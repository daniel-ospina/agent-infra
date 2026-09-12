---
title: "#745 — scope the #485 T2 anti-token pin to review-enforcer claims — Scope & Plan"
type: engineering
domain: operations
doc_status: draft
subjects.team: organisation-design-team
created: 2026-09-11
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-745, issue-485, issue-513, issue-691, issue-717, review-enforcer, commit-workflow
---

# Plan — #745: scope the `#485 T2` anti-token pin to review-enforcer claims

**Issue:** daniel-ospina/agent-infra#745 (`complexity:standard`)
**PR:** daniel-ospina/agent-infra#778 — branch `fix/745-drift-pin-scope` (worktree `.worktrees/745-drift-pin-scope`)
**Tier:** Standard. **Scope shape:** test-only — 1 file, `extensions/review-enforcer/index.test.ts`.
**Status:** implemented, verified green; scope reconstructed from the shipped PR (the design work preceded the PR body — this doc transcribes it rather than re-inventing it).

> **Provenance note.** This plan doc is written *after* the implementation (the code work landed on PR #778 before the `pipeline-compliance` artifact gate was satisfied). Every alternative, rejection rationale, and verification result below is transcribed from the real record — the issue body's three candidate directions, the PR's convergence reasoning, and the committed test diff — and carries the evidence that produced it. Nothing here is invented to satisfy a checker; where the shipped implementation went **beyond** the PR body's summary, that divergence is called out (§4.2).

---

## 1. Problem

The `#485 T2` drift pin in `extensions/review-enforcer/index.test.ts` forbade four **ordinary English warn phrases** — `warn-only`, `warn only`, `warn but do not block`, `warn instead of block` — case-insensitively, across all of commit-workflow `01/02/03` (`SWEPT_DOC_RELS`). Blanket scope put an **invisible, non-local constraint on every gate's documentation**: any author describing *any other* gate had to avoid four ordinary English phrases, in three files, in any case, with nothing surfacing the constraint at the point of writing.

It fired for real. On 2026-09-10, #691 documented the **unrelated** `.husky/commit-msg` hook and naturally wrote *"It is **warn-only** by default"*. `main` went red on two consecutive merges (`3e73be7`, `03bdb24`); #717 paid the reword tax. The pin's own contract comment already predicted recurrence and prescribed the fix itself:

> the tokens are generic warn-phrases, not review-enforcer-scoped — any FUTURE legitimate "warn-only"-vocabulary prose about ANOTHER gate in 01/02/03 must be reworded (**or this list scoped**)

### 1.1 Confirmed problem definition

> **The pin's true invariant is narrower than its implementation: "no WARN-ALLOW claim **about the review-enforcer** may exist in `01/02/03`." The whole-file scan conflates that invariant with "no warn-allow word may appear anywhere in `01/02/03`," and the second is not a property anyone wants — it taxes every other gate's documentation and red-mains `main` for correct prose.**

Falsification check: if an unrelated-gate sentence using the forbidder vocabulary *must* fail for the pin to serve its purpose, then scoping is impossible. It does not — acceptance criterion 2 (an unrelated-gate sentence passes) is satisfiable while criterion 1 (a genuine re-drift fails) also holds, and the shipped T2b fixtures prove both simultaneously.

| Framing | Verdict |
|---|---|
| **A. Confirmed** — scope the pin to review-enforcer claims (the invariant it actually protects) | adopted |
| **B. Keep blanket scope, keep rewording docs (#717's remedy as policy)** | rejected — the tax is permanent, invisible, and non-local; it already red-mained `main` twice |
| **C. Delete/disable the pin** (false positives too costly) | rejected — it guards the #485/#513 verdict-tier contract; deleting a drift backstop to stop false positives is symptom therapy |

Framing B and C are the two convenience exits. The Design Principle ("quality over convenience") and the root-cause rule both point at A: the symptom is a red `main`; the root cause is a scan with no notion of *claim scope*.

## 2. Solution alternatives (the three the issue body asked to evaluate)

### Option 1 — scope the scan **region** (headings/sections) · **REJECTED**

Anchor the scan to the review-enforcer-relevant regions of `01/02/03`, reusing the region-anchoring machinery the pin already has for `CONTRACT_DOC_PINS`.

**Why rejected:** the review-enforcer prose is not separable into stable regions. In `02-commit-pr.md` the claim is embedded **inside** the Micro-tier bullet alongside the VGATE and code-review consequences (L138); in `01-preflight.md` it spans both the Micro Tier table and the Extension Gates section. New heading anchors would add a fresh **red-CI-on-rename invariant** — the very false-positive class being removed — and the `02` bullet region would still contain unrelated-gate prose, so the precision gain is cosmetic. *When this would have been better:* if the review-enforcer prose occupied a dedicated, stable heading that nothing else shared — it does not, and forcing one would be a docs restructure masquerading as a test fix.

### Option 2 — **require proximity between the anti-token and review-enforcer vocabulary** · **CHOSEN**

An anti-token counts as a claim only when it reads as a claim *about the review-enforcer* — i.e. when review-enforcer vocabulary co-occurs with it. Keeps the negative anti-token list (so *any* warn phrasing in scope is still caught), adds no anchors to rot, and depends on no file structure.

**Refinement that shipped (beyond the PR body's summary — see §4.2):** proximity is evaluated at **two widths**, because a sentence-only test leaves the **anaphoric hole** — *"…unless a reviewer was dispatched this session. … The gate is warn-only."* The second sentence names no review-enforcer vocabulary, yet is unmistakably its claim.

| Width | Signal | Why |
|---|---|---|
| **SENTENCE** (strong) | the claim's own sentence carries review-enforcer vocabulary (`review-enforcer` / `review enforcer` / `agent-issue-complexity` / `tier_rule` / `micro` / dispatch-floor forms) | sufficient on its own, wherever the sentence sits |
| **SECTION** (contextual) | the enclosing markdown section is *about* the review-enforcer, so a bare warn-allow sentence inside it is that topic's claim | closes the anaphoric hole; the section is the docs' own topic unit |

**Why chosen:** it encodes the invariant the pin actually protects — *no WARN-ALLOW claim about the review-enforcer* — at the granularity of the claim, not the file. It is a **filter, not a mute**: every historical pre-#485 re-drift sentence carries review-enforcer vocabulary, so protective power is preserved, while *"the husky hook is warn-only"* names no review-enforcer vocabulary and sits in a section that names none either, and therefore passes.

### Option 3 — **invert** to a positive, review-enforcer-scoped phrase list · **REJECTED**

Assert positively on a sanctioned phrase list instead of negatively on generic English.

**Why rejected:** strictly weaker. It catches **deletion** of the sanctioned sentence, not the **addition** of a contradicting warn claim — so acceptance criterion 1 (a genuine re-drift must *fail*) could not hold. It also reds on any legitimate editorial improvement to the sanctioned prose, i.e. it **inverts** the false-positive problem instead of removing it. *When this would have been better:* if the goal were "the sanctioned sentence must exist verbatim" (a presence pin), which was never the contract.

**Decision:** Option 2 (proximity, two widths). Evaluated on outcome quality — edge-case coverage (anaphora, nested bullets, parentheticals, negations, labels), false-positive elimination (the #691 sentence), and no new maintenance invariants — **not** on diff size. Option 2 is the largest diff of the three.

## 3. Rejected-alternatives ledger (what would have changed the decision)

| Rejected | When it WOULD have been better |
|---|---|
| Option 1 (region) | If review-enforcer prose had a dedicated stable heading; the anchor-rot cost would then be near zero and region precision could approach claim precision. |
| Option 3 (invert) | If the contract were presence ("this sentence must exist") rather than absence ("no contradicting claim"). |
| **Semantic parsing** (not in the issue's list; surfaced during implementation) | If the residual mixed-subject sentence (*"unlike the review-enforcer, the husky hook is warn-only"*) must pass. Splitting those claims needs a parser; for a drift backstop the conservative direction is to red. Documented as residual #1 in the pin's contract comment. |

Unknowns accepted, not hidden: the pin's other-gate name list (`OTHER_GATE_SUBJECT_PATTERNS`) is **open-ended by nature** — a new unrelated gate coining a warn phrase *inside a review-enforcer section* is flagged until its name is added. The list only ever **loosens** the pin, so it imposes no constraint on future authors; adding a name is the cheap extension point, and the pin's comment says so explicitly (never a doc rewording).

## 4. Implementation (what was actually shipped)

### 4.1 Structure

`extensions/review-enforcer/index.test.ts` — test-only, +948/−42 (final, after main merge). No doc or production-code changes.

| Piece | Change |
|---|---|
| `MICRO_WARN_ANTI_TOKENS` | retained; **coverage gain** — inflected re-drift forms added (`warn but does not block`, `warns but do not block`, `warns but does not block`, `warns instead of block`), which the old list missed entirely |
| `MICRO_WARN_ANTI_PATTERNS` | **new** — the two inflections that cannot be plain tokens without a false positive (`warns only` / `only warns`), exempted by a trailing continuation (`when|if|after|before|…`) so ordinary English does not red |
| `REVIEW_ENFORCER_SCOPE_PATTERNS` | **new** — the scope vocabulary, as regexes (a bare `dispatch` would drag unrelated prose such as "the mutation gate dispatches a nightly run" in) |
| `OTHER_GATE_SUBJECT_PATTERNS` | **new** — claim-subject escape: inside a scoped section, a warning whose clause **names a different gate** before the phrase is that gate's prose, not a review-enforcer re-drift |
| `claimNamesAnotherGate` + `clauseStartsBefore` | **new** — positional clause analysis (`;:—–,` + coordinating/subordinating boundaries, parentheticals blanked in place) to find the claim's clause head; relative `that` clauses do not escape, complementizer `that` clauses can; bare anaphors borrow the previous clause |
| `markdownSections` / `sectionSentenceUnits` | **new** — markdown headings delimit sections; fenced code blocks and HTML comments handled (comment bodies can neither scope a section nor donate escape words); hard wraps joined, while table rows / list items / headings / blockquote starts are structural boundaries so a review-enforcer bullet cannot absorb the next bullet |
| `LEGIT_ON_DEMAND_LINE` | **DELETED** (AC3) — and its per-line strip + the anchor-count pin with it. The on-demand-gates line carries no scope token and sits in a section that carries none either, so it passes **structurally**. The doc line itself is untouched. |
| `findMicroWarnClaims` | the single predicate T2 and T2b both exercise (no parallel copy) |
| `#485 T2b` (new test) | two-sided proof: **must-FAIL** fixtures (including six **real pre-#485 corpus sentences** recovered from `e097b38^`, so protective power is proven against the actual re-drift vocabulary, not invented text) and **must-PASS** fixtures (including the literal #691 sentence and the on-demand-gates line), plus an end-to-end mixed-document check proving the scope is a filter, not a mute |

### 4.2 Divergence from the PR body, stated plainly

The PR body describes proximity as **sentence-level**. The shipped implementation evaluates **sentence AND section** (the anaphoric hole: *"…unless a reviewer was dispatched this session. … The gate is warn-only."*). The section width is a **strict superset** of the sentence width — it catches more, never less — and was added during the review loop (rounds referenced in the code comments, e.g. the reviewer scenario A/B anaphora cases in the T2b fixtures). The user-facing scope claim in the issue and PR body is unchanged and remains accurate: *only claims about the review-enforcer are in scope.*

### 4.3 Residuals, accepted deliberately (documented in the pin's contract comment)

1. A **sentence** naming the review-enforcer *and* another gate's warn behavior ("unlike the review-enforcer, the husky hook is warn-only") still reds — splitting those claims needs semantic parsing; for a backstop, the conservative direction is to red.
2. A warn-allow sentence in a **different** section from any review-enforcer content is out of scope even if anaphorically about it — the section is the topic unit, and that *is* the boundary that removes the #745 failure mode.
3. Conservative reds on shapes needing semantic parsing, and only inside a review-enforcer section: a negated claim ("the micro tier is no longer warn-only") and an other-gate subject split from its copula by an inserted phrase. The pre-#745 pin reddened on negations too — same fail-safe direction, not a regression.
4. A **bounded false negative**: in a scoped section, a re-drift whose other-gate name sits in an *unpunctuated* leading subordinate clause, or a relative-clause inversion. The inverse heuristic false-reds equally legitimate prose, so the pin does not guess; the punctuated comma form *is* caught (T2b fixture).

## 5. Verification (what was actually run)

Command (CI-equivalent): `(cd extensions/review-enforcer && npm ci …) && NODE_ENV=test npx tsx extensions/review-enforcer/index.test.ts`

| Scenario | Result |
|---|---|
| baseline `origin/main` | **113 passed, 0 failed** |
| after this change | **114 passed, 0 failed** |
| **AC1** append *"The review-enforcer micro tier warns but does not block — 0 dispatches warn only."* to the real `01-preflight.md` | **❌ #485 T2 fails** (113/1) — *"carries 2 review-enforcer warn-allow claim(s) …"* |
| **AC2** restore the exact #691 sentence *"It is **warn-only** by default"* in the real `02-commit-pr.md`, new pin | **✅ 114 passed, 0 failed** |
| **AC2′** same doc under `origin/main`'s pin | **❌ 112 passed, 1 failed** — the historical failure reproduced and closed |
| **AC3** `LEGIT_ON_DEMAND_LINE` | removed (`grep` → comment reference only); on-demand line present verbatim in the doc and pinned as a must-pass fixture |
| **AC4** `#485`/`#513` verdict-tier contract | untouched: T2's fence↔`TIER_RULE` `deepEqual` + producer-vocabulary pins, and T3's source-shape pins, unchanged |

A VGATE verification dispatch independently confirmed the suite result, that T2 and T2b exercise the **same** `findMicroWarnClaims` predicate (no parallel copy), and that the three swept docs are unmodified by the commit.

## 6. Acceptance criteria → disposition

- [x] **AC1** a genuine re-drift still **fails** — proven by test (`#485 T2b`, must-FAIL fixtures incl. the real pre-#485 corpus)
- [x] **AC2** an unrelated-gate sentence using the same vocabulary **passes** — proven by test (`#485 T2b`, must-PASS fixtures incl. the literal #691 sentence)
- [x] **AC3** the `01-preflight.md` on-demand-gates carve-out line no longer needs a special-case strip — `LEGIT_ON_DEMAND_LINE` deleted; passes structurally
- [x] **AC4** no reduction in coverage for the `#485`/`#513` verdict-tier contract — full `review-enforcer` suite: **114 passed, 0 failed**

## 7. Wiring Check

| Touch Point | Type | Covered By | Status |
|---|---|---|---|
| `extensions/review-enforcer/index.test.ts` — `findMicroWarnClaims` predicate | test (unit, the pin) | #778 (`#485 T2`, `#485 T2b`) | ✅ |
| `MICRO_WARN_ANTI_TOKENS` / `MICRO_WARN_ANTI_PATTERNS` (anti-token vocabulary) | test data | #778; coverage gained (inflected forms) | ✅ |
| `REVIEW_ENFORCER_SCOPE_PATTERNS` / `OTHER_GATE_SUBJECT_PATTERNS` (claim scope + escape) | test data | #778 | ✅ |
| `SWEPT_DOC_RELS` = commit-workflow `01/02/03` docs | docs (read-only input) | unmodified by #778; pinned by T2's existence + vacuous-pass guard | ✅ |
| `01-preflight.md` `REVIEW-ENFORCER-TIER-RULE` fence ↔ `TIER_RULE` | test pin (T2, unchanged) | #485; untouched | ✅ |
| `#513` verdict-tier contract (`TIER_RULE`, `clean-micro`) | test pins (T1/T1b/T3, unchanged) | #513; untouched | ✅ |
| CI: `extension-tests / unit-test` (`ci-main.yml`) | pipeline | same job that red-mained on `3e73be7`/`03bdb24`; runs the suite | ✅ |
| `pipeline-compliance` (required status check) | pipeline gate | scoping comment `<!-- issue-scoping: … -->` on #745 + this plan doc | ✅ (this PR) |
| `LEGIT_ON_DEMAND_LINE` carve-out | test constant | **deleted** (AC3) — nothing else referenced it (verified by `grep`) | ✅ |
| Production extension behavior (`extensions/review-enforcer/index.ts`) | runtime code | **not touched** — this is a test-only change | ✅ n/a |

No DB, API, auth, external-service, or UI touch points. No new dependency.

## 8. Deferred / not done (explicit)

- **Phase 7 parallel review gates of `issue-scoping`** were not re-run against this *reconstructed* scoping artifact: the artifact's plan content describes work already implemented and reviewed (PR #778's VGATE dispatch + the fresh code review on the final head SHA, dispatched as part of landing this PR). The `issue-scoping` verification gates that *were* run here are recorded in the scoping comment on #745.
- **`OTHER_GATE_SUBJECT_PATTERNS` growth** is not closed work — it is an intentional open extension point (§3). No tripwire is needed: the list only loosens the pin, and a false red is immediately actionable by adding a name.

## 9. Complexity

| Domain | Rating |
|---|---|
| UX | low (no user-facing surface) |
| Ontology | low (no schema/entity change) |
| Architecture | low-medium (single-predicate change in one test file; the clause/section machinery is local to the test) |
| Tier | standard (issue label `complexity:standard`; shared-infrastructure path `extensions/` per the skill's Micro→Standard override) |
