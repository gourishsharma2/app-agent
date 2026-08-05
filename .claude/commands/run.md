---
description: Execute a documented flow against an APK from apk/ and an app environment (Staging/Production), prompting for whichever of flow_name/apk_name/environment/testUser is missing and validating all four before running. Optionally accepts --mobile/--password to use ad-hoc credentials instead of a named test user.
argument-hint: [flow_name] [apk_name] [environment] [testUser] [--mobile "..."] [--password "..."]
---

# Run a flow

Arguments: `$1` = flow_name (optional), `$2` = apk_name (optional), `$3` =
environment (optional, `Staging` or `Production`), `$4` = testUser
(optional) — selects a named credential block from
`test-data/<environment>.properties` (see `application/test-data.md`) to log
in as, instead of that file's `default` entry. `$4` is conditionally
required: only prompted for when the resolved environment's file has no
`default*` entry at all (today, neither `test-data/production.properties`
nor `test-data/staging.properties` does, so in practice it's always
prompted for unless given up front) **and no `--mobile`/`--password` flags
were given** (see below).

## API runtime inputs (`key=value` form)

Anywhere in the argument text, `key=value` pairs may be given to supply the
runtime values the API layer needs. These are **not** positional and never
consume `$1`–`$4`:

```
/run environment=stage token=xxxx userCode=WE12345 deviceName=Samsung deviceId=xxxx androidVersion=16
```

| Key | Feeds |
|---|---|
| `environment` | selects `api/environments/<value>/` **and** the app environment (accepts `stage`/`staging`/`production`/`prod`, case-insensitive) |
| `token` | the `token` request header — a session secret |
| `userCode` | the `user-code` header; must match the account the app is logged in as |
| `deviceName` | `DEVICE_NAME` header |
| `deviceId` | `DEVICE-ID` and `X-DEVICE-ID` headers |
| `androidVersion` | `ANDROID_VERSION` header |

`environment=` given this way also satisfies `$3`, so don't prompt for the
environment as well. The others are only needed by a flow whose plan contains a
`call-api` step; a UI-only flow ignores them entirely and must not prompt for
them. Never echo `token` back to the user or write it into a report.

Which runtime inputs a given environment actually requires is declared in
`api/environments/<env>/headers.md`, not hardcoded here — check with
`.claude/skills/apiCall/scripts/api_action.sh doctor <environment>`, which
prints `MISSING_RUNTIME_INPUTS=` for anything absent. If a `call-api` step runs
without them, it fails **before** sending a request, naming the missing input —
it never sends an empty token and lets a `401` masquerade as a backend fault.

Pass them through to `flow-runner`, which forwards them to every `run-plan`
call as `--api-env`/`--token`/`--device-name`/`--device-id`/`--android-version`
(`userCode` travels as the existing `--user-code`).

