import simd

/// The operator records on the CPU (`wallpaper64.exe`'s operator VM, 0x14023fbc0; handlers by
/// opcode through the table at 0x14024bb58). Every operator runs in the system's space; the
/// change / fade / oscillate operators multiply the working size, alpha and colour, which start
/// every step from the base values (0x14023fc08…0x14023fc99).
extension ParticleProgramCPU {
    /// The boids neighbourhood of a step: every particle's position and velocity in the scene at the
    /// start of the step, and the frame counter WE slices the work by.
    struct Neighbors {
        var positions: [SIMD2<Float>] = []
        var velocities: [SIMD2<Float>] = []
        var serials: [UInt32] = []
        var frame: UInt32 = 0
    }

    /// Runs `operators` on `particle` (index `index` of the step), in order.
    static func runOperators(_ operators: [ParticleProgramOp], on particle: inout ParticleProgramState,
                             context: ParticleProgramContext, index: Int, neighbors: Neighbors) -> Bool {
        var dies = false
        particle.size = particle.baseSize
        particle.alpha = particle.baseAlpha
        particle.color = particle.baseColor
        particle.previous = particle.position
        for record in operators {
            guard let kind = ParticleOperatorKind(rawValue: record.header.x) else { continue }
            let blended = record.blend.x >= -1
            let blend = blended ? blendFactor(record.blend, particle.lifeFraction) : 1
            switch kind {
            case .movement: movement(record, &particle, context)
            case .angularMovement: angularMovement(record, &particle, context, blend: blend)
            case .alphaFade: particle.alpha *= alphaFade(record, particle.lifeFraction)
            case .sizeChange:
                particle.size *= change(record.a, particle.lifeFraction)
            case .alphaChange:
                particle.alpha *= change(record.a, particle.lifeFraction)
            case .colorChange:
                let w = progress(particle.lifeFraction, record.c.x, record.c.y)
                let start = SIMD3(record.a.x, record.a.y, record.a.z), end = SIMD3(record.b.x, record.b.y, record.b.z)
                particle.color *= start + (end - start) * w
            case .oscillatePosition: oscillatePosition(record, &particle, context, blend: blend)
            case .oscillateAlpha:
                let value = oscillation(record, particle, context)
                particle.alpha *= blended ? 1 - (1 - value) * blend : value
            case .oscillateSize:
                let value = oscillation(record, particle, context)
                particle.size *= blended ? 1 + (value - 1) * blend : value
            case .controlPointAttract:
                if controlPointAttract(record, &particle, context, blend: blend) { dies = true }
            case .maintainDistanceToControlPoint: maintainDistance(record, &particle, context, blend: blend)
            case .maintainDistanceBetweenControlPoints: maintainBetween(record, &particle, context, blend: blend)
            case .reduceMovementNearControlPoint: reduceMovement(record, &particle, context, blend: blend)
            case .turbulence: turbulence(record, &particle, context, blend: blend)
            case .vortex: vortex(record, &particle, context)
            case .vortexV2: vortexV2(record, &particle, context, blend: blend)
            case .boids: boids(record, &particle, context, index: index, neighbors: neighbors)
            case .capVelocity: capVelocity(record, &particle, blend: blend, blended: blended)
            case .remapValue: remap(record, &particle, context, initializer: false, blend: blend)
            case .inheritValueFromEvent: inheritValue(record, &particle, context)
            case .collision:
                if collide(record, &particle, context) { dies = true }
            }
        }
        return dies
    }

    // MARK: - Movement

    /// `movement` (0x14023fdc9): v' = v + g·Δt, p += v'·Δt, v = v'·(1 − min(drag·Δt', 1)), Δt' the
    /// damped step (`ParticleFrameInputs.dragDeltaTime`). Flag 1 gives gravity in the scene rather
    /// than the system's space (0x14023fde2).
    static func movement(_ record: ParticleProgramOp, _ p: inout ParticleProgramState, _ context: ParticleProgramContext) {
        var gravity = SIMD2(record.a.x, record.a.y)
        if record.header.y & 1 != 0, !context.worldSpace { gravity = context.toSpace * gravity }
        let dt = context.deltaTime
        let damping = 1 - min(record.a.w * context.dragDeltaTime, 1)
        let velocity = p.velocity + gravity * dt
        p.previous = p.position
        p.position += velocity * dt
        p.velocity = velocity * damping
    }

