//
//  SceneFontResolver.swift
//  Open Wallpaper Engine
//
//  Finds the font a text layer names, in the order WE looks for it:
//  1. the wallpaper's own package or folder,
//  2. WE's built-in assets (`fonts/Atami-Regular.otf`: a configured install, then the bundled copy),
//  3. another Workshop item (`fonts/workshop/<id>/Quicksand-Bold.otf`),
//  4. `systemfont_<name>`, an operating-system font.
//

import AppKit

struct SceneFontResolver {
    enum Source: Equatable {
        case wallpaper, weAssets, workshop
    }

    enum Resolution: Equatable {
        /// Font file bytes to register.
        case data(Data, Source)
        /// An installed macOS font family.
        case system(String)
    }

    static let systemFontPrefix = "systemfont_"

    /// Windows system fonts that macOS doesn't ship, mapped to the closest installed family.
    /// Fonts macOS does ship (Arial, Verdana, Tahoma, Georgia, Times New Roman, Courier New…)
    /// resolve by name and need no entry here.
    static let windowsSystemFontAliases: [String: String] = [
        "segoeui": "Helvetica Neue",           // Segoe UI: humanist sans UI face
        "segoeuilight": "Helvetica Neue",
        "segoeuisemibold": "Helvetica Neue",
        "segoeuisymbol": "Apple Symbols",
        "segoeuiemoji": "Apple Color Emoji",
        "calibri": "Helvetica Neue",           // Calibri: sans; Carlito isn't installed on macOS
        "cambria": "Georgia",                  // Cambria: transitional serif
        "consolas": "Menlo",                   // Consolas: monospace
        "candara": "Optima",
        "corbel": "Gill Sans",
        "constantia": "Palatino",
        "lucidaconsole": "Menlo",
        "msgothic": "Hiragino Sans",
        "msyahei": "PingFang SC",
        "microsoftyahei": "PingFang SC",
        "simsun": "Songti SC",
        "malgungothic": "Apple SD Gothic Neo",
    ]

    /// Looks the path up in the wallpaper's own package or folder.
    let wallpaperData: (String) -> Data?
    /// WE asset roots, most preferred first (configured install, bundled copy).
    let assetDirectories: [URL]
    let workshop: WorkshopAssetResolver
    /// Installed font families; injectable for tests.
    var availableFamilies: () -> [String] = { NSFontManager.shared.availableFontFamilies }

    func resolve(_ path: String) -> Resolution? {
        if path.lowercased().hasPrefix(Self.systemFontPrefix) {
            return systemFont(for: String(path.dropFirst(Self.systemFontPrefix.count))).map(Resolution.system)
        }
        if let data = wallpaperData(path) { return .data(data, .wallpaper) }
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        if WorkshopAssetResolver.reference(in: normalized) == nil {
            for root in assetDirectories {
                let url = root.appending(path: normalized)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                do {
                    return .data(try Data(contentsOf: url), .weAssets)
                } catch {
                    OWELog.error(.scene, "Failed to read font \(url.path): \(error)")
                }
            }
        } else if let data = workshop.data(for: normalized) {
            return .data(data, .workshop)
        }
        return nil
    }

    /// `arial` → `Arial`, `timesnewroman` → `Times New Roman`, `segoeui` → alias.
    func systemFont(for name: String) -> String? {
        let key = Self.key(name)
        let families = availableFamilies()
        if let family = families.first(where: { Self.key($0) == key }) { return family }
        if let alias = Self.windowsSystemFontAliases[key], families.contains(alias) { return alias }
        return nil
    }

    private static func key(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
