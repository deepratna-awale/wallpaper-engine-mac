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
            Fixtures.removeStoredSettings(for: directory)
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
        let spawnVerbs = systems[2].program.initializers.filter { $0.kind == .inheritInitialValueFromEvent }
            .map { ParticleInheritance(rawValue: $0.record.header.y) }
        XCTAssertEqual(spawnVerbs, [.multiplySize, .setColor], "setcolor when no input is named")
        let stepVerbs = systems[2].program.operators.filter { $0.kind == .inheritValueFromEvent }
            .map { ParticleInheritance(rawValue: $0.record.header.y) }
        XCTAssertEqual(stepVerbs, [[.setColor, .setOpacity]], "setcoloropacity when no input is named")
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

    func testUnsupportedLinkFeaturesAreReported() throws {
        let json = "{\"children\": [{\"name\": \"b.json\", \"flags\": 1}, {\"name\": \"c.json\", \"type\": \"eventburst\"}]}"
        let parent = try JSONDecoder().decode(WEParticleSystem.self, from: Data(json.utf8))
        var reports: [String] = []
        let builder = ParticleFamilyBuilder(
            load: { $0 == "a.json" ? parent : WEParticleSystem() },
            build: { _, _, _, _ in ParticleTestSystem().configuration },
            report: { reports.append($0) })
        let family = builder.family("a.json", world: .identity, overrides: SceneParticleOverrides())
        XCTAssertEqual(family.count, 2)
        XCTAssertEqual(reports.count, 1, "an unknown type")
        XCTAssertEqual(family[1].link?.controlPointStart, 0, "control points from the parent's particles, from 0 by default")
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

    func testChildrenInheritFromTheirEventParticle() throws {
        var root = rocketTestSystem()
        root.minimumColor = SIMD4(0.1, 0.2, 0.3, 1)
        root.maximumColor = SIMD4(0.9, 0.8, 0.7, 1)
        var child = ParticleTestSystem()
        child.emissionRate = 30
        child.maximum = 20
        child.lifetime = 3...3
        child.inheritOnSpawn = [.setColor, .setVelocity, .multiplySize]
        child.inheritEachStep = [.setOpacity]
        let family = try Family(root: root, children: [(child.link(.follow, instances: 20, probability: 1), 0)])
        family.stepCPU(frames: 40, root: translation(SIMD2(500, 300)))
        let parent = family.runtimes[0], children = family.runtimes[1]
        XCTAssertGreaterThan(children.particles.count, 10)
        for particle in children.particles {
            let instance = children.instances[particle.instance]
            guard let source = parent.particles.first(where: { $0.serial == instance.sourceSerial }) else { continue }
            XCTAssertEqual(SIMD3(particle.color.x, particle.color.y, particle.color.z),
                           SIMD3(source.color.x, source.color.y, source.color.z), "colour at spawn")
            XCTAssertEqual(particle.alpha, source.alpha, accuracy: 1e-6, "opacity every step")
        }
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
        spark.emitterSpeed = SIMD2(50, 120)
        spark.maximum = 10
        var burst = spark
        burst.instantaneous = 12
        burst.maximum = 12
        burst.worldSpace = true
        trail.inheritOnSpawn = [.multiplyColor, .addVelocity, .setSize, .addRotation, .setAngularVelocity]
        trail.inheritEachStep = [.multiplyOpacity, .multiplySize, .setRotation]
        spark.inheritOnSpawn = [.setColor, .setOpacity]
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

    /// Each instance keeps its own emitter clock: a periodic follow child, and under it a delayed,
    /// time-limited static child that emits 8 a period (WE's thunderbolt beam).
    func testTimedChildInstancesRunTheSameOnTheGPU() throws {
        var trail = ParticleTestSystem()
        trail.emissionRate = 60
        trail.maximum = 30
        trail.lifetime = 0.3...0.6
        trail.instantaneous = 2
        trail.emitterTiming.periodic = true
        trail.emitterTiming.periodDuration = 0.1...0.3
        trail.emitterTiming.periodDelay = 0.05...0.2
        trail.emitterTiming.maximumPerPeriod = 6
        var beam = ParticleTestSystem()
        beam.emissionRate = 100
        beam.maximum = 16
        beam.lifetime = 0.6...0.6
        beam.emitterTiming.delay = 0.2
        beam.emitterTiming.duration = 1
        beam.emitterTiming.periodic = true
        beam.emitterTiming.periodDuration = 1...1
        beam.emitterTiming.periodDelay = 9999...9999
        beam.emitterTiming.maximumPerPeriod = 8
        let links: [(ParticleTestSystem.Linked, Int)] = [
            (trail.link(.follow, instances: 6, probability: 1), 0),
            (beam.link(.static, instances: 6, probability: 1, instanced: true), 1),
        ]
        let cpu = try Family(root: rocketTestSystem(), children: links)
        let gpu = try Family(root: rocketTestSystem(), children: links)
        cpu.stepCPU(frames: 90, root: translation(SIMD2(500, 300)))
        try gpu.stepGPU(frames: 90, root: translation(SIMD2(500, 300)))
        for index in cpu.runtimes.indices {
            let expected = cpu.runtimes[index].particles
            let actual = gpu.simulator.snapshot(gpu.runtimes[index], queue: gpu.queue)
            XCTAssertEqual(actual.map(\.identity.x), expected.map(\.serial), "system \(index): the same particles")
            let instances: [Int] = actual.map { Int($0.trail.z) }
            XCTAssertEqual(instances, expected.map(\.instance), "system \(index)")
        }
        let beams = cpu.runtimes[2].particles
        XCTAssertGreaterThan(beams.count, 0)
        for slot in 0..<6 {
            XCTAssertLessThanOrEqual(beams.filter { $0.instance == slot }.count, 8, "8 a period, one period")
        }
    }

    /// Each instance runs every emitter of the child, each on its own clock (WE's dripping-water
    /// droplets have two).
    func testChildInstancesRunEveryEmitterTheSameOnTheGPU() throws {
        var drops = ParticleTestSystem()
        drops.emissionRate = 40
        drops.maximum = 40
        drops.lifetime = 0.3...0.6
        var second = ParticleEmitter(rate: 70)
        second.instantaneous = 3
        second.shape.distanceMaximum = SIMD3(repeating: 10)
        second.timing.periodic = true
        second.timing.periodDuration = 0.1...0.2
        second.timing.periodDelay = 0.05...0.1
        second.timing.maximumPerPeriod = 5
        drops.extraEmitters = [second]
        var sequence = ParticleInitializer(.mapSequenceAroundControlPoint, flags: 2, a: SIMD4(0.125, 0, 1, 0))
        sequence.sequenceCount = 8
        drops.initializers = [sequence]
        let links: [(ParticleTestSystem.Linked, Int)] = [(drops.link(.follow, instances: 6, probability: 1), 0)]
        let cpu = try Family(root: rocketTestSystem(), children: links)
        let gpu = try Family(root: rocketTestSystem(), children: links)
        cpu.stepCPU(frames: 90, root: translation(SIMD2(500, 300)))
        try gpu.stepGPU(frames: 90, root: translation(SIMD2(500, 300)))
        let expected = cpu.runtimes[1].particles
        let actual = gpu.simulator.snapshot(gpu.runtimes[1], queue: gpu.queue)
        XCTAssertGreaterThan(expected.count, 20)
        XCTAssertEqual(actual.map(\.identity.x), expected.map(\.serial), "the same particles")
        XCTAssertEqual(actual.map { Int($0.trail.z) }, expected.map(\.instance))
        for (a, e) in zip(actual, expected) {
            XCTAssertLessThan(simd_distance(SIMD2(a.positionVelocity.x, a.positionVelocity.y), e.position), 0.05)
        }
    }

    /// WE's thunderbolt: each spawner instance flies one particle off the bolt, and a static child of
    /// it draws a beam from the instance to that particle through its control point 1 (link flag 1,
    /// start index 1).
    func testLinkedControlPointsFollowTheParentsParticles() throws {
        let links = thunderboltLinks()
        let cpu = try Family(root: rocketTestSystem(), children: links)
        let gpu = try Family(root: rocketTestSystem(), children: links)
        for _ in 0..<40 {
            cpu.stepCPU(frames: 1, root: translation(SIMD2(500, 300)))
            // Beam particles spawned this step lie between their instance and its spawner's particle.
            let beams = cpu.runtimes[2]
            for particle in beams.particles where particle.age <= 1 / 60 + 1e-4 {
                let start = beams.instances[particle.instance].translation
                let points = ParticleControlPointLink.positions(for: beams, slot: particle.instance)
                let end = try XCTUnwrap(points.first, "the spawner instance has its particle")
                XCTAssertEqual(points, cpu.runtimes[1].particles.filter { $0.instance == particle.instance }.map(\.position))
                let t = simd_dot(particle.position - start, end - start) / max(simd_length_squared(end - start), 1e-6)
                let closest = start + (end - start) * min(max(t, 0), 1)
                XCTAssertLessThan(simd_distance(particle.position, closest), 1e-2)
            }
        }
        XCTAssertGreaterThan(cpu.runtimes[2].particles.count, 0)
        try gpu.stepGPU(frames: 40, root: translation(SIMD2(500, 300)))
        for index in cpu.runtimes.indices {
            let expected = cpu.runtimes[index].particles
            let actual = gpu.simulator.snapshot(gpu.runtimes[index], queue: gpu.queue)
            XCTAssertEqual(actual.map(\.identity.x), expected.map(\.serial), "system \(index)")
            for (a, e) in zip(actual, expected) {
                XCTAssertLessThan(simd_distance(SIMD2(a.positionVelocity.x, a.positionVelocity.y), e.position), 0.05,
                                  "system \(index)")
            }
        }
    }

    /// An instanced rope draws one strand per instance: no segment joins two instances' particles,
    /// on the CPU and the GPU.
    func testAnInstancedRopeDrawsOneStrandPerInstance() throws {
        let links = thunderboltLinks()
        let cpu = try Family(root: rocketTestSystem(), children: links)
        let gpu = try Family(root: rocketTestSystem(), children: links)
        cpu.stepCPU(frames: 40, root: translation(SIMD2(500, 300)))
        try gpu.stepGPU(frames: 40, root: translation(SIMD2(500, 300)), kinds: [2: .rope])
        let beams = cpu.runtimes[2]
        let count = ParticleRecordWriter.recordCount(beams, format: .rope)
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: max(count, 1) * ParticleVertexFormat.rope.stride,
                                                       alignment: 16)
        defer { pointer.deallocate() }
        ParticleRecordWriter.write(beams, format: .rope, count: count, into: pointer) { _ in 1 }
        let expected = Array(UnsafeBufferPointer(start: pointer.bindMemory(to: ParticleRopeSegmentInstance.self,
                                                                           capacity: count), count: count))
        let strands = ParticleRopeStrands(beams.particles)
        var drawn = 0
        for (index, record) in expected.enumerated() {
            guard let next = strands.next[index] else {
                XCTAssertEqual(record.start.w, 0, "the end of a strand joins nothing")
                continue
            }
            drawn += 1
            XCTAssertEqual(beams.particles[index].instance, beams.particles[next].instance)
            XCTAssertEqual(SIMD2(record.end.x, record.end.y), beams.particles[next].position)
            XCTAssertEqual(Int(record.end.w), beams.particles.filter { $0.instance == beams.particles[index].instance }.count)
        }
        XCTAssertGreaterThan(drawn, 0)
        XCTAssertLessThan(drawn, count, "more than one strand")
        let actual = gpu.simulator.records(gpu.runtimes[2], as: ParticleRopeSegmentInstance.self, queue: gpu.queue).records
        XCTAssertEqual(actual.count, expected.count)
        for (a, e) in zip(actual, expected) {
            XCTAssertLessThan(simd_distance(a.start, e.start), 0.05)
            XCTAssertLessThan(simd_distance(a.end, e.end), 0.05)
            XCTAssertLessThan(simd_distance(a.previous, e.previous), 0.05)
            XCTAssertLessThan(simd_distance(a.next, e.next), 0.05)
        }
    }

    /// WE's thunderbolt children: a follow spawner flying one particle off each rocket, and under it
    /// a beam, a rope from the spawner instance to that particle through control point 1.
    private func thunderboltLinks() -> [(ParticleTestSystem.Linked, Int)] {
        var spawner = ParticleTestSystem()
        spawner.emissionRate = 0
        spawner.instantaneous = 1
        spawner.maximum = 1
        spawner.spawnExtent = .zero
        spawner.minimumVelocity = SIMD2(200, 50)
        spawner.maximumVelocity = SIMD2(200, 50)
        spawner.lifetime = 2...2
        var beam = ParticleTestSystem()
        beam.emissionRate = 120
        beam.maximum = 8
        beam.spawnExtent = .zero
        beam.minimumVelocity = .zero
        beam.maximumVelocity = .zero
        beam.lifetime = 0.5...0.5
        beam.rendererName = "rope"
        var sequence = ParticleInitializer(.mapSequenceBetweenControlPoints, controlPoints: 0 | 1 << 8, a: SIMD4(0, 0, 1, 0))
        sequence.sequenceCount = 8
        beam.initializers = [sequence]
        var beamLink = beam.link(.static, instances: 4, probability: 1, instanced: true)
        beamLink.controlPointStart = 1
        return [(spawner.link(.follow, instances: 4, probability: 1), 0), (beamLink, 1)]
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

    /// `kinds`: what the step writes records for, by system (the built-in sprite otherwise).
    func stepGPU(frames: Int, root: (Int) -> SceneAffineTransform, kinds: [Int: ParticleGPUDrawKind] = [:]) throws {
        var last: MTLCommandBuffer?
        for _ in 0..<frames {
            let requests = runtimes.enumerated().map { index, runtime in
                ParticleGPUSimulator.Request(system: runtime, inputs: inputs(runtime, root: root),
                                             kind: kinds[index] ?? .fallbackSprite, materialVertexCount: 6)
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
