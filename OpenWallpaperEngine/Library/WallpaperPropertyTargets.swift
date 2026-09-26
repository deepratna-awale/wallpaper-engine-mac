import Foundation

/// The user-property stores an edit in the sidebar or the inspector goes to: the selected
/// displays' (`WallpaperViewModel.editedPropertyScopes`), or the shared store while properties
/// are synced. The first scope is the one shown.
struct WallpaperPropertyTargets {
    let directory: URL
    let identity: WallpaperSettingsIdentity
    let scopes: [WallpaperPropertyScope]

    init(wallpaper: WEWallpaper, scopes: [WallpaperPropertyScope]) {
        directory = wallpaper.wallpaperDirectory
        identity = WallpaperSettingsIdentity.resolve(wallpaper)
        self.scopes = scopes.isEmpty ? [.shared] : scopes
    }

    /// The shown scope's saved values (the shared ones for a display that has none yet).
    var storedValues: [String: String] {
        identity.stored(.userProperties, scope: scopes[0]) as? [String: String] ?? [:]
    }

    /// The keys of the running stores (`SceneUserPropertyService`) the scopes are read from.
    var runtimeKeys: [String] { scopes.map { $0.runtimeKey(directory: directory) } }

    /// Hands `values` to the running wallpapers at once.
    func publish(_ values: [String: String]) {
        for key in runtimeKeys { WallpaperServices.shared.setUserProperties(values, wallpaper: key, replacing: false) }
    }

    /// Saves `values` as every scope's, marked as set by the user, and lets the displays regroup
    /// by their properties (`Notification.Name.wallpaperPropertiesDidSave`).
    func save(_ values: [String: String], defaults: UserDefaults = .standard) {
        for scope in scopes {
            defaults.set(values, forKey: identity.key(.userProperties, scope: scope))
            defaults.set(true, forKey: identity.key(.explicitUserProperties, scope: scope))
        }
        NotificationCenter.default.post(name: .wallpaperPropertiesDidSave, object: directory.path)
    }
}
