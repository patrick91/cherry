# Cherry for iPhone and iPad (prototype)

The plan is [docs/specs/ios-app.md](../docs/specs/ios-app.md). This directory
holds its P0 prototype:

- `CherryMobileKit/`: the app's UI-free layer (Swift package, iOS and
  macOS). `MacConnection` is a Mac's host over SSH; `DemoMac` is a Mac that
  lives in the app, with agents in every state, for the demo, previews,
  screenshots and tests.
- `App/`: the iOS app (SwiftUI, with libghostty-spm's `UITerminalView` for
  the full terminal).

## Build and test

```bash
swift test --package-path Mobile/CherryMobileKit
```

## Rules for tests

Tests never reach the user's real Macs, daemon or Cherry:

- SSH only to a private sshd on 127.0.0.1 (as
  `Scripts/test-remote-mac-loopback` does);
- a private `cherry-host` with its own `HOME` and sockets;
- `cherry control --no-start`;
- recorded JSON in place of the real `CherryMCP`.
