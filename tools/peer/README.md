# Wallpaper Engine ground-truth captures

Reference captures from real Wallpaper Engine on Windows, for checking Open Wallpaper Engine's scene renderer.

- **WE version:** 2.8.0.42 (`wallpaper64.exe`)
- **Capture display:** display 2, 1920×1080 at 100% scaling. The primary display is 1536×864 logical (125%).
- **Base settings** (from `config.json`, not a fresh install): preset medium, post-processing enabled, volumetrics medium, shadows medium, reflections on, texture resolution full, MSAA none. FPS was set to 30 for the captures (the user's setting is 15).
- **Method:** `shoot.ps1` edits `config.json` when a setting differs, restarts WE, applies the wallpaper with `wallpaper64 -control openWallpaper -monitor 1`, waits 10 s, then takes two stills 2 s apart and a 3–5 s ffmpeg gdigrab clip at 30 fps. The Windows taskbar covers the bottom 48 px of every capture.
- `config.backup.json` is the user's original WE config, restored after the captures.
- `pkg.ps1` extracts a file from a `scene.pkg`. `analyze.py` measured the parallax shift, the setting diffs and the puppet motion.

| Workshop ID | Title | Rating | Folder(s) | Settings changed | What it checks |
|---|---|---|---|---|---|
| 2963872291 | Pixelart Alice City | Everyone | `default` | — | Media widget with no media playing (grey music-note placeholder, shown) |
| 3270035750 | One piece girls | Mature | `default` | — | Tube-light bands |
| 3352730400 | Hinata Uzumaki | Questionable | `vol_disabled`, `vol_low`, `vol_medium`, `vol_high` | volumetrics | Spot-light volumetric cone (off only when disabled; low, medium and high look identical) |
| 2764281221 | 2B Nier Automata | Everyone | `default` | — | Rotated layers (only flares: z=-0.744 with mirrored scale, and z=+0.521). Rotation direction inconclusive |
| 3245833232 | Kamado Tanjirou | Everyone | `default` | — | Particle rain sprites. `still2.png` is only 125 KB, so it may be a transition frame |
| 3802047741 | Sakura Haruno by NaughtyfeetAI | Questionable | `default` (`mouse_left/center/right.png`) | — | Mouse parallax: -82 px at centre, -164 px at the right edge, about -2 px vertical drift |
| 2515150033 | Knight (Puppet Warp PBR Demo) | Everyone | `default` | — | Puppet warp and PBR (strong motion) |
| 2321732083 | Cyberpunk Samurai | Everyone | `default` | — | Puppet animation (figure looks static; only rain and haze move) |
| 3455121165 | Solar system | Everyone | `shadowsOff_volOff`, `shadowsHigh_volHigh`, `compare_off_left_high_right.png` | shadows, volumetrics | No visible difference |
| 3159348391 | PaRappa the Rapper | Everyone | same as above | shadows, volumetrics | The camera animates, so the frames aren't comparable |
| 3378346807 | 3D Snowflakes | Everyone | same as above | shadows, volumetrics | High adds a light shaft, glowing flakes and cast shadows |
| 3734636606 | More Physics | Everyone | `default` | — | Physics scene |
| 3657770939 | WE_Phys α_01 | Everyone | `default` | — | Physics scene |

Not captured: the editor UI, fresh-install Settings defaults, VRAM use by texture resolution, two-monitor audio and per-monitor properties. With the same wallpaper on two monitors, WE's 3D engine use was 89% on one and 93% on two; the GPU was saturated, so that result is inconclusive.
