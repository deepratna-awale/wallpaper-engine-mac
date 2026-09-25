import Metal
import simd

/// Draws particle systems through their Wallpaper Engine material: WE's `genericparticle` /
/// `genericropeparticle` shaders (or a workshop shader in their place) with the material's
/// blending, combos, textures and constants. One instanced draw per system: each record
/// (`ParticleVertexFormat`) is one instance, expanded on the GPU by the emulated geometry
/// stage (`GeometryShaderEmulation`) or WE's no-geometry-shader stream (`ParticleQuadExpansion`).
///
/// A system whose material has no usable stage yet (pipeline compiling) or at all (failed, or
/// needing a feature not supported here) keeps the renderer's built-in particle draw; a failure
/// is logged once per system.
final class ParticleMaterialRenderer {
    /// Vertex buffer slots; buffer 0 is the `WEUniforms` block.
    static let recordBuffer = 30
    static let zeroBuffer = 28

    private let device: MTLDevice
    private let zeroAttributes: MTLBuffer
    /// By `.tex` flags that pick a sampler (`clampUVs`, `noInterpolation`).
    private var samplers: [UInt32: MTLSamplerState] = [:]

    /// Pipelines compile off the render thread. Guarded by `pipelineLock`.
    private let compileQueue = DispatchQueue(label: "owe.particle-pipelines", qos: .userInitiated, attributes: .concurrent)
    private let pipelineLock = NSLock()
    private var pipelines: [String: MTLRenderPipelineState] = [:]
    private var pendingPipelines = Set<String>()
    private var failedPipelines: [String: String] = [:]

    /// Per system, render thread only.
    private var systems: [ObjectIdentifier: SystemState] = [:]

    private final class SystemState {
        weak var owner: ParticleSystemRuntime?
        let records: ParticleRecordBuffer
        var programs: [String: UniformProgram] = [:]
        /// This frame's draw, set by `prepare`.
        var prepared: (stage: ParticleMaterialPlan.Stage, pipeline: MTLRenderPipelineState, buffer: MTLBuffer?, count: Int)?
        var reportedFallback = false

        init(owner: ParticleSystemRuntime, device: MTLDevice) {
            self.owner = owner
            records = ParticleRecordBuffer(device: device)
        }
    }

    /// Counters for tests and diagnostics.
    private(set) var drawsEncoded = 0

    init?(device: MTLDevice) {
        self.device = device
        guard let zero = device.makeBuffer(length: 64) else { return nil }
        zeroAttributes = zero
    }

    /// WE's sampler for a texture: clamp with `clampUVs`, else repeat; nearest with
    /// `noInterpolation`, else bilinear.
    private func sampler(for flags: TEXFlags) -> MTLSamplerState? {
        let key = flags.intersection([.clampUVs, .noInterpolation]).rawValue
        if let sampler = samplers[key] { return sampler }
        let descriptor = MTLSamplerDescriptor()
        let filter: MTLSamplerMinMagFilter = flags.contains(.noInterpolation) ? .nearest : .linear
        descriptor.minFilter = filter
        descriptor.magFilter = filter
        descriptor.mipFilter = flags.contains(.noInterpolation) ? .nearest : .linear
        let address: MTLSamplerAddressMode = flags.contains(.clampUVs) ? .clampToEdge : .repeat
        descriptor.sAddressMode = address
        descriptor.tAddressMode = address
        let sampler = device.makeSamplerState(descriptor: descriptor)
        samplers[key] = sampler
        return sampler
    }

    /// Forgets every system (the scene changed). Compiled pipelines are kept.
    func releaseAll() {
        systems.removeAll()
    }

    // MARK: - Frame

    /// Picks `system`'s stage and writes its records for this frame. False means the system
    /// can't draw through its material now; the caller draws it the built-in way.
    func prepare(_ system: ParticleSystemRuntime, pixelFormat: MTLPixelFormat,
                 opacity: (Particle) -> Float) -> Bool {
        guard let plan = system.configuration.material else { return false }
        let state = state(for: system)
        state.prepared = nil
        guard let ready = readyStage(plan, pixelFormat: pixelFormat, state: state) else { return false }
        let count = ParticleRecordWriter.recordCount(system, format: plan.format)
        var buffer: MTLBuffer?
        if count > 0 {
            guard let next = state.records.next(bytes: count * plan.format.stride) else { return false }
            ParticleRecordWriter.write(system, format: plan.format, count: count, into: next.contents(), opacity: opacity)
            buffer = next
        }
        state.prepared = (ready.stage, ready.pipeline, buffer, count)
        return true
    }

    struct DrawContext {
        let sceneSize: SIMD2<Float>
        let frame: BuiltinFrameContext
        let values: SceneValueContext
        /// Texture for an asset input, materialised by the renderer.
        let assetTexture: (String, SceneMetalTextureSource) -> MTLTexture?
    }

