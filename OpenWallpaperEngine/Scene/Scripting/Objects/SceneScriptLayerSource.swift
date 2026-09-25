import Foundation

/// What `thisScene.createLayer(configuration)` was given (IScene.createLayer).
enum SceneScriptLayerSource: Equatable {
    /// An asset path such as `'models/bar.json'`, or an `IAssetHandle`'s path.
    case asset(String)
    /// A configuration object in scene.json form, serialized by WE's `_Internal.stringifyConfig`
    /// (vectors become `"x y z"` strings). A `text` member makes it a text layer.
    case configuration(json: String)
    /// Another layer as the starting point: its authored configuration with its current values.
    case copy(slot: Int)
}
