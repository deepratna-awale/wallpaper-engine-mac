import XCTest
import Metal
@testable import OpenWallpaperEngine

final class EffectPipelineArchiveTests: XCTestCase {
    private var device: MTLDevice!
    private var directory: URL!

    override func setUpWithError() throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        directory = FileManager.default.temporaryDirectory.appending(path: "owe-archive-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func descriptor() throws -> MTLRenderPipelineDescriptor {
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        vertex float4 v(uint id [[vertex_id]]) { return float4(float(id & 1), float(id >> 1), 0, 1); }
        fragment float4 f() { return float4(1, 0, 0, 1); }
        """
        let library = try device.makeLibrary(source: source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "v")
        descriptor.fragmentFunction = library.makeFunction(name: "f")
        descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
        return descriptor
    }

    func testCompiledPipelinesArePersistedAndHitOnTheNextLaunch() throws {
        let first = EffectPipelineArchive(device: device, directory: directory)
        _ = try EffectGraphRenderer.makePipeline(try descriptor(), device: device, archive: first)
        XCTAssertEqual(first.additions, 1)
        first.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.url.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertEqual(leftovers, [], "writes go through a temporary file that is renamed")

        let second = EffectPipelineArchive(device: device, directory: directory)
        _ = try EffectGraphRenderer.makePipeline(try descriptor(), device: device, archive: second)
        XCTAssertEqual(second.hits, 1)
        XCTAssertEqual(second.additions, 0)
    }

    func testCorruptArchiveIsDiscardedAndReplaced() throws {
        let url = EffectPipelineArchive(device: device, directory: directory).url
        try Data((0..<4096).map { _ in UInt8.random(in: 0...255) }).write(to: url)
        let archive = EffectPipelineArchive(device: device, directory: directory)
        XCTAssertFalse(archive.archives.isEmpty, "an empty archive replaces the corrupt one")
        _ = try EffectGraphRenderer.makePipeline(try descriptor(), device: device, archive: archive)
        archive.flush()
        XCTAssertNotNil(try? device.makeBinaryArchive(descriptor: {
            let descriptor = MTLBinaryArchiveDescriptor()
            descriptor.url = url
            return descriptor
        }()), "the rewritten archive opens")
    }

    func testArchivesForAnotherBuildOfThisGPUAreDeleted() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let prefix = EffectPipelineArchive.devicePrefix(device)
        let stale = directory.appending(path: "\(prefix)--old-os--0.1-1--r1.binarchive")
        let otherGPU = directory.appending(path: "Other-GPU-1--old-os--0.1-1--r1.binarchive")
        try Data("x".utf8).write(to: stale)
        try Data("x".utf8).write(to: otherGPU)
        let archive = EffectPipelineArchive(device: device, directory: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherGPU.path), "other GPUs keep their archives")
        XCTAssertTrue(archive.url.lastPathComponent.hasPrefix(prefix))
        XCTAssertTrue(archive.url.lastPathComponent.contains("--r\(EffectPipelineArchive.revision)"))
    }
}
