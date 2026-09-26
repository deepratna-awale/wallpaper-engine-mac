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
    @ObservedObject var viewModel: VideoWallpaperViewModel
    let screenId: String

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

    /// Playback, volume and sound follow the app's controls in the shared view model; a display
    /// only places the picture.
    func updateNSView(_ nsView: AVPlayerView, context: Context) {
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

/// A video wallpaper (AVKit path) on one display: a view of the video's shared player
/// (`WallpaperViewModel.videoInstances`), so the video decodes and plays its sound once however
/// many displays show it. `WallpaperView` keys it by the wallpaper, so a display switched to
/// another video gets that video's player.
struct AudioReactiveVideoWallpaperView: View {
    typealias Lease = WallpaperInstanceLease<WallpaperInstanceKey, VideoWallpaperViewModel>

    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    @StateObject private var lease: Lease
    let screenId: String

    init(wallpaperViewModel: WallpaperViewModel, screenId: String) {
        self.wallpaperViewModel = wallpaperViewModel
        self.screenId = screenId
        let wallpaper = wallpaperViewModel.wallpaper(for: screenId)
        self._lease = StateObject(wrappedValue: Lease(wallpaperViewModel.videoInstances, key: WallpaperInstanceKey(wallpaper)) {
            VideoWallpaperViewModel(wallpaper: wallpaper, wallpaperViewModel: wallpaperViewModel)
        })
    }

    private var viewModel: VideoWallpaperViewModel { lease.instance }

    var body: some View {
        TimelineView(.animation) { _ in
            let wallpaper = wallpaperViewModel.wallpaper(for: screenId)
            let audioLevel = viewModel.musicSyncLevel
            let zoom = VideoMusicSyncSettings.bool(wallpaper, "zoomEnabled")
                ? 1 + audioLevel * VideoMusicSyncSettings.double(wallpaper, "zoomAmount", default: 0.08)
                : 1
            let tilt = VideoMusicSyncSettings.bool(wallpaper, "tiltEnabled")
                ? audioLevel * VideoMusicSyncSettings.double(wallpaper, "tiltAmount", default: 3)
                : 0
            let saturation = VideoMusicSyncSettings.bool(wallpaper, "saturationEnabled")
                ? 1 + audioLevel * VideoMusicSyncSettings.double(wallpaper, "saturationAmount", default: 0.6)
                : 1
            VideoWallpaperView(wallpaperViewModel: wallpaperViewModel, viewModel: viewModel, screenId: screenId)
                .scaleEffect(max(0.1, zoom))
                .rotationEffect(.degrees(tilt))
                .saturation(max(0, saturation))
                .onChange(of: audioLevel) { _, newValue in
                    NotificationCenter.default.post(name: .videoMusicSyncAudioLevelDidChange,
                                                    object: nil,
                                                    userInfo: ["level": newValue])
                }
                .clipped()
        }
    }
}
