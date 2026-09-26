import JavaScriptCore
import XCTest
@testable import OpenWallpaperEngine

/// The object-model bugs the corpus replay found (docs/scenescript-replay-findings.md): RF1, asset
/// paths under the script's Workshop item.
final class SceneScriptReplayFindingTests: XCTestCase {
    private func objectFixture(_ objects: [SceneScriptObjectDescription]) throws -> (FakeSceneScriptObjectHost, SceneScriptRuntime) {
        let host = FakeSceneScriptObjectHost(scene: SceneScriptSceneDescription(objects: objects)) { source in
            .make(.image, id: 100, name: "\(source)")
        }
        let runtime = try SceneScriptRuntime(host: TestSceneScriptHost(), compiler: SceneScriptModuleTransformer(),
                                             extensions: [SceneScriptObjectModel(host: host)])
        return (host, runtime)
    }

    // MARK: - RF1

    func testCreateLayerCarriesTheScriptsWorkshopID() throws {
        let (host, runtime) = try objectFixture([.make(.image, id: 1, name: "Bar")])
        runtime.add(SceneScriptInstance(id: "with", source: """
            'use strict';
            const handle = engine.registerAsset('models/handle.json');
            export let __workshopId = '2935714170';
            export function init() {
                thisScene.createLayer('models/bar.json');
                thisScene.createLayer(handle);
            }
            """, objectSlot: 0))
        runtime.add(SceneScriptInstance(id: "without", source: """
            export function init() { thisScene.createLayer('models/bar.json'); }
            """, objectSlot: 0))
        runtime.load()
        XCTAssertEqual(host.described, [
            .asset("models/bar.json", workshopID: "2935714170"),
            .asset("models/handle.json", workshopID: "2935714170"),
            .asset("models/bar.json", workshopID: nil),
        ])
    }

    func testAssetPathsTryTheWorkshopItemFirst() {
        XCTAssertEqual(SceneScriptLayerSource.assetPaths("models/bar.json", workshopID: "2935714170"),
                       ["models/workshop/2935714170/bar.json", "models/bar.json"])
        XCTAssertEqual(SceneScriptLayerSource.assetPaths("models/bar.json", workshopID: nil), ["models/bar.json"])
        XCTAssertEqual(SceneScriptLayerSource.assetPaths("bar.json", workshopID: "1"), ["bar.json"])
    }
}
