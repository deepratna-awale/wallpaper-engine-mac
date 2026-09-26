import simd

/// How many render-target pixels one scene unit gets. The scene is drawn at the output's
/// density, as WE draws at the display's resolution, so Retina text and edges stay sharp rather
/// than being upscaled. It is never drawn below its authored size, unless that exceeds what
/// Metal can allocate.
enum SceneRenderResolution {
    /// The largest 2D texture side every Mac GPU the app runs on can allocate. A target that
    /// would be larger is fitted into it rather than failing to allocate every frame.
    static let maximumTextureDimension: Float = 16384

    /// Pixels per scene unit for a scene of `sceneSize` shown on `drawableSize` pixels.
    /// Quantised to eighths so a live window resize doesn't reallocate the target every frame.
    static func pixelsPerUnit(sceneSize: SIMD2<Float>, drawableSize: SIMD2<Float>) -> Float {
        let scene = simd_max(sceneSize, SIMD2(1, 1))
        let fitsTexture = maximumTextureDimension / max(scene.x, scene.y)
        guard fitsTexture.isFinite, fitsTexture > 0 else { return 1 }
        // The hardware limit is the only thing that draws a scene below its authored size.
        guard fitsTexture >= 1 else { return fitsTexture }
        guard drawableSize.x > 0, drawableSize.y > 0 else { return 1 }
        let wanted = max(drawableSize.x / scene.x, drawableSize.y / scene.y)
        guard wanted.isFinite else { return 1 }
        let quantized = (max(wanted, 1) * 8).rounded(.up) / 8
        return quantized > fitsTexture ? max(1, (fitsTexture * 8).rounded(.down) / 8) : quantized
    }

    /// The drawable a scene target is sized for: the largest of `viewports`, in pixels, or in points
    /// for `GSRenderResolution.desktop` (one pixel per point, scaled up onto the drawable).
    static func drawableSize(_ viewports: [SceneViewport], resolution: GSRenderResolution) -> SIMD2<Float> {
        switch resolution {
        case .native: return SceneViewport.largestDrawable(viewports)
        case .desktop:
            // A point is never more than a pixel: a view without points yet keeps its pixels.
            return viewports.reduce(SIMD2<Float>(repeating: 0)) { largest, viewport in
                let points = viewport.pointSize.x > 0 && viewport.pointSize.y > 0
                    ? simd_min(viewport.pointSize, viewport.drawableSize) : viewport.drawableSize
                return simd_max(largest, points)
            }
        }
    }

    /// The render target's size in pixels.
    static func targetSize(sceneSize: SIMD2<Float>, pixelsPerUnit: Float) -> SIMD2<Int> {
        let size = (simd_max(sceneSize, SIMD2(1, 1)) * pixelsPerUnit).rounded(.toNearestOrAwayFromZero)
        func side(_ pixels: Float) -> Int { pixels.isFinite ? Int(min(max(pixels, 1), maximumTextureDimension)) : 1 }
        return SIMD2(side(size.x), side(size.y))
    }
}
