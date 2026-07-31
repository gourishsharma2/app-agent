---
name: compilePlan
description: Manages compiled execution plans under execution-plans/ — a cached, structured (JSON) replacement for re-reading a flow/test doc's markdown and screenshots on every run. Provides hash-based cache validity checking (check), full (re)compilation persistence (write), and single-step local-recovery patching (patch) through one fixed script. Use before driving a flow doc: check whether a valid plan already exists, compile one if not (flow-compiler agent), then hand the plan to driveFlow's `run-plan` for deterministic execution.
---

# compilePlan

This is the caching layer that lets a flow/test doc under `flow/` or
`tests/**` be *understood once* (by reading its markdown + screenshots) and
*replayed many times* without paying that reading/reasoning cost again, until
the doc or its screenshots actually change.

## Why this exists

Driving a flow the old way means Claude re-reads the whole `.md` doc and
re-views every screenshot on every single run, to re-derive the same tap
selectors and assertions it derived last time. None of that is persisted
anywhere, so identical work happens run after run. A **compiled execution
plan** is that derived knowledge, written down once as structured JSON:
which selector to tap, which screen marker confirms a transition landed,
which substrings to assert. Once it exists and is still valid, driving the
flow becomes a deterministic script loop (see `driveFlow`'s `run-plan`
subcommand) with no per-step reasoning at all.

## Where plans live

```
execution-plans/
    <flowName>.plan.json   # the compiled steps — what to do, what to check
    <flowName>.meta.json    # cache-validity metadata — hashes, versions
```

`<flowName>` matches the name `/list_flow` and `/run` already use for that
doc (filename without `.md`). Both files are committed like any other
generated-but-reviewable artifact (similar to `execution/report/`) — never
hand-edited; always produced by `plan_tool.sh write`/`patch`.

## Script usage

One fixed script, `.claude/skills/compilePlan/scripts/plan_tool.sh`. Issue
each call as its own single plain command, same reasoning as every other
script in this repo:

```bash
# Ensure execution-plans/ exists and get the paths for a given flow.
.claude/skills/compilePlan/scripts/plan_tool.sh plan-path <flowName>
# -> PLAN_PATH=execution-plans/<flowName>.plan.json
#    META_PATH=execution-plans/<flowName>.meta.json

# Pure hash comparison — no LLM cost, safe/cheap to call before every run.
.claude/skills/compilePlan/scripts/plan_tool.sh check <flowName>
# -> PLAN_STATUS=HIT|MISS
#    REASON=no-plan | doc-changed:<path> | screenshot-changed:<path> | schema-outdated:<old>-><new> | meta-unreadable | plan-version:<n>
#    PLAN_PATH=execution-plans/<flowName>.plan.json

# Full (re)compile — writes plan.json + meta.json. JSON envelope via stdin (see schema below).
.claude/skills/compilePlan/scripts/plan_tool.sh write <flowName> <<'JSON'
{ "plan": { ... }, "docs": ["flow/<flowName>.md"], "screenshots": ["screenshots or figma Links/<flowName>/Step 1.png", ...], "appVersion": "com.wheelseyeoperator.debug@23.7.0(1)" }
JSON
# -> WROTE_PLAN_VERSION=<n>, then PLAN_PATH=/META_PATH=

# Local recovery write-back — replaces exactly one step, leaves hashes/schemaVersion untouched.
.claude/skills/compilePlan/scripts/plan_tool.sh patch <flowName> <stepId> <<'JSON'
{ "screenMarker": "...", "action": {...}, "assertions": [...] }
JSON
# -> PATCHED_STEP=<id>, PLAN_VERSION=<n>

# What schema version this script currently writes/expects.
.claude/skills/compilePlan/scripts/plan_tool.sh schema-version
```

`check` and `write`/`patch` never read the markdown doc or any screenshot's
*content* — only their raw bytes, to hash them. Deciding what a plan should
contain is always an LLM job (the `flow-compiler` agent); this script only
does the mechanical parts: hashing, comparing, and atomically persisting
JSON files.

## Cache invalidation model

`meta.json` records a `sha256:` hash per source doc (`docHashes`) and per
screenshot (`screenshotHashes`) that the compiler actually read to build the
plan — for a `tests/*.md` doc with a precondition on a `flow/*.md` doc, that
means **both** docs' hashes are tracked, so editing the referenced flow doc
invalidates the test's plan too, not just the test doc's own hash.

`check` recomputes every hash listed in `meta.json` against the live files on
disk right now and reports the first mismatch it finds — deliberately no
manual version numbers (`v1.0.0` etc.) to remember to bump; editing a `.md`
file or replacing a screenshot is automatically enough to invalidate the
plan, and leaving them untouched is automatically enough to keep reusing it.
`schemaVersion` (bumped in this script when the plan JSON *shape* itself
changes, independent of any flow doc) invalidates every plan at once,
forcing a clean recompile against the new shape.

## Plan JSON schema (schemaVersion 1)

