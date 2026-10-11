import QuartzCore
import SwiftUI
import WaveformCore
import simd

/// The orb of dots. The geometry and the sound-to-shape maths are `OrbModel`; this only turns the
/// sphere, projects it and draws it, with four fills a frame (one per depth) however many dots.
struct OrbView: View {
  let ring: ColumnRing
  var columnsPerSecond: Double = 120
  /// Where the audio's time meets the screen's. Nil draws the newest sound (for a still picture).
  var clock: StreamClock?
  var latency = 0.06
  var scale: Scale = .decibels(floor: -60)
  var gain: Float = 0.45
  var historySeconds = 0.8  // how much of the past the orb spans, equator to pole
  var showStats = true
  var turning = true
  @State private var scratch = Scratch()
  @State private var model = OrbModel(count: 1_400)

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
          Text(String(format: "draw %.2f ms · %d dots · %d columns", scratch.drawMs, model.count, ring.count))
            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).padding(8)
        }
      }
    }
  }

  private func draw(_ context: inout GraphicsContext, _ size: CGSize) {
    // The picture runs a fixed moment behind the audio, on the audio's own clock, so each column moves
    // smoothly from the equator toward the poles instead of stepping when the screen notices it.
    let history = historySeconds * columnsPerSecond
    let needed = Int(history) + 16
    let (_, end) = ring.snapshot(needed, into: scratch.columns)
    let window = ColumnWindow(
      columns: UnsafeBufferPointer(start: scratch.columns, count: needed), base: end - needed)
    let frameTime = scratch.frame.tick(CACurrentMediaTime())
    let playhead = Playhead(columnsPerSecond: columnsPerSecond, latency: latency)
      .position(hostSeconds: frameTime, clock: clock ?? StreamClock(), written: end)
    let now = frameTime

    // Turn about the vertical axis, tipped a little toward the viewer so the poles can be seen.
    let spin = turning ? Float(now) * 0.35 : 0.6
    let tip: Float = 0.35
    let (sy, cy) = (sin(spin), cos(spin))
    let (sx, cx) = (sin(tip), cos(tip))

    let radius = Float(min(size.width, size.height)) / 2 / (1 + gain) * 0.94
    let center = SIMD2<Float>(Float(size.width) / 2, Float(size.height) / 2)
    var layers = [Path(), Path(), Path(), Path()]  // far to near

    for i in 0..<model.count {
      let (out, peak) = OrbModel.sample(
        age: model.age[i], window: window, playhead: playhead, history: history, scale: scale,
        gain: gain)
      let u = model.unit[i]
      // Spin, then tip.
      let x1 = u.x * cy + u.z * sy
      let z1 = -u.x * sy + u.z * cy
      let y2 = u.y * cx - z1 * sx
      let z2 = u.y * sx + z1 * cx
      let depth = (z2 + 1) / 2  // 0 far, 1 near
      let layer = min(3, Int(depth * 4))
      let perspective = 0.75 + 0.25 * depth
      let dot = (1.1 + 2.4 * peak + out - 1) * perspective
      let px = CGFloat(center.x + x1 * out * radius)
      let py = CGFloat(center.y - y2 * out * radius)
      layers[layer].addEllipse(in: CGRect(x: px - CGFloat(dot), y: py - CGFloat(dot), width: CGFloat(dot) * 2, height: CGFloat(dot) * 2))
    }
    let opacities = [0.18, 0.4, 0.7, 1.0]
    for (path, opacity) in zip(layers, opacities) {
      context.fill(path, with: .color(.mint.opacity(opacity)))
    }
  }
}
