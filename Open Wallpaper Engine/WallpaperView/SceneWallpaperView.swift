//
//  SceneWallpaperView.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/13.
//

import Cocoa
import SwiftUI
import SpriteKit

struct SceneWallpaperView: NSViewRepresentable {
    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    @StateObject var viewModel: SceneWallpaperViewModel
    let screenId: String

    init(wallpaperViewModel: WallpaperViewModel, screenId: String) {
        self.wallpaperViewModel = wallpaperViewModel
        self.screenId = screenId
        self._viewModel = StateObject(wrappedValue: SceneWallpaperViewModel(wallpaper: wallpaperViewModel.wallpaper(for: screenId)))
    }

    func makeNSView(context: Context) -> SKView {
        let skView = SKView(frame: .zero)
        skView.ignoresSiblingOrder = false
        skView.allowsTransparency = false
        skView.isPaused = false
        skView.scene?.scaleMode = sceneScaleMode(for: wallpaperViewModel.wallpaperPlacement)
        skView.preferredFramesPerSecond = Int(AppDelegate.shared.globalSettingsViewModel.settings.fps)

        if let scene = viewModel.skScene {
            skView.presentScene(scene)
            scene.scaleMode = sceneScaleMode(for: wallpaperViewModel.wallpaperPlacement)
            skView.setNeedsDisplay(skView.bounds)
        }

        return skView
    }

    func updateNSView(_ skView: SKView, context: Context) {
        let selectedWallpaper = wallpaperViewModel.wallpaper(for: screenId)
        let currentWallpaper = viewModel.currentWallpaper

        // Update scene if wallpaper changed
        if selectedWallpaper.wallpaperDirectory.appending(path: selectedWallpaper.project.file)
            != currentWallpaper.wallpaperDirectory.appending(path: currentWallpaper.project.file) {
            viewModel.currentWallpaper = selectedWallpaper
        }

        // Present scene if available and not already presented
        if let scene = viewModel.skScene, skView.scene !== scene {
            skView.presentScene(scene)
            scene.scaleMode = sceneScaleMode(for: wallpaperViewModel.wallpaperPlacement)
            skView.setNeedsDisplay(skView.bounds)
        }

        // Update FPS
        skView.preferredFramesPerSecond = Int(AppDelegate.shared.globalSettingsViewModel.settings.fps)
        skView.scene?.scaleMode = sceneScaleMode(for: wallpaperViewModel.wallpaperPlacement)

        // Pause/resume based on play rate
        skView.isPaused = wallpaperViewModel.playRate == 0
    }

    private func sceneScaleMode(for placement: WallpaperPlacement) -> SKSceneScaleMode {
        switch placement {
        case .stretch:
            return .resizeFill
        case .fill, .zoom:
            return .aspectFill
        case .fit, .center:
            return .aspectFit
        }
    }
}
