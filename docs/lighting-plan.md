# Lighting, reflections, bloom and HDR: evidence and plan

**Status: 2026-09-26. L0 (format, values, settings and seams) is done; the seams are in §4.4. A1 (the generated `LightingV1` and the light combos) is done. Nothing draws differently yet: lit image layers are still refused until A3.** This covers roadmap area 5 (lighting and reflections) and the image-material part of area 1 item 3 that area 5 needs: 3 library image layers fall back to our native draw because their materials set `LIGHTING`/`REFLECTION`. It sets out:

- WE's format for lights and the `general` lighting, bloom and HDR settings, with a survey of the library;
- how `wallpaper64.exe` collects lights, generates `#require LightingV1`, reflects, blooms, tone-maps and shadows;
- where our implementation stands;
- work packages that parallel agents can take.

Where the ground truth comes from:

- **Binary:** `wallpaper64.exe` from the 2026-09 install. The disassembly is `we64.asm` in the session scratchpad; the helpers are `/Volumes/980Pro/dd-timeline/we.py` (`strva`, `xrefs`, `show`). Addresses below are VAs in that file.
- **Shaders:** WE's shipped shaders and `materials/util`, vendored in `Vendor/we-assets`. They are byte-identical to the install's, so the util materials can be run as they are.
- **Docs:** docs.wallpaperengine.io: scene/lighting introduction and lights, models/lighting, effects/bloom, models/introduction, IScene. The docs are tutorial-level. They don't mention `lightconfig`, `_rt_Reflection`, shadow atlases or the HDR feather and iterations, and give almost no defaults.
- **Library:** the Steam workshop folder, `/Volumes/980Pro/OpenWallpaperStorage` and WE's default projects, `scene.pkg` contents included. That is 106 scenes after de-duplicating by workshop id.

WE can't be run here. Where the binary leaves a value open, it is tagged **[?]** and listed in §5.

The extracted data is in `/Volumes/980Pro/dd-lighting`:

| File | Contents |
|---|---|
| `survey/survey.py`, `survey/load.py` | the library scanner (reads `.pkg`; delete `cache.pkl` to rescan) |
| `survey/summary.md` | every table of §1.5 in full, with key and value distributions |
| `survey/per_wallpaper.json`, `.csv` | one row per scene: lights by type, hdr, bloom, lit layers, models |
| `survey/examples.json` | all 11 light objects, general blocks, lit layers, lit effects, models |
| `survey/raw.json` | raw key→count tables, and the grep of the shipped shaders |
| `re-lights/lightingv1_gen.py` | a port of WE's `LightingV1` generator (0x140169140) |
| `re-lights/lightingv1_fragments.txt` | the 67 strings that generator emits, verbatim, with addresses |
| `re-lights/lightingv1_example.glsl` | one sample expansion |
| `light_parse.asm`, `light_ctor.asm`, `scene_update.asm`/`su.txt`, `lightingv1_gen.asm`, `combos_lights.asm`, `uniform_set.asm`, `render_scene.asm`, `volumetrics.asm` | annotated disassembly |

## 1. Format and library survey

### 1.1 Light objects (`scene.json` objects with a `light` key)

A light is a scene object with the usual `origin`, `angles`, `scale`, `parent`, `visible` and `parallaxDepth`, plus the fields below. The properties are registered at `0x14025da80`; the constructor defaults are at `0x140190457`…`0x1401904e4`. None of the library's light fields is bound to a user property, script or animation. Tube endpoints can still be animated, as the docs describe, so the fields are read through `Scene/Values` like any other.

| Key | Type (offset) | WE default | Meaning |
|---|---|---|---|
| `light` | enum (0x2c0) | legacy `point` | `lpoint`=0, `lspot`=1, `ltube`=2, `ldirectional`=3; `point`=5 is the **legacy** type (4 fixed slots, §2.2). No other names exist. An unknown name is taken to leave the constructor's 5 [?: the enum setter wasn't traced]; we log it. A `null` `light` is no light, as for `sound`. |
| `color` | vec3 (0x2cc) | 0 0 0 | |
| `intensity` | float (0x2e4) | 0 (the constructor zeroes 0x2e0…0x2e7 at 0x14019047f) | multiplies the colour (premultiplied) |
| `radius` | float (0x2e8) | 1 | falloff `saturate(1 − d/radius)^exponent` |
| `exponent` | float (0x2ec) | 2 | |
| `innercone`, `outercone` | float (0x2f0, 0x2f4) | 20, 30 | half-angles in degrees; the shader gets their cosines |
| `controlpoint` | vec3 (0x2d8) | 2 0 0 | tube end B, in the light's local space; end A is the origin |
| `castshadow`, `usecookie`, `castvolumetrics` | bits 0/1/2 of 0x2c4 | off | |
| `density`, `volumetricsexponent` | float (0x2f8, 0x2fc) | 2, 1 | volumetrics only |
| `cascadedistance0/1/2` | float (0x300…0x308) | 3, 10, 100 | directional shadow cascades |
| `lightsourcesize` | float (0x30c) | 0 | near plane of a point light's shadow |

A light points along its **local +X** axis. The world matrix is row-major, and row 0 is the direction.

### 1.2 `general` lighting, bloom and HDR settings

| Key | WE default (scene constructor offset) | Notes |
|---|---|---|
| `ambientcolor`, `skylightcolor` | constructor (0,0,0) (0x368…0x37c, zeroed at 0x140186f68…0x140186f7d). Every library scene authors both, mostly 0.3 grey. | Copied into the frame context at load (0x140187e4a) and on change (0x1401863f0). Model shaders mix them by `N.y·0.5+0.5`; `genericimage4` uses the ambient colour alone. |
| `lightconfig` | absent | `{"point":n,"spot":n,"tube":n,"directional":n,"spotshadow":n,"spotcookie":n,"spotshadowcookie":n,"directionalshadow":n,"pointshadow":n}`. **It is the light budget.** Without it, new-style lights have no effect (§2.2). Each count is its integer masked to the field width (4 bits base, 2 bits subset: 20 → 4); a value that isn't a number is skipped. |
| `bloom` | false (scene flag 0x2) | |
| `bloomstrength`, `bloomthreshold` | 2.0 (0x3bc), 0.65 (0x3c0) | LDR bloom |
| `bloomtint` | 1 1 1 (0x3d8) | both chains |
| `hdr` | false (scene flag 0x400) | needs `bloom` too, plus the user's post-processing setting at "ultra" (§2.6) |
| `bloomhdrstrength`, `bloomhdrthreshold`, `bloomhdrfeather`, `bloomhdrscatter` | 2.0, 1.0, 0.1, 1.619 (0x3c4…0x3d0) | HDR bloom |
| `bloomhdriterations` | 8 (0x3d4, an **int**) | |
| fog (`fog*`) | distances 1…5, heights 1…−3, densities 1 | no library scene has fog |

The docs' "Ultra HDR" and "HDR threshold smoothing" are `hdr` and `bloomhdrfeather`. The per-object "HDR brightness" is `brightness`: 185 image objects author it, and generic2 multiplies the albedo by it under `HDR`.

### 1.3 Reflection, shadows and volumetrics in the format

- **Reflection:** there are no `general` reflection keys. Image layers turn it on with material combos (`REFLECTION`, plus `NORMALMAP` for anything to show).
  - Model objects carry `reflected` (default true, `0x14019086d`), which puts them in the planar reflection pass (§2.5).
  - The user setting `reflection` (bool, default true) turns the screen-space copy off.
- **Shadows:** `castshadow` on a light and on objects (image, model, other).
  - 350 `castshadow` keys exist in the library, and **none is true**.
  - The caster shader is picked by a `// [PASS] shadow <shader>` header in the object's shader, otherwise `materials/util/shadowcaster.json`.
