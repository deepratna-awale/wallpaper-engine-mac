import Foundation

/// One component's keyframes and WE's per-frame sampler (`0x1401a9bc0`, docs/timeline-plan.md §2.3).
///
/// `S(n)` is evaluated at integer frames only and cached: the cache grows lazily up to the highest
/// frame asked for, so a channel costs its Bézier solves once. All arithmetic is float32, in WE's
/// operation order.
struct SceneTimelineChannel: Equatable {
    typealias Keyframe = SceneTimelineDocument.Keyframe

    let keyframes: [Keyframe]
    private var cache: [Float] = []

    init(keyframes: [Keyframe]) {
        self.keyframes = keyframes
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.keyframes == rhs.keyframes
    }

    /// `S(frame)`, cached.
    mutating func sample(_ frame: Int32) -> Float {
        guard frame >= 0 else { return Self.evaluate(keyframes, at: frame) }
        let index = Int(frame)
        if index < cache.count { return cache[index] }
        cache.reserveCapacity(index + 1)
        for missing in cache.count...index {
            cache.append(Self.evaluate(keyframes, at: Int32(missing)))
        }
        return cache[index]
    }

    /// `S(n)` without the cache:
    /// - no keyframes → 0; before or at the first → its value; at or after the last → its value;
    /// - at a keyframe, or when the later keyframe is a `step` → the earlier value;
    /// - otherwise a cubic Bézier between the two keyframes, solved for x = n by bisection.
    static func evaluate(_ keyframes: [Keyframe], at frame: Int32) -> Float {
        guard let first = keyframes.first else { return 0 }
        if frame <= first.frame { return first.value }
        for index in 1..<max(keyframes.count, 1) {
            let previous = keyframes[index - 1]
            let next = keyframes[index]
            guard previous.frame <= frame, frame < next.frame else { continue }
            if previous.frame == frame || next.flags.contains(.step) { return previous.value }
            return bezier(from: previous, to: next, at: frame)
        }
        return keyframes[keyframes.count - 1].value
    }

    /// The segment's Bézier: x control points `p.frame`, `p.frame + h·p.front.x`,
    /// `q.frame + h·q.back.x`, `q.frame` with `h = (q.frame − p.frame) / 2`; y control points
    /// `p.value`, `p.value + p.front.y`, `q.value + q.back.y`, `q.value`.
    private static func bezier(from p: Keyframe, to q: Keyframe, at frame: Int32) -> Float {
        let half = Float(q.frame &- p.frame) * 0.5
        let x0 = Float(p.frame)
        let x1 = half * p.front.x + x0
        let x2 = half * q.back.x + Float(q.frame)
        let x3 = Float(q.frame)
        let target = Float(frame)

        var t: Float = 0
        var step: Float = 0.999
        for _ in 0..<1000 {
            let x = cubic(x0, x1, x2, x3, t)
            // WE compares the float distance, widened to double, against the double 0.01.
            if Double(abs(x - target)) < 0.01 { break }
            step *= 0.5
            if x > target { t -= step } else { t += step }
        }
        t = t < 1 ? t : 1
        if 0 > t { t = 0 }
        return cubic(p.value, p.value + p.front.y, q.value + q.back.y, q.value, t)
    }

    /// `u³·a + 3u²t·b + 3ut²·c + t³·d`, u = 1 − t, grouped and summed as WE does.
    private static func cubic(_ a: Float, _ b: Float, _ c: Float, _ d: Float, _ t: Float) -> Float {
        let u = 1 - t
        let uuu = u * u * u
        let uut3 = 3 * u * u * t
        let utt3 = 3 * u * t * t
        let ttt = t * t * t
        var sum = uuu * a
        sum += uut3 * b
        sum += utt3 * c
        sum += ttt * d
        return sum
    }
}
