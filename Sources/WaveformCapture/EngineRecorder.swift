#if os(iOS) || os(macOS)
  import AVFoundation
  import Foundation
  import WaveformCore

  /// Records what comes out of one audio node (the microphone, in both apps) to a file and, at the
  /// same time, turns it into what the orb draws.
  ///
  /// The two apps differ only in their `CaptureSettings`: Thames writes 24 kHz AAC and reads the
  /// spectrum, Ponte writes the 16 kHz WAV its engines read and reads loudness columns. Everything
  /// else — the conversion, the tap, the route changes, the duration, the errors — is this one
  /// implementation, tested once in `WaveformCaptureTests`.
  ///
  /// Swift: a "tap" is a closure the audio engine calls on its own audio thread with each small buffer
  /// of samples. Everything in the closure must be quick, so this one only converts to the target
  /// format and feeds the builders from reused buffers; a serial queue does the slow part, the writing.
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

    private let engine: AVAudioEngine
    private let source: AVAudioNode
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var columnBuilder: ColumnBuilder?
    private var spectrumBuilder: SpectrumBuilder?
    private var frames = 0
    private var failure: Error?
    private var spareBuffers: [AVAudioPCMBuffer] = []
    private let writer = DispatchQueue(label: "recording-writer")
    private var configObserver: NSObjectProtocol?
    /// How the engine is started. A test replaces it to see a restart fail.
    var startEngine: () throws -> Void
    private let target: AVAudioFormat

    /// - Parameters:
    ///   - settings: what to write and what to draw. See `CaptureSettings.streamingSpeech` and
    ///     `.localTranscription`.
    ///   - engine: the engine to run. A test hands one in offline rendering mode.
    ///   - source: the node to record. Defaults to the engine's microphone input.
    public init(
      settings: CaptureSettings, engine: AVAudioEngine = AVAudioEngine(), source: AVAudioNode? = nil
    ) {
      self.settings = settings
      self.columns = ColumnRing(capacity: 8192)
      self.spectrum = settings.spectrumBands.map { SpectrumRing(bands: $0, capacity: 8192) }
      self.engine = engine
      self.source = source ?? engine.inputNode
      self.target = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: settings.sampleRate,
        channels: AVAudioChannelCount(settings.channels), interleaved: false)!
      startEngine = { try engine.start() }
    }

    deinit { configObserver.map(NotificationCenter.default.removeObserver) }

    /// How much has been recorded so far, in seconds.
    public var seconds: Double { Double(lock.withLock { frames }) / settings.sampleRate }

    /// Starts recording to `url`.
    public func start(to url: URL) throws {
      path = url.path
      let made = try AVAudioFile(forWriting: url, settings: settings.fileSettings)
      lock.lock()
      file = made
      frames = 0
      lock.unlock()
      try listen()
      // The audio route changed (headset in or out, a call ended): the engine stops itself and the
      // input has a new format, so listen again and carry on writing to the same file.
      configObserver = NotificationCenter.default.addObserver(
        forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
      ) { [weak self] _ in self?.relisten() }
    }

    /// Stops and returns how long was recorded, in milliseconds. The file is complete once this returns.
    /// Throws `Incomplete` if the recording was cut short by a failed restart or a failed write.
    public func stop() throws -> Double {
      configObserver.map(NotificationCenter.default.removeObserver)
      configObserver = nil
      source.removeTap(onBus: 0)
      engine.stop()
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

    /// Listens again after the route changed. If the engine cannot restart, the recording is cut short:
    /// remember why, so `stop()` can say so.
    private func relisten() {
      do { try listen() } catch { fail(error) }
    }

    private func fail(_ error: Error) {
      lock.lock()
      failure = failure ?? error
      lock.unlock()
    }

    /// Installs the tap for the node's current format and starts the engine.
    private func listen() throws {
      source.removeTap(onBus: 0)
      let format = source.outputFormat(forBus: 0)
      lock.lock()
      converter = AVAudioConverter(from: format, to: target)
      columnBuilder = ColumnBuilder(
        sampleRate: settings.sampleRate, columnsPerSecond: settings.columnsPerSecond,
        releaseSeconds: settings.releaseSeconds)
      spectrumBuilder = settings.spectrumBands.map {
        SpectrumBuilder(
          sampleRate: settings.sampleRate, columnsPerSecond: settings.columnsPerSecond, bands: $0)
      }
      lock.unlock()
      source.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, when in
        self?.take(buffer, at: when)
      }
      if !engine.isRunning { try startEngine() }
    }

    private func take(_ buffer: AVAudioPCMBuffer, at when: AVAudioTime) {
      let capacity =
        AVAudioFrameCount(
          Double(buffer.frameLength) * settings.sampleRate / buffer.format.sampleRate) + 32
      lock.lock()
      guard let file, let converter, let columnBuilder else {
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
#endif
