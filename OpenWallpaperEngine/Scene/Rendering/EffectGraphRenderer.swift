import Metal
import simd

/// Runs WE effects on a layer's image with WE's own shaders.
///
/// Per layer: the input image is copied through the effect passes using two ping-pong targets at
/// the layer's size. A pass without a `target` renders the current image into the other ping-pong
/// buffer and becomes the current image (linux-wallpaperengine's per-pass swap); a pass with a
/// `target` renders into that effect FBO. `previous` is the effect's input. The result is the
/// processed image, which the scene pass then draws with the layer's transform and blending.
final class EffectGraphRenderer {
    private let device: MTLDevice
    private let quadPositions: MTLBuffer
    private let quadTexCoords: MTLBuffer
    private let zeroAttributes: MTLBuffer
    private let clampSampler: MTLSamplerState
    private let repeatSampler: MTLSamplerState

    /// Pipelines compile off the render thread: a cold Metal compile costs tens of milliseconds
    /// per variant, which would otherwise stall frames. Guarded by `pipelineLock`.
    private let compileQueue = DispatchQueue(label: "owe.effect-pipelines", qos: .userInitiated, attributes: .concurrent)
    private let pipelineLock = NSLock()
    private var pipelines: [String: MTLRenderPipelineState] = [:]
    private var pendingPipelines = Set<String>()
    private var failedPipelines = Set<String>()
    /// Backend binaries of compiled pipelines, persisted across launches; nil disables it.
    let pipelineArchive: EffectPipelineArchive?

    /// Per layer: targets, uniform programs and readiness, resolved once and reused every frame
    /// so the steady state does no string building or dictionary work per pass.
    private var layers: [String: LayerState] = [:]

    private final class LayerState {
        var width: Int
        var height: Int
        var formats: [[MTLPixelFormat?]] = []
        var ready = false
        /// Variant keys of the chain the programs were built for; a different chain rebuilds them.
        var chain: [[String]] = []
        var pingA: MTLTexture?
        var pingB: MTLTexture?
        var fbos: [[String: MTLTexture]] = []
        var programs: [[UniformProgram?]] = []
        /// Last output of a chain that doesn't change over time, and what produced it.
        var staticOutput: (key: StaticChainKey, output: MTLTexture)?

        init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
    }

    /// Everything a static chain's output depends on besides its plan. The input is held (not just
    /// its `ObjectIdentifier`, which can be reused once a texture is freed) and compared by identity.
    struct StaticChainKey {
        let input: MTLTexture
        let inputVersion: UInt64
        let color: SIMD3<Float>
        let alpha: Float

        func matches(_ other: StaticChainKey) -> Bool {
            input === other.input && inputVersion == other.inputVersion
                && color == other.color && alpha == other.alpha
        }
    }

    /// Targets a layer gave back when its size changed, by size and format. Layers whose size
    /// alternates (text on a clock) take them back instead of allocating new ones.
    private struct TargetKey: Hashable {
        let width: Int
        let height: Int
        let format: MTLPixelFormat
    }
    private var spareTargets: [TargetKey: [MTLTexture]] = [:]
    private var spareOrder: [TargetKey] = []
    /// Upper bound on spare textures kept; the oldest sizes go first.
    static let maxSpareTargets = 32

    /// Counters for tests and diagnostics.
    private(set) var passesEncoded = 0
    private(set) var layersReused = 0
    private(set) var targetsAllocated = 0
    var failedPipelineCount: Int { pipelineLock.withLock { failedPipelines.count } }

    static let positionBuffer = 30
    static let texCoordBuffer = 29
    static let zeroBuffer = 28

