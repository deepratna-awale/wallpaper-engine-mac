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

    private static let reveal = #"""
    {"objects": [{"id": 1,
      "alpha": {"value": 1, "animation": {"c0": [{"frame": 0, "value": 0}, {"frame": 60, "value": 1}],
                                          "options": {"fps": 60, "length": 60, "mode": "single", "startpaused": true,
                                                      "events": [{"name": "half", "frame": 3}]}}}}]}
    """#

    /// TL3: a script frame that overran the draw's wait brings its calls back after one more
    /// advance; the set replays that advance on the restored clock, so the clock, the drawn value
    /// and the events are those of a script frame that came back in time.
    func testAScriptFrameThatComesBackLateLosesNoAdvance() throws {
        let delta: Float = 1 / 60
        let onTime = try timelines(Self.reveal), late = try timelines(Self.reveal)
        for timelines in [onTime, late] { _ = timelines.advance(by: delta) }
        let seen = try XCTUnwrap(late.set?.frameCounter)
        // `play()` in the script frame that saw `seen`; on time it comes back before the next advance.
        onTime.restore(alpha, time: 0, flags: [], rate: 1, seenAt: seen)
        var onTimeEvents = onTime.advance(by: delta)
        var lateEvents = late.advance(by: delta)
        late.restore(alpha, time: 0, flags: [], rate: 1, seenAt: seen)
        XCTAssertEqual(late.set?.state(of: alpha)?.time, onTime.set?.state(of: alpha)?.time, "the missed advance is replayed")
        XCTAssertEqual(late.object("1")?.alpha, onTime.object("1")?.alpha, "and drawn this frame")
        for _ in 0..<4 {
            onTimeEvents += onTime.advance(by: delta)
            lateEvents += late.advance(by: delta)
        }
        XCTAssertEqual(late.set?.state(of: alpha), onTime.set?.state(of: alpha))
        XCTAssertEqual(lateEvents.map(\.name), onTimeEvents.map(\.name))
        XCTAssertEqual(onTimeEvents.map(\.name), ["half"])
    }

    private static let sheet = #"{"objects": [{"id": 1}, {"id": 2}]}"#

    /// TF5, TL8: a layer's texture override moves with the frame (WE steps it in the image layer's
    /// update), once per frame however often it is drawn, and while nothing draws it; the shared
    /// clock moves only when a layer draws the texture. A late script frame's override is replayed.
    func testTextureOverridesMoveWithTheFrameAndSharedClocksWhenDrawn() throws {
        let timelines = try timelines(Self.sheet)
        let set = try XCTUnwrap(timelines.set)
        for id in [1, 2] { timelines.registerTexture(object: id, texture: "materials/sheet.tex", frameTimes: [0.1, 0.1, 0.1, 0.1]) }
        XCTAssertTrue(set.textures.perform(.setFrame(0), object: 2))
        for _ in 0..<3 {
            _ = timelines.advance(by: 0.1)
            XCTAssertEqual(timelines.spriteFrame(object: 1, delta: 0.1), timelines.spriteFrame(object: 1, delta: 0.1))
        }
        XCTAssertEqual(set.textures.state(object: 1)?.sharedFrame, 3, "drawn three times")
        XCTAssertEqual(set.textures.state(object: 2)?.control.frame, 3, "never drawn, still moved")
        for _ in 0..<2 { _ = timelines.advance(by: 0.1) }
        XCTAssertEqual(set.textures.state(object: 1)?.sharedFrame, 3, "nobody drew the texture")
        XCTAssertEqual(set.textures.state(object: 2)?.control.frame, 1)

        let seen = set.frameCounter
        _ = timelines.advance(by: 0.1)
        var control = SceneTextureAnimationControl()
        control.setFrame(0)
        timelines.restoreTexture(control, object: 2, seenAt: seen)
        XCTAssertEqual(timelines.spriteFrame(object: 2, delta: 0.1), 1, "setFrame(0) a frame ago, one frame on")
    }
}
