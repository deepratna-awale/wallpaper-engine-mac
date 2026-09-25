import XCTest
import MetalKit
@testable import OpenWallpaperEngine

/// RG88 and R8 textures load as the GPU samples them, (r, g, 0, 1) and (r, 0, 0, 1): flow maps
/// (`shake`, `waterflow`) and normal maps read both channels, opacity masks and depth maps read
/// `.r`, and particle shaders convert such an albedo by `TEX0FORMAT`.
final class TextureRG88Tests: XCTestCase {
    private var device: MTLDevice!

    override func setUpWithError() throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    }

    func testRG88LoadsBothChannelsAsTheySample() throws {
        // Two texels: a flow direction (r 64, g 200) and (r 255, g 0).
        let data = Self.tex(format: 8, width: 2, height: 1, pixels: [64, 200, 255, 0])
        XCTAssertEqual(TEXImageFormat(texData: data), .rg88)
        let texels = try upload(try XCTUnwrap(TEXParser(data: data).extractImage()))
        XCTAssertEqual(Array(texels[0..<8]), [64, 200, 0, 255, 255, 0, 0, 255],
                       "red and green as stored, blue 0 and alpha 1, not luminance and alpha")
    }

    func testBuiltInDrawGetsLuminanceAndAlpha() throws {
        let data = Self.tex(format: 8, width: 2, height: 1, pixels: [200, 128, 40, 255])
        let image = try XCTUnwrap(TEXParser(data: data).extractImage())
        XCTAssertNil(ParticleFallbackTexture.converted(.image(image), format: TEXImageFormat(rawValue: 0)),
                     "other formats draw as loaded")
        guard case let .image(converted)? = ParticleFallbackTexture.converted(.image(image), format: .rg88) else {
            return XCTFail("an RG88 albedo gets a converted copy")
        }
        XCTAssertEqual(Array(try upload(converted)[0..<8]), [200, 200, 200, 128, 40, 40, 40, 255],
                       "`.rrrg`, as ConvertTexture0Format reads it")
    }

    func testRG88AndR8SetTheirFormatComboInEverySlot() {
        let combos = ParticleMaterialPlanBuilder.textureFormatCombos([0: Self.tex(format: 8), 1: Self.tex(format: 8),
                                                                      2: Self.tex(format: 9), 3: Self.tex(format: 0)])
        XCTAssertEqual(combos, ["TEX0FORMAT": 8, "TEX1FORMAT": 8, "TEX2FORMAT": 9], "RGBA is expanded on load and stays unset")
    }

    /// An R8 opacity mask or depth map reads its value in `.r`, as WE's effect shaders sample it
    /// (`texSample2D(g_Texture1, …).r`); it isn't white with the value in alpha.
    func testR8LoadsItsChannelAsRed() throws {
        let data = Self.tex(format: 9, width: 2, height: 1, pixels: [0, 200])
        XCTAssertEqual(TEXImageFormat(texData: data), .r8)
        let texels = try upload(try XCTUnwrap(TEXParser(data: data).extractImage()))
        XCTAssertEqual(Array(texels[0..<8]), [0, 0, 0, 255, 200, 0, 0, 255], "red as stored, green and blue 0, alpha 1")
    }

    func testBuiltInDrawGetsR8AsWhiteWithCoverage() throws {
        let data = Self.tex(format: 9, width: 2, height: 1, pixels: [0, 200])
        let image = try XCTUnwrap(TEXParser(data: data).extractImage())
        guard case let .image(converted)? = ParticleFallbackTexture.converted(.image(image), format: .r8) else {
            return XCTFail("an R8 albedo gets a converted copy")
        }
        XCTAssertEqual(Array(try upload(converted)[4..<8]), [255, 255, 255, 200],
                       "(1, 1, 1, r), as ConvertTexture0Format reads it")
        XCTAssertEqual(try upload(converted)[3], 0, "no coverage where the mask is 0")
    }

    private func upload(_ image: NSImage) throws -> [UInt8] {
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let texture = try SceneTextureUpload.texture(from: cgImage, loader: MTKTextureLoader(device: device), device: device)
        return try TextureUploadTests.read(texture, device: device)
    }

    /// A one-mipmap, uncompressed `TEXB0003` `.tex` of `format` holding `pixels`.
    static func tex(format: UInt32, width: UInt32 = 1, height: UInt32 = 1, pixels: [UInt8] = [0, 0]) -> Data {
        var data = Data("TEXV0005\u{0}TEXI0001\u{0}".utf8)
        func word(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        // Format, flags, texture size, image size, unknown.
        for value in [format, 0, width, height, width, height, 0] { word(value) }
        data.append(contentsOf: Data("TEXB0003\u{0}".utf8))
        // Images, FreeImage format (none), mipmaps; then the mipmap: size, uncompressed, bytes.
        for value in [1, UInt32.max, 1, width, height, 0, 0, UInt32(pixels.count)] { word(value) }
        data.append(contentsOf: pixels)
        return data
    }
}
