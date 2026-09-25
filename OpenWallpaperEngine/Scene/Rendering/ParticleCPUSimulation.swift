import Metal
import simd

struct Particle {
    var position: SIMD2<Float>
    var velocity: SIMD2<Float>
    var age: Float
    let lifetime: Float
    var size: Float
    var baseSize: Float
    var alpha: Float
    let baseAlpha: Float
    var rotation: Float
    var angularVelocity: Float
    var color: SIMD4<Float>
    let baseColor: SIMD4<Float>
    let spriteFrame: Int
    var history: [SIMD2<Float>]
    var historyStart: Int
    var historyTimer: Float = 0
    /// Normalised position along a control-point sequence, 0 at the start point and 1 at the end.
    var sequence: Float = 0
    /// Spawn order within the system; with the system's seed it names the particle's random draws.
    var serial: UInt32 = 0

    /// `history` is a circular buffer; this returns it oldest-first so a trail can be walked.
    var orderedHistory: [SIMD2<Float>] {
        guard historyStart > 0, historyStart < history.count else { return history }
        return Array(history[historyStart...] + history[..<historyStart])
    }
}

final class ParticleSystemRuntime {
    let texture: MTLTexture
    let configuration: SceneMetalParticleSystem
    var particles: [Particle] = []
    var emissionRemainder: Float = 0
    var elapsedTime: Float = 0
    /// Steps taken (`ParticleFrameInputs.frameIndex`).
    var frameIndex: UInt32 = 0
    /// The next particle's serial number: particles spawned so far.
    var nextSerial: UInt32 = 0
    /// Seeds every random draw of this system (`ParticleRandom`).
    let seed: UInt32
    var fadeIn: Float
    var fadeOut: Float
    /// Positions and velocities at the start of a step, which boids read their neighbours from.
    var neighborPositions: [SIMD2<Float>] = []
    var neighborVelocities: [SIMD2<Float>] = []
    /// The system's state on the GPU, when `ParticleGPUSimulator` runs it.
    var gpu: ParticleGPUSystem?
    /// The emitter's world transform at the last step (`ParticleFrameInputs.motion`).
    var lastEmitter: SceneAffineTransform?

    init(texture: MTLTexture, configuration: SceneMetalParticleSystem, seed: UInt32 = 0) {
        self.texture = texture
        self.configuration = configuration
        self.seed = seed
        self.fadeIn = configuration.fadeIn
        self.fadeOut = configuration.fadeOut
    }
}

/// The particle simulation on the CPU: emission, initializers, operators and death.
/// `ParticleSimulation.metal` runs the same step on the GPU; the two must stay in step
/// (`ParticleSimulationParityTests`).
enum ParticleCPUSimulation {
    static func update(_ particleSystems: [ParticleSystemRuntime], deltaTime: Float, cursor: SIMD2<Float>) {
        let signpost = OWESignpost.begin(OWESignpost.render, "updateParticles")
        defer { signpost.end() }
        for system in particleSystems {
            step(system, inputs: ParticleFrameInputs.advance(system, deltaTime: deltaTime, cursor: cursor))
        }
    }

    /// How many particles to spawn this step: `burst` first, then the rate, updating the
    /// fractional carry-over. Spawns a full system could not take are skipped, not queued into a
    /// later burst.
    static func emissionCount(liveCount: Int, maximum: Int, rate: Float, deltaTime: Float,
                              remainder: inout Float, burst: Int = 0) -> Int {
        let available = max(maximum - liveCount, 0)
        let burst = min(max(burst, 0), available)
        remainder += max(rate, 0) * deltaTime
        let count = max(0, min(Int(remainder), available - burst))
        remainder -= Float(count)
        if liveCount + burst + count >= maximum {
            remainder = remainder.truncatingRemainder(dividingBy: 1)
        }
        return burst + count
    }

