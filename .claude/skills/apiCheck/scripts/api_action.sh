#!/usr/bin/env bash
#
# api_action.sh — the single fixed entry point behind the apiCheck skill:
# calls a backend API, validates its status/headers/body, and compares the
# values it returned against what the app is actually rendering on screen.
#
# This exists for exactly the same reason appium_action.sh does. Hand-rolling
# a fresh `curl https://.../vehicles -H "Authorization: Bearer eyJ..."` per
# check means the command text differs every single run (different tokens,
# ids, query strings), so no stable permission allowlist rule can match it and
# every run re-prompts — for every teammate, forever. One fixed path,
# allowlisted once in .claude/settings.json, fixes that.
#
# It is also why this is a STATEFUL cli. Every call must be a plain
# `api_action.sh <cmd> ...` with no `$(...)` capture (capturing breaks the
# allowlist match), so the response can't be held in a shell variable: the
# request is stored to a state file and the assertion subcommands read it
# back. Same pattern as appium_action.sh's session id.
#
# Usage:
#   --- setup / discovery ---
#   api_action.sh doctor                          # show resolved config + auth state
#   api_action.sh set-token <token>               # store a token you already have
#   api_action.sh login                           # log in via apiLoginPath, store the token
#   api_action.sh token-from-device <pkg> [prefsFile] [key]   # lift the app's own token off the emulator
#   api_action.sh device-prefs <pkg> [prefsFile]  # list/dump the app's SharedPreferences
#   api_action.sh sniff [pkg] [lines]             # distinct API URLs the app has hit (from logcat)
#
#   --- calling ---
#   api_action.sh get <endpointKey|/path|url> [--no-auth] [--header "Name: Value"]
#   api_action.sh post <endpointKey|/path|url> '<json>' [--no-auth] [--header "Name: Value"]
#   api_action.sh request <METHOD> <endpointKey|/path|url> ['<json>'] [--no-auth]
#
#   --- validating the response ---
#   api_action.sh last                            # method/url/status/time/size of the last call
#   api_action.sh body [--pretty] [--full]
#   api_action.sh headers
#   api_action.sh json <jsonPath>                 # print value(s), e.g. data.vehicles[0].vehicleNumber
#   api_action.sh assert-status <code>
#   api_action.sh assert-header <name> <substring>
#   api_action.sh assert-json <jsonPath> <expected> [--normalize raw|text|number|plate|digits]
#   api_action.sh assert-type <jsonPath> <string|number|boolean|array|object|null>
#   api_action.sh assert-count <jsonPath> <n|>n|>=n|<n|<=n>
#   api_action.sh assert-fields <arrayPath> <field1> [field2 ...]
#
#   --- comparing the response against the live screen ---
#   api_action.sh compare-ui <jsonPath> [--normalize m] [--in anchor] [--label name]
#   api_action.sh compare-ui-list <arrayPath> <field> [--limit n] [--normalize m] [--in anchor]
#
#   --in <anchor> restricts the comparison to on-screen elements containing
#   <anchor>. Use it whenever the value alone isn't unique on the screen —
#   "Running (2)" and "Stopped (2)" both satisfy a bare numeric 2, so an
#   unanchored check can pass against the wrong element.
#
#   --- reporting ---
#   api_action.sh results [--json]                # every check recorded this run (feeds the HTML report)
#   api_action.sh reset                           # clear stored response + recorded checks
#
# Config comes from config.properties at the project root (apiEnv,
# apiBaseUrl.<env>, apiAuthHeader, apiLoginPath, ...) — see api/README.md.
# Secrets never live in config.properties: pass them via the WE_API_TOKEN /
# WE_API_MOBILE / WE_API_PASSWORD environment variables, or let
# `token-from-device` lift the token the app itself is already using.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$SKILL_DIR/../../.." && pwd)"
CONFIG_FILE="$PROJECT_ROOT/config.properties"
ENDPOINTS_FILE="$PROJECT_ROOT/api/endpoints.properties"
HEADERS_FILE="$PROJECT_ROOT/api/headers.properties"
AUTH_STATE="$SKILL_DIR/.auth_state"
UI_SOURCE_FILE="$SKILL_DIR/.last_ui_source.xml"
HEADERS_TMP="$SKILL_DIR/.last_headers.txt"
BODY_TMP="$SKILL_DIR/.last_body.txt"
PY="$SCRIPT_DIR/api_json.py"
DRIVEFLOW_SESSION_STATE="$PROJECT_ROOT/.claude/skills/driveFlow/.session_state"

