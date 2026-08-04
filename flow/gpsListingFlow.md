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