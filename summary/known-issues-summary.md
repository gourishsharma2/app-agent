# Known Issues Summary

Environment quirks and open questions surfaced while exploring the Operator app — not necessarily app bugs, but things that affect automation and should be understood before writing new flow/test docs. Full detail in `application/known-behaviors.md`.

## Confirmed expected behaviors (not bugs)
- **"Unauthenticated App Detected" dialog** after login — expected because the current APK is a sideloaded debug build (`com.wheelseyeoperator.debug`), not a Play Store install.
- **Notification permission prompt** stacked with the dialog above, right after login.
- **Masked FASTag/diesel balances** on some vehicle cards in the Vehicles tab — assert on labels/links, not the (sometimes blurred) numeric values.
- **"Non Wheelseye GPS" vehicles** show a "Buy GPS to track your vehicle" link instead of live tracking — expected for any vehicle without a device installed, not a tracking bug.

## Open question — leftover content from a different app?
`tests/demand/` (cancel-demand, create-demand-current-location, create-demand-new-address, create-demand-saved-address, edit-demand) plus the empty `tests/account/`, `tests/payment/`, `tests/shipper/` scaffold directories use "demand"/booking terminology that matches WheelsEye's **Book Truck** (shipper-facing) app, not the **Operator** app this project automates — no "book a truck"/"demand" concept has appeared anywhere in the Operator app explored so far (its services are FasTag / Vehicles(GPS) / Diesel / LOADS). These were very likely carried over from another project during the copy that seeded this repo. Recommend confirming with the team whether to remove/archive them or keep them for a future Book Truck automation effort — left untouched for now since removing test content wasn't requested.

This file should be updated whenever a new expected-but-surprising behavior is found, or an open question here gets resolved.
