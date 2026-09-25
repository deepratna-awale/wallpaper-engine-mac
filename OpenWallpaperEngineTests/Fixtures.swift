import Foundation
@testable import OpenWallpaperEngine

/// Fixtures live in `Tests/Fixtures` at the repository root, outside the test target, so they are
/// read from the source checkout instead of being flattened into the test bundle.
enum Fixtures {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Tests/Fixtures", directoryHint: .isDirectory)

    static func url(_ path: String) -> URL { root.appending(path: path) }

    static func data(_ path: String) throws -> Data { try Data(contentsOf: url(path)) }

    /// A writable copy, for code under test that writes caches next to its input.
    static func temporaryCopy(of path: String) throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "owe-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: url(path), to: destination)
        return destination
    }
}

extension Fixtures {
    /// Removes what loading the wallpaper in `directory` stores in the app's defaults (its settings,
    /// under its identity and any old path key), so tests leave nothing behind.
    static func removeStoredSettings(for directory: URL) {
        let identity = WallpaperSettingsIdentity(directory: directory,
                                                 projectData: FileManager.default.contents(atPath: directory.appending(path: "project.json").path))
        for family in WallpaperSettingsIdentity.Family.allCases {
            UserDefaults.standard.removeObject(forKey: identity.key(family))
            UserDefaults.standard.removeObject(forKey: family.rawValue + directory.path)
        }
        UserDefaults.standard.removeObject(forKey: "SceneAdditionalControlsVersion." + directory.path)
    }

    /// True when WE's effect shader sources are reachable (a configured install or a bundled copy
    /// with GLSL). Tests that need an effect to plan skip without them.
    static var hasWEShaderSources: Bool {
        guard let assets = WallpaperEngineAssets.directory else { return false }
        return FileManager.default.fileExists(atPath: assets.appending(path: "effects/tint/shaders/effects/tint.frag").path)
    }
}
