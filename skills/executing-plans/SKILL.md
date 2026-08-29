---
name: executing-plans
description: Use when you have a written implementation plan to execute in a separate session with review checkpoints
domain: engineering
allowed-tools: read write edit bash web_search web_fetch todo_write task grep find
steps:
  - name: workspace_setup
    type: skill
    gate: auto
  - name: parallel_check_start
    type: gate
    gate: checkpoint
    token_phase: start
    requires: [workspace_setup]
    # #4907: run `/Users/danielospina/swarm/operations/coordination/parallel_work_check.sh start` (C1 —
    # delegates the behind-check to checkout_guard; $PARALLEL_CHECK_BIN overrides
    # the path) before touching code. Set CHECKOUT_GUARD_ENFORCE=1. read /
    # loop_enforcer are the in-session escape; force-pass via /tmp/parallel-check-force.json.
  - name: complexity_ratings
    type: skill
    gate: auto
    requires: [parallel_check_start]
  - name: load_plan
    type: skill
    gate: auto
    requires: [complexity_ratings]
  - name: dependency_verification
    type: skill
    gate: auto
    requires: [load_plan]
  - name: implement_batch
    type: skill
    gate: auto
    requires: [dependency_verification]
  - name: parallel_check_implement
    type: gate
    gate: checkpoint
    token_phase: implement
    requires: [implement_batch]
    # #4907: run `/Users/danielospina/swarm/operations/coordination/parallel_work_check.sh implement` (C4 —
    # base-drift + symbol re-check; $PARALLEL_CHECK_BIN overrides the path)
    # before verification. read / loop_enforcer are the in-session escape;
    # operator force-pass via /tmp/parallel-check-force.json (one-shot).
  - name: verify_batch
    type: skill
    gate: verifier
    requires: [parallel_check_implement]
  - name: verification_before_completion
    type: skill
    gate: verifier
    requires: [verify_batch]
  - name: worktree_teardown
    type: skill
    gate: auto
    requires: [verification_before_completion]
  - name: commit
    type: skill
    gate: human_approval
    requires: [worktree_teardown]
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

**Human approval gate:** presents output for user review. Pipeline advances after approval.
**Verifier gate:** dispatches AI reviewers. Pipeline auto-advances when clean.

**Human approval gate:** presents output for user review. Pipeline advances after approval.
**Verifier gate:** dispatches AI reviewers. Pipeline auto-advances when clean.

**Human approval gate:** presents output for user review. Pipeline advances after approval.
**Verifier gate:** dispatches AI reviewers. Pipeline auto-advances when clean.

> **Source:** Canonical copy at `skills/executing-plans/SKILL.md``.
>
v5.0.0 — stripped NVIDIA/MCP tool calls. Restored batched execution flow. Added dirty-state guard and research context injection. All sub-agents use Pi `task` tool with isolated context.

# Executing Plans

## Overview

> **Ontology:** `tortoise/docs/ONTOLOGY.md` (v3.1, canonical) — fetch: `gh api repos/daniel-ospina/tortoise/contents/docs/ONTOLOGY.md --jq .content | base64 -d` (§5 = controlled vocabulary).

Load plan, review critically, execute tasks in batches, report progress between batches (informational — not blocking), pause only when taxonomy-matching decisions arise. Verification runs after each batch via isolated sub-agents. Fall back to the controller on failures.

**Core principle:** Batch execution with informational progress reports. Blocking pauses only for genuine decisions.

**Announce at start:** "I'm using the executing-plans skill to implement this plan."

### Between-Phase UI Verification (agent-browser)

When a phase touches UI files (`*.tsx` components or pages), run a lightweight agent-browser check before proceeding to the next phase:

```bash
# Verify the affected route renders in dev
agent-browser open http://localhost:3000/<affected-route> --screenshot=/tmp/verify-phase.png
agent-browser errors 2>&1

# Mobile viewport check
agent-browser open http://localhost:3000/<affected-route> --viewport=375x812 --screenshot=/tmp/verify-phase-mobile.png
```

**Gate**: If the page crashes (white screen, 500, unhandled error), **BLOCK** the next phase — fix before continuing. If warnings (layout issues, missing elements), **WARN** and proceed.
**Skip**: Backend-only phases with no `.tsx` changes.

**CTA Click-Through (between phases):** After completing a phase that touches UI, verify the CTA remains functional:

```bash
# Navigate to the affected page and verify CTA buttons work
agent-browser open http://localhost:3000/<affected-route> --screenshot=/tmp/verify-phase-cta.png

# Check for CTA elements
agent-browser evaluate "document.querySelectorAll('a[href], button').length" 2>&1 > /tmp/verify-cta-count.txt && cat /tmp/verify-cta-count.txt

