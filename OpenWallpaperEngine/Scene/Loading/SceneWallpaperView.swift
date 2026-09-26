//
//  SceneWallpaperView.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/13.
//

import SwiftUI
import MetalKit

/// A scene (or Metal video) wallpaper on one display: a presenter of the wallpaper's shared
/// instance (`SceneWallpaperInstance`), which every display showing the same wallpaper holds.
/// A display switched to another wallpaper gets a new view (`WallpaperView` keys it by the
/// wallpaper), and with it that wallpaper's instance.
struct SceneWallpaperView: NSViewRepresentable {
    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    let screenId: String

    func makeCoordinator() -> SceneWallpaperPresenter { SceneWallpaperPresenter() }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero)
        let wallpaper = wallpaperViewModel.wallpaper(for: screenId)
        let environment = SceneWallpaperEnvironment(wallpapers: wallpaperViewModel,
                                                    settings: AppDelegate.shared.globalSettingsViewModel,
                                                    scriptServices: AppDelegate.shared.sceneScriptServices)
        let screenId = screenId
        let lease = SceneWallpaperPresenter.Lease(wallpaperViewModel.sceneInstances, key: WallpaperInstanceKey(wallpaper)) {
            SceneWallpaperInstance(wallpaper: wallpaper, environment: environment, screenID: screenId)
        }
        context.coordinator.show(lease, in: view)
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.instance?.update()
    }

    static func dismantleNSView(_ view: MTKView, coordinator: SceneWallpaperPresenter) {
        coordinator.stop()
    }
}
