import Foundation
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

    init() {}

    init(_ settings: GlobalSettings) {
        postProcessing = settings.postProcessing
        reflection = settings.reflections
        shadows = settings.shadows
        volumetrics = settings.volumetrics
        particleBudget = settings.particleBudget
        renderResolution = settings.renderResolution
        sceneDetail = settings.sceneDetail
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
