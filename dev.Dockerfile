# Development image for the python-devcontainer monorepo.
#
# This image is for *editing* code: VS Code (or another devcontainer client)
# attaches to a container built from this Dockerfile, the workspace is
# bind-mounted in by Compose, and `uv sync --all-packages` runs against the
# mounted source so the resulting `.venv/` is visible to the host too.
#
# We deliberately do NOT bake the source code in — that's a job for a
# separate prod Dockerfile (to be added per-package when we ship something).
#
# Base: Ubuntu 24.04 — chosen over Astral's `uv:python3.12-bookworm` so the
# image stays close to the host distro and we can apt-install whatever ad-hoc
# tooling a contributor needs. uv installs Python itself, so no system Python
# is required.

FROM ubuntu:24.04

# -----------------------------------------------------------------------------
# System packages
# -----------------------------------------------------------------------------
# - sudo: convenience for ad-hoc root work inside the dev container.
# - curl, ca-certificates, gnupg: needed to fetch uv, Node, Claude Code.
# - git, openssh-client: VS Code source control + git push via forwarded SSH agent.
# - ripgrep, fd-find: required by Claude Code / OMC skills for fast search.
# - jq, less, vim, ncat, build-essential: small ad-hoc debugging conveniences.
# Collapsed into a single layer; apt cache wiped in the same RUN so the layer
# stays small.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        sudo \
        ca-certificates \
        curl \
        gnupg \
        git \
        openssh-client \
        ripgrep \
        fd-find \
        jq \
        less \
        vim \
        ncat \
        build-essential \
    && rm -rf /var/lib/apt/lists/*

# Passwordless sudo for the `sudo` group — dev image only.
RUN echo "%sudo ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/10-nopasswd \
    && chmod 0440 /etc/sudoers.d/10-nopasswd

# -----------------------------------------------------------------------------
# Docker CLI + compose plugin (Docker-outside-of-Docker)
# -----------------------------------------------------------------------------
# We do NOT install the `docker-ce` daemon — only the CLI. The CLI talks to
# the *host's* docker daemon via the bind-mounted /var/run/docker.sock (see
# .devcontainer/docker-compose.yml). This lets you run
#     docker compose logs -f api
#     docker compose restart redis
# from inside the dev container without leaving your editor.
#
# Socket access permissions: the GID of /var/run/docker.sock differs per host
# (WSL2: often 988/999/1001; Linux: usually 999). Hard-coding a GID here would
# bake in a host-specific assumption. Instead, the `docker` group below is a
# placeholder; .devcontainer/post-start.sh aligns its GID to the actual socket
# at attach time.
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
    && chmod a+r /etc/apt/keyrings/docker.gpg \
    && . /etc/os-release \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
        > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        docker-ce-cli \
        docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd -f docker

# -----------------------------------------------------------------------------
# Non-root user
# -----------------------------------------------------------------------------
# Ubuntu 24.04 ships with a default `ubuntu` user at UID 1000. We delete it
# and create our own `vscode` user at the same UID so file ownership matches
# the typical host UID on Linux/WSL. If your host UID differs, devcontainer's
# `updateRemoteUserUID: true` will renumber this user at attach time.
ARG USERNAME=vscode
ARG USER_UID=1000
ARG USER_GID=${USER_UID}

RUN if id -u ubuntu >/dev/null 2>&1; then userdel -r ubuntu; fi \
    && groupadd --gid ${USER_GID} ${USERNAME} \
    && useradd --uid ${USER_UID} --gid ${USER_GID} -m -s /bin/bash ${USERNAME} \
    && usermod -aG sudo ${USERNAME} \
    && usermod -aG docker ${USERNAME}

# -----------------------------------------------------------------------------
# Pre-create named-volume mountpoints with correct ownership
# -----------------------------------------------------------------------------
# When Docker mounts a named volume onto a path that doesn't exist in the
# image, it creates the directory as root:root, which then blocks the
# in-container `vscode` user from writing to it (this surfaces as
# `mkdir: cannot create directory '/home/vscode/.vscode-server/bin':
# Permission denied` on first attach).
#
# Creating the directories here — and chown'ing them to vscode — means the
# very first volume mount inherits these permissions instead of falling
# back to root:root. Subsequent mounts reuse the volume's existing tree, so
# this only matters once per volume.
RUN mkdir -p \
        /home/${USERNAME}/.vscode-server \
        /home/${USERNAME}/.cache \
        /home/${USERNAME}/.local/share/uv \
    && chown -R ${USERNAME}:${USERNAME} \
        /home/${USERNAME}/.vscode-server \
        /home/${USERNAME}/.cache \
        /home/${USERNAME}/.local

# -----------------------------------------------------------------------------
# Shell ergonomics for the multi-service workflow
# -----------------------------------------------------------------------------
# `dc` shortens the docker-compose-plugin invocation when running from inside
# the dev container. COMPOSE_FILE is also exported in docker-compose.yml so a
# bare `docker compose ps` works regardless of CWD.
#
# Written to /etc/bash.bashrc (system-wide) on purpose: the per-user ~/.bashrc
# is bind-mounted out of /home/vscode/.claude passthrough territory and could
# be shadowed by future dotfile mounts; system bashrc is stable.
RUN { \
        echo ''; \
        echo '# python-devcontainer: shortcut for the project compose file'; \
        echo "alias dc='docker compose'"; \
        echo "alias dcl='docker compose logs -f --tail=200'"; \
        echo "alias dcps='docker compose ps'"; \
    } >> /etc/bash.bashrc

# -----------------------------------------------------------------------------
# Node.js 22 (NodeSource apt repo)
# -----------------------------------------------------------------------------
# Needed for: Claude Code's MCP servers (npx-based), oh-my-claudecode skills,
# `ctx7` CLI, prettier, etc. NodeSource is preferred over nvm in containers
# because nvm is a shell function that needs `source` in every RUN — fragile.
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && npm config set fund false \
    && npm config set update-notifier false

# -----------------------------------------------------------------------------
# Per-user tooling: uv + Claude Code
# -----------------------------------------------------------------------------
USER ${USERNAME}
WORKDIR /home/${USERNAME}

# uv — installs to ~/.local/bin
RUN curl -LsSf https://astral.sh/uv/install.sh | sh

# Claude Code — Anthropic's official native installer (not the npm package);
# installs to ~/.local/bin/claude.
RUN curl -fsSL https://claude.ai/install.sh | bash

ENV PATH="/home/${USERNAME}/.local/bin:${PATH}" \
    EDITOR=vim \
    # OverlayFS sometimes blocks uv's hardlink optimisation when both the
    # cache and the venv live on bind-mounted volumes. Forcing copy mode
    # avoids the warning and is fast enough.
    UV_LINK_MODE=copy \
    # Compile bytecode at install time so the first import is snappy.
    UV_COMPILE_BYTECODE=1 \
    # Keep the cache out of the bind-mounted workspace; docker-compose mounts
    # a named volume here for fast, persistent installs across rebuilds.
    UV_CACHE_DIR=/home/${USERNAME}/.cache/uv \
    # Force uv to use its own managed Python; don't reach for any system one.
    UV_PYTHON_PREFERENCE=only-managed

# Default to a long-lived no-op so `docker compose up` keeps the container
# alive and `docker compose exec` can land you in a shell. VS Code overrides
# this with its own command on attach.
CMD ["sleep", "infinity"]
