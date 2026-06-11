# docs/

Long-form prose documentation that doesn't belong in a code comment or
the top-level `README.md`. Code and config files link in here by
relative path; if you move or rename one of these, search the repo for
the old path before committing.

## Index

| File | What it covers |
| ---- | -------------- |
| [`ssh-agent.md`](ssh-agent.md) | One-time host setup so the dev container can `git push` over SSH. Explains the agent-forwarding design, alternatives considered, host-side `ssh-agent` configuration for bash/zsh/macOS Keychain/systemd, and a troubleshooting section. |

## Conventions

- **One topic per file.** If a topic outgrows a single file, give it a
  directory and an `_index.md` (or `README.md`) with a sub-index.
- **Filenames are `kebab-case`.** Reserve `SCREAMING_CASE` for top-level
  meta files (`README.md`, `LICENSE`, `CHANGELOG.md`).
- **Link from code to docs by relative path** (e.g. `docs/ssh-agent.md`,
  not the GitHub URL). Keeps it working in offline clones, forks, and
  forks under different org names.
- **Don't duplicate decision rationale.** If a Dockerfile or compose
  comment already explains *why*, link to that comment from the doc and
  vice-versa — readers should find the explanation once, not twice.
