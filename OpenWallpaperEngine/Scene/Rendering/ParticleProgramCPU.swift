import simd

/// One particle as the program sees it: in the system's space (`ParticleFrameInputs.space`), y up.
/// `ParticleProgram.h` works on the same fields.
struct ParticleProgramState {
    var position = SIMD2<Float>.zero
    var velocity = SIMD2<Float>.zero
    /// Where the particle was before this step's `movement` (quad collisions and
    /// `controlpointattract`'s delete read it).
    var previous = SIMD2<Float>.zero
    var age: Float = 0
    var lifetime: Float = 1
    var size: Float = 0
    var baseSize: Float = 0
    var alpha: Float = 1
    var baseAlpha: Float = 1
    var rotation: Float = 0
    var angularVelocity: Float = 0
    var color = SIMD3<Float>(repeating: 1)
    var baseColor = SIMD3<Float>(repeating: 1)

    /// Age over lifetime.
    var lifeFraction: Float { age / max(lifetime, 0.001) }
}

/// What a record reads beyond the particle: the step, times, control points and the particle's
/// own random value.
struct ParticleProgramContext {
    var deltaTime: Float = 0
    /// The step damped at low frame rates (`ParticleFrameInputs.dragDeltaTime`): drag and the field
    /// operators' time step.
    var dragDeltaTime: Float = 0
    var engineTime: Float = 0
    var systemTime: Float = 0
    var timeOfDay: Float = 0
    var seed: UInt32 = 0
    var serial: UInt32 = 0
    /// WE's per-particle random (`wallpaper64.exe` [system+0x338]): the one value every operator
    /// of the particle reads.
    var random: Float = 0
    var controlPoints = [SIMD2<Float>](repeating: .zero, count: ParticleControlPoint.count)
    var previousControlPoints = [SIMD2<Float>](repeating: .zero, count: ParticleControlPoint.count)
    /// The system's space to the scene, and back.
    var space = SceneAffineTransform.identity
    var toSpace = matrix_identity_float2x2
    var worldSpace = false
    /// The emitter's scale and rotation in the system's space (`ParticleFrameInputs.emitterLinear`).
    var emitterLinear = matrix_identity_float2x2
    var collisions: [ParticleCollisionPlacement] = []
    /// The event's parent particle, for an instanced system's `inherit…fromevent`.
    var source: ParticleInstance?
    /// Instance overrides: size, alpha, lifetime and speed factors (`ParticleFrameInputs.spawnScale`).
    var spawnScale = SIMD4<Float>(repeating: 1)
    /// The particle object's position in the scene, for `remapvalue`'s `layerorigin` input
    /// (`ParticleFrameInputs.layerOrigin`).
    var layerOrigin = SIMD2<Float>.zero
    /// Spawn order of the particle among its system's (or instance's) spawns, and since the current
    /// emission period started, for the `mapsequence…` initializers.
    var sequenceIndex: UInt32 = 0
    var sequenceRestartIndex: UInt32 = 0
}

/// The program on the CPU: `wallpaper64.exe`'s initializer switch (0x14023b5c0) and operator VM
/// (0x14023fbc0), record by record in authored order. `ParticleProgram.h` is the GPU's copy;
/// change both together.
enum ParticleProgramCPU {
    // MARK: - Random streams

    /// Initializer `index`'s random draw `k` (WE draws them one after another from its generator).
    static func initializerStream(_ index: Int, _ k: Int) -> UInt32 { 64 + UInt32(index) * 16 + UInt32(k) }

    /// `pow(r, exponent)`, which WE skips for an exponent of exactly 1 (0x14023b5db).
    static func shaped(_ r: Float, _ exponent: Float) -> Float { exponent == 1 ? r : pow(r, exponent) }

    /// The flag that makes a sequence initializer follow the `count` override (0x1401ca184,
    /// 0x1401ca637).
    static func sequenceFollowsCountFlag(_ kind: ParticleInitializerKind) -> UInt32 {
        kind == .mapSequenceBetweenControlPoints ? 16 : 1
    }

    /// The flag that restarts a sequence with each period of a periodic emitter (0x14022f850).
    static func sequenceRestartsFlag(_ kind: ParticleInitializerKind) -> UInt32 {
        kind == .mapSequenceBetweenControlPoints ? 32 : 2
    }

