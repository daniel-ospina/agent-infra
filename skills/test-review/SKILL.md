---
name: test-review
description: Review-fix loop for tests. Dispatches 4 parallel reviewers (correctness, coverage+surface, journey-alignment, test-quality), merges issues, fixes with research, and loops until clean or convergence. Invoked by test-writing after test creation and by code-review at PR time.
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
version: 1.0.0
steps:
  - name: dispatch_reviewers
    type: parallel
    gate: verifier
    produces: [review_findings]
  - name: merge_and_dedup
    type: skill
    gate: auto
    requires: [dispatch_reviewers]
    produces: [merged_issues]
  - name: apply_fixes
    type: skill
    gate: auto
    requires: [merge_and_dedup]
    produces: [fixed_tests]
  - name: re_review
    type: parallel
    gate: verifier
    requires: [apply_fixes]
    produces: [final_review]
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

**Verifier gate:** dispatches AI reviewers. Pipeline auto-advances when clean.

# Test Review

Automated review-fix cycle for tests. Ensures tests are correct, complete, and aligned with integration surfaces and user journeys before merge.

## When to Use

- **Invoked by `test-writing`** after tests are written (in-execution review — catches issues before implementation code)
- **Invoked by `code-review` Step 0.5** (pre-merge review — catches issues with fresh eyes before merge)
- Can be invoked manually: `test-review <test-file> [--surface-map <path>] [--journey-map <path>]`

## Arguments

`test-review <test-file> --surface-map <surface-map-text> [--journey-map <journey-map-text>]`

At minimum, provide the test file content. Surface map and journey map are extracted from the plan doc if available.

## Review Cycle

```
Phase 1: Review (4 parallel agents — fresh task sub-agents)
    ↓
Phase 2: Merge & Dedup
    ↓
Phase 3: Fix (research-backed, surgical edits)
    ↓
Phase 4: Re-review (fresh sub-agents, no memory of prior cycle)
    ↓
Loop until NO ISSUES FOUND or convergence (fingerprint-stall; safety cap: 10 cycles)
```

### Phase 0 — Research Intake (Proactive Testing Knowledge)

**Purpose:** Before reviewing tests, gather domain knowledge about HOW to test the specific surfaces in play. Check the knowledge base first to avoid re-querying.

#### Phase 0a — Knowledge Base Lookup (check before querying)

Before firing any web searches, check two sources for existing testing knowledge:

**1. Markdown knowledge base (`docs/teams/organisation-design-team/domains (S1)/operations/testing-patterns.md`, eldato repo):**

> Run this phase from an eldato repo checkout, or fetch the file: `gh api repos/daniel-ospina/eldato/contents/docs/teams/organisation-design-team/domains%20(S1)/operations/testing-patterns.md --jq .content | base64 -d`.

```bash
# Does the file exist?
[ -f "docs/teams/organisation-design-team/domains (S1)/operations/testing-patterns.md" ] && echo "found" || echo "missing"
```

If found, read it. For each surface type in the Integration Surface Map, check if a pattern exists in the corresponding section. A pattern is "fresh" if its entry has a `Last researched:` date within the last 6 months.

```
For each surface type:
  ✓ Found in knowledge base + fresh (<6 months) → use it, skip web_search
  ⚠ Found but stale (≥6 months) → re-research with web_search
  ✗ Not found → research with web_search
```

**2. Tortoise/FalkorDB search (`agent-infra/testing-knowledge`):**

Search FalkorDB for existing testing knowledge about the surface type via Tortoise query.

If Tortoise returns matching knowledge not in the markdown knowledge base: use it, and also backfill it to `docs/teams/organisation-design-team/domains (S1)/operations/testing-patterns.md` (eldato repo).

#### Phase 0b — Web Search (only for missing/stale patterns)

For each surface type NOT covered by Phase 0a, fire 1-2 targeted `web_search` queries:

