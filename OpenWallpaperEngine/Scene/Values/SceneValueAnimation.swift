import Foundation

/// A keyframed value as WE writes it inside a bound value:
/// `{"animation": {"c0": [{frame, value, back, front, …}], "c1": […], "options": {fps, length, mode, startpaused, wraploop}}}`.
///
/// Each `cN` channel animates one component. `frame` and `length` are in frames at `fps`.
/// Interpolation is linear between keyframes (the renderer's default for layer timelines);
/// the `back`/`front` Bézier handles are not evaluated yet.
struct SceneValueAnimation: Equatable {
    struct Keyframe: Equatable {
        let frame: Double
        let value: Float
    }

    enum Mode: String, Equatable {
        case loop
        case mirror
        case single
    }

    /// One keyframe list per component, index = channel number.
    let channels: [[Keyframe]]
    let fps: Double
    /// Length in frames.
    let length: Double
    let mode: Mode
    let startPaused: Bool
    let wrapLoop: Bool

    /// Parses JSONSerialization output. Returns nil (and logs) when there are no channels.
    init?(json: Any) {
        guard let dictionary = json as? [String: Any] else {
            OWELog.error(.scene, "SceneValueAnimation: expected an object, got \(type(of: json))")
            return nil
        }
        var channels: [[Keyframe]] = []
        var index = 0
        while let raw = dictionary["c\(index)"] {
            guard let list = raw as? [Any] else {
                OWELog.error(.scene, "SceneValueAnimation: channel c\(index) is not an array")
                return nil
            }
            var keyframes: [Keyframe] = []
            for element in list {
                guard let entry = element as? [String: Any],
                      let frame = (entry["frame"] as? NSNumber)?.doubleValue,
                      let value = (entry["value"] as? NSNumber)?.floatValue else {
                    OWELog.error(.scene, "SceneValueAnimation: skipping malformed keyframe in c\(index): \(element)")
                    continue
                }
                keyframes.append(Keyframe(frame: frame, value: value))
            }
            channels.append(keyframes.sorted { $0.frame < $1.frame })
            index += 1
        }
        guard !channels.isEmpty else {
            OWELog.error(.scene, "SceneValueAnimation: no c0 channel in \(dictionary.keys.sorted())")
            return nil
        }
        let options = dictionary["options"] as? [String: Any] ?? [:]
        let fps = (options["fps"] as? NSNumber)?.doubleValue ?? 30
        let lastFrame = channels.compactMap { $0.last?.frame }.max() ?? 0
        let modeName = (options["mode"] as? String)?.lowercased() ?? "loop"
        let mode: Mode
        switch modeName {
        case "loop": mode = .loop
        case "mirror": mode = .mirror
        case "single": mode = .single
        default:
            OWELog.error(.scene, "SceneValueAnimation: unknown mode '\(modeName)', using loop")
            mode = .loop
        }
        self.init(channels: channels,
                  fps: fps > 0 ? fps : 30,
                  length: (options["length"] as? NSNumber)?.doubleValue ?? lastFrame,
                  mode: mode,
                  startPaused: (options["startpaused"] as? NSNumber)?.boolValue ?? false,
                  wrapLoop: (options["wraploop"] as? NSNumber)?.boolValue ?? false)
    }

    init(channels: [[Keyframe]], fps: Double, length: Double, mode: Mode,
         startPaused: Bool, wrapLoop: Bool) {
        self.channels = channels
        self.fps = fps
        self.length = length
        self.mode = mode
        self.startPaused = startPaused
        self.wrapLoop = wrapLoop
    }

    /// The value at `time` seconds since the scene started.
    func value(at time: Double) -> ShaderValue {
        let frame = timelineFrame(at: time)
        return ShaderValue(components: channels.map { sample($0, at: frame) })
    }

    private func timelineFrame(at time: Double) -> Double {
        guard !startPaused, length > 0 else { return 0 }
        let frame = max(time, 0) * fps
        switch mode {
        case .single:
            return min(frame, length)
        case .loop:
            return frame.truncatingRemainder(dividingBy: length)
        case .mirror:
            let cycle = frame.truncatingRemainder(dividingBy: 2 * length)
            return cycle <= length ? cycle : 2 * length - cycle
        }
    }

    private func sample(_ keyframes: [Keyframe], at frame: Double) -> Float {
        guard let first = keyframes.first, let last = keyframes.last else { return 0 }
        if let next = keyframes.first(where: { $0.frame >= frame }) {
            guard let previous = keyframes.last(where: { $0.frame <= frame }) else {
                // Before the first keyframe: wrap from the last one when looping with wraploop.
                if mode == .loop, wrapLoop, last.frame > first.frame {
                    return interpolate(last, Keyframe(frame: first.frame + length, value: first.value),
                                       at: frame + length)
                }
                return next.value
            }
            return interpolate(previous, next, at: frame)
        }
        // Past the last keyframe.
        if mode == .loop, wrapLoop, length > last.frame {
            return interpolate(last, Keyframe(frame: first.frame + length, value: first.value), at: frame)
        }
        return last.value
    }

    private func interpolate(_ a: Keyframe, _ b: Keyframe, at frame: Double) -> Float {
        guard b.frame > a.frame else { return b.value }
        let t = Float(min(max((frame - a.frame) / (b.frame - a.frame), 0), 1))
        return a.value + (b.value - a.value) * t
    }
}
