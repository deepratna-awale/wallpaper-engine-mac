#ifndef ParticleShared_h
#define ParticleShared_h

#include <metal_stdlib>
using namespace metal;

// Declarations the particle kernels share (`ParticleSimulation.metal`, `ParticleRecords.metal`):
// the layouts `ParticleGPUTypes.swift` mirrors, flags, control words, the random streams of
// `ParticleRandom` and small helpers.

// MARK: - Shared layouts

struct ParticleState {
    float4 positionVelocity; // position xy, velocity zw
    float4 life;             // age, lifetime, size, base size
    float4 alphaRotation;    // alpha, base alpha, rotation, angular velocity
    float4 color;
    float4 baseColor;
    float4 trail;            // history timer, sequence, instance
    uint4 identity;          // serial, sprite frame, history count, history start
};

struct ParticleParameters {
    uint4 counts;            // maximum, flags, seed, history limit
    float4 lifetimeSize;     // lifetime min, max, size min, max
    float4 alphaRotation;    // alpha min, max, rotation min, max
    float4 angularSpawn;     // angular velocity min, max, spawn extent xy
    float4 velocityRange;    // minimum xy, maximum xy
    float4 emitterShape;     // emitter speed min, max, sign xy
    float4 emitterRing;      // minimum spawn radius ratio
    float4 colorMinimum;
    float4 colorMaximum;
    float4 offsetRange;      // minimum xy, maximum xy
    float4 sequence;         // count, arc amount, mirrored, ring turns
    float4 ringAxisBounds;   // axis xy, bounds min, max
    float4 ringSpeed;        // minimum xy, maximum xy
    float4 initialRemap;     // range min, max, multiply, output (0 size, 1 alpha, 2 velocity)
    float4 limits;           // maximum speed, angular acceleration
    float4 turbulence;       // scale, speed min, max, time scale
    float4 turbulenceMask;   // phase, mask xy
    float4 attractor;        // strength, threshold
    float4 vortex;           // inner speed, outer speed, inner distance, outer distance
    float4 boids;            // alignment, cohesion, separation, threshold
    float4 reduction;        // inner distance, outer distance, reduction amount, constraint strength
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
    uint4 instancing;        // link kind (0 none, `ParticleChildLink.Kind`), instances, -, instantaneous
    float4 link;             // probability
    uint4 inherit;           // `ParticleInheritance` at spawn, every step
    float4 audioVelocity;    // audio-responsive turbulentvelocityrandom: minimum xy, maximum xy
    float4 emitterTiming;    // `ParticleEmitterTiming`: delay, duration, periodic duration min, max
    float4 emitterPeriod;    // periodic delay min, max, periodic
    int4 pointControlPoints0; // `ParticleControlPointLink.controlPoints` (-1: none): spawn origin, attractor,
    int4 pointControlPoints1; // sequence start, end; remap anchor, vortex, reduction, constraint
    uint4 linking;           // linked, first control point, per parent instance
};

/// A collision shape in scene space (`ParticleCollisionPlacement`).
struct CollisionPlacement {
    float4 shape;    // plane: normal xy, distance; sphere: centre xy, radius; quad: centre xy, normal xy
    float4 axis;     // quad: right xy, half size along it, half size along `extra`
    float4 extra;    // quad: second axis xy; z: fixed in the scene
    float4 response; // bounce coefficient, behaviour, stops rotation, kind
};

/// One instance of an instanced child system (`ParticleGPUInstance`, `ParticleInstance`).
struct ParticleInstanceState {
    float4 place;       // translation xy, previous translation xy
    float4 source;      // source velocity xy, size, rotation
    float4 sourceColor; // source colour, alpha
    float4 emission;    // source angular velocity, emission remainder
    uint4 state;        // flags (`iActive`…), source serial, live particles, first spawn
    uint4 spawn;        // spawned this step
    float4 clock;       // `ParticleEmitterClock.state`
};

