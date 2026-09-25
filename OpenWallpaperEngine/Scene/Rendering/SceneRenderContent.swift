import Cocoa
import MetalKit
import CryptoKit

enum SceneMetalTextureSource {
    case image(NSImage)
    case dxt(TEXCompressedTexture)
    case animated(TEXAnimatedImages)
    /// Frames arrive from AVFoundation each frame rather than being decoded up front.
    case video(VideoTextureStream)
}

struct SceneMetalEffect {
    let name: String
    let constants: [String: [Float]]
    let mask: SceneMetalTextureSource?
    let scripts: [String: String]
    /// Per-parameter user-property keys, one per component. Sampled every frame so music sync
    /// reacts live rather than being frozen at content-build time.
    var overrideKeys: [String: [String]] = [:]
    /// The image a blend effect composites over the layer, with the Photoshop-style mode it uses.
    var blend: SceneMetalTextureSource? = nil
    var blendMode: Int = 0
}

struct SceneMetalLayer {
    let id: String
    let name: String
    let source: SceneMetalTextureSource
    let position: SIMD2<Float>
    let size: SIMD2<Float>
    let scale: SIMD2<Float>
    let scaleScript: String?
    let scaleAnimation: WEVectorKeyframeAnimation?
    let opacity: Float
    let opacityScript: String?
    let opacityAnimation: WEKeyframeAnimation?
    let brightness: Float
    let brightnessScript: String?
    let color: SIMD4<Float>
    let colorScript: String?
    let text: SceneMetalText?
    let parallaxDepth: SIMD3<Float>
    let perspective: Bool
    let positionScript: String?
    let positionScriptProperties: [String: String]
    let positionAnimation: WEVectorKeyframeAnimation?
    let sizeScript: String?
    let sizeAnimation: WEVectorKeyframeAnimation?
    let rotation: Float
    let rotationScript: String?
    let rotationAnimation: WEVectorKeyframeAnimation?
    let effects: SceneMaterialEffects
    let sceneEffects: [SceneMetalEffect]
    let xraySource: SceneMetalTextureSource?
    /// Set for video layers so the picture can pulse with the music the way the AVKit path does.
    var musicSync: VideoMusicSyncVisuals? = nil
}

/// Audio-reactive transforms applied to a video layer each frame.
struct VideoMusicSyncVisuals {
    let zoomAmount: Float
    let tiltAmount: Float
    let saturationAmount: Float
    /// Supplied by the video stream so sync can follow the wallpaper's own soundtrack rather than
    /// the system-wide capture, which cannot tell the two apart.
    var levelSource: (() -> Double)? = nil
}

struct SceneMetalText {
    let value: String
    let script: String?
    let scriptProperties: [String: String]
    let font: String?
    let pointSize: CGFloat
    let horizontalAlignment: String?
    let verticalAlignment: String?
    /// Inset from the layer's own bounds; every authored text object declares one.
    let padding: SIMD2<Float>
    let maxWidth: Float?
    let maxRows: Int?
    let useEllipsis: Bool
    let clock: SceneClock?
}

struct SceneClock {
    enum Kind { case time, date, countdown }
    let kind: Kind
    let use24HourFormat: Bool
    let showSeconds: Bool
    let delimiter: String
    let targetDate: String?
    let recurring: Bool
    let finalMessage: String?
}

struct SceneMaterialEffects {
    let brightness: Float
    let contrast: Float
    let saturation: Float
    let bloom: Float
    let blur: Float
    let exposure: Float
    let gamma: Float
    let hue: Float
    let bloomThreshold: Float
    let transformAngle: Float
    let transformOffset: SIMD2<Float>
    let transformScale: SIMD2<Float>
    let scripts: [String: String]
}

struct SceneBloomSettings {
    let enabled: Bool
    let strength: Float
    let threshold: Float
    let tint: SIMD3<Float>
}

struct SceneMetalContent {
    let size: SIMD2<Float>
    let layers: [SceneMetalLayer]
    let particleSystems: [SceneMetalParticleSystem]
    let sceneScript: String?
    let effects: Set<String>
    let bloom: SceneBloomSettings
    let dynamicEffects: SceneDynamicEffectCatalog
}
