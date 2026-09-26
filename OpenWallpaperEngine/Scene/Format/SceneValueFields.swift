import Foundation

/// Value-bearing fields of a scene object that WE lets authors bind to a user property, a script
/// or an animation. The raw forms are kept in `WESceneObject.values`.
enum SceneObjectValueField: String, CaseIterable {
    case origin, scale, angles, color, alpha, brightness, size, pointsize
}

/// Value-bearing fields of `general` in scene.json. The raw forms are kept in `WESceneGeneral.values`.
enum SceneGeneralValueField: String, CaseIterable {
    case bloom, bloomstrength, bloomthreshold, clearcolor
    case camerashake, camerashakeamplitude, camerashakespeed, camerashakeroughness
    case cameraparallax, cameraparallaxamount, cameraparallaxdelay, cameraparallaxmouseinfluence
    case ambientcolor, skylightcolor
}

/// Fields of a particle object's `instanceoverride`. Each multiplies (or, for colours, replaces)
/// the emitter/initializer value of the particle file.
enum SceneInstanceOverrideField: String, CaseIterable {
    case alpha, brightness, color, colorn, count, lifetime, rate, size, speed
    /// Positions of the system's control points 0…7 (`ParticleControlPoint`).
    case controlpoint0, controlpoint1, controlpoint2, controlpoint3
    case controlpoint4, controlpoint5, controlpoint6, controlpoint7

    /// `controlpoint<n>` for control point `id` (0…7).
    static func controlPoint(_ id: Int) -> SceneInstanceOverrideField? {
        SceneInstanceOverrideField(rawValue: "controlpoint\(id)")
    }
}

extension SceneRawValue {
    /// The literal (authored `value`) part as WE text: `"1 0.5 0"`, `"0.5"`, `"true"`.
    /// Bindings are ignored; a missing `value` is nil.
    var literalString: String? {
        switch self {
        case .number(let n): return SceneJSON.number(n).scalarString
        case .bool(let b): return b ? "true" : "false"
        case .string(let s): return s
        case .object(let object): return object.value?.literalString
        }
    }

    /// The literal part as a number (`true` is 1). Nil when there is none or it isn't numeric.
    var literalDouble: Double? {
        switch self {
        case .number(let n): return n
        case .bool(let b): return b ? 1 : 0
        case .string(let s): return Double(s.trimmingCharacters(in: .whitespacesAndNewlines))
        case .object(let object): return object.value?.literalDouble
        }
    }

    /// The literal part as a flag. Numbers are true when non-zero; strings "true"/"1".
    var literalBool: Bool? {
        switch self {
        case .bool(let b): return b
        case .number(let n): return n != 0
        case .string(let s): return ["true", "1"].contains(s.lowercased())
        case .object(let object): return object.value?.literalBool
        }
    }

    /// The user property this value is bound to, if any.
    var userPropertyName: String? {
        if case .object(let object) = self { return object.userName }
        return nil
    }

    /// The script this value is driven by, if any.
    var scriptSource: String? {
        if case .object(let object) = self { return object.script }
        return nil
    }
}
