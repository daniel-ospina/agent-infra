> **Step 2/5** | ← requires: `strategy.md` §2, §3, §7.3; research dump initialized | → next: `03-phase-2-generation.md`

# Phase 1: Sales Research

## Purpose

Build a culturally-grounded, methodology-informed research brief that guides component tone, structure, and tactical approach. All research queries are parameterized from `strategy.md` — read the strategy first, then construct research prompts from it.

---

## 1. Dynamic Inputs (Read Before Constructing Queries)

- `strategy.md` §2 → target geography, market segment, ICP characteristics
- `strategy.md` §3 → JTBD forces, buying triggers, objection patterns
- `strategy.md` §7.3 → persona types and emphasis

Follow the research protocol in `references/protocols.md`: abundance principle, research dump protocol, dynamic geography/market references.

---

## 2. Research Tracks (Run 4 Sub-Agents in Parallel)

Dispatch 4 sub-agents via `task` tool, one per track. Each agent must read the strategy sections it needs before constructing queries.

### Track A: Sales Culture & Communication Norms

- B2B selling norms in [target geography from §2]
- Communication patterns on [outreach channel] for B2B contact
- Formality/informality spectrum in [target geography] business communication
- Trust-building dynamics in [target market segment from §2]: personal relationship vs credentials vs social proof
- How [target persona types from §7.3] prefer to be approached by vendors
- **8–12 queries**

### Track B: B2B Sales Methodology

- Frameworks appropriate for the sales model implied by §2 ICP + §3 JTBD:
  - ACV level (from §2 unit economics) → consultative vs transactional
  - Volume vs enterprise → personalization depth
  - Relationship vs transactional market → trust-building investment
- Objection handling patterns for [anxiety forces from §3]
- Cold-to-warm conversion in [outreach channel]
- SPIN, Challenger, consultative selling — which patterns fit [target market segment] ACV and buyer sophistication?
- **8–12 queries**

### Track C: Channel-Specific Sales Tactics

- Best practices for [outreach channel] business messaging:
  - Optimal message length
  - Timing windows (day of week, hour)
  - Media usage (text vs voice note vs image vs video)
  - Follow-up cadence norms
  - What triggers blocks/reports vs what gets replies
- **5–8 queries**

### Track D: Vertical-Specific Selling

- How platforms/SaaS products sell to [target market segment from §2]
- Common objections in [target market segment] vertical
- Buying process for [target persona types from §7.3]: who decides, who influences, who blocks
- Decision-maker access patterns in [target market segment]
- Pricing sensitivity patterns in [target geography] [target market segment]
- **8–12 queries**

---

## 3. Synthesize Output

Synthesize all 4 tracks into `docs/09_strategy/sales-research-brief.md` with sections:

1. **Sales Culture Summary** (from Track A)
2. **Methodology Recommendations** (from Track B)
3. **Channel Playbook** (from Track C)
4. **Vertical Selling Guide** (from Track D)
5. **Cross-Track Insights** (patterns that emerged across tracks)

---

## 4. Human Gate

Present research brief summary using `human-gate` format (see `references/protocols.md`). Key question: "Does this match your experience selling to [target market segment] in [target geography]? What's missing or wrong?"

---

## 5. Commit

```bash
git add docs/09_strategy/ && git commit -m "docs(strategy): pitch components Phase 1 — sales research brief"
```

This is a documentation commit — exempt from `commit-workflow`.
