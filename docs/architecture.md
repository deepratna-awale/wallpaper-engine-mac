# Architecture

Open Wallpaper Engine for macOS plays Wallpaper Engine (WE) wallpapers: **scene**, **video** and **web**. The `application` type is out of scope. The goal is to run *any* WE wallpaper, including arbitrary Workshop scenes with custom effects, shaders and SceneScripts. So the scene engine implements WE's actual formats and semantics, not per-wallpaper approximations.

This document describes the target structure and the rules for what goes where. [`docs/reorg-plan.md`](reorg-plan.md) lists the steps from today's layout to this one. [`docs/progress-snapshot.md`](progress-snapshot.md) records how complete each feature is.

## Big picture

```
┌──────────────────────── App shell (SwiftUI/AppKit) ────────────────────────┐
│ App/  Library/  Workshop/  Settings/  UI/            (views + view models) │
└───────────────┬───────────────────────────────┬────────────────────────────┘
                │ WEWallpaper                    │
      ┌─────────▼─────────┐  ┌─────────────┐  ┌──▼──────────┐
      │ Scene/  (engine)  │  │ Video/      │  │ Web/        │
      │  Format  → Values │  │ AVPlayer +  │  │ WKWebView + │
      │  Shaders → Render │  │ music sync  │  │ WE web API  │
      │  Scripting, Audio │  └──────┬──────┘  └─────────────┘
      └─────────┬─────────┘         │
                └──────────┬────────┘
                    ┌──────▼──────┐
                    │ Audio/      │  system capture (ScreenCaptureKit), per-item taps
                    └─────────────┘
Core/  logging, diagnostics, settings store, asset locations: usable by everything above
```

**Dependency direction:** arrows only point down. Code in `Scene/` must never import or reference anything in `UI/`, `Library/`, `Settings/` views or `AppDelegate`. Code in `Core/` depends on nothing else in the app.

## Modules

These are folders in the app target today. The scene engine (`Scene/`, `Audio/`, `Core/`) is meant to become a local Swift package (`Packages/WEScene`) during Phase 2, so it can be unit-tested and run headless. Keeping the dependency rules now is what makes that extraction a move rather than a rewrite.

### `Core/`: shared infrastructure

- **Logging and diagnostics:** `OWELog`, signposts and frame metrics.
- **Settings:** the global settings model and store.
- The **WE assets location**.
- The **Objective-C exception catcher**.
- It must not reference UI, view models or `AppDelegate`.

### `Scene/`: the WE scene engine

| Area | Responsibility | Examples |
|---|---|---|
| `Scene/Format/` | Decode WE files into plain Swift models. It does no rendering and has no side effects. | `scene.json`, `project.json` scene properties, `effect.json`, materials, models, particles, `.pkg`, `.tex` |
| `Scene/Values/` | *(Phase 4)* Resolve every dynamic value the same way: literal, `{"user":…}`, `{"user":{"name","condition"}}`, `{"script":…}`, `{"animation":…}`. | `SceneValue<T>` |
| `Scene/Shaders/` | GLSL → SPIR-V → MSL translation, reflection, the translation cache and the effect catalog. | `SceneShaderTranslator`, `SceneDynamicEffectCatalog` |
| `Scene/Rendering/` | Metal: layers, the effect pass graph, render targets, text, particles and the camera. | `SceneMetalRenderer`, `SceneShaders.metal` |
| `Scene/Scripting/` | The SceneScript runtime (JavaScriptCore), one per wallpaper instance on its own thread, and the WE JS API surface as extensions; `Host/` ties a runtime to the renderer (docs/scenescript-plan.md). | `SceneScriptRuntime`, `SceneScriptWallpaper`, `SceneScriptSceneMirror` |
| `Scene/Loading/` | Turns a wallpaper into render content: loads, resolves and builds. | `SceneWallpaperViewModel` (to be split) |
| `Scene/UI/` | Scene-specific SwiftUI: the inspector and user properties. These are the **only** scene files allowed to import SwiftUI views. | `SceneInspectorView`, `SceneUserPropertiesView`, `SceneHelp` |

