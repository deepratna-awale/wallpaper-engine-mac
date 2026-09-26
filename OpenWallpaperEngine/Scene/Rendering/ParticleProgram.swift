import simd

/// A particle system's operators and initializers, compiled the way WE compiles them: one record
/// per element, run in authored order. `wallpaper64.exe` builds two byte streams in its particle
/// parser (0x1401c1c70): initializers (opcodes 1…16, run per spawned particle by 0x14023b5c0) and
/// operators (opcodes 1…26, run once a frame over every particle by the operator VM 0x14023fbc0).
/// Two elements of the same kind are two records, each applied in turn.
///
/// The CPU (`ParticleProgramCPU`) and the GPU (`ParticleProgram.h`) interpret the same encoded
/// records (`ParticleProgramOp`), so the two simulations stay in step.
struct ParticleProgram: Equatable {
    var operators: [ParticleOperator] = []
    var initializers: [ParticleInitializer] = []

    /// The most records either list may hold; `ParticleProgram.h` sizes its buffers by it.
    static let capacity = 32

    /// A `remapvalue` writes a control point (its `controlpoint` output): the operators run record by
    /// record over every particle (`ParticleCPUSimulation.advanceOperatorMajor`).
    var operatorsWriteControlPoints: Bool {
        operators.contains { $0.kind == .remapValue && ParticleProgramCPU.RemapCode.output($0.record.header.w) == 16 }
    }

    /// A `remapinitialvalue` writes a control point: the `controlpoint` output, or an input that
    /// reads one (WE zeroes the point first, 0x14023d31d).
    var initializersWriteControlPoints: Bool {
        initializers.contains { element in
            let code = element.record.header.w
            return element.kind == .remapInitialValue
                && (ParticleProgramCPU.RemapCode.output(code) == 16 || (16...18).contains(ParticleProgramCPU.RemapCode.input(code)))
        }
    }

    var writesControlPoints: Bool { operatorsWriteControlPoints || initializersWriteControlPoints }
}

/// WE's operator opcodes (the operator VM's jump table at `wallpaper64.exe` 0x14024bb58).
enum ParticleOperatorKind: UInt32 {
    case movement = 1, angularMovement, alphaFade, sizeChange, colorChange, alphaChange
    case oscillatePosition, oscillateAlpha, oscillateSize, controlPointAttract
    case maintainDistanceToControlPoint, maintainDistanceBetweenControlPoints, reduceMovementNearControlPoint
    case turbulence, vortex, vortexV2, boids, capVelocity, remapValue, inheritValueFromEvent
    /// Collisions share one record kind here: `ParticleCollisionPlacement.kind` tells them apart.
    case collision
}

/// WE's initializer opcodes (the initializer switch at `wallpaper64.exe` 0x14023fa78).
enum ParticleInitializerKind: UInt32 {
    case lifetimeRandom = 1, sizeRandom, colorRandom, hsvColorRandom, colorList, alphaRandom, velocityRandom
    case inheritControlPointVelocity, turbulentVelocityRandom, rotationRandom, positionOffsetRandom
    case angularVelocityRandom, mapSequenceAroundControlPoint, mapSequenceBetweenControlPoints
    case remapInitialValue, inheritInitialValueFromEvent
}

/// A blend window over the particle's life (`blendinstart`, `blendinend`, `blendoutstart`,
/// `blendoutend`; parsed by `wallpaper64.exe` 0x1401c2a40): the operator's effect ramps in and back
/// out. WE switches an operator to its blended form only when the window does something
/// (0x1401c2e33); `nil` is the plain form.
struct ParticleBlend: Equatable {
    /// Start of the ramp in, 1 / its length, end of the ramp out, 1 / its length.
    let window: SIMD4<Float>

    /// Nil when WE keeps the plain operator: defaults 0, 0, 1, 1 (0x1401c2a9d…0x1401c2cd3).
    init?(inStart: Double?, inEnd: Double?, outStart: Double?, outEnd: Double?) {
        var inStart = Float(inStart ?? 0), inEnd = Float(inEnd ?? 0)
        let outStart = Float(outStart ?? 1)
        var outEnd = Float(outEnd ?? 1)
        // 0x1401c2d80: the ramps keep a length of at least 1e-4.
        inStart = min(inStart, inEnd - 0.0001)
        outEnd = max(outEnd, outStart + 0.0001)
        let active = (inEnd > 0.01 || outStart < 0.99)
            && ((outStart - inEnd) > 0.01 || (inEnd - inStart) > 0.01 || (outEnd - outStart) > 0.01)
        guard active else { return nil }
        window = SIMD4(inStart, 1 / (inEnd - inStart), outEnd, 1 / (outEnd - outStart))
    }

