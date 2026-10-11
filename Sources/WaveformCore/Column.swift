/// What one slice of time looks like: the lowest and highest sample in it, and its average power.
/// A waveform is a row of these. Peaks (`low`, `high`) show the shape; `rms` is what loudness is.
public struct Column: Equatable, Sendable {
  public var low: Float
  public var high: Float
  public var rms: Float

  public init(low: Float, high: Float, rms: Float) {
    self.low = low
    self.high = high
    self.rms = rms
  }

  public static let silent = Column(low: 0, high: 0, rms: 0)
}
