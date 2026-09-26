import Cocoa
import MetalKit
import CryptoKit

/// A particle system as the simulation and the draw read it: its emitter, its compiled program
/// (`ParticleProgram`: initializers and operators in authored order), control points and renderer.
/// `ParticleSystemBuilder` makes it from the particle json with WE's defaults.
struct SceneMetalParticleSystem {
    let source: SceneMetalTextureSource
    /// Index of the object in scene.json; systems draw between layers in that order.
    var order = 0
    /// The emitter's scene position at load. With `emitterLinear` it is the emitter object's
    /// authored world transform, which the simulation uses unless the renderer supplies a live one.
    let origin: SIMD2<Float>
    let emissionRate: Float
    let emissionRateScript: String?
    let maximumParticleCount: Int
    /// The emitter's shape (`sphererandom`, `boxrandom`).
    var emitter = ParticleEmitterShape()
    /// Initializers and operators, in authored order.
    var program = ParticleProgram()
    /// The system's eight control points, by index.
    var controlPoints: [ParticleControlPoint] = ParticleControlPoint.defaults
    let rendererName: String
    /// The trail renderers' `length`: seconds of history a `ropetrail` keeps; the `spritetrail`
    /// shader's stretch per unit of speed (`ParticleMaterialPlanBuilder.trailLengths`).
    let trailLength: Float
    /// `spritetrail`'s `maxlength` and `minlength`: the stretch's limits.
    var trailLengthLimits = SIMD2<Float>(10, 0)
    /// The renderer's `orientation`, `axis` and `flags`: the axes its sprites and ribbons face along.
    var orientation = ParticleOrientation()
    /// A rope's `uvscale`, `uvsmoothing` and `uvscrolling`.
    var ropeUV = ParticleRopeUV()
    /// `ropetrail`'s `segments`: samples of history per particle.
    let trailSegments: Int
    /// `subdivision`: spline points per rope segment (the `TRAILSUBDIVISION` combo).
    let ropeSubdivision: Int
    let fadeTrailAlpha: Bool
    let fadeTrailSize: Bool
    let spriteSheet: SpriteSheet?
    let animationMode: String
    let sequenceMultiplier: Float
    let opacityMultiplier: Float
    let refractive: Bool
    let blending: String
    /// The system's material for WE's own particle shaders; nil keeps the built-in particle draw.
    var material: ParticleMaterialPlan? = nil
    /// Texture 0 for the built-in draw when it can't sample `source` as it is
    /// (`ParticleFallbackTexture`).
    var fallbackSource: SceneMetalTextureSource? = nil
    /// The emitter object's id in the scene hierarchy; the renderer moves the emitter with that
    /// object's live transform (parents, scripts and animations included).
    var objectID: String? = nil
    /// The emitter's world scale and rotation at load (see `origin`).
    var emitterLinear = matrix_identity_float2x2
    /// `flags` bit 0: the system simulates in the scene (WE's world space); spawned particles stay
    /// where they are when the emitter moves. Otherwise they live in the emitter's space and move,
    /// turn and scale with it.
    var worldSpace = false
    /// The emitter's `instantaneous` burst: particles spawned at once when the emitter starts (and
    /// each period, when periodic).
    var instantaneous = 0
    /// When the emitter emits: `delay`, `duration`, periodic emission, one per frame.
    var emitterTiming = ParticleEmitterTiming()
    /// Set for a child system: how it hangs off its parent.
    var link: ParticleChildLink? = nil
    /// The object's `instanceoverride` as resolved at load. Emission rate, maximum, size, alpha,
    /// lifetime, speed and colour above are authored; these scale them every frame.
    var overrides = SceneParticleOverrides()
    /// The `instanceoverride` again when a field is bound to a user property: resolved every
    /// frame instead of `overrides`.
    var liveOverrides: WEInstanceOverride? = nil
    /// The instance overrides the system's `flags` switch off (`SceneParticleOverrides.Parts`).
    var ignoredOverrides: SceneParticleOverrides.Parts = []
    /// A child that keeps its own colours (link flag 2): the overrides' tint and brightness skip it.
    var keepsOwnColors = false
    /// The emitter's audio response, on its rate.
    var rateAudio: ParticleAudioResponse? = nil
    /// The emitters after the first, in authored order. WE runs every emitter of a system, each
    /// with its own rate, burst and timing (`wallpaper64.exe` 0x1402378a0 walks the emitter records);
    /// the fields above (`emitter`, `emissionRate`, `instantaneous`, `emitterTiming`, `rateAudio`) are
    /// the first's.
    var extraEmitters: [ParticleEmitter] = []
    /// The system has event children, which read its spawns and deaths.
    var hasEventChildren = false
    /// `starttime`: seconds WE simulates before the first frame.
    var startTime: Float = 0

