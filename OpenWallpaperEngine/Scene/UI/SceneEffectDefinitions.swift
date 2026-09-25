import Foundation

/// A single user-adjustable slider for an effect. `key` must match the constant name the shader
/// reads via `_owe_effect_<effect.name>_<key>` in `EffectStack.descriptor(for:)`.
struct SceneEffectParameter {
    let key: String
    let title: String
    let defaultValue: String
    let minimum: Double
    let maximum: Double

    var usesNormalizedStrength: Bool {
        Self.isMagnitudeKey(key)
    }

    var normalizedDefaultValue: String {
        defaultValue
    }

    var normalizedMinimum: Double { minimum }
    var normalizedMaximum: Double { maximum }

    static func isMagnitudeKey(_ key: String) -> Bool {
        let normalized = key.lowercased()
        return normalized.contains("strength") || normalized.contains("intensity")
    }
}

/// Describes one renderer-supported scene effect and the controls it exposes in the Properties
/// sidebar. Adding a new case here (plus the matching shader kind) is all the UI needs to show it.
struct SceneEffectDefinition {
    let name: String
    let title: String
    let parameters: [SceneEffectParameter]
    /// Raw author-declared user-property names (from project.json) that some workshop wallpapers
    /// use directly as this effect's own enable/disable toggle, in place of our generic
    /// `_owe_effect_enabled_<name>` property (e.g. "eyesnitro" for nitro, "vhs" for vhs).
    let authoredToggleAliases: [String]

    init(name: String, title: String, parameters: [SceneEffectParameter], authoredToggleAliases: [String] = []) {
        self.name = name
        self.title = title
        self.parameters = parameters
        self.authoredToggleAliases = authoredToggleAliases
    }
}

