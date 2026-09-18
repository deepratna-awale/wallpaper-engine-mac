//
//  VideoWallpaperViewModel.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/14.
//

import AVKit
import SwiftUI
import Combine

@MainActor
class VideoWallpaperViewModel: ObservableObject {
    private let playsAudio: Bool
    private let wallpaperViewModel: WallpaperViewModel

    var currentWallpaper: WEWallpaper {
        didSet {
            if let oldItem = self.player.currentItem {
                NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: oldItem)
            }
            replacePlayers(with: currentWallpaper)
        }
    }

    var playRate: Float = 0 {
        didSet {
            self.player.rate = playRate
        }
    }

    var playVolume: Float = 0 {
        didSet {
            self.player.volume = playVolume
            self.audioPlayer.volume = playVolume
        }
    }

    var player = AVPlayer()
    private var audioPlayer = AVPlayer()
    private var cancellables = Set<AnyCancellable>()

    init(
        wallpaper currentWallpaper: WEWallpaper,
        playsAudio: Bool = true,
        wallpaperViewModel: WallpaperViewModel
    ) {
        self.currentWallpaper = currentWallpaper
        self.playsAudio = playsAudio
        self.wallpaperViewModel = wallpaperViewModel
        self.player = AVPlayer(url: currentWallpaper.wallpaperDirectory.appending(path: currentWallpaper.project.file))
        self.audioPlayer = AVPlayer(url: currentWallpaper.wallpaperDirectory.appending(path: currentWallpaper.project.file))
        self.player.isMuted = true
        self.audioPlayer.currentItem?.audioTimePitchAlgorithm = .timeDomain
        self.audioPlayer.isMuted = !playsAudio
        NotificationCenter.default.addObserver(self, selector: #selector(playerDidFinishPlaying(_:)), name: .AVPlayerItemDidPlayToEndTime, object: self.player.currentItem)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemWillSleep(_:)), name: NSWorkspace.screensDidSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemDidWake(_:)), name: NSWorkspace.didWakeNotification, object: nil)

        wallpaperViewModel.$playRate
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rate in
                self?.playRate = rate
            }
            .store(in: &cancellables)
        wallpaperViewModel.$audioPlayRate
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rate in
                self?.audioPlayer.rate = self?.playsAudio == true ? rate : 0
            }
            .store(in: &cancellables)
        wallpaperViewModel.$playVolume
            .receive(on: DispatchQueue.main)
            .sink { [weak self] volume in
                self?.playVolume = volume
            }
            .store(in: &cancellables)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func setAudioEnabled(_ enabled: Bool) {
        player.isMuted = true
        audioPlayer.isMuted = !enabled
        audioPlayer.rate = enabled ? wallpaperViewModel.audioPlayRate : 0
    }

    @objc private func playerDidFinishPlaying(_ notification: Notification) {
        self.player.seek(to: CMTime.zero)
        self.audioPlayer.seek(to: CMTime.zero)
        self.player.rate = self.playRate
        self.audioPlayer.rate = playsAudio ? wallpaperViewModel.audioPlayRate : 0
    }

    @objc private func playerDidStopPlaying(_ notification: Notification) {
        // Resume playback
        self.player.rate = self.playRate
    }

    @objc func systemWillSleep(_ notification: Notification) {
        self.player.rate = 0
        self.audioPlayer.rate = 0
    }

    @objc func systemDidWake(_ notification: Notification) {
        self.player.rate = self.playRate
        self.audioPlayer.rate = playsAudio ? wallpaperViewModel.audioPlayRate : 0
    }

    private func replacePlayers(with wallpaper: WEWallpaper) {
        let url = wallpaper.wallpaperDirectory.appending(path: wallpaper.project.file)
        let videoItem = AVPlayerItem(url: url)
        let audioItem = AVPlayerItem(url: url)
        audioItem.audioTimePitchAlgorithm = .timeDomain

        player.replaceCurrentItem(with: videoItem)
        audioPlayer.replaceCurrentItem(with: audioItem)
        player.isMuted = true
        audioPlayer.isMuted = !playsAudio
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerDidFinishPlaying(_:)),
            name: .AVPlayerItemDidPlayToEndTime,
            object: videoItem
        )
        player.rate = playRate
        audioPlayer.rate = playsAudio ? wallpaperViewModel.audioPlayRate : 0
    }
}
