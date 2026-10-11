import Foundation

/// A made-up voice for tests and pictures: a few harmonics of a changing pitch, shaped by a rhythm of
/// syllables with gaps between words. Not speech, but it moves like it, and it is the same every time.
public enum Synthesize {
  public static func speechLike(seconds: Double, sampleRate: Double = 48_000) -> [Float] {
    let count = Int(seconds * sampleRate)
    var out = [Float](repeating: 0, count: count)
    var phase = 0.0
    for i in 0..<count {
      let t = Double(i) / sampleRate
      let pitch = 120 + 25 * sin(2 * .pi * 0.7 * t) + 10 * sin(2 * .pi * 3.1 * t)
      phase += 2 * .pi * pitch / sampleRate
      let voice =
        sin(phase) + 0.5 * sin(2 * phase) + 0.3 * sin(3 * phase) + 0.15 * sin(5 * phase)
      let syllable = pow(max(0, sin(2 * .pi * 3.6 * t)), 1.5)
      let word = 0.5 + 0.5 * sin(2 * .pi * 0.45 * t - 0.5)
      let gate = word > 0.35 ? 1.0 : 0.0
      out[i] = Float(0.45 * voice * syllable * gate * (0.55 + 0.45 * word) / 1.95)
    }
    return out
  }
}

extension Synthesize {
  /// A made-up voice with vowels, so a spectrum has something to show: a harmonic buzz at a drifting
  /// pitch, shaped by two resonances (formants) that move from "ah" through "ee" to "oo", and gated into
  /// syllables and words like `speechLike`. Not speech, but it looks like it in a spectrogram.
  public static func vowels(seconds: Double, sampleRate: Double = 48_000) -> [Float] {
    let count = Int(seconds * sampleRate)
    var out = [Float](repeating: 0, count: count)
    // (F1, F2) in Hz for ah, ee, oo, and back.
    let targets: [(Double, Double)] = [(700, 1_200), (300, 2_300), (320, 800), (700, 1_200)]
    func resonance(_ f: Double, _ centre: Double, _ width: Double) -> Double {
      1 / (1 + pow((f - centre) / width, 2))
    }
    let block = 480  // the vowel is recomputed every 10 ms
    var phases = [Double](repeating: 0, count: 40)
    var gains = [Double](repeating: 0, count: 40)
    for start in stride(from: 0, to: count, by: block) {
      let t = Double(start) / sampleRate
      let position = (t * 0.55).truncatingRemainder(dividingBy: 3)
      let index = Int(position)
      let mix = position - Double(index)
      let f1 = targets[index].0 * (1 - mix) + targets[index + 1].0 * mix
      let f2 = targets[index].1 * (1 - mix) + targets[index + 1].1 * mix
      let pitch = 118 + 22 * sin(2 * .pi * 0.6 * t) + 8 * sin(2 * .pi * 3.1 * t)
      for h in 1...39 {
        let f = pitch * Double(h)
        gains[h] = (resonance(f, f1, 110) + 0.7 * resonance(f, f2, 180)) / Double(h).squareRoot() * (f < 7_500 ? 1 : 0)
      }
      for i in start..<min(count, start + block) {
        var sample = 0.0
        let tt = Double(i) / sampleRate
        let p = 118 + 22 * sin(2 * .pi * 0.6 * tt) + 8 * sin(2 * .pi * 3.1 * tt)
        for h in 1...39 {
          phases[h] += 2 * .pi * p * Double(h) / sampleRate
          sample += gains[h] * sin(phases[h])
        }
        let syllable = pow(max(0, sin(2 * .pi * 3.2 * tt)), 1.2)
        let word = 0.5 + 0.5 * sin(2 * .pi * 0.45 * tt - 0.5)
        out[i] = Float(0.09 * sample * syllable * (word > 0.3 ? 1 : 0) * (0.5 + 0.5 * word))
      }
    }
    return out
  }
}