enum SceneEffectRegistry {
    static let all: [SceneEffectDefinition] = [
        SceneEffectDefinition(name: "tint", title: "Tint", parameters: [
            SceneEffectParameter(key: "alpha", title: "Tint Alpha", defaultValue: "1", minimum: 0, maximum: 1)
        ]),
        SceneEffectDefinition(name: "opacity", title: "Opacity", parameters: [
            SceneEffectParameter(key: "alpha", title: "Opacity", defaultValue: "1", minimum: 0, maximum: 1)
        ]),
        SceneEffectDefinition(name: "fisheye", title: "Fisheye", parameters: [
            SceneEffectParameter(key: "size", title: "Fisheye Size", defaultValue: "1", minimum: 0.01, maximum: 1),
            SceneEffectParameter(key: "scale", title: "Fisheye Distortion", defaultValue: "1", minimum: 0, maximum: 2.5)
        ]),
        SceneEffectDefinition(name: "scroll", title: "Scroll", parameters: [
            SceneEffectParameter(key: "speedx", title: "Scroll X Speed", defaultValue: "0.2", minimum: -2, maximum: 2),
            SceneEffectParameter(key: "speedy", title: "Scroll Y Speed", defaultValue: "0.2", minimum: -2, maximum: 2)
        ]),
        SceneEffectDefinition(name: "chromaticaberration", title: "Chromatic Aberration", parameters: [
            SceneEffectParameter(key: "strength", title: "Aberration Strength", defaultValue: "1", minimum: 0, maximum: 2),
            SceneEffectParameter(key: "centerfalloff", title: "Center Falloff", defaultValue: "1", minimum: 0, maximum: 1)
        ]),
        SceneEffectDefinition(name: "colorkey", title: "Color Key", parameters: [
            SceneEffectParameter(key: "alpha", title: "Key Alpha", defaultValue: "0", minimum: 0, maximum: 1),
            SceneEffectParameter(key: "fuzziness", title: "Key Fuzziness", defaultValue: "0", minimum: 0, maximum: 3),
            SceneEffectParameter(key: "tolerance", title: "Key Tolerance", defaultValue: "0.1", minimum: 0, maximum: 3)
        ]),
        SceneEffectDefinition(name: "spin", title: "Spin", parameters: [
            SceneEffectParameter(key: "size", title: "Spin Size", defaultValue: "0.1", minimum: 0, maximum: 1),
            SceneEffectParameter(key: "feather", title: "Spin Feather", defaultValue: "0.002", minimum: 0, maximum: 0.2)
        ]),
        SceneEffectDefinition(name: "blend", title: "Blend", parameters: []),
        SceneEffectDefinition(name: "blendgradient", title: "Blend Gradient", parameters: []),
        SceneEffectDefinition(name: "blurradial", title: "Radial Blur", parameters: []),
        SceneEffectDefinition(name: "watercaustics", title: "Caustics", parameters: []),
        SceneEffectDefinition(name: "cloudmotion", title: "Cloud Motion", parameters: []),
        SceneEffectDefinition(name: "clouds", title: "Clouds", parameters: []),
        SceneEffectDefinition(name: "edgedetection", title: "Edge Detection", parameters: []),
        SceneEffectDefinition(name: "filmgrain", title: "Film Grain", parameters: []),
        SceneEffectDefinition(name: "fire", title: "Fire", parameters: []),
        SceneEffectDefinition(name: "perspective", title: "Perspective", parameters: []),
        SceneEffectDefinition(name: "depthparallax", title: "Depth Parallax", parameters: [
            SceneEffectParameter(key: "depthx", title: "Depth X", defaultValue: "0.1", minimum: -2, maximum: 2),
            SceneEffectParameter(key: "depthy", title: "Depth Y", defaultValue: "0.1", minimum: -2, maximum: 2),
            SceneEffectParameter(key: "perspective", title: "Perspective", defaultValue: "0.2", minimum: 0, maximum: 2)
        ]),
        SceneEffectDefinition(name: "reflection", title: "Reflection", parameters: []),
        SceneEffectDefinition(name: "skew", title: "Skew", parameters: []),
        SceneEffectDefinition(name: "swing", title: "Swing", parameters: []),
        SceneEffectDefinition(name: "transform", title: "Transform", parameters: []),
        SceneEffectDefinition(name: "twirl", title: "Twirl", parameters: []),
        SceneEffectDefinition(name: "waterflow", title: "Water Flow", parameters: []),
        SceneEffectDefinition(name: "xray", title: "X-Ray", parameters: []),
        SceneEffectDefinition(name: "blur", title: "Blur", parameters: []),
        SceneEffectDefinition(name: "blurprecise", title: "Precise Blur", parameters: []),
        SceneEffectDefinition(name: "cursorripple", title: "Cursor Ripple", parameters: []),
        SceneEffectDefinition(name: "glitter", title: "Glitter", parameters: []),
        SceneEffectDefinition(name: "localcontrast", title: "Local Contrast", parameters: []),
        SceneEffectDefinition(name: "motionblur", title: "Motion Blur", parameters: []),
        SceneEffectDefinition(name: "refraction", title: "Refraction", parameters: []),
        SceneEffectDefinition(name: "shine", title: "Shine", parameters: []),
        SceneEffectDefinition(name: "empty", title: "Empty", parameters: []),
        SceneEffectDefinition(name: "shimmer", title: "Shimmer", parameters: []),
        SceneEffectDefinition(name: "shake", title: "Shake", parameters: [
            SceneEffectParameter(key: "strength", title: "Shake Strength", defaultValue: "0.072", minimum: 0, maximum: 1),
            SceneEffectParameter(key: "speed", title: "Shake Speed", defaultValue: "2", minimum: 0, maximum: 10),
            SceneEffectParameter(key: "friction", title: "Shake Friction", defaultValue: "1", minimum: 0, maximum: 10)
        ]),
        SceneEffectDefinition(name: "waterwaves", title: "Water Waves", parameters: [
            SceneEffectParameter(key: "strength", title: "Water Waves Strength", defaultValue: "0.03", minimum: 0, maximum: 1),
            SceneEffectParameter(key: "speed", title: "Water Waves Speed", defaultValue: "3", minimum: 0, maximum: 50),
            SceneEffectParameter(key: "scale", title: "Water Waves Scale", defaultValue: "25", minimum: 1, maximum: 100),
            SceneEffectParameter(key: "exponent", title: "Water Waves Exponent", defaultValue: "1", minimum: 0.5, maximum: 4),
            SceneEffectParameter(key: "direction", title: "Water Waves Direction", defaultValue: "0", minimum: -Double.pi, maximum: Double.pi)
        ]),
        SceneEffectDefinition(name: "nitro", title: "Nitro", parameters: [
            SceneEffectParameter(key: "multiply", title: "Nitro Intensity", defaultValue: "0.75", minimum: 0, maximum: 2),
            SceneEffectParameter(key: "smoothness", title: "Nitro Smoothness", defaultValue: "1", minimum: 0.1, maximum: 5)
        ], authoredToggleAliases: ["eyesnitro", "eyenitro"]),
        SceneEffectDefinition(name: "vhs", title: "VHS", parameters: [
            SceneEffectParameter(key: "strength", title: "VHS Strength", defaultValue: "1.2", minimum: 0, maximum: 2),
            SceneEffectParameter(key: "chromatic", title: "VHS Chromatic", defaultValue: "0.1", minimum: 0, maximum: 1),
            SceneEffectParameter(key: "artifacts", title: "VHS Artifacts", defaultValue: "0.5", minimum: 0, maximum: 1),
            SceneEffectParameter(key: "distortionstrength", title: "VHS Distortion", defaultValue: "1", minimum: 0, maximum: 2),
            SceneEffectParameter(key: "distortionspeed", title: "VHS Distortion Speed", defaultValue: "1", minimum: 0, maximum: 2),
            SceneEffectParameter(key: "distortionwidth", title: "VHS Distortion Width", defaultValue: "1", minimum: 0, maximum: 2)
        ], authoredToggleAliases: ["vhs"]),
        SceneEffectDefinition(name: "pulse", title: "Pulse", parameters: []),
        SceneEffectDefinition(name: "audiobars", title: "Audio Bars", parameters: [
            SceneEffectParameter(key: "opacity", title: "Bars Opacity", defaultValue: "1", minimum: 0, maximum: 1),
            SceneEffectParameter(key: "strength", title: "Bars Sensitivity", defaultValue: "2.2", minimum: 0, maximum: 6),
            SceneEffectParameter(key: "minimum", title: "Minimum Height", defaultValue: "0.02", minimum: 0, maximum: 0.5),
            SceneEffectParameter(key: "bars", title: "Bar Count", defaultValue: "16", minimum: 4, maximum: 16),
            SceneEffectParameter(key: "gap", title: "Bar Gap", defaultValue: "0.5", minimum: 0, maximum: 0.85),
            SceneEffectParameter(key: "smoothing", title: "Smoothing", defaultValue: "0.72", minimum: 0, maximum: 0.95),
            SceneEffectParameter(key: "glow", title: "Glow", defaultValue: "0.35", minimum: 0, maximum: 1),
            SceneEffectParameter(key: "red", title: "Red", defaultValue: "0.35", minimum: 0, maximum: 1),
            SceneEffectParameter(key: "green", title: "Green", defaultValue: "0.85", minimum: 0, maximum: 1),
            SceneEffectParameter(key: "blue", title: "Blue", defaultValue: "1", minimum: 0, maximum: 1)
        ], authoredToggleAliases: ["audiovisualizer"]),
        SceneEffectDefinition(name: "hueshift", title: "Hyperdrive Hue Shift", parameters: [
            SceneEffectParameter(key: "audioamount", title: "Music Sensitivity", defaultValue: "0.2", minimum: 0, maximum: 2),
            SceneEffectParameter(key: "audioexponent", title: "Music Curve", defaultValue: "0.2", minimum: 0.05, maximum: 4),
            SceneEffectParameter(key: "frequencymin", title: "Min Frequency Band", defaultValue: "4", minimum: 0, maximum: 15),
            SceneEffectParameter(key: "frequencymax", title: "Max Frequency Band", defaultValue: "7", minimum: 0, maximum: 15),
            SceneEffectParameter(key: "intensity", title: "Hue Intensity", defaultValue: "1", minimum: 0, maximum: 2)
        ], authoredToggleAliases: ["hyperdrive"]),
        SceneEffectDefinition(name: "hyperdrive", title: "Hyperdrive", parameters: [
            SceneEffectParameter(key: "audioamount", title: "Music Sensitivity", defaultValue: "1", minimum: 0, maximum: 3),
            SceneEffectParameter(key: "audioexponent", title: "Music Curve", defaultValue: "1", minimum: 0.05, maximum: 4),
            SceneEffectParameter(key: "frequencymin", title: "Min Frequency Band", defaultValue: "0", minimum: 0, maximum: 15),
            SceneEffectParameter(key: "frequencymax", title: "Max Frequency Band", defaultValue: "1", minimum: 0, maximum: 15),
            SceneEffectParameter(key: "strength", title: "Warp Strength", defaultValue: "1", minimum: 0, maximum: 3),
            SceneEffectParameter(key: "speed", title: "Warp Speed", defaultValue: "1", minimum: 0, maximum: 3)
        ], authoredToggleAliases: ["hyperdrive"]),
        SceneEffectDefinition(name: "iris", title: "Iris", parameters: []),
        SceneEffectDefinition(name: "volumetricfog", title: "Volumetric Fog", parameters: [
            SceneEffectParameter(key: "density", title: "Fog Density", defaultValue: "0.65", minimum: 0, maximum: 2),
            SceneEffectParameter(key: "drift", title: "Fog Drift", defaultValue: "0.035", minimum: 0, maximum: 1),
            SceneEffectParameter(key: "near", title: "Fog Near", defaultValue: "0.45", minimum: 0, maximum: 1),
            SceneEffectParameter(key: "far", title: "Fog Far", defaultValue: "0.85", minimum: 0, maximum: 1)
        ]),
        SceneEffectDefinition(name: "parallax", title: "Parallax", parameters: [
            SceneEffectParameter(key: "amount", title: "Parallax Amount", defaultValue: "1", minimum: 0, maximum: 3)
        ]),
        SceneEffectDefinition(name: "foliagesway", title: "Foliage Sway", parameters: [
            SceneEffectParameter(key: "strength", title: "Sway Strength", defaultValue: "0.4", minimum: 0, maximum: 2),
            SceneEffectParameter(key: "scale", title: "Sway Scale", defaultValue: "0.05", minimum: 0, maximum: 1),
            SceneEffectParameter(key: "speeduv", title: "Sway Speed", defaultValue: "5", minimum: 0, maximum: 20)
        ]),
        SceneEffectDefinition(name: "waterripple", title: "Water Ripple", parameters: [
            SceneEffectParameter(key: "ripplestrength", title: "Ripple Strength", defaultValue: "0.06", minimum: 0, maximum: 1),
            SceneEffectParameter(key: "scale", title: "Ripple Scale", defaultValue: "0.58", minimum: 0, maximum: 2),
            SceneEffectParameter(key: "animationspeed", title: "Ripple Speed", defaultValue: "0.15", minimum: 0, maximum: 2)
        ]),
        SceneEffectDefinition(name: "godrays", title: "God Rays", parameters: [
            SceneEffectParameter(key: "rayintensity", title: "Ray Intensity", defaultValue: "0.77", minimum: 0, maximum: 2),
            SceneEffectParameter(key: "raylength", title: "Ray Length", defaultValue: "0.49", minimum: 0, maximum: 1),
            SceneEffectParameter(key: "raythreshold", title: "Ray Threshold", defaultValue: "0.86", minimum: 0, maximum: 1)
        ]),
        SceneEffectDefinition(name: "lightshafts", title: "Light Shafts", parameters: [
            SceneEffectParameter(key: "colorwintensity", title: "Shaft Intensity", defaultValue: "0.45", minimum: 0, maximum: 2),
            SceneEffectParameter(key: "rayradius", title: "Shaft Radius", defaultValue: "0.15", minimum: 0, maximum: 1),
            SceneEffectParameter(key: "rayspeed", title: "Shaft Speed", defaultValue: "0.39", minimum: 0, maximum: 2)
        ])
    ]

