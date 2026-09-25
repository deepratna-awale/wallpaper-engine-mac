import Foundation

extension SceneRawValue {
    /// The value's user binding over its literal, without any script or animation (those run in
    /// their own per-frame paths). Nil when the value isn't user-bound.
    var userBindingSource: SceneValueSource? {
        guard case .object(let object) = self, let name = object.userName else { return nil }
        let literal = object.value?.literalString.flatMap(ShaderValue.init(string:)) ?? .zero
        return .user(name: name, condition: object.userCondition, fallback: .literal(literal))
    }
}

extension SceneObjectValueField {
    /// Resolves a binding of this field. A scalar property bound to `scale` or `color` (a slider)
    /// applies to every axis/channel.
    func resolve(_ source: SceneValueSource, in context: SceneValueContext) -> ShaderValue {
        let value = SceneValueResolver.resolve(source, in: context)
        guard value.components.count == 1, self == .scale || self == .color else { return value }
        return ShaderValue(components: Array(repeating: value.float, count: 3))
    }
}

extension ShaderValue {
    /// WE's text form: components separated by spaces.
    var sceneString: String {
        components.map { SceneJSON.number(Double($0)).scalarString ?? "0" }.joined(separator: " ")
    }
}

extension WESceneObject {
    /// This object with every user-bound field replaced by the property's current value, so
    /// content built from it shows what the properties say. Script- and animation-driven fields
    /// keep their literal; the renderer evaluates those each frame.
    func resolvingUserBindings(in context: SceneValueContext) -> WESceneObject {
        var object = self
        for (field, raw) in values {
            guard let source = raw.userBindingSource else { continue }
            let value = field.resolve(source, in: context)
            switch field {
            case .origin: object.origin = value.sceneString
            case .scale: object.scale = value.sceneString
            case .angles: object.angles = value.sceneString
            case .color: object.color = value.sceneString
            case .size: object.size = value.sceneString
            case .alpha: object.alpha = Double(value.float)
            case .brightness: object.brightness = Double(value.float)
            case .pointsize: object.pointsize = Double(value.float)
            }
        }
        if let name = textUserProperty, let text = context.userProperty(name) {
            object.textValue = text
        }
        object.originScriptProperties = SceneScriptPropertyResolver.resolve(originScriptPropertiesJSON, in: context)
        object.textScriptProperties = SceneScriptPropertyResolver.resolve(textScriptPropertiesJSON, in: context)
        return object
    }
}

/// Resolves `scriptproperties` entries of the form `{"user": name, "value": v}` (possibly nested)
/// to the user property's value, falling back to the innermost literal.
enum SceneScriptPropertyResolver {
    static func resolve(_ properties: [String: SceneJSON], in context: SceneValueContext) -> [String: String] {
        properties.compactMapValues { resolve($0, in: context) }
    }

    static func resolve(_ entry: SceneJSON, in context: SceneValueContext) -> String? {
        guard case .object(let fields) = entry else { return entry.scalarString }
        let name: String?
        switch fields["user"] {
        case .string(let value)?: name = value
        case .object(let user)?: if case .string(let value)? = user["name"] { name = value } else { name = nil }
        default: name = nil
        }
        if let name, let value = context.userProperty(name) { return value }
        return fields["value"].flatMap { resolve($0, in: context) }
    }
}
