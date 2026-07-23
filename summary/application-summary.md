# Application Summary

**WheelsEye** is an Indian logistics-tech company (founded 2017, HQ Gurugram) providing fleet-management tools — GPS tracking, FASTag (digital toll), diesel/fuel deals, and freight/loads — to truck fleet owners. It ships two apps: a shipper-facing **Book Truck** app, and the **Operator app**, which this project automates.

- Package (debug build used here): `com.wheelseyeoperator.debug` · Production package: `com.wheelseyeoperator`
- Version explored: `23.7.0`
- Login: phone number + OTP or password, plus an in-app Staging/Production toggle
- Core services (Home page tabs): **FasTag**, **Vehicles** (GPS), **Diesel**, **LOADS**
- Full details: `application/overview.md`, `application/architecture.md`, `application/environments.md`, `application/login.md`, `application/navigation.md`, `application/known-behaviors.md`

## Coverage explored so far
- Login flow (password path) — `flow/loginFlow.md`
- Home page / FasTag tab — `flow/homePage.md`
- Vehicles tab / GPS listing (All, Running, Stopped filters) — `flow/gpsListingFlow.md`
- End-to-end test: `tests/VerifyGpsListing.md`

Diesel, LOADS, the side menu, search, and the OTP/One-Tap login paths are not yet explored. This file, and the rest of `summary/`, will be updated as those areas get documented — see `summary/flows-summary.md`, `summary/screens-summary.md`, `summary/reusable-summary.md`, `summary/known-issues-summary.md`, and `summary/automation-status.md`.
