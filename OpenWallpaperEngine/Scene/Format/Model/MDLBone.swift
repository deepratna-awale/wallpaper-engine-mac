import simd

/// A bone of an `MDLS` skeleton (docs/models-plan.md §1.3).
///
/// Matrices in a `.mdl` are 16 floats of a D3D row-vector matrix with the translation in elements
/// 12…14. Read as four columns of four, that is the same memory as a column-major matrix acting on
/// column vectors, which is how every `simd_float4x4` of these types holds it: the translation is
/// `columns.3`.
struct MDLBone: Equatable {
    var name: String
    /// 0x1 is set on 520 of the library's 568 bones [?]; 0x2 hangs the bone's constraints on its
    /// link, and WE then disables its clip tracks unless an IK set names it.
    var flags: UInt32
    /// The parent's index, 0xFFFFFFFF for a root.
    var parent: UInt32
    /// The bind transform relative to the parent.
    var matrix: simd_float4x4
    /// The bone's physics and IK properties as JSON (`ik`, `se`, `gd`, `m`, `tf`…); empty when
    /// it has none.
    var properties: String

    var parentIndex: Int? { parent == 0xFFFF_FFFF ? nil : Int(parent) }
}
