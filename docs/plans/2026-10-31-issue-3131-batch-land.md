---
title: "Plan: #3131 — arm the merge queue / land merges through a gated batch branch"
type: engineering
domain: operations
doc_status: draft
subjects.team: organisation-design-team
created: 2026-10-31
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-3131, mergify, ci-main, atomic-land
---

<!-- research-path: none — in-repo references: `.mergify.yml` (tortoise), `scripts/atomic-land.sh --queue`, PR #2552, #2638, #3016 -->

# Arm the Merge Queue in agent-infra (Option A) — Implementation Plan

> **For Pi:** Use `executing-plans` to implement this plan task-by-task.

**Goal:** agent-infra lands merges through the Mergify merge queue, which validates the composition of up to `batch_size` PRs in ONE full-matrix run on the tree that will actually land — instead of paying one full cycle per PR and finding the breakage after it is already on `main`.

**Team:** organisation-design-team

**Architecture:** Nothing new is built. `scripts/atomic-land.sh --queue` already hands a PR to the queue and already falls back to the existing land path when the target repo declares no `queue_rules:` (`QUEUE-NOT-ARMED`). agent-infra is simply not armed: it has no `.mergify.yml` and the Mergify app is not installed. Option A adds the config, makes the queue branch actually run the **full matrix** (so the queue's composition run is the gate, not a symbolic one), keeps the post-merge auto-file signal `main`-only, and stops every red queue-branch run from minting a false "admin-merge carried unique failures" issue.

**Tech Stack:** GitHub Actions, Mergify config (YAML), bash test fixtures.

## Why this shape (review cycle 1, #3131)

Four reviewers killed the original "new `batch-land.py` + `git push` to main" plan as a second writer to `main` (`repo-authority.sh`), an unmodelled push shape (`review-enforcer`), a duplicate check reader (`ci-failure-set.sh` is "ONE PARSER, TWO CONSUMERS"), and a `flock` that does not exist on macOS. Option A reuses the mechanism the repo already ships and the tortoise `.mergify.yml` contract already proves.

## Decisions

| # | Decision | Rejected |
|---|----------|----------|
| A1 | **The queue is the batch mechanism.** No new land path, no new gate reader. | `scripts/batch-land.py` (cycle-1 P0s), a second `git push` to `main`. |
| A2 | **The full matrix runs on the queue branch.** `ci-main.yml` gains `mergify/merge-queue/main` to `on.push.branches`, so `merge_conditions` can name a heavy check that genuinely reports on the batch tree. | Naming a check in `merge_conditions` that the queue branch never reports → the deadlock tortoise's contract warns about. |
| A3 | **`auto-file-on-failure` is `failure() && github.ref == 'refs/heads/main'`** — verbatim, both clauses. | A bare ref condition, which *replaces* `failure()` and silences the very signal the roll-out metric reads. |
| A4 | **The detector is `main`-only.** `admin-merge-detector.yml` triggers on `workflow_run: ["CI on main"]` with no branch filter, so a queue-branch run would diff "unique failures" against `main` and file an issue claiming a SHA landed that never landed. | Leaving it — every red batch mints a false issue and Indicator 1 is met by noise. |
| A5 | **`branch_protection_injection_mode: merge`**, per the tortoise contract: entry is exactly `queue_conditions`, merge is re-checked on the batch tree. Live required set for agent-infra is `pipeline-compliance` (verified: `strict: true`, `enforce_admins: false`, `required_pull_request_reviews: null`). | The default `queue` mode, under which editing `queue_conditions` is a no-op. |
| A6 | **`batch_size: 10` for the first wave, 30 as the destination.** The number that decides this is the per-run cost, not caution: a full matrix on `main` measures **70–81 min**, and 15–26 merges/day × ~75 min is **19–32 hours of serialised matrix per day** — there is not enough wall clock in the day, which is the whole reason merges feel stuck. 30 merges in ONE 75-min run instead of 30 × 75 min is the prize, and the owner's target is 30. What actually bounds the size is the **per-PR breakage rate**: ~16 `main broken by merge` issues across ~120 merges/week ≈ **13 %**, at which a 30-batch is ~98 % likely to contain a red and would be bisected nearly every time. The first wave of 10 measures that rate; the drain backlog (36 open PRs today) makes a wave available immediately. | `batch_size: 3` (my earlier number — it copied tortoise's 4, whose "do not raise until a batch failure is measured" was a fear, not a measurement, in a repo with a different red rate); `30` on the very first wave with an unmeasured red rate. |
| A7 | **Hand-off is `atomic-land.sh --queue`**, whose fallback is the existing path, so an unarmed repo or an unreadable config degrades to today's behaviour rather than to nothing. | Wiring the queue into `admin-merge.sh` (that script is the chokepoint; it must not grow a second mode). |
| A8 | **Arming is an owner action** — the Mergify app install on `daniel-ospina/agent-infra` cannot be done from this repo, and until it lands the config is inert and `--queue` prints `QUEUE-NOT-ARMED`. | Pretending the config alone arms the queue. |

