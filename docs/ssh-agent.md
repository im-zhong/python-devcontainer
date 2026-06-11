# SSH agent forwarding — host setup

The dev container needs to push to private Git repos (GitHub, GitLab, …)
without ever holding your private key. The way this repo achieves that is
**SSH agent forwarding**:

```
┌──────────────── host (WSL2 / Linux / macOS) ────────────────┐
│                                                             │
│   ssh-agent (holds the decrypted private key in memory)     │
│        │                                                    │
│        │ exposes: $SSH_AUTH_SOCK = /tmp/ssh-XXXX/agent.NNN  │
│        │                                                    │
│        ▼                                                    │
│   bind-mount ──────────────► /ssh-agent (inside container)  │
│                                                             │
│                              container processes do         │
│                              SSH_AUTH_SOCK=/ssh-agent       │
│                              git push, ssh-add -l, …        │
│                              (sign requests RPC'd to host)  │
└─────────────────────────────────────────────────────────────┘
```

The private key file is **never** copied, never bind-mounted, never written
into an image layer. The container can only ask the host's agent to sign
challenges; it cannot read or export the key. See the long design-decision
comment in `devcontainer.json` for why this beats the alternatives.

The catch: it depends on the host having an agent running, with your key
added, in the same shell environment that launches VS Code. This document
is the one-time setup for that.

---

## 1. Confirm you have an SSH key

```bash
ls -la ~/.ssh/id_*
```

If you don't, generate one (recommended: ed25519):

```bash
ssh-keygen -t ed25519 -C "you@example.com"
```

Then add the **public** key (`~/.ssh/id_ed25519.pub`) to your Git host —
GitHub: **Settings → SSH and GPG keys → New SSH key**.

Verify it works on the host:

```bash
ssh -T git@github.com
# Hi <username>! You've successfully authenticated, ...
```

## 2. Make ssh-agent start automatically and load the key

Pick the section matching your host OS / shell.

### Linux / WSL2 / macOS with bash or zsh

Add to `~/.bashrc` (or `~/.zshrc`):

```bash
# Start a single ssh-agent per login and load the default key.
# Idempotent: re-sourcing the rc file does not spawn a second agent.
if [ -z "${SSH_AUTH_SOCK:-}" ] || ! ssh-add -l >/dev/null 2>&1; then
    eval "$(ssh-agent -s)" >/dev/null
    # Add every key file that exists; ignore the others silently.
    for k in ~/.ssh/id_ed25519 ~/.ssh/id_rsa ~/.ssh/id_ecdsa; do
        [ -f "$k" ] && ssh-add -q "$k" 2>/dev/null
    done
fi
```

If your key has a passphrase, `ssh-add` will prompt once per shell session.
On macOS you can avoid even that by storing it in the Keychain:

```bash
ssh-add --apple-use-keychain ~/.ssh/id_ed25519     # one-time
```

…and replacing the loop above with `ssh-add --apple-load-keychain` (macOS
Monterey+).

### Linux desktops with GNOME / KDE

GNOME Keyring and KDE Wallet usually start their own SSH agent and export
`$SSH_AUTH_SOCK` automatically. Check:

```bash
echo "$SSH_AUTH_SOCK"
ssh-add -l
```

If both work, do nothing. If the agent is running but the key isn't loaded,
just run `ssh-add ~/.ssh/id_ed25519` once — the desktop keyring caches it.

### systemd user service (more robust on long-running Linux sessions)

If you'd rather not couple the agent to a shell login, run it as a user
unit:

```bash
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/ssh-agent.service <<'EOF'
[Unit]
Description=SSH key agent

[Service]
Type=simple
Environment=SSH_AUTH_SOCK=%t/ssh-agent.socket
ExecStart=/usr/bin/ssh-agent -D -a $SSH_AUTH_SOCK

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now ssh-agent
```

Then export the socket from your shell rc (`~/.bashrc` / `~/.zshrc`):

```bash
export SSH_AUTH_SOCK="$XDG_RUNTIME_DIR/ssh-agent.socket"
```

…and `ssh-add ~/.ssh/id_ed25519` once. The agent now survives logout and
relogin.

## 3. Launch VS Code from a shell that has the agent

This is the step everyone forgets.

`$SSH_AUTH_SOCK` is **a per-process environment variable**. VS Code only
sees it if its parent process exported it. That means:

- **WSL2**: open a WSL terminal first (where the rc file ran), then `code .`
  from inside the repo.
- **Linux desktop with the systemd unit above**: opening VS Code from your
  application launcher works, because the user-session env includes
  `SSH_AUTH_SOCK`. Otherwise launch from a terminal.
- **macOS**: opening VS Code from Finder does *not* inherit shell rc.
  Either launch from Terminal (`code .`), or use the macOS Keychain agent
  which is exposed system-wide via `launchd`.

Sanity-check on the host before reopening in container:

```bash
echo "$SSH_AUTH_SOCK"     # should print a path like /tmp/ssh-XXX/agent.NNN
ssh-add -l                # should list one or more keys, NOT "no identities"
```

## 4. Reopen in container

VS Code → **Dev Containers: Reopen in Container** (or **Rebuild Container**
if it's already running with a stale env).

The dev container's `post-start.sh` self-checks the forwarded socket on
every attach. If it isn't reachable, you'll see:

```
[post-start] WARNING: host SSH agent is not reachable from inside the container.
            `git push` over SSH will fail with "Permission denied (publickey)".
            See docs/ssh-agent.md for one-time host setup.
```

When everything is right, that warning is silent. Inside the container:

```bash
echo "$SSH_AUTH_SOCK"     # /ssh-agent
ssh-add -l                # the same keys ssh-add -l showed on the host
ssh -T git@github.com     # Hi <username>! ...
git push                  # works
```

## Troubleshooting

**`Permission denied (publickey)` inside the container.**
On the host: `echo $SSH_AUTH_SOCK; ssh-add -l`. If the socket variable is
empty or `ssh-add -l` says "Could not open a connection to your
authentication agent", the agent isn't running in the shell that launched
VS Code. Re-do step 2, **then close and reopen VS Code from a fresh
terminal** — the running VS Code window will keep the old (empty)
environment.

**`ssh-add -l` works on host, fails in container.**
`/ssh-agent` got mounted as an empty file (host's `$SSH_AUTH_SOCK` was
empty when the container started). `Dev Containers: Rebuild Container`
after fixing the host shell — a plain "Reopen" reuses the existing
container.

**`Bad owner or permissions on /ssh-agent`.**
Not expected with this setup (the bind-mounted socket has the host UID;
VS Code's `updateRemoteUserUID` makes them match). If it appears, run
`ls -la /ssh-agent` inside the container and report the output — usually
indicates the host UID/GID drifted between sessions.

**Multiple keys, GitHub picks the wrong one.**
`ssh-add -l` order is what's tried first. Either `ssh-add -d` the unwanted
keys, or pin one in `~/.ssh/config` on the host:

```sshconfig
Host github.com
    IdentitiesOnly yes
    IdentityFile ~/.ssh/id_ed25519
```

(`~/.ssh/config` is a host-side file — agent forwarding doesn't use it
inside the container, but the host agent still respects it for the
"which key to offer" decision when *you* run `ssh` on the host. Inside
the container, GitHub negotiates with the agent directly and tries each
loaded identity in turn.)

**Hardware key (YubiKey, FIDO).**
Add it on the host: `ssh-add -K` (older OpenSSH) or just plug-and-go with
recent `ssh-agent` versions that auto-detect `sk-*` keys. It then works
inside the container with no extra config — that's one of the major
reasons we chose agent forwarding over key bind-mounts.
