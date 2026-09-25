import Cocoa
import MetalKit
import CryptoKit

final class DynamicEffectPipelineCache {
    private let device: MTLDevice
    private var libraries: [String: MTLLibrary] = [:]
    private var pipelines: [String: MTLRenderPipelineState] = [:]

    init(device: MTLDevice) {
        self.device = device
    }

    func pipeline(vertexURL: URL, fragmentURL: URL, pixelFormat: MTLPixelFormat,
                  macroConfiguration: String, blending: String?) -> MTLRenderPipelineState? {
        let blendKey = blending ?? "normal"
        let key = "\(vertexURL.path)|\(fragmentURL.path)|\(pixelFormat.rawValue)|\(macroConfiguration)|\(blendKey)"
        if let pipeline = pipelines[key] { return pipeline }
        guard let vertexLibrary = library(for: vertexURL), let fragmentLibrary = library(for: fragmentURL) else { return nil }
        guard let vertex = function(in: vertexLibrary, stage: "vertex"),
              let fragment = function(in: fragmentLibrary, stage: "fragment") else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        if blending?.lowercased() == "additive" {
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .one
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .one
        } else if blending?.lowercased() == "alpha" || blending?.lowercased() == "translucent" || blending == "normal" {
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
                guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        pipelines[key] = pipeline
        return pipeline
    }

    private func function(in library: MTLLibrary, stage: String) -> MTLFunction? {
        let names = library.functionNames
        let name = names.first { $0.localizedCaseInsensitiveContains(stage) }
            ?? names.first { $0.localizedCaseInsensitiveContains(stage == "vertex" ? "vert" : "frag") }
            ?? names.first { $0 == "main0" || $0 == "main" }
            ?? names.first
        return name.flatMap { library.makeFunction(name: $0) }
    }

    private func library(for url: URL) -> MTLLibrary? {
        // A sibling .metallib was compiled at conversion time; loading it skips MSL compilation.
        let libraryURL = url.appendingPathExtension("metallib")
        if FileManager.default.fileExists(atPath: libraryURL.path) {
            let key = "metallib|\(libraryURL.path)"
            if let library = libraries[key] { return library }
            if let library = try? device.makeLibrary(URL: libraryURL) {
                libraries[key] = library
                return library
            }
        }
        guard let source = try? String(contentsOf: url) else { return nil }
        let hash = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        let key = "\(url.path)|\(hash)"
        if let library = libraries[key] { return library }
        guard
              let library = try? device.makeLibrary(source: source, options: nil) else { return nil }
        libraries[key] = library
        return library
    }
}
