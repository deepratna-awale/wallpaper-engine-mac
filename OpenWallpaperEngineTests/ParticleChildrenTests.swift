import XCTest
import Metal
import simd
@testable import OpenWallpaperEngine

/// Child particle systems (`children`): decoding, how the loader flattens them, and how static and
/// event children run on the CPU and GPU.
final class ParticleChildrenTests: XCTestCase {
    private func particleSystem(_ name: String) throws -> WEParticleSystem {
        try JSONDecoder().decode(WEParticleSystem.self,
                                 from: Fixtures.data("Scenes/particle-children/particles/\(name).json"))
    }

    // MARK: - Format

    func testChildrenDecodeWithTheirLinkFields() throws {
        let rocket = try particleSystem("rocket")
        let children = try XCTUnwrap(rocket.children)
        XCTAssertEqual(children.map(\.type), [nil, "eventfollow", "eventspawn", "eventdeath"])
        XCTAssertEqual(children.map(\.name), ["particles/glow.json", "particles/trail.json",
                                              "particles/spark.json", "particles/burst.json"])
        XCTAssertEqual(children[0].origin?.vectorValue.1, 100)
        XCTAssertEqual(children[0].scale?.vectorValue.0, 2)
        XCTAssertEqual(children[0].angles?.vectorValue.2, 0.5)
        XCTAssertEqual(children[1].maxcount, 4)
        XCTAssertEqual(children[1].probability, 0.5)
        XCTAssertEqual(children[2].flags, 1)
        XCTAssertEqual(children[2].controlpointstartindex, 2)
        XCTAssertFalse(rocket.isWorldSpace)
    }

    func testEmitterBurstShapeAndSystemFlagsDecode() throws {
        let burst = try particleSystem("burst")
        XCTAssertTrue(burst.isWorldSpace)
        let emitter = try XCTUnwrap(burst.emitter?.first)
        XCTAssertEqual(emitter.instantaneous, 20)
        XCTAssertEqual(emitter.speedmin, 200)
        XCTAssertEqual(emitter.speedmax, 300)
        XCTAssertEqual(emitter.directions?.vectorValue.0, 1)
        XCTAssertEqual(emitter.directions?.vectorValue.2, 0)
        XCTAssertEqual(burst.operator?.first?.flags, 1, "movement: gravity in world space")
        XCTAssertEqual(burst.children?.count, 1, "children nest")
    }

