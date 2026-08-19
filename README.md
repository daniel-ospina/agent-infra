# agent-infra

Centralized agent infrastructure for Premise Labs repos. Extensions, skills, and scripts used by `tortoise`, `premise-labs`, and `eldato`.

## Source-Available Notice

This repository is **source-available**: it is published publicly for viewing purposes only and is **not** open source. All rights are reserved by the owner. **No license is granted** — you may read and view the code via GitHub's public access, but you have **no right to copy, modify, redistribute, sublicense, or use it commercially** (or for any other purpose) without explicit written permission from the owner. No license file is included by design; absence of a license means default copyright protection applies.

## Structure

```
agent-infra/
├── extensions/    → pi extensions (symlinked by product repos)
├── skills/        → agent skills (symlinked by product repos)
├── scripts/       → check scripts (symlinked by product repos)
├── templates/     → AGENTS.base.md, .mcp.base.json, .husky/ (copied per repo)
├── manifest.json  → version + file inventory
└── bin/           → agent-infra CLI
```

## Prerequisites

**`AGENT_INFRA_PATH` must be set** before using any agent-infra tooling. The auto-sync extension, pre-commit hook, and bootstrap CLI all depend on it.

Add this to your shell profile (`~/.zshrc`, `~/.bashrc`, etc.):

```bash
export AGENT_INFRA_PATH=/path/to/agent-infra
```

Verify it's set:
```bash
echo $AGENT_INFRA_PATH
```

## Bootstrap a repo

```bash
# 1. Link the CLI (from the agent-infra directory)
cd $AGENT_INFRA_PATH && npm link

# 2. Ensure AGENT_INFRA_PATH is set (see Prerequisites above)
export AGENT_INFRA_PATH=/path/to/agent-infra

# 3. Run init from the target repo
cd <target-repo>
npx agent-infra init
```

`init` symlinks extensions/skills/scripts from agent-infra, copies templates, and writes `.agent-infra-version`.

## Syncing

Two directions, two tools — don't mix them up.

**Pull** — update this machine's copy of agent-infra and refresh the pi config:

```bash
cd $AGENT_INFRA_PATH && ./sync.sh
```

**Propagate** — push agent-infra changes into product repos (refreshes symlinks, copies missing templates, bumps the version pin):

```bash
./sync-all            # every repo linked to agent-infra
./sync tortoise       # a single repo
./sync --list         # list linked repos without changing anything
```

A repo counts as **linked** when it contains a `.agent-infra-version` file (written by `agent-infra init` / `agent-infra update`). Linked repos are discovered under `$AGENT_INFRA_REPOS_ROOT` (default `~/Documents/GitHub`); point that env var elsewhere to include repos outside the default location.

Per-repo equivalent (what `sync` runs under the hood):

```bash
cd <target-repo> && node "$AGENT_INFRA_PATH/bin/agent-infra.js" update
```

Each repo's pre-commit hook (copied from `templates/.husky/`) **blocks** commits when `.agent-infra-version` is behind — run `agent-infra update` or `./sync <repo>` to fix.
