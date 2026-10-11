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

  /// How far out a dot at `age` sits, and how big its peak was, from `columns` (oldest first).
  /// `slide` (0...1) is how far the next column has come toward arriving, so the ripple moves smoothly
  /// between columns instead of stepping.
  ///
  /// `radius` is 1 for silence and `1 + gain` at full scale. `peak` is 0...1.
  public static func sample(
    age: Float, columns: UnsafeBufferPointer<Column>, slide: Float, scale: Scale, gain: Float
  ) -> (radius: Float, peak: Float) {
    let n = columns.count
    guard n > 0 else { return (1, 0) }
    // Position in the history: 0 is the oldest column, n - 1 the newest.
    let position = max(0, Float(n - 1) - (age * Float(n - 1) + slide))
    let lower = Int(position)
    let upper = min(n - 1, lower + 1)
    let t = position - Float(lower)
    let a = columns[lower]
    let b = columns[upper]
    let rms = scale.height(a.rms) * (1 - t) + scale.height(b.rms) * t
    let peakA = max(abs(scale.height(a.high)), abs(scale.height(a.low)))
    let peakB = max(abs(scale.height(b.high)), abs(scale.height(b.low)))
    return (1 + gain * rms, peakA * (1 - t) + peakB * t)
  }
}
