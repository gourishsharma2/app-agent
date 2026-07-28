# app-agent — WheelsEye Operator automation harness

Drives the WheelsEye **Operator** Android app through documented flows via
Appium, and cross-checks the data it displays against the backend APIs.

There is **no test code here** — no `src/`, no TestNG, no Page Objects. Flows
are documented as markdown + real screenshots (`flow/`, `tests/`), API
contracts as markdown + UI-mapping tables (`api/`), and everything is driven
live through four fixed shell entry points. See `CLAUDE.md` for the
architecture and the rules that keep it that way.

---

## 1. Prerequisites

| Tool | Why | Check |
|---|---|---|
| Android Studio (+ SDK) | emulator, `adb`, `aapt` | `adb --version` |
| Java 17+ | Appium / UiAutomator2 | `java -version` |
| Node.js 18+ | Appium, HTML report generator | `node --version` |
| Appium 2.x + `uiautomator2` driver | drives the app | `appium --version` |
| Python 3 | JSON parsing in the API layer (stdlib only) | `python3 --version` |

`curl` and `git` are assumed. No `jq`, no Maven, no `npm install` in this
repo — there is no `package.json` and there should not be one.

### One command to check all of it

```bash
.claude/skills/launchApplication/scripts/launch_environment.sh doctor
```

Reports every problem it finds in one pass — SDK location, each tool, the
Appium driver, available AVDs, whether an emulator is running, and whether
`apk/` has a build. Run this first whenever something misbehaves.

---

## 2. Android SDK environment variables

Android Studio installs the SDK but does **not** export `ANDROID_HOME` or put
`adb`/`emulator` on your PATH. The scripts here auto-detect the SDK at the
standard locations, so they work without this — but you'll want it for your
own shell.

Add to `~/.zshrc` (macOS default shell):

```bash
export ANDROID_HOME="$HOME/Library/Android/sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$ANDROID_HOME/cmdline-tools/latest/bin:$PATH"
```

Then `source ~/.zshrc` and verify:

```bash
echo $ANDROID_HOME     # -> /Users/<you>/Library/Android/sdk
adb --version
emulator -list-avds
```

| Variable | What it does |
|---|---|
| `ANDROID_HOME` | SDK root. Appium's UiAutomator2 driver requires it to find `adb`. |
| `ANDROID_SDK_ROOT` | Newer alias for the same thing; some tools still read it. |
| `PATH` additions | `platform-tools` → `adb`; `emulator` → `emulator`; `cmdline-tools/latest/bin` → `sdkmanager`, `avdmanager`. |

`JAVA_HOME` is generally set by the JDK installer. Set it explicitly if
`java -version` disagrees with what Appium reports.

---

## 3. Create an emulator from scratch

### Option A — Android Studio GUI (simplest)

1. **Tools → Device Manager → Create Device**
2. Pick a phone with a normal aspect ratio (Pixel 6 / Medium Phone). Avoid
   foldables and tablets — flow docs record tap coordinates from screenshots.
3. **System image:** API 33–35, and prefer the **Google APIs** image over
   **Google Play**. A Play image is production-signed: `adb root` is
   unavailable and app data is harder to reach, which blocks
   `api_action.sh token-from-device`. Google APIs images still have Play
   Services, which the Operator app needs for maps/location.
4. **Advanced settings:** RAM **4096 MB** (2 GB makes a Compose app crawl),
   internal storage ≥ 4 GB, **Graphics: Hardware**.
5. Finish, then launch it once from Device Manager to confirm it boots.

### Option B — command line

Requires **Android SDK Command-line Tools (latest)** — install it from
Android Studio → Settings → Languages & Frameworks → Android SDK → *SDK
Tools* tab. (It is missing from a default install; that's why `doctor` warns
about `avdmanager`.)

```bash
sdkmanager "platform-tools" "platforms;android-35" "system-images;android-35;google_apis;arm64-v8a"
avdmanager create avd -n WE_Automation -k "system-images;android-35;google_apis;arm64-v8a" -d "medium_phone"
emulator -list-avds
```

Use `x86_64` instead of `arm64-v8a` on an Intel machine.

### Verify the emulator is automation-ready

```bash
.claude/skills/launchApplication/scripts/launch_environment.sh boot
```

Brings up Appium **and** the emulator without installing anything (`boot`
also disables screen sleep for the session, so screenshots don't come back
black after an idle gap). Then:

```bash
adb devices                                    # -> emulator-5554   device
adb shell getprop sys.boot_completed           # -> 1
adb shell getprop ro.build.version.sdk         # -> 35
```

Pick a specific AVD with `AVD_NAME=WE_Automation` in the environment.

