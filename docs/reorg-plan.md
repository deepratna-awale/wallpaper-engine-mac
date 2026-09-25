# Phase 1 reorganization plan

**Status:** approved 2026-09-25; in progress on `deepratna/phase1-structure`.

**Aim:** move the code into the layout described in [`architecture.md`](architecture.md) and add the safety net, *without changing behaviour*. Type renames and logic changes are out of scope; they happen in Phases 2–6 as each area is rewritten.

## Ground rules

- **Branch.** Work on a new branch, `deepratna/phase1-structure`, based on `deepratna/feature-work` and opened as a PR stacked on #2. That keeps PR #2 reviewable.
- **One commit per step.** Moves are `git mv` only. Splits are cut and paste only, plus the minimum visibility change noted in the tables below (`private` → `internal`).
- **Every step is verified before the next one starts:**
  1. `xcodebuild build` succeeds with no new warnings.
  2. The set of compiled sources is identical: file basenames from the build's `SwiftFileList` and `.metal` inputs, diffed before and after. A split adds only the new file names.
  3. The built app's `Contents/Resources` is byte-identical, compared by hash listing.
  4. The app launches and a fixed set of wallpapers (1 video, 1 web, 3 scenes) loads with no new errors in the log.
- `deepratna/qol-changes` is already contained in `feature-work` (0 commits ahead), so the moves can't conflict with it.

## Step 1: guidelines (docs only)

Commit `CONTRIBUTING.md`, `CLAUDE.md`, `docs/architecture.md`, `docs/progress-snapshot.md` and this plan.

## Step 2: delete dead code

Everything below is unreachable today, and the build confirms it once removed.

| File | Remove | Approx. lines |
|---|---|---|
| `Services/SceneWallpaperViewModel.swift` | `buildSKScene`, `buildImageNode` (only called by `buildSKScene`), `buildParticleNode`, `import SpriteKit`, the "SpriteKit Scene Building" section, and the stale file header comment | ~270 |
| `Services/SceneWallpaperViewModel.swift` | `draggableTextLayer`, `moveTextLayer` (no callers) | ~27 |

Any helper left unused after this, for example SpriteKit-only `colorBlendMode` handling, is removed in the same commit, provided the build and the source-set check confirm it's unreferenced.

## Step 3: folder-synced groups

Upgrade the project to object version 77 and turn the `Open Wallpaper Engine` group into a `PBXFileSystemSynchronizedRootGroup`. From then on, moving a file on disk is enough and `project.pbxproj` no longer changes with every move.

These keep their current handling:

| Item | Handling |
|---|---|
| `Resources/we-assets/` | **Moved to `Vendor/we-assets/`** at the repo root and kept as the existing folder reference, copied as-is. A folder listed in `membershipExceptions` does *not* exclude its contents: the build then failed with duplicate outputs, and its 1,361 `.metal` files would have been compiled. |
| `Open_Wallpaper_Engine.entitlements`, `Open Wallpaper Engine-Bridging-Header.h` | Excluded from target membership; they're referenced by build settings. |
| `Preview Content/` | Unchanged (`DEVELOPMENT_ASSET_PATHS`). |
| `Open-Wallpaper-Engine-Info.plist` | Stays at the repo root, outside the synced group. |

Verification checks 2 and 3 matter most here: identical sources and identical resources.

## Step 4: moves (`git mv` only)

Paths are relative to `OpenWallpaperEngine/`.

