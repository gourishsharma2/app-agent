# Framework Review

A review of this harness as it stood before the API layer was added, plus the
defects found while verifying it live on 29 Jul 2026 against
`com.wheelseyeoperator` 24.1.0 on an API 35 emulator.

Items marked **FIXED** were repaired during that session. Items marked
**RECOMMENDED** need a decision or a follow-up and were deliberately left
alone.

## What the design gets right

Worth stating, because the constraints below are consequences of it, not
accidents:

- **One allowlisted entry point per concern.** The "never hand-roll a
  curl/adb one-liner" rule is what keeps the harness prompt-free across a
  shared repo. It is also why capabilities are added as *subcommands* rather
  than new commands, which has kept the surface area small and discoverable.
- **Docs as the source of truth.** A screenshot plus an assertion list is
  reviewable by someone who doesn't read code, and doesn't rot the way a
  Page Object hierarchy does when the app is not in this repo.
- **State in files, not shell variables.** Session id, run start, last API
  response. Slightly unusual, but it's what allows every call to be a single
  plain command.

## Defects found live

### 1. `contains` could never match text with `&`, `<`, `>` or `"` — **FIXED**

The page source is XML, so `&` arrives as `&amp;`. `flow/homePage.md` asserts
`contains "View & pay"` — an assertion that could never pass, regardless of
what the app displayed. Proven on the Settings screen: `contains "Network &
internet"` failed while `contains "Network &amp; internet"` passed.

Fixed in `appium_action.sh`: `contains`, `assert-all`, `find`, `wait-for`,
`wait-until-gone` and `scroll-to` now check the literal string, then its
XML-escaped form. Docs can write text the way it appears on screen.

*Why it matters beyond the one assertion:* a permanently-failing assertion in
a doc that has never been run end to end is invisible. It only surfaces the
first time someone trusts the result.

### 2. `launch_environment.sh` failed on a machine with a perfectly good SDK — **FIXED**

Android Studio does not export `ANDROID_HOME` or put `adb`/`emulator` on
PATH. On the reference machine `ANDROID_HOME` was unset and `emulator` was
not on PATH, so the script died at "emulator CLI not found on PATH" whenever
no emulator happened to be running — with the SDK sitting at
`~/Library/Android/sdk`.

Fixed: the script now resolves the SDK itself (honouring `ANDROID_HOME` /
`ANDROID_SDK_ROOT`, else probing the standard locations) and extends PATH for
its own execution. Verified by running it with `ANDROID_HOME` unset and a
stripped PATH.

### 3. No way to check the toolchain, and no way to boot without an APK — **FIXED**

The only entry point required an APK path, so "is my machine set up?" could
only be answered by attempting a real run. Added two modes:

- `launch_environment.sh doctor` — checks SDK, every tool, the Appium driver,
  AVDs, running emulator, and `apk/` contents, reporting *every* problem in
  one pass.
- `launch_environment.sh boot` — Appium + emulator + boot wait + screen-sleep
  off, no install. Needed for API-only checks and for driving an
  already-installed build.

### 4. Hardcoded data in assertions — **FIXED for the GPS test, pattern documented**

`tests/VerifyGpsListing.md` asserted `All (94)`, `Running (1)`, `Stopped (3)`.
The backend now reports 85 / 2 / 2. Those assertions fail identically whether
the app is broken or the fleet simply moved — **the test cannot distinguish a
defect from normal data change**, which is the worst property a test can have.

Fixed by splitting the two questions: assert the chip *labels* as static
chrome (`contains "All ("`), and verify the *numbers* against
`api/vehicleFilterCount.md` with `compare-ui`. The same treatment applies to
per-card speed/ignition/address via `api/vehiclesDynamic.md`.

### 5. `hide-keyboard` can close the app — **DOCUMENTED**

On Android, UiAutomator2 implements `hide_keyboard` as a back press; with
nothing to dismiss it pops the activity. Observed live: it closed the
Operator app to the launcher mid-login. Also observed: re-running
`open-session` does **not** reliably foreground a backgrounded app under
`noReset`. Both are now called out in `driveFlow`'s SKILL.md.

### 6. Tapping by screenshot pixel math is brittle — **FIXED (new `tap-on`)**

Flow docs derive x/y from screenshots, which ties them to one resolution and
one layout revision. Added `appium_action.sh tap-on "<substring>"`, which
resolves the element's real `bounds` at run time and taps its centre. Prefer
it over `tap <x> <y>` wherever the target has stable text.

## Recommendations not yet acted on

### A. `contains` matches the whole XML, including non-visible attributes

