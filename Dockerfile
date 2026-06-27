# git-sync-sidecar — a generic two-way git sync sidecar.
#
# Watches a shared volume for changes, periodically commits them to a
# dated branch (off the base branch) and pushes. Optionally opens a PR.
#
# Designed as a sidecar that shares a volume with the main service. The
# main service reads/writes files in the volume; this container owns all
# git operations.
FROM alpine:3.20

# git for git operations, jq for JSON parsing (gh PR output),
# gh CLI for opening PRs, curl/tar for gh install, openssh + tini.
RUN apk add --no-cache \
        git \
        bash \
        jq \
        curl \
        ca-certificates \
        openssh-client \
        tini \
        tzdata \
        supercronic \
    && GH_VERSION=2.65.0 \
    && curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz" \
        | tar -xz -C /tmp \
    && mv "/tmp/gh_${GH_VERSION}_linux_amd64/bin/gh" /usr/local/bin/gh \
    && rm -rf /tmp/gh_* \
    && chmod +x /usr/local/bin/gh

# The sync engine and entrypoint.
COPY sync.sh /usr/local/bin/sync.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/sync.sh /usr/local/bin/entrypoint.sh

WORKDIR /repo

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
