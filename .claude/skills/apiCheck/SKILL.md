---
name: apiCheck
description: Calls the WheelsEye Operator backend APIs, validates the response (status code, headers, body), and compares the values the API returned against what the app is actually rendering on screen — using one fixed helper script instead of ad-hoc curl one-liners. Use whenever a flow/test doc has an "API Validations" section, or when asked to verify that displayed data matches the backend.
---

# apiCheck

Verifies that what the app **shows** matches what the backend **returned**.

This is the missing half of `driveFlow`: `contains "Running (2)"` proves the
app rendered *something*, but not that it rendered the *right* thing. A
`contains` assertion on a hardcoded count passes happily when the backend
says 7 and the UI says 2 — both are "in the doc". `apiCheck` closes that gap
by making the expected value come from the API instead of from a doc written
weeks ago.

## Why this exists (same reasoning as driveFlow)

Hand-rolling `curl https://wheelseye.com/... -H "token: eyJ..."` per check
means the command text differs every run (different tokens, ids, bodies), so
no permission allowlist rule can match it and **every run re-prompts, for
every teammate**. One fixed path — `.claude/skills/apiCheck/scripts/api_action.sh`
— is allowlisted once in `.claude/settings.json` and never prompts again.

That constraint also explains the shape of the CLI. Every call must be a
plain `api_action.sh <cmd> ...` with no `$(...)` capture (capturing breaks the
allowlist match), so a response can't live in a shell variable: **the request
is stored to a state file and the assertion subcommands read it back**. Same
pattern as `appium_action.sh`'s session id.

If a new capability is needed, add a subcommand to `api_action.sh` (or to its
engine, `scripts/api_json.py`) — never reach for a raw `curl`.

## The validation flow

```bash
# 1. Authenticate once per run (see "Getting a token" below).
.claude/skills/apiCheck/scripts/api_action.sh token-from-device com.wheelseyeoperator.debug

# 2. Call the API.
.claude/skills/apiCheck/scripts/api_action.sh get vehicleFilterCount

# 3. Validate the response itself — status, headers, body.
.claude/skills/apiCheck/scripts/api_action.sh assert-status 200
.claude/skills/apiCheck/scripts/api_action.sh assert-header content-type application/json
.claude/skills/apiCheck/scripts/api_action.sh assert-json success true
.claude/skills/apiCheck/scripts/api_action.sh assert-type data.running number

# 4. Drive the app to the screen under test (driveFlow's job — appium_action.sh).

# 5. Compare what the API said against what the screen shows.
.claude/skills/apiCheck/scripts/api_action.sh compare-ui data.running --normalize number --in "Running"

# 6. Hand the recorded results to the report.
.claude/skills/apiCheck/scripts/api_action.sh results --json
```

Steps 2–3 and 5 can be interleaved with UI steps freely — the stored response
survives until the next request or a `reset`.

## Subcommands

```bash
# setup / discovery
api_action.sh doctor                        # resolved base URL, headers, endpoints, auth state
api_action.sh set-token <token>             # store a token you already have
api_action.sh login                         # log in via apiLoginPath, store the token
api_action.sh token-from-device <pkg> [prefsFile] [key]   # lift the app's own token off the emulator
api_action.sh device-prefs <pkg> [file]     # list/dump the app's SharedPreferences
api_action.sh sniff [pkg] [lines]           # distinct API URLs the app has hit (from logcat)

# calling
api_action.sh get <endpointKey|/path|url> [--no-auth] [--header "Name: Value"]
api_action.sh post <endpointKey|/path|url> '<json>' [--no-auth]
api_action.sh request <METHOD> <endpointKey|/path|url> ['<json>']

# validating the response
api_action.sh last                          # method/url/status/elapsed/size
api_action.sh body [--pretty] [--full]
api_action.sh headers
api_action.sh json <jsonPath>               # print value(s)
api_action.sh assert-status <code>
api_action.sh assert-header <name> <substring>
api_action.sh assert-json <jsonPath> <expected> [--normalize raw|text|number|plate|digits]
api_action.sh assert-type <jsonPath> <string|number|boolean|array|object|null>
api_action.sh assert-count <jsonPath> <n|>n|>=n|<n|<=n>
api_action.sh assert-fields <arrayPath> <field1> [field2 ...]

# comparing against the live screen
api_action.sh compare-ui <jsonPath> [--normalize m] [--in anchor] [--label name]
api_action.sh compare-ui-list <arrayPath> <field> [--limit n] [--normalize m] [--in anchor]

# reporting
api_action.sh results [--json]              # every check recorded this run
api_action.sh reset                         # clear stored response + recorded checks
```

Every `assert-*` and `compare-ui*` call exits 0 on pass / 1 on fail **and**
appends its result to `.checks.json`, so `results --json` at the end of a run
feeds the HTML report real data instead of a retyped summary.

## JSON paths

