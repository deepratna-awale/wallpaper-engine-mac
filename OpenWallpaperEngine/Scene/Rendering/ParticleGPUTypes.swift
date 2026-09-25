import simd

// The GPU simulation's shared structures; `ParticleSimulation.metal` declares the same layouts
// (`particleLayoutSizes` checks the sizes). Every field is a 16-byte vector so both sides agree.

/// One particle on the GPU (`Particle` on the CPU).
struct ParticleGPUState {
    /// Position xy, velocity zw.
    var positionVelocity: SIMD4<Float>
    /// Age, lifetime, size, base size.
    var life: SIMD4<Float>
    /// Alpha, base alpha, rotation, angular velocity.
    var alphaRotation: SIMD4<Float>
    var color: SIMD4<Float>
    var baseColor: SIMD4<Float>
    /// History timer, sequence, instance.
    var trail: SIMD4<Float>
    /// Serial, sprite frame, history count, history start.
    var identity: SIMD4<UInt32>
}

/// One instance of an instanced child system on the GPU (`ParticleInstance` on the CPU).
struct ParticleGPUInstance {
    struct Flag: OptionSet {
        let rawValue: UInt32
        static let active = Flag(rawValue: 1 << 0), emitting = Flag(rawValue: 1 << 1)
        static let fresh = Flag(rawValue: 1 << 2), clearing = Flag(rawValue: 1 << 3)
    }

    /// Translation xy, previous translation xy.
    var place: SIMD4<Float>
    /// Source velocity xy, size, rotation.
    var source: SIMD4<Float>
    /// Source colour and alpha.
    var sourceColor: SIMD4<Float>
    /// Source angular velocity, emission remainder.
    var emission: SIMD4<Float>
    /// Flags, source serial, live particles, first spawn.
    var state: SIMD4<UInt32>
    /// Spawned this step.
    var spawn: SIMD4<UInt32>

    var flags: Flag { Flag(rawValue: state.x) }
}

/// What a system's GPU records are drawn with this frame (`ParticleSimulation.metal`).
enum ParticleGPUDrawKind: UInt32 {
    /// WE material records (`ParticleVertexFormat`).
    case sprite = 0, rope, ropeTrail
    /// The renderer's built-in quads (`LayerUniform`).
    case fallbackSprite, fallbackSpriteTrail, fallbackRope, fallbackRopeTrail

    var isFallback: Bool { rawValue >= Self.fallbackSprite.rawValue }

    /// The material kind for `format` and the system's renderer.
    static func material(_ format: ParticleVertexFormat, rendererName: String) -> ParticleGPUDrawKind {
        switch format {
        case .sprite: return .sprite
        case .rope: return rendererName == "ropetrail" ? .ropeTrail : .rope
        }
    }

    /// The built-in draw's kind for a renderer, as `SceneMetalRenderer` picks it.
    static func fallback(rendererName: String) -> ParticleGPUDrawKind {
        if rendererName == "rope" { return .fallbackRope }
        if rendererName == "ropetrail" { return .fallbackRopeTrail }
        return rendererName.contains("trail") ? .fallbackSpriteTrail : .fallbackSprite
    }
}

/// Per-frame inputs of one system's GPU step (`ParticleFrameInputs`).
struct ParticleGPUFrame {
    /// Delta, elapsed, emission rate, drag.
    var time: SIMD4<Float>
    /// Fade in, fade out, clears, burst.
    var fade: SIMD4<Float>
    /// Spawn origin xy, attractor origin xy.
    var points: SIMD4<Float>
    /// Sequence start xy, end xy.
    var sequence: SIMD4<Float>
    /// Remap anchor xy, has sequence.
    var anchor: SIMD4<Float>
    /// Scene size xy, render target size xy (the built-in draw's pixels).
    var scene: SIMD4<Float>
    /// Frame index, material vertex count, `g_RenderVar0` offset in floats (`noRenderVar`: none), draw kind.
    var indices: SIMD4<UInt32>
    /// `ParticleFrameInputs.offsetLinear`, column 0 xy, column 1 xy.
    var offsetLinear: SIMD4<Float>
    /// `ParticleFrameInputs.velocityRotation`, column 0 xy, column 1 xy.
    var velocityRotation: SIMD4<Float>
    /// Gravity xy, extent scale xy.
    var gravityExtent: SIMD4<Float>
    /// Vortex origin xy, reduction origin xy.
    var origins: SIMD4<Float>
    /// Constraint origin xy, motion translation xy.
    var constraintMotion: SIMD4<Float>
    /// Motion linear part, column 0 xy, column 1 xy.
    var motionLinear: SIMD4<Float>
    /// Motion size scale, turn, has motion.
    var motionExtras: SIMD4<Float>
    /// `ParticleFrameInputs.absolutePoints`.
    var extra: SIMD4<UInt32>

