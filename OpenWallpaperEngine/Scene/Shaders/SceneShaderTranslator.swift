import Foundation
import CryptoKit

/// Finds glslang and SPIRV-Cross for `ProcessShaderCompiler`.
enum SceneShaderTranslator {
    /// Resolved once per launch. Bundled copies win so a packaged build works without Homebrew;
    /// otherwise fall back to the usual install locations and finally the user's PATH.
    struct Toolchain {
        let glslang: String
        let spirvCross: String
    }

    private static let toolchainLock = NSLock()
    nonisolated(unsafe) private static var resolvedToolchain: Toolchain??

    private static let searchDirectories: [String] = [
        Bundle.main.bundleURL.appending(path: "Contents/Resources/shader-tools").path,
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
            OWELog.error(.shader, "Shader toolchain unavailable; Workshop effects will fall back to native shaders only. Install with: brew install glslang spirv-cross")
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
