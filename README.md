# python-devcontainer

A reference layout for **pure-Python monorepos** developed inside a
container, using:

- **uv workspaces** — one lockfile, one virtualenv, multiple editable packages.
- **Devcontainer + Docker Compose** — reproducible dev env, host Claude Code
  config transparently passed through.
- **`src/` layout** — main service at the repo root, shared libraries under
  `packages/*`.

## Layout

```
.
├── .devcontainer/            # everything needed to build & attach the dev container
│   ├── devcontainer.json     #   VS Code "Reopen in Container" entry point
│   ├── docker-compose.yml    #   `dev` service + bind-mounted caches + host passthrough
│   ├── Dockerfile            #   Ubuntu 24.04 + uv + Node 22 + Claude Code
│   ├── initialize.sh         #   host-side: pre-create bind-mount sources (dotfiles + volumes/)
│   ├── post-start.sh         #   per-attach: docker.sock GID, git safe.dir, ssh-agent check
│   └── volumes/              #   bind-mount sources for cache/uv-data/vscode-server (gitignored)
├── docs/                     # long-form prose docs (linked from comments + README)
│   └── ssh-agent.md          #   one-time host setup for SSH agent forwarding
├── pyproject.toml            # workspace root AND main service
├── src/
│   └── python_devcontainer/  # main service code
├── packages/
│   └── core/                 # example shared library (`pdc-core`)
│       ├── pyproject.toml
│       └── src/pdc_core/
└── tests/                    # tests for the main service
```

The `.devcontainer/` directory is **self-contained** — every file the
dev environment needs (image recipe, compose, attach hook) lives there.
Day-to-day prose docs go in `docs/`; comments in code/config link to them
by relative path so they stay discoverable from inside an editor.

The repo root is **both** the workspace root and the main service —
`[tool.uv.workspace]` declares `packages/*` as members, and the main
service depends on them via `[tool.uv.sources]` with `workspace = true`,
which makes them install in editable mode automatically.

## Using this as a template for a new app

The repo is set up as a usable template — `python-devcontainer` is its
own name, but you'll usually want to rename everything to `myapp` (or
whatever) when starting a new project. A `bootstrap.py` script does the
rename in one shot and self-deletes:

```bash
# 1. Copy the template (clone, then drop the .git history)
git clone https://github.com/<you>/python-devcontainer myapp
cd myapp
rm -rf .git

# 2. Rename. Use --dry-run first if unsure.
./bootstrap.py myapp                    # main app named myapp
./bootstrap.py my-cool-api              # dashes auto-mapped to underscores
./bootstrap.py myapp --rename-core mya  # also rename pdc-core → mya-core

# 3. Initialise as your own repo
git init && git add -A && git commit -m "initial commit"
uv sync --all-packages
```

After that, "Reopen in Container" picks up the new project name; docker
volumes, the workspace path, and the package name are all consistent.

The `bootstrap.py` script's module docstring documents *why* it picks
this approach (a one-shot rename script over copier/cookiecutter
templates, Python over bash, curated replacements over recursive sed,
self-delete over leave-behind) — read it if you're considering adopting
the template at scale.

## Getting started

### Inside the devcontainer (recommended)

1. Open the repo in VS Code.
2. Run **Dev Containers: Reopen in Container**.
3. First boot builds the image and runs `uv sync --all-packages`. You then
   land in `/workspaces/python-devcontainer` with `.venv/` ready.

> **One-time host setup for `git push`:** the devcontainer forwards the host's
> SSH agent (private keys never enter the container — see the design notes in
> `.devcontainer/devcontainer.json`). If `git push` inside the container errors
> with `Permission denied (publickey)`, follow
> [`docs/ssh-agent.md`](docs/ssh-agent.md) once.

### On the host (without the container)

```bash
uv sync --all-packages
uv run python-devcontainer       # main service entry point
uv run pytest                    # run all tests across workspace
```

## Adding a new shared package

```bash
mkdir -p packages/foo/src/pdc_foo packages/foo/tests
# packages/foo/pyproject.toml — copy packages/core/pyproject.toml as a template,
# then update name/description/packages.
```

Then in the **root** `pyproject.toml`:

```toml
[project]
dependencies = ["pdc-core", "pdc-foo"]   # add new package

[tool.uv.sources]
pdc-core = { workspace = true }
pdc-foo  = { workspace = true }          # mark as workspace member
```