fail() { echo "❌ $1" >&2; exit 1; }

# Read a single key out of a `key=value` properties file (last one wins,
# same convention launch_environment.sh uses for appiumServerUrl).
read_prop() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 1
  grep -E "^[[:space:]]*$(echo "$key" | sed 's/\./\\./g')[[:space:]]*=" "$file" 2>/dev/null \
    | tail -1 | cut -d'=' -f2- | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

config() { read_prop "$CONFIG_FILE" "$1"; }

API_ENV="${WE_API_ENV:-$(config apiEnv)}"
[[ -n "$API_ENV" ]] || API_ENV="prod"
BASE_URL="${WE_API_BASE_URL:-$(config "apiBaseUrl.$API_ENV")}"
TIMEOUT="$(config apiTimeoutSeconds)"; [[ -n "$TIMEOUT" ]] || TIMEOUT=30
AUTH_HEADER_TEMPLATE="$(config apiAuthHeader)"
[[ -n "$AUTH_HEADER_TEMPLATE" ]] || AUTH_HEADER_TEMPLATE="Authorization: Bearer {token}"
LOGIN_PATH="$(config apiLoginPath)"
LOGIN_BODY_TEMPLATE="$(config apiLoginBody)"

resolve_token() {
  if [[ -n "${WE_API_TOKEN:-}" ]]; then
    echo "$WE_API_TOKEN"
  elif [[ -f "$AUTH_STATE" ]]; then
    grep -E '^TOKEN=' "$AUTH_STATE" | tail -1 | cut -d'=' -f2-
  fi
}

running_emulator() {
  adb devices 2>/dev/null | awk '$2=="device" && $1 ~ /^emulator-/ {print $1; exit}'
}

