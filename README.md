# git-sync-sidecar

A generic **two-way git sync sidecar** container. It watches a shared
volume for changes, periodically commits them to a **fixed work branch**
(one per base branch) and pushes. It keeps a long-lived **rolling PR**
open against your base branch for human review. It is designed to run
alongside any service that produces files you want to version-control
without that service knowing anything about git.

> The official `kubernetes/git-sync` is **pull-only**. This project adds
> the missing **push** half — for AI-agent / notebook / CMS workflows
> where a container edits files and you want them synced back to a git
> repo for review.

## How it works

```
┌─────────────────────────┐         ┌──────────────────────────────┐
│  your service            │         │  git-sync sidecar             │
│  (agent, notebook, …)    │         │                               │
│  reads/writes files ────►│  shared │  entrypoint.sh                │
│  in /repo (shared vol)   │  volume │   ├─ clone/init repo          │
│                           │ /repo   │   ├─ checkout work branch     │
│  does NOT touch git      │         │   ├─ sync.sh (once)           │
└─────────────────────────┘         │   └─ supercronic ──► sync.sh  │
                                     │       (on GIT_SYNC_SCHEDULE)   │
                                     └──────────────┬───────────────┘
                                                    │ push <prefix>-<base>
                                                    ▼
                                          remote: your git repo
                                          (rolling PR kept open)
```

The sidecar is the **sole owner of git state** on the shared volume. Your
service just reads and writes files — no git knowledge required.

### The fixed work branch

The work branch is named **`<prefix>-<base>`** (e.g. `auto/sync-edge`,
`auto/sync-main`) and is the **stable home** for this deploy's in-flight
edits. It is never deleted and never changes day-to-day. A single
long-lived "rolling" PR against the base branch tracks the latest
unreviewed work.

Each sync cycle:

1. `git fetch origin <base>` — get the latest base branch tip.
2. Checkout the work branch `<prefix>-<base>` (create it from `origin/<base>`
   on first run; reuse it thereafter).
3. `git merge origin/<base> -X ours` — pull the base branch's updates INTO
   the work branch. The `-X ours` strategy option means: on a conflicting
   hunk the working tree's version wins, but non-conflicting base changes
   merge in normally — the service's in-flight edits are never lost. (If the
   working tree is too dirty for git to even attempt the merge, it aborts
   and skips this cycle.) This also brings merged-PR commits back home, so
   the work branch's diff against base goes quiet after a review merge.
4. `git add -A` — stage all working-tree changes (respecting ignore rules).
5. If nothing changed → done (still refreshes the rolling PR if needed).
6. If changed → commit + push (a normal fast-forward push).
7. If `AUTO_OPEN_PR=true` — ensure a rolling PR exists and is OPEN:
   - No PR at all → create one.
   - An OPEN PR exists → update its title/body.
   - PRs exist but none OPEN (merged/closed) → create a fresh one.

The **base branch is never committed to directly**, so it stays clean for
human review.

## Quick start

```yaml
# docker-compose.yml
services:
  app:
    image: my-app
    volumes:
      - repo-data:/repo
    working_dir: /repo

  git-sync:
    build: ./git-sync-sidecar        # git submodule add <url> git-sync-sidecar
    environment:
      GIT_REPO_URL: ${SYNC_REPO_URL}
      GIT_SYNC_PATH: /repo
      GIT_TOKEN: ${SYNC_TOKEN}       # GitHub PAT (contents:write + pull-requests:write)
      AUTO_OPEN_PR: "true"
    volumes:
      - repo-data:/repo
    restart: unless-stopped

volumes:
  repo-data:
```

See [`docker-compose.example.yml`](./docker-compose.example.yml) for all knobs.

## Configuration

All configuration is via environment variables.

| Variable | Required | Default | Description |
|----------|:--------:|---------|-------------|
| `GIT_REPO_URL` | ✅ | — | Git remote URL (SSH `git@…` or HTTPS). |
| `GIT_SYNC_PATH` | ✅ | — | Shared-volume path holding the git repo. |
| `GIT_BASE_BRANCH` | ❌ | `main` | Branch the sync branches off of, PRs target, **and whose updates are pulled into the working tree each cycle**. Set per deploy environment (e.g. edge deploy → `edge`, production → `main`). |
| `GIT_SYNC_BRANCH_PREFIX` | ❌ | `auto/sync` | Work branch = `<prefix>-<base>` (e.g. `auto/sync-edge`). One stable branch per base branch; a rolling PR tracks it. Override to namespace multiple writers in the same env (e.g. `auto/sync-<host>` → `auto/sync-<host>-<base>`). |
| `GIT_SYNC_SCHEDULE` | ❌ | `0 3 * * *` | Cron expression (UTC). Daily 03:00 by default. |
| `AUTO_OPEN_PR` | ❌ | `true` | Open/update a PR after pushing. |
| `GIT_AUTHOR_NAME` | ❌ | `git-sync-sidecar` | Commit author name. |
| `GIT_AUTHOR_EMAIL` | ❌ | `git-sync-sidecar@local` | Commit author email. |
| `GIT_IGNORE_GLOB` | ❌ | — | Extra `.gitignore` patterns (newline-separated) to exclude generated artifacts. |
| `TZ` | ❌ | `UTC` | Timezone (affects the cron schedule + commit timestamps). |
| `SYNC_HOST_ID` | ❌ | `$(hostname)` | Identifier embedded in commit/PR bodies. |

### Authentication (provide exactly one)

| Variable | Description |
|----------|-------------|
| `GIT_TOKEN` | **HTTPS PAT** (recommended). Embedded in the remote URL; also used by `gh` for PRs. For GitHub, create a fine-grained PAT with `Contents: Read and Write` + `Pull requests: Read and Write` on the target repo. |
| `GIT_SSH_KEY` | **SSH mode**. PEM body of a deploy/SSH private key. Use this when your remote is an SSH URL. PRs are not opened in pure SSH mode unless `GH_TOKEN`/`GIT_TOKEN` is also set. |

> **PRs require a token.** If you choose SSH mode but still want PRs,
> also set `GIT_TOKEN` (or `GH_TOKEN`) so `gh` can authenticate.

## Triggering an immediate sync

Send `SIGUSR1` to the sidecar container to run an out-of-schedule cycle:

```bash
docker exec <sidecar-container> kill -USR1 1
```

Useful after a long agent run when you don't want to wait for the cron.

## Safety notes

- **Base branch is never mutated.** All auto-commits land on the work
  branch and go through a rolling PR.
- **No force-push.** The work branch uses normal fast-forward pushes.
  (The earlier dated-branch model force-pushed to resolve concurrent
  same-day writers; that case does not arise under the fixed-branch,
  single-writer design. If a push is rejected as non-fast-forward, the
  cycle logs a warning and skips — the next cycle's `merge origin/<base>`
  reconciles naturally.)
- The working tree is **never checked out destructively** — staged edits
  from the main service survive every sync cycle.
- **Self-healing after a PR merge.** Once you merge the rolling PR, the
  next cycle merges `<base>` back into the work branch; the diff goes
  quiet and, when new edits arrive, the PR (a fresh one if the previous
  was merged) reflects them again.
- Secrets (`GIT_TOKEN` / `GIT_SSH_KEY`) should be injected via your
  orchestrator's secret mechanism (e.g. SOPS-encrypted `.env`, Docker
  secrets). They are never written to disk by the image.

## Building

```bash
docker build -t git-sync-sidecar .
```

Image contents: Alpine 3.20 + git + gh CLI + supercronic + jq.
