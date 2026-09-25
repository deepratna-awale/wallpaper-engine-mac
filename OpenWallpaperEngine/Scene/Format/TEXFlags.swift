import Foundation

/// The `flags` word of a `.tex` file's `TEXI` header: how WE samples the texture.
struct TEXFlags: OptionSet, Equatable {
    let rawValue: UInt32

    /// Nearest filtering instead of bilinear.
    static let noInterpolation = TEXFlags(rawValue: 1)
    /// Clamp to the edge instead of repeating.
    static let clampUVs = TEXFlags(rawValue: 2)
    /// The texture is a sprite sheet (a `.tex-json` describes its frames).
    static let sprite = TEXFlags(rawValue: 4)

    /// Reads the flags from a `.tex` file (`TEXV0005\0TEXI0001\0`, format, flags…). Nil when the
    /// data isn't a `.tex`.
    init?(texData data: Data) {
        let bytes = [UInt8](data.prefix(64))
        guard let texi = (0..<max(bytes.count - 4, 0)).first(where: { bytes[$0..<$0 + 4] == [0x54, 0x45, 0x58, 0x49] }),
              let end = bytes[texi...].firstIndex(of: 0), end + 9 <= bytes.count else { return nil }
        let offset = end + 1 + 4 // past the name, then the format word
        rawValue = UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    init(rawValue: UInt32) {
        self.rawValue = rawValue
    }
}
