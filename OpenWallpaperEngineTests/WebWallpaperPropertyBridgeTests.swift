import XCTest
@testable import OpenWallpaperEngine

final class WebWallpaperPropertyBridgeTests: XCTestCase {
    private let project: [String: Any] = [
        "general": ["properties": [
            "schemecolor": ["type": "color", "value": "0.5 0.25 1"],
            "showclock": ["type": "bool", "value": true],
            "speed": ["type": "slider", "value": 3, "min": 0, "max": 10],
            "mode": ["type": "combo", "options": [["label": "A", "value": "a"], ["label": "B", "value": "b"]]],
            "notice": ["text": "<b>hi</b>"],
            "header": ["type": "text", "text": "Header"]
        ]]
    ]

    func testDeclaredPropertiesSkipNoticeRows() {
        let properties = WebWallpaperPropertyBridge.declaredProperties(projectRoot: project)
        XCTAssertEqual(Set(properties.keys), ["schemecolor", "showclock", "speed", "mode"])
        XCTAssertEqual(properties["mode"]?.defaultValue, "a")
        XCTAssertEqual(properties["showclock"]?.defaultValue, "true")
    }

    func testPayloadTypes() throws {
        let properties = WebWallpaperPropertyBridge.declaredProperties(projectRoot: project)
        let values = WebWallpaperPropertyBridge.currentValues(properties: properties, stored: ["speed": "2.5", "junk": "x"])
        let payload = WebWallpaperPropertyBridge.payload(properties: properties, values: values)
        XCTAssertEqual((payload["schemecolor"] as? [String: Any])?["value"] as? String, "0.5 0.25 1")
        XCTAssertEqual((payload["showclock"] as? [String: Any])?["value"] as? Bool, true)
        XCTAssertEqual((payload["speed"] as? [String: Any])?["value"] as? Double, 2.5)
        XCTAssertEqual((payload["mode"] as? [String: Any])?["value"] as? String, "a")
        XCTAssertNil(payload["junk"])
    }

    func testApplyScriptContainsJSON() throws {
        let script = try XCTUnwrap(WebWallpaperPropertyBridge.applyUserPropertiesScript(
            ["showclock": ["type": "bool", "value": false]]))
        XCTAssertTrue(script.contains("applyUserProperties({\"showclock\":{\"type\":\"bool\",\"value\":false}})"))
        XCTAssertNil(WebWallpaperPropertyBridge.applyUserPropertiesScript([:]))
    }

    func testIntegerSliderIsWholeNumber() {
        let value = WebWallpaperPropertyBridge.jsonValue(type: "slider", value: "30") as? NSNumber
        XCTAssertEqual(value?.stringValue, "30")
    }

    func testAudioArrayIs128Clamped() {
        let samples = WebWallpaperPropertyBridge.audioArray(left: [2, 0.5], right: [-1])
        XCTAssertEqual(samples.count, 128)
        XCTAssertEqual(samples[0], 1)
        XCTAssertEqual(samples[1], 0.5)
        XCTAssertEqual(samples[64], 0)
        XCTAssertTrue(WebWallpaperPropertyBridge.audioDeliveryScript(samples).hasPrefix("window.__oweDeliverAudio"))
    }
}
