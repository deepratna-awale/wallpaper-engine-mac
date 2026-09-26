# WE-authored values audit

**Status: 2026-09-26.** Work queue item 2 in [`roadmap.md`](roadmap.md).

The rule: every default, threshold, range, step, option list, label and unit that Wallpaper Engine authors comes from WE's own data. We never invent them. The sources are:
- effect and material json
- shader annotations (`// {"material":…}` and `// [COMBO] {…}`)
- project.json `general.properties`
- the scene.json `general` block
- particle json
- SceneScript `createScriptProperties`

Where WE authors nothing, we use WE's own default and cite where it comes from.

**Verdicts:**
- **fix:** the value must come from WE.
- **fixed:** done in this pass. The test is `WEAuthoredValuesTests`.
- **keep:** an app-only feature that WE doesn't have.
- **unknown:** needs WE ground truth (a capture, or more reverse engineering).
- **handoff:** another agent owns the file.

**Ground-truth sources used:**
- **`wallpaper64.exe`** (the local install, disassembled to `we64.asm` in the session scratchpad):
  - the scene-settings constructor at 0x140186f84…0x1401870e3
  - the property table that maps `general` field names to offsets, at 0x14019a…0x14019b2a0
  - the camera-parallax update at 0x140189b0f…0x140189cc6, the per-object displacement at 0x14018b062…0x14018b14e, and the load-time reset of an orthographic camera at 0x14018866b
  - the camera-shake routine at 0x140199580…0x14019977c
- **`bin/wallpaperui.exe`**: the editor's shader-annotation parser at 0x14046cdc9…0x14046d0bf (`range`, `linked`, `position`, `int`, `direction`, `nobindings`, `conversion`).
- **`ui/dist/scripts/scripts.js`**: WE's browse sidebar and the property editor.
  - The slider row uses `step:property.step||1, precision:property.precision||1`.
  - `EditorUserPropertyDetailsModalCtrl` creates sliders as `min 0, max 1` and saves `precision` as the decimals plus 1, with `step = 0.1^(precision-1)`.
  - The material slider uses `step 0.01, precision 2`; an `int` material slider uses step 1.
  - The linked slider links while x == y.
- **`assets/scripts/jsclasses/baseclasses.js`**: WE's `createScriptProperties` and `_Internal.updateScriptProperties`.
- **`locale/ui_en-us.json`**: WE's English text for the `ui_…` label keys.
- **WE 2.8.0.42's editor on Windows** (the user's screenshots, 2026-09-26): §7.

## 1. Effect parameters (inspector) — fixed

| Location | Was | WE's source | Verdict |
|---|---|---|---|
| `SceneEffectParameters.parameter` — range with no `range` annotation | `min(0, default)` … `max(1, 2 × default)` | `wallpaperui.exe` 0x14046cef9: `min = 0`, `max = 1.0f` | fixed (`SceneEffectParameters.defaultRange`) |
| `SceneEffectParameters.parameter` — default | components padded with the last value | the renderer's parse (`ShaderConstantResolver`): missing components are 0 | fixed; the test compares against the resolved constant |
| `SceneInspectorView.makeEffects` — slider range | widened to include the current value | the annotation range as is; the number field accepts values outside it | fixed (`clampsTypedValue: false`) |
| `SceneInspectorView` — colour control | any key containing "color" | annotation `"type":"color"`; values are 0…1 (the 255 guess is gone) | fixed |
| `SceneInspectorView.isPercentage` | "(%)" appended by key name | WE shows no unit | fixed (removed) |
| `SceneInspectorView` — slider step and decimals | continuous, 3 decimals | step 0.01 and 2 decimals; `int` uses step 1 and 0 decimals | fixed |
| `SceneInspectorView` — `linked` vec2 | two independent sliders | a link toggle that starts linked while x == y and moves both together | fixed |
| `SceneInspectorView` — `[COMBO]` with a `material` key | not shown | a checkbox, or a picker with the authored options in authored order; the choice is stored under `combo_<NAME>` and applied by `SceneEffectPlanBuilder.comboOverrides` | fixed |
| `SceneInspectorView` — combos with `"type":"imageblending"` (`BLENDMODE`) and no `options` | not shown | WE's editor list (`wallpaperui.exe` 0x140160040): 33 modes in its order and groups, §7.2 | fixed (`WEImageBlendModes`); an image layer's own `colorBlendMode` gets the same picker |
| `SceneInspectorView` — a combo's `require` (for example `RIMLIGHTING` needs `LIGHTING=1`) | — | WE hides a combo whose requirements don't hold | fixed |
| Labels | `ui_editor_properties_x` turned into words | WE's `locale/ui_en-us.json` (`WallpaperEngineLabels`), when an install is configured; the words are the fallback | fixed |

