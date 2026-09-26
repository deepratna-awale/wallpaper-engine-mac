import XCTest
@testable import OpenWallpaperEngine

/// D3/D8: full parent transforms and image alignment anchors, checked against objects taken from
/// real workshop scenes (see `_source` in the fixture).
final class SceneTransformTests: XCTestCase {
    private let sceneSize = SIMD2<Float>(3840, 2160)

    private func hierarchy() throws -> SceneTransformHierarchy {
        let objects = try JSONDecoder().decode([WESceneObject].self,
                                               from: Fixtures.data("Scenes/text-transforms/objects.json"))
        return SceneTransformHierarchy(objects: objects, sceneSize: sceneSize)
    }

    private func assertEqual(_ a: SIMD2<Float>, _ b: SIMD2<Float>, accuracy: Float = 0.01,
                             _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, "x: \(message)", file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, "y: \(message)", file: file, line: line)
    }

    /// 3677897732: 'D a y' (scale ≈4.08) under 'Clock' (scale 0.2) is drawn at ≈0.82, with its
    /// origin scaled by the parent, not summed.
    func testParentScaleAppliesToChildOriginAndSize() throws {
        let world = try hierarchy().world(of: "372")
        assertEqual(world.translation, SIMD2(86.46289 * 0.2, 567.91528 * 0.2), "origin scaled by the parent")
        XCTAssertEqual(world.axisScale.x, 4.08332 * 0.2, accuracy: 0.001)
        XCTAssertEqual(world.axisScale.y, 4.03663 * 0.2, accuracy: 0.001)
    }

    func testParentRotationTurnsChildOffsetAndAxes() {
        let hierarchy = SceneTransformHierarchy(nodes: [
            "1": .init(parentID: nil, local: SceneLocalTransform(origin: SIMD2(100, 100), scale: SIMD2(2, 2), angle: .pi / 2)),
            "2": .init(parentID: "1", local: SceneLocalTransform(origin: SIMD2(10, 0), scale: SIMD2(1, 3), angle: 0)),
        ])
        let world = hierarchy.world(of: "2")
        // A positive angle turns counter-clockwise on screen (y-up scene space), as WE's
        // object matrix does: +x maps to +y.
        assertEqual(world.translation, SIMD2(100, 120))
        let quad = SceneQuadGeometry(world: world, size: SIMD2(4, 4), alignment: nil)
        assertEqual(quad.axisX, SIMD2(0, 8))
        assertEqual(quad.axisY, SIMD2(-24, 0))
    }

    /// A live (scripted) parent transform replaces the authored one, so children follow it.
    func testLiveParentTransformMovesChildren() throws {
        let moved = SceneLocalTransform(origin: SIMD2(1000, 500), scale: SIMD2(0.5, 0.5), angle: 0)
        let world = try hierarchy().world(of: "372") { $0 == "363" ? moved : nil }
        assertEqual(world.translation, SIMD2(1000 + 86.46289 * 0.5, 500 + 567.91528 * 0.5))
    }

    func testDeepChainComposesEveryAncestor() throws {
        let world = try hierarchy().world(of: "206")
        let expectedScale: Float = 0.05014 * 0.19774 * 48.4 * 0.82645
        XCTAssertEqual(world.axisScale.x, expectedScale, accuracy: 0.0005)
        let vinylDot = SIMD2<Float>(294.08212, 374.27295) + SIMD2(-0.00098, -0.00293) * 0.05014
        let albumArt = vinylDot + SIMD2(-2193.76953, -38.15234) * (0.05014 * 0.19774)
        let artist = albumArt + SIMD2(74.38, -16.52905) * (0.05014 * 0.19774 * 48.4)
        assertEqual(world.translation, artist)
    }

    func testCyclicParentsTerminate() {
        let hierarchy = SceneTransformHierarchy(nodes: [
            "1": .init(parentID: "2", local: SceneLocalTransform(origin: SIMD2(1, 0), scale: SIMD2(1, 1), angle: 0)),
            "2": .init(parentID: "1", local: SceneLocalTransform(origin: SIMD2(0, 1), scale: SIMD2(1, 1), angle: 0)),
        ])
        assertEqual(hierarchy.world(of: "1").translation, SIMD2(1, 1))
    }

    /// 3546971487 'Media Area' is `alignment: bottom`: its bottom edge sits on the origin, and the
    /// child texts stay relative to the origin, not to the shifted quad.
    func testBottomAlignmentAnchorsBottomEdgeAtOrigin() throws {
        let hierarchy = try hierarchy()
        let area = SceneQuadGeometry(world: hierarchy.world(of: "47"), size: SIMD2(1920, 845), alignment: "bottom")
        let scale: Float = 0.35984
        assertEqual(area.center, SIMD2(3290.85107, 752.97852 + 845 * scale / 2))
        XCTAssertEqual(area.center.y - area.extent.y / 2, 752.97852, accuracy: 0.01)
        let title = hierarchy.world(of: "50")
        assertEqual(title.translation, SIMD2(3290.85107 - 137.0976 * scale, 752.97852 + 619.67834 * scale))
    }

    func testAlignmentAnchors() {
        let size = SIMD2<Float>(200, 100)
        assertEqual(SceneAlignment.centerOffset("center", size: size), .zero)
        assertEqual(SceneAlignment.centerOffset(nil, size: size), .zero)
        assertEqual(SceneAlignment.centerOffset("left", size: size), SIMD2(100, 0))
        assertEqual(SceneAlignment.centerOffset("right", size: size), SIMD2(-100, 0))
        assertEqual(SceneAlignment.centerOffset("top", size: size), SIMD2(0, -50))
        assertEqual(SceneAlignment.centerOffset("bottom", size: size), SIMD2(0, 50))
        assertEqual(SceneAlignment.centerOffset("topleft", size: size), SIMD2(100, -50))
        assertEqual(SceneAlignment.centerOffset("bottomright", size: size), SIMD2(-100, 50))
    }

    /// Alignment is a pivot in the object's own space: own scale and rotation turn around the origin.
    func testAlignmentOffsetIsScaledWithTheObject() {
        let world = SceneAffineTransform(SceneLocalTransform(origin: SIMD2(500, 500), scale: SIMD2(2, 2), angle: 0))
        let quad = SceneQuadGeometry(world: world, size: SIMD2(100, 50), alignment: "topleft")
        assertEqual(quad.center, SIMD2(600, 450))
    }

    func testRootWithoutOriginSitsAtSceneCentre() throws {
        let objects = try JSONDecoder().decode([WESceneObject].self, from: Data(#"[{"id": 1}, {"id": 2, "parent": 1}]"#.utf8))
        let hierarchy = SceneTransformHierarchy(objects: objects, sceneSize: sceneSize)
        assertEqual(hierarchy.world(of: "1").translation, sceneSize / 2)
        assertEqual(hierarchy.world(of: "2").translation, sceneSize / 2)
    }
}
