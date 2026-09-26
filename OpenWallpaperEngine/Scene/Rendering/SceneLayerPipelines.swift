import Metal

/// The pipelines the scene pass draws with natively (a layer's quad blended normally or
/// additively, and an unblended region copy), in each format the scene target can have: the
/// drawable's in LDR, RGBA16F in HDR (docs/lighting-plan.md §2.6).
final class SceneLayerPipelines {
    struct Pipelines {
        let normal: MTLRenderPipelineState
        let additive: MTLRenderPipelineState
        let copy: MTLRenderPipelineState
    }

    private let byFormat: [MTLPixelFormat: Pipelines]
    private let fallback: Pipelines

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
    }

    /// The pipelines drawing into a target of `format`.
    func pipelines(for format: MTLPixelFormat?) -> Pipelines {
        format.flatMap { byFormat[$0] } ?? fallback
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
                             copyFragment: MTLFunction, format: MTLPixelFormat) throws -> Pipelines {
        let descriptor = layerDescriptor(vertex: vertex, fragment: fragment, format: format)
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
        let copy = try device.makeRenderPipelineState(descriptor: copyDescriptor)
        return Pipelines(normal: normal, additive: additive, copy: copy)
    }
}
