---
name: apiCall
description: Calls the WheelsEye Operator backend REST APIs, binds each response into a runtime context as flow variables (api.running, api.stoppage, ...), and lets a flow decide what to execute based on those values. Configuration is markdown under api/environments/<env>/; everything runs through one fixed helper script instead of ad-hoc curl. Use whenever a flow doc contains CALL_API, or when asked to drive UI execution from API data.
---

# apiCall

Turns a backend response into **flow variables**, so a flow can decide what to
validate instead of asserting numbers that were true the day a screenshot was
taken.

`contains "Running (2)"` passes when the backend says 7 and the UI says 2 —
both are "in the doc". Worse, it fails identically whether the app is broken or
the fleet simply moved. Sourcing the expected value from the API separates
those two questions, and a runtime context lets the *flow shape itself* respond:
if nothing is running, skip the Running validation rather than fail it.

## Why one fixed script

`.claude/settings.json` allowlists `scripts/api_action.sh` by exact literal
path. A hand-rolled `curl ... -H "token: eyJ..."` differs on every run, so no
allowlist rule can match and every run re-prompts — for every teammate, in
every session. Issue each call as its own plain command: **never** wrapped in
`$(...)`, never chained with `&&`.

That constraint also shapes the design. Because a response can't be captured
into a shell variable, it is bound into `.context.json` and read back by the
next call — the same pattern `appium_action.sh` uses for its session id.

If a new capability is needed, add a subcommand to `api_action.sh` (or its
engine, `api_cli.py`) rather than reaching for `curl`.

## Configuration is markdown

```
api/environments/<env>/
    base_url.md    environment name, base URL, timeout, retry count
    headers.md     static headers + runtime header declarations
    paths.md       path key → path
api/contracts/<key>.md   response shape, variables produced, UI mapping
```

Only fenced blocks are parsed; prose is documentation and can never break the
loader. See `api/README.md` for the format.

**Adding an endpoint requires no code change**: add `key = /path` to
`paths.md`, optionally write a contract doc, then `CALL_API <key>`.

## Subcommands

```bash
# What is actually resolved for an environment — run this first when a call misbehaves.
.claude/skills/apiCall/scripts/api_action.sh doctor production

# Resolve credentials for a user code and store a session token (see "Authentication").
.claude/skills/apiCall/scripts/api_action.sh auth production WE25622

# Store the runtime inputs (also passed automatically by /run).
.claude/skills/apiCall/scripts/api_action.sh set-runtime token=xxxx userCode=WE12345 deviceName=Samsung deviceId=xxxx androidVersion=16

# Call an endpoint and bind its response.
.claude/skills/apiCall/scripts/api_action.sh call production getAllFilterCount

# An endpoint that PRODUCES credentials sends static headers only.
.claude/skills/apiCall/scripts/api_action.sh call production login --method POST --no-auth --body '{...}'

# Inspect the context (secrets always redacted).
.claude/skills/apiCall/scripts/api_action.sh context
.claude/skills/apiCall/scripts/api_action.sh context api.running

# Set a value by hand / clear everything.
.claude/skills/apiCall/scripts/api_action.sh context-set flow.threshold 5
.claude/skills/apiCall/scripts/api_action.sh reset
```

`doctor` prints `MISSING_RUNTIME_INPUTS=` and `HEADERS_BLOCKED_BY=` when an
input hasn't been supplied — that is the fast answer to "why did I get a 401".

## Authentication

One command turns a user code into a working session:

```bash
.claude/skills/apiCall/scripts/api_action.sh auth production WE25622
```

```
userCode ──▶ fetchUserDetail ──▶ phoneNumber + password ──▶ login ──▶ accessToken
                                                                          │
                                                            runtime.token ◀┘
```

It stores `runtime.token` and `runtime.userCode`, so every later `call` and
every `call-api` plan step is authenticated. **Nothing secret is printed** — the
output is the user code, the login status, and the token's length.

The chain is *declared*, not coded: `api/environments/<env>/auth.md` names the
two path keys, the JSON paths to the username/password/token, and the login body
template. A different backend's auth flow is a config change.

Three details that matter:

- **Paths in `auth.md` are paths into the raw response**, exactly as they appear
  in a `curl` output (`data.accessToken`, `data.0.phoneNumber`). They are read
  via `_raw`, bypassing the envelope unwrapping that produces flow variables.
  `fetchUserDetail` returns `data` as an *array*, which is why it needs `data.0.`
  while `getAllFilterCount`'s object `data` unwraps to `api.running`.
- **`user-code` comes from the login response**, not from the argument or a
  committed default. A `user-code` header disagreeing with the token's account
  would silently compare two different fleets, and the failure would look like
  an app bug.
- **Login is never retried** (`retries=0`), regardless of `retry_count`. It is
  rate-limited: enough attempts return `401 "You have reached maximum login
  attempts, wait till 15 minutes"` and lock the account out for everyone. Note
  the live login response includes `attemptLeft` — worth checking when auth
  starts failing.

## The runtime context

