---
title: "#665 — review-loop hard cap is per-reviewer but every cycle uses a fresh reviewer — Scope & Plan"
type: engineering
domain: operations
doc_status: draft
subjects.team: organisation-design-team
created: 2026-09-10
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-665, issue-676, issue-677
---

<!-- research-path: none — the defect, its evidence, and the mechanism are entirely in-repo
     (AGENTS.md §Review Loop Protocol + docs/plans/2026-09-09-issue-637-pi-pin-bump.md). -->

# #665 — make the review-loop budget loop-level, not per-reviewer

## Confirmed Problem

`AGENTS.md` stated two rules that cancel each other:

> **Hard Cap:** 4 cycles maximum per reviewer (unless skill specifies otherwise). On cap → document remaining issues, post with `⚠️ capped at N cycles — M issues remain`, proceed.

> Every review cycle MUST dispatch a FRESH `task` sub-agent.

The cap counted **per reviewer**; the protocol mandates a **fresh** reviewer every cycle. A fresh
reviewer is never the same reviewer twice, so the counter never tripped. On the #637 session the
code-review gate ran **10 cycles** and the issue-scoping parallel gate ran **5**, with no cycle ever
reaching a cap.

Each cycle found something real, which is why the loop kept going — but the *classes* were not
equivalent:

| cycles | finding class | surface |
|---|---|---|
| 1–4 | wrong class guarded, vacuous assertions, requirement rewriting | code + docs |
| 5–7 | YAML quoting/spacing re-opened the same bypasses; false-REDs | one test file |
| 8–10 | deliberately crafted decoys (fake job in a block scalar, dead step carrying the expected text) | one test file |

