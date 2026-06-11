#!/usr/bin/env bash
# Runs on every devcontainer attach (postStartCommand). Must be idempotent
# and fast — keep it under a second when there's nothing to do.

set -euo pipefail

# -----------------------------------------------------------------------------
# Align the in-container `docker` group GID with the bind-mounted host socket.
# -----------------------------------------------------------------------------
# /var/run/docker.sock is owned by root:<some GID> on the host. The Dockerfile
# created a `docker` group at an arbitrary GID and added vscode to it; if the
# host socket's GID differs (it usually does), `docker ps` returns "permission
# denied while trying to connect to the Docker daemon socket". Fix it by
# moving the in-container `docker` group to whatever GID the socket has.
#
# Skipped silently if the socket isn't mounted (e.g. someone disabled the
# bind-mount in compose) or already matches.
SOCK=/var/run/docker.sock
if [[ -S "$SOCK" ]]; then
    sock_gid=$(stat -c '%g' "$SOCK")
    cur_gid=$(getent group docker | cut -d: -f3 || true)
    if [[ "$sock_gid" != "$cur_gid" ]]; then
        # Another group might already own this GID — move it out of the way
        # before claiming it. This happens on hosts where docker GID collides
        # with a stock Ubuntu group (e.g. `ubuntu` at 1000 → 988).
        clash=$(getent group "$sock_gid" | cut -d: -f1 || true)
        if [[ -n "$clash" && "$clash" != "docker" ]]; then
            sudo groupmod -g "$((sock_gid + 10000))" "$clash"
        fi
        sudo groupmod -g "$sock_gid" docker
    fi
fi

# -----------------------------------------------------------------------------
# git safe.directory — bind-mounted repo is owned by the host UID; even with
# updateRemoteUserUID:true, the very first attach (before UID renumber lands)
# can hit "dubious ownership". Idempotent.
# -----------------------------------------------------------------------------
git config --global --add safe.directory /workspaces/python-devcontainer || true
