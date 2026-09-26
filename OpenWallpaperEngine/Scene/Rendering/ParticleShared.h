#ifndef ParticleShared_h
#define ParticleShared_h

#include <metal_stdlib>
using namespace metal;

// Declarations the particle kernels share (`ParticleSimulation.metal`, `ParticleRecords.metal`,
// `ParticleProgram.h`):
// the layouts `ParticleGPUTypes.swift` mirrors, flags, control words, the random streams of
// `ParticleRandom` and small helpers.

// MARK: - Shared layouts

struct ParticleState {
    float4 positionVelocity; // position xy, velocity zw
    float4 life;             // age, lifetime, size, base size
    float4 alphaRotation;    // alpha, base alpha, rotation, angular velocity
    float4 color;
    float4 baseColor;
    float4 trail;            // history timer, -, instance
    uint4 identity;          // serial, sprite frame, history count, history start
};

struct ParticleParameters {
    uint4 counts;            // maximum, flags, seed, history limit
    float4 trail;            // history interval, trail length, rope subdivision, fades (1 alpha, 2 size)
    float4 trailLimits;      // `spritetrail` maxlength, minlength
    float4 spriteSheet;      // frames, columns, rows, duration
    float4 sprite;           // mode (0 sequence, 1 once, 2 random frame), sequence multiplier, opacity multiplier, refractive
    uint4 instancing;        // link kind (0 none, `ParticleChildLink.Kind`), instances, emitters, -
    float4 link;             // probability
    uint4 linking;           // linked, first control point, per parent instance
};

/// One emitter (`ParticleGPUEmitter`).
struct EmitterParameters {
    float4 origin;           // `ParticleEmitterShape`: origin xyz, control point
    float4 directions;       // directions xyz, -cos(cone * pi)
    float4 minimum;          // distance minimum xyz, speed minimum
    float4 maximum;          // distance maximum xyz, speed maximum
    float4 sign;             // sign xyz
    float4 timing;           // `ParticleEmitterTiming`: delay, duration, periodic duration min, max
    float4 period;           // periodic delay min, max, periodic
    uint4 flags;             // box, applies sign, instantaneous
};

/// One emitter's part of the step (`ParticleGPUEmitterStep`).
struct EmitterStep {
    float4 rate;             // rate
    uint4 control;           // burst, period limit (~0: none), starts a period, one per frame
};

/// One emitter's running state (`ParticleGPUEmitterState`), per slot.
struct EmitterState {
    float4 clock;            // `ParticleEmitterClock.state` (instances)
    float4 carry;            // carried fraction
    uint4 counts;            // period emitted (systems), first spawn, spawns, sequence restart
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
    float4 emission;    // source angular velocity
    uint4 state;        // flags (`iActive`…), source serial, live particles, first spawn
    uint4 spawn;        // spawned this step, spawned before it, the spawn its sequence restarts from
};

struct ParticleFrame {
    float4 time;             // delta, system time, damped step (`dragDeltaTime`), engine time
    float4 misc;             // time of day, clears
    float4 scene;            // scene size xy, target size xy
    uint4 indices;           // frame index, material vertex count, render-var offset in floats (~0: none), draw kind
    float4 spaceLinear;      // the system's space in the scene: column 0 xy, column 1 xy
    float4 spaceMotion;      // its translation xy, the motion's translation xy
    float4 toSpace;          // the inverse linear part: column 0 xy, column 1 xy
    float4 emitterLinear;    // `ParticleFrameInputs.emitterLinear`: column 0 xy, column 1 xy
    float4 controlPoints[4]; // two per vector, in the system's space
    float4 previousControlPoints[4];
    float4 motionLinear;     // motion column 0 xy, column 1 xy
    float4 motionExtras;     // spawn size scale, spawn turn, has motion, trail and rope record size scale
    uint4 extra;             // control points that stay put in every instance, maximum, collisions, initializers | operators << 16
    float4 spawnScale;       // instance overrides: size, alpha, lifetime, speed
    float4 colorScale;       // instance overrides: tint times brightness
    uint4 emission;          // substeps, emitters
    float4 spriteLinear;     // a built-in sprite's quad axes (`spriteLinear`): column 0 xy, column 1 xy
    float4 rope;             // `ParticleRopeUV.layout`: rate, lifetime, frame-rate limit, 1 / uvscale
};

