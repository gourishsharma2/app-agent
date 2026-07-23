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
.claude/skills/driveFlow/scripts/appium_action.sh type "some text"
.claude/skills/driveFlow/scripts/appium_action.sh source              # prints the current UI hierarchy XML
.claude/skills/driveFlow/scripts/appium_action.sh contains "some text" # exit 0/1, for a quick screen check

# 3. Always close the session when done — this also clears the state file.
.claude/skills/driveFlow/scripts/appium_action.sh close-session
```

`sleep <n>` and `grep ...` between steps are fine as their own separate calls
too — both are already unconditionally auto-allowed by Claude Code, so they
don't need an allowlist entry and won't prompt either, as long as they aren't
combined into the same command line as something else.

Note: `noReset` means the app process and its state persist across sessions —
reopening a session resumes wherever the app was left (e.g. mid-flow on some
screen), it does not restart at the welcome screen. Only `launchApplication`'s
uninstall+reinstall actually resets app state.

## Finding tap coordinates

Read the flow doc's screenshot (under `screenshots or figma Links/screens/`) to see roughly where an
element sits, then confirm exact bounds from `source` output (elements are
Jetpack Compose views identified mostly by `content-desc`, rarely
`resource-id`). Compose can merge several UI elements into one large
accessibility node — tap near where the element visually appears within that
merged region, not just its center, and re-check `source` after tapping to
confirm the screen actually changed.

## Checking assertions

If a step in the flow doc has an **Assertions** list, don't just eyeball the
`source` dump — run `contains "<exact substring>"` for each listed string
right after landing on that screen, and report each one as pass/fail. An
"OR" between two assertions (e.g. `"Payments"` OR `"Due Amount"`) passes if
either `contains` call succeeds. For a "not present before, present after
tapping X" assertion, capture `source` (or a targeted `contains`) before and
after the tap and confirm the diff.

If a step has no Assertions list, fall back to the prior behavior: read
`source` and judge by eye whether the screen matches the doc's description.

## Scope

This only drives the UI and reads the screen — it doesn't persist results
across runs. It's for verifying a documented flow still works on a given
build. Turning a flow into a real regression test (Page Object + TestNG) is a
separate, explicit step.

Once the whole task is done (flow driven and verified), close the webdriver
session with `close-session` as above, then optionally tear down the whole
environment (Appium server + emulator) with
`.claude/skills/launchApplication/scripts/close_environment.sh` — see that
skill's "Tearing the environment down" section.
