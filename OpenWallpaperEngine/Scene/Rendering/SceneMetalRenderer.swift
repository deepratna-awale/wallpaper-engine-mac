import Cocoa
import MetalKit
import CryptoKit

private struct PreparedLayer {
    let frames: [RenderTextureFrame]
    let frameDuration: Float
    let layer: SceneMetalLayer
    // At most 4 mask textures can be bound per draw; effectMaskSlots maps each sceneEffects
    // position to its bound slot (0...3) in effectMasks, or nil if it has no mask / didn't fit.
    let effectMasks: [MTLTexture]
    let effectMaskSlots: [Int?]
    /// Blend sources share the same four texture slots as masks.
    let effectBlendSlots: [Int?]
    let xrayTexture: MTLTexture?
    /// Key used for script-driven state. Layers cloned by `thisScene.createLayer` share their
    /// source's textures but track their own transform under a different id.
    var stateId: String

    init(frames: [RenderTextureFrame], frameDuration: Float, layer: SceneMetalLayer,
         effectMasks: [MTLTexture], effectMaskSlots: [Int?], effectBlendSlots: [Int?] = [],
         xrayTexture: MTLTexture?,
         stateId: String? = nil) {
        self.frames = frames
        self.frameDuration = frameDuration
        self.layer = layer
        self.effectMasks = effectMasks
        self.effectMaskSlots = effectMaskSlots
        self.effectBlendSlots = effectBlendSlots
        self.xrayTexture = xrayTexture
        self.stateId = stateId ?? layer.id
    }
}

private struct RenderTextureFrame {
    let texture: MTLTexture
    let duration: Float
    let uvOrigin: SIMD2<Float>
    let uvAxisX: SIMD2<Float>
    let uvAxisY: SIMD2<Float>
}

private struct Particle {
    var position: SIMD2<Float>
    var velocity: SIMD2<Float>
    var age: Float
    let lifetime: Float
    var size: Float
    let baseSize: Float
    var alpha: Float
    let baseAlpha: Float
    var rotation: Float
    var angularVelocity: Float
    var color: SIMD4<Float>
    let baseColor: SIMD4<Float>
    let spriteFrame: Int
    var history: [SIMD2<Float>]
    var historyStart: Int
    var historyTimer: Float = 0
    /// Normalised position along a control-point sequence, 0 at the start point and 1 at the end.
    var sequence: Float = 0

    /// `history` is a circular buffer; this returns it oldest-first so a trail can be walked.
    var orderedHistory: [SIMD2<Float>] {
        guard historyStart > 0, historyStart < history.count else { return history }
        return Array(history[historyStart...] + history[..<historyStart])
    }
}

private final class ParticleSystemRuntime {
    let texture: MTLTexture
    let configuration: SceneMetalParticleSystem
    var particles: [Particle] = []
    var emissionRemainder: Float = 0
    var elapsedTime: Float = 0
    var spawnCounter: Int = 0
    var fadeIn: Float
    var fadeOut: Float

    init(texture: MTLTexture, configuration: SceneMetalParticleSystem) {
        self.texture = texture
        self.configuration = configuration
        self.fadeIn = configuration.fadeIn
        self.fadeOut = configuration.fadeOut
    }
}

final class SceneMetalRenderer: NSObject, MTKViewDelegate {
    /// Authored masks bound per layer. Stacking several masked effects on one object is common
    /// (a shine plus a handful of shakes), and anything past this renders unmasked.
    /// Must match `kMaxEffectMasks` and the `masks` array length in SceneShaders.metal.
    static let maxEffectMasks = 32
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let renderPipeline: MTLRenderPipelineState
    private let additiveRenderPipeline: MTLRenderPipelineState
    private let dxtDecodePipeline: MTLComputePipelineState
    private let textureLoader: MTKTextureLoader
    private let renderTargetPool: SceneRenderTargetPool
    private let dynamicEffectPipelines: DynamicEffectPipelineCache
    private let contentQueue = DispatchQueue(label: "SceneMetalRenderer.content", qos: .userInitiated)
    private let contentGenerationLock = NSLock()
    private var contentGeneration = 0
    private var sceneSize = SIMD2<Float>(1920, 1080)
    private var layers: [PreparedLayer] = []
    private var particleInstances: [LayerUniform] = []
    private var particleInstanceStorage: MTLBuffer?
    private struct EffectStackKey: Hashable {
        let layerIndex: Int
        let revision: Int
        let sceneSize: SIMD2<Float>
        let maskSlots: [Int?]
        let globalNames: Set<String>
        let handled: Set<String>
    }
    private var effectStackCache: [EffectStackKey: EffectStack] = [:]

    /// Descriptor construction walks every effect and does dictionary lookups per parameter, per
    /// layer, per frame. Only scripted and audio-baked effects actually change between frames, so
    /// everything else is reused until user properties bump the revision.
    private func cachedEffectStack(layerIndex: Int, effects: [SceneMetalEffect], maskSlots: [Int?],
                                   blendSlots: [Int?] = [],
                                   globalNames: Set<String>, handled: Set<String>,
                                   sceneSize: SIMD2<Float>, audioLevel: Float) -> EffectStack {
        guard !EffectStack.isFrameVarying(effects: effects, globalNames: globalNames) else {
            return EffectStack(effects: effects, maskSlots: maskSlots, blendSlots: blendSlots,
                               globalNames: globalNames,
                               sceneSize: sceneSize, audioLevel: audioLevel)
        }
        let key = EffectStackKey(layerIndex: layerIndex,
                                 revision: AudioReactiveScriptEngine.shared.propertyRevision,
                                 sceneSize: sceneSize, maskSlots: maskSlots,
                                 globalNames: globalNames, handled: handled)
        if let cached = effectStackCache[key] { return cached }
        let stack = EffectStack(effects: effects, maskSlots: maskSlots, blendSlots: blendSlots,
                                globalNames: globalNames,
                                sceneSize: sceneSize, audioLevel: audioLevel)
        if effectStackCache.count > 256 { effectStackCache.removeAll(keepingCapacity: true) }
        effectStackCache[key] = stack
        OWEFrameMetrics.countEffectStackBuild()
        return stack
    }
    private var particleSystems: [ParticleSystemRuntime] = []
    private var lastFrameTime = CACurrentMediaTime()
    private var sceneScript: String?
    private var placement: WallpaperPlacement = .fill
    private var effects = Set<String>()
    private var dynamicEffects = SceneDynamicEffectCatalog(definitions: [:])
    private var bloom = SceneBloomSettings(enabled: false, strength: 0, threshold: 0.7, tint: SIMD3<Float>(repeating: 1))
    private var sceneRenderTarget: MTLTexture?
    private var sceneRenderTargetSize = SIMD2<Float>.zero
    private var textFrameCache: [String: RenderTextureFrame] = [:]
    private var dynamicTextureCache: [URL: MTLTexture] = [:]
    private var dynamicSamplerCache: [String: MTLSamplerState] = [:]
    private var smoothedAudioBands = [Float](repeating: 0, count: 16)

