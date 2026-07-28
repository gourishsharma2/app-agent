---
name: generateReport
description: Generates and saves the standardized HTML run report for a flow/test execution into execution/report/, creating the directory if needed. Used automatically after every /run execution (and by driveFlow/report-writer directly) — not opt-in. Provides the one shared naming/timestamp/duration script (and the HtmlReportGenerator) so this logic isn't re-derived per command.
---

# generateReport

Produces one HTML run report per execution and saves it under
`execution/report/`, creating that directory the first time it's needed.
This is the single, reusable source of truth for report **naming**,
**timestamps/duration**, and **format** — every command or agent that
finishes a flow/test run (the `/run` command, `flow-runner`, `report-writer`,
and any future test runner) should produce its report through this skill
rather than inventing its own filename convention or HTML markup.

Only HTML is generated — no Markdown report file is written.

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
#      TOKENS_AVAILABLE=true|false
#      TOKENS_TOTAL=<n>          (only present when TOKENS_AVAILABLE=true)
#      TOKENS_INPUT=<n>
#      TOKENS_OUTPUT=<n>
#      TOKENS_CACHE_READ=<n>
#      TOKENS_CACHE_WRITE=<n>

# Call once you're ready to write the report file.
.claude/skills/generateReport/scripts/report_tool.sh new-paths <flow_name>
# -> ensures execution/report/ exists, prints:
#      HTML_PATH=execution/report/homePage-20260724-184512.html
```

`<flow_name>` should be the flow/test doc's filename without `.md` (e.g.
`homePage`, `VerifyGpsListing`) — matching how `/list_flow` and `/run` name
flows. Filenames include seconds (`yyyyMMdd-HHmmss`), so repeated runs never
collide or overwrite each other.

`new-path <flow_name>` (singular, no "s") still exists for backward
compatibility but is unused by current callers — it printed the legacy `.md`
path.

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
  ],
  "apiChecks": [
    { "name": "Running chip == API data.running", "result": "PASS", "expected": "2",
      "actual": "Running (2)", "notes": "matched on screen (normalize=number)",
      "timestamp": "2026-07-24 18:40:11 UTC" }
  ]
}
JSON
```

Notes on the JSON payload:

- Every field is optional except `steps`; anything missing/empty renders as
  `N/A` in the HTML (never guess or invent a value to fill a gap).
- `tokens` — build it straight from `report_tool.sh end`'s own output, not
  from your own guess: `{ "total": TOKENS_TOTAL, "input": TOKENS_INPUT,
  "output": TOKENS_OUTPUT, "cacheRead": TOKENS_CACHE_READ, "cacheWrite":
  TOKENS_CACHE_WRITE }`. `end` computes these for real by summing `usage`
  off this session's own Claude Code transcript
  (`~/.claude/projects/<slug>/<session-id>.jsonl`, matched via
  `$CLAUDE_CODE_SESSION_ID`) for every assistant turn — including subagent
  turns — that falls inside the `start`/`end` window, deduped by message id.
  Only omit `tokens` entirely (or leave its fields out) when `end` printed
  `TOKENS_AVAILABLE=false` (no `node` on PATH, or the transcript file
  couldn't be found) — don't omit it just because you didn't bother to read
  `end`'s output.
- `apiChecks` — optional; include it whenever the run had API validations
  (see the `apiCheck` skill). Paste the output of
  `.claude/skills/apiCheck/scripts/api_action.sh results --json` **verbatim**:
  it is the list of checks that were actually recorded during the run, with
  real expected/actual values. Never hand-write or re-summarize these, for
  the same reason token counts and timestamps are never invented. Omit the
  field entirely when the run had no API checks — the section then doesn't
  render, and reports without API validation look exactly as they did before.
  A failed API check makes the run's overall result `FAIL` and appears in the
  Failure Details section alongside failed UI steps.
- `result` per step accepts `PASS`/`FAIL`/`SKIP` (case-insensitive, with or
  without the ✅/❌/⚠️ glyphs) and is normalized to the right badge.
- `notes` is the failure reason for a `FAIL` row (shown in Notes and in the
  Failure Details section) — leave blank for Pass rows.
- `timestamp` per step is optional; used only in the Failure Details section.
- `overallResult` accepts `PASS`/`FAIL`; if omitted it's derived as `FAIL`
  when any step failed, else `PASS`.
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

Field-by-field notes:

- **flowName** — the doc's `# <Title>` heading text if it has one, else the
  filename.
- **flowDoc** — the relative path that was actually driven (e.g.
  `flow/homePage.md`, `tests/VerifyGpsListing.md`).
- **precondition** — copy it from the doc's own `## Precondition` section if
  present; write literally `None` if the doc has no precondition section.
- **apk / versionCode / versionName / package / device** — from
  `.last_install_state` as described above.
- **tokens** — take these straight from `report_tool.sh end`'s
  `TOKENS_TOTAL`/`TOKENS_INPUT`/`TOKENS_OUTPUT`/`TOKENS_CACHE_READ`/
  `TOKENS_CACHE_WRITE` output; omit the field entirely only when `end`
  printed `TOKENS_AVAILABLE=false`.
- **steps** — one entry per assertion actually checked, in the order
  checked, using the step numbering/title from the flow/test doc. Include
  every step that was executed, even the ones after which execution stopped
  due to a failure. Use `SKIP` for steps never reached because an earlier
  step failed.

## Failure handling

If the run fails partway through:

- Still call `report_tool.sh end` and `new-paths`, and still write the HTML
  report — a failed run's report is exactly as important as a passing one.
- Record the failing step with `FAIL` and put the exact failure reason (e.g.
  the specific `contains` check that didn't match) in `notes`.
- Set `"overallResult": "FAIL"` in the JSON payload.
- Any step never reached gets `"result": "SKIP"` in the `steps` array —
  never omitted.
- The HTML report's Failure Details section renders itself automatically
  from the `FAIL` rows in `steps` — nothing extra to do for it.

## Scope

This skill only formats and persists the report from results it's given (or
that the caller gathers via `driveFlow`) — it never drives the app or
re-verifies assertions itself. The HTML report is rendered by
`html_report_generator.js`; the JSON payload assembly is composed by the
calling agent from the run data.
