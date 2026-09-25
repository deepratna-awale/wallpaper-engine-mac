import Foundation
import CryptoKit

/// Finds glslang and SPIRV-Cross for `ProcessShaderCompiler`, the fallback compiler.
///
/// The app ships no copies of these tools: it translates with the linked libraries
/// (`InProcessShaderCompiler`) and uses installed tools only after those crashed
/// (`ShaderCompilerFactory`).
enum SceneShaderTranslator {
    /// Resolved once per launch: the usual install locations, then the user's PATH.
    struct Toolchain {
        let glslang: String
        let spirvCross: String
    }

    private static let toolchainLock = NSLock()
    nonisolated(unsafe) private static var resolvedToolchain: Toolchain??

    private static let searchDirectories: [String] = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/opt/local/bin",
        "/usr/bin"
    ]

    static var toolchain: Toolchain? {
        toolchainLock.lock()
        defer { toolchainLock.unlock() }
        if let resolvedToolchain { return resolvedToolchain }
        let resolved = locateToolchain()
        resolvedToolchain = .some(resolved)
        if let resolved {
            OWELog.info(.shader, "Shader toolchain: \(resolved.glslang) + \(resolved.spirvCross)")
        } else {
            OWELog.info(.shader, "No glslang/spirv-cross executables for the fallback shader compiler "
                        + "(optional: brew install glslang spirv-cross)")
        }
        return resolved
    }

    static func invalidateToolchainCache() {
        toolchainLock.lock()
        resolvedToolchain = nil
        toolchainLock.unlock()
    }

    private static func locateToolchain() -> Toolchain? {
        guard let glslang = locate(["glslangValidator", "glslang"]),
              let spirvCross = locate(["spirv-cross"]) else { return nil }
        return Toolchain(glslang: glslang, spirvCross: spirvCross)
    }

    private static func locate(_ names: [String]) -> String? {
        let fileManager = FileManager.default
        let pathDirectories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for directory in searchDirectories + pathDirectories {
            for name in names {
                let candidate = (directory as NSString).appendingPathComponent(name)
                if fileManager.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        return nil
    }
}
