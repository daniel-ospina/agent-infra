# agent-infra

Centralized agent infrastructure for Premise Labs repos. Extensions, skills, and scripts used by `tortoise`, `premise-labs`, and `eldato`.

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

Update agent-infra, then run `agent-infra update` in each product repo. Pre-commit hook blocks commits if version is stale.

## Syncing to product repos
Run `./sync-all` to propagate changes to all repos.
Run `./sync tortoise` to sync a single repo.
Each repo's pre-commit hook warns if it's behind.