    /// `angularmovement` (0x14023ffc7, blended 0x1402400e7): the same scheme on the spin about z.
    static func angularMovement(_ record: ParticleProgramOp, _ p: inout ParticleProgramState,
                                _ context: ParticleProgramContext, blend: Float) {
        let dt = context.deltaTime
        let damping = min(record.a.w * context.dragDeltaTime, 1)
        let spin = p.angularVelocity + blend * record.a.z * dt
        p.rotation += blend * dt * spin
        p.angularVelocity = spin * (1 - blend * damping)
    }

    // MARK: - Life-driven values

    /// `alphafade` (0x14024029d): in over the first `fadeintime` of the life, out after
    /// `fadeouttime`; both are fractions of the life.
    static func alphaFade(_ record: ParticleProgramOp, _ t: Float) -> Float {
        let fadeIn = record.a.x, fadeOut = record.a.y
        if t < fadeIn { return t / fadeIn }
        if fadeOut < t { return (1 - t) / (1 - fadeOut) }
        return 1
    }

    /// `sizechange` / `alphachange` (0x14024033a / 0x140240457): start…end over starttime…endtime.
    static func change(_ values: SIMD4<Float>, _ t: Float) -> Float {
        values.x + (values.y - values.x) * progress(t, values.z, values.w)
    }

    /// The oscillators' frequency, phase and scale: each `min + r·(max − min)` with the particle's
    /// one random value (0x140240f50).
    static func oscillator(_ record: ParticleProgramOp, _ random: Float) -> (frequency: Float, phase: Float, scale: Float) {
        (record.b.x + random * (record.b.y - record.b.x), record.b.z + random * (record.b.w - record.b.z),
         record.c.x + random * (record.c.y - record.c.x))
    }

    /// `oscillatealpha` / `oscillatesize`: scalemin + (sin(f·(age + phase)) + 1)·½·r·(scalemax −
    /// scalemin); the random scales the swing too (0x140240f50…0x140241069).
    static func oscillation(_ record: ParticleProgramOp, _ p: ParticleProgramState, _ context: ParticleProgramContext) -> Float {
        let r = context.random
        let o = oscillator(record, r)
        let wave = sin(o.frequency * (p.age + o.phase))
        return record.c.x + (wave + 1) * 0.5 * r * (record.c.y - record.c.x)
    }

    /// `oscillateposition` (0x1402404c0): moves the particle along a sine path, by its change over
    /// the step; y runs 2π·r out of phase with x.
    static func oscillatePosition(_ record: ParticleProgramOp, _ p: inout ParticleProgramState,
                                  _ context: ParticleProgramContext, blend: Float) {
        let r = context.random
        let o = oscillator(record, r)
        let scale = o.scale * blend
        let now = p.age + o.phase, before = p.age - context.deltaTime + o.phase
        let shift = 2 * Float.pi * r
        let x = sin(o.frequency * now) - sin(o.frequency * before)
        let y = sin(o.frequency * (now + shift)) - sin(o.frequency * (before + shift))
        p.position += SIMD2(x * scale * record.a.x, y * scale * record.a.y)
    }

    // MARK: - Control points

    /// `controlpointattract` (0x140241554): pulls the velocity towards the point, fading to nothing
    /// at `threshold`; flag 2 never pulls past the point, flag 1 deletes a particle that passed
    /// within `deletethreshold` of it. Returns true for a deleted particle.
    static func controlPointAttract(_ record: ParticleProgramOp, _ p: inout ParticleProgramState,
                                    _ context: ParticleProgramContext, blend: Float) -> Bool {
        let center = point(context.controlPoints, record.controlPoint0)
        let offset = p.position - center
        let distance = simd_length(offset)
        let scale = record.b.x, threshold = record.b.y
        if distance > Float.leastNormalMagnitude, distance < threshold {
            var force = (1 - distance / threshold) * scale * context.dragDeltaTime * blend
            if record.header.y & 2 != 0, distance < force { force = distance }
            p.velocity -= offset / distance * force
        }
        guard record.header.y & 1 != 0 else { return false }
        // The step's segment's closest point to the control point (0x14022a150).
        let segment = p.position - p.previous
        let length = simd_length_squared(segment)
        let t = length > 0 ? saturate(simd_dot(center - p.previous, segment) / length) : 0
        let closest = p.previous + segment * t
        return simd_length_squared(center - closest) <= record.b.z * record.b.z
    }

