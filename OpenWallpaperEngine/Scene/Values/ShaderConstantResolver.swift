import Foundation

/// Resolves the values of one pass's shader uniforms from annotation defaults, material
/// `constantshadervalues` and instance `constantshadervalues` (lowest priority first).
///
/// Built-in uniforms (`g_Time`, `g_Texture0Resolution`, …) are filled elsewhere; a uniform with
/// no `material` annotation and no value from any source is left out of the result.
enum ShaderConstantResolver {
    /// One uniform as declared in the WE shader source.
    struct Uniform {
        let name: String
        /// GLSL type name (`float`, `vec3`, `int`, …).
        let glslType: String
        /// 1 for non-arrays.
        let arrayCount: Int
        /// The JSON annotation after the declaration (`{"material": …, "default": …, "int": true}`).
        let annotation: [String: Any]

        init(name: String, glslType: String, arrayCount: Int = 1, annotation: [String: Any] = [:]) {
            self.name = name
            self.glslType = glslType
            self.arrayCount = max(arrayCount, 1)
            self.annotation = annotation
        }

        var materialName: String? { annotation["material"] as? String }
        var isInt: Bool {
            if (annotation["int"] as? NSNumber)?.boolValue == true { return true }
            return ["int", "ivec2", "ivec3", "ivec4", "uint", "bool"].contains(glslType)
        }

        /// Float components per element, or nil for types this resolver does not fill (samplers, matrices).
        var componentsPerElement: Int? {
            switch glslType {
            case "float", "int", "uint", "bool": return 1
            case "vec2", "ivec2": return 2
            case "vec3", "ivec3": return 3
            case "vec4", "ivec4": return 4
            default: return nil
            }
        }
    }

    struct DynamicConstant {
        let uniform: String
        let source: SceneValueSource
        let count: Int
        let isInt: Bool
    }

    /// Values that never change after load, plus the sources to re-resolve every frame.
    struct ResolvedConstants {
        let staticValues: [String: ShaderValue]
        let dynamic: [DynamicConstant]

        /// All values for this frame; only the dynamic sources are evaluated.
        func values(in context: SceneValueContext) -> [String: ShaderValue] {
            guard !dynamic.isEmpty else { return staticValues }
            var result = staticValues
            for constant in dynamic {
                result[constant.uniform] = ShaderConstantResolver.shape(
                    SceneValueResolver.resolve(constant.source, in: context),
                    count: constant.count, isInt: constant.isInt)
            }
            return result
        }
    }

    static func resolve(uniforms: [Uniform],
                        material: [String: SceneValueSource],
                        instance: [String: SceneValueSource]) -> ResolvedConstants {
        let materialLookup = KeyLookup(material)
        let instanceLookup = KeyLookup(instance)
        var staticValues: [String: ShaderValue] = [:]
        var dynamic: [DynamicConstant] = []

        for uniform in uniforms {
            guard let perElement = uniform.componentsPerElement else { continue }
            let count = perElement * uniform.arrayCount
            let source = instanceLookup.source(for: uniform)
                ?? materialLookup.source(for: uniform)
                ?? defaultSource(for: uniform)
            guard let source else {
                if uniform.materialName != nil {
                    staticValues[uniform.name] = shape(.zero, count: count, isInt: uniform.isInt)
                }
                continue
            }
            if case .literal(let value) = source {
                staticValues[uniform.name] = shape(value, count: count, isInt: uniform.isInt)
            } else {
                dynamic.append(DynamicConstant(uniform: uniform.name, source: source,
                                               count: count, isInt: uniform.isInt))
            }
        }
        return ResolvedConstants(staticValues: staticValues, dynamic: dynamic)
    }

    static func shape(_ value: ShaderValue, count: Int, isInt: Bool) -> ShaderValue {
        let sized = value.resized(to: count)
        return isInt ? sized.roundedToIntegers() : sized
    }

    /// The annotation `default`: a number, bool, or space-separated string (parsed as floats, not truncated).
    private static func defaultSource(for uniform: Uniform) -> SceneValueSource? {
        guard let raw = uniform.annotation["default"] else { return nil }
        guard let value = ShaderValue(json: raw) else {
            OWELog.error(.shader, "ShaderConstantResolver: unparseable default \(raw) for \(uniform.name)")
            return nil
        }
        return .literal(value)
    }

    /// Key matching: annotation `material` exact, then case-insensitive, then the uniform name
    /// without its `g_` prefix (case-insensitive).
    private struct KeyLookup {
        let exact: [String: SceneValueSource]
        let folded: [String: SceneValueSource]

        init(_ values: [String: SceneValueSource]) {
            exact = values
            // Sorted so a case-only collision resolves the same way every run.
            var folded: [String: SceneValueSource] = [:]
            for key in values.keys.sorted() where folded[key.lowercased()] == nil {
                folded[key.lowercased()] = values[key]
            }
            self.folded = folded
        }

        func source(for uniform: Uniform) -> SceneValueSource? {
            if let material = uniform.materialName {
                if let value = exact[material] { return value }
                if let value = folded[material.lowercased()] { return value }
            }
            let bare = uniform.name.hasPrefix("g_") ? String(uniform.name.dropFirst(2)) : uniform.name
            return folded[bare.lowercased()]
        }
    }
}
