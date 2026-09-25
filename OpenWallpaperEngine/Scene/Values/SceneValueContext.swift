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

    init(engine: AudioReactiveScriptEngine = .shared, time: Double,
         scriptTime: Double = CACurrentMediaTime(), layerId: String? = nil) {
        self.engine = engine
        self.time = time
        self.scriptTime = scriptTime
        self.layerId = layerId
    }

    func userProperty(_ name: String) -> String? {
        engine.userPropertyString(name)
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
