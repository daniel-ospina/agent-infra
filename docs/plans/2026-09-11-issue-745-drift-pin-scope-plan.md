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
**Status:** implemented and committed on PR #778 (**open** at the reviewed SHA). Scope reconstructed from the shipped code + PR record, then verified by the `issue-scoping` gates (cycle log in §11).

> **Provenance note.** The code work on PR #778 preceded this plan doc (the `pipeline-compliance` artifact gate is what required it). Every alternative, rejection rationale, and verification result below is transcribed from the real record — the issue body's three candidate directions, the PR's convergence reasoning, the committed diff, and the live test run — and carries its evidence. Where the shipped implementation **diverged** from the PR body's summary, or where verification **found a defect**, that is called out explicitly (§4.2, §4.3, §10, §11) rather than smoothed over. The PR body's own figures (`+186/−40`, "11 must-FAIL / 5 must-PASS") are from a **superseded revision** and are not reproduced here; the counts in this doc are measured from the final code.

---

## 1. Problem

The `#485 T2` drift pin in `extensions/review-enforcer/index.test.ts` forbade four **ordinary English warn phrases** — `warn-only`, `warn only`, `warn but do not block`, `warn instead of block` — case-insensitively, across all of commit-workflow `01/02/03` (`SWEPT_DOC_RELS`). Blanket scope put an **invisible, non-local constraint on every gate's documentation**: any author describing *any other* gate had to avoid four ordinary English phrases, in three files, in any case, with nothing surfacing the constraint at the point of writing.

It fired for real. On 2026-09-10, #691 documented the **unrelated** `.husky/commit-msg` hook and naturally wrote *"It is **warn-only** by default"*. One regression, two red `main` runs: `3e73be7` (#691, the doc) and `03bdb24` (#697, which inherited the regression — it touches no swept doc). #717 paid the reword tax (`493a656`). The pin landed 2026-09-06; #691 merged 2026-09-10 — **four days to first false positive** — and the pin's own contract comment already predicted recurrence and prescribed the fix itself:

> the tokens are generic warn-phrases, not review-enforcer-scoped — any FUTURE legitimate "warn-only"-vocabulary prose about ANOTHER gate in 01/02/03 must be reworded (**or this list scoped**)

### 1.1 Confirmed problem definition

> **The pin's true invariant is narrower than its implementation: "no WARN-ALLOW claim **about the review-enforcer** may exist in `01/02/03`." The whole-file scan conflates that invariant with "no warn-allow word may appear anywhere in `01/02/03`," and the second is not a property anyone wants — it taxes every other gate's documentation and red-mains `main` for correct prose.**

**Falsification check (properly stated).** The definition is wrong if the pin's protective power requires *whole-file* scope — i.e. if there exists a #485-class re-drift that is **not** a claim about the review-enforcer. There is not: every historical pre-#485 re-drift sentence names the review-enforcer or its tier/dispatch floor (proven by the six corpus fixtures recovered from `e097b38^`, all of which are caught by sentence scope alone). The original framing's implicit binary ("scope it, or the pin cannot work") is a false dilemma — the two acceptance criteria are **jointly satisfiable**, and the shipped T2b fixtures prove both simultaneously.

**Confidence: 88/100.** Basis: the reproduced #691 red-on-old / green-on-new pair, the 114/0 suite, and the six-fixture corpus provenance check. The residual 12 is §4.3 + §10 — the deliberate imperfections in the *replacement*, not doubt about the problem statement.

