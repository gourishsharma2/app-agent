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
- `driveFlow` skill — driving/verifying documented flows via `appium_action.sh` (open-session/tap/type/source/contains/close-session), see `.claude/skills/driveFlow/SKILL.md`. Every run is reported to `execution/report/` — automatic, not opt-in (see `generateReport`).
- `apiCheck` skill — calling backend APIs, validating status/headers/body, and comparing the returned values against the live screen via `api_action.sh`, see `.claude/skills/apiCheck/SKILL.md`. Endpoint contracts and UI-mapping tables live in `api/*.md`.
- Test credentials: `application/test-data.md`.

## Reusable API patterns
- **Response envelope** — every Operator endpoint returns `{ message, success, serverTime, data }`. Assert `success` as well as the HTTP status; a 401 arrives with `success: false` in the body.
- **Static header set** — the ~11 headers the app sends on every call (`X-APP-VERSION`, `service: OperatorApp`, `user-code`, device ids, …) live once in `api/headers.properties` and are applied automatically.
- **Auth token** — reuse the app's own token (`api_action.sh token-from-device <pkg>`) rather than logging in; the login endpoint is rate-limited and locks the shared test account for 15 minutes.
- **Anchored comparison** — always pass `--in "<anchor>"` when comparing a number, so a value can't match the wrong element on a screen that shows several similar ones.

## Not yet identified
Reusable patterns within Diesel, LOADS, and the side menu haven't been explored yet — revisit this file once those are documented.