## 2. project.json properties (sidebar) — fixed

| Location | Was | WE's source | Verdict |
|---|---|---|---|
| `SceneUserPropertiesView.load` — `min`/`max` when absent | 0 / 1 | WE's editor creates sliders as 0 / 1 | kept; now cited (`UserPropertyDefinition.defaultSliderRange`) |
| `UserPropertySliderFormat.effectiveStep` | continuous when there is no step | `step || 1` | fixed |
| `UserPropertySliderFormat.fractionDigits` | `precision`, or 3 | `precision − 1` (WE saves the decimals + 1), or 1 → 0 decimals | fixed |
| sidebar slider | the step wasn't passed to the slider | the slider snaps to WE's step | fixed |
| `usesDegrees` for ids ending `_direction` | shown in degrees ×180/π | WE shows the raw value | fixed (the name heuristic is gone) |
| property `text` and combo option labels | turned into words | WE's translation, then words | fixed |
| `_owe_*` sliders (hue, saturation, bloom, blur, speed, parallax, text size and opacity) | app ranges, continuous | not in WE | keep: app extras, 0.01 step; identity at their defaults, so they never change WE's values untouched |
| `undeclaredVisibilityToggles` | invents bool properties for undeclared `visible` bindings | WE shows only declared properties | keep (app affordance); shown under Wallpaper Settings, which is **unknown** whether acceptable |

Parsing moved to `UserPropertyDefinition`, which has unit tests. It is also checked against every library project.json.

## 3. scene.json `general` — fixed defaults and runtime

| Field | Was | WE's default (`wallpaper64.exe` constructor) | Verdict |
|---|---|---|---|
| `bloomstrength` | 1 | 2.0 (offset 0x3bc) | fixed (`SceneGeneralDefaults`) |
| `bloomthreshold` | 0.7 | 0.65 (0x3c0) | fixed |
| `bloomtint` | 1 1 1 | 1 1 1 (0x3d8…0x3e0) | kept |
| `bloomhdrstrength` / `threshold` / `feather` / `scatter` / `iterations` | not read | 2.0 / 1.0 / 0.1 / 1.619 / 8 (0x3c4…0x3d4) | unknown: the HDR chain isn't implemented (roadmap 5.4) |
| `camerashakespeed` / `amplitude` / `roughness` | 0 | 3.0 / 0.5 / 1.0 (0x328 / 0x32c / 0x330) | fixed default; the renderer now uses them (`SceneCameraShake`, below) |
| `cameraparallaxamount` / `delay` / `mouseinfluence` | 0 | 0.5 / 0.1 / 0.5 (0x334 / 0x338 / 0x33c) | fixed default; the renderer now uses them (`SceneCameraParallax`, below) |
| `gravitydirection`, `winddirection`, `windstrength` | not read | (0, −1, 0); (0.707, 0.707, 0); 1.0 | unknown: no consumer yet |
| fog fields | not read | distance 1…5, height 1…−3, densities 1 | unknown: no consumer yet |
| `SceneMetalRenderer` composite bloom threshold without WE bloom | 0.55 | WE's default 0.65 | fixed |
| `SceneMetalRenderer` `userBloom × 1.2`, `userBlur × 4` | app constants | `_owe_bloom` / `_owe_blur` are app extras | keep |

**Camera parallax — fixed** (`SceneCameraParallax`, roadmap 8.16). The invented `0.18 × depth × cursorDelta × sceneSize × amount × influence` model and its `perspective` zoom are gone. WE's model, from `wallpaper64.exe`:
1. The scene update (0x140189b0f…0x140189cc6) runs it while flag 0x100 (`cameraparallax`) is set. The influence is `cameraparallaxmouseinfluence`; WE uses 0 while its input flags 0x200200 are set, which we don't model.
2. `cursor = clamp((x, 1 − y), 0, 1)`; our cursor is already y-up.
3. `target = eye.xy + size · (cursor · influence + 0.5 · (1 − influence))`. An orthographic scene without camera paths has its authored eye reset to 0 at load (0x14018866b), so `eye` is only the camera shake, applied just before.
4. With `delay > 0`: `pos += (target − pos) · min(1, (1 − delay / 3) · 10 · dt)`. Otherwise `pos = target`. At load `pos` is the scene centre (0x140188715).
5. `g_ParallaxPosition = clamp(pos / size, 0, 1)`, and (0.5, 0.5) until parallax runs (0x1401886ea). A flag at 0x800 mirrors x; we don't model it.
6. When flags 0x108 are both set (parallax on, orthographic scene), the render loop (0x14018b062…0x14018b14e) translates every object by `amount · (root.origin.xy − pos) · root.parallaxDepth.xy`. `root` is the object's topmost ancestor (the parent chain at +0x180), so a child moves with its root. The mouse hit test at 0x14018a0b3 uses the same offset. A perspective scene isn't displaced.

