import Accelerate
import Cocoa
import CoreMedia
import ScreenCaptureKit

/// System audio capture through ScreenCaptureKit: the stream, its restarts, the legacy 64-band
/// level/spectrum/waveform and the WE-style spectrum analyzer. Owned by `AudioReactiveScriptEngine`,
/// which forwards to it until the SceneScript runtime takes over (docs/scenescript-plan.md, WP1).
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private let levelLock = NSLock()
    private var level: Double = 0
    private var spectrum = [Double](repeating: 0, count: 64)
    private var waveform = [Double](repeating: 0, count: 64)
    private var stream: SCStream?

    /// Guards `stream`; capture starts and stops on arbitrary tasks.
    private let captureLock = NSLock()
    /// Only touched on the main actor. Never calls ScreenCaptureKit while permission is missing,
    /// because ScreenCaptureKit itself shows the system prompt in that case.
    @MainActor private lazy var permissionGate = AudioCapturePermissionGate(
        preflight: { CGPreflightScreenCaptureAccess() },
        isAlertDismissed: { GlobalSettingsViewModel.isAudioPermissionAlertDismissed })
    /// Only touched on the main actor. The single owner of capture starts, so at most one
    /// `SCStream` exists app-wide.
    @MainActor private lazy var restartScheduler = CaptureRestartScheduler(
        schedule: { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(work) }
        },
        start: { [weak self] in self?.startSystemAudioCapture() })

    override init() {
        super.init()
        // Unit tests run ad-hoc signed with this bundle id; a capture request from them is denied
        // and that denial replaces the user's Screen Recording grant for the real app.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        Task { @MainActor [weak self] in self?.setUpSystemAudioCapture() }
    }

    @MainActor
    private func setUpSystemAudioCapture() {
        observeCaptureInterruptions()
        if permissionGate.canCapture() {
            restartScheduler.requestRestart()
        } else {
            OWELog.info(.audio, "Screen Recording permission not granted; system audio capture is off.")
            if permissionGate.shouldAlertMissingPermission() {
                NotificationCenter.default.post(name: .audioCapturePermissionMissing, object: nil)
            }
        }
    }

    /// A ScreenCaptureKit stream does not survive system sleep or display reconfiguration, and
    /// nothing else would ever start a new one, so every audio-reactive feature would stay silent
    /// until the app is relaunched.
    @MainActor
    private func observeCaptureInterruptions() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    // AppKit posts all three on the main thread.
    @MainActor @objc private func systemDidWake() {
        restartSystemAudioCapture(reason: "system woke")
    }

    @MainActor @objc private func screenParametersDidChange() {
        restartSystemAudioCapture(reason: "display configuration changed")
    }

    @MainActor @objc private func applicationDidBecomeActive() {
        recheckCapturePermission()
    }

    /// Starts capture if Screen Recording was granted since the last check. Never prompts, so it is
    /// safe to call whenever the app activates or the Permissions page appears.
    @MainActor
    func recheckCapturePermission() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        guard permissionGate.becameGranted() else { return }
        OWELog.info(.audio, "Screen Recording permission granted; starting system audio capture.")
        restartScheduler.reset()
        restartScheduler.requestRestart()
    }

    @MainActor
    private func restartSystemAudioCapture(reason: String) {
        guard permissionGate.canCapture() else { return }
        OWELog.info(.audio, "Restarting ScreenCaptureKit audio capture: \(reason).")
        restartScheduler.requestRestart()
    }

    /// Without this, visuals stay frozen on the last buffer that arrived before capture stopped.
    private func resetAudioLevels() {
        levelLock.lock()
        level = 0
        spectrum = [Double](repeating: 0, count: spectrum.count)
        waveform = [Double](repeating: 0, count: waveform.count)
        levelLock.unlock()
        audioSpectrumAnalyzer.reset()
    }

    func audioVisualizationSnapshot() -> AudioVisualizationSnapshot {
        levelLock.lock()
        defer { levelLock.unlock() }
        let bandAverage: (Range<Int>) -> Double = { range in
            guard !range.isEmpty else { return 0 }
            return self.spectrum[range].reduce(0, +) / Double(range.count)
        }
        return AudioVisualizationSnapshot(level: level, spectrum: spectrum, waveform: waveform,
                                          bass: bandAverage(0..<8), mid: bandAverage(8..<32), treble: bandAverage(32..<64))
    }

    var audioLevel: Double {
        levelLock.lock()
        defer { levelLock.unlock() }
        return level
    }

    var audioSpectrum: [Double] {
        levelLock.lock()
        defer { levelLock.unlock() }
        return spectrum
    }

    /// Called only by `restartScheduler`, which guarantees a single start in flight; the previous
    /// stream is stopped before a new one is created.
    @MainActor
    private func startSystemAudioCapture() {
        captureLock.lock()
        let previous = stream
        stream = nil
        captureLock.unlock()
        resetAudioLevels()
        guard permissionGate.canCapture() else {
            // Revoked while the start was queued. Touching ScreenCaptureKit now would prompt.
            Task { try? await previous?.stopCapture() }
            restartScheduler.reset()
            restartScheduler.finished(success: true)
            return
        }
        Task { [weak self] in
            if let previous {
                do { try await previous.stopCapture() } catch {
                    OWELog.debug(.audio, "Stopping previous capture stream failed: \(error.localizedDescription)")
                }
            }
            let success = await self?.createAndStartStream() ?? false
            await MainActor.run { [weak self] in
                guard let self else { return }
                if self.restartScheduler.finished(success: success) {
                    OWELog.error(.audio, "Giving up on ScreenCaptureKit audio capture after \(self.restartScheduler.maxFailures) failed attempts; it restarts on the next wake, display change or permission change.")
                }
            }
        }
    }

    private func createAndStartStream() async -> Bool {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            OWELog.error(.audio, "Unable to read shareable content: \(error.localizedDescription)")
            return false
        }
        guard let display = content.displays.first else {
            OWELog.error(.audio, "No shareable display found for ScreenCaptureKit audio capture.")
            return false
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = false
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
            try await stream.startCapture()
        } catch {
            OWELog.error(.audio, "Failed to start ScreenCaptureKit audio capture: \(error.localizedDescription)")
            return false
        }
        setCurrentStream(stream)
        OWELog.info(.audio, "ScreenCaptureKit audio capture started.")
        return true
    }

    private func setCurrentStream(_ stream: SCStream) {
        captureLock.lock()
        self.stream = stream
        captureLock.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        captureLock.lock()
        let wasCurrent = stream === self.stream
        if wasCurrent { self.stream = nil }
        captureLock.unlock()
        guard wasCurrent else { return }
        OWELog.error(.audio, "ScreenCaptureKit audio capture stopped: \(error.localizedDescription)")
        resetAudioLevels()
        Task { @MainActor [weak self] in self?.restartSystemAudioCapture(reason: "stream stopped") }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of outputType: SCStreamOutputType) {
        guard outputType == .audio else { return }
        feedAudioSpectrum(sampleBuffer)
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &length, dataPointerOut: &dataPointer) == noErr,
              let dataPointer, length >= MemoryLayout<Float>.size else { return }
        let sampleCount = length / MemoryLayout<Float>.size
        let samples = dataPointer.withMemoryRebound(to: Float.self, capacity: sampleCount) { $0 }
        var squaredSum: Float = 0
        vDSP_svesq(samples, 1, &squaredSum, vDSP_Length(sampleCount))
        let normalizedLevel = min(Double(sqrt(squaredSum / Float(sampleCount))) * 8, 1)
        let magnitudes = frequencyMagnitudes(samples: samples, count: sampleCount)
        var waveformValues = [Double](repeating: 0, count: 64)
        for index in waveformValues.indices {
            let start = index * sampleCount / waveformValues.count
            let end = max(start + 1, (index + 1) * sampleCount / waveformValues.count)
            var sum = 0.0
            for sampleIndex in start..<min(end, sampleCount) {
                sum += Double(samples[sampleIndex])
            }
            waveformValues[index] = sum / Double(max(end - start, 1))
        }
        levelLock.lock()
        level = normalizedLevel
        spectrum = magnitudes
        waveform = waveformValues
        levelLock.unlock()
    }

    /// WE's `g_AudioSpectrum*` source. Fed on the audio thread; the analyzer owns its own lock.
    private let audioSpectrumAnalyzer = AudioSpectrumAnalyzer()

    /// The latest smoothed WE spectra, without advancing the smoothing. (`audioSpectrum` is
    /// already the legacy 64-band mono array used by the script bindings.)
    var audioSpectrumSnapshot: AudioSpectrumSnapshot { audioSpectrumAnalyzer.snapshot }

    /// Advances the spectrum smoothing by one frame. The renderer calls this exactly once per
    /// rendered frame and binds the result to every pass of that frame.
    func advanceAudioSpectrumFrame() -> AudioSpectrumSnapshot { audioSpectrumAnalyzer.advanceFrame() }

    /// Splits the capture buffer (non-interleaved float32) into its channels for the analyzer.
    private func feedAudioSpectrum(_ sampleBuffer: CMSampleBuffer) {
        var sizeNeeded = 0
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &sizeNeeded, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0,
            blockBufferOut: nil) == noErr, sizeNeeded > 0 else { return }
        let listMemory = UnsafeMutableRawPointer.allocate(byteCount: sizeNeeded,
                                                          alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { listMemory.deallocate() }
        let listPointer = listMemory.bindMemory(to: AudioBufferList.self, capacity: 1)
        var retainedBlock: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: listPointer, bufferListSize: sizeNeeded,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &retainedBlock)
        guard status == noErr else {
            OWELog.debug(.audio, "Audio buffer list unavailable (status \(status))")
            return
        }
        let buffers = UnsafeMutableAudioBufferListPointer(listPointer)
        func channel(_ buffer: AudioBuffer) -> UnsafeBufferPointer<Float> {
            guard let data = buffer.mData else { return UnsafeBufferPointer(start: nil, count: 0) }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            return UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count)
        }
        guard let first = buffers.first else { return }
        let left = channel(first)
        let right = buffers.count > 1 ? channel(buffers[1]) : left
        withExtendedLifetime(retainedBlock) {
            audioSpectrumAnalyzer.ingest(left: left, right: right)
        }
    }

    // Audio-thread only: the capture stream delivers buffers serially, so these need no locking.
    private var fftSetup: FFTSetup?
    private var fftSetupLog2n: vDSP_Length = 0
    private var fftWindow: [Float] = []
    private var fftRealParts: [Float] = []
    private var fftImaginaryParts: [Float] = []
    private var fftWindowedSamples: [Float] = []
    private var fftMagnitudes: [Float] = []

    private func prepareFFT(size: Int) -> Bool {
        let log2n = vDSP_Length(round(log2(Double(size))))
        guard fftSetupLog2n != log2n || fftSetup == nil else { return true }
        if let existing = fftSetup { vDSP_destroy_fftsetup(existing) }
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            fftSetup = nil
            return false
        }
        fftSetup = setup
        fftSetupLog2n = log2n
        fftWindow = [Float](repeating: 0, count: size)
        vDSP_hann_window(&fftWindow, vDSP_Length(size), Int32(vDSP_HANN_DENORM))
        fftWindowedSamples = [Float](repeating: 0, count: size)
        fftRealParts = [Float](repeating: 0, count: size / 2)
        fftImaginaryParts = [Float](repeating: 0, count: size / 2)
        fftMagnitudes = [Float](repeating: 0, count: size / 2)
        return true
    }

    private func frequencyMagnitudes(samples: UnsafePointer<Float>, count: Int) -> [Double] {
        let signpost = OWESignpost.begin(OWESignpost.audio, "frequencyMagnitudes")
        defer { signpost.end() }
        let capped = min(1024, count)
        guard capped >= 64 else { return [Double](repeating: 0, count: 64) }
        // vDSP's radix-2 FFT needs a power-of-two length.
        let fftSize = 1 << Int(floor(log2(Double(capped))))
        guard fftSize >= 64, prepareFFT(size: fftSize), let setup = fftSetup else {
            return [Double](repeating: 0, count: 64)
        }
        let start = count - fftSize
        let halfSize = fftSize / 2

        vDSP_vmul(samples + start, 1, fftWindow, 1, &fftWindowedSamples, 1, vDSP_Length(fftSize))

        var bands = [Double](repeating: 0, count: 64)
        fftRealParts.withUnsafeMutableBufferPointer { realBuffer in
            fftImaginaryParts.withUnsafeMutableBufferPointer { imaginaryBuffer in
                var split = DSPSplitComplex(realp: realBuffer.baseAddress!,
                                            imagp: imaginaryBuffer.baseAddress!)
                fftWindowedSamples.withUnsafeBufferPointer { windowed in
                    windowed.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) { interleaved in
                        vDSP_ctoz(interleaved, 2, &split, 1, vDSP_Length(halfSize))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, fftSetupLog2n, FFTDirection(FFT_FORWARD))
                // zrip packs Nyquist into imagp[0]; it is not a real bin and would alias into band 0.
                imaginaryBuffer[0] = 0
                vDSP_zvabs(&split, 1, &fftMagnitudes, 1, vDSP_Length(halfSize))
            }
        }

        // zrip returns twice the true DFT magnitude, hence 8 rather than the scalar path's 16.
        let scale = 8.0 / Double(fftSize)
        for band in bands.indices {
            let bin = max(1, min(halfSize - 1, (band + 1) * fftSize / 128))
            bands[band] = min(Double(fftMagnitudes[bin]) * scale, 1)
        }
        return bands
    }
}