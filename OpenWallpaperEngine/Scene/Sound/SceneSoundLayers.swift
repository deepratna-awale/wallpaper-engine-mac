import AVFoundation

/// A wallpaper instance's sound layers (docs/scenescript-plan.md, sound layers): one
/// `SceneSoundPlayback` per scene.json `sound` object, played through one `SceneSoundMixer`, and
/// the wallpaper's gain. Owned by the renderer, main thread.
///
/// The wallpaper's gain is the app's volume, mute and pause (and whether this display is the one
/// that plays the wallpaper's sound). Like WE's wallpaper volume (0x140114d7c, 0x1401816d0) it
/// fades towards its target, `v += (target − v) × min(dt × 6, 1)` snapping within 0.01
/// (0x140492860, 0x140492620), on its own timer, so it also fades while no frames are drawn; at 0
/// the layers pause, above 0 they resume where they were.
final class SceneSoundLayers {
    private struct Layer {
        var content: SceneSoundContent
        var voices: SceneSoundVoices
        var playback: SceneSoundPlayback
    }

    /// WE's fade rate and snap distance.
    static let fadeRate = 6.0
    static let fadeSnap: Float = 0.01

    private let label: String
    private let offline: AVAudioFormat?
    private let random: () -> Double
    private var mixer: SceneSoundMixer?
    private var layers: [Int: Layer] = [:]
    private var order: [Int] = []
    private(set) var gain: Float = 0
    private(set) var targetGain: Float = 0
    private var fadeTimer: Timer?
    private var lastFadeTime: CFTimeInterval = 0

    /// `offline` renders through a manual-rendering engine (tests).
    init(label: String, offline: AVAudioFormat? = nil, random: @escaping () -> Double = { Double.random(in: 0..<1) }) {
        self.label = label
        self.offline = offline
        self.random = random
    }

    deinit {
        fadeTimer?.invalidate()
    }

    var isEmpty: Bool { layers.isEmpty }
    var ids: [Int] { order }

    /// The scene's sound layers. Layers that stay (same id and files) keep playing with the new
    /// settings, as a content rebuild for a user property doesn't restart WE's sounds; others
    /// stop, and new ones load (and play unless `startsilent`).
    func setContent(_ sounds: [SceneSoundContent]) {
        var kept: [Int: Layer] = [:]
        for content in sounds {
            guard var layer = layers.removeValue(forKey: content.id) else { continue }
            guard layer.content.files == content.files, layer.content.sound == content.sound else {
                layer.playback.stop()
                continue
            }
            if layer.content.volume != content.volume { layer.playback.setVolume(content.volume) }
            layer.content = content
            kept[content.id] = layer
        }
        for id in layers.keys { layers[id]?.playback.stop() }
        layers = kept
        order = sounds.map(\.id)
        for content in sounds where layers[content.id] == nil { add(content) }
        idleIfSilent()
    }

    /// Adds one layer (a script's `createLayer`, or new content) and loads it.
    func add(_ content: SceneSoundContent) {
        if layers[content.id] != nil { remove(content.id) }
        let mixer = self.mixer ?? SceneSoundMixer(label: label, offline: offline)
        self.mixer = mixer
        let voices = SceneSoundVoices(files: content.files, mixer: mixer, label: "\(label) '\(content.name)'")
        let playback = SceneSoundPlayback(sound: content.sound, durations: content.files.map(\.duration),
                                          volume: content.volume, sceneGain: gain, output: voices, random: random)
        layers[content.id] = Layer(content: content, voices: voices, playback: playback)
        if !order.contains(content.id) { order.append(content.id) }
        playback.load()
    }

    /// Stops and forgets one layer (`destroyLayer`).
    func remove(_ id: Int) {
        layers.removeValue(forKey: id)?.playback.stop()
        order.removeAll { $0 == id }
        idleIfSilent()
    }

    /// Stops everything (content released).
    func stopAll() {
        for layer in layers.values { layer.playback.stop() }
        layers.removeAll()
        order.removeAll()
        fadeTimer?.invalidate()
        fadeTimer = nil
        mixer?.idle()
    }

    // MARK: - Scripts

    func perform(_ playback: SceneScriptObjectCommand.Playback, on id: Int) {
        guard let layer = layers[id] else { return }
        switch playback {
        case .play: layer.playback.play()
        case .pause: layer.playback.pause()
        case .stop: layer.playback.stop()
        }
        idleIfSilent()
    }

    /// `volume` as a script left it.
    func setVolume(_ volume: Float, of id: Int) {
        guard let layer = layers[id], layer.playback.volume != volume else { return }
        layer.playback.setVolume(volume)
        idleIfSilent()
    }

    func isPlaying(_ id: Int) -> Bool? { layers[id]?.playback.isPlaying }

    func playback(of id: Int) -> SceneSoundPlayback? { layers[id]?.playback }

    // MARK: - Frame

    /// WE's per-frame update, `seconds` of real time since the last draw.
    func update(deltaTime seconds: Double) {
        guard !layers.isEmpty else { return }
        for id in order { layers[id]?.playback.update(deltaTime: seconds) }
        idleIfSilent()
    }

    // MARK: - Wallpaper gain

    /// The gain the wallpaper fades to. The first target (before any sound played) is taken at once.
    func setTargetGain(_ target: Float) {
        let target = max(target, 0)
        targetGain = target
        if layers.isEmpty && fadeTimer == nil {
            gain = target
            return
        }
        guard gain != target, fadeTimer == nil else { return }
        lastFadeTime = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = CACurrentMediaTime()
            self.stepFade(now - self.lastFadeTime)
            self.lastFadeTime = now
        }
        fadeTimer = timer
        // Default-mode timers stall while menus track; the fade must finish regardless.
        RunLoop.main.add(timer, forMode: .common)
    }

    /// One step of the fade (the timer's; tests call it directly).
    func stepFade(_ seconds: Double) {
        var next = gain + (targetGain - gain) * Float(min(max(seconds, 0) * Self.fadeRate, 1))
        if abs(targetGain - next) < Self.fadeSnap { next = targetGain }
        if next != gain {
            gain = next
            for id in order { layers[id]?.playback.setSceneGain(next) }
        }
        if gain == targetGain {
            fadeTimer?.invalidate()
            fadeTimer = nil
        }
        idleIfSilent()
    }

    /// Pauses the engine while no voice plays.
    private func idleIfSilent() {
        guard let mixer else { return }
        let anyPlaying = layers.values.contains { $0.playback.hasSoundingVoice }
        if !anyPlaying { mixer.idle() }
    }

    /// The mixer (tests render it offline).
    var soundMixer: SceneSoundMixer? { mixer }
}
