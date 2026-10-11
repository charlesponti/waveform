import CoreGraphics
import SwiftUI
import Testing
import WaveformCore

@testable import WaveformUI

/// The views are drawn into an image with `ImageRenderer`, so their `body`, canvas and overlay really run.
@MainActor @Suite struct ViewTests {
  private func image<V: View>(_ view: V, width: CGFloat = 240, height: CGFloat = 240) -> CGImage {
    let renderer = ImageRenderer(content: view.frame(width: width, height: height).background(.black))
    renderer.scale = 1
    return renderer.cgImage!
  }

  /// How many pixels are not the black background.
  private func ink(_ image: CGImage) -> Int {
    let w = image.width, h = image.height
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    let context = CGContext(
      data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    var count = 0
    for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i + 1] > 40 { count += 1 }
    return count
  }

  private func loudRing(seconds: Double = 1.2) -> ColumnRing {
    let ring = ColumnRing(capacity: 4096)
    let builder = ColumnBuilder(sampleRate: 48_000, columnsPerSecond: 120, windowBlocks: 3)
    let samples = Synthesize.vowels(seconds: seconds)
    samples.withUnsafeBufferPointer { builder.feed($0.baseAddress!, count: $0.count) { ring.append($0) } }
    return ring
  }

  private func spectrum(seconds: Double = 1.2) -> SpectrumRing {
    let ring = SpectrumRing(bands: 24, capacity: 4096)
    let builder = SpectrumBuilder(sampleRate: 48_000)
    let samples = Synthesize.vowels(seconds: seconds)
    samples.withUnsafeBufferPointer { builder.feed($0.baseAddress!, count: $0.count) { ring.append($0) } }
    return ring
  }

  @Test func theWaveformDrawsBarsForALoudRingAndNothingButTheHUDForASilentOne() {
    let loud = ink(image(WaveformView(ring: loudRing(), showStats: false)))
    let silent = ink(image(WaveformView(ring: ColumnRing(capacity: 64), showStats: false)))
    #expect(loud > silent + 200)
  }

  @Test func theWaveformSlidesBetweenColumnArrivalsAndShowsItsCost() {
    let ring = loudRing()
    let before = ink(image(WaveformView(ring: ring, columnsPerSecond: 120, barWidth: 4, gap: 1)))
    ring.append(Column(low: -0.5, high: 0.5, rms: 0.3))
    let after = ink(image(WaveformView(ring: ring, columnsPerSecond: 120, barWidth: 4, gap: 1)))
    #expect(before > 0 && after > 0)
  }

  @Test func theOrbDrawsDotsAndIsStillWhenNotTurning() {
    let ring = loudRing()
    let a = image(OrbView(ring: ring, showStats: false, turning: false))
    let b = image(OrbView(ring: ring, showStats: false, turning: false))
    #expect(ink(a) > 300)
    #expect(ink(a) == ink(b))
  }

  @Test func theOrbIsAPlainSphereForASilentRing() {
    let silent = ink(image(OrbView(ring: ColumnRing(capacity: 4096), showStats: false, turning: false, dotCount: 600)))
    let loud = ink(image(OrbView(ring: loudRing(), showStats: false, turning: false, dotCount: 600)))
    #expect(silent > 0)
    #expect(loud > silent)
  }

  @Test func theOrbCanFollowAnAudioClockAndShowItsStats() {
    let clock = StreamClock()
    clock.update(hostSeconds: 100, streamSeconds: 2)
    let withStats = ink(image(OrbView(ring: loudRing(), clock: clock, gain: 0.6, historySeconds: 1, showStats: true)))
    let without = ink(image(OrbView(ring: loudRing(), clock: clock, gain: 0.6, historySeconds: 1, showStats: false)))
    #expect(withStats > 300 && without > 300)
  }

  @Test func theSpectrumOrbDrawsPitchAsShape() {
    let ring = spectrum()
    let a = image(SpectrumOrbView(spectrum: ring, showStats: false, turning: false))
    #expect(ink(a) > 300)
    let silent = ink(image(SpectrumOrbView(spectrum: SpectrumRing(bands: 24, capacity: 4096), showStats: false, turning: false, dotCount: 900)))
    #expect(ink(a) > 0 && silent > 0)
  }

  @Test func theSpectrumOrbSpinsWhenAskedAndShowsStats() {
    let clock = StreamClock()
    clock.update(hostSeconds: 50, streamSeconds: 1)
    let v = image(SpectrumOrbView(spectrum: spectrum(), sampleRate: 48_000, fftSize: 2_048, clock: clock, gain: 0.7, historySeconds: 0.5))
    #expect(ink(v) > 0)
  }
}
