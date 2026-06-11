# =============================================================================
# Development image for the python-devcontainer monorepo.
# =============================================================================
#
# WHAT this image is:
#   A long-lived "editor backend" — VS Code (or any devcontainer client)
#   attaches to a running container built from this image. The workspace
#   directory is bind-mounted in by Compose, dependencies are installed
#   into a `.venv/` that lives inside that mount, and your IDE / shell /
#   debugger all run inside this container.
#
# WHAT this image is NOT:
#   A production image. We deliberately do NOT `COPY` source code in. When
#   it's time to ship something, write a separate per-package Dockerfile
#   that does its own multi-stage build. Mixing "dev" and "prod" concerns
#   in one image always rots — dev images grow shells/debuggers/aliases
#   that you don't want in prod, and prod images need stripped-down layers
#   that hurt dev ergonomics.
#
# -----------------------------------------------------------------------------
# Decision: base image — Ubuntu 24.04, NOT ghcr.io/astral-sh/uv:python3.12
# -----------------------------------------------------------------------------
# Considered:
#   1. ghcr.io/astral-sh/uv:python3.12-bookworm  — minimal, uv pre-installed.
#   2. mcr.microsoft.com/devcontainers/python    — devcontainer-curated.
#   3. ubuntu:24.04                              — vanilla distro.  ← chosen
#
# Rationale:
#   - This is a personal/learning template; the "I might need to apt-get
#     install <random thing>" frequency is high. Ubuntu's package universe
#     is the largest, and the user already runs WSL2 Ubuntu — staying on
#     the same distro means apt commands the user knows transfer 1:1.
#   - Astral's uv image is great when uv is the only tool you need, but it
#     is Debian slim with no man pages, no locale data, no build-essential.
#     Adding all that erases the size win and you end up with a Frankenstein.
#   - We pay ~80MB for the larger base; uv's managed Python install is the
#     same cost on any base, so the marginal cost is just system tooling.
#
# Pinning by tag (not digest) is intentional for a dev image — refreshing
# the base image once a quarter is cheap. Production images should pin by
# @sha256 instead.
FROM ubuntu:24.04

# -----------------------------------------------------------------------------
# System packages
# -----------------------------------------------------------------------------
# Decision: install everything in ONE `RUN` and wipe apt cache in the same
# layer. Two-RUN versions look cleaner in diffs but double the image size
# because the apt cache (~50MB) gets baked into the first layer permanently.
#
# Per-package rationale (delete from this list only if you're sure nothing
# downstream depends on it):
#   - sudo                : passwordless sudo for the dev user; needed by
#                           post-start.sh to align the docker.sock GID.
#   - ca-certificates     : TLS roots for curl / git / pip etc.
#   - curl, gnupg         : fetching uv installer, NodeSource keyring,
#                           Docker keyring, claude.ai installer.
#   - git, openssh-client : VS Code source-control panel; `git push` over
#                           SSH using the host-forwarded SSH agent.
#   - ripgrep, fd-find    : Claude Code & oh-my-claudecode skills shell out
#                           to `rg` / `fd` for fast workspace search; if
#                           you remove these, OMC search degrades silently.
#   - jq, less, vim, ncat : ad-hoc debugging conveniences (~5MB total).
#   - build-essential     : a few PyPI packages still ship sdists only;
#                           without gcc + headers they fall back to slow
#                           or fail outright. Cheap insurance.
#
# `--no-install-recommends` keeps each package's transitive footprint
# minimal — Ubuntu defaults pull in suggestions that are noise in a dev
# container (e.g. `vim` recommends `vim-runtime` which is fine but also
# `vim-doc`, `xxd`, etc.). Add them back individually if needed.
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

# Decision: passwordless sudo for the `sudo` group.
# This is dev-image-only behaviour. A production image must NEVER do this.
# We need it because post-start.sh runs `groupmod -g <socket-gid> docker`
# at every attach, and prompting for a password each time would block VS
# Code's startup. The risk is bounded: the only people in the `sudo` group
# inside this container are users we add explicitly below.
RUN echo "%sudo ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/10-nopasswd \
    && chmod 0440 /etc/sudoers.d/10-nopasswd

