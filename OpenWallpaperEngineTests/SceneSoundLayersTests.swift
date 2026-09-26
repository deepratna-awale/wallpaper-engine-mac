import XCTest
import AVFoundation
@testable import OpenWallpaperEngine

/// Sound layers through AVAudioEngine, rendered offline (`SceneSoundLayers`, `SceneSoundVoices`):
/// a layer plays its file, loops it past its end, fades with the wallpaper's gain like WE
/// (`v += (target − v) × min(dt × 6, 1)`), pauses at 0 and takes `volume²`. And the content
/// builder finds files loose and packaged, and leaves out what it can't decode.
final class SceneSoundLayersTests: XCTestCase {
    private var directory: URL!
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "owe-sound-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    /// A 0.1 s full-scale 440 Hz tone.
    private func tone(_ name: String, seconds: Double = 0.1) throws -> URL {
        let url = directory.appending(path: name)
        let mono = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let frames = AVAudioFrameCount(seconds * 44_100)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: frames))
        buffer.frameLength = frames
        for index in 0..<Int(frames) {
            buffer.floatChannelData![0][index] = Float(sin(2 * Double.pi * 440 * Double(index) / 44_100))
        }
        let file = try AVAudioFile(forWriting: url, settings: mono.settings)
        try file.write(from: buffer)
        return url
    }

    private func content(_ url: URL, mode: WESceneSound.PlaybackMode = .loop, volume: Float = 1) -> SceneSoundContent {
        SceneSoundContent(id: 7, name: "tone", sound: WESceneSound(files: ["sounds/tone.wav"], playbackMode: mode),
                          files: [SceneSoundContent.File(path: "sounds/tone.wav", url: url, duration: 0.1)], volume: volume)
    }

    /// RMS of `seconds` rendered offline.
    private func render(_ layers: SceneSoundLayers, seconds: Double) throws -> Float {
        let engine = try XCTUnwrap(layers.soundMixer?.engine)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096))
        var remaining = Int(seconds * 44_100), sum: Float = 0, count = 0
        while remaining > 0 {
            let frames = AVAudioFrameCount(min(remaining, 4096))
            guard engine.isRunning else { return 0 }
            let status = try engine.renderOffline(frames, to: buffer)
            XCTAssertEqual(status, .success)
            for index in 0..<Int(buffer.frameLength) {
                let sample = buffer.floatChannelData![0][index]
                sum += sample * sample
            }
            count += Int(buffer.frameLength)
            remaining -= Int(frames)
        }
        return count > 0 ? (sum / Float(count)).squareRoot() : 0
    }

    func testALayerPlaysAndLoopsPastItsEnd() throws {
        let layers = SceneSoundLayers(label: "test", offline: format)
        layers.setTargetGain(1)
        layers.setContent([content(try tone("tone.wav"))])
        XCTAssertEqual(layers.isPlaying(7), true)
        XCTAssertGreaterThan(try render(layers, seconds: 0.05), 0.3, "a full-scale mono sine is 0.5 RMS per channel")
        // The second pass is queued from the start (offline rendering never reports a pass as
        // played, so the third one isn't queued here).
        XCTAssertGreaterThan(try render(layers, seconds: 0.1), 0.3, "past its end the next pass plays without a gap")
    }

    func testVolumeIsSquaredAndTheWallpaperGainFadesToAPause() throws {
        let layers = SceneSoundLayers(label: "test", offline: format)
        layers.setTargetGain(1)
        layers.setContent([content(try tone("tone.wav"), volume: 0.5)])
        let quiet = try render(layers, seconds: 0.05)
        // The mono tone reaches each stereo channel 3 dB down: RMS 0.71 × 0.71 at full gain.
        XCTAssertEqual(quiet, 0.5 * 0.25, accuracy: 0.02, "volume 0.5 is a gain of 0.25")

        layers.setTargetGain(0)
        layers.stepFade(1.0 / 60)
        XCTAssertEqual(layers.gain, 0.9, accuracy: 1e-6, "one 60 Hz step of WE's fade covers a tenth")
        for _ in 0..<60 { layers.stepFade(1.0 / 60) }
        XCTAssertEqual(layers.gain, 0, "snapped at 0.01")
        XCTAssertLessThan(try render(layers, seconds: 0.05), 0.001, "paused")
        XCTAssertEqual(layers.playback(of: 7)?.hasSoundingVoice, false)

        layers.setTargetGain(1)
        for _ in 0..<60 { layers.stepFade(1.0 / 60) }
        XCTAssertEqual(layers.isPlaying(7), true, "resumed where it was")
        XCTAssertGreaterThan(try render(layers, seconds: 0.05), 0.1)
    }

    /// A muted wallpaper (or a display that doesn't play its sound) never makes an audio engine,
    /// so it never touches the audio hardware; unmuting makes it and starts the sound.
    func testASilentWallpaperMakesNoEngine() throws {
        let layers = SceneSoundLayers(label: "test", offline: format)
        layers.setTargetGain(0)
        layers.setContent([content(try tone("tone.wav"))])
        XCTAssertNil(layers.soundMixer)
        XCTAssertEqual(layers.isPlaying(7), false)
        layers.setTargetGain(1)
        for _ in 0..<60 { layers.stepFade(1.0 / 60) }
        XCTAssertNotNil(layers.soundMixer)
        XCTAssertEqual(layers.isPlaying(7), true)
    }

    /// A rebuild of the same content (a user property changed a layer) keeps the sound going.
    func testTheSameContentKeepsPlaying() throws {
        let layers = SceneSoundLayers(label: "test", offline: format)
        layers.setTargetGain(1)
        let url = try tone("tone.wav")
        layers.setContent([content(url)])
        let playback = layers.playback(of: 7)
        layers.setContent([content(url, volume: 0.5)])
        XCTAssertTrue(layers.playback(of: 7) === playback)
        XCTAssertEqual(playback?.volume, 0.5)
        layers.setContent([])
        XCTAssertNil(layers.playback(of: 7))
    }

    func testTheBuilderFindsFilesAndLeavesOutWhatItCantDecode() throws {
        let loose = try tone("loose.wav", seconds: 0.5)
        let packaged = try Data(contentsOf: try tone("packaged.wav", seconds: 0.25))
        try Data("not audio".utf8).write(to: directory.appending(path: "broken.mp3"))
        let cache = directory.appending(path: "cache")
        let builder = SceneSoundContentBuilder(
            wallpaperDirectory: directory, packagedData: { $0 == "sounds/in-package.wav" ? packaged : nil },
            workshopURL: { _ in nil }, workshopData: { _ in nil }, cacheDirectory: cache)
        let object = try JSONDecoder().decode(WESceneObject.self, from: Data(#"""
            {"id": 3, "name": "Music", "sound": ["\#(loose.lastPathComponent)", "sounds/in-package.wav", "broken.mp3", "missing.mp3"],
             "volume": 0.5}
            """#.utf8))
        let sounds = builder.sounds(in: [object], context: StaticSceneValueContext())
        let sound = try XCTUnwrap(sounds.first)
        XCTAssertEqual(sound.id, 3)
        XCTAssertEqual(sound.volume, 0.5)
        XCTAssertEqual(sound.files.map(\.path), ["loose.wav", "sounds/in-package.wav"])
        XCTAssertEqual(sound.files[0].duration, 0.5, accuracy: 0.01)
        XCTAssertEqual(sound.files[1].duration, 0.25, accuracy: 0.01)
        XCTAssertEqual(sound.files[1].url.deletingLastPathComponent().standardizedFileURL, cache.standardizedFileURL,
                       "a packaged file is read from its copy in the caches")
    }
}

/// No user properties: every binding takes its authored value.
private struct StaticSceneValueContext: SceneValueContext {
    func userProperty(_ name: String) -> String? { nil }
}
