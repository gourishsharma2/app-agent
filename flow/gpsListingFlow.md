# GPS Listing Flow

This document describes the vehicle GPS listing flow on the Vehicles tab of the Home page (see `flow/homePage.md`) in the WheelsEye Operator app — viewing the fleet's live tracking status via the All/Running/Stopped filter chips, with the chip counts validated against the backend rather than hardcoded.

## Precondition

User must be logged in first — complete `flow/userLogin.md` before this flow's steps.

The API steps below need a session token for the **same account** the app is logged in as. `testUserOne` is `WE25622`, so:

```
.claude/skills/apiCall/scripts/api_action.sh auth production WE25622
```

## Step 1: Vehicles tab — filter chips

The user taps the "Vehicles" tab (next to "FasTag" in the Home page tab row). This opens the fleet list with the "All", "Running" and "Stopped" filter chips above it.

![Step 1](<../screenshots or figma Links/gpsListingFlow/Step 1.png>)

**Assertions:**
- `contains "Vehicles"`
- `contains "All ("`
- `contains "Running ("`
- `contains "Stopped ("`

Only the chip label prefixes are asserted here; the counts are fleet data that changes between runs and are validated against the API in Step 3 instead.

Verified live 3 Aug 2026: these three chips are the only clickable elements in the chip row. There is **no filter icon and no "Offline" option** on this screen — an earlier draft of this doc described a funnel icon opening a panel containing "Offline", marked provisional because no screenshot showed it. It does not exist in this build, so that step and its assertion have been removed rather than left to fail.

## Step 2: Read the fleet counts from the backend

```
CALL_API getAllFilterCount
```

No UI interaction. Binds the response into the runtime context, producing `api.running`, `api.stoppage` and `api.noInfo` — see `api/contracts/getAllFilterCount.md`.

**Assertions:**
- `api.success == true` (checked as part of the call: a non-2xx status fails the step)

## Step 3: Chip counts match the backend

No UI interaction — asserts the counts bound by Step 2 against the chips already on screen.

**Assertions:**
- `contains "Running (${api.running})"`
- `contains "Stopped (${api.stoppage})"`

The expected values come from the API, so this cannot rot the way `contains "Running (1)"` did.

**No `IF api.running > 0` guard.** The chip renders `Running (0)` when nothing is running — verified live 3 Aug 2026 with `WE25622`, where `api.running` was `0` and `Running (0)` matched exactly. Guarding was only ever needed for hardcoded counts; an API-sourced expectation is correct at zero too, so the assertion runs unconditionally and a zero-running fleet is now validated instead of skipped.

**`api.noInfo` is not asserted.** The app exposes no No-Info chip or label — `api.noInfo` counts the "Non Wheelseye GPS" / no-recent-data population (see `application/known-behaviors.md`) and nothing on this screen displays it. The previous `contains "All ("` guarded on it added nothing over Step 1's identical assertion, so it is gone rather than kept as coverage theatre.

### The All chip is not the sum of the three counts

Verified live 3 Aug 2026 with `WE25622`: `0 + 2 + 79 = 81`, while the **All** chip read **92**. `Running (0)` and `Stopped (2)` matched the API exactly at that same moment, so this is not staleness or an account mismatch — the app sources the total elsewhere, and about eleven vehicles fall outside all three categories. An independent check on 29 Jul 2026 saw the same discrepancy in the same direction (85 vs 95).

**Do not assert the All count against this endpoint**, and do not "fix" this step by adding a sum of the three fields — that produces a red run blaming the app for a wrong mapping in this doc. Identifying the real source of the All count would also make a precise No-Info assertion possible.

## Step 4: Select a fleet tab with vehicles, and verify the first card's vehicle number

The user taps the "Running" chip. If the fleet has no running vehicles (`api.running == 0`, already known from Step 2), the user taps the "Stopped" chip instead. The first vehicle card shown must display the same vehicle number as the first vehicle the backend returns for whichever chip ends up active — see `api/contracts/vehiclesStatic.md` for how this endpoint was discovered and confirmed live on 5 Aug 2026.

Tap "Running" chip.

IF api.running == 0
Tap "Stopped" chip.
ENDIF

