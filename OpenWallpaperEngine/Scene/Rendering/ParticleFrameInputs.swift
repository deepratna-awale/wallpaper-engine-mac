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
    var drag: Float = 0
    var fadeIn: Float = 0
    var fadeOut: Float = 1
    /// The system emits nothing and shows nothing this frame: every particle is removed.
    var clears = false
    /// Particles emitted at once this step on top of the rate: the emitter's `instantaneous`
    /// burst on the system's first step.
    var burst = 0
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
                        emitter: SceneAffineTransform? = nil) -> ParticleFrameInputs {
        let configuration = system.configuration
        system.elapsedTime += deltaTime
        system.frameIndex &+= 1
        var inputs = ParticleFrameInputs()
        inputs.deltaTime = deltaTime
        inputs.elapsedTime = system.elapsedTime
        inputs.frameIndex = system.frameIndex
        let world = emitter ?? configuration.authoredWorld
        inputs.motion = motion(of: system, to: world)
        let time = Double(system.elapsedTime)
        inputs.emissionRate = configuration.emissionRateScript.map {
            AudioReactiveScriptEngine.shared.evaluate($0, fallback: configuration.emissionRate, time: time)
        } ?? configuration.emissionRate
        inputs.burst = system.frameIndex == 1 ? max(configuration.instantaneous, 0) : 0
        // Without a rate a system only shows its burst, if it has one.
        let idle = inputs.emissionRate <= 0.0001 && configuration.instantaneous <= 0
        if idle || configuration.opacityMultiplier <= 0.0001 {
            inputs.clears = true
            inputs.fadeIn = system.fadeIn
            inputs.fadeOut = system.fadeOut
            return inputs
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
        inputs.place(configuration, in: SceneParticleEmitterSpace(world: world), cursor: cursor)
        return inputs
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
        } else {
            spawnOrigin = origin
        }
        if let attractor = configuration.attractor {
            attractorOrigin = configuration.cursorControlPoint.map { cursor + $0.offset } ?? origin + attractor.offset
        }
        if let span = configuration.sequenceSpan {
            sequenceStart = Self.controlPointPosition(span.startControlPoint, configuration: configuration,
                                                      space: space, cursor: cursor)
            sequenceEnd = Self.controlPointPosition(span.endControlPoint, configuration: configuration,
                                                    space: space, cursor: cursor)
        }
        if let remap = configuration.initialRemap {
            remapAnchor = Self.controlPointPosition(remap.controlPoint, configuration: configuration,
                                                    space: space, cursor: cursor)
        }
    }

    static func controlPointPosition(_ id: Int, configuration: SceneMetalParticleSystem,
                                     space: SceneParticleEmitterSpace, cursor: SIMD2<Float>) -> SIMD2<Float> {
        guard let point = configuration.controlPoints.first(where: { $0.id == id }) else {
            return space.origin
        }
        return (point.locksToCursor ? cursor : space.origin) + space.offset(point.offset)
    }
}
