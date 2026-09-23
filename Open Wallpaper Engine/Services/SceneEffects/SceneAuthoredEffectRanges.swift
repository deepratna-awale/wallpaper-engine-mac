import Foundation

/// Per-effect, per-parameter authored ranges recovered from Wallpaper Engine's own shaders.
///
/// Every WE uniform carries a trailing JSON annotation, e.g.
/// `uniform float g_Amp; // {"material":"strength","default":0.1,"range":[0.01, 0.5]}`.
/// Those annotations survive in the `.reflection.json` sidecars written next to each translated
/// shader, so the authored range is available without shipping the original GLSL.
///
/// They are needed because an authored magnitude only means something relative to its own range:
/// `strength` spans `[0.01, 0.5]` for shake but `[0, 2]` for VHS. Our shaders were tuned against
/// the ranges declared in `SceneEffectRegistry`, so a value is translated by its position within
/// the authored range rather than by any fixed factor.
///
/// Particle systems deliberately have no entries here: their JSON carries raw simulation
/// quantities (pixels per second, seconds, pixels) rather than normalised UI parameters, so an
/// authored particle value is already in the units the simulation wants.
enum SceneAuthoredEffectRanges {
    struct AuthoredParameter {
        let range: ClosedRange<Float>
        let defaultValue: Float?
        let label: String
        let isInteger: Bool

        init(range: ClosedRange<Float>, defaultValue: Float?, label: String = "", isInteger: Bool = false) {
            self.range = range
            self.defaultValue = defaultValue
            self.label = label
            self.isInteger = isInteger
        }
    }

    struct AuthoredEffect {
        let group: String
        let groupTitle: String
        let title: String
        let parameters: [String: AuthoredParameter]
    }

    private struct Annotation: Decodable {
        let material: String?
        let range: [Float]?
        let `default`: WEFlexValue?
    }

    private struct TableParameter: Decodable {
        let range: [Float]
        let `default`: Float?
        let label: String?
        let int: Bool?
    }

    private struct TableEffect: Decodable {
        let group: String
        let groupTitle: String
        let title: String
        let parameters: [String: TableParameter]
    }

    /// A few effects key their materials by the full editor label rather than a bare name.
    private static let keyPrefixes = ["", "ui_editor_properties_"]

    private static let table: [String: AuthoredEffect] = load()

    static var effectCount: Int { table.count }
    static var parameterCount: Int { table.values.reduce(0) { $0 + $1.parameters.count } }

    static func effect(_ name: String) -> AuthoredEffect? { table[name.lowercased()] }

    /// Effect names bucketed by Wallpaper Engine's own grouping, each group sorted by title.
    static func groupedEffects() -> [(group: String, title: String, effects: [String])] {
        Dictionary(grouping: table.keys) { table[$0]!.group }
            .map { group, names in
                (group: group,
                 title: table[names[0]]!.groupTitle,
                 effects: names.sorted { table[$0]!.title < table[$1]!.title })
            }
            .sorted { $0.title < $1.title }
    }

    static func authored(effect: String, key: String) -> AuthoredParameter? {
        guard let parameters = table[effect.lowercased()]?.parameters else { return nil }
        for prefix in keyPrefixes {
            if let match = parameters[prefix + key.lowercased()] { return match }
        }
        return nil
    }

    /// Every authored parameter of an effect, for surfacing them as controls.
    static func parameters(forEffect effect: String) -> [String: AuthoredParameter] {
        table[effect.lowercased()]?.parameters ?? [:]
    }

    /// Re-expresses an authored value in the range this build's shader math expects for that exact
    /// parameter. Returns `nil` only when Wallpaper Engine declared no range for it.
    ///
    /// Where we have not declared a range of our own the authored range is used as the target,
    /// which leaves in-range values untouched and clamps out-of-range ones the way Wallpaper
    /// Engine's own editor bounds would.
    static func translate(effect: String, key: String, authored: Float) -> Float? {
        guard let source = Self.authored(effect: effect, key: key) else { return nil }
        let sourceSpan = source.range.upperBound - source.range.lowerBound
        guard sourceSpan > 0 else { return nil }
        let declared = SceneEffectRegistry.parameter(effect: effect, key: key)
        let targetLower = declared.map { Float($0.minimum) } ?? source.range.lowerBound
        let targetUpper = declared.map { Float($0.maximum) } ?? source.range.upperBound
        guard targetUpper > targetLower else { return nil }
        let normalized = min(max((authored - source.range.lowerBound) / sourceSpan, 0), 1)
        return targetLower + normalized * (targetUpper - targetLower)
    }

