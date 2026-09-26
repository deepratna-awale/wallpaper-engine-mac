import XCTest
import JavaScriptCore
@testable import OpenWallpaperEngine

/// JavaScriptCore compiles scripts only in a process signed with `com.apple.security.cs.allow-jit`
/// (`SceneScriptJIT`); without it every script runs interpreted, about ten times slower. The app
/// must carry it, and where the test host does, scripts must run compiled.
final class SceneScriptJITTests: XCTestCase {
    func testTheAppIsEntitledToJIT() throws {
        let url = Fixtures.root.deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "OpenWallpaperEngine/OpenWallpaperEngine.entitlements")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        let entitlements = try XCTUnwrap(plist as? [String: Any])
        XCTAssertEqual(entitlements[SceneScriptJIT.entitlement] as? Bool, true)
    }

    /// A hot loop takes about 1.3 s interpreted and 0.1 s compiled on an M-series Mac. Unsigned
    /// hosts (CI: `CODE_SIGNING_ALLOWED=NO`) have no entitlement and are skipped.
    func testScriptsRunCompiledWhereTheHostMayJIT() throws {
        try XCTSkipUnless(SceneScriptJIT.isEnabled, "the test host isn't signed with \(SceneScriptJIT.entitlement)")
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("function f(n) { let s = 0; for (let i = 0; i < n; i++) s = (s + i * 3) % 1000003; return s; } f(1000);")
        let start = Date()
        context.evaluateScript("f(20000000)")
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.6, "2·10⁷ iterations run compiled")
    }
}
