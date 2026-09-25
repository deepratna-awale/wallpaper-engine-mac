//
//  TEXParser.swift
//  Open Wallpaper Engine
//
//  Parse Wallpaper Engine TEXV texture container files.
//  Structure: TEXV0005 > TEXI (metadata) > TEXB (image data).
//  Currently supports JPEG (format 0) extraction only.
//

import Cocoa
import Compression
import Foundation
import AVFoundation

struct TEXMetadata {
    let format: UInt32
    let width: UInt32
    let height: UInt32
    let textureWidth: UInt32  // power-of-2 padded
    let textureHeight: UInt32
}

struct TEXAnimatedImages {
    let images: [NSImage]
    let frames: [TEXAnimationFrame]
}

struct TEXAnimationFrame {
    let imageIndex: Int
    let duration: Float
    let x: Float
    let y: Float
    let width: Float
    let widthY: Float
    let heightX: Float
    let height: Float
}

struct TEXCompressedTexture {
    let format: UInt32
    /// Allocated (block/power-of-two padded) size of the stored mipmap.
    let width: Int
    let height: Int
    let data: [UInt8]
    /// The image's own size inside the allocation (the header's image width/height).
    var contentWidth: Int
    var contentHeight: Int
}

class TEXParser {
    private let data: Data

    /// Callers try several extract* methods on the same parser, so materialise the byte view once
    /// rather than copying the whole file per attempt.
    private lazy var bytes: [UInt8] = [UInt8](data)

    init(data: Data) {
        self.data = data
    }

    func extractAnimatedImages() -> TEXAnimatedImages? {
        var cursor = 0
        guard readNullTerminatedString(from: bytes, cursor: &cursor) == "TEXV0005",
              readNullTerminatedString(from: bytes, cursor: &cursor) == "TEXI0001",
              let format = readUInt32(from: bytes, cursor: &cursor),
              readUInt32(from: bytes, cursor: &cursor) != nil,
              readUInt32(from: bytes, cursor: &cursor) != nil,
              readUInt32(from: bytes, cursor: &cursor) != nil,
              let imageWidth = readUInt32(from: bytes, cursor: &cursor),
              let imageHeight = readUInt32(from: bytes, cursor: &cursor),
              readUInt32(from: bytes, cursor: &cursor) != nil,
              let container = readNullTerminatedString(from: bytes, cursor: &cursor),
              let imageCount = readUInt32(from: bytes, cursor: &cursor), imageCount > 0 else { return nil }

        let version: Int
        var usesConditionalMipmapLayout = false
        switch container {
        case "TEXB0001": version = 1
        case "TEXB0002": version = 2
        case "TEXB0003":
            version = 3
            guard readUInt32(from: bytes, cursor: &cursor) != nil else { return nil }
        case "TEXB0004":
            version = 3
            guard let freeImageFormat = readUInt32(from: bytes, cursor: &cursor),
                  let isVideoFlag = readUInt32(from: bytes, cursor: &cursor) else { return nil }
            usesConditionalMipmapLayout = isConditionalVideoFormat(freeImageFormat, isVideoFlag: isVideoFlag)
        default: return nil
        }

        var imagePayloads: [(stored: [UInt8], compression: UInt32, uncompressedSize: Int, width: Int, height: Int)] = []
        for _ in 0..<imageCount {
            guard let mipmapCount = readUInt32(from: bytes, cursor: &cursor), mipmapCount > 0 else { return nil }
            var firstPayload: (stored: [UInt8], compression: UInt32, uncompressedSize: Int, width: Int, height: Int)?
            for level in 0..<mipmapCount {
                if usesConditionalMipmapLayout {
                    guard readV4ConditionalPreamble(from: bytes, cursor: &cursor) else { return nil }
                }
                guard let width = readUInt32(from: bytes, cursor: &cursor),
                      let height = readUInt32(from: bytes, cursor: &cursor) else { return nil }
                let compression: UInt32
                let uncompressedSize: Int
                if version == 1 {
                    compression = 0
                    uncompressedSize = 0
                } else {
                    guard let value = readUInt32(from: bytes, cursor: &cursor),
                          let size = readUInt32(from: bytes, cursor: &cursor) else { return nil }
                    compression = value
                    uncompressedSize = Int(size)
                }
                guard let storedSize = readUInt32(from: bytes, cursor: &cursor),
                      Int(storedSize) <= bytes.count - cursor else { return nil }
                let stored = Array(bytes[cursor..<(cursor + Int(storedSize))])
                cursor += Int(storedSize)
                guard level == 0 else { continue }
                firstPayload = (stored, compression, uncompressedSize, Int(width), Int(height))
            }
            guard let firstPayload else { return nil }
            imagePayloads.append(firstPayload)
        }

        guard let marker = readNullTerminatedString(from: bytes, cursor: &cursor), marker.hasPrefix("TEXS"),
              let frameCount = readUInt32(from: bytes, cursor: &cursor), frameCount > 0 else { return nil }
        if marker == "TEXS0003" {
            guard readUInt32(from: bytes, cursor: &cursor) != nil,
                  readUInt32(from: bytes, cursor: &cursor) != nil else { return nil }
        }
        let images = imagePayloads.compactMap { item -> NSImage? in
            let payload = item.compression == 0 ? item.stored
                : item.compression == 1 ? decompressLZ4(item.stored, uncompressedSize: item.uncompressedSize) : []
            if format == 4 || format == 6 || format == 7 {
                return decodeDXT(payload, format: format, width: item.width, height: item.height,
                                 visibleWidth: min(Int(imageWidth), item.width), visibleHeight: min(Int(imageHeight), item.height))
            }
            if let image = rawChannelImage(payload, format: format, width: item.width, height: item.height,
                                           visibleWidth: item.width, visibleHeight: item.height) {
                return image
            }
            // Spritesheet atlases must keep their full padded dimensions; TEXS frame rects are defined in that space.
            return NSImage(data: Data(payload))
                ?? posterImage(fromVideoData: Data(payload))
                ?? rawRGBAImage(payload, width: item.width, height: item.height,
                                visibleWidth: item.width, visibleHeight: item.height)
        }
        guard images.count == imagePayloads.count else { return nil }
        var frames: [TEXAnimationFrame] = []
        for _ in 0..<frameCount {
            guard let frameNumber = readUInt32(from: bytes, cursor: &cursor),
                  let durationBits = readUInt32(from: bytes, cursor: &cursor) else { return nil }
            let duration = Float(bitPattern: durationBits)
            let x: Float
            let y: Float
            let width: Float
            let widthY: Float
            let heightX: Float
            let height: Float
            if marker == "TEXS0001" {
                guard let rawX = readUInt32(from: bytes, cursor: &cursor),
                      let rawY = readUInt32(from: bytes, cursor: &cursor),
                      let rawWidth = readUInt32(from: bytes, cursor: &cursor),
                      let rawWidthY = readUInt32(from: bytes, cursor: &cursor),
                      let rawHeightX = readUInt32(from: bytes, cursor: &cursor),
                      let rawHeight = readUInt32(from: bytes, cursor: &cursor) else { return nil }
                x = Float(rawX); y = Float(rawY); width = Float(rawWidth); height = Float(rawHeight)
                widthY = Float(rawWidthY); heightX = Float(rawHeightX)
            } else {
                guard let xBits = readUInt32(from: bytes, cursor: &cursor),
                      let yBits = readUInt32(from: bytes, cursor: &cursor),
                      let widthBits = readUInt32(from: bytes, cursor: &cursor),
                      let widthYBits = readUInt32(from: bytes, cursor: &cursor),
                      let heightXBits = readUInt32(from: bytes, cursor: &cursor),
                      let heightBits = readUInt32(from: bytes, cursor: &cursor) else { return nil }
                x = Float(bitPattern: xBits); y = Float(bitPattern: yBits)
                width = Float(bitPattern: widthBits); height = Float(bitPattern: heightBits)
                widthY = Float(bitPattern: widthYBits); heightX = Float(bitPattern: heightXBits)
            }
            let imageIndex = images.count == 1 ? 0 : Int(frameNumber)
            if imageIndex < images.count, duration.isFinite, duration > 0,
               width > 0, height > 0 {
                frames.append(TEXAnimationFrame(imageIndex: imageIndex, duration: duration,
                                                x: x, y: y, width: width, widthY: widthY, heightX: heightX, height: height))
            }
        }
        return frames.isEmpty ? nil : TEXAnimatedImages(images: images, frames: frames)
    }

