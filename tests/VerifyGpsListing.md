# Verify GPS Listing

End-to-end verification of the vehicle GPS listing flow (Vehicles tab → All / Running / Stopped) in the WheelsEye ("operator") mobile app.

## Precondition

The user must be logged in to the application. Drive `flow/loginFlow.md` in full (Steps 1–5) using the credentials from `application/test-data.md`, and confirm all of that doc's assertions pass, ending on the Home page (FasTag tab).

## Test Steps

### Step 1: Open the Vehicles tab

From the Home page, tap the **Vehicles** tab. This corresponds to `flow/gpsListingFlow.md` Step 1.

Verify everything shown in that step's screenshot:
- `contains "Vehicles"` (tab is selected)
- `contains "All (94)"`
- `contains "Running (1)"`
- `contains "Stopped (3)"`
- `contains "Your vehicles"`
- If the list is still loading: `contains "Taking time in getting your vehicle details"`

### Step 2: Verify the Running filter

Tap the **Running (1)** chip. This corresponds to `flow/gpsListingFlow.md` Step 2.

Verify everything shown in that step's screenshot, for the single running vehicle card:
- `contains "Running (1)"`
- `contains "ON"`
- `contains "Ignition"`
- `contains "Play route"`
- `contains "Route History"`
- `contains "Parking alarm"`

### Step 3: Verify the Stopped filter

Tap the **Stopped (3)** chip. This corresponds to `flow/gpsListingFlow.md` Step 3.

Verify everything shown in that step's screenshot, for the stopped vehicle cards:
- `contains "Stopped (3)"`
- `contains "Save location"`
- `contains "Stopped since"`

### Step 4: Verify the All filter, and the DL01GH6543 card specifically

Tap the **All (94)** chip. This corresponds to `flow/gpsListingFlow.md` Step 4.

First verify the top-level screen matches that step's screenshot:
- `contains "All (94)"`
- `contains "Non Wheelseye GPS"`
- `contains "Buy GPS to track your vehicle"`

Then **scroll down** the vehicle list until the card for vehicle **`DL01GH6543`** is visible (it is not necessarily the first card — keep scrolling and re-checking `source` until it appears), and verify that specific card shows:
- `contains "DL01GH6543"`
- `contains "Non Wheelseye GPS"` (on/near this card)
- `contains "Buy GPS to track your vehicle"` (on/near this card)
- `contains "Check balance"` (FASTag balance link on this card)

## Scope

This test only drives and verifies the UI per `driveFlow`'s scope — it does not persist state or turn this into an automated regression test.

## Reporting

Store the results of each run under `execution/report/` (see `driveFlow`'s "Reporting results" section for the general convention):

- Filename: `execution/report/VerifyGpsListing_<YYYY-MM-DD_HHMM>.md`
- A Pass/Fail table with one row per step above — Precondition, Step 1, Step 2, Step 3, Step 4 (and the DL01GH6543 card check as its own row under Step 4) — columns `Step | Description | Result | Notes`.
- An overall Pass/Fail line at the top of the report.
- If any assertion fails, note the exact `contains` check that failed in that row's `Notes` column.
