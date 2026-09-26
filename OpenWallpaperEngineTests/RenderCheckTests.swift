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
}
