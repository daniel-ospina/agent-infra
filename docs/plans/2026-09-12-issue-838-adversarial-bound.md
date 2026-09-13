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

### 2.1 Own threat surface (this change's declaration)

This is the acceptance contract for the change. It is deliberately **finite**: a declared list,
covered by mutation tests, is what makes the exit decidable (and is why a bounded exit needs no
literal `NO ISSUES FOUND`).

**In scope — accidental drift.** What is under pin is the `### L1 — Exit conditions` fence in
`skills/code-review/references/fixer-loop.md`, plus the bound values the eight declaring surfaces
carry. That fence is **agent-facing prose — a prompt a fixer agent reads and follows — not a shell
program the repo executes.** The pin's contract is therefore *fidelity to the canonical text*; the
failure mode it exists to catch is drift — an edit that silently stops the document matching the
intended contract. Each class below has a mutation test that goes red without its guard.

1. **Bound drift** — the adversarial cap reads 2 on one surface and another number elsewhere → every surface carries exactly one anchor and all are equal.
2. **Silent re-cap of non-adversarial work** — the Low-Medium / Medium-High / High caps (3 / 5 / 10) move → the canonical table is asserted unchanged; `tier-config-parity` already pins runtime ↔ table parity.
3. **Unbounded-claim laundering** — a bounded, threat-list-covered exit presented as a literal `NO ISSUES FOUND` → the bounded verdict token (`THREAT SURFACE COVERED`) is distinct, and the PR body must carry the `[ADVERSARIAL-BOUND] …` disclosure line.
4. **Domain-declaration escape** — an adversarial change never classified as one → the declaration is mandatory and binary (`(not adversarial)` required when it does not apply).
5. **Fence drift** — any edit to the canonical `### L1` block (a commented-out branch, `BOUND=10` → `BOUND=100`, an added forged-marker line) → the exact-text pin requires the block verbatim, exactly once.
6. **Stray / duplicate block** — a second `### L1`-shaped section or an extra `BOUND=` assignment a fixer could copy instead → exactly-one-heading + no-stray-assignment conditions.
7. **Renamed / relocated heading** — the fence moved out of its `### L1` section → the heading is part of the pinned block.
8. **Literal guard-reachability loss** — the `ADVERSARIAL_BOUND=${ADVERSARIAL_BOUND:-0}` setup line deleted, or a *literal* duplicate `ADVERSARIAL_BOUND` assignment added (the cycle-1 regression) → the reachability pin requires the setup line exactly once and no other literal reference.
9. **Pin vacuity by drift** — the pin passes because its anchor vanished → every anchor check fails closed on absence, with negative controls.

**Coverage basis (stated so a reviewer can verify it mechanically).** Classes 1, 2, 5, 6, 7, 8 and 9
are **mutation-tested**: each is a shape applied to the real `fixer-loop.md`/canonical table that
makes a named assertion in `tier-config-parity.test.ts` go red (the §8.1 mutation table; the
negative-control tests carry the same names). Classes 3 and 4 are **contract-text invariants** —
there is no fence mutation for them; they are asserted by the pinned `adversarial-capped` token
(`canonicalFenceSelfViolations`) / anchor parity (`adversarialBoundViolations`) and enforced by the
skills the contract lives in (`code-review`, `issue-scoping`). The mutation-test requirement below
applies to the drift classes; the contract classes are verified against their pinned text.

**Out of scope — adversarial shell-execution semantics against the fence *as code*.** Pre-loop
variable rebinding that avoids the literal token (guard-name splitting via `v=ADVERSARIAL_` +
`v+=BOUND` + `printf -v "$v"`), builtin / `[` shadowing, environment injection, and forged
observation channels are **not** in scope. Rationale:

- The artifact is a **prompt**, read by an agent — the repo never executes it. Its correctness
  property is that it *says what the contract intends*, not that it is undefeatable by a shell
  attacker with write access to the session's environment.
- Forging an observation required an observation channel — *execute the markdown in bash and parse
  its stdout*. That channel has been **deleted** (§8, approach A); there is nothing left to forge,
  and **an execution harness must not be re-introduced** to chase these classes.
- Enumerating spellings of shell-semantic attacks against a document is the exact unbounded loop
  #838 exists to stop: every fix invites a new spelling (four cycles produced four).

