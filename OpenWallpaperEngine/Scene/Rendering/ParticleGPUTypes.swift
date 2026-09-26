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
    /// History timer, -, instance.
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
    /// Source angular velocity.
    var emission: SIMD4<Float>
    /// Flags, source serial, live particles, first spawn.
    var state: SIMD4<UInt32>
    /// Spawned this step, spawned before it, the spawn its sequence restarts from.
    var spawn: SIMD4<UInt32>

    var flags: Flag { Flag(rawValue: state.x) }
}

/// The parent particles a linked child's control points take (`ParticleControlPointLink`), for one
/// instance: up to eight positions, oldest first, and how many.
struct ParticleGPULinkedPoints {
    var points0: SIMD4<Float>
    var points1: SIMD4<Float>
    var points2: SIMD4<Float>
    var points3: SIMD4<Float>
    /// Positions, -, -, -.
    var count: SIMD4<UInt32>
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
    /// Delta, system time, the damped step (`ParticleFrameInputs.dragDeltaTime`), engine time.
    var time: SIMD4<Float>
    /// Time of day, clears, -, -.
    var misc: SIMD4<Float>
    /// Scene size xy, render target size xy (the built-in draw's pixels).
    var scene: SIMD4<Float>
    /// Frame index, material vertex count, `g_RenderVar0` offset in floats (`noRenderVar`: none), draw kind.
    var indices: SIMD4<UInt32>
    /// `ParticleFrameInputs.space`: linear part, column 0 xy, column 1 xy; its translation xy and
    /// the motion's translation xy.
    var spaceLinear: SIMD4<Float>
    var spaceMotion: SIMD4<Float>
    /// The inverse of `space`'s linear part, column 0 xy, column 1 xy.
    var toSpace: SIMD4<Float>
    /// `ParticleFrameInputs.emitterLinear`, column 0 xy, column 1 xy.
    var emitterLinear: SIMD4<Float>
    /// The control points in the system's space, two per vector, and last step's.
    var controlPoints0: SIMD4<Float>
    var controlPoints1: SIMD4<Float>
    var controlPoints2: SIMD4<Float>
    var controlPoints3: SIMD4<Float>
    var previousControlPoints0: SIMD4<Float>
    var previousControlPoints1: SIMD4<Float>
    var previousControlPoints2: SIMD4<Float>
    var previousControlPoints3: SIMD4<Float>
    /// Motion linear part, column 0 xy, column 1 xy.
    var motionLinear: SIMD4<Float>
    /// Spawn size scale, spawn turn (`ParticleFrameInputs.spawnSizeScale`), has motion, trail and
    /// rope record size scale (`drawSizeScale`).
    var motionExtras: SIMD4<Float>
    /// `ParticleFrameInputs.absolutePoints`, maximum, collisions, initializers | operators << 16.
    var extra: SIMD4<UInt32>
    /// `ParticleFrameInputs.spawnScale`.
    var spawnScale: SIMD4<Float>
    /// `ParticleFrameInputs.colorScale`.
    var colorScale: SIMD4<Float>
    /// `ParticleFrameInputs.substeps`, emitters (`ParticleGPUEmitterStep`), -, -.
    var emission: SIMD4<UInt32>
    /// `ParticleFrameInputs.drawLinear`, column 0 xy, column 1 xy.
    var drawLinear: SIMD4<Float>

    static let noRenderVar = UInt32.max
    static let noLimit = UInt32.max

