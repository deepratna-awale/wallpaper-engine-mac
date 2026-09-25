import XCTest
import Metal
import simd
@testable import OpenWallpaperEngine

final class ParticleCPUSimulationTests: XCTestCase {
    private var texture: MTLTexture!

    override func setUpWithError() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        texture = try XCTUnwrap(device.makeTexture(descriptor: .texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)))
    }

    private func run(_ system: ParticleTestSystem, seed: UInt32, frames: Int = 60) -> ParticleSystemRuntime {
        let runtime = ParticleSystemRuntime(texture: texture, configuration: system.configuration, seed: seed)
        for _ in 0..<frames {
            ParticleCPUSimulation.update([runtime], deltaTime: 1 / 60, cursor: SIMD2(100, 100))
        }
        return runtime
    }

    func testTheSameSeedReplaysTheSameParticles() {
        var system = ParticleTestSystem()
        system.turbulence = Turbulence(scale: 0.01, speed: 100...300, timeScale: 1, phase: 0, mask: SIMD2(1, 1))
        let first = run(system, seed: 7), second = run(system, seed: 7), other = run(system, seed: 8)
        XCTAssertGreaterThan(first.particles.count, 100)
        XCTAssertEqual(first.particles.map(\.position), second.particles.map(\.position))
        XCTAssertEqual(first.particles.map(\.color), second.particles.map(\.color))
        XCTAssertNotEqual(first.particles.map(\.position), other.particles.map(\.position))
    }

    func testRandomDrawsAreUniformAndStayInRange() {
        var sum: Float = 0
        for serial in UInt32(0)..<10_000 {
            let value = ParticleRandom.value(2, 4, seed: 3, serial: serial, .size)
            XCTAssertTrue((2..<4).contains(value))
            sum += value
        }
        XCTAssertEqual(sum / 10_000, 3, accuracy: 0.03)
        XCTAssertEqual(ParticleRandom.value(5, 1, seed: 0, serial: 0, .size) <= 5, true, "reversed bounds don't trap")
    }

    func testEmissionFillsTheAuthoredMaximumAndNoMore() {
        var system = ParticleTestSystem()
        system.emissionRate = 100_000
        system.maximum = 25_000
        system.lifetime = 100...100
        let runtime = run(system, seed: 1, frames: 30)
        XCTAssertEqual(runtime.particles.count, 25_000)
    }

    func testBoidsSteerLargeSystems() {
        // Boids used to switch off above 1 500 particles.
        var system = ParticleTestSystem()
        system.emissionRate = 200_000
        system.maximum = 3_000
        system.lifetime = 100...100
        system.minimumVelocity = SIMD2(-50, -50)
        system.maximumVelocity = SIMD2(50, 50)
        let plain = run(system, seed: 2, frames: 10)
        system.boids = ParticleBoids(alignment: 5, cohesion: 5, separation: 0, threshold: 500)
        let flocking = run(system, seed: 2, frames: 10)
        XCTAssertEqual(flocking.particles.count, 3_000)
        func spread(_ runtime: ParticleSystemRuntime) -> Float {
            let mean = runtime.particles.reduce(SIMD2<Float>.zero) { $0 + $1.velocity } / Float(runtime.particles.count)
            return runtime.particles.reduce(0) { $0 + simd_length($1.velocity - mean) } / Float(runtime.particles.count)
        }
        XCTAssertLessThan(spread(flocking), spread(plain) * 0.8, "alignment pulls velocities together")
    }
}
