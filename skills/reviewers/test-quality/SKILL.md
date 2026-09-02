---
disable-model-invocation: true
name: test-quality
description: Validates tests verify the right thing — checks behavior-vs-implementation, mock discipline, outcome alignment, implementation coupling, and negative case coverage. Use when reviewing test files in test-review, epic-plan Detailed E2E substep, or verification-before-completion. Returns structured ISSUE blocks or NO ISSUES FOUND.
allowed-tools: read bash grep find web_search web_fetch todo_write task
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

# Reviewer — Test Quality

> **Skill type:** Modular — independently invocable, reusable across Workflows.
> **Continuity:** none — fresh session per invocation, no state carried between calls.
> **Boundary:** Reviewer #1 (Correctness & Quality) in test-review checks HOW tests are written (determinism, AAA pattern, descriptive naming, false positives). This reviewer checks WHAT tests verify — whether the test actually proves the feature works. A test can pass Reviewer #1 and still be a weak test that provides zero confidence.

Weak tests pass all mechanical quality gates but provide zero confidence that the feature works. They test implementation details instead of behavior, mock everything so nothing real is verified, and pass when the outcome is wrong but the implementation is "correct." This reviewer catches those tests before they ship.

## When Used

Dispatched by:
- **test-review** — as 4th parallel reviewer (alongside correctness, coverage+surface, journey-alignment)
- **epic-plan Detailed E2E substep** — as 3rd reviewer (alongside e2e-coverage, e2e-reproducibility)
- **verification-before-completion** — lightweight behavioral assertion check at commit time

## Inputs Required

- **Test file content** — the full test file to review
- **Integration Surface Map** (from plan, optional) — for mock discipline checks
- **E2E scenarios or Journey Test Map** (from plan/epic, optional) — for outcome alignment checks

## Checks to Run

### P0 — Must Fix

**TQ1 — Implementation detail assertion:**
- Test asserts internal state, private methods, or implementation details instead of user-visible outcomes
- User-visible outcomes: returned data, UI text/state, side effects (DB writes, API calls), error messages
- For backend tests: API response fields, event payload shapes, DB state changes — not internal variable values
- Flag with: "what should the USER/CLIENT see or get?"
- Examples of implementation detail: `expect(component.state.showModal).toBe(true)`, `expect(helperCalled).toBe(true)`, `expect(mockFn).toHaveBeenCalledWith(internalArg)`

**TQ2 — Missing negative case:**
- Test covers happy path only with zero failure mode verification
- Every feature has at least one failure mode (invalid input, network error, auth failure, empty state, edge case)
- Flag with: "what happens when this fails?"

### P1 — Should Fix

**TQ3 — Mock overreach in integration test:**
- Integration/E2E test mocks a critical integration surface that should be tested realistically
- Mocks are fine for unit isolation; flag when the test layer requires real (or realistic) dependency verification
- Cross-reference with Integration Surface Map — if map assigns "integration" or "E2E" layer to a surface, that surface should not be mocked
- Flag with the surface name and assigned test layer

**TQ4 — Outcome misalignment:**
- Test verifies a different outcome than what the E2E scenario or journey describes
- E.g., scenario says "user logs in and sees dashboard" but test only verifies "API returned 200" without checking dashboard visibility
- Only check when E2E scenarios or Journey Test Map are provided — skip otherwise
- Flag with the scenario reference and the missing outcome check

**TQ5 — Implementation coupling pattern:**
- Test uses known brittleness anti-patterns that cause refactor fragility:
  - `expect(mockFn).toHaveBeenCalledWith(...)` as the sole assertion (testing mock behavior, not real behavior)
  - Snapshot tests without a documented purpose (snapshots break on any change)
  - Testing DOM structure (`querySelector('.class-name')`) instead of visible text (`getByText('...')`)
  - Testing component internals (state, props, instance methods)
- Flag with the specific anti-pattern found
- Note: checks for KNOWN patterns — does not claim to predict future breakage

### P2 — Should Fix (blocks merge)

**TQ6 — Test-data quality:**
- Hardcoded test data that masks edge cases (e.g., always using "test@example.com", always using same IDs)
- Test data that doesn't represent realistic production scenarios
- Flag with suggestion for more representative data

**TQ7 — Excessive mocking:**
- Test mocks >50% of its dependencies — may be testing mocks, not the system
- Flag with "consider whether this test provides real confidence"
- Skip for pure unit tests where mocking all collaborators is expected

## Output Format

```
ISSUE #N
Dimension: Test Quality
Severity: P0 | P1 | P2
Location: [test name or line number]
Problem: [what makes this a weak test]
Fix: [what to change — assert user-visible outcome, add failure case, use real dependency, etc.]
```

End with:
```
TEST QUALITY REVIEW SUMMARY
P0 issues: [count]
P1 issues: [count]
P2 issues: [count]
Tests reviewed: [count]
Weak tests found: [count]
Dimensions flagged: [list — e.g., "implementation-detail, negative-cases"]
```

If no issues found, return: NO ISSUES FOUND
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
