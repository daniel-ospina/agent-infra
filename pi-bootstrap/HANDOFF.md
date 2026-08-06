# Handoff — instructions for THIS machine's pi

> Read this first. You are a fresh pi instance on a second machine. This file
> tells you who you are, what you have, and what you're responsible for.

## Identity

- You are the pi instance on the **new Mac** (machine #2).
- The **main Mac** (machine #1) continues to run the original setup and is the
  primary operational hub. Treat it as the source of truth for shared state.
- Setup was done via `pi-bootstrap/setup.sh` — see `SETUP-NEW-MACHINE.md` for
  what was installed and how to refresh.

## What you have

- **Models:** DeepSeek (V4 Pro / V4 Flash), GLM-5.2 (Z.ai), OpenRouter, Qwen
  token-plan — configured in `~/.pi/agent/models.json`.
- **Agents & extensions:** the full set from the main machine (see
  `~/.pi/agent/agents/` and `~/.pi/agent/extensions/`).
- **Skills:** `~/.pi/agent/skills` — a real folder copy (not a symlink), so
  it works regardless of username/paths.
- **API keys:** entered manually via `/login` on this machine. Never stored in
  this repo. If a provider errors with auth issues, ask the user to re-run
  `/login` — keys live only in `~/.pi/agent/auth.json` here.

## Repos you should have (or fetch)

- `~/agent-infra` — this repo; skills + pi infrastructure. Source of updates.
- Other project repos (`eldato`, `eldato-outreach`, ...) live only on the main
  machine unless the user copies them here. Don't assume they exist.

## Working with the main machine

- **Auto-sync (Level 1) is enabled:** at every session start this machine
  fetches agent-infra and, if behind, runs `sync.sh` (git pull --ff-only +
  refresh config into `~/.pi/agent`). You are kept current automatically.
- Manual refresh: `cd ~/agent-infra && ./sync.sh` (safe: pulls only, never pushes).
- If a pull fails (local changes/divergence), auto-sync prints a warning and
  stops — resolve via `git -C ~/agent-infra status` before it will sync again.
- **Never push to agent-infra** from here unless the user asks — this machine
  is a consumer; the main machine publishes.
- **Secrets never sync:** auth.json, `~/.pi/keys.env` (if present), and env
  vars stay machine-local. If a provider errors with auth issues, re-check
  `~/pi-keys.env` is sourced (new terminal) or re-run `/login`.

## Your responsibilities

<!-- FILL THIS IN: what should this machine's pi do? Examples:
- [ ] Standby worker: pick up GitHub issues when the main machine is busy
- [ ] Long-running monitoring / nightly checks
- [ ] Independent experiment sandbox (try things without risking main)
-->
- _TODO — user to define the role for this machine._

## Rules (non-negotiable)

1. **Never commit `auth.json`, `settings.json` env blocks, or any API key** to
   this repo. Keys stay in `~/.pi/agent/auth.json` + provider dashboards.
2. When changing shared skills/agents/extensions, commit them to this repo so
   the other machine can pull the same version.
3. If this file changes, re-read it — it defines your mandate.
