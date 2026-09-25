# WE-authored values audit

**Status: 2026-09-25.** Work queue item 2 in [`roadmap.md`](roadmap.md).

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
  - the camera-parallax update at 0x140189b0f…0x140189cc6
- **`bin/wallpaperui.exe`**: the editor's shader-annotation parser at 0x14046cdc9…0x14046d0bf (`range`, `linked`, `position`, `int`, `direction`, `nobindings`, `conversion`).
- **`ui/dist/scripts/scripts.js`**: WE's browse sidebar and the property editor.
  - The slider row uses `step:property.step||1, precision:property.precision||1`.
  - `EditorUserPropertyDetailsModalCtrl` creates sliders as `min 0, max 1` and saves `precision` as the decimals plus 1, with `step = 0.1^(precision-1)`.
  - The material slider uses `step 0.01, precision 2`; an `int` material slider uses step 1.
  - The linked slider links while x == y.
- **`assets/scripts/jsclasses/baseclasses.js`**: WE's `createScriptProperties` and `_Internal.updateScriptProperties`.
- **`locale/ui_en-us.json`**: WE's English text for the `ui_…` label keys.

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
| `SceneInspectorView` — combos with `"type":"imageblending"` (`BLENDMODE`) and no `options` | — | WE fills the blend-mode list in its editor (`wallpaperui.exe`), not in the annotation | unknown: not shown until that list is extracted; the authored value still applies |
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

## 3. scene.json `general` — fixed defaults, runtime handoff

| Field | Was | WE's default (`wallpaper64.exe` constructor) | Verdict |
|---|---|---|---|
| `bloomstrength` | 1 | 2.0 (offset 0x3bc) | fixed (`SceneGeneralDefaults`) |
| `bloomthreshold` | 0.7 | 0.65 (0x3c0) | fixed |
| `bloomtint` | 1 1 1 | 1 1 1 (0x3d8…0x3e0) | kept |
| `bloomhdrstrength` / `threshold` / `feather` / `scatter` / `iterations` | not read | 2.0 / 1.0 / 0.1 / 1.619 / 8 (0x3c4…0x3d4) | unknown: the HDR chain isn't implemented (roadmap 5.4) |
| `camerashakespeed` / `amplitude` / `roughness` | 0 | 3.0 / 0.5 / 1.0 (0x328 / 0x32c / 0x330) | fixed default; the values are still **unused**, see below |
| `cameraparallaxamount` / `delay` / `mouseinfluence` | 0 | 0.5 / 0.1 / 0.5 (0x334 / 0x338 / 0x33c) | fixed default |
| `gravitydirection`, `winddirection`, `windstrength` | not read | (0, −1, 0); (0.707, 0.707, 0); 1.0 | unknown: no consumer yet |
| fog fields | not read | distance 1…5, height 1…−3, densities 1 | unknown: no consumer yet |
| `SceneMetalRenderer` composite bloom threshold without WE bloom | 0.55 | WE's default 0.65 | fixed |
| `SceneMetalRenderer` `userBloom × 1.2`, `userBlur × 4` | app constants | `_owe_bloom` / `_owe_blur` are app extras | keep |

**Handoff to the depth-parallax/shine agent (`SceneMetalRenderer`):**

**Camera parallax** (roadmap 8.16): our model is `0.18 × depth × cursorDelta × sceneSize × amount × influence`, which is not WE's. From `wallpaper64.exe` 0x140189b0f…0x140189cc6, `g_ParallaxPosition` works like this:
1. The flag bit 0x100 enables it. The influence is `cameraparallaxmouseinfluence` (0 while input is off).
2. `cursor = clamp((x, 1 − y), 0, 1)`.
3. `target = size · (cursor · influence + 0.5 · (1 − influence))`.
4. When `delay > 0`, the position eases toward the target: `pos += (target − pos) · min(1, (1 − delay / 3) · 10 · dt)`. Otherwise `pos = target`.
5. `g_ParallaxPosition = clamp(pos / size, 0, 1)`.

