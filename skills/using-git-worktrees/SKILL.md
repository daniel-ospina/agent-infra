---
name: using-git-worktrees
description: Use when starting feature work that needs isolation from current workspace or before executing implementation plans - creates isolated git worktrees with smart directory selection and safety verification
domain: operations
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

> **Source:** Canonical copy at `skills/using-git-worktrees/SKILL.md`.

> **Fork note:** Local override of `superpowers:using-git-worktrees` v5.0.0. Changes: (1) Integration section updated — no longer REQUIRED by executing-plans (now CONDITIONAL). See #908. (2) Added Step 0: Detect Main Repo Root — all path logic is anchored to `$MAIN_REPO` (resolved via `git rev-parse --git-common-dir`) so nested worktrees never get created when the skill runs from inside an existing agent worktree.

# Using Git Worktrees

## Overview

Git worktrees create isolated workspaces sharing the same repository, allowing work on multiple branches simultaneously without switching.

**Core principle:** Systematic directory selection + safety verification = reliable isolation.

**Announce at start:** "I'm using the using-git-worktrees skill to set up an isolated workspace."

## Step 0: Detect Main Repo Root

**Always run this first.** When called from inside an agent worktree, `$PWD` and `git rev-parse --show-toplevel` return the worktree's path, not the main repo. All directory checks and worktree creation must use `$MAIN_REPO` as the base to prevent nested worktrees.

```bash
# git-common-dir points to the shared .git dir, which lives in the main repo
GIT_COMMON=$(git rev-parse --git-common-dir)
MAIN_REPO=$(cd "$GIT_COMMON/.." && pwd)
# For bare repos or worktrees where common-dir is inside .git/worktrees/:
# $GIT_COMMON resolves to /path/to/main/.git, so $MAIN_REPO = /path/to/main ✓
```

All subsequent `ls`, path construction, and `git worktree add` commands use `$MAIN_REPO` as the working directory, not `$PWD`.

## Directory Selection Process

Follow this priority order:

### 1. Check Existing Directories

```bash
# Check in $MAIN_REPO, not $PWD
ls -d "$MAIN_REPO/.worktrees" 2>/dev/null     # Preferred (hidden)
ls -d "$MAIN_REPO/worktrees" 2>/dev/null      # Alternative
```

**If found:** Use that directory. If both exist, `.worktrees` wins.

### 2. Check CLAUDE.md

```bash
grep -i "worktree.*director" CLAUDE.md 2>/dev/null
```

**If preference specified:** Use it without asking.

### 3. Ask User

If no directory exists and no CLAUDE.md preference:

```
No worktree directory found. Where should I create worktrees?

1. .worktrees/ (project-local, hidden)
2. ~/.config/superpowers/worktrees/<project-name>/ (global location)

Which would you prefer?
```

## Safety Verification

### For Project-Local Directories (.worktrees or worktrees)

**MUST verify directory is ignored before creating worktree:**

```bash
# Check if directory is ignored (respects local, global, and system gitignore).
# Run from $MAIN_REPO so the check resolves against the main repo's .gitignore,
# not the current worktree's.
(cd "$MAIN_REPO" && git check-ignore -q .worktrees) 2>/dev/null \
  || (cd "$MAIN_REPO" && git check-ignore -q worktrees) 2>/dev/null
```

**If NOT ignored:**

Per Jesse's rule "Fix broken things immediately":
1. Add appropriate line to .gitignore
2. Commit the change
3. Proceed with worktree creation

**Why critical:** Prevents accidentally committing worktree contents to repository.

### For Global Directory (~/.config/superpowers/worktrees)

No .gitignore verification needed - outside project entirely.

## Creation Steps

### 1. Detect Project Name

```bash
# Use $MAIN_REPO (from Step 0), not the current worktree's toplevel
project=$(basename "$MAIN_REPO")
```

### 2. Create Worktree

```bash
# Determine full path — always anchored to $MAIN_REPO so nested worktrees
# never get created inside an existing agent worktree
case $LOCATION in
  .worktrees|worktrees)
    path="$MAIN_REPO/$LOCATION/$BRANCH_NAME"
    ;;
  ~/.config/superpowers/worktrees/*)
    path="$HOME/.config/superpowers/worktrees/$project/$BRANCH_NAME"
    ;;
esac

# Run git worktree add from the main repo so the new worktree lands beside it,
# not nested inside the current (possibly already-a-worktree) directory
cd "$MAIN_REPO"
git fetch origin main --quiet
git worktree add "$path" -b "$BRANCH_NAME" origin/main
cd "$path"
```

### 3. Run Project Setup

Auto-detect and run appropriate setup:

