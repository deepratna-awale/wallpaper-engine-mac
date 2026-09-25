//
//  WallpaperViewModel.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/14.
//

import SwiftUI
import AVKit

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Provide Wallpaper Database for WallpaperView and ContentView etc.
@MainActor
class WallpaperViewModel: ObservableObject {
    private let persistsWallpapers: Bool

    @Published var nextCurrentWallpaper: WEWallpaper =
    WEWallpaper(using: .invalid, where: Bundle.main.url(forResource: "WallpaperNotFound", withExtension: "mp4")!) {
        willSet {
            guard confirmApply?(newValue) ?? true else { return }
            if ["web", "application"].contains(newValue.project.type) {
                if let trustedWallpapers = UserDefaults.standard.array(forKey: "TrustedWallpapers") as? [String],
                   trustedWallpapers.contains(newValue.wallpaperDirectory.path(percentEncoded: false)) {
                    self.setWallpaper(newValue, for: selectedScreenIds)
                } else {
                    AppDelegate.shared.contentViewModel.warningUnsafeWallpaperModal(which: newValue)
                }
            } else {
                self.setWallpaper(newValue, for: selectedScreenIds)
            }
        }
    }

    /// Per-screen wallpaper assignments, keyed by CGDirectDisplayID as String.
    @Published var wallpapers: [String: WEWallpaper] = [:] {
        didSet {
            if persistsWallpapers {
                saveWallpapers()
            }
        }
    }

    /// Screens where wallpaper display is enabled.
    @Published var enabledScreens: Set<String> = [] {
        didSet {
            UserDefaults.standard.set(Array(enabledScreens), forKey: "EnabledScreens")
        }
    }

    /// The screen currently selected in the UI for configuration.
    @Published var selectedScreenId: String = ""

    /// Screens selected for the next wallpaper assignment.
    @Published var selectedScreenIds: Set<String> = []

    /// Wallpaper currently inspected in the sidebar or preview window.
    @Published var inspectedWallpaper: WEWallpaper?
    @Published var inspectedWorkshopItem: WorkshopItem?
    @Published var inspectedAuthor: SteamPlayer?
    /// Guards against firing a second Steam request for a lookup already in progress.
    private var inFlightWorkshopId: String?

    @Published var wallpaperPlacement: WallpaperPlacement = .fill {
        didSet {
            UserDefaults.standard.set(wallpaperPlacement.rawValue, forKey: "WallpaperPlacement")
        }
    }

    static let defaultWallpaper = WEWallpaper(using: .invalid, where: Bundle.main.url(forResource: "WallpaperNotFound", withExtension: "mp4")!)

    // MARK: - Recent wallpapers

    private static let maxRecents = 10
    private static let recentsKey = "RecentWallpapers"

    @Published var recentWallpapers: [WEWallpaper] = []

    @Published var playlists: [WallpaperPlaylist] = [] {
        didSet { savePlaylists() }
    }
    @Published var activePlaylistID: UUID? {
        didSet { savePlaylistSettings(); restartPlaylistTimer() }
    }
    @Published var playlistShuffle = false {
        didSet { savePlaylistSettings() }
    }
    @Published var playlistRepeats = true {
        didSet { savePlaylistSettings() }
    }
    @Published var playlistEnabled = false {
        didSet { savePlaylistSettings(); restartPlaylistTimer() }
    }

    private var playlistTimer: Timer?

    /// Holds the playlist still after safe restart stopped a wallpaper; the setting is untouched.
    var isPlaylistSuspended = false {
        didSet { restartPlaylistTimer() }
    }
    /// Asked before a wallpaper is applied; returning false cancels it. Set by `SafeRestart`.
    var confirmApply: ((WEWallpaper) -> Bool)?
    /// Receives wallpaper frame times. Set by `SafeRestart`.
    var renderWatchdog: RenderWatchdog?
    private var playlistIndex = 0

    private func loadRecents() {
        guard let data = UserDefaults.standard.data(forKey: Self.recentsKey),
              let saved = try? JSONDecoder().decode([WEWallpaper].self, from: data) else { return }
        recentWallpapers = saved.filter { $0.project != .invalid }
    }

