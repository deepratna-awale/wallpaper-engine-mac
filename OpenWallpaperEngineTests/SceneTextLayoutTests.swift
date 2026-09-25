import XCTest
@testable import OpenWallpaperEngine

/// D1, D2, D4, D6: WE text layout — 96/72 sizing, aligned edge on the origin, stub auto-size,
/// wrapping only under `limitwidth`, row limits with ellipsis, and no shrink-to-fit.
final class SceneTextLayoutTests: XCTestCase {
    private func font(pointSize: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: SceneTextLayout.pixelSize(pointSize: pointSize))
    }

    private func fixtureObject(_ id: Int) throws -> WESceneObject {
        let objects = try JSONDecoder().decode([WESceneObject].self,
                                               from: Fixtures.data("Scenes/text-transforms/objects.json"))
        return try XCTUnwrap(objects.first { $0.id == id })
    }

    private func layout(_ text: String, pointSize: CGFloat = 32, size: SIMD2<Float> = SIMD2(2, 2),
                        padding: SIMD2<Float> = SIMD2(32, 32), horizontal: String? = "center",
                        vertical: String? = "center", maxWidth: Float? = nil, maxRows: Int? = nil,
                        ellipsis: Bool = false) -> SceneTextLayout {
        SceneTextLayout(text: text, font: font(pointSize: pointSize), authoredSize: size, padding: padding,
                        horizontalAlignment: horizontal, verticalAlignment: vertical,
                        maxWidth: maxWidth, maxRows: maxRows, useEllipsis: ellipsis)
    }

    func testPixelSizeIsPointSizeAt96DPI() {
        XCTAssertEqual(SceneTextLayout.pixelSize(pointSize: 32), 42.6667, accuracy: 0.001)
        XCTAssertEqual(SceneTextLayout.pixelSize(pointSize: 72), 96)
    }

    /// 3352730400 'Artist Title' / 'Song Title' author `size "2 2"`: the block is sized from the text.
    func testStubSizeAutoSizesToContent() throws {
        let object = try fixtureObject(206)
        let size = try XCTUnwrap(object.size?.parseVector2())
        let authored = SIMD2<Float>(Float(size.0), Float(size.1))
        XCTAssertTrue(SceneTextLayout.isStub(size: authored, padding: SIMD2(32, 32)))
        XCTAssertTrue(SceneTextLayout.isStub(size: SIMD2(66, 66), padding: SIMD2(32, 32)), "empty-content editor size")
        XCTAssertFalse(SceneTextLayout.isStub(size: SIMD2(387, 219), padding: SIMD2(32, 32)))

        let text = layout("Artist Name", pointSize: CGFloat(object.pointsize ?? 0), size: authored,
                          horizontal: object.horizontalalign, maxWidth: object.maxwidth.map(Float.init),
                          maxRows: object.maxrows, ellipsis: true)
        XCTAssertEqual(text.boxSize.x, Float(ceil(text.contentSize.width)) + 64, accuracy: 0.001)
        XCTAssertEqual(text.boxSize.y, Float(text.contentSize.height) + 64, accuracy: 0.001)
        XCTAssertGreaterThan(text.contentSize.width, 20, "the stub must not squeeze the text away")
    }

    func testAuthoredSizeIsKept() {
        XCTAssertEqual(layout("12:34", size: SIMD2(387, 219)).boxSize, SIMD2(387, 219))
    }

    /// The block edge named by horizontalalign/verticalalign sits on the origin.
    func testAlignedEdgeSitsAtOrigin() {
        let box = SIMD2<Float>(300, 120)
        func quad(_ h: String, _ v: String) -> SceneQuadGeometry {
            SceneQuadGeometry(world: .identity, size: box, alignment: SceneAlignment.text(horizontal: h, vertical: v))
        }
        XCTAssertEqual(quad("left", "center").center.x - 150, 0, "left edge at origin")
        XCTAssertEqual(quad("right", "center").center.x + 150, 0, "right edge at origin")
        XCTAssertEqual(quad("center", "center").center, .zero)
        XCTAssertEqual(quad("center", "top").center.y + 60, 0, "top edge at origin")
        XCTAssertEqual(quad("center", "bottom").center.y - 60, 0, "bottom edge at origin")
        XCTAssertEqual(SceneAlignment.text(horizontal: "left", vertical: "top"), "topleft")
        XCTAssertEqual(SceneAlignment.text(horizontal: "center", vertical: "center"), "center")
    }

    /// Lines are placed inside the padding on the aligned side.
    func testLinesAlignInsidePadding() {
        let left = layout("Hi", size: SIMD2(400, 200), horizontal: "left", vertical: "top")
        let origin = try! XCTUnwrap(left.baselineOrigins().first)
        XCTAssertEqual(origin.x, 32)
        XCTAssertEqual(origin.y, 200 - 32 - left.ascent)
        let right = layout("Hi", size: SIMD2(400, 200), horizontal: "right", vertical: "bottom")
        let rightOrigin = try! XCTUnwrap(right.baselineOrigins().first)
        XCTAssertEqual(rightOrigin.x + right.lines[0].width, 400 - 32, accuracy: 0.001)
        XCTAssertEqual(rightOrigin.y, 32 + right.lineHeight - right.ascent, accuracy: 0.001)
    }

    func testNoWrapWithoutLimitWidth() {
        let text = "a fairly long line of text that would wrap if allowed"
        let result = layout(text, size: SIMD2(100, 60), padding: SIMD2(4, 4))
        XCTAssertEqual(result.lines.map(\.text), [text])
        XCTAssertGreaterThan(result.lines[0].width, 100, "no shrink-to-fit: the line keeps its natural width")
        XCTAssertEqual(result.boxSize, SIMD2(100, 60))
    }

    /// 3546971487 'Song Title': limitwidth 471, limitrows 2.
    func testWrapsAtMaxWidthAndLimitsRows() throws {
        let object = try fixtureObject(50)
        let maxWidth = Float(try XCTUnwrap(object.maxwidth))
        let text = String(repeating: "Song title words ", count: 12)
        let wrapped = layout(text, pointSize: 20, size: SIMD2(410, 84), maxWidth: maxWidth)
        XCTAssertGreaterThan(wrapped.lines.count, 2)
        XCTAssertTrue(wrapped.lines.allSatisfy { $0.width <= CGFloat(maxWidth) + 0.5 })

        let limited = layout(text, pointSize: 20, size: SIMD2(410, 84), maxWidth: maxWidth, maxRows: object.maxrows)
        XCTAssertEqual(limited.lines.count, 2)
        XCTAssertFalse(limited.lines.last!.text.hasSuffix("\u{2026}"))

        let ellipsis = layout(text, pointSize: 20, size: SIMD2(410, 84), maxWidth: maxWidth, maxRows: 1, ellipsis: true)
        XCTAssertEqual(ellipsis.lines.count, 1)
        XCTAssertTrue(ellipsis.lines[0].text.hasSuffix("\u{2026}"))
        XCTAssertLessThanOrEqual(ellipsis.lines[0].width, CGFloat(maxWidth) + 0.5)
    }

    func testExplicitNewlinesMakeRows() {
        XCTAssertEqual(layout("OUR JOURNEY IS\nTO THE STARS").lines.map(\.text), ["OUR JOURNEY IS", "TO THE STARS"])
    }

    func testRasterisesAtRequestedPixelScale() throws {
        let result = layout("12:34", size: SIMD2(387, 219))
        let image = try XCTUnwrap(result.rasterize(font: font(pointSize: 32), color: .white, pixelsPerUnit: 2))
        XCTAssertEqual(image.width, 774)
        XCTAssertEqual(image.height, 438)
        XCTAssertEqual(SceneTextRasterScale.quantized(1.3), exp2(Float(0.5)), accuracy: 0.0001)
        XCTAssertEqual(SceneTextRasterScale.clamped(100, boxSize: SIMD2(1000, 10)), 4.096, accuracy: 0.0001)
    }
}
