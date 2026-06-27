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
#   - Changes detected relative to the base branch ($GIT_BASE_BRANCH).
#   - Commits land on a dated branch ($GIT_SYNC_BRANCH_PREFIX-<date>),
#     NEVER on the base branch directly. This keeps the base branch clean
#     for human review.
#   - If a change occurs, the current working-tree state is committed
#     as-is (no destructive checkout that would clobber in-flight edits).
#
set -euo pipefail

log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S%z')] $*"; }

# -------------------------------------------------------------------
# Open (or update) a PR for the sync branch. Idempotent.
# -------------------------------------------------------------------
open_or_update_pr() {
    local branch="$1" day="$2" base_sha="$3"

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

    local pr_title="🔄 Auto-sync: ${day} (${SYNC_HOST_ID})"
    local pr_body="Automated sync from \`${SYNC_HOST_ID}\`.

- Base: \`${GIT_BASE_BRANCH}\` @ \`${base_sha}\`
- Branch: \`${branch}\`

Review the diff and merge, or close to discard."

    # If a PR already exists for this branch, gh exits non-zero; update its title/body instead.
    if gh pr view "$branch" --repo "$repo" --json number -q .number >/dev/null 2>&1; then
        gh pr edit "$branch" --repo "$repo" --title "$pr_title" --body "$pr_body" >/dev/null 2>&1 \
            && log "Updated existing PR for $branch."
    else
        gh pr create --repo "$repo" \
            --base "$GIT_BASE_BRANCH" --head "$branch" \
            --title "$pr_title" --body "$pr_body" >/dev/null 2>&1 \
            && log "Opened PR for $branch against $GIT_BASE_BRANCH." \
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

# Make sure we have the latest remote refs without touching the working tree.
git fetch origin "$GIT_BASE_BRANCH" --quiet || {
    log "WARN: could not fetch origin/$GIT_BASE_BRANCH (offline?), skipping this cycle"
    exit 0
}

# Capture the current base branch tip for commit messages / PR bodies.
BASE_SHA="$(git rev-parse --short "origin/$GIT_BASE_BRANCH")"
TODAY="$(date +%Y-%m-%d)"
BRANCH="${GIT_SYNC_BRANCH_PREFIX}-${TODAY}"

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
    log "No changes since last sync on $BRANCH. Nothing to do."
    exit 0
fi

# We have changes. Get onto (or create) the dated branch WITHOUT touching
# the working tree (staged changes survive the operations below).
#   1. If the dated branch exists locally → switch to it.
#   2. Else if it exists on origin → track it.
#   3. Otherwise → create it from HEAD (keeps staged changes).
if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    git checkout "$BRANCH" --quiet
elif git fetch origin "$BRANCH" --quiet 2>/dev/null \
     && git show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
    git checkout -B "$BRANCH" "origin/$BRANCH" --quiet
else
    git checkout -b "$BRANCH" --quiet
fi

# Checkout can reset staged state; re-stage to be safe.
git add -A

COMMIT_MSG="chore(sync): auto-sync from ${SYNC_HOST_ID} on ${TODAY}

Base: origin/${GIT_BASE_BRANCH}@${BASE_SHA}
Source: ${SYNC_HOST_ID}"
git commit --quiet -m "$COMMIT_MSG"

log "Committed changes to $BRANCH"

# Push the dated branch. A non-fast-forward means a same-day branch was
# pushed by another host/instance; force-push keeps a single linear
# history per day (acceptable for auto-sync branches that are reviewed
# and then deleted).
if ! git push origin "HEAD:refs/heads/$BRANCH" --quiet 2>/dev/null; then
    log "Force-push needed for $BRANCH (concurrent same-day sync)."
    git push origin "HEAD:refs/heads/$BRANCH" --force --quiet
fi
log "Pushed $BRANCH to origin."

# Optionally open / update a PR for the branch.
if [ "$AUTO_OPEN_PR" = "true" ] && [ -n "${GH_TOKEN:-}${GIT_TOKEN:-}" ]; then
    open_or_update_pr "$BRANCH" "$TODAY" "$BASE_SHA"
fi

exit 0
