---
name: clarifying-questions
description: "Scores and surfaces clarifying questions before planning proceeds. Invoked by epic-workflow and issue-scoping at defined insertion points. Not invoked directly by users."
domain: capability
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

<!-- pi-adapted from operations/skills/clarifying-questions/SKILL.md -->
# Clarifying Questions

> **Ontology:** `docs/teams/organisation-design-team/data/ONTOLOGY.md` — canonical entity classes, work vocabulary, domain taxonomy.

## Purpose

Run a scored question round to surface assumptions before planning proceeds. Called by parent skills at defined insertion points — not invoked directly by users.

**Research-first default:** All `human-required` questions are researched autonomously BEFORE asking the human. Only escalate what research cannot resolve. A question that was answered by research is recorded with `How = resolved by research` and never reaches the human.

## Caller Protocol

The calling skill must provide:
1. **mode** — one of: `epic-pre`, `epic-post`, `epic-ux`, `issue-pre`, `issue-post`
2. **tier** — the complexity tier (`micro`, `standard`, `complex`)
3. **context** — the issue body, epic brief, or research summary available at the call point

## Skip Conditions

- Tier is `micro` → skip entirely, output nothing, return immediately

## Process

### Step 1 — Generate 20 questions

Generate exactly 20 questions appropriate to the mode. Use the fixed categories below but phrase each question dynamically based on the context provided. Roughly half should check fundamentals ("is this assumption correct?"), half should expand thinking ("have you considered X?").

**Categories by mode:**

#### `issue-pre` — strategic, before reading the codebase

| Category | Focus |
|---|---|
| Scope | What is explicitly in scope vs out? What is the minimum viable version? |
| Success | How do we know this issue is done? What does passing look like? |
| User impact | Who is affected? What changes for them? |
| Priority | Why now? What breaks if this ships late? |
| Constraints | Known technical or product constraints that shape the solution? |
| Alternatives | Why this approach? What was considered and rejected? |
| Edge cases | What happens at the boundaries — empty state, max load, partial failure? |
| Integration | What other features or systems does this touch? |
| Rollback | If this needs to be reverted after shipping, how? |
| Stakeholder | Is there a design spec, a product decision, or a business rule driving this? |

#### `issue-post` — technical, after reading the codebase

| Category | Focus |
|---|---|
| Approach | Which implementation pattern should this follow (given what exists)? |
| Testing | What test cases are required? What is already covered? |
| Schema | Does this need a migration? What are the rollback implications? |
| Errors | How should failures surface to the user vs be silenced vs be logged? |
| Performance | Are there query or render performance concerns at scale? |
| Rollout | Feature flag? Gradual rollout? Or ship all at once? |
| Tech debt | Does this approach add debt? Is there a cleaner path? |
| Observability | What logging, metrics, or alerts does this need? |
| Docs | Which docs need updating as part of this change? |
| Dependencies | Does anything else need to ship before or alongside this? |

#### `epic-pre` — strategic, before research

| Category | Focus |
|---|---|
| Problem | Is the problem statement correct? What evidence confirms this is the right problem? |
| Scope | What is explicitly out of scope for this epic? |
| Metrics | How is success measured — concretely, not just "users can do X"? |
| Roles | Which user roles are affected and how? |
| Constraints | What technical or product constraints bound the solution space? |
| Phasing | Are there expected phases or must this ship as a unit? |
| Business Hypothesis | What is the business hypothesis? What evidence supports it? What would disprove it? |
| Validation Approach | How will this feature's hypothesis be validated? What's the minimum experiment? |
| Competitive Position | How do competitors handle this? What's our differentiation angle? |
| Company OKR Alignment | Which company OKR does this serve? How does it move the metric? |
| Dependencies | What must be true before this epic can start? |
| Stakeholders | Who needs to approve architecture decisions? Who is the product owner? |

#### `epic-post` — architectural, after research

