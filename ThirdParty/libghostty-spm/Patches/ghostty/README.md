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
building the macOS slices (`./build.sh --platforms macos`). Run
`Script/apply-patches.sh` twice against a clean checkout before building: the
second run must leave the checkout unchanged.
