#!/usr/bin/env bash
# =============================================================================
# Devcontainer post-start hook — runs on EVERY container attach.
# =============================================================================
#
# Three jobs, all idempotent and fast (no-op when nothing has changed):
#   1. Align the in-container `docker` group GID to the bind-mounted host
#      docker.sock — needed because the GID is host-specific and unknowable
#      at image-build time.
#   2. Mark the bind-mounted workspace as a safe directory for git.
#   3. Sanity-check that the host's SSH agent is reachable (non-fatal).
#
# Why these belong in postStart, not postCreate:
#   All three depend on facts that can change BETWEEN container starts (the
#   user could relocate the repo on the host; Docker Desktop could change
#   the docker GID after an upgrade). Doing them once at create time would
#   bake in stale assumptions.
#
# Note: this script used to also realign ownership of named-volume
# mountpoints (vscode-server, cache, uv-data). Those mounts are now bind
# mounts under .devcontainer/volumes/, which inherit the host user's UID
# from the filesystem — so no in-container chown is needed. The bind-mount
# block in docker-compose.yml documents why we switched.

# -e: abort on first error.  -u: undefined-variable use is an error.
# -o pipefail: catch failures inside pipelines, not just the last command.
# Together: if anything goes wrong, fail loudly so we don't silently
# leave the container in a weird half-initialised state.
set -euo pipefail

# -----------------------------------------------------------------------------
# Job 1 — docker.sock GID alignment
# -----------------------------------------------------------------------------
# Background:
#   The Dockerfile creates a `docker` group at whatever GID `apt` happens
#   to assign (often 999 or 1001) and adds `vscode` to it. But the
#   bind-mounted /var/run/docker.sock is owned by root:<HOST docker GID>,
#   which usually does NOT match. Result: `docker ps` returns
#   "permission denied while trying to connect to the Docker daemon socket".
#
# Considered fixes:
#   A. Hard-code a GID in the Dockerfile.
#      → Breaks the moment the image is shared across hosts.
#   B. `chmod 666 /var/run/docker.sock` here.
#      → Works, but world-writable docker socket is a security smell
#        even on a single-user dev machine.
#   C. `groupmod -g <socket-gid> docker` here.  ← chosen
#      → Tightest scope: the existing `docker` group becomes the right
#        GID, and only members of that group (vscode + root) gain
#        access.
#
# The "GID clash" branch handles a real edge case: on some hosts the
# docker GID happens to equal a stock Ubuntu group's GID (e.g. `ubuntu`
# at 1000 → docker GID 988 → fine; but docker GID 1000 would clash with
# the `vscode` primary group). Move the clashing group out of the way
# first so groupmod doesn't fail.
SOCK=/var/run/docker.sock
if [[ -S "$SOCK" ]]; then
    sock_gid=$(stat -c '%g' "$SOCK")
    cur_gid=$(getent group docker | cut -d: -f3 || true)
    if [[ "$sock_gid" != "$cur_gid" ]]; then
        clash=$(getent group "$sock_gid" | cut -d: -f1 || true)
        if [[ -n "$clash" && "$clash" != "docker" ]]; then
            # +10000 keeps the displaced group's GID in a known-empty
            # range; the actual value doesn't matter, we just need it
            # to not collide with anything else.
            sudo groupmod -g "$((sock_gid + 10000))" "$clash"
        fi
        sudo groupmod -g "$sock_gid" docker
    fi
fi
# After this point, `docker ps` from the vscode user works without sudo.

# -----------------------------------------------------------------------------
# Job 2 — git safe.directory
# -----------------------------------------------------------------------------
# Background:
#   git ≥2.35 refuses to operate on a working tree owned by a UID
#   different from the current process's UID, citing CVE-2022-24765.
#   The bind-mounted workspace is owned by the HOST UID; even with
#   `updateRemoteUserUID: true` doing its work, there's a race window
#   on the very first attach where the renumbering hasn't fully landed
#   for every subprocess. Marking the workspace as "safe" pre-emptively
#   is cheap insurance.
#
# Why --system, not --global:
#   docker-compose.yml mounts the host's ~/.gitconfig READ-ONLY into
#   the container at /home/vscode/.gitconfig, so `git config --global`
#   would fail with EROFS. The --system scope writes to /etc/gitconfig
#   which lives in the container's writable rootfs. Side-benefit: the
#   setting applies to ALL git users in the container (only `vscode`
#   today, but defensive for future).
#
# Why `--add` and not `--replace-all`:
#   Idempotent. Re-adding the same path is a no-op (git dedupes
#   safe.directory entries on read). --replace-all would clobber any
#   other entries someone might add later.
#
# Note: this MUST be in global or system scope. Per-repo config can't
# help — the safe.directory check fires BEFORE git reads the repo's
# own .git/config, by design.
sudo git config --system --add safe.directory /workspaces/python-devcontainer

# -----------------------------------------------------------------------------
# Job 3 — SSH agent forwarding self-check (non-fatal)
# -----------------------------------------------------------------------------
# devcontainer.json bind-mounts the host's $SSH_AUTH_SOCK to /ssh-agent
# inside the container so `git push` over SSH works without copying keys
# in. For that mount to actually be usable, the host must have ssh-agent
# running AND $SSH_AUTH_SOCK exported in the shell that launched VS Code.
# When it isn't, `git push` later fails with the unhelpful
# "Permission denied (publickey)". We catch the misconfig up front and
# point at the setup doc — but stay non-fatal because plenty of workflows
# (HTTPS clones, read-only browsing, CI-style attaches) don't need it.
SSH_SOCK=/ssh-agent
if [[ -S "$SSH_SOCK" ]] && SSH_AUTH_SOCK="$SSH_SOCK" ssh-add -l >/dev/null 2>&1; then
    : # agent reachable, keys loaded — nothing to say
else
    cat >&2 <<'EOF'
[post-start] WARNING: host SSH agent is not reachable from inside the container.
            `git push` over SSH will fail with "Permission denied (publickey)".
            See docs/ssh-agent.md for one-time host setup.
EOF
fi