| Surface Type | Research Focus | Example Query |
|-------------|----------------|---------------|
| **Concurrent access** | Deterministic concurrency testing patterns | "how to test race conditions vitest Promise.all concurrent operations" |
| **RLS policies / Auth** | pgTAP patterns for multi-role RLS testing | "how to test Supabase RLS policies pgTAP different auth roles" |
| **External API calls** | Mock vs sandbox tradeoffs, contract testing | "how to test Stripe API vitest mock sandbox contract testing patterns" |
| **Time-based logic** | Clock injection, fake timers | "how to test time-dependent code vitest fake timers clock injection" |
| **Idempotency** | Duplicate delivery simulation | "how to test idempotent webhook handlers duplicate delivery simulation" |
| **SQL business logic** | pgTAP transactions, triggers, isolation | "pgTAP patterns testing postgres functions transactions triggers" |
| **State machines / Workflows** | Invalid transition testing | "how to test state machine transitions vitest invalid state" |
| **Error handling / Retry** | Retry + backoff testing patterns | "how to test retry logic exponential backoff vitest mock timers" |
| **Data integrity** | Multi-write atomicity testing | "how to test data integrity postgres transactions vitest atomic" |

#### Phase 0c — File Findings (aggregate knowledge)

After research completes, file findings to BOTH locations so future cycles skip the query:

**1. Append to `docs/teams/organisation-design-team/domains (S1)/operations/testing-patterns.md` (eldato repo):**

```markdown
### <Surface Type>
- **Pattern:** <concise description of the correct testing approach>
- **Gotcha:** <common pitfall or anti-pattern to avoid>
- **Example:** <minimal code example showing the pattern>
- **Source:** <research source URL or "test-review Phase 0">
- **Last researched:** <YYYY-MM-DD>
```

**2. File to Tortoise/FalkorDB:**

```
tortoise ingest --content "<pattern + gotcha + example>" --kind testing-knowledge
```

This creates a searchable memory that future Tortoise lookups (Phase 0a) will find.

#### Phase 0d — Output

Produce a `### Testing Knowledge` block with ALL findings (from knowledge base + Tortoise + fresh research). Inject as context for all 4 reviewers and the fixer:

```markdown
### Testing Knowledge (research intake)

**Surface: <type>**
- Pattern: <how to test this> (source: knowledge base | Tortoise | fresh research)
- Gotcha: <common pitfall>

**Surface: <type>**
- Pattern: <how to test this>
- Gotcha: <common pitfall>
```

**If no surface map:** skip Phase 0 entirely — no domain-specific testing knowledge needed.

### Phase 1 — Review (4 Parallel Agents)

Launch 4 reviewers **in parallel** via Pi `task`. Each receives the full test file(s), surface map (if available), and journey map (if available). Each returns `ISSUE:` blocks or `NO ISSUES FOUND`.

**Multi-file support:** TEST FILE may be a single file or a list. For multiple files, review all simultaneously — 4 parallel reviewers examine all files in one dispatch. Output per-file issues with file path prefix. Limit 5 files per dispatch (context window).

**CRITICAL:** Every review cycle dispatches FRESH `task` sub-agents. Reviewers have no memory of prior cycles, no investment in defending prior fixes. This prevents confirmation bias.

---

**Reviewer #1 — Correctness & Quality:**

