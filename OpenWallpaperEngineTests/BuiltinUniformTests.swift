import simd
import XCTest
@testable import OpenWallpaperEngine

final class BuiltinUniformTests: XCTestCase {
    private var frame = BuiltinFrameContext()
    private var pass = BuiltinPassContext(targetSize: SIMD2(256, 128))

    private func value(_ name: String, count: Int? = nil) -> [Float] {
        guard let result = BuiltinUniforms.value(named: name, frame: frame, pass: pass, arrayCount: count) else {
            XCTFail("\(name) is not a built-in")
            return []
        }
        return result
    }

    func testScalarsAndDaytimeAlias() {
        frame.time = 12.5
        frame.frameTime = 0.02
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 18, minute: 30))!
        frame.daytime = BuiltinFrameContext.daytime(at: date, calendar: calendar)
        XCTAssertEqual(frame.daytime, Float(18 * 60 + 30) / 1440, accuracy: 1e-6)
        XCTAssertEqual(value("g_Time"), [12.5])
        XCTAssertEqual(value("g_Frametime")[0], 0.02, accuracy: 1e-6)
        XCTAssertEqual(value("g_Daytime"), value("g_DayTime"))
        XCTAssertEqual(value("g_TextureReductionScale"), [1])
    }

    /// Like WE, `g_Time` is never wrapped: a week in, it is still the scene time (as a float),
    /// and consecutive frames never jump backwards.
    func testTimeIsNotWrappedOverLongRuns() {
        let week = 7.0 * 24 * 3600
        frame.time = week
        XCTAssertEqual(value("g_Time"), [Float(week)])
        frame.time = week + 1
        XCTAssertGreaterThan(value("g_Time")[0], Float(week))
    }

    func testPointerParallaxAndScreen() {
        frame.pointer = SIMD2(0.25, 0.75)
        frame.pointerLast = SIMD2(0.2, 0.7)
        frame.pointerState = BuiltinFrameContext.pointerState(primaryDown: true)
        frame.parallax = SIMD2(0.4, 0.6)
        frame.screenSize = SIMD2(1920, 1080)
        XCTAssertEqual(value("g_PointerPosition"), [0.25, 0.75])
        XCTAssertEqual(value("g_PointerPositionLast"), [0.2, 0.7])
        XCTAssertEqual(value("g_PointerState"), [1, 0, 1, 0])
        XCTAssertEqual(value("g_ParallaxPosition"), [0.4, 0.6])
        XCTAssertEqual(value("g_Screen"), [1920, 1080, 1920 / Float(1080)])
    }

    func testTexelSizeFromTarget() {
        XCTAssertEqual(value("g_TexelSize"), [Float(1) / 256, Float(1) / 128])
        XCTAssertEqual(value("g_TexelSizeHalf"), [Float(0.5) / 256, Float(0.5) / 128])
    }

    func testTextureMetadata() {
        pass.textures[0] = BuiltinTextureInfo(allocatedSize: SIMD2(1024, 512), contentSize: SIMD2(1000, 500),
                                              mipCount: 4)
        pass.textures[3] = BuiltinTextureInfo(allocatedSize: SIMD2(64, 64), contentSize: SIMD2(64, 64),
                                              spriteRotation: SIMD4(0.5, 0, 0, 0.25),
                                              spriteTranslation: SIMD2(0.5, 0.25))
        XCTAssertEqual(value("g_Texture0Resolution"), [1024, 512, 1000, 500])
        XCTAssertEqual(value("g_Texture0MipMapInfo"), [4])
        XCTAssertEqual(value("g_Texture0Texel"), [Float(1) / 1024, Float(1) / 512])
        XCTAssertEqual(value("g_Texture0Rotation"), [1, 0, 0, 1])
        XCTAssertEqual(value("g_Texture0Translation"), [0, 0])
        XCTAssertEqual(value("g_Texture3Rotation"), [0.5, 0, 0, 0.25])
        XCTAssertEqual(value("g_Texture3Translation"), [0.5, 0.25])
        XCTAssertEqual(value("g_Texture7Resolution"), [0, 0, 0, 0])
        XCTAssertEqual(value("g_Texture12Resolution").count, 4)
    }

    func testMatricesAndInverses() {
        let model = simd_float4x4(translation: SIMD3(10, 20, 0)) * simd_float4x4(scale: SIMD3(2, 3, 1))
        let viewProjection = PassMatrices.ortho(left: 0, right: 1920, bottom: 0, top: 1080)
        pass.modelMatrix = model
        pass.viewProjection = viewProjection
        pass.modelViewProjection = PassMatrices.final(viewProjection: viewProjection, model: model)

        let names = ["g_ModelViewProjectionMatrix", "g_ModelViewProjectionMatrixInverse",
                     "g_EffectModelViewProjectionMatrix", "g_EffectModelViewProjectionMatrixInverse",
                     "g_ModelMatrix", "g_ModelMatrixInverse", "g_EffectModelMatrix", "g_AltModelMatrix",
                     "g_ModelViewMatrix", "g_ModelViewMatrixInverse", "g_ViewMatrix",
                     "g_ViewProjectionMatrix", "g_ViewProjectionMatrixInverse", "g_AltViewProjectionMatrix",
                     "g_EffectTextureProjectionMatrix", "g_EffectTextureProjectionMatrixInverse"]
        for name in names { XCTAssertEqual(value(name).count, 16, name) }
        XCTAssertEqual(value("g_NormalModelMatrix").count, 9)

        for (forward, inverse) in [("g_ModelViewProjectionMatrix", "g_ModelViewProjectionMatrixInverse"),
                                   ("g_ModelMatrix", "g_ModelMatrixInverse"),
                                   ("g_ViewProjectionMatrix", "g_ViewProjectionMatrixInverse")] {
            let product = matrix(value(forward)) * matrix(value(inverse))
            assertIdentity(product, forward)
        }
        XCTAssertEqual(matrix(value("g_ModelMatrix")), model)
        // Column-major: translation in the last column.
        XCTAssertEqual(Array(value("g_ModelMatrix")[12...13]), [10, 20])
        assertIdentity(matrix(value("g_EffectTextureProjectionMatrix")), "texture projection")
    }

    func testPassMatrices() {
        let base = PassMatrices.base(width: 200, height: 100)
        XCTAssertEqual(base * SIMD4(0, 0, 0, 1), SIMD4(-1, -1, 0, 1))
        XCTAssertEqual(base * SIMD4(200, 100, 0, 1), SIMD4(1, 1, 0, 1))
        XCTAssertEqual(PassMatrices.intermediate, matrix_identity_float4x4)
    }

    func testLayerAndSceneValues() {
        pass.color = SIMD3(0.1, 0.2, 0.3)
        pass.alpha = 0.5
        pass.userAlpha = 0.7
        pass.brightness = 2
        frame.ambient = SIMD3(0.1, 0.1, 0.1)
        frame.skylight = SIMD3(0.4, 0.5, 0.6)
        frame.eyePosition = SIMD3(1, 2, 3)
        XCTAssertEqual(value("g_Color4"), [0.1, 0.2, 0.3, 0.5])
        XCTAssertEqual(value("g_Color"), [0.1, 0.2, 0.3])
        XCTAssertEqual(value("g_Alpha"), [0.5])
        XCTAssertEqual(value("g_UserAlpha"), [0.7])
        XCTAssertEqual(value("g_Brightness"), [2])
        XCTAssertEqual(value("g_LightAmbientColor"), [0.1, 0.1, 0.1])
        XCTAssertEqual(value("g_LightSkylightColor"), [0.4, 0.5, 0.6])
        XCTAssertEqual(value("g_EyePosition"), [1, 2, 3])
        XCTAssertEqual(value("g_ViewUp"), [0, 1, 0])
        XCTAssertEqual(value("g_ViewRight"), [1, 0, 0])
        XCTAssertEqual(value("g_ViewForward"), [0, 0, -1])
    }

    func testRenderVarsAndAudio() {
        pass.renderVars[2] = SIMD4(1, 2, 3, 4)
        XCTAssertEqual(value("g_RenderVar0"), [0, 0, 0, 0])
        XCTAssertEqual(value("g_RenderVar2"), [1, 2, 3, 4])
        XCTAssertNil(BuiltinUniforms.value(named: "g_RenderVar5", frame: frame, pass: pass, arrayCount: nil))

        frame.audio.right32 = (0..<32).map { Float($0) / 32 }
        for bands in [16, 32, 64] {
            XCTAssertEqual(value("g_AudioSpectrum\(bands)Left").count, bands)
            XCTAssertEqual(value("g_AudioSpectrum\(bands)Right").count, bands)
        }
        XCTAssertEqual(value("g_AudioSpectrum32Right")[16], 0.5)
        XCTAssertEqual(value("g_AudioSpectrum16Left", count: 20).count, 20)
        XCTAssertEqual(value("g_AudioSpectrum64Left", count: 8).count, 8)
    }

    func testIsBuiltinAndUnknownNames() {
        for name in ["g_Time", "g_DayTime", "g_Texture0Resolution", "g_Texture5Translation",
                     "g_AudioSpectrum64Right", "g_RenderVar4", "g_EffectModelViewProjectionMatrixInverse"] {
            XCTAssertTrue(BuiltinUniforms.isBuiltin(name), name)
        }
        for name in ["g_Texture0", "g_TextureResolution", "g_AudioSpectrum8Left", "g_Speed", "u_Time"] {
            XCTAssertFalse(BuiltinUniforms.isBuiltin(name), name)
            XCTAssertNil(BuiltinUniforms.value(named: name, frame: frame, pass: pass, arrayCount: nil), name)
        }
    }

    private func matrix(_ values: [Float]) -> simd_float4x4 {
        simd_float4x4(columns: (SIMD4(values[0...3]), SIMD4(values[4...7]),
                                SIMD4(values[8...11]), SIMD4(values[12...15])))
    }

    private func assertIdentity(_ m: simd_float4x4, _ label: String) {
        for column in 0..<4 {
            for row in 0..<4 {
                XCTAssertEqual(m[column][row], column == row ? 1 : 0, accuracy: 1e-4, label)
            }
        }
    }
}

private extension simd_float4x4 {
    init(translation t: SIMD3<Float>) {
        self = matrix_identity_float4x4
        columns.3 = SIMD4(t.x, t.y, t.z, 1)
    }

    init(scale s: SIMD3<Float>) {
        self = simd_float4x4(diagonal: SIMD4(s.x, s.y, s.z, 1))
    }
}
