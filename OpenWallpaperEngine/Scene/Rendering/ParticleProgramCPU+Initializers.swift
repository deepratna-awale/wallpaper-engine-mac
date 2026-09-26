import simd

/// The emitter and the initializer records on the CPU (`wallpaper64.exe`'s spawn, 0x1402378a0:
/// emitter 0x1402379aa, base values 0x14023b340, initializer switch 0x14023b5c0). Lifetime is
/// set; size, colour and alpha initializers multiply the base value; velocity, rotation and spin
/// ones add; the position ones place the particle from where it is. Everything happens in the
/// system's space.
extension ParticleProgramCPU {
    /// The emitter's placement and launch velocity for spawn `serial` (0x140237c14 sphere,
    /// 0x14023847f box).
    static func emit(_ emitter: ParticleEmitterShape, context: ParticleProgramContext) -> (position: SIMD2<Float>, velocity: SIMD2<Float>) {
        func random(_ stream: ParticleRandom.Stream) -> Float {
            ParticleRandom.unit(seed: context.seed, serial: context.serial, stream: stream.rawValue)
        }
        var offset: SIMD3<Float>
        switch emitter.kind {
        case .sphere:
            let phi = 2 * Float.pi * random(.spawnAngle)
            let floor = -cos(emitter.cone * Float.pi)
            let u = floor + random(.spawnHeight) * (1 - floor)
            let s = sqrt(max(1 - u * u, 0))
            let k = pow(random(.spawnRadius), 1 / 3)  // WE: cbrtf (0x1402edfb0)
            let v = SIMD3(k * u, k * sin(phi) * s, k * cos(phi) * s) * emitter.directions
            let length = simd_length(v)
            var direction = length > 0 ? v / length : .zero
            if emitter.appliesSign { direction = signed(direction, emitter.sign) }
            offset = (emitter.distanceMinimum.x + length * (emitter.distanceMaximum.x - emitter.distanceMinimum.x)) * direction
        case .box:
            let a = (SIMD3(random(.spawnAngle), random(.spawnHeight), random(.spawnRadius)) * 2 - 1) * emitter.distanceMaximum
            let span = emitter.distanceMaximum - emitter.distanceMinimum
            let magnitude = emitter.distanceMinimum + simd_abs(a) / simd_max(simd_abs(emitter.distanceMaximum), SIMD3(repeating: .leastNormalMagnitude)) * span
            offset = SIMD3(a.x > 0 ? 1 : (a.x < 0 ? -1 : 0), a.y > 0 ? 1 : (a.y < 0 ? -1 : 0), a.z > 0 ? 1 : (a.z < 0 ? -1 : 0))
                * magnitude
            if emitter.appliesSign { offset = signed(offset, emitter.sign) }
        }
        let turned = context.emitterLinear * SIMD2(offset.x, offset.y)
        let position = point(context.controlPoints, emitter.controlPoint) + SIMD2(emitter.origin.x, emitter.origin.y) + turned
        // A particle at the centre launches in a random direction (0x140237fc8).
        var heading = turned
        if simd_length_squared(SIMD3(turned.x, turned.y, offset.z)) < 0.0001 {
            let fallback = (SIMD3(random(.fallbackX), random(.fallbackY), random(.fallbackZ)) * 2 - 1) * emitter.directions
            heading = context.emitterLinear * SIMD2(fallback.x, fallback.y)
        }
        let length = simd_length(heading)
        let speed = emitter.speed.x + random(.emitterSpeed) * (emitter.speed.y - emitter.speed.x)
        return (position, length > 0 ? heading / length * speed : .zero)
    }

    /// `sign`: forces each axis with a non-zero sign to that sign.
    static func signed(_ v: SIMD3<Float>, _ sign: SIMD3<Float>) -> SIMD3<Float> {
        func one(_ value: Float, _ sign: Float) -> Float { sign == 0 ? value : (sign < 0 ? -abs(value) : abs(value)) }
        return SIMD3(one(v.x, sign.x), one(v.y, sign.y), one(v.z, sign.z))
    }