    /// `maintaindistancetocontrolpoint` (0x14024197a): carries the particle along with the point's
    /// move and pulls it to `distance` from it, fully or by `variablestrength·Δt`.
    static func maintainDistance(_ record: ParticleProgramOp, _ p: inout ParticleProgramState,
                                 _ context: ParticleProgramContext, blend: Float) {
        let index = record.controlPoint0
        let center = point(context.controlPoints, index)
        let moved = p.position + (center - point(context.previousControlPoints, index))
        let offset = moved - center
        let length = simd_length(offset)
        let strength = record.a.y == 0 ? 1 : saturate(record.a.y * context.deltaTime)
        guard length > 0 else { p.position = moved; return }
        p.position = moved + offset * (record.a.x / length - 1) * strength * blend
    }

    /// `maintaindistancebetweencontrolpoints` (0x140242058): keeps each particle at its place along
    /// the segment between the two points as they move.
    static func maintainBetween(_ record: ParticleProgramOp, _ p: inout ParticleProgramState,
                                _ context: ParticleProgramContext, blend: Float) {
        let a = point(context.controlPoints, record.controlPoint0), b = point(context.controlPoints, record.controlPoint1)
        let aBefore = point(context.previousControlPoints, record.controlPoint0)
        let bBefore = point(context.previousControlPoints, record.controlPoint1)
        let span = b - a, spanBefore = bBefore - aBefore
        let limit: Float = 1.42109e-14
        guard simd_length_squared(span) > limit, simd_length_squared(spanBefore) > limit else { return }
        let lengthBefore = simd_length(spanBefore)
        let directionBefore = spanBefore / lengthBefore
        let along = simd_dot(p.position - aBefore, directionBefore)
        let t = saturate(along / lengthBefore)
        p.position += (a - aBefore + span * t - directionBefore * along) * blend
    }

    /// `reducemovementnearcontrolpoint` (0x14024268f): damps the velocity by reductioninner at
    /// distanceinner to reductionouter at distanceouter, per second.
    static func reduceMovement(_ record: ParticleProgramOp, _ p: inout ParticleProgramState,
                               _ context: ParticleProgramContext, blend: Float) {
        let distance = simd_length(p.position - point(context.controlPoints, record.controlPoint0))
        let span = record.a.y - record.a.x
        let t = saturate((distance - record.a.x) * (span == 0 ? 1 : 1 / span))
        // WE keeps a reduction span of 1 when the two reductions are equal (0x1401cd1a9).
        let reductionSpan = record.a.w == record.a.z ? 1 : record.a.w - record.a.z
        let reduction = record.a.z + t * reductionSpan
        p.velocity *= 1 - blend * saturate(reduction * context.deltaTime)
    }

    // MARK: - Fields

    /// `turbulence` (0x14024295a): 3D simplex noise of the position, shifted by time and the
    /// particle's phase, pushes the velocity (engine time × `timescale`; `phasemin` is never read).
    static func turbulence(_ record: ParticleProgramOp, _ p: inout ParticleProgramState,
                           _ context: ParticleProgramContext, blend: Float) {
        let r = context.random
        let phase = r * (record.c.y - record.c.x) + context.engineTime * record.b.w
        let scale = record.b.x
        let point = SIMD3(p.position.x + phase, p.position.y + phase, phase) * scale
        let speed = (record.b.y + r * (record.b.z - record.b.y)) * record.e.w * blend
        let push = context.dragDeltaTime * speed
        p.velocity.x += ParticleNoise.simplex3(point.x, point.y, point.z) * record.a.x * push
        p.velocity.y += ParticleNoise.simplex3(point.z, point.x, point.y) * record.a.y * push
    }