| Problem framing | Verdict |
|---|---|
| **A. Confirmed** — scope the pin to review-enforcer claims (the invariant it actually protects) | **adopted** |
| **B. Keep blanket scope; rewording docs is policy (#717's remedy, forever)** | rejected — the tax is permanent, invisible, and non-local; it already false-positived in 4 days |
| **C. Delete/disable the pin** (false positives too costly) | rejected — it guards the #485/#513 verdict-tier contract; removing a drift backstop to stop false positives is symptom therapy |
| **D. Authoring-time visibility** (make the constraint visible where docs are written — a visible contract region, a lint, a template) — *surfaced by the Devil's-Advocate verifier, not evaluated in the original session* | **out of scope, declared** — see §1.2 |

**Root-cause honesty (verifier finding, applied).** The original narrative named the harm as the *invisible, non-local constraint* and then defined the problem as the *over-broad scope* — which is the one property the shipped change fixes. Framing D is the remedy aimed at the *stated* harm, and it was never evaluated. It is declared out of scope here rather than silently dropped: the pin is post-merge CI, so this change does **not** make the constraint visible at authoring time, and eight real sections in the swept docs remain scope-constrained invisibly (see §4.3 F5).

### 1.2 Assumptions ledger

| Assumption | Status | Evidence / Falsification |
|---|---|---|
| Every historical pre-#485 re-drift sentence names review-enforcer vocabulary | **[validated]** | the 6 corpus fixtures from `e097b38^`; all are caught by sentence scope alone |
| The `.husky/commit-msg` (#691) sentence must pass under the new pin | **[validated]** | T2b must-PASS fixture "literal #691 hook sentence in its own section" |
| The on-demand-gates line must pass without a carve-out (AC3) | **[validated]** | T2b must-PASS fixture; the real doc line is verbatim |
| The docs' own heading structure is a meaningful topic unit | **[unverified]** | plausible and load-bearing: `markdownSections` scope is *silently* lost on a heading rename (F4) |
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

Option 2's dependency on heading structure is therefore a **real cost**, not zero, and it is recorded as residual F4. *When Option 1 would have been better:* if the anchors were already explicit fences (the repo's own convention — this file already reads `<!-- REVIEW-ENFORCER-TIER-RULE -->` and `<!-- VGATE-SHAPE-RULE -->` fences) rather than new heading anchors; a fence-anchored region would fail loudly **and** surface the contract at the point of writing (framing D). That variant was not evaluated in the original session; it is the subject of the follow-up issue in §10.

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

Unknowns accepted, **stated accurately** (verifier finding, applied). The other-gate name list (`OTHER_GATE_SUBJECT_PATTERNS`) is open-ended by nature, and a false red on a *new* gate's prose inside a review-enforcer section is detected **post-merge** (the pin runs only in `ci-main.yml`'s `extension-tests` job) and remediated by a test-file change. So the accurate statement is: the list **narrows** the author-facing constraint to a cheap extension point — it does **not** "impose no constraint on future authors". The failure site should name the remediation (F3, §4.3).

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
| `blankHtmlComments` (+ `FenceState` / `nextFenceState`), `findAntiTokenHits` | **new** — comment bodies can neither scope a section nor donate escape words; `findAntiTokenHits` judges each occurrence. **`blankHtmlComments` returns `unterminated`**, and T2 asserts on it: a stray `<!--` would blind the pin to EOF while CI stayed green. A **missing-doc guard** (`existsSync`) fails loudly rather than passing vacuously. |
| `LEGIT_ON_DEMAND_LINE` | **DELETED** (AC3) — and its per-line strip + anchor-count pin with it. The doc line itself is untouched. |
| `findMicroWarnClaims` | the single predicate T2 and T2b both exercise (verified: one definition, no parallel copy) |
| `#485 T2b` (**new test**) | two-sided proof: **45 must-FAIL** fixtures and **23 must-PASS** fixtures, plus an end-to-end mixed-document check proving the scope is a filter, not a mute. Must-FAIL includes the **six real pre-#485 corpus sentences** recovered from `e097b38^`. *(Correction: the PR body says "11 must-FAIL / 5 must-PASS"; the final revision has 45/23. 22 of the 23 must-PASS payloads are unique — the entries at ~L2554 and ~L2598 are byte-identical, so one intended case is covered once, not twice.)* |
| `#485 T3` | **MODIFIED (+9 lines)** — the code-side absence scan on `index.ts` now also applies `MICRO_WARN_ANTI_PATTERNS`, so the docs backstop (T2) and the code backstop (T3) cannot diverge on exactly the inflected forms #745 added. T3's existing assertions are unchanged. |

### 4.2 Divergence from the PR body, stated plainly

The PR body describes proximity as **sentence-level**. The shipped implementation evaluates **sentence AND section** (the anaphoric hole). Section scope is a **strict superset** of sentence scope — verified empirically: `findMicroWarnClaims` short-circuits sentence-scoped hits before the escape filter, and on all three real swept docs no sentence-only hit is dropped. So it catches **more, never less**, than the sentence-only description. The user-facing scope claim is unchanged: *only claims about the review-enforcer are in scope.*