Cycles 8–10 were re-deriving **one accepted bound** — "a same-commit crafted decoy is the same class
as deleting the guard; branch protection owns it (#646)". The loop could not notice, because "fresh
reviewer, never re-report" is exactly what the protocol mandated: a fresh reviewer has no memory that
the bound was accepted, so it re-reported it at a new severity and the loop restarted.

Two secondary defects in the same run:

- The Review Cycle Log accumulated **two different cycles both numbered "5"** (a code-review cycle and
  a parallel-review-gate cycle), was not read in cycle order (cycle 8's fix-round section precedes
  cycle 7's), and one cross-reference (`see fix round 7` on the cycle-6 row) resolved to a heading
  that had been appended after the row rather than before it. Numbering was per-gate but the log is
  read as one table.
- The cycle count was recorded nowhere machine-readable, so the cap could not be checked by anything
  except the agent's own recollection.

**Scope note:** the issue-scoping ceremony for #665 is owned by the controller session (a scoping
comment on #665 must not be forged by this implementation session). This doc is the implementation
contract; gate results are appended below as they run.

## Verification Gates

Pending — `plan-review`, the parallel review gates, and `code-review` run after this doc is saved.
See §Review Cycle Log for the machine-readable record.

## Plan

### Proposed solution

Five changes, one per required outcome. Nothing here removes the fresh-context reviewer rule — it is
load-bearing against confirmation bias and stays untouched.

**(1) Loop-level budget in `AGENTS.md` §Review Loop Protocol.** The `#### Hard Cap` section is
replaced by `#### Loop Budget — counted across fresh dispatches, NOT per reviewer`. The budget counts
every dispatch for one gate, starting at the gate's first dispatch; the default is **4 cycles per
gate**; the "on cap → document remaining issues, post `⚠️ capped at N cycles — M issues remain`,
proceed" semantics are preserved verbatim. The section states explicitly that dispatching a fresh
reviewer does **not** reset, extend, or replenish the budget, and the FORBIDDEN list gains
"❌ Treat a fresh dispatch as a budget reset".

Verbatim (the load-bearing paragraph):

> **Dispatching a fresh reviewer does NOT reset, extend, or replenish the budget.** The fresh-context
> rule exists to defeat confirmation bias, not to hand the loop a new counter. A gate that has
> dispatched 4 cycles has spent its budget no matter how many distinct reviewer processes were
> involved — a fresh reviewer is a new *reviewer*, never a new *loop*.

**(2) Convergence criterion — Accepted Bounds.** New `#### Convergence — Accepted Bounds` section. The
orchestrator maintains a running Accepted-bounds list in the artifact under review (plan doc / PR body
/ review comment): `id`, the bound, why it is accepted, and the owner that covers it. Every fresh
reviewer prompt carries the list verbatim with the `BOUND-CHALLENGE: <id>` instruction. A cycle whose
findings are all recorded bounds, or new variants of them, produces **no new class** → the loop has
converged, `converged (no new class)` is logged, no further dispatch happens, and **the cycle does not
extend the budget**. A `BOUND-CHALLENGE` is the only way a recorded bound re-enters the loop.

Verbatim (the reviewer-prompt instruction, injected into every fresh dispatch):

> The bounds below were examined and accepted. Do NOT report a defect that is an instance of one of
> them, and do NOT re-report it as a new finding. Report only a finding that is NOT a recorded bound.
> If you believe a recorded bound is wrong, say so explicitly and label it `BOUND-CHALLENGE: <id>`.

The skill files that dispatch reviewers carry the same mechanism written for their own loop shape:
`skills/issue-scoping/SKILL.md` (Phase 2.5/5.5 verification gates + Phase 7 gate loop),
`skills/plan-review/SKILL.md` (Phase 1 prompt + Phase 4 gate loop), `skills/code-review/SKILL.md`
(Gate Loop + `--re-review` step + `cycle-status.yaml`), `skills/test-review/SKILL.md` (Phase 1 prompt +
Phase 4 gate loop).

Skill-specific budgets are now stated as loop-level totals: issue-scoping 4 per verification gate,
code-review 4 per gate, test-review 3 (its own file and `code-review` Step 0.5 already advertised 3 —
the body's "hard cap: 10" was an internal contradiction, resolved in favour of 3), plan-review keeps
its risk-tier table (3 / 5 / 8) and is now explicitly labelled a loop-level budget. The old "no hard
cap / safety cap at 10 cycles" text is removed from all four.

**(3) Cycle-log numbering + cross-reference resolution.** New `#### Cycle Log — numbering +
machine-readable record` section in AGENTS.md. A cycle's identity is `<gate>#<n>`; within one gate `n`
is unique and strictly increasing down the table; two gates may each own a cycle 1 (that is not a
duplicate — the #637 ambiguity was the *unqualified* reference, not the shared number); every
cross-reference must be gate-qualified and must resolve to a `### Fix round — <gate> cycle <n>`
heading in the same artifact; a bare `see fix round 6` is malformed; the table header is exactly
`| Gate | Cycle | Result |`.

**(4) Machine-readable cycle count.** Every artifact with a cycle log carries a `review-cycles` record:

```
<!-- review-cycles
cap: 4
code-review: 4
plan-review: 6 cap=8
-->
```

`cap:` is the loop budget (default 4) and a gate may carry `cap=<n>` to override it — which is how plan-review's risk tiers (3 / 5 / 8) coexist with the 4-cycle default in one log; `<gate>: <n>` records the gate's total dispatched cycles; a trailing `capped` marks a loop that ended at the budget with issues remaining and requires the
`⚠️ capped at N cycles — M issues remain` line in the artifact. The recorded count must equal the
table's row count and every table gate must be recorded (a gate may be recorded at `0` before its
first dispatch).

**(5) The check.** `scripts/check-review-cycle-log.mjs` + `scripts/check-review-cycle-log.test.mjs` +
`scripts/review-cycle-log-baseline.txt` enforce (3) and (4). Rules R0–R7 (see §Check design). Legacy
logs are exempted through a **stale-detecting** baseline: an entry that no longer exists, no longer
carries a cycle log, or now passes fully fails the check, so the exemption cannot rot silently
(retrofit tracked by #677).

### Check design

| Rule | What it enforces | Failure message anchor |
|---|---|---|
| R0 | record **and** conforming table, or neither | ``no `<!-- review-cycles … -->` record`` |
| R1 | record syntax (`cap:` int; `<gate>: <int> [capped] [cap=<int>]`) | ``must be `<int>` (optionally suffixed `capped` and/or `cap=<int>`)`` |
| R2 | recorded count == gate row count; table gates ⊆ record gates | `record says <gate>: N but the table has M row(s)` |
| R3 | no duplicate `<gate>#<n>` | `duplicate cycle number` |
| R4 | strictly increasing cycle numbers within a gate | `not strictly increasing` |
| R5 | no gate over its effective `cap` (per-gate `cap=` else record `cap:`); `capped` ⇒ count == cap ∧ `⚠️ capped…` line | `over the loop budget (cap: N)` |
| R6 | every `see fix round …` is gate-qualified and resolves | `is not gate-qualified` / `has no matching` |
| R7 | every fix-round heading is gate-qualified and has a row | `which has no row in the cycle log` |

A doc is in scope only when it carries the convention's shape — the `## Review Cycle Log` heading, a
`| Gate | Cycle | Result |` table, or a `review-cycles` record. Fenced code blocks are masked, so the
convention's own examples never count as a real record. Four legacy docs (below) are baselined.

### Files changed

| File | Change |
|---|---|
| `AGENTS.md` | §Review Loop Protocol only: `#### Hard Cap` → `#### Loop Budget`; new `#### Convergence — Accepted Bounds`; new `#### Cycle Log — numbering + machine-readable record`; exit conditions + FORBIDDEN updated |
| `skills/issue-scoping/SKILL.md` | Phase 2.5 gate mechanics, Phase 5.5 reference, Phase 7 gate loop: loop budget + accepted bounds |
| `skills/plan-review/SKILL.md` | header summary, Proportional Review Cycles note, Phase 1 prompt, Phase 4 gate loop, cycle-status YAML, announce line |
| `skills/code-review/SKILL.md` | fixer config line, re-review step, Gate Loop exit conditions/budget/convergence, cycle-status YAML |
| `skills/test-review/SKILL.md` | review-cycle diagram, Phase 1 prompt, Phase 4 gate loop (10 → 3, loop-level), integration pattern line |
| `scripts/check-review-cycle-log.mjs` | new checker (R0–R7) |
| `scripts/check-review-cycle-log.test.mjs` | new fixture suite (32 cases, RED/GREEN per rule) |
| `scripts/review-cycle-log-baseline.txt` | new stale-detecting baseline (4 legacy docs) |
| `.github/workflows/ci.yml` | new `review-cycle-log` job (checker over repo docs + fixture suite) |
| `.github/workflows/ci-main.yml` | same two commands in the post-merge `extension-tests` accumulator |
| `docs/plans/2026-09-10-issue-665-review-loop-cap.md` | this doc |

### Verification plan

| Surface | Layer | Command | Expected |
|---|---|---|---|
| skill text | unit | `grep -n "Loop budget"` over the 4 skills + AGENTS.md | every reviewing skill states a loop-level budget and what happens at cap |
| cycle log | unit | `node scripts/check-review-cycle-log.mjs` | exit 0 on the current tree; RED on a planted malformed/duplicate-numbered log |
| cycle-log fixtures | unit | `node scripts/check-review-cycle-log.test.mjs` | 32/32 — every rule has a RED case and a GREEN case |
| skills (regression) | unit | `node scripts/check-skill-lint.test.mjs` | 163/163 — includes guard (j), which asserts `ci.yml`'s `test-command` is EXACTLY `node scripts/check-skill-lint.test.mjs` (so the new job is a separate job, never a suffix on that input) |
| skills (oracle) | unit | `node scripts/check-skill-lint.oracle.test.mjs` | 146/146 clean |
| workflows | unit | `bash scripts/check-workflow-actionlint.sh` | exit 0 |
| CI refs | unit | `node scripts/ci-ref-check.test.mjs` | 183/183 |
| reviewer prompt | manual | inject the Accepted-bounds list into a fresh reviewer | a recorded bound is not re-reported as a new defect |
| budget | manual | simulate a loop to the budget | `⚠️ capped at N cycles — M issues remain` is emitted; `capped` in the record requires it |

### Acceptance criteria

1. `AGENTS.md` §Review Loop Protocol states a loop-level budget (4 per gate) that a fresh dispatch
   cannot reset, and preserves the cap semantics.
2. Every reviewing skill states its own loop-level budget and what happens at cap.
3. A convergence criterion distinguishes "new class" from "new variant of a recorded accepted bound";
   a no-new-class cycle does not extend the budget.
4. The cycle-log numbering convention is unambiguous when read as one table, and every cross-reference
   resolves.
5. The cycle count is machine-readable and a malformed/duplicate-numbered log fails
   `scripts/check-review-cycle-log.mjs`; RED and GREEN are both demonstrated.

## Accepted Bounds

Recorded so reviewers do not re-derive them (AGENTS.md §Convergence — Accepted Bounds). Every fresh
reviewer prompt for this artifact carries this list verbatim.

- **AB-1 — the legacy exemption is a baseline, not a fix.** Four pre-existing cycle logs
  (`docs/plans/2026-09-09-issue-637-pi-pin-bump.md` and three `docs/scoping/*` docs) keep the old
  shape and are exempted through the stale-detecting baseline. Retrofitting them is #677; it is not
  this PR's scope, and the baseline cannot rot silently (a stale entry is a failure). A finding of the
  form "the #637 log is still malformed" is AB-1, not a new class.
- **AB-2 — CI-visible, not merge-blocking.** The only required status check in this repo is
  `pipeline-compliance` (#646). The new `review-cycle-log` job reports on the PR without blocking the
  merge, exactly like the #637 pin gate. Making it merge-blocking is a branch-protection change owned
  by #646, not by this issue.

## Review Cycle Log

Cycle numbering is per gate; identity is `<gate>#<n>`. Gates are recorded at `0` until their first
dispatch, then the rows and counts are appended as each gate completes. Cross-references must be
gate-qualified and resolve to a `### Fix round — <gate> cycle <n>` heading below.

| Gate | Cycle | Result |
|---|---|---|

<!-- review-cycles
cap: 4
issue-scoping: 0
plan-review: 0 cap=5
code-review: 0
-->

## Rejected Alternatives

- **Per-class budget with a class definition the orchestrator maintains.** Rejected: the class
  boundary is exactly the judgement the loop was already getting wrong, and it gives two counters to
  reconcile. The accepted-bounds list is the same idea with a concrete, reviewable artifact and one
  budget.
- **Count cycles per reviewer but let the orchestrator carry an explicit "reviewer generation"
  counter.** Rejected: it preserves the misleading vocabulary ("cap 4 per reviewer") that caused #637.
  The budget is a property of the loop; the text now says so.
- **Enforcement by trust (agent counts).** Rejected: the #637 session was an agent counting, and it
  reached 10. The record makes the count machine-readable and the checker fails a mismatch.
- **Hard-fail every legacy cycle log in the same PR.** Rejected: it would fold a large mechanical
  rewrite of four artifacts into a rules+tooling change, and the #637 log cannot be retrofitted
  purely mechanically (its fix-round sections are out of cycle order — see #677).
- **A single record-level `cap:` with no per-gate override.** First draft; rejected because plan-review's
  risk tiers (3 / 5 / 8) are a legitimate second budget and a record-level cap would either be too
  loose for code-review/issue-scoping (8) or too tight for a High-tier plan (4). Implemented as an
  optional `cap=<n>` suffix on a gate entry, defaulting to the record-level `cap:`.

## Wiring Check

| Surface | Wired? | Where |
|---|---|---|
| checker over repo docs (per PR) | ✅ | `.github/workflows/ci.yml` → `review-cycle-log` job |
| checker fixtures (per PR) | ✅ | same job |
| checker + fixtures (post-merge) | ✅ | `.github/workflows/ci-main.yml` → `extension-tests` test-command accumulator |
| `node --check` for the new script | ✅ | `ci-main.yml` script-validate loops `scripts/*.mjs` |
| workflow syntax | ✅ | `ci.yml` actionlint job + `tests/actionlint/run.sh` Case 3 |
| workflow template drift | ✅ not applicable | `pipeline-compliance.yml`'s `workflow-drift` job template-diffs only `python-ci.yml`, `node-ci.yml`, `docs-ci.yml`; `ci.yml`/`ci-main.yml` are not template-derived, so no `scripts/sync-ci-workflows.sh` run is required |
| merge-blocking | ⚠️ not wired by design | only `pipeline-compliance` is required (#646) — AB-2 |

## Out of Scope / Accepted Residual Gaps

- **Legacy cycle logs are exempt, not fixed** — #677. The baseline is stale-detecting, so the
  exemption cannot quietly become permanent.
- **`templates/AGENTS.base.md` keeps the old per-reviewer sentence** — #676. This session was scoped
  to `AGENTS.md` §Review Loop Protocol (siblings #664/#668 own other regions of the same file); the
  base template is the consumer source of truth and the propagation is its own change. Until #676
  lands, consumers that materialized from the base still receive the defect this PR fixes.
- **The checker does not retro-validate other cycle-log shapes.** A doc that writes a cycle log under
  a different heading/table is out of scope by design (see §Check design). The convention is the
  contract; a doc that does not claim the shape is not checked.
- **No automated reviewer-prompt test.** The "fresh reviewer given the accepted-bounds list does not
  re-report a recorded bound" property is manual (it needs an LLM dispatch, not a fixture). Recorded
  as a manual procedure in §Verification plan.

## Complexity

| Domain | Rating |
|---|---|
| Org Infra | standard |
| Config | standard |

Rules + skill text + a deterministic checker with a fixture suite. No new service, no schema, no
security surface. Overall **standard** — matches the issue's `complexity:standard` label.

## Learnings

- The root cause was a *unit mismatch* between two rules in the same section: "per reviewer" and
  "fresh reviewer every cycle" cannot both be meaningful. Naming the unit ("the budget belongs to the
  LOOP") is the whole fix.
- A reviewer that re-reports an accepted bound is not converging, and a fresh-context reviewer can
  never remember the bound — so accepted bounds must live in the **artifact**, not in the
  orchestrator's memory. This is the same information-persistence lesson as the cycle log itself.
- `scripts/check-skill-lint.test.mjs` guard (j) asserts `ci.yml`'s `test-command` is *exactly* one
  command. The new check therefore had to be a **separate job**, not an appended command — a concrete
  example of a guard doing its job, and worth knowing before touching `ci.yml`.
