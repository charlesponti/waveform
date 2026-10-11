import QuartzCore
import SwiftUI
import WaveformCore

/// The newest columns scrolling in from the right: a faint bar from lowest to highest sample, and a
/// bright one for loudness. One path per layer, so a frame is two fills however many bars there are.
public struct WaveformView: View {
  let ring: ColumnRing
  var columnsPerSecond: Double
  var scale: Scale
  var barWidth: CGFloat
  var gap: CGFloat
  var showStats: Bool
  @State private var scratch = Scratch()

  /// - Parameters:
  ///   - ring: the columns to draw, filled by `LiveInput` or by hand.
  ///   - columnsPerSecond: how fast columns arrive, so the row can slide between arrivals.
  ///   - scale: linear, or decibels so quiet speech stays visible.
  ///   - showStats: show what a frame costs in the corner.
  public init(
    ring: ColumnRing, columnsPerSecond: Double = 120, scale: Scale = .decibels(floor: -60),
    barWidth: CGFloat = 3, gap: CGFloat = 2, showStats: Bool = true
  ) {
    self.ring = ring
    self.columnsPerSecond = columnsPerSecond
    self.scale = scale
    self.barWidth = barWidth
    self.gap = gap
    self.showStats = showStats
  }

  public var body: some View {
    FrameCanvas(
      scratch: scratch, showStats: showStats,
      stats: { String(format: "draw %.2f ms", scratch.drawMs) }, draw: draw)
  }

  private func draw(_ context: inout GraphicsContext, _ size: CGSize) {
    let step = barWidth + gap
    let visible = min(4000, Int(size.width / step) + 2)
    ring.copyLast(visible, into: scratch.columns)

    // Columns arrive 60 times a second but the screen can draw 120, so the row slides left between
    // arrivals instead of jumping a whole column at once.
    let now = CACurrentMediaTime()
    let count = ring.count
    if count != scratch.lastCount {
      scratch.lastCount = count
      scratch.lastChange = now
    }
    let slide = CGFloat(min(1, (now - scratch.lastChange) * columnsPerSecond)) * step

    let mid = size.height / 2
    var peaks = Path()
    var loudness = Path()
    for i in 0..<visible {
      let column = scratch.columns[i]
      let x = size.width - CGFloat(visible - i) * step - slide + step
      if x + barWidth < 0 || x > size.width { continue }
      let top = mid - CGFloat(scale.height(column.high)) * mid
      let bottom = mid - CGFloat(scale.height(column.low)) * mid
      let minimum: CGFloat = barWidth
      let peakRect = CGRect(
        x: x, y: min(top, mid - minimum / 2), width: barWidth,
        height: max(minimum, bottom - top))
      peaks.addRoundedRect(in: peakRect, cornerSize: CGSize(width: barWidth / 2, height: barWidth / 2))
      let r = CGFloat(scale.height(column.rms)) * mid
      let loudRect = CGRect(x: x, y: mid - max(minimum / 2, r), width: barWidth, height: max(minimum, 2 * r))
      loudness.addRoundedRect(
        in: loudRect, cornerSize: CGSize(width: barWidth / 2, height: barWidth / 2))
    }
    context.fill(peaks, with: .color(.mint.opacity(0.35)))
    context.fill(loudness, with: .color(.mint))
  }
}