# -----------------------------------------------------------------------------
# Decision: Docker-outside-of-Docker (DooD), NOT Docker-in-Docker (DinD)
# -----------------------------------------------------------------------------
# Considered:
#   A. DooD: install only `docker-ce-cli`, bind-mount host's /var/run/docker.sock
#            into the container. Container's CLI drives the host's daemon.
#            ← chosen
#   B. DinD: install full `docker-ce` + run dockerd inside the container,
#            usually with --privileged. Fully isolated from host.
#   C. No docker access; force devs to bounce back to host terminal for
#      `docker compose logs api` etc.
#
# Rationale for DooD:
#   - Performance: nested overlayfs is measurably slower; DooD is native.
#   - Cache sharing: with DooD, images you build inside the dev container
#     live in the host docker daemon's cache, so `docker pull postgres`
#     reuses anything you already pulled on the host.
#   - Simplicity: no --privileged, no storage-driver gymnastics.
#   - Trade-off: the dev container has the host daemon's full power
#     (it can stop other containers, see all images). For a single-user
#     dev box this is fine; on a shared/multi-tenant host it would not be.
#
# Why a placeholder GID for the `docker` group?
#   The host's /var/run/docker.sock is owned by root:<GID> where <GID>
#   varies wildly (WSL2 with Docker Desktop: often 988 or 999; native
#   Linux: usually 999; older systems: 998). Hard-coding a GID at build
#   time would break the moment someone runs the image on a host with a
#   different docker GID — and the image itself would no longer be
#   shareable. Solution: create the group at WHATEVER GID apt assigns,
#   add `vscode` to it, and let post-start.sh re-number the group at
#   attach time to match the bind-mounted socket. This keeps the IMAGE
#   host-agnostic and pushes the host-specific work to runtime.
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
# Decision: non-root user with FIXED UID/GID 1000, NOT build-time `ARG UID`
# -----------------------------------------------------------------------------
# Considered:
#   A. ARG UID + ARG USER passed at build time, useradd to match host.
#      → image is per-user, can't be shared, every dev rebuilds, CI builds
#        a third copy. Simple, but doesn't scale.
#   B. Fixed UID 1000 in the image + devcontainer's `updateRemoteUserUID:
#      true` to renumber at attach time. ← chosen
#      → image is host-agnostic and pushable; the runtime renumbers vscode
#        to match the host UID right before VS Code attaches, so files
#        created from the container are owned by the host user, not root.
#      → catch: bare `docker compose exec dev bash` (without going through
#        VS Code) does NOT trigger renumbering. For this project that's
#        acceptable; if you ever need it to work, fall back to option A.
#
# Why delete the stock `ubuntu` user first:
#   Ubuntu 24.04 ships with a default `ubuntu` user already at UID 1000.
#   Trying to create `vscode` at the same UID without removing it fails
#   with `useradd: UID 1000 is not unique`. `userdel -r` is the cleanest
#   way to free the UID and is a no-op on Ubuntu versions that don't ship
#   the default user (the `if id -u ubuntu` guards against that).
#
# Why add `vscode` to BOTH `sudo` and `docker`:
#   - `sudo`: post-start.sh needs to `groupmod` the docker GID; a few
#     ad-hoc apt installs by users are convenient.
#   - `docker`: gives /var/run/docker.sock access. Required for DooD.
ARG USERNAME=vscode
ARG USER_UID=1000
ARG USER_GID=${USER_UID}

RUN if id -u ubuntu >/dev/null 2>&1; then userdel -r ubuntu; fi \
    && groupadd --gid ${USER_GID} ${USERNAME} \
    && useradd --uid ${USER_UID} --gid ${USER_GID} -m -s /bin/bash ${USERNAME} \
    && usermod -aG sudo ${USERNAME} \
    && usermod -aG docker ${USERNAME}

