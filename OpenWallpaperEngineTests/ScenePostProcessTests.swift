import XCTest
@testable import OpenWallpaperEngine

/// `ScenePostProcess`, the stage after the scene pass, draws the composite the renderer always drew.
final class ScenePostProcessTests: XCTestCase {
    private let placement = LayerUniform(position: SIMD2(960, 540), size: SIMD2(1920, 1080), sceneSize: SIMD2(1920, 1080),
                                         opacity: 1, particleShape: 0, rotation: 0, color: SIMD4(repeating: 1),
                                         uvOrigin: .zero, uvAxisX: SIMD2(1, 0), uvAxisY: SIMD2(0, 1),
                                         effects: SIMD4(1, 1, 1, 0), blur: 0, colorEffects: SIMD4(0, 1, 0, 0.7),
                                         transform: SIMD4(0, 0, 0, 1), transformScaleY: 1)

    /// The composite's uniform is the one the renderer always drew with.
    func testCompositeUniformIsTheRenderersOwn() {
        let bloom = ScenePostProcess.Bloom(enabled: true, strength: 2, threshold: 0.5, tint: SIMD3(1, 0.5, 0.25))
        let authored = ScenePostProcess.compositeUniform(placement, bloom: bloom, extras: .init(bloom: 1.5, saturation: 0.8,
                                                                                             hue: 0.25, blur: 1.5))
        XCTAssertEqual(authored.effects, SIMD4(1, 1, 0.8, 3))
        XCTAssertEqual(authored.colorEffects, SIMD4(0, 1, 0.25, 0.5))
        XCTAssertEqual(authored.bloomTint, SIMD4(1, 0.5, 0.25, 1))
        XCTAssertEqual(authored.blur, 2)
        XCTAssertEqual(authored.position, placement.position)

        var off = bloom
        off.enabled = false
        let slider = ScenePostProcess.compositeUniform(placement, bloom: off, extras: .init(bloom: 2))
        XCTAssertEqual(slider.effects.w, 1.2, accuracy: 1e-6, "the app's slider alone")
        XCTAssertEqual(slider.colorEffects.w, SceneGeneralDefaults.bloomThreshold)
        let identity = ScenePostProcess.compositeUniform(placement, bloom: off, extras: .init())
        XCTAssertEqual(identity.effects, SIMD4(1, 1, 1, 0))
        XCTAssertEqual(identity.blur, 0)
    }
}