    /// Runs as instances (`ParticleChildLink`).
    var isInstanced: Bool { link?.instanced == true }

    /// Every emitter, the first included, in the order WE runs them.
    var emitters: [ParticleEmitter] {
        [ParticleEmitter(shape: emitter, rate: emissionRate, rateScript: emissionRateScript,
                         instantaneous: instantaneous, timing: emitterTiming, audio: rateAudio)] + extraEmitters
    }

    /// The emitter's authored world transform.
    var authoredWorld: SceneAffineTransform {
        SceneAffineTransform(linear: emitterLinear, translation: origin)
    }

    /// Whether the program has an operator of `kind`.
    func has(_ kind: ParticleOperatorKind) -> Bool { program.operators.contains { $0.kind == kind } }
}

/// One emitter of a system: its shape, rate, `instantaneous` burst, timing and audio response.
struct ParticleEmitter {
    var shape = ParticleEmitterShape()
    /// Particles a second (WE's default 10, 0x1401b8e59).
    var rate: Float = 10
    var rateScript: String?
    var instantaneous = 0
    var timing = ParticleEmitterTiming()
    var audio: ParticleAudioResponse?
}

/// An emitter's shape and launch speed (`sphererandom`, `boxrandom`), in the system's space.
/// WE's spawn code: `wallpaper64.exe` 0x140237c14 (sphere), 0x14023847f (box).
struct ParticleEmitterShape: Equatable {
    enum Kind: UInt32 { case sphere = 0, box }

    var kind = Kind.sphere
    /// `origin`, added to the control point's position.
    var origin = SIMD3<Float>.zero
    /// `directions`: scales the spawn offset per axis.
    var directions = SIMD3<Float>(1, 1, 0)
    /// `distancemin` and `distancemax`: a sphere's radii (x), a box's half extents.
    var distanceMinimum = SIMD3<Float>.zero
    var distanceMaximum = SIMD3<Float>(256, 256, 0)
    /// `speedmin`, `speedmax`: speed away from the emitter's centre.
    var speed = SIMD2<Float>.zero
    /// `sign`, when `flags` bit 0 applies it: forces an axis of the offset positive (> 0) or
    /// negative (< 0).
    var sign = SIMD3<Float>.zero
    var appliesSign = false
    /// `cone`: the sphere's spread around its +x axis, 0 a full sphere, 1 one direction.
    var cone: Float = 0
    /// `controlpoint`: where the emitter sits.
    var controlPoint = 0
}

/// A control point (WE's `controlpoint` array entry, by index; `wallpaper64.exe` updates them each
/// frame at 0x14022e3e0).
struct ParticleControlPoint: Equatable {
    /// `offset` (or the object's `controlpoint<n>` override), y up: in the system's space, or in
    /// the scene when `worldSpace`.
    var offset = SIMD2<Float>.zero
    /// Flag 1: sits on the cursor.
    var followsCursor = false
    /// Flag 2 (not for control point 0): `offset` is a scene position.
    var worldSpace = false
    /// Flag 4: copies its parent system's control point `parentcontrolpoint`.
    var parentControlPoint: Int?

    static let count = 8
    static let defaults = [ParticleControlPoint](repeating: ParticleControlPoint(), count: count)
}

struct SpriteSheet {
    let columns: Int
    let rows: Int
    let frames: Int
    let duration: Float
}
