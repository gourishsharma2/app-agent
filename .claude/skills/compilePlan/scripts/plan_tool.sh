#!/usr/bin/env bash
#
# plan_tool.sh — fixed entry point backing the compilePlan skill. Owns the
# mechanical half of "compiled execution plans": hashing source docs +
# screenshots, comparing those hashes to decide HIT/MISS, and writing/patching
# the plan + metadata files under execution-plans/. Deciding WHAT a plan
# should contain (reading the flow doc + screenshots, extracting actions and
# assertions) stays an LLM job (the flow-compiler agent) — this script never
# reads markdown or screenshots for their content, only hashes them.
#
# Usage:
#   plan_tool.sh plan-path <flowName>              # ensures execution-plans/ exists, prints PLAN_PATH=/META_PATH=
#   plan_tool.sh check <flowName>                   # HIT/MISS against current doc+screenshot hashes; prints PLAN_STATUS=, REASON=, PLAN_PATH=
#   plan_tool.sh write <flowName>                   # writes plan.json + meta.json from a JSON envelope on stdin (full (re)compile)
#   plan_tool.sh patch <flowName> <stepId>          # replaces one step in an existing plan.json from a JSON step object on stdin (local recovery)
#   plan_tool.sh schema-version                     # prints the schema version this script currently writes/expects
#
# See .claude/skills/compilePlan/SKILL.md for the envelope/step JSON shapes.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
PLAN_DIR="$PROJECT_ROOT/execution-plans"
SCHEMA_VERSION=1

fail() { echo "❌ $1" >&2; exit 1; }

command -v python3 >/dev/null 2>&1 || fail "python3 is required but was not found on PATH."

plan_path() { echo "$PLAN_DIR/$1.plan.json"; }
meta_path() { echo "$PLAN_DIR/$1.meta.json"; }

CMD="${1:-}"
[[ -n "$CMD" ]] || fail "Usage: plan_tool.sh <plan-path|check|write|patch|schema-version> [args]"
shift || true

case "$CMD" in
  schema-version)
    echo "$SCHEMA_VERSION"
    ;;

  plan-path)
    FLOW_NAME="${1:-}"
    [[ -n "$FLOW_NAME" ]] || fail "Usage: plan_tool.sh plan-path <flowName>"
    mkdir -p "$PLAN_DIR"
    echo "PLAN_PATH=$(plan_path "$FLOW_NAME" | sed "s|^$PROJECT_ROOT/||")"
    echo "META_PATH=$(meta_path "$FLOW_NAME" | sed "s|^$PROJECT_ROOT/||")"
    ;;

  check)
    # Pure hash comparison — no LLM cost. This is what makes it cheap to
    # check "is the plan still valid?" on every single run.
    FLOW_NAME="${1:-}"
    [[ -n "$FLOW_NAME" ]] || fail "Usage: plan_tool.sh check <flowName>"
    PLAN_FILE="$(plan_path "$FLOW_NAME")"
    META_FILE="$(meta_path "$FLOW_NAME")"

    if [[ ! -f "$PLAN_FILE" || ! -f "$META_FILE" ]]; then
      echo "PLAN_STATUS=MISS"
      echo "REASON=no-plan"
      echo "PLAN_PATH=${PLAN_FILE#$PROJECT_ROOT/}"
      exit 0
    fi

    python3 - "$META_FILE" "$SCHEMA_VERSION" "$PROJECT_ROOT" <<'PYEOF'
import hashlib, json, sys

meta_path, expected_schema, project_root = sys.argv[1], int(sys.argv[2]), sys.argv[3]

def sha256_of(path):
    try:
        with open(path, "rb") as f:
            return "sha256:" + hashlib.sha256(f.read()).hexdigest()
    except FileNotFoundError:
        return None

try:
    with open(meta_path) as f:
        meta = json.load(f)
except (json.JSONDecodeError, OSError):
    print("PLAN_STATUS=MISS")
    print("REASON=meta-unreadable")
    sys.exit(0)

if meta.get("schemaVersion") != expected_schema:
    print("PLAN_STATUS=MISS")
    print(f"REASON=schema-outdated:{meta.get('schemaVersion')}->{expected_schema}")
    sys.exit(0)

for rel_path, expected_hash in meta.get("docHashes", {}).items():
    actual = sha256_of(f"{project_root}/{rel_path}")
    if actual != expected_hash:
        print("PLAN_STATUS=MISS")
        print(f"REASON=doc-changed:{rel_path}")
        sys.exit(0)

for rel_path, expected_hash in meta.get("screenshotHashes", {}).items():
    actual = sha256_of(f"{project_root}/{rel_path}")
    if actual != expected_hash:
        print("PLAN_STATUS=MISS")
        print(f"REASON=screenshot-changed:{rel_path}")
        sys.exit(0)

