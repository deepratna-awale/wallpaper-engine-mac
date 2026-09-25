import simd

/// What a particle system's simulation step reads from outside the particles: the time step,
/// script-evaluated values and control points. Both simulations (CPU and GPU) step from the same
/// inputs, evaluated once per frame on the CPU.
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
    /// Where particles spawn: the emitter, or its cursor-locked control point.
    var spawnOrigin = SIMD2<Float>.zero
    var attractorOrigin = SIMD2<Float>.zero
    /// `mapsequencebetweencontrolpoints` end points, when the system has a sequence.
    var sequenceStart: SIMD2<Float>?
    var sequenceEnd: SIMD2<Float>?
    /// `remapinitialvalue`'s control point.
    var remapAnchor = SIMD2<Float>.zero

    /// Advances `system`'s clock and evaluates this step's inputs.
    static func advance(_ system: ParticleSystemRuntime, deltaTime: Float, cursor: SIMD2<Float>) -> ParticleFrameInputs {
        let configuration = system.configuration
        system.elapsedTime += deltaTime
        system.frameIndex &+= 1
        var inputs = ParticleFrameInputs()
        inputs.deltaTime = deltaTime
        inputs.elapsedTime = system.elapsedTime
        inputs.frameIndex = system.frameIndex
        let time = Double(system.elapsedTime)
        inputs.emissionRate = configuration.emissionRateScript.map {
            AudioReactiveScriptEngine.shared.evaluate($0, fallback: configuration.emissionRate, time: time)
        } ?? configuration.emissionRate
        if inputs.emissionRate <= 0.0001 || configuration.opacityMultiplier <= 0.0001 {
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
        if let controlPoint = configuration.cursorControlPoint, configuration.emitterControlPoint == controlPoint.id {
            inputs.spawnOrigin = cursor + controlPoint.offset
        } else {
            inputs.spawnOrigin = configuration.origin
        }
        if let attractor = configuration.attractor {
            inputs.attractorOrigin = configuration.cursorControlPoint.map { cursor + $0.offset } ?? attractor.origin
        }
        if let span = configuration.sequenceSpan {
            inputs.sequenceStart = controlPointPosition(span.startControlPoint, configuration: configuration, cursor: cursor)
            inputs.sequenceEnd = controlPointPosition(span.endControlPoint, configuration: configuration, cursor: cursor)
        }
        if let remap = configuration.initialRemap {
            inputs.remapAnchor = controlPointPosition(remap.controlPoint, configuration: configuration, cursor: cursor)
        }
        return inputs
    }

    static func controlPointPosition(_ id: Int, configuration: SceneMetalParticleSystem,
                                     cursor: SIMD2<Float>) -> SIMD2<Float> {
        guard let point = configuration.controlPoints.first(where: { $0.id == id }) else {
            return configuration.origin
        }
        return (point.locksToCursor ? cursor : configuration.origin) + point.offset
    }
}
