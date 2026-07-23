#!/usr/bin/env bash
#
# launchApplication skill — tears down the Android automation environment:
#   1. Stops the running emulator (adb emu kill)
#   2. Stops the Appium server process
#
# Call this once the whole automation task (launch + drive flow) is done —
# not right after launch_environment.sh, since driveFlow still needs the
# Appium server and emulator alive in between.
#
# Usage:
#   close_environment.sh
#
# Env overrides:
#   APPIUM_URL - Appium server base URL (default: appiumServerUrl from config.properties, else http://localhost:4723)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
CONFIG_FILE="$PROJECT_ROOT/config.properties"

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

STEP="Argument validation"
command -v adb >/dev/null 2>&1 || fail "adb not found on PATH. Ensure Android SDK platform-tools is on PATH."
command -v curl >/dev/null 2>&1 || fail "curl not found on PATH."

APPIUM_URL="${APPIUM_URL:-}"
if [[ -z "$APPIUM_URL" ]]; then
  APPIUM_URL="http://localhost:4723"
  if [[ -f "$CONFIG_FILE" ]]; then
    cfg_url=$(grep -E '^[[:space:]]*appiumServerUrl[[:space:]]*=' "$CONFIG_FILE" | tail -1 | cut -d'=' -f2- | xargs)
    [[ -n "${cfg_url:-}" ]] && APPIUM_URL="$cfg_url"
  fi
fi
info "Appium URL: $APPIUM_URL"

# ---------------------------------------------------------------------------
# Step 1: Stop any running emulator(s)
# ---------------------------------------------------------------------------
STEP="Emulator shutdown"

running_emulators() {
  adb devices 2>/dev/null | awk '$2=="device" && $1 ~ /^emulator-/ {print $1}'
}

EMULATORS="$(running_emulators)"
if [[ -z "$EMULATORS" ]]; then
  info "No running emulator found — nothing to stop."
else
  while IFS= read -r serial; do
    [[ -n "$serial" ]] || continue
    info "Stopping emulator $serial ..."
    adb -s "$serial" emu kill >/dev/null 2>&1 || warn "adb emu kill did not confirm shutdown for $serial"
  done <<< "$EMULATORS"

  waited=0
  while [[ -n "$(running_emulators)" ]]; do
    sleep 2
    waited=$((waited + 2))
    if [[ $waited -ge 30 ]]; then
      warn "Emulator still listed in 'adb devices' after 30s — it may still be shutting down in the background."
      break
    fi
  done
  ok "Emulator shutdown complete."
fi

# ---------------------------------------------------------------------------
# Step 2: Stop the Appium server, if running
# ---------------------------------------------------------------------------
STEP="Appium server shutdown"

appium_ready() {
  curl -s -o /dev/null -w "%{http_code}" "$APPIUM_URL/status" 2>/dev/null | grep -q "^200$"
}

if ! appium_ready; then
  info "No Appium server responding at $APPIUM_URL — nothing to stop."
else
  APPIUM_PORT="$(echo "$APPIUM_URL" | sed -E 's#.*:([0-9]+).*#\1#')"
  APPIUM_PID=""
  if command -v lsof >/dev/null 2>&1 && [[ -n "$APPIUM_PORT" ]]; then
    APPIUM_PID="$(lsof -ti tcp:"$APPIUM_PORT" -sTCP:LISTEN 2>/dev/null | head -1)"
  fi

  if [[ -z "$APPIUM_PID" ]]; then
    fail "Appium server is responding at $APPIUM_URL but its process could not be identified (lsof unavailable or port not found). Stop it manually."
  fi

  info "Stopping Appium server (pid $APPIUM_PID) on port $APPIUM_PORT ..."
  kill "$APPIUM_PID" 2>/dev/null || warn "Could not send SIGTERM to pid $APPIUM_PID"

  waited=0
  while appium_ready; do
    sleep 1
    waited=$((waited + 1))
    if [[ $waited -ge 10 ]]; then
      warn "Appium still responding after SIGTERM — sending SIGKILL."
      kill -9 "$APPIUM_PID" 2>/dev/null || true
      break
    fi
  done
  ok "Appium server stopped."
fi

echo ""
ok "Environment torn down — Appium and emulator stopped (or were already not running)."
