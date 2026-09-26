import Cocoa
import Combine
import MetalKit

/// What a running scene reads from the app: the displays' wallpapers and the playback controls,
/// the user's quality and frame-rate settings, and the services every scene's scripts share.
struct SceneWallpaperEnvironment {
    weak var wallpapers: WallpaperViewModel?
    let settings: GlobalSettingsViewModel
    let scriptServices: SceneScriptServices?
}

/// One scene (or Metal video) wallpaper, running once for every display that shows it
/// (docs/architecture.md "Wallpaper instances"): it loads and builds the scene once, and has one
/// renderer with one script runtime, one particle, timeline and animation state, one effect graph
/// and one set of sound layers, so its sound plays once. Each display is a thin presenter
/// (`SceneWallpaperPresenter`): the display with the highest frame rate renders the frames
/// (`SceneFrameSchedule`), at the largest scene target the displays need, and every display
/// presents them at its own size.
@MainActor
final class SceneWallpaperInstance {
    private struct Display {
        weak var view: MTKView?
    }

    let key: WallpaperInstanceKey
    let viewModel: SceneWallpaperViewModel
    /// Nil when Metal can't make one; the displays then stay black.
    let renderer: SceneMetalRenderer?
    private let environment: SceneWallpaperEnvironment
    private var displays: [ObjectIdentifier: Display] = [:]
    /// Displays in the order they joined, which breaks frame-rate ties.
    private var displayOrder: [ObjectIdentifier] = []
    private var schedule = SceneFrameSchedule()
    private var metalRevision = -1
    private var observers: [NSObjectProtocol] = []
    private var cancellables = Set<AnyCancellable>()
    private var pendingImpact: SceneChangeImpact = .none
    private var pendingUpdate: DispatchWorkItem?
    private var scriptsNotice: SafeRestartNotice?

    /// `screenID` is the display that starts it; its scripts keep their per-display storage there.
    init(wallpaper: WEWallpaper, environment: SceneWallpaperEnvironment, screenID: String) {
        key = WallpaperInstanceKey(wallpaper)
        viewModel = SceneWallpaperViewModel(wallpaper: wallpaper)
        self.environment = environment
        renderer = SceneMetalRenderer(pixelFormat: .bgra8Unorm, scriptServices: environment.scriptServices,
                                      screenID: screenID)
        if renderer == nil {
            OWELog.error(.scene, "\(wallpaper.project.title): Metal renderer unavailable; the wallpaper can't be drawn")
        }
        configureRenderer()
        observeChanges()
        metalRevision = viewModel.metalRevision
        loadContent()
    }

    /// Stops everything: the scripts, the sound layers, a video's stream. The registry calls it
    /// once no display shows the wallpaper.
    func shutdown() {
        pendingUpdate?.cancel()
        pendingUpdate = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        cancellables.removeAll()
        scriptsNotice?.close()
        scriptsNotice = nil
        // Built layers hold the video stream and the sound layers, so the renderer has to let go
        // of them or the soundtrack outlives the wallpaper.
        renderer?.releaseContent()
        displays.removeAll()
        displayOrder.removeAll()
    }

    // MARK: - Displays

    /// `presenter` shows this wallpaper in `view` from now on.
    func attach(_ presenter: SceneWallpaperPresenter, view: MTKView) {
        let id = ObjectIdentifier(presenter)
        renderer?.configure(view)
        view.delegate = presenter
        displays[id] = Display(view: view)
        if !displayOrder.contains(id) { displayOrder.append(id) }
        schedule.add(id, frameRate: Self.frameRate(of: view))
        update()
    }

    func detach(_ presenter: SceneWallpaperPresenter) {
        let id = ObjectIdentifier(presenter)
        displays[id]?.view?.delegate = nil
        displays[id] = nil
        displayOrder.removeAll { $0 == id }
        schedule.remove(id)
    }

    var displayCount: Int { displays.count }

    /// A display's draw: one display draws the scene straight onto its drawable; with several,
    /// the driving display renders the frame for all of them and each presents it.
    func draw(_ presenter: SceneWallpaperPresenter, in view: MTKView) {
        guard let renderer else { return }
        guard displays.count > 1 else {
            renderer.draw(in: view)
            return
        }
        let id = ObjectIdentifier(presenter)
        let now = CACurrentMediaTime()
        if schedule.shouldRender(id, at: now) {
            renderer.renderShared(viewports())
            schedule.rendered(at: now)
        }
        renderer.present(in: view)
    }

    /// The displays as the frame needs them, the driving one first; views not yet laid out are left out.
    private func viewports() -> [SceneViewport] {
        let driver = schedule.driver
        let ordered = displayOrder.filter { $0 == driver } + displayOrder.filter { $0 != driver }
        return ordered.compactMap { id -> SceneViewport? in
            guard let view = displays[id]?.view, view.drawableSize.width > 0, view.drawableSize.height > 0 else { return nil }
            return SceneViewport(view)
        }
    }

