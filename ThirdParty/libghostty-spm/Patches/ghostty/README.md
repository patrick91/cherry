# Ghostty Patches

This directory is the single place for local upstream Ghostty patches used by
the `libghostty-spm` build pipeline.

## Rules

- Keep patches numbered so they apply in a stable order.
- Prefer standard unified diff files (`.patch`) when the upstream context is
  stable.
- Use executable patch scripts (`.sh`) only when upstream context is too
  unstable for a reliable diff.
- Keep generated binary inputs in `assets/` and copy them from the patch
  runner; Git binary patches are brittle when their surrounding source hunks
  need rebasing.
- Preserve newer Ghostty's renamed internal-library outputs when extending its
  Darwin static-library build path.
- Every patch in this directory must be safe to re-run.
- Patches here are applied automatically by `Script/build-ghostty.sh`, so they
  affect macOS, iOS, and Mac Catalyst builds equally.

## Current goal

This patch workflow exists so we can carry host-managed IO work required for
sandboxed iOS, macOS, and Mac Catalyst integration without hiding upstream
modifications inside ad-hoc build script edits.

The patches were last validated against Ghostty v1.4.0
(`83fb95624b0439ee660c2679b43b38c8b63769cd`, 2026-10-27) with Zig 0.17.0,
building the macOS and iOS slices (`./build.sh --platforms macos,ios`; Mac
Catalyst is not built). Run `Script/apply-patches.sh` twice against a clean
checkout before building: the second run must leave the checkout unchanged.

## iOS on Ghostty 1.4.0

Upstream no longer builds the full library for iOS (only libghostty-vt), but
its iOS code (the UIView surface, the Metal renderer) is still there. Our iOS
slices are that full build, which needs:

- `0004-ios-fixes.sh` (upstream libghostty-spm's current version): turns
  Config.zig's "iOS is not a supported target for the full Ghostty build"
  refusal into a comptime-false branch (marker
  `LIBGHOSTTY_SPM_IOS_FULL_BUILD`), puts an iOS 15.0 arm back in
  `osVersionMin`, and links Metal and MetalKit after pkg/macos's frameworks
  table (the older version of this script matched nothing on 1.4.0).
- `0011-ios-metallib.sh`: MetallibStep compiles the shaders for macOS only,
  so an iOS target had no metallib and configure panicked on
  `self.metallib.?`. Adds the iphoneos / iphonesimulator SDKs and their
  version flags (the iOS part of upstream's `0012-visionos.sh`).
- `0012-ios-aro-blocks.sh`: aro's `isBlocksSupported` reads Zig 0.15's
  `Os.isAtLeast` contract, so every iOS target translated CoreGraphics with
  blocks off (`CGPath.h:392: error: blocks are not enabled`). Edits the
  unpacked package under `zig-pkg/`, fetching it first on a fresh tree (the
  aro part of upstream's `0017-zig-pkg-apple-targets.sh`).
- `../zig/0.17.0-ios-std.patch`: Zig 0.17.0's std itself, see
  `../zig/README.md`.
