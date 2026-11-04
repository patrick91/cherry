# Zig Patches

Patches to the Zig *standard library* for targets the pinned Zig only half
knows. `Script/prepare-zig-lib.sh` applies `<zig version>-ios-std.patch` to a
copy of the toolchain's `lib/` under the build cache (an APFS clone), never to
the installation itself, and `Script/build-ghostty.sh` hands that copy to the
iOS targets as `ZIG_LIB_DIR`. Every other target, and a Zig with no patch
here, builds against the stock std. Patches apply with `patch -p1` from the
lib directory (paths start at `std/`).

## Patches

- `0.17.0-ios-std.patch`: `process.can_replace` is false on iOS, tvOS,
  visionOS and watchOS. `Io.Threaded`'s vtable always references
  `processReplace`, whose Darwin path opens /dev/null through
  `null_file.fd`, and its `NullFile` has no `fd` on those systems, so any iOS
  program using `Io.Threaded` failed to compile (`no field named 'fd' in
  struct 'Io.Threaded.NullFile__struct_19'`). They cannot replace a process
  image anyway. Drop it once a Zig release fixes this.
