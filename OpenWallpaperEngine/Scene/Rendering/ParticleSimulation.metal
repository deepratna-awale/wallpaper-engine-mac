#include "ParticleProgram.h"

// The particle simulation on the GPU. It is `ParticleCPUSimulation` step for step: the same
// emission arithmetic, program (`ParticleProgram.h`) and random draws (`ParticleRandom`), so the
// two stay interchangeable (`ParticleSimulationParityTests`). Structures mirror
// `ParticleGPUTypes.swift`; `particleLayoutSizes` lets a test check the two agree.
//
// One frame of one system, all in one compute encoder (`ParticleGPUSimulator`), in WE's order
// (`wallpaper64.exe` 0x140236cd0: age and die, emit and initialize, operate):
//   age → begin → emit → simulate → scan → compact → [trail scan] → finish → write records.
// Particles stay in spawn order: the compaction is an order-preserving prefix sum, so rope
// neighbours and boids' neighbours match the CPU's array.

// MARK: - Step

/// `ParticleCPUSimulation.age`: every particle ages by the step; one past its lifetime dies. An
/// instanced system's instances lose their dead.
kernel void particleAge(device ParticleState *particles [[buffer(0)]],
                        device uint *alive [[buffer(1)]],
                        device uint *control [[buffer(2)]],
                        constant ParticleParameters &p [[buffer(3)]],
                        constant ParticleFrame &f [[buffer(4)]],
                        device ParticleInstanceState *instances [[buffer(5)]],
                        uint gid [[thread_position_in_grid]]) {
    if (gid >= control[cCount]) return;
    ParticleState particle = particles[gid];
    particle.life.x += f.time.x;
    particles[gid] = particle;
    const bool dies = particle.life.y < particle.life.x;
    alive[gid] = dies ? 0 : 1;
    if (!dies) return;
    atomic_fetch_add_explicit((device atomic_uint *)(control + cDead), 1u, memory_order_relaxed);
    if (p.counts.y & kInstanced) {
        // `state.z`: uint 18 of the 24 in an instance.
        device uint *live = (device uint *)(instances + uint(particle.trail.z)) + 18;
        atomic_fetch_sub_explicit((device atomic_uint *)live, 1u, memory_order_relaxed);
    }
}

/// Emission counts and the frame's dispatch size (`ParticleCPUSimulation.step`'s emission): every
/// emitter in turn, each counting what the earlier ones spawned (`wallpaper64.exe` 0x1402378a0).
kernel void particleBegin(device uint *control [[buffer(0)]],
                          constant ParticleParameters &p [[buffer(1)]],
                          constant ParticleFrame &f [[buffer(2)]],
                          constant EmitterStep *steps [[buffer(3)]],
                          device EmitterState *emitters [[buffer(4)]]) {
    uint count = control[cCount];
    const uint dead = control[cDead];
    const uint emitterCount = f.emission.y;
    uint emitted = 0;
    if (f.misc.y > 0.5) {
        count = 0;
        for (uint e = 0; e < emitterCount; ++e) {
            emitters[e].carry.x = 0;
            emitters[e].counts = uint4(0);
        }
    } else {
        const uint live = count - min(dead, count);
        for (uint e = 0; e < emitterCount; ++e) {
            const EmitterStep step = steps[e];
            EmitterState state = emitters[e];
            if (step.control.z != 0) {
                state.counts.x = 0;
                control[cPeriodSerial] = control[cSerial] + emitted;
            }
            float carry = state.carry.x;
            const uint2 spawned = emission(int(live + emitted), int(f.extra.y), step.rate.x, f.time.x, carry,
                                           int(step.control.x), rateLimit(step, state.counts.x));
            state.carry.x = carry;
            state.counts.x += spawned.y;
            state.counts.y = emitted;
            state.counts.z = spawned.x + spawned.y;
            state.counts.w = control[cPeriodSerial];
            emitters[e] = state;
            emitted += state.counts.z;
        }
    }
    const uint total = count + emitted;
    control[cCount] = count;
    control[cEmit] = emitted;
    control[cTotal] = total;
    control[cLive] = total - min(f.misc.y > 0.5 ? 0u : dead, total);
    control[cDied] = f.misc.y > 0.5 ? 0u : control[cDied] + dead;
    control[cDead] = 0;
    control[cSerialBase] = control[cSerial];
    control[cSerial] = control[cSerial] + emitted;
    control[cDispatch] = max((total + kGroup - 1) / kGroup, 1u);
    control[cDispatch + 1] = 1;
    control[cDispatch + 2] = 1;
}

