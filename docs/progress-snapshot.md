# Open Wallpaper Engine for macOS: progress snapshot

- **Date:** 2026-09-25
- **Branch:** `deepratna/feature-work` @ `ebb88ae` plus uncommitted working-tree changes
- **Goal:** run **every** Wallpaper Engine wallpaper type except `application`. That means any Workshop scene with custom effects, shaders and SceneScripts, not only the wallpapers in the local library.

## How this was checked

- **Reference install:** the real WE install under CrossOver (`…/steamapps/common/wallpaper_engine/assets`) was the reference for effects, shaders, materials, util models and scripts.
- **Test sample:** the local library `/Volumes/980Pro/OpenWallpaperStorage` has 66 wallpapers: 43 scene, 22 video, 1 web. They contain 612 effect instances (102 of them Workshop-local effects), 196 scripts and 461 user-property bindings. The library is a sample for finding problems. **A low count does not mean a low priority.**
- **Empirical tests:**
  - A Swift harness built the app's exact `MTLRenderPipelineDescriptor` for all 69 built-in translated shader pairs and 13 Workshop pairs.
  - An unmodified copy of `AudioReactiveScriptEngine.swift` was compiled against JavaScriptCore and driven with real library scripts.
  - The current translator was re-run over all built-in shaders.
- **Official docs:** docs.wallpaperengine.io (SceneScript reference, user properties, effects). Where the docs are silent, community reverse-engineered behaviour was used, marked "RE".
- Licensing of the vendored `Resources/we-assets` is deliberately **out of scope** for this snapshot, as requested.

Paths below are relative to `Open Wallpaper Engine/`:

| Short name | Path |
|---|---|
| R | `WallpaperView/SceneMetalRenderer.swift` |
| SH | `WallpaperView/SceneShaders.metal` |
| VM | `Services/SceneWallpaperViewModel.swift` |
| M | `Services/SceneParsers/SceneModels.swift` |
| T | `Services/SceneShaderTranslator.swift` |
| C | `Services/SceneEffects/SceneDynamicEffectCatalog.swift` |
| ARSE | `Services/AudioReactiveScriptEngine.swift` |

---

## TL;DR

1. **No Wallpaper Engine shader renders today.** Every translated pipeline fails with `Vertex function has input attributes but no vertex descriptor was set`, and the error is swallowed by `try?` at R:781.
   - Every effect you see is a hand-written native approximation. There are 44 of them, and many ignore the authored parameters.
   - Effects with no native case are silently not drawn: `fluidsimulation`, and **34 of the 102** Workshop effect instances.
   - Even with the pipeline fixed, uniforms, texture slots, constants, combos and the pass graph are all wired wrong (A2–A6).
2. **A hidden regression breaks 33 of 136 built-in shaders on a fresh translation.** Commit `ebb88ae` added `#define M_PI_2` (T:378-380), which clashes with WE's `common.h`. Stale caches mask it: successful translations are never invalidated.
3. **Audio reactivity dies after sleep.** System-audio capture starts once, in the singleton `init` (ARSE:327). `SCStreamDelegate.didStopWithError` isn't implemented and nothing ever restarts capture.
   - This is the most likely cause of "audio bars don't move" and "video music sync doesn't work".
   - SceneScript `registerAudioBuffers` is also a frozen snapshot (E4).
4. **Whole-scene effect layers and solid layers render nothing.**
   - Composition, fullscreen and project layers use `_rt_FullFrameBuffer`, which becomes a transparent 1×1 texture: 26 layers in the sample.
   - 17 solid layers are dropped.
5. **Most SceneScript writes are lost.**
   - `thisLayer.x = …` writes are dropped.
   - `getAnimation().play()` breaks after one frame.
   - `update(value)` never receives its previous result.
   - Visibility scripts run only once, at load.
   - Media callbacks are never called.
6. **Text positioning isn't modelled.**
   - The box is always centred on `origin`, and `anchor`, `blockalign` and image `alignment` are ignored.
   - Parents contribute only their origin, not scale or rotation.
   - Authored color is ignored and the point-to-pixel factor is missing.
   - Text layers can't have effects, and they are drawn above everything.
7. **Sidebar user properties.**
   - Declared properties do show, but `condition`, label/notice rows, and slider `fraction`/`step` are ignored.
   - Web-wallpaper properties are shown but never delivered to the page.
   - Values for every wallpaper live in one global dictionary shared across displays.

---

## 1. Coverage by wallpaper type and scene feature

Legend: ✅ working · 🟡 partial · ❌ missing or broken

### Wallpaper types

| Type | Status | Evidence |
|---|---|---|
| Video | 🟡 | AVPlayer playback with placement, rate and volume works. Music sync depends on the dead system-audio capture (§2.G). The `saturation` sync modifier is applied to an `NSViewRepresentable`, where SwiftUI color effects don't apply, so it likely does nothing. |
| Web | 🟡 | WKWebView with file access works. Nothing calls `window.wallpaperPropertyListener.applyUserProperties`, and `wallpaperRegisterAudioListener` isn't provided. The 10 web properties in the sample show in the sidebar but have no effect. |
| Scene | 🟡 / ❌ | See the feature table below. |
| Application | n/a | Out of scope; gated behind a trust prompt. |
| Preset | ❌ | The filter is commented out (`FilterResultsViewModel.swift:46,53`). Presets are scene + `preset.json` overrides and would reuse the scene path. |

### Scene features

| Feature | Status | Evidence |
|---|---|---|
| Image layers (static, sprite sheets) | 🟡 | They render, but `alignment` is ignored (D3), parent scale and rotation are ignored (D8), and `colorBlendMode` is ignored on Metal (SH:727). |
| Keyframe animation | 🟡 | Alpha works (13 in the sample). Origin, scale, angles and size keyframes never play (E7). |
| Composition / fullscreen / project layers | ❌ | `_rt_FullFrameBuffer` becomes a transparent 1×1 (VM:1194, R:1504). |
| Solid layers (`solidlayer*.json`) | ❌ | No texture → nil (VM:696) → dropped. 17 in the sample. |
| Text layers | 🟡 | They render, but see §D. No effects (VM:797). Always drawn on top (VM:489). |
| Parenting | 🟡 | Only origins are summed, at build time (VM:657-690). 100 children in the sample. |
| Particles | 🟡 | They render, but `instanceoverride.count` and speed/alpha/lifetime/controlpoints are not decoded. Particles are always drawn after all layers (R:1316). A "snow" name heuristic applies. |
| Built-in effects (46) | 🟡 | 44 native approximations and 0 translated (§3). |
| Workshop / custom effects | ❌ | 0 translated. 68/102 are aliased to a native look-alike and 34/102 are not drawn. |
| Multi-pass effects, FBOs, `previous`, `_rt_*` | ❌ | Only pass 0 is used (VM:1012). `fbos`, `bind`, `target` and `command:"copy"` aren't implemented (A6). |
| Masks | 🟡 | The first texture slot is used as the mask. For shake, 234 of 235 masks in the sample are really RG88 flow maps (B4). |
| User-property bindings | 🟡 | Only `visible` bindings are honoured, including the `{name,condition}` form. All others are lost (C1). |
| SceneScript | 🟡 | See §5. Property scripts run; the object model is mostly broken. |
| Audio-reactive (effects, scripts, bars) | ❌ | Capture dies after sleep (§2.G). `g_AudioSpectrum*` is never fed to shaders. Bars are a native stand-in. |
| Sound objects | 🟡 | One file is looped at the app's own volume. `playbackmode`, `volume`, `startsilent`, `mintime`/`maxtime`, multiple sounds and script control are all ignored (F1). |
| Bloom / HDR | 🟡 | A `general.bloom` user binding fails the Bool decode, so bloom is turned off (2 wallpapers in the sample). |
| Camera parallax / shake | ❌ | Not decoded from `general` (M:98-135). |
| Lights, 3D models (`.mdl`), puppet warp | ❌ | Lights and models are dropped. Puppet-warp models render as a flat atlas (VM:700). |
| Perspective scenes (`orthogonalprojection: null`) | ❌ | The heuristic sizes the scene 2048×1078 with origins around 4.8 (3453730450). |
| Cursor interaction | 🟡 | Events fire globally with no `solid` hit test and use screen points (E5). |
| Tests | ❌ | No test target, and the scheme lists missing test bundles, so `xcodebuild test` fails (F3). |

