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

- `npx tsx extensions/loop-enforcer/tier-config-parity.test.ts` — all tests pass, including the new negative controls (must FAIL on a mutated cap / a missing anchor / a re-capped canonical row).
- `node scripts/check-skill-lint.test.mjs`, `node scripts/check-skill-lint.mjs --repo .` — skill frontmatter still valid.
- `bash tests/drift/run.sh` not required (no template-pin change beyond prose).
- Bounded code review: **max 2 cycles**, per this change's own rule. A fresh reviewer returning `THREAT SURFACE COVERED` (all 5 declared classes covered, no in-scope bypass reproduced) is a clean exit; residuals are filed, not chased, and the PR body discloses the basis.

## 6. Review Cycle Log

Cycle 1 and (if needed) cycle 2 recorded on the PR. Bounded exit disclosed with
`[ADVERSARIAL-BOUND] cycles=… threats=5 covered=… residuals=…`.
