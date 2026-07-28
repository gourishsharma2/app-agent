# GPS Listing Flow

This document describes the vehicle GPS listing flow on the **Vehicles** tab of the Home page (see `flow/homePage.md`) in the WheelsEye ("operator") mobile app — viewing the fleet's live tracking status, filtered by All / Running / Stopped.

> **The counts below are a snapshot, not a contract.** `All (94)` / `Running (1)` / `Stopped (3)` were the values when these screenshots were taken; the backend reported 85 / 2 / 2 as of 29 Jul 2026, and they change as the fleet moves. Treat the chip *labels* as the assertion and verify the *numbers* against `api/vehicleFilterCount.md` via the `apiCheck` skill. Same applies to per-card speed/ignition/address — see `api/vehiclesDynamic.md`.

## Step 1: Vehicles tab — All filter (loading state)

Tapping the **Vehicles** tab (next to FasTag) opens the vehicle list, with the **All (94)** filter chip selected by default alongside **Running (1)** and **Stopped (3)** chips and a filter icon. Above the list is a toll-price ticker, a "Need VLTD (AIS 140) Device?" promo banner, and a "Diesel payments" entry. The "Your vehicles" section header shows a refresh icon, a "Reports" (New) button, and an "+ Add device" button, followed by an "Add your other vehicle" input with an "Add" button. The vehicle list itself is still loading, showing "Taking time in getting your vehicle details. Please check back later." A floating "Ask Saarthi" chat bubble and map icon sit above a sticky "Schedule installation" bar (with Order ID and a "Schedule now" button).

![Step 1](<../screenshots or figma Links/gps/Step 1.png>)

**Assertions:**
- `contains "Vehicles"`
- `contains "All (94)"`
- `contains "Running (1)"`
- `contains "Stopped (3)"`
- `contains "Your vehicles"`
- `contains "Taking time in getting your vehicle details"`

## Step 2: Running filter

Tapping the **Running (1)** chip filters the list down to the single currently-running vehicle. Each vehicle card shows: the plate number (e.g. `HR55AM1599A`) with current speed in kmph, an "ON"/ignition status with a timestamp, the last known address, distance covered today (e.g. "0 km today"), a masked FASTag balance with a "Check balance" link, masked diesel-left with an "Upgrade Now" link, and an action row — **Play route**, **Route History**, **Share**, and a **Parking alarm** toggle. Below the card is a "Need help? Chat with us for any issues" banner.

![Step 2](<../screenshots or figma Links/gps/Step 2.png>)

**Assertions:**
- `contains "Running (1)"`
- `contains "ON"`
- `contains "Ignition"`
- `contains "Play route"`
- `contains "Route History"`
- `contains "Parking alarm"`

## Step 3: Stopped filter

Tapping the **Stopped (3)** chip filters the list to the fleet's stopped vehicles. Each card shows the plate number, speed (0 kmph), ignition state (can still read "ON" or "OFF" even while stopped), a timestamp, the last known address with a "Save location" link, how long it's been stopped (e.g. "Stopped since 49 mins"), and the same FASTag balance / diesel-left / Play route / Route History / Share / Parking alarm row as the Running view.

![Step 3](<../screenshots or figma Links/gps/Step 3.png>)

**Assertions:**
- `contains "Stopped (3)"`
- `contains "Save location"`
- `contains "Stopped since"`

## Step 4: All filter (loaded — non-GPS vehicles)

Back on the **All (94)** chip once the list finishes loading, vehicles that don't have a WheelsEye GPS device installed are shown with a "Non Wheelseye GPS" tag and a "+ Buy GPS to track your vehicle" link in place of live speed/location data. Each such card still shows its plate number, a timestamp, and either a FASTag balance with a "Check balance"/"Recharge" link.

![Step 4](<../screenshots or figma Links/gps/Step 4.png>)

**Assertions:**
- `contains "All (94)"`
- `contains "Non Wheelseye GPS"`
- `contains "Buy GPS to track your vehicle"`
