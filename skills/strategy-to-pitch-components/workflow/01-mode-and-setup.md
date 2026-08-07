> **Step 1/5** | ← requires: `strategy.md`, `philosophy.md`, existing manifest/artifacts | → next: `02-phase-1-sales-research.md` or `03-phase-2-generation.md`

# Mode & Setup

## Overview

This is the entry point for every `strategy-to-pitch-components` invocation. It reads existing artifacts, determines the operating mode (Full Build, Incremental Update, or Confidence Review), initializes confidence tracking, and prepares the session context.

---

## 1. Read All Inputs

Before any mode decision, read (strategy/product docs live in the eldato repo — fetch: `gh api repos/daniel-ospina/eldato/contents/<path> --jq .content | base64 -d`):

- `docs/teams/eldato-app-team/domains (S1)/product/strategy.md` — §2 (customer/market), §3 (JTBD), §4 (competition), §5 (value prop), §6 (differentiators), §7 (pitch derivation map)
- `docs/teams/eldato-app-team/domains (S1)/product/philosophy.md` — identity/ethos for tone grounding
- `docs/09_strategy/sales-research-brief.md` — if exists from prior run
- Existing pitch components TypeScript file at `eldato-outreach: src/lib/pitch-components/pitch-components.ts` (if exists)
- Existing manifest at `eldato-outreach: src/lib/pitch-components/pitch-components-manifest.json` (if exists)
- `strategy-builder` Phase 8 assessment — keep/rewrite/remove/missing categorization (from conversation context or committed output)

Ensure `docs/09_strategy/research/` exists: `mkdir -p docs/09_strategy/research`

---

## 2. Determine Mode

Check for `pitch-components-manifest.json`:

- **Absent or empty** → **Full Build**
- **Exists:**
  - Hash current `strategy.md` §3–§7 sections (SHA-256)
  - Compare against manifest `section_hashes`
  - **3+ sections differ** → **Full Build** (too much changed for incremental)
  - **1–2 sections differ** → **Incremental Update**
  - **0 sections differ** → inform user nothing changed; offer to re-run adversarial review only
- **User explicitly says "full rebuild"** → **Full Build** regardless of manifest
- **User explicitly says "review confidence" or "update confidence"** → **Confidence Review** (see `references/incremental-mode.md`)

---

## 3. Confidence Check (Full Build & Incremental Only)

Before generating new components:

1. If existing components exist, present current confidence levels grouped by type
2. Ask: "Any promotions or demotions based on recent conversations before we generate new components?"
3. Present retired components (if any): "These are currently retired. Any to resurrect?"
4. Apply any changes, then proceed to the generation pipeline

Use `question-format` skill for all structured questions.

---

## 4. Initialize Research Dump

Create the research dump file at `docs/09_strategy/research/YYYY-MM-DD-pitch-components.md` (use today's date).

---

## 5. Route to Next Phase

| Mode | Next File |
|------|-----------|
| Full Build | `02-phase-1-sales-research.md` |
| Full Build (research brief exists + §2/§3 unchanged) | `03-phase-2-generation.md` |
| Incremental Update | `references/incremental-mode.md` then scoped Phases 2–6 |
| Confidence Review | `references/incremental-mode.md` (Confidence Review section only) |
