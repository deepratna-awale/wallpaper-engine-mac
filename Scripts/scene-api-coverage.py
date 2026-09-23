#!/usr/bin/env python3
"""Report which Wallpaper Engine script APIs the installed wallpapers use, and which of those
the SceneScript runtime does not implement yet.

    ./Scripts/scene-api-coverage.py [library-path]

Scripts live both inside each wallpaper's scene.json and in UserDefaults (per-object overrides
saved by the inspector), so both are scanned.
"""

import collections
import glob
import json
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_LIBRARY = "/Volumes/980Pro/OpenWallpaperStorage"
BUNDLE_ID = "com.winddog.wallpaper-engine"
OBJECTS = ("thisScene", "thisLayer", "thisObject", "engine", "input")


def collect_scripts(library):
    """Returns [(wallpaper_id, script_source)]."""
    found = []
    for path in glob.glob(os.path.join(library, "*", "scene.json")):
        wallpaper = os.path.basename(os.path.dirname(path))
        raw = open(path, encoding="utf-8", errors="replace").read()
        for match in re.finditer(r'"script"\s*:\s*"((?:[^"\\]|\\.)*)"', raw):
            try:
                found.append((wallpaper, json.loads('"' + match.group(1) + '"')))
            except ValueError:
                pass
    try:
        defaults = subprocess.run(["/usr/bin/defaults", "read", BUNDLE_ID],
                                  capture_output=True, text=True, timeout=120).stdout
        for match in re.finditer(r'\\"script\\"\s*:\s*\\"((?:[^\\]|\\.)*?)\\"', defaults):
            found.append(("<user override>", match.group(1).replace("\\\\n", "\n")))
    except Exception as error:                                  # noqa: BLE001
        print(f"note: could not read UserDefaults ({error})", file=sys.stderr)
    return found


def implemented():
    """APIs the runtime provides, parsed from the sources so this can't drift."""
    renderer = open(os.path.join(REPO, "Open Wallpaper Engine/WallpaperView/SceneMetalRenderer.swift"),
                    encoding="utf-8").read()
    engine = open(os.path.join(REPO, "Open Wallpaper Engine/Services/AudioReactiveScriptEngine.swift"),
                  encoding="utf-8").read()

    state = re.search(r"scriptLayers\[entry\.layer\.id\] = \[(.*?)\n                    \]",
                      renderer, re.S)
    layer = set(re.findall(r'"(\w+)":', state.group(1))) if state else set()
    layer |= set(re.findall(r"layer\.(\w+)\s*=", engine))

    scene = set()
    for block in re.finditer(r"var thisScene = \{(.*?)\n            \};", engine, re.S):
        scene |= set(re.findall(r"(\w+)\s*:", block.group(1)))

    shared = set(re.findall(r'"(\w+)":', engine)) | set(re.findall(r"engine\.(\w+)\s*=", engine))
    return {"thisScene": scene, "thisLayer": layer, "thisObject": layer,
            "engine": shared, "input": shared}


def main():
    library = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_LIBRARY
    scripts = collect_scripts(library)
    if not scripts:
        print(f"No scripts found under {library}")
        return 1

    supported = implemented()
    usage = collections.defaultdict(collections.Counter)
    users = collections.defaultdict(lambda: collections.defaultdict(set))
    for wallpaper, source in scripts:
        for obj in OBJECTS:
            for match in re.finditer(obj + r"\.(\w+)", source):
                usage[obj][match.group(1)] += 1
                users[obj][match.group(1)].add(wallpaper)

    print(f"library:          {library}")
    print(f"scripts analysed: {len(scripts)}\n")

    total_missing = 0
    for obj in OBJECTS:
        if not usage[obj]:
            continue
        impl = supported.get(obj, set())
        missing = [(n, c) for n, c in usage[obj].most_common() if n not in impl]
        total_missing += len(missing)
        print(f"=== {obj}: {len(usage[obj]) - len(missing)}/{len(usage[obj])} supported ===")
        for name, count in missing:
            affected = sorted(users[obj][name])
            shown = ", ".join(affected[:4]) + (", …" if len(affected) > 4 else "")
            print(f"    MISSING {count:4}x  {obj}.{name}")
            print(f"              used by: {shown}")
        if not missing:
            print("    (all used APIs supported)")
        print()

    print(f"total unimplemented APIs in use: {total_missing}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
