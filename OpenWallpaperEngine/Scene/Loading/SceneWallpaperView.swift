//
//  SceneWallpaperView.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/13.
//

import Cocoa
import SwiftUI
import MetalKit
import AVKit

struct SceneWallpaperView: NSViewRepresentable {
    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    @StateObject var viewModel: SceneWallpaperViewModel
    let screenId: String

    init(wallpaperViewModel: WallpaperViewModel, screenId: String) {
        self.wallpaperViewModel = wallpaperViewModel
        self.screenId = screenId
        self._viewModel = StateObject(wrappedValue: SceneWallpaperViewModel(wallpaper: wallpaperViewModel.wallpaper(for: screenId)))
    }

    private func sceneMusicEnabled(for wallpaper: WEWallpaper) -> Bool {
        let key = "SceneMusicEnabled.\(wallpaper.wallpaperDirectory.path)"
        return UserDefaults.standard.object(forKey: key) == nil ? true : UserDefaults.standard.bool(forKey: key)
    }

    private func sceneMusicVolume(for wallpaper: WEWallpaper) -> Float {
        let key = "SceneMusicVolume.\(wallpaper.wallpaperDirectory.path)"
        guard UserDefaults.standard.object(forKey: key) != nil else { return 1 }
        return Float(UserDefaults.standard.double(forKey: key))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// `videoStream` is only built asynchronously inside `contentAsync`, so the very first
    /// playback update after switching to a video wallpaper finds it still nil and no-ops.
    /// Called again once that build lands (and on every update) so playback actually starts.
    private func kickVideoPlaybackIfNeeded() {
        guard SceneWallpaperViewModel.isVideoType(viewModel.currentWallpaper.project.type) else { return }
        viewModel.updateVideoPlayback(playRate: wallpaperViewModel.playRate,
                                      audioRate: wallpaperViewModel.audioPlayRate,
                                      audioLevel: AudioReactiveScriptEngine.shared.audioLevel,
                                      audioEnabled: wallpaperViewModel.shouldPlayAudio(on: screenId),
                                      volume: wallpaperViewModel.playVolume)
    }

    func makeNSView(context: Context) -> MTKView {
        let metalView = MTKView(frame: .zero)
        context.coordinator.renderer = SceneMetalRenderer(view: metalView, scriptServices: AppDelegate.shared.sceneScriptServices,
                                                          screenID: screenId)
        context.coordinator.renderer?.scripts.onHalt = { [weak coordinator = context.coordinator,
                                                         weak sceneViewModel = viewModel] error in
            guard let coordinator, let sceneViewModel else { return }
            // `take()` reports it from the renderer's draw, on the main thread.
            MainActor.assumeIsolated { coordinator.showScriptsHalted(sceneViewModel, error: error) }
        }
        if let watchdog = wallpaperViewModel.renderWatchdog {
            context.coordinator.renderer?.frameTimeObserver = { watchdog.recordFrame(duration: $0) }
        }
        context.coordinator.propertyObserver = NotificationCenter.default.addObserver(
            forName: .sceneUserPropertiesDidChange, object: nil, queue: .main
        ) { [weak coordinator = context.coordinator, weak sceneViewModel = viewModel] notification in
            let keys = notification.userInfo?["keys"] as? [String] ?? []
            guard let coordinator, let sceneViewModel else { return }
            // Scripts get every change (`applyUserProperties`); content is rebuilt only when it
            // reads the property itself.
            coordinator.renderer?.scripts.userPropertiesDidChange(Set(keys))
            let impact = sceneViewModel.impact(of: keys)
            guard impact > .none else { return }
            coordinator.scheduleSceneUpdate(impact, for: sceneViewModel)
        }
        context.coordinator.assetsObserver = NotificationCenter.default.addObserver(
            forName: .wallpaperEngineAssetsDirectoryDidChange, object: nil, queue: .main
        ) { [weak renderer = context.coordinator.renderer, weak sceneViewModel = viewModel] _ in
            sceneViewModel?.reloadSharedAssets()
            let revision = sceneViewModel?.metalRevision ?? -1
            sceneViewModel?.contentAsync { content in
                renderer?.setContent(content)
                context.coordinator.metalRevision = revision
            }
        }
        context.coordinator.dependencyObserver = NotificationCenter.default.addObserver(
            forName: .workshopDependenciesDidInstall, object: nil, queue: .main
        ) { [weak coordinator = context.coordinator, weak sceneViewModel = viewModel] notification in
            guard let coordinator, let sceneViewModel,
                  let directory = notification.userInfo?["wallpaperDirectory"] as? URL,
                  directory == sceneViewModel.currentWallpaper.wallpaperDirectory.standardizedFileURL else { return }
            coordinator.scheduleSceneUpdate(.reloadScene, for: sceneViewModel)
        }
        context.coordinator.sceneMusicObserver = NotificationCenter.default.addObserver(
            forName: .sceneMusicSettingsDidChange, object: nil, queue: .main
        ) { [weak coordinator = context.coordinator, weak sceneViewModel = viewModel] notification in
            guard let sceneViewModel else { return }
            let path = notification.userInfo?["path"] as? String
            guard path == nil || path == sceneViewModel.currentWallpaper.wallpaperDirectory.path else { return }
            coordinator?.audio?.update(url: sceneViewModel.sceneAudioURL(),
                                       enabled: wallpaperViewModel.shouldPlaySceneAudio(on: screenId)
                                           && sceneMusicEnabled(for: sceneViewModel.currentWallpaper),
                                       volume: wallpaperViewModel.playVolume * sceneMusicVolume(for: sceneViewModel.currentWallpaper),
                                       isPaused: wallpaperViewModel.playRate == 0)
        }
        // Zoom/tilt/saturation amounts are baked into the layer when content is built, so the
        // toggles do nothing until the content is rebuilt.
        context.coordinator.videoMusicSyncObserver = NotificationCenter.default.addObserver(
            forName: .videoMusicSyncSettingsDidChange, object: nil, queue: .main
        ) { [weak sceneViewModel = viewModel] notification in
            guard let sceneViewModel else { return }
            let path = notification.userInfo?["path"] as? String
            guard path == nil || path == sceneViewModel.currentWallpaper.wallpaperDirectory.path else { return }
            sceneViewModel.invalidateContent()
        }
        context.coordinator.renderer?.setPlacement(wallpaperViewModel.wallpaperPlacement)
        context.coordinator.metalRevision = viewModel.metalRevision
        viewModel.contentAsync { [weak coordinator = context.coordinator] content in
            coordinator?.renderer?.setContent(content)
            kickVideoPlaybackIfNeeded()
        }
        context.coordinator.audio = SceneAudioPlayback(url: viewModel.sceneAudioURL(),
                                enabled: wallpaperViewModel.shouldPlaySceneAudio(on: screenId)
                                    && sceneMusicEnabled(for: viewModel.currentWallpaper),
                                volume: wallpaperViewModel.playVolume * sceneMusicVolume(for: viewModel.currentWallpaper))
        context.coordinator.audio?.play()
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
            context.coordinator.metalRevision = viewModel.metalRevision
            viewModel.contentAsync { [weak coordinator = context.coordinator] content in
                coordinator?.renderer?.setContent(content)
                kickVideoPlaybackIfNeeded()
            }
        }
        context.coordinator.renderer?.setPlacement(wallpaperViewModel.wallpaperPlacement)
        // A video wallpaper on the Metal path has no scene audio; its own stream owns playback.
        kickVideoPlaybackIfNeeded()
        context.coordinator.audio?.update(url: viewModel.sceneAudioURL(),
                          enabled: wallpaperViewModel.shouldPlaySceneAudio(on: screenId)
                              && sceneMusicEnabled(for: viewModel.currentWallpaper),
                          volume: wallpaperViewModel.playVolume * sceneMusicVolume(for: viewModel.currentWallpaper),
                          isPaused: wallpaperViewModel.playRate == 0)
        metalView.preferredFramesPerSecond = Int(AppDelegate.shared.globalSettingsViewModel.settings.fps)
        metalView.isPaused = wallpaperViewModel.playRate == 0
    }

