import XCTest
import Metal
@testable import OpenWallpaperEngine

/// A chain's leading effects that don't change over time are kept between frames while later ones
/// run every frame (`EffectGraphRenderer.staticPrefix`).
final class EffectChainPrefixTests: XCTestCase {
    private typealias D = SceneEffectDetailTests

    func testAStaticPrefixIsKeptAndTheFrameStartsAfterIt() throws {
        let (renderer, builder, queue, cache) = try D.graph()
        defer {
            renderer.pipelineArchive?.flush()
            try? FileManager.default.removeItem(at: cache)
        }
        let tint = try D.plan("effects/tint/effect.json", builder), scroll = try D.plan("effects/scroll/effect.json", builder)
        XCTAssertTrue(renderer.waitUntilReady([tint, scroll], width: 64, height: 64))
        let image = try D.texture(queue.device, 64, 64)
        var lastOutput: MTLTexture?
        func draw(_ time: Double, hidden: Set<Int> = [], revision: Int = 0) throws {
            let buffer = try XCTUnwrap(queue.makeCommandBuffer())
            var context = D.context(time: time)
            context.hiddenEffects = hidden
            context.scriptRevision = revision
            lastOutput = renderer.apply([tint, scroll], to: image, layerID: "layer", context: context, commandBuffer: buffer)
            XCTAssertNotNil(lastOutput)
            buffer.commit()
            buffer.waitUntilCompleted()
        }
        let programs = [tint, scroll].map { effect in
            effect.passes.map { pass in pass.variant.map { UniformProgram(layout: $0.uniforms, constants: pass.constants) } }
        }
        XCTAssertEqual(EffectGraphRenderer.staticPrefix([tint, scroll], programs: programs, hidden: []), 1)
        XCTAssertEqual(EffectGraphRenderer.staticPrefix([tint, scroll], programs: programs, hidden: [1]), 0,
                       "nothing varies after it: the whole chain is kept instead")
        try draw(1)
        let encoded = renderer.passesEncoded
        try draw(2)
        try draw(3)
        XCTAssertEqual(renderer.prefixesReused, 2)
        XCTAssertEqual(renderer.passesEncoded - encoded, 2, "only the scroll pass, each frame")
        // What a frame that starts after the kept prefix draws is what drawing every pass draws.
        let kept = try TextureUploadTests.read(try XCTUnwrap(lastOutput), device: queue.device)
        let (fresh, _, freshQueue, freshCache) = try D.graph()
        defer {
            fresh.pipelineArchive?.flush()
            try? FileManager.default.removeItem(at: freshCache)
        }
        XCTAssertTrue(fresh.waitUntilReady([tint, scroll], width: 64, height: 64))
        let buffer = try XCTUnwrap(freshQueue.makeCommandBuffer())
        let whole = try XCTUnwrap(fresh.apply([tint, scroll], to: image, layerID: "layer", context: D.context(time: 3),
                                              commandBuffer: buffer))
        buffer.commit()
        buffer.waitUntilCompleted()
        XCTAssertEqual(fresh.prefixesReused, 0)
        XCTAssertEqual(try TextureUploadTests.read(whole, device: queue.device), kept, "pixel for pixel")
        try draw(4, hidden: [1], revision: 1)
        try draw(5, revision: 2)
        XCTAssertEqual(renderer.passesEncoded - encoded, 5, "a script's change redraws the prefix")
        try draw(6, revision: 2)
        XCTAssertEqual(renderer.passesEncoded - encoded, 6)
        XCTAssertEqual(renderer.prefixesReused, 3)
    }
}
