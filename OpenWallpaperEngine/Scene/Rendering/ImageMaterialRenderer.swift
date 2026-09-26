import Metal
import simd

/// Draws image layers through their own WE material (`ImageMaterialPlan`) into the scene target,
/// the way WE draws an image object: the layer's quad, in scene units, through
/// `g_ModelViewProjectionMatrix`; `g_Texture0` is the layer image (its effects' output when it
/// has any) with the sprite frame in `g_Texture0Rotation/Translation`; the live colour, alpha and
/// brightness feed `g_Color4`, `g_Color`, `g_Alpha`, `g_UserAlpha` and `g_Brightness`; blending
/// comes from the material and `BLENDMODE` reads the scene drawn so far.
///
/// Pipelines compile off the render thread, like effect pipelines, and share their binary
/// archive. `draw` returns false until the pipeline is ready, or when it failed (logged once);
/// the caller then draws the layer natively. Call on the render thread, apart from the compiles.
final class ImageMaterialRenderer {
    private let device: MTLDevice
    private let archive: EffectPipelineArchive?
    private let zeroAttributes: MTLBuffer
    private let clampSampler: MTLSamplerState
    private let repeatSampler: MTLSamplerState
    /// Uniform blocks over 4 KB. Render thread only (see `SceneUniformArena`).
    let uniformArena: SceneUniformArena

    private let compileQueue = DispatchQueue(label: "owe.image-material-pipelines", qos: .userInitiated,
                                             attributes: .concurrent)
    /// Owns `pipelines`, `pending` and `failed`, which compile threads write.
    private let pipelineLock = NSLock()
    private var pipelines: [String: MTLRenderPipelineState] = [:]
    /// Pipelines drawn with since the last `trimMemory` that dropped idle ones.
    private var usedPipelines = Set<String>()
    private var pending = Set<String>()
    private var failed = Set<String>()

    /// Uniform programs per layer instance (script clones share a plan but not a placement), rebuilt
    /// when the layer's plan changes. Render thread only.
    private var programs: [String: Program] = [:]

    private final class Program {
        let plan: ImageMaterialPlan
        let uniforms: ImageMaterialUniforms
        /// The prelighting pass's uniforms and its target (`prelight`).
        let prelightUniforms: ImageMaterialUniforms?
        var prelit: MTLTexture?
        /// Ignored native adjustments have been logged for this layer.
        var reportedIgnoredAdjustments = false

        init(plan: ImageMaterialPlan) {
            self.plan = plan
            uniforms = ImageMaterialUniforms(layout: plan.pass.variant?.uniforms, constants: plan.pass.constants,
                                             liveFactors: plan.liveFactors)
            prelightUniforms = plan.prelighting.map {
                ImageMaterialUniforms(layout: $0.variant?.uniforms, constants: $0.constants, liveFactors: plan.liveFactors)
            }
        }
    }

    /// Layers drawn through their material, for tests and diagnostics.
    private(set) var drawsEncoded = 0
    /// Prelighting passes encoded (`prelight`), for tests and diagnostics.
    private(set) var prelitDraws = 0
    /// Layer instances holding uniform state, for tests and diagnostics.
    var programCount: Int { programs.count }
    /// Compiled pipelines, shared by every layer drawing the same variant, format and blending.
    var pipelineCount: Int { pipelineLock.withLock { pipelines.count } }