| Category | Focus |
|---|---|
| Data model | Which entities are new vs extended? What are the key schema trade-offs? |
| Migration | How does data get from the current state to the target state safely? |
| Integration | Which existing systems need the most significant changes? |
| Phasing | How should delivery phases be cut to remain independently deployable? |
| Ontology | Does this introduce new semantic vocabulary (new status values, categories, entity types)? |
| Feature flags | Should any part be behind a flag for gradual rollout? |
| External APIs | Which external services are introduced or modified? |
| Rollback | What is the rollback plan for each migration phase? |
| Monitoring | What metrics/alerts confirm the epic shipped correctly? |
| Performance | What are the performance targets and how are they verified? |

#### `epic-ux` — UX/workflow alignment, after research

| Category | Focus |
|---|---|
| Operational rhythm | How often and when does the operator interact with this? Daily? Weekly? Event-driven? |
| Friction tolerance | Where is friction acceptable (safety, quality) vs where must it be frictionless? |
| Mental model | How does the user think about this — what's their vocabulary, their groupings? |
| Monitoring style | Proactive (dashboard checks) vs reactive (alerts only) vs hybrid? |
| Automation boundary | What should be fully automated vs semi-automated vs manual? |
| Multi-role handoffs | Where does one role's action create work for another? Is that intentional? |
| Error recovery | When something fails, who fixes it and how? Self-service vs escalation? |
| Edge case priority | Which edge cases matter enough to design for vs handle with a generic fallback? |
| Existing habits | What current workflows/tools does this replace or augment? |
| Progressive disclosure | What's visible by default vs hidden behind clicks/menus/settings? |

---

### Step 2 — Score each question

For each question, assign two scores (1–10) **and** a researchability classification:

**Impact** — how much will the answer shape what we build?

| Score | Meaning |
|---|---|
| 8–10 | One-way decision (hard to reverse), OR ontology change (new entity/status/category), OR significant UX flow change |
| 5–7 | Moderately shapes the approach — different answer = different implementation |
| 1–4 | Nice to know but answer does not change what ships |

**Uncertainty** — how unknown is the answer, given only the context provided?

| Score | Meaning |
|---|---|
| 8–10 | Completely unspecified in the prompt or brief |
| 5–7 | Implied or inferable but not explicitly stated — could be wrong |
| 1–4 | Clearly stated, or safely inferable from the prompt |

**Researchability** — can Claude answer this autonomously through codebase reading, documentation lookup, or pattern research?

| Value | Meaning |
|---|---|
| `human-required` | Requires human judgment because it touches: (1) ontology — new tables/columns/relationships/semantic meaning, (2) UX — visible behavior/layout/flow changes, (3) one-way doors — destructive ops, migrations, schema drops, (4) third-party dependencies — new API integrations or service subscriptions, (5) cost impact — increases recurring costs, (6) scope expansion — goes beyond what was requested |
| `researchable` | Answer is discoverable by Claude through codebase reading, docs lookup, or Phase 1.5 pattern research — Claude decides autonomously. Applies to: implementation approach/pattern selection, testing strategy, error handling style, observability/logging choices, performance trade-offs, tech debt assessment, docs updates needed, internal dependency ordering |

> **Researchability tie-breaker:** When uncertain, ask yourself: "Could Claude make a reasonable autonomous decision here with 30 minutes of research?" If yes → `researchable`. The cost of a wrong autonomous technical choice is recoverable; the cost of asking about 10 technical questions the user cannot answer is a broken workflow.

---

### Step 2.5 — Pre-filter Research Pass

Before filtering, resolve uncertainty on high-impact questions through research. This prevents the workflow from stopping for questions that research can answer — including ones classified `human-required`.

**Collect candidates:** All questions where **impact ≥ 6 AND (uncertainty ≥ 5 OR researchability = `human-required`)**, regardless of researchability classification. This is the research-first default — human-required questions are researched autonomously before escalation.

If no candidates: skip this step entirely and proceed to Step 3.

