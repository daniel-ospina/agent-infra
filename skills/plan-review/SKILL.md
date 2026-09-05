---
name: plan-review
description: Review-fix cycle for implementation plans. Sits between writing-plans and executing-plans. Launches proportional parallel reviewers, merges issues, fixes with research, and loops until clean or convergence. Invoked by writing-plans after saving the plan doc.
subjects.team: organisation-design-team
version: 2.3.0
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
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
    produces: [fixed_plan]
  - name: cycle_status
    type: skill
    gate: auto
    requires: [apply_fixes]
    produces: [status_report]
  - name: final_verification
    type: skill
    gate: verifier
    requires: [cycle_status]
    produces: [verified_plan]
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

**Verifier gate:** dispatches AI reviewers. Pipeline auto-advances when clean.
 from the primary repo -->
> **Canonical:** `agent-infra/skills/plan-review/SKILL.md` — git-tracked source of truth. Pi reads via `~/.pi/agent/skills`; consumers hard-link into `operations/skills`.
>
> **Unified v2.3.0** — agent-neutral. Based on Pi v2.0.0. Research Resolution Gate (#2092), merged Structural+Efficiency, GOOD > EASY design criterion (#51), proportional parallel reviewers (2-4), convergence-gated (cap proportional to risk: 3 for Medium, 5 for Medium-High, 8 for High). Backported 3-layer stuckness detection (fingerprint-stall, honest-stuck, zero-progress) from code-review v3.0.0.

# Plan Review

Automated review-fix cycle for implementation plans. Ensures plan quality before execution begins.

## When to Use

- Invoked automatically by `writing-plans` after saving a Standard or Complex plan doc
- Can also be invoked manually: `plan-review docs/plans/<plan>.md`
- **Skip for Micro tier** — micro plans are inline issue comments, not docs

## Arguments

`plan-review <plan-doc-path> [--issue <number>] [--epic <path>] [--tier standard|complex]`

## Proportional Review Cycles (inlined from proportional-gates v1.0.0)

> Reviewer count scales with plan risk and novelty. Not every plan needs 4 reviewers.

| Risk | Reviewers | Max Cycles |
|------|-----------|------------|
| **Micro** | 0 (skip review) | — |
| **Low-Medium** (small plan, existing patterns) | 2 reviewers (Structural + Integration) | 3 |
| **Medium-High** (large plan, some novelty) | 3 reviewers (+ Efficiency) | 5 |
| **High** (novel architecture, first-of-kind) | 4 reviewers (all parallel) | 8 |

**Proportional dispatch:** The agent decides how many reviewers to launch based on plan size and novelty. A 20-line plan following existing patterns = 2 reviewers. A 200-line plan with new architecture = 4 reviewers. The agent notes the decision; a reviewer sub-agent validates it.

**Level-based routing:** For Project-level issues (Level: project in issue body), prefer inline review in the current context over sub-agent dispatch. For Epic-level issues (Level: epic), use fresh-context sub-agent reviewers (default). If Level is missing, default to sub-agent review (safe default). See `proportional-gates` skill for the canonical routing table.

## Input Resolution

Before starting the first cycle:

1. **Read the plan doc** in full
2. **If `--issue` provided:** fetch issue spec via `gh issue view <N>` and derive epic path from `**Epic:** docs/epics/...`
3. **If `--epic` provided:** read the epic doc
4. **Collect codebase context:** read key files referenced in the plan's `Files:` sections
5. **Resolve research brief:** derive path from epic or plan doc frontmatter
6. **Research Resolution Gate (#2092):** if research brief exists, pre-read content once. Inject as `## Verified Research Context (author-provided)` header into every reviewer sub-agent prompt. If no brief exists, omit the section.

## Review Cycle

```
Phase 1: Review (4 parallel agents)
    ↓
Phase 2: Merge & Dedup
    ↓
Phase 3: Fix (1 agent + research)
    ↓
Phase 4: Cycle Status → [clean|issues|stalled]
    ↓
Phase 5: Final Verification (Claude)
```


## Self-Healing Protocol (NEW in v3.1.0)

When review finds issues, the agent attempts to resolve them autonomously before pausing:

| Issue severity | Action |
|---------------|--------|
| **P2** (improvement) | Fix inline immediately. Note in changelog. Re-review. Do NOT pause. |
| **P1** (important gap) | Research + fix inline. Note in changelog. Re-review. Do NOT pause. |
| **P0** (structural flaw), fixable in < 5 lines | Fix inline. Note in changelog. Re-review. Do NOT pause. |
| **P0**, needs substantial work | File a GitHub issue via issue-creation, run through issue-workflow, return to plan-review cycle. Do NOT pause unless the fix fails. |
| **P0**, requires human input (data loss, security, ontology choice, cost >$10/mo, legal/compliance) | Pause with structured question + research findings. |

**Stall detection:** If the same issue fingerprint persists across 2+ cycles, file an issue and continue (do NOT stall exit). Only stall exit if the issue is P0 and unfixable.


### Phase 1 — Review (Parallel Agents)

Launch the proportional reviewer count (N) from the Review Cycles table **in parallel** via Pi `task`. Each receives the full plan doc, issue spec (if available), epic doc (if available), and research context (if resolved). Each returns `ISSUE:` blocks or `NO ISSUES FOUND`.

---

**Reviewer #1 — Structural & Efficiency** (merged, all 6 dimensions):

```
You are reviewing an implementation plan for structural correctness and efficiency. Your job is to find issues — NOT to fix them.

PLAN DOC: <full plan>
ISSUE SPEC: <body + issue-scoping comment, or "none">
EPIC DOC: <epic content, or "none">

CHECK THESE DIMENSIONS:

1. SPEC COVERAGE (skip if no issue spec):
   - Does the plan address every requirement in the issue spec?
   - Are there gaps — requirements in the issue but absent from the plan?
   - Are there extras — plan tasks that go beyond what the issue requested?

2. STEP COHERENCE:
   - Do any steps contradict each other?
   - Are dependencies between steps explicit and correctly ordered?
   - Does any step depend on something not yet built?
   - Are there circular dependencies?

3. EPIC ALIGNMENT (skip if no epic doc):
   - Does the plan's data model match the epic's?
   - Does the plan's migration approach match the epic's phases?
   - Does the plan respect the epic's component boundaries?
   - Are there any silent divergences from the epic architecture?

4. PARALLELIZABILITY (Complex tier emphasis but always checked):
   - Are there tasks sequenced that have no actual dependency?
   - Could any tasks be merged without losing clarity?
   - Are there unnecessary ordering constraints?

5. PLAN QUALITY (Complex tier emphasis but always checked):
   - YAGNI: does the plan build things not needed for the stated goal?
   - DRY: does the plan duplicate logic across tasks?
   - Are there redundant verification steps?
   - Is complexity proportional to the tier?

6. GOOD > EASY (design quality — always checked):
   - Does any design decision choose the EASY path over the GOOD one? Easy paths accumulate into brittle systems; good paths cost more upfront but pay back in reliability, extensibility, and user satisfaction.
   - Flag decisions that optimize for implementation convenience over outcome quality: shortcuts on error handling, schema changes that skip migrations, duplicated logic instead of a shared abstraction, hardcoded config instead of proper configuration, quick hacks over maintainable patterns.
   - Each GOOD > EASY flag MUST name the Good alternative AND its cost (effort, time, risk). If you cannot name the Good alternative, it is a preference — omit it.

For each issue, return EXACTLY:
ISSUE:
  severity: P0|P1|P2
  dimension: spec-coverage|step-coherence|epic-alignment|parallelizability|plan-quality|good-easy
  location: [Task N, Step M] or [Header section name]
  description: <what's wrong>
  suggestion: <what to fix>

Severity: P0=structural flaw, P1=important gap, P2=improvement
If no issues: NO ISSUES FOUND
```

---

**Reviewer #2 — Integration:**

```
You are reviewing an implementation plan for integration completeness.

PLAN DOC: <full plan>
CODEBASE CONTEXT: <contents of key files referenced in the plan>

CHECK THESE DIMENSIONS:

1. INTERFACE & INTEGRATION IMPACT:
   - Does the plan identify ALL systems that touch or are touched by this change?
   - API contracts: if API shape changes, are all consumers accounted for?
   - Shared types: if TypeScript types change, are all importers updated?
   - Edge functions: if DB schema changes, are edge functions updated?
   - SSR pages: if data shape changes, are server-rendered pages updated?
   - RLS policies: if table access patterns change, are RLS policies updated?
   - Frontend consumers: if API responses change, are components updated?

2. EDGE CASE COVERAGE:
   - Are failure modes addressed (what happens when X fails)?
   - Are auth boundaries checked (who can access what)?
   - Are concurrency issues considered?
   - Are empty/null states handled?

3. TEST COVERAGE:
   - Does every integration surface have a test?
   - Do tests verify behavior, not just implementation?
   - Are edge cases covered by tests?

4. SURFACE MAP QUALITY (skip if no Integration Surface Map in plan):
   - Are all boundaries from the feature spec captured in the map?
   - Are test layers correctly assigned per surface? Specifically flag:
     * SQL business logic tested with TS mocks instead of pgTAP
     * External API calls without contract tests
     * Auth boundaries without integration tests
   - Are failure modes enumerated per surface (at least 2 per surface)?
   - Does the surface map cover the user journey steps (if Journey Test Map exists)?

For each issue, return EXACTLY:
ISSUE:
  severity: P0|P1|P2
  dimension: interface-impact|edge-cases|test-coverage|surface-map-quality
  location: [Task N, Step M] or [Header section name]
  description: <what's wrong>
  suggestion: <what to fix>

P0=structural flaw, P1=important gap, P2=improvement
If no issues: NO ISSUES FOUND
```

---

**Reviewer #3 — UX Coherence:**

```
You are reviewing an implementation PLAN TEXT for UX coherence issues. You are NOT reviewing HTML prototypes — you are reviewing the plan document itself.

PLAN DOC: <full plan>
ISSUE SPEC: <body, or "none">
EPIC DOC: <epic content, or "none">

CHECK THESE DIMENSIONS:

1. UX PATTERN CONSISTENCY:
   - Does the plan describe UI interactions consistently?
   - Are the same UX patterns named the same way across the plan?
   - Are there conflicting UX approaches described in different tasks?

2. UI STATE COVERAGE:
   - Does the plan account for loading, empty, error, and edge-case states?
   - Are transitions between states described?
   - Are there states mentioned in one task but forgotten in another?

3. USER FLOW GAPS:
   - Are there missing steps in user journeys described by the plan?
   - Does the user have a clear path through every described flow?
   - Are there dead ends or unreachable states?

4. UX ASSUMPTIONS:
   - Does the plan make unvalidated assumptions about user behavior?
   - Are UX decisions described without rationale?
   - Are accessibility considerations mentioned where relevant?

For each issue, return EXACTLY:
ISSUE:
  severity: P0|P1|P2
  dimension: ux-coherence
  location: [Task N, Step M] or [Header section name]
  description: <what's wrong>
  suggestion: <what to fix>

If no issues: NO ISSUES FOUND
```

---

**Reviewer #4 — Failure Mode Auditor:**

```
You are conducting a failure-mode gap analysis on an implementation plan. Identify failure modes NOT caught by the plan's listed tests.

TESTING STRATEGY: <extracted from plan>
VERIFICATION PLAN: <extracted from plan>
ACCEPTANCE CRITERIA: <from issue body, or "none">

For each failure mode NOT covered, return:
- The failure scenario
- Why existing tests miss it
- What test would catch it

Consider these failure families:
1. Race conditions / concurrency
2. Partial failures (one system down, others up)
3. Data inconsistency (write succeeds, subsequent read fails)
4. Time-based failures (cron jobs, token expiry, TTL)
5. Auth boundary violations (wrong role accessing data)
6. Input edge cases (empty, oversized, malformed)
7. State corruption (interrupted multi-step operations)
8. Resource exhaustion (rate limits, memory, connections)

For each gap found, return:
ISSUE:
  severity: P0|P1|P2
  dimension: failure-mode-gap
  location: Testing Strategy
  description: <failure mode + why existing tests miss it>
  suggestion: <test that would catch it>

If no gaps: NO ISSUES FOUND
```

### Phase 2 — Merge & Dedup

1. Parse all `ISSUE:` blocks from reviewer outputs
2. Dedup: same location + similar description → keep higher severity
3. Sort: P0 > P1 > P2, then structural > integration > UX > failure > good-easy
4. If zero issues → plan is clean, proceed to Phase 5

### Phase 2.5 — Confidence Scoring (NEW — CPI-7)

After merge-dedup, before Phase 3 (Fix): dispatch isolated confidence scorer sub-agents via Pi `task` for each issue.

**Rubric (same as code-review Step 5):**
```
Score on a scale from 0-100:
a. 0: Not confident. False positive or irrelevant.
b. 25: Somewhat confident. Might be real but could not verify.
c. 50: Moderately confident. Real issue but may be a nitpick.
d. 75: Highly confident. Very likely a real issue that matters.
e. 100: Absolutely certain. Confirmed by evidence.

Return ONLY the number.
```

**Filter:** Issues scoring < 50 are tagged `[LOW-CONFIDENCE]` P2 — surfaced for human judgment, not sent to fixer. Issues scoring >= 50 proceed to Phase 3 (Fix). Low-confidence issues do NOT count as unresolved for convergence purposes.


1. Parse all `ISSUE:` blocks from reviewer outputs
2. Dedup: same location + similar description → keep higher severity
3. Sort: P0 > P1 > P2, then structural > integration > UX > failure > good-easy
4. If zero issues → plan is clean, proceed to Phase 5

### Phase 3 — Fix (1 Agent with Research)

Dispatch a fixer sub-agent via Pi `task`:

```
You are fixing issues found in an implementation plan. For each issue, apply the minimum change needed.

PLAN DOC: <full plan content>
ISSUES TO FIX (all severities): <merged issue list>

RULES:
1. RESEARCH FIRST (MANDATORY): if an issue involves external systems, library capabilities, or unfamiliar APIs → use web_search to verify the correct approach before writing the fix. This is NOT optional — skip only if the issue is purely internal (typo, formatting, in-repo convention). Research protocol: (a) context7 first for library docs, (b) Perplexity queries for best practices and pitfalls (as many as needed to verify the approach), (c) inject findings as context. No query cap — mistakes cost more than queries.
2. SURGICAL EDITS: change only what the issue requires. Do not improve surrounding text.
3. PRESERVE STRUCTURE: keep task numbering, step format, header structure intact.
4. LOG CHANGES: for each fix, note what changed and why. Include whether research was performed and what sources were consulted.
5. GOOD > EASY RESOLUTION (MANDATORY): For every `good-easy` flag, EITHER fix the plan to the Good alternative OR record an explicit deferral in the plan doc:
   `Deferred: <easy path chosen> — Good alternative: <name> — Cost: <effort/time/risk> — Rationale: <why deferred — time-box, external constraint, dependency>`
   A deferral without a named Good alternative + cost + rationale is not a deferral — it is an unresolved flag. Keep it open and surface it to the human.

Return the COMPLETE updated plan doc, followed by:

CHANGELOG:
| # | Issue | Severity | Location | Fix Applied | Research? |
|---|-------|----------|----------|-------------|-----------|

SUMMARY:
- Fixes applied: N
- Research queries: N
- New content introduced: yes/no
```

Write the updated plan to disk. If the fixer introduced substantial new content (new tasks, architectural decisions) → next cycle needed.

### Phase 4 — Gate Loop — MANDATORY

Each review cycle dispatches FRESH `task` sub-agents. The reviewers have no memory
of prior cycles, no investment in defending prior fixes. This prevents confirmation bias.

For each cycle:
1. Dispatch all N reviewers in parallel via `task` tool (fresh `pi -p` sessions)
2. Parse responses: all return "NO ISSUES FOUND" → exit clean. Issues found → Phase 2-3.
3. After fixes applied, go to step 1 (repeat cycle)

**Why task sub-agents:** `pi -p` spawns a fresh session. The reviewer has no context
of the original plan draft, no awareness of what was "just fixed." It evaluates the
current plan text with fresh eyes — the closest available proxy for an independent reviewer.

**Exit conditions — ALL must be true before proceeding to Phase 5:**

- [ ] Last cycle's all N reviewers returned "NO ISSUES FOUND" (verbatim, not paraphrased)
- [ ] If cycle 1 found any issues → at least 1 re-review cycle completed
- [ ] Cycle log posted: each cycle's issues and fixes documented

**No hard cap.** The loop continues until clean exit or convergence. Safety cap at 10 cycles — if reached, escalate to human (runaway prevention, not a quality gate).

**Stuckness detection (3-layer algorithm)**:

a. **Fingerprint-stall**: Hash each surviving issue's dimension+location+description+suggestion (SHA256). If ≥80% of fingerprints match the previous cycle → escalate to human with stuck issues and attempted fixes. Do NOT auto-exit.

b. **Honest-stuck**: Track `issues_per_cycle` (number of issues surviving after each cycle). If issue count is **non-decreasing for 3 consecutive cycles** AND the fingerprints differ from prior cycles (genuinely new issues each time), the fixer is introducing new issues faster than it resolves existing ones. Exit reason = `honest-stuck`. Escalate to human — this indicates a systemic problem.

c. **Zero-progress**: Track whether the plan doc was modified each cycle. If plan doc unchanged for 2 consecutive cycles, the fixer is making zero progress — treat as fingerprint-stall and escalate.

**Convergence rule:** If cycle N issues are a strict subset of cycle N-1 issues (no new dimensions or locations, only previously-flagged items remain), the reviewer is in a refinement loop — fixes are shrinking the problem space but not eliminating it. Log convergence and escalate to human: present remaining issues with attempted fixes. Do NOT auto-exit — remaining issues must be acknowledged by a human before proceeding.

**Cycle-status YAML**: Write `operations/logs/cycle-status.yaml` on loop exit:

```yaml
exit_reason: <clean|fingerprint-stall|honest-stuck|cycle-cap|convergence>
cycles: <N>
issues_per_cycle: <json array>
plan_modified_per_cycle: <json array of booleans>
```

**Progress report:** After each cycle, output: "Plan review cycle N: X issues found across N reviewers, Y fixed, Z remaining."

**FORBIDDEN — these bypass the quality gate entirely:**

- ❌ Run review → get issues → fix → declare done without re-dispatching reviewers
  This IS skipping the review. Fixing without re-reviewing = no review.

- ❌ Self-declare "I addressed the feedback" as completion
  Only "NO ISSUES FOUND" from all fresh reviewers is a valid exit signal.

- ❌ Re-review in the same conversation context
  Confirmation bias makes same-context re-review unreliable.
  Always use `task` for fresh sessions.

### Phase 4.5 — Second-Model Final Gate (Two-Tier Review)

After Phase 4 converges clean (Flash reviewers are done), dispatch ONE second-model reviewer as a final quality gate. The second model is a stronger reasoner — it catches what cheaper reviewers miss. It runs ONCE, only after Flash has converged.

**Model (second-model gate):** dispatch with `model` = `$SECOND_MODEL` (env; default `deepseek/deepseek-v4-pro` — provider-qualified, unambiguous; resolve via `~/.pi/agent/models.json`). When `$SECOND_MODEL` is set but unresolvable, or unset with the default unresolvable, dispatch the tool default (`deepseek-v4-flash`) and annotate the result `[SECOND-MODEL-GATE] stand-in ($SECOND_MODEL=… set-but-unresolvable | unset+default-unresolvable)`. Never silently substitute. Pricing decision (issue #284): `deepseek-v4-pro` (best bug-finding + cost per review pass); qwen3.8-max re-enable only after verbosity control (reasoning_effort/output caps); kimi-k3 opt-in only.

**Dispatch:**
```
task(model=<$SECOND_MODEL per the second-model gate convention>, prompt=<same prompt as Phase 1, single reviewer>)
```

**Prompt:** Same as Phase 1 reviewers — the second model just applies stronger reasoning to the same review dimensions. No prompt engineering needed.

**Second-model findings are surfaced as `[SECOND-MODEL-GATE]` severity tags:**

| Second-model Issue | Action |
|---|---|
| `[SECOND-MODEL-GATE] P0` | Structural flaw missed by Flash — fix required, re-run the second-model gate once |
| `[SECOND-MODEL-GATE] P1` | Important gap — fix required, re-run the second-model gate once |
| `[SECOND-MODEL-GATE] P2` | Improvement — note in plan, do NOT re-run |
| `[SECOND-MODEL-GATE] P3/P4` | Nit/suggestion — note, do NOT re-run |

**Re-dispatch rule:** If the second-model gate finds P0 or P1 → fix → re-dispatch it once. Max 2 second-model cycles. On 2nd failure → surface to human as `[SECOND-MODEL-GATE]` with "second-model final gate could not converge."

**Gate passes:** second-model gate returns CLEAN or only P2+ issues.

**Log:**
```
🔍 second-model final gate: clean | N issues found (P0: X, P1: Y) — resolved in M cycles
```

### Phase 5 — Final Verification

After plan is clean (Phase 4 says clean), dispatch ONE verification sub-agent via Pi `task` that re-reviews the final plan (same N reviewers as the review cycles, proportional to plan risk). Same prompts as Phase 1, concatenated.

If the verification sub-agent finds issues:
- Fix them (Phase 3)
- Re-verify (Phase 5 again)
- Max 2 additional cycles
- On 3rd failure → surface to user

Append a summary line to the plan comment when double-gate runs:
- `🔍 Final verification: found N residuals — resolved in M fix cycles`
- Or: `🔍 Final verification: clean`

## Exit & Signature

On exit, append to the bottom of the plan doc:

```markdown
<!-- plan-review: cycles=N, status=clean|capped|stalled, version=2.3.0 -->
```

**Clean exit:** Return control to writing-plans for Execution Handoff. **Do NOT pause or ask the user for confirmation.** The review cycle IS the quality gate — if it passed, proceed immediately.

**Capped/Stalled exit:** Before halting, the orchestrator (you, the main session) makes one deep-fix attempt:

1. Read all remaining issues
2. Research each one (web_search for correct approaches)
3. Fix the plan directly with researched solutions
4. Re-run the review cycle (Phase 1-4)
5. If still capped/stalled → THEN output "Requires Human Input" with full context

This gives one orchestrator-level recovery before waking the human.

```
## Plan Review — Requires Human Input

**Status:** capped after N cycles | stalled at cycle N
**Remaining:** P0: X, P1: Y, P2: Z

### Unresolved Issues
1. **[P0] [dimension]** — [location]
   [description]
   Fixer attempted: [what was tried]
```

## Announce

At invocation: "Running plan-review on `[plan-doc-path]` with N parallel reviewers (proportional to plan risk). Capped at [3|5|8] cycles per plan risk tier — escalates to human at cap. See Proportional Review Cycles table. Does not auto-exit with remaining issues."
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
