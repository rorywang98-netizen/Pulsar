#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="RoryOrbit"
BUNDLE_ID="com.rory.roryorbit"
APP_SRC="$ROOT/${APP_NAME}.app"
APP_DST="/Applications/${APP_NAME}.app"
BIN="$APP_DST/Contents/MacOS/${APP_NAME}"
SUPPORT_DIR="$HOME/Library/Application Support/${APP_NAME}"
PLIST="$HOME/Library/LaunchAgents/${BUNDLE_ID}.plist"
GUI_DOMAIN="gui/$(id -u)"

REBUILD=0
START_SERVICE=1
for arg in "$@"; do
  case "$arg" in
    --rebuild) REBUILD=1 ;;
    --no-start) START_SERVICE=0 ;;
    *)
      echo "Unknown option: $arg" >&2
      echo "Usage: $0 [--rebuild] [--no-start]" >&2
      exit 2
      ;;
  esac
done

if [[ $REBUILD -eq 1 || ! -d "$APP_SRC" ]]; then
  bash "$ROOT/build.sh"
fi

mkdir -p "$SUPPORT_DIR" "$HOME/Library/LaunchAgents"
chmod 700 "$SUPPORT_DIR"

# Cleanly stop ONLY any previous RoryOrbit instance managed by launchd.
launchctl bootout "${GUI_DOMAIN}/${BUNDLE_ID}" 2>/dev/null || true

# Wait briefly for any prior RoryOrbit process to exit gracefully (never touch other apps).
for _ in {1..15}; do
  if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done

rm -rf "$APP_DST"
ditto "$APP_SRC" "$APP_DST"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${BUNDLE_ID}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${BIN}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>ThrottleInterval</key>
  <integer>15</integer>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${HOME}/.local/bin</string>
    <key>HOME</key>
    <string>${HOME}</string>
  </dict>
  <key>StandardOutPath</key>
  <string>${SUPPORT_DIR}/roryorbit.out.log</string>
  <key>StandardErrorPath</key>
  <string>${SUPPORT_DIR}/roryorbit.err.log</string>
</dict>
</plist>
EOF

chmod 600 "$PLIST"

if [[ $START_SERVICE -eq 1 ]]; then
  launchctl bootstrap "$GUI_DOMAIN" "$PLIST"
  echo "Installed & started: $APP_DST ($PLIST)"
else
  echo "Installed (not started): $APP_DST ($PLIST)"
fi
