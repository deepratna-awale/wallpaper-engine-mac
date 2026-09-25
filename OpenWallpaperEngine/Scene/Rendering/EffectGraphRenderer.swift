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
    private var libraries: [String: (vertex: MTLFunction, fragment: MTLFunction)] = [:]
    private var pipelines: [String: MTLRenderPipelineState] = [:]
    private var failedVariants = Set<String>()
    /// Per layer: ping-pong pair and effect FBOs, reused across frames.
    private var targets: [String: MTLTexture] = [:]

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

    /// Drops per-layer targets, e.g. when the scene changes.
    func releaseTargets() { targets.removeAll() }

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

    /// Runs `effects` on `input` and returns the processed image, or nil if nothing rendered.
    func apply(_ effects: [SceneEffectPlan], to input: MTLTexture, layerID: String,
               context: Context, commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        let width = input.width
        let height = input.height
        guard let pingA = target("\(layerID)|A", width: width, height: height, format: .rgba8Unorm),
              let pingB = target("\(layerID)|B", width: width, height: height, format: .rgba8Unorm) else { return nil }
        var current = input
        var didRender = false
        for (effectIndex, effect) in effects.enumerated() {
            let previous = current
            var fbos: [String: MTLTexture] = [:]
            for fbo in effect.fbos {
                let size = Self.fboSize(fbo, width: width, height: height)
                fbos[fbo.name] = target("\(layerID)|\(effectIndex)|\(fbo.name)", width: size.x, height: size.y,
                                        format: Self.pixelFormat(fbo.format))
            }
            for pass in effect.passes {
                switch pass.command {
                case .copy(let source, let destination):
                    guard let from = fbos[source] ?? (source == "previous" ? previous : nil), let to = fbos[destination],
                          let blit = commandBuffer.makeBlitCommandEncoder() else { continue }
                    if from.width == to.width, from.height == to.height, from.pixelFormat == to.pixelFormat {
                        blit.copy(from: from, to: to)
                    }
                    blit.endEncoding()
                case .swap(let first, let second):
                    let a = fbos[first]
                    fbos[first] = fbos[second]
                    fbos[second] = a
                case .render:
                    guard let variant = pass.variant else { continue }
                    let output: MTLTexture
                    if let name = pass.target {
                        guard let fbo = fbos[name] else {
                            OWELog.error(.scene, "\(effect.file): pass targets undeclared FBO \(name)")
                            continue
                        }
                        output = fbo
                    } else {
                        output = current === pingA ? pingB : pingA
                    }
                    guard encode(pass, variant: variant, output: output, current: current, previous: previous,
                                 fbos: fbos, context: context, commandBuffer: commandBuffer) else { continue }
                    didRender = true
                    if pass.target == nil { current = output }
                }
            }
        }
        return didRender ? current : nil
    }

    // MARK: - Passes

    private func encode(_ pass: SceneEffectPassPlan, variant: TranslatedShaderVariant, output: MTLTexture,
                        current: MTLTexture, previous: MTLTexture, fbos: [String: MTLTexture],
                        context: Context, commandBuffer: MTLCommandBuffer) -> Bool {
        guard let pipeline = pipeline(for: pass, variant: variant, format: output.pixelFormat) else { return false }
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = output
        // Blended passes composite over what's already there; others overwrite every pixel.
        descriptor.colorAttachments[0].loadAction = Self.blendMode(pass.blending) == nil ? .dontCare : .load
        descriptor.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return false }
        defer { encoder.endEncoding() }
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
            let size = SIMD2<Float>(Float(texture.width), Float(texture.height))
            textureInfo[slot] = BuiltinTextureInfo(allocatedSize: size, contentSize: size, spriteRotation: nil,
                                                   spriteTranslation: nil, mipCount: texture.mipmapLevelCount)
        }

        if let layout = variant.uniforms, layout.size > 0 {
            var passContext = BuiltinPassContext(targetSize: SIMD2<Float>(Float(output.width), Float(output.height)))
            passContext.textures = textureInfo
            passContext.color = context.layerColor
            passContext.alpha = context.layerAlpha
            let values = pass.constants.values(in: context.values)
            var bytes = [UInt8](repeating: 0, count: layout.size)
            for member in layout.members.values {
                let components = values[member.name]?.components
                    ?? BuiltinUniforms.value(named: member.name, frame: context.frame, pass: passContext,
                                             arrayCount: member.count > 1 ? member.count : nil)
                guard let components else { continue }
                UniformWriter.write(components, member: member, into: &bytes)
            }
            bytes.withUnsafeBytes { raw in
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
        return true
    }

    private func pipeline(for pass: SceneEffectPassPlan, variant: TranslatedShaderVariant,
                          format: MTLPixelFormat) -> MTLRenderPipelineState? {
        let key = "\(pass.variantKey)|\(format.rawValue)|\(pass.blending)"
        if let pipeline = pipelines[key] { return pipeline }
        guard !failedVariants.contains(key) else { return nil }
        do {
            let functions = try self.functions(for: pass.variantKey, variant: variant)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = functions.vertex
            descriptor.fragmentFunction = functions.fragment
            descriptor.colorAttachments[0].pixelFormat = format
            if let blend = Self.blendMode(pass.blending) {
                let attachment = descriptor.colorAttachments[0]!
                attachment.isBlendingEnabled = true
                attachment.sourceRGBBlendFactor = blend.source
                attachment.sourceAlphaBlendFactor = blend.source
                attachment.destinationRGBBlendFactor = blend.destination
                attachment.destinationAlphaBlendFactor = blend.destination
            }
            descriptor.vertexDescriptor = Self.vertexDescriptor(for: functions.vertex)
            let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            pipelines[key] = pipeline
            return pipeline
        } catch {
            failedVariants.insert(key)
            OWELog.error(.shader, "Effect pipeline failed (\(pass.variantKey.prefix(12))): \(error)")
            return nil
        }
    }

    private func functions(for key: String, variant: TranslatedShaderVariant) throws -> (vertex: MTLFunction, fragment: MTLFunction) {
        if let cached = libraries[key] { return cached }
        let vertexLibrary = try device.makeLibrary(source: variant.vertexMSL, options: nil)
        let fragmentLibrary = try device.makeLibrary(source: variant.fragmentMSL, options: nil)
        guard let vertex = vertexLibrary.makeFunction(name: "main0"),
              let fragment = fragmentLibrary.makeFunction(name: "main0") else {
            throw ShaderCompilerError.failed(step: "metal", output: "entry point main0 missing")
        }
        libraries[key] = (vertex, fragment)
        return (vertex, fragment)
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
