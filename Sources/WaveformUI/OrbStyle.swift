import SwiftUI

/// How a `SpectrumOrbView` looks as it responds to sound, apart from what it hears. The defaults are
/// the orb as it has always drawn. Find yours in the design lab (`docs/lab`).
public struct OrbStyle: Equatable, Sendable {
  /// A dot's size in points when its pitch is silent.
  public var dotBase: Float
  /// How many points a dot grows by at full loudness.
  public var dotGrowth: Float
  /// Bends loudness before it moves a dot: above 1 keeps quiet pitches still and lets only the loud
  /// ones stand out, below 1 lifts the quiet ones.
  public var contrast: Float
  /// Opacity of each of the four depth layers, far to near.
  public var opacities: [Double]
  /// Radians a second the sphere turns by, when it is turning.
  public var spinRate: Float
  /// How far the sphere leans toward the viewer, in radians.
  public var tip: Float

  public init(
    dotBase: Float = 1.0, dotGrowth: Float = 2.8, contrast: Float = 1,
    opacities: [Double] = [0.18, 0.4, 0.7, 1.0], spinRate: Float = 0.12, tip: Float = 0.32
  ) {
    self.dotBase = dotBase
    self.dotGrowth = dotGrowth
    self.contrast = contrast
    self.opacities = opacities
    self.spinRate = spinRate
    self.tip = tip
  }

  /// A loudness from 0 to 1, after `contrast`.
  func shaped(_ level: Float) -> Float {
    contrast == 1 ? level : pow(level, contrast)
  }
}
