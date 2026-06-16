#!/usr/bin/env bash
# =============================================================================
# Devcontainer initialize hook — runs on the HOST, before the container is
# built or started. Wired up via "initializeCommand" in devcontainer.json.
# =============================================================================
#
# Purpose: ensure the host-side paths that docker-compose.yml bind-mounts
# into the container actually exist with the correct TYPE (file vs directory)
# and are owned by the host user.
#
# Why this is necessary:
#   When a bind-mount source is missing on the host, Docker SILENTLY
#   auto-creates it — and because dockerd runs as root, the auto-created
#   path is a ROOT-OWNED DIRECTORY regardless of whether the mount target
#   inside the container is a file or a directory. Two failure modes:
#     1. Container fails to start because Docker can't mount a directory
#        onto a file target (e.g. /home/vscode/.gitconfig).
#     2. Container starts but tools break: git refuses to read its config
#        because it's an empty dir; Claude Code can't find ~/.claude.json.
#   Cleanup then requires `sudo rm -rf` on the user's $HOME, which is
#   exactly the kind of friction a dev container is supposed to eliminate.
#
# Why initializeCommand and not postCreate/postStart:
#   Those run INSIDE the container, AFTER bind-mounts have already been
#   resolved. By then it's too late — Docker has already created the
#   root-owned dirs. initializeCommand runs on the host before `docker
#   compose up`, so we can ensure the sources exist as the right type
#   with the right ownership BEFORE Docker ever sees them.
#
# Idempotent: re-runs are no-ops when everything is already in the right
# shape. Fast: ~10ms on a warm filesystem.

set -eu

# -----------------------------------------------------------------------------
# Step 1 — detect the "already broken" state from a previous failed start.
# -----------------------------------------------------------------------------
# If a prior devcontainer start left root-owned auto-created directories
# at the FILE paths, we can't fix them without sudo — bail out early with
# a clear message instead of letting the container start fail mysteriously
# downstream.
for path in "${HOME}/.claude.json" "${HOME}/.gitconfig"; do
    if [ -d "$path" ]; then
        cat >&2 <<EOF
[initialize] ERROR: '$path' exists but is a DIRECTORY.
             This is the fingerprint of a previous failed container start:
             Docker auto-created the missing bind-mount source as a
             root-owned directory.

             Fix it on the host with:
                 sudo rm -rf "$path"

             Then reopen the container — this script will recreate the
             path as an empty file with the right ownership.
EOF
        exit 1
    fi
done

# -----------------------------------------------------------------------------
# Step 2 — ensure each bind-mount source exists with the right type.
# -----------------------------------------------------------------------------
# ~/.claude/ is a DIRECTORY — Claude Code's state tree (skills, projects,
# conversation history, MCP server config) lives under it. mkdir -p is
# idempotent and creates parents if needed.
mkdir -p "${HOME}/.claude"

# ~/.claude.json is a FILE — Claude Code's top-level config/trust index.
# Seed with an empty JSON object so the first read by Claude Code parses
# cleanly instead of erroring on EOF.
if [ ! -e "${HOME}/.claude.json" ]; then
    printf '{}\n' > "${HOME}/.claude.json"
fi

# ~/.gitconfig is a FILE — git's per-user config. An empty file is a valid
# gitconfig (git fills it in on first `git config --global`). We don't seed
# user.name / user.email here because those are personal and shouldn't be
# templated; the user sets them once on the host with their real identity.
if [ ! -e "${HOME}/.gitconfig" ]; then
    touch "${HOME}/.gitconfig"
fi
