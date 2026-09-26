import Foundation

/// The `format` word of a `.tex` file's `TEXI` header. Its values are the shaders' `FORMAT_*`
/// constants (`common_fragment.h`), which WE passes to a shader as `TEX<n>FORMAT`.
struct TEXImageFormat: RawRepresentable, Equatable {
    let rawValue: UInt32

    init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Reads the format from a `.tex` file. Nil when the data isn't a `.tex`.
    init?(texData data: Data) {
        guard let word = Self.texiWord(0, in: data) else { return nil }
        rawValue = word
    }

    /// Two 8-bit channels (`FORMAT_RG88`), loaded as (r, g, 0, 1) like the GPU samples them.
    static let rg88 = TEXImageFormat(rawValue: 8)

    /// One 8-bit channel (`FORMAT_R8`), loaded as (r, 0, 0, 1) like the GPU samples it.
    static let r8 = TEXImageFormat(rawValue: 9)

    /// Loaded with fewer channels than RGBA, as the GPU samples them (`rg88`, `r8`): a shader
    /// that reads them as colour converts them by `TEX<n>FORMAT`.
    var isChannelReduced: Bool { self == .rg88 || self == .r8 }

    /// Block-compressed formats (ETC, DXT, BC7): the GPU samples them exactly as stored, so a
    /// shader may rely on their channel layout. RG88 and R8 load as they sample too
    /// (`isChannelReduced`); the other formats are expanded to RGBA on load (`TEXParser`), and
    /// shaders must see them as `FORMAT_RGBA8888`.
    var isBlockCompressed: Bool {
        (3...7).contains(rawValue) || rawValue == 12
    }

    /// The `index`th 32-bit word after the `TEXI0001` tag of a `.tex` file (`TEXV0005\0TEXI0001\0`,
    /// format, flags…); nil when the data isn't a `.tex`.
    static func texiWord(_ index: Int, in data: Data) -> UInt32? {
        let bytes = [UInt8](data.prefix(64))
        guard let texi = (0..<max(bytes.count - 4, 0)).first(where: { bytes[$0..<$0 + 4] == [0x54, 0x45, 0x58, 0x49] }),
              let end = bytes[texi...].firstIndex(of: 0) else { return nil }
        let offset = end + 1 + 4 * index
        guard offset + 4 <= bytes.count else { return nil }
        return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
}
