import Metal
import simd

struct Particle {
    /// In the scene.
    var position: SIMD2<Float>
    var velocity: SIMD2<Float>
    var age: Float
    var lifetime: Float
    /// WE's size: the full width of the particle's quad.
    var size: Float
    var baseSize: Float
    var alpha: Float
    var baseAlpha: Float
    var rotation: Float
    var angularVelocity: Float
    var color: SIMD4<Float>
    var baseColor: SIMD4<Float>
    let spriteFrame: Int
    var history: [SIMD2<Float>]
    var historyStart: Int
    var historyTimer: Float = 0
    /// Spawn order within the system; with the system's seed it names the particle's random draws.
    var serial: UInt32 = 0
    /// The instance it belongs to, in an instanced system (`ParticleChildLink`).
    var instance: Int = 0

    /// `history` is a circular buffer; this returns it oldest-first so a trail can be walked.
    var orderedHistory: [SIMD2<Float>] {
        guard historyStart > 0, historyStart < history.count else { return history }
        return Array(history[historyStart...] + history[..<historyStart])
    }
}

final class ParticleSystemRuntime {
    let texture: MTLTexture
    /// Texture 0 for the built-in draw (`SceneMetalParticleSystem.fallbackSource`); `texture`
    /// when it samples that as it is.
    let fallbackTexture: MTLTexture
    let configuration: SceneMetalParticleSystem
    var particles: [Particle] = []
    var emissionRemainder: Float = 0
    var elapsedTime: Float = 0
    /// Steps taken (`ParticleFrameInputs.frameIndex`).
    var frameIndex: UInt32 = 0
    /// The next particle's serial number: particles spawned so far.
    var nextSerial: UInt32 = 0
    /// The serial of the first spawn of the current emission period: the `mapsequence…`
    /// initializers that restart with each period count from it.
    var periodSerial: UInt32 = 0
    /// Seeds every random draw of this system (`ParticleRandom`).
    let seed: UInt32
    /// The system's state on the GPU, when `ParticleGPUSimulator` runs it.
    var gpu: ParticleGPUSystem?
    /// The emitter's world transform at the last step (`ParticleFrameInputs.motion`).
    var lastEmitter: SceneAffineTransform?
    /// The control points in the scene at the last step (a child's flag 4 control points copy them).
    var lastControlPoints = [SIMD2<Float>](repeating: .zero, count: ParticleControlPoint.count)
    /// The control points in the system's space at the last step.
    var previousControlPoints: [SIMD2<Float>]?
    /// The emitter's scale, rotation and shear the particles are drawn through
    /// (`ParticleFrameInputs.drawLinear`), from the last step.
    var drawLinear = matrix_identity_float2x2
    /// The emitter's timing (`ParticleEmitterTiming`) for a system that isn't instanced.
    var emitterClock = ParticleEmitterClock()
    /// What the rate emitted in the current period (`ParticleFrameInputs.periodLimit`), on the CPU.
    var periodEmitted = 0
    /// The system this one is a child of (`SceneMetalParticleSystem.link`).
    weak var parent: ParticleSystemRuntime?
    /// An instanced system's instances (`ParticleChildLink`), on the CPU.
    var instances: [ParticleInstance] = []
    /// A parent's particles spawned and died in its last CPU step, in array order, for its event
    /// children.
    var spawnedThisStep: [Particle] = []
    var diedThisStep: [Particle] = []

    init(texture: MTLTexture, configuration: SceneMetalParticleSystem, seed: UInt32 = 0,
         fallbackTexture: MTLTexture? = nil) {
        self.texture = texture
        self.fallbackTexture = fallbackTexture ?? texture
        self.configuration = configuration
        self.seed = seed
        if configuration.isInstanced {
            instances = Array(repeating: ParticleInstance(), count: max(configuration.link?.maximumInstances ?? 0, 0))
        }
    }

    /// Points each child at its parent (`SceneMetalParticleSystem.link`), in a scene's list of
    /// systems; a system that couldn't be prepared is nil and leaves its children without one.
    static func linkFamilies(_ systems: [ParticleSystemRuntime?]) {
        for system in systems {
            guard let system, let parentIndex = system.configuration.link?.parentIndex,
                  systems.indices.contains(parentIndex) else { continue }
            system.parent = systems[parentIndex]
        }
    }
}

