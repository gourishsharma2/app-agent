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
#   appium_action.sh long-press <x> <y> [durationMs]        # default 800ms
#   appium_action.sh double-tap <x> <y>
#   appium_action.sh type <text>       # via adb
#   appium_action.sh back              # Android hardware back button
#   appium_action.sh hide-keyboard     # dismiss the soft keyboard, if shown
#   appium_action.sh swipe <x1> <y1> <x2> <y2> [durationMs]  # raw custom swipe, default 300ms
#   appium_action.sh scroll <up|down|left|right>             # full-screen directional swipe
#   appium_action.sh scroll-to <substring> [maxScrolls]      # scroll down + check, repeatedly, until found (default 10)
#   appium_action.sh source            # prints page source XML to stdout
#   appium_action.sh contains <substring>   # exit 0 if substring is in the current source, else 1
#   appium_action.sh find <substring>       # prints each matching element's bounds="[x1,y1][x2,y2]" — use this
#                                            # instead of piping `source` through a raw grep call
#   appium_action.sh wait-for <substring> [timeoutSeconds]        # poll until substring appears (default 30s)
#   appium_action.sh wait-until-gone <substring> [timeoutSeconds] # poll until substring disappears (default 30s) — for loading states
#   appium_action.sh screenshot [name]      # saves a PNG under ../screenshots/, prints the saved path
#   appium_action.sh close-session

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
CONFIG_FILE="$PROJECT_ROOT/config.properties"
STATE_FILE="$SCRIPT_DIR/../.session_state"
SCREENSHOT_DIR="$SCRIPT_DIR/../screenshots"

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

get_page_source() {
  local session_id="$1"
  curl -s "$APPIUM_URL/session/$session_id/source" | python3 -c "import json,sys; print(json.load(sys.stdin)['value'])"
}

get_window_size() {
  local session_id="$1"
  curl -s "$APPIUM_URL/session/$session_id/window/rect" | python3 -c "import json,sys; v=json.load(sys.stdin)['value']; print(v['width'], v['height'])"
}

