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

/// The GLSL → SPIR-V → MSL toolchain. Behind a protocol so the process-spawning implementation can
/// be replaced by in-process glslang/SPIRV-Cross (Phase 2, M9) without touching callers.
protocol ShaderCompiler {
    /// Runs the GLSL preprocessor only, resolving every `#if` against the defined macros.
    func preprocess(_ source: String, stage: ShaderStage) throws -> String
    /// Compiles preprocessed, fully decorated GLSL to MSL and returns it with SPIRV-Cross's
    /// reflection JSON.
    func compileToMSL(_ source: String, stage: ShaderStage) throws -> (msl: String, reflection: Data)
}

struct ProcessShaderCompiler: ShaderCompiler {
    let glslang: String
    let spirvCross: String

    init(glslang: String, spirvCross: String) {
        self.glslang = glslang
        self.spirvCross = spirvCross
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
            // Vertex stages map GL clip-space z (-w...w) to Metal's (0...w).
            let clip = stage == .vertex ? ["--fixup-clipspace"] : []
            let msl = try run(spirvCross, [spirv.path, "--msl", "--msl-version", "20300", "--msl-decoration-binding"] + clip,
                              step: "spirv-cross")
            let reflection = try run(spirvCross, [spirv.path, "--reflect"], step: "reflect")
            return (msl, Data(reflection.utf8))
        }
    }

    private func withScratch<T>(_ body: (URL) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory.appending(path: "owe-shader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) } // scratch cleanup; failure is harmless
        return try body(directory)
    }

    private func run(_ executable: String, _ arguments: [String], step: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        // Read before waiting: a full pipe would otherwise block the tool forever.
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: stdout, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            let message = (text + String(decoding: stderr, as: UTF8.self))
                .split(separator: "\n").filter { $0.contains("ERROR") || $0.contains("error") }.prefix(8)
                .joined(separator: "\n")
            throw ShaderCompilerError.failed(step: step, output: message.isEmpty ? "exit \(process.terminationStatus)" : message)
        }
        return text
    }
}
