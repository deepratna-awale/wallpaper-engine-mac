import simd

/// One instance of an instanced child system (`ParticleChildLink`). The CPU simulation keeps an
/// array of them; the GPU one the same fields in `ParticleGPUInstance`.
struct ParticleInstance {
    var active = false
    /// Its emitter runs: rate emission (and the burst on its first step).
    var emitting = false
    /// Made this step: bursts once and starts its emission fresh.
    var fresh = false
    /// Its follow source died: its particles go this step.
    var clearing = false
    /// The parent particle it tracks (`follow`, `spawn`).
    var sourceSerial: UInt32 = 0
    var translation = SIMD2<Float>.zero
    var previousTranslation = SIMD2<Float>.zero
    var remainder: Float = 0
    /// Its emitter's timing, from when the instance was made (`ParticleEmitterClock`).
    var clock = ParticleEmitterClock()
    /// Its particles alive after the last step.
    var live = 0
    /// Spawned this step.
    var spawnCount = 0
    /// The source particle's values, for `inheritinitialvaluefromevent` and `inheritvaluefromevent`.
    var sourceVelocity = SIMD2<Float>.zero
    var sourceColor = SIMD4<Float>.zero
    var sourceSize: Float = 0
    var sourceRotation: Float = 0
    var sourceAngularVelocity: Float = 0

    /// Takes another instance's source (a static child of an instanced system inherits from its
    /// parent instance's event).
    mutating func inheritSource(of instance: ParticleInstance) {
        sourceVelocity = instance.sourceVelocity
        sourceColor = instance.sourceColor
        sourceSize = instance.sourceSize
        sourceRotation = instance.sourceRotation
        sourceAngularVelocity = instance.sourceAngularVelocity
    }

    mutating func track(_ particle: Particle) {
        translation = particle.position
        sourceVelocity = particle.velocity
        sourceColor = SIMD4(particle.color.x, particle.color.y, particle.color.z, particle.alpha)
        sourceSize = particle.size
        sourceRotation = particle.rotation
        sourceAngularVelocity = particle.angularVelocity
    }
}