    /// `pipelineArchiveDirectory` holds the persisted pipeline archive; nil keeps none.
    init?(device: MTLDevice, pipelineArchiveDirectory: URL? = EffectPipelineArchive.defaultDirectory) {
        self.device = device
        pipelineArchive = pipelineArchiveDirectory.map { EffectPipelineArchive(device: device, directory: $0) }
        // Triangle strip over the full target; with the translator's GL-style y flip, texcoord
        // (0, 0) lands on the first row, so each pass maps its input 1:1.
        let positions: [Float] = [-1, -1, 0, 1, -1, 0, -1, 1, 0, 1, 1, 0]
        let texCoords: [Float] = [0, 0, 1, 0, 0, 1, 1, 1]
        guard let quadPositions = device.makeBuffer(bytes: positions, length: positions.count * 4),
              let quadTexCoords = device.makeBuffer(bytes: texCoords, length: texCoords.count * 4),
              let zeroAttributes = device.makeBuffer(length: 64) else { return nil }
        self.quadPositions = quadPositions
        self.quadTexCoords = quadTexCoords
        self.zeroAttributes = zeroAttributes
        func sampler(_ mode: MTLSamplerAddressMode) -> MTLSamplerState? {
            let descriptor = MTLSamplerDescriptor()
            descriptor.minFilter = .linear
            descriptor.magFilter = .linear
            descriptor.mipFilter = .linear
            descriptor.sAddressMode = mode
            descriptor.tAddressMode = mode
            return device.makeSamplerState(descriptor: descriptor)
        }
        guard let clamp = sampler(.clampToEdge), let wrap = sampler(.repeat) else { return nil }
        clampSampler = clamp
        repeatSampler = wrap
    }

    /// Drops per-layer state, e.g. when the scene changes. Compiled pipelines are kept.
    func releaseTargets() {
        layers.removeAll()
        spareTargets.removeAll()
        spareOrder.removeAll()
    }

    /// Frees one layer's state (e.g. a removed script clone). Its targets go to the spare list,
    /// which is safe while earlier command buffers still read them: later passes on the same
    /// queue are ordered after those reads. Pipelines are shared by variant, not owned by a
    /// layer, so a compile still in flight for this layer's chain just lands in the cache.
    /// Call on the render thread, like `apply`.
    func releaseLayer(_ stateId: String) {
        guard let state = layers.removeValue(forKey: stateId) else { return }
        recycleTargets(state)
    }

    /// Layers holding state, for tests and diagnostics.
    var layerStateCount: Int { layers.count }

    struct Context {
        let frame: BuiltinFrameContext
        let values: SceneValueContext
        /// Texture for an asset input, materialised by the renderer.
        let assetTexture: (String, SceneMetalTextureSource) -> MTLTexture?
        /// The scene rendered so far, if a pass needs `_rt_FullFrameBuffer`.
        let sceneSnapshot: MTLTexture?
        let layerColor: SIMD3<Float>
        let layerAlpha: Float
        /// Bump when `input`'s contents change while the texture object stays the same.
        var inputVersion: UInt64 = 0
        /// Image size inside a padded asset texture (the `.tex` width/height), when known; used
        /// for `g_TextureNResolution.zw`. nil means the whole texture is content.
        var assetContentSize: ((String, SceneMetalTextureSource) -> SIMD2<Float>?)? = nil
    }

