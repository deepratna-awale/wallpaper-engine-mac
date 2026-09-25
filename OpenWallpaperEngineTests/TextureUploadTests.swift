import XCTest
import MetalKit
import ImageIO
import UniformTypeIdentifiers
@testable import OpenWallpaperEngine

/// Risks I1, I7, I18 and I19: what the renderer's textures hold. WE's textures are straight alpha
/// with their stored colour values; its blends (`SrcAlpha, InvSrcAlpha`) apply alpha once.
final class TextureUploadTests: XCTestCase {
    private var device: MTLDevice!
    private var loader: MTKTextureLoader!

    override func setUpWithError() throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        loader = MTKTextureLoader(device: device)
    }

    private func texels(_ image: CGImage) throws -> [UInt8] {
        let texture = try SceneTextureUpload.texture(from: image, loader: loader, device: device)
        XCTAssertEqual(texture.width, image.width)
        XCTAssertEqual(texture.height, image.height)
        return try Self.read(texture, device: device)
    }

    /// RGBA bytes of any 8-bit colour texture (BGRA ones are swizzled back).
    static func read(_ texture: MTLTexture, device: MTLDevice) throws -> [UInt8] {
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let rowBytes = texture.width * 4
        let buffer = try XCTUnwrap(device.makeBuffer(length: rowBytes * texture.height, options: .storageModeShared))
        let commands = try XCTUnwrap(queue.makeCommandBuffer())
        let blit = try XCTUnwrap(commands.makeBlitCommandEncoder())
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1), to: buffer,
                  destinationOffset: 0, destinationBytesPerRow: rowBytes, destinationBytesPerImage: rowBytes * texture.height)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        var bytes = [UInt8](UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: UInt8.self), count: buffer.length))
        if texture.pixelFormat == .bgra8Unorm {
            for index in stride(from: 0, to: bytes.count, by: 4) { bytes.swapAt(index, index + 2) }
        }
        return bytes
    }

    private func image(_ pixels: [UInt8], width: Int, alpha: CGImageAlphaInfo,
                       space: CGColorSpace = CGColorSpaceCreateDeviceRGB()) throws -> CGImage {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: pixels.count / 4 / width, bitsPerComponent: 8, bitsPerPixel: 32,
                                     bytesPerRow: width * 4, space: space,
                                     bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue).union(.byteOrder32Big),
                                     provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func assertBytes(_ actual: ArraySlice<UInt8>, _ expected: [UInt8], tolerance: Int = 1, _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        let delta = zip(actual, expected).map { abs(Int($0) - Int($1)) }.max() ?? 0
        XCTAssertLessThanOrEqual(delta, tolerance, "\(Array(actual)) vs \(expected) \(message)", file: file, line: line)
    }

    /// Straight-alpha images (the `.tex` decoders' output) upload unchanged, colour space ignored.
    func testStraightAlphaImagesUploadAsStored() throws {
        let pixels: [UInt8] = [255, 0, 0, 128, 0, 255, 0, 64, 10, 20, 30, 255, 200, 100, 50, 0]
        for space in [CGColorSpaceCreateDeviceRGB(), CGColorSpace(name: CGColorSpace.displayP3)!] {
            XCTAssertEqual(try texels(image(pixels, width: 2, alpha: .last, space: space)), pixels)
        }
    }

    /// Premultiplied images (CoreText, AppKit drawing) are unpremultiplied, so a half-transparent
    /// red texel is red at alpha 0.5, not dark red that the blend would darken again.
    func testPremultipliedImagesUploadWithStraightAlpha() throws {
        let premultiplied: [UInt8] = [128, 0, 0, 128, 0, 64, 0, 64, 10, 20, 30, 255, 0, 0, 0, 0]
        let bytes = try texels(image(premultiplied, width: 2, alpha: .premultipliedLast))
        assertBytes(bytes[0..<4], [255, 0, 0, 128])
        assertBytes(bytes[4..<8], [0, 255, 0, 64], tolerance: 2)
        assertBytes(bytes[8..<12], [10, 20, 30, 255])
        XCTAssertEqual(bytes[15], 0)
    }

    /// A PNG with a 50%-alpha region, decoded the way wallpaper images are (`NSImage(data:)`),
    /// samples its stored straight colour.
    func testDecodedPNGKeepsItsStraightColour() throws {
        let straight: [UInt8] = [200, 100, 50, 128, 200, 100, 50, 128, 200, 100, 50, 128, 200, 100, 50, 128]
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try image(straight, width: 2, alpha: .last), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let decoded = try XCTUnwrap(NSImage(data: data as Data)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let bytes = try texels(decoded)
        assertBytes(bytes[0..<4], [200, 100, 50, 128], tolerance: 2)
    }

    /// Solid layers bake their colour into a 1x1 image: the texel must be the authored value, not
    /// that colour converted into the display's colour space.
    func testSolidLayerImageHoldsTheAuthoredColour() throws {
        let solid = SceneWallpaperViewModel.solidImage(red: 0.2, green: 0.4, blue: 0.6)
        let cgImage = try XCTUnwrap(solid.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let bytes = try texels(cgImage)
        assertBytes(bytes[0..<4], [51, 102, 153, 255], tolerance: 0)
    }

    /// Text keeps its colour to the edge of each glyph: antialiased pixels differ in alpha only
    /// (WE's font shader draws `g_Color4` at the glyph's coverage).
    func testTextEdgesKeepTheTextColour() throws {
        let font = NSFont.systemFont(ofSize: 40)
        let layout = SceneTextLayout(text: "Ol", font: font, authoredSize: SIMD2(0, 0), padding: SIMD2(4, 4),
                                     horizontalAlignment: nil, verticalAlignment: nil, maxWidth: nil, maxRows: nil,
                                     useEllipsis: false)
        let color = NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1)
        let raster = try XCTUnwrap(layout.rasterize(font: font, color: color, pixelsPerUnit: 1))
        let bytes = try texels(raster)
        var edges = 0
        for index in stride(from: 0, to: bytes.count, by: 4) where bytes[index + 3] >= 24 {
            if bytes[index + 3] < 230 { edges += 1 }
            assertBytes(bytes[index..<index + 3], [255, 128, 0], tolerance: 12, "alpha \(bytes[index + 3])")
        }
        XCTAssertGreaterThan(edges, 10, "the glyphs have antialiased edges")
    }
}
