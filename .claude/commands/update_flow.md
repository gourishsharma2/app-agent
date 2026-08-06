---
description: Update an existing flow doc (and its compiled plan) with partial, possibly out-of-sequence step changes — drafts the update, live-verifies it, then requires the user to Accept/Reject/Modify before anything on disk changes.
argument-hint: <flow_name> [screenshots-folder] [--steps "1. ... 3. insert: ... 5. remove"]
---

# Update an existing flow

Updates an already-existing `flow/<name>.md` (or `tests/**/<name>.md`) doc
and its compiled plan (`execution-plans/<name>.*`) to reflect specific step
changes the user describes — which may be a partial subset of the doc's
steps, given in any order, not necessarily starting at step 1 and not
necessarily covering every step. Nothing is written to `flow/`,
`tests/**`, or `execution-plans/` until the user explicitly **Accepts** a
drafted preview. This is the mirror-image, update-only counterpart to
`/create_flow` (see `.claude/commands/create_flow.md`): that command only
ever creates a brand-new doc and refuses to touch an existing one; this one
only ever touches an existing doc and never creates a new one.

```
Existing doc + plan  →  Draft doc + draft plan (live-verified, not yet saved)  →  Accept/Reject/Modify  →  Saved (or discarded)
```

Delegates doc drafting to `flow-documenter` and live verification to
`flow-runner` — same agents `/create_flow` uses — but both operate on a
**scratch draft**, never the real files, until the user accepts. It
requires an environment to already be running (same posture as
`/create_flow`) and never launches or tears one down itself.

## 1. Parse arguments

`$ARGUMENTS` is the raw text after `/update_flow`.

1. **Flow name (mandatory)** — the first token, stripped of surrounding
   quotes/`@`/`[...]` the same way `/run`/`/create_flow` do. If nothing is
   left, stop and report:
   ```
   Usage: /update_flow <flow_name> [screenshots-folder] [--steps "1. ... 3. insert: ... 5. remove"]
   The flow name is mandatory.
   ```