Re-run `uv sync --all-packages` and the main service can `import pdc_foo`.

## Claude Code passthrough

`docker-compose.yml` bind-mounts these from the host into the dev container:

| Host path           | Container path                | Mode |
| ------------------- | ----------------------------- | ---- |
| `~/.claude`         | `/home/vscode/.claude`        | rw   |
| `~/.claude.json`    | `/home/vscode/.claude.json`   | rw   |
| `~/.gitconfig`      | `/home/vscode/.gitconfig`     | ro   |

Skills, MCP server config, conversation history, and the OMC layer all
"just work". Project paths inside `~/.claude.json` differ between host and
container (`/home/<user>/...` vs `/workspaces/...`), so Claude will ask you
to trust the in-container project the first time — accept once and you're
done.

## Working with sibling services

`.devcontainer/docker-compose.yml` is set up for **Docker-outside-of-Docker**:
the dev container bind-mounts the host's `/var/run/docker.sock` and ships
with the `docker` CLI + compose plugin. That means you can manage every
service in this compose project — including yourself — from inside the dev
container, no need to bounce back to a host terminal.

**Aliases baked into the dev image:**

| Alias  | Expands to                              |
| ------ | --------------------------------------- |
| `dc`   | `docker compose`                        |
| `dcl`  | `docker compose logs -f --tail=200`     |
| `dcps` | `docker compose ps`                     |

`COMPOSE_FILE` and `COMPOSE_PROJECT_NAME` are exported in the dev container,
so these work from any CWD.

### Starting / stopping siblings

Sibling services (currently: `redis`) live behind the `data` profile, so the
default boot stays fast and only starts `dev`. Bring them up explicitly:

```bash
dc --profile data up -d redis      # start in background
dcl redis                          # follow logs
dc restart redis                   # restart without rebuilding
dc stop redis                      # stop (keeps state)
dc rm -fsv redis                   # nuke (removes container + named volume)
```

### Watching logs across multiple services

```bash
dcl                                 # all services, colour-coded by name
dcl redis api                       # subset
dc logs --tail=500 redis            # historical, no follow
```

VS Code's Docker extension (`ms-azuretools.vscode-docker`) is preinstalled —
the side panel lists every container in this project; **right-click → View
Logs** is the GUI equivalent of `dcl`.

### Reaching siblings from your code

From inside the dev container, address services by their compose name —
no `localhost`, no port numbers in URLs that aren't on host-published ports:

```python
import redis
r = redis.Redis(host="redis", port=6379)   # works from `dev`
```

