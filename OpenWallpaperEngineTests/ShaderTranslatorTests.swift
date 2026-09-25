import XCTest
@testable import OpenWallpaperEngine

final class ShaderTranslatorTests: XCTestCase {
    private var assets: URL!
    private var cache: URL { assets.appending(path: ".open-wallpaper-engine/shaders", directoryHint: .isDirectory) }

    override func setUpWithError() throws {
        try XCTSkipIf(SceneShaderTranslator.toolchain == nil, "glslang/spirv-cross not installed")
        assets = try Fixtures.temporaryCopy(of: "ShaderAssets")
    }

    override func tearDownWithError() throws {
        if let assets { try? FileManager.default.removeItem(at: assets) }
    }

    /// Covers WE's `M_PI_2` (2π, clashing with a π/2 default) and HLSL-style int arguments to
    /// pow/max, both of which broke translation after the header gained vector overloads.
    func testTranslatesWallpaperEngineIdioms() throws {
        SceneShaderTranslator.translateSharedShaders(in: assets, cacheDirectory: cache)
        for stage in ["frag", "vert"] {
            let output = cache.appending(path: "effects_test_shaders_effects_test.\(stage).metal")
            XCTAssertTrue(FileManager.default.fileExists(atPath: output.path), "\(stage) not translated")
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathExtension("unsupported").path))
        }
    }

    func testStampRecordsTranslatorRevision() throws {
        SceneShaderTranslator.translateSharedShaders(in: assets, cacheDirectory: cache)
        let stamp = try String(contentsOf: cache.appending(path: "effects_test_shaders_effects_test.frag.metal.sha256"),
                               encoding: .utf8)
        XCTAssertNotNil(stamp.range(of: #"^\d+:[0-9a-f]{64}$"#, options: .regularExpression),
                        "stamp must carry the pipeline revision, got \(stamp)")
    }

    func testPurgesStaleEditorOnlyTranslationsOnly() throws {
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let preview = cache.appending(path: "effects_test_preview_shaders_effects_test.frag.metal")
        let package = cache.appending(path: "shaders_effects_fromapackage.frag.metal")
        for file in [preview, package, preview.appendingPathExtension("sha256")] {
            try Data("stale".utf8).write(to: file)
        }
        SceneShaderTranslator.translateSharedShaders(in: assets, cacheDirectory: cache)
        XCTAssertFalse(FileManager.default.fileExists(atPath: preview.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: preview.appendingPathExtension("sha256").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.path), "package translations are not the pass's to remove")
    }
}