Per object, 0x14018a0b3 displaces by `amount · depth.xy · (objectPosition − pos)`. This is a lead; confirm it before use.

**Camera shake:** the `47.3 / 71.9 / 53.1 / 83.7` Hz sines and the 0.004 / 0.002 × scene-size amplitude are invented. The authored speed, amplitude and roughness are ignored. WE's shake routine hasn't been found yet. The runtime readers of 0x328…0x330 are around 0x140192487 and 0x140195cba (unverified). **unknown**

**Text layers** are built with `parallaxDepth: .zero` (`SceneWallpaperViewModel.buildMetalTextLayer`), so text never follows parallax. 13 of the 75 corpus text objects author a depth. **fix**, owned by the parallax work.

## 4. SceneScript `createScriptProperties` — fixed

| Location | Was | WE's source | Verdict |
|---|---|---|---|
| `AudioReactiveScriptEngine` shim | replaced WE's builder: combo default = `o.value` (undefined), no `_config`, every authored key copied | WE's builder: combo = `options[0].value`, `_config` with label/min/max/int/options; `_Internal.updateScriptProperties` applies declared keys only and turns a colour string into a `Vec3` when the default is one | fixed (`SceneScriptPropertiesShim`) |
| `scriptproperties` bound to a user property (`{"user":…,"value":…}`) | unresolved | WE resolves them through the user property | handoff: SceneScript agent (docs/scenescript-plan.md, WP for script instances) |

## 5. Name heuristics and native approximations

