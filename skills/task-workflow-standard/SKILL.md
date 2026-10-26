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

Dispatched by `issue-workflow` for `Level: task` with `complexity:standard|complex` (or missing/unknown complexity — fail-closed). Owner ruling 2026-10-26: merged scope+plan behind a research gate, no stage that exists only to *make* a decision the issue already made.

## Pipeline

```
RESEARCH ──▶ PLAN ──▶ [PLAN-VERIFY] ──▶ BUILD ──▶ [PROVE]
```

**Two artifacts, two markers, two comments.** The research block and the plan are posted as **separate comments on the issue**, each with its own marker as the comment's first line — because `scripts/check-pipeline-compliance.sh` requires `<!-- issue-scoping:` at the first content line (or as a blank-line-set-off footer) of *its* comment, and two markers cannot both occupy that position. Do not put both in one comment.

### 1. RESEARCH — gate: a **checked artifact**, no reviewer dispatch

Post one comment:

```markdown
<!-- research: v1 -->
### Targeted Research Findings
> **Findings date:** <YYYY-MM-DD>
**Search:** rung <N> (`<tool>`) — <attempted>/<returned>

**Internal** (≥1, with a locator): `<path:line>` | `#<issue>` | `<owner/repo>#<n>` → what it settles
**External** (≥1, with a URL): <url> → what it settles
**Decisions this supports:** <the plan decisions that rest on the above>
**FALSIFIER:** <the observation that would overturn the chosen approach>
**Gaps:** <unanswered questions — carried as plan risk, named>
## Raw Notes
- <ts> [internal|external] <finding, source-tagged, append-only>
```

- **A locator must RESOLVE, not merely look like one.** Each `path:line` must exist at the head you are working on and the line must say what the finding claims — the gate checker (step 2) opens it, and PLAN-VERIFY Q2 re-opens it. A locator that points at a real file but a line about something else is the failure this gate exists to catch, not a formatting nit: it is the one field a lazy or pre-empted lane cannot cheaply fabricate.
- **Research is done by the lane, not inherited.** A brief that already contains research is context, never a substitute. `PRIOR_RESEARCH` (a parent epic's brief) is deduplicated against, with the dedup noted.
- **Depth is proportional:** `standard` = axis matrix capped at 8 queries, `complex` = 14 (`issue-scoping` §Tier Scaling). Codebase-first; fire external queries on a demonstrated gap.
- **Merge, don't add:** this block replaces `issue-scoping` Phase 1.5's `### Axis Research` *and* `writing-plans` Step B's `### Pattern Research` **for this pipeline**. One block, one format, one pointer — the plan doc's `<!-- research-path: … -->` resolves to it. (`### Axis Research` stays `issue-scoping`'s own artifact for epic/project workflows; do not confuse the two.)
- **Micro** skips this stage. **A decided ruling** replaces it with the decision reference — see §Decided-ruling path.

### 2. PLAN — one artifact, scope and plan merged, contract declared

Post one comment whose **first line** is the marker, then the fields in this order (the order *is* the guard that the problem was pinned before the solution was chosen):

```markdown
<!-- issue-scoping: merged scope+plan -->
### Scope + Plan — #<N>
1. Confirmed problem — one paragraph, the falsification check (carried from the research
   block's single `FALSIFIER:` — one falsifier, not two), confidence.
2. Alternatives considered — ≥2, and why the chosen one wins.
3. Complexity + domains — per `issue-scoping` §Tier Scaling.
4. Integration Surface Map — from `test-design` (surfaces × test layer).
5. Research — the pointer to the `<!-- research: v1 -->` comment (stage 1).
6. ### Review Scope Contract — MANDATORY, before any review is dispatched:
   class (code | gate-enforcement | protocol | docs-product | docs-marketing | ops-infra | research-decision),
   the `R<n>` risk surface with the check that would catch each, and the explicit out-of-scope list.
   Adversarial changes (gate/enforcement code) add a `Threat classes` sub-block: the in-scope
   bypass classes and the classes explicitly out of scope. There is ONE declared surface —
   this one. The pre-#2861 separate `### Adversarial Threat Surface` is that sub-block.
   Format and semantics: `review-discipline` §The Review Scope Contract.
7. Implementation steps — bite-sized, each with the test that proves it.
```

Escalate to `project-workflow` instead if this needs MECE decomposition into child issues, wiring, or E2E.

**Supersession, stated once:** `issue-scoping`'s own `Phase 2.5 problem-verify` and `Phase 5.5 solution-verify` are **not** dispatched by this pipeline — PLAN-VERIFY below is the one round that covers both diamonds' questions here. Those phases remain live for `epic-workflow` / `project-workflow`, which consume `issue-scoping` directly.

### 3. PLAN-VERIFY — gate: **one** verifier round (count is depth: standard 1, complex 2)

One dispatch per verifier, one round. The verifier prompt asks exactly three things:

- **Q1 — problem before solution:** is the confirmed problem pinned by evidence, and does the plan follow from it rather than from the issue's proposed fix?
- **Q2 — research-to-validate:** extract the plan's **load-bearing factual claims** (a claim whose falsity changes the design). For each, open the cited locator **and quote the line**; report every uncited claim, every locator that does not resolve, and every citation that does not bear on the claim it is attached to. *This question exists because planning changes which research was needed* — the research was written before the plan named its claims.
- **Q3 — contract coverage (plan-side half):** does each `R<n>` name a check that **exists** and would **fail without the change**? Is anything in the diff's blast radius missing from the surface? (The *evidence* half — running it — is PROVE's; the two halves must not both claim the criterion.)

Verdict is `NO ISSUES FOUND`, or issues tagged with the `R<n>` they violate. **Residual rules:** an issue on the declared surface blocks and is fixed; anything outside it is `OUT-OF-SCOPE:` — recorded, filed, **not looped on**. One round per gate: a fix to a covered item is re-checked **against the whole declared surface** by the same verifier in the same round — a design regression introduced by a round-1 fix is caught there, not by a later code test.

**Adversarial domain — declared threat surface (bound: 2 cycles).** When the plan declares a `Threat classes` sub-block (gate/enforcement code whose correctness is "an attacker cannot make it fail open"), that domain is bounded by the surface rather than by reviewer exhaustion: acceptance = every declared class covered by a test + green CI, residuals **filed from cycle 1, not chased**, and a fresh verifier returning **`THREAT SURFACE COVERED`** (no in-scope bypass reproduced) is this domain's clean exit, substituting for `NO ISSUES FOUND`. When the merge rests on threat-list coverage rather than a literal `NO ISSUES FOUND`, disclose it in the PR body (`[ADVERSARIAL-BOUND] cycles=<N> threats=<K> covered=<K> residuals=<#N,…|none>`). Statement of record: `AGENTS.md` §Hard Cap. <!-- adversarial-bound: cap=2 -->

