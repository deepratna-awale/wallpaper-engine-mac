import Foundation

/// One frame of WE's audio spectrum: `g_AudioSpectrum{16,32,64}{Left,Right}` for shaders and the
/// `left`/`right`/`average` arrays of SceneScript's `registerAudioBuffers`. WE fills one buffer
/// that both read (`AudioSpectrumSmoothing`). Values are normally 0…1 but can exceed 1.
struct AudioSpectrumSnapshot: Equatable {
    var left16: [Float]
    var right16: [Float]
    var left32: [Float]
    var right32: [Float]
    var left64: [Float]
    var right64: [Float]
    var average16 = [Float](repeating: 0, count: 16)
    var average32 = [Float](repeating: 0, count: 32)
    var average64 = [Float](repeating: 0, count: 64)

    static let silent = AudioSpectrumSnapshot(
        left16: [Float](repeating: 0, count: 16), right16: [Float](repeating: 0, count: 16),
        left32: [Float](repeating: 0, count: 32), right32: [Float](repeating: 0, count: 32),
        left64: [Float](repeating: 0, count: 64), right64: [Float](repeating: 0, count: 64))

    /// The array for a band count and channel, or nil for a count WE doesn't define.
    func values(bands: Int, right: Bool) -> [Float]? {
        switch bands {
        case 16: return right ? right16 : left16
        case 32: return right ? right32 : left32
        case 64: return right ? right64 : left64
        default: return nil
        }
    }

    /// The `average` array for a band count, or nil for a count WE doesn't define.
    func averages(bands: Int) -> [Float]? {
        switch bands {
        case 16: return average16
        case 32: return average32
        case 64: return average64
        default: return nil
        }
    }
}

/// WE's audio spectrum from stereo PCM: `AudioSpectrumBlockTransform` on the audio thread turns
/// blocks of samples into raw band values, and `AudioSpectrumSmoothing` turns the latest block into
/// each rendered frame's arrays. Both follow `wallpaper64.exe` (see their docs).
///
/// Threading: `ingest` runs on the audio thread and owns `transform`; `advanceFrame` runs on the
/// render thread. `lock` owns `latestRaw`, `smoothing`, `current` and `lastAdvance`.
final class AudioSpectrumAnalyzer {
    static let rawCount = 2 * AudioSpectrumBlockTransform.bandCount

    private let lock = NSLock()
    private var latestRaw = [Float](repeating: 0, count: AudioSpectrumAnalyzer.rawCount)
    private var smoothing = AudioSpectrumSmoothing()
    private var current = AudioSpectrumSnapshot.silent
    private var lastAdvance: TimeInterval?
    private let uptime: () -> TimeInterval

    // Audio-thread only.
    private let transform: AudioSpectrumBlockTransform?

    /// `sampleRate` is the capture stream's; `inputVolume` is WE's `audioinputvolume` × 0.02.
    init(sampleRate: Double = 48_000, inputVolume: Float = 1,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        transform = AudioSpectrumBlockTransform(sampleRate: sampleRate)
        transform?.inputVolume = inputVolume
        self.uptime = uptime
        if transform == nil {
            OWELog.error(.audio, "Audio spectrum DFT setup failed for \(sampleRate) Hz; the spectrum stays silent")
        }
    }

    /// Adds one buffer of non-interleaved float samples. Pass the same buffer twice for mono.
    func ingest(left: UnsafeBufferPointer<Float>, right: UnsafeBufferPointer<Float>) {
        guard let raw = transform?.append(left: left, right: right) else { return }
        lock.lock()
        latestRaw = raw
        lock.unlock()
    }

    /// Capture stopped: WE's processor hands out zeros while it isn't running, which silences the
    /// next frame.
    func reset() {
        lock.lock()
        latestRaw = [Float](repeating: 0, count: Self.rawCount)
        lock.unlock()
    }

    /// Advances by one rendered frame, timed by the monotonic clock. Call exactly once per frame.
    func advanceFrame() -> AudioSpectrumSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let now = uptime()
        // The first frame has no predecessor; WE's clamp turns 0 into its minimum step.
        let deltaTime = lastAdvance.map { now - $0 } ?? 0
        lastAdvance = now
        current = smoothing.advance(raw: latestRaw, deltaTime: deltaTime)
        return current
    }

    /// Advances by one frame of `deltaTime` seconds.
    func advanceFrame(deltaTime: Double) -> AudioSpectrumSnapshot {
        lock.lock()
        defer { lock.unlock() }
        lastAdvance = uptime()
        current = smoothing.advance(raw: latestRaw, deltaTime: deltaTime)
        return current
    }

    /// The latest frame's arrays, without advancing.
    var snapshot: AudioSpectrumSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return current
    }
}
