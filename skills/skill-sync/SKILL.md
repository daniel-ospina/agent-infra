---
name: skill-sync
description: "Use after creating, editing, or deleting any skill in .agents/skills/. Commits skill changes to the repo for version control and disaster recovery."
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
version: 2.1.0
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

# Skill Sync

## Overview

Single-mirror architecture. `.agents/skills/` is the canonical skill directory — both Claude Code and Pi read from here. The repo copy is the single source of truth.

```
.agents/skills/          ← Canonical (git-tracked)
  code-review/SKILL.md   ← Both agents read this file
  issue-scoping/SKILL.md
  ...

.claude/skills/          ← Per-skill symlinks → ../.agents/skills/
~/.pi/agent/skills/      ← Per-skill symlinks → .agents/skills/ (Pi loads from settings)
```

There is one source of truth: `.agents/skills/`. Both agent symlinks point there.

**When creating a new skill:** create it in `.agents/skills/<name>/SKILL.md` only. Symlinks pick it up automatically.

**Legacy mirrors** (`.agents/skills/`, `.agents/skills/`) are deprecated — do not edit them.

## When to Use

**Automatically after ANY skill modification in `.agents/skills/`:**
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
cd /path/to/repo

# Stage all skill changes
git add .agents/skills/

# Commit
git commit -m "chore(skills): sync .agents/skills/ to repo

- <skill-name>: <change summary>"
```

### Step 2 — Push

```bash
git push origin main
```

## Creating a New Skill

Create the skill in `.agents/skills/<name>/SKILL.md`, then:

```bash
# Both agents already read from .agents/skills/ — no symlink needed.
# Just commit the new skill.
cd /path/to/repo
git add .agents/skills/<name>/
git commit -m "feat(skills): add <name> skill"
git push origin main
```

## Rules

- **`.agents/skills/` is the single source of truth.** Both agents read from it.
- **No separate mirrors.** `.agents/skills/` and `.agents/skills/` are legacy — do not sync to them.
- **Trivial changes only.** Direct commit, no PR — for typo/dead-link/formatting fixes. Non-trivial changes MUST route through `issue-workflow` (see Proportionality Gate above).
- **One sync per edit session.** If you edit multiple skills, one sync at the end.
- **No content changes during sync.** Fix in `.agents/skills/` first, then sync.
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
