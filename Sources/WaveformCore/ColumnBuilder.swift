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

  /// How many of the latest blocks the loudness (`rms`) is measured over. A voice's pitch repeats every
  /// 4 to 10 milliseconds; a window of a few pitch periods keeps the loudness from flickering with it.
  public let windowBlocks: Int
  /// How long `level` takes to fall by a factor of e (about 63%) when the sound stops.
  public let releaseSeconds: Double
  private var recent: [(squares: Double, samples: Int)]
  private var recentIndex = 0
  private var level: Float = 0
  private let decay: Float

  public init(
    sampleRate: Double, columnsPerSecond: Double, windowBlocks: Int = 1, releaseSeconds: Double = 0.15
  ) {
    precondition(sampleRate > 0 && columnsPerSecond > 0 && columnsPerSecond <= sampleRate)
    precondition(windowBlocks >= 1)
    self.sampleRate = sampleRate
    self.columnsPerSecond = columnsPerSecond
    self.windowBlocks = windowBlocks
    self.releaseSeconds = releaseSeconds
    recent = Array(repeating: (0, 0), count: windowBlocks)
    decay = Float(exp(-1 / (columnsPerSecond * max(releaseSeconds, 1e-6))))
    nextEdge = Self.edge(1, sampleRate, columnsPerSecond)
  }

  /// How many samples have been fed in so far.
  public var samplesSeen: Int { seen }

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
        recent[recentIndex] = (sumOfSquares, inColumn)
        recentIndex = (recentIndex + 1) % windowBlocks
        var windowSquares = 0.0
        var windowSamples = 0
        for block in recent {
          windowSquares += block.squares
          windowSamples += block.samples
        }
        let rms = Float((windowSquares / Double(max(1, windowSamples))).squareRoot())
        level = max(rms, level * decay)
        emit(Column(low: low, high: high, rms: rms, level: level))
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
