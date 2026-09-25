#!/bin/bash
# Regenerates "Vendor/we-assets" from a local Wallpaper Engine install.
#
#   ./Scripts/vendor-we-assets.sh [assets-dir]
#
# The result is committed to the repository and copied into the app bundle by Xcode as an ordinary
# resource folder, so the app ships with working effects and needs no Wallpaper Engine install.
# This script exists only to refresh that folder when Wallpaper Engine updates; it is not part of
# the build.
#
# Kept: effect manifests, materials and their GLSL shaders (translated to Metal at runtime,
# per option set), the shared shaders/headers in `shaders/`, textures, models, particles and the
# SceneScript runtime, and the built-in fonts text layers name as "fonts/<file>" together with
# their licence files. Editor preview art and Direct3D (HLSL) shaders are left out.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$REPO/Vendor/we-assets"
ASSETS="${1:-}"

if [[ -z "$ASSETS" ]]; then
    CONFIGURED=$(defaults read com.winddog.wallpaper-engine WallpaperEngineAssetsDirectory 2>/dev/null || true)
    [[ -n "$CONFIGURED" ]] || { echo "usage: $0 <wallpaper_engine assets dir>" >&2; exit 2; }
    ASSETS="$CONFIGURED"
fi
[[ "$(basename "$ASSETS")" == "assets" ]] || ASSETS="$ASSETS/assets"
[[ -d "$ASSETS" ]] || { echo "error: $ASSETS is not a directory" >&2; exit 1; }

echo "source: $ASSETS"
rm -rf "$DEST"
mkdir -p "$DEST"

rsync -a --prune-empty-dirs \
    --exclude '*/preview*/' --exclude 'preview*/' --exclude '.DS_Store' \
    "$ASSETS/effects/" "$DEST/effects/"

rsync -a --prune-empty-dirs --exclude 'HLSL/' --exclude 'editor/' --exclude '.DS_Store' \
    "$ASSETS/shaders/" "$DEST/shaders/"

for dir in fonts materials models particles scripts; do
    [[ -d "$ASSETS/$dir" ]] || continue
    rsync -a --exclude '.DS_Store' "$ASSETS/$dir/" "$DEST/$dir/"
done

if [[ -f "$REPO/Scripts/we-assets-attribution.txt" ]]; then
    cp "$REPO/Scripts/we-assets-attribution.txt" "$DEST/ATTRIBUTION.txt"
fi

echo "done: $(find "$DEST" -type f | wc -l | tr -d ' ') files"
