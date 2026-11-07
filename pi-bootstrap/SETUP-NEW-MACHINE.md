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

It copies your models, agents, extensions, rules, skills, scripts, and **MCP config** into
`~/.pi/agent`. Run it again anytime to refresh.

**Launchd agents (macOS):** setup.sh also installs the scheduled jobs via
`scripts/install-launchd.sh` — the versioned plist templates in
`templates/launchd/` (provider-latency-tripwire every 1h — the
api.deepseek.com latency alert #424; corruption-canary every 15 min on swarm
hosts). The installer is
idempotent: renders → diffs vs the
installed plist → skips when identical, reloads on change. Run
`scripts/install-launchd.sh --status` to inspect; `--uninstall` to remove.

**The orchestrator harness (macOS) — a SECOND, separate step.** `setup.sh` installs this Mac's config
and the launchd template set, and it installs NEITHER the orchestrator controller NOR the harness-apply
clock. Run, once, from the checkout:

```bash
scripts/harness-up up        # preflight -> install the roles this box should run -> start them
scripts/harness-up status    # one MEASURED line per role; NEVER-INSTALLED / DANGLING / FAILED with the reason
```

`up` is idempotent and refuses before writing anything if a role's program or working directory is
missing. Which roles have a unit on which platform — and which components are current — is the table in
`scripts/orchestrator-harness/README.md` §6.1. The Linux cells get the same two commands; the install
half is systemd there instead of launchd.

