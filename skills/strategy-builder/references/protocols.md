# Strategy Builder — Protocols Reference

> Referenced by: `workflow/01-mode-and-setup.md` and all full build workflow files.

---

## Confidence Tiers

All JTBD elements, assumptions, and strategic claims must be tagged with a confidence tier:

- **`desk-research`** — hypothesized from secondary sources (Perplexity, articles, competitor analysis)
- **`founder-intuition`** — from founder experience and outreach conversations, not formally validated
- **`field-validated`** — heard directly from a prospect/customer in their own words, or confirmed by experiment data

Use inline tags: `[desk-research]`, `[founder-intuition]`, `[field-validated]`.

At human gates, ask the user to upgrade `desk-research` items where they have direct experience: "Which of these have you heard directly from prospects? Can you share the exact words they used?"

---

## Research Protocol

### Abundance Principle

Research is cheap and compounds. Every phase includes multiple rounds of queries. Do not conserve — 10 queries per topic is normal, 15 is fine. High-leverage foundational work.

### Research Dump Protocol

Every Perplexity query result is appended to the research dump file:

```markdown
## Phase N: [Phase Name]

### Query: "[exact query]"
**Source:** Perplexity | **Date:** YYYY-MM-DD

[Full response]

---
```

Create the dump file at the start of each run:
- Full build: `docs/09_strategy/research/YYYY-MM-DD-full-build.md`
- Incremental: `docs/09_strategy/research/YYYY-MM-DD-incremental.md`
- Review: `docs/09_strategy/research/YYYY-MM-DD-review.md`

### Research Round Pattern

Each phase follows this pattern:
1. **Broad sweep** (8-15 queries) — cast wide, explore the space
2. **Synthesize** — rewrite the relevant strategy.md section integrating old + new findings (NOT appending a separate "round 2" block). Note what changed vs previous version. Flag remaining gaps.
3. **Convergence check** — list remaining gaps, note which claims are strong vs weak. If 3 consecutive queries returned no new insights → stop. Otherwise, proceed to follow-up.
4. **Targeted follow-up** (5-8 queries) — fill gaps, challenge weak claims
5. **Integrate** — final section rewrite with all findings incorporated

### Using Existing Data

Before any research round, read:
- Current state of `strategy.md` (relevant sections)
- Existing product/market docs that feed this section
- Previous research dumps in `docs/09_strategy/research/`

Do not duplicate research already done. Build on it.

### Geography & Market References

**Never hardcode geographies, categories, or channels in research queries.** Always reference the strategy document dynamically:
- "SMB behavior in [target geography from §2]" not "SMB behavior in Mexico"
- "[business categories from §2]" not "the 12 categories"
- "[outreach channel]" not "WhatsApp"
- "[target persona from §2]" not "restaurant owner"

This keeps the skill reusable across strategy pivots and market changes.

---

## Adversarial Review Protocol

Used in Phases 3, 3.5, 4, 5, and 7. Three agents run **sequentially** (not parallel — Defender needs Attacker's output):

### Agent 1: Attacker
- **Persona:** A skeptical investor who has seen 50 SMB SaaS pitches fail. Your job is to identify which failure mode this strategy is heading toward.
- **Input:** receives full strategy.md (completed sections) + philosophy.md + research dump
- Has Perplexity access — research "startups with similar strategy that failed" and "why [specific assumption] doesn't hold in [specific market]"
- **Must produce at least 1 critical finding.** If unable to, explain why and flag this as suspicious.
- Output: numbered list of issues with severity (critical/major/minor)

### Agent 2: Defender
- **Input:** receives Attacker's output + same files
- Respond to each attack with evidence or concession
- Has Perplexity access — research supporting evidence
- Output: response to each issue (defended/conceded/partially conceded)

### Agent 3: Synthesizer
- **Input:** receives both Attacker and Defender outputs
- Produce categorized fix list: fix now / flag for human / acceptable as-is
- Severity: critical (breaks strategy coherence) / major (weakens argument) / minor (cosmetic)

**Loop count:** 2 minimum. If loop 2 still has critical findings → run loop 3. Cap at 4 loops.

---

## Clean Room Comparison (Phase 4)

Used when drafting the Value Proposition (§5):

- **Agent A:** Draft §5 from scratch using ONLY JTBD findings (Phase 3) + competition analysis (Phase 3.5). Do NOT read existing value proposition docs.
- **Agent B:** Draft §5 by evolving existing value proposition doc with JTBD framing.
- **Compare the two drafts.** The delta between them reveals anchoring bias. Present both to user at human gate: "What survived from the old VP? What's new? Where did anchoring pull us toward the old framing despite evidence?"

---

## Human Gate Protocol

At human gates, present using `question-format` skill for all structured questions:
1. **Summary** of what was produced (2-3 sentences)
2. **Key decisions** or insights that emerged
3. **Confidence check** — which items are `desk-research` vs `founder-intuition` vs `field-validated`? Ask user to contribute real prospect language where possible.
4. **Structured questions** for decisions needing user input
5. **What comes next** (next phase overview)

Wait for explicit approval before proceeding.

---

## Key Principles

1. **Strategy is coherence** — every section must connect to every other. Incoherent strategy is worse than no strategy.
2. **PoV is emergent** — philosophy.md grounds identity, but positioning emerges from JTBD + competition + field learnings. Don't hardcode.
3. **Preserve specificity** — when the user gives details, document at that level. Don't abstract into generic statements.
4. **Competitors are dynamic** — who counts depends on current strategy. Update the set as strategy evolves.
5. **Earned secrets are the moat** — capture aggressively, review regularly. But distinguish field notes (raw observations) from earned secrets (non-obvious + actionable + earned).
6. **Desk research is fast, field validation is slow** — get directionally right quickly, then let field data refine.
7. **Pitch components are derived artifacts** — they come FROM strategy, not vice versa.
8. **The process improves itself** — Phase 9 retrospective proposes skill updates.
9. **Never hardcode market specifics in queries** — always reference strategy.md sections dynamically.

---

## Common Mistakes

| Mistake | Fix |
|---|---|
| Feature-dumping pitch (listing features not jobs) | Every component must trace to a JTBD pain/force |
| Hardcoding PoV in strategy.md | PoV references philosophy.md, emerges from analysis |
| Skipping research ("we already know this") | Research validates or challenges. Do it anyway. |
| Abstracting user's specific details | Preserve exact structure and dimensions given |
| Running coherence review on incomplete strategy | Phase 7 only after 1-6 complete |
| Repeating customer facts across §2 subsections | §2.2 Target Customer is the single source of truth. §2.3 references §2.2 — broad = eligibility filter, speartip = current GTM focus. §2.1 (4Ps) is a compact card, not the detail source. |
| Putting geography in §2.2 Target Customer | §2.2 is geography-agnostic (describes the archetype for any market). Geography specifics go only in §2.3 Market Scope & Beachhead. |
| Competitor analysis as feature comparison | Analyze what they UNDERSTAND, not what they build |
| Anchoring VP to existing doc | Clean room comparison: draft fresh from JTBD first |
| Treating all insights as earned secrets | Qualification test: non-obvious + actionable + earned. Desk research = field notes. |
| Hardcoding geography/channel in queries | Reference §2 dynamically: "in [target geography from §2]" |
| Adversarial review producing theater | Attacker must find ≥1 critical issue. If zero, explain why. |
| Skipping convergence checks | After synthesis: list gaps, assess if more research needed |