    private static func load() -> [String: AuthoredEffect] {
        // The generated table is our own artifact, so it lives in the bundle even when the user
        // points at their own Wallpaper Engine install.
        for candidate in [WallpaperEngineAssets.directory, WallpaperEngineAssets.bundled].compactMap({ $0 }) {
            if let table = loadGeneratedTable(in: candidate), !table.isEmpty { return table }
        }
        guard let assets = WallpaperEngineAssets.directory else { return [:] }
        return loadFromSidecars(in: assets)
    }

    /// Distilled from every effect's GLSL at vendoring time. The sidecars only cover shaders a
    /// wallpaper referenced, which is roughly half of what Wallpaper Engine declares.
    private static func loadGeneratedTable(in assets: URL) -> [String: AuthoredEffect]? {
        let url = assets.appending(path: "effect-parameter-ranges.json")
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: TableEffect].self, from: data) else { return nil }
        var table: [String: AuthoredEffect] = [:]
        for (effect, entry) in decoded {
            var parameters: [String: AuthoredParameter] = [:]
            for (key, parameter) in entry.parameters
            where parameter.range.count >= 2 && parameter.range[1] > parameter.range[0] {
                parameters[key] = AuthoredParameter(range: parameter.range[0]...parameter.range[1],
                                                    defaultValue: parameter.default,
                                                    label: parameter.label ?? key.capitalized,
                                                    isInteger: parameter.int ?? false)
            }
            guard !parameters.isEmpty else { continue }
            table[effect] = AuthoredEffect(group: entry.group, groupTitle: entry.groupTitle,
                                           title: entry.title, parameters: parameters)
        }
        OWELog.info(.shader, "Authored effect ranges: \(table.count) effects, "
            + "\(table.values.reduce(0) { $0 + $1.parameters.count }) parameters (generated table)")
        return table
    }

    private static func loadFromSidecars(in assets: URL) -> [String: AuthoredEffect] {
        let shaders = assets.appending(path: ".open-wallpaper-engine/shaders", directoryHint: .isDirectory)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: shaders.path) else { return [:] }

        var table: [String: [String: AuthoredParameter]] = [:]
        let decoder = JSONDecoder()
        for name in names where name.hasSuffix(".reflection.json") {
            guard let effect = effectName(fromSidecar: name),
                  let data = try? Data(contentsOf: shaders.appending(path: name)),
                  let reflection = try? decoder.decode(SceneShaderReflection.self, from: data) else { continue }
            for uniform in reflection.uniforms {
                guard let semantic = uniform.semantic,
                      let payload = semantic.data(using: .utf8),
                      let annotation = try? decoder.decode(Annotation.self, from: payload),
                      let key = annotation.material?.lowercased(),
                      let bounds = annotation.range, bounds.count >= 2 else { continue }
                let lower = min(bounds[0], bounds[1])
                let upper = max(bounds[0], bounds[1])
                guard upper > lower, table[effect]?[key] == nil else { continue }
                table[effect, default: [:]][key] = AuthoredParameter(
                    range: lower...upper,
                    defaultValue: annotation.default.map { Float($0.doubleValue) },
                    label: key.capitalized)
            }
        }
        let total = table.values.reduce(0) { $0 + $1.count }
        OWELog.info(.shader, "Authored effect ranges: \(table.count) effects, \(total) parameters [sidecars]")
        // Sidecars carry no grouping; the generated table is the source for that.
        return table.mapValues {
            AuthoredEffect(group: "other", groupTitle: "Other", title: "", parameters: $0)
        }
    }

    /// `effects_shake_shaders_effects_shake.frag.metal.reflection.json` -> `shake`.
    /// Preview variants describe the editor thumbnail, not the effect, so they are skipped.
    private static func effectName(fromSidecar name: String) -> String? {
        guard name.hasPrefix("effects_"),
              let marker = name.range(of: "_shaders_") else { return nil }
        let effect = String(name[name.index(name.startIndex, offsetBy: "effects_".count)..<marker.lowerBound])
        guard !effect.isEmpty, !effect.hasSuffix("_preview") else { return nil }
        return effect.lowercased()
    }
}
