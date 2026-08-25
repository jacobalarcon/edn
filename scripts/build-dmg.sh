#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_PATH="$ROOT_DIR/dist/EDN.app"
VERSION="${EDN_DMG_VERSION:-${EDN_VERSION:-0.1.0}}"
DMG_PATH="$ROOT_DIR/dist/EDN-$VERSION.dmg"
IDENTITY="${EDN_CODE_SIGN_IDENTITY:--}"

if [[ ! -d "$APP_PATH" ]]; then
    echo "EDN.app is missing; run scripts/build-app.sh first." >&2
    exit 1
fi

STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGING_DIR"' EXIT
ditto "$APP_PATH" "$STAGING_DIR/EDN.app"
ln -s /Applications "$STAGING_DIR/Applications"

case "$DMG_PATH" in
    "$ROOT_DIR/dist/EDN-"*.dmg) rm -f "$DMG_PATH" "$DMG_PATH.sha256" ;;
    *) echo "Refusing unsafe disk-image output path: $DMG_PATH" >&2; exit 1 ;;
esac

hdiutil create \
    -volname "EDN" \
    -srcfolder "$STAGING_DIR" \
    -format UDZO \
    -ov \
    "$DMG_PATH" >/dev/null

if [[ "$IDENTITY" != "-" ]]; then
    codesign --force --timestamp --sign "$IDENTITY" "$DMG_PATH"
    codesign --verify --strict --verbose=2 "$DMG_PATH"
fi

(cd "$ROOT_DIR/dist" && shasum -a 256 "$(basename "$DMG_PATH")" > "$(basename "$DMG_PATH").sha256")
echo "Disk image: $DMG_PATH"
