# Cherry Sessions icon

A separate identity for the persistent-session test app: a cobalt tile, two mint/cyan terminal panes, and an amber live indicator. This keeps it distinguishable from Cherry's pink stacked icon when both apps are in the Dock.

- `source.svg`: editable vector design.
- `render.swift`: matching native Core Graphics renderer; draws every icon resolution directly.
- `AppIconSessions.png`: 1024 × 1024 preview with transparent corners.
- `AppIconSessions.icns`: packaged macOS icon, including 16–1024 pixel representations.

Regenerate from the repository root:

```sh
swift -module-cache-path /tmp/cherry-sessions-icon-cache Design/SessionsIcon/render.swift
```

The final `iconutil` step needs access to macOS image services and may need to run outside a restricted sandbox. The intermediate `.iconset` is generated and ignored.