    /// `vortex` (0x1402431be): spins particles about the axis through the control point (plus
    /// `offset`), speedinner at distanceinner to speedouter at distanceouter.
    static func vortex(_ record: ParticleProgramOp, _ p: inout ParticleProgramState, _ context: ParticleProgramContext) {
        let center = point(context.controlPoints, record.controlPoint0) + SIMD2(record.a.x, record.a.y)
        let axis = vortexAxis(record.b)
        var offset = SIMD3(p.position.x - center.x, p.position.y - center.y, 0)
        if record.header.y & 1 != 0 { offset -= simd_dot(offset, axis) * axis }
        let distance = simd_length(offset)
        guard distance > 0 else { return }
        let normal = offset / distance
        let span = record.c.y - record.c.x
        let t = saturate((distance - record.c.x) * (span == 0 ? 1 : 1 / span))
        let speed = (record.c.z + t * (record.c.w - record.c.z)) * record.e.w
        let push = cross(normal, axis) * speed * context.dragDeltaTime
        p.velocity += SIMD2(push.x, push.y)
    }

    /// A vortex axis, normalised; z when it is too short (0x1401cd8a2).
    static func vortexAxis(_ value: SIMD4<Float>) -> SIMD3<Float> {
        let axis = SIMD3(value.x, value.y, value.z)
        return simd_length_squared(axis) < 0.001 ? SIMD3(0, 0, 1) : simd_normalize(axis)
    }

    /// `vortex_v2` (0x1402433ea): the vortex spin, plus (flag 2) a pull that keeps the particle's
    /// distance to the axis over the step, and (flag 4) a ring of radius `ringradius` that pulls
    /// particles in from `ringpulldistance`.
    static func vortexV2(_ record: ParticleProgramOp, _ p: inout ParticleProgramState,
                         _ context: ParticleProgramContext, blend: Float) {
        let flags = record.header.y
        let center = point(context.controlPoints, record.controlPoint0)
        let axis = vortexAxis(record.a)
        var offset = SIMD3(p.position.x - center.x, p.position.y - center.y, 0)
        let height = flags & 1 != 0 ? simd_dot(offset, axis) : 0
        offset -= height * axis
        let distance = simd_length(offset)
        guard distance > 0 else { return }
        let normal = offset / distance
        let dt = context.deltaTime
        let ahead = SIMD3(p.position.x + p.velocity.x * dt - center.x, p.position.y + p.velocity.y * dt - center.y, 0)
            - height * axis
        let aheadLength = simd_length(ahead)
        let centerForce = flags & 2 != 0 ? record.c.x : 0
        var pull = aheadLength > 0 ? (distance / aheadLength - 1) * centerForce / dt : 0
        let t: Float
        if flags & 4 != 0 {
            let radius = record.c.y, width = record.c.z, reach = record.c.w
            let gap = radius - distance
            t = saturate((abs(gap) - width) / (reach == 0 ? 1 : reach))
            let sign: Float = gap > 0 ? 1 : (gap < 0 ? -1 : 0)
            pull += (t == 0 ? 0 : 1 - t) * sign * record.d.x * dt
        } else {
            let span = record.b.y - record.b.x
            t = saturate((distance - record.b.x) * (span == 0 ? 1 : 1 / span))
        }
        let speed = (record.b.z + t * (record.b.w - record.b.z)) * record.e.w
        let push = (cross(normal, axis) * speed * context.dragDeltaTime + pull * ahead) * blend
        p.velocity += SIMD2(push.x, push.y)
    }

