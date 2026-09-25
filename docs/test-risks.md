# Test risks: renderer (A), shaders M9 (B), recent `git log -25`

Status: 2026-09-25, branch `deepratna/feature-work`. Adversarial list; ranked by severity × likelihood.
Paths are relative to `OpenWallpaperEngine/`. **A** = renderer agent, **B** = shaders agent, **R** = already landed.

| # | Sev | Owner | Risk |
|---|-----|-------|------|
| 1 | Critical | B | Stale disk variants after the M9 switch |
| 2 | Critical | B | glslang global state is not thread-safe in-process |
| 3 | Critical | B | Static-lib symbol clashes (glslang / SPIRV-Cross / others) |
| 4 | High | B | Corrupt or foreign `MTLBinaryArchive` |
| 5 | High | B | Binary archive keyed to one GPU; GPU switch / eGPU / multi-display |
| 6 | High | B | Async pipeline compile races with `releaseLayer` |
| 7 | High | B | In-process crash/hang replaces a recoverable subprocess failure |
| 8 | High | B/R | Release/CI packaging still expects `shader-tools`; hardened runtime |
| 9 | High | R | Render-target pool evicts targets whose contents must survive |
| 10 | High | A | Screen-space scene snapshot sized/oriented wrong |
| 11 | High | R/A | Retina target on 5K / multi-display / display change |
| 12 | High | A | `.center` placement in points vs pixels |
| 13 | Med | A | `.tex` content size vs allocated (power-of-two) size |
| 14 | Med | A | Freeing effect state for removed clones: use-after-free / leak |
| 15 | Med | A | Particle velocity/gravity under parent rotation |
| 16 | Med | A/B | Pointer and parallax uniforms: coordinate space, multi-display |
| 17 | Med | R | Scene clock after sleep/wake, pause, speed 0 |
| 18 | Med | R | Static-chain cache key reuse (`ObjectIdentifier`) |
| 19 | Med | R | Bundled WE assets on first launch / read-only / translocated bundle |
| 20 | Med | R | Pool byte accounting and budget under memory pressure |
| 21 | Med | R | Per-wallpaper property store key collisions / migration |
| 22 | Med | R | Music-sync on effect overrides |
| 23 | Low | R | LRU caches: not thread-safe, clock wrap, capacity churn |
| 24 | Low | B | Cache dir: bundle id, disk-full, concurrent instances |
| 25 | Low | B/CI | CI runner with older Xcode / SDK |

---

## 1. Stale disk variants after the M9 switch — Critical, B
**Scenario.** The disk cache key includes `revision` and a toolchain fingerprint (`Scene/Shaders/ShaderVariant.swift:54`, `:67-69`, `:123-126`). The fingerprint is built from the *executables'* path/size/mtime (`:75-80`) and is `""` when no process toolchain is used (`:69`). After M9, if the in-process path yields `""` (or any constant), a user who upgrades keeps MSL produced by the old Homebrew glslang/spirv-cross. If in-process SPIRV-Cross options differ (MSL version, argument buffers, `--msl-decoration-binding`, reflection JSON shape), the cached reflection no longer matches what the new binder expects: wrong buffer indices, black layers, or a Metal validation failure. Also: the reverse (downgrade) and a user who still has Homebrew installed.
**Test.**
- Unit: assert `cacheKey(...)` differs between the process toolchain and the in-process toolchain for the same inputs; assert the in-process fingerprint includes glslang + SPIRV-Cross *library* versions (e.g. `glslang::GetVersion()`, `SPIRV_CROSS_C_API_VERSION`) and the option set.
- Unit: seed `~/Library/Caches/com.winddog.wallpaper-engine/shader-variants` with a v4 JSON for a known key, run the new build, assert it is not read (or is re-translated).
- CLAUDE.md rule: bump `ShaderVariantTranslator.revision` in the same commit; add a test that fails when the translator output hash for a fixed corpus changes without a revision bump (golden-file test).

