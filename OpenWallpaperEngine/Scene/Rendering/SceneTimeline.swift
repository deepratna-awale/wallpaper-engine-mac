import Foundation

/// Evaluates timeline (keyframe) animations of scene object values at a scene time.
enum SceneTimeline {
    static func value(_ animation: WEKeyframeAnimation?, at time: Float, fallback: Float) -> Float {
        guard let keyframes = animation?.keyframes, !keyframes.isEmpty else { return fallback }
        let frame = playhead(animation: animation, time: time, lastFrame: keyframes.last?.frame ?? 0)
        guard let next = keyframes.first(where: { $0.frame >= frame }) else { return Float(keyframes.last!.value) }
        guard let previous = keyframes.last(where: { $0.frame <= frame }), previous.frame != next.frame else { return Float(next.value) }
        let progress = interpolation(Double((frame - previous.frame) / (next.frame - previous.frame)),
                              easing: previous.easing ?? next.easing,
                              bezier: previous.bezier ?? next.bezier,
                              inTangent: next.inTangent, outTangent: previous.outTangent)
        return Float(previous.value + (next.value - previous.value) * progress)
    }

    static func vector3(_ animation: WEVectorKeyframeAnimation?, at time: Float,
                                 fallback: SIMD3<Float>) -> SIMD3<Float> {
        guard let keyframes = animation?.keyframes, !keyframes.isEmpty else { return fallback }
        let frame = playhead(animation: animation, time: time, lastFrame: keyframes.last?.frame ?? 0)
        guard let next = keyframes.first(where: { $0.frame >= frame }) else {
            let value = keyframes.last!.value.vectorValue
            return SIMD3<Float>(Float(value.0), Float(value.1), Float(value.2))
        }
        guard let previous = keyframes.last(where: { $0.frame <= frame }), previous.frame != next.frame else {
            let value = next.value.vectorValue
            return SIMD3<Float>(Float(value.0), Float(value.1), Float(value.2))
        }
        let progress = Float(interpolation((frame - previous.frame) / (next.frame - previous.frame),
                                easing: previous.easing ?? next.easing,
                                bezier: previous.bezier ?? next.bezier,
                                inTangent: next.inTangent, outTangent: previous.outTangent))
        let start = previous.value.vectorValue
        let end = next.value.vectorValue
        return SIMD3<Float>(Float(start.0 + (end.0 - start.0) * Double(progress)),
                            Float(start.1 + (end.1 - start.1) * Double(progress)),
                            Float(start.2 + (end.2 - start.2) * Double(progress)))
    }

    private static func interpolation(_ progress: Double, easing: String?, bezier: [Double]?,
                                       inTangent: Double?, outTangent: Double?) -> Double {
        let value = min(max(progress, 0), 1)
        if let bezier, bezier.count >= 4 {
            return cubicBezier(value, x1: bezier[0], y1: bezier[1], x2: bezier[2], y2: bezier[3])
        }
        if let easing {
            switch easing.lowercased() {
            case "step", "constant": return value < 1 ? 0 : 1
            case "easein": return value * value
            case "easeout": return 1 - (1 - value) * (1 - value)
            case "easeinout", "smooth": return value * value * (3 - 2 * value)
            default: break
            }
        }
        if let outTangent, let inTangent {
            let y1 = 1.0 / 3.0 * outTangent
            let y2 = 1.0 - 1.0 / 3.0 * inTangent
            return cubicBezier(value, x1: 1.0 / 3.0, y1: y1, x2: 2.0 / 3.0, y2: y2)
        }
        return value
    }

    private static func cubicBezier(_ x: Double, x1: Double, y1: Double, x2: Double, y2: Double) -> Double {
        var low = 0.0
        var high = 1.0
        for _ in 0..<12 {
            let t = (low + high) / 2
            let estimate = cubic(t, 0, x1, x2, 1)
            if estimate < x { low = t } else { high = t }
        }
        let t = (low + high) / 2
        return cubic(t, 0, y1, y2, 1)
    }

    private static func cubic(_ t: Double, _ p0: Double, _ p1: Double, _ p2: Double, _ p3: Double) -> Double {
        let inverse = 1 - t
        return inverse * inverse * inverse * p0 + 3 * inverse * inverse * t * p1
            + 3 * inverse * t * t * p2 + t * t * t * p3
    }

    private static func playhead<A>(animation: A, time: Float, lastFrame: Double) -> Double {
        let mode: String?
        let duration: Double?
        let startPaused: Bool?
        let wrapLoop: Bool?
        if let scalar = animation as? WEKeyframeAnimation {
            mode = scalar.mode; duration = scalar.duration; startPaused = scalar.startPaused; wrapLoop = scalar.wrapLoop
        } else if let vector = animation as? WEVectorKeyframeAnimation {
            mode = vector.mode; duration = vector.duration; startPaused = vector.startPaused; wrapLoop = vector.wrapLoop
        } else {
            mode = nil; duration = nil; startPaused = nil; wrapLoop = nil
        }
        guard startPaused != true else { return 0 }
        let lengthSeconds = max(duration ?? (lastFrame / 60.0), 0.0001)
        let progress = max(Double(time), 0) / lengthSeconds
        let normalizedMode = mode?.lowercased() ?? "loop"
        let mappedProgress: Double
        switch normalizedMode {
        case "single", "once":
            mappedProgress = min(progress, 1)
        case "mirror", "pingpong":
            let cycle = progress.truncatingRemainder(dividingBy: 2)
            mappedProgress = cycle <= 1 ? cycle : 2 - cycle
        default:
            let looped = progress.truncatingRemainder(dividingBy: 1)
            mappedProgress = wrapLoop == true ? looped : looped
        }
        return mappedProgress * max(lastFrame, 0)
    }
}
