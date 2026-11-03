#!/bin/bash
# iOS shaders: Ghostty 1.4.0's MetallibStep compiles the Metal shaders for
# macOS only (`else => return null`), so an iOS target has no metallib and the
# configure step panics on `self.metallib.?` in SharedDeps.zig. Give it the
# iphoneos / iphonesimulator SDKs and their version flags back. This is the
# iOS part of upstream libghostty-spm's 0012-visionos.sh.

set -euo pipefail

SOURCE_DIR="${1:?Usage: $0 <ghostty-source-dir>}"

MARKER="LIBGHOSTTY_SPM_IOS_METALLIB"
METALLIB="$SOURCE_DIR/src/build/MetallibStep.zig"

if grep -q "$MARKER" "$METALLIB" 2>/dev/null; then
    echo "[+] iOS metallib patch already applied"
    exit 0
fi

if grep -q 'iphonesimulator' "$METALLIB"; then
    echo "[+] MetallibStep already builds for iOS"
    exit 0
fi

python3 - "$METALLIB" "$MARKER" <<'PYEOF'
import sys
from pathlib import Path

path = Path(sys.argv[1])
marker = sys.argv[2]
text = path.read_text()

replacements = [
    (
        "sdk",
        """    const sdk = switch (opts.target.result.os.tag) {
        .macos => "macosx",
        else => return null,
    };
    const platform_version_arg = switch (opts.target.result.os.tag) {
        .macos => "-mmacos-version-min",
        else => null,
    };
""",
        f"""    const sdk = switch (opts.target.result.os.tag) {{
        .macos => "macosx",
        // {marker}
        .ios => switch (opts.target.result.abi) {{
            .simulator => "iphonesimulator",
            else => "iphoneos",
        }},
        else => return null,
    }};
    const platform_version_arg = switch (opts.target.result.os.tag) {{
        .macos => "-mmacos-version-min",
        .ios => switch (opts.target.result.abi) {{
            .simulator => "-mios-simulator-version-min",
            else => "-mios-version-min",
        }},
        else => null,
    }};
""",
    ),
    (
        "min_version",
        """    else switch (opts.target.result.os.tag) {
        .macos => "10.14",
        else => unreachable,
    };
""",
        """    else switch (opts.target.result.os.tag) {
        .macos => "10.14",
        .ios => "11.0",
        else => unreachable,
    };
""",
    ),
]

for label, old, new in replacements:
    count = text.count(old)
    if count != 1:
        print(f"[-] MetallibStep.zig anchor {label} matched {count} times (expected 1); upstream changed, update this patch")
        sys.exit(1)
    text = text.replace(old, new, 1)

path.write_text(text)
print("[+] patched MetallibStep.zig: iphoneos and iphonesimulator shaders")
PYEOF