---

## 2. Verification of suspected root causes

### A. Translated WE shaders (the "dynamic" path)

| # | Verdict | Evidence |
|---|---|---|
| A1: no vertex descriptor, so the pipeline never builds | **CONFIRMED** | See detail below. |
| A2: uniform buffer binding is wrong | **CONFIRMED** | See detail below. |
| A3: texture slots are in first-use order | **CONFIRMED** | shake.frag puts `g_Texture1` at texture(0) and `g_Texture0` at texture(1). R:1501 binds the layer image at 0, so shake would sample its flow map as the image. Samplers are only bound for `max(textures.count,1)` slots (R:1513). |
| A4: constants aren't passed in | **CONFIRMED, worse than suspected** | `SceneDynamicEffectPass` decodes the keys `constants`/`uniforms` (C:98-110), which no WE material uses. Every uniform therefore gets 0, not even the shader's annotation default (R:1564). Per-object `constantshadervalues` only reach the native path (VM:1016-1028). The keys are the annotation's `"material"` name; for example shake uses `speed`, `strength`, `friction`, not `g_Speed`. |
| A5: combos ignored | **CONFIRMED** | See detail below. |
| A6: effect.json `target` / `bind` / `fbos` ignored | **CONFIRMED** | See detail below. |
| A7: stub headers and naive string replaces | **PARTIAL, plus a regression** | See detail below. |
| A8: catalog key vs lookup name mismatch | **PARTIAL** | See detail below. |

**A1 detail.**
- R:756-780 never sets `vertexDescriptor`, and `try?` at R:781 hides the failure. All 230 translated vertex shaders use `[[stage_in]]`.
- The harness reproduced the failure on 138/138 built-in attempts and 13/13 Workshop pairs. The Metal source itself compiles cleanly.
- With a descriptor added, 64 of 69 pairs link. The other 5 have mismatched varying locations between vertex and fragment stages (spin, waterflow, waterripple, godrays_downsample2, shine_downsample2), so a location-remap step is also needed.
- R:1444 binds no vertex buffer.
- Failed pipelines aren't cached, so each one is rebuilt every frame, for every pass and every layer.

**A2 detail.**
- spirv-cross gives each uniform its own buffer slot, in first-use order:
  - shake.frag: `g_Speed`@0, `g_Time`@1, `g_Friction`@2, `g_Amp`@3.
  - shake.vert: MVP@0, `g_Texture1Resolution`@1, `g_Bounds`@2.
- The renderer binds `LayerUniform`@0, `EffectUniform`@1 and a packed float array@2 (R:1489-1500).
- `g_Time` is right in shake only by accident. In waterwaves it reads the layer position.
- The `.reflection.json` sidecars come from a regex over the GLSL (C:52-80). They have no binding indices and miss arrays.

**A5 detail.**
- The header hard-codes `MASK 0`, `MODE 0`, `VARIATION 0` and others (T:387-394, 417-426). `BLENDMODE 0` is hard-coded only in the pkg header (T:541).
- `macroConfiguration` is only a cache key (C:214-221).
- Per-instance combos are ignored. Example: blurprecise pass 2 sets `VERTICAL=1`, so both passes blur horizontally.
- The sample sets 38 distinct combo values per instance: `VERTICAL=1` ×77, `ENABLEMASK=1` ×30, `AUDIOPROCESSING` ×14, `BLENDMODE=31/32` …
- Masked layers skip the dynamic path entirely (R:1416).

**A6 detail.**
- `SceneDynamicEffectManifestPass` decodes only `material` (C:375-377).
- blur's effect.json runs 4 passes through 2 quarter-size FBOs, and its combine pass reads `previous`. The app chains the passes at full size and never passes the original image.
- None of these appear anywhere in the Swift sources: `_rt_imageLayerComposite_*`, `_rt_FullFrameBuffer`, `previous`, `command:"copy"`, FBO `scale` (a divisor).
- The render-target pool can hand a finished layer output to another layer's passes (R:726-738).

**A7 detail.**
- Built-in shaders get the real `common.h` and `common_blending.h` (T:312-317). `.pkg` and wallpaper-local translation fall back to a one-line `mix` stub (T:487-490, 549-562). The real header has about 45 blend functions, so this fails with, for example, `vhs.frag: 'BlendLinearDodge' undeclared`.
- **Regression:** `#define M_PI_2` (T:378-380) clashes with WE's `common.h`. Re-running the current translator fails **33 of 136** shaders, including shake, waterwaves, blur_combine, vhs, nitro and iris.
  - *Fixed 2026-09-25 (uncommitted).* The header now uses WE's values: `M_PI_2` = 2π and `M_PI_HALF` = π/2.
  - A second `ebb88ae` regression surfaced during the cache refresh. The added `pow`/`max` overloads stop glslang from converting `int` arguments for the built-ins, which breaks HLSL-style `pow(x, 4)` and `max(0, x)` (brushpreview, clippingmaskimage4, flag). Fixed by adding integer overloads.
  - All translatable WE sources now succeed: 247 of 250. The other 3 were already unsupported.
  - This is hidden because translations are keyed only on the source hash (T:257-266) and are never invalidated.
- `frac`→`fract` has no word boundary. The cached refract.frag contains `v_RefracttTexCoord`, which only works because both stages are renamed the same way.
- 3 of 5 `mul` overloads are reversed (T:396-399). The correct rule is `mul(x,y)` → `(y)*(x)`.
- `ddy` → `dFdy` has no negation. WE semantics need `dFdy(-(x))` (RE).

**A8 detail.**
- The catalog is keyed by `replacementkey` (C:286) and looked up by folder name (VM:1013). They differ for 7 built-ins: `blurprecise`/`blur_precise`, `blurradial`, `chromaticaberration`, `refraction`/`refract`, `watercaustics`/`caustics`, `_empty`, and `depthparallax`, whose key `iris` collides with the real iris.
- Workshop effects whose folder name equals their key do match, then fail because of A1.
- Some effects are hard-aliased to native look-alikes (VM:1079-1086): `Simple_Audio_Bars`, `lens_distorsion`→hyperdrive, `hue_shift`.
- The shader-file cache has 130 key collisions with stale preview translations, and the wrong copy wins in 73 of them (for example `vert|effects_shake`).

### B. Effects that disappear