    func extractCompressedTexture() -> TEXCompressedTexture? {
        var cursor = 0

        guard readNullTerminatedString(from: bytes, cursor: &cursor) == "TEXV0005",
              readNullTerminatedString(from: bytes, cursor: &cursor) == "TEXI0001",
              let format = readUInt32(from: bytes, cursor: &cursor),
              [UInt32(4), 6, 7, 12].contains(format),
              readUInt32(from: bytes, cursor: &cursor) != nil,
              readUInt32(from: bytes, cursor: &cursor) != nil,
              readUInt32(from: bytes, cursor: &cursor) != nil,
              let imageWidth = readUInt32(from: bytes, cursor: &cursor),
              let imageHeight = readUInt32(from: bytes, cursor: &cursor),
              readUInt32(from: bytes, cursor: &cursor) != nil,
              let containerVersion = readNullTerminatedString(from: bytes, cursor: &cursor),
              let imageCount = readUInt32(from: bytes, cursor: &cursor), imageCount > 0 else {
            return nil
        }

        let version: Int
        switch containerVersion {
        case "TEXB0001": version = 1
        case "TEXB0002": version = 2
        case "TEXB0003":
            version = 3
            guard readUInt32(from: bytes, cursor: &cursor) != nil else { return nil }
        case "TEXB0004":
            // TEXB0004 adds FreeImage format and video flags to the container.
            // Non-video image mipmaps then use the TEXB0003 layout.
            version = 3
            guard readUInt32(from: bytes, cursor: &cursor) != nil,
                  readUInt32(from: bytes, cursor: &cursor) != nil else { return nil }
        default:
            return nil
        }

        guard let mipmapCount = readUInt32(from: bytes, cursor: &cursor), mipmapCount > 0 else {
            return nil
        }
        guard
              let width = readUInt32(from: bytes, cursor: &cursor),
              let height = readUInt32(from: bytes, cursor: &cursor) else { return nil }

        let compression: UInt32
        let uncompressedSize: Int
        if version == 1 {
            compression = 0
            uncompressedSize = 0
        } else {
            guard let value = readUInt32(from: bytes, cursor: &cursor),
                  let size = readUInt32(from: bytes, cursor: &cursor) else { return nil }
            compression = value
            uncompressedSize = Int(size)
        }

        guard let storedSize = readUInt32(from: bytes, cursor: &cursor),
              Int(storedSize) <= bytes.count - cursor else { return nil }
        let storedData = Array(bytes[cursor..<(cursor + Int(storedSize))])
        let mipmapData: [UInt8]
        if compression == 0 {
            mipmapData = storedData
        } else if compression == 1, uncompressedSize > 0 {
            mipmapData = decompressLZ4(storedData, uncompressedSize: uncompressedSize)
        } else {
            return nil
        }

        let textureWidth = Int(width)
        let textureHeight = Int(height)
        guard textureWidth > 0, textureHeight > 0, textureWidth <= 16_384, textureHeight <= 16_384 else {
            return nil
        }
        let expectedSize = ((textureWidth + 3) / 4) * ((textureHeight + 3) / 4) * (format == 7 ? 8 : 16)
        guard mipmapData.count >= expectedSize else { return nil }
        // A zero or oversized header size means "no crop": the whole allocation is content.
        let contentWidth = imageWidth > 0 ? min(Int(imageWidth), textureWidth) : textureWidth
        let contentHeight = imageHeight > 0 ? min(Int(imageHeight), textureHeight) : textureHeight
        return TEXCompressedTexture(format: format, width: textureWidth, height: textureHeight, data: mipmapData,
                                    contentWidth: contentWidth, contentHeight: contentHeight)
    }