```
data.running                      plain field
data.vehicles[0].vehicleNumber    list index
data.vehicles[*].vehicleNumber    every element of a list
data.*.speed                      every value of an id-keyed map
data.3341520.speed                one entry of an id-keyed map
sum(data.running,data.stoppage)   derived value
len(data)                         size of a list/map/string
```

`sum()` matters more than it looks: the Vehicles screen's **All (N)** chip is
not a field the backend returns — it's `running + stoppage + noInfo` from
`getAllFilterCount`. Deriving it in the path keeps that arithmetic in the
assertion where it's visible, rather than hardcoding a number that silently
rots.

## Normalizers — how a value may differ between API and UI

The API says `86.0`; the card says `86 kmph`. The API says `HR36AP7846`; the
card says `HR 36 AP 7846`. A raw string comparison fails on both, so pick the
normalizer that matches how the app formats that field:

| `--normalize` | Matches when | Use for |
|---|---|---|
| `raw` | exact substring | ids, timestamps already formatted by the backend (`Today, 11:38 AM`) |
| `text` | case/whitespace-insensitive substring | addresses, statuses (`On` vs `Ignition ON`) — the default |
| `number` | numerically equal, ignoring `₹ , kmph %` | balances, speeds, distances, counts |
| `plate` | alphanumerics only, uppercased | vehicle registration numbers |
| `digits` | digits only | phone numbers, ids rendered with separators |

Comparison runs against the parsed `text`/`content-desc` attributes of the
hierarchy, **not** the raw XML — so `1,848.00` is compared as a whole field
value, never as characters that happen to sit adjacent in the markup.

## Always anchor with `--in` when the value isn't unique

This is the one mistake that produces a green run that proves nothing. The
Vehicles screen shows `Running (2)` and `Stopped (2)` at the same time, so:

```bash
# WRONG — passes by matching the Running chip. Green, and meaningless.
api_action.sh compare-ui data.stoppage --normalize number

# RIGHT — only elements containing "Stopped" are considered.
api_action.sh compare-ui data.stoppage --normalize number --in "Stopped"
```

If the anchor itself isn't on screen, the check fails with "anchor not found"
rather than quietly scanning the whole page. Anchor any numeric comparison,
and any comparison on a screen showing several cards.

## Compose only renders what's visible

A `LazyColumn` keeps roughly the visible window in the accessibility
hierarchy. The fleet has ~85 vehicles; the screen holds three or four. So:

- **Don't** compare a whole payload against one screen — `compare-ui-list`
  without `--limit` will fail by design, not because the app is wrong.
- **Do** compare aggregate values (counts, totals) that are visible at once.
- **Do** `appium_action.sh scroll-to "<plate>"` first, then `compare-ui` the
  fields of that one vehicle.
- **Do** use `compare-ui-list ... --limit 3` to sample the top of a list.

## Getting a token

Three options, in order of preference:

1. **`token-from-device <pkg>`** — lifts the token the app is *already* using
   out of its SharedPreferences via `adb run-as` (works because the automation
   build is debuggable). Best option: the API and the UI are then guaranteed
   to be the same session and the same account, which is the whole point of
   the comparison.
2. **`set-token <token>`** — paste a token captured elsewhere.
3. **`login`** — calls `/shield/admin/v3/login` with `WE_API_MOBILE` /
   `WE_API_PASSWORD` from the environment. Use sparingly: the endpoint is
   rate-limited and returns
   `401 "You have reached maximum login attempts, wait till 15 minutes"`
   after a handful of tries — enough failed runs will lock the shared test
   account out for everyone.

Tokens are written to `.claude/skills/apiCheck/.auth_state` (chmod 600,
gitignored) and never printed by `doctor`. Credentials are never read from a
committed file.

## Configuration

| Where | What |
|---|---|
| `config.properties` | `apiEnv`, `apiBaseUrl.<env>`, `apiAuthHeader`, `apiTimeoutSeconds`, login path/body/token-path |
| `api/headers.properties` | the ~11 static headers the app sends on every call (`Name: Value` per line) |
| `api/endpoints.properties` | endpoint key → path, so docs reference `vehicleFilterCount` not a URL |
| `api/*.md` | one contract doc per endpoint: expected response + **UI Mapping** table |

`apiEnv` must match the app's in-app Staging/Production toggle. If they
differ, the comparison is checking two different datasets and will fail for
entirely the wrong reason — check this first when a comparison fails
inexplicably.

## Discovering endpoints that aren't documented yet

```bash
api_action.sh sniff com.wheelseyeoperator.debug
```

Prints the distinct URLs the running app has hit, from its own logcat output.
Empty output usually means the app's HTTP client doesn't log request URLs in
this build — capture with an HTTPS proxy instead (see `api/README.md`).

## Scope

This skill calls APIs, validates responses, and compares them against the
current screen. It does **not** tap, type, or scroll — that's `driveFlow`.
It does not launch or install anything — that's `launchApplication`. It does
not write the report — it hands `results --json` to `report-writer`.
