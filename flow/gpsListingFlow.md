# GPS Listing Flow

This document describes the vehicle GPS listing flow on the Vehicles tab of the Home page (see `flow/homePage.md`) in the WheelsEye Operator app — viewing the fleet's live tracking status, filtered by the All/Running/Stopped chips and a filter option.

## Precondition

User must be logged in first — complete `flow/userLogin.md` before this flow's steps.

## Step 1: Vehicles tab — chips and filter

The user taps the "Vehicles" tab (next to "FasTag" in the Home page tab row). This opens the "Your vehicles" section, where the "All", "Running", "Stopped" filter chips are displayed and verified — note the numeric counts are dynamic fleet data that will differ on future runs, so these assertions should be treated as matching the chip label prefix ("All", "Running", "Stopped"), not the fixed counts shown here.

![Step 1](<../screenshots or figma Links/gpsListingFlow/Step 1.png>)

**Assertions:**
- `contains "Vehicles"`
- `contains "All"`
- `contains "Running"`
- `contains "Stopped"`
