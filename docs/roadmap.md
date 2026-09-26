# Roadmap

Order: finish what is **most implemented** first, then what is **partly implemented**, then what is **not implemented**. Within each area, smaller items come first. The goal is to run every Wallpaper Engine wallpaper except the `application` type (see [`architecture.md`](architecture.md)).

**Status: 2026-09-25.** PR #2, branch `deepratna/feature-work`.

## Done

- Hotfixes: audio capture lifecycle, translator regressions, stable signing, no permission prompt spam.
- Phase 1: guidelines, reorganization, tests, CI.
- Phase 2: effects and shaders through WE's own shaders (M1–M8), plus the library sweep.
- Phase 3: composition, fullscreen and solid layers, `_rt_FullFrameBuffer`, effects on text layers, object draw order.
- Phase 4: user properties on every field, per-wallpaper property store, sidebar conditions and property types, web wallpaper properties and audio.
- Phase 5: parent transforms, image alignment, WE text layout and colour.
- M8: library sweep passes (44 wallpapers, 0 failures).

## Work queue (autonomous loop, from 2026-09-25 night)

Each step: research → parallel agents by file ownership + tester → fix the tester's findings → full suite and sweeps on a clean HEAD → push → optimise → next.

1. Finish in flight: the depth-parallax and shine bug (3802047741). The particle finish (child control points, per-instance ropes, non-uniform scale, particle uniform arena, test cleanup) is done.
2. WE-authored values everywhere (priority): every threshold, default, range, step and option comes from WE's json, shader annotations and scripts (effect.json, materials, `// {..}` uniform annotations, `[COMBO]`, project.json properties, particle jsons, SceneScript `createScriptProperties`). No invented constants, magic factors or app-made ranges. Audit → fix → a test that fails on hard-coded values.
3. Area 4 SceneScript: research plan (docs/scenescript-plan.md) → implement → corpus replay over every library script → tester → optimise.
4. Area 3 Timeline animations → tester → optimise.
5. Area 5 Lighting and reflections → tester → optimise.
6. Area 6 3D models (with particle collisionmodel) → tester → optimise.
7. Area 7 Puppet warp → tester → optimise.
8. Gaps queue, worked in alongside when their files are free:
   - A shader-compiler helper process (hung compile with no Homebrew fallback).
   - Music-sync settings keyed by stable identity, not the path.
   - Text with effects, blend modes or emoji through WE's font path.
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
2. ~~Child particle systems (`children`)~~: done. Static children and event children (`eventfollow`, `eventspawn`, `eventdeath`) with probability, instance budget (`maxcount`), nesting and `inherit…fromevent`, on the GPU (events never leave it) and the CPU. Link flag 1 ("set control points to particle positions"): from `controlpointstartindex` on, the child's control points are the parent's particles (a static child of an instanced system reads its own parent instance's), without a GPU read back; control point 0 stays the origin. Point operators (`controlpointattract`, `vortex`, `reducemovementnearcontrolpoint`, `maintaindistancetocontrolpoint`) and the emitter sit on their own `controlpoint`. A rope on an instanced system draws one strand per instance. Control point flags 1 (cursor), 2 (scene position) and 4 (the parent's control point `parentcontrolpoint`) and `mapsequence*`'s flags (taper, velocity, size, arc, count override, restart with periodic emission) follow `wallpaper64.exe`; operators and initializers run as WE's compiled program, in order, so two of one kind both apply. Open: control point flag 16 (no runtime test found in WE), a second emitter (4 corpus systems; only the first runs, logged).
3. ~~Audio-reactive particle properties and collision operators~~: done. Audio response on emitters' rate, `turbulentvelocityrandom`, `turbulence` and `vortex`; `collisionplane`, `collisionsphere`, `collisionquad` and `collisionbounds` with bounce, slide, stop and delete (`collisionbox` is a no-op in WE). Emitter `delay`, `duration`, random periodic emission (flags bit 2, `min/maxperiodicduration`, `min/maxperiodicdelay`, `maxtoemitperperiod`, bursting `instantaneous` each period) and "limit to one per frame" (flags bit 1), per system and per instance, CPU and GPU. RG88 textures load as (r, g, 0, 1) and particle materials set `TEX<n>FORMAT=8` (albedo `.rrrg`, normal maps `.gr`), which also fixes RG88 flow maps (`shake`, `waterflow`). Open: `collisionmodel` (needs area 6).
4. Particles through WE's `genericparticle` shaders and materials: blend modes, sprite and trail material options, refraction.
5. ~~Effects on particle systems~~: WE has no per-particle-system effects; wallpapers use composition layers, which already work.
6. ~~Object scale on sprites~~: done. WE expands a sprite in its system's space and draws it through the model matrix, so a non-uniform scale squashes it (as linux-wallpaperengine and wallpaper-scene-renderer draw it); sizes and rotations stay local and the emitter's transform draws them (`g_Orientation*`, the built-in quad's axes). Open: WE simulates in the system's units, so velocities, gravity and operator distances would scale with the object too; ours are scene units turned but not scaled by it.
7. ~~Every particle default and semantic from WE~~: done (`docs/we-values-audit.md` §6). Open: WE's frame-rate-dependent drag factor (`0.025 / [engine+0x14c]`, the field not identified) and its half-step substeps (a setting of 1…20), `sprite` `orientation`, rope `uvsmoothing`/`uvscale`/`uvscrolling`.

### 3. Timeline animations (partly implemented)

1. Origin, scale, angles and size keyframes (E7: a static value currently overrides the timeline).
2. Bezier and easing parity for every keyframe track, animated effect constants included.
3. The `getTextureAnimation` API: play, pause, stop, frame and rate.
4. The `getAnimation` / animation-layer API for puppet and model animations; this completes with area 7.

### 4. SceneScript (partly implemented; Phase 6)

1. One JavaScript context per scene with live layer proxies. `thisLayer` writes stick, `update(value)` chains, and the 36%-of-frame re-bridging goes away.
2. Visibility scripts every frame; objects hidden at load stay creatable and showable.
3. `getEffect(...).visible`, `getMaterial`, `setMaterialProperty`, wired to the effect constants.
4. Live left/right `registerAudioBuffers` (16/32/64).
5. Input: scene-space cursor, events only on `solid` layers with hit-testing, angles in degrees.
6. Callbacks: `applyUserProperties` (changed keys only), `media*`, `destroy`, `resizeScreen`.
7. Layer API: `createLayer` from an asset, `destroyLayer`, `sortLayer`, `getLayerIndex`, sound layers, `localStorage`.

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
3. Hidden layers (script `visible=false`) still draw their raw texture. [4]
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
15. Built-ins never set: `g_PointerPositionLast`, `g_PointerState`, `g_ParallaxPosition`; `g_Texture*Resolution` reports the allocated size; spritesheet effect textures don't animate. [1]
16. Camera shake and parallax: amplitude, speed, roughness and delay are unused; parallax is our own model (0.18 factor). [new]
17. Clear, ambient and skylight colours are decoded but not applied. [5]
18. The sidebar writes to the un-keyed property store, so with two displays an edit can land on the other wallpaper. [4]
19. Scene audio cache names use `hashValue` (random per launch), so copies pile up in Caches. [new]
20. Pipeline compiles are unbounded, with no eviction or retry; the variant cache key ignores toolchain versions; a `TEMPDUMP` debug block is left in. [1]
21. The text cache clears completely past 128 entries and thrashes with animated scale. [new]
22. Script clones share `layer.id` with their source (text and effect state), and effect state is never pruned. [4]
23. Objects without an `id`: the hierarchy uses the index, layers use −1, so the parent link is lost. [new]
24. Dead `_owe_effect_*` UI code; toggling parallax triggers a full rebuild. [new]
