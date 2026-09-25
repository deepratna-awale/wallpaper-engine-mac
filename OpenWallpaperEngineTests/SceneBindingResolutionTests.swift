import XCTest
@testable import OpenWallpaperEngine

private struct PropertyContext: SceneValueContext {
    var properties: [String: String] = [:]
    var time: Double = 0
    func userProperty(_ name: String) -> String? { properties[name] }
    func evaluateScript(_ source: String, properties: SceneScriptProperties, current: ShaderValue) -> ShaderValue? { nil }
}

/// Bound values follow the user properties they're bound to.
final class SceneBindingResolutionTests: XCTestCase {
    private func loadScene() throws -> WEScene {
        try decodeTolerant(WEScene.self, from: Fixtures.data("Scenes/bindings/scene.json"))
    }

    func testObjectFieldsFollowTheirProperties() throws {
        let object = try loadScene().objects[0]
        let context = PropertyContext(properties: ["pos": "300 400 0", "size": "0.5", "color": "0 1 0",
                                                   "mode": "2", "brightness": "0.25"])
        let resolved = object.resolvingUserBindings(in: context)
        XCTAssertEqual(resolved.origin, "300 400 0")
        XCTAssertEqual(resolved.scale, "0.5 0.5 0.5", "a scalar slider scales every axis")
        XCTAssertEqual(resolved.color, "0 1 0")
        XCTAssertEqual(resolved.alpha, 1, "condition '2' matches")
        XCTAssertEqual(resolved.brightness, 0.25)
        XCTAssertEqual(resolved.angles, "0 0 0.5", "unbound fields keep their literal")

        let hidden = object.resolvingUserBindings(in: PropertyContext(properties: ["mode": "1"]))
        XCTAssertEqual(hidden.alpha, 0, "condition '2' doesn't match")
        XCTAssertEqual(hidden.color, "1 0.5 0.25", "missing properties keep the literal")
    }

    func testTextPointSizeAndScriptProperties() throws {
        let object = try loadScene().objects[1]
        let context = PropertyContext(properties: ["caption": "Hello there", "fontsize": "64", "ylensy": "0.7"])
        let resolved = object.resolvingUserBindings(in: context)
        XCTAssertEqual(resolved.textValue, "Hello there")
        XCTAssertEqual(resolved.pointsize, 64)
        XCTAssertEqual(resolved.originScriptProperties, ["speed": "0.7", "label": "hi", "on": "true"])

        let outer = object.resolvingUserBindings(in: PropertyContext(properties: ["ylensy1": "3", "ylensy": "0.7"]))
        XCTAssertEqual(outer.originScriptProperties["speed"], "3", "the outer binding wins")
        XCTAssertEqual(object.resolvingUserBindings(in: PropertyContext()).textValue, "Default caption")
    }

    func testLayerBindingsApplyChangesSinceBuild() throws {
        let object = try loadScene().objects[0]
        let built = PropertyContext(properties: ["pos": "100 200 0", "size": "0.2", "color": "1 0.5 0.25",
                                                 "mode": "2", "brightness": "1.5"])
        let bindings = SceneLayerBindings(object: object, builtWith: built)
        // A layer as built: its position includes a parent offset of (10, 10).
        let layer = SceneMetalLayer(id: "1", name: "Tinted", source: .image(NSImage()), position: SIMD2(110, 210),
                                    size: SIMD2(200, 200), scale: SIMD2(0.2, 0.2), scaleScript: nil, scaleAnimation: nil,
                                    opacity: 1, opacityScript: nil, opacityAnimation: nil, brightness: 1.5, brightnessScript: nil,
                                    color: SIMD4(1, 0.5, 0.25, 1), colorScript: nil, text: nil, parallaxDepth: .zero,
                                    perspective: false, positionScript: nil, positionScriptProperties: [:],
                                    positionAnimation: nil, sizeScript: nil, sizeAnimation: nil, rotation: 0.5,
                                    rotationScript: nil, rotationAnimation: nil,
                                    effects: SceneMaterialEffects(brightness: 1, contrast: 1, saturation: 1, bloom: 0, blur: 0,
                                                                  exposure: 0, gamma: 1, hue: 0, bloomThreshold: 0.7,
                                                                  transformAngle: 0, transformOffset: .zero,
                                                                  transformScale: SIMD2(1, 1), scripts: [:]))
        XCTAssertEqual(bindings.baseValues(for: layer, in: built), SceneLayerBaseValues(layer))

        var changed = built
        changed.properties.merge(["pos": "150 200 0", "size": "0.4", "color": "0.5 0.5 0.5", "mode": "0",
                                  "brightness": "0.75"]) { $1 }
        let base = bindings.baseValues(for: layer, in: changed)
        XCTAssertEqual(base.position, SIMD2(160, 210), "origin moves by the change, keeping the parent offset")
        XCTAssertEqual(base.scale.x, 0.4, accuracy: 1e-5)
        XCTAssertEqual(base.color.x, 0.5, accuracy: 1e-5)
        XCTAssertEqual(base.color.z, 0.5, accuracy: 1e-5)
        XCTAssertEqual(base.opacity, 0)
        XCTAssertEqual(base.brightness, 0.75, accuracy: 1e-5)
        XCTAssertEqual(base.rotation, 0.5, "angles isn't bound")
    }

    func testParticleOverridesResolveBindings() throws {
        let object = try loadScene().objects[2]
        let defaults = SceneParticleOverrides(object.instanceoverride, in: PropertyContext())
        XCTAssertEqual(defaults.rate, 0.58, accuracy: 1e-5)
        XCTAssertEqual(defaults.rateScript, "export function update(v) { return v; }")
        XCTAssertEqual(defaults.count, 0.1, accuracy: 1e-5)
        XCTAssertEqual(defaults.size, 1.5)
        XCTAssertEqual(defaults.alpha, 0.5)
        XCTAssertEqual(defaults.lifetime, 2)
        XCTAssertEqual(defaults.speed, 3)
        XCTAssertEqual(defaults.tint, SIMD3(1, 0.5, 0.25))

        let bound = SceneParticleOverrides(object.instanceoverride,
                                           in: PropertyContext(properties: ["snowamount": "0.8", "flakesize": "2"]))
        XCTAssertEqual(bound.count, 0.8, accuracy: 1e-5)
        XCTAssertEqual(bound.size, 2)
        XCTAssertEqual(SceneParticleOverrides(nil, in: PropertyContext()), SceneParticleOverrides())
    }

    func testGeneralBloomAndCameraFollowProperties() throws {
        let general = try loadScene().general
        let off = SceneBloomSettings(general, in: PropertyContext(properties: ["bloomon": "false"]))
        XCTAssertFalse(off.enabled)
        let on = SceneBloomSettings(general, in: PropertyContext(properties: ["bloomcut": "0.9"]))
        XCTAssertTrue(on.enabled)
        XCTAssertEqual(on.strength, 2)
        XCTAssertEqual(on.threshold, 0.9, accuracy: 1e-5)

        let camera = SceneCameraEffects(general, in: PropertyContext(properties: ["lensshake": "true", "parallax": "1"]))
        XCTAssertTrue(camera.shake)
        XCTAssertEqual(camera.shakeAmplitude, 3)
        XCTAssertEqual(camera.shakeSpeed, 0.6, accuracy: 1e-5)
        XCTAssertTrue(camera.parallax)
        XCTAssertEqual(camera.parallaxMouseInfluence, 0.4, accuracy: 1e-5)
        XCTAssertFalse(SceneCameraEffects(general, in: PropertyContext()).shake)
    }
}
