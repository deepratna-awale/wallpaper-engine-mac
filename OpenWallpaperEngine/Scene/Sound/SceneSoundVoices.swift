import AVFoundation

/// One sound layer's files as AVAudioEngine voices (the `SceneSoundOutput` `SceneSoundPlayback`
/// drives): an `AVAudioPlayerNode` per file, attached to the wallpaper's mixer on first use and
/// streaming the file from disk, as WE streams each file through its own `sf::Music`. A looping
/// file keeps two passes scheduled, so it wraps without a gap: when one has played, the next is
/// queued behind the other. Main thread; the players' completion handlers hop back to it (a
/// player must not be scheduled from inside its own callback).
final class SceneSoundVoices: SceneSoundOutput {
    private final class Voice {
        let node = AVAudioPlayerNode()
        var file: AVAudioFile?
        var attached = false
    }

    private let files: [SceneSoundContent.File]
    private let mixer: SceneSoundMixer
    private let label: String
    private var voices: [Voice]
    /// A voice's loop keeps scheduling only while its generation stands.
    private var generations: [Int]
    private var reported = Set<Int>()

    init(files: [SceneSoundContent.File], mixer: SceneSoundMixer, label: String) {
        self.files = files
        self.mixer = mixer
        self.label = label
        voices = files.map { _ in Voice() }
        generations = Array(repeating: 0, count: files.count)
    }

    deinit {
        for index in voices.indices { stop(file: index) }
        for voice in voices where voice.attached { mixer.detach(voice.node) }
    }

    func start(file index: Int, loop: Bool) {
        guard let voice = prepared(index), let file = voice.file else { return }
        let generation = nextGeneration(index)
        voice.node.stop()
        let frames = AVAudioFrameCount(clamping: max(file.length, 0))
        guard frames > 0 else { return }
        if loop {
            schedule(file, frames: frames, on: voice.node, index: index, generation: generation)
            schedule(file, frames: frames, on: voice.node, index: index, generation: generation)
        } else {
            voice.node.scheduleSegment(file, startingFrame: 0, frameCount: frames, at: nil)
        }
        guard mixer.run() else { return }
        voice.node.play()
    }

    func pause(file index: Int) {
        guard voices.indices.contains(index), voices[index].attached else { return }
        voices[index].node.pause()
    }

    func resume(file index: Int) {
        guard voices.indices.contains(index), voices[index].attached, mixer.run() else { return }
        voices[index].node.play()
    }

    func stop(file index: Int) {
        guard voices.indices.contains(index), voices[index].attached else { return }
        _ = nextGeneration(index)
        voices[index].node.stop()
    }

    func setGain(_ gain: Float, file index: Int) {
        guard voices.indices.contains(index) else { return }
        voices[index].node.volume = gain
    }

    /// Whether a voice is playing (tests).
    func isVoicePlaying(_ index: Int) -> Bool {
        voices.indices.contains(index) && voices[index].attached && voices[index].node.isPlaying
    }

    // MARK: - Private

    /// The voice with its file open and its node in the mixer; nil (logged once) when the file
    /// can't be opened.
    private func prepared(_ index: Int) -> Voice? {
        guard voices.indices.contains(index) else { return nil }
        let voice = voices[index]
        if voice.file == nil {
            do {
                voice.file = try AVAudioFile(forReading: files[index].url)
            } catch {
                if reported.insert(index).inserted {
                    OWELog.error(.audio, "\(label): sound '\(files[index].path)' can't be opened: \(error)")
                }
                return nil
            }
        }
        if !voice.attached, let file = voice.file {
            mixer.attach(voice.node, format: file.processingFormat)
            voice.attached = true
        }
        return voice
    }

    private func nextGeneration(_ index: Int) -> Int {
        generations[index] += 1
        return generations[index]
    }

    /// One pass of a looping file; when it has played, another is queued behind the pass now
    /// playing, so the loop never runs dry.
    private func schedule(_ file: AVAudioFile, frames: AVAudioFrameCount, on node: AVAudioPlayerNode, index: Int,
                          generation: Int) {
        node.scheduleSegment(file, startingFrame: 0, frameCount: frames, at: nil,
                             completionCallbackType: .dataPlayedBack) { [weak self, weak node] _ in
            DispatchQueue.main.async {
                guard let self, let node, self.generations[index] == generation else { return }
                self.schedule(file, frames: frames, on: node, index: index, generation: generation)
            }
        }
    }
}
