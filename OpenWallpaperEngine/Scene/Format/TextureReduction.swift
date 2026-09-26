import simd

/// WE's "Texture Resolution" setting (config `resolution`: `full`, `half` or `auto`), as
/// `wallpaper64.exe` applies it.
///
/// - The setting sets engine flag 0x20 (`half`) or 0x10 (`auto`) (0x1401155f6…0x14011562f). At scene
///   load the engine's reduction is 1 + (whether to reduce) (0x140187e3c), and whether to reduce is
///   (0x14017e6f0): never with `full`, always with `half`, and with `auto` when the window is under
///   0.95 × 1920 × 1080 = 1 969 920 pixels (0x140492970).
/// - With a reduction over 1 the `.tex` loader skips the first mipmap of every image stored with
///   more than one (0x14015d3fd, load flag 2 from 0x1400ec44e); a texture with one mipmap loads
///   whole. The texture keeps its header's sizes, so a layer sized by its image keeps its size.
/// - A layer's effect buffers are its image's size (a composite or solid layer's own size) over the
///   reduction, except a fullscreen layer's (0x1402092c0…0x14020933c); WE's buffers then match the
///   halved image. `g_TextureReductionScale` is the reduction (0x1400d9958), which shaders that
///   offset vertices in texels multiply back (`effects/skew`).
enum TextureReduction {
    /// Below this many window pixels, `auto` reduces (0x140492970: 0.95 × 1920 × 1080).
    static let automaticPixelThreshold: Float = 1_969_920

    /// The engine's reduction for `setting` on an output of `outputPixels` (the largest display's
    /// drawable): 1 or 2.
    static func factor(_ setting: GSTextureResolutionQuality, outputPixels: SIMD2<Float>) -> Int {
        switch setting {
        case .highQuality: return 1
        case .highPerformance: return 2
        case .automatic:
            let area = outputPixels.x * outputPixels.y
            // No display known yet: WE's window always has a size; full resolution until one does.
            guard area > 0 else { return 1 }
            return area < automaticPixelThreshold ? 2 : 1
        }
    }

    /// The mipmap WE loads of an image stored with `mipmapCount` mipmaps: the second under a
    /// reduction when there is one, else the first.
    static func loadedMipmap(reduction: Int, mipmapCount: Int) -> Int {
        reduction > 1 && mipmapCount > 1 ? 1 : 0
    }

    /// A side of `side` pixels at mipmap `level`: halved per level, rounded down, at least 1 (the
    /// library's `.tex` files store 2760 × 4466 → 1380 × 2233 → 690 × 1116).
    static func mipmapSide(_ side: Int, level: Int) -> Int {
        max(1, side >> max(level, 0))
    }
}