    /// Runs `initializers` on a spawned particle, in order.
    static func runInitializers(_ initializers: [ParticleProgramOp], on p: inout ParticleProgramState,
                                context: ParticleProgramContext) {
        var context = context
        runInitializers(initializers, on: &p, in: &context)
    }

    /// Runs `initializers` on a spawned particle, in order; a `remapinitialvalue` that writes a
    /// control point writes it into `context` for the spawns after it (`ParticleProgramCPU.remap`).
    static func runInitializers(_ initializers: [ParticleProgramOp], on p: inout ParticleProgramState,
                                in context: inout ParticleProgramContext) {
        for (index, record) in initializers.enumerated() {
            guard let kind = ParticleInitializerKind(rawValue: record.header.x) else { continue }
            func random(_ k: Int) -> Float {
                ParticleRandom.unit(seed: context.seed, serial: context.serial, stream: initializerStream(index, k))
            }
            func ranged(_ k: Int) -> Float { record.a.x + (record.a.y - record.a.x) * shaped(random(k), record.a.z) }
            func vector(_ k: Int) -> SIMD3<Float> {
                let exponent = record.a.w
                return SIMD3(record.a.x + (record.b.x - record.a.x) * shaped(random(k), exponent),
                             record.a.y + (record.b.y - record.a.y) * shaped(random(k + 1), exponent),
                             record.a.z + (record.b.z - record.a.z) * shaped(random(k + 2), exponent))
            }
            switch kind {
            case .lifetimeRandom:
                p.lifetime = max(ranged(0), 0.001) * context.spawnScale.z
            case .sizeRandom:
                p.baseSize *= ranged(0) * context.spawnScale.x
            case .alphaRandom:
                p.baseAlpha *= ranged(0)
            case .colorRandom:
                let t = shaped(random(0), record.a.w)
                let low = SIMD3(record.a.x, record.a.y, record.a.z), high = SIMD3(record.b.x, record.b.y, record.b.z)
                p.baseColor *= low + (high - low) * t
            case .hsvColorRandom:
                // 0x14023b74a: a hue step, then saturation and value.
                let steps = record.a.z
                let step = min(Float(Int(random(0) * (steps + 1))), steps)
                let hue = record.a.x + step * record.a.y
                let saturation = record.b.x + random(1) * (record.b.y - record.b.x)
                let value = record.b.z + random(2) * (record.b.w - record.b.z)
                p.baseColor *= hsvToRGB(hue, saturation, value)
            case .colorList:
                p.baseColor *= colorList(record, random: random)
            case .velocityRandom:
                let v = vector(0) * context.spawnScale.w
                p.velocity += context.emitterLinear * SIMD2(v.x, v.y)
            case .inheritControlPointVelocity:
                let index = record.controlPoint0
                let moved = point(context.controlPoints, index) - point(context.previousControlPoints, index)
                let velocity = context.deltaTime > 0 ? moved / context.deltaTime : .zero
                p.velocity += velocity * (record.a.x + random(0) * (record.a.y - record.a.x))
            case .turbulentVelocityRandom:
                p.velocity += turbulentVelocity(record, random: random, context: context) * context.spawnScale.w
            case .rotationRandom:
                p.rotation += vector(0).z
            case .angularVelocityRandom:
                p.angularVelocity += vector(0).z * context.spawnScale.w
            case .positionOffsetRandom:
                p.position = positionOffset(record, p.position, context: context)
            case .mapSequenceAroundControlPoint:
                sequenceAround(record, &p, context: context, random: random)
            case .mapSequenceBetweenControlPoints:
                sequenceBetween(record, &p, context: context)
            case .remapInitialValue:
                remap(record, &p, &context, initializer: true, blend: 1)
            case .inheritInitialValueFromEvent:
                inheritInitialValue(record, &p, context)
            }
        }
    }

