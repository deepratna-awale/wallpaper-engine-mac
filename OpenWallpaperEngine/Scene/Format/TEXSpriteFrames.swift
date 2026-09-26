import Foundation

/// The frame durations of a `.tex` spritesheet, read from its last `TEXS000n` block without
/// decoding the image (the `getTextureAnimation()` a script sees).
enum TEXSpriteFrames {
    /// Each frame's duration in seconds, or nil when the texture has no `TEXS` block.
    static func durations(_ bytes: [UInt8]) -> [Double]? {
        let marker = Array("TEXS000".utf8)
        guard bytes.count > marker.count + 2 else { return nil }
        var found: Int?
        var index = bytes.count - marker.count - 2
        while index >= 0 {
            if bytes[index] == marker[0], Array(bytes[index..<(index + marker.count)]) == marker,
               bytes[index + marker.count + 1] == 0 {
                found = index
                break
            }
            index -= 1
        }
        guard let start = found else { return nil }
        let version = bytes[start + marker.count]
        var cursor = start + marker.count + 2
        func u32() -> UInt32? {
            guard cursor + 4 <= bytes.count else { return nil }
            defer { cursor += 4 }
            var value: UInt32 = 0
            for offset in 0..<4 { value |= UInt32(bytes[cursor + offset]) << UInt32(8 * offset) }
            return value
        }
        guard let count = u32(), count > 0, count < 100_000 else { return nil }
        // TEXS0003 carries the atlas size before the frames.
        if version == UInt8(ascii: "3") { _ = u32(); _ = u32() }
        var durations: [Double] = []
        for _ in 0..<count {
            guard u32() != nil, let bits = u32() else { return nil }
            durations.append(Double(Float(bitPattern: bits)))
            for _ in 0..<6 { guard u32() != nil else { return nil } }
        }
        return durations
    }
}
