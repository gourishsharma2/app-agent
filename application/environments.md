# Environments

## In-app Staging / Production toggle
The Operator app itself exposes a **Staging / Production** switch directly on the login screen, next to the phone-number field (see `flow/loginFlow.md` Step 1). This lets a build talk to either backend without needing a separate build — it is the environment control that actually matters for what data/test accounts are valid, not anything in this repo's own config.

## In-app toggle is build-dependent
The toggle exists on the debug build (`com.wheelseyeoperator.debug`, 23.7.0). The production build verified on 29 Jul 2026 (`com.wheelseyeoperator`, 24.1.0) has **no** Staging/Production control on the login screen — it talks to production only.

## `config.properties` (this repo)
`config.properties` at the project root controls the **automation harness**, not the app's backend environment:
- `platform=android` — which mobile platform `launchApplication`/`driveFlow` target.
- `appiumServerUrl` — where the local Appium server is expected to be running.
- the `apiCheck` block — `apiEnv`, `apiBaseUrl.<env>`, `apiAuthHeader`, timeouts and login settings for API validation.

Do not confuse the first two with the in-app Staging/Production toggle above. **`apiEnv` is different**: it must be kept *in sync* with whichever backend the app is pointed at, because an API-vs-UI comparison run against a different environment compares two unrelated datasets and fails for the wrong reason. `apiBaseUrl.prod` is `https://wheelseye.com`.

## Web reference environment
A companion web app for the same product family is reachable at the staging environment: `https://trucking-web.stage.wheelseye.in/fo/login`. Useful for cross-checking terminology/flows, not part of the automated app under test.

## Debug/sideload build caveat
The APK explored so far (`com.wheelseyeoperator.debug`) is a debug build installed by sideloading the APK rather than via the Play Store. This triggers an "Unauthenticated App Detected" dialog right after login — expected for this kind of build, not an environment misconfiguration. See `application/known-behaviors.md`.
