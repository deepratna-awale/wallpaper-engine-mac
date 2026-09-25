import XCTest
import Metal
import simd
@testable import OpenWallpaperEngine

/// Every particle system of every scene in a local library, loaded as the app loads it, simulated
/// on the CPU and on the GPU with one seed: the two agree on count and on the means of position,
/// size, alpha and colour. Skipped when the library is absent (CI). `OWE_LIBRARY` overrides the
/// library root.
final class ParticleSimulationSweepTests: XCTestCase {
    func testEveryLibraryParticleSystemSimulatesTheSameOnTheGPU() throws {
        let library = LibrarySweepTests.libraryRoot
        try XCTSkipUnless(FileManager.default.fileExists(atPath: library.path), "wallpaper library not present")
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let simulator = try ParticleGPUSimulator(device: device)
        let texture = try XCTUnwrap(device.makeTexture(descriptor: .texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)))

        var systems = 0, children = 0, particles = 0
        var failures: [String] = []
        for id in try FileManager.default.contentsOfDirectory(atPath: library.path).sorted() {
            let directory = library.appending(path: id, directoryHint: .isDirectory)
            guard FileManager.default.fileExists(atPath: directory.appending(path: "scene.json").path),
                  let data = FileManager.default.contents(atPath: directory.appending(path: "project.json").path),
                  let project = try? JSONDecoder().decode(WEProject.self, from: data) else { continue } // decoding is covered elsewhere
            defer {
                for prefix in ["SceneUserProperties.", "SceneUserPropertiesExplicit.", "SceneAdditionalControlsVersion."] {
                    UserDefaults.standard.removeObject(forKey: prefix + directory.path)
                }
            }
            guard let content = SceneWallpaperViewModel(wallpaper: WEWallpaper(using: project, where: directory)).metalContent()
            else { continue }
            let extent = max(content.size.x, content.size.y)
            // Families step together, parents first, as the renderer steps them.
            let configurations = content.particleSystems
            let cpuSystems = configurations.enumerated().map { index, configuration in
                ParticleSystemRuntime(texture: texture, configuration: configuration, seed: ParticleRandom.pcg(UInt32(index)))
            }
            let gpuSystems = configurations.enumerated().map { index, configuration in
                ParticleSystemRuntime(texture: texture, configuration: configuration, seed: ParticleRandom.pcg(UInt32(index)))
            }
            ParticleSystemRuntime.linkFamilies(cpuSystems)
            ParticleSystemRuntime.linkFamilies(gpuSystems)
            let cursor = content.size / 2
            var last: MTLCommandBuffer?
            for _ in 0..<90 {
                ParticleCPUSimulation.update(cpuSystems, deltaTime: 1 / 60, cursor: cursor)
                let requests = gpuSystems.map { gpu in
                    ParticleGPUSimulator.Request(system: gpu, inputs: ParticleFrameInputs.advance(gpu, deltaTime: 1 / 60, cursor: cursor),
                                                 kind: .fallback(rendererName: gpu.configuration.rendererName))
                }
                let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
                simulator.encode(requests, sceneSize: content.size, targetSize: content.size, commandBuffer: commandBuffer)
                commandBuffer.commit()
                last = commandBuffer
            }
            last?.waitUntilCompleted()
            for (index, configuration) in configurations.enumerated() {
                systems += 1
                if configuration.link != nil { children += 1 }
                let cpu = cpuSystems[index], gpu = gpuSystems[index]
                let states = simulator.snapshot(gpu, queue: queue)
                particles += states.count
                let label = "\(id) system \(index) (\(configuration.rendererName), max \(configuration.maximumParticleCount))"
                let expected = cpu.particles.count
                if abs(states.count - expected) > max(2, expected / 50) {
                    failures.append("\(label): \(states.count) particles on the GPU, \(expected) on the CPU")
                    continue
                }
                guard !states.isEmpty, expected > 0 else { continue }
                let cpuMean = cpu.particles.reduce(SIMD2<Float>.zero) { $0 + $1.position } / Float(expected)
                let gpuMean = states.reduce(SIMD2<Float>.zero) { $0 + SIMD2($1.positionVelocity.x, $1.positionVelocity.y) }
                    / Float(states.count)
                if !(simd_distance(cpuMean, gpuMean) <= extent * 0.01) {
                    failures.append("\(label): mean position \(gpuMean) on the GPU, \(cpuMean) on the CPU")
                }
                let cpuSize = cpu.particles.reduce(0) { $0 + $1.size } / Float(expected)
                let gpuSize = states.reduce(0) { $0 + $1.life.z } / Float(states.count)
                if !(abs(cpuSize - gpuSize) <= max(abs(cpuSize) * 0.03, 0.01)) {
                    failures.append("\(label): mean size \(gpuSize) on the GPU, \(cpuSize) on the CPU")
                }
                let cpuColor = cpu.particles.reduce(SIMD4<Float>.zero) { $0 + $1.color } / Float(expected)
                let gpuColor = states.reduce(SIMD4<Float>.zero) { $0 + $1.color } / Float(states.count)
                if !(simd_distance(cpuColor, gpuColor) <= 0.02) {
                    failures.append("\(label): mean colour \(gpuColor) on the GPU, \(cpuColor) on the CPU")
                }
                let cpuAlpha = cpu.particles.reduce(0) { $0 + $1.alpha } / Float(expected)
                let gpuAlpha = states.reduce(0) { $0 + $1.alphaRotation.x } / Float(states.count)
                if !(abs(cpuAlpha - gpuAlpha) <= 0.02) {
                    failures.append("\(label): mean alpha \(gpuAlpha) on the GPU, \(cpuAlpha) on the CPU")
                }
            }
        }
        print("Particle simulation sweep: \(systems) systems (\(children) children), \(particles) GPU particles after 90 frames, \(failures.count) failures")
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }
}