struct ParticleFrame {
    float4 time;     // delta, elapsed, emission rate, drag
    float4 fade;     // fade in, fade out, clears, burst
    float4 points;   // spawn origin xy, attractor origin xy
    float4 sequence; // start xy, end xy
    float4 anchor;   // remap anchor xy, has sequence
    float4 scene;    // scene size xy, target size xy
    uint4 indices;   // frame index, material vertex count, render-var offset in floats (~0: none), draw kind
    float4 offsetLinear;     // emitter-space offsets (y down) to scene: column 0 xy, column 1 xy
    float4 velocityRotation; // emitter-space velocities to scene: column 0 xy, column 1 xy
    float4 gravityExtent;    // gravity xy, spawn extent scale xy
    float4 origins;          // vortex origin xy, reduction origin xy
    float4 constraintMotion; // constraint origin xy, motion translation xy
    float4 motionLinear;     // motion column 0 xy, column 1 xy
    float4 motionExtras;     // spawn size scale, spawn turn, has motion, trail and rope record size scale
    uint4 extra;             // points that stay put in every instance (`ParticleFrameInputs.AbsolutePoints`), maximum, collisions
    float4 spawnScale;       // instance overrides: size, alpha, lifetime, speed
    float4 colorScale;       // instance overrides: tint times brightness
    float4 audioScales;      // audio responses: turbulentvelocityrandom, turbulence, vortex
    uint4 emission;          // period limit (~0: none), starts a period, one per frame
    float4 drawLinear;       // the emitter's linear its particles are drawn through: column 0 xy, column 1 xy
    float4 linkOffsets0;     // operators' offsets from their control points: attractor xy, reduction xy
    float4 linkOffsets1;     // constraint xy
};

