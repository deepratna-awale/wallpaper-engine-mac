import simd

/// How many render-target pixels one scene unit gets. The scene is drawn at the output's
/// density (so Retina text and edges stay sharp) rather than at its authored size and then
/// upscaled; it is never drawn below its authored size, and the target is capped so a large
/// scene on a large display doesn't take unbounded memory.
enum SceneRenderResolution {
    /// About a 5K frame.
    static let maximumPixelCount: Float = 5120 * 2880
    static let maximumDimension: Float = 8192

    /// Pixels per scene unit for a scene of `sceneSize` shown on `drawableSize` pixels.
    /// Quantised to eighths so a live window resize doesn't reallocate the target every frame.
    static func pixelsPerUnit(sceneSize: SIMD2<Float>, drawableSize: SIMD2<Float>) -> Float {
        let scene = simd_max(sceneSize, SIMD2(1, 1))
        guard drawableSize.x > 0, drawableSize.y > 0 else { return 1 }
        let wanted = max(drawableSize.x / scene.x, drawableSize.y / scene.y)
        let cap = min(sqrt(maximumPixelCount / (scene.x * scene.y)), maximumDimension / max(scene.x, scene.y))
        let scale = min(max(wanted, 1), max(cap, 1))
        guard scale.isFinite else { return 1 }
        let quantized = (scale * 8).rounded(.up) / 8
        return max(1, quantized > cap ? (cap * 8).rounded(.down) / 8 : quantized)
    }

    /// The render target's size in pixels.
    static func targetSize(sceneSize: SIMD2<Float>, pixelsPerUnit: Float) -> SIMD2<Int> {
        let size = (simd_max(sceneSize, SIMD2(1, 1)) * pixelsPerUnit).rounded(.toNearestOrAwayFromZero)
        return SIMD2(Int(size.x), Int(size.y))
    }

    /// The pixels of a y-down target of `targetSize` covered by a y-up scene-unit box, grown to
    /// whole pixels and clipped to the target; nil when nothing is left.
    static func pixelRect(of box: (min: SIMD2<Float>, max: SIMD2<Float>), sceneSize: SIMD2<Float>,
                          targetSize: SIMD2<Int>) -> (origin: SIMD2<Int>, size: SIMD2<Int>)? {
        let scale = SIMD2<Float>(Float(targetSize.x), Float(targetSize.y)) / simd_max(sceneSize, SIMD2(1, 1))
        let height = Float(targetSize.y)
        let left = (box.min.x * scale.x).rounded(.down), right = (box.max.x * scale.x).rounded(.up)
        let top = (height - box.max.y * scale.y).rounded(.down), bottom = (height - box.min.y * scale.y).rounded(.up)
        guard left.isFinite, right.isFinite, top.isFinite, bottom.isFinite else { return nil }
        let x0 = Int(max(left, 0)), y0 = Int(max(top, 0))
        let x1 = Int(min(right, Float(targetSize.x))), y1 = Int(min(bottom, height))
        guard x1 > x0, y1 > y0 else { return nil }
        return (SIMD2(x0, y0), SIMD2(x1 - x0, y1 - y0))
    }
}
