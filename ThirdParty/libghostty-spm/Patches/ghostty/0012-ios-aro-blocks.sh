#!/bin/bash
# iOS headers: aro (the C frontend behind Zig 0.17's translate-c) decides per
# target whether Apple blocks (`^`) are a language feature, and its
# `isBlocksSupported` still reads `Os.isAtLeast` under Zig 0.15's contract:
# `null` when the OS tag differs. Since 0.16 it answers `false` there, so every
# iOS target (device and simulator) translates CoreGraphics with blocks off
# and fails at `CGPath.h:392: error: blocks are not enabled`. Ask the version
# question for macOS only and answer yes for the rest of Darwin. This is the
# aro part of upstream libghostty-spm's 0017-zig-pkg-apple-targets.sh.
#
# Zig unpacks packages under <source>/zig-pkg/<name-version-hash>/, so aro is
# patched there: fetched first on a fresh tree, edited in place after. A later
# build never unpacks a package that is already there, so the edit stays.

set -euo pipefail

SOURCE_DIR="${1:?Usage: $0 <ghostty-source-dir>}"

MARKER="LIBGHOSTTY_SPM_IOS_ARO_BLOCKS"

cd "$SOURCE_DIR"

if ! ls -d zig-pkg/aro-* >/dev/null 2>&1; then
    # Cache directories come from the environment (build-ghostty.sh exports
    # the build's ZIG_GLOBAL_CACHE_DIR).
    zig build --fetch=all >/dev/null
fi

for dir in zig-pkg/aro-*; do
    [ -d "$dir" ] || { echo "[-] no aro package under zig-pkg/ after fetch"; exit 1; }
    target_zig="$dir/src/aro/Target.zig"

    if grep -q "$MARKER" "$target_zig"; then
        echo "[+] aro blocks patch already applied: $(basename "$dir")"
        continue
    fi

    python3 - "$target_zig" "$MARKER" <<'PYEOF'
import sys
from pathlib import Path

path = Path(sys.argv[1])
marker = sys.argv[2]
text = path.read_text()

old = """        if (target.os.isAtLeast(.macos, .{ .major = 10, .minor = 6, .patch = 0 })) |sup| return sup;
        // TODO: do iOS or other OSes have a min version?
        return target.os.tag != .macos;
"""
new = f"""        // Zig 0.16's isAtLeast answers false, not null, for another OS
        // tag; ask it about macOS only. ({marker})
        if (target.os.tag != .macos) return true;
        return target.os.isAtLeast(.macos, .{{ .major = 10, .minor = 6, .patch = 0 }}) orelse false;
"""

count = text.count(old)
if count != 1:
    print(f"[-] aro isBlocksSupported anchor matched {count} times in {path} (expected 1); aro changed, update this patch")
    sys.exit(1)

path.write_text(text.replace(old, new, 1))
print(f"[+] patched aro: blocks on every Darwin target ({path.parent.parent.parent.name})")
PYEOF
done
