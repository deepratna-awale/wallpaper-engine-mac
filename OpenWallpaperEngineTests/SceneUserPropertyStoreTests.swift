import XCTest
@testable import OpenWallpaperEngine

final class SceneUserPropertyStoreTests: XCTestCase {
    func testWallpapersDoNotShareProperties() {
        var stores = SceneUserPropertyStores()
        stores.set(["color": "1 0 0", "speed": "2"], for: "/a", replacing: true)
        stores.set(["color": "0 0 1"], for: "/b", replacing: true)
        XCTAssertEqual(stores.entry(for: "/a").strings, ["color": "1 0 0", "speed": "2"])
        XCTAssertEqual(stores.entry(for: "/b").strings, ["color": "0 0 1"])
        XCTAssertEqual(stores.entry(for: "/a").numbers["speed"], 2)
    }

    func testReplacingDropsStaleKeysAndReportsThem() {
        var stores = SceneUserPropertyStores()
        stores.set(["old": "1", "keep": "true"], for: "/a", replacing: true)
        let changed = stores.set(["keep": "true", "new": "0.5"], for: "/a", replacing: true)
        XCTAssertEqual(Set(changed), ["old", "new"])
        XCTAssertEqual(stores.entry(for: "/a").strings, ["keep": "true", "new": "0.5"])
        XCTAssertNil(stores.entry(for: "/a").numbers["old"])
        XCTAssertEqual(stores.entry(for: "/a").numbers["keep"], 1)
    }

    func testMergeKeepsOtherKeys() {
        var stores = SceneUserPropertyStores()
        stores.set(["a": "1"], for: "/a", replacing: true)
        stores.set(["b": "2"], for: "/a", replacing: false)
        XCTAssertEqual(stores.entry(for: "/a").strings, ["a": "1", "b": "2"])
    }

    func testActiveEntryFollowsActiveKey() {
        var stores = SceneUserPropertyStores()
        stores.set(["x": "1"], for: "/a", replacing: true)
        stores.set(["x": "2"], for: "/b", replacing: true)
        stores.activeKey = "/b"
        XCTAssertEqual(stores.active.strings["x"], "2")
        stores.active.numbers["script"] = 5
        XCTAssertEqual(stores.entry(for: "/b").numbers["script"], 5)
        XCTAssertNil(stores.entry(for: "/a").numbers["script"])
    }

    /// Two displays rendering different wallpapers read their own properties each frame.
    func testEngineFramesReadTheirWallpaper() {
        let engine = AudioReactiveScriptEngine.shared
        let a = "/tests/\(UUID().uuidString)/a", b = "/tests/\(UUID().uuidString)/b"
        engine.setUserProperties(["tint": "1 0 0"], wallpaper: a, replacing: true)
        engine.setUserProperties(["tint": "0 1 0"], wallpaper: b, replacing: true)

        engine.beginFrame(wallpaper: a)
        XCTAssertEqual(engine.userPropertyString("tint"), "1 0 0")
        engine.endFrame()
        engine.beginFrame(wallpaper: b)
        XCTAssertEqual(engine.userPropertyString("tint"), "0 1 0")
        engine.endFrame()

        XCTAssertEqual(engine.userPropertyString("tint", wallpaper: a), "1 0 0")
        let context = LiveSceneValueContext(engine: engine, time: 0, wallpaper: b)
        XCTAssertEqual(SceneValueResolver.resolve(.user(name: "tint", condition: nil, fallback: .literal(.zero)),
                                                  in: context).components, [0, 1, 0])
    }
}
