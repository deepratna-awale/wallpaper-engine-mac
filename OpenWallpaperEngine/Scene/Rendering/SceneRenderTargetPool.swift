import Metal

/// Shared scratch render targets, bucketed by size, format and usage.
///
/// Callers hold on to what they get, so eviction only drops the pool's reference: a texture that
/// is still in use (or in flight on the GPU) stays alive until its last owner lets go. Buckets are
/// evicted least recently used first once the pool holds more than `byteBudget`, and a bucket
/// untouched for `maxIdleFrames` frames is dropped at `endFrame()`.
final class SceneRenderTargetPool {
    private struct Key: Hashable {
        let width: Int
        let height: Int
        let pixelFormat: MTLPixelFormat
        let usage: UInt
    }

    private struct Bucket {
        var textures: [MTLTexture] = []
        var lastUse: UInt64 = 0
        var lastFrame: UInt64 = 0
    }

    private let device: MTLDevice
    let byteBudget: Int
    let maxIdleFrames: UInt64
    private var buckets: [Key: Bucket] = [:]
    private var clock: UInt64 = 0
    private var frame: UInt64 = 0

    init(device: MTLDevice, byteBudget: Int = 256 << 20, maxIdleFrames: UInt64 = 600) {
        self.device = device
        self.byteBudget = byteBudget
        self.maxIdleFrames = maxIdleFrames
    }

    /// Textures currently held by the pool, and their approximate size in bytes.
    var textureCount: Int { buckets.values.reduce(0) { $0 + $1.textures.count } }
    var residentBytes: Int { buckets.values.reduce(0) { $0 + $1.textures.reduce(0) { $0 + Self.bytes(of: $1) } } }

    func texture(width: Int, height: Int, pixelFormat: MTLPixelFormat,
                 usage: MTLTextureUsage = [.renderTarget, .shaderRead], avoiding: MTLTexture? = nil) -> MTLTexture? {
        let key = Key(width: width, height: height, pixelFormat: pixelFormat, usage: usage.rawValue)
        clock += 1
        buckets[key, default: Bucket()].lastUse = clock
        buckets[key]!.lastFrame = frame
        if let texture = buckets[key]!.textures.first(where: { texture in
            avoiding.map { texture !== $0 } ?? true
        }) { return texture }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat,
                                                                    width: width, height: height,
                                                                    mipmapped: false)
        descriptor.usage = usage
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            if buckets[key]!.textures.isEmpty { buckets[key] = nil }
            return nil
        }
        buckets[key]!.textures.append(texture)
        evictOverBudget(keeping: key)
        return texture
    }

    /// Advances the frame clock and drops buckets nobody asked for in `maxIdleFrames` frames.
    func endFrame() {
        frame += 1
        buckets = buckets.filter { frame - $0.value.lastFrame <= maxIdleFrames }
    }

    func removeAll() {
        buckets.removeAll(keepingCapacity: true)
    }

    private func evictOverBudget(keeping protected: Key) {
        var total = residentBytes
        while total > byteBudget,
              let victim = buckets.filter({ $0.key != protected }).min(by: { $0.value.lastUse < $1.value.lastUse }) {
            total -= victim.value.textures.reduce(0) { $0 + Self.bytes(of: $1) }
            buckets[victim.key] = nil
        }
    }

    private static func bytes(of texture: MTLTexture) -> Int {
        texture.width * texture.height * bytesPerPixel(texture.pixelFormat)
    }

    private static func bytesPerPixel(_ format: MTLPixelFormat) -> Int {
        switch format {
        case .r8Unorm: return 1
        case .rg8Unorm, .r16Float: return 2
        case .rgba16Float: return 8
        case .rgba32Float: return 16
        default: return 4
        }
    }
}
