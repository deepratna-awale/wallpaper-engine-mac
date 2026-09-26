import Foundation

/// The parts of SceneScript the whole app shares (docs/scenescript-plan.md WP11), passed to every
/// renderer that runs scripts: WE's prelude (read once), the one `localStorage` store (so two
/// screens showing one wallpaper share `'global'`), the one media session (MediaRemote registers
/// per process, SF14) and the audio spectrum the renderer advances once per frame.
final class SceneScriptServices {
    let prelude: SceneScriptPrelude
    let storage: SceneScriptStorage
    let media: MediaSessionSource
    /// The current frame's spectrum, without advancing it (`SystemAudioCapture.audioSpectrumSnapshot`).
    let spectrum: () -> AudioSpectrumSnapshot
    let configuration: SceneScriptRuntime.Configuration

    init(prelude: SceneScriptPrelude, storage: SceneScriptStorage, media: MediaSessionSource,
         spectrum: @escaping () -> AudioSpectrumSnapshot,
         configuration: SceneScriptRuntime.Configuration = .standard) {
        self.prelude = prelude
        self.storage = storage
        self.media = media
        self.spectrum = spectrum
        self.configuration = configuration
    }
}
