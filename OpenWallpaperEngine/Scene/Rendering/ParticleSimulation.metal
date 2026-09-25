#include "ParticleShared.h"

// The particle simulation on the GPU. It is `ParticleCPUSimulation` step for step: the same
// emission arithmetic, initializers, operator order and random draws (`ParticleRandom`), so the
// two stay interchangeable (`ParticleSimulationParityTests`). Structures mirror
// `ParticleGPUTypes.swift`; `particleLayoutSizes` lets a test check the two agree.
//
// One frame of one system, all in one compute encoder (`ParticleGPUSimulator`):
//   begin → emit → simulate → scan → compact → [trail scan] → finish → write records.
// Particles stay in spawn order: the compaction is an order-preserving prefix sum, so rope
// neighbours and boids' neighbour sampling match the CPU's array.

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
        const int maximum = int(f.extra.y);
        const int available = max(maximum - int(count), 0);
        const int burst = min(int(f.fade.w), available);
        // Clamped before the conversion, which is undefined past int's range; the maximum caps it anyway.
        const int taken = max(0, min(int(min(carry, 2147483520.0f)), available - burst));
        carry -= float(taken);
        if (int(count) + burst + taken >= maximum) carry = fmod(carry, 1.0f);
        *remainder = carry;
        emitted = uint(burst + taken);
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
static ParticleState spawn(uint serial, constant ParticleParameters &p, constant ParticleFrame &f, FramePoints points) {
    const uint seed = p.counts.z;
    const uint flags = p.counts.y;
    const float angle = randomValue(0, 2 * M_PI_F, seed, serial, sSpawnAngle);
    const float inner = p.emitterRing.x;
    const float radius = inner + (1 - inner) * sqrt(randomValue(0, 1, seed, serial, sSpawnRadius));
    const float2 extent = abs(p.angularSpawn.zw * f.gravityExtent.zw);
    float2 spawnOffset;
    if (flags & kBoxEmitter) {
        spawnOffset = float2(randomValue(-extent.x, extent.x, seed, serial, sBoxX),
                             randomValue(-extent.y, extent.y, seed, serial, sBoxY));
    } else {
        spawnOffset = float2(cos(angle) * extent.x, sin(angle) * extent.y) * radius;
        if (p.emitterShape.z != 0) spawnOffset.x = abs(spawnOffset.x) * (p.emitterShape.z > 0 ? 1 : -1);
        if (p.emitterShape.w != 0) spawnOffset.y = abs(spawnOffset.y) * (p.emitterShape.w > 0 ? 1 : -1);
    }
    const float2x2 offsetLinear = float2x2(f.offsetLinear.xy, f.offsetLinear.zw);
    const float2 offsetMinimum = offsetLinear * p.offsetRange.xy, offsetMaximum = offsetLinear * p.offsetRange.zw;
    const float2 authoredOffset = float2(randomValue(offsetMinimum.x, offsetMaximum.x, seed, serial, sOffsetX),
                                         randomValue(offsetMinimum.y, offsetMaximum.y, seed, serial, sOffsetY));
    // Instance overrides scale the authored ranges (`ParticleFrameInputs.spawnScale`).
    const float4 scale = f.spawnScale;
    float size = randomValue(p.lifetimeSize.z * scale.x, p.lifetimeSize.w * scale.x, seed, serial, sSize);
    float alpha = randomValue(p.alphaRotation.x * scale.y, p.alphaRotation.y * scale.y, seed, serial, sAlpha);
    const float4 colorMinimum = p.colorMinimum * float4(f.colorScale.xyz, 1);
    const float4 colorMaximum = p.colorMaximum * float4(f.colorScale.xyz, 1);
    const float4 color = float4(randomValue(colorMinimum.x, colorMaximum.x, seed, serial, sRed),
                                randomValue(colorMinimum.y, colorMaximum.y, seed, serial, sGreen),
                                randomValue(colorMinimum.z, colorMaximum.z, seed, serial, sBlue), 1);
    float2 position = points.spawnOrigin + spawnOffset + authoredOffset;
    const float4 velocityRange = p.velocityRange * scale.w;
    float2 velocity = float2(randomValue(velocityRange.x, velocityRange.z, seed, serial, sVelocityX),
                             randomValue(velocityRange.y, velocityRange.w, seed, serial, sVelocityY));
    velocity = float2x2(f.velocityRotation.xy, f.velocityRotation.zw) * velocity;
    const float2 outward = length(spawnOffset) > 1e-6f ? normalize(spawnOffset) : float2(0);
    velocity += outward * randomValue(p.emitterShape.x, p.emitterShape.y, seed, serial, sEmitterSpeed);
    float sequence = 0;
    if ((flags & kSequenceSpan) && f.anchor.z > 0.5) {
        const uint spanCount = uint(p.sequence.x);
        const uint slot = serial % spanCount;
        const uint lap = serial / spanCount;
        sequence = p.sequence.z > 0.5 && lap % 2 == 1
            ? 1 - float(slot) / float(spanCount - 1)
            : float(slot) / float(spanCount - 1);
        const float2 start = points.sequenceStart, end = points.sequenceEnd;
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
        const float factor = saturateValue((length(position - points.remapAnchor) - p.initialRemap.x) / range);
        const bool multiply = p.initialRemap.z > 0.5;
        if (p.initialRemap.w == 0) size = multiply ? size * factor : factor;
        else if (p.initialRemap.w == 1) alpha = multiply ? alpha * factor : factor;
        else if (multiply) velocity = velocity * factor;
    }
    const uint frames = max(uint(p.spriteSheet.x), 1u);
    ParticleState particle;
    particle.positionVelocity = float4(position, velocity);
    particle.life = float4(0, randomValue(p.lifetimeSize.x * scale.z, p.lifetimeSize.y * scale.z, seed, serial, sLifetime),
                           size, size);
    particle.alphaRotation = float4(alpha, alpha, randomValue(p.alphaRotation.z, p.alphaRotation.w, seed, serial, sRotation),
                                    randomValue(p.angularSpawn.x, p.angularSpawn.y, seed, serial, sAngularVelocity));
    particle.color = color;
    particle.baseColor = color;
    particle.trail = float4(0, sequence, 0, 0);
    particle.identity = uint4(serial, min(uint(unitRandom(seed, serial, sSpriteFrame) * float(frames)), frames - 1), 0, 0);
    return particle;
}

