#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_APP="$ROOT/RoryOrbit.app"
DIST_APP_NAME="Pulsar.app"
BUNDLE_ID="com.rory.roryorbit"
DIST_DIR="$ROOT/dist"

# Use physical path (pwd -P) so /var -> /private/var matches hdiutil/mount paths reliably.
RAW_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pulsar-dmg.XXXXXX")"
TMP_DIR="$(cd "$RAW_TMP_DIR" && pwd -P)"
STAGING_DIR="$TMP_DIR/staging"
RW_DMG="$TMP_DIR/Pulsar-rw.dmg"
RW_MOUNT="$TMP_DIR/rw_mount"
VERIFY_MOUNT="$TMP_DIR/verify_mount"

SKIP_BUILD=0
if [[ "${1:-}" == "--skip-build" ]]; then
  SKIP_BUILD=1
fi

detach_mount() {
  local mount_dir="$1"
  [[ -n "$mount_dir" && -d "$mount_dir" ]] || return 0
  if ! mount | grep -Fq " on ${mount_dir} "; then
    return 0
  fi

  local attempt
  for attempt in 1 2 3 4 5; do
    if hdiutil detach "$mount_dir" -quiet 2>/dev/null; then
      return 0
    fi
    sleep 0.5
  done
  hdiutil detach "$mount_dir" -force -quiet 2>/dev/null || true
}

