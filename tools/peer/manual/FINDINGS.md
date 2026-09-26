# WE 2.8.0.42: manual editor and settings findings (2026-09-26)

Sources:
- The user's screenshots, copied to `screenshots/`
- The user's screen recordings, copied to `recordings/`, with sampled frames in `frames/`
- The user's direct observations, marked **(user)**

## 1. Rotation direction: confirmed
- **2D scene** (`scene2d-img-*.png`):
  - With angles 0,0,0 the arrows point right. The gizmo shows X to the right and Y up.
  - **z=+30 rotates the layer counter-clockwise on screen.** The arrows point up-right at about 30°, the right side rises, and grey canvas shows at the top-left and bottom-right.
  - x=30 squashes the layer vertically by cos 30° (about 87%). y=30 squashes it horizontally.
  - There is **no perspective in 2D**: opposite edges stay parallel and equal, so x and y rotation is just orthographic foreshortening.
- **3D scene** (`scene3d-*.png`, perspective camera):
  - z=+30 also turns counter-clockwise, seen from the layer's front.
  - y=30 swings the layer about the vertical axis, with real perspective: the left edge recedes and the right edge comes nearer.
  - x=30 tips the layer about X toward the floor.
  - The file `scene3d-x0y30-z30.png` actually shows Z=0 in its panel. It is a y=30-only shot.

## 2. Blend modes (image layer, in order; default Normal)
- **Native (fast):** Normal, Add
- **Emulated (slow):** Tint, Darken, Multiply, Color burn, Linear burn, Darker color, Lighten, Screen, Color dodge, Linear dodge, Lighter color, Overlay, Soft light, Hard light, Vivid light, Linear light, Pin light, Diffuse light, Hard mix, Difference, Exclusion, Subtract, Reflect, Glow, Phoenix, Average, Negation, Hue, Saturation, Color, Luminosity (last)

That's 33 modes. Two joins were never seen in the same screenshot (Lighten→Screen and Subtract→Reflect), so a hidden item there can't be fully ruled out. Solid-colour layer with a blend mode: **not captured**.

## 3. Lights (3D scene)
- **Types:** Point light, Spot light, Tube light, Directional light.
- **Common fields:** Name, Origin, Angles, Scale.
- **Spot light:** Color, Intensity, Radius, Falloff, Inner cone, Outer cone, and three checkboxes, all off by default: Cast shadow, Project texture (tooltip "usecookie") and Cast volumetrics.
  - Values seen: Intensity 0 and 25, Radius 30, Falloff 4, Inner cone 39.07 / 145.14 / 26.04, Outer cone 179.1 / 126.56.
  - The slider handle was at the far right at Intensity 25, Radius 30, Falloff 4 and Outer cone 179.1. That suggests the slider maximums are Intensity ≈25, Radius ≈30, Falloff ≈4 and cones ≈180, each with a minimum of 0. These are **slider** limits; typed values may go past them.
  - The viewport gizmo draws the inner cone solid and the outer cone dashed.
- **Tube light:** Intensity 25, Radius 30 and Falloff 4 (handles at the far right), plus a Control point field at 2,0,0.
- **(user)** Other light types have the same properties, with the same thresholds and the same lower/upper limits. The exception is any extra type-specific property, such as the tube's control point or the spot's cones.
- **Not captured:** the scene-level lighting settings and per-type light count limits.

## 4. Image layer
- **Properties panel, in order:**
  - Origin, Angles, Scale
  - Blend mode (Normal)
  - Effects (+Add / Edit)
  - Tint color (white)
  - Opacity (1)
  - Alignment: 3×3 anchor grid, default centre
  - Puppet Warp: "Edit Puppet Warp" button
  - Materials card: "Advanced Texture Settings / Lighting & Reflections". It was not opened, so the normal map and PBR fields weren't captured.
  - Miscellaneous checkboxes, all off: Perspective rendering, Enable click events, Disable click propagation, Limit iCUE & Chroma to this layer
