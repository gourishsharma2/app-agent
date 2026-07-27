# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

This is **not a source-code project** — there is no `src/`, no build system, and no test framework. It's a doc-and-script-driven Appium automation harness for the **WheelsEye Operator** Android app (fleet/GPS/FASTag management for truck owners; package `com.wheelseyeoperator` in prod, `com.wheelseyeoperator.debug` for the sideloaded debug build used so far). Flows are documented as markdown + real screenshots and then driven live against an already-installed APK via Appium's HTTP API + `adb` — never via written test code (no Page Objects, no TestNG, no `src/main`/`src/test`). A prior Maven/`pom.xml` setup was removed as unused leftover from the project this repo was copied from.

The sibling **Book Truck** app (shipper-facing) is explicitly out of scope. `tests/demand/*` and empty `tests/account|payment|shipper/` scaffold dirs use booking/"demand" terminology from that other app and are very likely stale leftovers from the copy — see `summary/known-issues-summary.md` before adding new content under `tests/`.

## Commands

- `/list_flow` — table of every flow doc under `flow/*.md` and `tests/**/*.md`.
- `/run [flow_name] [apk_name]` — the main entry point: validates the flow doc and an APK under `apk/`, then launches the environment, drives the flow, reports pass/fail, and always writes an HTML report.
- Everything else is invoked through skills/agents, not ad-hoc commands (see below) — there is no lint/build/test command because there is no code to lint/build/test.

## Architecture: skills, agents, and the "one fixed script" rule

Three Claude Code skills, each backed by exactly one allowlisted shell entry point, do all the real work:

| Skill | Entry point | Purpose |
|---|---|---|
| `launchApplication` | `.claude/skills/launchApplication/scripts/launch_environment.sh <apk>` | Starts Appium + boots the emulator + installs the APK (idempotent, swaps builds via explicit uninstall). Teardown: `close_environment.sh`. |
| `driveFlow` | `.claude/skills/driveFlow/scripts/appium_action.sh <subcommand> ...` | Opens/closes the Appium session and does every tap/type/scroll/read/assert against the live screen. |
| `generateReport` | `.claude/skills/generateReport/scripts/report_tool.sh {start\|end\|new-paths\|render-html}` | Timestamps a run and renders the standard HTML report via `html_report_generator.js`. |

Corresponding agents wrap these skills with a narrower mandate: `env-manager` (environment lifecycle only), `flow-runner` (drives+verifies a flow, doesn't touch the environment), `report-writer` (formats/persists the report, doesn't drive or re-verify anything), `flow-documenter` (writes flow docs from screenshots, doesn't touch the live app), `app-researcher` (web research only, no repo/emulator/APK access).

**The one hard rule that matters most in this repo:** never hand-roll a raw `curl`/`adb`/`node` command for something these scripts already do, and issue every script call as its own single plain command — never wrapped in `$(...)`, `&&`, or chained with anything else. `.claude/settings.json` allowlists these scripts by their *exact literal path*, is committed and shared across everyone using this repo, and a wrapped/combined/hand-rolled invocation breaks that match and reintroduces a permission prompt for every future session, for every user. If a new capability is needed, add a subcommand to the relevant script rather than reaching for a one-off shell command. `.claude/settings.local.json` is per-machine and uncommitted — never rely on it for anything that needs to work for a teammate or a fresh session.

## Repo layout

- `application/*.md` — architecture/overview/navigation/login/environments/known-behaviors/test-data reference docs about the app itself (not automation mechanics).
- `flow/*.md` — per-screen or short flow docs (e.g. `loginFlow.md`, `homePage.md`, `gpsListingFlow.md`), each step paired with a screenshot under `screenshots or figma Links/<name>/Step N.png` and a `contains "..."` **Assertions** list.
- `tests/*.md` / `tests/<category>/*.md` — end-to-end business flows composed from one or more `flow/*.md` docs (e.g. `tests/VerifyGpsListing.md`).
- `summary/*.md` — hand-maintained rollups (application-summary, flows-summary, screens-summary, reusable-summary, known-issues-summary, automation-status). These can go stale — `/list_flow` and `/run` always discover flows from the filesystem directly, never from these summaries.
- `execution/report/` — generated HTML run reports (`<flow_name>-<yyyyMMdd-HHmmss>.html`); `execution/logs/` — optional raw evidence (full UI-source dumps) per run.
- `apk/` — where `/run` expects build files to live (not present until builds are added).
- `config.properties` — automation-harness config only (`platform`, `appiumServerUrl`) — **not** the same as the app's own in-app Staging/Production toggle on the login screen, which controls which backend/data the app talks to.

## Working conventions specific to this repo

- **Flow docs are the source of truth for the UI.** The app is Jetpack Compose; elements are identified mostly by `content-desc` (rarely `resource-id`), and Compose often merges several elements into one accessibility node — tap where the element visually appears within that merged region, not just its center.
- **Every run gets an HTML report, unconditionally** — pass, fail, or stopped partway through. This is not opt-in and not something the user needs to ask for separately.
- **Reports must use real data only** — token counts, timestamps, and build metadata come from `report_tool.sh end` / `.last_install_state`, never invented to fill an `N/A`.
- Known non-bugs to check before treating something as a failure: the post-login "Unauthenticated App Detected" dialog (expected for the sideloaded debug build) and notification-permission prompt; masked/blurred FASTag/diesel balances on vehicle cards (assert on labels/links, not the numeric values); "Non Wheelseye GPS" vehicles lacking live tracking. Full detail in `application/known-behaviors.md`.
