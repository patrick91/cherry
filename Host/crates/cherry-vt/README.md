# cherry-vt

Safe ownership wrapper around a pinned upstream libghostty-vt, using a small C
shim compiled against the matching upstream headers rather than duplicating
complex C struct layouts in Rust. A terminal can move between threads (`Send`)
but cannot be accessed concurrently (`!Sync`). Ghostty callbacks run
synchronously and append PTY replies into a stable owned allocation.

`feed` consumes workload output and returns terminal-query replies for the
host to write to the PTY. `resize` may also return size-report bytes. The host
must remove answered queries and mode 2048 from the frontend's display stream;
otherwise the frontend can generate duplicate replies.
Size queries use the session's rows/columns and nominal 8×16 pixel cells.
Color queries currently report a fixed dark default (light gray foreground,
black background); synchronizing the desktop theme to the host is deferred.

`snapshot` produces VT bytes, beginning with a reset, to feed a fresh renderer
at the same dimensions. It preserves the primary buffer beneath an active
1049 alternate buffer, retained scrollback, styles, input modes, cursor,
pending wrap (including wide final cells), and unfinished UTF-8/control
continuations. The internal binary snapshot API is used only for a temporary
clone so exporting a snapshot never changes the running terminal.

Current limits: terminal graphics are not restored; theme/palette and OSC 7
are not exported; cursor shape is not restored; arbitrary saved cursor slots
and an inactive alternate buffer are not reconstructed. Alternate-screen
primary restoration is tested for the normal 1049 transition used by Neovim.
Legacy 47/1047 saved-cursor semantics are not guaranteed yet. Continuations
over 1 MiB cause an explicit snapshot error. The host also bounds individual
control strings before they reach this library.

Validation:

```
Scripts/build-host-vt
cargo test --manifest-path Host/Cargo.toml -p cherry-vt
cargo test --manifest-path Host/Cargo.toml -p cherry-vt --test neovim -- --ignored
```

The opt-in Neovim test starts real Neovim on a PTY, supplies query replies,
reconstructs its screen in a second terminal, exits the editor, and compares
both terminal states with the original shell screen visible again.
