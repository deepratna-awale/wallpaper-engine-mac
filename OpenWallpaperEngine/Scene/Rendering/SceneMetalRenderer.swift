import Cocoa
import MetalKit
import CryptoKit

private struct PreparedLayer {
    let frames: [RenderTextureFrame]
    let frameDuration: Float
    let layer: SceneMetalLayer
    /// Key used for script-driven state. Layers cloned by `thisScene.createLayer` share their
    /// source's textures but track their own transform under a different id.
    var stateId: String
    /// Where the layer's own transform comes from each frame.
    let motion: SceneObjectMotion

    init(frames: [RenderTextureFrame], frameDuration: Float, layer: SceneMetalLayer, stateId: String? = nil) {
        self.frames = frames
        self.frameDuration = frameDuration
        self.layer = layer
        self.stateId = stateId ?? layer.id
        motion = SceneObjectMotion(layer: layer)
    }
}

/// What a visible layer is drawn with this frame: its scripted/animated opacity and colour and
/// its placed quad. Computed once, before effects run, so effects see the same values.
private struct LayerDraw {
    let opacity: Float
    let color: SIMD4<Float>
    let brightness: Float
    /// World-space quad, parallax and camera shake included.
    let quad: SceneQuadGeometry
    let musicSyncLevel: Double
}

/// Frame-wide camera motion applied to every layer.
private struct CameraMotion {
    let parallaxEnabled: Bool
    let parallaxAmount: Float
    let cursorDelta: SIMD2<Float>
    let shakeOffset: SIMD2<Float>
    let audioLevel: Double
}

private struct RenderTextureFrame {
    let texture: MTLTexture
    let duration: Float
    let uvOrigin: SIMD2<Float>
    let uvAxisX: SIMD2<Float>
    let uvAxisY: SIMD2<Float>
}

