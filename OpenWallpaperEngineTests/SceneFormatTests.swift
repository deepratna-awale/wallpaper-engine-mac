import XCTest
@testable import OpenWallpaperEngine

final class SceneFormatTests: XCTestCase {
    private func loadScene() throws -> WEScene {
        try JSONDecoder().decode(WEScene.self, from: Fixtures.data("Scenes/layers/scene.json"))
    }

    func testDecodesEveryObjectKind() throws {
        let scene = try loadScene()
        XCTAssertEqual(scene.objects.map(\.id), [1, 2, 3])
        XCTAssertEqual(scene.objects[0].textValue, "Hello")
        XCTAssertEqual(scene.objects[1].image, "models/util/solidlayer.json")
        XCTAssertEqual(scene.general.orthogonalprojection?.width, 1920)
    }

    func testUserBoundVisibilityKeepsPropertyAndDefault() throws {
        let title = try loadScene().objects[0]
        XCTAssertEqual(title.visibleUserProperty, "showtitle")
        XCTAssertEqual(title.visible, true)
    }

    func testOneMalformedEffectDoesNotDropItsSiblings() throws {
        let compose = try loadScene().objects[2]
        XCTAssertEqual(compose.effects?.count, 1)
        XCTAssertEqual(compose.effects?.first?.file, "effects/tint/effect.json")
    }

    func testMultiPassInstanceKeepsEveryPass() throws {
        struct Objects: Decodable { let objects: [WESceneObject] }
        let failures = DecodeFailureLog()
        let scene = try decodeTolerant(Objects.self, from: Fixtures.data("Scenes/multipass/scene.json"),
                                       failures: failures)
        XCTAssertEqual(failures.messages, [])
        let effect = try XCTUnwrap(scene.objects.first?.effects?.first)
        XCTAssertEqual(effect.id, 10)
        XCTAssertEqual(effect.visible, true)
        XCTAssertEqual(effect.visibleUserProperty, "showblur")
        let passes = try XCTUnwrap(effect.passes)
        XCTAssertEqual(passes.count, 3)

        XCTAssertEqual(passes[0].combos, ["KERNEL": 2])
        XCTAssertEqual(passes[0].textures, [nil, "masks/blur_mask"])
        XCTAssertEqual(passes[0].constants["scale"], .string("2 2"))
        XCTAssertEqual(passes[0].constants["strength"],
                       .object(.init(value: .number(0.25), userName: "blurstrength")))
        XCTAssertEqual(passes[0].constantshadervalues?["strength"]?.number, 0.25)

        XCTAssertEqual(passes[1].combos, ["VERTICAL": 1])
        XCTAssertEqual(passes[1].constants["scale"], .number(3))
        XCTAssertEqual(passes[1].usertextures,
                       .array([.null, .object(["name": .string("$mediaThumbnail"), "type": .string("system")])]))

        XCTAssertNil(passes[2].combos)
        XCTAssertEqual(passes[2].constants, [:])
    }

    func testUserPropertyStringsMatchWallpaperEngineForms() {
        XCTAssertEqual(sceneUserPropertyString(true), "true")
        XCTAssertEqual(sceneUserPropertyString(NSNumber(value: 0.5)), "0.5")
        XCTAssertEqual(sceneUserPropertyString("1 0 0"), "1 0 0")
    }

    func testProjectDeclaresUserProperties() throws {
        let data = try Fixtures.data("Scenes/layers/project.json")
        let project = try JSONDecoder().decode(WEProject.self, from: data)
        XCTAssertEqual(project.type, "scene")
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let properties = try XCTUnwrap((raw["general"] as? [String: Any])?["properties"] as? [String: Any])
        XCTAssertEqual(Set(properties.keys), ["showtitle", "tintamount"])
    }
}
