# SceneScript corpus replay findings

Status: 2026-09-25, branch `deepratna/feature-work`, HEAD `46daecc` plus the WP9 harness. This is what WP9's replay found in [`scenescript-plan.md`](scenescript-plan.md) §5. Paths are relative to `OpenWallpaperEngine/`. "Corpus" is `/Volumes/980Pro/dd-scenescript/corpus`, and a 12-hex name like `08861b7e67b4` is `corpus/scripts/<name>.js`.

## The harness

- `OpenWallpaperEngineTests/SceneScriptCorpusReplayTests.swift` loads every corpus wallpaper. That is 44 library entries, with 3109042108 in both libraries, and 528 sites, the same count per wallpaper as `index.json`. Each wallpaper comes from its `scene.json`, its `scene.pkg`, or the `assets.json` of an asset pack.
- Every script runs at its real site on `SceneScriptRuntime`, on a `SceneScriptThread` of its own, with `SceneScriptInstance.binding` set per site. It uses:
  - the WP3 compiler;
  - WE's prelude and jsmodules;
  - WP4 (engine, timers, storage);
  - WP5 (audio);
  - WP6 (media);
  - WP7 (the object model).
- The object host describes every real object: its transform, strings, instance overrides, effects, and material constants. It also describes property timeline animations and the `TEXS` spritesheet animation from each image's `.tex`. `createLayer` loads from the wallpaper's own files.
- Each run is load plus 600 frames at 60 fps, driven by these fakes:
  - **Clock:** starts at 23:59:52 on 31 December. `Date` is stubbed to it and `Math.random` is seeded.
  - **Audio:** silence, then a moving two-channel tone with a kick every 0.5 s (frames 150–450), then silence.
  - **Cursor:** a moving cursor. Clicks go only to Solid objects (§1.9 P7).
  - **Media:** playing, paused, stopped without a thumbnail, then a new track.
  - **User properties:** every flag, slider and combo is changed at frame 420 and restored at frame 540.
- The test assertions and their checks:
  - **exception:** a compile error or a runtime throw, with the script, line, callback and frame.
  - **watchdog:** the watchdog fired.
  - **text:** a text is "undefined", "NaN", or not a string.
  - **finite:** a site, a table field or a `shared` number is not finite.
  - **change:** an animating script fails its class's expectation:
    - audio scripts vary under the tone and settle in silence;
    - clocks change across midnight;
    - a thumbnail script's effect visibility follows `hasThumbnail`;
    - a media text follows the track.
  - **budget:** the median CPU time of the script thread per frame is at or above 0.5 ms (§4.6). CPU time is used because in the full suite, with other builds running, wall-clock medians reached 0.56–0.58 ms for 2134765860 and 2176097362, where CPU medians stay at or below 0.26 ms for every wallpaper.
- A finding outside `expectedFailures` fails the test. Each expected entry is an `XCTExpectFailure` with its reason, and it fails once its finding is gone.
- `SceneScriptReplayFixtureTests` runs three synthetic wallpapers from `Tests/Fixtures/SceneScript/replay` in CI:
  - **behaviour:** every class expectation, P2 accumulators, P7 Solid-only clicks, `getAnimation` on a material constant, `createLayer`, `scriptproperties` and user properties.
  - **failures:** a compile error, P4 (a throwing `update` is disabled while its media callback keeps running), "undefined" text, and a NaN origin.
  - **watchdog:** a hung `update` halts the runtime.
- WP8 and WP10 have not landed, so `Tests/Fixtures/SceneScript/replay-harness/replay.js` stands in for them:
  - `__rt.hooks.argument` reads the bound property live (P2);
  - `__rt.hooks.coerce` applies returns through the object model's setters (P3);
  - cursor events arrive as an inbox kind targeted at an object slot.
- Set `TEST_RUNNER_OWE_REPLAY_REPORT=<path>` on `xcodebuild` to get the table below as a file.

## Results

Timing is from a Debug build on a shared M-series machine, with other builds running. Load time includes compiling every script.

