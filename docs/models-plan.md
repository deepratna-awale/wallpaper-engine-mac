# 3D models, the perspective camera, skinning, shadows and planar reflection: evidence and plan

**Status: 2026-09-26. Research only; nothing here is implemented yet.** This covers roadmap area 6 (3D models, with particle `collisionmodel`), the parts of area 7 (puppet warp) that share the `.mdl` format and skinning, and the two lighting packages that were waiting for area 6: C2 (planar `_rt_Reflection`) and D2 (shadows) in [`lighting-plan.md`](lighting-plan.md). It sets out:

- the `.mdl` binary format, every version in the library, from WE's own reader;
- WE's 3D runtime: projection, cameras and camera layers, depth, draw order, model objects, skinning, animation layers, morph targets, shadows, planar reflection, particles and puppets;
- where we stand;
- work packages that parallel agents can take, prerequisites first.

Where the ground truth comes from:

- **Binary:** `wallpaper64.exe` (WE 2.8.0.42). The disassembly is `we64.asm` in the session scratchpad; the helpers are `/Volumes/980Pro/dd-timeline/we.py`. The `.mdl` writer, `bin/resourcecompiler64.exe`, was disassembled to cross-check field meanings. Addresses below are VAs in `wallpaper64.exe` unless marked `rc:`.
- **Shaders:** WE's shipped shaders, vendored in `Vendor/we-assets/shaders` (`generic*`, `foliage4`, `fur4`, `flag`, `shadowcaster*`, `genericimage2/3/4`, `base/model_vertex_v1.h`, `common_pbr_2.h`).
- **Library:** the Steam workshop folder, `/Volumes/980Pro/OpenWallpaperStorage` and WE's default projects, `scene.pkg` contents included: 112 scenes after de-duplicating by workshop id, and 122 `.mdl` files in 26 items.
- **WE captures:** `origin/we-test-wp-images`, `tools/peer` (3455121165, 3159348391, 3378346807, 3657770939, 3734636606, 2515150033, 2321732083). There is no `tools/peer/manual/FINDINGS.md` on that branch, so the editor's 3D behaviour comes from the binary and from scripts in the library (§2.3).
- **Reference implementation:** linux-wallpaperengine has no real `.mdl` reader: `CImage::loadPuppetMesh` scans for a plausible vertex block with a fixed 80-byte stride and reads only positions and UVs. It is not used as ground truth here.

WE can't be run here. Where the binary leaves a value open, it is tagged **[?]**; an inference is **[I]**. Both are listed in §5.

The extracted data is in `/Volumes/980Pro/dd-models`:

| File | Contents |
|---|---|
| `re-mdl/FORMAT.md` | the byte-level `.mdl` spec, every read with its address, and the writer cross-checks |
| `re-mdl/mdl.py` | a parser for every version (`parse(data, decode=True)` also returns vertex arrays, indices and animation samples as numpy arrays): the oracle for M1 and the CPU skinning reference |
| `re-mdl/sweep.py`, `sweep.json`, `sweep_summary.md` | the parse of all 122 library files (122/122 exact), per file: tags, meshes, formats, counts, bones, animations |
| `re-mdl/rc64.asm`, `rc.py` | the writer's disassembly |
| `re-runtime/NOTES.md` | the runtime answers (camera, depth, draw order, model objects, skinning, shadows, reflection, particles, puppets) |
| `re-runtime/*.asm` | 88 annotated excerpts: `cam_*`, `depth_*`, `draw_*`, `mdlobj_*`, `shadowrefl_*`, `particles_*` |
| `survey_files.py`, `mdl_files.json`, `mdl_by_item.json` | every `.mdl` in the library with its section tags, and how each is used (3D, puppet, unreferenced) |
| `survey_scenes.py`, `scenes.json`, `model_objects.json`, `camera_layers.json`, `survey_summary.md` | the scene survey: projection, cameras, camera layers, model objects, puppets, 2D layers |
| `peer/tools/peer/…` | the WE captures used here |

## 1. The `.mdl` format

### 1.1 Container

- **Reader:** the model loader 0x140261880–0x140265a42, called for static models (0x1401d5ba6) and puppets (0x1401fbedd). The writer's field order (rc:0x140020f19 onwards) matches it.
- **Primitives:** little-endian `u8/u16/u32/u64/f32`; `cstr` is NUL-terminated UTF-8; `blob` is a `u32` byte length and that many bytes. A few reads are "capped": a `u32` length, then at most N bytes (0x1400d3ef0).
- **Order:** the `MDLV` part comes first. From MDLV 13 on, a section loop follows: `cstr tag`, `u32 sectionEnd` (an **absolute file offset**, 0x140261770), the body, then a jump to `sectionEnd`. An empty tag ends the file.
  - `MDLS` and `MDLA` are matched on 4 characters, with the version `atoi(tag+4)`. `MDAT0001`, `MDMP0001` and `MDLE0002` must match exactly. Unknown sections are skipped.
  - Old MDLV0013 files carry fill after the terminator (0x00, or 0xCD then 0x00: a debug-heap buffer). The reader never looks at it.
- **Errors:** the reader never fails on truncation; it reads zeros. The only hard checks are MSVC fast-fails (`int 0x29`): more than **128 bones** (0x140262501), a bone or sample blob of the wrong size, out-of-range IK and group indices. Our parser should be strict and log instead (a truncated file is a broken download, not WE behaviour worth copying).
- **Editor recompile:** 0x14027868b compares the header with the writer's current tag `MDLV0023` and reruns `resourcecompiler64.exe -mdl` if it differs. That is editor-only; the runtime reads every version below.

### 1.2 `MDLV`: meshes

```
cstr tag "MDLVnnnn"; V = atoi(tag+4)
u32  legacyFormat              vertex format for V < 15
u32  materialsPerMesh M        one material path per skin (the object's `skin` picks one, §2.6)
u32  meshCount
mesh[meshCount]:
    cstr material[M]
    if V >= 4:  u32 flags      (bit 0: u32 indices; 0x2: a u32 follows [?]; 0x4: SKINNING_ALPHA;
                                0x400/0x800/0x1000/0x2000: extra MDMP blobs, 0x2000 MORPHING_MODIFIERS)
    if flags & 2: u32 [?]
    if V >= 17: f32 aabbMin[3], aabbMax[3]
    if V >= 15: u32 format     (else legacyFormat)
    blob vertices              interleaved, stride from the format
    blob indices               triangle list, u16 or u32 (flags & 1)
    if V >= 21: u8 has; [u32; blob 12·vertexCount]   (one file; a second position set [I])
                u8 has; [blob 16·boneCount]         (zero in the library [?])
    if V >= 23: u32 n; n × { u64 id; cstr name; u32 flags; u32 nA, listA[nA]; u32 nB, listB[nB] }  (groups [?])
```

- **Bounds:** the model's AABB is the union of the meshes' (0x1402617c0); with none (V < 17) it is ±131072, so nothing is culled.
- **Vertex format:** 26 bits. Attributes are **interleaved in table order, not bit order** (input layout 0x1400d81a3; tables at 0x140484a20 mask, 0x1404849b0 size, 0x140484a90 name, 0x140482af0 D3D element):

| # | bit | bytes | attribute | type |
|---|---|---|---|---|
| 0 | 0x1 | 12 | `a_Position` | float3 |
| 1 | 0x10000 | 16 | `a_PositionVec4` | float4; w is the morph index. Selects `MORPHING` on puppets |
| 2 | 0x2000000 | 12 | `a_PositionC1` | float3 |
| 3 | 0x2 | 12 | `a_Normal` | float3 |
| 4 | 0x4 | 16 | `a_Tangent4` | float4 (xyz, handedness w) |
| 5 | 0x800000 | 16 | `a_BlendIndices` | **uint4** (R32G32B32A32_UINT) |
| 6 | 0x1000000 | 16 | `a_BlendWeights` | float4 |
| 7–9 | 0x8 / 0x10 / 0x20 | 8/12/16 | `a_TexCoord`, `a_TexCoordVec3`, `a_TexCoordVec4` | float2/3/4 |
| 10–24 | 0x40 … 0x400000 | 8/12/16 | the same for `C1` … `C5` | |
| 25 | 0x8000 | 16 | `a_Color` | float4, always last |

- **Formats in the library** (from the sweep):

| Format | Attributes | Stride | Meshes |
|---|---|---|---|
| `0xf` | position, normal, tangent4, uv | 48 | 73 |
| `0x180000f` | position, normal, tangent4, blend indices, blend weights, uv | 80 | 52 |
| `0x1800009` | position, blend indices, blend weights, uv | 52 | 25 (the MDLV0013 puppets) |
| `0x9` | position, uv | 20 | 20 |
| `0xb` | position, normal, uv | 32 | 10 |
| `0x27` | position, normal, tangent4, uvVec4 | 56 | 6 |

- **Skinning data** is per vertex: four `u32` bone indices and four `f32` weights. In the library the weights sum to 1 and every index with a weight is below the bone count.

### 1.3 `MDLS`: the skeleton (versions 1–4)

```
u32 boneCount NB  (≤ 128)
bone[NB]: cstr name; u32 flags; u32 parent (0xFFFFFFFF = root; parents come first);
          capped(64) localBindMatrix (row-vector mat4, translation in 12..14); cstr propsJSON
if S >= 2: links, optional bind matrices, constraints, u32-keyed maps, IK sets,
           an optional per-bone {vec3, mat4} block, an optional per-bone u32 array
if S >= 3: one more optional per-bone u32 array
if S >= 4: constraint flags (two floats when flags & 2)
```

