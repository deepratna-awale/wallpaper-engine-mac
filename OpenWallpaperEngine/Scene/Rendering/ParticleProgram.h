#ifndef ParticleProgram_h
#define ParticleProgram_h

#include "ParticleShared.h"
#include "ParticleNoise.h"

// The particle program on the GPU: `ParticleProgramCPU` record for record (the initializer
// switch and operator VM of `wallpaper64.exe`, 0x14023b5c0 / 0x14023fbc0). Change both together.

// Operator kinds (`ParticleOperatorKind`).
constant uint oMovement = 1, oAngularMovement = 2, oAlphaFade = 3, oSizeChange = 4, oColorChange = 5;
constant uint oAlphaChange = 6, oOscillatePosition = 7, oOscillateAlpha = 8, oOscillateSize = 9;
constant uint oControlPointAttract = 10, oMaintainDistance = 11, oMaintainBetween = 12, oReduceMovement = 13;
constant uint oTurbulence = 14, oVortex = 15, oVortexV2 = 16, oBoids = 17, oCapVelocity = 18, oRemapValue = 19;
constant uint oInheritValue = 20, oCollision = 21;

// Initializer kinds (`ParticleInitializerKind`).
constant uint iLifetimeRandom = 1, iSizeRandom = 2, iColorRandom = 3, iHSVColorRandom = 4, iColorList = 5;
constant uint iAlphaRandom = 6, iVelocityRandom = 7, iInheritControlPointVelocity = 8, iTurbulentVelocityRandom = 9;
constant uint iRotationRandom = 10, iPositionOffsetRandom = 11, iAngularVelocityRandom = 12;
constant uint iSequenceAround = 13, iSequenceBetween = 14, iRemapInitialValue = 15, iInheritInitialValue = 16;

/// `ParticleProgramState`.
struct ProgramState {
    float2 position, velocity, previous;
    float age, lifetime, size, baseSize, alpha, baseAlpha, rotation, angularVelocity;
    float3 color, baseColor;
};

/// `ParticleProgramContext`.
struct ProgramContext {
    float deltaTime, engineTime, systemTime, timeOfDay;
    float dragDeltaTime;
    uint seed, serial;
    float random;
    float2 points[8], previousPoints[8];
    float2x2 space, toSpace, emitterLinear;
    float2 origin;
    bool worldSpace;
    bool hasSource;
    ParticleInstanceState source;
    float4 spawnScale;
    uint sequenceIndex, sequenceRestartIndex;
};

static float lifeFraction(thread const ProgramState &p) { return p.age / max(p.lifetime, 0.001f); }

static float2 programPoint(thread const float2 *points, uint index) { return points[min(index, 7u)]; }

static float shaped(float r, float exponent) { return exponent == 1 ? r : pow(r, exponent); }

/// `ParticleProgramCPU.blendFactor`.
static float blendFactor(float4 window, float t) {
    return saturateValue((t - window.x) * window.y) * saturateValue((window.z - t) * window.w);
}

/// `ParticleProgramCPU.progress`.
static float lifeStep(float t, float start, float end) {
    const float span = end - start;
    if (span == 0) return t >= start ? 1.0f : 0.0f;
    return saturateValue((t - start) / span);
}

/// `ParticleProgramCPU.hsvToRGB`.
static float3 hsvToRGB(float h, float s, float v) {
    const float c = v * s;
    const float sector = fmod(h * 6, 6.0f);
    const float x = c * (1 - abs(fmod(sector, 2.0f) - 1));
    const float m = v - c;
    float3 rgb;
    if (sector < 0) rgb = float3(0);
    else if (sector < 1) rgb = float3(c, x, 0);
    else if (sector < 2) rgb = float3(x, c, 0);
    else if (sector < 3) rgb = float3(0, c, x);
    else if (sector < 4) rgb = float3(0, x, c);
    else if (sector < 5) rgb = float3(x, 0, c);
    else rgb = float3(c, 0, x);
    return rgb + m;
}

/// `ParticleProgramCPU.rotate`.
static float3 rotateAbout(float3 v, float3 axis, float angle) {
    const float axisLength = length(axis);
    if (!(axisLength > 1e-6f)) return v;
    const float3 k = axis / axisLength;
    const float c = cos(angle), s = sin(angle);
    return v * c + cross(k, v) * s + k * dot(k, v) * (1 - c);
}

// MARK: - Sequences

/// `ParticleProgramCPU.sequencePosition`.
static float sequencePosition(uint index, float step, bool mirror, bool between) {
    const float travelled = float(index) * step;
    if (mirror) return 1 - abs(fmod(travelled, 2.0f) - 1);
    if (between) {
        const float slots = max(floor(1 / max(step, 1e-6f) + 1e-4f), 0.0f) + 1;
        return fmod(float(index), slots) * step;
    }
    if (!(travelled > 1)) return travelled;
    const float wrapped = travelled - floor(travelled);
    return wrapped == 0 ? 1.0f : wrapped;
}

