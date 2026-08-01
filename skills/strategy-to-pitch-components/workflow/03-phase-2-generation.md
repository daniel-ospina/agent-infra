> **Step 3/5** | ← requires: `sales-research-brief.md`, `strategy.md` §3–§7, `philosophy.md` | → next: `04-phase-3-4-adversarial.md`

# Phase 2: Component Generation

## Purpose

Generate pitch components from strategy + research, producing a complete TypeScript constants file with bilingual content, per-component strategy traceability, and persona targeting. **All components start at `confidence: 'hypothesis'`** — they are hypotheses to test in real conversations, not final copy.

Component schema reference: `references/component-schema.md`

---

## 1. Inputs Loaded

- `strategy.md` §3–§7 (JTBD, competition, value prop, differentiators, pitch derivation)
- `philosophy.md` (tone grounding — how do we talk? What's our identity?)
- `sales-research-brief.md` (cultural/methodological constraints from Phase 1)
- Existing pitch components draft (if exists — honor `strategy-builder` Phase 8 assessment: keep/rewrite/remove/missing)

---

## 2. Hypothesis Framing

**Every generated component is a hypothesis, not a fact.** Frame all components this way during generation and human gates:

- "We hypothesize that leading with [angle] will resonate with [persona] because [strategy reasoning]"
- Present components as testable assertions, not finished messaging
- The goal: produce a *diverse, well-reasoned set of hypotheses* to test in the field — not converge on "the right answer" prematurely

---

## 3. Generation Structure: Force-First with Persona Cross-Cut

Generation proceeds in **4 force batches** (from §7.1), each with a human gate, followed by a **persona cross-cut review**. This ensures tight alignment at every step.

### §7 Derivation Map Reference

| Force batch | §7.1 mapping | Component types | Primary §7.2 sources |
|---|---|---|---|
| Push | situation pain → problem statements | `description`, `data_point` | §3 JTBD, §5 Value Prop |
| Pull | imagined better life → value propositions | `USP`, `benefit` | §5 + §6 |
| Anxiety | fears about switching → objection handling | `counter_argument`, `faq` | §3 + §4 |
| Habit | inertia → migration messaging | `context`, `differentiator`, `roadmap`, `business_model` | §2 + §3 + §4 + §5 + §6 |

Per-persona emphasis (§7.3) is applied during generation and validated during the persona cross-cut review.

Strategy source annotations (§7.4) are applied to every component: `// strategy_source: §N.N`

---

## 4. Force Batches

### Batch 1: Push Forces (situation pain)

- Read §3 JTBD push forces + §5 value proposition data
- Generate components: `description`, `data_point`
- Each component gets `confidence: 'hypothesis'`, `strategy_source`, `target_personas`, tags

**Human Gate 1** (use `question-format` skill):
- Present each generated component with its strategy source and reasoning
- For each: "Does this pain point land? Is the framing right? Would you say it differently?"
- "Any pain points missing from this batch that you've heard in real conversations?"

### Batch 2: Pull Forces (imagined better life)

- Read §3 JTBD pull forces + §5 value proposition + §6 differentiators
- Generate components: `USP`, `benefit`

**Human Gate 2:**
- Present each component with its hypothesis framing
- "Does this promise feel credible? Too big? Too vague? Would a [target persona] actually care about this?"
- "Which of these excites you most? Which feels weakest?"

### Batch 3: Anxiety Forces (fears about switching)

- Read §3 anxiety forces + §4 competition analysis
- Generate components: `counter_argument`, `faq`

**Human Gate 3:**
- Present each objection handler with the objection it addresses
- "Have you actually heard this objection? How did you respond? Does this component match how you'd handle it?"
- "Any objections you've encountered that aren't covered here?"

### Batch 4: Habit Forces (inertia of current solution)

- Read §3 habit forces + §4 competition + §6 differentiators
- Generate components: `context`, `differentiator`, `roadmap`, `business_model`

**Human Gate 4:**
- Present components addressing why prospects stick with their current approach
- "Is this how they actually talk about their current setup? Or are we projecting?"
- "Which current-solution assumptions feel strongest/weakest?"

---

## 5. Persona Cross-Cut Review

After all 4 batches are approved, regroup ALL generated components by target persona.

**Human Gate 5** — For each persona (read from §7.3):
- "Here's everything [persona] would hear across the full conversation flow. Does the sequence cohere? Is anything missing? Does the tone shift awkwardly between components?"
- Flag any persona that has thin coverage (few components targeting them)

**Human Gate 6** (if strategy gaps found):
- Present gaps and ask whether to proceed with adversarial review as-is or pause for strategy updates

---

## 6. Content Generation Rules

- **Bilingual:** `content_es` (Spanish) is primary — write it first, naturally. `content_en` is a translation, not a separate draft.
- **Tone:** Grounded in `philosophy.md` identity + `sales-research-brief.md` cultural norms. Must sound like a knowledgeable local recommendation, not a corporate pitch.
- **Length:** Components are building blocks the agent assembles — each 1–3 sentences, not paragraphs.
- **Tags:** Assign from the 9-tag set based on which conversation phases/contexts the component fits.
- **Slug naming:** `snake_case`, descriptive, unique. E.g., `community_size`, `no_contract_flexibility`.
- **Confidence:** All new components start at `confidence: 'hypothesis'`. Only the user promotes.

---

## 7. Strategy Gap Detection

When a strategy section is too vague, abstract, or missing to derive a concrete component:

1. **Do not hard gate.** Continue generating other components.
2. Log to `docs/09_strategy/strategy-gaps.md`:

```markdown
## Gap: [Component Type] — [What was being derived]

**Source section:** §N.N
**Problem:** [Why the section is insufficient — too vague? Missing data? Contradictory?]
**Impact:** [Which components could not be generated or are weak]
**Suggested improvement:** [What the strategy section needs to say]
```

---

## 8. Output

- Complete TypeScript file with all components (single file, following `references/component-schema.md`)
- `strategy-gaps.md` if any gaps found

---

## 9. Commit

```bash
git add docs/09_strategy/ && git commit -m "docs(strategy): pitch components Phase 2 — component generation"
```

This is a documentation commit — exempt from `commit-workflow`.
