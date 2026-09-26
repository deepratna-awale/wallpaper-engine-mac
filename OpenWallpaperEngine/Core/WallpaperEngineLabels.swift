import Foundation

/// WE's own English UI strings (`locale/ui_en-us.json` of a Wallpaper Engine install), which
/// translate the localisation keys wallpapers and shaders use as labels
/// (`ui_editor_properties_speed` → "Speed"). Without an install, keys are shown as words.
struct WallpaperEngineLabels {
    private let strings: [String: String]

    init(strings: [String: String] = [:]) {
        self.strings = strings
    }

    /// The table of the configured install; empty with the bundled assets only (they carry no
    /// locale files).
    static func load(assets: URL? = WallpaperEngineAssets.configured) -> WallpaperEngineLabels {
        guard let assets else { return WallpaperEngineLabels() }
        let file = assets.deletingLastPathComponent().appending(path: "locale/ui_en-us.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return WallpaperEngineLabels() }
        do {
            let data = try Data(contentsOf: file)
            let object = try JSONSerialization.jsonObject(with: data, options: [.json5Allowed])
            return WallpaperEngineLabels(strings: object as? [String: String] ?? [:])
        } catch {
            OWELog.error(.scene, "WallpaperEngineLabels: cannot read \(file.path): \(error)")
            return WallpaperEngineLabels()
        }
    }

    /// WE's text for a localisation key, matched case-insensitively as keys are authored with
    /// mixed case; nil for plain text and unknown keys.
    func translation(_ key: String) -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespaces)
        if let exact = strings[trimmed] { return exact }
        return strings[trimmed.lowercased()]
    }
}
