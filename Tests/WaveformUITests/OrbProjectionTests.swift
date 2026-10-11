import SwiftUI
import Testing
import WaveformCore
import simd

@testable import WaveformUI

@Suite struct OrbProjectionTests {
  private let flat = OrbProjection(spin: 0, tip: 0)

  @Test func aDotFacingTheViewerIsInTheMiddleAndNear() {
    let p = flat.place(SIMD3(0, 0, 1), out: 1)
    #expect(abs(p.x) < 1e-6 && abs(p.y) < 1e-6)
    #expect(abs(p.depth - 1) < 1e-6)
  }

  @Test func aDotOnTheRimIsOneRadiusOutAndHalfwayDeep() {
    let p = flat.place(SIMD3(1, 0, 0), out: 1)
    #expect(abs(p.x - 1) < 1e-6)
    #expect(abs(p.depth - 0.5) < 1e-6)
  }

  @Test func pushingADotOutScalesItsPositionButNotItsDepth() {
    let a = flat.place(SIMD3(0.6, 0.8, 0), out: 1)
    let b = flat.place(SIMD3(0.6, 0.8, 0), out: 1.5)
    #expect(abs(b.x - 1.5 * a.x) < 1e-6 && abs(b.y - 1.5 * a.y) < 1e-6)
    #expect(abs(b.depth - a.depth) < 1e-6)
  }

  @Test func spinningAQuarterTurnCarriesTheRimToTheBack() {
    let p = OrbProjection(spin: .pi / 2, tip: 0).place(SIMD3(1, 0, 0), out: 1)
    #expect(abs(p.x) < 1e-5)
    #expect(abs(p.depth) < 1e-5)
  }

  @Test func tippingAQuarterTurnBringsAPoleToTheViewer() {
    let p = OrbProjection(spin: 0, tip: .pi / 2).place(SIMD3(0, 1, 0), out: 1)
    #expect(abs(p.y) < 1e-5)
    #expect(abs(p.depth - 1) < 1e-5)
  }

  @Test func spinningKeepsEveryDotOnTheSphere() {
    let model = OrbModel(count: 200)
    let projection = OrbProjection(spin: 1.3, tip: 0.35)
    for u in model.unit {
      let p = projection.place(u, out: 1)
      let z = 2 * p.depth - 1
      #expect(abs(p.x * p.x + p.y * p.y + z * z - 1) < 1e-4)
    }
  }

  @Test func depthsFallIntoFourLayers() {
    #expect(OrbProjection.layer(depth: 0) == 0)
    #expect(OrbProjection.layer(depth: 0.24) == 0)
    #expect(OrbProjection.layer(depth: 0.25) == 1)
    #expect(OrbProjection.layer(depth: 0.6) == 2)
    #expect(OrbProjection.layer(depth: 0.99) == 3)
    #expect(OrbProjection.layer(depth: 1) == 3)
  }

  @Test func nearDotsAreLarger() {
    #expect(OrbProjection.perspective(depth: 0) == 0.75)
    #expect(OrbProjection.perspective(depth: 1) == 1)
  }

  @Test func theRadiusLeavesRoomForTheDotsThatPushOut() {
    let r = OrbProjection.radius(in: CGSize(width: 200, height: 100), gain: 0.5)
    #expect(abs(r - 50 / 1.5 * 0.94) < 1e-4)
    #expect(OrbProjection.radius(in: CGSize(width: 100, height: 200), gain: 0.5) == r)
  }

  @Test func spinTurnsAtTheRateOrHoldsStill() {
    #expect(OrbProjection.spin(turning: true, time: 10, rate: 0.5, still: 9) == 5)
    #expect(OrbProjection.spin(turning: false, time: 10, rate: 0.5, still: 9) == 9)
  }

  @Test func theLayerOpacitiesGoFromFaintToSolid() {
    #expect(OrbProjection.opacities == OrbProjection.opacities.sorted())
    #expect(OrbProjection.opacities.last == 1)
  }

  @Test func dotsGoIntoTheLayerTheyAreGiven() {
    var layers = DotLayers()
    layers.add(center: CGPoint(x: 10, y: 10), radius: 2, layer: 2)
    #expect(layers.paths[2].boundingRect == CGRect(x: 8, y: 8, width: 4, height: 4))
    #expect(layers.paths[0].isEmpty && layers.paths[1].isEmpty && layers.paths[3].isEmpty)
  }
}
