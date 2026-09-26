import XCTest
import Metal
@testable import OpenWallpaperEngine

/// Static-chain reuse and target recycling with real WE effects (needs the toolchain and a WE install).
final class EffectGraphReuseTests: XCTestCase {
    private var device: MTLDevice!
    private var queue: MTLCommandQueue!
    private var renderer: EffectGraphRenderer!
    private var builder: SceneEffectPlanBuilder!
    private var cache: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: ShaderVariantTests.weAssets.path), "WE install not present")
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        queue = try XCTUnwrap(device.makeCommandQueue())
        cache = FileManager.default.temporaryDirectory.appending(path: "owe-reuse-\(UUID().uuidString)")
        // Not the user's pipeline archive: tests must not write to the app's caches.
        renderer = try XCTUnwrap(EffectGraphRenderer(device: device, pipelineArchiveDirectory: cache.appending(path: "archives")))
        let translator = ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: cache)
        let root = ShaderVariantTests.weAssets
        builder = SceneEffectPlanBuilder(
            translator: translator,
            readFile: { FileManager.default.contents(atPath: root.appending(path: $0).path) },
            loadTexture: { _, _ in nil })
    }

    override func tearDownWithError() throws {
        // A pending archive write must not see its directory vanish mid-write.
        renderer?.pipelineArchive?.flush()
        if let cache { try? FileManager.default.removeItem(at: cache) }
    }

    private func tintPlan() throws -> SceneEffectPlan {
        let effect = try JSONDecoder().decode(WEObjectEffect.self, from: Data(#"{"file":"effects/tint/effect.json"}"#.utf8))
        return try builder.build(effect)
    }

    private func texture(_ width: Int, _ height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    private func context(color: SIMD3<Float> = SIMD3(1, 1, 1), alpha: Float = 1, version: UInt64 = 0) -> EffectGraphRenderer.Context {
        var context = EffectGraphRenderer.Context(frame: BuiltinFrameContext(time: 1), values: EffectGraphTests.FixedValues(),
                                                  assetTexture: { _, _ in nil }, sceneSnapshot: nil,
                                                  layerColor: color, layerAlpha: alpha)
        context.inputVersion = version
        return context
    }

    @discardableResult
    private func apply(_ plan: SceneEffectPlan, _ input: MTLTexture, _ context: EffectGraphRenderer.Context) throws -> MTLTexture {
        let buffer = try XCTUnwrap(queue.makeCommandBuffer())
        let output = try XCTUnwrap(renderer.apply([plan], to: input, layerID: "layer", context: context, commandBuffer: buffer))
        buffer.commit()
        buffer.waitUntilCompleted()
        return output
    }

    func testStaticChainRerendersWhenColorAlphaOrInputVersionChange() throws {
        let plan = try tintPlan()
        XCTAssertTrue(renderer.waitUntilReady([plan], width: 64, height: 64))
        let input = try texture(64, 64)
        try apply(plan, input, context())
        try apply(plan, input, context())
        XCTAssertEqual(renderer.layersReused, 1)
        let encoded = renderer.passesEncoded
        try apply(plan, input, context(color: SIMD3(1, 0, 0)))
        try apply(plan, input, context(color: SIMD3(1, 0, 0), alpha: 0.5))
        try apply(plan, input, context(color: SIMD3(1, 0, 0), alpha: 0.5, version: 1))
        XCTAssertEqual(renderer.passesEncoded - encoded, 3, "each change re-renders")
        try apply(plan, try texture(64, 64), context(color: SIMD3(1, 0, 0), alpha: 0.5, version: 1))
        XCTAssertEqual(renderer.passesEncoded - encoded, 4, "a different texture object re-renders")
    }

    /// TF4: a chain whose only live input is a timeline is reused while the timeline's value
    /// stays (a paused, finished or start-paused one), and re-rendered when it moves.
    func testAnAnimatedConstantsChainIsReusedWhileItsValueStays() throws {
        let json = #"{"file": "effects/tint/effect.json", "passes": [{"constantshadervalues": {"color": {"value": "1 1 1", "#
            + #""animation": {"c0": [{"frame": 0, "value": 1}], "options": {"fps": 30, "length": 30}}}}}]}"#
        let effect = try JSONDecoder().decode(WEObjectEffect.self, from: Data(json.utf8))
        let plan = try builder.build(effect, owner: (object: 1, effect: 0))
        XCTAssertTrue(renderer.waitUntilReady([plan], width: 64, height: 64))
        let input = try texture(64, 64)
        let timeline = Timeline()
        var context = context()
        context = EffectGraphRenderer.Context(frame: context.frame, values: timeline, assetTexture: { _, _ in nil },
                                              sceneSnapshot: nil, layerColor: context.layerColor, layerAlpha: context.layerAlpha)
        try apply(plan, input, context)
        try apply(plan, input, context)
        XCTAssertEqual(renderer.layersReused, 1, "paused: reused")
        let encoded = renderer.passesEncoded
        timeline.value = [0.5, 0.5, 0.5]
        try apply(plan, input, context)
        XCTAssertEqual(renderer.passesEncoded - encoded, 1, "moved: re-rendered")
        try apply(plan, input, context)
        XCTAssertEqual(renderer.layersReused, 2, "held again: reused")
    }

    private final class Timeline: SceneValueContext {
        var value: [Float] = [1, 0, 0]
        func userProperty(_ name: String) -> String? { nil }
        func animationValue(_ site: SceneAnimationSite) -> [Float]? {
            site == SceneAnimationSite(owner: .material(object: 1, effect: 0, pass: 0), key: "color") ? value : nil
        }
    }

    func testAlternatingInputSizesReuseTargets() throws {
        let plan = try tintPlan()
        XCTAssertTrue(renderer.waitUntilReady([plan], width: 64, height: 64))
        let small = try texture(40, 20), large = try texture(80, 20)
        let first = try apply(plan, small, context())
        XCTAssertEqual(first.width, 40)
        try apply(plan, large, context())
        let allocated = renderer.targetsAllocated
        for _ in 0..<4 {
            XCTAssertEqual(try apply(plan, small, context()).width, 40)
            XCTAssertEqual(try apply(plan, large, context()).width, 80)
        }
        XCTAssertEqual(renderer.targetsAllocated, allocated, "sizes seen before come from the spare list")
    }

    /// Memory pressure drops spare targets and, when critical, pipelines idle since the last such
    /// trim; the pipelines layers keep drawing with stay.
    func testMemoryPressureDropsSpareTargetsAndIdlePipelinesOnly() throws {
        let plan = try tintPlan()
        XCTAssertTrue(renderer.waitUntilReady([plan], width: 64, height: 64))
        let small = try texture(40, 20), large = try texture(80, 20)
        try apply(plan, small, context())
        try apply(plan, large, context())
        renderer.trimMemory(dropIdlePipelines: false)
        let allocated = renderer.targetsAllocated
        try apply(plan, small, context())
        XCTAssertGreaterThan(renderer.targetsAllocated, allocated, "the spare targets were dropped")
        XCTAssertEqual(renderer.pipelineCount, 1)
        renderer.trimMemory(dropIdlePipelines: true)
        XCTAssertEqual(renderer.pipelineCount, 1, "drawn with since the last trim: kept")
        renderer.trimMemory(dropIdlePipelines: true)
        XCTAssertEqual(renderer.pipelineCount, 0, "idle since the last trim: dropped")
        XCTAssertTrue(renderer.waitUntilReady([plan], width: 64, height: 64), "and rebuilt when needed again")
    }
}
