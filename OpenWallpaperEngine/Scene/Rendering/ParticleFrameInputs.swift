import simd

/// What a particle system's simulation step reads from outside the particles: the time step,
/// script-evaluated values, the emitter's transform this frame and control points. Both
/// simulations (CPU and GPU) step from the same inputs, evaluated once per frame on the CPU.
struct ParticleFrameInputs {
    var deltaTime: Float = 0
    /// Seconds since the system started (after this step).
    var elapsedTime: Float = 0
    /// Steps taken, this one included; seeds per-frame random draws.
    var frameIndex: UInt32 = 0
    var emissionRate: Float = 0
    /// The most particles the system (each instance, when instanced) may hold: the authored
    /// maximum times the `count` override.
    var maximum = 0
    /// The instance overrides spawned particles take: size, alpha, lifetime and speed factors.
    var spawnScale = SIMD4<Float>(repeating: 1)
    /// The overrides' tint times brightness, on spawned particles' colour.
    var colorScale = SIMD3<Float>(repeating: 1)
    /// Audio responses (`ParticleAudioResponse`): of an audio-responsive `turbulentvelocityrandom`,
    /// of `turbulence`'s and `vortex`'s speeds. 1 without one.
    var audioVelocityScale: Float = 1
    var turbulenceScale: Float = 1
    var vortexScale: Float = 1
    /// Collision shapes in scene space this step, in operator order.
    var collisions: [ParticleCollisionPlacement] = []
    var drag: Float = 0
    var fadeIn: Float = 0
    var fadeOut: Float = 1
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
    /// Where particles spawn: the emitter, or its cursor-locked control point.
    var spawnOrigin = SIMD2<Float>.zero
    var attractorOrigin = SIMD2<Float>.zero
    /// `mapsequencebetweencontrolpoints` end points, when the system has a sequence.
    var sequenceStart: SIMD2<Float>?
    var sequenceEnd: SIMD2<Float>?
    /// `remapinitialvalue`'s control point.
    var remapAnchor = SIMD2<Float>.zero

    // The emitter's space this frame (`SceneParticleEmitterSpace` of its live transform).
    /// Scales the spawn shape's emitter-space extent.
    var extentScale = SIMD2<Float>(1, 1)
    /// Places emitter-space offsets given y down (position offsets, control points).
    var offsetLinear = matrix_identity_float2x2
    /// Turns emitter-space velocities into scene space.
    var velocityRotation = matrix_identity_float2x2
    /// Gravity in scene space.
    var gravity = SIMD2<Float>.zero
    var vortexOrigin = SIMD2<Float>.zero
    var reductionOrigin = SIMD2<Float>.zero
    var constraintOrigin = SIMD2<Float>.zero
    /// Points that come from the cursor rather than the emitter: they stay put in every instance
    /// of an instanced system (`placed(at:)`).
    var absolutePoints: AbsolutePoints = []

    struct AbsolutePoints: OptionSet {
        let rawValue: UInt32
        static let spawnOrigin = AbsolutePoints(rawValue: 1 << 0), attractor = AbsolutePoints(rawValue: 1 << 1)
        static let sequenceStart = AbsolutePoints(rawValue: 1 << 2), sequenceEnd = AbsolutePoints(rawValue: 1 << 3)
        static let remapAnchor = AbsolutePoints(rawValue: 1 << 4)
    }

    /// How the emitter moved since the last step, for systems whose particles live in its space:
    /// applied to every particle alive before this step's spawns. Nil when it did not move.
    var motion: SceneAffineTransform?

    /// The particle size factor of `motion`: its area scale's square root.
    var motionScale: Float {
        guard let motion else { return 1 }
        return sqrt(abs(simd_determinant(motion.linear)))
    }

