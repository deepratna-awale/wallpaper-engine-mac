//
//  VideoWallpaperView.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/13.
//

import Cocoa
import SwiftUI
import AVKit

struct VideoWallpaperView: NSViewRepresentable {
    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    @StateObject var viewModel: VideoWallpaperViewModel
    let screenId: String

    init(wallpaperViewModel: WallpaperViewModel, screenId: String) {
        self.wallpaperViewModel = wallpaperViewModel
        self.screenId = screenId
        self._viewModel = StateObject(wrappedValue: VideoWallpaperViewModel(
            wallpaper: wallpaperViewModel.wallpaper(for: screenId),
            playsAudio: wallpaperViewModel.shouldPlayAudio(on: screenId),
            wallpaperViewModel: wallpaperViewModel
        ))
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()

        view.player = viewModel.player

        view.videoGravity = videoGravity(for: wallpaperViewModel.wallpaperPlacement)

        // hide any unneeded ui component, we want just the video output
        view.controlsStyle = .none

        // make sure this video player won't show any info in the system control center
        view.updatesNowPlayingInfoCenter = false

        // mark the flag as unneeded, improve performance and reduce power drain
        view.allowsVideoFrameAnalysis = false

        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        let selectedWallpaper = wallpaperViewModel.wallpaper(for: screenId)
        let currentWallpaper = viewModel.currentWallpaper

        if selectedWallpaper.wallpaperDirectory.appending(path: selectedWallpaper.project.file) != currentWallpaper.wallpaperDirectory.appending(path: currentWallpaper.project.file) {
            viewModel.currentWallpaper = selectedWallpaper
        }

        viewModel.playRate = wallpaperViewModel.playRate
        viewModel.playVolume = wallpaperViewModel.shouldPlayAudio(on: screenId)
            ? wallpaperViewModel.playVolume
            : 0
        viewModel.setAudioEnabled(wallpaperViewModel.shouldPlayAudio(on: screenId))
        nsView.videoGravity = videoGravity(for: wallpaperViewModel.wallpaperPlacement)
    }

    private func videoGravity(for placement: WallpaperPlacement) -> AVLayerVideoGravity {
        switch placement {
        case .stretch:
            return .resize
        case .fill, .zoom:
            return .resizeAspectFill
        case .fit, .center:
            return .resizeAspect
        }
    }
}
