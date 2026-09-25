import XCTest
@testable import OpenWallpaperEngine

/// The linked glslang/SPIRV-Cross (`InProcessShaderCompiler`) against the command line tools.
final class InProcessShaderCompilerTests: XCTestCase {
    private struct Job {
        let vertex: ShaderSource
        let fragment: ShaderSource
        let combos: [String: Int]
        var label: String { "\(vertex.path) \(combos.sorted { $0.key < $1.key })" }
    }

    /// Every vert/frag pair in the bundled WE assets, with default combos plus each declared combo
    /// switched on by itself.
    private static func corpus() throws -> [Job] {
        let assets = ShaderVariantTests.weAssets
        let loader = ShaderSourceLoader(roots: [assets])
        guard let files = FileManager.default.enumerator(at: assets, includingPropertiesForKeys: nil) else { return [] }
        var jobs: [Job] = []
        for case let url as URL in files where url.pathExtension == "vert" {
            let fragmentURL = url.deletingPathExtension().appendingPathExtension("frag")
            guard FileManager.default.fileExists(atPath: fragmentURL.path) else { continue }
            let relative = String(url.deletingPathExtension().path.dropFirst(assets.path.count + 1))
            let vertex = try loader.load(relative, stage: .vertex)
            let fragment = try loader.load(relative, stage: .fragment)
            let defaults = ShaderVariantTranslator.resolveCombos(vertex: vertex, fragment: fragment, overrides: [],
                                                                 boundTextureSlots: [0])
            jobs.append(Job(vertex: vertex, fragment: fragment, combos: defaults))
            for combo in Set((vertex.combos + fragment.combos).map(\.name)).sorted() where defaults[combo] != 1 {
                var combos = defaults
                combos[combo] = 1
                jobs.append(Job(vertex: vertex, fragment: fragment, combos: combos))
            }
        }
        return jobs.sorted { $0.label < $1.label }
    }

    private enum Outcome: Equatable {
        case translated(vertex: String, fragment: String, uniforms: UniformLayout?)
        case failed
    }

    /// Times the compiler steps alone (the translator's own Swift work is excluded).
    private final class TimedCompiler: ShaderCompiler {
        let base: ShaderCompiler
        private(set) var seconds: TimeInterval = 0
        private let lock = NSLock()
        init(_ base: ShaderCompiler) { self.base = base }
        var cacheFingerprint: String { base.cacheFingerprint }
        private func timed<T>(_ body: () throws -> T) rethrows -> T {
            let start = Date()
            defer { lock.withLock { seconds += Date().timeIntervalSince(start) } }
            return try body()
        }
        func preprocess(_ source: String, stage: ShaderStage) throws -> String {
            try timed { try base.preprocess(source, stage: stage) }
        }
        func compileToMSL(_ source: String, stage: ShaderStage) throws -> (msl: String, reflection: Data) {
            try timed { try base.compileToMSL(source, stage: stage) }
        }
    }

    private static func translate(_ job: Job, with compiler: ShaderCompiler) -> Outcome {
        // No disk cache: every call translates.
        let translator = ShaderVariantTranslator(compiler: compiler, cacheDirectory: nil)
        do {
            let variant = try translator.variant(vertex: job.vertex, fragment: job.fragment, combos: job.combos)
            return .translated(vertex: variant.vertexMSL, fragment: variant.fragmentMSL, uniforms: variant.uniforms)
        } catch {
            return .failed
        }
    }

    func testFingerprintNamesLibraryVersionsAndOptions() {
        let fingerprint = InProcessShaderCompiler().cacheFingerprint
        XCTAssertTrue(fingerprint.hasPrefix("in-process|glslang 16.6.0|spirv-cross vulkan-sdk-1.4.357.0|"), fingerprint)
        XCTAssertTrue(fingerprint.contains("msl20300"), fingerprint)
        XCTAssertFalse(fingerprint.contains("/Users") || fingerprint.contains("/opt"), "machine-specific: \(fingerprint)")
    }

    func testCacheKeyDiffersBetweenBackends() throws {
        try XCTSkipIf(SceneShaderTranslator.toolchain == nil, "glslang/spirv-cross not installed")
        let source = ShaderSource(stage: .vertex, path: "x", text: "void main() {}", combos: [], uniforms: [])
        let process = try ProcessShaderCompiler()
        XCTAssertTrue(process.cacheFingerprint.hasPrefix("process|"))
        XCTAssertFalse(process.cacheFingerprint.contains("/"), "machine-specific: \(process.cacheFingerprint)")
        XCTAssertNotEqual(
            ShaderVariantTranslator.cacheKey(vertex: source, fragment: source, combos: [:],
                                             toolchain: InProcessShaderCompiler().cacheFingerprint),
            ShaderVariantTranslator.cacheKey(vertex: source, fragment: source, combos: [:],
                                             toolchain: process.cacheFingerprint))
    }

