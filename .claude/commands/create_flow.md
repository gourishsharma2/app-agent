---
description: Author a new flow end-to-end from a screenshots folder — writes flow/<name>.md, immediately compiles it to execution-plans/, validates the result, and reports it ready for /run.
argument-hint: <screenshots-folder> ["precondition"] [--precondition "..."] [--notes "..."] [--title "..."] [--tags "a, b, c"]
---

# Create a new flow

Turns a folder of ordered screenshots into a fully working flow, in one shot:

```
Screenshots  →  Flow doc (flow/<name>.md)  →  Compiled plan (execution-plans/<name>.*)  →  Ready for /run
```

This command never drives the live app — it only writes documentation and a
compiled plan, the same posture as the `flow-documenter` and `flow-compiler`
agents it delegates to. It never modifies an existing flow doc; it only
creates new ones.

## 1. Parse arguments

`$ARGUMENTS` is the raw text after `/create_flow`.

1. **Screenshots folder (mandatory)** — the first token. Strip a leading
   `@`, surrounding `[...]`, and surrounding quotes, in whatever combination
   they appear (`@["screenshots or figma Links/Login Flow"]`,
   `"screenshots or figma Links/Login Flow"`, or the bare path all work the
   same way once stripped). This is the resolved **screenshots folder path**.
   If nothing is left after the first token is stripped, or the token is
   empty, stop and report:
   ```
   Usage: /create_flow <screenshots-folder> ["precondition"] [--precondition "..."] [--notes "..."] [--title "..."] [--tags "a, b, c"]
   The screenshots folder is mandatory.
   ```
2. **Everything after the first token** is optional. Parse it as:
   - If it starts with `--`, parse `--precondition "..."`, `--notes "..."`,
     `--title "..."`, `--tags "a, b, c"` (accept comma- or space-separated
     tags either way). Any combination/order is fine; unrecognized flags are
     a hard error — report which flag wasn't understood and stop.
   - Otherwise, if there's a single bare quoted (or unquoted) string with no
     `--` flags at all, treat it as shorthand for `--precondition` (matches
     the second usage example in the spec).
   - If nothing follows the first token, all optional fields are unset.
3. Defaults: `precondition` → `"None"` if unset. `notes` → unset (omit the
   section entirely). `title` → unset (derived in step 3 below). `tags` →
   unset (omit the tags line entirely).

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
  the screenshots — same hard rule the agent already follows.

Wait for it to finish and confirm the file was written to `flow/<flowName>.md`
before continuing. If it reports it couldn't produce a doc (e.g. an
unreadable image), treat that as a compilation-blocking failure: report
```
Flow document generation failed: <reason>
```
and stop — do not proceed to compilation.

## 5. Compile the plan immediately (delegates to `flow-compiler`)

Do not wait for a future `/run` to trigger this. Invoke the `flow-compiler`
agent (foreground) on `flow/<flowName>.md`, exactly as it would compile any
other flow doc — reading the doc + every screenshot once, deriving
steps/actions/`screenMarker`/assertions, resolving `appPackage`/`appActivity`/
`appVersion` from `.claude/skills/launchApplication/.last_install_state` (or
`aapt` if needed), and calling
`.claude/skills/compilePlan/scripts/plan_tool.sh write <flowName>`. This
writes `execution-plans/<flowName>.plan.json` and
`execution-plans/<flowName>.meta.json` — this repo's actual compiled-plan
format (see `.claude/skills/compilePlan/SKILL.md`). No new file layout is
introduced here.

If `flow-compiler` reports it could not resolve an app version (no APK ever
installed) or any other blocking issue, report:
```
Execution plan compilation failed: <reason>
```
and stop — the flow doc from step 4 still exists on disk (don't delete it),
but do not claim the flow is ready for `/run`.

## 6. Validate the generated plan

Once `flow-compiler` returns, cross-check its output before declaring
success — this is a real check, not a formality:

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
     needs one (i.e. everything except `back`).
3. If any of these checks fail, do not report success. Report exactly what
   failed (which step, which check) and stop — per this command's design,
   silently producing an invalid plan is not acceptable. The doc and
   whatever plan was written remain on disk for a human to fix (re-run
   `/create_flow`'s compile step manually via the `flow-compiler` agent, or
   correct the doc/screenshots and recompile) rather than being deleted.

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
  file is created; the chat output above (and `flow-compiler`'s own
  report-back) serves that purpose.
- This command only ever creates `flow/<flowName>.md` — it never edits an
  existing doc, never touches `tests/**`, never changes `/run`'s or
  `/list_flow`'s behavior, and never drives the live app.
