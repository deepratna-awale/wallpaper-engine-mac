# WE reference comparison

Status: 2026-09-26, branch `deepratna/feature-work`. First triaged at `aecac93`; R1–R4 fixed and re-run at `62e41d8` (the run at `/Volumes/980Pro/dd-agentREF/rb-final`). Our frames against real Wallpaper Engine 2.8.0.42 (the captures on the `we-test-wp-images` branch, `tools/peer/README.md`).

## How it runs

`WEReferenceComparisonTests` draws every captured wallpaper headlessly and compares it with WE's stills. It uses the real loader (`SceneWallpaperViewModel`) and renderer (`renderShared`).

- **Display:** one 1920×1080 display at 100 %, 30 fps. A scene that isn't 16:9 covers the display (fill).
- **Settings:** the capture's settings: post-processing enabled, reflections on, full textures, and volumetrics and shadows per capture folder. Scene detail is full and there is no particle budget.
- **Properties and time:** each wallpaper uses its default properties. The app's stored settings for it are cleared, then put back.
- **Warm-up:** the scene clock stands still until the frame stops changing, while pipelines compile. It then runs at 1/30 s a frame to each still's time: 10 s and 12 s, or 13, 16 and 19 s for the mouse test.
- **Randomness:** particles are seeded (`ParticleRandom`, seed 0), so they draw the same on every run.
- **Cursor:** at the centre of the screen, except in the mouse test.
- **Local time:** Foundation's local time is moved to the time on the capture's taskbar clock (`WEReferenceLocalTime`). This sets `engine.timeOfDay` and `g_Daytime`. JavaScriptCore's `Date` keeps the host's time, so script clocks are masked.
- **Metrics:** the Windows taskbar (bottom 48 px) and each item's masks are left out. The frame is split into 8×6 cells. For each cell and for the whole frame the harness reports:
  - mean colour and luma, and the mean absolute RGB difference;
  - SSIM of 8×8 blocks of the half-size luma;
  - edge alignment: the best shift of Sobel edges at quarter size, ±32 px for the frame and ±24 px per cell.
  - It also ranks the three worst cells by colour Δ + 50·(1 − SSIM).
- **Item checks:**
  - region brightness;
  - what a setting adds over its baseline capture: mean, centroid and axis;
  - the cursor-parallax shift, found the same way as `analyze.py`.
- **Config:** the settings, still times, masks and regions for each item are in `Tests/Fixtures/WEReference/captures.json`.

Run it with:

```sh
git archive origin/we-test-wp-images tools/peer | tar -x -C /Volumes/980Pro/dd-agentREF/peer
TEST_RUNNER_OWE_WE_REFERENCE=/Volumes/980Pro/dd-agentREF/peer/tools/peer \
TEST_RUNNER_OWE_WE_REFERENCE_OUT=/Volumes/980Pro/dd-agentREF/out \
xcodebuild test -project OpenWallpaperEngine.xcodeproj -scheme OpenWallpaperEngine \
  -only-testing:OpenWallpaperEngineTests/WEReferenceComparisonTests
```

- `TEST_RUNNER_OWE_WE_REFERENCE_ONLY=<ids>` limits the run to some items.
- The test is skipped without the captures or the library.
- A full run takes about 10 minutes.
- It writes `report.md` (every metric and the worst cells of every still), `<capture>-<still>-ours.png`, and `<capture>-<still>-compare.png` (WE | ours | difference ×4 in red, masked areas in blue). This report is triaged from the run at `/Volumes/980Pro/dd-agentREF/out`.

## Results

