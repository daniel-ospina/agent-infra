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

> ## ⚠ STATUS — read before the tasks (updated 2026-10-31 11:40Z)
>
> **This PR (#3139) ships the GATE half only: the batch branch runs the full matrix.** The batch is
> assembled as an `integration/batch-*` branch and landed through `atomic-land.sh`; that is what
> `ci-main.yml` gains a trigger for. **The Mergify queue half is NOT in this PR** — no `.mergify.yml`,
> no `tests/batch-queue/run.sh`, no `mergify/merge-queue/*` trigger, no hand-off. Tasks 1, 4 and 5, the
> queue-branch trigger in Task 2, and `A5`/`A6`/`A7`/`A8` below are **DEFERRED** to the queue follow-up on
> #3131, where they are inert until an owner arms the app (A8). `A6` is listed with them on purpose:
> `batch_size` sizes a QUEUE batch, so the measurement it prescribes needs the queue armed — the
> agent-assembled integration branch this PR does ship has no `batch_size` and lands one tree at a time.
>
> What this means for the rest of the doc: any sentence that describes the batch branch as
> `mergify/merge-queue/main`, or that would have a test assert that branch name, describes the DEFERRED
> half, not this PR. The shipped trigger is `branches: [main, 'integration/**']`.
>
> **Method note (the batch is agent-assembled, not queue-assembled):** a constituent is eligible for the
> batch only with a clean review recorded at its LIVE head (`~/.pi/agent/reviews/<owner>-<repo>-<N>.json`,
> `head_sha` == live `headRefOid`); a PR's own CI is not the gate. Verdicts: `BATCH-GREEN`,
> `BATCH-GREEN(BASELINE(ids))`, `BATCH-RED(ids)`. A culprit is DROPPED from the batch, never fixed inside
> it. Owner doctrine: tortoise#10399 - stated there in full, and written up in the TORTOISE repo's
> `docs/ops/batch-integration.md`, which lands with tortoise PR #10400 (that path does not exist on
> tortoise `main` yet, so the issue comment is the durable copy).

> **For Pi:** Use `executing-plans` to implement this plan task-by-task.

**Goal:** agent-infra lands merges through the Mergify merge queue, which validates the composition of up to `batch_size` PRs in ONE full-matrix run on the tree that will actually land — instead of paying one full cycle per PR and finding the breakage after it is already on `main`.

**Team:** organisation-design-team

