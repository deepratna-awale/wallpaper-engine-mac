import Foundation

/// A clip of the `MDLA` section, versions 1–6 (docs/models-plan.md §1.4). A scene's
/// `animationlayers` name it by `id`.
struct MDLAnimation: Equatable {
    /// How the clip plays past its end (0x1401a8c71): "mirror" ping-pongs, "single" plays once,
    /// any other name loops.
    enum Mode: Equatable {
        case loop, mirror, single

        init(name: String) {
            switch name {
            case "mirror": self = .mirror
            case "single": self = .single
            default: self = .loop
            }
        }
    }

    /// A bone or link track: `frames + 1` samples of 9 floats (`MDLBonePose`).
    struct Track: Equatable {
        /// Bit 0: disabled, the bone keeps its bind pose.
        var flags: UInt32
        var samples: [Float]

        var isDisabled: Bool { flags & 1 != 0 }

        /// The pose at `frame` (0…frames).
        func pose(at frame: Int) -> MDLBonePose {
            let base = frame * MDLBonePose.floatCount
            return MDLBonePose(samples[base..<(base + MDLBonePose.floatCount)])
        }
    }

    /// One float per frame: a constraint track (`tag` is its value) or one of the scalar lists
    /// (`tag` is the u32 WE skips before it).
    struct ScalarTrack: Equatable {
        var tag: UInt32
        var samples: [Float]
    }

    /// The morph-weight tracks of one mesh (`MDLA` 4 and later).
    struct MeshTrack: Equatable {
        struct MorphTrack: Equatable {
            var morph: UInt16
            var samples: [Float]
        }

        /// Bit 0: `weight` and `morphTracks` follow.
        var flags: UInt32
        var weight: Float?
        var morphTracks: [MorphTrack]?
    }

    /// When flags & 1: the clip is relative to an earlier one [I]; the four u32s are unresolved.
    struct Reference: Equatable {
        var animation: UInt16
        var values: [UInt32]
    }

    struct Event: Equatable {
        var frame: Float
        var name: String
    }

    var id: UInt64
    var name: String
    /// The mode as written; `mode` interprets it.
    var modeName: String
    var fps: Float
    /// The last frame index: every track has `frames + 1` samples.
    var frames: UInt32
    /// Bit 0: `reference` follows. WE sets 0x80000000 in its copy when a track is disabled.
    var flags: UInt32
    /// One per bone in the library.
    var boneTracks: [Track]
    /// `MDLA` 2 and later: one per skeleton link.
    var linkTracks: [Track]?
    /// `MDLA` 2 and later: one per skeleton constraint.
    var constraintTracks: [ScalarTrack]?
    /// `MDLA` 3 and later.
    var scalarTracksA: [ScalarTrack]?
    /// `MDLA` 3 and later, when present: one per bone track.
    var scalarTracksB: [ScalarTrack]?
    /// `MDLA` 4 and later, when present: one per mesh.
    var meshTracks: [MeshTrack]?
    /// `MDLA` 5 and later: the animated model's box.
    var bounds: MDLBounds?
    /// `MDLA` 6 and later, when present: one per bone track.
    var scalarTracksC: [ScalarTrack]?
    var reference: Reference?
    var events: [Event]

    var mode: Mode { Mode(name: modeName) }
    /// `frames / fps` seconds (0x1401a8c10).
    var duration: Float { Float(frames) / fps }
}