The `ports:` list in `docker-compose.yml` is **host-side** convenience only
(so you can run `redis-cli` from your laptop's terminal). Sibling-to-sibling
traffic doesn't go through host ports.

### ⚠️ Don't `dc down` from inside `dev`

`dev` is itself a service in this compose project. `dc down` stops the
whole project, including the container you're sitting in — VS Code instantly
loses its connection. Use `dc stop <service>` for individual services
instead, and reserve `dc down` for host-side terminals.

### Where each kind of service should live

| Type                                                         | Where to run                                                  |
| ------------------------------------------------------------ | ------------------------------------------------------------- |
| Data services (postgres, redis, kafka, minio, …)             | **`docker-compose.yml`** — you don't change their code        |
| Your own application services (api, worker, scheduler, CLIs) | **Inside `dev` via `uv run …`** — preserves debugger + reload |

Containerise your own code only when you're doing staging-like end-to-end
tests; day-to-day development should keep your code as plain processes
inside the dev container.

## Code quality: ruff + ty + pre-commit

This project uses [`ruff`](https://docs.astral.sh/ruff/) for linting and
formatting (replacing black + isort + flake8) and [`ty`](https://github.com/astral-sh/ty)
for type checking (instead of mypy or pyright). Both run on every commit
via `pre-commit`.

### Single source of truth for tool versions

`ruff` and `ty` versions live **only** in `pyproject.toml`'s `dev`
dependency group, pinned exactly by `uv.lock`. The pre-commit hooks shell
out to `uv run --frozen ruff …` / `uv run --frozen ty …`, so:

- VS Code's Ruff extension (which calls `.venv/bin/ruff`)
- `uv run pytest`-adjacent invocations (`uv run ruff check`)
- The pre-commit hook on `git commit`
- CI's `uv run …` calls

…all use **the exact same binary**. There's no `rev:` to keep in sync, no
"editor formatted with 0.16, hook reformatted with 0.15" reformat loops.

The trade-off: contributors must `uv sync` before their first commit. The
devcontainer's `postCreateCommand` does this automatically, so within the
container it's free. On the host, run `uv sync --all-packages` once
manually.

### Install the git hook

The devcontainer runs `uv run pre-commit install` automatically on first
container creation. If you're working on the host, do it once per clone:

```bash
uv run pre-commit install
```

After this, `git commit` automatically runs ruff + ty on staged files; if a
hook fails or a formatter rewrites a file, the commit aborts so you can
re-stage and try again.

### Manual runs

```bash
uv run pre-commit run --all-files          # check the whole repo
uv run pre-commit run ruff-format          # one specific hook
```

### Bumping versions

Because the version is locked in `uv.lock`, bumping is a `uv` operation:

```bash
uv lock --upgrade-package ruff --upgrade-package ty
uv sync
uv run pre-commit run --all-files          # confirm hooks still pass
```

For the generic file-hygiene hooks (whitespace, large files, …) which
*do* still come from a remote repo, occasionally run:

```bash
uv run pre-commit autoupdate
```

### First-run cost vs. the cache

The first `pre-commit run` only needs to build the small `pre-commit-hooks`
env (~10 MB) — ruff and ty come from `.venv/`, no extra downloads. Hook
envs live in `~/.cache/pre-commit/`, which is bind-mounted from
`.devcontainer/volumes/cache/` on the host, so container rebuilds reuse them.

## Cache layout (bind mounts)

| Host path                              | Container mountpoint           | What lives here                             |
| -------------------------------------- | ------------------------------ | ------------------------------------------- |
| `.devcontainer/volumes/cache/`         | `/home/vscode/.cache`          | uv wheels, pre-commit envs, ruff/ty caches  |
| `.devcontainer/volumes/uv-data/`       | `/home/vscode/.local/share/uv` | uv-managed Python interpreters, `uv tool …` |
| `.devcontainer/volumes/vscode-server/` | `/home/vscode/.vscode-server`  | VS Code Server + extensions                 |
| `redis-data` (named volume)            | `/data` in the redis container | redis persistence                           |

Why bind mounts (instead of Docker named volumes) for the three dev-container
caches: named volumes bake in a UID at first mount and don't follow the host
user's UID when the container starts on a different machine. The result was
a series of `Permission denied` failures on attach (most visibly on the
VS Code Server's connection-token write). Bind mounts inherit the host UID
from the filesystem, so the same directory works across any host whose user
the devcontainer CLI then maps `vscode` to. The trade-off: bind-mount I/O on
**macOS / Windows (non-WSL)** is slower than native volumes — roughly 2× on
modern Docker Desktop with VirtioFS, much worse on the legacy osxfs. On
**Linux / WSL2** there is no measurable difference. See
`.devcontainer/docker-compose.yml`'s bind-mount block for the full story
(it's a long comment because the history is long).

To clear one specific tool's cache without nuking the rest, prefer entering
the dev container and using the tool's own command:

```bash
uv cache clean              # only uv's wheel cache
uv run pre-commit clean     # only pre-commit envs
```

To wipe a whole cache directory (forces re-download), from a **host**
terminal:

```bash
rm -rf .devcontainer/volumes/cache              # XDG cache for all tools
rm -rf .devcontainer/volumes/uv-data            # uv-managed Pythons
rm -rf .devcontainer/volumes/vscode-server      # VS Code Server + extensions
```

The directories will be recreated empty on the next container start by
`.devcontainer/initialize.sh`.

⚠️ `docker compose down -v` only purges **named volumes**, so it will wipe
`redis-data` but leave the three bind-mounted dev caches untouched. That's
the opposite of the named-volume era — `down -v` used to be the "scorch
the earth" command and is now mostly harmless.

## Common commands

```bash
uv sync --all-packages              # install/refresh full workspace
uv add some-package                 # add a dependency to the main service
uv add --package pdc-core foo       # add a dependency to a workspace member
uv build --all-packages             # build sdists + wheels for the workspace
uv run pytest                       # run all tests
uv run ruff check .                 # lint (without committing)
uv run ruff format .                # format (without committing)
uv run ty check                     # type-check (without committing)
uv run pre-commit run --all-files   # everything above, in one shot
```
