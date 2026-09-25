import Foundation
import QuartzCore

/// What `SceneValueResolver` needs from the running scene to resolve bound values.
protocol SceneValueContext {
    /// The user property's current value as WE stores it ("1", "0.5 0.2 1", "true", a combo value),
    /// or nil when the wallpaper has no such property.
    func userProperty(_ name: String) -> String?
    /// Runs a value script with `current` as its input. Nil means the script produced no usable value.
    func evaluateScript(_ source: String, properties: SceneScriptProperties, current: ShaderValue) -> ShaderValue?
    /// Seconds since the scene started (drives `animation` values).
    var time: Double { get }
}

/// `SceneValueContext` over the app's existing script engine.
///
/// Note: `AudioReactiveScriptEngine.evaluate*` has no `scriptproperties` input yet, so
/// `properties` is not forwarded; scripts see their declared defaults.
struct LiveSceneValueContext: SceneValueContext {
    let engine: AudioReactiveScriptEngine
    let time: Double
    /// Clock passed to the script engine (it defaults to `CACurrentMediaTime()`).
    let scriptTime: Double
    let layerId: String?
    /// The wallpaper whose user properties to read; nil reads the wallpaper being rendered.
    let wallpaper: String?

    init(engine: AudioReactiveScriptEngine = .shared, time: Double,
         scriptTime: Double = CACurrentMediaTime(), layerId: String? = nil, wallpaper: String? = nil) {
        self.engine = engine
        self.time = time
        self.scriptTime = scriptTime
        self.layerId = layerId
        self.wallpaper = wallpaper
    }

    /// Reads outside a frame (`wallpaper` set) are the stored value; reads while rendering follow
    /// the music like the engine's numeric reads do.
    func userProperty(_ name: String) -> String? {
        if let wallpaper { return engine.userPropertyString(name, wallpaper: wallpaper) }
        guard let raw = engine.userPropertyString(name) else { return nil }
        return Self.musicSynced(raw, name: name, isSynced: engine.isMusicSynced,
                                modulate: { engine.userPropertyValue($0, fallback: $1) })
    }

    /// Applies music sync to a numeric property string. A scalar syncs under `<name>`, each vector
    /// component `i` under `<name>_<i>`; `modulate(key, base)` is the engine's numeric path
    /// (base + level × `<key>_musicAmount`). Non-numeric and unsynced values pass through.
    static func musicSynced(_ raw: String, name: String, isSynced: (String) -> Bool,
                            modulate: (String, Float) -> Float) -> String {
        guard let value = ShaderValue(string: raw) else { return raw }
        let components = value.components
        if components.count == 1 {
            guard isSynced(name) else { return raw }
            return String(modulate(name, components[0]))
        }
        var changed = false
        let modulated = components.enumerated().map { index, component -> Float in
            let key = "\(name)_\(index)"
            guard isSynced(key) else { return component }
            changed = true
            return modulate(key, component)
        }
        return changed ? modulated.map { String($0) }.joined(separator: " ") : raw
    }

    func evaluateScript(_ source: String, properties: SceneScriptProperties, current: ShaderValue) -> ShaderValue? {
        switch current.components.count {
        case 0, 1:
            let fallback = current.float
            return ShaderValue(engine.evaluate(source, fallback: fallback, layerId: layerId, time: scriptTime))
        case 2:
            guard let v = engine.evaluateVector2(source, fallback: current.vec2, layerId: layerId, time: scriptTime) else { return nil }
            return ShaderValue(components: [v.x, v.y])
        default:
            guard let v = engine.evaluateVector3(source, fallback: current.vec3, layerId: layerId, time: scriptTime) else { return nil }
            // The engine has no vec4 path; keep any components past z from the current value.
            return ShaderValue(components: [v.x, v.y, v.z] + current.components.dropFirst(3))
        }
    }
}
