---
disable-model-invocation: true
name: review-discipline
description: "Reference: routes a review to the canon its artifact answers to. A marketing doc is reviewed against the marketing canon, not for code correctness; code is reviewed for correctness, tests and surface. Consumed by planning (to declare the Review Scope Contract), PLAN-VERIFY, code-review and commit-workflow — not invoked directly."
type: reference
domain: capability
subjects.team: organisation-design-team
status: live
tags: [review, routing, scope-contract, disciplines, canon]
summary: "Artifact class → the canon it answers to → the questions its reviewer asks, and what it must not ask."
created: 2026-10-26
updated: 2026-10-26
allowed-tools: read write edit bash grep find
version: 1.0.0
---
> ⛔ **This skill MUST be read in full — not skimmed.** Read it before dispatching or receiving a review. A review asked the wrong question is not a weaker review — it is a review whose findings cannot be satisfied, which is how loops never converge.

# Review Discipline — artifact → canon → questions

> **Ontology:** `tortoise/docs/ONTOLOGY.md` (v3.1, canonical) — resolve it through a tortoise checkout, not a relative path (see §Canon resolution).

## Why this exists

A single universal checklist ("is this correct?") is the mechanism that makes reviews raise **side facts**. A marketing doc has no code to be correct about and no spec to be factually correct against; asked for "correctness" a reviewer invents a standard, finds the artifact fails it, and generates a cycle. The same reviewer, asked "is this claim aligned with the category architecture and the positioning line?", produces a finding the author can act on.

So a review is _discipline-specific_: the artifact's class picks **the canon it answers to**, the canon picks **the questions**. This skill is that routing table, and it is cited at every point where a review question is chosen: `task-workflow-standard` (declares the class in the Review Scope Contract), `code-review` (Step 3.6 / 0a resolves `ARTIFACT_CLASS`, and the class picks the question set), and `commit-workflow` (which review a non-code artifact routes to at all). Its §The Review Scope Contract template is **normative**: where a consumer restates it, this skill wins.

## Canon resolution — a path that does not resolve is a blocker, not a pass

Canons live in different repos, and a relative path that works in one is absent in the other (agent-infra carries no `docs/00_index.md`, no `docs/ONTOLOGY.md`, no `config/surface-manifest.yml`; tortoise carries all three). Every canon below is written **`<repo>:<path>`**. Resolve it:

1. `<repo>` = this repo → use the path directly.
2. `<repo>` = another repo → find a checkout (e.g. via `$TORTOISE` / the pre-flight's resolver) and use that path.
3. **No checkout of `<repo>`** → the reviewer records `canon unreadable: <repo>:<path>` and reviews **only** the questions that do not depend on it. It does **not** silently substitute a nearby file, and it does not pass the artifact: an unreadable canon is a stated blocker, and the fix is a checkout.

## The table

| Class | The canon it answers to | The reviewer asks | It must **not** ask |
|---|---|---|---|
| **code** | the merge rail (`agent-infra:scripts/admin-merge.sh`) · all-repos:`AGENTS.md` hard rules · `tortoise:config/surface-manifest.yml` (MCP/SDK surface) · the plan's `Integration Surface Map` | Is the fail-closed polarity right — a gate that cannot run must not pass? Does a test fail **without** the diff (mutation proof)? Was a surface change approved by the owner? Is the attestation bound to **this** head? | marketing positioning; doc prose; whether another architecture would be nicer |
| **gate-enforcement** | `AGENTS.md` §Hard Cap · the plan's declared `Threat classes` sub-block · `agent-infra:extensions/loop-enforcer/tier-config-parity.test.ts` where a cap is pinned | Can this fail **open** (a wrong artifact passes / a gate is defeated) or be a **no-op** (exits 0 when it cannot run)? Is every declared threat class covered by a test that fails without the coverage? Is a bounded exit disclosed (`[ADVERSARIAL-BOUND] …`)? | prose style; whether the gate is worth having (that is the plan's decision) |
| **protocol** | the repo's own `AGENTS.md` / `templates/AGENTS.base.md` **and** the drift pins that bind them (`agent-infra:tests/materialize-agents/run.sh`, `scripts/check-skill-lint.mjs`, `scripts/ci/enforce-protocol-table.sh`) | Is a hard rule **weakened** rather than extended? Do the pinned anchors still hold (count and value)? Does the base ⊆ `AGENTS.md` pin still hold? | product behaviour; whether the rule is philosophically right |
| **docs-product** | the doc index it is placed in (`tortoise:docs/00_index.md`, Diátaxis) · the doc's own stated contract · canonical terms (`tortoise:docs/ONTOLOGY.md`) | Does every behavioural claim trace to code/tests **in that tree**, with a provenance? Do links resolve; is it in the index? Are canonical terms used? | absolute correctness of the world; code style; whether the feature is a good idea |
| **docs-marketing** | the marketing canon for that surface — **name the artifact in the contract**: category architecture, the positioning doc, the SEO target/keyword artifact (e.g. `eldato:docs/teams/*/domains (S1)/growth/`, `tortoise:website/functions/blog/_shared/seo-keywords.ts`), plus `skills/seo-content-generation` claim discipline | Is the claim aligned with the category architecture and the positioning line? Does it serve the declared SEO target? Does it claim a negative universal (forbidden by the content discipline)? | **code correctness** · **absolute factual correctness** — marketing argues a position; its bar is alignment with the canon, not a specification |
| **ops-infra** | the runbook it amends · `agent-infra:docs/ops/fleet-liveness.md` (declared-population rules) · the reap/ancestry rules in `AGENTS.md` | What happens when the tool **cannot answer** — fail closed, or declare the unread population? Is the effect reversible? Could it act on a human's terminal, or on a peer lane's claim or worktree? | product UX; prose taste; whether the box should exist |
| **research-decision** | the decision's own home (its issue, plan doc, or Tortoise point) · the `OVERRIDES:` convention in `AGENTS.md` | Is the evidence **measured and dated** (a provenance, not a recollection)? Was the contradiction test run before adoption? Is there an `OVERRIDES:` line where it departs from the default? | implementation detail; style; whether the topic is interesting |