IF api.running > 0
```
CALL_API vehiclesStatic?filter=DRIVING&pageNo=0&pageSize=10
```
ENDIF

IF api.running == 0
```
CALL_API vehiclesStatic?filter=STOPPAGE&pageNo=0&pageSize=10
```
ENDIF

**Assertions:**
- `contains "${api.list.0.vehicleNumber}"`

`pageSize=10` is requested so the whole filtered list lands in `api.list` in one call. **Verified live 5 Aug 2026: `pageSize=15`/`20`/`50` silently return no `data` field at all on this backend** (200 OK, envelope only) — see `api/contracts/vehiclesStatic.md`'s Notes — so `10` is used deliberately, not as a placeholder. This account currently has 0 running / 2 stopped vehicles, comfortably under that, and Step 11 below reuses this same `api.list` rather than calling the API again.

Live-verified 5 Aug 2026 with `WE25622`: `api.running` was `0`, so the Stopped chip was tapped; the first card showed `NL01ACC3479`, matching `api.list.0.vehicleNumber` from the `filter=STOPPAGE` response exactly.

A second live pass the same day, with this account now showing `api.running = 1`, exercised the `running > 0` branch for the first time: the Running chip was tapped, `CALL_API vehiclesStatic?filter=DRIVING&pageNo=0&pageSize=10` returned `api.totalCount = 1`, and the first card showed `NL01ACC3479` again, matching `api.list.0.vehicleNumber` exactly.

## Step 5: Vehicle card layout

On the vehicle card now visible, verify: the speed reading (kmph) on the top-left of the card, the ignition status on the top-right (**ON** when the Running chip is active, **OFF** when the Stopped chip is active), a "FasTag" section with a "Check Balance" link, and the bottom action row: Play Route, Route History, Share, and Parking Alarm. A "Save Location" option is also present, but only when the vehicle is stopped — see below.

No action — still on the screen reached in Step 4.

**Assertions:**
- `contains "kmph"`
- IF api.running > 0: `contains "ON"`
- IF api.running == 0: `contains "OFF"`
- IF api.running == 0: `contains "Save location"`
- `contains "FasTag"`
- `contains "Check balance"`
- `contains "Play route"`
- `contains "Route History"`
- `contains "Share"`
- `contains "Parking alarm"`

Live-verified 5 Aug 2026 — corrected vs. the original narrative's casing: `kmph` (not "km/h"), `Save location`, `Check balance`, `Parking alarm` (lowercase second word in each). `FasTag`, `Play route`, `Route History`, `Share` matched as given. The card's content-desc merges several lines into one node, e.g. `"0\nkmph\nNL01ACC3479\nToday, ...\nOFF\nIgnition"`.

**The `ON` ignition assertion is now confirmed, and `Save location` is confirmed stopped-only.** This account's first run against a genuinely running vehicle (5 Aug 2026) exercised the previously-unverified `ON` branch and confirmed it matches live. That same run also checked the live accessibility XML and made 5 scroll-to attempts across the running vehicle's card, and **found no "Save location" element anywhere in its subtree** — not off-screen, not lazily rendered, simply absent. This supersedes the earlier note (from when this account had 0 running vehicles) that carried `ON` only on the strength of the `OFF` branch's symmetry — `ON` no longer needs that hedge, and `Save location` is now known to be a stopped-vehicle-only element rather than a universal one.

The four bottom-action labels are seeded from `bottomMenuListItems.items[].text` in the Step 4 API response and confirmed live to render verbatim.

## Step 6: Play Route opens the map

The user taps "Play route" on the vehicle card. The app navigates to a new screen showing a map.

Tap "Play route".

**Assertions:**
- `contains "Google Map"`
- `contains "Date range"`
- `contains "${api.list.0.vehicleNumber}"`

Live-verified 5 Aug 2026: lands on a route/report screen whose content-desc includes the literal text `"Google Map"` (the map element itself) alongside `"Date range"`, `"Last 7 days"`, `"Run-time"`, `"Stop-time"`, `"Tolls crossed"`, `"More reports"`, and `"How it works?"`; the vehicle number from Step 4 is still shown. `"Stopped ("` is no longer present, confirming departure from the listing screen.

