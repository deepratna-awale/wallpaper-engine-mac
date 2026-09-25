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

    /// Per layer: ping-pong pair and effect FBOs, reused across frames.
    private var targets: [String: MTLTexture] = [:]
    /// Per layer and pass: uniform bytes with the static values already written.
    private var programs: [String: UniformProgram] = [:]
    /// Per layer: last output of a chain that doesn't change over time, and what produced it.
    private var staticOutputs: [String: (input: ObjectIdentifier, output: MTLTexture)] = [:]

    /// Counters for tests and diagnostics.
    private(set) var passesEncoded = 0
    private(set) var layersReused = 0
    var failedPipelineCount: Int { pipelineLock.withLock { failedPipelines.count } }

    static let positionBuffer = 30
    static let texCoordBuffer = 29
    static let zeroBuffer = 28

    init?(device: MTLDevice) {
        self.device = device
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
        targets.removeAll()
        programs.removeAll()
        staticOutputs.removeAll()
    }

    struct Context {
        let frame: BuiltinFrameContext
        let values: SceneValueContext
        /// Texture for an asset input, materialised by the renderer.
        let assetTexture: (String, SceneMetalTextureSource) -> MTLTexture?
        /// The scene rendered so far, if a pass needs `_rt_FullFrameBuffer`.
        let sceneSnapshot: MTLTexture?
        let layerColor: SIMD3<Float>
        let layerAlpha: Float
    }

    /// Runs `effects` on `input` and returns the processed image, or nil when nothing rendered —
    /// including while the chain's pipelines are still compiling (the layer then draws plain).
    func apply(_ effects: [SceneEffectPlan], to input: MTLTexture, layerID: String,
               context: Context, commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        let width = input.width
        let height = input.height
        guard let formats = readyFormats(effects, width: width, height: height) else { return nil }

        let inputID = ObjectIdentifier(input)
        if let cached = staticOutputs[layerID], cached.input == inputID {
            layersReused += 1
            return cached.output
        }

        guard let pingA = target("\(layerID)|A", width: width, height: height, format: .rgba8Unorm),
              let pingB = target("\(layerID)|B", width: width, height: height, format: .rgba8Unorm) else { return nil }
        var current = input
        var didRender = false
        var isStatic = true
        for (effectIndex, effect) in effects.enumerated() {
            let previous = current
            var fbos: [String: MTLTexture] = [:]
            for fbo in effect.fbos {
                let size = Self.fboSize(fbo, width: width, height: height)
                fbos[fbo.name] = target("\(layerID)|\(effectIndex)|\(fbo.name)", width: size.x, height: size.y,
                                        format: Self.pixelFormat(fbo.format))
            }
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
                    guard let variant = pass.variant else { continue }
                    let output: MTLTexture
                    if let name = pass.target {
                        guard let fbo = fbos[name] else { continue }
                        output = fbo
                    } else {
                        output = current === pingA ? pingB : pingA
                    }
                    let format = formats["\(effectIndex)|\(passIndex)"] ?? output.pixelFormat
                    guard let pipeline = readyPipeline(pass, format: format) else { continue }
                    let program = self.program("\(layerID)|\(effectIndex)|\(passIndex)", pass: pass, variant: variant)
                    isStatic = isStatic && program.isStatic && !pass.textures.values.contains {
                        if case .sceneSnapshot = $0 { return true } else { return false }
                    }
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
        if isStatic {
            staticOutputs[layerID] = (inputID, current)
        } else {
            staticOutputs[layerID] = nil
        }
        return current
    }

    // MARK: - Pipelines

    /// Target format of every render pass, or nil while any pipeline is still compiling.
    /// Compiles are started here; a pipeline that failed to build just skips its pass.
    private func readyFormats(_ effects: [SceneEffectPlan], width: Int, height: Int) -> [String: MTLPixelFormat]? {
        var formats: [String: MTLPixelFormat] = [:]
        var ready = true
        for (effectIndex, effect) in effects.enumerated() {
            let fboFormats = Dictionary(effect.fbos.map { ($0.name, Self.pixelFormat($0.format)) }, uniquingKeysWith: { a, _ in a })
            for (passIndex, pass) in effect.passes.enumerated() {
                guard case .render = pass.command, let variant = pass.variant else { continue }
                let format = pass.target.flatMap { fboFormats[$0] } ?? .rgba8Unorm
                formats["\(effectIndex)|\(passIndex)"] = format
                let key = Self.pipelineKey(pass, format: format)
                let state: (ready: Bool, failed: Bool, pending: Bool) = pipelineLock.withLock {
                    (pipelines[key] != nil, failedPipelines.contains(key), pendingPipelines.contains(key))
                }
                if state.ready || state.failed { continue }
                ready = false
                if !state.pending { compile(pass, variant: variant, format: format, key: key) }
            }
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
                result = try device.makeRenderPipelineState(descriptor: descriptor)
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

    /// Blocks until every pipeline these effects need has compiled or failed (tests, prewarming).
    func waitUntilReady(_ effects: [SceneEffectPlan], width: Int, height: Int, timeout: TimeInterval = 60) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while readyFormats(effects, width: width, height: height) == nil {
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
            var sampler = clampSampler
            switch input {
            case .current: texture = current
            case .previous: texture = previous
            case .fbo(let name): texture = fbos[name]
            case .sceneSnapshot: texture = context.sceneSnapshot
            case .asset(let key, let source):
                texture = context.assetTexture(key, source)
                sampler = repeatSampler
            }
            guard let texture else { continue }
            encoder.setFragmentTexture(texture, index: slot)
            encoder.setFragmentSamplerState(sampler, index: slot)
            encoder.setVertexTexture(texture, index: slot)
            encoder.setVertexSamplerState(sampler, index: slot)
            if program.needsTextureInfo {
                let size = SIMD2<Float>(Float(texture.width), Float(texture.height))
                textureInfo[slot] = BuiltinTextureInfo(allocatedSize: size, contentSize: size, spriteRotation: nil,
                                                       spriteTranslation: nil, mipCount: texture.mipmapLevelCount)
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

    private func program(_ key: String, pass: SceneEffectPassPlan, variant: TranslatedShaderVariant) -> UniformProgram {
        if let existing = programs[key] { return existing }
        let program = UniformProgram(layout: variant.uniforms, constants: pass.constants)
        programs[key] = program
        return program
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

    private func target(_ key: String, width: Int, height: Int, format: MTLPixelFormat) -> MTLTexture? {
        if let existing = targets[key], existing.width == width, existing.height == height,
           existing.pixelFormat == format { return existing }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: max(width, 1),
                                                                  height: max(height, 1), mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let texture = device.makeTexture(descriptor: descriptor)
        targets[key] = texture
        return texture
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
    private let builtins: [UniformMember]

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
        self.builtins = builtins
        needsTextureInfo = builtins.contains { $0.name.hasPrefix("g_Texture") }
        isStatic = dynamic.isEmpty && !builtins.contains {
            Self.timeVarying.contains($0.name) || $0.name.hasPrefix("g_AudioSpectrum")
        }
    }

    func update(frame: BuiltinFrameContext, pass: BuiltinPassContext, values: SceneValueContext) {
        for (member, constant) in dynamic {
            let value = ShaderConstantResolver.shape(SceneValueResolver.resolve(constant.source, in: values),
                                                     count: constant.count, isInt: constant.isInt)
            UniformWriter.write(value.components, member: member, into: &bytes)
        }
        for member in builtins {
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
            withUnsafeBytes(of: isInteger ? UInt32(bitPattern: Int32(value.rounded())) : value.bitPattern) { raw in
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
