# SceneScript plan

**Status: 2026-09-26, WP0 (from evidence) and WP1–WP11 done: the app runs every scene's scripts on `SceneScriptRuntime`, one per display, and the legacy `AudioReactiveScriptEngine` scripting is deleted. WP12 (timelines and animation APIs) is next.** Roadmap area 4 (Phase 6). This document is the evidence and the plan for making our SceneScript runtime run *every* script users have. It replaces §5 and P5 of [`progress-snapshot.md`](progress-snapshot.md) as the source of truth for scripting.

Sources, in order of authority:

1. **WE's own files** in the CrossOver install (`…/steamapps/common/wallpaper_engine`):
   - `ui/dist/monaco/autocomplete/lib.sceneScript.d.ts`: the editor's *official* type declarations, "VERSION 2.8" (2571 lines). Every member in §1 comes from it unless marked otherwise.
   - `ui/dist/monaco/autocomplete/lib.es5 … lib.es2019.*.d.ts`: the ES library level the editor offers (ES2019).
   - `bin/scenescript64.dll` (V8 embedded, version string `2.8.42.SceneScript`) and `wallpaper64.exe`: the strings name every bound member, callback and runtime error message. Quoted in §1.8.
   - `assets/scripts/jsclasses/baseclasses.js` and `assets/scripts/jsmodules/{wemath,wevector,wecolor}.js`: WE's JS prelude. Byte-identical to our `Vendor/we-assets/scripts`.
2. **Official docs**: docs.wallpaperengine.io/en/scene/scenescript/ and all 57 reference, event, module and tutorial pages. Text copies and a member-by-member reference with sources (`we-scenescript-api.md`) are in `/Volumes/980Pro/dd-scenescript/spec/`, next to the corpus.
3. **The local corpus** (§2): 281 distinct scripts, 508 attachment sites, 43 wallpapers and asset packs.
4. **linux-wallpaperengine** (LWE) as a second implementation to compare against.
5. **Measurements** on JavaScriptCore on this Mac (§4.6).

Where WE's behaviour is not documented, §1.9 settles it from WE's binaries and marks what remains a best guess. Nothing here is guessed silently.

---

## 1. The WE SceneScript specification

### 1.1 Language and modules

- Each script is an **ES module** run by **V8** (`scenescript64.dll` embeds V8; `V8.js`, `v8::Context` strings). The docs promise ECMAScript 2018, and the editor type-checks against the ES2019 library; V8 accepts newer syntax too. JavaScriptCore on macOS 13+ covers all of it (verified: static class fields, private fields, `?.` and `??`).
- Modules the runtime resolves: `'WEMath'`, `'WEVector'`, `'WEColor'` (from `scripts/jsmodules/`, `import * as WEMath from 'WEMath'`). Nothing else can be imported.
- Exports the engine reads: the callbacks in §1.2, `scriptProperties` (from `createScriptProperties()…finish()`), and `__workshopId` (the editor inserts it; asset paths depend on it).
- Global scope code runs **once**, when the module is evaluated. Some calls are *only* legal there and others are *illegal* there (DLL error strings):
  - only at global scope: `engine.registerAudioBuffers`, `engine.registerAsset`, `requestFeatures`.
  - illegal at global scope: `thisLayer`/`thisObject`/`thisScene` member access ("`<member> cannot be accessed from global scope`"), `engine.setTimeout`/`setInterval` ("cannot be called from global scope"), clearing timeouts, every `localStorage` call.
- WE's `baseclasses.js` defines `Vec2`, `Vec3`, `Vec4`, `Mat3`, `Mat4`, `MediaPlaybackEvent`, `IModelData`, `createScriptProperties` and `_Internal` (`updateScriptProperties`, `convertUserProperties`, `stringifyConfig`). The native side calls `_Internal.*` to inject script-property values and user properties, so we must load that file unmodified and call the same hooks.

### 1.2 Callbacks (`IComponent`)

| Callback | When (per the d.ts) | Argument / return |
|---|---|---|
| `init(value)` | once, after the object the script belongs to was created | current value of the bound property; **returns the value to apply** |
| `update(value)` | every frame, for every script that exports it | current value of the bound property; **returns the new value** |
| `destroy()` | just before the object is destroyed | |
| `resizeScreen(size)` | on every resolution change; **not** at startup | `Vec2` in pixels |
| `applyUserProperties(changed)` | once initially at load, then whenever the user changes properties | object with **only the changed** properties (`hasOwnProperty` pattern) |
| `applyGeneralSettings(changed)` | once initially, then on changes | only changed settings (currently only `language`) |
| `cursorEnter/Leave(event)` | cursor enters/leaves the object's bounds | `CursorEvent` |
| `cursorMove(event)` | cursor moved | `CursorEvent` |
| `cursorDown/Up(event)` | pressed / released over the object | `CursorEvent` |
| `cursorClick(event)` | pressed and released on the same object | `CursorEvent` |
| `mediaStatusChanged(e)` | media integration turned on/off | `{enabled}` |
| `mediaPlaybackChanged(e)` | play/pause/stop | `{state}`; `MediaPlaybackEvent.PLAYBACK_STOPPED/PLAYING/PAUSED` = 0/1/2 |
| `mediaPropertiesChanged(e)` | track metadata changed | `{title, artist, subTitle, albumTitle, albumArtist, genres, contentType}` |
| `mediaThumbnailChanged(e)` | artwork changed | `{hasThumbnail, primaryColor, secondaryColor, tertiaryColor, textColor, highContrastColor}` (Vec3) |
| `mediaTimelineChanged(e)` | position changed (only some players) | `{position, duration}` |
| `animationEvent(e, value)` | *not in the d.ts*; named in the DLL | `AnimationEvent {name, frame}` (puppet/timeline events), plus the property value; its return is applied (§1.9 P3) |
| `cursorHitTest` | *not in the d.ts*; named in the DLL | never dispatched by `wallpaper64.exe` (§1.9 P7) |

