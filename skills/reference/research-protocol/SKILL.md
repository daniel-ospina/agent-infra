---
disable-model-invocation: true
name: research-protocol
description: "Reference for how to conduct research. Consumed by other skills — not invoked directly. Encodes five research dimensions within a domain-aware structure (Cynefin + Double Diamond + Estuarine Mapping + Distributed Sensing), the ## Raw Notes persistence convention, and the fractal granularity ladder. Restored 2026-08-13 from the eldato archive (issue #231)."
type: reference
domain: capability
---

# Research Protocol

> **Reference skill** — consumed by other skills, NOT invoked directly.
> Skills that do research reference this via:
> `## Research Discipline: See [research-protocol](reference/research-protocol/SKILL.md)` — from a consuming skill the relative path is `../reference/research-protocol/SKILL.md`.

## Quick Reference (30-Second Scan)

1. **Detect domain** — Clear? Apply best practice, skip research. Complicated? Analyze. Complex? Probe. Chaotic? Stabilize. Unsure? Decompose.
2. **Reframe the problem** — 5 Whys. How Might We. What assumptions? Aporetic Turn if stuck.
3. **Internal → external** — Codebase/docs/git first. Then Perplexity/context7. Default to the harder path.
4. **Adversarial by default** — Every research round includes disconfirmation queries. Fresh-session review for Standard+. Ritual Dissent for Complex.
5. **Distributed sensing for Complex** — 2-3 independent perspectives before converging. Outliers are signal.
6. **Check before building** — Existing skill? Existing lib? Can something be repurposed?

## Quality Criterion: Good > Easy

**When in doubt, take the harder path.** Research mistakes cost more than research queries. Budgets are floors, not ceilings. If 3 queries might find the answer but 5 would surface edge cases → run 5. If adversarial queries feel uncomfortable → that's the signal to run them. Exception: Execution Intent compression (Fast/Budget profiles) reduces thoroughness by design.

---

## 0. The Fractal Granularity Ladder (D11)

Research is embedded at **every level × stage** of the planning pipeline, with **increasing granularity as decisions become more concrete**. Prior-phase findings are `PRIOR_RESEARCH` context — **never a substitute** for fresh targeted queries at the next level (prior summaries lose fidelity; inherited claims without revalidation are the top error source in long-horizon agent research — DRIFT/TELBench, STALE).

| Level | Stage | Fire trigger | Output | Fresh queries |
|---|---|---|---|---|
| Epic | epic-research brief | Always (existing) | 5-section brief + `## Raw Notes` | 6+ (existing) |
| Epic | epic-plan substeps (Architecture, Data Model; light hooks: UX precedent, Interface contracts) | Demonstrated gap at the decision point (novel pattern, new integration, brief too broad) | `### Architecture Research Notes` / `### Data Model Research Notes` blocks, findings-date + provenance | 1–3 per hook |
| Epic | epic-scope | Complexity axis rated medium+ AND brief too broad for boundary decisions | `### Axis Research Notes`, deduped against brief | ≤ 4 total |
| Project/Task (standard+) | issue-scoping Phase 1.5 | Activation rule (axis medium+ = necessary; low axes may fire on demonstrated gap) | `### Axis Research` + `### Integration Docs` (persisted) | 8/14 caps (post-dedup) |
| Project/Task (standard+) | writing-plans Step B | Third-party deps / novel patterns in the concrete plan | `### Pattern Research` (sole author) + `> **Findings date:**` | 3+ per bucket (existing) |
| Task (micro) | task-workflow Research | Third-party deps or novel pattern (no in-repo precedent) | Inline `> Research note:` line, findings-date + provenance | 1–2 |

**Granularity rule (P2+P3 reconciliation):** P3 governs *whether* to fire — a demonstrated gap (new third-party dep, novel pattern, medium+ axis, new detail not covered by the parent brief). P2 governs *what* to do when firing — fresh queries at that level's granularity, inherited findings as context only. Later stages may displace earlier findings as documented updates (never silent rewrites — see `## Raw Notes`).

