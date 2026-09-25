import Foundation
import ImageIO

/// The system's now-playing session through the private MediaRemote framework, which is what the
/// menu bar's Now Playing uses. `MPNowPlayingInfoCenter` only describes the calling app's own
/// playback, so it can't stand in.
///
/// Everything is resolved at runtime with `dlopen`/`dlsym`; when any symbol is missing the source
/// reports `enabled == false` once and stays silent. Since macOS 15.4 MediaRemote answers only
/// entitled processes, so the info may simply never arrive: scripts then see "nothing playing".
///
/// Notifications trigger a fetch; while something plays with a known duration the position is
/// re-reported once a second (WE: timeline events are "sent frequently while media is playing").
/// All state is confined to `queue`.
final class MacMediaSessionSource: MediaSessionSource {
    private let queue = DispatchQueue(label: "OpenWallpaperEngine.MediaSession", qos: .utility)
    private let remote: MediaRemote?
    private let now: () -> Date

    // Confined to `queue`.
    private var update: ((MediaSessionState) -> Void)?
    private var info: [String: Any] = [:]
    private var isPlaying = false
    private var artwork: (key: Int, colors: ArtworkPalette.Colors?)?
    private var observers: [NSObjectProtocol] = []
    private var timer: DispatchSourceTimer?
    private var fetchGeneration = 0

    init(remote: MediaRemote? = MediaRemote.load(), now: @escaping () -> Date = Date.init) {
        self.remote = remote
        self.now = now
        queue.setSpecific(key: Self.queueKey, value: ())
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        timer?.cancel()
    }

    func start(update: @escaping (MediaSessionState) -> Void) {
        queue.async { [self] in
            self.update = update
            guard let remote else {
                update(MediaSessionState())
                return
            }
            remote.register(queue)
            for name in remote.notificationNames {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                    self?.queue.async { self?.fetch() }
                })
            }
            publish()
            fetch()
        }
    }

    func stop() {
        let work = { [self] in
            update = nil
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            timer?.cancel()
            timer = nil
            remote?.unregister()
        }
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil { work() } else { queue.sync(execute: work) }
    }

    private static let queueKey = DispatchSpecificKey<Void>()

    // MARK: - Fetching (on `queue`)

    private func fetch() {
        guard let remote, update != nil else { return }
        fetchGeneration += 1
        let generation = fetchGeneration
        remote.getNowPlayingInfo(queue) { [weak self] dictionary in
            guard let self, generation == self.fetchGeneration else { return }
            self.info = (dictionary as? [String: Any]) ?? [:]
            remote.getIsPlaying(self.queue) { [weak self] playing in
                guard let self, generation == self.fetchGeneration else { return }
                self.isPlaying = playing
                self.publish()
            }
        }
    }

    private func publish() {
        guard let update else { return }
        let colors = artworkColors()
        let state = Self.state(from: info, isPlaying: isPlaying, enabled: remote != nil, now: now(),
                               artwork: colors.map { ($0.key, $0.colors) })
        update(state)
        scheduleTimeline(running: state.playback == .playing && state.timeline.duration > 0)
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
