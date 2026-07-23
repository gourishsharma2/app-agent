# Reusable Summary

Elements, patterns, and tooling that recur across flows/screens — reuse these rather than re-describing them in every new flow doc.

## Reusable UI elements
- **Bottom navigation bar** — Wallet, Learn, Home, Notification, Help — present on Home and its tabs.
- **Home tab row** — FasTag, Vehicles, Diesel, LOADS — top of the Home page.
- **Top bar** — hamburger menu, WheelsEye logo, Help button, language-toggle icon — consistent across Home tabs.
- **"Ask Saarthi" chat bubble** — floating chatbot entry point, seen on multiple Home tabs.
- **"Schedule installation" sticky bar** — Order ID + "Schedule now" button, seen at the bottom of the Vehicles tab.
- **Staging/Production toggle** — on the login screen; changes which backend/environment the app talks to (see `application/environments.md`).

## Reusable automation tooling
- `launchApplication` skill — environment prep (emulator + Appium + APK install), see `.claude/skills/launchApplication/SKILL.md`.
- `driveFlow` skill — driving/verifying documented flows via `appium_action.sh` (open-session/tap/type/source/contains/close-session), see `.claude/skills/driveFlow/SKILL.md`. Includes an opt-in "Reporting results" convention writing to `execution/report/`.
- Test credentials: `application/test-data.md`.

## Not yet identified
Reusable patterns within Diesel, LOADS, and the side menu haven't been explored yet — revisit this file once those are documented.