    init?(device: MTLDevice, archive: EffectPipelineArchive?) {
        self.device = device
        self.archive = archive
        uniformArena = SceneUniformArena(device: device)
        guard let zero = device.makeBuffer(length: 64) else { return nil }
        zeroAttributes = zero
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

    /// Drops per-plan state when the content changes. Compiled pipelines are kept.
    func releaseAll() {
        programs.removeAll()
    }

    /// One layer's draw this frame.
    struct Draw {
        /// The layer instance (its state id); per-layer uniform state is kept under it.
        let layerID: String
        /// World-space quad in scene units (y up), parents, scripts, animation and parallax included.
        let quad: SceneQuadGeometry
        let sceneSize: SIMD2<Float>
        let color: SIMD3<Float>
        let alpha: Float
        let brightness: Float
        /// `g_Texture0`: the layer image, or its effects' output.
        let texture: MTLTexture
        /// The image inside a padded texture (`g_Texture0Resolution.zw`); nil when it fills it.
        let contentSize: SIMD2<Float>?
        /// The sprite frame (or content crop) in `texture`'s UV space.
        let uvOrigin: SIMD2<Float>
        let uvAxisX: SIMD2<Float>
        let uvAxisY: SIMD2<Float>
        /// The scene drawn so far, for materials that blend with it (`BLENDMODE`).
        let sceneSnapshot: MTLTexture?
        /// `_rt_MipMappedFrameBuffer` (`SceneMipMappedFrameBuffer`), for a material that samples it
        /// (`REFLECTION`).
        var mipMappedFrameBuffer: MTLTexture? = nil
        let frame: BuiltinFrameContext
        let values: SceneValueContext
        let assetTexture: (String, SceneMetalTextureSource) -> MTLTexture?
        /// An animated asset texture's sprite frame this frame (`g_TextureNRotation/Translation`
        /// of a slot other than 0, which is the layer's own frame); nil for a still one.
        var assetSprite: ((String, SceneMetalTextureSource) -> BuiltinSpriteFrame?)? = nil
        /// The renderer's own adjustments (legacy material heuristics) are not neutral for this
        /// layer; the material's shader draws it without them. Logged once per layer.
        var ignoredAdjustments = false
    }

    /// Encodes the layer into `encoder` (a pass of `commandBuffer` on a `pixelFormat` target). False
    /// when the layer must be drawn another way this frame: the pipeline is compiling or failed, or
    /// an input is missing. Leaves the encoder's pipeline state changed.
    func draw(_ plan: ImageMaterialPlan, _ draw: Draw, pixelFormat: MTLPixelFormat,
              encoder: MTLRenderCommandEncoder, commandBuffer: MTLCommandBuffer) -> Bool {
        guard plan.pass.variant != nil,
              let pipeline = pipeline(for: plan.pass, material: plan.materialPath, pixelFormat: pixelFormat) else { return false }
        let extent = draw.quad.extent
        // A zero-area quad covers no pixels; nothing to draw, and nothing for a fallback to draw either.
        guard extent.x > 0, extent.y > 0, extent.x.isFinite, extent.y.isFinite else { return true }
        guard let textureInfo = textures(of: plan.pass, plan: plan, draw) else { return false }

        let program = program(for: plan, layerID: draw.layerID)
        if draw.ignoredAdjustments, !program.reportedIgnoredAdjustments {
            program.reportedIgnoredAdjustments = true
            OWELog.info(.scene, "Layer \(draw.layerID) draws through \(plan.materialPath); its legacy material adjustments are not applied")
        }
        let uniforms = program.uniforms
        if uniforms.size > 0 {
            let model = Self.modelMatrix(draw.quad)
            let viewProjection = Self.viewProjection(sceneSize: draw.sceneSize)
            let rotation = SIMD4<Float>(draw.uvAxisX.x, draw.uvAxisX.y, draw.uvAxisY.x, draw.uvAxisY.y)
            let key = ImageMaterialUniforms.PassKey(
                model: model, viewProjection: viewProjection, color: draw.color, alpha: draw.alpha,
                brightness: draw.brightness, spriteRotation: rotation, spriteTranslation: draw.uvOrigin,
                screen: draw.frame.screenSize,
                textures: textureInfo.map { SIMD4(Float($0.texture.width), Float($0.texture.height),
                                                  $0.contentSize?.x ?? 0, $0.contentSize?.y ?? 0) },
                sprites: textureInfo.compactMap(\.sprite))
            uniforms.update(key: key, frame: draw.frame, values: draw.values) {
                var pass = BuiltinPassContext(targetSize: draw.sceneSize)
                pass.modelMatrix = model
                pass.viewProjection = viewProjection
                pass.modelViewProjection = viewProjection * model
                pass.color = draw.color
                pass.alpha = draw.alpha
                pass.userAlpha = draw.alpha
                pass.brightness = draw.brightness
                for entry in textureInfo {
                    var info = EffectGraphRenderer.textureInfo(for: entry.texture, contentSize: entry.contentSize)
                    if entry.slot == 0 {
                        info.spriteRotation = rotation
                        info.spriteTranslation = draw.uvOrigin
                    } else if let sprite = entry.sprite {
                        info.spriteRotation = sprite.rotation
                        info.spriteTranslation = sprite.translation
                    }
                    pass.textures[entry.slot] = info
                }
                return pass
            }
        }

        encoder.setRenderPipelineState(pipeline)
        var positions = Self.quadPositions(extent: extent)
        var texCoords = plan.usesSpriteSheetUniforms
            ? Self.corners
            : Self.corners.map { draw.uvOrigin + $0.x * draw.uvAxisX + $0.y * draw.uvAxisY }
        encoder.setVertexBytes(&positions, length: MemoryLayout<Float>.stride * positions.count,
                               index: EffectGraphRenderer.positionBuffer)
        encoder.setVertexBytes(&texCoords, length: MemoryLayout<SIMD2<Float>>.stride * texCoords.count,
                               index: EffectGraphRenderer.texCoordBuffer)
        encoder.setVertexBuffer(zeroAttributes, offset: 0, index: EffectGraphRenderer.zeroBuffer)
        for entry in textureInfo {
            encoder.setFragmentTexture(entry.texture, index: entry.slot)
            encoder.setFragmentSamplerState(entry.sampler, index: entry.slot)
            encoder.setVertexTexture(entry.texture, index: entry.slot)
            encoder.setVertexSamplerState(entry.sampler, index: entry.slot)
        }
        if uniforms.size > 0 {
            uniforms.bytes.withUnsafeBytes { raw in
                uniformArena.bind(raw, index: 0, to: encoder, commandBuffer: commandBuffer)
            }
        }
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        drawsEncoded += 1
        return true
    }

    /// The prelit image's format: WE's LDR effect buffers are RGBA8.
    static let prelitFormat = MTLPixelFormat.rgba8Unorm

    /// WE's prelighting pass (0x140209540; docs/lighting-plan.md §2.3) for a lit or reflective
    /// layer with effects: `plan.prelighting`, the material with its lighting and `PRELIGHTING`,
    /// draws `draw.texture` texel for texel into a texture of its size, which the layer's effects
    /// then start from. The layer's place in the scene reaches the shader as `g_AltModelMatrix`,
    /// `g_AltNormalModelMatrix` and `g_AltViewProjectionMatrix` (0x14020656b, 0x140207dc3), so each
    /// texel is lit, and reflects the scene, where it lies in the scene, while
    /// `g_ModelViewProjectionMatrix` maps it into the texture. `g_Color4` is white: the layer's
    /// colour, alpha and brightness are applied once, by its own draw after the effects. nil (the
    /// effects take the image unlit) while the pipeline compiles or an input is missing. Encodes its
    /// own render pass.
    func prelight(_ plan: ImageMaterialPlan, _ draw: Draw, commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        guard let pass = plan.prelighting,
              let pipeline = pipeline(for: pass, material: plan.materialPath, pixelFormat: Self.prelitFormat) else { return nil }
        let extent = draw.quad.extent
        guard extent.x > 0, extent.y > 0, extent.x.isFinite, extent.y.isFinite,
              let textureInfo = textures(of: pass, plan: plan, draw) else { return nil }
        let program = program(for: plan, layerID: draw.layerID)
        let width = draw.texture.width, height = draw.texture.height
        if program.prelit?.width != width || program.prelit?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.prelitFormat, width: width,
                                                                      height: height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            program.prelit = device.makeTexture(descriptor: descriptor)
        }
        guard let target = program.prelit else { return nil }

        // The image (its content, inside a padded texture) is the layer's quad in model space:
        // `extent` wide and tall, centred, y up. Every texel of the texture is drawn.
        let size = SIMD2(Float(width), Float(height))
        let content = (draw.contentSize ?? size) / size
        var positions = Self.corners.flatMap { uv -> [Float] in
            [(uv.x / content.x - 0.5) * extent.x, (0.5 - uv.y / content.y) * extent.y, 0]
        }
        // Model space onto the whole texture: texture row 0 at GL clip y = −1, as for the scene target.
        let intoTexture = simd_float4x4(columns: (SIMD4(2 * content.x / extent.x, 0, 0, 0),
                                                  SIMD4(0, -2 * content.y / extent.y, 0, 0),
                                                  SIMD4(0, 0, 1, 0),
                                                  SIMD4(content.x - 1, content.y - 1, 0, 1)))
        if let uniforms = program.prelightUniforms, uniforms.size > 0 {
            let alt = Self.modelMatrix(draw.quad)
            let key = ImageMaterialUniforms.PassKey(
                model: alt, viewProjection: intoTexture, color: SIMD3(repeating: 1), alpha: 1, brightness: 1,
                spriteRotation: SIMD4(1, 0, 0, 1), spriteTranslation: .zero, screen: draw.frame.screenSize,
                textures: textureInfo.map { SIMD4(Float($0.texture.width), Float($0.texture.height),
                                                  $0.contentSize?.x ?? 0, $0.contentSize?.y ?? 0) },
                sprites: textureInfo.compactMap(\.sprite))
            uniforms.update(key: key, frame: draw.frame, values: draw.values) {
                // The buffer's own view-projection, in the scene target's convention.
                let view = Self.viewProjection(sceneSize: size)
                var context = BuiltinPassContext(targetSize: size)
                context.viewProjection = view
                context.modelViewProjection = intoTexture
                context.modelMatrix = view.inverse * intoTexture
                context.altModelMatrix = alt
                context.altViewProjection = Self.viewProjection(sceneSize: draw.sceneSize)
                for entry in textureInfo {
                    var info = EffectGraphRenderer.textureInfo(for: entry.texture, contentSize: entry.contentSize)
                    if let sprite = entry.sprite, entry.slot != 0 {
                        info.spriteRotation = sprite.rotation
                        info.spriteTranslation = sprite.translation
                    }
                    context.textures[entry.slot] = info
                }
                return context
            }
        }

        let renderPass = MTLRenderPassDescriptor()
        renderPass.colorAttachments[0].texture = target
        renderPass.colorAttachments[0].loadAction = .clear
        renderPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        renderPass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else { return nil }
        encoder.setRenderPipelineState(pipeline)
        var texCoords = Self.corners
        encoder.setVertexBytes(&positions, length: MemoryLayout<Float>.stride * positions.count,
                               index: EffectGraphRenderer.positionBuffer)
        encoder.setVertexBytes(&texCoords, length: MemoryLayout<SIMD2<Float>>.stride * texCoords.count,
                               index: EffectGraphRenderer.texCoordBuffer)
        encoder.setVertexBuffer(zeroAttributes, offset: 0, index: EffectGraphRenderer.zeroBuffer)
        for entry in textureInfo {
            encoder.setFragmentTexture(entry.texture, index: entry.slot)
            encoder.setFragmentSamplerState(entry.sampler, index: entry.slot)
            encoder.setVertexTexture(entry.texture, index: entry.slot)
            encoder.setVertexSamplerState(entry.sampler, index: entry.slot)
        }
        if let uniforms = program.prelightUniforms, uniforms.size > 0 {
            uniforms.bytes.withUnsafeBytes { raw in
                uniformArena.bind(raw, index: 0, to: encoder, commandBuffer: commandBuffer)
            }
        }
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        prelitDraws += 1
        return target
    }