static uint sequenceIndex(ProgramOp record, thread const ProgramContext &context) {
    const uint restart = record.header.x == iSequenceBetween ? 32u : 2u;
    return (record.header.y & restart) ? context.sequenceRestartIndex : context.sequenceIndex;
}

/// `ParticleProgramCPU.sequenceBasis`.
static void sequenceBasis(float3 axis, thread float3 &unit, thread float3 &first, thread float3 &second) {
    if (all(axis == float3(0))) { unit = float3(0, 0, 1); first = float3(1, 0, 0); second = float3(0, 1, 0); return; }
    unit = normalize(axis);
    if (unit.x == 0 && unit.y == 0) { first = float3(1, 0, 0); second = float3(0, 1, 0); return; }
    first = normalize(float3(unit.y, -unit.x, 0));
    second = normalize(cross(unit, first));
}

// MARK: - Remap

/// `ParticleProgramCPU.remapInput`.
static float3 remapInput(uint input, ProgramOp record, thread const ProgramState &p, thread const ProgramContext &c,
                         bool initializer) {
    const float2 cp0 = programPoint(c.points, record.header.z & 0xFFu);
    switch (input) {
    case 0: return float3(lifeFraction(p));
    case 1: return float3(p.lifetime);
    case 2: return float3(initializer ? p.baseSize : p.size);
    case 3: return float3(initializer ? p.baseAlpha : p.alpha);
    case 4: return float3(length(p.velocity));
    case 5: return float3(p.rotation);
    case 6: return float3(p.angularVelocity);
    case 7: return float3(length(p.position - cp0));
    case 8: {
        const float2 a = programPoint(c.points, (record.header.z >> 8) & 0xFFu);
        const float2 b = programPoint(c.points, (record.header.z >> 24) & 0xFFu);
        const float2 span = b - a;
        const float spanLength = dot(span, span);
        return float3(spanLength > 0 ? dot(p.position - a, span) / spanLength : 0.0f);
    }
    case 9: return float3(c.engineTime);
    case 10: return float3(c.timeOfDay);
    case 11: case 12: return float3(c.systemTime);
    case 13: return initializer ? p.baseColor : p.color;
    case 14: return float3(p.position, 0);
    case 15: return float3(p.velocity, 0);
    case 16: return float3(cp0, 0);
    case 17: return float3(p.position - cp0, 0);
    case 18: {
        const float2 offset = p.position - cp0;
        const float offsetLength = length(offset);
        return offsetLength > 0 ? float3(offset / offsetLength, 0) : float3(0);
    }
    default: return float3(0);
    }
}

/// `ParticleProgramCPU.reduce`.
static float3 remapReduce(float3 v, uint component) {
    switch (component) {
    case 1: return float3(v.x);
    case 2: return float3(v.y);
    case 3: return float3(v.z);
    case 4: return float3(v.x + v.y + v.z);
    case 5: return float3((v.x + v.y + v.z) * (1.0f / 3.0f));
    case 6: return float3(max(max(v.x, v.y), v.z));
    case 7: return float3(min(min(v.x, v.y), v.z));
    default: return v;
    }
}

/// `ParticleProgramCPU.transform`.
static float3 remapTransform(float3 v, uint code, float scale, float random) {
    const int seed = as_type<int>(random);
    const int seeds[3] = { seed, seed ^ 188294317, seed ^ 1228574339 };
    const int octaves = int((code >> 26) & 0xFu);
    const uint transform = (code >> 22) & 0xFu;
    float3 result = v;
    for (int component = 0; component < 3; ++component) {
        const float x = v[component] * scale;
        switch (transform) {
        case 1: result[component] = 0.5f - 0.5f * cos(M_PI_F * x); break;
        case 2: result[component] = x - floor(x) < 0.5f ? 0.0f : 1.0f; break;
        case 3: result[component] = x - floor(x); break;
        case 4: result[component] = 1 - abs(2 * (abs(x) - floor(abs(x))) - 1); break;
        case 5: result[component] = 0.5f + 0.5f * seededSimplex2(seeds[component], x, 0); break;
        case 6: result[component] = 0.5f + 0.5f * seededFBm2(seeds[component], x, 0, octaves); break;
        default: break;
        }
    }
    return result;
}

static float remapApply(uint operation, float old, float value, float blend) {
    float result;
    switch (operation) {
    case 0: result = value; break;
    case 1: result = old * value; break;
    case 2: result = old + value; break;
    case 3: result = old - value; break;
    default: result = old; break;
    }
    return old + (result - old) * blend;
}

