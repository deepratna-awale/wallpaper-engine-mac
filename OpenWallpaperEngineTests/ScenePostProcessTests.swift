import XCTest
@testable import OpenWallpaperEngine

/// `ScenePostProcess`, the stage after the scene pass: WE's bloom gate and strength, and the
/// composite that carries the app's own adjustments.
final class ScenePostProcessTests: XCTestCase {
    private let placement = LayerUniform(position: SIMD2(960, 540), size: SIMD2(1920, 1080), sceneSize: SIMD2(1920, 1080),
                                         opacity: 1, particleShape: 0, rotation: 0, color: SIMD4(repeating: 1),
                                         uvOrigin: .zero, uvAxisX: SIMD2(1, 0), uvAxisY: SIMD2(0, 1),
                                         effects: SIMD4(1, 1, 1, 0), blur: 0, colorEffects: SIMD4(0, 1, 0, 0.7),
                                         transform: SIMD4(0, 0, 0, 1), transformScaleY: 1)

    /// The composite adds only the app's saturation, hue and blur; bloom is WE's chain, not the composite's.
    func testCompositeUniformCarriesTheAppExtrasOnly() {
        let extras = ScenePostProcess.AppExtras(bloom: 1.5, saturation: 0.8, hue: 0.25, blur: 1.5)
        let uniform = ScenePostProcess.compositeUniform(placement, extras: extras)
        XCTAssertEqual(uniform.effects, SIMD4(1, 1, 0.8, 0), "no native bloom")
        XCTAssertEqual(uniform.colorEffects.z, 0.25)
        XCTAssertEqual(uniform.blur, 2)
        XCTAssertEqual(uniform.position, placement.position)
        let identity = ScenePostProcess.compositeUniform(placement, extras: .init())
        XCTAssertEqual(identity.effects, SIMD4(1, 1, 1, 0))
        XCTAssertEqual(identity.colorEffects.z, 0)
        XCTAssertEqual(identity.blur, 0)
    }

    /// WE blooms when post-processing isn't "disabled" and the scene's live `bloom` is on (0x140180a41).
    func testBloomRunsWhenTheSceneAndTheSettingAllowIt() {
        let on = ScenePostProcess.Bloom(enabled: true, strength: 2, threshold: 0.65, tint: SIMD3(repeating: 1))
        var off = on
        off.enabled = false
        var settings = SceneRenderSettings()
        for quality in [GSPostProcessingQuality.enabled, .ultra, .displayhdr] {
            settings.postProcessing = quality
            XCTAssertTrue(ScenePostProcess.runsBloom(on, settings: settings), "\(quality)")
            XCTAssertFalse(ScenePostProcess.runsBloom(off, settings: settings), "\(quality): the scene's bloom is off")
        }
        settings.postProcessing = .disabled
        XCTAssertFalse(ScenePostProcess.runsBloom(on, settings: settings), "post-processing disabled")
    }

    /// The app's bloom slider scales WE's strength; 1 is WE's own.
    func testTheAppsBloomSliderScalesWEsStrength() {
        let bloom = ScenePostProcess.Bloom(enabled: true, strength: 2, threshold: 0.65, tint: SIMD3(repeating: 1))
        XCTAssertEqual(ScenePostProcess.bloomStrength(bloom, extras: .init()), 2)
        XCTAssertEqual(ScenePostProcess.bloomStrength(bloom, extras: .init(bloom: 1.5)), 3)
        XCTAssertEqual(ScenePostProcess.bloomStrength(bloom, extras: .init(bloom: 0)), 0)
        XCTAssertEqual(ScenePostProcess.bloomStrength(bloom, extras: .init(bloom: -1)), 0)
    }
}
