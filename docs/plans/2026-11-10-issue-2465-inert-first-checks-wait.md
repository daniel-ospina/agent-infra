<!-- research-path: https://github.com/daniel-ospina/agent-infra/issues/2465#issuecomment-6767232494 -->
<!-- plan-review: cycles=1, status=clean, version=2.3.0 -->

# #2465 — the FIRST-CHECKS wait must not poll a lane that cannot run for the head

**Level:** task · **Complexity:** standard · **Class:** gate-enforcement (merge rail)

## Confirmed problem

`scripts/admin-merge.sh` decides lane applicability three times and only two of them can be
reached before the wait:

1. **§0b** (`scripts/admin-merge.sh`, `# ── 0b. IS THE WATCHED LANE APPLICABLE`) measures
   `.github/workflows/<lane>` at the head through `lane_applicable`, which in
   `lane-applicable` mode answers `no-pr-trigger` when the workflow declares no
   `pull_request` / `pull_request_target` (`scripts/ci-workflow-pr-evaluable.sh:826-833`).
2. It then required **`lane_has_no_head_run "$head"`** — a second, single-shot gh read
   (`scripts/admin-merge.sh`, `lane_has_no_head_run`) — before setting `ANY_WORKFLOW=1`.
3. The **FIRST-CHECKS wait** (`wait_for_first_checks`) filters its run list on `$WORKFLOW`
   unless `ANY_WORKFLOW=1`, and its own #2862 re-derive only fires when the head already
   carries check-runs.

For a `workflow_call`-only lane the unfiltered read is a **strict superset** of the filtered
one, so step 2 could not change the outcome — but its failure (or an empty answer at t=0) left
the filter in place and the wait then polled a workflow that can never attach a run to a PR
head for the full `ADMIN_MERGE_FIRST_CHECKS_WAIT` (3900s) and refused with "no run of the lane
actually TESTED head …". Measured twice, 65 min per round: #2384 (the report) and #2513 (the
reproduction comment). `atomic-land.sh --no-wait` did not help: it skips only its own
`[2/4] verify` (`scripts/atomic-land.sh`, `wait_terminal`) and hands the head to the land step.

**Falsifier:** if `lane_applicable` never returns the structural class for a lane in this repo,
the §0b arm is dead code. Refuted by measurement — see the research comment.

## Alternatives considered

| # | Option | Why not |
|---|---|---|
| A | Attenuate `ADMIN_MERGE_FIRST_CHECKS_WAIT` when the lane is inapplicable | Hides the defect behind a shorter clock; a real fresh-PR race still needs the window. |
| B | Change the #2862 re-derive budget to "spend on outcome, not attempt" | **Reverses a recorded in-code decision** (`scripts/admin-merge.sh`: "THE BUDGET IS SPENT ON THE ATTEMPT, NOT ON THE OUTCOME", with its reason — an unreadable probe must not retry per poll) and its pinned arm (e). Not adopted. |
| C | **Refuse** instead of falling back when the lane is structurally inapplicable | Turns an inert wait into a false block on a green PR. |
| D ✅ | Classify ONCE (§0b) and let the wait consume that decision; skip the run probe for the structural class only | The issue's own suggested direction; keeps `paths-excluded` (where "did it run?" IS information) on the probe; unfiltered ⊇ filtered, and §4.5 still grades every workflow. |
| E ✅ | Carry `--no-wait` to the land step as `ADMIN_MERGE_FIRST_CHECKS_WAIT=0` | The rail has no `--no-wait` flag; its 0 seam already means "one observation, no waiting". An explicit knob in the environment still wins. |

## Integration Surface Map

| Surface | Change | Test layer |
|---|---|---|
| `admin-merge.sh` §0b decision | structural class bypasses the probe | `tests/issue-2465-inert-wait/run.sh` A(a)-(e) + mutation (f) |
| `admin-merge.sh` §0b `unknown` arm | was silent → prints reason + escape | same suite A(d) |
| `admin-merge.sh` `lane_no_pr_trigger` (new helper) | reason classifier | same suite (extraction + arms) |
| `admin-merge.sh` FIRST-CHECKS wait | **unchanged** (contract intact) | `tests/first-checks-lane-rederive/run.sh` (37 arms, re-run) |
| `atomic-land.sh` `do_land` | env carry to the land step | `tests/issue-2465-inert-wait/run.sh` B1-B5 |
| `tests/*/run.sh` discovery | new suite auto-wired by the glob (`scripts/run-bash-shards.sh:203`) | shard runner |