static float3 remapApplyVector(uint operation, uint component, float3 old, float3 value, float blend) {
    float3 result = old;
    for (int c = 0; c < 3; ++c) {
        if (component == 0 || component > 3 || int(component) - 1 == c) result[c] = remapApply(operation, old[c], value[c], blend);
    }
    return result;
}

/// `ParticleProgramCPU.remap`.
static void remap(ProgramOp record, thread ProgramState &p, thread const ProgramContext &c, bool initializer, float blend) {
    const uint code = record.header.w;
    const uint flags = record.header.y;
    const uint input = (code >> 4) & 0x1Fu;
    float3 value = remapInput(input, record, p, c, initializer);
    if (input >= 13) value = remapReduce(value, (code >> 14) & 0xFu);
    float3 width = record.b.xyz - record.a.xyz;
    width = float3(width.x == 0 ? FLT_EPSILON : width.x, width.y == 0 ? FLT_EPSILON : width.y,
                   width.z == 0 ? FLT_EPSILON : width.z);
    value = (value - record.a.xyz) / width;
    if (flags & 1u) value = clamp(value, float3(0), float3(1));
    value = remapTransform(value, code, record.e.x, c.random);
    float3 mapped = record.c.xyz + value * (record.d.xyz - record.c.xyz);
    if (flags & 2u) mapped = clamp(mapped, float3(0), float3(1));
    const uint operation = code & 0xFu, output = (code >> 9) & 0x1Fu, component = (code >> 18) & 0xFu;
    switch (output) {
    case 1: p.lifetime = remapApply(operation, p.lifetime, mapped.x, blend); break;
    case 2:
        if (initializer) p.baseSize = remapApply(operation, p.baseSize, mapped.x, blend);
        else p.size = remapApply(operation, p.size, mapped.x, blend);
        break;
    case 3:
        if (initializer) p.baseAlpha = remapApply(operation, p.baseAlpha, mapped.x, blend);
        else p.alpha = remapApply(operation, p.alpha, mapped.x, blend);
        break;
    case 4: {
        const float speed = length(p.velocity);
        const float target = remapApply(operation, speed, mapped.x, blend);
        p.velocity = speed > 0 ? p.velocity / speed * target : float2(0);
        break;
    }
    case 5: p.rotation = remapApply(operation, p.rotation, mapped.x, blend); break;
    case 6: p.angularVelocity = remapApply(operation, p.angularVelocity, mapped.x, blend); break;
    case 13:
        if (initializer) p.baseColor = remapApplyVector(operation, component, p.baseColor, mapped, blend);
        else p.color = remapApplyVector(operation, component, p.color, mapped, blend);
        break;
    case 14: p.position = remapApplyVector(operation, component, float3(p.position, 0), mapped, blend).xy; break;
    case 15: p.velocity = remapApplyVector(operation, component, float3(p.velocity, 0), mapped, blend).xy; break;
    default: break;
    }
}

// MARK: - Inheritance

/// `ParticleProgramCPU.inheritValue` / `inheritInitialValue`.
static void inheritFromSource(uint verbs, thread ProgramState &p, thread const ProgramContext &c, bool initializer) {
    if (!c.hasSource) return;
    const ParticleInstanceState source = c.source;
    const float3 rgb = source.sourceColor.xyz;
    const float2 velocity = c.toSpace * source.source.xy;
    thread float3 &color = initializer ? p.baseColor : p.color;
    thread float &alpha = initializer ? p.baseAlpha : p.alpha;
    thread float &size = initializer ? p.baseSize : p.size;
    if (verbs & hSetColor) color = rgb;
    if (verbs & hMultiplyColor) color *= rgb;
    if (verbs & hSetOpacity) alpha = source.sourceColor.w;
    if (verbs & hMultiplyOpacity) alpha *= source.sourceColor.w;
    if (verbs & hSetVelocity) p.velocity = velocity;
    if (verbs & hAddVelocity) p.velocity += velocity;
    if (verbs & hSetSize) size = source.source.z;
    if (verbs & hMultiplySize) size *= source.source.z;
    if (verbs & hSetRotation) p.rotation = source.source.w;
    if (verbs & hAddRotation) p.rotation += source.source.w;
    if (verbs & hSetAngularVelocity) p.angularVelocity = source.emission.x;
    if (verbs & hAddAngularVelocity) p.angularVelocity += source.emission.x;
}

// MARK: - Emitter and initializers

