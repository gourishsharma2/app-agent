# Application Overview

**WheelsEye** is an Indian logistics-tech company (founded 2017, HQ Gurugram) that provides digital fleet-management tools — GPS tracking, FASTag (digital toll), diesel/fuel deals, and freight/loads — to truck and fleet owners across India.

WheelsEye ships (at least) two separate customer-facing mobile apps:
- **Book Truck app** — shipper-facing app for booking trucks/freight. Not covered by this project.
- **Operator app** — for fleet owners/operators to manage their own vehicles: FASTag, GPS tracking, diesel, and loads. **This is the app this project automates.**

## App identity
- App label: "WheelsEye" (Play Store listing title: "FASTag, GPS, Fuel")
- Production Android package: `com.wheelseyeoperator`
- Package of the build used for exploration/automation so far: `com.wheelseyeoperator.debug` (a sideloaded debug build — see `application/known-behaviors.md` for what that changes)
- Version explored: `23.7.0`

## Core services (Home page tabs)
- **FasTag** — FASTag recharge, wallet balance, per-tag balances. See `flow/homePage.md`.
- **Vehicles** — fleet/GPS listing and live tracking (All / Running / Stopped). See `flow/gpsListingFlow.md`.
- **Diesel** — diesel/fuel deals. Not yet explored.
- **LOADS** — freight/loads. Not yet explored.

## Authentication
Phone number + OTP or password, with an in-app Staging/Production environment toggle. See `application/login.md`.

## Related references
- Staging web app (same product family, "fo" = fleet owner): `https://trucking-web.stage.wheelseye.in/fo/login`
- See `application/architecture.md` for technical/build details, `application/navigation.md` for the app's navigation structure, and `summary/application-summary.md` for a condensed snapshot of everything explored so far.
