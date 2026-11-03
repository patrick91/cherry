#!/bin/bash

set -euo pipefail

SOURCE_DIR="${1:?Usage: $0 <ghostty-source-dir>}"
DEVICE_ZIG="$SOURCE_DIR/src/renderer/metal/Device.zig"
METAL_ZIG="$SOURCE_DIR/src/renderer/Metal.zig"

for file in "$DEVICE_ZIG" "$METAL_ZIG"; do
    if [ ! -f "$file" ]; then
        echo "[-] $(basename "$file") not found"
        exit 1
    fi
done

if grep -q 'LIBGHOSTTY_SPM_TEXTURE_STORAGE_PATCH' "$DEVICE_ZIG"; then
    echo "[+] Metal texture storage already patched"
    exit 0
fi

python3 - "$DEVICE_ZIG" "$METAL_ZIG" <<'PY'
from pathlib import Path
import sys

device_path = Path(sys.argv[1])
metal_path = Path(sys.argv[2])
device = device_path.read_text()
metal = metal_path.read_text()

replacements = [
    (
        """default_storage_mode: mtl.MTLResourceOptions.StorageMode,

/// The maximum 2D texture width and height supported by the device.
""",
        """default_storage_mode: mtl.MTLResourceOptions.StorageMode,

/// The default storage mode to use for MTLTexture resources.
default_texture_storage_mode: mtl.MTLResourceOptions.StorageMode,

/// The maximum 2D texture width and height supported by the device.
""",
    ),
    (
        """    const max_texture_size = queryMaxTextureSize(device);
    log.debug(
        "device properties default_storage_mode={} max_texture_size={}",
        .{ default_storage_mode, max_texture_size },
    );
""",
        """    // LIBGHOSTTY_SPM_TEXTURE_STORAGE_PATCH
    // MTLStorageModeShared is valid for textures on Apple GPUs, while Intel
    // and AMD macOS GPUs require managed textures even when hasUnifiedMemory is
    // true. Keep buffer storage unchanged, but choose texture storage from the
    // Metal GPU family as Apple recommends for CPU-updated textures.
    const default_texture_storage_mode: mtl.MTLResourceOptions.StorageMode = switch (comptime builtin.target.os.tag) {
        .ios => .shared,
        .macos => if (device.msgSend(
            bool,
            objc.sel("supportsFamily:"),
            .{mtl.MTLGPUFamily.apple1},
        )) .shared else .managed,
        else => default_storage_mode,
    };
    const max_texture_size = queryMaxTextureSize(device);
    log.debug(
        "device properties default_storage_mode={} default_texture_storage_mode={} max_texture_size={}",
        .{ default_storage_mode, default_texture_storage_mode, max_texture_size },
    );
""",
    ),
    (
        """        .default_storage_mode = default_storage_mode,
        .max_texture_size = max_texture_size,
""",
        """        .default_storage_mode = default_storage_mode,
        .default_texture_storage_mode = default_texture_storage_mode,
        .max_texture_size = max_texture_size,
""",
    ),
]

for old, new in replacements:
    if old not in device:
        print("[-] Device.zig structure block not found")
        sys.exit(1)
    device = device.replace(old, new, 1)

old_site = ".storage_mode = self.device.default_storage_mode"
new_site = ".storage_mode = self.device.default_texture_storage_mode"
if metal.count(old_site) < 4:
    print("[-] expected texture storage call sites not found")
    sys.exit(1)

metal = metal.replace(old_site, new_site)

# Buffers keep the device's default storage mode.
buffer_marker = """pub inline fn bufferOptions(self: Metal) bufferpkg.Options {"""
buffer_start = metal.find(buffer_marker)
if buffer_start == -1:
    print("[-] bufferOptions not found")
    sys.exit(1)

metal = (
    metal[:buffer_start]
    + metal[buffer_start:].replace(new_site, old_site, 1)
)

device_path.write_text(device)
metal_path.write_text(metal)
print("[+] patched Metal.zig and metal/Device.zig: split buffer and texture storage modes")
PY
