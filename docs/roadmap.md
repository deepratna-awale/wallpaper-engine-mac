# Roadmap

Order: finish what is **most implemented** first, then what is **partly implemented**, then what is **not implemented**. Within each area, smaller items come first. The goal is to run every Wallpaper Engine wallpaper except the `application` type (see [`architecture.md`](architecture.md)).

**Status: 2026-09-26.** PR #2, branch `deepratna/feature-work`.

## Done

- Hotfixes: audio capture lifecycle, translator regressions, stable signing, no permission prompt spam.
- Phase 1: guidelines, reorganization, tests, CI.
- Phase 2: effects and shaders through WE's own shaders (M1–M8), plus the library sweep.
- Phase 3: composition, fullscreen and solid layers, `_rt_FullFrameBuffer`, effects on text layers, object draw order.
- Phase 4: user properties on every field, per-wallpaper property store, sidebar conditions and property types, web wallpaper properties and audio.
- Phase 5: parent transforms, image alignment, WE text layout and colour.
- M8: library sweep passes (44 wallpapers, 0 failures).
- Area 4 SceneScript, WP0–WP11 (docs/scenescript-plan.md): every scene's scripts run on `SceneScriptRuntime`, one per wallpaper instance, feeding the renderer through the object table; the legacy engine's scripting is deleted. Then WP11's gaps and the optimisation pass: WE's sound layers play, clicks count only on the wallpaper, a draw shows its own script frame, `createLayer` makes particle systems and sounds, `brightness`/`size` scripts are drawn, and JavaScriptCore JIT-compiles the scripts.
- Area 3 Timeline animations, T0–T7 (docs/timeline-plan.md): WE's timeline format and maths, bit for bit against a reference model; one set per wallpaper instance driving layer fields, effect constants, scene settings, particle overrides and sprite sheets (layers, effects and materials); the script API (`IAnimation`, `ITextureAnimation`, `animationEvent`); a render sweep of every animated library scene; and an optimisation pass (the library's timelines cost under 4 µs a frame).
- One instance per wallpaper, however many displays show it (architecture.md "Wallpaper instances"): an app-level registry of shared instances, reference-counted by the displays; a scene loads, scripts, simulates and renders once (at the largest scene target its displays need) and each display presents the frame at its own size and placement; one player per video; web pages on the other displays muted; each wallpaper's sound plays once, and Settings → Audio Output works. Two 1080p displays of one scene: the frame's CPU time falls to 0.38–0.56 of two renderers', its GPU time mostly to 0.25–0.74 (`SceneSharedInstanceBenchmarkTests`).

## Work queue (autonomous loop, from 2026-09-25 night)

Each step: research → parallel agents by file ownership + tester → fix the tester's findings → full suite and sweeps on a clean HEAD → push → optimise → next.

1. Finish in flight: the depth-parallax and shine bug (3802047741). The particle finish (child control points, per-instance ropes, non-uniform scale, particle uniform arena, test cleanup) is done.
2. WE-authored values everywhere (priority): every threshold, default, range, step and option comes from WE's json, shader annotations and scripts (effect.json, materials, `// {..}` uniform annotations, `[COMBO]`, project.json properties, particle jsons, SceneScript `createScriptProperties`). No invented constants, magic factors or app-made ranges. Audit → fix → a test that fails on hard-coded values.
3. Area 4 SceneScript: research plan (docs/scenescript-plan.md) → implement → corpus replay over every library script → tester → optimise. WP0–WP11, their gaps and the optimisation pass done; WP12's timeline half is done with area 3 (animation layers and bones wait for areas 6 and 7).
4. ~~Area 3 Timeline animations → tester → optimise.~~ Done (animation layers wait for areas 6 and 7).
5. Area 5 Lighting and reflections → tester → optimise.
6. Area 6 3D models (with particle collisionmodel) → tester → optimise.
7. Area 7 Puppet warp → tester → optimise.
8. Gaps queue, worked in alongside when their files are free:
   - A shader-compiler helper process (hung compile with no Homebrew fallback).
   - Music-sync settings keyed by stable identity, not the path.
   - Text with effects, blend modes or emoji through WE's font path.
   - UI: stray line under the seek bar — fixed be620ce (a stepped `Slider` drew a tick mark per step; `NumericSliderInput` now snaps the value instead).
   - Anything the testers find.
