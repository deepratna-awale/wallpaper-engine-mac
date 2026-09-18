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

Licensed under [GPL-3.0](LICENSE), same as the original project.

## What's New in 0.8.0

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

## What's Patched

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

## Current Limitations

- **Effect-schema coverage** — Cross-layer `thisScene.getLayer(idOrName)` mutation and supported scripted material constants are implemented. Unknown custom uniform names and arbitrary effect parameter schemas remain unsupported.
- **Custom GLSL shader binding** — Converted MSL is cached at import time, but shaders that depend on Wallpaper Engine-specific attributes, uniforms, texture chains, or unsupported includes are not yet bound into the runtime Metal render pipeline. Common bloom, blur, color-correction, and transform parameters use native Metal mappings.
- **SceneScript parity** — The runtime does not yet reproduce every proprietary Wallpaper Engine event name, input callback, lifecycle edge case, or exact timing semantic.
- **Particle operator coverage** — Common scripted rate, drag, and alpha-fade operators are supported; less common operator scripts, custom particle modules, and arbitrary operator schemas remain partial.
- **External asset recovery** — Some Workshop packages reference shared TEX assets that are absent from the downloaded package and require the original asset source.
- **Some JPEG thumbnails** — A small number of TEXB format 1 files contain non-standard JPEG data that macOS cannot decode.

## Supported Wallpaper Types

| Type | Status |
|------|--------|
| Video (.mp4, .webm) | Working (original) |
| Web (HTML/WebGL) | Working (patched) |
| Scene (static images) | Working (Metal) |
| Scene (sprite particles) | Working (common emitters) |
| Scene (advanced particles) | Partial — includes scripted rate/drag/fade support |
| Scene (TEXS sprites / alpha timelines) | Working |
| Scene (DXT1/DXT3/DXT5 textures) | Working (Metal GPU decode) |
| Application | Not supported |

## Build from Source

### Prerequisites
- macOS >= 13.0
- Xcode >= 14.4
- Xcode Command Line Tools

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

## Files Changed (vs upstream)

**Modified:**
- `WebWallpaperView.swift` — WKWebView file access configuration
- `WallpaperView.swift` — Scene wallpaper dispatch
- `SceneWallpaperView.swift` — Rewritten as SpriteKit NSViewRepresentable
- `ImportPanels.swift` — Folder import logic fix

**Added:**
- `Services/SceneParsers/PKGParser.swift` — PKGV archive parser
- `Services/SceneParsers/TEXParser.swift` — TEXV texture parser
- `Services/SceneParsers/SceneModels.swift` — Scene JSON data models
- `Services/SceneWallpaperViewModel.swift` — Scene loading and SpriteKit rendering
- `Services/SteamCmdService.swift` — steamcmd detection, login, and workshop download
- `Services/WorkshopAPIService.swift` — Steam Web API client for workshop browsing
- `Services/WorkshopViewModel.swift` — Workshop browser state management
- `Services/WallpaperDirectory.swift` — Centralized wallpaper storage path
- `Services/ZipImporter.swift` — Zip file extraction and import
- `ContentView/Components/WorkshopView.swift` — Workshop browser UI
