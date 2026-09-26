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
    @AppStorage("ReclaimOriginalPackages") private var reclaimOriginalPackages = false
    @State private var reclaimableBytes: Int64 = 0
    @State private var reclaimedCount: Int?
    @State private var isReclaiming = false

    private var reclaimableDescription: String {
        guard reclaimableBytes > 0 else { return "No originals ready to remove" }
        let formatted = ByteCountFormatter.string(fromByteCount: reclaimableBytes, countStyle: .file)
        return "\(formatted) of originals can be removed"
    }

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
                if let volume = WallpaperStorage.unmountedVolume(of: WallpaperStorage.directory) {
                    Text("\(volume.lastPathComponent) isn't connected. Workshop downloads fail until you connect it or choose another folder.")
                        .font(.caption)
                        .foregroundStyle(.red)
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
                Text("Workshop downloads, their dependencies and imported wallpapers go into this folder. You can move the current library to the new location.")
            }
            Section {
                HStack {
                    Text(viewModel.settings.wallpaperEngineAssetsDirectory ?? "Using built-in assets")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose...") {
                        chooseWallpaperEngineAssetsDirectory()
                    }
                }
                if viewModel.settings.wallpaperEngineAssetsDirectory != nil {
                    Button("Use Built-in Assets") {
                        viewModel.setWallpaperEngineAssetsDirectory(nil)
                    }
                }
            } header: {
                Label("Wallpaper Engine Assets", systemImage: "shippingbox")
            } footer: {
                Text("Shared textures, effects and presets ship with the app, so this is optional. Point it at the assets folder of a Wallpaper Engine installation to use that copy instead \u{2014} useful if it is newer than the bundled one.")
            }
            Section {
                Toggle("Remove original packages after conversion", isOn: $reclaimOriginalPackages)
                HStack {
                    Text(reclaimableDescription)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reclaim Now") {
                        isReclaiming = true
                        DispatchQueue.global(qos: .utility).async {
                            let removed = WallpaperPackageConverter.reclaimEligibleSources()
                            let remaining = WallpaperPackageConverter.reclaimableBytes()
                            DispatchQueue.main.async {
                                reclaimedCount = removed
                                reclaimableBytes = remaining
                                isReclaiming = false
                            }
                        }
                    }
                    .disabled(isReclaiming || reclaimableBytes == 0)
                }
                if let reclaimedCount {
                    Text("Removed \(reclaimedCount) original package\(reclaimedCount == 1 ? "" : "s").")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Label("Converted Wallpapers", systemImage: "arrow.triangle.2.circlepath")
            } footer: {
                Text("Wallpapers are unpacked into plain files when imported. The original package is kept until the wallpaper has rendered from those files, reported no conversion warnings, and no other wallpaper depends on it.")
            }
            // MARK: Steam Workshop
            Section {
                SteamWebAPIKeyView()
            } header: {
                Label("Steam Web API Key", systemImage: "key")
            } footer: {
                Text("Needed to browse and search the Workshop. It is stored in your keychain and checked with Steam before saving. Without it, author names come from public Steam profiles.")
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
                }
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
                    Text("Metal (effects apply to video)").tag(GSVideoFramework.metal)
                }
            } header: {
                Label("Video", systemImage: "film")
            } footer: {
                Text("Metal draws video through the scene renderer so effects and music sync apply "
                     + "to it, the way Wallpaper Engine does. Experimental.")
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
        .onAppear {
            DispatchQueue.global(qos: .utility).async {
                let bytes = WallpaperPackageConverter.reclaimableBytes()
                DispatchQueue.main.async { reclaimableBytes = bytes }
            }
        }
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

    private func chooseWallpaperEngineAssetsDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose Wallpaper Engine assets folder"
        if panel.runModal() == .OK, let directory = panel.url {
            viewModel.setWallpaperEngineAssetsDirectory(directory)
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
