import AVFoundation

/// One wallpaper instance's audio graph: an `AVAudioEngine` whose main mixer takes every sound
/// layer's voices. It is made when a voice first plays (a muted wallpaper, or a display that
/// doesn't play the wallpaper's sound, never touches the audio hardware), starts then, and pauses
/// when the layers go silent. Offline (manual rendering) for tests. Main thread.
final class SceneSoundMixer {
    let engine = AVAudioEngine()
    private var failed = false
    private let label: String

    /// `offline` renders on demand (`AVAudioEngine.renderOffline`) instead of to the output device.
    init(label: String, offline: AVAudioFormat? = nil) {
        self.label = label
        if let offline {
            do {
                try engine.enableManualRenderingMode(.offline, format: offline, maximumFrameCount: 4096)
            } catch {
                OWELog.error(.audio, "\(label): offline sound rendering is unavailable: \(error)")
                failed = true
            }
        }
    }

    deinit {
        // Disposing an engine's output talks to coreaudiod; a stalled daemon must not stall the
        // renderer, so the engine goes on a queue of its own.
        let engine = self.engine
        DispatchQueue.global(qos: .utility).async { engine.stop() }
    }

    func attach(_ node: AVAudioPlayerNode, format: AVAudioFormat) {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    func detach(_ node: AVAudioPlayerNode) {
        engine.detach(node)
    }

    /// Starts the engine if it isn't running; false (logged once) when it can't.
    func run() -> Bool {
        if engine.isRunning { return true }
        guard !failed else { return false }
        do {
            engine.prepare()
            try engine.start()
            return true
        } catch {
            failed = true
            OWELog.error(.audio, "\(label): the sound engine can't start, sound layers stay silent: \(error)")
            return false
        }
    }

    /// Pauses the engine (nothing plays).
    func idle() {
        if engine.isRunning { engine.pause() }
    }
}
