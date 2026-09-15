---
title: "#903 — stop the unbounded issue emission (measure-against-main + consequence bar) — Scope & Plan"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-09-15
aboutSubjects: organisation-design-team, proportional-gates, commit-workflow, using-git-worktrees
aboutObjects: agent-infra, issue-903, issue-900, issue-906, issue-937
---

<!-- research-path: docs/plans/2026-09-15-issue-903-issue-emission.md -->

# Plan — #903: stop the unbounded issue emission

> **For Pi:** Use `executing-plans` to implement this plan task-by-task.

**Goal:** Land interventions 1 and 2 of #903 as policy prose only — (1) a measurement claim
must name the revision it measured, measured against `origin/main` not the hub; (2) every
reviewer finding in an engineering delivery-pipeline review gate must declare a
`consequence:` or it is advisory: not blocking, not counted toward the gate, and not filed
as an issue.

**Team:** organisation-design-team

**Architecture:** Prose-only edits across skill/policy markdown. No code, no new scripts, no
new guards, no new tests for the bound (§6 of #903 is explicit: bounds belong in policy prose,
and the last attempt to encode one in code — PR #868 — cost 4 review cycles and 979 lines of pins).

**Issue:** #903 (`complexity:standard`, `team:organisation-design-team`, Level: task)
**Branch:** `fix/903-issue-emission` (worktree `.worktrees/fix-903-issue-emission`, from `origin/main` @ 6b25167)
**Tier:** standard → `task-workflow-standard`; reviewers per `proportional-gates` §Review Cycles (Low–Medium → 2)
**Research-path:** justified-skip. Axes all low (internal policy prose; no UX/ontology/architecture change; no third-party deps; no novel pattern — the change extends existing policy homes). No external queries.

---

## 1. Scope (double diamond)

### 1.1 Confirmed problem

Issue creation is structurally diverging: average emission is ≥ 1 issue per unit of work, so the
queue cannot reach steady state whichever individual bug is fixed. The *cause* is confounded
(#903 §2: a model alias switch, a new reviewer, and a review-cap removal landed within ~2 hours)
and **this plan does not resolve it** — §5 of the issue states none of the interventions depends
on that answer.

Two **independent structural defects** are established and are what this plan fixes. (A third,
Defect A, is named and explicitly deferred in §1.3.)

1. **Measurements describe the wrong revision.** An agent's default `cwd` is the shared hub, which
   is routinely behind `origin/main`. A guard/test run there asserts a smaller floor and returns an
   unqualified pass describing a revision nobody asked about (#900). The issue's own author and a
   verification sub-agent both cited `plan-review:112` — a rule already deleted from main by #884 —
   *inside the document about this problem*.

2. **Findings do not pay for themselves.** A reviewer finding that names no consequence is
   indistinguishable from noise, yet it blocks the gate and can be filed as an issue.

   **Load-bearing evidence** is cycle-level and local: in the session #903 measured, review cycles
   3–6 found only comment-prose inaccuracies while the one real product bug arrived in cycle 1.
   `[inherited — recorded in #903's own body; not independently re-derived. The "only comment-prose"
   classification carries the conclusion and is the unverified element.]`

   **Supporting (inherited, unverified).** The controller reported that of the 322 issues filed
   09-07…09-13, **54%** declared a consequence and **35%** gave a reproduction. This plan does
   **not** re-derive it: the figure rests on a human coding rule over hand-read bodies, and a
   keyword re-scan of the same 322 gives ~12% / ~26% because "consequence" is a *concept*, not a
   token. **Method as reported:** all issues created 2026-09-07…2026-09-13 inclusive (denominator
   322, excluding the 09-14/15 session), hand-coded for "declares what breaks and who observes it"
   and "gives a reproduction". **The revision it was measured against is not recorded — which is
   itself the defect intervention 1 exists to name.** `[unverified]`; no conclusion here depends on
   it — defect 2 stands on the cycle evidence alone.

### 1.2 Alternative framings considered

| Framing | Verdict |
|---|---|
| "The model emits more" | Not actionable and explicitly out of scope (#903 §5). No intervention depends on it. |
| "WIP-limit the queue (no new issue while open > closed)" | Rejected in #903 itself — a poor heuristic, gameable, and it fights the auto-continue rule. |
| "Bound review cycles in code" | Rejected by #903 §6 and by PR #868's own history. |
| **"Emission is not the defect — the review architecture is."** | Generated here, not taken from the body. **Rejected on scope, not merit:** its actionable form is intervention 4 ("declare review depth before reviewing"), which #903 §5 lists as **not approved**, and which the prose-only constraint of §6 cannot deliver here. It is *genuinely falsifiable* — §1.2.2 adopts a falsifier targeting exactly this hypothesis, and if that falsifier fires this framing becomes the correct one. |
| "Structural: findings must declare consequence; measurements must name their revision" | **Adopted** — re-derived from the two established defects, not inherited. #903's intervention 2 stated one reading; this plan re-derived the emission-control reading (§4.2) and corrected the issue's own file count (§4.3), which is the evidence it was re-derived rather than copied. |

### 1.2.1 Assumptions

| Assumption | Status | Evidence | Falsifier |
|---|---|---|---|
| An agent's default `cwd` is the shared hub | **[validated]** | `AGENTS.md`; the hub is this task's session cwd | A session started in a worktree with no hub on the path |
| The hub is routinely behind `origin/main` | **[validated]** (rule) / **[unverified]** (today) | #900 reproduced a 17-commits-behind hub; **today the hub is 0 behind** | A hub that is never behind in practice — then the rule is prophylactic, not corrective |
| A finding that cannot name a consequence is noise | **[inherited — unverified]** | #903 cycles 3–6 found only comment-prose inaccuracies (§1.1; classification not re-derived) | A consequence-less finding that later proves to be a real defect |
| Reviewers will emit `consequence:` when required | **[unverified]** | No prior art in this repo | A gate's reviewers return findings without the field after the schema edit — the §4.4 conformance floor |
| The 2.3x rate jump is attributable to the model | **[unverified] — and explicitly not claimed** | Confounded (§2); #903 §5 says no intervention depends on it | An unconfounded rate decomposition |
| Intervention 3's dedup is live on `main` | **[validated]** | §2: `ci-main.yml` L398–400 SHA-free; 2 open duplicates remain | A post-fix `main build by merge (<sha>)` issue |

### 1.2.2 Falsification check and confidence

**Falsifier:** this problem definition is wrong if the emission rate is driven by the *volume of
review surfaces* rather than by consequence-less findings — i.e. if issues continue to be filed at
the same rate after the consequence bar lands, **with a consequence declared on every one**. That
outcome confirms the rejected §1.2 framing: the defect is the number of gates, not the quality of
findings.

**Confidence: 70.** Above the Phase-2 human-gate threshold (<50), below certainty — the confound is
real and the supporting statistic is `[unverified]`. The two defects are independently established;
what is uncertain is the *sufficiency* of the fix, and §6's prose-only constraint caps how much this
change can prove.

### 1.3 What this plan does NOT do

- **Intervention 3 is already done** (see §2). Verify and report only; no re-implementation.
- **§7 (auto-continue vs bounded queue) is not ours to resolve.** Owner = this task's controller;
  artifact = a "Decision needed" section in the #903 PR body; trigger = if unanswered at merge,
  re-raise on #903 within 24h.
- **No code bound.** §6 forbids implementing the cap in a script.
- **Defect A (the `AGENTS.md` auto-file rule) is not absorbed.** `AGENTS.md:27`'s auto-file rule
  ("bug, workflow gap, missed edge case, or improvement opportunity → file a GitHub issue
  immediately") has no admission control and is **already filed as #906**. The interaction is stated
  so the emission path is not left half-closed: the consequence bar is scoped to findings raised
  *inside a review gate*, not to an agent discovering a defect while working; `AGENTS.md:27` still
  governs the latter. Closing that path requires #906, out of scope here.
- **The scope is deliberately narrowed (§4.3).** An unbounded "every gate that emits findings" would
  reach ~50 files across the vision/identity/content/carousel domains. Editing 50 files for a
  one-rule change is itself the pattern #903 §5 ranks last ("stop building meta-tooling that is
  cheap to build and expensive to own"), so the rule is bounded to the gates that form the
  **engineering delivery pipeline #903 measured** — and the excluded set is named, not silently
  dropped.

---

## 2. Intervention 3 — already implemented (verification only)

Verified on `main` @ 6b25167:

- The filer lives at `.github/workflows/ci-main.yml` **L339–L439** (the file is 439 lines; the
  issue's cited L324 is now an unrelated `python-ci` comment). Its title is **SHA-free**:
  `const TITLE = failed.length ? \`main broken by merge: ${failed.join(' + ')}\` : 'main broken by merge';`
  (L398–L400) — keyed on the **failing job set**, and the dedup matches on that title (the canonical
  paginate-then-find shape of `.github/workflows/enforce-skills.yml:89`).
- The fix landed in `77a3e8d` (2026-09-13, #937/#938), with a sibling worktree
  `.worktrees/fix/903-autofiler-dedup`.
- **Stale duplicates remaining OPEN: 2** — #975 (`main broken by merge (6f1f3d7)`) and #976
  (`main broken by merge (6c59118)`). Both titles carry a SHA, so both were minted by the **pre-fix**
  filer whose SHA-bearing title guaranteed uniqueness; both predate `77a3e8d`. The filer minted **35**
  SHA-titled issues (33 closed, 2 open); the 36th `main broken by merge`-titled issue is #339, filed by
  hand as the *pattern* issue. *(Earlier drafts attributed the two to the concurrent-filer race; the SHA
  titles prove the pre-fix filer, and two distinct SHAs are two distinct commits, not the same-title race.)*
- **Re-check mechanism (not a bare "ask"):** owner = this task's controller; trigger = the question
  is posed in the #903 PR body, and if neither of #975/#976 is closed by the time this PR merges, the
  operator on call for agent-infra closes the two within 24h and records it on #903.

---

## 3. Intervention 1 — measurement discipline

### 3.1 The rule

> **A measurement claim must name the revision it measured.** Measure against `origin/main`, never
> the contended hub: a guard/test run in a stale checkout asserts a smaller floor and returns an
> unqualified pass that describes a revision nobody asked about.

Four lines of prose. A one-rule change, not a section.

### 3.2 Home chosen, and why

**Home: `skills/using-git-worktrees/SKILL.md` §Checkout Discipline (new numbered item 5).**

- `docs/research/2026-08-14-checkout-discipline-homes.md` designates **agent-infra `skills/`** as the
  canonical *Behavior* layer for checkout discipline and records that `using-git-worktrees` is where
  that discipline's text lives. The rule is checkout-discipline behavior, so item 5 belongs beside
  the existing hub-check / delete-on-merge / canary / ambient-guard items (1–4 verified present).
- **Rejected:** `docs/research/2026-08-11-git-freshness-agent-checkouts.md` and
  `docs/plans/2026-08-11-issue-178-git-freshness.md` — dated historical records; policy appended to
  a record rots silently (the homes doc's own "one edit site per artifact").
- **Rejected:** `skills/commit-workflow/workflow/01-preflight.md` — commit-time git hygiene, not a
  pre-commit check; a second source of truth.
- **Constraint:** `extensions/shared/test-never-unbounded.mjs` reads this file and asserts exactly
  one "never launch an unbounded nested pi" block plus the absence of a bare `timeout <N>` form. The
  new item 5 must not add or disturb either (§6).

---

## 4. Intervention 2 — findings must declare consequence

### 4.1 The rule

> **Every finding must declare `consequence: <what breaks, who observes it>`.** No consequence →
> **advisory: non-blocking, not counted toward the gate, and not filed as a GitHub issue.**

**Adequacy (the bar must not be trivially satisfiable).** A `consequence:` is adequate only if it
names (a) a concrete failure — a broken behaviour, a lost invariant, a wrong result — and (b) the
party who observes it (a user, an operator, a downstream component, CI). A restatement of the finding
("this is wrong"), a severity word, or a bare "it breaks" is **not** a consequence: advisory.

**Conformance floor — the anti-vacuous-pass guard.** Voiding consequence-less findings must not let a
reviewer erase a whole cycle by omitting the field. Therefore:

- **If a cycle produced ≥ 1 finding and none of them carry an adequate `consequence:`, that is
  malformed reviewer output, not a clean cycle.** Record it with an explicit, auditable marker
  (`⚠️ reviewer returned N consequence-less findings`), re-dispatch once, and then exit **non-clean**
  (marker recorded, findings documented, never reported clean) per `AGENTS.md` §Hard Cap.
- **The floor SUPERSEDES the advisory "unverdict findings → record and proceed" precedent; it does not
  mirror it.** That precedent belongs to reviewers that are advisory *by construction* (the
  `duplication-architecture` disposition tables in `epic-scope:173`, `issue-scoping:408`, `epic-plan:162`,
  and `plan-review:402`), where "proceed" is harmless. The floor governs **blocking** reviewers, where
  "proceed" closes the gate. The edit cross-references those four adjacent rows so one cycle cannot have
  two opposite outcomes.
- **The floor fires only on a BLOCKING reviewer's consequence-less cycle.** Findings from reviewers that
  are *advisory by construction* — `duplication-architecture`, and `improvement-opportunities`' P1/P2 —
  are recorded, never counted toward the gate, and **do not trigger the floor** (§4.5).
- **A floor firing forbids a clean exit for that cycle — even after the one re-dispatch.** It converts
  the exit to an **escalation** exit: the remaining findings are documented and the cycle is never
  reported clean.
- **The clean predicate is each gate's own verbatim clean token, never a substring and never a count.**
  Tokens differ per gate and one contains a non-clean lookalike: `plan-review` and `epic-plan` accept only
  `NO ISSUES FOUND — CLEAN` (their files already warn that `…— DEGRADED` is *not* a pass); `issue-scoping`
  and `epic-scope` return `CLEAN`/`DEGRADED`; `epic-decompose` returns `MECE CLEAN`; the reviewer skills
  return `NO ISSUES FOUND`; the adversarial domain returns `THREAT SURFACE COVERED`. The edit writes the
  gate's own full token, never `NO ISSUES FOUND` as a substring test.
- **Voided findings are still written to the cycle log.** One field governs, and only one: convergence's
  strict-subset test and the fingerprint/stall detectors read the **logged findings** (consequence-bearing
  *and* voided), so a shrunken counted set can never read as convergence. The clean predicate alone reads
  the reviewer verdict, never a count.

**Precedence (two clauses).**
1. Against `AGENTS.md:27`'s auto-file rule: it does not re-mandate a consequence-less reviewer finding
   into an issue. The bar governs findings *inside a review gate*; the auto-file rule still governs an
   agent discovering a defect while working (§1.3).
2. Against `AGENTS.md`'s Review Loop Protocol / Hard Cap: for exit conditions, the `clean` predicate is
   the reviewer's verbatim clean verdict and the conformance floor above is what stops a
   consequence-less cycle from being declared clean. A cycle with findings but no consequences is not a
   clean exit — it is the floor firing, and it is an escalation exit.

**Known residual — the bar is fail-open, and that is deliberate.** A reviewer that writes a token
consequence keeps a soft finding. This is not detectable by prose. The direction is chosen on purpose:
a gate that occasionally passes a real finding is a *latency* cost; a gate that blocks and files on
noise is the *unbounded growth* this issue exists to stop. The mitigation is the adequacy test, the
conformance floor, and the emitter-schema edit (§4.4) — not a script.

**The token is pinned: `consequence:` — lowercase, one spelling.** Two schema families exist (emitter
files use `ISSUE #N` / `Severity:` / `Problem:` / `Fix:`; gate files use `ISSUE:` / `severity:` /
`description:` / `suggestion:`). The one *executable* consumer (`fixer-loop.md`) parses case-sensitively
with a fixed field list, so a `Consequence:` written in a file's own capitalised style would be invisible
to it. Both families use the exact lowercase token.

**`epic-decompose`'s MECE findings ARE in the bar.** The earlier draft exempted `fix: <create new issue |
merge issues | reorder dependencies>` as "not a finding-filing path" — that is false (the schema itself
files issues) and the exemption would be the second class of blocking-without-consequence that §4.5
rejects. The bar applies: a MECE finding must carry an adequate `consequence:` before its `fix` action
runs. A coverage gap *can* satisfy the adequacy test ("epic section X has no owning child issue → the
next stage cannot be dispatched"). One rule, no carve-out.

**`issue-scoping` keeps its discovery-time filing path.** The bar governs the scope/verifier **finding**
paths (Phase 2.5 / 5.5 / 7). The adjacent-discovery instruction ("file extra issues, don't silently
absorb") is a *discovery-while-working* path and remains governed by `AGENTS.md:27` per precedence clause 1.

### 4.2 The emission-control interpretation (stated explicitly — overrule if wrong)

#903 says "not counted toward the gate". The issue's *objective* is "stop the unbounded issue
emission", so this plan implements the reading that serves the objective: a consequence-less finding
is **also not filed**. A rule that only made findings non-blocking would leave the emission path
untouched. Stated here and in the PR body so a human can overrule it.

### 4.3 The authoritative set — measured, and explicitly bounded

#903 claims "~10 lines across **~6 reviewer prompts**, zero new files". **That count is wrong** — but
the truth is not "every gate in the repo" either. The rule is bounded to the **engineering delivery
pipeline** that #903 measured — `[inherited — #903 §3: "essentially all issues concern this repo's own
tooling"; the source RETRACTED its earlier 77%/10% split as not reproducible, and no percentage is
re-derived here]` — and the exclusions are named.

**Reproducible commands** (worktree root):

| Command | Output |
|---|---|
| `grep -rl "ISSUE #N" skills/ --include=*.md` | **17** (15 `skills/reviewers/*/SKILL.md` + 2 content reviewers) |
| `grep -rl "ISSUE:" skills/ --include=*.md` | **17** (a different membership — several gates say "ISSUE blocks" by concept, not token) |
| `grep -rl "^## Review Gate" skills/epic-*/SKILL.md` | **6** (the six epic gates) — `grep -rl "^## Review Gate" skills/` gives **7**, the extra being `proportional-gates` §Review Gate Routing |

**Inclusion criterion:** a file is in scope if it is (i) a review gate in the engineering delivery
pipeline — invoked by `issue-workflow`/`task-workflow-standard`/`project-workflow`/`epic-workflow`/
`commit-workflow`/`meta-framework-research` — that parses findings and can block a gate or file an
issue, or (ii) an emitter file defining an `ISSUE` schema dispatched by such a gate.

**Scope justification (tagged, per §1.1's own rule).** #903's appendix **retracted** its earlier
"77% meta / 10% product" split as non-reproducible and replaced it with "essentially all issues concern
this repo's own tooling". This plan uses the source's own formulation — `[inherited — #903 §3;
classification not reproducible to a split]` — rather than re-deriving a percentage.

**Role B — 15 consumer gate/reference files:**

| File | Role |
|---|---|
| `skills/code-review/SKILL.md` + `skills/code-review/references/fixer-loop.md` | PR gate — inline schemas + merge/fix/exit (the only *executable* consumer) |
| `skills/plan-review/SKILL.md` | Plan gate |
| `skills/test-review/SKILL.md` | Test gate |
| `skills/issue-scoping/SKILL.md` | Scope gates (2.5 / 5.5 / 7) + the explicit **"file extra issues"** path |
| `skills/prototype-review/SKILL.md` | Prototype gate |
| `skills/epic-align/SKILL.md`, `skills/epic-research/SKILL.md`, `skills/epic-verify/SKILL.md` | Epic stages 1/2/6 — each has a `## Review Gate` returning `ISSUES: <list>` + a fix loop |
| `skills/epic-plan/SKILL.md`, `skills/epic-scope/SKILL.md`, `skills/epic-decompose/SKILL.md` | Epic planning gates; `epic-decompose`'s MECE reviewer emits `ISSUE:` with `fix: <create new issue \| …>` |
| `skills/verification-before-completion/SKILL.md` | Verification gate — dispatches a verifier whose `ISSUE:` block blocks "done" via `<HARD-GATE>`; invoked by `task-workflow-standard` |
| `skills/research/SKILL.md` | Research gate — Step 5.5 `[VGATE]` verifier emits a full `ISSUE:` schema with a blocking fix gate; the mandated engineering research path (`AGENTS.md`) |
| `skills/meta-framework-research/workflow/07-review-gate.md` | Research gate (fresh-context review gate) |

**Role A — 15 emitter files:** `skills/reviewers/*/SKILL.md`.

**Role B count breakdown:** 15 files = **13 `SKILL.md` gates** + `code-review/references/fixer-loop.md`
+ `meta-framework-research/workflow/07-review-gate.md`. Of the 13 gates, only `plan-review` already cites
`proportional-gates`, so **12** gain the citation.

**Per-file finding-emitter site counts (the §6 threshold).** Counted with
`grep -cE "^\s*ISSUE:"` for schema files and `grep -c "ISSUES:"` for return-token files:
`code-review` 16, `plan-review` 5, `test-review` 4, `issue-scoping` 2, `prototype-review` 2,
`research` 1, `verification-before-completion` 1, `epic-decompose` 1 + 2, `epic-plan` 3,
`epic-scope` 2, `epic-align` 1, `epic-research` 1, `epic-verify` 1, `07-review-gate.md` 0 tokens
(+1 "Return ISSUE blocks" instruction line — the site to be added), `code-review/references/fixer-loop.md`
0 (reviewer-path prose only). The numbers are re-measured at implementation time with the same commands;
what matters is that the threshold is *recorded per file*, not self-graded.

**Canonical rule — 1 file:** `skills/proportional-gates/SKILL.md`.

Role A and Role B are disjoint. Intervention 2 edits **1 + 15 + 15 = 31 distinct files**; intervention
1 adds 1. **Grand total edited: 32 files** (plus this plan doc).

**Named exclusions (reported, not silently dropped).** These files also emit findings under a review
loop, but sit outside the engineering delivery pipeline #903 measured, so they are **out of scope by
the criterion above, not by omission**:

| Excluded | Why |
|---|---|
| `skills/define-vision/SKILL.md`, `skills/define-subject-identity/SKILL.md`, `skills/define-team-vision/SKILL.md`, `skills/define-strategy/SKILL.md`, `skills/define-product-*/`, `skills/define-team-strategy/SKILL.md` | Strategy/identity pipelines; they iterate reviewers to clean and do not feed the measured issue stream |
| `skills/planning/shared/{align,research,verify}/SKILL.md` | Epic-workflow *routers* to the `epic-*` gates already in the set (they declare no finding schema of their own) |
| `skills/experiment-analysis/SKILL.md` | Product-experiment pipeline |
| `skills/executing-plans/SKILL.md` | Its `ISSUE:`-shaped blocks are **deterministic check outputs** (`check_type`/`severity`/… emitted by pre-commit echoes), not reviewer-finding schemas |
| `skills/content-verification/SKILL.md`, `skills/content-reviewer-breadth|depth/SKILL.md`, `skills/content-fact-checker-writing/SKILL.md` | Content (El Dato) pipeline, a separate domain with its own gate loop |
| `skills/carousel-designer/SKILL.md`, `skills/carousel-b2b-strategy/SKILL.md`, `skills/google-slides/SKILL.md`, `skills/art-director/SKILL.md` | Content-production pipelines |
| `skills/plan-review/references/reviewers/{architectural-soundness,integration,efficiency,structural-pattern}.md` (4) | **Verified not dispatched by any gate**: `grep -rn "references/reviewers"` finds no dispatcher; `plan-review/SKILL.md` inlines its own prompts and the only inbound references are provenance notes inside the newer `skills/reviewers/*` files |
| `skills/code-review/ARCHIVE-pi-v2.0.0.md` | Superseded archive; excluded from drift scans by the `ARCHIVE*` filter in `tier-config-parity.test.ts` |
| `skills/commit-workflow/workflow/03-code-review.md`, `skills/commit-workflow/workflow/04-merge-deploy.md`, `skills/test-writing/SKILL.md` | **Consumer exit steps, not emitters.** They key a merge/loop decision on findings the gate has *already* voided or counted; they declare no finding schema and no severity-blocking rule of their own. `commit-workflow/03` does carry a `[ERROR]`/`[WARNING]` migration-review class — a *static scanner's* severity class (deterministic, like the pattern-scan above), explicitly out of the adequacy test |

**The bound is criterion-scoped, not universal.** Membership is the two lists above; every file excluded
*by the stated criterion* has a named reason in this table. Emitters outside the engineering delivery
pipeline exist (named above) and are out of scope by the criterion, not by omission.

**Why the emitter files are edited too.** The rule only bites if the reviewer actually emits the field.
Several gates tell the sub-agent *"read `skills/reviewers/<x>/SKILL.md` in full — the file is the
specification, not this prompt"*; a gate that merely *asks* for `consequence:` while that file
specifies a schema without it produces consequence-less findings — a vacuous pass.

**Why the gates' *inline* schemas are edited too.** The always-on reviewers (`code-review`'s four,
`plan-review`'s proportional set, `test-review`'s four, `prototype-review`'s three, `issue-scoping`'s
verifiers) are **inlined in the gate file**, not dispatched from `skills/reviewers/*`. Editing only
the dispatch clause would leave those reviewers emitting a schema with no field. Note the scale: an
`ISSUE:` schema appears **many times per gate file** (`code-review` alone has 16 `^\s*ISSUE:`
occurrences; `plan-review` 5; `test-review` 4). Task 4's acceptance is therefore **every** `ISSUE:`
schema occurrence in each gate file, not one per file.

### 4.4 Where the field goes

- **Emitter files (15):** one line added to each `## Output Format` block immediately after
  `Severity:`. `skills/reviewers/improvement-opportunities/SKILL.md` additionally has its
  `### P2 — Should Fix (blocks merge)` heading reworded — otherwise the file would simultaneously say
  "P2 blocks merge" and "P2 is advisory", the *silent, self-contradictory* disablement §4.5 exists to
  avoid.
- **Gate files (15):** the rule is added to (a) every inline `ISSUE:` schema and every `ISSUES:` return token, (b) the reviewer-dispatch instruction, and (c) the merge/parse/fix/exit step, where a finding lacking an adequate `consequence:` is voided for blocking **and** for filing — plus the conformance floor (§4.1) and, in each of the **13** gate `SKILL.md` files, the `proportional-gates` citation (**12** of them lack it today).
- **Canonical rule (1):** a short new section in `skills/proportional-gates/SKILL.md`. **It is not
  true that every gate already cites it** — today `grep -rln proportional-gates skills/` returns:
  `plan-review`, `issue-workflow`, `project-workflow`, `task-workflow-standard`, `executing-plans`,
  `execution-intent`, `commit-workflow/workflow/01-preflight.md`,
  `writing-plans/workflow/02-research-intake.md`, and `proportional-gates` itself. Of the 13 consumer
  gates, only `plan-review` cites it, so **Task 4 adds the citation to the other twelve.** The new
  section is placed so it cannot disturb the machine-parsed `### Review Cycles` table or the single
  `<!-- adversarial-bound: cap=2 -->` anchor pinned by
  `extensions/loop-enforcer/tier-config-parity.test.ts`.

**Pinned regions and contracts that must not be disturbed (verified constraints):**

| Pinned by | What it pins | Constraint on the edit |
|---|---|---|
| `extensions/loop-enforcer/tier-config-parity.test.ts` | `skills/proportional-gates/SKILL.md` `### Review Cycles` table | Add nothing inside the table region; the new section goes after it |
| same suite | exactly one `adversarial-bound: cap=2` anchor in **each of the 8 `ADVERSARIAL_SURFACES`** — **five of them are edited here**: `skills/proportional-gates/SKILL.md` (anchor L96, Task 2), `skills/code-review/SKILL.md:894`, `skills/code-review/references/fixer-loop.md` (anchor L75, immediately above the `BOUND=10` line), `skills/plan-review/SKILL.md:72`, `skills/issue-scoping/SKILL.md:937` | Add **no** second anchor at any of the five; keep each existing one in place |
| same suite | `STALL_THRESHOLD_SURFACES` — every live `skills/**/*.md` is scanned both ways: each listed surface keeps a numeric `stall_threshold` default, and no other file declares one. **Six** edited files are surfaces: `code-review/SKILL.md:839`, `code-review/references/fixer-loop.md`, `issue-scoping/SKILL.md:933`, `plan-review/SKILL.md:113/:494`, `test-review/SKILL.md:425`, `verification-before-completion/SKILL.md:182/:186` | No new `stall_threshold` mention anywhere, and **no decimal number within the 120-char window** of the existing ones (the scan takes the first `\d+\.\d+` in that window); do not remove an existing declaration |
| same suite | `skills/code-review/references/fixer-loop.md`: `CANONICAL_L1_BLOCK` exactly once, exactly one `### L1 — Exit conditions` heading, no `BOUND=` outside it, no extra `ADVERSARIAL_BOUND` reference | The fixer-loop edit is **prose on the reviewer-finding path only** — the embedded parser, its field list, its `EXIT_REASON="clean"` branches and `ISSUES_PER_CYCLE_JSON` are **not** touched (§4.4); introduce no `BOUND=`/`ADVERSARIAL_BOUND` token |
| `extensions/review-enforcer/index.test.ts` (`CONTRACT_DOC_PINS`) | `skills/code-review/SKILL.md` region `### Step 10a` → `## Standard-Tier Review`, tokens `clean-micro`/`complexity:micro`/`exit 4`/`not multi-agent` | The code-review edit stays **outside** that window |
| `extensions/loop-enforcer/termination.ts` (`verdict === "CLEAN" && issuesFound === 0`) | reads the agent-written loop manifest | out of the bar — the floor prose governs the agent that writes the manifest; no code change (§4.4) |
| `skills/post-deploy-verify/SKILL.md` | WARN-ONLY post-merge clickthrough gate (invoked by `commit-workflow` Step 3.8). Agent-executed, and it does file issues (Step 4, `clickthrough-failure:` prefix) — but those are failures observed **post-merge while working**: discovery-while-working under `AGENTS.md:27`, not in-gate reviewer findings. Governed by #906, not by this bar |
| `skills/test-debt-gate/SKILL.md` | Deterministic gate classifications (baseline-diff, `test-baseline.json`-keyed) with an auto-file protocol — the same class as `commit-workflow/03`'s static-scanner `[ERROR]`/`[WARNING]` severity; out of the adequacy test |
| `skills/qa-mission/SKILL.md`, `skills/ux-qa/SKILL.md`, `skills/friction-triage/SKILL.md` | Agent-invoked issue emitters outside the engineering delivery pipeline (QA missions and friction triage file scoped issues by design; not in-gate reviewer findings) |
| `extensions/shared/test-never-unbounded.mjs` | `skills/using-git-worktrees/SKILL.md`: exactly one "never launch an unbounded nested pi" block; no bare `timeout <N>` | Item 5 must not add/disturb either |
| `scripts/check-skill-lint.mjs` | frontmatter of every `SKILL.md` | body-only edits |

**The bar governs reviewer findings — not the automated pattern-scan, and not the machine loop.**
`skills/code-review/references/fixer-loop.md` builds `CURRENT_ISSUES_JSON` from **`PATTERN_SCAN_RAW`**,
the output of the MCP tool `mcp__ai-workflow-tools__code_review_pattern_scan` — a deterministic scanner,
not reviewer prose. Therefore:

- **The automated pattern-scan findings are OUT of the adequacy test, explicitly** (a deterministic scanner
  emits no prose `consequence:`; applying the test would void 100% of them and the loop would fix nothing
  forever). Recording this here is the disclosure the alternative — silently absorbing it — would omit.
- **The bar's `fixer-loop.md` edit is confined to the reviewer-finding path** (the prose contract that
  reviewer findings are voided for blocking and filing). The embedded parser, its fixed field list, its
  `EXIT_REASON="clean"` branches and `ISSUES_PER_CYCLE_JSON` are **not** re-engineered — re-engineering an
  embedded executable is precisely what §6 forbids.
- **`extensions/loop-enforcer/termination.ts` (`verdict === "CLEAN" && issuesFound === 0`) is out of the
  bar**: it reads the loop manifest, which the agent writes. The floor prose governs the agent that writes
  it; no code change is made. Named here so the exclusion is visible, not silent.

### 4.5 `improvement-opportunities` — the judgment call

Its self-description is *"constructive, not adversarial — it flags things that could be better, not
things that are broken."* Under a consequence bar its P1/P2 classes are consequence-less **by
construction**, so an unqualified application of the rule would *silently* disable it.

**First, the dispatch relationship is asserted, not observed — verified and corrected.** No gate
dispatches `skills/reviewers/improvement-opportunities/SKILL.md` **by name**. `epic-plan` §8 names
"improvement opportunities" as a *coherence dimension* only; the external references are the boundary
note in `duplication-architecture/SKILL.md:23` and the reviewer prompt at `epic-scope/SKILL.md:143`.
So this is **not** merely a disposition change — the dispatch site is made explicit in Task 4, the way
`duplication-architecture` already has a named dispatch + disposition table in `epic-plan` under
`## Review Gate Pattern`.

**Decision: it stays dispatched, and becomes advisory-only, explicitly and visibly — not by a special
exemption.** Its value (capturing improvement ideas) is real; its findings are legitimately
non-blocking; the bar already produces that outcome, so no exemption is needed — what is needed is
that the disablement be **visible, not silent**. Therefore:
- `skills/reviewers/improvement-opportunities/SKILL.md` states its P1/P2 classes are advisory by
  construction (recorded, never blocking, never filed) **and** both the `### P1 — Should Fix` and
  `### P2 — Should Fix (blocks merge)` headings are reworded to match — leaving P1 unmarked would be
  the same self-contradiction.
- Its **P0 (IO1 "active harm")** is tightened in the same edit so it names a concrete failure plus the
  observing party ("maintenance burden" alone fails §4.1's adequacy test), so the P0 path *can* block —
  the rule applied, not exempted.
- `skills/epic-plan/SKILL.md`'s coherence gate **names the reviewer explicitly** and records the
  advisory disposition (mirroring the duplication-architecture reviewer's existing disposition).

Rejected alternatives: an **explicit exemption** creates a second class of blocking finding with no
consequence — the emission the issue targets. **Stopping dispatch** throws away real signal to fix a
filing problem the advisory disposition already fixes.

### 4.6 Why prose and not code

#903 §6: "Enforce a cycle cap with a script" is self-defeating — PR #868 (a fix for unbounded review)
cost 4 review cycles, added 979 lines of pins, filed an issue during its own review, and deleted a
prior version of itself. No script, no guard, no test for the bound.

---

## 5. Task breakdown

### Task 1 — Intervention 1: measurement rule

**Intent:** A measurement claim names its revision; measured against `origin/main`, not the hub.
**Acceptance:** `skills/using-git-worktrees/SKILL.md` §Checkout Discipline gains item 5 (~4 lines);
`test-never-unbounded.mjs` still passes.
**Files:** Modify `skills/using-git-worktrees/SKILL.md`.

### Task 2 — Intervention 2: canonical rule

**Intent:** State the bar once in the canonical review-gating reference — with its adequacy test, its
conformance floor, its fail-open residual, and both precedence clauses.
**Acceptance:** `skills/proportional-gates/SKILL.md` carries the rule; the `### Review Cycles` table
and the single `adversarial-bound: cap=2` anchor are untouched; `tier-config-parity.test.ts` green.
**Files:** Modify `skills/proportional-gates/SKILL.md`.

### Task 3 — Intervention 2: emitter schemas

**Intent:** Every dispatched reviewer prompt emits `consequence:`.
**Acceptance:** each of the 15 emitter files' `## Output Format` blocks carries the line; **both** the
`### P1 — Should Fix` and `### P2 — Should Fix (blocks merge)` headings in `improvement-opportunities`
are reworded per §4.5; `check-skill-lint` exits 0.
**Files:** Modify 15 × `skills/reviewers/*/SKILL.md`.

### Task 4 — Intervention 2: gate consumption

**Intent:** A consequence-less finding is advisory — not blocking, not counted, not filed — without
opening a vacuous-pass channel.
**Acceptance:** **every finding-emitting site** in each of the 15 gate files carries the field — both the
`ISSUE:` schemas *and* the `ISSUES: <list>` return tokens of the five epic gates (which have **zero**
`ISSUE:` occurrences, so a bare `ISSUE:` count would pass vacuously); `07-review-gate.md` has no schema
and needs one added, not amended; each dispatch instruction requires the field; each merge/fix/exit step
carries the void rule and the conformance floor; each of the **13** gate `SKILL.md` files gains the
`proportional-gates` citation (**12** currently lack it); `improvement-opportunities` gets an explicit dispatch site +
advisory disposition; the pinned regions/contracts in §4.4 are untouched (`tier-config-parity.test.ts`,
`review-enforcer/index.test.ts`, `test-never-unbounded.mjs` green).
**Files:** Modify `skills/code-review/SKILL.md`, `skills/code-review/references/fixer-loop.md`,
`skills/plan-review/SKILL.md`, `skills/test-review/SKILL.md`, `skills/issue-scoping/SKILL.md`,
`skills/prototype-review/SKILL.md`, `skills/epic-align/SKILL.md`, `skills/epic-research/SKILL.md`,
`skills/epic-verify/SKILL.md`, `skills/epic-plan/SKILL.md`, `skills/epic-scope/SKILL.md`,
`skills/epic-decompose/SKILL.md`, `skills/verification-before-completion/SKILL.md`,
`skills/research/SKILL.md`, `skills/meta-framework-research/workflow/07-review-gate.md`.

### Task 5 — Verification

**Intent:** Prove the change is coherent and disturbs no machine-read contract, and deliver the two
non-prose commitments.
**Acceptance:** all local checks in §6 pass; the PR body carries the §1.3 "Decision needed" section and
the #975/#976 status (so the reconciliation is verified, not remembered).
**Files:** none.

---

## 6. Verification plan

| Check | Expectation |
|---|---|
| `node scripts/check-skill-lint.mjs --skills-dir skills` | exit 0 |
| `npx tsx extensions/loop-enforcer/tier-config-parity.test.ts` | 52 passed, 0 failed |
| `npx tsx extensions/loop-enforcer/termination.test.ts` | 46 passed, 0 failed |
| `node --test extensions/shared/test-never-unbounded.mjs` (or its runner) | pass — `using-git-worktrees` pin intact |
| `npx tsx extensions/review-enforcer/index.test.ts` | pass — `code-review` Step 10a pin intact |
| `bash scripts/materialize-agents.sh --check .` | clean (AGENTS.md NOT edited) |
| `grep -c "consequence:" skills/<file>` | per file, ≥ the **recorded per-file site count** (§4.3) — recomputed with the §4.3 commands, and a self-graded count is not accepted |
| `grep -c 'EXIT_REASON="clean"' skills/code-review/references/fixer-loop.md` | unchanged count (the parser is not re-engineered) |
| `git status --short` after the commit | every edited skill is committed (agent-infra `skills/` installs globally; `commit-workflow`/skill-sync carries it) |

No `.ts`/`.py` changes → typecheck/build skipped per `proportional-gates` §Pre-flight Verification.

---

## 7. Wiring map

| Touch point | Type | Covered by | Status |
|---|---|---|---|
| Reviewer output schema (dispatched files) | skill prose | Task 3 (15 files) | ✅ |
| Reviewer output schema (inline in gates) | skill prose | Task 4 (13 gate files, every occurrence) | ✅ |
| Gate blocking decision + conformance floor | skill prose | Task 4 | ✅ |
| Issue-filing path from findings | skill prose | Task 4 — advisory findings are not filed | ✅ |
| `proportional-gates` citation from consumer gates | skill prose | Task 4 (12 gates) | ✅ |
| Checkout discipline policy home | skill prose | Task 1 | ✅ |
| Machine-parsed contracts + pinned regions | test | Task 5 (5 suites) | ✅ |
| `AGENTS.md` / `templates/AGENTS.base.md` parity | — | untouched | ✅ n/a |
| Skill installation/sync to `~/.pi/agent/skills` | runtime | `commit-workflow` (skill-sync) | ✅ |

---

## 8. Acceptance criteria

1. A measurement claim cannot be made without naming its revision — the rule is readable at the
   canonical checkout-discipline home.
2. A reviewer finding without an *adequate* `consequence:` does not block a gate and does not become
   an issue — at every gate in the bounded set, for both inline-schema and dispatched reviewers — and
   a cycle with findings but no consequences is **not** a clean exit (the conformance floor fires).
3. `improvement-opportunities` remains dispatched (its dispatch site made explicit), its findings
   preserved as advisory, and the disposition is explicit rather than silent.
4. Every local check in §6 passes, including the pinned regions of §4.4.
5. No code, no new script, no new file beyond this plan doc.
6. The excluded gates are named (§4.3) and reported, not silently dropped.
