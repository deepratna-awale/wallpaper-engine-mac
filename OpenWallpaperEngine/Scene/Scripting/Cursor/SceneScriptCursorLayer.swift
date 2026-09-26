import simd

/// One object WE's cursor pass considers, as it was last drawn. Only image and text layers are
/// hit tested (wallpaper64.exe 0x14018a041: object types 1 and 4 take the quad test; models,
/// type 5, test their mesh bounds, which this renderer does not draw); every other object is left
/// out of `SceneScriptCursorFrame.layers`.
struct SceneScriptCursorLayer {
    /// The object-table slot; cursor events reach the scripts of this slot.
    var slot: Int
    /// The object's world matrix (column-major, parents included), without camera parallax or
    /// shake: the object table's `worldMatrix`.
    var worldMatrix: simd_float4x4
    /// `size`: the quad before scale, in scene units.
    var size: SIMD2<Float>
    /// The object's own `origin` and `parallaxDepth`. WE's hit test offsets the quad by camera
    /// parallax from these (0x14018a0b3), not from the root object's as drawing does.
    var origin: SIMD2<Float>
    var parallaxDepth: SIMD2<Float>
    /// `solid`: only solid objects are tested (flag 0x2000; WE's default is solid).
    var isSolid: Bool
    /// `disablepropagation` (flag 0x4000).
    var disablesPropagation: Bool
    /// `visible`, and every parent visible (0x140185010). Hidden objects are still hit and get
    /// their events; only a visible one stops propagation.
    var isVisible: Bool

    init(slot: Int, worldMatrix: simd_float4x4, size: SIMD2<Float>, origin: SIMD2<Float> = .zero,
         parallaxDepth: SIMD2<Float> = SIMD2(1, 1), isSolid: Bool = true, disablesPropagation: Bool = false,
         isVisible: Bool = true) {
        self.slot = slot
        self.worldMatrix = worldMatrix
        self.size = size
        self.origin = origin
        self.parallaxDepth = parallaxDepth
        self.isSolid = isSolid
        self.disablesPropagation = disablesPropagation
        self.isVisible = isVisible
    }

    /// Whether a hit on this layer keeps the cursor pass from reaching the layers under it.
    var stopsPropagation: Bool { disablesPropagation && isVisible }
}