| # | Verdict | Evidence |
|---|---|---|
| B1: composition / fullscreen / project / solid layers | **CONFIRMED** | See detail below. |
| B2: text layers get `sceneEffects: []` | **CONFIRMED** | VM:797. 31 of 63 text objects in the sample author effects (blurprecise on clocks, psyhue+nitro). WE supports effects on text layers. |
| B3: only `passes.first` is used | **CONFIRMED** | VM:1012. 72 of 73 multi-pass instances put constants in pass ≥2. Example: godrays 3453730450/145 authors `rayintensity` 0.2; the app uses 0.77. No real effect lacks `passes`. |
| B4: mask taken from the wrong slot | **CONFIRMED** | See detail below. |
| B5: `zeroDisablesKeys` | **CONFIRMED** | R:464-475. The test runs on the *translated* value, and translation clamps small values to 0. Example: opacity `alpha` 0.0035 → removed → the layer shows fully opaque (3639372043/336). |
| B6: unset bound property hides the effect | **PARTIAL** | VM:1146 returns false, but project.json defaults are seeded at scene start (VM:369-375). It only bites for properties that aren't declared: 8 bindings in the sample. |
| B7: all-or-nothing `[WEObjectEffect]` decode | **CONFIRMED in code** | M:230/324/334. No failing entry in the 612 samples; still a robustness hazard for arbitrary Workshop content. |
| B8: heuristics | **CONFIRMED** | See the list below. |

**B1 detail.**
- The WE `composelayer`, `fullscreenlayer` and `projectlayer` materials use `_rt_FullFrameBuffer`. VM:1194 turns any `_rt*` texture into a transparent 1×1.
- The solidlayer material has no texture, so VM:696 returns nil and the layer falls through to `buildShapeLayer`, which requires `shape`. The layer is dropped.
- `copybackground` and `solid` are decoded but never used.
- In the sample, 26 whole-scene effect layers render nothing (for example the post-processing layer and Hyperdrive in 3677897732, godrays in 3384308105) and 17 solid layers are dropped.

**B4 detail.**
- VM:1049 uses the first non-null texture. In WE's shake, slot 1 is a *flowmask* direction map and slot 3 is the opacity mask (`"combo":"MASK"`).
- Decoded from the pkgs, 234 of 235 shake slot-1 textures are RG88 flow maps. SH:154 samples their `.r` channel as the mask.
- The same mistake affects pulse (`util/noise`), waterflow, blendgradient and depthparallax.
- The mask limit is 32 in the working tree, not 4. The comment at R:632 is stale.

**B8: heuristics found.**
- `cloud` → volumetricfog (VM:725)
- clock detection plus regex-parsed settings (VM:800-834)
- clock/date/day texts skip their visibility binding (VM:1106)
- `lens_distorsion` → hyperdrive (VM:1083)
- `snow` particles (VM:1234)
- `4k` particle rescale (VM:1240)
- "halo" procedural fallback (VM:1903)
- xray source = same origin+size (VM:729)
- guessed constant names (VM:1159)
- forced variant selection (VM:386)
- index-based parallax depth (R:1201)
- `*mask*` uniform ⇒ mask (C:21)

### C. Sliders and intensity

| # | Verdict | Evidence |
|---|---|---|
| C1: `{"user":…}` bindings only kept for `visible` | **CONFIRMED** | See detail below. |
| C2: invented native parameter names and ranges | **CONFIRMED** | See the examples below. |
| C3: `orthogonalprojection {"auto":true}` | **PARTIAL** | `auto` isn't in the sample. The real outlier is `orthogonalprojection: null` (a perspective scene, 3453730450), which the heuristic can't render. Bad `general` fields never fail the whole scene (every field is `try?`). |

**C1 detail.**
- The condition form `{"user":{"name","condition"}}` *is* handled (M:382).
- Color, scale, text and `constantshadervalues` keep their literal `value` but lose the binding.
- Lost entirely:
  - `general.bloom`: the Bool decode fails, so bloom is off
  - `general.camerashake*` and `cameraparallax*`
  - `scriptproperties`: the object becomes `""` (M:485-494)
  - particle `instanceoverride.*`
- `{"script":…}` on `effect.visible` (8 in the sample) and `{"animation":…}` on constants (11) are dropped.
- The slider, intensity and color controls in the sidebar can therefore only move effects that the app hand-maps. Generic authored bindings don't move anything.

**C2 examples.**
- **Shake:** strength 0.1 → remapped 0.184 → ×0.01, then squared → ~3e-6 UV of random jitter. That is invisible, and WE moves along the flow map instead. Negative speed (−3 ×40 in 3736761065) clamps to 0, so those layers freeze.
- **Waterwaves:** scale 200 → 20.8. WE squares strength; the app uses it linearly.
- **Blur:** the app reads `amount`, but WE's parameter is `scale`.
- **Chromaticaberration:** WE's keys are `ui_editor_properties_*`; the app reads `strength`/`center`.
- **Pulse and iris:** ignore every authored constant.
- About 20 native cases read an invented `amount` and always use their hard-coded default.

### D. Text positioning

WE model (docs plus RE):
- Scene space is y-up with (0,0) at the bottom-left.
- `horizontalalign`/`verticalalign` pick which edge of the text block sits at `origin`.
- `anchor` is a screen anchor. Pixel size = `pointsize × 96/72`.
- A tiny stub `size` such as "2 2" means auto-size.
- The parent's full transform applies to its children.

| # | Verdict | Evidence |
|---|---|---|
| D1: nil without `size` | **CONFIRMED, but the real bug is stub sizes** | All 63 texts in the sample have `size`. 2 have `"2 2"` (3352730400/206, /212) and shrink-to-fit makes them invisible. |
| D2: always centred on origin | **CONFIRMED** | SH:302. `horizontalalign` is only paragraph alignment inside the box, and `verticalalign` only moves text within the box. `anchor` and `blockalign` aren't decoded. `maxwidth` narrows the box and re-centres it (R:1645). |
| D3: image `alignment` unused | **CONFIRMED** | Decoded at M:305, never read. In 3546971487 'Media Area' (`bottom`) the layer is off by 422.5 units, and its child texts inherit the error. |
| D4: shrink-to-fit | **CONFIRMED** | R:1611-1631 and VM:895-905. WE doesn't do this. |
| D5: authored `color` ignored | **CONFIRMED** | VM:787 and R:1593 default to white. `brightness` and `colorBlendMode` are also ignored for text. 34 texts in the sample author a color. |
| D6: rasterized small, then upscaled | **CONFIRMED** | Drawn at the scene-unit box size (R:1289/1597), then scaled up to ×4 or more. There's no 96/72 factor, so glyphs are about 75% of WE's size. |
| D7: text sorted above everything | **CONFIRMED** | VM:489. 47 texts in 13 scenes are authored below other layers. |
| D8: parent transforms are only origin sums | **CONFIRMED** | See detail below. |
| D9: clock uses a regex formatter | **PARTIAL** | Only the 15 texts detected as clocks use the fixed formatter (R:1276). The other 38 scripted texts run their scripts. |

**D8 detail.**
- VM:657-690 sums origins once at build time. Parent scale and rotation are ignored, and runtime changes to a parent don't move its children.
- 89 of 100 children in the sample have a scaled ancestor.
- Example: in 3677897732 the 'Clock' parent has scale 0.2, so its child 'D a y' renders 5× too large and in the wrong place.

### E. SceneScript runtime