    private func saveRecents() {
        if let data = try? JSONEncoder().encode(recentWallpapers) {
            UserDefaults.standard.set(data, forKey: Self.recentsKey)
        }
    }

    func addToRecents(_ wallpaper: WEWallpaper) {
        guard wallpaper.project != .invalid else { return }
        recentWallpapers.removeAll { $0.wallpaperDirectory == wallpaper.wallpaperDirectory }
        recentWallpapers.insert(wallpaper, at: 0)
        if recentWallpapers.count > Self.maxRecents {
            recentWallpapers = Array(recentWallpapers.prefix(Self.maxRecents))
        }
        saveRecents()
    }

    // MARK: - Wallpaper access

    /// Convenience: wallpaper for the currently selected screen in the UI.
    var currentWallpaper: WEWallpaper {
        get {
            wallpapers[selectedScreenId] ?? Self.defaultWallpaper
        }
        set {
            setWallpaper(newValue, for: selectedScreenIds)
        }
    }

    var displayedWallpaper: WEWallpaper {
        inspectedWallpaper ?? currentWallpaper
    }

    func inspect(_ wallpaper: WEWallpaper) {
        var wallpaper = wallpaper
        wallpaper.project.applyTaggedContentRating()
        // A tile tap inspects twice (once via selectWallpaper, once from the tile itself). Clearing
        // and refetching on the second call raced the first request, and Steam rejected the
        // duplicate, so the metadata stayed empty until a later visit read it from cache.
        let isSameWallpaper = inspectedWallpaper?.wallpaperDirectory == wallpaper.wallpaperDirectory
        inspectedWallpaper = wallpaper
        if !isSameWallpaper {
            inspectedWorkshopItem = nil
            inspectedAuthor = nil
        }

        let projectWorkshopId = wallpaper.project.workshopid?.rawValue
        let folderWorkshopId = wallpaper.wallpaperDirectory.lastPathComponent
        let workshopId = (projectWorkshopId?.allSatisfy(\.isNumber) == true ? projectWorkshopId : nil)
            ?? (folderWorkshopId.allSatisfy(\.isNumber) ? folderWorkshopId : nil)
        guard let workshopId else { return }
        guard inFlightWorkshopId != workshopId else { return }

        if let cachedItem = WorkshopMetadataStore.shared.item(for: workshopId) {
            inspectedWorkshopItem = cachedItem
            if let creatorId = cachedItem.creatorId,
               let cachedAuthor = SteamPlayerStore.shared.player(for: creatorId) {
                inspectedAuthor = cachedAuthor
                return
            }
        } else if isSameWallpaper, inspectedWorkshopItem != nil {
            return
        }
        inFlightWorkshopId = workshopId
        Task { [weak self] in
            defer { self?.inFlightWorkshopId = nil }
            let fetched = try? await WorkshopAPIService().getItemDetails(workshopIds: [workshopId]).first
            guard let self else { return }
            guard let item = fetched ?? WorkshopMetadataStore.shared.item(for: workshopId) else { return }
            guard self.displayedWallpaper.wallpaperDirectory.lastPathComponent == folderWorkshopId else { return }
            self.inspectedWorkshopItem = item
            if let creatorId = item.creatorId,
               let author = try? await WorkshopAPIService().getPlayerSummary(steamId: creatorId) {
                guard self.displayedWallpaper.wallpaperDirectory.lastPathComponent == folderWorkshopId else { return }
                self.inspectedAuthor = author
            }
        }
    }

    func applyInspectedWallpaper() {
        let wallpaper = promotePreviewIfNeeded(displayedWallpaper)
        inspectedWallpaper = wallpaper
        nextCurrentWallpaper = wallpaper
    }

