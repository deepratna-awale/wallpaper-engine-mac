import Foundation
import Metal
import simd

/// The user's quality settings that change how WE draws a scene (`wallpaper64.exe` 0x14010ed80;
/// docs/lighting-plan.md §2.2, §2.6), and the app's particle budget (`ParticleBudget`). The app hands them to each wallpaper instance: the view model
/// (for what is decided at load, like HDR and the engine combos) and the renderer (per frame).
struct SceneRenderSettings: Equatable {
    var postProcessing = GSPostProcessingQuality.enabled
    var reflection = true
    var shadows = GSLightingQuality.medium
    var volumetrics = GSLightingQuality.medium
    /// The most particles a scene may hold (`ParticleBudget`); the content is built for it.
    var particleBudget = GSParticleBudget.medium
    /// WE's texture reduction (`TextureReduction`), 1 or 2: the user's setting resolved for the
    /// displays showing the scene (`init(_:outputPixels:)`). Textures load for it.
    var textureReduction = 1
    /// The scene target's pixels per display point.
    var renderResolution = GSRenderResolution.native
    /// Draw as WE does (`full`, what a settings-less renderer does) or no more than the display shows.
    var sceneDetail = GSSceneDetail.full
    /// WE's `msaa`: the scene pass's samples per pixel.
    var antiAliasing = GSAntiAliasingQuality.none

    init() {}

    init(_ settings: GlobalSettings) {
        postProcessing = settings.postProcessing
        reflection = settings.reflections
        shadows = settings.shadows
        volumetrics = settings.volumetrics
        particleBudget = settings.particleBudget
        renderResolution = settings.renderResolution
        sceneDetail = settings.sceneDetail
        antiAliasing = settings.antiAliasing
    }

    /// The scene pass's sample count on `device`: the setting's, or the most below it the GPU
    /// supports (1 always is).
    func sceneSampleCount(on device: MTLDevice) -> Int {
        var count = antiAliasing.sampleCount
        while count > 1, !device.supportsTextureSampleCount(count) { count /= 2 }
        return max(count, 1)
    }

    /// Whether a layer's `brightness` scales its colour. WE multiplies the colour it draws a layer
    /// with by `brightness` only under engine flag 0x2000 (`0x140207a2b…0x140207a72`, and
    /// likewise at `0x140207bd2` and `0x1402086e1`), which the `ultra` and `displayhdr`
    /// post-processing settings set (`0x14010e6ba`, `0x14010e6da`); otherwise it uses 1.
    var appliesBrightness: Bool {
        postProcessing == .ultra || postProcessing == .displayhdr
    }

    /// `settings` with the texture reduction WE's `resolution` setting gives on displays whose
    /// largest drawable is `outputPixels` (zero while none is known).
    init(_ settings: GlobalSettings, outputPixels: SIMD2<Float>) {
        self.init(settings)
        textureReduction = TextureReduction.factor(settings.textureResolution, outputPixels: outputPixels)
    }
}

extension GSPostProcessingQuality {
    /// Render flag 0x40: bloom can run (0x14010edab).
    var allowsBloom: Bool { self != .disabled }
    /// A scene with `bloom` and `hdr` draws in HDR (0x14010e612…0x14010e6da).
    var allowsHDR: Bool { self == .ultra || self == .displayhdr }
}
