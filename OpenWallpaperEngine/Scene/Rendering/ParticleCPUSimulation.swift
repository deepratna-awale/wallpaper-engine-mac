import Metal
import simd

struct Particle {
    var position: SIMD2<Float>
    var velocity: SIMD2<Float>
    var age: Float
    let lifetime: Float
    var size: Float
    let baseSize: Float
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
    var spawnCounter: Int = 0
    var fadeIn: Float
    var fadeOut: Float

    init(texture: MTLTexture, configuration: SceneMetalParticleSystem) {
        self.texture = texture
        self.configuration = configuration
        self.fadeIn = configuration.fadeIn
        self.fadeOut = configuration.fadeOut
    }
}

/// The particle simulation on the CPU: emission, initializers, operators and death.
enum ParticleCPUSimulation {
    static func update(_ particleSystems: [ParticleSystemRuntime], deltaTime: Float, cursor: SIMD2<Float>) {
        let signpost = OWESignpost.begin(OWESignpost.render, "updateParticles")
        defer { signpost.end() }
        for system in particleSystems {
            let configuration = system.configuration
            system.elapsedTime += deltaTime
            let emissionRate = configuration.emissionRateScript.map {
                AudioReactiveScriptEngine.shared.evaluate($0, fallback: configuration.emissionRate, time: Double(system.elapsedTime))
            } ?? configuration.emissionRate
            if emissionRate <= 0.0001 || configuration.opacityMultiplier <= 0.0001 {
                system.particles.removeAll(keepingCapacity: true)
                system.emissionRemainder = 0
                continue
            }
            let drag = configuration.dragScript.map {
                AudioReactiveScriptEngine.shared.evaluate($0, fallback: configuration.drag, time: Double(system.elapsedTime))
            } ?? configuration.drag
            system.fadeIn = configuration.fadeInScript.map {
                AudioReactiveScriptEngine.shared.evaluate($0, fallback: configuration.fadeIn, time: Double(system.elapsedTime))
            } ?? configuration.fadeIn
            system.fadeOut = configuration.fadeOutScript.map {
                AudioReactiveScriptEngine.shared.evaluate($0, fallback: configuration.fadeOut, time: Double(system.elapsedTime))
            } ?? configuration.fadeOut
            system.emissionRemainder += max(emissionRate, 0) * deltaTime
            let sequenceStart = configuration.sequenceSpan.map {
                controlPointPosition($0.startControlPoint, configuration: configuration, cursor: cursor)
            }
            let sequenceEnd = configuration.sequenceSpan.map {
                controlPointPosition($0.endControlPoint, configuration: configuration, cursor: cursor)
            }
            let emissionCount = max(0, min(Int(system.emissionRemainder),
                                    configuration.maximumParticleCount - system.particles.count))
            // Spawns a full system could not take are skipped, not queued into a later burst.
            system.emissionRemainder -= Float(emissionCount)
            if system.particles.count + emissionCount >= configuration.maximumParticleCount {
                system.emissionRemainder = system.emissionRemainder.truncatingRemainder(dividingBy: 1)
            }
            for _ in 0..<max(emissionCount, 0) {
                let angle = Float.random(in: 0...(2 * .pi))
                let radius = sqrt(Float.random(in: 0...1))
                let spawnOrigin: SIMD2<Float>
                if let controlPoint = configuration.cursorControlPoint,
                   configuration.emitterControlPoint == controlPoint.id {
                    spawnOrigin = cursor + controlPoint.offset
                } else {
                    spawnOrigin = configuration.origin
                }
                let spawnOffset: SIMD2<Float>
                if configuration.emitterName == "boxrandom" {
                    let extentX = abs(configuration.spawnExtent.x)
                    let extentY = abs(configuration.spawnExtent.y)
                    spawnOffset = SIMD2<Float>(Float.random(in: -extentX...extentX),
                                               Float.random(in: -extentY...extentY))
                } else {
                    spawnOffset = SIMD2<Float>(cos(angle) * configuration.spawnExtent.x,
                                               sin(angle) * configuration.spawnExtent.y) * radius
                }
                let authoredOffset = SIMD2<Float>(Float.random(in: min(configuration.positionOffsetMinimum.x, configuration.positionOffsetMaximum.x)...max(configuration.positionOffsetMinimum.x, configuration.positionOffsetMaximum.x)),
                                                  Float.random(in: min(configuration.positionOffsetMinimum.y, configuration.positionOffsetMaximum.y)...max(configuration.positionOffsetMinimum.y, configuration.positionOffsetMaximum.y)))
                let initialSize = Float.random(in: configuration.size)
                let initialAlpha = Float.random(in: configuration.alpha)
                let initialColor = SIMD4<Float>(Float.random(in: min(configuration.minimumColor.x, configuration.maximumColor.x)...max(configuration.minimumColor.x, configuration.maximumColor.x)),
                                                Float.random(in: min(configuration.minimumColor.y, configuration.maximumColor.y)...max(configuration.minimumColor.y, configuration.maximumColor.y)),
                                                Float.random(in: min(configuration.minimumColor.z, configuration.maximumColor.z)...max(configuration.minimumColor.z, configuration.maximumColor.z)), 1)
                var size = initialSize
                var alpha = initialAlpha
                var position = spawnOrigin + spawnOffset + authoredOffset
                var velocity = SIMD2<Float>(Float.random(in: min(configuration.minimumVelocity.x, configuration.maximumVelocity.x)...max(configuration.minimumVelocity.x, configuration.maximumVelocity.x)),
                                            Float.random(in: min(configuration.minimumVelocity.y, configuration.maximumVelocity.y)...max(configuration.minimumVelocity.y, configuration.maximumVelocity.y)))
                // Authored in emitter space; a rotated emitter (or parent) turns the launch direction.
                velocity = configuration.velocityRotation * velocity
                var sequence: Float = 0
                if let span = configuration.sequenceSpan, let start = sequenceStart, let end = sequenceEnd {
                    let slot = system.spawnCounter % span.count
                    let lap = system.spawnCounter / span.count
                    system.spawnCounter &+= 1
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
                        let bounded = ring.bounds.lowerBound
                            + sequence * (ring.bounds.upperBound - ring.bounds.lowerBound)
                        let angle = bounded * ring.turns * 2 * .pi
                        let ringAxis = simd_length(ring.axis) > 0.0001 ? simd_normalize(ring.axis)
                            : (simd_length(axis) > 0.0001 ? simd_normalize(axis) : SIMD2<Float>(0, 1))
                        offset = SIMD2<Float>(-ringAxis.y, ringAxis.x) * cos(angle) * radius
                        velocity += SIMD2<Float>(Float.random(in: min(ring.minimumSpeed.x, ring.maximumSpeed.x)...max(ring.minimumSpeed.x, ring.maximumSpeed.x)),
                                                 Float.random(in: min(ring.minimumSpeed.y, ring.maximumSpeed.y)...max(ring.minimumSpeed.y, ring.maximumSpeed.y)))
                    }
                    position = start + axis * sequence + arc + offset + authoredOffset
                }
                if let remap = configuration.initialRemap {
                    let anchor = controlPointPosition(remap.controlPoint, configuration: configuration, cursor: cursor)
                    let range = max(remap.rangeMaximum - remap.rangeMinimum, 0.001)
                    let factor = min(max((simd_length(position - anchor) - remap.rangeMinimum) / range, 0), 1)
                    switch remap.output {
                    case .size: size = remap.multiply ? size * factor : factor
                    case .alpha: alpha = remap.multiply ? alpha * factor : factor
                    case .velocity: velocity = remap.multiply ? velocity * factor : velocity
                    }
                }
                system.particles.append(Particle(
                    position: position,
                    velocity: velocity,
                    age: 0,
                    lifetime: Float.random(in: configuration.lifetime),
                    size: size, baseSize: size,
                    alpha: alpha, baseAlpha: alpha,
                    rotation: Float.random(in: configuration.minimumRotation...configuration.maximumRotation),
                    angularVelocity: Float.random(in: configuration.minimumAngularVelocity...configuration.maximumAngularVelocity),
                    color: initialColor, baseColor: initialColor,
                    spriteFrame: Int.random(in: 0..<max(configuration.spriteSheet?.frames ?? 1, 1)),
                    history: [], historyStart: 0, sequence: sequence))
            }
            for index in system.particles.indices {
                system.particles[index].position += system.particles[index].velocity * deltaTime
                if let turbulence = configuration.turbulence {
                    let position = system.particles[index].position * turbulence.scale
                    let phase = system.elapsedTime * turbulence.timeScale + turbulence.phase
                    // Spelled out step by step: older Swift compilers mis-resolve the chained operators.
                    let direction = SIMD2<Float>(sin(position.y + phase), cos(position.x - phase))
                    let magnitude: Float = Float.random(in: turbulence.speed)
                    let force: SIMD2<Float> = direction * magnitude * turbulence.mask
                    system.particles[index].velocity += force * deltaTime
                }
                if let attractor = configuration.attractor {
                    let origin = configuration.cursorControlPoint.map { cursor + $0.offset } ?? attractor.origin
                    let offset = origin - system.particles[index].position
                    let distance = max(simd_length(offset), 0.001)
                    if distance < attractor.threshold {
                        system.particles[index].velocity += offset / distance * attractor.strength * deltaTime
                    }
                }
                if let vortex = configuration.vortex {
                    let offset = system.particles[index].position - vortex.origin
                    let distance = simd_length(offset)
                    if distance > 0.001, distance >= vortex.innerDistance, distance <= max(vortex.outerDistance, vortex.innerDistance) {
                        let progress = min(max((distance - vortex.innerDistance) / max(vortex.outerDistance - vortex.innerDistance, 0.001), 0), 1)
                        let speed = vortex.innerSpeed + (vortex.outerSpeed - vortex.innerSpeed) * progress
                        let tangent = SIMD2<Float>(-offset.y, offset.x) / distance
                        system.particles[index].velocity += tangent * speed * deltaTime
                    }
                }
                     if let boids = configuration.boids, boids.threshold > 0,
                         system.particles.count < 1500 {
                    var neighborCount: Float = 0
                    var averageVelocity = SIMD2<Float>.zero
                    var averagePosition = SIMD2<Float>.zero
                    var separation = SIMD2<Float>.zero
                    let neighborStride = max(1, system.particles.count / 256)
                    for neighborIndex in system.particles.indices where neighborIndex != index && neighborIndex % neighborStride == 0 {
                        let offset = system.particles[neighborIndex].position - system.particles[index].position
                        let distance = simd_length(offset)
                        guard distance > 0.001, distance < boids.threshold else { continue }
                        neighborCount += 1
                        averageVelocity += system.particles[neighborIndex].velocity
                        averagePosition += system.particles[neighborIndex].position
                        separation -= offset / distance
                    }
                    if neighborCount > 0 {
                        averageVelocity /= neighborCount
                        averagePosition /= neighborCount
                        let alignment = averageVelocity - system.particles[index].velocity
                        let cohesion = averagePosition - system.particles[index].position
                        system.particles[index].velocity += (alignment * boids.alignment
                            + cohesion * boids.cohesion + separation * boids.separation) * deltaTime
                    }
                }
                if let reduction = configuration.nearControlPointReduction {
                    let offset = system.particles[index].position - reduction.origin
                    let distance = simd_length(offset)
                    if distance < reduction.outerDistance {
                        let progress = min(max((distance - reduction.innerDistance) / max(reduction.outerDistance - reduction.innerDistance, 0.001), 0), 1)
                        let multiplier = 1 - reduction.reduction * (1 - progress) * deltaTime
                        system.particles[index].velocity *= max(multiplier, 0)
                    }
                }
                if let constraint = configuration.maintainControlPointDistance {
                    let offset = constraint.origin - system.particles[index].position
                    system.particles[index].velocity += offset * constraint.strength * deltaTime
                }
                if configuration.maintainSequenceDistance, let start = sequenceStart, let end = sequenceEnd {
                    // Pulls each particle back to its slot on the strand so turbulence bends the
                    // shape without tearing it away from its two anchors.
                    let anchor = start + (end - start) * system.particles[index].sequence
                    system.particles[index].velocity += (anchor - system.particles[index].position) * 10 * deltaTime
                }
                system.particles[index].velocity += configuration.gravity * deltaTime
                system.particles[index].velocity *= max(0, 1 - drag * deltaTime)
                if let maximumSpeed = configuration.maximumSpeed, maximumSpeed > 0 {
                    let speed = simd_length(system.particles[index].velocity)
                    if speed > maximumSpeed {
                        system.particles[index].velocity *= maximumSpeed / speed
                    }
                }
                system.particles[index].age += deltaTime
                let particleProgress = min(max(system.particles[index].age / max(system.particles[index].lifetime, 0.001), 0), 1)
                if let change = configuration.sizeChange {
                    let progress = min(max((particleProgress - change.startTime) / max(change.endTime - change.startTime, 0.001), 0), 1)
                    system.particles[index].size = system.particles[index].baseSize * (change.startValue + (change.endValue - change.startValue) * progress)
                }
                if let change = configuration.alphaChange {
                    let progress = min(max((particleProgress - change.startTime) / max(change.endTime - change.startTime, 0.001), 0), 1)
                    system.particles[index].alpha = system.particles[index].baseAlpha * (change.startValue + (change.endValue - change.startValue) * progress)
                }
                if let change = configuration.colorChange {
                    let progress = min(max((particleProgress - change.startTime) / max(change.endTime - change.startTime, 0.001), 0), 1)
                    system.particles[index].color = simd_mix(change.startValue, change.endValue, SIMD4<Float>(repeating: progress)) * system.particles[index].baseColor
                }
                if let oscillation = configuration.oscillateSize {
                    let frequency = (oscillation.frequency.lowerBound + oscillation.frequency.upperBound) / 2
                    let scale = (oscillation.scale.lowerBound + oscillation.scale.upperBound) / 2
                    let phase = (oscillation.phase.lowerBound + oscillation.phase.upperBound) / 2
                    system.particles[index].size = system.particles[index].baseSize * (1 + (scale - 1) * sin(system.particles[index].age * frequency + phase))
                }
                if let oscillation = configuration.oscillateAlpha {
                    let frequency = (oscillation.frequency.lowerBound + oscillation.frequency.upperBound) / 2
                    let scale = (oscillation.scale.lowerBound + oscillation.scale.upperBound) / 2
                    let phase = (oscillation.phase.lowerBound + oscillation.phase.upperBound) / 2
                    system.particles[index].alpha = max(0, system.particles[index].baseAlpha * (1 + (scale - 1) * sin(system.particles[index].age * frequency + phase)))
                }
                if let oscillation = configuration.oscillatePosition {
                    let frequency = (oscillation.frequency.lowerBound + oscillation.frequency.upperBound) / 2
                    let scale = (oscillation.scale.lowerBound + oscillation.scale.upperBound) / 2
                    let phase = (oscillation.phase.lowerBound + oscillation.phase.upperBound) / 2
                    let offset = sin(system.particles[index].age * frequency + phase) * scale * deltaTime
                    system.particles[index].position += SIMD2<Float>(offset, cos(system.particles[index].age * frequency + phase) * scale * deltaTime)
                }
                if let remap = configuration.remapAlpha {
                    var value = system.particles[index].age * remap.scale
                    if remap.sine { value = sin(value) * 0.5 + 0.5 }
                    let mapped = remap.outputMinimum + (remap.outputMaximum - remap.outputMinimum) * min(max(value, 0), 1)
                    system.particles[index].alpha = system.particles[index].baseAlpha * mapped
                }
                system.particles[index].angularVelocity += configuration.angularAcceleration * deltaTime
                system.particles[index].rotation += system.particles[index].angularVelocity * deltaTime
                let historyLimit = max(configuration.trailSegments, 1)
                // Only the ropetrail renderer reads history, and it wants samples spread over the
                // renderer's `length` in seconds rather than one per frame.
                if configuration.rendererName == "ropetrail" {
                    let interval = max(configuration.trailLength, 0.001) / Float(historyLimit)
                    system.particles[index].historyTimer += deltaTime
                    if system.particles[index].historyTimer >= interval || system.particles[index].history.isEmpty {
                        system.particles[index].historyTimer = 0
                        if system.particles[index].history.count < historyLimit {
                            system.particles[index].history.append(system.particles[index].position)
                        } else {
                            let historyStart = system.particles[index].historyStart
                            system.particles[index].history[historyStart] = system.particles[index].position
                            system.particles[index].historyStart = (historyStart + 1) % historyLimit
                        }
                    }
                }
            }
            system.particles.removeAll { $0.age >= $0.lifetime }
        }
    }

    static func controlPointPosition(_ id: Int, configuration: SceneMetalParticleSystem,
                                      cursor: SIMD2<Float>) -> SIMD2<Float> {        guard let point = configuration.controlPoints.first(where: { $0.id == id }) else {
            return configuration.origin
        }
        return (point.locksToCursor ? cursor : configuration.origin) + point.offset
    }
}
