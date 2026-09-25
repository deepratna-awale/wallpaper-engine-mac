import XCTest
import Metal
import MetalKit
@testable import OpenWallpaperEngine

/// Runs real WE effects headlessly on a checkerboard and checks they actually change it.
final class EffectGraphTests: XCTestCase {
    private var device: MTLDevice!
    private var renderer: EffectGraphRenderer!
    private var builder: SceneEffectPlanBuilder!
    private var cache: URL!

    override func setUpWithError() throws {
        try XCTSkipIf(SceneShaderTranslator.toolchain == nil, "glslang/spirv-cross not installed")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: ShaderVariantTests.weAssets.path), "WE install not present")
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        renderer = try XCTUnwrap(EffectGraphRenderer(device: device))
        cache = FileManager.default.temporaryDirectory.appending(path: "owe-graph-\(UUID().uuidString)")
        let translator = ShaderVariantTranslator(compiler: try ProcessShaderCompiler(), cacheDirectory: cache)
        let root = ShaderVariantTests.weAssets
        builder = SceneEffectPlanBuilder(
            roots: [root], translator: translator,
            readFile: { FileManager.default.contents(atPath: root.appending(path: $0).path) },
            loadTexture: { name, materialPath in
                let effectDirectory = materialPath.split(separator: "/").prefix(2).joined(separator: "/")
                for path in ["materials/\(name).tex", "\(name).tex", "\(effectDirectory)/materials/\(name).tex"] {
                    if let data = FileManager.default.contents(atPath: root.appending(path: path).path),
                       let image = TEXParser(data: data).extractImage() { return .image(image) }
                }
                return nil
            })
    }

    override func tearDownWithError() throws {
        if let cache { try? FileManager.default.removeItem(at: cache) }
    }

    private func effect(_ json: String) throws -> WEObjectEffect {
        try JSONDecoder().decode(WEObjectEffect.self, from: Data(json.utf8))
    }

    private func checkerboard(size: Int = 256) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: false)
        descriptor.usage = [.shaderRead]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        var pixels = [UInt8](repeating: 255, count: size * size * 4)
        for y in 0..<size { for x in 0..<size where (x / 32 + y / 32) % 2 == 0 {
            let i = (y * size + x) * 4
            pixels[i] = 20; pixels[i + 1] = 40; pixels[i + 2] = 200
        } }
        texture.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, withBytes: pixels, bytesPerRow: size * 4)
        return texture
    }

    private func read(_ texture: MTLTexture, queue: MTLCommandQueue) throws -> [UInt8] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: texture.pixelFormat, width: texture.width,
                                                                  height: texture.height, mipmapped: false)
        descriptor.storageMode = .shared
        let copy = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let buffer = try XCTUnwrap(queue.makeCommandBuffer())
        let blit = try XCTUnwrap(buffer.makeBlitCommandEncoder())
        blit.copy(from: texture, to: copy)
        blit.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        copy.getBytes(&bytes, bytesPerRow: texture.width * 4, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        return bytes
    }

    struct FixedValues: SceneValueContext {
        func userProperty(_ name: String) -> String? { nil }
        func evaluateScript(_ source: String, properties: SceneScriptProperties, current: ShaderValue) -> ShaderValue? { nil }
        var time: Double { 1.5 }
    }

    /// Plans, runs and reads back; returns (input, output) pixels.
    private func run(_ json: String) throws -> (input: [UInt8], output: [UInt8]) {
        let plan = try builder.build(try effect(json))
        XCTAssertFalse(plan.passes.isEmpty)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let input = try checkerboard()
        let buffer = try XCTUnwrap(queue.makeCommandBuffer())
        let loader = MTKTextureLoader(device: device)
        let context = EffectGraphRenderer.Context(
            frame: BuiltinFrameContext(time: 1.5), values: FixedValues(),
            assetTexture: { _, source in
                guard case .image(let image) = source, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
                return try? loader.newTexture(cgImage: cg, options: [.SRGB: false])
            },
            sceneSnapshot: nil, layerColor: SIMD3(1, 1, 1), layerAlpha: 1)
        XCTAssertTrue(renderer.waitUntilReady([plan], width: input.width, height: input.height), "pipelines still compiling")
        let output = try XCTUnwrap(renderer.apply([plan], to: input, layerID: "test", context: context, commandBuffer: buffer),
                                   "no pass rendered")
        buffer.commit()
        buffer.waitUntilCompleted()
        XCTAssertNil(buffer.error)
        return (try read(input, queue: queue), try read(output, queue: queue))
    }

    private func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        zip(a, b).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(a.count)
    }

    func testTintChangesTheImage() throws {
        let result = try run(#"{"file":"effects/tint/effect.json","passes":[{"constantshadervalues":{"color":"1 0 0","alpha":1}}]}"#)
        XCTAssertGreaterThan(difference(result.input, result.output), 1)
    }

    func testFourPassBlurWithQuarterBuffersSoftensEdges() throws {
        let result = try run(#"{"file":"effects/blur/effect.json","passes":[{},{},{},{}]}"#)
        XCTAssertGreaterThan(difference(result.input, result.output), 0.5)
        // The checker's colours are still where they were (no flip, no shift).
        let center = (128 * 256 + 16) * 4
        XCTAssertLessThan(abs(Int(result.output[center + 2]) - Int(result.input[center + 2])), 60)
    }

    /// Shake moves pixels along its direction map (slot 1); the default `util/noflow` is zero flow,
    /// so give it a real one, plus an opacity mask in slot 3 (MASK combo).
    func testShakeFollowsItsDirectionMapThroughAMask() throws {
        let result = try run(#"{"file":"effects/shake/effect.json","passes":[{"textures":[null,"util/clouds_256",null,"util/white"],"constantshadervalues":{"strength":0.3,"speed":2}}]}"#)
        XCTAssertGreaterThan(difference(result.input, result.output), 0.1)
    }

    func testEveryBuiltinEffectRunsWithDefaults() throws {
        let effects = ShaderVariantTests.weAssets.appending(path: "effects")
        var failures: [String] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: effects.path).sorted() where !name.hasPrefix(".") {
            do {
                _ = try run(#"{"file":"effects/\#(name)/effect.json"}"#)
            } catch {
                failures.append("\(name): \(String(describing: error).prefix(200))")
            }
        }
        XCTAssertEqual(failures, [], failures.joined(separator: "\n"))
    }

    /// Chains that don't change over time are rendered once and reused while the input is the same.
    func testStaticChainIsReusedAndAnimatedChainIsNot() throws {
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let input = try checkerboard()
        let context = EffectGraphRenderer.Context(frame: BuiltinFrameContext(time: 1), values: FixedValues(),
                                                  assetTexture: { _, _ in nil }, sceneSnapshot: nil,
                                                  layerColor: SIMD3(1, 1, 1), layerAlpha: 1)
        func frames(_ json: String, layer: String) throws -> (encoded: Int, reused: Int) {
            let plan = try builder.build(try effect(json))
            XCTAssertTrue(renderer.waitUntilReady([plan], width: 256, height: 256))
            let encodedBefore = renderer.passesEncoded
            let reusedBefore = renderer.layersReused
            for _ in 0..<3 {
                let buffer = try XCTUnwrap(queue.makeCommandBuffer())
                XCTAssertNotNil(renderer.apply([plan], to: input, layerID: layer, context: context, commandBuffer: buffer))
                buffer.commit()
            }
            return (renderer.passesEncoded - encodedBefore, renderer.layersReused - reusedBefore)
        }
        let tint = try frames(#"{"file":"effects/tint/effect.json"}"#, layer: "static")
        XCTAssertEqual(tint.encoded, 1, "tint has no time input: one render, then reuse")
        XCTAssertEqual(tint.reused, 2)
        let shake = try frames(#"{"file":"effects/shake/effect.json","passes":[{"textures":[null,"util/clouds_256"]}]}"#, layer: "animated")
        XCTAssertEqual(shake.encoded, 3, "shake reads g_Time and must render every frame")
        XCTAssertEqual(shake.reused, 0)
    }
}
