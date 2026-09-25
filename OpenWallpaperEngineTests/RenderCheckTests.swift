import XCTest
import Metal
@testable import OpenWallpaperEngine

/// Headless checks that the scene pipeline actually produces what WE content needs. Known gaps are
/// recorded with XCTExpectFailure (strict), so fixing one makes its test fail until the expectation
/// is removed, and the gap can't be forgotten.
final class RenderCheckTests: XCTestCase {
    func testTranslatedEffectPipelinesBuild() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let shaders = try XCTUnwrap(Bundle.main.resourceURL)
            .appending(path: "we-assets/.open-wallpaper-engine/shaders", directoryHint: .isDirectory)
        let names = try FileManager.default.contentsOfDirectory(atPath: shaders.path)
        let vertexShaders = names.filter { $0.hasSuffix(".vert.metal") && !$0.contains("_preview_") }.sorted()
        XCTAssertFalse(vertexShaders.isEmpty)
        let cache = DynamicEffectPipelineCache(device: device)
        var failed: [String] = []
        for vertex in vertexShaders {
            let fragment = vertex.replacingOccurrences(of: ".vert.metal", with: ".frag.metal")
            guard names.contains(fragment) else { continue }
            if cache.pipeline(vertexURL: shaders.appending(path: vertex), fragmentURL: shaders.appending(path: fragment),
                              pixelFormat: .bgra8Unorm, macroConfiguration: "", blending: nil) == nil {
                failed.append(vertex)
            }
        }
        XCTExpectFailure("A1: pipelines have no vertex descriptor, so no translated WE shader renders")
        XCTAssertEqual(failed, [], "\(failed.count) of \(vertexShaders.count) effect pipelines failed to build")
    }

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