- **Import dialog:**
  - Format: "High Quality - Uncompressed (RGBA 8888)". The other options weren't shown.
  - Pixel Art Optimization (disables bilinear filtering): off
  - No mip maps: off
  - **Clamp UVs: on**
  - Sprite sheet: off
  - **Adjust wallpaper size and center: on**

## 5. Add Asset dialog
- **Renderables:** Image Layer, Text Layer, Particle System, Sound, Light, Model
- **Utilities:** Solid Layer, Solid Placeholder, Transform, Post-processing Layer, Full Composition Layer, Adjustable Composition Layer, Camera
- **Presets:**

| Category | Presets |
|---|---|
| Abstract | DNA |
| Bubbles | Cartoon, Ocean |
| Clock | Clock, 3D Clock |
| Countdown | Release countdown |
| Ember | beams, large, small |
| Fire | Torch, Wildfire |
| Fireworks | 1, 2, 3 |
| Fog | calm, gust |
| Interactive | Swarm, Cursor trail, Drops, Fireflies |
| Leaves | red, green, red+yellow, red+green, Sakura |
| Lightning | Lightning cloud, Thunderbolt (old), Discharge, Discharge arc, Thunderbolt |
| Light Shafts | corner, radial, linear, Dust motes, 1/2/3 (old) |
| Magic | Charge, Sparkle, Gravitation, Vortex 1, Vortex 2, Glyphs 1, Glyphs 2, Focus, Trinity, Pulse, Powerup, Color sparkle, Vortex orb |
| Rain | perspective, downpour, refractive, splashes, screen drops 1080p, screen drops 4k |
| Smoke | Vapor single, Vapor double, Smoke stream, Smoke cloud, Ash |
| Snow | perspective, flat, storm |
| Spark | Spark |
| Stars | Star field, Star circle, Shooting star |
| Water | Dripping water, Dripping water single, Water droplets, Faucet, Faucet large, Water impact splash |

## 6. Particle system
- **Create templates:** Basic, Follow cursor, Avoid cursor, Turbulence. The default name is "new particle system".
- **Default system:**
  - Renderer: Sprite
  - Emitter: Sphere random
  - Initializers: Lifetime random, Size random, Velocity random, Color random
  - Operators: Movement, Alpha fade
  - Control points: 8 (0–7)
- **Material:** Albedo texture, Overbright 1, Blending Additive, Depth test Disabled, Depth write Disabled, Culling No cull.
- **System:**
  - **Max count 500** (the stats overlay shows "Particle count: 75 / 500")
  - Start time 0
  - Checkboxes, all off: Worldspace, Perspective rendering, Disable color overrides, Disable count overrides, Disable lifetime overrides, Disable size overrides, Disable speed overrides
  - Sprite-sheet Animation mode: Random frame or Sequence
- **Sprite renderer:** orientation is Screen, Upright or Fixed. Fixed adds an Axis field.
- **Sphere random emitter:**
  - Offset 0,0,0
  - Directions 1,1,0
  - Sign 0,0,0
  - Cone 0
  - Distance 32 to 512
  - Control point 0
  - Rate 20
  - Limit to one per frame: off
  - Duration 0, Delay 0, Instantaneous 0
  - Random periodic emission: off
  - Speed 0 to 0
  - Audio response mode: None
- **Initializers:** Lifetime random is 3 to 5 (exponent 1). Color random is white to white (exponent 1).
- **Alpha fade:** fade-in 0.5, fade-out 0.5.
- **Control point:** Offset, Angles, and checkboxes Lock to pointer, Worldspace, Hide gizmo in editor, Copy from parent.
- **Children:** "Add Child" selects an existing particle system as a child.
- **Not captured:** the full add-menu lists (emitter, initializer and operator types) and the hard upper limit on count.

