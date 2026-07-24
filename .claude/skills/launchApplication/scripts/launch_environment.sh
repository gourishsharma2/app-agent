#!/usr/bin/env bash
#
# launchApplication skill — prepares the Android automation environment:
#   1. Ensures an Appium server is running
#   2. Ensures an Android emulator is running and fully booted
#   3. Installs the given APK by opening an Appium/UiAutomator2 session with
#      the given `app` path and autoGrantPermissions=true. See the comment
#      above step 4 for why this uses noReset instead of fullReset.
#
# Usage:
#   launch_environment.sh /absolute/path/to/app.apk
#
# Env overrides:
#   AVD_NAME   - which AVD to boot if no emulator is running (default: first from `emulator -list-avds`)
#   APPIUM_URL - Appium server base URL (default: appiumServerUrl from config.properties, else http://localhost:4723)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
CONFIG_FILE="$PROJECT_ROOT/config.properties"
LOG_DIR="$SCRIPT_DIR/../logs"
APPIUM_LOG="$LOG_DIR/appium.log"
EMULATOR_LOG="$LOG_DIR/emulator.log"

DEVICE_SERIAL=""   # resolved dynamically in Step 2 below
APPIUM_BOOT_TIMEOUT=60
EMULATOR_DETECT_TIMEOUT=90
BOOT_COMPLETED_TIMEOUT=180

mkdir -p "$LOG_DIR"

STEP=""
fail() {
  echo "" >&2
  echo "❌ FAILED at step: ${STEP}" >&2
  echo "   Reason: $1" >&2
  exit 1
}
info() { echo "ℹ️  $1"; }
ok()   { echo "✅ $1"; }
warn() { echo "⚠️  $1" >&2; }

# ---------------------------------------------------------------------------
# Step 0: Resolve inputs / config
# ---------------------------------------------------------------------------
STEP="Argument validation"
APK_PATH="${1:-}"
[[ -n "$APK_PATH" ]] || fail "No APK path provided. Usage: launch_environment.sh <path-to-apk>"
[[ -f "$APK_PATH" ]] || fail "APK not found at path: $APK_PATH"
case "$APK_PATH" in
  *.apk) ;;
  *) fail "Provided file is not an .apk: $APK_PATH" ;;
esac
ABS_APK_PATH="$(cd "$(dirname "$APK_PATH")" && pwd)/$(basename "$APK_PATH")"

APPIUM_URL="${APPIUM_URL:-}"
if [[ -z "$APPIUM_URL" ]]; then
  APPIUM_URL="http://localhost:4723"
  if [[ -f "$CONFIG_FILE" ]]; then
    cfg_url=$(grep -E '^[[:space:]]*appiumServerUrl[[:space:]]*=' "$CONFIG_FILE" | tail -1 | cut -d'=' -f2- | xargs)
    [[ -n "${cfg_url:-}" ]] && APPIUM_URL="$cfg_url"
  fi
fi
info "Target APK: $ABS_APK_PATH"
info "Appium URL: $APPIUM_URL"

command -v adb >/dev/null 2>&1 || fail "adb not found on PATH. Ensure Android SDK platform-tools is on PATH."
command -v curl >/dev/null 2>&1 || fail "curl not found on PATH."

# ---------------------------------------------------------------------------
# Step 1: Appium server — reuse if already up, else start it
# ---------------------------------------------------------------------------
STEP="Appium server"
info "Checking Appium server at $APPIUM_URL ..."
appium_ready() {
  curl -s -o /dev/null -w "%{http_code}" "$APPIUM_URL/status" 2>/dev/null | grep -q "^200$"
}

if appium_ready; then
  ok "Appium server already running at $APPIUM_URL — reusing it."