do_swipe() {
  local session_id="$1" x1="$2" y1="$3" x2="$4" y2="$5" duration="${6:-300}"
  curl -s -X POST "$APPIUM_URL/session/$session_id/actions" -H "Content-Type: application/json" -d "{
    \"actions\": [
      {\"type\":\"pointer\",\"id\":\"finger1\",\"parameters\":{\"pointerType\":\"touch\"},
       \"actions\":[
         {\"type\":\"pointerMove\",\"duration\":0,\"x\":$x1,\"y\":$y1},
         {\"type\":\"pointerDown\",\"button\":0},
         {\"type\":\"pointerMove\",\"duration\":$duration,\"x\":$x2,\"y\":$y2},
         {\"type\":\"pointerUp\",\"button\":0}
       ]}
    ]
  }" > /dev/null
}

CMD="${1:-}"
[[ -n "$CMD" ]] || fail "Usage: appium_action.sh <open-session|tap|long-press|double-tap|type|back|hide-keyboard|swipe|scroll|scroll-to|source|contains|find|wait-for|wait-until-gone|screenshot|close-session> [args]"
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

  long-press)
    X="${1:-}"; Y="${2:-}"; DURATION="${3:-800}"
    [[ -n "$X" && -n "$Y" ]] || fail "Usage: appium_action.sh long-press <x> <y> [durationMs]"
    SESSION_ID="$(resolve_session_id)"
    curl -s -X POST "$APPIUM_URL/session/$SESSION_ID/actions" -H "Content-Type: application/json" -d "{
      \"actions\": [
        {\"type\":\"pointer\",\"id\":\"finger1\",\"parameters\":{\"pointerType\":\"touch\"},
         \"actions\":[
           {\"type\":\"pointerMove\",\"duration\":0,\"x\":$X,\"y\":$Y},
           {\"type\":\"pointerDown\",\"button\":0},
           {\"type\":\"pause\",\"duration\":$DURATION},
           {\"type\":\"pointerUp\",\"button\":0}
         ]}
      ]
    }" > /dev/null
    ;;

  double-tap)
    X="${1:-}"; Y="${2:-}"
    [[ -n "$X" && -n "$Y" ]] || fail "Usage: appium_action.sh double-tap <x> <y>"
    SESSION_ID="$(resolve_session_id)"
    curl -s -X POST "$APPIUM_URL/session/$SESSION_ID/actions" -H "Content-Type: application/json" -d "{
      \"actions\": [
        {\"type\":\"pointer\",\"id\":\"finger1\",\"parameters\":{\"pointerType\":\"touch\"},
         \"actions\":[
           {\"type\":\"pointerMove\",\"duration\":0,\"x\":$X,\"y\":$Y},
           {\"type\":\"pointerDown\",\"button\":0},
           {\"type\":\"pause\",\"duration\":80},
           {\"type\":\"pointerUp\",\"button\":0},
           {\"type\":\"pause\",\"duration\":80},
           {\"type\":\"pointerMove\",\"duration\":0,\"x\":$X,\"y\":$Y},
           {\"type\":\"pointerDown\",\"button\":0},
           {\"type\":\"pause\",\"duration\":80},
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

  back)
    DEVICE_SERIAL="$(running_emulator)"
    [[ -n "$DEVICE_SERIAL" ]] || fail "No running emulator detected (adb devices)."
    adb -s "$DEVICE_SERIAL" shell input keyevent 4
    ;;

  hide-keyboard)
    SESSION_ID="$(resolve_session_id)"
    curl -s -X POST "$APPIUM_URL/session/$SESSION_ID/appium/device/hide_keyboard" -H "Content-Type: application/json" -d '{}' > /dev/null
    ;;

  swipe)
    X1="${1:-}"; Y1="${2:-}"; X2="${3:-}"; Y2="${4:-}"; DURATION="${5:-300}"
    [[ -n "$X1" && -n "$Y1" && -n "$X2" && -n "$Y2" ]] || fail "Usage: appium_action.sh swipe <x1> <y1> <x2> <y2> [durationMs]"
    SESSION_ID="$(resolve_session_id)"
    do_swipe "$SESSION_ID" "$X1" "$Y1" "$X2" "$Y2" "$DURATION"
    ;;

  scroll)
    DIRECTION="${1:-down}"
    SESSION_ID="$(resolve_session_id)"
    read -r WIDTH HEIGHT <<< "$(get_window_size "$SESSION_ID")"
    [[ -n "${WIDTH:-}" && -n "${HEIGHT:-}" ]] || fail "Could not determine window size."
    CENTER_X=$((WIDTH / 2)); CENTER_Y=$((HEIGHT / 2))
    case "$DIRECTION" in
      down)  do_swipe "$SESSION_ID" "$CENTER_X" $((HEIGHT * 80 / 100)) "$CENTER_X" $((HEIGHT * 20 / 100)) ;;
      up)    do_swipe "$SESSION_ID" "$CENTER_X" $((HEIGHT * 20 / 100)) "$CENTER_X" $((HEIGHT * 80 / 100)) ;;
      left)  do_swipe "$SESSION_ID" $((WIDTH * 80 / 100)) "$CENTER_Y" $((WIDTH * 20 / 100)) "$CENTER_Y" ;;
      right) do_swipe "$SESSION_ID" $((WIDTH * 20 / 100)) "$CENTER_Y" $((WIDTH * 80 / 100)) "$CENTER_Y" ;;
      *) fail "Usage: appium_action.sh scroll <up|down|left|right>" ;;
    esac
    ;;

  scroll-to)
    SUBSTR="${1:-}"; MAX_SCROLLS="${2:-10}"
    [[ -n "$SUBSTR" ]] || fail "Usage: appium_action.sh scroll-to <substring> [maxScrolls]"
    SESSION_ID="$(resolve_session_id)"
    read -r WIDTH HEIGHT <<< "$(get_window_size "$SESSION_ID")"
    [[ -n "${WIDTH:-}" && -n "${HEIGHT:-}" ]] || fail "Could not determine window size."
    CENTER_X=$((WIDTH / 2))
    for ((i = 0; i < MAX_SCROLLS; i++)); do
      PAGE="$(get_page_source "$SESSION_ID")"
      if echo "$PAGE" | grep -qF "$SUBSTR"; then
        echo "FOUND: $SUBSTR (after $i scroll(s))"
        exit 0
      fi
      do_swipe "$SESSION_ID" "$CENTER_X" $((HEIGHT * 80 / 100)) "$CENTER_X" $((HEIGHT * 20 / 100))
      sleep 1
    done
    PAGE="$(get_page_source "$SESSION_ID")"
    if echo "$PAGE" | grep -qF "$SUBSTR"; then
      echo "FOUND: $SUBSTR (after $MAX_SCROLLS scroll(s))"
      exit 0
    fi
    echo "NOT FOUND: $SUBSTR (gave up after $MAX_SCROLLS scrolls)"
    exit 1
    ;;

  source)
    SESSION_ID="$(resolve_session_id)"
    get_page_source "$SESSION_ID"
    ;;

  contains)
    SUBSTR="${1:-}"
    [[ -n "$SUBSTR" ]] || fail "Usage: appium_action.sh contains <substring>"
    SESSION_ID="$(resolve_session_id)"
    PAGE="$(get_page_source "$SESSION_ID")"
    if echo "$PAGE" | grep -qF "$SUBSTR"; then
      echo "FOUND: $SUBSTR"
      exit 0
    else
      echo "NOT FOUND: $SUBSTR"
      exit 1
    fi
    ;;

  find)
    SUBSTR="${1:-}"
    [[ -n "$SUBSTR" ]] || fail "Usage: appium_action.sh find <substring>"
    SESSION_ID="$(resolve_session_id)"
    PAGE="$(get_page_source "$SESSION_ID")"
    MATCHES=$(echo "$PAGE" | grep -F "$SUBSTR" | grep -o 'bounds="\[[0-9,-]*\]\[[0-9,-]*\]"')
    [[ -n "$MATCHES" ]] || fail "No element containing '$SUBSTR' found in current source."
    echo "$MATCHES"
    ;;

  wait-for)
    SUBSTR="${1:-}"; TIMEOUT="${2:-30}"
    [[ -n "$SUBSTR" ]] || fail "Usage: appium_action.sh wait-for <substring> [timeoutSeconds]"
    SESSION_ID="$(resolve_session_id)"
    ELAPSED=0
    while (( ELAPSED < TIMEOUT )); do
      PAGE="$(get_page_source "$SESSION_ID")"
      if echo "$PAGE" | grep -qF "$SUBSTR"; then
        echo "FOUND: $SUBSTR (after ${ELAPSED}s)"
        exit 0
      fi
      sleep 2
      ELAPSED=$((ELAPSED + 2))
    done
    echo "NOT FOUND: $SUBSTR (timed out after ${TIMEOUT}s)"
    exit 1
    ;;

  wait-until-gone)
    SUBSTR="${1:-}"; TIMEOUT="${2:-30}"
    [[ -n "$SUBSTR" ]] || fail "Usage: appium_action.sh wait-until-gone <substring> [timeoutSeconds]"
    SESSION_ID="$(resolve_session_id)"
    ELAPSED=0
    while (( ELAPSED < TIMEOUT )); do
      PAGE="$(get_page_source "$SESSION_ID")"
      if ! echo "$PAGE" | grep -qF "$SUBSTR"; then
        echo "GONE: $SUBSTR (after ${ELAPSED}s)"
        exit 0
      fi
      sleep 2
      ELAPSED=$((ELAPSED + 2))
    done
    echo "STILL PRESENT: $SUBSTR (timed out after ${TIMEOUT}s)"
    exit 1
    ;;

  screenshot)
    NAME="${1:-capture}"
    DEVICE_SERIAL="$(running_emulator)"
    [[ -n "$DEVICE_SERIAL" ]] || fail "No running emulator detected (adb devices)."
    mkdir -p "$SCREENSHOT_DIR"
    OUT_PATH="$SCREENSHOT_DIR/${NAME}.png"
    adb -s "$DEVICE_SERIAL" exec-out screencap -p > "$OUT_PATH"
    echo "$OUT_PATH"
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
