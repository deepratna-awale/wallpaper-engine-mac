import XCTest
import Metal
import simd
@testable import OpenWallpaperEngine

/// Operators and initializers address control points by index (`controlpoint`), and a child can
/// take its control points from its parent's particles (link flag 1).
final class ParticleControlPointTests: XCTestCase {
    private var texture: MTLTexture!

    override func setUpWithError() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        texture = try XCTUnwrap(device.makeTexture(descriptor: .texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)))
    }

    /// WE's control points (`wallpaper64.exe` 0x14022e3e0), by index, in the system's space: an
    /// offset from the emitter, the cursor (flag 1), a scene position (flag 2), the parent system's
    /// point (flag 4) or the object's `controlpoint<n>` override.
    func testControlPointsFollowTheirFlags() {
        var system = ParticleTestSystem()
        system.origin = SIMD2(500, 500)
        system.emitterLinear = simd_float2x2(diagonal: SIMD2(2, 2))
        system.controlPoints[1] = ParticleTestSystem.point(SIMD2(30, -40))
        system.controlPoints[2] = ParticleTestSystem.point(.zero, cursor: true)
        system.controlPoints[3] = ParticleControlPoint(offset: SIMD2(100, 50), worldSpace: true)
        var configuration = system.configuration
        configuration.overrides.controlPoints[4] = SIMD3(10, 20, 0)
        let runtime = ParticleSystemRuntime(texture: texture, configuration: configuration, seed: 1)
        let cursor = SIMD2<Float>(700, 200)
        let inputs = ParticleFrameInputs.advance(runtime, deltaTime: 1 / 60, cursor: cursor)
        XCTAssertEqual(inputs.controlPoints[0], .zero, "control point 0 is the emitter")
        XCTAssertEqual(inputs.controlPoints[1], SIMD2(30, -40), "an offset in the system's space")
        XCTAssertEqual(inputs.controlPoints[2], SIMD2(100, -150), "the cursor, taken into the system's space")
        XCTAssertEqual(inputs.controlPoints[3], SIMD2(-200, -225), "a scene position")
        XCTAssertEqual(inputs.controlPoints[4], SIMD2(10, 20), "the object's override")
        XCTAssertEqual(runtime.lastControlPoints[1], SIMD2(560, 420))
        XCTAssertEqual(inputs.absolutePoints, 0b1100)
        let moved = inputs.placed(at: SIMD2(100, 0), previous: SIMD2(100, 0))
        XCTAssertEqual(moved.controlPoints[2], SIMD2(50, -150), "a cursor point stays put in the scene")
        XCTAssertEqual(moved.controlPoints[1], SIMD2(30, -40), "an emitter point moves with the instance")
    }

    /// The json's control points by position, with their flags (0x1401d0530).
    func testTheBuilderReadsControlPointFlags() throws {
        let points = try JSONDecoder().decode([WEParticleControlPoint].self, from: Data(#"""
            [{"id": 0, "flags": 2, "offset": "5 5 0"}, {"id": 7, "flags": 1}, {"flags": 2, "offset": "1 2 3"},
             {"flags": 4, "parentcontrolpoint": 3}]
            """#.utf8))
        let parsed = ParticleSystemBuilder.controlPoints(points)
        XCTAssertEqual(parsed.count, 8)
        XCTAssertFalse(parsed[0].worldSpace, "control point 0 is never in the scene")
        XCTAssertTrue(parsed[1].followsCursor, "the id is ignored")
        XCTAssertTrue(parsed[2].worldSpace)
        XCTAssertEqual(parsed[2].offset, SIMD2(1, 2))
        XCTAssertEqual(parsed[3].parentControlPoint, 3)
    }
}
