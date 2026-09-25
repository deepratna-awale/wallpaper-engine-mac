import Cocoa
import MetalKit
import CryptoKit

final class SceneRenderTargetPool {
    private struct Key: Hashable {
        let width: Int
        let height: Int
        let pixelFormat: MTLPixelFormat
        let usage: UInt
    }

    private let device: MTLDevice
    private var textures: [Key: [MTLTexture]] = [:]

    init(device: MTLDevice) {
        self.device = device
    }

    func texture(width: Int, height: Int, pixelFormat: MTLPixelFormat,
                 usage: MTLTextureUsage = [.renderTarget, .shaderRead], avoiding: MTLTexture? = nil) -> MTLTexture? {
        let key = Key(width: width, height: height, pixelFormat: pixelFormat, usage: usage.rawValue)
        if let texture = textures[key]?.first(where: { texture in
            avoiding.map { texture !== $0 } ?? true
        }) { return texture }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat,
                                                                    width: width, height: height,
                                                                    mipmapped: false)
        descriptor.usage = usage
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        textures[key, default: []].append(texture)
        return texture
    }

    func removeAll() {
        textures.removeAll(keepingCapacity: true)
    }
}
