import Foundation
import Synchronization

/// Ties the audio's own time (the count of samples) to the screen's time, so a column can be drawn at
/// the moment it should be heard rather than the moment the screen happened to notice it.
///
/// The audio thread tells it, for each buffer, when that buffer began on the host clock. The offset
/// between the two clocks barely drifts, so it is smoothed heavily: one buffer's scheduling noise
/// does not move it. Many threads may read; one writes.
public final class StreamClock: @unchecked Sendable {
  private let offsetBits = Atomic<UInt64>(Double.nan.bitPattern)
  private var smoothed = Double.nan  // the writer's copy
  private let gain: Double

  /// `gain` is how much of each new measurement is believed (0.02 = 2%).
  public init(gain: Double = 0.02) { self.gain = gain }

  /// Called by the audio thread: the host clock read `hostSeconds` when sample `streamSeconds * rate` began.
  public func update(hostSeconds: Double, streamSeconds: Double) {
    let raw = hostSeconds - streamSeconds
    smoothed = smoothed.isNaN ? raw : smoothed + gain * (raw - smoothed)
    offsetBits.store(smoothed.bitPattern, ordering: .releasing)
  }

  /// The host clock's reading at stream time zero, or nil until the first buffer.
  public var offset: Double? {
    let value = Double(bitPattern: offsetBits.load(ordering: .acquiring))
    return value.isNaN ? nil : value
  }

  /// Where in the stream the host clock's `hostSeconds` falls, or nil until the first buffer.
  public func streamTime(atHost hostSeconds: Double) -> Double? {
    offset.map { hostSeconds - $0 }
  }
}

/// A phase-locked loop on the screen's frame times. The system tells a drawing callback roughly when a
/// frame will be shown, with a millisecond or two of noise; used raw, that noise becomes shake. This
/// follows the steady beat of the frames and returns a clean time for each one.
public struct FrameClock: Sendable {
  private var phase = Double.nan
  public private(set) var period: Double
  private let phaseGain: Double
  private let periodGain: Double

  public init(initialPeriod: Double = 1.0 / 60, phaseGain: Double = 0.15, periodGain: Double = 0.01) {
    period = initialPeriod
    self.phaseGain = phaseGain
    self.periodGain = periodGain
  }

  /// Feeds the time a frame was measured at; returns the smoothed time of that frame.
  public mutating func tick(_ measured: Double) -> Double {
    guard !phase.isNaN, measured - phase < 0.5 else {  // first frame, or a long pause: start again
      phase = measured
      return measured
    }
    let predicted = phase + period
    // A late or early frame is believed only a little, and never by more than a period or two.
    let error = max(-period, min(2 * period, measured - predicted))
    period += periodGain * error
    phase = predicted + phaseGain * error
    return phase
  }
}
