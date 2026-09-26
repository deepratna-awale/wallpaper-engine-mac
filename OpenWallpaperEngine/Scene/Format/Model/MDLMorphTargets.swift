import Foundation

/// One mesh's morph targets (blend shapes) from the `MDMP0001` section (docs/models-plan.md
/// §1.5). No library file has the section; the layout is the reader's and the writer's.
struct MDLMorphTargets: Equatable {
    struct Target: Equatable {
        /// The writer's `modifierbone`, `modifiermode`, `modifierstartdistance` and
        /// `modifierenddistance` (mesh flag 0x2000, `MORPHING_MODIFIERS`).
        struct Modifier: Equatable {
            var bone: UInt32
            var mode: UInt32
            var startDistance: Float
            var endDistance: Float
        }

        var id: UInt64
        var name: String
        /// A float3 per vertex, stored as half floats: the position deltas [I].
        var positions: [Float]
        /// Mesh flag 0x400: normal deltas, like `positions` [I].
        var normals: [Float]?
        /// Mesh flag 0x800: tangent deltas, like `positions` [I].
        var tangents: [Float]?
        /// Mesh flag 0x1000: two bytes per vertex [?].
        var extra: Data?
        var modifier: Modifier?
    }

    /// The mesh's index.
    var mesh: Int
    /// With targets: WE's `g_MorphWeights[0]` start value (mesh+0x60) [?].
    var weight: Float?
    /// With targets: the vertices each target covers, clamped by WE to what the smallest position
    /// blob holds (0x14026578f).
    var vertexCount: UInt32?
    var targets: [Target]
}

extension MDLMorphTargets {
    /// An IEEE half float's value, subnormals, infinities and NaN included.
    static func float(halfBits bits: UInt16) -> Float {
        let sign = UInt32(bits >> 15) << 31
        let exponent = UInt32(bits >> 10) & 0x1f
        let mantissa = UInt32(bits) & 0x3ff
        switch exponent {
        case 0:
            // Zero or subnormal: mantissa · 2^-24.
            let magnitude = Float(mantissa) * Float(sign: .plus, exponent: -24, significand: 1)
            return sign == 0 ? magnitude : -magnitude
        case 0x1f:
            return Float(bitPattern: sign | 0x7f80_0000 | (mantissa << 13))
        default:
            return Float(bitPattern: sign | ((exponent + 112) << 23) | (mantissa << 13))
        }
    }
}
