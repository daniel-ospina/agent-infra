<!-- research-path: issue comment "<!-- research: v1 -->" on daniel-ospina/agent-infra#2726 -->
<!-- plan-review: NOT self-attested — this lane has no reviewer dispatch; the harness's fresh-context
     reviewer (merge-one.sh → record-review.sh) mints the review record at the PR head. -->

# #2726 — `harness-single-source`: make the two remaining arms hermetic

## Confirmed problem

`harness-single-source` must return the same verdict on any runner. The arm the issue names — the
`doctor` step asserting `d["deployed"]["kind"] == "absent"` — is **already fixed** on `main` by
`d3e599466` (PR #3001, 2026-10-29), exactly as the issue proposed: `kind` is now asserted against
doctor's closed vocabulary and cross-checked against what is actually on disk, with a non-vacuity arm.
Re-measured on `cmux` (the machine named in the issue's own payload): the pre-fix step exits 1 with
`AssertionError: {'path': '/home/cmux/orchestrator', 'kind': 'stamp', …}`; the post-fix step exits 0.

What the fix did **not** remove is the *class*: two other steps in the same job still read the runner's
ambient `O`, and `check-single-source.sh` takes its deployed dir from `${O:-}`
(`scripts/orchestrator-harness/check-single-source.sh:155`). On a runner that exports `O` — measured to
exist on this fleet's cell runners, 2026-10-25, `ai-runner-cell3-x64-1`/`-2` — those steps grade the
**box's deployment** and red a correct tree:

| step | with `O=$HOME/orchestrator` on `cmux` | why it is a false red |
|---|---|---|
| `canonical copy is complete` | rc 1, `FAIL: 56 divergence(s) — the harness has more than one source` | the step's name promises canonical **completeness**; canonical completeness was fine, the *deployment* diverged |
| `NON-VACUITY — checking nothing is UNKNOWN` | rc 1, `FAIL: --require-target with no target must exit 2, got 1` | the arm needs a box with nothing to compare, and `O` gave it something |

**Falsification check:** if the two steps already ignored ambient `O`, then setting `O` to a divergent
deployment would leave both at rc 0. It does not — measured rc 1 for both. Confidence: high.

## Alternatives considered

1. **Leave it; report `ALREADY_FIXED`.** Rejected: it is only fixed for the `doctor` arm. I reproduced a
   false red in the same job on the same box by exporting `O` — the configuration the fleet's cell
   runners were measured to carry. Reporting "fixed" would have recorded a false closure.
2. **Set a job-level `env: O: ''`.** Rejected — and this is why the external rung mattered: GitHub's
   `env` scopes *override* values and offer no way to **delete** a variable inherited from the runner
   service (the `env` context does not even contain runner-process variables). An empty value is not the
   same thing here: `bin/harness:297` resolves `O_DIR="${O:-$HOME/orchestrator}"`, so `O=''` would flip
   the `doctor` arm onto `$HOME/orchestrator`. That silently changes an arm this change must not touch.
3. **`unset O` in each of the two offending steps, plus an in-place assertion of the premise.** Chosen:
   it is the issue's own proposal ("a hermetic premise … instead of relying on the runner's ambient
   state"), it is scoped to the two steps that mis-grade, and the assertion converts a future regression
   from a *misleading count* into a *named* failure at the point of the edit.

## Complexity + domains

`Level: task`, complexity **standard** (workflow change on a merge-gating check; one file, but its
verdict gates merges). Domains: `ops-infra` / gate-enforcement-adjacent — the changed code is an
assertion set, not an enforcer, so no adversarial threat surface is declared.

## Integration Surface Map

| surface | layer | evidence |
|---|---|---|
| `.github/workflows/harness-single-source.yml` (2 steps) | local execution of the step bodies, both env configurations | step-body runs below |
| `scripts/orchestrator-harness/check-single-source.sh` (consumer of `O`) | unchanged; exercised through the steps | steps 3–6 unchanged and green |
| `scripts/check-workflow-lock.mjs` (`UNLOCKED_WORKFLOWS` classification) | repo check | `node scripts/check-workflow-lock.mjs` |
| `tests/actionlint`, `tests/ci-trigger-scope`, `tests/workflow-bounds` | repo suites that read this workflow | all green |

## Research

Pointer: the `<!-- research: v1 -->` comment on #2726. Decisions it supports: that the `O` mechanism is
real (`check-single-source.sh:155`), that the `doctor` arm is already fixed (`d3e599466`), and that a
job-level `env:` cannot substitute for an `unset`.

## Wiring

| thing touched | call site / consumer | what it does there |
|---|---|---|
| `unset O` (step 2) | `check-single-source.sh:155` → `:331` | without it, `${O:-}` names the box's deployment and the arm byte-compares it instead of grading canonical completeness |
| `unset O` (step 6) | `check-single-source.sh:155` → `:383` | without it, `--require-target` finds the ambient target and exits 1 (DIVERGENCE) where the arm requires 2 (UNKNOWN) |
| the premise assertion | the same two steps | names a dropped `unset` in place, instead of redding later with a misleading divergence count |
| `--o "$d"` steps (unchanged) | `check-single-source.sh` arg parsing | explicit `--o` already wins over `${O:-}`, so steps 3 and 5 are hermetic by construction — no change needed |

## Implementation steps

1. Add `unset O` + premise assertion to `canonical copy is complete` — proved by running the step body
   with `O` set (rc 0) and with `O` unset (rc 0), and the pre-fix body with `O` set (rc 1).
2. Same for `NON-VACUITY — checking nothing is UNKNOWN` — same four runs.
3. Prove the guard is not decoration: delete `unset O` from each new body, re-run with `O` set, require
   the named `FAIL: O is still set …`.
4. Prove step 6 is still a real arm: drop `--require-target`, assert rc 0, require the arm to red.
5. Repo gates: YAML parse, `check-workflow-lock.mjs`, `tests/actionlint`, `tests/ci-trigger-scope`,
   `tests/workflow-bounds`.

## Rounds

**Rounds:** 1 (verifiers: 1, class: protocol)

### Review Scope Contract

**Class:** protocol

**Risk surface** — what this change can break, each with the check that would catch it:

- R1 `unset O` makes an arm stop grading the deployment where grading it was intended → the deployed-byte
  arms are the separate `--o "$d"` steps (unchanged, still green), and step 5 still refuses a planted
  divergent copy.
- R2 the guarded step becomes vacuous — it passes because it now checks less → step 6's arm strength is
  re-proved by dropping `--require-target` and requiring a red (`FAIL: … must exit 2, got 0`).
- R3 a future edit drops `unset O` and the arm silently mis-grades again → the in-place
  `[ -z "${O:-}" ]` assertion, measured to fire with the named message when `unset O` is removed.
- R4 the workflow stops being valid / loses its classification → YAML parse, `check-workflow-lock.mjs`,
  `tests/actionlint`, `tests/ci-trigger-scope`, `tests/workflow-bounds`.

**Threat classes:** (not adversarial) — no enforcer or bypass surface is changed; the edit adds two
`unset`s and two assertions inside steps that already existed.

**Out of scope — must NOT be raised** (note, file, do not chase):

- pre-existing defects outside the diff · style/prose preference with no behaviour change;
- the `doctor` arm's own non-vacuity strength on a *bare* runner — already filed as agent-infra#3045,
  and this change deliberately does not touch that step;
- #2735's secondary finding that a `pull_request`-only check has no base counterpart for the merge rail
  to adjudicate — that is a rail-side question, named there, not here.

**Acceptance:** every `R<n>` has its named evidence, and no open item remains on the declared surface.
