import AVFoundation
import CoreVideo
import Metal
import QuartzCore

/// Publishes decoded video frames as Metal textures so a video can be drawn by the scene renderer
/// instead of an `AVPlayerLayer`.
///
/// Wallpaper Engine renders video through its normal scene pipeline — `scenes/videoplayer` binds
/// the movie as a `videotex` user texture on a `genericimage` material — which is why scene effects
/// apply to video there. Rendering into `AVPlayerView` keeps the frames outside Metal entirely, so
/// no effect can touch them.
final class VideoTextureStream {
    let player: AVPlayer
    /// Natural frame size, once the first frame has arrived.
    private(set) var frameSize = SIMD2<Float>(1920, 1080)

    private let output: AVPlayerItemVideoOutput
    /// Audio is a second player on the same file, mirroring the AVKit path: the video player stays
    /// muted so music pacing never pitch-shifts the soundtrack.
    private let audioPlayer: AVPlayer
    private var textureCache: CVMetalTextureCache?
    private let ownAudioTap = AudioLevelTap()
    private var audioIsAudible = false
    /// The CVMetalTexture must outlive the MTLTexture handed to the renderer, so it is held until
    /// the next frame replaces it.
    private var retainedTexture: CVMetalTexture?
    private var latestTexture: MTLTexture?
    private var observers: [NSObjectProtocol] = []

    private var appliedVideoRate: Float?
    private var appliedAudioRate: Float?
    private var smoothedAudioLevel: Double = 0
    private static let rateEpsilon: Float = 0.01
    private static let audioSmoothing = 0.25

    init?(url: URL, device: MTLDevice) {
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { return nil }
        textureCache = cache

        output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        let item = AVPlayerItem(url: url)
        item.add(output)
        player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.actionAtItemEnd = .none

        let audioItem = AVPlayerItem(url: url)
        audioItem.audioTimePitchAlgorithm = .timeDomain
        audioPlayer = AVPlayer(playerItem: audioItem)
        audioPlayer.actionAtItemEnd = .none
        ownAudioTap.attach(to: audioItem)

        for observed in [item, audioItem] {
            observers.append(NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: observed, queue: .main
            ) { [weak self] _ in self?.restart() })
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        player.pause()
        audioPlayer.pause()
        player.replaceCurrentItem(with: nil)
        audioPlayer.replaceCurrentItem(with: nil)
    }

    /// Stops both players and drops their items, so audio cannot keep playing through whatever
    /// still holds a reference to this stream (the renderer retains it inside the built layer).
    func stop() {
        player.pause()
        audioPlayer.pause()
        player.replaceCurrentItem(with: nil)
        audioPlayer.replaceCurrentItem(with: nil)
        appliedVideoRate = nil
        appliedAudioRate = nil
    }

    /// The frame for the current host time, or the previous one when no new frame is ready.
    func currentTexture() -> MTLTexture? {
        let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: itemTime),
              let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil),
              let textureCache else { return latestTexture }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        var created: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, buffer, nil,
                                                        .bgra8Unorm, width, height, 0, &created) == kCVReturnSuccess,
              let created, let texture = CVMetalTextureGetTexture(created) else { return latestTexture }

        retainedTexture = created
        latestTexture = texture
        frameSize = SIMD2<Float>(Float(width), Float(height))
        CVMetalTextureCacheFlush(textureCache, 0)
        return texture
    }

    func setAudio(enabled: Bool, volume: Float) {
        audioPlayer.isMuted = !enabled
        audioPlayer.volume = volume
        audioIsAudible = enabled && volume > 0
    }

    /// The wallpaper's own soundtrack drives music sync whenever you can actually hear it;
    /// otherwise sync follows whatever else is playing on the system.
    var musicSyncLevel: Double {
        audioIsAudible ? ownAudioTap.level : AudioReactiveScriptEngine.shared.audioLevel
    }

    /// `paceAmount` warps playback with the music the way the AVKit path does; the audio track keeps
    /// its own steady rate so only the picture is paced.
    func update(playRate: Float, audioRate: Float, audioLevel: Double, paceAmount: Double) {
        if paceAmount > 0 {
            smoothedAudioLevel += (audioLevel - smoothedAudioLevel) * Self.audioSmoothing
        } else {
            smoothedAudioLevel = audioLevel
        }
        setVideoRate(max(0, playRate + Float(smoothedAudioLevel * paceAmount)))
        // The soundtrack runs on its own player, so a paused wallpaper stays audible unless the
        // pause is applied to it explicitly.
        setAudioRate(audioPlayer.isMuted || playRate <= 0 ? 0 : audioRate)
    }

    /// Assigning `AVPlayer.rate` restarts the timebase, so only meaningful changes are forwarded.
    private func setVideoRate(_ rate: Float) {
        if let applied = appliedVideoRate, abs(rate - applied) <= Self.rateEpsilon { return }
        appliedVideoRate = rate
        player.rate = rate
    }

    private func setAudioRate(_ rate: Float) {
        if let applied = appliedAudioRate, abs(rate - applied) <= Self.rateEpsilon { return }
        appliedAudioRate = rate
        audioPlayer.rate = rate
    }

    func restart() {
        player.seek(to: .zero)
        audioPlayer.seek(to: .zero)
        // Seeking clears the rate, so the cache no longer describes the players.
        appliedVideoRate = nil
        appliedAudioRate = nil
    }
}