    /// TEXB0004 mipmaps use the conditional-variant layout (param1/param2/conditionJson/param3 preamble)
    /// only when the container's declared FreeImage format resolves to MP4 video.
    private func isConditionalVideoFormat(_ freeImageFormat: UInt32, isVideoFlag: UInt32) -> Bool {
        let format = Int32(bitPattern: freeImageFormat)
        return format == 35 || (format == -1 && isVideoFlag == 1)
    }

    /// Consumes the ReadMipmapV4 preamble (param1==1, param2==2, conditionJson string, param3==1)
    /// that precedes the standard width/height/compression/size mipmap fields in conditional TEXB0004 mipmaps.
    private func readV4ConditionalPreamble(from bytes: [UInt8], cursor: inout Int) -> Bool {
        guard readUInt32(from: bytes, cursor: &cursor) == 1,
              readUInt32(from: bytes, cursor: &cursor) == 2,
              readNullTerminatedString(from: bytes, cursor: &cursor) != nil,
              readUInt32(from: bytes, cursor: &cursor) == 1 else {
            return false
        }
        return true
    }

    /// Extract the image from this TEX container.
    func extractImage() -> NSImage? {
        if let image = extractContainerImage() {
            return image
        }
        OWELog.error(.texture, "Unsupported or malformed TEX container (\(data.count) bytes); refusing embedded thumbnail fallback")
        return nil
    }

    /// Extract raw JPEG/PNG data without creating NSImage
    func extractImageData() -> Data? {
        guard let texbRange = findSection("TEXB") else { return nil }
        let texbData = data[texbRange]

        if let jpegOffset = findJPEGMagic(in: texbData) {
            return Data(texbData[jpegOffset...])
        }
        if let pngOffset = findPNGMagic(in: texbData) {
            return Data(texbData[pngOffset...])
        }
        return nil
    }

    // MARK: - Private

