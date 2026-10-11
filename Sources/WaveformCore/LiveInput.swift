import AVFoundation

/// Listens to the microphone, or plays a file and listens to that, and fills a `ColumnRing` with
/// columns as the audio goes by. The columns are made right in the audio callback (no allocation, no
/// lock); the screen only reads the ring.
public final class LiveInput {
  public let ring: ColumnRing
  public let columnsPerSecond: Double
  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private var builder: ColumnBuilder?

  public init(ring: ColumnRing, columnsPerSecond: Double = 60) {
    self.ring = ring
    self.columnsPerSecond = columnsPerSecond
  }

  /// Draws the microphone. The first call asks for permission.
  public func startMicrophone() throws {
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
    let builder = ColumnBuilder(sampleRate: format.sampleRate, columnsPerSecond: columnsPerSecond)
    self.builder = builder
    let ring = ring
    node.installTap(onBus: 0, bufferSize: 512, format: format) { buffer, _ in
      // Channel 0 only: a voice is mono, and mixing channels would only smooth the peaks.
      guard let data = buffer.floatChannelData?[0] else { return }
      builder.feed(data, count: Int(buffer.frameLength)) { ring.append($0) }
    }
  }
}