```json
{
  "schemaVersion": 1,
  "flowName": "loginFlow",
  "sourceDoc": "flow/loginFlow.md",
  "referencedDocs": [],
  "appPackage": "com.wheelseyeoperator.debug",
  "appActivity": ".ui.launch.LaunchActivity",
  "steps": [
    {
      "id": 1,
      "title": "App launch / login screen",
      "screenMarker": "Login to your account",
      "action": null,
      "assertions": ["Login to your account", "Phone number", "Send OTP", "Continue with password"],
      "knownNonBug": false,
      "retries": 1,
      "notes": ""
    },
    {
      "id": 2,
      "title": "Enter mobile number",
      "action": { "type": "type", "text": "<from application/test-data.md>" },
      "assertions": ["Send OTP", "Continue with password"]
    },
    {
      "id": 3,
      "title": "Enter password",
      "action": { "type": "tap", "selector": "Continue with password" },
      "screenMarker": "Password",
      "assertions": ["Phone number", "Password", "Login", "Create new password"]
    },
    {
      "id": 4,
      "title": "Post-login prompts",
      "action": { "type": "tap", "selector": "Login" },
      "waitFor": { "text": "Allow WheelsEye to send you notifications?", "timeoutSeconds": 30 },
      "assertions": ["Allow WheelsEye to send you notifications?", "Unauthenticated App Detected"],
      "knownNonBug": false
    },
    {
      "id": 5,
      "title": "Home page",
      "action": [{ "type": "tap", "selector": "Don't allow" }, { "type": "tap", "selector": "Okay" }],
      "screenMarker": "FasTag",
      "assertions": ["FasTag", "Wallet Balance", "Home"]
    }
  ]
}
```

Field notes:

- **`action`** is `null` (no action, assertion-only step), a single action
  object, or an array of action objects executed in order. `type` is one of
  `tap` / `type` / `back` / `scroll` / `scroll-to` / `wait-for` /
  `wait-until-gone` / `double-tap` / `long-press` — the exact same verbs as
  `appium_action.sh`'s existing subcommands, because `run-plan` dispatches
  each action to that subcommand's underlying logic directly.
- **`selector`** is always text (`content-desc`/visible label), resolved to
  live `bounds` at execute time the same way `find` already does — never a
  raw pixel coordinate, so a plan survives emulator resolution changes.
- **`screenMarker`** is the one substring that confirms a step's action
  actually landed on the expected next screen — this is the state-machine
  transition check; `run-plan` waits briefly for it before checking
  `assertions`.
- **`knownNonBug`** — defaults `false` on every step, meaning a missing
  assertion is always a real, flow-stopping divergence. Setting it `true`
  makes `run-plan` still check and report that step's assertions but never
  treat a mismatch as a divergence (reported `WARN` instead of `FAIL`/
  stopping the run). **This is exclusively a manual field.** Neither
  `flow-compiler` (at compile time) nor `flow-runner` (during local
  recovery) is permitted to set it to `true` on its own, ever, no matter how
  confident either is that a mismatch is a documented quirk rather than a
  bug — it only ever changes because a human explicitly asks for that one
  step to be marked (e.g. "mark step 4 of loginFlow as known non-bug"),
  applied via `plan_tool.sh patch`. The point of this asymmetry: a real
  regression must never be silently swallowed by the automation deciding
  for itself that it's fine — only a person looking at the actual doc/app
  gets to decide that.
- For a scrollable search (e.g. finding one vehicle card in a 94-item list),
  `action.type: "scroll-to"` additionally carries `direction`, `maxScrolls`,
  and `startHint` (how many scrolls the *previous* successful run needed
  before finding it) — `run-plan` fast-forwards through `startHint` blind
  scrolls before starting its normal find-and-check loop, so a list doesn't
  get rescanned from the top every run. Whoever consumes `run-plan`'s result
  should `patch` the step with the actual scroll count from this run so the
  hint stays accurate.
- Avoid natural-language prose in the plan — descriptions belong in the
  `.md` doc, which remains the authoritative human-readable source; the plan
  only needs what execution actually consumes. A short `notes` field is fine
  for a one-line hint to a future recovery pass (e.g. "content-desc merges
  with the balance label — tap left third of the bounds").

## Credential tokens

A step's `action.text`, `action.selector`, `screenMarker`, `assertions[]`,
or `waitFor.text` may contain `${mobileNumber}`, `${password}`, or
`${userCode}` instead of a literal value, wherever that value is really a
login credential (a phone number, password, or user code) rather than
fixed on-screen copy. For example, instead of hardcoding one specific phone
number into every place it appears in a step, write:

```json
{ "type": "type", "text": "${mobileNumber}" }
```

```json
"assertions": ["Enter the OTP sent to ${mobileNumber}"]
```

These tokens are pure stored text as far as `plan_tool.sh` is concerned —
`check`/`write`/`patch` never interpret or substitute them, exactly like any
other string in the plan. Substitution happens only at execution time,
inside `run_plan.py` (`appium_action.sh run-plan`'s executor): it resolves
`${mobileNumber}`/`${password}`/`${userCode}` by reading
`test-data/<environment>.properties` (environment from `run-plan`'s
`--environment` flag, default `Production`) and looking up either the named
test user (`--test-user <name>`) or, if that flag is omitted, a `default`
entry in that same file (if the file has one — see
`test-data/production.properties`/`test-data/staging.properties`). This is
what lets one compiled plan drive the login flow as any test user in either
environment without ever being recompiled — only `flow-compiler` writing the
token in the first place, and `run-plan` substituting it later, are aware
credentials are involved at all.

`run-plan` also accepts `--mobile <number>`/`--password <pass>`/`--user-code
<code>` to supply a value directly instead of looking it up from a
test-data file — each given flag overrides just that one field; if both
`--mobile` and `--password` are given, no test-data file is consulted at
all, so a genuinely ad-hoc credential doesn't need a file entry first.

## Scope

This skill never drives the live app and never decides *what* a plan should
say — it only validates and persists. Compiling (reading markdown +
screenshots, producing the plan JSON) is the `flow-compiler` agent's job;
executing a valid plan (`run-plan`) and handling a divergence with a scoped
recovery + `patch` call is the `flow-runner` agent's job.