/// The particle simulation on the CPU, in `wallpaper64.exe`'s order (0x140236cd0): every particle
/// ages by the step and those past their lifetime die (0x140236d91), the emitter spawns and the
/// initializers run on the new particles (0x1402378a0), then the operators run over all of them
/// (0x14023fbc0). `ParticleSimulation.metal` runs the same step on the GPU; the two must stay in
/// step (`ParticleSimulationParityTests`).
enum ParticleCPUSimulation {
    static func update(_ particleSystems: [ParticleSystemRuntime], deltaTime: Float, cursor: SIMD2<Float>) {
        let signpost = OWESignpost.begin(OWESignpost.render, "updateParticles")
        defer { signpost.end() }
        for system in particleSystems {
            step(system, inputs: ParticleFrameInputs.advance(system, deltaTime: deltaTime, cursor: cursor))
        }
    }

    /// How many particles to spawn this step, as WE counts them (0x1402379aa…0x140237b74): the
    /// burst, then the rate's whole particles (at most `rateLimit`). The burst is taken out of the
    /// carried fraction too, and a system already at its maximum takes nothing from the rate.
    /// Spawns a full system can't take are skipped, not queued.
    static func emission(liveCount: Int, maximum: Int, rate: Float, deltaTime: Float,
                         remainder: inout Float, burst: Int = 0, rateLimit: Int = .max) -> (burst: Int, rate: Int) {
        let available = max(maximum - liveCount, 0)
        let burst = max(burst, 0)
        guard liveCount < maximum else { return (min(burst, available), 0) }
        remainder += max(rate, 0) * deltaTime
        var count = 0
        if remainder >= 1 {
            count = Int(min(remainder.rounded(.down), 2_147_483_520))
            remainder -= Float(count) + Float(burst)
            count = min(count, max(rateLimit, 0))
        } else {
            remainder -= Float(burst)
        }
        let taken = min(burst, available)
        return (taken, min(count, available - taken))
    }

    static func step(_ system: ParticleSystemRuntime, inputs frame: ParticleFrameInputs) {
        let configuration = system.configuration
        let start = configuration.link?.controlPointStart
        var inputs = frame
        if let start, !configuration.isInstanced {
            inputs = frame.linked(ParticleControlPointLink.positions(for: system, slot: 0), start: start)
        }
        system.spawnedThisStep.removeAll(keepingCapacity: true)
        system.diedThisStep.removeAll(keepingCapacity: true)
        if inputs.clears {
            system.particles.removeAll(keepingCapacity: true)
            system.emissionRemainder = 0
            system.periodEmitted = 0
            for index in system.instances.indices { system.instances[index] = ParticleInstance() }
            return
        }
        age(system, deltaTime: inputs.deltaTime)
        let firstSerial = system.nextSerial
        var instanceInputs: [ParticleFrameInputs] = []
        if configuration.isInstanced {
            countInstanceParticles(system)
            updateInstances(system, inputs: inputs)
            instanceInputs = system.instances.enumerated().map { slot, instance in
                let placed = inputs.placed(at: instance.translation, previous: instance.previousTranslation)
                guard let start else { return placed }
                return placed.linked(ParticleControlPointLink.positions(for: system, slot: slot), start: start)
            }
            if !configuration.worldSpace {
                for index in system.particles.indices {
                    let instance = system.instances[system.particles[index].instance]
                    followInstance(&system.particles[index], instance: instance, inputs: inputs)
                }
            }
            for (index, instance) in system.instances.enumerated() where instance.spawnCount > 0 {
                for k in 0..<instance.spawnCount {
                    let sequence = SIMD2(instance.spawned &+ UInt32(k), instance.spawned &+ UInt32(k) &- instance.periodSpawned)
                    system.particles.append(spawn(serial: system.nextSerial, system: system, inputs: instanceInputs[index],
                                                  instance: index, source: instance, sequence: sequence))
                    system.nextSerial &+= 1
                }
                system.instances[index].spawned &+= UInt32(instance.spawnCount)
            }
        } else {
            if let motion = inputs.motion {
                for index in system.particles.indices { follow(&system.particles[index], motion: motion) }
            }
            if inputs.startsPeriod {
                system.periodEmitted = 0
                system.periodSerial = system.nextSerial
            }
            let limit = ParticleEmitterClock.rateLimit(periodLimit: inputs.periodLimit, emitted: system.periodEmitted,
                                                       onePerFrame: inputs.onePerFrame)
            let emitted = emission(liveCount: system.particles.count, maximum: inputs.maximum,
                                   rate: inputs.emissionRate, deltaTime: inputs.deltaTime,
                                   remainder: &system.emissionRemainder, burst: inputs.burst, rateLimit: limit)
            system.periodEmitted += emitted.rate
            for _ in 0..<(emitted.burst + emitted.rate) {
                let serial = system.nextSerial
                system.particles.append(spawn(serial: serial, system: system, inputs: inputs,
                                              sequence: SIMD2(serial, serial &- system.periodSerial)))
                system.nextSerial &+= 1
            }
        }
        let neighbors = ParticleProgramCPU.Neighbors(positions: system.particles.map(\.position),
                                                     velocities: system.particles.map(\.velocity),
                                                     serials: system.particles.map(\.serial), frame: inputs.frameIndex)
        for index in system.particles.indices {
            let instance = system.particles[index].instance
            let own = instanceInputs.isEmpty ? inputs : instanceInputs[instance]
            let source = instanceInputs.isEmpty ? nil : system.instances[instance]
            advance(&system.particles[index], index: index, system: system, inputs: own, source: source,
                    neighbors: neighbors)
            if let source, source.clearing { system.particles[index].age = .infinity }
        }
        if configuration.hasEventChildren {
            for particle in system.particles where particle.serial &- firstSerial < system.nextSerial &- firstSerial {
                system.spawnedThisStep.append(particle)
            }
        }
        // A cleared instance's particles go with it.
        system.particles.removeAll { $0.age == .infinity }
        if configuration.isInstanced { countInstanceParticles(system) }
    }

