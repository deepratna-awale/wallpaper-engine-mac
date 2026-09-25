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

    /// Risk #17: speeds and wall times a frame can see. Time never runs backwards or turns NaN,
    /// and a long gap (sleep) advances it by one clamped frame.
    func testClockSurvivesDegenerateSpeedsAndWallTimes() {
        var clock = SceneClock()
        clock.advance(to: 10, speed: 1)
        for (step, speed) in [0, -1, Double.nan, Double.infinity, -Double.infinity].enumerated() {
            let before = clock.time
            clock.advance(to: 10 + 0.1 * Double(step + 1), speed: speed)
            XCTAssertTrue(clock.time.isFinite && clock.delta.isFinite, "speed \(speed)")
            XCTAssertGreaterThanOrEqual(clock.delta, 0, "speed \(speed)")
            XCTAssertGreaterThanOrEqual(clock.time, before, "speed \(speed)")
        }
        let beforeRewind = clock.time
        clock.advance(to: 5, speed: 1) // the wall clock went backwards
        XCTAssertEqual(clock.delta, 0)
        XCTAssertEqual(clock.time, beforeRewind)
        clock.advance(to: 5 + 3600, speed: 1) // an hour asleep
        XCTAssertEqual(clock.delta, SceneClock.maximumFrameDelta, accuracy: 1e-12)
        clock.advance(to: .nan, speed: 1)
        XCTAssertTrue(clock.time.isFinite, "a NaN wall time does not poison the clock")
        clock.advance(to: 5 + 3600.1, speed: 1)
        XCTAssertTrue(clock.time.isFinite)
    }

    // MARK: Retina target

    /// Risk #11: target size for the displays and scene shapes people use. The target never
    /// exceeds what Metal can allocate (16384 px per side), keeps the scene's aspect, and follows
    /// the drawable's density up to about a 5K frame.
    func testTargetSizeTable() {
        struct Case { let scene: SIMD2<Float>; let drawable: SIMD2<Float> }
        let cases = [
            Case(scene: SIMD2(1920, 1080), drawable: SIMD2(5120, 2880)),   // 5K
            Case(scene: SIMD2(1920, 1080), drawable: SIMD2(6016, 3384)),   // 6K XDR
            Case(scene: SIMD2(5120, 1440), drawable: SIMD2(5120, 1440)),   // 32:9
            Case(scene: SIMD2(1080, 1920), drawable: SIMD2(2880, 1800)),   // portrait scene, landscape display
            Case(scene: SIMD2(1920, 1080), drawable: .zero),                // no drawable yet
            Case(scene: SIMD2(1, 1), drawable: SIMD2(3840, 2160)),
            Case(scene: SIMD2(20000, 20000), drawable: SIMD2(3840, 2160)),
            Case(scene: SIMD2(1920, 1080), drawable: SIMD2(.nan, .infinity)),
        ]
        for item in cases {
            let scale = SceneRenderResolution.pixelsPerUnit(sceneSize: item.scene, drawableSize: item.drawable)
            let size = SceneRenderResolution.targetSize(sceneSize: item.scene, pixelsPerUnit: scale)
            let label = "scene \(item.scene), drawable \(item.drawable)"
            XCTAssertTrue(scale.isFinite && scale > 0, label)
            XCTAssertGreaterThanOrEqual(size.x, 1, label)
            XCTAssertGreaterThanOrEqual(size.y, 1, label)
            XCTAssertLessThanOrEqual(max(size.x, size.y), Int(SceneRenderResolution.maximumTextureDimension), label)
            XCTAssertEqual(Float(size.x) / Float(size.y), item.scene.x / item.scene.y,
                           accuracy: 0.01 * item.scene.x / item.scene.y, label)
        }
        // WE draws at the display's resolution: 5K and 6K get their full density (eighths, rounded up).
        let fiveK = SceneRenderResolution.pixelsPerUnit(sceneSize: SIMD2(1920, 1080), drawableSize: SIMD2(5120, 2880))
        XCTAssertEqual(fiveK, 2.75, accuracy: 1e-6)
        let sixK = SceneRenderResolution.pixelsPerUnit(sceneSize: SIMD2(1920, 1080), drawableSize: SIMD2(6016, 3384))
        XCTAssertEqual(sixK, 3.25, accuracy: 1e-6)
        // A scene bigger than Metal's largest texture is fitted into it rather than failing to allocate.
        let huge = SceneRenderResolution.pixelsPerUnit(sceneSize: SIMD2(20000, 20000), drawableSize: SIMD2(3840, 2160))
        XCTAssertEqual(SceneRenderResolution.targetSize(sceneSize: SIMD2(20000, 20000), pixelsPerUnit: huge),
                       SIMD2(16384, 16384))
    }

    func testTargetFollowsDrawableDensity() {
        let scene = SIMD2<Float>(1920, 1080)
        XCTAssertEqual(SceneRenderResolution.pixelsPerUnit(sceneSize: scene, drawableSize: SIMD2(3840, 2160)), 2)
        XCTAssertEqual(SceneRenderResolution.targetSize(sceneSize: scene, pixelsPerUnit: 2), SIMD2(3840, 2160))
        // Never below the authored size (thumbnails, small windows).
        XCTAssertEqual(SceneRenderResolution.pixelsPerUnit(sceneSize: scene, drawableSize: SIMD2(640, 360)), 1)
    }

    /// Only the hardware limits the target: no memory budget caps the density.
    func testTargetIsLimitedOnlyByTheLargestTexture() {
        let scale = SceneRenderResolution.pixelsPerUnit(sceneSize: SIMD2(1920, 1080), drawableSize: SIMD2(15360, 8640))
        XCTAssertEqual(scale, 8)
        XCTAssertEqual(SceneRenderResolution.targetSize(sceneSize: SIMD2(1920, 1080), pixelsPerUnit: scale), SIMD2(15360, 8640))
        let beyond = SceneRenderResolution.pixelsPerUnit(sceneSize: SIMD2(1920, 1080), drawableSize: SIMD2(30720, 17280))
        XCTAssertEqual(beyond, 8.5, "the largest eighth whose target fits 16384 px")
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