**A mixed diff has a mixed contract.** One class per `### Review Scope Contract` block, split by **claim**, not by file: when a single file is simultaneously an executable instruction (gate-enforcement / code) and product prose (docs-product), declare both blocks and say which paths each covers. A file that carries two canons gets two reviewers' questions, not one reviewer's guess.

**Unknown class ⇒ `code` (strictest), recorded in the contract as `class-uncertain: <why>`.** The reviewer may re-declare the class in the same round if the artifact clearly belongs elsewhere — and must say so in its verdict. An unstated class is never "no questions"; a *guessed* class is never silent.

## The Review Scope Contract (declared by the author, before review)

The author writes this into the plan/scoping artifact — not into the reviewer's brief, and never after the review starts:

```markdown
### Review Scope Contract
**Class:** code | gate-enforcement | protocol | docs-product | docs-marketing | ops-infra | research-decision
**Risk surface** — what this change can break, each with the check that would catch it:
- R1 <failure this change can cause> → caught by <test / assertion / gate / measurement>
**Threat classes** (gate-enforcement only) — `T1 <bypass class>`, or `(not adversarial)`.
**Out of scope — must NOT be raised** (note, file, do not chase):
- pre-existing defects outside the diff · style/prose preference with no behaviour change
- architectures the plan did not propose · incidental test/fixture shape
**Acceptance:** every `R<n>` has its named evidence, and no open item remains on the declared surface.
```

**In scope** = a finding that is **(a) caused** by the diff, **(b) newly reachable or value-bearing because of it**, or **(c) purpose-defeating** — it defeats the change's stated objective or declared risk surface. Anything else is reported as `OUT-OF-SCOPE: <one line>` with a suggested issue title: recorded, filed, **not looped on**.

**Acceptance is coverage, not cycles.** The contract is met when every `R<n>` (and every `T<n>`, where declared) has its evidence — not when a review counter reaches a number. A reviewer that stops at *n* cycles with an uncovered `R<n>` has failed the contract, however long it ran.

## Reviewer output shape

```
NO ISSUES FOUND
```
or one block per in-scope finding, then any out-of-scope notes:

```
ISSUE: [P0|P1|P2] <R<n> | <class> — <what is wrong> — <evidence: file:line / command output> — <fix>
OUT-OF-SCOPE: <what> — suggested issue: <title>
```

- A finding with no `R<n>` and no (a)/(b)/(c) justification **must** be `OUT-OF-SCOPE`.
- Evidence is a command output or a `file:line` — and for a cited line, **open it and quote it**. Never an impression.
- The reviewer does not propose scope expansion; it may note one after `OUT-OF-SCOPE`.
- `THREAT SURFACE COVERED` is the clean exit **only** for a declared `Threat classes` block (gate-enforcement), and it must name the classes it checked.

## Boundaries

- **This skill does not decide review counts or cycle bounds.** Those are `proportional-gates` §Review Cycles (counts) and the contract above (acceptance). A surface-coverage exit is not a licence to stop early: uncovered `R<n>` items block.
- **It does not weaken the hard rules.** Attestation at the exact head, MCP/SDK surface approval, worktree isolation, and "never edit a PR body after recording a review" apply to every class — including `docs-marketing`.
- **It does not select reviewers.** Panel composition and depth stay with `code-review` (Step 3.6 risk class) and `proportional-gates`; this skill only says **which questions** that panel asks.

---
> Continue following the workflow as mandated by this skill. Do not skip steps.