## 7. Performance settings (from the Settings dialog in `onepiecegirls (1–3).png`)
- **Options seen:**
  - FPS: 15, 25 and 30
  - Anti-aliasing: None and MSAA x2, x4 and x8 **(user: MSAA 2x–8x available)**
  - Post-processing: Enabled and **Ultra** (Ultra shows a warning icon)
  - Texture resolution: "High Quality"
- The user's own config at the start of testing was:
  - preset medium, fps 15, msaa none
  - postprocessing enabled, volumetrics medium, shadows medium
  - reflection true, resolution full
- **Texture resolution test: not valid.**
  - All four screenshots show "High Quality", and their sharpness is identical to within about 1%.
  - Task Manager was on the Processes tab, so it shows RAM (WE about 150 MB + 640 MB), not GPU memory.
  - Needs a redo: Low, Medium and High, each applied with OK, with Task Manager on Performance → GPU (Dedicated GPU memory).

## 8. Multi-monitor (user)
- **Same wallpaper on both monitors:** audio plays **once**.
- **Different wallpapers:** both play their audio.
- **Per-monitor properties:** yes, the same wallpaper can have different user-property values on each monitor. Our app has a "sync properties" option instead.
- **Render once vs twice:** still unmeasured. The earlier GPU test hit saturation.

## 9. Rain refraction (Kamado Tanjirou, `tanjiro-zoomin*.png`)
- **Inconclusive.**
  - The drop in `tanjiro-zoomin.png` shows a more saturated red region that doesn't match its surroundings, so some displacement or inversion is happening, but no feature could be matched inside and outside the drop.
  - `tanjiro-zoomin2.png` shows no clear drop.
- Needs a tighter zoom on one drop, next to an asymmetric feature such as a lightning bolt or the hand.

## 10. Effects (second batch of recordings, 17:36–18:01)
The recordings show only the Properties panel, so no canvas visuals were captured. Slider min/max were found by dragging to the end stops. No step size is visible; values show up to 2 decimals, so the sliders are continuous.

- **Shared effect UI:**
  - Every shader property has a gear with Bind User Property, Bind Timeline Animation and Bind Script.
  - A texture's gear has Bind User Property and Bind Album Cover.
  - The texture "Manual Editing" menu has Paint, Import Texture File and Export Texture File.
  - Opacity mask options: Paint, a folder button, Manual Editing.
  - Effects have a **Composite** option: Normal, Blend, Under, Cutout. Choosing Blend adds an Alpha slider (0–2, default 1).
- **Shine:**
  - Options:
    - Edges: 2/3/4/5, default 4
    - Quality: 4/8/15/30, default 8
    - Kernel size: 13x13/7x7/3x3, default 13x13
    - Blend mode: default **Linear dodge**
    - Noise: on
    - Copy background: off
  - Textures: Opacity mask, and Albedo (grey cloud noise).
  - Shader:

  | Property | Default | Range |
  |---|---|---|
  | Noise amount | 0.4 | 0.01 to about 0.97 (full max not confirmed) |
  | Noise scale | 3 | 0.01–10 |
  | Noise speed | 0.15 | max 1 (min not seen) |
  | Ray threshold | 0.5 | 0–1 |
  | Color | white | – |
  | Direction | 0 (needle up) | angle dial, signed degrees, about -180 to 180 |
  | Ray intensity | 1 (mid-track, so max about 2) | – |
  | Ray length | [unreadable] | – |

- **Depth parallax:**
  - Quality: default "Occlusion Performance" (list not opened).
  - Textures: Depth map (with a Generate button) and Opacity mask.
  - Shader:
    - Center: 0–1 (1 at start)
    - Depth X/Y: linked, 0.01–2, default 1
    - Perspective rendering: -5 to 5 (1 at start)
