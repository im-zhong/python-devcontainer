#!/usr/bin/env bash
# =============================================================================
# Container ENTRYPOINT — runs as PID 1, BEFORE the devcontainer CLI does
# anything else (updateRemoteUserUID, GPG passthrough, connection-token
# write, postStartCommand, postAttachCommand, …).
# =============================================================================
#
# The problem this exists to solve:
#   The devcontainer CLI's first acts on attach are to copy host config
#   (GPG trustdb, …) into /home/vscode/ and to write its connection
#   token to /home/vscode/.vscode-server/data/Machine/. If any of those
#   targets sit on a named volume whose contents are owned by the
#   "wrong" UID (root, a different host's UID, etc.), every write fails
#   with EACCES and the attach aborts with:
#       /bin/sh: cannot create /home/vscode/.vscode-server/.../connection-token-...
#       Permission denied
#
#   No devcontainer lifecycle hook (postCreate/postStart/postAttach) is
#   early enough to fix this — they all run AFTER the CLI's setup
#   phase. Only PID 1 itself runs early enough. So we use ENTRYPOINT.
#
# What this does:
#   For every named-volume mountpoint under /home/vscode/, force-chown
#   the top-level directory to the vscode user/group, recursing only
#   when the top-level ownership is already wrong. Then exec the
#   original CMD (`sleep infinity` by default).
#
# Why we can chown despite the Dockerfile's `USER vscode`:
#   `vscode` is in the `sudo` group with NOPASSWD (see Dockerfile).
#   `sudo` here invokes /usr/bin/chown as root, which is the same
#   privilege a root entrypoint would have. The "USER" doesn't change
#   what's possible — only what's the default.
#
# Why this works even though updateRemoteUserUID runs LATER:
#   At PID-1 time, `vscode` still has its image-baked UID (1000). We
#   chown to that UID. updateRemoteUserUID then runs `usermod -u
#   <hostUid>` AND `find / -uid 1000 -exec chown -h <hostUid>` —
#   because the volume's files are now owned by 1000 (not root, not
#   some other UID), updateRemoteUserUID's renumber-walk picks them up
#   and they end up owned by the host UID correctly. Without this
#   prelude, files owned by root (auto-created by dockerd) or by some
#   other UID (legacy from prior host) are invisible to updateRemoteUserUID's
#   `-uid 1000` filter and stay broken.
#
# Idempotent: when the top-level dir already belongs to vscode, the
# recursive walk is skipped. Cost on a healthy start: ~3 stat() calls.

set -eu

# MAINTENANCE NOTE — keep VOLUME_MOUNTPOINTS in sync with the named-volume
# bind targets under /home/vscode/ in docker-compose.yml AND the pre-create
# list in Dockerfile's named-volume-mountpoint RUN block. Three places,
# one truth — adding a fourth named volume under /home/vscode/ requires
# updating all three. See either of those files for the full rationale.
VOLUME_MOUNTPOINTS=(
    /home/vscode/.vscode-server   # vscode-server volume — VS Code Server install + workspace state
    /home/vscode/.cache           # cache volume — XDG cache for all tools (uv wheels, pre-commit, ruff, ty, ...)
    /home/vscode/.local/share/uv  # uv-data volume — uv's managed Python interpreters + tool installs
)

target="vscode:vscode"
for dir in "${VOLUME_MOUNTPOINTS[@]}"; do
    # If the mountpoint doesn't exist yet (very rare — Dockerfile
    # pre-creates them), create it as vscode-owned.
    if [ ! -d "$dir" ]; then
        sudo install -d -o vscode -g vscode "$dir"
        continue
    fi
    # Why we don't short-circuit on top-level ownership matching:
    #   The observed failure mode is that the mountpoint's TOP-LEVEL
    #   directory looks correct (vscode:vscode) but a subdirectory
    #   was created by dockerd or by a prior root-running process —
    #   e.g. /home/vscode/.vscode-server/data/Machine/ owned by root
    #   while /home/vscode/.vscode-server/ itself is vscode-owned.
    #   A top-level stat would miss this and skip the fix.
    #   `chown -R` on a tree where ownership already matches doesn't
    #   issue any chown(2) syscalls (coreutils short-circuits per-file
    #   at the libc level), so the cost on a healthy attach is bounded
    #   by stat throughput — tens of milliseconds even for big caches,
    #   which is invisible against container start time (~seconds).
    sudo chown -R "$target" "$dir"
done

# Hand off to the original command (CMD or `docker run`'s trailing args).
# `exec` replaces this shell so PID 1 becomes the CMD process — ensures
# SIGTERM from `docker stop` reaches it directly, so shutdown is fast.
exec "$@"
