#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE="$ROOT_DIR/dist/EDN.app"
DESTINATION="/Applications/EDN.app"

if [[ ! -d "$SOURCE" ]]; then
    "$SCRIPT_DIR/build-app.sh"
fi

if [[ -e "$DESTINATION" ]]; then
    echo "$DESTINATION already exists. Quit EDN and move it to Trash before reinstalling." >&2
    exit 1
fi

ditto "$SOURCE" "$DESTINATION"
open "$DESTINATION"
echo "Installed and opened $DESTINATION"
echo "The CLI is inside the app at $DESTINATION/Contents/Helpers/edn"
