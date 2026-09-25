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

/// `ParticleCPUSimulation.emissionCount` for one instance.
static uint instanceEmission(thread ParticleInstanceState &instance, int maximum, float rate, float deltaTime,
                             int burst) {
    const int live = int(instance.state.z);
    const int available = max(maximum - live, 0);
    const int taken = min(max(burst, 0), available);
    float carry = instance.emission.y + max(rate, 0.0f) * deltaTime;
    const int count = max(0, min(int(min(carry, 2147483520.0f)), available - taken));
    carry -= float(count);
    if (live + taken + count >= maximum) carry = fmod(carry, 1.0f);
    instance.emission.y = carry;
    return uint(taken + count);
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
                } else if (instance.state.x & iActive) {
                    instance.state.x &= ~iFresh;
                    instance.place.xy = source.place.xy;
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
        const int maximum = int(p.counts.x);
        for (uint slot = 0; slot < slots; ++slot) {
            ParticleInstanceState instance = instances[slot];
            instance.state.w = emitted;
            if ((instance.state.x & iActive) && (instance.state.x & iEmitting)) {
                const int burst = (instance.state.x & iFresh) ? int(p.instancing.w) : 0;
                instance.spawn.x = instanceEmission(instance, maximum, f.time.z, f.time.x, burst);
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
