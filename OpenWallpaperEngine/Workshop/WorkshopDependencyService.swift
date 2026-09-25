//
//  WorkshopDependencyService.swift
//  Open Wallpaper Engine
//
//  Downloads the Workshop items a wallpaper borrows assets from. When a wallpaper is shown (or a
//  Workshop item finishes downloading) its references are scanned off the main thread; every
//  missing id is fetched through steamcmd, and each download is scanned in turn, so dependencies
//  of dependencies arrive too. Each id is requested once per session. When a wallpaper's last
//  missing dependency lands, `.workshopDependenciesDidInstall` asks its scene to reload.
//

import Combine
import Foundation

extension Notification.Name {
    /// Posted on the main queue; `userInfo["wallpaperDirectory"]` is the wallpaper to reload.
    static let workshopDependenciesDidInstall = Notification.Name("WorkshopDependenciesDidInstall")
}

@MainActor
final class WorkshopDependencyService: ObservableObject {
    enum State: Equatable {
        case downloading
        case installed
        case failed
        /// steamcmd isn't set up or logged in, so the item can't be fetched automatically.
        case unavailable
    }

    /// Per dependency id, for the UI.
    @Published private(set) var states: [String: State] = [:]
    /// Wallpaper folder → the dependency ids it still waits for.
    @Published private(set) var pending: [URL: Set<String>] = [:]

    private let steamCmd: SteamCmdService
    private let makeResolver: () -> WorkshopAssetResolver
    private var requested = Set<String>()
    private var scanned = Set<URL>()
    private var cancellables = Set<AnyCancellable>()

    init(steamCmd: SteamCmdService,
         makeResolver: @escaping () -> WorkshopAssetResolver = { WorkshopAssetResolver(roots: WorkshopAssetResolver.defaultRoots()) }) {
        self.steamCmd = steamCmd
        self.makeResolver = makeResolver
        // Any finished download (from the Workshop tab too) may itself need dependencies.
        steamCmd.$downloadProgress.sink { [weak self] progress in
            let completed = progress.compactMap { $0.value == .completed ? $0.key : nil }
            Task { @MainActor [weak self] in
                guard let self else { return }
                for id in completed {
                    let directory = FileManager.default.wallpapersDirectory.appending(path: id, directoryHint: .isDirectory)
                    self.ensureDependencies(ofItemAt: directory)
                }
            }
        }.store(in: &cancellables)
        // Wallpapers that were waiting on a login get another try once there is one.
        steamCmd.$isLoggedIn.removeDuplicates().filter { $0 }.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.retryUnavailable() }
        }.store(in: &cancellables)
    }

    private func retryUnavailable() {
        let unavailable = Set(states.compactMap { $0.value == .unavailable ? $0.key : nil })
        for (wallpaper, ids) in pending where !ids.isDisjoint(with: unavailable) {
            scanned.remove(wallpaper)
            pending[wallpaper] = nil
            ensureDependencies(ofItemAt: wallpaper)
        }
    }

    func ensureDependencies(for wallpaper: WEWallpaper) {
        ensureDependencies(ofItemAt: wallpaper.wallpaperDirectory)
    }

    /// Scans the item once per session and fetches whatever it references that isn't installed.
    func ensureDependencies(ofItemAt directory: URL) {
        let directory = directory.standardizedFileURL
        guard scanned.insert(directory).inserted else { return }
        let makeResolver = makeResolver
        Task.detached(priority: .utility) {
            let resolver = makeResolver()
            let referenced = WorkshopDependencyResolver.referencedWorkshopIds(inItemAt: directory)
            let missing = referenced.filter { !resolver.isInstalled($0) }
            // Installed dependencies can still have missing dependencies of their own.
            let installed = referenced.subtracting(missing).compactMap(resolver.itemDirectory(for:))
            await self.handleScan(of: directory, missing: missing, installedDependencies: installed)
        }
    }

    private func handleScan(of directory: URL, missing: Set<String>, installedDependencies: [URL]) {
        installedDependencies.forEach(ensureDependencies(ofItemAt:))
        guard !missing.isEmpty else { return }
        OWELog.info(.workshop, "\(directory.lastPathComponent) needs workshop items \(missing.sorted())")
        pending[directory, default: []].formUnion(missing)
        for id in missing.sorted() { download(id) }
    }

    private func download(_ id: String) {
        guard requested.insert(id).inserted else { return }
        guard steamCmd.isInstalled, steamCmd.isLoggedIn else {
            OWELog.error(.workshop, "Workshop dependency \(id) is missing; log in to steamcmd on the Workshop tab to download it")
            states[id] = .unavailable
            requested.remove(id)
            return
        }
        states[id] = .downloading
        steamCmd.downloadWorkshopItem(workshopId: id) { [weak self] destination in
            Task { @MainActor [weak self] in
                self?.finishDownload(id, destination: destination)
            }
        }
    }

    private func finishDownload(_ id: String, destination: URL?) {
        guard let destination else {
            OWELog.error(.workshop, "Workshop dependency \(id) failed to download")
            states[id] = .failed
            return
        }
        states[id] = .installed
        ensureDependencies(ofItemAt: destination)
        for (wallpaper, ids) in pending where ids.contains(id) {
            let remaining = ids.subtracting([id])
            pending[wallpaper] = remaining.isEmpty ? nil : remaining
            guard remaining.isEmpty else { continue }
            OWELog.info(.workshop, "Workshop dependencies of \(wallpaper.lastPathComponent) installed; reloading")
            NotificationCenter.default.post(name: .workshopDependenciesDidInstall, object: self,
                                            userInfo: ["wallpaperDirectory": wallpaper])
        }
    }
}