/// `ParticleInheritance.applyOnSpawn`.
static void inheritOnSpawn(thread ParticleState &particle, uint verbs, ParticleInstanceState source) {
    const float3 rgb = source.sourceColor.xyz;
    if (verbs & hSetColor) particle.color.xyz = rgb;
    if (verbs & hMultiplyColor) particle.color.xyz *= rgb;
    particle.baseColor = particle.color;
    if (verbs & hSetOpacity) particle.alphaRotation.x = source.sourceColor.w;
    if (verbs & hMultiplyOpacity) particle.alphaRotation.x *= source.sourceColor.w;
    particle.alphaRotation.y = particle.alphaRotation.x;
    if (verbs & hSetVelocity) particle.positionVelocity.zw = source.source.xy;
    if (verbs & hAddVelocity) particle.positionVelocity.zw += source.source.xy;
    if (verbs & hSetSize) particle.life.z = source.source.z;
    if (verbs & hMultiplySize) particle.life.z *= source.source.z;
    particle.life.w = particle.life.z;
    if (verbs & hSetRotation) particle.alphaRotation.z = source.source.w;
    if (verbs & hAddRotation) particle.alphaRotation.z += source.source.w;
    if (verbs & hSetAngularVelocity) particle.alphaRotation.w = source.emission.x;
    if (verbs & hAddAngularVelocity) particle.alphaRotation.w += source.emission.x;
}

/// `ParticleInheritance.applyEachStep`.
static void inheritEachStep(thread ParticleState &particle, thread float2 &velocity, uint verbs,
                            ParticleInstanceState source) {
    const float3 rgb = source.sourceColor.xyz;
    if (verbs & hSetColor) particle.color.xyz = rgb;
    if (verbs & hMultiplyColor) particle.color.xyz = particle.baseColor.xyz * rgb;
    if (verbs & hSetOpacity) particle.alphaRotation.x = source.sourceColor.w;
    if (verbs & hMultiplyOpacity) particle.alphaRotation.x = particle.alphaRotation.y * source.sourceColor.w;
    if (verbs & hSetVelocity) velocity = source.source.xy;
    if (verbs & hSetSize) particle.life.z = source.source.z;
    if (verbs & hMultiplySize) particle.life.z = particle.life.w * source.source.z;
    if (verbs & hSetRotation) particle.alphaRotation.z = source.source.w;
    if (verbs & hSetAngularVelocity) particle.alphaRotation.w = source.emission.x;
}

/// The instance whose spawns this step include spawn `index` (`ParticleCPUSimulation.step`
/// spawns instance by instance): the last one starting at or before it.
static uint spawningInstance(device const ParticleInstanceState *instances, uint count, uint index) {
    uint low = 0, high = count;
    while (low + 1 < high) {
        const uint middle = (low + high) / 2;
        if (instances[middle].state.w <= index) low = middle; else high = middle;
    }
    return low;
}

kernel void particleEmit(device ParticleState *particles [[buffer(0)]],
                         device const uint *control [[buffer(1)]],
                         constant ParticleParameters &p [[buffer(2)]],
                         constant ParticleFrame &f [[buffer(3)]],
                         device const ParticleInstanceState *instances [[buffer(4)]],
                         uint gid [[thread_position_in_grid]]) {
    if (gid >= control[cEmit]) return;
    const uint serial = control[cSerialBase] + gid;
    if (p.counts.y & kInstanced) {
        const uint instance = spawningInstance(instances, p.instancing.y, gid);
        const ParticleInstanceState source = instances[instance];
        ParticleState particle = spawn(serial, p, f, framePoints(f, source.place.xy));
        particle.trail.z = float(instance);
        inheritOnSpawn(particle, p.inherit.x, source);
        particles[control[cCount] + gid] = particle;
    } else {
        particles[control[cCount] + gid] = spawn(serial, p, f, framePoints(f, float2(0)));
    }
}

