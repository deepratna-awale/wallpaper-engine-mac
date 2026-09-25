# CLAUDE.md

Guidance for AI coding sessions in this repository. Humans should read [`CONTRIBUTING.md`](CONTRIBUTING.md), and its rules apply here too.

- **Goal:** run *every* Wallpaper Engine wallpaper except the `application` type, not just the ones in a local library. Prefer general, WE-faithful implementations. Never add per-wallpaper or name/regex special cases.
- **Layout and responsibilities:** [`docs/architecture.md`](docs/architecture.md).
- **Feature status and known root causes:** [`docs/progress-snapshot.md`](docs/progress-snapshot.md).
- **The plan in progress:** [`docs/reorg-plan.md`](docs/reorg-plan.md) (Phase 1).

## Working rules

- **Verify against real WE data.** Check behaviour against a Wallpaper Engine install's `assets/` (effects, `shaders/common*.h`, materials, `scripts/`) and real `scene.json` files, not memory.
- **Keep moves separate.** Moves and renames are their own commits with no logic changes, and must build after each step.
- **Build from the command line:**

  ```
  xcodebuild -project "Open Wallpaper Engine.xcodeproj" -scheme "Open Wallpaper Engine" -configuration Debug build
  ```

  If Xcode isn't at the default path, set `DEVELOPER_DIR`.
- **Read runtime logs** with `/usr/bin/log show --predicate 'process == "Open Wallpaper Engine"'`. Some shells shadow `log` with a function, and `OWELog` messages are currently `<private>` in the unified log.
- **Test shader translation** by running glslang/spirv-cross on the preprocessed output. Failed translations are dumped to `/tmp/owe-failed-shaders/`.
- **Bump `SceneShaderTranslator.pipelineRevision`** whenever the translator's output can change.
