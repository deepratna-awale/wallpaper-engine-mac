import XCTest
import Metal
import AppKit
@testable import OpenWallpaperEngine

/// Particles drawn headlessly through WE's `genericparticle` / `genericropeparticle` materials,
/// with the emulated geometry stage and with WE's no-geometry-shader stream.
final class ParticleMaterialRenderTests: XCTestCase {
    private static let size = 256
    private var device: MTLDevice!
    private var queue: MTLCommandQueue!
    private var renderer: ParticleMaterialRenderer!
    private var builder: ParticleMaterialPlanBuilder!
    private var white: MTLTexture!

    override func setUpWithError() throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        queue = try XCTUnwrap(device.makeCommandQueue())
        renderer = try XCTUnwrap(ParticleMaterialRenderer(device: device))
        let roots = [Fixtures.url("Particles"), ShaderVariantTests.weAssets]
        builder = ParticleMaterialPlanBuilder(
            translator: ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: nil),
            readFile: { path in roots.lazy.compactMap { FileManager.default.contents(atPath: $0.appending(path: path).path) }.first },
            loadTexture: { _, _ in nil })
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 4, height: 4, mipmapped: false)
        white = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        white.replace(region: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0,
                      withBytes: [UInt8](repeating: 255, count: 64), bytesPerRow: 16)
    }

    // MARK: - Tests

    func testSpriteThroughEmulatedGeometryStage() throws {
        let plan = try self.plan("materials/solid.json", renderer: "sprite", keeping: .emulated(vertexCount: 6))
        // One particle in the top-left quadrant (scene y is up). WE's shaders read half the
        // simulated size, which is the quad's width.
        let pixels = try render(plan, particles: [particle(at: SIMD2(64, 192), size: 80)])
        XCTAssertGreaterThan(pixels.red(x: 64, y: 64), 250, "the sprite covers its position")
        XCTAssertGreaterThan(pixels.red(x: 64 + 17, y: 64 - 17), 250, "a size-80 sprite is 40 wide: it reaches 17 out")
        XCTAssertLessThan(pixels.red(x: 64 + 24, y: 64), 5, "and no further than 20")
        XCTAssertLessThan(pixels.red(x: 64, y: 192), 5, "nothing is drawn mirrored")
        XCTAssertEqual(renderer.drawsEncoded, 1, "one instanced draw per system")
    }

    func testSpriteThroughNoGeometryShaderStream() throws {
        let plan = try self.plan("materials/solid.json", renderer: "sprite", keeping: .expandedQuads)
        let pixels = try render(plan, particles: [particle(at: SIMD2(64, 192), size: 80),
                                                  particle(at: SIMD2(192, 64), size: 40)])
        XCTAssertGreaterThan(pixels.red(x: 64, y: 64), 250)
        XCTAssertGreaterThan(pixels.red(x: 192, y: 192), 250, "every instance draws")
        XCTAssertLessThan(pixels.red(x: 192 + 14, y: 192), 5)
        XCTAssertLessThan(pixels.red(x: 128, y: 128), 5)
    }

    func testBothPathsDrawTheSameRotatedSprite() throws {
        var rotated = particle(at: SIMD2(128, 128), size: 120)
        rotated.rotation = .pi / 4
        let emulated = try render(try plan("materials/solid.json", renderer: "sprite", keeping: .emulated(vertexCount: 6)),
                                  particles: [rotated])
        let expanded = try render(try plan("materials/solid.json", renderer: "sprite", keeping: .expandedQuads),
                                  particles: [rotated])
        let differing = zip(emulated.bytes, expanded.bytes).filter { abs(Int($0) - Int($1)) > 8 }.count
        XCTAssertLessThan(differing, 64, "the geometry stage and WE's stream agree (edge pixels aside)")
        // A 45° square reaches its corner along the axes (30·√2 ≈ 42) but not diagonally.
        XCTAssertGreaterThan(emulated.red(x: 128 + 38, y: 128), 250)
        XCTAssertLessThan(emulated.red(x: 128 + 26, y: 128 + 26), 5)
    }

    func testSpriteTrailStretchesAlongVelocity() throws {
        let plan = try self.plan("materials/solid.json", renderer: "spritetrail", keeping: .emulated(vertexCount: 6))
        var moving = particle(at: SIMD2(128, 128), size: 20)
        moving.velocity = SIMD2(200, 0)
        // length 0.05 · speed 200 = 10 sizes long (the default maxlength).
        let pixels = try render(plan, particles: [moving])
        XCTAssertGreaterThan(pixels.red(x: 128 + 40, y: 128), 250, "stretched along the velocity")
        XCTAssertLessThan(pixels.red(x: 128, y: 128 + 12), 5, "not across it")
    }

    func testRopeThroughEmulatedGeometryStage() throws {
        let plan = try self.plan("materials/solid.json", renderer: "rope", keeping: .emulated(vertexCount: 6))
        XCTAssertEqual(plan.shader, "genericropeparticle", "rope renderers swap in WE's rope shader")
        // A horizontal strand across the middle, as wide as the particles' size (the shader's
        // half width is half the size).
        let pixels = try render(plan, particles: [particle(at: SIMD2(32, 128), size: 20),
                                                  particle(at: SIMD2(128, 128), size: 20),
                                                  particle(at: SIMD2(224, 128), size: 20)])
        for x in [48, 128, 200] {
            XCTAssertGreaterThan(pixels.red(x: x, y: 128), 250, "strand at x \(x)")
            XCTAssertGreaterThan(pixels.red(x: x, y: 128 - 8), 250, "strand is 20 units wide at x \(x)")
            XCTAssertLessThan(pixels.red(x: x, y: 128 - 14), 5, "and no wider at x \(x)")
        }
    }

    func testSubdividedRopeCurvesThroughItsPoints() throws {
        let renderer = try decodeRenderer(#"{"name":"rope","subdivision":3}"#)
        let plan = try builder.build(materialPath: "materials/solid.json", renderer: renderer, flags: 0,
                                     baseTexture: .image(NSImage()), spriteSheet: nil)
        XCTAssertEqual(plan.stages.first?.geometry, .emulated(vertexCount: 3 * (4 + 3 * 2 - 2)))
        let pixels = try render(plan, particles: [particle(at: SIMD2(32, 64), size: 12),
                                                  particle(at: SIMD2(128, 192), size: 12),
                                                  particle(at: SIMD2(224, 64), size: 12)])
        XCTAssertGreaterThan(pixels.red(x: 128, y: 64), 250, "passes through the apex")
        XCTAssertLessThan(pixels.red(x: 128, y: 160), 5)
    }

    func testRopeThroughNoGeometryShaderStream() throws {
        let plan = try self.plan("materials/solid.json", renderer: "rope", keeping: .expandedQuads)
        let pixels = try render(plan, particles: [particle(at: SIMD2(32, 128), size: 20),
                                                  particle(at: SIMD2(224, 128), size: 20)])
        XCTAssertGreaterThan(pixels.red(x: 128, y: 128), 250)
        XCTAssertLessThan(pixels.red(x: 128, y: 64), 5)
    }

    func testRopeTrailFollowsEachParticlesHistory() throws {
        let plan = try self.plan("materials/solid.json", renderer: "ropetrail", keeping: .emulated(vertexCount: 6))
        var head = particle(at: SIMD2(200, 128), size: 16)
        // A full ring whose oldest sample sits at `historyStart`.
        head.history = [SIMD2(120, 128), SIMD2(40, 128)]
        head.historyStart = 1
        let pixels = try render(plan, particles: [head])
        for x in [60, 160] { XCTAssertGreaterThan(pixels.red(x: x, y: 128), 250, "trail at x \(x)") }
        XCTAssertLessThan(pixels.red(x: 230, y: 128), 5, "nothing past the particle")
    }

    func testRandomSpriteFramesShowOneFrameEvenWithFrameBlending() throws {
        // Two frames side by side: red, then green.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 2, height: 1, mipmapped: false)
        let sheet = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        sheet.replace(region: MTLRegionMake2D(0, 0, 2, 1), mipmapLevel: 0,
                      withBytes: [UInt8]([255, 0, 0, 255, 0, 255, 0, 255]), bytesPerRow: 8)
        let frames = SpriteSheet(columns: 2, rows: 1, frames: 2, duration: 1)
        let built = try builder.build(materialPath: "materials/solid.json", renderer: try decodeRenderer(#"{"name":"sprite"}"#),
                                      flags: 0, baseTexture: .image(NSImage()), spriteSheet: frames)
        let stage = try XCTUnwrap(built.stages.first { $0.geometry == .emulated(vertexCount: 6) })
        XCTAssertEqual(stage.variant.combos["SPRITESHEET"], 1)
        XCTAssertEqual(stage.variant.combos["SPRITESHEETBLEND"], 1, "blending is on unless the system's flag 2 is set")
        XCTAssertEqual(stage.variant.combos["THICKFORMAT"], 1)
        var plan = ParticleMaterialPlan(materialPath: built.materialPath, shader: built.shader, format: built.format,
                                        blending: built.blending, stages: [stage], trailLengths: built.trailLengths,
                                        spriteSheet: frames)
        // Clamped, so the frames' outer edges don't pull in the opposite frame.
        plan.textureFlags[0] = .clampUVs
        for frame in 0..<2 {
            let chosen = Particle(position: SIMD2(128, 128), velocity: .zero, age: 0, lifetime: 10, size: 80, baseSize: 80,
                                  alpha: 1, baseAlpha: 1, rotation: 0, angularVelocity: 0, color: SIMD4(repeating: 1),
                                  baseColor: SIMD4(repeating: 1), spriteFrame: frame, history: [], historyStart: 0)
            let pixels = try render(plan, particles: [chosen], texture: sheet, animationMode: "randomframe")
            let index = (128 * Self.size + 128) * 4
            let (own, other) = frame == 0 ? (pixels.bytes[index], pixels.bytes[index + 1])
                                          : (pixels.bytes[index + 1], pixels.bytes[index])
            XCTAssertGreaterThan(own, 250, "frame \(frame) shows")
            XCTAssertLessThan(other, 5, "without the other frame blended in (frame \(frame))")
        }
    }

    func testClampUVsKeepsTheOppositeEdgeOut() throws {
        // A texture whose top row is transparent and bottom row opaque white: repeat would pull
        // the bottom row into the top edge under bilinear filtering.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 4, mipmapped: false)
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 4), mipmapLevel: 0,
                        withBytes: [UInt8]([0, 0, 0, 0, 0, 0, 0, 0, 255, 255, 255, 255, 255, 255, 255, 255]), bytesPerRow: 4)
        var plan = try self.plan("materials/solid.json", renderer: "sprite", keeping: .emulated(vertexCount: 6))
        // A 1×4 texture makes the quad 4× taller than wide: 20 × 80 around the centre.
        let topRow = 128 - 39
        plan.textureFlags[0] = .clampUVs
        let clamped = try render(plan, particles: [particle(at: SIMD2(128, 128), size: 40)], texture: texture)
        XCTAssertLessThan(clamped.red(x: 128, y: topRow), 5, "clamped: the top edge stays transparent")
        plan.textureFlags[0] = []
        let repeated = try render(plan, particles: [particle(at: SIMD2(128, 128), size: 40)], texture: texture)
        XCTAssertGreaterThan(repeated.red(x: 128, y: topRow), 20, "WE's default repeat wraps the bottom row in")
    }

    // MARK: Geometry stages beyond WE's own

    /// `stripquads.geom` emits `size / 20` separate 20-unit quads (one strip each, 20 units apart)
    /// under a bound of 16 vertices.
    private func stripQuads(size: Float, cull: (MTLCullMode, MTLWinding)? = nil) throws -> Pixels {
        let plan = try self.plan("materials/stripquads.json", renderer: "sprite", keeping: .emulated(vertexCount: 3 * 14))
        return try render(plan, particles: [particle(at: SIMD2(48, 128), size: size)], cull: cull)
    }

    func testRestartedStripsLeaveTheGapsBetweenThem() throws {
        let pixels = try stripQuads(size: 60)
        for x in [48, 88, 128] { XCTAssertGreaterThan(pixels.red(x: x, y: 128), 250, "quad at x \(x)") }
        for x in [68, 108] { XCTAssertLessThan(pixels.red(x: x, y: 128), 5, "no triangle bridges the strips at x \(x)") }
    }

    func testEmittingFewerVerticesThanTheBoundDrawsOnlyThoseTriangles() throws {
        let one = try stripQuads(size: 20)
        XCTAssertGreaterThan(one.red(x: 48, y: 128), 250)
        let lit = stride(from: 0, to: one.bytes.count, by: 4).filter { one.bytes[$0] > 128 }.count
        XCTAssertEqual(Double(lit), 400, accuracy: 44, "one 20 × 20 quad and nothing else")
        let three = try stripQuads(size: 60)
        XCTAssertLessThan(three.red(x: 168, y: 128), 5, "a fourth quad the bound allows is not drawn")
    }

    func testStripTrianglesKeepOneWinding() throws {
        // With back faces culled, a quad whose two triangles wound differently would lose half.
        var counts: [Int] = []
        for winding in [MTLWinding.clockwise, .counterClockwise] {
            let pixels = try stripQuads(size: 60, cull: (.back, winding))
            counts.append(stride(from: 0, to: pixels.bytes.count, by: 4).filter { pixels.bytes[$0] > 128 }.count)
        }
        XCTAssertEqual(counts.min(), 0, "every triangle faces the same way: \(counts)")
        XCTAssertEqual(Double(counts.max() ?? 0), 1200, accuracy: 100, "three whole quads: \(counts)")
    }

    func testBuilderReadsTheTextureFlags() throws {
        let plan = try builder.build(materialPath: "materials/particle/halo.json", renderer: nil, flags: 0,
                                     baseTexture: .image(NSImage()), spriteSheet: nil)
        XCTAssertEqual(plan.textureFlags[0], .clampUVs, "WE's halo.tex clamps")
        let data = try XCTUnwrap(FileManager.default.contents(
            atPath: ShaderVariantTests.weAssets.appending(path: "materials/particle/beam/hose_1.tex").path))
        XCTAssertEqual(TEXFlags(texData: data)?.contains(.clampUVs), false, "rope hoses repeat along the rope")
    }

    func testAdditiveBlendingAndMaterialConstants() throws {
        let plan = try self.plan("materials/additive_overbright.json", renderer: "sprite", keeping: .emulated(vertexCount: 6))
        XCTAssertEqual(plan.blending, "additive")
        // Two overlapping sprites at half brightness (`g_Overbright` 0.5) add up.
        let pixels = try render(plan, particles: [particle(at: SIMD2(128, 128), size: 80),
                                                  particle(at: SIMD2(138, 128), size: 80)])
        XCTAssertEqual(Double(pixels.red(x: 110, y: 128)), 128, accuracy: 3, "one sprite: half")
        XCTAssertGreaterThan(pixels.red(x: 133, y: 128), 250, "overlap: both added")
    }

    func testRefractionFallsBackToTheBuiltInDraw() throws {
        let plan = try builder.build(materialPath: "materials/refract.json", renderer: nil, flags: 0,
                                     baseTexture: .image(NSImage()), spriteSheet: nil)
        XCTAssertTrue(plan.stages.allSatisfy(\.readsSceneSnapshot))
        let system = ParticleSystemRuntime(texture: white, configuration: Self.configuration(plan: plan))
        XCTAssertFalse(renderer.prepare(system, pixelFormat: .rgba8Unorm, opacity: { _ in 1 }))
    }

    func testFailedPipelineFallsBackToTheBuiltInDraw() throws {
        let good = try plan("materials/solid.json", renderer: "sprite", keeping: .emulated(vertexCount: 6))
        let stage = try XCTUnwrap(good.stages.first)
        let broken = ParticleMaterialPlan.Stage(
            geometry: stage.geometry,
            variant: TranslatedShaderVariant(vertexMSL: "not metal", fragmentMSL: stage.variant.fragmentMSL,
                                             uniforms: stage.variant.uniforms, textureSlots: stage.variant.textureSlots,
                                             attributes: stage.variant.attributes, combos: stage.variant.combos),
            variantKey: "broken", textures: stage.textures, constants: stage.constants)
        let plan = ParticleMaterialPlan(materialPath: good.materialPath, shader: good.shader, format: good.format,
                                        blending: good.blending, stages: [broken], trailLengths: good.trailLengths,
                                        spriteSheet: nil)
        let system = ParticleSystemRuntime(texture: white, configuration: Self.configuration(plan: plan))
        XCTAssertTrue(renderer.waitUntilCompiled(plan, pixelFormat: .rgba8Unorm))
        XCTAssertNotNil(renderer.pipelineFailure(broken, plan: plan, pixelFormat: .rgba8Unorm))
        XCTAssertFalse(renderer.prepare(system, pixelFormat: .rgba8Unorm, opacity: { _ in 1 }))
    }

    func testSpriteSheetFrameVariables() {
        let info = BuiltinTextureInfo(allocatedSize: SIMD2(512, 512), contentSize: SIMD2(400, 300))
        let value = ParticleMaterialUniforms.spriteSheetRenderVar(SpriteSheet(columns: 4, rows: 3, frames: 12, duration: 1),
                                                                   texture: info)
        XCTAssertEqual(value.x, 100 / 512, accuracy: 1e-6)
        XCTAssertEqual(value.y, 100 / 512, accuracy: 1e-6)
        XCTAssertEqual(value.z, 12)
        XCTAssertEqual(value.w, 1, accuracy: 1e-6)
    }

    // MARK: - Helpers

    private func decodeRenderer(_ json: String) throws -> WEParticleRenderer {
        try JSONDecoder().decode(WEParticleRenderer.self, from: Data(json.utf8))
    }

    /// Builds the material for `renderer` and keeps only the stage of the path under test.
    private func plan(_ material: String, renderer name: String,
                      keeping geometry: ParticleMaterialPlan.Stage.Geometry) throws -> ParticleMaterialPlan {
        let plan = try builder.build(materialPath: material, renderer: try decodeRenderer(#"{"name":"\#(name)"}"#),
                                     flags: 0, baseTexture: .image(NSImage()), spriteSheet: nil)
        let stages = plan.stages.filter { $0.geometry == geometry }
        XCTAssertEqual(stages.count, 1, "\(material) \(name): \(plan.stages.map(\.geometry))")
        return ParticleMaterialPlan(materialPath: plan.materialPath, shader: plan.shader, format: plan.format,
                                    blending: plan.blending, stages: stages, trailLengths: plan.trailLengths,
                                    spriteSheet: plan.spriteSheet)
    }

    private func particle(at position: SIMD2<Float>, size: Float) -> Particle {
        Particle(position: position, velocity: .zero, age: 0, lifetime: 10, size: size, baseSize: size,
                 alpha: 1, baseAlpha: 1, rotation: 0, angularVelocity: 0, color: SIMD4(repeating: 1),
                 baseColor: SIMD4(repeating: 1), spriteFrame: 0, history: [], historyStart: 0)
    }

    struct Pixels {
        let bytes: [UInt8]
        let width: Int
        /// Row 0 is the top of the scene.
        func red(x: Int, y: Int) -> UInt8 { bytes[(y * width + x) * 4] }
    }

    struct NoValues: SceneValueContext {
        func userProperty(_ name: String) -> String? { nil }
        func evaluateScript(_ source: String, properties: SceneScriptProperties, current: ShaderValue) -> ShaderValue? { nil }
        var time: Double { 0 }
    }

    private func render(_ plan: ParticleMaterialPlan, particles: [Particle], texture: MTLTexture? = nil,
                        animationMode: String = "sequence", cull: (MTLCullMode, MTLWinding)? = nil) throws -> Pixels {
        let size = Self.size
        XCTAssertTrue(renderer.waitUntilCompiled(plan, pixelFormat: .rgba8Unorm), "pipelines still compiling")
        for stage in plan.stages {
            XCTAssertNil(renderer.pipelineFailure(stage, plan: plan, pixelFormat: .rgba8Unorm))
        }
        let system = ParticleSystemRuntime(texture: texture ?? white,
                                           configuration: Self.configuration(plan: plan, animationMode: animationMode))
        system.particles = particles
        XCTAssertTrue(renderer.prepare(system, pixelFormat: .rgba8Unorm, opacity: { _ in 1 }), "draws through the material")

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        let buffer = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(buffer.makeRenderCommandEncoder(descriptor: pass))
        if let cull {
            encoder.setCullMode(cull.0)
            encoder.setFrontFacing(cull.1)
        }
        renderer.draw(system, encoder: encoder, context: .init(
            sceneSize: SIMD2(Float(size), Float(size)), frame: BuiltinFrameContext(), values: NoValues(),
            assetTexture: { _, _ in nil }))
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        XCTAssertNil(buffer.error)
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        target.getBytes(&bytes, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        return Pixels(bytes: bytes, width: size)
    }

    /// A system with every simulation setting neutral; only the renderer fields matter here.
    static func configuration(plan: ParticleMaterialPlan, animationMode: String = "sequence") -> SceneMetalParticleSystem {
        let trail = plan.stages.first?.variant.combos["TRAILRENDERER"] == 1
        let rendererName = plan.format == .rope ? (trail ? "ropetrail" : "rope") : (trail ? "spritetrail" : "sprite")
        var system = SceneMetalParticleSystem(
            source: .image(NSImage()), origin: .zero, emissionRate: 0, emissionRateScript: nil, maximumParticleCount: 100,
            spawnExtent: .zero, lifetime: 1...1, size: 1...1, minimumVelocity: .zero, maximumVelocity: .zero, gravity: .zero,
            drag: 0, dragScript: nil, alpha: 1...1, minimumColor: SIMD4(repeating: 1), maximumColor: SIMD4(repeating: 1),
            minimumRotation: 0, maximumRotation: 0, minimumAngularVelocity: 0, maximumAngularVelocity: 0,
            emitterName: "sphererandom", sizeChange: nil, alphaChange: nil, colorChange: nil, angularAcceleration: 0,
            maximumSpeed: nil, vortex: nil, boids: nil, oscillateSize: nil, oscillateAlpha: nil, oscillatePosition: nil,
            positionOffsetMinimum: .zero, positionOffsetMaximum: .zero, remapAlpha: nil, nearControlPointReduction: nil,
            maintainControlPointDistance: nil, controlPoints: [], sequenceSpan: nil, sequenceRing: nil, initialRemap: nil,
            maintainSequenceDistance: false, rendererName: rendererName, trailLength: 1, trailSegments: 4,
            ropeSubdivision: 1, fadeTrailAlpha: false, fadeTrailSize: false, turbulence: nil, attractor: nil,
            cursorControlPoint: nil, emitterControlPoint: nil, spriteSheet: plan.spriteSheet, animationMode: animationMode,
            sequenceMultiplier: 1, opacityMultiplier: 1, refractive: false, fadeIn: 0, fadeOut: 1,
            fadeInScript: nil, fadeOutScript: nil, blending: plan.blending)
        system.material = plan
        return system
    }
}
