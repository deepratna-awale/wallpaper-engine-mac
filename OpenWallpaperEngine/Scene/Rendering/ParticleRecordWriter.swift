import Foundation
import simd

/// Turns the CPU simulation's particles into the records WE's particle shaders read
/// (`ParticleVertexFormat`). This is the only per-particle CPU work of the material path, and it
/// replaces the built-in draw's per-particle uniforms rather than adding to them.
enum ParticleRecordWriter {
    /// Records `system` needs this frame.
    static func recordCount(_ system: ParticleSystemRuntime, format: ParticleVertexFormat) -> Int {
        let particles = system.particles
        switch format {
        case .sprite:
            return particles.count
        case .rope where system.configuration.rendererName == "ropetrail":
            // Each particle's trail: the particle itself, then its history; one record per gap.
            return particles.reduce(0) { $0 + $1.history.count }
        case .rope:
            return max(particles.count - 1, 0)
        }
    }

    /// Writes `count` records (from `recordCount`) into `destination`.
    static func write(_ system: ParticleSystemRuntime, format: ParticleVertexFormat, count: Int,
                      into destination: UnsafeMutableRawPointer, opacity: (Particle) -> Float) {
        switch format {
        case .sprite:
            let records = destination.bindMemory(to: ParticleSpriteInstance.self, capacity: count)
            writeSprites(system, into: records, count: count, opacity: opacity)
        case .rope:
            let records = destination.bindMemory(to: ParticleRopeSegmentInstance.self, capacity: count)
            if system.configuration.rendererName == "ropetrail" {
                writeRopeTrails(system, into: records, count: count, opacity: opacity)
            } else {
                writeRope(system, into: records, count: count, opacity: opacity)
            }
        }
    }

    /// `g_RenderVar0` for a rope: `(points, 0, segment time offset, points)`. Trails are sampled at
    /// the particle, so the newest segment is always whole (offset 1).
    static func ropeRenderVar(_ system: ParticleSystemRuntime) -> SIMD4<Float> {
        let points: Float
        if system.configuration.rendererName == "ropetrail" {
            points = Float(max(system.configuration.trailSegments, 1) + 1)
        } else {
            points = Float(system.particles.count)
        }
        return SIMD4(points, 0, 1, points)
    }

    /// The size WE's particle shaders read: half the simulated size (a sprite's quad is this
    /// wide, a rope ribbon twice this), as linux-wallpaperengine and wallpaper-scene-renderer
    /// pass it, times `scale` (`ParticleSystemRuntime.drawSizeScale`).
    static func shaderSize(_ particle: Particle, scale: Float = 1) -> Float { particle.size / 2 * scale }

    private static func color(_ particle: Particle, opacity: (Particle) -> Float) -> SIMD4<Float> {
        SIMD4(particle.color.x, particle.color.y, particle.color.z, particle.color.w * opacity(particle))
    }

    private static func writeSprites(_ system: ParticleSystemRuntime, into records: UnsafeMutablePointer<ParticleSpriteInstance>,
                                     count: Int, opacity: (Particle) -> Float) {
        let configuration = system.configuration
        // Sprites take the emitter's transform through `g_Orientation*`; trails scale by its area.
        let scale = system.drawSizeScale
        for (index, particle) in system.particles.prefix(count).enumerated() {
            records[index] = ParticleSpriteInstance(
                position: SIMD4(particle.position.x, particle.position.y, 0, 0),
                rotationSize: SIMD4(0, 0, particle.rotation, shaderSize(particle, scale: scale)),
                velocityLifetime: SIMD4(particle.velocity.x, particle.velocity.y, 0,
                                        spritePhase(particle, configuration: configuration)),
                color: color(particle, opacity: opacity))
        }
    }

    /// Where in its sprite sheet a particle is, 0...1; the shader takes the frame from `frac`.
    static func spritePhase(_ particle: Particle, configuration: SceneMetalParticleSystem) -> Float {
        guard let sheet = configuration.spriteSheet, sheet.frames > 0 else { return 0 }
        let phase: Float
        switch configuration.animationMode {
        case "randomframe":
            // The frame's own start: with `SPRITESHEETBLEND` the fraction past it is how much of
            // the next frame shows. The small offset keeps `floor` on this frame despite rounding.
            phase = (Float(particle.spriteFrame % sheet.frames) + 0.001) / Float(sheet.frames)
        case "once":
            phase = min(particle.age / max(particle.lifetime, 0.0001) * configuration.sequenceMultiplier, 0.9999)
        default:
            let cycle = particle.age * configuration.sequenceMultiplier / max(sheet.duration, 0.001)
            phase = cycle - cycle.rounded(.down)
        }
        return phase.isFinite ? phase : 0
    }

    /// `rope`: one strand through the system's particles, oldest first.
    private static func writeRope(_ system: ParticleSystemRuntime, into records: UnsafeMutablePointer<ParticleRopeSegmentInstance>,
                                  count: Int, opacity: (Particle) -> Float) {
        let particles = system.particles
        let points = Float(particles.count)
        let scale = system.drawSizeScale
        for index in 0..<min(count, max(particles.count - 1, 0)) {
            let start = particles[index]
            let end = particles[index + 1]
            let previous = particles[max(index - 1, 0)].position
            let next = particles[min(index + 2, particles.count - 1)].position
            records[index] = ParticleRopeSegmentInstance(
                start: SIMD4(start.position.x, start.position.y, 0, shaderSize(start, scale: scale)),
                end: SIMD4(end.position.x, end.position.y, 0, points),
                previous: SIMD4(previous.x, previous.y, 0, Float(index)),
                next: SIMD4(next.x, next.y, 0, shaderSize(end, scale: scale)),
                endColor: color(end, opacity: opacity),
                color: color(start, opacity: opacity))
        }
    }

    /// `ropetrail`: one strand per particle through its history, newest point first.
    private static func writeRopeTrails(_ system: ParticleSystemRuntime, into records: UnsafeMutablePointer<ParticleRopeSegmentInstance>,
                                        count: Int, opacity: (Particle) -> Float) {
        var written = 0
        let scale = system.drawSizeScale
        for particle in system.particles {
            let history = particle.history
            guard !history.isEmpty else { continue }
            // The newest sample is just before `historyStart` in the ring.
            let newest = (particle.historyStart - 1 + history.count) % history.count
            func point(_ index: Int) -> SIMD2<Float> {
                index == 0 ? particle.position : history[(newest - (index - 1) + history.count * 2) % history.count]
            }
            let points = history.count + 1
            let rgba = color(particle, opacity: opacity)
            let size = shaderSize(particle, scale: scale)
            for segment in 0..<(points - 1) where written < count {
                let start = point(segment)
                let end = point(segment + 1)
                let previous = point(max(segment - 1, 0))
                let next = point(min(segment + 2, points - 1))
                records[written] = ParticleRopeSegmentInstance(
                    start: SIMD4(start.x, start.y, 0, size),
                    end: SIMD4(end.x, end.y, 0, Float(points)),
                    previous: SIMD4(previous.x, previous.y, 0, Float(segment)),
                    next: SIMD4(next.x, next.y, 0, size),
                    endColor: rgba, color: rgba)
                written += 1
            }
        }
    }
}