| Location | Value | Verdict |
|---|---|---|
| `SceneWallpaperViewModel.materialEffects` | reads material constants by name (`brightness`/`intensity`/`gain`, `strength`/`glow`, `radius`/`sigma`, `threshold` → 0.7…) into the native image draw; bloom and blur default to 1 when the shader *name* contains "bloom"/"blur" | **fix**: this is a rule-1 native approximation. It only affects layers that don't draw through their WE material. Remove it once the base image material covers every layer (roadmap 1.3). It was not changed here because the parallax agent is editing that file |
| `SceneWallpaperViewModel.buildMetalTextLayer` | `pointsize ?? 24`, `padding ?? 0` | unknown: every corpus text object authors both. WE's text defaults weren't located (the text property table is at 0x14025…, and the pointsize offset isn't mapped yet) |
| `SceneUserPropertiesView` text extras | size 1…256, colour `1 1 1` tint, opacity 1 | keep: app extras, multiplicative identity at their defaults |
| `SceneInspectorView` move / scale | 0.05…5×, 1/10/50 px steps | keep: app editing tools, not a WE value |
| video music sync (`VideoMusicSyncSettings`) | zoom 0…0.5, pace ±1, tilt ±15°, saturation −1…2 | keep: app-only feature |
| inspector and sidebar "Music Amount" | ± the slider span | keep: app-only feature |
| `AudioSpectrum` (`maxStep 0.3`, `0.35·log10`, tilt) | our FFT shaping | unknown: WE's `g_AudioSpectrum` scaling needs a capture (see test-risks) |
| `SceneMetalRenderer` `_owe_speed` | scales the scene clock | keep: app extra; roadmap 8.4 covers the clock problems |

## 6. Particles — handoff to the particle agent

Almost nothing in the particle loader cites WE. The only citations are the emitter clock (`ParticleEmitterClock.swift`, `wallpaper64.exe` 0x1401c1c70) and the collision control point clamp to 7 (matches `re/coll_parse.asm`). Everything below is **unknown** until it is checked against `we64.asm`. Items marked ⚠ are inconsistent or drop authored data.

**Emitters** (`SceneWallpaperViewModel.buildMetalParticleSystem`):

| Field | Current value |
|---|---|
| `rate` | ?? 100 |
| `distancemax` | ?? 0 |
| `directions` | ?? (1, 1, 0) |
| emitter `name` | ?? "sphererandom" |
| `instantaneous` | ?? 0 |
| `speedmin` / `speedmax` | ?? 0; swapped if reversed |
| `sign` | ?? 0 |
| `distancemin` | ⚠ only x is used, as a ratio of `distancemax.x` |
| system `maxcount` | ?? 1000 |

**Initializers:**

| Initializer | Current value |
|---|---|
| `lifetimerandom` | 1…1 |
| `sizerandom` | 20…20 |
| `alpharandom` | 1…1 |
| `velocityrandom` / `turbulentvelocityrandom` | 0 |
| `colorrandom` | ?? (1, 1, 1) |
| `hsvcolorrandom` | ⚠ treated as RGB |
| `normalizedParticleColor` | ⚠ divides by 255 when any channel is > 1 (a heuristic) |
| `rotationrandom`, `angularvelocityrandom` | ⚠ z only |
| `mapsequencebetweencontrolpoints` | count ≥ 2; ⚠ arc × 0.5 |
| `remapinitialvalue` | output ?? size; input range 0…1 |

**Operators:**

| Operator | Current value |
|---|---|
| `movement` `gravity` | ⚠ z if non-zero, else y |
| `drag` | linear `1 − drag·dt` |
| `alphafade` | fadeout ?? 1, which means none |
| `sizechange` / `alphachange` / `colorchange` | 0 → 1, values 1 |
| `vortex` | distanceouter 1000 |
| `boids` | neighborthreshold 150; ~256 neighbours sampled |
| `oscillate*` | ⚠ the middle of each range is used, not a per-particle random |
| `remapvalue` | ⚠ always drives alpha unless the output is velocity |
| `reducemovementnearcontrolpoint` | outer 100 |
| `maintaindistancebetweencontrolpoints` | stiffness 10 |
| `turbulence` | scale 0.005, speed 500…1000, timescale 0.01; ⚠ `phasemax` is ignored |
| `controlpointattract` | scale 100, threshold 1000 |

**Renderer:**
- ⚠ trail length is `maxlength ?? length ?? 1` in the simulation, but 0.05 / 10 for the WE shader uniforms (`ParticleMaterialPlanBuilder`).
- ⚠ `subdivision` is 4 in the simulation but 0 for the `TRAILSUBDIVISION` combo.
- `segments` ?? 4.
- The built-in trail uses `speed · 0.08`.
- The refract-amount opacity is clamped to 0.04…1 (a heuristic).

**Children:**
- `maxcount` ?? 10
- `probability` ?? 1
- linked control points ≤ 8
- `controlpoint<n>` overrides ids 0…7

**Audio and collision:**

| Field | Current value |
|---|---|
| `audioprocessingbounds` | (0.8, 1) |
| `audioprocessingexponent` | 2 |
| `collisionplane` distance | −150 |
| `collisionsphere` | (0, −200, 0) r 50 |
| `collisionquad` | 200 × 200 at (0, −150, 0) |
| `bouncefactor` | 0.5 |
| quad push-out | × 1.05 |

**Instance overrides:** all default to 1, with no clamps on size and speed.

Loader-side fixes are the particle agent's, because they share the particle files. They should check each default in `we64.asm` the way §3 did: find the initializer's or operator's property table by its field names, then the constructor that writes the offsets.

## Tests

`OpenWallpaperEngineTests/WEAuthoredValuesTests.swift`:
- `testEveryEffectParameterIsItsAnnotation` walks every bundled effect and every effect shipped in a library wallpaper. For each parameter it checks:
  - the default, range, label, `int`, `type: color` and `linked` against the annotation
  - the default against the constant the renderer resolves
  - every combo's default and options against its `[COMBO]` annotation
- `testEveryLibraryPropertyIsAuthoredValue` checks every library project.json property: min, max, step, precision, value and option labels.
- Unit tests cover:
  - project.json parsing (WE's defaults when a field is absent)
  - WE's label table
  - the `general` defaults, with authored values winning
  - the inspector combo override
  - `createScriptProperties` defaults and `scriptproperties` injection, run against WE's own `baseclasses.js`
