import XCTest
import MetalKit
@testable import OpenWallpaperEngine

/// Headless checks that the scene pipeline actually produces what WE content needs. Known gaps are
/// recorded with XCTExpectFailure (strict), so fixing one makes its test fail until the expectation
/// is removed, and the gap can't be forgotten.
final class RenderCheckTests: XCTestCase {
    func testLoaderKeepsEveryVisibleLayer() throws {
        let directory = Fixtures.url("Scenes/layers")
        let project = try JSONDecoder().decode(WEProject.self, from: Fixtures.data("Scenes/layers/project.json"))
        let wallpaper = WEWallpaper(using: project, where: directory)
        defer {
            Fixtures.removeStoredSettings(for: directory)
        }
        let content = try XCTUnwrap(SceneWallpaperViewModel(wallpaper: wallpaper).metalContent())
        let ids = Set(content.layers.map(\.id))
        XCTAssertTrue(ids.contains("1"), "text layer missing; layers: \(ids)")
        // Kept, but it samples _rt_FullFrameBuffer, which is still a transparent placeholder (B1);
        // a pixel check belongs to the Phase 3 compositing work.
        // A composition layer only exists while its effect can run, which needs WE's shader sources.
        if Fixtures.hasWEShaderSources {
            XCTAssertTrue(ids.contains("3"), "composition layer missing; layers: \(ids)")
        }
        XCTAssertTrue(ids.contains("2"), "solid layer missing; layers: \(ids)")
        // Risk I18: text without effects draws through WE's `font` material.
        let text = try XCTUnwrap(content.layers.first { $0.id == "1" })
        XCTAssertEqual(text.imageMaterial?.materialPath, "materials/fonts/basefont.json")
    }

    /// 2963872291's 'Player Options' is a white solid layer sized "0 0" (a host for the music
    /// player's scripts) centred on the bottom edge at 1.4×. WE draws nothing of an empty quad; a
    /// scene-sized stand-in painted the bottom half of the screen white.
    func testZeroSizeSolidLayerDrawsNothing() throws {
        let size = SIMD2(480, 272)
        let directory = Fixtures.url("Scenes/zero-size-solid")
        let project = try JSONDecoder().decode(WEProject.self, from: Fixtures.data("Scenes/zero-size-solid/project.json"))
        defer { Fixtures.removeStoredSettings(for: directory) }
        let content = try XCTUnwrap(SceneWallpaperViewModel(wallpaper: WEWallpaper(using: project, where: directory)).metalContent())
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: size.x, height: size.y), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: size.x, height: size.y)
        let renderer = try XCTUnwrap(SceneMetalRenderer(view: view, scriptServices: nil, screenID: "zero-size-solid"))
        defer { renderer.releaseContent() }
        view.isPaused = true
        renderer.setPlacement(.stretch)
        renderer.setContent(content)
        var drawn = 0
        let deadline = Date().addingTimeInterval(30)
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            renderer.draw(in: view)
            renderer.lastCommandBuffer?.waitUntilCompleted()
            if renderer.hasContent { drawn += 1 }
        } while drawn < 3 && Date() < deadline
        XCTAssertTrue(renderer.hasContent)
        var bytes = [UInt8](repeating: 0, count: size.x * size.y * 4)
        view.currentDrawable?.texture.getBytes(&bytes, bytesPerRow: size.x * 4,
                                               from: MTLRegionMake2D(0, 0, size.x, size.y), mipmapLevel: 0)
        // The whole frame, the bottom half included, is the blue background (bgra bytes).
        for y in stride(from: 8, to: size.y, by: 16) {
            for x in stride(from: 8, to: size.x, by: 16) {
                let i = (y * size.x + x) * 4
                XCTAssertEqual(SIMD3(bytes[i + 2], bytes[i + 1], bytes[i]), SIMD3(0, 0, 255), "pixel (\(x), \(y))")
            }
        }
    }

    /// WE sizes a textureless layer's effect buffers to its `size` (0x140209206…0x14020923c),
    /// not to the 1×1 fill its quad stretches. The fixture's effect writes the pixel's u into red:
    /// at the layer's size it ramps across the layer; on a 1×1 buffer the layer was one flat colour.
    func testSolidLayerEffectsRunAtTheLayersSize() throws {
        XCTAssertEqual(SolidEffectInput.size(SIMD2(128, 64)), SIMD2(128, 64))
        XCTAssertEqual(SolidEffectInput.size(SIMD2(100.5, 0.4)), SIMD2(101, 1))
        let size = SIMD2(128, 64)
        let directory = Fixtures.url("Scenes/solid-effect")
        let project = try JSONDecoder().decode(WEProject.self, from: Fixtures.data("Scenes/solid-effect/project.json"))
        defer { Fixtures.removeStoredSettings(for: directory) }
        let content = try XCTUnwrap(SceneWallpaperViewModel(wallpaper: WEWallpaper(using: project, where: directory)).metalContent())
        let layer = try XCTUnwrap(content.layers.first)
        XCTAssertEqual(layer.solidFill, SIMD4(0, 0, 1, 1))
        try XCTSkipIf(layer.weEffects.isEmpty, "no shader toolchain for the fixture's effect")
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: size.x, height: size.y), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: size.x, height: size.y)
        let renderer = try XCTUnwrap(SceneMetalRenderer(view: view, scriptServices: nil, screenID: "solid-effect"))
        defer { renderer.releaseContent() }
        view.isPaused = true
        renderer.setPlacement(.stretch)
        renderer.setContent(content)
        var bytes = [UInt8](repeating: 0, count: size.x * size.y * 4)
        // (r, g, b) at a view pixel.
        func rgb(_ x: Int, _ y: Int) -> SIMD3<UInt8> {
            let i = (y * size.x + x) * 4
            return SIMD3(bytes[i + 2], bytes[i + 1], bytes[i])
        }
        let deadline = Date().addingTimeInterval(60)
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            renderer.draw(in: view)
            renderer.lastCommandBuffer?.waitUntilCompleted()
            view.currentDrawable?.texture.getBytes(&bytes, bytesPerRow: size.x * 4,
                                                   from: MTLRegionMake2D(0, 0, size.x, size.y), mipmapLevel: 0)
        } while rgb(size.x - 4, 32).x == 0 && Date() < deadline
        let left = rgb(4, 32), middle = rgb(64, 32), right = rgb(size.x - 4, 32)
        XCTAssertLessThan(left.x, 16, "left \(left)")
        XCTAssertEqual(Int(middle.x), 128, accuracy: 4, "middle \(middle)")
        XCTAssertGreaterThan(right.x, 240, "right \(right)")
        XCTAssertEqual(right.z, 255, "the fill's blue under the ramp")
    }
}
