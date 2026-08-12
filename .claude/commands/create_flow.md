---
description: Author a new flow end-to-end from a screenshots folder — writes flow/<name>.md, then drives it live against an already-running environment to build and validate execution-plans/, and reports it ready for /run.
argument-hint: <screenshots-folder> ["precondition"] [--precondition "..."] [--steps "1. ... 2. ..."] [--notes "..."] [--title "..."] [--tags "a, b, c"]
---

# Create a new flow

Turns a folder of ordered screenshots into a fully working flow, in one shot:

```
Screenshots  →  Flow doc (flow/<name>.md)  →  Live-driven, validated plan (execution-plans/<name>.*)  →  Ready for /run
```

This command writes documentation (same posture as the `flow-documenter`
agent it delegates to for step 4), then actually drives the new flow once
against a live, already-running environment (delegating to `flow-runner`,
the same agent `/run` uses) to compile and validate its execution plan —
a plan built and proven against the real app the first time, rather than
only guessed from screenshots, so it replays cleanly on every future `/run`
without needing a first-run recovery pass. It requires an environment to
already be running (see step 5) and never launches or tears one down itself.
It never modifies an existing flow doc; it only creates new ones.

## 1. Parse arguments

`$ARGUMENTS` is the raw text after `/create_flow`.

1. **Screenshots folder (mandatory)** — the first token. Strip a leading
   `@`, surrounding `[...]`, and surrounding quotes, in whatever combination
   they appear (`@["screenshots or figma Links/Login Flow"]`,
   `"screenshots or figma Links/Login Flow"`, or the bare path all work the
   same way once stripped). This is the resolved **screenshots folder path**.
   If nothing is left after the first token is stripped, or the token is
   empty, do not stop with a usage error — ask instead, the same way `/run`
   asks for a missing argument:
   1. Print exactly: `Which screenshots folder would you like to use?`
   2. Wait for the user's answer before continuing.
   3. Strip the answer the same way (leading `@`, surrounding `[...]`/quotes).
      If it's still empty after stripping, repeat the question and wait again.
2. **Everything after the first token** is optional. Parse it as:
   - If it starts with `--`, parse `--precondition "..."`, `--steps "..."`,
     `--notes "..."`, `--title "..."`, `--tags "a, b, c"` (accept comma- or
     space-separated tags either way). Any combination/order is fine;
     unrecognized flags are a hard error — report which flag wasn't
     understood and stop.
   - Otherwise, if the trailing text is a **multi-point numbered narrative**
     (two or more segments matching `<number>. ...`, e.g. "1. ... 2. ...") —
     even with no `--` flag in front of it — treat it as shorthand for
     `--steps`, not `--precondition`. This is the user dictating the flow's
     actual steps/actions/assertions in prose; a precondition is a short
     one-line phrase, never a numbered walkthrough. See "Handling `steps`"
     under step 4 below for how this changes the rest of the command.
   - Otherwise, if there's a single bare quoted (or unquoted) string with no
     `--` flags at all, treat it as shorthand for `--precondition` (matches
     the second usage example in the spec).
   - If nothing follows the first token, all optional fields are unset.
3. Defaults: `precondition` → `"None"` if unset. `steps` → unset (falls back
   to pure screenshot-driven authoring, see step 4). `notes` → unset (omit
   the section entirely). `title` → unset (derived in step 3 below). `tags`
   → unset (omit the tags line entirely).

## 2. Validate the screenshots folder

1. Confirm the folder exists and lives under `screenshots or figma Links/`
   (this is where every existing flow's screenshots live, and it's the path
   `flow-documenter`/`flow-compiler` will embed into the doc). If it doesn't
   exist:
   ```
   Screenshots folder not found: "<path>"
   ```
   Stop here.
2. List the folder's contents. If it's empty:
   ```
   Screenshots folder "<path>" is empty — nothing to document.
   ```
   Stop here.
