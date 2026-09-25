#!/bin/bash
# Copies glslangValidator/glslang + spirv-cross and their dylib dependencies into the built app
# bundle so shader translation works on machines without Homebrew.
#
#   ./Scripts/vendor-shader-tools.sh "/path/to/Open Wallpaper Engine.app"
#
# The runtime searches Contents/Resources/shader-tools before Homebrew and $PATH, so the vendored
# copies win automatically once present.

set -euo pipefail

APP="${1:-}"
if [[ -z "$APP" || ! -d "$APP" ]]; then
    echo "usage: $0 <path to Open Wallpaper Engine.app>" >&2
    exit 2
fi

DEST="$APP/Contents/Resources/shader-tools"
# Start from an empty folder every build. Rewriting a signed binary in place keeps its inode, and
# the kernel then checks its pages against the old cached signature and SIGKILLs it on launch
# ("rejecting invalid page"). Fresh files get fresh inodes.
rm -rf "$DEST"
mkdir -p "$DEST"

# Runs as a build phase, so bail out early when the vendored copies are already current.
if [[ -x "$DEST/glslangValidator" && -x "$DEST/spirv-cross" && "${FORCE_VENDOR:-0}" != "1" ]]; then
    if "$DEST/glslangValidator" --version >/dev/null 2>&1 && "$DEST/spirv-cross" --help >/dev/null 2>&1; then
        echo "shader tools already vendored in $DEST"
        exit 0
    fi
fi

resolve() {
    local name="$1"
    local found
    found=$(command -v "$name" 2>/dev/null || true)
    if [[ -z "$found" ]]; then
        for candidate in /opt/homebrew/bin /usr/local/bin /opt/local/bin; do
            if [[ -x "$candidate/$name" ]]; then found="$candidate/$name"; break; fi
        done
    fi
    [[ -n "$found" ]] || return 1
    readlink -f "$found" 2>/dev/null || python3 -c "import os,sys;print(os.path.realpath(sys.argv[1]))" "$found"
}

missing() {
    # Non-fatal by default so a contributor without the tools can still build; the app falls back
    # to Homebrew/$PATH at runtime and degrades to native effects only.
    echo "warning: $1 not found — shader tools will not be bundled. Install with: brew install glslang spirv-cross" >&2
    [[ "${STRICT_VENDOR:-0}" == "1" ]] && exit 1
    exit 0
}

GLSLANG=$(resolve glslangValidator || resolve glslang) || missing "glslangValidator/glslang"
SPIRV=$(resolve spirv-cross) || missing "spirv-cross"

echo "glslang:     $GLSLANG"
echo "spirv-cross: $SPIRV"

# glslangValidator is the name the app looks for first.
cp -f "$GLSLANG" "$DEST/glslangValidator"
cp -f "$SPIRV" "$DEST/spirv-cross"
chmod +x "$DEST/glslangValidator" "$DEST/spirv-cross"

# Copy every non-system dylib the binaries link against into DEST. Absolute references are
# repointed at @loader_path; @rpath references are kept and satisfied by adding @loader_path as an
# rpath, which is how Homebrew's glslang finds libglslang/libSPIRV-Tools.
SEARCH_DIRS=("$(dirname "$GLSLANG")/../lib" "$(dirname "$SPIRV")/../lib" /opt/homebrew/lib /usr/local/lib)

find_dylib() {
    local base="$1"
    for dir in "${SEARCH_DIRS[@]}"; do
        if [[ -f "$dir/$base" ]]; then
            python3 -c "import os,sys;print(os.path.realpath(sys.argv[1]))" "$dir/$base"
            return 0
        fi
    done
    # Fall back to any Homebrew opt/*/lib location.
    local hit
    hit=$(find /opt/homebrew/opt -maxdepth 3 -name "$base" -type f 2>/dev/null | head -n 1 || true)
    [[ -n "$hit" ]] && { echo "$hit"; return 0; }
    return 1
}

