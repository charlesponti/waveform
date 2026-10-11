import Accelerate

/// Turns a stream of audio samples into columns at a steady rate (say 60 a second), however the
/// samples arrive: in buffers of any size, one after another.
///
/// It is exact. A column's edges are placed at whole samples from the running count (`rate` need not
/// divide the sample rate), so after any amount of audio the number of columns is right and none
/// drifts. It never allocates, and it works through each buffer with vDSP, so it is safe to call from
/// the audio thread.
public final class ColumnBuilder {
  public let sampleRate: Double
  public let columnsPerSecond: Double

  private var seen = 0  // samples handed in so far, in columns already ended or the one in progress
  private var emitted = 0  // columns finished
  private var nextEdge: Int  // the sample count at which the column in progress ends
  private var low = Float.infinity
  private var high = -Float.infinity
  private var sumOfSquares = 0.0
  private var inColumn = 0

  public init(sampleRate: Double, columnsPerSecond: Double) {
    precondition(sampleRate > 0 && columnsPerSecond > 0 && columnsPerSecond <= sampleRate)
    self.sampleRate = sampleRate
    self.columnsPerSecond = columnsPerSecond
    nextEdge = Self.edge(1, sampleRate, columnsPerSecond)
  }

  private static func edge(_ index: Int, _ sampleRate: Double, _ rate: Double) -> Int {
    Int((Double(index) * sampleRate / rate).rounded())
  }

  /// Feeds `count` samples. `emit` is called once for each column that ends inside them.
  public func feed(
    _ samples: UnsafePointer<Float>, count: Int, emit: (Column) -> Void
  ) {
    var offset = 0
    while offset < count {
      let take = min(count - offset, max(1, nextEdge - seen))
      let slice = samples + offset
      var lowest: Float = 0
      var highest: Float = 0
      var squares: Float = 0
      vDSP_minv(slice, 1, &lowest, vDSP_Length(take))
      vDSP_maxv(slice, 1, &highest, vDSP_Length(take))
      vDSP_svesq(slice, 1, &squares, vDSP_Length(take))
      low = min(low, lowest)
      high = max(high, highest)
      sumOfSquares += Double(squares)
      inColumn += take
      seen += take
      offset += take
      if seen >= nextEdge {
        emit(
          Column(low: low, high: high, rms: Float((sumOfSquares / Double(inColumn)).squareRoot())))
        emitted += 1
        nextEdge = Self.edge(emitted + 1, sampleRate, columnsPerSecond)
        low = .infinity
        high = -.infinity
        sumOfSquares = 0
        inColumn = 0
      }
    }
  }

  /// How many columns have been finished.
  public var columns: Int { emitted }
}
