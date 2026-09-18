//
//  GeneralPage.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/12.
//

import Cocoa
import SwiftUI

struct GeneralPage: SettingsPage {
    @ObservedObject var viewModel: GlobalSettingsViewModel
    @State private var pendingStorageDirectory: URL?
    @State private var isStorageMoveConfirming = false
    @State private var storageError: String?
    
    init(globalSettings viewModel: GlobalSettingsViewModel) {
        self.viewModel = viewModel
    }
    
    var body: some View {
        Form {
            // MARK: Automatic Startup
            Section {
                Toggle("Start with macOS", isOn: $viewModel.settings.autoStart)
//                Toggle("Safe start after hibernation", isOn: $viewModel.settings.safeMode)
            } header: {
                Label("Automatic Startup", systemImage: "star.fill")
            }
            // MARK: Basic Setup
            Section {
                Picker("Language", selection: $viewModel.settings.language) {
                    Text("Follow System").tag(GSLocalization.followSystem)
                    Text("English").tag(GSLocalization.en_US)
                    Text("Chinese Simplified").tag(GSLocalization.zh_CN)
                }.disabled(true)
            } header: {
                Label("Basic Setup", systemImage: "gearshape.fill")
            }
            Section {
                HStack {
                    Text(WallpaperStorage.directory.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose...") {
                        chooseStorageDirectory()
                    }
                }
                if WallpaperStorage.usesCustomDirectory {
                    Button("Use Default Location") {
                        WallpaperStorage.resetToDefault()
                    }
                }
                if let storageError {
                    Text(storageError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Label("Wallpaper Storage", systemImage: "externaldrive")
            } footer: {
                Text("Choose a folder for downloaded and imported wallpapers. You can move the current library to the new location.")
            }
            // MARK: macOS
            Section {
                Toggle("Adjust Menu Bar Color", isOn: $viewModel.settings.adjustMenuBarTint)
            } header: {
                Label("macOS", systemImage: "apple.logo")
            }
            // MARK: Appearance
            Section {
                Picker("Theme", selection: $viewModel.settings.appearance) {
                    Text("Light").tag(GSAppearance.light)
                    Text("Dark").tag(GSAppearance.dark)
                    Text("Auto").tag(GSAppearance.followSystem)
                }
            } header: {
                Label("Appearance", systemImage: "paintpalette.fill")
            }
            // MARK: Audio
            Section {
                Toggle(isOn: $viewModel.settings.audioOutput) {
                    Text("Audio Output")
                }.disabled(true)
                Toggle(isOn: $viewModel.settings.reloadWhenChangingOutputDevice) {
                    Text("Reload when changing output device")
                }.disabled(true)
            } header: {
                Label("Audio", systemImage: "speaker.3.fill")
            }
            // MARK: Video
            Section {
                Picker("Video Framework", selection: $viewModel.settings.videoFramework) {
                    Text("Apple AVKit").tag(GSVideoFramework.avkit)
                }
            } header: {
                Label("Video", systemImage: "film")
            }
            // MARK: Advanced
            Section {
                Picker("Process Piority", selection: $viewModel.settings.processPiority) {
                    Text("Normal").tag(GSProcessPiority.normal)
                    Text("Below Normal").tag(GSProcessPiority.belowNormal)
                }
                Toggle("Pause when VRAM is exhausted", isOn: $viewModel.settings.pauseOnVRAMExhausted)
                Toggle("Restart after crashing", isOn: $viewModel.settings.restartAfterCrashing)
            } header: {
                Label("Advanced", systemImage: "wrench.and.screwdriver.fill")
            }
            // MARK: Developers
            Section {
                Picker("Log Level", selection: $viewModel.settings.logLevel) {
                    Text("None").tag(GSLogLevel.none)
                    Text("Errors Only").tag(GSLogLevel.error)
                    Text("Verbose").tag(GSLogLevel.verbose)
                }
            } header: {
                Label("Developer", systemImage: "number")
            }
            // MARK: Reset
            Section {
                HStack {
                    Text("Reset Config")
                    Spacer()
                    Button {
                        viewModel.settings = GlobalSettings()
                    } label: {
                        Text("Reset").frame(width: 100)
                    }
                    .tint(Color.red)
                    .buttonStyle(.borderedProminent)
                }
            } header: {
                Label("Reset", systemImage: "exclamationmark.triangle.fill")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Move Current Wallpapers?",
            isPresented: $isStorageMoveConfirming,
            titleVisibility: .visible
        ) {
            Button("Move Current Wallpapers") {
                setStorageDirectory(moveExisting: true)
            }
            Button("Use Empty Folder") {
                setStorageDirectory(moveExisting: false)
            }
            Button("Cancel", role: .cancel) {
                pendingStorageDirectory = nil
            }
        } message: {
            Text("Move existing wallpapers to the selected folder, or leave them in the current location and use the new folder from now on?")
        }
    }

    private func chooseStorageDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose Wallpaper Storage Folder"
        if panel.runModal() == .OK, let directory = panel.url {
            pendingStorageDirectory = directory
            isStorageMoveConfirming = true
        }
    }

    private func setStorageDirectory(moveExisting: Bool) {
        guard let directory = pendingStorageDirectory else { return }
        do {
            let migration = try WallpaperStorage.setDirectory(directory, moveExisting: moveExisting)
            if let migration {
                AppDelegate.shared.wallpaperViewModel.relocateWallpapers(
                    from: migration.source,
                    to: migration.destination
                )
            }
            DownloadedWallpaperIndex.shared.reloadFromLibrary()
            AppDelegate.shared.contentViewModel.refresh()
            storageError = nil
        } catch {
            storageError = error.localizedDescription
        }
        pendingStorageDirectory = nil
    }
}
