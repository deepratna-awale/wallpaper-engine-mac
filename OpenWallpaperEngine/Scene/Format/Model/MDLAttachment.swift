import simd

/// A named attachment point of the `MDAT0001` section (docs/models-plan.md §1.5): a scene
/// object's `attachment` names one and hangs from `bone` with `matrix` as its offset.
struct MDLAttachment: Equatable {
    var bone: UInt16
    var name: String
    var matrix: simd_float4x4
}
