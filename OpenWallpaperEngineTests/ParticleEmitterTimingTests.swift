import XCTest
import Metal
@testable import OpenWallpaperEngine

/// Emitter `delay`, `duration`, random periodic emission and "limit to one per frame"
/// (`ParticleEmitterTiming`), on the CPU; `ParticleSimulationParityTests` and
/// `ParticleChildrenTests` run them against the GPU.
final class ParticleEmitterTimingTests: XCTestCase {
    /// Exact in binary, so the phase boundaries fall on whole steps.
    private static let step: Float = 1 / 64

    // MARK: - Decoding

    func testTimingDecodesWithWEsDefaults() throws {
        // WE's thunderbolt beam: a delayed, one-second, periodic emitter that emits 8 a period.
        let beam = try emitter(#"{"delay": 0.2, "duration": 1, "flags": 4, "maxperiodicdelay": 9999, "maxperiodicduration": 1,"#
                               + #" "maxtoemitperperiod": 8, "minperiodicdelay": 9999, "minperiodicduration": 1, "rate": 100}"#)
        XCTAssertEqual(beam.delay, 0.2, accuracy: 1e-6)
        XCTAssertEqual(beam.duration, 1)
        XCTAssertTrue(beam.periodic)
        XCTAssertFalse(beam.onePerFrame)
        XCTAssertEqual(beam.periodDuration, 1...1)
        XCTAssertEqual(beam.periodDelay, 9999...9999)
        XCTAssertEqual(beam.maximumPerPeriod, 8)
        XCTAssertEqual(beam.periodLimit(countScale: 1.5), 12, "the limit scales with the count override")

        let plain = try emitter(#"{"flags": 2, "rate": 32}"#)
        var expected = ParticleEmitterTiming()
        expected.onePerFrame = true
        XCTAssertEqual(plain, expected)
        XCTAssertEqual(plain.periodDuration, 2...3, "an unset periodic range is 2…3 s emitting")
        XCTAssertEqual(plain.periodDelay, 1...2, "and 1…2 s paused")
        XCTAssertNil(plain.periodLimit(countScale: 1), "no limit unless periodic")
        let inverted = try emitter(#"{"flags": 4, "minperiodicduration": 5, "maxperiodicduration": 3}"#)
        XCTAssertEqual(inverted.periodDuration, 3...3, "a minimum above the maximum is lowered to it")
    }

    // MARK: - Clock

    func testDelayHoldsTheBurstAndTheRate() {
        var timing = ParticleEmitterTiming()
        timing.delay = 0.5
        var clock = ParticleEmitterClock()
        let steps = run(&clock, timing, frames: 60)
        let first = steps.firstIndex { $0.bursts }
        XCTAssertEqual(first, 31, "starts on the step that reaches 0.5 s")
        XCTAssertFalse(steps[..<31].contains { $0.emits || $0.bursts })
        XCTAssertTrue(steps[31...].allSatisfy(\.emits))
        XCTAssertEqual(steps.filter(\.bursts).count, 1)
    }

    func testDurationStopsTheRateButNotTheParticles() {
        var timing = ParticleEmitterTiming()
        timing.delay = 0.25
        timing.duration = 0.5
        var clock = ParticleEmitterClock()
        let steps = run(&clock, timing, frames: 120)
        let emitting = steps.indices.filter { steps[$0].emits }
        XCTAssertEqual(emitting.first, 15)
        XCTAssertEqual(emitting.last, 46, "0.5 s after the delay")
        XCTAssertEqual(emitting.count, 32)
    }

    func testPeriodicEmissionAlternatesAndBurstsEachPeriod() {
        var timing = ParticleEmitterTiming()
        timing.periodic = true
        timing.periodDuration = 0.5...0.5
        timing.periodDelay = 0.25...0.25
        var clock = ParticleEmitterClock()
        let steps = run(&clock, timing, frames: 180)
        let bursts = steps.indices.filter { steps[$0].bursts }
        XCTAssertEqual(bursts, [0, 48, 96, 144], "a burst every 0.75 s")
        XCTAssertTrue(steps[0..<32].allSatisfy(\.emits))
        XCTAssertFalse(steps[32..<48].contains { $0.emits }, "paused for 0.25 s")
        XCTAssertEqual(steps.filter(\.startsPeriod).count, 4)
    }

    func testRandomPeriodsStayInTheirRanges() {
        var timing = ParticleEmitterTiming()
        timing.periodic = true
        timing.periodDuration = 0.2...0.6
        timing.periodDelay = 0.1...0.3
        var lengths: Set<Float> = []
        for phase in UInt32(0)..<40 {
            let length = ParticleEmitterClock.phaseLength(phase, timing: timing, seed: 7, key: 0)
            XCTAssertTrue((phase % 2 == 0 ? timing.periodDuration : timing.periodDelay).contains(length))
            lengths.insert(length)
        }
        XCTAssertGreaterThan(lengths.count, 30, "each phase draws its own length")
        XCTAssertNotEqual(ParticleEmitterClock.phaseLength(0, timing: timing, seed: 7, key: 1),
                          ParticleEmitterClock.phaseLength(0, timing: timing, seed: 7, key: 2), "instances differ")
    }

    // MARK: - Emission on the CPU

    func testAPeriodEmitsNoMoreThanItsLimit() {
        var system = ParticleTestSystem()
        system.emissionRate = 100
        system.maximum = 100
        system.lifetime = 10...10
        system.instantaneous = 2
        system.emitterTiming.periodic = true
        system.emitterTiming.periodDuration = 1...1
        system.emitterTiming.periodDelay = 1...1
        system.emitterTiming.maximumPerPeriod = 32
        let runtime = ParticleSystemRuntime(texture: texture(), configuration: system.configuration, seed: 3)
        let counts = stepCPU(runtime, frames: 150)
        XCTAssertEqual(counts[63], 34, "the burst and 32 from the rate in the first second")
        XCTAssertEqual(counts[127], 34, "then nothing while paused")
        XCTAssertEqual(counts[149], 68, "a new period bursts and emits its 32 again")
    }

    func testLimitToOnePerFrame() {
        var system = ParticleTestSystem()
        system.emissionRate = 600
        system.lifetime = 10...10
        system.emitterTiming.onePerFrame = true
        let runtime = ParticleSystemRuntime(texture: texture(), configuration: system.configuration, seed: 3)
        XCTAssertEqual(stepCPU(runtime, frames: 30).last, 30, "one a step, however high the rate")
        XCTAssertLessThan(runtime.emissionRemainder, 1, "the excess isn't carried")
    }

    func testDelayedEmitterStartsWithItsBurst() {
        var system = ParticleTestSystem()
        system.emissionRate = 0
        system.instantaneous = 5
        system.lifetime = 10...10
        system.emitterTiming.delay = 0.5
        let runtime = ParticleSystemRuntime(texture: texture(), configuration: system.configuration, seed: 3)
        let counts = stepCPU(runtime, frames: 40)
        XCTAssertEqual(counts[30], 0)
        XCTAssertEqual(counts[31], 5)
        XCTAssertEqual(counts[39], 5)
    }

    // MARK: - Helpers

    private func emitter(_ json: String) throws -> ParticleEmitterTiming {
        ParticleEmitterTiming(try JSONDecoder().decode(WEParticleEmitter.self, from: Data(json.utf8)))
    }

    private func run(_ clock: inout ParticleEmitterClock, _ timing: ParticleEmitterTiming,
                     frames: Int) -> [ParticleEmitterClock.Step] {
        (0..<frames).map { _ in clock.advance(Self.step, timing: timing, seed: 1, key: 0) }
    }

    private func stepCPU(_ runtime: ParticleSystemRuntime, frames: Int) -> [Int] {
        (0..<frames).map { _ in
            ParticleCPUSimulation.step(runtime, inputs: ParticleFrameInputs.advance(runtime, deltaTime: Self.step,
                                                                                    cursor: .zero))
            return runtime.particles.count
        }
    }

    private func texture() -> MTLTexture {
        let device = MTLCreateSystemDefaultDevice()!
        return device.makeTexture(descriptor: .texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1,
                                                                   mipmapped: false))!
    }
}