    /// `boids` (0x140244121): separation, alignment and cohesion with the neighbours in range.
    /// WE spreads the work over frames: with N particles, one group of four in every N/200 + 1 is
    /// updated each frame, against the same slice, with the weights scaled up to match. Groups
    /// here are by spawn order, so both simulations slice alike.
    static func boids(_ record: ParticleProgramOp, _ p: inout ParticleProgramState, _ context: ParticleProgramContext,
                      index: Int, neighbors: Neighbors) {
        let count = neighbors.positions.count
        let slices = UInt32(count / 200 + 1)
        let slice = neighbors.frame % slices
        guard (context.serial / 4) % slices == slice else { return }
        let separationThreshold = record.a.x, neighborThreshold = record.a.y
        var separation = SIMD2<Float>.zero, velocitySum = SIMD2<Float>.zero, positionSum = SIMD2<Float>.zero
        var separated: Float = 0, neighbored: Float = 0
        for j in 0..<count where j != index && (neighbors.serials[j] / 4) % slices == slice {
            let position = context.toSpace * (neighbors.positions[j] - context.space.translation)
            let offset = p.position - position
            let distance = simd_length(offset)
            if distance < separationThreshold, distance > 0 {
                separation += (separationThreshold / distance - 1) * offset
                separated += 1
            }
            if distance < neighborThreshold {
                velocitySum += context.toSpace * neighbors.velocities[j]
                positionSum += position
                neighbored += 1
            }
        }
        let weight = Float(slices) * context.dragDeltaTime
        var change = SIMD2<Float>.zero
        if separated > 0 { change += record.b.x * weight / separated * separation }
        if neighbored > 0 {
            change += record.b.y * weight * (velocitySum / neighbored - p.velocity)
            change += record.b.z * weight * (positionSum / neighbored - p.position)
        }
        var velocity = p.velocity + change
        let maximum = record.a.z
        if record.header.y & 1 != 0,
           simd_length_squared(velocity) > max(simd_length_squared(p.velocity), maximum * maximum) {
            velocity *= maximum / simd_length(velocity)
        }
        p.velocity = velocity
    }

    /// `capvelocity` (0x1402446fd): limits the speed to `maxspeed`.
    static func capVelocity(_ record: ParticleProgramOp, _ p: inout ParticleProgramState, blend: Float, blended: Bool) {
        let speed = simd_length(p.velocity)
        guard speed > 0 else { return }
        let ratio = record.a.x / speed
        p.velocity *= blended ? 1 + blend * min(0, ratio - 1) : min(1, ratio)
    }

    // MARK: - Events and collisions

    /// `inheritvaluefromevent` (0x140249c30): the event's parent particle's values, every step.
    static func inheritValue(_ record: ParticleProgramOp, _ p: inout ParticleProgramState, _ context: ParticleProgramContext) {
        guard let source = context.source else { return }
        let verbs = ParticleInheritance(rawValue: record.header.y)
        let rgb = SIMD3(source.sourceColor.x, source.sourceColor.y, source.sourceColor.z)
        let velocity = context.toSpace * source.sourceVelocity
        if verbs.contains(.setColor) { p.color = rgb }
        if verbs.contains(.multiplyColor) { p.color *= rgb }
        if verbs.contains(.setOpacity) { p.alpha = source.sourceColor.w }
        if verbs.contains(.multiplyOpacity) { p.alpha *= source.sourceColor.w }
        if verbs.contains(.setVelocity) { p.velocity = velocity }
        if verbs.contains(.addVelocity) { p.velocity += velocity }
        if verbs.contains(.setSize) { p.size = source.sourceSize }
        if verbs.contains(.multiplySize) { p.size *= source.sourceSize }
        if verbs.contains(.setRotation) { p.rotation = source.sourceRotation }
        if verbs.contains(.addRotation) { p.rotation += source.sourceRotation }
        if verbs.contains(.setAngularVelocity) { p.angularVelocity = source.sourceAngularVelocity }
        if verbs.contains(.addAngularVelocity) { p.angularVelocity += source.sourceAngularVelocity }
    }

    /// A collision operator: its shapes, placed in the scene this step. True when it deletes the
    /// particle.
    static func collide(_ record: ParticleProgramOp, _ p: inout ParticleProgramState, _ context: ParticleProgramContext) -> Bool {
        let first = Int(record.header.z & 0xFFFF), count = Int(record.header.z >> 16)
        var position = context.space.apply(p.position)
        var velocity = context.space.linear * p.velocity
        let previous = context.space.apply(p.previous)
        var dies = false
        for index in first..<min(first + count, context.collisions.count) {
            context.collisions[index].resolve(position: &position, velocity: &velocity,
                                              angularVelocity: &p.angularVelocity, dies: &dies, previous: previous)
        }
        p.position = context.toSpace * (position - context.space.translation)
        p.velocity = context.toSpace * velocity
        return dies
    }
}
