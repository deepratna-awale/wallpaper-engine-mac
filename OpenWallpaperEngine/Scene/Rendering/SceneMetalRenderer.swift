import Cocoa
import MetalKit
import CryptoKit

private struct PreparedLayer {
    let frames: [RenderTextureFrame]
    let layer: SceneMetalLayer
    /// Where the layer's own transform comes from each frame.
    let motion: SceneObjectMotion
    /// The particle systems to draw before this layer: every system whose authored order is below
    /// this (`SceneRendererScripts.drawOrder`).
    var particleBarrier: Int

    init(frames: [RenderTextureFrame], layer: SceneMetalLayer) {
        self.frames = frames
        self.layer = layer
        motion = SceneObjectMotion(layer: layer)
        particleBarrier = layer.order
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
    /// This frame's parallax and `cameraparallaxamount` (times the app's amount), when objects
    /// are displaced: parallax on in an orthographic scene.
    let parallax: (state: SceneCameraParallax, amount: Float)?
    /// How far camera shake moved the camera; the scene moves the other way.
    let shake: SIMD2<Float>
    let audioLevel: Double
}

private struct RenderTextureFrame {
    let texture: MTLTexture
    let duration: Float
    let uvOrigin: SIMD2<Float>
    let uvAxisX: SIMD2<Float>
    let uvAxisY: SIMD2<Float>
    /// Text only: the glyphs' coverage, which WE's `font` material samples; nil for colour glyphs.
    var coverage: MTLTexture? = nil
}

final class SceneMetalRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    /// The drawables' format, which the layer and copy pipelines draw in.
    private let pixelFormat: MTLPixelFormat
    private let commandQueue: MTLCommandQueue
    /// The scene pass's own pipelines, in the scene target's format (`SceneLayerPipelines`).
    private let layerPipelines: SceneLayerPipelines
    private var renderPipeline: MTLRenderPipelineState { layerPipelines.pipelines(for: sceneRenderTarget?.pixelFormat).normal }
    private var additiveRenderPipeline: MTLRenderPipelineState {
        layerPipelines.pipelines(for: sceneRenderTarget?.pixelFormat).additive
    }
    /// An unblended copy in the drawables' format: a shared frame onto a display (`present(in:)`).
    private let copyPipeline: MTLRenderPipelineState
    /// Everything after the scene pass, up to the drawable (bloom and the composite).
    let postProcess: ScenePostProcess
    /// WE's work on the finished frame before its bloom (`SceneFrameStages`).
    private let frameStages: [SceneFrameStage]
    /// The stage that keeps `_rt_MipMappedFrameBuffer` (internal for tests and diagnostics), and
    /// its target for this frame's draws.
    let mipMappedFrameBuffer: SceneMipMappedFrameBuffer?
    private var mipMappedTarget: MTLTexture?
    /// The volumetrics stage (tests and diagnostics).
    var volumetrics: SceneVolumetrics? { frameStages.lazy.compactMap { $0 as? SceneVolumetrics }.first }
    private let dxtDecodePipeline: MTLComputePipelineState
    private let textureLoader: MTKTextureLoader
    private let renderTargetPool: SceneRenderTargetPool
    /// This frame's scene snapshot target (`sceneSnapshot`), leased on first use, and which part
    /// of it matches the scene drawn so far.
    private var sceneCopy: MTLTexture?
    /// This frame's scene snapshot goes into `_rt_MipMappedFrameBuffer`'s level 0
    /// (`SceneMipMappedFrameBuffer.snapshotCanShare`).
    private var snapshotSharesMipMappedTarget = false
    private(set) var snapshotTracker = SceneSnapshotTracker()
    /// Trims rebuildable memory when the system asks (`trimMemory`).
    private var memoryPressure: SceneMemoryPressure?
    /// Runs authored effects through Wallpaper Engine's own shaders.
    private lazy var effectGraph = EffectGraphRenderer(device: device)
    /// How much larger full detail would draw this frame's scene target (1 unless the scene is
    /// matched to a display smaller than it, `GSSceneDetail.matchDisplay`): the size effects on
    /// scene regions and text, and the bloom, stand for.
    private var fullDetailScale: Float = 1
    /// Bumped for every prelit image an effect chain starts from (`runEffects`).
    private var prelitVersion: UInt64 = 0
    /// Times the effect passes when set (profiling; `EffectPassTimer`).
    var effectPassTimer: EffectPassTimer? {
        get { effectGraph?.passTimer }
        set { effectGraph?.passTimer = newValue }
    }
    /// Draws particle systems through their WE material.
    private lazy var particleMaterials = ParticleMaterialRenderer(device: device)
    /// Draws image layers through their own WE material.
    private lazy var imageMaterials = ImageMaterialRenderer(device: device, archive: effectGraph?.pipelineArchive)
    /// Asset textures used by effect passes, materialised once per content.
    private var effectAssetTextures: [String: MTLTexture] = [:]
    /// Animated asset textures' sprite frames, by the same key.
    private var effectAssetFrames: [String: [RenderTextureFrame]] = [:]
    /// Textureless layers' effect inputs (`solidEffectInput`), by layer id; once per content.
    private var solidEffectInputs: [String: MTLTexture] = [:]
    /// Scene time since the content loaded, speed applied; drives animations, `g_Time`,
    /// particles and scripts alike.
    private var clock = SceneClock()
    /// The wall clock `clock` follows (tests step it).
    var wallTime: () -> CFTimeInterval = { CACurrentMediaTime() }
    /// The wallpaper instance's timelines and texture clocks (docs/timeline-plan.md §2), advanced
    /// once per frame by `clock`'s delta, before the scripts run.
    let timelines = SceneRendererAnimations()
    /// The instance's `SceneAnimationSet`; nil without a scene document.
    var animations: SceneAnimationSet? { timelines.set }
    /// Records what each frame draws while set (tests and diagnostics, `SceneDrawProbe`).
    var drawProbe: SceneDrawProbe?
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
    /// The wallpaper instance's scripts and what their last frame left.
    let scripts: SceneRendererScripts
    /// The scene's sound layers; the view sets their gain (`sounds.setTargetGain`).
    let sounds: SceneSoundLayers
    /// When the sounds last advanced (real time: their timers follow the audio, not scene speed).
    private var lastSoundTime: CFTimeInterval?
    /// Particle systems and sounds scripts created, by object id, kept across content rebuilds
    /// like `scriptLayers`.
    private var scriptParticles: [String: (systems: [ParticleSystemRuntime], motion: SceneObjectMotion)] = [:]
    private var scriptSounds: [Int: SceneSoundContent] = [:]
    /// Layers scripts created (`thisScene.createLayer`), kept across content rebuilds, by id, with
    /// their base `visible`.
    private var scriptLayers: [String: (entry: PreparedLayer, visible: Bool)] = [:]
    /// Layers scripts destroyed while they were still being built.
    private var destroyedScriptLayers = Set<String>()
    /// `emitParticles` counts waiting for their system's next step, by object id.
    private var pendingEmits: [String: Int] = [:]
    /// How many particle systems are drawn (tests, diagnostics).
    var particleSystemCount: Int { particleSystems.count }
    /// Layers drawn through their material, and prelighting passes run (tests, diagnostics).
    var imageMaterialDraws: Int { imageMaterials?.drawsEncoded ?? 0 }
    var imageMaterialPrelitDraws: Int { imageMaterials?.prelitDraws ?? 0 }
    /// Effect passes encoded so far, for tests.
    var effectPassesEncoded: Int { effectGraph?.passesEncoded ?? 0 }
    /// The last frame's scene target, before the post-process (tests, diagnostics).
    var lastSceneTarget: MTLTexture? { sceneRenderTarget }
    /// The bytes of the frame's own targets, by holder (diagnostics, test-risks LR10); the effect
    /// graph's layer and bloom buffers aren't among them.
    var frameTargetBytes: [String: Int] {
        ["scene target": sceneRenderTarget?.allocatedSize ?? 0,
         "mip-mapped frame buffer": mipMappedFrameBuffer?.texture?.allocatedSize ?? 0,
         "target pool (snapshots, regions)": renderTargetPool.residentBytes,
         "volumetrics": volumetrics?.residentBytes ?? 0,
         "prelit images": imageMaterials?.prelitBytes ?? 0]
    }
    /// A drawn layer's effect plans (tests, diagnostics).
    func effectPlans(ofLayer id: String) -> [SceneEffectPlan] {
        layers.first { $0.layer.id == id }?.layer.weEffects ?? []
    }
    /// Script-created layers still being built (tests wait for them).
    private(set) var pendingScriptLayers = 0
    /// The last `setContent` has been applied (its layers and scripts are in place).
    private(set) var hasContent = false
    /// Which object each authored scene index is, for the draw order scripts set.
    private var objectIDs: [Int] = []
    private var camera = SceneCameraEffects()
    /// `general.clearcolor` (`SceneMetalContent.clearColor`); a script's `thisScene.clearcolor` wins.
    private var clearColor = SceneGeneralDefaults.clearColor
    /// WE's parallax camera position, eased across frames (`SceneCameraParallax`).
    private var cameraParallax = SceneCameraParallax(sceneSize: SIMD2<Float>(1920, 1080))
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
    /// The scene's lighting settings and light objects (`SceneMetalContent.lighting`).
    private var lighting = SceneLightingContent()
    /// The user's quality settings (post-processing, reflection, shadows, volumetrics); the view sets them.
    var renderSettings = SceneRenderSettings()
    private var sceneRenderTarget: MTLTexture?
    /// This frame's prelit images (`prelit`), by layer id.
    private var prelitImages: [String: MTLTexture] = [:]
    /// A shared scene's finished frame, the scene target's size (`sharedFrame`).
    private var sharedFrameTarget: MTLTexture?
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
    /// A shared scene's latest finished frame (`renderShared`), which its displays present.
    private(set) var sharedFrame: MTLTexture?
    /// The last `present(in:)`'s command buffer (tests and benchmarks).
    private(set) var lastPresentCommandBuffer: MTLCommandBuffer?
    /// Destroyed script layers' ids, freed once the frame that last drew them completes.
    private var deferredReleases = SceneDeferredReleases()
    /// Where the cursor was last seen on this display, in display pixels from the top-left.
    private var lastCursorScreenPixels = SIMD2<Double>(repeating: 0)
    /// This renderer's view of the desktop's left clicks.
    private var clickReader = DesktopClickReader()
    /// The last drawn frame's camera motion and text sizes (by layer id), for the next script frame.
    private var lastCameraMotion: CameraMotion?
    private var lastTextSizes: [String: SIMD2<Float>] = [:]
    /// Told how long each frame took on the CPU, including the wait for a drawable.
    var frameTimeObserver: ((CFTimeInterval) -> Void)?

    /// Where particle systems are simulated. The CPU simulation is the reference the GPU one is
    /// tested against (`ParticleSimulationParityTests`), and the fallback when compute is unavailable.
    enum ParticleSimulation {
        case gpu, cpu
    }

