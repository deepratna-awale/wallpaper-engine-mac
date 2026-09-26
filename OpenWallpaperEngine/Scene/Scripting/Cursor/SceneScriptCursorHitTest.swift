import simd

/// WE's cursor hit test of an image or text layer (wallpaper64.exe 0x14019dbb0, which calls the
/// ray–parallelogram test 0x14019d5a0).
///
/// The quad is the layer's `size` centred on its world translation plus the parallax offset, with
/// the world matrix's x and y axes (so rotation, scale and parents apply): corners
/// `centre ± 0.5·size.x·axisX ± 0.5·size.y·axisY`. The cursor ray of an orthographic scene runs
/// along z, so the test is the 2D one of the quad's projection. It has no alpha test: a
/// transparent pixel inside the quad is a hit.
///
/// `u` runs from the left edge to the right, `v` from the bottom edge to the top; both must lie
/// in 0…1, edges included. The determinant must exceed `Float.ulpOfOne` in magnitude, or the quad
/// is edge-on and never hit, with a zero local position. Otherwise the local position is written
/// even outside the quad: `(u·size.x, (1 − v)·size.y)`, from the top-left corner with y down,
/// which is what `CursorEvent.localPosition` reports ("0 to thisLayer.size").
enum SceneScriptCursorHitTest {
    struct Result: Equatable {
        var isInside: Bool
        var localPosition: SIMD2<Float>
    }

    static func test(_ layer: SceneScriptCursorLayer, cursor: SIMD2<Float>, offset: SIMD2<Float>) -> Result {
        let matrix = layer.worldMatrix
        let axisX = SIMD2(matrix.columns.0.x, matrix.columns.0.y) * layer.size.x
        let axisY = SIMD2(matrix.columns.1.x, matrix.columns.1.y) * layer.size.y
        let centre = SIMD2(matrix.columns.3.x, matrix.columns.3.y) + offset
        let corner = centre - 0.5 * axisX - 0.5 * axisY
        let determinant = axisX.x * axisY.y - axisX.y * axisY.x
        guard abs(determinant) > Float.ulpOfOne else { return Result(isInside: false, localPosition: .zero) }
        let delta = cursor - corner
        let u = (delta.x * axisY.y - delta.y * axisY.x) / determinant
        let v = (axisX.x * delta.y - axisX.y * delta.x) / determinant
        let inside = u >= 0 && u <= 1 && v >= 0 && v <= 1
        return Result(isInside: inside, localPosition: SIMD2(u * layer.size.x, (1 - v) * layer.size.y))
    }
}
