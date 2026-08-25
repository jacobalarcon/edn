#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_PATH="$ROOT_DIR/dist/EDN.app"
VERSION="${EDN_DMG_VERSION:-${EDN_VERSION:-0.1.0}}"
DMG_PATH="$ROOT_DIR/dist/EDN-$VERSION.dmg"
IDENTITY="${EDN_CODE_SIGN_IDENTITY:--}"
VOLUME_NAME="EDN Installer"

if [[ ! -d "$APP_PATH" ]]; then
    echo "EDN.app is missing; run scripts/build-app.sh first." >&2
    exit 1
fi

WORK_DIR="$(mktemp -d)"
STAGING_DIR="$WORK_DIR/staging"
RW_DMG="$WORK_DIR/EDN-rw.dmg"
MOUNT_PATH=""

cleanup() {
    if [[ -n "$MOUNT_PATH" ]] && mount | grep -Fq " on $MOUNT_PATH "; then
        hdiutil detach "$MOUNT_PATH" -quiet || true
    fi
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$STAGING_DIR/.background"
ditto "$APP_PATH" "$STAGING_DIR/EDN.app"
ln -s /Applications "$STAGING_DIR/Applications"
"$ROOT_DIR/Packaging/render-dmg-background.swift" "$STAGING_DIR/.background/background.png"

case "$DMG_PATH" in
    "$ROOT_DIR/dist/EDN-"*.dmg) rm -f "$DMG_PATH" "$DMG_PATH.sha256" ;;
    *) echo "Refusing unsafe disk-image output path: $DMG_PATH" >&2; exit 1 ;;
esac

hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING_DIR" \
    -format UDRW \
    -ov \
    "$RW_DMG" >/dev/null

ATTACH_OUTPUT="$(hdiutil attach "$RW_DMG" -readwrite -noverify -noautoopen)"
MOUNT_PATH="$(printf '%s\n' "$ATTACH_OUTPUT" | awk '/\/Volumes\// { sub(/^.*\/Volumes\//, "/Volumes/"); print; exit }')"
if [[ -z "$MOUNT_PATH" || ! -d "$MOUNT_PATH" ]]; then
    echo "Could not mount the EDN disk image for layout." >&2
    exit 1
fi

osascript <<APPLESCRIPT
set backgroundImage to POSIX file "$MOUNT_PATH/.background/background.png" as alias
tell application "Finder"
    tell disk "$VOLUME_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {120, 120, 780, 542}
        set viewOptions to icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 104
        set text size of viewOptions to 13
        set background picture of viewOptions to backgroundImage
        set position of item "EDN.app" of container window to {170, 220}
        set position of item "Applications" of container window to {490, 220}
        close
        open
        update without registering applications
        delay 2
        close
    end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$MOUNT_PATH" -quiet
MOUNT_PATH=""

hdiutil convert "$RW_DMG" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    -o "$DMG_PATH" >/dev/null

hdiutil verify "$DMG_PATH" >/dev/null

if [[ "$IDENTITY" != "-" ]]; then
    codesign --force --timestamp --sign "$IDENTITY" "$DMG_PATH"
    codesign --verify --strict --verbose=2 "$DMG_PATH"
fi

(cd "$ROOT_DIR/dist" && shasum -a 256 "$(basename "$DMG_PATH")" > "$(basename "$DMG_PATH").sha256")
echo "Disk image: $DMG_PATH"
