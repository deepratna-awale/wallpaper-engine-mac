import AppKit
import CoreText
import simd

/// Lays out a WE text object the way Wallpaper Engine does, in scene units:
/// - the glyph size (em) is `pointsize × 300/72` scene units: WE sets its FreeType face to
///   `pointsize` points at 300 dpi and lays the glyphs out one atlas pixel per scene unit;
/// - text wraps only when `limitwidth` is set (at `maxwidth`), and `limitrows` keeps the first
///   `maxrows` lines, ending in an ellipsis when `limituseellipsis` is set;
/// - nothing is ever shrunk to fit, and nothing is clipped: the block grows to its content;
/// - `padding` is geometry around the glyphs, and a stub `size` (no room inside the padding,
///   e.g. "2 2") means the block is sized to its content.
struct SceneTextLayout {
    struct Line: Equatable {
        let text: String
        let width: CGFloat
    }

    /// The text block (the quad), in unscaled scene units.
    let boxSize: SIMD2<Float>
    let lines: [Line]
    let lineHeight: CGFloat
    let ascent: CGFloat
    let padding: SIMD2<Float>
    let horizontalAlignment: String?
    let verticalAlignment: String?

    /// Width and height of the laid-out glyphs, without padding.
    var contentSize: CGSize {
        CGSize(width: lines.map(\.width).max() ?? 0, height: lineHeight * CGFloat(lines.count))
    }

    /// WE's `FT_Set_Char_Size(face, 0, pointsize × 64, 300, 300)`: the em in scene units.
    static func pixelSize(pointSize: CGFloat) -> CGFloat { pointSize * 300 / 72 }

    /// A `size` with no room inside its padding is a placeholder the editor writes before the
    /// text has content; WE sizes such blocks from the text.
    static func isStub(size: SIMD2<Float>, padding: SIMD2<Float>) -> Bool {
        size.x - padding.x * 2 <= 2 || size.y - padding.y * 2 <= 2
    }

    init(text: String, font: NSFont, authoredSize: SIMD2<Float>, padding: SIMD2<Float>,
         horizontalAlignment: String?, verticalAlignment: String?,
         maxWidth: Float?, maxRows: Int?, useEllipsis: Bool) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        ascent = ceil(font.ascender)
        lineHeight = ceil(font.ascender - font.descender + font.leading)
        self.padding = padding
        self.horizontalAlignment = horizontalAlignment
        self.verticalAlignment = verticalAlignment

        var lines: [String] = []
        for paragraph in text.components(separatedBy: .newlines) {
            if let maxWidth, maxWidth > 0 {
                lines += Self.wrap(paragraph, attributes: attributes, width: CGFloat(maxWidth))
            } else {
                lines.append(paragraph)
            }
        }
        if let maxRows, maxRows > 0, lines.count > maxRows {
            lines = Array(lines.prefix(maxRows))
            if useEllipsis, let last = lines.popLast() {
                lines.append(Self.withEllipsis(last, attributes: attributes, width: maxWidth.map { CGFloat($0) }))
            }
        }
        self.lines = lines.map { Line(text: $0, width: Self.width(of: $0, attributes: attributes)) }

