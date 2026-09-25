import SwiftUI
import ImageIO

struct WEWallpaper: Codable, RawRepresentable, Identifiable {
    
    var id: Int { self.project.hashValue }
    var rawValue: String {
        do {
            let rawValueData = try JSONEncoder().encode(self)
            return String(data: rawValueData, encoding: .utf8)!
        } catch {
            print(error)
            return ""
        }
    }
    
    var wallpaperDirectory: URL
    var project: WEProject

    /// A remote wallpaper stores an absolute URL in `project.file`; everything else stores a path
    /// relative to its folder.
    var mediaURL: URL {
        if let remote = URL(string: project.file), let scheme = remote.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return remote
        }
        return wallpaperDirectory.appending(path: project.file)
    }

    var isRemoteMedia: Bool {
        guard let scheme = URL(string: project.file)?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
    
    var wallpaperSize: Int {
        guard let sizeBytes = try? self.wallpaperDirectory.directoryTotalAllocatedSize(includingSubfolders: true)
        else { return 0 }
        return sizeBytes
    }
    
    init(using project: WEProject, where url: URL) {
        self.wallpaperDirectory = url
        self.project = project
    }
    
    enum CodingKeys: CodingKey {
        case wallpaperDirectory
        case project
        // <all the other elements too>
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.wallpaperDirectory = try container.decode(URL.self, forKey: .wallpaperDirectory)
        self.project = try container.decode(WEProject.self, forKey: .project)
        // <and so on>
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(wallpaperDirectory, forKey: .wallpaperDirectory)
        try container.encode(project, forKey: .project)
        // <and so on>
    }
    
    init?(rawValue: String) {
        if let rawValueData = rawValue.data(using: .utf8),
           let wallpaper = try? JSONDecoder().decode(WEWallpaper.self, from: rawValueData) {
            self = wallpaper
        } else {
            return nil
        }
    }

    var isMobileCompatible: Bool {
        (project.tags ?? []).contains { $0.localizedCaseInsensitiveContains("mobile") }
    }

    var isAudioResponsive: Bool {
        (project.tags ?? []).contains { $0.localizedCaseInsensitiveContains("audio") }
    }

    var hasCustomizableProperties: Bool {
        projectHasCustomizableProperties(at: wallpaperDirectory)
    }
}

enum WEWallpaperSortingMethod: String, CaseIterable, Identifiable {
    
    var id: Self { self }
    
    case name = "Name"
    case rating = "Rating"
//    case favorite = "Favorite"
    case fileSize = "File Size"
    case dateAdded = "Date Added"
//    case subDate = "Subscription Date"
//    case lastUpdated = "Last Updated"

    var displayName: String {
        self == .dateAdded ? "Date Downloaded" : rawValue
    }
}

enum WEWallpaperSortingSequence: Int {
    case decrease = 0, increase = 1
}

enum WEInitError: Error {
    enum WEJSONProjectInitError: Error {
        case notFound, corrupted, mismatched, unkownError
    }
    
    enum WEResourcesInitError: Error {
        case notFound, mismatchedFormat, corrupted, unkownError
    }
    
    enum WEPreviewInitError: Error {
        case notFound, notImage, unkownError
    }
    
    case badDirectoryPath
    case JSONProject(was: WEJSONProjectInitError)
    case resources(was: WEResourcesInitError)
    case preview(was: WEPreviewInitError)
}
