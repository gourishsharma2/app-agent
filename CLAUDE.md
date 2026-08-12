# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

This is **not a source-code project** — there is no `src/`, no build system, and no test framework. It's a doc-and-script-driven Appium automation harness for the **WheelsEye Operator** Android app (fleet/GPS/FASTag management for truck owners; package `com.wheelseyeoperator` in prod, `com.wheelseyeoperator.debug` for the sideloaded debug build used so far). Flows are documented as markdown + real screenshots and then driven live against an already-installed APK via Appium's HTTP API + `adb` — never via written test code (no Page Objects, no TestNG, no `src/main`/`src/test`). A prior Maven/`pom.xml` setup was removed as unused leftover from the project this repo was copied from.

The sibling **Book Truck** app (shipper-facing) is explicitly out of scope. `tests/demand/*` and empty `tests/account|payment|shipper/` scaffold dirs use booking/"demand" terminology from that other app and are very likely stale leftovers from the copy — see `summary/known-issues-summary.md` before adding new content under `tests/`.

## Commands

- `/list_flow` — table of every flow doc under `flow/*.md` and `tests/**/*.md`.
- `/run [flow_name] [apk_name]` — the main entry point: validates the flow doc and an APK under `apk/`, then launches the environment, drives the flow, reports pass/fail, and always writes an HTML report.
- `/sync_master [--merge] [--stash]` — brings this checkout up to date with `origin/master` via the one allowlisted script `.claude/scripts/sync_master.sh` (fetch + **fast-forward-only** update of local `master`; `--merge` then merges `master` into the current branch, `--stash` carries local edits across). It never rebases, resets, or force-pushes, and refuses rather than guessing when the tree is dirty or the branches have diverged. Use it instead of hand-typing `git checkout master && git fetch --all && git pull` — same allowlist reasoning as every other script here.
- Everything else is invoked through skills/agents, not ad-hoc commands (see below) — there is no lint/build/test command because there is no code to lint/build/test.

## Architecture: skills, agents, and the "one fixed script" rule

Three Claude Code skills, each backed by exactly one allowlisted shell entry point, do all the real work:

| Skill | Entry point | Purpose |
|---|---|---|
| `launchApplication` | `.claude/skills/launchApplication/scripts/launch_environment.sh <apk>` | Starts Appium + boots the emulator + installs the APK (idempotent, swaps builds via explicit uninstall). Teardown: `close_environment.sh`. |
| `driveFlow` | `.claude/skills/driveFlow/scripts/appium_action.sh <subcommand> ...` | Opens/closes the Appium session and does every tap/type/scroll/read/assert against the live screen — including `run-plan`, which deterministically drives an entire compiled plan (see below) in one call with no LLM reasoning inside it. |
| `generateReport` | `.claude/skills/generateReport/scripts/report_tool.sh {start\|end\|new-paths\|render-html}` | Timestamps a run and renders the standard HTML report via `html_report_generator.js`. |
| `compilePlan` | `.claude/skills/compilePlan/scripts/plan_tool.sh {check\|write\|patch}` | Hash-based cache validity checking, and atomic persistence, of compiled execution plans under `execution-plans/` — see "Compiled execution plans" below. |
| `apiCall` | `.claude/skills/apiCall/scripts/api_action.sh {doctor\|set-runtime\|call\|context\|context-set\|reset}` | Calls backend REST APIs, binds each response into the runtime context as flow variables (`api.running`), and backs a flow doc's `CALL_API`/`IF`/`ENDIF` commands. Config is markdown under `api/environments/<env>/` — see "API-driven execution" below. |