```
You are reviewing tests for correctness and quality. Your job is to find issues — NOT to fix them.

TEST FILE: <full test file content>
SURFACE MAP: <integration surface map from plan, or "none">
JOURNEY MAP: <journey test map from plan, or "none">
TESTING KNOWLEDGE: <Phase 0 research findings, or "none — no surface map">

Use the Testing Knowledge as authoritative guidance for HOW to test these surfaces correctly. Flag tests that use incorrect patterns (e.g., testing concurrency without parallel execution, testing time without clock injection).

CHECK THESE DIMENSIONS:

1. ASSERTION CORRECTNESS:
   - Does each assertion test what the test name claims?
   - Are assertions testing user-visible outcomes (returned data, UI state, side effects, error messages) — NOT internal variables?
   - Are assertions precise (expected value matches actual semantics)?
   - Is there at least one assertion per test? (No tests that "pass" by running without asserting)

2. TEST QUALITY:
   - Is the test deterministic? (No Math.random(), no Date.now() without injection, no shared mutable state)
   - Is setup realistic? (Real dependencies where surface map requires integration, mocks only where allowed)
   - Is teardown clean? (No state leakage between tests)
   - Are test names descriptive? ("should [behavior] when [condition]" — not "test 1")

3. AAA PATTERN:
   - Arrange: is setup clear and minimal?
   - Act: is the action under test obvious?
   - Assert: are assertions grouped logically?

4. FALSE POSITIVES:
   - Could this test pass when the code is broken?
   - Are there assertions that always pass (e.g., expect(true).toBe(true))?
   - Are there missing await/async that cause tests to pass without waiting?

For each issue, return EXACTLY:
ISSUE:
  severity: P0|P1|P2
  dimension: assertion-correctness|test-quality|aaa-pattern|false-positive
  location: <test name or line number>
  description: <what's wrong>
  suggestion: <what to fix>

P0=wrong assertion (test passes but tests wrong thing, or would pass if code broken)
P1=important gap (flaky, unrealistic setup, misleading name)
P2=improvement (AAA clarity, naming polish)
If no issues: NO ISSUES FOUND
```

---

**Reviewer #2 — Coverage & Surface Alignment:**

```
You are reviewing tests for coverage completeness and surface alignment. Your job is to find gaps — NOT to fix them.

TEST FILE: <full test file content>
SURFACE MAP: <integration surface map from plan, or "none">
TESTING KNOWLEDGE: <Phase 0 research findings, or "none">

Use the Testing Knowledge to verify the test uses the correct testing approach for each surface type. Flag tests that use patterns known to be unreliable for the surface being tested.

CHECK THESE DIMENSIONS:

1. HAPPY PATH COVERAGE:
   - Does the test cover the primary success case?
   - Is the happy path tested with realistic data?

2. FAILURE MODE COVERAGE:
   - Does the test cover at least 2 failure modes from the surface map?
   - If no surface map: does the test cover at least 2 failure modes independent of the happy path?
   - Are failure assertions specific (correct error code/message, not just "not success")?

3. BOUNDARY VALUES:
   - For numeric inputs: 0, 1, max-1, max tested?
   - For arrays/collections: empty, single element, max capacity tested?
   - For strings: empty, single char, max length tested?
   - For booleans: both true and false tested?

4. SURFACE ALIGNMENT:
   - Does the test use the correct test layer? (Compare against surface map assignments)
   - Specifically flag: SQL business logic tested with TS mocks (should be pgTAP)
   - External API calls without contract validation tests
   - Auth boundaries without integration tests
   - Unit tests mocking where surface map says integration

5. MISSING TESTS:
   - Are there surfaces in the map with NO corresponding test?
   - Are there failure modes in the map with NO test?
   - Are there user journey steps with NO test?

For each issue, return EXACTLY:
ISSUE:
  severity: P0|P1|P2
  dimension: happy-path|failure-mode|boundary-value|surface-alignment|missing-test
  location: <test file, test name, or "missing">
  description: <what's missing or wrong>
  suggestion: <what to add or fix>

P0=missing critical test (uncovered surface, wrong layer for SQL logic)
P1=important gap (missing failure mode, boundary not tested)
P2=improvement (additional boundary, edge case)
If no issues: NO ISSUES FOUND
```

---

**Reviewer #3 — Journey Alignment** (skip if no Journey Test Map):

```
You are reviewing tests for alignment with user journeys. Your job is to find misalignments — NOT to fix them.

TEST FILE: <full test file content>
JOURNEY MAP: <journey test map from plan>

CHECK THESE DIMENSIONS:

1. JOURNEY STEP COVERAGE:
   - For each step in the Journey Test Map, is there a corresponding test?
   - Does the test verify the acceptance criteria from the journey step?
   - Are there journey steps with no test at all?

2. OUTCOME VERIFICATION:
   - Does each journey-linked test verify the OUTCOME the user experiences?
   - Not just: "the API returned 200"
   - But: "the user sees the booking confirmation with a valid code"
   - Cross-reference test assertions against journey acceptance criteria

3. FAILURE JOURNEYS:
   - Does the Journey Test Map list failure modes?
   - Is each failure mode tested?
   - Does the failure test verify the DEGRADED user experience? (Not just "error returned")

4. SEQUENCING:
   - If the journey has ordered steps, do tests verify the sequence?
   - Are there tests that verify step N's output feeds into step N+1?

For each issue, return EXACTLY:
ISSUE:
  severity: P0|P1|P2
  dimension: journey-coverage|outcome-verification|failure-journey|sequencing
  location: <test name or journey step>
  description: <what's missing or misaligned>
  suggestion: <what to add or fix>

P0=journey step completely untested, or outcome verified wrong
P1=important gap (failure journey untested, sequence not verified)
P2=improvement (better outcome assertion)
If no issues: NO ISSUES FOUND
```