    /// Ages every particle by the step; those past their lifetime die (0x140236d91).
    static func age(_ system: ParticleSystemRuntime, deltaTime: Float) {
        for index in system.particles.indices { system.particles[index].age += deltaTime }
        if system.configuration.hasEventChildren {
            system.diedThisStep = system.particles.filter { $0.lifetime < $0.age }
        }
        system.particles.removeAll { $0.lifetime < $0.age }
    }

    /// Carries a particle that lives in its emitter's space along with the emitter's move. Its size
    /// and rotation stay the emitter's own: it is drawn through the emitter's transform
    /// (`ParticleSystemRuntime.drawLinear`).
    static func follow(_ particle: inout Particle, motion: SceneAffineTransform) {
        particle.position = motion.apply(particle.position)
        particle.velocity = motion.linear * particle.velocity
        for sample in particle.history.indices {
            particle.history[sample] = motion.apply(particle.history[sample])
        }
    }

    /// The program's view of the step for particle `serial`.
    static func context(_ system: ParticleSystemRuntime, inputs: ParticleFrameInputs, serial: UInt32,
                        source: ParticleInstance?) -> ParticleProgramContext {
        var context = ParticleProgramContext()
        context.deltaTime = inputs.deltaTime
        context.engineTime = inputs.engineTime
        context.systemTime = inputs.elapsedTime
        context.timeOfDay = inputs.timeOfDay
        context.seed = system.seed
        context.serial = serial
        context.random = ParticleRandom.unit(seed: system.seed, serial: serial, stream: ParticleRandom.Stream.operator.rawValue)
        context.controlPoints = inputs.controlPoints
        context.previousControlPoints = inputs.previousControlPoints
        context.space = inputs.space
        context.toSpace = inputs.toSpace
        context.worldSpace = system.configuration.worldSpace
        context.emitterLinear = inputs.emitterLinear
        context.collisions = inputs.collisions
        context.source = source
        context.spawnScale = inputs.spawnScale
        return context
    }

    /// A new particle: the emitter's shape, WE's base values and every initializer
    /// (0x14023b340: lifetime 1, size 0.5, the instance colour and alpha).
    static func spawn(serial: UInt32, system: ParticleSystemRuntime, inputs: ParticleFrameInputs, instance: Int = 0,
                      source: ParticleInstance? = nil, sequence: SIMD2<UInt32>) -> Particle {
        let configuration = system.configuration
        var context = context(system, inputs: inputs, serial: serial, source: source)
        context.sequenceIndex = sequence.x
        context.sequenceRestartIndex = sequence.y
        var state = ParticleProgramState()
        state.lifetime = 1
        state.baseSize = 0.5
        state.baseAlpha = inputs.spawnScale.y
        state.baseColor = inputs.colorScale
        let emitted = ParticleProgramCPU.emit(configuration.emitter, context: context)
        state.position = emitted.position
        state.velocity = emitted.velocity
        ParticleProgramCPU.runInitializers(inputs.initializers, on: &state, context: context)
        // A worldspace particle leaves the emitter's space: it takes the emitter's scale and turn now.
        let size = state.baseSize * inputs.spawnSizeScale
        let color = SIMD4(state.baseColor, 1)
        return Particle(
            position: inputs.space.apply(state.position), velocity: inputs.space.linear * state.velocity,
            age: 0, lifetime: state.lifetime, size: size, baseSize: size, alpha: state.baseAlpha, baseAlpha: state.baseAlpha,
            rotation: state.rotation + inputs.spawnTurn, angularVelocity: state.angularVelocity,
            color: color, baseColor: color,
            spriteFrame: ParticleRandom.index(configuration.spriteSheet?.frames ?? 1, seed: system.seed, serial: serial, .spriteFrame),
            history: [], historyStart: 0, serial: serial, instance: instance)
    }

