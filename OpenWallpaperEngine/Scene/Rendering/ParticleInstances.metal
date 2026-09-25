#include "ParticleShared.h"

// Instanced child systems on the GPU (`ParticleChildLink`), step for step
// `ParticleCPUSimulation+Instances.swift`. An event child reads its parent's step without a CPU
// round trip: after the parent's step, `particleEventMark` flags the parent particles that make an
// event (spawned or died this step, and passing the link's probability), a prefix sum orders them,
// `particleEventScatter` lists them, and `particleInstanceStep` hands them out to free instances in
// slot order, updates the instances and decides each one's emission. It replaces `particleBegin`
// for an instanced system; emission, simulation and compaction then run as for any system.

/// Flags the parent particle `gid` when it makes an event for this child.
kernel void particleEventMark(device const ParticleState *parentStepped [[buffer(0)]],
                              device const uint *parentAlive [[buffer(1)]],
                              device const uint *parentControl [[buffer(2)]],
                              device uint *flags [[buffer(3)]],
                              constant ParticleParameters &p [[buffer(4)]],
                              uint gid [[thread_position_in_grid]]) {
    if (gid >= parentControl[cTotal]) return;
    const ParticleState particle = parentStepped[gid];
    bool event;
    if (p.instancing.x == lDeath) {
        event = parentAlive[gid] == 0;
    } else {
        event = particle.identity.x - parentControl[cSerialBase] < parentControl[cEmit];
    }
    if (event) event = unitRandom(p.counts.z, particle.identity.x, sEventProbability) < p.link.x;
    flags[gid] = event ? 1 : 0;
}

/// Lists the flagged parent particles in order (`particleScanBlocks` numbered them).
kernel void particleEventScatter(device const uint *flags [[buffer(0)]],
                                 device const uint *offsets [[buffer(1)]],
                                 device const uint *blockSums [[buffer(2)]],
                                 device const uint *parentControl [[buffer(3)]],
                                 device uint *events [[buffer(4)]],
                                 uint gid [[thread_position_in_grid]]) {
    if (gid >= parentControl[cTotal] || flags[gid] == 0) return;
    events[offsets[gid] + blockSums[gid / kGroup]] = gid;
}

/// `ParticleInstance.track`.
static void trackSource(thread ParticleInstanceState &instance, ParticleState particle) {
    instance.place.xy = particle.positionVelocity.xy;
    instance.source = float4(particle.positionVelocity.zw, particle.life.z, particle.alphaRotation.z);
    instance.sourceColor = float4(particle.color.xyz, particle.alphaRotation.x);
    instance.emission.x = particle.alphaRotation.w;
}

/// `ParticleInstance.inheritSource`.
static void inheritSource(thread ParticleInstanceState &instance, ParticleInstanceState parent) {
    instance.source = parent.source;
    instance.sourceColor = parent.sourceColor;
    instance.emission.x = parent.emission.x;
}

/// The parent particle with `serial`, by binary search (particles stay in spawn order); `count`
/// when there is none.
static uint findSerial(device const ParticleState *particles, uint count, uint serial) {
    if (count == 0) return 0;
    const uint first = particles[0].identity.x;
    uint low = 0, high = count;
    while (low < high) {
        const uint middle = (low + high) / 2;
        if (particles[middle].identity.x - first < serial - first) low = middle + 1; else high = middle;
    }
    return low < count && particles[low].identity.x == serial ? low : count;
}

/// `ParticleEmitterClock.phaseLength`.
static float phaseLength(uint phase, constant ParticleParameters &p, uint key) {
    const bool emitting = phase % 2 == 0;
    const float2 range = emitting ? p.emitterTiming.zw : p.emitterPeriod.xy;
    return randomValue(range.x, range.y, p.counts.z + key * 0x9E3779B9u, phase, emitting ? sPeriodDuration : sPeriodDelay);
}

/// `ParticleEmitterClock.advance`: whether the rate emits (x), the burst goes out (y) and a
/// period starts (z).
static uint3 advanceClock(thread float4 &clock, float deltaTime, constant ParticleParameters &p, uint key) {
    const float delay = p.emitterTiming.x, duration = p.emitterTiming.y;
    const bool periodic = p.emitterPeriod.z > 0.5;
    clock.x += deltaTime;
    const bool running = duration <= 0 || clock.x - delay < duration;
    if (clock.z == 0) {
        if (clock.x < delay) return uint3(0);
        clock.z = 1;
        clock.y = periodic ? phaseLength(0, p, key) : 0;
        clock.w = 0;
        return uint3(running ? 1 : 0, 1, 1);
    }
    uint3 step = uint3(0);
    if (periodic) {
        clock.y -= deltaTime;
        if (clock.y <= 0) {
            const uint phase = uint(clock.z);
            clock.z += 1;
            clock.y = phaseLength(phase, p, key);
            if (phase % 2 == 0) {
                clock.w = 0;
                step.z = 1;
                step.y = running ? 1 : 0;
            }
        }
    }
    step.x = running && (!periodic || uint(clock.z - 1) % 2 == 0) ? 1 : 0;
    return step;
}

/// `ParticleCPUSimulation.updateInstances`' emission for one instance.
static uint instanceEmission(thread ParticleInstanceState &instance, uint slot, constant ParticleParameters &p,
                             constant ParticleFrame &f) {
    // `ParticleCPUSimulation.clockKey`.
    const uint key = instance.state.y * 31u + slot + 1u;
    const uint3 step = advanceClock(instance.clock, f.time.x, p, key);
    float carry = instance.emission.y;
    const uint2 spawned = emission(int(instance.state.z), int(f.extra.y), step.x ? f.time.z : 0.0f, f.time.x, carry,
                                   step.y ? int(p.instancing.w) : 0, rateLimit(f, uint(instance.clock.w)));
    instance.emission.y = carry;
    instance.clock.w += float(spawned.y);
    return spawned.x + spawned.y;
}

