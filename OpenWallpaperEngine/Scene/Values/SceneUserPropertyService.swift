import Foundation

/// The user properties of every running wallpaper instance, their music-synced modulation and the
/// per-frame snapshot the render loop reads them from. Owned by `AudioReactiveScriptEngine`, which
/// forwards to it until the SceneScript runtime takes over (docs/scenescript-plan.md, WP1).
final class SceneUserPropertyService {
    /// Guards every stored property except `frameSnapshot`, which is confined to the render thread.
    private let levelLock = NSLock()
    /// The current system audio level, used by music-synced properties.
    private let audioLevel: () -> Double
    private var level: Double { audioLevel() }
    /// Per-wallpaper user properties (guarded by `levelLock`). `userPropertyStrings` and
    /// `globalValues` are views of the active wallpaper's entry.
    private var propertyStores = SceneUserPropertyStores()
    private var globalValues: [String: Double] {
        get { propertyStores.active.numbers }
        set { propertyStores.active.numbers = newValue }
    }
    private var userPropertyStrings: [String: String] {
        get { propertyStores.active.strings }
        set { propertyStores.active.strings = newValue }
    }
    private var userPropertiesRevision = 0
    private var scriptPropertyCacheRevision = -1
    private var scriptPropertyCacheKey = ""
    private var cachedModulatedGlobals: [String: Double] = [:]
    private var cachedUserProperties: [String: Any] = [:]
    private var cachedMusicSyncedKeys: [String] = []
    private var propertyNotificationWorkItem: DispatchWorkItem?

    init(audioLevel: @escaping () -> Double) {
        self.audioLevel = audioLevel
    }

    /// Sets the user properties of one wallpaper instance (keyed by its directory path). With
    /// `replacing`, properties missing from `values` are dropped, so nothing from a previous
    /// configuration of that wallpaper lingers.
    func setUserProperties(_ values: [String: String], wallpaper: String, replacing: Bool) {
        levelLock.lock()
        let changedKeys = propertyStores.set(values, for: wallpaper, replacing: replacing)
        if frameSnapshot == nil { propertyStores.activeKey = wallpaper }
        userPropertiesRevision &+= 1
        levelLock.unlock()
        propertyNotificationWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.levelLock.lock()
            let keys = Array(changedKeys)
            self.levelLock.unlock()
            NotificationCenter.default.post(name: .sceneUserPropertiesDidChange, object: nil,
                                            userInfo: ["keys": keys])
        }
        propertyNotificationWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    // MARK: - Frame snapshot

    /// Copy of the property state the render loop reads. Taken once per frame so per-layer reads
    /// stop contending with the audio thread. Confined to the render thread; dictionaries are
    /// copy-on-write so taking it is cheap.
    struct FrameSnapshot {
        var globalValues: [String: Double]
        var userPropertyStrings: [String: String]
        var level: Double
        var revision: Int
    }

    private var frameSnapshot: FrameSnapshot?

    /// The audio level captured with the current frame's snapshot; nil outside a frame.
    var frameAudioLevel: Double? { frameSnapshot?.level }

    /// Bumped whenever any user property changes. Render-side caches key off this to know when
    /// derived GPU state is still valid.
    var propertyRevision: Int {
        if let frameSnapshot { return frameSnapshot.revision }
        levelLock.lock()
        defer { levelLock.unlock() }
        return userPropertiesRevision
    }

    /// Starts a frame of `wallpaper` (its directory path): reads until `endFrame` see that
    /// wallpaper's user properties.
    func beginFrame(wallpaper: String) {
        levelLock.lock()
        propertyStores.activeKey = wallpaper
        frameSnapshot = FrameSnapshot(globalValues: globalValues,
                                      userPropertyStrings: userPropertyStrings,
                                      level: level,
                                      revision: userPropertiesRevision)
        levelLock.unlock()
    }

    func endFrame() {
        frameSnapshot = nil
    }

    private func modulatedValue(_ key: String, fallback: Double, in snapshot: FrameSnapshot) -> Double {
        let base = snapshot.globalValues[key] ?? fallback
        guard !key.hasSuffix("_musicSync"), !key.hasSuffix("_musicAmount"),
              snapshot.userPropertyStrings["\(key)_musicSync"] == "true" else { return base }
        let amount = snapshot.globalValues["\(key)_musicAmount"] ?? 0
        guard abs(amount) > 0.0001 else { return base }
        return base + snapshot.level * amount
    }

    func userPropertyValue(_ key: String, fallback: Float) -> Float {
        if let frameSnapshot {
            return Float(modulatedValue(key, fallback: Double(fallback), in: frameSnapshot))
        }
        OWEFrameMetrics.countLockAcquisition()
        levelLock.lock()
        defer { levelLock.unlock() }
        return Float(modulatedValueLocked(key, fallback: Double(fallback)))
    }