---

## 4. Appium

**Appium is required, and it is the right tool here.** The app under test is
a native Jetpack Compose Android app, installed as a release/debug APK with no
instrumentation hooks and no source in this repo. Espresso needs to be
compiled into the app; UI Automator needs an on-device test APK and a Gradle
project. Appium drives an *already-installed* APK over HTTP from outside the
app — which is exactly this harness's model, and is also why `adb` alone
isn't enough: `adb` can tap coordinates but can't read a structured UI
hierarchy or manage sessions.

```bash
npm install -g appium
appium driver install uiautomator2
appium driver list --installed      # -> uiautomator2@3.x [installed (npm)]
```

You don't normally start the server by hand — `launch_environment.sh` starts
one if none is running (logs: `.claude/skills/launchApplication/logs/appium.log`).
To check it manually: `curl -s http://localhost:4723/status`.

### Sample run (proves the whole chain)

With the environment booted, drive the emulator's own Settings app:

```bash
.claude/skills/driveFlow/scripts/appium_action.sh open-session com.android.settings com.android.settings.homepage.SettingsHomepageActivity
.claude/skills/driveFlow/scripts/appium_action.sh assert-all "Network & internet" "Battery" "Search settings"
.claude/skills/driveFlow/scripts/appium_action.sh scroll-to "About emulated device" 8
.claude/skills/driveFlow/scripts/appium_action.sh screenshot sample
.claude/skills/driveFlow/scripts/appium_action.sh close-session
```

All five should succeed. If `open-session` fails with "No running emulator
detected", the emulator isn't up — run `launch_environment.sh boot`.

---

## 5. Running a real flow

Put a build in `apk/`, then:

```
/run VerifyGpsListing app-release.apk
```

`/run` installs the build, drives the doc, runs any API validations, writes an
HTML report to `execution/report/`, and tears the environment down. Use
`/list_flow` to see every flow and test available.

---

## 6. API validation

Verifies that what the app *shows* matches what the backend *returned*. See
`api/README.md` for the contracts and `.claude/skills/apiCheck/SKILL.md` for
the full command reference.

```bash
# 1. Auth — reuse the token the app is already logged in with.
.claude/skills/apiCheck/scripts/api_action.sh token-from-device com.wheelseyeoperator.debug

# 2. Call + validate the response.
.claude/skills/apiCheck/scripts/api_action.sh get vehicleFilterCount
.claude/skills/apiCheck/scripts/api_action.sh assert-status 200
.claude/skills/apiCheck/scripts/api_action.sh assert-json success true

# 3. Compare against the live screen (needs an open Appium session).
.claude/skills/apiCheck/scripts/api_action.sh compare-ui data.running --normalize number --in "Running"
```

Check the configuration any time with `api_action.sh doctor`.

**Never commit a token or password.** Tokens live in the gitignored
`.claude/skills/apiCheck/.auth_state`; credentials come from `WE_API_MOBILE` /
`WE_API_PASSWORD` in your environment.

---

## 7. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `emulator CLI not found on PATH` | SDK not detected — set `ANDROID_HOME` (§2) or run `doctor`. |
| `avdmanager not found` | Install *Android SDK Command-line Tools (latest)* in the SDK Manager. |
| `No running emulator detected` | Run `launch_environment.sh boot`. |
| `invalid session id` | The session expired or the app was killed — `open-session` again. |
| A `contains` assertion fails but the text is visibly on screen | Check for a merged Compose node, or a character the XML escapes (`&`, `<`, `>`, `"`) — the script handles escaping now, but the text must otherwise match exactly. |
| Screenshots come back black | Screen slept. `launch_environment.sh` disables sleep; `appium_action.sh wake-screen` recovers. |
| API check fails with a plausible-looking value | `apiEnv` in `config.properties` doesn't match the app's in-app Staging/Production toggle, or `user-code` points at a different account. |
| Login API returns 401 "maximum login attempts" | Rate limited for 15 minutes. Use `token-from-device` instead of `login`. |

## Repository layout

| Path | Contents |
|---|---|
| `application/` | reference docs about the app itself (architecture, login, navigation, known behaviors, test data) |
| `flow/` | per-screen flow docs — screenshot + Assertions per step |
| `tests/` | end-to-end business flows composed from flow docs |
| `api/` | endpoint contracts, UI-mapping tables, endpoint/header registries |
| `summary/` | hand-maintained rollups (can go stale — the tooling always reads the filesystem) |
| `execution/report/` | generated HTML run reports |
| `apk/` | APK builds (gitignored — not committed) |
| `.claude/skills/` | the four fixed entry points that do all the work |