cleanup() {
  detach_mount "$RW_MOUNT"
  detach_mount "$VERIFY_MOUNT"
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

if [[ "$SKIP_BUILD" -eq 0 ]]; then
  if [[ -n "${APP_VERSION:-}" ]]; then
    echo "==> [1/4] Building latest RoryOrbit.app (v${APP_VERSION})..."
    APP_VERSION="$APP_VERSION" bash "$ROOT/build.sh"
  else
    echo "==> [1/4] Building latest RoryOrbit.app..."
    bash "$ROOT/build.sh"
  fi
else
  echo "==> [1/4] Skipping build (--skip-build); using existing RoryOrbit.app..."
fi

if [[ ! -d "$SOURCE_APP" || ! -f "$SOURCE_APP/Contents/Info.plist" ]]; then
  echo "Error: expected app bundle/Info.plist not found at $SOURCE_APP" >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SOURCE_APP/Contents/Info.plist")"
if [[ -z "$VERSION" ]]; then
  echo "Error: CFBundleShortVersionString is empty in $SOURCE_APP/Contents/Info.plist" >&2
  exit 1
fi
APP_VERSION="$VERSION"
VOL_NAME="Pulsar ${VERSION}"
DMG_NAME="Pulsar-v${VERSION}-macOS-arm64.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"
SHA_PATH="${DMG_PATH}.sha256"

echo "==> [2/4] Staging ${DIST_APP_NAME} (v${VERSION}) and signing..."
mkdir -p "$STAGING_DIR" "$DIST_DIR"
ditto "$SOURCE_APP" "$STAGING_DIR/$DIST_APP_NAME"
xattr -cr "$STAGING_DIR/$DIST_APP_NAME" 2>/dev/null || true

codesign \
  --force \
  --deep \
  --sign - \
  --identifier "$BUNDLE_ID" \
  --requirements "=designated => identifier \"${BUNDLE_ID}\"" \
  "$STAGING_DIR/$DIST_APP_NAME"

codesign --verify --deep --strict "$STAGING_DIR/$DIST_APP_NAME"

ln -s /Applications "$STAGING_DIR/Applications"

echo "==> [3/4] Creating compressed UDZO DMG (${DMG_NAME})..."
rm -f "$DMG_PATH" "$SHA_PATH"

SETFILE_BIN=""
if command -v SetFile >/dev/null 2>&1; then
  SETFILE_BIN="$(command -v SetFile)"
elif xcrun --find SetFile >/dev/null 2>&1; then
  SETFILE_BIN="$(xcrun --find SetFile)"
fi

DMG_CREATED=0
if [[ -f "$ROOT/Assets/AppIcon.icns" && -n "$SETFILE_BIN" ]]; then
  cp "$ROOT/Assets/AppIcon.icns" "$STAGING_DIR/.VolumeIcon.icns"
  mkdir -p "$RW_MOUNT"
  if hdiutil create \
      -srcfolder "$STAGING_DIR" \
      -volname "$VOL_NAME" \
      -fs HFS+ \
      -format UDRW \
      -ov "$RW_DMG" >/dev/null \
    && hdiutil attach "$RW_DMG" \
      -mountpoint "$RW_MOUNT" \
      -nobrowse \
      -noautoopen \
      -noverify \
      -quiet; then
    "$SETFILE_BIN" -a C "$RW_MOUNT" || true
    sync
    detach_mount "$RW_MOUNT"
    if hdiutil convert "$RW_DMG" \
        -format UDZO \
        -imagekey zlib-level=9 \
        -ov \
        -o "$DMG_PATH" >/dev/null; then
      DMG_CREATED=1
    fi
  fi
  if [[ "$DMG_CREATED" -eq 0 ]]; then
    detach_mount "$RW_MOUNT"
    rm -f "$RW_DMG" "$STAGING_DIR/.VolumeIcon.icns"
  fi
fi

if [[ "$DMG_CREATED" -eq 0 ]]; then
  hdiutil create \
    -srcfolder "$STAGING_DIR" \
    -volname "$VOL_NAME" \
    -fs HFS+ \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov "$DMG_PATH" >/dev/null
fi

echo "==> [4/4] Mount-verifying DMG contents, signature, and checksum..."
mkdir -p "$VERIFY_MOUNT"
hdiutil attach "$DMG_PATH" \
  -mountpoint "$VERIFY_MOUNT" \
  -readonly \
  -nobrowse \
  -noautoopen \
  -quiet

MOUNTED_APP="$VERIFY_MOUNT/$DIST_APP_NAME"
if [[ ! -d "$MOUNTED_APP" ]]; then
  echo "Error: $DIST_APP_NAME missing inside mounted DMG" >&2
  exit 1
fi

if [[ ! -L "$VERIFY_MOUNT/Applications" ]]; then
  echo "Error: /Applications symlink missing inside mounted DMG" >&2
  exit 1
fi

codesign --verify --deep --strict "$MOUNTED_APP"

if [[ ! -f "$MOUNTED_APP/Contents/Resources/AppIcon.icns" ]]; then
  echo "Error: AppIcon.icns missing inside packaged $DIST_APP_NAME" >&2
  exit 1
fi

REQUIRED_ICONS=(
  pulsar
  pulsar-template
  antigravity
  codex
  cursor
  deepseek
  grok
  kimi
)
for icon_name in "${REQUIRED_ICONS[@]}"; do
  if [[ ! -f "$MOUNTED_APP/Contents/Resources/ProviderIcons/${icon_name}.png" ]]; then
    echo "Error: ProviderIcons/${icon_name}.png missing inside packaged $DIST_APP_NAME" >&2
    exit 1
  fi
done

PLIST_PATH="$MOUNTED_APP/Contents/Info.plist"
PLIST_DISPLAY="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$PLIST_PATH")"
PLIST_SHORT_VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST_PATH")"
PLIST_VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST_PATH")"
PLIST_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST_PATH")"
PLIST_ICON="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$PLIST_PATH")"

if [[ "$PLIST_DISPLAY" != "Pulsar" || "$PLIST_SHORT_VER" != "$APP_VERSION" || "$PLIST_VER" != "$APP_VERSION" || "$PLIST_ID" != "$BUNDLE_ID" || "$PLIST_ICON" != "AppIcon" ]]; then
  echo "Error: unexpected Info.plist metadata (DisplayName=$PLIST_DISPLAY, ShortVersion=$PLIST_SHORT_VER, Version=$PLIST_VER, ID=$PLIST_ID, Icon=$PLIST_ICON)" >&2
  exit 1
fi

detach_mount "$VERIFY_MOUNT"

(cd "$DIST_DIR" && shasum -a 256 "$DMG_NAME") > "$SHA_PATH"
(cd "$DIST_DIR" && shasum -a 256 -c "$(basename "$SHA_PATH")" >/dev/null)

DMG_SIZE="$(du -h "$DMG_PATH" | awk '{print $1}')"
echo "Packaged DMG: $DMG_PATH ($DMG_SIZE)"
echo "SHA-256:      $(cat "$SHA_PATH")"
