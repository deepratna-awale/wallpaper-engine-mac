import XCTest
import Metal
import simd
@testable import OpenWallpaperEngine

/// WE's particle defaults and semantics, from `wallpaper64.exe` (its particle parser 0x1401c1c70,
/// initializer switch 0x14023b5c0, operator VM 0x14023fbc0).
final class ParticleProgramTests: XCTestCase {
    private var texture: MTLTexture!

    override func setUpWithError() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        texture = try XCTUnwrap(device.makeTexture(descriptor: .texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)))
    }

    private func decode<T: Decodable>(_ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private func initializer(_ json: String, pixels: Bool = true) throws -> ParticleProgramOp {
        let element: WEParticleInitializer = try decode(json)
        return try XCTUnwrap(ParticleInitializerBuilder.make(element, defaults: ParticleDefaults(pixelUnits: pixels), path: "t")).record
    }

    private func `operator`(_ json: String, pixels: Bool = true) throws -> ParticleProgramOp {
        let element: WEParticleOperator = try decode(json)
        return try XCTUnwrap(ParticleOperatorBuilder.make(element, defaults: ParticleDefaults(pixelUnits: pixels),
                                                          sceneSize: SIMD2(100, 100), path: "t")).record
    }

    // MARK: - Defaults

    func testInitializerDefaultsAreWEs() throws {
        XCTAssertEqual(try initializer(#"{"name":"lifetimerandom"}"#).a, SIMD4(0, 1, 1, 0))
        XCTAssertEqual(try initializer(#"{"name":"sizerandom"}"#).a, SIMD4(5, 50, 1, 0), "pixels in a 2D scene")
        XCTAssertEqual(try initializer(#"{"name":"sizerandom"}"#, pixels: false).a, SIMD4(0.001, 1, 1, 0))
        XCTAssertEqual(try initializer(#"{"name":"alpharandom"}"#).a, SIMD4(0.05, 1, 1, 0))
        let color = try initializer(#"{"name":"colorrandom","min":"255 0 0"}"#)
        XCTAssertEqual(color.a, SIMD4(1, 0, 0, 1), "divided by 255")
        XCTAssertEqual(color.b, SIMD4(1, 1, 1, 0))
        let velocity = try initializer(#"{"name":"velocityrandom"}"#)
        XCTAssertEqual(velocity.a, SIMD4(-32, -32, 0, 1))
        XCTAssertEqual(velocity.b, SIMD4(32, 32, 0, 0))
        XCTAssertEqual(try initializer(#"{"name":"rotationrandom","max":3}"#).b, SIMD4(0, 0, 3, 0), "a number is z")
        let hsv = try initializer(#"{"name":"hsvcolorrandom"}"#)
        XCTAssertEqual(hsv.a, SIMD4(0, 1.0 / 6.0, 6, 0), "six steps round the circle")
        XCTAssertEqual(hsv.b, SIMD4(0.5, 1, 0.5, 1))
        let around = try XCTUnwrap(ParticleInitializerBuilder.make(try decode(#"{"name":"mapsequencearoundcontrolpoint"}"#),
                                                                    defaults: ParticleDefaults(pixelUnits: true), path: "t"))
        XCTAssertEqual(around.sequenceCount, 32)
        XCTAssertEqual(around.record.d, SIMD4(0, 0, 1, 0))
        let between = try initializer(#"{"name":"mapsequencebetweencontrolpoints"}"#)
        XCTAssertEqual(between.b, SIMD4(0.3, 0.9, 0, 0), "arcamount, sizereductionamount")
        XCTAssertEqual(between.controlPoint1, 1)
        let remap = try initializer(#"{"name":"remapinitialvalue"}"#)
        XCTAssertEqual(ParticleProgramCPU.RemapCode.operation(remap.header.w), 1, "multiply")
        XCTAssertEqual(ParticleProgramCPU.RemapCode.input(remap.header.w), 1, "maxlifetime")
        XCTAssertEqual(ParticleProgramCPU.RemapCode.output(remap.header.w), 2, "size")
    }

    func testOperatorDefaultsAreWEs() throws {
        XCTAssertEqual(try `operator`(#"{"name":"alphafade"}"#).a, SIMD4(0.5, 0.5, 0, 0))
        XCTAssertEqual(try `operator`(#"{"name":"sizechange"}"#).a, SIMD4(1, 0, 0, 1))
        let oscillate = try `operator`(#"{"name":"oscillateposition"}"#)
        XCTAssertEqual(oscillate.c.y, 10, "scalemax in pixels")
        XCTAssertEqual(try `operator`(#"{"name":"oscillateposition"}"#, pixels: false).c.y, 0.5)
        let turbulence = try `operator`(#"{"name":"turbulence"}"#)
        XCTAssertEqual(turbulence.b, SIMD4(0.01, 500, 1000, 20))
        XCTAssertEqual(turbulence.c, SIMD4(0, 0, 0, 0), "phasemin 0, phasemax 0")
        XCTAssertEqual(try `operator`(#"{"name":"vortex"}"#).c, SIMD4(500, 650, 2500, 0))
        let attract = try `operator`(#"{"name":"controlpointattract"}"#)
        XCTAssertEqual(attract.b, SIMD4(512, 512, 15, 0))
        XCTAssertEqual(attract.header.y, 2, "flag 2: no overshoot")
        XCTAssertEqual(try `operator`(#"{"name":"reducemovementnearcontrolpoint"}"#).a, SIMD4(100, 350, 100, 0))
        XCTAssertEqual(try `operator`(#"{"name":"capvelocity"}"#).a.x, 100)
        XCTAssertEqual(try `operator`(#"{"name":"oscillatealpha"}"#).blend, ParticleProgramOp.noBlend)
        XCTAssertNotEqual(try `operator`(#"{"name":"oscillatealpha","blendinend":0.5}"#).blend, ParticleProgramOp.noBlend)
        let remap = try `operator`(#"{"name":"remapvalue"}"#)
        XCTAssertEqual(ParticleProgramCPU.RemapCode.input(remap.header.w), 0, "lifetimefraction")
        XCTAssertEqual(ParticleProgramCPU.RemapCode.output(remap.header.w), 2, "size")
    }

    func testEmitterAndRendererDefaultsAreWEs() throws {
        let sphere = ParticleSystemBuilder.emitterShape(try decode(#"{"name":"sphererandom"}"#),
                                                         defaults: ParticleDefaults(pixelUnits: true))
        XCTAssertEqual(sphere.distanceMaximum.x, 256)
        XCTAssertEqual(sphere.directions, SIMD3(1, 1, 0))
        let box = ParticleSystemBuilder.emitterShape(try decode(#"{"name":"boxrandom"}"#),
                                                      defaults: ParticleDefaults(pixelUnits: false))
        XCTAssertEqual(box.distanceMaximum, SIMD3(1, 1, 1))
        XCTAssertEqual(box.directions, SIMD3(1, 1, 1))
        let trail = ParticleRendererDefaults(try decode(#"{"name":"spritetrail"}"#))
        XCTAssertEqual([trail.length, trail.maximumLength, trail.minimumLength], [0.05, 10, 0])
        XCTAssertEqual(ParticleRendererDefaults(try decode(#"{"name":"rope"}"#)).subdivision, 4)
        let ropeTrail = ParticleRendererDefaults(try decode(#"{"name":"ropetrail"}"#))
        XCTAssertEqual(ropeTrail.subdivision, 1)
        XCTAssertEqual(ropeTrail.length, 1)
    }

    // MARK: - Semantics

    private func state(age: Float, lifetime: Float = 1) -> ParticleProgramState {
        var state = ParticleProgramState()
        state.age = age
        state.lifetime = lifetime
        state.baseSize = 10
        state.baseAlpha = 1
        return state
    }

    func testTwoOperatorsOfAKindBothApplyInOrder() {
        let grow = ParticleOperator(.sizeChange, a: SIMD4(1, 3, 0, 1)).record
        let shrink = ParticleOperator(.sizeChange, a: SIMD4(1, 0.5, 0, 1)).record
        var particle = state(age: 0.5)
        _ = ParticleProgramCPU.runOperators([grow, shrink], on: &particle, context: ParticleProgramContext(), index: 0,
                                            neighbors: .init())
        XCTAssertEqual(particle.size, 10 * 2 * 0.75, accuracy: 1e-5, "both multiply the base size")
    }

    func testAlphaFadeUsesFractionsOfTheLife() {
        let fade = ParticleOperator(.alphaFade, a: SIMD4(0.5, 0.5, 0, 0)).record
        for (age, expected) in [(0.25, 0.5), (0.5, 1), (0.75, 0.5)] as [(Float, Float)] {
            var particle = state(age: age)
            _ = ParticleProgramCPU.runOperators([fade], on: &particle, context: ParticleProgramContext(), index: 0,
                                                neighbors: .init())
            XCTAssertEqual(particle.alpha, expected, accuracy: 1e-5)
        }
    }

    func testOscillationsDrawEachParticlesOwnRandom() {
        let oscillate = ParticleOperator(.oscillateAlpha, b: SIMD4(1, 10, 0, 6.28), c: SIMD4(0, 1, 0, 0)).record
        var values: Set<Float> = []
        for random in [0.1, 0.5, 0.9] as [Float] {
            var context = ParticleProgramContext()
            context.random = random
            var particle = state(age: 0.3)
            _ = ParticleProgramCPU.runOperators([oscillate], on: &particle, context: context, index: 0, neighbors: .init())
            XCTAssertLessThanOrEqual(particle.alpha, random + 1e-5, "the random also scales the swing")
            values.insert(particle.alpha)
        }
        XCTAssertEqual(values.count, 3, "not the middle of the range for all")
    }

    func testHSVColorRandomPicksHueSteps() {
        let record = ParticleInitializer(.hsvColorRandom, a: SIMD4(0, 1.0 / 6.0, 6, 0), b: SIMD4(1, 1, 1, 1)).record
        var hues: Set<[Float]> = []
        for serial in UInt32(0)..<200 {
            var particle = state(age: 0)
            particle.baseColor = SIMD3(repeating: 1)
            var context = ParticleProgramContext()
            context.serial = serial
            ParticleProgramCPU.runInitializers([record], on: &particle, context: context)
            let c = particle.baseColor
            XCTAssertEqual(max(c.x, c.y, c.z), 1, accuracy: 1e-5, "full value")
            XCTAssertEqual(min(c.x, c.y, c.z), 0, accuracy: 1e-5, "full saturation")
            hues.insert([c.x, c.y, c.z].map { ($0 * 100).rounded() })
        }
        XCTAssertEqual(hues.count, 6, "six hues, 60° apart")
    }

    func testRemapInitialValueDefaultMultipliesSizeByLifetime() throws {
        let remap = try initializer(#"{"name":"remapinitialvalue"}"#)
        var particle = state(age: 0, lifetime: 0.25)
        ParticleProgramCPU.runInitializers([remap], on: &particle, context: ParticleProgramContext())
        XCTAssertEqual(particle.baseSize, 2.5, accuracy: 1e-5)
    }

    /// Without `movement` WE doesn't move particles by their velocity; with it, velocities and
    /// gravity are in the system's space, so they scale with the object.
    func testMovementIsAnOperatorInTheSystemsSpace() {
        var system = ParticleTestSystem()
        system.emissionRate = 0
        system.instantaneous = 1
        system.spawnExtent = .zero
        system.minimumVelocity = SIMD2(10, 0)
        system.maximumVelocity = SIMD2(10, 0)
        system.lifetime = 10...10
        system.spins = false
        func travel(scale: Float, movement: Bool) -> Float {
            var configuration = system.configuration
            if !movement { configuration.program.operators.removeAll { $0.kind == .movement } }
            configuration.emitterLinear = simd_float2x2(diagonal: SIMD2(repeating: scale))
            let runtime = ParticleSystemRuntime(texture: texture, configuration: configuration, seed: 1)
            for _ in 0..<60 {
                ParticleCPUSimulation.step(runtime, inputs: ParticleFrameInputs.advance(runtime, deltaTime: 1 / 60, cursor: .zero))
            }
            return runtime.particles[0].position.x - system.origin.x
        }
        XCTAssertEqual(travel(scale: 1, movement: false), 0, accuracy: 1e-4)
        XCTAssertEqual(travel(scale: 1, movement: true), 10, accuracy: 0.05)
        XCTAssertEqual(travel(scale: 2, movement: true), 20, accuracy: 0.1, "velocity in the object's units")
    }

    /// `mapsequencebetweencontrolpoints` flag 32 restarts the sequence with each period of a
    /// periodic emitter (wallpaper64.exe 0x14022f850); without it the sequence runs on.
    func testSequencesRestartWithPeriodicEmissionWhenFlagged() {
        func positions(flags: UInt32) -> [Float] {
            var system = ParticleTestSystem()
            system.emissionRate = 0
            system.instantaneous = 3
            system.spawnExtent = .zero
            system.minimumVelocity = .zero
            system.maximumVelocity = .zero
            system.lifetime = 100...100
            system.emitterTiming.periodic = true
            system.emitterTiming.periodDuration = 0.1...0.1
            system.emitterTiming.periodDelay = 0.1...0.1
            system.controlPoints[1] = ParticleTestSystem.point(SIMD2(100, 0))
            var between = ParticleInitializer(.mapSequenceBetweenControlPoints, flags: flags, controlPoints: 0 | 1 << 8,
                                              a: SIMD4(0, 0, 1, 0))
            between.sequenceCount = 5
            system.initializers = [between]
            let runtime = ParticleSystemRuntime(texture: texture, configuration: system.configuration, seed: 1)
            for _ in 0..<20 {
                ParticleCPUSimulation.step(runtime, inputs: ParticleFrameInputs.advance(runtime, deltaTime: 1 / 60, cursor: .zero))
            }
            return runtime.particles.map { ($0.position.x - system.origin.x).rounded() }
        }
        XCTAssertEqual(positions(flags: 32), [0, 25, 50, 0, 25, 50])
        XCTAssertEqual(positions(flags: 0), [0, 25, 50, 75, 100, 0])
    }

    /// `starttime` pre-simulates in WE's steps (wallpaper64.exe 0x14022f2e0).
    func testStartTimePresimulatesInWEsSteps() {
        XCTAssertEqual(ParticlePrewarm.steps(startTime: 1, maximum: 100), Array(repeating: 0.05, count: 20))
        XCTAssertEqual(ParticlePrewarm.steps(startTime: 1, maximum: 500), Array(repeating: 0.2, count: 5))
        XCTAssertEqual(ParticlePrewarm.steps(startTime: 0, maximum: 100), [])
    }
}
