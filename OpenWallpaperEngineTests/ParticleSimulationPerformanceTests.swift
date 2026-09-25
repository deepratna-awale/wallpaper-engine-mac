import XCTest
import Metal
@testable import OpenWallpaperEngine

/// Per-frame cost of the particle simulation at 1k, 10k and 100k live particles: the CPU step
/// plus writing its records, against the GPU step's CPU encode time and GPU time. Prints the
/// medians; the bounds only catch a pathological slowdown.
final class ParticleSimulationPerformanceTests: XCTestCase {
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

    /// Movement, gravity, drag, turbulence, and size, alpha and colour over life: a common mix.
    private func typical(_ count: Int) -> ParticleTestSystem {
        var system = ParticleTestSystem()
        system.maximum = count
        // Fills the system in two frames, then replaces every death at once.
        system.emissionRate = Float(count) * 30
        system.lifetime = 2...3
        system.spawnExtent = SIMD2(800, 400)
        system.gravity = SIMD2(0, -50)
        system.drag = 0.2
        system.turbulence = Turbulence(scale: 0.005, speed: 200...400, timeScale: 0.1, phase: 0, mask: SIMD2(1, 1))
        system.sizeChange = ParticleChange(startTime: 0, endTime: 1, startValue: 1, endValue: 0.2)
        system.alphaChange = ParticleChange(startTime: 0.5, endTime: 1, startValue: 1, endValue: 0)
        system.colorChange = ParticleColorChange(startTime: 0, endTime: 1, startValue: SIMD4(repeating: 1),
                                                 endValue: SIMD4(1, 0.5, 0.2, 1))
        return system
    }

    func testSimulationCost() throws {
        var report: [String] = []
        for count in [1_000, 10_000, 100_000] {
            report.append(try measure("typical", typical(count), count: count))
        }
        for count in [1_000, 10_000, 100_000] {
            var system = typical(count)
            system.boids = ParticleBoids(alignment: 0.2, cohesion: 0.1, separation: 5, threshold: 80)
            report.append(try measure("boids", system, count: count, frames: count >= 100_000 ? 6 : 20))
        }
        print("Particle simulation cost per frame (median):\n" + report.joined(separator: "\n"))
    }

    private func measure(_ label: String, _ system: ParticleTestSystem, count: Int, frames: Int = 30) throws -> String {
        let configuration = system.configuration
        let cpu = ParticleSystemRuntime(texture: texture, configuration: configuration, seed: 1)
        let gpu = ParticleSystemRuntime(texture: texture, configuration: configuration, seed: 1)
        let format = ParticleVertexFormat.sprite
        let records = UnsafeMutableRawPointer.allocate(byteCount: count * format.stride, alignment: 16)
        defer { records.deallocate() }
        var cpuTimes: [Double] = [], encodeTimes: [Double] = [], gpuTimes: [Double] = []
        for frame in 0..<(frames + 3) {
            let start = CACurrentMediaTime()
            ParticleCPUSimulation.update([cpu], deltaTime: 1 / 60, cursor: .zero)
            let written = ParticleRecordWriter.recordCount(cpu, format: format)
            ParticleRecordWriter.write(cpu, format: format, count: written, into: records, opacity: { $0.alpha })
            let cpuTime = CACurrentMediaTime() - start

            let encodeStart = CACurrentMediaTime()
            let inputs = ParticleFrameInputs.advance(gpu, deltaTime: 1 / 60, cursor: .zero)
            let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
            simulator.encode([.init(system: gpu, inputs: inputs, kind: .sprite, materialVertexCount: 6)],
                             sceneSize: SIMD2(1920, 1080), targetSize: SIMD2(1920, 1080), commandBuffer: commandBuffer)
            commandBuffer.commit()
            let encodeTime = CACurrentMediaTime() - encodeStart
            commandBuffer.waitUntilCompleted()
            XCTAssertNil(commandBuffer.error)
            // The first frames fill the system and grow its buffers.
            guard frame >= 3 else { continue }
            cpuTimes.append(cpuTime * 1000)
            encodeTimes.append(encodeTime * 1000)
            gpuTimes.append((commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1000)
        }
        XCTAssertEqual(cpu.particles.count, count, label)
        XCTAssertEqual(gpu.gpu?.completedCount, count, label)
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        XCTAssertLessThan(median(gpuTimes), 100, "\(label) \(count)")
        return String(format: "%@ %7d: CPU %8.3f ms | GPU %7.3f ms (+ %.3f ms CPU encode)",
                      label, count, median(cpuTimes), median(gpuTimes), median(encodeTimes))
    }
}
