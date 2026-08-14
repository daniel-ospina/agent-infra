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

## Shared Checkout Policy

The main checkout is a **SHARED HUB** that stays on `main`. Feature work happens ONLY in worktrees. Only the branch owner — or after verifying no active checkout (`git worktree list`) — deletes a branch. This is the hub discipline from the [multi-agent git coordination research](docs/research/2026-08-07-multi-agent-git-coordination.md) (Layer 2).

> **Never** start feature work in the main checkout. **Never** delete a branch without checking `git worktree list` for active checkouts.

## Escaping the main-checkout guard (deliberate mid-session escalation)

If a session is **guard-blocked but functional** — alive, issuing tool calls, stranded in the shared main checkout where the guard refuses the recovery git ops needed to un-strand (`git checkout main`, `git pull`, branch recovery) — it can open a **sanctioned, bounded, audited, session-scoped** window with one touch:

```bash
# must be its OWN bash tool call inside a guard-loaded session
touch ~/.pi/agent/.allow-main-edits  # recovery: <reason>
```

- **One command per touch.** A combined `touch ... && git checkout main` in ONE bash call does NOT work — the guard classifies the whole command before stamping, so the git part blocks and the touch never runs. The recovery git op goes in the **FOLLOW-UP** call.
- **15-minute expiry, refresh by re-touch.** The window is mtime-based (fixed 15-min TTL, not env-overridable), re-read on every tool call, never cached. Re-running the same `touch` refreshes the window; a marker exactly 15 minutes old is expired and the recovery op is blocked again.
- **Session-scoped + guard-stamped.** Only the guard's tool_call handler writes the session id + reason stamp; a human-terminal `touch` produces an unscoped empty file → inert → blocked. Headless/print-mode sessions with a null session id cannot escalate.
- **Delegation does NOT work.** A subagent does not inherit the parent's `PI_SESSION_ID` — recovery must run in the session that created the marker; delegating the touch to a subagent re-scopes the marker to the subagent's id or fails-closed.
- **Hung processes are NOT helped.** A hung process cannot issue any tool call, so it can never touch a marker. The hung-process class has no owner (process-supervision follow-up required) — see the guard README (`extensions/main-worktree-guard/README.md`) for the full contract, audit location, and verification checklist.

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

### Stranded main checkout — the ONLY sanctioned recovery is a terminal one-liner (#206)

- **Problem:** A main checkout stuck behind/stranded (auto-sync can't ff-pull, the guard blocks agent-side `checkout`/`pull`) is unrecoverable FROM the agent — the guard's escape hatches are env-only (`AGENT_ALLOW_MAIN_EDITS=1`) and cannot be set on a running process.
- **Fix (the ONLY sanctioned recovery):** the human runs ONE command in a **terminal** (terminals are not intercepted by the guard):
  ```bash
  cd <repo> && git checkout main && git pull --ff-only
  ```
  Never launch a nested/background `pi` to "escape" the guard — that is how a 29h fleet hang happened (2026-08-11→12, #206).

## Launching Nested pi

> **Never launch an unbounded nested pi.** Every nested or background `pi`
> launch MUST carry a hard timeout (30 minutes — the bounded-launch template
> below), a log redirect (`> /tmp/<launch-unique>.log 2>&1` — unique per
> launch; the template names it via `mktemp`), and a liveness
> marker — a `[task-heartbeat]` line written to the log at regular intervals
> (markers require `TASK_HEARTBEAT=1` AND `PI_MODE=print` set explicitly on
> the launch — the runtime writes them only when both are present; the task
> tool injects both, a manual nested launch must set them itself).
> Abort semantics: no marker within the window → the process is dead or
> blocked at the OS level → ABORT; markers present but no completion → the
> timeout is the bound — do NOT extend it. Note: marker presence ≠ progress —
> a gate-stalled pi keeps writing markers, which is exactly why the hard
> deadline is non-negotiable. On abort: kill the launch, surface the failure
> to the user, and never wait indefinitely — a silent wait is the failure
> mode this rule eliminates. The ONLY sanctioned guard escape is the terminal
> one-liner in `using-git-worktrees` (Guard Escape section), executed by the
> user in their own terminal — never by an agent tool, which the
> main-worktree guard blocks. When a bounded form is impossible, do not
> launch — escalate to the user instead.

### Bounded-launch template — the ONLY sanctioned form of nested pi

```bash
# Bounded nested pi launch — the ONLY sanctioned form of nested pi:
LOG="$(mktemp /tmp/nested-pi.XXXXXX)"
PI_MODE=print TASK_HEARTBEAT=1 pi -p "<prompt>" > "$LOG" 2>&1 &
launch_pid=$!
echo "launched $launch_pid → $LOG"

# Deadline watchdog — portable sleep-deadline + kill -0 liveness probe
# (no GNU timeout on macOS): SIGTERM at 1800s; SIGKILL after a 60s grace.
( sleep 1800; if kill -0 "$launch_pid" 2>/dev/null; then kill "$launch_pid"; pkill -P "$launch_pid" 2>/dev/null; sleep 60; kill -9 "$launch_pid" 2>/dev/null; fi ) &

# Liveness check + abort trigger — [task-heartbeat] markers land on stderr
# every 30s (2>&1 merged). No marker within 60s → the process is dead or
# blocked at the OS level → ABORT. Markers present → the launch is ALIVE and
# the 30-min deadline watchdog is the only remaining bound — do NOT kill here:
sleep 60
if grep -q '\[task-heartbeat\]' "$LOG"; then
  echo "ALIVE — bounded by the 30-min deadline watchdog"
else
  echo "NO MARKER — ABORTING (process dead/blocked at OS level)"
  kill "$launch_pid" 2>/dev/null
  pkill -P "$launch_pid" 2>/dev/null
  echo "ABORTED — surfacing to user"
  exit 1
fi
```

> Template semantics: `LOG` is created via `mktemp` BEFORE the launch (`$$` is the shell pid — two backgrounded launches in one bash call would collide on a `$$`-derived name; `${launch_pid}` inside the redirect is wrong because the redirect is evaluated before `$!` is captured). The deadline watchdog is the primary guarantee (SIGTERM at 30 min, SIGKILL after 60s grace — the portable equivalent of GNU `timeout --kill-after=60 1800`, which does not exist on macOS). The abort trigger is CONDITIONAL: `kill` executes only when grep finds no marker — a healthy launch that prints ALIVE is never killed at 60s. `pkill -P "$launch_pid"` is best-effort (BSD pkill exists on macOS); grandchildren may linger (accepted — full tree-kill is an extension-side concern, out of scope).

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

**Never:**
- Launch an unbounded nested/background `pi` — always use the bounded-launch template in `## Launching Nested pi` (hard timeout + log redirect + liveness marker; abort on no-marker).

**Always:**
- Bound every nested/background pi launch (`PI_MODE=print TASK_HEARTBEAT=1`, `mktemp` log, `sleep 1800` + `kill -0` watchdog) and prefer the terminal one-liner for guard escapes.
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
