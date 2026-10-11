import Foundation
import Testing

@testable import WaveformCore

@Suite struct SynthesizeTests {
  private func peak(_ x: ArraySlice<Float>) -> Float { x.map { abs($0) }.max() ?? 0 }

  @Test func speechLikeHasTheRightLengthIsQuietAndRepeatable() {
    let a = Synthesize.speechLike(seconds: 2, sampleRate: 16_000)
    #expect(a.count == 32_000)
    #expect(peak(a[...]) <= 0.45)
    #expect(peak(a[...]) > 0.1)
    #expect(a == Synthesize.speechLike(seconds: 2, sampleRate: 16_000))
  }

  @Test func speechLikeHasGapsBetweenWords() {
    let a = Synthesize.speechLike(seconds: 4, sampleRate: 8_000)
    let silent = stride(from: 0, to: a.count - 80, by: 80).filter { peak(a[$0..<$0 + 80]) < 1e-6 }
    #expect(silent.count > 5)
  }

  @Test func theDefaultSampleRateIs48k() {
    #expect(Synthesize.speechLike(seconds: 0.5).count == 24_000)
    #expect(Synthesize.vowels(seconds: 0.5).count == 24_000)
  }

  @Test func vowelsAreRepeatableAndGatedIntoWords() {
    let a = Synthesize.vowels(seconds: 4, sampleRate: 16_000)
    #expect(a == Synthesize.vowels(seconds: 4, sampleRate: 16_000))
    #expect(peak(a[...]) > 0.05)
    let silent = stride(from: 0, to: a.count - 160, by: 160).filter { peak(a[$0..<$0 + 160]) < 1e-6 }
    #expect(silent.count > 5)
  }
}