### Declared threat surface (gate code)

`<T1>` a queue run that never happens reads as green · `<T2>` a check named in `merge_conditions` that the queue branch never reports (deadlock: the queue wedges and merges stop — fail-CLOSED, but an outage) · `<T3>` a red queue-branch run files a "main broken by merge" issue or a false admin-merge-detector issue · `<T4>` the queue branch runs a *weaker* matrix than `main` (e.g. a batch PR that edits `ci-main.yml`) · `<T5>` `queue_conditions` drifting from the live required set. Tests in Task 5.

### Integration Surface Map

| Surface | Test Layer | Expected Verification |
|---------|-----------|----------------------|
| `.mergify.yml` (schema + condition lists) | contract | parses; every required context named in exactly one list; every `merge_conditions` check is one `ci-main` actually reports |
| Live required contexts vs config | contract | `gh api …/branches/main/protection` contexts ⊆ `queue_conditions ∪ merge_conditions` |
| `ci-main.yml` trigger on the queue branch | contract (YAML assertion + actionlint) | `mergify/merge-queue/main ∈ on.push.branches` |
| `ci-main.yml` concurrency | contract | group present; `cancel-in-progress` excludes `refs/heads/main` |
| `auto-file-on-failure` condition | contract | exact expression `failure() && github.ref == 'refs/heads/main'` |
| `admin-merge-detector.yml` | contract | `workflow_run.head_branch == 'main'` filter present |
| Workflow lock | contract | `scripts/workflow-lock.json` hash matches both edited workflows |
| Hand-off | integration (`tests/atomic-land/` existing suite) | `--queue` on an unarmed repo prints `QUEUE-NOT-ARMED` and still lands by the existing path |

**Files:**
- Create: `.mergify.yml`, `tests/batch-queue/run.sh`
- Modify: `.github/workflows/ci-main.yml` (`on.push.branches`, `concurrency:`, `auto-file-on-failure` `if:`), `.github/workflows/admin-merge-detector.yml` (job `if:`), `scripts/workflow-lock.json` (re-cut hashes), and the merge-duty call site (Task 4)

---

### Task 1: `.mergify.yml`

**Step 1: Write the failing test** — `tests/batch-queue/run.sh` case `mergify_contract`: parse `.mergify.yml`; assert `queue_rules[0].name == main`, `batch_size` present, `branch_protection_injection_mode == merge`, `merge_protections_settings.auto_merge_conditions == true`, and that the union of `queue_conditions`/`merge_conditions` check names contains every live required context.
**Step 2: Run — expect FAIL** (no such file).
**Step 3: Implement** the file, modelled on tortoise's contract: `queue_conditions` = `base=main`, `-draft`, `check-success=pipeline-compliance`, `check-success=ci` (the per-PR node suite); `merge_conditions` = the `ci-main` gate jobs that report on the queue branch; `merge_method: squash`; `batch_size: 3`; `batch_max_wait_time: 5 min`. Every line carries a comment naming #3131 and, where a hazard exists, the deadlock it avoids.
**Step 4: Re-run — expect PASS.**
**Step 5: Commit** `ci(mergify): arm the merge queue for main with a 3-PR batch (#3131)`