| Item | Still(s) | Mean abs Δ | SSIM | Verdict |
|---|---|---|---|---|
| 2963872291 Pixelart Alice City | still1, still2 | 0.8 | 0.995 | **Matches.** The zero-size solid fix holds, and the media widget's grey note placeholder draws where WE's does |
| 3802047741 Sakura (parallax) | mouse_center / right / left | 0.4 / 0.9 / 4.7 | 0.999 / 0.990 / 0.904 | **Matches** in x (−82 and −164 px, as WE). At the left edge WE sits 2 px lower (R5) |
| 3352730400 Hinata | vol_low / medium / high | 0.4 / 0.5 / 0.2 | 0.998 / 0.996 / 0.999 | **Matches.** The wedge is 40.2 / 40.4 / 40.4 against WE's 40.1 / 40.3 / 40.3 |
| 3352730400 Hinata | vol_disabled still1 / still2 | 2.3 / 5.0 | 0.938 / 0.870 | Matches outside the figure's breathing (N2). The wedge is 15.2, as WE's |
| 2764281221 2B | still1 / still2 | 1.9 / 2.7 | 0.961 / 0.948 | Matches. The rotated flares line up (edge shift 0, 0). still2 catches WE's periodic glitch (N2) |
| 3270035750 One piece girls | still1 / still2 | 8.2 / 5.5 | 0.796 / 0.865 | The tube-light bands match. The figures' bob phase differs (N2). The names match WE's size and place (R1, fixed) |
| 3245833232 Tanjirou | still1 | 17.6 | 0.569 | The fluid fire now flows (R3, fixed); the top strip is 229,114,234 against 210,110,222, the rest is the simulation's phase. The clock matches (R1). still2 is WE's grey capture artefact (N4) |
| 2321732083 Cyberpunk Samurai | still1 / still2 | 7.3 / 7.3 | 0.935 / 0.931 | The puppet is area 7. Brightness and backlight match (R4, fixed) |
| 2515150033 Knight | still1 / still2 | 46.4 / 52.1 | 0.378 / 0.386 | The puppet is area 7 (the sheet is drawn raw). The lit background matches |
| 3455121165 Solar system | all | 7.9 | 0.336 | Area 6: black (the models, and the 2D text in a perspective scene, are missing) |
| 3159348391 PaRappa | all | 84–93 | 0.47–0.56 | Area 6: the clear colour (0.7 grey, 195 after bloom) where WE draws the sky model (R2 fixed) |
| 3378346807 3D Snowflakes | all | 0.2 / 51.6 | 0.99 / 0.84 | The background is WE's clear colour, (65,80,83) exactly (R2, fixed). With shadows high, WE's lit flakes and light shaft are area 6 |
| 3734636606 More Physics | still1, still2 | 134.5 | 0.615 | Area 6: the authored clear colour (magenta) where WE draws the models |
| 3657770939 WE_Phys α_01 | still1, still2 | 163.7 | 0.157 | Area 6: the authored clear colour (0.7 grey) where WE draws the models |

### The specific checks

- **3802047741 parallax:** the image shifts from the left edge by (−82, 0) px to the centre and (−164, 0) px to the right edge. WE's shifts are (−82, −2) and (−164, −2). Against WE's frames, the centre is Δ0.34 and the right edge Δ0.93 unshifted.
  - The left frame is Δ4.3 unshifted and Δ0.95 once moved 2 px vertically (R5).
  - The parallax agent's commits (`7d02897`, `dda3af2`) are tests and docs and didn't change the result. The harness was re-run after they landed.
- **3352730400 volumetric cone, per setting:** brightness matches at every tier (the wedge table above). Low, medium and high are alike in both, and disabled draws no cone in either. Direction also matches:
  - In the added light (vol_medium − vol_disabled), the cone's brightness-weighted x per row agrees within 3 px from y 0 to y 600 (852/850, 824/826, 785/784, 755/757, 772/778 at y 0–400).
  - The harness's axis angle (WE 30°, ours 12°) and the rows below y 600 are thrown off by the figure's breathing. WE restarted between settings, so its baseline and variant differ in phase (N2), and its difference image outlines the whole figure.
  - A side-by-side of the chest and shoulder under the cone shows no visible difference.
  - Nothing to report to the lighting agent.
- **3270035750 tube-light bands:** the bottom 130 rows of each band are 168.0 / 142.0 / 103.6 in WE against 168.1 / 139.9 / 103.4 in ours (still1). still2 is 139.2 / 139.6 for the blue band.
  - The blue band's 2-point gap on still1 is Nami's bob overlapping the strip.
  - In 60 px columns across the bottom strip, the colours match to within 1–2 per channel. The exception is under Nami, x 720–960, which is ±5 with the bob.
- **2963872291 as a whole:** Δ0.8, SSIM 0.995, no edge shift. The worst cell is Δ2 (x 1680–1920, y 688–860: the music widget, 139,146,160 in both).
  - Before the local time was set, this wallpaper looked like a total mismatch: its city layer blends day, dusk and night art by `engine.timeOfDay`.
- **2515150033 Knight's lighting:** the knight is a puppet (area 7), so only the lit background can be checked. It is lit by two point lights, one flickered orange by a script. Its luma matches within 1:
  - castle left of the knight: 87.3 against 86.7;
  - sky at the top left: 128.5 against 128.7;
  - ground at the bottom left: 32.4 against 31.6.
  - The knight itself has to wait for puppets. Where WE shows dark lit armour (41,15,12) we draw pieces of the raw puppet sheet (144,134,136).

## Triage

### Real rendering bugs