Residuals of this class are **filed, not chased** (#892). Moving the line — declaring any of these
in scope — is a scoping decision, not a reviewer finding.

**Reviewer challenge rule.** A reviewer's job is (a) to verify each in-scope class above has a
mutation test that genuinely goes red, and (b) to challenge whether this declaration is **honest** —
in particular, whether any item placed out of scope is in fact load-bearing for the contract *as
written* (the document an agent follows). Constructing a new arbitrary-shell-execution attack against
the fence is **not** a finding under this declaration; a reviewer who believes an out-of-scope vector
breaks the actual contract must argue it *against this declaration*, with evidence about the
document, rather than file the vector.

### 2.2 Out of scope (filed/left, not chased — non-adversarial)

- Mechanical test→threat coverage semantics (the pin checks contract text; the reviewer judges coverage).
- Runtime cycle counting (no counter exists in `review-enforcer`; separate change).
- Classifying whether a change is adversarial (a scoping judgement; only its explicitness is enforced).

(Adversarial shell-execution semantics are out of scope by §2.1 above, not repeated here.)

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
| `skills/code-review/references/fixer-loop.md` | the pinned `### L1` fence: `ADVERSARIAL_BOUND=1` → 2 cycles, `adversarial-capped`; one of the 8 anchor surfaces |
| `extensions/loop-enforcer/tier-config-parity.test.ts` | anchor-parity pin + negative controls |
| `docs/plans/2026-09-12-issue-838-adversarial-bound.md` | this doc |

## 5. Verification

> **Superseded by §8 / §8.3** — the execution harness described here was deleted, and #894 later pinned
> the subject set; the suite is now **46 passed, 0 failed**. The text below is the historical
> cycle-0/cycle-1 record.

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
- Reviewer B (contract/consistency): `THREAT SURFACE COVERED` — classes 3 and 4 covered, no permissive reading on any of the eight surfaces.

**Exit: `adversarial-capped` at 2 cycles — a BOUNDED exit, not a clean one.** Per this change's own rule, the cycle-2 in-scope residuals are **filed, not chased**: #874 (the executable-bound pin's text-vs-effective-value weakness) and #875 (unqualified `NO ISSUES FOUND` sentences left next to the adversarial substitution). No literal `NO ISSUES FOUND` was obtained and no `clean` verdict is claimed.

Disclosure: `[ADVERSARIAL-BOUND] cycles=2 threats=5 covered=3 residuals=#874,#875`

## 7. Resume (2026-09-12, post-merge of main)

`origin/main` was merged into the branch (head `b7a40e2`) before any re-review, so the recorded
verdict and second-model gate line bind to the final head. Both cycle-2 in-scope residuals were then
**closed in this PR** rather than carried:

- **#874** — the executable-bound pin now binds to what EXECUTES, at three layers: (a) shell
  comments are stripped from the fenced bash and every `BOUND=<N>` assignment parsed, requiring
  exactly `[10, 2]` numerically; (b) no literal reassignment of `ADVERSARIAL_BOUND` is allowed
  (only the `${ADVERSARIAL_BOUND:-0}` default setup); (c) the fenced L1 block is **executed** under
  bash with the guard set to 1 and 0 and the observed `BOUND` must be 2 and 10. A commented-out
  `then BOUND=2; fi` yields `[10]`; `BOUND=10` → `BOUND=100` yields `[100, 2]`; and the cycle-3
  guard-neutering bypass (`ADVERSARIAL_BOUND=0` injected before the byte-intact branch) is caught
  by layers (b) and (c) even though the assignment shape is unchanged. Negative controls cover all
  three, and the old substring check (`includes("BOUND=10")`, satisfied by `BOUND=100`) is gone.
- **#875** — `task-workflow-standard` and `plan-review` now qualify their general
  "only `NO ISSUES FOUND` advances" sentences with the adversarial `THREAT SURFACE COVERED`
  substitution, so the rule is not read unqualified in multiple places.

Verification: `npx tsx extensions/loop-enforcer/tier-config-parity.test.ts` → **37 passed, 0 failed**;
all three bypass mutations were re-applied to the real `fixer-loop.md` and each made the suite red
(commented-out branch: 30 passed / 7 failed; `BOUND=100`: 31 passed / 6 failed; guard-neutering
`ADVERSARIAL_BOUND=0`: 35 passed / 2 failed). The bounded re-review verdict for the merged head is
recorded in the PR body.

