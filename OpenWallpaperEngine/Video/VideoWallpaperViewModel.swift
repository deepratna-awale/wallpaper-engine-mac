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

    @Published var currentWallpaper: WEWallpaper {
        didSet {
            replacePlayers(with: currentWallpaper)
        }
    }

    var playRate: Float = 0 {
        didSet {
            updatePlaybackRates(audioLevel: AudioReactiveScriptEngine.shared.audioLevel)
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
    private let ownAudioTap = AudioLevelTap()
    private var cancellables = Set<AnyCancellable>()
    private var itemEndObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var musicSyncObserver: NSObjectProtocol?

    /// Rates last handed to AVFoundation, so redundant assignments can be skipped.
    private var appliedVideoRate: Float?
    private var appliedAudioRate: Float?
    private var smoothedAudioLevel: Double = 0
    private static let rateEpsilon: Float = 0.01
    private static let audioSmoothing = 0.25

    init(
        wallpaper currentWallpaper: WEWallpaper,
        playsAudio: Bool = true,
        wallpaperViewModel: WallpaperViewModel
    ) {
        self.currentWallpaper = currentWallpaper
        self.playsAudio = playsAudio
        self.wallpaperViewModel = wallpaperViewModel
        self.player = AVPlayer(url: currentWallpaper.mediaURL)
        self.audioPlayer = AVPlayer(url: currentWallpaper.mediaURL)
        self.player.isMuted = true
        self.audioPlayer.currentItem?.audioTimePitchAlgorithm = .timeDomain
        self.audioPlayer.isMuted = !playsAudio
        if let audioItem = self.audioPlayer.currentItem { ownAudioTap.attach(to: audioItem) }
        observeItemEnd(of: self.player.currentItem)
        // Block-based observers with a weak target, so this instance can still deinit (and stop
        // playback) when the wallpaper view is torn down instead of being kept alive forever.
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.systemWillSleep()
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.systemDidWake()
        }
        musicSyncObserver = NotificationCenter.default.addObserver(forName: .videoMusicSyncAudioLevelDidChange, object: nil, queue: .main) { [weak self] notification in
            self?.videoMusicSyncAudioLevelDidChange(notification)
        }

        wallpaperViewModel.$playRate
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rate in
                self?.playRate = rate
            }
            .store(in: &cancellables)
        wallpaperViewModel.$audioPlayRate
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // Assigning the rate directly here used to restart audio even while paused.
                self?.updatePlaybackRates(audioLevel: AudioReactiveScriptEngine.shared.audioLevel)
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
        player.pause()
        audioPlayer.pause()
        if let itemEndObserver { NotificationCenter.default.removeObserver(itemEndObserver) }
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        if let musicSyncObserver { NotificationCenter.default.removeObserver(musicSyncObserver) }
    }

    func setAudioEnabled(_ enabled: Bool) {
        player.isMuted = true
        audioPlayer.isMuted = !enabled
        updatePlaybackRates(audioLevel: AudioReactiveScriptEngine.shared.audioLevel)
    }

    /// The wallpaper's own soundtrack drives music sync whenever you can actually hear it;
    /// otherwise sync follows whatever else is playing on the system.
    var musicSyncLevel: Double {
        !audioPlayer.isMuted && audioPlayer.volume > 0 && ownAudioTap.isMeasuring
            ? ownAudioTap.level
            : AudioReactiveScriptEngine.shared.audioLevel
    }

    func updatePlaybackRates(audioLevel: Double) {
        let paceAmount = VideoMusicSyncSettings.bool(currentWallpaper, "paceEnabled")
            ? VideoMusicSyncSettings.double(currentWallpaper, "paceAmount", default: 0.25)
            : 0
        // The raw level is per-sample noisy; pacing straight off it reads as stutter rather than
        // a pulse. Smoothing is skipped when pacing is off so play/pause stays instant.
        let level = musicSyncLevel
        if paceAmount > 0 {
            smoothedAudioLevel += (level - smoothedAudioLevel) * Self.audioSmoothing
        } else {
            smoothedAudioLevel = level
        }
        // A paused wallpaper stays paused; pacing only modulates a video that is playing.
        setVideoRate(playRate > 0 ? max(0, playRate + Float(smoothedAudioLevel * paceAmount)) : 0)
        // Audio runs on a second player, so a paused wallpaper keeps playing sound unless the
        // pause is applied here too.
        setAudioRate(playsAudio && !audioPlayer.isMuted && playRate > 0 ? wallpaperViewModel.audioPlayRate : 0)
    }

    /// Assigning `AVPlayer.rate` restarts the timebase, so doing it on every audio sample stutters
    /// the video and pitches the audio. Only meaningful changes are forwarded.
    private func setVideoRate(_ rate: Float) {
        if let applied = appliedVideoRate, abs(rate - applied) <= Self.rateEpsilon { return }
        appliedVideoRate = rate
        player.rate = rate
    }

    private func setAudioRate(_ rate: Float) {
        if let applied = appliedAudioRate, abs(rate - applied) <= Self.rateEpsilon { return }
        appliedAudioRate = rate
        audioPlayer.rate = rate
    }

    private func playerDidFinishPlaying(_ notification: Notification) {
        wallpaperViewModel.advancePlaylistIfVideoEnds(currentWallpaper)
        self.player.seek(to: CMTime.zero)
        self.audioPlayer.seek(to: CMTime.zero)
        updatePlaybackRates(audioLevel: AudioReactiveScriptEngine.shared.audioLevel)
    }

    private func systemWillSleep() {
        setVideoRate(0)
        setAudioRate(0)
    }

    private func systemDidWake() {
        updatePlaybackRates(audioLevel: AudioReactiveScriptEngine.shared.audioLevel)
    }

    private func videoMusicSyncAudioLevelDidChange(_ notification: Notification) {
        let level = notification.userInfo?["level"] as? Double ?? AudioReactiveScriptEngine.shared.audioLevel
        updatePlaybackRates(audioLevel: level)
    }

    private func observeItemEnd(of item: AVPlayerItem?) {
        if let itemEndObserver {
            NotificationCenter.default.removeObserver(itemEndObserver)
        }
        itemEndObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] notification in
            self?.playerDidFinishPlaying(notification)
        }
    }

    private func replacePlayers(with wallpaper: WEWallpaper) {
        // New AVPlayers start at rate 0, so the cached values no longer describe them.
        appliedVideoRate = nil
        appliedAudioRate = nil
        let url = wallpaper.mediaURL
        let videoItem = AVPlayerItem(url: url)
        let audioItem = AVPlayerItem(url: url)
        audioItem.audioTimePitchAlgorithm = .timeDomain

        player.replaceCurrentItem(with: videoItem)
        audioPlayer.replaceCurrentItem(with: audioItem)
        player.isMuted = true
        audioPlayer.isMuted = !playsAudio
        ownAudioTap.attach(to: audioItem)
        observeItemEnd(of: videoItem)
        updatePlaybackRates(audioLevel: AudioReactiveScriptEngine.shared.audioLevel)
    }
}