### 4.3 Disclosed residuals, defects and bounded false negatives

These are the pin's **actual** contract. Residuals 4 and 5 are the price paid for Option 2; F1–F3 are defects that verification found and that are **not fixed by this PR** (code is frozen for this merge — §10 files them).

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

**Net-coverage statement (§5's AC4 qualifies this):** the change is **net-weaker than the pre-#745 pin on R2 and R4** (both previously caught by definition — the old scan had no notion of topic at all), and it is **net-stronger on inflected forms and on precision**. That trade is the reason Option 2 was chosen; it is stated here as a trade, not as free coverage.

## 5. Verification (what was actually run)

Command (CI-equivalent): `NODE_ENV=test npx tsx extensions/review-enforcer/index.test.ts` (run from the worktree at the reviewed SHA).

| Scenario | Result |
|---|---|
| baseline `origin/main` | **113 passed, 0 failed** |
| after this change (final revision) | **114 passed, 0 failed** |
| **AC1** append *"The review-enforcer micro tier warns but does not block — 0 dispatches warn only."* to the real `01-preflight.md` | **❌ #485 T2 fails** (113/1) — *"carries 2 review-enforcer warn-allow claim(s) …"* |
| **AC2** restore the exact #691 sentence *"It is **warn-only** by default"* in the real `02-commit-pr.md`, new pin | **✅ 114 passed, 0 failed** |
| **AC2′** same doc under `origin/main`'s pin | **❌ 112 passed, 1 failed** — the historical failure reproduced and closed |
| **AC3** `LEGIT_ON_DEMAND_LINE` | removed (`grep` → comment reference only); on-demand line present verbatim in the doc and pinned as a must-PASS fixture |
| **AC4** `#485`/`#513` verdict-tier contract | T1/T1b/T3's **existing** assertions unchanged; **T3 extended** with the inflected-pattern scan (§4.1) |
| Structural pin (independent) | one `findMicroWarnClaims` definition; T2 and T2b call the same predicate; T3 re-uses the vocabularies by spread (no divergence) |
| Corpus provenance (independent) | all 6 corpus fixtures verified present in `git show e097b38^` docs; all 6 are sentence-scoped |

## 6. Acceptance criteria → disposition

- [x] **AC1** a genuine re-drift still **fails** — **qualified**: proven for the historical pre-#485 vocabulary (6 real corpus fixtures) and for every punctuated/fixture shape. **Not** universally true — see §4.3 R4/F1 (accepted bounded mis-parses; F1 is a disclosed defect).
- [x] **AC2** an unrelated-gate sentence using the same vocabulary **passes** — proven by test (must-PASS fixtures incl. the literal #691 sentence).
- [x] **AC3** the `01-preflight.md` on-demand-gates carve-out line no longer needs a special-case strip — `LEGIT_ON_DEMAND_LINE` deleted; passes structurally at the current doc content (**qualification: F4/R5** — the pass rests on the enclosing section carrying no scope vocabulary, so a future edit to that section can red it).
- [x] **AC4** no reduction in coverage for the `#485`/`#513` verdict-tier contract — the existing T1/T1b/T3 assertions are untouched and the full suite is 114/0. **Net-coverage qualification:** see the §4.3 net-coverage statement (net-weaker on R2/R4 by design).

**Issue Objective, audited honestly.** The issue's Objective says unrelated gates' prose can *"never"* red `main` again. That quantifier is **not** delivered: the escape is a bounded 16-name list matched in the clause head, and gates named in the swept docs but absent from the list (`git-lock`, `doc-affiliation`, `wiring-gap`, `freshness`, `skill-enforcement`, `branch-detection`, …) can still red. Realistic restatement: *"unrelated-gate prose no longer reds `main` for the class that caused #745, and the constraint is narrowed to a cheap, bounded extension point."* Recorded as a disclosed shortfall, not silently rounded up.

## 7. Wiring Check

| Touch Point | Type | Covered By | Status |
|---|---|---|---|
| `extensions/review-enforcer/index.test.ts` — `findMicroWarnClaims` predicate | test (unit, the pin) | #778 (`#485 T2`, `#485 T2b`) | ✅ |
| `MICRO_WARN_ANTI_TOKENS` / `MICRO_WARN_ANTI_PATTERNS` | test data | #778; coverage gained (inflected forms) | ✅ |
| `REVIEW_ENFORCER_SCOPE_PATTERNS` / `OTHER_GATE_SUBJECT_PATTERNS` | test data | #778; **no parity test vs `TIER_RULE`** (§10) | ⚠️ |
| `blankHtmlComments` + unterminated-comment guard | test helper + guard | #778; T2 asserts `!unterminated` | ✅ |
| missing-doc (`existsSync`) vacuous-pass guard | test guard | #778; T2 fails loudly | ✅ |
| `SWEPT_DOC_RELS` = commit-workflow `01/02/03` docs | docs (read-only input) | unmodified by #778; absence guarded | ✅ |
| `01-preflight.md` `REVIEW-ENFORCER-TIER-RULE` fence ↔ `TIER_RULE` | test pin (T2, unchanged) | #485; untouched | ✅ |
| `#513` verdict-tier contract (`TIER_RULE`, `clean-micro`) | test pins (T1/T1b, unchanged) | #513; untouched | ✅ |
| `#485 T3` code-side absence scan (`index.ts`) | test pin | **modified** — now also applies `MICRO_WARN_ANTI_PATTERNS` | ✅ |
| CI: `extension-tests / unit-test` (`ci-main.yml`) | pipeline | the job that red-mained on `3e73be7`/`03bdb24`; runs this suite | ✅ |
| `pipeline-compliance` (required status check) | pipeline gate | scoping comment `<!-- issue-scoping: … -->` on #745 (incl. this Wiring table) + this plan doc in the PR diff | ✅ |
| `LEGIT_ON_DEMAND_LINE` carve-out | test constant | **deleted** (AC3); no other referent (`grep`) | ✅ |
| Production extension behavior (`extensions/review-enforcer/index.ts`) | runtime code | **not touched** — test-only change | ✅ n/a |
| Follow-up findings F1–F5, duplication contract | tech debt in touched area | **#793** — filed as a separate issue (§10), **not absorbed** into this PR | ✅ (filed) |

No DB, API, auth, external-service, or UI touch points. No new dependency.

## 8. External Research (Phase 1.5 artifact)

### Axis Research

> **Trigger assessment:** axes UX = low (no user-facing surface), Ontology = low (no schema/entity change), **Architecture = low-medium** at the trigger boundary — the change introduces a markdown/grammar claim-scoping heuristic, but it is confined to one test file with in-repo precedent for the *pattern kind* (`CONTRACT_DOC_PINS` explicit region anchoring, and the T2/T3 pins themselves, in the same file). **No third-party dependency** is introduced. **Codebase-first precedent scan: verified** — the repo already has three heading-section extractors and two sentence splitters (`scripts/check-ask-premerge.cjs` `splitSentences`/`datedSections`/`newestEraSections`, `scripts/check-ask-retrieval.cjs` `status2070Sections`) and no shared declaration; the file already reads explicit contract fences. External research **not demonstrated** — a justified skip per the activation rule, with the boundary cases named rather than assumed.
>
> **Boundary caveat (verifier finding, applied):** the *grammar-based* scoping rule has no repo precedent (the existing extractors are simpler), and it carries the four documented parse residuals in §4.3. If the Architecture rating is read as `medium`, the correct action would be 1–2 pitfalls-framing queries on regex/grammar claim scoping — not done here. Recorded rather than hidden.

### Integration Docs

No dependencies added or modified (no `package.json` change). The only external interface touched is Node's built-in `readFileSync`/`existsSync` and the repo's own test harness — already used throughout this file. N/A beyond that.

## 9. Deferred / not done (explicit)

- **Authoring-time visibility (framing D / Option 4)** is out of scope (§1.1). No mechanism was added that surfaces the constraint where docs are written; the pin remains post-merge CI.
- **F1–F5 and the duplication/architecture findings** are **not fixed in this PR** — code is frozen for this merge; they are filed as **#793** (§10) with the evidence above. They are **not** absorbed silently.
- **The `issue-scoping` Phase 7 parallel review gates** were not run against this *reconstructed* artifact in their original 4-agent shape. What ran instead is recorded verbatim in §11: the two diamond verification gates (`problem-verify`, `solution-verify`), the required duplication/architecture reviewer, and a consolidated re-verification cycle after the findings were applied. The code-side review record is the VGATE dispatch plus the fresh code review on the final head SHA.

## 10. Follow-up issue

**daniel-ospina/agent-infra#793** — filed (not absorbed) covering: **F1** the unconditional `warns only`/`only warns` lookahead creating a scoped-sentence false negative; **F2** the `/\bhooks?\b/` escape masking "the hook is warn-only" inside a scoped section; **F3** the failure-site message not naming `OTHER_GATE_SUBJECT_PATTERNS`; **F4** silent section-scope erasure on a heading rename (no positive structural assertion); **F5** HTML-comment blanking not scanning comment bodies (notably the `REVIEW-ENFORCER-TIER-RULE` fence); the **net-coverage trade** on R2/R4; and the duplication/architecture reviewer's three advisory P1s (sentence/section extractor duplication vs `scripts/check-ask-*.cjs` — `unify-contract-keep-drivers`, parity test needed; `REVIEW_ENFORCER_SCOPE_PATTERNS` reader set with no parity assertion vs `TIER_RULE`; the now-false "acceptance grep is the FLOOR … CI can never green a claim the grep would have caught" comment, falsified by #745's own must-PASS fixture).

## 11. Verification Gates

### problem-verify — 1 cycle, findings applied, re-verified
- **Verifier A** (thoroughness/converge/gaps/research): 1×P1, 5×P2 — phantom `pipeline-compliance` evidence (§7/§8); T3 transcribed as unchanged; missing assumptions ledger; missing confidence score; missing `### Axis Research`; open-ended escape-list over-claim.
- **Verifier B** (Devil's advocate): 5×P1, 3×P2 — root-cause substitution (invisible/non-local constraint ≠ over-broad scope); the Objective's "never" not delivered; **F1** (inflected lookahead FN); **F5** (comment-body blanking); phantom provenance; Option-1 rationale self-defeating; net-weaker coverage unstated.
- **Controller action:** all applied — §1.1/§1.2 restated with framing D declared and the assumptions ledger added; §2.1 Option-1 reconciliation + Option 4 recorded; §3 over-claim corrected; §4.3 F1–F5 disclosed; §5/§6 AC1 qualified and the Objective audited; §6 confidence 88; §7 corrected (T3 modified, `pipeline-compliance` real state, `⚠️` on the un-parity-tested scope set); §8 Axis Research justified-skip emitted; §10 follow-up filed. **No P0/P1 left unaddressed** except the deliberate no-code-change decision (F1–F5 filed, not fixed) — recorded, not ignored.

### solution-verify — 1 cycle, findings applied, re-verified
- **Verifier C**: 1×P0, 2×P1, 3×P3 — phantom `pipeline-compliance` (P0); AC1 unqualified vs §4.3 #4 (P1); "imposes no constraint on future authors" (P1); structure-table omissions (`blankHtmlComments`, `findAntiTokenHits`, guards); stale "shipped/landed" phrasing vs PR-open.
- **Verifier D**: 0×P0/P1, 3×P3, 2×P4 — `hooks?` escape FN (**F2**, not in the residual list); §2 structure-dependency contradiction (**F4**); `blankHtmlComments` omission; corpus-comment overclaims (all 6 sentence-caught; 2 abridged); fixture counts 45/23 and the byte-identical must-PASS duplicate; vacuous-pass guard only covers missing files.
- **Controller action:** all applied (see §4.1, §4.3, §5, §6, §7, §9).

### duplication/architecture reviewer (Phase 5.5, #688) — advisory, `ISSUES`
- 2×P1 duplication (`unify-contract-keep-drivers`) + 1×P1 architecture (stale FLOOR invariant). Verdicts recorded above and in §10. **Tortoise unavailable at review time → `DEGRADED`** (repo-search only). This reviewer never enters the P0/P1 re-dispatch loop and did not fail the gate.

### Re-verification (post-fix) — 1 consolidated cycle
- Dispatched after the findings above were applied; result recorded with the scoping comment. Cycle log and remaining issues (if any) are stated in the issue comment, not asserted clean here.

## 12. Complexity

| Domain | Rating |
|---|---|
| UX | low (no user-facing surface) |
| Ontology | low (no schema/entity change) |
| Architecture | low-medium (single test file; local clause/section machinery; **no repo precedent for grammar-based scoping**) |
| Tier | standard (label `complexity:standard`; the skill's Micro→Standard override fires on the `extensions/` path) |