    /// Runs `effects` on `input` and returns the processed image, or nil when nothing rendered —
    /// including while the chain's pipelines are still compiling (the layer then draws plain).
    func apply(_ effects: [SceneEffectPlan], to input: MTLTexture, layerID: String,
               context: Context, commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        let width = input.width
        let height = input.height
        let state: LayerState
        let chain = effects.map { $0.passes.map(\.variantKey) }
        if let existing = layers[layerID], existing.chain == chain {
            state = existing
        } else {
            if let stale = layers[layerID] { recycleTargets(stale) }
            state = LayerState(width: width, height: height)
            state.chain = chain
            layers[layerID] = state
        }
        if !state.ready {
            guard let formats = readyFormats(effects) else { return nil }
            state.formats = formats
            state.programs = effects.map { effect in
                effect.passes.map { pass in pass.variant.map { UniformProgram(layout: $0.uniforms, constants: pass.constants) } }
            }
            allocateTargets(state, effects: effects, width: width, height: height)
            state.ready = true
        } else if state.width != width || state.height != height {
            recycleTargets(state)
            allocateTargets(state, effects: effects, width: width, height: height)
        }

        let staticKey = StaticChainKey(input: input, inputVersion: context.inputVersion,
                                       color: context.layerColor, alpha: context.layerAlpha)
        // A scene snapshot keeps its texture identity while its contents change every frame.
        let readsScene = context.sceneSnapshot != nil
        if !readsScene, let cached = state.staticOutput, cached.key.matches(staticKey) {
            layersReused += 1
            return cached.output
        }
        guard let pingA = state.pingA, let pingB = state.pingB else { return nil }

        var current = input
        var didRender = false
        var isStatic = true
        for (effectIndex, effect) in effects.enumerated() {
            let previous = current
            var fbos = state.fbos[effectIndex]
            for (passIndex, pass) in effect.passes.enumerated() {
                switch pass.command {
                case .copy(let source, let destination):
                    guard let from = fbos[source] ?? (source == "previous" ? previous : nil), let to = fbos[destination],
                          from.width == to.width, from.height == to.height, from.pixelFormat == to.pixelFormat,
                          let blit = commandBuffer.makeBlitCommandEncoder() else { continue }
                    blit.copy(from: from, to: to)
                    blit.endEncoding()
                case .swap(let first, let second):
                    let a = fbos[first]
                    fbos[first] = fbos[second]
                    fbos[second] = a
                case .render:
                    guard let variant = pass.variant, let program = state.programs[effectIndex][passIndex],
                          let format = state.formats[effectIndex][passIndex],
                          let pipeline = readyPipeline(pass, format: format) else { continue }
                    let output: MTLTexture
                    if let name = pass.target {
                        guard let fbo = fbos[name] else { continue }
                        output = fbo
                    } else {
                        output = current === pingA ? pingB : pingA
                    }
                    isStatic = isStatic && program.isStatic && !pass.readsSceneSnapshot
                    encode(pass, pipeline: pipeline, program: program, variant: variant, output: output,
                           current: current, previous: previous, fbos: fbos, context: context,
                           commandBuffer: commandBuffer)
                    didRender = true
                    if pass.target == nil { current = output }
                }
            }
        }
        guard didRender else { return nil }
        // A chain with no time, audio, pointer or live-bound input produces the same image
        // every frame; skip it until the input changes (bandwidth is the main per-frame cost).
        state.staticOutput = isStatic && !readsScene ? (staticKey, current) : nil
        return current
    }

    // MARK: - Pipelines

    /// Target format of every render pass (per effect, per pass), or nil while any pipeline is
    /// still compiling. Compiles are started here; a pipeline that failed just skips its pass.
    private func readyFormats(_ effects: [SceneEffectPlan]) -> [[MTLPixelFormat?]]? {
        var formats: [[MTLPixelFormat?]] = []
        var ready = true
        for effect in effects {
            let fboFormats = Dictionary(effect.fbos.map { ($0.name, Self.pixelFormat($0.format)) }, uniquingKeysWith: { a, _ in a })
            var effectFormats: [MTLPixelFormat?] = []
            for pass in effect.passes {
                guard case .render = pass.command, let variant = pass.variant else {
                    effectFormats.append(nil)
                    continue
                }
                let format = pass.target.flatMap { fboFormats[$0] } ?? .rgba8Unorm
                effectFormats.append(format)
                let key = Self.pipelineKey(pass, format: format)
                let state: (ready: Bool, failed: Bool, pending: Bool) = pipelineLock.withLock {
                    (pipelines[key] != nil, failedPipelines.contains(key), pendingPipelines.contains(key))
                }
                if state.ready || state.failed { continue }
                ready = false
                if !state.pending { compile(pass, variant: variant, format: format, key: key) }
            }
            formats.append(effectFormats)
        }
        return ready ? formats : nil
    }

    private func readyPipeline(_ pass: SceneEffectPassPlan, format: MTLPixelFormat) -> MTLRenderPipelineState? {
        let key = Self.pipelineKey(pass, format: format)
        return pipelineLock.withLock { pipelines[key] }
    }

    private static func pipelineKey(_ pass: SceneEffectPassPlan, format: MTLPixelFormat) -> String {
        "\(pass.variantKey)|\(format.rawValue)|\(pass.blending)"
    }

