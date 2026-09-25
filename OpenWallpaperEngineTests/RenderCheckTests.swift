import XCTest
@testable import OpenWallpaperEngine

/// Headless checks that the scene pipeline actually produces what WE content needs. Known gaps are
/// recorded with XCTExpectFailure (strict), so fixing one makes its test fail until the expectation
/// is removed, and the gap can't be forgotten.
final class RenderCheckTests: XCTestCase {
    func testLoaderKeepsEveryVisibleLayer() throws {
        let directory = Fixtures.url("Scenes/layers")
        let project = try JSONDecoder().decode(WEProject.self, from: Fixtures.data("Scenes/layers/project.json"))
        let wallpaper = WEWallpaper(using: project, where: directory)
        defer {
            for prefix in ["SceneUserProperties.", "SceneUserPropertiesExplicit.", "SceneAdditionalControlsVersion."] {
                UserDefaults.standard.removeObject(forKey: prefix + directory.path)
            }
        }
        let content = try XCTUnwrap(SceneWallpaperViewModel(wallpaper: wallpaper).metalContent())
        let ids = Set(content.layers.map(\.id))
        XCTAssertTrue(ids.contains("1"), "text layer missing; layers: \(ids)")
        // Kept, but it samples _rt_FullFrameBuffer, which is still a transparent placeholder (B1);
        // a pixel check belongs to the Phase 3 compositing work.
        XCTAssertTrue(ids.contains("3"), "composition layer missing; layers: \(ids)")
        XCTExpectFailure("B1: solid layers (no texture) are dropped")
        XCTAssertTrue(ids.contains("2"), "solid layer missing; layers: \(ids)")
    }
}
