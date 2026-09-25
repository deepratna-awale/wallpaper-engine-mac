import simd

extension WESceneGeneral {
    /// A bindable `general` field resolved against the user properties; nil when not authored.
    func value(_ field: SceneGeneralValueField, in context: SceneValueContext) -> ShaderValue? {
        guard let raw = values[field] else { return nil }
        if let source = raw.userBindingSource { return SceneValueResolver.resolve(source, in: context) }
        return raw.literalString.flatMap(ShaderValue.init(string:))
    }
}

extension SceneBloomSettings {
    init(_ general: WESceneGeneral, in context: SceneValueContext) {
        let tint = (general.bloomtint ?? "1 1 1").parseVector3()
        self.init(enabled: (general.value(.bloom, in: context)?.float ?? 0) != 0,
                  strength: general.value(.bloomstrength, in: context)?.float ?? 1,
                  threshold: general.value(.bloomthreshold, in: context)?.float ?? 0.7,
                  tint: SIMD3<Float>(Float(tint.0), Float(tint.1), Float(tint.2)))
    }
}

/// `general.camerashake*` and `general.cameraparallax*`, resolved against the user properties.
struct SceneCameraEffects: Equatable {
    var shake = false
    var shakeAmplitude: Float = 0
    var shakeSpeed: Float = 0
    var shakeRoughness: Float = 0
    var parallax = false
    var parallaxAmount: Float = 0
    var parallaxDelay: Float = 0
    var parallaxMouseInfluence: Float = 0

    init() {}

    init(_ general: WESceneGeneral, in context: SceneValueContext) {
        func float(_ field: SceneGeneralValueField, _ fallback: Float) -> Float {
            general.value(field, in: context)?.float ?? fallback
        }
        shake = float(.camerashake, 0) != 0
        shakeAmplitude = float(.camerashakeamplitude, 0)
        shakeSpeed = float(.camerashakespeed, 0)
        shakeRoughness = float(.camerashakeroughness, 0)
        parallax = float(.cameraparallax, 0) != 0
        parallaxAmount = float(.cameraparallaxamount, 0)
        parallaxDelay = float(.cameraparallaxdelay, 0)
        parallaxMouseInfluence = float(.cameraparallaxmouseinfluence, 0)
    }
}