    private func compile(_ pass: SceneEffectPassPlan, variant: TranslatedShaderVariant, format: MTLPixelFormat, key: String) {
        pipelineLock.withLock { _ = pendingPipelines.insert(key) }
        let device = self.device
        let blending = pass.blending
        let archive = pipelineArchive
        compileQueue.async { [weak self] in
            let result: MTLRenderPipelineState?
            do {
                let vertexLibrary = try device.makeLibrary(source: variant.vertexMSL, options: nil)
                let fragmentLibrary = try device.makeLibrary(source: variant.fragmentMSL, options: nil)
                guard let vertex = vertexLibrary.makeFunction(name: "main0"),
                      let fragment = fragmentLibrary.makeFunction(name: "main0") else {
                    throw ShaderCompilerError.failed(step: "metal", output: "entry point main0 missing")
                }
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = vertex
                descriptor.fragmentFunction = fragment
                descriptor.colorAttachments[0].pixelFormat = format
                if let blend = Self.blendMode(blending) {
                    let attachment = descriptor.colorAttachments[0]!
                    attachment.isBlendingEnabled = true
                    attachment.sourceRGBBlendFactor = blend.source
                    attachment.sourceAlphaBlendFactor = blend.source
                    attachment.destinationRGBBlendFactor = blend.destination
                    attachment.destinationAlphaBlendFactor = blend.destination
                }
                descriptor.vertexDescriptor = Self.vertexDescriptor(for: vertex)
                result = try Self.makePipeline(descriptor, device: device, archive: archive)
            } catch {
                OWELog.error(.shader, "Effect pipeline failed (\(key.prefix(12))): \(error)")
                result = nil
            }
            guard let self else { return }
            self.pipelineLock.withLock {
                self.pendingPipelines.remove(key)
                if let result { self.pipelines[key] = result } else { self.failedPipelines.insert(key) }
            }
        }
    }

    /// Takes the pipeline from the archive when it has it; otherwise compiles it and adds it.
    static func makePipeline(_ descriptor: MTLRenderPipelineDescriptor, device: MTLDevice,
                             archive: EffectPipelineArchive?) throws -> MTLRenderPipelineState {
        guard let archive else { return try device.makeRenderPipelineState(descriptor: descriptor) }
        descriptor.binaryArchives = archive.archives
        // Optional: a miss is the normal first-launch case and falls through to a full compile.
        if let hit = try? device.makeRenderPipelineState(descriptor: descriptor, options: [.failOnBinaryArchiveMiss]).0 {
            archive.recordHit()
            return hit
        }
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        archive.add(descriptor)
        return pipeline
    }

    /// Blocks until every pipeline these effects need has compiled or failed (tests, prewarming).
    func waitUntilReady(_ effects: [SceneEffectPlan], width: Int, height: Int, timeout: TimeInterval = 60) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while readyFormats(effects) == nil {
            if Date() > deadline { return false }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return true
    }

    // MARK: - Passes