    static func step(_ system: ParticleSystemRuntime, inputs: ParticleFrameInputs) {
        let configuration = system.configuration
        if inputs.clears {
            system.particles.removeAll(keepingCapacity: true)
            system.emissionRemainder = 0
            return
        }
        if let motion = inputs.motion {
            let scale = inputs.motionScale, angle = inputs.motionAngle
            for index in system.particles.indices {
                follow(&system.particles[index], motion: motion, scale: scale, angle: angle)
            }
        }
        let emitted = emissionCount(liveCount: system.particles.count, maximum: configuration.maximumParticleCount,
                                    rate: inputs.emissionRate, deltaTime: inputs.deltaTime,
                                    remainder: &system.emissionRemainder, burst: inputs.burst)
        for _ in 0..<emitted {
            system.particles.append(spawn(serial: system.nextSerial, system: system, inputs: inputs))
            system.nextSerial &+= 1
        }
        if configuration.boids != nil {
            system.neighborPositions.removeAll(keepingCapacity: true)
            system.neighborVelocities.removeAll(keepingCapacity: true)
            for particle in system.particles {
                system.neighborPositions.append(particle.position)
                system.neighborVelocities.append(particle.velocity)
            }
        }
        for index in system.particles.indices {
            advance(&system.particles[index], index: index, system: system, inputs: inputs)
        }
        system.particles.removeAll { $0.age >= $0.lifetime }
    }

    /// Carries a particle that lives in its emitter's space along with the emitter's move.
    static func follow(_ particle: inout Particle, motion: SceneAffineTransform, scale: Float, angle: Float) {
        particle.position = motion.apply(particle.position)
        particle.velocity = motion.linear * particle.velocity
        particle.size *= scale
        particle.baseSize *= scale
        particle.rotation += angle
        for sample in particle.history.indices {
            particle.history[sample] = motion.apply(particle.history[sample])
        }
    }

