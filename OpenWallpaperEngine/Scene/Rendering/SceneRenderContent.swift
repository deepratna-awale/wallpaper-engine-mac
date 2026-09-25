import Cocoa
import MetalKit
import CryptoKit

enum SceneMetalTextureSource {
    case image(NSImage)
    case dxt(TEXCompressedTexture)
    case animated(TEXAnimatedImages)
    /// Frames arrive from AVFoundation each frame rather than being decoded up front.
    case video(VideoTextureStream)

    /// The image's own size in texels when it is smaller than the texture it is uploaded into
    /// (`g_TextureNResolution.zw`). Decoded images are already cropped to their content, so
    /// only block-compressed uploads, which keep the .tex padding, report one.
    var contentSize: SIMD2<Float>? {
        switch self {
        case let .dxt(texture):
            return SIMD2(Float(texture.contentWidth), Float(texture.contentHeight))
        case .image, .animated, .video:
            return nil
        }
    }
}

struct SceneMetalLayer {
    let id: String
    let name: String
    let source: SceneMetalTextureSource
    /// `origin`, relative to the parent object (see `SceneMetalContent.transforms`).
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
    /// Set for video layers so the picture can pulse with the music the way the AVKit path does.
    var musicSync: VideoMusicSyncVisuals? = nil
    /// Authored effects, run through Wallpaper Engine's own shaders.
    var weEffects: [SceneEffectPlan] = []
    /// Composition, fullscreen and project layers: the base image is the scene rendered so far
    /// under the layer (`_rt_FullFrameBuffer`), not a texture.
    var sceneInput = false
    /// Index of the object in scene.json: layers and particle systems draw in that order.
    var order = 0
    /// `alignment` (images) or the text block's aligned edge: where the quad sits against `position`.
    var alignment: String? = nil
    /// `fullscreen` models cover the scene whatever their parent is.
    var fillsScene = false
    /// User-bound transform/colour values, re-resolved each frame.
    var bindings = SceneLayerBindings()

    /// The renderer must interrupt the scene pass for this layer to give it the scene so far.
    var readsScene: Bool { sceneInput || weEffects.contains { $0.passes.contains(where: \.readsSceneSnapshot) } }
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
    /// Dynamic screen anchor. The scene is always drawn with its authored projection, so every
    /// anchor resolves to the authored position.
    let anchor: String?
    let blockAlign: Bool
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
    let bloom: SceneBloomSettings
    /// Every object's parent and authored transform; layer positions are relative to their parent.
    var transforms: SceneTransformHierarchy = .empty
    var camera = SceneCameraEffects()
    /// The wallpaper instance's key in the script engine's user-property store (its directory path).
    var wallpaperKey = ""
}
