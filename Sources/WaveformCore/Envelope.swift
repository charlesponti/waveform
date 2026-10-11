import Foundation

/// A stretch of columns copied from the ring, read at any fractional position.
///
/// Position 0 is the middle of column 0, 1 the middle of column 1, and so on, by the absolute index
/// each column had when it was written. Between columns the value follows a Catmull-Rom curve through
/// the neighbouring four, so it has no corners: both the value and its rate of change are continuous
/// as the playhead moves, which is what makes the motion look smooth rather than stepped.
public struct ColumnWindow {
  public let columns: UnsafeBufferPointer<Column>
  /// The absolute index of `columns[0]`.
  public let base: Int

  public init(columns: UnsafeBufferPointer<Column>, base: Int) {
    self.columns = columns
    self.base = base
  }

  /// Level and peak (both in display units, 0...1) at absolute `position`.
  public func value(at position: Double, scale: Scale) -> (level: Float, peak: Float) {
    let n = columns.count
    guard n > 0 else { return (0, 0) }
    let local = position - Double(base)
    let i = Int(local.rounded(.down))
    let t = Float(local - Double(i))
    func at(_ k: Int) -> (Float, Float) {
      let column = columns[max(0, min(n - 1, k))]
      return (
        scale.height(column.level),
        max(abs(scale.height(column.high)), abs(scale.height(column.low)))
      )
    }
    let p0 = at(i - 1), p1 = at(i), p2 = at(i + 1), p3 = at(i + 2)
    return (
      max(0, Self.catmullRom(p0.0, p1.0, p2.0, p3.0, t)),
      max(0, min(1, Self.catmullRom(p0.1, p1.1, p2.1, p3.1, t)))
    )
  }

  /// The curve through p1 (at t = 0) and p2 (at t = 1), shaped by the points either side.
  public static func catmullRom(_ p0: Float, _ p1: Float, _ p2: Float, _ p3: Float, _ t: Float) -> Float {
    let t2 = t * t
    let t3 = t2 * t
    return 0.5
      * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2
        + (-p0 + 3 * p1 - 3 * p2 + p3) * t3)
  }
}

/// Where on the column timeline "now" is, for a screen that wants to show sound a fixed moment after it
/// was heard.
public struct Playhead {
  public let columnsPerSecond: Double
  /// How far behind the audio the picture runs. It must cover the audio buffer, the time to finish a
  /// column, and the cubic's one column of look-ahead; a little more than that costs nothing visible.
  public let latency: Double

  public init(columnsPerSecond: Double, latency: Double = 0.06) {
    self.columnsPerSecond = columnsPerSecond
    self.latency = latency
  }

  /// The absolute column position to draw at host time `hostSeconds`. Falls back to just behind the
  /// newest column when the clock has no audio yet. Never runs ahead of the data: the cubic needs the
  /// column after the one it is in.
  public func position(hostSeconds: Double, clock: StreamClock, written: Int) -> Double {
    let newest = Double(written - 2)  // the last position whose next neighbour exists
    guard let stream = clock.streamTime(atHost: hostSeconds - latency) else { return newest }
    return min(newest, stream * columnsPerSecond - 0.5)
  }
}
