import AVFoundation

/// Listens to the microphone, or plays a file and listens to that, and fills a `ColumnRing` with
/// columns as the audio goes by. The columns are made right in the audio callback (no allocation, no
/// lock); the screen only reads the ring.
public final class LiveInput: @unchecked Sendable {
  public let ring: ColumnRing
  /// The spectrum, one frame per column.
  public let spectrum = SpectrumRing(bands: 24, capacity: 8192)
  /// Ties the audio's time to the host clock; the screen reads it to draw each column at the right moment.
  public let clock = StreamClock()
  public let columnsPerSecond: Double
  private let engine: AVAudioEngine
  private let player = AVAudioPlayerNode()
  private let requestAccess: @Sendable () async -> Bool
  private var builder: ColumnBuilder?

  /// - Parameters:
  ///   - engine: the audio engine to listen through. Tests pass one in offline rendering mode, so no
  ///     microphone or speaker is needed.
  ///   - requestAccess: asks the person for the microphone. The default shows the system prompt.
  public init(
    ring: ColumnRing, columnsPerSecond: Double = 120, engine: AVAudioEngine = AVAudioEngine(),
    requestAccess: @escaping @Sendable () async -> Bool = systemMicrophoneAccess
  ) {
    self.ring = ring
    self.columnsPerSecond = columnsPerSecond
    self.engine = engine
    self.requestAccess = requestAccess
  }

  public enum MicrophoneError: Error, CustomStringConvertible {
    case denied
    public var description: String {
      "The microphone is not allowed. Turn it on for this app (or for Terminal, if you started it from there) in System Settings > Privacy & Security > Microphone."
    }
  }

  /// Draws the microphone. Asks for permission first, and says so plainly if it is refused: a refused
  /// microphone does not fail, it just delivers silence.
  public func startMicrophone() async throws {
    guard await requestAccess() else { throw MicrophoneError.denied }
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    tap(input, format: format)
    try engine.start()
  }

  /// Plays `file` out loud and draws it. Needs no microphone permission.
  public func play(file url: URL) throws {
    let file = try AVAudioFile(forReading: url)
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
    tap(player, format: file.processingFormat)
    player.scheduleFile(file, at: nil)
    try engine.start()
    player.play()
  }

  public func stop() {
    player.stop()
    engine.stop()
  }

  private func tap(_ node: AVAudioNode, format: AVAudioFormat) {
    // A 25 ms loudness window at the column rate: a few pitch periods of a voice.
    let blocks = max(1, Int((0.025 * columnsPerSecond).rounded()))
    let builder = ColumnBuilder(
      sampleRate: format.sampleRate, columnsPerSecond: columnsPerSecond, windowBlocks: blocks)
    self.builder = builder
    let ring = ring
    let spectrum = spectrum
    let spectrumBuilder = SpectrumBuilder(sampleRate: format.sampleRate, columnsPerSecond: columnsPerSecond)
    let clock = clock
    let rate = format.sampleRate
    node.installTap(onBus: 0, bufferSize: 512, format: format) { buffer, when in
      // Channel 0 only: a voice is mono, and mixing channels would only smooth the peaks.
      guard let data = buffer.floatChannelData?[0] else { return }
      Self.stamp(clock, at: when, samplesSeen: builder.samplesSeen, rate: rate)
      builder.feed(data, count: Int(buffer.frameLength)) { ring.append($0) }
      spectrumBuilder.feed(data, count: Int(buffer.frameLength)) { spectrum.append($0) }
    }
  }

  /// Tells `clock` that the buffer starting at sample `samplesSeen` began at `when` on the host clock.
  /// A buffer with no host time (offline rendering) says nothing.
  static func stamp(_ clock: StreamClock, at when: AVAudioTime, samplesSeen: Int, rate: Double) {
    guard when.isHostTimeValid else { return }
    clock.update(
      hostSeconds: AVAudioTime.seconds(forHostTime: when.hostTime),
      streamSeconds: Double(samplesSeen) / rate)
  }
}
