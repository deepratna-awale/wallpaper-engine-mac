import Metal

/// The pipelines the scene pass draws with natively (a layer's quad blended normally or
/// additively, and an unblended region copy), in each format the scene target can have: the
/// drawable's in LDR, RGBA16F in HDR (docs/lighting-plan.md §2.6). With WE's MSAA setting the
/// scene pass draws multisampled; its pipelines for a sample count above 1 are made when first
/// asked for.
final class SceneLayerPipelines {
    struct Pipelines {
        let normal: MTLRenderPipelineState
        let additive: MTLRenderPipelineState
        let copy: MTLRenderPipelineState
    }

    private struct Multisampled: Hashable {
        var format: MTLPixelFormat
        var sampleCount: Int
    }

    private let byFormat: [MTLPixelFormat: Pipelines]
    private let fallback: Pipelines
    private let device: MTLDevice
    private let functions: (vertex: MTLFunction, fragment: MTLFunction, copy: MTLFunction)
    /// Made on first use, by the render thread only; nil for one that failed (logged once).
    private var multisampled: [Multisampled: Pipelines?] = [:]

    /// The pipelines for each of `formats`, the first of which `pipelines(for:)` falls back to.
    /// Throws when one can't be made.
    init(device: MTLDevice, vertex: MTLFunction, fragment: MTLFunction, copyFragment: MTLFunction,
         formats: [MTLPixelFormat]) throws {
        var byFormat: [MTLPixelFormat: Pipelines] = [:]
        for format in formats where byFormat[format] == nil {
            byFormat[format] = try Self.make(device: device, vertex: vertex, fragment: fragment,
                                             copyFragment: copyFragment, format: format)
        }
        guard let first = formats.first, let fallback = byFormat[first] else {
            throw ShaderCompilerError.failed(step: "metal", output: "no scene target format")
        }
        self.byFormat = byFormat
        self.fallback = fallback
        self.device = device
        functions = (vertex, fragment, copyFragment)
    }

    /// The pipelines drawing into a target of `format`.
    func pipelines(for format: MTLPixelFormat?) -> Pipelines {
        format.flatMap { byFormat[$0] } ?? fallback
    }

    /// The pipelines drawing into a `sampleCount`-sample target of `format`; nil when they can't
    /// be made (the caller draws single-sampled). Call on the render thread.
    func pipelines(for format: MTLPixelFormat, sampleCount: Int) -> Pipelines? {
        guard sampleCount > 1 else { return pipelines(for: format) }
        let key = Multisampled(format: format, sampleCount: sampleCount)
        if let known = multisampled[key] { return known }
        do {
            let made = try Self.make(device: device, vertex: functions.vertex, fragment: functions.fragment,
                                     copyFragment: functions.copy, format: format, sampleCount: sampleCount)
            multisampled[key] = made
            return made
        } catch {
            OWELog.error(.scene, "The scene's \(sampleCount)× MSAA pipelines can't be made; it draws without MSAA: \(error)")
            multisampled[key] = .some(nil)
            return nil
        }
    }

    /// The layer pipeline's descriptor in `format`: source-over blending.
    static func layerDescriptor(vertex: MTLFunction, fragment: MTLFunction, format: MTLPixelFormat) -> MTLRenderPipelineDescriptor {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = format
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .sourceAlpha
        attachment.sourceAlphaBlendFactor = .sourceAlpha
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return descriptor
    }

    private static func make(device: MTLDevice, vertex: MTLFunction, fragment: MTLFunction,
                             copyFragment: MTLFunction, format: MTLPixelFormat, sampleCount: Int = 1) throws -> Pipelines {
        let descriptor = layerDescriptor(vertex: vertex, fragment: fragment, format: format)
        descriptor.rasterSampleCount = sampleCount
        let normal = try device.makeRenderPipelineState(descriptor: descriptor)
        let additiveDescriptor = descriptor.copy() as! MTLRenderPipelineDescriptor
        additiveDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        additiveDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        additiveDescriptor.colorAttachments[0].destinationRGBBlendFactor = .one
        additiveDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .one
        let additive = try device.makeRenderPipelineState(descriptor: additiveDescriptor)
        let copyDescriptor = MTLRenderPipelineDescriptor()
        copyDescriptor.vertexFunction = vertex
        copyDescriptor.fragmentFunction = copyFragment
        copyDescriptor.colorAttachments[0].pixelFormat = format
        copyDescriptor.rasterSampleCount = sampleCount
        let copy = try device.makeRenderPipelineState(descriptor: copyDescriptor)
        return Pipelines(normal: normal, additive: additive, copy: copy)
    }
}
