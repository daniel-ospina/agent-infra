---
name: skill-sync
description: "Use after creating, editing, or deleting any skill in agent-infra/skills/. Commits skill changes to the repo for version control and disaster recovery."
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
version: 2.2.0
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

# Skill Sync

## Architecture

**Canonical home: `agent-infra/skills/`** — the git-tracked source of truth for all shared skills (see `writing-skills` → Cross-Repo Hard-Link Pattern). There is no separate canonical directory and no `.agents/skills/` mirror.

```
agent-infra/skills/<name>/SKILL.md   ← Canonical (git-tracked, single source of truth)
       │
       ├── ~/.pi/agent/skills/<name>/  ← Where Pi reads at runtime (per-skill mirror/symlink)
       └── <consumer>/operations/skills/<name>/SKILL.md  ← Hard-link or directory symlink
                                                          (eldato, tortoise, premise-labs)
```

- **Pi reads from `~/.pi/agent/skills/`** (configured in `~/.pi/agent/settings.json`). Per `writing-skills` this is a symlink to `$AGENT_INFRA_PATH/skills`; on synced machines (see `pi-bootstrap/HANDOFF.md`) it is a folder copy refreshed by `sync.sh`. Either way, the canonical bytes live in agent-infra.
- **Consuming repos** (eldato, tortoise, premise-labs) hard-link skill files from agent-infra into their `operations/skills/` directory — see `scripts/link-skills.sh` and `scripts/check-skill-links.sh` in agent-infra. Hard links share the same inode: editing either path edits the same bytes.
- **No `~/.claude/skills`, no `.agents/skills`.** Both are legacy/removed — do not sync to them, do not document them as live paths.

**When creating a new skill:** create it in `agent-infra/skills/<name>/SKILL.md` following `writing-skills` conventions, then commit via this skill. Product-specific skills (repo-specific paths/APIs/brands) are created directly in the product repo's `operations/skills/<name>/SKILL.md` — do NOT create those in agent-infra.

## When to Use

**Automatically after ANY skill modification in `agent-infra/skills/`:**
- Creating a new skill
- Editing an existing skill
- Deleting a skill

**Never skip this.** Skills must be committed to the repo for version control and disaster recovery.

## Proportionality Gate — Route by Impact

Skill changes have **systemic blast radius** — a bug in a skill silently degrades quality across all future agent work. Treating every skill change as a micro-commit is wrong. Route by impact:

### Trivial → Direct Commit (this skill)

Changes that cannot affect agent behavior:
- Typos, grammar, punctuation
- Dead link fixes
- Whitespace/formatting only
- Updating examples without changing semantics
- Version bumps in frontmatter that match reality

### Non-Trivial → Full Pipeline (`issue-workflow`)

**Any change that could affect how agents behave in future sessions.** This includes:
- Workflow logic changes (adding/removing/reordering steps)
- Quality gate changes (adding/removing/modifying gates)
- New rules, constraints, or prohibitions
- Adding or removing tool permissions / `allowed-tools`
- Changing phase ordering or dependencies
- Adding/removing hard gates or `<HARD-GATE>` blocks
- Changing skill name, description, or routing logic
- Creating a new skill of any complexity
- Deleting a skill (removes functionality, needs scoping)
- Any change you'd want reviewed if you knew it'd run on every future issue

**Routing rule:** When uncertain, classify as non-trivial. The cost of a reviewer catching a skill bug is far lower than the cost of a broken pipeline running on 50 issues.

**Non-trivial flow:**
1. Create a GitHub issue describing the skill change and its rationale
2. Apply `issue-workflow` to that issue — it handles scoping, worktree isolation, implementation, verification, and `commit-workflow` (which includes code review)
3. Do NOT use `skill-sync`'s direct commit for non-trivial changes

**Trivial flow:** Continue to Step 1 below (direct commit).

## Process

### Step 1 — Commit Changes

```bash
cd /path/to/agent-infra

# Stage all skill changes
git add skills/

# Commit
git commit -m "chore(skills): sync skills/

- <skill-name>: <change summary>"
```

### Step 2 — Push

```bash
git push origin main
```

## Creating a New Skill

Create the skill in `agent-infra/skills/<name>/SKILL.md` (following `writing-skills` conventions), then:

```bash
# Canonical copy is committed to agent-infra. Consumers pick it up via
# link-skills.sh (hard-link) or their own sync mechanism.
cd /path/to/agent-infra
git add skills/<name>/
git commit -m "feat(skills): add <name> skill"
git push origin main
```

Then, if a consumer repo needs the skill now:
```bash
cd /path/to/<consumer>   # e.g. eldato
bash /path/to/agent-infra/scripts/link-skills.sh --dry-run   # review first
bash /path/to/agent-infra/scripts/link-skills.sh
```

## Rules

- **`agent-infra/skills/` is the single source of truth.** Pi reads it (via `~/.pi/agent/skills/`), consumers read it (via hard links into `operations/skills/`).
- **No legacy mirrors.** `.agents/skills/` and `~/.claude/skills/` are removed — never sync to them.
- **Trivial changes only.** Direct commit, no PR — for typo/dead-link/formatting fixes. Non-trivial changes MUST route through `issue-workflow` (see Proportionality Gate above).
- **One sync per edit session.** If you edit multiple skills, one sync at the end.
- **No content changes during sync.** Fix in `agent-infra/skills/` first, then sync.
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