    /// A new particle: the emitter's shape and every initializer.
    static func spawn(serial: UInt32, system: ParticleSystemRuntime, inputs: ParticleFrameInputs) -> Particle {
        let configuration = system.configuration
        let seed = system.seed
        func random(_ a: Float, _ b: Float, _ stream: ParticleRandom.Stream) -> Float {
            ParticleRandom.value(a, b, seed: seed, serial: serial, stream)
        }
        let angle = random(0, 2 * .pi, .spawnAngle)
        let inner = min(max(configuration.minimumSpawnRatio, 0), 1)
        let radius = inner + (1 - inner) * sqrt(random(0, 1, .spawnRadius))
        var spawnOffset: SIMD2<Float>
        let extent = abs(configuration.spawnExtent * inputs.extentScale)
        if configuration.emitterName == "boxrandom" {
            spawnOffset = SIMD2(random(-extent.x, extent.x, .boxX), random(-extent.y, extent.y, .boxY))
        } else {
            spawnOffset = SIMD2(cos(angle) * extent.x, sin(angle) * extent.y) * radius
            let sign = configuration.emitterSign
            if sign.x != 0 { spawnOffset.x = abs(spawnOffset.x) * (sign.x > 0 ? 1 : -1) }
            if sign.y != 0 { spawnOffset.y = abs(spawnOffset.y) * (sign.y > 0 ? 1 : -1) }
        }
        let offsetMinimum = inputs.offsetLinear * configuration.positionOffsetMinimum
        let offsetMaximum = inputs.offsetLinear * configuration.positionOffsetMaximum
        let authoredOffset = SIMD2(random(offsetMinimum.x, offsetMaximum.x, .offsetX),
                                   random(offsetMinimum.y, offsetMaximum.y, .offsetY))
        var size = random(configuration.size.lowerBound, configuration.size.upperBound, .size)
        var alpha = random(configuration.alpha.lowerBound, configuration.alpha.upperBound, .alpha)
        let color = SIMD4<Float>(random(configuration.minimumColor.x, configuration.maximumColor.x, .red),
                                 random(configuration.minimumColor.y, configuration.maximumColor.y, .green),
                                 random(configuration.minimumColor.z, configuration.maximumColor.z, .blue), 1)
        var position = inputs.spawnOrigin + spawnOffset + authoredOffset
        var velocity = SIMD2(random(configuration.minimumVelocity.x, configuration.maximumVelocity.x, .velocityX),
                             random(configuration.minimumVelocity.y, configuration.maximumVelocity.y, .velocityY))
        // Authored in emitter space; a rotated emitter (or parent) turns the launch direction.
        velocity = inputs.velocityRotation * velocity
        // The emitter's own speed pushes particles out from its centre.
        let outward = simd_length(spawnOffset) > 1e-6 ? simd_normalize(spawnOffset) : SIMD2<Float>.zero
        velocity += outward * random(configuration.emitterSpeed.lowerBound, configuration.emitterSpeed.upperBound, .emitterSpeed)
        var sequence: Float = 0
        if let span = configuration.sequenceSpan, let start = inputs.sequenceStart, let end = inputs.sequenceEnd {
            let slot = Int(serial) % span.count
            let lap = Int(serial) / span.count
            // "mirror" walks the strand back down on alternate passes so successive
            // particles stay adjacent instead of jumping from the end to the start.
            sequence = span.mirrored && lap % 2 == 1
                ? 1 - Float(slot) / Float(span.count - 1)
                : Float(slot) / Float(span.count - 1)
            let axis = end - start
            let normal = SIMD2<Float>(-axis.y, axis.x)
            let arc = normal * span.arcAmount * sin(sequence * .pi) * 0.5
            var offset = spawnOffset
            if let ring = configuration.sequenceRing {
                // The emitter still sets the radius; only the angle comes from the sequence,
                // which is what turns a straight span into a helix.
                let radius = simd_length(spawnOffset)
                let bounded = ring.bounds.lowerBound + sequence * (ring.bounds.upperBound - ring.bounds.lowerBound)
                let angle = bounded * ring.turns * 2 * .pi
                let ringAxis = simd_length(ring.axis) > 0.0001 ? simd_normalize(ring.axis)
                    : (simd_length(axis) > 0.0001 ? simd_normalize(axis) : SIMD2<Float>(0, 1))
                offset = SIMD2<Float>(-ringAxis.y, ringAxis.x) * cos(angle) * radius
                velocity += SIMD2(random(ring.minimumSpeed.x, ring.maximumSpeed.x, .ringSpeedX),
                                  random(ring.minimumSpeed.y, ring.maximumSpeed.y, .ringSpeedY))
            }
            position = start + axis * sequence + arc + offset + authoredOffset
        }
        if let remap = configuration.initialRemap {
            let range = max(remap.rangeMaximum - remap.rangeMinimum, 0.001)
            let factor = min(max((simd_length(position - inputs.remapAnchor) - remap.rangeMinimum) / range, 0), 1)
            switch remap.output {
            case .size: size = remap.multiply ? size * factor : factor
            case .alpha: alpha = remap.multiply ? alpha * factor : factor
            case .velocity: velocity = remap.multiply ? velocity * factor : velocity
            }
        }
        return Particle(
            position: position, velocity: velocity, age: 0,
            lifetime: random(configuration.lifetime.lowerBound, configuration.lifetime.upperBound, .lifetime),
            size: size, baseSize: size, alpha: alpha, baseAlpha: alpha,
            rotation: random(configuration.minimumRotation, configuration.maximumRotation, .rotation),
            angularVelocity: random(configuration.minimumAngularVelocity, configuration.maximumAngularVelocity, .angularVelocity),
            color: color, baseColor: color,
            spriteFrame: ParticleRandom.index(configuration.spriteSheet?.frames ?? 1, seed: seed, serial: serial, .spriteFrame),
            history: [], historyStart: 0, sequence: sequence, serial: serial)
    }

