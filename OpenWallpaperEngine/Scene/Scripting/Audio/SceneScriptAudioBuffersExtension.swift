import Foundation
import JavaScriptCore

/// WP5 of docs/scenescript-plan.md: `engine.registerAudioBuffers(resolution)`.
///
/// WE keeps one buffer per resolution with `left`, `right` and `average` back to back (the host
/// method at `wallpaper64.exe` `0x14018e010` hands scenescript64.dll a pointer per resolution; the
/// DLL's tick copies them at `0x18164f84d`, before timers and `update`). Here each resolution is one
/// shared `Float32Array` of 3 × resolution floats that this extension refills in place before
/// every frame, and the arrays a script gets are views into it: live, and the same objects every
/// frame. The values are WE's spectrum (`AudioSpectrumAnalyzer`, which also feeds the shaders'
/// `g_AudioSpectrum*`), so a script and a shader see the same numbers.
///
/// Confined to the runtime's thread, like the runtime.
final class SceneScriptAudioBuffersExtension: SceneScriptRuntimeExtension {
    /// `engine.AUDIO_RESOLUTION_16/32/64`; WE has no other ("Resolution must be either 16, 32 or 64.").
    static let resolutions = [16, 32, 64]

    let scriptResources = ["sceneScriptAudioBuffers"]

    private let spectrum: () -> AudioSpectrumSnapshot
    private var buffers: [Int: SceneScriptSharedBuffer<Float>] = [:]

    /// `spectrum` returns the current frame's arrays; the renderer advances the analyzer once per
    /// frame (`SystemAudioCapture.advanceAudioSpectrumFrame`) and this only reads.
    init(spectrum: @escaping () -> AudioSpectrumSnapshot) {
        self.spectrum = spectrum
    }

    func install(into runtime: SceneScriptRuntime) throws {
        guard let native = runtime.rt.forProperty("native"), native.isObject,
              let stores = JSValue(newObjectIn: runtime.context) else {
            throw SceneScriptRuntime.CreationError(description: "runtime.js has no __rt.native")
        }
        for resolution in Self.resolutions {
            guard let buffer = SceneScriptSharedBuffer<Float>(count: 3 * resolution, in: runtime.context) else {
                throw SceneScriptRuntime.CreationError(description: "the \(resolution)-band audio buffer could not be allocated")
            }
            buffers[resolution] = buffer
            stores.setValue(buffer.value, forProperty: String(resolution))
        }
        native.setValue(stores, forProperty: "audioBuffers")
    }

    func willRunFrame(_ runtime: SceneScriptRuntime, deltaTime: Double) {
        let snapshot = spectrum()
        for (resolution, buffer) in buffers {
            fill(buffer, at: 0, with: snapshot.values(bands: resolution, right: false), count: resolution)
            fill(buffer, at: resolution, with: snapshot.values(bands: resolution, right: true), count: resolution)
            fill(buffer, at: 2 * resolution, with: snapshot.averages(bands: resolution), count: resolution)
        }
    }

    /// Copies `values` into `count` slots from `offset`; a missing or short array leaves zeros.
    private func fill(_ buffer: SceneScriptSharedBuffer<Float>, at offset: Int, with values: [Float]?, count: Int) {
        let values = values ?? []
        for index in 0..<count {
            buffer[offset + index] = index < values.count ? values[index] : 0
        }
    }
}
