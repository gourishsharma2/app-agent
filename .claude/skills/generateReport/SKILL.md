---
name: generateReport
description: Generates and saves the standardized Markdown run report for a flow/test execution into execution/report/, creating the directory if needed. Used automatically after every /run execution (and by driveFlow/report-writer directly) — not opt-in. Provides the one shared naming/timestamp/duration script so this logic isn't re-derived per command.
---

# generateReport

Produces one Markdown run report per execution and saves it under
`execution/report/`, creating that directory the first time it's needed.
This is the single, reusable source of truth for report **naming**,
**timestamps/duration**, and **format** — every command or agent that
finishes a flow/test run (the `/run` command, `flow-runner`,
`report-writer`, and any future test runner) should produce its report
through this skill rather than inventing its own filename convention.

## Reports are automatic, not opt-in

Every execution of a flow or test doc (via `/run`, `driveFlow`, or
`flow-runner`) must end with a saved report, **regardless of outcome**
(pass, fail, or execution stopped partway through on a failure). Nothing
about triggering a report is conditional on the user separately asking for
one — that was the old convention and no longer applies.

## Script usage

One fixed script, `.claude/skills/generateReport/scripts/report_tool.sh`,
handles the mechanical parts. Issue each call as its own single plain
command (same reasoning as `driveFlow`'s `appium_action.sh` — a stable,
allowlistable path):

```bash
# Call once, right before driving the flow starts (session open / first step).
.claude/skills/generateReport/scripts/report_tool.sh start
# -> prints the run-start timestamp, and remembers it internally.

# Call once, right after the run ends (session closed / last step / failure).
.claude/skills/generateReport/scripts/report_tool.sh end
# -> prints:
#      START=<run start timestamp>
#      END=<run end timestamp>
#      DURATION=<e.g. "2m 13s" or "45s">

# Call once you're ready to write the report file itself.
.claude/skills/generateReport/scripts/report_tool.sh new-path <flow_name>
# -> ensures execution/report/ exists, prints a unique path, e.g.:
#      execution/report/homePage-20260724-184512.md
```

`<flow_name>` should be the flow/test doc's filename without `.md` (e.g.
`homePage`, `VerifyGpsListing`) — matching how `/list_flow` and `/run` name
flows. Filenames include seconds (`yyyyMMdd-HHmmss`), so repeated runs never
collide or overwrite each other.

Content formatting (the metadata block, the per-step table) is **not** done
by this script — composing that text is an LLM task. Once you have the path
from `new-path`, write the report content to that exact path with the
`Write` tool.

## Getting build/device metadata

APK filename, package name, versionCode, versionName, and the device serial
come from `launchApplication`'s install step, persisted at
`.claude/skills/launchApplication/.last_install_state` (key=value lines:
`APK_PATH`, `APK_FILENAME`, `PACKAGE_NAME`, `VERSION_CODE`, `VERSION_NAME`,
`DEVICE_SERIAL`, `INSTALLED_AT`). Read that file rather than re-deriving
this info with a fresh `aapt`/`adb` call.

## Report format

```md
# <Flow Name> — Run Report

- **Flow doc:** `<path_to_flow_markdown>`
- **Precondition:** `<precondition if available, otherwise "None">`
- **Build/APK:** `<apk filename>` (versionCode `<versionCode>`, versionName `<versionName>`)
- **Package:** `<package name>`
- **Platform:** `android` (device `<device_id>`)
- **Run start:** `<start timestamp>`
- **Run end:** `<end timestamp>`
- **Total execution time:** `<duration>`
- **Overall Result:** ✅ Pass / ❌ Fail
- **Token usage:** `<total tokens>` (input `<input>`, output `<output>`, cache write `<cache_write>`, cache read `<cache_read>`)

| Step | Assertion | Result | Notes |
|------|-----------|--------|-------|
| 1: Home page | `contains "Loading Location"` | ✅ Pass | |
| 2: ... | ... | ❌ Fail | Assertion failed |
```

Notes on filling this in:

- **Flow Name** (title) — the doc's `# <Title>` heading text if it has one,
  else the filename.
- **Flow doc** — the relative path that was actually driven (e.g.
  `flow/homePage.md`, `tests/VerifyGpsListing.md`).
- **Precondition** — copy it from the doc's own `## Precondition` section if
  present; write literally `None` if the doc has no precondition section.
- **Build/APK / Package / Platform / device** — from
  `.last_install_state` as described above.
- **Token usage** — only include real numbers if the caller actually has
  them; if none are available in this session, write
  `Token usage: not available in this session` instead of guessing.
- **Step table** — one row per assertion actually checked, in the order
  checked, using the step numbering/title from the flow/test doc. Include
  every step that was executed, even the ones after which execution stopped
  due to a failure. Use `⚠️ Skipped` for steps never reached because an
  earlier step failed.

## Failure handling

If the run fails partway through:

- Still call `report_tool.sh end` and `new-path`, and still write the file —
  a failed run's report is exactly as important as a passing one.
- Record the failing step's row with `❌ Fail` and put the exact failure
  reason (e.g. the specific `contains` check that didn't match) in **Notes**.
- Mark **Overall Result** as `❌ Fail`.
- Any step never reached gets `⚠️ Skipped` rather than being omitted from
  the table.

## Scope

This skill only formats and persists a report from results it's given (or
that the caller gathers via `driveFlow`) — it never drives the app or
re-verifies assertions itself.
