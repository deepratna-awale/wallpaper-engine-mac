import Cocoa
import MetalKit

enum SceneMetalTextureSource {
    case image(NSImage)
    case dxt(TEXCompressedTexture)
    case animated(TEXAnimatedImages)
}

struct SceneMetalEffect {
    let name: String
    let constants: [String: [Float]]
    let mask: SceneMetalTextureSource?
    let scripts: [String: String]
}

struct SceneMetalLayer {
    let id: String
    let name: String
    let source: SceneMetalTextureSource
    let position: SIMD2<Float>
    let size: SIMD2<Float>
    let scale: SIMD2<Float>
    let scaleScript: String?
    let scaleAnimation: WEVectorKeyframeAnimation?
    let opacity: Float
    let opacityScript: String?
    let opacityAnimation: WEKeyframeAnimation?
    let brightness: Float
    let brightnessScript: String?
    let color: SIMD4<Float>
    let colorScript: String?
    let text: SceneMetalText?
    let parallaxDepth: SIMD3<Float>
    let perspective: Bool
    let positionScript: String?
    let positionAnimation: WEVectorKeyframeAnimation?
    let sizeScript: String?
    let sizeAnimation: WEVectorKeyframeAnimation?
    let rotation: Float
    let rotationScript: String?
    let rotationAnimation: WEVectorKeyframeAnimation?
    let effects: SceneMaterialEffects
    let sceneEffects: [SceneMetalEffect]
}

struct SceneMetalText {
    let value: String
    let script: String?
    let font: String?
    let pointSize: CGFloat
    let horizontalAlignment: String?
    let verticalAlignment: String?
}

struct SceneMaterialEffects {
    let brightness: Float
    let contrast: Float
    let saturation: Float
    let bloom: Float
    let blur: Float
    let exposure: Float
    let gamma: Float
    let hue: Float
    let bloomThreshold: Float
    let transformAngle: Float
    let transformOffset: SIMD2<Float>
    let transformScale: SIMD2<Float>
    let scripts: [String: String]
}

struct SceneMetalParticleSystem {
    let source: SceneMetalTextureSource
    let origin: SIMD2<Float>
    let emissionRate: Float
    let emissionRateScript: String?
    let maximumParticleCount: Int
    let spawnRadius: Float
    let lifetime: ClosedRange<Float>
    let size: ClosedRange<Float>
    let minimumVelocity: SIMD2<Float>
    let maximumVelocity: SIMD2<Float>
    let gravity: SIMD2<Float>
    let drag: Float
    let dragScript: String?
    let alpha: ClosedRange<Float>
    let minimumColor: SIMD4<Float>
    let maximumColor: SIMD4<Float>
    let minimumRotation: Float
    let maximumRotation: Float
    let minimumAngularVelocity: Float
    let maximumAngularVelocity: Float
    let rendererName: String
    let trailLength: Float
    let trailSegments: Int
    let ropeSubdivision: Int
    let fadeTrailAlpha: Bool
    let fadeTrailSize: Bool
    let turbulence: Turbulence?
    let attractor: Attractor?
    let cursorControlPoint: CursorControlPoint?
    let emitterControlPoint: Int?
    let spriteSheet: SpriteSheet?
    let animationMode: String
    let sequenceMultiplier: Float
    let fadeIn: Float
    let fadeOut: Float
    let fadeInScript: String?
    let fadeOutScript: String?
    let blending: String
}

struct Turbulence {
    let scale: Float
    let speed: ClosedRange<Float>
    let timeScale: Float
    let phase: Float
    let mask: SIMD2<Float>
}

struct Attractor {
    let origin: SIMD2<Float>
    let strength: Float
    let threshold: Float
}

struct CursorControlPoint {
    let id: Int
    let offset: SIMD2<Float>
}

struct SpriteSheet {
    let columns: Int
    let rows: Int
    let frames: Int
    let duration: Float
}

struct SceneMetalContent {
    let size: SIMD2<Float>
    let layers: [SceneMetalLayer]
    let particleSystems: [SceneMetalParticleSystem]
    let effects: Set<String>
}

private struct LayerUniform {
    var position: SIMD2<Float>
    var size: SIMD2<Float>
    var sceneSize: SIMD2<Float>
    var opacity: Float
    var rotation: Float
    var color: SIMD4<Float>
    var uvOrigin: SIMD2<Float>
    var uvAxisX: SIMD2<Float>
    var uvAxisY: SIMD2<Float>
    var effects: SIMD4<Float>
    var blur: Float
    var colorEffects: SIMD4<Float>
    var transform: SIMD4<Float>
    var transformScaleY: Float
}

private struct DXTDecodeUniform {
    var width: UInt32
    var height: UInt32
    var blockColumns: UInt32
    var format: UInt32
}

private struct EffectUniform {
    var time: Float
    var pulse: Float
}