- **Unnamed effect** (header scrolled off; possibly a blur or shadow effect):
  - Options:
    - Kernel size: 13x13
    - Blend mode: default Normal
    - Composite: default Normal
    - Blur alpha: on
    - Monochrome: on
  - Shader:
    - Scale X/Y: linked, 0.01–2, default 1
    - Color: white
    - Offset X/Y: linked, -10 to 10, default 0
- **Pulse:**
  - Options:
    - Audio response: None
    - Blend mode: Linear dodge
    - Pulse alpha: off
    - Pulse color: on
  - Textures: Noise, and Opacity mask.
  - Shader:
    - Pulse amount: 1 (mid-track)
    - Pulse bounds: 0, 1
    - Noise amount: 0
    - Noise speed: 0.5
    - Pulse phase: 0
    - Power: [unreadable]
- **Blur:** not captured. **Add-effect list:** not captured.

## 11. Text layer
- **Properties:**
  - Text: default "Text Layer"
  - Color: white
  - Opacity: 1
  - Font: default **Arial**, with an Import button
  - Opaque background: off
  - **Point size: default 32, range 1–96**
- **Effect padding:** X/Y, default 32, range 0–128.
- **Font list:** bundled fonts first, then system fonts.
  - Bundled: 8-bit Operator+ 8, Alcubierre, Atami, Blackout 2AM, Cursed Timer ULiL, Kust, lazer84, monofur, Noto Sans, … OpenSticks, Roboto Mono, Segment7, Spin Cycle 3D OT, Summer85, Twemoji Mozilla
  - System: Arial, Calibri, Cambria, Comic Sans, Consolas, Sans Serif, Segoe, Verdana
  - There may be a gap after Noto Sans.
- **Font effects:**
  - Smooth Font Scaling (MSDF): on by default. It is forced on while Outline, Blur or Drop shadow is on.
  - Outline: off by default.
    - Thickness: default 4, max 32
    - Color: black
  - Blur: off by default.
    - Size: 1–32, default 1
  - Drop shadow: off by default.
    - Size: default 6, max 32
    - Opacity: 0–2, default 1
    - Offset: X/Y linked, default 4/4, max 16
    - Color: black
- **Alignment:**
  - Horizontal: left / center / right, default center
  - Vertical: center / top / bottom, default center
  - Spacing: X/Y, default 0; negative values allowed
  - Limit width: off

## 12. Solid layer
- It is an Image Layer backed by `models/util/solidlayer.json`, with a **Resolution** field (1920×1080).
- The other fields match an image layer: Tint, Opacity, 3×3 Alignment.
- Miscellaneous defaults: **Enable click events is ON** (for a plain image layer it is off), Perspective rendering off, Disable click propagation off, Limit iCUE off.
- The canvas wasn't captured, so there is no visual of a solid layer with a blend mode.

## 13. Wallpaper "Image filter" (wallpaper properties dialog)
- Default None. The presets, in order:
  1. Vibrant Contrast
  2. Vibrant Darkness
  3. Color Boost
  4. Shadow Boost
  5. Moon Light
  6. Late Night
  7. Desert
  8. Midday Sun
  9. Sunrise
  10. Honey
  11. Autumn
  12. Sepia Modern
  13. Western
  14. Sunset
  15. Color Crush
  16. Amber
  17. Toxic Green
  18. Daisy
  19. Emerald
  20. Overcast
  21. Blueshift
  22. Beach
  23. Studio Lighting
  24. Wasteland
  25. Retro Handheld
- The dialog also has "Show color options" and the preset buttons Load, Save, Apply to all Wallpapers, Share JSON and Reset.

## Not captured / still open
- Shine, Depth parallax and Blur slider min/max/step
- Timeline: interpolation, loop modes, keyframe snapping
- Text layer: font, size limits, anchor
- Solid-colour layer with a blend mode
- Image-layer material fields: lighting, normal map, PBR
- Scene lighting settings and light-count limits
- Texture resolution and VRAM
- Rain drop direction
