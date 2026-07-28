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
#   appium_action.sh tap-on <substring>   # tap the centre of the element containing <substring>
#                                          # — prefer this over hardcoded x/y from a screenshot
#   appium_action.sh long-press <x> <y> [durationMs]        # default 800ms
#   appium_action.sh double-tap <x> <y>
#   appium_action.sh type <text>       # via adb
#   appium_action.sh back              # Android hardware back button
#   appium_action.sh hide-keyboard     # dismiss the soft keyboard, if shown
#   appium_action.sh swipe <x1> <y1> <x2> <y2> [durationMs]  # raw custom swipe, default 450ms
#   appium_action.sh scroll <up|down|left|right>             # full-screen directional swipe
#   appium_action.sh scroll-to <substring> [up|down|left|right] [maxScrolls]  # scroll (default down) + check,
#                                                             # repeatedly, until found (default 10), logging every
#                                                             # attempt and stopping the instant the substring appears
#   appium_action.sh source            # prints page source XML to stdout
#   appium_action.sh contains <substring>   # exit 0 if substring is in the current source, else 1
#   appium_action.sh assert-all <substring1> [substring2] ...  # like contains, but checks every substring
#                                            # against ONE page-source fetch — use for a whole step's assertion
#                                            # list at once instead of one contains call per substring
#   appium_action.sh find <substring>       # prints each matching element's bounds="[x1,y1][x2,y2]" — use this
#                                            # instead of piping `source` through a raw grep call
#   appium_action.sh wait-for <substring> [timeoutSeconds]        # poll until substring appears (default 30s)
#   appium_action.sh wait-until-gone <substring> [timeoutSeconds] # poll until substring disappears (default 30s) — for loading states
#   appium_action.sh screenshot [name]      # saves a PNG under ../screenshots/, prints the saved path
#   appium_action.sh close-session
#
# All swipe/scroll/scroll-to gestures are driven via `adb shell input swipe`
# rather than Appium's W3C pointer actions. A raw 2-point W3C pointerMove (as
# this script used before) gives UiAutomator2 only a start and end coordinate
# to interpolate, which Android/Compose scrollables frequently misread as an
# uncontrolled fling — the actual scroll distance varies run to run, so a
# fixed-count retry loop can silently skip past the target element. `adb
# shell input swipe` synthesizes a real interpolated motion-event sequence
# over the given duration, which Compose's scroll/fling gesture detector
# recognizes consistently. Since `type`/`back`/`screenshot` already go
# through adb in this script, this keeps one gesture mechanism instead of two.

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

# The page source is XML, so any assertion text containing & < > or " arrives
# escaped: the Settings screen's "Network & internet" is `Network &amp;
# internet` in the dump, and this repo's own `contains "View & pay"`
# assertion in flow/homePage.md could never match. Check the literal needle
# first, then its XML-escaped form, so docs can keep writing text the way it
# actually appears on screen.
xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

page_contains() {
  local page="$1" needle="$2" escaped
  echo "$page" | grep -qF "$needle" && return 0
  escaped="$(xml_escape "$needle")"
  [[ "$escaped" != "$needle" ]] && echo "$page" | grep -qF "$escaped" && return 0
  return 1
}