    /// Encodes the draw `prepare` set up for `system` this frame.
    func draw(_ system: ParticleSystemRuntime, encoder: MTLRenderCommandEncoder, context: DrawContext) {
        guard let plan = system.configuration.material,
              let state = systems[ObjectIdentifier(system)], state.owner === system,
              let prepared = state.prepared else { return }
        state.prepared = nil
        guard prepared.count > 0, let buffer = prepared.buffer else { return }
        let stage = prepared.stage
        encoder.setRenderPipelineState(prepared.pipeline)
        encoder.setVertexBuffer(buffer, offset: 0, index: Self.recordBuffer)
        encoder.setVertexBuffer(zeroAttributes, offset: 0, index: Self.zeroBuffer)

        var textures: [Int: BuiltinTextureInfo] = [:]
        for slot in stage.variant.textureSlots {
            // Texture 0 is the one the system already loaded.
            guard case .asset(let key, let source)? = stage.textures[slot],
                  let texture = slot == 0 ? system.texture : context.assetTexture(key, source) else { continue }
            let sampler = sampler(for: plan.textureFlags[slot] ?? [])
            encoder.setFragmentTexture(texture, index: slot)
            encoder.setFragmentSamplerState(sampler, index: slot)
            encoder.setVertexTexture(texture, index: slot)
            encoder.setVertexSamplerState(sampler, index: slot)
            textures[slot] = EffectGraphRenderer.textureInfo(for: texture, contentSize: source.contentSize)
        }

        let program = state.programs[stage.variantKey] ?? {
            let program = UniformProgram(layout: stage.variant.uniforms, constants: stage.constants)
            state.programs[stage.variantKey] = program
            return program
        }()
        if program.size > 0, let layout = stage.variant.uniforms {
            let uniforms = ParticleMaterialUniforms(plan: plan, system: system, sceneSize: context.sceneSize,
                                                    texture0: textures[0])
            var pass = BuiltinPassContext(targetSize: context.sceneSize)
            pass.modelViewProjection = uniforms.modelViewProjection
            pass.textures = textures
            pass.renderVars = uniforms.renderVars
            program.update(frame: uniforms.frame(from: context.frame), pass: pass, values: context.values)
            var bytes = program.bytes
            uniforms.patch(&bytes, layout: layout)
            bytes.withUnsafeBytes { raw in
                if raw.count <= 4096 {
                    encoder.setVertexBytes(raw.baseAddress!, length: raw.count, index: 0)
                    encoder.setFragmentBytes(raw.baseAddress!, length: raw.count, index: 0)
                } else if let uniformBuffer = device.makeBuffer(bytes: raw.baseAddress!, length: raw.count) {
                    encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 0)
                    encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
                }
            }
        }
        let vertexCount: Int
        switch stage.geometry {
        case .emulated(let count): vertexCount = count
        case .expandedQuads: vertexCount = ParticleQuadExpansion.verticesPerInstance
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount, instanceCount: prepared.count)
        drawsEncoded += 1
    }

    // MARK: - Stages and pipelines

    private func state(for system: ParticleSystemRuntime) -> SystemState {
        let id = ObjectIdentifier(system)
        if let state = systems[id], state.owner === system { return state }
        let state = SystemState(owner: system, device: device)
        systems[id] = state
        return state
    }

    /// The first stage with a built pipeline. Nil while an earlier stage is still compiling, or
    /// when every stage failed (logged once).
    private func readyStage(_ plan: ParticleMaterialPlan, pixelFormat: MTLPixelFormat,
                            state: SystemState) -> (stage: ParticleMaterialPlan.Stage, pipeline: MTLRenderPipelineState)? {
        var reasons: [String] = []
        for stage in plan.stages {
            if stage.readsSceneSnapshot {
                reasons.append("\(stage.geometry): reads _rt_FullFrameBuffer (refraction), not supported for particles yet")
                continue
            }
            let key = Self.pipelineKey(stage, plan: plan, pixelFormat: pixelFormat)
            let status: (pipeline: MTLRenderPipelineState?, pending: Bool, failure: String?) = pipelineLock.withLock {
                (pipelines[key], pendingPipelines.contains(key), failedPipelines[key])
            }
            if let pipeline = status.pipeline { return (stage, pipeline) }
            if status.pending { return nil }
            if let failure = status.failure {
                reasons.append("\(stage.geometry): \(failure)")
                continue
            }
            compile(stage, plan: plan, pixelFormat: pixelFormat, key: key)
            return nil
        }
        if !state.reportedFallback {
            state.reportedFallback = true
            OWELog.error(.scene, "Particle material \(plan.materialPath) (\(plan.shader)) can't render; "
                         + "using the built-in particle draw: \(reasons.joined(separator: "; "))")
        }
        return nil
    }

    private static func pipelineKey(_ stage: ParticleMaterialPlan.Stage, plan: ParticleMaterialPlan,
                                     pixelFormat: MTLPixelFormat) -> String {
        "\(stage.variantKey)|\(plan.format)|\(plan.blending)|\(pixelFormat.rawValue)"
    }

    private func compile(_ stage: ParticleMaterialPlan.Stage, plan: ParticleMaterialPlan,
                         pixelFormat: MTLPixelFormat, key: String) {
        pipelineLock.withLock { _ = pendingPipelines.insert(key) }
        let device = self.device
        let format = plan.format
        let blending = plan.blending
        compileQueue.async { [weak self] in
            var failure: String?
            var pipeline: MTLRenderPipelineState?
            do {
                pipeline = try Self.makePipeline(stage, format: format, blending: blending,
                                                 pixelFormat: pixelFormat, device: device)
            } catch {
                failure = "\(error)"
                OWELog.error(.shader, "Particle pipeline failed (\(plan.materialPath), \(stage.geometry)): \(error)")
            }
            guard let self else { return }
            self.pipelineLock.withLock {
                self.pendingPipelines.remove(key)
                if let pipeline { self.pipelines[key] = pipeline } else { self.failedPipelines[key] = failure ?? "unknown" }
            }
        }
    }

    /// Blocks until every stage of `plan` has a pipeline or failed (tests, prewarming).
    func waitUntilCompiled(_ plan: ParticleMaterialPlan, pixelFormat: MTLPixelFormat, timeout: TimeInterval = 60) -> Bool {
        let keys = plan.stages.map { Self.pipelineKey($0, plan: plan, pixelFormat: pixelFormat) }
        for (stage, key) in zip(plan.stages, keys) where !stage.readsSceneSnapshot {
            let known = pipelineLock.withLock { pipelines[key] != nil || pendingPipelines.contains(key) || failedPipelines[key] != nil }
            if !known { compile(stage, plan: plan, pixelFormat: pixelFormat, key: key) }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while pipelineLock.withLock({ keys.contains { pendingPipelines.contains($0) } }) {
            if Date() > deadline { return false }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return true
    }

    /// Failure reason of a stage's pipeline, for tests and diagnostics.
    func pipelineFailure(_ stage: ParticleMaterialPlan.Stage, plan: ParticleMaterialPlan, pixelFormat: MTLPixelFormat) -> String? {
        let key = Self.pipelineKey(stage, plan: plan, pixelFormat: pixelFormat)
        return pipelineLock.withLock { failedPipelines[key] }
    }

    static func makePipeline(_ stage: ParticleMaterialPlan.Stage, format: ParticleVertexFormat, blending: String,
                             pixelFormat: MTLPixelFormat, device: MTLDevice) throws -> MTLRenderPipelineState {
        let vertexLibrary = try device.makeLibrary(source: stage.variant.vertexMSL, options: nil)
        let fragmentLibrary = try device.makeLibrary(source: stage.variant.fragmentMSL, options: nil)
        guard let vertex = vertexLibrary.makeFunction(name: "main0"),
              let fragment = fragmentLibrary.makeFunction(name: "main0") else {
            throw ShaderCompilerError.failed(step: "metal", output: "entry point main0 missing")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        if let blend = EffectGraphRenderer.blendMode(blending) {
            let attachment = descriptor.colorAttachments[0]!
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = blend.source
            attachment.sourceAlphaBlendFactor = blend.source
            attachment.destinationRGBBlendFactor = blend.destination
            attachment.destinationAlphaBlendFactor = blend.destination
        }
        descriptor.vertexDescriptor = vertexDescriptor(for: vertex, attributes: stage.variant.attributes, format: format)
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// Every attribute the stage reads comes from the instance's record, stepping once per
    /// instance; one the format lacks reads zero.
    static func vertexDescriptor(for function: MTLFunction, attributes: [String: Int],
                                 format: ParticleVertexFormat) -> MTLVertexDescriptor {
        let descriptor = MTLVertexDescriptor()
        var usesZero = false
        var usesRecord = false
        for attribute in function.vertexAttributes ?? [] where attribute.isActive {
            let index = attribute.attributeIndex
            let element = descriptor.attributes[index]!
            let offset = attributes.filter { $0.value == index }.keys.sorted()
                .lazy.compactMap { format.recordOffset(ofAttribute: $0) }.first
            element.format = vertexFormat(attribute.attributeType)
            if let offset {
                element.offset = offset
                element.bufferIndex = recordBuffer
                usesRecord = true
            } else {
                element.offset = 0
                element.bufferIndex = zeroBuffer
                usesZero = true
            }
        }
        if usesRecord {
            descriptor.layouts[recordBuffer].stride = format.stride
            descriptor.layouts[recordBuffer].stepFunction = .perInstance
            descriptor.layouts[recordBuffer].stepRate = 1
        }
        if usesZero {
            descriptor.layouts[zeroBuffer].stride = 16
            descriptor.layouts[zeroBuffer].stepFunction = .constant
            descriptor.layouts[zeroBuffer].stepRate = 0
        }
        return descriptor
    }

    private static func vertexFormat(_ type: MTLDataType) -> MTLVertexFormat {
        switch type {
        case .float: return .float
        case .float2: return .float2
        case .float3: return .float3
        default: return .float4
        }
    }
}
