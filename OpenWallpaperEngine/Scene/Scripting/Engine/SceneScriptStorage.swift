import AppKit
import Foundation

/// WE's SceneScript `localStorage` (lib.sceneScript.d.ts `ILocalStorage`), persisted per wallpaper:
/// one store for `'global'` (every instance of the wallpaper) and one per screen for `'screen'`, as
/// JSON files under `directory/<wallpaper id>/`. Values arrive as the JSON text scripts produced
/// (`JSON.stringify`), the form WE stores behind its `LSKV0001` header (scenescript64.dll).
///
/// One instance serves every runtime of the app, so two screens showing the same wallpaper see
/// each other's `'global'` writes at once; the owner (WP11) creates it and passes it in. `lock`
/// guards `stores`; each mutation marks its store dirty and `flush()` writes dirty stores.
/// `flushLock` serializes flushes, so an older snapshot never overwrites a newer one.
///
/// Stores are written by the runtimes (at most once a second, and at teardown) and when the app
/// terminates: the storage flushes itself on `NSApplication.willTerminateNotification`, since
/// runtimes are not torn down on quit (SF7).
final class SceneScriptStorage: @unchecked Sendable {
    enum Location: Equatable {
        case global
        case screen
    }

    /// wallpaper64.exe refuses a write that would take a store past 100000 bytes (`0x186a0`,
    /// "up to 100 KB per wallpaper" in the docs): the other keys' entries plus the new one.
    static let capacity = 100_000
    /// Each entry is WE's `LSKV0001` header followed by the value's JSON text. The key counts too
    /// (SF6): whether WE counts it is not known, but the file is ours, and without it a script that
    /// uses data as keys grows the store without bound.
    static let entryOverhead = 8

    let directory: URL
    private let lock = NSLock()
    private let flushLock = NSLock()
    private var stores: [String: Store] = [:]
    private var terminationObserver: NSObjectProtocol?
    private let notificationCenter: NotificationCenter

    /// `notificationCenter` is where the app posts `willTerminateNotification` (tests pass their own).
    init(directory: URL, notificationCenter: NotificationCenter = .default) {
        self.directory = directory
        self.notificationCenter = notificationCenter
        terminationObserver = notificationCenter.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            self?.flush()
        }
    }

    /// `<Application Support>/Open Wallpaper Engine/scenestorage`, the counterpart of WE's
    /// `bin/scenestorage/`.
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Open Wallpaper Engine/scenestorage")
    }

    deinit {
        if let terminationObserver { notificationCenter.removeObserver(terminationObserver) }
        flush()
    }

    // MARK: - Access (any thread)

    /// The JSON text stored under `key`, or nil.
    func value(forKey key: String, in location: Location, of identity: SceneScriptIdentity) -> String? {
        withStore(location, identity) { $0.entries[key] }
    }

    /// Stores `json` under `key`. False, storing nothing, when the store would exceed `capacity`.
    func setValue(_ json: String, forKey key: String, in location: Location, of identity: SceneScriptIdentity) -> Bool {
        withStore(location, identity) { store in
            let size = Self.size(key: key, json: json)
            let others = store.size - (store.entries[key].map { Self.size(key: key, json: $0) } ?? 0)
            guard others + size <= Self.capacity else { return false }
            store.entries[key] = json
            store.size = others + size
            store.dirty = true
            return true
        }
    }

    /// Removes `key`; true when it was stored.
    @discardableResult
    func removeValue(forKey key: String, in location: Location, of identity: SceneScriptIdentity) -> Bool {
        withStore(location, identity) { store in
            guard let removed = store.entries.removeValue(forKey: key) else { return false }
            store.size -= Self.size(key: key, json: removed)
            store.dirty = true
            return true
        }
    }

    func removeAll(in location: Location, of identity: SceneScriptIdentity) {
        withStore(location, identity) { store in
            guard !store.entries.isEmpty else { return }
            store.entries.removeAll()
            store.size = 0
            store.dirty = true
        }
    }

    /// Writes every store changed since the last flush.
    func flush() {
        flushLock.lock()
        defer { flushLock.unlock() }
        lock.lock()
        let dirty = stores.filter { $0.value.dirty }
        for key in dirty.keys { stores[key]?.dirty = false }
        lock.unlock()
        for store in dirty.values { write(store) }
    }

    /// Where a store lives: `<wallpaper>/global.json` or `<wallpaper>/screen-<screen>.json`.
    func fileURL(for location: Location, of identity: SceneScriptIdentity) -> URL {
        let folder = directory.appending(path: Self.fileComponent(identity.wallpaperID), directoryHint: .isDirectory)
        switch location {
        case .global: return folder.appending(path: "global.json")
        case .screen: return folder.appending(path: "screen-\(Self.fileComponent(identity.screenID)).json")
        }
    }

    // MARK: - Stores

    private struct Store {
        var url: URL
        var entries: [String: String]
        /// The entries' total size: `entryOverhead` plus the key's and the value's UTF-8 bytes each.
        var size: Int
        var dirty = false
    }

    private struct File: Codable {
        var version = 1
        var entries: [String: String]
    }

    private func withStore<Result>(_ location: Location, _ identity: SceneScriptIdentity,
                                   _ body: (inout Store) -> Result) -> Result {
        let url = fileURL(for: location, of: identity)
        lock.lock()
        defer { lock.unlock() }
        if stores[url.path] == nil { stores[url.path] = read(url) }
        return body(&stores[url.path]!)
    }

    private func read(_ url: URL) -> Store {
        var store = Store(url: url, entries: [:], size: 0)
        guard FileManager.default.fileExists(atPath: url.path) else { return store }
        do {
            store.entries = try JSONDecoder().decode(File.self, from: Data(contentsOf: url)).entries
            store.size = store.entries.reduce(0) { $0 + Self.size(key: $1.key, json: $1.value) }
        } catch {
            OWELog.error(.script, "Reading SceneScript localStorage \(url.path) failed; starting empty: \(error)")
        }
        return store
    }

    private func write(_ store: Store) {
        do {
            if store.entries.isEmpty {
                if FileManager.default.fileExists(atPath: store.url.path) {
                    try FileManager.default.removeItem(at: store.url)
                }
                return
            }
            try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            try encoder.encode(File(entries: store.entries)).write(to: store.url, options: .atomic)
        } catch {
            OWELog.error(.script, "Writing SceneScript localStorage \(store.url.path) failed: \(error)")
        }
    }

    static func size(key: String, json: String) -> Int {
        entryOverhead + key.utf8.count + json.utf8.count
    }

    /// A path component that can't escape the storage folder, whatever the id holds.
    private static func fileComponent(_ id: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_")
        let encoded = id.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return encoded.isEmpty ? "_" : encoded
    }
}
