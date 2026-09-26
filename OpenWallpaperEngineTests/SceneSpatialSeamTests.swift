import XCTest
import simd
@testable import OpenWallpaperEngine

/// The seams M0 of docs/models-plan.md added (§4.4): the content's `spatial` part and the frame
/// camera, which must still be the camera the renderer drew with before.
final class SceneSpatialSeamTests: XCTestCase {
    func testSpatialContentCollectsModelsCameraLayersAndPaths() throws {
        let scene = try decodeTolerant(WEScene.self, from: Data("""
        {"camera": {"eye": "1 2 3", "paths": ["scripts/camera_00.json", "scripts/missing.json"]},
         "general": {"orthogonalprojection": null, "transparentsorting": true},
         "objects": [
           {"id": 1, "name": "cam", "camera": "default", "path": "scripts/camera_paths_1.json"},
           {"id": 2, "name": "box", "model": "models/box.mdl", "castshadow": false},
           {"id": 3, "name": "image", "image": "models/a.json"},
           {"id": 4, "name": "both", "model": "models/b.mdl", "camera": "default"},
           {"id": 5, "name": "cam2", "camera": "default"}]}
        """.utf8))
        let files = ["scripts/camera_00.json": try Fixtures.data("Spatial/scene-camera-paths.json"),
                     "scripts/camera_paths_1.json": try Fixtures.data("Spatial/camera-layer-paths.json")]
        var reads: [String] = []
        let content = SceneSpatialContentBuilder(readFile: { reads.append($0); return files[$0] },
                                                 wallpaperName: "fixture").build(scene, context: SpatialProperties())
        XCTAssertTrue(content.camera.projection.isPerspective)
        XCTAssertEqual(content.drawOrder, SceneDrawOrderMode(splitsTranslucent: true))
        XCTAssertEqual(content.staticEye, SIMD3(1, 2, 3))
        XCTAssertEqual(content.staticCenter, SceneCameraDefaults.center)
        XCTAssertEqual(content.staticUp, SceneCameraDefaults.up)
        XCTAssertEqual(content.cameraPaths.map(\.name), ["first", "untimed"])
        XCTAssertEqual(content.models.map(\.id), ["2", "4"])
        XCTAssertEqual(content.models.map(\.order), [1, 3])
        XCTAssertEqual(content.models[0].renderValues[.castshadow], .bool(false))
        XCTAssertEqual(content.cameraLayers.map(\.id), ["1", "5"])
        XCTAssertEqual(content.cameraLayers[0].pathFile?.paths.count, 2)
        XCTAssertNil(content.cameraLayers[1].pathFile)
        XCTAssertEqual(reads, ["scripts/camera_00.json", "scripts/missing.json", "scripts/camera_paths_1.json"])
    }

    /// Today's rig reproduces the camera the renderer draws with: the layer pass's matrix and the
    /// lighting camera's eye and forward.
    func testTodaysCameraRigKeepsTheRenderersCamera() throws {
        var content = SceneMetalContent(size: SIMD2(1920, 1080), layers: [], particleSystems: [],
                                        bloom: SceneBloomSettings(enabled: false, strength: 0, threshold: 0,
                                                                  tint: SIMD3(repeating: 1)))
        content.lighting.camera = SceneVolumetricsCamera(eye: SIMD3(960, 540, 2000), center: SIMD3(960, 540, 0))
        let rig = SceneCameraRigs.make(for: content)
        let camera = rig.frameCamera(SceneCameraRigInput(sceneSize: content.size, aspect: 16.0 / 9, time: 1, deltaTime: 1 / 60))
        XCTAssertEqual(camera.viewProjection, ImageMaterialRenderer.viewProjection(sceneSize: content.size))
        XCTAssertEqual(camera.eye, SIMD3(960, 540, 2000))
        XCTAssertEqual(camera.forward, content.lighting.camera.forward)
        XCTAssertFalse(camera.isPerspective)
        XCTAssertFalse(camera.reversedDepth)
    }
}
