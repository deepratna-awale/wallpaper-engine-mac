import SwiftUI

/// Surfaces the state the shader pipeline depends on, so a wallpaper that renders wrong can be
/// told apart from a toolchain that never loaded.
struct DiagnosticsPage: SettingsPage {
    var viewModel: GlobalSettingsViewModel

    init(globalSettings: GlobalSettingsViewModel) {
        self.viewModel = globalSettings
    }

    @State private var toolchain = SceneShaderTranslator.toolchain
    @State private var shaderCounts = DiagnosticsPage.shaderCacheCounts()

    var body: some View {
        Form {
            Section {
                row("Source", WallpaperEngineAssets.isUsingBundledAssets ? "Built-in" : "Wallpaper Engine install")
                if let directory = WallpaperEngineAssets.directory {
                    row("Path", directory.path, monospaced: true)
                } else {
                    Label("No assets available", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                row("Effect parameters",
                    "\(SceneAuthoredEffectRanges.effectCount) effects, \(SceneAuthoredEffectRanges.parameterCount) parameters")
            } header: {
                Label("Assets", systemImage: "shippingbox")
            }

            Section {
                if let toolchain {
                    Label("Available", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    row("glslang", toolchain.glslang, monospaced: true)
                    row("spirv-cross", toolchain.spirvCross, monospaced: true)
                } else {
                    Label("Unavailable — Workshop effects fall back to built-in shaders",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Install with: brew install glslang spirv-cross")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Button("Re-detect") {
                    SceneShaderTranslator.invalidateToolchainCache()
                    toolchain = SceneShaderTranslator.toolchain
                }
            } header: {
                Label("Shader Toolchain", systemImage: "hammer")
            } footer: {
                Text("Shaders are translated from GLSL to Metal once and cached. A missing toolchain only "
                     + "matters for effects that were never translated.")
            }

            Section {
                row("Translated", "\(shaderCounts.metal)")
                row("Compiled libraries", "\(shaderCounts.metallib)")
                row("Reflection sidecars", "\(shaderCounts.reflection)")
                if shaderCounts.unsupported > 0 {
                    row("Unsupported by Metal", "\(shaderCounts.unsupported)")
                }
                Button("Refresh") { shaderCounts = DiagnosticsPage.shaderCacheCounts() }
            } header: {
                Label("Shader Cache", systemImage: "square.stack.3d.up")
            } footer: {
                // A library count below the translated count means some shaders could not be
                // expressed in Metal; those effects fall back to the built-in approximations.
                Text(shaderCounts.metallib < shaderCounts.metal
                     ? "\(shaderCounts.metal - shaderCounts.metallib) shader(s) have no Metal library."
                     : "Every translated shader has a compiled library.")
            }
        }
        .formStyle(.grouped)
        .onAppear { shaderCounts = DiagnosticsPage.shaderCacheCounts() }
    }

    @ViewBuilder
    private func row(_ title: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer()
            Text(value)
                .font(monospaced ? .caption.monospaced() : .body)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private struct ShaderCounts {
        var metal = 0, metallib = 0, reflection = 0, unsupported = 0
    }

    private static func shaderCacheCounts() -> ShaderCounts {
        var counts = ShaderCounts()
        guard let shaders = WallpaperEngineAssets.directory?
            .appending(path: ".open-wallpaper-engine/shaders", directoryHint: .isDirectory),
              let names = try? FileManager.default.contentsOfDirectory(atPath: shaders.path) else { return counts }
        for name in names {
            if name.hasSuffix(".metallib") { counts.metallib += 1 }
            else if name.hasSuffix(".reflection.json") { counts.reflection += 1 }
            else if name.hasSuffix(".unsupported") { counts.unsupported += 1 }
            else if name.hasSuffix(".metal") { counts.metal += 1 }
        }
        return counts
    }
}
