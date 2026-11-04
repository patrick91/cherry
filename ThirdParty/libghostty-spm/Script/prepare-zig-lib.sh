#!/bin/bash
# Stages a copy of the Zig on PATH's lib/ with Patches/zig/<version>-ios-std.patch
# applied, and prints its path; prints nothing when that Zig has no patch.
# The toolchain itself is never changed. See Patches/zig/README.md.

set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f .root ]; then
    echo "[*] malformed project structure" >&2
    exit 1
fi

OUTPUT_ROOT=${1:?Usage: $0 <output_root>}

ZIG_VERSION=$(zig version)
PATCH="$(pwd)/Patches/zig/$ZIG_VERSION-ios-std.patch"
[ -f "$PATCH" ] || exit 0

ZIG_LIB=$(zig env | sed -n 's/^ *\.lib_dir = "\(.*\)",$/\1/p')
if [ ! -d "$ZIG_LIB/std" ]; then
    echo "[!] zig lib directory not found: $ZIG_LIB" >&2
    exit 1
fi

PATCH_HASH=$(shasum -a 256 "$PATCH" | cut -c1-16)
STAGED="$OUTPUT_ROOT/zig-lib-$ZIG_VERSION-$PATCH_HASH"

if [ ! -f "$STAGED/.patched" ]; then
    rm -rf "$STAGED" "$STAGED.partial"
    mkdir -p "$OUTPUT_ROOT"
    # A clone on APFS: the copy costs no space until a file changes.
    cp -Rc "$ZIG_LIB" "$STAGED.partial" 2>/dev/null || cp -R "$ZIG_LIB" "$STAGED.partial"
    patch -p1 -s -d "$STAGED.partial" <"$PATCH" >&2
    touch "$STAGED.partial/.patched"
    mv "$STAGED.partial" "$STAGED"
    echo "[+] staged Zig $ZIG_VERSION lib with $(basename "$PATCH")" >&2
fi

echo "$STAGED"
