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
**Tier:** Standard. **Scope shape:** test-only runtime change — `extensions/review-enforcer/index.test.ts`, +948/−42; plus this plan doc.
**Status:** implemented and committed on PR #778 (**open**). Scope reconstructed from the shipped code + PR record, then verified by the `issue-scoping` gates (cycle log in §11). The last **code** review record is `@ 039f45114b623d4f95e95245de84e71a8a308d9e`; the branch head since then is docs-only.

> **Provenance note.** The code work on PR #778 preceded this plan doc (the `pipeline-compliance` artifact gate is what required it). Every alternative, rejection rationale, and verification result below is transcribed from the real record — the issue body's three candidate directions, the PR's convergence reasoning, the committed diff, and the live test run — and carries its evidence. Where the shipped implementation **diverged** from the PR body's summary, or where verification **found a defect**, that is called out explicitly (§4.2, §4.3, §10, §11) rather than smoothed over. The PR body's own figures (`+186/−40`, "11 must-FAIL / 5 must-PASS") are from a **superseded revision** and are not reproduced here; the counts in this doc are measured from the final code.

---

## 1. Problem

The `#485 T2` drift pin in `extensions/review-enforcer/index.test.ts` forbade four **ordinary English warn phrases** — `warn-only`, `warn only`, `warn but do not block`, `warn instead of block` — case-insensitively, across all of commit-workflow `01/02/03` (`SWEPT_DOC_RELS`). Blanket scope put an **invisible, non-local constraint on every gate's documentation**: any author describing *any other* gate had to avoid four ordinary English phrases, in three files, in any case, with nothing surfacing the constraint at the point of writing.

It fired for real. On 2026-09-10, #691 documented the **unrelated** `.husky/commit-msg` hook and naturally wrote *"It is **warn-only** by default"*. One regression, two red `main` runs: `3e73be7` (#691, the doc) and `03bdb24` (#697, which inherited the regression — it touches no swept doc). #717 paid the reword tax (`493a656`). The pin landed 2026-09-06; #691 merged 2026-09-10 — **four days to first false positive** — and the pin's own contract comment already predicted recurrence and prescribed the fix itself:

> the tokens are generic warn-phrases, not review-enforcer-scoped — any FUTURE legitimate "warn-only"-vocabulary prose about ANOTHER gate in 01/02/03 must be reworded (**or this list scoped**)

### 1.1 Confirmed problem definition

> **The pin's true invariant is narrower than its implementation: "no WARN-ALLOW claim **about the review-enforcer** may exist in `01/02/03`." The whole-file scan conflates that invariant with "no warn-allow word may appear anywhere in `01/02/03`," and the second is not a property anyone wants — it taxes every other gate's documentation and red-mains `main` for correct prose.**

**Falsification check (properly stated).** The definition is wrong if the pin's protective power requires *whole-file* scope — i.e. if there exists a #485-class re-drift that is **not** a claim about the review-enforcer. There is not: every pinned historical pre-#485 re-drift sentence names the review-enforcer or its tier/dispatch floor (6 of the 7 real pre-#485 corpus sentences are pinned from `e097b38^` — 4 verbatim, 2 abridged — and all 6 are caught by sentence scope alone). The original framing's implicit binary ("scope it, or the pin cannot work") is a false dilemma — the two acceptance criteria are **jointly satisfiable**, and the shipped T2b fixtures prove both simultaneously.

**Confidence: split, because one number was hiding two questions.** **P(problem definition) ≈ 0.95** — the framed problem is correct and the falsification check holds. **P(the shipped change meets AC1 with no unowned false-negative class) ≈ 0.78** — the replacement carries 7 disclosed defects (F1–F7) plus the header-nesting gap (F8) and the T3 inheritance (F9) found in cycle 3, and §6 concedes the Objective quantifier is undelivered. Basis for the second figure: the reproduced #691 red-on-old / green-on-new pair, the 114/0 suite, the corpus-provenance check, and the enumerated defect list — not the earlier unsplit 88.