/// `ParticleCPUSimulation.follow`: carries a particle along with its emitter's move, `linear`
/// and `translation`.
static void follow(thread ParticleState &particle, device float2 *own, constant ParticleParameters &p,
                   constant ParticleFrame &f, float2x2 linear, float2 translation) {
    particle.positionVelocity = float4(linear * particle.positionVelocity.xy + translation,
                                       linear * particle.positionVelocity.zw);
    particle.life.zw *= f.motionExtras.x;
    particle.alphaRotation.z += f.motionExtras.y;
    if (p.counts.y & kHistory) {
        for (uint sample = 0; sample < particle.identity.z; ++sample) own[sample] = linear * own[sample] + translation;
    }
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
                             device ParticleInstanceState *instances [[buffer(7)]],
                             uint gid [[thread_position_in_grid]]) {
    const uint total = control[cTotal];
    if (gid >= total) return;
    const uint flags = p.counts.y;
    const float deltaTime = f.time.x;
    ParticleState particle = particles[gid];
    const float2x2 motion = float2x2(f.motionLinear.xy, f.motionLinear.zw);
    device float2 *own = history + gid * p.counts.w;
    float2 shift = float2(0);
    bool clearing = false;
    ParticleInstanceState instance = ParticleInstanceState{};
    if (flags & kInstanced) {
        // `ParticleCPUSimulation.followInstance`: the instance's move around its own position.
        instance = instances[uint(particle.trail.z)];
        shift = instance.place.xy;
        clearing = (instance.state.x & iClearing) != 0;
        const bool moved = f.motionExtras.z > 0.5 || any(instance.place.xy != instance.place.zw);
        if (!(flags & kWorldSpace) && moved && gid < control[cCount]) {
            follow(particle, own, p, f, motion, instance.place.xy + f.constraintMotion.zw - motion * instance.place.zw);
        }
    } else if (f.motionExtras.z > 0.5 && gid < control[cCount]) {
        follow(particle, own, p, f, motion, f.constraintMotion.zw);
    }
    const FramePoints points = framePoints(f, shift);
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
        const float2 offset = points.attractor - position;
        const float distance = max(length(offset), 0.001f);
        if (distance < p.attractor.y) velocity += offset / distance * p.attractor.x * deltaTime;
    }
    if (flags & kVortex) {
        const float2 offset = position - points.vortex;
        const float distance = length(offset);
        const float inner = p.vortex.z, outer = p.vortex.w;
        if (distance > 0.001f && distance >= inner && distance <= max(outer, inner)) {
            const float progress = saturateValue((distance - inner) / max(outer - inner, 0.001f));
            const float speed = p.vortex.x + (p.vortex.y - p.vortex.x) * progress;
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
        const float distance = length(position - points.reduction);
        if (distance < p.reduction.y) {
            const float progress = saturateValue((distance - p.reduction.x) / max(p.reduction.y - p.reduction.x, 0.001f));
            velocity *= max(1 - p.reduction.z * (1 - progress) * deltaTime, 0.0f);
        }
    }
    if (flags & kConstraint) {
        velocity += (points.constraint - position) * p.reduction.w * deltaTime;
    }
    if ((flags & kMaintainSequence) && f.anchor.z > 0.5) {
        const float2 anchor = points.sequenceStart + (points.sequenceEnd - points.sequenceStart) * particle.trail.y;
        velocity += (anchor - position) * 10 * deltaTime;
    }
    velocity += f.gravityExtent.xy * deltaTime;
    velocity *= max(0.0f, 1 - f.time.w * deltaTime);
    if ((flags & kMaximumSpeed) && p.limits.x > 0) {
        const float speed = length(velocity);
        if (speed > p.limits.x) velocity *= p.limits.x / speed;
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
    particle.alphaRotation.w += p.limits.y * deltaTime;
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
    if (flags & kInstanced) inheritEachStep(particle, velocity, p.inherit.y, instance);
    particle.positionVelocity = float4(position, velocity);
    if (clearing) particle.life.x = particle.life.y;
    stepped[gid] = particle;
    const bool lives = particle.life.x < particle.life.y;
    alive[gid] = lives ? 1 : 0;
    if ((flags & kInstanced) && lives) {
        // `state.z`: uint 18 of the 24 in an instance.
        device uint *live = (device uint *)(instances + uint(particle.trail.z)) + 18;
        atomic_fetch_add_explicit((device atomic_uint *)live, 1u, memory_order_relaxed);
    }
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
/// `grandTotals[indices.y]`; the value count is `control[indices.x]`.
kernel void particleScanBlockSums(device uint *blockSums [[buffer(0)]],
                                  device const uint *control [[buffer(1)]],
                                  constant uint2 &indices [[buffer(2)]],
                                  device uint *grandTotals [[buffer(3)]],
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
    if (lid == 0) grandTotals[indices.y] = carry;
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
