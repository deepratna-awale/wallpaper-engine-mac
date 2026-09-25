import simd

/// Keeps the scene snapshot (`_rt_FullFrameBuffer`) cheap: one full-size copy target per frame,
/// into which only the part a scene-reading draw needs is copied, and only when the copy already
/// there no longer matches the scene.
///
/// A `BLENDMODE` material or a scene-input layer reads the scene under its own quad, so it needs
/// just that quad's bounding rect (padded for linear filtering). An effect that reads the scene may
/// sample anywhere, so it asks for all of it. Every draw into the scene afterwards shrinks the part
/// of the copy known to match (`valid`); the next request copies again only if it reaches outside.
///
/// Pixel rects are in the scene target (y down), in pixels.
struct SceneSnapshotTracker {
    struct Rect: Equatable {
        var x: Int
        var y: Int
        var width: Int
        var height: Int

        /// No pixels: a draw that covers none of the target needs nothing copied.
        static let empty = Rect(x: 0, y: 0, width: 0, height: 0)

        var maxX: Int { x + width }
        var maxY: Int { y + height }
        var area: Int { width * height }

        func contains(_ other: Rect) -> Bool {
            other.x >= x && other.y >= y && other.maxX <= maxX && other.maxY <= maxY
        }

        func intersection(_ other: Rect) -> Rect? {
            let left = max(x, other.x), top = max(y, other.y)
            let right = min(maxX, other.maxX), bottom = min(maxY, other.maxY)
            guard right > left, bottom > top else { return nil }
            return Rect(x: left, y: top, width: right - left, height: bottom - top)
        }
    }

    /// Texels around a quad's box: linear filtering reads one beyond the edge, rounding one more.
    static let padding = 2

    /// The target pixels `quad` covers (scene units, y up), padded and clamped to the target; nil
    /// when it covers none (off-screen, zero, NaN or infinite).
    static func pixelRect(of quad: SceneQuadGeometry, sceneSize: SIMD2<Float>, targetSize: SIMD2<Int>) -> Rect? {
        let scale = SIMD2<Float>(Float(targetSize.x), Float(targetSize.y)) / simd_max(sceneSize, SIMD2(1, 1))
        let halfX = quad.axisX / 2, halfY = quad.axisY / 2
        let corners = [quad.center - halfX - halfY, quad.center + halfX - halfY,
                       quad.center - halfX + halfY, quad.center + halfX + halfY]
            .map { SIMD2($0.x * scale.x, Float(targetSize.y) - $0.y * scale.y) }
        var low = corners[0], high = corners[0]
        for corner in corners.dropFirst() {
            low = simd_min(low, corner)
            high = simd_max(high, corner)
        }
        guard low.x.isFinite, low.y.isFinite, high.x.isFinite, high.y.isFinite else { return nil }
        let pad = Float(padding)
        let size = SIMD2<Float>(Float(targetSize.x), Float(targetSize.y))
        // Clamped before converting: a far off-screen corner must not overflow `Int`.
        let lowPixel = simd_clamp((low - pad).rounded(.down), SIMD2(0, 0), size)
        let highPixel = simd_clamp((high + pad).rounded(.up), SIMD2(0, 0), size)
        let left = Int(lowPixel.x), top = Int(lowPixel.y), right = Int(highPixel.x), bottom = Int(highPixel.y)
        guard right > left, bottom > top else { return nil }
        return Rect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// Where this frame's copy equals the scene as drawn so far; nil when nowhere.
    private(set) var valid: Rect?
    /// Pixels copied since creation, for tests and diagnostics.
    private(set) var pixelsCopied = 0

    /// A new frame, or a new copy target: nothing copied yet.
    mutating func reset() { valid = nil }

    /// The scene was drawn into within `rect`, or anywhere when nil. Keeps the largest part of
    /// `valid` that the draw didn't touch.
    mutating func sceneDrawn(in rect: Rect?) {
        guard let current = valid else { return }
        guard let rect else { valid = nil; return }
        guard current.intersection(rect) != nil else { return }
        let bands = [
            Rect(x: current.x, y: current.y, width: current.width, height: rect.y - current.y),
            Rect(x: current.x, y: rect.maxY, width: current.width, height: current.maxY - rect.maxY),
            Rect(x: current.x, y: current.y, width: rect.x - current.x, height: current.height),
            Rect(x: rect.maxX, y: current.y, width: current.maxX - rect.maxX, height: current.height),
        ].filter { $0.width > 0 && $0.height > 0 }
        valid = bands.max { $0.area < $1.area }
    }

    /// A draw needs the scene within `rect`. Returns the rect to copy now, or nil when the copy
    /// already holds it.
    mutating func copy(for rect: Rect) -> Rect? {
        guard rect.area > 0 else { return nil }
        if let valid, valid.contains(rect) { return nil }
        valid = rect
        pixelsCopied += rect.area
        return rect
    }
}
