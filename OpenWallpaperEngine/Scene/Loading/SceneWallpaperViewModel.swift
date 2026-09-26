//
//  SceneWallpaperViewModel.swift
//  Open Wallpaper Engine
//
//  Loads Wallpaper Engine scene wallpapers and builds the content the Metal renderer draws.
//  Follows the same ViewModel pattern as VideoWallpaperViewModel.
//

import SwiftUI
import CoreText
import CryptoKit

class SceneWallpaperViewModel: ObservableObject {
    static func log(_ msg: String) {
        OWELog.info(.scene, msg)
    }

    /// High-volume per-asset/per-texture diagnostics; only surfaces at verbose log level.
    static func logDetail(_ msg: String) {
        OWELog.debug(.scene, msg)
    }

    @Published var currentWallpaper: WEWallpaper {
        willSet {
            loadScene(from: newValue)
        }
    }

    private(set) var metalRevision = 0

    /// Every content invalidation must both bump the revision and tell SwiftUI, or `updateNSView`
    /// never runs and the renderer keeps drawing the previous wallpaper until some unrelated
    /// re-render happens to come along.
    private func bumpRevision() {
        metalRevision &+= 1
        if Thread.isMainThread {
            objectWillChange.send()
        } else {
            DispatchQueue.main.async { [weak self] in self?.objectWillChange.send() }
        }
    }

    /// Guards the parsed scene and its asset caches. `metalContent()` runs on a background queue,
    /// so it must not race a `loadScene` triggered from the main thread.
    private let sceneLock = NSRecursiveLock()
    private let contentQueue = DispatchQueue(label: "com.winddog.wallpaper-engine.scene-content", qos: .userInitiated)
    private var cachedContent: SceneMetalContent?
    private var cachedContentRevision = -1
    /// The user's quality settings the content is built for (`setRenderSettings`).
    private var renderSettings = SceneRenderSettings()
    /// The engine combos of the content being built, for every material plan built with it.
    private var sceneEngineCombos = SceneEngineCombos()
    /// The factor the particle budget put on the scene's systems (`ParticleBudget`); systems
    /// scripts create later are thinned by it too.
    private var particleBudgetScale: Float = 1
    /// The budget scaling last logged, so a rebuild of the same scene doesn't log it again.
    private var loggedParticleBudget: (directory: URL, report: ParticleBudget.Report)?
    /// Retained for video wallpapers rendered through the scene pipeline.
    private var videoStream: VideoTextureStream?
    private var builtVideoFrameSize: SIMD2<Float>?

    /// Builds the render content off the main thread and delivers it on the main queue.
    func contentAsync(completion: @escaping (SceneMetalContent?) -> Void) {
        contentQueue.async { [weak self] in
            let content = self?.metalContent()
            DispatchQueue.main.async { completion(content) }
        }
    }

    private var pkgParser: PKGParser?
    private var loadedScene: WEScene?
    /// The loaded scene.json and its parse signature (`ParsedScene`), which the scripts run from.
    private var loadedDocument: (document: SceneJSON, signature: String)?
    /// The loaded wallpaper's project.json, which declares its user properties.
    private var loadedProject: SceneJSON?
    /// User properties the built content reads (layer visibility, bound values outside scripts):
    /// changing any other only reaches the scripts (`applyUserProperties`), without a rebuild.
    private(set) var contentUserProperties = Set<String>()
    /// The loaded scene has SceneScripts.
    private var hasScriptSites = false
    private var loadedWallpaperDirectory: URL?
    private var assetDataCache: [String: Data] = [:]
    /// Where the loaded wallpaper's settings are stored, and the directory it was resolved for.
    private var settings: (directory: URL, identity: WallpaperSettingsIdentity)?
    /// Other Workshop items' assets (`…/workshop/<id>/…`), loose or inside the item's `.pkg`.
    private var workshopAssets = WorkshopAssetResolver(roots: WorkshopAssetResolver.defaultRoots())
    /// WE's fixed copies of broken Workshop shaders (`assets/zcompat`).
    private var shaderCompat: SceneShaderCompat?
    /// The loaded wallpaper's Workshop id, which bounds the zcompat fixes.
    private var loadedProjectId: String?

    /// Decoded textures are identical for every screen showing the same wallpaper, so they live in
    /// one process-wide cache. NSCache lets the system reclaim them under pressure rather than
    /// holding a full decoded copy per display.
    private final class TextureBox {
        let source: SceneMetalTextureSource
        init(_ source: SceneMetalTextureSource) { self.source = source }
    }

    private static let sharedTextureCache: NSCache<NSString, TextureBox> = {
        let cache = NSCache<NSString, TextureBox>()
        cache.countLimit = 512
        return cache
    }()

    /// Every screen showing the same wallpaper parses the identical PKG index and scene.json.
    /// PKGParser is immutable after init and WEScene is a value type, so both are safe to share.
    private struct ParsedScene {
        let parser: PKGParser?
        let scene: WEScene
        let signature: String
        /// scene.json as `scene` was decoded from (the user's object edits applied), for scripts.
        let document: SceneJSON?
    }

    private static let parseCacheLock = NSLock()
    nonisolated(unsafe) private static var parseCache: [String: ParsedScene] = [:]