    /// The rate a display draws at: the user's limit, or its screen's refresh rate if lower.
    private static func frameRate(of view: MTKView) -> Int {
        let screenRate = view.window?.screen?.maximumFramesPerSecond ?? view.preferredFramesPerSecond
        return min(view.preferredFramesPerSecond, screenRate > 0 ? screenRate : view.preferredFramesPerSecond)
    }

    // MARK: - Updates

    /// Follows the app's controls: a rebuilt content, the placement, playback, the sound's gain, the
    /// frame rate and pause. Displays call it when SwiftUI updates them.
    func update() {
        guard let wallpapers = environment.wallpapers else { return }
        if metalRevision != viewModel.metalRevision {
            metalRevision = viewModel.metalRevision
            loadContent()
        }
        renderer?.setPlacement(wallpapers.wallpaperPlacement)
        // A display that joined or changed size can change WE's automatic texture resolution.
        applyRenderSettings(renderSettings(for: environment.settings.settings))
        updateVideoPlayback()
        renderer?.sounds.setTargetGain(soundGain)
        let fps = Int(environment.settings.settings.fps)
        for (id, display) in displays {
            guard let view = display.view else { continue }
            view.preferredFramesPerSecond = fps
            view.isPaused = wallpapers.playRate == 0
            schedule.setFrameRate(Self.frameRate(of: view), of: id)
        }
    }

    private func loadContent() {
        viewModel.contentAsync { [weak self] content in
            guard let self else { return }
            self.renderer?.setContent(content)
            self.updateVideoPlayback()
        }
    }

    /// `videoStream` is only built inside `contentAsync`, so the first playback update after a
    /// video wallpaper starts finds none; called again once the content lands, so playback starts.
    private func updateVideoPlayback() {
        guard SceneWallpaperViewModel.isVideoType(viewModel.currentWallpaper.project.type),
              let wallpapers = environment.wallpapers else { return }
        viewModel.updateVideoPlayback(playRate: wallpapers.playRate, audioRate: wallpapers.audioPlayRate,
                                      audioLevel: WallpaperServices.shared.audioLevel,
                                      audioEnabled: wallpapers.playsInstanceAudio, volume: wallpapers.playVolume)
    }

    private var sceneMusicEnabled: Bool {
        let key = "SceneMusicEnabled.\(viewModel.currentWallpaper.wallpaperDirectory.path)"
        return UserDefaults.standard.object(forKey: key) == nil ? true : UserDefaults.standard.bool(forKey: key)
    }

    private var sceneMusicVolume: Float {
        let key = "SceneMusicVolume.\(viewModel.currentWallpaper.wallpaperDirectory.path)"
        guard UserDefaults.standard.object(forKey: key) != nil else { return 1 }
        return Float(UserDefaults.standard.double(forKey: key))
    }

    /// The wallpaper's sound gain (its sound layers fade to it): the app's volume times this
    /// wallpaper's music volume, and 0 with the app's audio output off, or while muted, paused or
    /// with its music turned off, as WE's wallpaper volume goes to 0 then.
    private var soundGain: Float {
        guard let wallpapers = environment.wallpapers, wallpapers.playsInstanceAudio, sceneMusicEnabled,
              wallpapers.playRate != 0 else { return 0 }
        return wallpapers.playVolume * sceneMusicVolume
    }

    // MARK: - Setup

    private func configureRenderer() {
        guard let renderer else { return }
        renderer.sounds.setTargetGain(soundGain)
        renderer.scripts.onHalt = { [weak self] error in
            // `take()` reports it from the renderer's draw, on the main thread.
            MainActor.assumeIsolated { self?.showScriptsHalted(error: error) }
        }
        if let watchdog = environment.wallpapers?.renderWatchdog {
            // One frame time per rendered frame, however many displays show it.
            renderer.frameTimeObserver = { watchdog.recordFrame(duration: $0) }
        }
        // The user's quality settings: the renderer reads them per frame, the content is built for them.
        let renderSettings = renderSettings(for: environment.settings.settings)
        renderer.renderSettings = renderSettings
        viewModel.setRenderSettings(renderSettings)
    }

