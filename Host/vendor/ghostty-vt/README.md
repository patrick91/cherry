# Ghostty VT build dependency

Cherry's host uses the upstream, headless `libghostty-vt` C API. It does not
depend on AppKit, GhosttyTerminal's Swift wrapper, a display server, or a GPU.

- Source: https://github.com/ghostty-org/ghostty
- Revision: `7aab0a0392369613472bd5dcfd66bef58e78c3ec`
- Zig: `0.16.0`; official download SHA256 values are pinned in `Scripts/build-host-vt`.
- Source patches: none.
- License: MIT; see `LICENSE`. The upstream build also bundles third-party
  dependencies identified by the pinned source's `build.zig.zon` and `vendor/`.
  Their notices are collected in `THIRD_PARTY_NOTICES.txt`; distribute both
  that file and `LICENSE` alongside binaries.

Run `Scripts/build-host-vt` from the repository root before building the Rust
workspace. The script downloads the exact source and toolchain, verifies the
toolchain archive, and builds the static library plus matching C headers into
this directory under the Rust target triple. Build caches and artifacts are
ignored. `ZIG`, `GHOSTTY_SRC`, and `CHERRY_VT_BUILD_CACHE` optionally select
existing build inputs; their version, revision, and clean source state are
checked. `CHERRY_GHOSTTY_VT_DIR` overrides the installed prefix for Cargo.

The library is built with `-Doptimize=ReleaseSafe`: the daemon parses untrusted
output from every session, so Zig's runtime safety checks (bounds, overflow,
unreachable) stay on. After a successful build the script writes two stamps
into the prefix, `SOURCE_REVISION` (the Ghostty revision) and `OPTIMIZE`
(`ReleaseSafe`); it deletes both before building, so an interrupted build
leaves none. `cherry-vt`'s build script refuses an archive whose stamps are
missing or different, including one built before the stamps existed, and asks
for `Scripts/build-host-vt` to be run. A prefix given with
`CHERRY_GHOSTTY_VT_DIR` needs the same stamps. `Scripts/build-host` and
`Scripts/test-host-linux` rebuild the library in this directory when it is
missing or its stamps do not match; `Scripts/build-host` skips that check when
`CHERRY_GHOSTTY_VT_DIR` is set. CI caches the built library keyed on the digest
of `Scripts/build-host-vt`, so a change to the pinned revision, Zig version, or
optimize mode rebuilds it.

Supported host targets are macOS arm64/x86_64 and GNU Linux arm64/x86_64.
Linux library builds target glibc 2.31; the final Rust binary must also be built
against an appropriate sysroot/container. Alpine/musl is not supported yet.
The library's internal snapshot format is used only to clone host state;
it is never sent over the wire. Renderer recovery uses ordinary VT bytes.
