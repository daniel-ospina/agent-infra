---
name: test-writing
description: Use when writing tests during implementation — enforces Red-Green-Refactor cycle, 7-point quality self-check, and workflow/journey alignment. Invoked by executing-plans for test-writing task steps.
domain: engineering
subjects.team: organisation-design-team
allowed-tools: read write edit bash grep find
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

# Test Writing

## Overview

Guides agents in writing tests that are **correct**, **workflow-aligned**, and **reviewable**. Consumes the Integration Surface Map (from `test-design`) and Journey Test Map (from the plan doc) to ensure every test verifies the right thing at the right layer.

**Core principle:** Tests verify outcomes the user experiences, not internal implementation details. A passing test that doesn't check the right thing is worse than no test — it creates false confidence.

**Announce at start:** "I'm using the test-writing skill to write workflow-aligned tests."

## When to Use

- During `executing-plans` when a task step says "Write the failing test" or "Write tests"
- When adding tests to existing code
- When reviewing test coverage for a feature

**When NOT to use:**
- Pure type/interface changes with no behavior
- Config or documentation changes
- Already has comprehensive, reviewed tests

## Process

### Step 1 — Consume Artifacts

Before writing any test, gather context:

1. **Integration Surface Map** — from the plan doc's `### Integration Surface Map` section. Identifies: what boundaries exist, what test layer each surface requires, what failure modes to test.
   - If no surface map exists (micro tier, pure logic): proceed — unit TDD only.

2. **Journey Test Map** — from the plan doc's `### Journey Test Map` section. Identifies: what user goals this feature serves, what outcomes the user should experience.
   - If no journey map exists (no user-facing journeys): proceed — test code-level behavior.

3. **Target test layer** — from the surface map for the surface being tested:
   - **Unit (Vitest):** Pure logic, transforms, utils. No external deps.
   - **Integration (Vitest + real Supabase):** DB reads/writes, auth flows, external API calls.
   - **pgTAP:** SQL business logic (transactions, RLS, triggers). Required, not optional.
   - **E2E (Playwright):** User-facing critical paths against real backend.

### Step 2 — Red Phase (Write the Failing Test)

Write the test FIRST, before implementation code. The test is the spec.

**Test structure requirements:**

1. **Descriptive name:** `should [behavior] when [condition]` — not `test case 1` or `test error`.
   - ✅ `should return 401 for expired token`
   - ❌ `test auth error`

2. **Arrange-Act-Assert** (AAA) pattern:
   ```typescript
   // Arrange — set up the scenario
   const expiredToken = createExpiredToken();
   
   // Act — perform the action
   const result = await validateToken(expiredToken);
   
   // Assert — verify the outcome
   expect(result).toEqual({ valid: false, reason: 'expired' });
   ```

3. **One behavior per test:** Each test verifies exactly one thing. Split compound assertions into separate tests.

4. **Reference the journey step:** If a Journey Test Map exists, include the journey step this test validates as a comment:
   ```typescript
   // Journey: Reserve table → Step 2: Receive confirmation
   test('should send confirmation email after successful booking', async () => {
   ```

#### Property-Based Test Pattern

When the surface calls for property-based testing (see `test-design` PBT applicability table):

1. **Identify the property:** What must always be true for all inputs? Common properties: idempotency (`f(f(x)) === f(x)`), roundtrip (`decode(encode(x)) === x`), commutativity (`f(a, b) === f(b, a)`), model-based (implementation matches a simpler reference model).
2. **Generate arbitraries:** Use `fast-check` built-ins (`fc.integer()`, `fc.string()`, `fc.array()`) or compose custom arbitraries for your domain types.
3. **Assert the property:** Use `fc.assert` or `test.prop` (from `@fast-check/vitest`) to run the property against hundreds of random inputs.

> **Install prerequisite:** `npm install --save-dev fast-check @fast-check/vitest`

```typescript
import { test } from 'vitest';
import { fc, test as fcTest } from '@fast-check/vitest';

fcTest.prop('roundtrip: decode(encode(x)) === x', [fc.string()], (input) => {
  expect(decode(encode(input))).toBe(input);
});
```

⚠️ **~50% false discovery rate:** LLM-generated property violations are often incorrect assertions or design choices, not real bugs. Verify each failure before changing production code.

### Step 3 — Quality Self-Check

Before writing implementation code, verify the test against this checklist. **All applicable items must pass.** If any fail, revise the test.

