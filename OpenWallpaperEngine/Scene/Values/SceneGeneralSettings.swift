import simd

extension WESceneGeneral {
    /// A bindable `general` field resolved against the user properties; nil when not authored.
    func value(_ field: SceneGeneralValueField, in context: SceneValueContext) -> ShaderValue? {
        guard let raw = values[field] else { return nil }
        if let source = raw.userBindingSource { return SceneValueResolver.resolve(source, in: context) }
        return raw.literalString.flatMap(ShaderValue.init(string:))
    }
}

/// WE's defaults for the `general` block when a scene doesn't author a field: the scene
/// settings constructor in `wallpaper64.exe` (0x140186f84…0x1401870e3), matched to the field
/// names through WE's property table (0x14019a…0x14019b2a0).
enum SceneGeneralDefaults {
    static let bloomStrength: Float = 2
    static let bloomThreshold: Float = 0.65
    static let bloomTint = SIMD3<Float>(repeating: 1)
    static let cameraShakeSpeed: Float = 3
    static let cameraShakeAmplitude: Float = 0.5
    static let cameraShakeRoughness: Float = 1
    static let cameraParallaxAmount: Float = 0.5
    static let cameraParallaxDelay: Float = 0.1
    static let cameraParallaxMouseInfluence: Float = 0.5
}

extension SceneBloomSettings {
    init(_ general: WESceneGeneral, in context: SceneValueContext) {
        let tint = general.bloomtint.map { $0.parseVector3() }
            .map { SIMD3<Float>(Float($0.0), Float($0.1), Float($0.2)) } ?? SceneGeneralDefaults.bloomTint
        self.init(enabled: (general.value(.bloom, in: context)?.float ?? 0) != 0,
                  strength: general.value(.bloomstrength, in: context)?.float ?? SceneGeneralDefaults.bloomStrength,
                  threshold: general.value(.bloomthreshold, in: context)?.float ?? SceneGeneralDefaults.bloomThreshold,
                  tint: tint)
    }
}

/// `general.camerashake*` and `general.cameraparallax*`, resolved against the user properties.
struct SceneCameraEffects: Equatable {
    var shake = false
    var shakeAmplitude = SceneGeneralDefaults.cameraShakeAmplitude
    var shakeSpeed = SceneGeneralDefaults.cameraShakeSpeed
    var shakeRoughness = SceneGeneralDefaults.cameraShakeRoughness
    var parallax = false
    var parallaxAmount = SceneGeneralDefaults.cameraParallaxAmount
    var parallaxDelay = SceneGeneralDefaults.cameraParallaxDelay
    var parallaxMouseInfluence = SceneGeneralDefaults.cameraParallaxMouseInfluence

    init() {}

    init(_ general: WESceneGeneral, in context: SceneValueContext) {
        func float(_ field: SceneGeneralValueField, _ fallback: Float) -> Float {
            general.value(field, in: context)?.float ?? fallback
        }
        shake = float(.camerashake, 0) != 0
        shakeAmplitude = float(.camerashakeamplitude, SceneGeneralDefaults.cameraShakeAmplitude)
        shakeSpeed = float(.camerashakespeed, SceneGeneralDefaults.cameraShakeSpeed)
        shakeRoughness = float(.camerashakeroughness, SceneGeneralDefaults.cameraShakeRoughness)
        parallax = float(.cameraparallax, 0) != 0
        parallaxAmount = float(.cameraparallaxamount, SceneGeneralDefaults.cameraParallaxAmount)
        parallaxDelay = float(.cameraparallaxdelay, SceneGeneralDefaults.cameraParallaxDelay)
        parallaxMouseInfluence = float(.cameraparallaxmouseinfluence, SceneGeneralDefaults.cameraParallaxMouseInfluence)
    }
}
