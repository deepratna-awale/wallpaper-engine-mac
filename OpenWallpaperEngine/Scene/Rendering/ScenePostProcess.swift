import Metal
import simd

/// What follows the scene pass, once per frame (docs/lighting-plan.md §2.6 "Frame order", steps
/// 3–8): WE copies the frame to `_rt_FullFrameBuffer`, runs its bloom (LDR or HDR) and combine,
/// then colour correction and the camera fade, and presents.
///
/// Here the finished scene target is `_rt_FullFrameBuffer` (it isn't drawn to again). Step 5 is
/// WE's LDR bloom (`SceneBloomChain`), gated like WE's by the scene's live `bloom` and the user's
/// post-processing setting; in a content drawn in HDR it is the HDR chain (`SceneHDRChain`), or
/// `combine_srgb` while bloom doesn't run. The composite then puts the frame on the drawable at
/// the user's placement with the app's own adjustments (`AppExtras`), which aren't WE's.
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

    /// One HDR frame's combine: the float frame, the sRGB output, the levels the bloom ran (nil
    /// for `combine_srgb` alone) and its constants.
    struct HDRRecord {
        var frame: MTLTexture
        var combined: MTLTexture
        var levels: Int?
        var constants: SceneHDRChain.Constants
    }

    /// The last HDR frame's combine, nil when the content isn't drawn in HDR or it didn't run.
    private(set) var lastHDR: HDRRecord?

    private let compositePipeline: MTLRenderPipelineState
    /// The content's LDR bloom chain; nil without a shader toolchain.
    private var bloomChain: SceneBloomChain?
    /// The content's HDR chain, when it draws in HDR (`SceneMetalContent.hdrChain`).
    private var hdrChain: SceneHDRChain?
    /// The content draws in HDR: float targets, `HDR=1`, the HDR chain (`SceneEngineCombos.hdr`).
    private(set) var drawsHDR = false
    /// Frames bloomed so far: the chain's input changes every frame while its texture stays.
    private var bloomFrames: UInt64 = 0
    /// The chain whose targets the effect graph holds (released when it stops running).
    private var heldChain: String?
    /// The HDR combine's output as the composite reads it (`SceneHDRChain.encodedView`), by output.
    private var encodedView: (output: ObjectIdentifier, view: MTLTexture)?
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
        hdrChain = content.hdrChain
        drawsHDR = content.engineCombos.hdr
    }

    /// Encodes everything from the scene target to the drawable. The caller presents and commits.
    func encode(_ frame: Frame) {
        // Step 5: the bloom and its combine.
        let finished = (drawsHDR ? combinedHDR(frame) : bloomed(frame)) ?? frame.scene
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

    /// Makes `chain` (a state id, nil for none) the one whose targets the effect graph holds.
    private func hold(_ chain: String?, in effects: EffectGraphRenderer) {
        guard heldChain != chain else { return }
        if let heldChain { effects.releaseLayer(heldChain) }
        heldChain = chain
    }

    /// The frame with WE's LDR bloom; nil when bloom doesn't run or its passes aren't ready.
    private func bloomed(_ frame: Frame) -> MTLTexture? {
        lastBloom = nil
        lastHDR = nil
        guard let effects = frame.effects else { return nil }
        guard Self.runsBloom(frame.bloom, settings: frame.settings), let bloomChain else {
            hold(nil, in: effects)
            return nil
        }
        hold(SceneBloomChain.stateID, in: effects)
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

    /// The levels WE's HDR bloom runs on `frame` this frame, or nil when bloom doesn't run and
    /// the frame takes `combine_srgb` (`0x140180a41`, `0x140184058`).
    static func hdrLevels(_ frame: Frame) -> Int? {
        guard runsBloom(frame.bloom, settings: frame.settings) else { return nil }
        return SceneHDRChain.runLevels(width: frame.scene.width, height: frame.scene.height,
                                       iterations: frame.bloom.hdr.iterations)
    }

    /// A HDR frame through WE's HDR bloom and combine, or `combine_srgb` while bloom doesn't run, as
    /// the composite reads it; nil when the passes aren't ready (the frame is composited as it is).
    private func combinedHDR(_ frame: Frame) -> MTLTexture? {
        lastBloom = nil
        lastHDR = nil
        guard let effects = frame.effects else { return nil }
        guard let hdrChain else {
            hold(nil, in: effects)
            return nil
        }
        hold(SceneHDRChain.stateID, in: effects)
        bloomFrames &+= 1
        let levels = Self.hdrLevels(frame)
        let constants = SceneHDRChain.Constants(frame.bloom.hdr, levels: levels ?? 1, tint: frame.bloom.tint,
                                                strengthScale: max(frame.extras.bloom, 0))
        guard let combined = hdrChain.encode(on: frame.scene, levels: levels, constants: constants, effects: effects,
                                             builtins: frame.builtins, values: frame.values, frameIndex: bloomFrames,
                                             commandBuffer: frame.commandBuffer) else { return nil }
        lastHDR = HDRRecord(frame: frame.scene, combined: combined, levels: levels, constants: constants)
        if encodedView?.output != ObjectIdentifier(combined) {
            encodedView = SceneHDRChain.encodedView(of: combined).map { (ObjectIdentifier(combined), $0) }
        }
        return encodedView?.view
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
