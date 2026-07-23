# Navigation

## Bottom navigation (global)
Present on the Home page and its tabs: **Wallet**, **Learn**, **Home** (default/selected after login), **Notification**, **Help**.

## Home page tab row
Once on **Home**, a secondary tab row switches between the app's core services:
- **FasTag** (default tab) — FASTag recharge, wallet balance, per-tag balances. See `flow/homePage.md`.
- **Vehicles** — fleet/GPS listing (All / Running / Stopped filters), live tracking per vehicle. See `flow/gpsListingFlow.md`.
- **Diesel** — diesel/fuel deals. Not yet explored.
- **LOADS** — freight/loads. Not yet explored.

Other top-bar elements present across Home tabs: a hamburger menu icon (side menu — not yet explored), a search icon (Vehicles tab), a "Help" button, and a language-toggle icon.

## Documented so far

| Area | Doc |
|---|---|
| Login (password path) | `flow/loginFlow.md` |
| Home page / FasTag tab | `flow/homePage.md` |
| Vehicles tab (GPS listing) | `flow/gpsListingFlow.md` |

Diesel and LOADS tabs, the hamburger side menu, search, Help, Notification screen, and the OTP/One-Tap login paths are not yet documented. Add new `flow/*.md` docs as they're explored, and update this table plus `summary/flows-summary.md` / `summary/screens-summary.md`.
