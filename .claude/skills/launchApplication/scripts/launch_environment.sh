#!/usr/bin/env bash
#
# launchApplication skill — prepares the Android automation environment:
#   1. Ensures an Appium server is running
#   2. Ensures an Android emulator is running and fully booted
#   3. Disables the emulator's screen sleep timeout for the automation session
#   4. Installs the given APK by opening an Appium/UiAutomator2 session with
#      the given `app` path and autoGrantPermissions=true. See the comment
#      above that step for why this uses noReset instead of fullReset.
#
# Usage:
#   launch_environment.sh /absolute/path/to/app.apk
#   launch_environment.sh doctor      # check the toolchain without installing anything
#
# Env overrides:
#   ANDROID_HOME - Android SDK location (auto-detected if unset; see resolve_sdk below)
#   AVD_NAME   - which AVD to boot if no emulator is running (default: first from `emulator -list-avds`)
#   APPIUM_URL - Appium server base URL (default: appiumServerUrl from config.properties, else http://localhost:4723)

set -uo pipefail

# ---------------------------------------------------------------------------
# Step -1: Locate the Android SDK.
#
# Android Studio installs the SDK but does NOT put `emulator`, `adb` or
# `sdkmanager` on your PATH, and does not export ANDROID_HOME — that's a
# manual shell-profile edit most people never make. Previously this script
# just died with "emulator CLI not found on PATH" on a fresh machine even
# though the SDK was sitting right there. Resolve it ourselves so the script
# works out of the box, while still honouring an explicit ANDROID_HOME.
# ---------------------------------------------------------------------------
resolve_sdk() {
  if [[ -z "${ANDROID_HOME:-}" ]]; then
    local candidate
    for candidate in "${ANDROID_SDK_ROOT:-}" "$HOME/Library/Android/sdk" "$HOME/Android/Sdk" "/usr/local/share/android-sdk"; do
      if [[ -n "$candidate" && -d "$candidate/platform-tools" ]]; then
        export ANDROID_HOME="$candidate"
        break
      fi
    done
  fi
  if [[ -n "${ANDROID_HOME:-}" ]]; then
    export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$ANDROID_HOME}"
    export PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$ANDROID_HOME/cmdline-tools/latest/bin:$PATH"
  fi
}
resolve_sdk

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

# Resolved here (rather than further down with the rest of Step 0) because
# `doctor` needs both of these before any APK argument is validated.
APPIUM_URL="${APPIUM_URL:-}"
if [[ -z "$APPIUM_URL" ]]; then
  APPIUM_URL="http://localhost:4723"
  if [[ -f "$CONFIG_FILE" ]]; then
    cfg_url=$(grep -E '^[[:space:]]*appiumServerUrl[[:space:]]*=' "$CONFIG_FILE" | tail -1 | cut -d'=' -f2- | xargs)
    [[ -n "${cfg_url:-}" ]] && APPIUM_URL="$cfg_url"
  fi
fi

appium_ready() {
  curl -s -o /dev/null -w "%{http_code}" "$APPIUM_URL/status" 2>/dev/null | grep -q "^200$"
}

# ---------------------------------------------------------------------------
# Step 0: Resolve inputs / config
# ---------------------------------------------------------------------------
STEP="Argument validation"
APK_PATH="${1:-}"

