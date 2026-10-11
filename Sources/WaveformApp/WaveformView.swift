import QuartzCore
import SwiftUI
import WaveformCore

/// Reused between frames so drawing never allocates.
final class Scratch {
  let columns = UnsafeMutablePointer<Column>.allocate(capacity: 4096)
  var lastCount = 0
  var lastChange = CACurrentMediaTime()
  var drawMs = 0.0  // a running average of what drawing a frame costs the CPU
  deinit { columns.deallocate() }
}

/// The newest columns scrolling in from the right. One path per layer, so a frame is two fills
/// however many bars there are.
struct WaveformView: View {
  let ring: ColumnRing
  var columnsPerSecond: Double = 60
  var scale: Scale = .decibels(floor: -60)
  var barWidth: CGFloat = 3
  var gap: CGFloat = 2
  var showStats = true
  @State private var scratch = Scratch()

  var body: some View {
    TimelineView(.animation) { _ in
      Canvas { context, size in
        let began = CACurrentMediaTime()
        draw(&context, size)
        let ms = (CACurrentMediaTime() - began) * 1000
        scratch.drawMs = scratch.drawMs * 0.95 + ms * 0.05
      }
      .overlay(alignment: .topLeading) {
        if showStats {
          Text(String(format: "draw %.2f ms", scratch.drawMs))
            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).padding(8)
        }
      }
    }
  }

  private func draw(_ context: inout GraphicsContext, _ size: CGSize) {
    let step = barWidth + gap
    let visible = min(4000, Int(size.width / step) + 2)
    let real = ring.copyLast(visible, into: scratch.columns)
    _ = real

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
