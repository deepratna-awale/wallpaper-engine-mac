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

**Status (R2, 2026-09-25).** Fixed 8cd197b. The key already held the revision and the library versions and options (1231087). Variants now also live in a directory per revision and compiler, so an upgrade never reads old ones. Verified by `ShaderVariantCacheTests.testVariantsOfAnotherCompilerAreNotReused` and `testTranslatedOutputMatchesItsRevision`: a golden hash of every bundled effect pair's output, keyed by `revision`, fails when output changes without a bump. Also by `InProcessShaderCompilerTests.testFingerprintNamesLibraryVersionsAndOptions` and `testCacheKeyDiffersBetweenBackends`.

## 2. glslang global state is not thread-safe in-process — Critical, B
**Scenario.** `glslang::InitializeProcess()`/`FinalizeProcess()` are process-global and ref-counted; older glslang has a global pool allocator and symbol-table init that races. Today each translate is an isolated process (`Scene/Shaders/ShaderCompiler.swift:76`), so parallel loads (multi-display, each display's scene loading at once; preloading many effects) were safe. In-process, two `variant(...)` calls run concurrently (`ShaderVariant.swift:109-121` only locks the memory map, not translation) → heap corruption, sporadic wrong SPIR-V, or crashes that are not reproducible. Calling `FinalizeProcess` per compile while another thread compiles is a use-after-free.
**Test.**
- Stress unit test: 64 concurrent `translate` calls over 16 different WE shaders on `DispatchQueue.concurrentPerform`, run under Thread Sanitizer and Address Sanitizer, 50 iterations; compare every output byte-for-byte to a serial run.
- Assert `InitializeProcess` is called exactly once (e.g. `static let` / `dispatch_once`) and `FinalizeProcess` never while the app lives.
- Manual: two displays, two different heavy scene wallpapers, launch with an empty cache.

**Status (R2, 2026-09-25).** Fixed 1231087: `InitializeProcess` runs once (`std::call_once`), is never finalized, and one mutex serializes every library call. Verified by `InProcessShaderCompilerTests.testParallelTranslationMatchesSerial` (24 pairs × 4 rounds concurrent, byte-equal to serial), which also passes under Thread Sanitizer with no reports. Open: two displays loading heavy scenes with an empty cache is manual. ASan was not run.

## 3. Static-lib symbol clashes — Critical, B
**Scenario.** glslang ships its own `spv::` headers and SPIRV-Tools; SPIRV-Cross embeds `spirv.hpp` (`spv::` namespace too). Linking both statically can give ODR violations (different `spv::Op` enum sizes, duplicated inline functions) — the linker silently picks one; crashes only on specific opcodes. Also clashes with any other C++ in the process (MoltenVK-like libs, a future `.mdl` loader). Duplicate `-lc++` / different C++ standard libraries between prebuilt libs and Xcode.
**Test.**
- Build step: `nm -gU` the app binary, grep for duplicate weak `spv::` symbols; fail CI if the linker emits "duplicate symbol" or ODR warnings (`-Wl,-warn_commons`, `-Wodr` with LTO).
- Round-trip test: translate the whole bundled `we-assets/shaders` corpus in-process and compare to the process path (golden). Any difference that is not whitespace is a bug.
- Build Release with LTO and with `-dead_strip`; run the same corpus test on the Release binary.

**Status (R2, 2026-09-25).** Verified. SPIRV-Cross's `spv::` is renamed `spvc_spv` (f28027d). `Scripts/check-toolchain-symbols.sh` (2a11bc6, run in CI) finds no symbol defined by both libraries in Debug or Release objects; the only shared definitions are libc++ instantiations and the libraries' own header inlines in the shim. `testMatchesProcessCompilerOverBundledCorpus` is byte-identical to the Homebrew tools. The Release archive links with dead stripping. Open: LTO is off, and the corpus test runs on the Debug build.

## 4. Corrupt or foreign `MTLBinaryArchive` — High, B
**Scenario.** App killed mid-`serialize(to:)`; disk full; the file written by a newer macOS/driver and read by an older one after a downgrade; two app instances (or login-item + manually launched) writing the same archive. `makeBinaryArchive(descriptor:)` with a corrupt URL throws — or succeeds and `makeRenderPipelineState` crashes deep in the driver.
**Test.**
- Unit: write random bytes / a truncated real archive to the archive path, launch the loader, assert it deletes the file and falls back to an empty archive without crashing.
- Serialize to a temp file then atomically rename; unit test that no partial file exists at the final path after a simulated failure.
- Manual: `kill -9` the app during first-launch warmup, relaunch.

**Status (R2, 2026-09-25).** Fixed a040708 and bdd0b48: writes go to a pid-named temporary file that is renamed into place, and an archive Metal can't open is deleted. Verified by `EffectPipelineArchiveTests`: `testCorruptArchiveIsDiscardedAndReplaced`, `testTruncatedArchiveIsDiscarded` (b68e85f), `testCompiledPipelinesArePersistedAndHitOnTheNextLaunch` (no `.tmp` left behind) and `testConcurrentCompilesSerializeCleanly` (also clean under TSan). With two instances, the last writer wins. Open: `kill -9` during warmup is manual (QA 3).

## 5. Binary archive tied to one GPU; GPU switch — High, B
**Scenario.** Archives contain GPU-specific binaries. MacBook Pro with dGPU/iGPU switching, eGPU hot-plug, or two displays on different GPUs (Intel Mac Pro): a pipeline looked up in an archive from another device silently recompiles (fine) — or code passes the archive to a device other than the one it was created with (error). Also an OS update invalidates everything; archive grows unbounded as keys accumulate.
**Test.**
- Key the archive file by `device.registryID` + OS build + app version; unit test the path function.
- Manual: Intel MBP, toggle "Automatic graphics switching", plug an external display, confirm no errors in `/usr/bin/log stream --predicate 'subsystem CONTAINS "wallpaper"'`.
- Check archive size after 44-wallpaper library sweep, then again after 3 sweeps (should not grow).

**Status (R2, 2026-09-25).** Fixed a040708: there is one file per GPU (name and registry ID), OS build, app build and revision, and this GPU's stale files are deleted. Each write holds only the pipelines of the last session that compiled something, which bounds the size. Verified by `testEachGPUHasItsOwnArchive` (b68e85f), `testArchivesForAnotherBuildOfThisGPUAreDeleted`, `testRenderersOfADeviceShareOneArchive` and `testBuiltinEffectPipelinesSurviveRepeatedWritesAndLaunches`. Open: a real GPU switch or eGPU is manual; no dual-GPU Mac was available.

## 6. Async pipeline compile races with `releaseLayer` — High, B
**Scenario.** A layer requests a pipeline asynchronously, then the wallpaper is switched (or a clone is removed, see #14) and `releaseLayer` runs before the completion handler; the handler writes into freed state or re-inserts a pipeline for a dead layer (leak). Two layers requesting the same key concurrently compile twice and one overwrites the other's cache entry while a frame is encoding with it.
**Test.**
- Unit: fake compiler with a controllable delay; request → `releaseLayer` → complete; assert no entry remains and no crash (TSan).
- Unit: two concurrent requests for one key produce one compile (in-flight dedupe).
- Manual: rapidly switch wallpapers (arrow keys in library) 30× with an empty cache.

**Status (R2, 2026-09-25).** Fixed 96a746b: the check for a pending compile and marking it pending were two separate locked steps, so two callers could both start one. Pipelines are keyed by variant, not by layer, and a completion only writes the shared cache under the lock. Verified by `EffectGraphTests.testReleaseLayerWhileItsPipelinesCompile` (no state comes back, and the next layer reuses the compiles) and `testConcurrentRequestsCompileEachPipelineOnce` (clean under TSan). Open: switching wallpapers 30× with an empty cache is manual.

## 7. In-process failure modes replace a recoverable subprocess — High, B
**Scenario.** The spawn path has a 30 s timeout and isolates crashes (`ShaderCompiler.swift:73`, `:76-100`). In-process, a glslang `assert`/`abort` on a malformed WE shader, an infinite loop in the preprocessor, or a stack overflow on deeply nested macros kills the whole app — and the menu-bar/login-item app then crash-loops on relaunch with the same wallpaper. `/tmp/owe-failed-shaders` dumping may also be lost.
**Test.**
- Fuzz: feed the translator truncated/garbled versions of 50 WE shaders; the app must return an error, not abort. Build glslang with `NDEBUG` in Release.
- Test that a failed shader still lands in `/tmp/owe-failed-shaders`.
- Crash-loop guard: if the app crashed during translation last launch, start without restoring the wallpaper (manual: inject a crash).

**Status (R2, 2026-09-25).** Fixed 0be8b90 and earlier. glslang builds with `NDEBUG`. `InProcessCompileCrashGuard` turns in-process compiling off after 2 deaths mid-compile, and safe restart skips the wallpaper. Fixed d9b00ee and 0418de2: the `/tmp/owe-failed-shaders` dump had been lost with the process translator. Verified by `ShaderVariantCacheTests.testGarbledSourcesFailWithoutCrashing` (truncated and garbled WE shaders, 20 000 parentheses, 2 000 nested `#if`), `testRejectedSourceIsWrittenForInspection` and `testFactoryFallsBackOnlyAfterRepeatedCrashes`, plus the crash-guard tests in `InProcessShaderCompilerTests`. Fixed e671ff6: in-process compiles run on a dedicated thread (16 MB stack) under a 20 s watchdog on the job's run time. A hung compile fails its variant, counts as a death for the crash guard (so a hang that recurs turns in-process compiling off on the next launch), and routes every later compile this session to the process compiler, since the stuck thread keeps glslang's lock. Verified by `InProcessShaderCompilerTests.testCompileThreadTimesOutAndFailsQueuedJobs`, `testTimeoutCountsRunTimeNotQueueTime`, `testHungCompileFailsItsVariantAndHandsOverToTheFallback` and `testHungCompileWithoutFallbackFailsFast`. Open: without Homebrew's tools, compiles after a hang fail for the rest of the session.

## 8. Packaging still expects `shader-tools`; hardened runtime — High, B / CI
**Scenario.** The release workflow asserts `Contents/Resources/shader-tools/glslangValidator` and `spirv-cross` exist and are executable, and CI `brew install`s them (`.github/workflows/*` "Verify bundle before notarizing"; `brew install glslang spirv-cross`). M9 removes them → release fails, or the tools are kept and unsigned binaries are notarized needlessly. If glslang is instead linked as a *dylib*, it must be signed with the same team, embedded under `Frameworks`, and library validation (hardened runtime) rejects an unsigned/ad-hoc dylib at launch — works in Debug, crashes in the notarized build. `SceneShaderTranslator.swift:18-19` still searches `/opt/homebrew/bin` and `/usr/local/bin`: a stale Homebrew toolchain could be preferred over the in-process one.
**Test.**
- Update the verify step: assert no `shader-tools`, run `codesign --verify --deep --strict` and `otool -L` shows no `/opt/homebrew` paths.
- Manual on a clean Mac/VM with no Homebrew: install the notarized DMG, open a scene with effects.
- Unit: the translator factory returns the in-process backend even when `/opt/homebrew/bin/glslangValidator` exists.

**Status (R2, 2026-09-25).** Fixed 9dda345: removed the Vendor Shader Tools build phase and its script, the bundle path from the fallback search and Homebrew from the release workflow. The release check now asserts that there is no `shader-tools`, that the WE assets are bundled, a Developer ID signature, the hardened runtime, only `/usr/lib` and `/System` libraries, and no extra executables. The linked libraries are static, so library validation has no dylib to reject. Verified locally on a Release archive: `codesign --verify --deep --strict` passes, `flags=0x10002(adhoc,runtime)`, `otool -L` lists system libraries only, and the verify step's checks pass. Also by `ShaderVariantCacheTests.testFactoryPrefersTheLinkedCompiler` with Homebrew installed. Tests translate in-process, so they need no Homebrew (1da4ae8). Open: Developer ID signing and notarization run only in the workflow, which hasn't run yet. QA 1 (a clean Mac) is manual.

## 9. Pool evicts targets whose contents must survive — High, R (9cccfe2, d05e689)
**Scenario.** `SceneRenderTargetPool.endFrame()` drops any bucket untouched for 600 frames (`Scene/Rendering/SceneRenderTargetPool.swift:64-67`) and `evictOverBudget` drops the LRU bucket over 256 MB (`:73-80`). Anything that relies on *previous-frame content* (ping-pong feedback effects, `_rt_` persistent targets, cached static-chain results from #18) gets a fresh uninitialised texture: trails reset, or garbage because `.private` storage is not cleared. 600 frames = 5 s at 120 Hz, 10 s at 60 Hz, so a layer hidden by a script for a few seconds loses its state; behaviour depends on refresh rate. Also: `texture(...)` returns `buckets[key]!.textures.first` (`:46-48`) — two consumers of the same size in one frame get the *same* texture unless `avoiding` is passed.
**Test.**
- Unit: request A, then `endFrame()` 601× without touching A, request again → assert the caller that holds a persistent target is notified/re-seeded (or persistent targets are excluded from the pool).
- Unit: two requests of the same key within a frame without `avoiding` → assert distinct textures (or document the contract).
- Headless: render a feedback-effect wallpaper 120 frames, hide the layer for 700 frames, show it → compare to reference.

**Status (R2, 2026-09-25).** Fixed 7272f67: frame leases, persistent leases that are never evicted or shared, and idle eviction by wall time instead of frames. Verified by `SceneRenderTargetPoolTests` (distinct textures within a frame, `avoiding`, idle by time at 240 Hz, persistent targets and LRU over budget). Effect ping-pong and FBO targets are per layer in `EffectGraphRenderer`, not pooled, so a hidden layer keeps them. Memory pressure trims free targets (#20).

## 10. Screen-space scene snapshot — High, A
**Scenario.** Rotated or partly off-screen layers whose effect reads the scene (`_rt_FullFrameBuffer`, refraction). Edge cases: rotation 90°/180° (width/height swap), negative scale (mirrored), layer entirely off-screen (zero-size rect: `pixelRect` returns nil at `Scene/Rendering/SceneRenderResolution.swift:33-`), snapshot taken before vs after the layer's own draw (feedback into itself), Retina scale (#11) applied twice or not at all, y-flip between scene y-up and texture y-down.
**Test.**
- Headless render check: synthetic scene with a checkerboard background and a 45°-rotated layer running a pass-through "sample framebuffer" effect; the output inside the layer must equal the background pixels under it (tolerance 1/255). Repeat for 90°, 180°, mirrored, half off-screen, fully off-screen.
- Unit: `pixelRect` for a box beyond every edge returns nil; for NaN/inf returns nil.
**Status (R1, 2026-09-25).** Verified by `SceneRegionResampleTests` (e3cb90f): a headless round trip through `sceneCopyFragment` and `sceneVertex` gives back the scene beneath for quads at 0/45/90/180/270°, mirrored on x or y, sheared, and half or fully off-screen. Zero, NaN and infinite quads cover no pixels. `pixelRect` no longer exists (bd8ceba). Since 221bed9 a blend-mode material or scene-input layer copies only its quad's padded bounding rect into one per-frame snapshot target, and a copy that still matches is shared (`SceneSnapshotTracker`); effects that read the scene still get all of it. Verified by `SceneSnapshotTrackerTests` (rect maths, sharing, and three `BLENDMODE` layers over each other reading the right scene from partial copies).

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
**Status (particles, 2026-09-25).** The emitter's transform is now live (animated and scripted parents), and gravity follows WE's `movement` flag 1: without it gravity turns with the emitter, with it gravity is scene space. Particles live in the emitter's space and move, turn and scale with it unless the system's `worldspace` flag (bit 0) is set (WE's docs: worldspace particles "ignore the position and rotation of the particle system after they have been created"). Verified by `ParticleEmitterMotionTests` (local particles follow a moved, turned and scaled emitter; worldspace ones stay), `ParticleSimulationParityTests.testParticlesFollowAMovingEmitter` and `testWorldSpaceParticlesIgnoreAMovingEmitter` (CPU and GPU agree under a moving emitter), and `SceneRendererParticleFamilyTests.testGPUParticlesFollowTheirAnimatedParent`. Open: sprite sizes under a non-uniform scale take the area scale; WE's model matrix would squash them.
**Status (particles, 2026-09-25, later).** Sprites are drawn through the emitter's transform, as WE's `genericparticle` expands a sprite in the system's space before `g_ModelViewProjectionMatrix` (linux-wallpaperengine and wallpaper-scene-renderer build the same model matrix, scale included): sizes and rotations stay local, the material path passes the emitter's linear as `g_OrientationRight/Up`, the built-in draw as the quad's axes, and trail and rope widths take its area scale. A non-uniform scale squashes and skews sprites; the emitter's first transform counts, not only its moves; a `worldspace` particle takes the area scale and turn when it spawns. Verified by `ParticleEmitterMotionTests.testANonUniformScaleSquashesSprites`, `testWorldSpaceParticlesTakeTheEmitterScaleWhenTheySpawn`, `ParticleMaterialRenderTests.testANonUniformEmitterScaleSquashesTheSprite` (both stages) and `ParticleSimulationParityTests.testBuiltInSpritesTakeTheEmitterTransform`. Open: WE simulates in the system's units, so velocities, gravity and operator distances would scale with the object as well; ours turn with it but stay scene units. Worldspace sprites under a non-uniform scale take the area scale. Both need a WE capture to settle.

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
**Status (R1, 2026-09-25).** The pool is B's. Fixed by 7272f67: it counts `allocatedSize`, never evicts leased targets, and ages targets out by wall time. Verified by `SceneRenderTargetPoolTests`. Fixed d73bf75: each renderer observes `DispatchSource.makeMemoryPressureSource`; a warning drops the pool's free targets, cached text beyond the current strings, spare effect targets and free uniform chunks, and a critical event also drops effect asset textures and pipelines idle since the last critical trim. Leased, persistent and layer-owned targets stay. Verified by `SceneMemoryPressureTests` (a blend layer still draws through its material on the frame after a critical trim) and `EffectGraphReuseTests.testMemoryPressureDropsSpareTargetsAndIdlePipelinesOnly`. Open: particle material pipelines aren't trimmed, and the manual 8 GB check is not done.

## 21. Per-wallpaper property store — Medium, R (0ba2720, 286158d)
**Scenario.** Keys per wallpaper instance: same wallpaper on two displays (one store or two?), workshop id vs folder path (a moved library changes keys → user settings lost), a property named with dots/slashes, deleting a wallpaper leaves orphans, a property changing type after a workshop update (bool → combo) → decode fails and crashes or silently resets.
**Test.**
- Unit on `Scene/Scripting/SceneUserPropertyStores.swift`: type change on stored value, two displays same wallpaper, key containing `.`.
- Manual: set a colour on display 1, check display 2; move the library folder; relaunch.
**Status (R1, 2026-09-25).** Verified by `SceneUserPropertyStoreTests` (1011bf9): a bool that becomes a combo, keys with dots and slashes, and one wallpaper on two displays sharing one entry. Open: it's unknown whether WE keeps properties per monitor. Fixed 23db937: stored settings are keyed by the Workshop id (or Steam's numeric folder), else a hash of `project.json` plus the folder name, and old path keys move over on first sight, including a single missing folder of the same name. Verified by `WallpaperSettingsIdentityTests`. Open: scene music and video music-sync settings are still keyed by path.

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

**Status (R2, 2026-09-25).** Fixed 8cd197b: variants are stored per generation (`r<revision>-<compiler hash>`). Other generations and the old flat files are deleted after a week unused. The path's bundle id still matches the app's (`com.winddog.wallpaper-engine`). Verified by `ShaderVariantCacheTests`: `testVariantsLiveInTheirGeneration`, `testStaleGenerationsArePruned`, `testUnwritableCacheStillTranslates` and `testCorruptCachedVariantIsRetranslated`. Tests no longer write the user's pipeline archive (1da4ae8). Open: within one generation the cache grows with the variants used, which is bounded by the library.

## 25. CI with older Xcode / SDK — Low, B/CI
**Scenario.** CI uses `macos-15` and picks the latest Xcode; a runner with an older Xcode lacks newer `MTLBinaryArchive`/Metal 3 APIs or C++20 features glslang needs; prebuilt static libs compiled with a newer clang (`-fcoroutines`, newer libc++ ABI) fail to link on older Xcode; deployment target mismatch warnings ("built for macOS 15 newer than 14"). Building glslang from source in CI adds minutes and may time out.
**Test.**
- Add a CI matrix leg with the oldest supported Xcode; `-Werror` on "was built for newer macOS version".
- Guard new Metal APIs with `if #available` and a unit test that the fallback path (no archive) still compiles pipelines.

**Status (R2, 2026-09-25).** Fixed 2a11bc6. CI and release pin Xcode 16.4, the oldest supported version, instead of the newest on the image, so development on the newest Xcode and CI on the oldest cover both. CI fails on "built for newer macOS version" link warnings and on toolchain symbol clashes. The Metal APIs used (`MTLBinaryArchive`, `.failOnBinaryArchiveMiss`) need macOS 11, below the 14.0 deployment target, so no `#available` is needed. The no-archive path runs in `ImageMaterialRenderTests` (`archive: nil`). Open: nothing was built with Xcode 16.4 locally (only Xcode 27 is installed); CI is the check.

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
**Status (particles, H).** Verified by `ParticleMaterialRenderTests.testEveryAttributeTheStageReadsComesFromTheRecord` (every renderer form × both stages: no attribute reads the zero buffer) and `testColourAndAlphaReachThePixel` (`bc63f2d`), with `testSpriteThroughEmulatedGeometryStage` (size), `testBothPathsDrawTheSameRotatedSprite` (radians) and `testClampUVsKeepsTheOppositeEdgeOut` (non-square aspect). The GPU simulation writes the same records (`ParticleSimulationParityTests.testSwiftAndMetalLayoutsAgree`, `testSpriteRecordsMatchTheCPUWriter`). Sizes follow linux-wallpaperengine (quad width = size/2, `0591466`); a WE capture is still Open.

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
**Status (particles, H).** Verified by `testRestartedStripsLeaveTheGapsBetweenThem`, `testEmittingFewerVerticesThanTheBoundDrawsOnlyThoseTriangles`, `testStripTrianglesKeepOneWinding` (`329a12d`), `GeometryShaderEmulationTests.testMaxVertexCountExpressions`, and `ParticleGPURenderTests.testTenThousandSpritesReuseTheirBuffers` (`bc63f2d`: 10 000 sprites keep one record and one particle buffer over 99 frames).

## I5. Blend-mode table parity and scene-target alpha (High, E)
**Scenario.** WE material `blending` values seen are `normal`, `translucent`, `additive` (and `disabled` in some workshop content). `EffectGraphRenderer.blendMode` (`Scene/Rendering/EffectGraphRenderer.swift:534-539`) maps `additive` to `(srcAlpha, one)` for **alpha as well**, and anything else to "no blending". The native additive path uses `(one, one)` for alpha (`SceneMetalRenderer.swift:180-183`). A `normal` (overwrite) image layer with transparent texels writes alpha 0 into the scene target. The final composite then blends the scene target with `sourceAlpha` (`SceneMetalRenderer.swift:~575`, `renderPipeline`), which WE never does at present, so holes show the clear colour. Unknown blending strings silently become overwrite.
**Test.**
- Table test over every blending string found in library + we-assets materials: expected Metal factors per RGB and alpha; an unknown string logs once.
- Headless: red opaque background + a `normal` layer whose texture has a transparent quadrant → the final drawable shows the texture's RGB there (or matches a WE reference screenshot), never the clear colour.
- An additive layer over a transparent area: final pixel equals WE's.
**Status (R1, 2026-09-25).** Fixed 320b7ec (opaque composite). Verified by `testNormalBlendingOverwritesTheScene`, `testCompositeIgnoresTheSceneAlpha` and `testAdditiveBlendingMatchesTheNativeAdditiveDraw`. Open: an unknown `blending` string silently overwrites (`EffectGraphRenderer.blendMode`, which is B's); fixing it needs WE's full list of blending values.

**Status (R2, 2026-09-25).** Fixed d03f50e: an unknown `blending` value still overwrites, as `normal` does, and is now logged once. `normal`, `disabled`, `translucent` and `additive` are known; the bundled assets and the 49-wallpaper library use only `normal` (416), `translucent` (213) and `additive` (56). Verified by `EffectGraphCachingTests.testBlendingTable`. Open: WE's full list of values.

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
**Status (particles, H).** Verified for particles by `ParticleMaterialRenderTests.testGreyStaysGreyInTheSceneFormat` (`bc63f2d`: 0x80 stays 0x80 in rgba8 and bgra8 targets); the particle pipeline key includes the target format. BC and ICC-tagged inputs and the `MTL_DEBUG_LAYER` run: Open (texture loading is E's).

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
**Status (particles, H).** Verified for particles by `testCoverageMaskSpriteTakesTheParticlesColour` (`bc63f2d`: TEXParser's white-plus-alpha R8 expansion takes the particle's colour; `TEX0FORMAT` stays unset and genericparticle doesn't read it). REFRACT particles draw through their material (`a0d6c15`). Block-compressed textures after the first set `TEX<n>FORMAT` (`187e2b3`, `testBlockCompressedTexturesAfterTheFirstSetTheirFormatCombo`), so a DXT normal map decompresses as in WE. RG88 normal maps: Open (none in the library; TEXParser's `(l,l,l,a)` expansion puts R in the mask).
**Status (particles, 2026-09-25, later).** RG88 loads as (r, g, 0, 1), as the GPU samples a two-channel texture, and particle materials set `TEX<n>FORMAT=8` for RG88 slots (texture 0 included): `ConvertTexture0Format` reads an albedo as `.rrrg` and `DecompressNormalWithMask` a normal map as `.gr`. The built-in draw gets a luminance-alpha copy (`ParticleFallbackTexture`). Consumers of the old expansion: only particle albedos (51 bundled textures), now converted by the combo; the library's other RG88 textures are `shake`/`waterflow`/`psyhue` flow maps, which read `.rg` and were losing their y, and two normal maps for `genericimage4` lighting (area 5). Verified by `TextureRG88Tests`, `ParticleMaterialRenderTests.testRG88NormalMapRefractsThroughItsFormatCombo` (green is x) and `testRG88AlbedoReadsAsLuminanceAndAlpha`. Image and effect materials set `TEX<n>FORMAT` for their `formatcombo` samplers since `55fdd33`.

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
**Status (R1, 2026-09-25).** Verified by `testRemovedClonesFreeTheirUniformState` (ac3b667: 100 layers on one material compile one pipeline and hold 100 programs, all freed on release) and `testStillLayerRewritesNoPlacementUniforms`. Fixed 87b58cf: uniforms over 4 KB come from `SceneUniformArena` (256-aligned slices of reused chunks, recycled once their command buffers complete). Verified by `SceneUniformArenaTests` and `ImageMaterialRenderTests.testLargeUniformBlocksComeFromTheArena`. Open: `ParticleMaterialRenderer` still makes a buffer per draw, and frame time for 500 layers is unmeasured.

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
**Status (particles, H).** Verified by `testRopeThroughEmulatedGeometryStage` (shader swap), `testSubdividedRopeCurvesThroughItsPoints`, and `testRopeJoinsParticlesInOrder` and `testRopeShaderBuildsForEverySubdivisionAndTrailCombo` (`bc63f2d`: subdivision 0–4 × trail combos; the geometry stage builds everywhere, the no-GS stream everywhere except `TRAILSCROLLALPHA` + `TRAILFADESIZE`, WE's own `sizeStart.w` bug, which the test asserts). The GPU simulation keeps spawn order with an order-preserving compaction (`c6f6fbc`), checked by `ParticleSimulationParityTests` (spawn order, rope and rope-trail records, `testRopeTrailHistory`). Spline shape against WE: Open, needs a WE capture.
**Status (particles, 2026-09-25, later).** A rope on an instanced system (a child) draws one strand per instance: record `i` joins particle `i` to the next particle of its instance, with the strand's own point count and index for the UVs, and the last of each strand gets an empty record; the built-in draw likewise. Verified by `ParticleChildrenTests.testAnInstancedRopeDrawsOneStrandPerInstance` (CPU records and the GPU's agree; no segment joins two instances). The GPU finds a strand's neighbours with a scan over the system's particles, O(n) per particle for an instanced rope (child ropes are small; WE's thunderbolt beam is 8 a strand).

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
**Status (particles, H).** Verified by `testRestartedStripsLeaveTheGapsBetweenThem` and `testEmittingFewerVerticesThanTheBoundDrawsOnlyThoseTriangles` (a loop bounded at runtime in `stripquads.geom`), `GeometryShaderEmulationTests.testLoopBodyRedeclaringTheLoopVariableGetsItsOwnScope` and `testNonPointInputIsReported`; a failed stage falls back (I16).

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
**Status (particles, H).** Verified for particles by `testFailedPipelineFallsBackToTheBuiltInDraw` and `testAFallbackIsReportedOnce` (`bc63f2d`: one report over 100 frames, `ParticleMaterialRenderer.fallbacksReported`). Only a material none of whose stages builds falls back; refraction no longer does (`a0d6c15`), and a compiling pipeline draws nothing instead of the built-in look-alike (`207b700`, `testCompilingPipelineDrawsNothingRatherThanTheBuiltInDraw`). The built-in draw also works from GPU-simulated particles (`ParticleSimulationParityTests.testBuiltInDrawInstances`, `SceneRendererParticleTests`).

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
**Status (particles, H).** Verified for particles by `ParticleMaterialSweepTests` (89 systems, 356 pipelines of which 32 refracting, 0 failures, 0 systems left on the built-in draw; in-process compiler, shader chosen by renderer) and `ParticleSimulationSweepTests` (`d3ff7e9`: 74 loaded systems through the CPU and GPU simulations, 0 failures). A rendered frame per wallpaper against a baseline: Open.

## I18. Text layers (Med, E)
**Scenario.** WE draws text with `font` (`Vendor/we-assets/materials/fonts/basefont*.json`: `g_Color4`, `MSDF`, `COLORFONT`, `g_RenderVar0..3` outline/shadow), not genericimage. Our text is CoreText-rasterised with its colour baked in (`SceneMetalRenderer.swift:921`) and is premultiplied. Routing it through genericimage2 `VERSION` with `g_Color4 = (colour, alpha)` squares the colour. Leaving it native makes text blend differently from images (I1), so a text layer next to an image with the same alpha looks different.
**Test.**
- Red `(1,0,0)` text, alpha 0.5, over white → glyph interior `(1,0.5,0.5)`; an edge pixel is no darker than the interior blend.
- The same text with a shake effect has the same colour.
**Status (R1, 2026-09-25).** Fixed 5aa4e95 (premultiplied glyph edges) and 22f8798 (alpha applied once). Verified by `TextureUploadTests.testTextEdgesKeepTheTextColour` and `testNativeDrawAppliesLayerAlphaOnce`. Fixed e277d74: text is rasterised white, uploaded as an R8 coverage texture, and drawn through `materials/fonts/basefont.json` (the `font` shader) with `g_Color4` as its colour, brightness and alpha. Verified by `ImageMaterialRenderTests.testTextFontMaterialTintsItsCoverageOnce` (red at alpha 0.5 over white, half-coverage edge, equal to the native draw), `TextureUploadTests.testWhiteTextGivesItsCoverage` and `RenderCheckTests`. Open: text with effects or a blend mode, and colour glyphs (emoji), draw natively; MSDF, outline and drop shadow need WE's MSDF atlas, which isn't generated.

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
**Status (particles, H).** Verified by `testEveryParticleUniformHasASource` (`bc63f2d`: every uniform of every particle stage is a built-in, a material or annotation constant, or one `ParticleMaterialUniforms` writes); the rope's `g_RenderVar0` point count comes from the GPU step (`ParticleGPURenderTests.testRopeRenderVarHoldsTheGPUsPointCount`). `flatpoint` size at 1080p vs 2160p against WE: Open, needs a WE capture.

## I22. `#define HLSL 0` semantics (Med, E/F)
**Scenario.** The prelude defines `GLSL 1` and `HLSL 0` (`Scene/Shaders/ShaderPrelude.swift:81-82`). So `#ifdef HLSL` blocks are **taken**: 17 in the assets, including the `v_ScreenCoord.y` flip in `genericimage2/3/4.vert`, `common_particles.h` refraction coords and `normal.y` in `genericimage3/4.frag`. Meanwhile `#if HLSL` (8) and `#ifndef HLSL` (2, e.g. the `genericparticle.frag` refraction offset y) take the GL branch. One shader can run HLSL-convention code in one place and GL-convention code in another, a mix WE never ships. It may be right for Metal's y-down textures, or it may flip. *Update:* `9d8c262` now leaves `HLSL`/`HLSL_SM30` undefined (GL branches everywhere, like WE's GLSL backend). The risk is now anything calibrated against the old mix; see Findings E-7.
**Test.** A REFRACT particle with a +y normal over a horizontal-stripe background, and a `BLENDMODE` layer over a gradient: the displacement direction and orientation must match a WE reference capture. Keep a table test listing the `#ifdef HLSL` sites so a prelude change is deliberate.
**Status (R1, 2026-09-25).** The prelude is B's (9d8c262). On the image side, `testBlendModeReadsTheScenePixelBeneath` verifies it. Particle refraction (`a0d6c15`): `v_ScreenCoord` already runs top-down, because the particle projection puts the scene's top at GL's bottom; with the GL offset flip, `g_ViewUp` is scene −y so a +y normal samples below as in WE (`testRefractionNormalOffsetsAlongTheScreenAxes`). A WE capture: Open.

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
**Status (particles, H).** Draw order verified by `SceneRendererParticleTests` (`5336d12`: whole `SceneMetalRenderer` frames, GPU and CPU simulation, built-in and material draw; particles cover the layer below and the layer above covers them); overbright saturation by `testAdditiveOverbrightSaturates` (`bc63f2d`). The REFRACT snapshot holds the layers below and not those above (`a0d6c15`, `testGPUSimulatedRefractionReadsTheSceneUpToItsSystem`, `testCPUSimulatedRefractionReadsTheSceneUpToItsSystem`). Additive alpha against WE: Open.

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

**Status of F1–F6 (particles, H).** F1 fixed by `0591466` (`testRandomSpriteFramesShowOneFrameEvenWithFrameBlending`). F2 fixed by `0591466`, following linux-wallpaperengine and wallpaper-scene-renderer (size/2); a WE capture is still Open. F3 fixed by `0591466` (`.tex` flags pick the sampler: `testClampUVsKeepsTheOppositeEdgeOut`, `testBuilderReadsTheTextureFlags`). F4 fixed by `329a12d` (the three pixel tests above). F5 measured by `ParticleMaterialPerformanceTests.testSubdividedRopeTrailCost`: 2 000 rope-trail segments on an M4 take 2.9 / 1.9 / 3.8 ms GPU at S = 0 / 4 / 8. F6 fixed by `a0d6c15` (scene snapshot per refracting system) and `671456d` (the built-in draw's faded look-alike no longer dims them).

---

# SceneScript

Status: 2026-09-25, branch `deepratna/feature-work`, base `94a9e6e` (WP1 and WP2 landed). Adversarial list for the rewrite in [`scenescript-plan.md`](scenescript-plan.md); owners are its work packages. Paths are relative to `OpenWallpaperEngine/`. "Corpus" is `/Volumes/980Pro/dd-scenescript/corpus` (281 scripts, 508 sites); a 12-hex name like `08861b7e67b4` is `corpus/scripts/<name>.js`. §1.9 P*n* is the plan's evidence table.

| # | Sev | Owner | Risk |
|---|-----|-------|------|
| S1 | Critical | WP3 | Tokenizer: regex vs division, comments and strings that contain `export`/`import`, template literals |
| S2 | High | WP3 | Export getters pick up non-exported functions and globals named like callbacks |
| S3 | Medium | WP3 | Sloppy-mode wrapper: implicit globals and `this`, unlike WE's always-strict modules |
| S4 | High | WP3, WP2 | Line and column drift in error reports |
| S5 | Medium | WP3, WP9 | Compile failures and V8-vs-JSC language gaps (macOS 13 JSC) |
| S6 | Critical | WP8, WP11 | Return-value coercion: NaN/Infinity reach Swift `Int(...)`, broadcast, text |
| S7 | High | WP8 | Accumulators and aliasing of `value` between calls |
| S8 | High | WP4, WP8 | Load order: `scriptproperties` → `init` → `applyUserProperties`; user-bound script properties |
| S9 | High | WP4 | Timers: cancel after fire, timers added while timers run, clock source, NaN delays |
| S10 | High | WP2, WP4, WP6, WP11 | Teardown: timers, `destroy()`, storage flush, no extension teardown hook |
| S11 | High | WP2, WP7, WP11 | Reentrancy: scripts creating or destroying layers and scripts inside callbacks |
| S12 | High | WP7, WP11 | `createLayer` from assets that must be loaded, or are missing |
| S13 | Medium | WP7, WP11 | `sortLayer` and command timing relative to updates and the draw |
| S14 | High | WP7, WP6 | Vector aliasing in setters, getters and event objects |
| S15 | Medium | WP7, WP8 | Vec math interop, degrees↔radians and Float32 round trips |
| S16 | High | WP5 | Audio buffers: sharing between scripts, smoothing advanced per renderer, races with capture |
| S17 | Critical | WP2, WP5 | A script detaches a shared typed array; JSC frees Swift's memory (use after free) |
| S18 | High | WP6 | MediaRemote unavailable or slow; artwork palette on the render thread |
| S19 | High | WP2, WP11 | Watchdog runs on the main thread; one hung script freezes the app and halts everything |
| S20 | Medium | WP2, WP6, WP10 | Inbox overflow drops state-changing events |
| S21 | Medium | WP4 | `localStorage` limits, corruption, write amplification, display ids |
| S22 | High | WP11, all | Two displays must share nothing |
| S23 | High | all | Swift↔JS retain cycles leak a whole VM per wallpaper switch |
| S24 | Medium | WP9, all | Per-frame allocations, GC pauses, the < 0.5 ms target, replay determinism |
| S25 | High | WP7, WP8 | Scripts on effects and materials (`thisObject`) |
| S26 | Medium | WP8, WP10, WP11 | Scripts on hidden layers and effects |
| S27 | Medium | WP10 | Cursor hit testing: spaces, parallax, Retina, multi-display, click pairing |
| S28 | Medium | WP2, WP7 | Untrusted scripts reach `__rt` and the shared buffers |

---

## S1. Tokenizer edge cases (Critical, WP3)
**Scenario.** The transformer finds top-level `import`/`export` with a tokenizer (plan §4.2). The corpus has everything that trips a naive one:
- 24 scripts with commented-out exports: `// export function update(value){` (about 15 scripts), block comments `/*export function init() {` (`01d5071b6f02` and others). If a comment is not skipped, a dead `update` becomes live, or `export ` is stripped from the middle of a comment and breaks nothing visibly but shifts the next token.
- `import` inside a comment (`01aa0f2822e2:3`, `// import * as WEVector from 'WEVector';`). Blanking that line is harmless; treating it as an import and registering a dependency is not.
- Regex literals after `(`: `string.split(/\s*,\s*/)` (`1b3a92cc7a8f:83`, `6f913f89fcc9`, `867af3817c70`). The classic trap: `/` after `)` or an identifier is division, after `(`, `,`, `=`, `return`, `typeof` it starts a regex. A mis-classified `/` swallows the rest of the line as a regex and can hide a real `export` or unbalance braces so "top level" is wrong.
- Template literals with `${…}` (`159224b59e2a:10`, `f86e0df8a16e:237`) and multi-line Japanese templates containing `\n` (`f902ebf8404a:29-33`). A template that contains `}` inside `${ {a:1} }` breaks depth counting.
- 32 scripts contain CJK text and full-width punctuation `（）` in comments and strings; none have astral characters, BOM, CRLF or U+2028 today, but Workshop scripts edited on Windows commonly have CRLF.
- 147 scripts use `export let/var/const`; none use `export {…}`, `export default`, classes or generators.
**Test.**
- Corpus: for every script, the export set the compiler reports equals `per-script.json`'s exports, and the transformed source has the same line count.
- Synthetic: `a = b / c / d` and `x = y /2/ z` stay division; `return /x/.test(s)`, `(/a/)`, `[/a/]`, `!/a/` are regexes; `}` then `/` after a block vs after an object literal; `` `${ {a:1}.a }` ``; `'export function update'` in a string; `obj.export = 1`, `{ import: 1 }`, `x.import`; `export` followed by a newline and then `function` (still an export); `export let a = 1, b = 2` (two exports); `export let {a} = o` (reject or support, but decide).
- A CRLF copy and a CR-only copy of every corpus script compile to the same exports and line numbers.

## S2. Export getters resolve non-exports (High, WP3)
**Scenario.** The contract says exports are "getters for every name in `__rt.CALLBACKS` plus `scriptProperties`" (`Modules/SceneScriptModuleCompiling.swift:10-11`, plan §4.2 `get update(){ return typeof update==='function'?update:undefined }`). If the compiler emits such a getter for a name the script did not export, it resolves the identifier through the module scope and then the global scope:
- A script with a private helper `function init(){…}` or `function destroy(){…}` that it never exports gets it called by the engine. WE calls only exports.
- A name with no binding at all resolves to a global of that name, so any extension that defines a global `update`, `destroy` or `init` (or a sloppy script that leaked one, S3) is called as every other script's callback.
**Test.** A script with non-exported `function update(){ throw new Error('called') }` and `function destroy(){…}` → never called, no error. A global `globalThis.update = () => 7` defined before load → a script without `update` is not affected. Only names in the source's own export list get getters.

## S3. Sloppy-mode wrapper (Medium, WP3)
**Scenario.** ES modules are always strict; 9 corpus scripts lack `'use strict'` (`288db579f057`, `7d3bc214624c`, `a1b1d7b1a839`, `b960dd5aa8d4`, …). If the factory function is not strict:
- `counter = 0` without a declaration creates a **global** shared by every script in the scene (WE throws a ReferenceError at that line). Two scripts using the same undeclared name then step on each other, and the difference hides author bugs WE would surface.
- `this` at top level is `globalThis` instead of `undefined`; `arguments.callee`, `with`, octal literals and duplicate parameters are accepted.
**Test.** A script without `'use strict'` doing `x = 1` at global scope → ReferenceError on that line, instance disabled; `typeof this` at top level is `'undefined'`; two non-strict scripts with the same top-level `let` both run.

## S4. Line and column drift (High, WP3, WP2)
**Scenario.**
- The header is joined onto line 1 (plan §4.2), so errors on line 1 report a column shifted by the header's length.
- Blanked import lines must keep their newlines, including an import that spans lines.
- JS counts `\r\n`, lone `\r`, U+2028 and U+2029 as line terminators; a Swift tokenizer that counts only `\n` drifts after the first CR-only or U+2028 line.
- **Errors thrown by runtime or extension helpers carry the helper's line, not the script's.** Confirmed for WP2, see Findings SF1.
**Test.** Fixtures that throw on line 1 at column 5, on the line after a blanked two-line import, after a CR-only line and after a U+2028 inside a string, each reporting the original line (and column on line 1). `engine.registerAudioBuffers(16)` inside `update` on line 3 reports line 3.

## S5. Compile failures and language gaps (Medium, WP3, WP9)
**Scenario.**
- `8bb9b9a54120` (string broken across lines) must disable only that site, keep the authored value and log once with its line.
- The deployment target is macOS 13 (`OpenWallpaperEngine.xcodeproj`, `MACOSX_DEPLOYMENT_TARGET = 13.0`). WE runs V8, which has builtins that macOS 13's JSC lacks (`Object.groupBy`, `Array.prototype.toSorted`/`toReversed`/`with`, regex `v` flag, `Promise.withResolvers`, `ArrayBuffer.prototype.transfer`). A Workshop script that uses one works in WE and on macOS 15 but throws a TypeError on macOS 13 every frame. The corpus uses none, but CI and developers run the newest macOS, so no test would notice.
- HTML-like comments (`<!--`) and hashbangs are accepted by our classic-script wrapper but rejected by V8 modules (harmless leniency; note it).
**Test.** The WP9 corpus replay also runs on the oldest supported macOS once before a release; a synthetic script that calls `[].toSorted()` in `update` logs one error naming the script and line, and other scripts keep running.

## S6. Return-value coercion (Critical, WP8, WP11)
**Scenario.** P3: a number returned for a vector is broadcast (today it becomes `(n, 0, 0)`), a failed type check leaves the field unchanged, and **NaN passes the number check and is written**. What reaches Swift matters more than what reaches JS:
- `08861b7e67b4` with its `barAmount` slider at 100 reads `audioBuffer.average[64]` (past the 64-entry array) → `undefined * x` → NaN → `scale.y = NaN` on the last bar. `Infinity` comes from `1000 / (now - last)` when two frames share a millisecond (`155fe61a17a0` computes `fps` that way).
- Swift's `Int(Float.nan)` and `Int(Float.infinity)` **trap**. Any consumer that converts a scripted number to an integer (particle `rate`/`count` → emitted count, `maxrows`, `pointsize` → font size, `limitrows`, a texture-animation frame, an index) crashes the app. A NaN in a world matrix makes the layer vanish, and a NaN in `alpha` poisons blending.
- `1e39` is finite in JS but `+inf` after the Float32 table write.
- Text: `update` returning a number, `null`, `undefined`, an object or a Vec3. The text must never render `"undefined"`; what WE does with a number (convert or skip) must be decided from P3, not guessed per call site.
**Test.** A fuzz fixture per field type (number, bool, string, Vec2, Vec3, colour, text, `instanceoverride.*`, `general.*`) returning each of `NaN`, `±Infinity`, `-0`, `1e39`, `"1 2 3"`, `"abc"`, `null`, `{}`, `[]`, `true`, a Vec2 for a Vec3 field, then rendering 10 frames through the renderer: no trap, no NaN in any GPU uniform the renderer computes from the table except where P3 says WE writes it, and a clamp or skip at every `Int(...)` conversion.

## S7. Accumulators and aliasing of `value` (High, WP8)
**Scenario.** P2: `update(value)` receives the last applied value, so `value += frametime` accumulates.
- If WP8 hands the script the cached value object itself, a script that mutates it and forgets to `return` (`value.x += 1;`) moves the property in ours and not in WE, where `value` is a fresh copy.
- If `rt.apply` stores the returned object as is (`Resources/SceneScript/runtime.js:124-129` stores whatever `coerce` returns), a script that returns a module-level `Vec3` and keeps mutating it from a timer or cursor callback changes `record.value` between frames without any return.
- On an animated property (P2), the value must be this frame's animated value, so an accumulator on an animated property does not run away.
**Test.** `update(v){ v.x += 1 }` (no return) → unchanged after 10 frames. `const k = new Vec3(); update(){ k.x += 1; return k }` plus a timer that sets `k.x = 100` → the field shows only what `update` returned. `update(v){ return v + 1 }` on alpha → 0, 1, 2, … exactly. An accumulator on an animated field follows the animation plus one frame's increment.

## S8. Load order and script properties (High, WP4, WP8)
**Scenario.**
- `08861b7e67b4` reads `scriptProperties.barAmount` in `init` to decide how many bars to create; if `scriptproperties` are injected after `init` (or the user-bound `{user, value}` entries, 38 in the corpus, are unresolved at load), the wallpaper makes 32 bars instead of the user's count and never corrects it (init runs once).
- `105f9d26fe76` relies on `applyUserProperties` running after every `init` (P8).
- On a property change, the user-bound script properties must be re-injected **before** the same frame's `applyUserProperties(changed)` broadcast, or scripts see the old value for a frame (or forever, if they latch).
- `load()` is re-callable for scripts added later; runtime-added scripts then receive `applyUserProperties(all)`, which P8's best guess says WE never sends. See Findings SF5.
- `engine.userProperties` colours must be `Vec3` through `_Internal.convertUserProperties`, the same object the first `applyUserProperties` gets.
**Test.** A fixture whose `init` creates `scriptProperties.n` layers with a user-bound `n` → the user's value; changing the user property → `applyUserProperties({n})` sees the new `scriptProperties.n`. The call log of a three-script scene matches P8 exactly: bodies, injection, `init`+media per script, then all `applyUserProperties`, then all `applyGeneralSettings`.

## S9. Timers (High, WP4)
**Scenario.** Corpus pattern (`23ea5c1b7601`, `1553916bf67e`): `lastHideEvent = engine.setTimeout(() => { thisObject.visible = false }, 1000)`, and on the next media event `lastHideEvent()` to cancel.
- Cancelling a timeout that **already fired** must be a no-op. With numeric ids reused from a free list, it cancels someone else's timer.
- A timer created inside a timer callback must not fire in the same pass (P1: per script over a snapshot); an interval whose period is shorter than the frame fires once per frame (reset, not catch-up); `setTimeout(cb, 0)` fires next frame.
- `ms` of `NaN`, negative, `undefined`, a string; `cb` not a function (a string of code must not be `eval`ed).
- Clock: timers must run on scene time, so pausing the wallpaper (`playRate 0`), sleep/wake and speed changes do not fire a burst of intervals on resume; `engine.runtime` and the timer clock must agree.
- A timer whose script was removed (`destroyLayer`, reconfigure) must never fire into a destroyed object.
- Global-scope `setTimeout` throws WE's message; a timer callback that throws is logged but not disabled.
**Test.** The `lastHideEvent` pattern with a cancel after the fire, then a second timer created: the second still fires. A 1 ms interval over 10 frames of 16 ms → 10 calls. Pause for 60 s and resume → no burst. Remove a script with a pending timeout → nothing fires, no error.

## S10. Teardown (High, WP2, WP4, WP6, WP11)
**Scenario.**
- `destroy()` may write `localStorage`, start a timer, stop a sound or push commands. `SceneScriptRuntime.tearDown()` runs `__rt.teardown` and never drains the command ring or tells extensions (Findings SF4), so storage written in `destroy()` is lost if WP4 batches writes, WP4 cannot clear timers, WP6 cannot unsubscribe from the media source, and WP5 cannot release its capture client.
- `deinit` calls `tearDown()`, so script `destroy()` callbacks run on whatever thread drops the last reference to the runtime (a view model released on a background task), breaking render-thread confinement.
- A watchdog stop inside `destroy()` during teardown must not block the next wallpaper's load.
**Test.** A script whose `destroy()` does `localStorage.set('k', 1)`: after teardown and a new runtime, `get('k')` is 1. A pending interval at teardown never fires afterwards (poll 2 s). A fake media source sees one unsubscribe per runtime. Release the last reference on a background queue → `destroy()` still runs on the render thread, or not at all, by design.

## S11. Reentrancy (High, WP2, WP7, WP11)
**Scenario.** Scripts change structure from inside callbacks:
- `destroyLayer(x)` in `update` or in a cursor callback of `x` itself; then writes to `thisLayer` after its own destroy.
- `destroy()` of one script removes another script: in WP2's `destroyPending` the second one is dropped without its `destroy()` and stays in `byId` (confirmed, Findings SF2).
- `createLayer` with a scripted config inside `update` adds records while `rt.frame` iterates `rt.records` (the loop reads `records.length` live, so a new record is visited in the same frame; it is skipped only because its state is `DEFINED`).
- A command handler that calls back into JS (for example `createLayer` running the new layer's module body) pushes into the ring while `SceneScriptCommandRing.drain()` executes it; `drain` ends with `resetRing`, which drops those commands.
- Slot reuse: a stale `ILayer` kept after `destroyLayer` writes into a slot that now belongs to a new layer (ABA).
**Test.** Create and destroy 1000 layers over 1000 frames with memory flat (the WP11 clone stress test). A stale handle write after its slot is reused changes nothing. `destroy()` that removes another script → both `destroy()`s run and both ids are gone. A handler that pushes a command during `drain` → the command runs this frame or the next, never lost.
**Status.** SF2 fixed in `16f9469`; stale handles in WP7. A command pushed during `drain` now runs in the same drain, bounded by the ring's capacity (`SceneScriptRuntimeReachTests`). The clone stress test is WP11's.

## S12. `createLayer` from assets (High, WP7, WP11)
**Scenario.**
- `08861b7e67b4` and `4919ac5f12ef` call `thisScene.createLayer('models/bar.json')` up to 99 times in `init`, and immediately write `alignment`, `color`, `alpha`, `parallaxDepth` and call `sortLayer(bar, thisIndex)`. The returned object must exist synchronously with a slot, and every write before the native layer materialises must land on it.
- `f6acb397ce16` creates 63 bars from `models/workshop/2079954552/bar.json`, another Workshop item's asset. When that dependency is missing, `createLayer` returning `null` makes `newBar.parallaxDepth` throw in `init`, which disables `init` (P4) with half the bars made. What WE returns for a missing asset must be settled, and the loader must not crash on it.
- `585203d7f809` clones through `createLayer(thisScene.getInitialLayerConfig(origbar))` inside a `try` and treats any throw as "no bars".
- Loading textures and models synchronously inside the JS entry stalls the frame (and counts toward the watchdog, S19). Loading them asynchronously means the first frames draw nothing for those layers.
- The object table has a fixed capacity (`Objects/SceneScriptObjectTable.swift:39-45`; "a larger table is a new buffer"). Growing it replaces the `Float32Array`; any JS layer object that captured the old array keeps writing into a dead buffer.
**Test.** 99 bars in `init` → 99 slots with independent origins and the draw order WE gives repeated `sortLayer(bar, i)` at the same index. A missing asset path → the documented result, one log line, no crash. Grow past capacity mid-scene → earlier layer objects still move their layers.

## S13. `sortLayer` and command timing (Medium, WP7, WP11)
**Scenario.**
- `sortLayer` from `update` must reorder before this frame's draw (plan: "in the same frame"); `getLayerIndex` right after `sortLayer` in the same callback must agree with WE (immediate or deferred; unknown, decide).
- Indices count what: drawables only, or also sound and hidden objects? `getLayerIndex(thisLayer)` followed by `sortLayer(bar, thisIndex)` gives different results for each choice.
- Commands pushed during `load` (module bodies and `init`: `createLayer`, `sortLayer`, `play`, `setFrame`) are not drained until after the first frame's updates (Findings SF5).
- The ring holds 4096 commands per frame; a script calling `emitParticles` or `setMaterialProperty` per bar per frame overflows it and later commands are dropped silently after one log line.
**Test.** `sortLayer` in `update` → the rendered order changes in the same frame (render test). `getLayerIndex` after `sortLayer` matches the chosen rule. A `play()` in `init` takes effect before the first rendered frame.

## S14. Vector aliasing (High, WP7, WP6)
**Scenario.** `08861b7e67b4.update` assigns **one** `Vec3` to every bar and mutates it between assignments: `scale.y = …; bar.scale = scale;` then the next bar. `bar.color = baseColor` shares one object across all bars. `baseOrigin = thisLayer.origin` is kept across frames.
- A setter that stores the reference (the plan keeps strings and rare fields on the JS object) makes every bar end up with the last bar's value.
- A getter that returns the cached object lets `baseOrigin` follow the layer, and makes `thisLayer.scale.x = 2` take effect (4 corpus scripts commented that out because it doesn't in WE).
- Event objects: `shared.accentColor = event.primaryColor` (corpus) keeps a thumbnail colour. If WP6 pools or reuses event objects to save allocations, the stored colour changes on the next event. `rt.broadcast` passes the same argument array to every script (`runtime.js:302-308`), so one script that mutates the event (or the `resizeScreen` Vec2, or the `applyUserProperties` object) changes what the next script receives.
**Test.** The bar loop above → each bar keeps its own scale. `const o = thisLayer.origin; thisLayer.origin = new Vec3(5)` → `o` unchanged. Two scripts on `mediaThumbnailChanged`, the first does `e.primaryColor.x = 0` → decide and pin whether the second sees it (WE likely builds the event per call).

## S15. Vec math interop and units (Medium, WP7, WP8)
**Scenario.**
- WE's quirks must survive: `new Vec4(x, y, z)` sets `w = z`, `Vec2.perpendicular()` is `(y, -x)`, `equals` uses an epsilon, `new Vec3(n)` broadcasts (`08861b7e67b4`: `new Vec3(0 + barWidth)`). Only loading `baseclasses.js` unmodified guarantees that; any shim that redefines them (the old one did) breaks it.
- Coercion must accept WE Vec objects, plain `{x, y, z}`, and `"x y z"` strings, and read `x/y/z` through getters too.
- Angles are degrees at the API and radians in a Float32 table: `thisLayer.angles = new Vec3(0, 0, 90)` then `thisLayer.angles.z === 90` is false after the Float32 radians round trip (89.99999…). Scripts that compare or accumulate (`angles.z += 1` for hours) drift. The same holds for origin `0.1` → `0.10000000149`.
**Test.** Set angles 90 and read back exactly 90 (store degrees, or round-trip within 1e-4 and document it). 100 000 frames of `angles.z += 0.36` → 36 000 within 0.01. `Vec4(1, 2, 3).w === 3`.

## S16. Audio buffers (High, WP5)
**Scenario.**
- **Smoothing advance.** `AudioSpectrumAnalyzer.advanceFrame()` moves the smoothing one step and must be called "exactly once per frame" (`Audio/AudioSpectrum.swift:90-91`). Every `SceneMetalRenderer` already calls it (`Scene/Rendering/SceneMetalRenderer.swift:449`), so two displays advance it twice per frame, and a WP5 extension that also calls it makes three: faster decay, and different values per display. WP5 must read `snapshot`, and the analyzer should advance once per display-link tick, not per renderer.
- **Sharing between scripts.** One `SceneScriptSharedBuffer` per resolution shared by every script (plan §5 WP5) means a script that normalizes in place (`buf.average[i] *= gain`) changes every other script's input for the rest of the frame. None of the corpus scripts write into the arrays, but Workshop scripts that do exist in the wider Workshop.
- **Races.** Filling the typed arrays from the capture thread (tempting for "live") gives torn reads mid-`update`; filling only in `willRunFrame` from `snapshot` under the analyzer's lock does not.
- **Stereo.** `left ≠ right` needs real stereo capture; a mono source copied to both sides passes every test that only checks shape.
- Out-of-range reads (`average[64]`) are `undefined` in WE too; they feed S6.
- Two `registerAudioBuffers(16)` calls in one scene must both work; `registerAudioBuffers(128)` throws WE's message; a call from a callback throws.
**Test.** Two runtimes rendering the same tone for 60 frames → identical values and the same decay as one runtime. Script A writes `average[0] = 99` and script B reads it in the same frame → B sees the captured value (per-script arrays, or copies refreshed per call). A left-only tone → `right` stays near zero.

## S17. Detached shared buffers (Critical, WP2, WP5)
**Scenario.** `SceneScriptSharedBuffer` gives JavaScriptCore ownership of Swift's allocation (`JSObjectMakeTypedArrayWithBytesNoCopy` with a deallocator that frees it) and keeps the typed array alive, assuming that keeps the memory alive (`Runtime/SceneScriptSharedBuffer.swift:7-9`, `:20`). A script that calls `audio.left.buffer.transfer()` (available in JSC from macOS 14.4) detaches the original: the new `ArrayBuffer` takes the bytes, and when it is collected JSC calls the deallocator while `pointer` is still used by Swift. Every later `willRunFrame` write is a heap write after free. Confirmed, see Findings SF3. Audio buffers are handed to scripts by design (WP5); the object table and command ring are reachable through `__rt` (S28).
**Test.** The probe in SF3 as a unit test: transfer a shared buffer's `ArrayBuffer`, drop it, force GC, then write through `pointer` under Address Sanitizer → no report.
**Status.** Fixed (SF3, SF9); `SceneScriptObjectHardeningTests`.

## S18. Media sources (High, WP6)
**Scenario.**
- MediaRemote is restricted for third-party bundles since macOS 15.4. The adapter (`/usr/bin/perl` or a helper) can disappear in any OS update, hang, or return garbage. Failure must mean `mediaStatusChanged({enabled: false})` once, not a crash, a hang on the render thread, or a permission prompt.
- The artwork palette (k-means or median cut) on a 1000×1000 image costs tens of ms; computed on the render thread it drops frames on every track change. It must run off-thread and post the event.
- Timeline events arrive several times a second from some players; while the wallpaper is paused they pile up in the inbox (S20).
- P8: each script gets the current media state right after its `init`, including scripts added later; before the first real event the state must be "no media", with WE's field names and `MediaPlaybackEvent` constants.
- No AppleScript and no Automation prompts anywhere (the old `BrowserMediaIntegration` polled eight browsers every 2 s).
**Test.** A fake source that fails to start, hangs for 5 s on the first query, and flips availability: the first frame is not delayed, `enabled` goes false then true, no crash. Palette time on a 4K PNG measured off the main thread. `grep -r NSAppleScript` in `Scene/Scripting` is empty.

## S19. Watchdog on the main thread (High, WP2, WP11)
**Scenario.** The renderer draws from `MTKView` with `isPaused = false` and `enableSetNeedsDisplay = false` (`Scene/Rendering/SceneMetalRenderer.swift:213-214`), i.e. on the main thread. The watchdog allows 15 s per native→JS entry (`Runtime/SceneScriptRuntime.swift:16-21`), so one `while (true) {}` in any script freezes the whole app (menu bar, settings, every other display) for 15 s. WE runs scripts in the wallpaper process, so its 15 s hang does not freeze its UI.
- After the stop, the runtime is halted for good (P5): the wallpaper keeps rendering with frozen values and the only sign is one log line. The user needs a visible state or a reload.
- The limit covers the whole frame (all 71 scripts of 3453730450 plus events and timers), not each outermost call like WE's; a legitimately slow load (99 `createLayer`s with synchronous asset loads, S12) shares one 15 s budget.
- Measured on this Mac: the watchdog stops a catastrophic regex (`/^(a+)+$/` on 28 characters) but overshoots a 0.5 s limit to 1.17 s.
**Status.** The mechanism is in (`16f9469`): `SceneScriptThread` runs a runtime on its own queue and `asyncFrame` skips frames while one is in flight (`testAHungScriptOnItsThreadLeavesTheMainThreadFree`); WP11 must create every runtime on one. The whole-frame budget and the halted-state UI remain open.
**Test.** A scene with a `while(true)` in `update` of a script on display A: the main run loop stays responsive enough to open Settings (or document that it does not, and pick a shorter per-frame limit than WE's), display B keeps rendering after A's stop, one "dead lock" line names the script, and the wallpaper shows the halted state. Termination inside `load`, `frame` and `tearDown` each leave the runtime `halted` and the next wallpaper loadable.

## S20. Inbox overflow (Medium, WP2, WP6, WP10)
**Scenario.** `SceneScriptInbox.post` drops the **oldest** events past 1024 (`Runtime/SceneScriptInbox.swift:14-16`). When frames stop (`metalView.isPaused` when `playRate == 0`, `Scene/Loading/SceneWallpaperView.swift:144`; occluded windows; a sleeping display), cursor moves (WP10) and media timeline events (WP6) keep arriving. A user-property change made in the sidebar while paused is then pushed out by mouse movement, and scripts never receive that `applyUserProperties`, a permanent desync. Confirmed by reading, Findings SF4.
**Status.** Fixed with SF4/SF15; WP10 posts clicks as `.keep`.
**Test.** Pause, change a user property, post 2000 cursor moves, resume → the script receives the property change. Cursor moves should be coalesced (keep the latest), and state events (properties, settings, media status, playback) never dropped.

## S21. `localStorage` (Medium, WP4)
**Scenario.**
- Cap: 100 KB per wallpaper (docs). A script that appends to a stored array every frame hits it in minutes; `set` beyond the cap must fail the way WE does (throw or return false), not grow the file or crash.
- Write amplification: a `set` every frame must not become a file write every frame on the (external) disk; batch and flush, and flush at teardown (S10).
- Corruption: a crash mid-write leaves a truncated file. Write atomically (temp file and rename); an unparsable file reads as empty and logs once, and must not throw on every `get`.
- Values: `Vec3` through `_Internal.stringifyConfig`; cyclic objects and functions (`JSON.stringify` throws) must throw into the script, not crash native code; NaN becomes null.
- Keys that are not strings throw WE's "key not a string"; calls at global scope throw.
- Scope: `'screen'` is keyed by display id. `CGDirectDisplayID` can change after a reconnect or reboot, and then per-screen data vanishes. Two runtimes of the same wallpaper on two displays share `'global'`; if each caches the file, the last writer wins and clobbers the other's keys.
**Test.** Two runtimes write different `'global'` keys → both survive a reload. Truncate the file → next load logs once and starts empty. `set` past 100 KB → WE's behaviour. A `Vec3` round-trips as a `Vec3`.

## S22. Two displays share nothing (High, WP11, all)
**Scenario.** Two instances of the same wallpaper must not share `shared`, module-level variables, timers, audio smoothing (S16), storage caches beyond `'global'` (S21), command handlers or statics in Swift. The old singleton `AudioReactiveScriptEngine.shared` keeps clobbering until WP11 removes it; any extension that keeps a `static var` cache (opcode handlers, compiled-module cache keyed by source, palette cache keyed by track) reintroduces the problem.
**Test.** Two runtimes of one scene with a counter in `shared` and in a module-level `let`; run A for 10 frames and B for 3 → 10 and 3. Tear down A → B keeps running with its timers. `grep -n "static var" Scene/Scripting` reviewed per package.

## S23. Swift↔JS retain cycles (High, all)
**Scenario.** A `@convention(block)` native installed on `rt.native` that captures the runtime or the extension strongly makes JSContext → block → runtime → JSContext: the VM is never freed. `SceneScriptCommandRing.register` stores escaping handlers (`Objects/SceneScriptCommandRing.swift:62-65`); WP7's handlers will naturally capture the runtime or the renderer, making runtime → ring → handler → runtime. A `JSValue` stored in a Swift object that JS can reach retains the context strongly (use `JSManagedValue`). Every wallpaper switch then leaks one VM, its JS heap, the object table, the ring and the audio buffers.
**Test.** Create a runtime with every extension, load a corpus scene, run 10 frames, tear down, and assert a `weak` reference to the runtime and to each extension is nil. Repeat 100 times with resident memory flat.

## S24. Per-frame cost and replay determinism (Medium, WP9, all)
**Scenario.** Target: < 0.5 ms per frame for 3453730450 (71 sites), about 1–5 µs per script.
- Swift→JS bridging per frame: `inbox.drain().map { $0.javaScriptObject }` converts Swift dictionaries each frame (cursor moves at 120 Hz), `rt.frame` gets a bridged array, `drainErrors` uses `toArray`, ring strings use `toArray`. Each is small but all run every frame.
- JS allocation: a `Vec3` per getter and per argument (like WE), event objects, closures. Eden GCs every few seconds with 1–3 ms pauses show up as p99 spikes, not in averages.
- Determinism: 62 corpus scripts use `Date` and 7 use `Math.random`. A replay harness with a fake clock must also stub `Date` and seed `Math.random`, or assertion (e) on clocks is flaky and frame-time baselines vary.
**Test.** `measure` p50 and p99 over 3600 frames of 3453730450 with a tone: p50 < 0.5 ms, p99 < 1 ms. Zero Swift→JS object creations in a frame with no events. The clock fixtures run at a fixed `Date`.

## S25. Scripts on effects and materials (High, WP7, WP8)
**Scenario.** 46 `effects[i].visible` sites (`thisObject.visible = event.hasThumbnail` 44 times) and 86 effect-constant sites. `thisObject` must be the `IEffect` or the `IMaterial` (constants by name, `thisObject.multiply`), and `thisObject.getAnimation()` must be the property's own timeline (2134765860's `multiply` with `startpaused`).
- Effects hidden at load are not built today (plan §3.3 item 11); a media event can then never show them.
- A material constant whose name collides with a member (`name`, `visible`, `getAnimation`) or with `Object.prototype` (`constructor`, `toString`, `__proto__`) shadows or breaks the object if members are defined per name on the object.
- Two effects with the same name: `getEffect(name)` returns which one?
- `setMaterialProperty` must reach every material of the effect with that constant, and nothing else.
**Test.** An effect hidden at load, shown by a `mediaThumbnailChanged` with `hasThumbnail: true`, draws. A material with a constant named `constructor` still exposes `getAnimation`. `thisObject` for an effect-constant script is the material, not the layer.

## S26. Hidden layers (Medium, WP8, WP10, WP11)
**Scenario.** P6: `update` runs on hidden layers; `03f0db0a6dff` hides its own layer in `init`. The old code drops objects hidden at load and runs visible scripts once. Also:
- a layer hidden by its parent: its scripts still run;
- cursor events on a hidden (or alpha 0) Solid layer: WE's hit test presumably skips invisible objects; ours must decide the same way;
- the renderer must skip drawing hidden layers without skipping their transform pass, or `getTransformMatrix` and hit tests read stale matrices.
**Test.** A layer hidden in `init` whose `update` shows it after 30 frames appears on frame 31. A click on a hidden Solid layer → no cursor callback.

## S27. Cursor hit testing (Medium, WP10)
**Scenario.** Three coordinate spaces meet: AppKit points (bottom-left origin), display pixels (Retina 2×, a second display at 1×), and scene space after `.cover`/`.center` fitting, camera parallax and camera shake. A hit test in points on a 2× display misses by half; one that ignores the parallax offset misses whenever the mouse is off-centre. Also:
- `cursorClick` requires down and up on the same object;
- a layer destroyed while hovered must not get `cursorLeave` afterwards;
- `openUserShortcut` only once per click;
- clicks that land on desktop icons or other apps' windows must not reach scripts (the old code counted any click via `NSEvent.pressedMouseButtons`).
**Test.** Rotated, scaled and parented Solid layers on a 2× and a 1× display, with parallax on: clicks at the layer's corners hit, 1 px outside miss. Down on A and up on B → no click. Moving across two overlapping Solid layers gives enter/leave pairs for the top one only.

## S28. Untrusted scripts reach the runtime (Medium, WP2, WP7)
**Scenario.** `__rt` is a non-writable global, but its members are writable and reachable from every script. A Workshop script can replace `__rt.hooks.coerce`, clear `__rt.records`, set `__rt.halted`, or push arbitrary opcodes and targets through `__rt.push` or directly into `__rt.ring.records`. The ring bounds-checks number ranges (`Objects/SceneScriptCommandRing.swift:95-96`), but each handler must also bounds-check `target` against the object table. Combined with S17, the shared buffers are the only path from script to memory corruption.
**Test.** A script that pushes opcode 400 with target `2^31-1`, negative targets and garbage counts → no crash, one log line. Handlers get `target` already validated or validate it themselves.
**Status.** Fixed. The memory-safety half with SF3 and SF10 (shared memory can't be freed, command numbers are validated). `__rt` is hidden from scripts (the module scope shadows it; the global reads `undefined` during every native entry and all script code, so a replaced builtin called by runtime code can't leak it) and sealed after installation (frozen hooks, read-only functions); `SceneScriptRuntimeReachTests`.

---

## Findings (SceneScript)

Line numbers are at `94a9e6e` unless a commit is named. Each probe ran against the real `runtime.js` and the system JavaScriptCore on the development Mac.

### WP2: `3387d82` (per-instance runtime skeleton)

**SF1. Errors thrown by runtime helpers report the helper's line as the script's. Medium (S4).** **Fixed** in `16f9469`: lines come from the first stack frame in the script's `sourceURL`.
- `describe` takes `error.line` from the error object (`Resources/SceneScript/runtime.js:55-65`), and `drainErrors` reports it as the script's line (`Runtime/SceneScriptRuntime.swift:256-259`). JavaScriptCore sets `line` where the `Error` was **constructed**, so every error built in `runtime.js` or an extension's JS carries that file's line.
- Probe: a script whose line 3 calls `__rt.requireGlobalScope('registerAudioBuffers')` from `update` → reported `line: 135, column: 51` (the `throw` in `runtime.js:135`). This will hit every WE-message error of WP4/WP5 (`setTimeout cannot be called from global scope.`, `Resolution must be either 16, 32 or 64.`, `key not a string`).
- **Fix direction:** take the line and column from the first `error.stack` frame whose URL is the script's `sourceURL` (`owe://script/…`), or `-1` when there is none.

**SF2. `destroy()` that removes another script loses that script's `destroy()` and leaves it in `byId`. Medium (S11).** **Fixed** in `16f9469`: `__rt.destroyPending` repeats until nothing is pending.
- `destroyPending` walks `records` once, then filters on `pendingDestroy` (`runtime.js:343-354`). A record marked during another record's `destroy()` and positioned **before** it is filtered out of `records` without its `destroy()` and without `byId.delete`.
- Probe: records `c`, `b`; `b.destroy()` calls `__rt.remove('c')`; after the frame `c`'s `destroy` never ran, `records` no longer has `c`, `byId.has('c')` is true (so `isEnabled('c')` stays true and a new script with id `c` throws "Duplicate script id").
- **Fix direction:** loop until no record is pending (or collect, destroy, and repeat), and delete from `byId` in the same pass that filters.

**SF3. A script can free Swift's shared memory by detaching a typed array. Critical (S17).** **Fixed** in `0338833` and `16f9469`: memory reference counted with the deallocator, buffers pinned (JSC copies a pinned buffer on `transfer()`), and the runtime halts if a watched buffer is detached anyway.
- `SceneScriptSharedBuffer` passes a deallocator that frees the allocation (`Runtime/SceneScriptSharedBuffer.swift:20`) and relies on holding the typed array to keep it alive (`:7-9`). `ArrayBuffer.prototype.transfer` exists in this JSC (`typeof … === 'function'`).
- Probe (a Swift JSC program mirroring `SceneScriptSharedBuffer`): after `left.buffer.transfer()`, Swift's writes are visible through the new buffer; once it is dropped and GC runs, **the deallocator is called while Swift still holds `pointer`**. Every later write from `willRunFrame` or the command ring is a use after free.
- Reachable today through `__rt.ring.header/records/args` (command ring), and after WP5 and WP7 through the audio buffers and `__rt.table.values`.
- **Fix direction:** Swift owns the memory (no-op deallocator, freed in `deinit` after the context is gone), and `runtime.js` deletes `ArrayBuffer.prototype.transfer` and `transferToFixedLength` before any script runs; add the probe as a test.

**SF4. The inbox drops the oldest events, including property changes, and teardown has no extension hook. Medium (S10, S20).** **Fixed** in `16f9469`: a full inbox coalesces by `SceneScriptEvent.Coalescing`; extensions get `tearDown(_:)`; `deinit` tears down on the runtime's thread.
- `SceneScriptInbox.post` removes the oldest events past 1024 regardless of kind (`Runtime/SceneScriptInbox.swift:14-16`). Once WP10 posts cursor moves, a paused wallpaper loses the user's property changes.
- `SceneScriptRuntimeExtension` has `install`, `willRunFrame` and `didRunFrame` only (`Runtime/SceneScriptRuntimeExtension.swift:12-25`), and `tearDown` neither drains the ring nor notifies extensions (`Runtime/SceneScriptRuntime.swift:168-177`). WP4 (storage flush, timers), WP5 and WP6 (unsubscribe) have nowhere to clean up; commands pushed in `destroy()` are never executed. `deinit` runs `tearDown` (`:124-126`), so `destroy()` callbacks run on the releasing thread.
- **Fix direction:** coalesce cursor moves and never drop state events; add `willTearDown(_:)` (called after `__rt.teardown`, then drain the ring) to the extension protocol.

**SF5. `load()` differs from P8 for scripts added later, and doesn't drain the ring. Low (S8, S13).** **Fixed** in `16f9469`: later loads skip `applyUserProperties` and `load` drains the ring.
- A second `load` sends `applyUserProperties(userProperties)` to the new records (`runtime.js:258-264`). P8's best guess is that runtime-created scripts get none; if WP11 calls `load()` with the default `[:]`, they get `{}`, and a script that reads `changed.x` without `hasOwnProperty` gets `undefined`.
- `load()` does not call `commandRing.drain()` (`Runtime/SceneScriptRuntime.swift:144-151`), so `createLayer`, `sortLayer` and `play` from module bodies and `init` run only after the first frame's updates.
- **Fix direction:** skip `applyUserProperties` for records defined after the first load (or document the choice), and drain after `load`.

Probes were small `swiftc` programs outside the repo: SF1 and SF2 evaluate the repo's `runtime.js` in a plain `JSContext` and drive `define`/`load`/`remove`/`frame`; SF3 builds a typed array exactly as `SceneScriptSharedBuffer.init` does; S19's regex timing sets `JSContextGroupSetExecutionTimeLimit` to 0.5 s as `SceneScriptWatchdog` does.

### WP3: `4d5410d`, `70c7a98`, `284ec4a` (tokenizer and module compiler)

Ran 33 adversarial snippets through `SceneScriptModuleTransformer` and JavaScriptCore (a `swiftc` build of `Scene/Scripting/Modules/*.swift`). All behave like a V8 module:
- S1: division vs regex (`a / b / c`, `a /2/ c`, after `)`/`return`/a block/an `if (x)`, `/[/]/`), templates with `}` and nested templates, `export`/`import` in strings, comments and as property names, `export` on its own line, multi-declarator and destructuring exports, CJK identifiers, HTML comments, hashbangs.
- S2: only exported names get getters; a non-exported `function update(){ throw … }` is invisible.
- S3: the factory is strict; `counter = 0` throws a ReferenceError on line 1, top-level `this` is `undefined`, a top-level `return` is a compile error.
- S4: CRLF, CR-only and U+2028 sources report the original line; line 1 columns are shifted by the header, as documented.
- ASI hazards (`export let a = 1` followed by a `(` line) fail the same way V8 does.

**No confirmed issues.** SF1 still applies: errors built inside runtime or extension JS carry that file's line.

### WP4: `c75f615`, `7eb0126`, `140b510`, `73d3b6d` (engine, input, console, timers, localStorage)

**What the commits already cover.** S9: a cancel after the timer fired is a no-op (the timer object, not an id, is cancelled); timers added while timers run wait for the next frame; an interval resets to its period, so a resume after a pause fires it once; NaN, negative and missing delays fire next frame; timers die with their record. S10/S21: writes flush at most once per second of scene time and when the extension is released (after `destroy()` ran), and atomically; an unreadable file starts empty with one log line; one `SceneScriptStorage` serves every runtime, so two screens don't clobber `'global'`. S14: each `applyUserProperties` call gets its own converted object. S23: the native blocks capture `self` weakly.

**SF6. `localStorage` keys are not counted against the 100 KB cap. Low.** `setValue` sizes an entry as `8 + value.utf8.count` (`Scene/Scripting/Engine/SceneScriptStorage.swift:54`, `:158-159`); the key is free. A script that uses data as keys (`localStorage.set(JSON.stringify(state), 1)` with a new state each frame) grows the file and the in-memory store without bound. Whether wallpaper64.exe counts keys should be checked at the same address as the value size; if it doesn't, cap the key length or the entry count anyway, because the file is ours. **Fixed** in `0972d84`: keys count toward the cap.
- **Test:** 10 000 `set`s of distinct 1 KB keys → refused past the cap (or the documented WE behaviour), file size bounded.

**SF7. Writes of the last second are lost when the app quits. Low.** Flushing happens in `didRunFrame` once a second (`Engine/SceneScriptEngineExtension.swift:99-101`) and in `deinit` (`:69`, `SceneScriptStorage.swift:40`). Nothing calls `SceneScriptStorage.flush()` from `applicationWillTerminate` (`App/SafeRestart.swift:80` is the existing hook), and runtimes are not released on quit. A counter a script stores on every click loses up to one second of clicks. **Fixed** in `0972d84`: the storage flushes itself on `NSApplication.willTerminateNotification`.
- **Fix direction:** WP11 flushes the shared storage from `applicationWillTerminate` (and on sleep).

**SF8. `engine.runtime` is a Float32 and steps by more than a frame after 1.5 days. Low (verify against WE).** `frame[Slot.runtime] = Float(runtimeSeconds)` (`Engine/SceneScriptEngineExtension.swift:112`). Float32 spacing is 1/64 s at 2^17 s (36 h) and 1/32 s at 3 days, so `Math.sin(engine.runtime * k)` animations stutter on a wallpaper left running (the normal case). The commit says WE's is a float too; if that is right the behaviour is faithful, otherwise keep a Double (a getter over a `Float64Array` costs the same). **Fixed** in `5c883fe`: `engine.runtime` reads a `Float64Array`.

### WP5: `5db500f` (WE's spectrum pipeline), `18e3bfb` (registerAudioBuffers)

**What the commits already cover.** S16: the smoothing is now timed by `deltaTime` from the monotonic clock (`Audio/AudioSpectrum.swift:89-99`), so the extra `advanceFrame()` from a second display's renderer adds one 0.1 ms step instead of a whole frame; the extension only reads the snapshot. The arrays are filled on the runtime's thread before the frame (no torn reads), left/right/average are separate, 128 and non-global calls throw WE's messages.

**SF9. Every script's audio arrays are views into one store per resolution, so SF3 is now reachable from any audio script, and one script's writes reach the others. High.**
- `registerAudioBuffers` returns `store.subarray(...)` of the one shared `Float32Array` (`Scene/Scripting/Audio/sceneScriptAudioBuffers.js:15-19`). `audio.left.buffer` is that store's `ArrayBuffer`: `audio.left.buffer.transfer()` in any script detaches it for **every** script (all arrays become length 0, so every read is `undefined` and every bar goes NaN, S6) and, once collected, frees the memory `willRunFrame` keeps writing (SF3).
- A script that normalizes in place (`buf.average[i] /= max`) changes what every later script sees in the same frame. The commit cites WE's DLL tick "copying" the host arrays at `0x18164f84d`; if that copy targets per-registration arrays, WE isolates scripts and ours doesn't.
- **Fix direction:** fix SF3 first; then give each registration its own arrays refreshed in `willRunFrame` (or pin, from the DLL, that WE shares them).
- **Test:** script A writes `average[0] = 99` in `update`, script B later in the same frame reads the spectrum value; script A calls `left.buffer.transfer()` and script B still reads 16 finite values.

### WP7: `7d767aa`, `d66d6c8`, `c16472e` (object model)

**What the commits already cover.** S14: numeric setters copy into the table at once and getters return fresh `Vec`s, so `08861b7e67b4`'s one shared `scale` gives every bar its own value; strings are copied with `String()`. S11/S12: `createLayer` places the layer synchronously (a live slot the script can write before the `.create` command), a missing asset returns `null` with one log line, the table has a fixed capacity (2048 objects) instead of growing, and a destroyed layer is detached onto a private snapshot so a stale handle never writes a reused slot. S6/P3: `convert` writes NaN like WE and rejects non-numeric components and strings. `sortLayer` clamps its index and rejects NaN. Native blocks and ring handlers capture `self` weakly (S23).

**SF10. A script can crash the app with a non-finite number in a command. Critical (S6, S28).** **Fixed** in `d7c3021`: `SceneScriptNumber` for every script Float→Int conversion (also the legacy engine's audio lookups); `emitParticles` floors and clamps.
- `decode` converts ring floats with `Int(...)` (`Scene/Scripting/Objects/SceneScriptObjectModel.swift:188`, `:196-197`, `:201`, `:208`). `Int(Float)` traps on NaN, ±Infinity and values past `Int.max` ("Float value cannot be converted to Int because it is either infinite or NaN"; checked with `swiftc`).
- Reachable without any adversarial intent: `ParticleSystem.emitParticles(count)` forwards any number (`Resources/SceneScript/objects-layers.js:223-226`), so `emitParticles(audio.average[64] * 10)` (NaN, the out-of-range read of S6) or `emitParticles(1e39)` (Infinity after the Float32 ring) kills the process. The other opcodes take internal indices, but any script can push them through `__rt.push` with NaN (S28).
- **Fix direction:** decode with `Int(exactly:)` after an `isFinite` check (or clamp), and drop the command otherwise; `emitParticles` should also floor and clamp to a sane maximum in JS.
- **Test:** `emitParticles(NaN)`, `emitParticles(Infinity)`, `emitParticles(1e30)`, and `__rt.push(opcode, slot, [NaN, NaN, 1], ['x'])` for every object opcode → no trap, one log line each.

**SF11. `destroy()` runs after its layer was detached. Low.** The deferred handler detaches the layer and removes it from `order` before the runtime calls the scripts' `destroy()` (`Resources/SceneScript/objects-scene.js:230-234`, then `runtime.js` `destroyPending`). The d.ts says `destroy` runs "just before the object is destroyed": in ours, `destroy()` writes to `thisLayer` are ignored and `thisScene.getLayer(thisLayer.name)` returns `null`. **Fixed** in `39ceef8`: the scripts' `destroy()` runs before the layer is detached.
- **Fix direction:** mark the layer's scripts, run their `destroy()` inside the deferred step, then detach.

**SF12. JS-side script removal leaves the id in Swift's `instanceIDs`. Low.** `destroyLayer` removes the layer's scripts with `rt.remove(record.id)` in JS (`objects-scene.js:231`); `SceneScriptRuntime.instanceIDs` only shrinks in the Swift `remove(scriptID:)` (`Runtime/SceneScriptRuntime.swift:180-184`). If WP8/WP11 give a re-created layer's scripts the same ids (object id plus field), `add` refuses them as "duplicate script id". **Fixed** in `16f9469`: removed ids come back through `__rt.removed`.
- **Fix direction:** `destroyPending` reports removed ids back (the frame's return value or a drained list), or WP8 never reuses ids.

**SF13. Angles read back in double precision are not the degrees written. Low (S15).** `read('degrees')` multiplies the Float32 radians by a double constant (`Resources/SceneScript/objects-values.js:89`): `angles = Vec3(0, 0, 90)` reads back `90.0000025`, 45 reads `45.0000013`. Computing the conversion in float (`Math.fround(r * Math.fround(180 / Math.PI))`) gives exactly 90, 45, 180, 360, 1 and 12.5, which is presumably what WE's C++ float conversion returns. `if (thisLayer.angles.z >= 90)` differs. **Fixed** in `39ceef8`: written degrees stay authoritative while the stored radians are unchanged; others convert in float.

**Note (S25).** A material constant named like one of the instance's internals (`_t`, `_dead`, `_effect`, `_constants`, …) makes `new Material` throw (redefining a non-configurable property), so `getEffect` fails for the whole layer (`objects-effects.js:57-68` skips only names in `Material.prototype`). Scene.json constant names are shader-author strings, so it is unlikely; skipping names that are own properties too costs nothing.

### WP5 follow-up: `5342654` (per-registration audio arrays)

**SF9 is fixed for audio buffers.** Each `registerAudioBuffers` call now gets its own `Float32Array`s over extension-owned memory with a no-op deallocator (`Scene/Scripting/Audio/SceneScriptAudioBuffersExtension.swift`), so `transfer()` detaches only that script's arrays and can't free the memory; scripts still see each other's writes until the next refill, which the commit pins to WE's DLL (`0x181655170`). **SF3 stays open** for the buffers that still use `SceneScriptSharedBuffer`'s freeing deallocator and are reachable from scripts through `__rt`: the command ring (`__rt.ring.header/records/args`), the object table (`__rt.table.values`, `__rt.objects.*`) and the engine frame (`__rt.native.engineFrame`). The same no-op-deallocator pattern fixes them.

### WP6: `02e299e` (media callbacks fed by MediaRemote)

**What the commit already covers.** S18: MediaRemote is resolved with `dlopen`/`dlsym` and a missing symbol means `enabled: false` once; fetching and the artwork palette run on a utility queue, never on the render thread; timeline events come at most once a second and only while playing with a known duration; every script gets its own event object and fresh `Vec3` colours (S14); a script gets the current state right after its `init`, and queued events it already saw are skipped by version (P8). No AppleScript.

**SF14. `stop()` unregisters MediaRemote for the whole process. Medium (S18, S22), verify.** `MacMediaSessionSource.stop()` calls `MRMediaRemoteUnregisterForNowPlayingNotifications()` (`Scene/Scripting/Media/MacMediaSessionSource.swift:65`), and `SceneScriptMediaExtension.deinit` calls `stop()`. The register/unregister pair takes no token, so if WP11 gives each runtime its own source (the extension's `init(source:)` invites it), tearing down one display's runtime (switching its wallpaper) stops now-playing notifications for the other display's source too; its scripts then see only the 1 s timeline ticks, never a track or artwork change.
- **Fix direction:** one app-wide source that fans out to extensions, or reference-count register/unregister.
- **Test:** two sources started, the first stopped, a now-playing change posted → the second still publishes it.

**SF15. A paused wallpaper loses media changes, not only property changes. Medium (S20, extends SF4).** While frames are stopped (`playRate 0`, occluded, display asleep), media events keep arriving (the timeline once a second), and the inbox drops the oldest past 1024 (`Runtime/SceneScriptInbox.swift:14-16`): after about 17 minutes of paused playback, the track change or artwork change that happened early in the pause is gone. Media changes are posted as deltas (one event per changed part), so nothing re-sends it: after resuming, `mediaPropertiesChanged` scripts show the old title and `thisObject.visible = event.hasThumbnail` stays stale until the next change. **Fixed** in `16f9469` with SF4: media kinds coalesce to their newest event (`.latest`).
- **Fix direction:** coalesce media events per kind in the inbox (keep only the newest of each), like cursor moves.
- **Test:** post a properties change, then 1100 timeline events, then run a frame → the script's last `mediaPropertiesChanged` has the new title.

**SF16. Teardown blocks the render thread on artwork decoding. Low.** `stop()` runs `queue.sync` when called off the queue (`MacMediaSessionSource.swift:67`); if the queue is decoding and scoring a large artwork (`ArtworkPalette.colors(of:)` visits every pixel), the wallpaper switch waits for it on the main thread. Downscale the artwork before scoring (WE's helper works on the thumbnail) or stop asynchronously.

### Runtime hardening: `d7c3021`, `0338833`, `16f9469`, `39ceef8`, `5c883fe`, `0972d84`, `cea1147`

SF1–SF8, SF10–SF13 and SF15 are fixed, each with a regression test in `SceneScriptRuntimeHardeningTests` or `SceneScriptObjectHardeningTests`; S19 has its mechanism (`SceneScriptThread`). Still open:
- SF14 and SF16 (WP6's `MacMediaSessionSource`). `SceneScriptMediaExtension` can now stop or unsubscribe in the new `tearDown(_:)` hook instead of `deinit`.
- S19: the watchdog still covers a whole frame, not each outermost call, and nothing shows the halted state to the user.

S28 and S11 were closed with WP8 (see WP8 below).

### WP8: property binding, S11, S28

**What the commits cover.** S6/P3: returns go through WE's converter per property type, read from the DLL (`0x181620e10`): flags take only booleans (so `return 1` on `visible` is ignored, unlike the object model's direct setters), text takes `ToString` of anything but `null`/`undefined` (a number shows as its text, never "undefined"), vectors take objects with numeric components or a broadcast number and reject `"1 2 3"`; NaN is written. S7: every argument is a fresh value and every applied return is copied, so neither a mutated argument nor a returned object changed later moves the property. S8: user-bound `scriptproperties` are resolved before module bodies run and re-injected through `_Internal.updateScriptProperties` before the frame's `applyUserProperties`; user-bound values take the new value then too. S25: `thisObject` is the effect, material or scene; material constants read `getMaterialProperty` and write `setMaterialProperty`. S26: hidden layers keep updating.

**Open.**
- Which properties use the converter's Int32 and inert cases is unknown; every numeric property is treated as float. `instanceoverride.colorn` is a number (the d.ts), though scene.json writes a colour.
- The argument is the object model's live value, so it is only as right as the descriptions WP11 builds: they must carry user-resolved values and the renderer's animated values (P2).
- Direct member writes (`thisLayer.visible = 1`) still accept numbers through the object model's setters; whether WE's member setters use the same converter is not verified.

### WP11: renderer integration (`9fe7c90`…`ee8b3bf`)

**What the commits cover.**
- S19: every runtime lives on its own `SceneScriptThread` and the renderer only posts frames (`asyncFrame`), so a hung script drops script frames while the renderer keeps drawing their last values. A watchdog stop is logged, shown in a non-blocking panel like safe restart's (Retry reloads the wallpaper) and stops only that wallpaper's scripts (`SceneScriptRenderTests.testAHungScriptHaltsOnlyItsWallpaper`). The watchdog still covers a whole frame, not each outermost call.
- S22: one runtime per renderer, i.e. per display; `shared`, module variables and frame counts are their own (`testTwoDisplaysShareNothing`). Storage and the media session are shared on purpose (one `SceneScriptStorage`, one `MacMediaSessionSource`, which fans out per subscriber, so SF14 is moot).
- S11/S12: the clone stress test runs 1000 frames of create-and-destroy with the table's slots reused and the scene flat (`SceneScriptWallpaperTests.testCreatingAndDestroyingALayerEveryFrameStaysFlat`). `createLayer` describes the layer synchronously and the renderer builds it off the main thread, so it draws a frame or more later; a missing asset gives `null` and one log line.
- S13: `sortLayer` reorders at once in JS and the renderer applies the order on its next draw, with particle systems kept between the layers around them (`testDrawOrderPutsParticlesBetweenTheLayersAroundThem`).
- S26: hidden objects and effects are built and skipped; visibility scripts run every frame (`testScriptWritesReachThePixels`).
- S10: the renderer tears its runtime down on its thread (`destroy()` runs there) when the content stops or the document changes.

**Open.**
- One frame of latency: scripts run between draws, so what they write shows on the next draw (WE runs them in the frame).
- The left button counts only while Finder is frontmost, the closest this app gets to "clicks the wallpaper receives".
- `brightness` and `size` scripts (none in the corpus) keep their values in JS but aren't drawn from them; sound layers aren't played; scene, effect and material animations aren't script-controlled (WP12).
- 3453730450 takes 0.49 ms per frame (Release median, p99 0.97 ms), just under §4.6's budget, nearly all of it its 71 scripts' JavaScript; the host around them costs about 0.05 ms.
