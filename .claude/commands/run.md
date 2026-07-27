---
description: Execute a documented flow against an APK from apk/, prompting for whichever of flow_name/apk_name is missing and validating both before running.
argument-hint: [flow_name] [apk_name]
---

# Run a flow

Arguments: `$1` = flow_name (optional), `$2` = apk_name (optional).

## 1. Resolve missing arguments

- If `flow_name` is missing:
  1. Print exactly: `Which flow would you like to run?`
  2. Discover and display flows using the same logic as `/list_flow` (glob `flow/*.md` + `tests/**/*.md`, name = filename without `.md`, rendered as the same markdown table).
  3. Wait for the user's choice before continuing.
- If `apk_name` is missing:
  1. Print exactly: `Which APK would you like to use?`
  2. List every file directly inside `apk/`, one per line as `- <filename>`.
  3. Wait for the user's choice before continuing.
- If both are missing, prompt for the flow first, then the APK, one at a time — never ask both in the same message.

## 2. Validate

- **Flow**: discover flows exactly as `/list_flow` does. Match `flow_name` case-insensitively against a discovered name, accepting it with or without a `flow/`/`tests/` prefix or `.md` suffix.
  - If there's no match, output:

    ```
    Flow "<flow_name>" not found.

    Available flows:

    <same markdown table /list_flow produces>
    ```

    Stop here — do not validate the APK or execute.

- **APK**: list files directly inside `apk/`. Match `apk_name` case-insensitively against a filename, with or without the `.apk` extension.
  - If there's no match, output:

    ```
    APK "<apk_name>" not found.

    Available APKs:
    - <file1>
    - <file2>
    ```

    Stop here — do not execute.

## 3. Execute

Once both are valid, print:

```
Running flow "<flow_name>" using APK "apk/<apk_name>"...
```

Then actually run it, reusing existing project mechanisms rather than hand-rolled commands:

1. Prepare the environment and install the build via the `launchApplication` skill, passing the resolved absolute path to `apk/<apk_name>`.
2. Drive the resolved flow doc (`flow/<flow_name>.md` or the matching `tests/<category>/<flow_name>.md`) via the `driveFlow` skill (or delegate to the `flow-runner` agent), checking each step's Assertions as usual. This includes `report_tool.sh start`/`end` around the run — see `generateReport`'s SKILL.md.
3. Report the per-step pass/fail result back to the user in chat.
4. Always generate and save the run report — HTML only — regardless of pass/fail/partial — this is automatic, not conditional on the user asking. Hand off to the `report-writer` agent (or follow `generateReport`'s SKILL.md yourself) with: the flow/test doc path, its precondition if any, the per-step/per-assertion results from step 2, and the full `START=`/`END=`/`DURATION=`/`TOKENS_*` output of `report_tool.sh end`. `report-writer` creates `execution/report/` if needed and writes the file — report the saved path back to the user alongside the chat summary from step 3.
