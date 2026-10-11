import QuartzCore
import SwiftUI
import WaveformCore

/// The orb as a spectrogram wrapped round a sphere: how far a dot is from the equator is how long ago
/// (newest at the equator, as in the plain orb); where it sits round the sphere is pitch, low on one
/// side to high on the other. A dot pushes out, and grows, by how loud that pitch was at that moment.
public struct SpectrumOrbView: View {
  let spectrum: SpectrumRing
  var columnsPerSecond: Double
  var sampleRate: Double
  var fftSize: Int
  var clock: StreamClock?
  var latency: Double
  var scale: Scale
  var gain: Float
  var historySeconds: Double
  var showStats: Bool
  var turning: Bool
  @State private var scratch = Scratch()
  @State private var model: OrbModel

  /// - Parameters:
  ///   - spectrum: the frames to draw, filled by `LiveInput.spectrum` or by a `SpectrumBuilder`.
  ///   - sampleRate: of the audio the spectrum was made from, to line the FFT window up with the loudness.
  ///   - fftSize: the builder's FFT size, for the same reason.
  ///   - clock: where the audio's time meets the screen's. Nil draws the newest sound.
  ///   - dotCount: number of dots on the sphere.
  public init(
    spectrum: SpectrumRing, columnsPerSecond: Double = 120, sampleRate: Double = 48_000,
    fftSize: Int = 2_048, clock: StreamClock? = nil, latency: Double = 0.06,
    scale: Scale = .decibels(floor: -66), gain: Float = 0.5, historySeconds: Double = 0.8,
    showStats: Bool = true, turning: Bool = true, dotCount: Int = 1_800
  ) {
    self.spectrum = spectrum
    self.columnsPerSecond = columnsPerSecond
    self.sampleRate = sampleRate
    self.fftSize = fftSize
    self.clock = clock
    self.latency = latency
    self.scale = scale
    self.gain = gain
    self.historySeconds = historySeconds
    self.showStats = showStats
    self.turning = turning
    _model = State(initialValue: OrbModel(count: dotCount))
  }

  public var body: some View {
    FrameCanvas(
      scratch: scratch, showStats: showStats,
      stats: { String(format: "draw %.2f ms · %d dots · %d frames", scratch.drawMs, model.count, spectrum.count) },
      draw: draw)
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
    let projection = OrbProjection(
      spin: OrbProjection.spin(turning: turning, time: frameTime, rate: 0.12, still: 0), tip: 0.32)
    drawOrbDots(&context, size: size, model: model, projection: projection, gain: gain) { i in
      let level = window.value(
        time: playhead - Double(model.age[i]) * history, band: model.pitch[i] * Float(bands - 1),
        scale: scale)
      return (1 + gain * level, 1.0 + 2.8 * level)
    }
  }
}
