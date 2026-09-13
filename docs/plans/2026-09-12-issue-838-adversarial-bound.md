---
title: "#838 — bound adversarial review by a declared threat surface, not reviewer exhaustion — Scope & Plan"
type: engineering
domain: operations
doc_status: draft
subjects.team: organisation-design-team
created: 2026-09-12
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-838, issue-709, issue-745, issue-708, issue-814, issue-793, issue-860, code-review, plan-review, issue-scoping, proportional-gates, review-enforcer
---

# Issue #838 — bound adversarial review by a declared threat surface

**Issue:** daniel-ospina/agent-infra#838 (`complexity:standard`)
**Branch:** `fix/838-adversarial-bound` — worktree `.worktrees/838-adversarial-bound`
**Scoping comment:** issue #838, `<!-- issue-scoping: 2026-09-11 (standard) -->` (Wiring table included)

## 1. Problem

Cap-by-count is not a bound on gate/enforcement code. The acceptance predicate there is "the
reviewer has no more ideas", which is not a property of the change, so a count cap is reached
only after hours and is indistinguishable from failure. Batch 2026-09-11 evidence: #709/PR #799
(11 rounds, 3 residuals → #814), #745/PR #778 (10 rounds, stalled at 3, 10 residuals → #793,
objective not delivered), #708/PR #823 (2 cycles, converged only under an imposed budget).

## 2. The contract introduced

| # | Behaviour (issue's "Intended behaviour") | Where it lives |
|---|---|---|
| 1 | Declare the bounded threat list + explicit out-of-scope classes **up front** | `issue-scoping` (mandatory binary `### Adversarial Threat Surface`), `task-workflow-standard` (scope stage) |
| 2 | Acceptance = declared threat list covered by tests + green CI; a fresh reviewer reproducing no in-scope bypass and confirming coverage is a **clean exit** | `code-review`, `plan-review` (exit conditions + `THREAT SURFACE COVERED` verdict) |
| 3 | Cap **2 cycles** (tighter than the general bound); residuals **filed from cycle 1, not chased** | `proportional-gates` (canonical), `AGENTS.md` §Hard Cap, `code-review`, `plan-review` |
| 4 | Disclose plainly when a merge rests on threat-list coverage, not a literal `NO ISSUES FOUND` | `AGENTS.md` §Hard Cap + `[ADVERSARIAL-BOUND] cycles=… threats=… covered=… residuals=…` in the PR body |

### 2.1 Own threat surface (this change's declaration — in scope)

1. **Bound drift** — the adversarial cap reads 2 on one surface and another number elsewhere → the pin requires every surface to carry exactly one anchor and all caps to be equal.
2. **Silent re-cap of non-adversarial work** — the Low-Medium / Medium-High / High caps (3 / 5 / 10) move → the pin asserts the canonical table is unchanged; `tier-config-parity` already pins runtime ↔ table parity.
3. **Unbounded-claim laundering** — a bounded exit presented as literal `NO ISSUES FOUND` → a distinct pinned verdict token plus a required PR-body disclosure line.
4. **Domain-declaration escape** — an adversarial change never classified as one → the declaration is mandatory and binary (`(not adversarial)` required when it does not apply).
5. **Pin vacuity** — the pin passes on an absent anchor → exactly-one-anchor per surface + negative controls.

### 2.2 Out of scope (filed/left, not chased)

- Mechanical test→threat coverage semantics (the pin checks contract text; the reviewer judges coverage).
- Runtime cycle counting (no counter exists in `review-enforcer`; separate change).
- Classifying whether a change is adversarial (a scoping judgement; only its explicitness is enforced).

## 3. Design decisions

- **Not a 5th row in the canonical Review Cycles table.** That table is machine-parsed and keyed by reviewer count (`parseReviewCycleTable`); a non-numeric row breaks `tier-config-parity`'s caps↔table count assertion. The adversarial bound is orthogonal to risk → prose + a one-line machine-readable anchor.
- **Anchor, not prose parsing.** Each declaring surface carries exactly one `<!-- adversarial-bound: cap=2 -->`. Prose parsing ("the first `N cycles` near 'adversarial'") is brittle — the surrounding prose legitimately mentions the general 10-cycle cap.
- **AGENTS.md consistency.** "Never apply a bound tighter than the skill's own" is preserved by defining 2 as *the skill's own bound for this domain* (canonical in `proportional-gates`), not as a cap imposed by AGENTS.md. The non-adversarial table is untouched.
- **Pin placement.** `extensions/loop-enforcer/tier-config-parity.test.ts` is already wired per-PR (`ci.yml` `verify`) and post-merge (blocking backstop in `ci-main.yml`), zero-dep, and already parses the canonical table. A new file would add `ci.yml` + `ci-main.yml` surface for a text contract.
- **Both AGENTS.md copies.** `AGENTS.md` and `templates/AGENTS.base.md` differ only by the repo-specific VENDOR line; consumer repos materialize the base, so both are updated in lockstep.

## 4. Files

| File | Change |
|---|---|
| `skills/proportional-gates/SKILL.md` | adversarial bound stated canonically beside the Review Cycles table + anchor |
| `AGENTS.md`, `templates/AGENTS.base.md` | §Hard Cap: adversarial domain = the skill's own bound for that domain; disclosure rule; anchor |
| `skills/code-review/SKILL.md` | exit conditions + bounded exit token + `adversarial-capped` exit_reason + filed-not-chased + disclosure |
| `skills/plan-review/SKILL.md` | same at the plan-level gate loop + exit conditions |
| `skills/issue-scoping/SKILL.md` | mandatory binary threat-surface declaration (plan prompt + scoping-comment template) + bounded gate-loop note |
| `skills/task-workflow-standard/SKILL.md` | scope/plan verifier gates accept the bounded verdict |
| `extensions/loop-enforcer/tier-config-parity.test.ts` | anchor-parity pin + negative controls |
| `docs/plans/2026-09-12-issue-838-adversarial-bound.md` | this doc |

