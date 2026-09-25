# Phase 2: real Wallpaper Engine shaders and effects

**Goal:** every WE effect — built-in or Workshop, single- or multi-pass — renders through WE's own shaders with WE's semantics. When this phase is done, the hand-written native effect stack is deleted.

**Status (2026-09-25):** M1–M7 landed on `deepratna/feature-work` (PR #2). M8 (library coverage sweep) and M9 (in-process compiler, binary archive) remain. Script access to effects (`getEffect`/`setMaterialProperty`) moved to the Phase 6 SceneScript rewrite.

**Sources:**
- Three research reports, kept in the session scratchpad and summarised here:
  - a corpus inventory of the WE install plus the 44-scene library;
  - WE runtime semantics, taken from linux-wallpaperengine ("LWE") and wallpaper-scene-renderer ("WSR");
  - Metal design options, with measurements on an M4.
- [`progress-snapshot.md`](progress-snapshot.md) §A lists the current defects this phase replaces.

## 1. What we have to run

These numbers are measured. Everything in this section is a requirement.

| Item | Count |
|---|---|
| Built-in effects | 46 (69 vert/frag pairs, 126 distinct sources) |
| Generic shaders in `assets/shaders` | 56 vert + 56 frag + 3 `.geom` + 14 headers. Image layers use genericimage2/3/4, particles use genericparticle, text uses font; there are also composite, bloom and passthrough shaders. |
| Workshop effect shaders in the library | 61 distinct. 39 library copies of built-ins differ from the install copy, so **the wallpaper's own copy wins**. |
| Distinct shaders the 44 scenes use | 94 |
| Distinct (shader, combo set) variants the 44 scenes use | 142–230 |
| Theoretical permutations of those shaders | 927,035 |
| Uniforms | 974 annotated with a `"material"` key, plus about 45 engine built-ins |
| Textures per shader | `g_Texture0…8`, so up to 9 slots |
| Multi-pass effects | 14; the largest have 16 and 20 passes |
| FBO formats | `rgba_backbuffer`, `rgba8888`, `r16f`, `rg1616f`, `r8` |
| FBO scales | divisors 1, 2, 4, 8 and 16, plus `fit` 256/512 |
| Pass commands | `copy`, `swap` |
| Conditions | on passes, binds and FBOs |
| Instance overrides in the scenes | 791 `constantshadervalues`, 496 `textures` (599 of the entries are null = keep the default), 176 `combos`; value forms are literal, `{user}`, `{script}` and `{animation}` |
| Layer kinds | composelayer 14, fullscreenlayer 11, projectlayer 2; `copybackground` 14; `colorBlendMode` > 0 on 15 layers |

Dialect features we must accept (counted in distinct files):
- `mul` 136, `CAST*` 114, int literals where a float is expected 108, `saturate` 71, local arrays 58, `frac` 48, loops 33, uniform arrays 33, derivatives 13, `atan2` 10, `texSample2DLod` 18, `#require LightingV1` 8, `gl_VertexID` 9, `gl_InstanceID` 4.
- There are no `#extension` directives and no `gl_FragData`.

## 2. Semantics we implement

The reference implementations agree on most of this. Where they disagree, the choice we make is noted.

**Preprocessing prelude**
- `mul(a,b)` becomes `((b)*(a))`, `ddy(x)` becomes `dFdy(-(x))`, `ddx` becomes `dFdx`.
- `frac` → `fract`, `lerp` → `mix`, `saturate(x)` → `clamp(x,0,1)`, `atan2` → `atan`.
- `fmod(x,y)` → `((x)-(y)*trunc((x)/(y)))`, `log10(x)` → `(log2(x)*0.30103)`.
- `CAST2/3/4/3X3` become the matching constructors, `float2/3/4` → `vecN`, `int2/3/4` → `ivecN`.
- `texSample2D` → `texture`, `texSample2DLod` → `textureLod`, and `GLSL` is defined as 1.
- All of these are **macros**, not string replacement, so identifiers like `fract` or `sample` are never corrupted (this fixes the `fractt` bug).
- Int/float mismatches are handled by the compiler's relaxed rules. The existing `pow`/`max` int overloads stay.

**Includes and requires**
- An `#include` is inlined after the last top-level `attribute`, `varying`, `uniform` or `struct` before `main`, and never inside an open `#if`. A file with two `main`s gets it at the top.
- Includes resolve against the wallpaper's own `shaders/` first, then the assets `shaders/`.
- `#require LightingV1` becomes a stub `PerformLighting_V1`, as LWE does.

**Combos**
- The value of each combo is decided in this order, highest priority first:
  1. the instance pass `combos` in scene.json;
  2. the effect pass combos in effect.json;
  3. the material pass `combos`;
  4. the `// [COMBO]` default.
- A sampler annotated with `"combo":"X"` sets X=1 when the slot has a texture. `require`/`requireany` are honoured (only LWE does this).
- WSR's format combos are also set: `TEX{N}FORMAT` = `FORMAT_R8`/`FORMAT_RG88` from the `.tex` format.

**Constants**, lowest priority first:
1. the annotation `default`;
2. the material `constantshadervalues`;
3. the instance pass `constantshadervalues`.

Each value may be a literal, `{user}`, `{script}` or `{animation}`, and is resolved every frame (LWE's live-binding behaviour). Other rules:
- The JSON key is the annotation's `"material"` name, matched case-sensitively first and then case-insensitively. As a fallback, the uniform name without its `g_` prefix also matches (WSR).
- Vectors are space-separated strings. A float with a string default is parsed as a float (LWE truncates it; we don't).
- Uniforms with no value and no default are set to 0.

**Built-in uniforms**

| Uniform | Value |
|---|---|
| `g_Time` | seconds since the scene started, no wrap |
| `g_Daytime` | `(h*60+m)/1440`, also bound under the alias `g_DayTime` |
| `g_Frametime` | frame time |
| `g_PointerPosition` | 0..1 with y = 0 at the bottom, in the layer's UV space, mapped through the fill/fit crop |
| `g_PointerPositionLast` | the previous frame's `g_PointerPosition` |
| `g_PointerState` | mouse-button state |
| `g_ParallaxPosition` | `0.5 + (mouse − 0.5)·influence` |
| `g_TexelSize` / `g_TexelSizeHalf` | from the real target size (LWE; WSR hard-codes 1080p) |
| `g_Texture{N}Resolution` | `(allocW, allocH, contentW, contentH)`; render targets use `(w,h,w,h)` |
| `g_Texture{N}Rotation` / `Translation` | sprite frame of an animated texture |
| `g_Texture{N}MipMapInfo`, `g_Texture{N}Texel` | derived from the texture |
| `g_Screen` | `(w, h, w/h)` |
| `g_ModelViewProjectionMatrix` (+Inverse), `g_ModelMatrix`, `g_ViewProjectionMatrix`, `g_Effect*Matrix`, `g_EffectTextureProjectionMatrix` (+Inverse) | per pass position; see *Matrices* below |
| `g_AudioSpectrum{16,32,64}{Left,Right}` | 0..1, real left and right channels. Uses LWE's curve: `0.35·log10(p)`, tilt, clamp, then move toward the target by at most 0.3 per frame. |
| `g_Color4`, `g_Color`, `g_Alpha`, `g_UserAlpha`, `g_Brightness` | the layer's values |
| `g_LightAmbientColor`, `g_LightSkylightColor` | from `general` |
| `g_EyePosition`, `g_ViewUp/Right/Forward` | camera |
| `g_RenderVar*` | per renderer |

**Matrices by pass position** (LWE):
- The base draw into the layer buffer uses `ortho(0,w,0,h)`.
- Intermediate passes draw a −1..1 quad with the identity matrix.
- The final pass draws the layer's quad in scene space with the camera's view-projection times the model matrix, where the model matrix includes the full parent transform and parallax.
- `g_EffectTextureProjectionMatrix` is the identity.

**Pass graph**
- `fbos[]` are scoped to one effect instance. Their size is the layer size divided by `scale`, or `fit` if given. The format maps to Metal:
  - `rgba_backbuffer` and `rgba8888` → `.rgba8Unorm`
  - `r16f` → `.r16Float`
  - `rg1616f` → `.rg16Float`
  - `r8` → `.r8Unorm`
- A `unique` FBO is not shared. A `clear` FBO is cleared when it is created.
- Each layer with effects owns two ping-pong targets, A and B, at the layer size:
  - The base pass draws the layer image into A.
  - A pass with no `target` renders the current input into the other buffer, and the buffers then **swap after that pass** (LWE's per-pass swap; the blur/godrays examples behave the same under WSR's per-effect swap).
  - A pass with a `target` renders into its FBO.
  - `bind {name,index}` puts the named FBO into slot `index`. `previous` means this effect's input, i.e. the buffer at the start of the effect.
  - Slot 0 defaults to the current input.
  - `command:"copy"` blits source to target; `"swap"` exchanges two FBOs.
  - Passes and binds with `conditions` (combo predicates) are skipped when they're false.
- The **last pass** of the last effect draws straight into the scene target, using the layer quad and the layer's material blending. Earlier passes are forced to Normal.
- A layer with no effects draws directly into the scene.
- `colorBlendMode > 0` appends `materials/util/effectpassthrough.json` with `BLENDMODE = colorBlendMode`.

**Blending** (color and alpha):

| Mode | Source factor | Destination factor |
|---|---|---|
| normal | ONE | ZERO |
| translucent | SRC_ALPHA | ONE_MINUS_SRC_ALPHA |
| additive | SRC_ALPHA | ONE |
| disabled | blending off | |

Alpha writes are off on the final pass (LWE).

**Scene targets**
- `_rt_FullFrameBuffer` is the scene rendered so far. Metal can't sample the attachment it is writing, so we **blit a copy** at the point a layer needs it, and only if some pass reads it that frame.
- `_rt_MipMappedFrameBuffer` is the same copy with generated mips.
- `_rt_imageLayerComposite_<id>` is a copy of layer `<id>`'s final output.

**Util layers**
- `composelayer` and `projectlayer` are passthrough: the base "image" is the scene under the layer's footprint, sampled through `v_ScreenCoord`. Without visible effects such a layer isn't drawn.
- `fullscreenlayer` makes the layer the size of the scene.
- `solidlayer` is a flat colour (`color`, `alpha`) at the layer size, or the scene size when the size is 0.

**Textures** (via TEXParser)
- Formats: RGBA8888, DXT1/3/5, RG88, R8, and embedded PNG/JPG.
- `.tex` flags: bit 0 = nearest filtering, bit 1 = clamp (the default is **repeat**).
- Sprite sheets come from the `TEXS` section.
- A sampler annotation's `default` (`util/white`, `util/noise`, …) fills an empty slot. Null instance texture entries keep the material or default texture.
- No sRGB conversion anywhere, which matches WE.

## 3. Architecture

These choices were measured on an M4; the numbers are from the design report.

**Toolchain: in-process.**
- We call glslang and SPIRV-Cross through their C APIs: about **1.3 ms per stage**. Spawning the processes costs about 110 ms per stage, mostly glslang's 50 ms of setup per launch. This also removes the bundled executables and their signing problems (ee68067).
- Until that lands (milestone M9), M1–M8 keep spawning the processes but go through the same Swift interface (`ShaderCompiler` protocol), so the swap only touches one file.

**Translation unit: one vertex+fragment pair × one resolved combo set.** Steps, in order:
1. Inline includes and apply requires.
2. Prepend the prelude macros and the resolved combo `#define`s.
3. Preprocess with glslang, so every `#if` is resolved before anything is rewritten.
4. Rewrite the pair:
   - every loose uniform from both stages goes into **one** `layout(std140, binding=0) uniform WEUniforms {…}` block;
   - each `sampler2D g_TextureN` gets `layout(binding=N)`;
   - varyings get locations assigned by name across both stages; a fragment input the vertex shader doesn't write gets a dummy vertex output;
   - attributes get fixed locations: `a_Position`=0, `a_TexCoord`=1, `a_Normal`=2, `a_Tangent4`=3, `a_Color`=4, `a_BlendIndices`=5, `a_BlendWeights`=6, `C1–C4`=7–10, `a_PositionC1`=11.
5. Parse, link and generate SPIR-V (OpenGL rules, std140).
6. SPIRV-Cross to MSL 2.3 with decoration bindings. That gives `[[buffer(0)]]` for `WEUniforms` in both stages and `[[texture(N)]]`/`[[sampler(N)]]` for `g_TextureN`.
7. Reflect the uniform layout: each member's offset, array stride and matrix stride, plus the block size.
8. Write the MSL and a layout JSON to the disk cache.
9. At runtime, call `makeLibrary(source:)` on a background queue. It costs about 45 ms cold per pair and about 0.05 ms on later launches thanks to the OS cache. Pipeline states are cached per (variant, target format, blend); an `MTLBinaryArchive` is optional (M9).

Prebuilt `.metallib` files are dropped. They gain nothing over the OS cache, and they need Xcode's `metal` tool, which users don't have.

**Buffer and texture slots**

| Slot | Contents |
|---|---|
| buffer 0 | `WEUniforms`, shared by both stages |
| buffers 27–30 | vertex streams |
| texture N / sampler N | `g_TextureN`; samplers come from the `.tex` flags |

**Uniform layout rules** (std140, from the prototype):
- A `vec3` followed by a float becomes `packed_float3`.
- A `mat3` is three 16-byte columns.
- `float x[N]` has a **16-byte stride**, which matters for the audio arrays.
- Values are written by name using the reflected offsets.

**Variant cache key:** `sha256(translatorRevision ‖ vertex source after includes ‖ fragment source after includes ‖ sorted resolved combos)`.
- Stored in `<cacheRoot>/variants/<key>.{vert,frag}.metal` + `<key>.layout.json`.
- `cacheRoot` is `~/Library/Caches/com.winddog.wallpaper-engine/shaders`, **not** inside the WE install or the wallpaper folders.

**Combos are compiled lazily**, per variant, when a scene loads.
- Real scenes need at most 230 variants, out of 1,871 theoretical for the built-ins alone. The first load costs about 2–50 ms per new variant, done in the background. Until a variant is ready, its layer renders **without** that effect; it never falls back to an approximation.
- Metal function constants are not an option, because combos gate declarations as well as code.

**Render graph.** Built once per scene load, re-encoded every frame:

```swift
struct ShaderVariantKey: Hashable { let vertex: ShaderSource; let fragment: ShaderSource; let combos: [String: Int] }
struct UniformMember { let name: String; let type: GLSLType; let offset: Int; let arrayStride: Int; let matrixStride: Int; let count: Int }
struct UniformLayout { let size: Int; let members: [String: UniformMember] }
struct TranslatedVariant { let vertexMSL: String; let fragmentMSL: String; let uniforms: UniformLayout?; let textureSlots: [Int]; let attributes: [String: Int] }
enum TextureSource { case layerInput, previous, effectFBO(Int), sceneCopy, sceneCopyMipmapped, layerComposite(String), asset(URL), defaultAsset(String) }
struct PassNode { let variant: CompiledVariant; let target: TargetRef; let inputs: [Int: TextureSource]
                  let constants: [String: ResolvedValue]; let builtins: BuiltinSet; let blend: BlendMode; let isFinal: Bool }
enum GraphStep { case render(PassNode), copy(from: TargetRef, to: TargetRef), swap(TargetRef, TargetRef), sceneSnapshot(mipmapped: Bool) }
final class LayerEffectGraph { let layerID: String; let steps: [GraphStep]; let targets: [TargetDescriptor] }
```

Per frame:
- Uniforms are written into a **3-frame ring buffer** (256-byte aligned slices).
- Targets come from a pool keyed by (w, h, format, usage).
- Intermediate passes use don't-care loads.
- The scene copy is a blit, which costs about 0.26 ms at 1440p.
- Layers whose inputs and uniforms haven't changed reuse last frame's output (M9).

**Performance budget.** At 1440p a full-screen pass costs about 1 ms and a blit about 0.26 ms. So:
- effects run at **layer size**, not screen size;
- FBO divisors are honoured;
- layers that don't change are cached.

A typical scene (10 layers × 2 effects) measured 37–53 ms on a shared, busy GPU. The target after M9 is under 8 ms for typical scenes on an idle M-series GPU, verified with the render-check timing test.

## 4. Milestones

Each milestone has its own commits and ends with passing tests. Every step removes an `XCTExpectFailure` or adds a test.

**M1: Translator v2 (pair, std140, bindings, locations, combos)**
- **M1.1** `Scene/Shaders/ShaderSource.swift`
  - Load a shader stage, preferring the wallpaper's copy, then the assets copy.
  - Inline includes at LWE's insertion point, and stub `#require`.
  - Parse `[COMBO]` declarations (name, default, options, `require`).
  - Parse uniform annotations: material, default, int, combo, require, requireany, mode, and default texture.
  - Tests: every built-in source parses; fixtures cover includes inside `#if` and two `main`s.
- **M1.2** `ShaderPrelude.swift`: the macro prelude described above. This replaces all string replacement in `SceneShaderTranslator`.
- **M1.3** `ShaderCompiler` protocol, with a `ProcessShaderCompiler` implementation (`glslangValidator -E`, `-G`, then `spirv-cross --msl --msl-decoration-binding --reflect`) that preprocesses, compiles and reflects.
- **M1.4** `PairRewriter.swift`: builds the `WEUniforms` block, adds sampler bindings, assigns varying locations by name, pins attribute locations, and inserts dummy outputs. Port the logic from `proto.py`, including its fixes: empty blocks, `mediump`/`lowp`, and array varyings.
- **M1.5** `VariantCache.swift`: the cache key above, the disk layout, and translation on a background queue. Makes `TranslatedVariant`.
- **M1.6** Tests:
  - every built-in pair at default combos translates; 130+ pairs are expected, with the 7 known exceptions listed as expected failures;
  - shake with `MASK=1`, `AUDIOPROCESSING=1` and `NOISE=1`;
  - texture N lands in slot N;
  - the layout offsets match a std140 reference.
- **M1.7** Delete `translateSharedShaders`/`translatePackageShaders`, the `.metallib` backfill, the bundled `.metal` shader cache in `Vendor/we-assets/.open-wallpaper-engine`, and `SceneShaderReflection`. Translation happens only through the variant cache.

**M2: Effect, material and pass model**
- **M2.1** `Scene/Format/EffectDocument.swift`
  - `effect.json`: passes (material, target, bind, command, source, compose, conditions), fbos (name, scale, fit, format, unique, clear, conditions), dependencies, replacementkey.
  - Use a tolerant JSON reader, because trailing commas occur.
- **M2.2** `MaterialDocument.swift`: pass shader, blending, depth, cull, textures, combos, constantshadervalues, alphawriting, usershadervalues.
- **M2.3** Make `WEObjectEffect`/`WEObjectEffectPass` complete and **element-wise**: all passes; `combos`, `textures` (nulls kept), `constantshadervalues` and `usertextures` for each pass; `visible` with every value form. This fixes B3 and B7, and removes their expected failure.
- **M2.4** Resolve effect files by **path**: the wallpaper's copy first, then the assets copy; `replacementkey` is used only as a fallback. The folder-name catalog goes away, which fixes A8.

**M3: Values**
- **M3.1** `Scene/Values/SceneValue.swift`: one resolver for literals, `{user,value}`, `{user:{name,condition}}`, `{script,scriptproperties,value}` and `{animation}`, reusing the existing script engine and keyframe code.
- **M3.2** `ConstantResolver`: annotation default, then material, then instance, keyed as in §2; vector and colour parsing; int handling.
- **M3.3** Tests: every value form from the library fixtures; precedence; string defaults on a float.

**M4: Built-in uniforms**
- **M4.1** `BuiltinUniforms.swift`: the table in §2, computed once per frame and once per pass.
- **M4.2** Audio: `AudioSpectrumProvider` with real left and right channels at 16/32/64 bins using LWE's curve and smoothing. The script `registerAudioBuffers` reads from the same source, which fixes E4 later.
- **M4.3** Matrices per pass position; pointer mapping into the layer's UV space.
- **M4.4** Texture metadata: `(alloc, content)` resolution and sprite rotation/translation, from TEXParser.

**M5: Pass graph**
- **M5.1** `Scene/Rendering/EffectGraphBuilder.swift`
  - Builds `LayerEffectGraph` from a layer, its effects, the documents and the combos.
  - Evaluates conditions, scopes FBOs to the effect, resolves binds, handles copy and swap, and appends the `colorBlendMode` passthrough.
- **M5.2** `RenderTargetPool.swift`: keyed by (w, h, format, usage); FBO sizes from scale or fit; ping-pong pairs; handles resize.
- **M5.3** `EffectGraphExecutor.swift`
  - Encodes the steps and writes uniforms into the ring buffer through the layout.
  - Binds textures and samplers per slot, sets the pipeline per (variant, format, blend), and draws the quad from a vertex buffer.
  - Makes the scene snapshot blit, and generates mips for the MipMapped variant.
- **M5.4** Tests: headless rendering of fixture effects (tint, blur 4-pass, godrays 5-pass, shake with a mask) on a 256×256 image, checking:
  - pipelines build (removes the A1 expected failure);
  - the output differs from the input where expected;
  - FBO sizes are right;
  - no Metal validation errors (run with the validation layer on).

**M6: Integrate with the renderer**
- **M6.1** `SceneMetalRenderer` draws layers through the graph:
  1. the base image into ping-pong A with the existing image draw;
  2. the effect passes;
  3. the final pass into the scene target.

  Layers without effects keep the existing direct draw.
- **M6.2** `_rt_FullFrameBuffer` snapshots are placed at the layer's position in object order. This includes composelayer, projectlayer, fullscreenlayer and copybackground (it fixes B1 for composition layers).
- **M6.3** Script and inspector hooks:
  - `setMaterialProperty` and `getEffect(...).visible` write into the pass constants and effect visibility;
  - the inspector lists the annotated uniforms of each effect, with labels, ranges and int flags, **from the shader annotations**, not from `SceneEffectRegistry`.

  (The full SceneScript rewrite is still Phase 6. This only connects the effect surface.)
- **M6.4** Workshop effects and `.pkg` wallpapers use the same path. Sources come from the wallpaper folder or the PKG through the `ShaderSource` loader.

**M7: Delete the approximations**
- **M7.1** Remove:
  - `NativeEffectStack.swift` and the effect kinds in `SceneShaders.metal`;
  - `SceneAuthoredEffectRanges.swift` and `effect-parameter-ranges.json`;
  - `SceneEffectRegistry` and its effect UI;
  - the aliases (VM:1079-1086), `zeroDisablesKeys`, the mask-slot guess, and the effect-related heuristics (lens_distorsion→hyperdrive, audiobars).
- **M7.2** Migrate existing per-effect user overrides (`_owe_effect_*`) to annotation-keyed values where there's a clear mapping. Drop the rest and log it once.

**M8: Coverage sweep**
- **M8.1** A test that loads every scene in a configurable library path, when present (skipped in CI), and asserts:
  - every referenced variant translates and its pipeline builds;
  - no effect is left without an implementation;
  - the log lists anything unsupported.
- **M8.2** Fix whatever the sweep finds: known candidates are `fluidsimulation`, r16f FBOs, `cursorripple` `fit` buffers, and the 16-pass workshop bloom. The goal is 100% of the pairs the library references.

**M9: Performance**
- **M9.1** In-process compiler: a `WEShaderToolchain` C module linking glslang and SPIRV-Cross statically, behind `ShaderCompiler`. Delete the process path and `Scripts/vendor-shader-tools.sh`.
- **M9.2** Uniform ring buffer, pipeline-state cache, and `MTLBinaryArchive` for pipelines.
- **M9.3** Cache unchanged layers (skip a layer's graph when its time-dependent inputs haven't changed); memoryless intermediate targets where possible.
- **M9.4** A timing test on the fixture scenes, with a regression budget.

## 5. Out of scope here (later phases)

- Particle and model shaders (genericparticle, geometry-shader expansion, puppet skinning) and lights/PBR: Phases 7 and 3.
- The base image through `genericimage4` instead of our image draw. After M6 this can be a single switch, because the same graph runs the base material pass.
- Text layer effects beyond using the same graph (Phase 3/5).
- Scene bloom/HDR (`general.bloom*`): after M6, using the WE bloom materials in `materials/util`, as LWE does.

## 6. Risks

| Risk | Mitigation |
|---|---|
| glslang relaxed rules differ from WE's HLSL compiler | The corpus sweep (M8) runs every referenced variant; fix dialect cases in the prelude or the rewriter with a test for each |
| First-time compile stalls on scene load | Translate in the background; layers render without the effect until ready; the in-process compiler (M9.1) cuts compile time about 90× |
| Bandwidth on heavy scenes | Layer-size targets, divisors, cached unchanged layers (M9.3); frame-rate cap stays |
| Linking the C toolchain for distribution | M9.1 is isolated behind a protocol; the process path keeps working until it lands |