3. Identify every file matching `Step <N>.<ext>` (case-insensitive on
   `Step`). For each:
   - **Unsupported format** — `<ext>` not one of `png`/`jpg`/`jpeg`: report
     `Unsupported image format: "<filename>" (only .png/.jpg/.jpeg are supported)` and stop.
   - **Duplicate step** — more than one file resolves to the same `N` (e.g.
     `Step 2.png` and `Step 2.jpg` both present): report
     `Duplicate screenshot for Step <N>: "<file1>" and "<file2>"` and stop.
   - Files in the folder that don't match `Step <N>.<ext>` at all are
     ignored (not an error) but not treated as steps.
4. Sort the matched steps numerically. If numbering doesn't start at 1 or
   has a gap (e.g. `Step 1`, `Step 3`, no `Step 2`): report
   `Missing screenshot in sequence: expected "Step <N>.<ext>", found none` and stop.
5. This gives you the ordered screenshot list and step count to hand to
   `flow-documenter`.

## 3. Resolve title, flow name, and output path

1. **Title** — `--title` if given; otherwise the screenshots folder's own
   basename (e.g. `"screenshots or figma Links/Login Flow"` → `"Login Flow"`).
2. **Flow name** — derive camelCase from the title, matching this project's
   existing convention (`"Login Flow"` → `loginFlow`, `"GPS Listing Flow"` →
   `gpsListingFlow`, matching the real `flow/gpsListingFlow.md`):
   - Split the title into alphanumeric-run words.
   - First word: lowercase entirely.
   - Every subsequent word: uppercase its first character, lowercase the rest.
   - Concatenate with no separators or spaces.
   - If this produces an empty string, report `Could not derive a flow name from title "<title>"` and stop.
3. **Output markdown path** is always `flow/<flowName>.md` (this command
   only authors screen-level flow docs, not `tests/*.md` end-to-end docs).
4. **Collision check** — discover existing flow names exactly as `/list_flow`
   does (`flow/*.md` + `tests/**/*.md`, filename without `.md`, matched
   case-insensitively). If `<flowName>` already exists anywhere in that set:
   ```
   Flow "<flowName>" already exists at <existing path>.
   /create_flow never overwrites an existing flow doc — pick a different --title, or remove/rename the existing doc yourself first.
   ```
   Stop here. Do not proceed to writing anything.

## 4. Write the flow doc (delegates to `flow-documenter`)

Invoke the `flow-documenter` agent (foreground — later steps depend on its
result) with the target path and every screenshot discovered in step 2, plus:

- Follow the exact established format in `flow/loginFlow.md`,
  `flow/homePage.md`, `flow/gpsListingFlow.md` — one `## Step N: <title>`
  section per screenshot, screenshot reference, **Assertions** list of
  `contains "..."` using only text actually visible in that screenshot. Use
  `<title>` (from step 3) as the `# <Flow Name>` heading.
- If `precondition` is anything other than `"None"`: add a `## Precondition`
  section right after the intro paragraph (same heading/placement already
  used in `tests/VerifyGpsListing.md`), containing exactly the supplied text.
  If it's `"None"`, still write the section with the literal body `None` (per
  this command's spec) rather than omitting it.
- If `notes` was supplied: add a `## Notes` section after the last step,
  containing exactly the supplied text, and note in that section's first
  line that these are internal authoring notes, not assertions or execution
  steps — nothing in `## Notes` should ever be read as something to tap or
  assert.
- If `tags` was supplied: add one line directly under the `# <Flow Name>`
  heading: `**Tags:** tag1, tag2, ...`.
- Never invent on-screen text, steps, or elements beyond what's visible in
  the screenshots — same hard rule the agent already follows. This default
  changes when `steps` was supplied — see immediately below.
- **If the user's narrative (`--steps`/`--notes`, or free text in this
  conversation) includes a raw `curl` command, it never gets pasted into
  `flow/<flowName>.md`.** Route it through `api/` instead, the same way
  `flow/gpsListingFlow.md` handles `getAllFilterCount`/`vehiclesStatic` — add
  the path to `api/environments/<env>/paths.md`, any new headers to
  `headers.md`, the curl itself to `api/curl-reference.md`, a response-shape
  doc to `api/contracts/<key>.md`, and write only `CALL_API <key>` (plus
  `IF api.x ... ENDIF` if the narrative branches on the response) into the
  step being authored. See CLAUDE.md's "API-driven execution" section.

