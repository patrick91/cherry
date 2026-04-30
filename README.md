# Cherry

Small native macOS prototype for a `libghostty`-style shell with left-side tabs.

## Why this shape

- Uses SwiftUI for the window chrome and tab rail.
- Uses an AppKit-backed terminal canvas for the scrollable surface so it only draws visible rows.
- Each tab now owns a live PTY-backed shell.
- Defaults to 50,000 lines of scrollback while still rendering only visible rows.

## Current State

- Works with a real login shell and real command output.
- Supports direct typing after clicking the terminal surface.
- Does not yet implement a full VT renderer, so TUIs such as `vim`, `top`, or `less` will still render imperfectly until `libghostty` is wired in.

## Run

```bash
swift run Cherry
```

## Local Install

Build and install a local `.app` copy into `~/Applications`:

```bash
Scripts/install-local-app
open ~/Applications/Cherry.app
```

Run the installer again after making changes to replace the installed copy.
You can customize the destination/name if you want a separate dogfood build:

```bash
CHERRY_APP_NAME="Cherry Local" CHERRY_INSTALL_DIR="$HOME/Applications" Scripts/install-local-app
```

By default the installer uses ad-hoc signing, which can make macOS privacy
permissions reset after each rebuild because the code identity changes. To keep
Desktop/Documents/etc. permissions stable, sign local builds with a persistent
certificate:

```bash
CHERRY_CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)" Scripts/install-local-app
```

If you do not have an Apple development certificate, create a local code-signing
certificate in Keychain Access and pass its common name as `CHERRY_CODESIGN_IDENTITY`.

Inside the prototype:

- Use the left rail to switch tabs.
- Use `New Tab` or `Cmd-T` to create another shell session.
- Click inside the terminal to type directly.
- Use the `Prototype` menu commands for interrupt, restart, and clearing scrollback.

## MCP Control

Cherry also bundles a local MCP helper that controls the visible app. After
installing the local app, register the bundled helper with your harness:

```bash
codex mcp add cherry -- "$HOME/Applications/Cherry.app/Contents/Helpers/CherryMCP"
claude mcp add --scope user cherry -- "$HOME/Applications/Cherry.app/Contents/Helpers/CherryMCP"
```

During development, you can also run the helper from SwiftPM:

```bash
swift run CherryMCP
```

Run the Cherry app first. The app listens on a per-user Unix socket at
`/tmp/cherry-$UID/control.sock`; the MCP helper exposes tools for listing,
creating, selecting, reading, searching, clearing, restarting, closing, and
sending input to visible Cherry terminal tabs. It can also list configured
agent tools and launch a new configured agent in the active project window.

## Rendering Debug

Run the terminal fixture inside Cherry and Ghostty side by side:

```bash
Scripts/terminal-hell-test
```

The most useful panels for background rendering bugs are `256-color and truecolor full-row backgrounds`, `Reset boundaries and inverse video`, and `Codex-style prompt paint`.

To capture the actual PTY stream while reproducing a rendering bug:

```bash
CHERRY_TRACE_PTY_DIR=/tmp/cherry-traces swift run
```

Then inspect the latest trace for palette queries and background SGR:

```bash
Scripts/analyze-terminal-trace /tmp/cherry-traces/*.pty --show-erase
```

Raw traces can include terminal output and prompt text, so treat them like logs.
