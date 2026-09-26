import XCTest
import simd
@testable import OpenWallpaperEngine

/// `SceneScriptWallpaper` without a renderer (docs/scenescript-plan.md WP11): what the renderer
/// feeds in reaches the scripts, and what scripts write comes back as state and events.
final class SceneScriptWallpaperTests: XCTestCase {
    private var storage: URL!

    override func setUpWithError() throws {
        storage = FileManager.default.temporaryDirectory.appending(path: "owe-wallpaper-scripts-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let storage, FileManager.default.fileExists(atPath: storage.path) {
            try FileManager.default.removeItem(at: storage)
        }
    }

    // MARK: - State

    /// Only the fields a script writes become the table's; the others stay the renderer's, and
    /// scripts read the renderer's live values (§1.9 P2).
    func testScriptsOwnWhatTheyWriteAndReadTheRenderersValues() throws {
        let wallpaper = try make(objects: [
            object(id: 1, fields: #""origin": {"script": "export function update(value) { shared.seen = thisLayer.scale.x; value.y = 7; return value; }", "value": "10 20 0"}"#),
        ])
        var input = SceneScriptFrameInput()
        input.deltaTime = 1.0 / 60
        input.objects[1] = feedback(origin: SIMD2(10, 20), scale: SIMD2(3, 3))
        let state = try frame(wallpaper, input)

        let layer = try XCTUnwrap(state.objects[1])
        XCTAssertEqual(layer.vector3(.origin), SIMD3(10, 7, 0))
        XCTAssertNil(layer.vector3(.scale), "scale was only read")
        XCTAssertNil(layer.scalar(.alpha))
        XCTAssertEqual(try shared(wallpaper, "seen"), 3, "the script read the renderer's scale")
    }

    /// An animated field a script owns still gets the animation's value before each frame: the
    /// script's `update(value)` starts from it (§1.9 P2, test-risks S7).
    func testAnAnimatedFieldTheScriptOwnsStartsFromTheAnimation() throws {
        let wallpaper = try make(objects: [
            object(id: 1, fields: #""alpha": {"script": "export function update(value) { return value + 0.25; }", "value": 1}"#),
        ])
        var input = SceneScriptFrameInput()
        input.deltaTime = 1.0 / 60
        var animated = feedback(origin: .zero, scale: SIMD2(1, 1))
        animated.alpha = 0.5
        animated.animated.insert(.alpha)
        input.objects[1] = animated
        _ = try frame(wallpaper, input)
        let state = try frame(wallpaper, input)
        XCTAssertEqual(try XCTUnwrap(state.objects[1]?.scalar(.alpha)), 0.75, accuracy: 1e-6,
                       "the animated 0.5 plus this frame's increment, not an accumulation")
    }

    func testWorldMatricesReachGetTransformMatrix() throws {
        let wallpaper = try make(objects: [
            object(id: 1, fields: #""origin": {"script": "export function update(value) { shared.tx = thisLayer.getTransformMatrix().translation().x; return value; }", "value": "0 0 0"}"#),
        ])
        var input = SceneScriptFrameInput()
        input.deltaTime = 1.0 / 60
        var moved = feedback(origin: .zero, scale: SIMD2(1, 1))
        moved.world = SceneAffineTransform(linear: matrix_identity_float2x2, translation: SIMD2(123, 4))
        input.objects[1] = moved
        _ = try frame(wallpaper, input)
        XCTAssertEqual(try shared(wallpaper, "tx"), 123)
    }

    // MARK: - Structure

    func testCreateSortAndDestroyBecomeEventsAndOrder() throws {
        let wallpaper = try make(objects: [
            object(id: 1, fields: #""image": "models/a.json""#),
            object(id: 2, fields: #""origin": {"script": "let made; export function update(value) { if (!made) { made = thisScene.createLayer({ image: 'models/b.json', origin: '5 6 0' }); thisScene.sortLayer(made, 0); } else if (!shared.gone) { thisScene.destroyLayer(made); shared.gone = true; } return value; }", "value": "0 0 0"}"#),
        ])
        var input = SceneScriptFrameInput()
        input.deltaTime = 1.0 / 60
        wallpaper.submit(input)
        wallpaper.waitUntilIdle()
        var taken = wallpaper.take()
        guard case .create(let id, let json)? = taken.events.first else { return XCTFail("no create: \(taken.events)") }
        XCTAssertEqual(json["image"], .string("models/b.json"))
        XCTAssertEqual(taken.state?.order, [id, 1, 2], "sortLayer(made, 0) put it at the bottom")

        wallpaper.submit(input)
        wallpaper.waitUntilIdle()
        taken = wallpaper.take()
        guard case .destroy(let destroyed)? = taken.events.first else { return XCTFail("no destroy: \(taken.events)") }
        XCTAssertEqual(destroyed, id)
        XCTAssertEqual(taken.state?.order, [1, 2])
    }

    /// test-risks S11's clone stress test: a layer created and destroyed every frame for 1000
    /// frames leaves the scene as it was (every create has its destroy; slots are reused).
    func testCreatingAndDestroyingALayerEveryFrameStaysFlat() throws {
        // `destroyLayer` applies after the frame's updates, so the count is read first.
        let churn = "let made = null; export function update(value) { shared.count = thisScene.getLayerCount(); "
            + "if (made !== null) thisScene.destroyLayer(made); made = thisScene.createLayer({ image: 'models/b.json' }); return value; }"
        let wallpaper = try make(objects: [object(id: 1, fields: #""origin": {"script": "\#(churn)", "value": "0 0 0"}"#)])
        var input = SceneScriptFrameInput()
        input.deltaTime = 1.0 / 60
        var created = Set<Int>(), destroyed = Set<Int>()
        for _ in 0..<1000 {
            wallpaper.submit(input)
            wallpaper.waitUntilIdle()
            for event in wallpaper.take().events {
                switch event {
                case .create(let id, _): created.insert(id)
                case .destroy(let id): destroyed.insert(id)
                case .emit: break
                }
            }
        }
        XCTAssertEqual(created.count, 1000)
        XCTAssertEqual(destroyed.count, 999, "all but the last one")
        XCTAssertEqual(try shared(wallpaper, "count"), 2, "the scene holds its object and one made layer")
        let slots = wallpaper.thread.sync { wallpaper.scriptRuntime?.context.evaluateScript("__rt.objects.bySlot.size")?.toInt32() }
        XCTAssertEqual(slots, 2, "destroyed layers' slots are free again")
    }

    /// A property animation a script controls comes back as the time the renderer evaluates it at;
    /// animations nobody touched keep following scene time.
    func testAScriptControlledAnimationPublishesItsTime() throws {
        let alpha = #""alpha": {"value": 1, "animation": {"c0": [{"frame": 0, "value": 0}, {"frame": 20, "value": 1}], "options": {"fps": 10, "length": 20, "name": "fade"}}}"#
        let script = "export function update(value) { const a = thisLayer.getAnimation('fade'); a.pause(); a.setFrame(5); return value; }"
        let wallpaper = try make(objects: [object(id: 1, fields: #"\#(alpha), "origin": {"script": "\#(script)", "value": "0 0 0"}"#)])
        var input = SceneScriptFrameInput()
        input.deltaTime = 1.0 / 60
        let state = try frame(wallpaper, input)
        XCTAssertEqual(try XCTUnwrap(state.objects[1]?.animationTimes["alpha"]), 0.5, accuracy: 1e-6, "frame 5 at 10 fps")
    }

    func testEffectVisibilityAndMaterialConstantsComeBack() throws {
        let effect = #"{"file": "effects/tint/effect.json", "visible": false, "passes": [{"constantshadervalues": {"color": "0 0 1"}}]}"#
        let wallpaper = try make(objects: [
            object(id: 1, fields: #""image": "models/a.json", "effects": [\#(effect)], "origin": {"script": "export function update(value) { const e = thisLayer.getEffect(0); e.visible = true; e.setMaterialProperty('color', new Vec3(0, 1, 0)); return value; }", "value": "0 0 0"}"#),
        ])
        var input = SceneScriptFrameInput()
        input.deltaTime = 1.0 / 60
        let state = try frame(wallpaper, input)
        let layer = try XCTUnwrap(state.objects[1])
        XCTAssertEqual(layer.effectVisible[0], true)
        XCTAssertEqual(layer.constants[0], [SceneScriptConstantWrite(material: nil, name: "color", value: [0, 1, 0])])
        XCTAssertGreaterThan(layer.effectRevision, 0)
    }

    /// A text script's string and a scene setting come back; a particle system's playback too.
    func testStringsSceneSettingsAndPlayback() throws {
        let wallpaper = try make(objects: [
            object(id: 1, fields: #""text": {"script": "export function update() { return 'hello'; }", "value": ""}"#),
            object(id: 2, fields: #""particle": "particles/p.json", "origin": {"script": "export function update(value) { thisLayer.pause(); thisScene.camerashake = true; return value; }", "value": "0 0 0"}"#),
        ])
        var input = SceneScriptFrameInput()
        input.deltaTime = 1.0 / 60
        let state = try frame(wallpaper, input)
        XCTAssertEqual(state.objects[1]?.strings[.text], "hello")
        XCTAssertEqual(state.objects[2]?.playback, .pause)
        XCTAssertEqual(state.scene.flag(.camerashake), true)
        XCTAssertNil(state.scene.flag(.bloom), "untouched settings stay the scene's")
    }

    /// WP10: the renderer's cursor frame reaches only the hit object's scripts.
    func testTheCursorPassClicksTheLayerUnderTheCursor() throws {
        let clicker = #"export function cursorClick() { shared.clicks = (shared.clicks || 0) + 1; }"#
        let wallpaper = try make(objects: [
            object(id: 1, fields: #""image": "models/a.json", "size": "100 100", "origin": {"script": "\#(clicker) export function update(value) { return value; }", "value": "50 50 0"}"#),
        ])
        var input = SceneScriptFrameInput()
        input.deltaTime = 1.0 / 60
        var layer = feedback(origin: SIMD2(50, 50), scale: SIMD2(1, 1))
        layer.world = SceneAffineTransform(linear: matrix_identity_float2x2, translation: SIMD2(50, 50))
        layer.size = SIMD2(100, 100)
        input.objects[1] = layer
        input.cursorScenePosition = SIMD2(60, 40)
        for down in [false, true, false] {
            input.input.cursorLeftDown = down
            _ = try frame(wallpaper, input)
        }
        _ = try frame(wallpaper, input)
        XCTAssertEqual(try shared(wallpaper, "clicks"), 1)
    }

    /// The user's values reach `engine.userProperties` in WE's raw form, typed as project.json declares.
    func testUserPropertiesKeepTheirDeclaredTypes() throws {
        var properties = SceneScriptUserProperties(project: try SceneScriptSiteBuilder.document(from: Data(#"""
            {"general": {"properties": {"on": {"type": "bool", "value": false}, "speed": {"type": "slider", "value": 1},
             "mode": {"type": "combo", "value": 2}, "tint": {"type": "color", "value": "1 0 0"}}}}
            """#.utf8)))
        properties.setStoredValues(["on": "true", "speed": "0.5", "mode": "3", "tint": "0 1 0"])
        XCTAssertEqual(properties.value(of: "on"), .bool(true))
        XCTAssertEqual(properties.value(of: "speed"), .number(0.5))
        XCTAssertEqual(properties.value(of: "mode"), .number(3))
        XCTAssertEqual(properties.value(of: "tint"), .string("0 1 0"))
    }

    // MARK: - Support

    private func object(id: Int, fields: String) -> String {
        #"{"id": \#(id), "name": "Object \#(id)", \#(fields)}"#
    }

    private func make(objects: [String]) throws -> SceneScriptWallpaper {
        let text = #"{"general": {"orthogonalprojection": {"width": 200, "height": 100}}, "objects": [\#(objects.joined(separator: ", "))]}"#
        let document = try SceneScriptSiteBuilder.document(from: Data(text.utf8))
        let content = SceneScriptSceneContent(wallpaperID: "test-\(UUID().uuidString.prefix(8))", document: document,
                                              documentSignature: "1", project: nil, userValues: { [:] },
                                              file: { _ in nil }, makeLayer: { _ in nil })
        let services = SceneScriptServices(prelude: SceneScriptPrelude.load(), storage: SceneScriptStorage(directory: storage),
                                           media: SceneScriptReplayMediaSource(), spectrum: { .silent })
        let wallpaper = try XCTUnwrap(try SceneScriptWallpaper(content: content, services: services, screenID: "test"))
        addTeardownBlock { wallpaper.tearDown(); wallpaper.waitUntilIdle() }
        return wallpaper
    }

    private func feedback(origin: SIMD2<Float>, scale: SIMD2<Float>) -> SceneScriptObjectFeedback {
        SceneScriptObjectFeedback(origin: origin, scale: scale, angle: 0, alpha: nil, color: nil, visible: true, size: nil,
                                  world: SceneAffineTransform(SceneLocalTransform(origin: origin, scale: scale, angle: 0)))
    }

    /// Runs one script frame and returns the state it left.
    private func frame(_ wallpaper: SceneScriptWallpaper, _ input: SceneScriptFrameInput) throws -> SceneScriptFrameState {
        wallpaper.submit(input)
        wallpaper.waitUntilIdle()
        return try XCTUnwrap(wallpaper.take().state)
    }

    private func shared(_ wallpaper: SceneScriptWallpaper, _ key: String) throws -> Double? {
        wallpaper.thread.sync { wallpaper.scriptRuntime?.context.evaluateScript("shared.\(key)")?.toDouble() }
    }
}
