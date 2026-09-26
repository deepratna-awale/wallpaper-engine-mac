import XCTest
import MetalKit
@testable import OpenWallpaperEngine

/// End to end (docs/scenescript-plan.md WP11): scenes loaded through the real loader, drawn
/// headlessly by the renderer with its SceneScript runtime, and script writes checked in the
/// pixels: an origin moves a layer, visibility scripts show and hide layers, a material constant
/// changes an effect's output, `createLayer` draws, and a text script changes the text.
final class SceneScriptRenderTests: XCTestCase {
    private var storage: URL!

    override func setUpWithError() throws {
        storage = FileManager.default.temporaryDirectory.appending(path: "owe-render-scripts-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let storage, FileManager.default.fileExists(atPath: storage.path) {
            try FileManager.default.removeItem(at: storage)
        }
    }

    // MARK: - Pixels

    func testScriptWritesReachThePixels() throws {
        let scene = try Scene(fixture: "scripted", services: services(), size: SIMD2(128, 64))
        defer { scene.close() }
        // Effect pipelines compile off the render thread; the tinted layer draws plain until then.
        let pixels = try scene.render(frames: 6) { !Fixtures.hasWEShaderSources || $0.color(atScene: SIMD2(16, 16)) != .white }

        XCTAssertEqual(pixels.color(atScene: SIMD2(48, 32)), .red, "the origin script moved Mover to x = 48")
        XCTAssertEqual(pixels.color(atScene: SIMD2(8, 32)), .black, "nothing is left where Mover was authored")
        XCTAssertEqual(pixels.color(atScene: SIMD2(32, 56)), .green, "a layer hidden at load is shown by its script")
        XCTAssertEqual(pixels.color(atScene: SIMD2(32, 8)), .black, "a visible layer is hidden by its script")
        XCTAssertEqual(pixels.color(atScene: SIMD2(56, 56)), .yellow, "the layer createLayer made is drawn")
        XCTAssertGreaterThan(pixels.litPixels(from: SIMD2(70, 20), to: SIMD2(122, 44)), 40,
                             "the text script's string (a user-bound script property) is drawn")
        if Fixtures.hasWEShaderSources {
            XCTAssertEqual(pixels.color(atScene: SIMD2(16, 16)), .green, "the constant script turned the tint green")
        }
    }

    /// Without scripts the same scene shows what scene.json authored: a baseline for the test above.
    func testTheSameSceneWithoutScriptsShowsTheAuthoredValues() throws {
        let scene = try Scene(fixture: "scripted", services: nil, size: SIMD2(128, 64))
        defer { scene.close() }
        let pixels = try scene.render(frames: 3) { !Fixtures.hasWEShaderSources || $0.color(atScene: SIMD2(16, 16)) != .white }

        XCTAssertEqual(pixels.color(atScene: SIMD2(8, 32)), .red)
        XCTAssertEqual(pixels.color(atScene: SIMD2(48, 32)), .black)
        XCTAssertEqual(pixels.color(atScene: SIMD2(32, 56)), .black, "hidden at load, still built")
        XCTAssertEqual(pixels.color(atScene: SIMD2(32, 8)), .blue)
        XCTAssertEqual(pixels.color(atScene: SIMD2(56, 56)), .black)
        XCTAssertEqual(pixels.litPixels(from: SIMD2(70, 20), to: SIMD2(122, 44)), 0)
        if Fixtures.hasWEShaderSources {
            XCTAssertEqual(pixels.color(atScene: SIMD2(16, 16)), .blue)
        }
    }

    // MARK: - Instances

    /// S22: two displays showing the same wallpaper run two runtimes that share nothing: module
    /// variables, `shared` and frame counts are their own.
    func testTwoDisplaysShareNothing() throws {
        let services = services()
        let first = try Scene(fixture: "scripted-counter", services: services, size: SIMD2(64, 64), screenID: "A")
        defer { first.close() }
        let second = try Scene(fixture: "scripted-counter", services: services, size: SIMD2(64, 64), screenID: "B")
        defer { second.close() }
        _ = try first.render(frames: 10)
        _ = try second.render(frames: 3)

        let a = try XCTUnwrap(first.origin(of: "1"))
        let b = try XCTUnwrap(second.origin(of: "1"))
        XCTAssertEqual(a.x, b.x + 7, "each runtime counts its own frames")
        XCTAssertEqual(a.y, a.x, "`shared` is the runtime's own")
        XCTAssertEqual(b.y, b.x, "`shared` is the runtime's own")
        XCTAssertNotIdentical(first.renderer.scripts.wallpaper, second.renderer.scripts.wallpaper)
    }