**Session checks (macOS):** hub-state-check (repo drift) + skill-lint-oracle
(skill-lint drift lock) can't run under launchd — macOS TCC blocks
launchd-spawned processes from reading ~/Documents, and both checks read the
repos there (#427/#431). They are RETIRED from launchd
(`templates/launchd/RETIRED`, #432) and instead run from
`extensions/session-checks.ts` at every pi session start, age-gated
(hub >6h, oracle >24h, ~/.pi/agent/state) — i.e. they run while you work,
not on a headless 24/7 timer. Hub surface = agent-infra (its own path) +
the tortoise checkout (TORTOISE_REPO env / sibling) — #615 removed the
agent-infra #99 hub-discipline exemption, so its main checkout is checked
like every other hub; `SESSION_CHECKS_REPOS` adds
more. `SESSION_CHECKS_OFF=1` disables; windows via
`SESSION_CHECKS_HUB_H` / `SESSION_CHECKS_ORACLE_H` (0 = never auto-run).
First run after setup: no state epochs exist yet → the first session start
runs both checks once, and hub's --gh-report becomes LIVE (it was TCC-dead
under launchd) — if the main checkout is dirty at that moment it files one
deduped issue per repo. Expected behavior, not a fault.

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

**One key is not like the others: `TORTOISE_MCP_API_KEY`.** The graph mandate (read the hosted
Tortoise graph before researching, confirm direction in it before implementing, write the learning
after) needs it, and nothing in this repo can deliver it — there is no secret store wired to the
fleet, so it is HAND-PROVISIONED: it must be a line in `pi-keys.env` here (and in a cell's `keys.env`).
⛔ **Step 3 item 4's "delete `pi-keys.env`" must not take this key with it.** Item 4 removes SECRET
MATERIAL, and nothing re-creates this key (unlike the provider keys, which pi keeps after `/login`).
So when you follow item 4: move the `TORTOISE_MCP_API_KEY` line into whatever replaces the file (the
password manager) **and keep a `pi-keys.env` in the home folder containing that one line** — it is the
only file the setup sources into your profile, so deleting the file deletes the mandate's credential
until someone re-provisions it by hand. It is the one line that must survive.

**And put it in `~/keys.env` too, because a LANE does not read your profile.**
`scripts/orchestrator-harness/worker-terminal.sh` sources `~/keys.env` UNCONDITIONALLY when it exists,
but sources `~/pi-keys.env` **only** when that file is the source of the MODEL-provider key its launch
line resolves — so on a Mac whose provider credential comes from `/login` instead (Step 3 item 3), a
graph key living only in `pi-keys.env` reaches no lane and every lane reports
`GRAPH-UNREACHABLE(NO-KEY)`. The remedy is one line, and it is the difference between the mandate
running and not: **keep `TORTOISE_MCP_API_KEY` in `~/keys.env`** (same line, hand-provisioned from the
Tortoise dashboard) alongside the `pi-keys.env` copy that covers interactive sessions. Losing it
silently is the one outcome worse than a loud NO-KEY.
The client itself (`~/.pi/agent/scripts/tortoise-graph.sh`) IS delivered by the setup — it is farmed
from this repo — so a box with NEITHER name set reports `GRAPH-UNREACHABLE(NO-KEY)` on every call. With
only the alias name `TORTOISE_API_KEY` present, the client takes that fallback and reports the endpoint's
verdict instead — and that name USUALLY carries the same token (`skills/research/SKILL.md` records it
measured identical, Bearer -> `200`), so a box that has only the alias may work fine; where the alias
carries the REST token instead, the endpoint answers `GRAPH-UNREACHABLE(HTTP 401)`, because the REST
key is not the MCP key. Neither outcome is a reason to skip provisioning `TORTOISE_MCP_API_KEY`.
`bash ~/.pi/agent/scripts/tortoise-graph.sh health` is the local reading; on a cell,
`bash scripts/cloud-cell-bringup.sh --check` additionally warns by variable NAME, never its value.
Re-generate it from the Tortoise dashboard at `tortoise.premiselabs.co` (the sign-up site, not the API
host).

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
- **Launchd on a swarm host:** after the one-time setup, run the swarm
  bootstrap (`bash scripts/bootstrap.sh` in the swarm checkout) — it installs
  the 8 swarm daemons (its own installer) and delegates the agent-infra jobs
  (corruption-canary) to `scripts/install-launchd.sh`, so the full fleet
  converges. Order: `pi-bootstrap/setup.sh` →
  swarm `bootstrap.sh` → `scripts/install-launchd.sh` (all idempotent).
- **What syncs:** skills, extensions, agents, models, settings, rules, the
  base MCP config (`templates/.mcp.base.json` → `~/.pi/agent/.mcp.json`), the
  `scripts/checkout-hygiene/` farm (real copies refreshed into
  `~/.pi/agent/scripts/`; #427 — symlinks into the repo were TCC-blocked for
  launchd bash, so setup.sh copies instead), and
  the launchd agents (via `scripts/install-launchd.sh`, #304).
- **`models.json` is MERGED, not replaced (#682).** A re-run reconciles the shipped
  `pi-config/models.json` into your live `~/.pi/agent/models.json` at three levels, and
  the shipped file wins **per key**: per provider, per model `id`, and per
  `modelOverrides` key. Anything that exists **only** in your live file — a local model
  you added, an extra provider, a machine-specific override — is kept, and the run prints
  what it replaced and what it preserved. Before #682 the whole provider object was
  replaced, so a live-only model id was deleted silently (a live id carrying 1,733
  recorded calls was removed by one sync). If a run ever would drop a live entry it now
  **refuses to write** and names the entries instead.
- **MCP servers:** pi loads MCP servers from the first `.mcp.json` found walking
  up from your working directory to the repo's git top-level, AND the base config
  at `~/.pi/agent/.mcp.json` — **both** are read and **merged**, so a repo's
  `.mcp.json` is a DELTA on the base, not a replacement for it. On a name
  collision the **repo's entry wins FIELD BY FIELD**: set only the fields that
  differ and the base's other fields are kept. So `{"tortoise": {"timeoutMs":
  40000}}` changes just the connect budget and keeps the base's `url`, `type`,
  `lazy` and headers — a whole-entry override used to leave the entry with no
  `command` and no `url`, i.e. permanently unspawnable.

  **The merge never inherits a secret into a different destination, and the transport
  is atomic.** Neither rule is a security boundary — see the warning below.

  - Changing `url` keeps `lazy`, `timeoutMs` and the catalog metadata, but **does
    not inherit** the base's `headers`/`oauth`: the base's credentials belong to the
    base's own endpoint. A `lazy`-only override does not change the destination,
    so it keeps them. URLs are compared normalised, so restating the same endpoint
    is still the same destination.
  - Declaring `command` drops the base's `url`/`headers`/`oauth`; declaring `url`
    drops the base's `command`/`args`/`env`/`cwd`. The base's `env` is inherited
    only when the same thing is LAUNCHED — `command` **and** `args` **and** `cwd`,
    because `args` decides what actually runs.
  - Never declare both transports (or a `type` contradicting the one you declare):
    such an entry is ambiguous, so it is IGNORED with a warning and the base's
    entry is kept. Silently it would resolve to `url`, because that is what the
    client tests first.

  ⛔ **A repo's `.mcp.json` is TRUSTED INPUT.** These rules stop a repo from
  *accidentally* inheriting the hub's credentials. They do **not** sandbox one: a
  repo-authored entry can still write `"Authorization": "Bearer
  ${TORTOISE_MCP_API_KEY}"` and the client resolves it from the environment — so
  **never restate a fleet secret's env-var name in a repo file**, and treat a
  cloned repo's `.mcp.json` as executable configuration. Every stdio server also
  inherits the parent's whole `process.env`. pi gates project config behind
  project trust; this client does not (yet).

  There is **no way to REMOVE a base server** from a repo layer (`"<name>": null`
  is ignored, with a warning, and an ambiguous entry leaves the base entry in
  place) — see #3612 for the `disabled` tombstone that would
  add one. The base is
  machine-local and is never shipped, so this is also how an INTERNAL server reaches
  every repo without being written into a product repo's tracked config. Base servers: brave-search,
  playwright-browser, gemini, tortoise (`seo-intelligence`, the Perplexity
  research server) and `orchestrator` (the fleet's own MCP — internal, why it
  lives here and not in a repo). **`exa` is not among them** — it was uninstalled by owner
  ruling (2026-10-31); do not re-add it.
- **Tortoise MCP server:** the base config declares the **HOSTED** server —
  `type: http`, `url: https://api.premiselabs.co/mcp/`, `Authorization: Bearer
  ${TORTOISE_MCP_API_KEY}`, `lazy: true`. It needs **no tortoise checkout, no venv and no
  local FalkorDB**: the DB target is resolved server-side. What it needs is a hosted key,
  `TORTOISE_MCP_API_KEY` — the name in the entry, and the name this doc tells you to provision.
  WHERE it goes depends on who reads it, and the two are different files
  (mode 600 either way): an **interactive shell** gets keys from `~/pi-keys.env` (wired into the
  shell profile by `setup.sh`), while **lanes a controller spawns** get them from `~/keys.env`
  (the launch line sources it). Naming only one of them sends half the operators to a file that
  nothing in their path reads. A plain `${VAR}`
  expands to the EMPTY string when unset, so without the key the client sends `Bearer ` and
  the server answers 401 — a set-up gap that reads like an auth bug (#5153). Self-host users
  point `url` at their own daemon (`http://localhost:8000/mcp`) instead; `TORTOISE_HOME` is
  still wired by `setup.sh` for local tooling but the base entry no longer reads it.
- **What never syncs (by design):** your API keys and chat history — those
  stay per-machine.
- On the main Mac, "publishing" just means committing work to agent-infra
  (the agent does this) — the new Mac picks it up at its next pi start.
