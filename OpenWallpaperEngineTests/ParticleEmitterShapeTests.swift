import XCTest
import Metal
import simd
@testable import OpenWallpaperEngine

/// The emitter's `instantaneous` burst and its shape: speed out from the centre, inner radius and
/// sign.
final class ParticleEmitterShapeTests: XCTestCase {
    private func runtime(_ system: ParticleTestSystem) throws -> ParticleSystemRuntime {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let texture = try XCTUnwrap(device.makeTexture(descriptor: .texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)))
        return ParticleSystemRuntime(texture: texture, configuration: system.configuration, seed: 9)
    }

    func testABurstSpawnsOnceWhenTheSystemStarts() throws {
        var system = ParticleTestSystem()
        system.emissionRate = 0
        system.instantaneous = 40
        system.lifetime = 10...10
        let runtime = try runtime(system)
        ParticleCPUSimulation.update([runtime], deltaTime: 1 / 60, cursor: .zero)
        XCTAssertEqual(runtime.particles.count, 40, "a rate of 0 with a burst is not an idle system")
        for _ in 0..<30 { ParticleCPUSimulation.update([runtime], deltaTime: 1 / 60, cursor: .zero) }
        XCTAssertEqual(runtime.particles.count, 40, "no second burst")
    }

    func testABurstRespectsTheMaximum() throws {
        var system = ParticleTestSystem()
        system.instantaneous = 40
        system.maximum = 25
        let runtime = try runtime(system)
        ParticleCPUSimulation.update([runtime], deltaTime: 1 / 60, cursor: .zero)
        XCTAssertEqual(runtime.particles.count, 25)
    }

    func testEmitterSpeedPushesOutwardFromTheRing() throws {
        var system = ParticleTestSystem()
        system.emissionRate = 0
        system.instantaneous = 200
        system.minimumVelocity = .zero
        system.maximumVelocity = .zero
        system.spawnExtent = SIMD2(40, 40)
        system.minimumSpawnRatio = 0.5
        system.emitterSpeed = 100...100
        system.emitterSign = SIMD2(0, 1)
        let runtime = try runtime(system)
        let inputs = ParticleFrameInputs.advance(runtime, deltaTime: 0, cursor: .zero)
        ParticleCPUSimulation.step(runtime, inputs: inputs)
        XCTAssertEqual(runtime.particles.count, 200)
        for particle in runtime.particles {
            let offset = particle.position - system.origin
            XCTAssertGreaterThanOrEqual(simd_length(offset), 20 - 1e-3, "inside the inner radius")
            XCTAssertLessThanOrEqual(simd_length(offset), 40 + 1e-3)
            XCTAssertGreaterThanOrEqual(offset.y, 0, "sign forces y positive")
            XCTAssertEqual(simd_length(particle.velocity), 100, accuracy: 1e-2)
            XCTAssertGreaterThan(simd_dot(simd_normalize(particle.velocity), simd_normalize(offset)), 0.999)
        }
    }
}