    private func extractContainerImage() -> NSImage? {
        var cursor = 0

        guard readNullTerminatedString(from: bytes, cursor: &cursor) == "TEXV0005",
              readNullTerminatedString(from: bytes, cursor: &cursor) == "TEXI0001",
              let format = readUInt32(from: bytes, cursor: &cursor),
              readUInt32(from: bytes, cursor: &cursor) != nil,
              readUInt32(from: bytes, cursor: &cursor) != nil,
              readUInt32(from: bytes, cursor: &cursor) != nil,
              let imageWidth = readUInt32(from: bytes, cursor: &cursor),
              let imageHeight = readUInt32(from: bytes, cursor: &cursor),
              readUInt32(from: bytes, cursor: &cursor) != nil,
              let containerVersion = readNullTerminatedString(from: bytes, cursor: &cursor),
              let imageCount = readUInt32(from: bytes, cursor: &cursor),
              imageCount > 0 else {
            return nil
        }

        let version: Int
        var usesConditionalMipmapLayout = false
        switch containerVersion {
        case "TEXB0001": version = 1
        case "TEXB0002": version = 2
        case "TEXB0003":
            version = 3
            guard readUInt32(from: bytes, cursor: &cursor) != nil else { return nil }
        case "TEXB0004":
            // TEXB0004 image mipmaps use the TEXB0003 layout, unless the container declares
            // a video/MP4 format, in which case each mipmap has a conditional-variant preamble.
            version = 3
            guard let freeImageFormat = readUInt32(from: bytes, cursor: &cursor),
                  let isVideoFlag = readUInt32(from: bytes, cursor: &cursor) else { return nil }
            usesConditionalMipmapLayout = isConditionalVideoFormat(freeImageFormat, isVideoFlag: isVideoFlag)
        default:
            return nil
        }

        if usesConditionalMipmapLayout {
            guard readV4ConditionalPreamble(from: bytes, cursor: &cursor) else { return nil }
        }
        guard let mipmapCount = readUInt32(from: bytes, cursor: &cursor), mipmapCount > 0 else {
            return nil
        }
        guard
              let mipmapWidth = readUInt32(from: bytes, cursor: &cursor),
              let mipmapHeight = readUInt32(from: bytes, cursor: &cursor) else {
            return nil
        }

        let compression: UInt32
        let uncompressedSize: Int
        if version == 1 {
            compression = 0
            uncompressedSize = 0
        } else {
            guard let compressed = readUInt32(from: bytes, cursor: &cursor),
                  let size = readUInt32(from: bytes, cursor: &cursor) else { return nil }
            compression = compressed
            uncompressedSize = Int(size)
        }

        guard let storedSize = readUInt32(from: bytes, cursor: &cursor),
              storedSize <= bytes.count - cursor else { return nil }
        let storedData = Array(bytes[cursor..<(cursor + Int(storedSize))])
        let mipmapData: [UInt8]
        if compression == 0 {
            mipmapData = storedData
        } else if compression == 1, uncompressedSize > 0 {
            mipmapData = decompressLZ4(storedData, uncompressedSize: uncompressedSize)
        } else {
            return nil
        }

        switch format {
        case 4, 6, 7:
            let width = Int(mipmapWidth)
            let height = Int(mipmapHeight)
            guard width > 0, height > 0, width <= 16_384, height <= 16_384 else { return nil }
            let visibleWidth = min(Int(imageWidth), width)
            let visibleHeight = min(Int(imageHeight), height)
            return decodeDXT(mipmapData, format: format, width: width, height: height,
                             visibleWidth: visibleWidth, visibleHeight: visibleHeight)
        default:
            let visibleWidth = min(Int(imageWidth), Int(mipmapWidth))
            let visibleHeight = min(Int(imageHeight), Int(mipmapHeight))
            if let image = rawChannelImage(mipmapData, format: format, width: Int(mipmapWidth), height: Int(mipmapHeight),
                                           visibleWidth: visibleWidth, visibleHeight: visibleHeight) {
                return image
            }
            return NSImage(data: Data(mipmapData))
                ?? posterImage(fromVideoData: Data(mipmapData))
                ?? rawRGBAImage(mipmapData, width: Int(mipmapWidth), height: Int(mipmapHeight),
                                visibleWidth: visibleWidth, visibleHeight: visibleHeight)
        }
    }

