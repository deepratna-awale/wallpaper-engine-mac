#include "ParticleShared.h"

// The GPU step's last stage: record counts, indirect draw arguments and the records a system is
// drawn from, for WE's particle materials and for the renderer's built-in draw
// (`ParticleRecordWriter` on the CPU). Run by `ParticleGPUSimulator` after the step.

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
    sizes[6] = sizeof(ParticleInstanceState);
    sizes[7] = sizeof(CollisionPlacement);
}