| wallpaper | sites | load ms | mean ms/frame | p50 | p99 | commands | findings |
|---|---|---|---|---|---|---|---|
| owe/2097947622 | 2 | 1.81 | 0.045 | 0.040 | 0.132 | 0 | ok |
| owe/2406282996 | 1 | 1.25 | 0.052 | 0.048 | 0.178 | 600 | ok |
| owe/2519054915 | 1 | 2.40 | 0.057 | 0.048 | 0.220 | 600 | ok |
| owe/2764281221 | 1 | 2.18 | 0.050 | 0.045 | 0.129 | 600 | ok |
| owe/2818296808 | 5 | 3.81 | 0.069 | 0.062 | 0.221 | 2400 | ok |
| owe/2935714170 | 1 | 9.52 | 0.068 | 0.063 | 0.119 | 94 | ok |
| owe/2978738836 | 15 | 6.14 | 0.092 | 0.073 | 0.384 | 2420 | ok |
| owe/2981960200 | 3 | 7.13 | 0.059 | 0.052 | 0.210 | 1800 | ok |
| owe/3109042108 | 20 | 13.46 | 0.292 | 0.353 | 0.742 | 2428 | ok |
| owe/3121284565 | 3 | 7.20 | 0.054 | 0.047 | 0.174 | 601 | exception (RF1) |
| owe/3187908708 | 22 | 26.55 | 0.130 | 0.117 | 0.334 | 3014 | ok |
| owe/3244466773 | 3 | 8.12 | 0.063 | 0.055 | 0.272 | 1800 | ok |
| owe/3245833232 | 5 | 9.21 | 0.063 | 0.058 | 0.135 | 1800 | ok |
| owe/3352730400 | 19 | 12.37 | 0.079 | 0.069 | 0.278 | 1828 | ok |
| owe/3384308105 | 1 | 11.08 | 0.043 | 0.040 | 0.095 | 0 | exception (WE too) |
| owe/3443078996 | 1 | 1.92 | 0.050 | 0.047 | 0.117 | 600 | ok |
| owe/3453730450 | 71 | 63.74 | 0.225 | 0.204 | 0.663 | 4200 | finite (WE too) |
| owe/3546971487 | 23 | 30.48 | 0.123 | 0.115 | 0.257 | 3016 | change (WE too) |
| owe/3672756984 | 12 | 6.60 | 0.077 | 0.073 | 0.178 | 3001 | ok |
| owe/3677897732 | 9 | 14.83 | 0.092 | 0.086 | 0.175 | 4200 | change (WE too) |
| owe/3742916237 | 1 | 2.26 | 0.046 | 0.040 | 0.164 | 0 | ok |
| owe/3802509485 | 6 | 3.40 | 0.063 | 0.057 | 0.198 | 1800 | exception (WE too) |
| owe/3802900973 | 3 | 7.81 | 0.057 | 0.053 | 0.136 | 1800 | ok |
| owe/3803044683 | 9 | 14.83 | 0.078 | 0.071 | 0.209 | 3000 | ok |
| owe/3803167460 | 7 | 10.70 | 0.068 | 0.061 | 0.234 | 1800 | ok |
| owe/3803728810 | 9 | 14.11 | 0.094 | 0.084 | 0.325 | 4200 | change (WE too) |
| owe/3805976313 | 3 | 7.09 | 0.057 | 0.053 | 0.117 | 1800 | ok |
| owe/3806006894 | 3 | 7.45 | 0.060 | 0.056 | 0.130 | 1800 | ok |
| workshop/1877013475 | 1 | 1.45 | 0.136 | 0.051 | 0.443 | 600 | ok |
| workshop/2134765860 | 32 | 18.83 | 0.131 | 0.120 | 0.361 | 6626 | ok |
| workshop/2176097362 | 25 | 28.78 | 0.153 | 0.138 | 0.506 | 9006 | ok |
| workshop/2224061441 | 1 | 1.90 | 0.052 | 0.045 | 0.195 | 600 | ok |
| workshop/2276071817 | 2 | 7.54 | 0.099 | 0.086 | 0.428 | 726 | ok |
| workshop/2370927443 | 12 | 11.59 | 0.076 | 0.069 | 0.244 | 2411 | ok |
| workshop/2734461061 | 4 | 3.44 | 0.069 | 0.061 | 0.200 | 2400 | ok |
| workshop/2927820378 | 5 | 7.77 | 0.062 | 0.054 | 0.211 | 1202 | ok |
| workshop/2963872291 | 39 | 144.74 | 0.374 | 0.203 | 1.435 | 12468 | exception (WE too) |
| workshop/2978204069 | 30 | 16.81 | 0.106 | 0.092 | 0.333 | 2428 | ok |
| workshop/2981249186 | 6 | 16.12 | 0.081 | 0.073 | 0.259 | 3600 | ok |
| workshop/3000562427 | 80 | 83.09 | 0.226 | 0.191 | 0.825 | 5747 | ok |
| workshop/3019043758 | 1 | 1.72 | 0.053 | 0.044 | 0.297 | 600 | ok |
| workshop/3030025146 | 4 | 4.75 | 0.061 | 0.056 | 0.193 | 2400 | ok |
| workshop/3074485715 | 7 | 9.08 | 0.081 | 0.073 | 0.238 | 4200 | ok |
| workshop/3109042108 | 20 | 13.84 | 0.077 | 0.069 | 0.299 | 2428 | ok |

**Summary.**