**Authorship boundary (D5):** `### Pattern Research` is reserved **exclusively** for writing-plans Step B (consumed by executing-plans' dependency-coverage rule). Scoping emits `### Axis Research` + `### Integration Docs`. Epic-brief headings (`### UX Pattern Research`, `### Tech Stack Research`) are PRIOR_RESEARCH context and never satisfy dependency coverage.

---

## 1. The Five Dimensions

### 1.1 Best Practices & Best Approaches

Research what the best way is, not just the first way.

- **Micro tasks (Clear domain):** Internal search. 1–2 external queries if no internal answer.
- **Standard tasks (Complicated domain):** ≥3 Perplexity angles per topic (canonical, comparative, pitfalls). No hard cap.
- **Complex tasks (Complex domain):** 2–3 landscape queries to identify coherent hypotheses. Bulk of effort shifts to safe-to-fail probes, not analysis.

**Theory-First for Complex/Complicated×Complex:** Before searching "how others do X," run one query: *"What does complexity theory / cognitive science / decision theory / [relevant domain] theory say about systems like [problem type]?"* Extract enabling constraints. Use them to filter subsequent research.

### 1.2 Challenge the Definition

Is this a symptom? Is there a root cause? Is there a better framing?

**Before any solution research, complete the Discover phase:**
- 5 Whys on the stated problem
- How Might We reframing (≥2 alternative framings)
- Assumption mapping: list every assumption, tag as [validated] or [unverified]
- Reverse the problem: "What if we tried the opposite?"

**Aporetic Turn gate:** When research hits a wall ("I can't answer this with my current framing"), change the framing, not the search effort. Snowden: *"A question you can only answer if you think differently about the problem."*

**Define phase:** Synthesize into a problem statement before entering solution space. Format: "[User] trying to [job] but [barrier] which results in [negative outcome]."

### 1.3 Internal + External Sources

Look outside but anchored in us.

- **Internal first:** Codebase (grep, read), docs (00_index.md, CLAUDE.md, design docs), git history (`git log --grep`)
- **External second:** Perplexity (`perplexity_research` for multi-angle, `perplexity_search` for quick), context7 (library-specific), `web_fetch` (competitor pages)
- **Synthesis:** Combine both. "External without internal = generic advice. Internal without external = blind spots."

**Good > Easy applies here.** The harder path (more queries, adversarial angle, fresh-session review) is the default.

### 1.4 Adversarial Research

Actively seek disconfirmation, not just confirmation.

- **Adversarial query templates active by default.** Every research round includes: "why [approach] fails," "problems with [approach]," "limitations of [approach] in production."
- **Research review cycle (Standard+):** Fresh-session sub-agent reviews research for accuracy and completeness before planning.
- **Ritual Dissent (Complex):** 2+ sub-agents as "dissent groups." Each receives research findings, produces structured critique. Researcher absorbs without defending. Synthesize into revised findings.
- **Pre-mortem (Complicated domain):** "6 months later, this failed. Why?" ≥3 independent failure scenarios.
- **Task-type awareness:** Completeness tasks (requirements, scoping) get lighter adversarial. Construction tasks (architecture, implementation) get full adversarial. Per TriAdReview (arXiv 2606.15074): adversarial review improves construction +21.3% but degrades completeness -7.5%.

### 1.5 Don't Reinvent

What already exists? Tools, skills, repos, libraries, patterns.

- **Skill deduplication gate:** Before creating a new skill → (a) does an existing skill cover ≥80% of the need? (b) can an existing skill be extended? (c) is this truly recurring, procedure-heavy, and benefiting from agent judgment?
- **Component reuse:** Check `docs/teams/eldato-app-team/ux/component_catalog.md` before new UI.
- **Library check:** Stdlib > existing dependency > new dependency > custom code.
- **Exaptation probe (standard research angle):** "What existing capability could be repurposed for this need in an unexpected way?" Snowden: traits evolved for one function exapt for another under stress.
- **SaaS/tool check:** Is there an existing service that solves this?

---

## 2. Domain Detection: Before Any Research

Classify the problem by causal structure, not by task scope.

| Question | If Yes | Domain |
|---|---|---|
| "I can write down the exact steps to solve this" | Yes | **Clear** — apply best practice, skip research |
| "I know what questions to ask, just need expert answers" | Yes | **Complicated** — analyze (sense → analyze → respond) |
| "I don't know what questions to ask; multiple competing hypotheses, all coherent, all supported by evidence" | Yes | **Complex** — probe first, sense patterns (probe → sense → respond) |
| "Everything is on fire; no time to think" | Yes | **Chaotic** — act to stabilize, then reassess (act → sense → respond) |
| "I don't know which of the above applies" | Yes | **Disorder/Aporetic** — decompose, assign parts to domains, probe in parallel |

**Snowden's definition of complexity:** *"If you have multiple competing hypotheses, all supported by evidence, all coherent, and you can't resolve which is right within the time frame for decision — then it's complex."*

### Domain Detection Verification

1. State the domain with a 1-line rationale citing the classifier questions above.
2. **Standard+:** Dispatch a fresh sub-agent to challenge the classification ("Argue for a different domain with evidence.")
3. If challenger disagrees → surface both classifications to user with evidence. User decides.
4. If challenger agrees → proceed.

### Domain Reclassification Trigger

If new information mid-research reveals misclassification: restart from domain detection. Apply new domain's method from current point. Record: "⚠️ DOMAIN RECLASSIFIED: [old] → [new] because [reason]."

---

## 3. Tier-Domain Behavior Table

*Format: Domain × Task Tier. Task tier is classified per-task (not per-skill). For multi-tier skills, each task applies its own row. "Adv (completeness)" column shows FINAL values — modifier already applied. Based on TriAdReview (arXiv 2606.15074): adversarial review degrades completeness by -7.5%.*

| Domain × Tier | Queries | Probes | Verification | Adv (robustness) | Adv (completeness) |
|---|---|---|---|---|---|
| **Clear × Any** | 0 | 0 | Checklist | Skip | Skip |
| **Complicated × Micro** | 1–2 | 0 | Light analysis | Skip | Skip |
| **Complicated × Standard** | 3–5 | 0 | Expert review | Light adv queries | Skip |
| **Complicated × Complex** | 5–15 | 0 | Pre-mortem + expert | Full Devil's Advocate | Light adv queries |
| **Complex × Micro** | 1 landscape | 1 probe | Probe result check | Skip | Skip |
| **Complex × Standard** | 2–3 landscape | 2–3 parallel | Pattern sensing + Distributed Sensing | Ritual Dissent (1 cycle) | Light adv queries |
| **Complex × Complex** | 3–5 landscape | 5+ parallel | Ritual Dissent (2+) + Estuarine + Distributed Sensing | Full adversarial | Ritual Dissent (1) |
| **Chaotic × Any** | 0 | 0 | Post-action review | Skip | Skip |
| **Disorder × Any** | 1–2 landscape | Decompose→probes | Per-domain | Skip until resolved | Skip until resolved |

### Verification Definitions

| Term | Definition |
|---|---|
| **Checklist** | 2–3 item self-check: was best practice applied correctly? |
| **Light analysis** | 2-item: (1) was analysis performed? (2) are sources cited? |
| **Expert review** | Fresh-session sub-agent reviews for gaps, contradictions, unsupported claims |
| **Pre-mortem** | "6 months later, failed. Why?" ≥3 independent failure scenarios |
| **Probe result check** | Did probe produce usable signal? Document what was learned |
| **Pattern sensing** | Compare parallel probe results. What's consistent vs contradictory? |
| **Ritual Dissent** | 2+ sub-agents critique findings with structured template. Researcher listens without responding. Synthesize. |

---

## 4. The Double Diamond: Process Rhythm

All research follows this structure, regardless of domain.

### Double Diamond × Domain Mapping

| DD Phase | Clear | Complicated | Complex | Chaotic |
|---|---|---|---|---|
| **Discover (diverge)** | Identify best practice from docs | Literature review, expert interviews, multi-angle queries | Landscape queries + parallel safe-to-fail probes + **Distributed Sensing** | Stabilize first, then reassess |
| **Define (converge)** | Confirm best practice matches context | Expert review synthesis, identify best approach | Probe pattern sensing — what emerges? | Move to another domain |
| **Develop (diverge)** | Apply best practice as specified | Design alternatives, compare trade-offs | Run experiments, amplify/dampen | Act decisively, open options |
| **Deliver (converge)** | Verify correct (checklist) | Implement, verify with tests | Amplify successes, formalize practice | Stabilize, document, move domain |

**Iteration is expected:** You will learn about the problem by working on the solution. Cycle back to Diamond 1 when solution exploration reveals new problem insights.

---

## 5. Estuarine Mapping (Complex Domain)

For Complex-domain problems in the Discover phase, replace root cause analysis with Estuarine Mapping. Snowden: *"A complexity alternative to root cause analysis."*

1. **Identify actants:** Map constraints (contain/connect) and constructors (produce replicable outcomes). Six types: rigid, elastic, tethers, permeable, phase shift, dark constraints.
2. **Plot on Energy×Time grid:** Vertical = energy cost of change. Horizontal = physical time to change.
3. **Draw Counterfactual Line:** Everything top-right is realistically unchangeable. Monitor this boundary.
4. **Draw Vulnerability Line:** Everything bottom-left changes quickly. High-impact items → urgent containment.
5. **Design experiments in middle zone:** Safe-to-fail probes targeting what you CAN change.
6. **Establish monitors:** Track when items cross boundaries — signals to reassess.

---

## 6. Distributed Sensing (Complex Domain)

Snowden's core insight: *"We don't see things we don't expect to see."* A single researcher has systematic blind spots. Multiple independent perspectives are the fix.

For Complex × Standard+ tasks:

1. **Dispatch 2–3 independent research sub-agents** to assess the same problem from different lenses (user-centric, systems-centric, outlier-seeking).
2. **Each researches independently** — no cross-talk. Each produces its own findings.
3. **Map agreements and disagreements.** Where all agree → high-confidence. Where they diverge → that's where the interesting information lives.
4. **Treat outliers as signal.** The agent that sees something the others don't is not wrong — it has a perspective the others lack.
5. **Synthesize across perspectives.** Capture dominant views, minority views, and explicitly flagged outlier observations.

**Relationship to Ritual Dissent:** Distributed sensing = sensemaking (Discover phase). Ritual Dissent = adversarial review (Define/Develop phase). Distributed sensing first.

---

## 7. Disorder Decomposition

When the domain is Disorder (can't classify):

1. **Surface ambiguity:** "Cannot classify. May involve [domains with rationale]."
2. **Decompose** into ≥2 independently classifiable sub-problems.
3. **Classify each sub-problem** to a domain.
4. **Apply per-domain method** in parallel where possible.
5. **Synthesize** composite understanding.
6. **Fallback:** If decomposition fails after 2 attempts → default to Complex (2–3 landscape + probes), flag "⚠️ DOMAIN UNRESOLVED."

---

## 8. Integration Modes

How the protocol interacts with existing skill methodologies:

| Mode | When to Use | Skills |
|---|---|---|
| **Protocol governs** | No existing methodology, or ad-hoc | research, brainstorming, codebase-audit, find-bugs, systematic-debugging, writing-plans |
| **Protocol wraps** | Partial methodology lives inside protocol phases | issue-scoping, epic-planning |
| **Protocol sits beside** | Mature methodology — protocol enhances without replacing | content-research, strategy-builder, content-fact-checker-* |

### Integration Tiers for Consumers

| Tier | Scope | Who |
|---|---|---|
| **Tier 3 (full)** | Entire protocol + self-audit | research, brainstorming, epic-planning, strategy-builder |
| **Tier 2 (significant)** | Dimensions 1–4, skip distributed sensing + Estuarine | issue-scoping, codebase-audit, writing-plans, content-research, content-fact-checker-* |
| **Tier 1 (light)** | Single-line Quick Reference reference | systematic-debugging, find-bugs |

---

## 9. Execution Intent Compression

| Profile | Effect | Rounding |
|---|---|---|
| **None (default)** | Autonomous — full protocol, no human gates | N/A |
| **Fast** | Query budget −50%. Skip Ritual Dissent + Distributed Sensing. Checklist verification only. | Ceil: 1–2→1, 2–3→2, 3–5→3. Min 1 if domain requires external. |
| **Autonomous** | Full protocol, no human gates | N/A |
| **Budget** | External queries → 0 where internal substitutes. Complex: min 1–2 landscape, note unknowns as assumptions. | Per above |

> **Pipeline Budget shapes (from #231):** `EXECUTION_INTENT=Budget` at the epic tier defers to the epic brief (codebase + brief only, zero external queries). Standard + Budget: issue-scoping Phase 1.5 ≤ 2 queries, codebase-first (with the writing-plans gate as the total session budget). Micro + Budget: codebase-read only. Budget never double-charges against an already-skipped perplexity gate.

---

## 10. Sub-Agent Protocol Access

Consuming skills MUST include in sub-agent dispatch prompts:

```
Before executing, read the research-protocol reference skill
(reference/research-protocol/SKILL.md — canonical in agent-infra; consumers:
.agents/skills/reference/research-protocol/SKILL.md).
Apply the protocol's domain detection, query budget, and verification strategy
for your assigned task.
```

---

## 11. Ritual Dissent (Agent-Native)

For Complex-domain adversarial review:

1. **Dispatch 2+ sub-agents as "dissent groups."** Each receives the research findings + the instruction: "Your job is to find what's wrong, missing, or unsupported in these findings. Be thorough and specific."
2. **Structured critique template:** (a) What claims are unsupported by evidence? (b) What evidence is missing? (c) What alternative interpretations exist? (d) What assumptions are unstated?
3. **Researcher agent receives all critiques without responding.** Forced listening — absorbs without defending.
4. **Synthesize revised findings** incorporating validated critiques.

---

## 12. Enforcement Self-Audit (Tier 3 Consumers)

```
Protocol compliance self-audit:
☐ Domain classified before research (with rationale)
☐ Domain classification challenged (Standard+)
☐ Query budget respected per Tier-Domain table
☐ Adversarial queries included (per task-type modifier)
☐ Theory-first query run (Complex / Complicated×Complex)
☐ Distributed sensing run (Complex × Standard+)
☐ Exaptation probe considered (all tiers)
☐ Research review or Ritual Dissent completed
☐ Verification strategy applied per domain
```

---

## 13. `## Raw Notes` Persistence Convention (D10)

Every research brief (epic sibling `research-brief.md`, `docs/research/<slug>.md`, or `docs/plans/<slug>-research.md`) carries a `## Raw Notes` section. This is the **append-only evidence ledger** behind all synthesized blocks (`### Axis Research`, `### Pattern Research`, brief sections).

**Shape:**
- Entries are **append-only, reverse-chronological** (newest last or first consistently within a brief — pick one per brief and keep it).
- Each entry: timestamp, framing label (canonical / competitor / precedent / pitfalls / adversarial / question), query or question reference, findings, source tag.
- Synthesized sections may be **updated per level** — updates are documented, never silent rewrites: `[updated YYYY-MM-DD — <what changed>]`.
- Later-stage findings may displace earlier ones — the displacement is recorded in Raw Notes with provenance (MisKnow-Agent/DRIFT compliance: later stages can challenge earlier evidence).

**Mechanical enforcement:** `scripts/_research_append.sh` appends timestamped entries and **creates `## Raw Notes` if absent** (same create-if-missing semantics as brief creation). Raw Notes is the source of truth; synthesized blocks are derived views.

---

## Anti-Patterns

| Anti-Pattern | Why It Matters |
|---|---|
| Applying analysis to Complex problems | Cannot analyze your way to certainty in complexity. Probe instead. |
| Applying probes to Clear problems | Wasteful. Apply best practice and move on. |
| Skipping domain detection | Wrong method for causal structure guarantees failure. |
| Using Cynefin as a static label | Cynefin is about movement between domains. |
| Treating research as linear | Solution exploration reveals new problem insights. Cycle back. |
| "It's complex, so we can't estimate" | Complexity is not an excuse. Cap time/budget at probe level. |
| Using "be critical" instead of explicit roles | Only explicit adversarial assignment works (OpenReview, 480 experiments). |
| Skipping the Aporetic Turn | When stuck, change the framing, not the search effort. |
| Single-analyst blind spots on Complex problems | "We don't see things we don't expect to see." Use distributed sensing. |
| Skipping theory-first for Complex problems | Case studies tell you what worked once. Theory tells you what CAN work. |
| Creating skills without dedup check | Skill sprawl is the dominant failure mode (callsphere.ai). |
| Treating inherited research as a substitute for fresh queries | Prior summaries lose fidelity; inherited claims without revalidation are the top error source (DRIFT/TELBench). Each level re-researches at its granularity. |
| Letting a justified-skip become the universal path | The escape hatch is for demonstrated no-gap; a brief-section citation must cover the ACTUAL question at sufficient granularity, not any adjacent section. |

---

## Scientific Foundations

- **Cynefin Framework** (Snowden, 1999–present): Domain detection and decision support for different causal structures.
- **Estuarine Mapping** (Snowden, 2022–present): Constraint-and-constructor mapping for complex systems.
- **Double Diamond** (British Design Council, 2005): Divergent/convergent thinking structure. Academically validated in requirements engineering (ACM SAC 2021, SBES 2025, arXiv 2112.05549).
- **Premortem Technique** (Klein, 2007; Oxford/Michigan Tech validated): Prospective hindsight for failure mode discovery. Army field-tested.
- **Structured Adversarial Synthesis** (FinNLP 2025): Five-act adversarial debate protocol.
- **TriAdReview** (arXiv 2606.15074): Task-type boundaries for adversarial review — +21.3% construction, −7.5% completeness.
- **Devil's Advocate Disagreement Research** (OpenReview, 480 experiments): Only explicit role assignment creates genuine disagreement.
- **Research-Plan-Implement Pattern** (agentpatterns.ai, Tyler Burleigh): Phase separation with fresh-context review cycles.
- **CRISPY Framework** (HumanLayer): Evolved RPI with design discussion and structure phases.
- **Karpathy's 4 Principles:** Think Before Coding, Simplicity First, Surgical Changes, Goal-Driven Execution.
- **DRIFT/TELBench** (arXiv 2606.02060): Inherited claims without revalidation are the top error source in long-horizon research.
- **STALE** (arXiv 2605.06527): Recognition of updated evidence does not imply application — re-derive at the point of use.
- **MisKnow-Agent** (arXiv 2607.20891): Later-stage research that can challenge earlier evidence reduces false-conclusion adoption.
