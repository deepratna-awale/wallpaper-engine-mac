import XCTest
import Metal
@testable import OpenWallpaperEngine

/// An effect's `swap` command persists: the next frame starts from the buffers this one left, as
/// WE's fluid simulation (`effects/fluidsimulation`) needs for its velocity and dye ping-pong.
/// The fixture adds a quarter to red in `_rt_B` over `_rt_A`, shows `_rt_B`, then swaps them.
final class EffectGraphSwapTests: XCTestCase {
    private var cache: URL!

    override func tearDownWithError() throws {
        if let cache { try? FileManager.default.removeItem(at: cache) }
    }

    struct NoValues: SceneValueContext {
        func userProperty(_ name: String) -> String? { nil }
    }

    func testSwappedBuffersCarryIntoTheNextFrame() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: ShaderVariantTests.weAssets.path), "WE install not present")
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        cache = FileManager.default.temporaryDirectory.appending(path: "owe-swap-\(UUID().uuidString)")
        let renderer = try XCTUnwrap(EffectGraphRenderer(device: device, pipelineArchiveDirectory: cache.appending(path: "archives")))
        defer { renderer.pipelineArchive?.flush() }
        let fixture = Fixtures.url("Effects/pingpong")
        let assets = ShaderVariantTests.weAssets
        let builder = SceneEffectPlanBuilder(
            translator: ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: cache),
            readFile: { path in
                FileManager.default.contents(atPath: fixture.appending(path: path).path)
                    ?? FileManager.default.contents(atPath: assets.appending(path: path).path)
            },
            loadTexture: { _, _ in nil })
        let effect = try JSONDecoder().decode(WEObjectEffect.self, from: Data(#"{"file": "effects/pingpong/effect.json"}"#.utf8))
        let plan = try builder.build(effect)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 8, height: 8, mipmapped: false)
        descriptor.usage = [.shaderRead]
        let input = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let context = EffectGraphRenderer.Context(frame: BuiltinFrameContext(time: 0), values: NoValues(),
                                                  assetTexture: { _, _ in nil }, sceneSnapshot: nil,
                                                  layerColor: SIMD3(1, 1, 1), layerAlpha: 1)
        XCTAssertTrue(renderer.waitUntilReady([plan], width: 8, height: 8), "pipelines still compiling")
        var reds: [Int] = []
        for _ in 0..<3 {
            let buffer = try XCTUnwrap(queue.makeCommandBuffer())
            let output = try XCTUnwrap(renderer.apply([plan], to: input, layerID: "pingpong", context: context,
                                                      commandBuffer: buffer))
            let shared = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: output.pixelFormat, width: output.width,
                                                                  height: output.height, mipmapped: false)
            shared.storageMode = .shared
            let copy = try XCTUnwrap(device.makeTexture(descriptor: shared))
            let blit = try XCTUnwrap(buffer.makeBlitCommandEncoder())
            blit.copy(from: output, to: copy)
            blit.endEncoding()
            buffer.commit()
            buffer.waitUntilCompleted()
            var pixel = [UInt8](repeating: 0, count: 4)
            copy.getBytes(&pixel, bytesPerRow: output.width * 4, from: MTLRegionMake2D(4, 4, 1, 1), mipmapLevel: 0)
            reds.append(Int(pixel[0]))
        }
        // 0.25, 0.5, 0.75: each frame adds to the last one's buffer. Without the swap carrying
        // over, every frame read the cleared `_rt_A` and showed 0.25.
        XCTAssertEqual(reds.count, 3)
        for (frame, red) in reds.enumerated() {
            XCTAssertEqual(red, 64 * (frame + 1), accuracy: 2, "frame \(frame): \(reds)")
        }
    }

    /// FBOs start as their `clear` colour: pooled targets hold whatever they last held, and a
    /// simulation that reads its own last frame keeps garbage (a NaN) for good.
    func testFBOsStartAsTheirClearColour() {
        let authored = EffectGraphRenderer.clearColor("0.25 0.5 1 0")
        XCTAssertEqual([authored.red, authored.green, authored.blue, authored.alpha], [0.25, 0.5, 1, 0])
        let none = EffectGraphRenderer.clearColor(nil)
        XCTAssertEqual([none.red, none.green, none.blue, none.alpha], [0, 0, 0, 0])
    }
}
