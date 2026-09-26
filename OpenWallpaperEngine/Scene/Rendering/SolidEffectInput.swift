import simd

/// The effect buffers of a layer whose material has no texture (a solid layer's `flat`, a shape):
/// WE sizes them to the layer's `size`, each side rounded half away from zero (`roundf`), with no
/// texture reduction (`wallpaper64.exe` 0x140209206…0x14020923c). A size under half a unit
/// still gets a 1×1 buffer.
enum SolidEffectInput {
    static func size(_ layerSize: SIMD2<Float>) -> SIMD2<Int> {
        func side(_ value: Float) -> Int {
            guard value.isFinite else { return 1 }
            return max(1, Int(value.rounded(.toNearestOrAwayFromZero)))
        }
        return SIMD2(side(layerSize.x), side(layerSize.y))
    }
}
