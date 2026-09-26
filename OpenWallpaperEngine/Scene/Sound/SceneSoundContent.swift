import Foundation

/// A sound layer ready to play: its scene.json object, the wallpaper's copy of each file it could
/// open with its length, and its `volume` with user bindings resolved.
struct SceneSoundContent: Equatable {
    struct File: Equatable {
        /// The path scene.json names.
        var path: String
        var url: URL
        /// Seconds.
        var duration: Double
    }

    var id: Int
    var name: String
    var sound: WESceneSound
    var files: [File]
    var volume: Float
}
