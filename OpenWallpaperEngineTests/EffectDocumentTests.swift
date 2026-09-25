import XCTest
@testable import OpenWallpaperEngine

final class EffectDocumentTests: XCTestCase {
    /// Local Wallpaper Engine install and library; CI has neither, so those tests skip.
    private static let assetsRoot = ShaderVariantTests.weAssets
    private static let libraryRoot = URL(fileURLWithPath: "/Volumes/980Pro/OpenWallpaperStorage", isDirectory: true)

    private func directories(in url: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [] // optional: absent dir = none
        return names.sorted().map { url.appending(path: $0, directoryHint: .isDirectory) }
            .filter { var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDir) && isDir.boolValue }
    }

    private func firstExisting(_ candidates: [URL]) -> URL? {
        candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Decodes an effect and every material it references; returns (effects, materials) decoded.
    @discardableResult
    private func decodeEffect(at effectDir: URL, searchRoots: [URL], failures: DecodeFailureLog,
                              requireMaterials: Bool) throws -> (EffectDocument, Int) {
        let effectURL = effectDir.appending(path: "effect.json")
        let effect = try decodeTolerant(EffectDocument.self, from: Data(contentsOf: effectURL), failures: failures)
        XCTAssertFalse(effect.passes.isEmpty, "\(effectURL.path) has no passes")
        var materials = 0
        for material in effect.passes.compactMap(\.material) {
            let candidates = ([effectDir] + searchRoots).map { $0.appending(path: material) }
            guard let url = firstExisting(candidates) else {
                if requireMaterials { XCTFail("\(effectURL.path): material \(material) not found") }
                continue
            }
            let document = try decodeTolerant(MaterialDocument.self, from: Data(contentsOf: url), failures: failures)
            XCTAssertFalse(document.passes.isEmpty, "\(url.path) has no passes")
            materials += 1
        }
        return (effect, materials)
    }

    func testDecodesEveryBuiltInEffectAndMaterial() throws {
        let effectsRoot = Self.assetsRoot.appending(path: "effects", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: effectsRoot.path) else {
            throw XCTSkip("Wallpaper Engine assets not installed")
        }
        let failures = DecodeFailureLog()
        var effects = 0, materials = 0
        for dir in directories(in: effectsRoot) where FileManager.default.fileExists(atPath: dir.appending(path: "effect.json").path) {
            let (_, count) = try decodeEffect(at: dir, searchRoots: [Self.assetsRoot], failures: failures, requireMaterials: true)
            effects += 1
            materials += count
        }
        XCTAssertEqual(effects, 46)
        XCTAssertGreaterThan(materials, effects)
        XCTAssertEqual(failures.messages, [])
    }

    func testDecodesEveryWorkshopEffectInTheLibrary() throws {
        guard FileManager.default.fileExists(atPath: Self.libraryRoot.path) else {
            throw XCTSkip("wallpaper library not present")
        }
        let failures = DecodeFailureLog()
        var effects = 0
        for wallpaper in directories(in: Self.libraryRoot) {
            let workshop = wallpaper.appending(path: "effects/workshop", directoryHint: .isDirectory)
            for item in directories(in: workshop) {
                for dir in directories(in: item) where FileManager.default.fileExists(atPath: dir.appending(path: "effect.json").path) {
                    try decodeEffect(at: dir, searchRoots: [wallpaper, Self.assetsRoot], failures: failures, requireMaterials: false)
                    effects += 1
                }
            }
        }
        if effects == 0 { throw XCTSkip("no workshop effects in the library") }
        XCTAssertEqual(failures.messages, [])
    }

    func testEffectSkipsOnlyBadElements() throws {
        let failures = DecodeFailureLog()
        let effect = try decodeTolerant(EffectDocument.self,
                                        from: Fixtures.data("Effects/partly-broken-effect.json"), failures: failures)
        XCTAssertEqual(effect.version, 1)
        XCTAssertEqual(effect.dependencies, ["materials/effects/a.json"])
        XCTAssertEqual(effect.passes.count, 2)
        XCTAssertEqual(effect.passes[0].material, "materials/effects/a.json")
        XCTAssertEqual(effect.passes[0].bind.map(\.name), ["previous"])
        XCTAssertEqual(effect.passes[0].conditions, [["MODE": 1]])
        XCTAssertEqual(effect.passes[1].commandKind, .copy)
        XCTAssertEqual(effect.passes[1].source, "_rt_A")
        XCTAssertEqual(effect.fbos.map(\.name), ["_rt_A", "_rt_B"])
        XCTAssertEqual(effect.fbos.map(\.scale), [2, 1])
        XCTAssertEqual(effect.fbos[1].fit, 512)
        // dependency 5, pass "not a pass", bind without name, fbo without format
        XCTAssertEqual(failures.messages.count, 4, failures.messages.joined(separator: "\n"))
    }

    func testMaterialKeepsNullTexturesAndEveryValueForm() throws {
        let failures = DecodeFailureLog()
        let material = try decodeTolerant(MaterialDocument.self,
                                          from: Fixtures.data("Effects/partly-broken-material.json"), failures: failures)
        XCTAssertEqual(material.passes.count, 1)
        let pass = material.passes[0]
        XCTAssertEqual(pass.shader, "effects/a")
        XCTAssertEqual(pass.textures, [nil, "util/noise", nil])
        XCTAssertEqual(pass.combos, ["MODE": 1])
        XCTAssertEqual(pass.usershadervalues, ["tint": "schemecolor"])
        let values = pass.constantshadervalues
        XCTAssertEqual(values["strength"], .number(0.5))
        XCTAssertEqual(values["color"], .string("1 0 0"))
        XCTAssertEqual(values["bound"], .object(.init(value: .number(3), userName: "prop", userCondition: "2")))
        guard case .object(let scripted)? = values["scripted"] else { return XCTFail("scripted") }
        XCTAssertEqual(scripted.value, .string("0 0"))
        XCTAssertEqual(scripted.scriptProperties, ["speed": .number(2)])
        XCTAssertNotNil(scripted.script)
        guard case .object(let animated)? = values["animated"] else { return XCTFail("animated") }
        XCTAssertEqual(animated.value, .number(1))
        XCTAssertNotNil(animated.animation)
        XCTAssertNil(values["bad"])
        // combo BAD, constant bad, pass without shader
        XCTAssertEqual(failures.messages.count, 3, failures.messages.joined(separator: "\n"))
    }
}