    init(_ inputs: ParticleFrameInputs, sceneSize: SIMD2<Float>, targetSize: SIMD2<Float>, kind: ParticleGPUDrawKind,
         materialVertexCount: Int, renderVarOffset: Int?) {
        time = SIMD4(inputs.deltaTime, inputs.elapsedTime, inputs.dragDeltaTime, inputs.engineTime)
        misc = SIMD4(inputs.timeOfDay, inputs.clears ? 1 : 0, 0, 0)
        scene = SIMD4(sceneSize.x, sceneSize.y, targetSize.x, targetSize.y)
        indices = SIMD4(inputs.frameIndex, UInt32(materialVertexCount),
                        renderVarOffset.map { UInt32($0 / 4) } ?? Self.noRenderVar, kind.rawValue)
        spaceLinear = Self.columns(inputs.space.linear)
        let motion = inputs.motion ?? .identity
        spaceMotion = SIMD4(inputs.space.translation.x, inputs.space.translation.y, motion.translation.x, motion.translation.y)
        toSpace = Self.columns(inputs.toSpace)
        emitterLinear = Self.columns(inputs.emitterLinear)
        func pair(_ points: [SIMD2<Float>], _ index: Int) -> SIMD4<Float> {
            SIMD4(points[index * 2].x, points[index * 2].y, points[index * 2 + 1].x, points[index * 2 + 1].y)
        }
        controlPoints0 = pair(inputs.controlPoints, 0)
        controlPoints1 = pair(inputs.controlPoints, 1)
        controlPoints2 = pair(inputs.controlPoints, 2)
        controlPoints3 = pair(inputs.controlPoints, 3)
        previousControlPoints0 = pair(inputs.previousControlPoints, 0)
        previousControlPoints1 = pair(inputs.previousControlPoints, 1)
        previousControlPoints2 = pair(inputs.previousControlPoints, 2)
        previousControlPoints3 = pair(inputs.previousControlPoints, 3)
        motionLinear = Self.columns(motion.linear)
        motionExtras = SIMD4(inputs.spawnSizeScale, inputs.spawnTurn, inputs.motion == nil ? 0 : 1, inputs.drawSizeScale)
        drawLinear = Self.columns(inputs.drawLinear)
        extra = SIMD4(inputs.absolutePoints, UInt32(clamping: inputs.maximum), UInt32(inputs.collisions.count),
                      UInt32(inputs.initializers.count) | UInt32(inputs.operators.count) << 16)
        spawnScale = inputs.spawnScale
        colorScale = SIMD4(inputs.colorScale, 1)
        emission = SIMD4(UInt32(inputs.substeps), UInt32(inputs.emitters.count), 0, 0)
    }

    static func columns(_ matrix: simd_float2x2) -> SIMD4<Float> {
        SIMD4(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.1.x, matrix.columns.1.y)
    }
}

/// A system's configuration as the GPU step reads it; built once per system.
struct ParticleGPUParameters {
    struct Flag: OptionSet {
        let rawValue: UInt32
        static let history = Flag(rawValue: 1 << 0)
        static let spriteSheet = Flag(rawValue: 1 << 2), instanced = Flag(rawValue: 1 << 3)
        static let worldSpace = Flag(rawValue: 1 << 4)
    }

    var counts = SIMD4<UInt32>.zero
    var trail = SIMD4<Float>.zero
    /// `spritetrail` maxlength, minlength.
    var trailLimits = SIMD4<Float>.zero
    var spriteSheet = SIMD4<Float>.zero
    var sprite = SIMD4<Float>.zero
    /// Link kind (0: none), instances, emitters (`ParticleGPUEmitter`), -.
    var instancing = SIMD4<UInt32>.zero
    /// Probability.
    var link = SIMD4<Float>.zero
    /// Linked (1), first control point, per parent instance (1).
    var linking = SIMD4<UInt32>.zero

    /// Samples each `ropetrail` particle keeps.
    var historyLimit: Int { Int(counts.w) }

