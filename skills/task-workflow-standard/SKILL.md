---
name: task-workflow-standard
description: Gated pipeline for standard+complex tasks — RESEARCH (checked artifact) → PLAN (scope+plan merged, declares the Review Scope Contract) → one PLAN-VERIFY round → BUILD → PROVE. Four stages, one blocking pre-code review round.
type: Workflow
domain: capability
subjects.team: organisation-design-team
status: live
tags: [pipeline, task, planning, research, review-scope, fractal, standard, complex]
summary: "Four stages for standard+complex tasks: a checked research artifact, one merged scope+plan with a declared review scope contract, one verifier round, then build and prove."
created: 2026-07-30
updated: 2026-10-26
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
version: 2.0.0
---
> ⛔ **This skill MUST be read in full — not skimmed.** The gate text is short on purpose; the *checks* it points at are the enforcement, and they are CI artifacts (see §What is actually enforced).

# Task Workflow (Standard + Complex)

Dispatched by `issue-workflow` for `Level: task` with `complexity:standard|complex` (or missing/unknown complexity — fail-closed). Owner ruling 2026-10-26: merged scope+plan behind a research gate, no stage that exists only to *make* a decision the issue already made. **Four stages (RESEARCH, PLAN, BUILD, PROVE) and three gates, of which one is a review round** — the two bracketed names below are gates, not stages.

## Pipeline

```
RESEARCH ──▶ PLAN ──▶ [PLAN-VERIFY] ──▶ BUILD ──▶ [PROVE]
```

**Two artifacts, two markers, two comments.** The research block and the plan are posted as **separate comments on the issue**, each with its own marker as the comment's first line — because `scripts/check-pipeline-compliance.sh` requires `<!-- issue-scoping:` at the first content line (or as a blank-line-set-off footer) of *its* comment, and two markers cannot both occupy that position. Do not put both in one comment. **PLAN also saves the plan doc** under `docs/plans/` (§2) — not because CI requires it (check (d) accepts a `wiring` mention in any issue comment, which `### Wiring` always supplies) but because the doc is the **reviewed** artifact, and a review needs one.

### 1. RESEARCH — gate: a **checked artifact**, no reviewer dispatch

Post one comment:

```markdown
<!-- research: v1 -->
### Targeted Research Findings
> **Findings date:** <YYYY-MM-DD>
**Search:** rung <N> (`<tool>`) — <attempted>/<returned>

**Internal** (≥1, each with a locator **and the quoted line**): `<path:line>` — "<the line, verbatim>" → what it settles
**External** (≥1, each with a URL): <url> → what it settles
**FALSIFIER:** <the observation that would overturn the chosen approach, and the consequence>
**Gaps:** <unanswered questions — carried as plan risk, named (or `none`, stated)>
## Raw Notes
- <ts> [internal|external] <finding, source-tagged, append-only>
```

