import XCTest
@testable import OpenWallpaperEngine

/// Risk #19: the WE assets without a WE install, with one, and with one that comes and goes.
final class WallpaperEngineAssetsTests: XCTestCase {
    private var scratch: URL!
    private var savedDefault: Any?

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appending(path: "owe-assets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        savedDefault = UserDefaults.standard.object(forKey: WallpaperEngineAssets.defaultsKey)
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.set(savedDefault, forKey: WallpaperEngineAssets.defaultsKey)
        try? FileManager.default.removeItem(at: scratch) // scratch cleanup
    }

    private func write(_ text: String, to path: String, in directory: URL) throws {
        let url = directory.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// The app ships its own copy, so effects work with no WE install at all.
    func testBundledAssetsAreShipped() throws {
        let bundled = try XCTUnwrap(WallpaperEngineAssets.bundled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundled.appending(path: "shaders/genericimage2.frag").path))
        UserDefaults.standard.removeObject(forKey: WallpaperEngineAssets.defaultsKey)
        XCTAssertEqual(WallpaperEngineAssets.searchDirectories, [bundled])
        XCTAssertTrue(WallpaperEngineAssets.isUsingBundledAssets)
    }

    /// A configured install on a drive that isn't mounted is skipped, and used again once it is.
    func testConfiguredInstallIsReadEachTime() throws {
        let install = scratch.appending(path: "wallpaper_engine")
        UserDefaults.standard.set(install.path, forKey: WallpaperEngineAssets.defaultsKey)
        XCTAssertNil(WallpaperEngineAssets.configured, "not there yet")
        try FileManager.default.createDirectory(at: install.appending(path: "assets"), withIntermediateDirectories: true)
        XCTAssertEqual(WallpaperEngineAssets.configured?.lastPathComponent, "assets", "normalised to its assets folder")
        XCTAssertEqual(WallpaperEngineAssets.searchDirectories.first, WallpaperEngineAssets.configured)
        if let bundled = WallpaperEngineAssets.bundled {
            XCTAssertEqual(WallpaperEngineAssets.searchDirectories.last, bundled, "the bundled copy backs it up")
        }
    }

    /// The configured install wins, and a file it lacks (an older WE) still resolves from the next.
    func testLookupFallsBackToTheNextDirectory() throws {
        let install = scratch.appending(path: "install"), bundled = scratch.appending(path: "bundled")
        try write("install", to: "shaders/both.frag", in: install)
        try write("bundled", to: "shaders/both.frag", in: bundled)
        try write("bundled", to: "materials/only-bundled.json", in: bundled)
        let both = try XCTUnwrap(WallpaperEngineAssets.locate(["shaders/both.frag"], in: [install, bundled]))
        XCTAssertEqual(try String(contentsOf: both, encoding: .utf8), "install")
        let fallback = try XCTUnwrap(WallpaperEngineAssets.locate(["only-bundled.json", "materials/only-bundled.json"],
                                                                  in: [install, bundled]))
        XCTAssertEqual(fallback.path, bundled.appending(path: "materials/only-bundled.json").standardizedFileURL.path)
        XCTAssertNil(WallpaperEngineAssets.locate(["missing"], in: [install, bundled]))
    }
}