- **Volumetrics:** `castvolumetrics`, `density` and `volumetricsexponent` on point and spot lights.
- **Cookies:** a spot light with `usecookie` projects a texture (the docs: an image, a video or a layer). The key that names the cookie source wasn't found. The one library cookie spot (Hinata) has none of `cookie`/`texture` among its keys [?].

### 1.4 Material side (`genericimage4`, and the same pattern in `genericimage2/3`, `generic4`, `chroma4`, `fur4`, `foliage4`)

- **Combos:** `LIGHTING` (default 0 on image shaders, 1 on `generic4`), `REFLECTION` (default 0) and `FOG` (default 1).
- **Normal map:** `g_Texture1`, `NORMALMAP`, rg88 with `formatcombo`.
- **PBR mask:** `g_Texture2`, `PBRMASKS`, whose r, g, b and a channels are the `METALLIC_MAP`, `ROUGHNESS_MAP`, `REFLECTION_MAP` and `EMISSIVE_MAP` components.
- **Material constants:** `roughness` 0.7, `metallic` 0, `speculartint` 1 1 1, `emissivecolor` 1 1 1, `emissivebrightness` 1, `reflectivity` 1, `reflectivitydistance` 4 (hidden).
- **Engine textures:** `g_Texture3` = `_rt_MipMappedFrameBuffer` (with REFLECTION and NORMALMAP), `g_Texture4` = `_rt_FullFrameBuffer` (with BLENDMODE), `g_Texture6` = `_rt_shadowAtlas` (a comparison sampler, with `LIGHTS_SHADOW_MAPPING`, plus `g_Texture6Texel`), and `g_Texture7` = `_alias_lightCookie` (with `LIGHTS_COOKIE`).
- **Engine uniforms:** `g_LightAmbientColor`, `g_EyePosition`, `g_NormalModelMatrix`, `g_ViewProjectionMatrix`, `g_AltModelMatrix`/`g_AltNormalModelMatrix`/`g_AltViewProjectionMatrix` (PRELIGHTING), `g_Texture3MipMapInfo`, `g_Screen`, `g_Texture2Resolution`.
- **Lighting math:**
  - `genericimage4.frag` calls `PerformLighting_V1(v_WorldPos, albedo, N, V, g_SpecularTint, f0, roughness, metallic)`; **the 6th argument is f0**, not an ambient colour.
  - The result goes through `CombineLighting(light, g_LightAmbientColor·albedo)`, which is `ambient + light`. Under HDR it is `saturate(ambient + light) + light·saturate(|light|−2)·0.5/max(0.01,|light|)`.
  - `SCENE_ORTHO` fixes the view vector at (0,0,1).
  - The building blocks (GGX, Schlick, Smith, `PointSegmentDelta`, PCF, cascades, point-shadow cube faces) are in `common_pbr_2.h`.

### 1.5 Library survey (106 scenes)

**Lights: 11 lights in 5 scenes.**

| Scene | Lights | `lightconfig` | What they light |
|---|---|---|---|
| 3270035750 "One piece girls" | 4 `ltube` (intensity 10, radius 500, exponent 2, z = 250, `controlpoint` (1.9, 1131.8, 0): vertical tubes across the image) | `{"tube":4}` | image layer `f1` (genericimage4, `LIGHTING:1`, **no effects**); ambient 0.294 0.133 0.133 |
| 3352730400 "Hinata Uzumaki" | 1 `lspot` (cones 80/80, radius 1136, intensity 4.12, `usecookie`, `castvolumetrics`) | `{"spot":1,"spotcookie":1}` | no lit layer: only its volumetrics show. HDR and bloom are on. |
| 3453730450 "Moon" [3D] | 3 `lpoint` (all `castvolumetrics`; 2 parented and invisible) | `{"point":3}` | 5 `generic4` models (`LIGHTING:1`, mostly `REFLECTION:1`): area 6 |
| arsenal (default project) | 2 legacy `point` | none | 1 model (`generic`, LIGHTMAP/NORMALMAP/REFLECTION); uses `_rt_Reflection` |
| demon_core (default project) | 1 legacy `point` | none | 2 models; custom `core` shader reading `g_Lights*` |

No `ldirectional` light exists. Nothing casts shadows. Of the 11 light objects, 8 author `castshadow` and all 8 are false.

**`general`:**

| Key | Scenes | Values |
|---|---|---|
| `bloom` | 106 | **true in 24** (4 user-bound) |
| `bloomstrength` / `bloomthreshold` | 98 | mostly 2.0 / 0.65. Strength is user-bound in 3 and script-bound in 2; threshold is user-bound in 2. |
| `bloomtint` | 48 | 46 white |
| `hdr` | 70 | **true in 5**: 3074485715, 3352730400, 3606529469, razer_bedroom, shimmering_particles. All 5 also have bloom on. |
| `bloomhdrstrength/threshold/feather/scatter` | 70 | mostly 2.0 / 1.0 / 0.1 / 1.619 |
| `bloomhdriterations` | 64 | always 8 |
| `ambientcolor` | 106 | not the default 0.3 grey in 8 scenes (e.g. witcher 1 1 1, One piece girls reddish) |
| `skylightcolor` | 106 | not the default grey in 3 (arsenal, fantasticcar, ricepod) |
| `lightconfig` | 3 | see above |
| fog, reflection or shadow keys | 0 | |

**Lit image layers** (`LIGHTING` or `REFLECTION` = 1). There are 4, and 3 of them are in OpenWallpaperStorage: those are the 3 fallbacks.

| Scene | Layer | Material, combos | Effects on the layer | What WE draws |
|---|---|---|---|---|
| 3270035750 One piece girls | `f1` | genericimage4, `LIGHTING:1` | none | full LightingV1 with 4 tubes: **the one visible direct-lighting user** |
| 3803167460 witcher (beta) | `ведьмак розбивpng` | genericimage4, `LIGHTING:1` | 9 | prelighting path (§2.3); no `lightconfig`, so ambient only (1 1 1): the albedo, unlit |
| 3803167460 witcher (beta) | `меч` | genericimage4, `LIGHTING:1 REFLECTION:1`, normal map + PBR mask, metallic 1, roughness 0.55, reflectivity 4 | 2 | prelighting; screen-space reflection off `_rt_MipMappedFrameBuffer` |
| 2370927443 Lofi Cafe (workshop only) | `Base Image` | genericimage2, `REFLECTION:1`, no normal map | 11 | prelighting; REFLECTION without NORMALMAP adds nothing |

No particle material turns on lighting. 17 passes in 9 scenes set `LIGHTING` and 12 in 7 set `REFLECTION`, but most set them to 0.

**Effects:**
- Two local copies of `fluidsimulation` (3244466773, 3245833232) have `#require LightingV1` and `_rt_shadowAtlas` behind a `LIGHTING` combo that stays 0.
- Light-looking 2D effects (shine 34 uses, godrays 26, lightshafts 4, reflection 2) don't use lighting at all; they are ordinary effects.

**Models:** 26 model objects in 8 scenes (Moon, and the default projects arsenal, demon_core, fantasticcar and others). All of them wait for area 6.

**Usage ranking:**
1. Bloom: **24 scenes**, the most used feature here.
2. HDR: 5.
3. Lit image layers: 3 in the library (1 with real lights).
4. Volumetrics: 2 (Hinata; Moon with area 6).
5. Planar reflection: 2 default projects (area 6).
6. Shadows: 0.

## 2. WE's runtime (`wallpaper64.exe`)

### 2.1 `#require LightingV1` is generated, not stored

- The preprocessor's `require` handler (`0x14016c0ec`) calls a generator at `0x140169140`. It emits **nothing** unless the name is exactly `LightingV1` and the combo `LIGHTING` exists and is non-zero. No other `#require` name exists.
- It emits:
  - uniform arrays sized by the engine's `LIGHTS_*` combos (§2.2);
  - then `vec3 PerformLighting_V1(vec3 worldPos, vec3 color, vec3 normal, vec3 viewVector, vec3 specularTint, vec3 ambient /*f0*/, float roughness, float metallic)`, unrolled as one `{ const uint i = Nu; … light += … }` block per light.
