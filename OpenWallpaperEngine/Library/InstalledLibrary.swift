//
//  InstalledLibrary.swift
//  Open Wallpaper Engine
//
//  What the Installed tab lists, decided the way WE does: only wallpapers (project.json `type` of
//  scene, video, web or application) the user got themselves. Workshop items that aren't
//  wallpapers (asset packs, effects and other `"category": "Asset"` items, which have no `type`)
//  and items downloaded only as another wallpaper's dependency stay on disk but aren't listed.
//

import Foundation

enum InstalledLibrary {
    static let wallpaperTypes: Set<String> = ["scene", "video", "web", "application"]

    /// The listed wallpapers among the folders in `directory`.
    static func wallpapers(in directory: URL, hiding dependencyIds: Set<String>) -> [WEWallpaper] {
        let folders: [URL]
        do {
            folders = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                                  options: .skipsHiddenFiles)
        } catch {
            OWELog.error(.library, "Can't list the wallpaper library at \(directory.path): \(error)")
            return []
        }
        return folders.compactMap { wallpaper(at: $0, hiding: dependencyIds) }
    }

    /// The folder's wallpaper, or nil when it isn't listed. A folder whose project.json is missing or
    /// unreadable is still listed, as an invalid entry the user can see and delete.
    static func wallpaper(at folder: URL, hiding dependencyIds: Set<String>) -> WEWallpaper? {
        guard !dependencyIds.contains(folder.lastPathComponent) else { return nil }
        // A folder without project.json is shown as invalid below, so a failed read is expected.
        guard let data = try? Data(contentsOf: folder.appending(path: "project.json")) else {
            return WEWallpaper(using: .invalid, where: folder)
        }
        guard isWallpaperProject(data) != false else { return nil }
        do {
            var project = try JSONDecoder().decode(WEProject.self, from: data)
            project.applyTaggedContentRating()
            return WEWallpaper(using: project, where: folder)
        } catch {
            OWELog.debug(.library, "\(folder.lastPathComponent)/project.json doesn't decode: \(error)")
            return WEWallpaper(using: .invalid, where: folder)
        }
    }

    /// Whether project.json declares a wallpaper type; nil when it isn't a JSON object.
    static func isWallpaperProject(_ projectData: Data) -> Bool? {
        // Not JSON: reported as nil so the caller keeps the folder visible as invalid.
        guard let object = try? JSONSerialization.jsonObject(with: projectData),
              let project = object as? [String: Any] else { return nil }
        guard let type = project["type"] as? String else { return false }
        return wallpaperTypes.contains(type.lowercased())
    }
}
