import AVFoundation

/// Listens to the microphone, or plays a file and listens to that, and fills a `ColumnRing` with
/// columns as the audio goes by. The columns are made right in the audio callback (no allocation, no
/// lock); the screen only reads the ring.
public final class LiveInput: @unchecked Sendable {
  public let ring: ColumnRing
  /// Ties the audio's time to the host clock; the screen reads it to draw each column at the right moment.
  public let clock = StreamClock()
  public let columnsPerSecond: Double
  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private var builder: ColumnBuilder?

  public init(ring: ColumnRing, columnsPerSecond: Double = 120) {
    self.ring = ring
    self.columnsPerSecond = columnsPerSecond
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
    guard await AVCaptureDevice.requestAccess(for: .audio) else { throw MicrophoneError.denied }
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
    let clock = clock
    let rate = format.sampleRate
    node.installTap(onBus: 0, bufferSize: 512, format: format) { buffer, when in
      // Channel 0 only: a voice is mono, and mixing channels would only smooth the peaks.
      guard let data = buffer.floatChannelData?[0] else { return }
      if when.isHostTimeValid {
        clock.update(
          hostSeconds: AVAudioTime.seconds(forHostTime: when.hostTime),
          streamSeconds: Double(builder.samplesSeen) / rate)
      }
      builder.feed(data, count: Int(buffer.frameLength)) { ring.append($0) }
    }
  }
}