# Verify no broken links on the page
agent-browser errors 2>&1 > /tmp/verify-phase-errors.txt && cat /tmp/verify-phase-errors.txt
```

**Gate:** CTA elements must be present and functional. Broken CTAs or missing buttons block the next phase.

**Quality Gates (WARN only):** After completing a phase that touches `.ts`/`.tsx` files, run quality checks:
```bash
npm run check:coverage-pruning   # flag untested new code
npm run check:arch:changed       # catch layer violations
```
Surface any gaps before proceeding. These are informational — they do not block.

## Human Input Taxonomy (inlined from human-input-framework v2.0.0)

### Research-Before-Ask Protocol (MANDATORY — runs BEFORE any pause)

When a taxonomy match occurs, do NOT pause immediately. Run this protocol first:

1. **Internal Research** — Search codebase for existing patterns, conventions, or prior decisions
2. **External Research** — Perplexity queries for best practices, how others solve this
3. **Decision:**
   - >80% confidence → Apply decision, note with ponytail comment. DO NOT PAUSE.
   - 50-80% confidence → Apply best-supported option, note rationale. DO NOT PAUSE.
   - <50% confidence → Pause with structured question + research findings.
   - P0 consequence (data loss, security, irreversible, cost >$10/mo, legal/compliance) → Pause regardless.

### Taxonomy Categories

Pause and present structured questions when a decision involves ANY of:

1. **Ontology changes** — new tables, columns, relationships, semantic meaning changes
2. **UX changes** — visible user-facing behavior/layout/flow changes not explicitly requested
3. **One-way doors** — destructive operations, data migrations, schema drops, force pushes
4. **Third-party dependencies** — new API integrations, service subscriptions
5. **Cost impact** — changes increasing recurring costs by >$1-3/month
6. **Scope expansion** — implementing beyond what was requested

**Tie-breaking rule:** When uncertain whether a decision matches the taxonomy, RESEARCH FIRST. Pause only if research is inconclusive OR P0 (data loss, security, irreversible, cost >$10/mo, legal/compliance).

Everything else → Agent decides autonomously with a brief note, open to iteration.

### Third-Party Dependency Detection

When Step 1.5 runs, "unfamiliar" means: a third-party npm package imported in files the plan will touch, that is NOT covered by the plan's `### Pattern Research` section.

**Detection algorithm:**

1. **Collect target files:** Parse the plan's task list for `**Files:**` entries. Extract all `Create:` and `Modify:` paths. Also scan task step code blocks for import statements in new-file code.