/// The emitter of spawn `index` among `emitters` (their first spawn and count, `counts.yz`).
static uint spawningEmitter(device const EmitterState *emitters, uint count, uint index) {
    for (uint e = 0; e + 1 < count; ++e) {
        if (index < emitters[e].counts.y + emitters[e].counts.z) return e;
    }
    return count > 0 ? count - 1 : 0;
}

/// The frame's control points for one instance (`ParticleFrameInputs.placed(at:previous:)`,
/// `linked`): the ones sitting in the scene don't move with it; linked ones are parent particles.
static void placeProgramPoints(thread ProgramContext &c, constant ParticleParameters &p, constant ParticleFrame &f,
                               float2 translation, float2 previousTranslation, bool linkedPoints, LinkedPoints linked) {
    c.origin = f.spaceMotion.xy + translation;
    for (uint i = 0; i < 8; ++i) {
        const float4 pair = f.controlPoints[i / 2];
        const float4 before = f.previousControlPoints[i / 2];
        c.points[i] = (i % 2 == 0) ? pair.xy : pair.zw;
        c.previousPoints[i] = (i % 2 == 0) ? before.xy : before.zw;
        if (f.extra.x & (1u << i)) {
            c.points[i] -= c.toSpace * translation;
            c.previousPoints[i] -= c.toSpace * previousTranslation;
        }
    }
    if (!linkedPoints || p.linking.x == 0) return;
    const uint start = p.linking.y;
    for (uint i = 0; i < linked.count.x; ++i) {
        const uint index = start + i;
        if (index < max(start, 1u) || index >= 8) continue;
        const float4 pair = linked.points[i / 2];
        const float2 position = (i % 2 == 0) ? pair.xy : pair.zw;
        c.points[index] = c.toSpace * (position - c.origin);
    }
}

/// The program's view of the step for particle `serial` (`ParticleCPUSimulation.context`).
static ProgramContext programContext(constant ParticleParameters &p, constant ParticleFrame &f, uint serial) {
    ProgramContext c;
    c.deltaTime = f.time.x;
    c.dragDeltaTime = f.time.z;
    c.engineTime = f.time.w;
    c.systemTime = f.time.y;
    c.timeOfDay = f.misc.x;
    c.seed = p.counts.z;
    c.serial = serial;
    c.random = unitRandom(p.counts.z, serial, sOperator);
    c.space = float2x2(f.spaceLinear.xy, f.spaceLinear.zw);
    c.toSpace = float2x2(f.toSpace.xy, f.toSpace.zw);
    c.emitterLinear = float2x2(f.emitterLinear.xy, f.emitterLinear.zw);
    c.worldSpace = (p.counts.y & kWorldSpace) != 0;
    c.hasSource = false;
    c.source = ParticleInstanceState{};
    c.spawnScale = f.spawnScale;
    c.sequenceIndex = 0;
    c.sequenceRestartIndex = 0;
    return c;
}

/// `ParticleCPUSimulation.spawn`.
static ParticleState spawn(uint serial, constant ParticleParameters &p, constant ParticleFrame &f,
                           constant ProgramOp *program, thread ProgramContext &c, EmitterParameters emitter) {
    ProgramState state;
    state.age = 0;
    state.lifetime = 1;
    state.size = 0;
    state.baseSize = 0.5f;
    state.alpha = 1;
    state.baseAlpha = f.spawnScale.y;
    state.rotation = 0;
    state.angularVelocity = 0;
    state.color = float3(1);
    state.baseColor = f.colorScale.xyz;
    emitParticle(emitter, c, state.position, state.velocity);
    state.previous = state.position;
    runInitializers(program, f.extra.w & 0xFFFFu, state, c);
    const float size = state.baseSize * f.motionExtras.x;
    const uint frames = max(uint(p.spriteSheet.x), 1u);
    ParticleState particle;
    particle.positionVelocity = float4(c.space * state.position + c.origin, c.space * state.velocity);
    particle.life = float4(0, state.lifetime, size, size);
    particle.alphaRotation = float4(state.baseAlpha, state.baseAlpha, state.rotation + f.motionExtras.y, state.angularVelocity);
    particle.color = float4(state.baseColor, 1);
    particle.baseColor = particle.color;
    particle.trail = float4(0);
    particle.identity = uint4(serial, min(uint(unitRandom(p.counts.z, serial, sSpriteFrame) * float(frames)), frames - 1), 0, 0);
    return particle;
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
                         device const LinkedPoints *linked [[buffer(5)]],
                         constant ProgramOp *program [[buffer(6)]],
                         constant EmitterParameters *emitterParameters [[buffer(7)]],
                         device const EmitterState *emitters [[buffer(8)]],
                         uint gid [[thread_position_in_grid]]) {
    if (gid >= control[cEmit]) return;
    const uint serial = control[cSerialBase] + gid;
    const uint emitterCount = p.instancing.z;
    ProgramContext c = programContext(p, f, serial);
    ParticleState particle;
    if (p.counts.y & kInstanced) {
        const uint instance = spawningInstance(instances, p.instancing.y, gid);
        const ParticleInstanceState source = instances[instance];
        placeProgramPoints(c, p, f, source.place.xy, source.place.zw, true, p.linking.x != 0 ? linked[instance] : LinkedPoints{});
        c.hasSource = true;
        c.source = source;
        const uint local = gid - source.state.w;
        device const EmitterState *own = emitters + instance * emitterCount;
        const uint e = spawningEmitter(own, emitterCount, local);
        const uint index = source.spawn.y + local;
        c.sequenceIndex = index;
        c.sequenceRestartIndex = index - own[e].counts.w;
        particle = spawn(serial, p, f, program, c, emitterParameters[e]);
        particle.trail.z = float(instance);
    } else {
        placeProgramPoints(c, p, f, float2(0), float2(0), true, p.linking.x != 0 ? linked[0] : LinkedPoints{});
        const uint e = spawningEmitter(emitters, emitterCount, gid);
        c.sequenceIndex = serial;
        c.sequenceRestartIndex = serial - emitters[e].counts.w;
        particle = spawn(serial, p, f, program, c, emitterParameters[e]);
    }
    particles[control[cCount] + gid] = particle;
}

