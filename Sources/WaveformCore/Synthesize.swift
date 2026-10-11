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
