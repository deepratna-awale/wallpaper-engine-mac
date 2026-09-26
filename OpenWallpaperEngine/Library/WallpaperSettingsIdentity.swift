import Foundation
import CryptoKit

/// Names a wallpaper's stored settings (its user property values) by what the wallpaper is, not
/// where it is, so moving or renaming the library keeps them.
///
/// The identity is the Workshop id when there is one (`project.json`'s `workshopid`, or a
/// numeric folder name, which is how Steam names Workshop downloads), else a hash of
/// `project.json`'s bytes plus the folder name. Settings stored under the old path keys are
/// moved over the first time a wallpaper is seen (`resolve`).
struct WallpaperSettingsIdentity: Hashable {
    let rawValue: String

    /// The stored settings families, each `<prefix><identity>` (formerly `<prefix><path>`).
    enum Family: String, CaseIterable {
        case userProperties = "SceneUserProperties."
        /// Whether the user ever set a value (else project defaults are re-derived on load).
        case explicitUserProperties = "SceneUserPropertiesExplicit."
    }

    init(rawValue: String) { self.rawValue = rawValue }

    /// The identity of the wallpaper in `directory`, from its `project.json` (nil when unreadable:
    /// the folder name alone then, which is all that is known).
    init(directory: URL, projectData: Data?) {
        let folder = directory.standardizedFileURL.lastPathComponent
        if let id = Self.workshopID(projectData: projectData, folder: folder) {
            rawValue = "workshop-\(id)"
        } else if let projectData {
            let digest = SHA256.hash(data: projectData).prefix(8).map { String(format: "%02x", $0) }.joined()
            rawValue = "local-\(digest)-\(folder)"
        } else {
            rawValue = "local-\(folder)"
        }
    }

    func key(_ family: Family) -> String { family.rawValue + rawValue }

    /// The identity of the wallpaper in `directory`, with any settings still stored under a path
    /// key moved to it: the directory's own path, or else a single path with the same folder name
    /// that no longer exists (the library moved). Settings already under the identity win.
    static func resolve(directory: URL, defaults: UserDefaults = .standard) -> WallpaperSettingsIdentity {
        let projectURL = directory.appending(path: "project.json")
        let projectData: Data?
        do {
            projectData = try Data(contentsOf: projectURL)
        } catch {
            OWELog.error(.library, "Could not read \(projectURL.path) to identify its settings: \(error)")
            projectData = nil
        }
        let identity = WallpaperSettingsIdentity(directory: directory, projectData: projectData)
        identity.migrateLegacyKeys(from: directory, defaults: defaults)
        return identity
    }

    static func resolve(_ wallpaper: WEWallpaper, defaults: UserDefaults = .standard) -> WallpaperSettingsIdentity {
        resolve(directory: wallpaper.wallpaperDirectory, defaults: defaults)
    }

    private func migrateLegacyKeys(from directory: URL, defaults: UserDefaults) {
        guard defaults.object(forKey: key(.userProperties)) == nil else { return }
        let path = directory.path
        let prefix = Family.userProperties.rawValue
        var legacyPath: String?
        if defaults.object(forKey: prefix + path) != nil {
            legacyPath = path
        } else {
            let folder = directory.standardizedFileURL.lastPathComponent
            let moved = defaults.dictionaryRepresentation().keys.compactMap { key -> String? in
                guard key.hasPrefix(prefix + "/") else { return nil }
                let candidate = String(key.dropFirst(prefix.count))
                guard URL(fileURLWithPath: candidate).lastPathComponent == folder,
                      !FileManager.default.fileExists(atPath: candidate) else { return nil }
                return candidate
            }
            // Two missing folders of the same name can't be told apart; neither is guessed.
            if moved.count == 1 { legacyPath = moved[0] }
        }
        guard let legacyPath else { return }
        for family in Family.allCases {
            let old = family.rawValue + legacyPath
            guard let value = defaults.object(forKey: old) else { continue }
            if defaults.object(forKey: key(family)) == nil { defaults.set(value, forKey: key(family)) }
            defaults.removeObject(forKey: old)
        }
        OWELog.info(.library, "Moved the settings stored for \(legacyPath) to \(rawValue)")
    }

    private static func workshopID(projectData: Data?, folder: String) -> String? {
        if let projectData,
           let root = (try? JSONSerialization.jsonObject(with: projectData)) as? [String: Any] { // unreadable: no id
            let raw = root["workshopid"].map { "\($0)" } ?? ""
            if !raw.isEmpty, raw.allSatisfy(\.isNumber) { return raw }
        }
        if !folder.isEmpty, folder.allSatisfy(\.isNumber) { return folder }
        return nil
    }
}
