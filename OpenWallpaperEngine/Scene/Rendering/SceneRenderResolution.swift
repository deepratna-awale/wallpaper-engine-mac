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
}
