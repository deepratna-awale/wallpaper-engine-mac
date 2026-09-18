//
//  WallpaperViewModel.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/14.
//

import SwiftUI

enum WallpaperPlacement: String, CaseIterable, Identifiable {
    case fill = "Fill"
    case fit = "Fit"
    case center = "Center"
    case stretch = "Stretch"
    case zoom = "Zoom"

    var id: Self { self }
}

/// Provide Wallpaper Database for WallpaperView and ContentView etc.
@MainActor
class WallpaperViewModel: ObservableObject {
    private let persistsWallpapers: Bool

    @Published var nextCurrentWallpaper: WEWallpaper =
    WEWallpaper(using: .invalid, where: Bundle.main.url(forResource: "WallpaperNotFound", withExtension: "mp4")!) {
        willSet {
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
        inspectedWallpaper = wallpaper
        inspectedWorkshopItem = nil
        inspectedAuthor = nil

        let projectWorkshopId = wallpaper.project.workshopid?.rawValue
        let folderWorkshopId = wallpaper.wallpaperDirectory.lastPathComponent
        let workshopId = (projectWorkshopId?.allSatisfy(\.isNumber) == true ? projectWorkshopId : nil)
            ?? (folderWorkshopId.allSatisfy(\.isNumber) ? folderWorkshopId : nil)
        guard let workshopId else { return }

        if let cachedItem = WorkshopMetadataStore.shared.item(for: workshopId) {
            inspectedWorkshopItem = cachedItem
            if let creatorId = cachedItem.creatorId,
               let cachedAuthor = SteamPlayerStore.shared.player(for: creatorId) {
                inspectedAuthor = cachedAuthor
                return
            }
        }
        Task { [weak self] in
            guard let item = try? await WorkshopAPIService().getItemDetails(workshopIds: [workshopId]).first else { return }
            guard let self else { return }
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
            print("Failed to promote Workshop preview: \(error)")
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

        let videoScreenIds = wallpapers.compactMap { screenId, wallpaper in
            enabledScreens.contains(screenId) && wallpaper.project.type.lowercased() == "video"
                ? screenId
                : nil
        }
        guard !videoScreenIds.isEmpty else { return false }

        let primaryScreenId = NSScreen.screens.first.map(Self.screenId(for:))
        let audioScreenId = videoScreenIds.contains(primaryScreenId ?? "")
            ? primaryScreenId
            : videoScreenIds.sorted().first
        return screenId == audioScreenId
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

        // Default selected screen to main
        self.selectedScreenId = Self.mainScreenId()
        self.selectedScreenIds = [selectedScreenId]

        // Load recent wallpapers
        loadRecents()
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
