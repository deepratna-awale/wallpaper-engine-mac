import XCTest
import simd
@testable import OpenWallpaperEngine

/// A light's fields and out-of-plane transform are read every frame, as WE's packer reads the
/// light's live properties (0x140190c80, 0x14025d1f0; test-risks LR2, LF2): a script's value wins,
/// then the field's timeline, then the value the content was built with.
final class SceneLightLiveValuesTests: XCTestCase {
    private func legacyPoint(id: String, intensity: Float, originZ: Float) -> SceneLightObject {
        var light = SceneLight(kind: .legacyPoint)
        light.color = SIMD3(1, 0.5, 0.25)
        light.intensity = intensity
        light.radius = 2048
        return SceneLightObject(id: id, authored: WESceneLight(kind: .legacyPoint), light: light,
                                depth: SceneLightDepth(originZ: originZ))
    }

    /// A script-owned object row with `fields` set.
    private func scripted(_ fields: [SceneScriptObjectField: [Float]]) -> SceneScriptObjectState {
        var state = SceneScriptObjectState(values: [Float](repeating: 0, count: SceneScriptObjectTable.Layout.stride))
        for (field, value) in fields {
            state.owned.insert(field)
            for (index, component) in value.enumerated() { state.values[field.offset + index] = component }
        }
        return state
    }

    private func input(live: ((SceneLightObject) -> SceneLightObject)?) -> SceneFrameLightingInput {
        let local = SceneLocalTransform(origin: SIMD2(100, 500), scale: SIMD2(repeating: 1), angle: 0)
        return SceneFrameLightingInput(local: { _ in local }, parentWorld: { _ in .identity }, isVisible: { _ in true },
                                       sceneColor: { _ in nil }, live: live, eyePosition: .zero,
                                       viewForward: SIMD3(0, 0, -1))
    }

    /// The Knight's light 29: scripts on `intensity` and `origin` (y and z). The legacy arrays
    /// take the script's intensity and `origin.z`.
    func testScriptedIntensityAndOriginZReachTheLegacyArrays() {
        var content = SceneLightingContent()
        content.lights = [legacyPoint(id: "29", intensity: 1, originZ: 588)]
        let script = scripted([.intensity: [1.4], .origin: [100, 500, 650]])
        let lighting = SceneFrameLighting.frame(content, input: input(live: {
            $0.live(script: script, animation: nil, timeline: { _ in nil })
        }))
        let colorRadius = Array(lighting.arrays["g_LightsColorRadius"]!.prefix(4))
        XCTAssertEqual(colorRadius, [1.4, 0.7, 0.35, 2048].map { Float($0) })
        XCTAssertEqual(lighting.arrays["g_LightsPosition"]![2], 650, "origin.z from the script")
        XCTAssertEqual(lighting.objects.first?.light?.intensity, 1.4, "the volumetrics see the live light")
    }

    /// Without a script or timeline the content's light is packed as built.
    func testAnUnscriptedLightKeepsItsBuiltValues() {
        var content = SceneLightingContent()
        content.lights = [legacyPoint(id: "33", intensity: 1.23, originZ: 331)]
        let lighting = SceneFrameLighting.frame(content, input: input(live: {
            $0.live(script: nil, animation: nil, timeline: { _ in nil })
        }))
        XCTAssertEqual(lighting.arrays["g_LightsColorRadius"]![0], 1.23, accuracy: 1e-6)
        XCTAssertEqual(lighting.arrays["g_LightsPosition"]![2], 331)
    }

    /// A timeline on `intensity` and one on `color`, and a script on a tube's `controlpoint`
    /// (the plan's adversarial fixture): the script beats the timeline.
    func testTimelinesAndScriptsOnTubeFields() {
        var tube = SceneLight(kind: .tube)
        tube.color = SIMD3(repeating: 1)
        tube.intensity = 10
        tube.radius = 500
        var content = SceneLightingContent()
        content.settings.lightConfig = WELightConfig(tube: 1)
        content.lights = [SceneLightObject(id: "5", authored: WESceneLight(kind: .tube), light: tube,
                                           depth: SceneLightDepth(originZ: 250), hasTimelines: true)]
        var animation = SceneObjectAnimation()
        animation.color = SIMD3(0.5, 0.5, 1)
        let script = scripted([.controlpoint: [0, 100, 0], .intensity: [4]])
        let timelineOnly = SceneFrameLighting.frame(content, input: input(live: {
            $0.live(script: nil, animation: animation, timeline: { $0 == "intensity" ? SIMD4(2, 0, 0, 0) : nil })
        }))
        XCTAssertEqual(Array(timelineOnly.arrays["g_LTube_Color"]!.prefix(4)), [1, 1, 2, 500], "colour × timeline intensity")
        let both = SceneFrameLighting.frame(content, input: input(live: {
            $0.live(script: script, animation: animation, timeline: { $0 == "intensity" ? SIMD4(2, 0, 0, 0) : nil })
        }))
        XCTAssertEqual(Array(both.arrays["g_LTube_Color"]!.prefix(4)), [2, 2, 4, 500], "the script's intensity wins")
        XCTAssertEqual(Array(both.arrays["g_LTube_OriginB"]!.prefix(3)), [100, 600, 250], "world(controlpoint)")
    }
}
