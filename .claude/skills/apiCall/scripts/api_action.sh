#!/usr/bin/env bash
#
# apiCall skill — the ONE fixed entry point for calling backend APIs, storing
# their responses in the runtime context, and exposing those values to a flow.
#
# Why a single fixed script (same reasoning as appium_action.sh / plan_tool.sh):
# .claude/settings.json allowlists this exact literal path. A hand-rolled
# `curl ... -H "token: eyJ..."` differs on every run, so no allowlist rule can
# match it and every run re-prompts — for every teammate, forever. Issue each
# call as its own plain command: never wrapped in $(...), never chained with &&.
#
# That constraint is also why responses are not printed for capture: the
# response is bound into .context.json and read back by the next call.
#
# Usage:
#   api_action.sh doctor <environment>
#       Resolved base URL, timeout, path keys, header names, and which runtime
#       inputs are still missing. Never prints a token. Run this first when a
#       call misbehaves.
#
#   api_action.sh set-runtime <key=value> [key=value ...]
#       Stores runtime inputs (token, userCode, deviceName, deviceId,
#       androidVersion) into the context for subsequent calls.
#
#   api_action.sh call <environment> <pathKey|/path|url> [--method GET]
#                       [--bind api] [--body '<json>'] [--print-body]
#       Loads config, merges headers, executes, binds the response.
#       Exit 0 on 2xx, 1 otherwise.
#
#   api_action.sh context [<dotted.path>]
#       Dumps the context with secrets redacted, or prints one value.
#
#   api_action.sh context-set <dotted.path> <value>
#   api_action.sh reset
#
# Env config lives in api/environments/<env>/{base_url,headers,paths}.md.
# Nothing here is hardcoded — add an endpoint by editing paths.md.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail() {
  echo "❌ $1" >&2
  exit 1
}

[[ $# -ge 1 ]] || fail "Usage: api_action.sh <doctor|set-runtime|call|context|context-set|reset> [args]"

command -v python3 >/dev/null 2>&1 || fail "python3 is required by apiCall but was not found on PATH."

exec python3 "$SCRIPT_DIR/api_cli.py" "$@"