/// `ParticleCollisionPlacement.resolve`, the shape carried by `shift` (`moved(by:)`).
static void collide(CollisionPlacement collision, float2 shift, thread float2 &position, thread float2 &velocity,
                    thread float &angularVelocity, thread bool &dies, float2 previous) {
    float4 shape = collision.shape;
    const uint kind = uint(collision.response.w);
    if (collision.extra.z < 0.5) {
        if (kind == 0) shape.z += dot(shape.xy, shift);
        else shape.xy += shift;
    }
    float2 normal;
    if (kind == 0) {
        const float depth = dot(shape.xy, position) - shape.z;
        if (!(depth < 0)) return;
        position -= shape.xy * depth;
        normal = shape.xy;
    } else if (kind == 1) {
        const float2 offset = position - shape.xy;
        const float distance = length(offset);
        if (!(distance < shape.z)) return;
        normal = distance > 1e-6f ? offset / distance : float2(0, 1);
        position = shape.xy + normal * shape.z;
    } else {
        const float2 n = shape.zw;
        const float depth = dot(n, position - shape.xy);
        if (!(depth <= 0 && dot(n, previous - shape.xy) > 0 && abs(dot(position - shape.xy, collision.axis.xy)) < collision.axis.z
              && abs(dot(position - shape.xy, collision.extra.xy)) < collision.axis.w)) return;
        position -= n * depth * 1.05f;
        normal = n;
    }
    const uint behavior = uint(collision.response.y);
    if (behavior == 0) velocity += normal * dot(normal, velocity) * collision.response.x;
    else if (behavior == 1) velocity -= normal * dot(normal, velocity);
    else if (behavior == 2) velocity = float2(0);
    else dies = true;
    if (collision.response.z > 0.5) angularVelocity = 0;
}

static bool programCollide(ProgramOp record, thread ProgramState &p, thread const ProgramContext &c,
                           constant CollisionPlacement *collisions, uint collisionCount, float2 shift) {
    const uint first = record.header.z & 0xFFFFu, count = record.header.z >> 16;
    float2 position = c.space * p.position + c.origin;
    float2 velocity = c.space * p.velocity;
    const float2 previous = c.space * p.previous + c.origin;
    bool dies = false;
    for (uint index = first; index < min(first + count, collisionCount); ++index) {
        collide(collisions[index], shift, position, velocity, p.angularVelocity, dies, previous);
    }
    p.position = c.toSpace * (position - c.origin);
    p.velocity = c.toSpace * velocity;
    return dies;
}

/// `ParticleCPUSimulation.follow`: carries a particle along with its emitter's move, `linear`
/// and `translation`.
static void follow(thread ParticleState &particle, device float2 *own, constant ParticleParameters &p,
                   float2x2 linear, float2 translation) {
    particle.positionVelocity = float4(linear * particle.positionVelocity.xy + translation,
                                       linear * particle.positionVelocity.zw);
    if (p.counts.y & kHistory) {
        for (uint sample = 0; sample < particle.identity.z; ++sample) own[sample] = linear * own[sample] + translation;
    }
}