final class SceneMetalRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let renderPipeline: MTLRenderPipelineState
    private let additiveRenderPipeline: MTLRenderPipelineState
    /// Unblended resample of a texture through per-vertex UVs (`sceneRegion`).
    private let copyPipeline: MTLRenderPipelineState
    /// The scene target onto the drawable: colour only, as WE presents it (scene alpha is ignored).
    private let compositePipeline: MTLRenderPipelineState
    private let dxtDecodePipeline: MTLComputePipelineState
    private let textureLoader: MTKTextureLoader
    private let renderTargetPool: SceneRenderTargetPool
    /// Runs authored effects through Wallpaper Engine's own shaders.
    private lazy var effectGraph = EffectGraphRenderer(device: device)
    /// Draws particle systems through their WE material.
    private lazy var particleMaterials = ParticleMaterialRenderer(device: device)
    /// Draws image layers through their own WE material.
    private lazy var imageMaterials = ImageMaterialRenderer(device: device, archive: effectGraph?.pipelineArchive)
    /// Asset textures used by effect passes, materialised once per content.
    private var effectAssetTextures: [String: MTLTexture] = [:]
    /// Scene time since the content loaded, speed applied; drives animations, `g_Time`,
    /// particles and scripts alike.
    private var clock = SceneClock()
    private let contentQueue = DispatchQueue(label: "SceneMetalRenderer.content", qos: .userInitiated)
    private let contentGenerationLock = NSLock()
    private var contentGeneration = 0
    private var sceneSize = SIMD2<Float>(1920, 1080)
    private var layers: [PreparedLayer] = []
    private var particleInstances: [LayerUniform] = []
    private var particleInstanceStorage: MTLBuffer?

    private var particleSystems: [ParticleSystemRuntime] = []
    /// Steps particle systems on the GPU; nil runs them on the CPU (`ParticleCPUSimulation`).
    private let particleSimulator: ParticleGPUSimulator?
    /// This frame's GPU steps, reused across frames.
    private var particleRequests: [ParticleGPUSimulator.Request] = []
    private var sceneScript: String?
    private var camera = SceneCameraEffects()
    /// Whose user properties this renderer's frames read (see `SceneMetalContent.wallpaperKey`).
    private var wallpaperKey = ""
    private var placement: WallpaperPlacement = .fill
    /// Drawable pixels per view point (the backing scale), refreshed every frame.
    private var drawablePixelsPerPoint: Float = 1
    /// Last frame's normalised pointer, for `g_PointerPositionLast`; nil until the first frame.
    private var lastPointer: SIMD2<Float>?
    /// Where the cursor was last seen on this renderer's display.
    private var cursorTracker = SceneCursorTracker()
    private var bloom = SceneBloomSettings(enabled: false, strength: 0, threshold: 0.7, tint: SIMD3<Float>(repeating: 1))
    private var sceneRenderTarget: MTLTexture?
    private var sceneRenderTargetSize = SIMD2<Int>.zero
    /// Render-target pixels per scene unit this frame (see `SceneRenderResolution`).
    private var renderPixelsPerUnit: Float = 1
    private var textFrameCache = SceneLRUCache<String, (frame: RenderTextureFrame, baseSize: SIMD2<Float>)>(capacity: 128)
    /// The finest raster scale each text layer has needed, so an animated scale doesn't
    /// re-rasterise at every step (see `SceneTextRasterScale.retained`).
    private var textRasterScales: [String: Float] = [:]
    /// Parent graph of the current content; layer origins are relative to their parents.
    private var transforms = SceneTransformHierarchy.empty
    /// Each layer's local transform, evaluated once per frame so a parent's scripts run once
    /// however many children read it.
    private var frameLocals: [String: SceneLocalTransform] = [:]
    private var layerIndexByStateId: [String: Int] = [:]
    /// Objects that aren't drawn layers (groups, particle systems), by id: their live transform.
    private var objectMotions: [String: SceneObjectMotion] = [:]
    /// The most recently committed frame, so state a removal frees can wait for it.
    private(set) var lastCommandBuffer: MTLCommandBuffer?
    /// Removed clones' state ids, freed once the frame that last drew them completes.
    private var deferredReleases = SceneDeferredReleases()
    /// Told how long each frame took on the CPU, including the wait for a drawable.
    var frameTimeObserver: ((CFTimeInterval) -> Void)?

    /// Where particle systems are simulated. The CPU simulation is the reference the GPU one is
    /// tested against (`ParticleSimulationParityTests`), and the fallback when compute is unavailable.
    enum ParticleSimulation {
        case gpu, cpu
    }

    init?(view: MTKView, particleSimulation: ParticleSimulation = .gpu) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "sceneVertex"),
              let fragment = library.makeFunction(name: "sceneFragment"),
              let copyFragment = library.makeFunction(name: "sceneCopyFragment"),
              let decode = library.makeFunction(name: "decodeDXT"),
              let decodePipeline = try? device.makeComputePipelineState(function: decode) else {
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let renderPipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else {
            return nil
        }
        let additiveDescriptor = descriptor.copy() as! MTLRenderPipelineDescriptor
        additiveDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        additiveDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        additiveDescriptor.colorAttachments[0].destinationRGBBlendFactor = .one
        additiveDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .one
        guard let additiveRenderPipeline = try? device.makeRenderPipelineState(descriptor: additiveDescriptor) else {
            return nil
        }

        guard let compositePipeline = try? device.makeRenderPipelineState(
            descriptor: SceneComposite.pipelineDescriptor(basedOn: descriptor)) else {
            return nil
        }

        let copyDescriptor = MTLRenderPipelineDescriptor()
        copyDescriptor.vertexFunction = vertex
        copyDescriptor.fragmentFunction = copyFragment
        copyDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        guard let copyPipeline = try? device.makeRenderPipelineState(descriptor: copyDescriptor) else {
            return nil
        }

        switch particleSimulation {
        case .gpu:
            do {
                particleSimulator = try ParticleGPUSimulator(device: device)
            } catch {
                OWELog.error(.scene, "GPU particle simulation unavailable, simulating on the CPU: \(error)")
                particleSimulator = nil
            }
        case .cpu:
            particleSimulator = nil
        }
        self.device = device
        self.copyPipeline = copyPipeline
        self.compositePipeline = compositePipeline
        self.commandQueue = commandQueue
        self.renderPipeline = renderPipeline
        self.additiveRenderPipeline = additiveRenderPipeline
        self.dxtDecodePipeline = decodePipeline
        self.textureLoader = MTKTextureLoader(device: device)
        self.renderTargetPool = SceneRenderTargetPool(device: device)
        super.init()
        view.device = device
        view.delegate = self
        view.framebufferOnly = false
        view.enableSetNeedsDisplay = false
        view.isPaused = false
    }

    /// Drops every prepared layer, releasing any video stream those layers hold.
    func releaseContent() {
        setContent(nil)
    }

    func setContent(_ content: SceneMetalContent?) {
        effectAssetTextures.removeAll()
        effectGraph?.releaseTargets()
        particleMaterials?.releaseAll()
        imageMaterials?.releaseAll()
        contentGenerationLock.lock()
        contentGeneration &+= 1
        let generation = contentGeneration
        contentGenerationLock.unlock()

        guard let content else {
            layers = []
            particleSystems = []
            objectMotions = [:]
            sceneScript = nil
            textFrameCache.removeAll()
            textRasterScales.removeAll()
            clock = SceneClock()
            transforms = .empty
            lastPointer = nil
            cursorTracker = SceneCursorTracker()
            deferredReleases.removeAll()
            lastCommandBuffer = nil
            return
        }
        contentQueue.async { [weak self] in
            guard let self, self.isCurrentContentGeneration(generation) else { return }
            let preparedLayers: [PreparedLayer] = content.layers.compactMap { layer in
                guard let frames = self.makeTextureFrames(from: layer.source), !frames.isEmpty else { return nil }
                return PreparedLayer(frames: frames, frameDuration: frames.reduce(0) { $0 + $1.duration }, layer: layer)
            }
            let preparedParticleSystems: [ParticleSystemRuntime] = content.particleSystems.enumerated().compactMap { index, system in
                guard let texture = self.makeTextureFrames(from: system.source)?.first?.texture else { return nil }
                // Seeded by position in the scene, so a wallpaper's particles replay the same way.
                return ParticleSystemRuntime(texture: texture, configuration: system, seed: ParticleRandom.pcg(UInt32(index)))
            }
            guard self.isCurrentContentGeneration(generation) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrentContentGeneration(generation) else { return }
                self.sceneSize = content.size
                self.bloom = content.bloom
                self.layers = preparedLayers
                self.particleSystems = preparedParticleSystems
                self.sceneScript = content.sceneScript
                self.transforms = content.transforms
                self.objectMotions = content.motions
                self.wallpaperKey = content.wallpaperKey
                self.camera = content.camera
                self.textFrameCache.removeAll()
                self.textRasterScales.removeAll()
                var scriptLayers: [String: [String: Any]] = [:]
                var layerAliases: [String: String] = [:]
                for entry in preparedLayers {
                    scriptLayers[entry.layer.id] = [
                        "id": entry.layer.id,
                        "name": entry.layer.name,
                        "visible": true,
                        "alpha": entry.layer.opacity,
                        "origin": ["x": entry.layer.position.x, "y": entry.layer.position.y, "z": 0],
                        "size": ["x": entry.layer.size.x, "y": entry.layer.size.y],
                        "scale": ["x": entry.layer.scale.x, "y": entry.layer.scale.y, "z": 1],
                        "angles": ["x": 0, "y": 0, "z": entry.layer.rotation],
                        "color": ["x": entry.layer.color.x, "y": entry.layer.color.y, "z": entry.layer.color.z],
                        "alignment": entry.layer.text?.horizontalAlignment ?? "center",
                        "scriptProperties": entry.layer.text?.scriptProperties.isEmpty == false
                            ? entry.layer.text?.scriptProperties ?? [:]
                            : entry.layer.positionScriptProperties
                    ]
                    layerAliases[entry.layer.name] = entry.layer.id
                }
                // Other objects (groups, particle systems) can be moved by scripts too.
                for (id, motion) in content.motions where scriptLayers[id] == nil {
                    scriptLayers[id] = [
                        "id": id, "name": motion.name, "visible": true,
                        "origin": ["x": motion.origin.x, "y": motion.origin.y, "z": 0],
                        "scale": ["x": motion.scale.x, "y": motion.scale.y, "z": 1],
                        "angles": ["x": 0, "y": 0, "z": motion.angle],
                    ]
                    if layerAliases[motion.name] == nil { layerAliases[motion.name] = id }
                }
                AudioReactiveScriptEngine.shared.configureLayers(scriptLayers, aliases: layerAliases,
                                                                 canvasSize: content.size)
                self.clock = SceneClock()
            }
        }
    }

    private func isCurrentContentGeneration(_ generation: Int) -> Bool {
        contentGenerationLock.lock()
        defer { contentGenerationLock.unlock() }
        return contentGeneration == generation
    }

    func setPlacement(_ placement: WallpaperPlacement) {
        self.placement = placement
    }

    /// `thisScene.createLayer` clones an existing layer. The clone reuses the source's textures and
    /// effects and only differs by the script state it reads, so no asset loading is required.
    private func materializeScriptCreatedLayers() {
        let pending = AudioReactiveScriptEngine.shared.drainPendingLayerCreations()
        for request in pending {
            guard !layers.contains(where: { $0.stateId == request.id }),
                  var clone = layers.first(where: { $0.stateId == request.source }) else { continue }
            clone.stateId = request.id
            layers.append(clone)
        }
        if !pending.isEmpty {
            OWELog.info(.script, "Script created \(pending.count) layer(s); now \(layers.count) total")
        }

        for request in AudioReactiveScriptEngine.shared.drainPendingLayerOrder() {
            guard let from = layers.firstIndex(where: { $0.stateId == request.id }) else { continue }
            let to = max(0, min(request.index, layers.count - 1))
            guard from != to else { continue }
            let entry = layers.remove(at: from)
            layers.insert(entry, at: to)
        }

        // Only script-created clones are removable; destroying an authored layer would leave the
        // scene unable to restore it without a full reload.
        let removals = Set(AudioReactiveScriptEngine.shared.drainPendingLayerRemovals())
        if !removals.isEmpty {
            let removed = layers.filter { removals.contains($0.stateId) && $0.stateId != $0.layer.id }.map(\.stateId)
            layers.removeAll { removals.contains($0.stateId) && $0.stateId != $0.layer.id }
            for id in removals { textRasterScales.removeValue(forKey: id) }
            // The last frame that drew these clones may still be on the GPU; free their effect
            // targets once it has finished (`releaseFinishedEffectState`).
            deferredReleases.enqueue(removed, after: lastCommandBuffer)
        }
    }

    /// Frees the effect state of removed clones whose last frame the GPU has finished. A clone
    /// re-created under the same id meanwhile keeps its (new) state.
    private func releaseFinishedEffectState() {
        guard deferredReleases.count > 0 else { return }
        deferredReleases.drain(live: Set(layers.map(\.stateId))) { id in
            effectGraph?.releaseLayer(id)
            imageMaterials?.releaseLayer(id)
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let frameStart = CACurrentMediaTime()
        let frameSignpost = OWESignpost.begin(OWESignpost.render, "frame")
        AudioReactiveScriptEngine.shared.beginFrame(wallpaper: wallpaperKey)
        renderTargetPool.endFrame()
        defer {
            AudioReactiveScriptEngine.shared.endFrame()
            frameSignpost.end()
            frameTimeObserver?(CACurrentMediaTime() - frameStart)
            if OWEFrameMetrics.isReportingEnabled {
                OWEFrameMetrics.recordFrame(seconds: CACurrentMediaTime() - frameStart,
                                            layers: layers.count,
                                            particles: particleSystems.reduce(0) { $0 + ($1.gpu?.completedCount ?? $1.particles.count) })
            }
        }

        guard let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable else {
            return
        }
        let realDrawableSize = SIMD2<Float>(Float(drawable.texture.width), Float(drawable.texture.height))
        drawablePixelsPerPoint = view.bounds.width > 0 ? realDrawableSize.x / Float(view.bounds.width) : 1
        renderPixelsPerUnit = SceneRenderResolution.pixelsPerUnit(sceneSize: sceneSize, drawableSize: realDrawableSize)
        guard let sceneTexture = sceneRenderTarget(matching: descriptor),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        // Layers and particles are drawn in scene units onto a target at the output's pixel
        // density; placement scaling happens once, in the final composite pass.
        let drawableSize = SIMD2<Float>(Float(sceneTexture.width), Float(sceneTexture.height))
        let animationSpeed = AudioReactiveScriptEngine.shared.userPropertyValue("_owe_speed", fallback: 1)
        clock.advance(to: CACurrentMediaTime(), speed: Double(animationSpeed))
        let sceneTime = clock.time
        let time = Float(sceneTime)
        AudioReactiveScriptEngine.shared.setSceneClock(deltaTime: clock.delta)
        if let sceneScript {
            AudioReactiveScriptEngine.shared.executeSceneScript(sceneScript, time: sceneTime)
        }
        let cursorSample = cursorTracker.update(sceneCursor(in: view, drawableSize: realDrawableSize),
                                                sceneSize: sceneSize)
        let cursor = cursorSample.position
        AudioReactiveScriptEngine.shared.updateSceneCursor(cursor)
        materializeScriptCreatedLayers()
        releaseFinishedEffectState()
        beginTransformFrame()
        var dynamicTextures: [Int: MTLTexture] = [:]
        // Advanced once per frame: every advance smooths the spectrum one step further.
        var effectFrame = BuiltinFrameContext()
        effectFrame.time = sceneTime
        effectFrame.frameTime = clock.delta
        effectFrame.daytime = BuiltinFrameContext.daytime(at: Date())
        let pointer = simd_clamp(cursor / max(sceneSize, SIMD2(1, 1)), SIMD2(0, 0), SIMD2(1, 1))
        effectFrame.pointer = pointer
        effectFrame.pointerLast = lastPointer ?? pointer
        lastPointer = pointer
        effectFrame.pointerState = BuiltinFrameContext.pointerState(
            primaryDown: cursorSample.onDisplay && NSEvent.pressedMouseButtons & 1 != 0)
        effectFrame.screenSize = drawableSize
        effectFrame.audio = AudioReactiveScriptEngine.shared.advanceAudioSpectrumFrame()
        let motion = cameraMotion(cursor: cursor, time: time)
        effectFrame.parallax = parallaxPosition(pointer: pointer)
        // Text is rasterised first so its effects run on the finished text, like an image layer's.
        var textFrames: [Int: (frame: RenderTextureFrame, baseSize: SIMD2<Float>)] = [:]
        // Only visible layers get an entry; the draw loop skips the rest.
        var draws: [Int: LayerDraw] = [:]
        for (layerIndex, entry) in layers.enumerated() {
            guard AudioReactiveScriptEngine.shared.layerBoolean(entry.stateId, property: "visible", fallback: true) else { continue }
            if entry.layer.text != nil {
                let world = worldTransform(entry, time: time)
                let pixelsPerUnit = max(world.axisScale.x, world.axisScale.y) * renderPixelsPerUnit
                textFrames[layerIndex] = layerTextFrame(entry, boxSize: layerBaseSize(entry, time: time),
                                                        pixelsPerUnit: pixelsPerUnit, time: time)
            }
            let draw = layerDraw(entry, baseSize: textFrames[layerIndex]?.baseSize ?? layerBaseSize(entry, time: time),
                                 time: time, motion: motion)
            draws[layerIndex] = draw
            // Layers that read the scene run inside the scene pass, once what's beneath them is drawn.
            if entry.layer.readsScene { continue }
            if !entry.layer.weEffects.isEmpty {
                let input = textFrames[layerIndex]?.frame ?? textureFrame(for: entry, time: time)
                dynamicTextures[layerIndex] = runEffects(entry, draw: draw, input: input.texture,
                                                         snapshot: nil, frame: effectFrame, commandBuffer: commandBuffer)
            }
        }

        let clearColor = descriptor.colorAttachments[0].clearColor
        let sceneRenderPass = MTLRenderPassDescriptor()
        sceneRenderPass.colorAttachments[0].texture = sceneTexture
        sceneRenderPass.colorAttachments[0].loadAction = .clear
        sceneRenderPass.colorAttachments[0].clearColor = clearColor
        sceneRenderPass.colorAttachments[0].storeAction = .store
        // One instanced draw per system rather than one per particle (or per rope segment, which
        // multiplies out to thousands on trail renderers).
        particleInstances.removeAll(keepingCapacity: true)
        particleRequests.removeAll(keepingCapacity: true)
        var particleBatches: [(system: ParticleSystemRuntime, base: Int, count: Int, material: Bool, simulated: Bool)] = []
        // Systems are drawn in scene.json order, between the layers around them.
        let orderedSystems = particleSystems.enumerated()
            .sorted { ($0.element.configuration.order, $0.offset) < ($1.element.configuration.order, $1.offset) }
            .map(\.element)
        let particleSignpost = OWESignpost.begin(OWESignpost.render, "updateParticles")
        for system in orderedSystems {
            let base = particleInstances.count
            let inputs = ParticleFrameInputs.advance(system, deltaTime: Float(clock.delta), cursor: cursor,
                                                     emitter: emitterWorld(system.configuration, time: time))
            if particleSimulator != nil {
                // The GPU steps the system and writes whichever records it is drawn from.
                let rendererName = system.configuration.rendererName
                if let simulated = particleMaterials?.prepareSimulated(system, pixelFormat: sceneTexture.pixelFormat) {
                    particleRequests.append(.init(system: system, inputs: inputs,
                                                  kind: .material(simulated.format, rendererName: rendererName),
                                                  materialVertexCount: simulated.vertexCount, renderVar: simulated.renderVar))
                    particleBatches.append((system, base, 0, true, true))
                } else {
                    particleRequests.append(.init(system: system, inputs: inputs, kind: .fallback(rendererName: rendererName)))
                    particleBatches.append((system, base, 0, false, true))
                }
                continue
            }
            ParticleCPUSimulation.step(system, inputs: inputs)
            if particleMaterials?.prepare(system, pixelFormat: sceneTexture.pixelFormat,
                                          opacity: { [unowned self] in self.particleOpacity($0, in: system) }) == true {
                particleBatches.append((system, base, 0, true, false))
                continue
            }
            if system.configuration.rendererName == "rope" {
                appendRope(system, drawableSize: drawableSize)
            } else {
                for particle in system.particles {
                    if system.configuration.rendererName == "ropetrail" {
                        appendRopeTrail(particle, system: system, drawableSize: drawableSize)
                    } else if system.configuration.rendererName.contains("trail") {
                        appendParticleTrail(particle, system: system, drawableSize: drawableSize)
                    } else {
                        var uniform = layerUniform(position: particle.position,
                                                   size: SIMD2<Float>(repeating: particle.size),
                                                   opacity: particleOpacity(particle, in: system),
                                                   drawableSize: drawableSize, placement: .stretch)
                        uniform.particleShape = 1
                        uniform.rotation = particle.rotation
                        uniform.color = particle.color
                        let uv = spriteSheetUV(for: particle, configuration: system.configuration)
                        uniform.uvOrigin = uv.origin
                        uniform.uvAxisX = SIMD2<Float>(uv.size.x, 0)
                        uniform.uvAxisY = SIMD2<Float>(0, uv.size.y)
                        particleInstances.append(uniform)
                    }
                }
            }
            particleBatches.append((system, base, particleInstances.count - base, false, false))
        }
        particleSignpost.end()
        particleSimulator?.encode(particleRequests, sceneSize: sceneSize, targetSize: drawableSize,
                                  commandBuffer: commandBuffer)
        guard var encoder = commandBuffer.makeRenderCommandEncoder(descriptor: sceneRenderPass) else { return }
        encoder.setRenderPipelineState(renderPipeline)
        let particleBuffer = particleInstanceBuffer(for: particleInstances.count)
        if let particleBuffer {
            particleInstances.withUnsafeBytes { source in
                particleBuffer.contents().copyMemory(from: source.baseAddress!, byteCount: source.count)
            }
        }
        var nextParticleBatch = 0
        /// One instanced draw per system, for every system authored before `order`.
        func drawParticleBatches(before order: Int) {
            var drew = false
            while nextParticleBatch < particleBatches.count,
                  particleBatches[nextParticleBatch].system.configuration.order < order {
                let batch = particleBatches[nextParticleBatch]
                nextParticleBatch += 1
                if batch.material {
                    particleMaterials?.draw(batch.system, encoder: encoder, context: .init(
                        sceneSize: sceneSize, frame: effectFrame,
                        values: LiveSceneValueContext(time: sceneTime, scriptTime: sceneTime),
                        assetTexture: { [unowned self] key, source in self.effectAssetTexture(key: key, source: source) }))
                    drew = true
                    continue
                }
                let pipeline = batch.system.configuration.blending == "additive" ? additiveRenderPipeline : renderPipeline
                if batch.simulated {
                    // The built-in quads the GPU step wrote, counted by its indirect arguments.
                    guard let gpu = batch.system.gpu, gpu.isReady, let records = gpu.records,
                          gpu.recordKind?.isFallback == true else { continue }
                    encoder.setVertexBuffer(records, offset: 0, index: 0)
                    encoder.setFragmentBuffer(records, offset: 0, index: 0)
                    encoder.setRenderPipelineState(pipeline)
                    encoder.setFragmentTexture(batch.system.texture, index: 0)
                    encoder.drawPrimitives(type: .triangleStrip, indirectBuffer: gpu.control,
                                           indirectBufferOffset: ParticleGPUSystem.Control.fallbackDrawOffset)
                    drew = true
                    continue
                }
                guard batch.count > 0, let particleBuffer else { continue }
                // Layer draws rebind index 0 with setVertexBytes, so bind the instances per draw.
                encoder.setVertexBuffer(particleBuffer, offset: 0, index: 0)
                encoder.setFragmentBuffer(particleBuffer, offset: 0, index: 0)
                encoder.setRenderPipelineState(pipeline)
                encoder.setFragmentTexture(batch.system.texture, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                       instanceCount: batch.count, baseInstance: batch.base)
                drew = true
            }
            if drew { encoder.setRenderPipelineState(renderPipeline) }
        }
        for (layerIndex, entry) in layers.enumerated() {
            drawParticleBatches(before: entry.layer.order)
            // Hidden layers (script `visible = false`) draw nothing, their raw texture included.
            guard let draw = draws[layerIndex] else { continue }
            var layerSnapshot: MTLTexture?
            if entry.layer.readsScene {
                // Metal can't sample the attachment it's drawing into: pause the scene pass, copy
                // what's drawn so far (`_rt_FullFrameBuffer`), run this layer's effects on it, resume.
                encoder.endEncoding()
                let snapshot = sceneSnapshot(of: sceneTexture, commandBuffer: commandBuffer)
                layerSnapshot = snapshot
                let input = entry.layer.sceneInput
                    ? snapshot.flatMap { sceneRegion(of: $0, under: draw.quad, commandBuffer: commandBuffer) }
                    : (textFrames[layerIndex]?.frame ?? textureFrame(for: entry, time: time)).texture
                dynamicTextures[layerIndex] = input.flatMap {
                    runEffects(entry, draw: draw, input: $0, snapshot: snapshot, frame: effectFrame, commandBuffer: commandBuffer)
                }
                let resume = MTLRenderPassDescriptor()
                resume.colorAttachments[0].texture = sceneTexture
                resume.colorAttachments[0].loadAction = .load
                resume.colorAttachments[0].storeAction = .store
                guard let resumed = commandBuffer.makeRenderCommandEncoder(descriptor: resume) else { return }
                encoder = resumed
                encoder.setRenderPipelineState(renderPipeline)
                // Until its effects are ready the layer has nothing of its own to draw.
                if entry.layer.sceneInput, dynamicTextures[layerIndex] == nil { continue }
            }
            var uniform = layerUniform(position: draw.quad.center, size: draw.quad.extent,
                                       opacity: draw.opacity, drawableSize: drawableSize, placement: .stretch)
            setQuadAxes(&uniform, quad: draw.quad)
            uniform.color = draw.color
            let materialEffects = entry.layer.effects
            let brightness = materialEffects.scripts["brightness"].map {
                AudioReactiveScriptEngine.shared.evaluate($0, fallback: materialEffects.brightness, layerId: entry.stateId, time: sceneTime)
            } ?? materialEffects.brightness
            let contrast = materialEffects.scripts["contrast"].map {
                AudioReactiveScriptEngine.shared.evaluate($0, fallback: materialEffects.contrast, layerId: entry.stateId, time: sceneTime)
            } ?? materialEffects.contrast
            let saturation = materialEffects.scripts["saturation"].map {
                AudioReactiveScriptEngine.shared.evaluate($0, fallback: materialEffects.saturation, layerId: entry.stateId, time: sceneTime)
            } ?? materialEffects.saturation
            // Scripts write thisObject.bloomstrength directly rather than through a property script.
            let bloom = AudioReactiveScriptEngine.shared.layerValue(entry.stateId, property: "bloomstrength",
                fallback: materialEffects.scripts["bloom"].map {
                    AudioReactiveScriptEngine.shared.evaluate($0, fallback: materialEffects.bloom, layerId: entry.stateId, time: sceneTime)
                } ?? materialEffects.bloom)
            uniform.effects = SIMD4<Float>(brightness * draw.brightness, contrast,
                                           saturation * (1 + (entry.layer.musicSync?.saturationAmount ?? 0) * Float(draw.musicSyncLevel)),
                                           bloom * AudioReactiveScriptEngine.shared.userPropertyValue("_owe_bloom", fallback: 1))
            uniform.blur = materialEffects.scripts["blur"].map {
                AudioReactiveScriptEngine.shared.evaluate($0, fallback: materialEffects.blur, layerId: entry.stateId, time: sceneTime)
            } ?? materialEffects.blur * AudioReactiveScriptEngine.shared.userPropertyValue("_owe_blur", fallback: 1)
            uniform.colorEffects = SIMD4<Float>(materialEffects.exposure, materialEffects.gamma,
                                                materialEffects.hue, materialEffects.bloomThreshold)
            uniform.transform = SIMD4<Float>(materialEffects.transformAngle, materialEffects.transformOffset.x,
                                             materialEffects.transformOffset.y, materialEffects.transformScale.x)
            uniform.transformScaleY = materialEffects.transformScale.y
            let textureFrame = textFrames[layerIndex]?.frame ?? self.textureFrame(for: entry, time: time)
            uniform.uvOrigin = textureFrame.uvOrigin
            uniform.uvAxisX = textureFrame.uvAxisX
            uniform.uvAxisY = textureFrame.uvAxisY
            if let plan = entry.layer.imageMaterial, let imageMaterials, imageMaterials.draw(plan, ImageMaterialRenderer.Draw(
                   layerID: entry.stateId, quad: draw.quad, sceneSize: sceneSize,
                   color: SIMD3(draw.color.x, draw.color.y, draw.color.z), alpha: draw.opacity, brightness: draw.brightness,
                   texture: dynamicTextures[layerIndex] ?? textureFrame.texture, contentSize: entry.layer.source.contentSize,
                   uvOrigin: textureFrame.uvOrigin, uvAxisX: textureFrame.uvAxisX, uvAxisY: textureFrame.uvAxisY,
                   sceneSnapshot: layerSnapshot, frame: effectFrame,
                   values: LiveSceneValueContext(time: sceneTime, scriptTime: sceneTime, layerId: entry.stateId),
                   assetTexture: { [unowned self] key, source in self.effectAssetTexture(key: key, source: source) },
                   ignoredAdjustments: !ImageMaterialRenderer.nativeAdjustmentsAreIdentity(uniform, brightness: draw.brightness)),
                   pixelFormat: sceneTexture.pixelFormat, encoder: encoder) {
                encoder.setRenderPipelineState(renderPipeline)
                continue
            }
            encoder.setVertexBytes(&uniform, length: MemoryLayout<LayerUniform>.stride, index: 0)
            encoder.setFragmentBytes(&uniform, length: MemoryLayout<LayerUniform>.stride, index: 0)
            encoder.setFragmentTexture(dynamicTextures[layerIndex] ?? textureFrame.texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        drawParticleBatches(before: .max)
        encoder.endEncoding()

        // Composite the scene-resolution render target onto the real drawable, applying placement exactly once.
        guard let compositeEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            commandBuffer.present(drawable)
            commandBuffer.commit()
            lastCommandBuffer = commandBuffer
            return
        }
        compositeEncoder.setRenderPipelineState(compositePipeline)
        var compositeUniform = layerUniform(position: sceneSize / 2, size: sceneSize, opacity: 1, drawableSize: realDrawableSize,
                                            placement: placement)
        let bloomMultiplier = AudioReactiveScriptEngine.shared.userPropertyValue("_owe_bloom", fallback: 1)
        let authoredBloom = bloom.enabled ? bloom.strength * bloomMultiplier : 0
        let userBloom = max(bloomMultiplier - 1, 0) * 1.2
        let bloomStrength = max(authoredBloom, userBloom)
        // The app's saturation and hue are linear in colour, so on the composite they equal applying
        // them to every layer, and layers keep drawing through their WE materials.
        compositeUniform.effects = SIMD4<Float>(1, 1, AudioReactiveScriptEngine.shared.userPropertyValue("_owe_saturation", fallback: 1),
                                                max(bloomStrength, 0))
        compositeUniform.colorEffects.z = AudioReactiveScriptEngine.shared.userPropertyValue("_owe_hue", fallback: 0)
        compositeUniform.colorEffects.w = bloom.enabled ? bloom.threshold : 0.55
        compositeUniform.bloomTint = SIMD4<Float>(bloom.tint.x, bloom.tint.y, bloom.tint.z, 1)
        // "_owe_blur" defaults to 1 (no extra blur); raising it above 1 blurs the whole composited scene,
        // independent of any per-layer material blur, so the slider is guaranteed to have an effect.
        let userBlur = AudioReactiveScriptEngine.shared.userPropertyValue("_owe_blur", fallback: 1)
        compositeUniform.blur = max(userBlur - 1, 0) * 4
        compositeEncoder.setVertexBytes(&compositeUniform, length: MemoryLayout<LayerUniform>.stride, index: 0)
        compositeEncoder.setFragmentBytes(&compositeUniform, length: MemoryLayout<LayerUniform>.stride, index: 0)
        compositeEncoder.setFragmentTexture(sceneTexture, index: 0)
        compositeEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        compositeEncoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
        lastCommandBuffer = commandBuffer
    }

    /// `g_ParallaxPosition`: `0.5 + (pointer − 0.5)·influence` while camera parallax is on, the
    /// centre otherwise. The influence is the scene's `cameraparallaxmouseinfluence`, or 1 when
    /// only the app's parallax toggle enabled it.
    private func parallaxPosition(pointer: SIMD2<Float>) -> SIMD2<Float> {
        if camera.parallax { return 0.5 + (pointer - 0.5) * camera.parallaxMouseInfluence }
        let appToggle = AudioReactiveScriptEngine.shared.userPropertyString("_owe_effect_enabled_parallax") == "true"
        return appToggle ? pointer : SIMD2(0.5, 0.5)
    }

    /// The scene's own `general.cameraparallax` / `camerashake` (possibly user-bound) or the app's toggles.
    private func cameraMotion(cursor: SIMD2<Float>, time: Float) -> CameraMotion {
        let parallaxEnabled = camera.parallax
            || AudioReactiveScriptEngine.shared.userPropertyString("_owe_effect_enabled_parallax") == "true"
        let parallaxAmount = AudioReactiveScriptEngine.shared.userPropertyValue("_owe_effect_parallax_amount", fallback: 1)
            * (camera.parallax ? camera.parallaxAmount * camera.parallaxMouseInfluence : 1)
        // Two decorrelated frequencies so the shake reads as a jitter rather than a circle.
        let shakeOffset: SIMD2<Float> = AudioReactiveScriptEngine.shared.cameraShakeEnabled || camera.shake
            ? SIMD2<Float>(sin(time * 47.3) * 0.004 + sin(time * 71.9) * 0.002,
                           cos(time * 53.1) * 0.004 + cos(time * 83.7) * 0.002) * sceneSize
            : .zero
        return CameraMotion(parallaxEnabled: parallaxEnabled, parallaxAmount: parallaxAmount,
                            cursorDelta: (cursor - sceneSize / 2) / sceneSize, shakeOffset: shakeOffset,
                            audioLevel: AudioReactiveScriptEngine.shared.audioLevel)
    }

    /// A visible layer's opacity, colour and placed quad this frame: user bindings, then
    /// scripts, then script-set state, then timeline, then authored.
    private func layerDraw(_ entry: PreparedLayer, baseSize: SIMD2<Float>, time: Float,
                           motion: CameraMotion) -> LayerDraw {
        let base = baseValues(entry, time: time)
        var opacity = entry.layer.opacityScript.map {
            AudioReactiveScriptEngine.shared.evaluate($0, fallback: base.opacity, layerId: entry.stateId, time: Double(time))
        } ?? SceneTimeline.value(entry.layer.opacityAnimation, at: time,
                           fallback: AudioReactiveScriptEngine.shared.layerValue(entry.stateId, property: "alpha", fallback: base.opacity))
        if entry.layer.text != nil {
            opacity *= AudioReactiveScriptEngine.shared.userPropertyValue("_owe_text_\(entry.layer.id)_opacity", fallback: 1)
        }
        var local = evaluatedLocal(entry, time: time)
        // Layers without an authored parallax depth stay put, as in Wallpaper Engine.
        let parallaxDepth = entry.layer.parallaxDepth
        let parallaxOffset = motion.parallaxEnabled
            ? SIMD2<Float>(parallaxDepth.x * motion.cursorDelta.x * sceneSize.x * 0.18 * motion.parallaxAmount,
                           parallaxDepth.y * motion.cursorDelta.y * sceneSize.y * 0.18 * motion.parallaxAmount)
            : .zero
        let perspectiveScale = motion.parallaxEnabled && entry.layer.perspective
            ? 1 + parallaxDepth.z * simd_length(motion.cursorDelta) * 0.18 * motion.parallaxAmount
            : 1
        let musicSyncLevel = entry.layer.musicSync?.levelSource.map { $0() } ?? motion.audioLevel
        local.scale *= perspectiveScale * (1 + (entry.layer.musicSync?.zoomAmount ?? 0) * Float(musicSyncLevel))
        local.angle += entry.layer.musicSync.map { $0.tiltAmount * Float(musicSyncLevel) * .pi / 180 } ?? 0
        let quad = SceneQuadGeometry(world: parentWorld(entry, time: time) * SceneAffineTransform(local),
                                     size: baseSize, alignment: entry.layer.alignment)
        let extent = quad.extent
        let center = quad.center + parallaxOffset + motion.shakeOffset
        let safeCenter = SIMD2<Float>(
            safeParallaxPosition(center.x, baseSize: extent.x, sceneExtent: sceneSize.x),
            safeParallaxPosition(center.y, baseSize: extent.y, sceneExtent: sceneSize.y)
        )
        let brightness = entry.layer.brightnessScript.map {
            AudioReactiveScriptEngine.shared.evaluate($0, fallback: base.brightness, layerId: entry.stateId, time: Double(time))
        } ?? base.brightness
        let color = entry.layer.colorScript.flatMap {
            AudioReactiveScriptEngine.shared.evaluateVector3($0,
                fallback: SIMD3<Float>(base.color.x, base.color.y, base.color.z),
                layerId: entry.stateId, time: Double(time))
        }.map { SIMD4<Float>($0.x, $0.y, $0.z, 1) } ?? base.color
        return LayerDraw(opacity: opacity, color: color, brightness: brightness,
                         quad: SceneQuadGeometry(center: safeCenter, axisX: quad.axisX, axisY: quad.axisY),
                         musicSyncLevel: musicSyncLevel)
    }

    /// The layer's unscaled size this frame: script, then script-set state, then timeline, then authored.
    private func layerBaseSize(_ entry: PreparedLayer, time: Float) -> SIMD2<Float> {
        entry.layer.sizeScript.flatMap {
            AudioReactiveScriptEngine.shared.evaluateVector2($0, fallback: entry.layer.size, layerId: entry.stateId,
                                                             time: Double(time))
        }
            ?? AudioReactiveScriptEngine.shared.layerVector2(entry.stateId, property: "size",
                fallback: vector2(SceneTimeline.vector3(entry.layer.sizeAnimation, at: time,
                    fallback: SIMD3<Float>(entry.layer.size.x, entry.layer.size.y, 0))))
    }

    /// A text layer's current string, laid out and rasterised (through the text cache) at
    /// `pixelsPerUnit`, with the block size the layout settled on.
    private func layerTextFrame(_ entry: PreparedLayer, boxSize: SIMD2<Float>, pixelsPerUnit: Float,
                                time: Float) -> (frame: RenderTextureFrame, baseSize: SIMD2<Float>) {
        guard let text = entry.layer.text else { return (textureFrame(for: entry, time: time), boxSize) }
        let value: String
        if let scripted = AudioReactiveScriptEngine.shared.layerString(entry.stateId, property: "text") {
            // Scripts assign layer.text directly for score counters, now-playing labels, etc.
            value = scripted
        } else {
            value = text.script.map {
                AudioReactiveScriptEngine.shared.evaluateString($0, fallback: text.value,
                                                                  layerId: entry.stateId, time: Double(time))
            } ?? text.value
        }
        return makeTextFrame(text, value: value, boxSize: boxSize, pixelsPerUnit: pixelsPerUnit,
                             layerID: entry.layer.id, stateKey: entry.stateId)
            ?? (textureFrame(for: entry, time: time), boxSize)
    }

    // MARK: - Transforms

    private func beginTransformFrame() {
        frameLocals.removeAll(keepingCapacity: true)
        layerIndexByStateId.removeAll(keepingCapacity: true)
        for (index, entry) in layers.enumerated() { layerIndexByStateId[entry.stateId] = index }
    }

    /// A layer's authored values moved by its user bindings: the base that scripts and
    /// animations start from.
    private func baseValues(_ entry: PreparedLayer, time: Float) -> SceneLayerBaseValues {
        entry.layer.bindings.isEmpty
            ? SceneLayerBaseValues(entry.layer)
            : entry.layer.bindings.baseValues(for: entry.layer,
                                              in: LiveSceneValueContext(time: Double(time), scriptTime: Double(time),
                                                                    layerId: entry.stateId))
    }

    private func evaluatedLocal(_ entry: PreparedLayer, time: Float) -> SceneLocalTransform {
        objectLocal(entry.motion, stateId: entry.stateId, time: time)
    }

    /// An object's own transform this frame (`SceneObjectMotion.local`), evaluated once per frame.
    private func objectLocal(_ motion: SceneObjectMotion, stateId: String, time: Float) -> SceneLocalTransform {
        if let cached = frameLocals[stateId] { return cached }
        let local = motion.local(at: time, stateId: stateId)
        frameLocals[stateId] = local
        return local
    }

    /// This frame's own transform of any object: a drawn layer's, or another object's (groups,
    /// particle systems) from its motion. Nil for an object without either.
    private func liveLocal(_ id: String, time: Float) -> SceneLocalTransform? {
        if let index = layerIndexByStateId[id] { return evaluatedLocal(layers[index], time: time) }
        return objectMotions[id].map { objectLocal($0, stateId: id, time: time) }
    }

    /// The full transform of a layer's ancestors this frame. Every ancestor uses its live
    /// (scripted, animated) transform, so moving a parent moves its children.
    private func parentWorld(_ entry: PreparedLayer, time: Float) -> SceneAffineTransform {
        transforms.parentWorld(of: entry.layer.id) { [self] id in liveLocal(id, time: time) }
    }

    /// A particle system's emitter transform this frame: its object's, parents included.
    private func emitterWorld(_ configuration: SceneMetalParticleSystem, time: Float) -> SceneAffineTransform? {
        guard let id = configuration.objectID else { return nil }
        return transforms.world(of: id) { [self] id in liveLocal(id, time: time) }
    }

    private func worldTransform(_ entry: PreparedLayer, time: Float) -> SceneAffineTransform {
        parentWorld(entry, time: time) * SceneAffineTransform(evaluatedLocal(entry, time: time))
    }

    /// Hands the vertex stage the quad's full axes (parent rotation and non-uniform scale), in
    /// the same placement space `layerUniform` put its centre in.
    private func setQuadAxes(_ uniform: inout LayerUniform, quad: SceneQuadGeometry) {
        let extent = quad.extent
        let placementScale = SIMD2<Float>(extent.x > 0 ? uniform.size.x / extent.x : 1,
                                          extent.y > 0 ? uniform.size.y / extent.y : 1)
        uniform.quadAxisX = quad.axisX * placementScale
        uniform.quadAxisY = quad.axisY * placementScale
        uniform.rotation = 0
    }

    private func runEffects(_ entry: PreparedLayer, draw: LayerDraw, input: MTLTexture, snapshot: MTLTexture?,
                            frame: BuiltinFrameContext, commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        guard let effectGraph, !entry.layer.weEffects.isEmpty else { return nil }
        var context = EffectGraphRenderer.Context(
            frame: frame,
            values: LiveSceneValueContext(time: frame.time, scriptTime: frame.time, layerId: entry.stateId),
            assetTexture: { [unowned self] key, source in self.effectAssetTexture(key: key, source: source) },
            sceneSnapshot: snapshot,
            // The scripted/animated values the layer is drawn with this frame, not the authored ones.
            layerColor: SIMD3(draw.color.x, draw.color.y, draw.color.z),
            layerAlpha: draw.opacity)
        context.assetContentSize = { _, source in source.contentSize }
        return effectGraph.apply(entry.layer.weEffects, to: input, layerID: entry.stateId,
                                 context: context, commandBuffer: commandBuffer)
    }

    /// A copy of the scene drawn so far. Several scene-reading layers in one frame may share the
    /// pooled texture: the GPU runs the command buffer in order, so each layer's effects read its
    /// snapshot before the next layer's copy overwrites it.
    private func sceneSnapshot(of scene: MTLTexture, commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        guard let copy = renderTargetPool.texture(width: scene.width, height: scene.height,
                                                  pixelFormat: scene.pixelFormat, avoiding: scene),
              let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: scene, to: copy)
        blit.endEncoding()
        return copy
    }

    /// The scene under a scene-input layer, as that layer's base image (`SceneRegionResample`).
    /// A quad that is exactly the scene (composition and fullscreen layers) uses the snapshot as is.
    private func sceneRegion(of snapshot: MTLTexture, under quad: SceneQuadGeometry,
                             commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        if SceneRegionResample.coversWholeScene(quad, sceneSize: sceneSize) { return snapshot }
        guard let size = SceneRegionResample.targetSize(quad, pixelsPerUnit: renderPixelsPerUnit),
              let region = renderTargetPool.texture(width: size.x, height: size.y,
                                                    pixelFormat: snapshot.pixelFormat, avoiding: snapshot) else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = region
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        var uniform = SceneRegionResample.uniform(quad, sceneSize: sceneSize, targetSize: size)
        encoder.setRenderPipelineState(copyPipeline)
        encoder.setVertexBytes(&uniform, length: MemoryLayout<LayerUniform>.stride, index: 0)
        encoder.setFragmentBytes(&uniform, length: MemoryLayout<LayerUniform>.stride, index: 0)
        encoder.setFragmentTexture(snapshot, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        return region
    }

    private func effectAssetTexture(key: String, source: SceneMetalTextureSource) -> MTLTexture? {
        if let cached = effectAssetTextures[key] { return cached }
        guard let texture = makeTextureFrames(from: source)?.first?.texture else { return nil }
        effectAssetTextures[key] = texture
        return texture
    }

    private func safeParallaxPosition(_ position: Float, baseSize: Float, sceneExtent: Float) -> Float {
        guard baseSize >= sceneExtent else { return position }
        let minimum = baseSize / 2
        let maximum = sceneExtent - baseSize / 2
        return min(max(position, minimum), maximum)
    }







    /// The scene target, at `renderPixelsPerUnit` pixels per scene unit.
    private func sceneRenderTarget(matching descriptor: MTLRenderPassDescriptor) -> MTLTexture? {
        let pixelSize = SceneRenderResolution.targetSize(sceneSize: sceneSize, pixelsPerUnit: renderPixelsPerUnit)
        if let sceneRenderTarget, sceneRenderTargetSize == pixelSize { return sceneRenderTarget }

        let pixelFormat = descriptor.colorAttachments[0].texture?.pixelFormat ?? .bgra8Unorm
        // Owned outright, not pooled: the scene is drawn into for the whole frame, so a pooled
        // scratch request of the same size (a scene-input region) must never be handed it.
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: pixelSize.x,
                                                                         height: pixelSize.y, mipmapped: false)
        textureDescriptor.usage = [.renderTarget, .shaderRead]
        textureDescriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
            OWELog.error(.scene, "Could not allocate the \(pixelSize.x)×\(pixelSize.y) scene target")
            return nil
        }
        sceneRenderTarget = texture
        sceneRenderTargetSize = pixelSize
        return texture
    }

    /// `layerID` is the authored layer (its user text settings); `stateKey` is this instance's
    /// state id, which differs for script clones so they don't share cached text.
    private func makeTextFrame(_ text: SceneMetalText, value: String, boxSize: SIMD2<Float>, pixelsPerUnit: Float,
                               layerID: String, stateKey: String) -> (frame: RenderTextureFrame, baseSize: SIMD2<Float>)? {
        let fontName = AudioReactiveScriptEngine.shared.userPropertyString("_owe_text_\(layerID)_font") ?? ""
        let sizeValue = AudioReactiveScriptEngine.shared.userPropertyValue("_owe_text_\(layerID)_size", fallback: Float(text.pointSize))
        let bold = AudioReactiveScriptEngine.shared.userPropertyString("_owe_text_\(layerID)_bold") == "true"
        let italic = AudioReactiveScriptEngine.shared.userPropertyString("_owe_text_\(layerID)_italic") == "true"
        let colorValue = AudioReactiveScriptEngine.shared.userPropertyString("_owe_text_\(layerID)_color") ?? "1 1 1"
        let rasterScale = SceneTextRasterScale.retained(SceneTextRasterScale.quantized(pixelsPerUnit),
                                                        previous: textRasterScales[stateKey])
        textRasterScales[stateKey] = rasterScale
        let cacheKey = "\(stateKey)|\(value)|\(boxSize.x)|\(boxSize.y)|\(fontName)|\(sizeValue)|\(bold)|\(italic)|\(colorValue)|\(rasterScale)"
        if let cached = textFrameCache.value(for: cacheKey) { return cached }

        let requestedFont = fontName.isEmpty ? (text.font ?? "System") : fontName
        let pixelSize = SceneTextLayout.pixelSize(pointSize: CGFloat(sizeValue))
        var font = SceneFontRegistry.font(named: requestedFont, size: pixelSize)
            ?? NSFont(name: requestedFont, size: pixelSize)
            ?? NSFont.systemFont(ofSize: pixelSize)
        if bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        let layout = SceneTextLayout(text: value, font: font, authoredSize: boxSize, padding: text.padding,
                                     horizontalAlignment: text.horizontalAlignment, verticalAlignment: text.verticalAlignment,
                                     maxWidth: text.maxWidth, maxRows: text.maxRows, useEllipsis: text.useEllipsis)
        // Authored colour, alpha and brightness are applied when the quad is drawn, as for images.
        let rgb = colorValue.parseVector3()
        let color = NSColor(srgbRed: CGFloat(rgb.0), green: CGFloat(rgb.1), blue: CGFloat(rgb.2), alpha: 1)
        let pixels = SceneTextRasterScale.clamped(rasterScale, boxSize: layout.boxSize)
        guard let image = layout.rasterize(font: font, color: color, pixelsPerUnit: CGFloat(pixels)),
              let texture = try? SceneTextureUpload.texture(from: image, loader: textureLoader, device: device) else {
            OWELog.error(.scene, "Text layer \(layerID): could not rasterise \(layout.boxSize) at \(pixels) px/unit")
            return nil
        }
        let entry = (RenderTextureFrame(texture: texture, duration: .greatestFiniteMagnitude,
                                        uvOrigin: .zero, uvAxisX: SIMD2(1, 0), uvAxisY: SIMD2(0, 1)), layout.boxSize)
        // Strings change every second for clocks; the LRU keeps the live ones and drops the rest.
        textFrameCache.insert(entry, for: cacheKey)
        return entry
    }

    /// Maps a scene-unit position and size onto `drawableSize` pixels. Scene draws use
    /// `.stretch` (the target has the scene's aspect); the composite uses the user's placement.
    private func layerUniform(position: SIMD2<Float>, size: SIMD2<Float>, opacity: Float,
                              drawableSize: SIMD2<Float>, placement: WallpaperPlacement) -> LayerUniform {
        let scale: Float
        switch placement {
        case .stretch:
            return LayerUniform(position: SIMD2<Float>(position.x * drawableSize.x / sceneSize.x,
                                                        position.y * drawableSize.y / sceneSize.y),
                                size: SIMD2<Float>(size.x * drawableSize.x / sceneSize.x,
                                                   size.y * drawableSize.y / sceneSize.y),
                                sceneSize: drawableSize, opacity: opacity, particleShape: 0, rotation: 0, color: SIMD4<Float>(repeating: 1),
                                uvOrigin: .zero, uvAxisX: SIMD2<Float>(1, 0), uvAxisY: SIMD2<Float>(0, 1),
                                effects: SIMD4<Float>(1, 1, 1, 0), blur: 0,
                                colorEffects: SIMD4<Float>(0, 1, 0, 0.7), transform: SIMD4<Float>(0, 0, 0, 1),
                                transformScaleY: 1)
        case .fill, .zoom, .fit, .center:
            scale = ScenePlacementScale.scale(for: placement, sceneSize: sceneSize, drawableSize: drawableSize,
                                              pixelsPerPoint: drawablePixelsPerPoint)
        }
        let offset = (drawableSize - sceneSize * scale) / 2
        return LayerUniform(position: SIMD2<Float>(position.x * scale + offset.x,
                                                   position.y * scale + (drawableSize.y - sceneSize.y * scale - offset.y)),
                            size: size * scale, sceneSize: drawableSize, opacity: opacity,
                            particleShape: 0, rotation: 0, color: SIMD4<Float>(repeating: 1),
                            uvOrigin: .zero, uvAxisX: SIMD2<Float>(1, 0), uvAxisY: SIMD2<Float>(0, 1),
                            effects: SIMD4<Float>(1, 1, 1, 0), blur: 0,
                            colorEffects: SIMD4<Float>(0, 1, 0, 0.7), transform: SIMD4<Float>(0, 0, 0, 1),
                            transformScaleY: 1)
    }

    /// The cursor in scene units, or nil while it is on another display.
    private func sceneCursor(in view: MTKView, drawableSize: SIMD2<Float>) -> SIMD2<Float>? {
        guard let window = view.window,
              let screen = window.screen,
              screen.frame.contains(NSEvent.mouseLocation) else {
            return nil
        }
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let mouse = view.convert(windowPoint, from: nil)
        let drawablePoint = SIMD2<Float>(Float(mouse.x) * drawableSize.x / Float(max(view.bounds.width, 1)),
                                         Float(mouse.y) * drawableSize.y / Float(max(view.bounds.height, 1)))
        return ScenePlacementScale.scenePoint(drawablePoint: drawablePoint, placement: placement, sceneSize: sceneSize,
                                              drawableSize: drawableSize, pixelsPerPoint: drawablePixelsPerPoint)
    }

    private func makeTextureFrames(from source: SceneMetalTextureSource) -> [RenderTextureFrame]? {
        switch source {
        case let .image(image):
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            let texture: MTLTexture
            do {
                texture = try SceneTextureUpload.texture(from: cgImage, loader: textureLoader, device: device)
            } catch {
                OWELog.error(.scene, "Could not upload a \(cgImage.width)×\(cgImage.height) image: \(error)")
                return nil
            }
            return [RenderTextureFrame(texture: texture, duration: .greatestFiniteMagnitude,
                                       uvOrigin: .zero, uvAxisX: SIMD2<Float>(1, 0), uvAxisY: SIMD2<Float>(0, 1))]
        case let .dxt(source):
            guard let texture = makeDXTTexture(source) else { return nil }
            let crop = Self.contentUVExtent(source)
            return [RenderTextureFrame(texture: texture, duration: .greatestFiniteMagnitude,
                                       uvOrigin: .zero, uvAxisX: SIMD2<Float>(crop.x, 0), uvAxisY: SIMD2<Float>(0, crop.y))]
        case let .video(stream):
            // Stand-in until the first frame decodes; draw() swaps in the live texture.
            guard let texture = stream.currentTexture() ?? makePlaceholderTexture() else { return nil }
            return [RenderTextureFrame(texture: texture, duration: .greatestFiniteMagnitude,
                                       uvOrigin: .zero, uvAxisX: SIMD2<Float>(1, 0), uvAxisY: SIMD2<Float>(0, 1))]
        case let .animated(animation):
            let textures = animation.images.compactMap { image -> MTLTexture? in
                guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
                do {
                    return try SceneTextureUpload.texture(from: cgImage, loader: textureLoader, device: device)
                } catch {
                    OWELog.error(.scene, "Could not upload a \(cgImage.width)×\(cgImage.height) animation frame: \(error)")
                    return nil
                }
            }
            guard textures.count == animation.images.count else { return nil }
            return animation.frames.compactMap { frame in
                guard frame.imageIndex < textures.count else { return nil }
                // Frame rects are in the atlas's pixels; the texture was made from those pixels,
                // whatever size in points the image reports. WidthY/HeightX shear or turn the rect.
                let atlas = textures[frame.imageIndex]
                let atlasSize = SIMD2<Float>(Float(atlas.width), Float(atlas.height))
                guard atlasSize.x > 0, atlasSize.y > 0 else { return nil }
                return RenderTextureFrame(texture: textures[frame.imageIndex], duration: frame.duration,
                                          uvOrigin: SIMD2<Float>(frame.x, frame.y) / atlasSize,
                                          uvAxisX: SIMD2<Float>(frame.width, frame.widthY) / atlasSize,
                                          uvAxisY: SIMD2<Float>(frame.heightX, frame.height) / atlasSize)
            }
        }
    }

    /// The part of a padded .tex allocation the image covers, in UV units: the quad samples only
    /// the image, never the padding around it.
    static func contentUVExtent(_ texture: TEXCompressedTexture) -> SIMD2<Float> {
        guard texture.width > 0, texture.height > 0, texture.contentWidth > 0, texture.contentHeight > 0 else {
            return SIMD2(1, 1)
        }
        return simd_min(SIMD2(Float(texture.contentWidth) / Float(texture.width),
                              Float(texture.contentHeight) / Float(texture.height)), SIMD2(1, 1))
    }

    private func makePlaceholderTexture() -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        var pixel: UInt32 = 0
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &pixel, bytesPerRow: 4)
        return texture
    }

    private func textureFrame(for entry: PreparedLayer, time: Float) -> RenderTextureFrame {
        // A video layer's texture is replaced every frame, so the decoded frame list is only a seed.
        if case let .video(stream) = entry.layer.source, let texture = stream.currentTexture() {
            return RenderTextureFrame(texture: texture, duration: .greatestFiniteMagnitude,
                                      uvOrigin: .zero, uvAxisX: SIMD2<Float>(1, 0), uvAxisY: SIMD2<Float>(0, 1))
        }
        guard entry.frames.count > 1 else { return entry.frames[0] }
        let duration = entry.frameDuration
        guard duration > 0 else { return entry.frames[0] }
        var frameTime = time.truncatingRemainder(dividingBy: duration)
        for frame in entry.frames {
            if frameTime < frame.duration { return frame }
            frameTime -= frame.duration
        }
        return entry.frames[0]
    }

    private func vector2(_ value: SIMD3<Float>) -> SIMD2<Float> {
        SIMD2<Float>(value.x, value.y)
    }
    private func spriteSheetUV(for particle: Particle,
                               configuration: SceneMetalParticleSystem) -> (origin: SIMD2<Float>, size: SIMD2<Float>) {
        guard let sheet = configuration.spriteSheet, sheet.frames > 0 else {
            return (.zero, SIMD2<Float>(repeating: 1))
        }
        let frame: Int
        switch configuration.animationMode {
        case "randomframe":
            frame = particle.spriteFrame % sheet.frames
        case "once":
            frame = min(Int((particle.age / particle.lifetime) * Float(sheet.frames) * configuration.sequenceMultiplier), sheet.frames - 1)
        default:
            let duration = max(sheet.duration, 0.001)
            frame = Int((particle.age * configuration.sequenceMultiplier / duration * Float(sheet.frames))) % sheet.frames
        }
        let column = frame % sheet.columns
        let row = frame / sheet.columns
        let size = SIMD2<Float>(1 / Float(sheet.columns), 1 / Float(sheet.rows))
        return (SIMD2<Float>(Float(column) * size.x, Float(row) * size.y), size)
    }

    private func makeDXTTexture(_ source: TEXCompressedTexture) -> MTLTexture? {
        // DXT1/3/5 are BC1/BC2/BC3. Apple Silicon Macs consume those natively, so upload the
        // blocks as-is instead of expanding them to rgba8Unorm through the decode kernel.
        if let native = nativeBlockFormat(for: source.format), device.supportsBCTextureCompression {
            return makeBlockCompressedTexture(source, pixelFormat: native.pixelFormat,
                                              bytesPerBlock: native.bytesPerBlock)
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                                    width: source.width, height: source.height,
                                                                    mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor),
              let input = device.makeBuffer(bytes: source.data, length: source.data.count, options: .storageModeShared),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }

        var uniform = DXTDecodeUniform(width: UInt32(source.width), height: UInt32(source.height),
                                       blockColumns: UInt32((source.width + 3) / 4), format: source.format)
        encoder.setComputePipelineState(dxtDecodePipeline)
        encoder.setBuffer(input, offset: 0, index: 0)
        encoder.setTexture(texture, index: 0)
        encoder.setBytes(&uniform, length: MemoryLayout<DXTDecodeUniform>.stride, index: 1)
        let threads = MTLSize(width: 8, height: 8, depth: 1)
        encoder.dispatchThreads(MTLSize(width: source.width, height: source.height, depth: 1), threadsPerThreadgroup: threads)
        encoder.endEncoding()
        commandBuffer.commit()
        // Keep the decode asynchronous. Metal command buffers on the same queue
        // preserve ordering, so later scene draws wait on this texture on-GPU
        // without blocking the render/content thread here.
        return texture
    }

    private func nativeBlockFormat(for format: UInt32) -> (pixelFormat: MTLPixelFormat, bytesPerBlock: Int)? {
        switch format {
        case 4: return (.bc3_rgba, 16)   // DXT5
        case 6: return (.bc2_rgba, 16)   // DXT3
        case 7: return (.bc1_rgba, 8)    // DXT1
        case 12: return (.bc7_rgbaUnorm, 16)
        default: return nil
        }
    }

    private func makeBlockCompressedTexture(_ source: TEXCompressedTexture,
                                            pixelFormat: MTLPixelFormat,
                                            bytesPerBlock: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat,
                                                                    width: source.width, height: source.height,
                                                                    mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        let blockBytesPerRow = ((source.width + 3) / 4) * bytesPerBlock
        let requiredBytes = blockBytesPerRow * ((source.height + 3) / 4)
        // A truncated payload would read out of bounds inside replace(region:).
        guard source.data.count >= requiredBytes,
              let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, source.width, source.height),
                        mipmapLevel: 0, withBytes: source.data, bytesPerRow: blockBytesPerRow)
        return texture
    }

    private func appendParticleTrail(_ particle: Particle, system: ParticleSystemRuntime,
                                     drawableSize: SIMD2<Float>) {
        let speed = simd_length(particle.velocity)
        let stretch = max(system.configuration.trailLength, 1)
        let length = max(particle.size, min(particle.size * stretch, particle.size + speed * 0.08))
        let width = system.configuration.refractive ? max(2, particle.size * 0.08) : particle.size
        var uniform = layerUniform(position: particle.position,
                                   size: SIMD2<Float>(width, length),
                                   opacity: particleOpacity(particle, in: system), drawableSize: drawableSize, placement: .stretch)
        uniform.rotation = speed > 0.01 ? atan2(particle.velocity.y, particle.velocity.x) - .pi / 2 : particle.rotation
        uniform.color = particle.color
        let uv = spriteSheetUV(for: particle, configuration: system.configuration)
        uniform.uvOrigin = uv.origin
        uniform.uvAxisX = SIMD2<Float>(uv.size.x, 0)
        uniform.uvAxisY = SIMD2<Float>(0, uv.size.y)
        particleInstances.append(uniform)
    }

    /// Grows geometrically so a system that ramps up to its particle cap stops reallocating.
    private func particleInstanceBuffer(for count: Int) -> MTLBuffer? {
        guard count > 0 else { return nil }
        let needed = MemoryLayout<LayerUniform>.stride * count
        if let buffer = particleInstanceStorage, buffer.length >= needed { return buffer }
        particleInstanceStorage = device.makeBuffer(length: max(needed * 2, 64 * MemoryLayout<LayerUniform>.stride),
                                                    options: .storageModeShared)
        return particleInstanceStorage
    }

    /// Draws one rope per particle through its own position history, rather than one rope through
    /// the whole system as `rope` does.
    private func appendRopeTrail(_ particle: Particle, system: ParticleSystemRuntime,
                                 drawableSize: SIMD2<Float>) {
        let configuration = system.configuration
        var trail = particle.orderedHistory
        // The newest sample lags by up to one interval, so close the gap to the particle itself.
        trail.append(particle.position)
        guard trail.count > 1 else { return }

        let opacity = particleOpacity(particle, in: system)
        let subdivision = max(configuration.ropeSubdivision, 1)
        var spline: [SIMD2<Float>] = []
        for index in 0..<(trail.count - 1) {
            let previous = trail[index > 0 ? index - 1 : index]
            let start = trail[index]
            let end = trail[index + 1]
            let following = trail[index + 2 < trail.count ? index + 2 : index + 1]
            for step in 0..<subdivision {
                spline.append(catmullRom(previous, start, end, following, Float(step) / Float(subdivision)))
            }
        }
        spline.append(trail[trail.count - 1])

        let uv = spriteSheetUV(for: particle, configuration: configuration)
        for index in 0..<(spline.count - 1) {
            let start = spline[index]
            let end = spline[index + 1]
            let delta = end - start
            let length = simd_length(delta)
            guard length > 0.01 else { continue }
            // 0 at the oldest sample, 1 at the particle itself.
            let progress = Float(index + 1) / Float(spline.count - 1)
            let width = configuration.fadeTrailSize ? particle.size * progress : particle.size
            var uniform = layerUniform(position: (start + end) / 2,
                                       size: SIMD2<Float>(length, max(width, 0.01)),
                                       opacity: configuration.fadeTrailAlpha ? opacity * progress : opacity,
                                       drawableSize: drawableSize, placement: .stretch)
            uniform.rotation = atan2(delta.y, delta.x)
            uniform.color = particle.color
            uniform.uvOrigin = uv.origin
            uniform.uvAxisX = SIMD2<Float>(uv.size.x, 0)
            uniform.uvAxisY = SIMD2<Float>(0, uv.size.y)
            particleInstances.append(uniform)
        }
    }

    private func appendRope(_ system: ParticleSystemRuntime, drawableSize: SIMD2<Float>) {        let particles = system.particles
        guard particles.count > 1 else { return }
        var spline: [(position: SIMD2<Float>, size: Float, color: SIMD4<Float>, opacity: Float)] = []
        let subdivision = max(system.configuration.ropeSubdivision, 1)
        for index in 0..<(particles.count - 1) {
            let previous = particles[index > 0 ? index - 1 : index]
            let start = particles[index]
            let end = particles[index + 1]
            let following = particles[index + 2 < particles.count ? index + 2 : index + 1]
            for step in 0..<subdivision {
                let t = Float(step) / Float(subdivision)
                spline.append((catmullRom(previous.position, start.position, end.position, following.position, t),
                               start.size + (end.size - start.size) * t,
                               simd_mix(start.color, end.color, SIMD4<Float>(repeating: t)),
                               particleOpacity(start, in: system)
                                   + (particleOpacity(end, in: system) - particleOpacity(start, in: system)) * t))
            }
        }
        if let last = particles.last {
            spline.append((last.position, last.size, last.color, particleOpacity(last, in: system)))
        }
        for index in 0..<(spline.count - 1) {
            let start = spline[index]
            let end = spline[index + 1]
            let delta = end.position - start.position
            let length = simd_length(delta)
            guard length > 0.01 else { continue }
            let averageSize = (start.size + end.size) / 2
            var uniform = layerUniform(position: (start.position + end.position) / 2,
                                       size: SIMD2<Float>(length, averageSize),
                                       opacity: (start.opacity + end.opacity) / 2,
                                       drawableSize: drawableSize, placement: .stretch)
            uniform.rotation = atan2(delta.y, delta.x)
            uniform.color = (start.color + end.color) / 2
            particleInstances.append(uniform)
        }
    }

    private func catmullRom(_ previous: SIMD2<Float>, _ start: SIMD2<Float>, _ end: SIMD2<Float>,
                            _ following: SIMD2<Float>, _ t: Float) -> SIMD2<Float> {        let t2 = t * t
        let t3 = t2 * t
        // Split into terms so older compilers type-check it in reasonable time.
        let a: SIMD2<Float> = 2 * start
        let b: SIMD2<Float> = (end - previous) * t
        let c1: SIMD2<Float> = 2 * previous - 5 * start
        let c: SIMD2<Float> = (c1 + 4 * end - following) * t2
        let d1: SIMD2<Float> = 3 * start - previous
        let d: SIMD2<Float> = (d1 - 3 * end + following) * t3
        return 0.5 * (a + b + c + d)
    }

    private func particleOpacity(_ particle: Particle, in system: ParticleSystemRuntime) -> Float {
        let progress = particle.age / particle.lifetime
        let fadeIn = system.fadeIn > 0 ? min(progress / system.fadeIn, 1) : 1
        let fadeOut = system.fadeOut < 1 ? min((1 - progress) / (1 - system.fadeOut), 1) : 1
        return particle.alpha * fadeIn * fadeOut * system.configuration.opacityMultiplier
    }
}
/// WE keeps the pointer where it left a display rather than recentring it, and reports no
/// button pressed while it is elsewhere; a jump to the centre would kick pointer-driven effects.
struct SceneCursorTracker {
    private(set) var lastPosition: SIMD2<Float>?

    /// `live` is nil while the cursor is on another display.
    mutating func update(_ live: SIMD2<Float>?, sceneSize: SIMD2<Float>) -> (position: SIMD2<Float>, onDisplay: Bool) {
        if let live {
            lastPosition = live
            return (live, true)
        }
        return (lastPosition ?? sceneSize / 2, false)
    }
}
