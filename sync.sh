#!/usr/bin/env bash
#
# sync.sh — the git-sync-sidecar sync engine.
#
# Performs ONE sync cycle. Invoked by entrypoint.sh on a cron schedule
# (and once at startup). Idempotent: safe to call repeatedly.
#
# Contract:
#   - The working dir ($GIT_SYNC_PATH) is a git repo shared (via volume)
#     with the main service. The main service reads/writes files there;
#     this script is the SOLE owner of git state.
#   - The working tree lives on a FIXED work branch (one per base branch):
#         <GIT_SYNC_BRANCH_PREFIX>-<GIT_BASE_BRANCH>   e.g. auto/sync-edge
#     This branch is never deleted; it accumulates the service's in-flight
#     edits across days. A long-lived "rolling" PR against the base branch
#     tracks the latest work for human review.
#   - Each cycle: fetch base → merge base into the work branch (-X ours, so
#     the working tree wins on conflicts) → stage → commit → push → refresh PR.
#   - The base branch is NEVER committed to directly. This keeps it clean
#     for human review.
#
set -euo pipefail

log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S%z')] $*"; }

# -------------------------------------------------------------------
# Resolve the fixed work branch name: <prefix>-<base>.
# One stable branch per base branch (e.g. auto/sync-edge, auto/sync-main).
# This replaces the old dated-branch model (auto/sync-YYYY-MM-DD), which
# accumulated many branches/PRs and made the working tree "drift" daily.
# -------------------------------------------------------------------
work_branch() {
    printf '%s-%s' "${GIT_SYNC_BRANCH_PREFIX}" "${GIT_BASE_BRANCH}"
}

