import Foundation

/// A wallpaper's own clock: seconds since its scene loaded, advanced by each frame's wall-clock
/// delta times the playback speed. Changing the speed changes how fast time runs from then on,
/// never where it is, so animations don't jump. Every consumer of scene time (keyframe
/// animations, `g_Time`, particles, scripts) reads this one clock.
struct SceneClock {
    /// Frames further apart than this (a stall, a sleep) advance the clock by this much only.
    static let maximumFrameDelta = 0.25

    /// Scene seconds since load, speed applied.
    private(set) var time: Double = 0
    /// Scene seconds the last frame advanced by, speed applied.
    private(set) var delta: Double = 0
    private var lastWallTime: Double?

    /// Advances to `wallTime` (e.g. `CACurrentMediaTime()`) at `speed`. The first call only
    /// anchors the clock.
    mutating func advance(to wallTime: Double, speed: Double) {
        defer { lastWallTime = wallTime }
        guard let lastWallTime else { delta = 0; return }
        let realDelta = min(max(wallTime - lastWallTime, 0), Self.maximumFrameDelta)
        let speed = speed.isFinite ? max(speed, 0) : 1
        delta = realDelta * speed
        time += delta
    }
}
