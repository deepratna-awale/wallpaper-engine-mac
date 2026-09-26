import simd

/// The scene camera for one frame (WE's ctx: view at +0x38, eye at +0x68, forward at +0x160):
/// what the draws of this frame see. `SceneMetalRenderer` builds it once per frame from its
/// `SceneCameraRig` and carries it on `BuiltinFrameContext.camera` (docs/models-plan.md § Seams).
struct SceneFrameCamera: Equatable {
    var view = matrix_identity_float4x4
    var projection = matrix_identity_float4x4
    /// `g_EyePosition`.
    var eye = SIMD3<Float>(0, 0, 1)
    /// The view direction (`g_ViewForward`; the light packer's and `transparentsorting`'s key).
    var forward = SIMD3<Float>(0, 0, -1)
    var up = SIMD3<Float>(0, 1, 0)
    /// The vertical fov in degrees, when the projection is a perspective one.
    var fieldOfView: Float?
    /// Depth runs 1 at near to 0 at far, cleared to 0, compared GREATER: WE's everywhere
    /// (§2.4). False while the scene pass has no depth buffer.
    var reversedDepth = false

    var viewProjection: simd_float4x4 { projection * view }
    var isPerspective: Bool { fieldOfView != nil }
}

/// What a rig gets each frame.
struct SceneCameraRigInput {
    /// The scene's size in scene units.
    var sceneSize: SIMD2<Float>
    /// The scene target's width over height (WE's projection aspect, R+0x84 / R+0x88).
    var aspect: Float
    /// Seconds since the scene started, and since the last frame.
    var time: Double
    var deltaTime: Float
}

/// Where a frame's camera comes from: WE's camera layers, the scene's camera paths, or the
/// `camera` block (§2.2 "View"). One rig lives per wallpaper instance and keeps its own
/// playback state (paths, queues, fades), so it is a class.
protocol SceneCameraRig: AnyObject {
    func frameCamera(_ input: SceneCameraRigInput) -> SceneFrameCamera
}

enum SceneCameraRigs {
    /// The rig for a content. Today every scene gets `SceneLayerPassCameraRig`, which reproduces
    /// the camera the renderer draws with; M2 returns WE's rig here for perspective scenes.
    static func make(for content: SceneMetalContent) -> any SceneCameraRig {
        SceneLayerPassCameraRig(camera: content.lighting.camera)
    }
}

/// Today's camera: layers are drawn in scene units through the layer pass's orthographic matrix
/// (`ImageMaterialRenderer.viewProjection(sceneSize:)`, as `projection` with an identity view),
/// and `g_EyePosition` and the forward come from the lighting's camera
/// (`SceneLightingContent.camera`).
final class SceneLayerPassCameraRig: SceneCameraRig {
    private let camera: SceneVolumetricsCamera

    init(camera: SceneVolumetricsCamera) {
        self.camera = camera
    }

    func frameCamera(_ input: SceneCameraRigInput) -> SceneFrameCamera {
        SceneFrameCamera(projection: ImageMaterialRenderer.viewProjection(sceneSize: input.sceneSize),
                         eye: camera.eye, forward: camera.forward, up: camera.up)
    }
}
