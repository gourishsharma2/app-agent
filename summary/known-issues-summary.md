# Known Issues Summary

Environment quirks and open questions surfaced while exploring the Operator app — not necessarily app bugs, but things that affect automation and should be understood before writing new flow/test docs. Full detail in `application/known-behaviors.md`.

## Confirmed expected behaviors (not bugs)
- **"Unauthenticated App Detected" dialog** after login — expected because the current APK is a sideloaded debug build (`com.wheelseyeoperator.debug`), not a Play Store install.
- **Notification permission prompt** stacked with the dialog above, right after login.
- **Masked FASTag/diesel balances** on some vehicle cards in the Vehicles tab — assert on labels/links, not the (sometimes blurred) numeric values.
- **"Non Wheelseye GPS" vehicles** show a "Buy GPS to track your vehicle" link instead of live tracking — expected for any vehicle without a device installed, not a tracking bug.

## Resolved — leftover content from a different app
`tests/demand/` and the empty `tests/account/`, `tests/payment/`, `tests/shipper/` scaffold directories carried "demand"/booking terminology from WheelsEye's **Book Truck** (shipper-facing) app rather than the **Operator** app this project automates. **They no longer exist** — `tests/` now contains only `VerifyGpsListing.md`. Nothing further to decide; this entry is kept as a record of why that terminology may still appear in older notes.

## Login is rate-limited (backend)
A few repeated login attempts — through the UI *or* the API — return "You have reached maximum login attempts, wait till 15 minutes before trying again". Confirmed on both surfaces on 29 Jul 2026. It is a real backend response, not a bad credential, and it locks the shared test account for everyone. Prefer reusing an existing session (`noReset`) and, for API checks, `api_action.sh token-from-device` over `api_action.sh login`. See `api/login.md`.

## Data-driven assertions go stale silently
Chip counts, balances and telemetry hardcoded into flow docs (`All (94)`, `Running (1)`) fail once the fleet changes — the backend reported 85 / 2 / 2 on 29 Jul 2026 — and they fail identically whether the app is broken or the data simply moved. Verify these against the backend via the `apiCheck` skill instead. See `summary/framework-review.md`.

This file should be updated whenever a new expected-but-surprising behavior is found, or an open question here gets resolved.
