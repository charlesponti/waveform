import Foundation
import simd

/// An orb of dots whose shape is the last second or so of a voice.
///
/// The dots sit evenly on a sphere (a Fibonacci lattice). Where a dot is up or down the sphere says how
/// old a sound it shows: the equator is the newest column, and older ones sit further toward the poles,
/// so each new sound appears as a ring at the equator that ripples out to both poles as it ages.
/// A dot pushes out from the sphere by how loud its sound was (the column's `rms`), and is drawn larger
/// by how high its peak was. Nothing is made up: a quiet moment is a plain sphere, and a loud one
/// is as far out as its loudness says, on the same decibel scale as the bars.
public struct OrbModel: Sendable {
  public let count: Int
  /// Each dot's place on the unit sphere. y is up.
  public let unit: [SIMD3<Float>]
  /// 0 at the equator (the newest sound) to 1 at a pole (the oldest).
  public let age: [Float]

  public init(count: Int = 1_200) {
    precondition(count > 1)
    self.count = count
    var unit: [SIMD3<Float>] = []
    var age: [Float] = []
    unit.reserveCapacity(count)
    age.reserveCapacity(count)
    let golden = Float.pi * (3 - Float(5).squareRoot())
    for i in 0..<count {
      // Evenly spaced heights, each turned a golden angle from the last: no clumps, no rows.
      let y = 1 - 2 * (Float(i) + 0.5) / Float(count)
      let ring = (1 - y * y).squareRoot()
      let angle = golden * Float(i)
      unit.append(SIMD3(cos(angle) * ring, y, sin(angle) * ring))
      age.append(abs(asin(y)) / (.pi / 2))
    }
    self.unit = unit
    self.age = age
  }

  /// How far out a dot at `age` sits, and how big its peak was.
  ///
  /// `window` holds recent columns; `playhead` is the (fractional) column that is "now" on screen and
  /// `history` is how many columns the orb spans, so a dot at `age` shows the sound `age * history`
  /// columns before the playhead. `radius` is 1 for silence and `1 + gain` at full scale; `peak` is 0...1.
  public static func sample(
    age: Float, window: ColumnWindow, playhead: Double, history: Double, scale: Scale, gain: Float
  ) -> (radius: Float, peak: Float) {
    let value = window.value(at: playhead - Double(age) * history, scale: scale)
    return (1 + gain * value.level, value.peak)
  }
}