# ---------------------------------------------------------------------------
# doctor — verify the toolchain is usable before anyone tries a real run.
# Reports every problem it finds rather than stopping at the first, so one
# pass tells you everything that needs fixing.
# ---------------------------------------------------------------------------
if [[ "$APK_PATH" == "doctor" ]]; then
  PROBLEMS=0
  echo "Android automation environment check"
  echo "===================================="
  if [[ -n "${ANDROID_HOME:-}" ]]; then
    ok "Android SDK: $ANDROID_HOME"
  else
    warn "Android SDK not found. Install it via Android Studio > Settings > Languages & Frameworks > Android SDK, or set ANDROID_HOME."
    PROBLEMS=$((PROBLEMS + 1))
  fi

  for tool in adb emulator java node curl; do
    if command -v "$tool" >/dev/null 2>&1; then
      ok "$tool: $(command -v "$tool")"
    else
      warn "$tool not found on PATH."
      PROBLEMS=$((PROBLEMS + 1))
    fi
  done

  if command -v avdmanager >/dev/null 2>&1; then
    ok "avdmanager: $(command -v avdmanager)"
  else
    warn "avdmanager/sdkmanager not found — install 'Android SDK Command-line Tools (latest)' in Android Studio's SDK Manager (SDK Tools tab) if you need to create AVDs from the CLI."
  fi

  if command -v appium >/dev/null 2>&1; then
    ok "appium: $(appium --version 2>/dev/null)"
    if appium driver list --installed 2>&1 | grep -q uiautomator2; then
      ok "appium uiautomator2 driver installed"
    else
      warn "uiautomator2 driver missing — install with: appium driver install uiautomator2"
      PROBLEMS=$((PROBLEMS + 1))
    fi
  else
    warn "appium not found — install with: npm install -g appium"
    PROBLEMS=$((PROBLEMS + 1))
  fi

  if appium_ready 2>/dev/null; then
    ok "Appium server responding at $APPIUM_URL"
  else
    info "Appium server not running at $APPIUM_URL (this script starts one automatically when needed)."
  fi

  AVDS="$(emulator -list-avds 2>/dev/null | grep -v '|')"
  if [[ -n "$AVDS" ]]; then
    ok "AVDs available:"
    echo "$AVDS" | sed 's/^/     /'
  else
    warn "No AVD found. Create one in Android Studio > Device Manager, or with avdmanager."
    PROBLEMS=$((PROBLEMS + 1))
  fi

  RUNNING="$(adb devices 2>/dev/null | awk '$2=="device" && $1 ~ /^emulator-/ {print $1}')"
  if [[ -n "$RUNNING" ]]; then
    ok "Emulator running: $RUNNING (API $(adb -s "${RUNNING%% *}" shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r'))"
  else
    info "No emulator currently running — one will be booted on the next run."
  fi

  if [[ -d "$PROJECT_ROOT/apk" ]] && ls "$PROJECT_ROOT/apk"/*.apk >/dev/null 2>&1; then
    ok "APK builds present in apk/"
  else
    warn "No APK found in apk/ — /run needs a build there before it can install anything."
    PROBLEMS=$((PROBLEMS + 1))
  fi

  echo ""
  if [[ $PROBLEMS -eq 0 ]]; then
    ok "Environment looks ready."
  else
    warn "$PROBLEMS problem(s) found — see the warnings above."
  fi
  exit $(( PROBLEMS > 0 ? 1 : 0 ))
fi

# `boot` brings the environment up (Appium + emulator, no install) — for
# running against an app that is already installed, or for API-only checks
# that still need an Appium session to read the screen.
BOOT_ONLY="false"
if [[ "$APK_PATH" == "boot" ]]; then
  BOOT_ONLY="true"
  ABS_APK_PATH=""
else
  [[ -n "$APK_PATH" ]] || fail "No APK path provided. Usage: launch_environment.sh <path-to-apk|boot|doctor>"
  [[ -f "$APK_PATH" ]] || fail "APK not found at path: $APK_PATH"
  case "$APK_PATH" in
    *.apk) ;;
    *) fail "Provided file is not an .apk: $APK_PATH" ;;
  esac
  ABS_APK_PATH="$(cd "$(dirname "$APK_PATH")" && pwd)/$(basename "$APK_PATH")"
fi

if [[ "$BOOT_ONLY" == "true" ]]; then
  info "Mode: boot only (no APK install)"
else
  info "Target APK: $ABS_APK_PATH"
fi
info "Appium URL: $APPIUM_URL"

command -v adb >/dev/null 2>&1 || fail "adb not found on PATH. Ensure Android SDK platform-tools is on PATH."
command -v curl >/dev/null 2>&1 || fail "curl not found on PATH."

# ---------------------------------------------------------------------------
# Step 1: Appium server — reuse if already up, else start it
# ---------------------------------------------------------------------------
STEP="Appium server"
info "Checking Appium server at $APPIUM_URL ..."

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
# Step 4: Prevent the emulator's screen from sleeping mid-run
#
# A long flow/test can have gaps between actions (thinking time, waiting on
# the user) long enough for the default screen timeout to kick in, which
# blanks the display and breaks screenshot-based evidence (adb screencap
# returns a black frame) until something wakes it back up. Push the timeout
# out for the life of this automation session instead of recovering from it
# mid-run.
# ---------------------------------------------------------------------------
STEP="Screen timeout configuration"
info "Disabling screen sleep on $DEVICE_SERIAL for the duration of this automation session..."
if adb -s "$DEVICE_SERIAL" shell settings put system screen_off_timeout 1800000 >/dev/null 2>&1; then
  ok "Screen sleep timeout set to 30 minutes on $DEVICE_SERIAL."
else
  warn "Could not set screen_off_timeout on $DEVICE_SERIAL — screen may still sleep during a long-idle run."
fi

if [[ "$BOOT_ONLY" == "true" ]]; then
  echo ""
  ok "Environment ready (boot only) — Appium: $APPIUM_URL | Device: $DEVICE_SERIAL | no APK installed."
  info "Open a session against an already-installed app with: .claude/skills/driveFlow/scripts/appium_action.sh open-session <appPackage> <appActivity>"
  exit 0
fi

# ---------------------------------------------------------------------------
# Step 5: Install the APK via an Appium/UiAutomator2 session
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
VERSION_CODE=""
VERSION_NAME=""
if [[ -n "$AAPT_BIN" ]]; then
  BADGING="$("$AAPT_BIN" dump badging "$ABS_APK_PATH" 2>/dev/null)"
  PACKAGE_NAME=$(echo "$BADGING" | awk -F"'" '/^package: name=/{print $2; exit}')
  VERSION_CODE=$(echo "$BADGING" | grep -o "versionCode='[^']*'" | head -1 | sed -E "s/versionCode='([^']*)'/\1/")
  VERSION_NAME=$(echo "$BADGING" | grep -o "versionName='[^']*'" | head -1 | sed -E "s/versionName='([^']*)'/\1/")
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
# Step 6: Verify the app is actually installed on the device
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

INSTALL_STATE_FILE="$SCRIPT_DIR/../.last_install_state"
{
  echo "APK_PATH=$ABS_APK_PATH"
  echo "APK_FILENAME=$(basename "$ABS_APK_PATH")"
  echo "PACKAGE_NAME=${PACKAGE_NAME:-unknown}"
  echo "VERSION_CODE=${VERSION_CODE:-unknown}"
  echo "VERSION_NAME=${VERSION_NAME:-unknown}"
  echo "DEVICE_SERIAL=$DEVICE_SERIAL"
  echo "INSTALLED_AT=$(date -u +"%Y-%m-%d %H:%M:%S UTC")"
} > "$INSTALL_STATE_FILE"

echo ""
ok "Environment ready — Appium: $APPIUM_URL | Device: $DEVICE_SERIAL | APK: $ABS_APK_PATH | Package: ${PACKAGE_NAME:-unknown} | versionCode: ${VERSION_CODE:-unknown} | versionName: ${VERSION_NAME:-unknown}"