/// `ParticleCPUSimulation.updateInstances`, then the step's counters as `particleBegin` sets them.
/// One thread: instances are few, and handing out slots in order keeps it deterministic.
kernel void particleInstanceStep(device uint *control [[buffer(0)]],
                                 device ParticleInstanceState *instances [[buffer(1)]],
                                 constant ParticleParameters &p [[buffer(2)]],
                                 constant ParticleFrame &f [[buffer(3)]],
                                 device const ParticleState *parentStepped [[buffer(4)]],
                                 device const ParticleState *parentParticles [[buffer(5)]],
                                 device const uint *parentControl [[buffer(6)]],
                                 device const uint *events [[buffer(7)]],
                                 device const ParticleInstanceState *parentInstances [[buffer(8)]]) {
    const uint slots = p.instancing.y;
    const uint kind = p.instancing.x;
    uint count = control[cCount];
    uint emitted = 0;
    if (f.fade.z > 0.5) {
        count = 0;
        for (uint slot = 0; slot < slots; ++slot) instances[slot] = ParticleInstanceState{};
    } else {
        const uint parentCount = parentControl[cCount];
        for (uint slot = 0; slot < slots; ++slot) {
            ParticleInstanceState instance = instances[slot];
            instance.place.zw = instance.place.xy;
            instance.spawn.x = 0;
            if (kind == lStatic) {
                const ParticleInstanceState source = parentInstances[slot];
                if (source.state.x & iFresh) {
                    const uint live = instance.state.z;
                    instance = ParticleInstanceState{};
                    instance.state.x = iActive | iEmitting | iFresh;
                    instance.state.z = live;
                    instance.place = float4(source.place.xy, source.place.xy);
                    inheritSource(instance, source);
                } else if (instance.state.x & iActive) {
                    instance.state.x &= ~iFresh;
                    instance.place.xy = source.place.xy;
                    inheritSource(instance, source);
                    const bool emitting = (source.state.x & iActive) != 0;
                    instance.state.x = emitting ? (instance.state.x | iEmitting) : (instance.state.x & ~iEmitting);
                }
            } else if (instance.state.x & iActive) {
                instance.state.x &= ~(iFresh | iClearing);
                if (kind == lFollow || kind == lSpawn) {
                    if (instance.state.x & iEmitting) {
                        const uint found = findSerial(parentParticles, parentCount, instance.state.y);
                        if (found < parentCount) {
                            trackSource(instance, parentParticles[found]);
                        } else {
                            instance.state.x &= ~iEmitting;
                            if (kind == lFollow) instance.state.x |= iClearing;
                        }
                    }
                } else {
                    instance.state.x &= ~iEmitting;
                }
            }
            const uint state = instance.state.x;
            if ((state & iActive) && !(state & (iEmitting | iClearing | iFresh)) && instance.state.z == 0) {
                instance = ParticleInstanceState{};
            }
            instances[slot] = instance;
        }
        if (kind != lStatic) {
            const uint eventCount = control[cEventTotal];
            uint slot = 0;
            for (uint event = 0; event < eventCount; ++event) {
                while (slot < slots && (instances[slot].state.x & iActive)) ++slot;
                if (slot >= slots) break;
                const ParticleState source = parentStepped[events[event]];
                ParticleInstanceState instance = ParticleInstanceState{};
                instance.state.x = iActive | iEmitting | iFresh;
                instance.state.y = source.identity.x;
                trackSource(instance, source);
                instance.place.zw = instance.place.xy;
                instances[slot] = instance;
            }
        }
        for (uint slot = 0; slot < slots; ++slot) {
            ParticleInstanceState instance = instances[slot];
            instance.state.w = emitted;
            if ((instance.state.x & iActive) && (instance.state.x & iEmitting)) {
                instance.spawn.x = instanceEmission(instance, slot, p, f);
                emitted += instance.spawn.x;
            }
            // Counted afresh by this step's simulation.
            instance.state.z = 0;
            instances[slot] = instance;
        }
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

/// `ParticleControlPointLink.positions`: the parent particles a linked child's control points take
/// this step, one thread per instance (1 for a system without instances). After the parent's step.
kernel void particleLinkPoints(device const ParticleState *parentParticles [[buffer(0)]],
                               device const uint *parentControl [[buffer(1)]],
                               device LinkedPoints *linked [[buffer(2)]],
                               constant ParticleParameters &p [[buffer(3)]],
                               constant uint &slots [[buffer(4)]],
                               uint slot [[thread_position_in_grid]]) {
    if (slot >= slots) return;
    const uint start = p.linking.y;
    const uint wanted = start < 8 ? 8 - start : 0;
    const bool perInstance = p.linking.z != 0;
    LinkedPoints points;
    for (uint i = 0; i < 4; ++i) points.points[i] = float4(0);
    uint count = 0;
    const uint total = parentControl[cCount];
    for (uint index = 0; index < total && count < wanted; ++index) {
        const ParticleState particle = parentParticles[index];
        if (perInstance && uint(particle.trail.z) != slot) continue;
        if (count % 2 == 0) points.points[count / 2].xy = particle.positionVelocity.xy;
        else points.points[count / 2].zw = particle.positionVelocity.xy;
        ++count;
    }
    points.count = uint4(count, 0, 0, 0);
    linked[slot] = points;
}