**Group and fire research:**
- Codebase/schema questions → read relevant source files, check existing tables/types/functions
- Technical pattern questions → Perplexity (`best practice for X in Y` / `common gotchas with Z`)
- External service questions → context7 first, fall back to Perplexity
- Batch similar questions into a single query where possible; cap at 5 total queries

**Update uncertainty scores** based on findings:
- Research fully resolves the question (clear answer exists in codebase or docs) → set uncertainty to 2–3
- Research provides strong context but human judgment still needed → reduce uncertainty by 2–3 points
- Research provides no useful signal → keep original score

**Produce an internal `### Research Findings` block** (not surfaced to user yet):
For each researched question, note: question #, what was found, new uncertainty score, whether the answer is now determined.

Continue to Step 3 using the **updated uncertainty scores**. Questions whose uncertainty dropped below 5 no longer qualify for Pass A — the workflow will not stop for them. If a `human-required` question was fully resolved by research, record its answer in the Step 6a Clarifications block with `How = resolved by research`.

---

### Step 3 — Filter

Two separate filter passes:

**Pass A — Ask the user:** questions where **impact ≥ 6 AND uncertainty ≥ 5 AND researchability = `human-required`** → present to user in Step 4.

**Pass B — Defer to research:** questions where **impact ≥ 6 AND uncertainty ≥ 5 AND researchability = `researchable`** → collected into the "Deferred to Research" block output in Step 6b. These are answered autonomously via Phase 1.5 research (Perplexity, codebase reading, context7).

Questions with impact < 6 are silently dropped regardless of researchability — not worth asking or researching.

If 0 questions qualify for Pass A: output this and proceed to check Pass B:

```
No clarifying questions needed for this round — all human-judgment decisions are already specified. Proceeding.
```

If Pass A questions exist: first show the full scored table (all 20, see format below), then ask qualifying questions one by one.

**Scored table format:**

| # | Question | Impact | Uncertainty | Researchability | Disposition |
|---|---|:---:|:---:|:---:|:---:|
| 1 | [question] | 9 | 8 | human-required | ask user |
| 2 | [question] | 8 | 7 | researchable | defer→research |
| 3 | [question] | 4 | 7 | human-required | dropped |
| 4 | [question] | 3 | 9 | researchable | dropped |

---

### Step 4 — Present qualifying questions

**All questions MUST follow the `question-format` protocol.** This ensures consistent, structured presentation with context, impact, options with trade-off analysis, and recommendations.

**For questions with discrete options (A/B/C/D):** use the asking the user directly tool per the `question-format` protocol — do **not** output markdown for these.

- You may batch qualifying questions (up to 4 per asking the user directly call).
- `header` field: short question title, max 12 chars (e.g. "Auth method", "Data store").
- **`question` field — MUST contain all three parts, not just the question:**
  1. **Context** (1-2 sentences): what research finding, design tension, or gap prompted this question
  2. **Impact** (1 sentence): what concretely changes depending on the answer — not abstract ("this is important") but specific ("this determines whether non-subscribers see an empty form or a pre-filled one")
  3. **The question itself** + `Impact: [X]/10 | Uncertainty: [Y]/10`
- Options: per `question-format` protocol — recommended first with `" (Recommended)"` label and `Recommended because:` in description. Each option must include what-you-gain and what-you-lose, not just a description.
- Add a `"Skip — apply recommendation"` option: `"Auto-applies the recommended option; recorded as skipped→recommendation."`
- **For epic modes only** (`epic-pre`, `epic-post`, `epic-ux`): add a `"Research this first"` option: `"Launch background research on this question before answering. A subagent will research the topic and you'll be re-asked with findings. Pick this when you want data before deciding."`
- When the user selects "Skip — apply recommendation", treat it identically to a typed **skip** (auto-apply recommendation, note as `skipped→recommendation`).

**Inline example — good `question` field:**

