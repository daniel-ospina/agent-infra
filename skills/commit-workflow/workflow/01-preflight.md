> **Step 1/5** | → next: `02-commit-pr.md`

# Pre-flight Checks

## Git Lock Check

Before running any other pre-flight step, check for a stale lock file:

```bash
if [ -f .git/index.lock ]; then
  if pgrep -x git > /dev/null; then
    echo "❌ Another git process is running — cannot commit. Wait for it to finish."
    exit 1
  else
    rm .git/index.lock
    echo "Removed stale .git/index.lock"
  fi
fi
```

A stale lock (no live git process) is safe to remove. A live lock means another process owns the repo — wait.

## Doc Affiliation Check

Verify that changed docs have valid `subjects.team` front matter.

```bash
CHANGED_DOCS=$(git diff --cached --name-only --diff-filter=ACMR | grep '^docs/.*\.md$' || true)
if [ -n "$CHANGED_DOCS" ]; then
  echo "Checking document affiliation..."
  node scripts/check-doc-affiliation.cjs --files $CHANGED_DOCS || exit 1
fi
```

**Rules:**
- Triggers only on `docs/**/*.md` files (zero overhead for code-only commits)
- Uses `--diff-filter=ACMR` to catch creates, modifies, renames
- Blocks commit if validation fails (exit 1)
- Low-risk tier — skips typecheck/build for doc-only changes (mechanism separation: this "Low-risk tier" and the "Low (docs, config, CSS, strings)" risk rows in the stack tables below are pre-flight SCRIPT gates — typecheck/build skip only — distinct from the extension gates' scoping: VGATE's content-shape exemption keys on file shape at ANY tier, not on this risk tier)

## Pre-flight Verification (proportional — from proportional-gates v1.0.0)

### Language Detection

Detect the project language to route to correct checks:

```bash
# Check tracked files (not just staged) — a Python project might have zero .py staged
if git ls-files '*.py' | head -1 | grep -q .; then
  LANG=python
elif git ls-files '*.ts' '*.tsx' | head -1 | grep -q .; then
  LANG=typescript
else
  LANG=unknown
fi
```

### TypeScript / Supabase Stack (default)

**Match verification to change risk:**

| Risk | Typecheck | Build | Integration Tests | pgTAP |
|-------|-----------|-------|-------------------|-------|
| Low (docs, config, CSS, strings) | Skip | Skip | Skip | Skip |
| Medium (component/hook change) | Run if .ts/.tsx | Run if src/ | Run if integration surfaces | Run if migrations |

> **New module test gate:** Run `node scripts/check-untested-modules.cjs` for Medium+ changes. Blocks new `.ts`/`.tsx` files without matching test files. Exempts type-only files, config/constants, pure re-exports, and no-logic files. Use `--warn` for silent-run period.
| High (multi-file, DB, auth) | Always run | Always run | Always run | Always run |

> **Quality gates available on-demand (WARN only, do not block):** `npm run check:coverage-pruning`, `npm run check:arch:changed`, `npm run check:mutation` (nightly). See #6460-#6463.

### Python Stack

When `LANG=python`, use these equivalents:

| Risk | Syntax Check | Test | Integration Tests | Supabase |
|-------|-------------|------|-------------------|----------|
| Low (docs, config, strings) | Skip | Skip | Skip | Skip |
| Medium (single-file logic change) | `python3 -m py_compile` on changed .py | `python3 -m pytest` if tests/ exists | `python3 -m pytest` if integration markers | Skip |
| High (multi-file, DB, auth) | Always | Always | Always | Skip (unless supabase/ dir exists) |

**Python-specific notes:**
- Syntax check: `python3 -m py_compile` on each staged `.py` file (catches ImportErrors, syntax errors). Faster than full pytest for low-risk changes.
- Test run: `python3 -m pytest` if `tests/` or `test_*.py` files exist. No equivalent to `tsc --noEmit` — pytest is both syntax and behavior check.
- No pgTAP/replay-smoke equivalent — Python projects don't use Supabase migrations. Skip unless a `supabase/` directory is present (rare polyglot case).
- No build step — Python is interpreted. Skip.

