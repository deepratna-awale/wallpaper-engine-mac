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

    func testPointOperatorsSitOnTheirControlPoint() {
        var system = ParticleTestSystem()
        system.controlPoints = [ParticleControlPoint(id: 1, offset: SIMD2(30, -40), locksToCursor: false),
                                ParticleControlPoint(id: 2, offset: .zero, locksToCursor: true)]
        system.attractor = Attractor(offset: SIMD2(5, 0), strength: 100, threshold: 1000, controlPoint: 1)
        system.vortex = ParticleVortex(innerSpeed: 10, outerSpeed: 10, innerDistance: 0, outerDistance: 100, controlPoint: 2)
        system.nearControlPointReduction = ParticleDistanceReduction(offset: .zero, innerDistance: 0, outerDistance: 10,
                                                                     reduction: 1, controlPoint: 1)
        let runtime = ParticleSystemRuntime(texture: texture, configuration: system.configuration, seed: 1)
        let cursor = SIMD2<Float>(700, 200)
        let inputs = ParticleFrameInputs.advance(runtime, deltaTime: 1 / 60, cursor: cursor)
        XCTAssertEqual(inputs.attractorOrigin, SIMD2(535, 460), "control point 1 plus the operator's origin")
        XCTAssertEqual(inputs.reductionOrigin, SIMD2(530, 460))
        XCTAssertEqual(inputs.vortexOrigin, cursor, "control point 2 follows the cursor")
        let moved = inputs.placed(at: SIMD2(100, 0))
        XCTAssertEqual(moved.vortexOrigin, cursor, "a cursor point stays put in every instance")
        XCTAssertEqual(moved.reductionOrigin, SIMD2(630, 460), "an emitter point moves with the instance")
    }
}
