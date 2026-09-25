import SwiftUI
import AVKit

struct WallpaperPlaylistItem: Codable, Identifiable, Equatable {
    let id: UUID
    var wallpaper: WEWallpaper
    var duration: TimeInterval

    init(wallpaper: WEWallpaper, duration: TimeInterval = 300) {
        self.id = UUID()
        self.wallpaper = wallpaper
        self.duration = max(duration, 1)
    }

    static func == (lhs: WallpaperPlaylistItem, rhs: WallpaperPlaylistItem) -> Bool {
        lhs.id == rhs.id && lhs.wallpaper.wallpaperDirectory == rhs.wallpaper.wallpaperDirectory
            && lhs.duration == rhs.duration
    }
}

struct WallpaperPlaylist: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var items: [WallpaperPlaylistItem]
    var duration: TimeInterval
    var changeWhenVideoEnds: Bool

    init(name: String, items: [WallpaperPlaylistItem] = [], duration: TimeInterval = 300,
         changeWhenVideoEnds: Bool = false) {
        self.id = UUID()
        self.name = name
        self.items = items
        self.duration = max(duration, 1)
        self.changeWhenVideoEnds = changeWhenVideoEnds
    }

    private enum CodingKeys: String, CodingKey { case id, name, items, duration, changeWhenVideoEnds }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        items = try container.decode([WallpaperPlaylistItem].self, forKey: .items)
        duration = max(try container.decodeIfPresent(TimeInterval.self, forKey: .duration)
            ?? items.first?.duration ?? 300, 1)
        changeWhenVideoEnds = try container.decodeIfPresent(Bool.self, forKey: .changeWhenVideoEnds) ?? false
    }
}