    private func encode(_ pass: SceneEffectPassPlan, pipeline: MTLRenderPipelineState, program: UniformProgram,
                        variant: TranslatedShaderVariant, output: MTLTexture,
                        current: MTLTexture, previous: MTLTexture, fbos: [String: MTLTexture],
                        context: Context, commandBuffer: MTLCommandBuffer) {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = output
        // Blended passes composite over what's already there; others overwrite every pixel.
        descriptor.colorAttachments[0].loadAction = Self.blendMode(pass.blending) == nil ? .dontCare : .load
        descriptor.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        defer { encoder.endEncoding() }
        passesEncoded += 1
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(quadPositions, offset: 0, index: Self.positionBuffer)
        encoder.setVertexBuffer(quadTexCoords, offset: 0, index: Self.texCoordBuffer)
        encoder.setVertexBuffer(zeroAttributes, offset: 0, index: Self.zeroBuffer)

        var textureInfo: [Int: BuiltinTextureInfo] = [:]
        for slot in variant.textureSlots {
            guard let input = pass.textures[slot] else { continue }
            let texture: MTLTexture?
            var contentSize: SIMD2<Float>?
            var sampler = clampSampler
            switch input {
            case .current: texture = current
            case .previous: texture = previous
            case .fbo(let name): texture = fbos[name]
            case .sceneSnapshot: texture = context.sceneSnapshot
            case .asset(let key, let source):
                texture = context.assetTexture(key, source)
                contentSize = context.assetContentSize?(key, source)
                sampler = repeatSampler
            }
            guard let texture else { continue }
            encoder.setFragmentTexture(texture, index: slot)
            encoder.setFragmentSamplerState(sampler, index: slot)
            encoder.setVertexTexture(texture, index: slot)
            encoder.setVertexSamplerState(sampler, index: slot)
            if program.needsTextureInfo {
                textureInfo[slot] = Self.textureInfo(for: texture, contentSize: contentSize)
            }
        }

        if program.size > 0 {
            var passContext = BuiltinPassContext(targetSize: SIMD2<Float>(Float(output.width), Float(output.height)))
            passContext.textures = textureInfo
            passContext.color = context.layerColor
            passContext.alpha = context.layerAlpha
            program.update(frame: context.frame, pass: passContext, values: context.values)
            program.bytes.withUnsafeBytes { raw in
                if raw.count <= 4096 {
                    encoder.setVertexBytes(raw.baseAddress!, length: raw.count, index: 0)
                    encoder.setFragmentBytes(raw.baseAddress!, length: raw.count, index: 0)
                } else if let buffer = device.makeBuffer(bytes: raw.baseAddress!, length: raw.count) {
                    encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                    encoder.setFragmentBuffer(buffer, offset: 0, index: 0)
                }
            }
        }
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    /// Position and texcoord come from the quad; any other attribute a shader reads is zero.
    static func vertexDescriptor(for function: MTLFunction) -> MTLVertexDescriptor {
        let descriptor = MTLVertexDescriptor()
        for attribute in function.vertexAttributes ?? [] where attribute.isActive {
            let index = attribute.attributeIndex
            let element = descriptor.attributes[index]!
            element.offset = 0
            switch index {
            case 0:
                element.format = .float3
                element.bufferIndex = positionBuffer
            case 1:
                element.format = .float2
                element.bufferIndex = texCoordBuffer
            default:
                element.format = .float4
                element.bufferIndex = zeroBuffer
            }
        }
        // Only buffers some attribute reads may have a layout, or Metal rejects the descriptor.
        let used = Set((function.vertexAttributes ?? []).filter(\.isActive).map {
            descriptor.attributes[$0.attributeIndex]!.bufferIndex
        })
        if used.contains(positionBuffer) { descriptor.layouts[positionBuffer].stride = 12 }
        if used.contains(texCoordBuffer) { descriptor.layouts[texCoordBuffer].stride = 8 }
        if used.contains(zeroBuffer) {
            descriptor.layouts[zeroBuffer].stride = 16
            descriptor.layouts[zeroBuffer].stepFunction = .constant
            descriptor.layouts[zeroBuffer].stepRate = 0
        }
        return descriptor
    }

    // MARK: - Targets

    /// Built-in texture info: allocated size is the GPU texture, content size the image inside it
    /// (clamped to the allocation; the allocation when unknown).
    static func textureInfo(for texture: MTLTexture, contentSize: SIMD2<Float>?) -> BuiltinTextureInfo {
        let allocated = SIMD2<Float>(Float(texture.width), Float(texture.height))
        var content = allocated
        if let contentSize, contentSize.x > 0, contentSize.y > 0 {
            content = simd_min(contentSize, allocated)
        }
        return BuiltinTextureInfo(allocatedSize: allocated, contentSize: content, spriteRotation: nil,
                                  spriteTranslation: nil, mipCount: texture.mipmapLevelCount)
    }

    private func allocateTargets(_ state: LayerState, effects: [SceneEffectPlan], width: Int, height: Int) {
        state.width = width
        state.height = height
        state.staticOutput = nil
        state.pingA = target(width: width, height: height, format: .rgba8Unorm)
        state.pingB = target(width: width, height: height, format: .rgba8Unorm)
        state.fbos = effects.map { effect in
            Dictionary(effect.fbos.compactMap { fbo -> (String, MTLTexture)? in
                let size = Self.fboSize(fbo, width: width, height: height)
                return target(width: size.x, height: size.y, format: Self.pixelFormat(fbo.format)).map { (fbo.name, $0) }
            }, uniquingKeysWith: { a, _ in a })
        }
    }

    /// Hands a layer's targets to the spare list. Contents don't matter: every pass either
    /// overwrites its target or (blended) runs after one that did.
    private func recycleTargets(_ state: LayerState) {
        let owned = [state.pingA, state.pingB].compactMap { $0 } + state.fbos.flatMap(\.values)
        state.pingA = nil
        state.pingB = nil
        state.fbos = []
        state.staticOutput = nil
        for texture in owned {
            let key = TargetKey(width: texture.width, height: texture.height, format: texture.pixelFormat)
            spareTargets[key, default: []].append(texture)
            spareOrder.removeAll { $0 == key }
            spareOrder.append(key)
        }
        var count = spareTargets.values.reduce(0) { $0 + $1.count }
        while count > Self.maxSpareTargets, let oldest = spareOrder.first {
            count -= spareTargets[oldest]?.count ?? 0
            spareTargets[oldest] = nil
            spareOrder.removeFirst()
        }
    }

    private func target(width: Int, height: Int, format: MTLPixelFormat) -> MTLTexture? {
        let key = TargetKey(width: max(width, 1), height: max(height, 1), format: format)
        if var spares = spareTargets[key], let texture = spares.popLast() {
            spareTargets[key] = spares.isEmpty ? nil : spares
            if spares.isEmpty { spareOrder.removeAll { $0 == key } }
            return texture
        }
        targetsAllocated += 1
        return makeTarget(width: width, height: height, format: format)
    }

    private func makeTarget(width: Int, height: Int, format: MTLPixelFormat) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: max(width, 1),
                                                                  height: max(height, 1), mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }

    /// `scale` divides the layer size; `fit` bounds the larger side.
    static func fboSize(_ fbo: EffectFBO, width: Int, height: Int) -> SIMD2<Int> {
        var w = Double(width) / Double(max(fbo.scale, 1))
        var h = Double(height) / Double(max(fbo.scale, 1))
        if let fit = fbo.fit, fit > 0 {
            let factor = Double(fit) / max(w, h)
            w *= factor
            h *= factor
        }
        return SIMD2(max(Int(w.rounded()), 1), max(Int(h.rounded()), 1))
    }

    static func pixelFormat(_ format: String) -> MTLPixelFormat {
        switch format.lowercased() {
        case "r16f": return .r16Float
        case "rg1616f": return .rg16Float
        case "rgba16161616f", "rgba16f": return .rgba16Float
        case "r8": return .r8Unorm
        case "rg88": return .rg8Unorm
        default: return .rgba8Unorm
        }
    }

    /// WE material blending → blend factors; nil means no blending (overwrite).
    static func blendMode(_ blending: String) -> (source: MTLBlendFactor, destination: MTLBlendFactor)? {
        switch blending.lowercased() {
        case "translucent": return (.sourceAlpha, .oneMinusSourceAlpha)
        case "additive": return (.sourceAlpha, .one)
        default: return nil
        }
    }
}

/// A pass's `WEUniforms` bytes: static values written once, dynamic constants and live built-ins
/// patched each frame. Avoids per-frame dictionaries and allocations on the render thread.
final class UniformProgram {
    private(set) var bytes: [UInt8]
    let size: Int
    /// True when nothing changes between frames (no time/audio/pointer/live-bound value).
    let isStatic: Bool
    let needsTextureInfo: Bool
    private let dynamic: [(member: UniformMember, constant: ShaderConstantResolver.DynamicConstant)]
    /// Built-ins that only depend on the pass's targets and textures: written when those change.
    private let passBuiltins: [UniformMember]
    /// Built-ins that change every frame (time, pointer, audio).
    private let frameBuiltins: [UniformMember]
    private var passSignature: [Float] = []

    /// Built-ins whose value changes from frame to frame.
    static let timeVarying: Set<String> = ["g_Time", "g_Frametime", "g_Daytime", "g_DayTime", "g_PointerPosition",
                                           "g_PointerPositionLast", "g_PointerState", "g_ParallaxPosition"]

    init(layout: UniformLayout?, constants: ShaderConstantResolver.ResolvedConstants) {
        size = layout?.size ?? 0
        bytes = [UInt8](repeating: 0, count: size)
        let dynamicByName = Dictionary(constants.dynamic.map { ($0.uniform, $0) }, uniquingKeysWith: { a, _ in a })
        var dynamic: [(UniformMember, ShaderConstantResolver.DynamicConstant)] = []
        var builtins: [UniformMember] = []
        for member in (layout?.members.values).map(Array.init) ?? [] {
            if let constant = dynamicByName[member.name] {
                dynamic.append((member, constant))
            } else if let value = constants.staticValues[member.name] {
                UniformWriter.write(value.components, member: member, into: &bytes)
            } else if BuiltinUniforms.isBuiltin(member.name) {
                builtins.append(member)
            }
        }
        self.dynamic = dynamic
        let varies = { (member: UniformMember) in
            Self.timeVarying.contains(member.name) || member.name.hasPrefix("g_AudioSpectrum")
        }
        frameBuiltins = builtins.filter(varies)
        passBuiltins = builtins.filter { !varies($0) }
        needsTextureInfo = builtins.contains { $0.name.hasPrefix("g_Texture") }
        isStatic = dynamic.isEmpty && frameBuiltins.isEmpty
    }

