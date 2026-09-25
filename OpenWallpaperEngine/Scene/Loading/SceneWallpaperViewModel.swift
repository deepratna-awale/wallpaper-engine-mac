//
//  SceneWallpaperViewModel.swift
//  Open Wallpaper Engine
//
//  Loads Wallpaper Engine scene wallpapers and builds the content the Metal renderer draws.
//  Follows the same ViewModel pattern as VideoWallpaperViewModel.
//

import SwiftUI
import CoreText

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
    private var loadedWallpaperDirectory: URL?
    private var assetDataCache: [String: Data] = [:]

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
    private static func overrideSignature(forWallpaperPath path: String) -> String {
        let values = UserDefaults.standard.dictionary(forKey: "SceneUserProperties.\(path)") as? [String: String] ?? [:]
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

    func sceneAudioURL() -> URL? {
        let extensions = Set(["mp3", "ogg", "wav", "m4a", "flac"])
        let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "Open Wallpaper Engine/SceneAudio")
        if let entry = pkgParser?.fileList.first(where: { extensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }),
           let data = pkgParser?.extractFile(named: entry) {
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            let destination = cacheDirectory.appending(path: "\(entry.hashValue).\(URL(fileURLWithPath: entry).pathExtension)")
            if !FileManager.default.fileExists(atPath: destination.path) {
                try? data.write(to: destination, options: .atomic)
            }
            return destination
        }
        if let directory = loadedWallpaperDirectory,
           let url = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?
            .compactMap({ $0 as? URL })
            .first(where: { extensions.contains($0.pathExtension.lowercased()) }) {
            return url
        }
        if let root = WallpaperEngineAssets.directory {
            return FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
                .compactMap({ $0 as? URL })
                .first(where: { extensions.contains($0.pathExtension.lowercased()) })
        }
        return nil
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
        }
        // Symlink in any already-installed cross-workshop-item asset dependencies before parsing,
        // so paths like "effects/workshop/<id>/name/effect.json" resolve as ordinary loose files.
        WorkshopDependencyResolver.linkInstalledDependencies(for: wallpaper)
        let dir = wallpaper.wallpaperDirectory
        let sceneFile = wallpaper.project.file  // e.g. "scene.json" or "gifscene.json"

        // Derive PKG name from scene file: "scene.json" → "scene.pkg", "gifscene.json" → "gifscene.pkg"
        let pkgName = (sceneFile as NSString).deletingPathExtension + ".pkg"
        let pkgURL = dir.appending(path: pkgName)
        let looseSceneURL = dir.appending(path: sceneFile)

        var scene: WEScene?
        var servedFromCache = false

        let hasPackage = FileManager.default.fileExists(atPath: pkgURL.path(percentEncoded: false))
        let sourceURL = hasPackage ? pkgURL : looseSceneURL
        let signature = Self.sourceSignature(for: sourceURL)
            + "|" + Self.overrideSignature(forWallpaperPath: dir.path)

        if let cached = Self.cachedParse(for: dir, signature: signature) {
            self.pkgParser = cached.parser
            scene = cached.scene
            servedFromCache = true
        } else if hasPackage {
            do {
                let parser = try PKGParser(url: pkgURL)
                self.pkgParser = parser
                if let data = parser.extractFile(named: sceneFile) {
                    scene = try decodeScene(data, wallpaperPath: dir.path)
                }
            } catch {
                Self.log("Failed to parse PKG: \(error)")
            }
        } else if FileManager.default.fileExists(atPath: looseSceneURL.path(percentEncoded: false)) {
            // Loose files (no .pkg)
            self.pkgParser = nil
            do {
                let data = try Data(contentsOf: looseSceneURL)
                scene = try decodeScene(data, wallpaperPath: dir.path)
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
        Self.storeParse(ParsedScene(parser: pkgParser, scene: scene, signature: signature), for: dir)

        if prepareDefaults {
            prepareSceneUserPropertyDefaults(for: wallpaper, scene: scene)
        }
        Self.log("Scene loaded: \(scene.objects.count) objects from \(sceneFile) [\(servedFromCache ? "shared parse" : "parsed")]")
        if !hasPackage {
            WallpaperPackageConverter.markVerified(wallpaperDirectory: dir, objectCount: scene.objects.count)
        }
        loadedScene = scene
        loadedWallpaperDirectory = dir
        bumpRevision()
    }

    private func decodeScene(_ data: Data, wallpaperPath: String) throws -> WEScene {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var objects = root["objects"] as? [[String: Any]] else {
            return try JSONDecoder().decode(WEScene.self, from: data)
        }
            let values = UserDefaults.standard.dictionary(forKey: "SceneUserProperties.\(wallpaperPath)") as? [String: String] ?? [:]
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
        return try JSONDecoder().decode(WEScene.self, from: resolvedData)
    }

    private func prepareSceneUserPropertyDefaults(for wallpaper: WEWallpaper, scene: WEScene) {
        guard wallpaper.project.type.caseInsensitiveCompare("scene") == .orderedSame else { return }
        let properties = Self.declaredUserProperties(in: wallpaper.wallpaperDirectory)
        let key = "SceneUserProperties.\(wallpaper.wallpaperDirectory.path)"
        let explicitKey = "SceneUserPropertiesExplicit.\(wallpaper.wallpaperDirectory.path)"
        let defaults = UserDefaults.standard
        var values = defaults.bool(forKey: explicitKey)
            ? defaults.dictionary(forKey: key) as? [String: String] ?? [:]
            : [:]
        for (name, property) in properties where values[name] == nil {
            if let value = property["value"] {
                values[name] = sceneUserPropertyString(value)
            } else if property["type"] as? String == "combo",
                      let option = (property["options"] as? [[String: Any]])?.first?["value"] {
                values[name] = sceneUserPropertyString(option)
            }
        }
        for object in scene.objects where object.textValue != nil {
            let prefix = "_owe_text_\(object.id ?? -1)_"
            if values[prefix + "font"] == nil, let font = object.font {
                values[prefix + "font"] = font
            }
            if values[prefix + "size"] == nil, let pointSize = object.pointsize {
                values[prefix + "size"] = String(pointSize)
            }
        }
        let conditionalImages = scene.objects.filter { $0.image != nil && $0.visibleUserProperty != nil }
        let hasSelectedVariant = conditionalImages.contains { object in
            guard let property = object.visibleUserProperty, let selectedValue = values[property] else { return false }
            if let condition = object.visibleCondition {
                return normalizeVariant(condition) == normalizeVariant(selectedValue)
            }
            return selectedValue.caseInsensitiveCompare("true") == .orderedSame || selectedValue == "1"
        }
        if !conditionalImages.isEmpty, !hasSelectedVariant,
           let fallback = conditionalImages.first(where: { $0.visible == true }) ?? conditionalImages.first,
           let property = fallback.visibleUserProperty {
            values[property] = fallback.visibleCondition ?? "true"
        }
        defaults.set(values, forKey: key)
        AudioReactiveScriptEngine.shared.setUserProperties(values, wallpaper: wallpaper.wallpaperDirectory.path,
                                                           replacing: true)
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
        guard let scene = loadedScene, let wallpaperDir = loadedWallpaperDirectory else { return nil }
        let sceneSize = metalSceneSize(for: scene)
        let sceneScript = loadSceneScript(scene.script, wallpaperDir: wallpaperDir)
        let visibility = resolvedVisibility(for: scene)
        var objectsByID: [Int: WESceneObject] = [:]
        for (index, object) in scene.objects.enumerated() {
            objectsByID[object.id ?? index] = object
        }
        // WE draws objects in scene.json order; both lists carry that index so the renderer can interleave them.
        let layers: [SceneMetalLayer] = scene.objects.enumerated().compactMap { index, object in
            guard visibility[String(object.id ?? -1)] ?? false else { return nil }
            if object.textValue != nil,
                    userProperty("_owe_text_\(object.id ?? -1)_enabled") == "false" {
                return nil
            }
            var layer = buildMetalLayer(object, wallpaperDir: wallpaperDir, sceneSize: sceneSize, objectsByID: objectsByID)
                ?? buildMetalTextLayer(object, wallpaperDir: wallpaperDir, sceneSize: sceneSize, objectsByID: objectsByID)
                ?? buildShapeLayer(object, wallpaperDir: wallpaperDir, sceneSize: sceneSize, objectsByID: objectsByID)
            layer?.order = index
            return layer
        }
        let particleSystems: [SceneMetalParticleSystem] = scene.objects.enumerated().compactMap { index, object in
            guard visibility[String(object.id ?? -1)] ?? false else { return nil }
            var system = buildMetalParticleSystem(object, wallpaperDir: wallpaperDir,
                                                  sceneSize: sceneSize, objectsByID: objectsByID)
            system?.order = index
            return system
        }
        if !layers.isEmpty || !particleSystems.isEmpty {
            let content = SceneMetalContent(size: sceneSize, layers: layers, particleSystems: particleSystems,
                                            sceneScript: sceneScript, bloom: bloomSettings(for: scene.general),
                                            wallpaperKey: propertyStoreKey)
            cachedContent = content
            cachedContentRevision = metalRevision
            return content
        }
        guard let preview = loadPreviewImage(wallpaperDir: wallpaperDir) else { return nil }
        return SceneMetalContent(size: sceneSize, layers: [SceneMetalLayer(id: "preview", name: "preview", source: .image(preview),
            position: sceneSize / 2, size: sceneSize, scale: SIMD2<Float>(repeating: 1), scaleScript: nil, scaleAnimation: nil,
            opacity: 1, opacityScript: nil, opacityAnimation: nil,
            brightness: 1, brightnessScript: nil, color: SIMD4<Float>(repeating: 1), colorScript: nil,
            text: nil,
            parallaxDepth: .zero, perspective: false,
            positionScript: nil, positionScriptProperties: [:], positionAnimation: nil, sizeScript: nil, sizeAnimation: nil,
            rotation: 0, rotationScript: nil, rotationAnimation: nil,
                effects: SceneMaterialEffects(brightness: 1, contrast: 1, saturation: 1, bloom: 0, blur: 0,
                                          exposure: 0, gamma: 1, hue: 0, bloomThreshold: 0.7,
                                          transformAngle: 0, transformOffset: .zero, transformScale: SIMD2<Float>(repeating: 1), scripts: [:]),
            )], particleSystems: [], sceneScript: sceneScript,
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
                stream?.musicSyncLevel ?? AudioReactiveScriptEngine.shared.audioLevel
            })

        var layer = SceneMetalLayer(
            id: "video", name: "video", source: .video(stream),
            position: sceneSize / 2, size: sceneSize,
            scale: SIMD2<Float>(repeating: 1), scaleScript: nil, scaleAnimation: nil,
            opacity: 1, opacityScript: nil, opacityAnimation: nil,
            brightness: 1, brightnessScript: nil, color: SIMD4<Float>(repeating: 1), colorScript: nil,
            text: nil, parallaxDepth: .zero, perspective: false,
            positionScript: nil, positionScriptProperties: [:], positionAnimation: nil,
            sizeScript: nil, sizeAnimation: nil,
            rotation: 0, rotationScript: nil, rotationAnimation: nil,
            effects: SceneMaterialEffects(brightness: 1, contrast: 1, saturation: 1, bloom: 0, blur: 0,
                                          exposure: 0, gamma: 1, hue: 0, bloomThreshold: 0.7,
                                          transformAngle: 0, transformOffset: .zero,
                                          transformScale: SIMD2<Float>(repeating: 1), scripts: [:]))
        layer.musicSync = musicSync
        return SceneMetalContent(size: sceneSize, layers: [layer], particleSystems: [], sceneScript: nil,
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

    func loadSceneScript(_ value: String?, wallpaperDir: URL) -> String? {
        let candidates: [String] = value.map { [$0] } ?? ["script.js", "scene.js", "scenescript.js"]
        for candidate in candidates {
            if candidate.contains("\n") || candidate.contains("function ") || candidate.contains("export ") {
                return candidate
            }
            if let data = pkgParser?.extractFile(named: candidate), let script = String(data: data, encoding: .utf8) {
                return script
            }
            let url = wallpaperDir.appending(path: candidate)
            if let data = try? Data(contentsOf: url), let script = String(data: data, encoding: .utf8) {
                return script
            }
        }
        return nil
    }

    private func bloomSettings(for general: WESceneGeneral) -> SceneBloomSettings {
        let tint = (general.bloomtint ?? "1 1 1").parseVector3()
        return SceneBloomSettings(enabled: general.bloom ?? false,
                                  strength: Float(general.bloomstrength ?? 1),
                                  threshold: Float(general.bloomthreshold ?? 0.7),
                                  tint: SIMD3<Float>(Float(tint.0), Float(tint.1), Float(tint.2)))
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

    /// Sums every ancestor's origin (not including the object itself), so parented objects
    /// (e.g. an effect attached to another layer) can be positioned relative to their parent.
    private func ancestorOrigin(for object: WESceneObject, sceneSize: SIMD2<Float>,
                                objectsByID: [Int: WESceneObject]) -> SIMD2<Float> {
        var total = SIMD2<Float>.zero
        var visited = Set<Int>()
        var parentID = object.parent
        while let id = parentID, visited.insert(id).inserted, let parentObject = objectsByID[id] {
            if let origin = parentObject.origin {
                let value = origin.parseVector3()
                total += SIMD2<Float>(Float(value.0), Float(value.1))
            } else if parentObject.parent == nil {
                // A root object without an explicit origin is anchored at the canvas center.
                total += sceneSize / 2
            }
            parentID = parentObject.parent
        }
        return total
    }

    /// An object's own origin (or canvas center if it's a root object without one) plus its ancestor chain.
    private func effectiveOrigin(for object: WESceneObject, sceneSize: SIMD2<Float>,
                                 objectsByID: [Int: WESceneObject]) -> SIMD2<Float> {
        let ownOrigin: SIMD2<Float>
        if let origin = object.origin {
            let value = origin.parseVector3()
            ownOrigin = SIMD2<Float>(Float(value.0), Float(value.1))
        } else if object.parent == nil {
            ownOrigin = sceneSize / 2
        } else {
            ownOrigin = .zero
        }
        return ownOrigin + ancestorOrigin(for: object, sceneSize: sceneSize, objectsByID: objectsByID)
    }

    private func buildMetalLayer(_ object: WESceneObject, wallpaperDir: URL, sceneSize: SIMD2<Float>,
                                 objectsByID: [Int: WESceneObject]) -> SceneMetalLayer? {
        guard let imagePath = object.image,
              let model: WEModel = loadJSON(path: imagePath, wallpaperDir: wallpaperDir),
              let materialPath = model.material,
              let material: WEMaterial = loadJSON(path: materialPath, wallpaperDir: wallpaperDir) else {
            return nil
        }
        if model.solidlayer == true {
            return buildSolidLayer(object, material: material, wallpaperDir: wallpaperDir,
                                   sceneSize: sceneSize, objectsByID: objectsByID)
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
            switch source {
            case let .image(image): size = SIMD2<Float>(Float(image.size.width), Float(image.size.height))
            case let .dxt(texture): size = SIMD2<Float>(Float(texture.width), Float(texture.height))
            case let .animated(animation):
                guard let image = animation.images.first else { return nil }
                size = SIMD2<Float>(Float(image.size.width), Float(image.size.height))
            case let .video(stream): size = stream.frameSize
            }
        }
        let position: SIMD2<Float> = model.fullscreen == true
            ? sceneSize / 2
            : effectiveOrigin(for: object, sceneSize: sceneSize, objectsByID: objectsByID)
        let rotation = Float(object.angles?.parseVector3().2 ?? 0)
        let staticScale = object.scale?.parseVector3() ?? (1, 1, 1)
        let objectColor = object.color?.parseVector3() ?? (1, 1, 1)
        let parallaxValue = object.parallaxDepth?.parseVector3() ?? (0, 0, 0)
        let effects = materialEffects(material.passes?.first)
        let effectPlans = buildEffectPlans(object.effects ?? [], objectID: object.id ?? -1, wallpaperDir: wallpaperDir)
        var layer = SceneMetalLayer(id: String(object.id ?? -1), name: object.name ?? String(object.id ?? -1), source: source, position: position, size: size,
                       scale: SIMD2<Float>(Float(staticScale.0), Float(staticScale.1)),
                       scaleScript: object.scaleScript, scaleAnimation: object.scaleAnimation,
                       opacity: Float(object.alpha ?? 1), opacityScript: object.alphaScript,
                       opacityAnimation: object.alphaAnimation,
                       brightness: Float(object.brightness ?? 1), brightnessScript: object.brightnessScript,
                       color: SIMD4<Float>(Float(objectColor.0), Float(objectColor.1), Float(objectColor.2), 1), colorScript: object.colorScript,
                       text: nil,
                       parallaxDepth: SIMD3<Float>(Float(parallaxValue.0), Float(parallaxValue.1), Float(parallaxValue.2)),
                       perspective: object.perspective ?? false,
                       positionScript: object.originScript, positionScriptProperties: object.originScriptProperties, positionAnimation: object.originAnimation,
                       sizeScript: object.sizeScript, sizeAnimation: nil,
                               rotation: rotation, rotationScript: object.anglesScript,
                               rotationAnimation: object.anglesAnimation, effects: effects)
        layer.weEffects = effectPlans.plans
        layer.sceneInput = sceneInput
        // A layer whose image is the scene only exists to run effects on it; WE skips it without any.
        if sceneInput, effectPlans.plans.isEmpty { return nil }
        return layer
    }

    /// `models/util/solidlayer*.json`: WE's `flat` shader fills the quad with the object's `color`.
    /// The colour is baked into a generated texture so authored effects see the coloured image, as
    /// they do in WE; `alpha` stays on the layer and is applied when the quad is drawn.
    private func buildSolidLayer(_ object: WESceneObject, material: WEMaterial, wallpaperDir: URL,
                                 sceneSize: SIMD2<Float>, objectsByID: [Int: WESceneObject]) -> SceneMetalLayer {
        let authoredSize = object.size.map { value -> SIMD2<Float> in
            let parsed = value.parseVector2()
            return SIMD2<Float>(Float(parsed.0), Float(parsed.1))
        }
        let size = authoredSize.flatMap { $0.x > 0 && $0.y > 0 ? $0 : nil } ?? sceneSize
        let color = object.color?.parseVector3() ?? (1, 1, 1)
        let staticScale = object.scale?.parseVector3() ?? (1, 1, 1)
        let parallaxValue = object.parallaxDepth?.parseVector3() ?? (0, 0, 0)
        var layer = SceneMetalLayer(id: String(object.id ?? -1), name: object.name ?? String(object.id ?? -1),
                       source: .image(Self.solidImage(red: color.0, green: color.1, blue: color.2)),
                       position: effectiveOrigin(for: object, sceneSize: sceneSize, objectsByID: objectsByID),
                       size: size,
                       scale: SIMD2<Float>(Float(staticScale.0), Float(staticScale.1)),
                       scaleScript: object.scaleScript, scaleAnimation: object.scaleAnimation,
                       opacity: Float(object.alpha ?? 1), opacityScript: object.alphaScript,
                       opacityAnimation: object.alphaAnimation,
                       brightness: Float(object.brightness ?? 1), brightnessScript: object.brightnessScript,
                       color: SIMD4<Float>(repeating: 1), colorScript: object.colorScript,
                       text: nil,
                       parallaxDepth: SIMD3<Float>(Float(parallaxValue.0), Float(parallaxValue.1), Float(parallaxValue.2)),
                       perspective: object.perspective ?? false,
                       positionScript: object.originScript, positionScriptProperties: object.originScriptProperties,
                       positionAnimation: object.originAnimation,
                       sizeScript: object.sizeScript, sizeAnimation: object.sizeAnimation,
                       rotation: Float(object.angles?.parseVector3().2 ?? 0), rotationScript: object.anglesScript,
                       rotationAnimation: object.anglesAnimation, effects: materialEffects(material.passes?.first))
        layer.weEffects = buildEffectPlans(object.effects ?? [], objectID: object.id ?? -1, wallpaperDir: wallpaperDir).plans
        return layer
    }

    /// A 1x1 opaque image of one colour; the quad stretches it to the layer's size.
    static func solidImage(red: Double, green: Double, blue: Double) -> NSImage {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor(srgbRed: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()
        return image
    }

    private func buildMetalTextLayer(_ object: WESceneObject, wallpaperDir: URL, sceneSize: SIMD2<Float>,
                                     objectsByID: [Int: WESceneObject]) -> SceneMetalLayer? {
        guard let text = object.textValue, let sizeString = object.size else { return nil }
        let sizeValue = sizeString.parseVector2()
        let position = effectiveOrigin(for: object, sceneSize: sceneSize, objectsByID: objectsByID)
        let textScale = object.scale?.parseVector3() ?? (1, 1, 1)
        let clock = clockConfiguration(for: object)
        // Padding is authored as "32" or "32 32"; a scalar applies to both axes.
        let paddingParts = (object.padding ?? "0").split(separator: " ").compactMap { Float($0) }
        let padding = SIMD2<Float>(paddingParts.first ?? 0,
                                   paddingParts.count > 1 ? paddingParts[1] : (paddingParts.first ?? 0))
        let textConfig = SceneMetalText(value: text, script: object.textScript, scriptProperties: object.textScriptProperties, font: registerFont(object.font),
                                         pointSize: CGFloat(object.pointsize ?? 24),
                                         horizontalAlignment: object.horizontalalign,
                                         verticalAlignment: object.verticalalign,
                                         padding: padding,
                                         maxWidth: object.limitwidth == true ? object.maxwidth.map(Float.init) : nil,
                                         maxRows: object.limitrows == true ? object.maxrows : nil,
                                         useEllipsis: object.limituseellipsis ?? false,
                                         clock: clock)
        var layer = SceneMetalLayer(id: String(object.id ?? -1), name: object.name ?? String(object.id ?? -1),
                               source: .image(renderText(textConfig, size: CGSize(width: sizeValue.0, height: sizeValue.1))),
                               position: position, size: SIMD2<Float>(Float(sizeValue.0), Float(sizeValue.1)),
                               scale: SIMD2<Float>(Float(textScale.0), Float(textScale.1)), scaleScript: object.scaleScript, scaleAnimation: object.scaleAnimation,
                               opacity: Float(object.alpha ?? 1), opacityScript: object.alphaScript, opacityAnimation: object.alphaAnimation,
                               brightness: 1, brightnessScript: nil, color: SIMD4<Float>(repeating: 1), colorScript: nil,
                               text: textConfig, parallaxDepth: .zero, perspective: false,
                               positionScript: object.originScript,
                               positionScriptProperties: object.originScriptProperties, positionAnimation: object.originAnimation,
                               sizeScript: object.sizeScript, sizeAnimation: object.sizeAnimation,
                               rotation: Float(object.angles?.parseVector3().2 ?? 0), rotationScript: object.anglesScript,
                               rotationAnimation: object.anglesAnimation,
                               effects: SceneMaterialEffects(brightness: 1, contrast: 1, saturation: 1, bloom: 0, blur: 0,
                                                             exposure: 0, gamma: 1, hue: 0, bloomThreshold: 0.7,
                                                             transformAngle: 0, transformOffset: .zero, transformScale: SIMD2<Float>(repeating: 1), scripts: [:]))
        // WE runs a text object's effects on its rasterised text; the renderer rasterises before effects run.
        layer.weEffects = buildEffectPlans(object.effects ?? [], objectID: object.id ?? -1, wallpaperDir: wallpaperDir).plans
        return layer
    }

    private func clockConfiguration(for object: WESceneObject) -> SceneClock? {
        let script = object.textScript ?? ""
        let isCountdown = script.contains("targetDate") && script.contains("getTime")
        let isClock = script.contains("getHours") && script.contains("getMinutes")
            || object.name?.localizedCaseInsensitiveContains("clock") == true
        guard isClock || isCountdown else { return nil }

        func boolValue(_ name: String, fallback: Bool) -> Bool {
            let patterns = [
                #"(?:let|var|const)\s+\#(name)\s*=\s*(true|false)"#,
                #"name:\s*['\"]\#(name)['\"][\s\S]{0,180}?value:\s*(true|false)"#
            ]
            for pattern in patterns {
                guard let expression = try? NSRegularExpression(pattern: pattern),
                      let match = expression.firstMatch(in: script, range: NSRange(script.startIndex..., in: script)),
                      let range = Range(match.range(at: 1), in: script) else { continue }
                return script[range] == "true"
            }
            return fallback
        }

        let delimiterPattern = #"(?:let\s+delimiter\s*=|name:\s*['\"]delimiter['\"][\s\S]{0,180}?value:)\s*['\"]([^'\"]*)['\"]"#
        let delimiter: String
        if let expression = try? NSRegularExpression(pattern: delimiterPattern),
           let match = expression.firstMatch(in: script, range: NSRange(script.startIndex..., in: script)),
           let range = Range(match.range(at: 1), in: script) {
            delimiter = String(script[range])
        } else {
            delimiter = ":"
        }
        let targetPattern = #"name:\s*['\"]date['\"][\s\S]{0,180}?value:\s*['\"]([^'\"]+)['\"]"#
        let targetDate = (try? NSRegularExpression(pattern: targetPattern))
            .flatMap { expression in expression.firstMatch(in: script, range: NSRange(script.startIndex..., in: script)) }
            .flatMap { Range($0.range(at: 1), in: script).map { String(script[$0]) } }
        let kind: SceneClock.Kind = isCountdown ? .countdown : script.contains("getDate") || script.contains("getMonth") ? .date : .time
        return SceneClock(kind: kind, use24HourFormat: boolValue("use24hFormat", fallback: true),
                          showSeconds: boolValue("showSeconds", fallback: false), delimiter: delimiter,
                          targetDate: targetDate, recurring: boolValue("recurring", fallback: true), finalMessage: nil)
    }

    /// Standalone "shape" objects (e.g. a DIRECTDRAW light-shaft quad) have no image/particle of their own;
    /// they exist purely to host a procedural effect, so give them a full-scene solid layer to render onto.
    private func buildShapeLayer(_ object: WESceneObject, wallpaperDir: URL, sceneSize: SIMD2<Float>,
                                 objectsByID: [Int: WESceneObject]) -> SceneMetalLayer? {
        guard object.shape != nil, let effects = object.effects, !effects.isEmpty else { return nil }
        let plans = buildEffectPlans(effects, objectID: object.id ?? -1, wallpaperDir: wallpaperDir).plans
        guard !plans.isEmpty else { return nil }
        let position = effectiveOrigin(for: object, sceneSize: sceneSize, objectsByID: objectsByID)
        let size: SIMD2<Float>
        if let sizeString = object.size {
            let value = sizeString.parseVector2()
            size = SIMD2<Float>(Float(value.0), Float(value.1))
        } else {
            size = sceneSize
        }
        var layer = SceneMetalLayer(id: String(object.id ?? -1), name: object.name ?? String(object.id ?? -1),
                       source: .image(transparentPlaceholderImage), position: position, size: size,
                       scale: SIMD2<Float>(repeating: 1), scaleScript: nil, scaleAnimation: nil,
                       opacity: Float(object.alpha ?? 1), opacityScript: object.alphaScript, opacityAnimation: object.alphaAnimation,
                       brightness: 1, brightnessScript: nil, color: SIMD4<Float>(repeating: 1), colorScript: nil,
                       text: nil, parallaxDepth: .zero, perspective: false,
                       positionScript: object.originScript, positionScriptProperties: object.originScriptProperties, positionAnimation: object.originAnimation,
                       sizeScript: object.sizeScript, sizeAnimation: object.sizeAnimation,
                       rotation: Float(object.angles?.parseVector3().2 ?? 0), rotationScript: object.anglesScript,
                       rotationAnimation: object.anglesAnimation,
                       effects: SceneMaterialEffects(brightness: 1, contrast: 1, saturation: 1, bloom: 0, blur: 0,
                                                     exposure: 0, gamma: 1, hue: 0, bloomThreshold: 0.7,
                                                     transformAngle: 0, transformOffset: .zero, transformScale: SIMD2<Float>(repeating: 1), scripts: [:]))
        layer.weEffects = plans
        return layer
    }

    /// A fully transparent 1x1 placeholder texture for procedural shape layers (e.g. light shafts) that
    /// have no authored image of their own; only the effect's computed alpha should ever become visible.
    private var transparentPlaceholderImage: NSImage {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.white.withAlphaComponent(0).setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()
        return image
    }

    private func renderText(_ text: SceneMetalText, size: CGSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSGraphicsContext.current?.shouldAntialias = true
        NSGraphicsContext.current?.imageInterpolation = .high
        let fontName = text.font ?? "System"
        let font = SceneFontRegistry.font(named: fontName, size: text.pointSize)
            ?? NSFont(name: fontName, size: text.pointSize)
            ?? NSFont.systemFont(ofSize: text.pointSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = text.horizontalAlignment == "left" ? .left : text.horizontalAlignment == "right" ? .right : .center
        // Only `limitwidth` authorises wrapping; otherwise keep one line and shrink to fit.
        if text.maxWidth == nil { paragraph.lineBreakMode = .byClipping }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]
        var attributed = NSAttributedString(string: text.value, attributes: attributes)
        if text.maxWidth == nil {
            let naturalWidth = attributed.size().width
            if naturalWidth > size.width, naturalWidth > 0, size.width > 0,
               let fitted = NSFont(descriptor: font.fontDescriptor,
                                   size: font.pointSize * size.width / naturalWidth) {
                attributes[.font] = fitted
                attributed = NSAttributedString(string: text.value, attributes: attributes)
            }
        }
        let textSize = attributed.size()
        let y: CGFloat
        if text.verticalAlignment == "top" {
            y = size.height - textSize.height
        } else if text.verticalAlignment == "bottom" {
            y = 0
        } else {
            y = (size.height - textSize.height) / 2
        }
        attributed.draw(in: NSRect(x: 0, y: max(0, y), width: size.width, height: textSize.height))
        image.unlockFocus()
        return image
    }

    private func registerFont(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        if let registered = registeredFontNames[path] { return registered }
        guard let data = loadFontData(named: path),
              let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor],
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
        if let assets = WallpaperEngineAssets.directory {
            for candidate in [normalized, (normalized as NSString).lastPathComponent] {
                if let data = try? Data(contentsOf: assets.appending(path: candidate)) {
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
            return ShaderVariantTranslator(compiler: try ProcessShaderCompiler())
        } catch {
            OWELog.error(.shader, "WE shader toolchain unavailable, scene effects are disabled: \(error)")
            return nil
        }
    }()

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
            })
        var plans: [SceneEffectPlan] = []
        var handled = Set<Int>()
        let storeKey = propertyStoreKey
        for (index, effect) in effects.enumerated() {
            let enabled = userProperty(
                sceneAuthoredEffectEnabledKey(objectID: objectID, effectIndex: index)) != "false"
            guard isEffectVisible(effect), enabled else {
                handled.insert(index)
                continue
            }
            do {
                plans.append(try builder.build(effect, overrides: { key in
                    AudioReactiveScriptEngine.shared.userPropertyString(
                        sceneAuthoredEffectOverrideKey(objectID: objectID, effectIndex: index, parameter: key),
                        wallpaper: storeKey)
                }))
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
        AudioReactiveScriptEngine.shared.userPropertyString(name, wallpaper: propertyStoreKey)
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
            if let name = object.name?.lowercased(), name.contains("clock") || name.contains("date") || name.contains("day") {
                return object.visible != false
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

    private func resolvedVisibility(for scene: WEScene) -> [String: Bool] {
        var visibility: [String: Bool] = [:]
        var objectsByID: [Int: WESceneObject] = [:]
        for (index, object) in scene.objects.enumerated() {
            let id = object.id ?? index
            objectsByID[id] = object
            visibility[String(id)] = isObjectVisible(object)
        }
        visibility = AudioReactiveScriptEngine.shared.resolveLayerVisibility(scene.objects, initial: visibility,
                                                                             wallpaper: propertyStoreKey)

        func isVisibleWithParents(_ object: WESceneObject, visited: Set<Int> = []) -> Bool {
            let id = object.id ?? -1
            guard visibility[String(id)] ?? false else { return false }
            guard let parent = object.parent, !visited.contains(parent), let parentObject = objectsByID[parent] else { return true }
            return isVisibleWithParents(parentObject, visited: visited.union([id]))
        }
        for object in scene.objects {
            visibility[String(object.id ?? -1)] = isVisibleWithParents(object)
        }
        return visibility
    }

    private func isEffectVisible(_ effect: WEObjectEffect) -> Bool {
        if let property = effect.visibleUserProperty {
            guard let selectedValue = userProperty(property) else { return false }
            if let condition = effect.visibleCondition {
                return normalizeVariant(condition) == normalizeVariant(selectedValue)
            }
            return selectedValue.caseInsensitiveCompare("true") == .orderedSame || selectedValue == "1"
        }
        return effect.visible != false
    }

    private func normalizeVariant(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private func materialEffects(_ pass: WEMaterialPass?) -> SceneMaterialEffects {
        let constants = pass?.constants ?? [:]
        var scripts: [String: String] = [:]
        func value(_ names: [String], default fallback: Float) -> Float {
            for (key, constant) in constants where names.contains(key.lowercased()) {
            if let script = constant.script { scripts[names[0]] = script }
                return Float(constant.value ?? Double(fallback))
            }
            return fallback
        }
        let shader = pass?.shader?.lowercased() ?? ""
        return SceneMaterialEffects(
            brightness: value(["brightness", "intensity", "overbright", "gain"], default: 1),
            contrast: value(["contrast", "contrastamount"], default: 1),
            saturation: value(["saturation", "saturationamount"], default: 1),
            bloom: value(["bloom", "bloomstrength", "glow", "strength"], default: shader.contains("bloom") ? 1 : 0),
            blur: value(["blur", "bluramount", "blurradius", "radius", "sigma"], default: shader.contains("blur") ? 1 : 0),
            exposure: value(["exposure", "exposurevalue"], default: 0),
            gamma: value(["gamma", "gammavalue"], default: 1),
            hue: value(["hue", "huerotation"], default: 0),
            bloomThreshold: value(["bloomthreshold", "threshold", "glowthreshold"], default: 0.7),
            transformAngle: value(["angle", "rotation"], default: 0),
            transformOffset: SIMD2<Float>(value(["offsetx", "xoffset"], default: 0), value(["offsety", "yoffset"], default: 0)),
            transformScale: SIMD2<Float>(value(["scalex", "xscale"], default: 1), value(["scaley", "yscale"], default: 1)),
            scripts: scripts
        )
    }

    private func loadMetalTexture(named name: String, materialDir: String, wallpaperDir: URL) -> SceneMetalTextureSource? {
        let cacheKey = "\(materialDir)|\(name)"
        if let cached = cachedTexture(cacheKey) { return cached }
        OWEFrameMetrics.countTextureDecode()
        let signpost = OWESignpost.begin(OWESignpost.scene, "decodeTexture")
        defer { signpost.end() }

        if name.hasPrefix("_rt") || name.hasPrefix("rt/") {
            return cacheTexture(.image(transparentPlaceholderImage), for: cacheKey)
        }

        let materialDirPath = (materialDir as NSString).deletingLastPathComponent
        let root = materialDirPath.split(separator: "/").first.map(String.init) ?? "materials"
        let paths = Array(Set(["\(materialDirPath)/\(name).tex", "\(root)/\(name).tex",
                       "materials/\(name).tex", "\(name).tex"]))
        for path in paths {
            let data = assetData(named: path, wallpaperDir: wallpaperDir)
            guard let data else { continue }
            let parser = TEXParser(data: data)
            if let animation = parser.extractAnimatedImages() {
                return cacheTexture(.animated(animation), for: cacheKey)
            }
            if let texture = parser.extractCompressedTexture() {
                return cacheTexture(.dxt(texture), for: cacheKey)
            }
            if let image = parser.extractImage() {
                return cacheTexture(.image(image), for: cacheKey)
            }
        }
        guard let image = loadTexture(named: name, materialDir: materialDir, wallpaperDir: wallpaperDir) else { return nil }
        return cacheTexture(.image(image), for: cacheKey)
    }

    private func buildMetalParticleSystem(_ object: WESceneObject, wallpaperDir: URL, sceneSize: SIMD2<Float>,
                                          objectsByID: [Int: WESceneObject]) -> SceneMetalParticleSystem? {
        guard let particlePath = object.particle,
              let particleSystem: WEParticleSystem = loadJSON(path: particlePath, wallpaperDir: wallpaperDir),
              let materialPath = particleSystem.material,
              let material: WEMaterial = loadJSON(path: materialPath, wallpaperDir: wallpaperDir),
              let textureName = material.passes?.first?.textures?.first else { return nil }
        let source = loadMetalTexture(named: textureName, materialDir: materialPath, wallpaperDir: wallpaperDir)
            ?? generateProceduralTexture(named: textureName).map(SceneMetalTextureSource.image)
        guard let source else { return nil }
        let spriteSheet = loadSpriteSheet(named: textureName, materialDir: materialPath,
                          wallpaperDir: wallpaperDir, source: source)

        let emitter = particleSystem.emitter?.first
        let isSnowParticle = object.name?.localizedCaseInsensitiveContains("snow") == true
        let objectScale = object.scale?.parseVector3() ?? (1, 1, 1)
        let origin = effectiveOrigin(for: object, sceneSize: sceneSize, objectsByID: objectsByID)
        let rate = Float((emitter?.rate ?? 100) * (object.instanceoverride?.rate?.value ?? 1))
        let rateScript = object.instanceoverride?.rate?.script ?? emitter?.$rate.script
        let distance = emitter?.distancemax?.vectorValue ?? (0, 0, 0)
        let presetScale = particlePath.localizedCaseInsensitiveContains("4k") ? sceneSize.y / 2160 : 1
        let spawnExtent = SIMD2<Float>(abs(Float(distance.0 * objectScale.0)) * presetScale,
                           abs(Float(distance.1 * objectScale.1)) * presetScale)
        var lifetime: ClosedRange<Float> = 1...1
        var size: ClosedRange<Float> = Float(object.instanceoverride?.size ?? 1) * 20...Float(object.instanceoverride?.size ?? 1) * 20
        var minimumVelocity = SIMD2<Float>.zero
        var maximumVelocity = SIMD2<Float>.zero
        var alpha: ClosedRange<Float> = 1...1
        var minimumColor = SIMD4<Float>(repeating: 1)
        var maximumColor = SIMD4<Float>(repeating: 1)
        var minimumRotation: Float = 0
        var maximumRotation: Float = 0
        var minimumAngularVelocity: Float = 0
        var maximumAngularVelocity: Float = 0
        var positionOffsetMinimum = SIMD2<Float>.zero
        var positionOffsetMaximum = SIMD2<Float>.zero
        var remapAlpha: ParticleRemap?
        var nearControlPointReduction: ParticleDistanceReduction?
        var maintainControlPointDistance: ParticleDistanceConstraint?
        var sequenceSpan: ParticleSequenceSpan?
        var sequenceRing: ParticleSequenceRing?
        var initialRemap: ParticleInitialRemap?
        var maintainSequenceDistance = false
        let controlPoints: [ParticleControlPoint] = (particleSystem.controlpoint ?? []).map { controlPoint in
            let offset = (controlPoint.offset ?? "0 0 0").parseVector3()
            return ParticleControlPoint(id: controlPoint.id ?? 0,
                                        offset: SIMD2<Float>(Float(offset.0), -Float(offset.1)) * presetScale,
                                        locksToCursor: controlPoint.locktopointer == true
                                            || ((controlPoint.flags ?? 0) & 1) != 0)
        }
        let particleRenderer = particleSystem.renderer?.first
        for initializer in particleSystem.initializer ?? [] {
            switch initializer.name {
            case "lifetimerandom":
                let lifetimeMin = Float(initializer.min?.doubleValue ?? 1)
                let lifetimeMax = Float(initializer.max?.doubleValue ?? 1)
                lifetime = min(lifetimeMin, lifetimeMax)...max(lifetimeMin, lifetimeMax)
            case "sizerandom":
                let multiplier = Float(object.instanceoverride?.size ?? 1)
                let sizeMin = Float(initializer.min?.doubleValue ?? 20) * multiplier
                let sizeMax = Float(initializer.max?.doubleValue ?? 20) * multiplier
                size = min(sizeMin, sizeMax)...max(sizeMin, sizeMax)
            case "velocityrandom":
                let minimum = initializer.min?.vectorValue ?? (0, 0, 0)
                let maximum = initializer.max?.vectorValue ?? (0, 0, 0)
                minimumVelocity = SIMD2<Float>(Float(minimum.0), Float(minimum.1))
                maximumVelocity = SIMD2<Float>(Float(maximum.0), Float(maximum.1))
            case "turbulentvelocityrandom":
                let minimum = initializer.min?.vectorValue ?? (0, 0, 0)
                let maximum = initializer.max?.vectorValue ?? (0, 0, 0)
                minimumVelocity += SIMD2<Float>(Float(minimum.0), Float(minimum.1))
                maximumVelocity += SIMD2<Float>(Float(maximum.0), Float(maximum.1))
            case "positionoffsetrandom":
                let minimum = initializer.min?.vectorValue ?? (0, 0, 0)
                let maximum = initializer.max?.vectorValue ?? (0, 0, 0)
                positionOffsetMinimum = SIMD2<Float>(Float(minimum.0), -Float(minimum.1))
                positionOffsetMaximum = SIMD2<Float>(Float(maximum.0), -Float(maximum.1))
            case "hsvcolorrandom":
                minimumColor = normalizedParticleColor(initializer.min?.vectorValue ?? (1, 1, 1))
                maximumColor = normalizedParticleColor(initializer.max?.vectorValue ?? (1, 1, 1))
            case "alpharandom":
                let alphaMin = Float(initializer.min?.doubleValue ?? 1)
                let alphaMax = Float(initializer.max?.doubleValue ?? 1)
                alpha = min(alphaMin, alphaMax)...max(alphaMin, alphaMax)
            case "colorrandom":
                if !isSnowParticle {
                    minimumColor = normalizedParticleColor(initializer.min?.vectorValue ?? (1, 1, 1))
                    maximumColor = normalizedParticleColor(initializer.max?.vectorValue ?? (1, 1, 1))
                }
            case "rotationrandom":
                minimumRotation = Float(initializer.min?.vectorValue.2 ?? 0)
                maximumRotation = Float(initializer.max?.vectorValue.2 ?? 0)
            case "angularvelocityrandom":
                minimumAngularVelocity = Float(initializer.min?.vectorValue.2 ?? 0)
                maximumAngularVelocity = Float(initializer.max?.vectorValue.2 ?? 0)
            case "mapsequencebetweencontrolpoints":
                sequenceSpan = ParticleSequenceSpan(startControlPoint: initializer.controlpoint0 ?? 0,
                                                    endControlPoint: initializer.controlpoint1 ?? 1,
                                                    count: max(2, Int(initializer.count ?? 2)),
                                                    arcAmount: Float(initializer.arcamount ?? 0),
                                                    mirrored: initializer.limitbehavior?.lowercased() == "mirror")
            case "mapsequencearoundcontrolpoint":
                let axis = (initializer.axis ?? "0 1 0").parseVector3()
                let bounds = (initializer.bounds ?? "0 1").split(separator: " ").compactMap { Float($0) }
                let speedMinimum = initializer.speedmin?.vectorValue ?? (0, 0, 0)
                let speedMaximum = initializer.speedmax?.vectorValue ?? (0, 0, 0)
                sequenceRing = ParticleSequenceRing(turns: Float(initializer.count ?? 1),
                                                    axis: SIMD2<Float>(Float(axis.0), -Float(axis.1)),
                                                    bounds: (bounds.first ?? 0)...max(bounds.first ?? 0, bounds.count > 1 ? bounds[1] : 1),
                                                    minimumSpeed: SIMD2<Float>(Float(speedMinimum.0), -Float(speedMinimum.1)),
                                                    maximumSpeed: SIMD2<Float>(Float(speedMaximum.0), -Float(speedMaximum.1)))
            case "remapinitialvalue":
                // Presets leave `output` implicit; size is the property that visibly tapers a strand
                // towards its anchor, and velocity damping is already covered by other operators.
                let output: ParticleInitialRemap.Output
                switch initializer.output?.lowercased() {
                case "alpha": output = .alpha
                case "velocity": output = .velocity
                default: output = .size
                }
                initialRemap = ParticleInitialRemap(controlPoint: initializer.inputcontrolpoint0 ?? 0,
                                                    rangeMinimum: Float(initializer.inputrangemin ?? 0),
                                                    rangeMaximum: Float(initializer.inputrangemax ?? 1) * presetScale,
                                                    multiply: initializer.operation?.lowercased() != "set",
                                                    output: output)
            default: break
            }
        }
        if isSnowParticle {
            minimumColor = SIMD4<Float>(1, 1, 1, 1)
            maximumColor = SIMD4<Float>(1, 1, 1, 1)
        }
        var gravity = SIMD2<Float>.zero
        var drag: Float = 0
        var fadeIn: Float = 0
        var fadeOut: Float = 1
        var dragScript: String?
        var fadeInScript: String?
        var fadeOutScript: String?
        var turbulence: Turbulence?
        var attractor: Attractor?
        var sizeChange: ParticleChange?
        var alphaChange: ParticleChange?
        var colorChange: ParticleColorChange?
        var angularAcceleration: Float = 0
        var maximumSpeed: Float?
        var vortex: ParticleVortex?
        var boids: ParticleBoids?
        var oscillateSize: ParticleOscillation?
        var oscillateAlpha: ParticleOscillation?
        var oscillatePosition: ParticleOscillation?
        let cursorControlPoint = particleSystem.controlpoint?.first(where: {
            $0.locktopointer == true || (($0.flags ?? 0) & 1) != 0
        }).map { controlPoint in
            let offset = (controlPoint.offset ?? "0 0 0").parseVector3()
            return CursorControlPoint(id: controlPoint.id ?? 0,
                                      offset: SIMD2<Float>(Float(offset.0), -Float(offset.1)))
        }
        for `operator` in particleSystem.operator ?? [] {
            switch `operator`.name {
            case "movement":
                let value = (`operator`.gravity ?? "0 0 0").parseVector3()
                gravity = SIMD2<Float>(Float(value.0), Float(value.2 != 0 ? value.2 : value.1))
                drag = Float(`operator`.drag ?? 0)
                dragScript = `operator`.$drag.script
            case "alphafade":
                fadeIn = Float(`operator`.fadeintime ?? 0)
                fadeOut = Float(`operator`.fadeouttime ?? 1)
                fadeInScript = `operator`.$fadeintime.script
                fadeOutScript = `operator`.$fadeouttime.script
            case "sizechange":
                sizeChange = ParticleChange(startTime: Float(`operator`.starttime ?? 0),
                                             endTime: Float(`operator`.endtime ?? 1),
                                             startValue: Float(`operator`.startvalue?.doubleValue ?? 1),
                                             endValue: Float(`operator`.endvalue?.doubleValue ?? 1))
            case "alphachange":
                alphaChange = ParticleChange(startTime: Float(`operator`.starttime ?? 0),
                                              endTime: Float(`operator`.endtime ?? 1),
                                              startValue: Float(`operator`.startvalue?.doubleValue ?? 1),
                                              endValue: Float(`operator`.endvalue?.doubleValue ?? 1))
            case "colorchange":
                let start = `operator`.startvalue?.vectorValue ?? (1, 1, 1)
                let end = `operator`.endvalue?.vectorValue ?? (1, 1, 1)
                colorChange = ParticleColorChange(startTime: Float(`operator`.starttime ?? 0),
                                                  endTime: Float(`operator`.endtime ?? 1),
                                                  startValue: SIMD4<Float>(Float(start.0), Float(start.1), Float(start.2), 1),
                                                  endValue: SIMD4<Float>(Float(end.0), Float(end.1), Float(end.2), 1))
            case "angularmovement":
                angularAcceleration = Float((`operator`.force ?? "0 0 0").parseVector3().2)
            case "capvelocity":
                maximumSpeed = Float(`operator`.maxspeed ?? 0)
            case "vortex", "vortex_v2":
                let axis = (`operator`.axis ?? "0 1 0").parseVector3()
                let axisOrigin = origin + SIMD2<Float>(Float(axis.0), -Float(axis.1))
                vortex = ParticleVortex(origin: axisOrigin,
                                         innerSpeed: Float(`operator`.speedinner ?? 0),
                                         outerSpeed: Float(`operator`.speedouter ?? 0),
                                         innerDistance: Float(`operator`.distanceinner ?? 0),
                                         outerDistance: Float(`operator`.distanceouter ?? 1000))
            case "boids":
                boids = ParticleBoids(alignment: Float(`operator`.alignmentfactor ?? 0),
                                      cohesion: Float(`operator`.cohesionfactor ?? 0),
                                      separation: Float(`operator`.separationfactor ?? 0),
                                      threshold: Float(`operator`.neighborthreshold ?? 150))
            case "oscillatesize":
                oscillateSize = ParticleOscillation(frequency: safeRange(`operator`.frequencymin, `operator`.frequencymax, default: 0),
                                                     scale: safeRange(`operator`.scalemin, `operator`.scalemax, default: 1),
                                                     phase: safeRange(`operator`.phasemin, `operator`.phasemax, default: 0))
            case "oscillatealpha":
                oscillateAlpha = ParticleOscillation(frequency: safeRange(`operator`.frequencymin, `operator`.frequencymax, default: 0),
                                                      scale: safeRange(`operator`.scalemin, `operator`.scalemax, default: 1),
                                                      phase: safeRange(`operator`.phasemin, `operator`.phasemax, default: 0))
            case "oscillateposition":
                oscillatePosition = ParticleOscillation(frequency: safeRange(`operator`.frequencymin, `operator`.frequencymax, default: 0),
                                                         scale: safeRange(`operator`.scalemin, `operator`.scalemax, default: 1),
                                                         phase: safeRange(`operator`.phasemin, `operator`.phasemax, default: 0))
            case "remapvalue":
                if `operator`.output?.lowercased() == "velocity" {
                    let minimum = `operator`.outputrangemin?.vectorValue ?? (0, 0, 0)
                    let maximum = `operator`.outputrangemax?.vectorValue ?? (0, 0, 0)
                    minimumVelocity = SIMD2<Float>(Float(minimum.0), Float(minimum.1)) * presetScale
                    maximumVelocity = SIMD2<Float>(Float(maximum.0), Float(maximum.1)) * presetScale
                } else {
                    remapAlpha = ParticleRemap(scale: Float(`operator`.transforminputscale ?? 1),
                                                outputMinimum: Float(`operator`.outputrangemin?.doubleValue ?? 0),
                                                outputMaximum: Float(`operator`.outputrangemax?.doubleValue ?? 1),
                                                sine: `operator`.transformfunction?.lowercased() == "sine")
                }
            case "reducemovementnearcontrolpoint":
                nearControlPointReduction = ParticleDistanceReduction(origin: origin,
                                                                       innerDistance: Float(`operator`.distanceinner ?? 0),
                                                                       outerDistance: Float(`operator`.distanceouter ?? 100),
                                                                       reduction: Float(`operator`.reductioninner ?? 1))
            case "maintaindistancetocontrolpoint":
                maintainControlPointDistance = ParticleDistanceConstraint(origin: origin,
                                                                          strength: Float(`operator`.variablestrength ?? 1))
            case "maintaindistancebetweencontrolpoints":
                maintainSequenceDistance = true
            case "turbulence":
                let mask = `operator`.mask?.vectorValue ?? (1, 1, 0)
                turbulence = Turbulence(scale: Float(`operator`.scale?.doubleValue ?? 0.005),
                                        speed: Float(`operator`.speedmin ?? 500)...Float(`operator`.speedmax ?? 1000),
                                        timeScale: Float(`operator`.timescale ?? 0.01),
                                        phase: Float(`operator`.phasemin ?? 0),
                                        mask: SIMD2<Float>(Float(mask.0), -Float(mask.1)))
            case "controlpointattract":
                // The operator's own "origin" is a local offset from the emitter, not an absolute scene
                // position; adding the system's own `origin` was previously shadowed by this `let origin`,
                // which pinned every attractor to the canvas corner (0,0) instead of the emitter itself.
                let attractOffset = `operator`.origin?.vectorValue ?? (0, 0, 0)
                attractor = Attractor(origin: origin + SIMD2<Float>(Float(attractOffset.0), -Float(attractOffset.1)),
                                      strength: Float(`operator`.scale?.doubleValue ?? 100),
                                      threshold: Float(`operator`.threshold ?? 1000))
            default: break
            }
        }
        let refractAmount = material.passes?.first?.constants?["ui_editor_properties_refract_amount"]?.value
        let opacityMultiplier = refractAmount.map { max(0.04, min(abs(Float($0)), 1)) } ?? 1
        return SceneMetalParticleSystem(source: source, origin: origin, emissionRate: max(rate, 0),
                emissionRateScript: rateScript,
                                        maximumParticleCount: min(particleSystem.maxcount ?? 1000, 1000),
                                        spawnExtent: spawnExtent, lifetime: lifetime, size: size,
                                        minimumVelocity: minimumVelocity, maximumVelocity: maximumVelocity,
                                        gravity: gravity, drag: drag, dragScript: dragScript, alpha: alpha,
                                        minimumColor: minimumColor, maximumColor: maximumColor,
                                        minimumRotation: minimumRotation, maximumRotation: maximumRotation,
                                        minimumAngularVelocity: minimumAngularVelocity, maximumAngularVelocity: maximumAngularVelocity,
                                        emitterName: emitter?.name ?? "sphererandom",
                                        sizeChange: sizeChange, alphaChange: alphaChange, colorChange: colorChange,
                                        angularAcceleration: angularAcceleration,
                                        maximumSpeed: maximumSpeed, vortex: vortex,
                                        boids: boids,
                                        oscillateSize: oscillateSize, oscillateAlpha: oscillateAlpha,
                                        oscillatePosition: oscillatePosition,
                                        positionOffsetMinimum: positionOffsetMinimum, positionOffsetMaximum: positionOffsetMaximum,
                                        remapAlpha: remapAlpha,
                                        nearControlPointReduction: nearControlPointReduction,
                                        maintainControlPointDistance: maintainControlPointDistance,
                                        controlPoints: controlPoints,
                                        sequenceSpan: sequenceSpan,
                                        sequenceRing: sequenceRing,
                                        initialRemap: initialRemap,
                                        maintainSequenceDistance: maintainSequenceDistance,
                                        rendererName: particleRenderer?.name ?? "sprite",
                                        trailLength: Float(particleRenderer?.maxlength ?? particleRenderer?.length ?? 1),
                                        trailSegments: max(2, particleRenderer?.segments ?? 4),
                                        ropeSubdivision: max(1, particleRenderer?.subdivision ?? 4),
                                        fadeTrailAlpha: particleRenderer?.fadealpha ?? false,
                                        fadeTrailSize: particleRenderer?.fadesize ?? false,
                                        turbulence: turbulence, attractor: attractor,
                                        cursorControlPoint: cursorControlPoint,
                                        emitterControlPoint: emitter?.controlpoint,
                                        spriteSheet: spriteSheet,
                                        animationMode: particleSystem.animationmode ?? "sequence",
                                        sequenceMultiplier: Float(particleSystem.sequencemultiplier ?? 1),
                                        opacityMultiplier: opacityMultiplier,
                                        refractive: refractAmount != nil,
                                        fadeIn: fadeIn, fadeOut: fadeOut,
                                        fadeInScript: fadeInScript, fadeOutScript: fadeOutScript,
                                        blending: material.passes?.first?.blending?.lowercased() ?? "translucent")
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

    private func safeRange(_ min: Double?, _ max: Double?, default defaultValue: Float) -> ClosedRange<Float> {
        let lower = Float(min ?? Double(defaultValue))
        let upper = Float(max ?? Double(defaultValue))
        return Swift.min(lower, upper)...Swift.max(lower, upper)
    }

    private func normalizedParticleColor(_ color: (Double, Double, Double)) -> SIMD4<Float> {
        guard color.0.isFinite, color.1.isFinite, color.2.isFinite,
              max(color.0, color.1, color.2) > 0 else {
            return SIMD4<Float>(1, 1, 1, 1)
        }
        let scale = max(color.0, color.1, color.2) > 1 ? 255.0 : 1.0
        return SIMD4<Float>(Float(color.0 / scale), Float(color.1 / scale), Float(color.2 / scale), 1)
    }

    // MARK: - Asset Loading

    private func loadJSON<T: Decodable>(path: String, wallpaperDir: URL) -> T? {
        guard let original = assetData(named: path, wallpaperDir: wallpaperDir) else { return nil }
        let storageKey = "SceneUserProperties.\(wallpaperDir.path)"
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
        let data = pkgParser?.extractFile(named: path)
            ?? (try? Data(contentsOf: wallpaperDir.appending(path: path)))
            ?? sharedAssetData(named: path)
        if let data { assetDataCache[path] = data }
        return data
    }

    private func sharedAssetData(named path: String) -> Data? {
        guard let assetsDirectory = WallpaperEngineAssets.directory else {
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
        var seenPaths: Set<String> = []
        let candidates = relativePaths
            .map { assetsDirectory.appending(path: $0).standardizedFileURL }
            .filter { seenPaths.insert($0.path).inserted }
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            if let data = try? Data(contentsOf: candidate) {
                Self.logDetail("Using shared asset '\(candidate.path)'")
                return data
            }
        }
        return nil
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