- The per-light code, in emission order (verbatim in `re-lights/lightingv1_example.glsl`):
  - **Points** (the first `LIGHTS_POINT_SHADOW` are shadowed): `lightDelta = g_LPoint_Origin[i].xyz − worldPos`, `ComputePBRLightShadow(N, lightDelta, V, color, g_LPoint_Color[i].rgb, g_LPoint_Color[i].w /*radius*/, g_LPoint_Origin[i].w /*exponent*/, …, shadow)`. A shadowed point gets its factor from `CalculateProjectedCoordsPoint` and `PerformPointShadowMapping`.
  - **Spots**, in four groups in this order:
    1. shadow+cookie;
    2. cookie only: the colour is multiplied by the cookie texture at the projected coordinates, and there is no cone;
    3. shadow only;
    4. plain.

    Without a cookie, the colour is multiplied by `smoothstep(Direction.w /*cos outer*/, Origin.w /*cos inner*/, −dot(normalize(delta), Direction.xyz))`; the exponent is `g_LSpot_Exponent[i].x`. The spot index also indexes `g_LFeature_ShadowProjection`.
  - **Tubes:** `lightDelta = PointSegmentDelta(worldPos, OriginA, OriginB)`, exponent `OriginA.w`, never shadowed.
  - **Directionals:** `ComputePBRLightShadowInfinite(N, Direction.xyz, …)`. The first `LIGHTS_DIRECTIONAL_SHADOW` blend 3 cascades `p1..p3` that follow the spot features.
    - **WE quirk [C]:** the generator advances the cascade base by 1 per light (`0x14016a9b4`/`0x14016ae36`) while the CPU writes 3 matrices per light (`0x1401929d4`). With 2 or more shadowed directionals, WE samples the wrong cascades. Reproduce it, don't fix it.
- `re-lights/lightingv1_gen.py` reproduces the generator exactly for any combo set. It is the oracle for WP A1.

### 2.2 Collection, budget, sort and packing

- **No per-object light list.** Every material with `LIGHTING` gets the same global arrays. There is no distance culling and no per-object maximum. The docs' "four lights per scene" is editor guidance; the real limit is the `lightconfig` budget, 4 bits per type (≤ 15).
- **Budget:** `general.lightconfig` is parsed at `0x140187695` into ctx+0x121c:
  - 4-bit `point`, `spot`, `tube` and `directional`;
  - 2-bit `spotshadow`, `spotcookie`, `spotshadowcookie`, `directionalshadow` and `pointshadow`.

  The word is point bits 0–3, spot 4–7, tube 8–11, directional 12–15, spotshadow 16–17, spotcookie 18–19, spotshadowcookie 20–21, directionalshadow 22–23, pointshadow 24–25. The base counts include their shadow and cookie subsets. With the user's shadows disabled (0x140187c39), `spotshadowcookie` is OR-ed (bitwise, not added) into `spotcookie`'s bits and the other shadow counts drop to 0. **Without `lightconfig`, the per-frame packer returns early (`0x140190cab`) and every `LIGHTS_*` combo is 0 [C].**
- **Per frame** (`0x140190c80`, called at `0x14018031a`):
  1. Sort all lights (`0x140186990`, comparator `0x14019f490`): by type ascending; then by cookie/shadow flags descending (shadow+cookie, cookie, shadow, none); then by `dot(position, cameraForward)` ascending (ctx+0x160 [L]).
  2. Walk the sorted list and drop any light past its type's budget. Sub-group overflow isn't checked: WE trusts `lightconfig`.
  3. Pack each light from its **live world transform**, so parents, scripts and timelines apply:

  | Type | Arrays |
  |---|---|
  | point | `LPoint_Color` = (c·I, radius), `LPoint_Origin` = (pos, exponent) |
  | spot | `LSpot_Color` = (c·I, radius), `LSpot_Origin` = (pos, cos inner), `LSpot_Direction` = (row0, cos outer) (not normalised; cosines at `0x140192e64`/`eaa`), `LSpot_Exponent.x` = exponent |
  | tube | `LTube_Color` = (c·I, radius), `LTube_OriginA` = (pos, exponent), `LTube_OriginB` = world(`controlpoint`) |
  | directional | `LDirectional_Color` = (c·I, 1), `LDirectional_Direction` = (−row0, 0), pointing toward the light |
  | shadow features | `LFeature_ShadowProjection` (mat4) and `…Transform` (atlas rect: xy offset, zw scale) × F, where F = SSC + SC + SS + 3·DS; `LFeature_ShadowPointProjection` and `…Transform` × PS |

  4. `_alias_lightCookie` is set to the **last** cookie spot's texture, so there is one cookie per scene.
- **Buffer order** (HLSL `g_bufLights`, generator `0x1400f74db`): the order of the table above. On Metal, our translated shaders see the arrays as ordinary uniform members, found by reflection by name.
- **Legacy uniforms** (the `genericimage2`, `generic`, `generic2` and custom shaders). Ids are registered at `0x140003d56`; the per-draw setter is `0x1400d8300`:
  - `g_LightsColorRadius[4]` = (c·I, radius), or (0,0,0,1) when invisible.
  - `g_LightsPosition[4]` = the translation.
  - Both are filled only by **legacy `point`** lights, in a fixed slot 0–3 taken at construction (first free; a fifth light collides on slot 0; `0x14025d1f0`).
  - `g_LightsColorPremultiplied[3]`: `out[k].xyz = L_k.rgb·r_k²`, `out[k].w = L_3.rgb[k]·r_3²` [C].
  - `g_LightAmbientColor` and `g_LightSkylightColor` come from `general`.
- **Engine combos** (`0x1401a5c40`):
  - The engine never forces `LIGHTING`.
  - When a material's `LIGHTING` ≠ 0, it sets `LIGHTS_POINT`, `_SPOT`, `_TUBE`, `_DIRECTIONAL`, `_SPOT_SHADOW_COOKIE`, `_SPOT_SHADOW`, `_SPOT_COOKIE`, `_DIRECTIONAL_SHADOW` and `_POINT_SHADOW` from the budget.
  - Any shadow count > 0 sets `LIGHTS_SHADOW_MAPPING=1` and `LIGHTS_SHADOW_MAPPING_QUALITY` = the shadow quality (1–4).
  - A cookie count > 0 sets `LIGHTS_COOKIE=1`.
  - The same routine sets `SCENE_ORTHO`, `FOG_DIST`/`FOG_HEIGHT`, `BACKBUFFER_MS`, `HDR`, `REVERSEDEPTH` and `TEX<n>FORMAT` for every material.
- **User settings** (`0x14010ed80`):
  - `shadows`: disabled, low, medium (default), high, ultra = 0…4.
  - `volumetrics`: the same scale.
  - `reflection`: bool, default true.
  - `postprocessing`: see §2.6.

### 2.3 Lit image layers and the prelighting path

At `0x140206eaf` an image layer without effects or a puppet compiles its material with `LIGHTING` = the layer's lighting flag and `REFLECTION` = its reflection flag. Both flags come from the material's combos.

A layer **with effects** (or a puppet) compiles its base material with both at 0 and takes the **prelighting path** (`0x140209540`) [L on the exact pass order]:
1. The albedo is rendered unlit into `_rt_imageLayerAlbedo_<id>`.
2. The layer's effects run on it.
3. The final quad (`fullscreenlayer.json`, `PRELIGHTING=1`, `PRELIGHTINGDUALVERTEX=1`, and `SKINNING`/`BONECOUNT`/`MORPHING` as needed) applies lighting and reflection with the `g_Alt*` matrices. That puts the lit surface where the layer is, while the effect output is sampled full-screen.

A lit puppet switches to `genericimage2`. Two of our three fallback layers (witcher) and Lofi Cafe take this path; One piece girls' `f1` doesn't.

