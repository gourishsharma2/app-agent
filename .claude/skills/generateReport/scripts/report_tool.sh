#!/usr/bin/env bash
#
# report_tool.sh — small fixed entry point backing the generateReport skill.
# Handles the mechanical parts of run-report generation (unique file naming,
# directory creation, start/end timestamps, duration math) so that logic
# lives in exactly one place instead of being re-derived by every agent or
# command that produces a report. Content formatting itself (the metadata
# block, the per-step table) is left to the caller — that's an LLM task, not
# a mechanical one.
#
# Usage:
#   report_tool.sh new-path <flow_name>   # ensures execution/report/ exists, prints a unique report path
#   report_tool.sh start                  # records run-start time, prints it
#   report_tool.sh end                    # prints start/end/duration for the run started above

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
REPORT_DIR="$PROJECT_ROOT/execution/report"
STATE_FILE="$SCRIPT_DIR/../.run_state"

fail() { echo "❌ $1" >&2; exit 1; }

now_iso() { date -u +"%Y-%m-%d %H:%M:%S UTC"; }

CMD="${1:-}"
[[ -n "$CMD" ]] || fail "Usage: report_tool.sh <new-path|start|end> [args]"
shift || true

case "$CMD" in
  new-path)
    FLOW_NAME="${1:-}"
    [[ -n "$FLOW_NAME" ]] || fail "Usage: report_tool.sh new-path <flow_name>"
    mkdir -p "$REPORT_DIR"
    TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
    echo "execution/report/${FLOW_NAME}-${TIMESTAMP}.md"
    ;;

  start)
    START_EPOCH="$(date +%s)"
    START_ISO="$(now_iso)"
    {
      echo "START_EPOCH=$START_EPOCH"
      echo "START_ISO=\"$START_ISO\""
    } > "$STATE_FILE"
    echo "$START_ISO"
    ;;

  end)
    [[ -f "$STATE_FILE" ]] || fail "No active run. Run 'report_tool.sh start' first."
    # shellcheck disable=SC1090
    source "$STATE_FILE"
    END_EPOCH="$(date +%s)"
    END_ISO="$(now_iso)"
    ELAPSED=$((END_EPOCH - START_EPOCH))
    (( ELAPSED < 0 )) && ELAPSED=0
    if (( ELAPSED >= 60 )); then
      DURATION="$((ELAPSED / 60))m $((ELAPSED % 60))s"
    else
      DURATION="${ELAPSED}s"
    fi
    echo "START=$START_ISO"
    echo "END=$END_ISO"
    echo "DURATION=$DURATION"
    rm -f "$STATE_FILE"
    ;;

  *)
    fail "Unknown command: $CMD"
    ;;
esac