2. **Extract imports:** For `Modify:` files, read the file and extract import statements with a non-relative, non-alias package specifier. For `Create:` files (don't exist yet), extract imports from the plan's code blocks for those files. Skip files that can't be read (treat as empty — no imports).

   Regex pattern to match third-party imports:
   ```
   /(?:import\s+.*?\s+from\s+['"]|require\s*\(\s*['"])([^.@/][^'"]*)['")]/
   ```

   Exclude:
   - Relative imports (`./`, `../`)
   - Alias imports (`@/` — project internal)
   - Node.js built-ins (`fs`, `path`, `crypto`, `stream`, `http`, `https`, `url`, `os`, `events`, `util`, `buffer`, `child_process`, `tls`, `net`, `dns`, `readline`, `zlib`, `querystring`, `assert`, `cluster`, `dgram`, `domain`, `punycode`, `string_decoder`, `tty`, `vm`, `worker_threads`)
   - Type-only imports (`import type { ... } from '...'`)

3. **Parse Pattern Research:** Read the plan's `### Pattern Research` section using an **anchored, line-level exact heading match** (`^### Pattern Research$`) — a substring match would let epic-brief headings such as `### UX Pattern Research` / `### Tech Stack Research` falsely satisfy coverage. Those epic-brief headings are PRIOR_RESEARCH context and **never** coverage evidence (issue #231 D5). Extract library/SDK/package names that appear in section headings or findings text. Also note `> Gate skipped`, `> Bucket [name] skipped`, and `> Research skipped: no demonstrated gap` justifications.

4. **Cross-reference:** For each extracted package name, check if it (or its parent scope, e.g. `@supabase/supabase-js` matches `supabase`) is mentioned in Pattern Research. A package is "covered" if:
   - Its name appears in a Pattern Research bucket heading or finding
   - The Pattern Research explicitly mentions skipping it with a valid reason (e.g., "uses in-repo wrapper exclusively") — a **documented skip takes precedence over findings-date absence** (issue #231 H5)
   - The Pattern Research says "plan touches zero third-party deps" AND no third-party imports were found

5. **Determine unfamiliar:** Any package NOT covered by Pattern Research is "unfamiliar". Also treat as unfamiliar if:
   - Pattern Research is absent from the plan entirely
   - Pattern Research exists, contains **actual findings**, but carries **no `> **Findings date:** YYYY-MM-DD` stamp** — findings-date ABSENT → unfamiliar directly (fail-safe re-verify; NO plan-date fallback for the coverage question — legacy unstamped plans get re-verified, issue #231 D4). **Carve-out (issue #231 H5): a documented whole-section skip is NOT "findings-date absent" — a block carrying `> Gate skipped: <justification>` / `> Bucket [name] skipped: <justification>` / `> Research skipped: no demonstrated gap` takes precedence over the stamp rule (per Step 4); only blocks containing actual findings are subject to the stamp requirement.**
   - The stamped findings are older than 6 months by **findings date** (staleness threshold unchanged; plan date plays no role in the new algorithm)
   - The plan references a different major version than what's imported (detected via package.json or import style)

6. **Result:** A list of `[package_name, reason_unfamiliar]` tuples.

## The Process

### Step 0: Workspace Setup

**Proportional isolation (inlined from proportional-gates v1.0.0):**

| Risk | Isolation |
|------|-----------|
| Low (docs, config, 1-2 files) | Plain branch acceptable. No worktree needed. |
| Medium (3+ files, shared infrastructure) | Worktree recommended. Plain branch OK for single-file. |
| High (multi-system, migrations, auth) | Worktree required. Stash uncommitted changes first. |

**Never start on main/master regardless of risk.**

**If worktree is needed:** Invoke `using-git-worktrees` skill once, in the controller session. If already inside an existing worktree, skip.

**If plain branch is acceptable:**
1. Run `git status --porcelain` to check for uncommitted changes
2. If changes exist on main: `git stash push -m "pre-<branch>-wip"` (optional for Low risk with no TS changes)
3. `git checkout -b feat/issue-<N>-<slug>`
4. **Dirty-state guard** (worktree only): Check for uncommitted changes that look like partial implementation. If found, surface options but default to reset-and-re-execute. Do NOT silently overwrite partial state.

**Pre-warming typecheck (proportional):** Run `npx tsc --noEmit` in background when changes touch `.ts`/`.tsx` files. Skip for non-code or config-only changes. When run, start before Step 1 to eliminate cold-start latency — by the time the plan is reviewed, typecheck is already complete or failing fast.

**Never create a worktree from inside a worktree.**

## Proportional Gating Summary

> This skill uses proportional gates (see proportional-gates v1.0.0). Instead of "always run X," match verification depth to change risk and novelty. A reviewer sub-agent validates gate-skip decisions. The gating decisions scale with: code impact, surface risk, novelty, and reversibility.


### Step 0.5 — Complexity Ratings Extraction (P0-3)

Before executing any tasks, extract domain complexity ratings from the scoping plan comment. These ratings drive proportional verification depth.

```bash
ISSUE_NUMBER=<from plan doc or branch name>
SCOPING_PLAN=$(gh issue view $ISSUE_NUMBER --json comments --jq '.comments[] | select(.body | contains("<!-- issue-scoping:")) | .body' | tail -1)

if [ -n "$SCOPING_PLAN" ]; then
  UX_RATING=$(echo "$SCOPING_PLAN" | awk '/^\| UX \|/ {print $3}')
  ARCH_RATING=$(echo "$SCOPING_PLAN" | awk '/^\| Architecture \|/ {print $3}')
  ONTOLOGY_RATING=$(echo "$SCOPING_PLAN" | awk '/^\| Ontology \|/ {print $3}')
  ACCESSIBILITY_RATING=$(echo "$SCOPING_PLAN" | awk '/^\| Accessibility \|/ {print $3}')
else
  echo "No scoping plan found — skipping complexity-axis checks"
  UX_RATING=""
  ARCH_RATING=""
  ONTOLOGY_RATING=""
  ACCESSIBILITY_RATING=""
fi

# Normalize: lowercase, trim
for var in UX_RATING ARCH_RATING ONTOLOGY_RATING ACCESSIBILITY_RATING; do
  eval "$var=$(echo \"${!$var}\" | tr '[:upper:]' '[:lower:]' | xargs)"
  # Empty or invalid → empty (skip checks)
  case "${!$var}" in
    low|medium|high) ;;
    *) eval "$var=" ;;
  esac
done
```

Pass ratings to Step 3 verifier as context. When all ratings are empty, verifier runs only typecheck + tests (existing behavior).

### Step 1: Load and Review Plan
1. Read plan file
2. Review critically — identify any questions or concerns about the plan
3. If concerns: Raise them with your human partner before starting
4. If no concerns: Create TodoWrite and proceed

### Step 1.5: Third-Party Dependency Verification (proportional)

**Proportional dependency verification (inlined from proportional-gates v1.0.0):**

| Situation | Action |
|-----------|--------|
| Dep already used elsewhere in codebase | Skip verification — pattern is known |
| Dep is well-known stdlib-adjacent | Skip — common knowledge |
| Dep is new to codebase AND not in plan Pattern Research | Verify: 1-2 Perplexity calls |
| Dep is novel, unfamiliar, AND no Pattern Research | Verify: 2-3 calls. Pause if unavailable. |

**Perplexity unavailable:** If dep is well-known, proceed with note. Only pause for genuinely novel deps.

This catches deps missed at plan-writing time and prevents hallucinated API usage.

#### Sub-step 1.5a — Detect Unfamiliar Dependencies

Run the detection algorithm from [Third-Party Dependency Detection](#third-party-dependency-detection) above. Produces a list of unfamiliar packages.

**If zero unfamiliar deps:** Skip to Step 2. Document the skip with a brief note (e.g., "Step 1.5: all third-party deps covered by plan Pattern Research — skipped").

**If unfamiliar deps found:** Proceed to Sub-step 1.5b.

#### Sub-step 1.5b — Perplexity Verification

For each unfamiliar dep, fire 2 separate `web_search` calls (can be issued in parallel across all deps):

1. **API verification call** — "What is the current API for [package]? How do you import and use it? Show the most common usage patterns for the latest stable version."
2. **Pitfalls call** — "What are common pitfalls, breaking changes, deprecations, or migration notes for [package]? What should developers watch out for?"

**Record findings:** For each dep, synthesize the two responses into a brief summary: correct import syntax, key API surface, version-specific gotchas. Append as context before proceeding to Step 2.

#### Sub-step 1.5c — Perplexity Unavailable

**Proportional response:** If the dep is well-known and used in 2+ other contexts, proceed with a note. Only pause if the dep is genuinely novel AND Perplexity is the only way to verify its API surface. When pausing, surface:

```
⚠️ Perplexity unavailable. The plan touches unfamiliar third-party deps that were not verified at plan-writing:
- [dep1] — [why unfamiliar]
- [dep2] — [why unfamiliar]

Options:
(a) Resolve perplexity (API key / credits) and say "continue"
(b) Proceed without verification — I accept the risk of hallucinated API usage
(c) Skip only [specific dep] — it's an internal dependency I know well
```

Wait for explicit user choice. Default to (a). Never auto-select.

**For 5xx errors / network failures:** Retry 3× with exponential backoff (1s, 2s, 4s) + jitter ±200ms. On final failure, surface same pause message.

**For 200 with empty content:** Surface: "Perplexity returned no usable content for [dep]. Cannot verify API surface."

#### Sub-step 1.5d — Proceed

After all unfamiliar deps verified, append findings as context for the implementation session. If verification surfaces a major API change (deprecated method, breaking change since plan was written), flag it explicitly before proceeding — the implementer may need to adjust the plan. Proceed to Step 2 (Execute Batch).

### Label Management — Execution Start

Before executing any tasks, manage workflow-state labels:

```bash
OWN_ING_LABEL="implementing"

**Status check:** Verify issue status is `planned` or `implementing` before starting. Warn if `dropped` or `failed` — do not auto-resume without human confirmation. Document `doc_status` transitions alongside label changes.

# 1. Self-cleanup: remove own stale implementing label from a prior crashed run
if gh issue view $ISSUE_NUMBER --json labels --jq '.labels[].name' | grep -q "^${OWN_ING_LABEL}$"; then
  echo "🧹 Removing stale '${OWN_ING_LABEL}' label (from a prior incomplete run)"
  gh issue edit $ISSUE_NUMBER --remove-label "$OWN_ING_LABEL" || {
    echo "⚠️ Failed to remove stale label — continuing anyway"
  }
fi

# 2. Warn-and-confirm: check for OTHER in-progress labels (exclude own)
OTHER_LABELS=$(gh issue view $ISSUE_NUMBER --json labels --jq '.labels[].name' \
  | grep -E '^(scoping|planning|implementing)$' \
  | grep -v "^${OWN_ING_LABEL}$" || true)
if [ -n "$OTHER_LABELS" ]; then
  echo "⚠️ Issue #$ISSUE_NUMBER already has in-progress label(s): $OTHER_LABELS"
  echo "   Another agent may be working on this issue."
  # Present the warning to the user. Ask: "Continue anyway?"
fi

# 3. Apply own implementing label (idempotent)
gh issue view $ISSUE_NUMBER --json labels --jq '.labels[].name' | grep -q '^implementing$' \
  || gh issue edit $ISSUE_NUMBER --add-label implementing
```

**Known residual race:** Between self-cleanup and label-apply, another agent could apply a conflicting label. This is acceptable — GitHub labels are advisory, not locking primitives.

**Canary-fix detection:** If the issue has the `ci-failure` label and "typecheck-canary" in its title, the fix may only address a type error without fixing the runtime gap. As part of implementation, ensure the fix wires the field through all data-fetching layers — not just the type. Identify every path that constructs or fetches the affected type (`.select()` calls, view queries, mapping functions, API handlers) and verify the plan covers each one. The commit-workflow preflight §Wiring-Gap Check will gate this again before merge.

### Step 2: Execute Batch
**Default: First 3 tasks**

For each task:
1. Mark as in_progress
2. Follow each step (plan has bite-sized steps). Use judgment — if a step is clearly unnecessary given what has already been built, note the skip and why.
   - **For test-writing steps** (steps containing "Write the failing test", "Write tests", or referencing a test file): invoke the `test-writing` skill to guide test creation. The skill enforces Red-Green-Refactor and a 7-point quality self-check.
3. Run verifications as specified
4. If a step requires a taxonomy-matching decision: run the Research-Before-Ask Protocol. If research is inconclusive or P0, STOP, present structured question with findings, wait for answer
5. Mark as completed

### Step 2.5: Plan Fidelity Gate

<HARD-GATE>

**Purpose:** Mechanically verify that files changed on disk match what the plan said to change. This catches plan-implementation drift before verification runs — silent scope creep, missed steps, and unplanned files that slip through when the implementer takes a "better" path without updating the plan.

**Blocking rule:** This gate MUST pass before Step 3 verification. If the plan has no task list (pre-refactoring plan doc), skip this gate with a note.

#### 2.5a — Extract Planned Files

Parse every task in the plan doc's `### Task N:` blocks. Extract all paths from each task's `**Files:**` block — `Create:`, `Modify:`, and `Test:` lines. Produce a set of planned paths (normalized — relative to repo root, no `./` prefix).

**Edge cases:**
- Tasks with glob patterns (e.g., `Modify: src/components/*/index.tsx`) → expand via `ls` before comparing
- Tasks with no `**Files:**` block → flag as "task missing Files block" (P2 — implementer should add one, but don't block)
- Task references a file that the plan says to "create if missing" → treat as both Create and Modify

#### 2.5b — Extract Actual Changes

```bash
git diff --name-only HEAD
```

This gives the set of files actually modified or created in the working tree (unstaged changes). Produce a set of actual paths.

#### 2.5c — Mechanical Comparison

Compare the planned set against the actual set. Classify every divergence into one of three categories:

| Classification | Detection | Action |
|----------------|-----------|--------|
| **Missed** | File in planned set but NOT in actual set | **BLOCK.** The plan says to change this file but it wasn't touched. Either (a) the implementer skipped a step, or (b) the step was unnecessary. If (b), the implementer MUST add a comment explaining the skip before retrying the gate. |
| **Extra** | File in actual set but NOT in planned set | **WARN.** Check if the file is an expected side-effect (config regeneration, type generation, lockfile churn). If not — it's unplanned scope. Surface with the task's Intent/Acceptance for a decision. If the file serves the same Intent as a planned task and its Acceptance is satisfied, accept with a note. Otherwise flag. |
| **Different approach** | Same file in both sets, but the implementation takes a fundamentally different path than the plan described | **Gate on Intent.** Read the task's `**Intent:**` and `**Acceptance:**` fields. If the implementation still satisfies both → accept + note divergence for plan update. If Acceptance is violated or Intent is unmet → flag. |

#### 2.5d — Fidelity Report

Emit a structured report before proceeding:

```
📋 Plan Fidelity Gate Report
  Planned files: N
  Actual files changed: M

  ✅ Matched: X files
  ⚠️ Missed: Y files
     - path/to/missed.ts — [task reference / reason]
  🔶 Extra: Z files
     - path/to/extra.ts — [expected side-effect? | maps to which task Intent?]
  🔀 Different approach: W files
     - path/to/changed.ts — Intent: [satisfied?] | Acceptance: [satisfied?]

  Verdict: PASS | BLOCK (reason)
```

**When BLOCK:** Surface missed files to the implementer. They must either implement the missing changes or annotate the plan doc with a skip justification. Re-run the gate after. Max 2 retries — on 3rd failure, surface to user.

**When PASS:** Proceed to Step 3 verification.

**Skip entirely when:** The plan doc has no `### Task N:` blocks (pre-refactoring plan). Document the skip: "Step 2.5: No task blocks found in plan — fidelity gate skipped."

</HARD-GATE>

### Step 3: Verification (per batch)

<HARD-GATE>

**Verification sub-agent dispatch must return PASS before proceeding to the next batch.** The `verification-gate` extension blocks git operations (`git commit`, `git push`, `gh pr create`, `gh pr merge`) until the verifier sub-agent returns PASS with matching file hashes for all changed files.

**Mandatory:** After each batch completes, dispatch a verification sub-agent via the `subagent` tool:

```
subagent(agent='verifier', task='verify files: <space-separated list>. Classification: <UI|backend|both>. Project root: <PROJECT_ROOT>.', cwd=<PROJECT_ROOT>)
```

The verifier reads the `### Verification Plan` from the plan doc (if present) and runs applicable commands. Falls back to existing behavior if no verification plan exists.

**Verifier commands:**

| Layer | Command | When |
|-------|---------|------|
| typecheck | `npx tsc --noEmit` | Always |
| unit | `npm test` | Always |
| integration | `npm run test:integration` | DB/API surfaces in verification plan |
| e2e smoke | `npm run test:e2e:smoke` | Critical paths, depth=smoke |
| e2e full | `npm run test:e2e:critical` | Multi-page flows, depth=full |

**Backward compatible:** If no verification plan exists in the plan doc (pre-refactoring plan docs), fall back to existing: typecheck + `npm test`.

**ISSUE block format:**
```
ISSUE:
  check_type: <type>
  severity: P0|P1|P2
  location: <file>:<line> or [section name]
  description: <what's wrong>
  suggestion: <how to fix>
```

A verification with zero issues = CLEAN.

#### Complexity-Axis Checks (P0-2 — lightweight, pre-commit)

**When:** Domain ratings available from Step 0.5 extraction. Skip when all ratings are empty.

```bash
# UX checks — component catalog + design tokens
if [ "$UX_RATING" = "medium" ] || [ "$UX_RATING" = "high" ]; then
  echo "=== UX Complexity-Axis Checks ==="
  
  # Check for hardcoded colors (design token bypass)
  if git diff --cached --name-only | grep -qE '\.(tsx|css)$'; then
    git diff --cached | grep -E 'bg-amber-|bg-yellow-|bg-gray-|bg-red-|bg-blue-|bg-green-' &&       echo "ISSUE: check_type: design-token | severity: P2 | location: <grep output> | description: hardcoded Tailwind color used instead of design token | suggestion: use semantic token (bg-primary, bg-card) or hex token (bg-[#FFD147])" || true
    git diff --cached | grep -E 'text-gray-|text-slate-|text-zinc-' &&       echo "ISSUE: check_type: design-token | severity: P2 | location: <grep output> | description: hardcoded text color used instead of design token | suggestion: use text-primary or text-secondary" || true
  fi
fi

# Architecture checks — wrapper compliance
if [ "$ARCH_RATING" = "medium" ] || [ "$ARCH_RATING" = "high" ]; then
  echo "=== Architecture Complexity-Axis Checks ==="
  
  # Check for direct external service imports bypassing wrappers
  if git diff --cached | grep -qE "from ['"]twilio['"]|from ['"]@sendgrid|from ['"]resend"; then
    echo "ISSUE: check_type: wrapper-compliance | severity: P0 | description: direct external service import bypasses in-repo wrapper | suggestion: use in-repo wrapper (sms.ts, email.ts, dispatcher.ts)"
  fi
fi

# Ontology checks — migration safety
if [ "$ONTOLOGY_RATING" = "medium" ] || [ "$ONTOLOGY_RATING" = "high" ]; then
  echo "=== Ontology Complexity-Axis Checks ==="
  
  # Check migration timestamp ordering
  if git diff --cached --name-only | grep -q 'supabase/migrations/'; then
    npm run check:migrations 2>&1 || echo "ISSUE: check_type: migration-safety | severity: P0 | description: migration timestamp check failed | suggestion: run npm run check:migrations and fix timestamp ordering"
    
    # Check types regenerated
    if [ -f src/integrations/supabase/types.ts ]; then
      git diff --cached --name-only | grep -q 'src/integrations/supabase/types.ts' ||         echo "ISSUE: check_type: type-alignment | severity: P1 | description: migration added without regenerating types | suggestion: run npm run generate:types and commit types.ts"
    fi
  fi
fi
```

### Playwright Functional Verification (CPI-9 — UI batches only)

**When:** The batch touches UI files AND the plan doc has a journey map.

**Pipeline:** Planner agent explores localhost from journey map → Generator produces tests → Execute → Healer auto-repairs locators. Human reviews patches.

**Gate:** Tests fail AND Healer cannot fix = BLOCK. Planner/Generator cannot produce = WARN.

**Flakiness prevention:** networkidle before screenshots, animations disabled, dynamic content masked.

**Skip when:** No journey map in plan doc, OR batch has no UI file changes.
 The JSON result with file hashes is produced as an optional machine-readable sidecar (`/tmp/verify-<batch>.json`).

**Gate:** If verifier returns issues, fix and re-dispatch (max 2 retries). Do NOT proceed to the next batch until zero issues remain. On 3rd failure: surface to user.


</HARD-GATE>

Use the same model as the current session — omit the `model` parameter or pass the current session's model. Do NOT specify a different model for sub-agents.

**Inputs to the sub-agent:**
- `plan_text`: the plan tasks covered by this batch
- `files_written`: list of files modified/created
- `acceptance_criteria`: from the plan
- `research_context`: if a research brief exists for this plan, pre-read and inject as `## Verified Research Context` header + content

**The sub-agent should:**
1. Read the implemented files
2. Verify each acceptance criterion is met
3. Run any specified tests
4. Return ISSUE blocks (zero issues = CLEAN) with unmet criteria + failing tests, plus optional JSON sidecar with file hashes

**On issues found:** Fix them, then re-dispatch verification (max 2 retries). On 3rd failure → the orchestrator (you, the main session) takes over:

1. Read the unmet criteria and failing tests
2. Fix the issues directly (you have full context the verification sub-agent lacked)
3. Re-run verification
4. If THIS also fails → halt and surface to user with options to (a) provide guidance, (b) skip and proceed, (c) abort

The orchestrator escalation gives one more recovery attempt before waking the human.

### Step 4: Progress Report (Informational — NEVER STOP)

When batch complete and verified:
- Show what was implemented (files written, shell commands run)
- Show verification output (PASS / FAIL details)
- **▶ CONTINUE IMMEDIATELY to next batch. Do NOT pause. Do NOT ask "shall I continue?"**
- The user can interrupt at any time if they want to provide feedback

**This is an informational checkpoint, not a gate. Never stop after a progress report.**

### Step 5: Continue

- Execute next batch, repeat Steps 2-4 until complete
- If user provides feedback: apply changes before next batch

### Step 6: Complete Development

After all tasks complete and verified:

<HARD-GATE>

**Verification gate extension fires at completion. Do NOT claim "done" without verification evidence.**

The `verification-gate` extension (loaded in this session) blocks `git commit`, `git push`, `gh pr create`, and `gh pr merge` until the verifier sub-agent returns PASS with matching file hashes. All files must be verified before git operations succeed.

**Required evidence before claiming "done":**
1. Verifier sub-agent returned `{"status": "PASS"}` with verified file hashes
2. Typecheck passes (0 errors)
3. Tests pass (0 failures)
4. For UI changes: browser screenshot shows page renders correctly
5. No regressions in unaffected code

**If verification fails:** fix and re-verify. Do NOT claim "done" with failing checks. Do NOT bypass the gate.

</HARD-GATE>

1. **Run verification gate:** Invoke `verification-before-completion` to prove the work.
   - Typecheck must pass. Tests must pass. No regressions.
   - For features with UI: render the affected pages, verify they load correctly.
   - If verification fails: fix the issue and re-verify. Do NOT claim "done" with failing checks.
2. **Verification clean → proceed:**

**Label Transition:**
```bash
# Remove implementing, add implemented
gh issue edit $ISSUE_NUMBER --remove-label implementing || true
gh issue view $ISSUE_NUMBER --json labels --jq '.labels[].name' | grep -q '^implemented$' \
  || gh issue edit $ISSUE_NUMBER --add-label implemented
```

- Announce: "I'm using the commit-workflow skill to land this work."

### Step 6.5 — Worktree Teardown

After verification passes and before handoff to commit-workflow, clean up the worktree if one was created in Step 0:

```bash
TOPLEVEL=$(git rev-parse --show-toplevel)
GIT_COMMON=$(git rev-parse --git-common-dir)
if [ "$GIT_COMMON" != ".git" ] && [ "$GIT_COMMON" != "$TOPLEVEL/.git" ]; then
  WORKTREE_PATH="$TOPLEVEL"
  BRANCH=$(git branch --show-current)
  MAIN_REPO=$(cd "$GIT_COMMON/.." && pwd)
  cd "$MAIN_REPO"
  git worktree remove --force "$WORKTREE_PATH" 2>/dev/null || echo "Warning: worktree cleanup failed"
  git branch -D "$BRANCH" 2>/dev/null || true
fi
```

If not in a worktree: skip silently.
- **REQUIRED SUB-SKILL:** Use `commit-workflow`
- Follow that skill's full sequence: commit → draft PR → code-review gate → auto-merge → doc update

## Human Gates

The `commit` step (Step 6 handoff) is a `human_approval` gate in this skill's frontmatter, and the checkpoint stops below ("When to Stop and Ask") are its checkpoint gates — every stop surfaces a request for human input.

### Approval Routing

When a gate fires, the agent MUST invoke the approval router to surface the request:

```bash
# Portable invocation (works from ANY repo checkout — #1402 rollout):
python3 -c "
import os, sys
sys.path.insert(0, os.environ.get('SWARM_ROOT', os.path.expanduser('~/swarm')))
from operations.coordination.approval import request_approval
request_approval('product-implementer', artifact='<plan-doc>.md', context='<checkpoint> approval for issue <N>', requires_human=False)
print('Approval request created')
"
```

Routine gates do NOT pop a human dialog: with `requires_human=False` (the default) the request routes through the VSM hierarchy (product-implementer → product-strategist → team-strategist → human), so the reviewer is the requester's `reports_to` role (a pi role — e.g. product-strategist for product-implementer). The request is logged to the per-repo store `~/.swarm/approvals/<repo>.json` and that role approves via `review_approval()`. Do NOT set `APPROVAL_NO_NOTIFY=0` — it overrides the daemon kill-switch.

Use `requires_human=True` for genuine human gates (epics, P0): that routes to 'human'. **Human gates are NEVER rate-limited and NEVER auto-approved** (#1402). With Slack forwarding configured (SLACK_BOT_TOKEN + SLACK_APPROVAL_CHANNEL in `~/.swarm.env`), the request is posted to Slack by the slack-bridge — the human answers there. Without Slack, the request is logged to the per-repo store `~/.swarm/approvals/<repo>.json` and an osascript notification fires (suppressed by `APPROVAL_NO_NOTIFY=1`).

**Conversation protocol (#1402) — approvals are a back-and-forth, not a one-shot:**
1. After `request_approval(...)`, monitor feedback: `python3 -c "from operations.coordination.approval import approval_feedback; print(approval_feedback('<req_id>'))"` — human replies in the Slack thread are mirrored into `approvals.json` (`thread` entries) by the slack-bridge within ~5s.
2. If the human asks a question or gives feedback, **answer it** — post your response as a follow-up request in the SAME thread:
   ```python
   request_approval('product-implementer', artifact='<same-artifact>',
                    context='RE: <original_req_id> — <your answer to the human>',
                    requires_human=True, parent='<original_req_id>')
   ```
   The slack-bridge posts follow-ups with `parent` into the parent's Slack thread, so the human sees your answer in context.
3. Continue monitoring until the request resolves: `pending_approvals('human')` shrinks when the human accepts/rejects (Socket Mode buttons or `review_approval()`).
4. **Approved** → proceed with the gate. **Denied/feedback** → revise per the feedback and re-request (new request, same thread via `parent`). Never silently proceed past a denied gate, and never spam: a NEW request per revision is correct — dedupe only collapses identical pending requests.

## When to Stop and Ask

**STOP executing ONLY when:**
- Research-Before-Ask protocol is inconclusive on a taxonomy-matching decision
- A P0 gate is triggered (data loss, security, irreversible, cost >$10/mo, legal/compliance)
- Hit a blocker mid-batch (missing dependency, test fails >2 attempts, instruction unclear)
- Plan has critical gaps preventing starting
- You don't understand an instruction AND research doesn't help

**ALWAYS research before stopping.** Never stop with a bare question — include research findings and why the decision still needs input.

**Research before asking for clarification.** Run internal + external research first. Ask only when research is inconclusive.

## When to Revisit Earlier Steps

**Return to Review (Step 1) when:**
- Partner updates the plan based on feedback
- Fundamental approach needs rethinking

**Don't force through blockers** — stop and ask.

## Remember
- Review plan critically first
- Follow plan steps exactly
- Run Step 1.5 third-party dependency verification before implementing (Standard + Complex only)
- Don't skip verifications — Step 3 is mandatory after every batch
- Reference skills when plan says to
- Between batches: report and **continue** (don't gate)
- Stop when blocked or when taxonomy-matching decision arises
- Never start implementation on main/master branch without explicit user consent

## Label Cleanup

If this skill exits early (error, user abort, or any non-completion path) before Step 6, remove the `implementing` label:

```bash
gh issue edit <ISSUE_NUMBER> --remove-label implementing || true
```

Do not leave `implementing` on issues where work is not actively progressing.

## Integration

**Required workflow skills:**
- **using-git-worktrees** — MANDATORY: always invoked in Step 0; stash uncommitted changes before creation
- **writing-plans** — Creates the plan this skill executes
- **commit-workflow** — Complete development after all tasks (Step 6)
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
