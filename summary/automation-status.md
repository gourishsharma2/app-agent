# Automation Status

This project automates the WheelsEye **Operator** Android app **without writing test code** — flows are documented as markdown + real screenshots, then driven live via Appium through two Claude Code skills, instead of Page Objects/TestNG classes.

## How it works
1. `launchApplication` skill — boots the Android emulator + Appium server and installs a given APK build (`.claude/skills/launchApplication/`).
2. Flow/screen behavior is documented in `flow/*.md` (per-screen or short flows) and `tests/*.md` (end-to-end business flows), each with real screenshots under `screenshots or figma Links/<name>/` and a per-step **Assertions** list (`contains "..."` checks against the UI hierarchy dump).
3. `driveFlow` skill — taps/types/reads the screen to drive the documented flow and verify each step's assertions (`.claude/skills/driveFlow/`).
4. `apiCheck` skill — calls the backend directly, validates the response, and compares the values it returned against what the app renders, so data-driven assertions come from the API instead of from numbers hardcoded in a doc (`.claude/skills/apiCheck/`, contracts in `api/*.md`).
5. Reporting — every run writes an HTML report to `execution/report/`, including an **API Validations** section when the run had API checks; raw evidence optionally goes to `execution/logs/`.

## Coverage so far
| Doc | Status |
|---|---|
| `flow/loginFlow.md` | Documented (password login path); driven 29 Jul 2026 up to the Login tap — blocked by the backend's 15-minute login rate limit, not by the app |
| `flow/homePage.md` | Documented (FasTag tab) — not yet driven/run. Note its `contains "View & pay"` assertion could never match before the XML-escaping fix (see `summary/framework-review.md`) |
| `flow/gpsListingFlow.md` | Documented (Vehicles tab: All/Running/Stopped) — not yet driven/run |
| `tests/VerifyGpsListing.md` | Documented (login → GPS listing verification, incl. scroll-to-card check + API validations) — not yet driven/run |
| `api/login.md` | Documented — endpoint verified live (returns 401 rate-limit when over-used) |
| `api/servicesInfo.md` | Documented — endpoint verified live (HTTP 200) |
| `api/vehicleFilterCount.md` | Documented — endpoint verified live (HTTP 200); UI mapping not yet run against the app |
| `api/vehiclesDynamic.md` | Documented — endpoint verified live (HTTP 200); UI mapping not yet run against the app |

## Not yet started
- Diesel tab, LOADS tab, side menu, search, Notification screen, Help screen
- OTP login path and One Tap Login

## Open question
`tests/demand/*` and the empty `tests/account/`, `tests/payment/`, `tests/shipper/` scaffold directories use "demand"/booking terminology that matches WheelsEye's **Book Truck** app, not the Operator app this project targets — see `summary/known-issues-summary.md` for detail. Confirm with the team whether these should be removed/archived or repurposed before adding new content under `tests/`.

This file should be updated every time a new area of the app is explored and documented, or a doc above moves from "documented" to "driven and passing."
