import QuartzCore
import SwiftUI
import WaveformCore
import simd

/// The orb as a spectrogram wrapped round a sphere: how far a dot is from the equator is how long ago
/// (newest at the equator, as in the plain orb); where it sits round the sphere is pitch, low on one
/// side to high on the other. A dot pushes out, and grows, by how loud that pitch was at that moment.
struct SpectrumOrbView: View {
  let spectrum: SpectrumRing
  var columnsPerSecond: Double = 120
  var sampleRate: Double = 48_000
  var fftSize = 2_048
  var clock: StreamClock?
  var latency = 0.06
  var scale: Scale = .decibels(floor: -66)
  var gain: Float = 0.5
  var historySeconds = 0.8
  var showStats = true
  var turning = true
  @State private var scratch = Scratch()
  @State private var model = OrbModel(count: 1_800)

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
          Text(String(format: "draw %.2f ms · %d dots · %d frames", scratch.drawMs, model.count, spectrum.count))
            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).padding(8)
        }
      }
    }
  }

  private func draw(_ context: inout GraphicsContext, _ size: CGSize) {
    let bands = spectrum.bands
    let history = historySeconds * columnsPerSecond
    let needed = Int(history) + 16
    let (_, end) = spectrum.snapshot(needed, into: scratch.spectrum)
    let window = SpectrumWindow(
      values: UnsafeBufferPointer(start: scratch.spectrum, count: needed * bands), bands: bands,
      base: end - needed)
    let frameTime = scratch.frame.tick(CACurrentMediaTime())
    let columnPlayhead = Playhead(columnsPerSecond: columnsPerSecond, latency: latency)
      .position(hostSeconds: frameTime, clock: clock ?? StreamClock(), written: end)
    // A frame looks at the last `fftSize` samples, so it describes the moment half a window before its
    // hop ends. Reading it at that moment (not at the hop's end) keeps pitch and loudness lined up.
    let delay = Double(fftSize) / 2 / sampleRate * columnsPerSecond - 0.5
    let playhead = min(Double(end - 2), columnPlayhead + delay)

    let spin = turning ? Float(frameTime) * 0.12 : 0.0
    let tip: Float = 0.32
    let (sy, cy) = (sin(spin), cos(spin))
    let (sx, cx) = (sin(tip), cos(tip))
    let radius = Float(min(size.width, size.height)) / 2 / (1 + gain) * 0.94
    let center = SIMD2<Float>(Float(size.width) / 2, Float(size.height) / 2)
    var layers = [Path(), Path(), Path(), Path()]

    for i in 0..<model.count {
      let level = window.value(
        time: playhead - Double(model.age[i]) * history, band: model.pitch[i] * Float(bands - 1),
        scale: scale)
      let out = 1 + gain * level
      let u = model.unit[i]
      let x1 = u.x * cy + u.z * sy
      let z1 = -u.x * sy + u.z * cy
      let y2 = u.y * cx - z1 * sx
      let z2 = u.y * sx + z1 * cx
      let depth = (z2 + 1) / 2
      let layer = min(3, Int(depth * 4))
      let perspective = 0.75 + 0.25 * depth
      let dot = (1.0 + 2.8 * level) * perspective
      let px = CGFloat(center.x + x1 * out * radius)
      let py = CGFloat(center.y - y2 * out * radius)
      layers[layer].addEllipse(
        in: CGRect(x: px - CGFloat(dot), y: py - CGFloat(dot), width: CGFloat(dot) * 2, height: CGFloat(dot) * 2))
    }
    for (path, opacity) in zip(layers, [0.18, 0.4, 0.7, 1.0]) {
      context.fill(path, with: .color(.mint.opacity(opacity)))
    }
  }
}