    /// `colorlist` (0x14023b86b): a random colour of the list (HSV), each part jittered by its noise.
    static func colorList(_ record: ParticleProgramOp, random: (Int) -> Float) -> SIMD3<Float> {
        let count = max(Int(record.a.x), 1)
        let colors = [record.b, record.c, record.d, record.e]
        let pick = colors[min(Int(random(0) * Float(count)), min(count, colors.count) - 1)]
        let noise = SIMD3(record.a.y, record.a.z, record.a.w)
        var hsv = SIMD3(pick.x, pick.y, pick.z)
        for channel in 0..<3 {
            let low = max(hsv[channel] - noise[channel], 0), high = min(hsv[channel] + noise[channel], 1)
            hsv[channel] = low + random(1 + channel) * (high - low)
        }
        hsv.x -= floor(hsv.x)
        return hsvToRGB(hsv.x, saturate(hsv.y), saturate(hsv.z))
    }

    /// `turbulentvelocityrandom` (0x14023bdbc): `forward` turned about `right` by 1D simplex noise of
    /// the engine time (plus the particle's phase), at a random speed.
    static func turbulentVelocity(_ record: ParticleProgramOp, random: (Int) -> Float,
                                  context: ParticleProgramContext) -> SIMD2<Float> {
        let phaseRange = (record.a.w - record.a.z) * record.e.w
        let t = (record.a.z + random(0) * phaseRange + context.engineTime) * record.b.x
        let angle = ParticleNoise.simplex1(t) * Float.pi * record.b.y + record.b.z
        let forward = SIMD3(record.c.x, record.c.y, record.c.z), right = SIMD3(record.d.x, record.d.y, record.d.z)
        let direction = rotate(forward, about: right, by: angle)
        let speed = record.a.x + random(1) * (record.a.y - record.a.x)
        return context.emitterLinear * SIMD2(direction.x, direction.y) * speed
    }

    /// `positionoffsetrandom` (0x14023c09a): fBm of 2D simplex noise of the position and the engine
    /// time moves the particle by up to `distance` along `directions`; `sign` forces the direction.
    static func positionOffset(_ record: ParticleProgramOp, _ position: SIMD2<Float>, context: ParticleProgramContext) -> SIMD2<Float> {
        let scale = record.c.x, time = record.c.z * context.engineTime
        let octaves = min(max(Int(record.c.w), 1), 8)
        func fbm(_ sample: (Float) -> Float) -> Float {
            var sum: Float = 0, amplitude: Float = 1, total: Float = 0, frequency: Float = 1
            for _ in 0..<octaves {
                sum += sample(frequency) * amplitude
                total += amplitude
                amplitude *= 0.5
                frequency *= 2
            }
            return sum / total
        }
        let x = fbm { ParticleNoise.simplex2(position.x * scale * $0, time * $0) }
        let y = fbm { ParticleNoise.simplex2(time * $0, position.y * scale * $0) }
        var offset = SIMD3(x, y, 0) * SIMD3(record.a.x, record.a.y, record.a.z)
        if record.header.y & 1 != 0 {
            let sign = SIMD3(record.b.x, record.b.y, record.b.z)
            offset = offset * (1 - simd_abs(sign)) + simd_abs(offset) * sign
        }
        return position + SIMD2(offset.x, offset.y) * record.c.y
    }