    /// A user property only scripts read reaches `applyUserProperties` without a content rebuild.
    func testAScriptOnlyUserPropertyReachesTheScriptsWithoutARebuild() throws {
        let scene = try Scene(fixture: "scripted-counter", services: services(), size: SIMD2(64, 64))
        defer { scene.close() }
        _ = try scene.render(frames: 2)
        XCTAssertEqual(scene.model.impact(of: ["offset"]), .none, "only a script reads it")

        let key = scene.model.propertyStoreKey
        WallpaperServices.shared.setUserProperties(["offset": "42"], wallpaper: key, replacing: false)
        scene.renderer.scripts.userPropertiesDidChange(["offset"])
        _ = try scene.render(frames: 2)
        XCTAssertEqual(scene.origin(of: "1")?.z, 42, "applyUserProperties({offset: 42})")
    }

    /// The watchdog stops a hung script's wallpaper (plan §1.9 P5): the renderer is told once and
    /// keeps drawing, and another display's scripts keep running.
    func testAHungScriptHaltsOnlyItsWallpaper() throws {
        var configuration = SceneScriptRuntime.Configuration.standard
        configuration.frameTimeLimit = 0.3
        let services = services(configuration: configuration)
        let hung = try Scene(fixture: "scripted-hang", services: services, size: SIMD2(64, 64), screenID: "A")
        defer { hung.close() }
        let healthy = try Scene(fixture: "scripted-counter", services: services, size: SIMD2(64, 64), screenID: "B")
        defer { healthy.close() }
        var halts: [SceneScriptError?] = []
        hung.renderer.scripts.onHalt = { halts.append($0) }

        _ = try hung.render(frames: 8)
        _ = try healthy.render(frames: 4)
        XCTAssertEqual(halts.count, 1, "reported once")
        XCTAssertEqual(halts.first??.kind, .terminated)
        XCTAssertTrue(hung.renderer.scripts.state.halted)
        XCTAssertEqual(hung.origin(of: "1")?.x, 3, "the last values stay")
        XCTAssertEqual(healthy.origin(of: "1")?.x, 4, "the other display's scripts go on")
    }

    // MARK: - Draw order

    func testDrawOrderPutsParticlesBetweenTheLayersAroundThem() {
        let layers = [(id: "1", order: 0), (id: "3", order: 2)]
        let systems: [(id: String?, order: Int)] = [(id: "2", order: 1)]
        let authored = SceneRendererScripts.drawOrder(layers: layers, systems: systems, scriptOrder: nil)
        XCTAssertEqual(authored.sequence, [0, 1])
        XCTAssertEqual(authored.barriers, [0, 2], "the system (order 1) draws before layer 3")

        let sorted = SceneRendererScripts.drawOrder(layers: layers, systems: systems, scriptOrder: [3, 1, 2])
        XCTAssertEqual(sorted.sequence, [1, 0], "layer 3 was sorted to the bottom")
        XCTAssertEqual(sorted.barriers, [Int.min, Int.min], "no system sits below either layer now")
    }

    // MARK: - Support

    private func services(configuration: SceneScriptRuntime.Configuration = .standard) -> SceneScriptServices {
        SceneScriptServices(prelude: SceneScriptPrelude.load(), storage: SceneScriptStorage(directory: storage),
                            media: SceneScriptReplayMediaSource(), spectrum: { .silent }, configuration: configuration)
    }

    /// One scene fixture on one display: its loader, renderer and offscreen view.
    private final class Scene {
        let model: SceneWallpaperViewModel
        let renderer: SceneMetalRenderer
        let view: MTKView
        let directory: URL
        let size: SIMD2<Int>

