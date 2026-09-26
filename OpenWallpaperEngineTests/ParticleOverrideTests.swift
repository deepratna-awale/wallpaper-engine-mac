import XCTest
import Metal
import simd
@testable import OpenWallpaperEngine

private struct Properties: SceneValueContext {
    var values: [String: String] = [:]
    var time: Double = 0
    func userProperty(_ name: String) -> String? { values[name] }
    func evaluateScript(_ source: String, properties: SceneScriptProperties, current: ShaderValue) -> ShaderValue? { nil }
}

/// A particle object's `instanceoverride` scales the authored values every frame, so a user
/// property it's bound to takes effect without rebuilding the scene.
final class ParticleOverrideTests: XCTestCase {
    private var texture: MTLTexture!

    override func setUpWithError() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        texture = try XCTUnwrap(device.makeTexture(descriptor: .texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)))
    }

    private func boundOverride() throws -> WEInstanceOverride {
        try JSONDecoder().decode(WEInstanceOverride.self, from: Data(#"""
        {"count": {"user": "amount", "value": 0.5}, "rate": {"user": "amount", "value": 0.5},
         "size": {"user": "flakesize", "value": 2}, "alpha": 0.5, "lifetime": 3, "speed": 2,
         "colorn": {"user": "tint", "value": "1 0.5 0.25"}, "brightness": 2}
        """#.utf8))
    }

    func testBoundOverridesResolveEveryFrame() throws {
        var system = ParticleTestSystem()
        system.emissionRate = 100
        system.maximum = 1000
        var configuration = system.configuration
        configuration.liveOverrides = try boundOverride()
        let runtime = ParticleSystemRuntime(texture: texture, configuration: configuration)
        let defaults = ParticleFrameInputs.advance(runtime, deltaTime: 1 / 60, cursor: .zero, values: Properties())
        XCTAssertEqual(defaults.emissionRate, 50, accuracy: 1e-4)
        XCTAssertEqual(defaults.maximum, 500)
        XCTAssertEqual(defaults.spawnScale, SIMD4(2, 0.5, 3, 2))
        XCTAssertEqual(defaults.colorScale, SIMD3(2, 1, 0.5))
        let changed = ParticleFrameInputs.advance(runtime, deltaTime: 1 / 60, cursor: .zero, values: Properties(values: [
            "amount": "0.25", "flakesize": "4", "tint": "0 1 0"]))
        XCTAssertEqual(changed.emissionRate, 25, accuracy: 1e-4)
        XCTAssertEqual(changed.maximum, 250)
        XCTAssertEqual(changed.spawnScale.x, 4)
        XCTAssertEqual(changed.colorScale, SIMD3(0, 2, 0))
    }

    func testControlPointOverridesPlaceControlPoints() throws {
        let json = "{\"controlpoint1\": \"-3382.5 384 0\", \"controlpoint2\": {\"user\": \"spot\", \"value\": \"10 20 0\"}}"
        let override = try JSONDecoder().decode(WEInstanceOverride.self, from: Data(json.utf8))
        let defaults = SceneParticleOverrides(override, in: Properties())
        XCTAssertEqual(defaults.controlPoints, [1: SIMD3(-3382.5, 384, 0), 2: SIMD3(10, 20, 0)])
        let bound = SceneParticleOverrides(override, in: Properties(values: ["spot": "5 6 0"]))
        XCTAssertEqual(bound.controlPoints[2], SIMD3(5, 6, 0))
    }

    func testAChildThatKeepsItsColoursSkipsTheTint() throws {
        var configuration = ParticleTestSystem().configuration
        configuration.overrides = SceneParticleOverrides(try boundOverride(), in: Properties())
        configuration.keepsOwnColors = true
        let runtime = ParticleSystemRuntime(texture: texture, configuration: configuration)
        let inputs = ParticleFrameInputs.advance(runtime, deltaTime: 1 / 60, cursor: .zero, values: Properties())
        XCTAssertEqual(inputs.colorScale, SIMD3(repeating: 1))
        XCTAssertEqual(inputs.spawnScale.x, 2, "the other overrides still apply")
    }

    func testOverriddenSpawnsMatchOnTheGPU() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let simulator = try ParticleGPUSimulator(device: device)
        var system = ParticleTestSystem()
        system.emissionRate = 3000
        var configuration = system.configuration
        configuration.overrides = SceneParticleOverrides(try boundOverride(), in: Properties())
        let cpu = ParticleSystemRuntime(texture: texture, configuration: configuration, seed: 5)
        let gpu = ParticleSystemRuntime(texture: texture, configuration: configuration, seed: 5)
        var last: MTLCommandBuffer?
        for _ in 0..<60 {
            ParticleCPUSimulation.step(cpu, inputs: ParticleFrameInputs.advance(cpu, deltaTime: 1 / 60, cursor: .zero,
                                                                                values: Properties()))
            let inputs = ParticleFrameInputs.advance(gpu, deltaTime: 1 / 60, cursor: .zero, values: Properties())
            let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
            simulator.encode([.init(system: gpu, inputs: inputs, kind: .sprite, materialVertexCount: 6)],
                             sceneSize: SIMD2(1280, 720), targetSize: SIMD2(1280, 720), commandBuffer: commandBuffer)
            commandBuffer.commit()
            last = commandBuffer
        }
        last?.waitUntilCompleted()
        let states = simulator.snapshot(gpu, queue: queue)
        XCTAssertEqual(states.count, cpu.particles.count)
        XCTAssertEqual(cpu.particles.count, 500, "the count override halves the maximum")
        for (state, particle) in zip(states, cpu.particles) {
            XCTAssertEqual(state.life.z, particle.size, accuracy: 1e-3)
            XCTAssertEqual(state.life.y, particle.lifetime, accuracy: 1e-4)
            XCTAssertLessThan(simd_distance(state.color, particle.color), 1e-4)
            XCTAssertLessThan(simd_distance(SIMD2(state.positionVelocity.z, state.positionVelocity.w), particle.velocity), 1e-2)
        }
        let sizes = cpu.particles.map(\.size)
        // WE's base size is 0.5, which `sizerandom` multiplies (wallpaper64.exe 0x14023b340).
        XCTAssertGreaterThanOrEqual(sizes.min() ?? 0, 10, "authored 10…20 on the base 0.5, doubled")
    }
}