**Handling `steps` (a user-supplied narrative takes priority over screenshot content):**
If `steps` was supplied, it — not the screenshots — is the source of truth
for which steps exist and what each step's actions/assertions are. Tell
`flow-documenter` explicitly:
- Write one `## Step N` section per point in the narrative (not one per
  screenshot file — the two counts do not need to match; a narrative often
  describes transient states, like a validation error, that no screenshot
  captures).
- Screenshots are now visual reference only, used solely to confirm layout
  and element naming where a narrative step's resulting screen happens to
  line up with one — reference that screenshot on that step. Do not pull
  on-screen text/content from a screenshot to add or override anything the
  narrative didn't say, and do not drop a narrative step just because no
  screenshot shows that state.
- Do not hardcode incidental dynamic values that only happen to appear in a
  screenshot (a specific test phone number, a specific balance figure, etc.)
  unless the narrative itself specified that literal value — refer to it
  generically instead (e.g. "the entered phone number").
- Any assertion text that comes only from the narrative and isn't
  independently confirmed by a screenshot (e.g. exact error-message
  wording for a state no screenshot shows) must be marked provisional
  inline in that step, noting it will be verified/corrected against the
  live app during step 5's live compile pass — never presented as
  screenshot-confirmed text it isn't.
- The existing "never invent on-screen text" hard rule still applies to
  content *not* covered by the narrative — `flow-documenter` shouldn't
  embellish beyond what the user described or what a screenshot shows.

If `steps` was not supplied, fall back to the original behavior: derive
steps/actions/assertions purely from the screenshots, one `## Step N` per
screenshot file, exactly as documented above.

Wait for it to finish and confirm the file was written to `flow/<flowName>.md`
before continuing. If it reports it couldn't produce a doc (e.g. an
unreadable image), treat that as a compilation-blocking failure: report
```
Flow document generation failed: <reason>
```
and stop — do not proceed to compilation.

## 5. Compile the plan by driving it live (delegates to `flow-runner`)

Do not wait for a future `/run` to trigger this, and do not build the plan
by only re-reading the doc/screenshots — drive the newly-written flow live,
once, so the plan that lands on disk is proven against the real app rather
than guessed.

1. **Require a live environment.** Check for one the same way the rest of
   this repo does (e.g. `.claude/skills/launchApplication/.last_install_state`
   plus an actually-reachable Appium session — the same liveness check
   `flow-runner`/`env-manager` already rely on). If nothing is running:
   ```
   No live environment found — /create_flow drives the new flow live to build a validated plan.
   Launch one first (env-manager agent, or launchApplication's launch_environment.sh <apk>), then re-run /create_flow.
   ```
   Stop here. The flow doc from step 4 still exists on disk (don't delete
   it), but do not claim the flow is ready for `/run`. `/create_flow` never
   launches or swaps the environment itself — it only ever reuses one that's
   already up, exactly like `flow-runner` does for `/run`.
2. **Satisfy the doc's own Precondition first, live**, if it has one other
   than `None` (e.g. a precondition that says to complete `flow/loginFlow.md`
   first) — this is `flow-runner`'s Step 0 (see
   `.claude/agents/flow-runner.md`): if the referenced flow doc already has
   a valid compiled plan, run that plan (`run-plan`) rather than re-reading
   its markdown; only compile it first if it doesn't have one yet. Never
   re-derive or duplicate the referenced flow's steps into the new flow's
   own plan.
