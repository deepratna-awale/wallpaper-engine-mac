# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Added a native Metal scene renderer with layer compositing, keyframe timelines, camera/projection handling, pooled render targets, effect masking, and additive/alpha blending.
- Added roughly 48 native Metal scene effects, including blur variants, bloom, godrays and light shafts, water waves/ripples/caustics/flow, clouds and fog, film grain, glitch/VHS, chromatic aberration, colour key, transform/skew/spin/twirl/perspective, reflection, refraction, shine/shimmer/glitter, and edge detection.
- Added audio-reactive effects (pulse, audio bars, hue shift, hyperdrive) driven by ScreenCaptureKit system-audio capture with a smoothed 16-band spectrum and bass/mid/treble levels.
- Added GLSL to SPIR-V to MSL shader translation using `glslangValidator` and SPIRV-Cross, with COMBO define extraction, include resolution, sampler deduplication, and Metal buffer-slot renumbering.
- Added a hash-gated shader cache under `.open-wallpaper-engine/shaders` storing `.metal`, `.metallib`, and `.reflection.json` artifacts, with background `.metallib` compilation and per-revision `unsupported` markers.
- Added a dynamic scene effect catalog sourced from Wallpaper Engine `assets/effects/*/effect.json` manifests, including multi-pass effects and reflected uniform bindings.
- Added GPU decoding of mipmapped DXT1/DXT3/DXT5 textures and TEXS0001/0002/0003 sprite timelines.
- Added a persistent SceneScript runtime with per-layer contexts, `init()`/`update(value)` lifecycle, `thisScene`/`thisLayer`/`engine`/`input` globals, `audio(low, high)` and `fft(index)`, timers, cursor and resize events, Vec/Mat math, `WEMath`/`WEVector`/`WEColor`, and loading of Wallpaper Engine JS modules.
- Added scripted control of layer alpha, origin, size, scale, angles, brightness and colour, material constants, effect thresholds, and particle emission rate, drag, and alpha fade.
- Added advanced particle behaviour: turbulence, attractors, vortex and boid motion, static and cursor-linked control points, rope segments, trails with alpha/size fade, and spritesheet frame animation.
- Added mouse tracking and parallax for layers with authored `parallaxDepth`.
- Added user-property support for slider, checkbox, combo, text, and colour settings in the scene inspector, with per-property music sync and amount modulation.
- Added a settings diagnostics section reporting shader toolchain paths and shader cache statistics, with a cache invalidation action.
- Added a Wallpaper Engine assets directory setting plus bundled `we-assets/` fallback, and `Scripts/vendor-shader-tools.sh`, `Scripts/vendor-we-assets.sh`, and `Scripts/scene-api-coverage.py`.
- Added quality, anti-aliasing, and post-processing options to the Performance settings page.
- Added music-synced zoom, tilt, and saturation for video wallpapers.
- Added Steam Workshop browsing with tag filters, numbered pagination, cached metadata, author profiles, and downloaded-item filtering.
- Added SteamCMD download queueing, retryable failures, live percentage progress when available, and a dedicated Downloads tab.
- Added Workshop preview windows backed by a bounded cache, with set-wallpaper, playback, and volume controls.
- Added multi-selection, range selection, and confirmation-gated bulk Workshop downloads and Installed wallpaper deletion.
- Added persisted downloaded Workshop IDs and download timestamps, including `Date Downloaded` sorting.
- Added multi-desktop selection and an `All Desktops` control in Display Settings.
- Added wallpaper placement controls for Fill, Fit, Center, Stretch, and Zoom.
- Added audio/video speed linking controls for video wallpapers.
- Added configurable wallpaper storage with an option to move the existing library to the selected location.

### Changed

- Scene wallpapers now render through Metal instead of SpriteKit.
- Reduced scene rendering hot-path overhead by caching effect descriptors that do not vary per frame and taking a single user-property snapshot per frame.
- Installed and Workshop grids now size their pages from the available viewport and current icon size.
- Installed tile selection now previews an item; applying a wallpaper is an explicit action from the sidebar or preview window.
- Cached Workshop previews are promoted to the permanent wallpaper library when applied, without a second download.
- Scene image layers use explicit SpriteKit depth ordering.
- Only one desktop video wallpaper outputs audio to avoid duplicate playback artifacts.
- Renamed the Installed sort label to `Date Downloaded` while preserving the existing saved preference value.
- Paused foreground thumbnail and sidebar GIF animations while the app is inactive, and avoided redundant GIF image decoding during SwiftUI updates.

### Fixed

- Fixed shaders exceeding Metal's 31 buffer-slot limit by densely renumbering bindings emitted by `glslang --auto-map-bindings`.
- Fixed spirv-cross output that declared helper parameters as `thread const T&` where Metal entry points require `constant T&`.
- Fixed repeated retranslation of unchanged shaders by hashing sources and gating on a pipeline revision.
- Fixed SceneScript exception spam by deduplicating identical errors within a time window and reporting repeat counts.
- Fixed SteamCMD downloads failing when the default Homebrew location is not writable by using a local forced install directory.
- Fixed stale Workshop previews replacing newer selections.
- Fixed cached Workshop download status not being reflected after app restart.
- Fixed Workshop Hide Downloaded pages leaving empty grid positions.
- Fixed SF Symbol warnings caused by empty symbol names.
- Fixed preview rendering requiring window movement before redraw.
- Fixed preview audio continuing after the preview window closes.
- Fixed author lookup when downloaded projects have an empty `workshopid` by falling back to the numeric wallpaper folder name.
- Fixed saved wallpaper assignments, recents, and the downloaded-ID index after moving the wallpaper library.
- Preserved compatibility with legacy Workshop metadata cache encodings.
- Fixed white flashes during wallpaper-window and SpriteKit scene initialization by using explicit black backing colors.

### Removed

- Removed hover-triggered Workshop preview downloads.
- Removed the bottom download queue panel in favor of the Downloads tab.
