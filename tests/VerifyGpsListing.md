# Verify GPS Listing

End-to-end verification of the vehicle GPS listing flow (Vehicles tab → All / Running / Stopped) in the WheelsEye ("operator") mobile app.

## Precondition

The user must be logged in to the application. Drive `flow/loginFlow.md` in full (Steps 1–5) using the credentials from `application/test-data.md`, and confirm all of that doc's assertions pass, ending on the Home page (FasTag tab).

## Test Steps

### Step 1: Open the Vehicles tab

From the Home page, tap the **Vehicles** tab. This corresponds to `flow/gpsListingFlow.md` Step 1.

Verify the static chrome of that step's screenshot:
- `contains "Vehicles"` (tab is selected)
- `contains "Your vehicles"`
- `contains "All ("`, `contains "Running ("`, `contains "Stopped ("` (the chips exist)
- If the list is still loading: `contains "Taking time in getting your vehicle details"`

**API Validations** — the chip *numbers* are data, not chrome, so they are
verified against the backend rather than hardcoded (see
`api/vehicleFilterCount.md` for the full contract):

```
.claude/skills/apiCheck/scripts/api_action.sh get vehicleFilterCount
.claude/skills/apiCheck/scripts/api_action.sh assert-status 200
.claude/skills/apiCheck/scripts/api_action.sh assert-json success true
.claude/skills/apiCheck/scripts/api_action.sh compare-ui data.running --normalize number --in "Running" --label "Running chip == API running count"
.claude/skills/apiCheck/scripts/api_action.sh compare-ui data.stoppage --normalize number --in "Stopped" --label "Stopped chip == API stoppage count"
```

The **All** chip is deliberately *not* checked here: it is not
`running + stoppage + noInfo`. Verified live on 29 Jul 2026 — the API summed
to 85 while the chip read 95, at the same moment Running and Stopped matched
exactly. Its real source hasn't been identified yet; see the "The All chip
does NOT come from this endpoint" section of `api/vehicleFilterCount.md`.

Run these while the Vehicles tab is on screen and the list has finished
loading. Requires a token — `api_action.sh token-from-device <appPackage>`
once at the start of the run.

### Step 2: Verify the Running filter

Tap the **Running** chip. This corresponds to `flow/gpsListingFlow.md` Step 2.

Verify everything shown in that step's screenshot, for the running vehicle card(s):
- `contains "Running ("`
- `contains "ON"`
- `contains "Ignition"`
- `contains "Play route"`
- `contains "Route History"`
- `contains "Parking alarm"`

### Step 3: Verify the Stopped filter

Tap the **Stopped** chip. This corresponds to `flow/gpsListingFlow.md` Step 3.

Verify everything shown in that step's screenshot, for the stopped vehicle cards:
- `contains "Stopped ("`
- `contains "Save location"`
- `contains "Stopped since"`

### Step 4: Verify the All filter, and the HR36AP7846 card specifically

Tap the **All** chip. This corresponds to `flow/gpsListingFlow.md` Step 4.

First verify the top-level screen matches that step's screenshot:
- `contains "All ("`
- `contains "Non Wheelseye GPS"`
- `contains "Buy GPS to track your vehicle"`

Then **scroll down** the vehicle list until the card for vehicle **`HR36AP7846`** is visible (it is not necessarily the first card — keep scrolling and re-checking `source` until it appears), and verify that specific card shows:
- `contains "HR36AP7846"`
- `contains "Non Wheelseye GPS"` (on/near this card)
- `contains "Buy GPS to track your vehicle"` (on/near this card)
- `contains "Check balance"` (FASTag balance link on this card)

**API Validations** — with that card scrolled into view, confirm its live
telemetry matches the backend (see `api/vehiclesDynamic.md`). Substitute the
vehicle id for `HR36AP7846`:

```
.claude/skills/apiCheck/scripts/api_action.sh post vehiclesDynamic '{"vehicleIds":[<id>]}'
.claude/skills/apiCheck/scripts/api_action.sh assert-status 200
.claude/skills/apiCheck/scripts/api_action.sh assert-fields data speed ignitionState addr displayTime
.claude/skills/apiCheck/scripts/api_action.sh compare-ui data.<id>.addr --normalize text --label "Card address == API addr"
.claude/skills/apiCheck/scripts/api_action.sh compare-ui data.<id>.displayTime --normalize raw --label "Card timestamp == API displayTime"
```

Only the card currently rendered can be compared — Compose keeps just the
visible window of the list in the hierarchy.

## Note on hardcoded counts

Earlier revisions of this doc asserted `All (94)` / `Running (1)` /
`Stopped (3)`. Those were true when the screenshots were taken; the backend
now reports 85 / 2 / 2. A literal count assertion fails identically whether
the app is broken or the fleet simply moved, so the counts are verified
against `api/vehicleFilterCount.md` instead and only the chip *labels* are
asserted as text.

## Scope

This test drives and verifies the UI per `driveFlow`'s scope, and cross-checks
the data it displays against the backend per `apiCheck`'s scope — it does not
persist state or turn this into an automated regression test.

## Reporting

Every run of this test is automatically reported per the project's standard
convention — see `driveFlow`'s "Reporting results" section and the
`generateReport` skill (`.claude/skills/generateReport/SKILL.md`) for the
filename, format, and script usage. Include one row per step above —
Precondition, Step 1, Step 2, Step 3, Step 4 (and the HR36AP7846 card check
as its own row under Step 4) — plus the API checks, passed through verbatim
from `api_action.sh results --json` as the report payload's `apiChecks`.