```
"question": "The journey assumes both toggles default to OFF for non-subscribers, but since QR is locked for them, 'Instrucciones personalizadas' is their only redemption method. If it also defaults to OFF, non-subscribers may save deals with zero redemption info — creating a dead-end user experience. This determines the onboarding friction for non-subscriber deal creation and whether we need a validation fallback. What should the default toggle state for 'Instrucciones personalizadas' be for non-subscribers? Impact: 8/10 | Uncertainty: 7/10"
```

**Bad `question` field (DO NOT do this):**

```
"question": "For non-subscribers creating a deal, what should the default toggle state for 'Instrucciones personalizadas' be?"
```

The bad version lacks context (why does this matter?) and impact (what breaks if we get it wrong?). The user can't make an informed decision from a bare question.

**For questions with no discrete options (free-form):** fall back to text output per the `question-format` protocol's free-form format:

```
Q[N] — [short question title]

[Context line: 1-2 sentences on why this question came up]

[Full question text]

[Impact explanation: what concretely changes depending on the answer]

Impact: [X]/10 | Uncertainty: [Y]/10

> Write your answer, type **skip** to apply the recommendation, or type **skip all** to skip all remaining questions.
```

For epic modes, add to the prompt: `> Or type **research this** to launch background research before answering.`

> **If this is the last qualifying question and it is free-form:** omit the "skip all" line.

When the user types **skip** for a free-form question: auto-apply the recommendation for that question, note it as `skipped→recommendation`, and continue to the next qualifying question.

Wait for responses before presenting the next batch (or next free-form question).

---

### Step 4.5 — Handle "Research this first" (epic modes only)

This step only applies to epic modes (`epic-pre`, `epic-post`, `epic-ux`). Issue modes do not offer "Research this first".

When the user selects "Research this first" for a question:

1. Launch a background subagent per the epic-workflow "Research This" Subagent Protocol:
   - Subagent reads current state of the relevant research brief section
   - Runs 3-5 Perplexity queries
   - Appends findings to Raw Notes (timestamped, source-tagged)
   - Notes connections to existing research
   - Returns 3-5 sentence summary
2. Continue presenting remaining qualifying questions — the user can fire multiple "research this" items while answering other questions directly (true parallel workflow)
3. When subagent results arrive, re-ask the original question with research context appended to the context line (**without** the "Research this first" option the second time)

---

### Step 5 — Handle "skip all"

When the user types "skip all":
1. Apply the recommended option for every unanswered qualifying question
2. Output:

```
### Assumptions Applied (skip all)
The following recommendations were auto-applied:
- Q[N] "[question title]": applied recommendation "[option text]"
- Q[N] "[question title]": applied recommendation "[option text]"
...
All assumptions are recorded in the Clarifications section below.
```

Then proceed to Step 6 to emit the Clarifications block. For all skipped questions, set the How column to `skipped→recommendation`.

---

### Step 6a — Output Clarifications block

After all questions are answered or skipped, output a block for the calling skill to embed in its output doc or plan comment:

```markdown
### Clarifications
*(from [mode] round — [YYYY-MM-DD])*

| Question | Answer | How |
|---|---|---|
| [question title] | [answer text] | chosen / custom / skipped→recommendation / resolved by research |
```

If no questions qualified for Pass A: output:
```markdown
### Clarifications
*(No clarifying questions needed — all human-judgment decisions already specified.)*
```

### Step 6b — Output Deferred to Research block

After Step 6a, output a second block listing questions deferred to Phase 1.5 research (Pass B results). This block is consumed by the calling skill to seed Phase 1.5 Sub-step B.

```markdown
### Deferred to Research
*(researchable questions — impact ≥ 6 — to be answered in Phase 1.5)*

- [question text] *(Impact: X/10 | Uncertainty: Y/10)*
- [question text] *(Impact: X/10 | Uncertainty: Y/10)*
```

If no questions qualified for Pass B: output:
```markdown
### Deferred to Research
*(none — no high-impact researchable questions)*
```
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
