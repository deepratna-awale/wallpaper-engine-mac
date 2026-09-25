//
//  WallpaperView.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/6/5.
//

import Cocoa
import SwiftUI
import AVKit

struct WallpaperView: View {
    @ObservedObject var viewModel: WallpaperViewModel
    let screenId: String

    var body: some View {
        let wallpaper = viewModel.wallpaper(for: screenId)
        switch wallpaper.project.type.lowercased() {
        // A remote video is the same pipeline as a local one; only the URL differs.
        case "video", "remote-video":
            // The Metal path draws video as a scene layer so the effect stack applies to it.
            if AppDelegate.shared.globalSettingsViewModel.settings.videoFramework == .metal {
                SceneWallpaperView(wallpaperViewModel: viewModel, screenId: screenId)
            } else {
                AudioReactiveVideoWallpaperView(wallpaperViewModel: viewModel, screenId: screenId)
            }
        case "scene":
            SceneWallpaperView(wallpaperViewModel: viewModel, screenId: screenId)
        case "web":
            WebWallpaperView(wallpaperViewModel: viewModel, screenId: screenId)
        case "remote-image":
            RemoteImageWallpaperView(url: URL(string: wallpaper.project.file))
        default:
            EmptyView()
        }
    }
}

private final class RemoteImageLoader: ObservableObject {
    @Published var image: NSImage?
    private var task: URLSessionDownloadTask?

    func load(url: URL?) {
        guard let url else { return }
        let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "Open Wallpaper Engine/RemoteImages")
        let cacheURL = cacheDirectory.appending(path: String(url.absoluteString.hashValue) + ".image")
        if let cached = NSImage(contentsOf: cacheURL) {
            image = cached
            return
        }
        task?.cancel()
        task = URLSession.shared.downloadTask(with: url) { [weak self] temporaryURL, _, _ in
            guard let temporaryURL else { return }
            do {
                try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: temporaryURL, to: cacheURL)
                guard let image = NSImage(contentsOf: cacheURL) else { return }
                DispatchQueue.main.async { self?.image = image }
            } catch {
                NSLog("[RemoteWallpaper] Image cache failed: %@", error.localizedDescription)
            }
        }
        task?.resume()
    }
}

private struct RemoteImageWallpaperView: View {
    let url: URL?
    @StateObject private var loader = RemoteImageLoader()

    var body: some View {
        Group {
            if let image = loader.image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.black
            }
        }
        .ignoresSafeArea()
        .onAppear { loader.load(url: url) }
    }
}
