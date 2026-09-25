import XCTest
import Metal
import simd
@testable import OpenWallpaperEngine

/// The GPU simulation against the CPU one: the same systems, seeds and inputs for many frames,
/// compared by count and by the means of position, size, alpha and colour, one operator at a
/// time. Both draw from the same random streams, so they agree up to float rounding.
final class ParticleSimulationParityTests: XCTestCase {
    private var device: MTLDevice!
    private var queue: MTLCommandQueue!
    private var simulator: ParticleGPUSimulator!
    private var texture: MTLTexture!
    private static let frames = 120
    private static let cursor = SIMD2<Float>(640, 360)

    override func setUpWithError() throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        queue = try XCTUnwrap(device.makeCommandQueue())
        simulator = try ParticleGPUSimulator(device: device)
        texture = try XCTUnwrap(device.makeTexture(descriptor: .texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)))
    }

    // MARK: - Layout

    func testSwiftAndMetalLayoutsAgree() throws {
        let library = try device.makeDefaultLibrary(bundle: Bundle(for: ParticleGPUSimulator.self))
        let function = try XCTUnwrap(library.makeFunction(name: "particleLayoutSizes"))
        let pipeline = try device.makeComputePipelineState(function: function)
        let sizes = try XCTUnwrap(device.makeBuffer(length: 6 * 4, options: .storageModeShared))
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(sizes, offset: 0, index: 0)
        encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let metal = Array(UnsafeBufferPointer(start: sizes.contents().bindMemory(to: UInt32.self, capacity: 6), count: 6)).map(Int.init)
        XCTAssertEqual(metal, [MemoryLayout<ParticleGPUState>.stride, MemoryLayout<ParticleGPUParameters>.stride,
                               MemoryLayout<ParticleGPUFrame>.stride, MemoryLayout<ParticleSpriteInstance>.stride,
                               MemoryLayout<ParticleRopeSegmentInstance>.stride, MemoryLayout<LayerUniform>.stride])
    }

    // MARK: - Parity per initializer and operator

    func testEmissionMovementGravityAndDrag() throws {
        var system = ParticleTestSystem()
        system.gravity = SIMD2(0, -120)
        system.drag = 0.8
        try assertParity(system)
    }

    func testBoxEmitterOffsetsRotationAndMaximumSpeed() throws {
        var system = ParticleTestSystem()
        system.emitterName = "boxrandom"
        system.spawnExtent = SIMD2(300, -80)
        system.positionOffsetMinimum = SIMD2(-20, 5)
        system.positionOffsetMaximum = SIMD2(20, 40)
        system.emitterLinear = simd_float2x2(SIMD2(0, 1), SIMD2(-1, 0))
        system.maximumSpeed = 30
        system.angularAcceleration = 2
        try assertParity(system)
    }

    func testTurbulence() throws {
        var system = ParticleTestSystem()
        system.turbulence = Turbulence(scale: 0.01, speed: 200...600, timeScale: 0.5, phase: 1, mask: SIMD2(1, -1))
        try assertParity(system)
    }

    func testControlPointAttractAndCursorControlPoint() throws {
        var system = ParticleTestSystem()
        system.attractor = Attractor(offset: SIMD2(100, 100), strength: 300, threshold: 400)
        system.cursorControlPoint = CursorControlPoint(id: 1, offset: SIMD2(10, -10))
        system.emitterControlPoint = 1
        try assertParity(system)
    }

    func testVortex() throws {
        var system = ParticleTestSystem()
        system.vortex = ParticleVortex(offset: SIMD2(20, -20), innerSpeed: 400, outerSpeed: 50, innerDistance: 5,
                                       outerDistance: 300)
        try assertParity(system)
    }

    func testBoids() throws {
        var system = ParticleTestSystem()
        system.boids = ParticleBoids(alignment: 0.5, cohesion: 0.3, separation: 20, threshold: 60)
        try assertParity(system, positionTolerance: 3)
    }

    func testControlPointDistanceOperators() throws {
        var system = ParticleTestSystem()
        system.nearControlPointReduction = ParticleDistanceReduction(offset: .zero, innerDistance: 10,
                                                                     outerDistance: 200, reduction: 3)
        system.maintainControlPointDistance = ParticleDistanceConstraint(offset: SIMD2(-50, 20), strength: 0.5)
        try assertParity(system)
    }

    func testSequenceBetweenAndAroundControlPoints() throws {
        var system = ParticleTestSystem()
        system.rendererName = "rope"
        system.controlPoints = [ParticleControlPoint(id: 0, offset: SIMD2(-200, 0), locksToCursor: false),
                                ParticleControlPoint(id: 1, offset: SIMD2(40, 60), locksToCursor: true)]
        system.sequenceSpan = ParticleSequenceSpan(startControlPoint: 0, endControlPoint: 1, count: 16, arcAmount: 0.4,
                                                   mirrored: true)
        system.sequenceRing = ParticleSequenceRing(turns: 2, axis: SIMD2(0, 1), bounds: 0...1,
                                                   minimumSpeed: SIMD2(-5, -5), maximumSpeed: SIMD2(5, 5))
        system.maintainSequenceDistance = true
        system.turbulence = Turbulence(scale: 0.02, speed: 50...80, timeScale: 1, phase: 0, mask: SIMD2(1, 1))
        try assertParity(system, positionTolerance: 3)
    }

    func testInitialRemapOfSizeAlphaAndVelocity() throws {
        for output in [ParticleInitialRemap.Output.size, .alpha, .velocity] {
            var system = ParticleTestSystem()
            system.controlPoints = [ParticleControlPoint(id: 2, offset: SIMD2(30, 0), locksToCursor: false)]
            system.initialRemap = ParticleInitialRemap(controlPoint: 2, rangeMinimum: 5, rangeMaximum: 60,
                                                       multiply: output != .alpha, output: output)
            try assertParity(system, "\(output)")
        }
    }

    func testChangesOverLife() throws {
        var system = ParticleTestSystem()
        system.sizeChange = ParticleChange(startTime: 0.1, endTime: 0.8, startValue: 1, endValue: 3)
        system.alphaChange = ParticleChange(startTime: 0.2, endTime: 1, startValue: 1, endValue: 0)
        system.colorChange = ParticleColorChange(startTime: 0, endTime: 0.5, startValue: SIMD4(1, 0.5, 0.2, 1),
                                                 endValue: SIMD4(0.2, 1, 0.5, 1))
        try assertParity(system)
    }

    func testOscillationsAndAlphaRemap() throws {
        var system = ParticleTestSystem()
        system.oscillateSize = ParticleOscillation(frequency: 2...4, scale: 0.5...1.5, phase: 0...1)
        system.oscillatePosition = ParticleOscillation(frequency: 3...3, scale: 40...60, phase: 0...0)
        system.remapAlpha = ParticleRemap(scale: 2, outputMinimum: 0.2, outputMaximum: 0.9, sine: true)
        try assertParity(system)
        system.remapAlpha = nil
        system.oscillateAlpha = ParticleOscillation(frequency: 5...5, scale: 0.2...0.6, phase: 1...2)
        try assertParity(system, "oscillatealpha")
    }

    func testRopeTrailHistory() throws {
        var system = ParticleTestSystem()
        system.rendererName = "ropetrail"
        system.trailSegments = 6
        system.trailLength = 0.3
        system.gravity = SIMD2(0, -200)
        let (cpu, gpu) = try runBoth(system)
        XCTAssertEqual(cpu.particles.count, gpu.count)
        let states = simulator.snapshot(gpu.runtime, queue: queue)
        for index in stride(from: 0, to: min(cpu.particles.count, states.count), by: 37) {
            let expected = cpu.particles[index].orderedHistory
            let actual = simulator.history(gpu.runtime, particle: states[index], index: index, queue: queue)
            XCTAssertEqual(actual.count, expected.count, "particle \(index)")
            for (a, e) in zip(actual, expected) { XCTAssertLessThan(simd_distance(a, e), 0.05, "particle \(index)") }
        }
    }

    func testSpriteSheetFramesAndFades() throws {
        var system = ParticleTestSystem()
        system.spriteSheet = SpriteSheet(columns: 4, rows: 2, frames: 7, duration: 1)
        system.animationMode = "randomframe"
        let (cpu, gpu) = try runBoth(system)
        let states = simulator.snapshot(gpu.runtime, queue: queue)
        XCTAssertEqual(cpu.particles.map { UInt32($0.spriteFrame) }, states.map(\.identity.y))
        XCTAssertEqual(Set(states.map(\.identity.y)), Set(0..<7))
    }

    func testEmissionHonoursALargeMaximum() throws {
        var system = ParticleTestSystem()
        system.emissionRate = 400_000
        system.maximum = 100_000
        system.lifetime = 50...50
        let (cpu, gpu) = try runBoth(system, frames: 30)
        XCTAssertEqual(cpu.particles.count, 100_000)
        XCTAssertEqual(gpu.count, 100_000)
    }

    func testAClearingFrameDropsEveryParticle() throws {
        let (_, gpu) = try runBoth(ParticleTestSystem(), frames: 30)
        XCTAssertGreaterThan(gpu.count, 0)
        // A zero emission rate (or opacity) clears the system.
        var inputs = ParticleFrameInputs.advance(gpu.runtime, deltaTime: 1 / 60, cursor: Self.cursor)
        inputs.clears = true
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        simulator.encode([.init(system: gpu.runtime, inputs: inputs, kind: .sprite)], sceneSize: SIMD2(1280, 720),
                         targetSize: SIMD2(1280, 720), commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(gpu.count, 0)
    }

    // MARK: - Moving emitters

    /// The emitter moves, turns and grows every frame (an animated parent): particles in its
    /// space follow it on both simulations alike.
    func testParticlesFollowAMovingEmitter() throws {
        var system = ParticleTestSystem()
        system.gravity = SIMD2(0, -80)
        system.rendererName = "ropetrail"
        try assertParity(system, "local", emitter: Self.movingEmitter)
    }

    func testWorldSpaceParticlesIgnoreAMovingEmitter() throws {
        var system = ParticleTestSystem()
        system.worldSpace = true
        system.worldGravity = true
        system.gravity = SIMD2(0, -80)
        try assertParity(system, "world", emitter: Self.movingEmitter)
    }

    private static func movingEmitter(_ frame: Int) -> SceneAffineTransform {
        let t = Float(frame) / 60
        let local = SceneLocalTransform(origin: SIMD2(400 + 200 * t, 500 + 50 * sin(t * 3)),
                                        scale: SIMD2(repeating: 1 + 0.5 * t), angle: t)
        return SceneAffineTransform(local)
    }

    // MARK: - Records

    func testSpriteRecordsMatchTheCPUWriter() throws {
        var system = ParticleTestSystem()
        system.spriteSheet = SpriteSheet(columns: 2, rows: 2, frames: 4, duration: 0.5)
        let (cpu, gpu) = try runBoth(system, kind: .sprite)
        let expected = cpuRecords(cpu, format: .sprite, as: ParticleSpriteInstance.self)
        let actual = simulator.records(gpu.runtime, as: ParticleSpriteInstance.self, queue: queue)
        XCTAssertEqual(actual.records.count, expected.count)
        XCTAssertEqual(Int(actual.material[1]), expected.count, "indirect instance count")
        for (a, e) in zip(actual.records, expected) {
            XCTAssertLessThan(simd_distance(a.position, e.position), 0.05)
            XCTAssertLessThan(simd_distance(a.rotationSize, e.rotationSize), 0.01)
            XCTAssertLessThan(simd_distance(a.color, e.color), 0.005)
            XCTAssertEqual(a.velocityLifetime.w, e.velocityLifetime.w, accuracy: 0.01)
        }
    }

    func testRopeAndRopeTrailRecordsMatchTheCPUWriter() throws {
        for renderer in ["rope", "ropetrail"] {
            var system = ParticleTestSystem()
            system.rendererName = renderer
            system.trailSegments = 5
            let kind = ParticleGPUDrawKind.material(.rope, rendererName: renderer)
            let (cpu, gpu) = try runBoth(system, kind: kind)
            let expected = cpuRecords(cpu, format: .rope, as: ParticleRopeSegmentInstance.self)
            let actual = simulator.records(gpu.runtime, as: ParticleRopeSegmentInstance.self, queue: queue)
            XCTAssertGreaterThan(expected.count, 100, renderer)
            XCTAssertEqual(actual.records.count, expected.count, renderer)
            for (a, e) in zip(actual.records, expected) {
                XCTAssertLessThan(simd_distance(a.start, e.start), 0.05, renderer)
                XCTAssertLessThan(simd_distance(a.end, e.end), 0.05, renderer)
                XCTAssertLessThan(simd_distance(a.previous, e.previous), 0.05, renderer)
                XCTAssertLessThan(simd_distance(a.next, e.next), 0.05, renderer)
                XCTAssertLessThan(simd_distance(a.color, e.color), 0.005, renderer)
            }
        }
    }

    func testBuiltInDrawInstances() throws {
        for (renderer, perParticle) in [("sprite", 1), ("spritetrail", 1), ("rope", 3), ("ropetrail", 3)] {
            var system = ParticleTestSystem()
            system.rendererName = renderer
            system.ropeSubdivision = 3
            system.trailSegments = 4
            let kind = ParticleGPUDrawKind.fallback(rendererName: renderer)
            let (cpu, gpu) = try runBoth(system, kind: kind)
            let actual = simulator.records(gpu.runtime, as: LayerUniform.self, queue: queue)
            let particles = cpu.particles
            let expected: Int
            switch renderer {
            case "rope": expected = (particles.count - 1) * perParticle
            case "ropetrail": expected = particles.reduce(0) { $0 + $1.history.count } * perParticle
            default: expected = particles.count
            }
            XCTAssertEqual(actual.records.count, expected, renderer)
            XCTAssertEqual(actual.fallback[0], 4, "one quad strip per instance")
            let drawn = actual.records.filter { $0.size.x > 0 }
            XCTAssertGreaterThan(drawn.count, expected / 2, renderer)
            // Scene and target are the same size here, so instance positions are scene positions.
            let mean = drawn.reduce(SIMD2<Float>.zero) { $0 + $1.position } / Float(drawn.count)
            let particleMean = particles.reduce(SIMD2<Float>.zero) { $0 + $1.position } / Float(particles.count)
            XCTAssertLessThan(simd_distance(mean, particleMean), 40, renderer)
        }
    }

    // MARK: - Helpers

    private struct GPURun {
        let runtime: ParticleSystemRuntime
        var count: Int { runtime.gpu?.completedCount ?? 0 }
    }

    private func runBoth(_ system: ParticleTestSystem, frames: Int = frames, seed: UInt32 = 42,
                         kind: ParticleGPUDrawKind? = nil,
                         emitter: ((Int) -> SceneAffineTransform)? = nil) throws -> (ParticleSystemRuntime, GPURun) {
        let cpu = ParticleSystemRuntime(texture: texture, configuration: system.configuration, seed: seed)
        let gpu = ParticleSystemRuntime(texture: texture, configuration: system.configuration, seed: seed)
        let kind = kind ?? (system.rendererName == "ropetrail" ? .ropeTrail : .sprite)
        var last: MTLCommandBuffer?
        for frame in 0..<frames {
            let world = emitter?(frame)
            ParticleCPUSimulation.step(cpu, inputs: ParticleFrameInputs.advance(cpu, deltaTime: 1 / 60, cursor: Self.cursor,
                                                                                emitter: world))
            let inputs = ParticleFrameInputs.advance(gpu, deltaTime: 1 / 60, cursor: Self.cursor, emitter: world)
            let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
            simulator.encode([.init(system: gpu, inputs: inputs, kind: kind, materialVertexCount: 6)],
                             sceneSize: SIMD2(1280, 720), targetSize: SIMD2(1280, 720), commandBuffer: commandBuffer)
            commandBuffer.commit()
            last = commandBuffer
        }
        last?.waitUntilCompleted()
        XCTAssertNil(last?.error)
        return (cpu, GPURun(runtime: gpu))
    }

    private struct Statistics {
        var count = 0
        var position = SIMD2<Float>.zero
        var size: Float = 0
        var alpha: Float = 0
        var color = SIMD4<Float>.zero
    }

    private func statistics(_ particles: [Particle]) -> Statistics {
        var result = Statistics(count: particles.count)
        guard !particles.isEmpty else { return result }
        for particle in particles {
            result.position += particle.position
            result.size += particle.size
            result.alpha += particle.alpha
            result.color += particle.color
        }
        let n = Float(particles.count)
        result.position /= n; result.size /= n; result.alpha /= n; result.color /= n
        return result
    }

    private func statistics(_ states: [ParticleGPUState]) -> Statistics {
        var result = Statistics(count: states.count)
        guard !states.isEmpty else { return result }
        for state in states {
            result.position += SIMD2(state.positionVelocity.x, state.positionVelocity.y)
            result.size += state.life.z
            result.alpha += state.alphaRotation.x
            result.color += state.color
        }
        let n = Float(states.count)
        result.position /= n; result.size /= n; result.alpha /= n; result.color /= n
        return result
    }

    private func assertParity(_ system: ParticleTestSystem, _ label: String = "", positionTolerance: Float = 1,
                              emitter: ((Int) -> SceneAffineTransform)? = nil,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        let (cpu, gpu) = try runBoth(system, emitter: emitter)
        let states = simulator.snapshot(gpu.runtime, queue: queue)
        let expected = statistics(cpu.particles), actual = statistics(states)
        XCTAssertGreaterThan(expected.count, 50, label, file: file, line: line)
        XCTAssertEqual(Double(actual.count), Double(expected.count), accuracy: max(2, Double(expected.count) * 0.01),
                       "count \(label)", file: file, line: line)
        XCTAssertLessThan(simd_distance(actual.position, expected.position), positionTolerance,
                          "mean position \(label): \(actual.position) vs \(expected.position)", file: file, line: line)
        XCTAssertEqual(actual.size, expected.size, accuracy: max(0.02 * abs(expected.size), 0.01),
                       "mean size \(label)", file: file, line: line)
        XCTAssertEqual(actual.alpha, expected.alpha, accuracy: 0.01, "mean alpha \(label)", file: file, line: line)
        XCTAssertLessThan(simd_distance(actual.color, expected.color), 0.01, "mean colour \(label)", file: file, line: line)
        // The compaction keeps spawn order, as the CPU's array does.
        let serials = states.map(\.identity.x)
        XCTAssertEqual(serials, serials.sorted(), "spawn order \(label)", file: file, line: line)
        if actual.count == expected.count {
            XCTAssertEqual(serials, cpu.particles.map(\.serial), "the same particles \(label)", file: file, line: line)
        }
    }

    private func cpuRecords<Record>(_ system: ParticleSystemRuntime, format: ParticleVertexFormat,
                                    as type: Record.Type) -> [Record] {
        let count = ParticleRecordWriter.recordCount(system, format: format)
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: max(count, 1) * format.stride, alignment: 16)
        defer { pointer.deallocate() }
        ParticleRecordWriter.write(system, format: format, count: count, into: pointer) { particle in
            let progress = particle.age / particle.lifetime
            let fadeIn = system.fadeIn > 0 ? min(progress / system.fadeIn, 1) : 1
            let fadeOut = system.fadeOut < 1 ? min((1 - progress) / (1 - system.fadeOut), 1) : 1
            return particle.alpha * fadeIn * fadeOut * system.configuration.opacityMultiplier
        }
        let records = pointer.bindMemory(to: Record.self, capacity: count)
        return Array(UnsafeBufferPointer(start: records, count: count))
    }
}
