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
      #if os(macOS)
        // macOS lets the output be asked for a format: exactly the file's, so no resampling. iOS has no
        // `audioSettings` at all — it always delivers Float32 — which is why the sink below reads the format
        // off the sample buffer instead of trusting this one.
        dataOutput.audioSettings = [
          AVFormatIDKey: Int(kAudioFormatLinearPCM),
          AVSampleRateKey: settings.sampleRate,
          AVNumberOfChannelsKey: settings.channels,
          AVLinearPCMBitDepthKey: 16,
          AVLinearPCMIsFloatKey: false,
          AVLinearPCMIsBigEndianKey: false,
          AVLinearPCMIsNonInterleaved: false,
        ]
      #endif
      guard session.canAddOutput(dataOutput) else { throw CaptureSourceError.outputRefused }
      session.addOutput(dataOutput)

      // The output holds its delegate weakly: an inline sink would be deallocated before the first buffer.
      let sink = Sink(onBuffer: onBuffer)
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

    /// Turns the output's sample buffers into the Float32 buffers the recorder converts from.
    ///
    /// The format is read from each sample buffer rather than assumed: macOS delivers the 16-bit interleaved
    /// shape asked for above, iOS delivers Float32 and cannot be asked for anything.
    private final class Sink: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
      private let onBuffer: (AVAudioPCMBuffer, AVAudioTime) -> Void

      init(onBuffer: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) {
        self.onBuffer = onBuffer
      }

      func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                         from connection: AVCaptureConnection) {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: asbd),
              let block = CMSampleBufferGetDataBuffer(sampleBuffer),
              CMBlockBufferIsRangeContiguous(block, atOffset: 0, length: 0) else { return }
        var lengthAtOffset = 0
        var totalLength = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset,
                                          totalLengthOut: &totalLength, dataPointerOut: &pointer) == kCMBlockBufferNoErr,
              let pointer else { return }

        // Every buffer handed on is Float32 mono at the source's own rate; the recorder converts from there.
        let channels = max(1, Int(format.channelCount))
        let target = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1)!
        switch format.commonFormat {
        case .pcmFormatFloat32:
          let frames = totalLength / (MemoryLayout<Float>.size * channels)
          guard frames > 0,
                let pcm = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(frames)),
                let destination = pcm.floatChannelData?[0] else { return }
          pcm.frameLength = AVAudioFrameCount(frames)
          pointer.withMemoryRebound(to: Float.self, capacity: frames * channels) { source in
            // Interleaved or not, take the first channel: a microphone is one channel in practice.
            if format.isInterleaved {
              for frame in 0..<frames { destination[frame] = source[frame * channels] }
            } else {
              destination.update(from: source, count: frames)
            }
          }
          onBuffer(pcm, AVAudioTime(hostTime: mach_absolute_time()))
        case .pcmFormatInt16:
          let frames = totalLength / (MemoryLayout<Int16>.size * channels)
          guard frames > 0,
                let pcm = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(frames)),
                let destination = pcm.floatChannelData?[0] else { return }
          pcm.frameLength = AVAudioFrameCount(frames)
          pointer.withMemoryRebound(to: Int16.self, capacity: frames * channels) { source in
            for frame in 0..<frames { destination[frame] = Float(source[frame * channels]) / 32_768 }
          }
          onBuffer(pcm, AVAudioTime(hostTime: mach_absolute_time()))
        default:
          return
        }
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