| # | Check | How to Verify | Common Failure |
|---|-------|---------------|----------------|
| 1 | **Assertion tests user-visible outcome** | Does the assertion check something the user/consumer experiences? Returned data, UI state, side effect, error message — not an internal variable. | `expect(counter).toBe(1)` when the user sees a badge count |
| 2 | **Covers happy path + top 2 failure modes** | Does the test suite include: (a) the expected success case, (b) the most likely failure from the surface map, (c) a second failure mode? | Only testing "it works" — missing timeout, auth error, or empty input |
| 3 | **Boundary values tested** | For numeric inputs and arrays: test 0, 1, max-1, max. For strings: empty, single char, max length. | Testing only the happy middle — missing empty array or max-size payload |
| 4 | **Test name describes behavior** | Can someone reading the test output understand what broke without opening the test file? | `test error case` vs `should reject booking when no tables available` |
| 5 | **Setup matches production conditions** | Is the test using real dependencies where the surface map requires it? Mocks only where surface map allows. | Mocking Supabase when the surface map says integration; using `Date.now()` without cleanup |
| 6 | **Test is deterministic** | Run twice — same result both times? No `Math.random()`, no `new Date()` without injection, no shared mutable state between tests, clean teardown. | Test passes on first run, fails on second due to shared state |
| 7 | **Test references the journey step** | If a Journey Test Map exists, does the test file or test name reference the journey step it validates? | Journey: "Book reservation" — no test covers the confirmation step |

**pgTAP-specific checks** (when writing SQL tests):

| # | Check |
|---|-------|
| 8 | **Tests run inside a transaction** — each test is isolated and rolls back |
| 9 | **Tests edge cases on RLS** — wrong user, no user, service role |
| 10 | **Tests concurrent access** — if the function modifies shared state, test with parallel execution |


**PBT-specific checks** (when writing property-based tests):

| # | Check |
|---|-------|
| 11 | **Property is an invariant, not an example** — `for all x: f(f(x)) === f(x)`, not `f(3) === 3` |
| 12 | **Arbitraries match the domain** — integer range, string constraints, array sizes match realistic inputs |
| 13 | **Failure is verified before code change** — ~50% false discovery rate; confirm it's a real bug, not a design choice |

**On failure:** Revise the test until all checks pass. Do not proceed to Green phase with a failing checklist. For PBT: verify the failure is a real bug before changing production code.

### Step 3.5 — Test Review (Mandatory Synchronous Gate)

**⛔ MANDATORY GATE — blocks Green phase until clean.** After the 7-point self-check passes, dispatch `test-review` as a `task` sub-agent for independent review. The self-check is the writer reviewing their own work; `test-review` brings an external perspective with 4 parallel reviewers checking correctness, coverage+surface, journey-alignment, and test-quality.

**Dispatch (multi-file, single invocation).** `TEST DIFF` and `SABOTAGE EVIDENCE` are REQUIRED fields — reviewer 1's discriminating-power check is decidable only from them, and omitting them makes that check fire blind. **What goes in `SABOTAGE EVIDENCE` depends on which path you are on, and on the TDD path below it is expected to be empty:**

