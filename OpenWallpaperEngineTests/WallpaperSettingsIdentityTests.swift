import XCTest
@testable import OpenWallpaperEngine

/// Risk #21: per-wallpaper settings follow the wallpaper, not its folder path.
final class WallpaperSettingsIdentityTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var root: URL!

    override func setUpWithError() throws {
        suite = "owe-settings-identity-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        root = FileManager.default.temporaryDirectory.appending(path: suite, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root) // scratch cleanup
    }

    /// A wallpaper folder at `path` under the scratch root with this project.json.
    @discardableResult
    private func wallpaper(_ path: String, project: String = #"{"title":"Rain","type":"scene","file":"scene.json"}"#) throws -> URL {
        let directory = root.appending(path: path, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(project.utf8).write(to: directory.appending(path: "project.json"))
        return directory
    }

    private func move(_ directory: URL, to path: String) throws -> URL {
        let destination = root.appending(path: path, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: directory, to: destination)
        return destination
    }

    func testWorkshopIdFromProjectOrFolder() throws {
        let declared = try wallpaper("library/anything", project: #"{"workshopid":"12345","file":"scene.json"}"#)
        XCTAssertEqual(WallpaperSettingsIdentity.resolve(directory: declared, defaults: defaults).rawValue, "workshop-12345")
        let numeric = try wallpaper("library/67890", project: #"{"workshopid":67890}"#)
        XCTAssertEqual(WallpaperSettingsIdentity.resolve(directory: numeric, defaults: defaults).rawValue, "workshop-67890")
        let steamFolder = try wallpaper("library/424242")
        XCTAssertEqual(WallpaperSettingsIdentity.resolve(directory: steamFolder, defaults: defaults).rawValue, "workshop-424242")
    }

    func testLocalWallpapersAreIdentifiedByContentAndFolderName() throws {
        let a = try wallpaper("one/Rain")
        let identity = WallpaperSettingsIdentity.resolve(directory: a, defaults: defaults)
        XCTAssertTrue(identity.rawValue.hasPrefix("local-") && identity.rawValue.hasSuffix("-Rain"), identity.rawValue)
        let moved = try move(a, to: "elsewhere/deeper/Rain")
        XCTAssertEqual(WallpaperSettingsIdentity.resolve(directory: moved, defaults: defaults), identity, "same wallpaper, new place")
        let edited = try wallpaper("two/Rain", project: #"{"title":"Snow","file":"scene.json"}"#)
        XCTAssertNotEqual(WallpaperSettingsIdentity.resolve(directory: edited, defaults: defaults), identity, "a different project")
        let renamed = try wallpaper("three/Drizzle")
        XCTAssertNotEqual(WallpaperSettingsIdentity.resolve(directory: renamed, defaults: defaults), identity,
                          "copies of one project in two folders keep their own settings")
    }

    func testSettingsSurviveMovingTheLibrary() throws {
        let directory = try wallpaper("library/Rain")
        let key = WallpaperSettingsIdentity.resolve(directory: directory, defaults: defaults).key(.userProperties)
        defaults.set(["speed": "2"], forKey: key)
        let moved = try move(directory, to: "new-library/Rain")
        let after = WallpaperSettingsIdentity.resolve(directory: moved, defaults: defaults).key(.userProperties)
        XCTAssertEqual(defaults.dictionary(forKey: after) as? [String: String], ["speed": "2"])
    }

    func testPathKeyedSettingsMigrateOnFirstSight() throws {
        let directory = try wallpaper("library/Rain")
        defaults.set(["speed": "2"], forKey: "SceneUserProperties." + directory.path)
        defaults.set(true, forKey: "SceneUserPropertiesExplicit." + directory.path)
        let identity = WallpaperSettingsIdentity.resolve(directory: directory, defaults: defaults)
        XCTAssertEqual(defaults.dictionary(forKey: identity.key(.userProperties)) as? [String: String], ["speed": "2"])
        XCTAssertTrue(defaults.bool(forKey: identity.key(.explicitUserProperties)))
        XCTAssertNil(defaults.object(forKey: "SceneUserProperties." + directory.path), "the old key is gone")
    }

    /// Settings saved by an older build, then the library moved before the upgrade: the old path
    /// no longer exists, and the one missing folder of that name is the wallpaper's.
    func testSettingsOfAMovedLibraryMigrateByFolderName() throws {
        let old = root.appending(path: "old-library/Rain").path
        defaults.set(["speed": "3"], forKey: "SceneUserProperties." + old)
        let directory = try wallpaper("new-library/Rain")
        let identity = WallpaperSettingsIdentity.resolve(directory: directory, defaults: defaults)
        XCTAssertEqual(defaults.dictionary(forKey: identity.key(.userProperties)) as? [String: String], ["speed": "3"])
        XCTAssertNil(defaults.object(forKey: "SceneUserProperties." + old))
    }

    func testAmbiguousOrLiveLegacyKeysAreLeftAlone() throws {
        defaults.set(["speed": "1"], forKey: "SceneUserProperties." + root.appending(path: "gone-a/Rain").path)
        defaults.set(["speed": "2"], forKey: "SceneUserProperties." + root.appending(path: "gone-b/Rain").path)
        let directory = try wallpaper("new/Rain")
        let identity = WallpaperSettingsIdentity.resolve(directory: directory, defaults: defaults)
        XCTAssertNil(defaults.object(forKey: identity.key(.userProperties)), "two candidates: neither is guessed")

        let other = try wallpaper("live/Snow")
        defaults.set(["speed": "4"], forKey: "SceneUserProperties." + other.path)
        let sameName = try wallpaper("copy/Snow", project: #"{"title":"Snow copy"}"#)
        let copyIdentity = WallpaperSettingsIdentity.resolve(directory: sameName, defaults: defaults)
        XCTAssertNil(defaults.object(forKey: copyIdentity.key(.userProperties)), "a folder that still exists keeps its settings")
        XCTAssertNotNil(defaults.object(forKey: "SceneUserProperties." + other.path))
    }

    func testSettingsUnderTheIdentityWin() throws {
        let directory = try wallpaper("library/Rain")
        let identity = WallpaperSettingsIdentity(directory: directory, projectData: try Data(contentsOf: directory.appending(path: "project.json")))
        defaults.set(["speed": "new"], forKey: identity.key(.userProperties))
        defaults.set(["speed": "old"], forKey: "SceneUserProperties." + directory.path)
        _ = WallpaperSettingsIdentity.resolve(directory: directory, defaults: defaults)
        XCTAssertEqual(defaults.dictionary(forKey: identity.key(.userProperties)) as? [String: String], ["speed": "new"])
    }
}
