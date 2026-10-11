/// What one slice of time looks like: the lowest and highest sample in it, and its loudness.
/// A waveform is a row of these. Peaks (`low`, `high`) show the shape; `rms` is how loud it was,
/// measured over a short sliding window so a voice's pitch does not make it flicker; `level` is `rms`
/// with a meter's ballistics: it rises at once and falls away over a fraction of a second.
public struct Column: Equatable, Sendable {
  public var low: Float
  public var high: Float
  public var rms: Float
  public var level: Float

  public init(low: Float, high: Float, rms: Float, level: Float? = nil) {
    self.low = low
    self.high = high
    self.rms = rms
    self.level = level ?? rms
  }

  public static let silent = Column(low: 0, high: 0, rms: 0)
}
