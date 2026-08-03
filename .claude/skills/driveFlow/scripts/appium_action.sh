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
#   appium_action.sh run-plan <plan.json> [--from-step N] [--environment <Staging|Production>] [--test-user <name>] [--mobile <number>] [--password <pass>] [--user-code <code>]
#                                            # deterministically drives an ENTIRE compiled
#                                            # execution plan (see .claude/skills/compilePlan/SKILL.md) in one
#                                            # call — opens/reuses a session per the plan's appPackage/appActivity,
#                                            # dispatches every step's action(s), checks screenMarker + assertions,
#                                            # and stops at the first real divergence instead of guessing. Prints
#                                            # one `PLAN_RESULT_JSON=...` line; leaves the session OPEN on exit
#                                            # (pass or diverge) so a recovery pass or a resumed --from-step call
#                                            # can reuse it. No LLM calls happen inside this — that's the point.
#                                            # --environment selects test-data/<Staging|Production lowercased>.properties
#                                            # (default Production); --test-user selects a named block within that file
#                                            # (e.g. testUserOne) to resolve ${mobileNumber}/${password}/${userCode}
#                                            # tokens anywhere in the plan against. Omitting --test-user falls back to
#                                            # that file's `default*` entry if one exists, else run-plan fails asking
#                                            # for an explicit --test-user (see test-data/*.properties for names).
#                                            # --mobile/--password/--user-code supply a credential value directly on
#                                            # the command line instead of looking it up from a test-data file — each
#                                            # given value overrides just that one field; if both --mobile AND
#                                            # --password are given, the test-data file/--test-user isn't consulted
#                                            # at all (no file entry required for a fully ad-hoc credential set).
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
# recognizes consistently. Since `type`/`back` already go through adb in
# this script, this keeps one gesture mechanism instead of two.

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

# cfg_get_file <file> <key> — reads a single flat KEY=value line out of any
# .properties-style file (config.properties or test-data/*.properties).
cfg_get_file() {
  local file="$1" key="$2"
  grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" 2>/dev/null | tail -1 | cut -d'=' -f2- | xargs
}

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

# text_landed <text> — reads a page source on stdin, exits 0 if <text>
# actually landed in the typed field. A masked (password) field never
# exposes its literal text to the accessibility tree even when typing
# worked correctly (node marked password="true", text rendered as
# asterisks) — falls back to comparing that masked value's character count
# against <text>'s length instead of requiring an exact substring match.
text_landed() {
  python3 -c '
import re, sys
text = sys.argv[1]
page = sys.stdin.read()
if text in page:
    sys.exit(0)
for line in page.splitlines():
    if "password=\"true\"" in line:
        m = re.search(r"text=\"([^\"]*)\"", line)
        if m and len(m.group(1)) == len(text):
            sys.exit(0)
sys.exit(1)
' "$1"
}

do_swipe() {
  local x1="$2" y1="$3" x2="$4" y2="$5" duration="${6:-450}"
  local device_serial
  device_serial="$(running_emulator)"
  [[ -n "$device_serial" ]] || fail "No running emulator detected (adb devices)."
  adb -s "$device_serial" shell input swipe "$x1" "$y1" "$x2" "$y2" "$duration"
}

