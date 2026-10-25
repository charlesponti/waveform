#if os(iOS) || os(macOS)
  import AVFoundation
  import Foundation
  import WaveformCore

  /// Records what comes out of an `AudioSource` to a file and, at the same time, turns it into what the orb draws.
  ///
  /// The two apps differ only in their `CaptureSettings`: Thames writes 24 kHz AAC and reads the spectrum, Ponte writes
  /// the 16 kHz WAV its engines read and reads loudness columns. Everything else — the conversion, the duration, the
  /// columns, the route changes, the errors — is this one implementation, tested once in `WaveformCaptureTests`.
  ///
  /// Where the samples come from is now a seam (`AudioSource`): the system's default input through `AVAudioEngine`, or
  /// a chosen device through `AVCaptureSession`. The recorder does not care which, and the converter rebuilds itself
  /// when a buffer arrives in a different format — which is exactly what a route change looks like, however it was
  /// caused.
  ///
  /// Swift: buffers arrive on an audio thread, so the per-buffer work only converts and feeds the builders from
  /// reused buffers; a serial queue does the slow part, the writing.
  public final class EngineRecorder: @unchecked Sendable {
    /// Why a recording stopped being complete. `stop()` throws it rather than hand back a clip that
    /// ends part way, because a clip cut short sends and answers as if it were the whole.
    public struct Incomplete: LocalizedError {
      public let reason: String
      public var errorDescription: String? { "The recording stopped part way: \(reason)" }
    }

    public let settings: CaptureSettings

    /// Loudness columns, one entry per column. Always built: it is cheap, and both orbs use it.
    public let columns: ColumnRing
    /// The spectrum the spectrum orb draws, when the settings ask for one.
    public let spectrum: SpectrumRing?
    /// Where the audio's time meets the screen's, so the picture moves smoothly between buffers.
    public let clock = StreamClock()

    /// Where the recording is being written; set by `start`.
    public private(set) var path = ""

    private let source: AudioSource
    /// Kept only so a test can make the engine refuse to start, as it does when a device is taken.
    private(set) var engineSource: EngineSource?

    private let lock = NSLock()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var columnBuilder: ColumnBuilder?
    private var spectrumBuilder: SpectrumBuilder?
    private var frames = 0
    private var failure: Error?
    private var spareBuffers: [AVAudioPCMBuffer] = []
    private let writer = DispatchQueue(label: "recording-writer")
    private let target: AVAudioFormat

    /// Records from the source's own choice of device.
    public init(settings: CaptureSettings, audioSource: AudioSource) {
      self.settings = settings
      self.columns = ColumnRing(capacity: 8192)
      self.spectrum = settings.spectrumBands.map { SpectrumRing(bands: $0, capacity: 8192) }
      self.source = audioSource
      self.engineSource = audioSource as? EngineSource
      self.target = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: settings.sampleRate,
        channels: AVAudioChannelCount(settings.channels), interleaved: false)!
    }

    /// Records the system's default input through `AVAudioEngine` — the original path, kept so existing call sites
    /// and tests read the same.
    ///
    /// - Parameters:
    ///   - settings: what to write and what to draw. See `CaptureSettings.streamingSpeech` and
    ///     `.localTranscription`.
    ///   - engine: the engine to run. A test hands one in offline rendering mode.
    ///   - source: the node to record. Defaults to the engine's microphone input.
    public convenience init(
      settings: CaptureSettings, engine: AVAudioEngine = AVAudioEngine(), source: AVAudioNode? = nil
    ) {
      let engineSource = EngineSource(engine: engine, node: source)
      self.init(settings: settings, audioSource: engineSource)
      self.engineSource = engineSource
    }

    /// How the engine is started. A test replaces it to see a restart fail.
    var startEngine: () throws -> Void {
      get { engineSource?.startEngine ?? {} }
      set { engineSource?.startEngine = newValue }
    }

    /// How much has been recorded so far, in seconds.
    public var seconds: Double { Double(lock.withLock { frames }) / settings.sampleRate }

    /// Starts recording to `url`.
    public func start(to url: URL) throws {
      path = url.path
      let made = try AVAudioFile(forWriting: url, settings: settings.fileSettings)
      lock.lock()
      file = made
      frames = 0
      converter = nil
      columnBuilder = ColumnBuilder(
        sampleRate: settings.sampleRate, columnsPerSecond: settings.columnsPerSecond,
        releaseSeconds: settings.releaseSeconds)
      spectrumBuilder = settings.spectrumBands.map {
        SpectrumBuilder(
          sampleRate: settings.sampleRate, columnsPerSecond: settings.columnsPerSecond, bands: $0)
      }
      lock.unlock()

      try source.start { [weak self] buffer, when in
        self?.take(buffer, at: when)
      }
    }

    /// Stops and returns how long was recorded, in milliseconds. The file is complete once this returns.
    /// Throws `Incomplete` if the recording was cut short by a failed restart or a failed write.
    public func stop() throws -> Double {
      source.stop()
      if let sourceError = engineSource?.lastError { fail(sourceError) }
      writer.sync {}  // every queued write has finished once this returns
      lock.lock()
      defer { lock.unlock() }
      file = nil  // Swift: releasing the last reference to an AVAudioFile writes its footer.
      converter = nil
      columnBuilder = nil
      spectrumBuilder = nil
      spareBuffers = []
      if let failure { throw Incomplete(reason: failure.localizedDescription) }
      return (Double(frames) / settings.sampleRate * 1_000).rounded()
    }

    private func fail(_ error: Error) {
      lock.lock()
      failure = failure ?? error
      lock.unlock()
    }

    /// The converter for this buffer's format, rebuilt when the format changes.
    ///
    /// A route change arrives as buffers in a new format, and so does a capture source whose device differs from the
    /// default. Rebuilding here means neither has to announce itself.
    private func converter(for format: AVAudioFormat) -> AVAudioConverter? {
      if let converter, converter.inputFormat == format { return converter }
      let made = AVAudioConverter(from: format, to: target)
      converter = made
      return made
    }

    private func take(_ buffer: AVAudioPCMBuffer, at when: AVAudioTime) {
      let capacity =
        AVAudioFrameCount(
          Double(buffer.frameLength) * settings.sampleRate / buffer.format.sampleRate) + 32
      lock.lock()
      guard let file, let columnBuilder, let converter = converter(for: buffer.format) else {
        lock.unlock()
        return
      }
      let spectrumBuilder = self.spectrumBuilder
      let spare = spareBuffers.firstIndex { $0.frameCapacity >= capacity }
      let reused = spare.map { spareBuffers.remove(at: $0) }
      let started = frames
      lock.unlock()
      // Only a first buffer, or a bigger one than any before, is allocated here.
      guard let out = reused ?? AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
        return
      }
      out.frameLength = 0
      var supplied = false
      var conversionError: NSError?
      converter.convert(to: out, error: &conversionError) { _, status in
        if supplied {
          status.pointee = .noDataNow
          return nil
        }
        supplied = true
        status.pointee = .haveData
        return buffer
      }
      guard conversionError == nil, out.frameLength > 0, let data = out.floatChannelData?[0] else {
        return
      }
      if when.isHostTimeValid {
        clock.update(
          hostSeconds: AVAudioTime.seconds(forHostTime: when.hostTime),
          streamSeconds: Double(started) / settings.sampleRate)
      }
      let count = Int(out.frameLength)
      columnBuilder.feed(data, count: count) { [columns] in columns.append($0) }
      if let spectrumBuilder, let spectrum {
        spectrumBuilder.feed(data, count: count) { [spectrum] in spectrum.append($0) }
      }
      lock.lock()
      frames += count
      lock.unlock()
      writer.async { [self] in
        do { try file.write(from: out) } catch { fail(error) }
        lock.lock()
        spareBuffers.append(out)
        lock.unlock()
      }
    }
  }

  /// Which source to record from, so an app can say "this device, or whatever the system chose" without knowing what
  /// that costs.
  public enum AudioSourceChoice {
    /// A pinned device records through `AVCaptureSession`; no pin keeps exactly the path the app had before.
    public static func make(settings: CaptureSettings, deviceUID: String?) -> AudioSource {
      guard let deviceUID, !deviceUID.isEmpty else { return EngineSource() }
      return CaptureSource(deviceUID: deviceUID, settings: settings)
    }
  }
#endif
