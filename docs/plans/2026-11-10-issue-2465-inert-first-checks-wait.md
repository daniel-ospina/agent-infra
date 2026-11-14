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
2. It then required a **boolean** run probe (`lane_has_no_head_run`) — a second, single-shot
   gh read — before setting `ANY_WORKFLOW=1`. That boolean merged two different answers
   ("a run exists for this head" and "the gh read failed"), which is what this fix removes:
   the probe is three-valued (`lane_head_run_state` → `has-run` / `none` / `unreadable`), and
   each answer has its own policy per class (see R1/R7).
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
| D ✅ | Classify ONCE (§0b) and let the wait consume that decision; the probe is consulted for **EVERY** inapplicable class — `none` → widen, `has-run` → keep the lane (#1614), `unreadable` → widen **only** for `STRUCTURAL` | The issue's own suggested direction; keeps `paths-excluded` (where "did it run?" IS information) on the probe; unfiltered ⊇ filtered, and §4.5 still grades every workflow. ⛔ **NOT "skip the run probe for the structural class"** — that was the first cut, it reversed the recorded #1614 dead-end gate, and it was rejected as a review P0 (`09d19b159`). The probe is called unconditionally (`admin-merge.sh`, `lane_head_run_state` before the `case`). |
| E ✅ | Carry `--no-wait` to the land step as `ADMIN_MERGE_FIRST_CHECKS_WAIT=0` **plus the rail's dedicated `ADMIN_MERGE_FIRST_CHECKS_ONESHOT` seam** | The rail has no `--no-wait` flag; its 0 seam already means "one observation, no waiting". ⛔ The seam is CONDITIONAL on neither progress bound being set, so carrying the window alone lets an inherited `STALL`/`CEILING` re-enable the wait and bound it there (8760 s / 18064 s) — the same defect one layer down. ⛔ **Clearing those bounds is the WRONG remedy**: `ADMIN_MERGE_FIRST_CHECKS_CEILING` is also a TERM of the derived whole-attempt bound (`rail_deadline_default`) that `rail_attempt_start` ties to `ADMIN_MERGE_LOCK_TTL`, so emptying it RAISES the bound (CEILING 600 → 18064 is 3990 s → 21454 s) and a legal `LOCK_TTL=6000` is refused with exit 2 — a working land invocation turned into a hard failure by the flag that exists to stop waiting. `ONESHOT` carries the intent without touching the arithmetic. An explicit `ADMIN_MERGE_FIRST_CHECKS_WAIT` in the environment still wins. |

## Integration Surface Map

| Surface | Change | Test layer |
|---|---|---|
| `admin-merge.sh` §0b decision | the THREE-valued probe is consulted for EVERY inapplicable class; `has-run` never widens, `none` widens, `unreadable` widens only for the STRUCTURAL class | `tests/issue-2465-inert-wait/run.sh` A(a)-(e) + mutations (f)/(h); integration in `tests/admin-merge/run.sh` §#1614 arms (e) and (f) |
| `admin-merge.sh` §0b `unknown` arm | was silent → prints reason + escape | same suite A(d) |
| `admin-merge.sh` `lane_no_pr_trigger` (new helper) | reason classifier — which class §0b is in | unit: arm (a) is the attributable row, plus the single-definition guard and mutant (h) (`tests/issue-2465-inert-wait/run.sh`); integration: `tests/admin-merge/run.sh` §#1614 **arm (f)** — a `no-pr-trigger` lane whose single probe read FAILED |
| `admin-merge.sh` FIRST-CHECKS wait | `wait_enabled` gains the `ADMIN_MERGE_FIRST_CHECKS_ONESHOT` conjunct (it may disable the wait only with a zero window, and only together with the zero window — never by touching the bounds), and the `*)` refusal is re-cut so its two states do not share a verdict. The POLL/BUDGET contract (`#2862`: spent on the attempt), the stall/ceiling bounds and §4.5 are **unchanged**. | `tests/first-checks-lane-rederive/run.sh` (37 arms, re-run) for the unchanged contract; `tests/admin-merge/run.sh` §79 (g1)-(g4) for the seam; `tests/issue-2465-inert-wait/run.sh` B1-B7 and the state-keyed text arm |
| `atomic-land.sh` `do_land` | env carry to the land step | `tests/issue-2465-inert-wait/run.sh` B1-B6, `tests/admin-merge/run.sh` §79 (g1)-(g3) |
| `tests/*/run.sh` discovery | new suite auto-wired by the glob (`scripts/run-bash-shards.sh:203`) | shard runner |

## Wiring

| Call site / consumer | What it does there |
|---|---|
| `main()` §0b `admin-merge.sh` | the only caller of `lane_applicable` / `lane_head_run_state` (three-valued) / `lane_no_pr_trigger`; sets `ANY_WORKFLOW`, `wf_args`, `lane` |
| `wait_for_first_checks` | reads `ANY_WORKFLOW` to decide `lane_filter_active` — consumes §0b's decision, unchanged |
| `lane_run_ids`, certificate, failure-set lane | read `wf_args` / `ANY_WORKFLOW`; the same single path `--any-workflow` sets (unchanged by this fix) |
| §4.5 `check_surface_probe "\$head" "the PR's evaluated tree"` | the gate that still refuses a red on every workflow — not touched |
| `atomic-land.sh` `do_land` | invoked as `[4/4] land`; wraps the rail invocation with the carried env |
| `atomic-land.sh` `do_queue_land` | `--queue` delegates; not touched (returns before the carry) |

## Implementation steps

1. Add `lane_no_pr_trigger` + replace the boolean `lane_has_no_head_run` with the three-valued
   `lane_head_run_state` (`has-run` | `none` | `unreadable`), and make §0b's `inapplicable` arm
   consult it for EVERY class:
   - `has-run` → no widening, the certificate keeps the lane's name (the RECORDED #1614 gate);
   - `none` → widen, loudly (waiting cannot create a run that does not exist);
   - `unreadable` → widen only for `STRUCTURAL` (no PR trigger at all, so the filtered wait is
     inert and no run can appear while it runs — #2465's measured burn); every other class keeps
     the filter and lets §1b refuse (fail closed).
   ⛔ NOT "skip the probe for STRUCTURAL" — a first cut did that and reversed #1614 (review P0).
   Test: A(a) red before the change (against `origin/main`'s rail) and green after; A(b) the
   measured-`none` half; A(c)/A(c2) `paths-excluded` still probes; A(c3) non-structural
   `unreadable` still fails closed; **A(g) STRUCTURAL + `has-run` → NO widening**, with mutant
   (f) rebuilding the reversal to prove (g) is load-bearing. The integration proof of the #1614
   gate remains `tests/admin-merge/run.sh` §#1614 arm (e).
   ⛔ **THE CLASSIFIER MUST BE EXECUTED BY A TEST** (review P1): `lane_no_pr_trigger` decides
   whether the whole branch is reachable, and the reason string it matches is produced in a
   DIFFERENT file (`ci-workflow-pr-evaluable.sh`), so the two are coupled only by a string
   prefix. A copy of the helper emitted inside the lib's `run_s0b` used to SHADOW the extract,
   which made every arm invariant to it and left a re-spelled prefix green while #2465's burn
   came back. Now: the lib defines it exactly once (a counted guard), mutant (h) re-spells the
   prefix and reds arm (a), and `tests/admin-merge/run.sh` §#1614 arm (f) pins the same state at
   integration level (STRUCTURAL + an UNREADABLE probe → fallback fires, class named, read
   failure named, lane dropped from the certificate).
2. Print the `unknown` arm's reason + the `--any-workflow` escape (it was `:` — quiet by design).
   Test: A(d) asserts the line; deleting it reds A(d).
3. Carry `--no-wait` into the land step as `ADMIN_MERGE_FIRST_CHECKS_WAIT=0` plus
   `ADMIN_MERGE_FIRST_CHECKS_ONESHOT=1`, never overriding an explicit knob and never
   touching the `STALL`/`CEILING` bounds (they are inputs to the derived whole-attempt
   bound, so clearing them can refuse a legal `ADMIN_MERGE_LOCK_TTL`). Test: B1-B7 against a
   fake land step that reports its own environment, plus §79 (g1)-(g4) driving the real
   wait: bounds set + no seam reaches a CEILING verdict and polls; the same bounds with the
   seam take ONE observation and name `(window 0s)`; an explicit `STALL` with no seam still
   re-enables the wait; and a seam carried beside a NON-ZERO window is INERT (the bounded
   wait runs to its ceiling, so the knob cannot outrank an explicit window).
4. PROVE: run the new suite, the #2862 wait suite (unchanged contract) and the bash-3.2 parse guard.

## Rounds

**Rounds:** 1 (verifiers: 1, class: gate-enforcement) — `<!-- plan-review: cycles=1, status=clean, version=2.3.0 -->`

### Review Scope Contract

**Class:** gate-enforcement

**Risk surface** — what this change can break, each with the check that would catch it:

- R1 a structural lane that **did** run for the head loses its filter — the RECORDED #1614
  dead-end gate (`f2e84b617` / PR #1619), whose reversal would make "every trigger-split repo
  silently become `--any-workflow`" → the probe is consulted for every INAPPLICABLE class, so
  `has-run` never widens; caught by `tests/admin-merge/run.sh` §#1614 arm (e) (fixture
  UNCHANGED, green) at integration level, and by unit arm (g) in
  `tests/issue-2465-inert-wait/run.sh`, with mutant (f) proving (g) is red against the
  reversal. A(c) + `first-checks-lane-rederive` arm (b2) still cover the `paths-excluded` half.
- R2 an unmeasurable applicability becomes an exemption (fail-open) → A(d) asserts
  `ANY_WORKFLOW` stays 0 and `wf_args` stays empty.
- R3 the fallback body silently no-ops (the `${VAR:-word}` apostrophe trap already documented
  at that site) → A(a) asserts `wf_args=--any-workflow` **and** `lane="any workflow"`, i.e. the
  state changed, not only the message; plus `bash -n` and the bash-3.2 parse guard.
- R4 `--no-wait` overrides an operator's explicit knob → B3.
- R5 the carry leaks into the default path → B2 (child sees the variable unset).
- R6 the wait's own contract (budget, stall, ceiling, §4.5) is altered as a side effect →
  the poll/budget logic and its bounds are untouched (§2862's "spent on the ATTEMPT" still
  precedes the probe); what this PR does change is `wait_enabled` (the ONESHOT conjunct) and
  the `*)` refusal text, and BOTH are pinned — B1-B7 + §79 (g1)-(g4) for the seam,
  `tests/first-checks-lane-rederive/run.sh` re-run green for the contract.
- R7 the fallback text asserts a measurement the code did not take (review P2) → the STRUCTURAL
  class widens on TWO grounds (`none` and `unreadable`) and only one of them measured "no run",
  so the class text branches on the probe state; unit arm (a) asserts the `unreadable` case does
  NOT claim "the lane has NO run for head" and the certificate line was corrected the same way.
- R8 the CLASSIFIER is executed by no test (review P1) — a re-spelled reason prefix silently
  de-classifies the lane and restores the 3900 s poll with a green board → the unit suite's
  shadowing copy is gone (a counted single-definition guard), mutant (h) proves arm (a)
  discriminates on the classifier, and rail arm (f) produces the only state in which the
  classification changes the outcome (`structural + unreadable`).
- R9 the `*)` refusal asserts a measurement the code did not take (review round 4, P2) — the
  branch that decides between "the surface was read" and "the Jobs read FAILED" is keyed on
  `FIRST_CHECKS_MISSING`, which advances by `dt` in WHOLE seconds, so a sub-second poll leaves
  it at 0 while `FIRST_CHECKS_STATE` is `unobservable` and an unread Jobs API was reported as
  "NOTHING was unreadable". Reachable on exactly the `--no-wait` path this PR ships (the
  one-shot return reports `$FIRST_CHECKS_STATE` after one poll) → the branch is keyed on the
  STATE and the clock is used only to decide whether a DURATION may be quoted; the arm drives
  `block_on_first_checks` itself (extracted, no clock) with `STATE=unobservable MISSING=0` and
  asserts the unread read is named, with the `still-running MISSING=0` control asserting the
  honest branch is still reachable.

**Threat classes** (`gate-enforcement`): `T1` fail-open by widening the merge surface — must be
impossible; the only widening is to the surface `--any-workflow` already selects, and §4.5
grades every workflow regardless. `T2` a silently-inert guard — must be impossible; A(a) is red
without the branch, and (f) rebuilds the pre-fix decision from a mutant to prove it.

**Out of scope — must NOT be raised**: the #2862 re-derive budget semantics (recorded decision);
the FIRST-CHECKS window's documented bounds; `paths-excluded` probe semantics; the `--queue`
land path; any pre-existing gh-quota behaviour.

**Explicitly IN scope and defended**: the #1614 dead-end gate. A first cut of this fix reversed it
as a side effect (it skipped the probe for the structural class); the gate is now re-stated at
`scripts/admin-merge.sh` (`lane_no_pr_trigger`) and pinned by arm (e) + unit arm (g) + mutant (f),
so a future trigger-shape refactor cannot drop it silently again.
