---
name: driveFlow
description: Drives an already-installed, already-running app through a documented flow (flow/ or tests/<category>/ markdown docs) via Appium — tapping, typing, and reading the screen — using one fixed helper script instead of ad-hoc curl/adb one-liners. Use after launchApplication has the environment ready, whenever asked to "run" a flow (e.g. a screen doc under flow/, or an end-to-end flow under tests/<category>/) without persisted test code.
---

# driveFlow

Manually drives the app through the steps described in a flow doc — either a
per-screen doc under `flow/` (e.g. `flow/home-screen.md`) or an end-to-end
business flow under `tests/<category>/` (e.g.
`tests/demand/create-demand-saved-address.md`) — verifying each screen
against the doc, without writing or persisting any test code.

## Why this exists

Driving a flow needs several distinct Appium/adb actions per step (open a
session, tap, type, read the screen, close the session). Hand-rolling a fresh
curl/adb command each time means the exact command text differs every run
(different session IDs, coordinates, temp file paths), so no simple permission
allowlist rule stays stable — every run prompts again.

This script is the fix: ONE fixed entry point with a stable path, so
`.claude/settings.json` can allowlist it once
(`Bash(.claude/skills/driveFlow/scripts/appium_action.sh *)`) and stop
prompting.

## Staying prompt-free for everyone, in every session