### 2.4 Screen-space reflection (`_rt_MipMappedFrameBuffer`)

All modern shaders (generic4, genericimage2/3/4, chroma4, fur4, foliage4) reflect in screen space; `_rt_Reflection` is not involved.

- **Creating the target:** an object reporting feature bit 0x40 (`0x140181cf8`) creates `_rt_MipMappedFrameBuffer` at full resolution, with mips [?: 15 in HDR, 1 otherwise].
- **Filling it:** it is copied, and its mips generated, after the main pass while render flag 0x80 is set, i.e. while the user's reflection setting is on. Otherwise it is cleared to (0,0,0,1) [L].
- **The reflection itself** (genericimage4):
  - The tangent-space normal is projected to screen: `normal.xy · (0.15, 0.15·g_Screen.z)`.
  - `screenUV += normal.xy · fresnel⁴ · g_ReflectivityDistance`, where `fresnel = max(0.001, dot(N, V))`.
  - The sample is `texSample2DLod(g_Texture3, screenUV, roughness · g_Texture3MipMapInfo)`.
  - `refl = pow(max(0.001, refl·(1−fresnel)·reflectivity), 2 − metallic)`.
  - `color.rgb += saturate(refl) · fresnel`.
  - The mask's b channel scales `reflectivity`.
- It needs `NORMALMAP`. Without it, REFLECTION only computes normals.

### 2.5 Planar reflection (`_rt_Reflection`)

Only `generic2.frag` samples it. It is created when an object reports feature bit 0x8 (`0x140181c65`): full resolution, the frame-buffer format. At the start of the frame (`0x140180357`…`0x14018089a`, before the main scene) the engine:
- multiplies the view by `diag(1, −1, 1, 1)`, a mirror across the world plane y = 0;
- mirrors the eye and the camera basis;
- flips the culling;
- draws the "reflected list": model and image objects whose `reflected` is true and which are not reflective themselves.

This is 3D-only in practice (arsenal, fantasticcar), so it belongs with area 6.

### 2.6 Bloom and HDR

**Enabling:**
- **Post-processing:** render flag 0x40 is set when the user's `postprocessing` setting is anything but "disabled" (`0x14010edab`). The engine writes "disabled" when the key is missing [?: the settings UI's default is unknown].
- **HDR:** decided at scene load (`0x14010e612`…`e6da`), only if **both** `general.bloom` and `general.hdr` are true. Then `postprocessing` = "ultra" sets HDR (0x2000), and "displayhdr" sets HDR plus display HDR (0x6000). Display HDR without an HDR swapchain falls back to plain HDR (`0x1401109be`).
- **HDR combo:** HDR compiles **every** material with `HDR=1` (`0x1401a6721`). That turns on CombineLighting's overbright, emissive overbright, `g_Brightness` in generic2, and the ccsimple LUT's overbright.
- **Per frame** (`0x140180a41`), bloom runs only if flag 0x40, `scene.bloom` (live; scripts and user properties can toggle it) and a non-empty scene list (`[scene+0x158]` [?]) all hold.
- **Constants** are recomputed on load and whenever the scene is dirty (`0x140184020`), so user and script changes apply live.

**Formats:** every frame-buffer-class target (`_rt_FullFrameBuffer`, MSAA, mip-mapped, bloom) is **RGBA8 in LDR and RGBA16F in HDR**: `rgb_backbuffer` resolves to 1 or 0xf (`0x1401e75ae`), mapped at `0x1400d2a20`.

**LDR chain** (setup `0x14017f1b0`, run `0x140183949`). Constants go only to pass 1.

| # | Material (shader) | In → out | Size | Math |
|---|---|---|---|---|
| 1 | `downsample_quarter_bloom` | `_rt_FullFrameBuffer` → `_rt_4FrameBuffer` | 1/4 | 4 diagonal taps at `uv ± g_TexelSize`, averaged; `c *= saturate(max(r,g,b) − g_BloomThreshold)`; `c = 2c − dot(c, (.2989,.587,.114))`; `out = max(0, c · strength · tint)` |
| 2 | `downsample_eighth_blur_v` | `_rt_4FrameBuffer` → `_rt_8FrameBuffer` | 1/8 | 13 taps along **x**, step 8·`g_TexelSize.x`; weights .006299 .017298 .039533 .075189 .119007 .156756 .171834 (centre), symmetric |
| 3 | `blur_h_bloom` | `_rt_8FrameBuffer` → `_rt_Bloom` | 1/8 | the same along **y**; the file names have the axes swapped |
| 4 | `combine_ldr` (`combine`) | [`_rt_FullFrameBuffer`, `_rt_Bloom`] → output | 1 | `vec4(scene.rgb + bloom.rgb, 1)` |

`g_TexelSize` is 1 / full render size [I]; that is the only size under which pass 1 is an exact 4×4 box.

**HDR chain** (targets `0x14017f346`…`f544`, run `0x140183610`). Up to 8 levels, `_rt_2FrameBuffer` (1/2) down to `_rt_256FrameBuffer`, all RGBA16F; the count is how many times `min(w,h)` halves, capped at 8. `_rt_Bloom` isn't created.

```
n        = max(1, min(levels, bloomhdriterations))
strength = bloomhdrstrength / (1 + bloomhdrscatter^(max(n,2) − 2))      // default 2/(1+1.619^6) ≈ 0.105
t = bloomhdrthreshold; k = t · bloomhdrfeather
blend    = (t, t − k, 2k, 0.25 / (k + 1e−5))                             // g_BloomBlendParams, default (1, .9, .2, 2.5)
D0: hdr_downsample_bloom  _rt_FullFrameBuffer → RT0 (1/2), g_RenderVar0 = (1/w, 1/h, −1/w, −1/h)
    c = box4; b = max(c.rgb); soft = clamp(b − blend.y, 0, blend.z)² · blend.w
    c *= max(soft, b − blend.x) / max(b, 1e−5) · strength · tint
Di: hdr_downsample        RT[i−1] → RT[i], box4, RenderVar0 × 2^i            i = 1…n−1
Uk: hdr_upsample(_cubic)  RT[k] → RT[k−1], additive: += 0.25 · scatter · Σ4 taps, RenderVar0 × 2^k
                          k = n−1…1; bicubic (B-spline) for k ≥ n−2
combine_hdr_upsample:     bloom = tent4(RT0);
    ultra      out = saturate(srgbToLinear(scene + bloom)) · RV.x
    displayhdr a = saturate(scene) + bloom; out = srgbToLinear(max(0,a)) · (RV.x + RV.y · smoothstep(1, 5, luma(a)))
```

There is **no tone-mapping operator**. The scene is drawn gamma-encoded into float targets with overbright allowed, and it is linearised only at the combine. So the output is linear (scRGB). `RV` = `g_RenderVar0` from the device (vt+0x158) [?: x the SDR-white scale, y the HDR boost]. An HDR scene without bloom running draws `combine_srgb` (`out = srgbToLinear(scene)`) instead.

**Frame order** (`0x14017fa70`):
1. The planar reflection pass (§2.5).
2. The main scene: every object, its effects and composite layers, into MSAA if enabled, then resolved.
3. `_rt_FullFrameBuffer` ← the frame.
4. `_rt_MipMappedFrameBuffer` copy and mips, if flag 0x80.
5. The bloom chain and combine; or, in HDR without bloom, `combine_srgb`.
6. `ccsimple` (colour correction), if present.
7. The camera fade (`fade.json`, alpha = the fade).
8. Present.

Bloom therefore sees the fully composited frame exactly once.

### 2.7 Shadows

- **Casters:**
  - Lights: point, spot and directional (never tubes) with `castshadow`, the shadows setting on, and room in the budget.
  - Objects: those with `castshadow`, drawn with their `[PASS] shadow` shader or `shadowcaster.json`. Translucent casters get `ALPHATOCOVERAGE`.