## Wiring

| Call site / consumer | What it does there |
|---|---|
| `main()` §0b `admin-merge.sh` | the only caller of `lane_applicable` / `lane_has_no_head_run` / (new) `lane_no_pr_trigger`; sets `ANY_WORKFLOW`, `wf_args`, `lane` |
| `wait_for_first_checks` | reads `ANY_WORKFLOW` to decide `lane_filter_active` — consumes §0b's decision, unchanged |
| `lane_run_ids`, certificate, failure-set lane | read `wf_args` / `ANY_WORKFLOW`; the same single path `--any-workflow` sets (unchanged by this fix) |
| §4.5 `check_surface_probe "\$head" "the PR's evaluated tree"` | the gate that still refuses a red on every workflow — not touched |
| `atomic-land.sh` `do_land` | invoked as `[4/4] land`; wraps the rail invocation with the carried env |
| `atomic-land.sh` `do_queue_land` | `--queue` delegates; not touched (returns before the carry) |

## Implementation steps

1. Add `lane_no_pr_trigger` + restructure the §0b `inapplicable` arm into a two-class decision
   (`STRUCTURAL` = no PR trigger at all; `NOT-RUN` = trigger exists, matched nothing, no run).
   Test: A(a) red before the change, green after; A(c) proves `paths-excluded` still probes.
2. Print the `unknown` arm's reason + the `--any-workflow` escape (it was `:` — quiet by design).
   Test: A(d) asserts the line; deleting it reds A(d).
3. Carry `--no-wait` into the land step as `ADMIN_MERGE_FIRST_CHECKS_WAIT=0`, never overriding an
   explicit knob. Test: B1-B5 against a fake land step that reports its own environment.
4. PROVE: run the new suite, the #2862 wait suite (unchanged contract) and the bash-3.2 parse guard.

## Rounds

**Rounds:** 1 (verifiers: 1, class: gate-enforcement) — `<!-- plan-review: cycles=1, status=clean, version=2.3.0 -->`

### Review Scope Contract

**Class:** gate-enforcement

**Risk surface** — what this change can break, each with the check that would catch it:

- R1 the structural class widens the lane filter for a lane that **did** run → caught by the
  superset argument + A(c) (probe still decides for `paths-excluded`) and
  `tests/first-checks-lane-rederive/run.sh` arm (b2) (drop ≡ `--any-workflow` verdict).
- R2 an unmeasurable applicability becomes an exemption (fail-open) → A(d) asserts
  `ANY_WORKFLOW` stays 0 and `wf_args` stays empty.
- R3 the fallback body silently no-ops (the `${VAR:-word}` apostrophe trap already documented
  at that site) → A(a) asserts `wf_args=--any-workflow` **and** `lane="any workflow"`, i.e. the
  state changed, not only the message; plus `bash -n` and the bash-3.2 parse guard.
- R4 `--no-wait` overrides an operator's explicit knob → B3.
- R5 the carry leaks into the default path → B2 (child sees the variable unset).
- R6 the wait's own contract (budget, stall, ceiling, §4.5) is altered as a side effect →
  the wait function is **not touched**; `tests/first-checks-lane-rederive/run.sh` re-run green.

**Threat classes** (`gate-enforcement`): `T1` fail-open by widening the merge surface — must be
impossible; the only widening is to the surface `--any-workflow` already selects, and §4.5
grades every workflow regardless. `T2` a silently-inert guard — must be impossible; A(a) is red
without the branch, and (f) rebuilds the pre-fix decision from a mutant to prove it.

**Out of scope — must NOT be raised**: the #2862 re-derive budget semantics (recorded decision);
the FIRST-CHECKS window's documented bounds; `paths-excluded` probe semantics; the `--queue`
land path; any pre-existing gh-quota behaviour.
