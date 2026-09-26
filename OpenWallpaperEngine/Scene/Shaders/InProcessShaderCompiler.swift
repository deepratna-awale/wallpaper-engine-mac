import Foundation
import ShaderToolchain

/// glslang and SPIRV-Cross linked into the app (`Vendor/ShaderToolchain`). Produces the same
/// output as `ProcessShaderCompiler` with the same library versions, without spawning a process
/// per step. Calls are serialized inside the library (glslang's global state is not thread-safe).
///
/// Every call runs on the compiler's `ShaderCompileThread`, under a watchdog. A call that overruns
/// it fails (its variant is logged as failed), is recorded with the crash guard, and leaves the
/// library's lock held by a thread that can't be stopped: every later call this session goes to
/// `fallback` (the process compiler), or fails at once without one.
struct InProcessShaderCompiler: ShaderCompiler {
    /// Marks compiles in flight, so a crash inside the library is noticed on the next launch.
    let crashGuard: InProcessCompileCrashGuard?
    private let session: Session

    /// - Parameter fallback: makes the compiler used after a call hung; resolved on first need.
    init(crashGuard: InProcessCompileCrashGuard? = nil, timeout: TimeInterval = ShaderCompileThread.defaultTimeout,
         fallback: (() throws -> ShaderCompiler)? = nil) {
        self.crashGuard = crashGuard
        session = Session(thread: ShaderCompileThread(timeout: timeout), makeFallback: fallback)
    }

    static var libraryFingerprint: String { String(cString: owe_shader_toolchain_fingerprint()) }

    /// The fallback's once a call hung, so what it translates is cached under its own key.
    var cacheFingerprint: String {
        if session.thread.isStuck, let fallback = session.fallback() { return fallback.cacheFingerprint }
        return "in-process|\(Self.libraryFingerprint)"
    }

    /// Whether a call overran the watchdog this session (later calls don't use the libraries).
    var isStuck: Bool { session.thread.isStuck }

    /// The compile thread and the compiler that replaces it once it is stuck.
    ///
    /// Thread-safe: `lock` owns `resolved`.
    private final class Session {
        let thread: ShaderCompileThread
        private let makeFallback: (() throws -> ShaderCompiler)?
        private let lock = NSLock()
        private var resolved: ShaderCompiler??

        init(thread: ShaderCompileThread, makeFallback: (() throws -> ShaderCompiler)?) {
            self.thread = thread
            self.makeFallback = makeFallback
        }

        func fallback() -> ShaderCompiler? {
            lock.lock()
            defer { lock.unlock() }
            if let resolved { return resolved }
            var made: ShaderCompiler?
            if let makeFallback {
                do {
                    made = try makeFallback()
                } catch {
                    OWELog.error(.shader, "No fallback shader compiler after an in-process hang: \(error)")
                }
            }
            resolved = .some(made)
            return made
        }
    }

    func preprocess(_ source: String, stage: ShaderStage) throws -> String {
        try dispatch(step: "preprocess", fallback: { try $0.preprocess(source, stage: stage) }) {
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
        try dispatch(step: "glslang", fallback: { try $0.compileToMSL(source, stage: stage) }) {
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

    /// Runs `body` (a library call) on the compile thread, or `fallback` once the thread is stuck.
    func dispatch<T>(step: String, fallback: (ShaderCompiler) throws -> T,
                     _ body: @escaping () throws -> T) throws -> T {
        if session.thread.isStuck { return try routeAway(step: step, fallback) }
        crashGuard?.begin()
        defer { crashGuard?.end() }
        do {
            return try session.thread.run(body)
        } catch ShaderCompileThread.Failure.timedOut(let seconds) {
            OWELog.error(.shader, "In-process shader \(step) hung for \(Int(seconds.rounded())) s; "
                         + "the rest of this session compiles with the fallback compiler")
            crashGuard?.recordHang(fingerprint: Self.libraryFingerprint)
            throw ShaderCompilerError.failed(step: step, output: "timed out after \(Int(seconds.rounded())) s")
        } catch ShaderCompileThread.Failure.stuck {
            return try routeAway(step: step, fallback)
        }
    }

    private func routeAway<T>(step: String, _ fallback: (ShaderCompiler) throws -> T) throws -> T {
        guard let compiler = session.fallback() else {
            throw ShaderCompilerError.failed(step: step, output: "\(ShaderCompileThread.Failure.stuck), "
                                             + "and glslang/spirv-cross are not installed")
        }
        return try fallback(compiler)
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