| Problem framing | Verdict |
|---|---|
| **A. Confirmed** — scope the pin to review-enforcer claims (the invariant it actually protects) | **adopted** |
| **B. Keep blanket scope; rewording docs is policy (#717's remedy, forever)** | rejected — the tax is permanent, invisible, and non-local; it already false-positived in 4 days |
| **C. Delete/disable the pin** (false positives too costly) | rejected — it guards the #485/#513 verdict-tier contract; removing a drift backstop to stop false positives is symptom therapy |
| **D. Authoring-time visibility** (make the constraint visible where docs are written — a visible contract region, a lint, a template) — *surfaced by the Devil's-Advocate verifier, not evaluated in the original session* | **out of scope, declared** — see §1.2 |

**Root-cause honesty (verifier finding, applied).** The original narrative named the harm as the *invisible, non-local constraint* and then defined the problem as the *over-broad scope* — which is the one property the shipped change fixes. Framing D is the remedy aimed at the *stated* harm, and it was never evaluated. It is declared out of scope here rather than silently dropped: the pin is post-merge CI, so this change does **not** make the constraint visible at authoring time, and eight real sections in the swept docs remain scope-constrained invisibly (see §4.3 F4).

### 1.2 Assumptions ledger

| Assumption | Status | Evidence / Falsification |
|---|---|---|
| Every historical pre-#485 re-drift sentence names review-enforcer vocabulary | **[validated]** | the 6 corpus fixtures from `e097b38^`; all are caught by sentence scope alone |
| The `.husky/commit-msg` (#691) sentence must pass under the new pin | **[validated]** | T2b must-PASS fixture "literal #691 hook sentence in its own section" |
| The on-demand-gates line must pass without a carve-out (AC3) | **[validated]** | T2b must-PASS fixture; the real doc line is verbatim |
| The docs' own heading structure is a meaningful topic unit | **[falsified in the flat model — F8]** | `markdownSections` is **flat**: scope vocabulary in a parent heading does **not** reach a child heading's section, so an anaphoric re-drift under a scoped parent passes (the OLD pin caught it). Also silently lost on a heading rename (F4). |
| `OTHER_GATE_SUBJECT_PATTERNS` can be extended cheaply when a legitimate other-gate sentence reds | **[unverified]** | the failure site (the T2 assertion message) does **not** point at the constant — the author is told "re-drift" with no remediation pointer (F3) |
| Inflected ordinary-English forms must be exempted unconditionally (not only in unscoped sentences) | **[unverified]** — and **known-false in the narrow case** | "The review-enforcer micro tier warns only if no reviewer was dispatched." passes; §4.3 F1 |
| `#485`/`#513` verdict-tier coverage is not reduced | **[validated with qualification]** | T1/T1b/T3's existing assertions unchanged; but T3 *gained* a scan loop (§4.1) and the pin is net-weaker on two documented classes (§4.3) |

## 2. Solution alternatives (the three the issue body asked to evaluate, plus one surfaced)

### Option 1 — scope the scan **region** (headings/sections) · **REJECTED**

Anchor the scan to review-enforcer-relevant regions, reusing the region-anchoring machinery the pin already has for `CONTRACT_DOC_PINS`.

**Why rejected (as originally reasoned):** the review-enforcer prose is not separable into stable regions. In `02-commit-pr.md` the claim is embedded **inside** the Micro-tier bullet alongside the VGATE and code-review consequences (L138); in `01-preflight.md` it spans both the Micro Tier table and the Extension Gates section. New heading anchors would add a fresh **red-CI-on-rename invariant** — the false-positive class being removed — and the `02` bullet region would still contain unrelated-gate prose, so the precision gain would be cosmetic.

**Reconciliation (verifier finding, applied).** This rejection is **self-defeating as originally worded**, because the shipped Option 2 *also* depends on file structure: section scope is a function of `markdownSections` + `isReviewEnforcerScoped(section.text)`. The honest distinction is the **failure direction**, not the presence of structure:

| | Option 1 (explicit anchors) | Option 2 as shipped (heading sections) |
|---|---|---|
| Rename/edit the structure | **reds loudly** (anchor-count pin fails) | **silently** loses section scope — no positive assertion that the real docs' sections are still scoped |
| Effect on legitimate other-gate prose | reds (region still contains it) | passes (claim-scoped) |

Option 2's dependency on heading structure is therefore a **real cost**, not zero, and it is recorded as residual F4. *When Option 1 would have been better:* if the anchors were already explicit fences (the repo's own convention — **this file reads** the `<!-- REVIEW-ENFORCER-TIER-RULE -->` fence; the sibling `extensions/verification-gate/index.test.ts` reads `<!-- VGATE-SHAPE-RULE -->`) rather than new heading anchors; a fence-anchored region would fail loudly **and** surface the contract at the point of writing (framing D). That variant was not evaluated in the original session; it is the subject of the follow-up issue in §10.

### Option 2 — **require proximity between the anti-token and review-enforcer vocabulary** · **CHOSEN**

An anti-token counts as a claim only when it reads as a claim *about the review-enforcer*. Keeps the negative anti-token list (so *any* warn phrasing in scope is still caught), adds no **new** anchors, and depends only on the docs' existing heading structure.

**Refinement that shipped (beyond the PR body's summary — §4.2):** proximity is evaluated at **two widths**, because sentence-only leaves the **anaphoric hole** — *"…unless a reviewer was dispatched this session. … The gate is warn-only."*

| Width | Signal | Why |
|---|---|---|
| **SENTENCE** (strong) | the claim's own sentence carries review-enforcer vocabulary (`review-enforcer` / `review enforcer` / `agent-issue-complexity` / `tier_rule` / `micro` / dispatch-floor forms) | sufficient on its own, wherever the sentence sits |
| **SECTION** (contextual) | the enclosing markdown section is *about* the review-enforcer, so a bare warn-allow sentence inside it is that topic's claim | closes the anaphoric hole; the section is the docs' own topic unit |

**Why chosen:** it encodes the invariant the pin actually protects at the granularity of the claim, not the file. It is a **filter, not a mute**: every historical pre-#485 re-drift is sentence-scoped and still fails, while *"the husky hook is warn-only"* names no review-enforcer vocabulary and sits in a section that names none either, so it passes. Option 2 is also the **largest** diff of the three — chosen on outcome quality, not size.

### Option 3 — **invert** to a positive, review-enforcer-scoped phrase list · **REJECTED**

**Why rejected:** strictly weaker. It catches **deletion** of the sanctioned sentence, not the **addition** of a contradicting warn claim — so acceptance criterion 1 could not hold. It also reds on any legitimate editorial improvement to the sanctioned prose, i.e. it **inverts** the false-positive problem instead of removing it. *When it would have been better:* if the goal were a presence pin ("this sentence must exist"), which was never the contract.

### Option 4 — explicit **fence-anchored contract region** (surfaced post-hoc, §2.1) · **NOT EVALUATED**

Adopt the repo's own convention (explicit `<!-- …-RULE -->` fences, loud-on-missing) so the protected region is both anchored *and* visible at the point of writing. Recorded in the ledger as the alternative that would beat Option 2 on framing D and on the anchor axis; deferred to the §10 follow-up rather than retrofitted into this PR.

**Decision:** Option 2 (proximity, two widths). Evaluated on outcome quality — edge-case coverage (anaphora, nested bullets, parentheticals, negations, labels), false-positive elimination (the #691 sentence), and no new anchors — **not** on diff size.

## 3. Rejected-alternatives ledger (what would have changed the decision)

| Rejected | When it WOULD have been better |
|---|---|
| Option 1 (heading regions) | If the region were a **pre-existing explicit fence**. The repo already uses loud, machine-read fences for contract regions; a fence-anchored region would red on rename instead of silently unscoping (§2.1, F4). |
| Option 3 (invert) | If the contract were presence ("this sentence must exist") rather than absence ("no contradicting claim"). |
| **Semantic parsing** | If the residual mixed-subject sentence (*"unlike the review-enforcer, the husky hook is warn-only"*) must pass, or the lookahead exemption must be conditional. Splitting those claims needs a parser; for a drift backstop the conservative direction is to red. |
| Option 4 (fence-anchored region) | Immediately, if authoring-time visibility (§1.1 framing D) were in scope. Declared out of scope; follow-up issue §10. |

Unknowns accepted, **stated accurately** (verifier findings, applied). The other-gate name list (`OTHER_GATE_SUBJECT_PATTERNS`) is open-ended by nature, and a false red on a *new* gate's prose inside a review-enforcer section is detected **post-merge** (the pin runs only in `ci-main.yml`'s `extension-tests` job) and remediated by a test-file change. So the accurate statement is: the list **narrows** the author-facing constraint to a cheap extension point — it does **not** "impose no constraint on future authors". The failure site should name the remediation (F3, §4.3).

**Second unknown, larger (cycle-2 verifier finding — F6).** The escape is consulted **only when the sentence is not itself sentence-scoped** (`if (!sentenceScoped && claimNamesAnotherGate(…))`). Consequently a warn-allow sentence about *another* gate that merely **carries scope vocabulary** reds even when that gate's name IS in the 16-name list: `"At micro, the VGATE check is warn-only."` → **reds**; `"The mutation gate's micro tier is warn-only."` → **reds**. For this class, "add a name to `OTHER_GATE_SUBJECT_PATTERNS`" **cannot** remediate — the escape never runs. §6's Objective shortfall therefore names **both** causes, not only the enumerative one.

## 4. Implementation (what was actually shipped)

### 4.1 Structure

`extensions/review-enforcer/index.test.ts` — runtime-test-only, **+948/−42**. No doc or production-code changes. `SWEPT_DOC_RELS` and `extensions/review-enforcer/index.ts` are untouched.

| Piece | Change |
|---|---|
| `MICRO_WARN_ANTI_TOKENS` | retained; **coverage gain** — inflected re-drift forms added (`warn but does not block`, `warns but do not block`, `warns but does not block`, `warns instead of block`) |
| `MICRO_WARN_ANTI_PATTERNS` | **new** — the two inflections that cannot be plain tokens without a false positive (`warns only` / `only warns`), exempted by a trailing continuation (`when|if|after|before|until|while|because|unless|where|once|as`) |
| `REVIEW_ENFORCER_SCOPE_PATTERNS` | **new** — the scope vocabulary as regexes (a bare `dispatch` would drag unrelated prose such as "the mutation gate dispatches a nightly run" in) |
| `OTHER_GATE_SUBJECT_PATTERNS` | **new** — claim-subject escape: inside a scoped section, a warning whose clause **names a different gate** before the phrase is that gate's prose |
| `claimNamesAnotherGate` + `clauseStartsBefore` + `BARE_ANAPHOR_CLAUSE` / `CLAUSE_BOUNDARY_CHARS` / `CLAUSE_BOUNDARY_WORDS` / `CLAUSE_NOUN_HEAD` | **new** — positional clause analysis (`;:—–,` + coordinating/subordinating boundaries, parentheticals blanked in place); relative `that` clauses cannot escape, complementizer `that` clauses can; bare anaphors borrow the previous clause |
| `markdownSections` / `sectionSentenceUnits` | **new** — markdown headings delimit sections; fenced code blocks handled; hard wraps joined, while table rows / list items / headings / blockquote starts are structural boundaries so a review-enforcer bullet cannot absorb the next bullet |
| `blankHtmlComments` (+ `FenceState` / `nextFenceState`), `findAntiTokenHits` | **new** — comment bodies can neither scope a section nor donate escape words; `findAntiTokenHits` judges each occurrence. **`blankHtmlComments` returns `unterminated`**, and T2 asserts on it: a stray `<!--` would blind the pin to EOF while CI stayed green. A **missing-doc guard** (`existsSync`) fails loudly on file **absence** — it does **not** cover a present-but-emptied/truncated doc (F7). |
| `LEGIT_ON_DEMAND_LINE` | **DELETED** (AC3) — and its per-line strip + anchor-count pin with it. The doc line itself is untouched. Its only remaining *code* referent is the contract comment; a historical plan doc (`2026-09-05-issue-485-micro-dispatch-policy.md`) still names it as narrative. |
| `findMicroWarnClaims` | the single predicate T2 and T2b both exercise (verified: one definition, no parallel copy) |
| `#485 T2b` (**new test**) | two-sided proof: **45 must-FAIL** fixtures and **23 must-PASS** fixtures, plus an end-to-end mixed-document check proving the scope is a filter, not a mute. Must-FAIL includes the **six real pre-#485 corpus sentences** recovered from `e097b38^`. *(Correction: the PR body says "11 must-FAIL / 5 must-PASS"; the final revision has 45/23. 22 of the 23 must-PASS payloads are unique — the entries at ~L2554 and ~L2598 are byte-identical, so one intended case is covered once, not twice.)* |
| `#485 T3` | **MODIFIED (+9 lines)** — the code-side absence scan on `index.ts` now also applies `MICRO_WARN_ANTI_PATTERNS`, so the docs backstop (T2) and the code backstop (T3) cannot diverge on exactly the inflected forms #745 added. T3's existing assertions are unchanged. |

### 4.2 Divergence from the PR body, stated plainly

The PR body describes proximity as **sentence-level**. The shipped implementation evaluates **sentence AND section** (the anaphoric hole). Section scope is a **strict superset** of sentence scope — verified structurally: `findMicroWarnClaims` short-circuits sentence-scoped hits before the escape filter, so every sentence-scoped hit is also a hit under the two-width rule. (The real swept docs currently carry **0** claims, so this is a structural check, not an empirical one on live doc content.) It therefore catches **more, never less**, than the sentence-only description. The user-facing scope claim is unchanged: *only claims about the review-enforcer are in scope.*

**Third divergence (cycle-3 finding, applied):** the PR body lists `dispatch` as part of the proximity vocabulary. The shipped `REVIEW_ENFORCER_SCOPE_PATTERNS` deliberately contains **no bare `dispatch`** — only `0-dispatch` / `no dispatch` / zero-dispatches / `dispatch floor` forms — because a bare `dispatch` would drag unrelated prose ("the mutation gate dispatches a nightly run") into scope. Verified: that sentence is unscoped under the shipped patterns. The PR body's list is therefore **stale on this point** and the plan doc supersedes it; a correction note on the PR is warranted (§10).

### 4.3 Disclosed residuals, defects and bounded false negatives

These are the pin's **actual** contract. R4/R5 and F6 are the price paid for Option 2; F1–F7 are defects that verification found and that are **not fixed by this PR** (code is frozen for this merge — §10 files them).

| # | Class | Behaviour | Status |
|---|---|---|---|
| R1 | mixed-subject sentence | *"unlike the review-enforcer, the husky hook is warn-only"* still **reds** | accepted — splitting claims needs parsing; conservative direction is to red |
| R2 | re-drift in an unscoped section | a warn-allow sentence anaphorically about the review-enforcer but in a different section **passes** | accepted — the section is the topic unit; this *is* the #745 fix |
| R3 | conservative reds | negated claims ("the micro tier is no longer warn-only") and an other-gate subject split from its copula **red** | accepted — same fail-safe direction as the pre-#745 pin, not a regression |
| R4 | bounded parse misses | in a scoped section, an *unpunctuated* leading subordinate clause or a relative-clause inversion **passes** | accepted — the inverse heuristic false-reds equally legitimate prose |
| R5 | other-gate corpus is enumerative | a legitimate warn sentence about a **new** gate inside a review-enforcer section **reds** until its name is added | accepted with correction — remediation is post-merge red → test-file change, and the failure message should name `OTHER_GATE_SUBJECT_PATTERNS` (F3) |
| F1 | inflected continuation, scoped | *"The review-enforcer micro tier **warns only if** no reviewer was dispatched."* **passes** (the `warns only` lookahead is unconditional, including in scoped sentences where the phrase *is* the claim) | **disclosed defect** — fixture-pinned as must-PASS for the ordinary-English form; the scoped-re-drift form is a false negative. Follow-up §10 |
| F2 | `hooks?` escape | in a scoped section, *"The hook is warn-only."* **passes** — `/\bhooks?\b/` is in the escape set, yet the review-enforcer *is* a git-operation hook | **disclosed defect** — not in the pre-#745 residual list; follow-up §10 |
| F3 | failure-site pointer | the T2 assertion says "a #485 micro warn re-drift" with no mention of `OTHER_GATE_SUBJECT_PATTERNS`, so the §3 "cheap extension point" is not discoverable at the point of failure | **disclosed defect** — follow-up §10 |
| F4 | silent scope erasure | the real docs currently contain 0 claims, so T2 only asserts `claims.length === 0`; a heading rename that removes section scope is invisible to CI (no positive "these sections are still scoped" assertion) | **disclosed defect** — follow-up §10 |
| F5 | comment-body blanking | an HTML-comment re-drift is not scanned. This matters: `01-preflight.md` L324 states the tier contract **inside** an HTML comment (`<!-- REVIEW-ENFORCER-TIER-RULE: … -->`) | **disclosed coverage loss** — the pre-#745 pin would have caught a re-drift written into that comment; follow-up §10 |
| **F6** | **sentence scope blocks the escape** | a warn-allow sentence about **another** gate that carries scope vocabulary **reds even when that gate is in the list**: `"At micro, the VGATE check is warn-only."` → **reds**; `"The mutation gate's micro tier is warn-only."` → **reds**. `claimNamesAnotherGate` runs only when the sentence is *not* sentence-scoped, so the documented remediation (add the gate name) **does not apply** | **disclosed defect — this is the #745 harm class, still live.** The artifact's earlier framing ("cheap, bounded extension point") is false for this class; follow-up §10 |
| **F7** | **truncation vacuous pass** | the only vacuous-pass guard is `existsSync`: a **present but emptied/truncated** swept doc passes. Reproduced: empty `02-commit-pr.md` → **114 passed, 0 failed**; put a re-drift in the same file → 113/1 | **disclosed defect** — `01-preflight.md` is incidentally covered by the fence parse; `02`/`03` are not; follow-up §10 |
| **F8** | **flat sections — parent scope does not reach a child heading** | `markdownSections` opens a new section at **every** heading, so scope vocabulary in a `##` heading does not reach a `###` child. Reproduced: `## Review Enforcer Gate…` + `### Notes` + `The gate is warn-only.` → **OLD red / NEW 0 claims**. In markdown a child heading *is* the same topic unit as its parent, so this is the anaphoric-hole class section scope was meant to close — and it is **live-shaped**: `01-preflight.md` has `## Pi Extension Gates (…)` scoped with unscoped children, and `## Tier Detection` scoped with children | **disclosed defect + net coverage loss** — not R2 (whose justification is the topic-unit argument, which this falsifies). Follow-up §10 |
| **F9** | **T3 inherits the F1 lookahead hole** | `#485 T3` runs `MICRO_WARN_ANTI_PATTERNS` globally over `index.ts` with **no sentence/section concept**, so a code comment re-drift in an exempted continuation form passes T3 too: `// micro tier warns only if the marker is absent` → T3 green. §4.1's "cannot diverge" claim holds for the *pattern set* but not for the *exemption semantics* | **disclosed defect** — F1's fix direction (scope-condition the exemption) is not portable to T3 as written; follow-up §10 |

**F1 scope correction (cycle-3 probe).** The exemption is **not** a coverage loss relative to the old pin: `"warns only when"` contained **no** old token as a substring (`warn only` requires `warn` + space), so the old pin passed it too. F1 is a hole in *new* protection, not a regression — corrected here.

**Corpus-provenance precision (cycle-2 verifier finding).** Of the six pinned pre-#485 corpus fixtures, **4 are verbatim** and **2 are abridged/adapted** (the table-row fixture omits the separator row; the `03-code-review` fixture drops a clause). The real pre-#485 corpus contains **7** re-drift sentences; **6 are pinned** — the `02-commit-pr.md` L71 sentence is not. The T2b comment's stronger wording ("the exact sentences … from {01-preflight, 02-commit-pr, 03-code-review}") over-claims and is corrected in #793.

**Net-coverage statement (§5's AC4 qualifies this) — revised for completeness after cycle 3.** The change is **net-weaker than the pre-#745 pin on four classes**: **R2** (re-drift in an unscoped section), **R4** (unpunctuated subordinate clause / relative-clause inversion), **F5** (re-drift written into an HTML comment), and **F8** (anaphoric re-drift under a *child* heading of a scoped parent) — the last two also being genuine coverage losses, not trade-offs. It is **net-stronger on inflected forms and on precision**. That trade is the reason Option 2 was chosen; it is stated here as a trade, not as free coverage, and the list is intended to be exhaustive rather than illustrative.

## 5. Verification (what was actually run)

Command (CI-equivalent): `NODE_ENV=test npx tsx extensions/review-enforcer/index.test.ts` (run from the worktree at the reviewed SHA).

| Scenario | Result |
|---|---|
| baseline `origin/main` | **113 passed, 0 failed** |
| after this change (final revision) | **114 passed, 0 failed** |
| **AC1** append *"The review-enforcer micro tier warns but does not block — 0 dispatches warn only."* to the real `01-preflight.md` | **❌ #485 T2 fails** (113/1) — *"carries 2 review-enforcer warn-allow claim(s) …"* |
| **AC2** restore the exact #691 sentence *"It is **warn-only** by default"* in the real `02-commit-pr.md`, new pin | **✅ 114 passed, 0 failed** |
| **AC2′** same doc under `origin/main`'s pin | **❌ 112 passed, 1 failed** — the historical failure reproduced and closed |
| **AC3** `LEGIT_ON_DEMAND_LINE` | removed — its only remaining *code* referent is the contract comment (a historical plan doc still names it as narrative); on-demand line present verbatim in the doc and pinned as a must-PASS fixture |
| **AC4** `#485`/`#513` verdict-tier contract | T1/T1b/T3's **existing** assertions unchanged; **T3 extended** with the inflected-pattern scan (§4.1) |
| Structural pin (independent) | one `findMicroWarnClaims` definition; T2 and T2b call the same predicate; T3 re-uses the vocabularies by spread (no divergence) |
| Corpus provenance (independent) | 4 of 6 pinned corpus fixtures verbatim in `git show e097b38^`, 2 abridged; all 6 sentence-scoped; 7 real corpus sentences exist, 6 pinned (F-precision, §4.3) |

## 6. Acceptance criteria → disposition

- [~] **AC1** a genuine re-drift still **fails** — **qualified, not complete**: proven for the historical pre-#485 vocabulary (6 real corpus fixtures) and for every punctuated/fixture shape. **Not** universally true — see §4.3 R4/F1 (F1 is a disclosed defect) and F8 (child-heading scope gap).
- [x] **AC2** an unrelated-gate sentence using the same vocabulary **passes** — proven by test (must-PASS fixtures incl. the literal #691 sentence).
- [x] **AC3** the `01-preflight.md` on-demand-gates carve-out line no longer needs a special-case strip — `LEGIT_ON_DEMAND_LINE` deleted; passes structurally at the current doc content (**qualification: F4/R5** — the pass rests on the enclosing section carrying no scope vocabulary, so a future edit to that section can red it).
- [~] **AC4** no reduction in coverage for the `#485`/`#513` verdict-tier contract — the existing T1/T1b/T3 assertions are untouched and the full suite is 114/0. **Net-coverage qualification:** see the revised §4.3 net-coverage statement (**net-weaker on R2, R4, F5 and F8**; T3 also inherits F9).

**Issue Objective, audited honestly.** The issue's Objective says unrelated gates' prose can *"never"* red `main` again. That quantifier is **not** delivered, for **two distinct reasons**: (a) the escape is a bounded 16-name list matched in the clause head, so gates named in the swept docs but absent from the list (`git-lock`, `doc-affiliation`, `wiring-gap`, `freshness`, `skill-enforcement`, `branch-detection`, …) can still red; and (b) **F6** — a warn-allow sentence about another gate that *carries scope vocabulary* reds even when the gate is in the list, because the escape is skipped for sentence-scoped hits, so adding a name cannot remediate it. Realistic restatement: *"unrelated-gate prose no longer reds `main` for the class that caused #745; the constraint is narrowed for a bounded class and remains live for the F6 class."* Recorded as a disclosed shortfall, not silently rounded up.

## 7. Wiring Check

| Touch Point | Type | Covered By | Status |
|---|---|---|---|
| `extensions/review-enforcer/index.test.ts` — `findMicroWarnClaims` predicate | test (unit, the pin) | #778 (`#485 T2`, `#485 T2b`) | ✅ |
| `MICRO_WARN_ANTI_TOKENS` / `MICRO_WARN_ANTI_PATTERNS` | test data | #778; coverage gained (inflected forms) | ✅ |
| `REVIEW_ENFORCER_SCOPE_PATTERNS` / `OTHER_GATE_SUBJECT_PATTERNS` | test data | #778; **no parity test vs `TIER_RULE`** (§10) | ⚠️ |
| `blankHtmlComments` + unterminated-comment guard | test helper + guard | #778; T2 asserts `!unterminated` | ✅ |
| missing-doc (`existsSync`) vacuous-pass guard | test guard | #778; file-absence only — truncation passes vacuously (**F7**) | ⚠️ #793 |
| `SWEPT_DOC_RELS` = commit-workflow `01/02/03` docs | docs (read-only input) | unmodified by #778; absence guarded | ✅ |
| `01-preflight.md` `REVIEW-ENFORCER-TIER-RULE` fence ↔ `TIER_RULE` | test pin (T2, unchanged) | #485; untouched | ✅ |
| `#513` verdict-tier contract (`TIER_RULE`, `clean-micro`) | test pins (T1/T1b, unchanged) | #513; untouched | ✅ |
| `#485 T3` code-side absence scan (`index.ts`) | test pin | **modified** — now also applies `MICRO_WARN_ANTI_PATTERNS` | ✅ |
| CI: `extension-tests / unit-test` (`ci-main.yml`) | pipeline | the job that red-mained on `3e73be7`/`03bdb24`; runs this suite | ✅ |
| `pipeline-compliance` (required status check) | pipeline gate | scoping comment `<!-- issue-scoping: … -->` on #745 (incl. this Wiring table) + this plan doc in the PR diff | ✅ |
| `LEGIT_ON_DEMAND_LINE` carve-out | test constant | **deleted** (AC3); no remaining *code* referent (historical plan doc names it as narrative) | ✅ |
| Production extension behavior (`extensions/review-enforcer/index.ts`) | runtime code | **not touched** — test-only change | ✅ n/a |
| Follow-up findings F1–F5, duplication contract | tech debt in touched area | **#793** — filed as a separate issue (§10), **not absorbed** into this PR | ✅ (filed) |

No DB, API, auth, external-service, or UI touch points. No new dependency.

## 8. External Research (Phase 1.5 artifact)

### Axis Research

> **Trigger assessment: SKIP WITH A NAMED, ACCEPTED RISK — not a clean justified skip.** Axes UX = low (no user-facing surface), Ontology = low (no schema/entity change), **Architecture = low-medium** (above the skip threshold). No third-party dependency is introduced. **Codebase-first precedent scan: verified** — the repo already carries three heading-section extractors and **one pre-existing** sentence splitter (`scripts/check-ask-premerge.cjs` `splitSentences`/`datedSections`/`newestEraSections`, `scripts/check-ask-retrieval.cjs` `status2070Sections`; the second splitter, `sectionSentenceUnits`, is this PR's own) and no shared declaration; this file already reads explicit `<!-- …-RULE -->` contract fences.
>
> **Why this is not a clean skip:** the skill's skip template requires *axes all low* **and** *no novel pattern*. Here Architecture is low-medium and the artifact itself records **no repo precedent for grammar-based scoping** — which the activation rule treats as a ground to **fire**, not to skip. §8's own boundary caveat says the correct action under the medium reading is 1–2 pitfalls-framing queries on regex/grammar claim scoping. **External research was not performed**: the landing session was explicitly `web_search`-restricted by the operator, so the queries could not be run. Recording that as a named accepted risk (with the four parse residuals in §4.3 as the exposure) rather than dressing it up as a justified skip.

### Integration Docs

No dependencies added or modified (no `package.json` change). The only external interface touched is Node's built-in `readFileSync`/`existsSync` and the repo's own test harness — already used throughout this file. N/A beyond that.

## 9. Deferred / not done (explicit)

- **Authoring-time visibility (framing D / Option 4)** is out of scope (§1.1). No mechanism was added that surfaces the constraint where docs are written; the pin remains post-merge CI.
- **F1–F9 and the duplication/architecture findings** are **not fixed in this PR** — code is frozen for this merge; they are filed as **#793** (§10) with the evidence above. They are **not** absorbed silently.
- **The `issue-scoping` Phase 7 parallel review gates** were not run against this *reconstructed* artifact in their original 4-agent shape. What ran instead is recorded verbatim in §11: the two diamond verification gates (`problem-verify`, `solution-verify`), the required duplication/architecture reviewer, and two consolidated re-verification cycles after the findings were applied. The code-side review record is the VGATE dispatch plus the fresh code review recorded against `039f45114b623d4f95e95245de84e71a8a308d9e` (the branch head since then is docs-only).

## 10. Follow-up issue

**daniel-ospina/agent-infra#793** — filed (not absorbed) covering: **F1** the unconditional `warns only`/`only warns` lookahead creating a scoped-sentence false negative; **F2** the `/\bhooks?\b/` escape masking "the hook is warn-only" inside a scoped section; **F3** the failure-site message not naming `OTHER_GATE_SUBJECT_PATTERNS`; **F4** silent section-scope erasure on a heading rename (no positive structural assertion); **F5** HTML-comment blanking not scanning comment bodies (notably the `REVIEW-ENFORCER-TIER-RULE` fence); **F6** the sentence-scope-blocks-the-escape false-positive class (the #745 harm class, still live — a name addition cannot remediate it); **F7** the truncation vacuous pass (the `existsSync` guard covers absence only); **F8** the flat-`markdownSections` gap (parent-heading scope does not reach a child heading — a net coverage loss vs the pre-#745 pin); **F9** T3 inheriting the F1 lookahead hole on the code surface; the **net-coverage trade** (now enumerated as R2/R4/F5/F8); the **T2b corpus-comment over-claim** ("the exact sentences" — 4 of 6 verbatim, 2 abridged, 1 of 7 real corpus sentences unpinned); and the duplication/architecture reviewer's three advisory P1s (sentence/section extractor duplication vs `scripts/check-ask-*.cjs` — `unify-contract-keep-drivers`, parity test needed; `REVIEW_ENFORCER_SCOPE_PATTERNS` reader set with no parity assertion vs `TIER_RULE`; the now-false "acceptance grep is the FLOOR … CI can never green a claim the grep would have caught" comment, falsified by #745's own must-PASS fixture).

## 11. Verification Gates

### problem-verify — 1 cycle, findings applied, re-verified
- **Verifier A** (thoroughness/converge/gaps/research): 1×P1, 5×P2 — phantom `pipeline-compliance` evidence (§7/§8); T3 transcribed as unchanged; missing assumptions ledger; missing confidence score; missing `### Axis Research`; open-ended escape-list over-claim.
- **Verifier B** (Devil's advocate): 5×P1, 3×P2 — root-cause substitution (invisible/non-local constraint ≠ over-broad scope); the Objective's "never" not delivered; **F1** (inflected lookahead FN); **F5** (comment-body blanking); phantom provenance; Option-1 rationale self-defeating; net-weaker coverage unstated.
- **Controller action:** all applied — §1.1/§1.2 restated with framing D declared and the assumptions ledger added; §2.1 Option-1 reconciliation + Option 4 recorded; §3 over-claim corrected; §4.3 F1–F5 disclosed; §5/§6 AC1 qualified and the Objective audited; §6 confidence 88; §7 corrected (T3 modified, `pipeline-compliance` real state, `⚠️` on the un-parity-tested scope set); §8 Axis Research justified-skip emitted; §10 follow-up filed. **No P0/P1 left unaddressed** except the deliberate no-code-change decision (F1–F5 filed, not fixed) — recorded, not ignored.

### solution-verify — 1 cycle, findings applied, re-verified
- **Verifier C**: 1×P0, 2×P1, 3×P3 — phantom `pipeline-compliance` (P0); AC1 unqualified vs §4.3 #4 (P1); "imposes no constraint on future authors" (P1); structure-table omissions (`blankHtmlComments`, `findAntiTokenHits`, guards); stale "shipped/landed" phrasing vs PR-open.
- **Verifier D**: 0×P0/P1, 3×P3, 2×P4 — `hooks?` escape FN (**F2**, not in the residual list); §2 structure-dependency contradiction (**F4**); `blankHtmlComments` omission; corpus-comment overclaims (all 6 sentence-caught; 2 abridged); fixture counts 45/23 and the byte-identical must-PASS duplicate; vacuous-pass guard only covers missing files.
- **Controller action:** applied (see §4.1, §4.3, §5, §6, §7, §9). Two of Verifier D's findings were recorded but **not** applied in cycle 1 and are applied in cycle 3 instead: the truncation vacuous pass (**F7**, §4.3) and the vacuous-pass-guard over-claim in §4.1/§7 — cycle 1 recorded them as "applied", which was inaccurate and is corrected here.

### duplication/architecture reviewer (Phase 5.5, #688) — advisory, `ISSUES`
- 2×P1 duplication (`unify-contract-keep-drivers`) + 1×P1 architecture (stale FLOOR invariant). Verdicts recorded above and in §10. **Tortoise unavailable at review time → `DEGRADED`** (repo-search only). This reviewer never enters the P0/P1 re-dispatch loop and did not fail the gate.

### Re-verification cycle 2 (fresh contexts, consolidated) — **not clean; findings applied in cycle 3**
- **Verifier E** (fidelity/fix-confirmation): confirmed all 10 cycle-1 findings fixed (T3, ledger/confidence/Axis Research, root-cause honesty, the over-claim, AC1 qualification, Option-1 reconciliation, 45/23 counts + duplicate, "one regression/two red runs", net-coverage trade + F1/F2/F5 reproduced); **re-raised the phantom `pipeline-compliance` comment as still-open** (the row had been corrected in §8 only, not §7) — plus a nit that the code comment at ~L1872 still says the escape list "imposes no constraint".
- **Verifier F** (Devil's advocate): found **F6** (sentence scope blocks the escape — a live false-positive class the artifact had not disclosed, with a false remediation claim), **F7** (truncation vacuous pass, mis-recorded as "applied"), the Axis Research skip's preconditions not being met (Architecture low-medium + no repo precedent ⇒ a *fire* condition), corpus-provenance overstatement (4 verbatim / 2 abridged; 7 real sentences, 6 pinned; the "on real docs" check is vacuous at 0 claims), the reviewed-SHA mis-statement, and a `LEGIT_ON_DEMAND_LINE` grep overstatement.
- **Controller action (cycle 3):** all applied in this revision — §3 second-unknown paragraph, §4.3 F6/F7 + corpus-provenance precision, §6 Objective audit naming both causes, §8 relabelled **skip with a named accepted risk** (web-search-restricted session) + corrected precedent count, §9/§10 extended to F7 + the corpus over-claim, §5/§7 wording qualified, header reviewed-SHA corrected. The one P0 (phantom comment) is resolved **by posting the scoping comment on #745** — this comment — which is what `check-pipeline-compliance.sh` check (b) reads; §7's row is true as of that post and is re-verified against the live issue state, not asserted.

### Re-verification cycle 3 (fresh contexts, adversarial) — **not clean; findings applied in this revision, then escalated**
- **Verifier G** (fix-confirmation): confirmed all seven cycle-2 findings genuinely fixed, and confirmed every spot-checked claim (diff `+948/−42`, 45/23 counts + the byte-identical must-PASS duplicate, T3 `+9`, `LEGIT_ON_DEMAND_LINE` referents, the two-width superset, suite 114/0) — but did **not** return the clean verdict because of two documentation-precision errors: a claimed duplicate in the `MICRO_WARN_ANTI_TOKENS` enumeration (**false positive** — verified: the four entries are distinct; no change needed) and the `<!-- VGATE-SHAPE-RULE -->` fence attribution (**correct** — that fence is read by the sibling `verification-gate` test, not this file; fixed in §2.1).
- **Verifier H** (adversarial): found a **new class not in F1–F7** — **F8**, `markdownSections` is flat, so scope vocabulary in a parent heading does not reach a child heading; an anaphoric re-drift under a scoped parent passes while the OLD pin caught it (reproduced). Also: **F9** (T3 inherits F1's lookahead hole with no sentence/section concept), the net-coverage statement being non-exhaustive (it omitted F5 and F8), confidence 88 being asserted rather than derived, AC1/AC4 `[x]` contradicting their own prose, and the PR body's `dispatch`-vocabulary claim being stale (the shipped patterns deliberately exclude bare `dispatch`). It also **falsified** the hypothesis that the `warns only` exemption is a coverage loss vs the old pin (the old pin did not catch it either) — that correction strengthens F1's characterisation.
- **Controller action (this revision):** applied — §4.3 **F8/F9** disclosed with probes, the net-coverage statement revised to enumerate R2/R4/F5/F8 as exhaustive, confidence **split** into P(problem)≈0.95 / P(shipped change clean)≈0.78, AC1/AC4 marked `[~]`, the `dispatch` divergence added to §4.2, the F1-not-a-regression correction added, §1.1 cross-reference and the fence attribution corrected, §9/§10 extended to F9.
- **STALL / ESCALATION (honest-stop).** Three verification cycles have each surfaced a **new class** rather than converging (cycle 1: 6 findings; cycle 2: the phantom P0 + F6/F7; cycle 3: F8/F9 + accounting/confidence/honesty items). Every one of them is a **pin-residual** finding, and the code is frozen for this merge by explicit operator instruction, so they route to **#793** rather than being fixed here. Applying them is a documentation exercise with no natural convergence point, and the operator's stated priority is the merge over further polish. **The loop is therefore stopped after cycle 3 as an escalation exit, not a clean exit** — no clean verdict was returned, the remaining findings are the code-freeze set (now F1–F9) tracked in #793, and cycle 3's documentation fixes have **not** been re-reviewed at the time of writing. This is recorded, not glossed: `issue-scoping` did not converge clean, and the last reviewer response was not `NO ISSUES FOUND`.

## 12. Complexity

| Domain | Rating |
|---|---|
| UX | low (no user-facing surface) |
| Ontology | low (no schema/entity change) |
| Architecture | low-medium (single test file; local clause/section machinery; **no repo precedent for grammar-based scoping**) |
| Tier | standard (label `complexity:standard`; the skill's Micro→Standard override fires on the `extensions/` path) |