**Skip rule:** If a check would not catch the change's failure mode, skip it. Note the skip. A reviewer validates the classification.

### Integration Tests

```bash
[ -f vitest.integration.config.ts ] && HAS_INTEGRATION=true || HAS_INTEGRATION=false
```

Run only when risk >= Medium AND integration surfaces are touched (DB queries, API calls, auth, shared state). Skip for UI-only, config, or doc changes. If run and tests fail: stop immediately and report.

### Typecheck

Run only when `.ts`/`.tsx` files changed. Skip for docs, config, CSS, or markdown-only changes.

```bash
npx tsc --noEmit
```

If fails: stop immediately and fix.

### Build

Run only when `src/` or config files changed. Skip for docs/skills/config-only changes. Build may require env vars — if it fails due to missing env vars and typecheck passed, skip build silently.

## pgTAP Tests (conditional)

Check if any **staged files** include migrations:

```bash
git diff --cached --name-only | grep -q 'supabase/migrations/' && HAS_COLUMN_DROP_MIGRATIONS=true || HAS_COLUMN_DROP_MIGRATIONS=false
```

If `HAS_COLUMN_DROP_MIGRATIONS=true` and `supabase` CLI is available:
- Announce: "Running pgTAP database tests..."
- Run: `npm run test:db` (or `supabase test db`)
- If tests fail: **stop immediately** and report. Do not commit.
- If `supabase` CLI is not available or `supabase start` is not running: skip with warning "pgTAP tests skipped — local Supabase not running"

If `HAS_COLUMN_DROP_MIGRATIONS=false`: skip silently.

