import simd

/// What a particle system's simulation step reads from outside the particles: the time step,
/// script-evaluated values, the system's space this frame, control points and the encoded
/// program. Both simulations (CPU and GPU) step from the same inputs, evaluated once per frame on
/// the CPU.
///
/// WE simulates a system in its object's space unless the system is `worldspace` (flag 1), and
/// draws it through the object's model matrix (`wallpaper64.exe` 0x14023761b…0x14023767a; the
/// particle vertex shaders expand in that space). The particles here are kept in the scene;
/// `space` takes the system's space to the scene, and every initializer and operator runs in the
/// system's space (`ParticleProgramCPU`, `ParticleProgram.h`), so velocities, gravity and every
/// distance scale and turn with the object as they do in WE.
struct ParticleFrameInputs {
    var deltaTime: Float = 0
    /// Seconds since the system started (after this step): WE's system time.
    var elapsedTime: Float = 0
    /// Seconds since the scene started: WE's engine time, which `turbulence`,
    /// `turbulentvelocityrandom` and `positionoffsetrandom` read.
    var engineTime: Float = 0
    /// The fraction of the day that has passed (`remapvalue`'s `timeofday`).
    var timeOfDay: Float = 0
    /// Steps taken, this one included.
    var frameIndex: UInt32 = 0
    var emissionRate: Float = 0
    /// The most particles the system (each instance, when instanced) may hold: the authored
    /// maximum times the `count` override.
    var maximum = 0
    /// The instance overrides spawned particles take: size, alpha, lifetime and speed factors.
    var spawnScale = SIMD4<Float>(repeating: 1)
    /// The overrides' tint times brightness: spawned particles' base colour.
    var colorScale = SIMD3<Float>(repeating: 1)
    /// Collision shapes in the scene this step (`ParticleOperatorKind.collision` records index them).
    var collisions: [ParticleCollisionPlacement] = []
    /// The system emits nothing and shows nothing this frame: every particle is removed.
    var clears = false
    /// Particles emitted at once this step on top of the rate: the emitter's `instantaneous`
    /// burst when it starts or starts a period (`ParticleEmitterClock`).
    var burst = 0
    /// A period of a periodic emitter starts this step: the per-period count restarts.
    var startsPeriod = false
    /// The most the rate emits in one period (`ParticleEmitterTiming.periodLimit`), for the system
    /// or each instance; nil without a limit.
    var periodLimit: Int?
    /// The rate emits at most one particle a step.
    var onePerFrame = false

    /// The system's space in the scene: the emitter's transform, identity for a `worldspace`
    /// system (which simulates in the scene).
    var space = SceneAffineTransform.identity
    /// The emitter's scale and rotation as the system's space sees them: identity for a system in
    /// its emitter's space, the emitter's own for a `worldspace` one. Spawn offsets and the
    /// velocity initializers turn with it (WE's control point matrix, 0x140237c14, 0x14023b364).
    var emitterLinear = matrix_identity_float2x2
    /// The control points in the system's space, by index, and where they were last step.
    var controlPoints = [SIMD2<Float>](repeating: .zero, count: ParticleControlPoint.count)
    var previousControlPoints = [SIMD2<Float>](repeating: .zero, count: ParticleControlPoint.count)
    /// Control points that sit in the scene (the cursor, scene-space and linked ones): an instance
    /// of an instanced system doesn't carry them (`placed(at:)`). Bit n is control point n.
    var absolutePoints: UInt32 = 0
    /// This step's program: every record with its scripts and audio evaluated.
    var initializers: [ParticleProgramOp] = []
    var operators: [ParticleProgramOp] = []

    /// How the emitter moved since the last step, for systems whose particles live in its space:
    /// applied to every particle alive before this step's spawns. Nil when it did not move.
    var motion: SceneAffineTransform?

    /// What the emitter's scale and rotation make of a spawned particle's size and rotation, for a
    /// `worldspace` system, whose particles leave its space when they spawn: the area scale's
    /// square root and the turn. A system whose particles stay in its space draws them through its
    /// transform instead (`drawLinear`), and keeps 1 and 0.
    var spawnSizeScale: Float = 1
    var spawnTurn: Float = 0

    /// The emitter's scale, rotation and shear its particles are drawn through, as WE draws a system
    /// through its model matrix: a sprite is squashed and turned with it
    /// (`ParticleSystemRuntime.drawLinear`). Identity for a `worldspace` system.
    var drawLinear = matrix_identity_float2x2
    /// The factor on the size of trail and rope records, whose width the shaders don't take from
    /// `drawLinear`: its area scale's square root (`ParticleSystemRuntime.drawSizeScale`).
    var drawSizeScale: Float = 1

