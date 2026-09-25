import Foundation

/// MediaRemote's functions, resolved at runtime. Nil from `load()` when the framework or any
/// symbol is missing (logged once, `.info`).
struct MediaRemote {
    typealias Register = @convention(c) (DispatchQueue) -> Void
    typealias Unregister = @convention(c) () -> Void
    typealias GetNowPlayingInfo = @convention(c) (DispatchQueue, @escaping @convention(block) (NSDictionary?) -> Void) -> Void
    typealias GetIsPlaying = @convention(c) (DispatchQueue, @escaping @convention(block) (Bool) -> Void) -> Void

    /// The now-playing dictionary's keys (the constants' values are their names).
    enum Key {
        static let title = "kMRMediaRemoteNowPlayingInfoTitle"
        static let artist = "kMRMediaRemoteNowPlayingInfoArtist"
        static let album = "kMRMediaRemoteNowPlayingInfoAlbum"
        static let albumArtist = "kMRMediaRemoteNowPlayingInfoAlbumArtist"
        static let genre = "kMRMediaRemoteNowPlayingInfoGenre"
        static let mediaType = "kMRMediaRemoteNowPlayingInfoMediaType"
        static let duration = "kMRMediaRemoteNowPlayingInfoDuration"
        static let elapsedTime = "kMRMediaRemoteNowPlayingInfoElapsedTime"
        static let timestamp = "kMRMediaRemoteNowPlayingInfoTimestamp"
        static let playbackRate = "kMRMediaRemoteNowPlayingInfoPlaybackRate"
        static let artworkData = "kMRMediaRemoteNowPlayingInfoArtworkData"
    }

    static let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
    static let notificationSymbols = [
        "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
        "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
        "kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
    ]

    let register: Register
    let unregister: Unregister
    let getNowPlayingInfo: GetNowPlayingInfo
    let getIsPlaying: GetIsPlaying
    let notificationNames: [Notification.Name]

    static func load() -> MediaRemote? {
        guard let handle = dlopen(path, RTLD_LAZY) else {
            OWELog.info(.script, "MediaRemote is unavailable; SceneScript media events are off")
            return nil
        }
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }
        guard let register = symbol("MRMediaRemoteRegisterForNowPlayingNotifications", as: Register.self),
              let unregister = symbol("MRMediaRemoteUnregisterForNowPlayingNotifications", as: Unregister.self),
              let getInfo = symbol("MRMediaRemoteGetNowPlayingInfo", as: GetNowPlayingInfo.self),
              let getIsPlaying = symbol("MRMediaRemoteGetNowPlayingApplicationIsPlaying", as: GetIsPlaying.self) else {
            OWELog.info(.script, "MediaRemote lacks a now-playing function; SceneScript media events are off")
            return nil
        }
        // Each constant is a CFStringRef whose value is (in every release so far) its own name.
        let names = notificationSymbols.map { name -> Notification.Name in
            guard let pointer = dlsym(handle, name) else { return Notification.Name(name) }
            let value = pointer.assumingMemoryBound(to: CFString?.self).pointee
            return Notification.Name(value.map { $0 as String } ?? name)
        }
        return MediaRemote(register: register, unregister: unregister, getNowPlayingInfo: getInfo,
                           getIsPlaying: getIsPlaying, notificationNames: names)
    }
}