    /// The sequence index `record` counts from.
    static func sequenceIndex(_ record: ParticleProgramOp, _ context: ParticleProgramContext) -> UInt32 {
        let kind = ParticleInitializerKind(rawValue: record.header.x) ?? .mapSequenceAroundControlPoint
        return record.header.y & sequenceRestartsFlag(kind) != 0 ? context.sequenceRestartIndex : context.sequenceIndex
    }

    // MARK: - Helpers

    static func saturate(_ value: Float) -> Float { min(max(value, 0), 1) }

    /// The blend window's factor at the particle's life fraction (0x14022a530).
    static func blendFactor(_ window: SIMD4<Float>, _ t: Float) -> Float {
        saturate((t - window.x) * window.y) * saturate((window.z - t) * window.w)
    }

    /// `(t − start) / (end − start)` clamped to 0…1, a step at `start` when the two are equal.
    static func progress(_ t: Float, _ start: Float, _ end: Float) -> Float {
        let span = end - start
        guard span != 0 else { return t >= start ? 1 : 0 }
        return saturate((t - start) / span)
    }

    static func cross(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> { simd_cross(a, b) }

    /// Hue in turns, saturation and value to RGB (0x1401b8c70).
    static func hsvToRGB(_ h: Float, _ s: Float, _ v: Float) -> SIMD3<Float> {
        let c = v * s
        let sector = fmod(h * 6, 6)
        let x = c * (1 - abs(fmod(sector, 2) - 1))
        let m = v - c
        let rgb: SIMD3<Float>
        if sector < 0 { rgb = .zero }
        else if sector < 1 { rgb = SIMD3(c, x, 0) }
        else if sector < 2 { rgb = SIMD3(x, c, 0) }
        else if sector < 3 { rgb = SIMD3(0, c, x) }
        else if sector < 4 { rgb = SIMD3(0, x, c) }
        else if sector < 5 { rgb = SIMD3(x, 0, c) }
        else { rgb = SIMD3(c, 0, x) }
        return rgb + m
    }

    /// `v` turned by `angle` about `axis` (0x1401e2500).
    static func rotate(_ v: SIMD3<Float>, about axis: SIMD3<Float>, by angle: Float) -> SIMD3<Float> {
        let length = simd_length(axis)
        guard length > 1e-6 else { return v }
        let k = axis / length
        let c = cos(angle), s = sin(angle)
        return v * c + simd_cross(k, v) * s + k * simd_dot(k, v) * (1 - c)
    }

    /// `axis` normalised (z when it is zero) and two unit vectors perpendicular to it
    /// (0x1401c19e0): `axis × z` and `axis × first`, or x and y for an axis along z.
    static func sequenceBasis(_ axis: SIMD3<Float>) -> (axis: SIMD3<Float>, first: SIMD3<Float>, second: SIMD3<Float>) {
        guard axis != .zero else { return (SIMD3(0, 0, 1), SIMD3(1, 0, 0), SIMD3(0, 1, 0)) }
        let unit = simd_normalize(axis)
        guard unit.x != 0 || unit.y != 0 else { return (unit, SIMD3(1, 0, 0), SIMD3(0, 1, 0)) }
        let first = simd_normalize(SIMD3(unit.y, -unit.x, 0))
        return (unit, first, simd_normalize(simd_cross(unit, first)))
    }

    /// A control point's position, clamped to the eight.
    static func point(_ points: [SIMD2<Float>], _ index: Int) -> SIMD2<Float> {
        points[min(max(index, 0), ParticleControlPoint.count - 1)]
    }

    // MARK: - Sequence

    /// Where the `index`-th spawn sits along a sequence of `step` (WE advances the position once
    /// per spawn, 0x14023c4cf / 0x14023ca93): `repeat` around a control point wraps with `fmod`
    /// (exactly 1 stays 1), between two restarts at 0, `mirror` walks back and forth.
    static func sequencePosition(index: UInt32, step: Float, mirror: Bool, between: Bool) -> Float {
        let travelled = Float(index) * step
        if mirror {
            let wrapped = fmod(travelled, 2)
            return 1 - abs(wrapped - 1)
        }
        if between {
            let slots = max(floor(1 / max(step, 1e-6) + 1e-4), 0) + 1
            return fmod(Float(index), slots) * step
        }
        guard travelled > 1 else { return travelled }
        let wrapped = travelled - floor(travelled)
        return wrapped == 0 ? 1 : wrapped
    }
}