- A bone's world bind matrix is `local · world(parent)` in WE's row-vector order [I, consistent in the data].
- The props JSON carries IK and bone-physics keys (`ik`, `ikce`, `se`, `re`, `ge`, `gd`, `m`, `tf`, `lamin`, `lamax`, `rax`… parsed at 0x140265c30). They drive `applyBonePhysicsImpulse` and IK, which no library file uses (links, constraints and IK sets are empty in every file).
- Bone flag 0x2: the bone's constraints hang on its link, and MDLA disables its track unless it is in an IK set. Bone flag 0x1 is set on 520 of 568 bones [?].

### 1.4 `MDLA`: animations (versions 1, 5 and 6 in the library; the code reads 1–6)

```
i32 animCount
anim: u64 id; cstr name; cstr mode ("loop" | "mirror" | "single"); f32 fps; u32 frames F; u32 flags;
      i32 trackCount (= NB)
      boneTrack[NB]: u32 trackFlags (bit 0 = disabled: keep the bind pose); blob 36·(F+1)
      A >= 2: link tracks (36 B/frame) and constraint tracks (4 B/frame)
      A >= 3: two lists of scalar tracks;   A >= 4: per-mesh morph-weight tracks
      A >= 5: f32[6] animated AABB;         A >= 6: a third scalar-track list
      if flags & 1: u16 referenceAnim (< this one); 4 × u32 [?]   (relative to another clip [I])
      i32 eventCount; eventCount × { f32 frame; cstr name }
```

- **Samples:** F+1 frames of 9 floats: position xyz, **Euler xyz in radians**, scale xyz. At load they become a quaternion `q = qz·qy·qx` (R = Rz·Ry·Rx, X first), stored SoA, 10 floats per bone. The data confirms the order: frame-0 Euler z equals the bind matrix's `atan2(m01, m00)` for every bone.
- **Playback:** duration = F / fps. "mirror" ping-pongs, "single" plays once, anything else loops (0x1401a8c71). Position and scale are lerped between frames; rotation is **nlerped** along the shorter arc (0x1401f9020), not slerped. Scalar tracks are lerped (0x140178e00).
- **In the library:** 80 animations in 40 files; 73 loop, 6 mirror, 1 single; fps 30 (69), 60 (5), 15 (3), 24, 7.25, 6; 1 to 450 frames; one clip has events.

### 1.5 `MDAT`, `MDMP`, `MDLE`