### Task 2: `ci-main.yml` — the batch gate and the `main`-only signal

**Step 1: Write the failing test** — cases `cimain_queue_trigger`, `cimain_concurrency`, `cimain_autofile_exact`: assert the trigger contains the queue branch; assert a `concurrency:` block whose `cancel-in-progress` is false for `refs/heads/main`; assert the literal expression `failure() && github.ref == 'refs/heads/main'`.
**Step 2: Run — expect FAIL.**
**Step 3: Implement** the three edits, re-cut `scripts/workflow-lock.json`, and keep the existing per-PR semantics untouched.
**Step 4: Re-run — expect PASS**, and `bash tests/actionlint/run.sh` green.
**Step 5: Commit** `ci(queue): run the full matrix on the queue branch, keep the auto-file signal main-only (#3131)`

### Task 3: `admin-merge-detector.yml` — never read a batch as a merge

**Step 1: Write the failing test** — assert the detect job carries `github.event.workflow_run.head_branch == 'main'`.
**Step 2: Run — expect FAIL.** **Step 3: Implement.** **Step 4: PASS.** **Step 5: Commit**

### Task 4: Hand-off — the merge duty asks the queue

**Step 1: Write the failing test** — extend `tests/atomic-land/` with a case: on a repo declaring `queue_rules:`, the merge duty hands off with `--queue`; on a repo without, it prints `QUEUE-NOT-ARMED` and lands by the existing path.
**Step 2: FAIL.** **Step 3: Implement** at the merge-duty call site (the lane that invokes the rail for a PR) — a `--queue` pass-through, no new logic in `admin-merge.sh`. **Step 4: PASS.** **Step 5: Commit**

### Task 5: Arm + measure (owner gate)

**Step 1:** Owner installs the **Mergify app** on `daniel-ospina/agent-infra` (the only step this repo cannot do).
**Step 2:** Confirm a queue run appears at `mergify/merge-queue/main` and that `merge_conditions` can be satisfied there (T2).
**Step 3:** First wave = **10** PRs from the current backlog (36 open, 6 conflicting — the conflicting ones are the #2552 train case). Record: `batch_size` actually formed, wall-clock, full-matrix runs paid, and the **per-PR red rate on the batch** (how many of the 10 had to be dropped).
**Step 4:** That red rate is the number that sets the steady-state size: if ≤ 10 % of PRs are bad, a 30-batch is viable and the destination is 30; if it is ~13 % (the current `main broken by merge` rate), 30 will be red nearly every time and the arrival cadence — not `batch_size` — becomes the lever (a scheduled train every N hours rather than a 5-min dwell, since at ~1 merge/hour a 5-min dwell can never assemble 30).
**Step 5:** Post the numbers on #3131 (decision relay) before the second wave.

## Risks

| Risk | Mitigation |
|------|-----------|
| A check named in `merge_conditions` never reports on the queue branch → queue wedges | Task 5 Step 2 verifies it on a real queue run before the hand-off is switched; `--queue` degrades to the existing path only on `QUEUE-NOT-ARMED`, so an armed-but-wedged queue is visible as a stall, not as a silent fallback |
| Config drift from the live required set | Task 1's test reads branch protection live; porting tortoise's `mergify_config_guard.py` is a named follow-up, not silently assumed |
| `batch_size: 3` on a repo whose composition breaks often | bisection cost is unmetered; raise only after measured green batches (A6) |
| Queue lands a batch whose matrix was weakened | T4: the queue branch's `ci-main.yml` must match `main`'s; test asserts the divergence refusal |
| Owner-arming is the critical path | everything except Task 5 lands first and is inert until arming |
