---
name: code-review
description: MANDATORY code review for standard+complex PRs. Dispatches parallel reviewers. Skipping ships unreviewed code to production.
domain: engineering
version: 3.2.0
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
steps:
  - name: test_coverage_check
    type: skill
    gate: auto
    produces: [coverage_report]
  - name: eligibility_and_analysis
    type: skill
    gate: auto
    requires: [test_coverage_check]
    produces: [pr_analysis]
  - name: dispatch_reviewers
    type: parallel
    gate: auto
    requires: [eligibility_and_analysis]
    produces: [review_findings]
  - name: confidence_scoring
    type: skill
    gate: verifier
    requires: [dispatch_reviewers]
    produces: [confidence_scores]
  - name: fixer_loop
    type: skill
    gate: auto
    requires: [confidence_scoring]
    produces: [fixes_applied]
  - name: post_and_log
    type: skill
    gate: auto
    requires: [fixer_loop]
    produces: [review_posted]
---

**Verifier gate:** dispatches AI reviewers. Pipeline auto-advances when clean.


> **Canonical:** `agent-infra/skills/code-review/SKILL.md` — git-tracked source of truth. Pi reads via `~/.pi/agent/skills`; consumers hard-link into `operations/skills`.
>
> **Unified v3.2.0** — agent-neutral. Consolidates Claude (v1.8.0) and Pi (v2.0.0) versions. Test coverage Step 0, 5-agent review (Agent #2 split into shallow + deep), convergence-gated fixer loop, `--standard-tier` flag, Supabase error logging, merge-dedup step. Uses agent-neutral sub-agent dispatch.

# Code Review

Provide a code review for the given pull request.

## Arguments

`code-review <PR_NUMBER> [--re-review] [--standard-tier]`

- `PR_NUMBER`: the pull request number to review
- `--re-review`: follow-up review after fix commits; see Smart Re-Review
- `--standard-tier`: reduced 2-agent review (Guidance Compliance + Bug Scan — shallow only, #2a)

**Routing:**
- `--standard-tier` present → skip to **Standard-Tier Review**
- `--re-review` present (without `--standard-tier`) → skip to **Smart Re-Review**
- Neither flag → follow steps 1–9 below

## Auto-Continue Protocol

**After review completes clean (0 P0, 0 P1, 0 P2 — all findings with confidence ≥ 50 resolved), auto-merge if applicable and proceed immediately. Do NOT pause to ask "shall I merge?" or "review complete — proceed?"**

**Self-Healing:** When review finds issues, the fixer loop (Steps 6-6.5) handles all severity levels with confidence scoring, convergence detection, and escalation. Do NOT apply separate fixing logic — use the existing fixer loop. See Steps 6-6.5 for the full self-healing workflow.

**Only pause when:** P0 issue requires human architectural/security decision (data loss, security breach, irreversible) AND the fixer loop's escalation mechanism has been exhausted.


## Process (Full Review)

### Step 0 — Test Coverage Check (MANDATORY, always runs)

Before reviewing code, check whether source changes are accompanied by test changes:

```bash
# List source files changed in the PR (exclude test files, type defs, config)
gh pr diff <PR_NUMBER> --name-only | grep -E '\.(ts|tsx)$' | grep -v '\.test\.' | grep -v '\.d\.ts'
```

For each source file, check if its test file was also changed:
- `src/components/Foo.tsx` → check `src/components/Foo.test.tsx`
- `src/hooks/useBar.ts` → check `src/hooks/useBar.test.ts`

**If source changed but test did not**: flag as a P1 issue with `check_type: test-coverage-gap`. Include in the review output:
```
ISSUE:
  check_type: test-coverage-gap
  severity: P1
  location: <changed source file>
  description: Source file changed without corresponding test file update.
    <test file> was not modified. Tests may be stale.
  suggestion: Verify tests still pass and cover the changed behavior.
    Update tests if the source change affects behavior.
```

**Exceptions** (do NOT flag):
- The change is purely cosmetic (formatting, comments, import reordering)
- The changed file has no test file (new module, config file, type definition)
- The PR description explicitly states tests are not needed

### Step 0.1 — Integration Test Coverage

For source files that touch database operations, check for integration tests:

```bash
# Files touching DB operations (supabase rpc, from, insert, update)
gh pr diff <PR_NUMBER> --name-only | xargs grep -El 'supabase\.(rpc|from|insert|update)' 2>/dev/null
```

For each DB-touching file, check if its integration test file exists:
- `src/lib/deals.ts` → check `src/__tests__/integration/deals.integration.test.ts`
- `src/services/profiles.ts` → check `src/__tests__/integration/profiles.integration.test.ts`

**If DB surface changed but integration test missing:** flag as P1 `check_type: test-coverage-gap` with specific layer:
```
ISSUE:
  check_type: test-coverage-gap
  severity: P1
  layer: integration
  location: <changed DB file>
  description: DB surface changed without integration test.
    Unit tests with mocked Supabase do not verify RLS, triggers, or schema.
  suggestion: Add integration test using supabase start + real DB.
    See test-integration skill for patterns.
```

### Step 0.2 — E2E Test Coverage

For changes to critical-path pages or flows, check for e2e tests:

```bash
# Files in critical paths (auth, booking, payment, profile)
gh pr diff <PR_NUMBER> --name-only | grep -E 'src/(pages|app)/(auth|booking|payment|profile|deals)'
```

For each critical path change, check for e2e test files:
- Pages changed → check `e2e/critical-paths/*.smoke.spec.ts` or `*.e2e.spec.ts`

**If critical path changed but e2e test missing:** flag as P1 `check_type: test-coverage-gap` with layer:
```
ISSUE:
  check_type: test-coverage-gap
  severity: P1
  layer: e2e
  location: <changed page>
  description: Critical path changed without e2e coverage.
  suggestion: Add smoke test (@smoke tag) for happy path, or full e2e (@e2e tag) for multi-page flows.
    See test-e2e skill for patterns.
```

### Step 0.3 — UX Verification Coverage

For PRs with UI changes (`.tsx` files in `components/` or `pages/`), check for UX verification:

```bash
# UI files changed
gh pr diff <PR_NUMBER> --name-only | grep -E '\.tsx$' | grep -v '\.test\.'
```

**If UI changed:** invoke `ux-verification` skill to check component library compliance, common failure patterns, and accessibility.

Flag if UX verification returns violations without fixes:
```
ISSUE:
  check_type: ux-violation
  severity: P1
  location: <component file>
  description: UX verification found unresolved violations.
    <summary from ux-verification report>
  suggestion: Fix violations or document why they're acceptable.
```

### Step 0.5 — Test Review (MANDATORY, always runs when tests changed)

For each changed test file, invoke `test-review` for an independent review-fix loop. This replaces the shallow checklist with a proper research+review+fix+re-review cycle.

```bash
# List test files changed in the PR
gh pr diff <PR_NUMBER> --name-only | grep -E '\.test\.(ts|tsx)$'
```

For each changed test file:
```
test-review <test-file> --surface-map "<extract from plan doc>" [--journey-map "<extract from plan doc>"]
```

`test-review` handles the full cycle:
- **Phase 0 — Research Intake:** Researches testing patterns for the surfaces under test
- **Phase 1 — Review:** 3 parallel fresh sub-agents (correctness, coverage+surface, journey-alignment)
- **Phase 2-4 — Fix + Re-review Loop:** Surgical fixes, fresh re-review, up to 3 cycles
- **Exit:** Clean (all reviewers return NO ISSUES FOUND) or capped with documented remaining issues

**If `test-review` returns capped:** flag the remaining issues as P1 with `check_type: test-quality-gap`. Include them in the review output.

**If no tests changed but source changed:** defer to Step 0 (test-coverage-gap already flagged).

**pgTAP-specific:** For SQL test files (`supabase/tests/`), `test-review` includes pgTAP-specific checks (transaction isolation, RLS roles, concurrent access).


### Step 0.6 — SQL Business Logic Function Check (MANDATORY, always runs)

When reviewing a PR that adds or modifies a Postgres function implementing business logic (transactions, reward claims, referral processing, RLS-guarded lookups): verify the plan or PR includes a SQL-level test — `npm run test:db` (pgTAP) or `execute_sql` verification via Supabase MCP. Mocked TypeScript tests cannot verify SQL logic.

Flag absence of SQL-level testing as a blocking P0 issue with `check_type: sql-test-gap`. Include in the review output:

```
ISSUE:
  check_type: sql-test-gap
  severity: P0
  location: <SQL function file>
  description: Postgres business logic function added/modified without SQL-level test.
    Mocked TypeScript tests cannot verify SQL logic (transaction isolation, RLS guards,
    RETURN QUERY side effects, auth.uid() behavior). A pgTAP test or execute_sql
    verification is required for any business logic function.
  suggestion: Add a SQL-level test — either a pgTAP test in supabase/tests/
    (run via npm run test:db) or an execute_sql verification block in the PR description
    demonstrating correct behavior for each code path.
```

**Past incidents:** referral transaction missing referred-user reward row, `RETURN QUERY` not setting `FOUND`, missing `auth.uid()` guard in `get_referidos_links`.

**Exceptions** (do NOT flag):
- The function is purely DDL/schema (CREATE TABLE, ALTER TABLE, INDEX operations)
- The function is a migration helper that runs once and is not callable at runtime
- The PR description explicitly states SQL tests will follow in a separate tracked PR

**Trigger pattern:** Identify business logic functions by scanning the PR diff for `CREATE OR REPLACE FUNCTION` blocks containing `INSERT`, `UPDATE`, `DELETE`, or `SELECT ... auth.uid()`, or function names matching `claim_*`, `redeem_*`, `process_*`, `transfer_*`, `refer_*`, `reward_*`.


### Step 0.7 — Content Generation Check (MANDATORY, always runs)

When reviewing a PR that generates or sends content (messages, emails, notifications, templates, push notifications, SMS): verify the execution path reaches the real generation/send function — not a hardcoded fallback, early return, or placeholder string. A function that silently skips real generation and returns a hardcoded string is a bug, not a test gap.

Flag skipped-generation paths as a blocking P0 issue with `check_type: content-generation-gap`. Include in the review output:

```
ISSUE:
  check_type: content-generation-gap
  severity: P0
  location: <file path>:<line>
  description: Content generation/send function has a code path that silently
    skips real generation and returns a hardcoded fallback, early return, or
    placeholder string. The execution path never reaches the actual send API.
  suggestion: Trace the execution path from the call site through the
    generation/send function. Verify every branch reaches the real send API
    in production mode. Remove any debug-only early returns that bypass
    actual delivery.
```

**Trigger pattern:** Scan the PR diff for functions that send or generate content — look for calls to email APIs (Resend, SendGrid, SES), push notification APIs (OneSignal, Firebase), SMS APIs (Twilio), in-app notification generators, or template renderers. Verify each function's return path reaches the real API call.

**Exceptions** (do NOT flag):
- Debug/dev-only code paths gated by `if (process.env.NODE_ENV === 'development')` that clearly log instead of sending
- Test files where mock generation is expected
- Functions whose purpose is to return preview/placeholder content (e.g., email template preview endpoints)


### Step 0.8 — Infrastructure File Detection (MANDATORY, always runs)

Skill files, ontology files, templates, and extension code are critical agent pipeline infrastructure. A broken skill breaks the entire agent. These files must NEVER be skipped as "trivial" or "non-code."

**Detection:**
```bash
INFRA_FILES=$(gh pr diff <PR_NUMBER> --name-only | grep -E 'skills/.*SKILL\.md|skills/.*workflow/.*\.md|templates/.*|extensions/.*\.ts|scripts/.*\.(cjs|mjs|js|sh|py)|\.mcp\.json')
```

> **Ontology note:** the canonical ontology now lives in the tortoise repo (`tortoise/docs/ONTOLOGY.md`, v3.1) and org data lives in swarm's Supabase SOR — neither is in this repo's PR diff. Ontology changes are reviewed via tortoise-repo PRs; agent-infra skill PRs get ontology review when they touch `skills/.*SKILL\.md` (vocabulary drift in skill text).

**If no infrastructure files detected:** `INFRA_RISK=""` — skip infrastructure reviewers.

**If infrastructure files detected:** Classify risk tier based on what changed:

| Risk | Examples | Reviewers |
|------|----------|-----------|
| **Infrastructure-low** | Typo fix in SKILL.md description, comment update, minor wording change | 1 reviewer (Skill Infrastructure) |
| **Infrastructure-medium** | New Bounded skill, workflow file change, ontology-touching skill change, .mcp.json change | 2 reviewers (Skill Infrastructure + Ontology & Templates) |
| **Infrastructure-high** | New Workflow skill, ONTOLOGY.md § change (tortoise repo), extension code, _template.md change | 3 reviewers (all) |

**Classification heuristic:**
- PR diff adds a new file matching `skills/**/SKILL.md` → read the skill to determine if Workflow (high) or Bounded/Modular (medium)
- PR diff modifies ontology-touching lines in `skills/**/SKILL.md` (entity/term drift) → high
- PR diff modifies extension code (`extensions/`) → high
- PR diff modifies `templates/` → high
- PR diff modifies `.mcp.json` → medium
- Other infra file changes → read the diff to classify; default to medium if uncertain

Store `INFRA_RISK=low|medium|high` for use in Step 4 dispatch.


### Step 0.9 — Cross-PR Overlap Detection (advisory notice, not a severity-gated finding)

Detect open PRs touching the same files as the current PR to surface merge-risk early.
This is an advisory notice — NOT a severity-gated finding. The P2-blocking merge gate
applies to CODE findings; overlap is a coordination signal and never blocks, gates, or
pauses the workflow (conflicts are resolved at merge time).

```bash
# Get changed files in this PR
gh pr diff <PR_NUMBER> --name-only > /tmp/pr_files_$$.txt

# Get all open PRs (excluding this one) with their file lists
gh pr list --state open --json number,title,files \
  --jq '.[] | select(.number != <PR_NUMBER>) | "\(.number)|\(.title)|" + (.files[].path)' \
  > /tmp/all_pr_files_$$.txt

# Extract unique files touched by other PRs
cut -d'|' -f3- /tmp/all_pr_files_$$.txt | sort -u > /tmp/other_pr_files_$$.txt

# Find overlap between this PR's files and other open PRs' files
comm -12 /tmp/pr_files_$$.txt /tmp/other_pr_files_$$.txt > /tmp/overlap_files_$$.txt

# For each overlapping file, find which PR(s) touch it
if [ -s /tmp/overlap_files_$$.txt ]; then
  while read -r file; do
    grep -F "|${file}" /tmp/all_pr_files_$$.txt | cut -d'|' -f1,2 | sort -u
  done < /tmp/overlap_files_$$.txt | sort -u > /tmp/overlap_prs_$$.txt
fi
```

**If overlap found:** flag as advisory P2 with `check_type: cross-pr-overlap`. Include in review output:

```
ISSUE:
  check_type: cross-pr-overlap
  severity: P2
  advisory: true
  description: File(s) also modified in N other open PR(s).
    Overlapping files: <comma-separated list>
    Open PRs touching same files: <PR #N (title), ...>
  suggestion: Review overlap for potential merge conflicts.
    Coordinate with PR authors if changes touch the same logic.
```

**This step never blocks.** The review proceeds regardless of overlap count.
Do not pause, gate, or escalate on cross-pr-overlap findings. (The `advisory: true` flag
on the ISSUE template keeps overlap findings outside the P0/P1/P2 severity-gated merge policy.)
The overlap signal feeds commit-workflow merge condition 5 (`04-merge-deploy.md`): when overlap
is detected, the merge step refreshes the branch against main and re-runs the affected regression
tests before merging — the safety net for cross-PR breakage without blocking on the signal itself.


### Step 1 — Eligibility Check

Dispatch a sub-agent via Pi `task` to check if the PR (a) is closed, (b) does not need review (automated, trivial, obvious), or (c) already has a code review. If ineligible, stop. **Draft PRs are eligible.** **Infrastructure files (skill files, ontology, templates, extensions, .mcp.json) are NEVER considered trivial — these are critical pipeline infrastructure that must always be reviewed.** If infrastructure files were detected in Step 0.8, the PR is always eligible regardless of triviality.

### Step 2 — CLAUDE.md File List

Dispatch a sub-agent to list relevant CLAUDE.md file paths: root CLAUDE.md and any in directories the PR modified. Return paths only, not contents.

### Step 3 — PR Summary

Dispatch a sub-agent to read the PR diff via `gh pr view <N> --json body,title,commits` and `gh pr diff <N>`. Return a summary of the change.

### Step 3.5 — Research Brief Resolution

Resolve a research brief if one exists for the linked issue:

```bash
ISSUE_NUMBER=$(gh pr view <PR_NUMBER> --json closingIssuesReferences --jq '.closingIssuesReferences[0].number')
if [ -n "$ISSUE_NUMBER" ]; then
  ISSUE_BODY=$(gh issue view "$ISSUE_NUMBER" --json body --jq '.body')
  RESEARCH_PATH=$(bash scripts/_research_path.sh --issue-body "$ISSUE_BODY" --epic-path "")
  if [ -n "$RESEARCH_PATH" ] && [ -f "$RESEARCH_PATH" ]; then
    RESEARCH_KIND=natural
    RESEARCH_CONTENT=$(cat "$RESEARCH_PATH")
  fi
fi
```

If `RESEARCH_KIND=natural`, inject before every reviewer sub-agent prompt:

```
## Verified Research Context (author-provided)

Treat this as authoritative; weigh findings against it. Downgrade reviewer recommendations that contradict it.

{RESEARCH_CONTENT}

---
```

### Step 3.6 — Complexity Rating Extraction + File Surface Detection

Extract complexity ratings from the linked issue and detect file surfaces from the PR diff to drive domain-aware reviewer dispatch in Step 4.

**1. Extract complexity ratings:**

```bash
ISSUE_NUMBER=$(gh pr view <PR_NUMBER> --json closingIssuesReferences --jq '.closingIssuesReferences[0].number')
if [ -n "$ISSUE_NUMBER" ]; then
  ISSUE_BODY=$(gh issue view "$ISSUE_NUMBER" --json body --jq '.body')
  UX_RATING=$(echo "$ISSUE_BODY" | grep -oP '(?<=UX_RATING: )\w+' || echo "")
  ARCH_RATING=$(echo "$ISSUE_BODY" | grep -oP '(?<=ARCH_RATING: )\w+' || echo "")
  ONTOLOGY_RATING=$(echo "$ISSUE_BODY" | grep -oP '(?<=ONTOLOGY_RATING: )\w+' || echo "")
fi
```

Ratings are OPTIONAL — they scale review DEPTH, not trigger. The PRIMARY trigger is the
PR diff surface (step 2): a surface match ALONE dispatches the domain reviewer at default
(medium) depth. If ratings not found in issue body, check the plan doc or scoping comment.

**2. Detect file surfaces from PR diff (surface = PRIMARY trigger, generalized beyond TS):**

```bash
FILES_CHANGED=$(gh pr diff <PR_NUMBER> --name-only)

# UI surface (UX review) — TS/JS/React AND Python/web/markup
UI_TOUCHED=$(echo "$FILES_CHANGED" | grep -qE '\.(tsx|jsx|vue|svelte|html|htm|css|scss|less)$|(components/|pages/|screens/|templates/)' && echo "true" || echo "false")

# Architecture surface — services/lib/api AND framework dirs (Python: tortoise/, src/, app/)
ARCH_TOUCHED=$(echo "$FILES_CHANGED" | grep -qE '(services/|lib/|api/|src/|app/|tortoise/|core/)' && echo "true" || echo "false")

# Data/Ontology surface — migrations, schema, types, data-model, projection
DATA_TOUCHED=$(echo "$FILES_CHANGED" | grep -qE '(supabase/migrations/|migrations/|schema|types/|models/|projection/|ontology)' && echo "true" || echo "false")

# Config surface — config files, manifests, env templates
CONFIG_TOUCHED=$(echo "$FILES_CHANGED" | grep -qE '\.(yaml|yml|toml)$|(\.mcp\.json|fly\.toml|docker-compose|\.env\.example|config\.)' && echo "true" || echo "false")
```

**3. Dispatch matrix (applied in Step 4) — surface triggers, rating scales depth:**

| Surface | Default (no rating) | `medium` rating | `high` rating |
|---------|--------------------|-----------------|---------------|
| `UI_TOUCHED` | ux-consistency + ux-coverage | same | + ux-realism |
| `ARCH_TOUCHED` | integration + architectural-soundness | same | + contract-completeness |
| `DATA_TOUCHED` | schema-correctness | same | + ontology-alignment |
| `CONFIG_TOUCHED` | config review (`config-validation`) | — | — |

Store all variables for Step 4 dispatch.

---

### Step 4 — Parallel Review (6-10 agents, surface-matched, ratings scale depth)

Launch **6 always-on agents** (Guidance, Bug-Shallow, Bug-Deep, History, PR Comments, Security) plus **up to 4 surface-matched domain agents** (UX, Architecture, Data, Config) in parallel via Pi `task`. Domain agents trigger on the PR diff surface (Step 3.6); complexity ratings, when present, scale depth inside each reviewer. Each receives the PR diff, CLAUDE.md paths, affected files, and research context (if any). Each returns `ISSUE:` blocks or `NO ISSUES FOUND`.

**Dispatch logic:**
```bash
# Always dispatch
# Always-on: 6 agents (Agent #2 split into shallow + deep — #2a and #2b; Security is #11)
AGENTS="Agent #1 (Guidance), Agent #2a (Bug Scan - Shallow), Agent #2b (Bug Scan - Deep), Agent #3 (History), Agent #4 (PR Comments), Agent #11 (Security)"

# Surface-first dispatch (domain reviewers fire on the DIFF — ratings scale depth inside the agents)
[ "$UI_TOUCHED" = "true" ] && AGENTS="$AGENTS, Agent #5 (UX — epic reviewers)"
[ "$ARCH_TOUCHED" = "true" ] && AGENTS="$AGENTS, Agent #6 (Architecture — epic reviewers)"
[ "$DATA_TOUCHED" = "true" ] && AGENTS="$AGENTS, Agent #7 (Data+Schema — epic reviewers)"
[ "$CONFIG_TOUCHED" = "true" ] && AGENTS="$AGENTS, Agent #12 (Config)"

if [ -z "$UX_RATING$ARCH_RATING$ONTOLOGY_RATING" ]; then
  echo "[code-review] No complexity ratings in issue — surface-matched domain reviewers still dispatch (default depth); ratings scale depth when present"
fi

# Infrastructure dispatch (runs alongside regular reviewers when INFRA_RISK is set from Step 0.8)
if [ -n "$INFRA_RISK" ]; then
  AGENTS="$AGENTS, Agent #8 (Skill Infrastructure)"
  [ "$INFRA_RISK" = "medium" ] || [ "$INFRA_RISK" = "high" ] && AGENTS="$AGENTS, Agent #9 (Ontology & Templates)"
  [ "$INFRA_RISK" = "high" ] && AGENTS="$AGENTS, Agent #10 (Extension Safety)"
  echo "[code-review] Infrastructure files detected (risk: $INFRA_RISK) — dispatching infrastructure reviewers"
fi
```

**Agent #1 — Guidance Compliance** (merged CLAUDE.md + code comments):
```
Audit the PR changes against:
1. CLAUDE.md guidance — all relevant CLAUDE.md files. Note: CLAUDE.md is guidance for writing code, so not all instructions apply during review.
2. Code comments — IMPORTANT/MUST/keep-in-sync/JSDoc contracts in modified files. Flag violations of binding comments.

For each issue found, return:
ISSUE:
  check_type: CLAUDE.md-adherence|comment-compliance
  severity: P0|P1|P2
  location: <file path>:<line>
  description: <what's wrong>
  suggestion: <what to fix>
```

**Agent #2a — Bug Scan (Shallow Diff)**:
```
Shallow scan of the PR diff for obvious bugs. Focus on the changes themselves — avoid reading extra context.
Look for: null pointer dereferences, wrong variable, inverted condition, missing async/await, incorrect API usage.
Ignore likely false positives, pre-existing issues, linter/compiler-detectable issues.

For each issue found, return:
ISSUE:
  check_type: bug
  severity: P0|P1|P2
  location: <file path>:<line>
  description: <what's wrong>
  suggestion: <what to fix>
```

**Agent #2b — Bug Scan (Deep — Caller/Callee)**:
```
Deep bug scan — read full changed files plus their import graph. Trace callers and callees. Check for broken contracts, cascading side effects, missing error propagation.

1. Read each changed file in full (not just the diff).
2. Trace imports to identify callers and callees across the codebase:
   grep -r "from '.*<module-path>'" --include='*.ts' --include='*.tsx'
   grep -r "<symbol>(" --include='*.ts' --include='*.tsx'
3. Map the call graph around each change. Check for:
   - Broken interface contracts: function signature changes that callers don't handle (changed return type, added/removed parameter, different error shape)
   - Cascading side effects: mutations, events, or DB writes that downstream code assumes won't change
   - Missing error propagation across the call chain
   - Type narrowing that breaks downstream consumers
   - API shape changes (return type, thrown errors) that callers don't handle
   - Removed exports that other modules import
   - Default export ↔ named export changes
4. Ignore likely false positives, pre-existing issues, linter/compiler-detectable issues.

For each issue found, return:
ISSUE:
  check_type: bug
  severity: P0|P1|P2
  location: <file path>:<line>
  description: <what's wrong, prefix with [deep]>
  suggestion: <what to fix>
```

**Agent #3 — Git History/Blame**:
```
Read git blame and history of the code modified. Identify bugs visible only in historical context:
- Regressions after a previous fix
- Removed safety checks or guards
- Repeated bugfix attempts that indicate a deeper issue
- Patterns of breakage on these files/lines

For each issue found, return:
ISSUE:
  check_type: historical-context
  severity: P0|P1|P2
  location: <file path>:<line>
  description: <what's wrong>
  suggestion: <what to fix>
```

**Agent #4 — Previous PR Comments**:
```
Find prior PRs that touched the same files. For each prior PR, read its comments.
Flag cases where the current PR repeats an issue flagged in a past review on the same files.
Steps:
1. For each affected file: gh api '/repos/{owner}/{repo}/commits?path={file}&per_page=20'
2. Extract PR numbers from commit messages (#NNN)
3. For each prior PR: gh pr view <N> --json reviews,comments
4. Return matches

For each issue found, return:
ISSUE:
  check_type: pr-comment-history
  severity: P0|P1|P2
  location: <file path>:<line>
  description: <repeated issue from PR #N>
  suggestion: <what to fix>
```

**Agent #11 — Security Review** (always-on):
```
You are the security reviewer for this PR. Apply the security-review skill discipline:
1. Read the security-review skill IN FULL first (resolve via $AGENT_INFRA_PATH/skills/security-review/SKILL.md or skills/security-review/SKILL.md relative to the agent-infra checkout).
2. RESEARCH before reporting: trace where the changed code's inputs come from, check for
   validation/sanitization elsewhere, check config/middleware, note framework protections.
3. Report ONLY HIGH-CONFIDENCE findings: a clear vulnerable pattern WITH attacker-controlled
   input. MEDIUM confidence → "Needs verification" note. LOW/theoretical → do not report.
4. Do NOT flag: test files, dead/commented code, documentation strings, server-controlled
   config values, code requiring prior auth (note the auth requirement instead), or
   pre-existing issues not touched by this PR.
5. Focus areas for this PR: the diff (git show main...HEAD or gh pr diff <N>).
```
For each issue return:
ISSUE:
  check_type: security
  severity: P0|P1|P2
  location: <file path>:<line>
  description: <vulnerability, why exploitable, attacker-controlled input path>
  suggestion: <fix>
If no high-confidence findings: NO ISSUES FOUND

**Agent #5 — UX Reviewer** (surface: `UI_TOUCHED` — ratings scale depth):

Dispatch to epic reviewers via Pi `task` sub-agents using the dispatch matrix from Step 3.6:
- rating absent (default) or `medium` → `ux-consistency` + `ux-coverage`
- `UX_RATING = high` → above + `ux-realism`

**Adaptation prefix** — inject before each reviewer's standard prompt:
```
You are reviewing a CODE PR DIFF, not an epic planning document. Apply your domain expertise to the code changes as if they were the implementation of a plan you validated.

PR DIFF:
<full diff>

---
```

For each dispatched reviewer, aggregate findings into standard `ISSUE:` blocks or `NO ISSUES FOUND`. Use `check_type` matching the reviewer: `ux-consistency`, `ux-coverage`, or `ux-realism`.

If UI_TOUCHED = false, skip (no UI surface to review).

**Agent #6 — Architecture Reviewer** (surface: `ARCH_TOUCHED` — ratings scale depth):

Dispatch to epic reviewers via Pi `task` sub-agents using the dispatch matrix from Step 3.6:
- rating absent (default) or `medium` → `integration` + `architectural-soundness`
- `ARCH_RATING = high` → above + `contract-completeness`

**Adaptation prefix** — inject before each reviewer's standard prompt:
```
You are reviewing a CODE PR DIFF, not an epic planning document. Apply your domain expertise to the code changes as if they were the implementation of a plan you validated.

PR DIFF:
<full diff>

---
```

For each dispatched reviewer, aggregate findings into standard `ISSUE:` blocks or `NO ISSUES FOUND`. Use `check_type` matching the reviewer: `integration`, `architectural-soundness`, or `contract-completeness`.

If ARCH_TOUCHED = false, skip (no architecture surface to review).

**Agent #7 — Data + Schema Reviewer** (surface: `DATA_TOUCHED` — ratings scale depth):

Dispatch to epic reviewers via Pi `task` sub-agents using the dispatch matrix from Step 3.6:
- rating absent (default) or `medium` → `schema-correctness`
- `ONTOLOGY_RATING = high` → above + `ontology-alignment`

**Adaptation prefix** — inject before each reviewer's standard prompt:
```
You are reviewing a CODE PR DIFF, not an epic planning document. Apply your domain expertise to the code changes as if they were the implementation of a plan you validated.

PR DIFF:
<full diff>

---
```

For each dispatched reviewer, aggregate findings into standard `ISSUE:` blocks or `NO ISSUES FOUND`. Use `check_type` matching the reviewer: `schema-correctness` or `ontology-alignment`.

If DATA_TOUCHED = false, skip (no data/ontology surface to review).

**Agent #12 — Config Reviewer** (surface: `CONFIG_TOUCHED`):
```
You are the config reviewer for this PR. Apply the config-validation skill discipline
(read skills/config-validation/SKILL.md if available):
1. Config changes are validated by the mapped check script for their file type
   (migrations → check-migration-*, skills → check-skill-lint, etc.).
2. Verify: env var names match what the code actually reads; no secrets in configs
   (placeholders only); default values are safe (fail-closed, not fail-open);
   config is internally consistent (e.g. .env.example vs .mcp.json vs defaults).
3. Report only concrete, actionable issues.
```
For each issue return:
ISSUE:
  check_type: config-validity|config-consistency|secret-leak|insecure-default
  severity: P0|P1|P2
  location: <file path>:<line>
  description: <what's wrong>
  suggestion: <what to fix>
If no issues: NO ISSUES FOUND


**Agent #8 — Skill Infrastructure Reviewer** (conditional: INFRA_RISK is set — dispatched for ALL infra risk levels):
```
You are reviewing a PR that changes skill infrastructure files. These files control agent behavior — errors here break the entire pipeline.

PR DIFF: <full diff>
INFRA_FILES: <list of infrastructure files from Step 0.8>

CHECK:

1. GATE WARNING (mandatory — every SKILL.md):
   - Does the SKILL.md have a gate warning block?
   - Acceptable patterns: "MUST be read in full", "mandatory before", "do not skip", "hard gate"
   - Missing gate warning in a skill that has quality gates → P0

2. CONTINUITY DIRECTIVE (mandatory — every SKILL.md):
   - Per skill type taxonomy (#5900):
     - Workflow skills → "as mandated by this skill" (or equivalent)
     - Bounded skills → "as mandated by the orchestrator skill" (or equivalent)
     - Modular skills → no continuity directive needed
   - Wrong or missing continuity directive → P1

3. FRONTMATTER VALIDITY (mandatory):
   - Required fields: `name`, `description`, `allowed-tools`, `version`
   - Missing required field → P0
   - Malformed YAML frontmatter → P0

4. BROKEN REFERENCES:
   - Does the skill reference other skills that don't exist?
   - Does it reference deprecated/archived paths?
   - Does it reference files that don't exist?
   - Broken reference → P1

5. SKILL TYPE CHECKS (domain-aware):
   - **Workflow skills:** Sequence correctness — do phases execute in the right order? Are handover contracts clear between phases? Are gate placements correct (before dangerous operations)?
   - **Bounded skills:** Is the orchestrator dependency clear? Are input/output contracts defined? Does it integrate correctly with the parent workflow's review gates?
   - **Modular skills:** Is it independently invocable? Are there no broken cross-skill assumptions? Is the interface self-contained and reusable?

For each issue found, return:
ISSUE:
  check_type: gate-warning|continuity-directive|frontmatter|broken-reference|sequence-correctness|handover-contract|gate-placement|orchestrator-dependency|io-contract|review-gate-integration|standalone-invocability|cross-skill-assumption
  severity: P0|P1|P2
  location: <file path>:<line>
  description: <what's wrong>
  suggestion: <what to fix>

If no issues: NO ISSUES FOUND
```

**Agent #9 — Ontology & Template Reviewer** (conditional: INFRA_RISK ∈ {medium, high}):
```
You are reviewing a PR that changes skill infrastructure, templates, or extension code. These define the canonical vocabulary and agent pipeline for the project. The canonical ontology lives in the tortoise repo (`tortoise/docs/ONTOLOGY.md`, v3.1 — fetch: `gh api repos/daniel-ospina/tortoise/contents/docs/ONTOLOGY.md --jq .content | base64 -d`, §5 = controlled vocabulary) and org data (teams/roles) lives in swarm's Supabase SOR. Neither is in this PR's diff — compare skill text against the fetched ontology.

PR DIFF: <full diff>
INFRA_FILES: <list of infrastructure files from Step 0.8>

CHECK:

1. VOCABULARY CONSISTENCY:
   - Does the change introduce terms that conflict with tortoise/docs/ONTOLOGY.md definitions?
   - Does the change use canonical entity names from the ontology's §5 controlled vocabulary?
   - New term without ontology registration → P1

2. ONTOLOGY DRIFT:
   - Does the change alter the meaning of an existing concept without updating downstream references?
   - Changed entity class but old name used elsewhere → P0
   - Semantic shift without changelog → P1

3. DOWNSTREAM IMPACT:
   - What other files reference the changed term/concept?
   - Are those references now stale?
   - Stale downstream reference → P1

4. TEMPLATE VALIDITY (for templates/ changes):
   - Are all required frontmatter fields still present?
   - Does the template match the filing workflow spec?
   - Missing required field → P0

5. ORG-DATA CONSISTENCY (team/role slugs in skill text):
   - Team/role slugs should match swarm's Supabase SOR (teams/roles tables) — verify via `node scripts/swarm-org.mjs list-teams` / `resolve-role <slug>`
   - Invalid slug → P1

For each issue found, return:
ISSUE:
  check_type: vocabulary-conflict|ontology-drift|downstream-impact|template-validity|subject-registry
  severity: P0|P1|P2
  location: <file path>:<line>
  description: <what's wrong>
  suggestion: <what to fix>

If no issues: NO ISSUES FOUND
```

**Agent #10 — Extension Safety Reviewer** (conditional: INFRA_RISK = high):
```
You are reviewing a PR that changes Pi extensions or MCP server configuration. These run in the agent's process — failures are silent and break agent capabilities.

PR DIFF: <full diff>
INFRA_FILES: <list of infrastructure files from Step 0.8>

CHECK:

1. RUNTIME SAFETY:
   - Does the extension handle errors gracefully or fail silently?
   - Are there uncaught exceptions?
   - Silent failure path → P0

2. ERROR HANDLING:
   - Does every operation have a catch/error boundary?
   - Are errors logged or surfaced to the user?
   - Missing error handler → P1

3. NO SILENT FAILURES:
   - If the extension can't load, does the agent know?
   - If an MCP server is unreachable, is it reported?
   - Silent degradation → P0

4. CONFIGURATION VALIDITY:
   - .mcp.json: valid JSON? All required fields (name, command, args)?
   - Extensions: correct manifest structure? Required exports present?
   - Invalid config → P0

For each issue found, return:
ISSUE:
  check_type: runtime-safety|error-handling|silent-failure|config-validity
  severity: P0|P1|P2
  location: <file path>:<line>
  description: <what's wrong>
  suggestion: <what to fix>

If no issues: NO ISSUES FOUND
```


### Step 4.5 — Merge-Dedup Bug Scan Results

Agent #2a (shallow) and Agent #2b (deep) may find overlapping or complementary bugs. After all agents return, merge their results:

1. **Dedup by location:** If both #2a and #2b flag the same `location` (file:line), keep only the more severe issue (prefer P0 > P1 > P2). If severity matches, prefer the deeper analysis (#2b).

2. **Complement check:** For each #2b issue that targets a caller/callee outside the diff, cross-reference with #2a results. If #2a flagged the same root cause at the source location, merge into a single issue with both locations cited.

3. **Output:** Produce a deduplicated, merged list of `check_type: bug` issues for confidence scoring in Step 5. Document merge decisions:
   ```
   MERGE: #2a location X + #2b location Y → merged (same root cause, source at X, side effect at Y)
   SKIP: #2a location Z (superseded by #2b deeper finding at same location)
   KEEP: #2b location W (unique deep finding, no shallow overlap)
   ```

Return the merged bug issues alongside Agent #1/#3/#4/#5/#6/#7 issues unchanged.

### Step 5 — Confidence Scoring

For each issue found in Step 4, dispatch an **isolated** Pi `task` sub-agent to score confidence. Each sub-agent gets:
- The PR number, issue description + location, CLAUDE.md file paths, and this rubric:

```
Score on a scale from 0–100:
a. 0: Not confident. False positive or pre-existing issue.
b. 25: Somewhat confident. Might be real but couldn't verify.
c. 50: Moderately confident. Real issue but may be a nitpick.
d. 75: Highly confident. Very likely a real issue that will be hit in practice. Important.
e. 100: Absolutely certain. Definitely a real issue, frequent in practice.

Return ONLY the number.
```

**Dispatch strategy:** Parallel for ≤15 issues, serial with 100ms stagger for >15. Extract score with regex `\b([0-9]{1,3})\b`, clamp to 0-100, default to 0 on parse failure.

### Step 6 — Filter & Fix

Filter out issues with score < 50. If none survive → go to Step 9 (Logging), then stop.

**Fixer configuration** — read `operations/ai-workflow-tools/config.json` (defaults if missing):
- `fixer_enabled`: default `true`
- `max_fix_cycles`: **REMOVED** — no cycle cap (convergence-gated instead)
- `stall_threshold`: default `0.8`

If `fixer_enabled == false` OR `--re-review` is active → skip fixer loop, go to Step 7.

### Gate Loop — MANDATORY (Fixer + Re-Review)

Each fix cycle dispatches a FRESH fixer sub-agent, and each re-review dispatches
FRESH reviewer sub-agents. Neither has memory of prior cycles — this prevents
confirmation bias.

**Simplified Fixer Loop:**

Serialize surviving issues to JSON: `[{"severity":"P1","location":"...","description":"...","suggestion":"..."}]`

For each cycle:

1. **Dispatch fixer sub-agent** via Pi `task` (fresh `pi -p` session):
   ```
   Fix these code-review issues in the current branch. Do NOT create a worktree.
   
   Issues to fix:
   <surviving issues JSON>
   
   Affected files: <list from PR diff>
   PR branch: <branch name>
   
   1. RESEARCH FIRST: For each issue involving external APIs, library behavior, or unfamiliar patterns → run web_search to verify the correct approach before fixing. Skip only for purely internal issues. No query cap — mistakes cost more than queries.
   2. Checkout the PR branch if not already on it
   3. For each issue, make the minimal fix (using research findings)
   4. Commit with message: fix(code-review): automated fixer cycle N — PR #<N>
   5. Push
   
   Return FILES_WRITTEN: <comma-separated> and STATUS: done|failed.
   ```

2. **Re-review**: Run `--re-review` on the new commits. This dispatches FRESH reviewer
   sub-agents via `task` — they see only the current code, not what was "just fixed."

3. **Stuckness detection (3-layer algorithm)**:

   a. **Fingerprint-stall**: Hash each surviving issue's location+description+suggestion (SHA256). If ≥`stall_threshold` of fingerprints match the previous cycle → escalate to human with stuck issues and attempted fixes. Do NOT auto-exit.

   b. **Honest-stuck**: Track `issues_per_cycle` (the number of issues surviving after each re-review). If issue count is **non-decreasing for 3 consecutive cycles** AND the fingerprints differ from prior cycles (genuinely new issues each time), the fixer is introducing new issues faster than it resolves existing ones. Exit reason = `honest-stuck`. Escalate to human — this indicates a systemic problem.

   c. **Zero-progress**: Track `files_changed_per_cycle`. If files changed = 0 for 2 consecutive cycles, the fixer is making zero code progress — treat as fingerprint-stall and escalate.

**Exit conditions — ALL must be true before proceeding to Step 8:**

- [ ] Last `--re-review` returned zero issues with confidence ≥ 50
- [ ] If cycle 1 found any issues → at least 1 re-review cycle completed
- [ ] Cycle log posted: each cycle's issues, fixes, and re-review results documented

**No hard cap.** The fix loop continues until clean exit or convergence. Safety cap at 10 cycles — if reached, escalate to human (prevents runaway loops from bugs, not a quality gate).

**Convergence rule:** If re-review issues are a strict subset of the previous cycle's issues (no new dimensions or files flagged), the fixer is in a refinement loop. Log convergence and escalate to human: present remaining issues with attempted fixes. Do NOT auto-exit — remaining issues must be acknowledged by a human before proceeding.

**Stall guard:** If the same issue survives 3 consecutive fix cycles, the automated fixer cannot resolve it. Log and escalate to human.

**Exit outcomes:**
- `STATUS=failed` → fixer couldn't push. Post with `⚠️ Auto-fix failed (push error) — N issues remain`.
- **Stall detected** → Escalate to human with stuck issues. Do NOT auto-exit.
- **Convergence reached** → Escalate to human with remaining issues (shrinking, no new). Do NOT auto-exit.
- **Clean** → no issues after re-review. Proceed to Step 8 with "No issues found."

**Cycle-status YAML**: Write `operations/logs/cycle-status.yaml` on loop exit:

```yaml
exit_reason: <clean|fingerprint-stall|honest-stuck|cycle-cap|convergence|stall-guard>
cycles: <N>
issues_per_cycle: <json array>
files_changed_per_cycle: <json array>
skill: code-review
```

This file enables cross-session staleness detection and loop enforcer integration.

**Critical: remaining issues are NEVER dropped.** They are always included in the PR comment body alongside the warning prefix. The fixer loop exits, but the issues persist in the review.

**FORBIDDEN — these bypass the quality gate entirely:**

- ❌ Run fixer → push → declare done without re-reviewing
  Fixing without re-reviewing = no review. Always run `--re-review` after fixes.

- ❌ Self-declare "the fix should address the issue" as completion
  Only a clean re-review (zero issues ≥ 50 confidence) is a valid exit signal.

- ❌ Re-review in the same conversation context
  Confirmation bias makes same-context re-review unreliable.
  Always use `--re-review` which dispatches fresh `task` sub-agents.

### Step 6.5 — Orchestrator Escalation (unattended recovery)

When the fixer loop exits with remaining issues (stall/cap/fail), the **orchestrator** (you, the main session) takes over BEFORE posting the PR comment:

1. **Read the remaining issues** — understand what the fixer couldn't solve
2. **Dispatch a deep-fix sub-agent** via Pi `task`:
   ```
   The automated fixer couldn't resolve these code-review issues after N cycles. You are the escalation path with FULL context and research capability.
   
   Remaining issues:
   <surviving issues JSON>
   
   PR branch: <branch>
   Affected files: <list>
   
   1. For EACH issue: research first — use web_search to understand the correct approach before touching code
   2. Checkout the PR branch
   3. Fix each issue with the correct, researched approach
   4. Commit with message: fix(code-review): deep escalation fix — PR #<N>
   5. Push
   6. Return FILES_WRITTEN and list which issues were resolved vs which remain unresolved with a brief explanation why
   ```
3. **If the deep-fix sub-agent resolves all issues** → re-review, then post "No issues found"
4. **If issues still remain** → THEN post the PR comment with the warning + remaining issues. These are the genuinely hard problems that need human judgment. Add a `### Requires Human Attention` section explaining what was tried and why each issue couldn't be auto-resolved.

**Pause only when:** a taxonomy-matching decision arises (human input taxonomy). Everything else proceeds unattended.

### Step 6.6 — Second-Model Final Gate (Two-Tier Review)

After the fixer loop converges clean (all Flash-based review cycles done), dispatch ONE second-model reviewer as a final quality gate. The second model is a stronger reasoner — it catches what the cheaper review agents miss.

**Model (second-model gate):** dispatch with `model` = `$SECOND_MODEL` (env; default `deepseek/deepseek-v4-pro` — provider-qualified, unambiguous; resolve via `~/.pi/agent/models.json`). When `$SECOND_MODEL` is set but unresolvable, or unset with the default unresolvable, dispatch the tool default (`deepseek-v4-flash`) and annotate the result `[SECOND-MODEL-GATE] stand-in ($SECOND_MODEL=… set-but-unresolvable | unset+default-unresolvable)`. Never silently substitute. Pricing decision (issue #284): `deepseek-v4-pro` (best bug-finding + cost per review pass); qwen3.8-max re-enable only after verbosity control (reasoning_effort/output caps); kimi-k3 opt-in only.

**Dispatch:**
```
task(model=<$SECOND_MODEL per the second-model gate convention>, prompt=<same Agent #1 guidance-compliance + Agent #2 bug-scan prompts, single reviewer>)
```

**Prompt:** Same review dimensions as Steps 4-5 agents — the second model just applies stronger reasoning. No prompt engineering needed.

**Second-model findings surfaced as `[SECOND-MODEL-GATE]` severity:**

| Second-model Issue | Action |
|---|---|
| `[SECOND-MODEL-GATE] P0` | Structural flaw missed by Flash — fix required, re-run the second-model gate once |
| `[SECOND-MODEL-GATE] P1` | Important gap — fix required, re-run the second-model gate once |
| `[SECOND-MODEL-GATE] P2` | Real improvement — fix required, re-run the second-model gate once (P2s block the merge gate) |

**Re-dispatch:** Max 2 second-model cycles. On 2nd failure → surface in PR comment as `[SECOND-MODEL-GATE]` with "second-model final gate could not converge."

**Gate passes:** second-model gate returns CLEAN (no P0/P1/P2 findings). Proceed to Step 7.

### Step 7 — Eligibility Re-check

Dispatch a sub-agent to re-check eligibility (same as Step 1).

### Step 8 — Post Comment

Use `gh pr comment` to post the review. **ALL surviving issues must be included** — even when the fixer loop exited with remaining issues.

**If fixer loop stalled or fixer failed (issues remain):**

```
⚠️ Auto-fix [stalled after N cycles | failed: <reason>] — M issues require human attention

### Code review

Found M issues:

1. <brief description> (<source>)
<link to file with full sha + line range>
...

🤖 Generated with [Pi](https://pi.dev)
<sub>- If this code review was useful, please react with 👍. Otherwise, react with 👎.</sub>
```

**If clean (no issues, or all fixed):**

```
### Code review

Found N issues:

1. <brief description> (<source>)

<link to file with full sha + line range>

2. ...

🤖 Generated with [Pi](https://pi.dev)

<sub>- If this code review was useful, please react with 👍. Otherwise, react with 👎.</sub>
```

Or if no issues:

```
### Code review

No issues found. Checked for bugs, guidance compliance, historical context, and prior PR comments.

🤖 Generated with [Pi](https://pi.dev)
```

**Link format:** `https://github.com/<owner>/<repo>/blob/<full sha>/<file>#L<start>-L<end>`. Require full SHA, provide 1 line of context before and after the issue.

### Step 9 — Logging (Supabase)

Best-effort logging — never block the workflow. For each issue ≥50 confidence:

```bash
JSON=$(python3 -c "
import json
from datetime import datetime, timezone
entry = {
  'ts': datetime.now(timezone.utc).isoformat(),
  'skill': 'code-review',
  'version': '2.0.0',
  'pr_number': <PR_NUMBER>,
  'pr_author': '<AUTHOR>',
  'file_path': '<FILE>',
  'check_type': '<TYPE>',
  'severity': '<SEVERITY>',
  'problem': '<≤200 char description>',
  'snippet': '<≤150 char code>',
  'confidence': <SCORE>
}
print(json.dumps(entry, ensure_ascii=False))
")
curl -s -o /dev/null -X POST \
  'https://axaeagulqhanatyoxrdv.supabase.co/rest/v1/code_review_errors' \
  -H 'apikey: <KEY>' \
  -H 'Authorization: Bearer <KEY>' \
  -H 'Content-Type: application/json' \
  -H 'Prefer: return=minimal' \
  -d "[$JSON]" \
  2>/dev/null \
|| (mkdir -p operations/logs && echo "$JSON" >> operations/logs/code-review-errors.jsonl)
true
```

**Check types:** `CLAUDE.md-adherence`, `comment-compliance`, `bug`, `historical-context`, `pr-comment-history`, `security`, `sql-test-gap`, `content-generation-gap`, `gate-warning`, `continuity-directive`, `frontmatter`, `broken-reference`, `sequence-correctness`, `handover-contract`, `gate-placement`, `orchestrator-dependency`, `io-contract`, `review-gate-integration`, `standalone-invocability`, `cross-skill-assumption`, `vocabulary-conflict`, `ontology-drift`, `downstream-impact`, `template-validity`, `subject-registry`, `runtime-safety`, `error-handling`, `silent-failure`, `config-validity`, `ux-consistency`, `ux-coverage`, `ux-realism`, `integration`, `architectural-soundness`, `contract-completeness`, `schema-correctness`, `ontology-alignment`, `e2e-coverage`, `e2e-reproducibility`, `config-consistency`, `secret-leak`, `insecure-default`
**Severity:** `high` (90-100), `medium` (70-89), `low` (50-69)

## Standard-Tier Review (`--standard-tier`)

Runs 2 agents. Used when full review is disproportionate.

**Step 1-3:** Same as full review (eligibility, CLAUDE.md paths, summary).

**Step 4:** Launch only 2 parallel agents — Guidance Compliance + Bug Scan (shallow only, Agent #2a). Skip Agent #2b (deep), Agent #3 (History), and Agent #4 (PR Comments).

**Step 5 onward:** Same as full review (scoring, filter, fixer, re-check, comment, logging). Append `(standard-tier review: guidance compliance + bug scan)` to comment header.

### Standard-Tier + Re-review

If `--re-review` with `--standard-tier`: identify fix commits (delta diff identification from Smart Re-Review Step A), scope agents to delta diff. If >4 files changed → fall back to full standard-tier. Append `(standard-tier re-review: fix-commits delta)`.

## Smart Re-Review (`--re-review`)

Targeted review on fix commits only. Skipped agents: Git History, PR Comments (static — won't have changed).

**Step A — Identify fix commits:** Sub-agent finds commits pushed after the most recent "### Code review" bot comment. Returns fix commit SHAs + distinct file count + combined delta diff.

**Step B — Scope check:** If >4 files changed → fall back to full review.

**Step C — CLAUDE.md paths:** Same as Step 2.

**Step D — Targeted review:** Launch 3 parallel agents on delta diff only:
- Guidance Compliance (delta diff)
- Bug Scan (delta diff)
- Guidance Compliance — code comments subset (delta diff, code comments only)

**Step E — Continue from Step 5:** Scoring, filter (skip fixer loop — `--re-review` disables it), re-check, comment, logging. Append `(re-review: fix-commits delta)` to comment header.

## False Positives to Ignore

- Pre-existing issues
- Something that looks like a bug but isn't
- Pedantic nitpicks a senior engineer wouldn't call out
- Issues a linter/typechecker/compiler would catch
- General code quality issues (test coverage, security, docs) unless explicitly required
- Issues silenced by lint ignore comments
- Changes likely intentional or directly related to the broader change
- Issues on lines the user did not modify

## Notes

- **Do NOT use Bash for reasoning or narration.** Only for commands that produce new information.
- **Prefer Read/Grep over Bash for file analysis.**
- Do not check build signal or attempt to build/typecheck.
- Use `gh` for GitHub interaction.
- Make a todo list first.
- Cite and link each bug with full SHA + line range.
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
