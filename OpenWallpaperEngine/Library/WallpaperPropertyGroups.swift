import Foundation

/// Which displays share a running wallpaper, by their user properties
/// (docs/architecture.md "Wallpaper instances").
///
/// With properties synced across displays, every display of a wallpaper runs its shared store's
/// properties, so they share one instance. Otherwise each display has its own properties, as in
/// WE: displays of a wallpaper whose properties are equal still share one instance (the first
/// such display's, by id, whose store it runs), and a display whose properties differ runs its own.
enum WallpaperPropertyGroups {
    /// Each display's instance key. `assignments` holds each display's wallpaper (`properties`
    /// unset); `values` reads a wallpaper's stored properties for a scope.
    static func instanceKeys(assignments: [String: WallpaperInstanceKey], synced: Bool,
                             values: (WallpaperInstanceKey, WallpaperPropertyScope) -> [String: String])
        -> [String: WallpaperInstanceKey] {
        guard !synced else { return assignments.mapValues(\.wallpaper) }
        var keys: [String: WallpaperInstanceKey] = [:]
        let byWallpaper = Dictionary(grouping: assignments.keys) { assignments[$0]!.wallpaper }
        for (wallpaper, screens) in byWallpaper {
            var groups: [(values: [String: String], key: WallpaperInstanceKey)] = []
            for screen in screens.sorted() {
                let own = values(wallpaper, .display(screen))
                if let group = groups.first(where: { $0.values == own }) {
                    keys[screen] = group.key
                } else {
                    var key = wallpaper
                    key.properties = .display(screen)
                    groups.append((own, key))
                    keys[screen] = key
                }
            }
        }
        return keys
    }
}
