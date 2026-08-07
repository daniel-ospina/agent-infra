# Setting up pi on a new Mac (no AirDrop needed)

This folder lets you get a full working pi setup on a new Mac using only a
browser + Terminal. Your models, agents, extensions, and skills all come from
here — the only thing you add by hand are your API keys (for security, keys are
never stored in this repo).

## Step 1 — Clone the repo (needed for auto-sync)

> Use `git clone` (one command), not the ZIP download — auto-sync needs the
> repo to be a git clone so it can pull updates automatically.

1. On the new Mac, open **Terminal** (Cmd+Space, type "Terminal", Enter)
2. Paste this and press Enter:

```bash
git clone https://github.com/daniel-ospina/agent-infra.git ~/agent-infra
```

   (The repo is private — GitHub will ask you to sign in in your browser the
   first time. After that it's cached.)

> **Using GitHub Desktop instead?** Clone it from GitHub Desktop — it can go
> anywhere (e.g. `~/Documents/GitHub/agent-infra`). The setup script detects
> its own location, so any folder works. Just note where it is for Step 2.

## Step 2 — Run the one-time setup

1. Open **Terminal** (Cmd+Space, type "Terminal", Enter)
2. Replace `<repo-path>` below with where the repo is, then paste and press Enter:

```bash
cd <repo-path>/pi-bootstrap && ./setup.sh
```

   (Example: `cd ~/Documents/GitHub/agent-infra/pi-bootstrap && ./setup.sh`)

It copies your models, agents, extensions, rules, skills, and **MCP config** into
`~/.pi/agent`. Run it again anytime to refresh.

## Step 3 — Transfer your keys (one-time, ~5 min)

The main Mac has a file on its Desktop called **`pi-keys.env`** with ALL your
API keys. Transfer it (AirDrop works — it's tiny).

1. On the new Mac: AirDrop **`pi-keys.env`** to yourself, then move it into
   your **home folder** (Cmd+Shift+H)
2. Run the setup (Step 2) — it will find the file and wire it into your shell
   automatically. Keys are active in new Terminal windows.
3. No `/login` needed for API-key providers. (For subscriptions like Anthropic
   Claude Pro, use `/login` in pi.)
4. **After confirming pi works: delete `pi-keys.env`** (or store it in a
   password manager) — it contains your secrets.

> Tip: if you ever lose the file, every key is re-generatable from each
> provider's dashboard (DeepSeek, OpenRouter, Z.ai, Anthropic, Moonshot, Qwen).

## Step 4 — What pi should do here

Read `HANDOFF.md` (in this same folder) — it's the instructions for this
machine's pi instance.

## Keeping in sync (automatic!)

- **Auto-sync is ON by default** (`AGENT_SYNC_MODE=auto`). Every time you
  start pi, it checks GitHub and if the main Mac published updates, it pulls
  them and refreshes this machine's config. Nothing to do.
- Manual refresh anytime: `cd ~/agent-infra && ./sync.sh`
- **What syncs:** skills, extensions, agents, models, settings, rules, and the
  base MCP config (`templates/.mcp.base.json` → `~/.pi/agent/.mcp.json`).
- **MCP servers:** pi loads MCP servers from the first `.mcp.json` found walking
  up from your working directory to the repo's git top-level, falling back to
  `~/.pi/agent/.mcp.json` (the base config). A repo-local `.mcp.json` overrides
  the base config for that repo. Base servers: exa, brave-search,
  playwright-browser, gemini, tortoise.
- **Tortoise MCP server:** the base config runs the local `tortoise.mcp_server`
  stdio server. It needs `TORTOISE_HOME` pointing at your tortoise checkout
  (setup.sh auto-wires it if the checkout is in a standard location, e.g.
  `~/Documents/GitHub/tortoise` next to this clone) and a local FalkorDB on
  `localhost:16379` for its DB target. If either is missing, the server
  fails fast and pi continues without it (no crash).
- **What never syncs (by design):** your API keys and chat history — those
  stay per-machine.
- On the main Mac, "publishing" just means committing work to agent-infra
  (the agent does this) — the new Mac picks it up at its next pi start.
