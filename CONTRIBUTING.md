# Contributing

Read [`docs/architecture.md`](docs/architecture.md) first. It explains the module layout and what goes where. This file holds the rules for changing the code. They exist because each of them was broken once and hid a real bug (see [`docs/progress-snapshot.md`](docs/progress-snapshot.md)).

## Building

- Open `Open Wallpaper Engine.xcodeproj`, scheme **Open Wallpaper Engine**, macOS 13+.
- **Debug builds sign with *Apple Development*.** macOS ties the Screen Recording grant (needed for audio-reactive features) to the signature, and ad-hoc signing loses it on every rebuild.
  - If you aren't on the project's team, set your own team in *Signing & Capabilities* and don't commit that change.
- **Shader toolchain:** `brew install glslang spirv-cross` for translating WE shaders.
- **WE assets:** point *Settings → General → Wallpaper Engine Assets Directory* at a Wallpaper Engine install. Otherwise the app uses the bundled copy.

## Where code goes

| You are adding… | Put it in… |
|---|---|
| A new WE file format or field | `Scene/Format/`: plain `Decodable` models, no side effects |
| Anything that reads a value that can be user-, script- or animation-bound | resolve it through `Scene/Values`; never read the raw JSON |
| Shader translation, reflection, caching | `Scene/Shaders/` |
| Metal drawing, render passes, render targets | `Scene/Rendering/` |
| A SceneScript API member | `Scene/Scripting/` (JS-side code in a bundled `.js` resource, not a Swift string) |
| A settings control or scene inspector UI | `Settings/` or `Scene/UI/`; the view model sits next to its view |
| Anything used by several features (logging, settings, asset paths) | `Core/` |

There is **one type per file** unless the types are tiny and private to it. A file over about 600 lines, or a function over about 80 lines, needs a reason. Split along a real seam.

## Rules

1. **Implement WE's behaviour, not a look-alike.**
   - Don't add native approximations of WE effects, invented parameter names, or remapped ranges.
   - Don't add special cases keyed on a layer, effect, file or property *name* (`"cloud"`, `"clock"`, `"snow"`…). If a wallpaper renders wrong, find the missing general feature.
   - The existing heuristics are listed in the progress snapshot (§B8) and are being removed.
2. **Fail loudly.**
   - Don't use `try?` on file IO, decoding, shader translation or pipeline creation. Use `do/catch` and log the error once, with the wallpaper, layer, effect and reason.
   - `try?` is fine for genuinely optional lookups, and a comment should say so.
   - Decode collections element by element, so one bad entry doesn't drop its siblings.
3. **No new global state.**
   - Don't add a new `static let shared`, `AppDelegate.shared` lookups from engine code, or `UserDefaults.standard` reads outside the settings store.
   - Pass dependencies in. State belongs to a wallpaper instance.
4. **Typed keys.** Don't add new `"_owe_…"` string keys. Add a case to the typed settings or property identifiers instead.
5. **Logging** goes through `OWELog`: `.debug` for per-frame detail, `.info` for lifecycle, `.error` for failures. Don't use `print` or raw `NSLog`, and don't log anything every frame at `.info` or above.
6. **Caches are versioned.** Any on-disk cache is keyed on its inputs *and* a revision constant you bump whenever the producing code changes. `SceneShaderTranslator.pipelineRevision` is the example.
7. **Concurrency.** Mark UI types `@MainActor`. Don't share mutable state across threads without an owner: prefer actors, or one lock that is documented and owns specific fields. Don't add `nonisolated(unsafe)` without a comment explaining why it's safe.
8. **Keep dead code out.** Delete it; git has history. Don't comment code out, and don't keep an unused alternate render path.

## Tests

- Every bug fix and feature comes with a test, once the test target exists (Phase 1). Put format and value tests in the unit-test target, and rendering checks in the headless render harness, with a small fixture wallpaper under `Tests/Fixtures/`.
- Before opening a PR, `xcodebuild build` and `xcodebuild test` must pass locally, and CI runs both.

## Commits and PRs

- Use [Conventional Commits](https://www.conventionalcommits.org/): `fix:`, `feat:`, `perf:`, `refactor:`, `build:`, `docs:`, `test:`.
- Keep commits small and single-purpose. File moves and renames go in their own commit with no logic changes, so review and `git log --follow` stay useful. Asset or vendor drops never share a commit with code.
- The PR description says what changed, why, and how it was verified.

## Changing the project file

- New files: once the project uses folder-synced groups (Phase 1), putting a file in the right folder is enough. Until then, add it through Xcode.
- `Resources/we-assets` is a **folder reference**. Don't let it become a synced group, or Xcode will try to compile the `.metal` files inside it.