## 2. glslang global state is not thread-safe in-process — Critical, B
**Scenario.** `glslang::InitializeProcess()`/`FinalizeProcess()` are process-global and ref-counted; older glslang has a global pool allocator and symbol-table init that races. Today each translate is an isolated process (`Scene/Shaders/ShaderCompiler.swift:76`), so parallel loads (multi-display, each display's scene loading at once; preloading many effects) were safe. In-process, two `variant(...)` calls run concurrently (`ShaderVariant.swift:109-121` only locks the memory map, not translation) → heap corruption, sporadic wrong SPIR-V, or crashes that are not reproducible. Calling `FinalizeProcess` per compile while another thread compiles is a use-after-free.
**Test.**
- Stress unit test: 64 concurrent `translate` calls over 16 different WE shaders on `DispatchQueue.concurrentPerform`, run under Thread Sanitizer and Address Sanitizer, 50 iterations; compare every output byte-for-byte to a serial run.
- Assert `InitializeProcess` is called exactly once (e.g. `static let` / `dispatch_once`) and `FinalizeProcess` never while the app lives.
- Manual: two displays, two different heavy scene wallpapers, launch with an empty cache.

## 3. Static-lib symbol clashes — Critical, B
**Scenario.** glslang ships its own `spv::` headers and SPIRV-Tools; SPIRV-Cross embeds `spirv.hpp` (`spv::` namespace too). Linking both statically can give ODR violations (different `spv::Op` enum sizes, duplicated inline functions) — the linker silently picks one; crashes only on specific opcodes. Also clashes with any other C++ in the process (MoltenVK-like libs, a future `.mdl` loader). Duplicate `-lc++` / different C++ standard libraries between prebuilt libs and Xcode.
**Test.**
- Build step: `nm -gU` the app binary, grep for duplicate weak `spv::` symbols; fail CI if the linker emits "duplicate symbol" or ODR warnings (`-Wl,-warn_commons`, `-Wodr` with LTO).
- Round-trip test: translate the whole bundled `we-assets/shaders` corpus in-process and compare to the process path (golden). Any difference that is not whitespace is a bug.
- Build Release with LTO and with `-dead_strip`; run the same corpus test on the Release binary.

## 4. Corrupt or foreign `MTLBinaryArchive` — High, B
**Scenario.** App killed mid-`serialize(to:)`; disk full; the file written by a newer macOS/driver and read by an older one after a downgrade; two app instances (or login-item + manually launched) writing the same archive. `makeBinaryArchive(descriptor:)` with a corrupt URL throws — or succeeds and `makeRenderPipelineState` crashes deep in the driver.
**Test.**
- Unit: write random bytes / a truncated real archive to the archive path, launch the loader, assert it deletes the file and falls back to an empty archive without crashing.
- Serialize to a temp file then atomically rename; unit test that no partial file exists at the final path after a simulated failure.
- Manual: `kill -9` the app during first-launch warmup, relaunch.

## 5. Binary archive tied to one GPU; GPU switch — High, B
**Scenario.** Archives contain GPU-specific binaries. MacBook Pro with dGPU/iGPU switching, eGPU hot-plug, or two displays on different GPUs (Intel Mac Pro): a pipeline looked up in an archive from another device silently recompiles (fine) — or code passes the archive to a device other than the one it was created with (error). Also an OS update invalidates everything; archive grows unbounded as keys accumulate.
**Test.**
- Key the archive file by `device.registryID` + OS build + app version; unit test the path function.
- Manual: Intel MBP, toggle "Automatic graphics switching", plug an external display, confirm no errors in `/usr/bin/log stream --predicate 'subsystem CONTAINS "wallpaper"'`.
- Check archive size after 44-wallpaper library sweep, then again after 3 sweeps (should not grow).

## 6. Async pipeline compile races with `releaseLayer` — High, B
**Scenario.** A layer requests a pipeline asynchronously, then the wallpaper is switched (or a clone is removed, see #14) and `releaseLayer` runs before the completion handler; the handler writes into freed state or re-inserts a pipeline for a dead layer (leak). Two layers requesting the same key concurrently compile twice and one overwrites the other's cache entry while a frame is encoding with it.
**Test.**
- Unit: fake compiler with a controllable delay; request → `releaseLayer` → complete; assert no entry remains and no crash (TSan).
- Unit: two concurrent requests for one key produce one compile (in-flight dedupe).
- Manual: rapidly switch wallpapers (arrow keys in library) 30× with an empty cache.

## 7. In-process failure modes replace a recoverable subprocess — High, B
**Scenario.** The spawn path has a 30 s timeout and isolates crashes (`ShaderCompiler.swift:73`, `:76-100`). In-process, a glslang `assert`/`abort` on a malformed WE shader, an infinite loop in the preprocessor, or a stack overflow on deeply nested macros kills the whole app — and the menu-bar/login-item app then crash-loops on relaunch with the same wallpaper. `/tmp/owe-failed-shaders` dumping may also be lost.
**Test.**
- Fuzz: feed the translator truncated/garbled versions of 50 WE shaders; the app must return an error, not abort. Build glslang with `NDEBUG` in Release.
- Test that a failed shader still lands in `/tmp/owe-failed-shaders`.
- Crash-loop guard: if the app crashed during translation last launch, start without restoring the wallpaper (manual: inject a crash).

## 8. Packaging still expects `shader-tools`; hardened runtime — High, B / CI
**Scenario.** The release workflow asserts `Contents/Resources/shader-tools/glslangValidator` and `spirv-cross` exist and are executable, and CI `brew install`s them (`.github/workflows/*` "Verify bundle before notarizing"; `brew install glslang spirv-cross`). M9 removes them → release fails, or the tools are kept and unsigned binaries are notarized needlessly. If glslang is instead linked as a *dylib*, it must be signed with the same team, embedded under `Frameworks`, and library validation (hardened runtime) rejects an unsigned/ad-hoc dylib at launch — works in Debug, crashes in the notarized build. `SceneShaderTranslator.swift:18-19` still searches `/opt/homebrew/bin` and `/usr/local/bin`: a stale Homebrew toolchain could be preferred over the in-process one.
**Test.**
- Update the verify step: assert no `shader-tools`, run `codesign --verify --deep --strict` and `otool -L` shows no `/opt/homebrew` paths.
- Manual on a clean Mac/VM with no Homebrew: install the notarized DMG, open a scene with effects.
- Unit: the translator factory returns the in-process backend even when `/opt/homebrew/bin/glslangValidator` exists.

## 9. Pool evicts targets whose contents must survive — High, R (9cccfe2, d05e689)
**Scenario.** `SceneRenderTargetPool.endFrame()` drops any bucket untouched for 600 frames (`Scene/Rendering/SceneRenderTargetPool.swift:64-67`) and `evictOverBudget` drops the LRU bucket over 256 MB (`:73-80`). Anything that relies on *previous-frame content* (ping-pong feedback effects, `_rt_` persistent targets, cached static-chain results from #18) gets a fresh uninitialised texture: trails reset, or garbage because `.private` storage is not cleared. 600 frames = 5 s at 120 Hz, 10 s at 60 Hz, so a layer hidden by a script for a few seconds loses its state; behaviour depends on refresh rate. Also: `texture(...)` returns `buckets[key]!.textures.first` (`:46-48`) — two consumers of the same size in one frame get the *same* texture unless `avoiding` is passed.
**Test.**
- Unit: request A, then `endFrame()` 601× without touching A, request again → assert the caller that holds a persistent target is notified/re-seeded (or persistent targets are excluded from the pool).
- Unit: two requests of the same key within a frame without `avoiding` → assert distinct textures (or document the contract).
- Headless: render a feedback-effect wallpaper 120 frames, hide the layer for 700 frames, show it → compare to reference.

## 10. Screen-space scene snapshot — High, A
**Scenario.** Rotated or partly off-screen layers whose effect reads the scene (`_rt_FullFrameBuffer`, refraction). Edge cases: rotation 90°/180° (width/height swap), negative scale (mirrored), layer entirely off-screen (zero-size rect: `pixelRect` returns nil at `Scene/Rendering/SceneRenderResolution.swift:33-`), snapshot taken before vs after the layer's own draw (feedback into itself), Retina scale (#11) applied twice or not at all, y-flip between scene y-up and texture y-down.
**Test.**
- Headless render check: synthetic scene with a checkerboard background and a 45°-rotated layer running a pass-through "sample framebuffer" effect; the output inside the layer must equal the background pixels under it (tolerance 1/255). Repeat for 90°, 180°, mirrored, half off-screen, fully off-screen.
- Unit: `pixelRect` for a box beyond every edge returns nil; for NaN/inf returns nil.
**Status (R1, 2026-09-25).** Verified by `SceneRegionResampleTests` (e3cb90f): a headless round trip through `sceneCopyFragment` and `sceneVertex` gives back the scene beneath for quads at 0/45/90/180/270°, mirrored on x or y, sheared, and half or fully off-screen. Zero, NaN and infinite quads cover no pixels. `pixelRect` no longer exists (bd8ceba).

## 11. Retina target on 5K / multi-display / display change — High, R/A
**Scenario.** `pixelsPerUnit` caps at 8192 px and `maximumPixelCount` (`SceneRenderResolution.swift:10-23`). A 1920×1080 scene on a 5K (5120×2880) display → ~2.67 ppu → 5120×2880 targets × every effect pass × rgba16Float = hundreds of MB, immediately over the pool's 256 MB budget (#20) → eviction thrash every frame. Dragging a window between a 1× and 2× display, or `didChangeScreenParametersNotification` (`App/AppDelegate.swift:107`), must re-size targets; `g_Screen` is set from `drawableSize` (`Scene/Rendering/SceneMetalRenderer.swift:356`) — check effects that divide by `g_Screen` still line up with a target that is not the drawable size. Ultrawide 32:9 or portrait scenes on a landscape display.
**Test.**
- Unit: table test of `pixelsPerUnit`/`targetSize` for 5K, 6K XDR, 32:9, portrait, 0-size drawable, scene 1×1, scene 20000×20000.
- Manual: 5K or 6K display + laptop panel, move a scene between them, watch memory in Activity Monitor and `/usr/bin/log` for pool churn.
**Status (R1, 2026-09-25).** Fixed 79223dc: the scene target follows the drawable's density with no 5K or 8192 px cap, as WE draws at the display's resolution. Only a target past Metal's 16384 px limit is scaled to fit; before, it failed to allocate every frame. Verified by `SceneRenderPrimitivesTests.testTargetSizeTable` (5K, 6K, 32:9, portrait, no drawable, 1×1, 20000², NaN) and `testTargetIsLimitedOnlyByTheLargestTexture`. `g_Screen` is the target size (053cb7d). Open: effect-target memory at 6K against the pool's 256 MB budget is unmeasured (the pool is B's). Moving between displays is manual (QA 4).

## 12. `.center` placement in points — High, A
**Scenario.** `WallpaperPlacement.center` (`Library/WallpaperPlacement.swift:7`) now in points: on a 2× display a 1920×1080 image is drawn at 3840×2160 pixels (larger than a 1440p-point screen → cropped) — is that what WE does? Mixed-DPI setups; scaled resolutions ("Looks like 1680×1050" on a 2880×1800 panel, backing scale 2 but not integer mapping); video and web wallpapers using the same enum.
**Test.**
- Unit: placement rect for (image 1920×1080, screen 1440×900 pt, scale 2) and scale 1; compare to WE on Windows at 100%/200% (screenshots).
- Manual: System Settings → Displays → switch between scaled modes while a centered scene/video runs.
**Status (R1, 2026-09-25).** Verified by `SceneRendererPlacementTests.testCenterPlacementIsOnePointPerSceneUnit` and `testCursorMapsThroughThePlacement` (070eafd). Open: whether WE's own centre placement is one point or one pixel per unit at 200 % needs WE-on-Windows captures at 100 % and 200 % scaling.

## 13. `.tex` content size vs texture size — Medium, A
**Scenario.** WE `.tex` files store an allocated (often power-of-two) size and a content size. Passing the content size to effects (`g_Texture0Resolution`, `g_TexelSize`) wrong way round → UVs off by the padding; sprite sheets (animated `.tex`) where each frame has its own size; mipmapped `.tex` where only mip 0 has the content size; content size 0 in old files.
**Test.**
- Unit on `Scene/Format/TEXParser.swift`: fixtures with padding (e.g. 1000×600 in 1024×1024), sprite sheet, content size 0 → assert fallback to texture size and `xy/zw` components of `g_Texture0Resolution` are (texture, content) as WE expects.
- Headless: an image layer with a padded `.tex` + a pass-through effect → no visible border strip.
**Status (R1, 2026-09-25).** Fixed 6fb64b5: unsized layers and sprite frames were sized by `NSImage.size`, which is in points and depends on DPI, instead of pixels. Verified by `TexContentCropTests` (including `testLayerSizeIsInPixelsWhateverTheImageDPI`), `SceneRendererPlacementTests.testCompressedTextureCarriesContentSize`, `EffectGraphCachingTests.testTextureResolutionReportsAllocatedThenContentSize` and `ImageMaterialRenderTests.testPaddedContentCropMatchesTheNativeDraw`.

## 14. Freeing effect state for removed clones — Medium, A
**Scenario.** Script `destroyLayer`/clone removal while the frame is encoding: freeing the effect state (targets returned to the pool) while the GPU still reads them from an in-flight command buffer → next frame hands the same texture to another layer while GPU still writes it (flicker). Removing a clone that shares a static-chain cache entry with its original (#18). Clone removed and re-created in the same frame gets the old state.
**Test.**
- Unit: create 100 clones, remove all, run `endFrame()` → assert state count back to baseline (leak check).
- Headless: script that creates/destroys a clone every frame for 1000 frames; memory flat, no Metal validation errors (`MTL_DEBUG_LAYER=1`).
**Status (R1, 2026-09-25).** Verified by `SceneDeferredReleasesTests` (6e51f34): state waits for the command buffer that last drew it, and a re-created id keeps its new state. Also by `ImageMaterialRenderTests.testRemovedClonesFreeTheirUniformState` (100 clones leave 0 programs) and `EffectGraphTests.testReleaseLayerFreesItsStateAndTargetsAreReused`. Open: a 1000-frame create/destroy run under `MTL_DEBUG_LAYER=1` is manual.

## 15. Particle velocity/gravity under parent rotation — Medium, A
**Scenario.** Emitters in world vs local space (`Scene/Loading/SceneParticleEmitterSpace.swift`). Rotating the parent should rotate emitted velocity but *not* gravity (gravity is world-space in WE) — or the reverse depending on flags. Double application when both parent and emitter are rotated; non-uniform parent scale; negative scale; animated parent rotation (already-emitted particles must not swing with the parent in world-space mode).
**Test.**
- Unit: emitter with velocity (0,100) and gravity (0,-10), parent rotated 90°: assert after 1 s the particle position in both space modes matches hand-computed values.
- Manual: compare with WE on Windows for a snow/rain wallpaper with a rotated emitter.
**Status (R1, 2026-09-25).** Unchanged, because particle code is the particle agent's. Verified by `SceneRendererPlacementTests.testEmitterDirectionsFollowParentRotationNotScale` and `SceneReviewFixTests.testEmitterSpaceIncludesParentScaleAndRotation`. Open: bd8ceba turns gravity with the emitter; whether WE does needs a WE capture of a rotated snow or rain emitter.

## 16. Pointer and parallax uniforms — Medium, A/B
**Scenario.** `g_PointerPosition`, `g_PointerPositionLast`, `g_PointerState`, `g_ParallaxPosition` (`Scene/Rendering/BuiltinUniforms.swift:67-68`, `:110-113`). Pitfalls: y-up vs y-down; normalised to the display vs to the scene (cropped with `cover` placement); multi-display (cursor on display 2 while display 1 renders — clamp or freeze?); desktop covered by windows (no mouse events delivered to the desktop-level window; must poll `NSEvent.mouseLocation`); `pointerLast == pointer` on first frame (no velocity spike); parallax influence 0 and the `0.5 + (mouse − 0.5)·influence` formula (`:15`); uniforms stay constant when "pause on fullscreen app".
**Test.**
- Unit: frame context builder with mouse at each display corner, display origin negative (display left of main), scene cropped → expected values.
- Manual: a parallax wallpaper, move cursor across two displays arranged vertically.
**Status (R1, 2026-09-25).** Verified by `SceneRendererPlacementTests.testCursorMapsThroughThePlacement` (070eafd: fill, fit, center and stretch, clamped to 0…1), `BuiltinUniformTests.testPointerParallaxAndScreen` and `SceneCursorTrackerTests` (the pointer stays put while on another display; on the first frame `pointerLast == pointer`). y points up (0 at the bottom), which matches the flip WE's own `cursorripple` and `xray` shaders apply ("Flip pointer screen space Y to match texture space Y"). Open: confirming the on-screen ripple position needs a WE capture. Under `fill` cropping, the pointer is normalised to the scene, not the display.

## 17. Scene clock after sleep/wake, pause, speed 0 — Medium, R (d75c0b0)
**Scenario.** `SceneClock.advance` clamps a frame delta to 0.25 s (`Scene/Rendering/SceneClock.swift:9`, `:22`), good for sleep. But `g_Time` is sent as `Float(frame.time)` (`BuiltinUniforms.swift:107`); after days of uptime without re-load precision drops (at 2^17 s ≈ 36 h resolution is ~8 ms; at ~1 week 60 ms) → jittery animations. Speed 0 stops time: any code that divides by `delta` gets NaN. Is `g_Daytime` wall-clock (should be) and not the scene clock?
**Test.**
- Unit: advance with speed 0, NaN, negative, inf, backwards wall time, 1-hour gap.
- Unit: set time to 7 days and assert that effects use a wrapped time (or doc the limitation).
- Manual: close the lid 10 min, open: no jump, no burst of particles.
**Status (R1, 2026-09-25).** Fixed 19e6ec7: a non-finite wall time made the clock NaN permanently. Verified by `SceneRenderPrimitivesTests.testClockSurvivesDegenerateSpeedsAndWallTimes` (speed 0, −1, NaN and ±∞, a backwards clock, an hour-long gap), `testSpeedChangeDoesNotJump` and `BuiltinUniformTests.testTimeIsNotWrappedOverLongRuns` (`g_Time` is not wrapped, as in WE; debcb9f). `g_Daytime` reads the wall clock.

## 18. Static-chain cache key — Medium, R (30836fa)
**Scenario.** The cache compares textures by identity because an `ObjectIdentifier` can be reused after free (`Scene/Rendering/EffectGraphRenderer.swift:52`). Remaining holes: a *reused* pool texture (#9) is the same object with new content → stale cache hit; scripted `g_Color`/`g_Alpha` or user-property changes that are not in the key (roadmap area 8 item 5); music-sync override (#22) changes a constant every frame yet the chain is cached as static.
**Test.**
- Unit: build a chain, change only a user property bound to an effect constant → assert the chain re-renders.
- Unit: return a texture to the pool, have another layer write into it, assert the cache misses.
**Status (R1, 2026-09-25).** `EffectGraphRenderer` is B's. Verified by `EffectGraphReuseTests.testStaticChainRerendersWhenColorAlphaOrInputVersionChange` and `EffectGraphTests.testStaticChainIsReusedAndAnimatedChainIsNot`. User-bound and music-synced constants are dynamic, so their chains are never cached as static (`UniformProgram.isStatic`).

## 19. Bundled WE assets: first launch, read-only, translocation — Medium, R (0916434, f2abfb8)
**Scenario.** `WallpaperEngineAssets.directory` = configured ?? bundled (`Core/WallpaperEngineAssets.swift:28-30`). First launch on a Mac with no WE install and no Homebrew: effects must work purely from `we-assets` + in-process translation. The app bundle is read-only (DMG, `/Applications` owned by root, App Translocation from Downloads): any code that writes derived files next to `we-assets` fails. A stale `WallpaperEngineAssetsDirectory` default pointing at an unmounted external drive → `configured` returns nil (good) but is it re-evaluated after the drive mounts? The tests now use the bundled copy (f2abfb8): tests may pass with the bundle but miss regressions in a real WE install with newer shaders.
**Test.**
- Manual: fresh macOS user, no Homebrew (`PATH` without `/opt/homebrew`), download the notarized zip, open it from Downloads (translocated), pick an effect-heavy scene.
- Unit: `chmod -R a-w` a copy of the bundle resources, run a load; assert no writes.
- CI: keep one optional job that runs the WE-asset tests against a real install when present.
**Status (R1, 2026-09-25).** Fixed cd4e7e6: shared assets came from either the configured install or the bundled copy, never both. A file an older install lacks now resolves from the bundled copy. Verified by `WallpaperEngineAssetsTests`: the bundled copy ships and is used with no install, an install on a drive that mounts later is picked up, and the lookup order holds. Open: a read-only or translocated bundle and a Mac without Homebrew are manual (QA 1).

## 20. Pool byte accounting under memory pressure — Medium, R
**Scenario.** `bytes(of:)` ignores mip levels, array layers, MSAA sample count, and compressed/depth formats default to 4 bpp (`SceneRenderTargetPool.swift:82-92`), so resident memory is under-counted. No reaction to `DispatchSource.makeMemoryPressureSource` or `MTLDevice.currentAllocatedSize`; `evictOverBudget` never evicts the protected key, so one giant bucket (5K rgba16Float with many layers) exceeds the budget forever. 8 GB Macs with shared memory under pressure → system swapping.
**Test.**
- Unit: pool with 1 MB budget, request a 4 MB texture → assert it's served and a later small request evicts it.
- Manual: 8 GB Mac, two 4K displays with heavy scenes + Xcode open; `memory_pressure -l warn`; watch the app's footprint.
**Status (R1, 2026-09-25).** The pool is B's. Fixed by 7272f67: it counts `allocatedSize`, never evicts leased targets, and ages targets out by wall time. Verified by `SceneRenderTargetPoolTests`. Open: nothing reacts to memory pressure (`DispatchSource.makeMemoryPressureSource`).

## 21. Per-wallpaper property store — Medium, R (0ba2720, 286158d)
**Scenario.** Keys per wallpaper instance: same wallpaper on two displays (one store or two?), workshop id vs folder path (a moved library changes keys → user settings lost), a property named with dots/slashes, deleting a wallpaper leaves orphans, a property changing type after a workshop update (bool → combo) → decode fails and crashes or silently resets.
**Test.**
- Unit on `Scene/Scripting/SceneUserPropertyStores.swift`: type change on stored value, two displays same wallpaper, key containing `.`.
- Manual: set a colour on display 1, check display 2; move the library folder; relaunch.
**Status (R1, 2026-09-25).** Verified by `SceneUserPropertyStoreTests` (1011bf9): a bool that becomes a combo, keys with dots and slashes, and one wallpaper on two displays sharing one entry. Open: it's unknown whether WE keeps properties per monitor. Keys are directory paths, so a moved library loses its settings; keying on the workshop id would fix that (not changed).

## 22. Music sync on effect overrides — Medium, R (3ca15ea)
**Scenario.** Inspector override of an audio-bound constant: when audio capture is denied or stops (sleep/wake, device switch to AirPods), does the override freeze at the last value or fall back to the authored one? Override removed while music is playing. Interaction with #18 (static-chain cached). Audio buffers from two scenes on two displays.
**Test.**
- Manual: enable an override on an audio-reactive effect, deny screen/audio recording permission, then grant; switch output device mid-song.
- Unit: override resolution with a nil audio snapshot returns the authored value.
**Status (R1, 2026-09-25).** Verified by `SceneReviewFixTests.testSyncedOverrideFallsBackToItsValueWithoutAudio` (1011bf9). When capture stops or is denied, `resetAudioLevels` sets the level to 0, so a synced override reads the user's value. `testSyncedOverrideBindsToItsProperty` makes it a dynamic `.user` binding, so #18 never caches it. Open: switching the output device mid-song is manual (QA 14).

## 23. LRU caches — Low, R (d75c0b0)
**Scenario.** `SceneLRUCache` is a struct with no lock (`Scene/Rendering/SceneLRUCache.swift:3-21`); fine only if every access is on the render thread — any access from a load/background queue (text layout preparation, font registry) is a data race. Eviction is O(n) per insert past capacity; text layers whose string changes each frame (clock wallpapers) churn the 128-entry text cache (`SceneMetalRenderer.swift:128`) and re-rasterise every frame.
**Test.**
- TSan run of a clock-text wallpaper for 60 s.
- Unit: capacity 2, insert 3, assert the least recently *read* entry goes.
**Status (R1, 2026-09-25).** Verified by `SceneRenderPrimitivesTests.testLRUEvictsLeastRecentlyUsed`: the least recently *read* entry goes. The text cache is touched only on the main (render) thread, and content loads hand off to main before touching it. The `UInt64` clock doesn't wrap in practice. Open: a TSan run of a clock wallpaper is manual.

## 24. Cache directory hygiene — Low, B
**Scenario.** Variants live under `Caches/com.winddog.wallpaper-engine/shader-variants` (`ShaderVariant.swift:86-88`) — hard-coded id that doesn't match the renamed app; sandboxed builds get a container path. Disk full → `write(.atomic)` (`:190`) throws: must not crash. Two app instances writing the same key (atomic rename makes this safe) but the binary archive (#4) is not. Unbounded growth over library sweeps.
**Test.**
- Unit: point the cache dir at a read-only folder → translation still succeeds (no persist).
- Manual: check cache size after 44-wallpaper sweep; add a size cap or document.

## 25. CI with older Xcode / SDK — Low, B/CI
**Scenario.** CI uses `macos-15` and picks the latest Xcode; a runner with an older Xcode lacks newer `MTLBinaryArchive`/Metal 3 APIs or C++20 features glslang needs; prebuilt static libs compiled with a newer clang (`-fcoroutines`, newer libc++ ABI) fail to link on older Xcode; deployment target mismatch warnings ("built for macOS 15 newer than 14"). Building glslang from source in CI adds minutes and may time out.
**Test.**
- Add a CI matrix leg with the oldest supported Xcode; `-Werror` on "was built for newer macOS version".
- Guard new Metal APIs with `if #available` and a unit test that the fallback path (no archive) still compiles pipelines.

---

## Manual QA checklist (on screen)

1. Fresh macOS user, no Homebrew, no WE install: open the notarized app from Downloads, pick an effect-heavy scene; effects render, `Console` shows no shader errors, `/tmp/owe-failed-shaders` stays empty.
2. Delete `~/Library/Caches/com.winddog.wallpaper-engine`, launch, time the first load of a heavy scene (should be seconds, not minutes); relaunch, second load near-instant.
3. `kill -9` the app during that first load; relaunch: no crash, no crash loop.
4. Two displays (one Retina, one not), two different scenes; drag/rearrange displays in System Settings; change a scaled resolution. Text stays sharp, nothing misaligned, memory stable.
5. 5K/6K display: check Activity Monitor memory after 5 minutes; should plateau.
6. Move the cursor across both displays on a parallax and a pointer-reactive wallpaper; no jumps at the display border, correct y direction.
7. Rotated-layer wallpaper with a refraction/framebuffer effect: no offset or mirrored background.
8. A `.center` placed wallpaper on 1× and 2× displays: same apparent size as WE on Windows at 100%/200%.
9. Particle wallpaper with a rotated parent: gravity still points down.
10. Speed slider 0 → 1 → 3 and back: no jump in time; pause/resume.
11. Sleep 10 min, wake: animations continue smoothly, audio-reactive effects resume, no particle burst.
12. Hide a feedback/trail layer via script or property for >10 s, show it: no garbage frame.
13. Set user properties on one wallpaper, switch away and back, relaunch: values kept; other wallpapers unaffected.
14. Enable a music-synced effect override, play music, switch output to headphones, deny then grant audio permission.
15. Rapidly switch wallpapers 30× in the library: no crash, memory returns to baseline.
16. Intel MBP only: toggle automatic graphics switching / plug external display: no blank frames.

---

# Area 1: image materials and geometry emulation

Status: 2026-09-25, branch `deepratna/feature-work`, base `4154ccd`. Roadmap area 1 items 3 and 4.
**E** = image-material agent (genericimage/2/3/4 and custom image-layer materials drawn through WE shaders).
**F** = geometry-emulation agent (`genericparticle.geom`, `genericropeparticle.geom`, `flatpoint.geom`, workshop `.geom`, particles through WE particle materials).
Paths are relative to `OpenWallpaperEngine/` unless they start with `Vendor/`. Library numbers come from `/Volumes/980Pro/OpenWallpaperStorage` (43 scenes): 243 image objects; 133 `genericimage*` material passes (101 of them `genericimage4`); 79 `genericparticle` passes; 33 objects with `colorBlendMode`, 21 with `copybackground`, 18 with `clampuvs`, 17 with `perspective`, 24 with `solid`; 25 models with `cropoffset`; combos seen: `VERSION` (16), `REFRACT` (13), `LIGHTING` (7), `REFLECTION` (4), and lowercase `version` and `spritesheet`.

| # | Sev | Owner | Risk |
|---|-----|-------|------|
| I1 | Critical | E | Premultiplied vs straight alpha; opacity applied twice |
| I2 | Critical | E | The base material's output fed into effect chains (world transform or alpha applied twice) |
| I3 | Critical | F | Particle attribute layout does not match what the shader expects |
| I4 | Critical | F | Vertex counts, `maxvertexcount`, strips and restarts in emulated geometry |
| I5 | High | E | Blend-mode table parity (`normal` / `translucent` / `additive`) and scene-target alpha |
| I6 | High | E | `colorBlendMode` → `BLENDMODE` reads `_rt_FullFrameBuffer`: y flip, alpha and cost |
| I7 | High | E/F | sRGB vs linear, and the scene target format vs the effect target format |
| I8 | High | E | UV flips, `.tex` padding, `cropoffset`, `clampuvs` / repeat |
| I9 | High | E | Spritesheet frames (`SPRITESHEET`, `g_Texture0Rotation/Translation`) |
| I10 | High | E/F | Combos triggered by bound textures, combo case, `TEXnFORMAT` vs TEXParser's expansion |
| I11 | High | E | Per-layer pipeline and uniform explosion; hundreds of layers; pop-in |
| I12 | High | E | World transform, MVP and matrix convention built-ins |
| I13 | High | E | Scene-input layers (`copybackground`, composition, fullscreen) |
| I14 | High | F | Rope and trail ordering, connectivity, shader choice by renderer |
| I15 | High | F | Custom workshop `.geom`: loops, HLSL-isms, other input primitives |
| I16 | High | E/F | Fallbacks: silent blank layers vs loud native fallback |
| I17 | High | E/F | Library sweep does not cover base materials or particles |
| I18 | Med | E | Text layers: font shader vs genericimage, baked colour |
| I19 | Med | E | Solid layers (`solidlayer*.json` = genericimage + `util/white` + `VERSION`) |
| I20 | Med | E | `g_Color4` / `g_UserAlpha` / `g_Brightness` vs object colour/alpha/brightness |
| I21 | Med | F | Particle built-ins left at zero (orientation, eye, `g_RenderVar*`, `g_Screen`) |
| I22 | Med | E/F | `#define HLSL 0` makes `#ifdef HLSL` and `#if HLSL` disagree |
| I23 | Med | E/F | Material render state: depth test without a depth attachment, cull mode, `culling` typo |
| I24 | Med | F | Particle blending, overbright and draw order between layers |

---

## I1. Premultiplied vs straight alpha; opacity applied twice (Critical, E)
**Scenario.** WE textures are straight alpha, and WE's `translucent` is `SrcAlpha, InvSrcAlpha`, with `g_UserAlpha` scaling **only** `albedo.a` (`Vendor/we-assets/shaders/genericimage2.frag`). Today's native fragment returns `color * layer.opacity * layer.color` (`Scene/Rendering/SceneShaders.metal:199`) into a `sourceAlpha` blend (`SceneMetalRenderer.swift:172-175`), so RGB is scaled by opacity² at partial alpha. Moving to genericimage changes every layer with alpha < 1. That is the fix, but any golden image calibrated on the native path will flag it, and someone may "fix" it back. Inputs that are premultiplied break under straight-alpha blending: CoreText output is `premultipliedLast` (`Scene/Rendering/TextLayout.swift:102`), CGImage-decoded PNGs may be premultiplied, and AVFoundation video frames are premultiplied BGRA. They get dark fringes and darker semi-transparent areas. Effect outputs fed back in (I2) must stay straight.
**Test.**
- Headless unit: 1×1 texture straight `(1,0,0,0.5)` over a white clear through `genericimage2` `translucent` with `g_UserAlpha=1` → `(1,0.5,0.5)` ±1/255; with `g_UserAlpha=0.5` → `(1,0.75,0.75)`.
- A PNG fixture with a 50%-alpha pure-colour region, loaded through the production texture path: the sampled RGB equals the file's straight RGB (not RGB·α).
- A white text glyph over black: an edge pixel with 50% coverage reads 0.5 (not 0.25). Test the same for a video frame with alpha, if supported.
**Status (R1, 2026-09-25).** Fixed 5aa4e95 and 22f8798. `MTKTextureLoader` copies a CGImage's bytes as they are, so premultiplied images (CoreText output, AppKit drawing) are now unpremultiplied on upload (5aa4e95). `sceneFragment` returned colour × opacity into a `SrcAlpha` blend, which applied opacity twice on native draws (22f8798). Verified by `TextureUploadTests` (straight images unchanged, premultiplied ones made straight, a decoded PNG keeps its straight colour, text edges keep the text colour), `ImageMaterialRenderTests.testLayerAlphaIsAppliedOnceLikeWE` and `testNativeDrawAppliesLayerAlphaOnce`. Open: video frames with alpha (AVFoundation BGRA) are untested.

## I2. Base material output feeding effect chains (Critical, E)
**Scenario.** In WE, a layer with effects first renders its image through its material into the layer's own FBO, **without** the world transform. The effects then run on that FBO, and the final composite applies the transform and blending. Failure modes:
- (a) The base pass uses the world MVP into the FBO, so the image is rotated or offset inside its FBO and cropped.
- (b) `g_UserAlpha`, `g_Brightness`, `g_Color4` or `BLENDMODE` are applied both in the base pass and in the composite: alpha², brightness², or the blend mode applied twice.
- (c) The FBO is sized to the allocated `.tex` size instead of the content size, so `g_Texture0Resolution` seen by the effects is wrong (see #13 above).
- (d) The static-chain cache (`EffectGraphRenderer`, #18 above) does not key on base-material constants that scripts animate (alpha, brightness, spritesheet frame), so the chain freezes.
**Test.**
- Headless: a layer rotated 45°, scaled 2×, alpha 0.5, with a pass-through effect vs the same layer without the effect → pixel-identical output (tolerance 1/255).
- Animate alpha by script while the effect is static: the output changes every frame. A spritesheet layer with an effect animates (I9).
- Assert the first effect pass's `g_Texture0Resolution.zw` equals the `.tex` content size.
**Status (R1, 2026-09-25).** Verified by `ImageMaterialRenderTests.testPassThroughEffectLeavesTheMaterialDrawUnchanged` (1dd7380): a layer rotated 45°, scaled, at α 0.5, tinted and at brightness 1.2 draws the same through a pass-through `tint`. Also by `EffectGraphReuseTests.testStaticChainRerendersWhenColorAlphaOrInputVersionChange` and `EffectGraphCachingTests.testTextureResolutionReportsAllocatedThenContentSize`. Effects run in texture space, and the material applies the transform, alpha and brightness once.

## I3. Particle attribute layout mismatch (Critical, F)
**Scenario.** WE particle shaders expect specific vertex attributes:
- `genericparticle.vert` with GS: `a_Position` vec3, `a_TexCoordVec4` = rotation xyz + size w, `a_TexCoordVec4C1` = velocity xyz + lifetime w (**only with `THICKFORMAT`**), `a_Color` vec4 in 0..1.
- Without GS: rotation is split into `a_TexCoordC2.xy` + `a_TexCoordVec4.z`, and `a_TexCoordVec4.xy` becomes the corner UV.
- Rope: `a_PositionVec4`, end point in `a_TexCoordVec4`, CP0 + trail position in C1, and `a_TexCoordVec3C2` or `Vec4C2/C3` (thick).

Our particles are 2D with a separate alpha: `Particle.position/velocity: SIMD2`, `alpha`, `color` (`SceneMetalRenderer.swift:48-73`). Failure modes:
- `z` left uninitialised.
- Rotation in degrees instead of radians.
- Size as radius instead of full width (`ComputeParticlePosition` uses `size*(uv-0.5)`).
- Lifetime not normalised (`frac(age/lifetime)` feeds `ComputeSpriteFrame`).
- `a_Color.a` missing the fade and `opacityMultiplier` (`particleOpacity`, `:1656`).
- Swift `SIMD3<Float>` is 16 bytes while an MSL `packed_float3` attribute is 12, so every attribute after it is shifted.
- An `MTLVertexDescriptor` built by hand instead of from the variant's reflection, which breaks as soon as combos add or remove attributes.
- `SPRITESHEET` or `TRAILRENDERER` enabled without `THICKFORMAT`: `genericparticle.geom` reads `IN[0].v_VelocityLifetime`, which only exists with `THICKFORMAT`, so it fails to compile.
**Test.**
- Unit: for GS × `THICKFORMAT` × `SPRITESHEET` × `TRAILRENDERER`, build the vertex descriptor from reflection. Assert that every declared attribute is bound with the right format and offset, and that invalid combos (SPRITESHEET without THICKFORMAT) are never requested.
- Golden: one particle at (100,100), size 50, rotation 0, colour `(1,0,0,0.5)`, square white texture → covered box exactly 50×50 scene units centred at (100,100), pixel `(1,0,0)` at 50%. Rotation π/4 gives a diamond.
- A non-square texture (e.g. 64×128) → height = size × `g_Texture0Resolution.y/x`. With a spritesheet, the ratio comes from `g_RenderVar1.w`.

## I4. Emulated geometry: vertex counts, `maxvertexcount`, strips (Critical, F)
**Scenario.**
- **Output layouts.** `genericparticle.geom` and `flatpoint.geom` emit one 4-vertex strip. `genericropeparticle.geom` emits `4 + TRAILSUBDIVISION*2`. A custom `.geom` can emit fewer than `maxvertexcount` (conditional `Append`), or several strips (`RestartStrip`).
- **Vertex pulling.** Emulating with `vertexCount = N` per instance must turn the extra slots into degenerate vertices. NaN positions are undefined behaviour, so they must collapse onto the last emitted vertex. Strip-to-list conversion must not bridge across a restart. Metal only has primitive restart for indexed strips.
- **The count itself.** The `[maxvertexcount(...)]` expression must be evaluated after combos are resolved.
- **Scale.** N × max particles (e.g. 10 × 10 000) blows up vertex counts and buffers. Mesh shaders cap a threadgroup at 256 vertices / 512 primitives.
- **Winding.** The strip's corner order (0,0),(0,1),(1,0),(1,1) gives alternating winding; that matters if a material's `cullmode` is not `nocull`.
**Test.**
- Parser unit: `[maxvertexcount(4 + TRAILSUBDIVISION * 2)]` → 4 / 10 for TRAILSUBDIVISION 0 / 3.
- A synthetic `.geom` emitting 3 of a max of 6 vertices draws exactly one triangle (count the covered pixels).
- A `RestartStrip` fixture with two disjoint quads leaves the pixel between them at background.
- 10 000 sprite particles: vertex buffer ≤ 4 × 10 000 vertices, no per-frame allocation (buffer identity stable over 100 frames).

## I5. Blend-mode table parity and scene-target alpha (High, E)
**Scenario.** WE material `blending` values seen are `normal`, `translucent`, `additive` (and `disabled` in some workshop content). `EffectGraphRenderer.blendMode` (`Scene/Rendering/EffectGraphRenderer.swift:534-539`) maps `additive` to `(srcAlpha, one)` for **alpha as well**, and anything else to "no blending". The native additive path uses `(one, one)` for alpha (`SceneMetalRenderer.swift:180-183`). A `normal` (overwrite) image layer with transparent texels writes alpha 0 into the scene target. The final composite then blends the scene target with `sourceAlpha` (`SceneMetalRenderer.swift:~575`, `renderPipeline`), which WE never does at present, so holes show the clear colour. Unknown blending strings silently become overwrite.
**Test.**
- Table test over every blending string found in library + we-assets materials: expected Metal factors per RGB and alpha; an unknown string logs once.
- Headless: red opaque background + a `normal` layer whose texture has a transparent quadrant → the final drawable shows the texture's RGB there (or matches a WE reference screenshot), never the clear colour.
- An additive layer over a transparent area: final pixel equals WE's.
**Status (R1, 2026-09-25).** Fixed 320b7ec (opaque composite). Verified by `testNormalBlendingOverwritesTheScene`, `testCompositeIgnoresTheSceneAlpha` and `testAdditiveBlendingMatchesTheNativeAdditiveDraw`. Open: an unknown `blending` string silently overwrites (`EffectGraphRenderer.blendMode`, which is B's); fixing it needs WE's full list of blending values.

## I6. `colorBlendMode` / `BLENDMODE` and `_rt_FullFrameBuffer` (High, E)
**Scenario.** 33 library objects set `colorBlendMode`. `genericimage2/3/4` then sample `g_Texture4 = _rt_FullFrameBuffer` at `v_ScreenPos` and write `gl_FragColor.a = screen.a`:
- **Snapshots.** Each such layer needs the snapshot taken *just before it*, as `readsScene` layers do (`SceneMetalRenderer.swift:~520`, end encoder + blit). At 5K with 10+ blend-mode layers, that is 10+ full-screen blits per frame (a performance risk).
- **y flip.** It depends on `#ifdef HLSL` being taken (I22).
- **Snapshot alpha.** Where the snapshot's alpha is 0 (clear colour alpha 0, nothing drawn yet), a translucent pass with `a = screen.a` makes the layer vanish.
- **Unused sampler.** `BLENDMODE 0` must *not* bind the sampler; `resolveCombos` must not turn it on because of the hidden default texture.
**Test.**
- Headless: vertical gradient background + a white layer with `BLENDMODE=2` (multiply) → output equals the background exactly (no vertical flip).
- The same over a region the background leaves transparent: the layer stays visible if WE shows it.
- Perf: 20 blend-mode layers at 5120×2880 → CPU+GPU frame time budget (e.g. < 8 ms on M1 Pro) recorded via `OWEFrameMetrics`.
**Status (R1, 2026-09-25).** Verified by `testBlendModeMultipliesWithTheSceneBeneath`, `testBlendModeReadsTheScenePixelBeneath` (fixed by 9d8c262 and 6bc5732) and `testObjectBlendModeReadsTheScene`. `BLENDMODE` 0 samples no snapshot (`testPlainMaterialsPlanWithTheLayerImageInSlotZero`). `a = screen.a` is WE's own shader code. Open: the cost of one snapshot per blend-mode layer at 5K is unmeasured.

## I7. sRGB vs linear; target formats (High, E/F)
**Scenario.** WE blends in gamma space: `rgba8` UNORM targets and non-sRGB textures (HDR scenes use `rgba16f` + `HDR` combo). Today every load passes `SRGB: false` (`SceneMetalRenderer.swift:924`, `:993`, `:1009`), and the scene target inherits the drawable's `bgra8Unorm` (`:878`), while effect targets are `rgba8Unorm` (`EffectGraphRenderer.swift:522-531`). Risks:
- New loading code uses `MTKTextureLoader` defaults (sRGB for tagged PNGs, so midtones get darker).
- BC blocks are uploaded as `_srgb`.
- The view switches to `bgra8Unorm_srgb`.
- A base-material pipeline compiled for `rgba8Unorm` is used in the scene pass (`bgra8Unorm`), which is a Metal validation error or a silent failure. The pipeline key must include the attachment format (it does for effects: `EffectGraphRenderer.swift:273`).
- `g_Power` (`genericimage.frag`) and MSDF math assume gamma values.
**Test.**
- Headless: a 1×1 `0x80` grey texture through genericimage2 into the scene target → reads back `0x80` ±1. Repeat for BC1/BC7 and a PNG with an sRGB ICC profile.
- Source test: grep asserts every `newTexture(` in `Scene/` passes `SRGB: false`.
- Unit: the base-material pipeline's colour format equals `sceneTexture.pixelFormat`. Run with `MTL_DEBUG_LAYER=1` and no validation errors.
**Status (R1, 2026-09-25).** Fixed 5aa4e95: AppKit converted solid-layer colours into the display's colour space (P3). Verified by `TextureUploadTests.testStraightAlphaImagesUploadAsStored` (Display P3 and sRGB tags are ignored) and `testSolidLayerImageHoldsTheAuthoredColour`. The pipeline key includes the target format, every upload passes `SRGB: false` through `SceneTextureUpload`, and BC formats upload as non-sRGB.

## I8. UV flips, `.tex` padding, `cropoffset`, `clampuvs` (High, E)
**Scenario.**
- **Padding.** Native crops the padded allocation via `contentUVExtent` (`SceneMetalRenderer.swift:1028-1034`). `genericimage*` uses raw `a_TexCoord`, so the generated quad's texcoords must span content/allocated, or the padding shows.
- **Flips.** The effect quad relies on the translator's GL-style y flip (`EffectGraphRenderer.swift:93-96`), while the scene pass uses a y-down `sceneVertex` (`SceneShaders.metal:135-160`). Moving the scene pass to a WE MVP (y-up world) can flip the image only when effects are present, or only when they are absent.
- **Model options.** `cropoffset` (25 models) and `nopadding` change the mesh.
- **Sampler mode.** WE uses repeat unless `clampuvs` (18 objects) or the `.tex` clamp flag. With repeat plus bilinear, the opposite edge bleeds a 1-px line into the border, and padded POT textures bleed padding. `genericimage` `g_ScrollX/Y` needs repeat. Native's constexpr sampler is clamp.
**Test.**
- A `.tex` fixture: 1000×600 content in 1024×1024 with a 1-px red border inside the content and green padding. Render it: no green pixel anywhere, red on all four edges. Repeat with `clampuvs` on/off.
- An asymmetric "F" texture: render with and without a pass-through effect and with rotation 0/90/180 → identical orientation to the native oracle.
- A `cropoffset` model fixture vs a WE screenshot.
**Status (R1, 2026-09-25).** Verified by `testPaddedContentCropMatchesTheNativeDraw`, `testScrollingImageWrapsUnlessClamped`, `testTexFlagsAreReadFromTheHeader` and the rotated native-oracle tests. Open: `cropoffset` and `nopadding` aren't decoded; their semantics need WE ground truth, such as a model with `cropoffset` captured in WE.

## I9. Spritesheet frames (High, E)
**Scenario.**
- **Combo.** Animated `.tex` needs `SPRITESHEET=1`, which the engine sets from the texture (library materials rarely set it, and one uses lowercase `spritesheet`).
- **Frame UVs.** `g_Texture0Rotation = (width, widthY, heightX, height)/atlas` and `g_Texture0Translation = (x, y)/atlas`, where atlas must be the **allocated** pixel size. Native divides by `NSImage.size` (`SceneMetalRenderer.swift:~1017`), which is in points and may be the content size.
- **Atlas binding.** Frames can live in different images (`frame.imageIndex`), so `g_Texture0` must be rebound per frame.
- **Default.** The fallback rotation `(1,0,0,1)` (`Scene/Rendering/BuiltinUniforms.swift:186`) is correct only when `SPRITESHEET` is 0.
- **Caching.** A static-chain cache that doesn't key on the frame freezes it (I2).
**Test.**
- A synthetic 4-frame 2×2 atlas (distinct colours, 0.1 s per frame, atlas padded to POT, 3 frames in a 512² texture with 480² content) → at t = 0.05/0.15/0.25/0.35 the centre colour is the expected one.
- The same with a material lacking the combo, with a lowercase combo, with a multi-image `.tex`, and with an effect on the layer.
**Status (R1, 2026-09-25).** Fixed 6fb64b5: frame rects are now divided by the atlas texture's pixels rather than `NSImage.size`. Verified by `testSpriteSheetFrameMatchesTheNativeDraw`, with and without `SPRITESHEET`. Each frame binds its own atlas image. Open: the repo has no real animated `.tex` fixture with padding.

## I10. Combos from bound textures, combo case, `TEXnFORMAT` (High, E/F)
**Scenario.** `resolveCombos` (`Scene/Shaders/ShaderVariant.swift:75-89`) turns a sampler's `combo` on when its slot is bound and upper-cases overrides, but declaration defaults are keyed by their declared name. Risks:
- **Material slots.** A material `textures` array with `""`/`null` slots; `require`/`requireany` annotations not honoured.
- **Hidden defaults.** `_rt_MipMappedFrameBuffer` (REFLECTION, 4 library materials), `_rt_shadowAtlas` (`sampler2DComparison`), `_alias_lightCookie` and `util/white` go through `textureInput`, which rejects `_rt_*` with an error (`Scene/Loading/SceneEffectPlan.swift` `textureInput`).
- **`TEXnFORMAT`.** TEXParser already expands R8 to `(1,1,1,r)` and RG88 to `(l,l,l,a)` (`Scene/Format/TEXParser.swift:434-455`). So `ConvertTexture0Format` must see `TEX0FORMAT=0`; setting `TEX0FORMAT=9` yields `vec4(1,1,1,1)` (opaque squares). RG88 **normal maps** lose G from RGB, so `DecompressNormal`/`WithMask` (`Vendor/we-assets/shaders/common_fragment.h:19-48`) read swapped or duplicated channels. That affects `REFRACT` particles (13 in library) and `LIGHTING`.
**Test.**
- Table test: (material, bound slots, object combos) → expected combo dictionary for all 133 image and 79 particle passes in the library; lowercase keys normalise.
- An R8 particle sprite: alpha = r, RGB = 1.
- An RG88 normal map with constant (+1,0) under REFRACT over a vertical-stripe background → displacement only along x.
**Status (R1, 2026-09-25).** Combo resolution and TEXParser's channel expansion are B's. On the image side, `testAMissingTextureOnlyUnbindsItsSlot` covers it. Still open on B's side: `TEXnFORMAT` against RG88 normal maps.

## I11. Pipeline and uniform explosion, hundreds of layers (High, E)
**Scenario.**
- **Variants.** 243 image objects; `BLENDMODE` has 33 values × `LIGHTING` × `REFLECTION` × `SPRITESHEET` × `VERSION` × `FOG` × `HDR`. Translation is keyed per variant (fine), but a pipeline per *layer*, or a uniform program per layer rebuilt each frame, costs CPU.
- **Uniform size.** `setVertexBytes` is limited to 4 KB, and `genericimage4`'s light arrays can approach that.
- **Async compile.** Pipelines compile asynchronously (`failedPipelines`, `pipelineLock` in `EffectGraphRenderer`), so layers pop in out of order over the first frames.
- **Clones.** `createLayer` script clones (hundreds) each get a uniform program.
**Test.**
- Synthetic scene with 500 layers on one material → 1 translated variant, 1 pipeline (expose counters), CPU frame time < 4 ms on M1 via `OWEFrameMetrics`.
- 500 layers over 33 `BLENDMODE`s → ≤ 33 pipelines.
- With a warm cache, frame 1 draws every layer (or loading holds until pipelines are ready); memory is flat over 1 000 frames.
**Status (R1, 2026-09-25).** Verified by `testRemovedClonesFreeTheirUniformState` (ac3b667: 100 layers on one material compile one pipeline and hold 100 programs, all freed on release) and `testStillLayerRewritesNoPlacementUniforms`. Open: uniforms over 4 KB allocate an `MTLBuffer` per draw, and frame time for 500 layers is unmeasured.

## I12. World transform, MVP and matrix convention (High, E)
**Scenario.** `g_ModelViewProjectionMatrix` must carry parents, alignment, parallax, shake, `cropoffset` and `perspective` (`angles.x/y`, 17 objects, needing a perspective camera). It must **not** include placement, which the composite applies (`SceneMetalRenderer.swift:~570`). `mul(x, y)` is `(y) * (x)` (`Scene/Shaders/ShaderPrelude.swift:86`), so WE matrices are row-vector; uploading a Swift column-major `simd_float4x4` without the matching transpose mirrors or shears. `LIGHTING`/`REFLECTION` also need `g_ModelMatrix`, `g_NormalModelMatrix`, `g_ViewProjectionMatrix`, `g_EyePosition` and `g_AltModelMatrix` (PRELIGHTING).
**Test.**
- Unit with native as the oracle: a layer at (100,200), scale 2, angle 30°, a parent offset and shear → MVP·corners in NDC equal `sceneVertex`'s corners (1e-4).
- A non-symmetric matrix transposition test.
- A `perspective` layer with `angles.y = 30°` vs a WE screenshot.
**Status (R1, 2026-09-25).** Verified by the native-oracle tests (`testGenericImage4MatchesTheNativeDraw`, `testVersionedGenericImage2MatchesTheNativeDrawWithColourAndBrightness`) and by the mirrored quads in the I23 test. Open: `perspective` (`angles.x/y`) and `cropoffset` aren't implemented and need WE captures. LIGHTING and REFLECTION are refused and logged.

## I13. Scene-input layers (High, E)
**Scenario.** `copybackground` (21), composition and fullscreen layers: native resamples the snapshot through the quad (`sceneRegion`, `SceneMetalRenderer.swift:819-851`). WE's `composelayer` samples `_rt_FullFrameBuffer` at `v_ScreenCoord` (and `CLEARALPHA`). Risks:
- Doing both (region resample *and* screen coordinates) double-offsets the image.
- Retina: the snapshot is at render px/unit, not scene units.
- The layer includes its own previous frame (feedback).
- `sceneInput` with no effects must still draw.
**Test.**
- Extend risk #10: a checkerboard + composition layer + pass-through effect → identical to the background; repeat for a 90°-rotated `copybackground` layer and a half-off-screen one.
- A scene-input layer with `BLENDMODE` combined.
**Status (R1, 2026-09-25).** Verified by `SceneRegionResampleTests` (see #10). A scene-input layer without effects is skipped, as in WE (`buildMetalLayer`). Open: `composelayer`'s own shader (`CLEARALPHA`) isn't used.

## I14. Rope and trail ordering and connectivity (High, F)
**Scenario.**
- **Shader choice.** Library rope/trail materials name `genericparticle`, so the engine must pick `genericropeparticle` from the renderer (`rope`, `ropetrail`) and set `TRAILRENDERER`, `THICKFORMAT` and `TRAILSUBDIVISION=renderer.subdivision`. Otherwise ropes draw as sprites.
- **Segment data.** Segment *i* needs particle *i+1* as its end point, spline control points, and `a_TexCoordVec4C1.w` trail position with `g_RenderVar0` (x unscaled max count, z UV time offset, w max count).
- **Particle order.** Swap-remove compaction would scramble ropes; today it is `removeAll` (order-preserving, `SceneMetalRenderer.swift:1519`). `ropetrail` uses a history ring buffer (`orderedHistory`), and translucent segments must draw oldest→newest.
- **Spline shape.** WE uses a cubic Bezier with CPs ×0.15 and `smoothstep` spacing; native uses Catmull-Rom (`:1605-1655`). Tests pinned to native will fail.
- **Shipped shader bugs.**
  - `genericropeparticle.geom` redeclares the loop variable (`for (int s…){ float s = …}`), which GLSL forbids: `TRAILSUBDIVISION > 0` won't compile without a rewrite.
  - The non-GS `genericropeparticle.vert` writes `sizeStart.w` on a float under `TRAILSCROLLALPHA && TRAILFADESIZE`, so that fallback won't compile.
**Test.**
- Translate `genericropeparticle` for TRAILSUBDIVISION 0..4 × each TRAIL* combo × GS on/off; list failures (expect the two above unless rewritten).
- A rope fixture with 5 particles on a line → one continuous strip: sample the midpoint of every joint (non-background). Kill the middle particle → no crossing segment.

## I15. Custom workshop `.geom` (High, F)
**Scenario.** WE's `.geom` dialect is pseudo-HLSL:
- `[maxvertexcount(n)]`, `in`/`out` redeclaring `gl_Position`, `IN[0].x`, `OUT.Append(v)`.
- `PS_INPUT`/`VS_OUTPUT` structs synthesised from varyings, possibly `OUT.RestartStrip()`.
- Line or triangle inputs (`IN[1]`, `IN[2]`).

Loops can be bounded by combos (unrollable) or by **uniforms** (runtime), which breaks translate-time unrolling. With `Append` inside a loop, vertex pulling must re-run the body per output vertex (O(N²)), or a compute pre-pass is needed. Shadowed loop variables (I14) and int literals in `smoothstep(0, 1, x)` also occur.
**Test.** Fixtures:
- (a) `for (int i = 0; i < COUNT; ++i)` emitting quads, COUNT combo = 3 → 3 quads.
- (b) A loop bound by uniform `g_Count` = 2 of max 8 → 2 quads; set it to 5 at runtime → 5 quads.
- (c) A line-input geom using `IN[1]`.
- Each case must render correctly or fail loudly: log once, a dump in `/tmp/owe-failed-shaders`, and the layer on its fallback (I16). Never draw nothing silently.

## I16. Fallbacks (High, E/F)
**Scenario.** When the WE path fails, the layer must fall back to the native draw, log once with the wallpaper, layer and reason (architecture "loud failure"), and not retry every frame. Failure causes include:
- A translate error or missing include.
- `sampler2DComparison` (`LIGHTS_SHADOW_MAPPING` in `genericimage4`/`genericparticle`).
- An unknown `_rt_*` target.
- A pipeline compile failure.
- An unparsable `.geom`.
- An attribute the emulator can't supply.

Risks:
- Everything silently falls back, for example after a prelude regression, and nothing notices because the picture looks "fine".
- The async-compile window shows native first and then WE: a visible colour/alpha jump due to I1.
- A fallback for particles doesn't exist and the system is dropped.
**Test.**
- Inject a bad shader name → the layer is still visible, exactly one log line, `failedPipelineCount == 1` after 100 frames.
- Expose "layers on WE path / fallback" counters and assert ≥ 95% WE-path in the sweep (I17).
- The same for a particle system with a broken custom `.geom`.
**Status (R1, 2026-09-25).** Verified by `testLightingNeedsSceneLightsAndFallsBack` and `testMissingShaderFailsLoudly` (1dd7380). A failed pipeline is remembered and logged once (`ImageMaterialRenderer.compile`). Open: the sweep has no counter of WE-path versus fallback layers.

## I17. Library sweep regressions (High, E/F)
**Scenario.** `LibrarySweepTests` (`OpenWallpaperEngineTests/LibrarySweepTests.swift:21`) only plans, translates and runs **effects**. Base image materials (133 passes), particle materials (79), rope variants and geometry emulation are not covered, and it uses `ProcessShaderCompiler` rather than the in-process compiler. "44 wallpapers, 0 failures" (roadmap) would stay green while every image layer quietly falls back.
**Test.**
- Extend the sweep:
  - For every image object, plan its material with object combos and `colorBlendMode`, translate it, and build the pipeline for the scene-target format.
  - For every particle system, choose the shader by renderer, then translate and build the emulated variant.
  - Assert 0 failures and the fallback ratio from I16.
- Render one frame per wallpaper headless: not blank (not all clear colour), and mean colour within tolerance of a stored baseline. Update the baselines deliberately when I1 changes appearance.
- Run with both compilers.
**Status (R1, 2026-09-25).** Verified by `ImageMaterialSweepTests`: every library image material builds a bgra8 pipeline with the in-process compiler. Open: rendering one frame per library wallpaper against a baseline. `SceneRendererParticleTests` (5336d12) shows whole frames now run headless.

## I18. Text layers (Med, E)
**Scenario.** WE draws text with `font` (`Vendor/we-assets/materials/fonts/basefont*.json`: `g_Color4`, `MSDF`, `COLORFONT`, `g_RenderVar0..3` outline/shadow), not genericimage. Our text is CoreText-rasterised with its colour baked in (`SceneMetalRenderer.swift:921`) and is premultiplied. Routing it through genericimage2 `VERSION` with `g_Color4 = (colour, alpha)` squares the colour. Leaving it native makes text blend differently from images (I1), so a text layer next to an image with the same alpha looks different.
**Test.**
- Red `(1,0,0)` text, alpha 0.5, over white → glyph interior `(1,0.5,0.5)`; an edge pixel is no darker than the interior blend.
- The same text with a shake effect has the same colour.
**Status (R1, 2026-09-25).** Fixed 5aa4e95 (premultiplied glyph edges) and 22f8798 (alpha applied once). Verified by `TextureUploadTests.testTextEdgesKeepTheTextColour` and `testNativeDrawAppliesLayerAlphaOnce`. Open: text is still rasterised by CoreText, not drawn through WE's `font` material (MSDF, outline, shadow).

## I19. Solid layers (Med, E)
**Scenario.** `solidlayer` models (3) and `solid` objects (24) are WE `util/solidlayer*.json`: genericimage2/3/4 + `util/white` + `VERSION: 2` → `g_Color4`. The `_depthtest` variants enable depth (I23), and the `_instance` variants use `INSTANCECOUNT`. Risks: `util/white` is not found in a workshop-only root; the colour is applied twice (I20); a fullscreen solid is not resized with the scene.
**Test.** Solid `(0.2,0.4,0.6)`, alpha 0.5, over black → `(0.1,0.2,0.3)`; with an effect → same; at a changed scene size it covers the full target.
**Status (R1, 2026-09-25).** WE's bundled `util/solidlayer.json` uses the `flat` shader, which has no image, so solid layers draw their baked colour natively. Fixed 5aa4e95 (the colour was converted to P3) and 22f8798. Verified by `testSolidLayerImageHoldsTheAuthoredColour`, `testNativeDrawAppliesLayerAlphaOnce` and `testBlendModeOnAFlatMaterialIsReported`. Open: E-5.

## I20. `g_Color4`, `g_UserAlpha`, `g_Brightness` vs object colour/alpha/brightness (Med, E)
**Scenario.** Without `VERSION`, genericimage2 takes `g_Brightness`/`g_UserAlpha` from `constantshadervalues` (`Brightness`, `Alpha`); with `VERSION`, it takes `g_Color4`. Objects also carry `color`, `alpha` and `brightness`, with scripts and timelines on top (`layerDraw`, `SceneMetalRenderer.swift:635-677`). Effects get `g_Color`/`g_Alpha` via `EffectGraphRenderer.Context.layerColor/layerAlpha`. If the object alpha is fed to `g_UserAlpha` **and** the composite still multiplies `opacity`, the result is alpha². If `VERSION` materials ignore the object colour, tint is lost.
**Test.** A matrix of `VERSION` on/off × object alpha 0.5 × material `Alpha` 0.5 × script alpha → expected final alpha per WE (take the expectations from WE screenshots, not from the native path).
**Status (R1, 2026-09-25).** Verified by `testLegacyGenericImage2TakesAlphaFromTheMaterialAndTheLayer`, `testVersionedGenericImage2MatchesTheNativeDrawWithColourAndBrightness`, `testMaterialBrightnessIsAppliedOnce` and `testLayerAlphaIsAppliedOnceLikeWE`. Open: the full matrix of `VERSION`, object α, material α and script α needs WE screenshots.

## I21. Particle built-ins left at zero (Med, F)
**Scenario.** Particle shaders read built-ins nothing sets today. If they stay zero, particles become degenerate and **invisible with no error**:
- `g_OrientationUp/Right/Forward`, `g_ViewUp/Right`, `g_EyePosition`, `g_ModelMatrixInverse` (`common_particles.h`).
- `g_RenderVar0` (trail length min/max, UV offset) and `g_RenderVar1` (frame width/height/count, ratio).
- `g_Texture0Resolution`.

`flatpoint.geom` divides by w and offsets in NDC by `0.002 * size`, with `g_Screen.z` as aspect and `1080/g_Screen.y`. `effectFrame.screenSize` is the Retina scene target (`SceneMetalRenderer.swift:~404`), so points shrink on 5K (the formula in fact expects that); check it against WE.
**Test.**
- Unit: for each particle variant, every reflected uniform is written by the builtin table or has a material/annotation default; fail on an "unset builtin" list.
- A `flatpoint` point at a 1080p vs a 2160p target keeps the same size in scene units, or matches WE.

## I22. `#define HLSL 0` semantics (Med, E/F)
**Scenario.** The prelude defines `GLSL 1` and `HLSL 0` (`Scene/Shaders/ShaderPrelude.swift:81-82`). So `#ifdef HLSL` blocks are **taken**: 17 in the assets, including the `v_ScreenCoord.y` flip in `genericimage2/3/4.vert`, `common_particles.h` refraction coords and `normal.y` in `genericimage3/4.frag`. Meanwhile `#if HLSL` (8) and `#ifndef HLSL` (2, e.g. the `genericparticle.frag` refraction offset y) take the GL branch. One shader can run HLSL-convention code in one place and GL-convention code in another, a mix WE never ships. It may be right for Metal's y-down textures, or it may flip. *Update:* `9d8c262` now leaves `HLSL`/`HLSL_SM30` undefined (GL branches everywhere, like WE's GLSL backend). The risk is now anything calibrated against the old mix; see Findings E-7.
**Test.** A REFRACT particle with a +y normal over a horizontal-stripe background, and a `BLENDMODE` layer over a gradient: the displacement direction and orientation must match a WE reference capture. Keep a table test listing the `#ifdef HLSL` sites so a prelude change is deliberate.
**Status (R1, 2026-09-25).** The prelude is B's (9d8c262). On the image side, `testBlendModeReadsTheScenePixelBeneath` verifies it. Particle refraction is the particle agent's.

## I23. Material render state (Med, E/F)
**Scenario.**
- **Depth.** `depthtest: enabled` (`solidlayer_depthtest`, perspective scenes) with a scene pass that has no depth attachment → a pipeline with depth state on a depth-less pass, which is a validation error.
- **Cull mode.** Negative-scale (mirrored) layers under a non-`nocull` cull mode get culled.
- **Key typo.** WE's own `flatpointalphavertexcolor.json` spells it `"culling"`, not `"cullmode"`.
- **Alpha-to-coverage.** `ALPHATOCOVERAGE` uses `fwidth` and needs MSAA.
**Test.** A mirrored layer (`scale.x = -1`) is visible; a depth-test material creates a valid pipeline with no depth format when the pass has none (`MTL_DEBUG_LAYER=1`); unknown or misspelled state keys fall back to the WE defaults.
**Status (R1, 2026-09-25).** Verified by `testDepthAndCullStateKeepMirroredLayersVisible` (1dd7380). Image pipelines ignore depth and cull state, so `depthtest: enabled`, `cullmode` and `culling` all build valid pipelines for the depth-less pass, and mirrored layers draw. Open: `ALPHATOCOVERAGE` (which needs MSAA) isn't handled, and whether WE culls mirrored image layers needs a capture.

## I24. Particle blending, overbright, draw order (Med, F)
**Scenario.**
- **Additive alpha.** Native additive particles use `(one, one)` for alpha; the effect-graph table uses `(srcAlpha, one)` (I5). The accumulated scene-target alpha then goes through the composite blend.
- **Overbright.** `g_Overbright` (library 1.6) above 1 clamps in `rgba8`.
- **Other modes.** `CUTOUT` and fog alpha (`FOG` default 1 in `genericparticle.frag`/`genericimage4.frag`; `FOG_DIST`/`FOG_HEIGHT` must stay off unless the scene defines fog, or `g_Fog*` uniforms stay zero and colour goes to black).
- **Draw order.** Particles draw between layers by `configuration.order` (`drawParticleBatches`, `SceneMetalRenderer.swift:488-508`). If E and F each change their own draw loop, the interleaving (and the snapshot a REFRACT particle reads) can change.
**Test.**
- An additive particle with overbright 1.6 over black → channel clamps at 1, alpha behaviour matches WE.
- A scene with layer A, particles, layer B → particles are occluded by B and cover A.
- A REFRACT particle reads a snapshot that includes A but not B.

---

## Findings (E and F commits)

_Watching `git log` on `deepratna/feature-work` from `4154ccd`._

### E: `864b9a4` (draw image materials through WE's shaders) + `c955481` (render image layers through their own material)

Line numbers are at `c955481`.

**What the commits already cover.**
- I1: alpha is applied once, tested by `testLayerAlphaIsAppliedOnceLikeWE`.
- I6: `BLENDMODE` gets a per-layer snapshot. At `c955481` the blend still read the vertically mirrored scene pixel; the test recorded that as a known gap with a strict `XCTExpectFailure`. `9d8c262` fixed it; see issue 7.
- I7: the pipeline key includes the attachment format.
- I9: frames are baked into the texcoords when `SPRITESHEET` is off, so animated `.tex` without the combo still animate.
- I16: failures fall back natively and are logged once. `LIGHTING`/`REFLECTION` are refused.
- I17: `ImageMaterialSweepTests` plans, translates and builds the `bgra8Unorm` pipeline for every library image material, using the in-process compiler.

**Confirmed issues.**
1. **Material `Brightness` is applied twice (I20). Medium.**
   - The legacy heuristic reads `constantshadervalues` `"Brightness"` into `materialEffects.brightness` (`Scene/Loading/SceneWallpaperViewModel.swift:1033`, via `Scene/Format/SceneMaterial.swift:40-41`).
   - The renderer folds it into `uniform.effects.x` (`Scene/Rendering/SceneMetalRenderer.swift:557`) and passes that as the draw's brightness (`:576`).
   - `ImageMaterialPlanBuilder` also takes the same constant as the live factor for `g_Brightness` (`Scene/Loading/ImageMaterialPlan.swift:121-124`), which `ImageMaterialUniforms.live` multiplies in again (`Scene/Rendering/ImageMaterialUniforms.swift:89-90`).
   - A legacy genericimage2 material with `"Brightness": 1.5` draws at 2.25× (≈1.5² once clamped). The heuristic's other aliases (`intensity`, `overbright`, `gain`) also leak into `g_Brightness` and into `g_Color4` for `VERSION` shaders (`ImageMaterialUniforms.swift:86-88`).
   - The fixture tests only use a material factor of 1 (`testLegacyAlphaConstantScalesTheLiveAlpha` asserts `g_Brightness == 1`), so they miss it.
   - **Test:** a legacy material with `Brightness` 1.5 over black, texel 0.4 → expect 0.6, not 0.9.
2. **`normal` blending now leaves texture alpha in the scene target, which the composite blends with the clear colour (I5). High, a regression for `normal` materials whose texture has alpha.**
   - `EffectGraphRenderer.blendMode("normal")` is nil, so the image pipeline overwrites RGBA (`Scene/Rendering/ImageMaterialRenderer.swift:271-278`). `testNormalBlendingOverwritesTheScene` asserts that the scene target then holds alpha 64/255.
   - The final composite draws the scene target with `renderPipeline` (`sourceAlpha, oneMinusSourceAlpha`; `SceneMetalRenderer.swift:168-175`, composite at `:601-620`) over the drawable's clear colour. Those pixels come out darkened toward black.
   - WE ignores target alpha when presenting, and the native path always used translucent blending, so this is new. Six library materials use `normal`.
   - **Test:** a background layer + a `normal` layer whose texture has α=0.25 → the final drawable pixel equals the texture RGB (WE), not RGB·0.25.
   - **Fix direction:** the composite should ignore scene alpha (opaque composite), or write alpha 1 for overwrite passes.
3. **App adjustment sliders silently switch every layer off the WE path (I16/I11). Medium.**
   - `nativeAdjustmentsAreIdentity(uniform)` gates the material draw (`SceneMetalRenderer.swift:573`). `uniform.effects.z` includes `_owe_saturation` (`:558`) and `colorEffects.z` includes `_owe_hue` (`:565`).
   - Any non-default app saturation/hue (or a legacy heuristic like `contrast`, `blur` or `angle` found in `constantshadervalues`) sends all layers back to `sceneFragment`. That drops `colorBlendMode`, custom image shaders and single alpha, while still paying for the per-layer scene snapshot (`readsScene` stays true through `imageMaterial.readsSceneSnapshot`, `Scene/Rendering/SceneRenderContent.swift` `readsScene`).
   - Nothing is logged, so it's not "loud".
   - **Test:** set `_owe_saturation = 0.9` → a `colorBlendMode` layer still multiplies (or a log line explains why not); `drawsEncoded` stays equal to the layer count.
4. **`clampuvs` and WE's repeat default are ignored for the layer image (I8). Medium.**
   - Slot 0 (`.current`) always uses `clampSampler` (`ImageMaterialRenderer.swift:97-98`), and asset slots always use `repeatSampler` (`:102-104`), whatever the object's `clampuvs` (18 library objects) or the `.tex` clamp flag.
   - `genericimage` (v1) scrolls with `a_TexCoord + g_Time * scroll` (`Vendor/we-assets/shaders/genericimage.vert`), which needs repeat. Under clamp, a scrolling layer smears its edge row instead of tiling.
   - **Test:** a genericimage material with `Scroll 1 X` = 1 at t = 0.25 → the texture wraps (column 0 visible at x = 25%).
5. **Solid layers keep the native draw, so their `colorBlendMode` is dropped. Low/Medium, a gap rather than a regression.** `buildSolidLayer` never builds an `imageMaterial` (`SceneWallpaperViewModel.swift:612-614`, `:690+`). Four library solid layers author a blend mode (modes 2, 3, and 31 twice, with effects). They draw with plain translucent blending. WE draws them through `solidlayer.json` → genericimage2 with `BLENDMODE`.
6. **Per-plan uniform state is shared by script clones. Low, performance only.** `programs` is keyed by `ObjectIdentifier(plan)` (`ImageMaterialRenderer.swift:215-221`). `createLayer` clones share their source's plan, so N clones alternate `lastKey` every draw and rewrite placement built-ins each time. It is still correct, because `setVertexBytes` copies. Above 4 KB it allocates a new `MTLBuffer` per draw per frame (`:163`).

7. **`ImageMaterialRenderTests` is red at HEAD because of a stale expected failure (I6/I22). High, but only for CI.**
   - `9d8c262` (fix(shaders): leave HLSL undefined) removed `#define HLSL 0`, so genericimage's `#ifdef HLSL` screen-coordinate flip no longer runs, and `BLENDMODE` now reads the pixel beneath.
   - `testBlendModeReadsTheScenePixelBeneath` still wraps its assertion in a strict `XCTExpectFailure` (`OpenWallpaperEngineTests/ImageMaterialRenderTests.swift:179`), so it fails with "Expected failure … but none recorded".
   - Verified by running the test in a scratch worktree: it passes at `c955481` and `e4adbe4` and fails at `9d8c262` and HEAD `0be8b90`. All 16 other tests in the class pass at HEAD.
   - **Fix:** remove the expectation. **Resolved by `6bc5732`**: the expectation is removed, and the whole `ImageMaterialRenderTests` class passes at `61a34d7`.
   - **Follow-up for I22:** anything else calibrated while `HLSL` was defined needs re-checking. That covers the comment on `ImageMaterialRenderer.viewProjection`, and for F the particle refraction: `common_particles.h` no longer flips `v_ScreenCoord.y`, and `genericparticle.frag`'s `#ifndef HLSL` offset flip is now taken.

**Status (R1, 2026-09-25).**
- E-1: fixed 320b7ec, verified by `testMaterialBrightnessIsAppliedOnce`.
- E-2: fixed 320b7ec, verified by `testCompositeIgnoresTheSceneAlpha`.
- E-3: fixed 320b7ec. The sliders apply on the composite, and legacy heuristics are logged once and not applied. Verified by `testObjectBrightnessAloneIsNotANativeAdjustment`.
- E-4: fixed 320b7ec, verified by `testScrollingImageWrapsUnlessClamped` and `testTexFlagsAreReadFromTheHeader`.
- E-5: open. WE's bundled solid layer is `flat`, which has no `BLENDMODE`, so a blend mode on a solid layer is reported (`testBlendModeOnAFlatMaterialIsReported`) but not drawn. Fixing it needs WE ground truth: a capture of a solid layer with `colorBlendMode`, and the material WE's editor saves for it (for example, whether it swaps in genericimage2 + `util/white`).
- E-6: fixed 320b7ec (state per layer instance), verified by `testStillLayerRewritesNoPlacementUniforms` and `testRemovedClonesFreeTheirUniformState`.
- E-7: resolved 6bc5732.

### F: `9c3b50c` (emulate WE geometry shaders in the vertex stage) + `61a34d7` (draw particle systems through their WE material)

Line numbers are at `61a34d7`. `GeometryShaderEmulationTests` (9) and `ImageMaterialRenderTests` (17) all pass there; I ran them in a scratch worktree.

**What the commits already cover.**
- I4: each point draws `3·(N−2)` list vertices. Triangles past the emitted count, or spanning a `RestartStrip`, collapse to `vec4(0)`, and odd strip triangles swap corners to keep their winding (`Scene/Shaders/GeometryShaderEmulation.swift:137-150`, `:231-255`). `maxvertexcount` is evaluated after combos (`:45-51`).
- I14: rope renderers swap in `genericropeparticle` (`Scene/Loading/ParticleMaterialPlanBuilder.swift`). The loop-variable redeclaration is rewritten (`Scene/Shaders/HLSLStageRewrites.swift:102-128`), and `TRAILSUBDIVISION` compiles.
- I3: the vertex descriptor comes from reflection, with a per-instance step and a constant-zero buffer for missing attributes (`Scene/Rendering/ParticleMaterialRenderer.swift:272-304`). Records are 16-byte slots (no `float3` packing hazard). `SPRITESHEET` and trails force `THICKFORMAT`.
- I15: loops and runtime-bound emission work, because the whole geometry body runs per output vertex. Non-point input and `IN[1+]` are reported.
- I16: failures fall back to the built-in draw and are logged once. REFRACT is refused.
- I21: the orientation, eye, `g_RenderVar0/1` and `g_ModelMatrixInverse` (identity) built-ins are set (`Scene/Rendering/ParticleMaterialUniforms.swift`).
- I17: `ParticleMaterialSweepTests` builds pipelines for every library particle material with the in-process compiler.

**Confirmed issues.**
1. **`randomframe` sprite sheets ghost the next frame at 50%. Medium.**
   - `spritePhase` for `randomframe` returns `(frame + 0.5) / frames` (`Scene/Rendering/ParticleRecordWriter.swift:73-74`).
   - `SPRITESHEETBLEND` is on unless flag 2 is set (`ParticleMaterialPlanBuilder.swift:95`), and flags are 0 by default.
   - `ComputeSpriteFrame` blends `frac(lifetime·numFrames)` = 0.5 between frame *k* and *k+1* (`Vendor/we-assets/shaders/common_particles.h`, `genericparticle.frag` `SPRITESHEETBLEND`). Every random-frame particle except the last frame shows two frames at half opacity.
   - `testSpriteSheetPicksTheParticlesFrame` passes only because it sets `noFrameBlendingFlag` and uses the last frame.
   - **Fix direction:** phase = `frame / frames` (plus ε), or no blend for `randomframe`.
   - **Test:** a 2-frame sheet, `randomframe`, flags 0, `spriteFrame = 0` → pure frame 0.
   - Also verify flag 2 = "no frame blending" against WE.
2. **Ropes are twice as wide as the native draw. Medium, needs a WE reference.**
   - The writer passes `particle.size` as the rope's `a_PositionVec4.w` (`ParticleRecordWriter.swift:95`, `:124`, `:127`), and `genericropeparticle.geom` offsets ±`size` along the normal. So a size-10 rope is 20 units wide.
   - The record doc calls it "half the ribbon width" (`Scene/Rendering/ParticleInstanceLayout.swift:59`), the sprite doc says `size` is the full width (`:45`), and `testRopeThroughEmulatedGeometryStage` asserts 20 units.
   - The native draw was `size` wide (`SceneMetalRenderer.swift` `appendRope`, `averageSize`).
   - **Test:** compare a rope and a rope trail against a WE capture of the same preset, then settle whether the record needs `size/2`.
3. **Particle textures always sample with repeat. Medium, a regression vs native clamp.**
   - `ParticleMaterialRenderer` makes one sampler with `.repeat` on both axes and binds it to every slot (`ParticleMaterialRenderer.swift:53-60`, `:115`). The native particle draw sampled with clamp (`SceneShaders.metal` `sceneFragment`).
   - Sprites whose edge texels aren't transparent (rain streaks, light shafts, beams) get a 1-px line of the opposite edge under bilinear filtering.
   - Spritesheet frames on the atlas border bleed into the opposite side.
   - The `.tex` clamp flag is ignored.
   - **Test:** a sprite with an opaque bottom row and a transparent top row → no coloured texels along the quad's top edge.
4. **Tests check pixels only on happy-path strips (I4). Low/Medium.** `GeometryShaderEmulationTests.testRestartStripAndCustomEmitCountsTranslate` checks that a two-quad `RestartStrip` stage *translates* and counts 18 vertices; it never renders. Still missing:
   - A pixel test that the gap between the two quads stays background (no bridging triangle).
   - A stage that emits fewer vertices than `maxvertexcount` → exactly the emitted triangles.
   - A cull-mode test for odd-triangle winding.
5. **Cost grows as O(N²) per rope segment with subdivision. Low, unmeasured.** Every emulated vertex reruns the whole geometry body (`GeometryShaderEmulation.swift:137-150`), so rope segments cost `3·(2+2S)` × `(4+2S)` vertex evaluations. At `TRAILSUBDIVISION` 8 that is 54 × 20 ≈ 1 000 per segment, which is significant for rope trails with thousands of segments.
   - **Test:** frame time for 2 000 rope-trail segments at S = 0 / 4 / 8 via `OWEFrameMetrics`.
6. **REFRACT particles (13 library materials) stay on the built-in draw, as intended and logged.** They can't be recalibrated until snapshot support lands. When it does, re-check the I22 conventions: since `9d8c262`, `common_particles.h` no longer flips `v_ScreenCoord.y`, and the `#ifndef HLSL` offset flip in `genericparticle.frag` is taken.
