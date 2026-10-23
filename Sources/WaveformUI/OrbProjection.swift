import Foundation
import SwiftUI
import WaveformCore
import simd

/// Turns a point on the unit sphere into a point on screen, and batches the dots into four depth
/// layers so a frame is four fills however many dots there are. Pure maths, tested without a screen.
struct OrbProjection {
  private let sy: Float
  private let cy: Float
  private let sx: Float
  private let cx: Float

  /// `spin` turns the sphere about the vertical axis; `tip` tilts it toward the viewer so a pole can be seen.
  init(spin: Float, tip: Float) {
    (sy, cy) = (sin(spin), cos(spin))
    (sx, cx) = (sin(tip), cos(tip))
  }

  /// Where the dot at unit-sphere position `u`, pushed out to `out` times the radius, lands: x and y in
  /// units of the radius (y up), and `depth` 0 for far to 1 for near.
  func place(_ u: SIMD3<Float>, out: Float) -> (x: Float, y: Float, depth: Float) {
    let x1 = u.x * cy + u.z * sy
    let z1 = -u.x * sy + u.z * cy
    let y2 = u.y * cx - z1 * sx
    let z2 = u.y * sx + z1 * cx
    return (x1 * out, y2 * out, (z2 + 1) / 2)
  }

  /// Which of four layers (0 far ... 3 near) a depth belongs to.
  static func layer(depth: Float) -> Int { min(3, Int(depth * 4)) }

  /// Near dots are drawn a little larger than far ones.
  static func perspective(depth: Float) -> Float { 0.75 + 0.25 * depth }

  /// The radius in points that leaves room for a dot pushed out by `gain`.
  static func radius(in size: CGSize, gain: Float) -> Float {
    Float(min(size.width, size.height)) / 2 / (1 + gain) * 0.94
  }

  /// The angle to turn by at `time`: steadily at `rate` radians a second, or held at `still`.
  static func spin(turning: Bool, time: Double, rate: Float, still: Float) -> Float {
    turning ? Float(time) * rate : still
  }

  /// The opacity of each layer, far to near.
  static let opacities: [Double] = [0.18, 0.4, 0.7, 1.0]
}

/// Dots collected into depth layers, ready to fill.
struct DotLayers {
  private(set) var paths = [Path(), Path(), Path(), Path()]

  mutating func add(center: CGPoint, radius: CGFloat, layer: Int) {
    paths[layer].addEllipse(
      in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
  }

  func fill(
    in context: inout GraphicsContext, color: Color, opacities: [Double] = OrbProjection.opacities
  ) {
    for (path, opacity) in zip(paths, opacities) {
      context.fill(path, with: .color(color.opacity(opacity)))
    }
  }
}

/// Draws an orb: for each dot of `model`, `value(i)` says how far out it sits (`out`, 1 for silence)
/// and how large it is before perspective (`base`).
func drawOrbDots(
  _ context: inout GraphicsContext, size: CGSize, model: OrbModel, projection: OrbProjection,
  gain: Float, tint: Color, opacities: [Double] = OrbProjection.opacities,
  value: (Int) -> (out: Float, base: Float)
) {
  let radius = OrbProjection.radius(in: size, gain: gain)
  let center = SIMD2<Float>(Float(size.width) / 2, Float(size.height) / 2)
  var layers = DotLayers()
  for i in 0..<model.count {
    let (out, base) = value(i)
    let p = projection.place(model.unit[i], out: out)
    let dot = base * OrbProjection.perspective(depth: p.depth)
    layers.add(
      center: CGPoint(x: CGFloat(center.x + p.x * radius), y: CGFloat(center.y - p.y * radius)),
      radius: CGFloat(dot), layer: OrbProjection.layer(depth: p.depth))
  }
  layers.fill(in: &context, color: tint, opacities: opacities)
}
