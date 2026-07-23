# Known Behaviors

Non-obvious or environment-specific behaviors observed while exploring the app — check here before treating something as a bug.

## "Unauthenticated App Detected" dialog after login
Because the APK used for automation so far (`com.wheelseyeoperator.debug`) is sideloaded rather than installed from the Play Store, the app shows an "Unauthenticated App Detected" dialog right after login, telling the user to install the Play Store build instead. Expected for every debug/sideloaded build — dismiss with "Okay" as a normal flow step, not a failure. See `flow/loginFlow.md` Step 4.

## Notification permission prompt
A standard Android notification-permission dialog ("Allow WheelsEye to send you notifications?") also appears right after login, stacked with the dialog above. Either "Allow" or "Don't allow" is fine for automation purposes unless a specific test needs notifications enabled.

## Staging vs Production toggle
The login screen has a Staging/Production switch (see `application/environments.md`). Which one is selected changes which backend the app talks to, and therefore which credentials/data are valid. Confirm the toggle position before debugging an unexpected login failure or unexpected data on screen.

## Masked balances on vehicle cards
On the Vehicles tab, FASTag balance and diesel-left figures shown on individual vehicle cards can appear visually masked/blurred (near "Check balance" / "Upgrade Now" links) even though the surrounding label/link text is readable. `contains` assertions on the numeric values may not be reliable — assert on the labels/links instead. See `flow/gpsListingFlow.md` Steps 2–3.

## "Non Wheelseye GPS" vehicles
Vehicles without a WheelsEye GPS device installed show a "Non Wheelseye GPS" tag and a "Buy GPS to track your vehicle" link instead of live speed/location. Expected for any fleet vehicle that hasn't had a device installed yet — not a tracking failure. See `flow/gpsListingFlow.md` Step 4.
