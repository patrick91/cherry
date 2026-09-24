#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="CherryDev"
DISPLAY_NAME="Cherry Dev"
BUNDLE_ID="app.cherry.CherryDev"
MIN_SYSTEM_VERSION="14.0"
# CHERRY_SKIP_HOST=1 leaves out the Persistent Sessions helpers (no Rust
# needed); the debug app then looks for them in the Host build and on PATH.
SKIP_HOST="${CHERRY_SKIP_HOST:-0}"
# Only the app's runtime resource bundles, as in Scripts/install-local-app.
# After a test build the SwiftPM bin directory also holds
# Cherry_CherryTests.bundle, which does not belong in the app.
RESOURCE_BUNDLES="Cherry_Cherry.bundle GhosttyKit_GhosttyTerminal.bundle"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"

fail() {
  echo "$*" >&2
  exit 1
}

case "$SKIP_HOST" in
  0) BUNDLE_HOST=1 ;;
  1) BUNDLE_HOST=0 ;;
  *) fail "CHERRY_SKIP_HOST must be 0 or 1, not '$SKIP_HOST'" ;;
esac

if [[ "$BUNDLE_HOST" == 1 ]]; then
  # Cargo's precedence for its output directory, as Scripts/build-host uses.
  # A relative value is relative to the caller's directory.
  HOST_TARGET_DIR="${CARGO_TARGET_DIR:-${CARGO_BUILD_TARGET_DIR:-$ROOT_DIR/Host/target}}"
  case "$HOST_TARGET_DIR" in /*) ;; *) HOST_TARGET_DIR="$PWD/$HOST_TARGET_DIR" ;; esac
  export CARGO_TARGET_DIR="$HOST_TARGET_DIR"
  HOST_BIN_DIR="$HOST_TARGET_DIR/debug"
fi

cd "$ROOT_DIR"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

if [[ "$BUNDLE_HOST" == 1 ]]; then
  # Always build: Cargo's own fingerprints decide what is stale, also when
  # several checkouts share one target directory. With nothing to rebuild,
  # Cargo only puts the existing helpers back in place.
  "$ROOT_DIR/Scripts/build-host" debug \
    || fail "Building the Persistent Sessions helpers failed. Rerun with CHERRY_SKIP_HOST=1 to build $APP_NAME without them."
fi

swift build
BUILD_BIN_DIR="$(swift build --show-bin-path)"
BUILD_BINARY="$BUILD_BIN_DIR/Cherry"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_CONTENTS/Resources"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
if [[ "$BUNDLE_HOST" == 1 ]]; then
  # The GUI is named $APP_NAME, so on a case-insensitive volume `cherry`
  # stays a distinct file beside it.
  cp "$HOST_BIN_DIR/cherry" "$APP_MACOS/cherry"
  cp "$HOST_BIN_DIR/cherry-host" "$APP_MACOS/cherry-host"
  cmp -s "$BUILD_BINARY" "$APP_BINARY" \
    || fail "The $APP_NAME executable was overwritten; GUI and helper filenames must be distinct."
fi

# SwiftPM resource bundles must ship inside the app; Bundle.module fatalErrors
# without them (see Scripts/install-local-app).
for RESOURCE_BUNDLE in $RESOURCE_BUNDLES; do
  [[ -d "$BUILD_BIN_DIR/$RESOURCE_BUNDLE" ]] || fail "Missing resource bundle $BUILD_BIN_DIR/$RESOURCE_BUNDLE"
  cp -R "$BUILD_BIN_DIR/$RESOURCE_BUNDLE" "$APP_CONTENTS/Resources/"
done
for RESOURCE_BUNDLE in "$BUILD_BIN_DIR"/*.bundle; do
  [[ -e "$RESOURCE_BUNDLE" ]] || continue
  RESOURCE_NAME="$(basename "$RESOURCE_BUNDLE")"
  case " $RESOURCE_BUNDLES " in *" $RESOURCE_NAME "*) continue ;; esac
  case "$RESOURCE_NAME" in *Tests.bundle) continue ;; esac
  echo "note: not bundling $RESOURCE_NAME; add it to RESOURCE_BUNDLES here and in Scripts/install-local-app if the app loads it" >&2
done

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$DISPLAY_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$DISPLAY_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
