import Foundation

/// A user-facing parameter of a WE effect, straight from its shader annotations.
struct EffectShaderParameter: Equatable {
    /// The key `constantshadervalues` and overrides use.
    let materialKey: String
    let title: String
    /// Default per component (1 for float, 2 for vec2, ...).
    let defaultValue: [Double]
    let minimum: Double
    let maximum: Double
    let isInteger: Bool
    let isColor: Bool
}

/// Reads the adjustable parameters of an effect from its passes' shaders, the way WE's editor
/// does: uniforms with a `material` key that aren't hidden, labelled and ranged by annotation.
enum SceneEffectParameters {
    static func parameters(for effectFile: String, readFile: @escaping (String) -> Data?) -> [EffectShaderParameter] {
        let directory = (effectFile as NSString).deletingLastPathComponent
        let scoped: (String) -> Data? = { path in
            (directory.isEmpty ? [path] : ["\(directory)/\(path)", path]).lazy.compactMap(readFile).first
        }
        guard let data = readFile(effectFile),
              let document = try? decodeTolerant(EffectDocument.self, from: data) else { return [] } // no parameters to show
        let loader = ShaderSourceLoader(readFile: scoped)
        var result: [EffectShaderParameter] = []
        for pass in document.passes {
            guard let materialPath = pass.material, let materialData = scoped(materialPath),
                  let material = try? decodeTolerant(MaterialDocument.self, from: materialData), // shown effects only
                  let shader = material.passes.first?.shader else { continue }
            for stage in ShaderStage.allCases {
                guard let source = try? loader.load(shader, stage: stage) else { continue } // missing stage has no parameters
                for uniform in source.uniforms where !uniform.isSampler {
                    guard let key = uniform.materialKey, uniform.annotation["hidden"] as? Bool != true,
                          !result.contains(where: { $0.materialKey.caseInsensitiveCompare(key) == .orderedSame }),
                          let parameter = parameter(uniform, key: key) else { continue }
                    result.append(parameter)
                }
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
        let defaults: [Double]
        if let number = annotation["default"] as? NSNumber {
            defaults = Array(repeating: number.doubleValue, count: components)
        } else if let string = annotation["default"] as? String {
            let values = string.split(separator: " ").compactMap { Double($0) }
            defaults = (0..<components).map { values.indices.contains($0) ? values[$0] : (values.last ?? 0) }
        } else {
            defaults = Array(repeating: 0, count: components)
        }
        let range = (annotation["range"] as? [NSNumber])?.map(\.doubleValue)
        let isColor = (annotation["type"] as? String)?.lowercased() == "color"
        let minimum = range?.first ?? (isColor ? 0 : min(0, defaults.min() ?? 0))
        let maximum = range.flatMap { $0.count > 1 ? $0[1] : nil } ?? (isColor ? 1 : max(1, (defaults.max() ?? 1) * 2))
        return EffectShaderParameter(materialKey: key, title: title(annotation["label"] as? String ?? key),
                                    defaultValue: defaults, minimum: minimum, maximum: maximum,
                                    isInteger: annotation["int"] as? Bool == true || uniform.type == "int",
                                    isColor: isColor)
    }

    /// WE labels are localisation keys (`ui_editor_properties_speed`); show them as words.
    static func title(_ label: String) -> String {
        var words = label
        for prefix in ["ui_editor_properties_", "ui_editor_"] where words.hasPrefix(prefix) {
            words = String(words.dropFirst(prefix.count))
        }
        return words.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}
