---
name: ux-design-review
description: "Pre-planning gate that classifies whether proposed changes involve UX decisions, presents structured options, and records user choices. Invoked by epic-workflow, project-workflow, and writing-plans when UX_RATING ≥ medium or changes touch UI. Not a design tool — a classification and decision-routing gate."
domain: capability
allowed-tools: read write edit bash
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

# UX Design Review — Pre-Planning Classification Gate

> **Ontology:** `docs/teams/organisation-design-team/data/ONTOLOGY.md` — canonical entity classes, work vocabulary, domain taxonomy.

## Purpose

Before planning begins, classify whether each proposed change involves a UX decision that needs human input. AGENTS.md mandates: "Any user-facing page, component, or visible behavior change must go through design review before planning or implementation." This skill operationalizes that rule.

**This is a classification gate, not a design tool.** It surfaces decisions, presents options, and records choices. It does NOT produce designs, mockups, or prototypes.

## When Invoked

| Consuming Skill | Trigger | Condition |
|-----------------|---------|-----------|
| `epic-workflow` | Between Stage 3 (Scope) and Stage 4 (Plan) | `UX_RATING ≥ medium` |
| `project-workflow` | Between Scope and Plan (proportional) | `UX_RATING ≥ medium` |
| `writing-plans` | After prerequisite check, before draft plan | Non-Micro + touches UI files |
| `issue-scoping` | Phase 1.5a companion | `UX_RATING ≥ medium` |

**Skip when:** Micro tier, pure backend/data/config changes, documentation-only, or `UX_RATING = low`.

## Process

### Step 1 — Scan proposed changes

From the issue/plan/epic, extract every proposed change that touches user-facing surfaces:

- New pages, components, modals, forms
- Modified layouts, navigation, information hierarchy
- New or changed copy (labels, CTAs, error messages, empty states)
- Changes to data display (what metrics are shown, how they're labeled)
- Subscription/paywall presentation changes
- Icon, color, or visual affordance changes
- Mobile vs desktop behavior differences

### Step 2 — Classify against the checklist

For each proposed change, check:

| # | UX Decision Type | Ask |
|---|---|---|
| 1 | **Metrics & data display** | Which data/metrics should the user see? How should they be labeled? |
| 2 | **Layout & hierarchy** | How should the page/card/section be organized? What's the information hierarchy? |
| 3 | **Copy & messaging** | What should CTAs, empty states, error messages, and labels say? |
| 4 | **Subscription gating** | How should gated content be presented? (blur, lock icon, upsell flow, preview?) |
| 5 | **Visual affordances** | What icons, colors, or visual cues communicate meaning? |
| 6 | **Responsive behavior** | How should this differ between mobile and desktop? |

If NONE of the 6 checklist items apply → the change has no UX decisions. Record "no UX decisions" and proceed.

### Step 3 — Present options

For each matching checklist item, present structured options using the `question-format` skill protocol:

```
## UX Decision: [type from checklist]

**Context:** [what's changing and why]

**Options:**
1. [Option A] — [trade-off]
2. [Option B] — [trade-off]
3. Defer to planning — revisit during writing-plans

**Recommendation:** [best-supported option with rationale]
```

**Research-before-ask:** Before presenting, check how comparable products handle this interaction. Cite 1-2 references. Propose, don't prescribe — present options, don't bake a decision into the plan.

### Step 4 — Record decisions

Output a structured decision record appended to the plan or issue comment:

```markdown
### UX Design Decisions

| # | Decision Type | User Choice | Rationale |
|---|---|---|---|
| 1 | Metrics display | Show deal count + avg price | User wants compact summary |
| 2 | Copy: CTA | "Ver ofertas" | Matches existing pattern in category pages |
| — | Layout | Deferred to planning | — |

**Pending:** Layout decision deferred to writing-plans.
```

### Step 5 — Proceed

Gate does NOT block — it surfaces and records. After decisions are recorded, hand back to the consuming skill. The recorded decisions inform the plan but don't gate it.

**Exception:** If a decision has P0 consequence (data loss, security, irreversible) → escalate as a hard gate per `human-input-framework`.

## Integration

**Consumed by:** `epic-workflow`, `project-workflow`, `writing-plans`, `issue-scoping`  
**References:** `question-format` (for presenting options), `human-input-framework` (for P0 escalation)  
**Companion to:** `issue-scoping` Phase 1.5a (UX Prototype Gate) — prototype gate validates visual fidelity; design review classifies decisions

## Anti-patterns

- ❌ Skipping classification and baking UX choices into the plan silently
- ❌ Presenting one option as "the answer" — always offer alternatives
- ❌ Blocking progress on non-P0 UX decisions — surface, record, proceed
- ❌ Duplicating what `brainstorming` already handled at creation time — check if decisions were already made
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