- **Map size per light** (`0x14025d3e0`): 256 at quality 1–2, 512 at 3, 1024 at 4.
- **Spot:** perspective with fov 2·outercone, near 0.05, far `max(radius, 0.06)`.
- **Point** (`0x14025d9c1`):
  - Six cube faces with fov 94°/92°/91.2° (quality 1–2 / 3 / 4), which matches the shader's 0.47/0.48/0.49 compensation.
  - near = `max(0.05, lightsourcesize)` (1.0 in ortho scenes); far = `max(radius, near + 0.01)`.
  - The faces are packed as a 2×3 block.
- **Directional:** 3 cascades (`0x14025d370`) of (distance, size) = (c0, 4c1), (c1, 4c1), (c2, max(1.5c2, 4c1)), each halved and centred at `eye + forward · distance/2` [L].
- **`_rt_shadowAtlas`** (`0x1401938d1`): rectangle-packed, grown on demand, sampled with a comparison sampler [?: depth format]. Filtering is 1 tap at quality 1, otherwise 9-tap PCF.

### 2.8 Volumetrics

- **Trigger** (`0x140196ce0`): any light with `castvolumetrics`, and the volumetrics setting not disabled.
- **Targets:** `_rt_volumetricsBack` at full size; `_rt_volumetricsSingle` and `_rt_volumetricsLightBuffer` at 1/4 (quality ≥ 3) or 1/8. Below quality 3 there is also `_rt_volumetricsLightBufferB` with `volumetrics_blur_h`/`_v` (`blur_k3`).
- **Per point or spot light:**
  1. The back faces of the light volume (a sphere; a frustum box for a spot with shadow or cookie; otherwise a 32-segment cone) go into `_rt_volumetricsBack` (`volumetrics_back`).
  2. `volumetrics_front` ray-marches it; `volumetrics_fullscreen` is used when the camera is inside the volume.
  3. `volumetrics_combine` adds the light buffer to the frame (additive `passthrough`).
- **Combos:** `COOKIE`, `SHADOW`, `QUALITY`, `POINTLIGHT`, `LIGHTS_SHADOW_MAPPING_QUALITY`.
- **Uniforms** (`0x14019870f`):

  | Uniform | Contents |
  |---|---|
  | `g_RenderVar0` | shadow transform |
  | `g_RenderVar1` | (radius·0.99, cos inner, cos outer, intensity) |
  | `g_RenderVar2` | (origin, density) |
  | `g_RenderVar3` | spot forward, or the point's projection info |
  | `g_RenderVar4` | (colour **without** intensity, volumetricsexponent) |

## 3. Where we stand

Code references are to `OpenWallpaperEngine/Scene/…`.