    final class Coordinator {
        var renderer: SceneMetalRenderer?
        var metalRevision = -1
        var propertyObserver: NSObjectProtocol?
        var assetsObserver: NSObjectProtocol?
        var sceneMusicObserver: NSObjectProtocol?
        var dependencyObserver: NSObjectProtocol?
        var videoMusicSyncObserver: NSObjectProtocol?
        var audio: SceneAudioPlayback?

        private var pendingImpact: SceneChangeImpact = .none
        private var pendingUpdate: DispatchWorkItem?
        private var scriptsNotice: SafeRestartNotice?

        /// The watchdog stopped this wallpaper's scripts (a script ran past WE's 15 s): the
        /// wallpaper keeps showing their last values. Says so without blocking, like SafeRestart;
        /// Retry reloads the wallpaper, which starts its scripts again.
        @MainActor
        func showScriptsHalted(_ viewModel: SceneWallpaperViewModel, error: SceneScriptError?) {
            let title = viewModel.currentWallpaper.project.title
            OWELog.error(.script, "\(title): scripts stopped by the watchdog\(error.map { " in \($0.scriptID)" } ?? "")")
            let message = String(localized: """
            The scripts of “\(title)” were stopped because one of them ran for too long. The wallpaper \
            keeps showing, without its scripted animations.
            """)
            scriptsNotice?.close()
            scriptsNotice = SafeRestartNotice(
                message: message,
                onRetry: { [weak self, weak viewModel] in
                    self?.dismissScriptsNotice()
                    guard let self, let viewModel else { return }
                    // A new document signature is not needed: dropping the content stops the
                    // halted scripts, and the reload starts new ones.
                    self.renderer?.releaseContent()
                    self.scheduleSceneUpdate(.reloadScene, for: viewModel)
                },
                onDismiss: { [weak self] in self?.dismissScriptsNotice() })
            scriptsNotice?.show()
        }

