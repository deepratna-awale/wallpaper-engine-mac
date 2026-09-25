import Foundation
import ShaderToolchain

/// glslang and SPIRV-Cross linked into the app (`Vendor/ShaderToolchain`). Produces the same
/// output as `ProcessShaderCompiler` with the same library versions, without spawning a process
/// per step. Calls are serialized inside the library (glslang's global state is not thread-safe).
struct InProcessShaderCompiler: ShaderCompiler {
    /// Marks compiles in flight, so a crash inside the library is noticed on the next launch.
    let crashGuard: InProcessCompileCrashGuard?

    init(crashGuard: InProcessCompileCrashGuard? = nil) {
        self.crashGuard = crashGuard
    }

    static var libraryFingerprint: String { String(cString: owe_shader_toolchain_fingerprint()) }

    var cacheFingerprint: String { "in-process|\(Self.libraryFingerprint)" }

    func preprocess(_ source: String, stage: ShaderStage) throws -> String {
        try guarded {
            var output: UnsafeMutablePointer<CChar>?
            var log: UnsafeMutablePointer<CChar>?
            defer { owe_shader_free(output); owe_shader_free(log) }
            guard owe_shader_preprocess(source, stage.library, &output, &log) != 0, let output else {
                throw ShaderCompilerError.failed(step: "preprocess", output: Self.errors(log))
            }
            return String(cString: output)
        }
    }

    func compileToMSL(_ source: String, stage: ShaderStage) throws -> (msl: String, reflection: Data) {
        try guarded {
            var msl: UnsafeMutablePointer<CChar>?
            var reflection: UnsafeMutablePointer<CChar>?
            var log: UnsafeMutablePointer<CChar>?
            var step: UnsafePointer<CChar>?
            defer { owe_shader_free(msl); owe_shader_free(reflection); owe_shader_free(log) }
            guard owe_shader_compile_msl(source, stage.library, &msl, &reflection, &log, &step) != 0,
                  let msl, let reflection else {
                throw ShaderCompilerError.failed(step: step.map { String(cString: $0) } ?? "glslang",
                                                 output: Self.errors(log))
            }
            return (String(cString: msl), Data(String(cString: reflection).utf8))
        }
    }

    private func guarded<T>(_ body: () throws -> T) throws -> T {
        crashGuard?.begin()
        defer { crashGuard?.end() }
        return try body()
    }

    /// The error lines of an info log, like `ProcessShaderCompiler` reports them.
    private static func errors(_ log: UnsafeMutablePointer<CChar>?) -> String {
        let text = log.map { String(cString: $0) } ?? ""
        let lines = text.split(separator: "\n").filter { $0.contains("ERROR") || $0.contains("error") }.prefix(8)
        return lines.isEmpty ? (text.isEmpty ? "failed" : String(text.prefix(800))) : lines.joined(separator: "\n")
    }
}

private extension ShaderStage {
    var library: owe_shader_stage {
        switch self {
        case .vertex: return OWE_SHADER_STAGE_VERTEX
        case .fragment: return OWE_SHADER_STAGE_FRAGMENT
        }
    }
}
