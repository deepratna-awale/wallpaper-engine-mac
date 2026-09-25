import Foundation

/// Resolves the Wallpaper Engine asset tree used for effects, shared materials and the SceneScript
/// runtime.
///
/// A user-configured Wallpaper Engine installation always wins, so an existing install stays the
/// source of truth and can be updated independently. Otherwise the translated copy bundled inside
/// the app is used, which is what makes effects work without Wallpaper Engine installed.
enum WallpaperEngineAssets {
    static let defaultsKey = "WallpaperEngineAssetsDirectory"

    /// The translated assets shipped inside the app, if present.
    static var bundled: URL? {
        guard let url = Bundle.main.url(forResource: "we-assets", withExtension: nil),
              FileManager.default.fileExists(atPath: url.appending(path: "effects").path) else { return nil }
        return url
    }

    /// The user's own installation, normalised to the `assets` folder.
    static var configured: URL? {
        guard let path = UserDefaults.standard.string(forKey: defaultsKey), !path.isEmpty else { return nil }
        let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let assets = root.lastPathComponent.caseInsensitiveCompare("assets") == .orderedSame
            ? root
            : root.appending(path: "assets", directoryHint: .isDirectory)
        return FileManager.default.fileExists(atPath: assets.path) ? assets : nil
    }

    static var directory: URL? {
        configured ?? bundled
    }

    static var isUsingBundledAssets: Bool {
        configured == nil && bundled != nil
    }
}
