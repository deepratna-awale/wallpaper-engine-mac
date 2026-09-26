import simd

/// A layer's own fields as its timelines set them this frame (docs/timeline-plan.md §2.1, §2.6):
/// WE's setter writes every animated property every frame, paused or not, so the value replaces
/// the static and user-bound one; only a script's return beats it, for its frame.
///
/// The property's type picks how many channels are read (`0x14017242d`): `alpha` and `brightness`
/// one, `size` two, `origin`, `scale`, `angles` and `color` three. A channel the timeline lacks
/// reads 0, like a channel without keyframes.
struct SceneObjectAnimation: Equatable {
    var origin: SIMD3<Float>?
    var scale: SIMD3<Float>?
    var angles: SIMD3<Float>?
    var color: SIMD3<Float>?
    var size: SIMD2<Float>?
    var alpha: Float?
    var brightness: Float?
    /// The fields a timeline drives: the scripts' table gets their animated value every frame,
    /// before scripts run (§1.9 P2).
    private(set) var fields = SceneScriptOwnedFields()

    init() {}

    /// The object fields the renderer draws from a timeline.
    static let keys: Set<String> = ["origin", "scale", "angles", "color", "size", "alpha", "brightness"]

    /// Object `id`'s fields as `set` last sampled them. `keys` (the object's animated ones, when
    /// known) spares the lookups of the others.
    init(_ set: SceneAnimationSet, object id: Int, keys: Set<String> = Self.keys) {
        func read(_ key: String, _ field: SceneScriptObjectField, width: Int) -> [Float]? {
            guard keys.contains(key),
                  let value = set.value(of: SceneAnimationSite(owner: .object(id), key: key)) else { return nil }
            fields.insert(field)
            return (0..<width).map { $0 < value.count ? value[$0] : 0 }
        }
        origin = read("origin", .origin, width: 3).map { SIMD3($0[0], $0[1], $0[2]) }
        scale = read("scale", .scale, width: 3).map { SIMD3($0[0], $0[1], $0[2]) }
        angles = read("angles", .angles, width: 3).map { SIMD3($0[0], $0[1], $0[2]) }
        color = read("color", .color, width: 3).map { SIMD3($0[0], $0[1], $0[2]) }
        size = read("size", .size, width: 2).map { SIMD2($0[0], $0[1]) }
        alpha = read("alpha", .alpha, width: 1)?[0]
        brightness = read("brightness", .brightness, width: 1)?[0]
    }

    var isEmpty: Bool { fields.isEmpty }
}