| # | Verdict | Evidence |
|---|---|---|
| E1: per-script context, rebuilt globals | **CONFIRMED, and expensive** | See detail below. |
| E2: `thisLayer` writes lost | **CONFIRMED, worse than suspected** | See detail below. |
| E3: `shared` round-trips through Swift | **Mechanism CONFIRMED, sample harmless** | Functions and prototypes are lost. The one heavy user (3453730450) stores only numbers. |
| E4: `registerAudioBuffers` is a static snapshot | **CONFIRMED** | All 20 calls are at module scope. The buffers never update (ARSE:849-862). `left == right`, and the maximum is 64 bins. WE updates them every frame. |
| E5: cursor in screen points | **CONFIRMED** | `NSEvent.mouseLocation` (ARSE:773, 866). WE uses scene coordinates. |
| E6: getEffect / getMaterial / setMaterialProperty are stubs | **CONFIRMED** | `getEffect` returns null and `getMaterial` returns `{}`. There's no use in the sample, but they are core WE API. `createLayer` clones the caller and ignores the model path. |
| E7: keyframes shadowed by layerStates | **CONFIRMED** | Origin/scale/angles/size are seeded (R:1008-1022), so their timelines never play. Alpha is checked first, so it still works. |
| **New:** visible scripts run once | **CONFIRMED** | See detail below. |
| **New:** media callbacks | **MISSING** | `mediaPropertiesChanged`, `mediaThumbnailChanged` and `mediaPlaybackChanged` are used by 34 scripts in 3 wallpapers and are never called. |
| **New:** angles units | **BUG** | Scripts write degrees (WE API); scene.json and the renderer use radians. No conversion is done. |
| **New:** `solid` hit-testing | **MISSING** | `cursorClick`/`Down`/`Up`/`Move` fire globally, including for clicks in other apps. WE only fires them on `solid` layers. |

**E1 detail.**
- The JSContext is kept, but every evaluation re-bridges `engine`, `input`, `thisScene` and every layer, each with about 60 helper functions.
- Measured cost is about 0.3 ms plus 0.12 ms per layer, per script, per frame. 3453730450 comes to roughly 400 ms per frame.
- Effect and particle scripts have no layer id, so identical script text on different objects shares one context and its state.

**E2 detail.**
- `thisLayer !== __layers[id]` (ARSE:920), so `thisLayer.origin/alpha/text` writes are dropped.
- The read-back turns bridged functions into `{}`. From the second frame on, `getAnimation().play()` throws "is not a function" (24 scripts).
- `update(value)` always receives the *authored* value, not the last returned one (R:1175-1225), so accumulators never move. That's about 23 scripts in 3453730450.
- A vector script returning `undefined` becomes (0,0,0), so the layer vanishes or jumps. A text script returning nothing renders the word "undefined".

**Visible-scripts detail.**
- Visible scripts are evaluated once, at load, in a minimal shared context (VM:1130, ARSE:536-558). That context has no `Vec3`, `shared`, `input` or events, and `let` redeclarations collide.
- Objects hidden at load are dropped, so a script can never show them later.
- 33 scripts are dead because of this, including `createLayer`/`sortLayer`, `camerashake` and 12 cursor handlers.

### F. Other gaps

| # | Verdict | Evidence |
|---|---|---|
| F1: sound objects | **CONFIRMED** | See detail below. |
| F2: 3D models, puppet warp, lights, camera parallax/shake | **CONFIRMED** | No `model` or `light` fields (M:152-212): 4 `.mdl` objects and 8 lights are dropped, and 5 puppet rigs are drawn flat. `cameraparallax*`/`camerashake*` are not decoded. All 43 scenes have the keys; 3 enable parallax and 2 enable shake. |
| F3: no test target | **CONFIRMED** | Only the app target (pbxproj:461). The shared scheme references deleted test bundles, so `xcodebuild test` fails. |
| F4: licensing | **Out of scope** | Deferred at the user's request. |

**F1 detail.**
- 10 sound objects in 8 wallpapers. Their authored fields are `sound[]`, `volume`, `playbackmode` (loop/random/single), `startsilent` and `mintime`/`maxtime`.
- The app plays the first audio file from an unsorted directory scan, looped at the app volume (VM:182-205).
- Consequences:
  - `slap` (single, startsilent, played on click) loops from launch.
  - The 12-track random playlist plays one track.
  - Second sound objects are ignored.
  - `getLayer("vo1")` returns `undefined`.
- A pkg audio cache file is re-extracted under a per-launch random name on every call.

### G. New: audio capture and "sync with music" (reported during this snapshot)

Symptom: audio bars in scenes don't move, and video music sync doesn't work.

- **Root cause (high confidence):**
  - All system-audio levels come from one `SCStream`, started once, in `AudioReactiveScriptEngine.init` (ARSE:327).
  - The class declares `SCStreamDelegate` but implements no `stream(_:didStopWithError:)`.
  - Nothing restarts capture after sleep/wake, a display change or a stream error, and `level` freezes at its last value.
- **Evidence:**
  - The running app process started 2026-09-23 21:54.
  - `pmset -g log` shows the display off at 23:35 and a full sleep until 2026-09-24 13:25.
  - The scene bars (`audioBandVectors`, R:1454) zero out below level 0.012.
  - Video sync reads the same source whenever the video's own audio is muted (`musicSyncLevel`, `VideoWallpaperViewModel.swift:117`).
- **Contributing factors:**
  - **Ad-hoc signing.** The debug build is ad-hoc signed (`codesign: Signature=adhoc`). TCC ties the Screen Recording grant to the code hash, so a rebuild can silently void it; the code only reports this after 3 failed retries.
  - **Silent videos.** For videos without an audio track (2 of 22 in the sample), `musicSyncLevel` reads the own-track tap whenever the volume is above 0. That tap never attaches, so the level is always 0.
  - **Pace sync while paused.** Pace sync moves a paused video: `max(0, 0 + level·pace)`.
  - **Mono and mixed channels.** `stream(_:didOutputSampleBuffer:)` treats the planar stereo block as one mono buffer, so the FFT mixes L+R and `left == right`.
- **Quick confirmation:** relaunch the app. If the bars move again and stop after the next sleep, the root cause is confirmed.
- **Relaunch result (2026-09-25 03:49):** replayd logged `TCC Disallow` for every capture attempt by the rebuilt app, so the ad-hoc-signing permission loss is confirmed as an active cause.
  - The capture-restart fix is in place (uncommitted).
  - Screen Recording must be re-granted after every rebuild until debug builds are signed with a stable identity.
- **Evidence correction:** in the analysis shell, `log` is shadowed by a zsh function. Earlier "no logs found" checks never actually ran; use `/usr/bin/log`. The app's own `NSLog` lines are also redacted as `<private>` in the unified log, which is another reason to move `OWELog` to `os.Logger` with public formatting.

### H. New: sidebar "user properties"

The sidebar builds its list from `project.json` `general.properties`, sorted by `order`, with defaults seeded (`SceneUserPropertiesView.swift:77-97`). Declared properties do show. Gaps:

