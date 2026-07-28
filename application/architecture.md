# Architecture

## App under test
- Platform: Android (native), built with Jetpack Compose — UI elements are mostly identified by `content-desc` rather than `resource-id`, and Compose frequently merges several elements into one accessibility node (see `.claude/skills/driveFlow/SKILL.md`, "Finding tap coordinates").
- Package name (production build, currently used for automation): `com.wheelseyeoperator`
- Package name (debug/sideload build used for earlier exploration): `com.wheelseyeoperator.debug`
- Launchable activity: `com.wheelseyeoperator.MainActivity` (confirmed via `adb shell cmd package resolve-activity --brief`; the debug build inserts a `.debug` segment)
- App label: "WheelsEye"
- Versions seen: versionName `24.1.0` / versionCode `244410` (production build, verified 29 Jul 2026) — earlier docs describe versionName `23.7.0` / versionCode `1` (debug build). The `24.1.0` build's login screen has **no Staging/Production toggle** and no visible "One Tap Login"; both are described in `flow/loginFlow.md` from the older debug build.
- Min SDK: 24 · Target SDK: 36 · Compile SDK: 36
- Native ABIs in the APK: `arm64-v8a`, `armeabi-v7a`, `x86_64`
- Notable permissions: fine/coarse location, Bluetooth scan/connect (GPS hardware pairing), camera, contacts, notifications, record audio, foreground service, boot-completed — consistent with a fleet-tracking + FASTag + diesel-purchase app.

## Web counterpart
A companion web app exists at a staging URL: `https://trucking-web.stage.wheelseye.in/fo/login` (path prefix `/fo/`, i.e. "fleet owner"), offering the same "Login with OTP" / "Login with Password" choice as the mobile app. It isn't the target of this project but is a useful secondary reference for terminology and flows shared with the Operator app.

## Automation approach
No native/Java test code is written for this project. The already-installed app is driven purely through Appium's HTTP API + adb, orchestrated by two Claude Code skills instead of a Page Object/TestNG framework:
- `launchApplication` (`.claude/skills/launchApplication/`) — boots the Android emulator + Appium server and installs a given APK build.
- `driveFlow` (`.claude/skills/driveFlow/`) — taps/types/reads the screen to drive a documented flow, verifying each step's assertions against the UI hierarchy dump.

Screens and flows are documented as markdown + real screenshots (`flow/*.md`, `tests/*.md`, screenshots under `screenshots or figma Links/<name>/`) rather than as code. See `summary/automation-status.md` for current coverage.

The `pom.xml`/Maven setup previously in this repo was removed as unused leftover from the source project this repo was copied from — there is no `src/main` or `src/test` anywhere here, and the actual automation is entirely bash + curl + adb.