### `Audio/`

- System audio capture (ScreenCaptureKit) with a restart lifecycle.
- Per-player taps (`AudioLevelTap`).
- Spectrum and waveform snapshots.
- One producer, many consumers: scene shaders, SceneScript `registerAudioBuffers`, video music sync.

### `Video/` and `Web/`

- Each holds its player, view, view model and type-specific features: video music sync, and the web wallpaper property/audio bridge.

### `Library/`, `Workshop/`, `Settings/`, `UI/`, `App/`

- **`Library/`:** app-shell features. It holds the wallpaper library model and the import paths (`WEProject`, `WallpaperDirectory`, zip/pkg import).
  - Installed lists what WE lists (`InstalledLibrary`): items whose project.json `type` is scene, video, web or application. Asset items (`"category": "Asset"`, no `type`) and items downloaded only as another wallpaper's dependency (`WorkshopDependencyIndex`, a hidden file in the library folder) stay on disk, where `WorkshopAssetResolver` finds them, but aren't listed. Downloading such an item yourself makes it yours and lists it.
  - Deleting a wallpaper removes the dependency-only items nothing left in the library references (`WorkshopDependencyCleanup`, logged). WE leaves required items to Steam, where the user can still see and unsubscribe them; here they are hidden, so keeping them would leave them on disk with no way to remove them.
- **`Workshop/`:** steamcmd and the Workshop API. Steam secrets live in the keychain (`Core/Keychain`, `SteamCredentials`): the Web API key and the steamcmd account name. The password and Steam Guard code are piped to steamcmd on stdin and never stored; steamcmd keeps its own login token. The API key goes in the `x-webapi-key` header, never a URL.
- **`Settings/`:** settings pages.
- **`UI/`:** the main window and shared components.
- **`App/`:** the entry point, `AppDelegate`, windows and menus.
- Each view model lives next to its view.

### `Resources/`

- `Assets.xcassets`, `Localizable.xcstrings`, media.
- The vendored WE runtime assets live outside the app folder in `Vendor/we-assets/` (repo root). They're a **folder reference**, copied into the app as `Resources/we-assets` and never compiled.

## Scene data flow

1. **Load.** `Scene/Format` decodes `project.json`, `scene.json` (from disk or the `.pkg`), then models, materials, effects and textures (`.tex`).
2. **Resolve.** `Scene/Values` binds user properties (per wallpaper, per display), scripts and animations to typed values. Nothing downstream reads raw JSON or string-keyed dictionaries.
3. **Build.** `Scene/Loading` produces render content: an ordered layer list in authored object order. Each layer carries its full parent transform, its effect pass graph (from `effect.json` passes, `fbos`, `bind`, `target` and combos) and its text, particle and sound state.
4. **Render.** `Scene/Rendering` executes the pass graph each frame through translated WE shaders. Uniforms come from reflection, plus built-ins such as `g_Time`, resolutions, pointer and audio spectrum, plus resolved constants.
5. **Script.** `Scene/Scripting` runs once per frame in one context per wallpaper instance, on its own thread. Layer objects read and write a shared object table; the renderer feeds it each object's drawn values before the frame and draws what scripts wrote after it (`SceneRendererScripts`).

## Invariants

- **WE semantics, not approximations.** Wallpaper Engine's shaders and effect definitions are the reference. Hand-written "native" effects and name/regex heuristics are technical debt to delete, not a pattern to extend (see [`CONTRIBUTING.md`](../CONTRIBUTING.md)).
- **Per-wallpaper state.** State belongs to a wallpaper *instance* (one per display), never to a process-wide singleton.
- **Loud failure.** A shader that fails to build, a layer that can't be decoded, or a script that throws is logged once, with the wallpaper, layer and reason.
- **Honest caches.** Everything derived from inputs (shader translations, `.metallib`s, parsed scenes) is keyed on its inputs *and* the version of the code that produced it.