/// `ParticleProgramCPU.signed`.
static float3 signedVector(float3 v, float3 sign) {
    float3 result = v;
    for (int i = 0; i < 3; ++i) {
        if (sign[i] != 0) result[i] = sign[i] < 0 ? -abs(v[i]) : abs(v[i]);
    }
    return result;
}

/// `ParticleProgramCPU.emit`.
static void emitParticle(EmitterParameters e, thread const ProgramContext &c, thread float2 &position,
                         thread float2 &velocity) {
    const uint seed = c.seed, serial = c.serial;
    const float3 directions = e.directions.xyz;
    float3 offset;
    if (e.flags.x != 0) {
        const float3 a = (float3(unitRandom(seed, serial, sSpawnAngle), unitRandom(seed, serial, sSpawnHeight),
                                 unitRandom(seed, serial, sSpawnRadius)) * 2 - 1) * e.maximum.xyz;
        const float3 span = e.maximum.xyz - e.minimum.xyz;
        const float3 magnitude = e.minimum.xyz + abs(a) / max(abs(e.maximum.xyz), float3(FLT_MIN)) * span;
        offset = sign(a) * magnitude;
        if (e.flags.y != 0) offset = signedVector(offset, e.sign.xyz);
    } else {
        const float phi = 2 * M_PI_F * unitRandom(seed, serial, sSpawnAngle);
        const float floorValue = e.directions.w;
        const float u = floorValue + unitRandom(seed, serial, sSpawnHeight) * (1 - floorValue);
        const float s = sqrt(max(1 - u * u, 0.0f));
        const float k = pow(unitRandom(seed, serial, sSpawnRadius), 1.0f / 3.0f);
        const float3 v = float3(k * u, k * sin(phi) * s, k * cos(phi) * s) * directions;
        const float vLength = length(v);
        float3 direction = vLength > 0 ? v / vLength : float3(0);
        if (e.flags.y != 0) direction = signedVector(direction, e.sign.xyz);
        offset = (e.minimum.x + vLength * (e.maximum.x - e.minimum.x)) * direction;
    }
    const float2 turned = c.emitterLinear * offset.xy;
    position = programPoint(c.points, uint(e.origin.w)) + e.origin.xy + turned;
    float2 heading = turned;
    if (length_squared(float3(turned, offset.z)) < 0.0001f) {
        const float3 fallback = (float3(unitRandom(seed, serial, sFallbackX), unitRandom(seed, serial, sFallbackY),
                                        unitRandom(seed, serial, sFallbackZ)) * 2 - 1) * directions;
        heading = c.emitterLinear * fallback.xy;
    }
    const float headingLength = length(heading);
    const float speed = e.minimum.w + unitRandom(seed, serial, sEmitterSpeed) * (e.maximum.w - e.minimum.w);
    velocity = headingLength > 0 ? heading / headingLength * speed : float2(0);
}

