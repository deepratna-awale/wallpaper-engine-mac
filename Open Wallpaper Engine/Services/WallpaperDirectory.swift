import Foundation
import Combine

final class DownloadedWallpaperIndex: ObservableObject {
    static let shared = DownloadedWallpaperIndex()

    @Published private(set) var ids: Set<String>
    private let storageKey = "DownloadedWorkshopWallpaperIds"
    private let dateStorageKey = "DownloadedWorkshopWallpaperDates"
    private var downloadDates: [String: Date]

    private init() {
        ids = Set(UserDefaults.standard.stringArray(forKey: storageKey) ?? [])
        downloadDates = Self.decodeDates(UserDefaults.standard.dictionary(forKey: dateStorageKey))
        if ids.isEmpty || downloadDates.isEmpty {
            rebuildFromLibrary()
        }
    }

    func contains(_ workshopId: String) -> Bool {
        ids.contains(workshopId)
    }

    func insert(_ workshopId: String) {
        ids.insert(workshopId)
        if downloadDates[workshopId] == nil {
            downloadDates[workshopId] = .now
        }
        save()
    }

    func dateAdded(for directory: URL) -> Date {
        let workshopId = directory.lastPathComponent
        if let date = downloadDates[workshopId] {
            return date
        }
        return (try? directory.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    func remove(directory: URL) {
        let workshopId = directory.lastPathComponent
        guard ids.remove(workshopId) != nil else { return }
        downloadDates.removeValue(forKey: workshopId)
        save()
    }

    private func rebuildFromLibrary() {
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: FileManager.default.wallpapersDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        let downloadedDirectories = directories.compactMap { directory -> URL? in
            let workshopId = directory.lastPathComponent
            guard workshopId.allSatisfy(\.isNumber),
                  FileManager.default.fileExists(atPath: directory.appending(path: "project.json").path) else {
                return nil
            }
            return directory
        }
        ids = Set(downloadedDirectories.map(\.lastPathComponent))
        for directory in downloadedDirectories {
            let workshopId = directory.lastPathComponent
            if downloadDates[workshopId] == nil {
                downloadDates[workshopId] = (try? directory.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .now
            }
        }
        save()
    }

    private func save() {
        UserDefaults.standard.set(ids.sorted(), forKey: storageKey)
        UserDefaults.standard.set(
            downloadDates.mapValues(\.timeIntervalSince1970),
            forKey: dateStorageKey
        )
    }

    private static func decodeDates(_ storedDates: [String: Any]?) -> [String: Date] {
        (storedDates ?? [:]).reduce(into: [:]) { dates, entry in
            guard let timestamp = entry.value as? Double else { return }
            dates[entry.key] = Date(timeIntervalSince1970: timestamp)
        }
    }
}

extension FileManager {
    /// The dedicated directory for storing wallpaper packages.
    /// Located at `~/Documents/Open Wallpaper Engine/`, created automatically if missing.
    var wallpapersDirectory: URL {
        let dir = urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "Open Wallpaper Engine")
        if !fileExists(atPath: dir.path) {
            try? createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
}
