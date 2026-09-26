import Cocoa
import SwiftUI

struct PermissionsPage: SettingsPage {
    @ObservedObject var viewModel: GlobalSettingsViewModel
    @State private var hasScreenRecordingPermission = PermissionHelper.hasScreenRecordingPermission

    init(globalSettings viewModel: GlobalSettingsViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        Form {
            Section {
                permissionRow(
                    title: "Screen & System Audio Recording",
                    status: hasScreenRecordingPermission ? "Allowed" : "Required",
                    isGranted: hasScreenRecordingPermission,
                    description: "Needed for audio visualizers and audio-reactive SceneScript. macOS exposes system audio capture through Screen Recording permission."
                )
                HStack {
                    Button("Grant Access") {
                        PermissionHelper.grantScreenRecordingAccess()
                        refresh()
                    }
                    .disabled(hasScreenRecordingPermission)
                    Button("Open Privacy Settings") {
                        PermissionHelper.openScreenRecordingSettings()
                    }
                    Button("Recheck") {
                        refresh()
                    }
                }
            } header: {
                Label("Audio Visualizers", systemImage: "waveform")
            } footer: {
                Text("Audio capture starts on its own once the permission is granted; no restart is needed.")
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
    }

    /// Never prompts: only re-reads the grant and starts capture if it was newly granted.
    private func refresh() {
        hasScreenRecordingPermission = PermissionHelper.hasScreenRecordingPermission
        WallpaperServices.shared.recheckCapturePermission()
    }

    private func permissionRow(title: String, status: String, isGranted: Bool, description: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: isGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(isGranted ? .green : .orange)
                Spacer()
                Text(status)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isGranted ? .green : .orange)
            }
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

enum PermissionHelper {
    static var hasScreenRecordingPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Only for explicit user actions: this is the one place the app asks macOS to prompt. The
    /// system prompt itself links to the Privacy pane, and the Permissions page has a button for it.
    static func grantScreenRecordingAccess() {
        guard !CGPreflightScreenCaptureAccess() else { return }
        _ = CGRequestScreenCaptureAccess()
    }

    static func openScreenRecordingSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCaptureMicrophone",
            "x-apple.systempreferences:com.apple.preference.security"
        ]
        for value in candidates {
            guard let url = URL(string: value), NSWorkspace.shared.open(url) else { continue }
            return
        }
    }
}