    private static let index: [String: [String: SceneEffectParameter]] = all.reduce(into: [:]) { table, definition in
        table[definition.name.lowercased()] = definition.parameters.reduce(into: [:]) { parameters, parameter in
            parameters[parameter.key.lowercased()] = parameter
        }
    }

    static func parameter(effect: String, key: String) -> SceneEffectParameter? {
        index[effect.lowercased()]?[key.lowercased()]
    }

    /// Effects that draw new content rather than modifying the layer they sit on. Applying one per
    /// layer would repeat its artwork for every layer in the scene, so they run once over the
    /// composited frame instead.
    static let overlayEffects: Set<String> = ["audiobars"]

    static func isOverlay(_ effect: String) -> Bool {
        overlayEffects.contains(effect.lowercased())
    }

    /// Controls for an effect: the hand-tuned ones we declare, plus every remaining parameter
    /// Wallpaper Engine authored, so nothing an effect actually reads is left unadjustable.
    static func controls(forEffect effect: String) -> [SceneEffectParameter] {
        let declared = index[effect.lowercased()] ?? [:]
        var seen = Set(declared.keys)
        var synthesized: [SceneEffectParameter] = []
        for (rawKey, parameter) in SceneAuthoredEffectRanges.parameters(forEffect: effect) {
            // Some effects key materials by their full editor label; the renderer reads the bare
            // name, so the control must use that or it writes a key nothing ever reads.
            let key = rawKey.hasPrefix("ui_editor_properties_")
                ? String(rawKey.dropFirst("ui_editor_properties_".count))
                : rawKey
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            let fallback = parameter.defaultValue ?? parameter.range.lowerBound
            synthesized.append(SceneEffectParameter(
                key: key,
                title: parameter.label.isEmpty ? key.capitalized : parameter.label,
                defaultValue: parameter.isInteger ? String(Int(fallback)) : String(fallback),
                minimum: Double(parameter.range.lowerBound),
                maximum: Double(parameter.range.upperBound)))
        }
        return (declared.values.map { $0 } + synthesized).sorted { $0.title < $1.title }
    }

