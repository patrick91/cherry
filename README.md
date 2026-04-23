# Cherry

Small native macOS prototype for a `libghostty`-style shell with left-side tabs.

## Why this shape

- Uses SwiftUI for the window chrome and tab rail.
- Uses an AppKit-backed terminal canvas for the scrollable surface so it only draws visible rows.
- Defaults to unlimited scrollback while still rendering only visible rows.

## Run

```bash
swift run
```

Inside the prototype:

- Use the left rail to switch tabs.
- Use `New Tab` or `Cmd-T` to create another session.
- Use `Burst 1,000` or `Cmd-B` to stress the renderer.
- Use the command bar with `pwd`, `ls`, `bench`, `burst`, `top`, or `clear`.