**If no Journey Test Map is provided:** Skip Reviewer #3. Run Reviewers #1, #2, and #4.

---

**Reviewer #4 — Test Quality:**

```
You are reviewing tests for semantic quality — WHAT they verify, not HOW they're written. Your job is to find weak tests that pass mechanical gates but provide zero confidence. Do NOT fix — only flag.

TEST FILE: <full test file content>
SURFACE MAP: <integration surface map from plan, or "none">
E2E SCENARIOS: <E2E scenarios or Journey Test Map, or "none">

CHECK THESE DIMENSIONS:

1. BEHAVIOR VS IMPLEMENTATION:
   - Does the test assert user-visible outcomes (returned data, UI text/state, side effects, error messages)?
   - Or does it assert internal implementation details (state, private methods, mock calls)?
   - For backend: API response fields, event payload shapes, DB state changes — not internal variables
   - Flag any test whose sole assertions are on implementation details

2. MOCK DISCIPLINE:
   - Are integration surfaces tested with realistic dependencies?
   - If Integration Surface Map assigns "integration" or "E2E" to a surface → that surface should NOT be mocked
   - Mocks are fine for unit isolation — flag only when the test LAYER requires real verification

3. OUTCOME ALIGNMENT (skip if no E2E scenarios):
   - Does the test verify the actual outcome the E2E scenario describes?
   - E.g., scenario says "user sees dashboard" → test must check dashboard visibility, not just API 200
   - Flag tests that verify a different (weaker) outcome than what the scenario requires

4. IMPLEMENTATION COUPLING:
   - Does the test use known brittleness anti-patterns?
   - `expect(mockFn).toHaveBeenCalledWith(...)` as sole assertion
   - Snapshot tests without documented purpose
   - Testing DOM structure (querySelector) instead of visible text (getByText)
   - Testing component internals (state, props, instance methods)
   - Flag with the specific anti-pattern — does NOT claim to predict future breakage

5. NEGATIVE CASES:
   - Does the test cover at least one failure mode beyond the happy path?
   - Error states, edge cases, boundary conditions, invalid input, network errors
   - Every feature has at least one failure mode — flag if none is tested

For each issue, return EXACTLY:
ISSUE:
  severity: P0|P1|P2
  dimension: test-quality
  check: TQ1-implementation-detail|TQ2-negative-case|TQ3-mock-overreach|TQ4-outcome-misalignment|TQ5-implementation-coupling|TQ6-test-data|TQ7-excessive-mocking
  location: <test name or line number>
  description: <what makes this a weak test>
  suggestion: <what to assert instead>

P0=implementation detail assertion or missing negative case
P1=mock overreach, outcome misalignment, or implementation coupling
P2=test-data quality or excessive mocking
If no issues: NO ISSUES FOUND
```

---

### Phase 2 — Merge & Dedup

1. Parse all `ISSUE:` blocks from reviewer outputs
2. Dedup: same location + similar description → keep higher severity
3. Sort: P0 > P1 > P2, then correctness > coverage > journey > test-quality
4. If zero issues → tests are clean, exit with `NO ISSUES FOUND`

### Phase 3 — Fix (Research-Backed)

For each issue, apply the minimum change needed. **Research first** for anything involving external systems, library APIs, or unfamiliar patterns:

