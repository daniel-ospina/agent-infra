> **Step 5/5** | ← requires: adversarial feedback (Phases 3–4), generated components | → final: thin `SKILL.md` (complete)

# Phases 5–6: Revision, Output & Manifest

---

## Phase 5: Revision & Human Review

### Process

1. **Synthesize** findings from both adversarial rounds (Phases 3 + 4)
2. **Categorize** feedback:

   | Tier | Criteria | Action |
   |------|----------|--------|
   | **Must-fix** | Majority of Phase 3 personas scored ignore/block, OR Phase 4 agent flagged as critical | Apply revision |
   | **Should-fix** | 2+ agents flagged (across both rounds) | Apply revision |
   | **Consider** | 1 agent flagged (minor concern) | Present for user judgment |

3. **Apply** must-fix and should-fix revisions to components
4. **Present** revised components with change annotations:
   - What changed and why (which agent feedback drove the change)
   - Components that remained unchanged (briefly, grouped)
   - "Consider" items presented for user judgment
5. **Human gate:** "Approve final component set before they become production constants?"

### Commit

```bash
git add docs/09_strategy/ && git commit -m "docs(strategy): pitch components Phase 5 — adversarial revision complete"
```

---

## Phase 6: Output & Manifest

### 1. Write Final TypeScript File

Write all approved components to `eldato-outreach: src/lib/pitch-components/pitch-components.ts`:

- Each component annotated with `// strategy_source: §N.N`
- Exports: typed array of `PitchComponent`, plus type definitions
- Components ordered by type, then by slug within type

Schema reference: `references/component-schema.md`

### 2. Generate/Update Manifest

Write to `eldato-outreach: src/lib/pitch-components/pitch-components-manifest.json`:

- `generated_at`: ISO timestamp
- `strategy_version`: git SHA of strategy.md at generation time
- `section_hashes`: SHA-256 of each strategy section (§3–§7)
- `components[]`: array with slug, type, strategy_source, generated_at, review_status, confidence, promoted_at, demoted_at

Full schema: `references/component-schema.md`

### 3. Update strategy.md §7.4

Populate the Bridge to TypeScript Components section with the component-to-strategy mapping (closes the traceability loop).

### 4. Commit to Both Repos

```bash
# in eldato repo
git add docs/09_strategy/ && git commit -m "docs(strategy): pitch components Phase 6 — manifest + §7.4 bridge"

# in eldato-outreach repo
git add src/lib/pitch-components/ && git commit -m "feat(strategy): pitch components TypeScript + manifest"
```

---

## Context Management

### Session Boundaries

| Session | Phases | Output |
|---|---|---|
| 1 | Phase 1 (Sales Research) | `sales-research-brief.md` + research dump |
| 2 | Phases 2–6 (Generation → Output) | Components + manifest + strategy-gaps |

**Adaptive:** If research brief already exists and is current → single session for Phases 2–6.

Incremental mode typically fits in one session.

### Session Handoff

When ending a session mid-pipeline:
1. Ensure all outputs written to disk + committed
2. Provide exact resume prompt:

```
Continue strategy-to-pitch-components in [Full Build / Incremental] mode.
Read ALL artifacts:
- docs/teams/eldato-app-team/product/strategy.md
- docs/teams/eldato-app-team/product/philosophy.md
- docs/09_strategy/sales-research-brief.md
- docs/09_strategy/research/YYYY-MM-DD-pitch-components.md (latest research dump)
- eldato-outreach: src/lib/pitch-components/pitch-components.ts (if exists)
- eldato-outreach: src/lib/pitch-components/pitch-components-manifest.json (if exists)
Resume from Phase [N]. Previous session completed through Phase [N-1].
[Any specific context about gaps found or decisions made]
```

---

## Sub-Agent Usage Summary

| Phase | Agents | Type |
|-------|--------|------|
| Phase 1 | 4 parallel research agents (Tracks A–D) | One per topic area |
| Phase 3 | Parallel persona agents (one per persona from §7.3) | Number varies with strategy |
| Phase 4 | 3 parallel methodology review agents | Sales methodology, cultural fit, anti-pattern |

All sub-agents must read relevant `strategy.md` sections before starting, append to research dump if doing research, and return structured outputs.

---

## Key Principles

1. **Components are hypotheses** — every generated component is a hypothesis to test in real conversations, not final copy. All new components start at `confidence: 'hypothesis'`.
2. **Never hard-delete** — components are never removed from the TypeScript file. Set `confidence: 'retiring'` and `is_active: false`. Explicit user confirmation required.
3. **Only the user promotes confidence** — the skill never auto-promotes. Confidence transitions are manual based on field experience.
4. **Never hardcode market specifics** — all geography, channel, persona, and market segment references read from `strategy.md` at runtime.
5. **Spanish is primary** — `content_es` is written first, naturally. `content_en` is a faithful translation.
6. **Every component traces to a strategy source** — the `// strategy_source: §N.N` annotation is mandatory.
7. **Flag and continue** — strategy gaps are logged, not hard gates.
8. **Two adversarial rounds are mandatory** — persona role-play + methodology review. Skipping either degrades quality.
9. **The manifest enables incremental mode** — always update it.
10. **Tone over content** — a factually perfect component with corporate tone will get blocked. Research brief cultural norms are binding constraints.
11. **The process improves itself** — if adversarial review consistently flags the same pattern, update generation instructions to prevent it.
12. **Abundant user alignment** — Phase 2 has 6+ human gates. Pitch components encode the founder's sales intuition; the skill structures and challenges that intuition, not replaces it.

---

## Common Mistakes

| Mistake | Fix |
|---|---|
| Feature-dumping (listing capabilities without connecting to pain) | Every component must trace to a JTBD force via §7.1 mapping |
| Corporate tone on WhatsApp ("We offer a comprehensive solution...") | Use research brief cultural norms. Sound like a knowledgeable local, not a sales deck |
| Hardcoding persona list | Read from `strategy.md` §7.3 |
| Hardcoding geography/channel in queries | Use dynamic references: "in [target geography from §2]" |
| Generating without research brief | Phase 1 must complete before Phase 2 |
| Orphan components (no strategy_source) | Every component links to §N.N via §7.2 mapping |
| Skipping adversarial review | Both rounds are mandatory |
| Translating English → Spanish | Write `content_es` first, translate to English second |
| Components too long for channel | 1–3 sentences each — building blocks, not complete messages |
| Ignoring Phase 8 assessment | Honor keep/rewrite/remove categorization |
| Updating components without updating manifest | Manifest must always reflect current state |
| Hard-deleting components | Never remove from file. Retire with user confirmation |
| Auto-promoting confidence levels | Only the user promotes |
| Treating components as final copy | Frame as "hypothesis to test" |
| Skipping human gates in Phase 2 | All 6+ gates are mandatory |
