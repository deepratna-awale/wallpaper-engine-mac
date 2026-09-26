import Metal
import simd

/// What a stage gets once the scene pass has ended.
struct SceneFrameStageContext {
    /// The finished scene target: every object, effect and particle drawn.
    var scene: MTLTexture
    var commandBuffer: MTLCommandBuffer
    /// The scene's size in scene units.
    var sceneSize: SIMD2<Float>
    /// This frame's built-in inputs, the lighting (`BuiltinFrameContext.lighting`) included.
    var frame: BuiltinFrameContext
    var settings: SceneRenderSettings
}

/// Work WE does on the finished frame before its bloom (docs/lighting-plan.md §2.6 "Frame
/// order", step 4, and the volumetrics' combine of §2.8): it reads or adds to the scene target.
/// `SceneMetalRenderer` runs its stages in order between the scene pass and `ScenePostProcess`.
protocol SceneFrameStage: AnyObject {
    func encode(_ context: SceneFrameStageContext)
    /// The content changed (a new scene or a rebuild): drop state that belonged to the old one.
    func setContent(_ content: SceneMetalContent)
}

enum SceneFrameStages {
    /// The stages of a renderer, in WE's order: the `_rt_MipMappedFrameBuffer` copy, then the
    /// volumetrics. None exists yet.
    static func make(device: MTLDevice) -> [SceneFrameStage] {
        []
    }
}