        let content = CGSize(width: self.lines.map(\.width).max() ?? 0, height: lineHeight * CGFloat(self.lines.count))
        let fitted = SIMD2(Float(ceil(content.width)) + padding.x * 2, Float(content.height) + padding.y * 2)
        // WE draws glyph quads, which nothing clips: a block whose text outgrows the size the
        // editor saved (a script's longer string, a user's font) grows around it.
        boxSize = Self.isStub(size: authoredSize, padding: padding) ? fitted : simd_max(authoredSize, fitted)
    }

    /// Where each line's baseline starts, in box coordinates (y-up, origin at the box's
    /// bottom-left). Lines are aligned inside the padding by `horizontalalign`, and the block by
    /// `verticalalign`.
    func baselineOrigins() -> [CGPoint] {
        let box = CGSize(width: CGFloat(boxSize.x), height: CGFloat(boxSize.y))
        let pad = CGSize(width: CGFloat(padding.x), height: CGFloat(padding.y))
        let blockHeight = contentSize.height
        let top: CGFloat
        switch verticalAlignment?.lowercased() {
        case "top": top = box.height - pad.height
        case "bottom": top = pad.height + blockHeight
        default: top = (box.height + blockHeight) / 2
        }
        return lines.enumerated().map { index, line in
            let x: CGFloat
            switch horizontalAlignment?.lowercased() {
            case "left": x = pad.width
            case "right": x = box.width - pad.width - line.width
            default: x = (box.width - line.width) / 2
            }
            return CGPoint(x: x, y: top - CGFloat(index) * lineHeight - ascent)
        }
    }

    /// Draws the block into a new bitmap at `pixelsPerUnit` device pixels per scene unit, so
    /// the glyphs are rasterised at the size they are shown at instead of being upscaled.
    func rasterize(font: NSFont, color: NSColor, pixelsPerUnit: CGFloat) -> CGImage? {
        let width = max(1, Int(ceil(CGFloat(boxSize.x) * pixelsPerUnit)))
        let height = max(1, Int(ceil(CGFloat(boxSize.y) * pixelsPerUnit)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setShouldAntialias(true)
        context.setShouldSmoothFonts(false)
        context.scaleBy(x: CGFloat(width) / CGFloat(max(boxSize.x, 0.0001)),
                        y: CGFloat(height) / CGFloat(max(boxSize.y, 0.0001)))
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        for (line, origin) in zip(lines, baselineOrigins()) {
            let ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: line.text, attributes: attributes))
            context.textPosition = origin
            CTLineDraw(ctLine, context)
        }
        return context.makeImage()
    }

    // MARK: - Line breaking

    private static func width(of text: String, attributes: [NSAttributedString.Key: Any]) -> CGFloat {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    private static func wrap(_ paragraph: String, attributes: [NSAttributedString.Key: Any], width: CGFloat) -> [String] {
        guard !paragraph.isEmpty else { return [""] }
        let attributed = NSAttributedString(string: paragraph, attributes: attributes)
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let utf16 = paragraph.utf16
        var lines: [String] = []
        var start = 0
        while start < utf16.count {
            let count = max(1, CTTypesetterSuggestLineBreak(typesetter, start, Double(width)))
            let from = utf16.index(utf16.startIndex, offsetBy: start)
            let to = utf16.index(from, offsetBy: count)
            let line = String(paragraph[from..<to])
            lines.append(line.trimmingCharacters(in: .whitespaces))
            start += count
        }
        return lines
    }

    private static func withEllipsis(_ line: String, attributes: [NSAttributedString.Key: Any], width: CGFloat?) -> String {
        let ellipsis = "\u{2026}"
        var trimmed = line
        while !trimmed.isEmpty,
              let width, Self.width(of: trimmed + ellipsis, attributes: attributes) > width {
            trimmed.removeLast()
        }
        return trimmed.trimmingCharacters(in: .whitespaces) + ellipsis
    }
}

/// How finely text is rasterised: device pixels per scene unit, in quarter-octave steps so an
/// animated scale doesn't re-rasterise every frame, and capped so a block stays a sane texture.
enum SceneTextRasterScale {
    static let maxTextureDimension: Float = 4096

    /// Where a text layer is rasterised: WE draws plain text's glyphs at the display's density
    /// (`onScreen`), but runs a text object's effects in buffers of its size, one pixel a scene
    /// unit (its `font` material has no texture: `wallpaper64.exe` 0x140209206…0x14020923c).
    static func layer(onScreen: Float, hasEffects: Bool) -> Float {
        hasEffects ? 1 : onScreen
    }

    static func quantized(_ pixelsPerUnit: Float) -> Float {
        guard pixelsPerUnit.isFinite, pixelsPerUnit > 0 else { return 1 }
        return exp2((log2(pixelsPerUnit) * 4).rounded(.up) / 4)
    }

    /// Text keeps the finest scale it has been rasterised at, so an animated scale re-rasterises
    /// only while it grows past what it has already reached, not at every step up and down.
    static func retained(_ pixelsPerUnit: Float, previous: Float?) -> Float {
        max(pixelsPerUnit, previous ?? 0)
    }

    static func clamped(_ pixelsPerUnit: Float, boxSize: SIMD2<Float>) -> Float {
        let largest = max(boxSize.x, boxSize.y, 1)
        return max(min(pixelsPerUnit, maxTextureDimension / largest), 1 / largest)
    }
}
