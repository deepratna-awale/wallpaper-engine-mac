import Foundation

/// One mesh of an `MDLV` part (docs/models-plan.md §1.2): its materials, interleaved vertices and
/// a triangle list. The bytes are kept as the file has them, ready for a vertex and index buffer;
/// the accessors decode single attributes.
struct MDLMesh: Equatable {
    /// A group record of `MDLV` 23 [?]: its lists index the mesh's `vector4Block`.
    struct Group: Equatable {
        var id: UInt64
        var name: String
        /// Bit 0 makes WE store 2 instead of 1 at rec+0x40 [?].
        var flags: UInt32
        var listA: [UInt32]
        var listB: [UInt32]
    }

    /// The optional blob of `MDLV` 21 and later after a `u32` WE discards. The one library file
    /// with it holds a float3 per vertex, the positions offset by a constant [I].
    struct ExtraPositions: Equatable {
        var discarded: UInt32
        var data: Data
    }

    /// One material path per skin; a model object's `skin` picks one (§2.6).
    var materials: [String]
    /// Bit 0: u32 indices; 0x2: `flagsExtra` follows [?]; 0x4: `SKINNING_ALPHA`;
    /// 0x400/0x800/0x1000/0x2000: extra `MDMP` blobs per morph target, 0x2000 `MORPHING_MODIFIERS`.
    var flags: UInt32
    /// The `u32` after the flags when flags & 0x2 [?].
    var flagsExtra: UInt32?
    /// The authored box (`MDLV` 17 and later).
    var bounds: MDLBounds?
    var format: MDLVertexFormat
    /// `vertexCount` vertices of `format.stride` bytes.
    var vertexData: Data
    /// A triangle list of u16 or u32 (`usesUInt32Indices`) indices.
    var indexData: Data
    var extraPositions: ExtraPositions?
    /// 16-byte entries (`MDLV` 21 and later), one per bone in the library, all zero there [?].
    var vector4Block: [SIMD4<Float>]?
    /// `MDLV` 23 and later.
    var groups: [Group]?

    var usesUInt32Indices: Bool { flags & 1 != 0 }
    var indexSize: Int { usesUInt32Indices ? 4 : 2 }
    var vertexCount: Int { format.stride == 0 ? 0 : vertexData.count / format.stride }
    var indexCount: Int { indexData.count / indexSize }
    /// Mesh flag 0x4.
    var usesSkinningAlpha: Bool { flags & 0x4 != 0 }
    var isSkinned: Bool { format.contains(.blendIndices) }

    /// The indices, widened to u32.
    var indices: [UInt32] {
        indexData.withUnsafeBytes { raw in
            (0..<indexCount).map { index in
                usesUInt32Indices ? raw.loadUnaligned(fromByteOffset: 4 * index, as: UInt32.self).littleEndian
                    : UInt32(raw.loadUnaligned(fromByteOffset: 2 * index, as: UInt16.self).littleEndian)
            }
        }
    }

    /// Every vertex's `attribute`, flattened (`components` values per vertex); nil when the
    /// format lacks it. `a_BlendIndices` reads as floats of the integers: use `unsignedValues`.
    func floatValues(_ attribute: MDLVertexAttribute) -> [Float]? {
        values(attribute).map { $0.map(Float.init(bitPattern:)) }
    }

    /// Every vertex's `attribute` as raw little-endian u32s (the integer `a_BlendIndices`, or a
    /// float's bit pattern); nil when the format lacks it.
    func unsignedValues(_ attribute: MDLVertexAttribute) -> [UInt32]? { values(attribute) }

    private func values(_ attribute: MDLVertexAttribute) -> [UInt32]? {
        guard let offset = format.offset(of: attribute) else { return nil }
        let stride = format.stride
        let count = vertexCount
        return vertexData.withUnsafeBytes { raw in
            var out: [UInt32] = []
            out.reserveCapacity(count * attribute.components)
            for vertex in 0..<count {
                for component in 0..<attribute.components {
                    out.append(raw.loadUnaligned(fromByteOffset: vertex * stride + offset + 4 * component, as: UInt32.self).littleEndian)
                }
            }
            return out
        }
    }
}
