import Foundation
import Testing

@testable import WaveformCore

@Suite struct ClockTests {
  /// A fixed pseudo-random sequence in -1...1, the same every run.
  private func noise(_ n: Int) -> [Double] {
    var state: UInt64 = 0x9E3779B97F4A7C15
    return (0..<n).map { _ in
      state = state &* 6364136223846793005 &+ 1442695040888963407
      return Double(state >> 11) / Double(1 << 53) * 2 - 1
    }
  }

  @Test func theFrameClockFollowsTheBeatAndShedsTheJitter() {
    let period = 1.0 / 120
    let jitter = noise(2_000).map { $0 * 0.002 }  // up to 2 ms either way
    var clock = FrameClock(initialPeriod: period)
    var rawError = 0.0
    var smoothError = 0.0
    for k in 0..<2_000 {
      let truth = Double(k) * period + 100
      let out = clock.tick(truth + jitter[k])
      if k > 200 {  // after it has locked
        rawError += jitter[k] * jitter[k]
        smoothError += (out - truth) * (out - truth)
      }
    }
    #expect(smoothError < rawError * 0.4, "smoothed \(smoothError) vs raw \(rawError)")
    #expect(abs(clock.period - period) < 0.0002)
  }

  @Test func theFrameClockStartsAgainAfterALongPause() {
    var clock = FrameClock()
    _ = clock.tick(10)
    _ = clock.tick(10.017)
    #expect(clock.tick(25) == 25)
  }

  @Test func theStreamClockSettlesOnTheOffsetDespiteBufferNoise() {
    let clock = StreamClock()
    #expect(clock.offset == nil)
    let jitter = noise(1_000).map { $0 * 0.003 }
    for k in 0..<1_000 {
      let stream = Double(k) * 512 / 48_000
      clock.update(hostSeconds: 500 + stream + jitter[k], streamSeconds: stream)
    }
    #expect(abs(clock.offset! - 500) < 0.0007)
    #expect(abs(clock.streamTime(atHost: 510)! - 10) < 0.0007)
  }

  @Test func thePlayheadRunsAFixedTimeBehindAndNeverAheadOfTheData() {
    let clock = StreamClock()
    clock.update(hostSeconds: 1_000, streamSeconds: 0)
    let playhead = Playhead(columnsPerSecond: 120, latency: 0.06)
    // Host time 1001 s is stream time 1 s; 60 ms behind that is 0.94 s, which is column 112.3.
    #expect(abs(playhead.position(hostSeconds: 1_001, clock: clock, written: 1_000) - 112.3) < 1e-6)
    // With little data written, it waits at the last column that has a neighbour.
    #expect(playhead.position(hostSeconds: 1_001, clock: clock, written: 50) == 48)
    // Before any audio, it sits just behind the newest column.
    #expect(playhead.position(hostSeconds: 1, clock: StreamClock(), written: 10) == 8)
  }
}

@Suite struct BallisticsTests {
  @Test func loudnessIsMeasuredOverAWindowSoPitchDoesNotFlickerIt() {
    // A 133 Hz voice (7.5 ms a cycle) with columns at 480 a second (2.1 ms): one column alone sees a
    // quarter of a cycle, so its loudness swings with the pitch.
    let rate = 48_000.0
    let signal = (0..<48_000).map { Float(0.5 * sin(2 * .pi * 133 * Double($0) / rate)) }
    func spread(_ blocks: Int) -> Float {
      let builder = ColumnBuilder(sampleRate: rate, columnsPerSecond: 480, windowBlocks: blocks)
      var rms: [Float] = []
      signal.withUnsafeBufferPointer { buffer in
        builder.feed(buffer.baseAddress!, count: buffer.count) { rms.append($0.rms) }
      }
      let steady = rms.dropFirst(20)
      return steady.max()! - steady.min()!
    }
    let single = spread(1)
    let windowed = spread(12)
    #expect(single > 0.1)  // one column wobbles with the pitch
    #expect(windowed < single / 8, "\(windowed) vs \(single)")  // a 25 ms window (12 columns) barely does
  }

  @Test func levelRisesAtOnceAndFallsAwayAtTheReleaseRate() {
    let rate = 48_000.0
    let builder = ColumnBuilder(sampleRate: rate, columnsPerSecond: 100, releaseSeconds: 0.2)
    var levels: [Float] = []
    let loud = [Float](repeating: 0.5, count: 4_800)  // 0.1 s of a steady 0.5
    let quiet = [Float](repeating: 0, count: 48_000)
    for chunk in [loud, quiet] {
      chunk.withUnsafeBufferPointer { buffer in
        builder.feed(buffer.baseAddress!, count: buffer.count) { levels.append($0.level) }
      }
    }
    #expect(abs(levels[0] - 0.5) < 1e-4)  // attack is immediate
    // After 0.2 s of silence (one release time) the level is down to 1/e of what it was.
    let tenth = levels[9]
    let afterOne = levels[9 + 20]
    #expect(abs(afterOne / tenth - Float(exp(-1.0))) < 0.01)
  }
}
