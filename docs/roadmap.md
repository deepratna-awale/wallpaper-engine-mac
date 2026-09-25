# Roadmap

Order: finish what is **most implemented** first, then what is **partly implemented**, then what is **not implemented**. Within each area, smaller items come first. The goal is to run every Wallpaper Engine wallpaper except the `application` type (see [`architecture.md`](architecture.md)).

**Status: 2026-09-25.** PR #2, branch `deepratna/feature-work`.

## Done

- Hotfixes: audio capture lifecycle, translator regressions, stable signing, no permission prompt spam.
- Phase 1: guidelines, reorganization, tests, CI.
- Phase 2: effects and shaders through WE's own shaders (M1–M8), plus the library sweep.
- Phase 3: composition, fullscreen and solid layers, `_rt_FullFrameBuffer`, effects on text layers, object draw order.

## In progress

- **Phase 4: generic value bindings.** User properties on every field, per-wallpaper property store, sidebar conditions and property types, web wallpaper properties and audio.
- **Phase 5: text and transforms.** Parent transforms, image alignment, WE text layout, text color, Retina-sharp text.

## Next, in order

### 1. Shader programming (mostly implemented)

1. M9: in-process glslang and SPIRV-Cross, which removes process spawns (about 90× faster first loads).
2. `MTLBinaryArchive` for pipeline states.
3. Base image materials through WE shaders (`genericimage2/3/4` and custom image-layer shaders) instead of our own image draw. This unlocks material combos and blend modes and is the foundation for lighting (area 5).
4. Geometry-shader emulation (`genericparticle.geom`, `flatpoint.geom`, rope) using vertex expansion or instancing.

### 2. Particle systems (largely implemented)

1. Instance overrides (rate, count, size, alpha, speed, lifetime, color), which Phase 4 is adding.
2. Child particle systems (`children`).
3. Audio-reactive particle properties and collision operators.
4. Particles through WE's `genericparticle` shaders and materials: blend modes, sprite and trail material options, refraction.
5. Effects on particle systems.

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