    static let noRenderVar = UInt32.max

    init(_ inputs: ParticleFrameInputs, sceneSize: SIMD2<Float>, targetSize: SIMD2<Float>, kind: ParticleGPUDrawKind,
         materialVertexCount: Int, renderVarOffset: Int?) {
        time = SIMD4(inputs.deltaTime, inputs.elapsedTime, inputs.emissionRate, inputs.drag)
        fade = SIMD4(inputs.fadeIn, inputs.fadeOut, inputs.clears ? 1 : 0, Float(inputs.burst))
        points = SIMD4(inputs.spawnOrigin.x, inputs.spawnOrigin.y, inputs.attractorOrigin.x, inputs.attractorOrigin.y)
        let start = inputs.sequenceStart ?? .zero, end = inputs.sequenceEnd ?? .zero
        sequence = SIMD4(start.x, start.y, end.x, end.y)
        let hasSequence: Float = inputs.sequenceStart != nil && inputs.sequenceEnd != nil ? 1 : 0
        anchor = SIMD4(inputs.remapAnchor.x, inputs.remapAnchor.y, hasSequence, 0)
        scene = SIMD4(sceneSize.x, sceneSize.y, targetSize.x, targetSize.y)
        indices = SIMD4(inputs.frameIndex, UInt32(materialVertexCount),
                        renderVarOffset.map { UInt32($0 / 4) } ?? Self.noRenderVar, kind.rawValue)
        offsetLinear = Self.columns(inputs.offsetLinear)
        velocityRotation = Self.columns(inputs.velocityRotation)
        gravityExtent = SIMD4(inputs.gravity.x, inputs.gravity.y, inputs.extentScale.x, inputs.extentScale.y)
        origins = SIMD4(inputs.vortexOrigin.x, inputs.vortexOrigin.y, inputs.reductionOrigin.x, inputs.reductionOrigin.y)
        let motion = inputs.motion ?? .identity
        constraintMotion = SIMD4(inputs.constraintOrigin.x, inputs.constraintOrigin.y,
                                 motion.translation.x, motion.translation.y)
        motionLinear = Self.columns(motion.linear)
        motionExtras = SIMD4(inputs.motionScale, inputs.motionAngle, inputs.motion == nil ? 0 : 1, 0)
        extra = SIMD4(inputs.absolutePoints.rawValue, 0, 0, 0)
    }

    static func columns(_ matrix: simd_float2x2) -> SIMD4<Float> {
        SIMD4(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.1.x, matrix.columns.1.y)
    }
}

/// A system's configuration as the GPU step reads it; built once per system.
struct ParticleGPUParameters {
    struct Flag: OptionSet {
        let rawValue: UInt32
        static let turbulence = Flag(rawValue: 1 << 0), attractor = Flag(rawValue: 1 << 1)
        static let vortex = Flag(rawValue: 1 << 2), boids = Flag(rawValue: 1 << 3)
        static let reduction = Flag(rawValue: 1 << 4), constraint = Flag(rawValue: 1 << 5)
        static let maintainSequence = Flag(rawValue: 1 << 6), sizeChange = Flag(rawValue: 1 << 7)
        static let alphaChange = Flag(rawValue: 1 << 8), colorChange = Flag(rawValue: 1 << 9)
        static let oscillateSize = Flag(rawValue: 1 << 10), oscillateAlpha = Flag(rawValue: 1 << 11)
        static let oscillatePosition = Flag(rawValue: 1 << 12), remapAlpha = Flag(rawValue: 1 << 13)
        static let sequenceSpan = Flag(rawValue: 1 << 14), sequenceRing = Flag(rawValue: 1 << 15)
        static let initialRemap = Flag(rawValue: 1 << 16), history = Flag(rawValue: 1 << 17)
        static let boxEmitter = Flag(rawValue: 1 << 18), maximumSpeed = Flag(rawValue: 1 << 19)
        static let spriteSheet = Flag(rawValue: 1 << 20), instanced = Flag(rawValue: 1 << 21)
        static let worldSpace = Flag(rawValue: 1 << 22)
    }

