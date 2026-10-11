import Foundation
import Testing
import simd

@testable import WaveformCore

@Suite struct OrbModelTests {
  /// Reads every dot of `model` from `columns` (absolute index 0 is the first), with the playhead at `playhead`.
  private func radii(
    _ columns: [Column], playhead: Double, history: Double = 47, scale: Scale = .linear,
    gain: Float = 0.5, model: OrbModel
  ) -> [(radius: Float, peak: Float)] {
    columns.withUnsafeBufferPointer { buffer in
      let window = ColumnWindow(columns: buffer, base: 0)
      return model.age.map {
        OrbModel.sample(
          age: $0, window: window, playhead: playhead, history: history, scale: scale, gain: gain)
      }
    }
  }

  @Test func everyDotIsOnTheSphereAndTheyAreEvenlySpread() {
    let model = OrbModel(count: 1_200)
    #expect(model.unit.allSatisfy { abs(simd_length($0) - 1) < 1e-5 })
    #expect(model.unit.filter { $0.y > 0 }.count == 600)
    let right = model.unit.filter { $0.x > 0 }.count
    #expect(abs(right - 600) < 40)
    #expect(model.age.min()! < 0.01 && model.age.max()! > 0.95)
  }

  @Test func silenceIsAPlainSphere() {
    let model = OrbModel()
    let result = radii([Column](repeating: .silent, count: 48), playhead: 47, model: model)
    #expect(result.allSatisfy { $0.radius == 1 && $0.peak == 0 })
  }

  @Test func theNewestSoundIsAtTheEquatorAndRipplesOutward() {
    let model = OrbModel(count: 2_000)
    var columns = [Column](repeating: .silent, count: 60)
    columns[47] = Column(low: -0.8, high: 0.8, rms: 0.6)
    let result = radii(columns, playhead: 47, model: model)
    let farthest = zip(model.age, result).max { $0.1.radius < $1.1.radius }!
    let pole = zip(model.age, result).filter { $0.0 > 0.9 }.map { $0.1.radius }
    // The farthest dot is at the equator and is out by the loudness: 1 + gain * level.
    #expect(farthest.0 < 0.002)
    #expect(abs(farthest.1.radius - (1 + 0.5 * 0.6)) < 0.005)
    #expect(pole.allSatisfy { $0 == 1 })
    // Two columns on, the same sound has moved off the equator toward the poles.
    let later = radii(columns, playhead: 49, model: model)
    let moved = zip(model.age, later).max { $0.1.radius < $1.1.radius }!
    #expect(moved.0 > 0.03)
  }

  @Test func aRampStaysARampBetweenColumns() {
    // Catmull-Rom reproduces a straight line exactly, so a steady swell is drawn as a steady swell.
    let columns = [0.2, 0.4, 0.6, 0.8, 1.0].map { Column(low: -$0, high: $0, rms: Float($0)) }
    columns.withUnsafeBufferPointer { buffer in
      let window = ColumnWindow(columns: buffer, base: 0)
      for position in stride(from: 1.0, through: 2.0, by: 0.125) {
        let got = window.value(at: position, scale: .linear).level
        #expect(abs(got - Float(0.2 + 0.2 * position)) < 1e-5, "at \(position)")
      }
    }
  }

  @Test func itPassesThroughEveryColumnAndHasNoCorners() {
    let levels: [Float] = [0, 0.1, 0.7, 0.2, 0.9, 0.3, 0.3, 0.8, 0]
    let columns = levels.map { Column(low: -$0, high: $0, rms: $0) }
    columns.withUnsafeBufferPointer { buffer in
      let window = ColumnWindow(columns: buffer, base: 0)
      let eps = 1e-3
      for k in 2..<(levels.count - 3) {
        let at = window.value(at: Double(k), scale: .linear).level
        #expect(abs(at - levels[k]) < 1e-5)
        // The slope just before and just after a column agree: no corner there.
        let before = (at - window.value(at: Double(k) - eps, scale: .linear).level) / Float(eps)
        let after = (window.value(at: Double(k) + eps, scale: .linear).level - at) / Float(eps)
        #expect(abs(before - after) < 0.01, "corner at \(k)")
      }
    }
  }

  @Test func theDecibelScaleMakesQuietSpeechVisible() {
    let model = OrbModel(count: 400)
    let quiet = [Column](repeating: Column(low: -0.01, high: 0.01, rms: 0.007), count: 60)
    let linear = radii(quiet, playhead: 50, scale: .linear, model: model)[0].radius
    let decibel = radii(quiet, playhead: 50, scale: .decibels(floor: -60), model: model)[0].radius
    #expect(decibel > linear + 0.1)
  }
}
