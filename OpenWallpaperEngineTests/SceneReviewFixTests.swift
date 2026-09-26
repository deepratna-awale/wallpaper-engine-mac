import XCTest
import simd
@testable import OpenWallpaperEngine

/// Area 8 review fixes on the loading side: stable caches, visibility fallbacks, object ids,
/// particle emitter space, change impact and music-synced effect overrides.
final class SceneReviewFixTests: XCTestCase {
    // MARK: Scene audio cache

    func testSceneAudioCacheNameIsStableAndPerWallpaper() {
        let a = URL(fileURLWithPath: "/w/a"), b = URL(fileURLWithPath: "/w/b")
        let name = SceneSoundContentBuilder.cacheName(entry: "sounds/music.mp3", wallpaperDirectory: a)
        XCTAssertEqual(name, SceneSoundContentBuilder.cacheName(entry: "sounds/music.mp3", wallpaperDirectory: a))
        XCTAssertNotEqual(name, SceneSoundContentBuilder.cacheName(entry: "sounds/music.mp3", wallpaperDirectory: b))
        XCTAssertTrue(name.hasSuffix(".mp3"))
        XCTAssertEqual(name.count, 64 + 4, "SHA256 hex plus extension")
    }

    // MARK: Effect visibility

    private func effect(_ json: String) throws -> WEObjectEffect {
        try JSONDecoder().decode(WEObjectEffect.self, from: Data(json.utf8))
    }