# -----------------------------------------------------------------------------
# Decision: pre-create named-volume mountpoints, NOT chown after first attach
# -----------------------------------------------------------------------------
# The problem: when docker-compose mounts a named volume onto a path that
# DOESN'T exist in the image, Docker creates the directory itself — and
# the daemon runs as root, so the new directory is owned root:root mode
# 755. The vscode user (UID 1000) then can't write to it. The first
# observable symptom is VS Code Server failing to attach with:
#     mkdir: cannot create directory '/home/vscode/.vscode-server/bin':
#     Permission denied
# The same happens to `~/.cache` (uv tries to write wheels) and
# `~/.local/share/uv` (uv tries to install Python).
#
# Considered fixes:
#   A. Pre-create + chown in the Dockerfile so the first volume mount
#      INHERITS vscode ownership.  ← chosen
#   B. `sudo chown` in post-start.sh on every attach.
#      → works but slow, and forces every contributor to rebuild
#        sudo permission expectations.
#   C. Run the container as root.
#      → defeats the entire UID-matching story above.
#
# Note: option A only works once per volume. If a volume already exists
# with bad ownership, you must delete it first (`docker volume rm`).
# This is documented in README's cache-layout section.
RUN mkdir -p \
        /home/${USERNAME}/.vscode-server \
        /home/${USERNAME}/.cache \
        /home/${USERNAME}/.local/share/uv \
    && chown -R ${USERNAME}:${USERNAME} \
        /home/${USERNAME}/.vscode-server \
        /home/${USERNAME}/.cache \
        /home/${USERNAME}/.local

# -----------------------------------------------------------------------------
# Decision: write shell aliases to /etc/bash.bashrc, NOT ~/.bashrc
# -----------------------------------------------------------------------------
# /etc/bash.bashrc is sourced by every interactive bash shell BEFORE
# ~/.bashrc. Putting our aliases here means:
#   - They survive even if the user wipes ~/.bashrc.
#   - They survive if /home/vscode is later bind-mounted from a host
#     dotfiles location that brings its own ~/.bashrc.
#   - They survive the OMC `~/.claude` passthrough (which doesn't touch
#     ~/.bashrc today, but might tomorrow — defensive).
#
# Why these three aliases:
#   - dc:   90% of compose invocations; saves typing.
#   - dcl:  the most common debugging move ("show me what's happening
#           in this service right now"); --tail=200 is enough scrollback
#           to see the last error without flooding the terminal.
#   - dcps: quick overview of which siblings are up.
RUN { \
        echo ''; \
        echo '# python-devcontainer: shortcut for the project compose file'; \
        echo "alias dc='docker compose'"; \
        echo "alias dcl='docker compose logs -f --tail=200'"; \
        echo "alias dcps='docker compose ps'"; \
    } >> /etc/bash.bashrc

# -----------------------------------------------------------------------------
# Decision: Node.js via NodeSource apt, NOT nvm
# -----------------------------------------------------------------------------
# Considered:
#   A. NodeSource apt repo (https://deb.nodesource.com).  ← chosen
#   B. nvm — a shell function that's only available after sourcing nvm.sh.
#   C. Ubuntu's stock `nodejs` package — currently 18, too old.
#
# Why not nvm in a container:
#   nvm is a bash function, not a binary. Every RUN that needs `node` must
#   `source $NVM_DIR/nvm.sh` first, which is fragile and fails subtly
#   in non-interactive scripts. Container layers don't preserve sourced
#   functions across RUNs, so you write `bash -c "source ... && npm ..."`
#   noise everywhere. NodeSource installs node into /usr/bin like any
#   other package — works in any shell, any RUN, any CI step.
#
# Why we need Node here:
#   - Claude Code's MCP servers are mostly npx-based.
#   - oh-my-claudecode skills sometimes shell out to npm tools.
#   - The `ctx7` CLI used per global CLAUDE.md.
#   - Future: prettier, markdown-link-check, etc.
#
# `npm config set fund/update-notifier false`: silences the "this package
# wants funding" / "npm has an update" banners that pollute every npx run.
# Pure noise reduction; no functional impact.
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && npm config set fund false \
    && npm config set update-notifier false

