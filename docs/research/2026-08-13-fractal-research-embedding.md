---
title: "Research Brief: Fractal External Research in the Planning Pipeline"
type: engineering
domain: capability
doc_status: draft
subjects.team: organisation-design-team
created: 2026-08-13
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-231, fractal-research-ladder
---


# Research Brief: Fractal External Research in the Planning Pipeline

**Date:** 2026-08-13
**Issue:** agent-infra #231
**Domain:** capability (org-infra)
**Depth:** Medium (project)


## Reframed Problem Statement

Agents in the planning pipeline are "trying to make good implementation decisions but the pipeline no longer requires or persists external research, which results in decisions made from model intuition alone — no best-practice import, no known-pitfall avoidance, at every level from epic to micro."

Reframing (per research protocol §1.2): the problem is **not** "agents forgot to research" (awareness) — it is **structural**: (a) the research phase + output artifact were deleted in a restructure, (b) downstream consumers still reference the deleted artifact, (c) the remaining "use the research skill" instruction is prose inside sub-agent prompts with no verifier check, (d) epic-plan never had research hooks at all.


## Internal Findings (verified)

1. **The regression:** issue-scoping v4 had `Phase 1.5 — External Research (Standard+Complex only)`: axis-driven research matrix (UX/Ontology/Architecture/Library), multi-angle queries (canonical+adversarial+precedent), codebase-first hybrid, uncertainty×impact question filtering, `### Axis Research` output block, findings appended to research brief via `scripts/_research_append.sh`. The v5.0.0 double-diamond restructure (#7501, closes #7498) **removed the phase**; v5.1.0 kept only soft prompt text: *"All agents MUST invoke the `research` skill internally"* (`issue-scoping/SKILL.md:459`).
2. **#7501 intent (via parent issue #7498):** the restructure explicitly said "Problem phases use research skill" — intent was to move framing/adversarial research into the diamond phases. It did **not** deliberately decide to drop external best-practice research; the two functions were conflated:
   - *Framing research* (adversarial, challenge the definition) — retained in diamond phases
   - *External best-practice research* (import how others solve it + pitfalls) — **dropped** with Phase 1.5
3. **Dangling references** to the removed Phase 1.5 (9 reference lines across 5 files): `writing-plans/workflow/02-research-intake.md` (Step A.2 expects `### Pattern Research`/`### Integration Docs` blocks), `clarifying-questions` (Pass B seeds "Phase 1.5 Sub-step B" — **zero callers in the planning pipeline**; sole caller is strategy-builder §2.4, GTM domain), `issue-creation` (§Research), `ux-design-review` (Phase 1.5a), `writing-plans/workflow/01.5-ux-design-gate.md` (line 27, "Phase 1.5a"). Plus missing infra: `scripts/_research_append.sh` never ported; `skills/reference/research-protocol/SKILL.md` missing (archived in eldato `_archive/`), referenced by 8+ skills.
4. **`### Pattern Research` is a live consumer contract, not a free name:** `skills/executing-plans/SKILL.md` Step 1.5 defines an "unfamiliar dependency" as one NOT covered by the plan's `### Pattern Research` section (explicit skip path keyed to that name); `writing-plans/workflow/03-integration-surface.md`, `04-draft-plan.md`, and `proportional-gates/SKILL.md` also reference it. Restoring the scoping artifact MUST use the exact existing names — a rename silently breaks executing-plans' dependency-detection gate.

   > **[updated 2026-08-14 — D5 contract redefinition (verified against the v4 eldato archive):]** v4 scoping actually emitted `### Axis Research` **and** `### Pattern Research`; `### Integration Docs` has no v4 provenance (consumer-side expectation from writing-plans Step A.2). The implemented contract (issue #231, PR #241): **scoping emits `### Axis Research` + `### Integration Docs`; `### Pattern Research` is writing-plans Step B's exclusive plan-doc output** (executing-plans always read the plan-doc block). "Exact existing names" above refers to the scoping blocks `### Axis Research` + `### Integration Docs` — the plan-doc `### Pattern Research` is Step B's, not scoping's. Consumers were re-pointed accordingly (writing-plans Step A.2 intake; executing-plans Step 1.5 anchored parse).
5. **Tier gaps:** micro (task-workflow) research = "read affected files" only; shared-research = minimal routing stub (append-to-brief vs run-research at depth — substantive routing, but no granularity ladder); epic-plan's 8 substeps have zero research hooks (architecture/data-model decisions made from intuition); epic-scope consumes the brief but fires no granular queries; **epic-research's brief-production contract is unassessed** (the ladder's root node — its sections feed writing-plans Step A.1).


## External Findings (Perplexity/sonar + Exa, 4 queries across 2 independent categories)

### A. The canonical pattern is Research→Plan→Implement with durable artifacts (multiple sources)

- RPI is the industry-standard lifecycle (Microsoft HVE `hve-core` RPI, infobip agentic-workflow, Claude Code RPI guides, AgentPatterns.ai). Core rules: **each phase produces a durable artifact** (`RESEARCH.md` → `PLAN.md` → `TASKS.md`), each gate requires an explicit GO before the next phase, research is read-only, and **research activates only on a demonstrated gap** — "reuse supplied or completed evidence when it is adequate" (Microsoft). AgentPatterns: "The research phase prevents the most expensive failure mode: implementing against wrong assumptions"; Addy Osmani: successful agent users spend ~70% on problem definition + verification.
- **Our pipeline already implements most of RPI.** What's missing is the artifact contract + enforcement at the scoping/planning research points.

### B. The originator of RPI reversed it to QRSPI — research summaries lose fidelity (validates the granularity thesis)

- Dexter Horthy (RPI originator) publicly reversed RPI in early 2026 → QRSPI (Questioning, Research, Structure, Plan, Implement), citing at scale: (1) broad research skipped the "alignment moments" where design decisions should surface as explicit options; (2) **the Structure phase between Plan and Implement was the most-skipped step in practice**; (3) **plans drifted silently once research summaries lost fidelity** ([talk: "Everything We Got Wrong About Research-Plan-Implement"]).
- AgentPatterns: "stale or wrong research summaries — a condensed summary the implementer cannot audit cheaply can confidently omit a relevant constraint, seeding the plan with a silent false assumption." **Direct validation: inherited research cannot replace fresh targeted queries at the next level.**

### C. Inherited claims without revalidation are the top error source in long-horizon agent research (academic)

- **DRIFT/TELBench (arXiv 2606.02060):** "the harmful step is often... an earlier commitment that later spans inherit without revalidation." Decision-making and finalization stages have the highest normalized error rates (60.5% / 51.8%), not retrieval. **Fix: revalidate claims at each decision point** — exactly the "fresh targeted queries as things become concrete" property.
- **STALE benchmark (arXiv 2605.06527):** "recognition does not imply application" — updated evidence can be stored and retrieved but does not reliably govern downstream behavior (best model 55.2%; most memory frameworks <10%). **Fix: queries at the point of use, not inherited summaries.**
- **MisKnow-Agent (arXiv 2607.20891):** misleading knowledge adoption is lowest when *subsequent research stages can challenge earlier evidence* (WebThinker's early-stage robustness = opportunities to challenge/displace later). **Fix: later stages must have research capacity to displace earlier conclusions.**

### D. Enforcement mechanisms that actually work (anti-ritualization)

- **juanchi.dev (pre-code research artifact experiment):** "Asking nicely in the prompt isn't enough" — enforcement requires (1) phase-gated tools (write disabled during research), (2) **fixed-structure artifacts with named sections** ("the artifact can turn into filler if the prompt isn't specific enough"), (3) real checkpoints (`waitForApproval()`), (4) **scoped research** — "not 'research the project', but 'research the authentication module and its direct dependencies'." "If it asks no questions, something is wrong."
- **Standing Questions ("Answers rot. Store questions instead."):** answers are point-in-time materialized views; staleness = refresh lag; re-derive at decision points. Critical caveat: **"you can structurally verify actions and artifacts, but not whether reasoning actually occurred"** — verifier gates check artifacts; and a same-author judge "drifts into a checkbox function" (ritualization) — hence fresh-context reviewers (which our pipeline already has).
- **ZenML/CRISPY + LinkedIn practitioner consensus:** agents skip research under instruction overload; the fix is simplification + enforcement + feedback loops, not more prose.


## Design Principles → Fix Requirements

| # | Principle (evidence) | Fix requirement |
|---|---|---|
| P1 | Artifacts over prompts — "asking nicely isn't enough" (juanchi.dev; Standing Questions; RPI) | Every research point emits a **fixed-structure persisted artifact** consumable by the next stage and checkable by existing verifier gates — scoping emits `### Axis Research` / `### Integration Docs`; the plan's `### Pattern Research` is writing-plans Step B's exclusive output (D5 redefinition, see Finding 4 update) |
| P2 | Re-derivation beats inheritance — inherited claims without revalidation are the top error source (DRIFT; STALE; QRSPI; AgentPatterns) | Each level fires **fresh targeted queries** with finer granularity; prior findings are `PRIOR_RESEARCH` context, never a substitute |
| P3 | Proportional triggers — research only on demonstrated gaps (Microsoft RPI; AgentPatterns "skip phases deliberately") | Axis-driven triggers (complexity ≥ medium per axis; third-party deps; novel patterns); micro gets a cheap proportional trigger, not a heavy gate |
| **P2+P3 reconciliation** | QRSPI warns mandatory research phases backfire at scale; STALE/MisKnow-Agent warn inherited evidence governs nothing | **P3 governs *whether* to fire** — a demonstrated gap: new third-party dep, novel pattern, medium+ axis, or new detail not covered by the parent brief. **P2 governs *what* to do when firing** — fresh queries at that level's granularity with inherited findings as context only. This is the scoping-stage decision rule. |
| P4 | Verifier-checkable output — structural verification of artifacts (Standing Questions; juanchi.dev fixed structure) | The existing problem-verify/solution-verify gates gain a check: research artifact present with required sections + per-framing citations |
| P5 | Scoped research questions — "research the authentication module, not the project" (juanchi.dev; v4 axis matrix) | Restore the axis-driven research matrix (UX/Ontology/Architecture/Library) with concrete named targets from the issue |
| P6 | Anti-ritualization — same-author judges drift to checkbox functions (Standing Questions) | Research output must be *updated with new findings per level*, reviewed by fresh-context reviewers (already the pipeline norm); presence-of-section ≠ content |
| P7 | Later stages can challenge earlier evidence (MisKnow-Agent; DRIFT) | The granularity ladder explicitly allows displacing prior findings (documented as updates, not rewrites — traceability) |


## Recommendation

Restore the fractal research ladder across the pipeline, artifact-first and verifier-enforced:

1. **issue-scoping:** re-add a dedicated external-research stage (Phase 1.5) for Standard+Complex — axis-driven matrix, fixed output contract (`### Axis Research` + `### Integration Docs` — the scoping blocks; `### Pattern Research` is writing-plans Step B's exclusive plan-doc output per the D5 redefinition in Finding 4), findings persisted to the issue comment + research brief; problem-verify gate checks artifact presence/structure.
2. **epic-plan:** add targeted research hooks at the Architecture and Data Model substeps (query template + persisted output block); epic-scope fires granular per-axis queries where the brief is too broad.
3. **writing-plans:** fix Step A.2 to consume the restored scoping artifact (contract names stay unchanged); keep the multi-call Perplexity gate as the *planning-phase* re-derivation (fresh, concrete, versioned queries) — explicitly framed as re-derivation, not repeat. Fix the 5th dangling reference in `workflow/01.5-ux-design-gate.md` (Phase 1.5a).
4. **task-workflow (micro):** proportional trigger — external research when third-party deps or novel patterns are involved (1-2 queries), codebase-read otherwise.
5. **clarifying-questions:** wire into issue-scoping (its "Deferred to Research" Pass B queue seeds the research stage); fix its Phase 1.5 reference; **verify the rewiring against strategy-builder §2.4** (its sole existing caller — consumption contract must not break); correct its stale frontmatter description (claims epic-workflow/issue-scoping insertion points that don't exist).
6. **Infra:** port `scripts/_research_append.sh`; restore `skills/reference/research-protocol/SKILL.md` from the eldato archive; fix all dangling references (issue-creation, ux-design-review, shared-research stub expansion).

**Open questions for scope:**
- Should Phase 1.5 be a distinct phase (v4 shape) or an integrated substep of problem-diverge? (Distinct phase = clearer artifact ownership + gate point; integrated = fewer pipeline steps.) — Recommend **distinct phase**, matching the verifier-gate architecture.
- How hard should the micro trigger be? (Recommend: warn-and-fire, not gate-blocking — micro must stay cheap.)
- research-protocol: restore verbatim vs. update? (Recommend restore + light update to reference the granularity ladder.)
- Assess epic-research's brief-production contract against writing-plans Step A.1 consumption (Strategy/Tech Stack/UX Patterns/Assumptions Register) — confirm section parity or list deltas.


## Source Confidence Summary

| Claim | Tier | Sources |
|---|---|---|
| RPI is canonical with durable artifacts + GO gates | High | Microsoft hve-core, infobip, AgentPatterns, Claude Code guides (4+ independent) |
| Research summaries lose fidelity → fresh queries needed (granularity) | High | QRSPI talk/blog, AgentPatterns, DRIFT/TELBench, STALE, MisKnow-Agent (5 independent) |
| Prose-only research instructions fail; enforcement via artifacts + gates works | High | juanchi.dev experiment, Standing Questions, ZenML/CRISPY, practitioner posts |
| Inherited claims without revalidation are top trajectory error source | Medium-High | DRIFT/TELBench (arXiv), STALE (arXiv) |
| Misleading evidence adoption drops when later stages can challenge | Medium | MisKnow-Agent (arXiv) |
| #7501 removed Phase 1.5 without deliberate external-research decision | High | eldato #7498/#7501 issue+PR text (verified internal) |
| `### Pattern Research` is a live consumer contract (executing-plans Step 1.5, writing-plans 03/04, proportional-gates) | High | agent-infra source (verified internal) |

> **Query-to-category note:** external findings span 4 queries across 2 independent source categories (Perplexity/sonar via web_search; Exa semantic search). The academic cluster (DRIFT/TELBench, STALE, MisKnow-Agent) surfaced via Exa; the practitioner cluster (RPI/QRSPI, juanchi.dev, Standing Questions, ZenML/CRISPY) surfaced via both.
