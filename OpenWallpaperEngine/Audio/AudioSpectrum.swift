import Accelerate
import Foundation

/// One frame of WE's `g_AudioSpectrum{16,32,64}{Left,Right}` values, each in 0...1.
struct AudioSpectrumSnapshot: Equatable {
    var left16: [Float]
    var right16: [Float]
    var left32: [Float]
    var right32: [Float]
    var left64: [Float]
    var right64: [Float]

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
}

/// Turns stereo PCM into WE's audio spectra, following linux-wallpaperengine's
/// `PulseAudioPlaybackRecorder`:
///
/// - The last 1024 samples of each channel go through a real FFT, no window.
/// - Band power `p = re² + im²` of the (unnormalised) DFT bin; value `0.35·log10(p)`,
///   times the tilt `2 − e^((1 − band/(N−1)) − 0.5)`, clamped to at most 1. We also clamp at 0,
///   because `log10` of a tiny power is negative and WE's values are 0...1.
/// - Bins (LWE's grouping, which samples single bins rather than summing ranges):
///   64 bands use bin `2b`; 32 bands use bin `4b + 2`; 16 bands use bin `8b + 6`.
///   At 48 kHz one bin is 46.875 Hz, so 64-band `b` sits at `b · 93.75 Hz`.
///   (LWE writes the 32/16 arrays inside the 64-band loop, so the last write per slot wins; that
///   is where the `+2` / `+6` come from. LWE's tilt for those uses the 64-band index, which we
///   treat as a bug and replace with the band's own index.)
/// - Each rendered frame, `advanceFrame()` moves every value toward its target by at most 0.3.
///
/// Threading: `ingest` runs on the audio thread and `advanceFrame` on the render thread. `lock`
/// owns `pending*`, `targets` and `current`; the FFT scratch is audio-thread only.
final class AudioSpectrumAnalyzer {
    static let fftSize = 1024
    static let maxStep: Float = 0.3

    private let lock = NSLock()
    private var targets = AudioSpectrumSnapshot.silent
    private var current = AudioSpectrumSnapshot.silent

    // Audio-thread only.
    private var leftHistory = [Float](repeating: 0, count: AudioSpectrumAnalyzer.fftSize)
    private var rightHistory = [Float](repeating: 0, count: AudioSpectrumAnalyzer.fftSize)
    private let log2n = vDSP_Length(10)
    private let fftSetup: FFTSetup?
    private var real = [Float](repeating: 0, count: AudioSpectrumAnalyzer.fftSize / 2)
    private var imaginary = [Float](repeating: 0, count: AudioSpectrumAnalyzer.fftSize / 2)

    init() {
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        if fftSetup == nil { OWELog.error(.audio, "vDSP FFT setup failed; audio spectrum stays silent") }
    }

    deinit {
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
    }

    /// Adds one buffer of non-interleaved float samples. Pass the same buffer twice for mono.
    func ingest(left: UnsafeBufferPointer<Float>, right: UnsafeBufferPointer<Float>) {
        Self.append(left, to: &leftHistory)
        Self.append(right, to: &rightHistory)
        let left = bandTargets(leftHistory)
        let right = bandTargets(rightHistory)
        lock.lock()
        targets = AudioSpectrumSnapshot(left16: left.0, right16: right.0, left32: left.1,
                                        right32: right.1, left64: left.2, right64: right.2)
        lock.unlock()
    }

    /// Drops the targets to silence (the smoothing still eases the values down).
    func reset() {
        lock.lock()
        targets = .silent
        lock.unlock()
    }

    /// Advances the smoothing by one rendered frame. Call exactly once per frame.
    func advanceFrame() -> AudioSpectrumSnapshot {
        lock.lock()
        defer { lock.unlock() }
        current.left16 = Self.move(current.left16, toward: targets.left16)
        current.right16 = Self.move(current.right16, toward: targets.right16)
        current.left32 = Self.move(current.left32, toward: targets.left32)
        current.right32 = Self.move(current.right32, toward: targets.right32)
        current.left64 = Self.move(current.left64, toward: targets.left64)
        current.right64 = Self.move(current.right64, toward: targets.right64)
        return current
    }

    /// The latest smoothed values, without advancing.
    var snapshot: AudioSpectrumSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    // MARK: - Private

    private static func append(_ samples: UnsafeBufferPointer<Float>, to history: inout [Float]) {
        let count = samples.count
        guard count > 0, let base = samples.baseAddress else { return }
        if count >= history.count {
            history.withUnsafeMutableBufferPointer {
                $0.baseAddress!.update(from: base + (count - $0.count), count: $0.count)
            }
        } else {
            history.removeFirst(count)
            history.append(contentsOf: samples)
        }
    }

    private static func move(_ values: [Float], toward targets: [Float]) -> [Float] {
        zip(values, targets).map { value, target in
            value + max(-maxStep, min(maxStep, target - value))
        }
    }

    static func tilt(band: Int, count: Int) -> Float {
        2 - exp((1 - Float(band) / Float(count - 1)) - 0.5)
    }

    static func value(power: Float, band: Int, count: Int) -> Float {
        guard power > 0 else { return 0 }
        return max(0, min(1, 0.35 * log10(power) * tilt(band: band, count: count)))
    }

    /// Per-bin power of the true DFT (not zrip's doubled output).
    private func binPowers(_ samples: [Float]) -> [Float] {
        let half = Self.fftSize / 2
        guard let fftSetup else { return [Float](repeating: 0, count: half) }
        var powers = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { realBuffer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                var split = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imaginaryBuffer.baseAddress!)
                samples.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                imaginaryBuffer[0] = 0 // Nyquist lives here; bin 0 is DC only.
                vDSP_zvmags(&split, 1, &powers, 1, vDSP_Length(half))
            }
        }
        // zrip scales by 2, so power by 4.
        var quarter: Float = 0.25
        vDSP_vsmul(powers, 1, &quarter, &powers, 1, vDSP_Length(half))
        return powers
    }

    private func bandTargets(_ samples: [Float]) -> ([Float], [Float], [Float]) {
        let powers = binPowers(samples)
        let b16 = (0..<16).map { Self.value(power: powers[8 * $0 + 6], band: $0, count: 16) }
        let b32 = (0..<32).map { Self.value(power: powers[4 * $0 + 2], band: $0, count: 32) }
        let b64 = (0..<64).map { Self.value(power: powers[2 * $0], band: $0, count: 64) }
        return (b16, b32, b64)
    }
}
