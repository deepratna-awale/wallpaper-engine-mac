import Metal
import simd

/// What follows the scene pass, once per frame (docs/lighting-plan.md §2.6 "Frame order", steps
/// 3–8): WE copies the frame to `_rt_FullFrameBuffer`, runs its bloom (LDR or HDR) and combine,
/// then colour correction and the camera fade, and presents.
///
/// For now this is the composite the renderer has always drawn: one pass that puts the scene
/// target on the drawable at the user's placement, with the bright-pass bloom of `sceneFragment`
/// and the app's saturation, hue and blur. The post-processing setting isn't consulted yet.
final class ScenePostProcess {
    /// The scene's bloom this frame, scripts' and timelines' values included.
    struct Bloom: Equatable {
        var enabled: Bool
        var strength: Float
        var threshold: Float
        var tint: SIMD3<Float>
        var hdr = SceneHDRBloomSettings()
    }

    /// The app's own adjustments (the `_owe_bloom`, `_owe_saturation`, `_owe_hue` and `_owe_blur`
    /// user properties); these defaults change nothing.
    struct AppExtras: Equatable {
        var bloom: Float = 1
        var saturation: Float = 1
        var hue: Float = 0
        var blur: Float = 1
    }

    struct Frame {
        /// The finished scene target.
        var scene: MTLTexture
        /// The drawable's pass.
        var output: MTLRenderPassDescriptor
        var commandBuffer: MTLCommandBuffer
        /// The scene's quad on the drawable at the user's placement, as `sceneVertex` reads it.
        var placement: LayerUniform
        var bloom: Bloom
        var extras: AppExtras
        var settings: SceneRenderSettings
    }

    private let compositePipeline: MTLRenderPipelineState
    /// The composite pass failed once already (it is logged once, not every frame).
    private var reportedEncodeFailure = false

    /// `layerDescriptor` is the scene's layer pipeline, whose functions and output format the
    /// composite shares. Nil when a pipeline can't be made.
    init?(device: MTLDevice, layerDescriptor: MTLRenderPipelineDescriptor) {
        do {
            compositePipeline = try device.makeRenderPipelineState(
                descriptor: SceneComposite.pipelineDescriptor(basedOn: layerDescriptor))
        } catch {
            OWELog.error(.scene, "The scene composite pipeline can't be made: \(error)")
            return nil
        }
    }

    /// Encodes everything from the scene target to the drawable. The caller presents and commits.
    func encode(_ frame: Frame) {
        guard let encoder = frame.commandBuffer.makeRenderCommandEncoder(descriptor: frame.output) else {
            if !reportedEncodeFailure {
                OWELog.error(.scene, "The scene composite pass can't be encoded; the drawable keeps its last frame")
                reportedEncodeFailure = true
            }
            return
        }
        encoder.setRenderPipelineState(compositePipeline)
        var uniform = Self.compositeUniform(frame.placement, bloom: frame.bloom, extras: frame.extras)
        encoder.setVertexBytes(&uniform, length: MemoryLayout<LayerUniform>.stride, index: 0)
        encoder.setFragmentBytes(&uniform, length: MemoryLayout<LayerUniform>.stride, index: 0)
        encoder.setFragmentTexture(frame.scene, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }

    /// The composite's uniform: `placement` with the bloom and the app's adjustments.
    static func compositeUniform(_ placement: LayerUniform, bloom: Bloom, extras: AppExtras) -> LayerUniform {
        var uniform = placement
        let authoredBloom = bloom.enabled ? bloom.strength * extras.bloom : 0
        let userBloom = max(extras.bloom - 1, 0) * 1.2
        let bloomStrength = max(authoredBloom, userBloom)
        // The app's saturation and hue are linear in colour, so on the composite they equal applying
        // them to every layer, and layers keep drawing through their WE materials.
        uniform.effects = SIMD4<Float>(1, 1, extras.saturation, max(bloomStrength, 0))
        uniform.colorEffects.z = extras.hue
        // The app's bloom slider (an app extra) on a scene without WE bloom uses WE's default threshold.
        uniform.colorEffects.w = bloom.enabled ? bloom.threshold : SceneGeneralDefaults.bloomThreshold
        uniform.bloomTint = SIMD4<Float>(bloom.tint, 1)
        // "_owe_blur" defaults to 1 (no extra blur); raising it above 1 blurs the whole composited scene,
        // independent of any per-layer material blur, so the slider is guaranteed to have an effect.
        uniform.blur = max(extras.blur - 1, 0) * 4
        return uniform
    }
}