| Namespace | Holds |
|---|---|
| `runtime.*` | inputs from the `/run` line (`token`, `userCode`, `deviceName`, `deviceId`, `androidVersion`) |
| `env.*` | resolved environment config (`name`, `base_url`, `timeout`) |
| `api.*` | the last response bound to that namespace, envelope unwrapped |
| `flow.*` | values set by `SET_CONTEXT` |
| `mobileNumber` / `password` / `userCode` | credentials, also mirrored under `runtime.*` |

Binding unwraps the backend's `{message, success, serverTime, data}` envelope,
so `data.running` becomes **`api.running`**. The untouched response stays at
`api._raw`, with `api._status` and `api._elapsedMs` alongside. A second call can
use `--bind counts` to keep both responses live at once.

Secrets (`token`, `password`, `mobileNumber`, ...) are redacted in every dump,
log line and report. `.context.json` is `chmod 600` and gitignored.

## Flow markdown syntax

A flow doc drives all of this with four commands. They are compiled once into
the plan by `flow-compiler`, exactly like every other step — the runtime never
parses markdown.

```markdown
## Step 3: Read the filter counts

CALL_API getAllFilterCount

**Assertions:**
- `api.success == true`

## Step 4: Validate visible vehicle states

IF api.running > 0
VALIDATE RunningVehicleVisible
ENDIF

IF api.stoppage > 0
VALIDATE StoppedVehicleVisible
ENDIF

IF api.noInfo > 0
VALIDATE NoInfoVehicleVisible
ENDIF
```

| Command | Compiles to |
|---|---|
| `CALL_API <key>` | `{"type": "call-api", "endpoint": "<key>", "bind": "api"}` |
| `SET_CONTEXT <path> <value>` | `{"type": "set-context", "key": "<path>", "value": <value>}` |
| `IF <path> <op> <value>` … `ENDIF` | a `when` predicate on each step inside the block |
| `ELSE` | the same predicate with the operator negated |

### Why `IF/ENDIF` becomes a per-step predicate rather than block markers

The plan is a flat array of independently addressable steps, and two existing
features depend on that: `run-plan --from-step N` (recovery resumes mid-flow)
and `plan_tool.sh patch <stepId>` (single-step self-healing). Block delimiters
inside the plan would allow resuming *inside an unmatched `IF`*, silently
corrupting control flow. A predicate attached to each step keeps every step
self-contained, so both features keep working untouched.

So markdown keeps the readable imperative form; the plan stays declarative:

```json
{ "id": 4, "title": "Running vehicles visible",
  "when": { "path": "api.running", "op": ">", "value": 0 },
  "assertions": ["Running"] }
```

## Operators

`>` `>=` `<` `<=` `==` `!=` `exists` `not-exists`

Numeric comparison when both sides parse as numbers; `==`/`!=` fall back to
string comparison. Booleans deliberately do **not** compare as `1`/`0` — use
`== true`.

### A missing path fails the run; it does not skip

`IF api.runing > 0` (typo) raises `condition-path-missing` and stops the flow.
Skipping instead would produce a green run that validated nothing — the exact
failure mode this repo's docs warn about. When absence is genuinely what's
being tested, say so explicitly with `exists` / `not-exists`.

## Skips are reported, never silent

```
run-plan: SKIP step 5 — condition false: api.noInfo = 0 > 0 -> False
```

Each skipped step lands in `PLAN_RESULT_JSON` with `status: "SKIP"` and its
`skipReason`, so the HTML report shows what was skipped and why rather than
quietly omitting it. A run with skips is still `PASS`.

## Error handling

| Situation | Behavior |
|---|---|
| Unknown environment | fails listing the environments that do exist |
| Missing/unterminated markdown config | fails naming the file (and the line, for an unclosed fence) |
| Unknown path key | fails listing the defined keys and the file to add it to |
| Missing runtime input | fails **before sending**, naming the input and the header needing it — never sends an empty token |
| 401 / 403 | returned as data with an actionable note; a `call-api` step diverges rather than continuing on bad auth |
| 5xx / timeout / network | retried per `retry_count`, then fails with the cause |
| 4xx | never retried — it is a definitive answer, and retrying login burns the shared account's rate limit |
| Malformed JSON | not fatal at transport level; `api._raw` is null and the note reports what came back instead |
| Runtime header set to a literal | rejected at load time, so a token can't be committed by accident |

## Scope

This skill calls APIs, binds responses, and evaluates conditions. It does not
tap, type or scroll — that is `driveFlow`. It does not launch or install
anything — that is `launchApplication`. It does not write reports — the results
land in `PLAN_RESULT_JSON` for `report-writer`.

## Verification status

**Production is verified live** (3 Aug 2026). The full chain ran end to end:
`auth production WE25622` → 200, token stored → `call production
getAllFilterCount` → `200 {"running":0,"stoppage":2,"noInfo":79}` → those values
drove the three `IF` blocks, skipping the Running validation and executing the
other two, with the run still `PASS`. `auth production WE7713033` also
succeeded (that account returns `0/0/0`, so all three blocks skip).

**Stage is not verified.** Its `base_url` is a placeholder, `fetchUserDetail`
still points at the production UMS host, and no `auth stage` call has ever
succeeded. See `api/environments/stage/auth.md`.

**No `call-api` step has run inside a live `/run` yet** — the engine is proven
against real API data, but driving it from a compiled plan on a booted emulator
still needs a flow doc with `CALL_API` in it and a recompile (schema 2).
