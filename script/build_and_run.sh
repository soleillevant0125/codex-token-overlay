#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="CodexTokenOverlay"
PROCESS_NAME="CodexTokenOverlayMac"
BUNDLE_ID="io.github.soleillevant0125.CodexTokenOverlay"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$PROCESS_NAME"
ARCH="$(uname -m)"

if [[ "$ARCH" != "arm64" && "$ARCH" != "x86_64" ]]; then
  echo "unsupported macOS architecture: $ARCH" >&2
  exit 2
fi

pkill -x "$PROCESS_NAME" >/dev/null 2>&1 || true

"$ROOT_DIR/macos/script/package_app.sh" \
  --arch "$ARCH" \
  --configuration debug \
  --version 0.2.0-dev \
  --output "$DIST_DIR"

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
    /usr/bin/log stream --info --style compact --predicate "process == \"$PROCESS_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 2
    pgrep -x "$PROCESS_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
