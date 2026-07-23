# Architecture

## App under test
- Platform: Android (native), built with Jetpack Compose — UI elements are mostly identified by `content-desc` rather than `resource-id`, and Compose frequently merges several elements into one accessibility node (see `.claude/skills/driveFlow/SKILL.md`, "Finding tap coordinates").
- Package name (debug/sideload build used for exploration so far): `com.wheelseyeoperator.debug`
- Package name (Play Store / production): `com.wheelseyeoperator`
- Launchable activity: `com.wheelseyeoperator.debug.MainActivity` (for the debug build; the production activity name would drop the `.debug` segment)
- App label: "WheelsEye"
- Version explored: versionName `23.7.0`, versionCode `1` (from `aapt dump badging` on the provided APK)
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