    func testCompileErrorIsReportedNotFatal() {
        XCTAssertThrowsError(try InProcessShaderCompiler().compileToMSL("#version 150\nvoid main() { nope(); }",
                                                                        stage: .fragment)) { error in
            XCTAssertTrue("\(error)".contains("glslang"), "\(error)")
        }
        XCTAssertThrowsError(try InProcessShaderCompiler().preprocess("#if\n", stage: .vertex))
    }

    /// Byte-identical to the command line tools over the whole bundled corpus, and logs the cold
    /// translate time of both.
    func testMatchesProcessCompilerOverBundledCorpus() throws {
        try XCTSkipIf(SceneShaderTranslator.toolchain == nil, "glslang/spirv-cross not installed")
        let jobs = try Self.corpus()
        XCTAssertGreaterThan(jobs.count, 100)
        let process = TimedCompiler(try ProcessShaderCompiler())
        let inProcess = TimedCompiler(InProcessShaderCompiler())

        var start = Date()
        let expected = jobs.map { Self.translate($0, with: process) }
        let processSeconds = Date().timeIntervalSince(start)
        start = Date()
        let actual = jobs.map { Self.translate($0, with: inProcess) }
        let inProcessSeconds = Date().timeIntervalSince(start)

        var mismatches: [String] = []
        for (index, job) in jobs.enumerated() where expected[index] != actual[index] {
            mismatches.append(job.label)
        }
        XCTAssertEqual(mismatches, [], "in-process output differs from glslangValidator/spirv-cross")
        let translated = expected.filter { $0 != .failed }.count
        print(String(format: "shader corpus: %d variants (%d translated); cold translate total process %.2f s, "
                     + "in-process %.2f s; compiler steps alone process %.2f s, in-process %.2f s",
                     jobs.count, translated, processSeconds, inProcessSeconds, process.seconds, inProcess.seconds))
    }

    /// glslang is not thread-safe; the library serializes calls, so parallel output equals serial.
    func testParallelTranslationMatchesSerial() throws {
        let jobs = Array(try Self.corpus().prefix(24))
        let compiler = InProcessShaderCompiler()
        let serial = jobs.map { Self.translate($0, with: compiler) }
        let rounds = 4
        var parallel = [Outcome?](repeating: nil, count: jobs.count * rounds)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: jobs.count * rounds) { index in
            let outcome = Self.translate(jobs[index % jobs.count], with: compiler)
            lock.lock()
            parallel[index] = outcome
            lock.unlock()
        }
        for index in parallel.indices {
            XCTAssertEqual(parallel[index], serial[index % jobs.count], jobs[index % jobs.count].label)
        }
    }

    // MARK: - Crash guard

    private func guardDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "owe-guard-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testCrashGuardDisablesAfterRepeatedDeathsMidCompile() throws {
        let directory = try guardDirectory()
        // A pid that can't be running: begin() without end() is what a crash mid-compile leaves.
        InProcessCompileCrashGuard(directory: directory, pid: Int32.max).begin()
        XCTAssertTrue(InProcessCompileCrashGuard(directory: directory).allowsInProcess(fingerprint: "libs-1"),
                      "one death (a force quit looks the same) is not enough")
        XCTAssertTrue(InProcessCompileCrashGuard(directory: directory).allowsInProcess(fingerprint: "libs-1"),
                      "a launch without a death doesn't count")
        InProcessCompileCrashGuard(directory: directory, pid: Int32.max).begin()
        let guardNow = InProcessCompileCrashGuard(directory: directory)
        XCTAssertFalse(guardNow.allowsInProcess(fingerprint: "libs-1"))
        XCTAssertFalse(guardNow.allowsInProcess(fingerprint: "libs-1"), "stays disabled for the same libraries")
        XCTAssertTrue(guardNow.allowsInProcess(fingerprint: "libs-2"), "new libraries get another try")
    }

    func testCrashGuardReadsTheOldDisabledFormat() throws {
        let directory = try guardDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("libs-1".utf8).write(to: directory.appending(path: "disabled"))
        XCTAssertFalse(InProcessCompileCrashGuard(directory: directory).allowsInProcess(fingerprint: "libs-1"))
    }

    func testCrashGuardIgnoresLiveProcessesAndCleansUp() throws {
        let directory = try guardDirectory()
        let live = InProcessCompileCrashGuard(directory: directory)
        live.begin()
        live.begin()
        XCTAssertTrue(InProcessCompileCrashGuard(directory: directory).allowsInProcess(fingerprint: "x"))
        live.end()
        live.end()
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(left, [])
    }
}

