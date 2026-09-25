import Foundation
import ImageIO

/// The system's now-playing session through the private MediaRemote framework, which is what the
/// menu bar's Now Playing uses. `MPNowPlayingInfoCenter` only describes the calling app's own
/// playback, so it can't stand in.
///
/// MediaRemote is resolved at runtime with `dlopen`/`dlsym` (`MediaRemote.load()`); without it the
/// source reports `enabled == false` and stays silent. Since macOS 15.4 MediaRemote answers only
/// entitled processes, so the info may simply never arrive: scripts then see "nothing playing".
///
/// Its registration is process-wide, so the app keeps one source and every runtime subscribes: the
/// first subscriber registers, the last one's departure unregisters. Notifications trigger a fetch;
/// while something plays with a known duration the position is re-reported once a second (WE:
/// timeline events are "sent frequently while media is playing"). Fetching and artwork decoding
/// run on `queue`; `unsubscribe` never waits for them.
final class MacMediaSessionSource: MediaSessionSource {
    private let queue = DispatchQueue(label: "OpenWallpaperEngine.MediaSession", qos: .utility)
    private let framework: NowPlayingFramework?
    private let now: () -> Date

    /// Owns `subscribers`, `nextID` and `latest`. Held while delivering a state, so `unsubscribe`
    /// waits at most for one delivery in progress (subscribers only queue it), never for fetching.
    private let lock = NSLock()
    private var subscribers: [Int: (MediaSessionState) -> Void] = [:]
    private var nextID = 0
    private var latest: MediaSessionState?

    // Confined to `queue`.
    private var active = false
    private var info: [String: Any] = [:]
    private var isPlaying = false
    private var artwork: (key: Int, colors: ArtworkPalette.Colors?)?
    private var observers: [NSObjectProtocol] = []
    private var timer: DispatchSourceTimer?
    private var fetchGeneration = 0

    init(framework: NowPlayingFramework? = MediaRemote.load(), now: @escaping () -> Date = Date.init) {
        self.framework = framework
        self.now = now
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        timer?.cancel()
        if active { framework?.unregister() }
    }

    func subscribe(_ update: @escaping (MediaSessionState) -> Void) -> Int {
        lock.lock()
        let id = nextID
        nextID += 1
        subscribers[id] = update
        lock.unlock()
        queue.async { [self] in
            reconcile()
            deliverLatest(to: id)
        }
        return id
    }

    func unsubscribe(_ id: Int) {
        lock.lock()
        subscribers[id] = nil
        lock.unlock()
        queue.async { [weak self] in self?.reconcile() }
    }

    /// Waits until the work queued so far has run. Tests use it.
    func flush() {
        queue.sync {}
    }

    // MARK: - Lifecycle (on `queue`)

    /// Registers while anyone listens and unregisters once nobody does.
    private func reconcile() {
        lock.lock()
        let wanted = !subscribers.isEmpty
        lock.unlock()
        if wanted && !active {
            activate()
        } else if !wanted && active {
            deactivate()
        }
    }

    private func activate() {
        active = true
        guard let framework else {
            publish()
            return
        }
        framework.register(on: queue)
        for name in framework.notificationNames {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.queue.async { self?.fetch() }
            })
        }
        publish()
        fetch()
    }

    private func deactivate() {
        active = false
        fetchGeneration += 1
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        timer?.cancel()
        timer = nil
        framework?.unregister()
        info = [:]
        isPlaying = false
        artwork = nil
        lock.lock()
        latest = nil
        lock.unlock()
    }

    private func deliverLatest(to id: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard let latest, let update = subscribers[id] else { return }
        update(latest)
    }

    // MARK: - Fetching (on `queue`)

    private func fetch() {
        guard active, let framework else { return }
        fetchGeneration += 1
        let generation = fetchGeneration
        framework.nowPlayingInfo(on: queue) { [weak self] info in
            guard let self, generation == self.fetchGeneration else { return }
            self.info = info
            framework.isPlaying(on: self.queue) { [weak self] playing in
                guard let self, generation == self.fetchGeneration else { return }
                self.isPlaying = playing
                self.publish()
            }
        }
    }

    private func publish() {
        let colors = artworkColors()
        let state = Self.state(from: info, isPlaying: isPlaying, enabled: framework != nil, now: now(),
                               artwork: colors.map { ($0.key, $0.colors) })
        lock.lock()
        latest = state
        for update in subscribers.values { update(state) }
        lock.unlock()
        scheduleTimeline(running: active && state.playback == .playing && state.timeline.duration > 0)
    }

    /// Decodes the artwork once per image.
    private func artworkColors() -> (key: Int, colors: ArtworkPalette.Colors?)? {
        guard let data = info[MediaRemote.Key.artworkData] as? Data, !data.isEmpty else {
            artwork = nil
            return nil
        }
        var hasher = Hasher()
        hasher.combine(data)
        let key = hasher.finalize()
        if let artwork, artwork.key == key { return artwork }
        var colors: ArtworkPalette.Colors?
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            colors = ArtworkPalette.colors(of: image)
        } else {
            OWELog.error(.script, "Now-playing artwork (\(data.count) bytes) could not be decoded; thumbnail colours are unavailable")
        }
        artwork = (key, colors)
        return artwork
    }

    private func scheduleTimeline(running: Bool) {
        if !running {
            timer?.cancel()
            timer = nil
            return
        }
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.publish() }
        timer.resume()
        self.timer = timer
    }

    // MARK: - Mapping

    /// The media state for MediaRemote's now-playing dictionary.
    static func state(from info: [String: Any], isPlaying: Bool, enabled: Bool, now: Date,
                      artwork: (key: Int, colors: ArtworkPalette.Colors?)?) -> MediaSessionState {
        var state = MediaSessionState()
        state.enabled = enabled
        func string(_ key: String) -> String { (info[key] as? String) ?? "" }
        state.properties.title = string(MediaRemote.Key.title)
        state.properties.artist = string(MediaRemote.Key.artist)
        state.properties.albumTitle = string(MediaRemote.Key.album)
        state.properties.albumArtist = string(MediaRemote.Key.albumArtist)
        state.properties.genres = string(MediaRemote.Key.genre)
        state.properties.contentType = contentType(info[MediaRemote.Key.mediaType] as? String)
        let rate = (info[MediaRemote.Key.playbackRate] as? NSNumber)?.doubleValue
        let playing = isPlaying || (rate ?? 0) > 0
        if playing {
            state.playback = .playing
        } else if !info.isEmpty {
            state.playback = .paused
        }
        if let key = artwork?.key, let colors = artwork?.colors {
            state.thumbnail = .init(artwork: key, colors: colors)
        }
        let duration = (info[MediaRemote.Key.duration] as? NSNumber)?.doubleValue ?? 0
        if duration > 0 {
            var position = (info[MediaRemote.Key.elapsedTime] as? NSNumber)?.doubleValue ?? 0
            if playing, let timestamp = info[MediaRemote.Key.timestamp] as? Date {
                position += now.timeIntervalSince(timestamp) * (rate ?? 1)
            }
            // Whole seconds, so a timeline change is a real one and not float noise per tick.
            state.timeline = .init(position: min(max(position.rounded(.down), 0), duration), duration: duration)
        }
        return state
    }

    private static func contentType(_ mediaType: String?) -> String {
        guard let mediaType = mediaType?.lowercased() else { return "" }
        if mediaType.contains("video") { return "video" }
        if mediaType.contains("music") || mediaType.contains("audio") || mediaType.contains("podcast") { return "audio" }
        return ""
    }
}
