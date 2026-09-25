#include <metal_stdlib>
using namespace metal;

// The particle simulation on the GPU. It is `ParticleCPUSimulation` step for step: the same
// emission arithmetic, initializers, operator order and random draws (`ParticleRandom`), so the
// two stay interchangeable (`ParticleSimulationParityTests`). Structures mirror
// `ParticleGPUTypes.swift`; `particleLayoutSizes` lets a test check the two agree.
//
// One frame of one system, all in one compute encoder (`ParticleGPUSimulator`):
//   begin → emit → simulate → scan → compact → [trail scan] → finish → write records.
// Particles stay in spawn order: the compaction is an order-preserving prefix sum, so rope
// neighbours and boids' neighbour sampling match the CPU's array.

// MARK: - Shared layouts

struct ParticleState {
    float4 positionVelocity; // position xy, velocity zw
    float4 life;             // age, lifetime, size, base size
    float4 alphaRotation;    // alpha, base alpha, rotation, angular velocity
    float4 color;
    float4 baseColor;
    float4 trail;            // history timer, sequence
    uint4 identity;          // serial, sprite frame, history count, history start
};

struct ParticleParameters {
    uint4 counts;            // maximum, flags, seed, history limit
    float4 lifetimeSize;     // lifetime min, max, size min, max
    float4 alphaRotation;    // alpha min, max, rotation min, max
    float4 angularSpawn;     // angular velocity min, max, spawn extent xy
    float4 velocityRange;    // minimum xy, maximum xy
    float4 velocityRotation; // column 0 xy, column 1 xy
    float4 colorMinimum;
    float4 colorMaximum;
    float4 offsetRange;      // minimum xy, maximum xy
    float4 sequence;         // count, arc amount, mirrored, ring turns
    float4 ringAxisBounds;   // axis xy, bounds min, max
    float4 ringSpeed;        // minimum xy, maximum xy
    float4 initialRemap;     // range min, max, multiply, output (0 size, 1 alpha, 2 velocity)
    float4 gravity;          // gravity xy, maximum speed, angular acceleration
    float4 turbulence;       // scale, speed min, max, time scale
    float4 turbulenceMask;   // phase, mask xy
    float4 attractor;        // strength, threshold
    float4 vortex;           // origin xy, inner speed, outer speed
    float4 vortexDistance;   // inner, outer
    float4 boids;            // alignment, cohesion, separation, threshold
    float4 reduction;        // origin xy, inner distance, outer distance
    float4 constraint;       // reduction amount, constraint origin xy, strength
    float4 sizeChange;       // start time, end time, start value, end value
    float4 alphaChange;
    float4 colorChangeTime;  // start time, end time
    float4 colorChangeStart;
    float4 colorChangeEnd;
    float4 oscillateSize;    // frequency, scale, phase (range middles)
    float4 oscillateAlpha;
    float4 oscillatePosition;
    float4 remapAlpha;       // scale, output min, max, sine
    float4 trail;            // history interval, trail length, rope subdivision, fades (1 alpha, 2 size)
    float4 spriteSheet;      // frames, columns, rows, duration
    float4 sprite;           // mode (0 sequence, 1 once, 2 random frame), sequence multiplier, opacity multiplier, refractive
};

struct ParticleFrame {
    float4 time;     // delta, elapsed, emission rate, drag
    float4 fade;     // fade in, fade out, clears
    float4 points;   // spawn origin xy, attractor origin xy
    float4 sequence; // start xy, end xy
    float4 anchor;   // remap anchor xy, has sequence
    float4 scene;    // scene size xy, target size xy
    uint4 indices;   // frame index, material vertex count, render-var offset in floats (~0: none), draw kind
};

// `ParticleSpriteInstance` and `ParticleRopeSegmentInstance` (ParticleInstanceLayout.swift).
struct SpriteRecord { float4 position; float4 rotationSize; float4 velocityLifetime; float4 color; };
struct RopeRecord { float4 start; float4 end; float4 previous; float4 next; float4 endColor; float4 color; };

// `LayerUniform` (SceneShaders.metal): the built-in particle draw's instances.
struct FallbackInstance {
    float2 position;
    float2 size;
    float2 sceneSize;
    float opacity;
    float particleShape;
    float rotation;
    float4 color;
    float2 uvOrigin;
    float2 uvAxisX;
    float2 uvAxisY;
    float4 effects;
    float blur;
    float4 colorEffects;
    float4 transform;
    float transformScaleY;
    float4 bloomTint;
    float2 quadAxisX;
    float2 quadAxisY;
};

// Flags (`ParticleGPUParameters.Flag`).
constant uint kTurbulence = 1u << 0, kAttractor = 1u << 1, kVortex = 1u << 2, kBoids = 1u << 3;
constant uint kReduction = 1u << 4, kConstraint = 1u << 5, kMaintainSequence = 1u << 6, kSizeChange = 1u << 7;
constant uint kAlphaChange = 1u << 8, kColorChange = 1u << 9, kOscillateSize = 1u << 10, kOscillateAlpha = 1u << 11;
constant uint kOscillatePosition = 1u << 12, kRemapAlpha = 1u << 13, kSequenceSpan = 1u << 14, kSequenceRing = 1u << 15;
constant uint kInitialRemap = 1u << 16, kHistory = 1u << 17, kBoxEmitter = 1u << 18, kMaximumSpeed = 1u << 19;
constant uint kSpriteSheet = 1u << 20;