CMD="${1:-}"
[[ -n "$CMD" ]] || fail "Usage: appium_action.sh <open-session|tap|long-press|double-tap|type|back|hide-keyboard|wake-screen|swipe|scroll|scroll-to|source|contains|assert-all|find|wait-for|wait-until-gone|run-plan|close-session> [args]"
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
    SESSION_ID="$(resolve_session_id)"
    # adb shell input text fires immediately with no guarantee the target
    # field is actually focus-ready yet (e.g. right after a screen-navigation
    # tap) — a slow transition can drop the first keystroke. Read back the
    # live accessibility tree after typing and retry (clearing first) rather
    # than trusting the injection blindly.
    MAX_TYPE_ATTEMPTS=3
    ATTEMPT=1
    while :; do
      adb -s "$DEVICE_SERIAL" shell input text "$TEXT"
      sleep 0.5
      PAGE="$(get_page_source "$SESSION_ID")"
      echo "$PAGE" | text_landed "$TEXT" && break
      [[ $ATTEMPT -lt $MAX_TYPE_ATTEMPTS ]] || fail "Typed text did not match live field content after $MAX_TYPE_ATTEMPTS attempts (target field may not have been focused/ready in time): \"$TEXT\""
      CLEAR_COUNT=$(( ${#TEXT} * 2 > 30 ? ${#TEXT} * 2 : 30 ))
      CLEAR_KEYS="123"
      for ((i = 0; i < CLEAR_COUNT; i++)); do CLEAR_KEYS="$CLEAR_KEYS 67"; done
      # shellcheck disable=SC2086
      adb -s "$DEVICE_SERIAL" shell input keyevent $CLEAR_KEYS
      sleep 0.3
      ATTEMPT=$((ATTEMPT + 1))
    done
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
    if echo "$PAGE" | grep -qF "$SUBSTR"; then
      echo "FOUND: $SUBSTR (already visible, no scroll needed)"
      exit 0
    fi

    STUCK_COUNT=0
    for ((i = 1; i <= MAX_SCROLLS; i++)); do
      swipe_once
      sleep 1
      NEW_PAGE="$(get_page_source "$SESSION_ID")"
      if echo "$NEW_PAGE" | grep -qF "$SUBSTR"; then
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
    if echo "$PAGE" | grep -qF "$SUBSTR"; then
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
      if echo "$PAGE" | grep -qF "$SUBSTR"; then
        echo "FOUND: $SUBSTR"
      else
        echo "NOT FOUND: $SUBSTR"
        FAIL_COUNT=$((FAIL_COUNT + 1))
      fi
    done
    [[ $FAIL_COUNT -eq 0 ]] || exit 1
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

  run-plan)
    PLAN_FILE="${1:-}"
    [[ -n "$PLAN_FILE" ]] || fail "Usage: appium_action.sh run-plan <plan.json> [--from-step N] [--environment <Staging|Production>] [--test-user <name>] [--mobile <number>] [--password <pass>] [--user-code <code>]"
    [[ -f "$PLAN_FILE" ]] || fail "Plan file not found: $PLAN_FILE"
    shift || true
    FROM_STEP=1
    ENVIRONMENT="Production"
    TEST_USER=""
    CLI_MOBILE=""
    CLI_PASSWORD=""
    CLI_USERCODE=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --from-step) FROM_STEP="${2:-1}"; shift 2 ;;
        --environment) ENVIRONMENT="${2:-Production}"; shift 2 ;;
        --test-user) TEST_USER="${2:-}"; shift 2 ;;
        --mobile) CLI_MOBILE="${2:-}"; shift 2 ;;
        --password) CLI_PASSWORD="${2:-}"; shift 2 ;;
        --user-code) CLI_USERCODE="${2:-}"; shift 2 ;;
        *) fail "Unknown run-plan flag: $1" ;;
      esac
    done

    if [[ -n "$CLI_MOBILE" && -n "$CLI_PASSWORD" ]]; then
      # Both given directly — use them as-is, no test-data file needed at all.
      MOBILE="$CLI_MOBILE"
      PASS="$CLI_PASSWORD"
      USERCODE="$CLI_USERCODE"
    else
      ENV_LOWER=$(echo "$ENVIRONMENT" | tr '[:upper:]' '[:lower:]')
      TEST_DATA_FILE="$PROJECT_ROOT/test-data/$ENV_LOWER.properties"
      [[ -f "$TEST_DATA_FILE" ]] || fail "Test-data file not found: $TEST_DATA_FILE"

      if [[ -z "$TEST_USER" ]]; then
        TEST_USER="default"
        MOBILE=$(cfg_get_file "$TEST_DATA_FILE" "defaultMobileNumber")
        [[ -n "$MOBILE" ]] || fail "No 'default' test user in $TEST_DATA_FILE — pass --test-user <name>, or --mobile/--password directly."
      else
        MOBILE=$(cfg_get_file "$TEST_DATA_FILE" "${TEST_USER}MobileNumber")
        [[ -n "$MOBILE" ]] || fail "Test user '$TEST_USER' not found in $TEST_DATA_FILE (no ${TEST_USER}MobileNumber key)."
      fi
      PASS=$(cfg_get_file "$TEST_DATA_FILE" "${TEST_USER}Password")
      USERCODE=$(cfg_get_file "$TEST_DATA_FILE" "${TEST_USER}UserCode")

      # A CLI value for just one field overrides that field only, keeping
      # the other resolved from the test-data file above.
      [[ -n "$CLI_MOBILE" ]] && MOBILE="$CLI_MOBILE"
      [[ -n "$CLI_PASSWORD" ]] && PASS="$CLI_PASSWORD"
      [[ -n "$CLI_USERCODE" ]] && USERCODE="$CLI_USERCODE"
    fi

    command -v python3 >/dev/null 2>&1 || fail "python3 is required for run-plan but was not found on PATH."
    DEVICE_SERIAL="$(running_emulator)"
    [[ -n "$DEVICE_SERIAL" ]] || fail "No running emulator detected (adb devices). Run launchApplication first."
    python3 "$SCRIPT_DIR/run_plan.py" "$PLAN_FILE" "$FROM_STEP" "$APPIUM_URL" "$STATE_FILE" "$DEVICE_SERIAL" "$MOBILE" "$PASS" "$USERCODE"
    exit $?
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