9. After each area: a performance pass (frame time, load time, memory) on the library, and bug fixes.

Blocked on WE ground truth (captures on Windows): see docs/test-risks.md "needs WE ground truth".

## Next, in order

### 1. Shader programming (mostly implemented)

1. M9: in-process glslang and SPIRV-Cross, which removes process spawns (about 90× faster first loads).
2. `MTLBinaryArchive` for pipeline states.
3. Base image materials through WE shaders (`genericimage2/3/4` and custom image-layer shaders) instead of our own image draw. This unlocks material combos and blend modes and is the foundation for lighting (area 5).
4. Geometry-shader emulation (`genericparticle.geom`, `flatpoint.geom`, rope) using vertex expansion or instancing.

### 2. Particle systems (largely implemented)

1. ~~Instance overrides (rate, count, size, alpha, speed, lifetime, color)~~: done; user-bound fields resolve every frame, and `controlpoint<n>` places control points. A property change still triggers a content rebuild, which restarts the particles.
2. ~~Child particle systems (`children`)~~: done. Static children and event children (`eventfollow`, `eventspawn`, `eventdeath`) with probability, instance budget (`maxcount`), nesting and `inherit…fromevent`, on the GPU (events never leave it) and the CPU. Link flag 1 ("set control points to particle positions"): from `controlpointstartindex` on, the child's control points are the parent's particles (a static child of an instanced system reads its own parent instance's), without a GPU read back; control point 0 stays the origin. Point operators (`controlpointattract`, `vortex`, `reducemovementnearcontrolpoint`, `maintaindistancetocontrolpoint`) and the emitter sit on their own `controlpoint`. A rope on an instanced system draws one strand per instance. Control point flags 1 (cursor), 2 (scene position) and 4 (the parent's control point `parentcontrolpoint`) and `mapsequence*`'s flags (taper, velocity, size, arc, count override, restart with periodic emission) follow `wallpaper64.exe`; operators and initializers run as WE's compiled program, in order, so two of one kind both apply. Every emitter of a system runs, each on its own clock (per system and per instance); remap's control point inputs and outputs follow WE, including its write-back into the shared control point array (a program that writes points runs record by record, on the GPU in one thread). Control point flag 16 has no runtime effect in WE.
3. ~~Audio-reactive particle properties and collision operators~~: done. Audio response on emitters' rate, `turbulentvelocityrandom`, `turbulence` and `vortex`; `collisionplane`, `collisionsphere`, `collisionquad` and `collisionbounds` with bounce, slide, stop and delete (`collisionbox` is a no-op in WE). Emitter `delay`, `duration`, random periodic emission (flags bit 2, `min/maxperiodicduration`, `min/maxperiodicdelay`, `maxtoemitperperiod`, bursting `instantaneous` each period) and "limit to one per frame" (flags bit 1), per system and per instance, CPU and GPU. RG88 textures load as (r, g, 0, 1) and particle materials set `TEX<n>FORMAT=8` (albedo `.rrrg`, normal maps `.gr`), which also fixes RG88 flow maps (`shake`, `waterflow`). Open: `collisionmodel` (needs area 6).
4. Particles through WE's `genericparticle` shaders and materials: blend modes, sprite and trail material options, refraction.
5. ~~Effects on particle systems~~: WE has no per-particle-system effects; wallpapers use composition layers, which already work.
6. ~~Object scale on sprites~~: done. WE expands a sprite in its system's space and draws it through the model matrix, so a non-uniform scale squashes it (as linux-wallpaperengine and wallpaper-scene-renderer draw it); sizes and rotations stay local and the emitter's transform draws them (`g_Orientation*`, the built-in quad's axes). Open: WE simulates in the system's units, so velocities, gravity and operator distances would scale with the object too; ours are scene units turned but not scaled by it.
7. ~~Every particle default and semantic from WE~~: done (`docs/we-values-audit.md` §6), with WE's low-frame-rate drag (the engine frame time [engine+0x14c]) and half steps at an fps limit of 1…20 ([engine+0x148]), renderer `orientation`/`axis`, and rope `uvscale`/`uvsmoothing`/`uvscrolling`.
8. ~~Performance pass~~: done (2026-09-25; `ParticleLibraryBenchmarkTests`, `ParticleSimulationPerformanceTests`, `ParticleMaterialPerformanceTests`). The GPU step now runs stage by stage for every system at once (one concurrent encoder, a barrier between stages) instead of each system's dozen dispatches in turn: a small system's fixed cost fell from about 48 µs to 3 µs, and every library wallpaper's simulation takes 0.03…0.27 ms of GPU time (was up to 0.43 ms; 10–11 systems 0.29…0.38 → 0.07…0.09 ms). The CPU inputs and encode take 0.03…0.08 ms a system (Debug), the material draw about 0.07 ms; pipeline keys, uniform members, the time of day and the sprite axes are cached. Open: a rate bound to a script costs 0.5…4 ms a frame in the script engine (area 4); the draws are fill-bound and dominate the heaviest wallpaper (20 000 refracting rain sprites, several ms at 1080p); boids and an instanced rope's neighbour search are O(n²).

### 3. Timeline animations (implemented but for animation layers; docs/timeline-plan.md)

1. ~~Origin, scale, angles and size keyframes (E7)~~: done. WE's own format, evaluated per wallpaper instance by `SceneAnimationSet` (Bézier handles, per-frame samples, single/loop/mirror, `startpaused`, `wraploop`, `relative`, linked clocks); the timeline beats the static and user value, a script's return wins for its frame.
2. ~~Bezier and easing parity, animated effect constants~~: done, bit for bit against the reference model.
3. ~~The `getTextureAnimation` API~~: done. One clock per texture, one step per frame, a script's override (`rate`, `pause`, `stop`, `setFrame`, `join`).
4. ~~`getAnimation`, `IAnimation` on objects, effects, materials and the scene, `animationEvent`~~: done; `thisScene.getAnimation(name)` searches every owner, taking only a string as scenescript64.dll does.
5. ~~Animated `general.*` and particle `instanceoverride` values, sprite-sheet effect and material textures (8.15), the library render sweep and the optimisation pass (T6, T7)~~: done. Animated `visible` stays undrawn, as in WE (a bool isn't written). The tester's findings (script writes on animated constants, NaN clocks, late script frames, hidden layers' texture overrides, static-chain reuse, cold channels) are fixed.
6. The animation-layer API for puppet and model animations; this completes with area 7.

### 4. SceneScript (mostly implemented; Phase 6)

1. ~~One JavaScript context per scene with live layer proxies.~~ Done (WP2–WP11).
2. ~~Visibility scripts every frame; objects hidden at load stay creatable and showable.~~ Done (WP11).
3. ~~`getEffect(...).visible`, `getMaterial`, `setMaterialProperty`, wired to the effect constants.~~ Done (WP7, WP11).
4. ~~Live left/right `registerAudioBuffers` (16/32/64).~~ Done (WP5).
5. ~~Input: scene-space cursor, events only on `solid` layers with hit-testing, angles in degrees.~~ Done (WP4, WP10, WP11).
6. ~~Callbacks: `applyUserProperties` (changed keys only), `media*`, `destroy`, `resizeScreen`.~~ Done (WP4, WP6, WP11).
7. ~~Layer API: `createLayer` from an asset (image, text, shape, particle system, sound), `destroyLayer`, `sortLayer`, `getLayerIndex`, `localStorage`; sound layers played like WE's (modes, gain, timers, mute and pause, script control)~~ done. Open: sound `spatialization` (no library sound uses it).
8. WP12: ~~scene, effect and material animations under script control, `animationEvent`~~ done (area 3); animation layers and bones with areas 6 and 7.
9. Live Now Playing on macOS 15.4+ (MediaRemote answers only entitled processes: the `/usr/bin/perl` adapter or a helper).
10. ~~Performance: JIT (the `allow-jit` entitlement), per-frame allocations in the runtime, no frame of latency.~~ Done; see the plan's cost table.

### 5. Lighting and reflections (mostly not implemented)

1. Light objects (point, spot, tube, directional) decoded and fed to shaders (`g_Lights*`).
2. Lit image layers through `genericimage4` (normal maps, PBR masks); needs area 1 item 3.
3. `_rt_Reflection` and reflection planes.
4. WE's bloom and HDR chain (`materials/util` downsample, blur and combine) instead of our approximation.
5. Shadows (`shadowcaster`, `_rt_shadowAtlas`) and volumetrics.

### 6. 3D models (not implemented)

1. `.mdl` parsing: meshes, materials, bounds.
2. Perspective camera path (`orthogonalprojection: null`, fov/near/far), depth buffer, draw order with depth.
3. Model shaders (`generic4`, `foliage4`, `fur4`, `flag`, …) through the translator, with the full vertex attribute set.
4. Skinning (bones) and morph targets.

### 7. Puppet warp (not implemented)

1. Puppet rigs from `.mdl` (bones, weights, mesh).
2. Skinned rendering of the puppet mesh (shares skinning with area 6).
3. Puppet animation layers (`getAnimationLayer`, blend, rate) and the script bone API.

### 8. Regressions and gaps from the review (2026-09-25)

Ranked; the area each item belongs to is in brackets.

1. Retina scene target: the scene renders at scene size and is upscaled, which defeats sharp text; `g_Screen` reports the scene size. [new, Phase 5]
2. `sceneRegion` crops with the local position (no parent, script, animation or rotation). [new, Phase 3/5]
3. ~~Hidden layers (script `visible=false`) still draw their raw texture.~~ Done (WP11): hidden layers and effects are built and skipped. [4]
4. Animation time is `Float(CACurrentMediaTime())`: precision drifts with uptime, the speed slider makes time jump, effects and particles ignore `_owe_speed`. [3]
5. Static-chain cache is keyed on the input's `ObjectIdentifier` and ignores scripted colour and alpha; `g_Color`/`g_Alpha` use authored values. [1]
6. Effects on text reallocate their buffers whenever the text's size changes (clocks). [1]
7. Render target pool never evicts; `sceneRegion` sizes grow it. [1]
8. `Int32(value.rounded())` traps on NaN/inf in integer uniforms. [1]
9. Name heuristics left: `isSnowParticle`, the "4k" particle scale, parallax `fallbackDepth`. [2]
10. Effect `visible` bound to a missing user property hides the effect (objects default to visible). [4]
11. Inspector effect overrides are baked in as literals, so music sync on effect parameters is probably lost. [4]
12. ~~Particles ignore parent scale, rotation and animation after load; image children of particle systems use the authored transform.~~ Done: emitters follow their live parents (scripts, timeline), particles live in the emitter's space unless `worldspace`, and groups and particle systems parent other objects live. [2]
13. Text `size`: a non-stub size is a fixed box, and the stub test (≤ 2 inside the padding) is a guess. `anchor` and `blockalign` are not applied. [new, Phase 5]
14. Unsupported `_rt_*` inputs (composite, half/quarter buffers) leave the slot unbound. [1/5]
15. Built-ins never set: `g_PointerPositionLast`, `g_PointerState`, `g_ParallaxPosition`; `g_Texture*Resolution` reports the allocated size. ~~Spritesheet effect textures don't animate~~: done (area 3, T7). [1]
16. Camera shake and parallax: amplitude, speed, roughness and delay are unused; parallax is our own model (0.18 factor). [new]
17. Clear, ambient and skylight colours are decoded but not applied. [5]
18. The sidebar writes to the un-keyed property store, so with two displays an edit can land on the other wallpaper. [4]
19. Scene audio cache names use `hashValue` (random per launch), so copies pile up in Caches. [new]
20. Pipeline compiles are unbounded, with no eviction or retry; the variant cache key ignores toolchain versions; a `TEMPDUMP` debug block is left in. [1]
21. The text cache clears completely past 128 entries and thrashes with animated scale. [new]
22. ~~Script clones share `layer.id` with their source (text and effect state), and effect state is never pruned.~~ Done (WP11): created layers get their own ids and free their state when destroyed. [4]
23. Objects without an `id`: the hierarchy uses the index, layers use −1, so the parent link is lost. [new]
24. Dead `_owe_effect_*` UI code; toggling parallax triggers a full rebuild. [new]
