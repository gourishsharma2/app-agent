---
description: Bring this checkout up to date with origin/master (fetch + fast-forward local master), optionally merging master into the current branch. Fast-forward only — never rewrites or discards local work.
argument-hint: [--merge] [--stash]
---

# Sync with master

Replaces the hand-typed `git checkout master` → `git fetch --all` →
`git pull origin master` sequence with one allowlisted script call.

Arguments (both optional, order-independent):

| Flag | Effect |
|---|---|
| `--merge` | After updating local `master`, merge it into the branch the user is on (ignored when already on `master`). |
| `--stash` | Stash tracked local modifications before syncing and re-apply them afterwards. Without it, a dirty working tree aborts the sync. |

## Steps

1. Run the sync script as its own single plain command — never wrapped in
   `$(...)`, never chained with `&&`, and never replaced by hand-rolled `git`
   commands (see CLAUDE.md, "the one hard rule"). Pass through whatever flags
   the user gave, and nothing else:

   ```
   .claude/scripts/sync_master.sh $ARGUMENTS
   ```

2. Read the script's output — it is line-oriented with `== SECTION ==` markers
   and ends in a `RESULT:` line. Do **not** re-run `git status`, `git log`, or
   `git fetch` to double-check it; everything needed is already in that output.

3. Report to the user, in 1–4 lines:
   - `RESULT: UP-TO-DATE` → say local `master` already matched
     `origin/master`, and name the branch they are on.
   - `RESULT: UPDATED (n new commit(s) ...)` → say how many commits came in and
     summarise them from the `git log --oneline` block the script printed
     (group by theme; don't paste all of them if there are many).
   - If the summary shows the current branch is **behind** `master` and
     `--merge` was not passed, surface the script's hint once — offer to re-run
     with `--merge`. Don't merge on your own initiative.

4. On a non-zero exit, relay the script's `ERROR:` line as-is and stop. The
   common cases are all deliberate refusals, not bugs — do not try to work
   around them with raw git commands:
   - **uncommitted changes present** → offer `/sync_master --stash`, or let the
     user commit first. Their call, not yours.
   - **local master has commits that are not on origin/master** → the branches
     have diverged; a fast-forward would be a lie. Explain, and let the user
     decide between rebase, merge, or push.
   - **merge stopped with conflicts** → report the conflicted state and that
     `git merge --abort` backs it out. Don't resolve conflicts unasked.
   - **detached HEAD** / **fetch failed** → relay verbatim.

## Notes

- The script only ever fast-forwards. It will not rebase, force-push, reset,
  or drop a stash, so it is safe to run at the start of any session.
- Nothing under `execution/`, `execution-plans/`, or `apk/` is touched by the
  sync itself. If incoming commits changed a `flow/*.md` doc or one of its
  screenshots, the next `/run` detects that via the plan's content hashes and
  recompiles on its own — there is no cache to clear by hand.