    /// A renderer that draws into `view` itself (`draw(in:)`). `scriptServices` runs the scenes'
    /// SceneScripts (nil runs none); `screenID` names the display whose script storage they use.
    convenience init?(view: MTKView, particleSimulation: ParticleSimulation = .gpu, scriptServices: SceneScriptServices? = nil,
                      screenID: String = "") {
        self.init(pixelFormat: view.colorPixelFormat, particleSimulation: particleSimulation,
                  scriptServices: scriptServices, screenID: screenID)
        configure(view)
        view.delegate = self
    }

    /// A renderer for drawables of `pixelFormat`. A shared scene's displays each show its frames
    /// through their own view (`configure`, `renderShared`, `present(in:)`).
    init?(pixelFormat: MTLPixelFormat, particleSimulation: ParticleSimulation = .gpu,
          scriptServices: SceneScriptServices? = nil, screenID: String = "") {
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

        let descriptor = SceneLayerPipelines.layerDescriptor(vertex: vertex, fragment: fragment, format: pixelFormat)
        let layerPipelines: SceneLayerPipelines
        do {
            // The drawable's format, and the HDR scene target's (docs/lighting-plan.md §2.6).
            layerPipelines = try SceneLayerPipelines(device: device, vertex: vertex, fragment: fragment,
                                                     copyFragment: copyFragment, formats: [pixelFormat, .rgba16Float])
        } catch {
            OWELog.error(.scene, "The scene pipelines can't be made: \(error)")
            return nil
        }

        guard let postProcess = ScenePostProcess(device: device, layerDescriptor: descriptor) else {
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
        self.pixelFormat = pixelFormat
        self.copyPipeline = layerPipelines.pipelines(for: pixelFormat).copy
        self.postProcess = postProcess
        let frameStages = SceneFrameStages.make(device: device)
        self.frameStages = frameStages
        self.mipMappedFrameBuffer = frameStages.lazy.compactMap { $0 as? SceneMipMappedFrameBuffer }.first
        self.commandQueue = commandQueue
        self.layerPipelines = layerPipelines
        self.dxtDecodePipeline = decodePipeline
        self.textureLoader = MTKTextureLoader(device: device)
        self.renderTargetPool = SceneRenderTargetPool(device: device)
        scripts = SceneRendererScripts(services: scriptServices, screenID: screenID)
        sounds = SceneSoundLayers(label: screenID.isEmpty ? "sounds" : "sounds \(screenID)")
        super.init()
        memoryPressure = SceneMemoryPressure { [weak self] level in self?.trimMemory(level) }
    }

    /// Sets `view` up to show this renderer's frames: on its device, drawn by the view's own timer.
    /// Its delegate is whoever draws it: this renderer, or a shared scene's presenter.
    func configure(_ view: MTKView) {
        view.device = device
        view.colorPixelFormat = pixelFormat
        view.framebufferOnly = false
        view.enableSetNeedsDisplay = false
        view.isPaused = false
    }

    /// Drops what can be rebuilt under memory pressure: free pooled targets, cached text other than
    /// the layers' current strings, spare effect targets and free uniform chunks; when critical,
    /// also effect asset textures and pipelines idle since the last critical trim. Leased and
    /// persistent targets, layers' own targets and anything the current frame uses stay.
    func trimMemory(_ level: SceneMemoryPressure.Level) {
        let before = renderTargetPool.residentBytes
        renderTargetPool.removeAll()
        textFrameCache.trim(to: layers.filter { $0.layer.text != nil }.count)
        effectGraph?.trimMemory(dropIdlePipelines: level == .critical)
        imageMaterials?.trimMemory(dropIdlePipelines: level == .critical)
        particleMaterials?.trimMemory(dropIdlePipelines: level == .critical)
        if level == .critical {
            effectAssetTextures.removeAll()
            effectAssetFrames.removeAll()
            solidEffectInputs.removeAll()
        }
        OWELog.info(.scene, "Memory pressure (\(level)): freed \((before - renderTargetPool.residentBytes) >> 20) MB of pooled targets")
    }

    /// Drops every prepared layer, releasing any video stream those layers hold.
    func releaseContent() {
        setContent(nil)
    }

    func setContent(_ content: SceneMetalContent?) {
        effectAssetTextures.removeAll()
        effectAssetFrames.removeAll()
        solidEffectInputs.removeAll()
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
            scripts.stop()
            timelines.clear()
            sounds.stopAll()
            lastSoundTime = nil
            scriptParticles.removeAll()
            scriptSounds.removeAll()
            scriptLayers.removeAll()
            destroyedScriptLayers.removeAll()
            pendingEmits.removeAll()
            objectIDs = []
            hasContent = false
            textFrameCache.removeAll()
            textRasterScales.removeAll()
            clock = SceneClock()
            transforms = .empty
            lastPointer = nil
            lastCameraMotion = nil
            lastTextSizes.removeAll()
            cameraParallax = SceneCameraParallax(sceneSize: sceneSize)
            cursorTracker = SceneCursorTracker()
            deferredReleases.removeAll()
            lastCommandBuffer = nil
            return
        }
        contentQueue.async { [weak self] in
            guard let self, self.isCurrentContentGeneration(generation) else { return }
            let preparedLayers: [PreparedLayer] = content.layers.compactMap { layer in
                guard let frames = self.makeTextureFrames(from: layer.source), !frames.isEmpty else { return nil }
                return PreparedLayer(frames: frames, layer: layer)
            }
            let runtimes: [ParticleSystemRuntime?] = content.particleSystems.enumerated().map { index, system in
                guard let texture = self.makeTextureFrames(from: system.source)?.first?.texture else { return nil }
                let fallback = system.fallbackSource.flatMap { self.makeTextureFrames(from: $0)?.first?.texture }
                // Seeded by position in the scene, so a wallpaper's particles replay the same way.
                return ParticleSystemRuntime(texture: texture, configuration: system, seed: ParticleRandom.pcg(UInt32(index)),
                                             fallbackTexture: fallback)
            }
            ParticleSystemRuntime.linkFamilies(runtimes)
            let preparedParticleSystems = runtimes.compactMap { $0 }
            guard self.isCurrentContentGeneration(generation) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrentContentGeneration(generation) else { return }
                self.sceneSize = content.size
                self.sharedFrame = nil
                self.bloom = content.bloom
                self.lighting = content.lighting
                for stage in self.frameStages { stage.setContent(content) }
                self.postProcess.setContent(content)
                self.particleSystems = preparedParticleSystems
                self.transforms = content.transforms
                self.objectMotions = content.motions
                self.objectIDs = content.objectIDs
                self.wallpaperKey = content.wallpaperKey
                self.camera = content.camera
                self.clearColor = content.clearColor
                self.cameraParallax = SceneCameraParallax(sceneSize: content.size)
                self.lastCameraMotion = nil
                self.lastTextSizes.removeAll()
                self.textFrameCache.removeAll()
                self.textRasterScales.removeAll()
                let running = self.scripts.wallpaper
                self.scripts.setContent(content.scripts, visibility: content.visibility,
                                        parents: content.transforms.nodes.compactMapValues(\.parentID))
                self.timelines.setTimelines(content.timelines,
                                            restart: self.scripts.wallpaper != nil && self.scripts.wallpaper !== running)
                if self.scripts.wallpaper == nil || self.scripts.wallpaper !== running {
                    // New scripts: the old ones' layers are gone with them.
                    self.scriptLayers.removeAll()
                    self.destroyedScriptLayers.removeAll()
                    self.pendingEmits.removeAll()
                    self.scriptParticles.removeAll()
                    self.scriptSounds.removeAll()
                }
                for (id, created) in self.scriptParticles {
                    self.particleSystems += created.systems
                    self.objectMotions[id] = created.motion
                }
                self.sounds.setContent(content.sounds + self.scriptSounds.keys.sorted().compactMap { self.scriptSounds[$0] })
                for (id, created) in self.scriptLayers { self.scripts.setBaseVisibility(created.visible, for: id) }
                self.layers = preparedLayers + self.scriptLayers.values.map(\.entry)
                self.timelines.registerTextures(self.layers.compactMap(Self.textureAnimation))
                self.orderLayers()
                self.hasContent = true
                self.clock = SceneClock()
            }
        }
    }

    private var currentContentGeneration: Int {
        contentGenerationLock.lock()
        defer { contentGenerationLock.unlock() }
        return contentGeneration
    }

    private func isCurrentContentGeneration(_ generation: Int) -> Bool {
        contentGenerationLock.lock()
        defer { contentGenerationLock.unlock() }
        return contentGeneration == generation
    }

    func setPlacement(_ placement: WallpaperPlacement) {
        self.placement = placement
    }

    /// Applies what scripts changed in the scene's structure: builds the layers `createLayer` made
    /// (off the main thread, through the loader; drawn once ready), drops destroyed ones (their GPU
    /// state freed after the in-flight frame) and queues `emitParticles` counts.
    private func applyScriptEvents(_ events: [SceneScriptRenderEvent]) {
        var removed: [String] = []
        for event in events {
            switch event {
            case .create(let id, let object):
                timelines.addObject(object, id: id)
                buildScriptLayer(String(id), object: object)
            case .destroy(let id):
                let key = String(id)
                let createdParticles = scriptParticles.removeValue(forKey: key)
                let createdSound = scriptSounds.removeValue(forKey: id)
                if scriptLayers.removeValue(forKey: key) == nil, createdParticles == nil, createdSound == nil {
                    destroyedScriptLayers.insert(key)
                }
                layers.removeAll { $0.layer.id == key }
                textRasterScales.removeValue(forKey: key)
                if createdParticles != nil {
                    particleSystems.removeAll { particleObjectID($0) == key }
                    objectMotions.removeValue(forKey: key)
                }
                sounds.remove(id)
                timelines.removeObject(id)
                removed.append(key)
            case .emit(let id, let count):
                pendingEmits[String(id), default: 0] += count ?? 1
            case .sound(let id, let playback):
                sounds.perform(playback, on: id)
            case let .animation(site, time, flags, rate, frame):
                timelines.restore(site, time: time, flags: flags, rate: rate, seenAt: frame)
            case let .textureAnimation(id, control, frame):
                timelines.restoreTexture(control, object: id, seenAt: frame)
            }
        }
        if !removed.isEmpty {
            // The last frame that drew these may still be on the GPU; free their effect targets
            // once it has finished (`releaseFinishedEffectState`).
            deferredReleases.enqueue(removed, after: lastCommandBuffer)
        }
    }

    // MARK: - Timelines

    /// An animated texture's layer shares its texture's clock (§2.7), frame times in sheet order.
    private func registerTextureAnimation(_ entry: PreparedLayer) {
        guard let animation = Self.textureAnimation(entry) else { return }
        timelines.registerTexture(object: animation.id, texture: animation.texture, frameTimes: animation.frameTimes)
    }

    private static func textureAnimation(_ entry: PreparedLayer) -> (id: Int, texture: String, frameTimes: [Float])? {
        guard let key = entry.layer.textureKey, let id = Int(entry.layer.id) else { return nil }
        return (id, key, entry.frames.map(\.duration))
    }

    /// Builds an object a script created through the loader, off the main thread: a layer, a
    /// particle system (with its children) or a sound.
    private func buildScriptLayer(_ id: String, object: [String: SceneJSON]) {
        guard let makeLayer = scripts.makeLayer else { return }
        var visible = true
        if case .bool(let flag)? = object["visible"] { visible = flag }
        let generation = currentContentGeneration
        let wallpaper = scripts.wallpaper
        pendingScriptLayers += 1
        contentQueue.async { [weak self] in
            guard let self else { return }
            let built: PreparedScriptObject? = {
                guard self.isCurrentContentGeneration(generation) else { return nil }
                guard let created = makeLayer(object) else {
                    OWELog.error(.script, "createLayer: object \(id) can't be built")
                    return nil
                }
                return self.prepare(created, id: id)
            }()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pendingScriptLayers -= 1
                guard let built, self.isCurrentContentGeneration(generation), self.scripts.wallpaper === wallpaper else { return }
                guard self.destroyedScriptLayers.remove(id) == nil else { return }
                self.scripts.setBaseVisibility(visible, for: id)
                switch built {
                case .layer(let entry):
                    self.scriptLayers[id] = (entry, visible)
                    self.layers.append(entry)
                    self.registerTextureAnimation(entry)
                case .particles(let systems, let motion):
                    self.scriptParticles[id] = (systems, motion)
                    self.objectMotions[id] = motion
                    self.particleSystems.append(contentsOf: systems)
                case .sound(let content):
                    self.scriptSounds[content.id] = content
                    self.sounds.add(content)
                }
                self.orderLayers()
            }
        }
    }

    /// A created object with its textures loaded (off the main thread).
    private enum PreparedScriptObject {
        case layer(PreparedLayer)
        case particles([ParticleSystemRuntime], motion: SceneObjectMotion)
        case sound(SceneSoundContent)
    }

    private func prepare(_ created: SceneScriptCreatedObject, id: String) -> PreparedScriptObject? {
        switch created {
        case .layer(var layer):
            layer.order = Int.max
            guard let frames = makeTextureFrames(from: layer.source), !frames.isEmpty else { return nil }
            return .layer(PreparedLayer(frames: frames, layer: layer))
        case .particles(let systems, let motion):
            // Above every authored object, like WE's createLayer; the scripts' order places it.
            let runtimes: [ParticleSystemRuntime?] = systems.enumerated().map { index, system in
                var system = system
                system.order = Int(Int32.max)
                guard let texture = makeTextureFrames(from: system.source)?.first?.texture else { return nil }
                let fallback = system.fallbackSource.flatMap { makeTextureFrames(from: $0)?.first?.texture }
                let seed = UInt32(truncatingIfNeeded: (Int(id) ?? 0) &* 31 &+ index)
                return ParticleSystemRuntime(texture: texture, configuration: system, seed: ParticleRandom.pcg(seed),
                                             fallbackTexture: fallback)
            }
            ParticleSystemRuntime.linkFamilies(runtimes)
            let prepared = runtimes.compactMap { $0 }
            return prepared.isEmpty ? nil : .particles(prepared, motion: motion)
        case .sound(let content):
            return .sound(content)
        }
    }

    /// Puts `layers` in draw order (the scene's, or the one scripts set) with each layer's
    /// particle barrier.
    private func orderLayers() {
        let systems = particleSystems.map { system -> (id: String?, order: Int) in
            let order = system.configuration.order
            if order >= 0 && order < objectIDs.count { return (String(objectIDs[order]), order) }
            return (particleObjectID(system), order)
        }
        let order = SceneRendererScripts.drawOrder(layers: layers.map { ($0.layer.id, $0.layer.order) },
                                                   systems: systems, scriptOrder: scripts.state.order)
        var ordered: [PreparedLayer] = []
        ordered.reserveCapacity(layers.count)
        for (index, position) in order.sequence.enumerated() {
            var entry = layers[position]
            entry.particleBarrier = order.barriers[index]
            ordered.append(entry)
        }
        layers = ordered
    }

    /// Frees the effect state of destroyed script layers whose last frame the GPU has finished.
    private func releaseFinishedEffectState() {
        guard deferredReleases.count > 0 else { return }
        deferredReleases.drain(live: Set(layers.map(\.layer.id))) { id in
            effectGraph?.releaseLayer(id)
            imageMaterials?.releaseLayer(id)
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    /// Renders a frame for `view` alone and presents it there.
    func draw(in view: MTKView) {
        renderFrame(.view(view))
    }

    /// Renders one frame for all the displays of a shared scene, at the largest scene target any
    /// of them needs; the cursor comes from the display it is on. Each display then shows the
    /// frame at its own size (`present(in:)`). The first viewport is the driving display, whose
    /// resolution scripts see.
    func renderShared(_ viewports: [SceneViewport]) {
        guard !viewports.isEmpty else { return }
        renderFrame(.shared(viewports))
    }

    /// Shows the latest shared frame (`renderShared`) on `view`, at its size and the user's
    /// placement: one pass per display.
    func present(in view: MTKView) {
        guard let frame = sharedFrame, let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable, let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        let size = SIMD2<Float>(Float(drawable.texture.width), Float(drawable.texture.height))
        let pixelsPerPoint = view.bounds.width > 0 ? size.x / Float(view.bounds.width) : 1
        var uniform = layerUniform(position: sceneSize / 2, size: sceneSize, opacity: 1, drawableSize: size,
                                   placement: placement, pixelsPerPoint: pixelsPerPoint)
        encoder.setRenderPipelineState(copyPipeline)
        encoder.setVertexBytes(&uniform, length: MemoryLayout<LayerUniform>.stride, index: 0)
        encoder.setFragmentTexture(frame, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
        lastPresentCommandBuffer = commandBuffer
    }

    /// Where a frame goes: one view's drawable, or a shared scene's finished frame.
    private enum FrameOutput {
        case view(MTKView)
        case shared([SceneViewport])
    }

    /// The frame's pass onto `output` (nil for a shared frame until its size is known), its
    /// viewports and the placement the post-process composites with.
    private func frameDestination(_ output: FrameOutput) -> SceneFrameDestination? {
        switch output {
        case .view(let view):
            guard let descriptor = view.currentRenderPassDescriptor, let drawable = view.currentDrawable else { return nil }
            let size = SIMD2<Float>(Float(drawable.texture.width), Float(drawable.texture.height))
            return SceneFrameDestination(descriptor: descriptor, drawable: drawable,
                                         pixelFormat: drawable.texture.pixelFormat, placement: placement,
                                         viewports: [SceneViewport(view, drawableSize: size)])
        case .shared(let viewports):
            // The finished frame keeps the scene's aspect; each display places it when presenting.
            return SceneFrameDestination(descriptor: nil, drawable: nil, pixelFormat: pixelFormat, placement: .stretch,
                                         viewports: viewports)
        }
    }

    /// The pass onto a shared scene's finished frame, the size of `scene`.
    private func sharedFramePass(matching scene: MTLTexture) -> MTLRenderPassDescriptor? {
        if sharedFrameTarget?.width != scene.width || sharedFrameTarget?.height != scene.height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: scene.width,
                                                                      height: scene.height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            sharedFrameTarget = device.makeTexture(descriptor: descriptor)
            if sharedFrameTarget == nil {
                OWELog.error(.scene, "Could not allocate the \(scene.width)×\(scene.height) shared frame")
            }
        }
        guard let target = sharedFrameTarget else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = SceneFrameDestination.clearColor
        pass.colorAttachments[0].storeAction = .store
        return pass
    }

    private func renderFrame(_ output: FrameOutput) {
        let frameStart = CACurrentMediaTime()
        let frameSignpost = OWESignpost.begin(OWESignpost.render, "frame")
        WallpaperServices.shared.beginFrame(wallpaper: wallpaperKey)
        renderTargetPool.endFrame()
        defer {
            WallpaperServices.shared.endFrame()
            frameSignpost.end()
            frameTimeObserver?(CACurrentMediaTime() - frameStart)
            if OWEFrameMetrics.isReportingEnabled {
                OWEFrameMetrics.recordFrame(seconds: CACurrentMediaTime() - frameStart,
                                            layers: layers.count,
                                            particles: particleSystems.reduce(0) { $0 + ($1.gpu?.completedCount ?? $1.particles.count) })
            }
        }

        guard let destination = frameDestination(output) else { return }
        let viewports = destination.viewports
        drawablePixelsPerPoint = viewports[0].pixelsPerPoint
        // The largest target any display needs, so each shows the scene at its own density.
        let renderDrawable = SceneRenderResolution.drawableSize(viewports, resolution: renderSettings.renderResolution)
        renderPixelsPerUnit = SceneRenderResolution.pixelsPerUnit(sceneSize: sceneSize, drawableSize: renderDrawable,
                                                                  matchDisplay: renderSettings.sceneDetail == .matchDisplay)
        // A scene matched to a smaller display is drawn below full detail: what its buffers stand for.
        fullDetailScale = SceneRenderResolution.pixelsPerUnit(sceneSize: sceneSize, drawableSize: renderDrawable)
            / renderPixelsPerUnit
        // A content drawn in HDR draws into RGBA16F (docs/lighting-plan.md §2.6).
        guard let sceneTexture = sceneRenderTarget(pixelFormat: postProcess.drawsHDR ? .rgba16Float : destination.pixelFormat),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let descriptor = destination.descriptor ?? sharedFramePass(matching: sceneTexture) else {
            return
        }
        // What the post-process composites onto: the drawable, or the shared frame.
        let realDrawableSize = SIMD2<Float>(Float(descriptor.colorAttachments[0].texture?.width ?? sceneTexture.width),
                                            Float(descriptor.colorAttachments[0].texture?.height ?? sceneTexture.height))

        // Layers and particles are drawn in scene units onto a target at the output's pixel
        // density; placement scaling happens once, in the final composite pass.
        let drawableSize = SIMD2<Float>(Float(sceneTexture.width), Float(sceneTexture.height))
        // Draws sample the last frame's copy; this frame's is made after the scene pass.
        mipMappedTarget = mipMappedFrameBuffer?.target(matching: sceneTexture, commandBuffer: commandBuffer)
        let animationSpeed = WallpaperServices.shared.userPropertyValue("_owe_speed", fallback: 1)
        clock.advance(to: wallTime(), speed: Double(animationSpeed))
        let sceneTime = clock.time
        let time = Float(sceneTime)
        // What a script frame that overran the last draw's wait left (they run on their own thread, §4.5).
        let orderBefore = scripts.state.order
        applyScriptEvents(scripts.beginFrame())
        // WE writes every timeline before the scripts run; a script's calls act on the next advance.
        let animationEvents = timelines.advance(by: Float(clock.delta))
        drawProbe?.beginFrame()
        let cursorSample = cursorTracker.update(sceneCursor(viewports), sceneSize: sceneSize)
        let cursor = cursorSample.position
        // WE's scripts and `g_PointerState` see only clicks that land on the wallpaper.
        let leftDown = cursorSample.onDisplay
            && clickReader.isDown(scripts.services?.clicks?.state ?? DesktopClickMonitor.State())
        releaseFinishedEffectState()
        prelitImages.removeAll(keepingCapacity: true)
        beginTransformFrame()
        if scripts.isRunning {
            // Like WE, the scripts run before the frame that shows what they did (§4.4): this
            // frame's clock, cursor and animated values go in, and their results are drawn now
            // unless they overrun the wait (then they show from the next draw on).
            let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            submitScriptFrame(viewports: viewports, cursor: cursorSample, leftDown: leftDown,
                              animationEvents: animationEvents)
            scripts.record(since: start, newFrame: false)
            applyScriptEvents(scripts.finishFrame(waitingUpTo: scripts.frameWait))
            beginTransformFrame()
        }
        if scripts.state.order != orderBefore {
            orderLayers()
            beginTransformFrame()
        }
        updateSounds()
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
        effectFrame.pointerState = BuiltinFrameContext.pointerState(primaryDown: leftDown)
        effectFrame.screenSize = drawableSize
        effectFrame.textureReductionScale = Float(renderSettings.textureReduction)
        effectFrame.audio = WallpaperServices.shared.advanceAudioSpectrumFrame()
        let motion = cameraMotion(pointer: pointer, time: time, deltaTime: Float(clock.delta))
        effectFrame.parallax = parallaxEnabled ? cameraParallax.shaderPosition(sceneSize: sceneSize) : SIMD2(0.5, 0.5)
        // WE's camera eye and forward (ctx+0x68, ctx+0x160); the renderer keeps the camera still
        // and moves the objects by the shake instead (`SceneFrameLightingInput.cameraShake`).
        effectFrame.eyePosition = lighting.camera.eye
        effectFrame.viewForward = lighting.camera.forward
        effectFrame.lighting = frameLighting(eye: effectFrame.eyePosition, forward: effectFrame.viewForward,
                                             shake: motion.shake)
        drawProbe?.record(lighting: effectFrame.lighting)
        // Text is rasterised first so its effects run on the finished text, like an image layer's.
        var textFrames: [Int: (frame: RenderTextureFrame, baseSize: SIMD2<Float>)] = [:]
        // Only visible layers get an entry; the draw loop skips the rest.
        var draws: [Int: LayerDraw] = [:]
        for (layerIndex, entry) in layers.enumerated() {
            // Hidden layers keep their transforms (scripts and hit tests read them) but draw nothing.
            guard scripts.isVisible(entry.layer.id) else { continue }
            if entry.layer.text != nil {
                let world = worldTransform(entry)
                let onScreen = max(world.axisScale.x, world.axisScale.y) * renderPixelsPerUnit
                let pixelsPerUnit = SceneTextRasterScale.layer(onScreen: onScreen,
                                                               hasEffects: !entry.layer.weEffects.isEmpty)
                textFrames[layerIndex] = layerTextFrame(entry, boxSize: layerBaseSize(entry),
                                                        pixelsPerUnit: pixelsPerUnit)
            }
            let draw = layerDraw(entry, baseSize: textFrames[layerIndex]?.baseSize ?? layerBaseSize(entry),
                                 motion: motion)
            draws[layerIndex] = draw
            // Layers that read the scene run inside the scene pass, once what's beneath them is drawn.
            if entry.layer.readsScene { continue }
            if !entry.layer.weEffects.isEmpty {
                let input = solidEffectInput(entry.layer, commandBuffer: commandBuffer)
                    ?? (textFrames[layerIndex]?.frame ?? textureFrame(for: entry)).texture
                dynamicTextures[layerIndex] = runEffects(entry, draw: draw, input: input,
                                                         snapshot: nil, frame: effectFrame, commandBuffer: commandBuffer)
            }
        }
        // The next script frame reads this frame's text sizes and camera (WE's cursor pass and
        // `size` see the last drawn frame).
        lastTextSizes.removeAll(keepingCapacity: true)
        for (index, frame) in textFrames { lastTextSizes[layers[index].layer.id] = frame.baseSize }
        lastCameraMotion = motion

        // WE clears the scene to `general.clearcolor` (the composite's letterbox stays black).
        let clear = scripts.state.scene.vector3(.clearcolor) ?? clearColor
        let sceneRenderPass = MTLRenderPassDescriptor()
        sceneRenderPass.colorAttachments[0].texture = sceneTexture
        sceneRenderPass.colorAttachments[0].loadAction = .clear
        sceneRenderPass.colorAttachments[0].clearColor = MTLClearColor(red: Double(clear.x), green: Double(clear.y),
                                                                       blue: Double(clear.z), alpha: 1)
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
            // A hidden system (its own `visible` or a parent's) neither steps nor draws.
            let objectID = particleObjectID(system)
            if let objectID, !scripts.isVisible(objectID) { continue }
            let script = objectID.flatMap(scripts.object)
            let scripted = script.flatMap(SceneScriptInstanceOverrides.init)
            let base = particleInstances.count
            let emitter = emitterWorld(system.configuration, motion: motion)
            // `starttime`: the system's first frame comes after WE's pre-simulation.
            // WE's engine frame time and frame-rate limit steer drag and the operators' half steps
            // (`ParticleFrameInputs.dragDeltaTime`, `substeps`); the pre-simulation runs in this frame.
            let prewarm = ParticlePrewarm.steps(system).map {
                ParticleFrameInputs.advance(system, deltaTime: $0, cursor: cursor, emitter: emitter, values: timelines.values,
                                            scripted: scripted,
                                            audio: effectFrame.audio, frameTime: Float(clock.delta),
                                            frameRateLimit: destination.frameRateLimit)
            }
            // A script's `pause()` holds the system as it is; `stop()` clears it until `play()`.
            let paused = script?.playback == .pause
            var inputs = ParticleFrameInputs.advance(system, deltaTime: paused ? 0 : Float(clock.delta), cursor: cursor,
                                                     emitter: emitter, values: timelines.values, scripted: scripted,
                                                     audio: effectFrame.audio,
                                                     frameTime: Float(clock.delta), frameRateLimit: destination.frameRateLimit)
            Self.applyScriptPlayback(script?.playback, emitting: objectID.flatMap { pendingEmits.removeValue(forKey: $0) },
                                     to: &inputs)
            if particleSimulator != nil {
                // The GPU steps the system and writes whichever records it is drawn from.
                let rendererName = system.configuration.rendererName
                if let simulated = particleMaterials?.prepareSimulated(system, pixelFormat: sceneTexture.pixelFormat) {
                    let kind = ParticleGPUDrawKind.material(simulated.format, rendererName: rendererName)
                    for step in prewarm {
                        particleRequests.append(.init(system: system, inputs: step, kind: kind, materialVertexCount: simulated.vertexCount))
                    }
                    particleRequests.append(.init(system: system, inputs: inputs, kind: kind,
                                                  materialVertexCount: simulated.vertexCount, renderVar: simulated.renderVar))
                    particleBatches.append((system, base, 0, true, true))
                } else {
                    let kind = ParticleGPUDrawKind.fallback(rendererName: rendererName)
                    for step in prewarm { particleRequests.append(.init(system: system, inputs: step, kind: kind)) }
                    particleRequests.append(.init(system: system, inputs: inputs, kind: kind))
                    particleBatches.append((system, base, 0, false, true))
                }
                continue
            }
            for step in prewarm { ParticleCPUSimulation.step(system, inputs: step) }
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
                        let axes = system.spriteAxes(size: particle.size, rotation: particle.rotation,
                                                     scale: drawableSize / sceneSize)
                        uniform.quadAxisX = axes.x
                        uniform.quadAxisY = axes.y
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
        /// One instanced draw per system, for every system authored before `order`. False when the
        /// scene pass couldn't resume after a snapshot.
        func drawParticleBatches(before order: Int) -> Bool {
            var drew = false
            while nextParticleBatch < particleBatches.count,
                  particleBatches[nextParticleBatch].system.configuration.order < order {
                let batch = particleBatches[nextParticleBatch]
                nextParticleBatch += 1
                if batch.material {
                    var snapshot: MTLTexture?
                    if particleMaterials?.readsSceneSnapshot(batch.system) == true {
                        // Refraction reads the scene drawn up to this system (`_rt_FullFrameBuffer`).
                        encoder.endEncoding()
                        snapshot = sceneSnapshot(of: sceneTexture, commandBuffer: commandBuffer)
                        guard let resumed = resumeScenePass(on: sceneTexture, commandBuffer: commandBuffer) else { return false }
                        encoder = resumed
                    }
                    particleMaterials?.draw(batch.system, encoder: encoder, commandBuffer: commandBuffer, context: .init(
                        sceneSize: sceneSize, frame: effectFrame,
                        values: timelines.values,
                        assetTexture: { [unowned self] key, source in self.effectAssetTexture(key: key, source: source) },
                        sceneSnapshot: snapshot, mipMappedFrameBuffer: mipMappedTarget))
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
                    encoder.setFragmentTexture(batch.system.fallbackTexture, index: 0)
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
                encoder.setFragmentTexture(batch.system.fallbackTexture, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                       instanceCount: batch.count, baseInstance: batch.base)
                drew = true
            }
            if drew { encoder.setRenderPipelineState(renderPipeline) }
            return true
        }
        sceneCopy = nil
        snapshotSharesMipMappedTarget = mipMappedTarget != nil && SceneMipMappedFrameBuffer.snapshotCanShare(
            layers: layers.lazy.map(\.layer), particleSystems: particleSystems.map(\.configuration),
            reflection: renderSettings.reflection)
        snapshotTracker.reset()
        let targetSize = SIMD2(sceneTexture.width, sceneTexture.height)
        for (layerIndex, entry) in layers.enumerated() {
            let batchesBefore = nextParticleBatch
            guard drawParticleBatches(before: entry.particleBarrier) else { return }
            // Particles cover no rect we track: the snapshot no longer matches anywhere.
            if nextParticleBatch != batchesBefore { snapshotTracker.sceneDrawn(in: nil) }
            // Hidden layers (script `visible = false`) draw nothing, their raw texture included.
            guard let draw = draws[layerIndex] else { continue }
            var layerSnapshot: MTLTexture?
            if entry.layer.readsScene {
                // Metal can't sample the attachment it's drawing into: pause the scene pass, run
                // this layer's effects on what's drawn so far (`_rt_FullFrameBuffer`), resume. The
                // effects read the target itself while the pass is paused; only a material that
                // reads the scene from inside the resumed pass needs a copy of it.
                encoder.endEncoding()
                var snapshot: MTLTexture? = sceneTexture
                if entry.layer.imageMaterial?.readsSceneSnapshot == true {
                    // A material or scene input reads the scene under its own quad; an effect anywhere.
                    let needed = entry.layer.effectsReadScene ? nil
                        : SceneSnapshotTracker.pixelRect(of: draw.quad, sceneSize: sceneSize, targetSize: targetSize)
                            ?? SceneSnapshotTracker.Rect.empty
                    snapshot = sceneSnapshot(of: sceneTexture, commandBuffer: commandBuffer, needing: needed)
                    layerSnapshot = snapshot
                }
                let input = entry.layer.sceneInput
                    ? snapshot.flatMap { sceneRegion(of: $0, under: draw.quad, reducedFor: entry.layer,
                                                     commandBuffer: commandBuffer) }
                    : solidEffectInput(entry.layer, commandBuffer: commandBuffer)
                        ?? (textFrames[layerIndex]?.frame ?? textureFrame(for: entry)).texture
                dynamicTextures[layerIndex] = input.flatMap {
                    runEffects(entry, draw: draw, input: $0, snapshot: snapshot, frame: effectFrame, commandBuffer: commandBuffer)
                }
                guard let resumed = resumeScenePass(on: sceneTexture, commandBuffer: commandBuffer) else { return }
                encoder = resumed
                // Until its effects are ready the layer has nothing of its own to draw.
                if entry.layer.sceneInput, dynamicTextures[layerIndex] == nil { continue }
            }
            var uniform = layerUniform(position: draw.quad.center, size: draw.quad.extent,
                                       opacity: draw.opacity, drawableSize: drawableSize, placement: .stretch)
            setQuadAxes(&uniform, quad: draw.quad)
            // Text is rasterised white; its user colour tints it when drawn, like its authored one.
            let textTint = entry.layer.text == nil ? SIMD3<Float>(repeating: 1) : self.textTint(layerID: entry.layer.id)
            uniform.color = draw.color * SIMD4(textTint, 1)
            let materialEffects = entry.layer.effects
            uniform.effects = SIMD4<Float>(materialEffects.brightness * draw.brightness, materialEffects.contrast,
                                           materialEffects.saturation
                                               * (1 + (entry.layer.musicSync?.saturationAmount ?? 0) * Float(draw.musicSyncLevel)),
                                           materialEffects.bloom * WallpaperServices.shared.userPropertyValue("_owe_bloom", fallback: 1))
            uniform.blur = materialEffects.blur * WallpaperServices.shared.userPropertyValue("_owe_blur", fallback: 1)
            uniform.colorEffects = SIMD4<Float>(materialEffects.exposure, materialEffects.gamma,
                                                materialEffects.hue, materialEffects.bloomThreshold)
            uniform.transform = SIMD4<Float>(materialEffects.transformAngle, materialEffects.transformOffset.x,
                                             materialEffects.transformOffset.y, materialEffects.transformScale.x)
            uniform.transformScaleY = materialEffects.transformScale.y
            let textureFrame = textFrames[layerIndex]?.frame ?? self.textureFrame(for: entry)
            uniform.uvOrigin = textureFrame.uvOrigin
            uniform.uvAxisX = textureFrame.uvAxisX
            uniform.uvAxisY = textureFrame.uvAxisY
            // Drawn below, natively or through its material.
            if let drawn = SceneSnapshotTracker.pixelRect(of: draw.quad, sceneSize: sceneSize, targetSize: targetSize) {
                snapshotTracker.sceneDrawn(in: drawn)
            }
            // A text layer's `font` material reads the glyphs' coverage; colour glyphs have none.
            // A prelit layer whose chain rendered nothing (every effect hidden, or compiling) draws
            // its prelit image: its own draw has the lighting off, so the raw image would be unlit.
            let materialTexture = entry.layer.text == nil
                ? dynamicTextures[layerIndex] ?? prelitImages[entry.layer.id] ?? textureFrame.texture
                : textureFrame.coverage
            if let plan = entry.layer.imageMaterial, let imageMaterials, let materialTexture, imageMaterials.draw(plan, ImageMaterialRenderer.Draw(
                   layerID: entry.layer.id, quad: draw.quad, sceneSize: sceneSize,
                   color: SIMD3(draw.color.x, draw.color.y, draw.color.z) * textTint, alpha: draw.opacity, brightness: draw.brightness,
                   texture: materialTexture, contentSize: entry.layer.source.contentSize,
                   uvOrigin: textureFrame.uvOrigin, uvAxisX: textureFrame.uvAxisX, uvAxisY: textureFrame.uvAxisY,
                   sceneSnapshot: layerSnapshot, mipMappedFrameBuffer: mipMappedTarget, frame: effectFrame,
                   values: timelines.values,
                   assetTexture: { [unowned self] key, source in self.effectAssetTexture(key: key, source: source) },
                   assetSprite: { [unowned self] key, source in self.effectAssetSprite(key: key, source: source) },
                   ignoredAdjustments: !ImageMaterialRenderer.nativeAdjustmentsAreIdentity(uniform, brightness: draw.brightness)),
                   pixelFormat: sceneTexture.pixelFormat, encoder: encoder, commandBuffer: commandBuffer) {
                encoder.setRenderPipelineState(renderPipeline)
                continue
            }
            encoder.setVertexBytes(&uniform, length: MemoryLayout<LayerUniform>.stride, index: 0)
            encoder.setFragmentBytes(&uniform, length: MemoryLayout<LayerUniform>.stride, index: 0)
            encoder.setFragmentTexture(dynamicTextures[layerIndex] ?? textureFrame.texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        guard drawParticleBatches(before: .max) else { return }
        encoder.endEncoding()

        var stageContext = SceneFrameStageContext(scene: sceneTexture, commandBuffer: commandBuffer, sceneSize: sceneSize,
                                                  frame: effectFrame, settings: renderSettings)
        stageContext.assetTexture = { [unowned self] key, source in self.effectAssetTexture(key: key, source: source) }
        for stage in frameStages { stage.encode(stageContext) }
        // The scene-resolution target goes onto the real drawable, placement applied exactly once.
        postProcess.encode(ScenePostProcess.Frame(
            scene: sceneTexture, output: descriptor, commandBuffer: commandBuffer,
            placement: layerUniform(position: sceneSize / 2, size: sceneSize, opacity: 1, drawableSize: realDrawableSize,
                                    placement: destination.placement),
            bloom: liveBloom(), extras: appExtras(), settings: renderSettings,
            effects: effectGraph, builtins: effectFrame, values: timelines.values, fullDetailScale: fullDetailScale))

        if let drawable = destination.drawable {
            commandBuffer.present(drawable)
        } else {
            sharedFrame = descriptor.colorAttachments[0].texture
        }
        commandBuffer.commit()
        lastCommandBuffer = commandBuffer
    }

    /// The scene's bloom this frame: `thisScene.bloom`, `bloomstrength` and `bloomthreshold` once a
    /// script set them, else their timelines, else the content's.
    private func liveBloom() -> ScenePostProcess.Bloom {
        let scene = scripts.state.scene
        return ScenePostProcess.Bloom(
            enabled: scene.flag(.bloom) ?? bloom.enabled,
            strength: scene.scalar(.bloomstrength) ?? timelines.sceneScalar(.bloomstrength) ?? bloom.strength,
            threshold: scene.scalar(.bloomthreshold) ?? timelines.sceneScalar(.bloomthreshold) ?? bloom.threshold,
            tint: bloom.tint, hdr: liveHDRBloom())
    }

    /// The HDR bloom's `bloomhdr*` this frame: a bound script's, else its timeline's, else the
    /// content's. Whether the scene draws in HDR stays the content's (WE decides it at load).
    private func liveHDRBloom() -> SceneHDRBloomSettings {
        var hdr = bloom.hdr
        hdr.strength = sceneSetting(.bloomhdrstrength) ?? hdr.strength
        hdr.threshold = sceneSetting(.bloomhdrthreshold) ?? hdr.threshold
        hdr.feather = sceneSetting(.bloomhdrfeather) ?? hdr.feather
        hdr.scatter = sceneSetting(.bloomhdrscatter) ?? hdr.scatter
        // An int property: WE's converter truncates (`ToInt32`).
        if let iterations = sceneSetting(.bloomhdriterations), iterations.isFinite, abs(iterations) < 1e9 {
            hdr.iterations = Int(iterations)
        }
        return hdr
    }

    /// The app's own whole-scene adjustments, from this wallpaper's user properties.
    private func appExtras() -> ScenePostProcess.AppExtras {
        let services = WallpaperServices.shared
        return ScenePostProcess.AppExtras(bloom: services.userPropertyValue("_owe_bloom", fallback: 1),
                                          saturation: services.userPropertyValue("_owe_saturation", fallback: 1),
                                          hue: services.userPropertyValue("_owe_hue", fallback: 0),
                                          blur: services.userPropertyValue("_owe_blur", fallback: 1))
    }

    /// This frame's lighting (`SceneFrameLighting`), from the objects' live transforms and
    /// visibility, the scripts' scene colours and the user's shadows setting.
    private func frameLighting(eye: SIMD3<Float>, forward: SIMD3<Float>, shake: SIMD2<Float>) -> SceneFrameLighting {
        let scene = scripts.state.scene
        return SceneFrameLighting.frame(lighting, input: SceneFrameLightingInput(
            local: { [unowned self] id in self.liveLocal(id) ?? self.transforms.nodes[id]?.local },
            parentWorld: { [unowned self] id in self.transforms.parentWorld(of: id) { self.liveLocal($0) } },
            isVisible: { [unowned self] id in self.scripts.isVisible(id) },
            sceneColor: { scene.vector3($0) },
            live: { [unowned self] object in
                object.live(script: self.scripts.object(object.id), animation: self.timelines.object(object.id),
                            timeline: { self.timelines.objectField(object.id, $0) })
            },
            shadows: renderSettings.shadows != .disabled, cameraShake: shake,
            eyePosition: eye, viewForward: forward))
    }

    /// WE's sound layers each frame: the volumes scripts set, then their timers, in real time. A
    /// gap in drawing (a paused wallpaper) counts as at most `maxSoundStep`: its sounds were paused.
    private func updateSounds() {
        guard !sounds.isEmpty else {
            lastSoundTime = nil
            return
        }
        for id in sounds.ids {
            if let volume = scripts.object(String(id))?.scalar(.volume) ?? timelines.object(String(id))?.volume {
                sounds.setVolume(volume, of: id)
            }
        }
        let now = CACurrentMediaTime()
        if let last = lastSoundTime { sounds.update(deltaTime: min(now - last, Self.maxSoundStep)) }
        lastSoundTime = now
    }

    static let maxSoundStep: CFTimeInterval = 0.25

    /// Hands the scripts this frame: the clock, the display and cursor, and every object at this
    /// frame's time with the last drawn frame's transforms, text sizes and camera
    /// (docs/scenescript-plan.md §4.4). They run on their own thread; `finishFrame` waits for them.
    private func submitScriptFrame(viewports: [SceneViewport],
                                   cursor: (position: SIMD2<Float>, onDisplay: Bool), leftDown: Bool,
                                   animationEvents: [SceneAnimationEvent]) {
        let drawableSize = viewports[0].drawableSize
        var input = SceneScriptFrameInput()
        input.deltaTime = clock.delta
        timelines.describe(into: &input, events: animationEvents)
        input.environment = SceneScriptEngineEnvironment(
            screenResolution: SIMD2(Double(drawableSize.x), Double(drawableSize.y)),
            canvasSize: SIMD2(Double(sceneSize.x), Double(sceneSize.y)), placement: placement,
            pixelsPerPoint: Double(drawablePixelsPerPoint))
        input.input = SceneScriptInput(cursorScreenPosition: cursorScreenPixels(viewports), cursorLeftDown: leftDown)
        input.cursorScenePosition = cursor.position
        input.shakeOffset = lastCameraMotion?.shake ?? .zero
        if let parallax = lastCameraMotion?.parallax {
            input.parallax = SceneScriptCursorFrame.Parallax(state: parallax.state, amount: parallax.amount)
        }
        for entry in layers {
            guard let id = Int(entry.layer.id) else { continue }
            let script = scripts.object(entry.layer.id)
            let base = baseValues(entry)
            let animation = timelines.object(entry.layer.id)
            let own = entry.motion.local(animation: animation, script: script, scriptValues: false)
            input.objects[id] = SceneScriptObjectFeedback(
                origin: own.origin, scale: own.scale, angle: own.angle,
                alpha: baseOpacity(entry, base: base),
                color: animation?.color ?? SIMD3(base.color.x, base.color.y, base.color.z),
                brightness: animation?.brightness ?? base.brightness,
                visible: scripts.baseVisible(entry.layer.id),
                size: lastTextSizes[entry.layer.id] ?? layerBaseSize(entry),
                world: worldTransform(entry), animated: animation?.fields ?? SceneScriptOwnedFields())
        }
        for (key, objectMotion) in objectMotions {
            guard let id = Int(key) else { continue }
            let animation = timelines.object(key)
            let own = objectMotion.local(animation: animation, script: scripts.object(key), scriptValues: false)
            input.objects[id] = SceneScriptObjectFeedback(
                origin: own.origin, scale: own.scale, angle: own.angle, alpha: nil, color: nil, brightness: nil,
                visible: scripts.baseVisible(key), size: nil,
                world: transforms.world(of: key) { [self] id in liveLocal(id) },
                animated: animation?.fields ?? SceneScriptOwnedFields(), playing: sounds.isPlaying(id))
        }
        scripts.submit(input)
    }

    /// The cursor in display pixels from the top-left of the wallpaper's view on the display it is
    /// on (`input.cursorScreenPosition`); where it was last seen while it is on none of them.
    private func cursorScreenPixels(_ viewports: [SceneViewport]) -> SIMD2<Double> {
        guard let pixels = viewports.lazy.compactMap(\.cursorScreenPixels).first else { return lastCursorScreenPixels }
        lastCursorScreenPixels = pixels
        return pixels
    }

    /// The scene's own `general.cameraparallax` (possibly user-bound, or set by a script) or the
    /// app's parallax toggle.
    private var parallaxEnabled: Bool {
        if let scripted = scripts.state.scene.flag(.cameraparallax) { return scripted }
        return camera.parallax || WallpaperServices.shared.userPropertyString("_owe_effect_enabled_parallax") == "true"
    }

    /// WE's camera shake, then its parallax (`SceneCameraShake`, `SceneCameraParallax`), in the
    /// order its scene update runs them: the parallax target includes the shaken eye. Scripts'
    /// `thisScene.camerashake…`/`cameraparallax…` settings override the scene's.
    private func cameraMotion(pointer: SIMD2<Float>, time: Float, deltaTime: Float) -> CameraMotion {
        let scene = scripts.state.scene
        let shaking = scene.flag(.camerashake) ?? camera.shake
        let shake = shaking
            ? SceneCameraShake.cameraOffset(time: time, speed: sceneSetting(.camerashakespeed) ?? camera.shakeSpeed,
                                            amplitude: sceneSetting(.camerashakeamplitude) ?? camera.shakeAmplitude,
                                            roughness: sceneSetting(.camerashakeroughness) ?? camera.shakeRoughness,
                                            orthographicHeight: camera.orthographic ? sceneSize.y : nil)
            : .zero
        var parallax: (state: SceneCameraParallax, amount: Float)?
        if parallaxEnabled {
            cameraParallax.update(cursor: pointer, eye: SIMD2(shake.x, shake.y), sceneSize: sceneSize,
                                  influence: sceneSetting(.cameraparallaxmouseinfluence) ?? camera.parallaxMouseInfluence,
                                  delay: sceneSetting(.cameraparallaxdelay) ?? camera.parallaxDelay,
                                  deltaTime: deltaTime)
            // `_owe_effect_parallax_amount` is an app extra, 1 (WE's amount) by default.
            let amount = (sceneSetting(.cameraparallaxamount) ?? camera.parallaxAmount)
                * WallpaperServices.shared.userPropertyValue("_owe_effect_parallax_amount", fallback: 1)
            if camera.orthographic { parallax = (cameraParallax, amount) }
        }
        return CameraMotion(parallax: parallax, shake: SIMD2(shake.x, shake.y),
                            audioLevel: WallpaperServices.shared.audioLevel)
    }

    /// A number of the scene's settings this frame: a script's, else its timeline's; nil leaves
    /// the authored (or user-bound) one.
    private func sceneSetting(_ field: SceneScriptSceneField) -> Float? {
        scripts.state.scene.scalar(field) ?? timelines.sceneScalar(field)
    }

    /// The parallax offset of a layer: its root object's live origin and `parallaxDepth`.
    private func parallaxOffset(_ entry: PreparedLayer, local: SceneLocalTransform,
                                motion: CameraMotion) -> SIMD2<Float> {
        guard let parallax = motion.parallax else { return .zero }
        let rootID = transforms.root(of: entry.layer.id)
        if rootID == entry.layer.id {
            let depth = entry.layer.parallaxDepth
            let scripted = scripts.object(rootID)?.vector2(.parallaxDepth) ?? timelines.object(rootID)?.parallaxDepth
            return parallax.state.offset(rootOrigin: local.origin, rootDepth: scripted ?? SIMD2(depth.x, depth.y),
                                         amount: parallax.amount)
        }
        guard let node = transforms.nodes[rootID] else { return .zero }
        let rootLocal = liveLocal(rootID) ?? node.local
        return parallax.state.offset(rootOrigin: rootLocal.origin, rootDepth: parallaxDepth(of: rootID, node: node),
                                     amount: parallax.amount)
    }

    /// A root object's `parallaxDepth`: a script's, else its timeline's, else authored.
    private func parallaxDepth(of id: String, node: SceneTransformHierarchy.Node) -> SIMD2<Float> {
        scripts.object(id)?.vector2(.parallaxDepth) ?? timelines.object(id)?.parallaxDepth ?? node.parallaxDepth
    }

    /// A visible layer's opacity, colour and placed quad this frame: what scripts wrote, then the
    /// timeline, then authored (moved by user bindings).
    private func layerDraw(_ entry: PreparedLayer, baseSize: SIMD2<Float>,
                           motion: CameraMotion) -> LayerDraw {
        let base = baseValues(entry)
        let script = scripts.object(entry.layer.id)
        var opacity = script?.scalar(.alpha) ?? baseOpacity(entry, base: base)
        if entry.layer.text != nil {
            opacity *= WallpaperServices.shared.userPropertyValue("_owe_text_\(entry.layer.id)_opacity", fallback: 1)
        }
        var local = evaluatedLocal(entry)
        let own = local
        let parallaxOffset = parallaxOffset(entry, local: local, motion: motion)
        let musicSyncLevel = entry.layer.musicSync?.levelSource.map { $0() } ?? motion.audioLevel
        local.scale *= 1 + (entry.layer.musicSync?.zoomAmount ?? 0) * Float(musicSyncLevel)
        local.angle += entry.layer.musicSync.map { $0.tiltAmount * Float(musicSyncLevel) * .pi / 180 } ?? 0
        let quad = SceneQuadGeometry(world: parentWorld(entry) * SceneAffineTransform(local),
                                     size: baseSize, alignment: entry.layer.alignment)
        // WE draws a layer where its transform and the camera put it; an oversized layer (sized
        // to hide its edges while it moves) isn't pinned inside the scene.
        let center = quad.center + parallaxOffset - motion.shake
        let animation = timelines.object(entry.layer.id)
        let rgb = script?.vector3(.color) ?? animation?.color
        let color = rgb.map { SIMD4<Float>($0.x, $0.y, $0.z, base.color.w) } ?? base.color
        let brightness = script?.scalar(.brightness) ?? animation?.brightness ?? base.brightness
        drawProbe?.record(layer: entry.layer.id, .init(opacity: opacity, color: color, brightness: brightness, local: own))
        return LayerDraw(opacity: opacity, color: color, brightness: brightness,
                         quad: SceneQuadGeometry(center: center, axisX: quad.axisX, axisY: quad.axisY),
                         musicSyncLevel: musicSyncLevel)
    }

    /// A layer's opacity before scripts: its timeline's value this frame, else authored or user-bound.
    private func baseOpacity(_ entry: PreparedLayer, base: SceneLayerBaseValues) -> Float {
        timelines.object(entry.layer.id)?.alpha ?? base.opacity
    }

    /// The layer's unscaled size this frame: a script bound to `size` (WE's image property is
    /// writable and drawn every frame, wallpaper64.exe 0x1401e8bb0), else its timeline, else authored.
    private func layerBaseSize(_ entry: PreparedLayer) -> SIMD2<Float> {
        scripts.object(entry.layer.id)?.vector2(.size) ?? timelines.object(entry.layer.id)?.size ?? entry.layer.size
    }

    /// A text layer's current string (a script's, else authored), laid out and rasterised (through
    /// the text cache) at `pixelsPerUnit`, with the block size the layout settled on.
    private func layerTextFrame(_ entry: PreparedLayer, boxSize: SIMD2<Float>,
                                pixelsPerUnit: Float) -> (frame: RenderTextureFrame, baseSize: SIMD2<Float>) {
        guard let authored = entry.layer.text else { return (textureFrame(for: entry), boxSize) }
        let scripted = scripts.text(authored, of: entry.layer.id)
        return makeTextFrame(scripted.text, value: scripted.value, pointSize: scripted.pointSize, boxSize: boxSize,
                             pixelsPerUnit: pixelsPerUnit, layerID: entry.layer.id)
            ?? (textureFrame(for: entry), boxSize)
    }

    // MARK: - Transforms

    private func beginTransformFrame() {
        frameLocals.removeAll(keepingCapacity: true)
        layerIndexByStateId.removeAll(keepingCapacity: true)
        for (index, entry) in layers.enumerated() { layerIndexByStateId[entry.layer.id] = index }
    }

    /// A layer's authored values moved by its user bindings: the base that animations and scripts
    /// start from.
    private func baseValues(_ entry: PreparedLayer) -> SceneLayerBaseValues {
        entry.layer.bindings.isEmpty
            ? SceneLayerBaseValues(entry.layer)
            : entry.layer.bindings.baseValues(for: entry.layer, in: LiveSceneValueContext())
    }

    private func evaluatedLocal(_ entry: PreparedLayer) -> SceneLocalTransform {
        objectLocal(entry.motion, id: entry.layer.id)
    }

    /// An object's own transform this frame (`SceneObjectMotion.local`, scripts' values
    /// included), evaluated once per frame.
    private func objectLocal(_ motion: SceneObjectMotion, id: String) -> SceneLocalTransform {
        if let cached = frameLocals[id] { return cached }
        let local = motion.local(animation: timelines.object(id), script: scripts.object(id))
        frameLocals[id] = local
        return local
    }

    /// This frame's own transform of any object: a drawn layer's, or another object's (groups,
    /// particle systems) from its motion. Nil for an object without either.
    private func liveLocal(_ id: String) -> SceneLocalTransform? {
        if let index = layerIndexByStateId[id] { return evaluatedLocal(layers[index]) }
        return objectMotions[id].map { objectLocal($0, id: id) }
    }

    /// The full transform of a layer's ancestors this frame. Every ancestor uses its live
    /// (scripted, animated) transform, so moving a parent moves its children.
    private func parentWorld(_ entry: PreparedLayer) -> SceneAffineTransform {
        transforms.parentWorld(of: entry.layer.id) { [self] id in liveLocal(id) }
    }

    /// A particle system's emitter transform this frame: its object's, parents included, moved by
    /// camera parallax and shake as WE moves every object's model matrix (0x14018a0b3): the
    /// system's particles follow it unless it is `worldspace`; its children follow it through
    /// their links.
    private func emitterWorld(_ configuration: SceneMetalParticleSystem,
                              motion: CameraMotion) -> SceneAffineTransform? {
        guard let id = configuration.objectID else { return nil }
        var world = transforms.world(of: id) { [self] id in liveLocal(id) }
        world.translation += particleParallaxOffset(id, motion: motion) - motion.shake
        return world
    }

    /// The scene object a particle system belongs to: its own, or its family root's for a child.
    private func particleObjectID(_ system: ParticleSystemRuntime) -> String? {
        var current: ParticleSystemRuntime? = system
        var steps = 0
        while let candidate = current, steps < 64 {
            if let id = candidate.configuration.objectID { return id }
            current = candidate.parent
            steps += 1
        }
        return nil
    }

    /// A step as scripts' playback leaves it: paused emits nothing (its clock stands still),
    /// stopped clears the system; `emitParticles(count)` adds a burst of `count`.
    private static func applyScriptPlayback(_ playback: SceneScriptObjectCommand.Playback?, emitting count: Int?,
                                            to inputs: inout ParticleFrameInputs) {
        switch playback {
        case .pause?:
            for index in inputs.emitters.indices {
                inputs.emitters[index].rate = 0
                inputs.emitters[index].burst = 0
            }
        case .stop?:
            inputs.clears = true
        case .play?, nil:
            break
        }
        if let count, !inputs.emitters.isEmpty { inputs.emitters[0].burst += count }
    }

    /// The parallax offset of a particle object: its root object's live origin and `parallaxDepth`.
    private func particleParallaxOffset(_ id: String, motion: CameraMotion) -> SIMD2<Float> {
        guard let parallax = motion.parallax else { return .zero }
        let rootID = transforms.root(of: id)
        guard let node = transforms.nodes[rootID] else { return .zero }
        let rootLocal = liveLocal(rootID) ?? node.local
        return parallax.state.offset(rootOrigin: rootLocal.origin, rootDepth: parallaxDepth(of: rootID, node: node),
                                     amount: parallax.amount)
    }

    private func worldTransform(_ entry: PreparedLayer) -> SceneAffineTransform {
        parentWorld(entry) * SceneAffineTransform(evaluatedLocal(entry))
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
            values: timelines.values,
            assetTexture: { [unowned self] key, source in self.effectAssetTexture(key: key, source: source) },
            sceneSnapshot: snapshot,
            // The scripted/animated values the layer is drawn with this frame, not the authored ones.
            layerColor: SIMD3(draw.color.x, draw.color.y, draw.color.z),
            layerAlpha: draw.opacity)
        context.mipMappedFrameBuffer = mipMappedTarget
        // WE's layer buffers are frame-buffer class: RGBA16F in HDR.
        context.frameBufferFormat = postProcess.drawsHDR ? .rgba16Float : .rgba8Unorm
        context.assetContentSize = { _, source in source.contentSize }
        context.assetSprite = { [unowned self] key, source in self.effectAssetSprite(key: key, source: source) }
        if let probe = drawProbe { context.recordAnimated = { probe.record(constant: $0, value: $1) } }
        // Hidden effects (authored, user-bound or a script's `visible`) are built but skipped;
        // constants scripts set go over the material's.
        let scripted = scripts.effects(entry.layer.weEffects, of: entry.layer.id)
        context.hiddenEffects = scripted.hidden
        context.constantWrites = scripted.writes
        context.scriptRevision = scripted.revision
        if renderSettings.sceneDetail == .matchDisplay {
            context.footprint = effectFootprint(entry, draw: draw, input: input)
            // Scene regions are drawn at the scene target's density, below full detail when the
            // target is matched to a smaller display; solid fills and text with effects are at
            // WE's own buffer size.
            if context.footprint == nil, fullDetailScale > 1, entry.layer.solidFill == nil, entry.layer.text == nil {
                let standIn = (SIMD2(Float(input.width), Float(input.height)) * fullDetailScale).rounded(.toNearestOrAwayFromZero)
                context.inputStandInSize = SIMD2(Int(standIn.x), Int(standIn.y))
            }
        }
        let lit = prelit(entry, draw: draw, input: input, snapshot: snapshot, frame: frame, commandBuffer: commandBuffer)
        if lit != nil {
            // The prelit image is redrawn into the same texture every frame (its lights, the
            // reflection it samples): a new version, so no kept chain output outlives it.
            prelitVersion &+= 1
            context.inputVersion = prelitVersion
        }
        return effectGraph.apply(entry.layer.weEffects, to: lit ?? input,
                                 layerID: entry.layer.id, context: context, commandBuffer: commandBuffer)
    }

    /// The on-screen size, in scene-target pixels, of the whole image a layer's effects run on
    /// (`SceneEffectDetail`): its quad at the target's density, over the part of the image the quad
    /// shows (a padded `.tex` or a sprite frame shows part of it). Nil where the effects already run
    /// at the display's density or their input isn't the layer's image: scene-input layers (the
    /// scene under them, resampled at the target's density), text (rasterised at it), videos and
    /// perspective layers.
    private func effectFootprint(_ entry: PreparedLayer, draw: LayerDraw, input: MTLTexture) -> SIMD2<Float>? {
        let layer = entry.layer
        guard !layer.sceneInput, layer.text == nil, !layer.perspective, let frame = entry.frames.first,
              frame.texture.width == input.width, frame.texture.height == input.height else { return nil }
        if case .video = layer.source { return nil }
        let shown = SIMD2(simd_length(frame.uvAxisX), simd_length(frame.uvAxisY))
        guard shown.x > 0, shown.y > 0 else { return nil }
        return draw.quad.extent * renderPixelsPerUnit / shown
    }

    /// A lit or reflective layer's image as its effects start from it: lit by its material's
    /// prelighting pass (`ImageMaterialRenderer.prelight`); nil for any other layer.
    private func prelit(_ entry: PreparedLayer, draw: LayerDraw, input: MTLTexture, snapshot: MTLTexture?,
                        frame: BuiltinFrameContext, commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        guard let plan = entry.layer.imageMaterial, plan.prelighting != nil, let imageMaterials else { return nil }
        let lit = imageMaterials.prelight(plan, ImageMaterialRenderer.Draw(
            layerID: entry.layer.id, quad: draw.quad, sceneSize: sceneSize, color: SIMD3(repeating: 1), alpha: 1,
            brightness: 1, texture: input, contentSize: entry.layer.source.contentSize, uvOrigin: .zero,
            uvAxisX: SIMD2(1, 0), uvAxisY: SIMD2(0, 1), sceneSnapshot: snapshot, mipMappedFrameBuffer: mipMappedTarget,
            frame: frame, values: timelines.values,
            assetTexture: { [unowned self] key, source in self.effectAssetTexture(key: key, source: source) },
            assetSprite: { [unowned self] key, source in self.effectAssetSprite(key: key, source: source) }),
            // The layer's effect buffers' format: RGBA16F in HDR (docs/lighting-plan.md §2.3, §2.6).
            format: postProcess.drawsHDR ? .rgba16Float : .rgba8Unorm, commandBuffer: commandBuffer)
        prelitImages[entry.layer.id] = lit
        return lit
    }

    /// Continues the scene pass after a pause (a snapshot of it, or effects run in between).
    private func resumeScenePass(on scene: MTLTexture, commandBuffer: MTLCommandBuffer) -> MTLRenderCommandEncoder? {
        let resume = MTLRenderPassDescriptor()
        resume.colorAttachments[0].texture = scene
        resume.colorAttachments[0].loadAction = .load
        resume.colorAttachments[0].storeAction = .store
        let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: resume)
        encoder?.setRenderPipelineState(renderPipeline)
        return encoder
    }

    /// The scene drawn so far (`_rt_FullFrameBuffer`), current within `rect` (all of it when nil).
    /// Every scene-reading draw of a frame shares one full-size target, and only what changed is
    /// copied (`SceneSnapshotTracker`): the GPU runs the command buffer in order, so each draw
    /// reads its snapshot before the next copy overwrites any of it.
    private func sceneSnapshot(of scene: MTLTexture, commandBuffer: MTLCommandBuffer,
                               needing rect: SceneSnapshotTracker.Rect? = nil) -> MTLTexture? {
        if sceneCopy == nil {
            // The reflection copy's level 0 when this frame allows (`snapshotCanShare`): one
            // full-size target fewer.
            let shared = snapshotSharesMipMappedTarget ? mipMappedTarget.flatMap {
                $0.width == scene.width && $0.height == scene.height && $0.pixelFormat == scene.pixelFormat ? $0 : nil
            } : nil
            sceneCopy = shared ?? renderTargetPool.texture(width: scene.width, height: scene.height,
                                                           pixelFormat: scene.pixelFormat, avoiding: scene)
            snapshotTracker.reset()
        }
        guard let copy = sceneCopy else { return nil }
        let whole = SceneSnapshotTracker.Rect(x: 0, y: 0, width: scene.width, height: scene.height)
        guard let region = snapshotTracker.copy(for: rect ?? whole) else { return copy }
        guard let blit = commandBuffer.makeBlitCommandEncoder() else {
            snapshotTracker.reset()
            return nil
        }
        let origin = MTLOrigin(x: region.x, y: region.y, z: 0)
        blit.copy(from: scene, sourceSlice: 0, sourceLevel: 0, sourceOrigin: origin,
                  sourceSize: MTLSize(width: region.width, height: region.height, depth: 1),
                  to: copy, destinationSlice: 0, destinationLevel: 0, destinationOrigin: origin)
        blit.endEncoding()
        return copy
    }

    /// The scene under a scene-input layer, as that layer's base image (`SceneRegionResample`).
    /// A quad that is exactly the scene (composition and fullscreen layers) uses the snapshot as is.
    /// Under WE's texture reduction a composition layer's buffers are its size over the reduction;
    /// a fullscreen layer's aren't (`TextureReduction`).
    private func sceneRegion(of snapshot: MTLTexture, under quad: SceneQuadGeometry, reducedFor layer: SceneMetalLayer,
                             commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        let reduction = layer.fillsScene ? 1 : Float(renderSettings.textureReduction)
        if reduction == 1, SceneRegionResample.coversWholeScene(quad, sceneSize: sceneSize) { return snapshot }
        guard let size = SceneRegionResample.targetSize(quad, layerSize: layer.size, pixelsPerUnit: renderPixelsPerUnit / reduction),
              let region = renderTargetPool.texture(width: size.x, height: size.y,
                                                    pixelFormat: snapshot.pixelFormat, avoiding: snapshot) else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = region
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        var uniform = SceneRegionResample.uniform(quad, sceneSize: sceneSize, targetSize: size)
        encoder.setRenderPipelineState(layerPipelines.pipelines(for: region.pixelFormat).copy)
        encoder.setVertexBytes(&uniform, length: MemoryLayout<LayerUniform>.stride, index: 0)
        encoder.setFragmentBytes(&uniform, length: MemoryLayout<LayerUniform>.stride, index: 0)
        encoder.setFragmentTexture(snapshot, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        return region
    }

    /// A textureless layer's image as its effects start from it: its fill at WE's buffer size, the
    /// layer's `size` rounded (`SceneMetalLayer.solidFill`), filled once per content; nil for a
    /// layer with a texture (or when the target can't be made, and the 1×1 source stands in).
    private func solidEffectInput(_ layer: SceneMetalLayer, commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        guard let fill = layer.solidFill else { return nil }
        let size = SolidEffectInput.size(layer.size)
        if let cached = solidEffectInputs[layer.id], cached.width == size.x, cached.height == size.y { return cached }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: size.x,
                                                                  height: size.y, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            OWELog.error(.scene, "Layer \(layer.id): could not allocate its \(size.x)×\(size.y) effect input")
            return nil
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(fill.x), green: Double(fill.y),
                                                            blue: Double(fill.z), alpha: Double(fill.w))
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encoder.endEncoding()
        solidEffectInputs[layer.id] = texture
        return texture
    }

    private func effectAssetTexture(key: String, source: SceneMetalTextureSource) -> MTLTexture? {
        if case .animated = source { return animatedAssetFrame(key: key, source: source)?.texture }
        if let cached = effectAssetTextures[key] { return cached }
        guard let texture = makeTextureFrames(from: source)?.first?.texture else { return nil }
        effectAssetTextures[key] = texture
        return texture
    }

    /// An animated asset texture's sprite frame this frame, for `g_TextureNRotation/Translation`;
    /// nil for a still one.
    private func effectAssetSprite(key: String, source: SceneMetalTextureSource) -> BuiltinSpriteFrame? {
        guard case .animated = source, let frame = animatedAssetFrame(key: key, source: source) else { return nil }
        return BuiltinSpriteFrame(rotation: SIMD4(frame.uvAxisX.x, frame.uvAxisX.y, frame.uvAxisY.x, frame.uvAxisY.y),
                                  translation: frame.uvOrigin)
    }

    /// The frame an effect or material shows of an animated asset texture (T7): the texture's
    /// shared clock (§2.7), which every binding of the frame and every image layer of the texture
    /// share. The key is `materialPath|name`; the clock is the texture name's.
    private func animatedAssetFrame(key: String, source: SceneMetalTextureSource) -> RenderTextureFrame? {
        let frames: [RenderTextureFrame]
        if let cached = effectAssetFrames[key] {
            frames = cached
        } else {
            guard let made = makeTextureFrames(from: source), !made.isEmpty else { return nil }
            effectAssetFrames[key] = made
            frames = made
        }
        guard frames.count > 1 else { return frames[0] }
        let texture = key.split(separator: "|", omittingEmptySubsequences: false).last.map(String.init) ?? key
        let frame = timelines.materialTextureFrame(texture: texture, frameTimes: { frames.map(\.duration) },
                                                   delta: Float(clock.delta))
        // `setFrame(n)` can't reach a material's clock; a frame outside the sheet can't happen, but draws the first.
        return frame >= 0 && Int(frame) < frames.count ? frames[Int(frame)] : frames[0]
    }







    /// The scene target, at `renderPixelsPerUnit` pixels per scene unit.
    private func sceneRenderTarget(pixelFormat: MTLPixelFormat) -> MTLTexture? {
        let pixelSize = SceneRenderResolution.targetSize(sceneSize: sceneSize, pixelsPerUnit: renderPixelsPerUnit)
        if let sceneRenderTarget, sceneRenderTargetSize == pixelSize, sceneRenderTarget.pixelFormat == pixelFormat {
            return sceneRenderTarget
        }

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

    /// The user's colour for a text layer (`_owe_text_<id>_color`), white when unset.
    private func textTint(layerID: String) -> SIMD3<Float> {
        guard let value = WallpaperServices.shared.userPropertyString("_owe_text_\(layerID)_color") else {
            return SIMD3(repeating: 1)
        }
        let rgb = value.parseVector3()
        return SIMD3(Float(rgb.0), Float(rgb.1), Float(rgb.2))
    }

    /// `layerID` keys the user's text settings and the text cache. `pointSize` is a script's
    /// `pointsize`, which wins over the app's size setting.
    private func makeTextFrame(_ text: SceneMetalText, value: String, pointSize: Float?, boxSize: SIMD2<Float>,
                               pixelsPerUnit: Float, layerID: String) -> (frame: RenderTextureFrame, baseSize: SIMD2<Float>)? {
        let stateKey = layerID
        let fontName = WallpaperServices.shared.userPropertyString("_owe_text_\(layerID)_font") ?? ""
        let sizeValue = pointSize
            ?? WallpaperServices.shared.userPropertyValue("_owe_text_\(layerID)_size", fallback: Float(text.pointSize))
        let bold = WallpaperServices.shared.userPropertyString("_owe_text_\(layerID)_bold") == "true"
        let italic = WallpaperServices.shared.userPropertyString("_owe_text_\(layerID)_italic") == "true"
        let rasterScale = SceneTextRasterScale.retained(SceneTextRasterScale.quantized(pixelsPerUnit),
                                                        previous: textRasterScales[stateKey])
        textRasterScales[stateKey] = rasterScale
        let cacheKey = "\(stateKey)|\(value)|\(boxSize.x)|\(boxSize.y)|\(fontName)|\(sizeValue)|\(bold)|\(italic)|\(rasterScale)"
            + "|\(text.horizontalAlignment ?? "")|\(text.verticalAlignment ?? "")"
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
        // A white coverage mask, as WE's `font` shader samples its glyphs: colour (authored and
        // the user's), alpha and brightness are applied when the quad is drawn.
        let color = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let pixels = SceneTextRasterScale.clamped(rasterScale, boxSize: layout.boxSize)
        guard let image = layout.rasterize(font: font, color: color, pixelsPerUnit: CGFloat(pixels)),
              let texture = try? SceneTextureUpload.texture(from: image, loader: textureLoader, device: device) else {
            OWELog.error(.scene, "Text layer \(layerID): could not rasterise \(layout.boxSize) at \(pixels) px/unit")
            return nil
        }
        let coverage: MTLTexture?
        do {
            coverage = try SceneTextureUpload.coverageTexture(from: image, device: device)
        } catch {
            OWELog.error(.scene, "Text layer \(layerID): no coverage texture, drawn natively: \(error)")
            coverage = nil
        }
        let entry = (RenderTextureFrame(texture: texture, duration: .greatestFiniteMagnitude,
                                        uvOrigin: .zero, uvAxisX: SIMD2(1, 0), uvAxisY: SIMD2(0, 1), coverage: coverage),
                     layout.boxSize)
        // Strings change every second for clocks; the LRU keeps the live ones and drops the rest.
        textFrameCache.insert(entry, for: cacheKey)
        return entry
    }

    /// Maps a scene-unit position and size onto `drawableSize` pixels. Scene draws use
    /// `.stretch` (the target has the scene's aspect); the composite uses the user's placement, at
    /// `pixelsPerPoint` (the frame's display by default).
    private func layerUniform(position: SIMD2<Float>, size: SIMD2<Float>, opacity: Float,
                              drawableSize: SIMD2<Float>, placement: WallpaperPlacement,
                              pixelsPerPoint: Float? = nil) -> LayerUniform {
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
                                              pixelsPerPoint: pixelsPerPoint ?? drawablePixelsPerPoint)
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

    /// The cursor in scene units, mapped through the placement of the display it is on, or nil
    /// while it is on none of this scene's displays.
    private func sceneCursor(_ viewports: [SceneViewport]) -> SIMD2<Float>? {
        for viewport in viewports {
            guard let drawablePoint = viewport.cursorPixels else { continue }
            return ScenePlacementScale.scenePoint(drawablePoint: drawablePoint, placement: placement, sceneSize: sceneSize,
                                                  drawableSize: viewport.drawableSize, pixelsPerPoint: viewport.pixelsPerPoint)
        }
        return nil
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

    /// The layer's texture this frame: a video's current picture, or the sprite frame of an
    /// animated texture from the instance's texture clocks (docs/timeline-plan.md §2.7, §3.2),
    /// taken once per frame (a script's override advances each time it is asked).
    private func textureFrame(for entry: PreparedLayer) -> RenderTextureFrame {
        // A video layer's texture is replaced every frame, so the decoded frame list is only a seed.
        if case let .video(stream) = entry.layer.source, let texture = stream.currentTexture() {
            return RenderTextureFrame(texture: texture, duration: .greatestFiniteMagnitude,
                                      uvOrigin: .zero, uvAxisX: SIMD2<Float>(1, 0), uvAxisY: SIMD2<Float>(0, 1))
        }
        guard entry.frames.count > 1, let id = Int(entry.layer.id) else { return entry.frames[0] }
        let frame = timelines.spriteFrame(object: id, delta: Float(clock.delta))
        drawProbe?.record(spriteFrame: frame, object: id)
        // `setFrame(n)` isn't range-checked; a frame outside the sheet draws the first.
        return frame >= 0 && Int(frame) < entry.frames.count ? entry.frames[Int(frame)] : entry.frames[0]
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
        // `ComputeParticleTrailTangents` (common_particles.h): the size times the speed's stretch,
        // clamped to `minlength`…`maxlength`.
        let limits = system.configuration.trailLengthLimits
        let stretch = max(limits.y, min(speed * system.configuration.trailLength, limits.x))
        let size = particle.size * system.drawSizeScale
        let length = size * stretch
        let width = system.configuration.refractive ? max(2, size * 0.08) : size
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
            // A rope ribbon is twice the particle's size wide.
            let size = 2 * particle.size * system.drawSizeScale
            let width = configuration.fadeTrailSize ? size * progress : size
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

    /// One rope through the system's particles; one per instance of an instanced system.
    private func appendRope(_ system: ParticleSystemRuntime, drawableSize: SIMD2<Float>) {
        for strand in ParticleRopeStrands.strands(system.particles) {
            appendRope(strand, system: system, drawableSize: drawableSize)
        }
    }

    private func appendRope(_ particles: [Particle], system: ParticleSystemRuntime, drawableSize: SIMD2<Float>) {
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
            // A rope ribbon is twice the particle's size wide.
            let averageSize = (start.size + end.size) * system.drawSizeScale
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

    /// The particle's alpha (`alphafade` is one of its operators) with the material's multiplier.
    private func particleOpacity(_ particle: Particle, in system: ParticleSystemRuntime) -> Float {
        particle.alpha * system.configuration.opacityMultiplier
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