    func update(frame: BuiltinFrameContext, pass: BuiltinPassContext, values: SceneValueContext) {
        for (member, constant) in dynamic {
            let value = ShaderConstantResolver.shape(SceneValueResolver.resolve(constant.source, in: values),
                                                     count: constant.count, isInt: constant.isInt)
            UniformWriter.write(value.components, member: member, into: &bytes)
        }
        write(frameBuiltins, frame: frame, pass: pass)
        // Name lookups are string work; do them only when the targets actually change.
        var signature: [Float] = [frame.screenSize.x, frame.screenSize.y, pass.targetSize.x, pass.targetSize.y, pass.alpha,
                                  pass.color.x, pass.color.y, pass.color.z]
        for slot in pass.textures.keys.sorted() {
            let info = pass.textures[slot]!
            signature += [Float(slot), info.allocatedSize.x, info.allocatedSize.y, info.contentSize.x, info.contentSize.y]
        }
        if signature != passSignature {
            passSignature = signature
            write(passBuiltins, frame: frame, pass: pass)
        }
    }

    private func write(_ members: [UniformMember], frame: BuiltinFrameContext, pass: BuiltinPassContext) {
        for member in members {
            if let components = BuiltinUniforms.value(named: member.name, frame: frame, pass: pass,
                                                      arrayCount: member.count > 1 ? member.count : nil) {
                UniformWriter.write(components, member: member, into: &bytes)
            }
        }
    }
}

/// Writes values into a std140 `WEUniforms` block as SPIRV-Cross laid it out.
enum UniformWriter {
    static func write(_ components: [Float], member: UniformMember, into bytes: inout [UInt8]) {
        let isInteger = member.type.hasPrefix("int") || member.type.hasPrefix("ivec")
            || member.type.hasPrefix("uint") || member.type.hasPrefix("uvec") || member.type == "bool"
        let perElement = componentsPerElement(member.type)
        let columns = matrixColumns(member.type)
        func put(_ value: Float, at offset: Int) {
            guard offset >= 0, offset + 4 <= bytes.count else { return }
            withUnsafeBytes(of: isInteger ? integerBits(value) : value.bitPattern) { raw in
                for (index, byte) in raw.enumerated() { bytes[offset + index] = byte }
            }
        }
        for element in 0..<member.count {
            let base = member.offset + element * member.arrayStride
            for component in 0..<perElement {
                let index = element * perElement + component
                guard index < components.count else { return }
                if let columns, member.matrixStride > 0 {
                    let rows = perElement / columns
                    put(components[index], at: base + (component / rows) * member.matrixStride + (component % rows) * 4)
                } else {
                    put(components[index], at: base + component * 4)
                }
            }
        }
    }

    /// Rounds to the nearest Int32, clamping out-of-range values; NaN becomes 0.
    static func integerBits(_ value: Float) -> UInt32 {
        guard !value.isNaN else { return 0 }
        let rounded = value.rounded()
        // Float(Int32.max) rounds up to 2^31, so compare against that, not the Int32.
        if rounded >= 2_147_483_648 { return UInt32(bitPattern: Int32.max) }
        if rounded <= -2_147_483_648 { return UInt32(bitPattern: Int32.min) }
        return UInt32(bitPattern: Int32(rounded))
    }

    static func componentsPerElement(_ type: String) -> Int {
        switch type {
        case "vec2", "ivec2", "uvec2": return 2
        case "vec3", "ivec3", "uvec3": return 3
        case "vec4", "ivec4", "uvec4": return 4
        case "mat2": return 4
        case "mat3": return 9
        case "mat4": return 16
        case "mat4x3": return 12
        case "mat3x4": return 12
        default: return 1
        }
    }

    static func matrixColumns(_ type: String) -> Int? {
        switch type {
        case "mat2": return 2
        case "mat3", "mat3x4": return 3
        case "mat4", "mat4x3": return 4
        default: return nil
        }
    }
}
