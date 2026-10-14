---
name: test-review
description: Review-fix loop for tests. Dispatches 2 merged reviewers by concern (A correctness + discriminating power, B coverage + surface + journey alignment), plus C (e2e + reproducibility) only when the change touches e2e surfaces; merges issues, fixes with research, and loops until clean or convergence. Invoked by test-writing after test creation and by code-review at PR time.
subjects.team: organisation-design-team
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
version: 1.1.0
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

> **Cold-class seam (#512):** reviewer/eval dispatches are cache-cold one-shot traffic — an operator who exports `COLD_CLASS_PROVIDER=venice` opts them into the venice leg (`--provider venice --model deepseek-v4-flash`; same model id — venice serves cold prompts with cache reads). **Unset (default) = inert.** Interactive/warm traffic never routes venice (docs/providers.md §8).

> **v1.1.0 (reviewer merge).** The 4 dispatch slots are merged into **2 reviewers by concern**, so every former lens is covered by exactly one merged reviewer:
>
> | Merged reviewer | Absorbs | Concern it covers |
> |---|---|---|
> | **A — Correctness & Discriminating Power** | #1 Correctness & Quality + #4 Test Quality | is each assertion *correct*, and does it actually discriminate? Runs **two ordered passes** — mechanical correctness, then semantic strength |
> | **B — Coverage, Surface & Journey Alignment** | #2 Coverage & Surface Alignment + #3 Journey Alignment | does the suite cover the required surfaces and journey steps, at the right layer? |
> | **C — E2E & Reproducibility** (conditional) | new — covers the e2e-coverage and reproducibility concerns; consults `skills/reviewers/e2e-coverage`, `skills/reviewers/e2e-reproducibility` as supplementary references | fires only when the change touches e2e surfaces |
>
> **Why the two passes stay ordered.** `skills/reviewers/test-quality/SKILL.md` records the boundary: a test can pass mechanical correctness and still be a weak test that proves nothing. Merging the *dispatch* must not merge the *lens* — so pass 2 keeps its own `ISSUE:` output and its own `check:` field (TQ1–TQ7), and it runs **after** pass 1, never instead of it.
>
> **What the merge does cost — independence, stated rather than claimed away.** Both passes run in **one `task` dispatch, one context**. Before the merge, reviewer #4 was a separate fresh sub-agent that had never seen reviewer #1's conclusions; pass 2 now runs in the agent that produced pass 1, so it is **not** independent of pass 1's findings the way a fresh dispatch is. The independence guarantee this skill relies on (`CRITICAL: Every review cycle dispatches FRESH task sub-agents`) holds **across cycles**, not within a dispatch. The ordered passes preserve the *lens distinction*, not cross-pass blindness — a deliberate trade for the dispatch reduction, recorded on #1538.
>
> **A's combined verdict — the clean exit is a verdict, not a token match.** A emits per-pass verdicts **and exactly one overall verdict line**: `REVIEWER A VERDICT: CLEAN` only when **both** passes returned `NO ISSUES FOUND`; otherwise `REVIEWER A VERDICT: ISSUES`. A response that prints `NO ISSUES FOUND` for pass 1 and `ISSUE:` blocks for pass 2 is `REVIEWER A VERDICT: ISSUES` and is **not** clean — see Phase 4's exit conditions.
>
> **B's combined verdict — the same rule, for the same reason.** B has the same two-parts-one-dispatch structure as A (part 1 coverage/surface, part 2 journey alignment — the latter skipped only when no Journey Test Map was provided), so a bare part-1 `NO ISSUES FOUND` must not be readable as B's verdict. B emits **exactly one overall verdict line**: `REVIEWER B VERDICT: CLEAN` only when **every part it ran** returned `NO ISSUES FOUND`; otherwise `REVIEWER B VERDICT: ISSUES`. Part 1 clean plus part 2's `ISSUE:` blocks is `REVIEWER B VERDICT: ISSUES`, never clean — a `NO ISSUES FOUND` from one part is not B's verdict. See Phase 4's exit conditions.
>
> **The count.** `proportional-gates` §Review Cycles **owns** the reviewer-count table and is unchanged. `test-review`'s merged panel is **2** (3 when C fires), so a High-risk test review fields at most 3; the table's "4" is an upper bound this panel cannot reach, and depth is scaled *inside* A and B instead (A's two passes always run). Deliberate — see the `OVERRIDES:` line on #1538.
>
> **Precedence change (intentional).** With the grouping, Phase 2's tie-break sort becomes pass 1 > pass 2 > coverage/surface > journey; it was correctness > coverage > journey > test-quality. `test-quality` moves from last to second and `journey` to last, so the semantic-strength pass is never filed below the coverage or journey lenses at equal severity.
>
> Supersedes `test-review`'s reviewer-count clause only (not the HOW/WHAT boundary), extending #1538/#1539 from `code-review` to this skill. Load rationale and metrics: #1538.


# Test Review

Automated review-fix cycle for tests. Ensures tests are correct, complete, and aligned with integration surfaces and user journeys before merge.

## When to Use

- **Invoked by `test-writing`** after tests are written (in-execution review — catches issues before implementation code)
- **Invoked by `code-review` Step 0.5** (pre-merge review — catches issues with fresh eyes before merge)
- Can be invoked manually: `test-review <test-file> [--surface-map <path>] [--journey-map <path>]`

## Arguments

`test-review <test-file> --surface-map <surface-map-text> [--journey-map <journey-map-text>]`

At minimum, provide the test file content. Surface map and journey map are extracted from the plan doc if available.

**Also required for Reviewer A's pass 1, and passed by the `test-writing` Step 3.5 dispatch:** `TEST DIFF` (the diff of the test files in this batch) and `SABOTAGE EVIDENCE` (the observed failure against the unfixed code). Reviewer A's pass 1 discriminating-power check is decidable *only* from these; pass `"none supplied"` when either is genuinely absent (the check then names the missing evidence rather than guessing). A manual invocation that omits them runs that check blind.

## Review Cycle

```
Phase 1: Review (2 merged reviewers — fresh task sub-agents; + C when e2e)
    ↓
Phase 2: Merge & Dedup
    ↓
Phase 3: Fix (research-backed, surgical edits)
    ↓
Phase 4: Re-review (fresh sub-agents, no memory of prior cycle)
    ↓
Loop until every dispatched reviewer returns its clean verdict or convergence (safety cap: 10 cycles)
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

Produce a `### Testing Knowledge` block with ALL findings (from knowledge base + Tortoise + fresh research). Inject it as context for the reviewers whose prompts carry a `TESTING KNOWLEDGE` field — **Reviewer A's pass 1** and **Reviewer B's part 1** — and for the fixer. The semantic-strength pass (A pass 2), the journey pass (B part 2), and Reviewer C do not take the field:

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

### Phase 1 — Review (2 merged reviewers, by concern)

Launch the merged reviewers **in parallel** via Pi `task` — **A** and **B**, plus **C** when the change touches e2e surfaces. Each receives the full test file(s), surface map (if available), and journey map (if available). Each returns `ISSUE:` blocks or its clean verdict — A and B each emit one combined verdict line (`REVIEWER A VERDICT:` / `REVIEWER B VERDICT:`), C returns `NO ISSUES FOUND` — as specified below.

**A runs two ORDERED passes in one dispatch** — mechanical correctness, then semantic strength. The passes are never collapsed into one judgement: a test can pass the first and still be a weak test that provides zero confidence (`skills/reviewers/test-quality/SKILL.md`, Boundary).

**Multi-file support:** TEST FILE may be a single file or a list. For multiple files, review all simultaneously — the merged reviewers examine all files in one dispatch. Output per-file issues with file path prefix. Limit 5 files per dispatch (context window).

**CRITICAL:** Every review cycle dispatches FRESH `task` sub-agents. Reviewers have no memory of prior cycles, no investment in defending prior fixes. This prevents confirmation bias.

---

**Reviewer A — Correctness & Discriminating Power.**

**Pass 1 — mechanical correctness** (run this pass first):

```
You are reviewing tests for correctness and quality. Your job is to find issues — NOT to fix them.

TEST FILE: <full test file content>
TEST DIFF: <the diff of test files in this PR, or "none supplied">
SABOTAGE EVIDENCE: <the observed-failure output the author recorded for the changed assertions, or "none supplied">
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
   - **Discriminating power — for each assertion the TEST DIFF adds or changes, does SABOTAGE EVIDENCE show it failing against the unfixed code?** A green suite cannot distinguish a real pin from a vacuous one: both are green. This check is decidable only from the diff plus the evidence — so when TEST DIFF or SABOTAGE EVIDENCE is "none supplied", flag P0 **only** for a changed assertion whose description names a fixed defect, and name the missing evidence rather than guessing. Do not flag assertions the diff does not touch.
   - **Could this assertion pin a race?** An equality on a value that is identical under *every* schedule cannot — the observable must *differ* between the buggy and fixed schedules. Where a changed assertion claims to pin a concurrency bug, require an operation-history oracle instead: count invocations (a `PATH` shim suffices) and assert the exact count. Flag P0 if the assertion is invariant across schedules — but schedule-invariance is not decidable from the diff alone, so when `SABOTAGE EVIDENCE` is `"none supplied"`, name the missing schedule evidence rather than asserting invariance.

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
   - Could this test pass when the code is broken? — but see the evidence rider under ASSERTION CORRECTNESS: when `SABOTAGE EVIDENCE` is `"none supplied"`, name the missing evidence rather than asserting it.
   - Are there assertions that always pass (e.g., expect(true).toBe(true))?
   - Are there missing await/async that cause tests to pass without waiting?

For each issue, return EXACTLY:
ISSUE:
  severity: P0|P1|P2
  dimension: assertion-correctness|test-quality|aaa-pattern|false-positive
  location: <test name or line number>
  description: <what's wrong>
  suggestion: <what to fix>

P0=wrong assertion (test passes but tests wrong thing, or would pass if code broken — **a vacuous pin belongs here: it is exactly "would pass if code broken"**)
P1=important gap (flaky, unrealistic setup, misleading name)
P2=improvement (AAA clarity, naming polish)
If no issues: NO ISSUES FOUND
```

---

**Pass 2 — semantic strength** (SAME reviewer, run AFTER pass 1; return this pass's `ISSUE:` blocks separately, using the `check:` field below):

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

**A's required output — both passes, then one verdict.** Print pass 1's `ISSUE:` blocks (or `NO ISSUES FOUND`) first, then pass 2's, then exactly one line:
`REVIEWER A VERDICT: CLEAN` — only when **both** passes returned `NO ISSUES FOUND`
`REVIEWER A VERDICT: ISSUES` — otherwise, with both passes' issues listed above
A response carrying `NO ISSUES FOUND` from pass 1 and `ISSUE:` blocks from pass 2 is `REVIEWER A VERDICT: ISSUES`, never clean.

---

**Reviewer B — Coverage, Surface & Journey Alignment.**

**Part 1 — coverage and surface** (run this part first):

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

**Part 2 — journey alignment** (SAME reviewer, run AFTER part 1; skip if no Journey Test Map):

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

**If no Journey Test Map is provided:** skip B's part 2. B's part 1 still runs.

**B's required output — both parts, then one verdict.** Print part 1's `ISSUE:` blocks (or `NO ISSUES FOUND`) first, then part 2's — or the line `part 2: skipped (no Journey Test Map)` when it was skipped — then exactly one line:
`REVIEWER B VERDICT: CLEAN` — only when **every part B ran** returned `NO ISSUES FOUND`
`REVIEWER B VERDICT: ISSUES` — otherwise, with every part's issues listed above
A part-1 `NO ISSUES FOUND` followed by part-2 `ISSUE:` blocks is `REVIEWER B VERDICT: ISSUES`, never clean.

---

**Reviewer C — E2E & Reproducibility** (conditional — dispatch ONLY when the change touches e2e surfaces: an E2E scenario, a Playwright/browser surface, or the failure-reproduction path of an e2e/browser test. A unit-test pin that is not part of an e2e surface does NOT fire C):

```
You are reviewing tests for end-to-end coverage and reproducibility. Your job is to find gaps — NOT to fix them.

TEST FILE: <full test file content>
E2E SCENARIOS: <E2E scenarios / Journey Test Map, or "none">
SURFACE MAP: <integration surface map from plan, or "none">

CHECK THESE DIMENSIONS:

1. E2E COVERAGE:
   - Is each end-to-end scenario in the plan covered by a test that drives the real stack?
   - Are there scenario steps exercised only through mocks, when the scenario claims end-to-end?

2. REPRODUCIBILITY:
   - Does the test reproduce the failure deterministically, or does it depend on timing/ordering?
   - Is the failure it pins re-runnable in isolation (single test, no shared state from a prior test)?
   - Is there a recorded command that reproduces the failure against the unfixed code?

3. ENVIRONMENT HONESTY:
   - Does the test assert on what the user observes, or on an intermediate artifact?
   - Are timeouts/bounds stated rather than inherited from a default?

For each issue, return EXACTLY:
ISSUE:
  severity: P0|P1|P2
  dimension: e2e-coverage|reproducibility|environment-honesty
  location: <test name or line number>
  description: <what's wrong>
  suggestion: <what to fix>

P0=scenario claimed end-to-end but driven through mocks, or failure not reproducible at all
P1=non-deterministic reproduction, or ordering-dependent test
P2=weaker assertion than the scenario requires
If no issues: NO ISSUES FOUND
```

**C's specification is the inline prompt above — not a catalog.** `skills/reviewers/e2e-coverage/SKILL.md` and `skills/reviewers/e2e-reproducibility/SKILL.md` are **supplementary references** for the e2e-coverage and reproducibility concerns; both are plan-pipeline catalogs whose required inputs are epic-doc sections (Detailed E2E, User Journeys, Data Model, Architecture) and whose output shape is `ISSUE #N / Dimension: …`, so neither can be run against a test file as-is. Read them for their concern list and check IDs (`E2E1–E2E7`, `E2R1–E2R7`); emit findings in C's `ISSUE:` shape above.

---

### Phase 2 — Merge & Dedup

1. Parse all `ISSUE:` blocks from reviewer outputs
2. Dedup: same location + similar description → keep higher severity
3. Sort: P0 > P1 > P2, then pass 1 (mechanical correctness) > pass 2 (semantic strength) > coverage/surface > journey (pre-merge this was correctness > coverage > journey > test-quality — the change is intentional, see the v1.1.0 note)
4. If zero issues across every reviewer and every pass → tests are clean; exit is by per-reviewer verdict (`REVIEWER A VERDICT: CLEAN`, `REVIEWER B VERDICT: CLEAN`, C `NO ISSUES FOUND`) — a bare `NO ISSUES FOUND` token is not an exit, see Phase 4

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
2. Parse responses: every dispatched reviewer must return its clean verdict → exit clean. Issues found → Phase 2-3.
3. After fixes applied, go to step 1 (repeat cycle)

**The clean verdict is per-reviewer and unambiguous — a bare `NO ISSUES FOUND` is NOT enough.** Reviewer A returns **one overall verdict**, `REVIEWER A VERDICT: CLEAN`, which requires *both* of its ordered passes to be clean. A response that prints `NO ISSUES FOUND` for pass 1 and `ISSUE:` blocks for pass 2 is `REVIEWER A VERDICT: ISSUES` and does **not** exit the loop — this is the fail-open the per-pass combination rule closes. Reviewer B is built the same way: it returns **one overall verdict**, `REVIEWER B VERDICT: CLEAN`, which requires *every part it ran* to be clean — part 1 clean plus part 2 `ISSUE:` blocks is `REVIEWER B VERDICT: ISSUES` and does **not** exit the loop. Reviewer C, when dispatched, returns `NO ISSUES FOUND`.

**Exit conditions — ALL must be true:**

- [ ] Last cycle's every dispatched reviewer returned its clean verdict **verbatim** (not paraphrased): Reviewer A → `REVIEWER A VERDICT: CLEAN` (both passes clean), Reviewer B → `REVIEWER B VERDICT: CLEAN` (every part it ran clean), and Reviewer C → `NO ISSUES FOUND` if it was dispatched
- [ ] The cycle log records whether C was dispatched: `C: dispatched` or `C: skipped (<reason>)` — an unrecorded skip counts as C not having run
- [ ] If cycle 1 found any issues → at least 1 re-review cycle completed
- [ ] Cycle log posted: each cycle's issues and fixes documented

**Stuckness detection:** recurrence = `|current ∩ prev| / |prev|` (the fraction of the previous cycle's issues that recurred). Fingerprints are taken over `location + severity` — **not** `description`/`suggestion`, which a fresh reviewer re-words every cycle.
- **Fingerprint-stall:** recurrence ≥ `stall_threshold` (default `0.8`) → escalate to human.
- **Honest-stuck:** issue count non-decreasing for 3 consecutive cycles → escalate to human. **Independent signal — fires regardless of recurrence** (a one-for-one churn has low recurrence but is not converging).
- **Zero-progress:** no files changed 2 consecutive cycles → escalate to human.

> **Fire if `recurrence ≥ stall_threshold` OR the count is non-decreasing for 3 cycles.** Either alone is sufficient. Recurrence picks the *label* only (`honest-stuck` when the count is not shrinking, else `fingerprint-stall`) — never a precondition for the count signal. The executable predicate lives in `code-review/references/fixer-loop.md`.

**Hard cap: 10 cycles.** Test review is narrower scope than plan review. On cap:
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
  - Reviewers per cycle: 2 (A, B) — or 3 when C fires (e2e)
  - Reviewer A: pass 1 <CLEAN | N issues>, pass 2 <CLEAN | N issues> — combined verdict <CLEAN | ISSUES>
  - Reviewer B: part 1 <CLEAN | N issues>, part 2 <CLEAN | N issues | skipped (no Journey Test Map)> — combined verdict <CLEAN | ISSUES>
  - Reviewer C: dispatched | skipped (<reason>)
  - Issues found and fixed: N
  - Final status: CLEAN

Test file: <path>
subjects.team: [auto-populated from issue Team field → AGENT_SESSION_TEAM → fallback organisation-design-team]
subjects.role: [auto-populated from AGENT_SESSION_ROLE, omit if unavailable]
Surface map alignment: ✓
Journey map coverage: ✓ | skipped (no journey map)
7-point quality checklist: ✓
```

## Integration

**Invoked by:**
- `test-writing` — after Step 3.5 (Test Review) and before Step 4. On the TDD path this runs before implementation code is written; for a **pin added to an existing suite** the implementation already exists, and Step 4's sabotage evidence is produced *before* the dispatch.
- `code-review` Step 0.5 — during PR review. Re-runs the same review with fresh eyes to catch issues the implementation agent missed.

**Consumes:**
- `test-design` output (Integration Surface Map)
- Plan doc's `### Journey Test Map` section

**Pattern:** Mirrors `plan-review`'s research+review+fix+re-review loop structure, adapted for test-level scope (narrower, 2 merged reviewers plus C, **10-cycle cap** — see "Hard cap: 10 cycles" above).

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