/// `ParticleProgramCPU.runInitializers`.
static void runInitializers(constant ProgramOp *records, uint count, thread ProgramState &p, thread const ProgramContext &c) {
    for (uint index = 0; index < count; ++index) {
        const ProgramOp record = records[index];
        const uint seed = c.seed, serial = c.serial;
        switch (record.header.x) {
        case iLifetimeRandom:
            p.lifetime = max(record.a.x + (record.a.y - record.a.x) * shaped(unitRandom(seed, serial, initializerStream(index, 0)), record.a.z),
                             0.001f) * c.spawnScale.z;
            break;
        case iSizeRandom:
            p.baseSize *= (record.a.x + (record.a.y - record.a.x) * shaped(unitRandom(seed, serial, initializerStream(index, 0)), record.a.z))
                * c.spawnScale.x;
            break;
        case iAlphaRandom:
            p.baseAlpha *= record.a.x + (record.a.y - record.a.x) * shaped(unitRandom(seed, serial, initializerStream(index, 0)), record.a.z);
            break;
        case iColorRandom: {
            const float t = shaped(unitRandom(seed, serial, initializerStream(index, 0)), record.a.w);
            p.baseColor *= record.a.xyz + (record.b.xyz - record.a.xyz) * t;
            break;
        }
        case iHSVColorRandom: {
            const float steps = record.a.z;
            const float step = min(float(int(unitRandom(seed, serial, initializerStream(index, 0)) * (steps + 1))), steps);
            const float hue = record.a.x + step * record.a.y;
            const float saturation = record.b.x + unitRandom(seed, serial, initializerStream(index, 1)) * (record.b.y - record.b.x);
            const float value = record.b.z + unitRandom(seed, serial, initializerStream(index, 2)) * (record.b.w - record.b.z);
            p.baseColor *= hsvToRGB(hue, saturation, value);
            break;
        }
        case iColorList: {
            const int listCount = max(int(record.a.x), 1);
            const float4 colors[4] = { record.b, record.c, record.d, record.e };
            const int pick = min(int(unitRandom(seed, serial, initializerStream(index, 0)) * float(listCount)), min(listCount, 4) - 1);
            float3 hsv = colors[pick].xyz;
            const float3 noise = record.a.yzw;
            for (int channel = 0; channel < 3; ++channel) {
                const float low = max(hsv[channel] - noise[channel], 0.0f), high = min(hsv[channel] + noise[channel], 1.0f);
                hsv[channel] = low + unitRandom(seed, serial, initializerStream(index, 1 + channel)) * (high - low);
            }
            hsv.x -= floor(hsv.x);
            p.baseColor *= hsvToRGB(hsv.x, saturateValue(hsv.y), saturateValue(hsv.z));
            break;
        }
        case iVelocityRandom: case iRotationRandom: case iAngularVelocityRandom: {
            const float exponent = record.a.w;
            const float3 v = float3(record.a.x + (record.b.x - record.a.x) * shaped(unitRandom(seed, serial, initializerStream(index, 0)), exponent),
                                    record.a.y + (record.b.y - record.a.y) * shaped(unitRandom(seed, serial, initializerStream(index, 1)), exponent),
                                    record.a.z + (record.b.z - record.a.z) * shaped(unitRandom(seed, serial, initializerStream(index, 2)), exponent));
            if (record.header.x == iVelocityRandom) p.velocity += c.emitterLinear * (v.xy * c.spawnScale.w);
            else if (record.header.x == iRotationRandom) p.rotation += v.z;
            else p.angularVelocity += v.z * c.spawnScale.w;
            break;
        }
        case iInheritControlPointVelocity: {
            const uint point = record.header.z & 0xFFu;
            const float2 moved = programPoint(c.points, point) - programPoint(c.previousPoints, point);
            const float2 velocity = c.deltaTime > 0 ? moved / c.deltaTime : float2(0);
            p.velocity += velocity * (record.a.x + unitRandom(seed, serial, initializerStream(index, 0)) * (record.a.y - record.a.x));
            break;
        }
        case iTurbulentVelocityRandom: {
            const float phaseRange = (record.a.w - record.a.z) * record.e.w;
            const float t = (record.a.z + unitRandom(seed, serial, initializerStream(index, 0)) * phaseRange + c.engineTime) * record.b.x;
            const float angle = simplex1(t) * M_PI_F * record.b.y + record.b.z;
            const float3 direction = rotateAbout(record.c.xyz, record.d.xyz, angle);
            const float speed = record.a.x + unitRandom(seed, serial, initializerStream(index, 1)) * (record.a.y - record.a.x);
            p.velocity += c.emitterLinear * direction.xy * speed * c.spawnScale.w;
            break;
        }
        case iPositionOffsetRandom: {
            const float scale = record.c.x, time = record.c.z * c.engineTime;
            const int octaves = clamp(int(record.c.w), 1, 8);
            float sumX = 0, sumY = 0, amplitude = 1, total = 0, frequency = 1;
            for (int octave = 0; octave < octaves; ++octave) {
                sumX += simplex2(p.position.x * scale * frequency, time * frequency) * amplitude;
                sumY += simplex2(time * frequency, p.position.y * scale * frequency) * amplitude;
                total += amplitude;
                amplitude *= 0.5f;
                frequency *= 2;
            }
            float3 offset = float3(sumX / total, sumY / total, 0) * record.a.xyz;
            if (record.header.y & 1u) offset = offset * (1 - abs(record.b.xyz)) + abs(offset) * record.b.xyz;
            p.position += offset.xy * record.c.y;
            break;
        }
        case iSequenceAround: {
            const float t = sequencePosition(sequenceIndex(record, c), record.a.x, record.a.w != 0, false);
            const float2 center = programPoint(c.points, record.header.z & 0xFFu);
            float3 axis, first, second;
            sequenceBasis(record.d.xyz, axis, first, second);
            const float3 offset = float3(p.position - center, 0);
            const float height = dot(offset, axis);
            const float radius = length(offset - height * axis);
            const float angle = 2 * M_PI_F * (record.a.y + t * (record.a.z - record.a.y));
            const float3 outward = sin(angle) * first + cos(angle) * second;
            const float3 tangent = cos(angle) * first - sin(angle) * second;
            p.position = (float3(center, 0) + height * axis + radius * outward).xy;
            const float speedZ = record.b.z + unitRandom(seed, serial, initializerStream(index, 0)) * (record.c.z - record.b.z);
            const float speedX = record.b.x + unitRandom(seed, serial, initializerStream(index, 1)) * (record.c.x - record.b.x);
            const float speedY = record.b.y + unitRandom(seed, serial, initializerStream(index, 2)) * (record.c.y - record.b.y);
            p.velocity += (tangent * speedX + outward * speedY + axis * speedZ).xy;
            break;
        }
        case iSequenceBetween: {
            const uint flags = record.header.y;
            const float t = sequencePosition(sequenceIndex(record, c), record.a.x, record.a.w != 0, true);
            const float2 a = programPoint(c.points, record.header.z & 0xFFu), b = programPoint(c.points, (record.header.z >> 8) & 0xFFu);
            const float2 span = b - a;
            const float spanLength = max(length(span), FLT_MIN);
            const float2 direction = span / spanLength;
            float2 from = p.position;
            if (c.worldSpace) from -= a;
            const float along = dot(from, direction);
            float2 across = from - along * direction;
            const float s = record.a.y + t * (record.a.z - record.a.y);
            const float w = 1 - pow(abs(2 * t - 1), 2.0f);
            if (flags & 1u) across *= w;
            float2 position = a + direction * (s * spanLength) + across;
            if (flags & 8u) position += record.c.xy * (w * spanLength * record.b.x);
            p.position = position;
            if (flags & 2u) p.velocity *= w;
            if (flags & 4u) p.baseSize *= (1 - record.b.y) + record.b.y * w;
            break;
        }
        case iRemapInitialValue: remap(record, p, c, true, 1); break;
        case iInheritInitialValue: inheritFromSource(record.header.y, p, c, true); break;
        default: break;
        }
    }
}