**R1 (fixed). Text was drawn about three times too small.**
- Cause: WE sets its FreeType face with `FT_Set_Char_Size(face, 0, pointsize × 64, 300, 300)` (`0x1401ad1c9`, from the text object's `pointsize` at object+0x4e0) and lays glyphs out one atlas pixel per scene unit. The em is `pointsize × 300/72` scene units, not × 96/72. Fitting "Nami" and "Robin" (Deutschlands, 25 pt) against WE's capture gives an em of 104, which is 25 × 300/72.
- At that size a script's string can outgrow the size the editor saved ("SATURDAY" in the block saved for "DAY"). WE's glyph quads aren't clipped, so the block now grows around its text.
- A text object's effects run in buffers of its size, one pixel a scene unit (its `font` material has no texture, see "Solid layers" below). Ours ran them on the text rasterised at its on-screen density: 3245833232's date (scale 0.28 in a 4K scene) was 0.14 px a unit, and `blurprecise` smeared it.
- Now the day name, date and time of 3352730400 and 3245833232, 3270035750's names and the VHS clocks of 2963872291 and 2764281221 match WE's in size and place (`SceneTextLayoutTests`). The clock texts stay masked (N1).
- Before the fix, measured on 3352730400 (bright ink, over y 380–780, x 0–560):

| Text | WE | Ours |
|---|---|---|
| Day name ("SATURDAY") | rows 489–559 (70 px tall) | rows 507–527 (20 px) |
| Date line | rows 574–604, x 148–428 | too small and faint to reach the threshold |
| Time line | rows 620–650 | too small and faint to reach the threshold |
| Media square in the same corner (not text) | rows 678–733, x 245–302 | rows 678–733, x 245–302 |

- The square matches exactly, so the transform and placement are right and the glyph size is wrong.
- The same holds for:
  - 3270035750's names (static text, no parent scale, `pointsize` 25): "Robin", "Nami" and "Boa" are about 2.7× smaller than WE's;
  - 3245833232's clock;
  - 2963872291's VHS clock.
- The text inside each item's clock mask isn't scored. The names and the clock crops in the compare pictures show the bug.

**R2 (fixed). `general.clearcolor` was ignored.** WE clears the scene target to it every frame, as authored, alpha 1 (`0x14018031f…0x140180351`; black when unauthored, `0x140186f61`). The scene pass now does, through its user binding and a script's `thisScene.clearcolor`; 3378346807's background is (65,80,83) as WE's. Before:
- `SceneDocument.clearcolor` is decoded, but the scene pass always clears to `SceneFrameDestination.clearColor` (black): `SceneMetalRenderer.swift:816–820`.
- In 3378346807 WE's empty background is (65,80,83) in every cell. That is the scene's clear colour exactly: the user property `backgroundcolor`, 0.2549 0.3137 0.3255. Ours is (0,0,0).
- 3159348391's clear colour is 0.7 grey. WE covers it with the sky model; we draw black.
- This is independent of models, so it can be fixed before area 6.

**R3 (fixed). 3245833232: the magenta energy at the top was about 20 % darker.**
- Cause: `effects/fluidsimulation`. Isolating the background's effects (a library copy per variant through `OWE_LIBRARY`) showed that with none of them the top strip is the same (164,95,180), the raw texture's colour: the effects added nothing. The fluid simulation never built up, for two reasons:
  - An effect's `swap` command swapped a per-frame copy of the layer's FBO table, so each frame started from the unswapped buffers. The simulation's velocity and dye ping-pong through swaps.
  - FBOs came from the target pool with whatever they last held, never their `clear` colour. With the swaps kept, a NaN in the pressure buffer poisoned the velocity for good.
- Now swaps persist, new FBOs are cleared before any pass reads them, and a chain with a swap is never reused as static (`EffectGraphSwapTests`). The fire flows along the top as in WE; the top strip is (229,114,234) against WE's (210,110,222), within the simulation's phase.
- Before:
- In x 480–1440, y 0–172, ours is (166,95,181) at 10 s and (167,96,182) at 12 s.
- WE's is (208–213, 108–114, 220–225) in every non-artefact frame of its 5 s clip. It's stable, so this isn't animation phase.
- The whole frame is 97.0 against 99.7.
- The background layer runs waterripple, iris, waterwaves, foliagesway, shake, chromatic_aberration, nitro, fluidsimulation, pulse_ and waterflow. The scene has no bloom. `fluidsimulation` and `nitro`, which build up over time, are the first suspects.

**R4 (fixed). 2321732083: the frame was about 11 % darker, and the backlight far dimmer.**
- Cause: the background's `brightness` 0.89. WE multiplies a layer's draw colour by its brightness only under engine flag 0x2000 (`0x140207a2b…0x140207a72`), which the `ultra` and `displayhdr` post-processing settings set (`0x14010e6ba`, `0x14010e6da`). The captures were taken with post-processing enabled, so WE drew it at 1. Found by isolation: without the vhs effect, the particles or bloom nothing changed; brightness 1 matched.
- Now `SceneRenderSettings.appliesBrightness` follows the setting (`RenderCheckTests.testBrightnessAppliesOnlyUnderUltraPostProcessing`). Backlight 244.5 against 246.0, top-left corner 41.3 against 41.1, street 59.1 against 59.0, whole frame 104.0 against 104.0.
- Before:

| Region | WE | Ours | Ours, post-processing disabled |
|---|---|---|---|
| Backlight right of the figure (x 860–960, y 100–400) | 248.3 | 197.6 | 183.8 |
| Dark corner at the top left | 42.5 | 37.8 | 37.7 |
| Street at the lower right | 55.0 | 49.0 | not recorded |

- The disabled column is from a one-off experiment.
- WE's backlight is 244–247 throughout its clip.
- Our bloom (strength 1.97, threshold 0.85; `hdr: true` but LDR under "enabled") adds 14 to the backlight and nothing in the darks. So bloom may be weak, but it can't explain the darks.
- Next suspects: the haze particle systems (`bg_copy1` and five `column_copy1`, `Light shafts 2`), and the `vhs` effect on the background.

**R5 (not ours). The vertical parallax drift.**
- WE's image moves 2 px vertically between the cursor at the left edge and at the centre or right edge; ours doesn't move.
- The cursor is on row 540 in all three captures (`shoot.ps1`), so any y formula (including `1 − cursor.y`) gives the same y in all three; the centre and right frames match WE's y exactly. Only the left capture differs, whose cursor sits on the capture display's boundary (`$b.X`) after coming from the other display. That is the capture's cursor state, not a formula; nothing changed.

**Solid layers' effects (fixed, from the effects agent).** A layer whose material has no texture (a solid layer's `flat`, a shape, a text object's `font`) gets effect buffers of its `size`, rounded (`0x140209206…0x14020923c`), without texture reduction. Ours ran a solid layer's effects on its 1×1 fill, so masks, gradients and blurs collapsed to one colour (21 library layers, e.g. 2963872291's player bars and 3352730400's album shadow). They now start from the fill at the layer's size (`RenderCheckTests.testSolidLayerEffectsRunAtTheLayersSize`).

### Not yet implemented

- **Puppet warp (area 7):**
  - 2515150033: we draw the puppet sheet's texture as an image, so the knight's parts are scattered over the frame.
  - 2321732083: the samurai's parts are scattered.
- **3D models and perspective scenes (area 6):** 3455121165, 3159348391, 3378346807, 3734636606 and 3657770939 draw black apart from R2.
  - Their 2D text and solid layers aren't projected through the perspective camera. In 3455121165 the clock and orbit rings are missing. In 3378346807 the VHS clock lands as a white strip at x 0–63.
- **Shadows:** what WE's high setting adds can't be checked without models.
  - 3378346807: +56.8 mean brightening, centred on (847, 499): the light shaft, glowing flakes and cast shadows.
  - 3455121165: +0.2, centred on (1009, 442).
  - Ours adds 0.

### Expected nondeterminism

- **N1. Clocks:**
  - Script clocks read JavaScriptCore's `Date`, which keeps the host's time; they are masked per item.
  - `engine.timeOfDay` and `g_Daytime` follow the capture's taskbar time.
- **N2. Animation phase:** WE's scene time at the capture is 10 s after it opened the wallpaper, minus an unknown load time. WE also restarted between setting captures. Affected:
  - 3270035750's figures bob by ±12 px (WE's own clip);
  - Hinata breathes: vol_disabled still2 is Δ5.0 with an edge shift of (0, 16), and WE's setting-difference image outlines the figure;
  - 2B's still2 catches a periodic chromatic glitch that ours doesn't have at 12 s.
- **N3. Particles:**
  - rain in 3245833232 and 2321732083: a single long streak in ours at the left of the samurai;
  - 2B's sparkles.
  - They are seeded, so ours repeat run to run, but WE's aren't.
- **N4. Capture artefact:** some of WE's gdigrab and GDI frames of 3245833232 are flat grey (178), including still2. The clip has 6 of 25 such frames at 5 fps. still2 is marked unreliable in the config.