        init(fixture: String, services: SceneScriptServices?, size: SIMD2<Int>, screenID: String = "test") throws {
            directory = Fixtures.url("Scenes/\(fixture)")
            self.size = size
            let project = try JSONDecoder().decode(WEProject.self, from: Fixtures.data("Scenes/\(fixture)/project.json"))
            model = SceneWallpaperViewModel(wallpaper: WEWallpaper(using: project, where: directory))
            let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
            view = MTKView(frame: CGRect(x: 0, y: 0, width: size.x, height: size.y), device: device)
            view.colorPixelFormat = .bgra8Unorm
            view.framebufferOnly = false
            view.autoResizeDrawable = false
            view.drawableSize = CGSize(width: size.x, height: size.y)
            renderer = try XCTUnwrap(SceneMetalRenderer(view: view, scriptServices: services, screenID: screenID))
            view.isPaused = true
            renderer.setPlacement(.stretch)
            renderer.setContent(try XCTUnwrap(model.metalContent()))
        }

        func close() {
            renderer.releaseContent()
            Fixtures.removeStoredSettings(for: directory)
        }

        /// Draws `frames` frames, each after the scripts finished the previous one, then more until
        /// `ready` holds, and returns the last one's pixels. Waits for the content (and layers
        /// scripts create) to be built.
        func render(frames: Int, until ready: (Pixels) -> Bool = { _ in true }) throws -> Pixels {
            let deadline = Date().addingTimeInterval(30)
            var drawn = 0
            var pixels = Pixels(bytes: [], size: size)
            repeat {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                renderer.draw(in: view)
                renderer.lastCommandBuffer?.waitUntilCompleted()
                renderer.scripts.wallpaper?.waitUntilIdle()
                if renderer.hasContent { drawn += 1 }
                pixels = read()
            } while (drawn < frames || renderer.pendingScriptLayers > 0 || !ready(pixels)) && Date() < deadline
            return pixels
        }

        private func read() -> Pixels {
            var bytes = [UInt8](repeating: 0, count: size.x * size.y * 4)
            view.currentDrawable?.texture.getBytes(&bytes, bytesPerRow: size.x * 4,
                                                   from: MTLRegionMake2D(0, 0, size.x, size.y), mipmapLevel: 0)
            return Pixels(bytes: bytes, size: size)
        }

        func origin(of id: String) -> SIMD3<Float>? {
            renderer.scripts.wallpaper?.waitUntilIdle()
            _ = renderer.scripts.beginFrame()
            return renderer.scripts.object(id)?.vector3(.origin)
        }
    }

    enum Color: Equatable {
        case black, white, red, green, blue, yellow, other
    }

    struct Pixels {
        let bytes: [UInt8]
        let size: SIMD2<Int>

        /// The colour at a scene point (the scene is drawn stretched onto the whole view, y up).
        func color(atScene point: SIMD2<Float>) -> Color {
            let x = Int(point.x), y = size.y - 1 - Int(point.y)
            let index = (y * size.x + x) * 4
            let (b, g, r) = (bytes[index], bytes[index + 1], bytes[index + 2])
            func on(_ value: UInt8) -> Bool { value > 180 }
            func off(_ value: UInt8) -> Bool { value < 60 }
            switch (on(r), on(g), on(b)) {
            case (false, false, false) where off(r) && off(g) && off(b): return .black
            case (true, false, false) where off(g) && off(b): return .red
            case (false, true, false) where off(r) && off(b): return .green
            case (false, false, true) where off(r) && off(g): return .blue
            case (true, true, false) where off(b): return .yellow
            case (true, true, true): return .white
            default: return .other
            }
        }

        /// Pixels brighter than black within a scene rectangle.
        func litPixels(from low: SIMD2<Int>, to high: SIMD2<Int>) -> Int {
            var count = 0
            for sceneY in low.y...high.y {
                for sceneX in low.x...high.x {
                    let index = ((size.y - 1 - sceneY) * size.x + sceneX) * 4
                    if Int(bytes[index]) + Int(bytes[index + 1]) + Int(bytes[index + 2]) > 90 { count += 1 }
                }
            }
            return count
        }
    }
}