3. Invoke the `flow-runner` agent (foreground) to walk `flow/<flowName>.md`
   live, step by step, **before** any plan.json/meta.json is written —
   for a brand-new flow there is no prior plan to replay, so this is not
   "guess a plan, then execute it, then patch what's wrong." Instead, for
   each step in order: perform that step's action against the live app
   (via `appium_action.sh` — `tap`/`type`/`scroll`/etc., driven off the
   doc's description of what to do), then read the *actual* live UI state
   (`source`/`find`/`contains`) to confirm the real `content-desc`/selector
   text and to check the doc's assertions for that step actually hold. Only
   once every step has been walked this way — so every action's selector
   and every assertion has been confirmed against real, live accessibility
   data, not inferred from a screenshot image — call
   `.claude/skills/compilePlan/scripts/plan_tool.sh write <flowName>` a
   single time with the now-verified steps (resolving `appPackage`/
   `appActivity`/`appVersion` from
   `.claude/skills/launchApplication/.last_install_state` or `aapt`). This
   is what makes future `/run`s of this flow fast: `run-plan` replays
   selectors that are already known-good from this live pass, instead of
   discovering they're wrong on the first real run and needing a recovery
   pass then. Do not have `flow-runner` touch environment lifecycle (no
   launch/teardown) — that's out of scope for this command.
4. Report back the per-step pass/fail `flow-runner` observed. If any step
   still fails after local recovery (a genuine mismatch between the doc and
   the live app, not just a one-time selector drift), that's a
   compilation-blocking failure:
   ```
   Execution plan compilation failed: <reason — include which step(s) failed and why>
   ```
   Stop here — do not report the flow ready for `/run` with known-failing
   steps. The doc and whatever plan state exists remain on disk for a human
   to fix.

## 6. Validate the generated plan

Once `flow-runner` returns from the live run, cross-check its output before
declaring success — this is a real check, not a formality:

1. Run `.claude/skills/compilePlan/scripts/plan_tool.sh check <flowName>`.
   Expect `PLAN_STATUS=HIT` (a plan that was just written should immediately
   hash-match itself). `MISS` here is itself a validation failure — report it
   verbatim and stop.
2. Read `execution-plans/<flowName>.plan.json` and `flow/<flowName>.md` and confirm:
   - **Every markdown step exists in the plan** — the number of `## Step N`
     sections in the doc matches the number of entries in `plan.steps`.
   - **Every screenshot referenced exists** — each step's screenshot path
     from the markdown resolves to a real file on disk (already true from
     step 2, but re-confirm against what actually landed in `docs`/
     `screenshots` in `execution-plans/<flowName>.meta.json`).
   - **Every assertion was extracted** — each step's `assertions` array is
     non-empty, OR the step carries a `notes` field explaining why it's
     empty (the one case `flow-compiler` is allowed to leave it empty).
   - **Every action has a valid execution strategy** — each step's `action`
     is `null`, or an object/array of objects whose `type` is one of
     `tap`/`type`/`back`/`scroll`/`scroll-to`/`wait-for`/`wait-until-gone`/
     `double-tap`/`long-press`, with a `selector` present for any type that
     needs one (i.e. everything except `back`/`scroll`, which act on the
     whole screen rather than one element).
   - **Every step actually passed live** — cross-check against `flow-runner`'s
     step- pass/fail report from step 5.4: a structurally valid plan whose
     live run still failed a step (even after recovery) is not a pass.
3. If any of these checks fail, do not report success. Report exactly what
   failed (which step, which check) and stop — per this command's design,
   silently producing an invalid or unproven plan is not acceptable. The doc
   and whatever plan was written remain on disk for a human to fix (re-run
   `/create_flow`'s live-drive step manually via the `flow-runner` agent, or
   correct the doc/screenshots and re-drive) rather than being deleted.

## 7. Success output

Once every check in step 6 passes, report:

```
✓ Flow document created
  Location: flow/<flowName>.md

✓ Execution plan created
  Location: execution-plans/<flowName>.plan.json (+ .meta.json)

Summary:
- Screens analysed: <screenshot count>
- Steps generated: <step count>
- Assertions generated: <total assertion count across all steps>
- Plan compiled: version <planVersion from meta.json>
- Ready to execute using /run <flowName> <apk>
```

No manual steps should remain before `/run <flowName> <apk>` works.

## Notes on this implementation

- Metadata (flow name, doc hash, screenshot hashes, generated timestamp,
  schema version) is exactly what `execution-plans/<flowName>.meta.json`
  already stores via `plan_tool.sh write` — no second metadata file or log
  file is created; the chat output above (and `flow-runner`'s own
  report-back) serves that purpose.
- This command only ever creates `flow/<flowName>.md` — it never edits an
  existing doc, never touches `tests/**`, and never changes `/list_flow`'s
  behavior.
- This command drives the live app exactly once, during step 5, to compile
  and validate the plan — it requires a pre-existing running environment and
  never launches, swaps, or tears one down itself (that stays entirely
  `/run`'s and `env-manager`'s job).