    /// One step of every operator for the particle at `index`.
    static func advance(_ particle: inout Particle, index: Int, system: ParticleSystemRuntime, inputs: ParticleFrameInputs,
                        source: ParticleInstance?, neighbors: ParticleProgramCPU.Neighbors) {
        let configuration = system.configuration
        let context = context(system, inputs: inputs, serial: particle.serial, source: source)
        var state = ParticleProgramState()
        state.position = inputs.toSpace * (particle.position - inputs.space.translation)
        state.velocity = inputs.toSpace * particle.velocity
        state.age = particle.age
        state.lifetime = particle.lifetime
        state.baseSize = particle.baseSize
        state.baseAlpha = particle.baseAlpha
        state.baseColor = SIMD3(particle.baseColor.x, particle.baseColor.y, particle.baseColor.z)
        state.rotation = particle.rotation
        state.angularVelocity = particle.angularVelocity
        let dies = ParticleProgramCPU.runOperators(inputs.operators, on: &state, context: context, index: index,
                                                   neighbors: neighbors)
        particle.position = inputs.space.apply(state.position)
        particle.velocity = inputs.space.linear * state.velocity
        particle.lifetime = state.lifetime
        particle.size = state.size
        particle.alpha = state.alpha
        particle.color = SIMD4(state.color, particle.color.w)
        particle.rotation = state.rotation
        particle.angularVelocity = state.angularVelocity
        // A deleted particle dies when it next ages (WE sets its age to its lifetime).
        if dies { particle.age = particle.lifetime }
        // Only the ropetrail renderer reads history, and it wants samples spread over the
        // renderer's `length` in seconds rather than one per frame.
        if configuration.rendererName == "ropetrail" {
            let historyLimit = max(configuration.trailSegments, 1)
            let interval = max(configuration.trailLength, 0.001) / Float(historyLimit)
            particle.historyTimer += inputs.deltaTime
            if particle.historyTimer >= interval || particle.history.isEmpty {
                particle.historyTimer = 0
                if particle.history.count < historyLimit {
                    particle.history.append(particle.position)
                } else {
                    particle.history[particle.historyStart] = particle.position
                    particle.historyStart = (particle.historyStart + 1) % historyLimit
                }
            }
        }
    }
}

extension ParticleSystemRuntime {
    /// The factor on a trail's or rope's size (`ParticleFrameInputs.drawSizeScale`): the area scale
    /// of `drawLinear`, which WE's trail and rope shaders apply along directions of their own.
    /// Sprites take `drawLinear` whole and keep 1.
    var drawSizeScale: Float {
        let name = configuration.rendererName
        guard name.contains("trail") || name.hasPrefix("rope") else { return 1 }
        return sqrt(abs(simd_determinant(drawLinear)))
    }

    /// A built-in sprite's quad axes (`LayerUniform.quadAxisX`, y up) for a particle of `size` and
    /// `rotation` drawn through `drawLinear`, as WE's model matrix draws it. `scale` takes scene
    /// units to the target's pixels. `spriteAxes` in `ParticleShared.h` is the GPU's.
    func spriteAxes(size: Float, rotation: Float, scale: SIMD2<Float>) -> (x: SIMD2<Float>, y: SIMD2<Float>) {
        let c = cos(rotation), s = sin(rotation)
        // Rotated in the shader's y-down corner space, then flipped to y up.
        let x: SIMD2<Float> = drawLinear * (SIMD2(c, -s) * size)
        let y: SIMD2<Float> = drawLinear * (SIMD2(-s, -c) * size)
        return (x * scale, -y * scale)
    }
}
