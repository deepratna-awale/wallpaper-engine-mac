//
//  WorkshopDependencyIndex.swift
//  Open Wallpaper Engine
//
//  The Workshop items that are in the library only because a wallpaper needs them: asset packs,
//  effects, fonts, models and particles another wallpaper references as `workshop/<id>/…` or in its
//  project.json `dependency`. WE gets these as a wallpaper's required items and never lists them in
//  Installed; they stay on disk so the wallpapers that use them keep resolving. The user's own
//  download of the same item wins: it then belongs to the user and is listed.
//
//  The ids are stored in a hidden JSON file inside the library folder, so they follow the library
//  when its location changes.
//

import Foundation

final class WorkshopDependencyIndex {
    static let fileName = ".owe-workshop-dependencies.json"

    private let libraryDirectory: () -> URL
    /// Owns `cache`. The library listing reads on the main thread; orphan cleanup reads off it.
    private let lock = NSLock()
    private var cache: (directory: URL, ids: Set<String>)?

    init(libraryDirectory: @escaping () -> URL = { FileManager.default.wallpapersDirectory }) {
        self.libraryDirectory = libraryDirectory
    }

    /// The ids downloaded as dependencies of the current library's wallpapers.
    var ids: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return loadedIds()
    }

    func contains(_ workshopId: String) -> Bool {
        ids.contains(workshopId)
    }

    /// A dependency download finished. `copiedIntoLibrary` is false when the item was already in the
    /// library, in which case it keeps whatever standing it had (a user's own item stays theirs).
    func recordDependencyDownload(_ workshopId: String, copiedIntoLibrary: Bool) {
        guard copiedIntoLibrary else { return }
        update { $0.insert(workshopId).inserted }
    }

    /// The user downloaded the item themselves, so it is theirs now even if a wallpaper needs it too.
    func recordUserDownload(_ workshopId: String) {
        update { $0.remove(workshopId) != nil }
    }

    /// The item left the library.
    func remove(_ workshopId: String) {
        update { $0.remove(workshopId) != nil }
    }

    private func update(_ change: (inout Set<String>) -> Bool) {
        lock.lock()
        defer { lock.unlock() }
        var ids = loadedIds()
        guard change(&ids) else { return }
        let directory = libraryDirectory().standardizedFileURL
        cache = (directory, ids)
        let url = directory.appending(path: Self.fileName)
        do {
            try JSONEncoder().encode(ids.sorted()).write(to: url, options: .atomic)
        } catch {
            OWELog.error(.library, "Can't save the workshop dependency list to \(url.path): \(error)")
        }
    }

    /// Call with `lock` held.
    private func loadedIds() -> Set<String> {
        let directory = libraryDirectory().standardizedFileURL
        if let cache, cache.directory == directory { return cache.ids }
        let url = directory.appending(path: Self.fileName)
        var ids = Set<String>()
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                ids = Set(try JSONDecoder().decode([String].self, from: Data(contentsOf: url)))
            } catch {
                OWELog.error(.library, "Can't read the workshop dependency list at \(url.path): \(error)")
            }
        }
        cache = (directory, ids)
        return ids
    }
}
