import XCTest
@testable import OpenWallpaperEngine

/// Particle systems as the scene loader builds them for their WE material.
final class ParticleMaterialLoadingTests: XCTestCase {
    private func content(_ fixture: String) throws -> SceneMetalContent {
        let directory = Fixtures.url("Scenes/\(fixture)")
        let project = try JSONDecoder().decode(WEProject.self, from: Fixtures.data("Scenes/\(fixture)/project.json"))
        let wallpaper = WEWallpaper(using: project, where: directory)
        addTeardownBlock {
            Fixtures.removeStoredSettings(for: directory)
        }
        return try XCTUnwrap(SceneWallpaperViewModel(wallpaper: wallpaper).metalContent())
    }

    /// The built-in draw's refraction look-alike (sprites faded to the refract amount, drawn
    /// thin) stays off a system that refracts through WE's shader, which uses its own alpha.
    func testRefractingMaterialKeepsTheParticlesOwnAlpha() throws {
        let system = try XCTUnwrap(try content("particle-refraction").particleSystems.first)
        let plan = try XCTUnwrap(system.material, "drawn through its WE material")
        XCTAssertTrue(plan.stages.allSatisfy(\.readsSceneSnapshot))
        XCTAssertEqual(plan.stages.first?.variant.combos["NORMALMAP"], 1, "WE's drop_normal is bound")
        XCTAssertEqual(system.opacityMultiplier, 1)
        XCTAssertFalse(system.refractive)
    }
}
