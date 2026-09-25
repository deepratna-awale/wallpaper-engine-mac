import Accelerate
import MetalKit

/// Uploads decoded images the way WE's textures hold them: straight (not premultiplied) alpha,
/// with the stored colour values as they are (no colour management).
///
/// `MTKTextureLoader` copies a `CGImage`'s bytes unchanged. That is right for straight-alpha
/// images, but CoreText output and some decoded files are premultiplied, and WE's shaders and
/// blend modes (`SrcAlpha, InvSrcAlpha`) would apply their alpha a second time, darkening
/// semi-transparent edges. Those are unpremultiplied here first, in their own colour space.
enum SceneTextureUpload {
    static func texture(from image: CGImage, loader: MTKTextureLoader, device: MTLDevice) throws -> MTLTexture {
        guard isPremultiplied(image) else {
            return try loader.newTexture(cgImage: image, options: [MTKTextureLoader.Option.SRGB: false])
        }
        let bytes = try straightRGBA(image)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: image.width,
                                                                  height: image.height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw UploadError.allocation(image.width, image.height)
        }
        bytes.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: image.width * 4)
        }
        return texture
    }

    static func isPremultiplied(_ image: CGImage) -> Bool {
        image.alphaInfo == .premultipliedLast || image.alphaInfo == .premultipliedFirst
    }

    /// The image as tightly packed RGBA8 rows with straight alpha, in its own RGB colour space.
    static func straightRGBA(_ image: CGImage) throws -> [UInt8] {
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpaceCreateDeviceRGB()
        guard let format = vImage_CGImageFormat(bitsPerComponent: 8, bitsPerPixel: 32, colorSpace: space,
                                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
                                                    .union(.byteOrder32Big)) else {
            throw UploadError.unsupported(image.bitsPerPixel)
        }
        var buffer = try vImage_Buffer(cgImage: image, format: format)
        defer { buffer.free() }
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let rowBytes = image.width * 4
        let source = buffer.data.assumingMemoryBound(to: UInt8.self)
        bytes.withUnsafeMutableBytes { destination in
            for row in 0..<image.height {
                (destination.baseAddress! + row * rowBytes).copyMemory(from: source + row * buffer.rowBytes,
                                                                        byteCount: rowBytes)
            }
        }
        return bytes
    }

    enum UploadError: Error, CustomStringConvertible {
        case allocation(Int, Int)
        case unsupported(Int)

        var description: String {
            switch self {
            case let .allocation(width, height): return "could not allocate a \(width)×\(height) texture"
            case let .unsupported(bits): return "no RGBA conversion for a \(bits)-bit image"
            }
        }
    }
}
