> **Step 2/6** | ← requires: Step 1 (mode = full build) | → next: Step 3 (`03-full-build-jtbd.md`)

# Full Build — Frameworks & Customer Definition

> **Read before starting:** `references/protocols.md`, `references/context-management.md`
> **Session:** This step covers Phases 1-2 (Session 1). Split into separate sessions if complex.

---

## Phase 1: Philosophy & Framework Curation

### 1.1 Research: Identity Frameworks
- 5-8 queries: startup philosophy/mission frameworks for early-stage B2B SaaS
- 3-5 queries: how do successful SMB-focused startups articulate their identity?
- 3-5 queries: Viable System Model applied to startup organizational artifacts
- Read existing product docs (value proposition, user segments) — extract philosophical elements

### 1.2 Research: Strategy Frameworks
- 5-8 queries per framework area: JTBD variants, positioning, segmentation, messaging, PMF search, experiment design — which are most practical for a small team at early stage?
- 3-5 queries: are there GTM or positioning frameworks specifically adapted for [target region] markets? How do standard frameworks need modification for [target geography] context?

### 1.3 Draft
- Write `philosophy.md`: extract philosophical thinking from existing docs + user input
- Write `strategy.md Appendix A`: curated frameworks reference (placed at the end of the document)

### 1.4 Adversarial review on framework selection
See `references/protocols.md` → Adversarial Review Protocol.

### 1.5 Human gate
See `references/protocols.md` → Human Gate Protocol. Present philosophy.md + Appendix A.

### 1.6 Commit
See `references/context-management.md` → Progressive Commit Protocol.

---

## Phase 2: Customer & Market Definition

### 2.1 Gather Existing Data
- Read existing product/market docs (user segments, value proposition, CRM lifecycle)
- Read recent outreach results if available

### 2.2 Research: Market Landscape (heavy, 15-25 queries)
- [Target customer] behavior in [target geography] and [business categories from §2]
- Buyer decision patterns for [target persona] (decision-maker vs influencer dynamics)
- How [target customers] in [target market] currently handle [core problem domain]
- How other startups in [product category] define their ICP
- Beachhead market selection for two-sided marketplaces
- B2B sales culture and communication norms in [target geography]: how do business owners prefer to be contacted by vendors? Role of personal relationships and trust-building in [target geography] B2B sales. Cold outreach cultural acceptability.
- Regulatory landscape: commercial messaging regulations in [target geography] (anti-spam, data protection, messaging platform compliance)

### 2.3 Draft `strategy.md §2` using the following structure

**Document structure:** §2 is the first section readers see. Frameworks Reference lives at the end as Appendix A.

```
§2.1 Hypothesis Card (4Ps — compact, 1-2 sentences per P)
     Quick-reference card only — not the detail source.
§2.2 Target Customer (single section, all customer facts stated ONCE)
     Geography-agnostic — describes the customer archetype for ANY target market.
  a. Business Profile — type, categories, size, digital maturity
  b. Buyer Persona — role, decision dynamics, communication, behavioral context
  c. Pain Landscape — intensity by category, key frustrations
  d. Qualification Filters — accessibility, willingness to pay, prerequisites
§2.3 Market Scope & Beachhead
     Geography specifics go ONLY here — not in §2.2.
  a. Eligible market (broad) — eligibility criteria, not repeating §2.2 customer facts
  b. Current GTM focus (speartip) — specific geography + category testing list
     After the speartip dimensions table, add a "Speartip field insights" table:
     | Insight | Detail | Confidence |
     Capture behavioral observations specific to the current speartip geography/culture
     that may later be promoted to the Target Customer section (§2.2) as more markets are tested.
     Examples: scheduling norms, communication preferences, trust signals, vendor fatigue patterns.
  c. Beachhead rationale + expansion thesis
§2.4 Market Sizing (TAM/SAM/SOM)
§2.5 Unit Economics Hypothesis
§2.6 Seasonal Strategy
§2.7 Sales Culture Adaptation
```

**Key deduplication rules:**
- §2.2 Target Customer is the single source of truth for customer facts (merges former ICP Grid + Persona)
- §2.3 Eligible Market (broad) = eligibility filter referencing §2.2 archetype, NOT restating business type/geography/buyer
- §2.3 Current GTM Focus (speartip) = specific geography + category focus, NOT restating customer profile
- §2.1 Hypothesis Card (4Ps) = compact quick-reference (1-2 sentences per P), NOT the detail source

### 2.4 Clarifying questions (invoke `clarifying-questions` skill): target customer dimensions, market scope rationale, beachhead expansion thesis, qualification filter thresholds

### 2.5 Follow-up research (5-8 targeted queries based on user answers)

### 2.6 Human gate
See `references/protocols.md` → Human Gate Protocol. Present §2.

### 2.7 Commit