# -------------------------------------------------------------------
# Ensure a rolling PR exists for the work branch and is OPEN.
#
# Unlike the old dated-branch model (where each day got its own PR), there
# is now a single long-lived PR per work branch. When that PR is merged or
# closed, the NEXT cycle must open a fresh one — otherwise the merged
# commits would be silently pushed to a branch nobody is watching.
#
# Logic:
#   - No PR at all           → create one.
#   - An OPEN PR exists      → edit its title/body to reflect latest state.
#   - PRs exist but none OPEN → create a fresh rolling PR.
# -------------------------------------------------------------------
ensure_rolling_pr() {
    local branch="$1" base_sha="$2"

    # gh needs a token; prefer GH_TOKEN, fall back to GIT_TOKEN.
    : "${GH_TOKEN:=${GIT_TOKEN:-}}"
    export GH_TOKEN

    # Detect repo in owner/name form from the remote URL.
    local repo
    repo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
    if [ -z "$repo" ]; then
        log "Could not determine repo for PR creation, skipping PR."
        return 0
    fi

    local today
    today="$(date +%Y-%m-%d)"
    local pr_title="🔄 Auto-sync: ${GIT_BASE_BRANCH} (${SYNC_HOST_ID})"
    local pr_body="Rolling sync branch for **\`${SYNC_HOST_ID}\`** → \`${GIT_BASE_BRANCH}\`.

- Base: \`${GIT_BASE_BRANCH}\` @ \`${base_sha}\`
- Work branch: \`${branch}\`
- Last updated: ${today}

This PR stays open and tracks the latest unreviewed changes from \`${SYNC_HOST_ID}\`. Merge to fast-forward \`${GIT_BASE_BRANCH}\`; the next sync cycle will pull the merge back into the work branch and this PR will go quiet until new edits arrive."

    # List ALL PRs for this head branch (any state). --state all is critical:
    # `gh pr view` succeeds on a merged PR and would otherwise trick us into
    # thinking an open PR still exists.
    local existing
    existing="$(gh pr list --repo "$repo" --head "$branch" --state all \
                    --json number,state --limit 10 2>/dev/null || echo "[]")"

    # Find an OPEN PR number (there should be at most one).
    local open_num
    open_num="$(printf '%s' "$existing" \
                    | jq -r '.[] | select(.state=="OPEN") | .number' 2>/dev/null \
                    | head -1 || true)"

    if [ -n "$open_num" ]; then
        # An open PR exists — refresh its title/body to reflect latest state.
        gh pr edit "$open_num" --repo "$repo" \
            --title "$pr_title" --body "$pr_body" >/dev/null 2>&1 \
            && log "Updated rolling PR #$open_num for $branch." \
            || log "WARN: could not update PR #$open_num (permissions?)."
    else
        # No open PR (either none ever, or the prior one was merged/closed).
        # Open a fresh rolling PR.
        gh pr create --repo "$repo" \
            --base "$GIT_BASE_BRANCH" --head "$branch" \
            --title "$pr_title" --body "$pr_body" >/dev/null 2>&1 \
            && log "Opened a fresh rolling PR for $branch against $GIT_BASE_BRANCH." \
            || log "WARN: could not open PR for $branch (permissions?). Changes are pushed regardless."
    fi
}

# Resolve config (entrypoint has already validated most of these, but be
# defensive in case sync.sh is invoked directly).
: "${GIT_SYNC_PATH:?GIT_SYNC_PATH is required}"
: "${GIT_REPO_URL:?GIT_REPO_URL is required}"
: "${GIT_BASE_BRANCH:=main}"
: "${GIT_SYNC_BRANCH_PREFIX:=auto/sync}"
: "${AUTO_OPEN_PR:=true}"
: "${GIT_AUTHOR_NAME:=git-sync-sidecar}"
: "${GIT_AUTHOR_EMAIL:=git-sync-sidecar@local}"
: "${SYNC_HOST_ID:=$(hostname)}"

cd "$GIT_SYNC_PATH"

# Ensure git identity is set (idempotent).
git config user.name  "$GIT_AUTHOR_NAME"
git config user.email "$GIT_AUTHOR_EMAIL"
git config push.default current

BRANCH="$(work_branch)"

# Make sure we have the latest remote refs without touching the working tree.
git fetch origin "$GIT_BASE_BRANCH" --quiet || {
    log "WARN: could not fetch origin/$GIT_BASE_BRANCH (offline?), skipping this cycle"
    exit 0
}
# Also fetch the work branch ref if it exists on origin (cheap; ignored if not).
git fetch origin "$BRANCH" --quiet 2>/dev/null || true

# Capture the current base branch tip for PR bodies.
BASE_SHA="$(git rev-parse --short "origin/$GIT_BASE_BRANCH")"

# -------------------------------------------------------------------
# 1. Get onto (or create) the FIXED work branch.
#
#    The work branch is the stable home for this deploy's in-flight edits.
#    Unlike the old dated-branch model, we never switch branches mid-cycle,
#    so the working tree's relationship to its branch is always consistent.
#
#    Order:
#      a. Exists locally           → checkout it.
#      b. Exists only on origin     → create a local tracking branch.
#      c. Doesn't exist anywhere    → create it from origin/<base>.
#
#    If currently on some other branch with a dirty tree (e.g. a stale
#    dated branch left over from the old model, or base after a restart),
#    a plain checkout may refuse. We carry the working tree over by
#    checkout (git preserves uncommitted changes across checkout when
#    they don't conflict); if that fails, fall back to creating the branch
#    in place from HEAD, which keeps the working tree intact.
# -------------------------------------------------------------------
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
if [ "$CURRENT_BRANCH" = "$BRANCH" ]; then
    : # already there
elif git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    git checkout "$BRANCH" --quiet 2>/dev/null || {
        log "Checkout to existing $BRANCH blocked (dirty tree from $CURRENT_BRANCH); creating in place."
        git checkout -B "$BRANCH" --quiet
    }
elif git show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
    git checkout -B "$BRANCH" "origin/$BRANCH" --quiet 2>/dev/null || {
        log "Tracking checkout of origin/$BRANCH blocked; creating in place."
        git checkout -B "$BRANCH" --quiet
    }
else
    # First ever run for this base branch: branch off origin/<base>.
    # `-B` creates/resets in place and keeps the working tree (carries
    # any in-flight edits the service already produced).
    git checkout -B "$BRANCH" "origin/$GIT_BASE_BRANCH" --quiet 2>/dev/null || {
        log "Could not branch off origin/$GIT_BASE_BRANCH; creating $BRANCH in place from HEAD."
        git checkout -B "$BRANCH" --quiet
    }
    log "Created work branch $BRANCH from origin/$GIT_BASE_BRANCH."
fi

# -------------------------------------------------------------------
# 2. Merge the base branch's updates INTO the work branch.
#
#    This is the merge-back added in f1c7fe7, now operating on the work
#    branch (clearer semantics: work branch is the protagonist, base is
#    the source being merged in). Two purposes:
#      a. Pull deploys (new code pushed to base) into the container.
#      b. After a PR merge, bring the merged commits back so the work
#         branch's diff against base goes quiet (no stale PR diff).
#
#    Conflict policy: `-X ours` (strategy OPTION, not `-s ours`) — on a
#    conflicting hunk the working tree's version wins, but non-conflicting
#    base changes still merge in. The service's in-flight edits are never
#    lost. If the working tree is too dirty to even attempt the merge,
#    abort and skip this cycle — never force, never clobber.
# -------------------------------------------------------------------
if git merge "origin/${GIT_BASE_BRANCH}" -X ours --no-edit --quiet; then
    log "Merged origin/${GIT_BASE_BRANCH} into $BRANCH (-X ours)."
else
    # merge can fail when the working tree has uncommitted changes that git
    # refuses to overwrite (the `-X ours` option only resolves content
    # conflicts, not the "would overwrite local changes" precondition).
    # Abort cleanly and skip this cycle — never force, never clobber.
    git merge --abort 2>/dev/null || true
    log "WARN: merge origin/${GIT_BASE_BRANCH} failed (dirty working tree?); skipped this cycle."
fi

# Refresh ignore rules: append extra patterns so generated artifacts
# (e.g. data/raw/, node_modules/) never leak into the auto commit.
if [ -n "${GIT_IGNORE_GLOB:-}" ]; then
    while IFS= read -r pattern; do
        [ -z "$pattern" ] && continue
        grep -qxF "$pattern" .gitignore 2>/dev/null || echo "$pattern" >> .gitignore
    done <<< "$GIT_IGNORE_GLOB"
fi

# Stage everything (respecting ignore rules) and detect whether there is
# anything new to commit vs HEAD.
git add -A

if git diff --cached --quiet --; then
    log "No changes since last sync on $BRANCH. Nothing to commit."
    # Still refresh the PR (e.g. it may have been merged and a new one is
    # needed, even with no new local changes — though typically the merge
    # above produces no diff in that case and we'd skip). Cheap to attempt.
    if [ "$AUTO_OPEN_PR" = "true" ] && [ -n "${GH_TOKEN:-}${GIT_TOKEN:-}" ]; then
        ensure_rolling_pr "$BRANCH" "$BASE_SHA"
    fi
    exit 0
fi

COMMIT_MSG="chore(sync): auto-sync from ${SYNC_HOST_ID} on $(date +%Y-%m-%d)

Base: origin/${GIT_BASE_BRANCH}@${BASE_SHA}
Work branch: ${BRANCH}
Source: ${SYNC_HOST_ID}"
git commit --quiet -m "$COMMIT_MSG"

log "Committed changes to $BRANCH"

# Push the work branch. Single-writer model: a normal fast-forward push is
# expected. A non-fast-forward is rare (e.g. the branch was rewritten on
# the remote by hand); rather than force-push and risk discarding remote
# history, log a warning and skip — the next cycle's `merge origin/<base>`
# will reconcile naturally. (Force-push was used in the old dated-branch
# model for concurrent same-day writers; that case no longer applies under
# the fixed-branch, single-writer design.)
if ! git push origin "HEAD:refs/heads/$BRANCH" --quiet 2>/dev/null; then
    log "WARN: push to $BRANCH was rejected (non-fast-forward). The remote branch may have diverged. Skipping this push; next cycle will attempt to reconcile via merge."
fi
log "Pushed $BRANCH to origin."

# Ensure a rolling PR exists and is OPEN (creates one if missing/merged/closed).
if [ "$AUTO_OPEN_PR" = "true" ] && [ -n "${GH_TOKEN:-}${GIT_TOKEN:-}" ]; then
    ensure_rolling_pr "$BRANCH" "$BASE_SHA"
fi

exit 0