    /// One step of every operator for the particle at `index`.
    static func advance(_ particle: inout Particle, index: Int, system: ParticleSystemRuntime, inputs: ParticleFrameInputs) {
        let configuration = system.configuration
        let deltaTime = inputs.deltaTime
        particle.position += particle.velocity * deltaTime
        if let turbulence = configuration.turbulence {
            let position = particle.position * turbulence.scale
            let phase = inputs.elapsedTime * turbulence.timeScale + turbulence.phase
            let direction = SIMD2<Float>(sin(position.y + phase), cos(position.x - phase))
            let magnitude = ParticleRandom.value(turbulence.speed.lowerBound, turbulence.speed.upperBound, seed: system.seed,
                                                 serial: particle.serial, stream: ParticleRandom.frameStream(inputs.frameIndex))
            let force: SIMD2<Float> = direction * magnitude * turbulence.mask
            particle.velocity += force * deltaTime
        }
        if let attractor = configuration.attractor {
            let offset = inputs.attractorOrigin - particle.position
            let distance = max(simd_length(offset), 0.001)
            if distance < attractor.threshold {
                particle.velocity += offset / distance * attractor.strength * deltaTime
            }
        }
        if let vortex = configuration.vortex {
            let offset = particle.position - inputs.vortexOrigin
            let distance = simd_length(offset)
            if distance > 0.001, distance >= vortex.innerDistance, distance <= max(vortex.outerDistance, vortex.innerDistance) {
                let progress = min(max((distance - vortex.innerDistance) / max(vortex.outerDistance - vortex.innerDistance, 0.001), 0), 1)
                let speed = vortex.innerSpeed + (vortex.outerSpeed - vortex.innerSpeed) * progress
                let tangent = SIMD2<Float>(-offset.y, offset.x) / distance
                particle.velocity += tangent * speed * deltaTime
            }
        }
        if let boids = configuration.boids, boids.threshold > 0 {
            applyBoids(boids, to: &particle, index: index, system: system, deltaTime: deltaTime)
        }
        if let reduction = configuration.nearControlPointReduction {
            let distance = simd_length(particle.position - inputs.reductionOrigin)
            if distance < reduction.outerDistance {
                let progress = min(max((distance - reduction.innerDistance) / max(reduction.outerDistance - reduction.innerDistance, 0.001), 0), 1)
                let multiplier = 1 - reduction.reduction * (1 - progress) * deltaTime
                particle.velocity *= max(multiplier, 0)
            }
        }
        if let constraint = configuration.maintainControlPointDistance {
            particle.velocity += (inputs.constraintOrigin - particle.position) * constraint.strength * deltaTime
        }
        if configuration.maintainSequenceDistance, let start = inputs.sequenceStart, let end = inputs.sequenceEnd {
            // Pulls each particle back to its slot on the strand so turbulence bends the
            // shape without tearing it away from its two anchors.
            let anchor = start + (end - start) * particle.sequence
            particle.velocity += (anchor - particle.position) * 10 * deltaTime
        }
        particle.velocity += inputs.gravity * deltaTime
        particle.velocity *= max(0, 1 - inputs.drag * deltaTime)
        if let maximumSpeed = configuration.maximumSpeed, maximumSpeed > 0 {
            let speed = simd_length(particle.velocity)
            if speed > maximumSpeed { particle.velocity *= maximumSpeed / speed }
        }
        particle.age += deltaTime
        let life = min(max(particle.age / max(particle.lifetime, 0.001), 0), 1)
        func progress(_ start: Float, _ end: Float) -> Float {
            min(max((life - start) / max(end - start, 0.001), 0), 1)
        }
        if let change = configuration.sizeChange {
            let t = progress(change.startTime, change.endTime)
            particle.size = particle.baseSize * (change.startValue + (change.endValue - change.startValue) * t)
        }
        if let change = configuration.alphaChange {
            let t = progress(change.startTime, change.endTime)
            particle.alpha = particle.baseAlpha * (change.startValue + (change.endValue - change.startValue) * t)
        }
        if let change = configuration.colorChange {
            let t = progress(change.startTime, change.endTime)
            particle.color = simd_mix(change.startValue, change.endValue, SIMD4<Float>(repeating: t)) * particle.baseColor
        }
        if let oscillation = configuration.oscillateSize {
            let wave = sin(particle.age * oscillation.frequency.middle + oscillation.phase.middle)
            particle.size = particle.baseSize * (1 + (oscillation.scale.middle - 1) * wave)
        }
        if let oscillation = configuration.oscillateAlpha {
            let wave = sin(particle.age * oscillation.frequency.middle + oscillation.phase.middle)
            particle.alpha = max(0, particle.baseAlpha * (1 + (oscillation.scale.middle - 1) * wave))
        }
        if let oscillation = configuration.oscillatePosition {
            let angle = particle.age * oscillation.frequency.middle + oscillation.phase.middle
            let scale = oscillation.scale.middle
            particle.position += SIMD2<Float>(sin(angle) * scale * deltaTime, cos(angle) * scale * deltaTime)
        }
        if let remap = configuration.remapAlpha {
            var value = particle.age * remap.scale
            if remap.sine { value = sin(value) * 0.5 + 0.5 }
            let mapped = remap.outputMinimum + (remap.outputMaximum - remap.outputMinimum) * min(max(value, 0), 1)
            particle.alpha = particle.baseAlpha * mapped
        }
        particle.angularVelocity += configuration.angularAcceleration * deltaTime
        particle.rotation += particle.angularVelocity * deltaTime
        // Only the ropetrail renderer reads history, and it wants samples spread over the
        // renderer's `length` in seconds rather than one per frame.
        if configuration.rendererName == "ropetrail" {
            let historyLimit = max(configuration.trailSegments, 1)
            let interval = max(configuration.trailLength, 0.001) / Float(historyLimit)
            particle.historyTimer += deltaTime
            if particle.historyTimer >= interval || particle.history.isEmpty {
                particle.historyTimer = 0
                if particle.history.count < historyLimit {
                    particle.history.append(particle.position)
                } else {
                    particle.history[particle.historyStart] = particle.position
                    particle.historyStart = (particle.historyStart + 1) % historyLimit
                }
            }
        }
    }

