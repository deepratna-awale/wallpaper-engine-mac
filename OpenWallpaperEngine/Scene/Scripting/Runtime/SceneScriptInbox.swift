import Foundation

/// The one thread-safe entry into a `SceneScriptRuntime`: property changes, resizes, media and
/// cursor events are posted from any thread and drained by the runtime at the start of a frame.
/// `lock` guards `events`.
final class SceneScriptInbox: @unchecked Sendable {
    /// Past this many undrained events (a runtime that stopped rendering), the oldest are dropped.
    static let capacity = 1024

    private let lock = NSLock()
    private var events: [SceneScriptEvent] = []

    func post(_ event: SceneScriptEvent) {
        lock.lock()
        if events.count >= Self.capacity { events.removeFirst(events.count - Self.capacity + 1) }
        events.append(event)
        lock.unlock()
    }

    func drain() -> [SceneScriptEvent] {
        lock.lock()
        defer { lock.unlock() }
        guard !events.isEmpty else { return [] }
        let drained = events
        events.removeAll(keepingCapacity: true)
        return drained
    }
}
