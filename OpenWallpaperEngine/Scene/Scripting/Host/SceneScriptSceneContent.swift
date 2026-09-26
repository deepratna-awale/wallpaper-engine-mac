import Foundation

/// What the loader hands the renderer to run a scene's scripts (docs/scenescript-plan.md WP11):
/// the resolved scene document the content was built from, the wallpaper's user properties, its
/// files, and the loader's way of building a layer for `thisScene.createLayer`.
struct SceneScriptSceneContent {
    /// Names script ids, logs and `localStorage`: the Workshop id, or a stable local id.
    var wallpaperID: String
    /// `scene.json` as the content was built from it (the user's object edits applied).
    var document: SceneJSON
    /// Identifies `document`: the renderer keeps the scripts running across content rebuilds (a
    /// user property that changes a layer) while it stays the same, as WE does.
    var documentSignature: String
    /// `project.json`, whose `general.properties` declare the user properties.
    var project: SceneJSON?
    /// The wallpaper instance's current user property values, as the property store keeps them.
    var userValues: () -> [String: String]
    /// Reads a file of the wallpaper (package, folder, Workshop dependencies, WE's assets).
    var file: (String) -> Data?
    /// Builds an object `createLayer` made (scene.json form), through the loader's builders; nil
    /// when it can't be built. Called off the main thread.
    var makeLayer: ([String: SceneJSON]) -> SceneScriptCreatedObject?

    /// The user properties with the user's current values, in WE's raw form.
    func userProperties() -> SceneScriptUserProperties {
        var properties = SceneScriptUserProperties(project: project)
        properties.setStoredValues(userValues())
        return properties
    }
}

extension SceneScriptUserProperties {
    /// Takes the property store's values (WE's text forms: "true", "0.5", "1 0 0", a combo's value)
    /// in the JSON type project.json declares each property with, so scripts get booleans, numbers
    /// and text as WE hands them.
    mutating func setStoredValues(_ stored: [String: String]) {
        for (name, property) in properties {
            guard let text = stored[name] else { continue }
            set(name, to: Self.value(text, type: property.type, declared: property.value))
        }
    }

    private static func value(_ text: String, type: String, declared: SceneJSON) -> SceneJSON {
        switch type {
        case "bool":
            return .bool(text.caseInsensitiveCompare("true") == .orderedSame || text == "1")
        case "slider":
            return Double(text).map(SceneJSON.number) ?? declared
        default:
            // Combos keep their options' type; colours and text stay text.
            if case .number = declared, let number = Double(text) { return .number(number) }
            if case .bool = declared { return .bool(text.caseInsensitiveCompare("true") == .orderedSame || text == "1") }
            return .string(text)
        }
    }
}
