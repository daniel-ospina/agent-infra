---
name: codebase-audit
description: "Full codebase audit coordinating security, bug, config, supply-chain, and database specialists. Use when asked to 'audit the codebase', 'find all bugs', 'security audit', 'full audit', 'code quality scan', or 'run codebase audit'."
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
steps:
  - name: file_discovery
    type: skill
    gate: auto
    produces: [file_list]
  - name: fan_out
    type: parallel
    gate: auto
    requires: [file_discovery]
    produces: [specialist_findings]
  - name: fan_in_synthesis
    type: skill
    gate: auto
    requires: [fan_out]
    produces: [synthesized_findings]
  - name: fix_loop
    type: skill
    gate: verifier
    requires: [fan_in_synthesis]
    produces: [fixes_applied]
  - name: report
    type: skill
    gate: auto
    requires: [fix_loop]
    produces: [audit_report]
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

**Verifier gate:** dispatches AI reviewers. Pipeline auto-advances when clean.

> **Source:** Canonical copy at `skills/codebase-audit/SKILL.md`.

# Codebase Audit

Orchestrate a multi-dimensional codebase audit using 5 specialist agents in parallel, then synthesize, deduplicate, fix critical issues, and produce a report.

## Scope Selection

Ask the user or detect from invocation:

1. **Targeted** — user provides specific file paths or directories
2. **Changed** — files changed in the last 30 days: `git log --since="30 days ago" --name-only --pretty=format: | sort -u | grep -v '^$'`
3. **Full** (default when user says "full audit") — all files in `src/`, `functions/`, `supabase/functions/`, `supabase/migrations/`

For any mode, build a file list and share it with all agents.

## Phase 1: File Discovery

```bash
# Full mode example
find src/ functions/ supabase/functions/ supabase/migrations/ \
  -name '*.ts' -o -name '*.tsx' -o -name '*.sql' \
  | grep -v node_modules | grep -v '.test.' | grep -v '.d.ts' \
  | sort
```

Group files by category for specialist routing:
- **App code**: `src/**/*.{ts,tsx}` (excluding tests)
- **SSR functions**: `functions/**/*.ts`
- **Edge functions**: `supabase/functions/**/*.ts`
- **Migrations**: `supabase/migrations/**/*.sql`
- **Config**: `tsconfig*.json`, `eslint.config.js`, `vite*.ts`, `package.json`

## Phase 2: Fan-Out (5 Parallel Agents)

**Concurrency control:** Max 8 parallel agents. Stagger launches by 200ms between agents to avoid API rate limits. Use `subagent({ tasks: [...] })` for true parallel dispatch. Each task in the array needs `{ agent: "worker", task: "<prompt>" }`. On rate-limit errors, retry with exponential backoff (1s, 2s, 4s) + jitter ±200ms. See `parallel-orchestrator` reference skill for full pattern.

Launch all 5 agents simultaneously using the subagent tool. Each agent receives:
- The file list for its domain
- Instructions referencing the specialist skill's methodology
- The standardized output format (below)

### Agent A: Security Review

```
You are the Security specialist for a codebase audit.

Follow the methodology from the security-review skill:
- Read `../security-review/SKILL.md` for the overall approach
- Read `../security-review/languages/javascript.md` for JS/TS patterns
- Read `../security-review/languages/typescript.md` for TS-specific patterns
- Read `../security-review/references/supabase-rls.md` for Supabase patterns
- Read `../security-review/references/cloudflare-pages.md` for SSR patterns
- Consult other reference files as needed based on what you find

Scope: [FILE LIST — app code, SSR functions, edge functions]

Report only HIGH confidence findings. Trace data flow before flagging.
Use the standardized finding format.
```

### Agent B: Bug Hunting

```
You are the Bug Hunting specialist for a codebase audit.

Follow the methodology from the find-bugs skill:
- Read `../find-bugs/SKILL.md`
- Use full-codebase mode (skip Phase 1 git diff, use provided file list)
- Apply Phases 2-5: attack surface mapping, security checklist, verification, coverage audit

Scope: [FILE LIST — all app code]

Focus on logic errors, crash vectors, race conditions, edge cases.
Use the standardized finding format.
```

### Agent C: Configuration Security

```
You are the Configuration Security specialist for a codebase audit.

Follow the methodology from the insecure-defaults skill:
- Read `../insecure-defaults/SKILL.md`
- Read `../insecure-defaults/references/examples.md`

Scope: [FILE LIST — config files, env handling, SSR functions, edge functions]

Focus on fail-open patterns, hardcoded secrets, weak defaults, debug features.
Use the standardized finding format.
```

### Agent D: Supply Chain

