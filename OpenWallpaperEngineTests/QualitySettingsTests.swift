import XCTest
@testable import OpenWallpaperEngine

/// WE's quality settings (post-processing, reflection, shadows, volumetrics; docs/lighting-plan.md
/// §2.2, §2.6) default to what the app has always drawn, and settings saved by an older build keep
/// their values.
final class QualitySettingsTests: XCTestCase {
    func testQualitySettingsDefaultToWhatTheAppDrew() {
        let settings = GlobalSettings()
        XCTAssertEqual(settings.postProcessing, .enabled, "keeps bloom as drawn; WE's own UI default is unknown")
        XCTAssertTrue(settings.reflections)
        XCTAssertEqual(settings.shadows, .medium)
        XCTAssertEqual(settings.volumetrics, .medium)
        XCTAssertEqual(SceneRenderSettings(settings), SceneRenderSettings())
        XCTAssertEqual(GSLightingQuality.allCases.map(\.level), [0, 1, 2, 3, 4])
        XCTAssertTrue(GSPostProcessingQuality.enabled.allowsBloom)
        XCTAssertFalse(GSPostProcessingQuality.disabled.allowsBloom)
    }

    /// Settings saved before the renderer read post-processing and reflection: those two keys are
    /// left behind (they held the inert "disabled" and false), everything else is kept, and a
    /// missing or unreadable key keeps its default instead of resetting every setting.
    func testSettingsSavedBeforeKeepTheirOtherValues() throws {
        let old = #"{"otherApplicationFocused":"pause","antiAliasing":"msaa_x4","postProcessing":"disabled","reflections":false,"fps":45,"videoFramework":"metal","logLevel":"verbose","appearance":"sparkly"}"#
        let settings = try JSONDecoder().decode(GlobalSettings.self, from: Data(old.utf8))
        XCTAssertEqual(settings.otherApplicationFocused, .pause)
        XCTAssertEqual(settings.antiAliasing, .msaa_x4)
        XCTAssertEqual(settings.fps, 45)
        XCTAssertEqual(settings.videoFramework, .metal)
        XCTAssertEqual(settings.logLevel, .verbose)
        XCTAssertEqual(settings.appearance, .followSystem, "an unknown value keeps the default")
        XCTAssertEqual(settings.postProcessing, .enabled)
        XCTAssertTrue(settings.reflections)
    }

    /// The particle budget is stored, read back, reaches the renderer's settings (a change rebuilds
    /// the content), and settings saved before it existed get the default.
    func testParticleBudgetPersists() throws {
        XCTAssertEqual(GlobalSettings().particleBudget, .medium)
        XCTAssertEqual(GSParticleBudget.allCases.map(\.limit), [10_000, 25_000, 50_000, nil])
        var settings = GlobalSettings()
        settings.particleBudget = .low
        let data = try JSONEncoder().encode(settings)
        let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(stored["particleBudget"] as? String, "low")
        let read = try JSONDecoder().decode(GlobalSettings.self, from: data)
        XCTAssertEqual(read.particleBudget, .low)
        XCTAssertEqual(SceneRenderSettings(read).particleBudget, .low)
        XCTAssertNotEqual(SceneRenderSettings(read), SceneRenderSettings(GlobalSettings()))
        let older = try JSONDecoder().decode(GlobalSettings.self, from: Data(#"{"fps":45}"#.utf8))
        XCTAssertEqual(older.particleBudget, .medium)
        let unknown = try JSONDecoder().decode(GlobalSettings.self, from: Data(#"{"particleBudget":"huge"}"#.utf8))
        XCTAssertEqual(unknown.particleBudget, .medium, "an unknown value keeps the default")
    }

    func testSettingsRoundTrip() throws {
        var settings = GlobalSettings()
        settings.postProcessing = .displayhdr
        settings.reflections = false
        settings.shadows = .ultra
        settings.volumetrics = .low
        settings.wallpaperEngineAssetsDirectory = "/tmp/we"
        let data = try JSONEncoder().encode(settings)
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys
        XCTAssertTrue(keys.contains("postProcessingQuality"))
        XCTAssertTrue(keys.contains("reflection"))
        XCTAssertEqual(try JSONDecoder().decode(GlobalSettings.self, from: data), settings)
    }
}