> Supabase-specific gates (Replay Smoke, Column Drop Audit) are eldato-only — no `supabase/` dir in agent-infra; not applicable (issue #239).

## Skill Enforcement Audit (conditional)

Runs `scripts/ci/enforce-protocol-table.sh`. **Pass 1 is the live gate in agent-infra:** every dangerous-ops manifest skill (`enforcement/dangerous-ops.txt`) must resolve to a real `skills/<name>/SKILL.md` — a missing file is a silently broken enforcement gate. **Pass 2/3 (manifest ↔ AGENTS.md protocol table) are conditional:** they run only when AGENTS.md exists AND its protocol table is populated — in agent-infra AGENTS.md IS tracked, but its protocol table is the template placeholder (commented-out rows with `| ... |` cells, e.g. the compliance table at the top of AGENTS.md), so Pass 2/3 skip-with-note on the placeholder match (verified: the script prints "skipped — AGENTS.md protocol table matches the template placeholder"). The script's other skip branch — "AGENTS.md not found (untracked/generated)" — fires only where the file is genuinely absent (consumer repos / CI fresh checkouts); Passes 2/3 activate in consumer repos with populated tables (issue #239).

**Condition:** Only when **staged files** include changes under `skills/`, `enforcement/`, or `AGENTS.md`.

```bash
git diff --cached --name-only --no-renames | grep -qE '^(skills/|enforcement/|AGENTS\.md)' && HAS_SKILL_CHANGES=true || HAS_SKILL_CHANGES=false
```

- If `HAS_SKILL_CHANGES=true`:
  - Announce: "Running Skill Enforcement Audit..."
  - Run: `bash scripts/ci/enforce-protocol-table.sh`
  - If it fails: **stop immediately** and report. Do not commit.
- If `HAS_SKILL_CHANGES=false`: skip silently.

> Script ported into agent-infra in #239 (from eldato @ 49afc61f, blob fb4c5357). The `enforce-skills.yml` workflow (#252) runs it nightly (06:00 UTC) + on push to main + manual — drift coverage is this pre-flight trigger AND the CI gate; the pre-flight catches commit-time, CI catches main-drift not tied to a `skills/|enforcement/|AGENTS.md` commit.

## Issue Detection

Detect the linked issue **before committing** (avoids stalling mid-sequence):

1. **Branch name** — look for pattern `feat/123-*`, `fix/123-*`, `chore/123-*` → extract issue number
2. **Commit message scan** — search staged diff / recent commits for `fixes #N`, `closes #N`, `resolves #N`
3. **Ask the user** — if neither resolves: "Which issue does this work close? (or 'none')"

Store as `ISSUE_NUMBER` for use in subsequent steps.

## Branch Detection

```
Already on a feature branch (not main/master)?
  → Run the merged-branch guard below FIRST. If safe, commit here. No branch creation needed.

On main/master + ISSUE_NUMBER resolved?
  → Auto-create: git fetch origin main --quiet && git checkout -b feat/issue-{N}-{slug} origin/main
  → (slug = 3-4 word summary of the work, kebab-case)

On main/master + no ISSUE_NUMBER?
  → Ask: "What should I name the new branch?"
```

### Merged-Branch Guard (runs when already on a feature branch)

Before committing on an existing feature branch, verify it hasn't already been merged. Committing unrelated changes (e.g. skill doc fixes) onto a branch whose PR was merged can cause those changes to be silently absorbed into a squash-merge — polluting the merge with unintended content. This happened with PR #2167 where skill documentation edits were accidentally squash-merged into a pizza/sushi content PR.

```bash
BRANCH=$(git branch --show-current)

# Check if this branch has an open PR (not merged, not closed)
PR_STATE=$(gh pr view --json state --jq '.state' 2>/dev/null || echo "no-pr")

# Check if this branch's commits are already on main (merged)
git fetch origin main --quiet
if git merge-base --is-ancestor HEAD origin/main 2>/dev/null; then
  ALREADY_MERGED=true
else
  ALREADY_MERGED=false
fi
```

| Situation | Action |
|-----------|--------|
| `PR_STATE = "MERGED"` or `ALREADY_MERGED = true` | **BLOCK.** Output: "⚠️ Branch `BRANCH` has already been merged to main. Creating a new branch for this work instead." Then auto-create a new branch off `origin/main`. |
| `PR_STATE = "CLOSED"` | **WARN.** Output: "⚠️ Branch `BRANCH` has a closed (unmerged) PR. Proceeding, but consider whether this work belongs on a new branch." Then proceed. |
| `PR_STATE = "OPEN"` | **Proceed.** The branch has an active PR — changes pushed here will update it. |
| `PR_STATE = "no-pr"` and `ALREADY_MERGED = false` | **Proceed.** Fresh feature branch with no PR yet. |

## Pre-PR Freshness Check (#178/#181)

Runs AFTER the Merged-Branch Guard and BEFORE Tier Detection (the guard already
fetches and may redirect to a fresh branch — reconciling before its verdict
wastes work). Reconcile the branch with the origin default so stale checkouts
never ship:

```bash
DEFAULT_BRANCH=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')
[ -z "$DEFAULT_BRANCH" ] && DEFAULT_BRANCH="main"
git fetch origin "$DEFAULT_BRANCH" --quiet
BEHIND=$(git rev-list --count HEAD.."origin/$DEFAULT_BRANCH" 2>/dev/null || echo 0)
```

| State | Action |
|---|---|
| `BEHIND = 0` | Silent — already current. |
| `BEHIND > 0` + clean tree | `git -c commit.gpgsign=false pull --rebase origin "$DEFAULT_BRANCH"`, then RE-RUN the affected pre-flight regression tests. If the branch was previously pushed and the post-rebase push is rejected as non-fast-forward → `git push --force-with-lease`. |
| `BEHIND > 0` + dirty tree | **WARN**: "Branch is N behind origin/<default> — commit or stash first, then `git -c commit.gpgsign=false pull --rebase origin <default>`." NEVER autostash (conflict-unsafe unattended). |

**Pre-flight: the main-worktree-guard's branch-ownership gates (#265) run on every bash tool_call.** In agent-infra main (where this skill works by design), the guard allows the session's OWN-branch hygiene ops — `pull --rebase`, `rebase`, `merge origin/<default>`, `push` incl. `--force-with-lease`, `push --delete` of the own branch, `branch -D` of the own branch — so this pre-flight's commands pass on the baseline branch. If a command is blocked with a "branch ownership violated" message, the shared checkout was switched under the session: `git checkout -b` a fresh branch (M3 carve-out re-baselines) and retry.

Notes: `commit.gpgsign=false` is process-scoped and prevents headless pinentry
hangs during rebase (fleet ships squash-merged; research-verified). Condition 5
in 04-merge-deploy.md still governs overlap at merge time; repos with strict
up-to-date protection additionally use the **Auto-merge ceremony in 04-merge-deploy.md
(#500)** at merge time — Stale-Merge Recovery there only when auto-merge is
unavailable (repo settings) or the arm failed and a one-shot manual merge can still win.

## Tier Detection

Check the linked issue for a `complexity:*` label:

```bash
# Only if ISSUE_NUMBER is resolved (not 'none')
gh issue view $ISSUE_NUMBER --json labels --jq '.labels[].name' | grep '^complexity:'
```

- `complexity:micro` → **TIER = Micro**
- `complexity:standard` → **TIER = Standard**
- `complexity:complex` → **TIER = Complex**
- No label found or `ISSUE_NUMBER = 'none'` → **TIER = unknown** (classify from diff in Step 1.5 / `02-commit-pr.md`)

Store as `TIER` for subsequent steps. Write the marker file — the only channel the review-enforcer reads (a bash-exported `AGENT_ISSUE_COMPLEXITY` env var has no effect: the extension's session_start handler reads it only to warn that it is dead — `extensions/review-enforcer/index.ts` ~L670; the vestigial export was dropped in #493). Since #485 the marker selects only the micro-specific remediation message, never allow/block:

```bash
echo "$TIER" > /tmp/agent-issue-complexity
```

### Micro Tier Auto-Detection & Gate Behavior

When `TIER = Micro` or auto-detected (1 file, <20 added lines, no migrations, or docs/CSS/static-only per 02-commit-pr.md Step 1.5).

Mechanism separation: the VGATE content-shape skip is extension-side and shape-based (applies at ANY tier; code sets never skip); the review-enforcer ≥1-dispatch rule is **uniform — every tier (micro, standard, complex, unknown/unlabeled) blocks at 0 dispatches** (the pre-#485 micro branch let a 0-dispatch session through — the VGATE docs/CSS/static skip removed the backstop that made that leniency safe, so a docs-only micro commit at 0 dispatches cleared every enforced gate). The extension reads `/tmp/agent-issue-complexity` ONLY to select the micro-specific remediation message (micro skips the multi-agent code-review gate), never to allow/block. A docs-only commit at 0 dispatches is review-enforcer-blocked at every tier — labeled-micro included.

| Gate | Micro Behavior |
|------|---------------|
| Review-enforcer | **BLOCK at 0 dispatches — ≥1 sub-agent dispatch required at EVERY tier, micro included (#485)** (the gate counts any sub-agent dispatch — the `task` or `subagent` tool). The VGATE docs/CSS/static skip removed the backstop that made the pre-#485 micro leniency safe. Code sets satisfy the dispatch via VGATE's own [VGATE] verification dispatch; docs-only sets dispatch a lightweight reviewer (even a trivial one-line review counts). The marker read (/tmp/agent-issue-complexity = micro) selects the micro remediation message only |
| Verification-gate (VGATE) | **shape-gated, not tier-gated** — docs/CSS/static-only sets skip regardless of tier; code sets never skip (see Pi Extension Gates → Verification Gate below) |
| Lint/Typecheck | **KEPT** — runs in pre-commit hooks, zero agent overhead |
| Code review (Step 3) | **SKIPPED** — per commit-workflow/03-code-review.md |
| Pipeline-compliance CI gate (check a) | **KEPT — issue link required at EVERY tier, docs-only micro included (#488)** — the script's micro exemption skips checks b–e (scoping/review/plan evidence), and the docs-only shape exemption covers only check e (test evidence); no carve-out exists or is planned for the linked-issue requirement. See the #488 note below. |

**Rationale:** Micro-tier CODE commits keep full VGATE (shape-gated — the extension skips only docs/CSS/static sets, never code), and VGATE's own [VGATE] verification dispatch satisfies the review-enforcer ≥1-dispatch rule before the commit — micro code sets clear the gate with no extra ceremony. The residual case the uniform block closes is the docs-only micro commit: VGATE shape-exempts it and the multi-agent code-review gate is skipped at micro, so the ≥1 dispatch must come from a lightweight reviewer dispatch (even a trivial one-line review counts).

**#488 decision — the pipeline-compliance issue-link requirement (check a) is KEPT for docs-only shape-exempt commits, as a deliberate audit invariant.** The audit (scripts/check-pipeline-compliance.sh): check a is unconditional — it runs at every tier and every file shape; `complexity:micro` skips checks b–e (scoping comment, code-review evidence, plan doc) and the docs/skills/templates/config-only shape exemption covers only check e (test coverage — it exempts nothing about the linked issue). No docs-only carve-out exists in the script or the workflow. KEEP rationale: (1) a docs-only commit now skips VGATE (#472 shape exemption) and the multi-agent code-review gate (micro), so check a is the only deterministic, CI-enforced content gate left on it — the review-enforcer ≥1-dispatch floor is content-free by design (#485); (2) the #485 audit documented that the "docs are low-consequence" premise fails for the contract-doc subclass (skills/*.md edits encode agent behavior for every future session — #475/#492), so docs-only commits are exactly the class that must keep tracing to a deliberate issue; (3) friction is negligible for pipeline-shaped work — Issue Detection above resolves an issue before every PR-opening commit (the permitted `'none'` answer leaves no PR that check a would pass — a no-issue docs change must go through issue-creation first, which is the intended remedy, not a gate exemption). Relaxing would reopen a no-content-gate path for contract-doc changes and break the gate's "every PR traces to an issue" audit claim. No script or test change — this is a documented-rationale decision (#488).

## Wiring-Gap Check (canary-fix PRs only)

If `ISSUE_NUMBER` is resolved and not `'none'`, check for the `ci-failure` label and "typecheck-canary" in the issue title. These signal a canary-fix PR that might only address the type error without fixing the runtime gap.

```bash
ISSUE_TITLE=$(gh issue view $ISSUE_NUMBER --json title --jq '.title')
IS_CI_FAILURE=$(gh issue view $ISSUE_NUMBER --json labels --jq '.labels[].name' | grep -q '^ci-failure$' && echo true || echo false)
IS_CANARY=$(echo "$ISSUE_TITLE" | grep -qi 'typecheck-canary' && echo true || echo false)

if [ "$IS_CI_FAILURE" = "true" ] && [ "$IS_CANARY" = "true" ]; then
  echo "🔍 Canary-fix PR detected — running wiring-gap check"
  WIRING_CHECK=true
else
  WIRING_CHECK=false
fi
```

If `WIRING_CHECK=true`, before committing:

1. Identify which field/column was missing — from the `tsc` error: "Property 'X' does not exist on type 'Y'"
2. Search every data-fetching path that constructs an object of type `Y` — `.select()` calls, view queries, construction/mapping functions, API response handlers, ORM queries
3. Verify the missing field `X` is included in ALL of those paths
4. If the field appears in a component but not in the corresponding query/construction code: **BLOCK.** The fix is incomplete — the feature will compile but silently fail at runtime.
5. If the field is wired through all layers: proceed.

This guard exists because #4327/#4328 demonstrated a type error fix can mask a wiring gap: `tripadvisor_url` existed in the DB and types but wasn't fetched by `useDeals.ts`, producing a silent `undefined`.

## Pi Extension Gates (extension-enforced — per-gate scoping)

These checks are enforced by Pi extensions — each with per-gate scoping rather than a blanket tier rule: the review-enforcer applies a **uniform ≥1-dispatch block — every tier (micro, standard, complex, unknown/unlabeled) blocks at 0 dispatches** (the marker read selects only the micro-specific remediation message); VGATE is content-shape gated (docs/CSS/static-only sets exempt, code never). Neither is bypassed for code-bearing sets.

### Review Enforcer Gate

The `review-enforcer` extension blocks git operations unless at least one sub-agent was dispatched this session — the gate counts ANY sub-agent dispatch (the `task` tool or the specialized-agent `subagent` tool; content-free floor — see the micro rationale below) — **at every tier, micro included** (0 dispatches block; pre-#485 the micro branch let a 0-dispatch session through — the VGATE docs/CSS/static skip removed the backstop that made that leniency safe. The extension reads `/tmp/agent-issue-complexity` only to select the micro-specific remediation message below; it never selects allow/block).

> **Task sub-agents are exempt from the commit-time dispatch floor** (#285/#825): their review DISPATCH is parent-enforced — the parent session runs the review ceremony, so a task sub-agent's own git ops do not re-trigger the floor. The merge-registry gate still requires a recorded clean review before merge. The "every tier blocks at 0 dispatches" uniform floor describes the tier dimension; the sub-agent session shape is this documented carve-out.

```bash
# This gate fires ON the git commit/push command itself — not as a separate check.
# To satisfy it: dispatch a reviewer sub-agent BEFORE running git commit.
# Even a trivial one-line review counts.
```

**How to satisfy:**
1. Before `git commit`, dispatch a `task` sub-agent (or `subagent`-tool agent) to review your changes
2. The reviewer must return a result (even "NO ISSUES FOUND")
3. The gate counts any sub-agent dispatch (task or subagent tool) — 1 is enough
4. **Micro tier:** code sets satisfy the dispatch via VGATE's own [VGATE] verification dispatch; docs-only micro sets (VGATE content-shape exempt) dispatch a lightweight reviewer naming the diff — the multi-agent code-review gate stays skipped per 03-code-review.md

**Failure:** "No reviewers were dispatched in this session before the git operation." (micro tier receives a micro-specific message directing a lightweight docs reviewer).  
**Bypass:** `AGENT_SKIP_REVIEW_GATE=1` (emergency only)

<!-- REVIEW-ENFORCER-TIER-RULE: machine-read by extensions/review-enforcer/index.test.ts (drift pin T2) — must stay in sync with TIER_RULE in extensions/review-enforcer/index.ts. Every tier blocks at 0 dispatches (#485). -->

| Tier | Dispatch rule |
|------|---------------|
| micro | block |
| standard | block |
| complex | block |
| unknown | block |
| unlabeled | block |

<!-- /REVIEW-ENFORCER-TIER-RULE -->

### Verification Gate

The `verification-gate` extension blocks `git commit` unless every file the commit
will record has been verified by a `[VGATE]` sub-agent — for bare commits that is
"every staged file", but `-a`/`--all` sweep commits also record never-staged dirty
tracked files, so the verified set is the command's full diff scope (see the #489
paragraph below) — except where the content-shape exemption below applies.

**#489 — auto-sweep (`-a`/`--all`) commits are NOT index-scoped:** `git commit -a` /
`--all` record the tracked WORKING TREE, not just the staged index. When the
command is a pure sweep (`-a`/`--all` on every commit invocation, e.g. `git commit
-am x`, `git commit -a -m x`), VGATE verifies the
HEAD-vs-working-tree file set (`git diff HEAD --name-only` — exactly what the
sweep records) instead of the staged diff; a mixed command (sweep + bare commit in
one op, including a sweep preceded by a wrapper/negated commit such as
`sh -c 'git commit -m y' && git commit -am x`) verifies the union of staged +
working-tree files. ⚠️ Global-option spellings (`git -C repo commit --all`,
`git --no-pager commit …`) are NOT yet intercepted by the hook at all — always
invoke `git commit` directly in the repo root so VGATE fires (open #490). The verification prompt
for a sweep therefore lists WORKING-TREE files — `[VGATE] verify files: <dirty
code>. Classification: …` — even when only docs are staged: a docs-only PASS must
not unlock a sweep that would ship dirty, never-verified code. Bare/pathspec/
`--amend`-alone commits keep the staged (index) scope (#489 T2); pathspec commits
(`git commit -m x f.txt`) keep that same staged index scope — a known under-gate
for pathspec WT-path commits, tracked as residual #538. Unborn-HEAD
repos (no commits yet) fall back to the staged set — `git commit -a` on an unborn
HEAD records only the index. `gh pr` ops are unchanged (branch diff scope).

**Content-shape exemption (docs/CSS/static-only — extension-side, tier-independent):**
when the op's relevant file set (staged diff for commit; pushed-range diff for
content push where a base resolves — staged otherwise; branch diff for
`gh pr create`/merge) is ENTIRELY docs/CSS/static AND no file sits under a
build-output directory, VGATE skips the op (audited `gate_skip:
content_shape_exempt`). Code-bearing or mixed sets are NEVER exempt; among
`git commit` invocations only the bare form qualifies — `-a`/`--all`/`--amend`/
pathspec anywhere in the op re-gates the whole command (push / `gh pr create`/
merge ops with no commit invocation qualify on file shape alone).

<!-- VGATE-SHAPE-RULE: machine-read by extensions/verification-gate/index.test.ts drift test — keep in sync with SHAPE_EXEMPT_EXTENSIONS + BUILD_OUTPUT_SEGMENTS in extensions/verification-gate/index.ts -->
| Exempt extension | Build-output path segments (any depth — NOT exempt) |
|---|---|
| `.md` | `public/` `dist/` `build/` |
| `.css` | `public/` `dist/` `build/` |
| `.scss` | `public/` `dist/` `build/` |
| `.html` | `public/` `dist/` `build/` |
<!-- /VGATE-SHAPE-RULE -->
(Drift test normalizes the trailing `/` before comparing to `BUILD_OUTPUT_SEGMENTS`.)

Delete-shaped pushes (`git push origin --delete <branch>`, `git push --delete
origin <branch>`, `git push origin :<branch>`) ship no local file content and
skip VGATE before any diff computation (audited `gate_skip:
delete_push_no_content`). Content pushes verify the PUSHED RANGE — the files
the push actually ships — not the whole index: `git diff
refs/remotes/<remote>/<branch> <src>` when the remote-tracking ref exists
(2-dot), or 3-dot against the remote's main on a first push
(`refs/remotes/<remote>/main` when that ref exists, else the
`refs/remotes/origin/main` fallback). A parked-WIP index from another session
must not block an unrelated push of already-verified committed HEAD; an
up-to-date push is audited `gate_skip: push_range_empty`. ⛔ Fail-closed
fallbacks (the range scope is a best-effort resolution, never a widening):
when NO usable base exists (no tracking ref AND no `refs/remotes/origin/main`
— e.g. a fresh `git init` first push) the push keeps the staged (index) check
and can still block over parked WIP; a whole command that contains a `git
commit`, a tag/`--all`/`--tags`/`--mirror` push, a delete+content chain, a
`gh pr create`/merge anywhere in the command, an
unmappable refspec shape, or any probe failure likewise keeps the staged
check. `git branch -D`
/ `git worktree remove` are not VGATE-intercepted.

**How to satisfy:**
```bash
# Dispatch a verifier sub-agent (bare commit — staged scope):
task(prompt='[VGATE] verify files: <list staged files>. Classification: <UI|backend|doc>. Project root: <repo root>.', ...)
# For `git commit -a`/`--all` (sweep) commands the block lists the WORKING-TREE file
# set (`git diff HEAD`) — dirty tracked files that may never have been staged; list
# them in the prompt exactly as the gate named them.
```

**Format requirements (CRITICAL):**
- Prompt MUST say `verify files:` (plural) — `verify file:` (singular) will silently fail
- Response MUST include `PASS` on its own line, OR valid JSON: `{"status": "PASS", "failures": [], "verified_files": [{"path": "...", "hash": "..."}]}`
- `**VERIFIED**` is NOT enough — the gate regex looks for `PASS`

**Gotchas:**
- If staged files change after verification, hashes won't match — re-verify
- The gate extracts file paths from the prompt, not the response — make sure paths are correct
- `ELDATO_SKIP_VGATE=1` at session start disables this gate entirely (`AGENT_ALLOW_MAIN_EDITS=1` no longer does — #7470)

---

### Test-Review Hash Backstop Gate

**Purpose:** Ensure every test file has passed test-review before commit. Complements VGATE (which verifies file content quality) by verifying test correctness. Catches any code path that bypassed the test-writing → test-review mandatory gate.

**When:** Standard+Complex tier commits where staged files include `.ts`, `.tsx`, `.py`, `.sql`, `.js`, or `.jsx`.

**Skip:** Micro tier commits (tier-gated — the Mechanism below greps the issue BODY for `complexity:micro`, a third, separate micro channel from the review-enforcer's `/tmp/agent-issue-complexity` marker; VGATE is shape-gated, never micro-gated), or commits with no matching file extensions.

**Mechanism:**

```bash
# Skip for micro tier
ISSUE_BODY=$(gh issue view <N> --json body -q '.body')
IS_COMPLEXITY_MICRO=$(echo "$ISSUE_BODY" | grep -q 'complexity:micro' && echo true || echo false)
[ "$IS_COMPLEXITY_MICRO" = "true" ] && exit 0

# Check for testable files
STAGED=$(git diff --cached --name-only)
HAS_TESTABLE=$(echo "$STAGED" | grep -qE '\.(ts|tsx|py|sql|js|jsx)$' && echo true || echo false)
[ "$HAS_TESTABLE" != "true" ] && exit 0

# Check each test file for test-review hash
for FILE in $(echo "$STAGED" | grep -E '\.(test|spec|e2e)\.(ts|tsx)$|\.pg$|\.py$'); do
  # Skip deleted files
  git diff --cached --diff-filter=D -- "$FILE" | grep -q . && continue
  
  ABS_PATH=$(realpath "$FILE" 2>/dev/null || readlink -f "$FILE" 2>/dev/null || echo "$FILE")
  if command -v sha256sum >/dev/null 2>&1; then
    FILE_HASH=$(echo -n "$ABS_PATH" | sha256sum | cut -d' ' -f1)
  else
    FILE_HASH=$(echo -n "$ABS_PATH" | shasum -a 256 | cut -d' ' -f1)
  fi
  HASH_FILE="$HOME/.pi/agent/test-review/${FILE_HASH}.json"
  
  if [ ! -f "$HASH_FILE" ]; then
    echo "⛔ BLOCKED: test-review never completed for $FILE"
    echo "   Run test-writing → test-review before committing."
    exit 1
  fi
  
  STATUS=$(python3 -c "import json; print(json.load(open('$HASH_FILE'))['status'])" 2>/dev/null || echo "ABSENT")
  
  case "$STATUS" in
    CLEAN)
      echo "✅ $FILE — test-review: CLEAN"
      ;;
    CAPPED)
      ISSUES=$(python3 -c "import json; d=json.load(open('$HASH_FILE')); print('; '.join(i['description'][:80] for i in d.get('capped_issues',[])))" 2>/dev/null || echo "unknown")
      echo "⚠️ $FILE — test-review: CAPPED ($ISSUES)"
      ;;
    *)
      echo "⛔ BLOCKED: invalid hash status '$STATUS' for $FILE"
      exit 1
      ;;
  esac
done

# TTL cleanup: remove hashes older than 30 days
find "$HOME/.pi/agent/test-review/" -name '*.json' -mtime +30 -delete 2>/dev/null || true

# Orphan cleanup: remove hashes where test file no longer exists
for HF in "$HOME/.pi/agent/test-review/"*.json; do
  [ ! -f "$HF" ] && continue
  FP=$(python3 -c "import json; print(json.load(open('$HF')).get('test_file_path',''))" 2>/dev/null || true)
  [ -n "$FP" ] && [ ! -f "$FP" ] && rm -f "$HF"
done
```

**Tri-state verdict:**
- **ABSENT** (no hash file) → **BLOCK** — test-review was never completed
- **CAPPED** (hash exists, status=CAPPED) → **WARN** — proceed with documented issues
- **CLEAN** (hash exists, status=CLEAN) → proceed

**Post-commit cleanup:** After successful commit, delete consumed hash files for CLEAN-status files in this commit.
