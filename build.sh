#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="RoryOrbit"
DISPLAY_NAME="Pulsar"
APP_VERSION="${APP_VERSION:-1.2.0}"
BUNDLE_ID="com.rory.roryorbit"
APP="$ROOT/${APP_NAME}.app"
BIN="$APP/Contents/MacOS/${APP_NAME}"

shopt -s nullglob
SOURCES=("$ROOT"/Sources/*.swift)
shopt -u nullglob

if [[ ${#SOURCES[@]} -eq 0 ]]; then
  echo "Error: no Swift source files found under $ROOT/Sources" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

ICON_PLIST=""
if [[ -f "$ROOT/Assets/AppIcon.icns" ]]; then
  cp "$ROOT/Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  ICON_PLIST=$'  <key>CFBundleIconFile</key>\n  <string>AppIcon</string>'
fi

if [[ -d "$ROOT/Assets/ProviderIcons" ]]; then
  shopt -s nullglob
  PROVIDER_ICONS=("$ROOT"/Assets/ProviderIcons/*.png)
  shopt -u nullglob
  if [[ ${#PROVIDER_ICONS[@]} -gt 0 ]]; then
    mkdir -p "$APP/Contents/Resources/ProviderIcons"
    cp "${PROVIDER_ICONS[@]}" "$APP/Contents/Resources/ProviderIcons/"
  fi
fi

xcrun swiftc \
  -O \
  -swift-version 5 \
  -target arm64-apple-macosx13.0 \
  -framework AppKit \
  -framework SwiftUI \
  -framework Security \
  -framework CryptoKit \
  -framework Combine \
  -lsqlite3 \
  "${SOURCES[@]}" \
  -o "$BIN"

chmod +x "$BIN"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key>
  <string>${DISPLAY_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>
${ICON_PLIST}
  <key>CFBundleVersion</key>
  <string>${APP_VERSION}</string>
  <key>CFBundleShortVersionString</key>
  <string>${APP_VERSION}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSUIElement</key>
  <true/>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

codesign \
  --force \
  --sign - \
  --identifier "$BUNDLE_ID" \
  --requirements "=designated => identifier \"${BUNDLE_ID}\"" \
  "$APP"

echo "Built: $APP"
