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

    /// The item auto-advance moves to after `current`, passing over any `isSkipped` item. Nil
    /// when the end is reached without `repeats`, or when every item is skipped.
    func nextIndex(after current: Int, shuffle: Bool, repeats: Bool, isSkipped: (Int) -> Bool,
                   random: (Range<Int>) -> Int = { Int.random(in: $0) }) -> Int? {
        guard !items.isEmpty else { return nil }
        if shuffle {
            let playable = items.indices.filter { !isSkipped($0) }
            guard !playable.isEmpty else { return nil }
            return playable[random(0..<playable.count)]
        }
        var index = current
        for _ in 0..<items.count {
            index += 1
            if index >= items.count {
                guard repeats else { return nil }
                index = 0
            }
            if !isSkipped(index) { return index }
        }
        return nil
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
