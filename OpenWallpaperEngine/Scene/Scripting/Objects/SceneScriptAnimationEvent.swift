import Foundation

extension SceneScriptEvent.Kind {
    /// `animationEvent(event, value)` on the scripts of the animation's owner
    /// (`objects-animations.js`); payload: `["slot": animationSlot, "name": String, "frame": Double]`.
    static let animationEvent = Self(rawValue: "animationEvent")
}

extension SceneScriptEvent {
    /// A timeline event the clock crossed (docs/timeline-plan.md §3.3), for the animation in
    /// `animationSlot` of the object model's animation buffer. Post it after advancing the clocks
    /// and before `__rt.frame` drains the inbox; it reaches scripts after the frame's media events
    /// and before timers and `update` (§1.9 P1). Events are discrete: a full inbox never merges them.
    static func animationEvent(animationSlot: Int, name: String, frame: Double) -> SceneScriptEvent {
        SceneScriptEvent(kind: .animationEvent, payload: ["slot": animationSlot, "name": name, "frame": frame],
                         coalescing: .keep)
    }
}