| Gap | Sample |
|---|---|
| `condition` (show a property only when another has some value) is ignored, so these are always shown | 20 properties / 3 wallpapers |
| `type:"text"` and untyped notice/header rows render as `EmptyView` | 18 |
| Titles containing HTML are shown as raw tags | 11 |
| Slider `fraction:false` (integer only), `step` and `precision` are ignored | 8 integer sliders, 14 with step |
| Combo `editable` is ignored | 9 |
| Web properties are shown but never delivered to the page | 10 |
| Bindings to undeclared properties: only simple on/off visibility toggles are synthesized | 26 bindings |
| `file`, `directory`, `texture` and `usershortcut` property types (per WE docs) aren't supported | 0 in the sample; exist in the wild |

Additional problems:
- `AudioReactiveScriptEngine.userPropertyStrings` is a single global dictionary. On multi-display, two scenes with the same property name (`schemecolor`, `clock`) overwrite each other. Stale keys from the previous wallpaper persist.
- VM:386 forces a variant on when none is selected, which overrides a user's deliberate "hide all".

---

## 3. Effect coverage: all 46 effects in the WE install

The local WE install has **46** effects, identical by name to the 46 vendored in `Resources/we-assets/effects`. At runtime **none is "translated OK"**, because A1 fails every pipeline.

Column meanings:
- **Native case (kind)**: the hand-written native effect the app runs instead, with its shader kind number.
- **Authored keys honoured / invented**: which WE parameter names the native case reads correctly, and which names it reads that WE never authors.
- **Would link with VD**: whether the translated pipeline links once a vertex descriptor is added.
- **Current translator fails**: shaders the current translator fails on because of the `M_PI_2` regression.

| Effect | Passes / FBOs | Runtime | Native case (kind) | Authored keys honoured / invented | Would link with VD | Current translator fails |
|---|---|---|---|---|---|---|
| _empty | 1/0 | missing (no-op, harmless) | – | – | yes | – |
| blend | 1/0 | native | blend (19) | multiply / amount | yes | blend.vert |
| blendgradient | 1/0 | native | blendgradient (20) | – / amount | yes | blendgradient.vert |
| blur | 4/2 | native | blur (36) | – / amount | yes | blur_combine.frag |
| blurprecise | 2/1 | native | blurprecise (37) | – / amount | yes | – |
| blurradial | 1/0 | native | blurradial (21) | – / amount | yes | – |
| chromaticaberration | 1/0 | native | chromaticaberration (16) | – / strength, center… | yes | chromatic_aberration.frag |
| cloudmotion | 1/0 | native | cloudmotion (23) | – / amount, speed | yes | cloudmotion.frag |
| clouds | 1/0 | native | clouds (24) | speed / amount | yes | clouds.frag |
| colorkey | 1/0 | native | colorkey (18) | alpha, color, fuzziness, tolerance | yes | – |
| cursorripple | 3/2 | native | cursorripple (38) | – / amount, speed | yes | cursorripple_combine.frag |
| depthparallax | 1/0 | native | depthparallax (46) | center / depthx, depthy, perspective | yes | – |
| edgedetection | 1/0 | native | edgedetection (25) | – / amount | yes | edgedetection.frag |
| filmgrain | 1/0 | native | filmgrain (26) | – / amount, speed | yes | filmgrain.frag |
| fire | 1/0 | native | fire (27) | speed / amount | yes | – |
| fisheye | 1/0 | native | fisheye (14) | center, size / scale | yes | fisheye.frag |
| **fluidsimulation** | 20/9 | **missing** | – | – | yes | fluidsimulation_combine, _vorticity |
| foliagesway | 1/0 | native | foliagesway (8) | phase, power, ratio, scale, speeduv, strength | yes | foliagesway.frag/.vert |
| glitter | 2/1 | native | glitter (39) | speed / amount | yes | – |
| godrays | 5/2 | native | godrays (10) | center, noise*, ray* (pass 0 only) | no (varyings) | godrays_cast.frag |
| iris | 1/0 | native | iris (6) | none (hard-coded) | yes | iris.vert |
| lightshafts | 1/0 | native | lightshafts (50) | colorend, noise*, ray* | yes | lightshafts.vert |
| localcontrast | 4/2 | native | localcontrast (40) | – / amount | yes | – |
| motionblur | 3/2 | native | motionblur (41) | – / amount, speed | yes | – |
| nitro | 1/0 | native | nitro (3) | bounds, colors, multiply, scale, smoothness, speed | yes | nitro.frag |
| opacity | 1/0 | native | opacity (13) | alpha | yes | – |
| perspective | 1/0 | native | perspective (28) | – / amount | yes | perspective.vert |
| pulse | 1/0 | native (brightness only) | pulse (5) | none | yes | – |
| reflection | 1/0 | native | reflection (29) | – / amount | yes | reflection.frag/.vert |
| refraction | 2/0 | native | refraction (42) | – / amount, speed | yes | – |
| scroll | 1/0 | native | scroll (15) | speedx, speedy / repeatx, repeaty | yes | – |
| shake | 1/0 | native (wrong mask, invisible jitter) | shake (1) | friction, speed, strength | yes | shake.frag |
| shimmer | 1/0 | native | shimmer (45) | – / amount, speed | yes | shimmer.frag |
| shine | 5/2 | native | shine (43) | speed / amount | no (varyings) | shine_cast.vert |
| skew | 1/0 | native | skew (30) | – / amount, speed | yes | skew.vert |
| spin | 1/0 | native | spin (17) | center, feather, size | no (varyings) | spin.vert |
| swing | 1/0 | native | swing (31) | amount, speed | yes | – |
| tint | 1/0 | native | tint (12) | alpha, color | yes | – |
| transform | 1/0 | native | transform (32) | – / amount | yes | transform.vert |
| twirl | 1/0 | native | twirl (33) | amount, speed | yes | twirl.frag |
| vhs | 1/0 | native | vhs (4) | artifacts, chromatic, distortion*, strength | yes | vhs.frag |
| watercaustics | 1/0 | native | watercaustics (22) | – / amount, speed | yes | – |
| waterflow | 1/0 | native | waterflow (34) | speed / amount | no (varyings) | – |
| waterripple | 1/0 | native | waterripple (9) | animationspeed, ratio, ripplestrength, scale, scroll* | no (varyings) | waterripple.frag/.vert |
| waterwaves | 1/0 | native | waterwaves (2) | direction, exponent, scale, speed, strength | yes | waterwaves.frag/.vert |
| xray | 1/0 | native | xray (35) | size | yes | – |

**Totals:** 0 translated OK · 44 native approximations · 2 missing (`fluidsimulation`, `_empty`).

With A1 fixed, 64 of 69 shader pairs link. The other 5 also need a varying-location remap. Every effect would still render incorrectly until A2–A6 are fixed.

**Workshop effects in the sample:** 102 instances across 30 distinct effects. 0 are translated, 68 run a native look-alike (for example `…/blurprecise` → native blurprecise, `Simple_Audio_Bars` → native audiobars) and **34 are not drawn**. 42 wallpaper-local shaders use `g_AudioSpectrum*`, which is never fed.

---

## 4. User-property binding usage (sample: 461 bindings in 23 of 43 scenes)

