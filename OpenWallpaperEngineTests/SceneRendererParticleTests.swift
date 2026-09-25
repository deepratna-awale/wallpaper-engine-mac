import XCTest
import MetalKit
import AppKit
@testable import OpenWallpaperEngine

/// Whole frames of `SceneMetalRenderer` with a particle system between two layers, simulated on
/// the GPU and on the CPU: particles cover the layer below and are covered by the layer above.
final class SceneRendererParticleTests: XCTestCase {
    private static let size = 128

    func testGPUSimulatedParticlesDrawBetweenTheirLayers() throws {
        try assertDrawOrder(simulation: .gpu, material: false)
    }

    func testCPUSimulatedParticlesDrawBetweenTheirLayers() throws {
        try assertDrawOrder(simulation: .cpu, material: false)
    }

    func testGPUSimulatedParticlesDrawThroughTheirMaterialBetweenTheirLayers() throws {
        try assertDrawOrder(simulation: .gpu, material: true)
    }

    func testCPUSimulatedParticlesDrawThroughTheirMaterialBetweenTheirLayers() throws {
        try assertDrawOrder(simulation: .cpu, material: true)
    }

    // MARK: - Helpers

    private func assertDrawOrder(simulation: SceneMetalRenderer.ParticleSimulation, material: Bool,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: Self.size, height: Self.size), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: Self.size, height: Self.size)
        let renderer = try XCTUnwrap(SceneMetalRenderer(view: view, particleSimulation: simulation))
        view.isPaused = true
        renderer.setPlacement(.stretch)

        let scene = Float(Self.size)
        // A: red under everything. B: blue over the left half, above the particles.
        let below = layer("A", color: [1, 0, 0, 1], center: SIMD2(scene / 2, scene / 2), size: SIMD2(scene, scene), order: 0)
        let above = layer("B", color: [0, 0, 1, 1], center: SIMD2(scene / 4, scene / 2), size: SIMD2(scene / 2, scene), order: 2)
        var system = ParticleTestSystem()
        system.origin = SIMD2(scene / 2, scene / 2)
        system.spawnExtent = .zero
        system.minimumVelocity = .zero
        system.maximumVelocity = .zero
        system.size = 100...100
        system.lifetime = 100...100
        system.alpha = 1...1
        system.minimumColor = SIMD4(repeating: 1)
        system.maximumColor = SIMD4(repeating: 1)
        system.fadeIn = 0
        system.fadeOut = 1
        system.maximum = 5
        system.source = .image(image([1, 1, 1, 1]))
        if material { system.material = try solidMaterial() }
        var configuration = system.configuration
        configuration.order = 1
        let content = SceneMetalContent(size: SIMD2(scene, scene), layers: [below, above], particleSystems: [configuration],
                                        sceneScript: nil,
                                        bloom: SceneBloomSettings(enabled: false, strength: 0, threshold: 0.7, tint: SIMD3(repeating: 1)))
        renderer.setContent(content)

        // Content loads off the main thread, and material pipelines compile in the background.
        var pixels: [UInt8] = []
        let deadline = Date().addingTimeInterval(10)
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            renderer.draw(in: view)
            renderer.lastCommandBuffer?.waitUntilCompleted()
            guard let texture = view.currentDrawable?.texture else { continue }
            pixels = [UInt8](repeating: 0, count: Self.size * Self.size * 4)
            texture.getBytes(&pixels, bytesPerRow: Self.size * 4,
                             from: MTLRegionMake2D(0, 0, Self.size, Self.size), mipmapLevel: 0)
            // WE's shader draws the sprite half its size wide (a 50-unit square here); the
            // built-in draw a 100-unit disc. The material compiles in the background meanwhile.
        } while Date() < deadline && !(isWhite(pixels, x: 80, y: 64) && isBlue(pixels, x: 50, y: 64)
                                       && (material ? isRed(pixels, x: 100, y: 64) : isWhite(pixels, x: 100, y: 64)))
        XCTAssertFalse(pixels.isEmpty, "a drawable to read", file: file, line: line)
        guard !pixels.isEmpty else { return }
        XCTAssertTrue(isWhite(pixels, x: 80, y: 64), "particles cover the layer below: \(bgra(pixels, x: 80, y: 64))", file: file, line: line)
        XCTAssertTrue(isBlue(pixels, x: 50, y: 64), "the layer above covers the particles: \(bgra(pixels, x: 50, y: 64))", file: file, line: line)
        XCTAssertTrue(isRed(pixels, x: 120, y: 64), "the layer below shows elsewhere: \(bgra(pixels, x: 120, y: 64))", file: file, line: line)
        XCTAssertTrue(isBlue(pixels, x: 10, y: 64), file: file, line: line)
        if material {
            XCTAssertTrue(isRed(pixels, x: 100, y: 64), "drawn through WE's shader: \(bgra(pixels, x: 100, y: 64))", file: file, line: line)
        } else {
            XCTAssertTrue(isWhite(pixels, x: 100, y: 64), "the built-in disc: \(bgra(pixels, x: 100, y: 64))", file: file, line: line)
        }
    }

    private func bgra(_ pixels: [UInt8], x: Int, y: Int) -> [UInt8] {
        guard pixels.count >= Self.size * Self.size * 4 else { return [] }
        let index = (y * Self.size + x) * 4
        return Array(pixels[index..<index + 4])
    }

    private func isWhite(_ pixels: [UInt8], x: Int, y: Int) -> Bool {
        let p = bgra(pixels, x: x, y: y)
        return p.count == 4 && p[0] > 250 && p[1] > 250 && p[2] > 250
    }

    private func isBlue(_ pixels: [UInt8], x: Int, y: Int) -> Bool {
        let p = bgra(pixels, x: x, y: y)
        return p.count == 4 && p[0] > 250 && p[1] < 5 && p[2] < 5
    }

    private func isRed(_ pixels: [UInt8], x: Int, y: Int) -> Bool {
        let p = bgra(pixels, x: x, y: y)
        return p.count == 4 && p[0] < 5 && p[1] < 5 && p[2] > 250
    }

    private func solidMaterial() throws -> ParticleMaterialPlan {
        let roots = [Fixtures.url("Particles"), ShaderVariantTests.weAssets]
        let builder = ParticleMaterialPlanBuilder(
            translator: ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: nil),
            readFile: { path in roots.lazy.compactMap { FileManager.default.contents(atPath: $0.appending(path: path).path) }.first },
            loadTexture: { _, _ in nil })
        let renderer = try JSONDecoder().decode(WEParticleRenderer.self, from: Data(#"{"name":"sprite"}"#.utf8))
        return try builder.build(materialPath: "materials/solid.json", renderer: renderer, flags: 0,
                                 baseTexture: .image(NSImage()), spriteSheet: nil)
    }

    /// Exact texels, not AppKit drawing (which colour-matches `NSColor.red` to about (237, 47, 25)).
    private func image(_ rgba: [Double]) -> NSImage { SceneWallpaperViewModel.pixelImage(rgba) }

    private func layer(_ id: String, color: [Double], center: SIMD2<Float>, size: SIMD2<Float>, order: Int) -> SceneMetalLayer {
        var layer = SceneMetalLayer(
            id: id, name: id, source: .image(image(color)), position: center, size: size, scale: SIMD2(1, 1),
            scaleScript: nil, scaleAnimation: nil, opacity: 1, opacityScript: nil, opacityAnimation: nil,
            brightness: 1, brightnessScript: nil, color: SIMD4(repeating: 1), colorScript: nil, text: nil,
            parallaxDepth: .zero, perspective: false, positionScript: nil, positionScriptProperties: [:],
            positionAnimation: nil, sizeScript: nil, sizeAnimation: nil, rotation: 0, rotationScript: nil,
            rotationAnimation: nil,
            effects: SceneMaterialEffects(brightness: 1, contrast: 1, saturation: 1, bloom: 0, blur: 0, exposure: 0,
                                          gamma: 1, hue: 0, bloomThreshold: 0.7, transformAngle: 0, transformOffset: .zero,
                                          transformScale: SIMD2(1, 1), scripts: [:]))
        layer.order = order
        return layer
    }
}
