import XCTest
import CryptoKit
@testable import OpenWallpaperEngine

/// The shader variant disk cache and the choice of compiler: what survives an upgrade, a
/// read-only or full disk, and a machine with or without Homebrew's glslang/spirv-cross.
final class ShaderVariantCacheTests: XCTestCase {
    private func temporaryDirectory(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "owe-\(name)-\(UUID().uuidString)",
                                                                   directoryHint: .isDirectory)
        addTeardownBlock {
            // Scratch cleanup; a read-only test directory is made writable first.
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    /// Returns fixed output and counts calls; stands in for an older compiler.
    private final class FakeCompiler: ShaderCompiler {
        let cacheFingerprint: String
        let marker: String
        private(set) var compiles = 0
        init(fingerprint: String, marker: String) {
            cacheFingerprint = fingerprint
            self.marker = marker
        }
        func preprocess(_ source: String, stage: ShaderStage) throws -> String { source }
        func compileToMSL(_ source: String, stage: ShaderStage) throws -> (msl: String, reflection: Data) {
            compiles += 1
            return ("// \(marker)", Data("{}".utf8))
        }
    }

    private let vertex = ShaderSource(stage: .vertex, path: "v", text: "void main() {}", combos: [], uniforms: [])
    private let fragment = ShaderSource(stage: .fragment, path: "f", text: "void main() {}", combos: [], uniforms: [])

    // MARK: - Upgrades (risk 1)

    /// Variants cached by another compiler (e.g. the Homebrew tools before M9) are never read.
    func testVariantsOfAnotherCompilerAreNotReused() throws {
        let cache = temporaryDirectory("variants")
        let old = FakeCompiler(fingerprint: "process|glslang 15|spirv-cross 2024", marker: "old")
        _ = try ShaderVariantTranslator(compiler: old, cacheDirectory: cache).variant(vertex: vertex, fragment: fragment, combos: [:])
        let new = FakeCompiler(fingerprint: "in-process|glslang 16.6.0", marker: "new")
        let variant = try ShaderVariantTranslator(compiler: new, cacheDirectory: cache).variant(vertex: vertex, fragment: fragment, combos: [:])
        XCTAssertEqual(variant.vertexMSL, "// new")
        XCTAssertEqual(new.compiles, 2)
        let again = FakeCompiler(fingerprint: new.cacheFingerprint, marker: "unused")
        XCTAssertEqual(try ShaderVariantTranslator(compiler: again, cacheDirectory: cache)
            .variant(vertex: vertex, fragment: fragment, combos: [:]).vertexMSL, "// new", "the same compiler reads it back")
        XCTAssertEqual(again.compiles, 0)
    }

    /// Output of the translator over a fixed corpus, per `ShaderVariantTranslator.revision`.
    /// Translated output changed: bump `revision` (CLAUDE.md) and add the new hash here.
    static let goldenCorpusHashes: [Int: String] = [
        6: "46033e7a708b9df4b268e1f4e9be409c228d6ad367b7b6455c036729440ad2af",
        // The effects corpus has no lit pass: `LightingV1` changed lit variants only.
        7: "46033e7a708b9df4b268e1f4e9be409c228d6ad367b7b6455c036729440ad2af",
    ]

    /// Fails when translated output changes without a `revision` bump, which would let users keep
    /// stale variants from their disk cache.
    func testTranslatedOutputMatchesItsRevision() throws {
        let assets = ShaderVariantTests.weAssets
        let loader = ShaderSourceLoader(roots: [assets])
        let translator = ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: nil, failureDirectory: nil)
        var hasher = SHA256()
        var count = 0
        let effects = try FileManager.default.contentsOfDirectory(atPath: assets.appending(path: "effects").path).sorted()
        for effect in effects {
            let shaders = assets.appending(path: "effects/\(effect)/shaders/effects")
            // Optional: an effect without its own shaders uses shared ones.
            let names = (try? FileManager.default.contentsOfDirectory(atPath: shaders.path)) ?? []
            for name in names.sorted() where name.hasSuffix(".vert") {
                let path = "effects/\(effect)/shaders/effects/\(name.dropLast(5))"
                let vertex = try loader.load(path, stage: .vertex), fragment = try loader.load(path, stage: .fragment)
                let combos = ShaderVariantTranslator.resolveCombos(vertex: vertex, fragment: fragment, overrides: [],
                                                                   boundTextureSlots: [0])
                hasher.update(data: Data(path.utf8))
                // Optional: a pair that fails to translate contributes that it failed.
                if let variant = try? translator.variant(vertex: vertex, fragment: fragment, combos: combos) {
                    hasher.update(data: Data(variant.vertexMSL.utf8))
                    hasher.update(data: Data(variant.fragmentMSL.utf8))
                    for (name, member) in (variant.uniforms?.members ?? [:]).sorted(by: { $0.key < $1.key }) {
                        hasher.update(data: Data("\(name):\(member.type):\(member.offset):\(member.count)".utf8))
                    }
                    hasher.update(data: Data("\(variant.textureSlots)\(variant.attributes.sorted { $0.key < $1.key })".utf8))
                    count += 1
                } else {
                    hasher.update(data: Data("failed".utf8))
                }
            }
        }
        XCTAssertGreaterThan(count, 50)
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hash, Self.goldenCorpusHashes[ShaderVariantTranslator.revision],
                       "translated output changed: bump ShaderVariantTranslator.revision and record \(hash) for it")
    }

    /// LF8: a combo neither stage names (the engine's `SCENE_ORTHO` and `HDR` are set for every
    /// material) doesn't fork the key, so the same effect in a perspective or orthographic scene is
    /// one variant. A combo the shader names, and `LIGHTING`/`LIGHTS_*` under
    /// `#require LightingV1`, still does.
    func testCombosTheShaderDoesntNameStayOutOfTheKey() throws {
        let loader = ShaderSourceLoader(roots: [ShaderVariantTests.weAssets])
        let path = "effects/tint/shaders/effects/tint"
        let vertex = try loader.load(path, stage: .vertex), fragment = try loader.load(path, stage: .fragment)
        let base = ShaderVariantTranslator.resolveCombos(vertex: vertex, fragment: fragment, overrides: [], boundTextureSlots: [0])
        func key(_ extra: [String: Int]) -> String {
            ShaderVariantTranslator.cacheKey(vertex: vertex, fragment: fragment, combos: base.merging(extra) { _, new in new })
        }
        XCTAssertEqual(key([:]), key(["SCENE_ORTHO": 1, "LIGHTS_POINT": 2]), "tint names neither")
        XCTAssertNotEqual(key([:]), key(["HDR": 1]), "tint's common_blending.h tests HDR")
        let declared = try XCTUnwrap(base.keys.sorted().first, "tint declares a combo")
        XCTAssertNotEqual(key([declared: 7]), key([:]), "a declared combo keys the variant")

        let lit = "shaders/genericimage4"
        let litVertex = try loader.load(lit, stage: .vertex), litFragment = try loader.load(lit, stage: .fragment)
        let combos = ShaderVariantTranslator.resolveCombos(vertex: litVertex, fragment: litFragment,
                                                           overrides: [["LIGHTING": 1]], boundTextureSlots: [0])
        func litKey(_ extra: [String: Int]) -> String {
            ShaderVariantTranslator.cacheKey(vertex: litVertex, fragment: litFragment,
                                             combos: combos.merging(extra) { _, new in new })
        }
        XCTAssertNotEqual(litKey(["LIGHTS_TUBE": 4]), litKey([:]), "LightingV1 is generated from the counts")
        XCTAssertNotEqual(litKey(["HDR": 1]), litKey([:]), "genericimage4 tests HDR")
        XCTAssertEqual(litKey(["UNUSED_ENGINE_COMBO": 1]), litKey([:]))
    }

    // MARK: - Cache hygiene (risk 24)

    func testVariantsLiveInTheirGeneration() throws {
        let cache = temporaryDirectory("variants")
        let compiler = FakeCompiler(fingerprint: "a", marker: "a")
        let translator = ShaderVariantTranslator(compiler: compiler, cacheDirectory: cache)
        _ = try translator.variant(vertex: vertex, fragment: fragment, combos: [:])
        let generation = ShaderVariantTranslator.generation(toolchain: "a")
        XCTAssertTrue(generation.hasPrefix("r\(ShaderVariantTranslator.revision)-"))
        XCTAssertNotEqual(generation, ShaderVariantTranslator.generation(toolchain: "b"))
        XCTAssertEqual(translator.generationDirectory?.lastPathComponent, generation)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.appending(path: generation).path).count, 1)
        XCTAssertEqual(ShaderVariantTranslator.cachedVariantCount(in: cache), 1)
    }

    /// Old generations and the pre-generation flat layout are deleted; a generation used within
    /// the last week (another build in use) is kept.
    func testStaleGenerationsArePruned() throws {
        let cache = temporaryDirectory("variants")
        let fileManager = FileManager.default
        let now = Date()
        func make(_ name: String, age: TimeInterval) throws {
            let url = cache.appending(path: name)
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: url.appending(path: "k.json"))
            try fileManager.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
        try make("r5-aaaaaaaaaaaa", age: 30 * 24 * 3600)
        try make("r6-bbbbbbbbbbbb", age: 3600)
        try make("r6-cccccccccccc", age: 30 * 24 * 3600)
        try Data("{}".utf8).write(to: cache.appending(path: "0123abcd.json"))
        try fileManager.createDirectory(at: cache.appending(path: "other"), withIntermediateDirectories: true)

        ShaderVariantTranslator.pruneStaleGenerations(in: cache, keeping: "r6-cccccccccccc", now: now)

        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: cache.path).sorted(),
                       ["other", "r6-bbbbbbbbbbbb", "r6-cccccccccccc"])
        let kept = try fileManager.attributesOfItem(atPath: cache.appending(path: "r6-cccccccccccc").path)[.modificationDate] as? Date
        XCTAssertEqual(try XCTUnwrap(kept).timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 1,
                       "the generation in use is marked as used")
    }

    /// A cache that can't be written (read-only volume, disk full) costs retranslation, not effects.
    func testUnwritableCacheStillTranslates() throws {
        let cache = temporaryDirectory("readonly")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: cache.path)
        let compiler = FakeCompiler(fingerprint: "a", marker: "a")
        let variant = try ShaderVariantTranslator(compiler: compiler, cacheDirectory: cache)
            .variant(vertex: vertex, fragment: fragment, combos: [:])
        XCTAssertEqual(variant.fragmentMSL, "// a")
        XCTAssertEqual(ShaderVariantTranslator.cachedVariantCount(in: cache), 0)
    }

    /// A truncated cache file (killed mid-write by an older build, disk full) is retranslated.
    func testCorruptCachedVariantIsRetranslated() throws {
        let cache = temporaryDirectory("variants")
        let compiler = FakeCompiler(fingerprint: "a", marker: "a")
        let translator = ShaderVariantTranslator(compiler: compiler, cacheDirectory: cache)
        let key = ShaderVariantTranslator.cacheKey(vertex: vertex, fragment: fragment, combos: [:], toolchain: "a")
        let directory = try XCTUnwrap(translator.generationDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{\"vertexMSL\":".utf8).write(to: directory.appending(path: "\(key).json"))
        XCTAssertEqual(try translator.variant(vertex: vertex, fragment: fragment, combos: [:]).vertexMSL, "// a")
        XCTAssertEqual(compiler.compiles, 2)
    }

    // MARK: - Compiler choice (risks 7, 8)

    private func stateDirectory() -> URL { temporaryDirectory("compiler-state") }

    /// The linked libraries are used whether or not Homebrew's tools are installed.
    func testFactoryPrefersTheLinkedCompiler() throws {
        let compiler = try ShaderCompilerFactory.makeDefault(stateDirectory: stateDirectory())
        XCTAssertTrue(compiler is InProcessShaderCompiler, "\(type(of: compiler))")
        XCTAssertTrue(compiler.cacheFingerprint.hasPrefix("in-process|"))
    }

    /// After repeated deaths mid-compile the installed tools take over; without them the linked
    /// libraries stay, since they are the only compiler there is.
    func testFactoryFallsBackOnlyAfterRepeatedCrashes() throws {
        let directory = stateDirectory()
        for _ in 0..<InProcessCompileCrashGuard.disableThreshold {
            InProcessCompileCrashGuard(directory: directory, pid: Int32.max).begin()
            _ = InProcessCompileCrashGuard(directory: directory).allowsInProcess(fingerprint: InProcessShaderCompiler.libraryFingerprint)
        }
        let compiler = try ShaderCompilerFactory.makeDefault(stateDirectory: directory)
        if SceneShaderTranslator.toolchain != nil {
            XCTAssertTrue(compiler is ProcessShaderCompiler, "\(type(of: compiler))")
        } else {
            XCTAssertTrue(compiler is InProcessShaderCompiler, "\(type(of: compiler))")
        }
    }

    /// The source a compiler step rejected lands in the failure directory (CLAUDE.md's
    /// `/tmp/owe-failed-shaders`), with the error after it so its line numbers still match.
    func testRejectedSourceIsWrittenForInspection() throws {
        let failures = temporaryDirectory("failed-shaders")
        let translator = ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: nil,
                                                 failureDirectory: failures)
        let vertex = ShaderSource(stage: .vertex, path: "effects/x/ok", text: "void main() { gl_Position = vec4(0.0); }",
                                  combos: [], uniforms: [])
        let fragment = ShaderSource(stage: .fragment, path: "effects/x/bad", text: "void main() { nope(); }",
                                    combos: [], uniforms: [])
        XCTAssertThrowsError(try translator.variant(vertex: vertex, fragment: fragment, combos: [:]))
        let names = try FileManager.default.contentsOfDirectory(atPath: failures.path)
        XCTAssertEqual(names, ["effects_x_bad.frag"])
        let text = try String(contentsOf: failures.appending(path: "effects_x_bad.frag"), encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let source = try XCTUnwrap(lines.firstIndex { $0.contains("nope()") })
        let error = try XCTUnwrap(lines.lastIndex { $0.hasPrefix("// ") && $0.contains("nope") })
        XCTAssertLessThan(source, error, "the error follows the source")
        XCTAssertEqual(ShaderVariantTranslator.defaultFailureDirectory.path, "/tmp/owe-failed-shaders")
    }

    /// Malformed WE sources (truncated, garbled) fail with an error; none may abort the app.
    func testGarbledSourcesFailWithoutCrashing() throws {
        let assets = ShaderVariantTests.weAssets
        let loader = ShaderSourceLoader(roots: [assets])
        let compiler = InProcessShaderCompiler()
        var sources: [String] = []
        for path in ["effects/blur/shaders/effects/blur_gaussian", "effects/tint/shaders/effects/tint",
                     "effects/shake/shaders/effects/shake", "effects/waterripple/shaders/effects/waterripple"] {
            guard FileManager.default.fileExists(atPath: assets.appending(path: "\(path).frag").path) else { continue }
            sources.append(try loader.load(path, stage: .fragment).text)
        }
        XCTAssertFalse(sources.isEmpty)
        var generator = SystemRandomNumberGenerator()
        for source in sources {
            let bytes = Array(source.utf8)
            var cases = (1...8).map { String(decoding: bytes.prefix(bytes.count * $0 / 9), as: UTF8.self) }
            for _ in 0..<8 {
                var garbled = bytes
                for _ in 0..<16 { garbled[Int.random(in: 0..<garbled.count, using: &generator)] = UInt8.random(in: 32...126, using: &generator) }
                cases.append(String(decoding: garbled, as: UTF8.self))
            }
            cases += [String(repeating: "#define A(x) A(x)\nA(1)\n", count: 4), String(repeating: "(", count: 20_000),
                      "#if 1\n" + String(repeating: "#if 1\n", count: 2000), "\u{0}\u{1}\u{2}"]
            for text in cases {
                // Either outcome is fine; returning at all is the test.
                _ = try? compiler.preprocess(text, stage: .fragment)
                _ = try? compiler.compileToMSL("#version 150\n" + text, stage: .fragment)
            }
        }
    }
}
