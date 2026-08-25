#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/edn-cli-contract.XXXXXX")"
export EDN_CONFIG_PATH="$TEST_DIR/config.json"
export EDN_STATE_PATH="$TEST_DIR/state.json"

swift build --package-path "$ROOT_DIR" --product edn >/dev/null
CLI="$(swift build --package-path "$ROOT_DIR" --show-bin-path)/edn"

STATUS="$($CLI status --json)"
echo "$STATUS" | jq -e '.accessibilityTrusted | type == "boolean"' >/dev/null
TRUSTED="$(echo "$STATUS" | jq -r '.accessibilityTrusted')"
$CLI init --json | jq -e '.created == true' >/dev/null
$CLI create alpha --hotkey 1 --json | jq -e '.name == "alpha" and .hotkey == "1"' >/dev/null
$CLI list --json | jq -e '.workspaces[0].name == "alpha" and .workspaces[0].isActive == false' >/dev/null
$CLI inspect alpha --json | jq -e '.name == "alpha" and .apps == []' >/dev/null

if [[ "$TRUSTED" == "true" ]]; then
    $CLI switch alpha --json | jq -e '.workspace == "alpha" and .apps == []' >/dev/null
    $CLI windows --json | jq -e '.displays | type == "array"' >/dev/null
else
    set +e
    $CLI switch alpha --json >"$TEST_DIR/switch.stdout" 2>"$TEST_DIR/switch.error"
    SWITCH_STATUS=$?
    set -e
    test "$SWITCH_STATUS" -eq 1
    jq -e '.error.code == "accessibility_not_trusted"' "$TEST_DIR/switch.error" >/dev/null
fi

$CLI save alpha --json | jq -e '.workspace == "alpha" and .fullyCaptured == true' >/dev/null
$CLI reset alpha --yes --json | jq -e '.action == "reset" and .workspace == "alpha"' >/dev/null

set +e
$CLI delete alpha --json >"$TEST_DIR/error.stdout" 2>"$TEST_DIR/error.json"
ERROR_STATUS=$?
set -e
test "$ERROR_STATUS" -eq 1
test ! -s "$TEST_DIR/error.stdout"
jq -e '.error.code == "confirmation_required" and .error.command == "delete"' "$TEST_DIR/error.json" >/dev/null
$CLI delete alpha --yes --json | jq -e '.action == "delete" and .workspace == "alpha"' >/dev/null

if [[ "$TRUSTED" == "true" ]]; then
    $CLI daemon --json >"$TEST_DIR/daemon.jsonl" 2>"$TEST_DIR/daemon.stderr" &
    DAEMON_PID=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        [[ -s "$TEST_DIR/daemon.jsonl" ]] && break
        sleep 0.1
    done
    kill -TERM "$DAEMON_PID" 2>/dev/null || true
    wait "$DAEMON_PID" 2>/dev/null || true
    head -1 "$TEST_DIR/daemon.jsonl" | jq -e '.event == "ready" and (.hotkeys | type == "array")' >/dev/null
fi

echo "CLI JSON contract passed. Isolated artifacts: $TEST_DIR"
