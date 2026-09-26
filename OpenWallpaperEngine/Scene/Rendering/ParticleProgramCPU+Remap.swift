import Foundation
import simd

/// `remapvalue` (operator, `wallpaper64.exe` 0x140244874) and `remapinitialvalue` (initializer,
/// 0x14023ce53): reads an input, maps it from the input range through a transform to the output
/// range, and sets, multiplies, adds to or subtracts from an output.
///
/// Record: `header.y` flags (1 clamps the normalised input, 2 the output), `header.z` control
/// points (input 0, output 0, input 1, output 1, a byte each), `header.w` the enums (`Code`);
/// `a`/`b` the input range, `c`/`d` the output range, `e.x` `transforminputscale`.
extension ParticleProgramCPU {
    /// The packed enums of a remap record.
    enum RemapCode {
        static func pack(operation: UInt32, input: UInt32, output: UInt32, inputComponent: UInt32,
                         outputComponent: UInt32, transform: UInt32, octaves: UInt32) -> UInt32 {
            operation | input << 4 | output << 9 | inputComponent << 14 | outputComponent << 18 | transform << 22
                | min(octaves, 15) << 26
        }

        static func operation(_ code: UInt32) -> UInt32 { code & 0xF }
        static func input(_ code: UInt32) -> UInt32 { (code >> 4) & 0x1F }
        static func output(_ code: UInt32) -> UInt32 { (code >> 9) & 0x1F }
        static func inputComponent(_ code: UInt32) -> UInt32 { (code >> 14) & 0xF }
        static func outputComponent(_ code: UInt32) -> UInt32 { (code >> 18) & 0xF }
        static func transform(_ code: UInt32) -> UInt32 { (code >> 22) & 0xF }
        static func octaves(_ code: UInt32) -> UInt32 { (code >> 26) & 0xF }
    }

    /// WE's names, in its enum order (the string tables at 0x140484dc0…0x140484f38).
    static let remapOperations = ["remap", "multiply", "add", "subtract"]
    static let remapValues = ["lifetimefraction", "maxlifetime", "size", "opacity", "speed", "rotation", "angularspeed",
                              "distancetocontrolpoint", "positionbetweentwocontrolpoints", "runtime", "timeofday",
                              "particlesystemtime", "layertime", "color", "position", "velocity", "controlpoint",
                              "deltatocontrolpoint", "directiontocontrolpoint", "layerorigin"]
    static let remapComponents = ["all", "x", "y", "z", "sum", "average", "max", "min"]
    static let remapTransforms = ["none", "sine", "square", "saw", "triangle", "simplexnoise", "fbmnoise"]

    /// The remap's value inputs above this index are vectors.
    static let remapVectorInputs: UInt32 = 13

    static func remap(_ record: ParticleProgramOp, _ p: inout ParticleProgramState, _ context: inout ParticleProgramContext,
                      initializer: Bool, blend: Float) {
        let code = record.header.w
        let flags = record.header.y
        let input = RemapCode.input(code)
        var value = remapInput(input, record: record, p, &context, initializer: initializer)
        if input >= remapVectorInputs { value = reduce(value, RemapCode.inputComponent(code)) }
        let low = SIMD3(record.a.x, record.a.y, record.a.z), high = SIMD3(record.b.x, record.b.y, record.b.z)
        var width = high - low
        width = SIMD3(width.x == 0 ? Float.ulpOfOne : width.x, width.y == 0 ? Float.ulpOfOne : width.y,
                      width.z == 0 ? Float.ulpOfOne : width.z)
        value = (value - low) / width
        if flags & 1 != 0 { value = simd_clamp(value, .zero, SIMD3(repeating: 1)) }
        value = transform(value, code: code, scale: record.e.x, random: context.random)
        let outLow = SIMD3(record.c.x, record.c.y, record.c.z), outHigh = SIMD3(record.d.x, record.d.y, record.d.z)
        var mapped = outLow + value * (outHigh - outLow)
        if flags & 2 != 0 { mapped = simd_clamp(mapped, .zero, SIMD3(repeating: 1)) }
        writeRemap(RemapCode.output(code), RemapCode.operation(code), RemapCode.outputComponent(code), mapped,
                   record: record, &p, &context, initializer: initializer, blend: blend)
    }