    var counts = SIMD4<UInt32>.zero
    var lifetimeSize = SIMD4<Float>.zero
    var alphaRotation = SIMD4<Float>.zero
    var angularSpawn = SIMD4<Float>.zero
    var velocityRange = SIMD4<Float>.zero
    /// Emitter speed min, max, sign xy.
    var emitterShape = SIMD4<Float>.zero
    /// Minimum spawn radius ratio.
    var emitterRing = SIMD4<Float>.zero
    var colorMinimum = SIMD4<Float>.zero
    var colorMaximum = SIMD4<Float>.zero
    var offsetRange = SIMD4<Float>.zero
    var sequence = SIMD4<Float>.zero
    var ringAxisBounds = SIMD4<Float>.zero
    var ringSpeed = SIMD4<Float>.zero
    var initialRemap = SIMD4<Float>.zero
    /// Maximum speed, angular acceleration.
    var limits = SIMD4<Float>.zero
    var turbulence = SIMD4<Float>.zero
    var turbulenceMask = SIMD4<Float>.zero
    var attractor = SIMD4<Float>.zero
    /// Inner speed, outer speed, inner distance, outer distance.
    var vortex = SIMD4<Float>.zero
    var boids = SIMD4<Float>.zero
    /// Inner distance, outer distance, reduction; constraint strength.
    var reduction = SIMD4<Float>.zero
    var sizeChange = SIMD4<Float>.zero
    var alphaChange = SIMD4<Float>.zero
    var colorChangeTime = SIMD4<Float>.zero
    var colorChangeStart = SIMD4<Float>.zero
    var colorChangeEnd = SIMD4<Float>.zero
    var oscillateSize = SIMD4<Float>.zero
    var oscillateAlpha = SIMD4<Float>.zero
    var oscillatePosition = SIMD4<Float>.zero
    var remapAlpha = SIMD4<Float>.zero
    var trail = SIMD4<Float>.zero
    var spriteSheet = SIMD4<Float>.zero
    var sprite = SIMD4<Float>.zero
    /// Link kind (0: none), instances, -, instantaneous.
    var instancing = SIMD4<UInt32>.zero
    /// Probability.
    var link = SIMD4<Float>.zero

    /// Samples each `ropetrail` particle keeps.
    var historyLimit: Int { Int(counts.w) }