- **(a) TDD path** — the test was written before the implementation, so this gate runs *before* Step 4 (run the test) and Step 5 (implement the fix). There is no fix to revert yet, so `"none supplied"` is the correct and expected value here; reviewer 1's fallback branch governs, and that is not a gap.
- **(b) Pin added to an existing suite** (the fix already exists — the regression case, and the one #820 is about) — perform the Step 4 sabotage procedure **now**, before dispatching, and paste the observed failure. Do not leave this empty: on this path an empty field is exactly the vacuous-pin condition the check exists to catch.
- If a batch mixes both, fill in (b)'s evidence and say so; do not leave the field blank because part of the batch is TDD-authored.
```
task(prompt='test-review: <file1> <file2> ... \n\nTEST DIFF: <diff of the test files in this batch, or "none supplied">\nSABOTAGE EVIDENCE: <per the must-fail requirement in Step 4 below — see the two cases above; write "none supplied" if there is none>\nSURFACE MAP: <surface map from plan doc>\nJOURNEY MAP: <journey map from plan doc>\n\nTEST FILE 1: <full content>\nTEST FILE 2: <full content>\n...')
```

All changed test files from this implementation batch are dispatched in a SINGLE task sub-agent invocation. Limit 5 files per dispatch (context window). test-review runs its full protocol (Phases 0-5) and returns per-file results.

**Cap protocol (test-review's 10-cycle cap, not 3):**
- CAPPED + only P1/P2 issues → **WARN** — proceed to Green phase. Document remaining issues.
- CAPPED + any P0 issue → **escalate to human gate.** Do NOT proceed. Present issues for decision.
- CLEAN (all 4 reviewers return NO ISSUES FOUND) → proceed to Green phase.

**Wrong-layer P0 escalation:** If Reviewer #2 flags "SQL business logic tested with TS mocks (should be pgTAP)":
1. Escalate to implementer with pgTAP guidance: file path convention (`supabase/tests/`), assertion patterns, link to test-writing pgTAP-specific checks (#8-10)
2. Implementer writes pgTAP test → re-run test-review for that surface only
3. Max 2 re-review attempts. Still P0 after 2 → human gate.

**Sub-agent failure:** If `task` sub-agent crashes or times out → retry 2x with exponential backoff (1s, 2s). Still failing → escalate to human.

**Surface map pre-check:** If no surface map exists for these test files AND files touch DB/API/auth boundaries → WARN "no surface map — test-review runs without layer assignment context."

### Step 3.8 — Isolated checkouts — never copy the repo (#1141)

When a test must run against a ref other than your current checkout (verifying a
branch, reproducing on `main`, mutation-probing a file), get the checkout from a
worktree — never a copy:

```bash
bash scripts/scratch-worktree.sh run --repo <repo> --ref <ref> \
  [--paths <dir,file> | --full] -- <test-command...>
```

`run` shares the object store (no second `.git`) and **removes the worktree on
EXIT/INT/TERM/HUP**, so a failing or killed test still leaves nothing behind.
`--paths` is a sparse checkout (a few KB) — use it when the test only reads some
paths. `--full` is the whole tracked tree.

**BANNED for scratch checkouts:** `git clone`, `cp -R`, `cp -r`, `cp -a`, `rsync`
of the repo, `git archive | tar -x` into a temp dir. If you create a worktree by
hand, the trap is mandatory and MUST re-raise the status (a trap that does not
`exit` swallows the signal and the script keeps running):

```bash
REPO=<repo>; D="$REPO/.worktrees/scratch-$$"
git -C "$REPO" worktree add --detach "$D" <ref>
GD="$(sed -n 's/^gitdir: //p' "$D/.git" 2>/dev/null)"
trap 'rc=$?; rm -rf "${D:-/nonexistent}" 2>/dev/null || true; if [ ! -e "${D:-/nonexistent}" ]; then git -C "$REPO" worktree remove --force "${D:-/nonexistent}" 2>/dev/null || true; case "${GD:-}" in /*/.git/worktrees/*) rm -rf "$GD";; esac; else echo "leftover ${D:-?} - record KEPT so list shows it" >&2; fi; exit $rc' EXIT
trap 'exit 130' INT; trap 'exit 143' TERM
```

The trap removes the TREE first and only then deregisters: `git worktree remove --force`
drops the record even when it FAILS to delete the directory, so deregistering first would
leave a surviving checkout invisible to `list`, to a second `clean <path>` and to the
reaper (#1141).
The record removal is TARGETED: a bare `git worktree prune` deregisters every
record whose directory is not currently stat-able (unmounted volume, permission
blip, stale network mount), so it can silently destroy an unrelated sibling
worktree's checkout while its files sit on disk. Remove your own record — the
trap above reads its own `gitdir:` line — never prune the whole repo.

Before reporting done, `bash scripts/scratch-worktree.sh list --repo <repo> --root <the root you used>` must not show a
scratch worktree of YOURS. Clean only your own path (`scratch-worktree.sh clean
<path>`). A bare `clean --all` refuses to sweep (it cannot see a holder whose argv
does not name the path, so it would delete a sibling's in-flight probe);
`clean --all --force-all` is the deliberate sibling sweep — do not run it while
sibling sessions are running.
The check is ROOT-SCOPED (`$SCRATCH_WORKTREE_ROOT`, else `/tmp`), so a bare `list` is
a false PASS for a worktree created under another root.


### Step 4 — Green Phase (Run Test, Verify It Fails)

Run the test and confirm it fails for the expected reason:

```bash
npx vitest run <test-file> --reporter=verbose 2>&1 | tail -10
```

**Gate:** The test MUST fail. A test that passes before implementation is written is a false-positive test — it doesn't verify anything. If it passes:
- Check that the assertion is actually testing the new behavior
- Verify the test setup isn't accidentally providing the correct answer
- Rewrite the test

*Exception — a **pin added to an existing suite** (see the must-fail requirement below): the implementation already exists, so a green run here is the **expected** result. For that case the must-fail run is the sabotage run described below, not this one.*

**Gate — this must-fail requirement covers every new or changed assertion, not only the pre-implementation case above.** The test you just ran was written *before* the implementation. The far more common case — and the one with no pre-implementation run at all — is a **pin added to an existing suite** after the fact: the regression test for a bug you have just fixed. That assertion is never run against broken code, so it never passes the must-fail requirement, and the pipeline counts it as evidence anyway.

For that case, prove the pin by **sabotage**:

1. Revert the fix (or re-introduce the defect) in place.
2. Run the assertion. **It must fail, for the reason you expect** — not a load error, not a different assertion.
3. Restore the fix and confirm it passes.

**If Step 3.5(b) already ran this sabotage before dispatching the review, do not repeat it here** — carry the same output forward.

An assertion you cannot make fail pins nothing. It is a **vacuous pin** — worse than no test, because the pipeline counts it. Three were caught in one change in this repo; none would have been without that pass, and each looked correct on inspection.

**An equality on a value that is identical under *every* schedule cannot pin a race.** The observable must *differ* between the buggy and the fixed schedule. For a double-resolve or a torn read the settled value is the same either way, so the discriminating observable is an **operation history**: count the invocations (a `PATH` shim is enough) and assert the exact count — 2 against the bug, 1 against the fix. (The count assertion is itself a value equality; that is fine. The point is the *counted quantity* separates the schedules, while the settled value does not.)

### Step 5 — Implement (Minimal Code to Pass)

Write the minimum code that makes the test pass. No more.

- Follow the plan's task steps
- Implement only what the test requires
- Do not add abstractions, error handling, or edge cases not covered by tests

### Step 6 — Verify (Test Passes)

Run the test and confirm it passes:

```bash
npx vitest run <test-file> --reporter=verbose 2>&1 | tail -10
```

Also run related tests to catch regressions:

```bash
npx vitest run --reporter=verbose 2>&1 | tail -20
```

### Step 7 — Refactor (Optional)

After green, clean up:
- Remove duplication
- Improve names
- Simplify logic

Re-run tests after each refactor. Keep the cycle tight — refactor only what was just implemented.

### Step 8 — Report

Output a one-line summary:
```
✅ test-writing: [file] — [N] tests written, [M] surface map failure modes covered, [K] journey steps validated
```

## Handoff to code-review

The test quality self-check results are referenced by `code-review` Step 0.5 (Test Quality Review). When `code-review` scans changed test files, it checks:
- Do tests exist for changed source files? (existing Step 0)
- Do tests pass the 7-point checklist? (new Step 0.5 — this skill's checklist)
- Do tests cover the Journey Test Map steps? (if map exists)

## Integration

**Invoked by:** `executing-plans` Step 2 (Execute Batch) for test-writing task steps.

**Consumes:**
- `test-design` output (Integration Surface Map)
- Plan doc's `### Journey Test Map` section

**Consumed by:**
- `code-review` Step 0.5 (Test Quality Review)
- `verification-before-completion` (runs the tests this skill produces)

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Writing implementation before test | Red phase first — the test is the spec |
| Testing internal state instead of outcomes | Assert what the user/consumer experiences, not variable values |
| Skipping failure modes | Every surface has failure modes — test at least 2 |
| Mocking when surface map requires real | Check the surface map — if it says integration, use real Supabase |
| Test passes before implementation | False positive — the test isn't testing new behavior. Rewrite. |
| No journey reference | Tests without journey context can't be reviewed for alignment |

## Example

```typescript
// Journey: Reserve table → Step 2: Receive confirmation
// Surface: DB (bookings table), External (Resend email)
// Test layer: Integration

describe('booking confirmation', () => {
  // Happy path
  test('should create booking and send confirmation email when table is available', async () => {
    // Arrange
    const deal = await createTestDeal({ availableTables: 1 });
    
    // Act
    const result = await reserveTable(deal.id, testUser.id);
    
    // Assert — user-visible outcomes
    expect(result.status).toBe('confirmed');
    expect(result.confirmationEmailSent).toBe(true);
    expect(result.bookingCode).toMatch(/^BK-\d{6}$/);
  });

  // Failure mode 1: no tables available
  test('should return unavailable status when all tables are booked', async () => {
    const deal = await createTestDeal({ availableTables: 0 });
    const result = await reserveTable(deal.id, testUser.id);
    expect(result.status).toBe('unavailable');
    expect(result.confirmationEmailSent).toBe(false);
  });

  // Failure mode 2: double booking (concurrent)
  test('should prevent double booking of the last table', async () => {
    const deal = await createTestDeal({ availableTables: 1 });
    const [first, second] = await Promise.all([
      reserveTable(deal.id, testUser.id),
      reserveTable(deal.id, otherUser.id),
    ]);
    const confirmed = [first, second].filter(r => r.status === 'confirmed');
    expect(confirmed).toHaveLength(1); // only one gets it
  });

  // Boundary: 0 tables initially
  test('should handle deal with zero tables gracefully', async () => {
    const deal = await createTestDeal({ availableTables: 0 });
    const result = await reserveTable(deal.id, testUser.id);
    expect(result.status).toBe('unavailable');
  });
});
```
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
