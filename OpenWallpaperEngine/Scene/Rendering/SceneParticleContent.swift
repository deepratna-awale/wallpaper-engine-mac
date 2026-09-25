import Cocoa
import MetalKit
import CryptoKit

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
    /// The spawn shape's half extent (`distancemax`, times `directions`) in emitter space.
    let spawnExtent: SIMD2<Float>
    let lifetime: ClosedRange<Float>
    let size: ClosedRange<Float>
    let minimumVelocity: SIMD2<Float>
    let maximumVelocity: SIMD2<Float>
    /// The `movement` operator's gravity as authored: in emitter space, or in scene space with
    /// `worldGravity`.
    let gravity: SIMD2<Float>
    let drag: Float
    let dragScript: String?
    let alpha: ClosedRange<Float>
    let minimumColor: SIMD4<Float>
    let maximumColor: SIMD4<Float>
    let minimumRotation: Float
    let maximumRotation: Float
    let minimumAngularVelocity: Float
    let maximumAngularVelocity: Float
    let emitterName: String
    let sizeChange: ParticleChange?
    let alphaChange: ParticleChange?
    let colorChange: ParticleColorChange?
    let angularAcceleration: Float
    let maximumSpeed: Float?
    let vortex: ParticleVortex?
    let boids: ParticleBoids?
    let oscillateSize: ParticleOscillation?
    let oscillateAlpha: ParticleOscillation?
    let oscillatePosition: ParticleOscillation?
    let positionOffsetMinimum: SIMD2<Float>
    let positionOffsetMaximum: SIMD2<Float>
    let remapAlpha: ParticleRemap?
    let nearControlPointReduction: ParticleDistanceReduction?
    let maintainControlPointDistance: ParticleDistanceConstraint?
    let controlPoints: [ParticleControlPoint]
    let sequenceSpan: ParticleSequenceSpan?
    let sequenceRing: ParticleSequenceRing?
    let initialRemap: ParticleInitialRemap?
    let maintainSequenceDistance: Bool
    let rendererName: String
    let trailLength: Float
    let trailSegments: Int
    let ropeSubdivision: Int
    let fadeTrailAlpha: Bool
    let fadeTrailSize: Bool
    let turbulence: Turbulence?
    let attractor: Attractor?
    let emitterControlPoint: Int?
    let spriteSheet: SpriteSheet?
    let animationMode: String
    let sequenceMultiplier: Float
    let opacityMultiplier: Float
    let refractive: Bool
    let fadeIn: Float
    let fadeOut: Float
    let fadeInScript: String?
    let fadeOutScript: String?
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
    /// `flags` bit 0: spawned particles stay where they are when the emitter moves. Otherwise they
    /// live in the emitter's space and move, turn and scale with it.
    var worldSpace = false
    /// `movement` flag bit 0: gravity is a scene-space vector, not turned with the emitter.
    var worldGravity = false
    /// The emitter's `instantaneous` burst: particles spawned at once when the emitter starts (and
    /// each period, when periodic).
    var instantaneous = 0
    /// When the emitter emits: `delay`, `duration`, periodic emission, one per frame.
    var emitterTiming = ParticleEmitterTiming()
    /// Emitter `speedmin`…`speedmax`: speed away from the emitter's centre along the spawn offset.
    var emitterSpeed: ClosedRange<Float> = 0...0
    /// `sphererandom` `distancemin` over `distancemax`: the spawn ring's inner radius.
    var minimumSpawnRatio: Float = 0
    /// `sphererandom` `sign`: forces a spawn offset axis positive (1) or negative (−1); 0 leaves it.
    var emitterSign = SIMD2<Float>.zero
    /// Set for a child system: how it hangs off its parent.
    var link: ParticleChildLink? = nil
    /// The object's `instanceoverride` as resolved at load. Emission rate, maximum, size, alpha,
    /// lifetime, speed and colour above are authored; these scale them every frame.
    var overrides = SceneParticleOverrides()
    /// The `instanceoverride` again when a field is bound to a user property: resolved every
    /// frame instead of `overrides`.
    var liveOverrides: WEInstanceOverride? = nil
    /// A child that keeps its own colours (link flag 2): the overrides' tint and brightness skip it.
    var keepsOwnColors = false
    /// Collision operators, in order.
    var collisions: [ParticleCollision] = []
    /// Audio responses: of the emitter's rate, of an audio-responsive `turbulentvelocityrandom`
    /// (`audioVelocity…`, kept apart from the other velocity initializers), of `turbulence`'s and
    /// `vortex`'s speeds.
    var rateAudio: ParticleAudioResponse? = nil
    var velocityAudio: ParticleAudioResponse? = nil
    var audioVelocityMinimum = SIMD2<Float>.zero
    var audioVelocityMaximum = SIMD2<Float>.zero
    var turbulenceAudio: ParticleAudioResponse? = nil
    var vortexAudio: ParticleAudioResponse? = nil
    /// The system has event children, which read its spawns and deaths.
    var hasEventChildren = false
    /// What an instanced system's particles take from their event's parent particle
    /// (`inheritinitialvaluefromevent` at spawn, `inheritvaluefromevent` every step).
    var inheritOnSpawn: ParticleInheritance = []
    var inheritEachStep: ParticleInheritance = []

    /// Runs as instances (`ParticleChildLink`).
    var isInstanced: Bool { link?.instanced == true }

    /// The emitter's authored world transform.
    var authoredWorld: SceneAffineTransform {
        SceneAffineTransform(linear: emitterLinear, translation: origin)
    }
}