| Location | Count | Wallpapers | App behaviour |
|---|---|---|---|
| effect `visible` | 273 | 17 | ✅ (also the condition form) |
| object `visible` | 131 | 21 | ✅ (except clock/date/day text heuristic) |
| object `color` | 17 | 4 | ❌ literal kept, binding lost |
| script `scriptproperties` | 13 | 4 | ❌ becomes `""` |
| effect `constantshadervalues` | 12 | 4 | ❌ literal kept, binding lost |
| object `text` | 4 | 1 | ❌ literal kept, binding lost |
| `general.bloom` | 2 | 2 | ❌ decode fails, so bloom is off |
| object `scale` | 2 | 2 | ❌ literal kept, binding lost |
| particle `instanceoverride.count` | 2 | 1 | ❌ not decoded |
| `general.camerashake*` / `cameraparallax*` | 5 | 1 | ❌ not decoded |

53 of these bindings use the `{"user":{"name","condition"}}` form.

**Other dynamic-value forms:**

| Form | Where | Count | App behaviour |
|---|---|---|---|
| `{"script":…}` | text | 53 | ✅ runs |
| `{"script":…}` | alpha | 36 | ✅ runs |
| `{"script":…}` | visible | 25 | runs once only |
| `{"script":…}` | origin | 15 | ✅ runs |
| `{"script":…}` | constants | 15 | ✅ runs |
| `{"script":…}` | angles | 13 | ✅ runs |
| `{"script":…}` | scale | 13 | ✅ runs |
| `{"script":…}` | effect.visible | 8 | ❌ dropped |
| `{"script":…}` | particle rate | 5 | ✅ runs |
| `{"animation":…}` | constants | 11 | ❌ dropped |
| `{"animation":…}` | alpha | 8 | ✅ works |

Project-declared property types in the sample: bool 83, color 65 (43 are `schemecolor`), slider 22, combo 14, group 13, textinput 10, text 7, untyped 11.

**Takeaway:** a generic resolver for `{value | user | script | animation}` on *every* field would make sliders, intensity and colors work for arbitrary wallpapers. The current design special-cases fields and effects one at a time.

---

## 5. SceneScript API: usage vs implementation

`Scripts/scene-api-coverage.py` reports only 2 missing APIs, but **it is not trustworthy**:
- For `engine` and `input`, any `"word":` anywhere in the engine file counts as "supported".
- It checks names exist, not whether they work. `registerAudioBuffers`, `cursorWorldPosition`, `getAnimation` and `thisLayer` writes all "pass".
- It flags `camerashake`, which is actually implemented via `defineProperty` (ARSE:911).
- It ignores exported callbacks, `shared`, `Vec*`, imports and where the script is attached.

Corrected table (184 scene.json scripts in 18 wallpapers; 196 including UserDefaults overrides):

| API | Use | Status |
|---|---|---|
| `export update(value)` | 150 scripts / 18 wp | 🟡 gets the authored value, not the last result; `undefined` becomes (0,0,0) or "undefined"; dead in visible scripts |
| `export init` | 31 / 10 | ✅ (dead in visible scripts) |
| `export applyUserProperties` | 4 / 3 | 🟡 receives all properties every time |
| `export cursorClick/Down/Up/Move` | 23 / 5 | 🟡 global, no `solid` hit test, screen points; 12 dead |
| `cursorEnter/Leave` | 16 | 🟡 static origin, unscaled size |
| `media*Changed` | 34 / 3 | ❌ never called |
| `createScriptProperties` / `scriptProperties` | 55 / 14 | 🟡 instance values only for origin/text scripts; user-bound → `""` |
| `shared` | 48 / 1 | 🟡 works for numbers; functions and prototypes lost |
| `thisScene.getLayer` | 50 calls | 🟡 returns a copy, stale if cached; `undefined` for sound, particle and hidden objects |
| `getLayerCount` / `getLayerIndex` / `createLayer` / `sortLayer` | 1 each | 🟡 partial, and dead because they're in visible scripts |
| `thisScene.camerashake` | 2 | ✅ setter exists, but dead (visible script) |
| `thisLayer.*` reads | ~50 | 🟡 plain `{x,y,z}`, no Vec methods, radians instead of degrees |
| `thisLayer.*` writes | 21 / 7 | ❌ lost |
| `thisLayer.text` | 4 | ❌ |
| `getAnimation` / `play` / `stop` / `pause` | 24 | ❌ decays to `{}` after one evaluation |
| `engine.frametime` | 39 | ✅ |
| `engine.runtime` | 2 | 🟡 time base differs by script kind |
| `engine.userProperties` | 2 | 🟡 colors are strings, not Vec3 |
| `engine.timeOfDay`, `canvasSize`, `AUDIO_RESOLUTION_*` | – | ✅ |
| `engine.registerAudioBuffers` | 20 / 8 | ❌ frozen snapshot, mono, max 64 |
| `engine.setTimeout` | 4 | 🟡 only ticks when its script is evaluated |
| `input.cursorWorldPosition` | 1 | ❌ screen points |
| `input.cursorLeftDown` | 1 | 🟡 counts clicks in any app |
| `Vec2`/`Vec3`, `WEMath` imports | 28 / 3 | ✅ via bundled WE jsmodules |
| `getEffect` / `getMaterial` / `setMaterialProperty` | 0 | ❌ stubs; core WE API, common in the wild |
| `localStorage` | 0 | ❌ not provided |

---

## 6. Prioritized fix plan

Ordering principle: make the **generic WE pipeline** correct, so arbitrary Workshop content works, before tuning individual effects. The heuristics and native approximations should shrink as each generic piece lands. Each step should come with a test, which needs a test target first (step 0).

### P0: cheap and unblocking (hours)

> **Status, 2026-09-25:** items 1–3 are done and on PR #2:
> - `57fd40e`: capture restart, translator fixes, versioned cache.
> - `729a70d`: Debug builds signed with Apple Development.
>
> Item 4 (the test target) is part of Phase 1 in [`reorg-plan.md`](reorg-plan.md).

1. **Audio capture lifecycle (§2.G).**
   - Implement `stream(_:didStopWithError:)`. Restart on `NSWorkspace.didWakeNotification` and on screen-parameter changes. Reset `level`/`spectrum` to 0 while down.
   - Log capture state. Split L/R channels.
   - Pick the video sync source by whether an audio track exists, not by volume.
   - Sign debug builds with a stable identity so the TCC grant survives rebuilds.
2. **Fix the `M_PI_2` regression (A7).** Invalidate the translation cache on a translator revision (T:257-266), and drop stale preview translations and key collisions (A8).
   - *Done, uncommitted.* Translation stamps are now `<pipelineRevision>:<sha256>` (revision 5). Orphaned editor-only translations are purged on each pass.
   - The shared cache went from 1,819 to 994 files, with no stale stamps left.
   - Wallpaper-local caches refresh when each wallpaper is next loaded.
   - The vendored `Resources/we-assets` snapshot has not been regenerated.
3. **Stop swallowing pipeline errors.** Log once per shader and cache failures (A1).
4. **Restore `xcodebuild test`.** Add a unit-test target and a small corpus of scene.json / effect fixtures.

### P1: make the translated-shader path real (the core of "all wallpapers")

1. **Vertex input.** Add a `vertexDescriptor` (attr 0 = float3 position, attr 1 = float2 texcoord) and a quad VBO. Remap varying locations by name between stages, which fixes the 5 non-linking pairs.
2. **Uniform binding by reflection.**
   - Use spirv-cross `--reflect` or MTLFunction reflection to map names to buffer and texture indices.
   - Alternatively, rewrite the loose uniforms into one std140 UBO before glslang.
   - Bind textures by *name* (`g_TextureN`) and samplers for every slot.