    private typealias BoundTexture = (slot: Int, texture: MTLTexture, sampler: MTLSamplerState, contentSize: SIMD2<Float>?,
                                      sprite: BuiltinSpriteFrame?)

    /// The textures `pass` reads for this draw; nil when one isn't there this frame.
    private func textures(of pass: SceneEffectPassPlan, plan: ImageMaterialPlan, _ draw: Draw) -> [BoundTexture]? {
        var textureInfo: [BoundTexture] = []
        for slot in pass.variant?.textureSlots ?? [] {
            // The plan binds every slot the variant reads; one it leaves out is declared but unused.
            guard let input = pass.textures[slot] else { continue }
            let sampler = plan.clampedSlots.contains(slot) ? clampSampler : repeatSampler
            switch input {
            case .current, .previous:
                textureInfo.append((slot, draw.texture, sampler, draw.contentSize, nil))
            case .sceneSnapshot:
                guard let snapshot = draw.sceneSnapshot else { return nil }
                textureInfo.append((slot, snapshot, clampSampler, nil, nil))
            case .mipMappedFrameBuffer:
                guard let target = draw.mipMappedFrameBuffer else { return nil }
                textureInfo.append((slot, target, clampSampler, nil, nil))
            case .asset(let key, let source):
                guard let texture = draw.assetTexture(key, source) else { return nil }
                textureInfo.append((slot, texture, sampler, source.contentSize, draw.assetSprite?(key, source)))
            case .fbo:
                return nil
            }
        }
        return textureInfo
    }