# -----------------------------------------------------------------------------
# Per-user tooling: uv + Claude Code
# -----------------------------------------------------------------------------
# Switch to the unprivileged user BEFORE installing per-user tools so the
# files land under /home/vscode/.local/bin owned by vscode. If we did this
# as root, every tool invocation later would need `sudo` or chown.
USER ${USERNAME}
WORKDIR /home/${USERNAME}

# Decision: install uv via Astral's official installer script, NOT via apt
# or pipx. Astral doesn't ship a Debian package; pipx would require a
# system Python first; the installer is a static binary download with no
# dependencies. It's the upstream-recommended path.
RUN curl -LsSf https://astral.sh/uv/install.sh | sh

# Decision: install Claude Code via Anthropic's native installer, NOT
# `npm install -g @anthropic-ai/claude-code`. The native installer ships
# a single self-contained binary at ~/.local/bin/claude — no Node runtime
# coupling, faster startup, simpler upgrade path (`claude update`).
# (We DO have Node available for MCP servers; we just don't want Claude
# itself to depend on it.)
RUN curl -fsSL https://claude.ai/install.sh | bash

# -----------------------------------------------------------------------------
# Environment variables — every one of these is here for a specific reason.
# -----------------------------------------------------------------------------
ENV PATH="/home/${USERNAME}/.local/bin:${PATH}" \
    EDITOR=vim \
    \
    # UV_LINK_MODE=copy
    # uv's default is to HARDLINK wheel contents from the global cache
    # into the venv (faster, less disk). Hardlinks require source and
    # destination to be on the SAME filesystem. In our setup:
    #   - cache  (~/.cache/uv)      → named volume `cache`
    #   - venv   (.venv/)            → bind mount of the host workspace
    # These are on different mounts, so hardlinks fail with EXDEV. uv
    # falls back to copy and prints a warning every install. Setting
    # `copy` upfront skips the failed-hardlink dance.
    UV_LINK_MODE=copy \
    \
    # UV_COMPILE_BYTECODE=1
    # Pre-compile .pyc files at install time. Costs ~5s extra during
    # `uv sync`; saves ~200ms on every cold `python -c "import ..."`.
    # Worth it for an interactive dev environment where you start
    # processes manually all day.
    UV_COMPILE_BYTECODE=1 \
    \
    # UV_CACHE_DIR=/home/${USERNAME}/.cache/uv
    # Pin the cache location explicitly. uv's default is XDG-cache, which
    # IS ~/.cache/uv — but only if XDG_CACHE_HOME is unset or sane. Some
    # tools mutate XDG_* and we don't want a surprise relocation that
    # would land outside the named volume. Belt + suspenders.
    UV_CACHE_DIR=/home/${USERNAME}/.cache/uv \
    \
    # UV_PYTHON_PREFERENCE=only-managed
    # Forbid uv from using any system Python it might find on PATH.
    # The image has no system Python (Ubuntu 24.04's `python3` is not
    # installed) so this is mostly defensive — but if a future apt
    # package pulls Python in as a dependency, uv would silently switch
    # to it and the project's pinned interpreter version would be
    # ignored. `only-managed` makes that failure mode loud instead.
    UV_PYTHON_PREFERENCE=only-managed

# -----------------------------------------------------------------------------
# Decision: long-running no-op as default CMD.
# -----------------------------------------------------------------------------
# A devcontainer is attached to, not "run". The container needs to stay
# alive after `docker compose up` so `docker compose exec` can land
# subsequent shells. `sleep infinity` is the standard trick — it consumes
# zero CPU, returns no output, and exits cleanly on SIGTERM (so
# `docker compose down` is fast). VS Code Server's attach overrides this
# with its own command anyway.
CMD ["sleep", "infinity"]
