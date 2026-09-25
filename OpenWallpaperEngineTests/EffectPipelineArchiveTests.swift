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

    private func descriptor(red: Int = 1) throws -> MTLRenderPipelineDescriptor {
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        vertex float4 v(uint id [[vertex_id]]) { return float4(float(id & 1), float(id >> 1), 0, 1); }
        fragment float4 f() { return float4(\(red) / 100.0, 0, 0, 1); }
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
        _ = try EffectGraphRenderer.makePipeline(try descriptor(), device: device, archive: first, key: "a")
        XCTAssertEqual(first.additions, 1)
        first.flush()
        XCTAssertEqual(first.writeFailures, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.url.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertEqual(leftovers, [], "writes go through a temporary file that is renamed")

        let second = EffectPipelineArchive(device: device, directory: directory)
        _ = try EffectGraphRenderer.makePipeline(try descriptor(), device: device, archive: second, key: "a")
        XCTAssertEqual(second.hits, 1)
        XCTAssertEqual(second.additions, 0)
    }

    /// Pipelines compile on a concurrent queue; lookups and additions must not corrupt the archive.
    func testConcurrentCompilesSerializeCleanly() throws {
        let archive = EffectPipelineArchive(device: device, directory: directory)
        let descriptors = try (0..<24).map { try descriptor(red: $0) }
        let device: MTLDevice = self.device
        DispatchQueue.concurrentPerform(iterations: descriptors.count) { index in
            do {
                _ = try EffectGraphRenderer.makePipeline(descriptors[index], device: device, archive: archive, key: "\(index)")
            } catch {
                XCTFail("\(error)")
            }
        }
        archive.flush()
        XCTAssertEqual(archive.writeFailures, 0)
        let reopened = EffectPipelineArchive(device: device, directory: directory)
        for index in [0, 11, 23] {
            _ = try EffectGraphRenderer.makePipeline(try descriptor(red: index), device: device, archive: reopened, key: "\(index)")
        }
        XCTAssertEqual(reopened.hits, 3)
    }

    /// Translated WE shaders are one library per stage; each pipeline takes its two entry points
    /// from two libraries.
    func testPipelinesFromPerStageLibrariesSerialize() throws {
        for launch in 0..<3 {
            let archive = EffectPipelineArchive(device: device, directory: directory)
            try addPerStagePipelines(range: (launch * 4)..<(launch * 4 + 4), to: archive)
            archive.flush()
            XCTAssertEqual(archive.writeFailures, 0, "launch \(launch)")
        }
    }

    private func addPerStagePipelines(range: Range<Int>, to archive: EffectPipelineArchive) throws {
        for red in range {
            let vertexLibrary = try device.makeLibrary(source: """
            #include <metal_stdlib>
            using namespace metal;
            vertex float4 main0(uint id [[vertex_id]]) { return float4(float(id & 1) * \(red + 1), float(id >> 1), 0, 1); }
            """, options: nil)
            let fragmentLibrary = try device.makeLibrary(source: """
            #include <metal_stdlib>
            using namespace metal;
            fragment float4 main0() { return float4(\(red % 2) / 10.0, 0, 0, 1); }
            """, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexLibrary.makeFunction(name: "main0")
            descriptor.fragmentFunction = fragmentLibrary.makeFunction(name: "main0")
            descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
            _ = try EffectGraphRenderer.makePipeline(descriptor, device: device, archive: archive, key: "stage\(red)")
        }
    }

    /// One variant is used with several target formats and blend modes.
    func testSameFunctionsWithDifferentTargetsSerialize() throws {
        let archive = EffectPipelineArchive(device: device, directory: directory)
        let base = try descriptor()
        for format in [MTLPixelFormat.rgba8Unorm, .r16Float, .rgba16Float] {
            for blend in [false, true] {
                let descriptor = base.copy() as! MTLRenderPipelineDescriptor // copy() returns its own class
                descriptor.colorAttachments[0].pixelFormat = format
                descriptor.colorAttachments[0].isBlendingEnabled = blend
                _ = try EffectGraphRenderer.makePipeline(descriptor, device: device, archive: archive, key: "\(format.rawValue)|\(blend)")
            }
        }
        archive.flush()
        XCTAssertEqual(archive.writeFailures, 0)
    }

    func testCorruptArchiveIsDiscardedAndReplaced() throws {
        let url = EffectPipelineArchive(device: device, directory: directory).url
        try Data((0..<4096).map { _ in UInt8.random(in: 0...255) }).write(to: url)
        let archive = EffectPipelineArchive(device: device, directory: directory)
        XCTAssertTrue(archive.archives.isEmpty, "the corrupt archive is not used")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "and it is deleted")
        _ = try EffectGraphRenderer.makePipeline(try descriptor(), device: device, archive: archive, key: "a")
        archive.flush()
        XCTAssertEqual(archive.writeFailures, 0)
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

    /// Renderers of one device share one archive, so they don't overwrite each other's file.
    func testRenderersOfADeviceShareOneArchive() throws {
        let a = try XCTUnwrap(EffectGraphRenderer(device: device, pipelineArchiveDirectory: directory))
        let b = try XCTUnwrap(EffectGraphRenderer(device: device, pipelineArchiveDirectory: directory))
        XCTAssertTrue(a.pipelineArchive === b.pipelineArchive)
        let other = try XCTUnwrap(EffectGraphRenderer(device: device, pipelineArchiveDirectory: directory.appending(path: "other")))
        XCTAssertFalse(a.pipelineArchive === other.pipelineArchive)
    }

    /// Metal fails to serialize an archive that grew after a write for some sets of WE's built-in
    /// pipelines ("missing 'vertex' stage in pipeline no. N"); every write is built afresh, so
    /// frequent writes across two launches keep every pipeline.
    func testBuiltinEffectPipelinesSurviveRepeatedWritesAndLaunches() throws {
        let assets = ShaderVariantTests.weAssets
        let loader = ShaderSourceLoader(roots: [assets])
        let translator = ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: nil)
        let effects = try FileManager.default.contentsOfDirectory(atPath: assets.appending(path: "effects").path).sorted()
        var descriptors: [(key: String, descriptor: MTLRenderPipelineDescriptor)] = []
        for effect in effects {
            let shaders = assets.appending(path: "effects/\(effect)/shaders/effects")
            // Optional: an effect without its own shaders uses shared ones.
            let names = (try? FileManager.default.contentsOfDirectory(atPath: shaders.path)) ?? []
            for name in names.sorted() where name.hasSuffix(".vert") {
                let path = "effects/\(effect)/shaders/effects/\(name.dropLast(5))"
                let vertex = try loader.load(path, stage: .vertex), fragment = try loader.load(path, stage: .fragment)
                let base = ShaderVariantTranslator.resolveCombos(vertex: vertex, fragment: fragment, overrides: [], boundTextureSlots: [0])
                for combo in [nil] + Set((vertex.combos + fragment.combos).map(\.name)).sorted() {
                    var combos = base
                    if let combo { combos[combo] = 1 }
                    // Optional: a combo that doesn't translate is another test's concern.
                    guard let variant = try? translator.variant(vertex: vertex, fragment: fragment, combos: combos) else { continue }
                    let descriptor = MTLRenderPipelineDescriptor()
                    descriptor.vertexFunction = try device.makeLibrary(source: variant.vertexMSL, options: nil).makeFunction(name: "main0")
                    descriptor.fragmentFunction = try device.makeLibrary(source: variant.fragmentMSL, options: nil).makeFunction(name: "main0")
                    descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
                    descriptor.vertexDescriptor = EffectGraphRenderer.vertexDescriptor(for: try XCTUnwrap(descriptor.vertexFunction))
                    descriptors.append(("\(path)|\(combos.sorted { $0.key < $1.key })", descriptor))
                }
            }
        }
        XCTAssertGreaterThan(descriptors.count, 100)
        let split = descriptors.count * 2 / 3
        for (launch, range) in [(0, 0..<split), (1, (descriptors.count / 3)..<descriptors.count)] {
            let archive = EffectPipelineArchive(device: device, directory: directory, serializeDelay: 1000)
            for index in range {
                _ = try EffectGraphRenderer.makePipeline(descriptors[index].descriptor.copy() as! MTLRenderPipelineDescriptor, // copy() returns its own class
                                                         device: device, archive: archive, key: descriptors[index].key)
                if index % 5 == 4 { archive.flush() }
            }
            archive.flush()
            XCTAssertEqual(archive.writeFailures, 0, "launch \(launch)")
            XCTAssertEqual(archive.skippedCount, 0, "launch \(launch)")
            if launch == 1 { XCTAssertGreaterThanOrEqual(archive.hits, split - descriptors.count / 3, "the first launch's pipelines are found") }
        }
    }
}
