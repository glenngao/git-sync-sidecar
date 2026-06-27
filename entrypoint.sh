#!/usr/bin/env bash
#
# entrypoint.sh — boots the git-sync-sidecar.
#
# Responsibilities:
#   1. Validate required config.
#   2. Configure git auth (SSH key or HTTPS token) from injected secrets.
#   3. Clone / verify the repo into the shared volume (if not present).
#   4. Run one sync cycle immediately.
#   5. Install a cron schedule and run it as the foreground process.
#
set -euo pipefail

log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S%z')] [entrypoint] $*"; }

# -------------------------------------------------------------------
# 1. Validate config
# -------------------------------------------------------------------
: "${GIT_SYNC_PATH:?GIT_SYNC_PATH is required (the shared volume path)}"
: "${GIT_REPO_URL:?GIT_REPO_URL is required}"
: "${GIT_BASE_BRANCH:=main}"
: "${GIT_SYNC_SCHEDULE:=0 3 * * *}"   # default: daily at 03:00 UTC
: "${SYNC_HOST_ID:=$(hostname)}"

mkdir -p "$GIT_SYNC_PATH"
cd "$GIT_SYNC_PATH"

# -------------------------------------------------------------------
# 2. Configure authentication
#
# Two supported modes:
#   - SSH key:  GIT_SSH_KEY holds the PEM body of a private key.
#   - HTTPS:    GIT_TOKEN (a PAT / deploy token) is embedded in the URL.
#
# GIT_SSH_KEY takes precedence. Otherwise, if GIT_TOKEN is set we rewrite
# the remote URL to https://<token>@...  gh CLI uses GH_TOKEN or GIT_TOKEN.
# -------------------------------------------------------------------
mkdir -p /root/.ssh && chmod 700 /root/.ssh

USE_SSH=false
if [ -n "${GIT_SSH_KEY:-}" ]; then
    USE_SSH=true
    KEY_FILE=/root/.ssh/id_ed25519
    printf '%s\n' "$GIT_SSH_KEY" > "$KEY_FILE"
    chmod 600 "$KEY_FILE"
    # Accept the host key of the git host (best-effort; extract host from URL).
    GIT_HOST="$(printf '%s' "$GIT_REPO_URL" | sed -E 's#.*@([^:/]+).*#\1#')"
    [ -n "$GIT_HOST" ] && ssh-keyscan -t ed25519,rsa "$GIT_HOST" >> /root/.ssh/known_hosts 2>/dev/null || true
    # Ensure remote URL uses SSH form if caller gave https URL.
    if printf '%s' "$GIT_REPO_URL" | grep -q '^https://'; then
        log "GIT_SSH_KEY provided but GIT_REPO_URL is https; convert it to SSH form manually for SSH auth."
    fi
    log "Configured SSH key auth."
elif [ -n "${GIT_TOKEN:-}" ]; then
    # Rewrite https URL to embed the token: https://x-access-token:<token>@host/...
    NORMALIZED_URL="$(printf '%s' "$GIT_REPO_URL" \
        | sed -E "s#^(https?://)#\1x-access-token:${GIT_TOKEN}@#")"
    GIT_REPO_URL="$NORMALIZED_URL"
    # Make gh use the same token.
    export GH_TOKEN="${GH_TOKEN:-$GIT_TOKEN}"
    log "Configured HTTPS token auth."
else
    log "ERROR: provide GIT_SSH_KEY (SSH) or GIT_TOKEN (HTTPS) so pushes can authenticate."
    exit 1
fi

# Normalize an SSH remote into a form git can use as "origin".
normalize_remote() {
    # scp-style git@host:owner/repo.git → already valid; leave as-is.
    printf '%s' "$1"
}

REMOTE_URL="$(normalize_remote "$GIT_REPO_URL")"

# -------------------------------------------------------------------
# 3. Clone or attach to existing repo in the shared volume
# -------------------------------------------------------------------
if [ -d "$GIT_SYNC_PATH/.git" ]; then
    log "Existing repo found at $GIT_SYNC_PATH, updating remote URL."
    git -C "$GIT_SYNC_PATH" remote set-url origin "$REMOTE_URL" 2>/dev/null \
        || git -C "$GIT_SYNC_PATH" remote add origin "$REMOTE_URL"
else
    log "Cloning $REMOTE_URL into $GIT_SYNC_PATH ..."
    # Shallow-ish clone of the base branch to keep it light, then full fetch.
    git clone --branch "$GIT_BASE_BRANCH" "$REMOTE_URL" "$GIT_SYNC_PATH" \
        || git clone "$REMOTE_URL" "$GIT_SYNC_PATH"
    log "Clone complete."
fi

# Make sure HEAD points at the base branch initially, WITHOUT discarding
# any working-tree changes that the main service may have produced.
cd "$GIT_SYNC_PATH"
git fetch origin "$GIT_BASE_BRANCH" --quiet || true
if ! git rev-parse --verify --quiet HEAD >/dev/null; then
    # Brand-new checkout with no commits on the current ref: align to base.
    git checkout "$GIT_BASE_BRANCH" --quiet || true
fi

# -------------------------------------------------------------------
# 4. Run one sync immediately (catches changes made while offline)
# -------------------------------------------------------------------
log "Running initial sync cycle ..."
/usr/local/bin/sync.sh || log "Initial sync cycle failed (will retry on schedule)."

# -------------------------------------------------------------------
# 5. Install cron schedule and run as the foreground process.
#
# We use supercronic (runs as non-root / foreground, parses crontab on
# stdin) so there is no need for a system cron daemon.
# -------------------------------------------------------------------
CRONTAB_FILE=/tmp/sync.crontab
cat > "$CRONTAB_FILE" <<EOF
# git-sync-sidecar schedule (host: ${SYNC_HOST_ID})
# minute hour day month weekday  command
${GIT_SYNC_SCHEDULE} /usr/local/bin/sync.sh >> /var/log/sync.log 2>&1
EOF

# Also wake up on SIGUSR1 to sync on demand (e.g. docker exec kill -USR1 1).
sync_on_signal() {
    log "Received SIGUSR1 — running ad-hoc sync."
    /usr/local/bin/sync.sh || log "Ad-hoc sync failed."
}
trap sync_on_signal USR1

log "Installed crontab:"
cat "$CRONTAB_FILE"

log "Starting supercronic (schedule='${GIT_SYNC_SCHEDULE}')."
# supercronic runs in the foreground and exits if it dies → container restarts.
exec supercronic -passthrough-logs "$CRONTAB_FILE"