`CursorEvent`: `worldPosition: Vec3`, `localPosition: Vec3` ("only X and Y are supported"), `hitBox?: String` (the puppet hit box's name); `screenPosition` and `button` are commented out as "NOT USED" (`button` is always 0). The DLL sets `button` (0), `worldPosition`, `localPosition` and, for a puppet hit box, `hitBox`; never `screenPosition`. The docs say `cursorClick` follows `cursorDown` and `cursorUp` on the same object.

**Values in and out** (docs and d.ts):

- `init(value)` and `update(value)` receive the property's *current* value. The docs' own example `value.y += engine.frametime * 100; return value;` accumulates.
- Whatever they return is applied. Returning nothing leaves the property unchanged.
- A number returned for a vector property is broadcast: returning `2` on Scale gives `Vec3(2, 2, 2)`.
- Colours are normalized `Vec3`s (0…1).
- In `scene.json`, a bound property is `{value, script, scriptproperties?, user?, animation?}`. All of these can be present together. A `scriptproperties` entry is a literal (colours as `"r g b"`) or a user binding `{user, value}` (38 such entries in the corpus).
- Script-property values are applied only to keys the script declared. A string becomes a `Vec3` when the default is one (`_Internal.updateScriptProperties`).
- `init` runs "before any other functions run" (localStorage tutorial).

The d.ts header states the binding model: a script is bound to **one property**; `update` should return a value of that property's type; *assigning* to `thisLayer.<prop>` is allowed "if a script needs to modify multiple properties"; the Visibility property is "typically used" for general-purpose scripts.

### 1.3 Globals

- `thisLayer: ILayer` — the layer the script runs on.
- `thisObject: IThisPropertyObjectBase` — "the object this property is bound to":
  - the layer, for layer properties;
  - the `IEffect`, for `effects[i].visible` (the corpus does `thisObject.visible = event.hasThumbnail` 44 times);
  - the `IMaterial`, for material constants, whose shader constants are its members by name (`thisObject.multiply`).
  - Its `getAnimation()` with no name returns "the animation object bound to the current property": the property's own keyframe timeline. For example, `multiply` in 2134765860 carries `animation {mode: single, startpaused: true}`, and its script calls `thisObject.getAnimation().play()` on a thumbnail change.
- `thisScene: IScene`, `engine: IEngine`, `input: IInput`, `console: IConsole`, `localStorage: ILocalStorage`, `shared: Object` (one object shared by every script in the scene), `renderContext` (empty interface).

### 1.4 `IEngine`

| Member | Kind | Notes |
|---|---|---|
| `frametime`, `runtime`, `timeOfDay` | number | seconds since last frame; seconds since start; fraction of the day 0…1 |
| `screenResolution`, `canvasSize` | Vec2 | screen pixels; scene (canvas) size |
| `userProperties` | object | converted by `_Internal.convertUserProperties`: `color` → `Vec3`, `usershortcut` → `{isbound, commandtype, file}`, others their value |
| `isRunningInEditor()`, `isPortrait()`, `isLandscape()`, `isDesktopDevice()`, `isMobileDevice()`, `isWallpaper()`, `isScreensaver()` | **functions** | |
| `AUDIO_RESOLUTION_16/32/64` | 16/32/64 | there is **no** 128 ("Resolution must be either 16, 32 or 64.") |
| `registerAudioBuffers(res)` | → `AudioBuffers {left, right, average: Float32Array}` | global scope only; the arrays are live and refreshed each frame |
| `registerAsset(file, precache)` | → `IAssetHandle` | global scope only |
| `setTimeout(cb, ms)`, `setInterval(cb, ms)` | → **Function** | "Returns a new callback that can be used to stop the timeout". Not callable at global scope. `clearTimeout` is commented out of the d.ts as "Not implemented. Use returned function to clear." (the DLL string is the cancel function's internals). |
| `openUserShortcut(name)` | → Boolean | only inside cursor callbacks, once per click (DLL errors) |
| `isObjectValid`, `requestFeatures` | | DLL only; undocumented |

### 1.5 `IInput`, `ILocalStorage`, `IConsole`

- `input.cursorWorldPosition: Vec3` (scene space), `cursorScreenPosition: Vec2`, `cursorLeftDown: Boolean`.
- `localStorage.set(key, value, location?)`, `get(key, location?)`, `delete(key, location?) → Boolean`, `clear(location?)`. `LOCATION_GLOBAL = 'global'` (shared by all instances of the wallpaper), `LOCATION_SCREEN = 'screen'` (per instance on multi-monitor setups), **default `'screen'`**. There is no default-value argument; a missing key reads as `undefined`/`null`. Keys must be strings (DLL: "key not a string"). The docs cap it at **100 KB per wallpaper**.
- `console.log(...)`, `console.error(...)`. They go to the editor's Log tab, or to `wallpaper_engine/log.txt` with the log level set to Verbose.

### 1.6 `IScene`

- Lookup: `getLayer(name|index|id)`, `getLayerByID(id)`, `getLayerCount()`, `enumerateLayers()`, `getLayerIndex(layer|name)`, `getInitialLayerConfig(layer)`.
- Structure: `createLayer(path|IAssetHandle|config|IModelData)`, `destroyLayer(layer)` ("removed after all scripts on that frame updated"), `sortLayer(layer, index)`, `createModelData(config)` / `destroyModelData`.
- Camera: `getCameraTransforms()` / `setCameraTransforms({eye, center, up, zoom})`, `fov`, `nearz`, `farz`.
- `getAnimation(name?)` from any layer.
- Scene settings (read/write): `bloom`, `bloomstrength`, `bloomthreshold`, `clearenabled`, `clearcolor`, `ambientcolor`, `skylightcolor`, `camerafade`, `camerashake`, `camerashakespeed`, `camerashakeamplitude`, `camerashakeroughness`, `cameraparallax`, `cameraparallaxamount`, `cameraparallaxdelay`, `cameraparallaxmouseinfluence`.

`createLayer` config objects may carry `name`, `origin`, `angles`, `scale`, `text`, `color`, … and `model` (IModelData); the doc example passes `thisLayer.origin` directly.

### 1.7 Layers and their parts

`ILayer` is the union of every layer kind; members that don't apply to a kind are inert.

- **Common**: `origin: Vec3`, `angles: Vec3` (**degrees**), `scale: Vec3`, `parallaxDepth: Vec2`, `name`, `visible` ("currently only for image layers and particles"), `getTransformMatrix()`, `rotateObjectSpace(angles)`, `lookAt(center, up?)`, `lookAtYaw(center, up?)`, `setParent(parent, [attachment], adjustTransforms?)`, `getParent()`, `getChildren()`, attachments (`getAttachmentIndex/Matrix/Origin/Angles`), `getAnimation(name?)`.
- **Effect layer** (image/text): `getEffect(name|index) → IEffect`, `getEffectCount()`, `transformAttachmentToTexture(...)`, `size: Vec2` (read-only), `perspective`, `solid`.
- **Image**: `alpha`, `color: Vec3`, `alignment`, `getTextureAnimation() → ITextureAnimation`, `getVideoTexture() → IVideoTexture`, animation layers (`getAnimationLayerCount/getAnimationLayer/createAnimationLayer/playSingleAnimation/destroyAnimationLayer`), bones (`getBoneCount`, `get/setBoneTransform`, `get/setLocalBoneTransform/Angles/Origin`, `getBoneIndex`, `getBoneParentIndex`, `applyBonePhysicsImpulse`, `resetBonePhysicsSimulation`), blend shapes (`getBlendShapeIndex/Weight`, `setBlendShapeWeight`).
- **Text**: `text`, `color`, `alpha`, `opaquebackground`, `backgroundcolor`, `pointsize`, `font`, `padding`, `horizontalalign`, `verticalalign`, `anchor`, `limitrows`, `maxrows`, `limitwidth`, `maxwidth`.
- **Sound**: `play()`, `stop()`, `pause()`, `isPlaying()`, `volume`.
- **Particle system**: `play/pause/stop/isPlaying`, `emitParticles(count?)`, `instance: {alpha, size, count, speed, lifetime, rate, colorn, controlpoint0…7}`.
- **Model**: `perspective`, `rootmotion`, animation layers. **Camera**: `fov`, `zoom`.
- `IEffect`: `visible`, `name`, `getMaterial(i) → IMaterial`, `getMaterialCount()`, `setMaterialProperty(name, number|Vec2|Vec3|Vec4)` ("on all materials of this effect that have a matching property"), `executeMaterialFunction(name)`, `getAnimation()`.
- `ITextureAnimation`: `frameCount`, `duration`, `rate`, `play/pause/stop/isPlaying`, `getFrame/setFrame`, `join`.
- `IVideoTexture`: `duration`, `rate`, `loop`, `play/pause/stop/isPlaying`, `getCurrentTime/setCurrentTime`, `addEndedCallback`.
- `IAnimation` (timelines): `fps`, `frameCount`, `duration`, `name`, `rate`, `play/pause/stop/isPlaying`, `getFrame/setFrame`. `IAnimationLayer` adds `blend`, `visible`, `addEndedCallback`.

Beyond the d.ts, any scriptable `scene.json` key of a layer reads and writes as a member. `wallpaper64.exe` binds keys such as `pointsize`, `maxwidth`, `sortorder` and `solid` by their JSON names, and the corpus writes `thisLayer.maxwidth` and `thisLayer.pointsize`. The object model should therefore be generated from the typed field list (`SceneValueFields`), not hand-written per member.

The math classes have quirks that only WE's own code reproduces, so load `baseclasses.js` unmodified instead of reimplementing it:

- `Vec2.perpendicular()` is `(y, -x)`;
- `new Vec4(x, y, z)` sets `w = z`;
- `equals` uses an epsilon.

Value semantics: vector getters return **copies**. In the corpus, every in-place write such as `thisLayer.scale.x = …` is commented out (4 scripts), so authors learned that it has no effect. Assigning a new vector is the way to write.

### 1.8 Runtime behaviour visible in WE's binaries

From `scenescript64.dll`: `Script execution has been interrupted because a dead lock was detected.` (WE has a watchdog that terminates long-running scripts), `Error: ` / `Log: ` / `, col ` / ` (line ` (the log format), `JS base class error: %s`, `Cannot execute user command outside of cursor callbacks.`, `Cannot execute more than one user command per cursor click.`, and the storage file magic `LSKV0001`. From `wallpaper64.exe`: `Invalid parent configuration.`, `bin/scenestorage/` (where `localStorage` persists) and `LSBK0001`.

### 1.9 Semantics resolved from evidence

WE cannot run on this Mac, not even under CrossOver, so the probes WP0 planned are impossible. Each question is settled from WE's binaries instead: `scenescript64.dll` (the DLL) and `wallpaper64.exe` (the exe), disassembled with `llvm-objdump`, following references from the strings and vtable slots into the code. Where the binaries are silent, the docs, the d.ts and the corpus decide. Addresses are virtual addresses. The disassembly and the xref scripts are in `/Volumes/980Pro/dd-agentSS1/research/` (`ssx.asm`, `wp.asm`, `xref2.py`).

Two structures anchor the evidence:

- The DLL's callback name table (`0x1819a3ee0`) fixes each callback's index and bit: 0 `init`, 1 `update`, 2 `resizeScreen`, 3 `destroy`, 4 `applyUserProperties`, 5 `applyGeneralSettings`, 6 `animationEvent`, 7 `cursorHitTest`, 8–13 cursor, 14–18 media.
- The DLL engine vtable (`0x1819a3f78`): `+0x40` is the callback dispatcher (`0x18164e4d0`), `+0x48` the per-frame tick (`0x18164f800`). In the exe, `0x140177ad0` sends one callback to every script component of the scene, in list order.

| # | Question | WE's behaviour | Evidence | Status |
|---|---|---|---|---|
| P1 | Order in a frame | cursor events → pending user-property changes and `applyUserProperties(changed)` → media events → timeline animations and `animationEvent` → engine tick (audio buffers refilled, then timers) → `update` for every script in list order. Timers run per script over a snapshot of its list; an interval is **reset** to its period when it fires (so at most once per frame); a timeout is removed after firing. | exe frame `0x1401802d5`–`0x1401802e5`: cursor `0x140189e10`, then `0x140171440` (`applyUserProperties` via `0x1401731d0` at `0x140171a8d`, media from `0x140171b7c`, `animationEvent` at `0x1401726e7`, `tick` at `0x140172755`, `update` at `0x14017276f`); DLL tick refreshes audio at `0x18164f84d`, timers `0x18164f9b0`–`0x181650346` | evidence. Best guess: list order is scene creation order; `destroyLayer` applies after all updates (docs); where `resizeScreen` falls (we put it first) |
| P2 | What `value` holds | the property's live value at the call, read natively; animations are evaluated earlier in the same frame, so an animated property shows this frame's animated value; otherwise the last applied value (accumulators work) | DLL `0x18164e693` → `0x1816208e0`; corpus `155fe61a17a0` (`value += …`) | evidence; best guess for how an animation and a script combine on one property |
| P3 | Returning an unusable value | converter switches on the property type and type-checks the return; a failed check leaves the property unchanged, silently. Its nine cases (jump table `0x181621474`): 0 Int32 (`IsNumber`, then `ToInt32`), 1 Vec2, 2 Vec3, 3 Vec4 (an object whose x/y/z/w are all numbers, else a bare number broadcast; nothing else, so `"1 2 3"` is rejected), 4 float (`IsNumber`), 5 string (anything but `null`/`undefined`, through `ToString`; an oddball-kind check at `0x181621376` skips those two), 6 and 8 flag (`IsBoolean` only, `0x180016fe0`: a number is rejected), 7 inert. `NaN` passes the number check and **is written**. Flag bit 4 multiplies float and Vec3 values by π/180 (angles). Only `init`, `update` and `animationEvent` returns are applied; `animationEvent(event, value)` receives the value too | DLL converter `0x181620e10`, skip path `0x181621458`, applied-return check `0x18164f719` | evidence; which properties use the Int32 and inert cases is not known (WP8 treats every numeric property as float) |
| P4 | A script that throws | the error is logged with line and column, the call's return is not applied, and **that callback is never called again for that script**; its other callbacks keep running. Timer and ended callbacks are logged but never disabled | DLL error handler `0x181651ab0` sets the callback's bit in the script's mask (`orl %r8d,0xdc(%rax)` at `0x181651bff`, only for error-level messages, `0x181651ba6`); the dispatcher skips masked callbacks (`testl %eax,0xdc(%r13)` at `0x18164e51c`); timers call with bit 0 (`0x1816501bc`, `0x181650943`) | evidence (contradicts the earlier "keeps running" default and LWE) |
| P5 | The watchdog | **15 s** per outermost script call (steady clock + `0x37E11D600` ns, reset when the nesting depth returns to 0). When it fires: `TerminateExecution`, an engine-wide flag, and the "dead lock" message logged once naming the script. From then on **every** callback, timer, ended callback and new script is skipped until the engine is reset (the wallpaper reloads) | DLL `0x1816477c8` (constant), `0x181647908` (flag), `0x181653e3d` (message), skips at `0x18164e529`, `0x18164f9d2`, `0x181650743`, `0x18164bfbc`; reset `0x18164bcb0` | evidence |
| P6 | `update` on hidden layers | yes: the broadcast checks the exported-callback bit, the component state and a scene flag, never visibility | exe `0x140177ad0`; corpus `03f0db0a6dff` hides its layer in `init` | evidence |
| P7 | Who gets cursor events | The cursor pass (exe `0x140189e10`) walks the objects from the top of the draw order down. It tests only `solid` objects (flag 0x2000; **solid is the default**, the object constructor sets 0x2001 at `0x1401ddc72`), and only image and text layers take the quad test (types 1 and 4; models test their mesh bounds). The quad is `size` around the world translation plus the camera-parallax offset of the object itself (`0x14018a0b3`), with no alpha test; edges count (`0x14019d5a0`). Hidden objects are hit and get events. Per object, all its events before the next object's: enter if new, move if the cursor moved, down or up when the button changed, then a press marks it pressed and a release on a pressed object clicks. A miss sends up to a pressed object on release (no click) and leave to a hovered one. While a pressed object is held, only pressed objects get moves (no enter or leave anywhere). Events go on to the objects below unless the hit object has `disablepropagation` (0x4000) and it and its parents are visible (`0x140185010`). Only the scripts of the hit object get them. The event object is `{button: 0, worldPosition, localPosition, hitBox?}` (DLL `0x18164ec5f`). `cursorHitTest` is never dispatched: the pass sends only indices 8–13 | exe `0x140189e10`–`0x14018aaa6`, `0x14019dbb0`, `0x14019d5a0`, `0x140185010`, property table `0x1401e122b` (`solid` 0x2000, `disablepropagation` 0x4000), constructor `0x1401ddc72`; DLL `0x18164ec5f`; docs (Solid) | evidence. Best guess: scene-level scripts get none (the pass also matches scripts whose field +0x8 is null, which could not be tied to anything) |
| P8 | Load order | module evaluation → `init` in list order, each script getting the current media state right after its `init` → `applyUserProperties` (all properties, once, at load) → `applyGeneralSettings` | exe `0x140172830` moves each new component through states 0→1→2, calls `init` (`0x140172bd0`), then media 14–18; `applyUserProperties` (`0x1401742e2`) only reaches state-2 components that export it (`0x1401734e4`); docs: "called once initially when the wallpaper is loaded"; corpus `105f9d26fe76` uses in `applyUserProperties` what `init` set | evidence for init first; best guess that the first call carries every property (docs), and that scripts created at runtime get no initial `applyUserProperties` (`0x140172830` never sends index 4) |
| P9 | `thisObject` for `instanceoverride.*` and `general.*` | the particle system; the scene | none of the 29 corpus bindings on these fields touches `thisObject` or `thisLayer`, so it cannot be observed | best guess, harmless either way |

WE's exact global-scope messages (DLL `.rdata`): `registerAudioBuffers can only be called from global scope.`, `registerAsset can only be called from global scope.`, `requestFeatures can only be called from global scope.`, `setTimeout cannot be called from global scope.`, `setInterval cannot be called from global scope.`, `timeout cannot be cleared from global scope.`, `<member> cannot be accessed from global scope.`, and `Resolution must be either 16, 32 or 64.`

### 1.10 linux-wallpaperengine as a reference

LWE (github.com/Almamu/linux-wallpaperengine, `src/WallpaperEngine/Scripting/`; copies in `dd-scenescript/spec/lwe/`) added scripting in May–June 2026.

- **Engine:** QuickJS with real modules (`JS_EVAL_TYPE_MODULE`), one module per bound property.
- **Frame:** `tick()` runs the intervals and timeouts, then every `update(value)`. The value passed in is the last converted result, and an exception skips that frame's result.
- **Supported:** `thisLayer` is a generic property bag. Also `engine.frametime/runtime/timeOfDay/setTimeout/setInterval`, `input.cursor*`, `thisScene.getLayer` plus scene properties, `console`, `createScriptProperties`, WEMath/WEColor, Vec2/3/4, `shared`, and media events with hard-coded thumbnail colours.
- **Missing:** `registerAudioBuffers`, `createLayer`, cursor callbacks, `applyUserProperties`, `resizeScreen`, the effect, material, animation, particle and sound APIs, and the global-scope rules. `localStorage` is a non-persistent stub.

It confirms the chaining and timers-before-updates choices. It is not an API target: WE's d.ts and `baseclasses.js` are.

---

## 2. The corpus

**Location:** `/Volumes/980Pro/dd-scenescript/corpus` (outside the repo).

- `extract.py` (one level up) reads `scene.json` from disk or from `scene.pkg` (PKGV header, entry table) plus every other `.json` in the wallpaper. It walks all JSON and records every object that has a string `script`.
- Each site is attributed to wallpaper, file, object id, name, kind and field path, with `value`, `scriptproperties` and `user` recorded.
- `scripts/<sha1-12>.js` holds each distinct source, `index.json` holds every site, `api-usage.json` and `per-script.json` come from `analyze.py`.

**Size.**

- Libraries: 52 Workshop items plus 97 in OpenWallpaperStorage. One item is in both.
- 93 scenes. 43 items have scripts: 36 scenes and 7 editor asset packs (`assets.json`, category "Asset", which users import into their own scenes).
- **508 attachment sites and 281 distinct scripts.**
- One web wallpaper ships 64 `.js` files; they are web JS, not SceneScript, and are out of scope here.
- The earlier snapshot counted 184 scripts in 18 wallpapers. The Workshop folder more than doubled the sample.

**Language.**

- All 281 parse as ES modules (JSC `checkModuleSyntax`) except one: `8bb9b9a54120`, a text-layer `visible` script in 3802509485 with a string literal broken across two lines. WE can't compile it either, so the right behaviour is to log it once and keep the authored value.
- `'use strict'`: 272 scripts. `let`/`const`: 226. Arrow functions: 19. Spread: 5. Template literals: 3. `??`: 1.
- None use classes, async/await, Promises, generators, `export default`, `export {…}` or re-exports.
- Imports are only `import * as X from 'WEMath' | 'WEColor' | 'WEVector'` (18 scripts).
- `Date`: 62 scripts (clocks). `Math.random`: 7.

**Where scripts attach** (sites):

| Field | Sites | Typical callbacks and APIs |
|---|---|---|
| text `text` | 135 | `update` (113), `mediaPropertiesChanged` (33), `scriptProperties` (90) |
| effect constant (`effects[i].passes[j].constantshadervalues.*`) | 86 | `update` (64), `init` (28), `mediaThumbnailChanged` (30), `thisObject.getAnimation` (22) |
| `visible` | 70 | `update` (50), `init` (28), `applyUserProperties` (26), `thisScene.getLayer` (24), `mediaPlaybackChanged` (23), cursor (15), `createLayer`/`sortLayer` (3) |
| `origin` | 56 | `getLayer` (32), `init` (31), `applyUserProperties` (25), `update` (23), cursor (20) |
| `effects[i].visible` | 46 | `mediaThumbnailChanged` (45), `thisObject.visible` (44), `createLayer` (1) |
| `alpha` | 43 | `update` (35), `thisObject.getAnimation` (8) |
| `scale` | 26 | `update` (24), `cursorEnter/Leave` (8 each) |
| particle `instanceoverride.*` | 22 | rate 12, alpha 8, colorn 1, lifetime 1 |
| `angles` | 18 | `update` |
| `color` | 4 | |
| `general.bloomstrength`, `general.camerashake` | 1 each | scene-level fields can be scripted too |

**Exports** (scripts / sites / wallpapers):

| Export | Scripts | Sites | Wallpapers |
|---|---|---|---|
| `update` | 213 | 357 | 43 |
| `__workshopId` | 127 | 268 | 31 |
| `init` | 79 | 115 | 23 |
| `scriptProperties` | 59 | 124 | 35 |
| `applyUserProperties` | 48 | 60 | 6 |
| `mediaPropertiesChanged` | 27 | 42 | 12 |
| `mediaPlaybackChanged` | 23 | 30 | 6 |
| `mediaThumbnailChanged` | 21 | 85 | 10 |
| `cursorClick` | 11 | 18 | 6 |
| `cursorDown` | 6 | 8 | 4 |
| `cursorEnter` / `cursorLeave` | 5 | 9 | 3 |
| `mediaTimelineChanged` | 4 | 4 | 2 |
| `cursorMove`, `cursorUp` | 3 | 5 | 3 |
| `mediaStatusChanged` | 1 | 1 | 1 |

Ten further exports are the authors' own helpers (`skip`, `playTrack`, …); WE ignores them.

**API surface** (scripts / sites / wallpapers):

- `engine.frametime` 54/92/20
- `thisScene.getLayer` 56/68/7
- `createScriptProperties`: `addCheckbox` 49/112/33, `addText` 39/94/32, `addSlider` 23/36/12, `addCombo` 17/41/21, `addColor` 1
- `new Vec3` 49/62/12
- `engine.registerAudioBuffers` 33/62/19. Resolutions: 16 (most), 32, 64. Always at module scope.
- `thisLayer.origin` 41/47/8, `.alpha` 28/31/6, `.visible` 18/26/4, `.text` 12/27/8, `.scale`, `.color`, `.size`, `.alignment`, `.maxwidth`, `.pointsize`
- `thisObject.getAnimation` 15/36/9, `thisObject.visible` 6/44/7
- `MediaPlaybackEvent.*` 18+6+4
- `WEMath.smoothStep` 12/29/6, `WEMath.mix`, `WEColor.hsv2rgb`
- `engine.timeOfDay` 10/25/6
- `shared.*` 48 scripts, practically all in 3453730450 (numbers only)
- `thisLayer.getTextureAnimation` 5/9/2
- `engine.runtime` 4/6/4
- `thisScene.createLayer` 4/4/4 (asset path `'models/bar.json'` ×3, `getInitialLayerConfig` ×1), `sortLayer` 3, `getLayerIndex` 3, `enumerateLayers` 2, `getLayerCount` 1, `getInitialLayerConfig` 1
- `engine.setTimeout` 3/22/7. Its return value is **called** to cancel: `lastHideEvent()`.
- `engine.canvasSize` 2/4/3, `engine.userProperties` 1, `engine.isScreensaver()` 1
- `input.cursorWorldPosition` 1, `input.cursorLeftDown` 1, `console.log` 3
- Writes via layer references: `parallaxDepth` 3, sound `volume` 3, texture-animation `rate` 5, `solid` 1
- **Zero** uses of `getEffect`, `getMaterial`, `setMaterialProperty`, `localStorage`, bones, animation layers, `createModelData` or camera transforms. These are still part of the WE API and common in the wider Workshop, so they are in the plan, only lower in the order.

**Wallpapers by script weight** (sites / distinct scripts):

- 3000562427 Steam Summer Sale 2023: 80/61. Media, timers, `getAnimation`.
- 3453730450 Moon: 71/54. `shared`, cursor, audio.
- 2963872291 Pixelart Alice City: 39/35. Every cursor callback, media.
- 2134765860 Bunk: 32/10. Media, timers, `getAnimation`, general script.
- 2978204069, 2176097362 (Dance Club: `getTextureAnimation`, general script), 3546971487, 3187908708, 3109042108, 3352730400, 2978738836, 2370927443.
- Then 31 smaller ones: clocks, audio bars with `createLayer`, cursor toys.

---

## 3. The implementation before WP11

Kept as the record of what the rewrite replaced; WP11 deleted all of it (see WP11 below for what runs now).

Files:

- `OpenWallpaperEngine/Scene/Scripting/AudioReactiveScriptEngine.swift`: layer state and the JS runtime in one process-wide singleton. It held audio capture, FFT and the property store too (1336 lines) until WP1 moved them to `Audio/SystemAudioCapture.swift` and `Scene/Values/SceneUserPropertyService.swift`; the engine owns one of each and forwards its old API to them.
- `BrowserMediaIntegration.swift`: polls browser tab titles with AppleScript every 2 s.

Call sites:

- `SceneMetalRenderer` (`configureLayers`, `executeSceneScript`, `layerBoolean/Value/Vector2/String`, `evaluate*` for alpha, colour, size, text, brightness and bloom, drains for `createLayer`/`sortLayer`/`destroyLayer`).
- `SceneObjectMotion.local` (origin, scale and angles scripts).
- `LiveSceneValueContext.evaluateScript` (effect constants and every `SceneValue` script).
- `ParticleFrameInputs` (particle rate, drag, fade).
- `SceneWallpaperViewModel.resolvedVisibility` (visible scripts, once).

### 3.1 How it runs a script

1. **Context per key.** The context is keyed by `"<layerId|global>:<full source>"`. Particle and effect scripts have no layer id, so identical sources on different objects share one context and its state.
2. **Rebuilt every call.** Every `evaluate*` call re-sets about 15 globals: `engine` rebuilt from a Swift dictionary, `input`, `__layers` (a JSON copy of *every* layer's state), `shared`, `thisScene` (a new object literal, evaluated from a string), `thisLayer` (another copy), plus `registerAudioBuffers`. Every layer is then re-decorated with about 60 closures.
3. **Script source.** The source goes through regex rewriting: `export` is stripped and `import * as` / `import {}` become `__requireModule`. It is evaluated once; then `init(input)` runs, `applyUserProperties(all)` runs when the property revision changed, then `__dispatchRuntimeEvents` (cursor, enter/leave, animation stubs, timers), then `update(input)`.
4. **Read-back.** Afterwards `__layers.toDictionary()` and `shared.toDictionary()` are copied back into Swift and replace the global state. Pending creations, orders and removals are drained, and `__camerashake` is read.

The measured cost in the snapshot is about 0.3 ms plus 0.12 ms per layer, per script, per frame: roughly 400 ms per frame for 3453730450.

### 3.2 Status per API

Legend: ✅ works like WE · 🟡 partial or wrong in a way the corpus hits · ❌ missing or broken · ⚪ missing, unused in the corpus.

| API | WE semantics | Ours | Corpus (scripts/sites/wp) |
|---|---|---|---|
| ES module syntax | real modules, own scope per script | 🟡 regex rewrite; top-level `let` collides in the shared visibility context | all 281 |
| imports `WEMath/WEColor/WEVector` | WE jsmodules | ✅ via the bundled WE files | 18/37/9 |
| `update(value)` return → property | chained: the next call receives the current value; no return = unchanged; number broadcast to vectors | 🟡 input is always the authored/base value, so accumulators never move; `undefined` → `"undefined"` text or (0,0,0) vectors; a number `n` returned for a vector becomes `(n, 0, 0)` through `parseVector3`, not `(n, n, n)` | 213/357/43 |
| `init(value)` return → property | applied | ❌ return ignored | 79/115/23 |
| visible scripts | every frame | ❌ once at load, in a separate stub context; hidden objects are dropped and can never be shown | 70 sites |
| effect `visible` scripts, `thisObject.visible` on an effect | toggles the effect | ❌ never run; effects hidden at load are dropped; `thisObject` is a copy of the layer | 46 sites/7 wp |
| effect constant scripts | per frame | 🟡 run per frame, but with no `scriptproperties`, `thisObject` = layer copy, and a context shared across objects | 86 sites |
| particle `instanceoverride` scripts | per frame | 🟡 only `rate` runs; alpha, colorn and lifetime are ignored; no layer id | 22 sites |
| `general.*` scripts | per frame | ❌ evaluated once at load (`SceneGeneralSettings` at `time: 0`) | 2 |
| `thisLayer.<prop>` writes | stick | ❌ `thisLayer` is a copy; only writes through `thisScene.getLayer(...)` survive the read-back | 41+ scripts |
| `thisLayer.angles` | degrees | 🟡 radians are handed out and read back as radians | 18 sites |
| `thisObject` | the property's owner | ❌ always `thisLayer`'s copy | 21 scripts/80 sites |
| `thisObject.getAnimation()` | the property's timeline | ❌ a JS stub with its own frame counter, not linked to the keyframes; decays to `{}` after the read-back | 15/36/9 |
| `getTextureAnimation()` | spritesheet control | ❌ stub | 5/9/2 |
| `thisScene.getLayer/ByID/Count/enumerate/getLayerIndex` | live objects | 🟡 copies; indices follow dictionary key order, not draw order; sound, particle and hidden objects are missing | 56/68/7 |
| `createLayer(path \| config)` | loads that asset or config | 🟡 always clones `thisLayer` and ignores the path | 4 wp |
| `sortLayer`, `destroyLayer` | reorder; remove after the frame's updates | 🟡 applied next frame; only clones can be destroyed | 3 wp |
| `getInitialLayerConfig` | authored config | 🟡 a JSON copy of the current state | 1 |
| `shared` | one live object | 🟡 round-tripped through Swift each call; functions and prototypes are lost | 48 scripts |
| `createScriptProperties` / `scriptProperties` | WE's builder, then values from `scriptproperties` via `_Internal.updateScriptProperties` | 🟡 our shim replaces WE's builder (`addCombo` takes `value`, not `options[0].value`); values reach only origin/text scripts; user-bound entries are unresolved | 59/124/35 |
| `engine.frametime`, `runtime`, `timeOfDay`, `canvasSize` | | ✅ (`runtime` time base differs by call site) | |
| `engine.screenResolution` | the screen's pixels | 🟡 `NSScreen.main` points, not this wallpaper's display | |
| `engine.userProperties` | converted (colour → Vec3) | 🟡 colours are strings | 1 |
| `engine.is*()` | functions | ❌ missing; `engine.isScreensaver()` throws | 1 |
| `engine.registerAudioBuffers` | live `Float32Array`s, left/right/average, 16/32/64 | ❌ a frozen snapshot of the legacy 64-band mono FFT; `left == right`; plain arrays | 33/62/19 |
| `engine.setTimeout/setInterval` | return a cancel **function** | ❌ return a number, so `cancel()` throws; they tick only when the owning script is evaluated | 3/22/7 |
| `engine.registerAsset` | asset handle | 🟡 stub object | |
| `engine.openUserShortcut` | runs a user shortcut | ⚪ | |
| `applyUserProperties` | changed keys only; all at load | 🟡 all keys every time | 48/60/6 |
| `applyGeneralSettings` | `{language}` | ⚪ | |
| `resizeScreen` | on resize only | 🟡 also called on the first evaluation | |
| `input.cursorWorldPosition` | scene space | ❌ screen points (`NSEvent.mouseLocation`) | 1 |
| `input.cursorLeftDown` | | 🟡 counts clicks in any app | 1 |
| cursor callbacks | only for the object under the cursor | 🟡 click/down/up/move fire for every script regardless of position; enter/leave test origin ± size/2 (no scale, rotation or parents); event positions are screen points | 23 scripts |
| media callbacks (5) | from the OS media session | ❌ never called; `BrowserMediaIntegration` knows only browser tab titles | 76 scripts/162 sites/12 wp |
| `localStorage` | per wallpaper, `'screen'` default, `get(key, location)` | 🟡 `UserDefaults.standard` (breaks the no-globals rule), not namespaced per wallpaper, wrong signature `get(k, default, scope)`, numeric scopes | 0 |
| `console.log/error` | | ✅ (`log` → `.debug`) | 3 |
| `Vec2/3/4`, `Mat3/4` | WE baseclasses | ✅ WE's classes load first and win; the shim's copies are dead code | |
| `WEMath` as a global | module only | 🟡 the shim defines `WEMath.deg2rad` as a *function*; WE's is a number | |
| `getEffect`, `getMaterial`, `setMaterialProperty` | effect and material control | ⚪ stubs returning null/{} | 0 |
| sound layer API | play/stop/pause/volume | ⚪ stubs; sound objects are not script-visible | 3 (volume) |
| particle `instance`, `emitParticles`, `play/stop` | | ⚪ stub object | 0 |
| animation layers, bones, blend shapes, attachments, `lookAt`, `setParent`, `getTransformMatrix` | | ⚪ stubs (need areas 6/7) | 0 |
| camera transforms, scene settings (`bloom*`, `clearcolor`, …) | read/write | 🟡 only `camerashake` | 1 |
| `destroy` | before destruction | 🟡 only on reconfigure | |
| exceptions | logged | 🟡 logged with the **entire script source** in the context key; rate-limited | |
| infinite loops | watchdog | ❌ a hang freezes the render thread forever | |

### 3.3 Other problems in the current code

1. **One process-wide singleton** (`AudioReactiveScriptEngine.shared`). With two displays, each renderer's `configureLayers` replaces `layerStates` and **destroys every context**, including the other display's, so two scenes clobber each other. The context keys (`layerId:source`) also collide between two instances of the same wallpaper. This breaks the architecture invariant "state belongs to a wallpaper instance".
2. **Invented, non-WE globals** that no WE script uses:
   - functions `audio()`, `fft()`, `property()`, `setGlobal()`, and globals `time`, `cursor`, `global`
   - `engine.spectrum/waveform/bass/mid/treble/audio/audioLevel/audioVisualization/media`, `engine.AUDIO_RESOLUTION_128`
   - `input.mouse/buttons/modifiers/leftDown/rightDown/cursorScenePosition`
   - `thisScene.time/currentTime/dt/fps`, `Vec2.rotate(radians)`
   - They mask script bugs and should go.
3. `loadSceneScript` guesses `script.js`, `scene.js` and `scenescript.js` in the wallpaper folder when `scene.json` has no `script` key. WE has no scene-level script file; no scene in the corpus has a top-level `script`. It would execute any stray `.js` a scene ships.
4. The compatibility shim assigns `createScriptProperties`, `WEMath`, `WEVector`, `WEColor` and `AudioBuffers` as global properties **after** WE's `baseclasses.js`. That replaces WE's `createScriptProperties`, whose combo default is `options[0].value`.
5. `resolveLayerVisibility` evaluates every visible script in *one* context. A top-level `let` in a second script throws a redeclaration error, and that script's result is silently lost (`exceptionHandler = { _, _ in }`).
6. `evaluateString` returns `"undefined"` when `update` returns nothing. `evaluateVector*` returns (0,0,0) for `undefined` (the string parse of "undefined").
7. `reportScriptException` puts `contextKey` (layer id plus the **full source**) into every log line.
8. The engine reads `NSEvent.pressedMouseButtons`/`mouseLocation` on the render thread and ties cursor state to one global `__lastCursor` per context.
9. `localStorage` writes `UserDefaults.standard` (CONTRIBUTING rule 3) and uses `dictionaryRepresentation()` scans for `clear`.
10. `BrowserMediaIntegration` runs AppleScript against eight browsers every 2 s. That triggers Automation permission prompts, reports tab titles rather than media, and never dispatches events.
11. Effects hidden at load (`isEffectVisible`) are not built at all, so no script or user property can show them later. The same holds for objects (roadmap area 8 item 3 and item 10).
12. Particle scripts use the particle system's elapsed time as `engine.runtime`, while layer scripts use scene time.
13. `SceneValueContext` has a `properties` parameter that `LiveSceneValueContext` ignores (its doc comment says so), so `scriptproperties` never reach effect, particle or visible scripts.
14. The audio capture, FFT, property store and the render-side property reads (`userPropertyValue`, `_owe_*`) all live in the script engine file. The script runtime can't be extracted or tested without them.
15. There are **no** SceneScript tests. `SceneUserPropertyStoreTests` and `SceneReviewFixTests` touch only the property store.

---

## 4. Design

### 4.1 Shape

```
SceneRenderContent ──► SceneScriptRuntime (one per wallpaper instance, owned by the renderer)
                         ├─ JSVirtualMachine + one JSContext
                         ├─ prelude: WE baseclasses.js + jsmodules (unmodified) + our runtime/*.js
                         ├─ ScriptInstance[] (one per attachment site, in scene order)
                         ├─ SceneScriptObjectTable (shared memory with the renderer)
                         └─ SceneScriptHost (protocol): assets, audio, media, input, storage, clock, log
```

- **Per instance, no singleton.** Two displays mean two runtimes. `shared` is per runtime. `localStorage` `'screen'` is keyed per instance (wallpaper id plus display id) and `'global'` per wallpaper id.
- **One context per scene.** Every script is its own *module scope* inside it (§4.2), so top-level names never collide, and `shared`, `thisScene` and layer objects are genuinely shared.
- **Confined to the render thread.** The runtime is not thread-safe and never touched elsewhere. Anything from other threads (property changes, media events, resizes) goes into a locked inbox that the runtime drains at the start of a frame.

### 4.2 Modules without private API

The corpus uses only `export function|let|var|const NAME` and `import * as X from 'Y'` (§2). Each script becomes a factory with public-API `evaluateScript(_:withSourceURL:)`. The sketch below is the original design; the contract WP3 implemented is in `Modules/SceneScriptModuleCompiling.swift` and `SceneScriptModuleTransformer.swift` (`(__rt, __scope) → frozen namespace`):

```js
// header joined on line 1, so line numbers stay exact
(function (__rt, thisLayer, thisObject, WEMath, WEVector, WEColor) { 'use strict';
  /* original source with `export ` removed and import lines blanked (kept as empty lines) */
  return __rt.exports({ get update(){ return typeof update==='function'?update:undefined }, … });
})
```

- A **tokenizer**, not regexes, finds `import` and `export` at the top level. It skips strings, comments, regex and template literals.
- **Export rules (WP3).** Accepted: `export function|let|var|const|class`, `export default <declaration or expression>` (bound to a hidden local), and `export { a, b as c }`. The exports object is a frozen, prototype-less namespace with one getter per exported name, so it exposes only exported names and `export let` stays live. Imports: `import * as X`, `import D`, `import { a as b }` from WE's jsmodules (resolved case-insensitively). Rejected, as compile errors logged once with their line: re-exports (`export * from …`), dynamic `import()`, `import.meta`, import attributes. None of the accepted extras occur in the corpus.
- Export getters keep `export let` bindings live.
- `sourceURL` = `owe://<workshopId>/<object name>#<id>/<field>`, so errors name the wallpaper, layer and field (CONTRIBUTING rule 2).
- Global-scope rules (§1.1) are enforced in a phase flag: `__rt.phase = 'global'` while the factory body runs, then `'callback'`. `registerAudioBuffers`/`registerAsset` throw outside `global`; `setTimeout` and `localStorage` throw inside it. Access to `thisLayer` members at global scope is allowed (lenient superset); only the call rules WE errors on are enforced, because a script that does them is broken in WE too.
- Real JSC modules exist only as SPI: `JSScript` with `kJSScriptTypeModule`, `-[JSContext evaluateJSScript:]` and `moduleLoaderDelegate` were all present in the probe. The wrapper covers 100 % of the corpus without them.

### 4.3 Live objects and state writeback

**The object table.** `SceneScriptObjectTable` is a struct-of-arrays that the renderer owns and the runtime shares:

- per object slot: origin xyz, angles xyz (degrees at the API, radians stored), scale xyz, alpha, colour rgb, visible, parallaxDepth, size, …
- plus per-effect `visible` and per-material constant slots.
- Numeric fields sit in one `Float32Array` created with `JSObjectMakeTypedArrayWithBytesNoCopy` over Swift-owned memory. JS and Swift read and write the **same bytes**, so there is nothing to marshal per frame.

**JS classes** live in `runtime/layers.js`. `Layer`, `TextLayer`, `ParticleSystem`, `SoundLayer`, `Effect`, `Material` and `Animation` are plain JS classes with getters and setters over the table:

- `get origin(){ return new Vec3(t[i], t[i+1], t[i+2]) }` returns a copy, like WE.
- `set origin(v){ t[i]=v.x; t[i+1]=v.y; t[i+2]=v.z; dirty[i]=1 }`.
- Strings and rare fields (`text`, `font`, `name`, `horizontalalign`, …) live on the JS object with a dirty bit. The renderer pulls dirty strings once per frame with one `__rt.drainStringWrites()` call. A text layer's text changes at most once a second.
- Methods that need native work (`play`, `setFrame`, `emitParticles`, `setMaterialProperty`, `createLayer`) append to a command ring (`Int32Array` + args), which Swift executes after the script phase. Queries that need native answers (`getTransformMatrix`, `getBoneTransform`) read the table's world-matrix slots, which the renderer writes after each transform pass.
- One JS object per scene object, created once. `thisScene.getLayer` returns the same object every time, so `thisLayer === thisScene.getLayer(thisLayer.name)`.

**Property scripts.** A `ScriptInstance` bound to a field keeps the current value:

- `update(value)` receives it (a fresh `Vec3` for vector fields, created per call like WE, or cached when P2 shows WE reuses one).
- The return value is coerced to the field's type by WE's converter (P3): number, bool (booleans only), string (`ToString` of anything but `null`/`undefined`), `Vec2/3/4` from objects with numeric x/y/z/w, and a number broadcast to every component (WE: `2` on Scale is `Vec3(2, 2, 2)`). Strings are not vectors.
- The coerced value becomes the field's value (written into the table) and the next call's input. `undefined` or an uncoercible value leaves it unchanged (P3).
- `init(value)`'s return is applied the same way.

**Fields feeding the table**, in precedence order:

1. authored or user value,
2. the timeline animation (P2),
3. the property script's return,
4. direct writes by *any* script this frame (last writer wins, in execution order).

**The renderer** stops calling `layerValue`/`evaluate*` per draw. It reads the table after the script phase. `SceneObjectMotion`, `ParticleFrameInputs` and `LiveSceneValueContext.evaluateScript` read the resolved field from the table instead of running scripts themselves.

**Hidden objects** stay in the table and the draw list with `visible = 0`. Their scripts keep running (P6). Hidden effects are built and skipped. This closes roadmap area 8 items 3 and 10 for scripts.

### 4.4 Frame order

The load phase runs once, in scene object order (§1.9 P8):

1. Evaluate every module factory (global scope: `registerAudioBuffers`, `registerAsset`, `createScriptProperties().finish()`).
2. Inject `scriptproperties` through WE's `_Internal.updateScriptProperties`. User-bound entries are resolved through `Scene/Values` and re-injected when the user property changes.
3. `init(value)` per script, applying its return; right after each `init`, that script gets the current media state (WP6).
4. `applyUserProperties(all)` for every script, then `applyGeneralSettings({language})`.

Each frame:

1. Frame globals: `engine.frametime/runtime/timeOfDay`, `input.*` in scene space, audio buffers refilled in place.
2. Inbox events by kind, then arrival (§1.9 P1): `resizeScreen` (best guess), cursor events, `applyUserProperties(changed)`, media events. Cursor hit tests use last frame's world transforms (§4.8).
3. Timeline animations and `animationEvent` (WP12).
4. Due timers.
5. `update(value)` for every instance in scene order. Within an object, fields go in a fixed order (visible, origin, scale, angles, alpha, color, text, effects, instanceoverride); WE's list order is creation order, which this approximates.
6. Deferred structure: `destroyLayer` (after all updates, per the docs), `createLayer` materialisation, `sortLayer`, `destroy()` callbacks.
7. Swift executes the command ring, then particles and transforms (which write world matrices back into the table), then render.

**One native→JS call per frame** (`__rt.frame(dt)`) runs steps 1–6 in JS. Swift only fills the shared buffers before it and drains the command ring and dirty strings after it.

### 4.5 Errors, the watchdog and the sandbox

**Isolation.** Every callback runs inside `__rt.invoke(instance, name, args)`, a JS `try/catch`.

- An exception is recorded on the instance: the message, `sourceURL:line:col` and the stack. It is reported to Swift through a per-frame error array, and each distinct (instance, message) is logged once through `OWELog.error(.script, …)`.
- Other scripts are unaffected.
- A compile error disables that instance, and its field keeps the authored value. `8bb9b9a54120` is the corpus case.
- A callback that throws is never called again for that instance; its other callbacks keep running, and the call's return is not applied (§1.9 P4). A module body that throws disables the instance. Timer callbacks are logged, never disabled.

**Watchdog.** `JSContextGroupSetExecutionTimeLimit` (private C symbol, resolved with `dlsym`; nil means no watchdog, with an `.info` log).

- Verified on this Mac: `while(true){}` is terminated after 0.21 s with a 0.2 s limit, and the context stays usable afterwards.
- The limit applies per native→JS entry, so it covers the whole `__rt.frame`; WE's applies per outermost script call. On termination `__rt.current` names the running instance, the "dead lock was detected" message is logged once, and, like WE, the **whole runtime halts**: no callback, timer or new script runs until the wallpaper reloads (§1.9 P5).
- Limit: WE's 15 s, at load and per frame.

**Threading (S19).** A runtime is confined to one `SceneScriptThread`: a serial dispatch queue of its own, off the main thread (`.userInitiated`). The owner creates the runtime inside `thread.sync { … }` and afterwards reaches it only on that queue; `load`, `frame`, `add`, `remove` and `tearDown` check it (`dispatchPrecondition`). The renderer posts each frame with `thread.asyncFrame { runtime.frame(deltaTime:) }`, which skips the frame while the previous one is still queued or running, so a script that hangs until the 15 s watchdog fires stalls only its own wallpaper's scripts: the UI, other displays and the renderer (drawing with the last values) keep going. Other threads talk to a runtime only through its thread-safe `inbox`. Releasing the last reference elsewhere still runs `destroy()` on the runtime's queue (`deinit` hops there). JavaScriptCore locks a VM per API call, so the queue's worker threads may change between blocks. Without a thread (tests) the caller's thread is the runtime's; on the main thread that is logged once. The table and command read-back (WP11) happen on the script queue after the frame, handing the renderer a value snapshot.

**Shared memory (SF3).** Every buffer scripts can reach (command ring, object table and slot buffers, engine frame and clock) is a `SceneScriptSharedBuffer`: the bytes are reference counted between Swift and the typed array's deallocator, and pinned at creation, so `buffer.transfer()` copies instead of detaching and no script can free memory Swift writes. The runtime `watch`es each buffer and stops the scripts if one ever reports `isDetached`.

**Numbers (SF10).** Every Float/Double → Int conversion of a script-provided number goes through `SceneScriptNumber` (clamp or validate; `Int(_:)` traps on NaN and infinity). WP11's table readers (`maxrows`, `pointsize`, `limitrows`, frame indices) must too.

**Sandbox.**

- JSC contexts have no file system, network, `require` or DOM. We expose only the WE API. The invented globals of §3.3 are deleted, and no Swift block is callable except the runtime's own narrow ones.
- `__rt` is out of scripts' reach (S28): a compiled module's own scope shadows the name, and the global reads as `undefined` while a native entry (`load`, `frame`, `teardown`) or any script code runs, so runtime code calling a builtin a script replaced can't leak it either. After every extension is installed, `__rt.seal()` freezes the hooks and makes the runtime's functions read-only. Runtime and extension files capture `__rt` when they are evaluated; tests and the native side read it between entries.
- `localStorage` has WE's documented cap of 100 KB per wallpaper.
- `console` is rate-limited.
- `eval` and `Function` stay available (V8 allows them), but they run inside the same watchdog.
- There is no public JSC heap limit. Watch `JSVirtualMachine` memory through `JSGarbageCollect` statistics in debug, and cap object creation per frame (`createLayer` > 1000 live clones is logged).

### 4.6 Performance targets

| Cost | Today | Target |
|---|---|---|
| Per script per frame | 0.3 ms + 0.12 ms × layers | ≈ 1–5 µs (one JS call inside the frame loop) |
| Per frame, 3453730450 (71 sites) | ~400 ms | < 0.5 ms |
| Bridging per frame | ~15 `setObject` + `toDictionary` of all layers per call | 1 call + buffer reads |
| Allocations | dictionaries per call | one `Vec3` per vector getter or argument (like WE) |

Per-frame budget assertions go into the harness (§5, WP9) as `measure` tests, with a baseline per scene. Measured after WP11 in the renderer (`SceneScriptLibraryCostTests`, Release, median): 0.10–0.26 ms per frame for the library's scenes, 0.49 ms for 3453730450 (71 sites); see WP11.

### 4.7 Audio, media and storage sources

- **Audio buffers.** WE fills one buffer that both the shaders' `g_AudioSpectrum16/32/64` (`wallpaper64.exe` `0x1400d9bc4`) and SceneScript (host `0x14018e010`) read, so `AudioSpectrumAnalyzer` computes exactly that (WP5, done): the capture thread's block DFT and 64 bands per channel (`0x1400d02b0`) and the render loop's per-group gain, smoothing and 32/16 pair maxima (`0x140111654`). `average` is (l+r)/2 at 64 bands. Every `registerAudioBuffers` call in the corpus is at module scope, as WE requires.
- **Media.**
  - A `MediaSessionSource` protocol with one macOS implementation, MediaRemote through `dlopen`/`dlsym` (WP6, done). It is restricted for third-party bundles since macOS 15.4, so on current macOS the info may never arrive; the `/usr/bin/perl` adapter technique or a helper is still open.
  - Thumbnail colours: WE's media helper (`winrtutil64.exe`) scores 360 hue bins and picks primary, secondary and tertiary by score and hue distance; `textColor` and `highContrastColor` by WCAG contrast ≥ 2.5 (`ArtworkPalette`).
  - `BrowserMediaIntegration` is deleted.
- **localStorage.** A per-wallpaper JSON file in Application Support: `scenestorage/<workshopId|dir-hash>/{global,screen-<displayID>}.json`. Values go through `_Internal.stringifyConfig`, so `Vec3` survives through `toConfigString`.

### 4.8 Input

- The renderer publishes the scene-space cursor (it already has `sceneCursor` and `cursorTracker`) and the left-button state **only for clicks on the desktop** (the wallpaper window receives the events; the global `NSEvent.pressedMouseButtons` is not used).
- `input.cursorScreenPosition` is in display pixels.
- **Hit test** (WP10, §1.9 P7). The renderer hands `SceneScriptCursorExtension.publish(_:)` the cursor, the button and the image and text layers in draw order with last frame's world matrices (`SceneScriptCursorLayer.layers(in:drawOrder:parentOf:)` reads them from the table). `localPosition` is from the quad's top-left with y down. Hidden layers are hit; `disablepropagation` on a visible hit stops the pass; otherwise overlapping solid layers all get the events, topmost first.

---

## 5. Implementation plan

Work packages are ordered; packages in the same step touch disjoint files and can run in parallel. Each lands as small conventional commits with tests (CONTRIBUTING). Moves and renames get their own commits.

### Step 0 (serial)

**WP0 — Resolved from evidence.** WE cannot run on this Mac, even under CrossOver, so no probe wallpapers. §1.9 records each answer with its evidence from WE's binaries, docs and corpus, and marks the remaining best guesses. WP9's synthetic fixtures assert the §1.9 behaviour instead of probe logs.

**WP1 — Split the file, moves only.** *Done:* `AudioCapturePermissionGate` and `CaptureRestartScheduler` moved to `Audio/`, `SceneUserPropertyStores` to `Scene/Values/` (move-only commit); then the split below, with bodies unchanged and each new type owning its own lock. Move audio capture, FFT and `SceneUserPropertyStores` usage out of `AudioReactiveScriptEngine.swift`:

- `Audio/SystemAudioCapture.swift` (capture, restart, spectrum analyzer feed)
- `Scene/Values/SceneUserPropertyService.swift` (property store, music sync, `userPropertyValue`)
- The old type keeps only scripting and forwards. No logic changes; must build.

**WP2 — Runtime skeleton and interfaces.** *Done;* see **Seams** below. Not wired into the renderer yet: the app keeps running `AudioReactiveScriptEngine` until WP11.

- `Scene/Scripting/Runtime/SceneScriptRuntime.swift`: VM, context, watchdog, prelude loading, the `frame(dt)` driver, the error channel.
- `SceneScriptHost.swift`: the protocol for assets, audio, media, input, storage, clock and log.
- `SceneScriptInstance.swift`.
- `SceneScriptObjectTable.swift`: the slot layout only.
- `Resources/SceneScript/runtime.js`: `__rt.invoke`, the phase flag, the error array.
- WE's `baseclasses.js` and jsmodules are loaded **unmodified** from `WallpaperEngineAssets`.
- Tests: a fake host; `while(true)` is terminated and disabled; an exception in one instance leaves the next one running; the context survives termination.

### Seams (what WP2 left for WP3–WP11)

WP2's files, all under `OpenWallpaperEngine/Scene/Scripting/` unless noted. Later packages **plug in; they don't edit these**. If a package needs a new runtime method, it adds it in an `extension SceneScriptRuntime` in its own file.

| File | What it is |
|---|---|
| `Runtime/SceneScriptRuntime.swift` | One `JSVirtualMachine` + one `JSContext` per wallpaper instance, optionally confined to a `SceneScriptThread`. `add(_:)`, `load(userProperties:generalSettings:)`, `frame(deltaTime:)`, `tearDown()`, `remove(scriptID:)`, `watch(_:)` (shared buffers), and the inbox shortcuts `userPropertiesDidChange(_:)`, `screenDidResize(width:height:)`. |
| `Runtime/SceneScriptThread.swift` | The runtime's serial queue off the main thread: `sync`, `async`, `asyncFrame` (skips while a frame is in flight), `isCurrent` (§4.5). |
| `Runtime/SceneScriptNumber.swift` | Trap-free integer conversion of script numbers (clamp, or validate an index). |
| `Resources/SceneScript/runtime.js` | `__rt`: script records, the load and frame order, the phase flag, `__rt.call`/`invoke` isolation, the error channel, module registry, command-ring writer. |
| `Runtime/SceneScriptWatchdog.swift` | `JSContextGroupSetExecutionTimeLimit` via `dlsym`; nil (and one `.info` line) when missing. Limit: WE's 15 s per load entry and per frame entry (`Configuration`). |
| `Runtime/SceneScriptError*.swift` | `SceneScriptError` (compile/runtime/terminated/internal; id, callback, line, message; never source) and the once-per-distinct-error log. |
| `Runtime/SceneScriptInstance.swift` | One attachment site: id, source, initial value, `scriptproperties` JSON, object slot, and `binding` (`SceneScriptObjectBinding`: what `thisObject` is; WP8 sets it). |
| `Runtime/SceneScriptHost.swift` | What the owning wallpaper instance provides: `identity` (wallpaper id + screen id), `prelude`, an optional error callback. |
| `Runtime/SceneScriptRuntimeExtension.swift` | The plug-in protocol (below). |
| `Runtime/SceneScriptInbox.swift`, `SceneScriptEvent.swift` | The only thread-safe entry; events drained at the start of a frame. Past 1024 undrained events (frames stopped) the inbox coalesces by each event's `Coalescing`: `.latest` (default: states such as media parts, resize, cursor moves) keeps the newest per kind and target, `.merge` (user properties, general settings) merges the dictionaries, `.keep` (WP10's clicks) is dropped oldest first only if still full. |
| `Runtime/SceneScriptSharedBuffer.swift` | Swift memory seen by JS as a typed array, reference counted with the array's deallocator and pinned (§4.5); `isDetached`. |
| `Runtime/SceneScriptPrelude.swift`, `SceneScriptResources.swift` | WE's `baseclasses.js` + jsmodules, unmodified; our bundled JS. |
| `Modules/SceneScriptModuleCompiling.swift` | The compiler protocol and factory contract (WP3). |
| `Objects/SceneScriptObjectTable.swift` | Slot layout + shared `Float32Array`/dirty bytes (WP7 fills). |
| `Objects/SceneScriptCommandRing.swift` | Shared `Int32Array` records + `Float32Array` numbers, drained after each frame (WP7 and others add opcodes). |

**Order the runtime guarantees** (tested in `SceneScriptRuntimeTests`):

- Creation: `baseclasses.js` → `runtime.js` → per extension `install(into:)` then its `scriptResources` → jsmodules through the compiler.
- `load` (resumable; re-callable for scripts added later): every module body (phase `'global'`) → `scriptproperties` through `_Internal.updateScriptProperties` → every `init(value)` → every `applyUserProperties(all)` → every `applyGeneralSettings({language})`. All in `add` order, which is scene order.
- `load` also calls `__rt.hooks.initialized(record)` right after each `init`. Scripts defined after the first load get no `applyUserProperties` (P8's best guess; they read `engine.userProperties`). `load` drains the command ring before it returns, so `createLayer`/`sortLayer`/`play` from module bodies and `init` take effect before the first frame.
- `frame`: `frameGlobals` handlers → inbox events ordered by kind (`__rt.EVENT_ORDER`: resize, cursor, userProperties, generalSettings, media), then arrival → `animations` handlers → `timers` handlers → every `update(value)` → `deferred` handlers → `__rt.destroyPending()`: `destroy()` of removed scripts, repeated until none is pending (a `destroy()` may remove more). Removed ids reach Swift (`__rt.removed`) and are free again. Then Swift drains the command ring and calls `didRunFrame`.
- `tearDown`: every `destroy()` → the command ring → every extension's `tearDown(_:)` (flush, cancel, unsubscribe; also after a halt). Once only.
- `__rt.current` is the running script's id, `__rt.callback` the running exported callback (null in module bodies and timers). Error lines come from the first stack frame in the script's own `sourceURL`, so an error a helper throws names the calling line.
- A throw is recorded and swallowed; the callback that threw is never called again for that script (`record.failed`), its other callbacks keep running. `__rt.call` (timers, ended callbacks) logs but disables nothing. A throw in a module body or a compile error disables that script only. A watchdog stop halts the whole runtime (`state == .halted`, `__rt.halted`), naming the script from `__rt.current`.

**Per package:**

- **WP3 (module compiler).** *Done (see WP3 below).* Implement `SceneScriptModuleCompiling` in `Modules/`. The contract is in the protocol's doc comment: `factorySource` evaluates to `function (__rt, __scope) → exports`; `thisLayer`/`thisObject` come from `__scope`, imports from `__scope.require(name)`; exports are getters for every name in `__rt.CALLBACKS` plus `scriptProperties`; line N stays line N. Rejected forms throw `SceneScriptCompileError(message:line:)`. The same compiler turns WE's jsmodules into modules the runtime registers as `wemath`/`wevector`/`wecolor`. `TestSceneScriptCompiler` in the tests is the stand-in until then.
- **WP4 (engine, input, console, timers, storage).** A `SceneScriptRuntimeExtension` with its own `engine.js`, `timers.js`, `storage.js`. Timers register with `__rt.addPhaseHandler('timers', fn)` and run script callbacks through `__rt.call(record, label, 'callback', fn, args)` (errors stay attributed and isolated); the owning record at `setTimeout` time is `__rt.byId.get(__rt.current)`. Global-scope rules use `__rt.requireGlobalScope(what)` / `__rt.forbidGlobalScope(what)`, which produce WE's exact messages (§1.9). Timers follow §1.9 P1: per script, over a snapshot, an interval resets to its period (fires at most once per frame), a timeout is removed after firing. `_Internal.convertUserProperties` goes into `__rt.hooks.userProperties`. Per-frame numbers (`frametime`, `runtime`, cursor) belong in a `SceneScriptSharedBuffer` filled in `willRunFrame`. Storage keys come from `runtime.identity`.
- **WP5 (audio).** An extension; one `SceneScriptSharedBuffer<Float>` per registered resolution, filled in place in `willRunFrame` (WE refreshes them in its tick, before timers and updates; §1.9 P1); `registerAudioBuffers` calls `__rt.requireGlobalScope('registerAudioBuffers')`.
- **WP6 (media).** Declare kinds in its own file (`extension SceneScriptEvent.Kind { static let mediaPlayback = … }`), post with `runtime.inbox.post(_:)` from any thread, and handle them in JS with `__rt.addEventHandler(kind, __rt.EVENT_ORDER.media, e => __rt.broadcast('mediaPlaybackChanged', [e.payload]))`. The current media state for a new script goes in `__rt.hooks.initialized` (§1.9 P8).
- **WP7 (object model).** Owns `SceneScriptObjectTable` (append fields at the end and bump `stride`) and the opcodes 400–999 (`extension SceneScriptCommandRing.Opcode { static let … }` in its files, handlers registered in its extension's `install`). `__rt.hooks.scope(record)` returns `{thisLayer, thisObject}` for `record.slot`; `thisScene`, `layers.js` and `scene.js` are its own. Opcode ranges: 1–99 runtime, 100–199 WP4, 200–299 WP5, 300–399 WP6, 400–999 WP7, 1000+ later.
- **WP8 (binding).** *Done (see WP8 below).* Builds `SceneScriptInstance`s; `__rt.hooks.argument(record)` (the value `init`/`update` receive), `__rt.hooks.coerce(record, returned)` (undefined keeps the value) and `__rt.hooks.userPropertiesChanged(raw)` (before the frame's `applyUserProperties`).
- **WP10 (cursor).** Cursor events through the inbox with `target` = object slot; its own JS handler registered at `__rt.EVENT_ORDER.cursor`; only Solid objects (§1.9 P7).
- **WP12 (animations).** Timeline evaluation and `animationEvent(event, value)` go in the `animations` phase.
- **WP11 (integration).** The renderer (not a singleton) owns one runtime per wallpaper instance, on its own `SceneScriptThread` (§4.5), which is what fixes two displays clobbering each other: `load` at scene load, `thread.asyncFrame { frame(deltaTime:) }` per frame, `tearDown` on reconfigure (on the thread), `screenDidResize`/`userPropertiesDidChange` from the view model. Instances carry `binding` from WP8. It builds the extension list, reads `SceneScriptPrelude.load()` once, and deletes the scripting half of `AudioReactiveScriptEngine`.

**Bundle names.** The synchronized group copies `Resources/SceneScript/*.js` to the bundle root, so every runtime JS file name must be unique in the app bundle. `SceneScriptResources` looks in `SceneScript/` first, then the root.

### Step 1 (parallel; each owns the files listed)

**WP3 — Module compiler.** *Done:* `Scripting/Modules/` (tokenizer, scanner, transformer). Export and import rules in §4.2; every corpus script but `8bb9b9a54120` compiles; `TestSceneScriptHost` can load the jsmodules through it. `Scripting/Modules/SceneScriptTokenizer.swift`, `SceneScriptModuleTransformer.swift`.

- Tests: every corpus script compiles except `8bb9b9a54120`, which reports a compile error with its line; line numbers match the original; unsupported export forms are rejected; fixtures are synthetic snippets.
- The full-corpus test reads `/Volumes/980Pro/dd-scenescript/corpus` and is skipped when absent (like `LibrarySweepTests`).

**WP4 — Engine, input, console, timers, storage.** *Done:* `Scripting/Engine/` (`SceneScriptEngineExtension`, `SceneScriptStorage`, `SceneScriptInput`, `SceneScriptConsole`, `SceneScriptEngineEnvironment`) and `Resources/SceneScript/sceneScript{Engine,Timers,LocalStorage,Console}.js`. Best guesses: timers run on scene time and fire once per frame at most; the user-shortcut count resets per frame; storage writes flush once a second of scene time, at teardown and on app termination, and a store's cap counts keys too (SF6); `engine.runtime` is a double (SF8). Later packages extend `engine`, never replace it. WP11 wiring: one `SceneScriptStorage` app-wide; set `environment` on resize and `input` per frame on the script thread; `registerAsset` lives in the object model (an `IAssetHandle` whose `toConfigString()` is the path), and so do `isObjectValid` and `requestFeatures` since WP11 (best guesses: alive-or-destroyed, and a global-scope no-op).

- `engine.*` including the `is*()` functions and `userProperties` via `_Internal.convertUserProperties`.
- `setTimeout`/`setInterval` returning cancel functions, global-scope rules, `localStorage` per §4.7, `openUserShortcut` (logs "unsupported" until user shortcuts exist).
- Tests: timer order and cancel (`lastHideEvent()` pattern); storage isolation between two instances and two wallpapers; the `'screen'` default; `Vec3` round-trip; quota.

**WP5 — Audio buffers.** *Done:* `Scripting/Audio/SceneScriptAudioBuffersExtension.swift` and `sceneScriptAudioBuffers.js`; `Audio/AudioSpectrum*.swift` and `BluesteinDFT.swift` compute WE's spectrum (§4.7). Like scenescript64.dll (`0x181655170`), each registration gets its own `Float32Array`s over the scene's one native store (no-op deallocator), refilled before every frame. WP11 passes `SceneScriptAudioBuffersExtension(spectrum: { capture.audioSpectrumSnapshot })` and keeps advancing the analyzer once per rendered frame.

- Tests: feed a synthetic left-only tone and assert `left ≠ right` at 16/32/64; the arrays are the same objects every frame with values updated in place; a resolution of 128 throws WE's message; calling from a callback throws.

**WP6 — Media.** *Done:* `Scripting/Media/` (`MediaSessionState`, `MediaSessionSource`, `MacMediaSessionSource`, `MediaRemote`, `NowPlayingFramework`, `ArtworkPalette`, `SceneScriptMediaExtension`, `sceneScriptMedia.js`); `BrowserMediaIntegration.swift` deleted. WP11 keeps **one** `MacMediaSessionSource` for the process (MediaRemote registration is process-wide) and gives each runtime a `SceneScriptMediaExtension(source:)`. Pending changes are coalesced to the newest per kind and posted before each frame; each script gets the current state after its `init` (P8).

- Tests: a fake source drives all five events with WE's field names; the palette on fixture images; no AppleScript anywhere.

**WP7 — Object model (layers, scene, effects, materials).** *Done:* `Scripting/Objects/` and `Resources/SceneScript/objects-{values,animations,effects,layers,scene}.js`. Best guesses: destroying a parent destroys its children; `getLayer(number)` is a draw-order index, a string a name then an id; `createLayer` appends on top; a missing asset returns `null`. A layer's scripts get `destroy()` while it is still in the scene (SF11); written angles read back exactly (SF13). `createLayer` and `registerAsset` handles carry the calling script's `__workshopId`, and the host tries the path under that Workshop item first (`SceneScriptLayerSource.assetPaths`; replay RF1); layer strings reach the renderer only when they changed (RF2). WP11 duties: keep `worldMatrix`, `size`, `playing` and animation state current in the tables, read them after each frame's commands on the script thread, clear the dirty bytes. Originally planned as `Resources/SceneScript/layers.js`, `scene.js`; `Scripting/Objects/SceneScriptObjectTable.swift` (fill), `SceneScriptCommandRing.swift`.

- `getLayer*`, `enumerateLayers` and `getLayerIndex` in draw order with identity preserved; `getParent`/`getChildren`; degrees↔radians; copies on get; `getEffect(name|index).visible`; `getMaterial`/`setMaterialProperty` onto material constant slots; `getTextureAnimation`; particle `instance` and `emitParticles`; sound `play/stop/pause/volume`; scene settings.
- Tests: headless, against a table: writes stick; `thisLayer === getLayer(name)`; the angles unit; effect visibility toggles; an unknown member is inert rather than throwing, where WE members are inert.

### Step 2 (parallel)

**WP8 — Property binding.** *Done:* `Scripting/Binding/` (`SceneScriptBindingExtension`, `SceneScriptPropertyType`, `SceneScriptBoundProperty`, `SceneScriptSite`, `SceneScriptUserReference`, `SceneScriptUserProperties`, `SceneScriptSceneValue`, `sceneScriptBinding.js`) and `Scene/Loading/SceneScriptSiteBuilder.swift`. Usage (WP9, WP11), on the runtime's thread:

```swift
let properties = SceneScriptUserProperties(project: projectJSON)          // + set(_:to:) for the user's values
let builder = SceneScriptSiteBuilder(wallpaperID: id, userProperties: properties,
                                     slot: { model.slot(forObjectID: $0) })
let sites = builder.sites(in: try SceneScriptSiteBuilder.document(from: sceneJSONData))
binding.add(sites, to: runtime)                                          // binding: SceneScriptBindingExtension
runtime.load(userProperties: properties.payload())
runtime.userPropertiesDidChange(properties.payload(only: changedNames))  // later
```

- A site is every JSON object with a non-empty string `script` (object fields, `effects[i].visible`, `constantshadervalues`, `instanceoverride.*`, `general.*`, and anything else, which then binds to nothing). Order: `general.*` first (best guess), then objects in scene order, their fields `visible, origin, scale, angles, alpha, color, text`, other fields by name, effects (own fields, then constants), `instanceoverride`. Ids: `<wallpaper>/<name>#<id>/<path>` (`#i<index>` for objects without an id, `~2` for duplicates).
- Types come from the object model's field lists, else from the authored value's shape. `instanceoverride.colorn` is a number, as `lib.sceneScript.d.ts` types it, although scene.json writes a colour.
- The argument is the live value through the object model (P2) for its members; other fields (`brightness`) chain through the record. Vectors are fresh on every call (S7). A throwing getter or `toString` keeps the value and is reported as `<value>`.
- The object model's descriptions must carry user-resolved values (the table is the live value); the builder's initial value only seeds fields outside the model.
- Not done here: the renderer still reads `AudioReactiveScriptEngine` (WP11 deletes `resolveLayerVisibility` and `loadSceneScript` when it switches).

Originally planned: `Scene/Values/` (`SceneValueContext`, `SceneValueResolver`, `SceneParticleOverrides`, `SceneGeneralSettings`), `Scene/Loading/` script-site collection.

- Every `{"script":…}` site becomes a `ScriptInstance` with its field type, value, `scriptproperties` (user-bound entries resolved) and `thisObject` (layer, effect or particle system, per P9).
- Effect-visible, effect-constant, all `instanceoverride` fields, `general.*` and visible scripts run every frame.
- `update`/`init` chaining and return coercion.
- Delete `resolveLayerVisibility` and `loadSceneScript`.
- Tests: an accumulator script moves; `undefined` keeps the value; a text script never renders "undefined"; an effect hidden at load can be shown by a media event; `scriptproperties` from `{"user":…}` update on property change.

**WP9 — Corpus replay harness.** `OpenWallpaperEngineTests/SceneScriptCorpusTests.swift`, `SceneScriptTestHost.swift`, `Tests/Fixtures/SceneScript/` (synthetic scripts asserting the §1.9 behaviour).

- For every corpus wallpaper, build the real script sites from its `scene.json` or `.pkg` through WP8's collector, with a headless host (fake clock, silent and tone audio, scripted cursor path, media event sequence, property changes).
- Run load plus N = 600 frames.
- Assert:
  - (a) no uncaught exception, except in an allowlist keyed by script hash with a reason; each entry is an `XCTExpectFailure` naming the gap;
  - (b) no watchdog trips;
  - (c) every text site yields a string, not "undefined";
  - (d) every numeric or vector site yields finite values;
  - (e) expected effects per script class: clocks match `Date` formatting at a fixed clock, audio-driven fields vary under the tone and not under silence, cursor scripts react to the scripted click, media scripts set `thisObject.visible` from `hasThumbnail`;
  - (f) per-frame time under budget (`measure`).
- Skipped when the corpus folder is absent (CI). A small synthetic fixture set runs in CI.

**WP10 — Input and cursor events.** *Done:* `Scripting/Cursor/` (`SceneScriptCursorLayer`, `SceneScriptCursorFrame`, `SceneScriptCursorHitTest`, `SceneScriptCursorPass`, `SceneScriptCursorEvent`, `SceneScriptCursorExtension`, `sceneScriptCursor.js`); `WESceneObject.disablepropagation`; `solid` defaults to 1 in the table. Inbox kinds `cursor` (`.keep`) and `cursorMove` (`.latest`), both at `EVENT_ORDER.cursor`, targeted at the slot; a script gets them once its `init` ran. WP11 wiring: one `SceneScriptCursorExtension` per runtime; each frame `publish(SceneScriptCursorFrame(...))` with the scene-space cursor as WE's camera sees it (the unshaken point plus the shake offset, since WE shakes the eye), the left button for clicks the wallpaper receives, `parallax` only for an orthographic scene with parallax on, and the image and text layers in draw order. Best guesses: slots gone from the frame are forgotten; the cursor counts as moved on the first frame; fullscreen image layers (a flag at +0x304 that returns a hit everywhere) and models are not handled.

- Tests: `SceneScriptCursorHitTestTests` (rotated, scaled, parented, parallax, edge-on), `SceneScriptCursorPassTests` (enter/move/leave, click pairing, release elsewhere, drags, topmost first, `disablepropagation`, hidden layers), `SceneScriptCursorExtensionTests` (only the hit object's scripts, WE's event object, before `update`, one event object per script, a throwing callback, the table reader).

### Step 3 (serial)

**WP11 — Renderer integration and deletion.** *Done* (2026-09-26). How it runs:

- **Per wallpaper instance.** `SceneRendererScripts` (the renderer's side) owns a `SceneScriptWallpaper` (`Scripting/Host/`), which creates the runtime inside its `SceneScriptThread` (`thread.sync`) with every extension: WP4 over the one app-wide `SceneScriptStorage`, WP5 over `capture.audioSpectrumSnapshot`, WP6 over the one process-wide `MacMediaSessionSource`, WP7, WP8 (sites from `SceneScriptSiteBuilder`, bound to the slots WP7 gave the scene's objects) and WP10. `AppDelegate.sceneScriptServices` holds the shared parts and the prelude, read once. The runtime survives a content rebuild of the same document (a user property changed a layer) and restarts with a new document or wallpaper.
- **Frames.** Each draw hands the scripts the clock, the display (`engine` environment), `input` (screen pixels, the left button for desktop clicks while Finder is in front, the camera shake offset), the cursor pass's frame (WP10: scene cursor plus shake, parallax only for an orthographic scene with parallax on, the image and text layers in draw order) and every object as drawn (`SceneScriptFrameInput`), and runs a script frame with `asyncFrame`. What the last finished frame left (`SceneScriptFrameState`) is drawn from the next draw on: one frame of latency, and a hung script only drops script frames.
- **The tables.** `SceneScriptTableSync` writes the renderer's values (authored, user-bound, animated) into every field scripts don't own, and world matrices and sizes into all, before each frame (P2: an animated field gets the animation's value even when a script owns it; the script's return wins). After the frame a dirty slot's fields that changed become script-owned for good, and the renderer draws those from the table: origin, scale, angles, alpha, colour, visible, parallax depth, point size, instance overrides. Dirty bytes are cleared.
- **Commands** (`SceneScriptSceneMirror`, the object host): `createLayer` describes the layer from the asset (under the script's Workshop item first), a configuration or a copy (`SceneScriptSceneDescriber`), and the renderer builds it through the loader off the main thread; `destroyLayer` removes it and frees its GPU state after the in-flight frame; `sortLayer` reorders at once, particle systems keep their place among the layers; strings (text, font, alignments), `setMaterialProperty`/`IMaterial` writes (into the pass uniforms whose key matches), effect `visible`, particle `play`/`pause`/`stop`/`emitParticles`, and play/pause/stop/setFrame/rate of object property and texture animations (their timelines are evaluated at the animation's own time). Scene settings scripts set (bloom, camera shake and parallax) override the scene's.
- **Visibility.** The loader builds every object and effect, hidden ones included; visibility scripts run every frame (P6), a hidden parent hides its children, and hidden particle systems neither step nor draw.
- **User properties.** Every change reaches `applyUserProperties` with WE's raw payload (values typed as project.json declares them); the content is rebuilt only for a property the built content reads outside scripts (`SceneWallpaperViewModel.contentUserProperties`).
- **Halt.** A watchdog stop is logged, shown in a non-blocking panel like safe restart's (Retry reloads the wallpaper), and stops only that wallpaper's scripts; the renderer keeps drawing their last values.
- **Deleted:** `AudioReactiveScriptEngine`'s scripting (what remains, audio capture and user properties, is `Audio/WallpaperServices.swift`), `SceneScriptPropertiesShim`, the invented globals, the legacy 64-band spectrum and waveform, `resolveLayerVisibility`, the `script.js` guess, the per-field script sources the loader decoded, and `SceneValueContext.evaluateScript` (a scripted value starts from its fallback; the runtime owns it). Also `engine.isObjectValid` and `requestFeatures` (WP4's leftovers) are in.
- **Best guesses and gaps:** the left button counts only while Finder is frontmost (the wallpaper window ignores mouse events); fields outside the object model (`brightness`, `size`) are kept by their scripts but not drawn from them (no corpus site uses them); sound layers are not played, so their playback only changes `isPlaying()` (logged once); scene, effect and material animations and `executeMaterialFunction` are not script-controlled (WP12, logged once); `createLayer` draws image, text and shape layers, not particle systems; `fullscreen` layers and models are not hit-tested (WP10's gaps).
- **Tests:** `SceneScriptRenderTests` (headless renders of `Tests/Fixtures/Scenes/scripted*` through the real loader: an origin moves a layer, a layer hidden at load is shown and a visible one hidden, a material constant turns a tint green, `createLayer` draws, a user-bound script property reaches a text layer; two displays share nothing; a script-only user property reaches `applyUserProperties` without a rebuild; a hang halts only its wallpaper), `SceneScriptWallpaperTests` (ownership and P2, world matrices, create/sort/destroy, effects and constants, strings, playback, the cursor pass, animation control, the 1000-frame create/destroy churn), `SceneScriptSceneDescriberTests`, `UniformScriptWriteTests`, `SceneScriptInstanceOverridesTests`, and `SceneScriptLibraryCostTests` (the cost table below). The replay now uses the app's describer and WP10's cursor pass.
- **Cost** (§4.6), per frame, CPU time of the script thread for a whole script frame (renderer values into the tables, cursor pass, scripts, read-back), median of 240 frames on the local library's 21 scenes with scripts, Release: 0.10–0.26 ms, and 0.49 ms for 3453730450 (71 sites; p99 0.97 ms), almost all of it the scripts' own JavaScript (the host around them is about 0.05 ms); the render thread's share is 0.01–0.07 ms. Before, with the legacy engine on the render thread (Debug): 1.1–64 ms per frame, 3453730450 about 500 ms. Debug builds of the new path: 0.18–0.41 ms, 3453730450 0.72 ms; render thread 0.03–0.26 ms.

Originally planned:

- `SceneMetalRenderer`, `SceneObjectMotion` and `ParticleFrameInputs` read the object table.
- The command ring is executed there.
- `createLayer` from an asset path or config through the existing loaders (`Scene/Loading` builds one object at runtime).
- `destroyLayer` for any layer, freeing GPU state after the in-flight frame (reuse `deferredReleases`).
- `sortLayer` in the same frame.
- Delete `AudioReactiveScriptEngine`'s scripting half, the shim and the invented globals, and rename what remains per the architecture doc (move-only commit).
- Tests: the existing render tests plus `RenderCheckTests` for a scripted layer that moves, hides and shows; the clone stress test from test-risks (create and destroy 1000 frames, memory flat).

### Step 4 (after areas 3, 6 and 7)

**WP12** — Timeline and animation APIs (`getAnimation` on properties and scene, `IAnimation` bound to `SceneValueAnimation`); video textures; animation layers, bones, attachments, `lookAt`/`setParent`; `createModelData`; camera transforms. Each gets its own tests as its engine feature lands.

### Order and dependencies

```
WP0 ─┐
WP1 ─┴─ WP2 ─┬─ WP3 ─┐
             ├─ WP4 ─┤
             ├─ WP5 ─┼─ WP8 ─┬─ WP11 ─ WP12
             ├─ WP6 ─┤  WP9 ─┤
             └─ WP7 ─┘  WP10 ┘
```

WP9 starts as soon as WP3 lands (compile-only replay) and grows with each package. It is the progress meter: the allowlist should shrink to zero.
