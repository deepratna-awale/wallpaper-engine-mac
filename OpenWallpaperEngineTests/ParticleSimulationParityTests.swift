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
        let sizes = try XCTUnwrap(device.makeBuffer(length: 14 * 4, options: .storageModeShared))
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(sizes, offset: 0, index: 0)
        encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let metal = Array(UnsafeBufferPointer(start: sizes.contents().bindMemory(to: UInt32.self, capacity: 14), count: 14)).map(Int.init)
        XCTAssertEqual(metal, [MemoryLayout<ParticleGPUState>.stride, MemoryLayout<ParticleGPUParameters>.stride,
                               MemoryLayout<ParticleGPUFrame>.stride, MemoryLayout<ParticleSpriteInstance>.stride,
                               MemoryLayout<ParticleRopeSegmentInstance>.stride, MemoryLayout<LayerUniform>.stride,
                               MemoryLayout<ParticleGPUInstance>.stride, MemoryLayout<ParticleCollisionPlacement>.stride,
                               MemoryLayout<ParticleGPULinkedPoints>.stride, MemoryLayout<ParticleGPUEmitter>.stride,
                               MemoryLayout<ParticleGPUEmitterStep>.stride, MemoryLayout<ParticleGPUEmitterState>.stride,
                               ParticleGPUSystem.pointStateStride, ParticleGPUSystem.serialStateStride])
    }

    // MARK: - Parity per initializer and operator

    func testEmissionMovementGravityAndDrag() throws {
        var system = ParticleTestSystem()
        system.gravity = SIMD2(0, -120)
        system.drag = 0.8
        try assertParity(system)
    }

    func testBoxEmitterSpinAndCappedVelocity() throws {
        var system = ParticleTestSystem()
        system.emitterName = "boxrandom"
        system.spawnExtent = SIMD2(300, -80)
        system.emitterLinear = simd_float2x2(SIMD2(0, 1), SIMD2(-1, 0))
        system.operators = [ParticleOperator(.angularMovement, a: SIMD4(0, 0, 2, 0.5)),
                            ParticleOperator(.capVelocity, a: SIMD4(30, 0, 0, 0))]
        try assertParity(system)
    }

    func testTurbulence() throws {
        var system = ParticleTestSystem()
        system.operators = [ParticleOperator(.turbulence, a: SIMD4(1, -1, 0, 0), b: SIMD4(0.01, 200, 600, 0.5),
                                             c: SIMD4(0, 1, 0, 0))]
        try assertParity(system)
    }

    func testControlPointAttractAndCursorControlPoint() throws {
        var system = ParticleTestSystem()
        system.operators = [ParticleOperator(.controlPointAttract, flags: 3, controlPoints: 1, b: SIMD4(300, 400, 5, 0))]
        system.controlPoints[1] = ParticleTestSystem.point(SIMD2(10, -10), cursor: true)
        system.emitterControlPoint = 1
        try assertParity(system)
    }

    func testVortices() throws {
        var system = ParticleTestSystem()
        system.controlPoints[2] = ParticleTestSystem.point(SIMD2(20, -20))
        system.operators = [ParticleOperator(.vortex, controlPoints: 2, a: SIMD4(5, 0, 0, 0), b: SIMD4(0, 0, 1, 0),
                                             c: SIMD4(5, 300, 400, 50))]
        try assertParity(system, "vortex")
        system.operators = [ParticleOperator(.vortexV2, flags: 6, controlPoints: 2, a: SIMD4(0, 0, 1, 0),
                                             b: SIMD4(0, 32, 0, 2500), c: SIMD4(1, 120, 5, 250), d: SIMD4(10, 0, 0, 0))]
        try assertParity(system, "vortex_v2", positionTolerance: 3)
    }

    func testBoids() throws {
        var system = ParticleTestSystem()
        system.operators = [ParticleOperator(.boids, flags: 1, a: SIMD4(20, 60, 200, 0), b: SIMD4(15, 1, 2, 0))]
        try assertParity(system, positionTolerance: 3)
    }

    func testControlPointDistanceOperators() throws {
        var system = ParticleTestSystem()
        system.controlPoints[1] = ParticleTestSystem.point(SIMD2(-50, 20), cursor: true)
        system.operators = [ParticleOperator(.reduceMovementNearControlPoint, a: SIMD4(10, 200, 3, 0)),
                            ParticleOperator(.maintainDistanceToControlPoint, controlPoints: 1, a: SIMD4(80, 0.5, 0, 0)),
                            ParticleOperator(.maintainDistanceBetweenControlPoints, controlPoints: 0 | 1 << 8)]
        try assertParity(system, positionTolerance: 2, cursor: { frame in SIMD2(640 + Float(frame), 360) })
    }

    func testSequencesBetweenAndAroundControlPoints() throws {
        var system = ParticleTestSystem()
        system.rendererName = "rope"
        system.controlPoints[0] = ParticleTestSystem.point(SIMD2(-200, 0))
        system.controlPoints[1] = ParticleTestSystem.point(SIMD2(40, 60), cursor: true)
        var around = ParticleInitializer(.mapSequenceAroundControlPoint, a: SIMD4(0, 0, 1, 0), b: SIMD4(-5, -5, 0, 0),
                                         c: SIMD4(5, 5, 0, 0), d: SIMD4(0, 1, 0, 0))
        around.sequenceCount = 16
        var between = ParticleInitializer(.mapSequenceBetweenControlPoints, flags: 15, controlPoints: 0 | 1 << 8,
                                          a: SIMD4(0, 0, 1, 1), b: SIMD4(0.4, 0.9, 0, 0), c: SIMD4(0, 1, 0, 0))
        between.sequenceCount = 16
        system.initializers = [around, between,
                               ParticleInitializer(.positionOffsetRandom, a: SIMD4(1, 1, 0, 0), c: SIMD4(0.001, 30, 5, 6))]
        system.operators = [ParticleOperator(.turbulence, a: SIMD4(1, 1, 0, 0), b: SIMD4(0.02, 50, 80, 1))]
        try assertParity(system, positionTolerance: 3)
    }

    func testEveryInitializerKind() throws {
        var system = ParticleTestSystem()
        system.controlPoints[2] = ParticleTestSystem.point(SIMD2(30, 0), cursor: true)
        let remapCode = ParticleProgramCPU.RemapCode.pack(operation: 1, input: 7, output: 2, inputComponent: 0,
                                                          outputComponent: 0, transform: 1, octaves: 3)
        var remap = ParticleInitializer(.remapInitialValue, flags: 1, controlPoints: 2, a: SIMD4(5, 5, 5, 0),
                                        b: SIMD4(60, 60, 60, 0), c: SIMD4(0.2, 0.2, 0.2, 0), d: SIMD4(1, 1, 1, 0),
                                        e: SIMD4(1, 0, 0, 1))
        remap.record.header.w = remapCode
        system.initializers = [
            ParticleInitializer(.hsvColorRandom, a: SIMD4(0.1, 0.1, 6, 0), b: SIMD4(0.5, 1, 0.5, 1)),
            ParticleInitializer(.colorList, a: SIMD4(3, 0.1, 0.1, 0.1), b: SIMD4(0, 1, 1, 0), c: SIMD4(0.3, 0.5, 1, 0),
                                d: SIMD4(0.6, 1, 0.8, 0), e: SIMD4(0, 1, 1, 0)),
            ParticleInitializer(.turbulentVelocityRandom, a: SIMD4(100, 250, 0, 0.1), b: SIMD4(1, 1, 0, 0),
                                c: SIMD4(0, 1, 0, 0), d: SIMD4(0, 0, 1, 0)),
            ParticleInitializer(.inheritControlPointVelocity, controlPoints: 2, a: SIMD4(0.1, 0.2, 0, 0)),
            remap,
        ]
        try assertParity(system, cursor: { frame in SIMD2(640 + 3 * Float(frame), 360) })
    }

    func testChangesAndFadesOverLife() throws {
        var system = ParticleTestSystem()
        // Two of a kind apply in turn.
        system.operators = [ParticleOperator(.sizeChange, a: SIMD4(1, 3, 0.1, 0.8)),
                            ParticleOperator(.sizeChange, a: SIMD4(1, 0.5, 0.5, 1)),
                            ParticleOperator(.alphaChange, a: SIMD4(1, 0, 0.2, 1)),
                            ParticleOperator(.colorChange, a: SIMD4(1, 0.5, 0.2, 0), b: SIMD4(0.2, 1, 0.5, 0),
                                             c: SIMD4(0, 0.5, 0, 0)),
                            ParticleOperator(.alphaFade, a: SIMD4(0.1, 0.8, 0, 0))]
        try assertParity(system)
    }

    func testOscillationsAndRemaps() throws {
        var system = ParticleTestSystem()
        let window = ParticleBlend(inStart: 0.1, inEnd: 0.4, outStart: 0.7, outEnd: 0.9)
        system.operators = [
            ParticleOperator(.oscillateSize, b: SIMD4(2, 4, 0, 1), c: SIMD4(0.5, 1.5, 0, 0)),
            ParticleOperator(.oscillatePosition, a: SIMD4(1, 1, 0, 0), b: SIMD4(3, 3, 0, 0), c: SIMD4(40, 60, 0, 0),
                             blend: window),
            ParticleOperator(.oscillateAlpha, b: SIMD4(5, 5, 1, 2), c: SIMD4(0.2, 0.6, 0, 0), blend: window),
        ]
        func remap(_ operation: UInt32, input: UInt32, output: UInt32, transform: UInt32, flags: UInt32 = 0,
                   low: SIMD4<Float>, high: SIMD4<Float>, scale: Float) -> ParticleOperator {
            var op = ParticleOperator(.remapValue, flags: flags, b: SIMD4(1, 1, 1, 0), c: low, d: high, e: SIMD4(scale, 0, 0, 1))
            op.record.header.w = ParticleProgramCPU.RemapCode.pack(operation: operation, input: input, output: output,
                                                                   inputComponent: 0, outputComponent: 0,
                                                                   transform: transform, octaves: 3)
            return op
        }
        system.operators += [
            remap(1, input: 0, output: 3, transform: 1, low: SIMD4(0.2, 0.2, 0.2, 0), high: SIMD4(0.9, 0.9, 0.9, 0), scale: 2),
            remap(0, input: 0, output: 15, transform: 5, low: SIMD4(-200, -100, 0, 0), high: SIMD4(200, -1000, 0, 0), scale: 10),
            remap(1, input: 0, output: 4, transform: 6, flags: 3, low: SIMD4(-5, -5, -5, 0), high: SIMD4(7, 7, 7, 0), scale: 8),
        ]
        try assertParity(system, positionTolerance: 3)
    }

    func testCollisions() throws {
        var system = ParticleTestSystem()
        system.gravity = SIMD2(0, -400)
        var plane = ParticleOperator(.collision)
        plane.collision = ParticleCollision(shape: .plane(normal: SIMD3(0, 1, 0), distance: -60))
        var sphere = ParticleOperator(.collision)
        sphere.collision = ParticleCollision(shape: .sphere(origin: SIMD3(0, -30, 0), radius: 20), behavior: .slide)
        system.operators = [plane, sphere]
        try assertParity(system, positionTolerance: 2)
    }

    func testEmitterTimingRunsTheSameOnTheGPU() throws {
        var periodic = ParticleTestSystem()
        periodic.instantaneous = 3
        periodic.emitterTiming.periodic = true
        periodic.emitterTiming.periodDuration = 0.2...0.5
        periodic.emitterTiming.periodDelay = 0.1...0.3
        periodic.emitterTiming.maximumPerPeriod = 40
        try assertParity(periodic, "periodic")
        var delayed = ParticleTestSystem()
        delayed.emitterTiming.delay = 0.4
        delayed.emitterTiming.duration = 0.8
        try assertParity(delayed, "delay and duration")
        var single = ParticleTestSystem()
        single.lifetime = 5...5
        single.emitterTiming.onePerFrame = true
        try assertParity(single, "one per frame")
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

    func testEmitterBurstSpeedRingAndSign() throws {
        var system = ParticleTestSystem()
        system.instantaneous = 300
        system.emissionRate = 120
        system.emitterSpeed = SIMD2(50, 250)
        system.minimumSpawnRatio = 0.5
        system.emitterSign = SIMD2(0, 1)
        system.lifetime = 3...4
        try assertParity(system)
    }

    /// Every emitter runs, each with its own rate, burst, timing and control point (WE's
    /// dripping-water presets).
    func testEveryEmitterRunsTheSameOnTheGPU() throws {
        var system = ParticleTestSystem()
        system.emissionRate = 200
        system.controlPoints[1] = ParticleTestSystem.point(SIMD2(-200, 50))
        system.controlPoints[2] = ParticleTestSystem.point(SIMD2(250, -80))
        var second = ParticleEmitter(rate: 300)
        second.shape.controlPoint = 1
        second.shape.distanceMaximum = SIMD3(repeating: 20)
        second.instantaneous = 40
        var third = ParticleEmitter(rate: 150)
        third.shape.kind = .box
        third.shape.controlPoint = 2
        third.shape.distanceMaximum = SIMD3(60, 10, 0)
        third.timing.periodic = true
        third.timing.periodDuration = 0.2...0.4
        third.timing.periodDelay = 0.1...0.2
        third.timing.maximumPerPeriod = 30
        system.extraEmitters = [second, third]
        try assertParity(system, positionTolerance: 2)
    }

    /// WE's damped drag below 40 frames a second and its half steps at a limit of 20 or less.
    func testLowFrameRateDragAndHalfStepsRunTheSameOnTheGPU() throws {
        var system = ParticleTestSystem()
        system.gravity = SIMD2(0, -150)
        system.drag = 3
        system.operators = [ParticleOperator(.turbulence, a: SIMD4(1, 1, 0, 0), b: SIMD4(0.01, 200, 400, 0.5)),
                            ParticleOperator(.vortex, controlPoints: 0, b: SIMD4(0, 0, 1, 0), c: SIMD4(0, 500, 300, 50))]
        try assertParity(system, "30 fps", positionTolerance: 2, frameTime: 1 / 30)
        try assertParity(system, "a limit of 15", positionTolerance: 2, frameTime: 1 / 15, frameRateLimit: 15)
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
        var scaled = ParticleRopeUV()
        scaled.inverseScale = 0.5
        scaled.rate = 600
        scaled.lifetime = 1.5
        var scrolling = scaled
        scrolling.scrolling = true
        scrolling.smoothing = false
        for (renderer, uv) in [("rope", ParticleRopeUV()), ("ropetrail", ParticleRopeUV()), ("rope", scaled),
                               ("rope", scrolling), ("ropetrail", scrolling)] {
            var system = ParticleTestSystem()
            system.rendererName = renderer
            system.ropeUV = uv
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

    /// The built-in sprite goes through the emitter's transform and the renderer's orientation on
    /// both paths (`spriteAxes`).
    func testBuiltInSpritesTakeTheEmitterTransform() throws {
        var upright = ParticleOrientation()
        upright.mode = .upright
        upright.objectSpace = false
        for orientation in [ParticleOrientation(), upright] {
            var system = ParticleTestSystem()
            let turn = simd_float2x2(SIMD2(0.8, 0.6), SIMD2(-0.6, 0.8))
            system.emitterLinear = turn * simd_float2x2(diagonal: SIMD2(2.5, 0.5))
            system.orientation = orientation
            let (cpu, gpu) = try runBoth(system, frames: 30, kind: .fallbackSprite)
            let actual = simulator.records(gpu.runtime, as: LayerUniform.self, queue: queue).records
            XCTAssertEqual(actual.count, cpu.particles.count)
            XCTAssertEqual(cpu.drawLinear, system.emitterLinear)
            XCTAssertEqual(cpu.spriteLinear, orientation.spriteLinear(linear: system.emitterLinear))
            for (record, particle) in zip(actual, cpu.particles) {
                let axes = cpu.spriteAxes(size: particle.size, rotation: particle.rotation, scale: SIMD2(1, 1))
                XCTAssertLessThan(simd_distance(record.quadAxisX, axes.x), 1e-2)
                XCTAssertLessThan(simd_distance(record.quadAxisY, axes.y), 1e-2)
            }
        }
    }

    // MARK: - Helpers

    private struct GPURun {
        let runtime: ParticleSystemRuntime
        var count: Int { runtime.gpu?.completedCount ?? 0 }
    }

    private func runBoth(_ system: ParticleTestSystem, frames: Int = frames, seed: UInt32 = 42,
                         kind: ParticleGPUDrawKind? = nil,
                         emitter: ((Int) -> SceneAffineTransform)? = nil,
                         cursor: ((Int) -> SIMD2<Float>)? = nil, frameTime: Float? = nil,
                         frameRateLimit: Int = 0) throws -> (ParticleSystemRuntime, GPURun) {
        let cpu = ParticleSystemRuntime(texture: texture, configuration: system.configuration, seed: seed)
        let gpu = ParticleSystemRuntime(texture: texture, configuration: system.configuration, seed: seed)
        let kind = kind ?? (system.rendererName == "ropetrail" ? .ropeTrail : .sprite)
        var last: MTLCommandBuffer?
        for frame in 0..<frames {
            let world = emitter?(frame)
            let point = cursor?(frame) ?? Self.cursor
            ParticleCPUSimulation.step(cpu, inputs: ParticleFrameInputs.advance(cpu, deltaTime: 1 / 60, cursor: point,
                                                                                emitter: world, frameTime: frameTime,
                                                                                frameRateLimit: frameRateLimit))
            let inputs = ParticleFrameInputs.advance(gpu, deltaTime: 1 / 60, cursor: point, emitter: world,
                                                     frameTime: frameTime, frameRateLimit: frameRateLimit)
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
                              emitter: ((Int) -> SceneAffineTransform)? = nil, cursor: ((Int) -> SIMD2<Float>)? = nil,
                              frameTime: Float? = nil, frameRateLimit: Int = 0,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        let (cpu, gpu) = try runBoth(system, emitter: emitter, cursor: cursor, frameTime: frameTime,
                                     frameRateLimit: frameRateLimit)
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
            particle.alpha * system.configuration.opacityMultiplier
        }
        let records = pointer.bindMemory(to: Record.self, capacity: count)
        return Array(UnsafeBufferPointer(start: records, count: count))
    }
}