    /// The input, splatted when it is a scalar. An initializer reads the base size, alpha and
    /// colour; an operator the working ones. Control points are `header.z`'s input bytes (the
    /// output ones for `positionbetweentwocontrolpoints`, WE's quirk).
    ///
    /// The operator (0x140244874…0x140244fef) reads `runtime` and `particlesystemtime` both as the
    /// engine time and the vector control point inputs from the point: `controlpoint`, point −
    /// particle, and its direction. The initializer (0x14023ce53…0x14023d546) reads the system time
    /// for `particlesystemtime`, and for the three control point inputs first writes (0, 0, 0) over
    /// the control point's position, then reads that zero: the point, 0 − particle and its direction.
    static func remapInput(_ input: UInt32, record: ParticleProgramOp, _ p: ParticleProgramState,
                           _ context: inout ParticleProgramContext, initializer: Bool) -> SIMD3<Float> {
        let pointIndex = Int(record.header.z & 0xFF)
        if initializer, (16...18).contains(input) {
            context.controlPoints[min(max(pointIndex, 0), ParticleControlPoint.count - 1)] = .zero
        }
        let cp0 = point(context.controlPoints, pointIndex)
        func splat(_ value: Float) -> SIMD3<Float> { SIMD3(repeating: value) }
        switch input {
        case 0: return splat(p.lifeFraction)
        case 1: return splat(p.lifetime)
        case 2: return splat(initializer ? p.baseSize : p.size)
        case 3: return splat(initializer ? p.baseAlpha : p.alpha)
        case 4: return splat(simd_length(p.velocity))
        case 5: return splat(p.rotation)
        case 6: return splat(p.angularVelocity)
        case 7: return splat(simd_length(p.position - cp0))
        case 8:
            // WE reads the output control points here (0x14023d0b5).
            let a = point(context.controlPoints, Int((record.header.z >> 8) & 0xFF))
            let b = point(context.controlPoints, Int((record.header.z >> 24) & 0xFF))
            let span = b - a
            let length = simd_length_squared(span)
            return splat(length > 0 ? simd_dot(p.position - a, span) / length : 0)
        case 9: return splat(context.engineTime)
        case 10: return splat(context.timeOfDay)
        case 11: return splat(initializer ? context.systemTime : context.engineTime)
        case 12: return splat(context.systemTime)
        case 13: return initializer ? p.baseColor : p.color
        case 14: return SIMD3(p.position.x, p.position.y, 0)
        case 15: return SIMD3(p.velocity.x, p.velocity.y, 0)
        case 16: return SIMD3(cp0.x, cp0.y, 0)
        case 17: return SIMD3(cp0.x - p.position.x, cp0.y - p.position.y, 0)
        case 18:
            let offset = cp0 - p.position
            let length = simd_length(offset)
            return length > 0 ? SIMD3(offset.x / length, offset.y / length, 0) : .zero
        case 19: return SIMD3(context.layerOrigin.x, context.layerOrigin.y, 0)
        default: return .zero
        }
    }

    /// A vector input reduced to one component (splatted), or kept whole.
    static func reduce(_ v: SIMD3<Float>, _ component: UInt32) -> SIMD3<Float> {
        switch component {
        case 1: return SIMD3(repeating: v.x)
        case 2: return SIMD3(repeating: v.y)
        case 3: return SIMD3(repeating: v.z)
        case 4: return SIMD3(repeating: v.x + v.y + v.z)
        case 5: return SIMD3(repeating: (v.x + v.y + v.z) * (1.0 / 3.0))
        case 6: return SIMD3(repeating: max(v.x, v.y, v.z))
        case 7: return SIMD3(repeating: min(v.x, v.y, v.z))
        default: return v
        }
    }

    /// The transform, per component: sine eases 0…1 (`0.5 − 0.5·cos(π·s·v)`), the waves repeat
    /// every 1/s, and the noises are FastNoise2's, seeded by the particle's random value (each
    /// component its own seed, 0x14024562a).
    static func transform(_ v: SIMD3<Float>, code: UInt32, scale: Float, random: Float) -> SIMD3<Float> {
        let seed = Int32(bitPattern: random.bitPattern)
        let seeds = [seed, seed ^ 188_294_317, seed ^ 1_228_574_339]
        let octaves = Int(RemapCode.octaves(code))
        var result = v
        for c in 0..<3 {
            let x = v[c] * scale
            switch RemapCode.transform(code) {
            case 1: result[c] = 0.5 - 0.5 * cos(Float.pi * x)
            case 2: result[c] = x - floor(x) < 0.5 ? 0 : 1
            case 3: result[c] = x - floor(x)
            case 4: result[c] = 1 - abs(2 * (abs(x) - floor(abs(x))) - 1)
            case 5: result[c] = 0.5 + 0.5 * ParticleNoise.seededSimplex2(seed: seeds[c], x, 0)
            case 6: result[c] = 0.5 + 0.5 * ParticleNoise.seededFBm2(seed: seeds[c], x, 0, octaves: octaves)
            default: break
            }
        }
        return result
    }

