# Setting up pi on a new Mac (no AirDrop needed)

This folder lets you get a full working pi setup on a new Mac using only a
browser + Terminal. Your models, agents, extensions, and skills all come from
here — the only thing you add by hand are your API keys (for security, keys are
never stored in this repo).

## Step 1 — Get this repo onto the new Mac (no git required)

1. On the new Mac, open Safari/Chrome and go to:
   `https://github.com/daniel-ospina/agent-infra`
2. Click the green **Code** button → **Download ZIP**
3. Open Downloads, double-click the ZIP to unzip
4. Drag the **`agent-infra`** folder into your home folder
   (home = the folder with Desktop/Documents inside; press Cmd+Shift+H in Finder)
   Result should be: `~/agent-infra`

## Step 2 — Run the one-time setup

1. Open **Terminal** (Cmd+Space, type "Terminal", Enter)
2. Paste this and press Enter:

```bash
cd ~/agent-infra/pi-bootstrap && ./setup.sh
```

It copies your models, agents, extensions, rules, and skills into
`~/.pi/agent`. Run it again anytime to refresh.

## Step 3 — Add your API keys (one-time, ~5 min)

1. Start pi: type `pi` in Terminal and press Enter
2. Type `/login` and add keys for each provider you use:
   - **DeepSeek** → platform.deepseek.com (API keys page)
   - **OpenRouter** → openrouter.ai/keys
   - **Z.ai** → z.ai console (used by GLM-5.2)
   - **Anthropic** → console.anthropic.com (settings → API keys)
3. Type `/model` (or Ctrl+L) and pick `deepseek-v4-flash` (or any model)
4. Send a message — if you get an answer, you're live ✅

> Tip: keep the keys in a password manager (e.g. iCloud Keychain) so you don't
> have to dig them out of dashboards again.

## Step 4 — What pi should do here

Read `HANDOFF.md` (in this same folder) — it's the instructions for this
machine's pi instance.

## Keeping in sync

- Skills/agents/extensions update: re-download this repo's ZIP (or run
  `git pull` if you know git) and run `./setup.sh` again.
- Your chat history does **not** sync — that's per-machine by design.