| Feature | WE semantics (§) | Our status | Library users |
|---|---|---|---|
| Light objects | typed lights, WE defaults (1.1) | ❌ `WESceneObject` has no `light` key; lights are dropped | 11 lights / 5 scenes |
| `lightconfig` budget | gates everything (2.2) | ❌ not decoded | 3 |
| `ambientcolor`/`skylightcolor` | general → `g_LightAmbientColor`/`g_LightSkylightColor` (1.2) | ✅ A2: from `general` (a script's colour wins) through `BuiltinFrameContext.lighting`, written every frame; the invented 0.2 / 0.3 are gone | all 106 author them; 8 non-default |
| `#require LightingV1` | generated per `LIGHTS_*` combo set (2.1) | ✅ A1: `Shaders/LightingV1Require.swift`, expanded per variant (`ShaderSource.text(combos:)`); text-equal to `Scripts/lightingv1-reference.py`. The old stub's `color * f0` is gone | every LIGHTING material |
| `LIGHTS_*`, `HDR`, `SCENE_ORTHO` engine combos | set per material (2.2) | 🟡 A1: `LIGHTS_*`, `LIGHTS_SHADOW_MAPPING*`, `LIGHTS_COOKIE` and `SCENE_ORTHO` (`SceneEngineCombos+Lighting.swift`); `HDR` waits for B2 | — |
| `g_L*` light arrays, legacy `g_Lights*` | packed per frame from live transforms (2.2) | ✅ A2: `Rendering/SceneLightPacker.swift`; the `g_LFeature_*` projections stay zero (D1 cookies, D2 shadows) | One piece girls (tubes); legacy: default projects |
| Lit image layers (`LIGHTING`/`REFLECTION`) | direct path, or prelighting with effects (2.3) | ❌ refused: `ImageMaterialPlanBuilder.unsupportedCombos` (`Loading/ImageMaterialPlan.swift`:63) → "needs scene lights (roadmap area 5)", drawn natively | 3 layers (f1, witcher ×2) + Lofi Cafe (workshop) |
| Prelighting (`PRELIGHTING`, `_rt_imageLayerAlbedo_`, `g_Alt*`) | 2.3 | ❌ | witcher ×2, Lofi Cafe |
| Normal map / PBR mask on images | rg88 with `formatcombo`, `TEX1FORMAT` (1.4) | 🟡 the particle side sets `TEX<n>FORMAT=8`; images never reach it (behind LIGHTING) | меч |
| Screen-space reflection `_rt_MipMappedFrameBuffer` | copied after the main pass, mipmapped, `g_Texture3MipMapInfo` (2.4) | 🟡 mapped to the non-mipmapped `.sceneSnapshot`; no mip info | меч (+ 4 materials per test-risks) |
| Planar `_rt_Reflection` | mirrored pass of the `reflected` list (2.5) | ❌ rejected | arsenal, fantasticcar (area 6) |
| LDR bloom | 4 util passes on the composited frame (2.6) | 🟡 approximation: one 3×3 bright-pass in `sceneFragment` (`Rendering/SceneShaders.metal`:185), `max(authored, (_owe_bloom−1)·1.2)` (`SceneMetalRenderer.swift`:927-943); ignores `postprocessing` | **24 scenes** |
| HDR (float targets, `HDR=1`, mip-chain bloom, combine) | 2.6 | ❌ `hdr` and `bloomhdr*` not decoded; the scene target is the drawable's `bgra8Unorm` | 5 scenes |
| `postprocessing` / `shadows` / `volumetrics` / `reflection` user settings | 2.2, 2.6 | ❌ | all bloom/HDR scenes |
| Shadows (`_rt_shadowAtlas`, casters) | 2.7 | ❌ | 0 (no `castshadow` true) |
| Volumetrics | 2.8 | ❌ | Hinata (2D), Moon (3D) |
| Light cookie (`_alias_lightCookie`) | one per scene (2.2) | ❌; the cookie source key is unknown | Hinata |
| Fog (`FOG_*`, `g_Fog*`) | per general fog | ❌ (must stay off) | 0 |
| Depth buffer, perspective models | area 6 | ❌ | Moon, default projects |

Tests that pin today's gaps:
- `ImageMaterialRenderTests.testLightingNeedsSceneLightsAndFallsBack` (fixture `Tests/Fixtures/ImageMaterials/materials/lit.json`);
- `ImageMaterialSweepTests`, which tallies `unsupported[reason]`;
- `WEAuthoredValuesTests`:196-218 (bloom defaults);
- `BuiltinUniformTests`:117-125 (ambient and skylight pass through; the invented defaults are untested).

## 4. Plan

### 4.1 Principles

- **Run WE's own code.** The LightingV1 source comes from a port of WE's generator. Bloom and HDR run WE's `materials/util` passes through our shader translator, not hand-written Metal. The native `sceneFragment` bloom and the invented ambient defaults are deleted.
- **Keep app extras identity at their defaults.** `_owe_bloom` becomes a multiplier on WE's strength, with 1 = WE.
- **Per-scene state.** The light list, budget and targets belong to the wallpaper instance.
- **Bump `ShaderVariantTranslator.revision`** whenever translated output changes (A1, B2).

### 4.2 Order and ownership

Files are listed per package. Each file has one owner; a later package touches an earlier one's file only after it has landed.

```
L0 ─┬─ A1 ─┐
    ├─ A2 ─┼─ A3 ── A4
    ├─ B1 ── B2
    ├─ C1 ─┘ (A3's REFLECTION test needs C1)
    └─ D1 (after A2)            C2, D2 → with area 6
T (tester, lighting sweep) after A3/B2
```

Most-used first: **B1 (bloom, 24 scenes)** and **A1–A3 (lighting)** are the critical path; B2 (HDR, 5 scenes) next. C1 is small and unblocks меч. D1, C2 and D2 come last.

### 4.3 Work packages

**L0 — Format, values and seams (one agent, first, small). Done; what landed is in §4.4.**
- **Files:** new `Scene/Format/SceneLight.swift` (`WESceneLight`: kind enum with legacy `point`, every field of §1.1 with WE's defaults, bound values through `SceneRawValue`); `Scene/Format/SceneObject.swift` (the `light` key); `Scene/Format/SceneDocument.swift` and `Scene/Format/SceneValueFields.swift` (`hdr`, `bloomhdr*`, `lightconfig` as `WELightConfig`); `Scene/Values/SceneGeneralSettings.swift` (the HDR defaults of §1.2; `SceneBloomSettings` gains the HDR fields).
- **Seams, with no output change:**
  - new `Scene/Shaders/SceneEngineCombos.swift`: a value type {hdr, sceneOrtho, lightBudget, shadowQuality, cookie} and one function that turns it into combos, threaded through `ImageMaterialPlan`, `SceneEffectPlan` and `ParticleMaterialPlanBuilder`. For now it returns nothing, so there is no revision bump.
  - new `Scene/Rendering/SceneFrameLighting.swift`: the per-frame lighting value (ambient, skylight, packed arrays, all empty for now) that `SceneMetalRenderer` builds once per frame and passes to the uniform writers.
  - new `Scene/Rendering/ScenePostProcess.swift`: the post-process stage that `SceneMetalRenderer` calls after the scene pass. For now it wraps today's composite unchanged.
- **Tests:**
  - `SceneLightDecodeTests`: fixtures for each light type with defaults and bindings.
  - A library decode check: 11 lights (4 tube, 3 lpoint, 3 legacy point, 1 spot), 3 `lightconfig`s, 5 `hdr: true`, 70 `bloomhdr*`.
  - `WEAuthoredValuesTests`: the HDR defaults.

**A1 — The LightingV1 generator and light combos. Done** (revision 7). Shadow budgets don't translate yet: the prelude has no `sampler2DComparison`/`texSample2DCompare` for `_rt_shadowAtlas`, which comes with D2 (`LightingV1RequireTests.testShadowBudgetsNeedTheShadowAtlas`, an expected failure).
- **Files:** new `Scene/Shaders/LightingV1Require.swift`, a port of `re-lights/lightingv1_gen.py` (strings verbatim from `lightingv1_fragments.txt`, the cascade quirk included); `Shaders/ShaderSource.swift` (`stubRequires` → the generator, given the variant's combos; an unknown `#require` stays a logged comment); the `lightBudget` → `LIGHTS_*`, `LIGHTS_SHADOW_MAPPING*` and `LIGHTS_COOKIE` mapping, and `SCENE_ORTHO`, in `SceneEngineCombos+Lighting.swift` (§4.4). Bump the revision.
- **Tests:**
  - A text oracle: our output equals `lightingv1_gen.py`'s for a matrix of budgets (0/1/4/15 per type, with shadow and cookie subsets). Check the Python outputs in as fixtures.
  - `genericimage4`, `generic4`, `genericparticle` and the fluid-simulation combine translate and build pipelines under each budget.
  - `LIGHTING=0` emits nothing.
  - `ShaderVariantCacheTests` sees the revision bump.

**A2 — The light packer and frame lighting. Done.** `SceneLightPacker` reproduces the packer at 0x140190c80 on one flat buffer, cursors and all, and the legacy setter; `SceneFrameLighting.frame` feeds it each light's world matrix (`SceneFrameLighting.world`), and `BuiltinUniforms` serves the arrays by name (zero-padded to the shader's length) and the scene colours. They are frame-varying uniforms (`UniformProgram.timeVarying`). What the binary showed beyond §2.2:
- **Sort key:** the depth is `dot(object+0x128, ctx+0x160)`, and +0x128 is the light's **own `origin`** (relative to its parent; the world matrix is cached at +0xe0, 0x1401850a0), not its world position. The flags key is `flags & 3` (shadow 1, cookie 2). Ties keep scene order here; WE's `std::sort` leaves them unordered [?].
- **Visibility:** a light is packed only if it and every ancestor are visible (0x140185010), checked before the budget, so a hidden light doesn't use it.
- **Groups:** each group's cursor starts at its budget offset (points: shadowed at 0, plain at PS; spots: SSC 0, SC SSC, SS SSC+SC, plain SSC+SC+SS; directionals: shadowed at 0, plain at DS) and is never checked, so an overfull group writes over the next group or array. The spot group is `flags & (shadows ? 3 : 2)`. `g_LSpot_Exponent` gets only `.x`. The buffer is zeroed each frame.
- **Unused directional slots** get the direction (0, 1, 0, 0) (0x1401931bb, 0x140193530).
- **Legacy slots:** the constructor gives **every** light, whatever its type, the first slot 0–3 no earlier light holds, and slot 0 after that (0x1401903c4), so a legacy point's slot counts the lights before it in scene order. Each frame (0x14025d1f0) a legacy point writes (c·I, radius), or (0,0,0,1) when it or an ancestor is hidden, and its world position either way. The context starts with all slots zero. `g_LightsPosition` is `vec3[4]` in the shaders.
- **Rotation:** WE builds an object's rotation as `Rz(z)·Ry(y)·Rx(x)` (0x1401dd630). The 2D hierarchy carries no depth or tilt, so each light keeps its authored `origin.z`, `angles.x/y` and `scale.z` (`SceneLightDepth`); the z rotation is the renderer's 2D one, so a light turns with the layers it lights [?: the renderer turns `angles.z` clockwise, while WE's matrix turns +X toward +Y]. Parents contribute their 2D transform only, and camera parallax isn't applied to lights [?].
- **Not done:** the `g_LFeature_*` projections (a cookie spot's projection is D1's, shadows D2's) and `_alias_lightCookie`, whose source key is unknown (§5.6).
- **Files:** new `Scene/Rendering/SceneLightPacker.swift` (sort, budget and pack as in §2.2, from live world transforms after scripts and timelines; legacy `point` slots; `g_LightsColorPremultiplied`; the cookie alias); `SceneFrameLighting.swift` (filled); `Rendering/BuiltinUniforms.swift` (`g_LightAmbientColor`/`g_LightSkylightColor` from `general`, deleting the 0.2/0.3 defaults; the `g_L*` and `g_Lights*` arrays by reflection name). Light objects stay out of the draw list but take part in parenting and in the script object table, as `thisScene.getLayer` proxies with `origin`/`angles`/`visible`.
- **Tests:** packer unit tests with hand-derived arrays (the sort order across types, flags and camera depth; budget truncation; no `lightconfig` → empty; spot cosines and the −row0 direction; the tube's world `controlpoint`; a parented light following its parent; `visible: false` legacy slots = (0,0,0,1)); One piece girls' 4 tubes packed against values computed by hand from its `scene.json`.

**A3 — Lit image materials, direct path.**
- **Files:** `Loading/ImageMaterialPlan.swift` (drop `unsupportedCombos`; `NORMALMAP`/`PBRMASKS`/`*_MAP` from bound textures; `TEX1FORMAT` for rg88 normals; the `_rt_shadowAtlas`/`_alias_lightCookie` slots bound only under their combos); `Rendering/ImageMaterialUniforms.swift` and `Rendering/ImageMaterialRenderer.swift` (`g_NormalModelMatrix`, `g_EyePosition`, `g_ViewProjectionMatrix`, `g_Texture2Resolution`, the frame lighting from A2).
- **Tests:**
  - `ImageMaterialRenderTests`: a lit fixture with one point, one spot and one tube light against a CPU reference of `ComputePBRLightShadow` (Swift, float32) at chosen pixels; ambient-only gives `albedo · ambient`.
  - `testLightingNeedsSceneLightsAndFallsBack` is deleted.
  - `ImageMaterialSweepTests`: no "needs scene lights" reason is left.
  - A headless render of One piece girls (the `TimelineLibraryRenderTests` harness): `f1` is drawn through the WE path, with the brightness bands at the 4 tube x positions.

**A4 — The prelighting path (lit layers with effects).**
- **First, pin down the pass order at `0x140209540` in the binary.**
- **Files:** the image-layer build in `Loading/SceneWallpaperViewModel.swift` (the unlit albedo target `_rt_imageLayerAlbedo_<id>`, the effect chain, the final `fullscreenlayer`/genericimage pass with `PRELIGHTING`/`PRELIGHTINGDUALVERTEX` and the `g_Alt*` matrices) and `Rendering/EffectGraphRenderer.swift` (the final lit pass).
- **Tests:** witcher's two layers and Lofi Cafe draw through WE's path with no fallback. With ambient 1 1 1 and no `lightconfig`, witcher's first layer matches today's unlit output within 1/255. A fixture layer with an effect and a light matches the direct path where the effect is the identity.

**B1 — WE's LDR bloom chain.**
- **Files:** new `Scene/Rendering/SceneBloomChain.swift` (the 4 passes of §2.6 run from `materials/util` through the effect-pass machinery, with RGBA8 targets from `SceneRenderTargetPool`); `ScenePostProcess.swift` (`_rt_FullFrameBuffer` ← the frame, bloom, combine; then the existing colour/fade steps in WE's order); `Rendering/SceneShaders.metal`, `SceneComposite.swift` and the composite section of `SceneMetalRenderer.swift` (delete the 3×3 bloom and `userBloom × 1.2`; `_owe_bloom` multiplies strength); the typed `postprocessing` setting is in place since L0 (§4.4): B1 only reads `ScenePostProcess.Frame.settings.postProcessing.allowsBloom`.
  - The app's default is "enabled", which keeps today's behaviour. WE's own UI default is unknown [?] (§5.1); the user can change the setting under *Settings → Performance → Post-Processing*.
  - `g_TexelSize` = 1 / render size.
- **Tests:**
  - A Python and Swift reference of the 4 passes on synthetic frames (an impulse, a step, a gradient); the rendered chain matches it within 2/255.
  - Threshold, strength and tint respond live to user, script and timeline values.
  - `postprocessing = disabled` → no bloom.
  - A bloom sweep renders the 24 bloom scenes headless: finite, no fallback, and a frame-time budget.
  - Compare before and after to confirm that non-bloom scenes are unchanged.

**B2 — HDR.**
- **Files:** new `Scene/Rendering/SceneHDRChain.swift` (§2.6 HDR: up to 8 RGBA16F levels, the constants, D0/Di/Uk with bicubic, `combine_hdr_upsample`/`combine_dhdr_upsample`/`combine_srgb`); `ScenePostProcess.swift`; the scene-target format in `SceneMetalRenderer.swift` (RGBA16F when HDR is on); `SceneEngineCombos+HDR.swift` (`HDR=1` everywhere; bump the revision; §4.4); effect FBO and ping-pong formats in `EffectGraphRenderer.swift` (the frame-buffer class follows the scene format).
- **Output on macOS:** "ultra" writes linear values, so the final pass goes to an sRGB drawable view (`bgra8Unorm_srgb`) with `RV.x` = 1. "displayhdr" uses an `rgba16Float` `CAMetalLayer` with `wantsExtendedDynamicRangeContent` and a linear extended colour space, with `RV.x` = 1 and `RV.y` from the screen's EDR headroom. RV is our choice here [?], so name it in test-risks.
- **Tests:**
  - A reference of the mip chain (levels, strength normalisation, soft knee) on synthetic float frames.
  - The 5 HDR scenes render with `ultra` and fall back to LDR bloom with `enabled`.
  - An overbright fixture (emissive or `brightness` > 1) blooms only in HDR.
  - The LDR output is unchanged by B2.

**C1 — The mip-mapped frame buffer and the reflection setting.**
- **Files:** `Rendering/SceneSnapshotTracker.swift` and `SceneRenderTargetPool.swift` (a mipmapped copy after the main pass; `g_Texture3MipMapInfo` = mip count − 1 [?: verify at `0x140181cf8`]; cleared to (0,0,0,1) when the setting is off); the `reflection` setting.
- **Tests:** a unit test of the mip chain; меч renders with a visible reflection term (a CPU reference of §2.4 at a few pixels); the setting turned off gives no reflection.

**D1 — Volumetrics (2D first: Hinata).**
- **Files:** new `Scene/Rendering/SceneVolumetrics.swift` (volumes, back-face pass, ray-march, blur, combine per §2.8, the `RenderVar` packing, quality from the `volumetrics` setting).
- **Needs first:** the cookie source key (RE: the light parser near `0x14025da80` and the cookie alias assignment in the packer) and the volume meshes' construction.
- **Tests:** a reference of `volumetrics_front` along one ray; Hinata renders a cone of light that follows the spot's transform.

**C2 — Planar `_rt_Reflection`** and **D2 — shadows (atlas, casters, the cascade quirk):** with area 6 (depth buffer, models). There are no 2D library users.

**T — Tester (after A3 and B2).**
- A `LightingLibrarySweepTests` over the library (`OWE_LIBRARY`), listing every scene with lights, lit layers, bloom or HDR. For each it:
  - asserts there is no lighting or bloom fallback;
  - logs the packed light arrays and the chosen combos;
  - checks every frame for NaN and inf;
  - records the frame time.
- Adversarial fixtures: a budget exceeded, 5 legacy points, a light without `lightconfig`, a script moving a tube's `controlpoint`, bloom toggled by a user property mid-run.
- New "needs WE ground truth" entries in `docs/test-risks.md`: One piece girls, Hinata, the 2B HDR scene, and one plain bloom scene, captured at `postprocessing` ultra and enabled.

### 4.4 Seams (landed with L0)

L0 decoded the format and added the files, types and hook points below without changing what is drawn: the engine combos are empty, nothing is packed, no uniform reads the frame lighting, and the composite is the old one. A1, A2, B1, C1 and D1 can now start in parallel, and A3, A4 and B2 as their prerequisites land. Each file below has one owner.

**Decoded and resolved.** L0 owns these; the other packages read them and don't edit them.

| What | Where |
|---|---|
| `WESceneObject.light: WESceneLight?`: the kind (`WELightKind`, with WE's raw values) and every field of §1.1 as a `SceneRawValue`, keyed by `SceneLightValueField` | `Scene/Format/SceneLight.swift`, `SceneObject.swift`, `SceneValueFields.swift` |
| `WESceneGeneral.lightconfig: WELightConfig?`, with masked counts and `withShadowsDisabled` | `Scene/Format/SceneLightConfig.swift`, `SceneDocument.swift` |
| `hdr` and `bloomhdr*` as bindable `general` fields | `SceneValueFields.swift` |
| `SceneLight(_:in:)`: the fields resolved against the user properties, defaulting to `SceneLightDefaults` (the constructor's values) | `Scene/Values/SceneLightValues.swift` |
| `SceneBloomSettings.hdr: SceneHDRBloomSettings` and `SceneLightingSettings` (ambient, skylight, `lightConfig`), with their defaults in `SceneGeneralDefaults` | `Scene/Values/SceneGeneralSettings.swift`, `Rendering/SceneRenderContent.swift` |
| `SceneMetalContent.lighting: SceneLightingContent` (the settings, plus every `SceneLightObject` in scene order: object id, authored light and resolved light) and `SceneMetalContent.engineCombos`. Light objects aren't layers. Their transforms are in `content.transforms` and `content.motions`, like any other object's. | `SceneWallpaperViewModel.lights(in:context:)` |

**User settings.** L0 added all of these, so no later package needs to touch the settings store.
- `GlobalSettings` has WE's four quality settings:
  - `postProcessing`: disabled, enabled, **ultra** or **displayhdr**; default "enabled".
  - `reflections`: default on, as in WE.
  - `shadows` and `volumetrics`: `GSLightingQuality`, disabled…ultra = 0…4; default medium.
- Post-processing and reflection are stored under new keys (`postProcessingQuality`, `reflection`). The old keys hold values saved while the settings had no effect, when post-processing defaulted to "disabled".
- Settings now decode key by key, so adding a key no longer resets every setting.
- The engine sees them as `SceneRenderSettings` (`Rendering/SceneRenderSettings.swift`, with `allowsBloom` and `allowsHDR`):
  - `SceneMetalRenderer.renderSettings` is read per frame;
  - `SceneWallpaperViewModel.setRenderSettings` rebuilds the content;
  - `SceneWallpaperView` passes them in and follows changes.
- UI: *Settings → Performance* already has Post-Processing (disabled, enabled, ultra) and Reflections. In `Settings/PerformancePage.swift`, B2 adds a "Display HDR" entry and D1 a volumetrics picker. Each touches only its own control.

**Hook points and their owners.**

| Seam | File (owner) | How it is called now | What the owner adds |
|---|---|---|---|
| Engine combos | `Scene/Shaders/SceneEngineCombos.swift` (L0). `SceneEngineCombos(bloom:lighting:orthographic:settings:)` sets `hdr` (bloom, hdr and ultra or displayhdr), `sceneOrtho`, `lightBudget` (folded when shadows are off) and `shadowQuality`. | `SceneWallpaperViewModel.metalContent` makes one per content build and passes it to every `ImageMaterialPlanBuilder`, `SceneEffectPlanBuilder` and `ParticleMaterialPlanBuilder` (`sceneEngineCombos`). They lay `applied(to:)` over the resolved combos. | — |
| Light combos | `SceneEngineCombos+Lighting.swift` (**A1**, done) | called from `combos(for:)` | done: all nine `LIGHTS_*` counts when `material["LIGHTING"]` ≠ 0 (0 without `lightconfig`), `LIGHTS_SHADOW_MAPPING` and `_QUALITY` for a shadowed count, `LIGHTS_COOKIE` for a cookie count, and `SCENE_ORTHO` on every material of an orthographic scene |
| HDR combo | `SceneEngineCombos+HDR.swift` (**B2**): `hdrCombos(for:)` returns `[:]` | called from `combos(for:)` | `HDR=1` when `hdr` is set; bump the revision |
| Frame lighting | `Scene/Rendering/SceneFrameLighting.swift` and `SceneLightPacker.swift` (**A2**, done). `SceneFrameLighting.frame(_:input:)` returns the ambient and skylight colours (a script's `thisScene.ambientcolor` or `skylightcolor` wins) and the packed `arrays` by uniform name. | `SceneMetalRenderer` calls it once per frame, after scripts and timelines, and stores the result in `BuiltinFrameContext.lighting`, which `BuiltinUniforms` reads. `SceneFrameLightingInput` provides each object's live own transform (`local(id)`) and its parents' (`parentWorld(id)`), `isVisible(id)` (ancestors included), the scripts' scene colours, the user's shadows setting, the eye and the view forward. | done |
| Post-process | `Scene/Rendering/ScenePostProcess.swift` (**B1**, then **B2**). `encode(Frame)` draws the old composite, and `compositeUniform` holds the old bloom math. It owns the composite pipeline. | `SceneMetalRenderer` calls it after the scene pass and the frame stages. `Frame` holds the scene target, the drawable's pass, the placement uniform, `Bloom` (live values: scripts, then timelines, then the content; `hdr` included), `AppExtras` (`_owe_bloom`, `_owe_saturation`, `_owe_hue`, `_owe_blur`) and `settings`. | B1: `_rt_FullFrameBuffer`, `SceneBloomChain.swift` and the combine; honour `allowsBloom`; make `_owe_bloom` a strength multiplier; then the composite. Delete `sceneFragment`'s 3×3 bloom (`SceneShaders.metal`, `SceneComposite.swift`). B2: `SceneHDRChain.swift` and the float scene target in `SceneMetalRenderer.swift` and `EffectGraphRenderer.swift`. |
| Frame stages | `Scene/Rendering/SceneFrameStage.swift`: `protocol SceneFrameStage` (`encode(SceneFrameStageContext)`, `setContent`) and `SceneFrameStages.make(device:)`, which returns `[]` | `SceneMetalRenderer` runs the stages in order between the scene pass and the post-process. Each gets the scene target, the command buffer, the scene size, the frame's `BuiltinFrameContext` (lighting included) and the settings, and `setContent` on every content change. | **C1** adds the `_rt_MipMappedFrameBuffer` copy as the first stage and **D1** adds `SceneVolumetrics` as the second: one line each in `make`, the only line they share. Otherwise D1 owns the file and may extend the context. |
| Lit image materials | `Loading/ImageMaterialPlan.swift`, `Rendering/ImageMaterialUniforms.swift`, `ImageMaterialRenderer.swift` (**A3**) | unchanged: `LIGHTING` and `REFLECTION` are still refused | see A3 in §4.3 |
| Prelighting | `Loading/SceneWallpaperViewModel.swift` (the image-layer build) and `Rendering/EffectGraphRenderer.swift` (**A4**; in the latter, after B2's format change) | — | see A4 in §4.3 |
| Reflection copy | `SceneSnapshotTracker.swift`, `SceneRenderTargetPool.swift` (**C1**); the setting is `renderSettings.reflection` | — | see C1 in §4.3, run as a frame stage |

**Tests that pin the seams:**
- `SceneLightDecodeTests`: each light type from the survey objects in `Tests/Fixtures/Scenes/lights`, WE's defaults, bindings, `lightconfig` masking and folding, and the HDR and lighting settings.
- `LightingLibraryDecodeTests`: the library decodes to 106 scenes, 4 tube, 3 lpoint, 3 legacy point and 1 spot light, 3 `lightconfig`s, 5 `hdr: true` and 70 scenes with `bloomhdr*`.
- `SceneLightingSeamTests`: no combos, no arrays, and the lights in the built content; `ScenePostProcessTests`: the old composite uniform. Each owner replaces its "nothing yet" assertions as it fills its seam.
- `QualitySettingsTests`: the settings' defaults and the migration of saved settings.
- `WEAuthoredValuesTests.testGeneralDefaultsAreWEs`: the HDR and colour defaults.

## 5. Open points (all need the binary or WE ground truth)

1. The default for `postprocessing` in WE's settings UI (the engine writes "disabled" when the key is missing). The app defaults to "enabled" (today's look) and the user can change it; revisit once WE's UI default is known. The default of the `volumetrics` setting is also unconfirmed: the app takes shadows' "medium".
2. `g_TexelSize` for the bloom passes (inferred as 1 / render size) and the device values of `g_RenderVar0` for the HDR combine.
3. Whether `vt+0x8` on `_rt_FullFrameBuffer` is a frame copy (strongly implied), and what `[scene+0x158]` is.
4. `_rt_MipMappedFrameBuffer`'s mip count in LDR (reported as 1, which would disable roughness blur) and `g_Texture3MipMapInfo`.
5. The prelighting pass order for lit layers with effects (`0x140209540`).
6. The cookie texture's source key. (The default `intensity` is 0: §1.1.)
7. The shadow atlas depth format and the exact cascade fit.
