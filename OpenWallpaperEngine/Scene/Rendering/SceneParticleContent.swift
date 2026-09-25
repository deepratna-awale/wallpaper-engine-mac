import Cocoa
import MetalKit
import CryptoKit

struct SceneMetalParticleSystem {
    let source: SceneMetalTextureSource
    /// Index of the object in scene.json; systems draw between layers in that order.
    var order = 0
    let origin: SIMD2<Float>
    let emissionRate: Float
    let emissionRateScript: String?
    let maximumParticleCount: Int
    let spawnExtent: SIMD2<Float>
    let lifetime: ClosedRange<Float>
    let size: ClosedRange<Float>
    let minimumVelocity: SIMD2<Float>
    let maximumVelocity: SIMD2<Float>
    /// Scene-space gravity: the authored vector turned by the emitter's world rotation.
    let gravity: SIMD2<Float>
    /// Turns each spawned particle's emitter-local velocity into scene space
    /// (`SceneParticleEmitterSpace.rotation`).
    var velocityRotation = matrix_identity_float2x2
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
    let cursorControlPoint: CursorControlPoint?
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

struct ParticleVortex {
    let origin: SIMD2<Float>
    let innerSpeed: Float
    let outerSpeed: Float
    let innerDistance: Float
    let outerDistance: Float
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

struct ParticleDistanceReduction {
    let origin: SIMD2<Float>
    let innerDistance: Float
    let outerDistance: Float
    let reduction: Float
}

struct ParticleDistanceConstraint {
    let origin: SIMD2<Float>
    let strength: Float
}

/// A control point declared by the particle system. Wallpaper Engine always writes eight of them;
/// initializers and operators address them by index.
struct ParticleControlPoint {
    let id: Int
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

struct Attractor {
    let origin: SIMD2<Float>
    let strength: Float
    let threshold: Float
}

struct CursorControlPoint {
    let id: Int
    let offset: SIMD2<Float>
}

struct SpriteSheet {
    let columns: Int
    let rows: Int
    let frames: Int
    let duration: Float
}