// Control words (`ParticleGPUSystem.Control`).
constant uint cCount = 0, cEmit = 1, cTotal = 2, cSerial = 3, cRemainder = 4, cTrailTotal = 6, cSerialBase = 7;
constant uint cDispatch = 8, cMaterialDraw = 12, cFallbackDraw = 16;

// Draw kinds (`ParticleGPUDrawKind`); 0 (sprite records) and 3 (built-in sprites) need no case.
constant uint kDrawRope = 1, kDrawRopeTrail = 2;
constant uint kFallbackSpriteTrail = 4, kFallbackRope = 5, kFallbackRopeTrail = 6;

constant uint kGroup = 256;

// MARK: - Randomness (`ParticleRandom`)

// Random streams (`ParticleRandom.Stream`), in order.
constant uint sSpawnAngle = 0;
constant uint sSpawnRadius = 1;
constant uint sBoxX = 2;
constant uint sBoxY = 3;
constant uint sOffsetX = 4;
constant uint sOffsetY = 5;
constant uint sSize = 6;
constant uint sAlpha = 7;
constant uint sRed = 8;
constant uint sGreen = 9;
constant uint sBlue = 10;
constant uint sVelocityX = 11;
constant uint sVelocityY = 12;
constant uint sRingSpeedX = 13;
constant uint sRingSpeedY = 14;
constant uint sLifetime = 15;
constant uint sRotation = 16;
constant uint sAngularVelocity = 17;
constant uint sSpriteFrame = 18;

