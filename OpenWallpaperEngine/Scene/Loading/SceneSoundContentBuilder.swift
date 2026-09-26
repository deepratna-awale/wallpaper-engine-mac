import AVFoundation
import CryptoKit

/// Finds and opens a scene's sound files (docs/scenescript-plan.md, sound layers). A file comes
/// from the wallpaper's package (copied once into the app's caches, since AVFoundation reads
/// files), its folder, another Workshop item, or WE's assets, in that order. AVFoundation decodes
/// what WE's SFML decoders read (mp3, Ogg Vorbis, FLAC, WAV) and streams it. A file that can't be
/// found or opened is logged once and left out; a layer with no file left plays nothing.
/// Off the main thread, with the content.
struct SceneSoundContentBuilder {
    var wallpaperDirectory: URL
    /// The file's bytes inside the wallpaper's package, if it has one.
    var packagedData: (String) -> Data?
    var workshopURL: (String) -> URL?
    var workshopData: (String) -> Data?
    var cacheDirectory = Self.defaultCacheDirectory

    static var defaultCacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "Open Wallpaper Engine/SceneAudio")
    }

    func sounds(in objects: [WESceneObject], context: SceneValueContext) -> [SceneSoundContent] {
        objects.compactMap { object in
            guard let sound = object.sound, let id = object.id else { return nil }
            let files = sound.files.compactMap(file)
            return SceneSoundContent(id: id, name: object.name ?? "", sound: sound, files: files,
                                     volume: Self.volume(sound.volume, in: context))
        }
    }

    /// `volume`: its user binding's value, else the literal (a script's value comes from the
    /// runtime), else WE's default 1.
    static func volume(_ raw: SceneRawValue?, in context: SceneValueContext) -> Float {
        guard let raw else { return 1 }
        if let source = raw.userBindingSource { return SceneValueResolver.resolve(source, in: context).float }
        return raw.literalDouble.map(Float.init) ?? 1
    }

    private func file(_ path: String) -> SceneSoundContent.File? {
        guard let url = locate(path) else {
            OWELog.error(.audio, "Sound '\(path)' is in neither the wallpaper, its Workshop items nor WE's assets")
            return nil
        }
        do {
            let audio = try AVAudioFile(forReading: url)
            let rate = audio.processingFormat.sampleRate
            return SceneSoundContent.File(path: path, url: url, duration: rate > 0 ? Double(audio.length) / rate : 0)
        } catch {
            OWELog.error(.audio, "Sound '\(path)' can't be decoded: \(error)")
            return nil
        }
    }

    private func locate(_ path: String) -> URL? {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        if let data = packagedData(path) ?? packagedData(normalized) { return cached(data, entry: normalized) }
        let loose = wallpaperDirectory.appending(path: normalized)
        if FileManager.default.fileExists(atPath: loose.path) { return loose }
        if let url = workshopURL(normalized) { return url }
        if let data = workshopData(normalized) { return cached(data, entry: normalized) }
        return WallpaperEngineAssets.locate([normalized], in: WallpaperEngineAssets.searchDirectories)
    }

    /// A packaged file's copy in the caches, named by the wallpaper and entry so every screen and
    /// launch reuses it.
    private func cached(_ data: Data, entry: String) -> URL? {
        let destination = cacheDirectory.appending(path: Self.cacheName(entry: entry, wallpaperDirectory: wallpaperDirectory))
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
            return destination
        } catch {
            OWELog.error(.audio, "Sound '\(entry)' can't be copied to \(destination.path): \(error)")
            return nil
        }
    }

    /// A packaged entry's cache file name: stable across launches (`hashValue` is seeded per
    /// process), and distinct per wallpaper since entry paths repeat across packages.
    static func cacheName(entry: String, wallpaperDirectory: URL?) -> String {
        let key = "\(wallpaperDirectory?.standardizedFileURL.path ?? "")|\(entry)"
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(digest).\(URL(fileURLWithPath: entry).pathExtension)"
    }
}
