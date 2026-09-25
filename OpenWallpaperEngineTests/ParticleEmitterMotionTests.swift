import XCTest
import Metal
import simd
@testable import OpenWallpaperEngine

/// Particle systems follow their emitter's live transform: particles in the emitter's space move,
/// turn and scale with it; `worldspace` ones stay where they spawned. And a live parent (moved by
/// its timeline) moves the emitter, and particle systems in turn parent other objects.
final class ParticleEmitterMotionTests: XCTestCase {
    private var texture: MTLTexture!

    override func setUpWithError() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        texture = try XCTUnwrap(device.makeTexture(descriptor: .texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)))
    }

    /// Still particles, so any change of position comes from the emitter.
    private func stillSystem(worldSpace: Bool) -> ParticleSystemRuntime {
        var system = ParticleTestSystem()
        system.origin = SIMD2(100, 100)
        system.minimumVelocity = .zero
        system.maximumVelocity = .zero
        system.lifetime = 50...50
        system.minimumAngularVelocity = 0
        system.maximumAngularVelocity = 0
        system.worldSpace = worldSpace
        return ParticleSystemRuntime(texture: texture, configuration: system.configuration, seed: 3)
    }

    private func step(_ system: ParticleSystemRuntime, emitter: SceneAffineTransform, frames: Int = 1) {
        for _ in 0..<frames {
            ParticleCPUSimulation.step(system, inputs: ParticleFrameInputs.advance(system, deltaTime: 1 / 60,
                                                                                   cursor: .zero, emitter: emitter))
        }
    }

    private func translation(_ point: SIMD2<Float>) -> SceneAffineTransform {
        SceneAffineTransform(linear: matrix_identity_float2x2, translation: point)
    }

    func testLocalParticlesMoveWithTheirEmitter() throws {
        let system = stillSystem(worldSpace: false)
        step(system, emitter: translation(SIMD2(100, 100)), frames: 20)
        let before = system.particles.map(\.position)
        XCTAssertGreaterThan(before.count, 50)
        step(system, emitter: translation(SIMD2(300, 50)))
        for (old, new) in zip(before, system.particles.map(\.position)) {
            XCTAssertLessThan(simd_distance(new - old, SIMD2(200, -50)), 1e-3)
        }
    }

    func testWorldSpaceParticlesStayWhereTheySpawned() throws {
        let system = stillSystem(worldSpace: true)
        step(system, emitter: translation(SIMD2(100, 100)), frames: 20)
        let before = system.particles.map(\.position)
        step(system, emitter: translation(SIMD2(300, 50)))
        XCTAssertEqual(Array(system.particles.map(\.position).prefix(before.count)), before)
        XCTAssertGreaterThan(system.particles.count, before.count)
        let spawned = try XCTUnwrap(system.particles.last)
        XCTAssertLessThan(simd_distance(spawned.position, SIMD2(300, 50)), 60, "new particles spawn at the emitter")
    }

    func testTurningAndScalingTheEmitterTurnsAndScalesItsParticles() throws {
        let system = stillSystem(worldSpace: false)
        step(system, emitter: translation(SIMD2(100, 100)), frames: 20)
        let before = system.particles
        let turned = SceneAffineTransform(SceneLocalTransform(origin: SIMD2(100, 100), scale: SIMD2(2, 2), angle: .pi / 2))
        step(system, emitter: turned)
        for (old, new) in zip(before, system.particles) {
            let expected = turned.apply(old.position - SIMD2(100, 100))
            XCTAssertLessThan(simd_distance(new.position, expected), 1e-3)
            XCTAssertEqual(new.size, old.size * 2, accuracy: 1e-3)
            XCTAssertEqual(new.rotation, old.rotation - .pi / 2, accuracy: 1e-4, "a clockwise quarter turn")
        }
    }

    // MARK: - Live parents

    private func content(_ fixture: String) throws -> SceneMetalContent {
        let directory = Fixtures.url("Scenes/\(fixture)")
        let project = try JSONDecoder().decode(WEProject.self, from: Fixtures.data("Scenes/\(fixture)/project.json"))
        addTeardownBlock {
            for prefix in ["SceneUserProperties.", "SceneUserPropertiesExplicit.", "SceneAdditionalControlsVersion."] {
                UserDefaults.standard.removeObject(forKey: prefix + directory.path)
            }
        }
        return try XCTUnwrap(SceneWallpaperViewModel(wallpaper: WEWallpaper(using: project, where: directory)).metalContent())
    }

    /// The world transform of `id` at `time`, the way the renderer evaluates it for objects that
    /// aren't drawn layers.
    private func world(_ id: String, in content: SceneMetalContent, at time: Float) -> SceneAffineTransform {
        content.transforms.world(of: id) { content.motions[$0]?.local(at: time, stateId: $0) }
    }

    func testEmittersFollowTheirAnimatedParent() throws {
        let content = try content("particle-animated-parent")
        let systems = content.particleSystems
        XCTAssertEqual(systems.map(\.objectID), ["2", "3"])
        XCTAssertEqual(systems.map(\.worldSpace), [false, true])
        XCTAssertNotNil(content.motions["1"], "a group without a layer still moves its children")
        let start = world("2", in: content, at: 0)
        XCTAssertLessThan(simd_distance(start.translation, SIMD2(500, 540)), 1e-3)
        XCTAssertEqual(start, systems[0].authoredWorld)
        // Halfway: the pivot is at (900, 540), turned a clockwise eighth.
        let halfway = world("2", in: content, at: 1)
        let expected = SIMD2<Float>(900, 540) + SIMD2(100, -100) / sqrt(2)
        XCTAssertLessThan(simd_distance(halfway.translation, expected), 1e-2)
    }

    func testParticleSystemsParentOtherObjectsLive() throws {
        let content = try content("particle-animated-parent")
        let marker = try XCTUnwrap(content.layers.first { $0.id == "4" })
        let emitter = world("2", in: content, at: 1)
        let markerWorld = content.transforms.parentWorld(of: marker.id) { content.motions[$0]?.local(at: 1, stateId: $0) }
            * SceneAffineTransform(SceneLocalTransform(origin: marker.position, scale: marker.scale, angle: marker.rotation))
        XCTAssertLessThan(simd_distance(markerWorld.translation, emitter.apply(SIMD2(0, 50))), 1e-2)
    }
}