        @MainActor
        private func dismissScriptsNotice() {
            scriptsNotice?.close()
            scriptsNotice = nil
        }

        /// Coalesces bursts of property changes (e.g. dragging a slider) into one rebuild,
        /// escalating to a full re-parse only when some key in the burst demands it.
        func scheduleSceneUpdate(_ impact: SceneChangeImpact, for viewModel: SceneWallpaperViewModel) {
            pendingImpact = Swift.max(pendingImpact, impact)
            pendingUpdate?.cancel()
            let work = DispatchWorkItem { [weak self, weak viewModel] in
                guard let self, let viewModel else { return }
                let resolved = self.pendingImpact
                self.pendingImpact = .none
                if resolved == .reloadScene {
                    viewModel.reloadCurrentScene()
                } else {
                    // Content is memoised against metalRevision, so without this the rebuild
                    // would just hand back the pre-change scene.
                    viewModel.invalidateContent()
                }
                self.metalRevision = viewModel.metalRevision
                viewModel.contentAsync { [weak self] content in
                    self?.renderer?.setContent(content)
                }
            }
            pendingUpdate = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }

        deinit {
            pendingUpdate?.cancel()
            if let propertyObserver {
                NotificationCenter.default.removeObserver(propertyObserver)
            }
            if let assetsObserver {
                NotificationCenter.default.removeObserver(assetsObserver)
            }
            if let dependencyObserver {
                NotificationCenter.default.removeObserver(dependencyObserver)
            }
            if let sceneMusicObserver {
                NotificationCenter.default.removeObserver(sceneMusicObserver)
            }
            if let videoMusicSyncObserver {
                NotificationCenter.default.removeObserver(videoMusicSyncObserver)
            }
            if let scriptsNotice { MainActor.assumeIsolated { scriptsNotice.close() } }
            audio?.stop()
            // Built layers hold the video stream, so the renderer has to let go of them or the
            // soundtrack outlives this view.
            renderer?.releaseContent()
            renderer = nil
        }
    }
}

final class SceneAudioPlayback {
    private var url: URL?
    private var player: AVPlayer?
    private var enabled: Bool
    private var volume: Float
    private var isPaused = false
    private var fadeTimer: Timer?

    init(url: URL?, enabled: Bool, volume: Float) {
        self.url = url
        self.enabled = enabled
        self.volume = volume
        if let url { player = AVPlayer(url: url) }
        player?.isMuted = !enabled
        player?.volume = volume
        observeEnd(of: player?.currentItem)
    }

    func play() {
        guard enabled, !isPaused else { return }
        player?.play()
    }

    func update(url: URL?, enabled: Bool, volume: Float, isPaused: Bool) {
        self.enabled = enabled
        self.volume = volume
        self.isPaused = isPaused

        guard url != self.url else {
            player?.isMuted = !enabled
            player?.volume = volume
            // Scene music has its own player, so a paused wallpaper stays audible without this.
            if isPaused || !enabled { player?.pause() } else { player?.play() }
            return
        }

        retireCurrentPlayer()
        self.url = url
        guard let url else { return }
        let newPlayer = AVPlayer(url: url)
        newPlayer.isMuted = !enabled
        newPlayer.volume = volume
        player = newPlayer
        observeEnd(of: newPlayer.currentItem)
        play()
    }

    func stop() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        retireCurrentPlayer(immediately: true)
        url = nil
    }

    private func observeEnd(of item: AVPlayerItem?) {
        guard let item else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(loop),
                                               name: .AVPlayerItemDidPlayToEndTime, object: item)
    }

    /// Hands the outgoing player to a fade and drops it from `player` right away, so nothing can
    /// resume it and a missed fade tick cannot leave it playing.
    private func retireCurrentPlayer(immediately: Bool = false) {
        fadeTimer?.invalidate()
        fadeTimer = nil
        guard let oldPlayer = player else { return }
        player = nil
        if let item = oldPlayer.currentItem {
            NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: item)
        }

        func shutDown() {
            oldPlayer.pause()
            oldPlayer.replaceCurrentItem(with: nil)
        }
        let startingVolume = max(oldPlayer.volume, 0)
        guard !immediately, startingVolume > 0.001 else {
            shutDown()
            return
        }

        let startTime = Date()
        let duration: TimeInterval = 0.3
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { timer in
            let progress = min(max(Date().timeIntervalSince(startTime) / duration, 0), 1)
            oldPlayer.volume = startingVolume * Float(1 - progress)
            if progress >= 1 {
                timer.invalidate()
                shutDown()
            }
        }
        fadeTimer = timer
        // Default-mode timers stall while menus or scroll views are tracking, which previously
        // left the outgoing soundtrack running indefinitely.
        RunLoop.main.add(timer, forMode: .common)
        // Backstop in case the run loop never services the timer at all.
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.1) {
            timer.invalidate()
            shutDown()
        }
    }

    @objc private func loop() {
        guard enabled, !isPaused else { return }
        player?.seek(to: .zero)
        player?.play()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        player?.pause()
        player?.replaceCurrentItem(with: nil)
    }
}