/// `ParticleCPUSimulation.advance`: every operator. Reads `particles` (boids read neighbours from
/// there too), writes `stepped`; particles that died aging stay dead.
kernel void particleSimulate(device const ParticleState *particles [[buffer(0)]],
                             device ParticleState *stepped [[buffer(1)]],
                             device uint *alive [[buffer(2)]],
                             device float2 *history [[buffer(3)]],
                             device const uint *control [[buffer(4)]],
                             constant ParticleParameters &p [[buffer(5)]],
                             constant ParticleFrame &f [[buffer(6)]],
                             device ParticleInstanceState *instances [[buffer(7)]],
                             constant CollisionPlacement *collisions [[buffer(8)]],
                             device const LinkedPoints *linked [[buffer(9)]],
                             constant ProgramOp *program [[buffer(10)]],
                             uint gid [[thread_position_in_grid]]) {
    const uint total = control[cTotal];
    if (gid >= total) return;
    const uint aged = control[cCount];
    ParticleState particle = particles[gid];
    if (gid < aged && alive[gid] == 0) {
        stepped[gid] = particle;
        return;
    }
    const uint flags = p.counts.y;
    const float deltaTime = f.time.x;
    const float2x2 motion = float2x2(f.motionLinear.xy, f.motionLinear.zw);
    device float2 *own = history + gid * p.counts.w;
    float2 shift = float2(0), previousShift = float2(0);
    bool clearing = false;
    ParticleInstanceState instance = ParticleInstanceState{};
    const uint slot = (flags & kInstanced) ? uint(particle.trail.z) : 0;
    if (flags & kInstanced) {
        // `ParticleCPUSimulation.followInstance`: the instance's move around its own position.
        instance = instances[slot];
        shift = instance.place.xy;
        previousShift = instance.place.zw;
        clearing = (instance.state.x & iClearing) != 0;
        const bool moved = f.motionExtras.z > 0.5 || any(instance.place.xy != instance.place.zw);
        if (!(flags & kWorldSpace) && moved && gid < aged) {
            follow(particle, own, p, motion, instance.place.xy + f.spaceMotion.zw - motion * instance.place.zw);
        }
    } else if (f.motionExtras.z > 0.5 && gid < aged) {
        follow(particle, own, p, motion, f.spaceMotion.zw);
    }
    ProgramContext c = programContext(p, f, particle.identity.x);
    placeProgramPoints(c, p, f, shift, previousShift, true, p.linking.x != 0 ? linked[slot] : LinkedPoints{});
    if (flags & kInstanced) {
        c.hasSource = true;
        c.source = instance;
    }
    ProgramState state;
    state.position = c.toSpace * (particle.positionVelocity.xy - c.origin);
    state.velocity = c.toSpace * particle.positionVelocity.zw;
    state.previous = state.position;
    state.age = particle.life.x;
    state.lifetime = particle.life.y;
    state.size = particle.life.z;
    state.baseSize = particle.life.w;
    state.alpha = particle.alphaRotation.x;
    state.baseAlpha = particle.alphaRotation.y;
    state.rotation = particle.alphaRotation.z;
    state.angularVelocity = particle.alphaRotation.w;
    state.color = particle.color.xyz;
    state.baseColor = particle.baseColor.xyz;
    // `ParticleFrameInputs.substeps`: at a frame-rate limit of 20 or less the operators run twice,
    // in half steps; the neighbours stay the step's.
    const uint substeps = max(f.emission.x, 1u);
    c.deltaTime /= float(substeps);
    c.dragDeltaTime /= float(substeps);
    bool dies = false;
    for (uint substep = 0; substep < substeps; ++substep) {
        dies = runOperators(program + (f.extra.w & 0xFFFFu), f.extra.w >> 16, state, c, collisions, f.extra.z, shift,
                            particles, total, gid, control[cLive], f.indices.x, alive, aged) || dies;
    }
    const float2 position = c.space * state.position + c.origin;
    particle.positionVelocity = float4(position, c.space * state.velocity);
    particle.life = float4(dies ? state.lifetime : particle.life.x, state.lifetime, state.size, particle.life.w);
    particle.alphaRotation = float4(state.alpha, particle.alphaRotation.y, state.rotation, state.angularVelocity);
    particle.color = float4(state.color, particle.color.w);
    if (flags & kHistory) {
        const uint limit = p.counts.w;
        particle.trail.x += deltaTime;
        if (particle.trail.x >= p.trail.x || particle.identity.z == 0) {
            particle.trail.x = 0;
            if (particle.identity.z < limit) {
                own[particle.identity.z] = position;
                particle.identity.z += 1;
            } else {
                own[particle.identity.w] = position;
                particle.identity.w = (particle.identity.w + 1) % limit;
            }
        }
    }
    stepped[gid] = particle;
    const bool lives = !clearing;
    alive[gid] = lives ? 1 : 0;
    if ((flags & kInstanced) && lives) {
        // `state.z`: uint 18 of the 24 in an instance.
        device uint *live = (device uint *)(instances + slot) + 18;
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
