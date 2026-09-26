import Foundation

/// A property timeline ready to evaluate: WE's animation object after its load-time transforms
/// (docs/timeline-plan.md §2.2) with its own clock (§2.4).
///
/// Evaluation (§2.3): each channel is sampled at whole frames (`SceneTimelineChannel`) and the
/// value is blended linearly between the two frames around the clock's time. A linked child
/// (`parentKey`) samples its own channels on its parent's clock: pass that clock to `value(on:)`.
struct SceneTimelineAnimation: Equatable {
    /// Why an `animation` object gives no timeline. WE keeps such an animation without channels.
    enum LoadError: Error, Equatable, CustomStringConvertible {
        /// `options` isn't an object, or its `fps` or `length` isn't a number.
        case missingOptions
        /// `fps` ≤ 0, or `length / fps` ≤ 0.
        case invalidTiming(fps: Float, length: Int32)

        var description: String {
            switch self {
            case .missingOptions:
                return "options needs a numeric fps and length"
            case let .invalidTiming(fps, length):
                return "fps \(fps) and length \(length) give no duration"
            }
        }
    }

    /// `c0`, `c1`, …: one per component.
    var channels: [SceneTimelineChannel]
    var clock: SceneTimelineClock
    /// `options.name`, what `getAnimation(name)` finds.
    let name: String?
    /// `options.parent.key`: this animation runs on the clock of the same owner's animation on that property.
    let parentKey: String?

    /// Builds the timeline from its `animation` JSON and the holder's static `value`
    /// (only a string `value` is used, for `relative`).
    init(json: SceneJSON, staticValue: SceneJSON?) throws {
        try self.init(document: SceneTimelineDocument(json: json), staticValue: staticValue)
    }

    init(document: SceneTimelineDocument, staticValue: SceneJSON?) throws {
        guard let options = document.options else { throw LoadError.missingOptions }
        guard let clock = SceneTimelineClock(options: options) else {
            throw LoadError.invalidTiming(fps: options.fps, length: options.length)
        }
        var keyframeLists = document.channels
        if document.isRelative, case .string(let text)? = staticValue,
           let offsets = Self.relativeOffsets(text) {
            for index in keyframeLists.indices where index < 3 {
                for key in keyframeLists[index].indices {
                    keyframeLists[index][key].value += offsets[index]
                }
            }
        }
        if options.wrapLoop {
            for index in keyframeLists.indices {
                Self.wrapLoop(&keyframeLists[index], length: options.length)
            }
        }
        self.channels = keyframeLists.map(SceneTimelineChannel.init(keyframes:))
        self.clock = clock
        self.name = document.name
        self.parentKey = document.parentKey
    }

    // MARK: - Evaluation

    /// This animation's value on its own clock: one component per channel.
    mutating func value() -> [Float] {
        value(on: clock)
    }

    /// This animation's channels sampled at `clock`'s time and length: its own clock, or its
    /// parent's when it is linked.
    mutating func value(on clock: SceneTimelineClock) -> [Float] {
        let position = clock.samplePosition
        return channels.indices.map { index in
            let upper = channels[index].sample(position.frame1)
            let lower = channels[index].sample(position.frame0)
            return upper * position.fraction + lower * (1 - position.fraction)
        }
    }

    // MARK: - Load-time transforms

    /// `relative` (`0x1401a538a`): up to three floats from the static value string, each added to
    /// every keyframe of `c0`…`c2`. WE applies nothing unless the string has at least two spaces
    /// between tokens (three tokens); a token is read by `atof`, so text that isn't a number is 0.
    static func relativeOffsets(_ text: String) -> SIMD3<Float>? {
        var bytes = Array(text.utf8.prefix { $0 != 0 })
        guard !bytes.isEmpty else { return .zero }
        bytes.append(0)
        let space = UInt8(ascii: " ")
        var index = 0
        var offsets = SIMD3<Float>.zero
        for component in 0..<3 {
            offsets[component] = Float(atof(bytes, from: index))
            guard component < 2 else { break }
            while bytes[index] != 0, bytes[index] != space { index += 1 }
            guard bytes[index] == space else { return nil }
            while bytes[index] == space { index += 1 }
        }
        return offsets
    }

    /// C's `atof` in the "C" locale on NUL-terminated bytes: leading whitespace, then the longest
    /// decimal prefix (sign, digits, fraction, exponent); 0 when there is none.
    private static func atof(_ bytes: [UInt8], from start: Int) -> Double {
        func isDigit(_ index: Int) -> Bool { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) }
        var begin = start
        while [9, 10, 11, 12, 13, 32].contains(bytes[begin]) { begin += 1 }
        var end = begin
        if bytes[end] == UInt8(ascii: "+") || bytes[end] == UInt8(ascii: "-") { end += 1 }
        var digits = 0
        while isDigit(end) { end += 1; digits += 1 }
        if bytes[end] == UInt8(ascii: ".") {
            end += 1
            while isDigit(end) { end += 1; digits += 1 }
        }
        guard digits > 0 else { return 0 }
        if bytes[end] == UInt8(ascii: "e") || bytes[end] == UInt8(ascii: "E") {
            var exponent = end + 1
            if bytes[exponent] == UInt8(ascii: "+") || bytes[exponent] == UInt8(ascii: "-") { exponent += 1 }
            if isDigit(exponent) {
                end = exponent
                while isDigit(end) { end += 1 }
            }
        }
        // The prefix is a valid decimal literal, which Double parses with correct rounding.
        return Double(String(decoding: bytes[begin..<end], as: UTF8.self)) ?? 0
    }

    /// The `wraploop` fix-up (`0x1401a98b0`), per channel with at least two keyframes: keyframes
    /// past `length` are dropped from the end (keeping one); a keyframe is appended at `length`
    /// unless the last is there; the last keyframe takes the first one's value, and its back handle
    /// mirrors the first one's front handle when that is enabled, or loses its enabled bit.
    static func wrapLoop(_ keyframes: inout [SceneTimelineDocument.Keyframe], length: Int32) {
        guard keyframes.count > 1 else { return }
        let first = keyframes[0]
        while keyframes.count > 1, keyframes[keyframes.count - 1].frame > length {
            keyframes.removeLast()
        }
        guard keyframes.count > 1 else { return }
        if keyframes[keyframes.count - 1].frame != length {
            keyframes.append(.init(frame: length, value: 0, flags: [], back: .zero, front: .zero))
        }
        let last = keyframes.count - 1
        if first.flags.contains(.front) {
            keyframes[last].flags.insert(.back)
            keyframes[last].back = -first.front
        } else {
            keyframes[last].flags.remove(.back)
        }
        keyframes[last].value = first.value
    }
}