    /// The system's space to the scene's inverse linear part (identity when it collapses).
    var toSpace: simd_float2x2 { space.inverse?.linear ?? matrix_identity_float2x2 }

    /// Advances `system`'s clock and evaluates this step's inputs. `emitter` is the emitter's
    /// world transform this frame; nil keeps the authored one.
    static func advance(_ system: ParticleSystemRuntime, deltaTime: Float, cursor: SIMD2<Float>,
                        emitter: SceneAffineTransform? = nil, values: SceneValueContext? = nil,
                        audio: AudioSpectrumSnapshot = .silent) -> ParticleFrameInputs {
        let configuration = system.configuration
        system.elapsedTime += deltaTime
        system.frameIndex &+= 1
        var inputs = ParticleFrameInputs()
        inputs.deltaTime = deltaTime
        inputs.elapsedTime = system.elapsedTime
        inputs.engineTime = values.map { Float($0.time) } ?? system.elapsedTime
        inputs.frameIndex = system.frameIndex
        inputs.timeOfDay = ParticleProgramCPU.fractionOfDay()
        let world = emitter ?? childEmitter(system) ?? configuration.authoredWorld
        inputs.motion = motion(of: system, to: world)
        let time = Double(system.elapsedTime)
        let context = values ?? LiveSceneValueContext(time: time, scriptTime: time)
        let overrides = inputs.applyOverrides(configuration, values: context)
        let rate = configuration.emissionRate * overrides.rate
        inputs.emissionRate = configuration.emissionRateScript.map {
            AudioReactiveScriptEngine.shared.evaluate($0, fallback: rate, time: time)
        } ?? rate
        // Without a rate a system only shows its burst, if it has one.
        let idle = inputs.emissionRate <= 0.0001 && configuration.instantaneous <= 0
        if idle || configuration.opacityMultiplier <= 0.0001 {
            inputs.clears = true
            return inputs
        }
        let timing = configuration.emitterTiming
        inputs.periodLimit = timing.periodLimit(countScale: overrides.count)
        inputs.onePerFrame = timing.onePerFrame
        // An instanced system times each instance instead (`ParticleCPUSimulation.updateInstances`).
        if !configuration.isInstanced {
            let step = system.emitterClock.advance(deltaTime, timing: timing, seed: system.seed, key: 0)
            inputs.burst = step.bursts ? max(configuration.instantaneous, 0) : 0
            inputs.startsPeriod = step.startsPeriod
            if !step.emits { inputs.emissionRate = 0 }
        }
        // Silence stops an audio-responsive emitter without clearing what it emitted.
        if let response = configuration.rateAudio { inputs.emissionRate *= response.response(audio) }
        inputs.space = configuration.worldSpace ? .identity : world
        inputs.emitterLinear = configuration.worldSpace ? world.linear : matrix_identity_float2x2
        if configuration.worldSpace {
            let linear = world.linear
            inputs.spawnSizeScale = sqrt(abs(simd_determinant(linear)))
            inputs.spawnTurn = atan2(linear.columns.0.y, linear.columns.0.x)
        }
        system.drawLinear = configuration.worldSpace ? matrix_identity_float2x2 : world.linear
        inputs.drawLinear = system.drawLinear
        inputs.drawSizeScale = system.drawSizeScale
        inputs.placeControlPoints(system, world: world, cursor: cursor, overrides: overrides)
        inputs.encodeProgram(system, time: time, audio: audio, countScale: overrides.count)
        return inputs
    }

    /// The system's instance overrides this frame, less the parts its flags switch off; bound to
    /// user properties, they resolve again.
    private mutating func applyOverrides(_ configuration: SceneMetalParticleSystem,
                                         values: SceneValueContext) -> SceneParticleOverrides {
        let authored = configuration.liveOverrides.map { SceneParticleOverrides($0, in: values) } ?? configuration.overrides
        let overrides = authored.ignoring(configuration.ignoredOverrides)
        maximum = max(Int((Float(configuration.maximumParticleCount) * overrides.count).rounded()), 0)
        // Negative multipliers would invert the ranges; WE treats them as 0.
        spawnScale = SIMD4(overrides.size, max(overrides.alpha, 0), max(overrides.lifetime, 0), overrides.speed)
        colorScale = configuration.keepsOwnColors ? SIMD3(repeating: 1) : overrides.tint * overrides.brightness
        return overrides
    }

    /// A child's emitter this frame: from its parent's, which stepped first.
    private static func childEmitter(_ system: ParticleSystemRuntime) -> SceneAffineTransform? {
        guard let link = system.configuration.link, let parent = system.parent else { return nil }
        return link.emitter(parent: parent.lastEmitter ?? parent.configuration.authoredWorld)
    }

