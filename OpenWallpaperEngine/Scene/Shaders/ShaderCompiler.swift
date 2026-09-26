import Foundation

enum ShaderCompilerError: Error, CustomStringConvertible {
    case toolchainUnavailable
    case failed(step: String, output: String)

    var description: String {
        switch self {
        case .toolchainUnavailable: return "glslang/spirv-cross not found"
        case .failed(let step, let output): return "\(step) failed: \(output)"
        }
    }
}

/// The GLSL → SPIR-V → MSL toolchain: `InProcessShaderCompiler` (linked libraries) or
/// `ProcessShaderCompiler` (the command line tools, kept as a fallback).
protocol ShaderCompiler {
    /// Identifies everything that decides the output: backend, tool/library versions and options.
    /// Part of the variant cache key; never machine-specific (no paths or dates).
    var cacheFingerprint: String { get }
    /// Runs the GLSL preprocessor only, resolving every `#if` against the defined macros.
    func preprocess(_ source: String, stage: ShaderStage) throws -> String
    /// Compiles preprocessed, fully decorated GLSL to MSL and returns it with SPIRV-Cross's
    /// reflection JSON.
    func compileToMSL(_ source: String, stage: ShaderStage) throws -> (msl: String, reflection: Data)
}

struct ProcessShaderCompiler: ShaderCompiler {
    let glslang: String
    let spirvCross: String
    let cacheFingerprint: String

    init(glslang: String, spirvCross: String) {
        self.glslang = glslang
        self.spirvCross = spirvCross
        cacheFingerprint = "process|" + Self.versions(glslang: glslang, spirvCross: spirvCross)
    }

    init() throws {
        guard let tools = SceneShaderTranslator.toolchain else { throw ShaderCompilerError.toolchainUnavailable }
        self.init(glslang: tools.glslang, spirvCross: tools.spirvCross)
    }

    func preprocess(_ source: String, stage: ShaderStage) throws -> String {
        try withScratch { directory in
            let input = directory.appending(path: "shader.\(stage.rawValue)")
            try source.write(to: input, atomically: false, encoding: .utf8)
            return try run(glslang, ["-E", "-S", stage.rawValue, input.path], step: "preprocess")
        }
    }

    func compileToMSL(_ source: String, stage: ShaderStage) throws -> (msl: String, reflection: Data) {
        try withScratch { directory in
            let input = directory.appending(path: "shader.\(stage.rawValue)")
            let spirv = directory.appending(path: "shader.spv")
            try source.write(to: input, atomically: false, encoding: .utf8)
            _ = try run(glslang, ["-G", "-S", stage.rawValue, "-o", spirv.path, input.path], step: "glslang")
            // The input file must come first: SPIRV-Cross options consume the argument after them.
            // Vertex stages map GL clip-space z (-w...w) to Metal's (0...w), and flip y so a pass
            // samples and writes rows exactly like GL: WE's texture-coordinate conventions (v = 0 is
            // the first row of every texture and render target) then hold unchanged.
            let clip = stage == .vertex ? ["--fixup-clipspace", "--flip-vert-y"] : []
            let msl = try run(spirvCross, [spirv.path, "--msl", "--msl-version", "20300", "--msl-decoration-binding"] + clip,
                              step: "spirv-cross")
            let reflection = try run(spirvCross, [spirv.path, "--reflect"], step: "reflect")
            return (msl, Data(reflection.utf8))
        }
    }

    /// `glslangValidator --version` and `spirv-cross --revision`, so an upgrade retranslates.
    /// A tool that can't report its version contributes its file name only; it fails loudly
    /// later, at translation.
    static func versions(glslang: String, spirvCross: String) -> String {
        let compiler = ProcessShaderCompiler(glslang: glslang, spirvCross: spirvCross, fingerprint: "")
        func version(_ tool: String, _ arguments: [String]) -> String {
            do {
                return try compiler.run(tool, arguments, step: "version", acceptAnyStatus: true)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                OWELog.error(.shader, "Could not read the version of \(tool): \(error)")
                return URL(fileURLWithPath: tool).lastPathComponent
            }
        }
        return version(glslang, ["--version"]) + "|" + version(spirvCross, ["--revision"])
    }

    private init(glslang: String, spirvCross: String, fingerprint: String) {
        self.glslang = glslang
        self.spirvCross = spirvCross
        cacheFingerprint = fingerprint
    }

    private func withScratch<T>(_ body: (URL) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory.appending(path: "owe-shader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) } // scratch cleanup; failure is harmless
        return try body(directory)
    }

    /// A single translation step normally takes milliseconds; anything this long is stuck.
    static let timeout: TimeInterval = 30

    private func run(_ executable: String, _ arguments: [String], step: String,
                     acceptAnyStatus: Bool = false) throws -> String {
        // Pipes and their file handles are autoreleased; a caller translating many variants in
        // one loop would otherwise run out of file descriptors ("Bad file descriptor").
        try autoreleasepool { try runDrained(executable, arguments, step: step, acceptAnyStatus: acceptAnyStatus) }
    }

    private func runDrained(_ executable: String, _ arguments: [String], step: String,
                            acceptAnyStatus: Bool) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        // Drain both pipes concurrently: a tool that fills one while we block reading the other
        // would never exit.
        let group = DispatchGroup()
        var stdout = Data()
        var stderr = Data()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stdout = output.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stderr = errors.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        if exited.wait(timeout: .now() + Self.timeout) == .timedOut {
            process.terminate()
            _ = exited.wait(timeout: .now() + 2)
            group.wait()
            throw ShaderCompilerError.failed(step: step, output: "timed out after \(Int(Self.timeout)) s")
        }
        group.wait()
        // Close our read ends now instead of whenever the handles are deallocated.
        try? output.fileHandleForReading.close() // already at EOF; a close error changes nothing
        try? errors.fileHandleForReading.close() // same
        let text = String(decoding: stdout, as: UTF8.self)
        // `spirv-cross --revision` prints to stderr and exits 1.
        if acceptAnyStatus { return text + String(decoding: stderr, as: UTF8.self) }
        guard process.terminationStatus == 0 else {
            let message = (text + String(decoding: stderr, as: UTF8.self))
                .split(separator: "\n").filter { $0.contains("ERROR") || $0.contains("error") }.prefix(8)
                .joined(separator: "\n")
            throw ShaderCompilerError.failed(step: step, output: message.isEmpty ? "exit \(process.terminationStatus)" : message)
        }
        return text
    }
}

/// Picks the shader compiler for the app: in-process unless it crashed with these libraries.
enum ShaderCompilerFactory {
    static func makeDefault(stateDirectory: URL? = ShaderVariantTranslator.defaultCacheDirectory?
        .deletingLastPathComponent().appending(path: "shader-compiler", directoryHint: .isDirectory)) throws -> ShaderCompiler {
        guard let stateDirectory else { return InProcessShaderCompiler() }
        let crashGuard = InProcessCompileCrashGuard(directory: stateDirectory)
        if crashGuard.allowsInProcess(fingerprint: InProcessShaderCompiler.libraryFingerprint) {
            return InProcessShaderCompiler(crashGuard: crashGuard, fallback: { try ProcessShaderCompiler() })
        }
        do {
            return try ProcessShaderCompiler()
        } catch {
            // Without the command line tools the linked libraries are the only compiler; safe
            // restart still keeps a wallpaper that crashes them from coming back on its own.
            OWELog.error(.shader, "glslang/spirv-cross not installed; compiling in-process despite earlier crashes")
            return InProcessShaderCompiler(crashGuard: crashGuard)
        }
    }
}
