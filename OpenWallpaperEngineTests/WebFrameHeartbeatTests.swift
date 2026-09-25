import XCTest
@testable import OpenWallpaperEngine

/// Web wallpapers report `requestAnimationFrame` intervals to the render watchdog.
final class WebFrameHeartbeatTests: XCTestCase {
    func testFrameIntervalsDecodeFromTheMessageBody() {
        XCTAssertEqual(WebWallpaperPropertyBridge.frameIntervals(from: [0.016, 0.5, NSNumber(value: 0.02)]), [0.016, 0.5, 0.02])
        XCTAssertEqual(WebWallpaperPropertyBridge.frameIntervals(from: ["x", -1, Double.nan, 0.1] as [Any]), [0.1])
        XCTAssertEqual(WebWallpaperPropertyBridge.frameIntervals(from: "nope"), [])
    }

    func testBootstrapPostsFrameIntervals() {
        XCTAssertTrue(WebWallpaperPropertyBridge.bootstrapScript.contains(WebWallpaperPropertyBridge.frameMessageName))
        XCTAssertTrue(WebWallpaperPropertyBridge.bootstrapScript.contains("requestAnimationFrame"))
    }
}