    init(window: SIMD4<Float>) { self.window = window }
}

/// One encoded record: what both simulations interpret. Every field is a 16-byte vector, as in
/// `ParticleShared.h`.
struct ParticleProgramOp: Equatable {
    /// Kind, flags, first and second control point (or a collision's index).
    var header = SIMD4<UInt32>.zero
    var a = SIMD4<Float>.zero
    var b = SIMD4<Float>.zero
    var c = SIMD4<Float>.zero
    var d = SIMD4<Float>.zero
    var e = SIMD4<Float>.zero
    /// `ParticleBlend.window`; x < -1 without one.
    var blend = SIMD4<Float>(-2, 0, 0, 0)

    static let noBlend = SIMD4<Float>(-2, 0, 0, 0)
}

/// A value of a record that a script sets every frame (`WEFlexibleDouble.script`).
struct ParticleValueScript: Equatable {
    /// Which record vector (0 `a` … 4 `e`) and component.
    let vector: Int
    let component: Int
    let script: String
}

/// One authored operator: its record as parsed, and what changes it every frame.
struct ParticleOperator: Equatable {
    var record: ParticleProgramOp
    var scripts: [ParticleValueScript] = []
    /// The audio response scaling the operator's speed (`e.w`; `turbulence`, `vortex`, `vortex_v2`).
    var audio: ParticleAudioResponse?
    /// The shape of a collision operator (placed every frame, `ParticleFrameInputs.collisions`).
    var collision: ParticleCollision?

    var kind: ParticleOperatorKind { ParticleOperatorKind(rawValue: record.header.x) ?? .movement }

    init(_ kind: ParticleOperatorKind, flags: UInt32 = 0, controlPoints: UInt32 = 0,
         a: SIMD4<Float> = .zero, b: SIMD4<Float> = .zero, c: SIMD4<Float> = .zero, d: SIMD4<Float> = .zero,
         e: SIMD4<Float> = SIMD4(0, 0, 0, 1), blend: ParticleBlend? = nil) {
        record = ParticleProgramOp(header: SIMD4(kind.rawValue, flags, controlPoints, 0), a: a, b: b, c: c, d: d, e: e,
                                   blend: blend?.window ?? ParticleProgramOp.noBlend)
    }
}

/// One authored initializer (`ParticleOperator`'s counterpart for spawning particles).
struct ParticleInitializer: Equatable {
    var record: ParticleProgramOp
    var scripts: [ParticleValueScript] = []
    /// `turbulentvelocityrandom`'s audio response (scales its phase range, `e.w`).
    var audio: ParticleAudioResponse?
    /// A `mapsequence…` initializer's count, which the `count` instance override rescales (its
    /// flag 1 or 16): the step is `1 / count` (`1 / (count − 1)` between two points).
    var sequenceCount: Float?

    var kind: ParticleInitializerKind { ParticleInitializerKind(rawValue: record.header.x) ?? .lifetimeRandom }

    init(_ kind: ParticleInitializerKind, flags: UInt32 = 0, controlPoints: UInt32 = 0,
         a: SIMD4<Float> = .zero, b: SIMD4<Float> = .zero, c: SIMD4<Float> = .zero, d: SIMD4<Float> = .zero,
         e: SIMD4<Float> = SIMD4(0, 0, 0, 1)) {
        record = ParticleProgramOp(header: SIMD4(kind.rawValue, flags, controlPoints, 0), a: a, b: b, c: c, d: d, e: e)
    }
}

extension ParticleProgramOp {
    subscript(vector: Int, component: Int) -> Float {
        get {
            switch vector {
            case 0: return a[component]
            case 1: return b[component]
            case 2: return c[component]
            case 3: return d[component]
            default: return e[component]
            }
        }
        set {
            switch vector {
            case 0: a[component] = newValue
            case 1: b[component] = newValue
            case 2: c[component] = newValue
            case 3: d[component] = newValue
            default: e[component] = newValue
            }
        }
    }

    /// The first control point (low byte of `header.z`) and the second (next byte).
    var controlPoint0: Int { Int(header.z & 0xFF) }
    var controlPoint1: Int { Int((header.z >> 8) & 0xFF) }
}