    /// The turn of `motion`, counter-clockwise in radians, which particles' own rotation takes.
    var motionAngle: Float {
        guard let motion else { return 0 }
        return atan2(motion.linear.columns.0.y, motion.linear.columns.0.x)
    }

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
        inputs.frameIndex = system.frameIndex
        let world = emitter ?? childEmitter(system) ?? configuration.authoredWorld
        inputs.motion = motion(of: system, to: world)
        let time = Double(system.elapsedTime)
        inputs.applyOverrides(configuration, values: values ?? LiveSceneValueContext(time: time, scriptTime: time))
        let rate = configuration.emissionRate * inputs.overrideRate
        inputs.emissionRate = configuration.emissionRateScript.map {
            AudioReactiveScriptEngine.shared.evaluate($0, fallback: rate, time: time)
        } ?? rate
        // Without a rate a system only shows its burst, if it has one.
        let idle = inputs.emissionRate <= 0.0001 && configuration.instantaneous <= 0
        if idle || configuration.opacityMultiplier <= 0.0001 {
            inputs.clears = true
            inputs.fadeIn = system.fadeIn
            inputs.fadeOut = system.fadeOut
            return inputs
        }
        let timing = configuration.emitterTiming
        inputs.periodLimit = timing.periodLimit(countScale: inputs.overrideCount)
        inputs.onePerFrame = timing.onePerFrame
        // An instanced system times each instance instead (`ParticleCPUSimulation.updateInstances`).
        if !configuration.isInstanced {
            let step = system.emitterClock.advance(deltaTime, timing: timing, seed: system.seed, key: 0)
            inputs.burst = step.bursts ? max(configuration.instantaneous, 0) : 0
            inputs.startsPeriod = step.startsPeriod
            if !step.emits { inputs.emissionRate = 0 }
        }
        inputs.drag = configuration.dragScript.map {
            AudioReactiveScriptEngine.shared.evaluate($0, fallback: configuration.drag, time: time)
        } ?? configuration.drag
        system.fadeIn = configuration.fadeInScript.map {
            AudioReactiveScriptEngine.shared.evaluate($0, fallback: configuration.fadeIn, time: time)
        } ?? configuration.fadeIn
        system.fadeOut = configuration.fadeOutScript.map {
            AudioReactiveScriptEngine.shared.evaluate($0, fallback: configuration.fadeOut, time: time)
        } ?? configuration.fadeOut
        inputs.fadeIn = system.fadeIn
        inputs.fadeOut = system.fadeOut
        // Silence stops an audio-responsive emitter without clearing what it emitted.
        if let response = configuration.rateAudio { inputs.emissionRate *= response.response(audio) }
        inputs.audioVelocityScale = configuration.velocityAudio?.response(audio) ?? 1
        inputs.turbulenceScale = configuration.turbulenceAudio?.response(audio) ?? 1
        inputs.vortexScale = configuration.vortexAudio?.response(audio) ?? 1
        let space = SceneParticleEmitterSpace(world: world)
        inputs.place(configuration, in: space, cursor: cursor)
        inputs.collisions = configuration.collisions.flatMap { collision in
            collision.placed(in: space) { id in
                controlPointPosition(id, configuration: configuration, space: space, cursor: cursor)
            }
        }
        return inputs
    }

    /// The instance overrides' rate and count factors (`applyOverrides`).
    private var overrideRate: Float = 1
    private var overrideCount: Float = 1

    /// The system's instance overrides this frame: resolved again when bound to user properties.
    private mutating func applyOverrides(_ configuration: SceneMetalParticleSystem, values: SceneValueContext) {
        let overrides = configuration.liveOverrides.map { SceneParticleOverrides($0, in: values) } ?? configuration.overrides
        overrideRate = overrides.rate
        overrideCount = overrides.count
        maximum = max(Int((Float(configuration.maximumParticleCount) * overrides.count).rounded()), 0)
        // Negative multipliers would invert the ranges; WE treats them as 0.
        spawnScale = SIMD4(overrides.size, max(overrides.alpha, 0), max(overrides.lifetime, 0), overrides.speed)
        colorScale = configuration.keepsOwnColors ? SIMD3(repeating: 1) : overrides.tint * overrides.brightness
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

    /// The emitter-space values of `configuration` placed in `space`.
    private mutating func place(_ configuration: SceneMetalParticleSystem, in space: SceneParticleEmitterSpace,
                                cursor: SIMD2<Float>) {
        let origin = space.origin
        extentScale = space.world.axisScale
        offsetLinear = space.offsetLinear
        velocityRotation = space.rotation
        gravity = configuration.worldGravity ? configuration.gravity : space.direction(configuration.gravity)
        vortexOrigin = origin + (configuration.vortex?.offset ?? .zero)
        reductionOrigin = origin + (configuration.nearControlPointReduction?.offset ?? .zero)
        constraintOrigin = origin + (configuration.maintainControlPointDistance?.offset ?? .zero)
        if let controlPoint = configuration.cursorControlPoint, configuration.emitterControlPoint == controlPoint.id {
            spawnOrigin = cursor + controlPoint.offset
            absolutePoints.insert(.spawnOrigin)
        } else {
            spawnOrigin = origin
        }
        if let attractor = configuration.attractor {
            attractorOrigin = configuration.cursorControlPoint.map { cursor + $0.offset } ?? origin + attractor.offset
            if configuration.cursorControlPoint != nil { absolutePoints.insert(.attractor) }
        }
        func locked(_ id: Int) -> Bool { configuration.controlPoints.first { $0.id == id }?.locksToCursor == true }
        if let span = configuration.sequenceSpan {
            if locked(span.startControlPoint) { absolutePoints.insert(.sequenceStart) }
            if locked(span.endControlPoint) { absolutePoints.insert(.sequenceEnd) }
            sequenceStart = Self.controlPointPosition(span.startControlPoint, configuration: configuration,
                                                      space: space, cursor: cursor)
            sequenceEnd = Self.controlPointPosition(span.endControlPoint, configuration: configuration,
                                                    space: space, cursor: cursor)
        }
        if let remap = configuration.initialRemap {
            if locked(remap.controlPoint) { absolutePoints.insert(.remapAnchor) }
            remapAnchor = Self.controlPointPosition(remap.controlPoint, configuration: configuration,
                                                    space: space, cursor: cursor)
        }
    }

    /// These inputs for one instance of an instanced system, whose emitter sits at `translation`
    /// (on top of the shared emitter transform the inputs were placed with).
    func placed(at translation: SIMD2<Float>) -> ParticleFrameInputs {
        var inputs = self
        func shift(_ point: SIMD2<Float>, _ absolute: AbsolutePoints) -> SIMD2<Float> {
            absolutePoints.contains(absolute) ? point : point + translation
        }
        inputs.spawnOrigin = shift(spawnOrigin, .spawnOrigin)
        inputs.attractorOrigin = shift(attractorOrigin, .attractor)
        inputs.sequenceStart = sequenceStart.map { shift($0, .sequenceStart) }
        inputs.sequenceEnd = sequenceEnd.map { shift($0, .sequenceEnd) }
        inputs.remapAnchor = shift(remapAnchor, .remapAnchor)
        inputs.vortexOrigin += translation
        inputs.reductionOrigin += translation
        inputs.constraintOrigin += translation
        inputs.collisions = collisions.map { $0.moved(by: translation) }
        return inputs
    }

    static func controlPointPosition(_ id: Int, configuration: SceneMetalParticleSystem,
                                     space: SceneParticleEmitterSpace, cursor: SIMD2<Float>) -> SIMD2<Float> {
        guard let point = configuration.controlPoints.first(where: { $0.id == id }) else {
            return space.origin
        }
        return (point.locksToCursor ? cursor : space.origin) + space.offset(point.offset)
    }
}
