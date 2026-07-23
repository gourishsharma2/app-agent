#!/usr/bin/env bash
#
# appium_action.sh — thin wrapper around the Appium HTTP API + adb for driving
# an already-installed app through a flow (tap, type, read the screen, open/close
# a session). Used after launchApplication has the environment ready.
#
# This exists as ONE fixed, narrow entry point (instead of hand-rolled curl/adb
# one-liners each time) so it can be allowlisted once in .claude/settings.json
# and stop prompting for permission on every run. The active session id is
# tracked internally (state file, not stdout capture) so every call is a plain
# `appium_action.sh <cmd> [args]` invocation with no `$(...)` wrapping — that
# wrapping is what breaks the allowlist match, since the permission check
# matches the literal leading command text, and `SID=$(...)` doesn't start
# with the script path.
#
# Usage:
#   appium_action.sh open-session <appPackage> <appActivity>
#   appium_action.sh tap <x> <y>
#   appium_action.sh type <text>       # via adb
#   appium_action.sh source            # prints page source XML to stdout
#   appium_action.sh contains <substring>   # exit 0 if substring is in the current source, else 1
#   appium_action.sh close-session

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
CONFIG_FILE="$PROJECT_ROOT/config.properties"
STATE_FILE="$SCRIPT_DIR/../.session_state"

APPIUM_URL="${APPIUM_URL:-}"
if [[ -z "$APPIUM_URL" ]]; then
  APPIUM_URL="http://localhost:4723"
  if [[ -f "$CONFIG_FILE" ]]; then
    cfg_url=$(grep -E '^[[:space:]]*appiumServerUrl[[:space:]]*=' "$CONFIG_FILE" | tail -1 | cut -d'=' -f2- | xargs)
    [[ -n "${cfg_url:-}" ]] && APPIUM_URL="$cfg_url"
  fi
fi

running_emulator() {
  adb devices 2>/dev/null | awk '$2=="device" && $1 ~ /^emulator-/ {print $1; exit}'
}

fail() { echo "❌ $1" >&2; exit 1; }

resolve_session_id() {
  [[ -f "$STATE_FILE" ]] || fail "No active session. Run 'appium_action.sh open-session <appPackage> <appActivity>' first."
  cat "$STATE_FILE"
}

CMD="${1:-}"
[[ -n "$CMD" ]] || fail "Usage: appium_action.sh <open-session|tap|type|source|contains|close-session> [args]"
shift || true

case "$CMD" in
  open-session)
    APP_PACKAGE="${1:-}"; APP_ACTIVITY="${2:-}"
    [[ -n "$APP_PACKAGE" && -n "$APP_ACTIVITY" ]] || fail "Usage: appium_action.sh open-session <appPackage> <appActivity>"
    DEVICE_SERIAL="$(running_emulator)"
    [[ -n "$DEVICE_SERIAL" ]] || fail "No running emulator detected (adb devices). Run launchApplication first."
    RESPONSE=$(curl -s -X POST "$APPIUM_URL/session" -H "Content-Type: application/json" -d "{
      \"capabilities\": {
        \"alwaysMatch\": {
          \"platformName\": \"Android\",
          \"appium:automationName\": \"UiAutomator2\",
          \"appium:deviceName\": \"$DEVICE_SERIAL\",
          \"appium:udid\": \"$DEVICE_SERIAL\",
          \"appium:appPackage\": \"$APP_PACKAGE\",
          \"appium:appActivity\": \"$APP_ACTIVITY\",
          \"appium:noReset\": true,
          \"appium:autoGrantPermissions\": true,
          \"appium:newCommandTimeout\": 300
        }
      }
    }")
    SESSION_ID=$(echo "$RESPONSE" | grep -o '"sessionId"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*:"([^"]*)"/\1/')
    [[ -n "$SESSION_ID" ]] || fail "Could not open Appium session. Raw response: $RESPONSE"
    echo "$SESSION_ID" > "$STATE_FILE"
    echo "Session opened: $SESSION_ID"
    ;;

  tap)
    X="${1:-}"; Y="${2:-}"
    [[ -n "$X" && -n "$Y" ]] || fail "Usage: appium_action.sh tap <x> <y>"
    SESSION_ID="$(resolve_session_id)"
    curl -s -X POST "$APPIUM_URL/session/$SESSION_ID/actions" -H "Content-Type: application/json" -d "{
      \"actions\": [
        {\"type\":\"pointer\",\"id\":\"finger1\",\"parameters\":{\"pointerType\":\"touch\"},
         \"actions\":[
           {\"type\":\"pointerMove\",\"duration\":0,\"x\":$X,\"y\":$Y},
           {\"type\":\"pointerDown\",\"button\":0},
           {\"type\":\"pause\",\"duration\":100},
           {\"type\":\"pointerUp\",\"button\":0}
         ]}
      ]
    }" > /dev/null
    ;;

  type)
    TEXT="${1:-}"
    [[ -n "$TEXT" ]] || fail "Usage: appium_action.sh type <text>"
    DEVICE_SERIAL="$(running_emulator)"
    [[ -n "$DEVICE_SERIAL" ]] || fail "No running emulator detected (adb devices)."
    adb -s "$DEVICE_SERIAL" shell input text "$TEXT"
    ;;

  source)
    SESSION_ID="$(resolve_session_id)"
    curl -s "$APPIUM_URL/session/$SESSION_ID/source" | python3 -c "import json,sys; print(json.load(sys.stdin)['value'])"
    ;;

  contains)
    SUBSTR="${1:-}"
    [[ -n "$SUBSTR" ]] || fail "Usage: appium_action.sh contains <substring>"
    SESSION_ID="$(resolve_session_id)"
    PAGE=$(curl -s "$APPIUM_URL/session/$SESSION_ID/source" | python3 -c "import json,sys; print(json.load(sys.stdin)['value'])")
    if echo "$PAGE" | grep -qF "$SUBSTR"; then
      echo "FOUND: $SUBSTR"
      exit 0
    else
      echo "NOT FOUND: $SUBSTR"
      exit 1
    fi
    ;;

  close-session)
    SESSION_ID="$(resolve_session_id)"
    curl -s -X DELETE "$APPIUM_URL/session/$SESSION_ID" > /dev/null
    rm -f "$STATE_FILE"
    ;;

  *)
    fail "Unknown command: $CMD"
    ;;
esac