> **Read the ceiling correctly:** the adversarial domain is entitled to **2 cycles**, so the pipeline's headline “one blocking pre-code round” reads *1 for non-adversarial classes, ≤2 for a change that declares the adversarial domain*. This rule — *acceptance is coverage of a declared surface, not a reviewer count* — is the rule the whole pipeline now uses; the scope contract is its generalization, and `cap=2` is the one remnant. It is machine-pinned across eight surfaces (`extensions/loop-enforcer/tier-config-parity.test.ts`) and retired in step 2 of the redesign (agent-infra#2861 §11). Do not move it by editing prose.

### 4. BUILD

Write the code, following the plan and `executing-plans`. The leverage is the test that must fail without the change — write it first.

### 5. PROVE — gate: evidence at the **exact head**

- `verification-before-completion`: typecheck + the targeted tests, output pasted, not summarized.
- **Mutation proof** for any branch that is *supposed* to refuse: delete/neuter the branch and show the guarding test goes red. A fail-closed branch with no test that fails without it is unproven — measured failure mode: deleting a reconcile arm left the sibling tests green.
- **Contract close-out:** paste the Review Scope Contract with each `R<n>` marked `covered` and the command + output that covers it, plus an `OUT-OF-SCOPE: <n>` count. This is the artifact a reviewer (and the next lane) reads to see the acceptance was met — without it, the scope contract replaced a machine-parsed cap with nothing.
- Commit and merge through `commit-workflow` (PR, discipline-scoped review, head-bound attestation, rail).

## Decided-ruling path (owner ruling 2026-10-26 #3)

A lane whose issue says *"implement this ruling"* does not pay for stages that exist to **make** a decision.

**All three must hold:**

1. A **recorded decision** exists in its own home — an owner ruling, a decision section of a plan doc, a decision comment on an issue, or a Tortoise point carrying one.
2. The work is to **carry it out**.
3. Nothing in the change **reverses** it (a departure is a **reopen** in the decision's own home, not a lean dispatch).

**Skips:** stage 1 (RESEARCH) and stage 3 (PLAN-VERIFY).
**Does not skip:** one paragraph of design naming the decision and its location; the `### Review Scope Contract` (carrying out a decision has a real risk surface); **PROVE** (tests, mutation proof, exact-head review + attestation); and every `AGENTS.md` hard rule the change touches.

**The research requirement is satisfied — checkably, not by self-certification.** Post the `<!-- research: v1 -->` comment with `**Basis:** <resolvable pointer>` in place of the citation fields, where the pointer is one of `<owner/repo>#N`, a Tortoise point id, or `docs/plans/<file>.md#<section>` **that exists**. Keep `FALSIFIER:` and `Gaps:` — carrying out a decision can still be wrong, and those two lines are the only place that is written down. Also write `Path: decided-ruling (<that same pointer>)` in the plan comment.

**An unresolvable pointer is the bypass, not the path.** If the location does not resolve, or the "decision" is the lane's own judgement ("the fix is obvious"), this path is **not** available: run the normal pipeline, or reopen/produce the decision first. When it is ambiguous, the default is **not lean** — ask, and record the answer where the work is gated.

## What is actually enforced (read this before trusting the above)

The stages are **instructions**. What *binds* is CI, from the repo being merged — `scripts/check-pipeline-compliance.sh` (linked issue, `<!-- issue-scoping:` comment, plan doc, head-bound review attestation, test evidence, and from step 2 of #2861: the `<!-- research: v1 -->` block with a resolvable locator, plus O/I-T) and the merge rail (`scripts/admin-merge.sh`). This skill declares no `steps:` frontmatter, so no host extension locks your writes at a boundary — a lane that skips a stage discovers it at the gate, not at the next tool call. That is deliberate: the checks that matter must survive a host where these skills were never installed (agent-infra#9560).

## Key Principles

- **Research is a gate on your own artifact, never a paragraph in a brief.** Wrong or missing research is our most expensive defect class; a *resolvable* citation with a falsifier is the cheapest way to catch it.
- **One round per gate.** A second round over an unchanged artifact re-asks a question the first round answered. Re-checking a *fixed* artifact against its whole declared surface is the same round, not a new one.
- **The scope contract is the acceptance criterion, not a cycle count.** A count truncates a review that is finding real defects and flatters one that is finding none.
- **Proportional depth, not proportional correctness.** Depth scales with the tier; the declared surface is covered or it is not.
- **Fresh context at the exact head** for every reviewer (`task`), because same-context re-review defends its own prior fixes.
- **File extra issues; don't silently absorb** a defect outside the declared surface.

---
> Continue following the workflow as mandated by this skill. Do not skip steps.
