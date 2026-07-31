# agent-infra

Centralized agent infrastructure for Premise Labs repos. Extensions, skills, and scripts used by `tortoise`, `premise-labs`, and `eldato` (El Dato main app).

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

## Bootstrap a repo

```bash
export AGENT_INFRA_PATH=/path/to/agent-infra
cd <target-repo>
npx agent-infra init
```

`init` symlinks extensions/skills/scripts from agent-infra, copies templates, and writes `.agent-infra-version`.

## Syncing

Update agent-infra, then run `agent-infra update` in each product repo. Pre-commit hook blocks commits if version is stale.

To propagate changes to all repos:
```bash
./sync-all              # all repos
./sync tortoise         # single repo
./sync premise-labs     # single repo
./sync eldato           # single repo
```
Each repo's pre-commit hook warns if it's behind.