**Units — measured.** `pos`, `eye` and `size` (+0x340, +0xf0, +0x354) are all scene units, so the displacement is scene units too, and with depth 1 a full cursor sweep moves an object by `−amount · influence · size`. WE 2.8.0.42 on Windows at 1920×1080, on 3802047741 (orthographic 1920×1080, amount 0.5, influence 0.17, no `parallaxDepth`): left edge → centre −82 px, left → right −164 px, opposite to the cursor and linear, about 2 px vertical drift. The model gives −81.6 and −163.2. The headless render of that wallpaper through `SceneMetalRenderer` gives −82 and −163 at 1920×1080 (−163 and −327 at 3840×2160 with the cursor in points), with or without its 0.1 delay once settled, and 0 px vertically. The shake reads the same projection height (+0x358), so its orthographic offset is scene units too: `amplitude · 0.1 · 0.1 · height`, 5.4 units for amplitude 0.5 at 1080. Tests: `SceneCameraMotionTests.testParallaxSweepMatchesWEsMeasurement`, and `CameraParallaxLibraryTests` on the wallpaper itself (skipped without the library).

The app's `_owe_effect_enabled_parallax` toggle and `_owe_effect_parallax_amount` (default 1, a multiplier on WE's amount) are kept as app extras. Tests: `SceneCameraMotionTests` checks the formulas against hand-derived values and a rendered frame.

**Camera shake — fixed** (`SceneCameraShake`). The invented `47.3 / 71.9 / 53.1 / 83.7` Hz sines are gone. WE's routine is 0x140199580, called by the scene update while flag 0x80 (`camerashake`) is set:
1. `t = speed² · g_Time`. The time is the scene clock at +0x130 of the render context, which the particle oscillate operators also read.
2. `v = (cos t, sin(1.333 t), sin t)`. An orthographic scene zeroes z.
3. With `r = roughness³` above 0.001 and not 1: `v = v / |v| · |v|^r`.
4. `v` is scaled by `amplitude · 0.1`, and in an orthographic scene also by `0.1 · projection height`.
5. The eye and centre both move by `v`, so the scene moves by `−v`. The parallax target includes the shaken eye.

**Text and shape layers — fixed.** Both now read their object's `parallaxDepth`, with WE's default 1 1 (`SceneWallpaperViewModel.parallaxDepth(of:)`). Previously both were built with `.zero`. The preview and video layers stay at 0: they aren't WE objects, and their content has no camera.

**Still open:**
- Particle systems aren't moved by parallax or shake. They should be, since WE's render loop displaces every object, and the shake moves the camera. This belongs to the particle agent's files.
- Camera paths (`camera.paths`) aren't implemented, so the eye is always 0 in an orthographic scene.
- A perspective scene's `g_ParallaxPosition` uses our 1920×1080 stand-in size. **unknown**
- A layer's `perspective` flag is carried but unused now that the invented zoom is gone. WE uses it for its perspective draw, not for parallax.

## 4. SceneScript `createScriptProperties` — fixed

| Location | Was | WE's source | Verdict |
|---|---|---|---|
| `AudioReactiveScriptEngine` shim | replaced WE's builder: combo default = `o.value` (undefined), no `_config`, every authored key copied | WE's builder: combo = `options[0].value`, `_config` with label/min/max/int/options; `_Internal.updateScriptProperties` applies declared keys only and turns a colour string into a `Vec3` when the default is one | fixed (`SceneScriptPropertiesShim`) |
| `scriptproperties` bound to a user property (`{"user":…,"value":…}`) | unresolved | WE resolves them through the user property | handoff: SceneScript agent (docs/scenescript-plan.md, WP for script instances) |

## 5. Name heuristics and native approximations

