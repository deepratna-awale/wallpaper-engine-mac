import Foundation

/// A user-facing parameter of a WE effect, straight from its shader annotations.
struct EffectShaderParameter: Equatable {
    /// The key `constantshadervalues` and overrides use.
    let materialKey: String
    /// The annotation's `label` (a WE localisation key such as `ui_editor_properties_speed`), or
    /// the material key when there is none.
    let label: String
    /// Default per component (1 for float, 2 for vec2, ...), parsed as the renderer parses it.
    let defaultValue: [Double]
    /// The annotation's `range`, or WE's editor default of 0...1 when it has none.
    let minimum: Double
    let maximum: Double
    let isInteger: Bool
    /// `"type": "color"`.
    let isColor: Bool
    /// `"linked": true`: a vec2 edited with one slider for both components while they are equal.
    let isLinked: Bool

    /// The label as words, without WE's translation table.
    var title: String { SceneEffectParameters.title(label) }
}

/// A `// [COMBO]` switch an effect exposes in WE's editor (it has a `material` key).
struct EffectShaderCombo: Equatable {
    struct Option: Equatable {
        /// A WE localisation key, as authored.
        let label: String
        let value: Int
    }

    /// The preprocessor name (`BLENDMODE`), upper-cased as the translator uses it.
    let combo: String
    /// The annotation's `material`, which WE also uses as the control's label.
    let label: String
    let defaultValue: Int
    /// The authored `options` in authored order; empty for an on/off switch.
    let options: [Option]
    /// The annotation's `type` (`options`, `imageblending`, …); nil when not authored.
    var type: String? = nil
    /// `require`: other combos' values this one is shown for (upper-cased names).
    var requirements: [String: Int] = [:]

    /// An on/off switch or an authored option list. WE fills some types (`imageblending`) from
    /// lists in its editor that we don't have, so those aren't editable here.
    var isEditable: Bool { !options.isEmpty || type == nil || type == "options" }
}

/// Reads the adjustable parameters of an effect from its passes' shaders, the way WE's editor
/// does: uniforms with a `material` key that aren't hidden, labelled and ranged by annotation.
enum SceneEffectParameters {
    /// WE's editor gives a uniform without a `range` annotation a 0...1 slider
    /// (`wallpaperui.exe` 0x14046cef9: `min = 0`, `max = 1.0f` when `range` is absent).
    static let defaultRange: ClosedRange<Double> = 0...1

    /// The inspector override key of a combo choice (`combo_<NAME>`), kept apart from uniform keys.
    static func comboOverrideKey(_ combo: String) -> String { "combo_\(combo.uppercased())" }

    static func parameters(for effectFile: String, readFile: @escaping (String) -> Data?) -> [EffectShaderParameter] {
        var result: [EffectShaderParameter] = []
        for source in sources(for: effectFile, readFile: readFile) {
            for uniform in source.uniforms where !uniform.isSampler {
                guard let key = uniform.materialKey, uniform.annotation["hidden"] as? Bool != true,
                      !result.contains(where: { $0.materialKey.caseInsensitiveCompare(key) == .orderedSame }),
                      let parameter = parameter(uniform, key: key) else { continue }
                result.append(parameter)
            }
        }
        return result
    }

    /// The effect's combos that WE's editor shows (those with a `material` key).
    static func combos(for effectFile: String, readFile: @escaping (String) -> Data?) -> [EffectShaderCombo] {
        var result: [EffectShaderCombo] = []
        for source in sources(for: effectFile, readFile: readFile) {
            for combo in combos(in: source.text) where !result.contains(where: { $0.combo == combo.combo }) {
                result.append(combo)
            }
        }
        return result
    }

    /// Every stage of every pass's shader, in pass order.
    private static func sources(for effectFile: String, readFile: @escaping (String) -> Data?) -> [ShaderSource] {
        let directory = (effectFile as NSString).deletingLastPathComponent
        let scoped: (String) -> Data? = { path in
            (directory.isEmpty ? [path] : ["\(directory)/\(path)", path]).lazy.compactMap(readFile).first
        }
        guard let data = readFile(effectFile),
              let document = try? decodeTolerant(EffectDocument.self, from: data) else { return [] } // no parameters to show
        let loader = ShaderSourceLoader(readFile: scoped)
        var result: [ShaderSource] = []
        for pass in document.passes {
            guard let materialPath = pass.material, let materialData = scoped(materialPath),
                  let material = try? decodeTolerant(MaterialDocument.self, from: materialData), // shown effects only
                  let shader = material.passes.first?.shader else { continue }
            for stage in ShaderStage.allCases {
                guard let source = try? loader.load(shader, stage: stage) else { continue } // missing stage has no parameters
                result.append(source)
            }
        }
        return result
    }

