import Foundation
import Testing

@testable import WaveformCore

private func sine(_ amplitude: Float, hz: Double, seconds: Double, rate: Double = 48_000) -> [Float] {
  (0..<Int(seconds * rate)).map { amplitude * Float(sin(2 * .pi * hz * Double($0) / rate)) }
}

private func columns(
  of samples: [Float], rate: Double = 48_000, perSecond: Double = 60, chunk: Int
) -> [Column] {
  let builder = ColumnBuilder(sampleRate: rate, columnsPerSecond: perSecond)
  var out: [Column] = []
  var start = 0
  while start < samples.count {
    let end = min(samples.count, start + chunk)
    samples[start..<end].withUnsafeBufferPointer { buffer in
      builder.feed(buffer.baseAddress!, count: end - start) { out.append($0) }
    }
    start = end
  }
  return out
}

@Suite struct ColumnBuilderTests {
  @Test func aSineShowsItsAmplitudeAndItsLoudness() {
    let result = columns(of: sine(0.5, hz: 440, seconds: 2), chunk: 512)
    #expect(result.count == 120)
    for column in result.dropFirst() {
      #expect(abs(column.high - 0.5) < 0.005)
      #expect(abs(column.low + 0.5) < 0.005)
      // The loudness of a sine is its peak divided by the square root of two.
      #expect(abs(Double(column.rms) - 0.5 / 2.0.squareRoot()) < 0.01)
    }
  }

  @Test func silenceIsSilence() {
    let result = columns(of: [Float](repeating: 0, count: 48_000), chunk: 300)
    #expect(result.count == 60)
    #expect(result.allSatisfy { $0 == .silent })
  }

  @Test func theWayAudioArrivesDoesNotChangeTheColumns() {
    let signal = Synthesize.speechLike(seconds: 3)
    let reference = columns(of: signal, chunk: 4_096)
    for chunk in [1, 7, 100, 512, 735, 1_000, 4_801] {
      let other = columns(of: signal, chunk: chunk)
      #expect(other.count == reference.count, "chunk \(chunk)")
      for (a, b) in zip(reference, other) {
        #expect(a.low == b.low && a.high == b.high, "chunk \(chunk)")
        #expect(abs(a.rms - b.rms) < 1e-6, "chunk \(chunk)")
      }
    }
  }

  @Test func theNumberOfColumnsStaysRightWhenTheRateDoesNotDivideEvenly() {
    for (rate, perSecond) in [(44_100.0, 60.0), (44_100.0, 47.0), (48_000.0, 59.94), (16_000.0, 120.0)] {
      let seconds = 10.0
      let signal = [Float](repeating: 0.1, count: Int(seconds * rate))
      let result = columns(of: signal, rate: rate, perSecond: perSecond, chunk: 777)
      let expected = Int((seconds * perSecond).rounded(.down))
      #expect(abs(result.count - expected) <= 1, "\(rate) at \(perSecond): \(result.count) not \(expected)")
    }
  }

  @Test func aSingleLoudSampleIsNeverLost() {
    var signal = [Float](repeating: 0, count: 48_000)
    signal[12_345] = 0.9
    let result = columns(of: signal, chunk: 333)
    #expect(result.map(\.high).max() == 0.9)
  }
}

@Suite struct ScaleTests {
  @Test func decibelsKeepTheSignAndTheEnds() {
    let scale = Scale.decibels(floor: -60)
    #expect(scale.height(1) == 1)
    #expect(scale.height(-1) == -1)
    #expect(scale.height(0) == 0)
    #expect(scale.height(0.0005) == 0)
    // Half the amplitude is 6 dB down: 90% of the way up a 60 dB range.
    #expect(abs(scale.height(0.5) - 0.9) < 0.005)
    #expect(scale.height(-0.5) < 0)
  }

  @Test func linearClips() {
    #expect(Scale.linear.height(2) == 1)
    #expect(Scale.linear.height(-0.25) == -0.25)
  }
}
