import QuartzCore
import SwiftUI
import WaveformCore

/// Reused between frames so drawing never allocates.
final class Scratch {
  let columns = UnsafeMutablePointer<Column>.allocate(capacity: 4096)
  let spectrum = UnsafeMutablePointer<Float>.allocate(capacity: 4096 * 24)
  var lastCount = 0
  var lastChange = CACurrentMediaTime()
  var drawMs = 0.0  // a running average of what drawing a frame costs the CPU
  var frame = FrameClock(initialPeriod: 1.0 / 60)  // follows the beat of the screen's frames
  deinit {
    columns.deallocate()
    spectrum.deallocate()
  }
}

/// A canvas that redraws every screen frame and, if asked, shows what a frame costs.
struct FrameCanvas: View {
  let scratch: Scratch
  var showStats: Bool
  let stats: () -> String
  let draw: (inout GraphicsContext, CGSize) -> Void

  var body: some View {
    TimelineView(.animation) { timeline in
      Canvas { context, size in
        // Reading the date makes each tick a new drawing, so SwiftUI never reuses the last frame.
        _ = timeline.date
        let began = CACurrentMediaTime()
        draw(&context, size)
        let ms = (CACurrentMediaTime() - began) * 1000
        scratch.drawMs = scratch.drawMs * 0.95 + ms * 0.05
      }
      .overlay(alignment: .topLeading) {
        if showStats {
          Text(stats())
            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).padding(8)
        }
      }
    }
  }
}