    static func parameter(_ uniform: ShaderUniformDeclaration, key: String) -> EffectShaderParameter? {
        let components: Int
        switch uniform.type {
        case "float", "int": components = 1
        case "vec2": components = 2
        case "vec3": components = 3
        case "vec4": components = 4
        default: return nil
        }
        let annotation = uniform.annotation
        let isInteger = (annotation["int"] as? NSNumber)?.boolValue == true || uniform.type == "int"
        // The renderer's parse (`ShaderConstantResolver`): missing components are 0.
        var parsed = annotation["default"].flatMap { ShaderValue(json: $0) } ?? .zero
        parsed = parsed.resized(to: components)
        if isInteger { parsed = parsed.roundedToIntegers() }
        let range = (annotation["range"] as? [NSNumber])?.map(\.doubleValue)
        let hasRange = range.map { $0.count >= 2 } ?? false
        return EffectShaderParameter(materialKey: key, label: annotation["label"] as? String ?? key,
                                     defaultValue: parsed.components.map(Double.init),
                                     minimum: hasRange ? range![0] : defaultRange.lowerBound,
                                     maximum: hasRange ? range![1] : defaultRange.upperBound,
                                     isInteger: isInteger,
                                     isColor: (annotation["type"] as? String)?.lowercased() == "color",
                                     isLinked: (annotation["linked"] as? NSNumber)?.boolValue == true)
    }

    private static let comboPattern = try! NSRegularExpression(pattern: #"//\s*\[COMBO\]\s*(\{[^\n]*\})"#)
    private static let optionPattern = try! NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)"\s*:\s*(-?\d+)"#)

    /// `// [COMBO]` annotations with a `material` key, in source order.
    static func combos(in text: String) -> [EffectShaderCombo] {
        var result: [EffectShaderCombo] = []
        for match in comboPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            let raw = String(text[range])
            guard let json = ShaderSourceLoader.annotation(raw), let name = json["combo"] as? String,
                  let label = json["material"] as? String else { continue }
            let value = (json["default"] as? NSNumber)?.intValue ?? Int(json["default"] as? String ?? "") ?? 0
            result.append(EffectShaderCombo(combo: name.uppercased(), label: label, defaultValue: value,
                                            options: json["options"] is [String: Any] ? orderedOptions(raw) : [],
                                            type: json["type"] as? String,
                                            requirements: requirements(json["require"])))
        }
        return result
    }

    private static func requirements(_ raw: Any?) -> [String: Int] {
        var result: [String: Int] = [:]
        for (name, value) in raw as? [String: Any] ?? [:] {
            if let number = value as? NSNumber { result[name.uppercased()] = number.intValue }
        }
        return result
    }

    /// The `options` object's entries in authored order (JSONSerialization loses the order).
    private static func orderedOptions(_ raw: String) -> [EffectShaderCombo.Option] {
        guard let start = raw.range(of: #""options"\s*:\s*\{"#, options: .regularExpression),
              let end = raw[start.upperBound...].firstIndex(of: "}") else { return [] }
        let body = String(raw[start.upperBound..<end])
        return optionPattern.matches(in: body, range: NSRange(body.startIndex..., in: body)).compactMap { match in
            guard let label = Range(match.range(at: 1), in: body), let value = Range(match.range(at: 2), in: body),
                  let number = Int(body[value]) else { return nil }
            return EffectShaderCombo.Option(label: String(body[label]), value: number)
        }
    }

    /// WE labels are localisation keys (`ui_editor_properties_speed`); show them as words when
    /// WE's own translation table isn't available.
    static func title(_ label: String) -> String {
        var words = label
        for prefix in ["ui_editor_properties_", "ui_editor_"] where words.hasPrefix(prefix) {
            words = String(words.dropFirst(prefix.count))
        }
        return words.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}
