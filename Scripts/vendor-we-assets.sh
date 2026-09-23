#!/bin/bash
# Regenerates "Open Wallpaper Engine/Resources/we-assets" from a local Wallpaper Engine install.
#
#   ./Scripts/vendor-we-assets.sh [assets-dir]
#
# The result is committed to the repository and copied into the app bundle by Xcode as an ordinary
# resource folder, so the app ships with working effects and needs no Wallpaper Engine install.
# This script exists only to refresh that folder when Wallpaper Engine updates; it is not part of
# the build.
#
# Only derived/needed files are kept:
#   - translated Metal shaders (.metal/.metallib) and their reflection sidecars
#   - effect manifests and materials, minus editor preview art
#   - shared textures, models, particles and the SceneScript runtime
# GLSL sources and .sha256 translation stamps are excluded: the app has been verified to run
# without them, and they account for most of the source tree's size.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$REPO/Open Wallpaper Engine/Resources/we-assets"
ASSETS="${1:-}"

if [[ -z "$ASSETS" ]]; then
    CONFIGURED=$(defaults read com.winddog.wallpaper-engine WallpaperEngineAssetsDirectory 2>/dev/null || true)
    [[ -n "$CONFIGURED" ]] || { echo "usage: $0 <wallpaper_engine assets dir>" >&2; exit 2; }
    ASSETS="$CONFIGURED"
fi
[[ "$(basename "$ASSETS")" == "assets" ]] || ASSETS="$ASSETS/assets"
[[ -d "$ASSETS" ]] || { echo "error: $ASSETS is not a directory" >&2; exit 1; }

SHADER_SRC="$ASSETS/.open-wallpaper-engine/shaders"
if [[ ! -d "$SHADER_SRC" ]]; then
    echo "error: no translated shaders in $SHADER_SRC." >&2
    echo "       Point the app at this assets folder and let it finish translating first." >&2
    exit 1
fi

echo "source: $ASSETS"
rm -rf "$DEST"
mkdir -p "$DEST/.open-wallpaper-engine/shaders"

find "$SHADER_SRC" -type f \( -name '*.metal' -o -name '*.metallib' -o -name '*.reflection.json' \) \
    -exec cp {} "$DEST/.open-wallpaper-engine/shaders/" \;

rsync -a --prune-empty-dirs \
    --exclude '*/preview*/' --exclude 'preview*/' \
    --exclude '*.frag' --exclude '*.vert' --exclude '.DS_Store' \
    "$ASSETS/effects/" "$DEST/effects/"

for dir in materials models particles scripts; do
    [[ -d "$ASSETS/$dir" ]] || continue
    rsync -a --exclude '.DS_Store' --exclude '*.frag' --exclude '*.vert' \
        "$ASSETS/$dir/" "$DEST/$dir/"
done

cp "$REPO/Scripts/we-assets-attribution.txt" "$DEST/ATTRIBUTION.txt"

# Wallpaper Engine declares each uniform's authored default, range and label in a trailing JSON
# comment, its effects' grouping in effect.json, and the display strings in locale/ui_en-us.json.
# Distil all of it into one small table instead of shipping the GLSL and every localisation.
/usr/bin/python3 - "$ASSETS" "$DEST/effect-parameter-ranges.json" <<'PYTHON'
import json, os, re, sys

assets, out = sys.argv[1], sys.argv[2]
engine_root = os.path.dirname(assets.rstrip('/'))

trailing_comma = re.compile(r',(\s*[}\]])')

def load_json(path):
    """Wallpaper Engine's own parser tolerates trailing commas; several manifests rely on it."""
    try:
        text = open(path, encoding='utf-8-sig', errors='ignore').read()
    except OSError:
        return None
    try:
        return json.loads(text)
    except ValueError:
        try:
            return json.loads(trailing_comma.sub(r'\1', text))
        except ValueError:
            return None

strings = load_json(os.path.join(engine_root, 'locale', 'ui_en-us.json')) or {}

def display(key, fallback):
    text = strings.get(key)
    return text if isinstance(text, str) and text else fallback

pattern = re.compile(r'uniform\s+\w+\s+(\w+)\s*;\s*//\s*(\{.*\})')
table = {}
for effect in sorted(os.listdir(os.path.join(assets, 'effects'))):
    root = os.path.join(assets, 'effects', effect)
    manifest = os.path.join(root, 'effect.json')
    if not os.path.isdir(root) or not os.path.exists(manifest):
        continue
    meta = load_json(manifest)
    if meta is None:
        continue

    parameters = {}
    for directory, _, files in os.walk(root):
        relative = directory[len(root):]
        if '/preview' in relative or relative.startswith('/preview'):
            continue
        for name in files:
            if not name.endswith(('.frag', '.vert')):
                continue
            try:
                text = open(os.path.join(directory, name), encoding='utf-8', errors='ignore').read()
            except OSError:
                continue
            for _, payload in pattern.findall(text):
                try:
                    annotation = json.loads(payload)
                except ValueError:
                    continue
                material = annotation.get('material')
                span = annotation.get('range')
                if not material or not span or len(span) < 2 or span[1] <= span[0]:
                    continue
                key = material.lower()
                if key in parameters:
                    continue
                label = annotation.get('label') or f'ui_editor_properties_{key}'
                entry = {
                    'range': [span[0], span[1]],
                    'label': display(label, key.replace('_', ' ').title())
                }
                default = annotation.get('default')
                if isinstance(default, (int, float)):
                    entry['default'] = default
                elif isinstance(default, str) and default.replace(' ', '').replace('.', '').replace('-', '').isdigit():
                    # Vector defaults such as "1 1"; the components share one range.
                    entry['default'] = float(default.split()[0])
                if annotation.get('int'):
                    entry['int'] = True
                parameters[key] = entry

    if not parameters:
        continue
    group = meta.get('group') or 'other'
    table[effect.lower()] = {
        'group': group,
        'groupTitle': display(f'ui_editor_effects_modal_group_{group}', group.title()),
        'title': display(meta.get('name', ''), effect.replace('_', ' ').title()),
        'parameters': parameters
    }

json.dump(table, open(out, 'w'), separators=(',', ':'), sort_keys=True)
total = sum(len(e['parameters']) for e in table.values())
groups = sorted({e['group'] for e in table.values()})
print(f"  effect ranges: {len(table)} effects, {total} parameters, groups: {', '.join(groups)}")
PYTHON

for section in .open-wallpaper-engine effects materials models particles scripts; do
    [[ -d "$DEST/$section" ]] || continue
    printf '  %-24s %s files\n' "$section" "$(find "$DEST/$section" -type f | wc -l | tr -d ' ')"
done
du -sh "$DEST" | awk '{print "total:", $1}'
echo "remember to commit $DEST"