    init?(view: MTKView) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "sceneVertex"),
              let fragment = library.makeFunction(name: "sceneFragment"),
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

        self.device = device
        self.commandQueue = commandQueue
        self.renderPipeline = renderPipeline
        self.additiveRenderPipeline = additiveRenderPipeline
        self.dxtDecodePipeline = decodePipeline
        self.textureLoader = MTKTextureLoader(device: device)
        self.renderTargetPool = SceneRenderTargetPool(device: device)
        self.dynamicEffectPipelines = DynamicEffectPipelineCache(device: device)
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
        contentGenerationLock.lock()
        contentGeneration &+= 1
        let generation = contentGeneration
        contentGenerationLock.unlock()

        guard let content else {
            layers = []
            particleSystems = []
            sceneScript = nil
            effectStackCache.removeAll(keepingCapacity: true)
            textFrameCache.removeAll(keepingCapacity: true)
            dynamicTextureCache.removeAll(keepingCapacity: true)
            dynamicSamplerCache.removeAll(keepingCapacity: true)
            return
        }
        contentQueue.async { [weak self] in
            guard let self, self.isCurrentContentGeneration(generation) else { return }
            let preparedLayers: [PreparedLayer] = content.layers.compactMap { layer in
                guard let frames = self.makeTextureFrames(from: layer.source), !frames.isEmpty else { return nil }
                var effectMasks: [MTLTexture] = []
                let effectMaskSlots: [Int?] = layer.sceneEffects.map { effect in
                    guard let mask = effect.mask, let texture = self.makeTextureFrames(from: mask)?.first?.texture else { return nil }
                    guard effectMasks.count < SceneMetalRenderer.maxEffectMasks else {
                        OWELog.error(.scene, "Layer '\(layer.name)' exceeds \(SceneMetalRenderer.maxEffectMasks) masked effects; '\(effect.name)' will render unmasked")
                        return nil
                    }
                    effectMasks.append(texture)
                    return effectMasks.count - 1
                }
                // Blend sources share the mask array, so they draw from the same budget.
                let effectBlendSlots: [Int?] = layer.sceneEffects.map { effect in
                    guard let blend = effect.blend,
                          let texture = self.makeTextureFrames(from: blend)?.first?.texture else { return nil }
                    guard effectMasks.count < SceneMetalRenderer.maxEffectMasks else {
                        OWELog.error(.scene, "Layer '\(layer.name)' exceeds \(SceneMetalRenderer.maxEffectMasks) mask/blend textures; '\(effect.name)' will not blend")
                        return nil
                    }
                    effectMasks.append(texture)
                    return effectMasks.count - 1
                }
                return PreparedLayer(frames: frames, frameDuration: frames.reduce(0) { $0 + $1.duration },
                                     layer: layer, effectMasks: effectMasks, effectMaskSlots: effectMaskSlots,
                                     effectBlendSlots: effectBlendSlots,
                                     xrayTexture: layer.xraySource.flatMap { self.makeTextureFrames(from: $0)?.first?.texture })
            }
            let preparedParticleSystems: [ParticleSystemRuntime] = content.particleSystems.compactMap { system in
                guard let texture = self.makeTextureFrames(from: system.source)?.first?.texture else { return nil }
                return ParticleSystemRuntime(texture: texture, configuration: system)
            }
            guard self.isCurrentContentGeneration(generation) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrentContentGeneration(generation) else { return }
                self.sceneSize = content.size
                self.effects = Set(content.effects.map { $0.lowercased() })
                self.dynamicEffects = content.dynamicEffects
                self.bloom = content.bloom
                self.layers = preparedLayers
                self.particleSystems = preparedParticleSystems
                self.sceneScript = content.sceneScript
                self.effectStackCache.removeAll(keepingCapacity: true)
                self.textFrameCache.removeAll(keepingCapacity: true)
                self.dynamicTextureCache.removeAll(keepingCapacity: true)
                self.dynamicSamplerCache.removeAll(keepingCapacity: true)
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
                AudioReactiveScriptEngine.shared.configureLayers(scriptLayers, aliases: layerAliases,
                                                                 canvasSize: content.size)
                self.lastFrameTime = CACurrentMediaTime()
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
            guard layers.count < 512 else {
                OWELog.error(.script, "Refusing to create layer \(request.id): layer budget reached")
                break
            }
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
            layers.removeAll { removals.contains($0.stateId) && $0.stateId != $0.layer.id }
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let frameStart = CACurrentMediaTime()
        let frameSignpost = OWESignpost.begin(OWESignpost.render, "frame")
        AudioReactiveScriptEngine.shared.beginFrame()
        defer {
            AudioReactiveScriptEngine.shared.endFrame()
            frameSignpost.end()
            if OWEFrameMetrics.isReportingEnabled {
                OWEFrameMetrics.recordFrame(seconds: CACurrentMediaTime() - frameStart,
                                            layers: layers.count,
                                            particles: particleSystems.reduce(0) { $0 + $1.particles.count })
            }
        }

        guard let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let sceneTexture = sceneRenderTarget(matching: descriptor),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        // Render every layer/particle at native scene resolution; placement scaling happens once, in the final composite pass.
        let drawableSize = SIMD2<Float>(Float(sceneTexture.width), Float(sceneTexture.height))
        let realDrawableSize = SIMD2<Float>(Float(drawable.texture.width), Float(drawable.texture.height))
        let animationSpeed = AudioReactiveScriptEngine.shared.userPropertyValue("_owe_speed", fallback: 1)
        let time = Float(CACurrentMediaTime()) * animationSpeed
        let audioLevel = AudioReactiveScriptEngine.shared.audioLevel
        let audioBands = audioBandVectors()
        let frameDelta = min(Float(CACurrentMediaTime() - lastFrameTime), 1.0 / 15.0)
        AudioReactiveScriptEngine.shared.setSceneClock(deltaTime: Double(frameDelta))
        if let sceneScript {
            AudioReactiveScriptEngine.shared.executeSceneScript(sceneScript, time: Double(time))
        }
        let cursor = sceneCursor(in: view, drawableSize: realDrawableSize)
        AudioReactiveScriptEngine.shared.updateSceneCursor(cursor)
        let cursorDelta = (cursor - sceneSize / 2) / sceneSize
        materializeScriptCreatedLayers()
        var dynamicTextures: [Int: MTLTexture] = [:]
        var dynamicHandledEffects: [Int: Set<String>] = [:]
        for (layerIndex, entry) in layers.enumerated() {
            guard AudioReactiveScriptEngine.shared.layerBoolean(entry.stateId, property: "visible", fallback: true) else { continue }
            if let result = applyDynamicEffects(to: entry, time: time, audioLevel: Float(audioLevel),
                                                drawableSize: drawableSize, commandBuffer: commandBuffer) {
                dynamicTextures[layerIndex] = result.texture
                dynamicHandledEffects[layerIndex] = result.handledEffects
            }
        }

        let clearColor = descriptor.colorAttachments[0].clearColor
        let sceneRenderPass = MTLRenderPassDescriptor()
        sceneRenderPass.colorAttachments[0].texture = sceneTexture
        sceneRenderPass.colorAttachments[0].loadAction = .clear
        sceneRenderPass.colorAttachments[0].clearColor = clearColor
        sceneRenderPass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: sceneRenderPass) else { return }
        encoder.setRenderPipelineState(renderPipeline)

        let parallaxEnabled = AudioReactiveScriptEngine.shared.userPropertyString("_owe_effect_enabled_parallax") == "true"
        let parallaxAmount = AudioReactiveScriptEngine.shared.userPropertyValue("_owe_effect_parallax_amount", fallback: 1)
        // Two decorrelated frequencies so the shake reads as a jitter rather than a circle.
        let cameraShakeOffset: SIMD2<Float> = AudioReactiveScriptEngine.shared.cameraShakeEnabled
            ? SIMD2<Float>(sin(time * 47.3) * 0.004 + sin(time * 71.9) * 0.002,
                           cos(time * 53.1) * 0.004 + cos(time * 83.7) * 0.002) * sceneSize
            : .zero
        for (layerIndex, entry) in layers.enumerated() {
            var effectUniform = EffectUniform(time: time,
                                              pulse: effects.contains("pulse") ? Float(audioLevel) : 0)
            effectUniform.cursor = cursorDelta
            effectUniform.audioBands0 = audioBands.0
            effectUniform.audioBands1 = audioBands.1
            effectUniform.audioBands2 = audioBands.2
            effectUniform.audioBands3 = audioBands.3
            encoder.setVertexBytes(&effectUniform, length: MemoryLayout<EffectUniform>.stride, index: 1)
            encoder.setFragmentBytes(&effectUniform, length: MemoryLayout<EffectUniform>.stride, index: 1)
            let handledEffects = dynamicHandledEffects[layerIndex] ?? []
            let blendSlotsByIndex = entry.effectBlendSlots
            let nativeEffectEntries = zip(entry.layer.sceneEffects.enumerated(), entry.effectMaskSlots)
                .filter { !handledEffects.contains($0.0.element.name.lowercased()) }
            let nativeEffects = nativeEffectEntries.map(\.0.element)
            let nativeMaskSlots = nativeEffectEntries.map(\.1)
            let nativeBlendSlots = nativeEffectEntries.map { entry -> Int? in
                entry.0.offset < blendSlotsByIndex.count ? blendSlotsByIndex[entry.0.offset] : nil
            }
            // Layers that already author an effect (with their own tuned values/mask) must not
            // also receive the global toggle's copy, or the two passes stack and corrupt the layer.
            let authoredEffectNames = Set(entry.layer.sceneEffects.map { $0.name.lowercased() })
            let nativeGlobalEffects = effects.filter {
                !handledEffects.contains($0.lowercased()) && !authoredEffectNames.contains($0.lowercased())
                    && !SceneEffectRegistry.isOverlay($0)
            }
            let effectStack = cachedEffectStack(layerIndex: layerIndex, effects: nativeEffects,
                                                maskSlots: nativeMaskSlots, blendSlots: nativeBlendSlots,
                                                globalNames: nativeGlobalEffects,
                                                handled: handledEffects,
                                                sceneSize: sceneSize, audioLevel: Float(audioLevel))
            effectStack.bind(to: encoder)
            let opacity = entry.layer.opacityScript.map {
                AudioReactiveScriptEngine.shared.evaluate($0, fallback: entry.layer.opacity, layerId: entry.stateId)
            } ?? timelineValue(entry.layer.opacityAnimation, at: time, fallback: AudioReactiveScriptEngine.shared.layerValue(entry.stateId, property: "alpha", fallback: entry.layer.opacity))
            // origin is a Vec3 in Wallpaper Engine; scripts read and write value.z, so evaluating
            // it as a Vec2 hands them an object with no z and silently corrupts the result.
            let position = entry.layer.positionScript.flatMap { script -> SIMD2<Float>? in
                AudioReactiveScriptEngine.shared.evaluateVector3(script,
                    fallback: SIMD3<Float>(entry.layer.position.x, entry.layer.position.y, 0),
                    layerId: entry.stateId).map { SIMD2<Float>($0.x, $0.y) }
            }
                ?? AudioReactiveScriptEngine.shared.layerVector2(entry.stateId, property: "origin",
                    fallback: vector2(timelineVector3(entry.layer.positionAnimation, at: time,
                        fallback: SIMD3<Float>(entry.layer.position.x, entry.layer.position.y, 0))))
            let baseSize = entry.layer.sizeScript.flatMap {
                AudioReactiveScriptEngine.shared.evaluateVector2($0, fallback: entry.layer.size, layerId: entry.stateId)
            }
                ?? AudioReactiveScriptEngine.shared.layerVector2(entry.stateId, property: "size",
                    fallback: vector2(timelineVector3(entry.layer.sizeAnimation, at: time,
                        fallback: SIMD3<Float>(entry.layer.size.x, entry.layer.size.y, 0))))
            let scale = entry.layer.scaleScript.flatMap { script -> SIMD2<Float>? in
                AudioReactiveScriptEngine.shared.evaluateVector3(script,
                    fallback: SIMD3<Float>(entry.layer.scale.x, entry.layer.scale.y, 1),
                    layerId: entry.stateId).map { SIMD2<Float>($0.x, $0.y) }
            } ?? AudioReactiveScriptEngine.shared.layerVector2(entry.stateId, property: "scale",
                fallback: vector2(timelineVector3(entry.layer.scaleAnimation, at: time,
                    fallback: SIMD3<Float>(entry.layer.scale.x, entry.layer.scale.y, 1))))
            let hasAuthoredDepth = simd_length(entry.layer.parallaxDepth) > 0
            let fallbackDepth = Float(layerIndex + 1) / Float(max(layers.count, 1)) * 0.35
            let parallaxDepth = hasAuthoredDepth
                ? entry.layer.parallaxDepth
                : SIMD3<Float>(repeating: fallbackDepth)
            let parallaxOffset = parallaxEnabled
                ? SIMD2<Float>(parallaxDepth.x * cursorDelta.x * sceneSize.x * 0.18 * parallaxAmount,
                               parallaxDepth.y * cursorDelta.y * sceneSize.y * 0.18 * parallaxAmount)
                : .zero
            let perspectiveScale = parallaxEnabled && entry.layer.perspective
                ? 1 + parallaxDepth.z * simd_length(cursorDelta) * 0.18 * parallaxAmount
                : 1
            let musicSyncLevel = entry.layer.musicSync?.levelSource.map { $0() } ?? audioLevel
            let size = baseSize * scale * perspectiveScale
                * (1 + (entry.layer.musicSync?.zoomAmount ?? 0) * Float(musicSyncLevel))
            let unclampedPosition = position + parallaxOffset + cameraShakeOffset
            let safePosition = SIMD2<Float>(
                safeParallaxPosition(unclampedPosition.x, baseSize: size.x, sceneExtent: sceneSize.x),
                safeParallaxPosition(unclampedPosition.y, baseSize: size.y, sceneExtent: sceneSize.y)
            )
            // `angles` is a Vec3 in Wallpaper Engine; scripts mutate value.x/y/z, so it has to be
            // evaluated as a vector even though only the Z rotation is used here.
            let rotation = entry.layer.rotationScript.flatMap {
                AudioReactiveScriptEngine.shared.evaluateVector3($0,
                    fallback: SIMD3<Float>(0, 0, entry.layer.rotation),
                    layerId: entry.stateId)?.z
            } ?? AudioReactiveScriptEngine.shared.layerValue(entry.stateId, property: "angles.z",
                fallback: timelineVector3(entry.layer.rotationAnimation, at: time,
                    fallback: SIMD3<Float>(0, 0, entry.layer.rotation)).z)
            var uniform = layerUniform(position: safePosition, size: size,
                                       opacity: opacity, drawableSize: drawableSize)
            if entry.layer.text != nil {
                uniform.opacity *= AudioReactiveScriptEngine.shared.userPropertyValue("_owe_text_\(entry.layer.id)_opacity", fallback: 1)
            }
            uniform.rotation = rotation + (entry.layer.musicSync.map {
                $0.tiltAmount * Float(musicSyncLevel) * .pi / 180
            } ?? 0)
            let objectBrightness = entry.layer.brightnessScript.map {
                AudioReactiveScriptEngine.shared.evaluate($0, fallback: entry.layer.brightness, layerId: entry.stateId)
            } ?? entry.layer.brightness
            let objectColor = entry.layer.colorScript.flatMap {
                AudioReactiveScriptEngine.shared.evaluateVector3($0,
                    fallback: SIMD3<Float>(entry.layer.color.x, entry.layer.color.y, entry.layer.color.z),
                    layerId: entry.stateId)
            }.map { SIMD4<Float>($0.x, $0.y, $0.z, 1) } ?? entry.layer.color
            uniform.color = objectColor
            let materialEffects = entry.layer.effects
            let brightness = materialEffects.scripts["brightness"].map {
                AudioReactiveScriptEngine.shared.evaluate($0, fallback: materialEffects.brightness, layerId: entry.stateId)
            } ?? materialEffects.brightness
            let contrast = materialEffects.scripts["contrast"].map {
                AudioReactiveScriptEngine.shared.evaluate($0, fallback: materialEffects.contrast, layerId: entry.stateId)
            } ?? materialEffects.contrast
            let saturation = materialEffects.scripts["saturation"].map {
                AudioReactiveScriptEngine.shared.evaluate($0, fallback: materialEffects.saturation, layerId: entry.stateId)
            } ?? materialEffects.saturation
            // Scripts write thisObject.bloomstrength directly rather than through a property script.
            let bloom = AudioReactiveScriptEngine.shared.layerValue(entry.stateId, property: "bloomstrength",
                fallback: materialEffects.scripts["bloom"].map {
                    AudioReactiveScriptEngine.shared.evaluate($0, fallback: materialEffects.bloom, layerId: entry.stateId)
                } ?? materialEffects.bloom)
            uniform.effects = SIMD4<Float>(brightness * objectBrightness, contrast,
                                           saturation * AudioReactiveScriptEngine.shared.userPropertyValue("_owe_saturation", fallback: 1)
                                               * (1 + (entry.layer.musicSync?.saturationAmount ?? 0) * Float(musicSyncLevel)),
                                           bloom * AudioReactiveScriptEngine.shared.userPropertyValue("_owe_bloom", fallback: 1))
            uniform.blur = materialEffects.scripts["blur"].map {
                AudioReactiveScriptEngine.shared.evaluate($0, fallback: materialEffects.blur, layerId: entry.stateId)
            } ?? materialEffects.blur * AudioReactiveScriptEngine.shared.userPropertyValue("_owe_blur", fallback: 1)
            uniform.colorEffects = SIMD4<Float>(materialEffects.exposure, materialEffects.gamma,
                                                materialEffects.hue + AudioReactiveScriptEngine.shared.userPropertyValue("_owe_hue", fallback: 0), materialEffects.bloomThreshold)
            uniform.transform = SIMD4<Float>(materialEffects.transformAngle, materialEffects.transformOffset.x,
                                             materialEffects.transformOffset.y, materialEffects.transformScale.x)
            uniform.transformScaleY = materialEffects.transformScale.y
            let textureFrame: RenderTextureFrame
            if let text = entry.layer.text {
                let value: String
                if let clock = text.clock {
                    value = clockValue(clock)
                } else if let scripted = AudioReactiveScriptEngine.shared.layerString(entry.stateId, property: "text") {
                    // Scripts assign layer.text directly for score counters, now-playing labels, etc.
                    value = scripted
                } else {
                    value = text.script.map {
                        AudioReactiveScriptEngine.shared.evaluateString($0, fallback: text.value,
                                                                          layerId: entry.stateId, time: Double(time))
                    } ?? text.value
                }
                // Rasterised at the unscaled box so layout (padding, wrapping, point size) is
                // computed once; the quad then scales the finished block uniformly.
                textureFrame = makeTextFrame(text, value: value, size: baseSize, layerID: entry.layer.id)
                    ?? self.textureFrame(for: entry, time: time)
            } else {
                textureFrame = self.textureFrame(for: entry, time: time)
            }
            uniform.uvOrigin = textureFrame.uvOrigin
            uniform.uvAxisX = textureFrame.uvAxisX
            uniform.uvAxisY = textureFrame.uvAxisY
            encoder.setVertexBytes(&uniform, length: MemoryLayout<LayerUniform>.stride, index: 0)
            encoder.setFragmentBytes(&uniform, length: MemoryLayout<LayerUniform>.stride, index: 0)
            encoder.setFragmentTexture(dynamicTextures[layerIndex] ?? textureFrame.texture, index: 0)
            encoder.setFragmentTexture(entry.xrayTexture, index: 1)
            // The shader takes the masks as one indexable array starting at slot 2, so the whole
            // range is bound in a single call and unused slots are explicitly cleared.
            var maskTextures = [MTLTexture?](repeating: nil, count: SceneMetalRenderer.maxEffectMasks)
            for (index, texture) in entry.effectMasks.prefix(SceneMetalRenderer.maxEffectMasks).enumerated() {
                maskTextures[index] = texture
            }
            encoder.setFragmentTextures(maskTextures, range: 2..<(2 + SceneMetalRenderer.maxEffectMasks))
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        updateParticles(deltaTime: frameDelta, cursor: cursor)
        lastFrameTime = CACurrentMediaTime()
        // One instanced draw per system rather than one per particle (or per rope segment, which
        // multiplies out to thousands on trail renderers).
        particleInstances.removeAll(keepingCapacity: true)
        var particleBatches: [(system: ParticleSystemRuntime, base: Int, count: Int)] = []
        for system in particleSystems {
            let base = particleInstances.count
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
                                                   drawableSize: drawableSize)
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
            particleBatches.append((system, base, particleInstances.count - base))
        }
        if let buffer = particleInstanceBuffer(for: particleInstances.count) {
            particleInstances.withUnsafeBytes { source in
                buffer.contents().copyMemory(from: source.baseAddress!, byteCount: source.count)
            }
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setFragmentBuffer(buffer, offset: 0, index: 0)
            for batch in particleBatches where batch.count > 0 {
                encoder.setRenderPipelineState(batch.system.configuration.blending == "additive"
                                               ? additiveRenderPipeline : renderPipeline)
                encoder.setFragmentTexture(batch.system.texture, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                       instanceCount: batch.count, baseInstance: batch.base)
            }
        }
        encoder.endEncoding()

        // Composite the scene-resolution render target onto the real drawable, applying placement exactly once.
        guard let compositeEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }
        compositeEncoder.setRenderPipelineState(renderPipeline)
        // Overlay effects generate their own artwork, so they run here, once, over the whole frame.
        let overlayEffects = effects.filter { SceneEffectRegistry.isOverlay($0) }
        var compositeEffectUniform = EffectUniform(time: time, pulse: 0)
        compositeEffectUniform.cursor = cursorDelta
        compositeEffectUniform.audioBands0 = audioBands.0
        compositeEffectUniform.audioBands1 = audioBands.1
        compositeEffectUniform.audioBands2 = audioBands.2
        compositeEffectUniform.audioBands3 = audioBands.3
        compositeEncoder.setVertexBytes(&compositeEffectUniform, length: MemoryLayout<EffectUniform>.stride, index: 1)
        compositeEncoder.setFragmentBytes(&compositeEffectUniform, length: MemoryLayout<EffectUniform>.stride, index: 1)
        let compositeEffectStack = EffectStack(effects: [], globalNames: overlayEffects,
                                               sceneSize: sceneSize, audioLevel: Float(audioLevel))
        compositeEffectStack.bind(to: compositeEncoder)
        var compositeUniform = layerUniform(position: sceneSize / 2, size: sceneSize, opacity: 1, drawableSize: realDrawableSize)
        let bloomMultiplier = AudioReactiveScriptEngine.shared.userPropertyValue("_owe_bloom", fallback: 1)
        let authoredBloom = bloom.enabled ? bloom.strength * bloomMultiplier : 0
        let userBloom = max(bloomMultiplier - 1, 0) * 1.2
        let bloomStrength = max(authoredBloom, userBloom)
        compositeUniform.effects = SIMD4<Float>(1, 1, 1, max(bloomStrength, 0))
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
    }

    private func safeParallaxPosition(_ position: Float, baseSize: Float, sceneExtent: Float) -> Float {
        guard baseSize >= sceneExtent else { return position }
        let minimum = baseSize / 2
        let maximum = sceneExtent - baseSize / 2
        return min(max(position, minimum), maximum)
    }

    private func applyDynamicEffects(to entry: PreparedLayer, time: Float, audioLevel: Float,
                                     drawableSize: SIMD2<Float>, commandBuffer: MTLCommandBuffer)
        -> (texture: MTLTexture, handledEffects: Set<String>)? {
        let signpost = OWESignpost.begin(OWESignpost.render, "dynamicEffects")
        defer { signpost.end() }
        // Authored masks are object-specific and only the native path binds them. Do not let the
        // generic dynamic executor claim these effects and suppress their mask-aware implementation.
        var names = entry.layer.sceneEffects.filter { $0.mask == nil }.map { $0.name }
        for name in effects where dynamicEffects.definition(for: name) != nil && !names.contains(name) {
            names.append(name)
        }
        guard !names.isEmpty else { return nil }

        var current = textureFrame(for: entry, time: time).texture
        var didRender = false
        var handledEffects = Set<String>()
        for name in names {
            guard let definition = dynamicEffects.definition(for: name) else { continue }
            var effectCompleted = true
            for pass in definition.passes {
                guard let vertexURL = dynamicEffects.shaderURL(for: pass, stage: "vert"),
                      let fragmentURL = dynamicEffects.shaderURL(for: pass, stage: "frag"),
                      let pipeline = dynamicEffectPipelines.pipeline(vertexURL: vertexURL, fragmentURL: fragmentURL,
                                                                      pixelFormat: current.pixelFormat,
                                                                      macroConfiguration: dynamicEffects.macroConfiguration(for: vertexURL, fragmentURL: fragmentURL),
                                                                      blending: pass.blending),
                      let output = renderTargetPool.texture(width: current.width, height: current.height,
                                                            pixelFormat: current.pixelFormat, avoiding: current),
                      let encoder = dynamicEncoder(for: pipeline, source: current, output: output,
                                                   time: time, audioLevel: audioLevel, drawableSize: drawableSize,
                                                   pass: pass, fragmentURL: fragmentURL,
                                                   commandBuffer: commandBuffer) else {
                    effectCompleted = false
                    break
                }
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                encoder.endEncoding()
                current = output
                didRender = true
            }
            if effectCompleted { handledEffects.insert(name.lowercased()) }
        }
        return didRender ? (current, handledEffects) : nil
    }

    private func audioBandVectors() -> (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) {
        let snapshot = AudioReactiveScriptEngine.shared.audioVisualizationSnapshot()
        let smoothing = min(max(AudioReactiveScriptEngine.shared.userPropertyValue("_owe_effect_audiobars_smoothing", fallback: 0.72), 0), 0.95)
        let spectrum = snapshot.spectrum
        let bands = (0..<16).map { index -> Float in
            guard snapshot.level > 0.012 else { return 0 }
            let start = index * 4
            let end = min(start + 4, spectrum.count)
            guard start < end else { return 0 }
            let average = spectrum[start..<end].reduce(0, +) / Double(end - start)
            return min(max(Float((average - 0.006) * 1.8), 0), 1)
        }
        for index in 0..<16 {
            let attack = bands[index] > smoothedAudioBands[index] ? min(smoothing, 0.55) : smoothing
            smoothedAudioBands[index] = smoothedAudioBands[index] * attack + bands[index] * (1 - attack)
        }
        return (SIMD4<Float>(smoothedAudioBands[0], smoothedAudioBands[1], smoothedAudioBands[2], smoothedAudioBands[3]),
                SIMD4<Float>(smoothedAudioBands[4], smoothedAudioBands[5], smoothedAudioBands[6], smoothedAudioBands[7]),
                SIMD4<Float>(smoothedAudioBands[8], smoothedAudioBands[9], smoothedAudioBands[10], smoothedAudioBands[11]),
                SIMD4<Float>(smoothedAudioBands[12], smoothedAudioBands[13], smoothedAudioBands[14], smoothedAudioBands[15]))
    }

    private func dynamicEncoder(for pipeline: MTLRenderPipelineState, source: MTLTexture, output: MTLTexture,
                                time: Float, audioLevel: Float, drawableSize: SIMD2<Float>,
                                pass: SceneDynamicEffectPass, fragmentURL: URL,
                                commandBuffer: MTLCommandBuffer) -> MTLRenderCommandEncoder? {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = output
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return nil }
        encoder.setRenderPipelineState(pipeline)
        var uniform = layerUniform(position: drawableSize / 2, size: drawableSize, opacity: 1,
                                   drawableSize: drawableSize)
        uniform.sceneSize = drawableSize
        encoder.setVertexBytes(&uniform, length: MemoryLayout<LayerUniform>.stride, index: 0)
        encoder.setFragmentBytes(&uniform, length: MemoryLayout<LayerUniform>.stride, index: 0)
        var effect = EffectUniform(time: time, pulse: Float(audioLevel))
        effect.cursor = .zero
        encoder.setVertexBytes(&effect, length: MemoryLayout<EffectUniform>.stride, index: 1)
        encoder.setFragmentBytes(&effect, length: MemoryLayout<EffectUniform>.stride, index: 1)
        let values = dynamicPassValues(pass, reflection: dynamicEffects.reflection(for: fragmentURL))
        if !values.isEmpty {
            values.withUnsafeBytes { bytes in
                encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 2)
            }
        }
        encoder.setFragmentTexture(source, index: 0)
        for (index, texturePath) in (pass.textures ?? []).enumerated() {
            guard let texturePath else { continue }
            if texturePath.hasPrefix("_rt") || texturePath.hasPrefix("rt/") {
                encoder.setFragmentTexture(source, index: index)
                continue
            }
            guard let url = dynamicEffects.textureURL(for: texturePath),
                  let texture = dynamicTexture(for: url) else { continue }
            encoder.setFragmentTexture(texture, index: index)
        }
        if let sampler = dynamicSampler(for: pass) {
            let textureCount = max((pass.textures ?? []).count, 1)
            for index in 0..<textureCount { encoder.setFragmentSamplerState(sampler, index: index) }
        }
        return encoder
    }

    private func dynamicSampler(for pass: SceneDynamicEffectPass) -> MTLSamplerState? {
        let filter = pass.filter?.lowercased() ?? "linear"
        let address = pass.address?.lowercased() ?? "clamp"
        let key = "\(filter)|\(address)|\(pass.sampler ?? "")"
        if let cached = dynamicSamplerCache[key] { return cached }
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = filter.contains("nearest") ? .nearest : .linear
        descriptor.magFilter = descriptor.minFilter
        let addressMode: MTLSamplerAddressMode = address.contains("repeat") ? .repeat : .clampToEdge
        descriptor.sAddressMode = addressMode
        descriptor.tAddressMode = addressMode
        guard let sampler = device.makeSamplerState(descriptor: descriptor) else { return nil }
        dynamicSamplerCache[key] = sampler
        return sampler
    }

    private func dynamicTexture(for url: URL) -> MTLTexture? {
        if let cached = dynamicTextureCache[url] { return cached }
        let source: SceneMetalTextureSource?
        if url.pathExtension.lowercased() == "tex" {
            let parser = TEXParser(data: (try? Data(contentsOf: url)) ?? Data())
            source = parser.extractImage().map(SceneMetalTextureSource.image)
        } else {
            source = NSImage(contentsOf: url).map(SceneMetalTextureSource.image)
        }
        guard let source, let frame = makeTextureFrames(from: source)?.first else { return nil }
        dynamicTextureCache[url] = frame.texture
        return frame.texture
    }

    private func dynamicPassValues(_ pass: SceneDynamicEffectPass,
                                   reflection: SceneShaderReflection?) -> [Float] {
        let constants = (pass.constants ?? [:]).merging(pass.uniforms ?? [:], uniquingKeysWith: { first, _ in first })
        let keys: [String] = reflection?.uniforms
            .filter { !$0.type.hasPrefix("sampler") }
            .map { uniform in
                let name = uniform.name.lowercased()
                let semantic = uniform.semantic?.lowercased()
                return constants.keys.first { key in
                    let normalized = key.lowercased()
                    return normalized == name || normalized == name.replacingOccurrences(of: "g_", with: "")
                        || semantic?.contains("\"material\":\"\(normalized)\"") == true
                } ?? uniform.name
            } ?? constants.keys.sorted()
        return keys.flatMap { (key) -> [Float] in
            guard let constant = constants[key] else { return [0] }
            if let number = constant.number { return [Float(number)] }
            if let value = constant.value {
                return value.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Float($0) }
            }
            if let script = constant.script {
                return [AudioReactiveScriptEngine.shared.evaluate(script, fallback: 0)]
            }
            return []
        }
    }

    private func sceneRenderTarget(matching descriptor: MTLRenderPassDescriptor) -> MTLTexture? {
        let pixelSize = SIMD2<Float>(max(1, sceneSize.x.rounded()), max(1, sceneSize.y.rounded()))
        if let sceneRenderTarget, sceneRenderTargetSize == pixelSize { return sceneRenderTarget }

        let pixelFormat = descriptor.colorAttachments[0].texture?.pixelFormat ?? .bgra8Unorm
        guard let texture = renderTargetPool.texture(width: Int(pixelSize.x), height: Int(pixelSize.y),
                                                     pixelFormat: pixelFormat) else { return nil }
        sceneRenderTarget = texture
        sceneRenderTargetSize = pixelSize
        return texture
    }

    private func makeTextFrame(_ text: SceneMetalText, value: String, size: SIMD2<Float>, layerID: String) -> RenderTextureFrame? {
        let fontName = AudioReactiveScriptEngine.shared.userPropertyString("_owe_text_\(layerID)_font") ?? ""
        let sizeValue = AudioReactiveScriptEngine.shared.userPropertyValue("_owe_text_\(layerID)_size", fallback: Float(text.pointSize))
        let bold = AudioReactiveScriptEngine.shared.userPropertyString("_owe_text_\(layerID)_bold") == "true"
        let italic = AudioReactiveScriptEngine.shared.userPropertyString("_owe_text_\(layerID)_italic") == "true"
        let colorValue = AudioReactiveScriptEngine.shared.userPropertyString("_owe_text_\(layerID)_color") ?? "1 1 1"
        let cacheKey = "\(layerID)|\(value)|\(size.x)|\(size.y)|\(fontName)|\(sizeValue)|\(bold)|\(italic)|\(colorValue)"
        if let cached = textFrameCache[cacheKey] { return cached }

        let image = NSImage(size: NSSize(width: CGFloat(max(size.x, 1)), height: CGFloat(max(size.y, 1))))
        image.lockFocus()
        NSGraphicsContext.current?.shouldAntialias = true
        NSGraphicsContext.current?.imageInterpolation = .high
        let requestedFont = fontName.isEmpty ? (text.font ?? "System") : fontName
        var font = SceneFontRegistry.font(named: requestedFont, size: CGFloat(sizeValue))
            ?? NSFont(name: requestedFont, size: CGFloat(sizeValue))
            ?? NSFont.systemFont(ofSize: CGFloat(sizeValue))
        if bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = text.horizontalAlignment == "left" ? .left : text.horizontalAlignment == "right" ? .right : .center
        // `limitwidth` is what authorises wrapping. Without it the author laid the string out as a
        // single line, so it is shrunk to fit rather than broken mid-word.
        let allowsWrapping = text.maxWidth != nil && text.maxRows != 1
        paragraph.lineBreakMode = allowsWrapping
            ? .byWordWrapping
            : (text.useEllipsis ? .byTruncatingTail : .byClipping)
        let rgb = colorValue.parseVector3()
        let color = NSColor(calibratedRed: CGFloat(rgb.0), green: CGFloat(rgb.1), blue: CGFloat(rgb.2), alpha: 1)
        func attributedText(_ font: NSFont) -> NSAttributedString {
            NSAttributedString(string: value, attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ])
        }
        // Authored padding insets the text box; the drawable width also honours maxwidth.
        // Padding is capped so a layer whose box is smaller than its authored inset still shows
        // its text instead of collapsing the draw rect to nothing.
        let padding = CGSize(width: min(CGFloat(text.padding.x), image.size.width * 0.3),
                             height: min(CGFloat(text.padding.y), image.size.height * 0.3))
        var drawWidth = max(1, image.size.width - padding.width * 2)
        if let maxWidth = text.maxWidth, maxWidth > 0 { drawWidth = min(drawWidth, CGFloat(maxWidth)) }
        let drawHeight = max(1, image.size.height - padding.height * 2)
        var attributed = attributedText(font)
        if !allowsWrapping {
            let naturalWidth = attributed.size().width
            if naturalWidth > drawWidth, naturalWidth > 0,
               let fitted = NSFont(descriptor: font.fontDescriptor,
                                   size: font.pointSize * drawWidth / naturalWidth) {
                attributed = attributedText(fitted)
            }
        }
        // `size()` is a single-line measurement, so a wrapped string would be mis-centred and clipped.
        let bounds = attributed.boundingRect(with: NSSize(width: drawWidth, height: .greatestFiniteMagnitude),
                                             options: [.usesLineFragmentOrigin, .usesFontLeading])
        let textHeight = min(ceil(bounds.height), drawHeight)
        let originX = (image.size.width - drawWidth) / 2
        let originY: CGFloat
        switch text.verticalAlignment {
        case "top": originY = image.size.height - padding.height - textHeight
        case "bottom": originY = padding.height
        default: originY = (image.size.height - textHeight) / 2
        }
        attributed.draw(with: NSRect(x: originX, y: max(0, originY), width: drawWidth, height: textHeight),
                        options: [.usesLineFragmentOrigin, .usesFontLeading])
        image.unlockFocus()
        guard let frame = makeTextureFrames(from: .image(image))?.first else { return nil }
        textFrameCache[cacheKey] = frame
        return frame
    }

    private func clockValue(_ clock: SceneClock) -> String {
        if clock.kind == .countdown, let target = clock.targetDate,
           let targetDate = ISO8601DateFormatter().date(from: target) {
            let now = Date()
            var end = targetDate
            if clock.recurring {
                let calendar = Calendar.current
                end = calendar.date(bySetting: .year, value: calendar.component(.year, from: now), of: targetDate) ?? targetDate
                if end < now { end = calendar.date(byAdding: .year, value: 1, to: end) ?? end }
            }
            let seconds = Int(end.timeIntervalSince(now))
            if seconds < 0 { return clock.finalMessage ?? "" }
            let days = seconds / 86400
            let hours = seconds / 3600 % 24
            let minutes = seconds / 60 % 60
            return days > 0 ? "\(days)d\(clock.delimiter)\(String(format: "%02d", hours))h" : "\(hours)h\(clock.delimiter)\(String(format: "%02d", minutes))m"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale.autoupdatingCurrent
        switch clock.kind {
        case .date:
            formatter.dateFormat = "EEE, MMM d"
        case .time:
            formatter.dateFormat = clock.use24HourFormat
                ? (clock.showSeconds ? "HH'\(clock.delimiter)'mm'\(clock.delimiter)'ss" : "HH'\(clock.delimiter)'mm")
                : (clock.showSeconds ? "hh'\(clock.delimiter)'mm'\(clock.delimiter)'ss a" : "hh'\(clock.delimiter)'mm a")
        case .countdown:
            return ""
        }
        return formatter.string(from: Date())
    }

    private func layerUniform(position: SIMD2<Float>, size: SIMD2<Float>, opacity: Float,
                              drawableSize: SIMD2<Float>) -> LayerUniform {
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
        case .fill, .zoom:
            scale = max(drawableSize.x / sceneSize.x, drawableSize.y / sceneSize.y)
        case .fit:
            scale = min(drawableSize.x / sceneSize.x, drawableSize.y / sceneSize.y)
        case .center:
            scale = 1
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

    private func sceneCursor(in view: MTKView, drawableSize: SIMD2<Float>) -> SIMD2<Float> {
        guard let window = view.window,
              let screen = window.screen,
              screen.frame.contains(NSEvent.mouseLocation) else {
            return sceneSize / 2
        }
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let mouse = view.convert(windowPoint, from: nil)
        let drawablePoint = SIMD2<Float>(Float(mouse.x) * drawableSize.x / Float(max(view.bounds.width, 1)),
                                         Float(mouse.y) * drawableSize.y / Float(max(view.bounds.height, 1)))
        switch placement {
        case .stretch:
            return SIMD2<Float>(drawablePoint.x * sceneSize.x / drawableSize.x,
                                drawablePoint.y * sceneSize.y / drawableSize.y)
        case .fill, .zoom, .fit, .center:
            let scale: Float = placement == .fit
                ? min(drawableSize.x / sceneSize.x, drawableSize.y / sceneSize.y)
                : placement == .center ? 1 : max(drawableSize.x / sceneSize.x, drawableSize.y / sceneSize.y)
            let offset = (drawableSize - sceneSize * scale) / 2
            return (drawablePoint - offset) / scale
        }
    }

    private func makeTextureFrames(from source: SceneMetalTextureSource) -> [RenderTextureFrame]? {
        switch source {
        case let .image(image):
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            guard let texture = try? textureLoader.newTexture(cgImage: cgImage, options: [MTKTextureLoader.Option.SRGB: false]) else { return nil }
            return [RenderTextureFrame(texture: texture, duration: .greatestFiniteMagnitude,
                                       uvOrigin: .zero, uvAxisX: SIMD2<Float>(1, 0), uvAxisY: SIMD2<Float>(0, 1))]
        case let .dxt(texture):
            guard let texture = makeDXTTexture(texture) else { return nil }
            return [RenderTextureFrame(texture: texture, duration: .greatestFiniteMagnitude,
                                       uvOrigin: .zero, uvAxisX: SIMD2<Float>(1, 0), uvAxisY: SIMD2<Float>(0, 1))]
        case let .video(stream):
            // Stand-in until the first frame decodes; draw() swaps in the live texture.
            guard let texture = stream.currentTexture() ?? makePlaceholderTexture() else { return nil }
            return [RenderTextureFrame(texture: texture, duration: .greatestFiniteMagnitude,
                                       uvOrigin: .zero, uvAxisX: SIMD2<Float>(1, 0), uvAxisY: SIMD2<Float>(0, 1))]
        case let .animated(animation):
            let textures = animation.images.compactMap { image -> MTLTexture? in
                guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
                return try? textureLoader.newTexture(cgImage: cgImage, options: [MTKTextureLoader.Option.SRGB: false])
            }
            guard textures.count == animation.images.count else { return nil }
            return animation.frames.compactMap { frame in
                guard frame.imageIndex < textures.count else { return nil }
                let image = animation.images[frame.imageIndex]
                guard image.size.width > 0, image.size.height > 0 else { return nil }
                // WidthY/HeightX allow the frame rect to be sheared/rotated within the atlas.
                let atlasSize = SIMD2<Float>(Float(image.size.width), Float(image.size.height))
                return RenderTextureFrame(texture: textures[frame.imageIndex], duration: frame.duration,
                                          uvOrigin: SIMD2<Float>(frame.x, frame.y) / atlasSize,
                                          uvAxisX: SIMD2<Float>(frame.width, frame.widthY) / atlasSize,
                                          uvAxisY: SIMD2<Float>(frame.heightX, frame.height) / atlasSize)
            }
        }
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

    private func timelineValue(_ animation: WEKeyframeAnimation?, at time: Float, fallback: Float) -> Float {
        guard let keyframes = animation?.keyframes, !keyframes.isEmpty else { return fallback }
        let frame = timelineFrame(animation: animation, time: time, lastFrame: keyframes.last?.frame ?? 0)
        guard let next = keyframes.first(where: { $0.frame >= frame }) else { return Float(keyframes.last!.value) }
        guard let previous = keyframes.last(where: { $0.frame <= frame }), previous.frame != next.frame else { return Float(next.value) }
        let progress = timelineInterpolation(Double((frame - previous.frame) / (next.frame - previous.frame)),
                              easing: previous.easing ?? next.easing,
                              bezier: previous.bezier ?? next.bezier,
                              inTangent: next.inTangent, outTangent: previous.outTangent)
        return Float(previous.value + (next.value - previous.value) * progress)
    }

    private func timelineVector3(_ animation: WEVectorKeyframeAnimation?, at time: Float,
                                 fallback: SIMD3<Float>) -> SIMD3<Float> {
        guard let keyframes = animation?.keyframes, !keyframes.isEmpty else { return fallback }
        let frame = timelineFrame(animation: animation, time: time, lastFrame: keyframes.last?.frame ?? 0)
        guard let next = keyframes.first(where: { $0.frame >= frame }) else {
            let value = keyframes.last!.value.vectorValue
            return SIMD3<Float>(Float(value.0), Float(value.1), Float(value.2))
        }
        guard let previous = keyframes.last(where: { $0.frame <= frame }), previous.frame != next.frame else {
            let value = next.value.vectorValue
            return SIMD3<Float>(Float(value.0), Float(value.1), Float(value.2))
        }
        let progress = Float(timelineInterpolation((frame - previous.frame) / (next.frame - previous.frame),
                                easing: previous.easing ?? next.easing,
                                bezier: previous.bezier ?? next.bezier,
                                inTangent: next.inTangent, outTangent: previous.outTangent))
        let start = previous.value.vectorValue
        let end = next.value.vectorValue
        return SIMD3<Float>(Float(start.0 + (end.0 - start.0) * Double(progress)),
                            Float(start.1 + (end.1 - start.1) * Double(progress)),
                            Float(start.2 + (end.2 - start.2) * Double(progress)))
    }

    private func timelineInterpolation(_ progress: Double, easing: String?, bezier: [Double]?,
                                       inTangent: Double?, outTangent: Double?) -> Double {
        let value = min(max(progress, 0), 1)
        if let bezier, bezier.count >= 4 {
            return cubicBezier(value, x1: bezier[0], y1: bezier[1], x2: bezier[2], y2: bezier[3])
        }
        if let easing {
            switch easing.lowercased() {
            case "step", "constant": return value < 1 ? 0 : 1
            case "easein": return value * value
            case "easeout": return 1 - (1 - value) * (1 - value)
            case "easeinout", "smooth": return value * value * (3 - 2 * value)
            default: break
            }
        }
        if let outTangent, let inTangent {
            let y1 = 1.0 / 3.0 * outTangent
            let y2 = 1.0 - 1.0 / 3.0 * inTangent
            return cubicBezier(value, x1: 1.0 / 3.0, y1: y1, x2: 2.0 / 3.0, y2: y2)
        }
        return value
    }

    private func cubicBezier(_ x: Double, x1: Double, y1: Double, x2: Double, y2: Double) -> Double {
        var low = 0.0
        var high = 1.0
        for _ in 0..<12 {
            let t = (low + high) / 2
            let estimate = cubic(t, 0, x1, x2, 1)
            if estimate < x { low = t } else { high = t }
        }
        let t = (low + high) / 2
        return cubic(t, 0, y1, y2, 1)
    }

    private func cubic(_ t: Double, _ p0: Double, _ p1: Double, _ p2: Double, _ p3: Double) -> Double {
        let inverse = 1 - t
        return inverse * inverse * inverse * p0 + 3 * inverse * inverse * t * p1
            + 3 * inverse * t * t * p2 + t * t * t * p3
    }

    private func timelineFrame<A>(animation: A, time: Float, lastFrame: Double) -> Double {
        let mode: String?
        let duration: Double?
        let startPaused: Bool?
        let wrapLoop: Bool?
        if let scalar = animation as? WEKeyframeAnimation {
            mode = scalar.mode; duration = scalar.duration; startPaused = scalar.startPaused; wrapLoop = scalar.wrapLoop
        } else if let vector = animation as? WEVectorKeyframeAnimation {
            mode = vector.mode; duration = vector.duration; startPaused = vector.startPaused; wrapLoop = vector.wrapLoop
        } else {
            mode = nil; duration = nil; startPaused = nil; wrapLoop = nil
        }
        guard startPaused != true else { return 0 }
        let lengthSeconds = max(duration ?? (lastFrame / 60.0), 0.0001)
        let progress = max(Double(time), 0) / lengthSeconds
        let normalizedMode = mode?.lowercased() ?? "loop"
        let mappedProgress: Double
        switch normalizedMode {
        case "single", "once":
            mappedProgress = min(progress, 1)
        case "mirror", "pingpong":
            let cycle = progress.truncatingRemainder(dividingBy: 2)
            mappedProgress = cycle <= 1 ? cycle : 2 - cycle
        default:
            let looped = progress.truncatingRemainder(dividingBy: 1)
            mappedProgress = wrapLoop == true ? looped : looped
        }
        return mappedProgress * max(lastFrame, 0)
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

    private func updateParticles(deltaTime: Float, cursor: SIMD2<Float>) {
        let signpost = OWESignpost.begin(OWESignpost.render, "updateParticles")
        defer { signpost.end() }
        for system in particleSystems {
            let configuration = system.configuration
            system.elapsedTime += deltaTime
            let emissionRate = configuration.emissionRateScript.map {
                AudioReactiveScriptEngine.shared.evaluate($0, fallback: configuration.emissionRate, time: Double(system.elapsedTime))
            } ?? configuration.emissionRate
            if emissionRate <= 0.0001 || configuration.opacityMultiplier <= 0.0001 {
                system.particles.removeAll(keepingCapacity: true)
                system.emissionRemainder = 0
                continue
            }
            let drag = configuration.dragScript.map {
                AudioReactiveScriptEngine.shared.evaluate($0, fallback: configuration.drag, time: Double(system.elapsedTime))
            } ?? configuration.drag
            system.fadeIn = configuration.fadeInScript.map {
                AudioReactiveScriptEngine.shared.evaluate($0, fallback: configuration.fadeIn, time: Double(system.elapsedTime))
            } ?? configuration.fadeIn
            system.fadeOut = configuration.fadeOutScript.map {
                AudioReactiveScriptEngine.shared.evaluate($0, fallback: configuration.fadeOut, time: Double(system.elapsedTime))
            } ?? configuration.fadeOut
            system.emissionRemainder += max(emissionRate, 0) * deltaTime
            let sequenceStart = configuration.sequenceSpan.map {
                controlPointPosition($0.startControlPoint, configuration: configuration, cursor: cursor)
            }
            let sequenceEnd = configuration.sequenceSpan.map {
                controlPointPosition($0.endControlPoint, configuration: configuration, cursor: cursor)
            }
            // Spread very large authored bursts over multiple frames instead of
            // blocking the render loop with thousands of allocations at once.
            let emissionCount = min(min(Int(system.emissionRemainder), 256),
                                    configuration.maximumParticleCount - system.particles.count)
            system.emissionRemainder -= Float(emissionCount)
            for _ in 0..<max(emissionCount, 0) {
                let angle = Float.random(in: 0...(2 * .pi))
                let radius = sqrt(Float.random(in: 0...1))
                let spawnOrigin: SIMD2<Float>
                if let controlPoint = configuration.cursorControlPoint,
                   configuration.emitterControlPoint == controlPoint.id {
                    spawnOrigin = cursor + controlPoint.offset
                } else {
                    spawnOrigin = configuration.origin
                }
                let spawnOffset: SIMD2<Float>
                if configuration.emitterName == "boxrandom" {
                    let extentX = abs(configuration.spawnExtent.x)
                    let extentY = abs(configuration.spawnExtent.y)
                    spawnOffset = SIMD2<Float>(Float.random(in: -extentX...extentX),
                                               Float.random(in: -extentY...extentY))
                } else {
                    spawnOffset = SIMD2<Float>(cos(angle) * configuration.spawnExtent.x,
                                               sin(angle) * configuration.spawnExtent.y) * radius
                }
                let authoredOffset = SIMD2<Float>(Float.random(in: min(configuration.positionOffsetMinimum.x, configuration.positionOffsetMaximum.x)...max(configuration.positionOffsetMinimum.x, configuration.positionOffsetMaximum.x)),
                                                  Float.random(in: min(configuration.positionOffsetMinimum.y, configuration.positionOffsetMaximum.y)...max(configuration.positionOffsetMinimum.y, configuration.positionOffsetMaximum.y)))
                let initialSize = Float.random(in: configuration.size)
                let initialAlpha = Float.random(in: configuration.alpha)
                let initialColor = SIMD4<Float>(Float.random(in: min(configuration.minimumColor.x, configuration.maximumColor.x)...max(configuration.minimumColor.x, configuration.maximumColor.x)),
                                                Float.random(in: min(configuration.minimumColor.y, configuration.maximumColor.y)...max(configuration.minimumColor.y, configuration.maximumColor.y)),
                                                Float.random(in: min(configuration.minimumColor.z, configuration.maximumColor.z)...max(configuration.minimumColor.z, configuration.maximumColor.z)), 1)
                var size = initialSize
                var alpha = initialAlpha
                var position = spawnOrigin + spawnOffset + authoredOffset
                var velocity = SIMD2<Float>(Float.random(in: min(configuration.minimumVelocity.x, configuration.maximumVelocity.x)...max(configuration.minimumVelocity.x, configuration.maximumVelocity.x)),
                                            Float.random(in: min(configuration.minimumVelocity.y, configuration.maximumVelocity.y)...max(configuration.minimumVelocity.y, configuration.maximumVelocity.y)))
                var sequence: Float = 0
                if let span = configuration.sequenceSpan, let start = sequenceStart, let end = sequenceEnd {
                    let slot = system.spawnCounter % span.count
                    let lap = system.spawnCounter / span.count
                    system.spawnCounter &+= 1
                    // "mirror" walks the strand back down on alternate passes so successive
                    // particles stay adjacent instead of jumping from the end to the start.
                    sequence = span.mirrored && lap % 2 == 1
                        ? 1 - Float(slot) / Float(span.count - 1)
                        : Float(slot) / Float(span.count - 1)
                    let axis = end - start
                    let normal = SIMD2<Float>(-axis.y, axis.x)
                    let arc = normal * span.arcAmount * sin(sequence * .pi) * 0.5
                    var offset = spawnOffset
                    if let ring = configuration.sequenceRing {
                        // The emitter still sets the radius; only the angle comes from the sequence,
                        // which is what turns a straight span into a helix.
                        let radius = simd_length(spawnOffset)
                        let bounded = ring.bounds.lowerBound
                            + sequence * (ring.bounds.upperBound - ring.bounds.lowerBound)
                        let angle = bounded * ring.turns * 2 * .pi
                        let ringAxis = simd_length(ring.axis) > 0.0001 ? simd_normalize(ring.axis)
                            : (simd_length(axis) > 0.0001 ? simd_normalize(axis) : SIMD2<Float>(0, 1))
                        offset = SIMD2<Float>(-ringAxis.y, ringAxis.x) * cos(angle) * radius
                        velocity += SIMD2<Float>(Float.random(in: min(ring.minimumSpeed.x, ring.maximumSpeed.x)...max(ring.minimumSpeed.x, ring.maximumSpeed.x)),
                                                 Float.random(in: min(ring.minimumSpeed.y, ring.maximumSpeed.y)...max(ring.minimumSpeed.y, ring.maximumSpeed.y)))
                    }
                    position = start + axis * sequence + arc + offset + authoredOffset
                }
                if let remap = configuration.initialRemap {
                    let anchor = controlPointPosition(remap.controlPoint, configuration: configuration, cursor: cursor)
                    let range = max(remap.rangeMaximum - remap.rangeMinimum, 0.001)
                    let factor = min(max((simd_length(position - anchor) - remap.rangeMinimum) / range, 0), 1)
                    switch remap.output {
                    case .size: size = remap.multiply ? size * factor : factor
                    case .alpha: alpha = remap.multiply ? alpha * factor : factor
                    case .velocity: velocity = remap.multiply ? velocity * factor : velocity
                    }
                }
                system.particles.append(Particle(
                    position: position,
                    velocity: velocity,
                    age: 0,
                    lifetime: Float.random(in: configuration.lifetime),
                    size: size, baseSize: size,
                    alpha: alpha, baseAlpha: alpha,
                    rotation: Float.random(in: configuration.minimumRotation...configuration.maximumRotation),
                    angularVelocity: Float.random(in: configuration.minimumAngularVelocity...configuration.maximumAngularVelocity),
                    color: initialColor, baseColor: initialColor,
                    spriteFrame: Int.random(in: 0..<max(configuration.spriteSheet?.frames ?? 1, 1)),
                    history: [], historyStart: 0, sequence: sequence))
            }
            for index in system.particles.indices {
                system.particles[index].position += system.particles[index].velocity * deltaTime
                if let turbulence = configuration.turbulence {
                    let position = system.particles[index].position * turbulence.scale
                    let phase = system.elapsedTime * turbulence.timeScale + turbulence.phase
                    let force = SIMD2<Float>(sin(position.y + phase), cos(position.x - phase))
                        * Float.random(in: turbulence.speed) * turbulence.mask
                    system.particles[index].velocity += force * deltaTime
                }
                if let attractor = configuration.attractor {
                    let origin = configuration.cursorControlPoint.map { cursor + $0.offset } ?? attractor.origin
                    let offset = origin - system.particles[index].position
                    let distance = max(simd_length(offset), 0.001)
                    if distance < attractor.threshold {
                        system.particles[index].velocity += offset / distance * attractor.strength * deltaTime
                    }
                }
                if let vortex = configuration.vortex {
                    let offset = system.particles[index].position - vortex.origin
                    let distance = simd_length(offset)
                    if distance > 0.001, distance >= vortex.innerDistance, distance <= max(vortex.outerDistance, vortex.innerDistance) {
                        let progress = min(max((distance - vortex.innerDistance) / max(vortex.outerDistance - vortex.innerDistance, 0.001), 0), 1)
                        let speed = vortex.innerSpeed + (vortex.outerSpeed - vortex.innerSpeed) * progress
                        let tangent = SIMD2<Float>(-offset.y, offset.x) / distance
                        system.particles[index].velocity += tangent * speed * deltaTime
                    }
                }
                     if let boids = configuration.boids, boids.threshold > 0,
                         system.particles.count < 1500 {
                    var neighborCount: Float = 0
                    var averageVelocity = SIMD2<Float>.zero
                    var averagePosition = SIMD2<Float>.zero
                    var separation = SIMD2<Float>.zero
                    let neighborStride = max(1, system.particles.count / 256)
                    for neighborIndex in system.particles.indices where neighborIndex != index && neighborIndex % neighborStride == 0 {
                        let offset = system.particles[neighborIndex].position - system.particles[index].position
                        let distance = simd_length(offset)
                        guard distance > 0.001, distance < boids.threshold else { continue }
                        neighborCount += 1
                        averageVelocity += system.particles[neighborIndex].velocity
                        averagePosition += system.particles[neighborIndex].position
                        separation -= offset / distance
                    }
                    if neighborCount > 0 {
                        averageVelocity /= neighborCount
                        averagePosition /= neighborCount
                        let alignment = averageVelocity - system.particles[index].velocity
                        let cohesion = averagePosition - system.particles[index].position
                        system.particles[index].velocity += (alignment * boids.alignment
                            + cohesion * boids.cohesion + separation * boids.separation) * deltaTime
                    }
                }
                if let reduction = configuration.nearControlPointReduction {
                    let offset = system.particles[index].position - reduction.origin
                    let distance = simd_length(offset)
                    if distance < reduction.outerDistance {
                        let progress = min(max((distance - reduction.innerDistance) / max(reduction.outerDistance - reduction.innerDistance, 0.001), 0), 1)
                        let multiplier = 1 - reduction.reduction * (1 - progress) * deltaTime
                        system.particles[index].velocity *= max(multiplier, 0)
                    }
                }
                if let constraint = configuration.maintainControlPointDistance {
                    let offset = constraint.origin - system.particles[index].position
                    system.particles[index].velocity += offset * constraint.strength * deltaTime
                }
                if configuration.maintainSequenceDistance, let start = sequenceStart, let end = sequenceEnd {
                    // Pulls each particle back to its slot on the strand so turbulence bends the
                    // shape without tearing it away from its two anchors.
                    let anchor = start + (end - start) * system.particles[index].sequence
                    system.particles[index].velocity += (anchor - system.particles[index].position) * 10 * deltaTime
                }
                system.particles[index].velocity += configuration.gravity * deltaTime
                system.particles[index].velocity *= max(0, 1 - drag * deltaTime)
                if let maximumSpeed = configuration.maximumSpeed, maximumSpeed > 0 {
                    let speed = simd_length(system.particles[index].velocity)
                    if speed > maximumSpeed {
                        system.particles[index].velocity *= maximumSpeed / speed
                    }
                }
                system.particles[index].age += deltaTime
                let particleProgress = min(max(system.particles[index].age / max(system.particles[index].lifetime, 0.001), 0), 1)
                if let change = configuration.sizeChange {
                    let progress = min(max((particleProgress - change.startTime) / max(change.endTime - change.startTime, 0.001), 0), 1)
                    system.particles[index].size = system.particles[index].baseSize * (change.startValue + (change.endValue - change.startValue) * progress)
                }
                if let change = configuration.alphaChange {
                    let progress = min(max((particleProgress - change.startTime) / max(change.endTime - change.startTime, 0.001), 0), 1)
                    system.particles[index].alpha = system.particles[index].baseAlpha * (change.startValue + (change.endValue - change.startValue) * progress)
                }
                if let change = configuration.colorChange {
                    let progress = min(max((particleProgress - change.startTime) / max(change.endTime - change.startTime, 0.001), 0), 1)
                    system.particles[index].color = simd_mix(change.startValue, change.endValue, SIMD4<Float>(repeating: progress)) * system.particles[index].baseColor
                }
                if let oscillation = configuration.oscillateSize {
                    let frequency = (oscillation.frequency.lowerBound + oscillation.frequency.upperBound) / 2
                    let scale = (oscillation.scale.lowerBound + oscillation.scale.upperBound) / 2
                    let phase = (oscillation.phase.lowerBound + oscillation.phase.upperBound) / 2
                    system.particles[index].size = system.particles[index].baseSize * (1 + (scale - 1) * sin(system.particles[index].age * frequency + phase))
                }
                if let oscillation = configuration.oscillateAlpha {
                    let frequency = (oscillation.frequency.lowerBound + oscillation.frequency.upperBound) / 2
                    let scale = (oscillation.scale.lowerBound + oscillation.scale.upperBound) / 2
                    let phase = (oscillation.phase.lowerBound + oscillation.phase.upperBound) / 2
                    system.particles[index].alpha = max(0, system.particles[index].baseAlpha * (1 + (scale - 1) * sin(system.particles[index].age * frequency + phase)))
                }
                if let oscillation = configuration.oscillatePosition {
                    let frequency = (oscillation.frequency.lowerBound + oscillation.frequency.upperBound) / 2
                    let scale = (oscillation.scale.lowerBound + oscillation.scale.upperBound) / 2
                    let phase = (oscillation.phase.lowerBound + oscillation.phase.upperBound) / 2
                    let offset = sin(system.particles[index].age * frequency + phase) * scale * deltaTime
                    system.particles[index].position += SIMD2<Float>(offset, cos(system.particles[index].age * frequency + phase) * scale * deltaTime)
                }
                if let remap = configuration.remapAlpha {
                    var value = system.particles[index].age * remap.scale
                    if remap.sine { value = sin(value) * 0.5 + 0.5 }
                    let mapped = remap.outputMinimum + (remap.outputMaximum - remap.outputMinimum) * min(max(value, 0), 1)
                    system.particles[index].alpha = system.particles[index].baseAlpha * mapped
                }
                system.particles[index].angularVelocity += configuration.angularAcceleration * deltaTime
                system.particles[index].rotation += system.particles[index].angularVelocity * deltaTime
                let historyLimit = max(configuration.trailSegments, 1)
                // Only the ropetrail renderer reads history, and it wants samples spread over the
                // renderer's `length` in seconds rather than one per frame.
                if configuration.rendererName == "ropetrail" {
                    let interval = max(configuration.trailLength, 0.001) / Float(historyLimit)
                    system.particles[index].historyTimer += deltaTime
                    if system.particles[index].historyTimer >= interval || system.particles[index].history.isEmpty {
                        system.particles[index].historyTimer = 0
                        if system.particles[index].history.count < historyLimit {
                            system.particles[index].history.append(system.particles[index].position)
                        } else {
                            let historyStart = system.particles[index].historyStart
                            system.particles[index].history[historyStart] = system.particles[index].position
                            system.particles[index].historyStart = (historyStart + 1) % historyLimit
                        }
                    }
                }
            }
            system.particles.removeAll { $0.age >= $0.lifetime }
        }
    }

    private func appendParticleTrail(_ particle: Particle, system: ParticleSystemRuntime,
                                     drawableSize: SIMD2<Float>) {
        let speed = simd_length(particle.velocity)
        let stretch = max(system.configuration.trailLength, 1)
        let length = max(particle.size, min(particle.size * stretch, particle.size + speed * 0.08))
        let width = system.configuration.refractive ? max(2, particle.size * 0.08) : particle.size
        var uniform = layerUniform(position: particle.position,
                                   size: SIMD2<Float>(width, length),
                                   opacity: particleOpacity(particle, in: system), drawableSize: drawableSize)
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

    private func controlPointPosition(_ id: Int, configuration: SceneMetalParticleSystem,
                                      cursor: SIMD2<Float>) -> SIMD2<Float> {        guard let point = configuration.controlPoints.first(where: { $0.id == id }) else {
            return configuration.origin
        }
        return (point.locksToCursor ? cursor : configuration.origin) + point.offset
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
                                       drawableSize: drawableSize)
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
                                       drawableSize: drawableSize)
            uniform.rotation = atan2(delta.y, delta.x)
            uniform.color = (start.color + end.color) / 2
            particleInstances.append(uniform)
        }
    }

    private func catmullRom(_ previous: SIMD2<Float>, _ start: SIMD2<Float>, _ end: SIMD2<Float>,
                            _ following: SIMD2<Float>, _ t: Float) -> SIMD2<Float> {        let t2 = t * t
        let t3 = t2 * t
        return 0.5 * ((2 * start) + (-previous + end) * t
            + (2 * previous - 5 * start + 4 * end - following) * t2
            + (-previous + 3 * start - 3 * end + following) * t3)
    }

    private func particleOpacity(_ particle: Particle, in system: ParticleSystemRuntime) -> Float {
        let progress = particle.age / particle.lifetime
        let fadeIn = system.fadeIn > 0 ? min(progress / system.fadeIn, 1) : 1
        let fadeOut = system.fadeOut < 1 ? min((1 - progress) / (1 - system.fadeOut), 1) : 1
        return particle.alpha * fadeIn * fadeOut * system.configuration.opacityMultiplier
    }
}