## Step 7: Back from Play Route

The user presses back.

Tap back (hardware back button).

**Verified live 5 Aug 2026: no confirmation bottom sheet appeared** — back returns directly to the vehicle listing. No "Go back" tap is scripted as a result; if a future run does hit a bottom sheet here, that's a genuine divergence to recover/patch (this repo's existing convention for optional post-action dialogs — e.g. `flow/loginFlow.md`'s "Unauthenticated App Detected" dialog), not something to guess into this doc now.

**Assertions:**
- `contains "Running ("`
- `contains "Stopped ("`
- `contains "${api.list.0.vehicleNumber}"`

## Step 8: Route History opens the map

The user taps "Route History" on the vehicle card. The app navigates to a new screen showing a map.

Tap "Route History".

**Assertions:**
- `contains "Google Map"`
- `contains "Date range"`
- `contains "${api.list.0.vehicleNumber}"`

Live-verified 5 Aug 2026: **"Route History" lands on the exact same screen as "Play route" in Step 6** — identical content-desc set (`Google Map`, `Date range`, `Run-time`, `Stop-time`, etc.). Confirmed real app behavior, not a stale/re-used reading — both card actions currently open the same route/report screen.

## Step 9: Back from Route History

The user presses back.

Tap back (hardware back button).

Same result as Step 7, verified live 5 Aug 2026: back returns directly to the listing, no bottom sheet observed. No "Go back" tap scripted, for the same reason as Step 7.

**Assertions:**
- `contains "Running ("`
- `contains "Stopped ("`
- `contains "${api.list.0.vehicleNumber}"`

## Step 10: Share bottom sheet

The user taps "Share" on the vehicle card. A bottom sheet is displayed. The user taps its cross/close button to dismiss it.

Tap "Share".

**Assertions:**
- `contains "Share truck live location"`
- `contains "Share via WhatsApp"`

Tap the bottom sheet's cross/close button.

**Assertions:**
- `contains "Stopped ("` (bottom sheet dismissed, back on the listing)

Live-verified 5 Aug 2026: the sheet's content-desc includes `"Share truck live location"`, `"Share route details along with live location"`, time-range chips (`2 hrs`/`24 hrs`/`3 days`/`7 days`), `"Add driver (optional)"`, and `"Share via WhatsApp"`.

**Known gap: the close/cross button has no accessible label at all** — no `content-desc`, no `resource-id`, just a bare `ImageView` at a fixed position. This breaks this repo's usual "selector is always text" convention (see `.claude/skills/compilePlan/SKILL.md`); the compiled plan resorts to a coordinate tap for this one action, which is more brittle than every other selector in this doc (liable to break if the sheet's layout shifts). Confirmed it does dismiss the sheet. Flagging for a human to decide whether a coordinate selector is acceptable here or whether the app should get an accessibility label added.

## Step 11: Last vehicle card matches the backend's last vehicle

The last vehicle card shown must display the same vehicle number as the last vehicle in the `api.list` array fetched in Step 4, for whichever chip (Running/Stopped) is active.

No action — reuses `api.list` from Step 4 rather than calling the API again.

**Assertions:**
- `contains "${api.list.<N>.vehicleNumber}"`, where `<N>` is `api.totalCount - 1` for the active filter, resolved to a literal integer index at compile time — see `api/contracts/vehiclesStatic.md`'s "No dynamic last-index" note. This index must be re-verified/recompiled if the vehicle count for the active filter changes enough to shift which vehicle is last.

Live-verified 5 Aug 2026: `api.totalCount` was `2` for the Stopped filter, so `N = 1`; `api.list.1.vehicleNumber` resolved to `RJ32GE4895WE`, confirmed present on screen with no scrolling needed — both of this account's 2 stopped vehicles fit on-screen at once.

A second live pass the same day, with this account now showing `api.running = 1` and the Running filter active (`api.totalCount = 1`), resolved `N = 0`; `api.list.0.vehicleNumber` was `NL01ACC3479`, confirmed on screen — with only one running vehicle, it serves as both the first (Step 4) and last (this step) card. This confirms the doc's own caveat above: the compiled index is tied to whichever filter/count was active at verification time and must be re-verified whenever that changes.