do_tap() {
  local session_id="$1" x="$2" y="$3"
  curl -s -X POST "$APPIUM_URL/session/$session_id/actions" -H "Content-Type: application/json" -d "{
    \"actions\": [
      {\"type\":\"pointer\",\"id\":\"finger1\",\"parameters\":{\"pointerType\":\"touch\"},
       \"actions\":[
         {\"type\":\"pointerMove\",\"duration\":0,\"x\":$x,\"y\":$y},
         {\"type\":\"pointerDown\",\"button\":0},
         {\"type\":\"pause\",\"duration\":100},
         {\"type\":\"pointerUp\",\"button\":0}
       ]}
    ]
  }" > /dev/null
}

get_window_size() {
  local session_id="$1"
  curl -s "$APPIUM_URL/session/$session_id/window/rect" | python3 -c "import json,sys; v=json.load(sys.stdin)['value']; print(v['width'], v['height'])"
}

do_swipe() {
  local x1="$2" y1="$3" x2="$4" y2="$5" duration="${6:-450}"
  local device_serial
  device_serial="$(running_emulator)"
  [[ -n "$device_serial" ]] || fail "No running emulator detected (adb devices)."
  adb -s "$device_serial" shell input swipe "$x1" "$y1" "$x2" "$y2" "$duration"
}

CMD="${1:-}"
[[ -n "$CMD" ]] || fail "Usage: appium_action.sh <open-session|tap|tap-on|long-press|double-tap|type|back|hide-keyboard|wake-screen|swipe|scroll|scroll-to|source|contains|assert-all|find|wait-for|wait-until-gone|screenshot|close-session> [args]"
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
          \"appium:newCommandTimeout\": 3600
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
    do_tap "$SESSION_ID" "$X" "$Y"
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

  wake-screen)
    DEVICE_SERIAL="$(running_emulator)"
    [[ -n "$DEVICE_SERIAL" ]] || fail "No running emulator detected (adb devices)."
    AWAKE=$(adb -s "$DEVICE_SERIAL" shell dumpsys power | grep -o 'mWakefulness=[A-Za-z]*' | head -1)
    if [[ "$AWAKE" != "mWakefulness=Awake" ]]; then
      adb -s "$DEVICE_SERIAL" shell input keyevent 224  # KEYCODE_WAKEUP
      adb -s "$DEVICE_SERIAL" shell input keyevent 82   # KEYCODE_MENU, dismisses a simple (non-PIN) lock screen
    fi
    ;;

  hide-keyboard)
    SESSION_ID="$(resolve_session_id)"
    curl -s -X POST "$APPIUM_URL/session/$SESSION_ID/appium/device/hide_keyboard" -H "Content-Type: application/json" -d '{}' > /dev/null
    ;;

  swipe)
    X1="${1:-}"; Y1="${2:-}"; X2="${3:-}"; Y2="${4:-}"; DURATION="${5:-450}"
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
      down)  do_swipe "$SESSION_ID" "$CENTER_X" $((HEIGHT * 82 / 100)) "$CENTER_X" $((HEIGHT * 22 / 100)) ;;
      up)    do_swipe "$SESSION_ID" "$CENTER_X" $((HEIGHT * 22 / 100)) "$CENTER_X" $((HEIGHT * 82 / 100)) ;;
      left)  do_swipe "$SESSION_ID" $((WIDTH * 82 / 100)) "$CENTER_Y" $((WIDTH * 18 / 100)) "$CENTER_Y" ;;
      right) do_swipe "$SESSION_ID" $((WIDTH * 18 / 100)) "$CENTER_Y" $((WIDTH * 82 / 100)) "$CENTER_Y" ;;
      *) fail "Usage: appium_action.sh scroll <up|down|left|right>" ;;
    esac
    ;;

  scroll-to)
    # scroll-to <substring> [up|down|left|right] [maxScrolls]
    # Direction is optional (defaults to down) and detected positionally so
    # existing 2-arg callers (`scroll-to "text" 15`) keep working unchanged.
    SUBSTR="${1:-}"
    [[ -n "$SUBSTR" ]] || fail "Usage: appium_action.sh scroll-to <substring> [up|down|left|right] [maxScrolls]"
    if [[ "${2:-}" =~ ^(up|down|left|right)$ ]]; then
      DIRECTION="$2"; MAX_SCROLLS="${3:-10}"
    else
      DIRECTION="down"; MAX_SCROLLS="${2:-10}"
    fi
    SESSION_ID="$(resolve_session_id)"
    read -r WIDTH HEIGHT <<< "$(get_window_size "$SESSION_ID")"
    [[ -n "${WIDTH:-}" && -n "${HEIGHT:-}" ]] || fail "Could not determine window size."
    CENTER_X=$((WIDTH / 2)); CENTER_Y=$((HEIGHT / 2))

    swipe_once() {
      case "$DIRECTION" in
        down)  do_swipe "$SESSION_ID" "$CENTER_X" $((HEIGHT * 82 / 100)) "$CENTER_X" $((HEIGHT * 22 / 100)) ;;
        up)    do_swipe "$SESSION_ID" "$CENTER_X" $((HEIGHT * 22 / 100)) "$CENTER_X" $((HEIGHT * 82 / 100)) ;;
        left)  do_swipe "$SESSION_ID" $((WIDTH * 82 / 100)) "$CENTER_Y" $((WIDTH * 18 / 100)) "$CENTER_Y" ;;
        right) do_swipe "$SESSION_ID" $((WIDTH * 18 / 100)) "$CENTER_Y" $((WIDTH * 82 / 100)) "$CENTER_Y" ;;
      esac
    }

    PAGE="$(get_page_source "$SESSION_ID")"
    if page_contains "$PAGE" "$SUBSTR"; then
      echo "FOUND: $SUBSTR (already visible, no scroll needed)"
      exit 0
    fi

    STUCK_COUNT=0
    for ((i = 1; i <= MAX_SCROLLS; i++)); do
      swipe_once
      sleep 1
      NEW_PAGE="$(get_page_source "$SESSION_ID")"
      if page_contains "$NEW_PAGE" "$SUBSTR"; then
        echo "FOUND: $SUBSTR (after $i scroll(s) $DIRECTION)"
        exit 0
      fi
      if [[ "$NEW_PAGE" == "$PAGE" ]]; then
        STUCK_COUNT=$((STUCK_COUNT + 1))
        echo "scroll-to: attempt $i/$MAX_SCROLLS ($DIRECTION) — screen unchanged after swipe (stuck $STUCK_COUNT/2), '$SUBSTR' not yet visible" >&2
        if (( STUCK_COUNT >= 2 )); then
          echo "NOT FOUND: $SUBSTR (list stopped responding to scroll after $i attempt(s) — likely reached the end)"
          exit 1
        fi
      else
        STUCK_COUNT=0
        echo "scroll-to: attempt $i/$MAX_SCROLLS ($DIRECTION) — list moved, '$SUBSTR' not yet visible" >&2
      fi
      PAGE="$NEW_PAGE"
    done
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
    if page_contains "$PAGE" "$SUBSTR"; then
      echo "FOUND: $SUBSTR"
      exit 0
    else
      echo "NOT FOUND: $SUBSTR"
      exit 1
    fi
    ;;

  assert-all)
    # Checks every given substring against ONE page-source fetch instead of
    # one fetch per substring — use this for a step's whole assertion list
    # once the screen has settled (wait-for/wait-until-gone first if the
    # screen has a loading state). Still reports each substring individually;
    # only the number of page-source round trips changes, not the coverage.
    [[ $# -ge 1 ]] || fail "Usage: appium_action.sh assert-all <substring1> [substring2] ..."
    SESSION_ID="$(resolve_session_id)"
    PAGE="$(get_page_source "$SESSION_ID")"
    FAIL_COUNT=0
    for SUBSTR in "$@"; do
      if page_contains "$PAGE" "$SUBSTR"; then
        echo "FOUND: $SUBSTR"
      else
        echo "NOT FOUND: $SUBSTR"
        FAIL_COUNT=$((FAIL_COUNT + 1))
      fi
    done
    [[ $FAIL_COUNT -eq 0 ]] || exit 1
    ;;

  tap-on)
    # Tap the centre of the first element whose text/content-desc contains
    # <substring>, instead of hardcoding x/y read off a screenshot. Screenshot
    # coordinates are tied to one screen resolution and one layout revision;
    # this resolves the element's real bounds at run time, so a flow doc
    # survives a device change or a UI nudge that moves the button 40px.
    #
    # Picks the SMALLEST element containing the text, not the first one in
    # document order. The hierarchy is nested, so a parent container — often
    # the root itself, bounds [0,0][width,height] — also "contains" the
    # string; tapping its centre hits whatever happens to sit in the middle of
    # the screen. Smallest-area is the node the user would point at.
    SUBSTR="${1:-}"
    [[ -n "$SUBSTR" ]] || fail "Usage: appium_action.sh tap-on <substring>"
    SESSION_ID="$(resolve_session_id)"
    PAGE="$(get_page_source "$SESSION_ID")"
    MATCHES=$(echo "$PAGE" | tr '<' '\n' | grep -F "$SUBSTR")
    if [[ -z "$MATCHES" ]]; then
      ESCAPED="$(xml_escape "$SUBSTR")"
      [[ "$ESCAPED" != "$SUBSTR" ]] && MATCHES=$(echo "$PAGE" | tr '<' '\n' | grep -F "$ESCAPED")
    fi
    [[ -n "$MATCHES" ]] || fail "No element containing '$SUBSTR' found in current source."

    BEST_AREA=-1; CX=""; CY=""; BEST_BOUNDS=""
    while IFS= read -r NODE; do
      B=$(echo "$NODE" | grep -o 'bounds="\[[0-9-]\+,[0-9-]\+\]\[[0-9-]\+,[0-9-]\+\]"' | head -1)
      [[ -n "$B" ]] || continue
      C=$(echo "$B" | grep -o '[0-9-]\+')
      x1=$(echo "$C" | sed -n 1p); y1=$(echo "$C" | sed -n 2p)
      x2=$(echo "$C" | sed -n 3p); y2=$(echo "$C" | sed -n 4p)
      area=$(( (x2 - x1) * (y2 - y1) ))
      (( area > 0 )) || continue
      if (( BEST_AREA < 0 || area < BEST_AREA )); then
        BEST_AREA=$area
        CX=$(( (x1 + x2) / 2 )); CY=$(( (y1 + y2) / 2 ))
        BEST_BOUNDS="[$x1,$y1][$x2,$y2]"
      fi
    done <<< "$MATCHES"

    [[ -n "$CX" ]] || fail "Element(s) containing '$SUBSTR' have no usable bounds — tap by coordinates instead."
    do_tap "$SESSION_ID" "$CX" "$CY"
    echo "Tapped '$SUBSTR' at ($CX,$CY) — smallest matching element, bounds $BEST_BOUNDS"
    ;;

  find)
    SUBSTR="${1:-}"
    [[ -n "$SUBSTR" ]] || fail "Usage: appium_action.sh find <substring>"
    SESSION_ID="$(resolve_session_id)"
    PAGE="$(get_page_source "$SESSION_ID")"
    MATCHES=$(echo "$PAGE" | grep -F "$SUBSTR" | grep -o 'bounds="\[[0-9,-]*\]\[[0-9,-]*\]"')
    if [[ -z "$MATCHES" ]]; then
      ESCAPED="$(xml_escape "$SUBSTR")"
      [[ "$ESCAPED" != "$SUBSTR" ]] && MATCHES=$(echo "$PAGE" | grep -F "$ESCAPED" | grep -o 'bounds="\[[0-9,-]*\]\[[0-9,-]*\]"')
    fi
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
      if page_contains "$PAGE" "$SUBSTR"; then
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
      if ! page_contains "$PAGE" "$SUBSTR"; then
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