vendor_dylibs() {
    local binary="$1"
    local pending=1
    while [[ $pending -eq 1 ]]; do
        pending=0
        while read -r dep; do
            [[ -n "$dep" ]] || continue
            case "$dep" in
                /usr/lib/*|/System/*) continue ;;
                @loader_path/*|@executable_path/*) continue ;;
            esac
            local base source
            base=$(basename "$dep")
            [[ "$base" == "$(basename "$binary")" ]] && continue
            if [[ ! -f "$DEST/$base" ]]; then
                if [[ "$dep" == @rpath/* ]]; then
                    source=$(find_dylib "$base") || { echo "warning: could not locate $base" >&2; continue; }
                else
                    source="$dep"
                fi
                [[ -f "$source" ]] || { echo "warning: missing $source" >&2; continue; }
                cp -f "$source" "$DEST/$base"
                chmod +w "$DEST/$base"
                pending=1
            fi
            if [[ "$dep" != @rpath/* ]]; then
                install_name_tool -change "$dep" "@loader_path/$base" "$binary" 2>/dev/null || true
            fi
        done < <(otool -L "$binary" | tail -n +2 | awk '{print $1}')
    done
    install_name_tool -add_rpath "@loader_path" "$binary" 2>/dev/null || true
}

vendor_dylibs "$DEST/glslangValidator"
vendor_dylibs "$DEST/spirv-cross"
for lib in "$DEST"/*.dylib; do
    [[ -e "$lib" ]] || continue
    install_name_tool -id "@loader_path/$(basename "$lib")" "$lib" 2>/dev/null || true
    vendor_dylibs "$lib"
done

# Both tools are permissively licensed but redistribution requires shipping their license texts.
copy_license() {
    local binary="$1" name="$2" dir
    dir=$(dirname "$(dirname "$binary")")
    for candidate in "$dir/LICENSE.txt" "$dir/LICENSE" "$dir/COPYING"; do
        if [[ -f "$candidate" ]]; then
            cp -f "$candidate" "$DEST/LICENSE-$name.txt"
            return
        fi
    done
    echo "warning: no license file found for $name" >&2
}
copy_license "$GLSLANG" glslang
copy_license "$SPIRV" spirv-cross

# install_name_tool invalidates signatures, so re-sign. Nested executables must carry the same
# identity as the app for notarization, so prefer the identity Xcode is already using.
SIGN_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY_NAME:-${CODE_SIGN_IDENTITY:-}}"
# CODE_SIGNING_ALLOWED=NO (CI) still leaves CODE_SIGN_IDENTITY set, but no identity is available.
if [[ "${CODE_SIGNING_ALLOWED:-YES}" == "NO" || -z "$SIGN_IDENTITY" || "$SIGN_IDENTITY" == "-" \
      || "$SIGN_IDENTITY" == "Sign to Run Locally" ]]; then
    SIGN_IDENTITY="-"
    echo "note: signing shader tools ad-hoc; re-sign with your Developer ID before notarizing"
fi

# The hardened runtime enforces library validation, which only permits loading libraries signed by
# the same Team ID. These tools load their own sibling dylibs, and an ad-hoc signature carries no
# Team ID at all, so without this entitlement dyld refuses them outright.
ENTITLEMENTS="$(mktemp -t shader-tools-entitlements).plist"
cat > "$ENTITLEMENTS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
</dict>
</plist>
PLIST
trap 'rm -f "$ENTITLEMENTS"' EXIT

for file in "$DEST"/*; do
    case "$file" in
        *.txt) continue ;;
    esac
    if [[ "$SIGN_IDENTITY" == "-" ]]; then
        # Ad-hoc signatures carry no Team ID and cannot bear entitlements, so the hardened runtime
        # is left off; library validation is only enforced when it is on.
        codesign --force --sign - "$file" >/dev/null 2>&1 || true
    else
        case "$file" in
            *.dylib) entitlements=() ;;
            *) entitlements=(--entitlements "$ENTITLEMENTS") ;;
        esac
        # ${arr[@]+...}: bash 3.2 under `set -u` treats an empty array as unbound, which silently
        # skipped signing every dylib and left them with invalid signatures (SIGKILL on load).
        codesign --force --options runtime --timestamp=none ${entitlements[@]+"${entitlements[@]}"} \
            --sign "$SIGN_IDENTITY" "$file" >/dev/null
    fi
done

echo "--- verifying ---"
# Check stderr too: a dyld failure here means the tools are unusable at runtime, and redirecting
# only stdout previously let that pass silently.
for tool in glslangValidator spirv-cross; do
    # spirv-cross --version exits 1 normally, so only a dyld error or a signal (status >= 128,
    # e.g. SIGKILL for an invalid signature, which prints nothing) counts as failure.
    status=0
    output=$("$DEST/$tool" --version 2>&1) || status=$?
    if (( status < 128 )) && [[ "$output" != *"dyld"* ]]; then
        echo "$tool: OK"
    else
        echo "error: $tool cannot run (status $status):" >&2
        echo "$output" | head -n 3 >&2
        exit 1
    fi
done
echo "vendored into $DEST"
du -sh "$DEST" | awk '{print "size:", $1}'