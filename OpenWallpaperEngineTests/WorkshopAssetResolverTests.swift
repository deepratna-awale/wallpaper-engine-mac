import XCTest
@testable import OpenWallpaperEngine

final class WorkshopAssetResolverTests: XCTestCase {
    private let library = Fixtures.url("Workshop/library")
    private let assets = Fixtures.url("Workshop/assets")

    private var resolver: WorkshopAssetResolver {
        WorkshopAssetResolver(roots: [FileManager.default.temporaryDirectory.appending(path: "owe-missing-root"), library])
    }

    func testParsesWorkshopReference() throws {
        let reference = try XCTUnwrap(WorkshopAssetResolver.reference(in: "fonts\\workshop\\2981960200\\Quicksand-Bold.otf"))
        XCTAssertEqual(reference.category, "fonts")
        XCTAssertEqual(reference.workshopId, "2981960200")
        XCTAssertEqual(reference.remainder, "Quicksand-Bold.otf")
        XCTAssertEqual(reference.candidatePaths.first, "fonts/Quicksand-Bold.otf")
        XCTAssertNil(WorkshopAssetResolver.reference(in: "fonts/Atami-Regular.otf"))
        XCTAssertNil(WorkshopAssetResolver.reference(in: "fonts/myworkshop/2981960200/x.ttf"))
    }

    func testResolvesInsideTheItemFolderOfAnyRoot() throws {
        let url = try XCTUnwrap(resolver.url(for: "fonts/workshop/2981960200/x.ttf"))
        XCTAssertEqual(url.standardizedFileURL, library.appending(path: "2981960200/fonts/x.ttf").standardizedFileURL)
        XCTAssertEqual(resolver.data(for: "fonts/workshop/2981960200/x.ttf"), Data("workshop-font".utf8))
        XCTAssertNil(resolver.url(for: "fonts/workshop/2981960200/missing.ttf"))
        XCTAssertNil(resolver.url(for: "fonts/workshop/9999999999/x.ttf"))
        XCTAssertTrue(resolver.isInstalled("1111111111"))
        XCTAssertFalse(resolver.isInstalled("9999999999"))
    }

    func testSteamWorkshopFolderIsDerivedFromTheInstall() {
        let assets = URL(fileURLWithPath: "/x/Steam/steamapps/common/wallpaper_engine/assets")
        XCTAssertEqual(WorkshopAssetResolver.steamWorkshopContentDirectory(assetsDirectory: assets)?.path,
                       "/x/Steam/steamapps/workshop/content/431960")
        XCTAssertNil(WorkshopAssetResolver.steamWorkshopContentDirectory(assetsDirectory: URL(fileURLWithPath: "/opt/assets")))
    }

    func testScansSceneMaterialsAndProjectDependency() {
        let ids = WorkshopDependencyResolver.referencedWorkshopIds(inItemAt: Fixtures.url("Workshop/wallpaper"))
        XCTAssertEqual(ids, ["2981960200", "3333333333", "4444444444"])
    }

    // MARK: - Fonts

    private func fontResolver(own: [String: Data] = [:], families: [String] = []) -> SceneFontResolver {
        var resolver = SceneFontResolver(wallpaperData: { own[$0] }, assetDirectories: [assets], workshop: resolver)
        resolver.availableFamilies = { families }
        return resolver
    }

    func testWallpaperFontWinsOverWEAssets() {
        let resolution = fontResolver(own: ["fonts/Own.otf": Data("own".utf8)]).resolve("fonts/Own.otf")
        XCTAssertEqual(resolution, .data(Data("own".utf8), .wallpaper))
    }

    func testFallsBackToWEAssets() {
        XCTAssertEqual(fontResolver().resolve("fonts/Atami-Regular.otf"), .data(Data("assets-font".utf8), .weAssets))
    }

    func testWorkshopFontComesFromTheItem() {
        XCTAssertEqual(fontResolver().resolve("fonts/workshop/2981960200/x.ttf"), .data(Data("workshop-font".utf8), .workshop))
    }

    func testSystemFontsMapToInstalledFamilies() {
        let resolver = fontResolver(families: ["Arial", "Times New Roman", "Helvetica Neue"])
        XCTAssertEqual(resolver.resolve("systemfont_arial"), .system("Arial"))
        XCTAssertEqual(resolver.resolve("systemfont_timesnewroman"), .system("Times New Roman"))
        XCTAssertEqual(resolver.resolve("systemfont_segoeui"), .system("Helvetica Neue"))
        XCTAssertNil(resolver.resolve("systemfont_wingdings"))
    }

    func testMissingFontResolvesToNothing() {
        XCTAssertNil(fontResolver().resolve("fonts/Nope.otf"))
    }
}
