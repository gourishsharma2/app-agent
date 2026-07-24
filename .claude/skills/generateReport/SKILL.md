---
name: generateReport
description: Generates and saves the standardized Markdown AND HTML run reports for a flow/test execution into execution/report/, creating the directory if needed. Used automatically after every /run execution (and by driveFlow/report-writer directly) — not opt-in. Provides the one shared naming/timestamp/duration script (and the HtmlReportGenerator) so this logic isn't re-derived per command.
---

# generateReport

Produces one Markdown run report **and** one HTML run report per execution,
both from the same run data, and saves them under `execution/report/`,
creating that directory the first time it's needed. This is the single,
reusable source of truth for report **naming**, **timestamps/duration**, and
**format** — every command or agent that finishes a flow/test run (the
`/run` command, `flow-runner`, `report-writer`, and any future test runner)
should produce its reports through this skill rather than inventing its own
filename convention or HTML markup.

Both formats are mandatory and automatic — never write only one. The
Markdown format and its template below are unchanged; the HTML format is
additive.

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

# Call once you're ready to write the report files (get BOTH paths at once,
# sharing one timestamp so the .md and .html of one run are easy to pair up).
.claude/skills/generateReport/scripts/report_tool.sh new-paths <flow_name>
# -> ensures execution/report/ exists, prints:
#      MD_PATH=execution/report/homePage-20260724-184512.md
#      HTML_PATH=execution/report/homePage-20260724-184512.html
```

`<flow_name>` should be the flow/test doc's filename without `.md` (e.g.
`homePage`, `VerifyGpsListing`) — matching how `/list_flow` and `/run` name
flows. Filenames include seconds (`yyyyMMdd-HHmmss`), so repeated runs never
collide or overwrite each other.

Content formatting for Markdown (the metadata block, the per-step table) is
**not** done by this script — composing that text is an LLM task. Once you
have `MD_PATH`, write the Markdown content to that exact path with the
`Write` tool, following the template below unchanged.

`new-path <flow_name>` (singular, no "s") still exists and behaves exactly
as before, for any caller that only needs the `.md` path.

## Generating the HTML report (HtmlReportGenerator)

The HTML report is rendered by a dedicated generator,
`.claude/skills/generateReport/scripts/html_report_generator.js` (Node.js),
so its markup/CSS lives in one place instead of being reinvented per report.
It is invoked through `report_tool.sh` — never call `node` on it directly —
so it stays behind the same allowlisted script path:

```bash
.claude/skills/generateReport/scripts/report_tool.sh render-html <HTML_PATH> <<'JSON'
{
  "flowName": "Home Page Flow",
  "flowDoc": "flow/homePage.md",
  "precondition": "None",
  "apk": "app-release (10).apk",
  "versionCode": "1",
  "versionName": "23.7.0",
  "package": "com.wheelseyeoperator.debug",
  "platform": "android",
  "device": "emulator-5554",
  "runStart": "2026-07-24 18:39:15 UTC",
  "runEnd": "2026-07-24 18:45:12 UTC",
  "duration": "5m 57s",
  "overallResult": "PASS",
  "tokens": { "total": 12345, "input": 10000, "output": 2000, "cacheRead": 300, "cacheWrite": 45 },
  "steps": [
    { "step": "1: Home page", "assertion": "contains \"Loading Location\"", "result": "PASS", "notes": "" },
    { "step": "2: ...", "assertion": "...", "result": "FAIL", "notes": "exact failure reason", "timestamp": "2026-07-24 18:41:02 UTC" }
  ]
}
JSON
```

Notes on the JSON payload (this is the same data already gathered for the
Markdown report — assemble it once, use it for both):

- Every field is optional except `steps`; anything missing/empty renders as
  `N/A` in the HTML (never guess or invent a value to fill a gap).
- `tokens` may be omitted entirely if usage isn't available in this session
  (same rule as the Markdown "not available" case) — its sub-fields render
  as `N/A` individually.
- `result` per step accepts `PASS`/`FAIL`/`SKIP` (case-insensitive, with or
  without the ✅/❌/⚠️ glyphs) and is normalized to the right badge.
- `notes` is the failure reason for a `FAIL` row (shown in Notes and in the
  Failure Details section) — leave blank for Pass rows.
- `timestamp` per step is optional; used only in the Failure Details section.
- `overallResult` accepts `PASS`/`FAIL`; if omitted it's derived as `FAIL`
  when any step failed, else `PASS` — same rule as the Markdown report.
- The generator computes Total/Passed/Failed/Skipped/Success Rate itself —
  don't pass precomputed statistics.
- The Failure Details section is included automatically only when at least
  one step is `FAIL` — nothing to do for that on the caller's side.

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

- Still call `report_tool.sh end` and `new-paths`, and still write **both**
  files — a failed run's report is exactly as important as a passing one.
- Record the failing step's row with `❌ Fail` and put the exact failure
  reason (e.g. the specific `contains` check that didn't match) in **Notes**
  (Markdown) / `notes` (HTML JSON payload) — the same reason string in both.
- Mark **Overall Result** as `❌ Fail` in the Markdown, and `"overallResult": "FAIL"`
  in the HTML JSON payload.
- Any step never reached gets `⚠️ Skipped` in the Markdown table and
  `"result": "SKIP"` in the HTML JSON `steps` array — never omitted from
  either.
- The HTML report's Failure Details section renders itself automatically
  from the `FAIL` rows in `steps` — nothing extra to do for it.

## Scope

This skill only formats and persists reports from results it's given (or
that the caller gathers via `driveFlow`) — it never drives the app or
re-verifies assertions itself. The HTML report is rendered by
`html_report_generator.js`; everything else (Markdown content, JSON payload
assembly) is composed by the calling agent from the same run data.
