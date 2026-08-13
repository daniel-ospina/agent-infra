---
title: "Restore Fractal External Research in the Planning Pipeline (#231) — Implementation Plan"
type: engineering
domain: capability
doc_status: draft
subjects.team: organisation-design-team
created: 2026-08-13
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-231, fractal-research-ladder
---


<!-- research-path: docs/research/2026-08-13-fractal-research-embedding.md -->

# Restore Fractal External Research in the Planning Pipeline (#231) — Implementation Plan

> **For Pi:** Use `executing-plans` to implement this plan task-by-task.

**Goal:** Restore the granularity ladder for external research — epic brief → epic-plan substeps → issue-scope axes → issue-plan concrete queries → micro proportional — as an artifact-first, budget-bounded, verifier-enforced capability, without ritualizing it.

**Team:** organisation-design-team
**Role:** product-implementer

**Architecture:** Restore `issue-scoping` Phase 1.5 as the mid-pipeline research stage (v4 name, v5 placement), emitting `### Axis Research` + `### Integration Docs` blocks (v4 names — live consumer contracts). `### Pattern Research` stays the exclusive output of `writing-plans` Step B (sole author — executing-plans Step 1.5's dependency-coverage rule is keyed to that exact heading). Persistence goes through the restored `scripts/_research_append.sh` into a research brief with a `## Raw Notes` convention defined by the restored `skills/reference/research-protocol/SKILL.md`. The verifier gates gain a 5th dimension (research artifact) with a justified-skip escape hatch. Epic level gains hooks at epic-plan Architecture + Data Model substeps and granular per-axis queries in epic-scope; micro tier gains a proportional trigger in task-workflow.

### Pattern Research

> **Findings date:** 2026-08-14

**Library docs (preflight)** — no third-party deps in plan (skills/scripts/config only — `check-skill-lint.mjs`, `check-skill-links.sh`, `gh`, `bash` are existing in-repo tooling) — skipped.

**Library version & API surface** — skipped (zero third-party deps).
**Idiomatic usage patterns** — skipped (in-repo conventions only: body-text orchestration, workflow/*.md sub-files, `_research_path.sh`-style bash guards — 2+ in-repo examples).
**Library/framework pitfalls** — skipped (zero third-party deps).

> This plan self-demonstrates the contract it defines: the block carries a findings-date stamp, the skip carries a justification, and the underlying decisions are anchored in `docs/research/2026-08-13-fractal-research-embedding.md` (verified internal findings + external evidence, 4 queries across 2 categories).

### Integration Surface Map

| Surface | Producer → Consumer | Test layer |
|---|---|---|
| `### Axis Research` block | issue-scoping Phase 1.5 → writing-plans Step A.2 (PRIOR_RESEARCH) | lint + grep assertion (exact block name in both files) |
| `### Integration Docs` block | Phase 1.5 query findings + Phase 3 Codebase Explorer DEPENDENCIES → draft at solution-converge (4/5) → checked at solution-verify (5.5) → posted at Phase 8 → writing-plans Step A.2 | lint + grep assertion + phase-order assertion (5.5 before 8) |
| `### Pattern Research` heading | writing-plans Step B (sole author) → executing-plans Step 1.5 coverage rule | lint + grep assertion (not in issue-scoping output contract) |
| `> **Findings date:**` line | writing-plans Step B → executing-plans staleness check | grep assertion both sides |
| Research brief path | `_research_path.sh`/`_research_append.sh` → writing-plans Step A.2 fallback, issue-scoping Phase 0.5 | script self-test (bash) |
| `## Raw Notes` convention | research-protocol → all brief producers | grep assertion (defined in protocol) |
| research-protocol path | `skills/reference/research-protocol/SKILL.md` → 8+ skills | in-repo dangling-reference assertion (T-B; resolves every `../reference/...` target under `skills/`) |
| clarifying-questions `### Deferred to Research` | clarifying-questions Step 6b → issue-scoping Phase 1.5 Sub-step B | grep assertion (caller present) |
| Epic brief headings (`### Strategy Context` etc.) | epic-research → writing-plans Step A.1 | grep assertion (parity) |
| Verifier 5th dimension | issue-scoping problem-verify / solution-verify | grep assertion (dimension in both prompts) |


## Problem Statement

The planning pipeline's fractal external-research capability is structurally broken (verified through the full problem diamond; see research brief §Reframed Problem Statement):

1. **The stage was deleted:** issue-scoping v4's `Phase 1.5 — External Research` (axis matrix, multi-angle queries, codebase-first hybrid, persisted artifact) was removed in the v5.0.0 double-diamond restructure (#7501). #7501's intent was to fold *framing/adversarial* research into the diamond phases; the *external best-practice/pitfall import* function was dropped as a casualty, not by decision.
2. **Only prose remains:** the replacement is one soft instruction in the sub-agent dispatch preamble (`issue-scoping/SKILL.md:459` — "All agents MUST invoke the `research` skill internally"), which no verifier checks.
3. **Consumers dangle:** 5 files still reference "Phase 1.5" (`writing-plans/workflow/02-research-intake.md` Step A.2, `clarifying-questions` (4 lines), `issue-creation` §Research, `ux-design-review`, `writing-plans/workflow/01.5-ux-design-gate.md`). `writing-plans` Step A expects scoping-produced blocks that scoping never produces → the intake runs empty and the planning-phase Perplexity gate fires from zero prior findings.
4. **No persistence:** findings were never persisted across sessions; `scripts/_research_append.sh` was never ported to agent-infra.
5. **Epic-plan has zero research hooks:** all 8 substeps (User Journeys → Workflows → Prototype → Data Model → Architecture → Interfaces → Detailed E2E → Coherence Review) make architecture/data-model/UX decisions from model intuition.
6. **Micro tier is codebase-read only:** task-workflow's Research phase reads files but never fires external queries, even for third-party deps or novel patterns.
7. **Missing infrastructure:** `skills/reference/research-protocol/SKILL.md` is referenced by 8+ skills but absent from agent-infra (archived in eldato `_archive/`); `planning/shared/research` is a 2-line trivially-skippable stub.

**Behavioral consequence (owner-observed + structurally entailed):** decisions at every level converge on whatever the model already knows — no best-practice triangulation, no known-pitfall avoidance, no granularity. The pipeline's own docs still promise Phase 1.5 research; only the enforcement disappeared.

**Design intent being restored:** *prior-phase research is context, not a substitute.* The epic brief answers *why* and *what direction*; it cannot tell you which Supabase pattern fits the concrete notification flow. Each level re-researches with sharper specificity, bounded by demonstrated gaps.


## Proposed Solution — Approach B: Artifact-First Fractal Ladder

**Chosen approach:** **B** — full restoration per the confirmed problem. This is the only approach that satisfies all 8 issue indicators: it restores the scoping artifact (1), fixes the intake + skip rules (2), adds epic-scope granular queries (3), adds epic-plan hooks (4), adds the micro trigger (5), resolves all dangling refs (6), wires clarifying-questions (7), and restores the protocol + ported script (8).

The design decisions below resolve the 8 key risks identified in diverge analysis (numbered **R1–R8**):
- **R1** verifier ordering / skip-justification (D1, D2, D7)
- **R2** budget vs execution-intent (D3)
- **R3** freshness keyed to findings date (D4)
- **R4** exact-match naming collision (D5)
- **R5** cold-start / brief-absence (D8)
- **R6** clarifying-questions §2.4 contract safety (D6)
- **R7** epic-research section parity (D9)
- **R8** `## Raw Notes` persistence convention (D10)

Each is stated as a decision, not an option.

### D1 — Phase 1.5 placement: restored name, v5-compatible position (Risk: verifier ordering)

Phase 1.5 is restored with its **v4 numeric name** (`## Phase 1.5 — External Research (Standard + Complex)`) so every consumer reference ("issue-scoping Phase 1.5") becomes valid again, but it is **positioned between Phase 2 (problem-converge) and Phase 2.5 (problem-verify)** — after the problem is confirmed (axes are scoped from the confirmed problem + Phase 0 complexity ratings) and *before* problem-verify, so the verifier gate can check the artifact it produces (see D7). It feeds solution-diverge (Phase 4) as PRIOR_RESEARCH. Process flow becomes:

```
Phase 0/0.5 → 1 problem-diverge → 2 problem-converge
  → 1.5 External Research (axis matrix + question-driven + persistence)
  → 2.5 🛡️ problem-verify (5 dimensions — research artifact added)
  → 3 Codebase Explorer + UX Prototype → 4 solution-diverge → 5 solution-converge
  → 5.5 🛡️ solution-verify (5 dimensions) → 5.6 Qwen → 6 Wiring → 7 Parallel Review → 8 Finalize
```

Sub-step structure (kept so `clarifying-questions`' "seeds Phase 1.5 Sub-step B" wording stays true):
- **Sub-step A — Axis Research Matrix:** for each axis rated `medium+` (UX / Ontology / Architecture, from Phase 0 ratings; Library-deps axis triggered by third-party-dep detection in the issue body/affected files — there is no Phase 0 Library rating field in v5): codebase-first precedent scan → dedup against PRIOR_RESEARCH (epic brief / existing research brief) → fire external queries per axis using the per-bucket protocol (canonical / competitor-precedent / pitfalls). **Framing counts reconcile with D3 caps: 1–3 framings per axis, but the D3 cap is a post-dedup TOTAL — when the cap binds, lower-priority axes get 1 framing each (e.g., 3 medium+ axes at 3 framings = 9 > 8 cap → third axis drops to 1–2 framings, or one axis to 2). The cap is the contract; per-axis counts flex beneath it.**
- **Sub-step B — Question-Driven Research:** consume clarifying-questions `### Deferred to Research` queue (see D6) and the issue's `**Research:**` field; spend remaining budget on those questions.
- **Sub-step C — Persist:** append timestamped, source-tagged findings to the research brief via `_research_append.sh` (create-if-missing, sets `**Research:**` in the issue body); stage `### Axis Research` for the Phase 8 plan comment (`### Integration Docs` draft happens at solution-converge (Phase 4/5) from Phase 3 Codebase Explorer DEPENDENCIES + Sub-steps A/B findings — see Task 3 Step 4).

### D2 — Skip-justification escape hatch (Risk 1)

The gates must accept "no demonstrated gap." Phase 1.5 emits the `### Axis Research` block **either populated or as a justified skip**:

```
### Axis Research
> **Trigger assessment:** axes all low (UX=low, Ontology=low, Architecture=low); no third-party deps; no novel pattern (in-repo precedent: <path>). External research not demonstrated — skipped per activation rule.
```

**Activation rule (necessary-not-sufficient):** an axis rated `medium+` **cannot** be skipped by "no gap" (rating is a necessary trigger: `medium+` → must fire or justify *why the brief already covers it at sufficient granularity*, with a section citation). A low-rated axis **may** still fire when a demonstrated gap exists (new third-party dep, novel pattern, codebase-first scan (Sub-step A) verified absence of precedent) — this is the "necessary-not-sufficient" direction that prevents both silent skips and checkbox ritualization. **Cap-constrained high axes (H4):** when the D3 cap binds and a high-rated axis is reduced to one framing, that framing MUST be the pitfalls/adversarial one (canonical-only for a capped high axis is P1 under D7). Verifier dimension 5 (D7) accepts the justified-skip block verbatim as passing, mirroring writing-plans' existing `> Gate skipped` / `> Bucket [name] skipped` convention. **Skip precedence (H5):** a justified-skip block takes precedence over findings-date-absence — a plan whose `### Pattern Research` is a documented `> Research skipped: no demonstrated gap` is NOT re-verified at execution even without a findings-date stamp.

### D3 — Budget vs execution-intent (Risk 2)

Phase 1.5 reads `EXECUTION_INTENT` (execution-intent skill) and shapes spend per profile, **after** PRIOR_RESEARCH dedup (deduplicated questions are skipped with a `> Deduplicated: covered by <parent brief section>` note and never counted):

| Intent | Phase 1.5 shape | Caps (post-dedup) |
|---|---|---|
| **Fast** (default) | Full axis matrix, per-bucket protocol | Standard ≤ 8 external queries; Complex ≤ 14 |
| **Autonomous** | Full matrix, no early-exit | Same caps; never skip a medium+ axis |
| **Budget** | Codebase-only + ≤ 2 queries, fired **only** on P0-level gaps (new third-party dep or novel pattern with zero in-repo precedent) | ≤ 2; document the skip in the trigger assessment |

This prevents double-charging: per execution-intent, **Complex + Budget** already skips writing-plans' Perplexity gate (execution-intent table); under Budget the ladder's shape (codebase-only + 1–2 queries) is the *only* external spend the session makes. (Standard + Budget is undocumented in execution-intent — the plan defines Phase 1.5 ≤ 2 queries + the writing-plans gate as the total session budget for that case.) Budget + Micro = codebase-read only, consistent with existing intent×tier interaction.

**Epic-tier Budget shape (covers Task 8 + epic-scope):** under `EXECUTION_INTENT=Budget`, epic-plan research hooks and epic-scope Step 0 **defer to the epic brief** (codebase + brief only, zero external queries) — consistent with the existing Complex+Budget intent table; the epic brief is the epic-tier research surface in Budget mode.

**Standard+Budget policy home:** execution-intent documents Micro+Budget and Complex+Budget but not Standard+Budget. Task 3 lands a one-line addition to execution-intent's Budget section (Standard+Budget: Phase 1.5 ≤ 2 queries, codebase-first, no double-charge with the writing-plans gate) so the shape lives in the canonical reference, not only in issue-scoping.

### D4 — Freshness: findings-date keyed staleness (Risk 3)

- `writing-plans` Step B prepends `> **Findings date:** YYYY-MM-DD` to the `### Pattern Research` block (same line shape as the skip justifications — greppable).
- `executing-plans` Step 1.5 staleness check (currently `executing-plans/SKILL.md:182`, plan-date keyed) becomes findings-date keyed: parse the `> **Findings date:**` line. **Findings-date ABSENT → treat as unfamiliar (fail-safe re-verify) — no plan-date fallback for the coverage question.** Findings-date present → stale if older than 6 months by findings date (threshold unchanged). Staleness is purely findings-date keyed; plan date plays no role in the new algorithm.
- Legacy plans (pre-stamp) therefore default to the fail-safe path: they get re-verified at execution. This is the accepted cold-start cost; the stamp propagates forward as plans are written under the new contract. (Rationale: legacy plans always carry a recent plan date — a plan-date fallback would mark a 2-month-old unstamped plan as fresh and covered, silently inheriting stale findings; exactly the DRIFT/STALE failure this issue exists to fix. Findings-date absence is the unambiguous signal.)

### D5 — Exact-match authorship boundary (Risk 4) — **contract redefinition, verified against v4**

Verified v4 reality (eldato archive, reachable): v4 scoping emitted `### Axis Research` **and** `### Pattern Research`; `### Integration Docs` never appeared in v4 scoping (it is a consumer-side expectation from writing-plans `02-research-intake.md:22`). v4 executing-plans consumed the **plan's** `### Pattern Research` (plan doc), never scoping's. Therefore:

- **`### Axis Research`** — restored v4 name (confirmed).
- **`### Integration Docs`** — **new formalized producer contract** (no v4 provenance); the name is kept because the current consumer (writing-plans Step A.2) already expects it — keeping it minimizes churn; it is a real redefinition, not a restoration.
- **`### Pattern Research`** — **deliberately reassigned** from v4's scoping emission to writing-plans Step B exclusively. Rationale: v4 had dual emission (scoping → issue comment; Step B → plan doc); executing-plans' coverage rule reads only the plan doc, so scoping's copy was dead weight that invited copy-into-plan contamination (the PM1 hazard). Reassignment eliminates the hazard. This is a **contract redefinition** — surfaced in the PR description for issue-owner sign-off (the issue's literal target wording mentions `### Pattern Research` from scoping; the plan amends it).
- `executing-plans` Step 1.5 parse instruction is tightened to an **anchored, line-level exact heading match** (`^### Pattern Research$` within the plan doc) and gains an explicit note: epic-brief headings such as `### UX Pattern Research` / `### Tech Stack Research` are PRIOR_RESEARCH context and **never** satisfy the dependency-coverage rule. This kills the substring-collision path where an epic heading falsely satisfies Step 1.5.
- `writing-plans` Step A.2's intake list changes to `### Axis Research` + `### Integration Docs` (produced by scoping); Step A.2 explicitly does not consume `### Pattern Research` (Step B owns it).

### D6 — clarifying-questions rewiring (Risk 6)

- `issue-scoping` becomes the planning-pipeline caller: after Phase 0.5 (epic/deps detection), before Phase 1, invoke `clarifying-questions` with `mode=issue-pre`, `tier`, and the issue body as context. Its `### Clarifications` block is embedded in the Phase 8 plan comment; its `### Deferred to Research` block seeds Phase 1.5 Sub-step B.
- **Consumption contract preserved:** the call is **additive**. clarifying-questions' caller protocol (mode/tier/context) and both output block formats (`### Clarifications`, `### Deferred to Research`) are unchanged — strategy-builder §2.4 (`workflow/02-full-build-frameworks.md:87`, GTM domain) keeps working identically. No rewording of the output blocks, no change to Pass A/B scoring.
- clarifying-questions' internal "Phase 1.5" references (lines 144/182/319/323) become valid as written once Phase 1.5 exists (Sub-step B). Verify: `grep -rn "clarifying-questions" skills/issue-scoping/SKILL.md` → ≥ 1 call site; `grep -rn "Deferred to Research" skills/issue-scoping/SKILL.md` → consumed.

### D7 — Gate-specific verifier checks (Risk 1 enforcement)

**problem-verify (Phase 2.5) gains dimension 5 — RESEARCH ARTIFACT:**
- `### Axis Research` block present in the scoping output, **or** a justified-skip trigger assessment (D2) — presence of a populated block with a bare section title but no findings is P2 (ritualization check: findings must be content, not section headers).
- Findings carry provenance: per-framing source attribution (canonical / competitor-precedent / pitfalls + source name or URL).
- Adversarial/disconfirming evidence: for each axis rated high, at least one query framing seeks failure modes or counter-evidence (the pitfalls framing satisfies this; a canonical-only axis is P1).
- Justified-skip validity: an axis rated `medium+` skipped without a brief-coverage citation is P1.
- P1 if artifact absent without justification; P1 if a high-rating axis has zero external findings; P2 if citations are weak.

**solution-verify (Phase 5.5) gains dimension 5 — SOLUTION RESEARCH EVIDENCE:**
- Solution-level research updated: new third-party deps / patterns introduced by the chosen approach are verified (the `### Integration Docs` block lists dep + version + API-surface findings) **or** justified-skipped (dep already used elsewhere in codebase, or in-repo wrapper).
- P1 if the chosen approach introduces a dep with zero external verification and no in-repo precedent.

**Micro** (full-diamond-verify): merged single check — artifact or justified skip, provenance, adversarial evidence for any fired axis.

**Plan gate (writing-plans):** `plan-review` (workflow/05) gains a check that the plan's `### Pattern Research` block carries the `> **Findings date:**` stamp or a skip justification — this is the fresh-query evidence gate (Step B ran or cleanly skipped).

**Qwen coherence check (Phase 5.6):** the Qwen cross-diamond reviewer also receives the Phase 1.5 research artifact (`### Axis Research` + `### Integration Docs`) as an input and cross-checks the chosen approach's dependency claims against it — a cheap anti-hallucination strengthening (the existing Qwen prompt gains one line; not a new gate).

### D8 — Cold-start (Risk 5)

- Phase 0.5's `RESEARCH_BRIEF_PATH` empty result **never disables Phase 1.5**. The phase runs regardless; persistence creates the brief on first append.
- `_research_append.sh` (ported) resolves the brief path with the same resolution order as `_research_path.sh` (`**Research:**` field → epic sibling), **creates the brief if missing** (header + `## Raw Notes` + `### Axis Research` skeleton), then `gh issue edit` backfills `**Research:** <path>` into the issue body so subsequent sessions and `_research_path.sh` consumers resolve it.
- First N runs on empty PRIOR_RESEARCH simply have nothing to dedup — the matrix fires in full (bounded by D3 caps). The fix does not depend on inheritance.

### D9 — Epic-brief section parity (Risk 7)

`epic-research` is **producer-authoritative** for brief headings. Canonical set (unchanged names, now documented as the contract):

```
## Epic Research Brief — <title>
### Strategy Context
### UX Pattern Research
### Workflow Pattern Research
### Tech Stack Research
### Assumptions Register
## Raw Notes   ← see D10
```

`writing-plans` Step A.1 currently reads `## Strategy`, `## Tech Stack`, `## UX Patterns`, `## Assumptions Register` — **none of which exist**. Step A.1 is updated to consume the canonical headings (`### Strategy Context`, `### Tech Stack Research`, `### UX Pattern Research`, `### Assumptions Register`). `epic-research` gains a line in its Step 3 making the heading set the contract, so future drift is caught at the producer.

### D10 — `## Raw Notes` persistence convention (Risk 8)

Defined in the restored research-protocol (the protocol restores carry it into agent-infra):

- Research briefs (epic sibling `research-brief.md` or `docs/research/<slug>.md`) have a `## Raw Notes` section.
- Entries are **append-only, reverse-chronological**, each: timestamp, framing label (canonical / competitor / precedent / pitfalls / adversarial), query or question reference, findings, source tag.
- Synthesized sections (`### Axis Research`, `### Pattern Research`, brief sections) may be updated per level (D4/D7 traceability — updates are documented, not silent rewrites: `[updated YYYY-MM-DD — <what changed>]`).
- `_research_append.sh` enforces the append-only shape mechanically.

### D11 — Granularity ladder summary (what each level does)

| Level | Stage | Fire trigger | Output | Fresh queries |
|---|---|---|---|---|
| Epic | epic-research brief | Always (existing) | 5-section brief + `## Raw Notes` | 6+ (existing) |
| Epic | epic-plan substeps (Architecture, Data Model; light hooks at UX precedent, Interface contracts) | Demonstrated gap at the decision point (novel pattern, new integration, brief too broad for the decision) | `### Architecture Research Notes` / `### Data Model Research Notes` blocks in the epic plan doc, findings-date + provenance; substep review gates check presence-or-justified-skip | 1–3 per hook |
| Epic | epic-scope | Complexity axis rated medium+ AND brief too broad for boundary decisions | `### Axis Research Notes` in scope doc, deduped against brief | ≤ 4 total |
| Project/Task (standard+) | issue-scoping Phase 1.5 | D2 activation rule | `### Axis Research` + `### Integration Docs` (persisted) | 8/14 caps (D3) |
| Project/Task (standard+) | writing-plans Step B | Third-party deps / novel patterns in the concrete plan | `### Pattern Research` (sole author) + findings-date | 3+ per bucket (existing) |
| Task (micro) | task-workflow Research | Third-party deps or novel pattern (no in-repo precedent) | Inline `> Research note:` line in the task plan comment (findings-date + provenance); Budget mode: skip | 1–2 |


## Implementation Plan

### Task 1: Restore `skills/reference/research-protocol/SKILL.md`

**Intent:** Re-establish the governing research protocol that 8+ skills reference (`../reference/research-protocol/SKILL.md`) — without it, every restored research surface lacks its normative frame (five dimensions: best practices, challenge definition, internal+external, adversarial, don't reinvent) and the `## Raw Notes` convention (D10) has no home.

**Acceptance:** `skills/reference/research-protocol/SKILL.md` exists with lint-clean frontmatter (`name: research-protocol`, `type: reference`, `domain: capability`); the in-repo dangling-reference assertion (T-B replacement) finds zero unresolved `../reference/...` targets; the file documents the five dimensions, the per-bucket query protocol, and the `## Raw Notes` append-only convention; `check-skill-lint.mjs` passes on the new file.

**Files:**
- Create: `skills/reference/research-protocol/SKILL.md`

**Steps:**
1. **Frontmatter compliance (lint gate):** verify/correct the file's frontmatter first — `name: research-protocol` (must equal dir name — check-skill-lint name==dir rule, no shared- exemption here), `type: reference` (exempt from the allowed-tools requirement; `Bounded`/`Workflow`/`Routing` would fail lint), non-empty `description`, `domain: capability`. Matches existing reference-type skills (question-format, parallel-orchestrator, human-input-framework).
2. **Verify the v4 block-name anchor — DONE (verified 2026-08-13, eldato reachable via gh api):** v4 scoping emitted `### Axis Research` + `### Pattern Research`; `### Integration Docs` has no v4 provenance (consumer-side expectation from writing-plans Step A.2). D5 is accordingly framed as a **contract redefinition** (see D5). Re-verify if the PR review disputes: `gh api repos/daniel-ospina/eldato/contents/_archive/pi-skills/issue-scoping/SKILL.md`.
3. Reconstruct/port the protocol from the five dimensions documented in `skills/research/SKILL.md` (Research Discipline + self-audit block) and the research brief's protocol summary; the eldato archive copy (`_archive/pi-skills/skills/reference/research-protocol/SKILL.md`) is reachable via gh api and may be ported verbatim as the base — but the frontmatter must still pass lint (step 1).
4. Have the reconstruction reviewed by a fresh-context reviewer per the plan-review gate.
5. Add D10 (`## Raw Notes` convention) and a granularity-ladder section referencing the D11 levels.
6. Run lint + the in-repo dangling-reference assertion (T-B replacement).

**Ordering note:** Must land before Tasks 3–5 (they cite the restored path). Pure addition — nothing breaks mid-change.


### Task 2: Create `scripts/_research_append.sh` (new script — v4-adjacent semantics, deliberate deviations)

**Intent:** Give every research stage a mechanical, idempotent persistence path — the cold-start guarantee (D8) that findings survive across sessions and that `**Research:**` backfills into the issue body.

**Acceptance:** Script exists and is executable; `--create` on a missing brief creates header + `## Raw Notes` + `### Axis Research` skeleton (and creates `## Raw Notes` inside an existing brief that lacks it); append preserves existing content and appends timestamped entries; same-resolution-order as `_research_path.sh`; `--self-test` (bash unit) passes including the brief-exists-but-no-Raw-Notes case; offline mode: local brief creation proceeds, `gh issue edit` backfill silently skipped (documented, not swallowed as success).

**Note (v4 provenance):** v4's `_research_append.sh` took positional args and *errored* on missing target/Raw Notes — this script is a deliberate redesign (resolution order from `_research_path.sh`, create-if-missing, backfill). Label it as new, not a verbatim port.

**Files:**
- Create: `scripts/_research_append.sh`
- Test: inline self-test block (run with `bash scripts/_research_append.sh --self-test`)

**Steps:**
1. Port the v4 script shape (resolution order copied from `_research_path.sh`: `**Research:**` field → epic sibling; `--issue-body` + optional `--epic-path`).
2. Implement `--append "<text>"` (timestamped, source-tagged) and `--create` (brief-if-missing + `gh issue edit` `**Research:**` backfill, guarded by `|| true` like `_research_path.sh` callers).
3. Enforce `## Raw Notes` append-only shape per D10 — **create `## Raw Notes` if absent** (same create-if-missing semantics as `--create`; covers briefs written before this change that lack the section), not validate-only.
4. Add `--self-test` covering: create-on-missing-brief, append-preserves, brief-exists-but-no-Raw-Notes (section created), idempotency; run it.


### Task 3: Restore `issue-scoping` Phase 1.5 + verifier 5th dimension + clarifying-questions wiring

**Intent:** Re-create the mid-pipeline research stage with a persisted, verifier-checked artifact — the core of indicator 1. Restore the v4 axis matrix with v5-compatible placement (D1), activation rule (D2), intent-bounded budget (D3), and the Pass B queue seeding (D6).

**Acceptance:** `skills/issue-scoping/SKILL.md` contains a `## Phase 1.5 — External Research (Standard + Complex)` section with Sub-steps A/B/C; `### Axis Research` and `### Integration Docs` appear in the output contract (Phase 8 post-comment template); Process Flow shows Phase 1.5 between Phase 2 and 2.5; problem-verify and solution-verify prompts each contain a 5th dimension (research artifact); the justified-skip trigger assessment is accepted by the verifier dimension; a clarifying-questions call site exists (mode=issue-pre); `_research_append.sh` invocation in Sub-step C; Budget/Fast/Autonomous shapes per D3.

**Files:**
- Modify: `skills/issue-scoping/SKILL.md`
- Modify: `skills/execution-intent/SKILL.md` (one-line Standard+Budget row in the Budget section, per D3 policy-home decision)

**Steps:**
1. Add Phase 1.5 section between Phase 2 (problem-converge) and Phase 2.5 (problem-verify) in the Process Flow list + body; keep the v4 numeric name.
2. Sub-step A — axis matrix: codebase-first precedent scan → dedup vs PRIOR_RESEARCH → per-bucket protocol queries (canonical / competitor-precedent / pitfalls), 1–3 per medium+ axis; emit `### Axis Research` output contract with per-framing citations.
3. Sub-step B — question-driven research: consume clarifying-questions `### Deferred to Research` + the issue's `**Research:**` field; spend remaining budget.
4. Sub-step C — persist via `_research_append.sh`; stage `### Axis Research` (from Sub-steps A/B findings) for the Phase 8 post comment. `### Integration Docs` (deps + versions + API-surface findings) is **drafted at solution-converge (Phase 4/5)** from Codebase Explorer DEPENDENCIES (Phase 3 — runs before Phase 4) + Phase 1.5 query findings; solution-verify (Phase 5.5) checks the draft (D7); Phase 8 posts the finalized block. This keeps producer→checker ordering coherent: 1.5 emits findings → 3 maps deps → 4/5 assembles draft → 5.5 verifies → 8 posts. **Disambiguation (P4):** `### Integration Docs` (scoping output, posted in the issue comment) is distinct from the plan doc's `### Integration Surface Map` (test-design output embedded at writing-plans Step C) — different documents, different consumers; never merge or relocate.
5. Activation rule + justified-skip block (D2).
6. Execution-intent budget shapes + caps (D3).
7. Verifier prompts: add dimension 5 to problem-verify and solution-verify per D7; Micro full-diamond-verify merged check; Qwen 5.6 prompt gains one line — receives `### Axis Research` + `### Integration Docs` as inputs and cross-checks the chosen approach's dependency claims against them (D7; not a new gate).
8. Add clarifying-questions invocation (after Phase 0.5, mode=issue-pre) + embed `### Clarifications` in the Phase 8 comment template.
9. Land the execution-intent Standard+Budget line (per D3): `EXECUTION_INTENT=Budget` + Standard tier → Phase 1.5 ≤ 2 queries, codebase-first.
10. **D5 sign-off (H1):** before implementation, comment the D5 contract-redefinition on issue #231 (v4 facts: scoping emitted `### Axis Research` + `### Pattern Research`; `### Integration Docs` is a new producer name kept for the current consumer; `### Pattern Research` reassigned to Step B) and mirror it in the PR description — this amends the issue's literal target wording and needs owner acknowledgement BEFORE the PR is built.

**Ordering note:** This is the biggest task and the producer half of the producer-consumer pair. It must land atomically with Task 4 (writing-plans) — Task 4's Step A.2 consumes the restored blocks; landing Task 3 alone leaves the same dangling expectation. Task 3 requires Tasks 1–2 (paths + script).


### Task 4: Fix `writing-plans` research intake (Step A.1 parity, Step A.2 consumption, Step B findings-date + skip-rule split)

**Intent:** Make the planning-phase intake actually run on scoping findings instead of starting empty (indicator 2), fix the epic-brief heading parity (D9), add the findings-date stamp that executing-plans' freshness depends on (D4), and stop the zero-deps skip rule from zeroing out prior-research intake.

**Acceptance:** Step A.2's intake list is `### Axis Research` + `### Integration Docs` (produced by scoping) with the fallback to the research brief; Step A.1 reads the canonical epic-research headings; Step B prepends `> **Findings date:** YYYY-MM-DD` to `### Pattern Research`; the top-of-skill Skip Rules explicitly apply to Step B only — Step A always runs and consumes the scoping artifact; Step B output persists to `## Raw Notes` per D10.

**Files:**
- Modify: `skills/writing-plans/SKILL.md` (Skip Rules section)
- Modify: `skills/writing-plans/workflow/02-research-intake.md` (Step A.1 epic-brief heading read at line 20, Step A.2 intake list, Step B stamp + Raw Notes)
- Modify: `skills/writing-plans/workflow/05-review-handoff.md` (plan-review check: findings-date or skip justification — currently has no research check)

**Steps:**
1. Step A.2: intake list → `### Axis Research` + `### Integration Docs`; add research-brief fallback (`### Axis Research` section in the resolved brief); explicit note that `### Pattern Research` is Step B's exclusive output and is not consumed here.
2. Step A.1: consume the canonical epic-research headings (D9).
3. Step B: prepend `> **Findings date:** YYYY-MM-DD`; persist to `## Raw Notes` per D10 with update-traceability note.
4. Skip Rules: split — the zero-third-party-deps skip applies to Step B (the Perplexity gate) only; Step A always runs (cheap intake; consumes scoping artifact). Standard+ plans can no longer have their research zeroed by the skip.
5. plan-review (workflow/05): verify `### Pattern Research` stamp or skip justification (fresh-query evidence gate, D7).

**Ordering note:** Land atomically with Task 3 (same PR). Requires Task 1 (protocol path) + Task 7's heading parity (epic-research canonical headings must be decided first — Task 7 is pulled ahead into PR 1 for this reason).


### Task 5: Fix `executing-plans` Step 1.5 freshness + exact-match coverage

**Intent:** Key staleness to findings date (D4) and make the dependency-coverage rule exact-match (D5) so epic-brief headings can never falsely satisfy it — indicator-adjacent hardening of the execution gate.

**Acceptance:** The staleness rule at `executing-plans/SKILL.md:182` keys to `> **Findings date:**` with **findings-date ABSENT → unfamiliar directly** (no plan-date fallback for the coverage question) and treat-as-unfamiliar default; the parse instruction uses an anchored exact-heading match (`^### Pattern Research$`); the rule notes epic-brief headings are not coverage evidence; the justified-skip block (`> Research skipped: no demonstrated gap` / `> Gate skipped`) is **excluded from the unfamiliar path** (a deliberate skip is not stale findings — see G7 fix).

**Files:**
- Modify: `skills/executing-plans/SKILL.md` (Third-Party Dependency Detection steps 3–5 + Sub-step 1.5a)

**Steps:**
1. Update step 3 (parse): anchored exact heading; extract findings-date line.
2. Update step 5 (unfamiliar): **findings-date ABSENT → unfamiliar directly** (fail-safe re-verify, no plan-date fallback for the coverage question); findings-date present → stale if older than 6 months by findings date (staleness threshold unchanged); **justified-skip blocks excluded from the unfamiliar path** (executing-plans:177 — "skipped with valid reason → covered" — must remain valid for the D2 trigger-assessment skip; a zero-dep plan that legitimately skips is NOT re-verified at execution; skip-justification precedence over findings-date-absence per H5); **preserve the existing major-version-mismatch unfamiliar trigger unchanged** (plan references a different major version than imported, executing-plans:183). **Vocabulary stitch (H5):** the D2 scoping skip (`> **Trigger assessment:**`) propagates into the plan-doc block as the executing-plans-recognized `> Gate skipped`/`> Research skipped:` justification — writing-plans Step B documents the bridge (02-research-intake.md:50 "document the skip in the output block").
3. Add explicit exclusion note: `### UX Pattern Research` / `### Tech Stack Research` (epic brief) are PRIOR_RESEARCH context, never coverage evidence.

**Ordering note:** Depends on Task 4's findings-date stamp. Safe to land in the same PR.


### Task 6: Resolve all remaining dangling Phase 1.5 references

**Intent:** Indicator 6 + the issue's target (`grep -rn "Phase 1.5" skills/` → only refs to the real, restored phase).

**Acceptance:** Every `Phase 1.5` match in `skills/` refers to the restored `issue-scoping` Phase 1.5; `Phase 1.5a` appears nowhere; `check-skill-lint.mjs` passes; the in-repo dangling-reference assertion (T-B) passes.

**Files:**
- Modify: `skills/issue-creation/SKILL.md` (line ~173: §Research wording updated to name the restored phase's artifact — "feeds `issue-scoping` Phase 1.5's `### Axis Research` matrix"; micro skip unchanged)
- Modify: `skills/ux-design-review/SKILL.md` (lines 27, 105: "Phase 1.5a (UX Prototype Gate)" → "Phase 3 (UX Prototype Gate)")
- Modify: `skills/writing-plans/workflow/01.5-ux-design-gate.md` (line 27: same Phase 1.5a → Phase 3)
- Modify: `skills/clarifying-questions/SKILL.md` (verify lines 144/182/319/323 now point at the real Sub-step B; adjust wording only if the restored sub-step naming differs; **update the stale frontmatter description** — it claims "Invoked by epic-workflow and issue-scoping at defined insertion points" but the sole real callers are strategy-builder §2.4 (GTM) and, after this fix, issue-scoping (mode=issue-pre) — drop the epic-workflow claim)

**Steps:**
1. Audit: `grep -rn "Phase 1.5" skills/` — classify each match: valid (restored phase) vs stale (1.5a).
2. Fix the 1.5a drift in ux-design-review + 01.5 (the UX Prototype Gate is Phase 3 in v5).
3. Update issue-creation §Research wording to the restored artifact name.
4. Final grep assertion run.

**Ordering note:** Depends on Task 3 (restored phase). Pure reference hygiene — safe at the end of PR 1.


### Task 7: Epic-research heading parity (canonical brief contract)

**Intent:** Resolve D9 — make the brief heading set an explicit producer contract so `writing-plans` Step A.1 (Task 4) consumes real headings.

**Acceptance:** `skills/epic-research/SKILL.md` Step 3 documents the canonical 5-section heading set + `## Raw Notes`; sections unchanged (no rename risk to existing briefs); check-skill-lint passes.

**Files:**
- Modify: `skills/epic-research/SKILL.md` (Step 3 — heading set as contract + Raw Notes)

**Steps:**
1. Add a "Canonical brief structure" block in Step 3 listing the headings.
2. Note the D10 Raw Notes convention.

**Ordering note:** Pulled into PR 1 (before Task 4) because Step A.1 parity depends on the canonical set being fixed. Additive — safe.


### Task 8: Epic ladder — epic-plan research hooks + epic-scope granular queries

**Intent:** Indicators 3 + 4 — decision-point research in the epic pipeline with persisted output and gate checks, deduped against the epic brief.

**Acceptance:** `skills/epic-plan/SKILL.md` substeps 4 (Data Model) and 5 (Architecture) each have a research hook (query template: canonical / competitor-reference / pitfalls; persisted output `### Architecture Research Notes` / `### Data Model Research Notes` with findings-date + provenance; substep review gate checks present-or-justified-skip); light documented hooks at substeps 1 (UX precedent) and 6 (Interface contract patterns) fire only on demonstrated gaps; `skills/epic-scope/SKILL.md` has a Step 0 granular per-axis query pass (`### Axis Research Notes`, ≤ 4 queries, deduped against the brief, fires only where the brief is too broad for boundary decisions).

**Files:**
- Modify: `skills/epic-plan/SKILL.md` (substeps 4, 5 mandatory hooks; 1, 6 light hooks; gate language)
- Modify: `skills/epic-scope/SKILL.md` (Step 0 + output block)

**Steps:**
1. epic-plan substep 5 (Architecture): add research hook — query template (3 framings), persisted output block, gate check.
2. epic-plan substep 4 (Data Model): same.
3. epic-plan substeps 1 (UX precedent) and 6 (Interface contracts): light documented hooks with demonstrated-gap trigger only.
4. epic-scope Step 0: per-axis granular queries where the brief is too broad; output `### Axis Research Notes`; **its existing Review Gate (epic-scope/SKILL.md:~104) gains a checklist line: whenever a complexity axis is rated `medium+`, the gate checks `### Axis Research Notes` present-or-justified-skip (justified = cited brief section) — symmetric with the epic-plan hooks, closing the epic-tier enforcement loss.**

**Ordering note:** PR 2 (additive — nothing in PR 1 breaks if these land after). Requires Task 1 (protocol) + Task 7 (brief contract). **Budget-trim note:** the epic tier is the first lever under budget pressure — its Budget-mode shape already defers to the brief (zero external queries), and if the outcome metric (Verification Plan step 4) shows low epic-tier utilization, Task 8's hooks can be reduced to documentation-only deferral defaults without touching PR 1.


### Task 9: Micro tier proportional trigger + shared-research mechanics

**Intent:** Indicators 5 + the stub gap — micro tasks get external research when the task demonstrates a gap (third-party deps or novel pattern), and the shared-research stub gains gate mechanics + output contract so it is no longer trivially skippable.

**Acceptance:** `skills/task-workflow/SKILL.md` Research phase (line ~60) gains the proportional trigger: after the codebase check, fire 1–2 external queries (canonical usage + pitfalls) when the task touches third-party deps or a novel pattern with no in-repo precedent; findings recorded as an inline `> Research note:` line with findings-date + provenance in the task plan comment; Budget mode skips external queries; `skills/task-workflow-standard/SKILL.md` documents that its research stage = issue-scoping Phase 1.5 artifact + writing-plans Step B re-derivation; `skills/planning/shared/research/SKILL.md` stub expanded with (1) PRIOR_RESEARCH dedup rule, (2) gate mechanics (fresh-context reviewer checks brief completeness + adversarial balance), (3) output contract (fixed sections + `## Raw Notes` + findings-date).

**Files:**
- Modify: `skills/task-workflow/SKILL.md`
- Modify: `skills/task-workflow-standard/SKILL.md`
- Modify: `skills/planning/shared/research/SKILL.md` (remove `status: stub`)

**Steps:**
1. task-workflow Research phase: proportional trigger + inline research-note output + Budget shape.
2. task-workflow-standard: one-line research-path documentation.
3. shared-research: expand to the 3-part mechanics; drop the stub status.

**Ordering note:** PR 2. Requires Task 1 (protocol) for the output-contract references.


## Task Ordering Summary (what lands when)

**PR 1 — "Restore the scoping→planning research contract" (atomic producer-consumer chain):**
`T1 research-protocol` → `T2 _research_append.sh` → `T7 epic-research parity` → `T3 issue-scoping Phase 1.5 + verifier + clarifying-questions` → `T4 writing-plans intake` (lands **atomically** with T3) → `T5 executing-plans freshness` → `T6 dangling refs`

**PR 2 — "Epic + micro ladder levels" (additive capability tiers):**
`T8 epic-plan hooks + epic-scope queries` → `T9 micro trigger + shared-research`

Rationale: PR 1 must land as one unit because T3 produces the artifact and T4 consumes it — landing either alone recreates the dangling expectation. T5 depends on T4's findings-date stamp. T6 is reference hygiene enabled by T3. PR 2 is additive; nothing in PR 1 breaks if PR 2 lands later, and vice versa.


## Testing Strategy

This is a skills/config change — the verification surface is lint + link integrity + grep assertions, per the Codebase Explorer's RECOMMENDED_TESTS framing for org-infra work. Concrete assertions, all run in CI pre-merge:

| # | Assertion | Command | Fails when |
|---|---|---|---|
| T-A | Frontmatter valid on all touched skills | `node scripts/check-skill-lint.mjs` | exit ≠ 0 |
| T-B | No broken in-repo skill references (agent-infra runnable) | For each `../reference/...` target found in `skills/**/*.md` (grep -oE), assert the target file exists under `skills/` (bash loop, exit 1 on missing). **Not** `check-skill-links.sh` — that script is consumer-repo-only (guards abort in agent-infra) and does not inspect markdown reference resolution | any unresolved target |
| T-C | Restored phase exists | `grep -n "## Phase 1.5 — External Research" skills/issue-scoping/SKILL.md` | no match |
| T-D | Scoping output contract present | `grep -n "### Axis Research" skills/issue-scoping/SKILL.md` && `grep -n "### Integration Docs" skills/issue-scoping/SKILL.md` | no match |
| T-E | Pattern Research authorship boundary | `grep -n "### Pattern Research" skills/issue-scoping/SKILL.md` → only prose documentation of the boundary (e.g. "reserved exclusively for writing-plans Step B"), **zero occurrences inside the Phase 8 output-contract template / `### Axis Research` block spec** | any occurrence inside the output contract (scoping must not emit Step B's block; documentation mentions are allowed) |
| T-F | Intake consumes restored blocks | `grep -n "### Axis Research" skills/writing-plans/workflow/02-research-intake.md` | no match |
| T-G | Findings-date contract both sides | `grep -in "absent.*unfamiliar\|unfamiliar.*absent" skills/executing-plans/SKILL.md` (fail-safe: findings-date absence → treat as unfamiliar, no plan-date fallback for coverage; case-insensitive) && `grep -n "Findings date" skills/writing-plans/workflow/02-research-intake.md` && `grep -n "Findings date" skills/executing-plans/SKILL.md` | either missing |
| T-H | Exact-match coverage note | `grep -n "Pattern Research\b.*anchor\|anchored" skills/executing-plans/SKILL.md` | no match |
| T-I | No stale 1.5a refs | `grep -rn "Phase 1.5a" skills/` | any match |
| T-J | Every Phase 1.5 ref names the restored phase | `grep -rn "Phase 1.5" skills/` manual audit | any ref not resolving to issue-scoping Phase 1.5 |
| T-K | Verifier 5th dimension present | `grep -c "RESEARCH ARTIFACT" skills/issue-scoping/SKILL.md` ≥ 1 (problem-verify dimension title) && `grep -c "SOLUTION RESEARCH EVIDENCE" skills/issue-scoping/SKILL.md` ≥ 1 (solution-verify dimension title) | either < 1 |
| T-L | clarifying-questions wired | `grep -n "clarifying-questions" skills/issue-scoping/SKILL.md` && `grep -n "Deferred to Research" skills/issue-scoping/SKILL.md` | either missing |
| T-M | Epic-plan hooks | `grep -n "Research Notes\|research hook" skills/epic-plan/SKILL.md` ≥ 2 (Architecture + Data Model) | < 2 |
| T-M2 | Epic-scope gate + output | `grep -n "Axis Research Notes" skills/epic-scope/SKILL.md` (output block) && `grep -n "Axis Research Notes\|present-or-justified-skip" skills/epic-scope/SKILL.md` review-gate line | either missing |
| T-M3 | execution-intent Standard+Budget row | `grep -n "Standard + Budget" skills/execution-intent/SKILL.md` | no match |
| T-N | Micro trigger | `grep -n "proportional" skills/task-workflow/SKILL.md` | no match |
| T-O | Protocol restored | `test -f skills/reference/research-protocol/SKILL.md` | missing |
| T-P | Raw Notes convention defined | `grep -n "## Raw Notes" skills/reference/research-protocol/SKILL.md` | no match |
| T-Q | Script self-test | `bash scripts/_research_append.sh --self-test` | exit ≠ 0 |
| T-R | strategy-builder §2.4 contract untouched | `grep -n "clarifying-questions" skills/strategy-builder/workflow/02-full-build-frameworks.md` still present; clarifying-questions output block names unchanged | §2.4 missing |
| T-S | Epic-brief heading parity (D9, ISM row 9) | `grep -n "### Strategy Context\|### UX Pattern Research\|### Workflow Pattern Research\|### Tech Stack Research\|### Assumptions Register" skills/epic-research/SKILL.md` (canonical set in Step 3) && same five headings present in `skills/writing-plans/workflow/02-research-intake.md` Step A.1 | either side missing |
| T-T | Phase-order assertion (ISM row 2) | `awk '/## Phase 5\.5/{f5=NR} /## Phase 8/{f8=NR} END{exit !(f5 && f8 && f5 < f8)}' skills/issue-scoping/SKILL.md` — solution-verify (5.5) precedes Finalize (8), so `### Integration Docs` is verifiable before posting | not ordered |

Unit tests: T-Q (bash self-test for `_research_append.sh` — create-on-missing, append-preserves, section dedup, idempotency).


## Verification Plan

1. **Pre-merge (both PRs):** run T-A through T-T on the merged branch state. All must pass.
2. **Post-merge (PR 1):** pick one low-risk standard issue (skills/domain, no prod code) and run `issue-scoping` through Phase 1.5 end-to-end: verify the `### Axis Research` + `### Integration Docs` blocks appear in the plan comment, the research brief is created (or appended) with `**Research:**` backfilled, and `writing-plans` Step A.2 consumes the blocks instead of starting empty. Verify a Budget-mode run takes the codebase-only shape.
3. **Post-merge (PR 1):** take one plan written under the new contract and one legacy plan (no findings-date) through `executing-plans` Step 1.5: the legacy plan must be treated as unfamiliar (fail-safe re-verify — findings-date absence triggers it directly), the new plan must be covered by `### Pattern Research`, and a legitimately-skipped zero-dep plan must NOT be re-verified (justified-skip exclusion).
4. **Post-merge (PR 1): outcome metric — "did research change the decision?" sample:** after 3–5 issues have run through the restored Phase 1.5, review a sample of scoping outputs with the evidence set = problem-diverge/converge outputs + solution-diverge alternatives + the `### Axis Research`/`### Integration Docs` blocks + the plan comment. For each finding the classifier must **cite the specific plan line** it changed or validated, then bucket: **influenced** (finding narrowed/changed a documented alternative), **validated** (finding confirmed an approach already implied — cite the diverge output that implied it), **unused** (block present but no plan line engages it), or **unmeasurable** (no citation traceable — bucket explicitly, do not force). Report the ratio on the issue; if unused+unmeasurable is high, tighten verifier dimension 5 or fire the ritualization follow-up.
5. **Post-merge (PR 2):** dispatch one epic through epic-plan substeps 4–5 to confirm the research hooks fire on demonstrated gaps and the `### Research Notes` blocks persist; one micro task with a third-party dep through task-workflow to confirm the 1–2 query trigger.
6. **Regression:** confirm `strategy-builder` §2.4 still invokes clarifying-questions with the unchanged protocol (T-R).
7. **Follow-up issues (auto-file):** (a) CI `skill-lint` fails-open bug — **already filed as #237** (skip auto-file; close #237 when CI gates on lint); (b) extend `check-pipeline-compliance.sh` with a RESEARCH EVID deterministic check on posted scoping comments (Approach C as complement — enforcement on session output, not skill prose); (c) extend `link-skills.sh`/`check-skill-links.sh` for nested `reference/*/` dirs.


## Acceptance Criteria (mapped to the issue's indicators)

- **AC-1 (indicator 1):** issue-scoping produces a persisted external-research artifact — `### Axis Research` + `### Integration Docs` blocks (v4 names) — in the plan comment and research brief, consumed by writing-plans Step A.2. No dangling references to a nonexistent phase (T-C, T-D, T-F, T-I, T-J).
- **AC-2 (indicator 2):** writing-plans' research intake runs on scoping findings (not empty); the zero-deps skip applies to Step B only, never zeroing intake for standard+ plans (T-F + Step A always-runs rule).
- **AC-3 (indicator 3):** epic-scope fires granular per-axis queries where the brief is too broad, and its Review Gate checks the `### Axis Research Notes` output for medium+ axes (T-M2, `### Axis Research Notes` in epic-scope).
- **AC-4 (indicator 4):** epic-plan has documented research hooks at Architecture + Data Model substeps (query template + persisted output + gate check), with light hooks at UX precedent and Interface contracts (T-M).
- **AC-5 (indicator 5):** task-workflow micro tier has a proportional external-research trigger (T-N).
- **AC-6 (indicator 6):** all 5 dangling-reference files resolve to the restored phase; `grep -rn "Phase 1.5a"` is empty (T-I, T-J).
- **AC-7 (indicator 7):** clarifying-questions has a pipeline caller (issue-scoping, mode=issue-pre) and its `### Deferred to Research` queue seeds Phase 1.5 Sub-step B; strategy-builder §2.4 contract unchanged (T-L, T-R).
- **AC-8 (indicator 8):** `skills/reference/research-protocol/SKILL.md` restored with the five dimensions + `## Raw Notes` convention (T-O, T-P); `_research_append.sh` created (new script, v4-adjacent — T-Q).
- **AC-9 (targets):** `check-skill-lint` passes (T-A); in-repo dangling-reference assertion passes (T-B — the replacement for `check-skill-links.sh`, which is consumer-repo-only and cannot run in agent-infra).
- **AC-10 (risk closures):** verifier 5th dimension accepts justified-skip (D2, T-K); Budget-mode shape defined and codebase-only, including the execution-intent Standard+Budget row (D3, T-M3); executing-plans staleness keyed to findings date with absent→unfamiliar fail-safe (D4, T-G); exact-match authorship boundary enforced (D5, T-E, T-H); cold-start does not disable research (D8).


## Runtime Prerequisites

- **RT1 (hard):** `AGENT_INFRA_PATH` set (per AGENTS.md) — required for `link-skills.sh`/`check-skill-links.sh` on the CONSUMER side (those scripts cannot run in agent-infra by design; they are not part of this plan's verification gates — T-B replaces them for in-repo reference checks).
- **RT2 (hard):** `gh` CLI authenticated — issue body/comment reads, `gh issue edit` for `**Research:**` backfill, `gh issue view` in skills.
- **RT3 (hard):** node ≥ 18 for `check-skill-lint.mjs`.
- **RT4 (external fetch):** eldato repo access to port the archived `research-protocol/SKILL.md` (`_archive/pi-skills/reference/research-protocol/SKILL.md`). If unreachable, reconstruct per Task 1 step 3 (documented fallback, then fresh-context review). This is the only externally-sourced asset; everything else is in-repo reconstruction.
- **RT5 (runtime):** `mcp__seo-intelligence__perplexity_research` available for the restored research surfaces (Fast/Autonomous). Budget mode is designed to run without it (codebase-only). Micro trigger needs `web_search` only.
- **RT6 (release):** `~/.pi/agent/skills` is a symlink → agent-infra/skills on this machine (verified) — new `reference/` propagates via `git pull`, nothing else needed. On real-folder machines, `pi-bootstrap/setup.sh` `cp -R` propagates nesting automatically. **Consumer repos** (`operations/skills`): `link-skills.sh`/`check-skill-links.sh` iterate top-level dirs only and skip `reference/` (pre-existing pattern — `planning/shared/` was never linked by them either); consumers get nested dirs via the same path they get `planning/shared/` today (setup.sh / sync). Extending link-skills.sh for nested reference dirs is a separate enhancement, not required for this fix.


## Rejected Alternatives

**Approach A — Faithful v4 restoration (scoping-only).** Restore Phase 1.5's axis matrix + script port + reference fixes with NO ladder (no epic-plan hooks, no micro trigger, no verifier change). Rejected: it fixes the scoping tier but leaves the confirmed problem's structural entanglements — epic-plan still makes architecture/data-model decisions from intuition (indicator 4 fails), micro stays codebase-read-only (indicator 5 fails), epic-scope never re-queries (indicator 3 fails), and without a verifier dimension the soft-prompt recurrence risk returns — the exact failure mode that caused the v5 regression. A would have been better only if the confirmed problem were scoping-tier-only; it is not.

**Approach C — Enforcement-centric (deterministic check script).** A `check-pipeline-compliance.sh --research-evidence` gate with minimal content changes. Rejected: it produces the cheapest hard guarantee (the script runs or CI fails) but *without* the capability, the gate would fail every session — driving checkbox ritualization (paste a block to pass) or mass skips, exactly the anti-pattern the research brief's external evidence warns about (Standing Questions: "you can structurally verify actions and artifacts, but not whether reasoning actually occurred"; same-author judges drift into checkbox functions). C would have been better if the problem were purely non-adherence to an existing phase; the phase itself was deleted, so there is nothing to enforce. Its deterministic-check idea is absorbed as the testing strategy (T-A…T-R), not as the mechanism.

**Within B — rejected sub-choices:**
- *Integrated substep of problem-diverge instead of a distinct phase:* rejected — a distinct phase gives clear artifact ownership and a verifier-gate point (research brief, §Recommendation Q1); integration re-blurs the framing/external distinction that #7501 already conflated.
- *Micro trigger as gate-blocking:* rejected — micro must stay cheap; warn-and-fire (1–2 queries on demonstrated gaps) preserves proportional gates.
- *Renaming the scoping blocks (e.g. `### Scoping Research`):* rejected — v4 names are live consumer contracts (executing-plans Step 1.5, writing-plans 02/03/04, proportional-gates); renaming silently breaks the dependency-detection gate.
- *epic-plan hooks on all 8 substeps:* rejected — ritualization risk; Architecture + Data Model are the mandatory decision points (issue target), UX precedent + Interface contracts are light demonstrated-gap hooks, the rest stay intuition-driven with the coherence review as backstop.
- *Research-protocol verbatim-only restore:* rejected — restore + light update (five dimensions verbatim; add `## Raw Notes` + granularity-ladder section) per the research brief's Q3 recommendation.