# endpointKey | /path | full URL  ->  absolute URL (query strings preserved)
resolve_url() {
  local target="$1"
  case "$target" in
    http://*|https://*) echo "$target"; return 0 ;;
    /*) [[ -n "$BASE_URL" ]] || fail "No base URL configured. Set apiBaseUrl.$API_ENV in config.properties (see api/README.md)."
        echo "${BASE_URL%/}$target"; return 0 ;;
  esac
  local key="${target%%\?*}" query=""
  [[ "$target" == *"?"* ]] && query="?${target#*\?}"
  local path
  path="$(read_prop "$ENDPOINTS_FILE" "$key")"
  [[ -n "$path" ]] || fail "Unknown endpoint key '$key'. Add it to api/endpoints.properties, or pass a /path or full URL."
  case "$path" in
    http://*|https://*) echo "${path}${query}" ;;
    *) [[ -n "$BASE_URL" ]] || fail "No base URL configured. Set apiBaseUrl.$API_ENV in config.properties."
       echo "${BASE_URL%/}${path}${query}" ;;
  esac
}

# Pull the current screen from the Appium session driveFlow already opened, so
# a UI/API comparison never needs its own session (or its own allowlist rule).
capture_ui_source() {
  [[ -f "$DRIVEFLOW_SESSION_STATE" ]] || fail "No active Appium session. Open one with 'appium_action.sh open-session <pkg> <activity>' before comparing against the UI."
  local session_id appium_url
  session_id="$(cat "$DRIVEFLOW_SESSION_STATE")"
  appium_url="${APPIUM_URL:-$(config appiumServerUrl)}"
  [[ -n "$appium_url" ]] || appium_url="http://localhost:4723"
  curl -s "${appium_url}/session/${session_id}/source" \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['value'])" > "$UI_SOURCE_FILE" 2>/dev/null
  [[ -s "$UI_SOURCE_FILE" ]] || fail "Could not read the current screen from Appium session $session_id (session expired? re-run open-session)."
}

do_request() {
  local method="$1" target="$2"; shift 2
  local body="" no_auth="false"
  local -a extra_headers=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-auth) no_auth="true"; shift ;;
      --header)  extra_headers+=("$2"); shift 2 ;;
      *)         body="$1"; shift ;;
    esac
  done

  local url; url="$(resolve_url "$target")" || exit 1
  local -a curl_args=(-s -o "$BODY_TMP" -D "$HEADERS_TMP" -w '%{http_code} %{time_total}' --max-time "$TIMEOUT" -X "$method" "$url")

  if [[ "$no_auth" != "true" ]]; then
    local token; token="$(resolve_token)"
    if [[ -n "$token" ]]; then
      curl_args+=(-H "${AUTH_HEADER_TEMPLATE//\{token\}/$token}")
    fi
  fi

  # Static headers the app always sends (app version, platform, user-code,
  # device id, ...) live in api/headers.properties, one `Name: Value` per line
  # — the same shape as curl's own -H flag. The Operator backend needs a dozen
  # of them on every call; retyping those per request is exactly the kind of
  # drift that makes an assertion fail for the wrong reason.
  local header
  if [[ -f "$HEADERS_FILE" ]]; then
    while IFS= read -r header; do
      header="${header#"${header%%[![:space:]]*}"}"   # ltrim
      [[ -z "$header" || "$header" == \#* ]] && continue
      [[ "$header" == *:* ]] || continue
      curl_args+=(-H "$header")
    done < "$HEADERS_FILE"
  fi
  for header in ${extra_headers+"${extra_headers[@]}"}; do
    curl_args+=(-H "$header")
  done

  if [[ -n "$body" ]]; then
    curl_args+=(-H "Content-Type: application/json" --data "$body")
  fi

  local metrics
  metrics="$(curl "${curl_args[@]}")" || fail "Request failed (network error, DNS, or timeout after ${TIMEOUT}s): $method $url"
  local status="${metrics%% *}" seconds="${metrics##* }"
  local millis; millis="$(python3 -c "print(int(float('${seconds:-0}') * 1000))" 2>/dev/null || echo 0)"
  python3 "$PY" save-response "$status" "$millis" "$url" "$method" "$HEADERS_TMP" "$BODY_TMP"
}

CMD="${1:-}"
[[ -n "$CMD" ]] || fail "Usage: api_action.sh <doctor|login|set-token|token-from-device|device-prefs|sniff|get|post|request|last|body|headers|json|assert-status|assert-header|assert-json|assert-type|assert-count|assert-fields|compare-ui|compare-ui-list|results|reset> [args]"
shift || true

case "$CMD" in
  doctor)
    echo "API_ENV=$API_ENV"
    echo "BASE_URL=${BASE_URL:-<unset — add apiBaseUrl.$API_ENV to config.properties>}"
    echo "TIMEOUT_SECONDS=$TIMEOUT"
    echo "AUTH_HEADER_TEMPLATE=$AUTH_HEADER_TEMPLATE"
    echo "LOGIN_PATH=${LOGIN_PATH:-<unset>}"
    if [[ -n "$(resolve_token)" ]]; then
      # Never echo the token itself — only where it came from.
      if [[ -n "${WE_API_TOKEN:-}" ]]; then
        echo "TOKEN=present (from the WE_API_TOKEN environment variable)"
      else
        echo "TOKEN=present (from .auth_state)"
      fi
    else
      echo "TOKEN=absent — run 'api_action.sh login' or 'api_action.sh token-from-device <pkg>'"
    fi
    if [[ -f "$HEADERS_FILE" ]]; then
      echo "STATIC_HEADERS=$(grep -cE '^[[:space:]]*[^#[:space:]].*:' "$HEADERS_FILE") from $HEADERS_FILE"
    else
      echo "STATIC_HEADERS=<api/headers.properties not found>"
    fi
    if [[ -f "$ENDPOINTS_FILE" ]]; then
      echo "ENDPOINTS ($ENDPOINTS_FILE):"
      grep -vE '^[[:space:]]*(#|$)' "$ENDPOINTS_FILE" | sed 's/^/  /'
    else
      echo "ENDPOINTS=<api/endpoints.properties not found>"
    fi
    ;;

  set-token)
    TOKEN="${1:-}"
    [[ -n "$TOKEN" ]] || fail "Usage: api_action.sh set-token <token>"
    echo "TOKEN=$TOKEN" > "$AUTH_STATE"
    chmod 600 "$AUTH_STATE" 2>/dev/null || true
    echo "Token stored (gitignored, this machine only)."
    ;;

  login)
    [[ -n "$LOGIN_PATH" ]] || fail "apiLoginPath is not set in config.properties — set it, or use 'token-from-device'/'set-token' instead."
    MOBILE="${WE_API_MOBILE:-}"; PASSWORD="${WE_API_PASSWORD:-}"
    [[ -n "$MOBILE" && -n "$PASSWORD" ]] || fail "Set WE_API_MOBILE and WE_API_PASSWORD in the environment before logging in (credentials are never read from a committed file)."
    [[ -n "$LOGIN_BODY_TEMPLATE" ]] || LOGIN_BODY_TEMPLATE='{"mobile":"{mobile}","password":"{password}"}'
    LOGIN_BODY="${LOGIN_BODY_TEMPLATE//\{mobile\}/$MOBILE}"
    LOGIN_BODY="${LOGIN_BODY//\{password\}/$PASSWORD}"
    do_request POST "$LOGIN_PATH" "$LOGIN_BODY" --no-auth
    TOKEN_PATH="$(config apiLoginTokenPath)"; [[ -n "$TOKEN_PATH" ]] || TOKEN_PATH="data.token"
    TOKEN="$(python3 "$PY" json "$TOKEN_PATH" 2>/dev/null | head -1)"
    [[ -n "$TOKEN" ]] || fail "Login response did not contain a token at '$TOKEN_PATH'. Inspect it with 'api_action.sh body --pretty' and set apiLoginTokenPath in config.properties."
    echo "TOKEN=$TOKEN" > "$AUTH_STATE"
    chmod 600 "$AUTH_STATE" 2>/dev/null || true
    echo "Login succeeded — token stored."
    ;;

  device-prefs)
    PKG="${1:-}"; PREFS_FILE="${2:-}"
    [[ -n "$PKG" ]] || fail "Usage: api_action.sh device-prefs <appPackage> [prefsFile.xml]"
    SERIAL="$(running_emulator)"
    [[ -n "$SERIAL" ]] || fail "No running emulator detected (adb devices)."
    if [[ -z "$PREFS_FILE" ]]; then
      echo "SharedPreferences files for $PKG:"
      adb -s "$SERIAL" shell run-as "$PKG" ls shared_prefs 2>&1 | sed 's/^/  /'
      echo ""
      echo "Dump one with: api_action.sh device-prefs $PKG <file.xml>"
      echo "(run-as only works on a debuggable build — that's the case for com.wheelseyeoperator.debug.)"
    else
      adb -s "$SERIAL" shell run-as "$PKG" cat "shared_prefs/$PREFS_FILE"
    fi
    ;;

  token-from-device)
    # The most reliable way to authenticate API checks as the same user the app
    # is logged in as: reuse the app's own session token instead of minting a
    # second one. Requires a debuggable build (run-as).
    PKG="${1:-}"; PREFS_FILE="${2:-}"; KEY="${3:-}"
    [[ -n "$PKG" ]] || fail "Usage: api_action.sh token-from-device <appPackage> [prefsFile.xml] [prefKey]"
    SERIAL="$(running_emulator)"
    [[ -n "$SERIAL" ]] || fail "No running emulator detected (adb devices)."
    if [[ -n "$PREFS_FILE" ]]; then
      FILES="$PREFS_FILE"
    else
      FILES="$(adb -s "$SERIAL" shell run-as "$PKG" ls shared_prefs 2>/dev/null | tr -d '\r')"
      [[ -n "$FILES" ]] || fail "Could not list shared_prefs for $PKG (is it installed, logged in, and a debuggable build?)."
    fi
    FOUND=""
    for f in $FILES; do
      XML="$(adb -s "$SERIAL" shell run-as "$PKG" cat "shared_prefs/$f" 2>/dev/null)"
      [[ -n "$XML" ]] || continue
      if [[ -n "$KEY" ]]; then
        VALUE="$(echo "$XML" | python3 -c "
import re,sys
xml = sys.stdin.read()
m = re.search(r'name=\"%s\"[^>]*>([^<]+)<' % re.escape('$KEY'), xml)
print(m.group(1) if m else '')")"
      else
        VALUE="$(echo "$XML" | python3 -c "
import re,sys
xml = sys.stdin.read()
for name, value in re.findall(r'name=\"([^\"]+)\"[^>]*>([^<]+)<', xml):
    if re.search(r'token|jwt|auth|session', name, re.I) and len(value) > 20:
        print('%s\t%s' % (name, value))
        break")"
      fi
      if [[ -n "$VALUE" ]]; then
        FOUND="$f"
        if [[ -n "$KEY" ]]; then
          echo "TOKEN=$VALUE" > "$AUTH_STATE"
          echo "Token taken from $f / $KEY and stored."
        else
          PREF_KEY="${VALUE%%$'\t'*}"; PREF_VALUE="${VALUE#*$'\t'}"
          echo "TOKEN=$PREF_VALUE" > "$AUTH_STATE"
          echo "Token taken from $f / $PREF_KEY and stored."
        fi
        chmod 600 "$AUTH_STATE" 2>/dev/null || true
        break
      fi
    done
    [[ -n "$FOUND" ]] || fail "No token-looking preference found for $PKG. Inspect manually: api_action.sh device-prefs $PKG"
    ;;

  sniff)
    # Endpoint discovery: which URLs has the app actually called? Beats
    # guessing paths, and keeps the logcat filtering inside this allowlisted
    # script instead of a hand-rolled `adb logcat | grep` one-liner.
    PKG="${1:-}"; LINES="${2:-4000}"
    SERIAL="$(running_emulator)"
    [[ -n "$SERIAL" ]] || fail "No running emulator detected (adb devices)."
    if [[ -n "$PKG" ]]; then
      PID="$(adb -s "$SERIAL" shell pidof "$PKG" 2>/dev/null | tr -d '\r' | awk '{print $1}')"
      [[ -n "$PID" ]] || fail "$PKG is not running on $SERIAL — launch the app first, then re-run sniff."
      RAW="$(adb -s "$SERIAL" logcat -d -t "$LINES" --pid="$PID" 2>/dev/null)"
    else
      RAW="$(adb -s "$SERIAL" logcat -d -t "$LINES" 2>/dev/null)"
    fi
    echo "$RAW" | grep -oE 'https?://[A-Za-z0-9._~:/?#@!$&()*+,;=%-]+' | sed 's/[",)]*$//' | sort -u
    echo ""
    echo "(Distinct URLs seen in the last $LINES log lines. Nothing here usually means the app's HTTP client doesn't log — capture with a proxy instead, see api/README.md.)"
    ;;

  get)     TARGET="${1:-}"; [[ -n "$TARGET" ]] || fail "Usage: api_action.sh get <endpointKey|/path|url>"; shift; do_request GET "$TARGET" "$@" ;;
  post)    TARGET="${1:-}"; [[ -n "$TARGET" ]] || fail "Usage: api_action.sh post <endpointKey|/path|url> '<json>'"; shift; do_request POST "$TARGET" "$@" ;;
  request)
    METHOD="${1:-}"; TARGET="${2:-}"
    [[ -n "$METHOD" && -n "$TARGET" ]] || fail "Usage: api_action.sh request <METHOD> <endpointKey|/path|url> ['<json>']"
    shift 2; do_request "$METHOD" "$TARGET" "$@" ;;

  compare-ui)
    JSON_PATH="${1:-}"
    [[ -n "$JSON_PATH" ]] || fail "Usage: api_action.sh compare-ui <jsonPath> [--normalize m] [--label name]"
    shift
    capture_ui_source
    python3 "$PY" compare-ui "$JSON_PATH" "$UI_SOURCE_FILE" "$@"
    ;;

  compare-ui-list)
    ARRAY_PATH="${1:-}"; FIELD="${2:-}"
    [[ -n "$ARRAY_PATH" && -n "$FIELD" ]] || fail "Usage: api_action.sh compare-ui-list <arrayPath> <field> [--limit n] [--normalize m]"
    shift 2
    capture_ui_source
    python3 "$PY" compare-ui-list "$ARRAY_PATH" "$FIELD" "$UI_SOURCE_FILE" "$@"
    ;;

  last|body|headers|json|assert-status|assert-header|assert-json|assert-type|assert-count|assert-fields|results)
    python3 "$PY" "$CMD" "$@"
    ;;

  reset)
    python3 "$PY" reset
    rm -f "$UI_SOURCE_FILE" "$HEADERS_TMP" "$BODY_TMP"
    ;;

  *)
    fail "Unknown command: $CMD"
    ;;
esac