    /// `mapsequencearoundcontrolpoint` (0x14023c4cf): the particle keeps the emitter's radius and
    /// height about the axis through the control point; its angle follows the sequence.
    static func sequenceAround(_ record: ParticleProgramOp, _ p: inout ParticleProgramState,
                               context: ParticleProgramContext, random: (Int) -> Float) {
        let t = sequencePosition(index: sequenceIndex(record, context), step: record.a.x, mirror: record.a.w != 0,
                                 between: false)
        let center = point(context.controlPoints, record.controlPoint0)
        let basis = sequenceBasis(SIMD3(record.d.x, record.d.y, record.d.z))
        let offset = SIMD3(p.position.x - center.x, p.position.y - center.y, 0)
        let height = simd_dot(offset, basis.axis)
        let radius = simd_length(offset - height * basis.axis)
        let angle = 2 * Float.pi * (record.a.y + t * (record.a.z - record.a.y))
        let outward = sin(angle) * basis.first + cos(angle) * basis.second
        let tangent = cos(angle) * basis.first - sin(angle) * basis.second
        let placed = SIMD3(center.x, center.y, 0) + height * basis.axis + radius * outward
        p.position = SIMD2(placed.x, placed.y)
        let speedZ = record.b.z + random(0) * (record.c.z - record.b.z)
        let speedX = record.b.x + random(1) * (record.c.x - record.b.x)
        let speedY = record.b.y + random(2) * (record.c.y - record.b.y)
        let push = tangent * speedX + outward * speedY + basis.axis * speedZ
        p.velocity += SIMD2(push.x, push.y)
    }

    /// `mapsequencebetweencontrolpoints` (0x14023ca93): places the particle along the segment
    /// between the two control points, keeping the emitter's spread across it. Flags: 1 tapers the
    /// spread to the ends, 2 scales the velocity the same way, 4 shrinks the size towards the ends
    /// by `sizereductionamount`, 8 bows the line along `arcdirection` by `arcamount`.
    static func sequenceBetween(_ record: ParticleProgramOp, _ p: inout ParticleProgramState, context: ParticleProgramContext) {
        let flags = record.header.y
        let t = sequencePosition(index: sequenceIndex(record, context), step: record.a.x, mirror: record.a.w != 0,
                                 between: true)
        let a = point(context.controlPoints, record.controlPoint0), b = point(context.controlPoints, record.controlPoint1)
        let span = b - a
        let length = max(simd_length(span), Float.leastNormalMagnitude)
        let direction = span / length
        var from = p.position
        if context.worldSpace { from -= a }
        let along = simd_dot(from, direction)
        var across = from - along * direction
        let s = record.a.y + t * (record.a.z - record.a.y)
        let w = 1 - pow(abs(2 * t - 1), 2)
        if flags & 1 != 0 { across *= w }
        var position = a + direction * (s * length) + across
        if flags & 8 != 0 { position += SIMD2(record.c.x, record.c.y) * (w * length * record.b.x) }
        p.position = position
        if flags & 2 != 0 { p.velocity *= w }
        if flags & 4 != 0 { p.baseSize *= (1 - record.b.y) + record.b.y * w }
    }

    /// `inheritinitialvaluefromevent` (0x14023f445): the event's parent particle's values, once.
    static func inheritInitialValue(_ record: ParticleProgramOp, _ p: inout ParticleProgramState,
                                    _ context: ParticleProgramContext) {
        guard let source = context.source else { return }
        let verbs = ParticleInheritance(rawValue: record.header.y)
        let rgb = SIMD3(source.sourceColor.x, source.sourceColor.y, source.sourceColor.z)
        let velocity = context.toSpace * source.sourceVelocity
        if verbs.contains(.setColor) { p.baseColor = rgb }
        if verbs.contains(.multiplyColor) { p.baseColor *= rgb }
        if verbs.contains(.setOpacity) { p.baseAlpha = source.sourceColor.w }
        if verbs.contains(.multiplyOpacity) { p.baseAlpha *= source.sourceColor.w }
        if verbs.contains(.setVelocity) { p.velocity = velocity }
        if verbs.contains(.addVelocity) { p.velocity += velocity }
        if verbs.contains(.setSize) { p.baseSize = source.sourceSize }
        if verbs.contains(.multiplySize) { p.baseSize *= source.sourceSize }
        if verbs.contains(.setRotation) { p.rotation = source.sourceRotation }
        if verbs.contains(.addRotation) { p.rotation += source.sourceRotation }
        if verbs.contains(.setAngularVelocity) { p.angularVelocity = source.sourceAngularVelocity }
        if verbs.contains(.addAngularVelocity) { p.angularVelocity += source.sourceAngularVelocity }
    }
}
