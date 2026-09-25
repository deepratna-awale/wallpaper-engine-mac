import XCTest
@testable import OpenWallpaperEngine

/// An image layer draws its .tex image, not the padding of the allocation around it.
final class TexContentCropTests: XCTestCase {
    func testPaddedAllocationIsCroppedToTheImage() {
        let texture = TEXCompressedTexture(format: 0, width: 2048, height: 1024, data: [],
                                           contentWidth: 1920, contentHeight: 1000)
        XCTAssertEqual(SceneMetalRenderer.contentUVExtent(texture), SIMD2(1920.0 / 2048, 1000.0 / 1024))
        XCTAssertEqual(SceneMetalTextureSource.dxt(texture).contentSize, SIMD2(1920, 1000))
    }

    func testUnpaddedOrUnknownContentKeepsTheWholeTexture() {
        let exact = TEXCompressedTexture(format: 0, width: 64, height: 64, data: [], contentWidth: 64, contentHeight: 64)
        XCTAssertEqual(SceneMetalRenderer.contentUVExtent(exact), SIMD2(1, 1))
        let unknown = TEXCompressedTexture(format: 0, width: 64, height: 64, data: [], contentWidth: 0, contentHeight: 0)
        XCTAssertEqual(SceneMetalRenderer.contentUVExtent(unknown), SIMD2(1, 1))
    }
}
