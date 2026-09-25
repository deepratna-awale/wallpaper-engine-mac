import Foundation

/// The system's now-playing session, for SceneScript's media events (docs/scenescript-plan.md
/// WP6). `MacMediaSessionSource` reads it from macOS; tests use a fake.
protocol MediaSessionSource: AnyObject {
    /// Starts reporting. `update` receives the whole state whenever it may have changed, on any
    /// thread, and never concurrently with itself. A source that can't work reports a state with
    /// `enabled == false` (or nothing).
    func start(update: @escaping (MediaSessionState) -> Void)

    /// Stops reporting; no `update` call starts after it returns.
    func stop()
}