    /// Size + mtime of the backing file, so an updated wallpaper re-parses instead of going stale.
    private static func sourceSignature(for url: URL) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        return "\(size)|\(modified)"
    }

    /// `decodeScene` bakes per-object origin and JSON edits into the parsed scene, so those edits
    /// have to take part in the cache key or a reload serves the pre-edit scene and the object
    /// snaps back to its authored position.
    private static func overrideSignature(settingsKey: String) -> String {
        let values = UserDefaults.standard.dictionary(forKey: settingsKey) as? [String: String] ?? [:]
        let edits = values.filter { $0.key.hasPrefix("_owe_scene_object_") }
        guard !edits.isEmpty else { return "-" }
        return String(edits.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            .joined(separator: ";").hashValue)
    }

    private static func cachedParse(for directory: URL, signature: String) -> ParsedScene? {
        parseCacheLock.lock()
        defer { parseCacheLock.unlock() }
        guard let entry = parseCache[directory.path], entry.signature == signature else { return nil }
        return entry
    }

    private static func storeParse(_ entry: ParsedScene, for directory: URL) {
        parseCacheLock.lock()
        defer { parseCacheLock.unlock() }
        // Deliberately tiny: every display showing one wallpaper shares a single entry, so this
        // only needs the current wallpaper plus one for switching back. A larger cap would pin
        // mapped PKG data across playlist rotation for no benefit.
        if parseCache.count >= 2, parseCache[directory.path] == nil {
            parseCache.removeAll(keepingCapacity: true)
        }
        parseCache[directory.path] = entry
    }

    private func textureCacheKey(_ key: String) -> NSString {
        "\(loadedWallpaperDirectory?.path ?? currentWallpaper.wallpaperDirectory.path)|\(key)" as NSString
    }

    private func cachedTexture(_ key: String) -> SceneMetalTextureSource? {
        Self.sharedTextureCache.object(forKey: textureCacheKey(key))?.source
    }

    private func cacheTexture(_ source: SceneMetalTextureSource, for key: String) -> SceneMetalTextureSource {
        Self.sharedTextureCache.setObject(TextureBox(source), forKey: textureCacheKey(key))
        return source
    }
    private var registeredFontNames: [String: String] = [:]

    init(wallpaper: WEWallpaper) {
        self.currentWallpaper = wallpaper
        Self.log("init: wallpaper=\(wallpaper.project.title) dir=\(wallpaper.wallpaperDirectory.path)")
        loadScene(from: wallpaper)
    }

    deinit {
        // The built layer hands a strong reference to the renderer, so releasing this view model
        // is not enough on its own to silence the soundtrack.
        videoStream?.stop()
    }

    /// Both local and remote videos render through the one-layer video scene.
    static func isVideoType(_ type: String) -> Bool {
        let value = type.lowercased()
        return value == "video" || value == "remote-video"
    }

    func reloadSharedAssets() {
        sceneLock.lock()
        defer { sceneLock.unlock() }
        assetDataCache.removeAll(keepingCapacity: true)
        Self.sharedTextureCache.removeAllObjects()
        registeredFontNames.removeAll(keepingCapacity: true)
        bumpRevision()
    }

    func reloadCurrentScene() {
        loadScene(from: currentWallpaper, prepareDefaults: false)
    }

    /// Drops the memoised scene content so the next build re-reads user properties that are
    /// consumed at build time, such as an authored effect's enabled flag.
    func invalidateContent() {
        sceneLock.lock()
        defer { sceneLock.unlock() }
        bumpRevision()
    }

    /// The user's quality settings; a change rebuilds the content, whose engine combos follow them.
    func setRenderSettings(_ settings: SceneRenderSettings) {
        sceneLock.lock()
        defer { sceneLock.unlock() }
        guard settings != renderSettings else { return }
        renderSettings = settings
        bumpRevision()
    }

    // MARK: - Scene Loading

    func loadScene(from wallpaper: WEWallpaper, prepareDefaults: Bool = true) {
        sceneLock.lock()
        defer { sceneLock.unlock() }
        let signpost = OWESignpost.begin(OWESignpost.scene, "loadScene")
        defer { signpost.end() }
        OWEFrameMetrics.countSceneReload()

        // Re-parsing the same wallpaper (a settings change) must keep decoded textures and fonts;
        // only a different wallpaper invalidates them. Textures are shared process-wide and keyed
        // per wallpaper, so they survive switches and are reclaimed by NSCache under pressure.
        if loadedWallpaperDirectory != wallpaper.wallpaperDirectory {
            assetDataCache.removeAll(keepingCapacity: true)
            registeredFontNames.removeAll(keepingCapacity: true)
            // Otherwise a stale stream either keeps playing the previous video's audio after
            // switching to a non-video wallpaper, or gets reused verbatim for a different video.
            videoStream?.stop()
            videoStream = nil
            builtVideoFrameSize = nil
            workshopAssets = WorkshopAssetResolver(roots: WorkshopAssetResolver.defaultRoots())
            shaderCompat = SceneShaderCompat(assetsDirectory: WallpaperEngineAssets.directory)
                ?? SceneShaderCompat(assetsDirectory: WallpaperEngineAssets.bundled)
            loadedProjectId = Self.workshopId(of: wallpaper)
        }
        // Symlink in any already-installed cross-workshop-item asset dependencies before parsing,
        // so paths like "effects/workshop/<id>/name/effect.json" resolve as ordinary loose files.
        WorkshopDependencyResolver.linkInstalledDependencies(for: wallpaper)
        let dir = wallpaper.wallpaperDirectory
        let sceneFile = wallpaper.project.file  // e.g. "scene.json" or "gifscene.json"
        let settingsKey = settingsIdentity(for: dir).key(.userProperties)

        // Derive PKG name from scene file: "scene.json" → "scene.pkg", "gifscene.json" → "gifscene.pkg"
        let pkgName = (sceneFile as NSString).deletingPathExtension + ".pkg"
        let pkgURL = dir.appending(path: pkgName)
        let looseSceneURL = dir.appending(path: sceneFile)

        var scene: WEScene?
        var document: SceneJSON?
        var servedFromCache = false

        let hasPackage = FileManager.default.fileExists(atPath: pkgURL.path(percentEncoded: false))
        let sourceURL = hasPackage ? pkgURL : looseSceneURL
        let signature = Self.sourceSignature(for: sourceURL)
            + "|" + Self.overrideSignature(settingsKey: settingsKey)

        if let cached = Self.cachedParse(for: dir, signature: signature) {
            self.pkgParser = cached.parser
            scene = cached.scene
            document = cached.document
            servedFromCache = true
        } else if hasPackage {
            do {
                let parser = try PKGParser(url: pkgURL)
                self.pkgParser = parser
                if let data = parser.extractFile(named: sceneFile) {
                    (scene, document) = try decodeScene(data, settingsKey: settingsKey)
                }
            } catch {
                Self.log("Failed to parse PKG: \(error)")
            }
        } else if FileManager.default.fileExists(atPath: looseSceneURL.path(percentEncoded: false)) {
            // Loose files (no .pkg)
            self.pkgParser = nil
            do {
                let data = try Data(contentsOf: looseSceneURL)
                (scene, document) = try decodeScene(data, settingsKey: settingsKey)
            } catch {
                Self.log("Failed to parse loose \(sceneFile): \(error)")
            }
        }

        guard let scene = scene else {
            // A video or web wallpaper legitimately has no scene; only a scene wallpaper missing
            // one is a real failure, and treating both as errors buries the genuine case.
            let type = wallpaper.project.type.lowercased()
            if type.isEmpty || type == "scene" {
                OWELog.error(.scene, "No scene data found")
            } else {
                Self.logDetail("No scene data for \(type) wallpaper; handled by its own renderer")
                // Otherwise metalContent()'s memoization still sees the old revision and keeps
                // serving the previous wallpaper's content until something else bumps it.
                loadedWallpaperDirectory = dir
                bumpRevision()
            }
            return
        }
        Self.storeParse(ParsedScene(parser: pkgParser, scene: scene, signature: signature, document: document), for: dir)

        if prepareDefaults {
            prepareSceneUserPropertyDefaults(for: wallpaper, scene: scene)
        }
        Self.log("Scene loaded: \(scene.objects.count) objects from \(sceneFile) [\(servedFromCache ? "shared parse" : "parsed")]")
        if !hasPackage {
            WallpaperPackageConverter.markVerified(wallpaperDirectory: dir, objectCount: scene.objects.count)
        }
        loadedScene = scene
        loadedDocument = document.map { ($0, "\(dir.path)|\(signature)") }
        loadedProject = Self.project(in: dir)
        contentUserProperties = document.map(Self.contentUserProperties(in:)) ?? []
        hasScriptSites = document.map { !SceneScriptSiteBuilder(wallpaperID: "").sites(in: $0).isEmpty } ?? false
        loadedWallpaperDirectory = dir
        bumpRevision()
    }

    /// The scene and the document it was decoded from (for the scripts; nil when it isn't JSON the
    /// tolerant reader takes).
    private func decodeScene(_ data: Data, settingsKey: String) throws -> (WEScene, SceneJSON?) {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var objects = root["objects"] as? [[String: Any]] else {
            return (try JSONDecoder().decode(WEScene.self, from: data), Self.document(data))
        }
            let values = UserDefaults.standard.dictionary(forKey: settingsKey) as? [String: String] ?? [:]
        for index in objects.indices {
            let objectID = (objects[index]["id"] as? NSNumber)?.intValue ?? index
            guard let override = values["_owe_scene_object_\(objectID)_json"],
                  let overrideData = override.data(using: .utf8),
                  let replacement = try? JSONSerialization.jsonObject(with: overrideData) as? [String: Any] else { continue }
            objects[index] = replacement
        }
        for index in objects.indices {
            let objectID = (objects[index]["id"] as? NSNumber)?.intValue ?? index
            if let origin = values["_owe_scene_object_\(objectID)_origin"] {
                objects[index]["origin"] = origin
            }
            if let scale = values["_owe_scene_object_\(objectID)_scale"] {
                objects[index]["scale"] = scale
            }
        }
        root["objects"] = objects
        let resolvedData = try JSONSerialization.data(withJSONObject: root)
        return (try JSONDecoder().decode(WEScene.self, from: resolvedData), Self.document(resolvedData))
    }

    private static func document(_ data: Data) -> SceneJSON? {
        do {
            return try SceneScriptSiteBuilder.document(from: data)
        } catch {
            OWELog.error(.script, "scene.json can't be read for its scripts: \(error)")
            return nil
        }
    }

    /// project.json as JSON; nil (logged) when it can't be read.
    private static func project(in directory: URL) -> SceneJSON? {
        let url = directory.appending(path: "project.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try decodeTolerant(SceneJSON.self, from: Data(contentsOf: url))
        } catch {
            OWELog.error(.scene, "Can't read \(url.path): \(error)")
            return nil
        }
    }

    /// The user properties the content is built from: every `"user"` binding of the document
    /// except inside script sites (their scripts get the change through `applyUserProperties` and
    /// the binding, docs/scenescript-plan.md WP8) and `scriptproperties`.
    static func contentUserProperties(in document: SceneJSON) -> Set<String> {
        var names = Set<String>()
        func walk(_ value: SceneJSON) {
            switch value {
            case .object(let fields):
                if case .string(let script)? = fields["script"], !script.isEmpty { return }
                if let user = SceneScriptUserReference(fields["user"]) { names.insert(user.name) }
                for (key, field) in fields where key != "scriptproperties" { walk(field) }
            case .array(let values):
                values.forEach(walk)
            default:
                break
            }
        }
        walk(document)
        return names
    }

    /// How much of the scene a user property change invalidates. A declared property no built
    /// content reads (only scripts do) changes nothing here: the renderer hands it to the scripts.
    func impact(of keys: [String]) -> SceneChangeImpact {
        keys.reduce(.none) { impact, key in
            let own = SceneChangeImpact.impact(of: key)
            guard own == .rebuildContent, !key.hasPrefix("_owe_") else { return max(impact, own) }
            return max(impact, contentUserProperties.contains(key) ? .rebuildContent : .none)
        }
    }

    /// The settings identity of the wallpaper in `directory`, resolved (and old path keys moved)
    /// once per load.
    private func settingsIdentity(for directory: URL) -> WallpaperSettingsIdentity {
        if let settings, settings.directory == directory { return settings.identity }
        let identity = WallpaperSettingsIdentity.resolve(directory: directory)
        settings = (directory, identity)
        return identity
    }

    private func prepareSceneUserPropertyDefaults(for wallpaper: WEWallpaper, scene: WEScene) {
        guard wallpaper.project.type.caseInsensitiveCompare("scene") == .orderedSame else { return }
        let identity = settingsIdentity(for: wallpaper.wallpaperDirectory)
        let key = identity.key(.userProperties)
        let explicitKey = identity.key(.explicitUserProperties)
        let defaults = UserDefaults.standard
        let stored = defaults.bool(forKey: explicitKey)
            ? defaults.dictionary(forKey: key) as? [String: String] ?? [:]
            : [:]
        let values = Self.userPropertyValues(stored: stored,
                                             declared: Self.declaredUserProperties(in: wallpaper.wallpaperDirectory),
                                             scene: scene)
        defaults.set(values, forKey: key)
        WallpaperServices.shared.setUserProperties(values, wallpaper: wallpaper.wallpaperDirectory.path,
                                                           replacing: true)
    }

    /// The wallpaper's property values: what the user stored, else project.json's defaults (the
    /// first option for a combo without one). Nothing else is invented: WE shows exactly what the
    /// properties say, even when that selects no variant of a conditional layer.
    static func userPropertyValues(stored: [String: String], declared: [String: [String: Any]],
                                   scene: WEScene) -> [String: String] {
        var values = stored
        for (name, property) in declared where values[name] == nil {
            if let value = property["value"] {
                values[name] = sceneUserPropertyString(value)
            } else if property["type"] as? String == "combo",
                      let option = (property["options"] as? [[String: Any]])?.first?["value"] {
                values[name] = sceneUserPropertyString(option)
            }
        }
        for object in SceneObjectIdentity.assigningFallbackIDs(scene.objects) where object.textValue != nil {
            let prefix = "_owe_text_\(object.id ?? -1)_"
            if values[prefix + "font"] == nil, let font = object.font {
                values[prefix + "font"] = font
            }
            // A user-bound point size follows its property; a seeded override would pin it.
            if values[prefix + "size"] == nil, object.values[.pointsize]?.userPropertyName == nil,
               let pointSize = object.pointsize {
                values[prefix + "size"] = String(pointSize)
            }
        }
        return values
    }

    /// `general.properties` of project.json; empty when the wallpaper declares none.
    private static func declaredUserProperties(in directory: URL) -> [String: [String: Any]] {
        let url = directory.appending(path: "project.json")
        do {
            let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            let general = root?["general"] as? [String: Any]
            return general?["properties"] as? [String: [String: Any]] ?? [:]
        } catch {
            OWELog.error(.scene, "Can't read user properties from \(url.path): \(error)")
            return [:]
        }
    }

    private func loadPreviewImage(wallpaperDir: URL) -> NSImage? {
        for name in ["preview.jpg", "preview.png", "preview.gif"] {
            let url = wallpaperDir.appending(path: name)
            if let image = NSImage(contentsOf: url) { return image }
        }
        return nil
    }

    func metalContent() -> SceneMetalContent? {
        sceneLock.lock()
        defer { sceneLock.unlock() }
        // Rebuilding walks every object and re-resolves textures; the result only changes when
        // the scene or its user properties do.
        if cachedContentRevision == metalRevision, let cachedContent {
            return cachedContent
        }
        if SceneWallpaperViewModel.isVideoType(currentWallpaper.project.type) {
            let content = videoContent()
            cachedContent = content
            cachedContentRevision = metalRevision
            return content
        }
        let signpost = OWESignpost.begin(OWESignpost.scene, "metalContent")
        defer { signpost.end() }
        guard let authoredScene = loadedScene, let wallpaperDir = loadedWallpaperDirectory else { return nil }
        // Content is built from what the user properties say; a property change rebuilds it.
        let valueContext = userValueContext
        var scene = authoredScene
        scene.objects = SceneObjectIdentity.assigningFallbackIDs(
            authoredScene.objects.map { $0.resolvingUserBindings(in: valueContext) })
        let sceneSize = metalSceneSize(for: scene)
        let bloom = bloomSettings(for: scene.general)
        let lighting = SceneLightingSettings(scene.general, in: valueContext)
        sceneEngineCombos = SceneEngineCombos(bloom: bloom, lighting: lighting,
                                              orthographic: !scene.general.usesPerspectiveProjection,
                                              settings: renderSettings)
        // Hidden objects are built too: a script can show them (docs/scenescript-plan.md §4.3).
        let visibility = Dictionary(scene.objects.map { (String($0.id ?? -1), isObjectVisible($0)) },
                                    uniquingKeysWith: { first, _ in first })
        let authoredTransforms = SceneTransformHierarchy(objects: scene.objects, sceneSize: sceneSize)
        // WE draws objects in scene.json order; both lists carry that index so the renderer can interleave them.
        let layers: [SceneMetalLayer] = scene.objects.enumerated().compactMap { index, object in
            var layer = buildLayer(object, wallpaperDir: wallpaperDir, sceneSize: sceneSize, context: valueContext)
            layer?.order = index
            return layer
        }
        var particleSystems: [SceneMetalParticleSystem] = []
        for (index, object) in scene.objects.enumerated() {
            let base = particleSystems.count
            for var system in buildParticleFamily(object, wallpaperDir: wallpaperDir, sceneSize: sceneSize,
                                                  pixelUnits: Self.particlesUsePixelUnits(scene),
                                                  transforms: authoredTransforms) {
                system.order = index
                system.link?.parentIndex += base
                particleSystems.append(system)
            }
        }
        applyParticleBudget(to: &particleSystems, wallpaperDir: wallpaperDir)
        // A scene of scripts alone (groups whose scripts create layers) runs too.
        if !layers.isEmpty || !particleSystems.isEmpty || hasScriptSites {
            var transforms = authoredTransforms
            for layer in layers where layer.fillsScene {
                transforms.makeRoot(layer.id, local: SceneLocalTransform(origin: layer.position, scale: layer.scale, angle: layer.rotation))
            }
            var content = SceneMetalContent(size: sceneSize, layers: layers, particleSystems: particleSystems,
                                            bloom: bloom,
                                            transforms: transforms,
                                            camera: SceneCameraEffects(scene.general, in: valueContext),
                                            wallpaperKey: propertyStoreKey)
            content.motions = objectMotions(scene.objects, besides: layers, sceneSize: sceneSize, context: valueContext)
            content.visibility = visibility
            content.objectIDs = scene.objects.map { $0.id ?? -1 }
            content.scripts = scriptContent(wallpaperDir: wallpaperDir, sceneSize: sceneSize)
            content.timelines = loadedDocument.map {
                SceneTimelineSource(wallpaperID: loadedProjectId ?? Self.localWallpaperID(wallpaperDir),
                                    document: $0.document, signature: $0.signature)
            }
            content.sounds = soundBuilder(wallpaperDir: wallpaperDir).sounds(in: scene.objects, context: valueContext)
            content.lighting = SceneLightingContent(settings: lighting, lights: Self.lights(in: scene.objects, context: valueContext))
            content.volumetrics = volumetricsPlan(content.lighting.lights, camera: SceneVolumetricsCamera(scene: scene, size: sceneSize),
                                                  wallpaperDir: wallpaperDir)
            content.engineCombos = sceneEngineCombos
            content.bloomChain = engineChain("WE's bloom", wallpaperDir: wallpaperDir, SceneBloomChain.build)
            if sceneEngineCombos.hdr {
                content.hdrChain = engineChain("WE's HDR bloom", wallpaperDir: wallpaperDir, SceneHDRChain.build)
            }
            cachedContent = content
            cachedContentRevision = metalRevision
            return content
        }
        guard let preview = loadPreviewImage(wallpaperDir: wallpaperDir) else { return nil }
        return SceneMetalContent(size: sceneSize, layers: [SceneMetalLayer(id: "preview", name: "preview", source: .image(preview),
            position: sceneSize / 2, size: sceneSize, scale: SIMD2<Float>(repeating: 1),
            opacity: 1,
            brightness: 1, color: SIMD4<Float>(repeating: 1), text: nil,
            parallaxDepth: .zero, perspective: false,
            rotation: 0,
                effects: .identity,
            )], particleSystems: [],
            bloom: SceneBloomSettings(enabled: false, strength: 0, threshold: 0.7, tint: SIMD3<Float>(repeating: 1)))
    }

    // MARK: - Video as a scene

    /// Wraps a video wallpaper in a one-layer scene so the effect stack applies to it, the way
    /// Wallpaper Engine's own `scenes/videoplayer` does.
    private func videoContent() -> SceneMetalContent? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let url = currentWallpaper.mediaURL
        let stream = videoStream ?? VideoTextureStream(url: url, device: device)
        guard let stream else {
            OWELog.error(.scene, "Could not open video \(url.lastPathComponent) for Metal playback")
            return nil
        }
        videoStream = stream

        // The display size is unknown here, so the scene is the video's own size and the renderer's
        // placement handles fitting. `keepaspect` then costs nothing: the layer fills its scene.
        let sceneSize = stream.frameSize
        builtVideoFrameSize = sceneSize
        let wallpaper = currentWallpaper
        let musicSync = VideoMusicSyncVisuals(
            zoomAmount: VideoMusicSyncSettings.bool(wallpaper, "zoomEnabled")
                ? Float(VideoMusicSyncSettings.double(wallpaper, "zoomAmount", default: 0.08)) : 0,
            tiltAmount: VideoMusicSyncSettings.bool(wallpaper, "tiltEnabled")
                ? Float(VideoMusicSyncSettings.double(wallpaper, "tiltAmount", default: 3)) : 0,
            saturationAmount: VideoMusicSyncSettings.bool(wallpaper, "saturationEnabled")
                ? Float(VideoMusicSyncSettings.double(wallpaper, "saturationAmount", default: 0.6)) : 0,
            levelSource: { [weak stream] in
                stream?.musicSyncLevel ?? WallpaperServices.shared.audioLevel
            })

        var layer = SceneMetalLayer(
            id: "video", name: "video", source: .video(stream),
            position: sceneSize / 2, size: sceneSize,
            scale: SIMD2<Float>(repeating: 1),
            opacity: 1,
            brightness: 1, color: SIMD4<Float>(repeating: 1), text: nil, parallaxDepth: .zero, perspective: false,
            rotation: 0,
            effects: .identity)
        layer.musicSync = musicSync
        return SceneMetalContent(size: sceneSize, layers: [layer], particleSystems: [],
                                 bloom: SceneBloomSettings(enabled: false, strength: 0, threshold: 0.7,
                                                           tint: SIMD3<Float>(repeating: 1)))
    }

    /// Drives playback for the Metal video path; the AVKit path owns its own players.
    func updateVideoPlayback(playRate: Float, audioRate: Float, audioLevel: Double,
                             audioEnabled: Bool, volume: Float) {
        guard let stream = videoStream else { return }
        stream.setAudio(enabled: audioEnabled, volume: volume)
        let pace = VideoMusicSyncSettings.bool(currentWallpaper, "paceEnabled")
            ? VideoMusicSyncSettings.double(currentWallpaper, "paceAmount", default: 0.25)
            : 0
        stream.update(playRate: playRate, audioRate: audioRate,
                      audioLevel: stream.musicSyncLevel, paceAmount: pace)

        // The first frame decodes seconds after the layer is built, so the scene starts at the
        // placeholder size and would keep the wrong aspect ratio without a rebuild.
        if let built = builtVideoFrameSize, built != stream.frameSize {
            builtVideoFrameSize = stream.frameSize
            bumpRevision()
        }
    }

    /// An object's layer: an image, text or shape layer, with its user bindings; nil for objects
    /// that draw nothing of their own (groups, particle systems, sounds).
    private func buildLayer(_ object: WESceneObject, wallpaperDir: URL, sceneSize: SIMD2<Float>,
                            context: SceneValueContext) -> SceneMetalLayer? {
        var layer = buildMetalLayer(object, wallpaperDir: wallpaperDir, sceneSize: sceneSize)
            ?? buildMetalTextLayer(object, wallpaperDir: wallpaperDir, sceneSize: sceneSize)
            ?? buildShapeLayer(object, wallpaperDir: wallpaperDir, sceneSize: sceneSize)
        layer?.bindings = SceneLayerBindings(object: object, builtWith: context)
        return layer
    }

    // MARK: - Scripts

    /// What the renderer runs the scene's scripts from; nil without a scene document.
    private func scriptContent(wallpaperDir: URL, sceneSize: SIMD2<Float>) -> SceneScriptSceneContent? {
        guard let loadedDocument else { return nil }
        let storeKey = propertyStoreKey
        return SceneScriptSceneContent(
            wallpaperID: loadedProjectId ?? Self.localWallpaperID(wallpaperDir),
            document: loadedDocument.document, documentSignature: loadedDocument.signature,
            project: loadedProject,
            userValues: { WallpaperServices.shared.userProperties(wallpaper: storeKey) },
            file: { [weak self] path in self?.scriptFile(path, wallpaperDir: wallpaperDir) },
            makeLayer: { [weak self] json in self?.buildScriptLayer(json, wallpaperDir: wallpaperDir, sceneSize: sceneSize) })
    }

    /// A stable id for a wallpaper without a Workshop id: its directory's hash (scripts' ids and
    /// `localStorage` are keyed on it).
    static func localWallpaperID(_ directory: URL) -> String {
        let digest = SHA256.hash(data: Data(directory.standardizedFileURL.path.utf8))
        return "local-" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// A file for the scripts (`createLayer` assets, texture animations). Called on a script
    /// thread, so it takes the scene lock like every other asset read.
    private func scriptFile(_ path: String, wallpaperDir: URL) -> Data? {
        sceneLock.lock()
        defer { sceneLock.unlock() }
        return assetData(named: path, wallpaperDir: wallpaperDir)
    }

    /// An object a script created (`thisScene.createLayer`), built like the scene's own: a layer,
    /// a particle system or a sound. Off the main thread, under the scene lock.
    private func buildScriptLayer(_ json: [String: SceneJSON], wallpaperDir: URL,
                                  sceneSize: SIMD2<Float>) -> SceneScriptCreatedObject? {
        sceneLock.lock()
        defer { sceneLock.unlock() }
        let object: WESceneObject
        do {
            let data = try JSONSerialization.data(withJSONObject: SceneJSON.object(json).foundationObject)
            object = try JSONDecoder().decode(WESceneObject.self, from: data)
        } catch {
            OWELog.error(.script, "createLayer: the object can't be decoded: \(error)")
            return nil
        }
        let context = userValueContext
        let resolved = object.resolvingUserBindings(in: context)
        if resolved.particle != nil {
            var systems = buildParticleFamily(resolved, wallpaperDir: wallpaperDir, sceneSize: sceneSize,
                                              pixelUnits: loadedScene.map(Self.particlesUsePixelUnits) ?? true,
                                              transforms: SceneTransformHierarchy(objects: [resolved], sceneSize: sceneSize))
            guard !systems.isEmpty else { return nil }
            // The scene's factor, or the family's own if it alone exceeds the budget.
            let own = ParticleBudget.scale(authored: systems.reduce(0) { $0 + ParticleBudget.capacity(of: $1) },
                                           budget: renderSettings.particleBudget.limit)
            for index in systems.indices { systems[index].budgetScale = min(particleBudgetScale, own) }
            let motion = SceneObjectMotion(object: resolved, sceneSize: sceneSize,
                                           bindings: SceneLayerBindings(object: resolved, builtWith: context))
            return .particles(systems, motion: motion)
        }
        if resolved.sound != nil {
            return soundBuilder(wallpaperDir: wallpaperDir).sounds(in: [resolved], context: context).first.map { .sound($0) }
        }
        return buildLayer(resolved, wallpaperDir: wallpaperDir, sceneSize: sceneSize, context: context).map { .layer($0) }
    }

    /// Finds the scene's sound files in the package, the folder, Workshop items and WE's assets.
    private func soundBuilder(wallpaperDir: URL) -> SceneSoundContentBuilder {
        let parser = pkgParser
        let workshop = workshopAssets
        return SceneSoundContentBuilder(wallpaperDirectory: wallpaperDir,
                                        packagedData: { parser?.extractFile(named: $0) },
                                        workshopURL: { workshop.url(for: $0) },
                                        workshopData: { workshop.data(for: $0) })
    }

    private func bloomSettings(for general: WESceneGeneral) -> SceneBloomSettings {
        SceneBloomSettings(general, in: userValueContext)
    }

    /// The scene's light objects, in scene order. They draw nothing; their transforms are in the
    /// content's hierarchy and motions like any other object's.
    static func lights(in objects: [WESceneObject], context: SceneValueContext) -> [SceneLightObject] {
        objects.compactMap { object in
            guard let light = object.light, let id = object.id else { return nil }
            let animated: [SceneLightValueField] = [.intensity, .radius, .exponent, .innercone, .outercone, .controlpoint]
            let hasTimelines = animated.contains { field in
                if case .object(let bound)? = light.values[field] { return bound.animation != nil }
                return false
            }
            return SceneLightObject(id: String(id), authored: light, light: SceneLight(light, in: context),
                                    depth: SceneLightDepth(object: object), hasTimelines: hasTimelines)
        }
    }

    /// Resolves user-bound values against this wallpaper's properties.
    private var userValueContext: LiveSceneValueContext {
        LiveSceneValueContext(wallpaper: propertyStoreKey)
    }

    private func metalSceneSize(for scene: WEScene) -> SIMD2<Float> {
        if let projection = scene.general.orthogonalprojection {
            return SIMD2<Float>(Float(projection.width), Float(projection.height))
        }
        // `orthogonalprojection: null` is a perspective scene: objects are in world units, so their
        // bounds say nothing about the canvas. Render at WE's default canvas.
        if scene.general.usesPerspectiveProjection { return SIMD2<Float>(1920, 1080) }
        let imageBounds = scene.objects.compactMap { object -> SIMD2<Float>? in
            guard let origin = object.origin?.parseVector3(), let size = object.size?.parseVector2() else { return nil }
            return SIMD2<Float>(Float(origin.0 + size.0 / 2), Float(origin.1 + size.1 / 2))
        }
        guard let widest = imageBounds.map(\.x).max(), let tallest = imageBounds.map(\.y).max(),
              widest > 0, tallest > 0 else { return SIMD2<Float>(1920, 1080) }
        return SIMD2<Float>(widest, tallest)
    }

    /// An object's own `origin`, relative to its parent.
    private func localOrigin(for object: WESceneObject, sceneSize: SIMD2<Float>) -> SIMD2<Float> {
        SceneLocalTransform(object: object, sceneSize: sceneSize).origin
    }

    private func buildMetalLayer(_ object: WESceneObject, wallpaperDir: URL, sceneSize: SIMD2<Float>) -> SceneMetalLayer? {
        guard let imagePath = object.image,
              let model: WEModel = loadJSON(path: imagePath, wallpaperDir: wallpaperDir),
              let materialPath = model.material,
              let material: WEMaterial = loadJSON(path: materialPath, wallpaperDir: wallpaperDir) else {
            return nil
        }
        if model.solidlayer == true {
            var layer = buildSolidLayer(object, wallpaperDir: wallpaperDir, sceneSize: sceneSize)
            layer.imageMaterial = buildImageMaterial(materialPath, object: object, wallpaperDir: wallpaperDir)
            return layer
        }
        guard let textureName = material.passes?.first?.textures?.first,
              let source = loadMetalTexture(named: textureName, materialDir: materialPath, wallpaperDir: wallpaperDir) else {
            return nil
        }
        if model.puppet != nil {
            Self.log("Puppet Warp rig found for \(imagePath); rendering authored atlas until mesh rig data is available")
        }
        let sceneInput = textureName == "_rt_FullFrameBuffer" || textureName == "_rt_MipMappedFrameBuffer"
        let size: SIMD2<Float>
        if model.fullscreen == true {
            size = sceneSize
        } else if let sizeString = object.size {
            let value = sizeString.parseVector2()
            size = SIMD2<Float>(Float(value.0), Float(value.1))
        } else {
            // In pixels, and for a .tex the image's own size, not the padded allocation around it.
            if case let .animated(animation) = source, animation.images.isEmpty { return nil }
            size = source.pixelSize * textureReductionApplied(named: textureName, materialDir: materialPath,
                                                              wallpaperDir: wallpaperDir)
        }
        let position: SIMD2<Float> = model.fullscreen == true
            ? sceneSize / 2
            : localOrigin(for: object, sceneSize: sceneSize)
        let rotation = Float(object.angles?.parseVector3().2 ?? 0)
        let staticScale = object.scale?.parseVector3() ?? (1, 1, 1)
        let objectColor = object.color?.parseVector3() ?? (1, 1, 1)
        let effectPlans = buildEffectPlans(object.effects ?? [], objectID: object.id ?? -1, wallpaperDir: wallpaperDir)
        var layer = SceneMetalLayer(id: String(object.id ?? -1), name: object.name ?? String(object.id ?? -1), source: source, position: position, size: size,
                       scale: SIMD2<Float>(Float(staticScale.0), Float(staticScale.1)),
                       opacity: Float(object.alpha ?? 1),
                       brightness: Float(object.brightness ?? 1), color: SIMD4<Float>(Float(objectColor.0), Float(objectColor.1), Float(objectColor.2), 1), text: nil,
                       parallaxDepth: Self.parallaxDepth(of: object),
                       perspective: object.perspective ?? false,
                               rotation: rotation, effects: .identity)
        layer.weEffects = effectPlans.plans
        layer.sceneInput = sceneInput
        if case .animated = source { layer.textureKey = textureName }
        layer.alignment = model.fullscreen == true ? nil : object.alignment
        layer.fillsScene = model.fullscreen == true
        // A layer whose image is the scene only exists to run effects on it; WE skips it without any.
        if sceneInput, effectPlans.plans.isEmpty { return nil }
        if !sceneInput {
            // WE prelights a puppet too (0x140209540), drawing its mesh lit; its mesh isn't drawn
            // here, and its atlas is lit where it is drawn, as the still mesh would be.
            layer.imageMaterial = buildImageMaterial(materialPath, object: object, wallpaperDir: wallpaperDir,
                                                     prelit: !effectPlans.plans.isEmpty)
        }
        return layer
    }

    /// The image's own material through WE's shader; nil (logged when it's a failure) keeps the native draw.
    /// `prelit`: the layer has effects, so WE lights it before them (`ImageMaterialPlan.prelighting`).
    private func buildImageMaterial(_ materialPath: String, object: WESceneObject, wallpaperDir: URL,
                                    prelit: Bool = false) -> ImageMaterialPlan? {
        guard let translator = Self.effectTranslator else { return nil }
        let builder = ImageMaterialPlanBuilder(
            translator: translator,
            readFile: { [weak self] path in self?.assetData(named: path, wallpaperDir: wallpaperDir) },
            loadTexture: { [weak self] name, path in self?.loadMetalTexture(named: name, materialDir: path, wallpaperDir: wallpaperDir) },
            sceneEngineCombos: sceneEngineCombos)
        do {
            return try builder.build(materialPath: materialPath, colorBlendMode: object.colorBlendMode,
                                     clampUVs: object.clampuvs, prelit: prelit)
        } catch {
            OWELog.error(.scene, "Image layer \(object.id ?? -1) draws natively, material \(materialPath): \(error)")
            return nil
        }
    }

    /// `models/util/solidlayer*.json`: WE's `flat` shader fills the quad with the object's `color`.
    /// The colour is baked into a generated texture so authored effects see the coloured image, as
    /// they do in WE; `alpha` stays on the layer and is applied when the quad is drawn.
    private func buildSolidLayer(_ object: WESceneObject, wallpaperDir: URL,
                                 sceneSize: SIMD2<Float>) -> SceneMetalLayer {
        let authoredSize = object.size.map { value -> SIMD2<Float> in
            let parsed = value.parseVector2()
            return SIMD2<Float>(Float(parsed.0), Float(parsed.1))
        }
        // An authored size is the quad's even when it is zero: WE draws nothing of an empty quad
        // (2963872291's 'Player Options', a 0×0 host for the music player's scripts). Only a
        // layer without a size takes the scene's.
        let size = authoredSize ?? sceneSize
        let color = object.color?.parseVector3() ?? (1, 1, 1)
        let staticScale = object.scale?.parseVector3() ?? (1, 1, 1)
        var layer = SceneMetalLayer(id: String(object.id ?? -1), name: object.name ?? String(object.id ?? -1),
                       source: .image(Self.solidImage(red: color.0, green: color.1, blue: color.2)),
                       position: localOrigin(for: object, sceneSize: sceneSize),
                       size: size,
                       scale: SIMD2<Float>(Float(staticScale.0), Float(staticScale.1)),
                       opacity: Float(object.alpha ?? 1),
                       brightness: Float(object.brightness ?? 1), color: SIMD4<Float>(repeating: 1), text: nil,
                       parallaxDepth: Self.parallaxDepth(of: object),
                       perspective: object.perspective ?? false,
                       rotation: Float(object.angles?.parseVector3().2 ?? 0), effects: .identity)
        layer.weEffects = buildEffectPlans(object.effects ?? [], objectID: object.id ?? -1, wallpaperDir: wallpaperDir).plans
        layer.alignment = object.alignment
        return layer
    }

    /// A 1x1 opaque image of one colour; the quad stretches it to the layer's size. Its texel is
    /// the colour's value as authored, like WE's `util/white` tinted by `g_Color4`. Drawing it with
    /// AppKit would convert it to the display's colour space (e.g. Display P3) and shift it.
    static func solidImage(red: Double, green: Double, blue: Double) -> NSImage {
        pixelImage([red, green, blue, 1])
    }

    /// A 1x1 image holding `rgba` (0...1 each) as straight-alpha bytes, without colour management.
    static func pixelImage(_ rgba: [Double]) -> NSImage {
        let bytes = rgba.map { UInt8((min(max($0.isFinite ? $0 : 0, 0), 1) * 255).rounded()) }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue).union(.byteOrder32Big),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            preconditionFailure("a 1x1 RGBA8 image is always representable")
        }
        return NSImage(cgImage: image, size: NSSize(width: 1, height: 1))
    }

    /// Text is laid out and rasterised by the renderer every frame (its string can change); the
    /// layer's source is only a placeholder. `size` is the block before auto-sizing.
    private func buildMetalTextLayer(_ object: WESceneObject, wallpaperDir: URL, sceneSize: SIMD2<Float>) -> SceneMetalLayer? {
        guard let text = object.textValue else { return nil }
        let sizeValue = object.size?.parseVector2() ?? (0, 0)
        let textScale = object.scale?.parseVector3() ?? (1, 1, 1)
        let color = object.color?.parseVector3() ?? (1, 1, 1)
        // Padding is authored as "32" or "32 32"; a scalar applies to both axes.
        let paddingParts = (object.padding ?? "0").split(separator: " ").compactMap { Float($0) }
        let padding = SIMD2<Float>(paddingParts.first ?? 0,
                                   paddingParts.count > 1 ? paddingParts[1] : (paddingParts.first ?? 0))
        let textConfig = SceneMetalText(value: text, font: registerFont(object.font),
                                         pointSize: CGFloat(object.pointsize ?? 24),
                                         horizontalAlignment: object.horizontalalign,
                                         verticalAlignment: object.verticalalign,
                                         padding: padding,
                                         maxWidth: object.limitwidth == true ? object.maxwidth.map(Float.init) : nil,
                                         maxRows: object.limitrows == true ? object.maxrows : nil,
                                         useEllipsis: object.limituseellipsis ?? false,
                                         anchor: object.anchor, blockAlign: object.blockalign ?? false)
        var layer = SceneMetalLayer(id: String(object.id ?? -1), name: object.name ?? String(object.id ?? -1),
                               source: .image(transparentPlaceholderImage),
                               position: localOrigin(for: object, sceneSize: sceneSize),
                               size: SIMD2<Float>(Float(sizeValue.0), Float(sizeValue.1)),
                               scale: SIMD2<Float>(Float(textScale.0), Float(textScale.1)),
                               opacity: Float(object.alpha ?? 1),
                               brightness: Float(object.brightness ?? 1), color: SIMD4<Float>(Float(color.0), Float(color.1), Float(color.2), 1), text: textConfig, parallaxDepth: Self.parallaxDepth(of: object),
                               perspective: object.perspective ?? false,
                               rotation: Float(object.angles?.parseVector3().2 ?? 0),
                               effects: .identity)
        layer.alignment = SceneAlignment.text(horizontal: object.horizontalalign, vertical: object.verticalalign)
        // WE runs a text object's effects on its rasterised text; the renderer rasterises before effects run.
        layer.weEffects = buildEffectPlans(object.effects ?? [], objectID: object.id ?? -1, wallpaperDir: wallpaperDir).plans
        // Drawn through WE's `font` material, which reads its texture as coverage: effects' output
        // isn't that, and `font` has no blend-mode combo, so those layers keep the native draw.
        if layer.weEffects.isEmpty, (object.colorBlendMode ?? 0) == 0 {
            layer.imageMaterial = buildTextMaterial(object, wallpaperDir: wallpaperDir)
        }
        return layer
    }

    /// A text object's `font` material (`materials/fonts/basefont.json`), whose `g_Texture0` is the
    /// renderer's rasterised text. WE's MSDF atlas (`msdf`, outline, drop shadow) isn't generated:
    /// CoreText's coverage stands in for it, as for plain fonts. nil (logged) keeps the native draw.
    private func buildTextMaterial(_ object: WESceneObject, wallpaperDir: URL) -> ImageMaterialPlan? {
        guard let translator = Self.effectTranslator else { return nil }
        let builder = ImageMaterialPlanBuilder(
            translator: translator,
            readFile: { [weak self] path in self?.assetData(named: path, wallpaperDir: wallpaperDir) },
            loadTexture: { _, _ in nil },
            sceneEngineCombos: sceneEngineCombos)
        let materialPath = "materials/fonts/basefont.json"
        do {
            return try builder.buildText(materialPath: materialPath)
        } catch {
            OWELog.error(.scene, "Text layer \(object.id ?? -1) draws natively, material \(materialPath): \(error)")
            return nil
        }
    }

    /// Standalone "shape" objects (e.g. a DIRECTDRAW light-shaft quad) have no image/particle of their own;
    /// they exist purely to host a procedural effect, so give them a full-scene solid layer to render onto.
    private func buildShapeLayer(_ object: WESceneObject, wallpaperDir: URL, sceneSize: SIMD2<Float>) -> SceneMetalLayer? {
        guard object.shape != nil, let effects = object.effects, !effects.isEmpty else { return nil }
        let plans = buildEffectPlans(effects, objectID: object.id ?? -1, wallpaperDir: wallpaperDir).plans
        guard !plans.isEmpty else { return nil }
        let position = localOrigin(for: object, sceneSize: sceneSize)
        let size: SIMD2<Float>
        if let sizeString = object.size {
            let value = sizeString.parseVector2()
            size = SIMD2<Float>(Float(value.0), Float(value.1))
        } else {
            size = sceneSize
        }
        var layer = SceneMetalLayer(id: String(object.id ?? -1), name: object.name ?? String(object.id ?? -1),
                       source: .image(transparentPlaceholderImage), position: position, size: size,
                       scale: SIMD2<Float>(repeating: 1),
                       opacity: Float(object.alpha ?? 1),
                       brightness: 1, color: SIMD4<Float>(repeating: 1), text: nil, parallaxDepth: Self.parallaxDepth(of: object), perspective: object.perspective ?? false,
                       rotation: Float(object.angles?.parseVector3().2 ?? 0),
                       effects: .identity)
        layer.weEffects = plans
        layer.alignment = object.alignment
        return layer
    }

    /// A fully transparent 1x1 placeholder texture for procedural shape layers (e.g. light shafts) that
    /// have no authored image of their own; only the effect's computed alpha should ever become visible.
    private var transparentPlaceholderImage: NSImage {
        Self.pixelImage([1, 1, 1, 0])
    }

    private func registerFont(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        if let registered = registeredFontNames[path] { return registered }
        let resolver = SceneFontResolver(
            wallpaperData: { self.loadFontData(named: $0) },
            assetDirectories: [WallpaperEngineAssets.configured, WallpaperEngineAssets.bundled].compactMap { $0 },
            workshop: WorkshopAssetResolver(roots: WorkshopAssetResolver.defaultRoots()))
        let data: Data
        switch resolver.resolve(path) {
        case .system(let family)?:
            registeredFontNames[path] = family
            return family
        case .data(let bytes, _)?:
            data = bytes
        case nil:
            OWELog.error(.scene, "Font \"\(path)\" not found in the wallpaper, WE assets or workshop items; using the system font")
            return path
        }
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor],
              let descriptor = descriptors.first,
              let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String else {
            return path
        }

        // Fonts inside a PKG have no filesystem URL, so register their in-memory
        // CGFont before NSFont(name:) is used by either text rendering path.
        if let provider = CGDataProvider(data: data as CFData),
           let font = CGFont(provider) {
            var error: Unmanaged<CFError>?
            _ = CTFontManagerRegisterGraphicsFont(font, &error)
            let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String
            SceneFontRegistry.register(font, names: [path, name, family ?? ""])
        }
        registeredFontNames[path] = name
        return name
    }

    /// The wallpaper's own package or folder; `SceneFontResolver` handles the other sources.
    private func loadFontData(named path: String) -> Data? {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let keys = [path, normalized, (normalized as NSString).lastPathComponent]
        for key in keys {
            if let cached = assetDataCache[key] { return cached }
            if let data = pkgParser?.extractFile(named: key) {
                assetDataCache[key] = data
                return data
            }
        }
        if let entry = pkgParser?.fileList.first(where: {
            let candidate = $0.replacingOccurrences(of: "\\", with: "/")
            return candidate.caseInsensitiveCompare(normalized) == .orderedSame
                || (candidate as NSString).lastPathComponent.caseInsensitiveCompare((normalized as NSString).lastPathComponent) == .orderedSame
        }), let data = pkgParser?.extractFile(named: entry) {
            assetDataCache[path] = data
            return data
        }
        if let directory = loadedWallpaperDirectory {
            for candidate in [normalized, (normalized as NSString).lastPathComponent] {
                if let data = try? Data(contentsOf: directory.appending(path: candidate)) {
                    assetDataCache[path] = data
                    return data
                }
            }
        }
        return nil
    }


    /// Shared by every scene: translated variants are cached in memory and on disk.
    private static let effectTranslator: ShaderVariantTranslator? = {
        do {
            return ShaderVariantTranslator(compiler: try ShaderCompilerFactory.makeDefault())
        } catch {
            OWELog.error(.shader, "WE shader toolchain unavailable, scene effects are disabled: \(error)")
            return nil
        }
    }()

    /// One of WE's post-processing chains (`SceneBloomChain`, `SceneHDRChain`) planned by `build`;
    /// nil, logged, when it can't be planned.
    private func engineChain<Chain>(_ name: String, wallpaperDir: URL,
                                    _ build: (SceneEffectPlanBuilder) throws -> Chain) -> Chain? {
        guard let translator = Self.effectTranslator else { return nil }
        let builder = SceneEffectPlanBuilder(
            translator: translator,
            readFile: { [weak self] path in self?.assetData(named: path, wallpaperDir: wallpaperDir) },
            loadTexture: { [weak self] name, materialPath in
                self?.loadMetalTexture(named: name, materialDir: materialPath, wallpaperDir: wallpaperDir)
            },
            sceneEngineCombos: sceneEngineCombos)
        do {
            return try build(builder)
        } catch {
            OWELog.error(.scene, "\(name) can't be planned; the scene draws without it: \(error)")
            return nil
        }
    }

    /// WE's volumetric lights (`SceneVolumetricsPlan`); nil, logged, when they can't be planned.
    private func volumetricsPlan(_ lights: [SceneLightObject], camera: SceneVolumetricsCamera,
                                 wallpaperDir: URL) -> SceneVolumetricsPlan? {
        guard lights.contains(where: \.light.castVolumetrics), let translator = Self.effectTranslator else { return nil }
        let builder = SceneEffectPlanBuilder(
            translator: translator,
            readFile: { [weak self] path in self?.assetData(named: path, wallpaperDir: wallpaperDir) },
            loadTexture: { [weak self] name, materialPath in
                self?.loadMetalTexture(named: name, materialDir: materialPath, wallpaperDir: wallpaperDir)
            },
            sceneEngineCombos: sceneEngineCombos)
        do {
            return try SceneVolumetricsPlan.build(lights: lights, camera: camera, settings: renderSettings, builder: builder)
        } catch {
            OWELog.error(.scene, "WE's volumetrics can't be planned; the scene draws without them: \(error)")
            return nil
        }
    }

    /// Plans each visible effect for Wallpaper Engine's own shaders. An effect that can't be
    /// planned (no toolchain, sources missing) is left out, with the reason logged.
    private func buildEffectPlans(_ effects: [WEObjectEffect], objectID: Int,
                                  wallpaperDir: URL) -> (plans: [SceneEffectPlan], handled: Set<Int>) {
        guard !effects.isEmpty, let translator = Self.effectTranslator else { return ([], []) }
        let builder = SceneEffectPlanBuilder(
            translator: translator,
            readFile: { [weak self] path in self?.assetData(named: path, wallpaperDir: wallpaperDir) },
            loadTexture: { [weak self] name, materialPath in
                self?.loadMetalTexture(named: name, materialDir: materialPath, wallpaperDir: wallpaperDir)
            },
            sceneEngineCombos: sceneEngineCombos)
        var plans: [SceneEffectPlan] = []
        var handled = Set<Int>()
        let storeKey = propertyStoreKey
        for (index, effect) in effects.enumerated() {
            // The app's own switch removes an effect; WE's `visible` only hides it, so a script or a
            // user property can show it again.
            let enabled = userProperty(
                sceneAuthoredEffectEnabledKey(objectID: objectID, effectIndex: index)) != "false"
            guard enabled else {
                handled.insert(index)
                continue
            }
            do {
                var plan = try builder.build(effect, owner: (objectID, index), overrides: { key in
                    SceneEffectOverride.stored(
                        property: sceneAuthoredEffectOverrideKey(objectID: objectID, effectIndex: index, parameter: key),
                        lookup: { WallpaperServices.shared.userPropertyString($0, wallpaper: storeKey) })
                })
                plan.effectIndex = index
                plan.visible = isEffectVisible(effect)
                plans.append(plan)
                handled.insert(index)
            } catch {
                OWELog.error(.scene, "Effect \(effect.file) on object \(objectID) can't use WE shaders: \(error)")
            }
        }
        return (plans, handled)
    }






    /// Key of this wallpaper instance's user properties in the script engine's store.
    var propertyStoreKey: String {
        (loadedWallpaperDirectory ?? currentWallpaper.wallpaperDirectory).path
    }

    /// This wallpaper's current value of a user property.
    func userProperty(_ name: String) -> String? {
        WallpaperServices.shared.userPropertyString(name, wallpaper: propertyStoreKey)
    }

    private func isObjectVisible(_ object: WESceneObject) -> Bool {
        let objectID = object.id ?? -1
        let overrideKey = sceneObjectVisibilityKey(objectID: objectID)
        if let override = userProperty(overrideKey) {
            return override != "false"
        }
        if object.textValue != nil {
            if userProperty("_owe_text_\(objectID)_enabled") == "false" {
                return false
            }
        }
        if let property = object.visibleUserProperty {
            guard let selectedValue = userProperty(property) else {
                return object.visible != false
            }
            if let condition = object.visibleCondition {
                return normalizeVariant(condition) == normalizeVariant(selectedValue)
            }
            return selectedValue.caseInsensitiveCompare("true") == .orderedSame || selectedValue == "1"
        }
        return object.visible != false
    }

    private func isEffectVisible(_ effect: WEObjectEffect) -> Bool {
        Self.isEffectVisible(effect, userProperty: userProperty)
    }

    /// An effect bound to a user property follows it; with the property missing it keeps its
    /// authored `visible` (default true), as objects do.
    static func isEffectVisible(_ effect: WEObjectEffect, userProperty: (String) -> String?) -> Bool {
        if let property = effect.visibleUserProperty {
            guard let selectedValue = userProperty(property) else { return effect.visible != false }
            if let condition = effect.visibleCondition {
                return normalizeVariant(condition) == normalizeVariant(selectedValue)
            }
            return selectedValue.caseInsensitiveCompare("true") == .orderedSame || selectedValue == "1"
        }
        return effect.visible != false
    }

    private func normalizeVariant(_ value: String) -> String {
        Self.normalizeVariant(value)
    }

    private static func normalizeVariant(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// An object's `parallaxDepth` (WE's 1 1 when absent), as the layer carries it.
    static func parallaxDepth(of object: WESceneObject) -> SIMD3<Float> {
        let value = object.parallaxDepthValue
        return SIMD3<Float>(Float(value.0), Float(value.1), Float(value.2))
    }

    private func loadMetalTexture(named name: String, materialDir: String, wallpaperDir: URL) -> SceneMetalTextureSource? {
        // WE's texture reduction loads a smaller mipmap (`TextureReduction`), cached apart.
        let reduction = renderSettings.textureReduction
        let cacheKey = "\(materialDir)|\(name)" + (reduction > 1 ? "|reduced\(reduction)" : "")
        if let cached = cachedTexture(cacheKey) { return cached }
        OWEFrameMetrics.countTextureDecode()
        let signpost = OWESignpost.begin(OWESignpost.scene, "decodeTexture")
        defer { signpost.end() }

        if name.hasPrefix("_rt") || name.hasPrefix("rt/") {
            return cacheTexture(.image(transparentPlaceholderImage), for: cacheKey)
        }

        for path in Self.texturePaths(named: name, materialDir: materialDir) {
            let data = assetData(named: path, wallpaperDir: wallpaperDir)
            guard let data else { continue }
            let parser = TEXParser(data: data)
            if let animation = parser.extractAnimatedImages(reduction: reduction) {
                return cacheTexture(.animated(animation), for: cacheKey)
            }
            if let texture = parser.extractCompressedTexture(reduction: reduction) {
                return cacheTexture(.dxt(texture), for: cacheKey)
            }
            if let image = parser.extractImage(reduction: reduction) {
                return cacheTexture(.image(image), for: cacheKey)
            }
        }
        guard let image = loadTexture(named: name, materialDir: materialDir, wallpaperDir: wallpaperDir) else { return nil }
        return cacheTexture(.image(image), for: cacheKey)
    }

    /// Where a material's texture `name` may be, in the order they are tried.
    private static func texturePaths(named name: String, materialDir: String) -> [String] {
        let materialDirPath = (materialDir as NSString).deletingLastPathComponent
        let root = materialDirPath.split(separator: "/").first.map(String.init) ?? "materials"
        return Array(Set(["\(materialDirPath)/\(name).tex", "\(root)/\(name).tex",
                          "materials/\(name).tex", "\(name).tex"]))
    }

    /// How much smaller than its header's image texture `name` loaded under WE's texture reduction:
    /// 2 when it skipped the first of several mipmaps, else 1. A layer sized by its image keeps the
    /// header's size, as WE's texture keeps it (`TextureReduction`).
    private func textureReductionApplied(named name: String, materialDir: String, wallpaperDir: URL) -> Float {
        let reduction = renderSettings.textureReduction
        guard reduction > 1 else { return 1 }
        for path in Self.texturePaths(named: name, materialDir: materialDir) {
            guard let data = assetData(named: path, wallpaperDir: wallpaperDir) else { continue }
            let mipmaps = TEXParser(data: data).firstImageMipmapCount() ?? 1
            return Float(1 << TextureReduction.loadedMipmap(reduction: reduction, mipmapCount: mipmaps))
        }
        return 1
    }

    /// How every object that isn't a drawn layer (groups, particle systems) moves, so its
    /// children and its own particles follow it live.
    private func objectMotions(_ objects: [WESceneObject], besides layers: [SceneMetalLayer], sceneSize: SIMD2<Float>,
                               context: SceneValueContext) -> [String: SceneObjectMotion] {
        let layerIDs = Set(layers.map(\.id))
        var motions: [String: SceneObjectMotion] = [:]
        for object in objects {
            guard let id = object.id.map(String.init), !layerIDs.contains(id) else { continue }
            motions[id] = SceneObjectMotion(object: object, sceneSize: sceneSize,
                                            bindings: SceneLayerBindings(object: object, builtWith: context))
        }
        return motions
    }

    /// Thins the scene's particle systems to the user's budget (`ParticleBudget`), logging it once
    /// per scene and budget.
    private func applyParticleBudget(to systems: inout [SceneMetalParticleSystem], wallpaperDir: URL) {
        let report = ParticleBudget.apply(renderSettings.particleBudget.limit, to: &systems)
        particleBudgetScale = report?.scale ?? 1
        guard let report, loggedParticleBudget?.directory != wallpaperDir || loggedParticleBudget?.report != report else { return }
        loggedParticleBudget = (wallpaperDir, report)
        OWELog.info(.scene, String(format: "%@: %d particles authored over the budget of %d; every system's maximum and rate × %.3f",
                                   wallpaperDir.lastPathComponent, report.authored, report.budget, report.scale))
    }

    /// A particle object's system followed by its children (`ParticleFamilyBuilder`).
    /// WE's particle defaults are in pixels in an orthographic scene with a size (its parser's flag,
    /// `wallpaper64.exe` 0x14018768a), in world units otherwise.
    static func particlesUsePixelUnits(_ scene: WEScene) -> Bool {
        guard let projection = scene.general.orthogonalprojection else { return false }
        return projection.width != 0 || projection.height != 0
    }

    private func buildParticleFamily(_ object: WESceneObject, wallpaperDir: URL, sceneSize: SIMD2<Float>, pixelUnits: Bool,
                                     transforms: SceneTransformHierarchy) -> [SceneMetalParticleSystem] {
        guard let particlePath = object.particle else { return [] }
        // The emitter's full world transform: its own and its parents' origin, scale and angle.
        let world = object.id.map { transforms.world(of: String($0)) }
            ?? SceneAffineTransform(SceneLocalTransform(object: object, sceneSize: sceneSize))
        let builder = ParticleFamilyBuilder(
            load: { [weak self] path in self?.loadJSON(path: path, wallpaperDir: wallpaperDir) },
            build: { [weak self] path, system, world, overrides in
                self?.buildMetalParticleSystem(path, particleSystem: system, object: object, world: world,
                                               overrides: overrides, sceneSize: sceneSize, pixelUnits: pixelUnits,
                                               wallpaperDir: wallpaperDir)
            },
            report: { message in OWELog.error(.scene, "Particle object \(object.id ?? -1): \(message)") })
        var family = builder.family(particlePath, world: world,
                                    overrides: SceneParticleOverrides(object.instanceoverride, in: userValueContext))
        // Only the root is the object; its children follow it through their links.
        for index in family.indices.dropFirst() { family[index].objectID = nil }
        return family
    }

    private func buildMetalParticleSystem(_ particlePath: String, particleSystem: WEParticleSystem, object: WESceneObject,
                                          world: SceneAffineTransform, overrides: SceneParticleOverrides,
                                          sceneSize: SIMD2<Float>, pixelUnits: Bool,
                                          wallpaperDir: URL) -> SceneMetalParticleSystem? {
        guard let materialPath = particleSystem.material,
              let material: WEMaterial = loadJSON(path: materialPath, wallpaperDir: wallpaperDir),
              let textureName = material.passes?.first?.textures?.first else { return nil }
        let source = loadMetalTexture(named: textureName, materialDir: materialPath, wallpaperDir: wallpaperDir)
            ?? generateProceduralTexture(named: textureName).map(SceneMetalTextureSource.image)
        guard let source else { return nil }
        let spriteSheet = loadSpriteSheet(named: textureName, materialDir: materialPath,
                          wallpaperDir: wallpaperDir, source: source)

        let particleRenderer = particleSystem.renderer?.first
        let materialPlan = buildParticleMaterial(materialPath, particleSystem: particleSystem, renderer: particleRenderer,
                                                 source: source, spriteSheet: spriteSheet, object: object,
                                                 wallpaperDir: wallpaperDir)
        var system = ParticleSystemBuilder.build(particlePath, particleSystem: particleSystem, object: object,
                                                 world: world, overrides: overrides, sceneSize: sceneSize,
                                                 source: source, spriteSheet: spriteSheet, material: material,
                                                 materialPlan: materialPlan, pixelUnits: pixelUnits)
        system.material = materialPlan
        let albedo = ParticleMaterialPlanBuilder.textureHeader(named: textureName, materialPath: materialPath) {
            assetData(named: $0, wallpaperDir: wallpaperDir)
        }
        system.fallbackSource = ParticleFallbackTexture.converted(source, format: albedo.flatMap(TEXImageFormat.init(texData:)))
        return system
    }

    /// The system's material through WE's particle shaders; nil (logged when it's a failure)
    /// keeps the built-in particle draw.
    private func buildParticleMaterial(_ materialPath: String, particleSystem: WEParticleSystem,
                                       renderer: WEParticleRenderer?, source: SceneMetalTextureSource,
                                       spriteSheet: SpriteSheet?, object: WESceneObject,
                                       wallpaperDir: URL) -> ParticleMaterialPlan? {
        guard let translator = Self.effectTranslator else { return nil }
        let builder = ParticleMaterialPlanBuilder(
            translator: translator,
            readFile: { [weak self] path in self?.assetData(named: path, wallpaperDir: wallpaperDir) },
            loadTexture: { [weak self] name, path in self?.loadMetalTexture(named: name, materialDir: path, wallpaperDir: wallpaperDir) },
            sceneEngineCombos: sceneEngineCombos)
        do {
            return try builder.build(materialPath: materialPath, renderer: renderer, flags: particleSystem.flags ?? 0,
                                     baseTexture: source, spriteSheet: spriteSheet)
        } catch {
            OWELog.error(.scene, "Particle system \(object.id ?? -1) uses the built-in draw, material \(materialPath): \(error)")
            return nil
        }
    }

    private func loadSpriteSheet(named name: String, materialDir: String, wallpaperDir: URL,
                                 source: SceneMetalTextureSource) -> SpriteSheet? {
        struct TextureMetadata: Decodable {
            struct Sequence: Decodable { let frames: Int; let width: Double; let height: Double; let duration: Double }
            let spritesheetsequences: [Sequence]?
        }
        let materialDirectory = (materialDir as NSString).deletingLastPathComponent
        let root = materialDirectory.split(separator: "/").first.map(String.init) ?? "materials"
        let candidates = ["\(materialDirectory)/\(name).tex-json", "\(root)/\(name).tex-json", "\(name).tex-json"]
        for candidate in candidates {
            let data = assetData(named: candidate, wallpaperDir: wallpaperDir)
            guard let data, let metadata = try? JSONDecoder().decode(TextureMetadata.self, from: data),
                  let sequence = metadata.spritesheetsequences?.first, sequence.frames > 0,
                  sequence.width > 0, sequence.height > 0 else { continue }
            let textureSize: (width: Double, height: Double)
            switch source {
            case let .dxt(texture):
                textureSize = (Double(texture.width), Double(texture.height))
            case let .image(image):
                let representation = image.representations.first
                textureSize = (Double(representation?.pixelsWide ?? Int(image.size.width)),
                               Double(representation?.pixelsHigh ?? Int(image.size.height)))
            case let .animated(animation):
                guard let image = animation.images.first else { continue }
                let representation = image.representations.first
                textureSize = (Double(representation?.pixelsWide ?? Int(image.size.width)),
                               Double(representation?.pixelsHigh ?? Int(image.size.height)))
            case let .video(stream):
                textureSize = (Double(stream.frameSize.x), Double(stream.frameSize.y))
            }
            let columns = max(1, min(sequence.frames, Int((textureSize.width / sequence.width).rounded())))
            let authoredRows = max(1, Int((textureSize.height / sequence.height).rounded()))
            let rows = max(authoredRows, Int(ceil(Double(sequence.frames) / Double(columns))))
            return SpriteSheet(columns: columns, rows: rows, frames: sequence.frames, duration: Float(sequence.duration))
        }
        return nil
    }

    // MARK: - Asset Loading

    private func loadJSON<T: Decodable>(path: String, wallpaperDir: URL) -> T? {
        guard let original = assetData(named: path, wallpaperDir: wallpaperDir) else { return nil }
        let storageKey = settingsIdentity(for: wallpaperDir).key(.userProperties)
        let overrideKey = "_owe_scene_asset_\(path)_json"
        let data: Data
        if let values = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String],
           let override = values[overrideKey], let overrideData = override.data(using: .utf8) {
            data = overrideData
        } else {
            data = original
        }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func assetData(named path: String, wallpaperDir: URL) -> Data? {
        if let cached = assetDataCache[path] { return cached }
        // WE's fixed copy of a broken Workshop shader replaces the one the wallpaper ships.
        if let fixed = shaderCompat?.replacement(forShaderPath: path, projectId: loadedProjectId) {
            Self.log("Using WE's compatibility copy of \(path)")
            assetDataCache[path] = fixed
            return fixed
        }
        // A missing loose file is an ordinary miss: the next source is tried.
        let data = pkgParser?.extractFile(named: path)
            ?? (try? Data(contentsOf: wallpaperDir.appending(path: path)))
            ?? workshopAssets.data(for: path)
            ?? sharedAssetData(named: path)
        if let data { assetDataCache[path] = data }
        return data
    }

    /// The project's Workshop id: `workshopid` in project.json, else a numeric folder name
    /// (Steam names downloaded items by id). Nil for a local project.
    static func workshopId(of wallpaper: WEWallpaper) -> String? {
        if let id = wallpaper.project.workshopid?.rawValue, !id.isEmpty, id.allSatisfy(\.isNumber) { return id }
        let folder = wallpaper.wallpaperDirectory.lastPathComponent
        return !folder.isEmpty && folder.allSatisfy({ $0.isASCII && $0.isNumber }) ? folder : nil
    }

    private func sharedAssetData(named path: String) -> Data? {
        let assetsDirectories = WallpaperEngineAssets.searchDirectories
        guard !assetsDirectories.isEmpty else {
            Self.logDetail("Shared asset lookup skipped: no Wallpaper Engine assets available")
            return nil
        }
        let normalizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var relativePaths = [normalizedPath]
        if URL(fileURLWithPath: normalizedPath).pathExtension.isEmpty {
            relativePaths.append("\(normalizedPath).tex")
        }
        if normalizedPath.hasPrefix("materials/presets/") {
            relativePaths.append("materials/\(normalizedPath.dropFirst("materials/presets/".count))")
        } else if !normalizedPath.hasPrefix("materials/") {
            relativePaths.append("materials/\(normalizedPath)")
        }
        guard let candidate = WallpaperEngineAssets.locate(relativePaths, in: assetsDirectories) else { return nil }
        do {
            let data = try Data(contentsOf: candidate)
            Self.logDetail("Using shared asset '\(candidate.path)'")
            return data
        } catch {
            OWELog.error(.scene, "Could not read shared asset \(candidate.path): \(error)")
            return nil
        }
    }

    private func loadTexture(named name: String, materialDir: String, wallpaperDir: URL) -> NSImage? {
        // Build candidate .tex paths: relative to material dir, then relative to materials/ root
        let materialDirPath = (materialDir as NSString).deletingLastPathComponent
        var texPaths = [String]()
        if !materialDirPath.isEmpty {
            texPaths.append("\(materialDirPath)/\(name).tex")
        }
        // Also try materials/{name}.tex for textures with embedded paths (e.g. "workshop/xxx/foo")
        let materialsRoot = materialDirPath.split(separator: "/").first.map(String.init) ?? "materials"
        let rootPath = "\(materialsRoot)/\(name).tex"
        if !texPaths.contains(rootPath) {
            texPaths.append(rootPath)
        }
        texPaths.append("\(name).tex")

        for texPath in texPaths {
            // Try .tex from PKG
            if let texData = assetData(named: texPath, wallpaperDir: wallpaperDir) {
                Self.logDetail("  TEX from PKG '\(texPath)' size=\(texData.count)")
                let texParser = TEXParser(data: Data(texData))  // Copy to reset indices
                if let image = texParser.extractImage() {
                    return image
                }
                Self.log("  TEXParser.extractImage() returned nil for '\(texPath)'")
            }
        }

        // Try common image formats directly
        for ext in ["png", "jpg", "jpeg", "gif"] {
            let imgPath = materialDirPath.isEmpty ? "\(name).\(ext)" : "\(materialDirPath)/\(name).\(ext)"
            if let imgData = assetData(named: imgPath, wallpaperDir: wallpaperDir) {
                if let image = NSImage(data: imgData) { return image }
            }
        }

        Self.log("  No texture found for '\(name)'")
        return nil
    }

    /// Generate simple procedural textures for built-in particle names
    private func generateProceduralTexture(named name: String) -> NSImage? {
        let size: CGFloat = 32

        switch name {
        case "particle/drop":
            // Elongated raindrop: bright center, soft edges
            return generateRadialGradient(size: CGSize(width: 4, height: 16), color: .white)

        case _ where name.contains("halo"):
            // Soft circular glow
            return generateRadialGradient(size: CGSize(width: size, height: size), color: .white)

        default:
            // Generic soft circle
            return generateRadialGradient(size: CGSize(width: size, height: size), color: .white)
        }
    }

    private func generateRadialGradient(size: CGSize, color: NSColor) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()

        let ctx = NSGraphicsContext.current!.cgContext
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        // Convert to RGB color space to guarantee 4 components (r, g, b, a)
        let rgbColor = color.usingColorSpace(.deviceRGB) ?? color
        let r = rgbColor.redComponent
        let g = rgbColor.greenComponent
        let b = rgbColor.blueComponent
        let a = rgbColor.alphaComponent
        let colors = [
            CGColor(colorSpace: colorSpace, components: [r, g, b, a])!,
            CGColor(colorSpace: colorSpace, components: [r, g, b, 0])!
        ] as CFArray
        let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1])!

        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) / 2
        ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                               endCenter: center, endRadius: radius, options: [])

        image.unlockFocus()
        return image
    }

}