**Architecture:** Nothing new is built. `scripts/atomic-land.sh --queue` already hands a PR to the queue and already falls back to the existing land path when the target repo declares no `queue_rules:` (`QUEUE-NOT-ARMED`). agent-infra is simply not armed: it has no `.mergify.yml` and the Mergify app is not installed. Option A adds the config, makes the queue branch actually run the **full matrix** (so the queue's composition run is the gate, not a symbolic one), keeps the post-merge auto-file signal `main`-only, and stops every red queue-branch run from minting a false "admin-merge carried unique failures" issue. **In THIS PR only the gate half ships** (`on.push.branches` gains `integration/**`, the auto-file signal and the detector stay `main`-only) — see STATUS.

**Tech Stack:** GitHub Actions, Mergify config (YAML), bash test fixtures.

## Why this shape (review cycle 1, #3131)

Four reviewers killed the original "new `batch-land.py` + `git push` to main" plan as a second writer to `main` (`repo-authority.sh`), an unmodelled push shape (`review-enforcer`), a duplicate check reader (`ci-failure-set.sh` is "ONE PARSER, TWO CONSUMERS"), and a `flock` that does not exist on macOS. Option A reuses the mechanism the repo already ships and the tortoise `.mergify.yml` contract already proves.

## Decisions

| # | Decision | Rejected |
|---|----------|----------|
| A1 | **The queue is the batch mechanism.** No new land path, no new gate reader. | `scripts/batch-land.py` (cycle-1 P0s), a second `git push` to `main`. |
| A2 | **The full matrix runs on the BATCH branch, not only on `main`.** `ci-main.yml` gains `integration/**` to `on.push.branches` (owner-recorded shape: `branches: [main, 'integration/**']`), so the branch a batch lands from is itself gated by the full matrix. The queue half would add `mergify/merge-queue/main` to the same list; that is DEFERRED (see STATUS) and is why no test in this PR asserts a queue-branch name. | Naming a check in `merge_conditions` that the batch branch never reports → the deadlock tortoise's contract warns about. |
| A3 | **`auto-file-on-failure` is `failure() && github.ref == 'refs/heads/main'`** — verbatim, both clauses. `failure()` is load-bearing because the filer derives the failing set from `needs` and files EVEN WHEN that set is empty (bare title `main broken by merge`, `Failing jobs: unknown`): a bare ref condition therefore makes the job run on every push to `main` and file a FALSE issue on every GREEN one. The ref clause is load-bearing for the other direction: it keeps an `integration/**` matrix failure — a tree that never reached `main` — from being filed as "main broken by merge". | A bare ref condition (files false issues on green pushes); dropping the ref clause (files integration-branch failures as main breakages). |
| A4 | **The detector is `main`-only, filtered on the TRIGGER.** `admin-merge-detector.yml` triggers on `workflow_run: ["CI on main"]` plus `branches: [main]`, so an `integration/**` (or queue-branch) run cannot diff "unique failures" against `main` and file an issue claiming a SHA landed that never landed. The filter belongs on the trigger, NOT a job `if:` — a job `if:` also gates the documented `workflow_dispatch` path, which carries no `workflow_run` payload, and would silently skip it. | Leaving it unfiltered — every red batch mints a false issue and Indicator 1 is met by noise. A job-level `if:` (skips `workflow_dispatch`). |
| A5 | **`branch_protection_injection_mode: merge`**, per the tortoise contract: entry is exactly `queue_conditions`, merge is re-checked on the batch tree. Live required set for agent-infra is `pipeline-compliance` (verified: `strict: true`, `enforce_admins: false`, `required_pull_request_reviews: null`). | The default `queue` mode, under which editing `queue_conditions` is a no-op. |
| A6 | **`batch_size: 10` for the first wave, 30 as the destination.** The number that decides this is the per-run cost, not caution: a full matrix on `main` measures **70–81 min**, and 15–26 merges/day × ~75 min is **19–32 hours of serialised matrix per day** — there is not enough wall clock in the day, which is the whole reason merges feel stuck. 30 merges in ONE 75-min run instead of 30 × 75 min is the prize, and the owner's target is 30. What actually bounds the size is the **per-PR breakage rate**, and three DIFFERENT measurements must not be
confused. In the 4 weeks to 2026-10-31, on `main` (one snapshot at 2026-10-31T11:49Z, all counts from the same window):
**514 `CI on main` runs** over **513 distinct head shas**, of which **338 failed / 138 succeeded** — **71 % of
completed runs are red**, a PERSISTENCE figure that says main is red most of the time, not that most merges break
it; **11 green→red flips** across those 513 pushes ≈ **2.1 % per push**; **16 `main broken by merge` issues
over 513 commits** ≈ **3.1 % per commit** (~4.7 % of the 338 red runs, which is what the issue filer's dedup
shapes — a same-set recurrence appends to the open issue rather than filing another). The number that sizes a batch
is the per-PR cause rate, i.e. **2–3 %**: a 10-batch is then **~18–26 %** likely to contain a culprit and a
30-batch **~45–60 %**, which is exactly why the first wave is 10 and why the destination 30 is *measured* before
it is adopted. There is no 13 % figure in the record — an earlier revision of this row asserted one without a
derivation, and it is withdrawn. The first wave of 10 measures that rate; the drain backlog (36 open PRs today) makes a wave available immediately. | `batch_size: 3` (my earlier number — it copied tortoise's 4, whose "do not raise until a batch failure is measured" was a fear, not a measurement, in a repo with a different red rate); `30` on the very first wave with an unmeasured red rate. |
| A7 | **Hand-off is `atomic-land.sh --queue`**, whose fallback is the existing path, so an unarmed repo or an unreadable config degrades to today's behaviour rather than to nothing. | Wiring the queue into `admin-merge.sh` (that script is the chokepoint; it must not grow a second mode). |
| A8 | **Arming is an owner action** — the Mergify app install on `daniel-ospina/agent-infra` cannot be done from this repo, and until it lands the config is inert and `--queue` prints `QUEUE-NOT-ARMED`. | Pretending the config alone arms the queue. |

### Declared threat surface (gate code)

`<T1>` a queue run that never happens reads as green · `<T2>` a check named in `merge_conditions` that the queue branch never reports (deadlock: the queue wedges and merges stop — fail-CLOSED, but an outage) · `<T3>` a red queue-branch run files a "main broken by merge" issue or a false admin-merge-detector issue · `<T4>` the queue branch runs a *weaker* matrix than `main` (e.g. a batch PR that edits `ci-main.yml`) · `<T5>` `queue_conditions` drifting from the live required set. Tests in Task 5.

### Integration Surface Map

| Surface | Test Layer | Expected Verification |
|---------|-----------|----------------------|
| `.mergify.yml` (schema + condition lists) | contract | parses; every required context named in exactly one list; every `merge_conditions` check is one `ci-main` actually reports |
| Live required contexts vs config | contract | `gh api …/branches/main/protection` contexts ⊆ `queue_conditions ∪ merge_conditions` |
| `ci-main.yml` trigger on the batch branch | contract (YAML assertion + actionlint) | `'integration/**' ∈ on.push.branches` (the queue-branch name is the DEFERRED half — see STATUS) |
| `ci-main.yml` concurrency | contract | `check-workflow-concurrency.sh` passes on the file: no `cancel-in-progress: true` anywhere and no JOB-level block (a workflow-level block with the literal `false` is permitted, but this workflow ships WITHOUT one — a group here would cancel the very matrix the queue waits on) |
| `auto-file-on-failure` condition | contract | exact expression `failure() && github.ref == 'refs/heads/main'` |
| `admin-merge-detector.yml` | contract | the main-only filter is the TRIGGER's `on.workflow_run.branches: [main]` — a job-level `if:` would silently skip the documented `workflow_dispatch` path (see Task 3) |
| Workflow lock | contract | `scripts/workflow-lock.json` matches the workflows it COVERS — the lock lists
`ci.yml`, `node-ci.yml` and `ci-main.yml` only, so the detector is NOT lock-covered (its drift control is
`sync-ci-workflows.sh`, which requires `templates/.github/workflows/admin-merge-detector.yml` to stay
byte-identical to the live copy) |
| Hand-off | integration (`tests/atomic-land/` existing suite) | `--queue` on an unarmed repo prints `QUEUE-NOT-ARMED` and still lands by the existing path |

**Files:**
- Create: `.mergify.yml`, `tests/batch-queue/run.sh`
- Modify: `.github/workflows/ci-main.yml` (`on.push.branches`, `auto-file-on-failure` `if:` — and deliberately NO `concurrency:` block), `.github/workflows/admin-merge-detector.yml` **and its SOURCE** `templates/.github/workflows/admin-merge-detector.yml` (the two are byte-identical, enforced by `sync-ci-workflows.sh`; the main-only filter is the trigger's `workflow_run.branches:`, never a job `if:`), `scripts/workflow-lock.json` (re-cut hashes), and the merge-duty call site (Task 4)

---

### Task 1: `.mergify.yml`

**Step 1: Write the failing test** — `tests/batch-queue/run.sh` case `mergify_contract`: parse `.mergify.yml`; assert `queue_rules[0].name == main`, `batch_size` present, `branch_protection_injection_mode == merge`, `merge_protections_settings.auto_merge_conditions == true`, and that the union of `queue_conditions`/`merge_conditions` check names contains every live required context.
**Step 2: Run — expect FAIL** (no such file).
**Step 3: Implement** the file, modelled on tortoise's contract: `queue_conditions` = `base=main`, `-draft`, `check-success=pipeline-compliance`, `check-success=ci` (the per-PR node suite); `merge_conditions` = the `ci-main` gate jobs that report on the queue branch; `merge_method: squash`; `batch_size: 10` (A6 — the first-wave number; the per-run cost is what bounds it, not caution); `batch_max_wait_time: 5 min`. Every line carries a comment naming #3131 and, where a hazard exists, the deadlock it avoids.
**Step 4: Re-run — expect PASS.**
**Step 5: Commit** `ci(mergify): arm the merge queue for main with a 10-PR batch (#3131)`

### Task 2: `ci-main.yml` — the batch gate and the `main`-only signal

**Step 1: Write the failing test** — cases `cimain_batch_trigger`, `cimain_concurrency`, `cimain_autofile_exact`: assert the trigger contains `'integration/**'` (NOT a queue-branch name — that is the DEFERRED half); assert `check-workflow-concurrency.sh` PASSES on the file as shipped, which is the accurate statement of the repo's rule — R2 refuses `cancel-in-progress: true` and any non-literal value, and R0 refuses a JOB-level block, while a workflow-level block with the literal `false` is permitted; this workflow simply ships without one, because a `concurrency:` group on ci-main would cancel the very matrix the batch is waiting on. Do NOT assert that a `concurrency:` block is refused — it is not, and such a test would go red the moment a literal-`false` block is added legitimately; assert the literal expression `failure() && github.ref == 'refs/heads/main'` for the auto-file job, and assert the detector's main-only filter is the TRIGGER's `workflow_run.branches: [main]`.
**Step 2: Run — expect FAIL.**
**Step 3: Implement** the three edits, re-cut `scripts/workflow-lock.json`, and keep the existing per-PR semantics untouched.
**Step 4: Re-run — expect PASS**, and `bash tests/actionlint/run.sh` green.
**Step 5: Commit** `ci(batch): run the full matrix on the batch branch, keep the auto-file signal main-only (#3131)`

### Task 3: `admin-merge-detector.yml` — never read a batch as a merge

**Step 1: Write the failing test** — assert the workflow's TRIGGER carries `on.workflow_run.branches: [main]`. The main-only filter belongs on the trigger, NOT on a job `if:`: a job-level `if:` also gates the documented `workflow_dispatch` path (which carries no `workflow_run` payload) and would silently skip it, so the shipped file states that reason in its own comment.
**Step 2: Run — expect FAIL.** **Step 3: Implement.** **Step 4: PASS.** **Step 5: Commit**

### Task 4: Hand-off — the merge duty asks the queue

**Step 1: Write the failing test** — extend `tests/atomic-land/` with a case: on a repo declaring `queue_rules:`, the merge duty hands off with `--queue`; on a repo without, it prints `QUEUE-NOT-ARMED` and lands by the existing path.
**Step 2: FAIL.** **Step 3: Implement** at the merge-duty call site (the lane that invokes the rail for a PR) — a `--queue` pass-through, no new logic in `admin-merge.sh`. **Step 4: PASS.** **Step 5: Commit**

### Task 5: Arm + measure (owner gate)

**Step 1:** Owner installs the **Mergify app** on `daniel-ospina/agent-infra` (the only step this repo cannot do).
**Step 2:** Confirm a queue run appears at `mergify/merge-queue/main` and that `merge_conditions` can be satisfied there (T2).
**Step 3:** First wave = **10** PRs from the current backlog (36 open, 6 conflicting — the conflicting ones are the #2552 train case). Record: `batch_size` actually formed, wall-clock, full-matrix runs paid, and the **per-PR red rate on the batch** (how many of the 10 had to be dropped).
**Step 4:** That red rate is the number that sets the steady-state size: if ≤ 10 % of PRs are bad, a 30-batch is viable and the destination is 30; if it is in the 2–3 % band A6 measured (green→red flips, and issues per commit), a 30-batch is ~45–60 % likely to contain a culprit — tolerable only because bisection is automated; if the wave measures materially higher, 30 will be red nearly every time and the arrival cadence — not `batch_size` — becomes the lever (a scheduled train every N hours rather than a 5-min dwell, since at ~1 merge/hour a 5-min dwell can never assemble 30).
**Step 5:** Post the numbers on #3131 (decision relay) before the second wave.

## Risks

| Risk | Mitigation |
|------|-----------|
| A check named in `merge_conditions` never reports on the queue branch → queue wedges | Task 5 Step 2 verifies it on a real queue run before the hand-off is switched; `--queue` degrades to the existing path only on `QUEUE-NOT-ARMED`, so an armed-but-wedged queue is visible as a stall, not as a silent fallback |
| Config drift from the live required set | Task 1's test reads branch protection live; porting tortoise's `mergify_config_guard.py` is a named follow-up, not silently assumed |
| `batch_size: 10` on a repo whose composition breaks often | bisection cost is unmetered; the first wave of 10 MEASURES the per-PR breakage rate, and the size is raised only on that measurement (A6) |
| Queue lands a batch whose matrix was weakened | T4: the queue branch's `ci-main.yml` must match `main`'s; test asserts the divergence refusal |
| Owner-arming is the critical path | everything except Task 5 lands first and is inert until arming |
