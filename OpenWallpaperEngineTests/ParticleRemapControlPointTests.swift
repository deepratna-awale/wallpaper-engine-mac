import XCTest
import Metal
import simd
@testable import OpenWallpaperEngine

/// `remapvalue` and `remapinitialvalue` on control points, as `wallpaper64.exe` runs them
/// (operator outputs 0x140245c9e…0x140246e52, inputs 0x140244e27…0x140244fef; initializer
/// 0x14023d31d…0x14023d546), on both simulations.
final class ParticleRemapControlPointTests: XCTestCase {
    private var device: MTLDevice!
    private var queue: MTLCommandQueue!
    private var simulator: ParticleGPUSimulator!
    private var texture: MTLTexture!

    override func setUpWithError() throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        queue = try XCTUnwrap(device.makeCommandQueue())
        simulator = try ParticleGPUSimulator(device: device)
        texture = try XCTUnwrap(device.makeTexture(descriptor: .texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)))
    }

    private func remapOperator(_ json: String) throws -> ParticleOperator {
        let element = try JSONDecoder().decode(WEParticleOperator.self, from: Data(json.utf8))
        return try XCTUnwrap(ParticleOperatorBuilder.make(element, defaults: ParticleDefaults(pixelUnits: true),
                                                          sceneSize: SIMD2(100, 100), path: "t"))
    }

    private func remapInitializer(_ json: String) throws -> ParticleInitializer {
        let element = try JSONDecoder().decode(WEParticleInitializer.self, from: Data(json.utf8))
        return try XCTUnwrap(ParticleInitializerBuilder.make(element, defaults: ParticleDefaults(pixelUnits: true), path: "t"))
    }

    private func run(_ record: ParticleOperator, position: SIMD2<Float>, points: [Int: SIMD2<Float>]) -> (ParticleProgramState, [SIMD2<Float>]) {
        var state = ParticleProgramState()
        state.position = position
        state.lifetime = 1
        var context = ParticleProgramContext()
        for (index, point) in points { context.controlPoints[index] = point }
        _ = ParticleProgramCPU.runOperators([record.record], on: &state, in: &context, index: 0, neighbors: .init())
        return (state, context.controlPoints)
    }

    /// The operator's vector inputs run from the particle to the point.
    func testDeltaAndDirectionInputsPointAtTheControlPoint() throws {
        let delta = try remapOperator(#"{"name":"remapvalue","input":"deltatocontrolpoint","inputcontrolpoint0":1,"inputcomponent":"x","inputrangemin":"-100 -100 -100","inputrangemax":"100 100 100","outputrangemin":0,"outputrangemax":200,"output":"size","operation":"remap"}"#)
        let moved = run(delta, position: SIMD2(10, 0), points: [1: SIMD2(40, 0)]).0
        XCTAssertEqual(moved.size, 130, accuracy: 1e-3, "point − particle = 30")
        let direction = try remapOperator(#"{"name":"remapvalue","input":"directiontocontrolpoint","inputcontrolpoint0":1,"inputcomponent":"y","inputrangemin":"-1 -1 -1","inputrangemax":"1 1 1","outputrangemin":0,"outputrangemax":2,"output":"size","operation":"remap"}"#)
        XCTAssertEqual(run(direction, position: SIMD2(0, 10), points: [1: .zero]).0.size, 0, accuracy: 1e-5, "straight down")
    }

    /// `distancetocontrolpoint`, `positionbetweentwocontrolpoints`, `deltatocontrolpoint` and
    /// `directiontocontrolpoint` move the particle; `controlpoint` moves the point.
    func testControlPointOutputs() throws {
        let points: [Int: SIMD2<Float>] = [0: SIMD2(0, 0), 1: SIMD2(100, 0)]
        let distance = try remapOperator(#"{"name":"remapvalue","input":"maxlifetime","output":"distancetocontrolpoint","operation":"remap","outputrangemin":0,"outputrangemax":50}"#)
        XCTAssertEqual(run(distance, position: SIMD2(0, 10), points: points).0.position, SIMD2(0, 50))
        let between = try remapOperator(#"{"name":"remapvalue","input":"maxlifetime","output":"positionbetweentwocontrolpoints","operation":"remap","outputrangemin":0.25,"outputrangemax":0.25}"#)
        XCTAssertEqual(run(between, position: SIMD2(80, 7), points: points).0.position, SIMD2(25, 7), "along the line, same offset")
        let delta = try remapOperator(#"{"name":"remapvalue","input":"maxlifetime","output":"deltatocontrolpoint","operation":"multiply","outputrangemin":"0.5 0.5 0.5","outputrangemax":"0.5 0.5 0.5"}"#)
        XCTAssertEqual(run(delta, position: SIMD2(20, 40), points: points).0.position, SIMD2(10, 20), "half the way to point 0")
        let direction = try remapOperator(#"{"name":"remapvalue","input":"maxlifetime","output":"directiontocontrolpoint","operation":"remap","outputrangemin":"1 0 0","outputrangemax":"1 0 0"}"#)
        let turned = run(direction, position: SIMD2(0, 30), points: points).0.position
        XCTAssertLessThan(simd_distance(turned, SIMD2(-30, 0)), 1e-4, "the point now lies along +x at the same distance")
        let point = try remapOperator(#"{"name":"remapvalue","input":"maxlifetime","output":"controlpoint","outputcontrolpoint0":1,"outputcomponent":"y","operation":"add","outputrangemin":5,"outputrangemax":5}"#)
        let written = run(point, position: .zero, points: points)
        XCTAssertEqual(written.1[1], SIMD2(100, 5), "only y")
        let reduced = try remapOperator(#"{"name":"remapvalue","input":"maxlifetime","output":"position","outputcomponent":"sum","operation":"remap","outputrangemin":5,"outputrangemax":5}"#)
        XCTAssertEqual(run(reduced, position: SIMD2(3, 4), points: points).0.position, SIMD2(3, 4), "a reduction writes nothing")
    }

    /// The initializer's control point inputs zero the point first, and read zero.
    func testTheInitializersControlPointInputsZeroThePoint() throws {
        let input = try remapInitializer(#"{"name":"remapinitialvalue","input":"deltatocontrolpoint","inputcontrolpoint0":2,"inputcomponent":"x","inputrangemin":"-100 -100 -100","inputrangemax":"100 100 100","outputrangemin":0,"outputrangemax":200,"output":"size","operation":"remap"}"#)
        var state = ParticleProgramState()
        state.position = SIMD2(30, 0)
        var context = ParticleProgramContext()
        context.controlPoints[2] = SIMD2(500, 500)
        ParticleProgramCPU.runInitializers([input.record], on: &state, in: &context)
        XCTAssertEqual(context.controlPoints[2], .zero)
        XCTAssertEqual(state.baseSize, 70, accuracy: 1e-3, "0 − 30")
    }

    /// The operator writes a control point once per group of four particles, each group adding to
    /// what the last left; the next step starts from the written point.
    func testTheControlPointOutputWritesOncePerFourParticles() throws {
        let add = try remapOperator(#"{"name":"remapvalue","input":"maxlifetime","output":"controlpoint","outputcontrolpoint0":1,"operation":"add","outputrangemin":"0 0 0","outputrangemax":"1 2 0"}"#)
        for (count, groups) in [(8, 2), (9, 3), (3, 1)] {
            var system = ParticleTestSystem()
            system.emissionRate = 0
            system.instantaneous = count
            system.lifetime = 1...1
            system.controlPoints[1] = ParticleTestSystem.point(SIMD2(10, 10))
            system.operators = [add]
            let runtime = ParticleSystemRuntime(texture: texture, configuration: system.configuration, seed: 1)
            ParticleCPUSimulation.step(runtime, inputs: ParticleFrameInputs.advance(runtime, deltaTime: 1 / 60, cursor: .zero))
            XCTAssertEqual(runtime.particles.count, count)
            let written = try XCTUnwrap(runtime.previousControlPoints?[1])
            XCTAssertEqual(written, SIMD2(10, 10) + SIMD2(1, 2) * Float(groups), "\(count) particles")
        }
    }

    /// Both simulations run the writes alike: an operator that writes a point read by the operators
    /// after it, and initializers that zero and write one.
    func testControlPointWritesRunTheSameOnTheGPU() throws {
        var system = ParticleTestSystem()
        system.emissionRate = 300
        system.controlPoints[1] = ParticleTestSystem.point(SIMD2(40, -20))
        system.controlPoints[2] = ParticleTestSystem.point(SIMD2(-60, 30))
        system.initializers = [
            try remapInitializer(#"{"name":"remapinitialvalue","input":"directiontocontrolpoint","inputcontrolpoint0":2,"output":"size","inputcomponent":"x","inputrangemin":"-1 -1 -1","operation":"multiply","outputrangemin":0.5,"outputrangemax":2}"#),
            try remapInitializer(#"{"name":"remapinitialvalue","input":"maxlifetime","output":"controlpoint","outputcontrolpoint0":2,"operation":"add","inputrangemax":"3 3 3","outputrangemin":"0 0 0","outputrangemax":"4 -3 0"}"#),
        ]
        system.operators = [
            try remapOperator(#"{"name":"remapvalue","input":"lifetimefraction","output":"controlpoint","outputcontrolpoint0":1,"operation":"add","outputrangemin":"0 0 0","outputrangemax":"0.5 0.25 0"}"#),
            ParticleOperator(.controlPointAttract, flags: 2, controlPoints: 1, b: SIMD4(300, 400, 5, 0)),
            try remapOperator(#"{"name":"remapvalue","input":"deltatocontrolpoint","inputcontrolpoint0":1,"inputcomponent":"x","inputrangemin":"-500 -500 -500","inputrangemax":"500 500 500","output":"opacity","operation":"multiply"}"#),
        ]
        system.emitterControlPoint = 2
        for frameRateLimit in [60, 15] {
            let cpu = ParticleSystemRuntime(texture: texture, configuration: system.configuration, seed: 7)
            let gpu = ParticleSystemRuntime(texture: texture, configuration: system.configuration, seed: 7)
            var last: MTLCommandBuffer?
            for _ in 0..<60 {
                ParticleCPUSimulation.step(cpu, inputs: ParticleFrameInputs.advance(cpu, deltaTime: 1 / 60, cursor: .zero,
                                                                                    frameRateLimit: frameRateLimit))
                let inputs = ParticleFrameInputs.advance(gpu, deltaTime: 1 / 60, cursor: .zero, frameRateLimit: frameRateLimit)
                let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
                simulator.encode([.init(system: gpu, inputs: inputs, kind: .sprite, materialVertexCount: 6)],
                                 sceneSize: SIMD2(1280, 720), targetSize: SIMD2(1280, 720), commandBuffer: commandBuffer)
                commandBuffer.commit()
                last = commandBuffer
            }
            last?.waitUntilCompleted()
            let states = simulator.snapshot(gpu, queue: queue)
            XCTAssertGreaterThan(cpu.particles.count, 100)
            XCTAssertEqual(states.map(\.identity.x), cpu.particles.map(\.serial), "the same particles, limit \(frameRateLimit)")
            for (state, particle) in zip(states, cpu.particles) {
                XCTAssertLessThan(simd_distance(SIMD2(state.positionVelocity.x, state.positionVelocity.y), particle.position), 0.05,
                                  "limit \(frameRateLimit)")
                XCTAssertEqual(state.life.z, particle.size, accuracy: 1e-3)
                XCTAssertEqual(state.alphaRotation.x, particle.alpha, accuracy: 1e-4)
            }
        }
    }
}