    /// All known effects bucketed by Wallpaper Engine's own grouping, with anything we implement
    /// that Wallpaper Engine does not ship collected separately.
    static func grouped() -> [(title: String, effects: [SceneEffectDefinition])] {
        let byName = Dictionary(uniqueKeysWithValues: all.map { ($0.name.lowercased(), $0) })
        var grouped: [(title: String, effects: [SceneEffectDefinition])] = []
        var placed = Set<String>()
        for group in SceneAuthoredEffectRanges.groupedEffects() {
            let effects = group.effects.compactMap { byName[$0] }
            guard !effects.isEmpty else { continue }
            placed.formUnion(effects.map { $0.name.lowercased() })
            grouped.append((title: group.title, effects: effects.sorted { $0.title < $1.title }))
        }
        let remaining = all.filter { !placed.contains($0.name.lowercased()) }
        if !remaining.isEmpty {
            grouped.append((title: "Other", effects: remaining.sorted { $0.title < $1.title }))
        }
        return grouped
    }
}

/// Effect names now follow Wallpaper Engine's spelling. Per-effect settings are persisted under
/// `_owe_effect_<name>_<key>`, so saved customisations have to be carried across the rename.
enum SceneEffectNameMigration {
    private static let renames = [
        "refract": "refraction",
        "caustics": "watercaustics",
        "chromatic_aberration": "chromaticaberration",
        "blur_precise": "blurprecise",
        "blur_radial": "blurradial"
    ]

    static func run(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: "SceneEffectNamesUseWallpaperEngineSpelling") else { return }
        defer { defaults.set(true, forKey: "SceneEffectNamesUseWallpaperEngineSpelling") }

        for (storeKey, stored) in defaults.dictionaryRepresentation()
        where storeKey.hasPrefix("SceneUserProperties.") {
            guard var values = stored as? [String: String] else { continue }
            var migrated = false
            for (property, value) in values {
                guard let renamed = renamedProperty(property) else { continue }
                values.removeValue(forKey: property)
                // A setting already saved under the new name wins over the stale one.
                if values[renamed] == nil { values[renamed] = value }
                migrated = true
            }
            if migrated { defaults.set(values, forKey: storeKey) }
        }
    }

    private static func renamedProperty(_ property: String) -> String? {
        for (old, new) in renames {
            // Exact match for the toggle, so an already-renamed "…_refraction" is not treated as
            // an unmigrated "…_refract" with a trailing "ion".
            if property == "_owe_effect_enabled_\(old)" { return "_owe_effect_enabled_\(new)" }
            let prefix = "_owe_effect_\(old)_"
            if property.hasPrefix(prefix) { return "_owe_effect_\(new)_" + property.dropFirst(prefix.count) }
        }
        return nil
    }
}