> **Superseded by §8.** The execution boundary described immediately above was removed one day
> later — it is the observation channel §8 deletes; the suite is now **42 passed, 0 failed**.

## 8. Decisive simplification (2026-09-13) — exact-text pin, harness deleted

The #874 closure in §7 hardened an observation channel — *execute the markdown in bash, parse its
stdout* — that three review cycles each defeated in a new way. Three holes, one family (threat
class 5, pin vacuity):

1. `printf "BOUND=%d\n" 2` printed a fake marker the first-match regex read → 37/0 green while the
   real loop executed the 10-cycle cap.
2. The sentinel + last-match fix fell to a shadowing body (`command`/`[`/`builtin`/`printf`).
3. The allowlist fix fell to an allowlist-clean **decoy block placed earlier**: `fixerLoopBlock()`
   bound to the first matching block while `executableBoundAssignments()` summed over all blocks, so
   the real L1 fence was never checked and never executed — the pin returned `[]` while the fence
   executed `BOUND=20`.

By #838's own contract this class is declared **out of scope, not chased**. Rather than write a
fourth hardening, the observation channel is removed:

- **Approach A — exact-text pin, no execution.** `CANONICAL_L1_BLOCK` is the one approved
  `### L1 — Exit conditions` block, byte-for-byte. `l1FenceViolations(md)` requires (i) the block to
  occur **exactly once**, (ii) the `### L1` heading to occur **exactly once**, and (iii) no `BOUND=`
  assignment to survive **outside** the block. `adversarialReachabilityViolations(md)` additionally
  requires the guard setup line `ADVERSARIAL_BOUND=${ADVERSARIAL_BOUND:-0}` to occur exactly once and
  **no other `ADVERSARIAL_BOUND` reference** anywhere — restoring, as exact text, the layer the
  deleted `adversarialBoundAssignments()` used to provide. `canonicalFenceSelfViolations()` ties the
  constant to `ADVERSARIAL_CAP` and the `adversarial-capped` exit. No bash is executed; every check
  is a property of the text, so there is no stdout to forge.
- **Deleted, not disabled:** `execFileSync`, `BOUND_SENTINEL`, `effectiveAdversarialBound`,
  `executableBashBlocks`, `stripShellComments`, `executableBoundAssignments`,
  `adversarialBoundAssignments`, `fixerLoopBlock`, `unallowedL1Statements`, the `L1_ALLOWED_STATEMENTS`
  allowlist, and every execution-based test.

### 8.1 Cycle-1 review of the simplification (2 fresh reviewers)

- **In-scope (class 5/1, REGRESSION)** — Reviewer A reproduced a pre-loop `ADVERSARIAL_BOUND=0`
  injection that left the canonical L1 block byte-identical: the pin stayed green (whole suite 42/0)
  while the doc executed the general 10-cycle cap. The deleted `adversarialBoundAssignments()` layer
  used to catch exactly this. Fixed by `adversarialReachabilityViolations()` — exact text, no
  execution — plus guard-spelling controls (`export` / `unset` / `printf -v`).
- **In-scope (class 5)** — Reviewer A also placed a second `### L1`-shaped section (`CAP=20`) a fixer
  could copy instead. Fixed by the exactly-one-heading condition (a renamed-heading decoy containing
  the same heading substring is caught too).
- **Control fragility** — the relocated-fence control rewrote the *first* heading occurrence, so a
  decoy earlier in the doc made it red for the wrong reason. Fixed by anchoring the mutation on
  `CANONICAL_L1_BLOCK`.
- **Doc/PR-body staleness** — §4–§7 carried pre-§8 counts (32/34/37/38), “seven surfaces”, and an
  omitted `fixer-loop.md` row; the PR body still described the deleted harness as the blocker. All
  corrected here; the PR body is refreshed at merge.

The two in-scope findings are the **same class** (pin vacuity / guard neutering) the simplification
exists to bound — not a new class — and both are closed by exact text, so no execution was
reintroduced. What the pin does *not* scan for — a bound computed under a non-literal
variable/spelling, or a shadowed builtin — is **out of scope by declaration** (§2.1): the artifact is
prose an agent reads, not a program the repo executes, so shell-execution semantics against it are
not part of the contract this pin enforces.

**Mutation evidence** — each mutation applied to the real `fixer-loop.md`, then the real suite run
(the first failing pin is the substantive one):

