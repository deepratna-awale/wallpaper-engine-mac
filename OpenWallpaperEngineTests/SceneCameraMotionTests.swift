import XCTest
import MetalKit
import simd
@testable import OpenWallpaperEngine

/// WE's camera parallax and shake against the formulas recovered from `wallpaper64.exe`
/// (see `SceneCameraParallax` and `SceneCameraShake` for the addresses). The expected numbers
/// were worked out by hand from the disassembly, not from our code.
final class SceneCameraMotionTests: XCTestCase {
    private let size = SIMD2<Float>(1920, 1080)

    private func assertEqual(_ a: SIMD2<Float>, _ b: SIMD2<Float>, accuracy: Float = 1e-3,
                             _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, message, file: file, line: line)
    }

    // MARK: - Parallax

    /// At load WE puts the position at the scene centre (0x140188715) and g_ParallaxPosition at 0.5 0.5.
    func testParallaxStartsAtTheSceneCentre() {
        let parallax = SceneCameraParallax(sceneSize: size)
        assertEqual(parallax.position, SIMD2(960, 540))
        assertEqual(parallax.shaderPosition(sceneSize: size), SIMD2(0.5, 0.5))
    }

    /// target = eye + size · (cursor · influence + 0.5 · (1 − influence)); no delay takes it at once.
    func testParallaxTargetMixesCursorAndCentreByInfluence() {
        var parallax = SceneCameraParallax(sceneSize: size)
        parallax.update(cursor: SIMD2(1, 0), eye: .zero, sceneSize: size, influence: 0.5, delay: 0, deltaTime: 1 / 60)
        assertEqual(parallax.position, SIMD2(1440, 270))
        assertEqual(parallax.shaderPosition(sceneSize: size), SIMD2(0.75, 0.25))

        // The cursor is clamped to 0…1 before it's used.
        parallax.update(cursor: SIMD2(2, -1), eye: .zero, sceneSize: size, influence: 0.5, delay: 0, deltaTime: 1 / 60)
        assertEqual(parallax.position, SIMD2(1440, 270))

        // Influence 0 (the cursor ignored) looks at the centre.
        parallax.update(cursor: SIMD2(1, 1), eye: .zero, sceneSize: size, influence: 0, delay: 0, deltaTime: 1 / 60)
        assertEqual(parallax.position, SIMD2(960, 540))
    }

    /// Influence isn't clamped (a library scene authors 3): the position runs past the scene and
    /// only g_ParallaxPosition is clamped.
    func testParallaxInfluenceAboveOneOvershootsAndTheShaderValueClamps() {
        var parallax = SceneCameraParallax(sceneSize: size)
        parallax.update(cursor: SIMD2(1, 0), eye: .zero, sceneSize: size, influence: 3, delay: 0, deltaTime: 1 / 60)
        assertEqual(parallax.position, SIMD2(3840, -1080))
        assertEqual(parallax.shaderPosition(sceneSize: size), SIMD2(1, 0))
    }

    /// The camera eye (after shake) is added to the target.
    func testParallaxTargetIncludesTheEye() {
        var parallax = SceneCameraParallax(sceneSize: size)
        parallax.update(cursor: SIMD2(0.5, 0.5), eye: SIMD2(10, -5), sceneSize: size, influence: 0.5, delay: 0,
                        deltaTime: 1 / 60)
        assertEqual(parallax.position, SIMD2(970, 535))
    }

    /// pos += (target − pos) · min(1, (1 − delay / 3) · 10 · dt).
    func testParallaxDelayEasesTowardTheTarget() {
        var parallax = SceneCameraParallax(sceneSize: size)
        parallax.update(cursor: SIMD2(1, 0), eye: .zero, sceneSize: size, influence: 0.5, delay: 0.1, deltaTime: 1 / 60)
        // rate = (1 − 0.1 / 3) · 10 / 60 = 0.161111
        assertEqual(parallax.position, SIMD2(960 + 480 * 0.161111, 540 - 270 * 0.161111), accuracy: 1e-2)

        var slow = SceneCameraParallax(sceneSize: size)
        slow.update(cursor: SIMD2(1, 0), eye: .zero, sceneSize: size, influence: 0.5, delay: 2, deltaTime: 0.25)
        // rate = (1 − 2 / 3) · 10 · 0.25 = 0.833333
        assertEqual(slow.position, SIMD2(960 + 480 * 0.833333, 540 - 270 * 0.833333), accuracy: 1e-2)

        // A long frame reaches the target and doesn't overshoot it.
        var long = SceneCameraParallax(sceneSize: size)
        long.update(cursor: SIMD2(1, 0), eye: .zero, sceneSize: size, influence: 0.5, delay: 0.1, deltaTime: 0.25)
        assertEqual(long.position, SIMD2(1440, 270))
    }

    /// Objects move by amount · (root.origin − position) · root.parallaxDepth.
    func testParallaxOffsetUsesTheRootOriginAndDepth() {
        var parallax = SceneCameraParallax(sceneSize: size)
        parallax.update(cursor: SIMD2(1, 0), eye: .zero, sceneSize: size, influence: 0.5, delay: 0, deltaTime: 1 / 60)
        assertEqual(parallax.offset(rootOrigin: SIMD2(960, 540), rootDepth: SIMD2(1, 1), amount: 0.5), SIMD2(-240, 135))
        assertEqual(parallax.offset(rootOrigin: SIMD2(960, 540), rootDepth: SIMD2(0, 0.5), amount: 0.5), SIMD2(0, 67.5))
        assertEqual(parallax.offset(rootOrigin: SIMD2(1440, 270), rootDepth: SIMD2(1, 1), amount: 0.5), .zero)
    }

    // MARK: - Shake

    /// t = speed² · time; v = (cos t, sin 1.333t, 0) · amplitude · 0.1 · height · 0.1 in an
    /// orthographic scene. Roughness 1 (r = 1) and 0 (r ≤ 0.001) leave v's length alone.
    func testShakeFollowsWEsFormula() {
        let smooth = SceneCameraShake.cameraOffset(time: 0.1, speed: 3, amplitude: 0.5, roughness: 1, orthographicHeight: 1080)
        XCTAssertEqual(smooth.x, 3.356694, accuracy: 1e-4)
        XCTAssertEqual(smooth.y, 5.032424, accuracy: 1e-4)
        XCTAssertEqual(smooth.z, 0)
        let zero = SceneCameraShake.cameraOffset(time: 0.1, speed: 3, amplitude: 0.5, roughness: 0, orthographicHeight: 1080)
        XCTAssertEqual(zero, smooth)

        // Roughness 0.5: r = 0.125, v = v / |v| · |v|^r.
        let rough = SceneCameraShake.cameraOffset(time: 0.1, speed: 3, amplitude: 0.5, roughness: 0.5, orthographicHeight: 1080)
        XCTAssertEqual(rough.x, 3.039284, accuracy: 1e-4)
        XCTAssertEqual(rough.y, 4.556557, accuracy: 1e-4)

        // A library scene's values (3803167460): speed 0.64, amplitude 0.35, roughness 0, 3840×2160.
        let library = SceneCameraShake.cameraOffset(time: 2, speed: 0.64, amplitude: 0.35, roughness: 0, orthographicHeight: 2160)
        XCTAssertEqual(library.x, 5.162013, accuracy: 1e-4)
        XCTAssertEqual(library.y, 6.709857, accuracy: 1e-4)
    }

    /// A perspective scene keeps z = sin t and scales by amplitude · 0.1 only.
    func testShakeInAPerspectiveSceneIsInWorldUnits() {
        let smooth = SceneCameraShake.cameraOffset(time: 0.1, speed: 3, amplitude: 0.5, roughness: 1, orthographicHeight: nil)
        XCTAssertEqual(smooth.x, 0.031080, accuracy: 1e-5)
        XCTAssertEqual(smooth.y, 0.046597, accuracy: 1e-5)
        XCTAssertEqual(smooth.z, 0.039166, accuracy: 1e-5)
        let rough = SceneCameraShake.cameraOffset(time: 0.1, speed: 3, amplitude: 0.5, roughness: 0.5, orthographicHeight: nil)
        XCTAssertEqual(rough.x, 0.023643, accuracy: 1e-5)
        XCTAssertEqual(rough.y, 0.035447, accuracy: 1e-5)
        XCTAssertEqual(rough.z, 0.029794, accuracy: 1e-5)
    }

    // MARK: - Hierarchy

    /// Parallax uses an object's topmost ancestor; an object without `parallaxDepth` has WE's 1 1.
    func testRootAndParallaxDepthOfTheHierarchy() throws {
        let objects = try JSONDecoder().decode([WESceneObject].self, from: Data("""
            [{"id": 1, "origin": "100 100 0", "parallaxDepth": "0.25 0.50000"},
             {"id": 2, "parent": 1, "origin": "10 0 0"},
             {"id": 3, "parent": 2},
             {"id": 4, "origin": "5 5 0"}]
            """.utf8))
        let hierarchy = SceneTransformHierarchy(objects: objects, sceneSize: size)
        XCTAssertEqual(hierarchy.root(of: "3"), "1")
        XCTAssertEqual(hierarchy.root(of: "1"), "1")
        XCTAssertEqual(hierarchy.root(of: "missing"), "missing")
        XCTAssertEqual(hierarchy.nodes["1"]?.parallaxDepth, SIMD2(0.25, 0.5))
        XCTAssertEqual(hierarchy.nodes["4"]?.parallaxDepth, SIMD2(1, 1))

        var fullscreen = hierarchy
        fullscreen.makeRoot("1", local: .identity)
        XCTAssertEqual(fullscreen.nodes["1"]?.parallaxDepth, SIMD2(0.25, 0.5), "a fullscreen layer keeps its depth")
    }

    // MARK: - Rendering

    /// A rendered frame: with parallax on and the cursor at the centre (no window, so the
    /// tracker's default), a layer at x 40 of a 64-wide scene moves by 0.5 · (40 − 32) = 4.
    /// A layer with parallaxDepth 0 0 doesn't move, and nothing moves with parallax off.
    func testRenderedLayerMovesByWEsParallaxOffset() throws {
        XCTAssertEqual(try renderedSeam(parallax: true, depth: SIMD3(1, 1, 0)), 44)
        XCTAssertEqual(try renderedSeam(parallax: true, depth: .zero), 40)
        XCTAssertEqual(try renderedSeam(parallax: false, depth: SIMD3(1, 1, 0)), 40)
    }

    /// The first column that is green along the middle row of a 64×64 render of a two-colour layer
    /// (red left of its origin, green right).
    private func renderedSeam(parallax: Bool, depth: SIMD3<Float>) throws -> Int {
        let size = 64
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: size, height: size), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: size, height: size)
        let renderer = try XCTUnwrap(SceneMetalRenderer(view: view))
        view.isPaused = true
        renderer.setPlacement(.stretch)
        let scene = Float(size)
        var layer = SceneMetalLayer(
            id: "1", name: "halves", source: .image(try Self.halves()), position: SIMD2(40, scene / 2),
            size: SIMD2(scene * 2, scene), scale: SIMD2(1, 1), opacity: 1, brightness: 1, color: SIMD4(repeating: 1),
            text: nil, parallaxDepth: depth, perspective: false, rotation: 0, effects: .identity)
        layer.order = 0
        var content = SceneMetalContent(
            size: SIMD2(scene, scene), layers: [layer], particleSystems: [],
            bloom: SceneBloomSettings(enabled: false, strength: 0, threshold: 0.7, tint: SIMD3(repeating: 1)))
        content.camera.parallax = parallax
        content.camera.parallaxAmount = 0.5
        content.camera.parallaxDelay = 0
        renderer.setContent(content)
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let deadline = Date().addingTimeInterval(10)
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            renderer.draw(in: view)
            renderer.lastCommandBuffer?.waitUntilCompleted()
            view.currentDrawable?.texture.getBytes(&pixels, bytesPerRow: size * 4,
                                                   from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        } while Date() < deadline && pixels.allSatisfy { $0 == 0 }
        let row = size / 2
        return try XCTUnwrap((0..<size).first { x in
            let texel = pixels[(row * size + x) * 4..<(row * size + x) * 4 + 4]
            return texel[texel.startIndex + 1] > 128 && texel[texel.startIndex + 2] < 128
        }, "no green in the row")
    }

    /// A 128×1 image, one texel per scene unit of the layer: 64 red texels, then 64 green.
    private static func halves() throws -> NSImage {
        let bytes: [UInt8] = Array(repeating: [255, 0, 0, 255], count: 64).flatMap { $0 }
            + Array(repeating: [0, 255, 0, 255], count: 64).flatMap { $0 }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: 128, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 512,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue).union(.byteOrder32Big),
                                          provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return NSImage(cgImage: image, size: NSSize(width: 128, height: 1))
    }
}
