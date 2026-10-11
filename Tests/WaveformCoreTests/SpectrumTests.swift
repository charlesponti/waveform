import Foundation
import Testing

@testable import WaveformCore

private let rate = 48_000.0

private func tone(_ parts: [(hz: Double, amplitude: Double)], seconds: Double) -> [Float] {
  (0..<Int(seconds * rate)).map { i in
    Float(parts.reduce(0) { $0 + $1.amplitude * sin(2 * .pi * $1.hz * Double(i) / rate) })
  }
}

private func frames(
  _ samples: [Float], tilt: Double = 0, chunk: Int = 512
) -> (frames: [[Float]], builder: SpectrumBuilder) {
  let builder = SpectrumBuilder(sampleRate: rate, tiltDBPerOctave: tilt)
  var out: [[Float]] = []
  var start = 0
  while start < samples.count {
    let end = min(samples.count, start + chunk)
    samples[start..<end].withUnsafeBufferPointer { buffer in
      builder.feed(buffer.baseAddress!, count: end - start) { out.append(Array($0)) }
    }
    start = end
  }
  return (out, builder)
}

@Suite struct SpectrumTests {
  /// The band whose range holds `hz`, for a builder with 24 log bands from 80 Hz to 8 kHz.
  private func band(of hz: Double) -> Int {
    Int(24 * log(hz / 80) / log(8_000.0 / 80))
  }

  @Test func aToneShowsItsAmplitudeInItsBandAndNowhereElse() {
    // 1500 Hz is exactly the centre of FFT bin 64, so the whole tone is in one place.
    let result = frames(tone([(1_500, 0.5)], seconds: 1))
    let last = result.frames.last!
    let target = band(of: 1_500)
    // A sine of amplitude 0.5 has an RMS of 0.5 / sqrt(2) = 0.3536.
    #expect(abs(last[target] - 0.3536) < 0.008, "band \(target): \(last[target])")
    for (i, value) in last.enumerated() where abs(i - target) >= 3 {
      #expect(value < 0.01, "band \(i) leaked \(value)")
    }
  }

  @Test func theBandsAddUpToTheSignalsPower() {
    let signal = tone([(300, 0.4), (3_000, 0.2), (700, 0.1)], seconds: 1)
    let last = frames(signal).frames.last!
    let power = last.reduce(0) { $0 + Double($1) * Double($1) }
    // Mean square of a sum of sines is the sum of A²/2.
    #expect(abs(power - (0.16 + 0.04 + 0.01) / 2) < 0.003, "\(power)")
  }

  @Test func twoTonesKeepTheirProportion() {
    let last = frames(tone([(500, 0.4), (3_000, 0.2)], seconds: 1)).frames.last!
    let low = last[band(of: 500)]
    let high = last[band(of: 3_000)]
    #expect(abs(low / high - 2) < 0.1, "\(low / high)")
  }

  @Test func silenceIsSilence() {
    let last = frames([Float](repeating: 0, count: 48_000)).frames.last!
    #expect(last.allSatisfy { $0 == 0 })
  }

  @Test func theTiltRaisesHigherBandsByTheStatedAmount() {
    // The same amplitude at 1 kHz and 2 kHz; with 3 dB per octave the upper one reads 3 dB (x1.414) higher.
    let flat = frames(tone([(1_000, 0.3), (2_000, 0.3)], seconds: 1)).frames.last!
    let tilted = frames(tone([(1_000, 0.3), (2_000, 0.3)], seconds: 1), tilt: 3).frames.last!
    let flatRatio = flat[band(of: 2_000)] / flat[band(of: 1_000)]
    let tiltedRatio = tilted[band(of: 2_000)] / tilted[band(of: 1_000)]
    #expect(abs(flatRatio - 1) < 0.15, "\(flatRatio)")
    #expect(abs(tiltedRatio / flatRatio - 1.414) < 0.12, "\(tiltedRatio / flatRatio)")
  }

  @Test func theWayAudioArrivesDoesNotChangeTheFrames() {
    let signal = Synthesize.speechLike(seconds: 1)
    let reference = frames(signal, chunk: 4_096).frames
    for chunk in [1, 100, 735, 512, 5_000] {
      let other = frames(signal, chunk: chunk).frames
      #expect(other.count == reference.count, "chunk \(chunk)")
      for (a, b) in zip(reference, other) {
        for (x, y) in zip(a, b) { #expect(abs(x - y) < 1e-6, "chunk \(chunk)") }
      }
    }
  }

  @Test func framesComeAtTheSameRateAsColumns() {
    let signal = [Float](repeating: 0.1, count: 48_000)
    #expect(frames(signal).frames.count == 120)
  }
}

@Suite struct SpectrumWindowTests {
  /// A little spectrogram with a known value at each (frame, band): value = 0.1 * band + 0.01 * frame.
  private func window(frames: Int, bands: Int, body: (SpectrumWindow) -> Void) {
    let values = (0..<(frames * bands)).map { Float(0.1 * Double($0 % bands) + 0.01 * Double($0 / bands)) }
    values.withUnsafeBufferPointer { body(SpectrumWindow(values: $0, bands: bands, base: 0)) }
  }

  @Test func itReadsExactlyAtFramesAndBandsAndBlendsBetween() {
    window(frames: 8, bands: 6) { window in
      #expect(abs(window.value(time: 3, band: 2, scale: .linear) - 0.23) < 1e-5)
      // Halfway between bands 2 and 3 at frame 3: the mean of 0.23 and 0.33.
      #expect(abs(window.value(time: 3, band: 2.5, scale: .linear) - 0.28) < 1e-5)
      // A straight ramp in time stays straight: halfway between frames 3 and 4.
      #expect(abs(window.value(time: 3.5, band: 2, scale: .linear) - 0.235) < 1e-5)
    }
  }

  @Test func theTopBandHasNoBandAboveIt() {
    window(frames: 8, bands: 6) { window in
      #expect(abs(window.value(time: 3, band: 5, scale: .linear) - 0.53) < 1e-5)
    }
  }

  @Test func theRingHandsFramesOverOldestFirst() {
    let ring = SpectrumRing(bands: 3, capacity: 8)
    for i in 0..<20 {
      let values: [Float] = [Float(i), Float(i) + 0.1, Float(i) + 0.2]
      values.withUnsafeBufferPointer { ring.append($0) }
    }
    var out = [Float](repeating: -1, count: 4 * 3)
    let (real, end) = out.withUnsafeMutableBufferPointer { ring.snapshot(4, into: $0.baseAddress!) }
    #expect(real == 4 && end == 20)
    #expect(out[0] == 16 && out[9] == 19 && abs(out[11] - 19.2) < 1e-5)
  }
}

@Suite struct OrbPitchTests {
  @Test func longitudeIsPitchWithNoSeam() {
    let model = OrbModel(count: 2_000)
    #expect(model.pitch.min()! < 0.01 && model.pitch.max()! > 0.99)
    // A dot's pitch is how far round from the +x meridian it is, whichever way round: mirror dots (z and
    // -z) agree, which is what leaves no seam.
    for (unit, pitch) in zip(model.unit, model.pitch) {
      #expect(abs(pitch - abs(atan2(unit.z, unit.x)) / .pi) < 1e-4)
    }
    let low = zip(model.unit, model.pitch).filter { $0.0.x > 0.9 }.map { $0.1 }
    let high = zip(model.unit, model.pitch).filter { $0.0.x < -0.9 }.map { $0.1 }
    #expect(!low.isEmpty && !high.isEmpty)
    #expect(low.max()! < 0.25 && high.min()! > 0.75)
  }
}