    func relocateWallpapers(from sourceDirectory: URL, to destinationDirectory: URL) {
        func relocated(_ wallpaper: WEWallpaper) -> WEWallpaper {
            let path = wallpaper.wallpaperDirectory.standardizedFileURL.path
            let sourcePath = sourceDirectory.standardizedFileURL.path + "/"
            guard path.hasPrefix(sourcePath) else { return wallpaper }
            let suffix = String(path.dropFirst(sourcePath.count))
            return WEWallpaper(using: wallpaper.project, where: destinationDirectory.appending(path: suffix))
        }

        wallpapers = wallpapers.mapValues(relocated)
        recentWallpapers = recentWallpapers.map(relocated)
        inspectedWallpaper = inspectedWallpaper.map(relocated)
        saveRecents()
    }

    private func promotePreviewIfNeeded(_ wallpaper: WEWallpaper) -> WEWallpaper {
        let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "Open Wallpaper Engine/WorkshopPreviews/steamapps/workshop/content/431960")
        let source = wallpaper.wallpaperDirectory
        guard source.path.hasPrefix(cacheRoot.path + "/") else { return wallpaper }

        let workshopId = source.lastPathComponent
        let destination = FileManager.default.wallpapersDirectory.appending(path: workshopId)
        do {
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.moveItem(at: source, to: destination)
            }
            DownloadedWallpaperIndex.shared.insert(workshopId)
            return WEWallpaper(using: wallpaper.project, where: destination)
        } catch {
            OWELog.error(.workshop, "Failed to promote Workshop preview: \(error)")
            return wallpaper
        }
    }

    /// Get wallpaper for a specific screen.
    func wallpaper(for screenId: String) -> WEWallpaper {
        wallpapers[screenId] ?? Self.defaultWallpaper
    }

    /// Set wallpaper for a specific screen.
    func setWallpaper(_ wallpaper: WEWallpaper, for screenId: String) {
        wallpapers[screenId] = wallpaper
        addToRecents(wallpaper)
    }

    func setWallpaper(_ wallpaper: WEWallpaper, for screenIds: Set<String>) {
        for screenId in screenIds {
            wallpapers[screenId] = wallpaper
        }
        addToRecents(wallpaper)
    }

    var activePlaylist: WallpaperPlaylist? {
        playlists.first { $0.id == activePlaylistID }
    }

    func createPlaylist(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let playlist = WallpaperPlaylist(name: trimmed)
        playlists.append(playlist)
        activePlaylistID = playlist.id
    }

    @discardableResult
    func createPlaylist(named name: String, wallpapers: [WEWallpaper]) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let playlist = WallpaperPlaylist(name: trimmed,
                                          items: wallpapers
                                            .filter { $0.project != .invalid }
                                            .map { WallpaperPlaylistItem(wallpaper: $0) })
        playlists.append(playlist)
        activePlaylistID = playlist.id
        return true
    }

    func addToPlaylist(_ wallpapers: [WEWallpaper], playlistID: UUID) {
        for wallpaper in wallpapers { addToPlaylist(wallpaper, playlistID: playlistID) }
    }

    func deletePlaylist(_ playlist: WallpaperPlaylist) {
        playlists.removeAll { $0.id == playlist.id }
        if activePlaylistID == playlist.id { activePlaylistID = playlists.first?.id }
    }

    func addToPlaylist(_ wallpaper: WEWallpaper, playlistID: UUID? = nil) {
        guard wallpaper.project != .invalid,
              let id = playlistID ?? activePlaylistID,
              let index = playlists.firstIndex(where: { $0.id == id }),
              !playlists[index].items.contains(where: { $0.wallpaper.wallpaperDirectory == wallpaper.wallpaperDirectory }) else { return }
        playlists[index].items.append(WallpaperPlaylistItem(wallpaper: wallpaper))
    }

    func removeFromPlaylist(itemID: UUID, playlistID: UUID? = nil) {
        guard let id = playlistID ?? activePlaylistID,
              let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].items.removeAll { $0.id == itemID }
    }

    func movePlaylistItem(itemID: UUID, offset: Int, playlistID: UUID? = nil) {
        guard let id = playlistID ?? activePlaylistID,
              let playlistIndex = playlists.firstIndex(where: { $0.id == id }),
              let itemIndex = playlists[playlistIndex].items.firstIndex(where: { $0.id == itemID }) else { return }
        let destination = itemIndex + offset
        guard playlists[playlistIndex].items.indices.contains(destination) else { return }
        playlists[playlistIndex].items.swapAt(itemIndex, destination)
    }

    func setPlaylistItemDuration(_ duration: TimeInterval, itemID: UUID, playlistID: UUID? = nil) {
          guard let id = playlistID ?? activePlaylistID,
              let playlistIndex = playlists.firstIndex(where: { $0.id == id }) else { return }
          playlists[playlistIndex].duration = max(duration, 1)
        restartPlaylistTimer()
    }

        func setPlaylistDuration(_ duration: TimeInterval, playlistID: UUID? = nil) {
          guard let id = playlistID ?? activePlaylistID,
              let index = playlists.firstIndex(where: { $0.id == id }) else { return }
          playlists[index].duration = max(duration, 1)
          restartPlaylistTimer()
        }

        func setPlaylistChangeWhenVideoEnds(_ enabled: Bool, playlistID: UUID? = nil) {
          guard let id = playlistID ?? activePlaylistID,
              let index = playlists.firstIndex(where: { $0.id == id }) else { return }
          playlists[index].changeWhenVideoEnds = enabled
          restartPlaylistTimer()
        }

        func advancePlaylistIfVideoEnds(_ wallpaper: WEWallpaper) {
          guard let playlist = activePlaylist, playlist.changeWhenVideoEnds,
              playlist.items.indices.contains(playlistIndex),
              playlist.items[playlistIndex].wallpaper.wallpaperDirectory == wallpaper.wallpaperDirectory else { return }
          nextPlaylistWallpaper()
        }

    func importVideoWallpaper(from url: URL) {
        let fileManager = FileManager.default
        let baseName = url.deletingPathExtension().lastPathComponent
        var destination = fileManager.wallpapersDirectory.appending(path: baseName)
        var suffix = 2
        while fileManager.fileExists(atPath: destination.path) {
            destination = fileManager.wallpapersDirectory.appending(path: "\(baseName) \(suffix)")
            suffix += 1
        }
        let fileName = url.lastPathComponent
        let project = WEProject(file: fileName, preview: "preview.jpg", title: baseName, type: "video")
        let generator = AVAssetImageGenerator(asset: AVAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: CMTime(seconds: 0, preferredTimescale: 600))]) { [weak self] _, cgImage, _, _, _ in
            guard let cgImage,
                  let previewData = NSBitmapImageRep(cgImage: cgImage).representation(using: .jpeg, properties: [:]) else { return }
            DispatchQueue.main.async {
                do {
                    try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
                    try fileManager.copyItem(at: url, to: destination.appending(path: fileName))
                    try previewData.write(to: destination.appending(path: "preview.jpg"), options: .atomic)
                    try JSONEncoder().encode(project).write(to: destination.appending(path: "project.json"), options: .atomic)
                } catch {
                    OWELog.error(.importer, "Failed to import video: \(error.localizedDescription)")
                }
            }
        }
    }

    func addRemoteWallpaper(from url: URL) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        let pathExtension = url.pathExtension.lowercased()
        let imageExtensions = ["jpg", "jpeg", "png", "gif", "webp", "heic"]
        let videoExtensions = ["mp4", "mov", "m4v", "webm"]
        if imageExtensions.contains(pathExtension) {
            importImageAsScene(from: url)
            return
        }
        guard videoExtensions.contains(pathExtension) else { return }
        importRemoteVideo(from: url)
    }

    /// Remote videos used to live only in memory, so the library — which lists folders on disk —
    /// never showed a tile for them. They now get a real wallpaper folder whose project.json keeps
    /// the absolute URL as its file.
    private func importRemoteVideo(from url: URL) {
        let fileManager = FileManager.default
        let baseName = url.deletingPathExtension().lastPathComponent
        let title = baseName.isEmpty ? (url.host ?? "Remote Video") : baseName
        var destination = fileManager.wallpapersDirectory.appending(path: title)
        var suffix = 2
        while fileManager.fileExists(atPath: destination.path) {
            destination = fileManager.wallpapersDirectory.appending(path: "\(title) \(suffix)")
            suffix += 1
        }
        let finalDestination = destination
        let project = WEProject(file: url.absoluteString, preview: "preview.jpg", title: title, type: "remote-video")
        do {
            try fileManager.createDirectory(at: finalDestination, withIntermediateDirectories: true)
            try JSONEncoder().encode(project)
                .write(to: finalDestination.appending(path: "project.json"), options: .atomic)
        } catch {
            OWELog.error(.importer, "Failed to add remote video: \(error.localizedDescription)")
            return
        }
        let wallpaper = WEWallpaper(using: project, where: finalDestination)
        setWallpaper(wallpaper, for: selectedScreenIds)
        inspect(wallpaper)

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: CMTime(seconds: 0, preferredTimescale: 600))]) { _, cgImage, _, _, _ in
            guard let cgImage,
                  let previewData = NSBitmapImageRep(cgImage: cgImage).representation(using: .jpeg, properties: [:]) else { return }
            try? previewData.write(to: finalDestination.appending(path: "preview.jpg"), options: .atomic)
        }
    }

    /// Downloads the image and writes a minimal Wallpaper Engine scene around it, so it renders
    /// through the normal scene pipeline and the whole effect stack applies to it.
    private func importImageAsScene(from url: URL) {
        let fileManager = FileManager.default
        let baseName = url.deletingPathExtension().lastPathComponent
        let title = baseName.isEmpty ? (url.host ?? "Image Wallpaper") : baseName
        var destination = fileManager.wallpapersDirectory.appending(path: title)
        var suffix = 2
        while fileManager.fileExists(atPath: destination.path) {
            destination = fileManager.wallpapersDirectory.appending(path: "\(title) \(suffix)")
            suffix += 1
        }
        let finalDestination = destination

        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = NSImage(data: data), image.size.width > 0 else {
                OWELog.error(.importer, "Could not download image at \(url.absoluteString)")
                return
            }
            // The scene texture loader looks for materials/<name>.<ext>, so the bytes are stored
            // under the name the generated material references.
            let textureExtension = ["png", "jpg", "jpeg", "gif"].contains(url.pathExtension.lowercased())
                ? url.pathExtension.lowercased()
                : "png"
            let textureData = textureExtension == "png"
                ? (NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) ?? data)
                : data
            let width = Int(image.size.width)
            let height = Int(image.size.height)

            let scene: [String: Any] = [
                "camera": [:],
                "general": [
                    "clearcolor": "0 0 0",
                    "orthogonalprojection": ["width": width, "height": height]
                ],
                "objects": [[
                    "id": 0,
                    "name": "Image",
                    "image": "models/image.json",
                    "origin": "\(width / 2) \(height / 2) 0",
                    "scale": "1 1 1",
                    "angles": "0 0 0",
                    "size": "\(width) \(height)",
                    "visible": true
                ]]
            ]
            let model: [String: Any] = ["material": "materials/image.json"]
            let material: [String: Any] = ["passes": [["textures": ["image"]]]]

            do {
                try fileManager.createDirectory(at: finalDestination.appending(path: "models"), withIntermediateDirectories: true)
                try fileManager.createDirectory(at: finalDestination.appending(path: "materials"), withIntermediateDirectories: true)
                try textureData.write(to: finalDestination.appending(path: "materials/image.\(textureExtension)"), options: .atomic)
                try JSONSerialization.data(withJSONObject: scene)
                    .write(to: finalDestination.appending(path: "scene.json"), options: .atomic)
                try JSONSerialization.data(withJSONObject: model)
                    .write(to: finalDestination.appending(path: "models/image.json"), options: .atomic)
                try JSONSerialization.data(withJSONObject: material)
                    .write(to: finalDestination.appending(path: "materials/image.json"), options: .atomic)
                if let preview = NSBitmapImageRep(data: data)?.representation(using: .jpeg, properties: [:]) {
                    try preview.write(to: finalDestination.appending(path: "preview.jpg"), options: .atomic)
                }
                let project = WEProject(file: "scene.json", preview: "preview.jpg", title: title, type: "scene")
                try JSONEncoder().encode(project)
                    .write(to: finalDestination.appending(path: "project.json"), options: .atomic)

                guard let self else { return }
                let wallpaper = WEWallpaper(using: project, where: finalDestination)
                self.setWallpaper(wallpaper, for: self.selectedScreenIds)
                self.inspect(wallpaper)
            } catch {
                OWELog.error(.importer, "Failed to build image scene: \(error.localizedDescription)")
            }
        }
    }

    func setContentRating(_ rating: String, for wallpaper: WEWallpaper) {
        guard wallpaper.project.workshopid == nil else { return }
        var updated = wallpaper
        updated.project.contentrating = rating
        if let data = try? JSONEncoder().encode(updated.project) {
            try? data.write(to: updated.wallpaperDirectory.appending(path: "project.json"), options: .atomic)
        }
        for key in wallpapers.keys where wallpapers[key]?.wallpaperDirectory == updated.wallpaperDirectory {
            wallpapers[key] = updated
        }
        inspect(updated)
    }

    func nextPlaylistWallpaper() {
        guard let playlist = activePlaylist, !playlist.items.isEmpty else { return }
        if playlistShuffle {
            playlistIndex = Int.random(in: 0..<playlist.items.count)
        } else {
            playlistIndex += 1
            if playlistIndex >= playlist.items.count {
                guard playlistRepeats else { playlistEnabled = false; return }
                playlistIndex = 0
            }
        }
        setWallpaper(playlist.items[playlistIndex].wallpaper, for: selectedScreenIds)
        restartPlaylistTimer()
    }

    func previousPlaylistWallpaper() {
        guard let playlist = activePlaylist, !playlist.items.isEmpty else { return }
        playlistIndex = (playlistIndex - 1 + playlist.items.count) % playlist.items.count
        setWallpaper(playlist.items[playlistIndex].wallpaper, for: selectedScreenIds)
        restartPlaylistTimer()
    }

    private func restartPlaylistTimer() {
        playlistTimer?.invalidate()
        playlistTimer = nil
          guard persistsWallpapers, playlistEnabled, !isPlaylistSuspended, let playlist = activePlaylist,
              let item = playlist.items[safe: playlistIndex] else { return }
          let type = item.wallpaper.project.type.lowercased()
          if playlist.changeWhenVideoEnds && (type == "video" || type == "remote-video") { return }
          playlistTimer = Timer.scheduledTimer(withTimeInterval: playlist.duration, repeats: false) { [weak self] _ in
            self?.nextPlaylistWallpaper()
        }
    }

    private func savePlaylists() {
        guard let data = try? JSONEncoder().encode(playlists) else { return }
        UserDefaults.standard.set(data, forKey: "WallpaperPlaylists")
    }

    private func savePlaylistSettings() {
        UserDefaults.standard.set(activePlaylistID?.uuidString, forKey: "ActiveWallpaperPlaylist")
        UserDefaults.standard.set(playlistShuffle, forKey: "WallpaperPlaylistShuffle")
        UserDefaults.standard.set(playlistRepeats, forKey: "WallpaperPlaylistRepeats")
        UserDefaults.standard.set(playlistEnabled, forKey: "WallpaperPlaylistEnabled")
    }

    func selectScreen(_ screenId: String, extendingSelection: Bool) {
        if extendingSelection {
            if selectedScreenIds.contains(screenId) {
                selectedScreenIds.remove(screenId)
            } else {
                selectedScreenIds.insert(screenId)
            }
        } else {
            selectedScreenIds = [screenId]
        }
        selectedScreenId = screenId
    }

    func isScreenEnabled(_ screenId: String) -> Bool {
        enabledScreens.contains(screenId)
    }

    func shouldPlayAudio(on screenId: String) -> Bool {
        guard persistsWallpapers else { return true }

        let wallpaper = wallpaper(for: screenId)
        let type = wallpaper.project.type.lowercased()
        guard type == "video" || type == "remote-video" else { return false }
        let sourceKey = type == "remote-video"
            ? wallpaper.project.file
            : wallpaper.wallpaperDirectory.appending(path: wallpaper.project.file).standardizedFileURL.path
        let matchingScreens = wallpapers.compactMap { assignedScreen, assignedWallpaper -> String? in
            guard enabledScreens.contains(assignedScreen) else { return nil }
            let assignedType = assignedWallpaper.project.type.lowercased()
            guard assignedType == "video" || assignedType == "remote-video" else { return nil }
            let assignedSource = assignedType == "remote-video"
                ? assignedWallpaper.project.file
                : assignedWallpaper.wallpaperDirectory.appending(path: assignedWallpaper.project.file).standardizedFileURL.path
            return assignedSource == sourceKey ? assignedScreen : nil
        }.sorted()
        guard let firstMatchingScreen = matchingScreens.first else { return false }
        let primaryScreenId = NSScreen.main.map(Self.screenId(for:))
        return screenId == (matchingScreens.contains(primaryScreenId ?? "") ? primaryScreenId : firstMatchingScreen)
    }

    func shouldPlaySceneAudio(on screenId: String) -> Bool {
        guard persistsWallpapers else { return true }
        let enabledSceneScreens = wallpapers.compactMap { id, wallpaper in
            enabledScreens.contains(id) && wallpaper.project.type.lowercased() == "scene" ? id : nil
        }.sorted()
        guard !enabledSceneScreens.isEmpty else { return false }
        let primary = NSScreen.main.map(Self.screenId(for:))
        return screenId == (enabledSceneScreens.contains(primary ?? "") ? primary : enabledSceneScreens[0])
    }

    func toggleScreen(_ screenId: String) {
        if enabledScreens.contains(screenId) {
            enabledScreens.remove(screenId)
        } else {
            enabledScreens.insert(screenId)
        }
        AppDelegate.shared.rebuildWallpaperWindows()
    }

    /// Remove a wallpaper from all screens (e.g., when unsubscribing).
    func removeWallpaperFromAllScreens(directory: URL) {
        for (key, wp) in wallpapers {
            if wp.wallpaperDirectory == directory {
                wallpapers[key] = Self.defaultWallpaper
            }
        }
    }

    var lastPlayRate: Float = 1.0
    @Published public var playRate: Float = 1.0 {
        willSet {
            guard persistsWallpapers else { return }
            if newValue == 0.0 {
                for (index, item) in AppDelegate.shared.statusItem.menu!.items.enumerated() {
                    if item.title == "Pause" {
                        AppDelegate.shared.statusItem.menu!.items[index] =
                            .init(title: "Resume", systemImage: "play.fill", action: #selector(AppDelegate.shared.resume), keyEquivalent: "")
                    }
                }
            } else {
                for (index, item) in AppDelegate.shared.statusItem.menu!.items.enumerated() {
                    if item.title == "Resume" {
                        AppDelegate.shared.statusItem.menu!.items[index] =
                            .init(title: "Pause", systemImage: "pause.fill", action: #selector(AppDelegate.shared.pause), keyEquivalent: "")
                    }
                }
            }
        }
        didSet {
            self.lastPlayRate = oldValue
            if arePlaybackRatesLinked {
                audioPlayRate = playRate
            }
        }
    }

    @Published var audioPlayRate: Float = 1.0
    @Published var arePlaybackRatesLinked = true {
        didSet {
            if arePlaybackRatesLinked {
                audioPlayRate = playRate
            }
        }
    }

    var lastPlayVolume: Float = 1.0
    @Published public var playVolume: Float = 1.0 {
        willSet {
            guard persistsWallpapers else { return }
            if newValue == 0.0 {
                for (index, item) in AppDelegate.shared.statusItem.menu!.items.enumerated() {
                    if item.title == "Mute" {
                        AppDelegate.shared.statusItem.menu!.items[index] =
                            .init(title: String(localized: "Unmute"), systemImage: "speaker.fill", action: #selector(AppDelegate.shared.unmute), keyEquivalent: "")
                    }
                }
            } else {
                for (index, item) in AppDelegate.shared.statusItem.menu!.items.enumerated() {
                    if item.title == "Unmute" {
                        AppDelegate.shared.statusItem.menu!.items[index] =
                            .init(title: String(localized: "Mute"), systemImage: "speaker.slash.fill", action: #selector(AppDelegate.shared.mute), keyEquivalent: "")
                    }
                }
            }
        }
        didSet {
            self.lastPlayVolume = oldValue
        }
    }

    init(persistsWallpapers: Bool = true) {
        self.persistsWallpapers = persistsWallpapers
        if let storedPlacement = UserDefaults.standard.string(forKey: "WallpaperPlacement"),
           let placement = WallpaperPlacement(rawValue: storedPlacement) {
            wallpaperPlacement = placement
        }
        guard persistsWallpapers else {
            self.selectedScreenId = "preview"
            self.selectedScreenIds = [selectedScreenId]
            return
        }

        if let data = UserDefaults.standard.data(forKey: "WallpaperPlaylists"),
           let saved = try? JSONDecoder().decode([WallpaperPlaylist].self, from: data) {
            self.playlists = saved
        }
        if let value = UserDefaults.standard.string(forKey: "ActiveWallpaperPlaylist") {
            self.activePlaylistID = UUID(uuidString: value)
        }
        if self.activePlaylistID == nil {
            self.activePlaylistID = self.playlists.first?.id
        }
        self.playlistShuffle = UserDefaults.standard.bool(forKey: "WallpaperPlaylistShuffle")
        self.playlistRepeats = UserDefaults.standard.object(forKey: "WallpaperPlaylistRepeats") == nil
            ? true : UserDefaults.standard.bool(forKey: "WallpaperPlaylistRepeats")
        self.playlistEnabled = UserDefaults.standard.bool(forKey: "WallpaperPlaylistEnabled")

        // Load per-screen wallpapers
        if let data = UserDefaults.standard.data(forKey: "ScreenWallpapers"),
           let saved = try? JSONDecoder().decode([String: WEWallpaper].self, from: data) {
            // Filter out any compound keys (screenId_spaceId) from previous per-space experiment
            self.wallpapers = saved.filter { !$0.key.contains("_") }
        }
        // Migrate legacy single wallpaper
        else if let json = UserDefaults.standard.data(forKey: "CurrentWallpaper"),
                let wallpaper = try? JSONDecoder().decode(WEWallpaper.self, from: json) {
            let mainId = Self.mainScreenId()
            self.wallpapers = [mainId: wallpaper]
        }

        // Load enabled screens (default: all connected screens enabled)
        if let saved = UserDefaults.standard.array(forKey: "EnabledScreens") as? [String] {
            self.enabledScreens = Set(saved)
        } else {
            self.enabledScreens = Set(NSScreen.screens.map { Self.screenId(for: $0) })
        }

        // Default the active screen to main while assigning wallpapers to all desktops.
        self.selectedScreenId = Self.mainScreenId()
        self.selectedScreenIds = Set(NSScreen.screens.map { Self.screenId(for: $0) })

        // Load recent wallpapers
        loadRecents()
        restartPlaylistTimer()
    }

    // MARK: - Screen ID helpers

    static func screenId(for screen: NSScreen) -> String {
        let displayId = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
        return String(displayId)
    }

    static func mainScreenId() -> String {
        guard let main = NSScreen.main else { return "0" }
        return screenId(for: main)
    }

    static func screenName(for screen: NSScreen) -> String {
        screen.localizedName
    }

    // MARK: - Persistence

    private func saveWallpapers() {
        if let data = try? JSONEncoder().encode(wallpapers) {
            UserDefaults.standard.set(data, forKey: "ScreenWallpapers")
        }
        // Keep legacy key updated for backward compat
        if let data = try? JSONEncoder().encode(currentWallpaper) {
            UserDefaults.standard.set(data, forKey: "CurrentWallpaper")
        }
    }
}