```bash
# Node.js
if [ -f package.json ]; then npm install; fi

# Rust
if [ -f Cargo.toml ]; then cargo build; fi

# Python
if [ -f requirements.txt ]; then pip install -r requirements.txt; fi
if [ -f pyproject.toml ]; then poetry install; fi

# Go
if [ -f go.mod ]; then go mod download; fi

# MCP config — .mcp.json is gitignored (contains embedded API keys) so worktrees
# don't inherit it. Symlink from main repo so all MCP tools (NVIDIA, Supabase, etc.)
# are available in Claude Code sessions opened inside this worktree.
if [ -f "$MAIN_REPO/.mcp.json" ] && [ ! -e "$path/.mcp.json" ]; then
  ln -s "$MAIN_REPO/.mcp.json" "$path/.mcp.json"
fi

# .env.local — gitignored secrets file (Supabase URL, service role key, API keys).
# Same pattern as .mcp.json. Without this, integration tests in the worktree fail with
# "VITE_SUPABASE_URL must be set" because process.env doesn't pick them up.
if [ -f "$MAIN_REPO/.env.local" ] && [ ! -e "$path/.env.local" ]; then
  ln -s "$MAIN_REPO/.env.local" "$path/.env.local"
fi
```

### 4. Verify Clean Baseline

Run tests to ensure worktree starts clean:

```bash
# Examples - use project-appropriate command
npm test
cargo test
pytest
go test ./...
```

**If tests fail:** Report failures, ask whether to proceed or investigate.

**If tests pass:** Report ready.

### 5. Report Location

```
Worktree ready at <full-path>
Tests passing (<N> tests, 0 failures)
Ready to implement <feature-name>
```

## Quick Reference

| Situation | Action |
|-----------|--------|
| `.worktrees/` exists | Use it (verify ignored) |
| `worktrees/` exists | Use it (verify ignored) |
| Both exist | Use `.worktrees/` |
| Neither exists | Check CLAUDE.md → Ask user |
| Directory not ignored | Add to .gitignore + commit |
| Tests fail during baseline | Report failures + ask |
| No package.json/Cargo.toml | Skip dependency install |

## Common Mistakes

### Skipping ignore verification

- **Problem:** Worktree contents get tracked, pollute git status
- **Fix:** Always use `git check-ignore` before creating project-local worktree

### Assuming directory location

- **Problem:** Creates inconsistency, violates project conventions
- **Fix:** Follow priority: existing > CLAUDE.md > ask

### Proceeding with failing tests

- **Problem:** Can't distinguish new bugs from pre-existing issues
- **Fix:** Report failures, get explicit permission to proceed

### Hardcoding setup commands

- **Problem:** Breaks on projects using different tools
- **Fix:** Auto-detect from project files (package.json, etc.)

### Creating nested worktrees from inside another worktree

- **Problem:** When the skill runs from inside an agent worktree, using `$(git rev-parse --show-toplevel)` or `$PWD` resolves to the current worktree, not the main repo. `git worktree add` then creates the new worktree nested inside the parent (e.g. `.worktrees/agent-a/.worktrees/agent-b/`), which accumulates cruft and breaks cleanup.
- **Fix:** Always derive `$MAIN_REPO` in Step 0 via `git rev-parse --git-common-dir` and anchor every path (ls, check-ignore, worktree add) to `$MAIN_REPO`. Never use `$PWD` or `--show-toplevel` for path construction in this skill.

### Missing MCP tools in worktree sessions (NVIDIA, Supabase, etc.)

- **Problem:** `.mcp.json` is gitignored (contains embedded API keys) and is therefore absent from all worktrees. When Claude Code is opened in a worktree directory, no MCP servers register → `issue-scoping`, `code-review`, `prototype-review` and any skill that routes to NVIDIA falls back to Claude sub-agents.
- **Fix:** Step 3 symlinks `$MAIN_REPO/.mcp.json` into the new worktree. The server uses absolute paths to the main repo's `server.ts` and `.env`, so MCP tools work correctly once the symlink exists.

## Example Workflow

```
You: I'm using the using-git-worktrees skill to set up an isolated workspace.

[Detect main repo: MAIN_REPO=/Users/jesse/myproject (even if called from inside a worktree)]
[Check $MAIN_REPO/.worktrees/ - exists]
[Verify ignored - git check-ignore (run from $MAIN_REPO) confirms .worktrees/ is ignored]
[cd $MAIN_REPO && git worktree add /Users/jesse/myproject/.worktrees/auth -b feature/auth]
[Run npm install]
[Symlink .mcp.json from main repo → /Users/jesse/myproject/.worktrees/auth/.mcp.json]
[Run npm test - 47 passing]

Worktree ready at /Users/jesse/myproject/.worktrees/auth
Tests passing (47 tests, 0 failures)
Ready to implement auth feature
```

## Red Flags

**Never:**
- Create worktree without verifying it's ignored (project-local)
- Skip baseline test verification
- Proceed with failing tests without asking
- Assume directory location when ambiguous
- Skip CLAUDE.md check
- Use `$PWD` or `git rev-parse --show-toplevel` for path construction — always use `$MAIN_REPO` from Step 0

**Always:**
- Resolve `$MAIN_REPO` via `git rev-parse --git-common-dir` before anything else (Step 0)
- Follow directory priority: existing > CLAUDE.md > ask
- Verify directory is ignored for project-local
- Auto-detect and run project setup
- Verify clean test baseline

## Integration

**Called by:**
- **brainstorming** (Phase 4) - REQUIRED when design is approved and implementation follows
- **subagent-driven-development** - REQUIRED before executing any tasks
- **executing-plans** - CONDITIONAL: only when dirty working tree or parallel agents need isolation
- Any skill needing isolated workspace

**Pairs with:**
- **commit-workflow** (Step 3.8) — handles worktree teardown after merge
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
