import Foundation

/// Where a bindable scene value comes from. Resolved to a `ShaderValue` by `SceneValueResolver`.
///
/// WE JSON forms and how `init?(json:)` maps them:
/// - `0.5`, `true`, `"1 0.5 0"` → `.literal`
/// - `{"value": v, "user": "name"}` → `.user(name, nil, fallback: v)`
/// - `{"value": v, "user": {"name": n, "condition": c}}` → `.user(n, c, fallback: v)`
/// - `{"value": v, "script": s, "scriptproperties": {…}}` → `.script(s, props, fallback: v)`
/// - `{"value": v, "animation": {…}}` → `.animation(anim, fallback: v)`
///
/// When several keys are present they nest: `user` wraps `script`, which wraps `animation`,
/// which wraps the literal `value`. A missing `value` falls back to 0.
indirect enum SceneValueSource: Equatable {
    case literal(ShaderValue)
    case user(name: String, condition: String?, fallback: SceneValueSource)
    case script(source: String, properties: SceneScriptProperties, fallback: SceneValueSource)
    case animation(SceneValueAnimation, fallback: SceneValueSource)

    /// True when the value can change after load (so it must be re-resolved every frame).
    var isDynamic: Bool {
        if case .literal = self { return false }
        return true
    }

    /// Parses JSONSerialization output (NSNumber, Bool, String or Dictionary). Logs and returns
    /// nil for anything it can't represent.
    init?(json: Any) {
        if let dictionary = json as? [String: Any] {
            self.init(dictionary: dictionary)
            return
        }
        guard let value = ShaderValue(json: json) else {
            OWELog.error(.scene, "SceneValueSource: unparseable value \(json)")
            return nil
        }
        self = .literal(value)
    }

    private init?(dictionary: [String: Any]) {
        let known: Set<String> = ["value", "user", "script", "scriptproperties", "animation"]
        guard !Set(dictionary.keys).isDisjoint(with: known) else {
            OWELog.error(.scene, "SceneValueSource: object with none of \(known.sorted()): \(dictionary.keys.sorted())")
            return nil
        }

        var source: SceneValueSource
        if let raw = dictionary["value"] {
            guard let value = ShaderValue(json: raw) else {
                OWELog.error(.scene, "SceneValueSource: unparseable 'value' \(raw)")
                return nil
            }
            source = .literal(value)
        } else {
            source = .literal(.zero)
        }

        if let raw = dictionary["animation"] {
            guard let animation = SceneValueAnimation(json: raw) else { return nil }
            source = .animation(animation, fallback: source)
        }

        if let raw = dictionary["script"] {
            guard let script = raw as? String else {
                OWELog.error(.scene, "SceneValueSource: 'script' is not a string")
                return nil
            }
            let properties = SceneScriptProperties(json: dictionary["scriptproperties"] as? [String: Any] ?? [:])
            source = .script(source: script, properties: properties, fallback: source)
        }

        if let raw = dictionary["user"] {
            if let name = raw as? String {
                source = .user(name: name, condition: nil, fallback: source)
            } else if let user = raw as? [String: Any], let name = user["name"] as? String {
                let condition: String?
                switch user["condition"] {
                case nil: condition = nil
                case let string as String: condition = string
                case let number as NSNumber: condition = number.stringValue
                case let other?:
                    OWELog.error(.scene, "SceneValueSource: unsupported user condition \(other)")
                    return nil
                }
                source = .user(name: name, condition: condition, fallback: source)
            } else {
                OWELog.error(.scene, "SceneValueSource: unsupported 'user' binding \(raw)")
                return nil
            }
        }
        self = source
    }
}
