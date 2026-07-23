---
name: launchApplication
description: Prepares the Android automation environment (Appium server + emulator boot + APK install) before any mobile automation task in this repo. Self-contained to this project — reads config from this project's own config.properties, no dependency on any other repo. Use when the user asks to launch the app, install/swap an APK build, start the emulator, or "get the environment ready" for automation, and provides (or is asked for) an APK path.
---

# launchApplication

Prepares everything this project's Appium/TestNG automation needs to be live
before it can drive the WheelsEye Marketplace Android app, then installs a
given APK build.

## When to use this

- The user wants to "get the environment ready" / "launch the app" / "install this
  build" on the Android emulator before doing any UI automation or manual
  exploration with Appium.
- The user gives (or you ask for) an absolute path to an `.apk` file.
- This is Android-only (`platform=android`). It does not touch iOS/pCloudy/LambdaTest
  flows.

## What it does

Run the bundled script, passing the APK path as the only argument:

```bash
.claude/skills/launchApplication/scripts/launch_environment.sh /absolute/path/to/app.apk
```

It performs, in order, stopping immediately with a clear `❌ FAILED at step: ...`
message on the first failure:

1. **Appium server** — checks `GET <appiumServerUrl>/status` (from this
   project's own `config.properties` at the project root, default
   `http://localhost:4723`). Starts `appium` in the background only if it
   isn't already responding.
2. **Android emulator** — checks `adb devices` for a running `emulator-*` device.
   Boots one only if none is running, using the first AVD from
   `emulator -list-avds` (override with `AVD_NAME=<name>` env var).
3. **Boot completion** — polls `adb wait-for-device` + `getprop sys.boot_completed`
   until the emulator is actually ready to accept ADB commands (not just detected).
4. **APK install** — opens an Appium session directly (`automationName=UiAutomator2`,
   `deviceName=<detected emulator serial>`, `autoGrantPermissions=true`) to
   install the APK. See **Why `noReset` instead of `fullReset`** below.
5. **Verification** — extracts the package name from the APK via `aapt` and
   confirms it via `adb shell pm list packages` before declaring success.

## Why `noReset` instead of `fullReset`

`fullReset=true` uninstalls the app when the Appium session is torn down. This
skill opens and closes a session immediately after installing (so the device
is free afterwards), so using `fullReset` here would silently undo the install
right after it happened.

So the script explicitly `adb uninstall`s the target package first (to
guarantee a clean swap when given a different build than whatever was already
installed), then opens the Appium session with `noReset=true`. The install
mechanism itself — Appium/UiAutomator2 installing via capabilities,
`autoGrantPermissions=true` — is standard Appium behavior; only the
reset-capability value is deliberately different for this throwaway prep
session.

## Idempotency

Safe to re-run: it will not start a second Appium server or a second emulator
if one is already up, and re-running with a different APK path cleanly swaps
the installed build via the explicit uninstall step.

## Failure handling

Every step is guarded; on failure the script prints which step failed and why,
then exits non-zero. Relevant background-process logs are written to
`.claude/skills/launchApplication/logs/appium.log` and
`emulator.log` for further debugging — check these first if a step times out.

## Tearing the environment down

Once the whole automation task is done — `launchApplication` prepped the
environment and `driveFlow` finished driving/verifying the flow — stop the
Appium server and emulator with:

```bash
.claude/skills/launchApplication/scripts/close_environment.sh
```

Do **not** run this right after `launch_environment.sh` — `driveFlow` still
needs the Appium server and emulator alive in between. This is a separate,
explicit last step, not something `launch_environment.sh` does on its own.

It stops whatever emulator (`adb emu kill`) and Appium server process (found
via the port in `appiumServerUrl`) are currently running, and is a safe no-op
if either is already stopped.

Both `launch_environment.sh` and `close_environment.sh` are allowlisted by
their fixed script paths in the shared, committed `.claude/settings.json`, so
running either never prompts for permission — for any user, in any session.
Never replace a call to these scripts with raw `adb`/`curl` one-liners, and if
new environment-setup/teardown behavior is needed, add it as a new step
inside these scripts rather than a one-off shell command — see driveFlow's
"Staying prompt-free for everyone, in every session" section for why this
matters in a repo shared across multiple people.
