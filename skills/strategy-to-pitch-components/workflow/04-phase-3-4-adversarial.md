> **Step 4/5** | ← requires: generated components, `strategy.md` §2, §7.3, `sales-research-brief.md` | → next: `05-phase-5-6-output.md`

# Phases 3–4: Adversarial Review

## Overview

Two mandatory adversarial review rounds. Phase 3 catches "feels wrong" (persona role-play). Phase 4 catches structural gaps (methodology review). Both rounds are required — skipping either degrades quality.

---

## Phase 3: Adversarial Review — Round 1 (Persona Role-Play)

### Purpose

Gut-check: "Would you actually reply to this message?"

### Dynamic Persona Spawning

Read persona types from `strategy.md` §7.3 (per-stakeholder pitch emphasis). Spawn one parallel **sub-agent** per persona (via `task` tool). Each agent is briefed with:

- The persona's role, authority level, and priorities (from §7.3)
- The target market segment context (from §2)
- The cultural communication norms (from the Phase 1 research brief)

### Each Agent Does

1. Reads all generated components
2. Simulates receiving each warmup/discovery/pitch message via the outreach channel
3. Scores each component: **reply-worthy** / **ignore** / **block**
4. Explains why for each score (1–2 sentences)
5. Flags specific phrasing that triggers negative reactions (e.g., "this sounds like spam", "too corporate", "I'd block this number")

### Output

Persona feedback report — **conversation-ephemeral** (not committed to disk). Feeds Phase 5 revision.

---

## Phase 4: Adversarial Review — Round 2 (Methodology Review)

### Purpose

Structural check: does the messaging follow proven sales patterns?

### 3 Parallel Sub-Agents (dispatch via `task`)

**Agent 1: Sales Methodology Alignment**

- Checks components against frameworks identified in research brief (SPIN questions, Challenger insights, consultative approach patterns)
- Key question: "Are we leading with insight or leading with product?"
- Flags components that describe features without connecting to a job/pain

**Agent 2: Cultural Fit**

- Checks against communication norms from research brief
- Key question: "Does this sound like a local recommendation or a corporate pitch?"
- Checks: formality level, relationship-building signals, channel-native phrasing, trust cues
- Flags anything that would feel foreign or tone-deaf to [target persona in target geography]

**Agent 3: Anti-Pattern Detection**

Scans for common sales messaging anti-patterns:

| Anti-Pattern | Example |
|---|---|
| Pushy language | "Don't miss out!", "Act now!" |
| Corporate jargon | "synergy", "leverage", "solution" |
| Discount-leading | "Special offer!", "X% off!" |
| Feature-dumping | Listing capabilities without connecting to pain |
| Needy follow-ups | "Just checking in...", "Did you see my message?" |
| Spam signals | ALL CAPS, excessive punctuation, too many emojis |
| Over-long messages | Exceeds channel-appropriate length |

Flags each anti-pattern with severity: **critical** / **major** / **minor**

### Output

Methodology feedback report — **conversation-ephemeral** (not committed to disk). Feeds Phase 5 revision.

---

## Agent Briefing Notes

All sub-agents must:
- Read relevant `strategy.md` sections before starting
- Return structured outputs (score + explanation per component)
- Append to research dump if doing additional research
