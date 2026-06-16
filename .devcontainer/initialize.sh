#!/usr/bin/env bash
# =============================================================================
# Devcontainer initialize hook — runs on the HOST, before the container is
# built or started. Wired up via "initializeCommand" in devcontainer.json.
# =============================================================================
#
# Purpose: ensure every host-side path that docker-compose.yml bind-mounts
# into the container actually exists with the correct TYPE (file vs directory)
# and is owned by the host user.
#
# Why this is necessary:
#   When a bind-mount source is missing on the host, Docker SILENTLY
#   auto-creates it — and because dockerd runs as root, the auto-created
#   path is a ROOT-OWNED DIRECTORY regardless of whether the mount target
#   inside the container is a file or a directory. Two failure modes:
#     1. Container fails to start because Docker can't mount a directory
#        onto a file target (e.g. /home/vscode/.gitconfig).
#     2. Container starts but tools break: git refuses to read its config
#        because it's an empty dir; Claude Code can't find ~/.claude.json;
#        vscode user (UID = host UID) can't write into root-owned dirs.
#   Cleanup then requires `sudo rm -rf` somewhere on the user's machine,
#   which is exactly the kind of friction a dev container is supposed to
#   eliminate.
#
# Why initializeCommand and not postCreate/postStart:
#   Those run INSIDE the container, AFTER bind-mounts have already been
#   resolved. By then it's too late — Docker has already created the
#   root-owned dirs. initializeCommand runs on the host before `docker
#   compose up`, so we can ensure the sources exist as the right type
#   with the right ownership BEFORE Docker ever sees them.
#
# Why we do this for cache/uv-data/vscode-server at all (these used to be
# named volumes, which didn't need any host-side setup):
#   We switched from named volumes to bind mounts to eliminate an entire
#   class of UID-mismatch bugs that named volumes brought with them
#   (cross-host UID drift, dockerd auto-creating mountpoints as root,
#   chown timing races with updateRemoteUserUID). See the long comment
#   above the bind-mount declarations in docker-compose.yml for the full
#   history. The cost of bind mounts is that the host paths must exist
#   before Docker mounts them — which is exactly what initialize.sh
#   already does for the dotfiles, so we extend it to cover these too.
#
# Idempotent: re-runs are no-ops when everything is already in the right
# shape. Fast: ~10ms on a warm filesystem.

set -eu

# The script's directory — used to anchor the volumes/ tree to .devcontainer/
# regardless of where the user invokes this from. devcontainer CLI normally
# runs initializeCommand with the repo root as CWD, but we don't rely on
# that — using $SCRIPT_DIR/volumes/ keeps the script correct under any CWD.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# -----------------------------------------------------------------------------
# Step 1 — detect the "already broken" state from a previous failed start.
# -----------------------------------------------------------------------------
# If a prior devcontainer start left root-owned auto-created directories
# at the FILE paths, we can't fix them without sudo — bail out early with
# a clear message instead of letting the container start fail mysteriously
# downstream.
#
# Only check the FILE-typed bind mounts here. The directory-typed ones
# (.claude/, the volumes/ subdirs) might legitimately be directories even
# if mis-owned; we let them be created or reused as-is, and the host UID
# inheritance via bind-mount semantics handles the ownership story inside
# the container.
#
# We DON'T check ~/.gitconfig anymore — see docker-compose.yml's
# "Why ~/.gitconfig is NOT bind-mounted" block. The VS Code Dev Containers
# extension copies it into the container at attach time; we no longer
# bind-mount it, so no host-side existence guarantee is needed.
for path in "${HOME}/.claude.json"; do
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
# Step 2 — ensure each DIRECTORY bind-mount source exists.
# -----------------------------------------------------------------------------
# Why these three under .devcontainer/volumes/ specifically:
#   They replace the former named volumes (cache, uv-data, vscode-server).
#   See docker-compose.yml's bind-mount block for why we moved away from
#   named volumes. Bind mounts inherit the host user's UID for free, so
#   `mkdir` here (run as the host user) is all the ownership setup we
#   need — no in-container chown, no entrypoint dance, no post-start
#   safety net. The bug-class is eliminated structurally.
#
# Why mkdir -p and not `install -d`:
#   mkdir -p is POSIX, present everywhere, and silently no-ops on existing
#   directories. install(1) is a GNU utility that would do the same with
#   slightly more flexibility (mode bits, owner override), but we don't
#   need those — the host user's umask gives the right mode, and the
#   owner IS the host user by virtue of running as them.
#
# MAINTENANCE NOTE — keep this list in sync with the bind-mount targets
# under .devcontainer/volumes/ in docker-compose.yml. Adding a new bind
# mount there without adding it here means dockerd will silently auto-
# create the missing directory as root, reintroducing the bug class this
# refactor exists to prevent. One place to read (compose), one place to
# write (here) — that's the minimum two-step we couldn't eliminate without
# a YAML parser.
mkdir -p \
    "$SCRIPT_DIR/volumes/cache" \
    "$SCRIPT_DIR/volumes/uv-data" \
    "$SCRIPT_DIR/volumes/vscode-server"

# ~/.claude/ is a DIRECTORY — Claude Code's state tree (skills, projects,
# conversation history, MCP server config) lives under it. mkdir -p is
# idempotent and creates parents if needed.
mkdir -p "${HOME}/.claude"

# -----------------------------------------------------------------------------
# Step 3 — ensure each FILE bind-mount source exists, with a sensible seed.
# -----------------------------------------------------------------------------
# ~/.claude.json is a FILE — Claude Code's top-level config/trust index.
# Seed with an empty JSON object so the first read by Claude Code parses
# cleanly instead of erroring on EOF.
if [ ! -e "${HOME}/.claude.json" ]; then
    printf '{}\n' > "${HOME}/.claude.json"
fi

# We don't touch ~/.gitconfig here. The VS Code Dev Containers extension
# copies host gitconfig into the container at attach time via its own
# mechanism (see the long block in docker-compose.yml). If ${HOME}/.gitconfig
# is missing on the host, the extension's copy step will be a harmless
# no-op — git inside the container will simply have no user identity set,
# and `git commit` will error with the usual "please tell me who you are"
# message, which is the right failure mode (it points the user at the
# canonical fix: `git config --global user.email/name` on the host).