| Location | Value | Verdict |
|---|---|---|
| `SceneWallpaperViewModel.materialEffects` | read material constants by name (`brightness`/`intensity`/`gain`, `strength`/`glow`, `radius`/`sigma`, `threshold` → 0.7…) into the native image draw; bloom and blur defaulted to 1 when the shader *name* contained "bloom"/"blur" | **fixed**: removed. Every layer gets `SceneMaterialEffects.identity`, and material constants reach WE's own shader through `ImageMaterialPlan`. No library image layer matched a guessed name, so nothing regresses: the image material sweep is unchanged. Test: `SceneLayerKindTests.testMaterialConstantsAreNotGuessedIntoNativeAdjustments`. Follow-up: `SceneMaterialEffects` is now constant and can be deleted, along with the native shader's adjustment uniforms |
| `SceneWallpaperViewModel.buildMetalTextLayer` | `pointsize ?? 24`, `padding ?? 0` | unknown: every corpus text object authors both. WE's text defaults weren't located (the text property table is at 0x14025…, and the pointsize offset isn't mapped yet) |
| `SceneUserPropertiesView` text extras | size 1…256, colour `1 1 1` tint, opacity 1 | keep: app extras, multiplicative identity at their defaults |
| `SceneInspectorView` move / scale | 0.05…5×, 1/10/50 px steps | keep: app editing tools, not a WE value |
| video music sync (`VideoMusicSyncSettings`) | zoom 0…0.5, pace ±1, tilt ±15°, saturation −1…2 | keep: app-only feature |
| inspector and sidebar "Music Amount" | ± the slider span | keep: app-only feature |
| `AudioSpectrum` (was LWE's `maxStep 0.3`, `0.35·log10`, tilt) | LWE's FFT shaping | fixed: WE's pipeline from `wallpaper64.exe` (block DFT and bands `0x1400d02b0`, gain and smoothing `0x140111654`; `Audio/AudioSpectrum*.swift`) |
| `SceneMetalRenderer` `_owe_speed` | scales the scene clock | keep: app extra; roadmap 8.4 covers the clock problems |

## 6. Particles — fixed

Particle systems now compile their initializers and operators into records the way `wallpaper64.exe`'s particle parser (0x1401c1c70) does, and the CPU (`ParticleProgramCPU`) and GPU (`ParticleProgram.h`) run them in authored order. Every default below is WE's own: it fills each element's json before parsing, with one filler per element (cited in `ParticleSystemBuilder`, `ParticleInitializerBuilder`, `ParticleOperatorBuilder`). Where two values are given, the first is for an orthographic (2D) scene and the second for a perspective one; the parser's flag comes from `orthogonalprojection` (0x14010daa0, 0x14018768a). The reverse-engineering notes are `re/initializers-spec.md` and `re/operators-spec.md` under the session's derived data.

**Emitters** (`ParticleSystemBuilder.emitterShape`):

| Field | Was | WE's value | Verdict |
|---|---|---|---|
| `rate` | ?? 100 | 10 (0x1401b8e59) | fixed |
| `distancemax` | ?? 0 | sphere 256 / 1 (a scalar); box "256 256 0" / "1 1 1" (0x1401b9100, 0x1401b9520) | fixed |
| `distancemin` | ⚠ x only, as a ratio | sphere: a radius (scalar), 0; box: a per-axis shell, "0 0 0" | fixed |
| `directions` | ?? (1, 1, 0) | sphere "1 1 0"; box "1 1 0" / "1 1 1" | fixed |
| emitter `name` | ?? "sphererandom" | sphererandom unless `boxrandom` | kept |
| `instantaneous` | ?? 0 | 0; the burst also comes out of the rate's carry (0x140237a06) | fixed |
| `speedmin` / `speedmax` | ?? 0; swapped if reversed | 0 / 0, as authored; radial from the centre, set (0x140237c14) | fixed |
| `sign` | ?? 0 | "0 0 0"; applied by flag 1, which a non-zero sign sets (0x1401c61e7) | fixed |
| `cone` | not read | 0: `u` from −cos(cone·π) (0x1401c61ba) | fixed |
| sphere spawn | uniform in a ring | radius `dmin + cbrt(r)·|v·directions|·(dmax − dmin)` (0x140237c14) | fixed |
| system `maxcount` | ?? 1000 | no default: 0 | fixed |
| `starttime` | not read | pre-simulated in 0.05 s steps (0.2 s from 500 particles; 0x14022f2e0) | fixed |
| system `flags` 8…0x80 | not read | switch off the colour, speed, count, lifetime and size overrides | fixed |
| a second emitter | ignored (logged) | WE runs every emitter record in order, each with its own rate, carry, burst, clock and per-period count, counting what the earlier ones spawned (0x1402378a0) | fixed (CPU, GPU, instances) |

**Initializers:** lifetime is set; size, colour and alpha multiply WE's base values (lifetime 1, size 0.5, the instance colour and alpha; 0x14023b340); velocity, rotation and spin add. Two of a kind both apply.

| Initializer | Was | WE's value | Verdict |
|---|---|---|---|
| `lifetimerandom` | 1…1 | 0…1, `exponent` 1, at least 0.001 | fixed |
| `sizerandom` | 20…20 | 5…50 / 0.001…1, times the base 0.5 | fixed |
| `alpharandom` | 1…1 | 0.05…1 | fixed |
| `colorrandom` | ?? (1, 1, 1) | "0 0 0"…"255 255 255" ÷ 255, one random for the three channels | fixed |
| `hsvcolorrandom` | ⚠ treated as RGB | hue 0…1 in `huesteps` 6 steps, saturation 0.5…1, value 0.5…1, HSV→RGB (0x1401b8c70) | fixed |
| `colorlist` | not read | a random colour of the list, jittered in HSV by the noises | fixed (up to 4 colours, more logged) |
| `normalizedParticleColor` | ⚠ ÷255 when > 1 | removed: `colorrandom` always ÷ 255, `colorchange` never | fixed |
| `velocityrandom` | 0 | "−32 −32 0"…"32 32 0" / "−1 −1 −1"…"1 1 1", one random per axis | fixed |
| `turbulentvelocityrandom` | 0; added to the range | 1D simplex noise turns `forward` about `right`; speed 100…250 / 0.5…1, phase 0…0.1 | fixed |
| `rotationrandom`, `angularvelocityrandom` | ⚠ z only | z is the 2D axis; a bare number is (0, 0, n); 0…2π and −5…5 | fixed |
| `positionoffsetrandom` | a random box | fBm of 2D simplex noise of the position and time; scale 0.001 / 1, distance 100 / 0.1, octaves 6 | fixed |
| `inheritcontrolpointvelocity` | not read | the control point's velocity × 0.1…0.2 | fixed |
| `mapsequencebetweencontrolpoints` | count ≥ 2; ⚠ arc × 0.5 | count 32 (step 1/(count − 1)), arcamount 0.3, sizereductionamount 0.9, flags 1/2/4/8, 16 (count override), 32 (restart each period) | fixed |
| `mapsequencearoundcontrolpoint` | a helix from the span | radius and height kept from the emitter, angle from the sequence; count 32, flags 1 (count override), 2 (restart each period) | fixed |
| `remapinitialvalue` | output ?? size; input range 0…1 | WE's full remap: multiply, `maxlifetime` → `size` by default, every input, output, component and transform | fixed |
| `inheritinitialvaluefromevent` | setcolor | setcolor | kept |

**Operators:** size, alpha and colour start from their base values every frame and the operators multiply them (0x14023fc08…0x14023fc99). Only `movement` moves particles by their velocity. Blend windows (`blendinstart` … `blendoutend`, 0x1401c2a40) switch an operator to its blended form.

| Operator | Was | WE's value | Verdict |
|---|---|---|---|
| `movement` `gravity` | ⚠ z if non-zero, else y | "0 0 0", in the system's space; flag 1 gives it in the scene | fixed |
| `drag` | linear `1 − drag·dt` | `v·(1 − min(drag·dt', 1))`, after the position step; dt' = dt·`pow(min(0.025 / frame time, 1), 0.7)`, the engine's frame time [engine+0x14c] (SceneScript's `engine.frametime`). `angularmovement` damps, and `controlpointattract`, `turbulence`, `vortex`, `vortex_v2`'s spin and `boids` push, by dt' too. At an fps limit ([engine+0x148], the settings' `fps`, 0x1401114f1) of 1…20 the VM runs twice with dt/2 (0x140237724…0x140237793) | fixed |
| `alphafade` | fadeout ?? 1 (none) | 0.5 / 0.5, fractions of the life | fixed |
| `sizechange` / `alphachange` / `colorchange` | 0 → 1, values 1 | start 1 (colour "1 1 1"), end 0 ("0 0 0"), times 0 → 1 | fixed |
| `angularmovement` | integrated always | force 0, drag 0; only this operator spins | fixed |
| `oscillate*` | ⚠ range middles | one random per particle for frequency, phase and scale; frequency 1…5 / 1…10, scale 0…10 (0.5) / 0…1 / 0.8…1.2 | fixed |
| `remapvalue` | ⚠ drives alpha unless velocity | multiply, `lifetimefraction` → `size`; every input, output and transform (FastNoise2 simplex and fBm) | fixed |
| remap control points | outputs 7, 8, 16…18 not written; inputs 17/18 particle → point | outputs move the particle (distance, fraction between the output points, delta, direction) or write the point into the shared array, once per group of four particles in the operator (0x140246781); inputs run particle → point; the initializer's point inputs zero the point first (0x14023d31d); written points persist as the next step's previous points; reductions leave vector outputs alone | fixed (CPU; GPU in one thread for such programs) |
| `vortex` | distanceouter 1000 | 500 / 1 … 650 / 2, speed 2500 / 1 … 0, axis "0 0 1" | fixed |
| `vortex_v2` | = vortex | adds centre force (flag 2) and a ring (flag 4): radius 300, width 50, pull 50 / 10 | fixed |
| `boids` | threshold 150; ~256 neighbours | separation 20, neighbours 50, maxspeed 500, factors 15 / 1 / 2; WE's time slicing | fixed |
| `reducemovementnearcontrolpoint` | outer 100 | inner 100 / 0.5, outer 350 / 1, reduction 100 … 0 | fixed |
| `maintaindistancetocontrolpoint` | pulls velocity | moves with the point and keeps `distance` 200 / 1 | fixed |
| `maintaindistancebetweencontrolpoints` | stiffness 10 | carries each particle with the moving segment | fixed |
| `turbulence` | scale 0.005, speed 500…1000, timescale 0.01; ⚠ `phasemax` ignored | scale 0.01 / 0.5, speed 500…1000 / 1…5, timescale 20 / 1, 3D simplex noise; `phasemax` × the particle's random (`phasemin` WE never reads) | fixed |
| `controlpointattract` | scale 100, threshold 1000 | 512 / 20, 512 / 5, flag 2 (no overshoot), delete within 15 / 0.5 (flag 1) | fixed |
| `capvelocity` | cap | 100 / 1 | fixed |
| `inheritvaluefromevent` | set/multiply only | setcoloropacity; every verb, each step | fixed |

**Renderer:**

| Field | Was | WE's value | Verdict |
|---|---|---|---|
| trail length | ⚠ 1 in the simulation, 0.05 / 10 for the shader | one value: `spritetrail` `length` 0.05, `maxlength` 10, `minlength` 0 (the shader's stretch); `ropetrail` `length` 1 s of history | fixed |
| `subdivision` | ⚠ 4 in the simulation, 0 for `TRAILSUBDIVISION` | `rope` 4, `ropetrail` 1, clamped 0…32, for both | fixed |
| `segments` | ?? 4 | 4 | kept |
| built-in trail | `speed · 0.08` | WE's stretch, as the shader | fixed |
| particle size | the shaders read half | WE's size (the base 0.5 × the random) is the quad's width everywhere | fixed |
| refract-amount opacity 0.04…1 | heuristic | built-in draw only | keep (it only affects the fallback draw) |
| `orientation`, `axis`, `flags` | not read | screen / upright / fixed axes for `g_Orientation*` (0x1402298b0; flag 1: the axis in the scene), the rope's ORIENTATION combo | fixed |
| rope `uvscale` / `uvsmoothing` / `uvscrolling` | not read | the rope builder's layout (0x14023099e): expected points rate × lifetime (capped at the fps limit while filling), smoothing (default on) slides the texture as the oldest point dies, scrolling shifts it by the dead, the count ÷ uvscale; a scrolling `ropetrail` takes TRAILSCROLLALPHA and WE's `g_RenderVar0` | fixed |

**Control points** (0x14022e3e0): read by index (WE ignores `id` and `locktopointer`); flag 1 follows the cursor, flag 2 is a scene position (not for control point 0), flag 4 copies the parent system's `parentcontrolpoint`. Flag 16 is set by 10 WE assets (the dripping-water presets, on the points their instance override drives), but the runtime never reads it: the point's flags are tested only for 1, 2, 4, 8 and the parser's 0x10000 (0x14022e461, 0x14022a08c, 0x14022e66e, 0x14022a765, 0x14022bf26). It is a plain point here too.

**Units:** the particles simulate in their system's space (WE's model matrix, 0x14023761b…0x14023767a): velocities, gravity, forces and every distance scale and turn with the object. A `worldspace` system simulates in the scene; its spawn offsets and velocity initializers turn with the emitter (the control point matrix).

**Children, audio, collision:** children `maxcount` 10, `probability` 1, type static (kept); audio `audioprocessingbounds` "0.8 1.0", `exponent` 2, frequency 0…1 (kept); collision defaults 2D / 3D: plane at −150 / 0, sphere at "0 −200 0" / origin with radius 50 / 1, quad "0 −150 0" / origin of 200 × 200 / 1 × 1, bounce 0.5, push-out × 1.05 (kept, now cited).

**Instance overrides:** unchanged (1 by default, no clamps: WE has none either); the system's flags switch parts off.

**Camera:** particle systems now move with camera parallax and shake as every WE object does (their emitter's transform takes the layer's offset).

## 7. WE 2.8.0.42's editor (ground truth)

Checked against the editor itself (screenshots of WE 2.8.0.42 on Windows).

**7.1 Rotation — fixed.**

| Field | Editor | Ours | Verdict |
|---|---|---|---|
| `angles.z` = +30° | turns the object counter-clockwise | counter-clockwise since dc179e3 (WE's `Rz(z)·Ry(y)·Rx(x)`, 0x1401dd630) | confirmed |
| `angles.x` = 30° (orthographic scene) | squashes the object vertically by cos 30°, no perspective | was ignored | fixed: `SceneAffineTransform` takes the x and y rows of WE's rotation without their z (+x → (cy·cz, cy·sz), +y → (sx·sy·cz − cx·sz, sx·sy·sz + cx·cz)) |
| `angles.y` = 30° | squashes it horizontally by cos 30° | was ignored | fixed, as above |

The tilt comes from the authored angles, user bindings, timelines and scripts (`SceneLocalTransform.tilt`). Tests: `SceneTransformTests` (the squashes, the counter-clockwise turn, and all three angles against WE's 3D rotation projected). Still open: a parent's tilt composes with its children as projected 2×2 matrices, not as WE's 3D matrices, so a child tilted back against a tilted parent doesn't straighten; a perspective scene is drawn with the same orthographic squash (no perspective camera yet).

**7.2 Blend modes — fixed.** The editor lists 33, Normal the default: under "Native (fast)" Normal, Add; under "Emulated (slow)" Tint, Darken, Multiply, Color burn, Linear burn, Darker color, Lighten, Screen, Color dodge, Linear dodge, Lighter color, Overlay, Soft light, Hard light, Vivid light, Linear light, Pin light, Diffuse light, Hard mix, Difference, Exclusion, Subtract, Reflect, Glow, Phoenix, Average, Negation, Hue, Saturation, Color, Luminosity. `wallpaperui.exe` 0x140160040 fills that menu, pairing each `ui_editor_blending_*` key with its `BLENDMODE` value, and the values select the branches of `ApplyBlending` in `common_blending.h`:

| Mode | Value | Mode | Value | Mode | Value |
|---|---|---|---|---|---|
| Normal | 0 | Screen | 7 | Hard mix | 17 |
| Add | 31 (`A + B·opacity`) | Color dodge | 8 | Difference | 18 |
| Tint | 30 | Linear dodge | 9 (`BlendAdd`) | Exclusion | 19 |
| Darken | 1 | Lighter color | 10 (`max`) | Subtract | 20 |
| Multiply | 2 | Overlay | 11 | Reflect | 21 |
| Color burn | 3 | Soft light | 12 | Glow | 22 |
| Linear burn | 4 (`BlendSubstract`) | Hard light | 13 | Phoenix | 23 |
| Darker color | 5 (`min`) | Vivid light | 14 | Average | 24 |
| Lighten | 6 | Linear light | 15 | Negation | 25 |
| | | Pin light | 16 | Hue, Saturation, Color, Luminosity | 26…29 |
| | | Diffuse light | 32 (`A + A·B`) | | |

The inspector shows `imageblending` combos and an image layer's `colorBlendMode` as that list, with WE's labels (`locale/ui_en-us.json`, English text as the fallback) and groups; the layer's choice is saved with its edited object. Tests: `WEImageBlendModesTests`, `WEAuthoredValuesTests`.

**7.3 User properties per display — fixed.** In WE the same wallpaper on two displays has independent user properties: its UI keeps them per monitor (`currentSelection.properties[selectedMonitor.location]`, `ui/dist/scripts/scripts.js`). WE's UI scripts have no setting named "sync properties": the closest is the layout, "Wallpaper per display" (0, independent properties) or "Clone single wallpaper" (2, one wallpaper and one set of properties on every display). Ours: each display has its own store, and Settings → General → "Sync properties across displays" (default **off**, WE's per-display behaviour) makes them share one. Displays whose properties are equal still share one running instance; different properties run separate instances, and a wallpaper still plays its sound once (from the instance on its audible display). Details in `architecture.md` ("Wallpaper instances"). Tests: `WallpaperPropertyScopeTests`.

**7.4 A new particle system — no change.** The editor creates a system from WE's own template, `particles/example.json`. Those are template values the editor writes into the new system's json, not what `wallpaper64.exe` assumes for an absent field, so our parse defaults (§6) stay:

| Field | Editor template | WE's parse default for an absent field (ours) |
|---|---|---|
| `maxcount` | 500 | none: 0 |
| emitter | `sphererandom` | `sphererandom` |
| `distancemin` … `distancemax` | 32 … 512 | 0 … 256 (2D) / 1 (3D) |
| `directions` | 1 1 0 | 1 1 0 |
| `rate` | 20 | 10 |
| `speedmin` / `speedmax` | 0 | 0 |
| `lifetimerandom` | 3 … 5 | 0 … 1 |
| `colorrandom` | 255 255 255 … 255 255 255 (white) | 0 0 0 … 255 255 255 |
| `sizerandom` (template, not in the screenshots) | 50 … 200 | 5 … 50 / 0.001 … 1 |
| `velocityrandom` (template) | ±50 ±50 0 | ±32 ±32 0 / ±1 |
| operators | `movement`, `alphafade` | — |
| `alphafade` | fade in 0.5 (fade out absent: 0.5) | 0.5 / 0.5 |
| material | `particle/halo.json`: additive | a material without `blending`: translucent |
| overbright | 1 | `g_Overbright`'s annotation default, 1 |

Test: `ParticleEditorTemplateTests` runs the template and gets the editor's values; `ParticleProgramTests` keeps the parse defaults.

**7.5 Clamp UVs on import — no change needed.** WE's importer turns Clamp UVs on by default and writes it into the `.tex` (TEXI flags bit 2). The renderer reads that flag alone: a flagged `.tex` clamps, an unflagged one repeats, an image that isn't a `.tex` clamps, and the object's `clampuvs` can only add clamping (`ImageMaterialPlanBuilder.textureClamps`). Nothing assumes the opposite default. Test: `TexClampUVsDefaultTests`.

**7.6 Light sliders — noted.** The editor's ranges: intensity 0…25, radius 0…30, falloff 0…4, cone 0…180 (degrees). Our inspector doesn't expose light properties (lights are read from scene.json only), so there is nothing to range yet; an inspector for lights should use these.

## Tests

`OpenWallpaperEngineTests/WEAuthoredValuesTests.swift`:
- `testEveryEffectParameterIsItsAnnotation` walks every bundled effect and every effect shipped in a library wallpaper. For each parameter it checks:
  - the default, range, label, `int`, `type: color` and `linked` against the annotation
  - the default against the constant the renderer resolves
  - every combo's default and options against its `[COMBO]` annotation
- `testEveryLibraryPropertyIsAuthoredValue` checks every library project.json property: min, max, step, precision, value and option labels.
- `SceneCameraMotionTests` checks camera parallax (target, delay easing, `g_ParallaxPosition`, per-object offset) and camera shake against values worked out from `wallpaper64.exe`, and checks a rendered frame's parallax displacement.
- Unit tests cover:
  - project.json parsing (WE's defaults when a field is absent)
  - WE's label table
  - the `general` defaults, with authored values winning
  - the inspector combo override
  - `createScriptProperties` defaults and `scriptproperties` injection, run against WE's own `baseclasses.js`

`OpenWallpaperEngineTests/ParticleProgramTests.swift` checks WE's particle defaults per element (2D and 3D), two operators of a kind, the oscillators' per-particle random, `hsvcolorrandom`'s hue steps, the remap default, movement in the object's units, sequences restarting each period and `starttime`. `ParticleSimulationParityTests` runs every operator and initializer kind on both simulations, several emitters and the low-frame-rate drag and half steps among them. `ParticleRendererOptionsTests` checks the orientations and the rope layout; `ParticleRemapControlPointTests` the remap's control point inputs and outputs and their write-back, on both simulations.

The editor's ground truth (§7) is checked by `SceneTransformTests` (angles), `WEImageBlendModesTests` (the blend-mode list against `common_blending.h` and WE's labels), `WallpaperPropertyScopeTests` (per-display stores, instance grouping, sound once), `ParticleEditorTemplateTests` and `TexClampUVsDefaultTests`.