    /// The active wallpaper's modulated value, read under the lock (the script `property()` global).
    func modulatedValue(_ key: String) -> Double {
        levelLock.lock()
        defer { levelLock.unlock() }
        return modulatedValueLocked(key)
    }

    private func modulatedValueLocked(_ key: String, fallback: Double = 0) -> Double {
        let base = globalValues[key] ?? fallback
        guard !key.hasSuffix("_musicSync"), !key.hasSuffix("_musicAmount"),
              userPropertyStrings["\(key)_musicSync"] == "true" else { return base }
        let amount = globalValues["\(key)_musicAmount"] ?? 0
        guard abs(amount) > 0.0001 else { return base }
        return base + level * amount
    }

    func isMusicSynced(_ key: String) -> Bool {
        if let frameSnapshot { return frameSnapshot.userPropertyStrings["\(key)_musicSync"] == "true" }
        OWEFrameMetrics.countLockAcquisition()
        levelLock.lock()
        defer { levelLock.unlock() }
        return userPropertyStrings["\(key)_musicSync"] == "true"
    }

    private func modulatedGlobalValuesLocked() -> [String: Double] {
        Dictionary(uniqueKeysWithValues: globalValues.map { key, value in
            (key, modulatedValueLocked(key, fallback: value))
        })
    }

    func userPropertyString(_ key: String) -> String? {
        if let frameSnapshot { return frameSnapshot.userPropertyStrings[key] }
        OWEFrameMetrics.countLockAcquisition()
        levelLock.lock()
        defer { levelLock.unlock() }
        return userPropertyStrings[key]
    }

    /// One wallpaper instance's property, independent of which wallpaper is being rendered.
    func userPropertyString(_ key: String, wallpaper: String) -> String? {
        levelLock.lock()
        defer { levelLock.unlock() }
        return propertyStores.entry(for: wallpaper).strings[key]
    }

    /// Every user property of one wallpaper instance.
    func userProperties(wallpaper: String) -> [String: String] {
        levelLock.lock()
        defer { levelLock.unlock() }
        return propertyStores.entry(for: wallpaper).strings
    }

    // MARK: - Script-published numbers

    /// A number of the active wallpaper: the frame snapshot's inside a frame, else the store's.
    func globalValue(_ key: String) -> Double? {
        if let frameSnapshot { return frameSnapshot.globalValues[key] }
        levelLock.lock()
        defer { levelLock.unlock() }
        return globalValues[key]
    }

    /// Publishes a number on the active wallpaper (scripts' `setGlobal`, `thisScene.camerashake`).
    /// With `includingFrame`, the current frame's snapshot sees it too.
    func setGlobalValue(_ value: Double, forKey key: String, includingFrame: Bool = false) {
        levelLock.lock()
        globalValues[key] = value
        levelLock.unlock()
        if includingFrame { frameSnapshot?.globalValues[key] = value }
    }

    /// The active wallpaper's numbers (music-synced ones modulated) and user properties as the
    /// legacy script engine hands them to scripts, plus the property revision they belong to.
    func scriptInputs() -> (globals: [String: Double], userProperties: [String: Any], revision: Int) {
        levelLock.lock()
        let propertyRevision = userPropertiesRevision
        let snapshotLevel = level
        // Converting every user property on each evaluation dominated script cost; rebuild only
        // when properties actually change, then patch the (usually empty) music-synced subset.
        if propertyRevision != scriptPropertyCacheRevision || propertyStores.activeKey != scriptPropertyCacheKey {
            scriptPropertyCacheRevision = propertyRevision
            scriptPropertyCacheKey = propertyStores.activeKey
            cachedModulatedGlobals = globalValues
            cachedMusicSyncedKeys = globalValues.keys.filter {
                userPropertyStrings["\($0)_musicSync"] == "true"
            }
            cachedUserProperties = Dictionary(uniqueKeysWithValues: userPropertyStrings.map { key, value -> (String, Any) in
                if value.caseInsensitiveCompare("true") == .orderedSame { return (key, true) }
                if value.caseInsensitiveCompare("false") == .orderedSame { return (key, false) }
                if let number = Double(value) { return (key, number) }
                return (key, value)
            })
        }
        var modulatedGlobals = cachedModulatedGlobals
        var userProperties = cachedUserProperties
        for key in cachedMusicSyncedKeys {
            let amount = globalValues["\(key)_musicAmount"] ?? 0
            guard abs(amount) > 0.0001 else { continue }
            let modulated = (globalValues[key] ?? 0) + snapshotLevel * amount
            modulatedGlobals[key] = modulated
            userProperties[key] = modulated
        }
        levelLock.unlock()
        return (modulatedGlobals, userProperties, propertyRevision)
    }
}
