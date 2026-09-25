import XCTest
import Metal
@testable import OpenWallpaperEngine

/// Uniform writing, render-target pooling and cache keys: the parts of the effect graph that
/// must stay correct across frames without a WE install.
final class EffectGraphCachingTests: XCTestCase {
    // MARK: - UniformWriter

    func testIntegerUniformsClampAndTreatNaNAsZero() {
        XCTAssertEqual(UniformWriter.integerBits(.nan), 0)
        XCTAssertEqual(UniformWriter.integerBits(.infinity), UInt32(bitPattern: Int32.max))
        XCTAssertEqual(UniformWriter.integerBits(-.infinity), UInt32(bitPattern: Int32.min))
        XCTAssertEqual(UniformWriter.integerBits(1e20), UInt32(bitPattern: Int32.max))
        XCTAssertEqual(UniformWriter.integerBits(-1e20), UInt32(bitPattern: Int32.min))
        XCTAssertEqual(UniformWriter.integerBits(2.6), 3)
        XCTAssertEqual(UniformWriter.integerBits(-2.6), UInt32(bitPattern: -3))
    }

    func testWritingNaNIntoAnIntUniformDoesNotTrap() {
        var bytes = [UInt8](repeating: 0xFF, count: 16)
        let member = UniformMember(name: "i", type: "ivec2", offset: 0, count: 1, arrayStride: 0, matrixStride: 0)
        UniformWriter.write([.nan, 5], member: member, into: &bytes)
        XCTAssertEqual(Array(bytes[0..<8]), [0, 0, 0, 0, 5, 0, 0, 0])
    }

    // MARK: - Texture info

    private func texture(_ device: MTLDevice, _ width: Int, _ height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    func testTextureResolutionReportsAllocatedThenContentSize() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let padded = try texture(device, 512, 256)
        let info = EffectGraphRenderer.textureInfo(for: padded, contentSize: SIMD2(300, 200))
        let value = BuiltinUniforms.value(named: "g_Texture0Resolution", frame: BuiltinFrameContext(time: 0),
                                          pass: { var p = BuiltinPassContext(targetSize: SIMD2(1, 1)); p.textures = [0: info]; return p }(),
                                          arrayCount: nil)
        XCTAssertEqual(value, [512, 256, 300, 200])
        // Unknown content: the whole texture. Oversized content is clamped to the allocation.
        XCTAssertEqual(EffectGraphRenderer.textureInfo(for: padded, contentSize: nil).contentSize, SIMD2(512, 256))
        XCTAssertEqual(EffectGraphRenderer.textureInfo(for: padded, contentSize: SIMD2(900, 100)).contentSize, SIMD2(512, 100))
    }

    // MARK: - SceneRenderTargetPool

    func testPoolEvictsLeastRecentlyUsedOverBudget() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        // Room for the 64×64 and 64×32 RGBA8 textures; a third bucket goes over.
        let pool = SceneRenderTargetPool(device: device, byteBudget: 64 * 64 * 4 + 64 * 32 * 4)
        let a = try XCTUnwrap(pool.texture(width: 64, height: 64, pixelFormat: .rgba8Unorm))
        let b = try XCTUnwrap(pool.texture(width: 64, height: 32, pixelFormat: .rgba8Unorm))
        XCTAssertTrue(pool.texture(width: 64, height: 64, pixelFormat: .rgba8Unorm) === a, "same bucket is reused")
        _ = try XCTUnwrap(pool.texture(width: 32, height: 64, pixelFormat: .rgba8Unorm))
        XCTAssertLessThanOrEqual(pool.residentBytes, pool.byteBudget)
        XCTAssertTrue(pool.texture(width: 64, height: 64, pixelFormat: .rgba8Unorm) === a, "recently used bucket survives")
        XCTAssertFalse(pool.texture(width: 64, height: 32, pixelFormat: .rgba8Unorm) === b, "least recently used bucket was evicted")
    }

    func testPoolDropsBucketsIdleForTooManyFrames() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let pool = SceneRenderTargetPool(device: device, maxIdleFrames: 2)
        _ = pool.texture(width: 16, height: 16, pixelFormat: .rgba8Unorm)
        for _ in 0..<2 {
            _ = pool.texture(width: 8, height: 8, pixelFormat: .rgba8Unorm)
            pool.endFrame()
        }
        XCTAssertEqual(pool.textureCount, 2)
        _ = pool.texture(width: 8, height: 8, pixelFormat: .rgba8Unorm)
        pool.endFrame()
        XCTAssertEqual(pool.textureCount, 1, "the 16×16 bucket went unused for three frames")
    }

    // MARK: - Shader variant cache key

    func testVariantCacheKeyDependsOnToolchain() throws {
        let source = ShaderSource(stage: .vertex, path: "x", text: "void main() {}", combos: [], uniforms: [])
        let a = ShaderVariantTranslator.cacheKey(vertex: source, fragment: source, combos: [:], toolchain: "glslang:1")
        let b = ShaderVariantTranslator.cacheKey(vertex: source, fragment: source, combos: [:], toolchain: "glslang:2")
        XCTAssertNotEqual(a, b)
    }

    func testToolchainFingerprintTracksTheBinary() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "owe-tool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tool = directory.appending(path: "glslang")
        try Data("v1".utf8).write(to: tool)
        let before = ShaderVariantTranslator.toolchainFingerprint(tools: [tool.path])
        try Data("version2".utf8).write(to: tool)
        XCTAssertNotEqual(before, ShaderVariantTranslator.toolchainFingerprint(tools: [tool.path]))
    }
}
