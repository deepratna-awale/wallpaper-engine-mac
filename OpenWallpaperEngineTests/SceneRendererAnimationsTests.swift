import XCTest
@testable import OpenWallpaperEngine

/// The renderer's side of the timelines (`SceneRendererAnimations`, docs/timeline-plan.md T3/T6):
/// what reaches the draw from the instance's `SceneAnimationSet`, at the frame boundary.
final class SceneRendererAnimationsTests: XCTestCase {
    private let alpha = SceneAnimationSite(owner: .object(1), key: "alpha")
    private let tint = SceneAnimationSite(owner: .material(object: 1, effect: 0, pass: 0), key: "tint")

    private func timelines(_ json: String) throws -> SceneRendererAnimations {
        let document = try JSONDecoder().decode(SceneJSON.self, from: Data(json.utf8))
        let timelines = SceneRendererAnimations()
        timelines.setTimelines(SceneTimelineSource(wallpaperID: "boundary", document: document, signature: ""), restart: true)
        return timelines
    }

    private static let fade = #"""
    {"objects": [{"id": 1,
      "alpha": {"value": 0.25, "animation": {"c0": [{"frame": 0, "value": 0}, {"frame": 60, "value": 1}],
                                              "options": {"fps": 60, "length": 60, "mode": "loop"}}},
      "effects": [{"passes": [{"constantshadervalues": {"tint": {"value": "0.5 0.5 0.5", "animation": {
        "c0": [{"frame": 0, "value": 0}, {"frame": 60, "value": 1}],
        "options": {"fps": 60, "length": 60, "mode": "loop"}}}}}]}]}]}
    """#

    /// TF6: WE keeps a NaN or infinite clock for good, and scripts see it, but the draw gets the
    /// property's static value until the clock is finite again.
    func testANonFiniteClockNeverReachesTheDraw() throws {
        let timelines = try timelines(Self.fade)
        let set = try XCTUnwrap(timelines.set)
        for poison: SceneAnimationControl in [.setFrame(.nan), .setFrame(.infinity), .setRate(.infinity)] {
            set.perform(poison, on: alpha)
            set.perform(poison, on: tint)
            for _ in 0..<3 { _ = timelines.advance(by: 1 / 60) }
            XCTAssertNil(timelines.object("1")?.alpha, "\(poison): the layer draws its own alpha")
            XCTAssertNil(timelines.values.animationValue(tint), "\(poison): the constant draws its own value")
            XCTAssertEqual(SceneValueResolver.resolve(.animation(site: tint, fallback: .literal(ShaderValue(components: [0.5]))),
                                                      in: timelines.values), ShaderValue(components: [0.5]))
            XCTAssertFalse(set.state(of: alpha)?.value.x.isFinite ?? true, "\(poison): scripts see WE's value")
            set.perform(.setRate(1), on: alpha)
            set.perform(.setRate(1), on: tint)
            set.perform(.stop, on: alpha)
            set.perform(.stop, on: tint)
            set.perform(.play, on: alpha)
            set.perform(.play, on: tint)
            _ = timelines.advance(by: 1 / 60)
            XCTAssertEqual(try XCTUnwrap(timelines.object("1")?.alpha), 1 / 60, accuracy: 1e-4, "\(poison): stop() recovers")
            XCTAssertEqual(try XCTUnwrap(timelines.values.animationValue(tint)?.first), 1 / 60, accuracy: 1e-4)
        }
    }
}