private struct EffectDescriptorGPU {
    var kind: UInt32
    var maskIndex: UInt32
    var values: SIMD4<Float>
    var extra: SIMD4<Float>
}

private struct EffectStack {
    let descriptors: [EffectDescriptorGPU]

    init(effects: [SceneMetalEffect], globalNames: Set<String>, sceneSize: SIMD2<Float>, audioLevel: Float) {
        var descriptors: [EffectDescriptorGPU] = []
        var names = Set<String>()
        for (index, effect) in effects.enumerated() {
            guard Self.isEnabled(effect.name) else { continue }
            let maskIndex = effect.mask == nil ? UInt32.max : UInt32(index)
            guard let descriptor = Self.descriptor(for: effect, maskIndex: maskIndex, sceneSize: sceneSize, audioLevel: audioLevel) else { continue }
            descriptors.append(descriptor)
            names.insert(effect.name)
        }
        for name in globalNames where !names.contains(name) {
            guard Self.isEnabled(name) else { continue }
            guard let descriptor = Self.descriptor(for: SceneMetalEffect(name: name, constants: [:], mask: nil, scripts: [:]), maskIndex: UInt32.max, sceneSize: sceneSize, audioLevel: audioLevel) else { continue }
            descriptors.append(descriptor)
        }
        self.descriptors = descriptors.isEmpty ? [EffectDescriptorGPU(kind: 0, maskIndex: UInt32.max, values: .zero, extra: .zero)] : descriptors
    }

    private static func isEnabled(_ name: String) -> Bool {
        AudioReactiveScriptEngine.shared.userPropertyString("_owe_effect_enabled_\(name)") != "false"
    }

    func bind(to encoder: MTLRenderCommandEncoder) {
        var count = UInt32(descriptors.count)
        descriptors.withUnsafeBufferPointer { buffer in
            encoder.setVertexBytes(buffer.baseAddress!, length: MemoryLayout<EffectDescriptorGPU>.stride * descriptors.count, index: 2)
            encoder.setFragmentBytes(buffer.baseAddress!, length: MemoryLayout<EffectDescriptorGPU>.stride * descriptors.count, index: 2)
        }
        encoder.setVertexBytes(&count, length: MemoryLayout<UInt32>.stride, index: 3)
        encoder.setFragmentBytes(&count, length: MemoryLayout<UInt32>.stride, index: 3)
    }

    private static func descriptor(for effect: SceneMetalEffect, maskIndex: UInt32,
                                   sceneSize: SIMD2<Float>, audioLevel: Float) -> EffectDescriptorGPU? {
        let value = { (name: String, fallback: Float) in
            let authored = effect.constants[name]?.first ?? fallback
            if let script = effect.scripts[name] {
                return AudioReactiveScriptEngine.shared.evaluate(script, fallback: authored)
            }
            return AudioReactiveScriptEngine.shared.userPropertyValue("_owe_effect_\(effect.name)_\(name)", fallback: authored)
        }
        let vector = { (name: String, fallback: SIMD4<Float>) in
            let values = effect.constants[name] ?? []
            let padded = values + Array(repeating: 0, count: max(0, 4 - values.count))
            return values.isEmpty ? fallback : SIMD4<Float>(padded[0], padded[1], padded[2], padded[3])
        }
        switch effect.name {
        case "shake":
            return EffectDescriptorGPU(kind: 1, maskIndex: maskIndex,
                                       values: SIMD4(value("strength", 0.1), value("speed", 1), value("friction", 1), audioLevel), extra: .zero)
        case "waterwaves":
            return EffectDescriptorGPU(kind: 2, maskIndex: maskIndex,
                                       values: SIMD4(value("strength", 0.1), value("speed", 5), value("scale", 200), value("direction", 0)),
                                       extra: SIMD4(value("exponent", 1), 0, 0, 0))
        case "nitro":
            let speeds = vector("speed", SIMD4(-0.1, 0.7, 0.1, -0.5))
            let scales = vector("scale", SIMD4(1, 2, 0, 0))
            let bounds = vector("bounds", SIMD4(0.3, 0.25, 0, 0))
            return EffectDescriptorGPU(kind: 3, maskIndex: maskIndex,
                                       values: SIMD4(value("multiply", 1), speeds.x, speeds.y, speeds.z), extra: SIMD4(speeds.w, scales.x, scales.y, bounds.x))
        case "vhs":
            return EffectDescriptorGPU(kind: 4, maskIndex: maskIndex,
                                       values: SIMD4(value("strength", 1.2), value("chromatic", 0.1), value("artifacts", 0.5), value("distortionstrength", 1)),
                                       extra: SIMD4(value("distortionspeed", 1), value("distortionwidth", 1), 0, 0))
        case "pulse":
            return EffectDescriptorGPU(kind: 5, maskIndex: maskIndex, values: SIMD4(audioLevel, 0, 0, 0), extra: .zero)
        case "iris":
            return EffectDescriptorGPU(kind: 6, maskIndex: maskIndex, values: .zero, extra: .zero)
        case "volumetricfog":
            return EffectDescriptorGPU(kind: 7, maskIndex: maskIndex,
                                       values: SIMD4(value("density", 0.65), value("drift", 0.035), 0.12, 0.8),
                                       extra: SIMD4(value("near", 0.45), value("far", 0.85), 0, 0))
        default:
            return nil
        }
    }
}

