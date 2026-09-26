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
        // The format word comes first, then the flags.
        guard let word = TEXImageFormat.texiWord(1, in: data) else { return nil }
        rawValue = word
    }

    init(rawValue: UInt32) {
        self.rawValue = rawValue
    }
}
