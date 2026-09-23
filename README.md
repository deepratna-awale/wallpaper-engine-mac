Open Wallpaper Engine (Patched)
=========

**English** | [繁體中文](README.zh-TW.md) | [日本語](README.ja.md)

[![GitHub license](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)

A patched fork of [Open Wallpaper Engine](https://github.com/MrWindDog/wallpaper-engine-mac) for macOS, adding scene wallpaper rendering and web wallpaper fixes.

> **Note:** This is NOT affiliated with the commercial Wallpaper Engine on Steam. This is an open-source macOS app that can display wallpaper assets from Wallpaper Engine's Steam Workshop.

## Related Projects

- **[Open Wallpaper Engine for Linux](https://github.com/Unayung/simple-linux-wallpaperengine-gui)** — A PyQt6 GUI for [linux-wallpaperengine](https://github.com/Almamu/linux-wallpaperengine), with Steam Workshop integration and UI design ported from this macOS version.

## Credits

This project is built on top of the work of:

- **[MrWindDog](https://github.com/MrWindDog)** — Maintainer of the upstream [wallpaper-engine-mac](https://github.com/MrWindDog/wallpaper-engine-mac) fork, added new features and UI refinements
- **[Haren Chen](https://github.com/haren724)** — Original creator of [open-wallpaper-engine-mac](https://github.com/haren724/open-wallpaper-engine-mac), built the core app architecture (SwiftUI, video wallpaper playback, import system, playlist UI)
- **[1ris_W](https://github.com/Erica-Iris)** — Chinese i18n translation
- **[Klaus Zhu](https://github.com/klauszhu1105)** — App logo icons
- **[Chen Chia Yang](https://github.com/Unayung)** — Scene wallpaper rendering, web wallpaper fixes, Steam Workshop integration, multi-display support, zip import
- **[Deepratna Awale](https://github.com/deepratna-awale)** — Metal scene renderer and effect pipeline, GLSL→MSL shader translation and caching, SceneScript runtime, audio-reactive rendering, Workshop/Downloads overhaul, placement and performance settings

Licensed under [GPL-3.0](LICENSE), same as the original project.

## What 0.8.1 Supports

### Wallpaper playback
- **Scene wallpapers** rendered natively with Metal — image layers, transforms, keyframe timelines, depth ordering, and camera/projection data from `scene.json`.
- **Video wallpapers** (`.mp4`, `.webm`) with playback rate, volume, audio/video speed linking, and optional music-synced zoom/tilt/saturation.
- **Web wallpapers** (HTML/WebGL) with local file access enabled so WebGL textures and assets load correctly, plus external embeds (YouTube/Vimeo).
- **Placement modes** — Fill, Fit, Center, Stretch, Zoom.
- **Multi-display** — a different wallpaper per monitor, per-screen enable/disable, visual monitor layout, and auto-detection of newly connected displays.
- **Multi-desktop (Spaces)** — continuous playback across all desktops, including an `All Desktops` assignment option.
- **Playback rules** — keep running, mute, pause, or stop when another app is focused; correct behaviour on sleep/wake and desktop switches.

### Scene format support
- **PKG parser** for Wallpaper Engine `PKGV` archives (scene.json, materials, textures, shaders).
- **TEX parser** for `TEXV0005` containers: embedded JPEG/PNG, mipmapped DXT1/DXT3/DXT5 decoded on the GPU via a Metal compute shader.
- **TEXS sprite timelines** (0001/0002/0003), including single-atlas frame rectangles and multi-image sequences.
- **Flexible scene.json decoding** that handles Wallpaper Engine's polymorphic fields (plain values or `{"script":…,"value":…}`).
- **Preview fallback** to `preview.jpg/png/gif` when textures can't be extracted.

### Effects and shaders
- **~48 native Metal effects** covering distortion, blur (standard/precise/radial/motion), bloom, godrays and light shafts, water waves/ripples/caustics/flow, clouds and fog, film grain, glitch/VHS, chromatic aberration, colour key, transform/skew/spin/twirl/perspective, reflection, refraction, shine/shimmer/glitter, edge detection, and more.
- **Audio-reactive effects** — pulse, audio bars, audio-synced hue shift, and hyperdrive driven by live system-audio spectrum data.
- **Semantic material effects** — brightness, contrast, saturation, exposure, gamma, hue, bloom threshold, bloom, and blur mapped to native Metal passes.
- **GLSL → SPIR-V → MSL translation** at import time via `glslangValidator` and SPIRV-Cross, with COMBO defines, include resolution, and Metal buffer-slot renumbering.
- **Precompiled shader cache** — translated `.metal`, compiled `.metallib`, and `.reflection.json` sidecars are cached under `.open-wallpaper-engine/shaders`, hash-gated so only changed shaders are retranslated, and compiled in the background so rendering is never blocked.
- **Dynamic effect catalog** read from the Wallpaper Engine `assets/effects/*/effect.json` manifests, including multi-pass effects and reflected uniform bindings.
- **Effect masking** (up to 4 mask textures per layer), additive and alpha blending, and a pooled render-target system.

### Particles
- Sprite emitters with randomized lifetime, size, velocity, colour, rotation, angular velocity, gravity, drag, and alpha fades.
- Advanced behaviour — turbulence, attractors, vortex and boid motion, static and cursor-linked control points, connected rope segments, and trails with alpha/size fade.
- Spritesheet frame animation via `.tex-json` sequences.
- Scripted operators for emission rate, drag, and alpha-fade timing.

### SceneScript runtime
- Persistent per-layer script contexts with `init()` called once and `update(value)` called every frame.
- Globals: `thisScene`, `thisLayer`, `engine`, `input`, `audio(low, high)`, real `fft(index)`, `setTimeout`/`setInterval`, and persistent script globals.
- Full `Vec2`/`Vec3`/`Vec4`/`Mat3`/`Mat4` math library plus `WEMath`, `WEVector`, and `WEColor` helpers.
- Wallpaper Engine runtime JS modules loaded from `assets/scripts/jsmodules` and `jsclasses`.
- Cursor events (`cursorMove`/`Down`/`Up`/`Click`/`Enter`/`Leave`) and `resizeScreen`.
- Scripts can drive layer alpha, origin, size, scale, angles, brightness/colour, material constants, effect thresholds, and particle rates.
- Deduplicated script exception logging with repeat counts.

### Audio
- System audio capture via ScreenCaptureKit feeding a smoothed 16-band spectrum, waveform, and bass/mid/treble levels.
- Per-property **music sync** — any user property can be modulated by audio level with a configurable amount.

### User properties & inspector
- Slider, checkbox, combo, text, and colour project settings exposed in the scene sidebar, live-applied, and readable from SceneScript.
- Mouse tracking and parallax for layers with authored `parallaxDepth`.

### Steam Workshop
- Browse, search, and filter by content rating, type, and genre tags, with Trending / Most Recent / Most Popular / Most Subscribed sorting and numbered pagination.
- Preview windows with set-wallpaper, playback, and volume controls, backed by a bounded cache; applied previews are promoted to the library without re-downloading.
- SteamCMD integration with auto-detection, password / Steam Guard / cached-session login, a dedicated Downloads tab, queued and retryable downloads, and live progress.
- Multi-selection, range selection, confirmation-gated bulk downloads and deletions, persisted downloaded IDs, and `Date Downloaded` sorting.

### Library & settings
- Import from folders, from `.zip` packages, or by drag-and-drop.
- Configurable wallpaper storage location with migration of an existing library.
- Recent wallpapers menu in the status bar.
- Performance settings — quality, anti-aliasing, post-processing, and focus-loss playback behaviour.
- Diagnostics — resolved shader toolchain paths, shader cache statistics, and a cache invalidation action.

<details>
<summary>Previously in 0.8.0</summary>

### Multi-Display Support
Assign different wallpapers to each connected monitor with per-screen enable/disable control.
- **Display Settings panel** — Visual monitor layout showing all connected screens, click to select
- **Per-screen wallpaper** — Each display can show a different wallpaper independently
- **Enable/disable toggle** — Turn wallpaper on or off per monitor
- **Auto-detect** — New monitors are automatically detected and enabled when connected

### Multi-Desktop Support
Wallpapers now display across all macOS desktops (Spaces) with continuous playback — no interruption when switching desktops.

### Recent Wallpapers Menu
Quickly switch wallpapers from the status bar menu. The last 10 wallpapers you've used are listed for one-click access.

### Playback Settings — Fixed
Performance playback settings (pause/mute/stop when other apps are focused) now work correctly for all wallpaper types.

### Steam Workshop Browser
Browse, search, and download wallpapers directly from the Steam Workshop without leaving the app.
- **Search & filter** — Search by name, filter by content rating (Everyone/Questionable/Mature), type (Scene/Video/Web), and genre tags
- **Sort options** — Trending, Most Recent, Most Popular, Most Subscribed
- **steamcmd integration** — Auto-detects steamcmd (Homebrew or custom path), with install instructions if not found
- **Steam login** — Supports password, Steam Guard, and cached session authentication
- **Download with progress** — Real-time status updates during download (authenticating, downloading %, validating, copying)
- **Safe defaults** — Content rating defaults to "Everyone" to filter out mature content

### Zip Import
Import wallpaper packages directly from `.zip` files — no need to manually extract first. Works via File > Import and drag-and-drop.

### Multi-Select & Batch Unsubscribe
Cmd+click to select multiple wallpapers, then right-click to batch unsubscribe.

### Wallpaper Storage Isolation
Wallpapers are now stored in `~/Documents/Open Wallpaper Engine/` instead of the raw Documents directory, preventing "error" wallpapers when cloning the repo on a fresh machine.

</details>

<details>
<summary>What's patched relative to upstream</summary>

### Web Wallpapers — Fixed gray/blank rendering
WebGL-based wallpapers rendered as gray rectangles because `WKWebView` blocked local file access for textures and assets.

**Fix:** Enabled `allowFileAccessFromFileURLs` and `allowUniversalAccessFromFileURLs` on the WKWebView configuration, allowing WebGL shaders to load local texture files.

### Scene Wallpapers — Implemented from scratch
Scene wallpapers (the most common type on Steam Workshop) were completely unimplemented — just showed "Hello, World!".

**New implementation includes:**
- **PKG parser** — Reads Wallpaper Engine's PKGV archive format to extract scene.json, models, materials, and textures
- **TEX parser** — Reads TEXV0005 texture containers, extracts embedded JPEG/PNG image data, and reads DXT1/DXT3/DXT5 mipmaps
- **Scene JSON decoder** — Parses scene.json with flexible decoding that handles Wallpaper Engine's polymorphic fields (values can be plain types or `{"script":..,"value":..}` objects)
- **Metal renderer** — Renders scene image layers with GPU texture compositing and a foundation for future shader effects
- **GPU DXT decode** — Expands DXT1 (TEXI 7), DXT3 (TEXI 6), and DXT5 (TEXI 4) textures through a Metal compute shader when the scene loads
- **Sprite particles** — Renders common `sphererandom` sprite emitters with randomized lifetime, size, velocity, alpha, color, rotation, angular velocity, gravity, drag, and alpha fades
- **Advanced particles** — Supports rotation, color variation, turbulence, static and cursor-linked control points, connected rope segments, trails, and `.tex-json` spritesheet frame animation
- **TEXS animation** — Decodes TEXS0001/0002/0003 timelines, including single-atlas frame rectangles and multi-image texture sequences
- **Scene timelines** — Interpolates object alpha, origin, scale, and angles keyframes at 60 FPS
- **SceneScript runtime** — Evaluates expression and `export function update(value)` property scripts against ScreenCaptureKit system audio. `thisScene` timing, `thisLayer.value`, `engine`, input cursor, `audio(low, high)`, real `fft(index)`, property lookup, and persistent globals drive image transforms, alpha, and particle emission rates.
- **Persistent SceneScript lifecycle** — Reuses per-layer script contexts, calls `init()` once, and calls `update()` across frames with shared `dt`, frame, mouse, button, modifier, cursor, audio, FFT, property, and layer state.
- **Scripted particle operators** — Supports scripts for particle emission rate, movement drag, and alpha fade timing, with flexible numeric/string particle fields.
- **Mouse tracking and parallax** — Applies cursor-relative translation and optional perspective scaling to layers with authored `parallaxDepth` metadata; cursor-linked particles use the same scene-space cursor.
- **Scripted visual properties** — Supports scripted object brightness/RGB color, material effect constants, scalar/vector transforms, and effect threshold overrides.
- **User properties** — Exposes documented slider, checkbox, combo, text, and color project settings in the scene sidebar and makes numeric and boolean values available to SceneScript
- **Built-in scene effects** — Executes authored `pulse`, `shake`, `iris`, and `waterwaves` effect graph entries in the Metal renderer
- **Semantic material effects** — Maps common material constants and scripts for brightness, contrast, saturation, exposure, gamma, hue, bloom threshold, bloom, and blur to native Metal effects
- **GLSL shader translation** — Converts packaged Wallpaper Engine GLSL shaders to SPIR-V and MSL at import time with `glslangValidator` and SPIRV-Cross; generated MSL is cached under `.open-wallpaper-engine/shaders` in the wallpaper directory
- **Preview fallback** — Falls back to preview.jpg/png/gif when textures can't be extracted

### Import — Fixed folder import
The import panel now correctly handles both individual wallpaper folders and parent directories containing multiple wallpapers.

</details>

## Current Limitations

- **Application wallpapers** — `type: "application"` wallpapers are not supported and will not run.
- **3D models and rigging** — Bone transforms, blend shapes, attachments, and puppet-warp rigs (`.mdl`) are stubbed; affected layers render as flat atlases.
- **Material script functions** — `getMaterial()`, `getMaterialCount()`, `setMaterialProperty()`, and `executeMaterialFunction()` are stubs that no-op or return empty values.
- **Custom GLSL shader binding** — Converted MSL is cached at import time, but shaders depending on Wallpaper Engine-specific attributes, texture chains, or unsupported includes are not bound into the runtime Metal pipeline. Common bloom, blur, colour-correction, and transform parameters fall back to native Metal mappings.
- **Metal buffer limit** — Shaders needing more than Metal's 31 buffer slots cannot be translated and are permanently marked unsupported for the current pipeline revision.
- **HLSL shaders** — Direct3D-only shaders shipped alongside the GLSL sources are skipped entirely.
- **Effect-schema coverage** — Unknown custom uniform names and arbitrary effect parameter schemas remain unsupported.
- **SceneScript parity** — Not every proprietary event name, input callback, lifecycle edge case, or exact timing semantic is reproduced.
- **Particle operator coverage** — Common scripted rate, drag, and alpha-fade operators work; uncommon operator scripts, custom particle modules, and arbitrary operator schemas are partial.
- **External asset recovery** — Some Workshop packages reference shared TEX assets absent from the downloaded package and need the original Wallpaper Engine install.
- **Some JPEG thumbnails** — A small number of TEXB format 1 files contain non-standard JPEG data that macOS cannot decode.
- **Performance settings scope** — Quality, anti-aliasing, and post-processing options are designed for scene wallpapers and have limited effect on video and web wallpapers.
- **Audio features require permission** — Without Screen Recording permission, audio visualizers and audio-reactive SceneScript receive silence.

## Supported Wallpaper Types

| Type | Status |
|------|--------|
| Video (.mp4, .webm) | Working |
| Web (HTML/WebGL) | Working |
| Scene — image layers & timelines | Working (Metal) |
| Scene — DXT1/DXT3/DXT5 textures | Working (Metal GPU decode) |
| Scene — TEXS sprites / alpha timelines | Working |
| Scene — sprite particles | Working |
| Scene — advanced particles | Partial (scripted rate/drag/fade supported) |
| Scene — native Metal effects | Working (~48 effects) |
| Scene — translated Workshop GLSL effects | Partial (see Limitations) |
| Scene — SceneScript | Partial (see Limitations) |
| Scene — 3D models / rigging / puppet warp | Not supported |
| Application | Not supported |

## Requirements

### Required
- **macOS 13.0 or later** (Ventura). ScreenCaptureKit audio capture and Metal scene rendering both depend on it.

### Optional — needed for specific features

| Feature | Requirement | Install |
|---------|-------------|---------|
| Workshop scene effects (blur, bloom, caustics, light shafts…) | `glslang` + `spirv-cross` | `brew install glslang spirv-cross` |
| Browsing / downloading from Steam Workshop | `steamcmd` | `brew install steamcmd` |
| Scene effect library | A Wallpaper Engine `assets/` folder | See below |
| Audio visualizers & audio-reactive SceneScript | Screen Recording permission | Settings → Permissions |

#### Shader toolchain (`glslang` + `spirv-cross`)

Wallpaper Engine ships its effects as GLSL. They are translated to Metal (GLSL → SPIR-V → MSL) the first time an assets folder or wallpaper is loaded, then cached on disk and reused until the source changes.

```sh
brew install glslang spirv-cross
```

The app searches its own bundle, `/opt/homebrew/bin`, `/usr/local/bin`, `/opt/local/bin`, `/usr/bin`, and then your `PATH`. Without these tools the app still runs, but Workshop effects fall back to the built-in native Metal effects only. The resolved paths are logged at launch:

```
[ShaderTranslator] Shader toolchain: /opt/homebrew/bin/glslangValidator + /opt/homebrew/bin/spirv-cross
```

#### Wallpaper Engine assets folder

Scene effects are defined by the effect manifests, materials, and shaders that ship with the Windows build of Wallpaper Engine. They are not redistributed here — point the app at an existing install via **Settings → General → Wallpaper Engine Assets Directory**.

Select the `wallpaper_engine` folder (or its `assets` subfolder), typically:

```
…/Steam/steamapps/common/wallpaper_engine
```

This works with a Steam install running under CrossOver, Parallels, Whisky, or a copy taken from a Windows machine. On success the launch log reports the catalog:

```
[ShaderTranslator] Effect catalog: 45 definitions, 81 complete passes, 1 missing shader pairs
```

Without it, video and web wallpapers still work, and scene wallpapers render — but object effects are unavailable.

## Build from Source

### Prerequisites
- macOS >= 13.0
- Xcode >= 14.4
- Xcode Command Line Tools
- `glslang` and `spirv-cross` (see [Requirements](#requirements)) if you are working on scene effects

### Steps
```sh
git clone https://github.com/unayung/wallpaper-engine-mac
cd wallpaper-engine-mac
open "Open Wallpaper Engine.xcodeproj"
```

In Xcode, change the signing certificate to your own or select "Sign to Run Locally", then press `Cmd + R` to build and run.

## Usage

### Browse & Download from Steam Workshop

1. Install steamcmd (`brew install steamcmd`) or point the app to an existing binary
2. Switch to the **Workshop** tab and log in with your Steam account (must own Wallpaper Engine)
3. Enter a [Steam Web API key](https://steamcommunity.com/dev/apikey) when prompted
4. Search, filter, and click **Download** on any wallpaper

### Import from Local Files

- **Folder:** File > Import from Folder — select wallpaper folders containing `project.json`
- **Zip:** File > Import or drag-and-drop a `.zip` file containing wallpaper packages
- **Manual:** Copy wallpaper folders directly into `~/Documents/Open Wallpaper Engine/`

## Project Layout

- `Open Wallpaper Engine/Services/SceneParsers/` — PKG, TEX/TEXS, and scene.json parsers and models
- `Open Wallpaper Engine/Services/SceneEffects/` — dynamic effect catalog and authored effect parameter ranges
- `Open Wallpaper Engine/Services/SceneShaderTranslator.swift` — GLSL → SPIR-V → MSL translation, `.metallib` compilation, and caching
- `Open Wallpaper Engine/Services/AudioReactiveScriptEngine.swift` — SceneScript runtime and audio/FFT bindings
- `Open Wallpaper Engine/Services/AudioLevelTap.swift` — ScreenCaptureKit system audio capture
- `Open Wallpaper Engine/WallpaperView/SceneMetalRenderer.swift`, `SceneShaders.metal` — the Metal scene renderer and shader library
- `Open Wallpaper Engine/Services/SteamCmdService.swift`, `WorkshopAPIService.swift`, `WorkshopViewModel.swift` — Steam Workshop browsing and downloads
- `Open Wallpaper Engine/Services/WallpaperDirectory.swift`, `ZipImporter.swift`, `WallpaperPackageConverter.swift` — library storage, import, and package conversion
- `Scripts/vendor-shader-tools.sh` — vendors `glslang` and `spirv-cross` into the app bundle
- `Scripts/vendor-we-assets.sh` — vendors translated effect shaders and manifests into `we-assets/`
- `Scripts/scene-api-coverage.py` — reports which SceneScript APIs installed wallpapers use versus what is implemented