3. **Built-in uniforms:**
   - `g_Time`, `g_Daytime`
   - `g_ModelViewProjectionMatrix` and the effect matrices
   - `g_TextureNResolution` (xy = padded, zw = content)
   - `g_PointerPosition` (0..1)
   - `g_AudioSpectrum{16,32,64}{Left,Right}`
   - `g_ParallaxPosition`
4. **Constant values.**
   - Parse annotation defaults.
   - Apply material `constantshadervalues` (the correct key), then per-instance values from *every* pass, keyed by the annotation's `material` name.
   - Resolve `{user|script|animation}` on them.
5. **Per-combo compilation.**
   - Precedence: pass override > material > annotation default.
   - `MASK=1` when a sampler annotated `"combo":"MASK"` is bound.
   - Remove the hard-coded `MASK/MODE/BLENDMODE 0` from the header.
6. **Pass graph.**
   - Implement effect.json `fbos` (scale is a divisor), `target`, `bind` and `command:"copy"`.
   - Add per-layer ping-pong `_rt_imageLayerComposite_<id>_a/_b` and `previous`.
   - Apply layer `blending` only to the final composite. `colorBlendMode>0` becomes an `effectpassthrough` pass with `BLENDMODE=n`.
   - Make render-target pool ownership per layer.
7. **Translator correctness.**
   - Use the real `common*.h` for *all* sources: pkg, wallpaper-local and built-in.
   - Replace string munging with word-boundary or token-level rewrites.
   - `mul(x,y)` → `(y)*(x)`; `ddy(x)` → `dFdy(-(x))`.
8. **Catalog keying.** Key by file path, fall back to `replacementkey`, never by folder name. Load Workshop effects from the wallpaper directory and its `effects/workshop/<id>/…` dependencies.
9. **Then delete the native path**, or keep it only as a debug fallback. Remove the aliases (VM:1079-1086) and `SceneAuthoredEffectRanges`.

### P2: layers that currently vanish

1. **`_rt_FullFrameBuffer`.** Blit a copy of the scene rendered so far. This covers composition, fullscreen and project layers and `copybackground`.
2. **Solid layers.** Render with the solidlayer material (color and alpha, no texture).
3. **Effects on text layers**, drawn through the same effect pipeline as images.
4. **Draw order.** One ordered draw list: images, text and particles interleaved in object order.
5. **Robust decoding.** Decode effects and passes element-wise and skip only the bad entry. Remove `zeroDisablesKeys`.

### P3: generic value bindings

1. **A single `SceneValue<T>` resolver** for `literal | {user,value} | {user:{name,condition}} | {script,scriptproperties,value} | {animation}`, used by every object, effect, material, particle `instanceoverride`, `scriptproperties` and `general.*` field.
2. **Per-wallpaper property stores.** Keep them per display, not in one global dictionary. Missing values default to the `project.json` value.
3. **Sidebar.**
   - Honour `condition`, `fraction`/`step`/`precision` and `editable`.
   - Render `text` and untyped rows as sanitized labels.
   - Add the `file`/`directory`/`texture` types.
   - Deliver web properties through `wallpaperPropertyListener.applyUserProperties` and add `wallpaperRegisterAudioListener`.
4. **`general` settings.** Decode `bloom` with bindings, `cameraparallax*`, `camerashake*` and perspective projection.

### P4: text and transform model

1. **Full parent transforms.** Build a transform hierarchy with parent scale and rotation, evaluated every frame so runtime and script changes propagate.
2. **Image `alignment` anchor.** For `left`, `centre.x = origin.x + w/2`; for `top`, `centre.y = origin.y − h/2`.
3. **Text layout:**
   - `horizontalalign`/`verticalalign` choose the text-block edge placed at `origin`.
   - Handle `anchor` and `blockalign`.
   - Pixel size = `pointsize·96/72`.
   - A stub `size` means auto-size.
   - No shrink-to-fit. Wrap only with `limitwidth`/`maxwidth`.
4. **Text color and rasterizing.** Use the authored `color`, `alpha`, `brightness` and `colorBlendMode`. Rasterize at output pixel scale (Retina).
5. **Delete the clock regex formatter** once scripts run correctly (P5).

### P5: SceneScript runtime

1. **One JSContext per scene** holding live layer proxies: native `JSExport` objects or getters/setters, not copies.
   - `thisLayer === thisScene.getLayer(name)`, and writes go straight to renderer state.
   - `update(value)` receives the last value.
   - Remove the per-frame re-bridging (E1). The measured 50–400 ms per frame should drop to about 0.
2. **Visible scripts** run every frame in the same context. Hidden objects are kept but not drawn.
3. **The WE object model:**
   - `getEffect(name).visible`, `getMaterial`, `setMaterialProperty(materialKey, v)`, wired to the P1 constants.
   - `getAnimation` / `getTextureAnimation`.
   - Real `createLayer`, `destroyLayer` and `sortLayer`.
   - Sound layers with play, stop and pause.
   - `localStorage`.
4. **Live audio.** `registerAudioBuffers` returns live `Float32Array`s updated every frame, with separate left and right channels and resolutions 16, 32 and 64.
5. **Input.**
   - Cursor positions in scene coordinates.
   - Cursor events only on `solid` layers, with a real hit test, and only when the desktop is actually clicked.
   - Angles in degrees at the API boundary.
6. **Callbacks.** `applyUserProperties` receives only the changed keys after the first call. Add the `media*` callbacks, fed from the existing `BrowserMediaIntegration`.
7. **Keyframes (E7).** Keyframe timelines drive origin, scale, angles and size, and scripts override only when they're present.

### P6: remaining content types

1. **Sound objects.** Honour `sound[]`, `playbackmode`, `volume`, `startsilent`, `mintime`/`maxtime`, allow several per scene, and expose them to scripts. Remove the fallback that picks an arbitrary audio file.
2. **Particles.** Decode all of `instanceoverride` (with bindings) and add control points.
3. **Other scene content.** Lights, `.mdl` models and puppet-warp skinning and animation layers. Presets as a type.

### P7: remove the heuristics (B8)

Remove each one as the generic piece above that makes it unnecessary lands:
- cloud→fog
- clock regex
- clock/date/day visibility skip
- `lens_distorsion`→hyperdrive
- snow and 4k particles
- halo fallback
- xray origin matching
- guessed constant names
- forced variant selection
- index parallax
- `*mask*` naming

Every one of these is tuned to specific wallpapers and misbehaves on others.

### Tooling (for the §6 work)

- **Rewrite `Scripts/scene-api-coverage.py`.** It should record the attachment point of each script and check behaviour, not names.
- **Add a headless render-test harness.** For each fixture it would:
  - load the scene
  - render N frames offscreen
  - assert that every effect pipeline built, no layer was dropped and no script threw.

  Run it over the whole library as a regression gate. The pipeline test from this snapshot (`pipetest.swift`) is a starting point.

---

## 7. Repository and code health

**Verdict:** the app works and the code is readable, with good comments explaining *why*. But it is not in good shape for the scale of the goal. The scene engine is ~9k lines in 4 files with no tests. Its correctness failures are silent. It depends on global singletons, stringly-typed keys and suppressed errors. Every bug in §2 that survived unnoticed (the dead dynamic path, the `M_PI_2` regression, the lost script writes) survived because nothing fails loudly and nothing is tested.

Measured on `Open Wallpaper Engine/` (~22.4k lines of Swift plus 727 lines of Metal).

