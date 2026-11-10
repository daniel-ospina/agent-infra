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
| `--o "$d"` steps | `check-single-source.sh` arg parsing | explicit `--o` already wins over `${O:-}` — but they now carry the same premise too (`unset O` + assertion), see the review round below: the guard stopped reasoning about the `--o` VALUE, because `--o "$d"` with `d=""` re-enters `${O:-}` |

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

## Review round 2 — the premise GUARD was syntactic (P1), and one posted number was wrong (P2)

A fresh-context reviewer (the harness's, at `2859a5fcc`) found the workflow change correct and the
**new guard** unsound: three measured routes certified an UNGUARDED arm as guarded. Each was
reproduced here before any fix (a mutant of the full workflow, suite unchanged):

| route | shape | pre-fix result |
|---|---|---|
| (a) body extraction | `run_body` collected only on `run: \|`, so a **single-line `run:`** yielded an empty body and the step was dropped at `audit`'s `[ -n "$body" ] \|\| continue` | `PASS 9 · FAIL 0` with an unguarded arm present |
| (b) `--o` exemption | the exemption matched `--o` with no notion of its **value**; `:155` re-enters `${O:-}` for an EMPTY `O_DIR` | `PASS 9 · FAIL 0` with an arm whose `--o "$d"` had `d=""` |
| (c) order | `grep -Fxq 'unset O'` tested PRESENCE while the header claimed "preceded by" | `PASS 9 · FAIL 0` with the unset moved below the invocation |

**Fix (all four of the reviewer's required halves):**

1. Generic `run:` extraction — `|`/`>` blocks (with `-`/`+` and indentation indicators) **and**
   single-line bodies — plus a fail-closed `UNEXTRACTABLE` finding for a step that names the checker
   but whose body cannot be read. No shape is silently skipped.
2. The `--o` exemption is **dropped**, so every invoking arm carries the premise. `unset O` is a
   no-op on an explicit-`--o` arm (measured: all 5 checker steps rc 0 with `O` unset, with
   `O=$HOME/orchestrator`, and with `O=''`), and a uniform rule has no value-shaped hole. This is
   the reviewer's sanctioned alternative, and it supersedes the "steps 3 and 5 need no change" line
   in the Wiring table above.
3. ORDER is compared (line, then column) for both the `unset` and the assertion.
4. One negative control per new shape: premised-accepted, non-invoking-not-flagged,
   comment-only-not-an-invocation, single-line (premise and assertion variants), folded `>`,
   explicit `--o`, empty `--o`, `LATE-PREMISE`, `LATE-ASSERTION`, `UNEXTRACTABLE`; the mutant
   population is now DERIVED from the workflow (and FAILS if it shrinks below 5), and a new
   order-mutant pins the ordering claim.

Non-vacuity: the rewritten suite is **24/24 on the fixed tree**, **4 failures against this branch's
pre-fix workflow** (the two now-premised `--o` arms), and each of the three routes above reds it by
name. Arm 1 now also states the population it inspected (6 named steps) and arm 4 refuses a population
that shrank below 5 invoking arms, so an extractor that stops seeing steps cannot read as a clean sweep. The two new arms' in-place assertions were re-measured live: deleting their `unset O` and
running with `O=$HOME/orchestrator` gives rc 1 with the named message.

**Finding 2 (P2, the shard count) — FALSIFIED, no change.** The comment posted "201 shards; new
suite discovered as #183" and the reviewer read the two numbers as disagreeing (claiming 182/183).
Re-measured at this head: `bash scripts/run-bash-shards.sh --list | wc -l` → **201** paths and
`... --list | grep -n harness-single-source-premise` → **183**; `--list` prints only paths, and
`tests/harness-single-source-premise/run.sh` is discovered by the `tests/*/run.sh` glob. Both numbers
reproduce exactly as posted, so the line stands.
