# Incremental Update Mode

## Trigger

`strategy.md` sections §3–§7 have been updated since last manifest. User wants to regenerate only affected components.

## Process

### I.1 Detect Changes
- Read manifest `section_hashes`
- Hash current `strategy.md` §3–§7 sections
- Diff: which sections changed?
- List components whose `strategy_source` maps to changed sections (using §7.2 mapping)

### I.2 Research Check
- If §2 (customer definition) or §3 (JTBD) changed → re-run Phase 1 sales research (these are foundational)
- Otherwise → skip Phase 1, reuse existing `sales-research-brief.md`

### I.3 Targeted Regeneration (Phase 2, scoped)
- Regenerate only components whose source sections changed
- Preserve unchanged components exactly (including version numbers)
- Increment `version` on regenerated components

### I.4 Scoped Adversarial Review (Phases 3–4, scoped)
- Adversarial review of changed components only
- Persona agents still read ALL components (context matters) but score only changed ones
- Methodology agents focus on changed components

### I.5 Revision (Phase 5, scoped)
- Apply fixes to changed components only
- Human gate: review changes with diff annotations

### I.6 Merge Output (Phase 6)
- Merge regenerated components into existing TypeScript file
- Update manifest: new section hashes, updated component entries, preserve unchanged entries
- Commit to both repos (`eldato` and `eldato-outreach`)

## Confidence Review Mode

Lightweight standalone mode — no research, no generation, no adversarial review.

### Process
1. Read existing pitch components TypeScript file and manifest
2. Present all active components grouped by type, showing current `confidence` level
3. For each component, ask user (using `question-format` skill):
   - Keep at current confidence level?
   - Promote (e.g., `hypothesis` → `promising`)?
   - Demote (e.g., `validated` → `retiring`)?
   - Ask user for reasoning (brief note — what did they observe in conversations?)
4. Update the TypeScript file and manifest with new confidence levels + timestamps
5. Commit: `git add && git commit -m "docs(strategy): pitch components confidence review — [date]"`

### Retirement Confirmation
When user wants to demote to `retiring`:
- Show the component content one more time
- Confirm: "This will set `is_active: false`. The component stays in the file for reference. Confirm?"
- Never hard-delete.