// MARK: - Operators

/// A vortex axis, normalised; z when too short.
static float3 vortexAxis(float3 axis) { return length_squared(axis) < 0.001f ? float3(0, 0, 1) : normalize(axis); }

/// The oscillators' frequency, phase and scale.
static float3 oscillator(ProgramOp record, float r) {
    return float3(record.b.x + r * (record.b.y - record.b.x), record.b.z + r * (record.b.w - record.b.z),
                  record.c.x + r * (record.c.y - record.c.x));
}

static float oscillation(ProgramOp record, thread const ProgramState &p, thread const ProgramContext &c) {
    const float r = c.random;
    const float3 o = oscillator(record, r);
    const float wave = sin(o.x * (p.age + o.y));
    return record.c.x + (wave + 1) * 0.5f * r * (record.c.y - record.c.x);
}

/// `ParticleProgramCPU.collide`: `collisions[first…]`, carried by `shift`, in the scene.
static bool programCollide(ProgramOp record, thread ProgramState &p, thread const ProgramContext &c,
                           constant CollisionPlacement *collisions, uint collisionCount, float2 shift);

/// `ParticleProgramCPU.runOperators`. `neighbors` are the step's particles (scene space) for boids;
/// true when an operator deletes the particle.
static bool runOperators(constant ProgramOp *records, uint count, thread ProgramState &p, thread const ProgramContext &c,
                         constant CollisionPlacement *collisions, uint collisionCount, float2 shift,
                         device const ParticleState *neighbors, uint neighborCount, uint self, uint liveCount,
                         uint frame, device const uint *alive, uint aged) {
    bool dies = false;
    p.size = p.baseSize;
    p.alpha = p.baseAlpha;
    p.color = p.baseColor;
    p.previous = p.position;
    const float dt = c.deltaTime;
    for (uint index = 0; index < count; ++index) {
        const ProgramOp record = records[index];
        const bool blended = record.blend.x >= -1;
        const float blend = blended ? blendFactor(record.blend, lifeFraction(p)) : 1.0f;
        const uint flags = record.header.y;
        switch (record.header.x) {
        case oMovement: {
            float2 gravity = record.a.xy;
            if ((flags & 1u) && !c.worldSpace) gravity = c.toSpace * gravity;
            const float damping = 1 - min(record.a.w * c.dragDeltaTime, 1.0f);
            const float2 velocity = p.velocity + gravity * dt;
            p.previous = p.position;
            p.position += velocity * dt;
            p.velocity = velocity * damping;
            break;
        }
        case oAngularMovement: {
            const float damping = min(record.a.w * c.dragDeltaTime, 1.0f);
            const float spin = p.angularVelocity + blend * record.a.z * dt;
            p.rotation += blend * dt * spin;
            p.angularVelocity = spin * (1 - blend * damping);
            break;
        }
        case oAlphaFade: {
            const float t = lifeFraction(p);
            const float fadeIn = record.a.x, fadeOut = record.a.y;
            p.alpha *= t < fadeIn ? t / fadeIn : (fadeOut < t ? (1 - t) / (1 - fadeOut) : 1.0f);
            break;
        }
        case oSizeChange:
            p.size *= record.a.x + (record.a.y - record.a.x) * lifeStep(lifeFraction(p), record.a.z, record.a.w);
            break;
        case oAlphaChange:
            p.alpha *= record.a.x + (record.a.y - record.a.x) * lifeStep(lifeFraction(p), record.a.z, record.a.w);
            break;
        case oColorChange: {
            const float w = lifeStep(lifeFraction(p), record.c.x, record.c.y);
            p.color *= record.a.xyz + (record.b.xyz - record.a.xyz) * w;
            break;
        }
        case oOscillatePosition: {
            const float r = c.random;
            const float3 o = oscillator(record, r);
            const float scale = o.z * blend;
            const float now = p.age + o.y, before = p.age - dt + o.y;
            const float shift2 = 2 * M_PI_F * r;
            const float x = sin(o.x * now) - sin(o.x * before);
            const float y = sin(o.x * (now + shift2)) - sin(o.x * (before + shift2));
            p.position += float2(x * scale * record.a.x, y * scale * record.a.y);
            break;
        }
        case oOscillateAlpha: {
            const float value = oscillation(record, p, c);
            p.alpha *= blended ? 1 - (1 - value) * blend : value;
            break;
        }
        case oOscillateSize: {
            const float value = oscillation(record, p, c);
            p.size *= blended ? 1 + (value - 1) * blend : value;
            break;
        }
        case oControlPointAttract: {
            const float2 center = programPoint(c.points, record.header.z & 0xFFu);
            const float2 offset = p.position - center;
            const float distance = length(offset);
            const float scale = record.b.x, threshold = record.b.y;
            if (distance > FLT_MIN && distance < threshold) {
                float force = (1 - distance / threshold) * scale * c.dragDeltaTime * blend;
                if ((flags & 2u) && distance < force) force = distance;
                p.velocity -= offset / distance * force;
            }
            if (flags & 1u) {
                const float2 segment = p.position - p.previous;
                const float segmentLength = dot(segment, segment);
                const float t = segmentLength > 0 ? saturateValue(dot(center - p.previous, segment) / segmentLength) : 0.0f;
                const float2 closest = p.previous + segment * t;
                if (length_squared(center - closest) <= record.b.z * record.b.z) dies = true;
            }
            break;
        }
        case oMaintainDistance: {
            const uint point = record.header.z & 0xFFu;
            const float2 center = programPoint(c.points, point);
            const float2 moved = p.position + (center - programPoint(c.previousPoints, point));
            const float2 offset = moved - center;
            const float offsetLength = length(offset);
            const float strength = record.a.y == 0 ? 1.0f : saturateValue(record.a.y * dt);
            p.position = offsetLength > 0 ? moved + offset * (record.a.x / offsetLength - 1) * strength * blend : moved;
            break;
        }
        case oMaintainBetween: {
            const uint first = record.header.z & 0xFFu, second = (record.header.z >> 8) & 0xFFu;
            const float2 a = programPoint(c.points, first), b = programPoint(c.points, second);
            const float2 aBefore = programPoint(c.previousPoints, first), bBefore = programPoint(c.previousPoints, second);
            const float2 span = b - a, spanBefore = bBefore - aBefore;
            const float limit = 1.42109e-14f;
            if (length_squared(span) > limit && length_squared(spanBefore) > limit) {
                const float lengthBefore = length(spanBefore);
                const float2 directionBefore = spanBefore / lengthBefore;
                const float along = dot(p.position - aBefore, directionBefore);
                const float t = saturateValue(along / lengthBefore);
                p.position += (a - aBefore + span * t - directionBefore * along) * blend;
            }
            break;
        }
        case oReduceMovement: {
            const float distance = length(p.position - programPoint(c.points, record.header.z & 0xFFu));
            const float span = record.a.y - record.a.x;
            const float t = saturateValue((distance - record.a.x) * (span == 0 ? 1.0f : 1 / span));
            const float reductionSpan = record.a.w == record.a.z ? 1.0f : record.a.w - record.a.z;
            const float reduction = record.a.z + t * reductionSpan;
            p.velocity *= 1 - blend * saturateValue(reduction * dt);
            break;
        }
        case oTurbulence: {
            const float r = c.random;
            const float phase = r * (record.c.y - record.c.x) + c.engineTime * record.b.w;
            const float3 point = float3(p.position.x + phase, p.position.y + phase, phase) * record.b.x;
            const float speed = (record.b.y + r * (record.b.z - record.b.y)) * record.e.w * blend;
            const float push = c.dragDeltaTime * speed;
            p.velocity.x += simplex3(point.x, point.y, point.z) * record.a.x * push;
            p.velocity.y += simplex3(point.z, point.x, point.y) * record.a.y * push;
            break;
        }
        case oVortex: {
            const float2 center = programPoint(c.points, record.header.z & 0xFFu) + record.a.xy;
            const float3 axis = vortexAxis(record.b.xyz);
            float3 offset = float3(p.position - center, 0);
            if (flags & 1u) offset -= dot(offset, axis) * axis;
            const float distance = length(offset);
            if (distance > 0) {
                const float3 normal = offset / distance;
                const float span = record.c.y - record.c.x;
                const float t = saturateValue((distance - record.c.x) * (span == 0 ? 1.0f : 1 / span));
                const float speed = (record.c.z + t * (record.c.w - record.c.z)) * record.e.w;
                p.velocity += (cross(normal, axis) * speed * c.dragDeltaTime).xy;
            }
            break;
        }
        case oVortexV2: {
            const float2 center = programPoint(c.points, record.header.z & 0xFFu);
            const float3 axis = vortexAxis(record.a.xyz);
            float3 offset = float3(p.position - center, 0);
            const float height = (flags & 1u) ? dot(offset, axis) : 0.0f;
            offset -= height * axis;
            const float distance = length(offset);
            if (distance > 0) {
                const float3 normal = offset / distance;
                const float3 ahead = float3(p.position + p.velocity * dt - center, 0) - height * axis;
                const float aheadLength = length(ahead);
                const float centerForce = (flags & 2u) ? record.c.x : 0.0f;
                float pull = aheadLength > 0 ? (distance / aheadLength - 1) * centerForce / dt : 0.0f;
                float t;
                if (flags & 4u) {
                    const float radius = record.c.y, width = record.c.z, reach = record.c.w;
                    const float gap = radius - distance;
                    t = saturateValue((abs(gap) - width) / (reach == 0 ? 1.0f : reach));
                    const float gapSign = gap > 0 ? 1.0f : (gap < 0 ? -1.0f : 0.0f);
                    pull += (t == 0 ? 0.0f : 1 - t) * gapSign * record.d.x * dt;
                } else {
                    const float span = record.b.y - record.b.x;
                    t = saturateValue((distance - record.b.x) * (span == 0 ? 1.0f : 1 / span));
                }
                const float speed = (record.b.z + t * (record.b.w - record.b.z)) * record.e.w;
                p.velocity += ((cross(normal, axis) * speed * c.dragDeltaTime + pull * ahead) * blend).xy;
            }
            break;
        }
        case oBoids: {
            const uint slices = liveCount / 200 + 1;
            const uint slice = frame % slices;
            if ((c.serial / 4) % slices != slice) break;
            const float separationThreshold = record.a.x, neighborThreshold = record.a.y;
            float2 separation = float2(0), velocitySum = float2(0), positionSum = float2(0);
            float separated = 0, neighbored = 0;
            for (uint j = 0; j < neighborCount; ++j) {
                if (j == self || (j < aged && alive[j] == 0)) continue;
                const ParticleState other = neighbors[j];
                if ((other.identity.x / 4) % slices != slice) continue;
                const float2 position = c.toSpace * (other.positionVelocity.xy - c.origin);
                const float2 offset = p.position - position;
                const float distance = length(offset);
                if (distance < separationThreshold && distance > 0) {
                    separation += (separationThreshold / distance - 1) * offset;
                    separated += 1;
                }
                if (distance < neighborThreshold) {
                    velocitySum += c.toSpace * other.positionVelocity.zw;
                    positionSum += position;
                    neighbored += 1;
                }
            }
            const float weight = float(slices) * c.dragDeltaTime;
            float2 change = float2(0);
            if (separated > 0) change += record.b.x * weight / separated * separation;
            if (neighbored > 0) {
                change += record.b.y * weight * (velocitySum / neighbored - p.velocity);
                change += record.b.z * weight * (positionSum / neighbored - p.position);
            }
            float2 velocity = p.velocity + change;
            const float maximum = record.a.z;
            if ((flags & 1u) && length_squared(velocity) > max(length_squared(p.velocity), maximum * maximum)) {
                velocity *= maximum / length(velocity);
            }
            p.velocity = velocity;
            break;
        }
        case oCapVelocity: {
            const float speed = length(p.velocity);
            if (speed > 0) {
                const float ratio = record.a.x / speed;
                p.velocity *= blended ? 1 + blend * min(0.0f, ratio - 1) : min(1.0f, ratio);
            }
            break;
        }
        case oRemapValue: remap(record, p, c, false, blend); break;
        case oInheritValue: inheritFromSource(flags, p, c, false); break;
        case oCollision:
            if (programCollide(record, p, c, collisions, collisionCount, shift)) dies = true;
            break;
        default: break;
        }
    }
    return dies;
}

#endif
