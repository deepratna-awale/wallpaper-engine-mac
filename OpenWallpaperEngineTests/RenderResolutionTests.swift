import XCTest
@testable import OpenWallpaperEngine

/// Settings → Performance → Render Resolution (`GSRenderResolution`): the scene target sized for
/// the displays' pixels, or for their points.
final class RenderResolutionTests: XCTestCase {
    func testDesktopResolutionSizesTheTargetInPoints() {
        let retina = SceneViewport(drawableSize: SIMD2(3840, 2160), pointSize: SIMD2(1920, 1080), cursor: nil, frameRateLimit: 30)
        let plain = SceneViewport(drawableSize: SIMD2(2560, 1440), pointSize: SIMD2(2560, 1440), cursor: nil, frameRateLimit: 30)
        XCTAssertEqual(SceneRenderResolution.drawableSize([retina], resolution: .native), SIMD2(3840, 2160))
        XCTAssertEqual(SceneRenderResolution.drawableSize([retina], resolution: .desktop), SIMD2(1920, 1080))
        XCTAssertEqual(SceneRenderResolution.drawableSize([retina, plain], resolution: .desktop), SIMD2(2560, 1440))
        let unlaid = SceneViewport(drawableSize: SIMD2(800, 600), pointSize: .zero, cursor: nil, frameRateLimit: 30)
        XCTAssertEqual(SceneRenderResolution.drawableSize([unlaid], resolution: .desktop), SIMD2(800, 600))
    }

    func testTheSettingReachesTheRenderer() {
        var settings = GlobalSettings()
        XCTAssertEqual(settings.renderResolution, .native, "the display's pixels by default")
        settings.renderResolution = .desktop
        XCTAssertEqual(SceneRenderSettings(settings).renderResolution, .desktop)
        XCTAssertEqual(SceneRenderSettings().renderResolution, .native)
    }
}