| Mutation | Result |
|---|---|
| commented-out adversarial branch | 39 passed / **3 failed** (red) |
| `BOUND=10` → `BOUND=100` | 37 passed / **5 failed** (red) |
| allowlist-clean decoy block prepended | 40 passed / **2 failed** (red) |
| forged marker `printf "BOUND=%d\n" 2` | 39 passed / **3 failed** (red) |
| pre-loop `ADVERSARIAL_BOUND=0` (cycle-1 finding) | 41 passed / **1 failed** (red) |
| renamed-heading `### L1` decoy with `CAP=20` (cycle-1 finding) | 41 passed / **1 failed** (red) |

File restored byte-for-byte after each. Baseline: **42 passed, 0 failed**. Failure counts include
control-precondition assertions that also trip when the base doc is mutated; the pin failure is
always among them.

The chosen approach is not clever — it is the absence of cleverness. A pin whose "verification"
executes the text under test can always be made to observe a forgery; a pin that *is* the text
cannot.

### 8.2 Re-scope (2026-09-13, cycle-2 review) — the pin vacuity vector is declared, not chased

The cycle-2 fresh reviewers reproduced two further "pin vacuity" vectors (#892): guard-name
splitting (`v=ADVERSARIAL_` + `v+=BOUND` + `printf -v "$v" 0`) and `[` shadowing, each leaving both
pin functions green while a *shell executing the markdown* would run the general 10-cycle cap. Those
reviewers were operating against an **unbounded threat model** — arbitrary shell semantics against
the fence treated as an executed program. That model is wrong for this artifact, and no pin can
exhaust it, which is why four cycles produced four new vectors.

This is the re-scope. The declared threat surface is §2.1: **in scope = accidental drift** (any edit
to the canonical text, any bound change, a stray/duplicate block, a renamed heading, loss of literal
guard reachability — each has a red-without-guard mutation test above), and **out of scope =
adversarial shell-execution semantics against the fence as code** (the #892 class, the deleted
observation channel, environment injection). Rationale: the fence is a prompt consumed by an agent,
not a program the repo executes; the pin's contract is fidelity-to-canonical-text; and the
observation channel that made forgery meaningful was deleted (approach A). **The execution harness is
not re-introduced.** #892 is filed as an out-of-scope residual.

The cycle-3 review was re-briefed accordingly — to test in-scope coverage and to challenge only the
*honesty* of this declaration (see §2.1's reviewer challenge rule). A reviewer that still disagrees
must argue the declaration is dishonest (i.e. that an out-of-scope vector breaks the contract *as
written*), citing §2.1, rather than filing a new vector.

### 8.3 Cycle-4 review of the re-scope (2026-09-13) — #894 closed, class 9 honest

The cycle-3 reviewer accepted the §2.1 declaration as honest, confirmed the execution harness is
verifiably gone, and produced **no new adversarial-shell vector** — the unbounded loop the re-scope
exists to stop is closed. It filed one **in-scope class-9 (pin vacuity)** finding, #894:
`adversarialBoundViolations()` returned `[]` for an empty source map, and `ADVERSARIAL_SURFACES`
(the map's subject set) had no cardinality or set-equality assertion, so deleting a de-listed
surface left the positive test green and the surface free to drift.

Fixed as the reviewer prescribed — no redesign, no execution harness:

- `adversarialBoundViolations()` fails closed on an empty source set (absent subject = violation).
- The checked subject set is pinned to the declared eight (`DECLARED_ADVERSARIAL_SURFACES` +
  `subjectSetViolations()` set-equality), so de-listing a surface and adding an undeclared one both
  go red.
- Negative controls added: a shrunk set, an empty `{}`, and an added undeclared surface each fail.

**Evidence** — `npx tsx extensions/loop-enforcer/tier-config-parity.test.ts` → **46 passed, 0 failed**
(was 42). Mutation evidence, file restored byte-for-byte after each:

| Mutation | Result |
|---|---|
| empty-source guard neutered (`length === 0` → `-1`) | 45 passed / **1 failed** (the `{}` control) |
| `skills/plan-review/SKILL.md` deleted from `ADVERSARIAL_SURFACES` | 44 passed / **2 failed** (the subject-set pin + its dependent control) |
| baseline (unmutated) | **46 passed, 0 failed** |