| From | To |
|---|---|
| `main.swift`, `AppDelegate.swift` | `App/` |
| `MenuBars/MainMenu.swift`, `MenuBars/StatusBar.swift` | `App/Menus/` |
| `WallpaperView/WallpaperView.swift` | `App/WallpaperView.swift` (per-display host that picks scene, video or web) |
| `Services/OWEPerf.swift` | `Core/Logging/OWEPerf.swift` |
| `Services/ObjCExceptionCatcher.h/.m` | `Core/` |
| `Services/GlobalSettingsService.swift` | `Core/Settings/GlobalSettingsService.swift` |
| `Services/WallpaperEngineAssets.swift` | `Core/WallpaperEngineAssets.swift` |
| `Services/SceneParsers/SceneModels.swift`, `PKGParser.swift`, `TEXParser.swift` | `Scene/Format/` |
| `Services/SceneShaderTranslator.swift` | `Scene/Shaders/` |
| `Services/SceneEffects/SceneDynamicEffectCatalog.swift`, `SceneAuthoredEffectRanges.swift` | `Scene/Shaders/` |
| `WallpaperView/SceneMetalRenderer.swift`, `WallpaperView/SceneShaders.metal`, `Services/SceneCamera.swift` | `Scene/Rendering/` |
| `Services/SceneWallpaperViewModel.swift`, `WallpaperView/SceneWallpaperView.swift` | `Scene/Loading/` |
| `Services/AudioReactiveScriptEngine.swift` | `Scene/Scripting/` |
| `ContentView/Components/SceneInspectorView.swift`, `SceneUserPropertiesView.swift`, `SceneHelp.swift`, `SceneEffectDefinitions.swift` | `Scene/UI/` |
| `Services/AudioLevelTap.swift` | `Audio/` |
| `WallpaperView/VideoWallpaperView.swift`, `Services/VideoWallpaperViewModel.swift`, `Services/VideoTextureStream.swift` | `Video/` |
| `WallpaperView/WebWallpaperView.swift`, `Services/WebWallpaperViewModel.swift` | `Web/` |
| `Services/WEProject.swift`, `WallpaperDirectory.swift`, `WallpaperViewModel.swift` | `Library/` |
| `Services/ZipImporter.swift`, `WallpaperPackageConverter.swift`, `ContentView/ImportPanels.swift` | `Library/Import/` |
| `Services/SteamCmdService.swift`, `WorkshopAPIService.swift`, `WorkshopDependencyResolver.swift`, `WorkshopViewModel.swift`, `ContentView/Components/WorkshopView.swift` | `Workshop/` |
| `SettingsView/*` (7 files) | `Settings/` |
| `ContentView/ContentView.swift`, `MainWindow.swift`, `FirstLaunchView.swift`, `ViewModels/ContentViewModel.swift` | `UI/` |
| `ContentView/Components/WallpaperExplorer.swift`, `ExplorerItem.swift`, `ExplorerTopBar.swift`, `FilterResults.swift`, `WallpaperPreview.swift`, `WallpaperDiscover.swift`, `TopTabBar.swift`, `GifImage.swift`, `ViewModels/FilterResultsViewModel.swift` | `UI/Explorer/` |
| `ContentView/Components/Alerts/*`, `ContentView/Components/ContextMenus/*` | `UI/Explorer/Alerts/`, `UI/Explorer/ContextMenus/` |
| `ContentView/Components/CollapsibleSection.swift`, `GlobalComponents/ColorPanelAnchor.swift`, `GlobalComponents/WorkingInProgress.swift` | `UI/Components/` |

Afterwards `Services/`, `ContentView/`, `WallpaperView/`, `SettingsView/`, `GlobalComponents/` and `MenuBars/` are empty and get removed.

`Localizable.xcstrings`, `Resources/`, `Preview Content/` and `Open_Wallpaper_Engine.docc/` stay where they are.

## Step 5: split multi-type files

Each split is cut and paste along existing type boundaries, one commit per source file. Line numbers refer to the current files.

### `Scene/Rendering/SceneMetalRenderer.swift` (2,397 lines)

| New file | Types moved | Visibility change |
|---|---|---|
| `SceneFontRegistry.swift` | `SceneFontRegistry` (5–24) | – |
| `SceneRenderContent.swift` | `SceneMetalTextureSource`, `SceneMetalEffect`, `SceneMetalLayer`, `VideoMusicSyncVisuals`, `SceneMetalText`, `SceneClock`, `SceneMaterialEffects`, `SceneBloomSettings`, `SceneMetalContent` | – |
| `SceneParticleContent.swift` | `SceneMetalParticleSystem` and the `Particle*`, `Turbulence`, `Attractor`, `CursorControlPoint`, `SpriteSheet` value types (133–315) | – |
| `SceneGPUTypes.swift` | `LayerUniform`, `DXTDecodeUniform`, `EffectUniform`, `EffectDescriptorGPU` | `private` → `internal` |
| `NativeEffectStack.swift` | `EffectStack` (378–627), scheduled for deletion in Phase 2 | `private` → `internal` |
| `DynamicEffectPipelineCache.swift` | `DynamicEffectPipelineCache` | `private` → `internal` |
| `SceneRenderTargetPool.swift` | `SceneRenderTargetPool` | `private` → `internal` |

The `SceneMetalRenderer` class (~1,600 lines) and its private per-frame helpers (`PreparedLayer`, `RenderTextureFrame`, `Particle`, `ParticleSystemRuntime`) stay together. Splitting the class itself would expose its private state, and Phase 2 rewrites it anyway.

