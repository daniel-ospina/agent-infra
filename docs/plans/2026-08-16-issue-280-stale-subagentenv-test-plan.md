---
title: "Plan: #280 — stale subAgentEnv dual-support test (ALLOW_MAIN_EDITS contract + run-from-root convention)"
type: engineering
domain: operations
doc_status: draft
subjects.team: organisation-design-team
created: 2026-08-16
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-280, builtin-tools, subagent-integration, main-worktree-guard
---

# Plan: #280 — stale subAgentEnv dual-support test

## Goal
Fix the failing-on-origin/main test `subAgentEnv no longer contains AGENT/ELDATO_ALLOW_MAIN_EDITS` (extensions/builtin-tools/subagent-integration.test.ts L54-64). The #7549 dual-support change re-added `ELDATO_ALLOW_MAIN_EDITS: "1"` + `AGENT_ALLOW_MAIN_EDITS: "1"` to subAgentEnv (extensions/builtin-tools/index.ts L2084-2085) via the #825 verified-file-registry bridge; the test still asserts their ABSENCE (stale #265 premise). Test-only change, surgical.

## Approach (1-3 sentences)
Update the single assertion block in `subagent-integration.test.ts`: rename the test to reflect the dual-support contract, assert **both** `ELDATO_ALLOW_MAIN_EDITS` and `AGENT_ALLOW_MAIN_EDITS` are present, keep `ELDATO_SKIP_VGATE` as an **absence** check but tighten it to the assignment form (`!/ELDATO_SKIP_VGATE\s*:/` — the comments legitimately mention the name), keep the SKILL_ENFORCER_DISABLED check, and add a run-from-repo-root note to the file header (both cwd-relative tests ENOENT with a doubled path when run from `extensions/builtin-tools/`).

## Edits (single file: extensions/builtin-tools/subagent-integration.test.ts)

1. **Header note:** document the invocation convention — the two cwd-relative tests (`extensions/builtin-tools/index.ts`, `extensions/main-worktree-guard/index.ts`) must run from the REPO ROOT; running from `extensions/builtin-tools/` produces a doubled-path ENOENT.
2. **Test rename:** `subAgentEnv no longer contains AGENT/ELDATO_ALLOW_MAIN_EDITS` → `subAgentEnv sets dual-support ALLOW_MAIN_EDITS (ELDATO + AGENT) with no ELDATO_SKIP_VGATE injection`.
3. **Assertions:**
   - `ok(block.includes("ELDATO_ALLOW_MAIN_EDITS"), ...)` — dual-support ELDATO variant present
   - `ok(block.includes("AGENT_ALLOW_MAIN_EDITS"), ...)` — dual-support AGENT variant present
   - `ok(!/ELDATO_SKIP_VGATE\s*:/.test(block), "no ELDATO_SKIP_VGATE assignment (VGATE stays ACTIVE for sub-agents, #825)")` — absence check on the ASSIGNMENT form
   - keep `ok(block.includes("SKILL_ENFORCER_DISABLED"), ...)` + `ok(block.includes("AGENT_SKIP_REVIEW_GATE"), ...)` (review dispatch stays parent-enforced, #825)

No source (non-test) changes. Test count stays 8.

## Verify
- `npx tsx extensions/builtin-tools/subagent-integration.test.ts` from the worktree ROOT → 8/8 pass
- `npx tsx extensions/builtin-tools/builtin-tools.test.ts` → regression: 159 pass

## References
- Issue #280 body (Context: found while verifying #279)
- extensions/builtin-tools/index.ts L2051-2104 (subAgentEnv contract, dual-support #7549, #825 VGATE)
- `scripts/check-pipeline-compliance.sh` — gate checks: (b) scoping comment marker on issue, (c) code-review evidence in PR body/commits, (d) plan doc (standard/complex), (e) test-coverage evidence