struct ParticleChange {
    let startTime: Float
    let endTime: Float
    let startValue: Float
    let endValue: Float
}

struct ParticleColorChange {
    let startTime: Float
    let endTime: Float
    let startValue: SIMD4<Float>
    let endValue: SIMD4<Float>
}

/// `vortex` around control point `controlPoint`.
struct ParticleVortex {
    let innerSpeed: Float
    let outerSpeed: Float
    let innerDistance: Float
    let outerDistance: Float
    var controlPoint = 0
}

struct ParticleBoids {
    let alignment: Float
    let cohesion: Float
    let separation: Float
    let threshold: Float
}

struct ParticleOscillation {
    let frequency: ClosedRange<Float>
    let scale: ClosedRange<Float>
    let phase: ClosedRange<Float>
}

struct ParticleRemap {
    let scale: Float
    let outputMinimum: Float
    let outputMaximum: Float
    let sine: Bool
}

/// `reducemovementnearcontrolpoint` around control point `controlPoint` plus `offset`.
struct ParticleDistanceReduction {
    let offset: SIMD2<Float>
    let innerDistance: Float
    let outerDistance: Float
    let reduction: Float
    var controlPoint = 0
}

/// `maintaindistancetocontrolpoint` towards control point `controlPoint` plus `offset`.
struct ParticleDistanceConstraint {
    let offset: SIMD2<Float>
    let strength: Float
    var controlPoint = 0
}

/// A control point declared by the particle system. Wallpaper Engine always writes eight of them;
/// initializers and operators address them by index.
struct ParticleControlPoint {
    let id: Int
    /// Emitter-space offset, y down; `SceneParticleEmitterSpace.offset` places it.
    let offset: SIMD2<Float>
    let locksToCursor: Bool
}

/// `mapsequencebetweencontrolpoints`: spreads particles along the segment joining two control
/// points, so a rope renderer draws a continuous strand (lightning arcs, DNA strands).
struct ParticleSequenceSpan {
    let startControlPoint: Int
    let endControlPoint: Int
    let count: Int
    let arcAmount: Float
    let mirrored: Bool
}

/// `mapsequencearoundcontrolpoint`: replaces the emitter's random spawn angle with one derived from
/// the particle's sequence position, turning a straight span into a helix.
struct ParticleSequenceRing {
    let turns: Float
    let axis: SIMD2<Float>
    let bounds: ClosedRange<Float>
    let minimumSpeed: SIMD2<Float>
    let maximumSpeed: SIMD2<Float>
}

/// `remapinitialvalue`: scales an initial property by how far the particle spawned from a control
/// point, which tapers strands towards their anchors.
struct ParticleInitialRemap {
    enum Output { case size, alpha, velocity }
    let controlPoint: Int
    let rangeMinimum: Float
    let rangeMaximum: Float
    let multiply: Bool
    let output: Output
}

struct Turbulence {
    let scale: Float
    let speed: ClosedRange<Float>
    let timeScale: Float
    let phase: Float
    let mask: SIMD2<Float>
}

/// `controlpointattract` towards control point `controlPoint` plus its `origin` (`offset`, y down).
struct Attractor {
    let offset: SIMD2<Float>
    let strength: Float
    let threshold: Float
    var controlPoint = 0
}

struct SpriteSheet {
    let columns: Int
    let rows: Int
    let frames: Int
    let duration: Float
}