    func testNullAndMissingLinkFieldsDecode() throws {
        let json = #"""
        {"children": [{"angles": "0 0 0", "controlpointstartindex": null, "flags": null, "id": 13,
                       "maxcount": 10, "name": "particles/a.json", "origin": "0 0 0", "probability": 1.0,
                       "scale": "1 1 1", "type": "static"},
                      {"name": "particles/b.json"}]}
        """#
        let system = try JSONDecoder().decode(WEParticleSystem.self, from: Data(json.utf8))
        XCTAssertEqual(system.children?.count, 2)
        XCTAssertNil(system.children?[0].controlpointstartindex)
        XCTAssertNil(system.children?[1].type)
    }

    // MARK: - Loading

    private func content() throws -> SceneMetalContent {
        let directory = Fixtures.url("Scenes/particle-children")
        let project = try JSONDecoder().decode(WEProject.self, from: Fixtures.data("Scenes/particle-children/project.json"))
        addTeardownBlock {
            for prefix in ["SceneUserProperties.", "SceneUserPropertiesExplicit.", "SceneAdditionalControlsVersion."] {
                UserDefaults.standard.removeObject(forKey: prefix + directory.path)
            }
        }
        return try XCTUnwrap(SceneWallpaperViewModel(wallpaper: WEWallpaper(using: project, where: directory)).metalContent())
    }

    func testTheLoaderFlattensAFamilyDepthFirst() throws {
        let systems = try content().particleSystems
        XCTAssertEqual(systems.count, 6, "rocket, glow, trail, spark, burst and burst's glow")
        XCTAssertEqual(systems.map { $0.link?.parentIndex }, [nil, 0, 0, 0, 0, 4])
        XCTAssertEqual(systems.map { $0.link?.kind }, [nil, .static, .follow, .spawn, .death, .static])
        XCTAssertEqual(systems.map(\.isInstanced), [false, false, true, true, true, true],
                       "a static child of an instanced system is instanced too")
        XCTAssertEqual(systems.map { $0.link?.maximumInstances }, [nil, 1, 4, 10, 3, 3])
        XCTAssertEqual(systems.map(\.objectID), ["5", nil, nil, nil, nil, nil])
        XCTAssertEqual(Set(systems.map(\.order)), [0])
        XCTAssertEqual(systems.map(\.hasEventChildren), [true, false, false, false, false, false])
        XCTAssertEqual(systems[2].link?.probability, 0.5)
        XCTAssertEqual(systems[3].instantaneous, 3)
        XCTAssertTrue(systems[4].worldSpace)
        // The static glow sits 100 units above the rocket's emitter, turned and doubled.
        let glow = systems[1].authoredWorld
        XCTAssertLessThan(simd_distance(glow.translation, SIMD2(500, 400)), 1e-3)
        XCTAssertEqual(glow.axisScale.x, 2, accuracy: 1e-5)
    }

    func testACycleOfChildrenIsReportedNotFollowed() throws {
        let cyclic = try JSONDecoder().decode(WEParticleSystem.self, from: Data(#"{"children": [{"name": "a.json"}]}"#.utf8))
        var reports: [String] = []
        let builder = ParticleFamilyBuilder(
            load: { _ in cyclic },
            build: { _, _, world, _ in
                var system = ParticleTestSystem().configuration
                system.emitterLinear = world.linear
                return system
            },
            report: { reports.append($0) })
        let family = builder.family("a.json", world: .identity, overrides: SceneParticleOverrides())
        XCTAssertEqual(family.count, 1)
        XCTAssertEqual(reports.count, 1)
    }

    // MARK: - Simulation

    func testAStaticChildEmitsFromItsParentsEmitterAndFollowsIt() throws {
        let family = try Family(root: rocketTestSystem(), children: [(staticGlow(), 0)])
        family.stepCPU(frames: 30, root: translation(SIMD2(500, 300)))
        let glow = family.runtimes[1]
        XCTAssertGreaterThan(glow.particles.count, 5)
        for particle in glow.particles { XCTAssertLessThan(simd_distance(particle.position, SIMD2(500, 400)), 1) }
        family.stepCPU(frames: 1, root: translation(SIMD2(700, 300)))
        for particle in glow.particles { XCTAssertLessThan(simd_distance(particle.position, SIMD2(700, 400)), 1) }
    }

    func testFollowInstancesTrackTheirParticleAndClearWithIt() throws {
        var trail = ParticleTestSystem()
        trail.emissionRate = 60
        trail.maximum = 50
        trail.spawnExtent = .zero
        trail.minimumVelocity = .zero
        trail.maximumVelocity = .zero
        trail.lifetime = 10...10
        let family = try Family(root: rocketTestSystem(), children: [(trail.link(.follow, instances: 4, probability: 1), 0)])
        family.stepCPU(frames: 20, root: translation(SIMD2(500, 300)))
        let parent = family.runtimes[0], child = family.runtimes[1]
        let active = child.instances.filter(\.active)
        XCTAssertEqual(active.count, min(parent.particles.count, 4))
        for instance in active {
            let source = try XCTUnwrap(parent.particles.first { $0.serial == instance.sourceSerial })
            XCTAssertEqual(instance.translation, source.position)
        }
        // Local-space trail particles move with their source.
        for particle in child.particles {
            let instance = child.instances[particle.instance]
            XCTAssertLessThan(simd_distance(particle.position, instance.translation), 1e-3)
        }
        // Parent particles live 1 s: their followers and their particles go with them.
        family.stepCPU(frames: 70, root: translation(SIMD2(500, 300)))
        let serials = Set(parent.particles.map(\.serial))
        for instance in child.instances where instance.active {
            XCTAssertTrue(serials.contains(instance.sourceSerial) || instance.clearing)
        }
        for particle in child.particles {
            XCTAssertTrue(serials.contains(child.instances[particle.instance].sourceSerial))
        }
    }

    func testSpawnAndDeathEventsBurstWhereTheParticleIs() throws {
        var spark = ParticleTestSystem()
        spark.emissionRate = 0
        spark.instantaneous = 3
        spark.maximum = 3
        spark.spawnExtent = .zero
        spark.minimumVelocity = .zero
        spark.maximumVelocity = .zero
        spark.lifetime = 5...5
        var burst = spark
        burst.instantaneous = 7
        burst.maximum = 7
        burst.worldSpace = true
        let family = try Family(root: rocketTestSystem(), children: [(spark.link(.spawn, instances: 100, probability: 1), 0),
                                                                    (burst.link(.death, instances: 100, probability: 1), 0)])
        family.stepCPU(frames: 90, root: translation(SIMD2(500, 300)))
        let parent = family.runtimes[0]
        let spawned = parent.nextSerial, died = spawned - UInt32(parent.particles.count)
        XCTAssertEqual(family.runtimes[1].particles.count, 3 * Int(spawned), "three sparks per rocket spawned")
        XCTAssertEqual(family.runtimes[2].particles.count, 7 * Int(died), "seven per rocket died")
        XCTAssertGreaterThan(died, 0)
        // Death bursts stay where their rocket died; the rockets rise at 400 units a second.
        for particle in family.runtimes[2].particles { XCTAssertGreaterThan(particle.position.y, 600) }
    }

    func testProbabilityAndTheInstanceBudgetLimitEvents() throws {
        var child = ParticleTestSystem()
        child.emissionRate = 0
        child.instantaneous = 1
        child.maximum = 1
        child.lifetime = 100...100
        var root = rocketTestSystem()
        root.emissionRate = 60
        root.maximum = 1000
        let half = try Family(root: root, children: [(child.link(.spawn, instances: 1000, probability: 0.5), 0)])
        half.stepCPU(frames: 120, root: translation(SIMD2(500, 300)))
        let ratio = Float(half.runtimes[1].particles.count) / Float(half.runtimes[0].nextSerial)
        XCTAssertEqual(ratio, 0.5, accuracy: 0.12)
        let capped = try Family(root: root, children: [(child.link(.spawn, instances: 5, probability: 1), 0)])
        capped.stepCPU(frames: 120, root: translation(SIMD2(500, 300)))
        XCTAssertEqual(capped.runtimes[1].instances.filter(\.active).count, 5)
        XCTAssertEqual(capped.runtimes[1].particles.count, 5)
    }

    // MARK: - GPU parity

    func testEventChildrenRunTheSameOnTheGPU() throws {
        var trail = ParticleTestSystem()
        trail.emissionRate = 40
        trail.maximum = 30
        trail.lifetime = 0.5...0.8
        trail.gravity = SIMD2(0, -100)
        var spark = trail
        spark.instantaneous = 5
        spark.emissionRate = 0
        spark.emitterSpeed = 50...120
        spark.maximum = 10
        var burst = spark
        burst.instantaneous = 12
        burst.maximum = 12
        burst.worldSpace = true
        var glow = trail
        glow.emissionRate = 20
        glow.maximum = 10
        let links: [(ParticleTestSystem.Linked, Int)] = [
            (staticGlow(), 0),
            (trail.link(.follow, instances: 6, probability: 0.7), 0),
            (spark.link(.spawn, instances: 20, probability: 1), 0),
            (burst.link(.death, instances: 4, probability: 1), 0),
            (glow.link(.static, instances: 4, probability: 1, instanced: true), 4),
        ]
        let moving: (Int) -> SceneAffineTransform = { frame in
            SceneAffineTransform(SceneLocalTransform(origin: SIMD2(400 + Float(frame) * 2, 300), scale: SIMD2(1, 1),
                                                     angle: Float(frame) * 0.01))
        }
        let cpu = try Family(root: rocketTestSystem(), children: links)
        let gpu = try Family(root: rocketTestSystem(), children: links)
        cpu.stepCPU(frames: 150, root: moving)
        try gpu.stepGPU(frames: 150, root: moving)
        for index in cpu.runtimes.indices {
            let expected = cpu.runtimes[index].particles
            let actual = gpu.simulator.snapshot(gpu.runtimes[index], queue: gpu.queue)
            XCTAssertEqual(actual.count, expected.count, "system \(index)")
            XCTAssertEqual(actual.map(\.identity.x), expected.map(\.serial), "system \(index): the same particles")
            guard actual.count == expected.count, !expected.isEmpty else { continue }
            for (a, e) in zip(actual, expected) {
                XCTAssertLessThan(simd_distance(SIMD2(a.positionVelocity.x, a.positionVelocity.y), e.position), 0.5,
                                  "system \(index)")
                XCTAssertEqual(Int(a.trail.z), e.instance, "system \(index)")
            }
            let gpuInstances = gpu.simulator.instances(gpu.runtimes[index], queue: gpu.queue)
            for (a, e) in zip(gpuInstances, cpu.runtimes[index].instances) {
                XCTAssertEqual(a.flags.contains(.active), e.active, "system \(index) instances")
                XCTAssertEqual(a.state.y, e.active ? e.sourceSerial : a.state.y, "system \(index) instances")
            }
        }
        XCTAssertGreaterThan(cpu.runtimes[3].particles.count, 0)
        XCTAssertGreaterThan(cpu.runtimes[4].particles.count, 0)
        XCTAssertGreaterThan(cpu.runtimes[5].particles.count, 0)
    }

    func testTheFixtureFamilyRunsTheSameOnTheGPU() throws {
        let systems = try content().particleSystems
        let cpu = try Family(systems)
        let gpu = try Family(systems)
        cpu.stepCPU(frames: 120, root: { _ in systems[0].authoredWorld })
        try gpu.stepGPU(frames: 120, root: { _ in systems[0].authoredWorld })
        for index in cpu.runtimes.indices {
            let actual = gpu.simulator.snapshot(gpu.runtimes[index], queue: gpu.queue)
            XCTAssertEqual(actual.map(\.identity.x), cpu.runtimes[index].particles.map(\.serial), "system \(index)")
        }
        XCTAssertGreaterThan(cpu.runtimes[4].particles.count, 0, "rockets burst")
        XCTAssertGreaterThan(cpu.runtimes[5].particles.count, 0, "bursts glow")
    }

    // MARK: - Helpers

    private func translation(_ point: SIMD2<Float>) -> (Int) -> SceneAffineTransform {
        { _ in SceneAffineTransform(linear: matrix_identity_float2x2, translation: point) }
    }

    /// Rockets: six a second, straight up at 400 units a second for a second.
    private func rocketTestSystem() -> ParticleTestSystem {
        var rocket = ParticleTestSystem()
        rocket.emissionRate = 6
        rocket.maximum = 20
        rocket.spawnExtent = .zero
        rocket.minimumVelocity = SIMD2(0, 400)
        rocket.maximumVelocity = SIMD2(0, 400)
        rocket.lifetime = 1...1
        return rocket
    }

    private func staticGlow() -> ParticleTestSystem.Linked {
        var glow = ParticleTestSystem()
        glow.emissionRate = 30
        glow.maximum = 40
        glow.spawnExtent = .zero
        glow.minimumVelocity = .zero
        glow.maximumVelocity = .zero
        glow.lifetime = 2...2
        return glow.link(.static, instances: 1, probability: 1, origin: SIMD2(0, 100))
    }
}

/// A particle system and its children stepped together, parents first, as the renderer does.
private final class Family {
    let runtimes: [ParticleSystemRuntime]
    let device: MTLDevice
    let queue: MTLCommandQueue
    let simulator: ParticleGPUSimulator

    convenience init(root: ParticleTestSystem, children: [(ParticleTestSystem.Linked, Int)]) throws {
        var systems = [root.configuration]
        for (child, parent) in children {
            var configuration = child.system.configuration
            configuration.link = child.link(parentIndex: parent, parent: systems[parent].link)
            systems[parent].hasEventChildren = systems[parent].hasEventChildren || child.kind != .static
            systems.append(configuration)
        }
        try self.init(systems)
    }

    init(_ systems: [SceneMetalParticleSystem]) throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        queue = try XCTUnwrap(device.makeCommandQueue())
        simulator = try ParticleGPUSimulator(device: device)
        let texture = try XCTUnwrap(device.makeTexture(descriptor: .texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)))
        runtimes = systems.enumerated().map { index, system in
            ParticleSystemRuntime(texture: texture, configuration: system, seed: ParticleRandom.pcg(UInt32(index)))
        }
        ParticleSystemRuntime.linkFamilies(runtimes)
    }

    private var frame = 0

    private func inputs(_ runtime: ParticleSystemRuntime, root: (Int) -> SceneAffineTransform) -> ParticleFrameInputs {
        ParticleFrameInputs.advance(runtime, deltaTime: 1 / 60, cursor: SIMD2(100, 100),
                                    emitter: runtime.configuration.link == nil ? root(frame) : nil)
    }

    func stepCPU(frames: Int, root: (Int) -> SceneAffineTransform) {
        for _ in 0..<frames {
            for runtime in runtimes { ParticleCPUSimulation.step(runtime, inputs: inputs(runtime, root: root)) }
            frame += 1
        }
    }

    func stepGPU(frames: Int, root: (Int) -> SceneAffineTransform) throws {
        var last: MTLCommandBuffer?
        for _ in 0..<frames {
            let requests = runtimes.map { runtime in
                ParticleGPUSimulator.Request(system: runtime, inputs: inputs(runtime, root: root), kind: .fallbackSprite)
            }
            let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
            simulator.encode(requests, sceneSize: SIMD2(1280, 720), targetSize: SIMD2(1280, 720), commandBuffer: commandBuffer)
            commandBuffer.commit()
            last = commandBuffer
            frame += 1
        }
        last?.waitUntilCompleted()
        XCTAssertNil(last?.error)
    }
}