Corresponding agents wrap these skills with a narrower mandate: `env-manager` (environment lifecycle only), `flow-runner` (drives+verifies a flow via a compiled plan when one is valid, compiles one when it isn't, recovers locally on divergence — doesn't touch the environment), `flow-compiler` (turns a flow/test doc + its screenshots into a compiled plan — doesn't touch the live app), `report-writer` (formats/persists the report, doesn't drive or re-verify anything), `flow-documenter` (writes flow docs from screenshots, doesn't touch the live app), `app-researcher` (web research only, no repo/emulator/APK access).

### Compiled execution plans

Driving a flow the old way meant re-reading the whole `.md` doc and
re-viewing every screenshot on every single run, to re-derive the same tap
selectors and assertions derived last time. `flow-runner` now checks for a
**compiled execution plan** first (`.claude/skills/compilePlan/scripts/plan_tool.sh check <flowName>` —
pure hash comparison, no LLM cost) and only re-reads the doc/screenshots
(same cost as before) on a cache miss, immediately saving the result to
`execution-plans/<flowName>.plan.json` + `.meta.json`. Every run after that
replays the plan deterministically via `appium_action.sh run-plan` — no
markdown, no screenshots, no per-step reasoning — until the doc or a
screenshot it references actually changes (detected automatically via
content hashes in `.meta.json`, never a manual version number). A divergence
between the plan and the live app triggers a **local** recovery pass scoped
to the one mismatched step, which patches the plan
(`plan_tool.sh patch <flowName> <stepId>`) so the same divergence self-heals
instead of recurring on every future run. Full schema and rationale:
`.claude/skills/compilePlan/SKILL.md`. The `.md` docs under `flow/`/`tests/`
remain the human-readable source of truth; everything under
`execution-plans/` is a derived, regenerable build artifact — never
hand-edited.

### API-driven execution

A flow can call a REST API mid-run, expose the response as variables, and
branch on them. Four markdown commands (`CALL_API`, `SET_CONTEXT`, `IF`/`ELSE`/
`ENDIF`) compile — like everything else — into the plan: `CALL_API` becomes a
`call-api` action, and an `IF ... ENDIF` block becomes a `when` predicate on
each step inside it. The runtime still parses no markdown and makes no model
call; predicates are evaluated in code, so conditional flows keep the zero-LLM
guarantee.

The response's `{message, success, serverTime, data}` envelope is unwrapped on
binding, so `data.running` reads as **`api.running`**. A false predicate marks
the step `SKIP` with its reason recorded (a run with skips is still `PASS`); a
condition path that isn't in the context is a **failure, not a skip**,
deliberately — a typo that silently skipped its step would produce a green run
that validated nothing.

Per-environment configuration is markdown under
`api/environments/<stage|production>/{base_url,headers,paths}.md`, with one
contract doc per endpoint under `api/contracts/`. Adding an endpoint means
adding one line to `paths.md` — no script change. Runtime values (`token`,
`userCode`, `deviceName`, `deviceId`, `androidVersion`) arrive as `key=value`
pairs on the `/run` line, are never committed, and are redacted from every log
and report. Full detail: `.claude/skills/apiCall/SKILL.md` and `api/README.md`.

**A raw `curl` a user pastes while authoring/updating a flow (`/create_flow`,
`/update_flow`) never goes into the flow doc itself** — route it through this
same API layer instead, exactly as `flow/gpsListingFlow.md` /
`tests/VerifyGpsListing.md` already do for `getAllFilterCount` and
`vehiclesStatic`: add `key = /path` to `paths.md` (both environments), any
new headers to `headers.md`, the curl itself to `api/curl-reference.md`, and
a response-shape doc to `api/contracts/<key>.md` — then reference it from the
flow doc only as `CALL_API <key>` (plus `IF api.x ... ENDIF` where needed). A
flow doc stays free of curl text, URLs, and header names no matter what was
pasted into the authoring conversation.

**The one hard rule that matters most in this repo:** never hand-roll a raw `curl`/`adb`/`node` command for something these scripts already do, and issue every script call as its own single plain command — never wrapped in `$(...)`, `&&`, or chained with anything else. `.claude/settings.json` allowlists these scripts by their *exact literal path*, is committed and shared across everyone using this repo, and a wrapped/combined/hand-rolled invocation breaks that match and reintroduces a permission prompt for every future session, for every user. If a new capability is needed, add a subcommand to the relevant script rather than reaching for a one-off shell command. `.claude/settings.local.json` is per-machine and uncommitted — never rely on it for anything that needs to work for a teammate or a fresh session.

## Repo layout

- `application/*.md` — architecture/overview/navigation/login/environments/known-behaviors/test-data reference docs about the app itself (not automation mechanics).
- `flow/*.md` — per-screen or short flow docs (e.g. `loginFlow.md`, `homePage.md`, `gpsListingFlow.md`), each step paired with a screenshot under `screenshots or figma Links/<name>/Step N.png` and a `contains "..."` **Assertions** list.
- `tests/*.md` / `tests/<category>/*.md` — end-to-end business flows composed from one or more `flow/*.md` docs (e.g. `tests/VerifyGpsListing.md`).
- `summary/*.md` — hand-maintained rollups (application-summary, flows-summary, screens-summary, reusable-summary, known-issues-summary, automation-status). These can go stale — `/list_flow` and `/run` always discover flows from the filesystem directly, never from these summaries.
- `execution/report/` — generated HTML run reports (`<flow_name>-<yyyyMMdd-HHmmss>.html`); `execution/logs/` — optional raw evidence (full UI-source dumps) per run.
- `execution-plans/` — compiled execution plans (`<flow_name>.plan.json` + `.meta.json`), one pair per flow/test doc — see "Compiled execution plans" above. Generated by `flow-compiler`/`flow-runner`, never hand-edited; safe to delete (the next run just recompiles).
- `api/` — the API layer: `environments/<env>/{base_url,headers,paths}.md` (per-environment config, markdown-only, loaded dynamically) and `contracts/<endpoint>.md` (response shape, variables produced, UI mapping). Adding an endpoint touches only `paths.md`.
- `apk/` — where `/run` expects build files to live (not present until builds are added).
- `config.properties` — automation-harness config only (`platform`, `appiumServerUrl`) — **not** the same as the app's own in-app Staging/Production toggle on the login screen, which controls which backend/data the app talks to.

## Working conventions specific to this repo

- **Flow docs are the source of truth for the UI.** The app is Jetpack Compose; elements are identified mostly by `content-desc` (rarely `resource-id`), and Compose often merges several elements into one accessibility node — tap where the element visually appears within that merged region, not just its center.
- **Screenshots are for authoring, never for verification.** They're read once, by `flow-documenter`/`flow-compiler`, to derive a doc's steps or a plan's selectors/assertions — every actual check, at compile time and at run time, is done against the live UI's accessibility XML (`source`/`find`/`contains`/`assert-all`), never against a screenshot's rendered pixels or text. A screenshot's visible text is not ground truth for whether an assertion currently holds; only a live check against the running app is. This already holds throughout `driveFlow`, `flow-compiler`, and `flow-runner` — this bullet just states it once, at the top level, instead of leaving it implicit across three separate files.
- **Every run gets an HTML report, unconditionally** — pass, fail, or stopped partway through. This is not opt-in and not something the user needs to ask for separately.
- **Reports must use real data only** — token counts, timestamps, and build metadata come from `report_tool.sh end` / `.last_install_state`, never invented to fill an `N/A`.
- Known non-bugs to check before treating something as a failure: the post-login "Unauthenticated App Detected" dialog (expected for the sideloaded debug build) and notification-permission prompt; masked/blurred FASTag/diesel balances on vehicle cards (assert on labels/links, not the numeric values); "Non Wheelseye GPS" vehicles lacking live tracking. Full detail in `application/known-behaviors.md`.