This repo is shared across multiple people. `.claude/settings.json` is
committed and shared — every allowlist rule needed to run a flow must live
there. `.claude/settings.local.json` is per-user and per-machine, is not
committed, and does not help a teammate or a future session on a different
machine; anything added only there (e.g. a rule tied to one specific emulator
serial or an absolute path under one user's home directory) will re-prompt
for everyone else, and can even re-prompt for the same user later if the
detail it's pinned to (like the emulator serial) changes.

So: never invent a new raw `curl`/`adb`/`chmod` one-liner to get something
done. If a task needs a new capability, add a new subcommand to
`appium_action.sh` (or `launch_environment.sh` /
`close_environment.sh` for environment setup/teardown) and call it through
the existing fixed script path — that path is already allowlisted, so nothing
new needs to be added to settings for it to stay prompt-free, for anyone,
forever. If a script path itself is genuinely new (not a new subcommand of an
existing script), add its allowlist rule to `.claude/settings.json`, not
`.claude/settings.local.json`.

## Usage

The active session id is tracked internally by the script (a state file next
to it), not captured into a shell variable — issue every call as its own
**single, plain command**, never wrapped in `$(...)`, `&&`, or combined with
other commands on the same line. A wrapped/combined invocation no longer
starts with the literal script path, which breaks the `.claude/settings.json`
allowlist match and re-triggers a permission prompt. One command per tool
call is what keeps this prompt-free.

```bash
# 1. Open a session against the already-installed app (see launchApplication
#    for how it gets installed). Get appPackage/appActivity via:
#    aapt dump badging <apk> | grep -E "launchable-activity|package:"
.claude/skills/driveFlow/scripts/appium_action.sh open-session <appPackage> <appActivity>

# 2. Drive the flow: tap coordinates from the flow doc's element bounds,
#    type text via adb, and read the screen between steps to confirm you
#    landed where the doc says you should.
.claude/skills/driveFlow/scripts/appium_action.sh tap <x> <y>
.claude/skills/driveFlow/scripts/appium_action.sh long-press <x> <y> [durationMs]  # default 800ms
.claude/skills/driveFlow/scripts/appium_action.sh double-tap <x> <y>
.claude/skills/driveFlow/scripts/appium_action.sh type "some text"
.claude/skills/driveFlow/scripts/appium_action.sh back                 # Android hardware back button
.claude/skills/driveFlow/scripts/appium_action.sh hide-keyboard        # dismiss the soft keyboard, if shown
.claude/skills/driveFlow/scripts/appium_action.sh wake-screen          # wakes the device if its screen went to sleep (no-op if already awake)
.claude/skills/driveFlow/scripts/appium_action.sh swipe <x1> <y1> <x2> <y2> [durationMs]  # raw custom swipe
.claude/skills/driveFlow/scripts/appium_action.sh scroll <up|down|left|right>             # full-screen directional swipe
.claude/skills/driveFlow/scripts/appium_action.sh scroll-to "some text" [up|down|left|right] [maxScrolls]  # scroll (default down) + check repeatedly until found (default 10 scrolls), logging each attempt
.claude/skills/driveFlow/scripts/appium_action.sh source              # prints the current UI hierarchy XML
.claude/skills/driveFlow/scripts/appium_action.sh contains "some text" # exit 0/1, for a quick screen check
.claude/skills/driveFlow/scripts/appium_action.sh assert-all "text1" "text2" ...  # checks all substrings against one page-source fetch — use for a step's whole assertion list
.claude/skills/driveFlow/scripts/appium_action.sh find "some text"     # prints bounds="[x1,y1][x2,y2]" for each matching element
.claude/skills/driveFlow/scripts/appium_action.sh wait-for "some text" [timeoutSeconds]        # poll until it appears (default 30s)
.claude/skills/driveFlow/scripts/appium_action.sh wait-until-gone "some text" [timeoutSeconds]  # poll until it disappears (default 30s) — for loading states

# 3. Always close the session when done — this also clears the state file.
.claude/skills/driveFlow/scripts/appium_action.sh close-session
```

There is deliberately no screenshot/vision capability in this script. Every
question this skill answers — where an element is, whether a screen
transition landed, whether text is present — comes from the UI hierarchy XML
(`source`/`find`/`contains`/`assert-all`), which is exact and free of visual
ambiguity. Compiled-plan authoring (`flow-compiler`) is the only place in
this pipeline that still looks at pixels, and it reads the flow doc's own
documentation screenshots directly with the `Read` tool — it never goes
through this script. If a real gap shows up where XML truly can't answer a
question, raise it rather than reintroducing screen capture here.

Never pipe `source`'s output into a raw `grep` call (or redirect it to a file under `/tmp` to grep later) to find an element's coordinates — despite what earlier versions of this doc claimed, `grep` is **not** unconditionally auto-allowed in practice, and redirecting output to a file plus reading it back from outside the project root (`/tmp`) each need their own permission on top of that. Use the `find` subcommand above instead: it does the filtering internally (inside the already-allowlisted script) and prints just the `bounds="..."` you need, with nothing written outside the project and no separate `grep`/`Read` call required. `sleep <n>` by itself, with no piping, is genuinely auto-allowed and fine to use between steps.

Note: `noReset` means the app process and its state persist across sessions —
reopening a session resumes wherever the app was left (e.g. mid-flow on some
screen), it does not restart at the welcome screen. Only `launchApplication`'s
uninstall+reinstall actually resets app state.

`open-session` sets a 1-hour `newCommandTimeout` (up from Appium's default),
so the session survives normal thinking/back-and-forth gaps between actions
without dying mid-flow — if `source`/`contains`/etc. ever comes back with
"invalid session id", the session genuinely expired (or the app crashed/got
killed) and needs `open-session` called again, not a sign anything else is
wrong. Separately, `launch_environment.sh` disables the emulator's screen
sleep timeout for the whole automation session, so it shouldn't go to sleep
mid-run either — if a tap stops registering and the screen appears off,
prefer `wake-screen` over diagnosing it as an app problem.

## Finding tap coordinates

Live coordinate resolution — turning a text selector into on-screen
`bounds` — is `find "<content-desc text>"` against the current `source`
(elements are Jetpack Compose views identified mostly by `content-desc`,
rarely `resource-id`) rather than reading the full `source` dump and
grepping it yourself. Under the compiled-plan architecture, `run-plan` does
this resolution internally for every step in a plan — you only need to call
`find` directly yourself during a `flow-runner` local-recovery pass (a real
divergence) or ad-hoc exploration outside a plan. Where a selector's text
actually comes from (what to type into `find`) is decided once, at compile
time, by `flow-compiler` reading the flow doc's own documentation
screenshots directly — never by this script.
Compose can merge several UI elements into one large
accessibility node — tap near where the element visually appears within that
merged region, not just its center, and re-check `source`/`contains` after tapping to
confirm the screen actually changed.

## Scrolling and other gestures

For a doc instruction like "scroll down until X is visible," don't hand-roll a
tap-then-`contains`-then-tap-again loop — use `scroll-to "X" [maxScrolls]` in
one call; it scrolls and re-checks internally, logs every attempt (to
stderr — `FOUND:`/`NOT FOUND:` on stdout stay parseable), and stops the
instant the substring appears instead of doing extra scrolls. It also detects
a stalled list: if two consecutive scrolls produce no change in the page
source, it stops early and reports "likely reached the end" rather than
burning through the rest of `maxScrolls` blindly. Pass a direction
(`scroll-to "X" up 15`) for the rare screen that needs to scroll up/left/right
instead of down — omit it and it defaults to down. For a single scroll without
a target to search for, use `scroll <up|down|left|right>`, which swipes across
the full screen height/width automatically (no need to compute coordinates
yourself). `swipe <x1> <y1> <x2> <y2>` is there for anything more specific
(e.g. a custom carousel) that the directional `scroll` doesn't fit.

Under the hood, every one of these gestures is driven by `adb shell input
swipe`, not Appium's W3C pointer-actions API. A raw 2-point W3C swipe (start
coordinate, end coordinate, duration) gives UiAutomator2 too little to go on,
and Android/Compose scrollables often read it as an uncontrolled fling —
the actual scroll distance varies between otherwise-identical calls, which is
why a fixed-count scroll loop could skip past the target element on one run
and undershoot it on the next. `adb shell input swipe` synthesizes a real
interpolated motion-event sequence, which Compose's scroll gesture detector
recognizes consistently across devices and screen sizes (coordinates are
still computed from `window/rect`, so nothing is hardcoded to one resolution).
`long-press`, `double-tap`, and `back` (the hardware back button) cover the
other common gestures a flow doc might call for; `hide-keyboard` is useful
right after `type` if an on-screen keyboard is covering a button you need to
tap next.

## Waiting for loading states

Some screens show a transient loading state (e.g. "Taking time in getting
your vehicle details...") before real content appears. Don't hand-roll a
`sleep`+`contains` polling loop in a background shell for this — use
`wait-until-gone "<loading text>" [timeoutSeconds]` to poll for the loading
text to disappear, or `wait-for "<text>" [timeoutSeconds]` to poll for
content to appear, both inside the one already-allowlisted script. If a
`wait-until-gone`/`wait-for` call times out, that's a real signal worth
reporting as-is (e.g. "list never finished loading after 30s") rather than
silently retrying forever or improvising a longer wait outside the script.

## Checking assertions

If a step in the flow doc has an **Assertions** list, don't just eyeball the
`source` dump — check each listed string right after landing on that screen,
and report each one as pass/fail. Prefer `assert-all "<substring1>" "<substring2>" ...`
over calling `contains` once per substring: it fetches the page source once
and checks every substring against that single snapshot instead of
re-fetching per assertion, and still reports each one individually (FOUND/NOT
FOUND), so nothing about the pass/fail coverage changes — only the number of
page-source round trips does. Make sure the screen has actually settled
first (see "Waiting for loading states" below) before batching — checking a
whole assertion list against a still-loading screen just means several
assertions come back NOT FOUND together instead of one being a timing
fluke. Fall back to a single `contains "<substring>"` call when you only
need one check (e.g. confirming a tap landed on the right screen before
deciding what to do next). An "OR" between two assertions (e.g. `"Payments"`
OR `"Due Amount"`) passes if either one is FOUND. For a "not present before,
present after tapping X" assertion, capture `source` (or a targeted
`contains`) before and after the tap and confirm the diff.

If a step has no Assertions list, fall back to the prior behavior: read
`source` and judge by eye whether the screen matches the doc's description.

## Scope

This only drives the UI and reads the screen — by default it doesn't persist
results across runs. It's for verifying a documented flow still works on a
given build. Turning a flow into a real regression test (Page Object + TestNG)
is a separate, explicit step.

Once the whole task is done (flow driven, verified, and reported), close the
webdriver session with `close-session` as above, then always tear down the
whole environment (uninstall the app, stop Appium, stop the emulator) with
`.claude/skills/launchApplication/scripts/close_environment.sh` — this is a
standard step after every completed run, not optional, per that skill's
"Tearing the environment down" section.

## Reporting results

Every run gets a saved report — this is automatic, not something the user
needs to ask for. Use `.claude/skills/generateReport/scripts/report_tool.sh`
(`start` before driving, `end` after) and hand the results off to the
`report-writer` agent, including `end`'s full output verbatim (`START=`,
`END=`, `DURATION=`, and its `TOKENS_*` lines — don't drop those), following
the `generateReport` skill
(`.claude/skills/generateReport/SKILL.md`) for the exact filename
(`execution/report/<flow_name>-<yyyyMMdd-HHmmss>.html`, directory created if
missing) and report format (metadata block + per-step/per-assertion table,
overall ✅ Pass / ❌ Fail). Only HTML is generated — no Markdown report file.

A step is Fail if any one of its listed assertions fails; capture the
specific `contains` check(s) that didn't match in `Notes`. Raw evidence
(full `source` XML dumps per step) is optional and, if captured, goes under
`execution/logs/` with the same base filename — the report itself should
stay a concise table, not a dump of page source.

This always happens, whether the run passes, fails partway through, or the
`tests/*.md` doc being driven has its own "Reporting" section — none of
that is opt-in anymore.