- No watchdog trips.
- No "undefined" or "NaN" text.
- No budget failures: every median is below 0.5 ms.
- p99 is above 0.5 ms for 3453730450 and 3000562427 in every run. In some runs it is also above 0.5 ms for 2963872291, 2176097362, 2276071817 and 3109042108. Those spikes are GC or scheduling on a loaded machine, not a steady cost.
- `testMoonReplayPerformance` measures the whole 3453730450 replay: 0.64–0.77 s for load plus 600 frames, including the harness's per-frame sampling.

## Real bugs

### RF1. `createLayer(assetPath)` ignores the script's `__workshopId` (WP7, WP11)

- **Where:**
  - `Resources/SceneScript/objects-scene.js` `IScene.createLayer`: the string and `IAssetHandle` branches send the path as-is.
  - `Scripting/Objects/SceneScriptLayerSource.swift`: `.asset(String)` has no room for the workshop id.
  - `SceneScriptObjectHost.sceneScriptDescribeLayer`: it cannot resolve the path without that id.
- **Evidence:**
  - 3121284565 runs `08861b7e67b4`, the visible script of 'Bar', which exports `__workshopId = '2935714170'`. Line 90 calls `thisScene.createLayer('models/bar.json')`.
  - The file is at `models/workshop/2935714170/bar.json`, with its material at `materials/workshop/2935714170/bar.json`. The converted package's `.owe-bundle.json` lists them there, and there is no `models/bar.json`.
  - WE's editor inserts `__workshopId` with the comment "Do not remove this line or asset references may break" (plan §1.1).
- **Symptom:** `createLayer` returns `null`, and `init` throws at line 91: `TypeError: null is not an object (evaluating 'bar.alignment = thisLayer.alignment')`.
  - `update` then throws at line 128 (`bar.scale = scale`) and is disabled.
  - The audio bars never appear.
  - The asset pack itself (2935714170, the same script as `4919ac5f12ef`) works, because there the path is relative to the pack.
- **Fix:**
  - In `createLayer`, read the calling record's `__workshopId` export: `__rt.byId.get(__rt.current)`, then `rt.exports(record, '__workshopId')`.
  - Pass the id with the path, for example `.asset(path, workshopID:)`.
  - The host resolves `<dir>/workshop/<id>/<file>` first (`models/bar.json` → `models/workshop/<id>/bar.json`), then the plain path.
  - `registerAsset` should resolve the same way.
- **Test:** a fixture scene whose asset lives only under `models/workshop/<id>/`, plus the `08861b7e67b4` expectation in `SceneScriptCorpusReplayTests.expectedFailures`. That expectation fails once this is fixed; delete it then.

### RF2. Unchanged strings are flushed as commands every frame (WP7, WP8)

- **Where:** `Resources/SceneScript/objects-layers.js`:
  - `writeString` marks the field pending on every write;
  - `flushStrings` pushes one `setString` per pending field without comparing it with the last value it flushed.
- **Evidence:**
  - Every text site that returns the same string each frame yields one `setString` per frame: 600 commands in 600 frames for 2519054915 (one text site), 2224061441 and 1877013475.
  - Property binding writes a script's return through the same path each frame. WP8 will do the same natively, and the harness stands in for it here.
- **Why it matters:** from WP11, each `setString` reaches the renderer and relays out the text. That is per frame for every clock and title, although the plan expects text to change "at most once a second" (§4.3).
- **Fix:** in `flushStrings`, remember the last flushed value per (slot, field) and skip the push when it is equal. Compare at flush, not at write, so A→B→A within one frame still flushes nothing.
- **Test:** a text site returning a constant produces one `setString` in 600 frames.

## Expected findings that are WE's behaviour (not bugs)

These are listed in `SceneScriptCorpusReplayTests.expectedFailures`, with reasons.

- **`8bb9b9a54120`** (3802509485): a string literal is broken across lines. V8 rejects it as well, so it is a compile error at line 2.
- **`03f0db0a6dff`** (3384308105): the scene has no layer whose name contains "Big". The frame-420 property change picks a mode that indexes the empty list, and `getLayer(undefined)` is `null` in WE too (line 168).
- **`f629892e644b`** (3453730450, 'TY' angles): reads `shared.wrx`, which the same object's `origin` script (`c4594f29b0a8`) sets in its first `update`.
  - Running `angles` first gives NaN on frame 0, and P3 says WE writes the NaN too.
  - The order of scripts within one object is P1's best guess. We follow the scene.json key order, which is alphabetical.
- **`f86e0df8a16e`** (2963872291, the Solid 'playerplay'): there are no `.mp3` sound layers, so `cachedSongs` is empty and a click throws at lines 114 and 54, in WE too.
- **`7d3bc214624c`** (3546971487): its `scriptproperties` clamp the scale to [2.7, 2.8], and a spectrum average never reaches 2.7, so the value is constant.
- **`11844b104b6a`** (3677897732, 3803728810): bound to a constant authored as 0, which it multiplies by the audio level, so the value is constant.