Additionally, anywhere after `$3`, `--mobile "<number>"` and/or `--password
"<pass>"` may be given (parsed from the raw argument text, same style as
`create_flow`'s `--flag "value"` parsing) to supply a credential value
directly instead of looking one up by name. If **both** are given, `$4`
(testUser) is not needed at all — skip prompting/validating it entirely and
use the two literal values as-is. If only one of the two is given, `$4`
still resolves/validates normally and supplies whichever credential wasn't
given literally.

## 1. Resolve missing arguments

- If `flow_name` is missing:
  1. Print exactly: `Which flow would you like to run?`
  2. Discover and display flows using the same logic as `/list_flow` (glob `flow/*.md` + `tests/**/*.md`, name = filename without `.md`, rendered as the same markdown table).
  3. Wait for the user's choice before continuing.
- If `apk_name` is missing:
  1. Print exactly: `Which APK would you like to use?`
  2. List every file directly inside `apk/`, one per line as `- <filename>`.
  3. Wait for the user's choice before continuing.
- If `environment` is missing:
  1. Print exactly: `Which environment — Staging or Production?`
  2. Wait for the user's choice before continuing.
- If `testUser` ($4) is missing, **only prompt for it once `environment` is
  resolved** (its available options depend on which environment's file to
  read), **and only if `--mobile`/`--password` weren't both already given**,
  **and only if that environment's `test-data/<environment>.properties`
  has no `default*` entry**:
  1. Scan that file for every line matching
     `^([A-Za-z0-9]+)MobileNumber[[:space:]]*=`, collecting the captured
     names (excluding `default`, if present).
  2. Print exactly: `Which test user would you like to use for <environment>?`
     followed by the names, one per line as `- <name>`.
  3. Wait for the user's choice before continuing.
  If a `default*` entry does exist for that environment, skip this prompt
  entirely — an omitted `$4` silently uses it, exactly like today.
  Regardless of any of the above, skip this prompt entirely whenever both
  `--mobile` and `--password` were given — nothing about testUser matters
  once literal credentials are supplied.
- If more than one is missing, prompt in this order — flow, then APK, then
  environment, then testUser — one at a time, never combined in the same
  message.

## 2. Validate

- **Flow**: discover flows exactly as `/list_flow` does. Match `flow_name` case-insensitively against a discovered name, accepting it with or without a `flow/`/`tests/` prefix or `.md` suffix.
  - If there's no match, output:

    ```
    Flow "<flow_name>" not found.

    Available flows:

    <same markdown table /list_flow produces>
    ```

    Stop here — do not validate the APK, the environment, or execute.

- **APK**: list files directly inside `apk/`. Match `apk_name` case-insensitively against a filename, with or without the `.apk` extension.
  - If there's no match, output:

    ```
    APK "<apk_name>" not found.

    Available APKs:
    - <file1>
    - <file2>
    ```

    Stop here — do not validate the environment or execute.

- **Environment**: match `environment` case-insensitively against `Staging` or `Production`, accepting the shorthand `stage`/`prod`. Normalize the resolved value to `Staging` or `Production` for everything downstream.
  - If there's no match, output:

    ```
    Environment "<environment>" not recognized.

    Valid environments:
    - Staging
    - Production
    ```

    Stop here — do not validate testUser or execute.

- **testUser** (only if `$4` was actually given, and only if `--mobile`/
  `--password` weren't both already given — an omitted `$4` that fell
  through the "has a `default*` entry" check in step 1, or that's moot
  because both credential flags were supplied, needs no validation):
  scan `test-data/<environment-lowercase>.properties` for every line
  matching `^([A-Za-z0-9]+)MobileNumber[[:space:]]*=`, match `testUser`
  case-insensitively against the captured names (excluding `default`).
  - If there's no match, output:

    ```
    Test user "<testUser>" not found for <environment>.

    Available test users:
    - <name1>
    - <name2>
    ```

    Stop here — do not execute.
  - On a match, resolve to the canonical-case name as it actually appears
    in the file (not necessarily what the user typed).

## 3. Execute

Once every given/required argument is valid, print:

```
Running flow "<flow_name>" using APK "apk/<apk_name>" against <environment>...
```

or, if a testUser was resolved (given explicitly or via the step-1 prompt):

```
Running flow "<flow_name>" using APK "apk/<apk_name>" against <environment> as "<testUser>"...
```

or, if `--mobile`/`--password` were given (either or both):

```
Running flow "<flow_name>" using APK "apk/<apk_name>" against <environment> with the given credentials...
```

Then actually run it, reusing existing project mechanisms rather than hand-rolled commands:

1. Prepare the environment and install the build via the `launchApplication` skill, passing the resolved absolute path to `apk/<apk_name>`.
2. Drive the resolved flow doc (`flow/<flow_name>.md` or the matching `tests/<category>/<flow_name>.md`) by delegating to the `flow-runner` agent, passing along the resolved `environment` value and whichever of `testUser`/`mobile`/`password` were resolved — `flow-runner` threads all of these through as `--environment`/`--test-user`/`--mobile`/`--password` on every `run-plan` call it makes, which is how a plan's `${mobileNumber}`/`${password}`/`${userCode}` tokens get resolved, either against `test-data/<environment>.properties` or directly from the literal values (see `compilePlan` SKILL.md's "Credential tokens" section). `flow-runner` handles the compiled-plan lifecycle itself (`compilePlan`'s `check` → compile on a cache miss, same process as the `flow-compiler` agent → deterministic `run-plan` → scoped local recovery on divergence) — nothing extra to orchestrate here. Any step in the plan that selects the in-app Staging/Production toggle (see `flow/loginFlow.md`) uses this `environment` value; steps unrelated to login ignore it. This includes `report_tool.sh start`/`end` around the run — see `generateReport`'s SKILL.md.
   - Alternatively, to warm the cache for many flows ahead of time without driving the app (e.g. before a batch of `/run` calls), invoke the `flow-compiler` agent directly per flow first — `flow-runner` will then see `PLAN_STATUS=HIT` and skip straight to execution.
3. Report the per-step pass/fail result back to the user in chat.
4. Always generate and save the run report — HTML only — regardless of pass/fail/partial — this is automatic, not conditional on the user asking. Hand off to the `report-writer` agent (or follow `generateReport`'s SKILL.md yourself) with: the flow/test doc path, its precondition if any, the per-step/per-assertion results from step 2, and the full `START=`/`END=`/`DURATION=`/`TOKENS_*` output of `report_tool.sh end`. `report-writer` creates `execution/report/` if needed and writes the file — report the saved path back to the user alongside the chat summary from step 3.
5. Always tear down afterward — this is standard, not optional: close the Appium session (`appium_action.sh close-session`), then uninstall the app and stop the emulator/Appium server via `.claude/skills/launchApplication/scripts/close_environment.sh` (or delegate to the `env-manager` agent). Do this after step 4, once the report is saved.
