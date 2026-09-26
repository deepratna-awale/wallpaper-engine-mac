import Accelerate
import Cocoa
import CoreMedia
import ScreenCaptureKit

/// System audio capture through ScreenCaptureKit: the stream, its restarts, the overall level
/// (video music sync) and WE's spectrum analyzer (shaders' `g_AudioSpectrum*`, SceneScript's
/// `registerAudioBuffers`). Owned by `WallpaperServices`.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private let levelLock = NSLock()
    private var level: Double = 0
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
        levelLock.unlock()
        audioSpectrumAnalyzer.reset()
    }

    var audioLevel: Double {
        levelLock.lock()
        defer { levelLock.unlock() }
        return level
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
        levelLock.lock()
        level = normalizedLevel
        levelLock.unlock()
    }

    /// WE's `g_AudioSpectrum*` source. Fed on the audio thread; the analyzer owns its own lock.
    private let audioSpectrumAnalyzer = AudioSpectrumAnalyzer()

    /// The latest smoothed WE spectra, without advancing the smoothing.
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
}
