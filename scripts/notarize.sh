#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: scripts/notarize.sh /path/to/EDN.app" >&2
    exit 64
fi

TARGET_PATH="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
: "${APPLE_ID:?APPLE_ID is required}"
: "${APPLE_APP_SPECIFIC_PASSWORD:?APPLE_APP_SPECIFIC_PASSWORD is required}"
: "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required}"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
case "$TARGET_PATH" in
    *.app)
        SUBMISSION="$WORK_DIR/EDN.zip"
        ditto -c -k --sequesterRsrc --keepParent "$TARGET_PATH" "$SUBMISSION"
        ;;
    *.dmg)
        SUBMISSION="$TARGET_PATH"
        ;;
    *)
        echo "notarize target must be an .app or .dmg" >&2
        exit 64
        ;;
esac
xcrun notarytool submit "$SUBMISSION" \
    --apple-id "$APPLE_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD" \
    --team-id "$APPLE_TEAM_ID" \
    --wait
xcrun stapler staple "$TARGET_PATH"
xcrun stapler validate "$TARGET_PATH"