- **`MDAT0001`: attachments** (1 file). `u16 n`, then `{u16 bone; cstr name; mat4 offset}`. A scene object's `attachment` key names one (§2.6). Example: bone 24, "правая рука" ("right hand").
- **`MDMP0001`: morph targets / blend shapes.** No library file has one; the layout comes from the reader and the writer. Per mesh: `u16 targetCount`; `f32` (→ `g_MorphWeights[0]`) and `u32 vertexCount`; per target `u64 id`, `cstr name`, and a 6-byte-per-vertex blob of half-float position deltas [I]. Flags 0x400/0x800/0x1000 add normal, tangent and a 16-bit per-vertex blob; flag 0x2000 adds the modifier `{bone, mode, startDistance, endDistance}` (the writer's `modifierbone` … keys, `MORPHING_MODIFIERS`).
- **`MDLE0002`: a reference pose** (1 file). One local mat4 per bone: 40 of the 65 equal the bind pose, the rest differ. The writer calls it `referencepose` [I: its consumer wasn't traced].

### 1.6 Versions

| MDLV | Adds | Files | Users |
|---|---|---|---|
| 4 | mesh flags; no sections | 8 | dna_fragment (4); audiophile (4, unreferenced) |
| 13 | the section loop | 27 | 25 puppets (MDLS1 + MDLA1): 2542737668 (21), 2804817823 (2), 2321732083, 2515150033; 2 static in 2350874185 |
| 14 | — | 15 | the default projects arsenal, demon_core, fantasticcar, neon_sunset, retro, ricepod, techno |
| 16 | per-mesh format | 1 | 3455121165 |
| 17 | per-mesh AABB | 1 | unreferenced |
| 19 | — | 1 | 3233200129 (MDLS2 + MDLA5: the SAS shuffle, 35 bones) |
| 21 | the two optional blobs | 26 | 3159348391 (20; 8 skinned with MDLS3 + MDLA6, up to 115 bones), 3378346807 (5), 2321732083's samurai puppet |
| 23 | groups | 43 | 3384390033, 3453730450, 3455121165, 3657770939, 3734636606; puppets in 3802767544, 3803042537, 3803167460 (MDLS4 + MDLA6; one with MDAT and MDLE) |

- **Sections:** MDLS versions 1 (25), 2 (1), 3 (10), 4 (4); MDLA 1 (25), 5 (1), 6 (14); MDAT 1; MDLE 1; MDMP 0.
- **Bones:** 2 to 115 per skeleton (WE's limit 128).
- **Indices:** 4 meshes use u32 indices (all have more than 65 535 vertices).

## 2. WE's 3D runtime

### 2.1 Orthographic or perspective

- **A scene is perspective by default** (scene flags start at 0x26, ortho bit clear; 0x140186d1f). `general.orthogonalprojection` is examined only when it is a JSON object (0x140187502):
  - `null`, missing, or any other value → perspective. The default projects arsenal, demon_core, dna_fragment and fantasticcar omit the key and are perspective.
  - `{"width": w, "height": h}` → orthographic only if both are non-zero (0x1401875d5).
  - `{"auto": true}` → orthographic, sized from the first image object, which is centred (0x14018b2c0).
- **`general` camera fields** (property table 0x140199780; defaults from the constructor, 0x140186d13):

| Key | Default | Notes |
|---|---|---|
| `fov` | 50 | vertical, degrees |
| `perspectiveoverridefov` | 95 | the fov of `perspective` layers in ortho scenes |
| `nearz` / `farz` | 0.1 / 10000 | perspective only; ortho is always z −2000…2000 |
| `zoom` | 1 | **ortho only** (0x14017fd50); it does nothing in perspective [I] |
| `camerafade` | on | fades each scene camera path in and out |
| `camerashake` | off | speed, amplitude, roughness |
| `cameraparallax` | off | **ortho only**: no parallax in 3D (0x14018af5d) |
| `transparentsorting` | off | opaque first, then translucent back to front (§2.4) |
| `customsortorder` | off | sort by each object's `sortorder` |

- **Effective fov** (0x1401892a0): `fov` in a perspective scene, `perspectiveoverridefov` in an ortho one; a camera layer or its path replaces it; clamped to [0.1, 179.9].

### 2.2 Projection and view

- **Projection** (0x140183a70; builder 0x14009a370): fovY = fov·π/180, aspect = render-target width/height, near/far from `general`. The matrix, row-vector (the same memory as glm column-major):

  ```
  [cot/aspect 0 0 0; 0 cot 0 0; 0 0 n/(f−n) −1; 0 0 n·f/(f−n) 0]
  ```

  That is **right-handed** (the camera looks down −Z) and **reversed-Z**: depth 1 at near, 0 at far. Ortho (0x14009a630) is reversed too.
- **View** (0x1401891a0, lookAt 0x14019d920): `lookAtRH(eye, center, up)`. The eye is at ctx+0x68 (`g_EyePosition`), the forward at ctx+0x160. The eye, centre and up come from, in priority order:
  1. **The active camera layer** (§2.3).
  2. **The scene's `camera` block** `{eye, center, up}`; defaults eye (2, 2, 2), centre 0, up +Y. An ortho scene without paths forces eye (0,0,0) looking down −Z, then moves the eye to (w/2, h/2, 2000).
  3. **Scene camera paths** (`camera.paths`, a list of files; loader 0x140198e20). Each file is `{"paths":[{"disabled"?, "duration", "transforms":[{eye, center, up, zoom = 1, timestamp}]}]}`; a missing timestamp is i/(n−1)·duration. Between keys, per component: `p0 + (p1−p0)·(0.5t + 1.5t² − t³)` (Hermite with both tangents (p1−p0)/2). Paths play **in order and loop**. With `camerafade` each path fades to black over its first and last 0.5 s, `alpha = 1 − 2·min(t, duration − t)`, through `materials/util/fade.json` (0x140180c1a).
- **Camera shake** (0x140199580): phase = speed²·time; d = (cos p, sin 1.333p, sin p), shaped by roughness³ (d/|d|·|d|^q when 0.001 < q < 1); eye and centre both move by d·amplitude·0.1. In ortho it is h·0.01·amplitude with z = 0.

### 2.3 Camera layers and object transforms

Every modern 3D scene in the library drives its camera through **camera layers**: scene objects like

```json
{"camera": "default", "fov": 31.14, "zoom": 1.0, "origin": "0 1.4 4", "angles": "-0.384 0 0",
 "path": "scripts/camera_paths_203.json", "queuemode": "random",
 "visible": {"user": {"condition": "0", "name": "camerastyle"}}}
```

- **Recognised** by a string `camera` value (dispatcher 0x14019065e). Defaults fov 50, zoom 1.
- **Active:** the **last** camera layer in scene order that is visible, with its `visible` condition true (0x140189220). PaRappa (3159348391) has 8 and picks one with its `camerastyle` combo property.
- **View:** eye = the layer's world translation; it looks down its local **−Z** with +Y up; parents apply. fov and zoom are the layer's (or its path's).
- **Path files:** `{"paths":[{options, events, eye, center, up, zoom, fov}]}` where each channel is a timeline in the property-animation format (the `c0…` keyframes of [`timeline-plan.md`](timeline-plan.md)), sampled with linear interpolation between frames (0x1401f2030, 0x1401f2ad0). `queuemode` is "random" (a shuffle bag [I]) or "sequential". Missing channels default from the transform: eye = translation, centre = eye − 5·forward, up = the Y row. The result is **written back into the layer**: `origin` = eye, `angles` from `lookAt(eye, center, up)` (0x1401f31f2 → 0x1401dd630). Perspective scenes animate fov, ortho scenes zoom. Every library camera-layer path file is `{"paths": []}` except 3159348391's `camera_paths_203.json`.
- **Library:** 15 camera layers in 7 scenes: 3159348391 (8), 3453730450 (2), 3233200129, 3378346807 (fov bound to a user property), 3455121165, 3657770939, 3734636606 (angles scripted).
- **Object transforms** (0x1401dd630): `angles` are **radians in every scene**; R = Rz·Ry·Rx, stored with the basis vectors as rows:
  - row0 = (cy·cz, cy·sz, −sy)
  - row1 = (sx·sy·cz − cx·sz, sx·sy·sz + cx·cz, sx·cy)
  - row2 = (cx·sy·cz + sx·sz, cx·sy·sz − sx·cz, cx·cy)

  `origin` is in world units (pixels in 2D, scene units in 3D) and `scale` is per axis. **The editor shows degrees and the file stores radians; SceneScript's `angles` are degrees** (the camera-sync script in 3734636606 multiplies `layer.angles` by π/180 and rebuilds the same Rz·Ry·Rx, forward = R·(0, 0, −1)). Our 2D hierarchy already builds these rows for `angles.x/y` in ortho scenes (`SceneAffineTransform.rotation`), and an orthographic projection of this 3D matrix is exactly its cos-squash.
- **Script camera:** the scene camera (`thisScene.getCameraTransforms`/`setCameraTransforms`) and the camera layer are separate objects: the community script in 3734636606 copies the layer's transform into the scene camera each frame so ray casts see it. How the two map onto the fields above wasn't traced [?].

### 2.4 Depth, render state and draw order

- **Depth is reversed-Z everywhere:** depth-stencil states compare GREATER (0x140099050), the clear value is 0 (0x14009b130), both projections are reversed, and the shaders get the `REVERSEDEPTH` engine combo.
- **Depth formats** (table 0x1400d2a20): the main frame buffer and `_rt_Reflection` have D16, the MSAA frame buffer D32F, the shadow atlas and volumetrics R32 with a D32F view. For Metal, use `depth32Float` everywhere (reversed, clear 0, compare `.greater`).
- **States:** test+write, test only, off. Rasterizer: cull back, front or none; FrontCounterClockwise false (the D3D default).
- **Pass state** (material pass bytes, 0x1401577e0; the pass constructor zeroes them, 0x140151680), so the **engine defaults are depth test on, depth write on, back-face culling, normal blending**:

| Key | Values |
|---|---|
| `blending` | normal 0, translucent 1, additive 2, alphatocoverage 3 |
| `alphawriting` | default, enabled, disabled |
| `depthtest` | enabled 0, disabled 1 |
| `depthwrite` | enabled 0, disabled 1 |
| `cullmode` | normal 0 (back), nocull 1 |

  2D materials author depth test and write off and `nocull`; 64 shipped materials disable depth test and 7 enable it (`solidlayer_depthtest`, `composelayer_depthtest`, …). An image layer's generated material copies its material's first-pass `depthtest`/`depthwrite` (0x140206dba). Text objects in 3D scenes author `depthtest` per object (114 in the library).
- **Library materials of models:** 91 `generic4` passes (every workshop 3D scene), `genericimage2`/`genericimage4` (puppets), `generic`/`generic2` and project-local shaders in the default projects (`car`, `technoorbit`, `ricepod`, `skybox`, `grid`, …). Blending: normal 60, translucent 21, alphatocoverage 7, additive 17. Depth test+write enabled 80, disabled 15. Cull normal 76, `nocull` 18.
- **Draw order** (object loop 0x14018aac0; pass 0 main, 1 planar reflection, 2 shadow casters):
  1. **Default: plain `scene.json` order**, no split and no sort. Every ortho scene gets this. But 6 of the 3D scenes author `transparentsorting` (3233200129, 3378346807, 3453730450, 3455121165, 3657770939, 3734636606), so mode 3 is the common case in 3D.
  2. `customsortorder` alone: a stable sort by each object's `sortorder` int, ascending.
  3. `transparentsorting` in a perspective scene: every non-translucent object first, in list order; then the translucent ones sorted by `dot(object origin, camera forward)` **descending** (back to front; 0x1401865c0). The key is the object's own `origin`, not its world position [I].
  - **Translucent** (object flag 0x100): particles, lights, text, images whose first pass blends translucent or additive, and models unless their mesh blending is normal or alphatocoverage (those get the opaque flag 0x400 instead).
- **2D layers in a perspective scene** are ordinary objects: model matrix = the world transform (origin, radians, scale, parents) times the scene's view-projection. There is no special placement: a text's quad is its `size` in world units, so authors scale them down (PaRappa's texts have `scale` 0.003; 3455121165's rings are images laid flat with `angles.x` = π/2). `depthtest` on the object or its material decides whether models hide them.
- **`perspective: true`** (object flag 0x80) is for **ortho** scenes (0x1401e5b60): the layer is drawn through a temporary perspective camera, fov = `perspectiveoverridefov` [I], near 5, far max(15000, d + 1000), placed at d = (h/2)/tan(fov/2) so the z = 0 plane matches the ortho framing; rotated layers then foreshorten. Particle systems have the same flag.

### 2.5 The captures

| Item | What WE shows | What it tests |
|---|---|---|
| 3455121165 Solar system | planets and the sun (models), orbit rings (flat images) and the clock text, all in perspective on black; shadows and volumetrics high add +0.2 only | camera layer, 2D in perspective, `generic4` lighting |
| 3159348391 PaRappa | a dojo, skinned characters (up to 115 bones) animating, the clock text on the wall; the camera animates, so the two settings' frames differ | skinning, animation layers with animated `blend`, camera layers, 2D text in 3D |
| 3378346807 3D Snowflakes | the clear colour (65, 80, 83), snowflake models; at high a light shaft, glowing flakes and cast shadows (+56.8 mean) | clear colour, point shadows (2 shadowed points), volumetrics in 3D |
| 3657770939 WE_Phys α_01 | spheres and boxes lit purple by 4 points (3 shadowed), HDR bloom | lighting, point shadows, HDR, scripted physics |
| 3734636606 More Physics | a floor, a car, boxes and ~400 spheres under a directional light with shadows, sky | directional cascades, many models, scripted camera layer |
| 2515150033 Knight, 2321732083 Samurai | lit puppets | puppet mesh, skinning in 2D, prelighting |

The two physics scenes run rigid-body physics in SceneScript (cannon-es and oimo, inlined); WE has no engine physics for them. They need the script runtime to write model transforms, which it already does for layers.

### 2.6 Model objects in `scene.json`

The object dispatcher (0x14018ff60) makes a model object when `model` is a string (a `.mdl` path), a number (the id of an already loaded model) or an object. Keys (most through the generic property loader, so animatable and user-bindable as on other objects):

| Key | Default | Notes |
|---|---|---|
| `model` | — | `.mdl` path |
| `origin`, `scale`, `angles` | 0, 1, 0 | angles in radians |
| `parent` | — | also accepts a bone attachment through `attachment` |
| `attachment` | −1 | an exact name in the parent model's MDAT list; world = parentWorld · boneWorld[bone] · attachMatrix · local (0x1401dd7d0, 0x140224970), resolved up to 3 levels deep |
| `skin` | 0 | picks `materials[min(skin, M−1)]` for every mesh |
| `visible`, `solid` | true, **true** | |
| `disablepropagation`, `perspective` | false | |
| `castshadow` | **true for models** (the factory sets it, 0x1401901b1) | the library writes `false` on 28 of 254 model objects and omits it on the rest, so **226 models cast shadows** |
| `reflected` | true | membership of the planar reflection list |
| `rootmotion` | true | |
| `sortorder`, `parallaxDepth` | | |
| `animationlayers` | [] | below |

- **Not read:** per-mesh material overrides in `scene.json`, `alpha`, `color`, `brightness` and `instances`. A model's look is entirely its `.mdl` materials.
- **`animationlayers[]`** (0x1402230c0, layer properties 0x14026c980): `animation` (a clip id from MDLA; a missing id makes no layer), `id`, `name`, `visible` (1), `additive` (0), `blendin` (0), `blendout` (0; kept only for "single" clips), `rate` (1, animatable), `blend` (1, animatable), `blendtime` (0.5). The clip's mode, fps and frame count come from the `.mdl`. Library: 9 model objects (3159348391 ×8, 3233200129) and the puppets. PaRappa animates `blend` with timelines and scripts (`getAnimationLayer(...)` 52 times in its scripts).
- **Draw** (0x1402222a0): cull the model's bounding sphere against the frustum (6 planes per view in the shadow pass), upload the bones, then per mesh: morph uniforms, bind the material (per-mesh pass state), draw.

### 2.7 Model shaders and vertex attributes

- **`generic4`** (and `generic3`, `foliage4`, `fur4`, `chroma4` through `base/model_vertex_v1.h`): attributes `a_Position`, `a_Normal`, `a_TexCoord`, with `SKINNING` `a_BlendIndices` (uint4) and `a_BlendWeights`, with `NORMALMAP` `a_Tangent4`; `MORPHING` reads `gl_VertexID`.
  - Uniforms: `g_ModelMatrix`, `g_NormalModelMatrix`, `g_ViewProjectionMatrix`, `g_EyePosition`, `g_LightAmbientColor`, `g_LightSkylightColor` (the vertex mixes them by `dot(normal, up)`), `g_Bones`, `g_MorphOffsets`, `g_MorphWeights`, `g_Texture5` "morph".
  - Fragment combos: `LIGHTING` (default **1**), `FOG` (1), `REFLECTION` (0), `RIMLIGHTING`, `SHADINGGRADIENT` (`g_Texture4` toon gradient), `TINTMASKALPHA`; the engine's `LIGHTS_*`, `LIGHTS_SHADOW_MAPPING*`, `LIGHTS_COOKIE`, `HDR` and `REVERSEDEPTH`. Textures: `g_Texture0` albedo, `1` normal map, `2` PBR mask, `3` `_rt_MipMappedFrameBuffer`, `6` `_rt_shadowAtlas` (a **comparison sampler**), `7` `_alias_lightCookie`.
- **`foliage4`** (`LEAVESUVMODE`, `DOUBLESIDEDLIGHTING`, `FOLIAGEDEBUG`) and **`fur4`** (`INSTANCECOUNT` 5/9/13/21 shells, `gl_InstanceID`, `g_Texture8` fur) name their own shadow casters with `// [PASS] shadow shadowcasterfoliage4` / `shadowcasterfur4`. No library model uses them today.
- **`flag`** and **`generic2`**: `generic2.frag` samples `_rt_Reflection` (§2.10).
- **Engine combos on models** (0x140224c70): `SKINNING` when the mesh has `a_BlendIndices`; `BONECOUNT` = `min(nextPow2(max(bones, 16)), 128)`, so 16, 32, 64 or 128; `MORPHING` when the mesh has morph targets; `MORPHING_NORMALS` from mesh flag 0x400. Puppets differ (§2.12).
- **Vertex buffers:** one interleaved buffer per mesh in the table order of §1.2. In Metal the vertex descriptor comes from the format bits, and each shader's inputs are matched by name (`a_*`) to the descriptor's attributes; an input the mesh lacks gets a constant default [I: WE's input layout simply omits it; check what the translated shader expects].

### 2.8 Skinning and animation layers

- **Bones:** `cbuffer g_bufAnimation { float4x3 g_Bones[BONECOUNT]; }` (HLSL generator 0x1400f7e80), BONECOUNT × 48 bytes. Entry i = `boneWorld[i] · inverseBind[i]` in model space (0x1402220a0); inverseBind is the inverse of the bind-pose chain (0x14021b46f). GLSL: `mat4x3 g_Bones[BONECOUNT]`, `localPos = mul(vec4(p, 1), Σ wᵢ·g_Bones[iᵢ])`, and the same 3×3 for normals and tangents.
- **Evaluation** (0x14021c480; only while visible), per visible layer in order:
  1. time += dt·rate; frames and fraction from the clip's mode.
  2. weight w = blend × min(t / min(duration/2, blendtime), 1) with `blendin` × min((duration − t) / min(duration/2, blendtime), 1) with `blendout` (0x14026c8b0).
  3. Sample every enabled bone track (T and S lerped, Q nlerped).
  4. Apply: w = 1 replaces (0x1401f89a0); 0 < w < 1 nlerps from the current pose (0x1401f9020); additive composes the delta from the bind pose, scaled by w (0x1401f9820) [I: exact composition]; w = 0 is skipped.
  - The pose starts from the bind pose each frame; disabled tracks keep it.
  - Morph-weight tracks: replace lerps, blend mixes and clamps, additive ≈ max(out, v·w) [I].
- **Root motion** (0x140225900): while `rootmotion` is on and the clip's flags 0x1f800 are set, origin += world3×3 · rootDelta · w · Π(1 − w of the later non-additive layers), and the yaw delta is added to `angles` [?: which flag bit is which axis]. A finished single clip destroys its layer [I].
- **Script API** (bindings 0x140227814 on models; 0x140211327 on images): `getAnimationLayer(name|index)`, `getAnimationLayerCount`, `createAnimationLayer`, `playSingleAnimation`, `destroyAnimationLayer` on both; on images (puppets) also the bone API (`getBoneCount`, `get/setBoneTransform`, `get/setLocalBone{Transform,Angles,Origin}`, `getBoneIndex`, `getBoneParentIndex`, `applyBonePhysicsImpulse`, `resetBonePhysicsSimulation`) and blend shapes (`getBlendShapeIndex`, `get/setBlendShapeWeight`). Attachments on every layer (`getAttachmentIndex/Matrix/Origin/Angles`, 0x1401e0ec2). Ours are stubs in `Resources/SceneScript/objects-layers.js`.

### 2.9 Morph targets

- `uint g_MorphOffsets[12]`: [0] = the count, [1 + k] = target k × vertexCount. `float g_MorphWeights[12]`: [0] = the mesh's MDMP float, [1 + k] = weight k. **At most 11 active targets**: the first 11 in index order, sorted by weight, descending.
- Deltas live in `g_Texture5` "morph": RGBA16F, square, side `ceil(sqrt(ceil(T·V·3·(normals ? 2 : 1) / 4)))`, half floats packed 3 (or 6 with normals) per vertex across texels (0x1401d7760). The shader's pixel y is `index / Resolution.y` (not `.x`), which only works because the texture is square; keep it square.
- No library model has MDMP, and no library puppet uses `a_PositionVec4`. This is code-only today.

### 2.10 Shadows (lighting-plan D2)

This corrects lighting-plan §2.7 where noted.

- **When:** every frame inside the light packer (0x140190c80, called at 0x14018031a), after the camera update and before the reflection and main passes. For each batch of up to 6 views (0x140196530):
  1. turn depth bias on and bind `_rt_shadowAtlas`;
  2. clear depth to 0 on the frame's first batch;
  3. set a viewport array (one rect per view) and select the "shadow" material variant;
  4. draw the casters instanced × views: `shadowcaster.vert` reads `g_ViewportViewProjectionMatrices[gl_InstanceID]` and writes `gl_ViewportIndex` (Metal: `[[viewport_array_index]]`, or one draw per view);
  5. cull each caster against the view's 6 planes (pass 2 of the object loop).
- **Casters:** visible objects with `castshadow` **and** the opaque flag (models whose mesh blending is normal or alphatocoverage). Only those meshes draw.
- **Caster material** (variant at material+0x300): the shader is the source shader's `// [PASS] shadow <name>` (header parser 0x14016de11), else `shadowcaster`; every combo the caster declares takes the source material's value; `ALPHATOCOVERAGE=1` with A2C blending when the source blending is **alphatocoverage** (lighting-plan said translucent). States from `materials/util/shadowcaster.json`; the source's cull mode isn't inherited. Textures (albedo for A2C, the morph texture) are copied from the source on every bind.
- **Bias:** slope-scaled depth bias **−4.0**, constant 0, clamp 0. Quirk: the biased back-cull state was created with cull NONE, so casters render **two-sided**. The render matrices (not the shader's) also get an extra bias: spot and cascade `VP[3][2] −= 0.0005`, point `P[3][2] −= 0.00333`.
- **Atlas** (0x1401938d1): depth-only R32 (D32F view, R32F sampling). A shelf packer, shelves 8192 wide; maps sorted by (isPoint ≪ 15) + size, descending; the atlas is max(2, extent) in each direction, not a power of two, only grows, and keeps its layout while sizes don't change. Map size per light: 256 at quality 1–2, 512 at 3, 1024 at 4; a directional light takes 3 (its cascades).
- **Sampler** (0x140099980): comparison, linear, border (0,0,0,0), compare **GREATER**. Filtering is 1 tap at quality 1, else 9-tap PCF (`common_pbr_2.h`).
- **Spot:** perspective, fov 2·outer cone, near 0.05, far max(radius, 0.06).
- **Point:** perspective, aspect 1, fov 94/92/91.2° (quality 1–2/3/4), near max(0.05, `lightsourcesize`) (1 in ortho), far max(radius, near + 0.01). Six faces of (size/2)×(size/3) in a size×size cell, 2 columns × 3 rows, face k at (k % 2, k / 2), order +X, −X, +Y, −Y, +Z, −Z (the bases of `CalculateProjectedCoordsPoint`).
- **Directional cascades:** the pairs are (box size b, depth range d) (lighting-plan had them as distance and size): (c0, 4c1), (c1, 4c1), (c2, max(1.5c2, 4c1)), from `cascadedistance0..2` (defaults 3, 10, 100). Per cascade: F′ = F − 0.5(F·L)L; centre = eye + F′·b/2 (z = 0 in ortho), snapped to texels along the light's rows 1 and 2; view = the rigid inverse of (row2, row1, −row0, centre); ortho x, y ∈ ±b/2, z ∈ ±d/2, reversed. The shader takes the first cascade with |xy| < 0.99. WE's cascade-base quirk (lighting-plan §2.1) still applies.
- **Uniforms:** `g_LFeature_ShadowProjection[i]` = the unbiased light view-projection; `…ShadowProjectionTransform[i]` = (x/W, y/H, s/W, s/H) (the shader does `xy·(0.5, −0.5) + 0.5`, then `·zw + xy`); `g_LFeature_ShadowPointProjection` = (P22, P32, P23, P33); `g_Texture6Texel` = (1/W, 1/H, W, H) of the atlas.
- **Library:** shadow budgets in 3159348391 (a directional), 3378346807 (2 points), 3455121165 (a point and a spot), 3657770939 (3 points), 3734636606 (a directional), and 3233200129's cookie spot. The captures show shadows only in 3378346807 and (by eye) 3734636606.

### 2.11 Planar reflection `_rt_Reflection` (lighting-plan C2)

- **Trigger:** any material that binds a texture named `_rt_Reflection` (only `generic2`'s `g_Texture2` does). Its object gets feature 0x8 and the scene a flag; the target is made at load at the render size (RGBA8 or the frame format, with depth).
- **Pass** (0x140180357–0x1401808ff), before the main pass, only with the user's `reflection` setting on (otherwise the target is cleared once): view' = view · diag(1, −1, 1, 1), a mirror across the **world plane y = 0** with no height offset and no per-object plane; the eye and basis are mirrored; culling is flipped; clear to the clear colour and depth 0; draw the **reflected list**: objects with `reflected` (default true) that aren't reflective themselves. **There is no clip plane**, so geometry below y = 0 lands in the reflection too.
- **Sampling** (`generic2.frag`): uv = clip xy/w·0.5 + 0.5 from `g_ViewProjectionMatrix` (no y flip in D3D; flip in Metal if the target is y-down [I]); `albedo.rgb += tex(g_Texture2, uv + normal.xy·0.01).rgb · 0.35`.
- **Library:** 2350874185 (Razer; its dome is `generic2`, `reflected` on 3 objects) and the default projects arsenal and fantasticcar.

### 2.12 Particles

- **`collisionmodel`** (0x1401cfd98): `bouncefactor` (0.5) and `collisionbehavior` (bounce, slide, stop, delete). The model isn't a path: the particle object's `dependencies` array links it, `{"id": <object id>, "type": "collisionmodel", "index": n}` (n = the ordinal among the system's collisionmodel operators; 0x14022af30, bound at 0x14022cfa0). The target may be a model or a puppet image.
  - **Shape: capsules, not triangles** (0x1401d4580): one per bone, fitted to the bone's extent (axis = the largest component, radius = the second, half-length = their difference; 0x1401d5880), following the animated bone; a model without bones gets one capsule from its AABB. Built in world space once per frame per target.
  - The particle is a point (its size is ignored); the last hit wins. Responses as for the other collision operators. Above 8192 particles the work spreads over frames.
  - **No library particle system uses it.**
- **Renderers:** only `sprite`, `spritetrail`, `rope` and `ropetrail`; **none draws a model per particle.**
- **In 3D:** one vertex buffer per system through the system's model matrix. Billboards take `g_OrientationRight/Up/Forward` from the camera (0x1402298b0: screen mode F = −camera forward, U = object Y or camera up; upright turns only about the axis; fixed uses the axis basis); trails use `g_EyePosition`. Depth state from the particle material (the halo: test on, write off). No per-particle sort.

### 2.13 Puppet warp (area 7)

- An image whose model JSON has `"puppet": "<file>.mdl"` loads it at 0x1401fbb81 and makes a "morph_<n>" RGBA16F texture (3 position deltas + alpha).
- **The image's `animationlayers`** (0x1401fc192 → 0x1401fcc20) use the same parser, keys, weights and sampling as models; the update is 0x1401fdf90.
- **Material overrides** on its genericimage2/3/4 material (0x140207100): `SKINNING=1`; `BONECOUNT` = **the exact bone count** (not rounded); `SKINNING_ALPHA` with mesh flag 0x4 (`g_BonesAlpha`); `MORPHING` when the mesh has `a_PositionVec4` (w = morph index); `MORPHING_MODIFIERS` with flag 0x2000 (`g_MorphBoneTransform[11]`, `g_MorphBoneRules[11]`); cull `nocull` or normal. Uniforms `g_Bones`, `g_BonesAlpha`, `g_BlendMap` (0x140206430): **2D skinning in pixel space.**
- **Drawing** (0x140207740): the skinned mesh replaces the quad **inside an image-sized offscreen target** (`_rt_imageLayerAlbedo_<id>`), cleared to 0, identity model and view, ortho over the texture's pixels (z ±1000, y flipped by a context bit). A first auxiliary draw into it is unidentified [?]. The layer's quad and effect chain (and lighting-plan's prelighting path) then sample that target, which is why the Knight is lit as a flat layer.
- **Library:** 32 puppet layers in 7 scenes: 2542737668 (22), 3803167460 (3), 2804817823 (2), 2321732083 (2), 2515150033, 3802767544, 3803042537.

## 3. Where we stand

Code references are to `OpenWallpaperEngine/Scene/…`.

| Feature | WE semantics (§) | Our status | Library users |
|---|---|---|---|
| `.mdl` parsing | 1 | ❌ none. `SceneScriptSceneDescriber` only notes that `model` ends in `.mdl` | 122 files, 26 items |
| Model objects | 2.6 | 🟡 decoded (`WESceneObject.model`, `animationLayers`, `renderValues`; M0) and collected in `SceneMetalContent.spatial.models`, logged, not drawn | 254 objects, 16 scenes |
| Perspective or ortho | 2.1 | 🟡 `SceneCamera(scene:)` treats a nil `orthogonalprojection` as perspective, but `metalSceneSize` sizes a scene with a **missing** key from its images' bounds; `{"auto":true}` and zero sizes aren't handled | 10 `null` + 4 missing |
| Perspective projection | 2.2 | 🟡 `Rendering/SceneCamera.swift` exists but only the volumetrics use it (`SceneVolumetricsCamera`). Its defaults differ from WE's (near 0.01 vs 0.1, eye (0,0,1) vs (2,2,2)), it divides fov by `zoom` (WE: zoom does nothing in perspective), and its depth runs 0 near → 1 far, not reversed | every 3D scene |
| Camera layers | 2.3 | 🟡 decoded with their path files (M0, `spatial.cameraLayers`); the camera never moves | 15 layers, 7 scenes |
| Scene camera paths, `camerafade` | 2.2 | 🟡 decoded (M0, `spatial.cameraPaths`, `spatial.camera.cameraFade`); not played | 7 scenes (6 default projects, 2350874185) |
| 3D transform hierarchy | 2.3 | 🟡 a 2D affine hierarchy; `angles.x/y` squash in ortho (right for ortho); no `origin.z`, `scale.z` or 4×4 world matrices | every 3D scene |
| Depth buffer | 2.4 | ❌ the scene pass has only a colour attachment (`SceneMetalRenderer` "sceneRenderPass"); only the volumetrics have depth | every 3D scene; 114 `depthtest` texts |
| Draw order (`transparentsorting`, `customsortorder`) | 2.4 | 🟡 scene.json order (right for ortho scenes); the sorts aren't decoded | `transparentsorting`: 6 of the 3D scenes |
| 2D layers in perspective scenes | 2.4 | ❌ drawn in pixel space, so they land in the top-left corner or off screen (we-reference-report: 3455121165's clock and rings missing, 3378346807's clock a white strip) | 10 perspective scenes |
| `perspective: true` in ortho | 2.4 | ❌ (test-risks) | 17 objects |
| Model materials (`generic4` …) | 2.7 | ❌ | 91 `generic4` passes + default-project shaders |
| Skinning, animation layers, root motion | 2.8 | ❌; the script API is stubbed | 9 model objects, 32 puppets; PaRappa's scripts |
| Morph targets | 2.9 | ❌ | 0 (code only) |
| Shadows (D2) | 2.10 | ❌; `LightingV1RequireTests.testShadowBudgetsNeedTheShadowAtlas` is an expected failure; shadow-casting volumetric lights wait (LR22) | 6 scenes with shadow budgets; 226 models cast by default |
| Planar `_rt_Reflection` (C2) | 2.11 | ❌ rejected | 2350874185, arsenal, fantasticcar |
| Particles in 3D (camera orientation) | 2.12 | 🟡 `g_Orientation*` from the emitter; the camera is 2D | 3D scenes with particles (3159348391, 3378346807, …) |
| `collisionmodel` | 2.12 | ❌ (roadmap area 2 item 3) | 0 |
| Puppet mesh and skinning | 2.13 | ❌ the atlas is drawn flat (`SceneWallpaperViewModel` logs "Puppet Warp rig found") | 32 layers, 7 scenes |
| Attachments | 2.6 | ❌; script stubs | 1 file (a puppet) |

Tests that pin today's gaps: `WEReferenceComparisonTests` (the five 3D items draw black, the two puppets scattered), `LightingV1RequireTests.testShadowBudgetsNeedTheShadowAtlas`, `ImageMaterialSweepTests` (`_rt_Reflection` rejected), `VolumetricsLibraryTests` (3D volumes without the scene's depth).

## 4. Plan

### 4.1 Principles

- WE's semantics from the binary, not approximations: the reversed-Z depth, the camera-layer rules, WE's draw order (plain `scene.json` order unless the scene sorts, which most 3D scenes do), nlerp rather than slerp, the shadow bias quirks and the cascade quirk.
- Every model material goes through the translator (`ShaderVariantTranslator`), with the engine combos (`SKINNING`, `BONECOUNT`, `MORPHING`, `LIGHTS_*`, `HDR`, `REVERSEDEPTH`) and the uniforms by reflection name. No hand-written model shader. Bump `ShaderVariantTranslator.revision` when translated output changes.
- The orthographic path stays exactly as it is. Everything new is gated on the scene being perspective, having models, or on a flag WE gates it on.
- `mdl.py` is the oracle for parsing and for a CPU skinning reference; the WE captures are the oracle for the frames.

### 4.2 Order and ownership

```
M0 format + seams ─┬─ M2 camera ───────┐
                   ├─ M3 3D transforms ─┼─ M4 depth, draw order, 2D in 3D ─ M5 static models ─ M6 skinning + animation ─┬─ M8 shadows (D2)
M1 .mdl parser ────┤                    │                                                                            ├─ M9 planar reflection (C2)
                   │                    │                                                                            ├─ M10 particles in 3D + collisionmodel
                   └────────────────────┴─ P1 puppet mesh (after M1; skinned after M6) ─ P2 puppet animation + script API ─ M7 morphs
T tester (after M5, again after M8 and P2)   O optimisation (after T)
```

- **Prerequisites first:** M0 and M1 in parallel; then M2 and M3 in parallel; then M4, which makes the 3D scenes' 2D content, depth and camera right before any model draws. After M4 the five 3D captures should show their clocks, rings and texts in place.
- M1 has no rendering dependency, so it can land first and P1 can start on it at once (a puppet in its bind pose).
- Each package owns its files; a file listed under one package is edited by no other. Where two packages need one file, the earlier one adds a seam (a hook, a protocol or an empty slot) that the later one fills in its own file.

### 4.3 Work packages

**M0 — Format and seams (one agent, first, small; no output change). Done; what landed is in §4.4, with two changes to the list below: `usesPerspectiveProjection` stays until M2 moves its callers, and `cascadedistance*` are the light's fields (`SceneLightValueField`), not `general`'s.**
- **Files:** `Scene/Format/SceneObject.swift` (`model`, `camera`, `fov`, `zoom`, `path`, `queuemode`, `animationlayers` as `[WEAnimationLayer]`, `attachment`, `skin`, `sortorder`, `castshadow`, `reflected`, `rootmotion`, `depthtest`, each as `SceneRawValue` where WE binds them); new `Scene/Format/SceneAnimationLayer.swift`; new `Scene/Format/SceneCameraPath.swift` (both path-file formats: the scene's `transforms` and the camera layer's timeline channels, the latter decoded with the existing timeline types); `Scene/Format/SceneDocument.swift` (`perspectiveoverridefov`, `transparentsorting`, `customsortorder`, `cascadedistance*`, and `WESceneGeneral.isPerspective` implementing §2.1 exactly: missing, null, non-object or a zero size → perspective, `auto` → ortho; delete `usesPerspectiveProjection`); `Scene/Format/SceneValueFields.swift`.
- **Seams:** `SceneMetalContent.models` (empty `[SceneModelObject]`), `.cameraLayers`, `.drawOrder` (today's order), and `SceneFrameCamera` (view, projection, eye, forward, reversed depth flag), built once per frame by `SceneMetalRenderer` from a `SceneCameraRig` protocol that returns today's orthographic camera. `BuiltinUniforms` reads the view-projection and eye from `SceneFrameCamera` (for ortho the numbers are today's).
- **Tests:** decode fixtures for a model object (every key, defaults, bindings), a camera layer, both path formats, and `orthogonalprojection` null / missing / `{"auto":true}` / `{"width":0,"height":0}`; a library decode check: 254 model objects, 15 camera layers, 7 scene path lists, 10 + 4 perspective scenes.

**M1 — The `.mdl` parser (one agent; parallel with M0). Done.**
- **Files:** `Scene/Format/Model/`: `MDLModel` (with `MDLMesh`, `MDLVertexFormat` and `MDLVertexAttribute` for the table of §1.2, `MDLSkeleton`, `MDLBone`, `MDLAnimation`, `MDLBonePose`, `MDLAttachment`, `MDLMorphTargets`, `MDLBounds`) and `MDLReader` (every version and section of §1). Strict: an overrun, a wrong blob size or a fast-fail condition throws an `MDLError` for that model, never a crash; the caller logs it. Like WE, it continues at a section's stored end and ignores bytes after the terminating tag. `MDLModel.load(path:package:directory:)` reads from the wallpaper's package, else its folder.
- **Oracle:** `Scripts/mdl-reference.py` (`mdl.py` without numpy, plus the decode as JSON); `Scripts/mdl-fixtures.py` writes the hand-built fixtures.
- **Tests:**
  - `MDLParseTests`: the fixtures of `Tests/Fixtures/Models/` (one model per version and section, every optional block, malformed ones) and WE's vendored editor camera, field for field against `expected.json`; every truncation and random corruption fails cleanly; 129 bones rejected; the attribute table, the model box, q = qz·qy·qx, loading from a package.
  - `MDLLibrarySweepTests`: every library `.mdl` field for field against `library.json` (long arrays as digests); files new or changed since are checked against the script run at test time.

**M2 — The scene camera (one agent, after M0).**
- **Files:** `Rendering/SceneCamera.swift` (rewritten: WE's projection, reversed-Z, `zoom` only in ortho, the defaults of §2.1 and §2.2, fov clamp), new `Rendering/SceneCameraLayers.swift` (the active layer, its view from the world matrix, its path playback with `queuemode`, the write-back of origin and angles), new `Rendering/SceneCameraPaths.swift` (scene paths, the Hermite, sequencing, `camerafade` through `materials/util/fade.json`), `Rendering/SceneCameraShake.swift` (the 3D shake of §2.2), `Rendering/SceneVolumetricLight.swift` (`SceneVolumetricsCamera` takes `SceneFrameCamera`), and the camera part of `Scripting/Host/SceneScriptTableSync.swift` (`getCameraTransforms`/`setCameraTransforms` read and write the scene camera).
- **Reconcile:** the volumetrics assume depth 0 at near; WE's is reversed everywhere (§2.4). Switch them with the rest, verified by `VolumetricsLibraryTests`.
- **Tests:** projection and view against hand-derived matrices (right-handed, reversed: near → 1, far → 0); the active camera layer for PaRappa's `camerastyle` 0…6; a camera layer under a parent; the Hermite against the formula at t = 0, 0.5, 1 and across a path boundary; fade alpha at the ends; the shake phase; `setCameraTransforms` round trip.

**M3 — 3D transforms (one agent, after M0; parallel with M2).**
- **Files:** new `Rendering/SceneTransform3D.swift` (`SceneWorldMatrix`: WE's rows of §2.3, `origin.z`, `scale.z`; a hierarchy that composes them, parents first, and a bone-attachment hook `attachmentWorld(object) -> simd_float4x4?` that M6 fills), `Rendering/SceneObjectMotion.swift` (live 3D values from scripts and timelines).
- The 2D `SceneAffineTransform` stays for ortho scenes; in perspective scenes every drawable takes its model matrix from the 3D hierarchy.
- **Tests:** the rows against `0x1401dd630`'s formula for random angles; the ortho projection of the 3D matrix equals today's `SceneAffineTransform` for every library ortho layer with tilt (so the two paths agree); parent chains; the camera-sync script's forward vector (3734636606) equals −row2.

**M4 — Depth, draw order and 2D layers in perspective scenes (one agent, after M2 and M3).**
- **Files:** `Rendering/SceneMetalRenderer.swift` (a depth attachment on the scene pass, `depth32Float`, cleared to 0, only for perspective scenes and scenes with `depthtest` objects; the draw loop's order modes of §2.4; the model draw seam `SceneModelDrawing` that M5 implements), `Rendering/SceneLayerPipelines.swift` and `Rendering/ImageMaterialRenderer.swift` (pipelines keyed by the depth format; depth-stencil and cull state from the pass bytes, WE's defaults), `Rendering/ParticleMaterialRenderer.swift` (the depth format; orientation from `SceneFrameCamera`), `Rendering/BuiltinUniforms.swift` (`g_ModelViewProjectionMatrix`, `g_ModelMatrix`, `g_ViewProjectionMatrix`, `g_EyePosition` from the 3D path in perspective scenes), and the text draw (text quads through the camera).
- Also: `perspective: true` layers in ortho scenes through the temporary camera of §2.4 (test-risks "perspective" items), and `general.clearcolor` stays as today.
- **Tests:**
  - Unit: a layer quad in a perspective scene lands where `mul(world, VP)` puts it; depth-state and cull-state tables per pass key; `transparentsorting` order (opaque first, then by `dot(origin, forward)` descending) and `customsortorder`.
  - Headless (the reference harness, `OWE_WE_REFERENCE`): 3455121165 (clock and rings in place: the edge alignment of the text and rings against WE's still within a few pixels), 3159348391's wall clock and 3378346807's clock land where WE draws them; the ortho items' metrics don't change (a guard that the ortho path is untouched).

**M5 — Static models (one agent, after M1 and M4).**
- **Files:** new `Scene/Loading/SceneModelBuilder.swift` (model objects → `SceneModelObject`: the `.mdl`, its meshes' materials for `skin`, bounds, flags), new `Scene/Loading/ModelMaterialPlan.swift` (each mesh's material through the translator with the engine combos and pass state; `LIGHTING` with the frame's packed lights, `REFLECTION` with `_rt_MipMappedFrameBuffer`; `FOG` stays 0 as in lighting-plan), new `Rendering/SceneModelRenderer.swift` (vertex and index buffers, the vertex descriptor from the format bits matched to the shader's `a_*` inputs, bounding-sphere frustum culling, the draw per mesh), new `Rendering/ModelMaterialUniforms.swift` (with an empty bones slot).
- Default-project shaders (`car`, `technoorbit`, …) go through the same path; a shader that fails to translate is logged once, as for effects.
- **Tests:**
  - `ModelMaterialSweepTests` (`OWE_LIBRARY`): every library model mesh builds a pipeline (tally failures by reason, like `ImageMaterialSweepTests`).
  - A fixture cube with a known material rendered headlessly: pixel positions of its corners from the camera matrices, depth occlusion between two cubes, back-face culling, `nocull`.
  - Reference harness: 3734636606 and 3657770939 in their bind poses (their models don't animate): whole-frame SSIM and colour against WE, and the worst cells triaged; 3455121165's planets.

**M6 — Skeletons, animation layers and skinning (one agent, after M5).**
- **Files:** new `Rendering/SceneSkeleton.swift` (bind and inverse-bind matrices, the pose, `g_Bones` as `float4x3`), new `Rendering/SceneAnimationLayers.swift` (§2.8: clip time and modes, blend-in/out ramps, replace, nlerp blend, additive, disabled tracks, events), new `Rendering/SceneRootMotion.swift`, `ModelMaterialUniforms.swift`'s bones slot (M5 hands it over), `SceneTransform3D.swift`'s attachment hook (M3 hands it over), and the model half of `Resources/SceneScript/objects-layers.js` with its host bindings (`getAnimationLayer`, `createAnimationLayer`, `playSingleAnimation`, `destroyAnimationLayer`, the layer's `rate`/`blend`/`visible`, `getAttachment*`).
- `BONECOUNT` = `min(nextPow2(max(bones, 16)), 128)` for models; the exact count for puppets (P1).
- **Tests:**
  - **A CPU skinning reference:** `SkinningReference.swift` poses a skeleton and skins vertices on the CPU from WE's rules (Euler → q = qz·qy·qx, lerp/nlerp, world = local·parent, boneWorld·inverseBind, Σ w·M). Fixtures from `mdl.py` (decode) plus a small Python skinning script in `Scripts/` give expected positions for pj.mdl, parappa.mdl (115 bones) and sas@Shuffling.mdl at 3 times. The GPU vertex stage (a transform-feedback-style render into a buffer, or a compute pass using the same function) matches the CPU within 1e-4.
  - Layer maths: ramps at t = 0, blendtime, duration/2; mirror and single modes; additive against a hand-derived pose; a disabled track keeps the bind pose.
  - Reference harness: 3159348391 (PaRappa) against WE's stills, camera animating: compare with WE's clip frames at the matching time (the harness supports multiple stills) and triage the characters' silhouettes; 3233200129 (no capture) renders without NaNs.

**M7 — Morph targets (one agent, after M6; small, code only).**
- **Files:** new `Rendering/SceneMorphTargets.swift` (the square RGBA16F morph texture, the 11 active targets sorted by weight, `g_MorphOffsets`/`g_MorphWeights`), the MDLA morph-weight tracks in `SceneAnimationLayers.swift` (M6 hands it over), and blend-shape script calls.
- **Tests:** a synthetic MDMP fixture (the reader and writer layouts of §1.5): texel packing against the shader's index maths (with normals and without), 12+ targets (only 11 apply), weights animated by a clip.

**M8 — Shadows (lighting-plan D2; one agent, after M5; parallel with M9 and M10).**
- **Files:** new `Rendering/SceneShadowAtlas.swift` (the shelf packer, growth, the map sizes per quality), new `Rendering/SceneShadowPass.swift` (views per light: spot, point faces, directional cascades with the snap and the bias quirks; the caster draw per view with the `[PASS] shadow` variant, two-sided, slope bias −4), `Rendering/SceneLightPacker.swift` (the `g_LFeature_Shadow*` values; lighting owns this file, so coordinate: M8 takes it for this package), `Shaders/ShaderPrelude.swift` (`sampler2DComparison` and `texSample2DCompare` as a Metal `depth2d` + `sample_compare` with compare `.greater`; bump the revision), `Rendering/SceneVolumetrics*.swift` (shadow-casting volumetric lights: LR22).
- **Tests:**
  - `LightingV1RequireTests.testShadowBudgetsNeedTheShadowAtlas` passes (delete its expected failure).
  - The packer against hand-derived rectangles (points before others, shelves, growth); the cascade boxes, snap and matrices against §2.10; the point face layout against `CalculateProjectedCoordsPoint`.
  - A fixture: a cube over a plane lit by a spot, a point and a directional; the shadow's area on the plane against a CPU ray test within a few percent.
  - Reference harness: 3378346807 high against off (WE adds +56.8 mean, centred on (847, 499)) and 3734636606's floor shadows.

**M9 — Planar reflection (lighting-plan C2; one agent, after M5).**
- **Files:** new `Rendering/ScenePlanarReflection.swift` (the target, the mirrored pass of §2.11 without a clip plane, the reflected list), the `_rt_Reflection` binding in `Scene/Loading/SceneEffectPlan.swift`'s `textureInput` and `ModelMaterialPlan.swift` (M5 hands over the one line).
- **Tests:** a fixture cube above a `generic2` plane: the mirrored image's position; the reflection setting off leaves the target cleared; the reflected list excludes reflective objects. 2350874185 renders its dome (no capture).

**M10 — Particles in 3D and `collisionmodel` (one agent, after M6).**
- **Files:** `Rendering/ParticleOrientation.swift` (camera-based billboards of §2.12), `Rendering/ParticleCollision.swift` and the collision kernels (capsules from bones or the AABB; bounce, slide, stop, delete), `Scene/Loading/ParticleOperatorBuilder.swift` (the operator and the `dependencies` link).
- **Tests:** billboards face the camera in a perspective fixture; capsule fitting against §2.12's rule; the four responses against a capsule, CPU and GPU agreeing (`ParticleSimulationParityTests` style). No library users, so no capture.

**P1 — Puppet mesh (area 7; one agent, after M1; skinned after M6).**
- **Files:** new `Rendering/ScenePuppet.swift` (the mesh into `_rt_imageLayerAlbedo_<id>`, pixel-space ortho, cleared to 0, before the layer's effects), `Scene/Loading/ImageMaterialPlan.swift` (the puppet combos: `SKINNING`, exact `BONECOUNT`, `SKINNING_ALPHA`, `MORPHING`, `MORPHING_MODIFIERS`, cull), and the puppet branch in `SceneWallpaperViewModel.buildMetalLayer` (replacing the "rendering authored atlas" fallback). Puppets are prelit like other lit layers (lighting-plan A4).
- **Tests:** the bind pose of each library puppet reproduces its source image (the atlas's parts land where the unwarped picture has them: a mask comparison against the authored preview); the reference harness for 2515150033 and 2321732083 (WE's Knight: dark lit armour (41, 15, 12) where we draw the raw sheet).

**P2 — Puppet animation and the script bone API (one agent, after P1 and M6).**
- **Files:** the image half of `Resources/SceneScript/objects-layers.js` and its host bindings: animation layers on images, the bone API (`getBoneCount`, `get/setBoneTransform`, local bone TRS, indices, parents), blend shapes, attachments; bone physics (`applyBonePhysicsImpulse`, `resetBonePhysicsSimulation`) stays a logged no-op until a library file carries physics bones.
- **Tests:** script API tests against a fixture puppet (set a bone, read it back through `getBoneTransform`, the mesh moves); the Knight's motion against WE's clip (`analyze.py`'s puppet motion measure).

**T — Tester (after M5; again after M8 and P2).**
- `ModelLibraryRenderTests` over every library 3D scene and puppet: no model or puppet fallback, no NaN or inf in a frame, the frame time, and the counts of meshes, bones and draws.
- Adversarial fixtures: 128 and 129 bones, u32 indices, a model with no materials, a missing `.mdl`, a camera layer hidden mid-run, two camera layers switching, `orthogonalprojection` missing on an image-only scene, `skin` past the list, an attachment name that doesn't exist.
- New "needs WE ground truth" entries in `docs/test-risks.md`: the camera-layer `queuemode` random order, `transparentsorting` in a library scene, additive layer composition, root motion axes, a puppet with morphs.

**O — Optimisation (after T).** Frame and load time on the 3D scenes: 3378346807 (100 models), 3734636606 (~400 spheres through scripts, 46 model objects), PaRappa (115-bone skeletons); instancing identical meshes, caching bone palettes for hidden or paused layers, the shadow atlas layout reuse.

### 4.4 Seams (landed with M0)

M0 decoded the 3D fields of `scene.json` and added the files, types and hook points below without changing what is drawn: the frame camera is the one the renderer already drew with, `SceneMetalContent.spatial` is built but nothing reads it, and model objects are collected and logged, not drawn. M2 and M3 can start now; M4, M5 and the rest follow their prerequisites. Each file below has one owner; a package that needs a file it doesn't own asks for a seam in the owner's file.

**Decoded and resolved.** M0 owns these; the other packages read them and don't edit them (a missing field goes to the owner of the file).

| What | Where |
|---|---|
| `WESceneObject.model: WESceneModel?`: `source` (`.path`, `.loadedID`, `.object`: a string, number or object `model`, WE's dispatcher test), `attachment`, and `skin` and `rootmotion` as `SceneRawValue`s keyed by `SceneModelValueField`, with WE's defaults (`skin` 0, `rootMotion` true). No material overrides, `alpha`, `color`, `brightness` or `instances`: WE doesn't read them on models (§2.6). | `Scene/Format/SceneModel.swift` |
| `WESceneObject.animationLayers: [WEAnimationLayer]` on **every** object, since a puppet image carries them too: `animation` (a `UInt64` clip id, nil when not a number), `id`, `name`, `autosort`, `index`, and `visible`, `additive`, `blendin`, `blendout`, `rate`, `blend`, `blendtime` as `SceneRawValue`s (a timeline on `blend` is kept), with WE's defaults | `Scene/Format/SceneAnimationLayer.swift`, `SceneObject.swift` |
| `WESceneObject.cameraLayer: WESceneCameraLayer?` (a string `camera`): `path`, `queueMode` (`random` unless "sequential"), `fov` and `zoom` bindable (defaults 50 and 1). The layer's transform, parent and `visible` condition are the object's own. | `Scene/Format/SceneCameraLayer.swift` |
| `WESceneObject.renderValues[SceneObjectRenderField]`: `sortorder`, `castshadow`, `reflected`, `depthtest`, as authored on any object (on a light, `castshadow` is the light's own). `WESceneObject.dependencies: [WEObjectDependency]` (`.link(id:type:index:)` for a particle's `collisionmodel`, `.id` for the editor's plain ids). | `SceneObject.swift`, `SceneValueFields.swift`, `Scene/Format/SceneObjectDependency.swift` |
| `WECamera.paths`; `WESceneCameraPathFile` (the scene's path files: disabled paths and keys skipped, missing timestamps at i/(n−1)·duration, `zoom` 1) and `WECameraLayerPathFile` (a camera layer's: `eye`, `center`, `up`, `fov`, `zoom` as `SceneTimelineDocument`s sharing the path's `options`; a path whose options aren't a timeline's is dropped) | `SceneDocument.swift`, `Scene/Format/SceneCameraPath.swift` |
| `WESceneGeneral.projection: WESceneProjection` (§2.1 exactly: `.perspective`, `.orthographic(width:height:)`, `.orthographicAuto`), and `fov`, `perspectiveoverridefov`, `nearz`, `farz`, `zoom`, `camerafade`, `transparentsorting`, `customsortorder` as bindable `general` fields (3378346807 binds `fov`) | `Scene/Format/SceneProjection.swift`, `SceneDocument.swift`, `SceneValueFields.swift` |
| `SceneCameraSettings(general, in:)`: those fields resolved against the user properties, defaults in `SceneCameraDefaults` (fov 50, override 95, near 0.1, far 10000, zoom 1, fov clamp 0.1…179.9, the `camera` block's eye (2, 2, 2), centre 0, up +Y); `sceneFov` is §2.1's effective fov before any camera layer | `Scene/Values/SceneCameraSettings.swift` |
| `SceneDrawOrderMode(settings)`: `sortsBySortOrder` (`customsortorder` without `transparentsorting`) and `splitsTranslucent` (`transparentsorting` in a perspective scene), the object loop's flag tests | `Scene/Rendering/SceneDrawOrder.swift` (M4 applies it) |
| `SceneMetalContent.spatial: SceneSpatialContent`: `camera` (the settings), `staticEye`/`staticCenter`/`staticUp`, `cameraPaths` (every path of every `camera.paths` file, in order), `cameraLayers: [SceneCameraLayerObject]` (id, name, scene index, the decoded layer and its path file), `models: [SceneModelObject]` (id, name, scene index, `WESceneModel`, `animationLayers`, `renderValues`), `drawOrder`. An object with both `model` and `camera` is a model, as in WE. | `Scene/Rendering/SceneSpatialContent.swift`, `SceneCameraLayerObject.swift`, `SceneModelObject.swift`; built by `Scene/Loading/SceneSpatialContentBuilder.swift` from one call in `SceneWallpaperViewModel.metalContent` |

**Hook points and their owners.**

| Seam | File (owner) | How it is called now | What the owner adds |
|---|---|---|---|
| Frame camera | `Rendering/SceneFrameCamera.swift` (**M2** from now on): `SceneFrameCamera` (view, projection, `viewProjection`, eye, forward, up, `fieldOfView` (nil = not perspective), `reversedDepth`), `protocol SceneCameraRig: AnyObject` (`frameCamera(_:)`), `SceneCameraRigInput` (scene size, aspect, time, delta), `SceneCameraRigs.make(for:)` and `SceneLayerPassCameraRig` (today's camera: the layer pass's pixel-space matrix as `projection` with an identity view, and the lighting camera's eye and forward) | `SceneMetalRenderer` makes the rig in `setContent` and calls `frameCamera` once per frame before the frame lighting; the result is `BuiltinFrameContext.camera`, and `eyePosition` and `viewForward` are copied from it (the numbers `g_EyePosition`, the packer's sort and the volumetrics saw before) | M2: WE's rig (camera layers, scene paths, the static camera, shake, fade) in its new files, returned by `make(for:)` for perspective scenes; the inputs it needs (object world matrices from M3, visibility, the time) added to `SceneCameraRigInput` and filled at the one call site. `SceneVolumetricsCamera` takes `SceneFrameCamera`. |
| Projection gate | `WESceneGeneral.usesPerspectiveProjection` (an explicit `null`) is still what `SceneCameraEffects.orthographic`, the engine combos' `orthographic` and `metalSceneSize` read; `SceneCamera(scene:)`, `metalSceneSize` and `particlesUsePixelUnits` read `orthogonalprojection` | unchanged | **M2** moves them to `general.projection` / `spatial.camera.projection` (`{"auto":true}` sized from the first image, which it centres), then deletes `usesPerspectiveProjection` and `WEOrthogonalProjection` and the expected failure in `SceneSpatialDecodeTests.testTheRenderersGateMissesAMissingProjection`. That turns the four default projects without the key (arsenal, demon_core, dna_fragment, fantasticcar) perspective, which is a visible change M2 verifies. |
| Built-in camera uniforms | `Rendering/BuiltinUniforms.swift`: `BuiltinFrameContext.camera` | `g_EyePosition` and `g_ViewForward` read `eyePosition`/`viewForward`; the view-projection uniforms still come from each pass's `BuiltinPassContext` | **M4** takes the pass matrices from `frame.camera` in perspective scenes (`g_ViewProjectionMatrix`, `g_ModelViewProjectionMatrix` = VP × the 3D world matrix). |
| Draw order | `Rendering/SceneDrawOrder.swift` and `spatial.drawOrder` (**M4**) | not read: `orderLayers()` (`SceneRendererScripts.drawOrder`) keeps scene.json order, which is right for every ortho scene | M4: `sortsBySortOrder` by `renderValues[.sortorder]` (stable), `splitsTranslucent` with the translucent flag of §2.4 and `frame.camera.forward`, in the draw loop. |
| 3D transforms | nothing yet; objects keep `origin`, `angles`, `scale` and their `values` | — | **M3**: `Rendering/SceneTransform3D.swift` from `WESceneObject`; the attachment hook reads `WESceneModel.attachment`. |
| Model objects | `Rendering/SceneModelObject.swift` (**M5** from now on) | built for every model object, not drawn; `SceneSpatialContentBuilder` logs "N model objects aren't drawn yet" once per content (a scene of models alone builds no content yet: the `layers`/`particles`/scripts guard in `metalContent` is M5's to widen) | M5: `Scene/Loading/SceneModelBuilder.swift` adds the `MDLModel` (`MDLModel.load(path:package:directory:)`), `skin`'s materials and bounds to `SceneModelObject`; the renderer's `SceneModelDrawing` seam (M4). `castshadow`'s model default (true) is M8's to apply: `renderValues[.castshadow]` is only what is authored. |
| Animation layers | `WESceneObject.animationLayers`, `SceneModelObject.animationLayers` | — | **M6** evaluates them (a `blend` timeline is `values[.blend]?.animation`); **P1/P2** read the same field on puppet images. |
| Camera layers and paths | `Rendering/SceneCameraLayerObject.swift` (**M2**), `spatial.cameraLayers`, `spatial.cameraPaths`, `spatial.static*` | built with their path files; a missing or unreadable file is logged once per content | M2 plays them. |
| Particle links | `WESceneObject.dependencies` | — | **M10** binds `.link(type: "collisionmodel")` to the operator by `index`. |
| Reflection list, text depth | `renderValues[.reflected]`, `renderValues[.depthtest]` | — | **M9** (`reflected`, default true) and **M4** (`depthtest` on texts). |

**Tests that pin the seams:**
- `SceneSpatialDecodeTests`: the survey's model objects and all 15 camera layers (`Tests/Fixtures/Spatial`), every model key with defaults and bindings, WE's dispatcher (model first; `null`, bools and arrays aren't models), both path formats (a trimmed copy of 3159348391's `camera_paths_203.json`, and a hand-built scene path file), `orthogonalprojection` in every form, the camera settings' defaults, bindings and fov clamp, and the draw-order flag table.
- `SceneSpatialSeamTests`: the content builder (models, camera layers with their path files, scene paths, a model with a `camera` key is a model), and that today's rig reproduces the renderer's camera.
- `SpatialLibraryDecodeTests` (skipped without the library): per scene, the decoded models, camera layers, `camera.paths` and projection equal the JSON under WE's rules, and every path file decodes; the survey's totals (254 model objects in 16 scenes, 15 camera layers in 7, 7 scenes with paths, 14 perspective).

## 5. Open points (need the binary or WE ground truth)

1. **Zoom in perspective:** no reader of zoom was found on the perspective path [I]. A capture of a 3D scene at two `zoom` values settles it.
2. **Additive layers:** the exact composition of 0x1401f9820 [I]; and morph tracks under additive layers.
3. **Root motion:** which of the clip flags 0x1f800 is which axis [?].
4. **`queuemode` random:** a shuffle bag or a plain random pick [I].
5. **`getCameraTransforms`/`setCameraTransforms`:** how they map onto the scene camera and the camera layer [?].
6. **The main frame buffer's depth:** D16 in WE; we use depth32Float. A precision difference could show as z-fighting in WE that we don't reproduce; not worth copying unless a capture shows it.
7. **The context bit R+0x128 & 1** (no depth on `_rt_FullFrameBuffer`, a y flip) [?].
8. **The puppet's first auxiliary draw** into `_rt_imageLayerAlbedo` [?].
9. **MDLV unknowns:** mesh flag 0x2 and its u32, the v21 blobs, the v23 groups, bone flag 0x1, the MDLS per-bone blocks, `MDLE`'s consumer [?]. None changes what the library draws: the sweep reads them and nothing in the runtime notes consumes them on the draw path.
10. **Text objects' `depthtest`:** the object key is inferred to feed the text material like an image's [I].
11. **Missing vertex attributes:** what a translated shader sees when a mesh lacks an input it declares (WE's input layout omits it) [I].
12. **The volumetrics' depth convention** (lighting-plan D1 assumed 0 at near); WE is reversed everywhere (§2.4). M2 reconciles it.