    init(_ c: SceneMetalParticleSystem, seed: UInt32) {
        var flags: Flag = []
        let historyLimit = max(c.trailSegments, 1)
        if c.rendererName == "ropetrail" { flags.insert(.history) }
        if c.emitterName == "boxrandom" { flags.insert(.boxEmitter) }
        lifetimeSize = SIMD4(c.lifetime.lowerBound, c.lifetime.upperBound, c.size.lowerBound, c.size.upperBound)
        alphaRotation = SIMD4(c.alpha.lowerBound, c.alpha.upperBound, c.minimumRotation, c.maximumRotation)
        angularSpawn = SIMD4(c.minimumAngularVelocity, c.maximumAngularVelocity, c.spawnExtent.x, c.spawnExtent.y)
        velocityRange = SIMD4(c.minimumVelocity.x, c.minimumVelocity.y, c.maximumVelocity.x, c.maximumVelocity.y)
        emitterShape = SIMD4(c.emitterSpeed.lowerBound, c.emitterSpeed.upperBound, c.emitterSign.x, c.emitterSign.y)
        emitterRing = SIMD4(min(max(c.minimumSpawnRatio, 0), 1), 0, 0, 0)
        colorMinimum = c.minimumColor
        colorMaximum = c.maximumColor
        offsetRange = SIMD4(c.positionOffsetMinimum.x, c.positionOffsetMinimum.y,
                            c.positionOffsetMaximum.x, c.positionOffsetMaximum.y)
        if let span = c.sequenceSpan {
            flags.insert(.sequenceSpan)
            sequence = SIMD4(Float(span.count), span.arcAmount, span.mirrored ? 1 : 0, 0)
        }
        if let ring = c.sequenceRing {
            flags.insert(.sequenceRing)
            sequence.w = ring.turns
            ringAxisBounds = SIMD4(ring.axis.x, ring.axis.y, ring.bounds.lowerBound, ring.bounds.upperBound)
            ringSpeed = SIMD4(ring.minimumSpeed.x, ring.minimumSpeed.y, ring.maximumSpeed.x, ring.maximumSpeed.y)
        }
        if let remap = c.initialRemap {
            flags.insert(.initialRemap)
            let output: Float
            switch remap.output {
            case .size: output = 0
            case .alpha: output = 1
            case .velocity: output = 2
            }
            initialRemap = SIMD4(remap.rangeMinimum, remap.rangeMaximum, remap.multiply ? 1 : 0, output)
        }
        limits = SIMD4(c.maximumSpeed ?? 0, c.angularAcceleration, 0, 0)
        if c.maximumSpeed != nil { flags.insert(.maximumSpeed) }
        if let value = c.turbulence {
            flags.insert(.turbulence)
            turbulence = SIMD4(value.scale, value.speed.lowerBound, value.speed.upperBound, value.timeScale)
            turbulenceMask = SIMD4(value.phase, value.mask.x, value.mask.y, 0)
        }
        if let value = c.attractor {
            flags.insert(.attractor)
            attractor = SIMD4(value.strength, value.threshold, 0, 0)
        }
        if let value = c.vortex {
            flags.insert(.vortex)
            vortex = SIMD4(value.innerSpeed, value.outerSpeed, value.innerDistance, value.outerDistance)
        }
        if let value = c.boids {
            flags.insert(.boids)
            boids = SIMD4(value.alignment, value.cohesion, value.separation, value.threshold)
        }
        if let value = c.nearControlPointReduction {
            flags.insert(.reduction)
            reduction.x = value.innerDistance
            reduction.y = value.outerDistance
            reduction.z = value.reduction
        }
        if let value = c.maintainControlPointDistance {
            flags.insert(.constraint)
            reduction.w = value.strength
        }
        if c.maintainSequenceDistance { flags.insert(.maintainSequence) }
        if let change = c.sizeChange {
            flags.insert(.sizeChange)
            sizeChange = SIMD4(change.startTime, change.endTime, change.startValue, change.endValue)
        }
        if let change = c.alphaChange {
            flags.insert(.alphaChange)
            alphaChange = SIMD4(change.startTime, change.endTime, change.startValue, change.endValue)
        }
        if let change = c.colorChange {
            flags.insert(.colorChange)
            colorChangeTime = SIMD4(change.startTime, change.endTime, 0, 0)
            colorChangeStart = change.startValue
            colorChangeEnd = change.endValue
        }
        func oscillation(_ value: ParticleOscillation) -> SIMD4<Float> {
            SIMD4(value.frequency.middle, value.scale.middle, value.phase.middle, 0)
        }
        if let value = c.oscillateSize { flags.insert(.oscillateSize); oscillateSize = oscillation(value) }
        if let value = c.oscillateAlpha { flags.insert(.oscillateAlpha); oscillateAlpha = oscillation(value) }
        if let value = c.oscillatePosition { flags.insert(.oscillatePosition); oscillatePosition = oscillation(value) }
        if let remap = c.remapAlpha {
            flags.insert(.remapAlpha)
            remapAlpha = SIMD4(remap.scale, remap.outputMinimum, remap.outputMaximum, remap.sine ? 1 : 0)
        }
        let fades: Float = (c.fadeTrailAlpha ? 1 : 0) + (c.fadeTrailSize ? 2 : 0)
        trail = SIMD4(max(c.trailLength, 0.001) / Float(historyLimit), c.trailLength, Float(max(c.ropeSubdivision, 1)), fades)
        if let sheet = c.spriteSheet {
            flags.insert(.spriteSheet)
            spriteSheet = SIMD4(Float(sheet.frames), Float(sheet.columns), Float(sheet.rows), sheet.duration)
        } else {
            spriteSheet = SIMD4(1, 1, 1, 1)
        }
        let mode: Float
        switch c.animationMode {
        case "randomframe": mode = 2
        case "once": mode = 1
        default: mode = 0
        }
        sprite = SIMD4(mode, c.sequenceMultiplier, c.opacityMultiplier, c.refractive ? 1 : 0)
        if c.worldSpace { flags.insert(.worldSpace) }
        if let link = c.link, link.instanced {
            flags.insert(.instanced)
            instancing = SIMD4(link.kind.rawValue, UInt32(clamping: link.maximumInstances), 0,
                               UInt32(clamping: max(c.instantaneous, 0)))
            self.link = SIMD4(link.probability, 0, 0, 0)
        }
        counts = SIMD4(UInt32(clamping: c.maximumParticleCount), flags.rawValue, seed, UInt32(historyLimit))
    }
}
