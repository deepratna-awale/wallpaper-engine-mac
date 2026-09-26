import Foundation

/// What makes two displays show the same running wallpaper: the same wallpaper folder, file and
/// type. Displays whose keys are equal share one instance (`WallpaperInstanceRegistry`); a
/// display switched to another wallpaper gets another key and splits off into its own.
///
/// A wallpaper's user properties are stored per wallpaper (`WallpaperSettingsIdentity`, and
/// `SceneUserPropertyStores` keyed by its folder), not per display, so displays with the same key
/// always have the same properties and a change reaches both.
struct WallpaperInstanceKey: Hashable, CustomStringConvertible {
    let directory: String
    let file: String
    let type: String

    init(_ wallpaper: WEWallpaper) {
        directory = wallpaper.wallpaperDirectory.standardizedFileURL.path
        file = wallpaper.project.file
        type = wallpaper.project.type.lowercased()
    }

    var description: String { "\(type) \(directory)/\(file)" }
}
