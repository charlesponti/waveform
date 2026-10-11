import Foundation
import Testing
import simd

@testable import WaveformCore

@Suite struct OrbModelTests {
  private func radii(
    _ columns: [Column], slide: Float = 0, scale: Scale = .linear, gain: Float = 0.5, model: OrbModel
  ) -> [(radius: Float, peak: Float)] {
    columns.withUnsafeBufferPointer { buffer in
      model.age.map { OrbModel.sample(age: $0, columns: buffer, slide: slide, scale: scale, gain: gain) }
    }
  }

  @Test func everyDotIsOnTheSphereAndTheyAreEvenlySpread() {
    let model = OrbModel(count: 1_200)
    #expect(model.unit.allSatisfy { abs(simd_length($0) - 1) < 1e-5 })
    // Equal area on each side: half the dots in each hemisphere, and as many left as right.
    #expect(model.unit.filter { $0.y > 0 }.count == 600)
    let right = model.unit.filter { $0.x > 0 }.count
    #expect(abs(right - 600) < 40)
    // Ages cover the equator (0) to the poles (1).
    #expect(model.age.min()! < 0.01 && model.age.max()! > 0.95)
  }

  @Test func silenceIsAPlainSphere() {
    let model = OrbModel()
    let result = radii([Column](repeating: .silent, count: 48), model: model)
    #expect(result.allSatisfy { $0.radius == 1 && $0.peak == 0 })
  }

  @Test func theNewestSoundIsAtTheEquatorAndRipplesOutward() {
    let model = OrbModel(count: 2_000)
    // Quiet history, then one loud column at the end (the newest).
    var columns = [Column](repeating: .silent, count: 48)
    columns[47] = Column(low: -0.8, high: 0.8, rms: 0.6)
    let result = radii(columns, model: model)
    let farthest = zip(model.age, result).max { $0.1.radius < $1.1.radius }!
    let pole = zip(model.age, result).filter { $0.0 > 0.9 }.map { $0.1.radius }
    // The farthest dot is at the equator and is out by the loudness: 1 + gain * rms.
    #expect(farthest.0 < 0.002)
    #expect(abs(farthest.1.radius - (1 + 0.5 * 0.6)) < 0.005)
    #expect(pole.allSatisfy { $0 == 1 })
    // A little later the same sound has moved off the equator toward the poles.
    let later = radii(columns, slide: 1, model: model)
    let movedFarthest = zip(model.age, later).max { $0.1.radius < $1.1.radius }!
    #expect(movedFarthest.0 > 0.015)  // the peak has left the equator for older dots
  }

  @Test func betweenTwoColumnsTheRadiusIsTheMixOfBoth() {
    let model = OrbModel(count: 400)
    var columns = [Column](repeating: .silent, count: 10)
    columns[8] = Column(low: -0.4, high: 0.4, rms: 0.4)
    columns[9] = Column(low: -0.8, high: 0.8, rms: 0.8)
    // slide 0 at age 0 is the newest column; moving half a column back is the mean of the two.
    let a = columns.withUnsafeBufferPointer {
      OrbModel.sample(age: 0, columns: $0, slide: 0.5, scale: .linear, gain: 1)
    }
    #expect(abs(a.radius - (1 + 0.6)) < 1e-5)
    #expect(abs(a.peak - 0.6) < 1e-5)
  }

  @Test func theDecibelScaleMakesQuietSpeechVisible() {
    let model = OrbModel(count: 400)
    let quiet = [Column](repeating: Column(low: -0.01, high: 0.01, rms: 0.007), count: 24)
    let linear = radii(quiet, scale: .linear, model: model)[0].radius
    let decibel = radii(quiet, scale: .decibels(floor: -60), model: model)[0].radius
    #expect(decibel > linear + 0.1)
  }
}
