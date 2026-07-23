# Environments

## In-app Staging / Production toggle
The Operator app itself exposes a **Staging / Production** switch directly on the login screen, next to the phone-number field (see `flow/loginFlow.md` Step 1). This lets a build talk to either backend without needing a separate build — it is the environment control that actually matters for what data/test accounts are valid, not anything in this repo's own config.

## `config.properties` (this repo)
`config.properties` at the project root controls the **automation harness**, not the app's backend environment:
- `platform=android` — which mobile platform `launchApplication`/`driveFlow` target.
- `appiumServerUrl` — where the local Appium server is expected to be running.

Do not confuse this with the in-app Staging/Production toggle above.

## Web reference environment
A companion web app for the same product family is reachable at the staging environment: `https://trucking-web.stage.wheelseye.in/fo/login`. Useful for cross-checking terminology/flows, not part of the automated app under test.

## Debug/sideload build caveat
The APK explored so far (`com.wheelseyeoperator.debug`) is a debug build installed by sideloading the APK rather than via the Play Store. This triggers an "Unauthenticated App Detected" dialog right after login — expected for this kind of build, not an environment misconfiguration. See `application/known-behaviors.md`.
