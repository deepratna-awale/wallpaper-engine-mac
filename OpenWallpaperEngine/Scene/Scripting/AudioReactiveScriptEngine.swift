import Cocoa

extension Notification.Name {
    static let sceneUserPropertiesDidChange = Notification.Name("SceneUserPropertiesDidChange")
    static let audioCapturePermissionMissing = Notification.Name("AudioCapturePermissionMissing")
    static let videoMusicSyncAudioLevelDidChange = Notification.Name("VideoMusicSyncAudioLevelDidChange")
    static let videoMusicSyncSettingsDidChange = Notification.Name("VideoMusicSyncSettingsDidChange")
    static let sceneMusicSettingsDidChange = Notification.Name("SceneMusicSettingsDidChange")
}

/// The app's system audio capture and the user properties of every running wallpaper instance,
/// shared by scene, video and web wallpapers. SceneScript itself runs per wallpaper instance in a
/// `SceneScriptRuntime` (docs/scenescript-plan.md WP11).
final class AudioReactiveScriptEngine {
    static let shared = AudioReactiveScriptEngine()

    /// System audio capture: the level, the legacy spectrum and WE's spectrum analyzer.
    let audioCapture: SystemAudioCapture
    /// Per-wallpaper user properties and their music-synced modulation.
    let propertyService: SceneUserPropertyService

    private init() {
        let capture = SystemAudioCapture()
        audioCapture = capture
        propertyService = SceneUserPropertyService(audioLevel: { capture.audioLevel })
    }

    /// Starts capture if Screen Recording was granted since the last check. Never prompts, so it is
    /// safe to call whenever the app activates or the Permissions page appears.
    @MainActor
    func recheckCapturePermission() {
        audioCapture.recheckCapturePermission()
    }

    /// Sets the user properties of one wallpaper instance (keyed by its directory path). With
    /// `replacing`, properties missing from `values` are dropped, so nothing from a previous
    /// configuration of that wallpaper lingers.
    func setUserProperties(_ values: [String: String], wallpaper: String, replacing: Bool) {
        propertyService.setUserProperties(values, wallpaper: wallpaper, replacing: replacing)
    }

    // MARK: - Frame snapshot

    /// Starts a frame of `wallpaper` (its directory path): reads until `endFrame` see that
    /// wallpaper's user properties, so per-layer reads stop contending with the audio thread.
    func beginFrame(wallpaper: String) {
        OWEFrameMetrics.countLockAcquisition()
        propertyService.beginFrame(wallpaper: wallpaper)
    }

    func endFrame() {
        propertyService.endFrame()
    }

    func userPropertyValue(_ key: String, fallback: Float) -> Float {
        propertyService.userPropertyValue(key, fallback: fallback)
    }

    func isMusicSynced(_ key: String) -> Bool {
        propertyService.isMusicSynced(key)
    }

    func userPropertyString(_ key: String) -> String? {
        propertyService.userPropertyString(key)
    }

    /// One wallpaper instance's property, independent of which wallpaper is being rendered.
    func userPropertyString(_ key: String, wallpaper: String) -> String? {
        propertyService.userPropertyString(key, wallpaper: wallpaper)
    }

    /// Every user property of one wallpaper instance.
    func userProperties(wallpaper: String) -> [String: String] {
        propertyService.userProperties(wallpaper: wallpaper)
    }

    // MARK: - Audio

    var audioLevel: Double {
        if let level = propertyService.frameAudioLevel { return level }
        OWEFrameMetrics.countLockAcquisition()
        return audioCapture.audioLevel
    }

    /// The latest smoothed WE spectra, without advancing the smoothing.
    var audioSpectrumSnapshot: AudioSpectrumSnapshot { audioCapture.audioSpectrumSnapshot }

    /// Advances the spectrum smoothing by one frame. The renderer calls this exactly once per
    /// rendered frame and binds the result to every pass of that frame.
    func advanceAudioSpectrumFrame() -> AudioSpectrumSnapshot { audioCapture.advanceAudioSpectrumFrame() }
}
