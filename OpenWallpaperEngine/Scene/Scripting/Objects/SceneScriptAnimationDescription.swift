import Foundation

/// A timeline or texture animation scripts can control (`IAnimation`, `ITextureAnimation`). Its
/// state (rate, frame, playing) lives in the animation buffer of `SceneScriptObjectModel`, which the
/// renderer keeps current; scripts change it through commands (WP12 evaluates the timelines).
struct SceneScriptAnimationDescription {
    var name: String
    var fps: Double
    var frameCount: Int
    var duration: Double
    var rate: Double = 1
    var frame: Double = 0
    var playing: Bool = false
    /// The scene.json key of the property the animation drives, for property animations; what
    /// `thisObject.getAnimation()` returns in a script bound to that property.
    var property: String?
}