static uint pcg(uint value) {
    const uint state = value * 747796405u + 2891336453u;
    const uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

static float unitRandom(uint seed, uint serial, uint stream) {
    return float(pcg(seed + pcg(serial + pcg(stream))) >> 8) * (1.0f / 16777216.0f);
}

static float randomValue(float a, float b, uint seed, uint serial, uint stream) {
    return a + (b - a) * unitRandom(seed, serial, stream);
}

// MARK: - Helpers

static float saturateValue(float value) { return min(max(value, 0.0f), 1.0f); }

static float lifeProgress(float life, float4 change) {
    return saturateValue((life - change.x) / max(change.y - change.x, 0.001f));
}

/// `ParticleSystemRuntime.opacity`: alpha with the fades and the material's multiplier.
static float particleOpacity(ParticleState particle, constant ParticleParameters &p, constant ParticleFrame &f) {
    const float progress = particle.life.x / particle.life.y;
    const float fadeIn = f.fade.x > 0 ? min(progress / f.fade.x, 1.0f) : 1.0f;
    const float fadeOut = f.fade.y < 1 ? min((1 - progress) / (1 - f.fade.y), 1.0f) : 1.0f;
    return particle.alphaRotation.x * fadeIn * fadeOut * p.sprite.z;
}

static float4 recordColor(ParticleState particle, constant ParticleParameters &p, constant ParticleFrame &f) {
    return float4(particle.color.xyz, particle.color.w * particleOpacity(particle, p, f));
}

/// `ParticleRecordWriter.spritePhase`.
static float spritePhase(ParticleState particle, constant ParticleParameters &p) {
    const int frames = int(p.spriteSheet.x);
    if ((p.counts.y & kSpriteSheet) == 0 || frames <= 0) return 0;
    float phase;
    if (p.sprite.x == 2) {
        phase = (float(int(particle.identity.y) % frames) + 0.001f) / float(frames);
    } else if (p.sprite.x == 1) {
        phase = min(particle.life.x / max(particle.life.y, 0.0001f) * p.sprite.y, 0.9999f);
    } else {
        const float cycle = particle.life.x * p.sprite.y / max(p.spriteSheet.w, 0.001f);
        phase = cycle - floor(cycle);
    }
    return isfinite(phase) ? phase : 0;
}

/// The built-in draw's sprite-sheet cell: origin xy, size zw.
static float4 spriteSheetCell(ParticleState particle, constant ParticleParameters &p) {
    const int frames = int(p.spriteSheet.x);
    if ((p.counts.y & kSpriteSheet) == 0 || frames <= 0) return float4(0, 0, 1, 1);
    int frame;
    if (p.sprite.x == 2) {
        frame = int(particle.identity.y) % frames;
    } else if (p.sprite.x == 1) {
        frame = min(int((particle.life.x / particle.life.y) * float(frames) * p.sprite.y), frames - 1);
    } else {
        const float duration = max(p.spriteSheet.w, 0.001f);
        frame = int(particle.life.x * p.sprite.y / duration * float(frames)) % frames;
    }
    const int columns = int(p.spriteSheet.y);
    const float2 size = float2(1 / p.spriteSheet.y, 1 / p.spriteSheet.z);
    return float4(float(frame % columns) * size.x, float(frame / columns) * size.y, size);
}

/// `SceneMetalRenderer.layerUniform` with `.stretch`: scene units onto the target's pixels.
static FallbackInstance fallbackInstance(float2 position, float2 size, float opacity, constant ParticleFrame &f) {
    const float2 scale = f.scene.zw / f.scene.xy;
    FallbackInstance instance;
    instance.position = position * scale;
    instance.size = size * scale;
    instance.sceneSize = f.scene.zw;
    instance.opacity = opacity;
    instance.particleShape = 0;
    instance.rotation = 0;
    instance.color = float4(1);
    instance.uvOrigin = float2(0);
    instance.uvAxisX = float2(1, 0);
    instance.uvAxisY = float2(0, 1);
    instance.effects = float4(1, 1, 1, 0);
    instance.blur = 0;
    instance.colorEffects = float4(0, 1, 0, 0.7);
    instance.transform = float4(0, 0, 0, 1);
    instance.transformScaleY = 1;
    instance.bloomTint = float4(1);
    instance.quadAxisX = float2(0);
    instance.quadAxisY = float2(0);
    return instance;
}

static float2 catmullRom(float2 previous, float2 start, float2 end, float2 following, float t) {
    const float t2 = t * t;
    const float t3 = t2 * t;
    return 0.5f * (2 * start + (end - previous) * t + (2 * previous - 5 * start + 4 * end - following) * t2
                   + (3 * start - previous - 3 * end + following) * t3);
}

/// Exclusive prefix sum over a 256-thread group; every thread must call it.
static uint groupExclusiveScan(uint value, uint lid, uint lane, uint simdIndex, uint simdCount,
                               threadgroup uint *totals) {
    const uint prefix = simd_prefix_exclusive_sum(value);
    const uint total = simd_sum(value);
    if (lane == 0) totals[simdIndex] = total;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (lid == 0) {
        uint running = 0;
        for (uint s = 0; s < simdCount; ++s) {
            const uint t = totals[s];
            totals[s] = running;
            running += t;
        }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    const uint result = prefix + totals[simdIndex];
    threadgroup_barrier(mem_flags::mem_threadgroup);
    return result;
}

// MARK: - Step

/// Emission count and the frame's dispatch size (`ParticleCPUSimulation.emissionCount`).
kernel void particleBegin(device uint *control [[buffer(0)]],
                          constant ParticleParameters &p [[buffer(1)]],
                          constant ParticleFrame &f [[buffer(2)]]) {
    uint count = control[cCount];
    device float *remainder = (device float *)(control + cRemainder);
    uint emitted = 0;
    if (f.fade.z > 0.5) {
        count = 0;
        *remainder = 0;
    } else {
        float carry = *remainder + max(f.time.z, 0.0f) * f.time.x;
        const int maximum = int(p.counts.x);
        // Clamped before the conversion, which is undefined past int's range; the maximum caps it anyway.
        const int taken = max(0, min(int(min(carry, 2147483520.0f)), maximum - int(count)));
        carry -= float(taken);
        if (int(count) + taken >= maximum) carry = fmod(carry, 1.0f);
        *remainder = carry;
        emitted = uint(taken);
    }
    const uint total = count + emitted;
    control[cCount] = count;
    control[cEmit] = emitted;
    control[cTotal] = total;
    control[cSerialBase] = control[cSerial];
    control[cSerial] = control[cSerial] + emitted;
    control[cDispatch] = max((total + kGroup - 1) / kGroup, 1u);
    control[cDispatch + 1] = 1;
    control[cDispatch + 2] = 1;
}

/// `ParticleCPUSimulation.spawn`.
static ParticleState spawn(uint serial, constant ParticleParameters &p, constant ParticleFrame &f) {
    const uint seed = p.counts.z;
    const uint flags = p.counts.y;
    const float angle = randomValue(0, 2 * M_PI_F, seed, serial, sSpawnAngle);
    const float radius = sqrt(randomValue(0, 1, seed, serial, sSpawnRadius));
    const float2 extent = p.angularSpawn.zw;
    float2 spawnOffset;
    if (flags & kBoxEmitter) {
        const float2 box = abs(extent);
        spawnOffset = float2(randomValue(-box.x, box.x, seed, serial, sBoxX), randomValue(-box.y, box.y, seed, serial, sBoxY));
    } else {
        spawnOffset = float2(cos(angle) * extent.x, sin(angle) * extent.y) * radius;
    }
    const float2 authoredOffset = float2(randomValue(p.offsetRange.x, p.offsetRange.z, seed, serial, sOffsetX),
                                         randomValue(p.offsetRange.y, p.offsetRange.w, seed, serial, sOffsetY));
    float size = randomValue(p.lifetimeSize.z, p.lifetimeSize.w, seed, serial, sSize);
    float alpha = randomValue(p.alphaRotation.x, p.alphaRotation.y, seed, serial, sAlpha);
    const float4 color = float4(randomValue(p.colorMinimum.x, p.colorMaximum.x, seed, serial, sRed),
                                randomValue(p.colorMinimum.y, p.colorMaximum.y, seed, serial, sGreen),
                                randomValue(p.colorMinimum.z, p.colorMaximum.z, seed, serial, sBlue), 1);
    float2 position = f.points.xy + spawnOffset + authoredOffset;
    float2 velocity = float2(randomValue(p.velocityRange.x, p.velocityRange.z, seed, serial, sVelocityX),
                             randomValue(p.velocityRange.y, p.velocityRange.w, seed, serial, sVelocityY));
    velocity = float2x2(p.velocityRotation.xy, p.velocityRotation.zw) * velocity;
    float sequence = 0;
    if ((flags & kSequenceSpan) && f.anchor.z > 0.5) {
        const uint spanCount = uint(p.sequence.x);
        const uint slot = serial % spanCount;
        const uint lap = serial / spanCount;
        sequence = p.sequence.z > 0.5 && lap % 2 == 1
            ? 1 - float(slot) / float(spanCount - 1)
            : float(slot) / float(spanCount - 1);
        const float2 start = f.sequence.xy, end = f.sequence.zw;
        const float2 axis = end - start;
        const float2 normal = float2(-axis.y, axis.x);
        const float2 arc = normal * p.sequence.y * sin(sequence * M_PI_F) * 0.5f;
        float2 offset = spawnOffset;
        if (flags & kSequenceRing) {
            const float ringRadius = length(spawnOffset);
            const float bounded = p.ringAxisBounds.z + sequence * (p.ringAxisBounds.w - p.ringAxisBounds.z);
            const float ringAngle = bounded * p.sequence.w * 2 * M_PI_F;
            const float2 authoredAxis = p.ringAxisBounds.xy;
            const float2 ringAxis = length(authoredAxis) > 0.0001f ? normalize(authoredAxis)
                : (length(axis) > 0.0001f ? normalize(axis) : float2(0, 1));
            offset = float2(-ringAxis.y, ringAxis.x) * cos(ringAngle) * ringRadius;
            velocity += float2(randomValue(p.ringSpeed.x, p.ringSpeed.z, seed, serial, sRingSpeedX),
                               randomValue(p.ringSpeed.y, p.ringSpeed.w, seed, serial, sRingSpeedY));
        }
        position = start + axis * sequence + arc + offset + authoredOffset;
    }
    if (flags & kInitialRemap) {
        const float range = max(p.initialRemap.y - p.initialRemap.x, 0.001f);
        const float factor = saturateValue((length(position - f.anchor.xy) - p.initialRemap.x) / range);
        const bool multiply = p.initialRemap.z > 0.5;
        if (p.initialRemap.w == 0) size = multiply ? size * factor : factor;
        else if (p.initialRemap.w == 1) alpha = multiply ? alpha * factor : factor;
        else if (multiply) velocity = velocity * factor;
    }
    const uint frames = max(uint(p.spriteSheet.x), 1u);
    ParticleState particle;
    particle.positionVelocity = float4(position, velocity);
    particle.life = float4(0, randomValue(p.lifetimeSize.x, p.lifetimeSize.y, seed, serial, sLifetime), size, size);
    particle.alphaRotation = float4(alpha, alpha, randomValue(p.alphaRotation.z, p.alphaRotation.w, seed, serial, sRotation),
                                    randomValue(p.angularSpawn.x, p.angularSpawn.y, seed, serial, sAngularVelocity));
    particle.color = color;
    particle.baseColor = color;
    particle.trail = float4(0, sequence, 0, 0);
    particle.identity = uint4(serial, min(uint(unitRandom(seed, serial, sSpriteFrame) * float(frames)), frames - 1), 0, 0);
    return particle;
}

kernel void particleEmit(device ParticleState *particles [[buffer(0)]],
                         device const uint *control [[buffer(1)]],
                         constant ParticleParameters &p [[buffer(2)]],
                         constant ParticleFrame &f [[buffer(3)]],
                         uint gid [[thread_position_in_grid]]) {
    if (gid >= control[cEmit]) return;
    particles[control[cCount] + gid] = spawn(control[cSerialBase] + gid, p, f);
}

/// `ParticleCPUSimulation.advance`: every operator, then the death test. Reads `particles`
/// (boids read neighbours from there too), writes `stepped`.
kernel void particleSimulate(device const ParticleState *particles [[buffer(0)]],
                             device ParticleState *stepped [[buffer(1)]],
                             device uint *alive [[buffer(2)]],
                             device float2 *history [[buffer(3)]],
                             device const uint *control [[buffer(4)]],
                             constant ParticleParameters &p [[buffer(5)]],
                             constant ParticleFrame &f [[buffer(6)]],
                             uint gid [[thread_position_in_grid]]) {
    const uint total = control[cTotal];
    if (gid >= total) return;
    const uint flags = p.counts.y;
    const float deltaTime = f.time.x;
    ParticleState particle = particles[gid];
    float2 position = particle.positionVelocity.xy;
    float2 velocity = particle.positionVelocity.zw;
    position += velocity * deltaTime;
    if (flags & kTurbulence) {
        const float2 scaled = position * p.turbulence.x;
        const float phase = f.time.y * p.turbulence.w + p.turbulenceMask.x;
        const float2 direction = float2(sin(scaled.y + phase), cos(scaled.x - phase));
        const float magnitude = randomValue(p.turbulence.y, p.turbulence.z, p.counts.z, particle.identity.x,
                                            0x80000000u | (f.indices.x & 0x7FFFFFFFu));
        velocity += direction * magnitude * p.turbulenceMask.yz * deltaTime;
    }
    if (flags & kAttractor) {
        const float2 offset = f.points.zw - position;
        const float distance = max(length(offset), 0.001f);
        if (distance < p.attractor.y) velocity += offset / distance * p.attractor.x * deltaTime;
    }
    if (flags & kVortex) {
        const float2 offset = position - p.vortex.xy;
        const float distance = length(offset);
        const float inner = p.vortexDistance.x, outer = p.vortexDistance.y;
        if (distance > 0.001f && distance >= inner && distance <= max(outer, inner)) {
            const float progress = saturateValue((distance - inner) / max(outer - inner, 0.001f));
            const float speed = p.vortex.z + (p.vortex.w - p.vortex.z) * progress;
            velocity += float2(-offset.y, offset.x) / distance * speed * deltaTime;
        }
    }
    if ((flags & kBoids) && p.boids.w > 0) {
        const uint neighborStride = max(1u, total / 256u);
        float neighborCount = 0;
        float2 averageVelocity = float2(0), averagePosition = float2(0), separation = float2(0);
        for (uint neighbor = 0; neighbor < total; neighbor += neighborStride) {
            if (neighbor == gid) continue;
            const float4 other = particles[neighbor].positionVelocity;
            const float2 offset = other.xy - position;
            const float distance = length(offset);
            if (!(distance > 0.001f && distance < p.boids.w)) continue;
            neighborCount += 1;
            averageVelocity += other.zw;
            averagePosition += other.xy;
            separation -= offset / distance;
        }
        if (neighborCount > 0) {
            averageVelocity /= neighborCount;
            averagePosition /= neighborCount;
            velocity += ((averageVelocity - velocity) * p.boids.x + (averagePosition - position) * p.boids.y
                         + separation * p.boids.z) * deltaTime;
        }
    }
    if (flags & kReduction) {
        const float distance = length(position - p.reduction.xy);
        if (distance < p.reduction.w) {
            const float progress = saturateValue((distance - p.reduction.z) / max(p.reduction.w - p.reduction.z, 0.001f));
            velocity *= max(1 - p.constraint.x * (1 - progress) * deltaTime, 0.0f);
        }
    }
    if (flags & kConstraint) {
        velocity += (p.constraint.yz - position) * p.constraint.w * deltaTime;
    }
    if ((flags & kMaintainSequence) && f.anchor.z > 0.5) {
        const float2 anchor = f.sequence.xy + (f.sequence.zw - f.sequence.xy) * particle.trail.y;
        velocity += (anchor - position) * 10 * deltaTime;
    }
    velocity += p.gravity.xy * deltaTime;
    velocity *= max(0.0f, 1 - f.time.w * deltaTime);
    if ((flags & kMaximumSpeed) && p.gravity.z > 0) {
        const float speed = length(velocity);
        if (speed > p.gravity.z) velocity *= p.gravity.z / speed;
    }
    particle.life.x += deltaTime;
    const float life = saturateValue(particle.life.x / max(particle.life.y, 0.001f));
    if (flags & kSizeChange) {
        const float t = lifeProgress(life, p.sizeChange);
        particle.life.z = particle.life.w * (p.sizeChange.z + (p.sizeChange.w - p.sizeChange.z) * t);
    }
    if (flags & kAlphaChange) {
        const float t = lifeProgress(life, p.alphaChange);
        particle.alphaRotation.x = particle.alphaRotation.y * (p.alphaChange.z + (p.alphaChange.w - p.alphaChange.z) * t);
    }
    if (flags & kColorChange) {
        const float t = lifeProgress(life, p.colorChangeTime);
        particle.color = mix(p.colorChangeStart, p.colorChangeEnd, float4(t)) * particle.baseColor;
    }
    const float age = particle.life.x;
    if (flags & kOscillateSize) {
        const float wave = sin(age * p.oscillateSize.x + p.oscillateSize.z);
        particle.life.z = particle.life.w * (1 + (p.oscillateSize.y - 1) * wave);
    }
    if (flags & kOscillateAlpha) {
        const float wave = sin(age * p.oscillateAlpha.x + p.oscillateAlpha.z);
        particle.alphaRotation.x = max(0.0f, particle.alphaRotation.y * (1 + (p.oscillateAlpha.y - 1) * wave));
    }
    if (flags & kOscillatePosition) {
        const float angle = age * p.oscillatePosition.x + p.oscillatePosition.z;
        const float scale = p.oscillatePosition.y;
        position += float2(sin(angle) * scale * deltaTime, cos(angle) * scale * deltaTime);
    }
    if (flags & kRemapAlpha) {
        float value = age * p.remapAlpha.x;
        if (p.remapAlpha.w > 0.5) value = sin(value) * 0.5f + 0.5f;
        const float mapped = p.remapAlpha.y + (p.remapAlpha.z - p.remapAlpha.y) * saturateValue(value);
        particle.alphaRotation.x = particle.alphaRotation.y * mapped;
    }
    particle.alphaRotation.w += p.gravity.w * deltaTime;
    particle.alphaRotation.z += particle.alphaRotation.w * deltaTime;
    if (flags & kHistory) {
        const uint limit = p.counts.w;
        particle.trail.x += deltaTime;
        if (particle.trail.x >= p.trail.x || particle.identity.z == 0) {
            particle.trail.x = 0;
            device float2 *own = history + gid * limit;
            if (particle.identity.z < limit) {
                own[particle.identity.z] = position;
                particle.identity.z += 1;
            } else {
                own[particle.identity.w] = position;
                particle.identity.w = (particle.identity.w + 1) % limit;
            }
        }
    }
    particle.positionVelocity = float4(position, velocity);
    stepped[gid] = particle;
    alive[gid] = particle.life.x >= particle.life.y ? 0 : 1;
}

// MARK: - Compaction

/// Per-group exclusive prefix sums of `values` (`control[countIndex]` of them) and each group's total.
kernel void particleScanBlocks(device const uint *values [[buffer(0)]],
                               device uint *offsets [[buffer(1)]],
                               device uint *blockSums [[buffer(2)]],
                               device const uint *control [[buffer(3)]],
                               constant uint &countIndex [[buffer(4)]],
                               uint gid [[thread_position_in_grid]],
                               uint lid [[thread_index_in_threadgroup]],
                               uint group [[threadgroup_position_in_grid]],
                               uint lane [[thread_index_in_simdgroup]],
                               uint simdIndex [[simdgroup_index_in_threadgroup]],
                               uint simdCount [[simdgroups_per_threadgroup]]) {
    threadgroup uint totals[64];
    const uint count = control[countIndex];
    const uint value = gid < count ? values[gid] : 0;
    const uint prefix = groupExclusiveScan(value, lid, lane, simdIndex, simdCount, totals);
    if (gid < count) offsets[gid] = prefix;
    if (lid == kGroup - 1) blockSums[group] = prefix + value;
}

/// Turns the group totals into group offsets (one threadgroup) and stores the grand total in
/// `control[indices.y]`.
kernel void particleScanBlockSums(device uint *blockSums [[buffer(0)]],
                                  device uint *control [[buffer(1)]],
                                  constant uint2 &indices [[buffer(2)]],
                                  uint lid [[thread_index_in_threadgroup]],
                                  uint lane [[thread_index_in_simdgroup]],
                                  uint simdIndex [[simdgroup_index_in_threadgroup]],
                                  uint simdCount [[simdgroups_per_threadgroup]]) {
    threadgroup uint totals[64];
    threadgroup uint carry;
    const uint blocks = (control[indices.x] + kGroup - 1) / kGroup;
    if (lid == 0) carry = 0;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint base = 0; base < blocks; base += kGroup) {
        const uint index = base + lid;
        const uint value = index < blocks ? blockSums[index] : 0;
        const uint prefix = groupExclusiveScan(value, lid, lane, simdIndex, simdCount, totals);
        const uint running = carry;
        if (index < blocks) blockSums[index] = running + prefix;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        if (lid == kGroup - 1) carry = running + prefix + value;
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (lid == 0) control[indices.y] = carry;
}

/// Moves the survivors back to `particles`, in order, with their trail history.
kernel void particleCompact(device const ParticleState *stepped [[buffer(0)]],
                            device ParticleState *particles [[buffer(1)]],
                            device const uint *alive [[buffer(2)]],
                            device const uint *offsets [[buffer(3)]],
                            device const uint *blockSums [[buffer(4)]],
                            device const float2 *history [[buffer(5)]],
                            device float2 *nextHistory [[buffer(6)]],
                            device uint *trailCounts [[buffer(7)]],
                            device const uint *control [[buffer(8)]],
                            constant ParticleParameters &p [[buffer(9)]],
                            uint gid [[thread_position_in_grid]]) {
    if (gid >= control[cTotal] || alive[gid] == 0) return;
    const uint destination = offsets[gid] + blockSums[gid / kGroup];
    const ParticleState particle = stepped[gid];
    particles[destination] = particle;
    if (p.counts.y & kHistory) {
        const uint limit = p.counts.w;
        for (uint sample = 0; sample < particle.identity.z; ++sample) {
            nextHistory[destination * limit + sample] = history[gid * limit + sample];
        }
        trailCounts[destination] = particle.identity.z;
    }
}

// MARK: - Draw

/// Record counts and indirect draw arguments; patches a rope's `g_RenderVar0` point count.
kernel void particleFinish(device uint *control [[buffer(0)]],
                           device float *uniforms [[buffer(1)]],
                           constant ParticleParameters &p [[buffer(2)]],
                           constant ParticleFrame &f [[buffer(3)]]) {
    const uint count = control[cCount];
    const uint segments = count > 0 ? count - 1 : 0;
    const uint subdivision = uint(p.trail.z);
    uint material = count, fallback = count;
    switch (f.indices.w) {
    case kDrawRope: material = segments; break;
    case kDrawRopeTrail: material = control[cTrailTotal]; break;
    case kFallbackRope: fallback = segments * subdivision; break;
    case kFallbackRopeTrail: fallback = control[cTrailTotal] * subdivision; break;
    default: break;
    }
    control[cMaterialDraw] = f.indices.y;
    control[cMaterialDraw + 1] = material;
    control[cMaterialDraw + 2] = 0;
    control[cMaterialDraw + 3] = 0;
    control[cFallbackDraw] = 4;
    control[cFallbackDraw + 1] = fallback;
    control[cFallbackDraw + 2] = 0;
    control[cFallbackDraw + 3] = 0;
    if (f.indices.z != 0xFFFFFFFFu) {
        const float points = float(count);
        device float *renderVar = uniforms + f.indices.z;
        renderVar[0] = points;
        renderVar[1] = 0;
        renderVar[2] = 1;
        renderVar[3] = points;
    }
}

/// `ParticleRecordWriter.writeSprites`.
kernel void particleWriteSprites(device const ParticleState *particles [[buffer(0)]],
                                 device SpriteRecord *records [[buffer(1)]],
                                 device const uint *control [[buffer(2)]],
                                 constant ParticleParameters &p [[buffer(3)]],
                                 constant ParticleFrame &f [[buffer(4)]],
                                 uint gid [[thread_position_in_grid]]) {
    if (gid >= control[cCount]) return;
    const ParticleState particle = particles[gid];
    SpriteRecord record;
    record.position = float4(particle.positionVelocity.xy, 0, 0);
    record.rotationSize = float4(0, 0, particle.alphaRotation.z, particle.life.z / 2);
    record.velocityLifetime = float4(particle.positionVelocity.zw, 0, spritePhase(particle, p));
    record.color = recordColor(particle, p, f);
    records[gid] = record;
}

/// `ParticleRecordWriter.writeRope`: one strand through the system, oldest particle first.
kernel void particleWriteRope(device const ParticleState *particles [[buffer(0)]],
                              device RopeRecord *records [[buffer(1)]],
                              device const uint *control [[buffer(2)]],
                              constant ParticleParameters &p [[buffer(3)]],
                              constant ParticleFrame &f [[buffer(4)]],
                              uint gid [[thread_position_in_grid]]) {
    const uint count = control[cCount];
    if (gid + 1 >= count) return;
    const ParticleState start = particles[gid];
    const ParticleState end = particles[gid + 1];
    const float2 previous = particles[gid > 0 ? gid - 1 : 0].positionVelocity.xy;
    const float2 next = particles[min(gid + 2, count - 1)].positionVelocity.xy;
    RopeRecord record;
    record.start = float4(start.positionVelocity.xy, 0, start.life.z / 2);
    record.end = float4(end.positionVelocity.xy, 0, float(count));
    record.previous = float4(previous, 0, float(gid));
    record.next = float4(next, 0, end.life.z / 2);
    record.endColor = recordColor(end, p, f);
    record.color = recordColor(start, p, f);
    records[gid] = record;
}

/// A point of a `ropetrail` particle's trail, newest first: the particle, then its history.
static float2 trailPointNewestFirst(ParticleState particle, device const float2 *own, uint index) {
    if (index == 0) return particle.positionVelocity.xy;
    const int count = int(particle.identity.z);
    const int newest = (int(particle.identity.w) - 1 + count) % count;
    return own[(newest - (int(index) - 1) + count * 2) % count];
}

/// `ParticleRecordWriter.writeRopeTrails`.
kernel void particleWriteRopeTrails(device const ParticleState *particles [[buffer(0)]],
                                    device RopeRecord *records [[buffer(1)]],
                                    device const float2 *history [[buffer(2)]],
                                    device const uint *offsets [[buffer(3)]],
                                    device const uint *blockSums [[buffer(4)]],
                                    device const uint *control [[buffer(5)]],
                                    constant ParticleParameters &p [[buffer(6)]],
                                    constant ParticleFrame &f [[buffer(7)]],
                                    uint gid [[thread_position_in_grid]]) {
    if (gid >= control[cCount]) return;
    const ParticleState particle = particles[gid];
    const uint count = particle.identity.z;
    if (count == 0) return;
    device const float2 *own = history + gid * p.counts.w;
    const uint base = offsets[gid] + blockSums[gid / kGroup];
    const uint points = count + 1;
    const float4 rgba = recordColor(particle, p, f);
    const float size = particle.life.z / 2;
    for (uint segment = 0; segment < points - 1; ++segment) {
        const float2 start = trailPointNewestFirst(particle, own, segment);
        const float2 end = trailPointNewestFirst(particle, own, segment + 1);
        const float2 previous = trailPointNewestFirst(particle, own, segment > 0 ? segment - 1 : 0);
        const float2 next = trailPointNewestFirst(particle, own, min(segment + 2, points - 1));
        RopeRecord record;
        record.start = float4(start, 0, size);
        record.end = float4(end, 0, float(points));
        record.previous = float4(previous, 0, float(segment));
        record.next = float4(next, 0, size);
        record.endColor = rgba;
        record.color = rgba;
        records[base + segment] = record;
    }
}

// MARK: - Built-in draw

/// `sprite` and `*trail` sprites through the renderer's own quad.
kernel void particleWriteFallbackSprites(device const ParticleState *particles [[buffer(0)]],
                                         device FallbackInstance *instances [[buffer(1)]],
                                         device const uint *control [[buffer(2)]],
                                         constant ParticleParameters &p [[buffer(3)]],
                                         constant ParticleFrame &f [[buffer(4)]],
                                         uint gid [[thread_position_in_grid]]) {
    if (gid >= control[cCount]) return;
    const ParticleState particle = particles[gid];
    const float size = particle.life.z;
    const float opacity = particleOpacity(particle, p, f);
    FallbackInstance instance;
    if (f.indices.w == kFallbackSpriteTrail) {
        const float2 velocity = particle.positionVelocity.zw;
        const float speed = length(velocity);
        const float stretch = max(p.trail.y, 1.0f);
        const float trailLength = max(size, min(size * stretch, size + speed * 0.08f));
        const float width = p.sprite.w > 0.5 ? max(2.0f, size * 0.08f) : size;
        instance = fallbackInstance(particle.positionVelocity.xy, float2(width, trailLength), opacity, f);
        instance.rotation = speed > 0.01f ? atan2(velocity.y, velocity.x) - M_PI_F / 2 : particle.alphaRotation.z;
    } else {
        instance = fallbackInstance(particle.positionVelocity.xy, float2(size), opacity, f);
        instance.particleShape = 1;
        instance.rotation = particle.alphaRotation.z;
    }
    instance.color = particle.color;
    const float4 cell = spriteSheetCell(particle, p);
    instance.uvOrigin = cell.xy;
    instance.uvAxisX = float2(cell.z, 0);
    instance.uvAxisY = float2(0, cell.w);
    instances[gid] = instance;
}

/// A quad the built-in draw skips (shorter than 0.01): nothing drawn.
static FallbackInstance emptyInstance(constant ParticleFrame &f) {
    return fallbackInstance(float2(0), float2(0), 0, f);
}

/// `rope` through the built-in quad: `subdivision` Catmull-Rom pieces per segment.
kernel void particleWriteFallbackRope(device const ParticleState *particles [[buffer(0)]],
                                      device FallbackInstance *instances [[buffer(1)]],
                                      device const uint *control [[buffer(2)]],
                                      constant ParticleParameters &p [[buffer(3)]],
                                      constant ParticleFrame &f [[buffer(4)]],
                                      uint gid [[thread_position_in_grid]]) {
    const uint count = control[cCount];
    if (gid + 1 >= count) return;
    const uint subdivision = uint(p.trail.z);
    const ParticleState previous = particles[gid > 0 ? gid - 1 : gid];
    const ParticleState start = particles[gid];
    const ParticleState end = particles[gid + 1];
    const ParticleState following = particles[gid + 2 < count ? gid + 2 : gid + 1];
    const float startOpacity = particleOpacity(start, p, f), endOpacity = particleOpacity(end, p, f);
    for (uint step = 0; step < subdivision; ++step) {
        const float t0 = float(step) / float(subdivision);
        const float t1 = float(step + 1) / float(subdivision);
        // The piece's far end is the next spline point; the segment's last one is `end` itself.
        const float2 from = catmullRom(previous.positionVelocity.xy, start.positionVelocity.xy,
                                       end.positionVelocity.xy, following.positionVelocity.xy, t0);
        const bool last = step + 1 == subdivision;
        const float2 to = last ? end.positionVelocity.xy
            : catmullRom(previous.positionVelocity.xy, start.positionVelocity.xy,
                         end.positionVelocity.xy, following.positionVelocity.xy, t1);
        const float fromSize = start.life.z + (end.life.z - start.life.z) * t0;
        const float toSize = last ? end.life.z : start.life.z + (end.life.z - start.life.z) * t1;
        const float4 fromColor = mix(start.color, end.color, float4(t0));
        const float4 toColor = last ? end.color : mix(start.color, end.color, float4(t1));
        const float fromOpacity = startOpacity + (endOpacity - startOpacity) * t0;
        const float toOpacity = last ? endOpacity : startOpacity + (endOpacity - startOpacity) * t1;
        const float2 delta = to - from;
        const float pieceLength = length(delta);
        FallbackInstance instance = emptyInstance(f);
        if (pieceLength > 0.01f) {
            instance = fallbackInstance((from + to) / 2, float2(pieceLength, (fromSize + toSize) / 2),
                                        (fromOpacity + toOpacity) / 2, f);
            instance.rotation = atan2(delta.y, delta.x);
            instance.color = (fromColor + toColor) / 2;
        }
        instances[gid * subdivision + step] = instance;
    }
}

/// A point of a `ropetrail` particle's trail, oldest first: its history, then the particle.
static float2 trailPointOldestFirst(ParticleState particle, device const float2 *own, uint index) {
    const uint count = particle.identity.z;
    if (index >= count) return particle.positionVelocity.xy;
    return own[(particle.identity.w + index) % count];
}

/// `ropetrail` through the built-in quad: one Catmull-Rom strand per particle.
kernel void particleWriteFallbackRopeTrails(device const ParticleState *particles [[buffer(0)]],
                                            device FallbackInstance *instances [[buffer(1)]],
                                            device const float2 *history [[buffer(2)]],
                                            device const uint *offsets [[buffer(3)]],
                                            device const uint *blockSums [[buffer(4)]],
                                            device const uint *control [[buffer(5)]],
                                            constant ParticleParameters &p [[buffer(6)]],
                                            constant ParticleFrame &f [[buffer(7)]],
                                            uint gid [[thread_position_in_grid]]) {
    if (gid >= control[cCount]) return;
    const ParticleState particle = particles[gid];
    const uint count = particle.identity.z;
    if (count == 0) return;
    device const float2 *own = history + gid * p.counts.w;
    const uint subdivision = uint(p.trail.z);
    const uint base = (offsets[gid] + blockSums[gid / kGroup]) * subdivision;
    const uint points = count + 1;
    const uint pieces = (points - 1) * subdivision;
    const float opacity = particleOpacity(particle, p, f);
    const float4 cell = spriteSheetCell(particle, p);
    const bool fadeAlpha = (uint(p.trail.w) & 1u) != 0, fadeSize = (uint(p.trail.w) & 2u) != 0;
    for (uint segment = 0; segment < points - 1; ++segment) {
        const float2 previous = trailPointOldestFirst(particle, own, segment > 0 ? segment - 1 : segment);
        const float2 start = trailPointOldestFirst(particle, own, segment);
        const float2 end = trailPointOldestFirst(particle, own, segment + 1);
        const float2 following = trailPointOldestFirst(particle, own, segment + 2 < points ? segment + 2 : segment + 1);
        for (uint step = 0; step < subdivision; ++step) {
            const uint piece = segment * subdivision + step;
            const float2 from = catmullRom(previous, start, end, following, float(step) / float(subdivision));
            const bool last = step + 1 == subdivision;
            const float2 to = last ? end : catmullRom(previous, start, end, following, float(step + 1) / float(subdivision));
            const float2 delta = to - from;
            const float pieceLength = length(delta);
            FallbackInstance instance = emptyInstance(f);
            if (pieceLength > 0.01f) {
                // 0 at the oldest sample, 1 at the particle itself.
                const float progress = float(piece + 1) / float(pieces);
                const float width = fadeSize ? particle.life.z * progress : particle.life.z;
                instance = fallbackInstance((from + to) / 2, float2(pieceLength, max(width, 0.01f)),
                                            fadeAlpha ? opacity * progress : opacity, f);
                instance.rotation = atan2(delta.y, delta.x);
                instance.color = particle.color;
                instance.uvOrigin = cell.xy;
                instance.uvAxisX = float2(cell.z, 0);
                instance.uvAxisY = float2(0, cell.w);
            }
            instances[base + piece] = instance;
        }
    }
}

/// The sizes of the structures above, for the layout test.
kernel void particleLayoutSizes(device uint *sizes [[buffer(0)]]) {
    sizes[0] = sizeof(ParticleState);
    sizes[1] = sizeof(ParticleParameters);
    sizes[2] = sizeof(ParticleFrame);
    sizes[3] = sizeof(SpriteRecord);
    sizes[4] = sizeof(RopeRecord);
    sizes[5] = sizeof(FallbackInstance);
}
