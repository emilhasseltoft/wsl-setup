# WSL Setup

A one-shot setup script that turns a fresh Ubuntu WSL install into a ready-to-use development workstation.

Designed to be **dummy-proof**: works for engineers, designers, and PMs alike. No prior Linux knowledge required.

## Prerequisites

- Windows 10/11
- WSL with Ubuntu installed and opened (you should be at an Ubuntu shell prompt)
- Internet access

> Don't have WSL yet? From PowerShell, run `wsl --install`, restart your machine, and follow the Ubuntu setup prompts. Then come back here.

## Run it

Paste this into your Ubuntu terminal and press Enter:

```bash
curl -fsSL https://raw.githubusercontent.com/emilhasseltoft/wsl-setup/main/setup.sh -o /tmp/setup.sh && bash /tmp/setup.sh
```

That's it. You'll be asked for:

1. Your password (once, for admin access)
2. Your name and GitHub email
3. To sign in to GitHub via your browser

Everything else happens automatically. The whole thing takes ~10–15 minutes depending on your internet speed.

When it finishes, WSL restarts itself. Reopen **Ubuntu** from your Start menu and a short walkthrough finishes the last few steps (Claude Code sign-in, VS Code WSL extension, cloning your first repo).

## What it installs

| Tool | Why |
|---|---|
| Zsh + Oh My Zsh + plugins (fzf, fzf-tab, syntax highlighting, history search) | A nicer terminal |
| Docker (official repo, with Buildx and Compose v2) | Run containerized projects |
| GitHub CLI (`gh`) | GitHub auth + SSH key setup |
| mise | Per-project language runtimes (Node, Python, etc. — installed by each project) |
| Claude Code | AI coding assistant |
| Git, configured with your identity | Commit and push code |

It does **not** install Node, Python, Go, or any other language runtime — your projects' `.mise.toml` or `.tool-versions` will install those on demand.

## If something breaks

The script is idempotent: just re-run it. Completed steps are skipped automatically.

```bash
bash /tmp/setup.sh
```

A full log is saved to `/tmp/wsl-setup-<timestamp>.log` — paste it into a Slack message if you need help.

## What you'll have when it's done

- Zsh as your default shell
- A working `git`, `gh`, `docker`, `mise`, and `claude` command
- An SSH key on GitHub so `git push` Just Works
- A `~/code/` folder with your first repo cloned (if you provided a URL during the walkthrough)
- VS Code on Windows talking to WSL via the WSL extension

Open your project with `code .` from inside `~/code/<repo-name>` and start building.
