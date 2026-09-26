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

    /// Where an object's animated fields sit in a set (`SceneAnimationSet.index(of:)`): found once
    /// when the set's sites change, so a frame's read is array indexing, not a keyed lookup.
    struct Indices: Equatable {
        var origin: Int?
        var scale: Int?
        var angles: Int?
        var color: Int?
        var size: Int?
        var alpha: Int?
        var brightness: Int?
        /// The fields these indices animate.
        var fields = SceneScriptOwnedFields()

        /// Object `id`'s animated fields in `set`; nil when none is animated.
        init?(_ set: SceneAnimationSet, object id: Int) {
            func index(_ key: String) -> Int? { set.index(of: SceneAnimationSite(owner: .object(id), key: key)) }
            origin = index("origin")
            scale = index("scale")
            angles = index("angles")
            color = index("color")
            size = index("size")
            alpha = index("alpha")
            brightness = index("brightness")
            let found: [(Int?, SceneScriptObjectField)] = [(origin, .origin), (scale, .scale), (angles, .angles),
                                                            (color, .color), (size, .size), (alpha, .alpha),
                                                            (brightness, .brightness)]
            for (index, field) in found where index != nil { fields.insert(field) }
            guard !fields.isEmpty else { return nil }
        }
    }

    init() {}

    /// The object fields the renderer draws from a timeline.
    static let keys: Set<String> = ["origin", "scale", "angles", "color", "size", "alpha", "brightness"]

    /// Object `id`'s fields as `set` last sampled them.
    init(_ set: SceneAnimationSet, object id: Int) {
        guard let indices = Indices(set, object: id) else {
            self.init()
            return
        }
        self.init(set, indices: indices)
    }

    /// The fields at `indices` as `set` last sampled them.
    init(_ set: SceneAnimationSet, indices: Indices) {
        func read(_ index: Int?) -> SIMD4<Float>? { index.flatMap(set.drawnComponents(at:)) }
        origin = read(indices.origin).map { SIMD3($0.x, $0.y, $0.z) }
        scale = read(indices.scale).map { SIMD3($0.x, $0.y, $0.z) }
        angles = read(indices.angles).map { SIMD3($0.x, $0.y, $0.z) }
        color = read(indices.color).map { SIMD3($0.x, $0.y, $0.z) }
        size = read(indices.size).map { SIMD2($0.x, $0.y) }
        alpha = read(indices.alpha)?.x
        brightness = read(indices.brightness)?.x
        fields = indices.fields
    }

    var isEmpty: Bool { fields.isEmpty }
}