    /// Applies `value` to the output with the operation (remap sets it), blended. A vector output
    /// takes its component (all, x, y or z); the reductions leave it alone (0x1402464e6).
    ///
    /// The control point outputs (0x140245c9e…0x140246e52): `distancetocontrolpoint` moves the
    /// particle along its line from output control point 0 to the new distance;
    /// `positionbetweentwocontrolpoints` moves it along output points 0 → 1 to the new fraction,
    /// keeping its offset across the line; `controlpoint` writes the point itself, into the
    /// system's shared array (`ParticleProgramContext.controlPoints`), so later particles and records
    /// read it (the operator writes it once per four particles, `ParticleCPUSimulation`);
    /// `deltatocontrolpoint` and `directiontocontrolpoint` set point − particle, and its direction
    /// at the same distance. The time and `layerorigin` outputs write nothing.
    static func writeRemap(_ output: UInt32, _ operation: UInt32, _ component: UInt32, _ value: SIMD3<Float>,
                           record: ParticleProgramOp, _ p: inout ParticleProgramState, _ context: inout ParticleProgramContext,
                           initializer: Bool, blend: Float) {
        func apply(_ old: Float, _ value: Float) -> Float {
            let new: Float
            switch operation {
            case 0: new = value
            case 1: new = old * value
            case 2: new = old + value
            case 3: new = old - value
            default: new = old
            }
            return old + (new - old) * blend
        }
        func applyVector(_ old: SIMD3<Float>) -> SIMD3<Float> {
            var result = old
            for c in 0..<3 where component == 0 || Int(component) - 1 == c {
                result[c] = apply(old[c], value[c])
            }
            return result
        }
        let outputPoint = min(max(Int((record.header.z >> 8) & 0xFF), 0), ParticleControlPoint.count - 1)
        let center = context.controlPoints[outputPoint]
        switch output {
        case 1: p.lifetime = apply(p.lifetime, value.x)
        case 2:
            if initializer { p.baseSize = apply(p.baseSize, value.x) } else { p.size = apply(p.size, value.x) }
        case 3:
            if initializer { p.baseAlpha = apply(p.baseAlpha, value.x) } else { p.alpha = apply(p.alpha, value.x) }
        case 4:
            let speed = simd_length(p.velocity)
            let target = apply(speed, value.x)
            p.velocity = speed > 0 ? p.velocity / speed * target : .zero
        case 5: p.rotation = apply(p.rotation, value.x)
        case 6: p.angularVelocity = apply(p.angularVelocity, value.x)
        case 7:
            let offset = p.position - center
            let distance = simd_length(offset)
            p.position = center + (distance > 0 ? offset / distance : .zero) * apply(distance, value.x)
        case 8:
            let end = point(context.controlPoints, Int((record.header.z >> 24) & 0xFF))
            let span = end - center
            let length = simd_length(span)
            let direction = length > 0 ? span / length : .zero
            let offset = p.position - center
            let along = simd_dot(offset, direction)
            let across = offset - along * direction
            let fraction = length > 0 ? along / length : 0
            p.position = center + across + direction * (apply(fraction, value.x) * length)
        case 13:
            if initializer { p.baseColor = applyVector(p.baseColor) } else { p.color = applyVector(p.color) }
        case 14:
            let moved = applyVector(SIMD3(p.position.x, p.position.y, 0))
            p.position = SIMD2(moved.x, moved.y)
        case 15:
            let moved = applyVector(SIMD3(p.velocity.x, p.velocity.y, 0))
            p.velocity = SIMD2(moved.x, moved.y)
        case 16:
            let moved = applyVector(SIMD3(center.x, center.y, 0))
            context.controlPoints[outputPoint] = SIMD2(moved.x, moved.y)
        case 17:
            let delta = applyVector(SIMD3(center.x - p.position.x, center.y - p.position.y, 0))
            p.position = center - SIMD2(delta.x, delta.y)
        case 18:
            let offset = center - p.position
            let distance = simd_length(offset)
            let direction = distance > 0 ? offset / distance : .zero
            let turned = applyVector(SIMD3(direction.x, direction.y, 0))
            let turnedLength = simd_length(SIMD2(turned.x, turned.y))
            p.position = center - (turnedLength > 0 ? SIMD2(turned.x, turned.y) / turnedLength : .zero) * distance
        default: break
        }
    }

    /// The fraction of the day that has passed, for the `timeofday` input.
    static func fractionOfDay(_ date: Date = Date()) -> Float {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        return Float(date.timeIntervalSince(start) / 86_400)
    }
}
