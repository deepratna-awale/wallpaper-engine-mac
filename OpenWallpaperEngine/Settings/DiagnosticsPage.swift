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
                row("Translated variants", "\(shaderCounts)")
                Button("Refresh") { shaderCounts = DiagnosticsPage.shaderCacheCounts() }
            } header: {
                Label("Shader Cache", systemImage: "square.stack.3d.up")
            } footer: {
                Text("WE shaders are translated per combination of options the first time a scene uses them, then reused.")
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

    /// Shader variants translated so far (one per shader pair and option set).
    private static func shaderCacheCounts() -> Int {
        guard let directory = ShaderVariantTranslator.defaultCacheDirectory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return 0 } // no cache yet
        return names.filter { $0.hasSuffix(".json") }.count
    }
}
