#!/usr/bin/env bash
# Keep this checkout up to date with origin/master.
#
# Replaces the hand-typed  git checkout master && git fetch --all && git pull
# sequence with one fixed, allowlisted entry point (see CLAUDE.md, "the one
# hard rule"). Never rewrites history, never force-pushes, never discards
# local work: every update is fast-forward-only, and a dirty working tree
# stops the run unless --stash is passed.
#
# Usage:
#   .claude/scripts/sync_master.sh                # update local master from origin/master
#   .claude/scripts/sync_master.sh --merge        # ...then merge master into the current branch
#   .claude/scripts/sync_master.sh --stash        # auto-stash/restore local changes around it
#
# Output is line-oriented with == SECTION == markers and a final
# "RESULT: <UP-TO-DATE|UPDATED ...>" line, so a caller can summarise it
# without re-running any git command.

set -uo pipefail

MAIN_BRANCH="master"
REMOTE="origin"
MERGE=0
STASH=0
STASHED=0

usage() {
  cat <<'EOF'
Usage: .claude/scripts/sync_master.sh [--merge] [--stash]

  --merge   After updating local master, merge it into the branch you are on
            (no-op when you are already on master).
  --stash   Stash tracked local modifications before syncing and re-apply them
            afterwards. Without this flag, a dirty working tree aborts the run.
  -h        Show this help.
EOF
}

log()  { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

restore_stash() {
  if [ "$STASHED" = "1" ]; then
    log ""
    log "== RESTORE LOCAL CHANGES =="
    if git stash pop; then
      STASHED=0
    else
      log "WARNING: could not re-apply the auto-stash — your changes are still safe."
      log "         Recover them with: git stash list  /  git stash pop"
    fi
  fi
}
trap restore_stash EXIT

for arg in "$@"; do
  case "$arg" in
    --merge) MERGE=1 ;;
    --stash) STASH=1 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'ERROR: unknown argument: %s\n' "$arg" >&2; usage >&2; exit 2 ;;
  esac
done

git rev-parse --git-dir >/dev/null 2>&1 || fail "not inside a git repository"
REPO_ROOT=$(git rev-parse --show-toplevel) || fail "cannot resolve repository root"
cd "$REPO_ROOT" || fail "cannot cd to $REPO_ROOT"

START_BRANCH=$(git symbolic-ref --quiet --short HEAD) \
  || fail "HEAD is detached — check out a branch before syncing"

log "== CONTEXT =="
log "repo:           $REPO_ROOT"
log "current branch: $START_BRANCH"

DIRTY=$(git status --porcelain --untracked-files=no)
if [ -n "$DIRTY" ]; then
  log "working tree:   dirty"
  printf '%s\n' "$DIRTY"
  if [ "$STASH" = "1" ]; then
    log "stashing local changes (--stash)"
    git stash push --message "sync_master auto-stash" >/dev/null \
      || fail "git stash push failed — nothing was changed"
    STASHED=1
  else
    fail "uncommitted changes present — commit them, or re-run with --stash"
  fi
else
  log "working tree:   clean (tracked files)"
fi

log ""
log "== FETCH =="
git fetch --all --prune || fail "git fetch failed — check network/remote access"

git rev-parse --verify --quiet "refs/remotes/$REMOTE/$MAIN_BRANCH" >/dev/null \
  || fail "$REMOTE/$MAIN_BRANCH does not exist — is '$REMOTE' the right remote?"

log ""
log "== UPDATE $MAIN_BRANCH =="
BEFORE=$(git rev-parse --verify --quiet "refs/heads/$MAIN_BRANCH" || true)

if [ "$START_BRANCH" = "$MAIN_BRANCH" ]; then
  git merge --ff-only "$REMOTE/$MAIN_BRANCH" \
    || fail "local $MAIN_BRANCH has commits that are not on $REMOTE/$MAIN_BRANCH — resolve by hand (rebase/merge/push); nothing was changed"
else
  # Fast-forward the non-checked-out master ref without leaving this branch.
  git fetch "$REMOTE" "$MAIN_BRANCH:$MAIN_BRANCH" \
    || fail "local $MAIN_BRANCH could not be fast-forwarded (it has commits not on $REMOTE/$MAIN_BRANCH) — check it out and resolve by hand"
fi

AFTER=$(git rev-parse "refs/heads/$MAIN_BRANCH")
if [ -z "$BEFORE" ]; then
  NEW_COMMITS="created"
  log "local $MAIN_BRANCH created at $(git rev-parse --short "$AFTER")"
elif [ "$BEFORE" = "$AFTER" ]; then
  NEW_COMMITS=0
  log "already at $(git rev-parse --short "$AFTER") — no new commits"
else
  NEW_COMMITS=$(git rev-list --count "$BEFORE..$AFTER")
  log "$(git rev-parse --short "$BEFORE") -> $(git rev-parse --short "$AFTER")  ($NEW_COMMITS new commit(s))"
  git log --oneline --no-decorate "$BEFORE..$AFTER"
fi

if [ "$MERGE" = "1" ] && [ "$START_BRANCH" != "$MAIN_BRANCH" ]; then
  log ""
  log "== MERGE $MAIN_BRANCH INTO $START_BRANCH =="
  git merge --no-edit "$MAIN_BRANCH" \
    || fail "merge stopped with conflicts — resolve them and commit, or run: git merge --abort"
fi

log ""
log "== SUMMARY =="
log "branch:         $START_BRANCH"
log "$MAIN_BRANCH:         $(git rev-parse --short "refs/heads/$MAIN_BRANCH")"
if [ "$START_BRANCH" != "$MAIN_BRANCH" ]; then
  AHEAD=$(git rev-list --count "$MAIN_BRANCH..$START_BRANCH")
  BEHIND=$(git rev-list --count "$START_BRANCH..$MAIN_BRANCH")
  log "vs $MAIN_BRANCH:      $AHEAD ahead, $BEHIND behind"
  if [ "$BEHIND" != "0" ] && [ "$MERGE" != "1" ]; then
    log "hint:           re-run with --merge to bring those $BEHIND commit(s) into $START_BRANCH"
  fi
fi

if [ "$NEW_COMMITS" = "0" ]; then
  log "RESULT: UP-TO-DATE"
else
  log "RESULT: UPDATED ($NEW_COMMITS new commit(s) on $MAIN_BRANCH)"
fi
