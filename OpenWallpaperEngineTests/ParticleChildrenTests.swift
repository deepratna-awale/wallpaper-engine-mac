import XCTest
import simd
@testable import OpenWallpaperEngine

/// Child particle systems (`children`): decoding, how the loader flattens them, and how static and
/// event children run on the CPU and GPU.
final class ParticleChildrenTests: XCTestCase {
    private func particleSystem(_ name: String) throws -> WEParticleSystem {
        try JSONDecoder().decode(WEParticleSystem.self,
                                 from: Fixtures.data("Scenes/particle-children/particles/\(name).json"))
    }

    // MARK: - Format

    func testChildrenDecodeWithTheirLinkFields() throws {
        let rocket = try particleSystem("rocket")
        let children = try XCTUnwrap(rocket.children)
        XCTAssertEqual(children.map(\.type), [nil, "eventfollow", "eventspawn", "eventdeath"])
        XCTAssertEqual(children.map(\.name), ["particles/glow.json", "particles/trail.json",
                                              "particles/spark.json", "particles/burst.json"])
        XCTAssertEqual(children[0].origin?.vectorValue.1, 100)
        XCTAssertEqual(children[0].scale?.vectorValue.0, 2)
        XCTAssertEqual(children[0].angles?.vectorValue.2, 0.5)
        XCTAssertEqual(children[1].maxcount, 4)
        XCTAssertEqual(children[1].probability, 0.5)
        XCTAssertEqual(children[2].flags, 1)
        XCTAssertEqual(children[2].controlpointstartindex, 2)
        XCTAssertFalse(rocket.isWorldSpace)
    }

    func testEmitterBurstShapeAndSystemFlagsDecode() throws {
        let burst = try particleSystem("burst")
        XCTAssertTrue(burst.isWorldSpace)
        let emitter = try XCTUnwrap(burst.emitter?.first)
        XCTAssertEqual(emitter.instantaneous, 20)
        XCTAssertEqual(emitter.speedmin, 200)
        XCTAssertEqual(emitter.speedmax, 300)
        XCTAssertEqual(emitter.directions?.vectorValue.0, 1)
        XCTAssertEqual(emitter.directions?.vectorValue.2, 0)
        XCTAssertEqual(burst.operator?.first?.flags, 1, "movement: gravity in world space")
        XCTAssertEqual(burst.children?.count, 1, "children nest")
    }

    func testNullAndMissingLinkFieldsDecode() throws {
        let json = #"""
        {"children": [{"angles": "0 0 0", "controlpointstartindex": null, "flags": null, "id": 13,
                       "maxcount": 10, "name": "particles/a.json", "origin": "0 0 0", "probability": 1.0,
                       "scale": "1 1 1", "type": "static"},
                      {"name": "particles/b.json"}]}
        """#
        let system = try JSONDecoder().decode(WEParticleSystem.self, from: Data(json.utf8))
        XCTAssertEqual(system.children?.count, 2)
        XCTAssertNil(system.children?[0].controlpointstartindex)
        XCTAssertNil(system.children?[1].type)
    }
}
