#if os(iOS) || os(macOS)
  import AVFoundation
  import Foundation

  /// Where a recording's samples come from.
  ///
  /// The two implementations differ only in how buffers arrive, which is why this seam exists: an `AVAudioEngine`
  /// follows the system's default input and cannot be repointed after its graph is built (setting
  /// `kAudioOutputUnitProperty_CurrentDevice` is accepted, the hardware really switches, and then AVFAudio aborts on
  /// the tap because the graph still describes the old device). An `AVCaptureSession` takes a device up front and has
  /// no graph to disagree with.
  ///
  /// Everything downstream — conversion, duration, columns, spectrum, writing — belongs to `EngineRecorder`.
  public protocol AudioSource: AnyObject {
    /// Installs the source and calls `onBuffer` for each buffer of samples.
    func start(onBuffer: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) throws
    /// Stops the source. Called before the file is closed.
    func stop()
  }

  /// The microphone the system chose, through `AVAudioEngine`.
  ///
  /// This is the original path, unchanged in behaviour, so an app that does not need to choose a device keeps exactly
  /// what it had — including the engine's own handling of route changes: it stops itself, the input format changes,
  /// and the next buffer arrives in the new format. `EngineRecorder` rebuilds its converter when that happens.
  public final class EngineSource: AudioSource {
    private let engine: AVAudioEngine
    private let node: AVAudioNode
    private var configObserver: NSObjectProtocol?
    /// How the engine is started. A test replaces it to see a restart fail.
    var startEngine: () throws -> Void

    /// - Parameters:
    ///   - engine: the engine to run. A test hands one in offline rendering mode.
    ///   - node: the node to tap. Defaults to the engine's microphone input.
    public init(engine: AVAudioEngine = AVAudioEngine(), node: AVAudioNode? = nil) {
      self.engine = engine
      self.node = node ?? engine.inputNode
      self.startEngine = { try engine.start() }
    }

    deinit { configObserver.map(NotificationCenter.default.removeObserver) }

    public func start(onBuffer: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) throws {
      try listen(onBuffer)
      // A route change (headset in or out, a call ended) stops the engine and gives the input a new format, so listen
      // again and carry on writing to the same file.
      configObserver = NotificationCenter.default.addObserver(
        forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
      ) { [weak self, weak node] _ in
        guard let self, let node else { return }
        node.removeTap(onBus: 0)
        do { try self.listen(onBuffer) } catch {
          // The recorder notices a silent source: nothing arrives, and `stop()` reports it.
          self.lastError = error
        }
      }
    }

    /// Set when a route change could not be recovered. The recorder surfaces it through `stop()`.
    private(set) var lastError: Error?

    public func stop() {
      configObserver.map(NotificationCenter.default.removeObserver)
      configObserver = nil
      node.removeTap(onBus: 0)
      engine.stop()
    }

    private func listen(_ onBuffer: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) throws {
      node.removeTap(onBus: 0)
      let format = node.outputFormat(forBus: 0)
      node.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, when in
        onBuffer(buffer, when)
      }
      if !engine.isRunning { try startEngine() }
    }
  }

  /// The microphone chosen by name, through `AVCaptureSession`.
  ///
  /// Device-first by construction: the device is known before anything is built, so there is no graph to repoint.
  /// `AVCaptureAudioDataOutput.audioSettings` does the format conversion, so asking for the file's own format yields
  /// exactly that in every sample buffer.
  public final class CaptureSource: AudioSource {
    private let uid: String?
    private let settings: CaptureSettings
    private let session = AVCaptureSession()
    private var output: AVCaptureAudioDataOutput?
    private var sink: Sink?
    private let delegateQueue = DispatchQueue(label: "capture-source")
    /// The format the sample buffers arrive in, so the recorder knows what it converting from.
    private(set) var bufferFormat: AVAudioFormat?

    public init(deviceUID: String?, settings: CaptureSettings) {
      self.uid = deviceUID
      self.settings = settings
    }

    public func start(onBuffer: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) throws {
      guard let device = Self.device(uid: uid) else {
        throw CaptureSourceError.noSuchDevice(uid ?? "system default")
      }

      session.beginConfiguration()
      defer { session.commitConfiguration() }   // startRunning throws between begin and commit
      if session.canSetSessionPreset(.high) { session.sessionPreset = .high }

      let input = try AVCaptureDeviceInput(device: device)
      guard session.canAddInput(input) else { throw CaptureSourceError.deviceRefused(device.localizedName) }
      session.addInput(input)

      let dataOutput = AVCaptureAudioDataOutput()
      // Exactly the file's format: no converter of our own, and no resampling.
      dataOutput.audioSettings = [
        AVFormatIDKey: Int(kAudioFormatLinearPCM),
        AVSampleRateKey: settings.sampleRate,
        AVNumberOfChannelsKey: settings.channels,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
      ]
      guard session.canAddOutput(dataOutput) else { throw CaptureSourceError.outputRefused }
      session.addOutput(dataOutput)

      let format = AVAudioFormat(standardFormatWithSampleRate: settings.sampleRate,
                                 channels: AVAudioChannelCount(settings.channels))
      bufferFormat = format

      // The output holds its delegate weakly: an inline sink would be deallocated before the first buffer.
      let sink = Sink(format: format, onBuffer: onBuffer)
      dataOutput.setSampleBufferDelegate(sink, queue: delegateQueue)
      self.sink = sink
      self.output = dataOutput

      // startRunning blocks; the session delivers on `delegateQueue`.
      delegateQueue.async { [session] in session.startRunning() }
    }

    public func stop() {
      session.stopRunning()
      output?.setSampleBufferDelegate(nil, queue: nil)
      output = nil
      sink = nil
    }

    /// The device for a UID, or the system default when there is none.
    static func device(uid: String?) -> AVCaptureDevice? {
      if let uid, let match = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
      ).devices.first(where: { $0.uniqueID == uid }) {
        return match
      }
      return AVCaptureDevice.default(for: .audio)
    }

    /// Turns 16-bit sample buffers into the Float32 buffers the recorder converts from.
    private final class Sink: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
      private let format: AVAudioFormat?
      private let onBuffer: (AVAudioPCMBuffer, AVAudioTime) -> Void

      init(format: AVAudioFormat?, onBuffer: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) {
        self.format = format
        self.onBuffer = onBuffer
      }

      func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                         from connection: AVCaptureConnection) {
        guard let format, let block = CMSampleBufferGetDataBuffer(sampleBuffer),
              CMBlockBufferIsRangeContiguous(block, atOffset: 0, length: 0) else { return }
        var lengthAtOffset = 0
        var totalLength = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset,
                                          totalLengthOut: &totalLength, dataPointerOut: &pointer) == kCMBlockBufferNoErr,
              let pointer else { return }

        let sampleCount = totalLength / MemoryLayout<Int16>.size
        guard sampleCount > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleCount)),
              let destination = pcm.floatChannelData?[0] else { return }
        pcm.frameLength = AVAudioFrameCount(sampleCount)
        pointer.withMemoryRebound(to: Int16.self, capacity: sampleCount) { source in
          for index in 0..<sampleCount { destination[index] = Float(source[index]) / 32_768 }
        }
        onBuffer(pcm, AVAudioTime(hostTime: mach_absolute_time()))
      }
    }
  }

  public enum CaptureSourceError: LocalizedError {
    case noSuchDevice(String)
    case deviceRefused(String)
    case outputRefused

    public var errorDescription: String? {
      switch self {
      case .noSuchDevice(let name): return "There is no microphone called \(name)."
      case .deviceRefused(let name): return "The microphone \(name) could not be opened."
      case .outputRefused: return "The capture session refused an audio output."
      }
    }
  }
#endif