else
  command -v appium >/dev/null 2>&1 || fail "appium CLI not found on PATH. Install with: npm install -g appium"
  info "No Appium server detected. Starting one (logs: $APPIUM_LOG)..."
  nohup appium > "$APPIUM_LOG" 2>&1 &
  APPIUM_PID=$!
  disown "$APPIUM_PID" 2>/dev/null || true

  waited=0
  until appium_ready; do
    sleep 2
    waited=$((waited + 2))
    if [[ $waited -ge $APPIUM_BOOT_TIMEOUT ]]; then
      fail "Appium server did not become ready within ${APPIUM_BOOT_TIMEOUT}s. Check $APPIUM_LOG"
    fi
  done
  ok "Appium server started (pid $APPIUM_PID) and is ready."
fi

# ---------------------------------------------------------------------------
# Step 2: Android emulator — reuse if already running, else boot one
# ---------------------------------------------------------------------------
STEP="Android emulator launch"
info "Checking for a running Android emulator..."

running_emulator() {
  adb devices 2>/dev/null | awk '$2=="device" && $1 ~ /^emulator-/ {print $1; exit}'
}

CURRENT_EMULATOR="$(running_emulator)"
if [[ -n "$CURRENT_EMULATOR" ]]; then
  ok "Emulator already running: $CURRENT_EMULATOR — reusing it."
  DEVICE_SERIAL="$CURRENT_EMULATOR"
else
  command -v emulator >/dev/null 2>&1 || fail "emulator CLI not found on PATH. Ensure \$ANDROID_HOME/emulator is on PATH."

  AVD_NAME="${AVD_NAME:-}"
  if [[ -z "$AVD_NAME" ]]; then
    AVD_NAME="$(emulator -list-avds 2>/dev/null | grep -v '|' | head -1)"
  fi
  [[ -n "$AVD_NAME" ]] || fail "No AVD available (emulator -list-avds returned nothing). Create one first or set AVD_NAME."

  info "No emulator running. Booting AVD '$AVD_NAME' (logs: $EMULATOR_LOG)..."
  nohup emulator -avd "$AVD_NAME" -netdelay none -netspeed full > "$EMULATOR_LOG" 2>&1 &
  disown "$!" 2>/dev/null || true

  waited=0
  until [[ -n "$(running_emulator)" ]]; do
    sleep 3
    waited=$((waited + 3))
    if [[ $waited -ge $EMULATOR_DETECT_TIMEOUT ]]; then
      fail "Emulator '$AVD_NAME' was not detected by adb within ${EMULATOR_DETECT_TIMEOUT}s. Check $EMULATOR_LOG"
    fi
  done
  DEVICE_SERIAL="$(running_emulator)"
  ok "Emulator detected by adb: $DEVICE_SERIAL"
fi

# ---------------------------------------------------------------------------
# Step 3: Wait until the emulator has fully booted (ready for adb commands)
# ---------------------------------------------------------------------------
STEP="Emulator boot completion"
info "Waiting for $DEVICE_SERIAL to finish booting..."

adb -s "$DEVICE_SERIAL" wait-for-device || fail "adb wait-for-device failed for $DEVICE_SERIAL"

waited=0
while true; do
  boot_completed="$(adb -s "$DEVICE_SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r\n')"
  [[ "$boot_completed" == "1" ]] && break
  sleep 3
  waited=$((waited + 3))
  if [[ $waited -ge $BOOT_COMPLETED_TIMEOUT ]]; then
    fail "Emulator $DEVICE_SERIAL did not report sys.boot_completed=1 within ${BOOT_COMPLETED_TIMEOUT}s"
  fi
done
ok "Emulator $DEVICE_SERIAL is fully booted and ready for ADB commands."

# ---------------------------------------------------------------------------
# Step 4: Install the APK via an Appium/UiAutomator2 session
#
# Opens a session with:
#   platformName=Android, automationName=UiAutomator2, deviceName=<detected serial>,
#   app=<apk path>, autoGrantPermissions=true, noReset=true
# Appium/UiAutomator2 performs the install and permission grant as part of
# creating that session (Appium-managed install via capabilities, not a raw
# `adb install` shell-out).
#
# We use noReset=true instead of fullReset=true because this is a throwaway
# prep session that installs then immediately closes: fullReset uninstalls
# the app when the session is torn down, which would undo the install we
# just did. To still guarantee a clean swap when a different APK build is
# provided, we explicitly uninstall the target package first, then let
# Appium install fresh with noReset (so teardown leaves it in place).
# ---------------------------------------------------------------------------
STEP="APK installation"