### Layout (Xcode macOS SwiftUI app)

| Area | Finding | Recommendation |
|---|---|---|
| Top level | ✅ Standard for an Xcode app: `Open Wallpaper Engine/`, `.xcodeproj`, `Scripts/`, `.github/`, README ×3, CHANGELOG, LICENSE. ❌ `Open Wallpaper EngineTests/` is empty, and the scheme still references test and UI-test bundles that don't exist. `CNAME` and `resources/` (README screenshots) sit at the root. Local junk (`build/`, `default.profraw`, `frag.spv`) is correctly git-ignored. | Move screenshots to `docs/images/`. Add a real test target or remove the dead testables. |
| Folder semantics | ❌ Folders mix layers. `Services/` holds five **view models** (`SceneWallpaperViewModel`, `WallpaperViewModel`, `Video…`, `Web…`, `Workshop…`) next to parsers and services. `SceneEffectDefinitions.swift` (a model registry) lives in `ContentView/Components/`. `VideoMusicSyncSettings/Store` live in `VideoWallpaperView.swift`. `BrowserMediaIntegration` lives in `AudioReactiveScriptEngine.swift`. | Organise by feature: `Scene/{Parsing,Assets,Shaders,Rendering,Scripting,Audio}`, `Video/`, `Web/`, `Workshop/`, `Library/`, `Settings/`, `UI/`. Put view models next to their views. |
| Module boundaries | ❌ One app target. The scene engine (parsers, TEX/PKG, translator, renderer, script runtime) can't be built, tested or run headless without the UI. | Extract a local Swift package (for example `Packages/WEScene`) with `WESceneFormat` (Codable models and value resolver), `WEShaders` (translator and reflection), `WERender` (Metal) and `WEScript` (JSContext runtime). The app becomes a thin shell. This enables unit tests, the render-test CLI from §6 and faster builds. |
| Vendored assets | 2,092 tracked files under `Resources/we-assets`, landed in single commits of 2,182 files / 39k lines. | (Licensing deferred.) Technically, keep generated shader caches out of source control, or version them with a translator revision (see A7/A8). |

### Code-level findings

| Metric / pattern | Count | Why it matters |
|---|---|---|
| God files | `SceneMetalRenderer.swift` 2,397 lines (≥20 types, 54 funcs); `SceneWallpaperViewModel.swift` 1,940; `SceneInspectorView.swift` 1,341; `AudioReactiveScriptEngine.swift` 1,223 | Each mixes several concerns. `AudioReactiveScriptEngine` alone does audio capture, FFT, the JS runtime, the user-property store, the layer-state store and browser media. |
| Very long functions | `evaluateValue` 337 lines · `mtkView(_:draw)` 324 · `buildMetalParticleSystem` 300 · `updateParticles` 259 · `EffectStack.descriptor` 181 | Untestable units. The native effect switch is where parameter parity is lost (C2). |
| `try?` | **341** | Silent failure is the house style. It hid A1 (every pipeline failing), B7 and C1. Use `do/catch` with one-time logging at every IO, decode and pipeline boundary. |
| `try!` / `as!` | 3 / 4 | Few; audit anyway. |
| `.shared` singleton uses | 223 (9 singletons); `AppDelegate.shared` alone 63 | Global state leaks across displays (§2.H) and blocks testing. Inject dependencies per wallpaper instance. |
| `UserDefaults.standard` direct calls | 119 | Persistence is spread across views, view models and the renderer, with ad-hoc key strings and version-migration flags (`SceneAdditionalControlsVersion`). Centralise it in a typed settings store. |
| Magic `"_owe_…"` string keys | 75 | Renderer behaviour is keyed by strings shared between UI and engine. Replace with typed identifiers. |
| JS embedded in Swift strings | 16 `evaluateScript` sites; single lines of 1,069 and 1,120 chars (ARSE:221, 264) | Unreadable, unlintable and undiffable. Move the runtime prelude to bundled `.js` resources. |
| Concurrency | Swift 5.0 language mode, no strict-concurrency setting; `nonisolated(unsafe)` ×18; manual `NSLock` ×12; `DispatchQueue` ×54; only 15 `@MainActor` | Data races are plausible, for example `frameSnapshot` is set on the render thread and read elsewhere. Adopt Swift 6 / strict concurrency incrementally, with actors for the script runtime and audio. |
| State observation | 14 `ObservableObject`s, 0 `@Observable`; NotificationCenter used as an event bus (7 custom posts) | Fine for macOS 13, but NotificationCenter fan-out, as in music sync, makes data flow hard to follow. |
| Logging | `OWELog` exists (good) but coexists with `print` ×27 and raw `NSLog` ×15. `OWELog` itself routes to `NSLog`, not `os.Logger`. | Use `os.Logger` with subsystem and category, so `log show`/Console can filter it. During this snapshot the app's runtime logs could not be retrieved at all. |
| Dead code | The whole SpriteKit render path (`buildSKScene` VM:405, `buildParticleNode` VM:1645, the SpriteKit `colorBlendMode` handling) is never called. | Delete it (hundreds of lines). It duplicates logic and misleads readers, as in B/D, where "only the SpriteKit path" handles a feature. |
| Heuristics | 13 name/regex special cases (B8) | Each is tuned to specific wallpapers and misbehaves on others. |
| Build settings | `SWIFT_VERSION = 5.0`, deployment target 13.0; app sandbox off; hardened runtime on; ad-hoc debug signing (`CODE_SIGN_IDENTITY = "-"`) | Ad-hoc signing breaks the TCC Screen Recording grant on each rebuild (§2.G). Use a stable development identity. Sandbox off is expected for this app type. |
| Lint / format | No SwiftLint, SwiftFormat or `.editorconfig` | Add SwiftFormat and a light SwiftLint config (file and function length, `force_try`, `todo`). |
| CI | Only `release.yml` (tag → sign → notarize). No PR or push build, no tests. | Add a PR workflow: `xcodebuild build` + `test` + the headless render check on a small fixture corpus. |
| Commits | Mixed conventions (Conventional Commits recently, free-form before). Very large feature commits: 5 commits carry +43k lines. | Smaller, reviewable commits. Keep asset or vendor drops separate from code changes. |
| Docs | README (×3 languages), CHANGELOG and a DocC stub (33 lines). No architecture doc. | Add `docs/architecture.md` covering the render pipeline, the value-resolution model and the script runtime. The README over-claims (for example "multi-pass effects and reflected uniform bindings"), which §2.A shows are not functional. |

### Suggested order (alongside the §6 fixes)

1. **CI safety net.** Add a test target, a PR CI workflow, `os.Logger`, and replace `try?` at pipeline, decode and IO boundaries with logged errors. This is the precondition for landing §6 P1 safely.
2. **Extract the engine.** Move the scene engine into a local Swift package as each §6 area is rewritten: parsing/value resolver → shaders/pass graph → renderer → script runtime. Don't do a big-bang move.
3. **Remove dead weight.** Delete the SpriteKit path and, after P1, the native effect stack and `SceneAuthoredEffectRanges`.
4. **Replace global state.** Swap singletons, `UserDefaults` sprawl and `_owe_` strings for per-wallpaper-instance services and a typed settings store. This also fixes the multi-display property collisions.
5. **Tighten the toolchain.** Move to Swift 6 language mode and strict concurrency per module, once the engine is isolated.