    /// The emitter's move since the last step for a system whose particles follow it, and records
    /// `world` as the latest.
    private static func motion(of system: ParticleSystemRuntime, to world: SceneAffineTransform) -> SceneAffineTransform? {
        defer { system.lastEmitter = world }
        guard !system.configuration.worldSpace, let last = system.lastEmitter, last != world,
              let undo = last.inverse else { return nil }
        return world * undo
    }

    /// The control points this frame, as `wallpaper64.exe` 0x14022e3e0 updates them: on the
    /// cursor (flag 1), at a scene position (flag 2, control points 1…7), on the parent system's
    /// control point `parentcontrolpoint` (flag 4) or at their offset in the emitter's space. The
    /// object's `controlpoint<n>` override replaces the offset.
    private mutating func placeControlPoints(_ system: ParticleSystemRuntime, world: SceneAffineTransform,
                                             cursor: SIMD2<Float>, overrides: SceneParticleOverrides) {
        let configuration = system.configuration
        let toSpace = self.space.inverse ?? .identity
        let emitterToSpace = toSpace * world
        for index in 0..<ParticleControlPoint.count {
            let point = index < configuration.controlPoints.count ? configuration.controlPoints[index] : ParticleControlPoint()
            let offset = overrides.controlPoints[index].map { SIMD2($0.x, $0.y) } ?? point.offset
            let scene: SIMD2<Float>?
            if point.followsCursor {
                scene = cursor
            } else if point.worldSpace, index != 0 {
                scene = offset
            } else if let parentIndex = point.parentControlPoint, let parent = system.parent,
                      parentIndex >= 0, parentIndex < parent.lastControlPoints.count {
                scene = parent.lastControlPoints[parentIndex]
            } else {
                scene = nil
            }
            if let scene {
                controlPoints[index] = toSpace.apply(scene)
                absolutePoints |= 1 << UInt32(index)
            } else {
                controlPoints[index] = emitterToSpace.apply(offset)
            }
            system.lastControlPoints[index] = space.apply(controlPoints[index])
        }
        previousControlPoints = system.previousControlPoints ?? controlPoints
        system.previousControlPoints = controlPoints
        let simulationSpace = SceneParticleEmitterSpace(world: space)
        let points = controlPoints
        let spaceToScene = space
        collisions = configuration.program.operators.compactMap(\.collision).flatMap { collision in
            collision.placed(in: simulationSpace) { spaceToScene.apply(points[min(max($0, 0), 7)]) }
        }
    }

    /// This step's records: each with its scripts evaluated, its audio response and, for the
    /// `mapsequence…` initializers, the `count` override applied to their step.
    private mutating func encodeProgram(_ system: ParticleSystemRuntime, time: Double, audio: AudioSpectrumSnapshot,
                                        countScale: Float) {
        let program = system.configuration.program
        func evaluated(_ record: ParticleProgramOp, scripts: [ParticleValueScript]) -> ParticleProgramOp {
            var record = record
            for script in scripts {
                let fallback = record[script.vector, script.component]
                record[script.vector, script.component] = AudioReactiveScriptEngine.shared.evaluate(
                    script.script, fallback: fallback, time: time)
            }
            return record
        }
        var collision: UInt32 = 0
        operators = program.operators.map { element in
            var record = evaluated(element.record, scripts: element.scripts)
            if let response = element.audio { record.e.w = response.response(audio) }
            if element.kind == .collision {
                let count = element.collision?.placementCount ?? 0
                record.header.z = collision | (UInt32(count) << 16)
                collision += UInt32(count)
            }
            return record
        }
        initializers = program.initializers.map { element in
            var record = evaluated(element.record, scripts: element.scripts)
            if let response = element.audio { record.e.w = response.response(audio) }
            if let count = element.sequenceCount {
                let scaled = (record.header.y & ParticleProgramCPU.sequenceFollowsCountFlag(element.kind)) != 0
                    ? count * countScale : count
                let between = element.kind == .mapSequenceBetweenControlPoints
                record.a.x = 1 / max(between ? scaled - 1 : scaled, 0.0001)
            }
            return record
        }
    }

    /// These inputs for one instance of an instanced system, whose emitter sits at `translation`
    /// (on top of the shared emitter transform the inputs were placed with); it sat at `previous`
    /// last step.
    func placed(at translation: SIMD2<Float>, previous: SIMD2<Float>) -> ParticleFrameInputs {
        var inputs = self
        inputs.space.translation += translation
        let toSpace = self.toSpace
        for index in 0..<ParticleControlPoint.count where absolutePoints & (1 << UInt32(index)) != 0 {
            inputs.controlPoints[index] -= toSpace * translation
            inputs.previousControlPoints[index] -= toSpace * previous
        }
        inputs.collisions = collisions.map { $0.moved(by: translation) }
        return inputs
    }
}