    func testEffectBoundToMissingPropertyKeepsAuthoredVisibility() throws {
        let shown = try effect(#"{"file":"e.json","visible":{"user":"toggle","value":true}}"#)
        let hidden = try effect(#"{"file":"e.json","visible":{"user":"toggle","value":false}}"#)
        XCTAssertTrue(SceneWallpaperViewModel.isEffectVisible(shown, userProperty: { _ in nil }))
        XCTAssertFalse(SceneWallpaperViewModel.isEffectVisible(hidden, userProperty: { _ in nil }))
        XCTAssertFalse(SceneWallpaperViewModel.isEffectVisible(shown, userProperty: { _ in "false" }))
        XCTAssertTrue(SceneWallpaperViewModel.isEffectVisible(hidden, userProperty: { _ in "true" }))
    }

    // MARK: Object ids

    func testObjectsWithoutIDUseTheHierarchyFallback() throws {
        let objects = try JSONDecoder().decode([WESceneObject].self,
                                               from: Data(#"[{"id": 7}, {"name": "x"}, {"id": 3}]"#.utf8))
        let keyed = SceneObjectIdentity.assigningFallbackIDs(objects)
        XCTAssertEqual(keyed.map(\.id), [7, 1, 3])
        let hierarchy = SceneTransformHierarchy(objects: objects, sceneSize: SIMD2(100, 100))
        for object in keyed {
            XCTAssertNotNil(hierarchy.nodes[String(object.id!)], "layer id matches a hierarchy node")
        }
    }

    // MARK: Particle emitter space

    func testEmitterSpaceIncludesParentScaleAndRotation() throws {
        let objects = try JSONDecoder().decode([WESceneObject].self, from: Data(#"""
        [{"id": 1, "origin": "100 100 0", "scale": "2 2 1", "angles": "0 0 1.5707963"},
         {"id": 2, "parent": 1, "origin": "10 0 0", "particle": "p.json"}]
        """#.utf8))
        let hierarchy = SceneTransformHierarchy(objects: objects, sceneSize: SIMD2(1920, 1080))
        let space = SceneParticleEmitterSpace(world: hierarchy.world(of: "2"))
        XCTAssertEqual(simd_length(space.origin - SIMD2(100, 100)), 20, accuracy: 1e-3,
                       "child offset is scaled by the parent")
        XCTAssertEqual(space.extent(SIMD2(5, 5)), SIMD2(10, 10))
        let rotated = space.offset(SIMD2(1, 0))
        XCTAssertEqual(simd_length(rotated), 2, accuracy: 1e-4)
        XCTAssertEqual(abs(rotated.x), 0, accuracy: 1e-4, "a quarter turn moves x onto y")
    }

    // MARK: Change impact

    func testParallaxAndEffectMusicSyncImpact() {
        XCTAssertEqual(SceneChangeImpact.impact(of: "_owe_effect_enabled_parallax"), .none)
        XCTAssertEqual(SceneChangeImpact.impact(of: "_owe_effect_parallax_amount"), .none)
        XCTAssertEqual(SceneChangeImpact.impact(of: "_owe_authored_effect_1_0_strength_musicSync"), .rebuildContent)
        XCTAssertEqual(SceneChangeImpact.impact(of: "_owe_authored_effect_1_0_strength_musicAmount"), .none)
        XCTAssertEqual(SceneChangeImpact.impact(of: "speed_musicSync"), .none)
    }

    // MARK: Effect overrides and music sync

    func testStoredOverrideDetectsScalarAndComponentSync() {
        let store = ["p": "0.4", "p_musicSync": "true", "v": "1 2 3", "v_1_musicSync": "true", "q": "1"]
        XCTAssertEqual(SceneEffectOverride.stored(property: "p", lookup: { store[$0] }),
                       SceneEffectOverride(property: "p", value: "0.4", isMusicSynced: true))
        XCTAssertEqual(SceneEffectOverride.stored(property: "v", lookup: { store[$0] })?.isMusicSynced, true)
        XCTAssertEqual(SceneEffectOverride.stored(property: "q", lookup: { store[$0] })?.isMusicSynced, false)
        XCTAssertNil(SceneEffectOverride.stored(property: "missing", lookup: { store[$0] }))
    }

    func testSyncedOverrideBindsToItsProperty() {
        let uniform = ShaderUniformDeclaration(type: "float", name: "g_Amp", arrayCount: nil,
                                               annotation: ["material": "strength"])
        let synced = SceneEffectPlanBuilder.applyingOverrides(
            { _ in SceneEffectOverride(property: "p", value: "0.4", isMusicSynced: true) },
            to: ["strength": .literal(ShaderValue(0.2))], uniforms: [uniform])
        XCTAssertEqual(synced["strength"], .user(name: "p", condition: nil, fallback: .literal(ShaderValue(0.4))))
        let plain = SceneEffectPlanBuilder.applyingOverrides(
            { _ in SceneEffectOverride(property: "p", value: "0.4") },
            to: [:], uniforms: [uniform])
        XCTAssertEqual(plain["strength"], .literal(ShaderValue(0.4)))
    }

    /// Risk #22: with no audio (capture denied, stopped or asleep, which resets the level to 0)
    /// a music-synced override reads as the value the user set, not a frozen modulation.
    func testSyncedOverrideFallsBackToItsValueWithoutAudio() {
        let engine = WallpaperServices.shared
        let wallpaper = "/tests/\(UUID().uuidString)"
        engine.setUserProperties(["p": "0.4", "p_musicSync": "true", "p_musicAmount": "1"], wallpaper: wallpaper, replacing: true)
        engine.beginFrame(wallpaper: wallpaper)
        defer { engine.endFrame() }
        XCTAssertEqual(engine.audioLevel, 0)
        XCTAssertTrue(engine.isMusicSynced("p"))
        XCTAssertEqual(LiveSceneValueContext(engine: engine, time: 0).userProperty("p").flatMap(Float.init), 0.4)
        XCTAssertEqual(engine.userPropertyValue("p", fallback: 0.4), 0.4)
    }

    func testMusicSyncModulatesScalarsAndComponents() {
        let modulate: (String, Float) -> Float = { _, base in base + 1 }
        XCTAssertEqual(LiveSceneValueContext.musicSynced("0.5", name: "p", isSynced: { $0 == "p" }, modulate: modulate), "1.5")
        XCTAssertEqual(LiveSceneValueContext.musicSynced("0.5", name: "p", isSynced: { _ in false }, modulate: modulate), "0.5")
        XCTAssertEqual(LiveSceneValueContext.musicSynced("1 2 3", name: "v", isSynced: { $0 == "v_1" }, modulate: modulate),
                       "1.0 3.0 3.0")
        XCTAssertEqual(LiveSceneValueContext.musicSynced("abc", name: "p", isSynced: { _ in true }, modulate: modulate), "abc")
    }
}