2. **Everything after the first token** is optional, parsed the same
   flag-aware way as `/run`/`/create_flow`:
   - `--steps "..."` — the step-change narrative (see "Parsing the step
     changes" below). A bare multi-point numbered narrative with no `--`
     flag in front of it (two or more `<number>. ...` segments) is
     shorthand for `--steps`, exactly like `/create_flow`.
   - A bare token with no `--` flags and no numbered-narrative shape is
     shorthand for the **screenshots folder** instead.
   - Both may be given together, in either order.
3. If neither a screenshots folder nor `--steps` was given, stop and report:
   ```
   Nothing to update — give either an updated screenshots folder or --steps describing what changed.
   ```

## 2. Validate the flow exists

Discover flows exactly as `/list_flow`/`/run` do (`flow/*.md` +
`tests/**/*.md`, case-insensitive match, with/without `flow/`/`tests/`
prefix or `.md` suffix). If there's no match:

```
Flow "<flow_name>" not found — /update_flow only edits an existing flow.

Available flows:

<same markdown table /list_flow produces>
```

Stop here. (Use `/create_flow` instead if this is meant to be a new flow.)

If a screenshots folder was given, validate it the same way `/create_flow`
step 2 does (must exist under `screenshots or figma Links/`, non-empty,
files matching `Step <N>.<ext>` with `png`/`jpg`/`jpeg` only, no duplicate
step numbers) — same error messages, same stop-here behavior on failure.

## 3. Read current state

Read the full current doc (`flow/<flowName>.md` or the matched
`tests/<category>/<flowName>.md`) and, if it exists,
`execution-plans/<flowName>.plan.json` + `.meta.json`. Note the doc's
current step count and titles — this is the baseline every change below is
computed against.

## 4. Parse the step changes

If `--steps` was given, split it into numbered points (`<N>. <text>`,
regardless of the order they appear in the argument text — sort by `N`
before doing anything else). Each point is one of three kinds, by its text:

- **Update** (default) — `<N>. <description>` where `N` matches an
  **existing** step number in the current doc. Replaces that step's
  action/description/assertions with the new description. The narrative
  is the source of truth for this step's content, same rule as
  `/create_flow` (screenshots are visual reference only — see
  [[feedback_create_flow_screenshots_reference_only]]) — never let a
  screenshot's text override or narrow what the user described for that
  step.
- **Insert** — `<N>. insert: <description>` — adds a **new** step at
  position `N`, shifting the existing step `N` and every step after it
  down by one (renumbered). `N` may be `<current step count> + 1` to mean
  "append at the end." If no `Step <N>.<ext>` file for this position exists
  in the screenshots-folder argument (or no screenshots folder was given at
  all), the new step gets **no image reference** — write it exactly like a
  narrative-only negative-path step in `/create_flow`
  ([[feedback_create_flow_screenshots_reference_only]]), never a fabricated
  or borrowed screenshot link.
- **Remove** — `<N>. remove` (no further text needed) — deletes existing
  step `N` entirely, shifting every later step up by one (renumbered).

**Screenshot files on disk, not just doc text, follow the same
renumbering.** An `insert`/`remove` shifts which step number every *later*
step's screenshot corresponds to — e.g. inserting a new step 3 means the
old `Step 3.png`...`Step 6.png` files must become `Step 4.png`...`Step
7.png` to stay aligned with the doc's renumbered `## Step N` sections and
image links. This physical rename happens only at Accept time (step 8), on
the real `screenshots or figma Links/<flowName>/` folder, never on the
scratch draft — draft image links in step 5 should reference each
screenshot's *final, post-renumbering* filename so the diff shown in step 7
already reflects what the rename will produce, but the actual `mv` waits
for Accept like every other real-file change.

Validation, before drafting anything:

- **Unknown/ambiguous number** — an `update`-style point whose `N` doesn't
  match any existing step and isn't exactly "append" (`count + 1`): stop
  and report
  ```
  Step <N> doesn't exist in <flow_name> (it has <count> steps) — use "<N>. insert: ..." if you mean to add a new step there.
  ```
- **Duplicate reference** — two points naming the same `N`: stop and
  report `Step <N> was referenced more than once — combine them into a single point.`
- Apply insert/remove points in ascending `N` order, renumbering as you go,
  so later points' `N` values in the *original* numbering still resolve
  correctly (compute all target positions against the original doc first,
  then apply structurally — don't let an earlier insert silently shift the
  meaning of a later point's `N`).

If `--steps` was **not** given (screenshots-folder-only update): there is
no per-step change-set to compute — instead, tell `flow-documenter` to
re-derive the whole doc from the new screenshots and correct any step
whose content no longer matches what the screenshots show, exactly as
`flow-documenter`'s own "if told the app differs from an existing doc"
behavior already does. Skip straight to step 5 with this framing instead
of a change-set.

If a screenshots folder was also given alongside `--steps`: any `Step
<N>.<ext>` file in it is visual reference only for that step number's
*update*/`insert` point (per the narrative-priority rule above) — never a
replacement source of truth for that step's text.

## 5. Draft the updated doc (scratch copy — never the real file)

Invoke `flow-documenter` to produce the **full** updated doc content and
write it to a scratch path, not `flow/<flowName>.md` itself — use this
session's scratchpad directory (e.g.
`<scratchpad>/update_flow/<flowName>.md`), so nothing under version control
changes yet. Give it:

- The full current doc content (so it can carry forward every untouched
  step byte-for-byte — this is an update, not a rewrite from scratch).
- The parsed change-set from step 4 (or the "re-derive from screenshots"
  framing if `--steps` was omitted).
- The same format rules `/create_flow` gives it: one `## Step N:` section
  per step in the final numbering, `![Step N](<../screenshots or figma
  Links/<flowName>/Step N.png>)` image references, `**Assertions:**` list
  of `contains "..."`.
- For an `insert`ed step whose new screenshot came from the
  screenshots-folder argument: reference that new image's eventual path
  (`../screenshots or figma Links/<flowName>/Step <N>.<ext>`) — the actual
  file copy into that canonical folder only happens on Accept (step 8),
  never during drafting.
- Renumber every `## Step N`/image reference/precondition mention
  consistently if any insert/remove shifted step numbers.
- Mark any assertion text that comes only from the narrative (not
  independently confirmable from an existing or new screenshot) as
  provisional, to be proven/corrected during step 6's live pass — same
  convention as `/create_flow`.

Wait for it to confirm the scratch file was written before continuing.

## 6. Require a live environment, then live-verify the entire draft

Same liveness check as `/create_flow` step 5.1 — if nothing is running:

```
No live environment found — /update_flow live-verifies the draft before showing it to you.
Launch one first (env-manager agent, or launchApplication's launch_environment.sh <apk>), then re-run /update_flow.
```

Stop here. The scratch draft from step 5 is discarded (nothing real was
touched); re-running after launching an environment starts over cleanly.

Otherwise, invoke `flow-runner` to walk the **scratch draft doc** live,
step by step, from Step 1 — same mechanism as `/create_flow` step 5.3
(perform each step's action against the live app, then read live
`source`/`find`/`contains` to confirm the real selector text and check
that step's assertions actually hold) — walking every step of the draft,
not just the ones that changed, since a change to one step can silently
break an unrelated later step's starting assumptions and this is exactly
the kind of regression an update should catch before it's saved.

**Critical difference from `/create_flow` and from `flow-runner`'s normal
recovery behavior: do not call `plan_tool.sh write` or `patch` during this
step.** Instruct `flow-runner` explicitly to return the fully-verified step
JSON array (one object per step, same shape as the plan schema in
`.claude/skills/compilePlan/SKILL.md`) as its report-back instead of
persisting anything — this run's entire purpose is to produce a *draft*
plan for the user to review, and nothing is real until step 8's Accept.

If any step fails to verify (even after `flow-runner`'s normal local
investigation — XML-only, no retrying with different content than what the
draft doc actually says), stop here and report it as a blocking failure,
the same posture as `/create_flow` step 5.4:

```
Update verification failed at Step <N>: <reason>
```

Do not proceed to step 7 with a known-broken draft — there is nothing safe
to offer for Accept. The scratch draft remains on disk for reference; the
real doc/plan are untouched. The user can re-run `/update_flow` with a
corrected `--steps` description once they've seen why it failed.

## 7. Show the draft and ask Accept / Reject / Modify

Once every step verifies live, show the user:

1. A **diff** between the current real doc and the scratch draft — old vs.
   new text for every changed/inserted/removed step (unchanged steps: just
   note "unchanged" rather than repeating their full text).
2. A **plan diff** — for each step whose `action`/`screenMarker`/
   `assertions` differ from the current `execution-plans/<flowName>.plan.json`
   (or that's new/removed), show old vs. new JSON for that step only.

Then ask the user to choose, exactly:

- **Accept** — save both files as drafted.
- **Reject** — discard the draft, make no changes at all.
- **Modify** — describe further changes before saving.

Use `AskUserQuestion` with these three options (plus whatever "Other" the
tool provides automatically).

## 8. Accept

1. Overwrite `flow/<flowName>.md` (or the matched `tests/**` path) with the
   scratch draft's content.
2. Reconcile `screenshots or figma Links/<flowName>/` with the final
   numbering — this is the one point where screenshot files themselves
   move, and it's the only step that touches that folder:
   - For every existing screenshot whose step number shifted (because an
     `insert`/`remove` came before it), rename it to its new number. Do
     the renames in an order that never overwrites a file still needed:
     shifting numbers **up** (after an insert) — rename starting from the
     **highest** existing number downward; shifting numbers **down**
     (after a remove) — rename starting from the **lowest** affected
     number upward. When both an insert and a remove are in the same
     update, resolve each affected step's *net* shift first, then apply
     renames in whichever single pass order avoids collisions for that
     net mapping.
   - For any `insert` step whose screenshot came from the
     screenshots-folder argument, copy that image into
     `screenshots or figma Links/<flowName>/Step <N>.<ext>` at its final
     position (after the rename pass above, so it can't collide with a
     shifted file).
   - An `insert` step with no supplied screenshot gets no file here —
     consistent with its doc section having no image reference either.
   - A `remove`d step's own screenshot file is deleted (it no longer
     corresponds to any step).
3. Build the **full** merged step list — every unchanged step's existing
   plan JSON reused as-is, plus every changed/inserted step's
   `flow-runner`-verified JSON from step 6, renumbered to match the final
   doc — and call
   `.claude/skills/compilePlan/scripts/plan_tool.sh write <flowName>` with
   it (a full `write`, not `patch`: the doc itself changed, so hashes must
   be refreshed too, or the very next `check` would report a spurious
   `doc-changed` MISS and force a wasted full recompile on the next `/run`).
4. Delete the scratch draft file.
5. Report:
   ```
   ✓ flow/<flowName>.md updated
   ✓ Execution plan updated — version <planVersion>

   Changes:
   - Step <N>: updated / inserted / removed — <one-line summary>
   ...
   ```

## 9. Reject

Delete the scratch draft file. Make **no** changes to `flow/<flowName>.md`,
any screenshots folder, or `execution-plans/<flowName>.*`. Report:

```
Discarded — <flow_name> and its plan are unchanged.
```

## 10. Modify

Ask the user what to change about the draft just shown (free text). Treat
their answer as a new/amended `--steps` narrative layered on top of the
**current scratch draft** (not the original doc — keep building on the
draft already in progress), re-run step 5 (redraft) for just the
newly-changed points, then step 6 (live-verify — at minimum the
newly-touched steps, and any step after them whose starting state they
affect), then re-show the updated diff and ask Accept/Reject/Modify again
(step 7). Loop until the user picks Accept or Reject — Modify never
persists anything on its own.

## Notes on this implementation

- Mirrors `/create_flow`'s live-verification philosophy
  ([[feedback_create_flow_live_plan]]): a plan is never persisted from
  screenshots/narrative alone, only from a live-proven draft.
- Screenshots are reference-only for whatever a narrative describes, same
  as `/create_flow` ([[feedback_create_flow_screenshots_reference_only]]) —
  this applies to updates exactly as much as to authoring a new doc.
- Never sets `knownNonBug: true` on any step, drafted or persisted — same
  hard rule as `flow-compiler`/`flow-runner`
  ([[feedback_known_non_bug_flag]]); that field only ever changes by a
  human's own explicit, separate instruction.
- The scratch draft never lives under `flow/`, `tests/`, or
  `execution-plans/` — only in this session's scratchpad directory — so a
  Rejected or abandoned update leaves zero trace in the repo.
- This command only edits a doc that already exists; it never creates
  `flow/<name>.md` from nothing (that's `/create_flow`'s job) and never
  changes `/list_flow`'s discovery behavior.