`contains "Settings"` returned FOUND on the launcher because the string
appears in a `resource-id`/class name, not because the user could see it.
This produces **false passes**, the most dangerous failure mode for a test.

Recommendation: add a `--strict` mode (or a `contains-text` subcommand) that
matches only `text` / `content-desc` / `hint` attribute values, and migrate
assertion lists to it. The API layer's `api_json.py` already does exactly
this parsing — `ui_strings()` — so the logic can be lifted rather than
reinvented.

### B. Reports carry no visual evidence

`screenshot` writes into a gitignored directory and nothing links those files
into the HTML report. A failure row says what didn't match but not what the
screen looked like.

Recommendation: embed a base64 screenshot per failed step in the report
payload. `html_report_generator.js` is the only place that would change.

### C. Doc drift — several summaries contradict reality

- `summary/automation-status.md` lists every doc as "not yet driven/run",
  while `execution/report/VerifyGpsListing-20260727-193405.html` is a real run
  report from 27 Jul.
- `summary/reusable-summary.md` calls reporting "opt-in"; `generateReport`'s
  SKILL.md says every run is reported unconditionally.
- `CLAUDE.md` and `summary/known-issues-summary.md` discuss `tests/demand/*`
  and empty `tests/account|payment|shipper/` scaffold directories at length.
  **Those directories no longer exist** — the open question they describe is
  already resolved.
- `application/architecture.md` documents `com.wheelseyeoperator.debug` at
  versionName 23.7.0 as the build under test; the build actually supplied is
  `com.wheelseyeoperator` 24.1.0 (production package, sideloaded), whose login
  screen has **no Staging/Production toggle** and no visible "One Tap Login" —
  both of which `application/environments.md` and `flow/loginFlow.md` still
  describe.

Recommendation: these are cheap to fix but they are the team's call, since
some describe intended future state. Doc drift is the main maintenance risk
in a docs-as-source-of-truth design — a stale doc here is what a failing
test would be in a code-based framework, except nothing goes red.

### D. No shared precondition for login

Every test doc restates "drive `flow/loginFlow.md` in full". With the login
endpoint rate-limited (15-minute lockout after a few attempts — hit twice
during this session), repeatedly logging in through the UI is actively
harmful on a shared account.

Recommendation: log in once per environment and rely on `noReset` to keep the
session, rather than making login a precondition of every test. Add an
explicit "already logged in?" check at the top of a run and skip the login
flow when it passes.

### E. No flake handling or timing policy

There is no retry, and waits are ad-hoc `sleep`s between steps in practice
even though `wait-for`/`wait-until-gone` exist. Recommendation: make
`wait-for` the default after any navigation action in flow docs, and state a
policy — retry once on a *navigation* step, never on an *assertion*, since
retrying an assertion is how a flaky test becomes a lying test.

### F. `find` output is ambiguous with multiple matches

It prints bounds only, so with several matches you can't tell which element
is which. Recommendation: print `text/content-desc → bounds` pairs.

## What the first live run found

The UI-vs-API comparison was run against the real app on 29 Jul 2026
(`com.wheelseyeoperator` 24.1.0, logged in as WE25622). Report:
`execution/report/VerifyGpsListing-API-20260729-010055.html`.

- Running chip == `data.running` (2) — **PASS**
- Stopped chip == `data.stoppage` (2) — **PASS**
- All chip vs `sum(running,stoppage,noInfo)` — **the mapping was wrong.** The
  API summed to 85; the chip read 95, at the same instant the other two
  matched exactly. The All total comes from a source outside
  `getAllFilterCount`, still unidentified (`sniff` found nothing — this build
  doesn't log request URLs). The contract doc was corrected to mark the All
  mapping unknown rather than forcing the assertion green.

Worth noting *because* it was a miss: the value of this layer is that a wrong
assumption produced a specific, actionable discrepancy (85 vs 95) on its
first real run, instead of a vague "the count looks off". The old hardcoded
`contains "All (94)"` would have failed here too — but it would have told you
nothing about why.

## Applies to the new API layer too

The same pitfalls exist on the API side and are handled explicitly, but they
are worth restating because they are easy to get wrong:

- **Anchor numeric comparisons** (`--in`). Without it, `data.stoppage = 2`
  happily matches the `Running (2)` chip. This was caught while testing the
  comparison engine — an unanchored check passed for entirely the wrong
  reason, which is exactly the false-pass problem in (A).
- **Compose renders only the visible window**, so a whole payload can never be
  compared against one screen — scroll to the target or sample with
  `--limit`.
- **Never widen a normalizer to turn a check green.** If `raw` fails and
  `digits` passes, that's a formatting finding, not a fix.
