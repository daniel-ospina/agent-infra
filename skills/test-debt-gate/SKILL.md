---
disable-model-invocation: true
name: test-debt-gate
description: Reference for test regression gate semantics. Consumed, not invoked — classification rules, block-vs-warn, flaky re-run protocol, no-silent-pass auto-file protocol, and tech-debt pre-flight UX. Used by commit-workflow (regression gate), executing-plans, and issue-scoping.
type: reference
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
version: 1.0.0
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.


# Test-Debt Gate — Reference

Semantics for the test regression gate system. Consumed by `commit-workflow`, `executing-plans`, and `issue-scoping`. Not invoked directly by users.

## Gate Script

The canonical script is `scripts/check-test-regression.cjs`. Invoke it:

```bash
npm run check:test-regression
```

Exit codes:
- `0` — clean (no regressions)
- `1` — regression detected (at least one new failure not in baseline)
- `2` — script error (vitest not found, baseline missing/malformed, git diff failed)

## Classification Rules

The gate classifies every test failure into one of four categories:

| Category | Definition | Action |
|---|---|---|
| **Regression** | Failure not in `test-baseline.json` AND does not pass on ≤2 isolated re-runs | **BLOCK** — exit 1, refuse merge |
| **Pre-existing** | Failure already recorded in `test-baseline.json` (keyed by `file::describe > test name`) | **WARN** — requires a linked tracked issue; does not block merge |
| **Flaky** | Failure not in baseline BUT passes on ≥1 of ≤2 isolated re-runs | **WARN** — record, does not block merge |
| **Skipped** | Test timed out (>30s) or vitest reported TIMEOUT | **WARN** — record, does not block merge |
| **Coverage Gap** | Changed source file has <50% statement coverage (from `check:coverage-pruning`) | **WARN** — flag as potentially unnecessary code; does not block merge. Run `npm run check:coverage-pruning` to see gaps. |
| **Mutation Gap** | Mutation score decreased on changed files (from nightly `check:mutation` gate) | **WARN** — tests may have been weakened; does not block merge. Run `npm run check:mutation` to investigate. |
| **Architecture Violation** | Forbidden import or circular dependency detected (from `check:arch` gate) | **WARN** — architecture boundary crossed; does not block merge during silent-run period. Run `npm run check:arch:changed` to see violations. |

## Block-vs-Warn Protocol

### Regression → BLOCK

When the gate exits 1, the consuming skill MUST block the current operation (commit, merge, deployment). Output:

```
❌ Test regression detected — N new failure(s):

  src/foo.test.ts::describe > should do X
  src/bar.test.ts::should do Y

These failures are NOT tracked in test-baseline.json. Fix them before proceeding,
or if they are pre-existing (discovered late), add them to the baseline:
  npm run check:test-baseline:refresh -- --append

Baseline: npm run check:test-debt
```

### Pre-existing → WARN + require linked issue

When pre-existing failures are found, the consuming skill MUST:

1. **Warn** with the count and a link to `npm run check:test-debt`
2. **Verify** each pre-existing failure has a linked tracking issue in `test-baseline.json`
3. **If any pre-existing failure lacks an issue tag** (`issue` field missing or empty):
   - Auto-file a debt issue via `gh issue create` with:
     - Title: `Pre-existing test failure untracked: <file>`
     - Body: Template linking to the file, the test name, and a note that it was discovered by the test-debt gate
     - Labels: `bug`, `tech-debt`, `ci-failure`
   - Add the issue number to `test-baseline.json` and commit
4. **Proceed** (do not block) after verification

### Flaky → WARN

Output the flaky test name(s) and the re-run results. Suggest adding to baseline if persistent. Do not block.

### Skipped → WARN

Output the timed-out test name(s). Do not block.

### Coverage Gap → WARN

When `scripts/check-coverage-pruning.cjs` detects changed source files with <50% statement coverage, the consuming skill MUST:

1. **Warn** with the file list and coverage percentages
2. **Surface** as potentially unnecessary code — the agent should either add tests or justify the gap
3. **Proceed** (do not block) — coverage gaps are informational at this stage

