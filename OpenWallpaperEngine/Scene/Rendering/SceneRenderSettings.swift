import Foundation

/// The user's quality settings that change how WE draws a scene (`wallpaper64.exe` 0x14010ed80;
/// docs/lighting-plan.md §2.2, §2.6). The app hands them to each wallpaper instance: the view model
/// (for what is decided at load, like HDR and the engine combos) and the renderer (per frame).
struct SceneRenderSettings: Equatable {
    var postProcessing = GSPostProcessingQuality.enabled
    var reflection = true
    var shadows = GSLightingQuality.medium
    var volumetrics = GSLightingQuality.medium

    init() {}

    init(_ settings: GlobalSettings) {
        postProcessing = settings.postProcessing
        reflection = settings.reflections
        shadows = settings.shadows
        volumetrics = settings.volumetrics
    }
}

extension GSPostProcessingQuality {
    /// Render flag 0x40: bloom can run (0x14010edab).
    var allowsBloom: Bool { self != .disabled }
    /// A scene with `bloom` and `hdr` draws in HDR (0x14010e612…0x14010e6da).
    var allowsHDR: Bool { self == .ultra || self == .displayhdr }
}