    /// Alignment, cohesion and separation against the neighbours within `threshold`, read from
    /// the start of the step. Each particle samples at most about 256 neighbours spread over the
    /// system (every `count / 256`-th), which bounds the cost without capping the system.
    private static func applyBoids(_ boids: ParticleBoids, to particle: inout Particle, index: Int,
                                   system: ParticleSystemRuntime, deltaTime: Float) {
        let positions = system.neighborPositions
        let velocities = system.neighborVelocities
        let neighborStride = max(1, positions.count / 256)
        var neighborCount: Float = 0
        var averageVelocity = SIMD2<Float>.zero
        var averagePosition = SIMD2<Float>.zero
        var separation = SIMD2<Float>.zero
        for neighborIndex in stride(from: 0, to: positions.count, by: neighborStride) where neighborIndex != index {
            let offset = positions[neighborIndex] - particle.position
            let distance = simd_length(offset)
            guard distance > 0.001, distance < boids.threshold else { continue }
            neighborCount += 1
            averageVelocity += velocities[neighborIndex]
            averagePosition += positions[neighborIndex]
            separation -= offset / distance
        }
        guard neighborCount > 0 else { return }
        averageVelocity /= neighborCount
        averagePosition /= neighborCount
        let alignment = averageVelocity - particle.velocity
        let cohesion = averagePosition - particle.position
        particle.velocity += (alignment * boids.alignment + cohesion * boids.cohesion + separation * boids.separation) * deltaTime
    }
}

extension ClosedRange where Bound == Float {
    /// The range's midpoint; the oscillation operators run at their ranges' middle.
    var middle: Float { (lowerBound + upperBound) / 2 }
}