find_aapt() {
  if command -v aapt >/dev/null 2>&1; then
    command -v aapt
    return 0
  fi
  local sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
  [[ -n "$sdk" && -d "$sdk/build-tools" ]] || return 1
  local latest
  latest=$(ls -1 "$sdk/build-tools" 2>/dev/null | sort -V | tail -1)
  [[ -n "$latest" ]] || return 1
  local candidate="$sdk/build-tools/$latest/aapt"
  [[ -x "$candidate" ]] && echo "$candidate" || return 1
}

AAPT_BIN="$(find_aapt || true)"
PACKAGE_NAME=""
if [[ -n "$AAPT_BIN" ]]; then
  PACKAGE_NAME=$("$AAPT_BIN" dump badging "$ABS_APK_PATH" 2>/dev/null | awk -F"'" '/^package: name=/{print $2; exit}')
fi

if [[ -n "$PACKAGE_NAME" ]]; then
  info "Target package: $PACKAGE_NAME — uninstalling any existing copy to guarantee a clean install of this build..."
  adb -s "$DEVICE_SERIAL" uninstall "$PACKAGE_NAME" >/dev/null 2>&1 || true
else
  warn "Could not determine package name via aapt — proceeding without a pre-uninstall (existing installs of a different build version may not be cleanly replaced)."
fi

info "Installing APK via Appium using the project's existing capability flow (UiAutomator2, autoGrantPermissions=true)..."

SESSION_PAYLOAD=$(cat <<JSON
{
  "capabilities": {
    "alwaysMatch": {
      "platformName": "Android",
      "appium:automationName": "UiAutomator2",
      "appium:deviceName": "$DEVICE_SERIAL",
      "appium:udid": "$DEVICE_SERIAL",
      "appium:app": "$ABS_APK_PATH",
      "appium:autoGrantPermissions": true,
      "appium:noReset": true,
      "appium:newCommandTimeout": 180
    }
  }
}
JSON
)

RESPONSE="$(curl -s -X POST "$APPIUM_URL/session" -H "Content-Type: application/json" -d "$SESSION_PAYLOAD")"

if echo "$RESPONSE" | grep -q '"error"'; then
  ERR_MSG=$(echo "$RESPONSE" | grep -o '"message"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*:"([^"]*)"/\1/')
  fail "Appium rejected the session (APK install failed). ${ERR_MSG:+Message: $ERR_MSG. }Raw response: $RESPONSE"
fi

SESSION_ID=$(echo "$RESPONSE" | grep -o '"sessionId"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*:"([^"]*)"/\1/')
[[ -n "$SESSION_ID" ]] || fail "Could not parse sessionId from Appium response — install likely failed. Raw response: $RESPONSE"

ok "APK installed and app launched (Appium session $SESSION_ID)."

info "Closing the temporary Appium session so the device is free for the automation suite..."
curl -s -X DELETE "$APPIUM_URL/session/$SESSION_ID" > /dev/null
ok "Session closed."

# ---------------------------------------------------------------------------
# Step 5: Verify the app is actually installed on the device
# ---------------------------------------------------------------------------
STEP="Post-install verification"

if [[ -n "$PACKAGE_NAME" ]]; then
  if adb -s "$DEVICE_SERIAL" shell pm list packages 2>/dev/null | tr -d '\r' | grep -q "^package:${PACKAGE_NAME}$"; then
    ok "Verified installed package on device: $PACKAGE_NAME"
  else
    fail "Package '$PACKAGE_NAME' not found on device after install (adb shell pm list packages)"
  fi
else
  warn "Could not determine package name via aapt — skipping package-name verification. Appium already reported a successful session/install above."
fi

echo ""
ok "Environment ready — Appium: $APPIUM_URL | Device: $DEVICE_SERIAL | APK: $ABS_APK_PATH"
