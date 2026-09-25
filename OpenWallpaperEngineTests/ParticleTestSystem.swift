import AppKit
import simd
@testable import OpenWallpaperEngine

/// A particle system configuration for simulation tests: every operator off unless set.
struct ParticleTestSystem {
    var source: SceneMetalTextureSource = .image(NSImage())
    var origin = SIMD2<Float>(500, 500)
    var emissionRate: Float = 600
    var maximum = 1000
    var spawnExtent = SIMD2<Float>(50, 30)
    var emitterName = "sphererandom"
    var lifetime: ClosedRange<Float> = 1...2
    var size: ClosedRange<Float> = 10...20
    var minimumVelocity = SIMD2<Float>(-40, -20)
    var maximumVelocity = SIMD2<Float>(40, 60)
    var gravity = SIMD2<Float>.zero
    /// The emitter's world scale and rotation (with `origin`, its transform).
    var emitterLinear = matrix_identity_float2x2
    var worldSpace = false
    var worldGravity = false
    var instantaneous = 0
    var emitterTiming = ParticleEmitterTiming()
    var emitterSpeed: ClosedRange<Float> = 0...0
    var minimumSpawnRatio: Float = 0
    var emitterSign = SIMD2<Float>.zero
    var inheritOnSpawn: ParticleInheritance = []
    var inheritEachStep: ParticleInheritance = []
    var drag: Float = 0
    var alpha: ClosedRange<Float> = 0.5...1
    var minimumColor = SIMD4<Float>(0.2, 0.3, 0.4, 1)
    var maximumColor = SIMD4<Float>(0.9, 0.8, 1, 1)
    var minimumRotation: Float = 0
    var maximumRotation: Float = 1
    var minimumAngularVelocity: Float = -1
    var maximumAngularVelocity: Float = 1
    var sizeChange: ParticleChange?
    var alphaChange: ParticleChange?
    var colorChange: ParticleColorChange?
    var angularAcceleration: Float = 0
    var maximumSpeed: Float?
    var vortex: ParticleVortex?
    var boids: ParticleBoids?
    var oscillateSize: ParticleOscillation?
    var oscillateAlpha: ParticleOscillation?
    var oscillatePosition: ParticleOscillation?
    var positionOffsetMinimum = SIMD2<Float>.zero
    var positionOffsetMaximum = SIMD2<Float>.zero
    var remapAlpha: ParticleRemap?
    var nearControlPointReduction: ParticleDistanceReduction?
    var maintainControlPointDistance: ParticleDistanceConstraint?
    var controlPoints: [ParticleControlPoint] = []
    var sequenceSpan: ParticleSequenceSpan?
    var sequenceRing: ParticleSequenceRing?
    var initialRemap: ParticleInitialRemap?
    var maintainSequenceDistance = false
    var rendererName = "sprite"
    var trailLength: Float = 1
    var trailSegments = 4
    var ropeSubdivision = 1
    var fadeTrailAlpha = false
    var fadeTrailSize = false
    var turbulence: Turbulence?
    var attractor: Attractor?
    var emitterControlPoint: Int?
    var spriteSheet: SpriteSheet?
    var animationMode = "sequence"
    var fadeIn: Float = 0.1
    var fadeOut: Float = 0.8
    var material: ParticleMaterialPlan?

    var configuration: SceneMetalParticleSystem {
        var system = SceneMetalParticleSystem(
            source: source, origin: origin, emissionRate: emissionRate, emissionRateScript: nil,
            maximumParticleCount: maximum, spawnExtent: spawnExtent, lifetime: lifetime, size: size,
            minimumVelocity: minimumVelocity, maximumVelocity: maximumVelocity, gravity: gravity,
            drag: drag, dragScript: nil, alpha: alpha, minimumColor: minimumColor, maximumColor: maximumColor,
            minimumRotation: minimumRotation, maximumRotation: maximumRotation,
            minimumAngularVelocity: minimumAngularVelocity, maximumAngularVelocity: maximumAngularVelocity,
            emitterName: emitterName, sizeChange: sizeChange, alphaChange: alphaChange, colorChange: colorChange,
            angularAcceleration: angularAcceleration, maximumSpeed: maximumSpeed, vortex: vortex, boids: boids,
            oscillateSize: oscillateSize, oscillateAlpha: oscillateAlpha, oscillatePosition: oscillatePosition,
            positionOffsetMinimum: positionOffsetMinimum, positionOffsetMaximum: positionOffsetMaximum,
            remapAlpha: remapAlpha, nearControlPointReduction: nearControlPointReduction,
            maintainControlPointDistance: maintainControlPointDistance, controlPoints: controlPoints,
            sequenceSpan: sequenceSpan, sequenceRing: sequenceRing, initialRemap: initialRemap,
            maintainSequenceDistance: maintainSequenceDistance, rendererName: rendererName, trailLength: trailLength,
            trailSegments: trailSegments, ropeSubdivision: ropeSubdivision, fadeTrailAlpha: fadeTrailAlpha,
            fadeTrailSize: fadeTrailSize, turbulence: turbulence, attractor: attractor,
            emitterControlPoint: emitterControlPoint, spriteSheet: spriteSheet,
            animationMode: animationMode, sequenceMultiplier: 1, opacityMultiplier: 1, refractive: false,
            fadeIn: fadeIn, fadeOut: fadeOut, fadeInScript: nil, fadeOutScript: nil, blending: "translucent")
        system.emitterLinear = emitterLinear
        system.worldSpace = worldSpace
        system.worldGravity = worldGravity
        system.instantaneous = instantaneous
        system.emitterTiming = emitterTiming
        system.emitterSpeed = emitterSpeed
        system.minimumSpawnRatio = minimumSpawnRatio
        system.emitterSign = emitterSign
        system.inheritOnSpawn = inheritOnSpawn
        system.inheritEachStep = inheritEachStep
        system.material = material
        return system
    }

    /// This system as a child (`ParticleChildLink`).
    struct Linked {
        let system: ParticleTestSystem
        let kind: ParticleChildLink.Kind
        let instances: Int
        let probability: Float
        var origin = SIMD2<Float>.zero
        var instanced: Bool?

        func link(parentIndex: Int, parent: ParticleChildLink?) -> ParticleChildLink {
            ParticleChildLink(parentIndex: parentIndex, kind: kind,
                              local: SceneLocalTransform(origin: origin, scale: SIMD2(1, 1), angle: 0),
                              probability: probability, maximumInstances: instances,
                              instanced: instanced ?? (kind != .static || parent?.instanced == true))
        }
    }

    func link(_ kind: ParticleChildLink.Kind, instances: Int, probability: Float, origin: SIMD2<Float> = .zero,
              instanced: Bool? = nil) -> Linked {
        Linked(system: self, kind: kind, instances: instances, probability: probability, origin: origin, instanced: instanced)
    }
}
