#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION="${EDN_VERSION:-0.1.0}"
ARCHIVE_VERSION="${EDN_ARCHIVE_VERSION:-$VERSION}"
BUILD_NUMBER="${EDN_BUILD_NUMBER:-1}"
if [[ -n "${EDN_CODE_SIGN_IDENTITY:-}" ]]; then
    IDENTITY="$EDN_CODE_SIGN_IDENTITY"
elif security find-identity -v -p codesigning 2>/dev/null | grep -Fq '"EDN Local Development"'; then
    IDENTITY="EDN Local Development"
else
    IDENTITY="-"
fi
APP_DIR="$ROOT_DIR/dist/EDN.app"

build_arch() {
    local architecture="$1"
    local scratch="$ROOT_DIR/.build/package-$architecture"
    local triple="$architecture-apple-macosx13.0"
    swift build --package-path "$ROOT_DIR" -c release --triple "$triple" --scratch-path "$scratch" --product edn-menubar >&2
    swift build --package-path "$ROOT_DIR" -c release --triple "$triple" --scratch-path "$scratch" --product edn >&2
    swift build --package-path "$ROOT_DIR" -c release --triple "$triple" --scratch-path "$scratch" --show-bin-path
}

mkdir -p "$ROOT_DIR/dist"
case "$APP_DIR" in
    "$ROOT_DIR/dist/EDN.app") rm -rf "$APP_DIR" ;;
    *) echo "Refusing unsafe app output path: $APP_DIR" >&2; exit 1 ;;
esac
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Helpers" "$APP_DIR/Contents/Resources"

if [[ "${EDN_UNIVERSAL:-0}" == "1" ]]; then
    ARM_BIN="$(build_arch arm64)"
    INTEL_BIN="$(build_arch x86_64)"
    lipo -create "$ARM_BIN/edn-menubar" "$INTEL_BIN/edn-menubar" -output "$APP_DIR/Contents/MacOS/EDN"
    lipo -create "$ARM_BIN/edn" "$INTEL_BIN/edn" -output "$APP_DIR/Contents/Helpers/edn"
else
    swift build --package-path "$ROOT_DIR" -c release --product edn-menubar
    swift build --package-path "$ROOT_DIR" -c release --product edn
    BIN_DIR="$(swift build --package-path "$ROOT_DIR" -c release --show-bin-path)"
    cp "$BIN_DIR/edn-menubar" "$APP_DIR/Contents/MacOS/EDN"
    cp "$BIN_DIR/edn" "$APP_DIR/Contents/Helpers/edn"
fi

cp "$ROOT_DIR/Packaging/Info.plist" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP_DIR/Contents/Info.plist"

ICON_TMP="$(mktemp -d)"
trap 'rm -rf "$ICON_TMP"' EXIT
swift "$ROOT_DIR/Packaging/render-icon.swift" "$ICON_TMP/icon-1024.png"
ICONSET="$ICON_TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
for specification in "16:icon_16x16.png" "32:icon_16x16@2x.png" "32:icon_32x32.png" "64:icon_32x32@2x.png" "128:icon_128x128.png" "256:icon_128x128@2x.png" "256:icon_256x256.png" "512:icon_256x256@2x.png" "512:icon_512x512.png" "1024:icon_512x512@2x.png"; do
    pixels="${specification%%:*}"
    filename="${specification#*:}"
    sips -z "$pixels" "$pixels" "$ICON_TMP/icon-1024.png" --out "$ICONSET/$filename" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/AppIcon.icns"

chmod 755 "$APP_DIR/Contents/MacOS/EDN" "$APP_DIR/Contents/Helpers/edn"
SIGN_ARGS=(--force --sign "$IDENTITY")
if [[ "$IDENTITY" != "-" ]]; then
    SIGN_ARGS+=(--options runtime --timestamp)
fi
codesign "${SIGN_ARGS[@]}" --identifier com.jacobalarcon.edn.cli "$APP_DIR/Contents/Helpers/edn"
codesign "${SIGN_ARGS[@]}" --identifier com.jacobalarcon.edn "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

ARCHIVE="$ROOT_DIR/dist/EDN-$ARCHIVE_VERSION.zip"
rm -f "$ARCHIVE" "$ARCHIVE.sha256"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ARCHIVE"
(cd "$ROOT_DIR/dist" && shasum -a 256 "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256")
echo "Built $APP_DIR"
echo "Archive: $ARCHIVE"