    /// `settings` for this scene's displays: WE's automatic texture resolution follows the largest.
    private func renderSettings(for settings: GlobalSettings) -> SceneRenderSettings {
        let largest = displays.values.reduce(SIMD2<Float>(repeating: 0)) { largest, display in
            guard let view = display.view else { return largest }
            return simd_max(largest, SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)))
        }
        return SceneRenderSettings(settings, outputPixels: largest)
    }

    /// Applies `settings` when they differ from the renderer's, rebuilding the content for them.
    private func applyRenderSettings(_ settings: SceneRenderSettings) {
        guard let renderer, settings != renderer.renderSettings else { return }
        renderer.renderSettings = settings
        viewModel.setRenderSettings(settings)
        scheduleSceneUpdate(.rebuildContent)
    }

    private func observeChanges() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .sceneUserPropertiesDidChange, object: nil, queue: .main) { [weak self] notification in
            let keys = notification.userInfo?["keys"] as? [String] ?? []
            MainActor.assumeIsolated {
                guard let self else { return }
                // Scripts get every change (`applyUserProperties`); content is rebuilt only when it
                // reads the property itself.
                self.renderer?.scripts.userPropertiesDidChange(Set(keys))
                let impact = self.viewModel.impact(of: keys)
                guard impact > .none else { return }
                self.scheduleSceneUpdate(impact)
            }
        })
        observers.append(center.addObserver(forName: .wallpaperEngineAssetsDirectoryDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.viewModel.reloadSharedAssets()
                self.metalRevision = self.viewModel.metalRevision
                self.loadContent()
            }
        })
        observers.append(center.addObserver(forName: .workshopDependenciesDidInstall, object: nil, queue: .main) { [weak self] notification in
            let directory = notification.userInfo?["wallpaperDirectory"] as? URL
            MainActor.assumeIsolated {
                guard let self,
                      directory == self.viewModel.currentWallpaper.wallpaperDirectory.standardizedFileURL else { return }
                self.scheduleSceneUpdate(.reloadScene)
            }
        })
        observers.append(center.addObserver(forName: .sceneMusicSettingsDidChange, object: nil, queue: .main) { [weak self] notification in
            let path = notification.userInfo?["path"] as? String
            MainActor.assumeIsolated {
                guard let self, path == nil || path == self.viewModel.currentWallpaper.wallpaperDirectory.path else { return }
                self.renderer?.sounds.setTargetGain(self.soundGain)
            }
        })
        // Zoom/tilt/saturation amounts are baked into the layer when content is built, so the
        // toggles do nothing until the content is rebuilt.
        observers.append(center.addObserver(forName: .videoMusicSyncSettingsDidChange, object: nil, queue: .main) { [weak self] notification in
            let path = notification.userInfo?["path"] as? String
            MainActor.assumeIsolated {
                guard let self, path == nil || path == self.viewModel.currentWallpaper.wallpaperDirectory.path else { return }
                self.viewModel.invalidateContent()
            }
        })
        environment.settings.$settings
            .dropFirst()
            .sink { [weak self] settings in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.applyRenderSettings(self.renderSettings(for: settings))
                }
            }
            .store(in: &cancellables)
        // A rebuilt content (a new revision) or a video that changed shape: the displays used to
        // pick it up through SwiftUI; the instance follows it itself, after the change lands.
        viewModel.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.update() } }
            .store(in: &cancellables)
    }

    /// Coalesces bursts of property changes (e.g. dragging a slider) into one rebuild,
    /// escalating to a full re-parse only when some key in the burst demands it.
    private func scheduleSceneUpdate(_ impact: SceneChangeImpact) {
        pendingImpact = Swift.max(pendingImpact, impact)
        pendingUpdate?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let resolved = self.pendingImpact
                self.pendingImpact = .none
                if resolved == .reloadScene {
                    self.viewModel.reloadCurrentScene()
                } else {
                    // Content is memoised against metalRevision, so without this the rebuild
                    // would just hand back the pre-change scene.
                    self.viewModel.invalidateContent()
                }
                self.metalRevision = self.viewModel.metalRevision
                self.loadContent()
            }
        }
        pendingUpdate = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    // MARK: - Scripts halted

    /// The watchdog stopped this wallpaper's scripts (a script ran past WE's 15 s): the
    /// wallpaper keeps showing their last values. Says so without blocking, like SafeRestart;
    /// Retry reloads the wallpaper, which starts its scripts again.
    private func showScriptsHalted(error: SceneScriptError?) {
        let title = viewModel.currentWallpaper.project.title
        OWELog.error(.script, "\(title): scripts stopped by the watchdog\(error.map { " in \($0.scriptID)" } ?? "")")
        let message = String(localized: """
        The scripts of “\(title)” were stopped because one of them ran for too long. The wallpaper \
        keeps showing, without its scripted animations.
        """)
        scriptsNotice?.close()
        scriptsNotice = SafeRestartNotice(
            message: message,
            onRetry: { [weak self] in
                guard let self else { return }
                self.dismissScriptsNotice()
                // A new document signature is not needed: dropping the content stops the halted
                // scripts, and the reload starts new ones.
                self.renderer?.releaseContent()
                self.scheduleSceneUpdate(.reloadScene)
            },
            onDismiss: { [weak self] in self?.dismissScriptsNotice() })
        scriptsNotice?.show()
    }

    private func dismissScriptsNotice() {
        scriptsNotice?.close()
        scriptsNotice = nil
    }
}
