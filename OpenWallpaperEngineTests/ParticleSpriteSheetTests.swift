import XCTest
import MetalKit
@testable import OpenWallpaperEngine

/// A particle texture's sprite-sheet grid, from its `.tex-json` sequence and the texture's pixels,
/// and a refracting drop of WE's rain sheet (`particle/water/rain_drops_sheet`, 16 frames of 64 on
/// 256 × 256, RG88 albedo and an RGBA normal map) drawn through the real loader and renderer.
final class ParticleSpriteSheetTests: XCTestCase {
    // MARK: - The grid

    /// The grid counts the image's pixels, not its points: an `NSImage` made from a `CGImage`
    /// reports its representation's `pixelsWide` at the screen's backing scale, which made WE's
    /// rain sheet an 8 × 8 grid on a Retina display and drew a quarter of each frame.
    func testTheSheetCountsTheImagesPixels() throws {
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        for points in [256.0, 128, 512] {
            let image = NSImage(cgImage: bitmap, size: NSSize(width: points, height: points))
            for source in [SceneMetalTextureSource.image(image),
                           .animated(TEXAnimatedImages(images: [image], frames: []))] {
                XCTAssertEqual(source.sheetPixelSize, SIMD2(256, 256), "\(points) points")
            }
        }
        XCTAssertNil(SceneMetalTextureSource.animated(TEXAnimatedImages(images: [], frames: [])).sheetPixelSize)
    }

    func testTheGridFollowsTheSequencesFrameSize() {
        let sheet = SpriteSheet(frames: 16, frameSize: SIMD2(64, 64), duration: 1, textureSize: SIMD2(256, 256))
        XCTAssertEqual([sheet.columns, sheet.rows, sheet.frames], [4, 4, 16])
        // Frames fill the rows first; a short last row still counts.
        let short = SpriteSheet(frames: 7, frameSize: SIMD2(64, 32), duration: 1, textureSize: SIMD2(256, 32))
        XCTAssertEqual([short.columns, short.rows], [4, 2])
    }

    /// WE's rain sheet, loaded for a scene: 4 × 4 frames, a quarter of the texture each.
    func testTheRainSheetLoadsAsFourByFour() throws {
        let content = try content(.enabled)
        let system = try XCTUnwrap(content.particleSystems.first)
        let sheet = try XCTUnwrap(system.spriteSheet)
        XCTAssertEqual([sheet.columns, sheet.rows, sheet.frames], [4, 4, 16])
        XCTAssertEqual(system.material?.spriteSheet?.columns, 4, "the material draws the same grid")
    }

    // MARK: - The drawn drop

    /// One drop (frame 0, a 100-unit sprite tinted red) over a 0.6 grey layer. WE draws the
    /// albedo's luminance (white) times the colour times the refracted scene, with the albedo's
    /// alpha: a red-tinted copy of the grey, the frame's whole blob and nothing else of its quad.
    func testARefractingDropShowsItsWholeFrameOfTheRefractedScene() throws {
        for quality in [GSPostProcessingQuality.enabled, .ultra] {
            let pixels = try render(quality)
            let drop = pixels.points { $0.x > $0.y + 60 }
            XCTAssertFalse(drop.isEmpty, "\(quality): the drop is drawn")
            guard !drop.isEmpty else { continue }
            // Frame 0's blob spans x 10…52 and y 16…48 of its 64 pixels: on the 100-unit quad
            // around (128, 128), x 94…159 and y 103…153, with a clear margin on every side.
            let low = drop.reduce(SIMD2(Int.max, Int.max)) { simd_min($0, $1.point) }
            let high = drop.reduce(SIMD2(Int.min, Int.min)) { simd_max($0, $1.point) }
            XCTAssertEqual(Double(low.x), 94, accuracy: 4, "\(quality): the blob's left edge")
            XCTAssertEqual(Double(high.x), 159, accuracy: 4, "\(quality): its right edge, not the quad's")
            XCTAssertEqual(Double(low.y), 103, accuracy: 4, "\(quality): its top edge")
            XCTAssertEqual(Double(high.y), 153, accuracy: 4, "\(quality): its bottom edge, not the quad's")
            XCTAssertTrue(drop.contains { $0.point == SIMD2(128, 128) }, "\(quality): the blob covers the centre")
            // Inside the blob (its edge pixels aside, which blend with the layer) the refracted
            // grey shows at full strength through the red tint: the drop is the scene seen
            // through water, not a dark shape.
            let inside = drop.filter { $0.color.y < 20 }
            XCTAssertGreaterThan(Double(inside.count) / Double(drop.count), 0.85, "\(quality): mostly covered")
            let reds = inside.map { Int($0.color.x) }
            XCTAssertEqual(reds.min() ?? 0, 153, accuracy: 6, "\(quality): the refracted grey, at its darkest")
            XCTAssertEqual(reds.max() ?? 0, 153, accuracy: 6, "\(quality): and its brightest")
        }
    }