```
RULES:
1. RESEARCH FIRST (MANDATORY): if an issue involves external systems, library capabilities, 
   or unfamiliar test patterns → use web_search to verify the correct approach before 
   writing the fix. **First check the Testing Knowledge block from Phase 0** — many 
   patterns are already researched. Only fire new queries if the knowledge block does 
   not cover the issue. Skip web_search only if purely internal (typo, naming, formatting).
   
2. SURGICAL EDITS: change only what the issue requires. Do not rewrite the whole test.
   
3. PRESERVE STRUCTURE: keep AAA pattern, test names, file structure intact.
   
4. LOG CHANGES: for each fix, note what changed and why. Include research sources.
```

### Phase 4 — Gate Loop — MANDATORY

Each review cycle dispatches FRESH `task` sub-agents. Reviewers have no memory of prior cycles, no investment in defending prior fixes.

For each cycle:
1. Dispatch all applicable reviewers in parallel via `task` tool (fresh `pi -p` sessions)
2. Parse responses: all return "NO ISSUES FOUND" → exit clean. Issues found → Phase 2-3.
3. After fixes applied, go to step 1 (repeat cycle)

**Exit conditions — ALL must be true:**

- [ ] Last cycle's all reviewers returned "NO ISSUES FOUND" (verbatim, not paraphrased)
- [ ] If cycle 1 found any issues → at least 1 re-review cycle completed
- [ ] Cycle log posted: each cycle's issues and fixes documented

**Hard cap: 10 cycles (fingerprint-stall).** Test review is narrower scope than plan review. On cap:
```
⚠️ Test review capped at 10 cycles — N issues remain:
  - [issue 1]
  - [issue 2]
Proceeding with known gaps. Fix in a follow-up.
```

**FORBIDDEN:**
- ❌ Run review → get issues → fix → declare done without re-dispatching reviewers
- ❌ Self-declare "I addressed the feedback" as completion
- ❌ Re-review in the same conversation context (always fresh `task` sub-agents)

### Phase 5 — Final Verification

After all reviewers return clean, output:
```
✅ Test review complete:
  - Review cycles: N
  - Reviewers per cycle: <1-3>
  - Issues found and fixed: N
  - Final status: CLEAN

Test file: <path>
subjects.team: [auto-populated from issue Team field → AGENT_SESSION_TEAM → fallback organisation-design-team]
subjects.role: [auto-populated from AGENT_SESSION_ROLE, omit if unavailable]
Surface map alignment: ✓
Journey map coverage: ✓ | skipped (no journey map)
7-point quality checklist: ✓
```

**Hash output (test-writing caller only):** If invoked with `--caller test-writing` context, write per-file hash to `~/.pi/agent/test-review/<sha256-of-absolute-test-file-path>.json`. Schema defined in test-writing/SKILL.md Step 7. Include `PASS` on its own line in console output for VGATE compatibility. If invoked standalone or from code-review: skip hash write.

## Integration

**Invoked by:**
- `test-writing` — after Step 3 (7-point self-check) and before Step 4 (Green phase). Catches issues before implementation code is written.
- `code-review` Step 0.5 — during PR review. Re-runs the same review with fresh eyes to catch issues the implementation agent missed.

**Consumes:**
- `test-design` output (Integration Surface Map)
- Plan doc's `### Journey Test Map` section

**Pattern:** Mirrors `plan-review`'s research+review+fix+re-review loop structure, adapted for test-level scope (narrower, 4 reviewers, 3-cycle cap instead of 10).

## When NOT to Use

- Micro tier issues with no test surface (no integration boundaries)
- Pure config/type/comment changes with no test files
- Already reviewed and clean (no changes to test files since last review)

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Skipping the re-review cycle after fixing | Always re-dispatch fresh reviewers — self-declaring "fixed" is not a review |
| Re-reviewing in the same conversation | Confirmation bias — use `task` for fresh sessions |
| Reviewing without surface map context | If surface map is available, provide it to reviewers |
| Expanding scope during fix | Fix only what was flagged — don't rewrite the whole test |
| Cap exit without documenting remaining issues | Always list what's left if capped |
---
> Continue following the workflow as mandated by the orchestrator skill. Do not skip steps.