    /// Decodes RG88 (two-channel) and R8 (single-channel) raw mipmaps; nil for any other format.
    private func rawChannelImage(_ bytes: [UInt8], format: UInt32, width: Int, height: Int,
                                 visibleWidth: Int, visibleHeight: Int) -> NSImage? {
        switch format {
        case 1:
            guard bytes.count >= width * height * 3 else { return nil }
            var rgba = [UInt8](repeating: 255, count: width * height * 4)
            for pixel in 0..<(width * height) {
                rgba[pixel * 4] = bytes[pixel * 3]
                rgba[pixel * 4 + 1] = bytes[pixel * 3 + 1]
                rgba[pixel * 4 + 2] = bytes[pixel * 3 + 2]
            }
            return rawRGBAImage(rgba, width: width, height: height,
                                visibleWidth: visibleWidth, visibleHeight: visibleHeight)
        case 2:
            guard bytes.count >= width * height * 2 else { return nil }
            var rgba = [UInt8](repeating: 255, count: width * height * 4)
            for pixel in 0..<(width * height) {
                let offset = pixel * 2
                let packed = UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
                rgba[pixel * 4] = UInt8((packed >> 11) * 255 / 31)
                rgba[pixel * 4 + 1] = UInt8(((packed >> 5) & 63) * 255 / 63)
                rgba[pixel * 4 + 2] = UInt8((packed & 31) * 255 / 31)
            }
            return rawRGBAImage(rgba, width: width, height: height,
                                visibleWidth: visibleWidth, visibleHeight: visibleHeight)
        case 8:
            guard bytes.count >= width * height * 2 else { return nil }
            var rgba = [UInt8](repeating: 0, count: width * height * 4)
            for pixel in 0..<(width * height) {
                let luminance = bytes[pixel * 2]
                rgba[pixel * 4] = luminance
                rgba[pixel * 4 + 1] = luminance
                rgba[pixel * 4 + 2] = luminance
                rgba[pixel * 4 + 3] = bytes[pixel * 2 + 1]
            }
            return rawRGBAImage(rgba, width: width, height: height, visibleWidth: visibleWidth, visibleHeight: visibleHeight)
        case 9:
            guard width > 0, height > 0, visibleWidth > 0, visibleHeight > 0,
                  bytes.count >= width * height else { return nil }
            // R8 particle textures are coverage masks: the channel is alpha,
            // while the visible particle color is supplied by the particle system.
            var rgba = [UInt8](repeating: 255, count: width * height * 4)
            for pixel in 0..<(width * height) {
                rgba[pixel * 4 + 3] = bytes[pixel]
            }
            return rawRGBAImage(rgba, width: width, height: height,
                                visibleWidth: visibleWidth, visibleHeight: visibleHeight)
        case 10:
            guard bytes.count >= width * height * 4 else { return nil }
            var rgba = [UInt8](repeating: 255, count: width * height * 4)
            for pixel in 0..<(width * height) {
                let offset = pixel * 4
                let red = Self.halfToFloat(UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8)
                let green = Self.halfToFloat(UInt16(bytes[offset + 2]) | UInt16(bytes[offset + 3]) << 8)
                rgba[pixel * 4] = Self.floatToByte(red)
                rgba[pixel * 4 + 1] = Self.floatToByte(green)
                rgba[pixel * 4 + 2] = 0
            }
            return rawRGBAImage(rgba, width: width, height: height,
                                visibleWidth: visibleWidth, visibleHeight: visibleHeight)
        case 11:
            guard bytes.count >= width * height * 2 else { return nil }
            var rgba = [UInt8](repeating: 255, count: width * height * 4)
            for pixel in 0..<(width * height) {
                let offset = pixel * 2
                let value = Self.halfToFloat(UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8)
                let channel = Self.floatToByte(value)
                rgba[pixel * 4] = channel; rgba[pixel * 4 + 1] = channel; rgba[pixel * 4 + 2] = channel
            }
            return rawRGBAImage(rgba, width: width, height: height,
                                visibleWidth: visibleWidth, visibleHeight: visibleHeight)
        case 13:
            guard bytes.count >= width * height * 4 else { return nil }
            var rgba = [UInt8](repeating: 255, count: width * height * 4)
            for pixel in 0..<(width * height) {
                let offset = pixel * 4
                let packed = UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
                    | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
                rgba[pixel * 4] = UInt8((packed & 1023) * 255 / 1023)
                rgba[pixel * 4 + 1] = UInt8(((packed >> 10) & 1023) * 255 / 1023)
                rgba[pixel * 4 + 2] = UInt8(((packed >> 20) & 1023) * 255 / 1023)
                rgba[pixel * 4 + 3] = UInt8(((packed >> 30) & 3) * 255 / 3)
            }
            return rawRGBAImage(rgba, width: width, height: height,
                                visibleWidth: visibleWidth, visibleHeight: visibleHeight)
        case 14:
            guard bytes.count >= width * height * 8 else { return nil }
            return float16RGBAImage(bytes, width: width, height: height,
                                         visibleWidth: visibleWidth, visibleHeight: visibleHeight)
        case 15:
            guard bytes.count >= width * height * 6 else { return nil }
            var rgba = [UInt8](repeating: 255, count: width * height * 4)
            for pixel in 0..<(width * height) {
                let offset = pixel * 6
                for component in 0..<3 {
                    let value = Self.halfToFloat(UInt16(bytes[offset + component * 2])
                        | UInt16(bytes[offset + component * 2 + 1]) << 8)
                    rgba[pixel * 4 + component] = Self.floatToByte(value)
                }
            }
            return rawRGBAImage(rgba, width: width, height: height,
                                visibleWidth: visibleWidth, visibleHeight: visibleHeight)
        default:
            return nil
        }
    }

    private static func floatToByte(_ value: Float) -> UInt8 {
        UInt8(max(0, min(255, Int((value.isFinite ? value : 0) * 255))))
    }

    private func float16RGBAImage(_ bytes: [UInt8], width: Int, height: Int,
                                         visibleWidth: Int, visibleHeight: Int) -> NSImage? {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for pixel in 0..<(width * height) {
            let offset = pixel * 8
            for component in 0..<4 {
                let value = Self.halfToFloat(UInt16(bytes[offset + component * 2])
                    | UInt16(bytes[offset + component * 2 + 1]) << 8)
                    rgba[pixel * 4 + component] = Self.floatToByte(value)
            }
        }
        return rawRGBAImage(rgba, width: width, height: height,
                            visibleWidth: visibleWidth, visibleHeight: visibleHeight)
    }

