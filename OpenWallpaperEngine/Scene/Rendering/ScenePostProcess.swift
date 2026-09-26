import Metal
import simd

/// What follows the scene pass, once per frame (docs/lighting-plan.md §2.6 "Frame order", steps
/// 3–8): WE copies the frame to `_rt_FullFrameBuffer`, runs its bloom (LDR or HDR) and combine,
/// then colour correction and the camera fade, and presents.
///
/// Here the finished scene target is `_rt_FullFrameBuffer` (it isn't drawn to again). Step 5 is
/// WE's LDR bloom (`SceneBloomChain`), gated like WE's by the scene's live `bloom` and the user's
/// post-processing setting. The composite then puts the frame on the drawable at the user's
/// placement with the app's own adjustments (`AppExtras`), which aren't WE's.
final class ScenePostProcess {
    /// The scene's bloom this frame, scripts' and timelines' values included.
    struct Bloom: Equatable {
        var enabled: Bool
        var strength: Float
        var threshold: Float
        var tint: SIMD3<Float>
        var hdr = SceneHDRBloomSettings()
    }

    /// The app's own adjustments, not WE's (the `_owe_bloom`, `_owe_saturation`, `_owe_hue` and
    /// `_owe_blur` user properties); these defaults change nothing.
    struct AppExtras: Equatable {
        /// Multiplies WE's bloom strength; 1 is WE's bloom. A scene without bloom has none to scale.
        var bloom: Float = 1
        var saturation: Float = 1
        var hue: Float = 0
        var blur: Float = 1
    }

    struct Frame {
        /// The finished scene target (`_rt_FullFrameBuffer`).
        var scene: MTLTexture
        /// The drawable's pass.
        var output: MTLRenderPassDescriptor
        var commandBuffer: MTLCommandBuffer
        /// The scene's quad on the drawable at the user's placement, as `sceneVertex` reads it.
        var placement: LayerUniform
        var bloom: Bloom
        var extras: AppExtras
        var settings: SceneRenderSettings
        /// Runs WE's post-processing passes; nil puts the frame on the drawable without them.
        var effects: EffectGraphRenderer?
        /// This frame's built-in inputs and bound values, for those passes.
        var builtins = BuiltinFrameContext()
        var values: SceneValueContext = LiveSceneValueContext()
    }

    /// One frame's bloom: what went in, what came out and the constants of pass 1.
    struct BloomRecord {
        var frame: MTLTexture
        var bloomed: MTLTexture
        var strength: Float
        var threshold: Float
        var tint: SIMD3<Float>
    }

    /// The last frame's bloom, nil when it didn't run (tests, diagnostics).
    private(set) var lastBloom: BloomRecord?

    private let compositePipeline: MTLRenderPipelineState
    /// The content's LDR bloom chain; nil without a shader toolchain.
    private var bloomChain: SceneBloomChain?
    /// Frames bloomed so far: the chain's input changes every frame while its texture stays.
    private var bloomFrames: UInt64 = 0
    /// The effect graph holds the chain's targets (released when bloom stops).
    private var holdsBloomTargets = false
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

    /// A new content (a new scene or a rebuild).
    func setContent(_ content: SceneMetalContent) {
        bloomChain = content.bloomChain
    }

    /// Encodes everything from the scene target to the drawable. The caller presents and commits.
    func encode(_ frame: Frame) {
        // Step 5. B2: in HDR the HDR chain and its combine take this place.
        let finished = bloomed(frame) ?? frame.scene
        // Steps 6–7, WE's colour correction (`ccsimple`) and camera fade, would follow here; the
        // app draws neither yet.
        composite(finished, frame)
    }

    /// Whether WE runs its bloom this frame (`0x140180a41`): the post-processing setting allows it
    /// (render flag 0x40) and the scene's live `bloom` is on.
    static func runsBloom(_ bloom: Bloom, settings: SceneRenderSettings) -> Bool {
        settings.postProcessing.allowsBloom && bloom.enabled
    }

    /// `g_BloomStrength`: the scene's, scaled by the app's bloom slider (1 = WE's).
    static func bloomStrength(_ bloom: Bloom, extras: AppExtras) -> Float {
        bloom.strength * max(extras.bloom, 0)
    }

    /// The frame with WE's LDR bloom; nil when bloom doesn't run or its passes aren't ready.
    private func bloomed(_ frame: Frame) -> MTLTexture? {
        lastBloom = nil
        guard let effects = frame.effects else { return nil }
        guard Self.runsBloom(frame.bloom, settings: frame.settings), let bloomChain else {
            if holdsBloomTargets {
                effects.releaseLayer(SceneBloomChain.stateID)
                holdsBloomTargets = false
            }
            return nil
        }
        holdsBloomTargets = true
        bloomFrames &+= 1
        let strength = Self.bloomStrength(frame.bloom, extras: frame.extras)
        guard let bloomed = bloomChain.encode(on: frame.scene, strength: strength, threshold: frame.bloom.threshold,
                                              tint: frame.bloom.tint, effects: effects, builtins: frame.builtins,
                                              values: frame.values, frameIndex: bloomFrames,
                                              commandBuffer: frame.commandBuffer) else { return nil }
        lastBloom = BloomRecord(frame: frame.scene, bloomed: bloomed, strength: strength,
                                threshold: frame.bloom.threshold, tint: frame.bloom.tint)
        return bloomed
    }

    /// Step 8: `finished` on the drawable at the user's placement, with the app's adjustments.
    private func composite(_ finished: MTLTexture, _ frame: Frame) {
        guard let encoder = frame.commandBuffer.makeRenderCommandEncoder(descriptor: frame.output) else {
            if !reportedEncodeFailure {
                OWELog.error(.scene, "The scene composite pass can't be encoded; the drawable keeps its last frame")
                reportedEncodeFailure = true
            }
            return
        }
        encoder.setRenderPipelineState(compositePipeline)
        var uniform = Self.compositeUniform(frame.placement, extras: frame.extras)
        encoder.setVertexBytes(&uniform, length: MemoryLayout<LayerUniform>.stride, index: 0)
        encoder.setFragmentBytes(&uniform, length: MemoryLayout<LayerUniform>.stride, index: 0)
        encoder.setFragmentTexture(finished, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }

    /// The composite's uniform: `placement` with the app's adjustments.
    static func compositeUniform(_ placement: LayerUniform, extras: AppExtras) -> LayerUniform {
        var uniform = placement
        // The app's saturation and hue are linear in colour, so on the composite they equal applying
        // them to every layer, and layers keep drawing through their WE materials.
        uniform.effects = SIMD4<Float>(1, 1, extras.saturation, 0)
        uniform.colorEffects.z = extras.hue
        // "_owe_blur" defaults to 1 (no extra blur); raising it above 1 blurs the whole composited scene,
        // independent of any per-layer material blur, so the slider is guaranteed to have an effect.
        uniform.blur = max(extras.blur - 1, 0) * 4
        return uniform
    }
}