private struct PreparedLayer {
    let frames: [RenderTextureFrame]
    let layer: SceneMetalLayer
    let effectMasks: [MTLTexture?]
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
    let size: Float
    let alpha: Float
    var rotation: Float
    let angularVelocity: Float
    let color: SIMD4<Float>
    var history: [SIMD2<Float>]
}

private final class ParticleSystemRuntime {
    let texture: MTLTexture
    let configuration: SceneMetalParticleSystem
    var particles: [Particle] = []
    var emissionRemainder: Float = 0
    var elapsedTime: Float = 0

    init(texture: MTLTexture, configuration: SceneMetalParticleSystem) {
        self.texture = texture
        self.configuration = configuration
    }
}

final class SceneMetalRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let renderPipeline: MTLRenderPipelineState
    private let additiveRenderPipeline: MTLRenderPipelineState
    private let dxtDecodePipeline: MTLComputePipelineState
    private let textureLoader: MTKTextureLoader
    private let contentQueue = DispatchQueue(label: "SceneMetalRenderer.content", qos: .userInitiated)
    private let contentGenerationLock = NSLock()
    private var contentGeneration = 0
    private var sceneSize = SIMD2<Float>(1920, 1080)
    private var layers: [PreparedLayer] = []
    private var particleSystems: [ParticleSystemRuntime] = []
    private var lastFrameTime = CACurrentMediaTime()
    private var placement: WallpaperPlacement = .fill
    private var effects = Set<String>()
    private var sceneRenderTarget: MTLTexture?
    private var sceneRenderTargetSize = SIMD2<Float>.zero

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
        super.init()
        view.device = device
        view.delegate = self
        view.framebufferOnly = false
        view.enableSetNeedsDisplay = false
        view.isPaused = false
    }

    func setContent(_ content: SceneMetalContent?) {
        contentGenerationLock.lock()
        contentGeneration &+= 1
        let generation = contentGeneration
        contentGenerationLock.unlock()

        guard let content else {
            layers = []
            particleSystems = []
            return
        }
        contentQueue.async { [weak self] in
            guard let self, self.isCurrentContentGeneration(generation) else { return }
            let preparedLayers: [PreparedLayer] = content.layers.compactMap { layer in
                guard let frames = self.makeTextureFrames(from: layer.source), !frames.isEmpty else { return nil }
                let effectMasks = layer.sceneEffects.map { effect in
                    effect.mask.flatMap { self.makeTextureFrames(from: $0)?.first?.texture }
                }
                return PreparedLayer(frames: frames, layer: layer, effectMasks: effectMasks)
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
                self.layers = preparedLayers
                self.particleSystems = preparedParticleSystems
                var scriptLayers: [String: [String: Any]] = [:]
                var layerAliases: [String: String] = [:]
                for entry in preparedLayers {
                    scriptLayers[entry.layer.id] = [
                        "alpha": entry.layer.opacity,
                        "origin": ["x": entry.layer.position.x, "y": entry.layer.position.y],
                        "size": ["x": entry.layer.size.x, "y": entry.layer.size.y],
                        "angles": ["z": entry.layer.rotation]
                    ]
                    layerAliases[entry.layer.name] = entry.layer.id
                }
                AudioReactiveScriptEngine.shared.configureLayers(scriptLayers, aliases: layerAliases)
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

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let sceneTexture = sceneRenderTarget(matching: descriptor),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        let clearColor = descriptor.colorAttachments[0].clearColor
        let sceneRenderPass = MTLRenderPassDescriptor()
        sceneRenderPass.colorAttachments[0].texture = sceneTexture
        sceneRenderPass.colorAttachments[0].loadAction = .clear
        sceneRenderPass.colorAttachments[0].clearColor = clearColor
        sceneRenderPass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: sceneRenderPass) else { return }

        encoder.setRenderPipelineState(renderPipeline)
        // Render every layer/particle at native scene resolution; placement scaling happens once, in the final composite pass.
        let drawableSize = SIMD2<Float>(Float(sceneTexture.width), Float(sceneTexture.height))
        let realDrawableSize = SIMD2<Float>(Float(drawable.texture.width), Float(drawable.texture.height))
        let animationSpeed = AudioReactiveScriptEngine.shared.userPropertyValue("_owe_speed", fallback: 1)
        let time = Float(CACurrentMediaTime()) * animationSpeed
        let audioLevel = AudioReactiveScriptEngine.shared.audioLevel
        let frameDelta = min(Float(CACurrentMediaTime() - lastFrameTime), 1.0 / 15.0)
        AudioReactiveScriptEngine.shared.setSceneClock(deltaTime: Double(frameDelta))
        let cursor = sceneCursor(in: view, drawableSize: realDrawableSize)
        let cursorDelta = (cursor - sceneSize / 2) / sceneSize
        let parallaxEnabled = AudioReactiveScriptEngine.shared.userPropertyString("_owe_effect_enabled_parallax") != "false"
        for (layerIndex, entry) in layers.enumerated() {
            var effectUniform = EffectUniform(time: time,
                                              pulse: effects.contains("pulse") ? Float(audioLevel) : 0)
            encoder.setVertexBytes(&effectUniform, length: MemoryLayout<EffectUniform>.stride, index: 1)
            encoder.setFragmentBytes(&effectUniform, length: MemoryLayout<EffectUniform>.stride, index: 1)
            let effectStack = EffectStack(effects: entry.layer.sceneEffects, globalNames: effects,
                                          sceneSize: sceneSize, audioLevel: Float(audioLevel))
            effectStack.bind(to: encoder)
            let opacity = entry.layer.opacityScript.map {
                AudioReactiveScriptEngine.shared.evaluate($0, fallback: entry.layer.opacity, layerId: entry.layer.id)
            } ?? timelineValue(entry.layer.opacityAnimation, at: time, fallback: AudioReactiveScriptEngine.shared.layerValue(entry.layer.id, property: "alpha", fallback: entry.layer.opacity))
            let position = entry.layer.positionScript.flatMap {
                AudioReactiveScriptEngine.shared.evaluateVector2($0, fallback: entry.layer.position, layerId: entry.layer.id)
            }
                ?? vector2(timelineVector3(entry.layer.positionAnimation, at: time, fallback: SIMD3<Float>(entry.layer.position.x, entry.layer.position.y, 0)))
            let baseSize = entry.layer.sizeScript.flatMap {
                AudioReactiveScriptEngine.shared.evaluateVector2($0, fallback: entry.layer.size, layerId: entry.layer.id)
            }
                ?? vector2(timelineVector3(entry.layer.sizeAnimation, at: time, fallback: SIMD3<Float>(entry.layer.size.x, entry.layer.size.y, 0)))
            let scale = entry.layer.scaleScript.flatMap {
                AudioReactiveScriptEngine.shared.evaluateVector2($0, fallback: entry.layer.scale, layerId: entry.layer.id)
            } ?? vector2(timelineVector3(entry.layer.scaleAnimation, at: time, fallback: SIMD3<Float>(entry.layer.scale.x, entry.layer.scale.y, 1)))
            let hasAuthoredDepth = simd_length(entry.layer.parallaxDepth) > 0
            let fallbackDepth = Float(layerIndex + 1) / Float(max(layers.count, 1)) * 0.35
            let parallaxDepth = hasAuthoredDepth
                ? entry.layer.parallaxDepth
                : SIMD3<Float>(repeating: fallbackDepth)
            let parallaxOffset = parallaxEnabled
                ? SIMD2<Float>(parallaxDepth.x * cursorDelta.x * sceneSize.x * 0.1,
                               parallaxDepth.y * cursorDelta.y * sceneSize.y * 0.1)
                : .zero
            let perspectiveScale = parallaxEnabled && entry.layer.perspective
                ? 1 + parallaxDepth.z * simd_length(cursorDelta) * 0.1
                : 1
            let size = baseSize * scale * perspectiveScale
            let unclampedPosition = position + parallaxOffset
            let safePosition = SIMD2<Float>(
                safeParallaxPosition(unclampedPosition.x, baseSize: size.x, sceneExtent: sceneSize.x),
                safeParallaxPosition(unclampedPosition.y, baseSize: size.y, sceneExtent: sceneSize.y)
            )
            let rotation = entry.layer.rotationScript.map {
                AudioReactiveScriptEngine.shared.evaluate($0, fallback: entry.layer.rotation, layerId: entry.layer.id)
            } ?? timelineVector3(entry.layer.rotationAnimation, at: time, fallback: SIMD3<Float>(0, 0, entry.layer.rotation)).z
            var uniform = layerUniform(position: safePosition, size: size,
                                       opacity: opacity, drawableSize: drawableSize)
            if entry.layer.text != nil {
                uniform.opacity *= AudioReactiveScriptEngine.shared.userPropertyValue("_owe_text_\(entry.layer.id)_opacity", fallback: 1)
            }
            uniform.rotation = rotation
            let objectBrightness = entry.layer.brightnessScript.map {
                AudioReactiveScriptEngine.shared.evaluate($0, fallback: entry.layer.brightness, layerId: entry.layer.id)
            } ?? entry.layer.brightness
            let objectColor = entry.layer.colorScript.flatMap {
                AudioReactiveScriptEngine.shared.evaluateVector3($0,
                    fallback: SIMD3<Float>(entry.layer.color.x, entry.layer.color.y, entry.layer.color.z),
                    layerId: entry.layer.id)
            }.map { SIMD4<Float>($0.x, $0.y, $0.z, 1) } ?? entry.layer.color
            uniform.color = objectColor
            let materialEffects = entry.layer.effects
            let brightness = materialEffects.scripts["brightness"].map {
                AudioReactiveScriptEngine.shared.evaluate($0, fallback: materialEffects.brightness, layerId: entry.layer.id)
            } ?? materialEffects.brightness
            let contrast = materialEffects.scripts["contrast"].map {
                AudioReactiveScriptEngine.shared.evaluate($0, fallback: materialEffects.contrast, layerId: entry.layer.id)
            } ?? materialEffects.contrast
            let saturation = materialEffects.scripts["saturation"].map {
                AudioReactiveScriptEngine.shared.evaluate($0, fallback: materialEffects.saturation, layerId: entry.layer.id)
            } ?? materialEffects.saturation
            let bloom = materialEffects.scripts["bloom"].map {
                AudioReactiveScriptEngine.shared.evaluate($0, fallback: materialEffects.bloom, layerId: entry.layer.id)
            } ?? materialEffects.bloom
            uniform.effects = SIMD4<Float>(brightness * objectBrightness, contrast,
                                           saturation * AudioReactiveScriptEngine.shared.userPropertyValue("_owe_saturation", fallback: 1),
                                           bloom * AudioReactiveScriptEngine.shared.userPropertyValue("_owe_bloom", fallback: 1))
            uniform.blur = materialEffects.scripts["blur"].map {
                AudioReactiveScriptEngine.shared.evaluate($0, fallback: materialEffects.blur, layerId: entry.layer.id)
            } ?? materialEffects.blur * AudioReactiveScriptEngine.shared.userPropertyValue("_owe_blur", fallback: 1)
            uniform.colorEffects = SIMD4<Float>(materialEffects.exposure, materialEffects.gamma,
                                                materialEffects.hue + AudioReactiveScriptEngine.shared.userPropertyValue("_owe_hue", fallback: 0), materialEffects.bloomThreshold)
            uniform.transform = SIMD4<Float>(materialEffects.transformAngle, materialEffects.transformOffset.x,
                                             materialEffects.transformOffset.y, materialEffects.transformScale.x)
            uniform.transformScaleY = materialEffects.transformScale.y
            let textureFrame: RenderTextureFrame
            if let text = entry.layer.text {
                let value = text.script.map {
                    AudioReactiveScriptEngine.shared.evaluateString($0, fallback: text.value,
                                                                      layerId: entry.layer.id, time: Double(time))
                } ?? text.value
                textureFrame = makeTextFrame(text, value: value, size: size, layerID: entry.layer.id) ?? self.textureFrame(for: entry, time: time)
            } else {
                textureFrame = self.textureFrame(for: entry, time: time)
            }
            uniform.uvOrigin = textureFrame.uvOrigin
            uniform.uvAxisX = textureFrame.uvAxisX
            uniform.uvAxisY = textureFrame.uvAxisY
            encoder.setVertexBytes(&uniform, length: MemoryLayout<LayerUniform>.stride, index: 0)
            encoder.setFragmentBytes(&uniform, length: MemoryLayout<LayerUniform>.stride, index: 0)
            encoder.setFragmentTexture(textureFrame.texture, index: 0)
            for index in 0..<4 {
                encoder.setFragmentTexture(index < entry.effectMasks.count ? entry.effectMasks[index] : nil, index: index + 1)
            }
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        updateParticles(deltaTime: frameDelta, cursor: cursor)
        lastFrameTime = CACurrentMediaTime()
        for system in particleSystems {
            encoder.setRenderPipelineState(system.configuration.blending == "additive" ? additiveRenderPipeline : renderPipeline)
            if system.configuration.rendererName == "rope" {
                drawRope(system, drawableSize: drawableSize, encoder: encoder)
                continue
            }
            for particle in system.particles {
                if system.configuration.rendererName.contains("trail") || system.configuration.rendererName == "rope" {
                    drawParticleTrail(particle, system: system, drawableSize: drawableSize, encoder: encoder)
                }
                var uniform = layerUniform(position: particle.position,
                                           size: SIMD2<Float>(repeating: particle.size),
                                           opacity: particleOpacity(particle, in: system.configuration, time: system.elapsedTime),
                                           drawableSize: drawableSize)
                uniform.rotation = particle.rotation
                uniform.color = particle.color
                let uv = spriteSheetUV(for: particle, configuration: system.configuration)
                uniform.uvOrigin = uv.origin
                uniform.uvAxisX = SIMD2<Float>(uv.size.x, 0)
                uniform.uvAxisY = SIMD2<Float>(0, uv.size.y)
                encoder.setVertexBytes(&uniform, length: MemoryLayout<LayerUniform>.stride, index: 0)
                encoder.setFragmentBytes(&uniform, length: MemoryLayout<LayerUniform>.stride, index: 0)
                encoder.setFragmentTexture(system.texture, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
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
        var neutralEffectUniform = EffectUniform(time: 0, pulse: 0)
        compositeEncoder.setVertexBytes(&neutralEffectUniform, length: MemoryLayout<EffectUniform>.stride, index: 1)
        compositeEncoder.setFragmentBytes(&neutralEffectUniform, length: MemoryLayout<EffectUniform>.stride, index: 1)
        let neutralEffectStack = EffectStack(effects: [], globalNames: [], sceneSize: sceneSize, audioLevel: 0)
        neutralEffectStack.bind(to: compositeEncoder)
        var compositeUniform = layerUniform(position: sceneSize / 2, size: sceneSize, opacity: 1, drawableSize: realDrawableSize)
        compositeUniform.effects = SIMD4<Float>(1, 1, 1, 0)
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

    private func sceneRenderTarget(matching descriptor: MTLRenderPassDescriptor) -> MTLTexture? {
        let pixelSize = SIMD2<Float>(max(1, sceneSize.x.rounded()), max(1, sceneSize.y.rounded()))
        if let sceneRenderTarget, sceneRenderTargetSize == pixelSize { return sceneRenderTarget }

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: descriptor.colorAttachments[0].texture?.pixelFormat ?? .bgra8Unorm,
            width: Int(pixelSize.x), height: Int(pixelSize.y), mipmapped: false)
        textureDescriptor.usage = [.renderTarget, .shaderRead]
        textureDescriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: textureDescriptor) else { return nil }
        sceneRenderTarget = texture
        sceneRenderTargetSize = pixelSize
        return texture
    }

    private func makeTextFrame(_ text: SceneMetalText, value: String, size: SIMD2<Float>, layerID: String) -> RenderTextureFrame? {
        let image = NSImage(size: NSSize(width: CGFloat(max(size.x, 1)), height: CGFloat(max(size.y, 1))))
        image.lockFocus()
        let fontName = AudioReactiveScriptEngine.shared.userPropertyString("_owe_text_\(layerID)_font") ?? ""
        let sizeValue = AudioReactiveScriptEngine.shared.userPropertyValue("_owe_text_\(layerID)_size", fallback: Float(text.pointSize))
        var font = NSFont(name: fontName.isEmpty ? (text.font ?? "System") : fontName, size: CGFloat(sizeValue))
            ?? NSFont.systemFont(ofSize: CGFloat(sizeValue))
        let bold = AudioReactiveScriptEngine.shared.userPropertyString("_owe_text_\(layerID)_bold") == "true"
        let italic = AudioReactiveScriptEngine.shared.userPropertyString("_owe_text_\(layerID)_italic") == "true"
        if bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = text.horizontalAlignment == "left" ? .left : text.horizontalAlignment == "right" ? .right : .center
        let colorValue = AudioReactiveScriptEngine.shared.userPropertyString("_owe_text_\(layerID)_color") ?? "1 1 1"
        let rgb = colorValue.parseVector3()
        let color = NSColor(calibratedRed: CGFloat(rgb.0), green: CGFloat(rgb.1), blue: CGFloat(rgb.2), alpha: 1)
        let attributed = NSAttributedString(string: value, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
        let textSize = attributed.size()
        let y: CGFloat = text.verticalAlignment == "top" ? image.size.height - textSize.height
            : text.verticalAlignment == "bottom" ? 0 : (image.size.height - textSize.height) / 2
        attributed.draw(in: NSRect(x: 0, y: max(0, y), width: image.size.width, height: textSize.height))
        image.unlockFocus()
        return makeTextureFrames(from: .image(image))?.first
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
                                sceneSize: drawableSize, opacity: opacity, rotation: 0, color: SIMD4<Float>(repeating: 1),
                                uvOrigin: .zero, uvAxisX: SIMD2<Float>(1, 0), uvAxisY: SIMD2<Float>(0, 1), effects: .zero, blur: 0,
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
                            rotation: 0, color: SIMD4<Float>(repeating: 1),
                            uvOrigin: .zero, uvAxisX: SIMD2<Float>(1, 0), uvAxisY: SIMD2<Float>(0, 1), effects: .zero, blur: 0,
                            colorEffects: SIMD4<Float>(0, 1, 0, 0.7), transform: SIMD4<Float>(0, 0, 0, 1),
                            transformScaleY: 1)
    }

    private func sceneCursor(in view: MTKView, drawableSize: SIMD2<Float>) -> SIMD2<Float> {
        let mouse = view.convert(view.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
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

    private func textureFrame(for entry: PreparedLayer, time: Float) -> RenderTextureFrame {
        guard entry.frames.count > 1 else { return entry.frames[0] }
        let duration = entry.frames.map(\.duration).reduce(0, +)
        guard duration > 0 else { return entry.frames[0] }
        var frameTime = time.truncatingRemainder(dividingBy: duration)
        for frame in entry.frames {
            if frameTime < frame.duration { return frame }
            frameTime -= frame.duration
        }
        return entry.frames[0]
    }

    private func timelineValue(_ animation: WEKeyframeAnimation?, at time: Float, fallback: Float) -> Float {
        guard let keyframes = animation?.keyframes.sorted(by: { $0.frame < $1.frame }), !keyframes.isEmpty else { return fallback }
        let frame = Double(time * 60)
        guard let next = keyframes.first(where: { $0.frame >= frame }) else { return Float(keyframes.last!.value) }
        guard let previous = keyframes.last(where: { $0.frame <= frame }), previous.frame != next.frame else { return Float(next.value) }
        let progress = (frame - previous.frame) / (next.frame - previous.frame)
        return Float(previous.value + (next.value - previous.value) * progress)
    }

    private func timelineVector3(_ animation: WEVectorKeyframeAnimation?, at time: Float,
                                 fallback: SIMD3<Float>) -> SIMD3<Float> {
        guard let keyframes = animation?.keyframes.sorted(by: { $0.frame < $1.frame }), !keyframes.isEmpty else { return fallback }
        let frame = Double(time * 60)
        guard let next = keyframes.first(where: { $0.frame >= frame }) else {
            let value = keyframes.last!.value.vectorValue
            return SIMD3<Float>(Float(value.0), Float(value.1), Float(value.2))
        }
        guard let previous = keyframes.last(where: { $0.frame <= frame }), previous.frame != next.frame else {
            let value = next.value.vectorValue
            return SIMD3<Float>(Float(value.0), Float(value.1), Float(value.2))
        }
        let progress = Float((frame - previous.frame) / (next.frame - previous.frame))
        let start = previous.value.vectorValue
        let end = next.value.vectorValue
        return SIMD3<Float>(Float(start.0 + (end.0 - start.0) * Double(progress)),
                            Float(start.1 + (end.1 - start.1) * Double(progress)),
                            Float(start.2 + (end.2 - start.2) * Double(progress)))
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
            frame = Int(particle.rotation.bitPattern % UInt32(sheet.frames))
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
        commandBuffer.waitUntilCompleted()
        return commandBuffer.status == .completed ? texture : nil
    }

    private func updateParticles(deltaTime: Float, cursor: SIMD2<Float>) {
        for system in particleSystems {
            let configuration = system.configuration
            system.elapsedTime += deltaTime
            let emissionRate = configuration.emissionRateScript.map {
                AudioReactiveScriptEngine.shared.evaluate($0, fallback: configuration.emissionRate, time: Double(system.elapsedTime))
            } ?? configuration.emissionRate
            let drag = configuration.dragScript.map {
                AudioReactiveScriptEngine.shared.evaluate($0, fallback: configuration.drag, time: Double(system.elapsedTime))
            } ?? configuration.drag
            system.emissionRemainder += max(emissionRate, 0) * deltaTime
            let emissionCount = min(Int(system.emissionRemainder), configuration.maximumParticleCount - system.particles.count)
            system.emissionRemainder -= Float(emissionCount)
            for _ in 0..<max(emissionCount, 0) {
                let angle = Float.random(in: 0...(2 * .pi))
                let radius = sqrt(Float.random(in: 0...1)) * configuration.spawnRadius
                let spawnOrigin: SIMD2<Float>
                if let controlPoint = configuration.cursorControlPoint,
                   configuration.emitterControlPoint == controlPoint.id {
                    spawnOrigin = cursor + controlPoint.offset
                } else {
                    spawnOrigin = configuration.origin
                }
                system.particles.append(Particle(
                    position: spawnOrigin + SIMD2<Float>(cos(angle), sin(angle)) * radius,
                    velocity: SIMD2<Float>(Float.random(in: min(configuration.minimumVelocity.x, configuration.maximumVelocity.x)...max(configuration.minimumVelocity.x, configuration.maximumVelocity.x)),
                                           Float.random(in: min(configuration.minimumVelocity.y, configuration.maximumVelocity.y)...max(configuration.minimumVelocity.y, configuration.maximumVelocity.y))),
                    age: 0,
                    lifetime: Float.random(in: configuration.lifetime),
                    size: Float.random(in: configuration.size),
                    alpha: Float.random(in: configuration.alpha),
                    rotation: Float.random(in: configuration.minimumRotation...configuration.maximumRotation),
                    angularVelocity: Float.random(in: configuration.minimumAngularVelocity...configuration.maximumAngularVelocity),
                    color: SIMD4<Float>(Float.random(in: min(configuration.minimumColor.x, configuration.maximumColor.x)...max(configuration.minimumColor.x, configuration.maximumColor.x)),
                                        Float.random(in: min(configuration.minimumColor.y, configuration.maximumColor.y)...max(configuration.minimumColor.y, configuration.maximumColor.y)),
                                        Float.random(in: min(configuration.minimumColor.z, configuration.maximumColor.z)...max(configuration.minimumColor.z, configuration.maximumColor.z)), 1),
                    history: []))
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
                system.particles[index].velocity += configuration.gravity * deltaTime
                system.particles[index].velocity *= max(0, 1 - drag * deltaTime)
                system.particles[index].age += deltaTime
                system.particles[index].rotation += system.particles[index].angularVelocity * deltaTime
                system.particles[index].history.append(system.particles[index].position)
                if system.particles[index].history.count > configuration.trailSegments {
                    system.particles[index].history.removeFirst()
                }
            }
            system.particles.removeAll { $0.age >= $0.lifetime }
        }
    }

    private func drawParticleTrail(_ particle: Particle, system: ParticleSystemRuntime,
                                   drawableSize: SIMD2<Float>, encoder: MTLRenderCommandEncoder) {
        let history = particle.history
        guard history.count > 1 else { return }
        for (index, position) in history.enumerated() {
            let progress = Float(index) / Float(history.count)
            let opacity = particleOpacity(particle, in: system.configuration, time: system.elapsedTime)
                * (system.configuration.fadeTrailAlpha ? progress : 1)
            let size = particle.size * (system.configuration.fadeTrailSize ? max(progress, 0.15) : 1)
            var uniform = layerUniform(position: position, size: SIMD2<Float>(repeating: size),
                                       opacity: opacity, drawableSize: drawableSize)
            uniform.rotation = particle.rotation
            uniform.color = particle.color
            encoder.setVertexBytes(&uniform, length: MemoryLayout<LayerUniform>.stride, index: 0)
            encoder.setFragmentBytes(&uniform, length: MemoryLayout<LayerUniform>.stride, index: 0)
            encoder.setFragmentTexture(system.texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
    }

    private func drawRope(_ system: ParticleSystemRuntime, drawableSize: SIMD2<Float>,
                          encoder: MTLRenderCommandEncoder) {
        let particles = system.particles
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
                               particleOpacity(start, in: system.configuration, time: system.elapsedTime)
                                   + (particleOpacity(end, in: system.configuration, time: system.elapsedTime) - particleOpacity(start, in: system.configuration, time: system.elapsedTime)) * t))
            }
        }
        if let last = particles.last {
            spline.append((last.position, last.size, last.color, particleOpacity(last, in: system.configuration, time: system.elapsedTime)))
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
            encoder.setVertexBytes(&uniform, length: MemoryLayout<LayerUniform>.stride, index: 0)
            encoder.setFragmentBytes(&uniform, length: MemoryLayout<LayerUniform>.stride, index: 0)
            encoder.setFragmentTexture(system.texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
    }

    private func catmullRom(_ previous: SIMD2<Float>, _ start: SIMD2<Float>, _ end: SIMD2<Float>,
                            _ following: SIMD2<Float>, _ t: Float) -> SIMD2<Float> {
        let t2 = t * t
        let t3 = t2 * t
        return 0.5 * ((2 * start) + (-previous + end) * t
            + (2 * previous - 5 * start + 4 * end - following) * t2
            + (-previous + 3 * start - 3 * end + following) * t3)
    }

    private func particleOpacity(_ particle: Particle, in configuration: SceneMetalParticleSystem, time: Float) -> Float {
        let progress = particle.age / particle.lifetime
        let fadeInValue = configuration.fadeInScript.map {
            AudioReactiveScriptEngine.shared.evaluate($0, fallback: configuration.fadeIn, time: Double(time))
        } ?? configuration.fadeIn
        let fadeOutValue = configuration.fadeOutScript.map {
            AudioReactiveScriptEngine.shared.evaluate($0, fallback: configuration.fadeOut, time: Double(time))
        } ?? configuration.fadeOut
        let fadeIn = fadeInValue > 0 ? min(progress / fadeInValue, 1) : 1
        let fadeOut = fadeOutValue < 1 ? min((1 - progress) / (1 - fadeOutValue), 1) : 1
        return particle.alpha * fadeIn * fadeOut
    }
}