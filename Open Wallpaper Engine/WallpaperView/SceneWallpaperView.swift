//
//  SceneWallpaperView.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/13.
//

import Cocoa
import SwiftUI
import MetalKit

struct SceneWallpaperView: NSViewRepresentable {
    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    @StateObject var viewModel: SceneWallpaperViewModel
    let screenId: String

    init(wallpaperViewModel: WallpaperViewModel, screenId: String) {
        self.wallpaperViewModel = wallpaperViewModel
        self.screenId = screenId
        self._viewModel = StateObject(wrappedValue: SceneWallpaperViewModel(wallpaper: wallpaperViewModel.wallpaper(for: screenId)))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MTKView {
        let metalView = MTKView(frame: .zero)
        context.coordinator.renderer = SceneMetalRenderer(view: metalView)
        context.coordinator.propertyObserver = NotificationCenter.default.addObserver(
            forName: .sceneUserPropertiesDidChange, object: nil, queue: .main
        ) { [weak renderer = context.coordinator.renderer, weak sceneViewModel = viewModel] _ in
            renderer?.setContent(sceneViewModel?.metalContent())
            sceneViewModel.map { context.coordinator.metalRevision = $0.metalRevision }
        }
        context.coordinator.renderer?.setPlacement(wallpaperViewModel.wallpaperPlacement)
        context.coordinator.renderer?.setContent(viewModel.metalContent())
        context.coordinator.metalRevision = viewModel.metalRevision
        metalView.preferredFramesPerSecond = Int(AppDelegate.shared.globalSettingsViewModel.settings.fps)
        return metalView
    }

    func updateNSView(_ metalView: MTKView, context: Context) {
        let selectedWallpaper = wallpaperViewModel.wallpaper(for: screenId)
        let currentWallpaper = viewModel.currentWallpaper

        // Update scene if wallpaper changed
        if selectedWallpaper.wallpaperDirectory.appending(path: selectedWallpaper.project.file)
            != currentWallpaper.wallpaperDirectory.appending(path: currentWallpaper.project.file) {
            viewModel.currentWallpaper = selectedWallpaper
        }

        if context.coordinator.metalRevision != viewModel.metalRevision {
            context.coordinator.renderer?.setContent(viewModel.metalContent())
            context.coordinator.metalRevision = viewModel.metalRevision
        }
        context.coordinator.renderer?.setPlacement(wallpaperViewModel.wallpaperPlacement)
        metalView.preferredFramesPerSecond = Int(AppDelegate.shared.globalSettingsViewModel.settings.fps)
        metalView.isPaused = wallpaperViewModel.playRate == 0
    }

    final class Coordinator {
        var renderer: SceneMetalRenderer?
        var metalRevision = -1
        var propertyObserver: NSObjectProtocol?

        deinit {
            if let propertyObserver {
                NotificationCenter.default.removeObserver(propertyObserver)
            }
        }
    }
}