- **Quote the line, at write time.** The quoted text is what makes the locator checkable by whoever reads the block — and it is the cheapest hardening available with no new stage: a fabricated citation is caught while you are still writing, before a verifier is spent on it. A locator without its quoted line is an assertion, not evidence.
- **A locator must RESOLVE, not merely look like one.** Each `path:line` must exist at the head you are working on, and the quoted line must be that line and must say what the finding claims. **PLAN-VERIFY Q2 re-opens every one and quotes it** — that is the check that runs *today*; the CI half (`check-pipeline-compliance.sh`, landing in agent-infra#2861 §11 **sequence step 2** — *not* the pipeline's stage 2) will open them automatically later. Do not wait for it, and do not claim it ran. A locator that points at a real file but a line about something else is the failure this gate exists to catch: it is the one field a lazy or pre-empted lane cannot cheaply fabricate.
- **Research is done by the lane, not inherited.** A brief that already contains research is context, never a substitute. `PRIOR_RESEARCH` (a parent epic's brief) is deduplicated against, with the dedup noted.
- **Depth is proportional:** `standard` = axis matrix capped at 8 queries, `complex` = 14 (`issue-scoping` §Tier Scaling). Codebase-first; fire external queries on a demonstrated gap.
- **Merge, don't add:** this block replaces `issue-scoping` Phase 1.5's `### Axis Research` *and* `writing-plans` Step B's `### Pattern Research` **for this pipeline**. One block, one format, one pointer — the plan doc's `<!-- research-path: … -->` resolves to it. (`### Axis Research` and `### Pattern Research` stay live for epic/project pipelines; do not confuse the two.)
- **Micro** skips this stage. **A decided ruling** replaces it with the decision reference — see §Decided-ruling path.

### 2. PLAN — one artifact, scope and plan merged, contract declared

Read `skills/writing-plans` first: it defines the plan-doc structure this stage saves, and reading it arms **two** sequence-enforcer steps — the **C3 `parallel_check_plan`** checkpoint (`gate: checkpoint`, `token_phase: plan`) **and** the `plan_review` verifier step (`gate: verifier`) that this stage's own PLAN-VERIFY dispatch satisfies (`skills/enforcement`). Both are steps in the sequence, not extra review rounds: PLAN-VERIFY is the one round. Skipping the read disarms the checkpoint silently, so it is part of this stage, not an optional reference.

Answer the problem questions **before** the plan questions. Two outputs: the **plan doc** and the **issue comment**.

**2a. Save the plan doc** — `docs/plans/<YYYY-MM-DD>-issue-<N>-<slug>.md`, opening with the research pointer:

```markdown
<!-- research-path: <the issue comment carrying `<!-- research: v1 -->`, or this doc's own §Research> -->
<!-- plan-review: cycles=<n>, status=<clean|threat-surface-covered>, version=2.3.0 -->
```

The second line is written **at PLAN-VERIFY close** and is this pipeline's `plan-review`
signature: `writing-plans/workflow/05-review-handoff.md` stops at Execution Handoff without one,
and for this pipeline PLAN-VERIFY **is** the plan review (see §3).

**CI check (d) is satisfied by either artifact**, and this is worth stating precisely because the first draft of this line got it wrong: (d) passes on a `docs/plans/*.md` change **or** on a case-insensitive `wiring` mention anywhere in the issue's comments (`check-pipeline-compliance.sh:1368`), which this stage's `### Wiring` table always provides. So the **doc is the reviewed artifact** — the one a human and the next lane read — **not the CI-enforced one**. Only (b)'s marker position and (c)'s head-bound record are unconditional. Making the doc mandatory would be a step-2 change to the script, and is not claimed here.

**2b. Post the issue comment** — first line is the marker, then the fields in this order (the order *is* the guard that the problem was pinned before the solution was chosen), mirroring the plan doc:

```markdown
<!-- issue-scoping: merged scope+plan -->
### Scope + Plan — #<N>
1. **Confirmed problem** — one paragraph, the falsification check (carried from the research
   block's single `FALSIFIER:` — one falsifier, not two), confidence.
2. **Alternatives considered** — ≥2, and why the chosen one wins.
3. **Complexity + domains** — per `issue-scoping` §Tier Scaling.
4. **Integration Surface Map** — from `test-design` (surfaces × test layer).
5. **Research** — the pointer to the `<!-- research: v1 -->` comment, × the decisions it supports.
6. **Wiring** — the `### Wiring` table: every call site / importer / consumer of each thing this
   change touches, and what it does there. **Required**: `commit-workflow`'s pre-PR
   (`--issue-only`) run of `check-pipeline-compliance.sh` accepts a plan doc only after a PR
   exists, so this section is the ONE plan evidence visible before it does (check (d)).
7. **Implementation steps** — bite-sized, each with the test that proves it.
8. **Rounds** — filled at PLAN-VERIFY close: `**Rounds:** <rounds> (verifiers: <count per round>, class: <class>)` — **two different measures**, rounds spent and verifiers per round (a standard lane that spent one verifier over two rounds writes `**Rounds:** 2 (verifiers: 1, class: protocol)`).

### Review Scope Contract
**Class:** <code | gate-enforcement | protocol | docs-product | docs-marketing | ops-infra | research-decision>
**Risk surface** — what this change can break, each with the check that would catch it:
- R1 <failure this change can cause> → caught by <test / assertion / gate / measurement>
**Threat classes** (gate-enforcement only) — `T1 <bypass class>`, or `(not adversarial)`.
**Out of scope — must NOT be raised** (note, file, do not chase):
- pre-existing defects outside the diff · style/prose preference with no behaviour change
- architectures the plan did not propose · incidental test/fixture shape
**Acceptance:** every `R<n>` has its named evidence, and no open item remains on the declared surface.
```

Emit the contract as its **own `### Review Scope Contract` heading with a real `**Class:**` line** — `code-review` reads that heading, so a numbered field with the heading inline is invisible to it. The normative template is `review-discipline` §The Review Scope Contract; if the two disagree, that skill wins. **There is ONE declared surface — this one.** A change to gate/enforcement code adds a `Threat classes` sub-block; the pre-#2861 separate `### Adversarial Threat Surface` is that sub-block, not a second document.

Escalate to `project-workflow` instead if this needs MECE decomposition into child issues, wiring, or E2E.

**Supersession, stated once:** for this pipeline, `issue-scoping`'s `Phase 2.5 problem-verify`, `Phase 5.5 solution-verify`, and its `Phase 8` plan-comment shape (including its standalone `### Adversarial Threat Surface`) are **not** dispatched or emitted — PLAN-VERIFY below is the one round that covers both diamonds' questions, and §2b above is the artifact CI check (b) reads. Those phases remain live for `epic-workflow` / `project-workflow`, which consume `issue-scoping` directly.

### 3. PLAN-VERIFY — gate: **one** verifier round (verifier count from `issue-scoping` §Tier Scaling: standard 1, complex 2 — **this gate's count, not the code panel's**, which `proportional-gates` owns)

One dispatch per verifier, one round. The verifier prompt asks exactly three things, **after** the class row is appended: look up the `Review Scope Contract`'s `Class:` in `review-discipline` and add that class's questions and its **must-NOT-ask** list to the prompt — the router's other consumer is `code-review` 0a, and PLAN-VERIFY is where a *design* class (`research-decision`, `protocol`) is asked its own questions rather than the code panel's:

- **Q1 — problem before solution:** is the confirmed problem pinned by evidence, and does the plan follow from it rather than from the issue's proposed fix?
- **Q2 — research-to-validate:** extract the plan's **load-bearing factual claims** (a claim whose falsity changes the design). For each, open the cited locator **and quote the line**; report every uncited claim, every locator that does not resolve, and every citation that does not bear on the claim it is attached to. *This question exists because planning changes which research was needed* — the research was written before the plan named its claims.
- **Q3 — contract coverage (plan-side half):** does each `R<n>` name a check that **could exist and be falsified** — specifically, would deleting the branch the check guards make it red? Is anything in the diff's blast radius missing from the surface? (Running it and pasting the red is PROVE's half; Q3 does not run it.)

On close, write **one number, twice**: `<!-- plan-review: cycles=<n>, status=<clean|threat-surface-covered>, version=2.3.0 -->` into the plan doc — the **record**, in its owner's key (`skills/plan-review` defines the marker; `cycles=`, not a second vocabulary) — and `**Rounds:** <rounds> (verifiers: <count per round>, class: <class>)` into the plan comment as its **mirror**, because the comment is the artifact §13 of agent-infra#2861 greps. **`<n>` = verifier rounds spent at this gate, the initial round included**; a fix plus its fresh re-check is `2`. The field is a measurement, not a claim of virtue: write what was spent, and if the two disagree the doc's `cycles=` is right. `writing-plans/05` requires the signature before Execution Handoff.

Verdict is `NO ISSUES FOUND`, or issues tagged with the `R<n>` they violate. **Residual rules:** an issue on the declared surface blocks and is fixed; anything outside it is `OUT-OF-SCOPE:` — recorded, filed, **not looped on** — **unless it is (a) caused by the change, (b) newly reachable or value-bearing because of it, or (c) purpose-defeating: those block whatever the declared surface says** (`review-discipline`). That exception is the one that matters: both P0s found in this design's own review were caused by its diff and outside its declared surface. A fix is re-checked **against the whole declared surface, by a FRESH verifier dispatch (a new `task`)** — and that re-check is a **round in the `AGENTS.md` §Hard Cap sense**: it increments `<n>`, and it **consumes** the bound exactly as any cycle does (`AGENTS.md`: *"dispatching a fresh reviewer does not reset, extend, or replenish the budget"*). "One round" is this gate's **plan**, not a rebate on the ceiling. A second dispatch is earned by a fix, never by a differing opinion, and the **cycle** bound is **the tier's cap in `skills/proportional-gates` §Review Cycles** (`standard` is Low-Medium, cap 3 — that file owns **cycle** bounds, while the verifier **count** above comes from `issue-scoping` §Tier Scaling), with `AGENTS.md` §Hard Cap's 10-cycle fallback where no tier cap applies. On either bound, or a stall, escalate to the owner rather than reporting clean.

**Adversarial domain — declared threat surface (bound: 2 cycles).** When the plan declares a `Threat classes` sub-block (gate/enforcement code whose correctness is "an attacker cannot make it fail open"), that domain is bounded by the surface rather than by reviewer exhaustion: acceptance = every declared class covered by a test + green CI, residuals **filed from cycle 1, not chased**, and a fresh verifier returning **`THREAT SURFACE COVERED`** (no in-scope bypass reproduced) is this domain's clean exit, substituting for `NO ISSUES FOUND`. When the merge rests on threat-list coverage rather than a literal `NO ISSUES FOUND`, disclose it in the PR body (`[ADVERSARIAL-BOUND] cycles=<N> threats=<K> covered=<K> residuals=<#N,…|none>`). Statement of record: `AGENTS.md` §Hard Cap. <!-- adversarial-bound: cap=2 -->

> **Read the ceiling correctly:** the adversarial domain is entitled to **2 cycles**, so the pipeline's headline "one blocking pre-code round" reads *1 for non-adversarial classes, ≤2 for a change that declares the adversarial domain*. This rule — *acceptance is coverage of a declared surface, not a reviewer count* — is the rule the whole pipeline now uses; the scope contract is its generalization, and `cap=2` is the one remnant. It is machine-pinned across eight surfaces (`extensions/loop-enforcer/tier-config-parity.test.ts`) and retired in sequence step 2 of the redesign (agent-infra#2861 §11). Do not move it by editing prose.

### 4. BUILD

Write the code, following the plan and `executing-plans`. The leverage is the test that must fail without the change — write it first.

### 5. PROVE — gate: evidence at the **exact head**

- `verification-before-completion`: typecheck + the targeted tests, output pasted, not summarized.
- **Mutation proof** for any branch that is *supposed* to refuse: delete/neuter the branch and show the guarding test goes red. A fail-closed branch with no test that fails without it is unproven — measured failure mode: deleting a reconcile arm left the sibling tests green.
- **Contract close-out:** one line per risk in the PR body, in exactly this shape — `- R<n>: covered — <command> → <output>`, or `- R<n>: open — <what is missing>` — plus a final `OUT-OF-SCOPE: <n>` (and a filed-issue reference per item, or `0`). The literal shape is what §13 of agent-infra#2861 greps; a prose paragraph is not readable by it. This is the artifact a reviewer (and the next lane) reads to see the acceptance was met — without it, the scope contract replaced a machine-parsed cap with nothing.
- Commit and merge through `commit-workflow` (PR, discipline-scoped review, head-bound attestation, rail).

## Decided-ruling path (owner ruling 2026-10-26 #3)

A lane whose issue says *"implement this ruling"* does not pay for stages that exist to **make** a decision.

**All three must hold:**

1. A **recorded decision** exists in its own home — an owner ruling, a decision section of a plan doc, a decision comment on an issue, or a Tortoise point carrying one.
2. The work is to **carry it out**.
3. Nothing in the change **reverses** it (a departure is a **reopen** in the decision's own home, not a lean dispatch).

**Skips:** the RESEARCH *work* (the queries) and PLAN-VERIFY's three questions. **Kept:** the research *artifact* (as a `**Basis:**` reference, below), **PLAN** (one paragraph of design plus the `### Review Scope Contract`, posted in the same plan comment), the doc's `### Wiring` table, and a **one-question verifier round** in place of PLAN-VERIFY.

Write `**Rounds:** 1 (verifiers: 1, class: <class>)` with the plan comment **and** `<!-- plan-review: cycles=1, status=clean, version=2.3.0 -->` into the plan doc — so `writing-plans/05`'s pre-check finds a record rather than an absence, and the round is counted rather than inferred — one verifier round is spent on this path, and saying `0` would misreport a round that ran.

**Does not skip:** the contract; **PROVE** (tests, mutation proof, exact-head review + attestation); every `AGENTS.md` hard rule the change touches; and a **one-question verifier round** — *"is the pointed artifact a decision that governs THIS change, or merely an artifact that exists?"* That round replaces PLAN-VERIFY's three questions because this is the path with the least scrutiny: skipping the review *and* the research check is exactly what would make the lean path a bypass.

**The research artifact is satisfied — checkably, not by self-certification** (the *work* is not done, and is not faked: the basis is a decision). Post the `<!-- research: v1 -->` comment with `**Basis:** <pointer>` in place of the citation fields, where the pointer resolves **to a decision**: an owner ruling, a `**Decision:**`/`OVERRIDES:` line, a decision comment, or a Tortoise point of decision type — not merely an existing issue or section. Keep `FALSIFIER:` and `Gaps:`: carrying out a decision can still be wrong, and those two lines are the only place that is written down. Also write `Path: decided-ruling (<that same pointer>)` in the plan comment.

**An unresolvable pointer — or an artifact that is not a decision — is the bypass, not the path.** If the location does not resolve, or the "decision" is the lane's own judgement ("the fix is obvious"), this path is **not** available: run the normal pipeline, or reopen/produce the decision first. Ambiguous → **not lean**: ask, and record the answer where the work is gated.

## What is actually enforced (read this before trusting the above)

The stages are **instructions**. What *binds* is CI, from the repo being merged — `scripts/check-pipeline-compliance.sh` (linked issue, `<!-- issue-scoping:` comment, **a plan doc under `docs/plans/` *or* a `wiring` mention in an issue comment**, head-bound review attestation, test evidence; and from sequence step 2 of #2861 the `<!-- research: v1 -->` block with a resolvable locator, plus O/I-T) and the merge rail (`scripts/admin-merge.sh`). This skill declares no `steps:` frontmatter, so no host extension locks your writes at a boundary — a lane that skips a stage discovers it at the gate, not at the next tool call. That is deliberate: the checks that matter must survive a host where these skills were never installed (agent-infra#9560).

## Key Principles

- **Research is a gate on your own artifact, never a paragraph in a brief.** Wrong or missing research is our most expensive defect class; a *resolvable* citation with a falsifier is the cheapest way to catch it.
- **One round per gate as the target, a fresh verifier per re-check, and the ceiling still counts.** A re-check consumes the budget like any cycle; the design predicts one round, it does not exempt the gate from the bound.
- **The scope contract is the acceptance criterion, not a cycle count.** A count truncates a review that is finding real defects and flatters one that is finding none.
- **Proportional depth, not proportional correctness.** Depth scales with the tier; the declared surface is covered or it is not.
- **Fresh context at the exact head** for every reviewer (`task`), because same-context re-review defends its own prior fixes.
- **File extra issues; don't silently absorb** a defect outside the declared surface.

---
> Continue following the workflow as mandated by this skill. Do not skip steps.