    private static func halfToFloat(_ bits: UInt16) -> Float {
        let sign = (bits & 0x8000) == 0 ? Float(1) : -Float(1)
        let exponent = Int((bits >> 10) & 0x1f)
        let fraction = Float(bits & 0x03ff) / 1024
        if exponent == 0 { return sign * fraction * powf(2, -14) }
        if exponent == 31 { return fraction == 0 ? sign * Float.infinity : Float.nan }
        return sign * (1 + fraction) * powf(2, Float(exponent - 15))
    }

    /// Decodes an uncompressed RGBA8888 mipmap (TEXI format 0); these carry no image container header.
    private func rawRGBAImage(_ bytes: [UInt8], width: Int, height: Int,
                              visibleWidth: Int, visibleHeight: Int) -> NSImage? {
        guard width > 0, height > 0, visibleWidth > 0, visibleHeight > 0,
              bytes.count >= width * height * 4,
              let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: visibleWidth, height: visibleHeight, bitsPerComponent: 8,
                                  bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
                                      .union(.byteOrder32Big), provider: provider, decode: nil,
                                  shouldInterpolate: true, intent: .defaultIntent) else {
            return nil
        }
        return NSImage(cgImage: image, size: NSSize(width: visibleWidth, height: visibleHeight))
    }

    /// Wallpaper Engine stores some TEX mipmaps as a raw MP4 file (video-backed materials).
    /// Decode a single poster frame so the layer still renders as a static image.
    /// The very first frame of these clips is frequently a noisy/black transition artifact,
    /// so sample a little into the clip instead of literal time zero.
    private func posterImage(fromVideoData data: Data) -> NSImage? {
        guard data.count > 12, data[4..<8].elementsEqual("ftyp".utf8) else { return nil }
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
            .appendingPathExtension("mp4")
        guard (try? data.write(to: temporaryURL)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let asset = AVURLAsset(url: temporaryURL)
        let durationSemaphore = DispatchSemaphore(value: 0)
        var durationSeconds: Double = 0
        Task {
            durationSeconds = (try? await asset.load(.duration))?.seconds ?? 0
            durationSemaphore.signal()
        }
        durationSemaphore.wait()
        let sampleSeconds = durationSeconds.isFinite && durationSeconds > 0
            ? min(max(durationSeconds * 0.1, 0.5), durationSeconds, 2)
            : 0

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let semaphore = DispatchSemaphore(value: 0)
        var decodedImage: CGImage?
        let sampleTime = CMTime(seconds: sampleSeconds, preferredTimescale: 600)
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: sampleTime)]) { _, cgImage, _, _, _ in
            decodedImage = cgImage
            semaphore.signal()
        }
        semaphore.wait()
        guard let cgImage = decodedImage else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// Wallpaper Engine stores raw LZ4 blocks, which the Compression framework decodes with a
    /// SIMD implementation. The hand-rolled decoder stays as a fallback for anything it rejects.
    private func decompressLZ4(_ input: [UInt8], uncompressedSize: Int) -> [UInt8] {
        guard uncompressedSize > 0, !input.isEmpty else { return [] }
        var output = [UInt8](repeating: 0, count: uncompressedSize)
        let written = input.withUnsafeBufferPointer { source -> Int in
            guard let sourceBase = source.baseAddress else { return 0 }
            return output.withUnsafeMutableBufferPointer { destination -> Int in
                guard let destinationBase = destination.baseAddress else { return 0 }
                return compression_decode_buffer(destinationBase, uncompressedSize,
                                                 sourceBase, input.count,
                                                 nil, COMPRESSION_LZ4_RAW)
            }
        }
        if written == uncompressedSize { return output }
        return decompressLZ4Scalar(input, uncompressedSize: uncompressedSize)
    }

    private func decompressLZ4Scalar(_ input: [UInt8], uncompressedSize: Int) -> [UInt8] {
        guard uncompressedSize > 0 else { return [] }
        var output = [UInt8](repeating: 0, count: uncompressedSize)
        var source = 0
        var destination = 0

        func readLength(_ base: Int) -> Int? {
            var length = base
            guard base == 15 else { return length }
            while source < input.count {
                let value = Int(input[source])
                source += 1
                guard length <= Int.max - value else { return nil }
                length += value
                if value != 255 { return length }
            }
            return nil
        }

        while source < input.count {
            let token = input[source]
            source += 1

            guard let literalLength = readLength(Int(token >> 4)),
                  literalLength <= input.count - source,
                  literalLength <= output.count - destination else { return [] }
            if literalLength > 0 {
                output.replaceSubrange(destination..<(destination + literalLength),
                                       with: input[source..<(source + literalLength)])
                source += literalLength
                destination += literalLength
            }

            if source == input.count { break }
            guard source + 2 <= input.count else { return [] }
            let offset = Int(input[source]) | (Int(input[source + 1]) << 8)
            source += 2
            guard offset > 0, offset <= destination,
                  let matchLength = readLength(Int(token & 0x0F)).map({ $0 + 4 }),
                  matchLength <= output.count - destination else { return [] }
            for _ in 0..<matchLength {
                output[destination] = output[destination - offset]
                destination += 1
            }
        }

        return destination == uncompressedSize ? output : []
    }

    private func decodeDXT(_ input: [UInt8], format: UInt32, width: Int, height: Int,
                           visibleWidth: Int, visibleHeight: Int) -> NSImage? {
        let bytesPerBlock = format == 7 ? 8 : 16
        let blockColumns = (width + 3) / 4
        let blockRows = (height + 3) / 4
        guard input.count >= blockColumns * blockRows * bytesPerBlock else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for blockY in 0..<blockRows {
            for blockX in 0..<blockColumns {
                let offset = (blockY * blockColumns + blockX) * bytesPerBlock
                let alpha: [UInt8]
                let colorOffset: Int
                switch format {
                case 4:
                    alpha = decodeDXT5Alpha(input, offset: offset)
                    colorOffset = offset + 8
                case 6:
                    alpha = decodeDXT3Alpha(input, offset: offset)
                    colorOffset = offset + 8
                default:
                    alpha = [UInt8](repeating: 255, count: 16)
                    colorOffset = offset
                }
                let colors = decodeDXTColors(input, offset: colorOffset, usesOneBitAlpha: format == 7)

                for pixelY in 0..<4 {
                    for pixelX in 0..<4 {
                        let sourceIndex = pixelY * 4 + pixelX
                        let destinationX = blockX * 4 + pixelX
                        let destinationY = blockY * 4 + pixelY
                        guard destinationX < width, destinationY < height else { continue }
                        let color = colors[sourceIndex]
                        let destinationIndex = (destinationY * width + destinationX) * 4
                        pixels[destinationIndex] = color.0
                        pixels[destinationIndex + 1] = color.1
                        pixels[destinationIndex + 2] = color.2
                        pixels[destinationIndex + 3] = format == 7 && color.3 == 0 ? 0 : alpha[sourceIndex]
                    }
                }
            }
        }

        guard visibleWidth > 0, visibleHeight > 0,
              let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: visibleWidth, height: visibleHeight, bitsPerComponent: 8,
                                  bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
                                      .union(.byteOrder32Big), provider: provider, decode: nil,
                                  shouldInterpolate: true, intent: .defaultIntent) else {
            return nil
        }
        return NSImage(cgImage: image, size: NSSize(width: visibleWidth, height: visibleHeight))
    }

    private func decodeDXTColors(_ bytes: [UInt8], offset: Int, usesOneBitAlpha: Bool) -> [(UInt8, UInt8, UInt8, UInt8)] {
        let color0 = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        let color1 = UInt16(bytes[offset + 2]) | (UInt16(bytes[offset + 3]) << 8)
        let first = color565(color0)
        let second = color565(color1)
        var palette = [(first.0, first.1, first.2, UInt8(255)), (second.0, second.1, second.2, UInt8(255))]
        if usesOneBitAlpha && color0 <= color1 {
            palette.append((UInt8((Int(first.0) + Int(second.0)) / 2),
                            UInt8((Int(first.1) + Int(second.1)) / 2),
                            UInt8((Int(first.2) + Int(second.2)) / 2), 255))
            palette.append((0, 0, 0, 0))
        } else {
            palette.append((UInt8((2 * Int(first.0) + Int(second.0)) / 3),
                            UInt8((2 * Int(first.1) + Int(second.1)) / 3),
                            UInt8((2 * Int(first.2) + Int(second.2)) / 3), 255))
            palette.append((UInt8((Int(first.0) + 2 * Int(second.0)) / 3),
                            UInt8((Int(first.1) + 2 * Int(second.1)) / 3),
                            UInt8((Int(first.2) + 2 * Int(second.2)) / 3), 255))
        }
        let indices = UInt32(bytes[offset + 4]) | (UInt32(bytes[offset + 5]) << 8)
            | (UInt32(bytes[offset + 6]) << 16) | (UInt32(bytes[offset + 7]) << 24)
        return (0..<16).map { palette[Int((indices >> ($0 * 2)) & 0x3)] }
    }

    private func decodeDXT3Alpha(_ bytes: [UInt8], offset: Int) -> [UInt8] {
        (0..<16).map { pixel in
            let nibble = (bytes[offset + pixel / 2] >> ((pixel % 2) * 4)) & 0xF
            return nibble * 17
        }
    }

    private func decodeDXT5Alpha(_ bytes: [UInt8], offset: Int) -> [UInt8] {
        let alpha0 = bytes[offset]
        let alpha1 = bytes[offset + 1]
        var palette = [alpha0, alpha1]
        if alpha0 > alpha1 {
            for index in 1...6 { palette.append(UInt8(((7 - index) * Int(alpha0) + index * Int(alpha1)) / 7)) }
        } else {
            for index in 1...4 { palette.append(UInt8(((5 - index) * Int(alpha0) + index * Int(alpha1)) / 5)) }
            palette.append(0)
            palette.append(255)
        }
        var indices: UInt64 = 0
        for index in 0..<6 { indices |= UInt64(bytes[offset + 2 + index]) << (index * 8) }
        return (0..<16).map { palette[Int((indices >> ($0 * 3)) & 0x7)] }
    }

    private func color565(_ color: UInt16) -> (UInt8, UInt8, UInt8) {
        (UInt8((color >> 11) * 255 / 31), UInt8(((color >> 5) & 0x3F) * 255 / 63), UInt8((color & 0x1F) * 255 / 31))
    }

    private func readNullTerminatedString(from bytes: [UInt8], cursor: inout Int) -> String? {
        guard cursor < bytes.count, let end = bytes[cursor...].firstIndex(of: 0) else { return nil }
        defer { cursor = end + 1 }
        return String(bytes: bytes[cursor..<end], encoding: .ascii)
    }

    private func readUInt32(from bytes: [UInt8], cursor: inout Int) -> UInt32? {
        guard cursor + 4 <= bytes.count else { return nil }
        defer { cursor += 4 }
        return UInt32(bytes[cursor]) | (UInt32(bytes[cursor + 1]) << 8)
            | (UInt32(bytes[cursor + 2]) << 16) | (UInt32(bytes[cursor + 3]) << 24)
    }

    /// Read TEXI metadata section: format, flags, width, height, textureWidth, textureHeight
    private func readTEXIMetadata() -> TEXMetadata? {
        guard let texiMagic = "TEXI".data(using: .ascii) else { return nil }
        var i = data.startIndex
        while i + 4 <= data.endIndex {
            if data[i..<i+4] == texiMagic {
                // Skip past "TEXIxxxx\0" (null-terminated name with version)
                var j = i + 4
                while j < data.endIndex && data[j] != 0 { j += 1 }
                j += 1 // skip null byte
                guard j + 24 <= data.endIndex else { return nil }
                func u32(_ off: Int) -> UInt32 {
                    UInt32(data[j+off]) | (UInt32(data[j+off+1]) << 8)
                    | (UInt32(data[j+off+2]) << 16) | (UInt32(data[j+off+3]) << 24)
                }
                return TEXMetadata(format: u32(0), width: u32(8), height: u32(12),
                                   textureWidth: u32(16), textureHeight: u32(20))
            }
            i += 1
        }
        return nil
    }

    /// Read the TEXB format field (first uint32 after the null-terminated section name).
    /// Format 1 = image-extractable, Format 2 = DXT5, etc.
    private func readTEXBFormat() -> Int {
        guard let texbMagic = "TEXB".data(using: .ascii) else { return -1 }
        var i = data.startIndex
        while i + 4 <= data.endIndex {
            if data[i..<i+4] == texbMagic {
                // Skip past "TEXBxxxx\0" (null-terminated name with version)
                var j = i + 4
                while j < data.endIndex && data[j] != 0 { j += 1 }
                j += 1 // skip null byte
                guard j + 4 <= data.endIndex else { return -1 }
                return Int(UInt32(data[j])
                    | (UInt32(data[j+1]) << 8)
                    | (UInt32(data[j+2]) << 16)
                    | (UInt32(data[j+3]) << 24))
            }
            i += 1
        }
        return -1
    }

    /// Find a named section (e.g. "TEXI", "TEXB") in the TEX data
    private func findSection(_ name: String) -> Range<Data.Index>? {
        guard let nameData = name.data(using: .ascii) else { return nil }
        let nameLen = nameData.count

        var i = data.startIndex
        while i + nameLen + 4 <= data.endIndex {
            if data[i..<i+nameLen] == nameData {
                // Section found — next 4 bytes after name are section length
                let lenStart = i + nameLen
                guard lenStart + 4 <= data.endIndex else { return nil }
                let sectionLen = UInt32(data[lenStart])
                    | (UInt32(data[lenStart+1]) << 8)
                    | (UInt32(data[lenStart+2]) << 16)
                    | (UInt32(data[lenStart+3]) << 24)
                let contentStart = lenStart + 4
                let contentEnd = contentStart + Int(sectionLen)
                guard contentEnd <= data.endIndex else {
                    return contentStart..<data.endIndex
                }
                return contentStart..<contentEnd
            }
            i += 1
        }
        return nil
    }

    /// Find JPEG end marker (FFD9) scanning from a given start position
    private func findJPEGEnd(in slice: Data, from start: Data.Index) -> Data.Index? {
        var i = start
        while i + 1 < slice.endIndex {
            if slice[i] == 0xFF && slice[i+1] == 0xD9 {
                return i + 1  // Include the D9 byte
            }
            i += 1
        }
        return nil
    }

    private func findJPEGMagic(in slice: Data) -> Data.Index? {
        var i = slice.startIndex
        while i + 1 < slice.endIndex {
            if slice[i] == 0xFF && slice[i+1] == 0xD8 {
                return i
            }
            i += 1
        }
        return nil
    }

    private func findPNGMagic(in slice: Data) -> Data.Index? {
        let pngMagic: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
        var i = slice.startIndex
        while i + 3 < slice.endIndex {
            if slice[i] == pngMagic[0] && slice[i+1] == pngMagic[1]
                && slice[i+2] == pngMagic[2] && slice[i+3] == pngMagic[3] {
                return i
            }
            i += 1
        }
        return nil
    }
}