/// One encoded program record (`ParticleProgramOp`).
struct ProgramOp {
    uint4 header;            // kind, flags, control points, enums
    float4 a, b, c, d, e;
    float4 blend;            // `ParticleBlend.window`; x < -1 without one
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
constant uint kHistory = 1u << 0, kRopeSmoothing = 1u << 1, kSpriteSheet = 1u << 2, kInstanced = 1u << 3;
constant uint kWorldSpace = 1u << 4, kRopeScrolling = 1u << 5;

// Instance flags (`ParticleGPUInstance`).
constant uint iActive = 1u << 0, iEmitting = 1u << 1, iFresh = 1u << 2, iClearing = 1u << 3;

// `ParticleInheritance`.
constant uint hSetColor = 1u << 0, hMultiplyColor = 1u << 1, hSetOpacity = 1u << 2, hMultiplyOpacity = 1u << 3;
constant uint hSetVelocity = 1u << 4, hAddVelocity = 1u << 5, hSetSize = 1u << 6, hMultiplySize = 1u << 7;
constant uint hSetRotation = 1u << 8, hAddRotation = 1u << 9, hSetAngularVelocity = 1u << 10;
constant uint hAddAngularVelocity = 1u << 11;

// Link kinds (`ParticleChildLink.Kind`).
constant uint lStatic = 1, lFollow = 2, lSpawn = 3, lDeath = 4;

// Control words (`ParticleGPUSystem.Control`).
// Particles that died aging since the system started (a rope's scrolling UVs).
constant uint cCount = 0, cEmit = 1, cTotal = 2, cSerial = 3, cDied = 4, cTrailTotal = 6;
constant uint cSerialBase = 7;
constant uint cDispatch = 8, cMaterialDraw = 12, cFallbackDraw = 16, cEventTotal = 20;
// Particles that died aging this step, the live particles after this step's spawns, the serial the
// current emission period started at.
constant uint cDead = 21, cLive = 22, cPeriodSerial = 23;

// Draw kinds (`ParticleGPUDrawKind`); 0 (sprite records) and 3 (built-in sprites) need no case.
constant uint kDrawRope = 1, kDrawRopeTrail = 2;
constant uint kFallbackSpriteTrail = 4, kFallbackRope = 5, kFallbackRopeTrail = 6;

constant uint kGroup = 256;

// MARK: - Randomness (`ParticleRandom`)

// Random streams (`ParticleRandom.Stream`), in order.
constant uint sSpawnAngle = 0;
constant uint sSpawnHeight = 1;
constant uint sSpawnRadius = 2;
constant uint sEmitterSpeed = 3;
constant uint sFallbackX = 4;
constant uint sFallbackY = 5;
constant uint sFallbackZ = 6;
constant uint sSpriteFrame = 7;
constant uint sEventProbability = 8;
constant uint sPeriodDuration = 9;
constant uint sPeriodDelay = 10;
constant uint sOperator = 11;

/// `ParticleProgramCPU.initializerStream`.
static uint initializerStream(uint index, uint k) { return 64u + index * 16u + k; }

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

/// `ParticleSystemRuntime.opacity`: alpha (fades included, `alphafade` is an operator) with the
/// material's multiplier.
static float particleOpacity(ParticleState particle, constant ParticleParameters &p, constant ParticleFrame &f) {
    return particle.alphaRotation.x * p.sprite.z;
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

/// A built-in sprite drawn along `linear` (`ParticleSystemRuntime.spriteLinear`), as
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
static uint rateLimit(EmitterStep step, uint emitted) {
    const uint periodLimit = step.control.y;
    uint limit = periodLimit == 0xFFFFFFFFu ? 0xFFFFFFFFu : (periodLimit > emitted ? periodLimit - emitted : 0u);
    if (step.control.w != 0) limit = min(limit, 1u);
    return limit;
}

/// `ParticleCPUSimulation.emission`: the burst and the rate's spawns (at most `limit`), updating
/// the carry-over as WE does (the burst comes out of it too; a full system takes nothing from the
/// rate).
static uint2 emission(int live, int maximum, float rate, float deltaTime, thread float &carry, int burst, uint limit) {
    const int available = max(maximum - live, 0);
    burst = max(burst, 0);
    if (live >= maximum) return uint2(uint(min(burst, available)), 0);
    carry += max(rate, 0.0f) * deltaTime;
    int count = 0;
    if (carry >= 1) {
        // Clamped before the conversion, which is undefined past int's range; the maximum caps it anyway.
        count = int(min(floor(carry), 2147483520.0f));
        carry -= float(count) + float(burst);
        count = int(min(uint(count), limit));
    } else {
        carry -= float(burst);
    }
    const int taken = min(burst, available);
    return uint2(uint(taken), uint(min(count, available - taken)));
}

#endif