Integration point: `verification-before-completion` runs `npm run check:coverage-pruning` for High-risk changes. `commit-workflow` may surface gaps but does not block on them.

### Mutation Gap → WARN

When the nightly `check:mutation` gate (StrykerJS) detects decreased mutation scores on changed files, the consuming skill MUST:

1. **Warn** with the affected files and score delta
2. **Surface** as potentially weakened tests — the agent should investigate whether new code lacks mutation-killing assertions
3. **Proceed** (do not block) — mutation gaps are informational during silent-run period

Integration point: `.github/workflows/mutation-test.yml` runs nightly. Results available as artifact. Non-blocking during 2-week silent-run period. Graduates to blocking after stabilization.

### Architecture Violation → WARN

When the `check:arch` gate (dependency-cruiser) detects forbidden imports or circular dependencies, the consuming skill MUST:

1. **Warn** with the dependency path (from → to) and rule name
2. **Surface** as architecture drift — the agent should refactor to respect boundaries or justify the exception
3. **Proceed** (do not block) — architecture violations are informational during silent-run period

Integration point: `.github/workflows/arch-check.yml` runs on PR (non-blocking). `check:arch:changed` runs faster for incremental checks. Graduates to blocking after 2-week silent-run period.

## No-Silent-Pass Protocol

A gate bypass (admin merge, manual override, `--force` flag on refresh) MUST leave a tracked artifact:

1. **Log the bypass** to `operations/logs/commit-workflow-bypass.jsonl` with:
   ```json
   {
     "ts": "<ISO-8601>",
     "skill": "commit-workflow",
     "gate_name": "test-regression",
     "trigger_phrase": "<bypass phrase or 'admin-merge'>",
     "pr_number": <N>,
     "test_regressions_blocked": <count>,
     "test_pre_existing_warned": <count>
   }
   ```

2. **Auto-file a debt issue** if the bypass skipped the gate entirely:
   ```
   Title: Test regression gate bypassed on PR #N
   Labels: bug, tech-debt, ci-failure
   Body: The test regression gate was bypassed during merge of PR #N.
         Reason: <bypass reason>
         Regressions blocked: <count>
         Pre-existing warned: <count>
         Action: Run npm run check:test-debt to review current debt.
   ```

## Tech-Debt Pre-Flight UX

When `executing-plans` or `issue-scoping` starts (consumed by #3486), surface outstanding test debt:

1. Run `npm run check:test-debt --baseline test-baseline.json` (or equivalent)
2. If pre-existing failures exist with issue tags matching the current epic/component:
   - **Warn:** "N pre-existing test failures are linked to issues in this area. Consider paying down this debt first."
   - **Offer:** "Fix these tests now? (yes/no/skip)"
3. If the user declines: record the decision and proceed
4. If the user accepts: open the relevant issues or begin fixing

## Baseline Maintenance

```bash
# View debt ledger
npm run check:test-debt

# Regenerate (only when main is fully green)
npm run check:test-baseline:refresh

# Force regenerate
npm run check:test-baseline:refresh -- --force

# Append changed-test results (incremental seeding)
npm run check:test-baseline:refresh -- --append
```

## Integration Points

| Consumer | Where | Behavior |
|---|---|---|
| `commit-workflow` 01-preflight.md | After pgTAP, before issue detection | Run gate → block on regression, warn on pre-existing, auto-file untracked |
| `commit-workflow` 04-merge-deploy.md | Admin-merge retry path | Log bypass, auto-file debt issue |
| `executing-plans` | Pre-implementation check | Surface outstanding debt, offer pay-down |
| `issue-scoping` | Phase 0 (tier check) | Surface relevant debt, suggest fixing before scoping |
| `verification-before-completion` | High-risk code verification | Run `check:coverage-pruning` + `check:arch:changed`, surface gaps (WARN) |
| `cron-quality-gates.sh` | Nightly cron / on-demand | Aggregate coverage + architecture + mutation results, alert on failures |
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