/// `ParticleGPULinkedPoints`: a linked child's control points for one instance.
struct LinkedPoints {
    float4 points[4];
    uint4 count;
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
constant uint kSpriteSheet = 1u << 20, kInstanced = 1u << 21, kWorldSpace = 1u << 22;

// Instance flags (`ParticleGPUInstance`).
constant uint iActive = 1u << 0, iEmitting = 1u << 1, iFresh = 1u << 2, iClearing = 1u << 3;

// `ParticleInheritance`.
constant uint hSetColor = 1u << 0, hMultiplyColor = 1u << 1, hSetOpacity = 1u << 2, hMultiplyOpacity = 1u << 3;
constant uint hSetVelocity = 1u << 4, hAddVelocity = 1u << 5, hSetSize = 1u << 6, hMultiplySize = 1u << 7;
constant uint hSetRotation = 1u << 8, hAddRotation = 1u << 9, hSetAngularVelocity = 1u << 10;
constant uint hAddAngularVelocity = 1u << 11;

// Link kinds (`ParticleChildLink.Kind`).
constant uint lStatic = 1, lFollow = 2, lSpawn = 3, lDeath = 4;

// Absolute points (`ParticleFrameInputs.AbsolutePoints`).
constant uint aSpawnOrigin = 1u << 0, aAttractor = 1u << 1, aSequenceStart = 1u << 2, aSequenceEnd = 1u << 3;
constant uint aRemapAnchor = 1u << 4, aVortex = 1u << 5, aReduction = 1u << 6, aConstraint = 1u << 7;

// Control words (`ParticleGPUSystem.Control`).
constant uint cCount = 0, cEmit = 1, cTotal = 2, cSerial = 3, cRemainder = 4, cPeriodEmitted = 5, cTrailTotal = 6;
constant uint cSerialBase = 7;
constant uint cDispatch = 8, cMaterialDraw = 12, cFallbackDraw = 16, cEventTotal = 20;

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
constant uint sEmitterSpeed = 19;
constant uint sEventProbability = 20;
constant uint sAudioVelocityX = 21;
constant uint sAudioVelocityY = 22;
constant uint sPeriodDuration = 23;
constant uint sPeriodDelay = 24;

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

// MARK: - Points

/// The frame's points for one instance (`ParticleFrameInputs.placed(at:)`): shifted by the
/// instance's position unless they come from the cursor. A system without instances shifts by 0.
struct FramePoints {
    float2 spawnOrigin, attractor, sequenceStart, sequenceEnd, remapAnchor, vortex, reduction, constraint;
};

static FramePoints framePoints(constant ParticleFrame &f, float2 shift) {
    const uint absolute = f.extra.x;
    FramePoints points;
    points.spawnOrigin = f.points.xy + ((absolute & aSpawnOrigin) ? float2(0) : shift);
    points.attractor = f.points.zw + ((absolute & aAttractor) ? float2(0) : shift);
    points.sequenceStart = f.sequence.xy + ((absolute & aSequenceStart) ? float2(0) : shift);
    points.sequenceEnd = f.sequence.zw + ((absolute & aSequenceEnd) ? float2(0) : shift);
    points.remapAnchor = f.anchor.xy + ((absolute & aRemapAnchor) ? float2(0) : shift);
    points.vortex = f.origins.xy + ((absolute & aVortex) ? float2(0) : shift);
    points.reduction = f.origins.zw + ((absolute & aReduction) ? float2(0) : shift);
    points.constraint = f.constraintMotion.xy + ((absolute & aConstraint) ? float2(0) : shift);
    return points;
}

/// `ParticleFrameInputs.linked`: the points on control points `start…` moved to the parent's
/// particles in `linked`.
static void linkPoints(thread FramePoints &points, constant ParticleParameters &p, constant ParticleFrame &f,
                       LinkedPoints linked) {
    if (p.linking.x == 0) return;
    const int start = int(p.linking.y);
    for (int point = 0; point < 8; ++point) {
        const int id = point < 4 ? p.pointControlPoints0[point] : p.pointControlPoints1[point - 4];
        const int index = id - start;
        if (id < max(start, 1) || index >= int(linked.count.x)) continue;
        const float4 pair = linked.points[index / 2];
        const float2 position = (index % 2 == 0) ? pair.xy : pair.zw;
        switch (point) {
        case 0: points.spawnOrigin = position; break;
        case 1: points.attractor = position + f.linkOffsets0.xy; break;
        case 2: points.sequenceStart = position; break;
        case 3: points.sequenceEnd = position; break;
        case 4: points.remapAnchor = position; break;
        case 5: points.vortex = position; break;
        case 6: points.reduction = position + f.linkOffsets0.zw; break;
        default: points.constraint = position + f.linkOffsets1.xy; break;
        }
    }
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

/// A built-in sprite drawn through the emitter's `linear` (`ParticleSystemRuntime.drawLinear`), as
/// WE's model matrix draws it: the quad's axes, in the target's pixels (`LayerUniform.quadAxisX`).
/// The shader's corners run y down, rotated by `rotation`, and its axes are y up.
static void spriteAxes(thread FallbackInstance &instance, float2x2 linear, float rotation, float size,
                       constant ParticleFrame &f) {
    const float2 scale = f.scene.zw / f.scene.xy;
    const float c = cos(rotation), s = sin(rotation);
    // Rotated in the corners' y-down space, then flipped to y up.
    const float2 x = float2(c, -s) * size, y = float2(-s, -c) * size;
    instance.quadAxisX = linear * x * scale;
    instance.quadAxisY = -(linear * y) * scale;
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

// MARK: - Emission

/// `ParticleEmitterClock.rateLimit`, with `~0u` for no limit.
static uint rateLimit(constant ParticleFrame &f, uint emitted) {
    uint limit = f.emission.x == 0xFFFFFFFFu ? 0xFFFFFFFFu : (f.emission.x > emitted ? f.emission.x - emitted : 0u);
    if (f.emission.z != 0) limit = min(limit, 1u);
    return limit;
}

/// `ParticleCPUSimulation.emission`: the burst and the rate's spawns (at most `limit`), updating
/// the carry-over.
static uint2 emission(int live, int maximum, float rate, float deltaTime, thread float &carry, int burst, uint limit) {
    const int available = max(maximum - live, 0);
    const int taken = min(max(burst, 0), available);
    carry += max(rate, 0.0f) * deltaTime;
    // Clamped before the conversion, which is undefined past int's range; the maximum caps it anyway.
    const int allowed = int(min(uint(max(available - taken, 0)), limit));
    const int count = max(0, min(int(min(carry, 2147483520.0f)), allowed));
    carry -= float(count);
    if (live + taken + count >= maximum || uint(count) >= limit) carry = fmod(carry, 1.0f);
    return uint2(taken, count);
}

#endif
