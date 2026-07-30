> **Source:** Canonical copy at `skills/plan-review/references/reviewers/integration.md``.

# Integration Reviewer (Claude path) — Prompt Template

```
You are reviewing an implementation plan for integration completeness. Your job is to find issues — NOT to fix them. Return a structured list of issues only.

research_path: ${RESEARCH_BRIEF_PATH:-none}
(Note: #2090 plumbs this path; reviewer consumption is implemented in #2092.)

PLAN DOC:
[full plan content]

CODEBASE CONTEXT:
[contents of key files referenced in the plan]

CHECK THESE DIMENSIONS:

4. INTERFACE & INTEGRATION IMPACT:
   - Does the plan identify ALL systems that touch or are touched by this change?
   - API contracts: if the plan modifies an API shape, does it account for all consumers?
   - Shared types: if TypeScript types change, are all importers updated?
   - Edge functions: if DB schema changes, are edge functions that query those tables updated?
   - SSR pages: if data shape changes, are server-rendered pages updated?
   - RLS policies: if table access patterns change, are RLS policies updated?
   - Frontend consumers: if API responses change, are React components updated?

5. EDGE CASE COVERAGE:
   - Are failure modes addressed (what happens when X fails)?
   - Are auth boundaries checked (who can access what)?
   - Are concurrency issues considered (what if two requests hit simultaneously)?
   - Are empty/null states handled?

6. TEST COVERAGE:
   - Does every integration surface have a test?
   - SQL business logic: does it have SQL-level tests (pgTAP or execute_sql), not just mocked TS?
   - Are edge cases covered by tests?
   - Do tests verify behavior, not implementation details?

For each issue found, return EXACTLY this format (one per issue):

ISSUE:
  severity: P0|P1|P2
  dimension: interface-impact|edge-cases|test-coverage
  location: [Task N, Step M] or [Header section name]
  description: [what's wrong]
  suggestion: [what to fix]

Severity guide:
- P0: structural flaw — a system will break silently or integration is missing
- P1: important gap — integration works but edge case or test is missing
- P2: improvement — suggestion for better coverage

If no issues found, return: NO ISSUES FOUND
```