    // MARK: - Helpers

    private static let size = 256
    private let directory = Fixtures.url("Scenes/particle-rain-sheet")

    override func tearDownWithError() throws {
        Fixtures.removeStoredSettings(for: directory)
    }

    private struct Pixels {
        struct Sample {
            let point: SIMD2<Int>
            let color: SIMD3<UInt8>
        }

        let bytes: [UInt8]

        /// Every pixel (y down) whose (r, g, b) passes `test`.
        func points(where test: (SIMD3<Int>) -> Bool) -> [Sample] {
            var result: [Sample] = []
            for y in 0..<ParticleSpriteSheetTests.size {
                for x in 0..<ParticleSpriteSheetTests.size {
                    let i = (y * ParticleSpriteSheetTests.size + x) * 4
                    let color = SIMD3(bytes[i + 2], bytes[i + 1], bytes[i])
                    if test(SIMD3<Int>(truncatingIfNeeded: color)) { result.append(Sample(point: SIMD2(x, y), color: color)) }
                }
            }
            return result
        }
    }

    private func content(_ postProcessing: GSPostProcessingQuality) throws -> SceneMetalContent {
        let project = try JSONDecoder().decode(WEProject.self, from: Data(contentsOf: directory.appending(path: "project.json")))
        let model = SceneWallpaperViewModel(wallpaper: WEWallpaper(using: project, where: directory))
        var settings = SceneRenderSettings()
        settings.postProcessing = postProcessing
        model.setRenderSettings(settings)
        return try XCTUnwrap(model.metalContent())
    }

    /// The fixture drawn under `postProcessing` until the drop shows (its pipelines compile off
    /// the render thread); the last frame's drawable.
    private func render(_ postProcessing: GSPostProcessingQuality) throws -> Pixels {
        let content = try content(postProcessing)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: Self.size, height: Self.size), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: Self.size, height: Self.size)
        let renderer = try XCTUnwrap(SceneMetalRenderer(view: view, scriptServices: nil, screenID: "rain-sheet"))
        defer { renderer.releaseContent() }
        view.isPaused = true
        renderer.renderSettings.postProcessing = postProcessing
        renderer.setPlacement(.stretch)
        renderer.setContent(content)
        var pixels = Pixels(bytes: [])
        let deadline = Date().addingTimeInterval(30)
        var drawn = 0
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            renderer.draw(in: view)
            renderer.lastCommandBuffer?.waitUntilCompleted()
            guard renderer.hasContent, let texture = view.currentDrawable?.texture else { continue }
            drawn += 1
            var bytes = [UInt8](repeating: 0, count: Self.size * Self.size * 4)
            texture.getBytes(&bytes, bytesPerRow: Self.size * 4, from: MTLRegionMake2D(0, 0, Self.size, Self.size), mipmapLevel: 0)
            pixels = Pixels(bytes: bytes)
        } while (drawn < 3 || pixels.points(where: { $0.x > $0.y + 60 }).isEmpty) && Date() < deadline
        return pixels
    }
}
