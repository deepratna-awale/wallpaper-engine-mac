import XCTest
@testable import OpenWallpaperEngine

/// Area 8 review items: the scene clock, Retina target sizing, world-space scene regions and the
/// text cache.
final class SceneRenderPrimitivesTests: XCTestCase {
    // MARK: Scene clock

    func testClockStartsAtZeroAndCountsSceneSeconds() {
        var clock = SceneClock()
        clock.advance(to: 1_000_000, speed: 1)
        XCTAssertEqual(clock.time, 0, "the first frame only anchors the clock, whatever the uptime")
        clock.advance(to: 1_000_000.1, speed: 1)
        XCTAssertEqual(clock.time, 0.1, accuracy: 1e-9)
        XCTAssertEqual(clock.delta, 0.1, accuracy: 1e-9)
    }

    func testSpeedChangeDoesNotJump() {
        var clock = SceneClock()
        clock.advance(to: 100, speed: 1)
        clock.advance(to: 110, speed: 1) // clamped: a 10 s stall counts as one max-length frame
        XCTAssertEqual(clock.time, SceneClock.maximumFrameDelta, accuracy: 1e-9)
        let before = clock.time
        clock.advance(to: 110.1, speed: 3)
        XCTAssertEqual(clock.time - before, 0.3, accuracy: 1e-9, "speed scales the step, not the position")
        XCTAssertEqual(clock.delta, 0.3, accuracy: 1e-9)
        clock.advance(to: 110.2, speed: 0)
        XCTAssertEqual(clock.delta, 0)
    }

    // MARK: Retina target

    func testTargetFollowsDrawableDensity() {
        let scene = SIMD2<Float>(1920, 1080)
        XCTAssertEqual(SceneRenderResolution.pixelsPerUnit(sceneSize: scene, drawableSize: SIMD2(3840, 2160)), 2)
        XCTAssertEqual(SceneRenderResolution.targetSize(sceneSize: scene, pixelsPerUnit: 2), SIMD2(3840, 2160))
        // Never below the authored size (thumbnails, small windows).
        XCTAssertEqual(SceneRenderResolution.pixelsPerUnit(sceneSize: scene, drawableSize: SIMD2(640, 360)), 1)
    }

    func testTargetIsCapped() {
        let scale = SceneRenderResolution.pixelsPerUnit(sceneSize: SIMD2(1920, 1080), drawableSize: SIMD2(15360, 8640))
        let size = SceneRenderResolution.targetSize(sceneSize: SIMD2(1920, 1080), pixelsPerUnit: scale)
        XCTAssertLessThanOrEqual(Float(size.x * size.y), SceneRenderResolution.maximumPixelCount)
        XCTAssertGreaterThan(scale, 2)
        // A scene already bigger than the cap is drawn at its own size.
        XCTAssertEqual(SceneRenderResolution.pixelsPerUnit(sceneSize: SIMD2(7680, 4320), drawableSize: SIMD2(7680, 4320)), 1)
    }

    // MARK: Scene regions

    func testRotatedQuadBoundingBox() {
        let world = SceneAffineTransform(SceneLocalTransform(origin: SIMD2(500, 300), scale: SIMD2(2, 2), angle: .pi / 2))
        let box = SceneQuadGeometry(world: world, size: SIMD2(100, 50), alignment: nil).boundingBox
        // Turned a quarter: 200×100 becomes 100 wide, 200 tall.
        XCTAssertEqual(box.min.x, 450, accuracy: 0.01)
        XCTAssertEqual(box.max.x, 550, accuracy: 0.01)
        XCTAssertEqual(box.min.y, 200, accuracy: 0.01)
        XCTAssertEqual(box.max.y, 400, accuracy: 0.01)
    }

    func testPixelRectFlipsYScalesAndClips() throws {
        let scene = SIMD2<Float>(1000, 500)
        let rect = try XCTUnwrap(SceneRenderResolution.pixelRect(of: (SIMD2(100, 100), SIMD2(300, 200)),
                                                                sceneSize: scene, targetSize: SIMD2(2000, 1000)))
        XCTAssertEqual(rect.origin, SIMD2(200, 600))
        XCTAssertEqual(rect.size, SIMD2(400, 200))
        let clipped = try XCTUnwrap(SceneRenderResolution.pixelRect(of: (SIMD2(-50, -50), SIMD2(1100, 600)),
                                                                   sceneSize: scene, targetSize: SIMD2(1000, 500)))
        XCTAssertEqual(clipped.origin, SIMD2(0, 0))
        XCTAssertEqual(clipped.size, SIMD2(1000, 500))
        XCTAssertNil(SceneRenderResolution.pixelRect(of: (SIMD2(2000, 0), SIMD2(2100, 10)),
                                                     sceneSize: scene, targetSize: SIMD2(1000, 500)))
    }

    // MARK: Text cache

    func testLRUEvictsLeastRecentlyUsed() {
        var cache = SceneLRUCache<String, Int>(capacity: 2)
        cache.insert(1, for: "a")
        cache.insert(2, for: "b")
        XCTAssertEqual(cache.value(for: "a"), 1)
        cache.insert(3, for: "c")
        XCTAssertEqual(cache.count, 2)
        XCTAssertNil(cache.value(for: "b"), "b was the least recently used")
        XCTAssertEqual(cache.value(for: "a"), 1)
        XCTAssertEqual(cache.value(for: "c"), 3)
    }

    func testTextRasterScaleIsRetainedWhileScaleAnimatesDown() {
        var retained: Float?
        var scales = Set<Float>()
        for step in 0..<200 {
            let animated = 1 + 0.5 * sin(Float(step) * 0.1) // a pulsing scale
            let scale = SceneTextRasterScale.retained(SceneTextRasterScale.quantized(animated * 2), previous: retained)
            retained = scale
            scales.insert(scale)
        }
        XCTAssertLessThanOrEqual(scales.count, 4, "only the growth steps re-rasterise")
    }
}
