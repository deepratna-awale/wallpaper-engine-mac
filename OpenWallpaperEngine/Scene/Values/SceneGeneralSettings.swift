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
    /// HDR bloom (0x1401870c2…0x1401870ee); `bloomhdriterations` is an int.
    static let bloomHDRStrength: Float = 2
    static let bloomHDRThreshold: Float = 1
    static let bloomHDRFeather: Float = 0.1
    static let bloomHDRScatter: Float = 1.619
    static let bloomHDRIterations = 8
    /// The constructor zeroes both colours (0x140186f68…0x140186f7d). Every library scene authors
    /// them (mostly 0.3 grey), so the zero is rarely seen.
    static let ambientColor = SIMD3<Float>(repeating: 0)
    static let skylightColor = SIMD3<Float>(repeating: 0)
}

/// `general.hdr` and `bloomhdr*`, resolved against the user properties. WE turns HDR on at load
/// only when `bloom` and `hdr` are both true and the user's post-processing setting allows it
/// (docs/lighting-plan.md §2.6).
struct SceneHDRBloomSettings: Equatable {
    var enabled = false
    var strength = SceneGeneralDefaults.bloomHDRStrength
    var threshold = SceneGeneralDefaults.bloomHDRThreshold
    var feather = SceneGeneralDefaults.bloomHDRFeather
    var scatter = SceneGeneralDefaults.bloomHDRScatter
    var iterations = SceneGeneralDefaults.bloomHDRIterations

    init() {}

    init(_ general: WESceneGeneral, in context: SceneValueContext) {
        func float(_ field: SceneGeneralValueField, _ fallback: Float) -> Float {
            general.value(field, in: context)?.float ?? fallback
        }
        enabled = float(.hdr, 0) != 0
        strength = float(.bloomhdrstrength, SceneGeneralDefaults.bloomHDRStrength)
        threshold = float(.bloomhdrthreshold, SceneGeneralDefaults.bloomHDRThreshold)
        feather = float(.bloomhdrfeather, SceneGeneralDefaults.bloomHDRFeather)
        scatter = float(.bloomhdrscatter, SceneGeneralDefaults.bloomHDRScatter)
        let authoredIterations = float(.bloomhdriterations, Float(SceneGeneralDefaults.bloomHDRIterations))
        iterations = authoredIterations.isFinite ? Int(authoredIterations) : SceneGeneralDefaults.bloomHDRIterations
    }
}

/// `general.ambientcolor`, `skylightcolor` and `lightconfig`, resolved against the user
/// properties: the scene-wide lighting inputs (docs/lighting-plan.md §1.2, §2.2).
struct SceneLightingSettings: Equatable {
    var ambient = SceneGeneralDefaults.ambientColor
    var skylight = SceneGeneralDefaults.skylightColor
    /// The light budget; nil packs no new-style light.
    var lightConfig: WELightConfig?

    init() {}

    init(_ general: WESceneGeneral, in context: SceneValueContext) {
        ambient = general.value(.ambientcolor, in: context)?.vec3 ?? SceneGeneralDefaults.ambientColor
        skylight = general.value(.skylightcolor, in: context)?.vec3 ?? SceneGeneralDefaults.skylightColor
        lightConfig = general.lightconfig
    }
}

extension SceneBloomSettings {
    init(_ general: WESceneGeneral, in context: SceneValueContext) {
        let tint = general.bloomtint.map { $0.parseVector3() }
            .map { SIMD3<Float>(Float($0.0), Float($0.1), Float($0.2)) } ?? SceneGeneralDefaults.bloomTint
        self.init(enabled: (general.value(.bloom, in: context)?.float ?? 0) != 0,
                  strength: general.value(.bloomstrength, in: context)?.float ?? SceneGeneralDefaults.bloomStrength,
                  threshold: general.value(.bloomthreshold, in: context)?.float ?? SceneGeneralDefaults.bloomThreshold,
                  tint: tint, hdr: SceneHDRBloomSettings(general, in: context))
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
    /// False for a perspective scene (`orthogonalprojection: null`). WE displaces objects for
    /// parallax only in an orthographic scene, and scales its shake by the projection height.
    var orthographic = true

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
        orthographic = !general.usesPerspectiveProjection
    }
}
