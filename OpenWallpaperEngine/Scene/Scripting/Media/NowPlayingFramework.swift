import Foundation

/// What `MacMediaSessionSource` needs from the system's now-playing service: MediaRemote
/// (`MediaRemote`) in the app, a fake in tests. Registration is process-wide.
protocol NowPlayingFramework {
    /// Posted (on `NotificationCenter.default`) when the now-playing info or state may have changed.
    var notificationNames: [Notification.Name] { get }
    func register(on queue: DispatchQueue)
    func unregister()
    /// The now-playing dictionary (MediaRemote's `kMRMediaRemoteNowPlayingInfo…` keys), on `queue`.
    func nowPlayingInfo(on queue: DispatchQueue, _ handler: @escaping ([String: Any]) -> Void)
    func isPlaying(on queue: DispatchQueue, _ handler: @escaping (Bool) -> Void)
}
