# Issue #206 — Research

Status: DRAFT (Stage 2 — Research)
Branch: feat/206-never-unbounded-pi
Date: 2026-08-12
Level: project | Complexity: standard | Team: organisation-design-team

## Background

Incident: a nested `pi -p` hung for 105,150s (~29.2h) on 2026-08-11→12.
Issue objective: codify a hard rule — never launch an unbounded nested pi;
every launch carries `timeout <N>` + log redirect + liveness marker; the
terminal one-liner (`cd <repo> && git checkout main && git pull --ff-only`) is
the ONLY sanctioned guard escape. Target: grep of the 3 skills shows
rule+pattern; `node scripts/check-skill-lint.mjs` exit 0.

All findings below are repo-grounded against the canonical tree at
`skills/`, `scripts/`, `extensions/`, `bin/`, `pi-bootstrap/` in this worktree
(branch `feat/206-never-unbounded-pi`).

---

## 1. Current state of the three target skills

### 1a. Guard-escape / terminal-recovery wording in `skills/using-git-worktrees/SKILL.md`

**Result: NONE present in the canonical repo copy** (283 lines). Grep for
`checkout main`, `--ff-only`, `guard`, `escape`, `recovery`, `terminal`
returns **zero matches** in the whole file. The Align-phase finding that the
runtime `~/.pi/agent/skills` copy has no such wording is re-verified here, and
now confirmed against the canonical repo copy too (both are empty of it —
the machine's runtime copy is a real-folder mirror, see §4).

Closest existing content (main-checkout discipline, not an escape):

- `skills/using-git-worktrees/SKILL.md:23` — `## Shared Checkout Policy`
- `:25` — "The main checkout is a **SHARED HUB** that stays on `main`. Feature
  work happens ONLY in worktrees."
- `:27` — "> **Never** start feature work in the main checkout. **Never**
  delete a branch without checking `git worktree list` for active checkouts."

There is no recovery/escape section at all: no way to "get back to a known
state from a stuck session" is documented. The one-liner and guard-escape
designation must be **added**, not referenced.

### 1b. Bounded-launch patterns (`timeout`, liveness, heartbeat, log redirect, `2>&1`) in the 3 skills

Grep for `timeout|liveness|heartbeat|2>&1|log|pid`:

| Skill | Matches |
|---|---|
| `using-git-worktrees/SKILL.md` | **0** (no bounded pattern at all) |
| `parallel-orchestrator/SKILL.md` | **1** — Pre-Warming example, line 97 |
| `subagent-driven-development/SKILL.md` | **0** (no bounded pattern at all) |

The single match, `skills/parallel-orchestrator/SKILL.md:97`:

```
npm install --silent 2>&1 | tail -1 && npx tsc --noEmit > /tmp/typecheck-preflight.txt 2>&1 &
```

This is a background launch with a **log redirect** (`> /tmp/... 2>&1`) but
**no `timeout`, no liveness marker, no PID, no abort path**. The
skill's own framing (line 107: "If still running, warn and proceed") even
allows proceeding while the background job is unbounded. The "Background
Execution Note" (`:123-127`) recommends `bash &` + temp-file redirects with no
bounding guidance at all. **No skill anywhere in the repo documents a bounded
`timeout N ... > log 2>&1` + liveness-marker launch pattern.** I3's premise is
confirmed: the examples that exist today are unbounded.

### 1c. Natural insertion points (section headings)

| Skill | Never-unbounded rule | Bounded-launch pattern |
|---|---|---|
| `using-git-worktrees` | `## Red Flags` (`:255`, holds the Never/Always hard-rule lists — add Never bullet); the guard-escape one-liner fits a new "Guard Escape / Terminal Recovery" block between `## Red Flags` (`:255`) and `## Integration` (`:272`), or as an Always bullet in Red Flags (main-checkout recovery context) | `## Example Workflow` (`:237`) and/or `## Quick Reference` table (`:193`) — add a bounded-launch row; or a new `## Launching Nested pi` section near Example Workflow |
| `parallel-orchestrator` | `## Anti-Patterns` table (`:142`) — add row "Unbounded background/pi launch" (table already has "Infinite review cycles — Always cap at 10 cycles", `:146`, and "Waiting for background tasks synchronously") | `## Pre-Warming Pattern` (`:91`) — retrofit the line-97 example with `timeout` + liveness marker; `## Background Execution Note` (`:123`) — state the never-unbounded launch rule next to the `bash &` guidance |
| `subagent-driven-development` | `## Red Flags` Never list (`:229`) — add Never bullet (list already has the worktree anti-nesting Never items, `:254-255`); structural sibling: `## Worktree Ownership Rule (anti-nesting)` (`:22`) is the closest "hard rule" section and is a natural neighbor for a "Never-Unbounded-Launch Rule" section | `## Red Flags` (fix wording for the failure) or a short new section after `## Worktree Ownership Rule` (`:22`) — mirrors how the worktree rule pairs a hard rule with an explicit pattern |

---

## 2. Lint surface (`scripts/check-skill-lint.mjs`)

**What it validates, per SKILL.md file** (118 files checked, baseline: 0 issues):

1. **Frontmatter parses** — opening `---`, closing `---`, non-empty YAML.
   js-yaml is dynamically imported; YAML parse errors (e.g. "Nested mappings
   not allowed" from an unquoted `: ` in a description) are P0.
2. **Required fields** — `name` and `description` present (`:195`).
3. **name ↔ directory match** — `name` must equal dirname, or `shared-<dir>`
   for routing wrappers (`:203-208`).
4. **description non-empty** (`:209-211`).
5. **allowed-tools** — required only when `type` is
   `Bounded`/`Workflow`/`Routing` (`:216-219`); `reference`/typeless exempt.
   `parallel-orchestrator` is `type: reference` with `allowed-tools` already
   present; `subagent-driven-development` and `using-git-worktrees` have no
   `type` field — unaffected.
6. **Duplicate keys** — indentation-aware dup detection in frontmatter
   (`:134-171`).
7. **Forbidden phrase** — regex `/sequential\s+or\s+parallel/i` tested against
   the **entire file content**, not just frontmatter (`:224-227`). This is the
   only body-content check.

**Will adding a section to the 3 skills pass?** Yes — the linter does not
validate body markdown structure. Risks to guard against in Scope/Plan:

- **Risk A (only real body risk):** any new rule/example text containing
  "sequential or parallel" (case-insensitive) → P0. The bounded-launch
  template must avoid this phrasing (e.g. don't write "run sequentially or
  parallel").
- **Risk B:** editing a frontmatter `description` with an unquoted `: ` →
  YAML "Nested mappings not allowed" → P0. (None of the 3 descriptions need
  editing; keep it that way.)
- **Risk C:** duplicate frontmatter keys if new fields are added — avoid
  adding keys to existing skills.

**Limitation to record:** `check-skill-lint.mjs` is a **frontmatter + phrase
guard, not a rule checker** — it cannot enforce the never-unbounded rule's
presence in body text. The grep target (Indicators 1–3) is the real
verification; enforceability of the rule text is a Scope decision (§Implications,
drift-guard option).

---

## 3. Pattern precedent — bounded pi/process launches already in the repo

The runtime already implements **both halves** of the bounded pattern; the
skills simply never document them.

**A. Timeout + kill (closest overall precedent)** — `extensions/subagent/index.ts` (#137):

- `:239` — `export const DEFAULT_TASK_TIMEOUT_MS = 1_800_000;` (30 min)
- `:241` — env-overridable: `SUBAGENT_TASK_TIMEOUT_MS`
- `:458-464` — timer fires `killTree("SIGTERM")` at the timeout
- `:463` — `killTree` = recursive process-tree kill (`extensions/shared/tree-kill.ts`, "#137: recursive process-tree kill for abort/timeout")
- `:194-195` — `result.stopReason === "timeout"` ("the worker was killed, not done")
- `:442` — "Heartbeat: prevent silence timeout during long tool calls"

**B. Liveness markers (the "liveness marker" precedent)** — `extensions/task-heartbeat.ts` (#176):

- `:50` — `export const HEARTBEAT_MARKER_PREFIX = "[task-heartbeat]";`
- `:14-19` — lifecycle markers: `ready`, `tool_start`, `tool_end`, `turn_start`, `turn_end`, `tick`
- `:54-56` — interval: min 5s, max 300s, default 30s

**C. Silence/liveness timeout tiers** — `extensions/builtin-tools/index.ts`:
- `:11-15` — "Tier 1: first-output timeout (60s)"; "Tier 2: state-aware
  silence detection (30 min, `TASK_HEARTBEAT_TIMEOUT_MS`)" driven by
  `[task-heartbeat]` markers on stderr.

**D. PID-file locks** — `extensions/loop-enforcer/scheduler.ts`:
- `:34-59` — `.pid` lock files with staleness check `process.kill(pid, 0)`
  (`:47`: "Check if a live PID lock exists"; stale → ignore).

**E. Log redirect in scripts** — `scripts/cron-quality-gates.sh:146`:
`if node "$test_file" >/tmp/cron-mutation-out.$$ 2>&1; then` (redirect with
PID-suffixed temp file).

**F. Drift-guard precedent for the future rule-text test** —
`extensions/shared/test-git-freshness.mjs` (#178): reads
`skills/issue-workflow/SKILL.md` via **repo-relative** path
(`PROJECT_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..")`)
and runs source assertions (the "Branch Gate" drift guard), plus real-git
runtime fixtures. This is the exact pattern for pinning Indicators 1–3 at
Scope (per Align Stage 3).

**G. Tension to document — why the escape must be a TERMINAL one-liner:**
`extensions/main-worktree-guard/classify-git.mjs:30` classifies
`git checkout main` as `block:checkout-branch` (and `:6-8` lists
pull/merge/rebase as destructive) **when invoked through the agent's bash
tool**. `extensions/main-worktree-guard/index.ts:13` — "The only escape hatch
is `AGENT_ALLOW_MAIN_EDITS=1`... There is NO auto-bypass." An in-agent `git
checkout main && git pull --ff-only` is therefore guarded/blocked in the
shared main checkout — the one-liner can only be executed from the **user's
terminal**, outside agent tools. This is precisely why the issue designates a
"terminal one-liner" as the guard escape; the rule text should say so
explicitly, and must not instruct agents to run it themselves.

---

## 4. Repo → runtime sync mechanism (do edits take effect automatically?)

**Mechanism chain:**

- `manifest.json` — `"skills/": { "kind": "symlink", "essential": true }`
  (skills are declared as a symlink into `~/.pi/agent/skills`).
- `bin/agent-infra.js` (`init`/`update`) — `forceSymlink(SKILLS_SRC,
  PI_SKILLS)` (`:182`, `:290`), **but only when `~/.pi/agent/skills` is not
  already a real directory** (`:178-181`: "⚠️ ~/.pi/agent/skills exists as a
  real directory — skipping").
- `pi-bootstrap/setup.sh` (`:193-210`) — if the runtime skills dir is a
  symlink into this repo, keep it ("updates via git pull"); otherwise
  **materialize a real folder** with `cp -R "$INFRA_ROOT/skills/." "$DEST/skills"`
  ("skills refreshed (local extras preserved)" — a merge, not a replace).
- `sync.sh` — `git pull --ff-only origin main` then `./pi-bootstrap/setup.sh`.
- `extensions/auto-sync.ts` — at `session_start`, when `AGENT_INFRA_PATH` is
  set and the repo is behind, runs `sync.sh` (`AGENT_SYNC_MODE=auto`) → the
  skills folder gets refreshed.

**Current machine state (verified):** `~/.pi/agent/skills` is a **real
directory** (100 entries, not a symlink — `ls -la` shows `drwxr-xr-x`, no
`->` target). So on this machine, editing repo skills does **not** propagate
instantly; the runtime copy is refreshed on the next sync (`sync.sh` /
auto-sync at a later session start), and even then `cp -R` merges rather than
cleans.

**Scope implication:** issue #206's target is correctly scoped to **repo
skills + lint** (grep against the canonical `skills/` tree — repo-relative
paths, as in the #178 drift guard). Runtime propagation to `~/.pi/agent/skills`
requires the normal sync path and is **out of scope**; it should be noted as a
follow-up (the drift-guard test must read repo-relative paths so it stays
green regardless of runtime copy state).

---

## 5. Web (1 query, supporting only)

GNU `timeout(1)` (man7 / coreutils manual): "run a command with a time limit"
— starts a command and kills it if still running after the duration; Stack
Overflow's canonical bash pattern (background + `$!` PID + sleep + kill) and
"`timeout 15s command` as the simpler built-in solution". Confirms `timeout N`
as the standard bounded-launch primitive; the liveness-marker half is already
exemplified in-repo by `[task-heartbeat]` (§3B). No additional external
pattern needed — the repo precedent is authoritative and richer.

---

## Implications for Scope

1. **All three edits are ADD-style.** Neither the rule nor the bounded pattern
   exists in any of the 3 skills today; the one-liner is absent from the
   canonical repo copy of `using-git-worktrees` (Align's I1 premise re-verified
   against the repo, not just runtime). Scope must draft the exact rule text,
   not reference existing text.
2. **One example needs a retrofit, not a rewrite:** `parallel-orchestrator`
   Pre-Warming (`SKILL.md:97`) already has the log-redirect half
   (`> /tmp/... 2>&1 &`) — wrap it in `timeout <N>` + add a liveness marker +
   abort-on-no-marker. `using-git-worktrees` and `subagent-driven-development`
   get the full template new.
3. **Pick timeout value N and abort trigger at Scope.** Precedent to anchor on:
   30 min (1,800,000 ms) in `extensions/subagent/index.ts:239`; 30 min silence
   tier in `builtin-tools/index.ts:14`; 30s marker cadence in
   `task-heartbeat.ts:56`. Codify "no liveness marker within N → abort
   immediately, never wait indefinitely" (Align gap 3) — the 29h hang was a
   no-abort-decision failure.
4. **Lint-pass constraints:** new body text must avoid the phrase
   "sequential or parallel" (case-insensitive P0 over the whole file) and any
   unquoted `: ` in descriptions; avoid adding frontmatter keys. Baseline is
   118 files / 0 issues.
5. **Drift-guard is the real enforcement.** `check-skill-lint.mjs` cannot check
   body text; to pin Indicators 1–3 use the #178 pattern
   (`extensions/shared/test-git-freshness.mjs` — source assertions on
   repo-relative `skills/` paths). Decide test-file location/name at Scope.
6. **Frame the one-liner as human-terminal-only.** `main-worktree-guard`
   blocks `git checkout main` via agent bash (`classify-git.mjs:30`,
   `block:checkout-branch`) — the rule must state the escape is executed by
   the user in their terminal, never by an agent tool; the guard's own
   escape-hatch precedent is `AGENT_ALLOW_MAIN_EDITS=1` (`index.ts:13`).
7. **Runtime propagation is out of scope.** This machine's
   `~/.pi/agent/skills` is a real-dir mirror refreshed by `sync.sh` /
   auto-sync — repo edits land there on the next sync. The drift-guard must
   assert repo-relative paths so it never depends on runtime copy state.