print("PLAN_STATUS=HIT")
print(f"REASON=plan-version:{meta.get('planVersion', 'unknown')}")
PYEOF
    echo "PLAN_PATH=${PLAN_FILE#$PROJECT_ROOT/}"
    ;;

  write)
    # Full (re)compile. Stdin is a JSON envelope:
    #   { "plan": {...}, "docs": ["flow/x.md", ...], "screenshots": ["screenshots or figma Links/x/Step 1.png", ...], "appVersion": "..." }
    # The script hashes every path listed in docs/screenshots itself — the
    # caller never computes or states a hash.
    FLOW_NAME="${1:-}"
    [[ -n "$FLOW_NAME" ]] || fail "Usage: plan_tool.sh write <flowName> (JSON envelope via stdin)"
    mkdir -p "$PLAN_DIR"
    PLAN_FILE="$(plan_path "$FLOW_NAME")"
    META_FILE="$(meta_path "$FLOW_NAME")"

    # The heredoc below IS python3's stdin (it's how `python3 -` receives the
    # script text), so the envelope piped into THIS script can't also be read
    # via sys.stdin inside it — capture it to a temp file first and pass the
    # path as an argument instead.
    TMP_ENVELOPE="$(mktemp)"
    cat > "$TMP_ENVELOPE"
    python3 - "$PLAN_FILE" "$META_FILE" "$SCHEMA_VERSION" "$PROJECT_ROOT" "$TMP_ENVELOPE" <<'PYEOF' || { rm -f "$TMP_ENVELOPE"; fail "write failed — see error above"; }
import hashlib, json, sys, datetime, os

plan_file, meta_file, schema_version, project_root, envelope_file = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4], sys.argv[5]

with open(envelope_file) as f:
    envelope = json.load(f)
plan = envelope["plan"]
docs = envelope.get("docs", [])
screenshots = envelope.get("screenshots", [])
app_version = envelope.get("appVersion")

def sha256_of(rel_path):
    full = os.path.join(project_root, rel_path)
    with open(full, "rb") as f:
        return "sha256:" + hashlib.sha256(f.read()).hexdigest()

plan["schemaVersion"] = schema_version
plan.setdefault("flowName", os.path.basename(plan_file).split(".plan.json")[0])

doc_hashes = {p: sha256_of(p) for p in docs}
screenshot_hashes = {p: sha256_of(p) for p in screenshots}

prev_version = 0
if os.path.exists(meta_file):
    try:
        with open(meta_file) as f:
            prev_version = json.load(f).get("planVersion", 0)
    except (json.JSONDecodeError, OSError):
        prev_version = 0

meta = {
    "schemaVersion": schema_version,
    "planVersion": prev_version + 1,
    "docHashes": doc_hashes,
    "screenshotHashes": screenshot_hashes,
    "appVersion": app_version,
    "generatedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}

with open(plan_file, "w") as f:
    json.dump(plan, f, indent=2)
    f.write("\n")
with open(meta_file, "w") as f:
    json.dump(meta, f, indent=2)
    f.write("\n")

print(f"WROTE_PLAN_VERSION={meta['planVersion']}")
PYEOF
    rm -f "$TMP_ENVELOPE"
    echo "PLAN_PATH=${PLAN_FILE#$PROJECT_ROOT/}"
    echo "META_PATH=${META_FILE#$PROJECT_ROOT/}"
    ;;

  patch)
    # Local recovery write-back: replace exactly one step in an already-valid
    # plan. Stdin is the JSON for the replacement step object. docHashes /
    # screenshotHashes / schemaVersion are left untouched — the source docs
    # didn't change, only Claude's derived plan for this one step did.
    FLOW_NAME="${1:-}"; STEP_ID="${2:-}"
    [[ -n "$FLOW_NAME" && -n "$STEP_ID" ]] || fail "Usage: plan_tool.sh patch <flowName> <stepId> (JSON step object via stdin)"
    PLAN_FILE="$(plan_path "$FLOW_NAME")"
    META_FILE="$(meta_path "$FLOW_NAME")"
    [[ -f "$PLAN_FILE" && -f "$META_FILE" ]] || fail "No existing plan for '$FLOW_NAME' — run 'write' (full compile) first."

    TMP_STEP="$(mktemp)"
    cat > "$TMP_STEP"
    python3 - "$PLAN_FILE" "$META_FILE" "$STEP_ID" "$TMP_STEP" <<'PYEOF' || { rm -f "$TMP_STEP"; fail "patch failed — see error above"; }
import json, sys, datetime

plan_file, meta_file, step_id, step_file = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(step_file) as f:
    new_step = json.load(f)
new_step["id"] = int(step_id)

with open(plan_file) as f:
    plan = json.load(f)

steps = plan.get("steps", [])
for i, s in enumerate(steps):
    if str(s.get("id")) == str(step_id):
        steps[i] = new_step
        break
else:
    fail_msg = f"step id {step_id} not found in plan — nothing patched"
    print(fail_msg, file=sys.stderr)
    sys.exit(1)

with open(plan_file, "w") as f:
    json.dump(plan, f, indent=2)
    f.write("\n")

with open(meta_file) as f:
    meta = json.load(f)
meta["planVersion"] = meta.get("planVersion", 0) + 1
meta["generatedAt"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
with open(meta_file, "w") as f:
    json.dump(meta, f, indent=2)
    f.write("\n")

print(f"PATCHED_STEP={step_id}")
print(f"PLAN_VERSION={meta['planVersion']}")
PYEOF
    rm -f "$TMP_STEP"
    ;;

  *)
    fail "Unknown command: $CMD"
    ;;
esac