## 5. Verification

- `npx tsx extensions/loop-enforcer/tier-config-parity.test.ts` — **34 passed, 0 failed** (21 baseline + 13 new), including the negative controls (mutated cap / missing anchor / duplicated anchor / re-capped canonical table / **executed** `BOUND=3` with the anchor intact / dropped executable branch / **commented-out adversarial branch** / **`BOUND=10` → `BOUND=100`**) — each must FAIL. The executable-bound pin parses the fenced bash with shell comments stripped and requires exactly two numeric `BOUND=<N>` assignments (`[10, 2]`), so it binds the effective value rather than source text: a commented-out `then BOUND=2; fi` leaves one assignment, and `BOUND=100` fails the strict default equality that `includes("BOUND=10")` used to wave through.
- `node scripts/check-skill-lint.test.mjs`, `node scripts/check-skill-lint.mjs --repo .`, `node scripts/check-pi-pin-lockstep.mjs` — green.
- Bounded code review: **max 2 cycles**, per this change's own rule. A fresh reviewer returning `THREAT SURFACE COVERED` (all 5 declared classes covered, no in-scope bypass reproduced) is a clean exit; residuals are filed, not chased, and the PR body discloses the basis.

## 6. Review Cycle Log

**Cycle 1** — 2 fresh reviewers. 4 in-scope findings, all fixed:

| # | Class | Finding | Fix |
|---|---|---|---|
| 1 | 1 (cap drift) | the pin bound the anchor comment but not the **executed** `BOUND`; `BOUND=2→3` left 29/29 green (reproduced by the reviewer) | `executableBoundViolations()` parses `then BOUND=<N>; fi`; equality assertion + `BOUND=3` and dropped-branch negative controls |
| 2 | 1 (cap drift) | `ADVERSARIAL_BOUND` was never **set** anywhere, so the 2-cycle branch was unreachable on the documented path | pre-loop setup defines `ADVERSARIAL_BOUND=${ADVERSARIAL_BOUND:-0}`; `code-review` Step 6 says to export it; pinned |
| 3 | 3 (laundering) | `proportional-gates` — the surface `AGENTS.md` calls canonical — omitted the clean-verdict token and the disclosure syntax | both added to the canonical paragraph |
| 4 | 4 (declaration escape) | the scoping template emitted `## Adversarial Threat Surface` while every consumer keys on `###` | template now requires the `###` section inside the plan draft (one heading level everywhere) |

Out-of-scope findings — **filed, not chased**: #871 (reported cycle count is off by one), #870 (no mechanical check that a scoping comment declares or disclaims the surface).

**Cycle 2** — 2 fresh reviewers (the cap). Verdicts split:

- Reviewer A (adversarial): 2 more in-scope bypasses of classes 1/2/5 — the executable-bound pin matches **text**, so a commented-out `then BOUND=2; fi` (executed bound 10) and `BOUND=10 → BOUND=100` (`includes()` substring vacuity) both leave the suite 32/32 green. **Class 1 and 2 are therefore NOT covered.**
- Reviewer B (contract/consistency): `THREAT SURFACE COVERED` — classes 3 and 4 covered, no permissive reading on any of the seven surfaces.

**Exit: `adversarial-capped` at 2 cycles — a BOUNDED exit, not a clean one.** Per this change's own rule, the cycle-2 in-scope residuals are **filed, not chased**: #874 (the executable-bound pin's text-vs-effective-value weakness) and #875 (unqualified `NO ISSUES FOUND` sentences left next to the adversarial substitution). No literal `NO ISSUES FOUND` was obtained and no `clean` verdict is claimed.

Disclosure: `[ADVERSARIAL-BOUND] cycles=2 threats=5 covered=3 residuals=#874,#875`

## 7. Resume (2026-09-12, post-merge of main)

`origin/main` was merged into the branch (head `b7a40e2`) before any re-review, so the recorded
verdict and second-model gate line bind to the final head. Both cycle-2 in-scope residuals were then
**closed in this PR** rather than carried:

- **#874** — the executable-bound pin now strips shell comments from the fenced bash and parses
  every `BOUND=<N>` assignment, requiring exactly `[10, 2]` numerically. A commented-out
  `then BOUND=2; fi` yields `[10]` (violation) and `BOUND=10` → `BOUND=100` yields `[100, 2]`
  (violation). Negative controls added for both, and the old substring check
  (`includes("BOUND=10")`, which `BOUND=100` satisfies) was replaced with strict equality.
- **#875** — `task-workflow-standard` and `plan-review` now qualify their general
  "only `NO ISSUES FOUND` advances" sentences with the adversarial `THREAT SURFACE COVERED`
  substitution, so the rule is not read unqualified in multiple places.

Verification: `npx tsx extensions/loop-enforcer/tier-config-parity.test.ts` → **34 passed, 0 failed**;
both bypass mutations were re-applied to the real `fixer-loop.md` and each made the suite red
(30 passed, 4 failed). The bounded re-review verdict for the merged head is recorded in the PR body.