```
You are the Supply Chain specialist for a codebase audit.

Follow the methodology from the supply-chain-risk-auditor skill:
- Read `../supply-chain-risk-auditor/SKILL.md`
- Read package.json and package-lock.json for dependency list
- Use gh CLI to query GitHub metadata for each direct dependency

Scope: package.json dependencies (direct only)

Use the standardized finding format.
```

### Agent E: Database & Supabase

```
You are the Database specialist for a codebase audit.

Follow the methodology from the supabase-postgres-best-practices skill:
- Read `../supabase-postgres-best-practices/SKILL.md`
- Consult references/ files for specific rules as needed

Scope: [FILE LIST — migrations, edge functions, any file using supabase client]

Focus on: missing indexes, RLS issues, connection management, query performance.
Use the standardized finding format.
```

## Standardized Finding Format

ALL agents MUST return findings in this exact format:

```
[P0] Brief title
- File: path/to/file.ts:42
- Category: Security|Bug|Config|SupplyChain|Database
- Impact: 1-2 sentences describing the real-world consequence
- Fix: Specific suggested approach
- Effort: quick-win|medium|long-term
```

Severity levels:
- **P0 (Critical)** — Exploitable now, data loss risk, auth bypass. Fix immediately.
- **P1 (High)** — Significant risk or user-facing breakage. Fix this sprint.
- **P2 (Medium)** — Degrades reliability/maintainability. Fix when convenient.
- **P3 (Low)** — Style, minor debt. Backlog.

If an agent finds no issues, it returns: "No findings."

## Research Discipline

This skill follows the [research-protocol](../reference/research-protocol/SKILL.md). Tier 2 integration.

### Phase 2.5 — External Benchmarking (NEW)

After all agents return but before synthesis, run 2-3 targeted `perplexity_search` queries to benchmark findings against industry standards:
1. **Security benchmark:** "common security vulnerabilities in [our stack] production applications 2025 2026"
2. **Architecture benchmark:** "production architecture best practices [our stack] common mistakes"
3. **Dependency benchmark:** "known vulnerable dependencies [key packages] 2025 2026"

Flag any finding where our codebase deviates from industry standard without a documented reason.

## Phase 3: Fan-In (Synthesis)

**Wait for all agents to complete** (the subagent tool blocks until all tasks resolve). On subagent tool failure (network error, API down, timeout), retry 3× with exponential backoff (1s, 2s, 4s) + jitter ±200ms. If all retries fail, surface to human with options to (a) retry, (b) proceed with partial results, (c) abort. After all agents return successfully:

1. **Collect** all findings into a single list
2. **Deduplicate** — if two agents flag the same file+line, merge into one finding (keep the higher severity)
3. **Sort** by severity (P0 first, then P1, P2, P3)
4. **Estimate effort** if not already assigned
5. **Count** total findings by category and severity

## Phase 4: Fix Loop (P0/P1 Only)

For each P0 and P1 finding:

1. Apply the suggested fix
2. Verify the fix doesn't break tests: `npx vitest run --reporter=verbose 2>&1 | tail -5`
3. If tests fail, revert and try an alternative approach
4. Re-run the affected specialist agent on just the fixed file to verify the issue is resolved
5. Max 3 fix-verify cycles per finding. If unresolved after 3 cycles, mark as "needs manual review"

After all P0/P1 fixes are applied:
- Run full typecheck: `npx tsc --noEmit -p tsconfig.app.json`
- Run full test suite: `npx vitest run`

## Phase 5: Report

Generate a structured markdown report:

```markdown
# Codebase Audit Report — [DATE]

## Summary
- **Files analyzed:** N
- **Scope:** [targeted|changed|full]
- **Findings:** N total (X P0, Y P1, Z P2, W P3)
- **Fixed:** N (all P0/P1 resolved)
- **Remaining:** N (P2/P3, backlog)

## P0 — Critical (Fixed)
[findings with fix descriptions]

## P1 — High (Fixed)
[findings with fix descriptions]

## P2 — Medium (Backlog)
[findings]

## P3 — Low (Backlog)
[findings]

## By Category
| Category | P0 | P1 | P2 | P3 | Total |
|----------|----|----|----|----|-------|
| Security | .. | .. | .. | .. | ..    |
| Bug      | .. | .. | .. | .. | ..    |
| Config   | .. | .. | .. | .. | ..    |
| SupplyChain | .. | .. | .. | .. | .. |
| Database | .. | .. | .. | .. | ..    |
```

## After the Audit

If P0/P1 fixes were applied, use the `commit-workflow` skill to commit and land the changes.

Track P2/P3 findings as GitHub issues if warranted (ask the user).
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