    init(_ c: SceneMetalParticleSystem, seed: UInt32) {
        var flags: Flag = []
        let historyLimit = max(c.trailSegments, 1)
        if c.rendererName == "ropetrail" { flags.insert(.history) }
        let fades: Float = (c.fadeTrailAlpha ? 1 : 0) + (c.fadeTrailSize ? 2 : 0)
        trail = SIMD4(max(c.trailLength, 0.001) / Float(historyLimit), c.trailLength, Float(max(c.ropeSubdivision, 1)), fades)
        trailLimits = SIMD4(c.trailLengthLimits.x, c.trailLengthLimits.y, 0, 0)
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
            instancing = SIMD4(link.kind.rawValue, UInt32(clamping: link.maximumInstances), 0, 0)
            self.link = SIMD4(link.probability, 0, 0, 0)
        }
        instancing.z = UInt32(c.emitters.count)
        if let link = c.link, let start = link.controlPointStart {
            linking = SIMD4(1, UInt32(clamping: start), link.kind == .static && link.instanced ? 1 : 0, 0)
        }
        counts = SIMD4(UInt32(clamping: c.maximumParticleCount), flags.rawValue, seed, UInt32(historyLimit))
    }
}

/// One emitter of a system on the GPU (`ParticleEmitter`); a system's emitters are a buffer of them.
struct ParticleGPUEmitter {
    /// Origin xyz, control point.
    var origin: SIMD4<Float>
    /// Directions xyz, −cos(cone·π).
    var directions: SIMD4<Float>
    /// Distance minimum xyz, speed minimum.
    var minimum: SIMD4<Float>
    /// Distance maximum xyz, speed maximum.
    var maximum: SIMD4<Float>
    /// Sign xyz.
    var sign: SIMD4<Float>
    /// `ParticleEmitterTiming` (an instance's clock): delay, duration, periodic duration minimum
    /// and maximum; periodic delay minimum and maximum, periodic, -.
    var timing: SIMD4<Float>
    var period: SIMD4<Float>
    /// Box (1), applies its sign (1), `instantaneous`, -.
    var flags: SIMD4<UInt32>

    init(_ emitter: ParticleEmitter) {
        let shape = emitter.shape
        origin = SIMD4(shape.origin, Float(shape.controlPoint))
        directions = SIMD4(shape.directions, -cos(shape.cone * .pi))
        minimum = SIMD4(shape.distanceMinimum, shape.speed.x)
        maximum = SIMD4(shape.distanceMaximum, shape.speed.y)
        sign = SIMD4(shape.sign, 0)
        let timing = emitter.timing
        self.timing = SIMD4(timing.delay, timing.duration, timing.periodDuration.lowerBound, timing.periodDuration.upperBound)
        period = SIMD4(timing.periodDelay.lowerBound, timing.periodDelay.upperBound, timing.periodic ? 1 : 0, 0)
        flags = SIMD4(shape.kind == .box ? 1 : 0, shape.appliesSign ? 1 : 0, UInt32(clamping: max(emitter.instantaneous, 0)), 0)
    }
}

/// One emitter's part of a GPU step (`ParticleEmitterStep`).
struct ParticleGPUEmitterStep {
    /// Rate, -, -, -.
    var rate: SIMD4<Float>
    /// Burst, period limit (`ParticleGPUFrame.noLimit`: none), starts a period, one per frame.
    var control: SIMD4<UInt32>

    init(_ step: ParticleEmitterStep) {
        rate = SIMD4(step.rate, 0, 0, 0)
        control = SIMD4(UInt32(clamping: max(step.burst, 0)), step.periodLimit.map { UInt32(clamping: $0) } ?? ParticleGPUFrame.noLimit,
                        step.startsPeriod ? 1 : 0, step.onePerFrame ? 1 : 0)
    }
}

/// One emitter's running state on the GPU (`ParticleEmitterState`), for the system or one of its
/// instances: `slots × emitters` of them.
struct ParticleGPUEmitterState {
    /// `ParticleEmitterClock.state` (an instance's).
    var clock: SIMD4<Float>
    /// Carried fraction, -, -, -.
    var carry: SIMD4<Float>
    /// What the rate emitted this period (a system's), this step's first spawn and spawns (among the
    /// system's or the instance's), the spawn index its sequence restarts from.
    var counts: SIMD4<UInt32>
}
