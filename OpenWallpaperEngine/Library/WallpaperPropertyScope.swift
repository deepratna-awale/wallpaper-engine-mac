import Foundation

extension Notification.Name {
    /// A wallpaper's user properties were saved (the sidebar or the inspector): displays regroup
    /// by their properties (`WallpaperViewModel.refreshInstanceKeys`).
    static let wallpaperPropertiesDidSave = Notification.Name("WallpaperPropertiesDidSave")
}

/// Whose user properties a wallpaper runs with: one store every display shares ("Sync properties
/// across displays"), or each display's own.
///
/// WE keeps a wallpaper's properties per display (`currentSelection.properties[monitor.location]`
/// in its `ui/dist/scripts/scripts.js`), so the same wallpaper on two displays has independent
/// properties under its default "Wallpaper per display" layout; its "Clone single wallpaper"
/// layout shows one wallpaper, with one set of properties, on every display. The sync setting is
/// that choice for properties alone.
enum WallpaperPropertyScope: Hashable, CustomStringConvertible {
    case shared
    case display(String)

    /// Appended to the wallpaper's settings keys (`WallpaperSettingsIdentity.key(_:scope:)`).
    var settingsSuffix: String {
        switch self {
        case .shared: return ""
        case .display(let id): return ".display.\(id)"
        }
    }

    /// The key of this scope's properties in the running store (`SceneUserPropertyService`), for
    /// the wallpaper in `directory`: its path for the shared store, as before scopes existed.
    func runtimeKey(directory: URL) -> String {
        switch self {
        case .shared: return directory.path
        case .display(let id): return directory.path + "#display=" + id
        }
    }

    var description: String {
        switch self {
        case .shared: return "shared"
        case .display(let id): return "display \(id)"
        }
    }
}

extension WallpaperSettingsIdentity {
    /// `family`'s key for `scope`.
    func key(_ family: Family, scope: WallpaperPropertyScope) -> String { key(family) + scope.settingsSuffix }

    /// `scope`'s stored values of `family`, falling back to the shared ones for a display whose own
    /// were never saved: a display starts from the properties the wallpaper had before.
    func stored(_ family: Family, scope: WallpaperPropertyScope, defaults: UserDefaults = .standard) -> Any? {
        defaults.object(forKey: key(family, scope: scope)) ?? defaults.object(forKey: key(family))
    }

    /// Saves the shared values under `scope`'s own keys when it has none yet, so a display's store
    /// starts from the wallpaper's properties and is read and written under its own key from then on.
    func seed(_ scope: WallpaperPropertyScope, defaults: UserDefaults = .standard) {
        guard scope != .shared else { return }
        for family in Family.allCases where defaults.object(forKey: key(family, scope: scope)) == nil {
            if let shared = defaults.object(forKey: key(family)) { defaults.set(shared, forKey: key(family, scope: scope)) }
        }
    }
}
