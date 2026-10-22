import QuartzCore
import SwiftUI
import WaveformCore

/// The orb of dots, loudness only: time runs from the equator (now) to the poles. The geometry and the
/// sound-to-shape maths are `OrbModel`; this turns the sphere, projects it and draws it.
public struct OrbView: View {
  let ring: ColumnRing
  var columnsPerSecond: Double
  var clock: StreamClock?
  var latency: Double
  var scale: Scale
  var gain: Float
  var historySeconds: Double
  var showStats: Bool
  var turning: Bool
  var tint: Color
  /// Radians a second the sphere turns at, and the angle it holds when `turning` is false.
  var spinRate: Float
  var still: Float
  /// Multiplies the size of every dot. The dot size is an absolute point size tuned for an orb of a
  /// few hundred points; a small orb drawn with the same dots ends up almost solid, so it passes a
  /// smaller multiplier. This is also how an icon grows its dots as the tile shrinks.
  var dotScale: Double
  @State private var scratch = Scratch()
  @State private var model: OrbModel

  /// - Parameters:
  ///   - ring: the columns to draw.
  ///   - clock: where the audio's time meets the screen's (`LiveInput.clock`). Nil draws the newest sound, for a still picture.
  ///   - latency: how far the picture runs behind the audio, in seconds.
  ///   - gain: how far a full-scale sound pushes a dot out, as a fraction of the radius.
  ///   - historySeconds: how much of the past the orb spans, equator to pole.
  ///   - turning: spin steadily; off holds a fixed angle.
  ///   - tint: the colour of the dots.
  ///   - dotCount: number of dots on the sphere.
  public init(
    ring: ColumnRing, columnsPerSecond: Double = 120, clock: StreamClock? = nil, latency: Double = 0.06,
    scale: Scale = .decibels(floor: -60), gain: Float = 0.45, historySeconds: Double = 0.8,
    showStats: Bool = true, turning: Bool = true, tint: Color = .mint, dotCount: Int = 1_400,
    spinRate: Float = 0.35, still: Float = 0.6, dotScale: Double = 1
  ) {
    self.ring = ring
    self.columnsPerSecond = columnsPerSecond
    self.clock = clock
    self.latency = latency
    self.scale = scale
    self.gain = gain
    self.historySeconds = historySeconds
    self.showStats = showStats
    self.turning = turning
    self.tint = tint
    self.spinRate = spinRate
    self.still = still
    self.dotScale = dotScale
    _model = State(initialValue: OrbModel(count: dotCount))
  }

  public var body: some View {
    FrameCanvas(
      scratch: scratch, showStats: showStats,
      stats: { String(format: "draw %.2f ms · %d dots · %d columns", scratch.drawMs, model.count, ring.count) },
      draw: draw)
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
    let projection = OrbProjection(
      spin: OrbProjection.spin(turning: turning, time: frameTime, rate: spinRate, still: still),
      tip: 0.35)
    drawOrbDots(&context, size: size, model: model, projection: projection, gain: gain, tint: tint) { i in
      let (out, peak) = OrbModel.sample(
        age: model.age[i], window: window, playhead: playhead, history: history, scale: scale,
        gain: gain)
      return (out, (1.1 + 2.4 * peak + out - 1) * Float(dotScale))
    }
  }
}
