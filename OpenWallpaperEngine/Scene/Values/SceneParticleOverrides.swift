import simd

/// A particle object's `instanceoverride`, resolved against the current user properties.
///
/// Scalars multiply the particle file's values (`rate` the emission rate, `count` the particle
/// budget, `size`/`alpha`/`lifetime` their initial ranges, `speed` the initial velocity).
/// `colorn` (0–1) or `color` (0–255) tints the initial colour, and `brightness` scales it.
struct SceneParticleOverrides: Equatable {
    var rate: Float = 1
    var count: Float = 1
    var size: Float = 1
    var alpha: Float = 1
    var speed: Float = 1
    var lifetime: Float = 1
    var brightness: Float = 1
    var tint = SIMD3<Float>(repeating: 1)
    /// The `rate` script, evaluated by the particle runtime each frame.
    var rateScript: String?

    init() {}

    init(_ override: WEInstanceOverride?, in context: SceneValueContext) {
        guard let override else { return }
        // Scripts run in the particle runtime; only the user binding and the literal resolve here.
        func value(_ field: SceneInstanceOverrideField) -> ShaderValue? {
            guard let raw = override.values[field] else { return nil }
            if let source = raw.userBindingSource { return SceneValueResolver.resolve(source, in: context) }
            return raw.literalString.flatMap(ShaderValue.init(string:))
        }
        func scalar(_ field: SceneInstanceOverrideField) -> Float? { value(field)?.float }
        func vector(_ field: SceneInstanceOverrideField) -> SIMD3<Float>? {
            value(field).map { $0.components.count == 1 ? SIMD3(repeating: $0.float) : $0.vec3 }
        }
        rate = scalar(.rate) ?? 1
        count = scalar(.count) ?? 1
        size = scalar(.size) ?? 1
        alpha = scalar(.alpha) ?? 1
        speed = scalar(.speed) ?? 1
        lifetime = scalar(.lifetime) ?? 1
        brightness = scalar(.brightness) ?? 1
        if let colorn = vector(.colorn) {
            tint = colorn
        } else if let color = vector(.color) {
            tint = color / 255
        }
        rateScript = override.values[.rate]?.scriptSource
    }
}