    /// Whether `sceneFragment`'s per-layer adjustments (legacy material heuristics, music sync) leave
    /// this layer unchanged, i.e. whether the native draw would apply nothing besides the object's
    /// own `brightness`, which the material applies.
    static func nativeAdjustmentsAreIdentity(_ uniform: LayerUniform, brightness: Float) -> Bool {
        uniform.effects.x == brightness
            && uniform.effects.y == 1 && uniform.effects.z == 1 && uniform.effects.w <= 0 && uniform.blur <= 0
            && uniform.colorEffects.x == 0 && uniform.colorEffects.y == 1 && abs(uniform.colorEffects.z) <= 0.0001
            && uniform.transform == SIMD4(0, 0, 0, 1) && uniform.transformScaleY == 1
    }

    // MARK: - Geometry

    /// Triangle-strip corners in texture space (u right, v down the image).
    static let corners: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(1, 0), SIMD2(0, 1), SIMD2(1, 1)]

    /// The quad in model space: centred, `extent` wide and tall, y up (v = 0 is the top edge).
    static func quadPositions(extent: SIMD2<Float>) -> [Float] {
        corners.flatMap { corner -> [Float] in
            [(corner.x - 0.5) * extent.x, (0.5 - corner.y) * extent.y, 0]
        }
    }

    /// Maps the model-space quad onto the world quad: its axes (rotation, shear and scale of the
    /// whole parent chain) and its centre.
    static func modelMatrix(_ quad: SceneQuadGeometry) -> simd_float4x4 {
        let extent = quad.extent
        let x = quad.axisX / extent.x
        let y = quad.axisY / extent.y
        return simd_float4x4(columns: (SIMD4(x.x, x.y, 0, 0), SIMD4(y.x, y.y, 0, 0), SIMD4(0, 0, 1, 0),
                                       SIMD4(quad.center.x, quad.center.y, 0, 1)))
    }

    /// Scene units to clip space. The translated vertex stage flips y (GL rows, see
    /// `ProcessShaderCompiler`), and the scene target keeps the scene's top in its first row, so the
    /// scene's top maps to GL clip y = −1.
    static func viewProjection(sceneSize: SIMD2<Float>) -> simd_float4x4 {
        PassMatrices.ortho(left: 0, right: max(sceneSize.x, 1), bottom: max(sceneSize.y, 1), top: 0)
    }

    // MARK: - Uniforms

    private func program(for plan: ImageMaterialPlan, layerID: String) -> Program {
        if let existing = programs[layerID], existing.plan === plan { return existing }
        let program = Program(plan: plan)
        programs[layerID] = program
        return program
    }

    /// Memory pressure: drops free uniform chunks, and with `dropIdlePipelines` every pipeline not
    /// drawn with since the last trim (they recompile, from the binary archive, if needed again).
    func trimMemory(dropIdlePipelines: Bool) {
        uniformArena.trim()
        guard dropIdlePipelines else { return }
        pipelineLock.withLock {
            pipelines = pipelines.filter { usedPipelines.contains($0.key) }
            usedPipelines.removeAll()
        }
    }

    /// Frees one layer's uniform state (e.g. a removed script clone).
    func releaseLayer(_ layerID: String) {
        programs.removeValue(forKey: layerID)
    }

    // MARK: - Pipelines

    static func pipelineKey(_ pass: SceneEffectPassPlan, pixelFormat: MTLPixelFormat) -> String {
        "image|\(pass.variantKey)|\(pixelFormat.rawValue)|\(pass.blending.lowercased())"
    }

    /// The ready pipeline, or nil while it compiles (the compile is started here) or after it failed.
    private func pipeline(for pass: SceneEffectPassPlan, material: String, pixelFormat: MTLPixelFormat) -> MTLRenderPipelineState? {
        let key = Self.pipelineKey(pass, pixelFormat: pixelFormat)
        let state: (pipeline: MTLRenderPipelineState?, busy: Bool) = pipelineLock.withLock {
            if pipelines[key] != nil { usedPipelines.insert(key) }
            return (pipelines[key], pending.contains(key) || failed.contains(key))
        }
        if let pipeline = state.pipeline { return pipeline }
        if !state.busy, let variant = pass.variant {
            compile(variant, blending: pass.blending, material: material, pixelFormat: pixelFormat, key: key)
        }
        return nil
    }

    /// Blocks until the plan's pipelines (its prelighting pass's too, into `prelitFormat`) compiled
    /// or failed (tests, prewarming). True when they are ready.
    func waitUntilReady(_ plan: ImageMaterialPlan, pixelFormat: MTLPixelFormat, timeout: TimeInterval = 60) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let passes = [(plan.pass, pixelFormat)] + (plan.prelighting.map { [($0, Self.prelitFormat)] } ?? [])
        for (pass, format) in passes {
            let key = Self.pipelineKey(pass, pixelFormat: format)
            while pipeline(for: pass, material: plan.materialPath, pixelFormat: format) == nil {
                if pipelineLock.withLock({ failed.contains(key) }) || Date() > deadline { return false }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        return true
    }

    private func compile(_ variant: TranslatedShaderVariant, blending: String, material: String, pixelFormat: MTLPixelFormat,
                         key: String) {
        pipelineLock.withLock { _ = pending.insert(key) }
        let device = self.device
        let archive = self.archive
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
                descriptor.colorAttachments[0].pixelFormat = pixelFormat
                if let blend = EffectGraphRenderer.blendMode(blending) {
                    let attachment = descriptor.colorAttachments[0]!
                    attachment.isBlendingEnabled = true
                    attachment.sourceRGBBlendFactor = blend.source
                    attachment.sourceAlphaBlendFactor = blend.source
                    attachment.destinationRGBBlendFactor = blend.destination
                    attachment.destinationAlphaBlendFactor = blend.destination
                }
                descriptor.vertexDescriptor = EffectGraphRenderer.vertexDescriptor(for: vertex)
                result = try EffectGraphRenderer.makePipeline(descriptor, device: device, archive: archive, key: key)
            } catch {
                OWELog.error(.shader, "Image material \(material) can't draw through its shader; the layer draws natively: \(error)")
                result = nil
            }
            guard let self else { return }
            self.pipelineLock.withLock {
                self.pending.remove(key)
                if let result { self.pipelines[key] = result } else { self.failed.insert(key) }
            }
        }
    }
}