### `Scene/Format/SceneModels.swift` (851 lines)

| New file | Contents |
|---|---|
| `SceneDocument.swift` | the free helper functions (1–31), `SceneChangeImpact`, `WEScene`, `WECamera`, `WESceneGeneral`, `WEOrthogonalProjection` |
| `SceneObject.swift` | `WESceneObject` through `WEScriptValue` (152–557), together with the private decoding helpers they use (`WEConditionalBool`, `WEAnimatedScalar`, `FlexibleScriptValue`, `WEScriptedProperty`) and the keyframe types |
| `SceneMaterial.swift` | `WEModel`, `WEMaterial`, `WEMaterialPass` |
| `SceneFlexibleValues.swift` | `WEFlexibleDouble`, `WEFlexibleInt`, the `KeyedDecodingContainer` and `String` extensions, `WEFlexValue` |
| `SceneParticles.swift` | `WEParticleSystem` through `WEParticleRenderer` |

### Other splits

| File | Split |
|---|---|
| `Scene/Scripting/AudioReactiveScriptEngine.swift` | `BrowserMediaIntegration` → `Scene/Scripting/BrowserMediaIntegration.swift`; `AudioVisualizationSnapshot` → `Audio/AudioVisualizationSnapshot.swift`. Extracting audio capture out of the engine is a logic change, so it waits for Phase 6. |
| `Scene/Shaders/SceneDynamicEffectCatalog.swift` | `SceneShaderUniformReflection` + `SceneShaderReflection` (+ extensions) → `SceneShaderReflection.swift` |
| `Video/VideoWallpaperView.swift` | `VideoMusicSyncSettings`, `VideoMusicSyncStore` → `Video/VideoMusicSync.swift` |
| `Core/Logging/OWEPerf.swift` | → `OWELog.swift`, `OWESignpost.swift`, `OWEFrameMetrics.swift` |
| `Core/Settings/GlobalSettingsService.swift` | the `GS*` enums + `GlobalSettings` → `GlobalSettings.swift`; `GlobalSettingsViewModel` stays |
| `Library/WEProject.swift` | `WEWallpaper`, the sorting enums and `WEInitError` → `Library/WEWallpaper.swift` |
| `Library/WallpaperViewModel.swift` | `WallpaperPlaylistItem`, `WallpaperPlaylist` → `WallpaperPlaylist.swift`; `WallpaperPlacement` → `WallpaperPlacement.swift` |
| `App/AppDelegate.swift` | `WallpaperWindow`, `SettingsToolbarIdentifiers` → `App/WallpaperWindow.swift`. The private Workshop preview window stays for now. |

`SceneWallpaperViewModel` (~1,650 lines after step 2) and `SceneInspectorView` (1,341) aren't split in Phase 1. Each is one class with shared private state, and Phases 2–4 replace most of `SceneWallpaperViewModel`.

## Step 6: safety net

1. **Logging.** Route `OWELog` through `os.Logger` (subsystem `com.winddog.wallpaper-engine`, category per `OWELog.Category`, messages `privacy: .public`), and replace the remaining `print` and `NSLog` calls. This is a small, deliberate behaviour change: log output only.
2. **Tests.**
   - Add an `Open Wallpaper EngineTests` unit-test target, and fix the shared scheme's dangling test references.
   - Add fixtures under `Tests/Fixtures/`: small hand-made scenes plus the `effect.json`/material shapes, covering multi-pass, combos, user bindings and text alignment.
   - First tests: `Scene/Format` decoding (element-wise failure, `{"user":…}` forms), translator stamp/purge and `M_PI_2`/`pow`, and `project.json` user-property parsing.
3. **Headless render check.** A test that loads each fixture through the real loader and renderer offscreen for N frames, then asserts:
   - every effect pipeline built
   - no layer was dropped
   - no script threw

   The Phase 0 `pipetest` harness is the starting point. It is expected to **fail** on the dynamic-shader fixtures until Phase 2, so those cases are marked as expected failures, which records the known gap.
4. **CI.** Add `.github/workflows/ci.yml`. It runs `xcodebuild build test` on every push and PR against `macos-15`, with Homebrew `glslang` and `spirv-cross`, and signing disabled.

## Out of scope for Phase 1

- Type renames (e.g. `AudioReactiveScriptEngine` → `SceneScriptRuntime`, `WE*` → `Scene*`).
- Extracting the local Swift package.
- Removing singletons.
- Swift 6 language mode.

These land with the phase that rewrites each area, so every change is reviewed together with its replacement.
