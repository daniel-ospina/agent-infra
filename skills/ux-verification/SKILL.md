---
name: ux-verification
description: "Use when verifying UI changes for component library compliance, common UX failure patterns, and accessibility basics. Complexity-proportional: UX=low checks component catalog, UX=medium adds failure patterns, UX=high dispatches full ux-path-auditor. Invoked by test-routing when UI changes are detected."
domain: engineering
subjects.team: organisation-design-team
allowed-tools: read write edit bash grep find web_search web_fetch
---

> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

> **Multi-repo:** Universal patterns. For repo-specific references (component catalog, design tokens, pipeline skills), see `repo-conventions.md`.

# UX Verification — Component Compliance & Quality

## Overview

Checks that UI changes use existing component library components, handle common UX states, and meet accessibility basics. Depth scales with UX complexity rating.

**Announce at start:** "I'm using the ux-verification skill to check UX quality (depth: minimal|standard|full)."

Invoked by `test-routing` when UI changes are detected.

### When to Use

- New UI components or pages
- Style/layout changes
- Visual modifications to existing components
- Any PR with `.tsx` file changes touching UI

### When NOT to Use

- Pure logic/backend changes with no UI
- Config/documentation changes
- Already passed ux-verification in a prior run → reuse report

## Depth Scaling

| UX Rating | Depth | Checks |
|-----------|-------|--------|
| low | minimal | Component catalog check only |
| medium | standard | + common failure patterns |
| high | full | + ux-path-auditor dispatch |

## Process

### Step 1 — Identify UI Changes

From the PR diff or feature description, list all UI changes:

```
UI changes detected:
- New: <PricingDisplay> component (src/components/pricing/PricingDisplay.tsx)
- Modified: <DealCard> — added discount badge
- New page: /deals/premium
```

### Step 2 — Component Catalog Check (all depths)

Check every new/modified component against your project's component catalog.

```tsx
// ❌ P1: Raw div where catalog component exists
<div className="pricing-card">
  <h3>{title}</h3>
  <span className="price">{price}</span>
</div>

// ✅ Use existing component from catalog
import { PricingCard } from '@/components/ui/PricingCard';
<PricingCard title={title} price={price} />
```

**Checklist:**
- [ ] No raw divs where catalog components exist — use the catalog component
- [ ] Semantic design tokens used (e.g., `text-primary`, `bg-card`) not hardcoded colors
- [ ] No duplicate components — a component that duplicates an existing one is a bug
- [ ] New components (not in catalog) follow existing patterns and conventions

See `repo-conventions.md` for catalog path and token names.

### Step 3 — Common Failure Patterns (depth ≥ standard)

Check every UI change for these states:

#### Loading State
```
- [ ] Is there a loading indicator while data fetches? (Skeleton, spinner, or progress)
- [ ] Does the loading state prevent interaction with stale data?
```

#### Empty State
```
- [ ] What does the component show when there's no data? (not just blank space)
- [ ] Is there a helpful message or CTA? ("No deals yet — browse available deals")
```

#### Error State
```
- [ ] What happens when data fetch fails? (not a white screen or crash)
- [ ] Is there a retry mechanism? (button or automatic)
- [ ] Is the error message user-friendly? (not "Error 500: internal server error")
```

#### Responsive Breakpoints
```
- [ ] Does layout work at mobile (375px), tablet (768px), desktop (1280px)?
- [ ] Do touch targets meet minimum size? (≥ 44x44px on mobile)
- [ ] No horizontal scroll on mobile viewport?
```

#### Keyboard Navigation
```
- [ ] Can all interactive elements be reached via Tab?
- [ ] Is focus visible on all elements? (no focus:outline-none without replacement)
- [ ] Can forms be submitted via Enter?
- [ ] Can modals/dialogs be closed via Escape?
```

### Step 4 — Accessibility Basics (depth ≥ standard)

Run these checks — no special tools needed:

```
- [ ] Heading hierarchy is logical (h1 → h2 → h3, no skips)
- [ ] All images have alt text (informative images) or alt="" (decorative)
- [ ] Color is not the only way to convey information (error states use icon + text, not just red border)
- [ ] Form inputs have associated labels (not just placeholders)
- [ ] lang attribute is present on <html>
```

### Step 5 — Full Audit (depth=full only)

Dispatch `ux-path-auditor` for comprehensive path-based audit. This runs Playwright-based checks across the full user journey.

```
Depth=full detected. Dispatching ux-path-auditor for:
- Path: /deals → /deals/premium → /checkout
- Viewports: desktop (1280px), mobile (375px)
```

### Step 6 — Output UX Report

```markdown
## UX Verification Report

**Depth:** standard (UX=medium)
**Components checked:** 3 (2 existing, 1 new)

### Violations

| # | Severity | Type | Location | Description | Fix |
|---|----------|------|----------|-------------|-----|
| 1 | P1 | duplicate_component | `src/components/pricing/PricingDisplay.tsx:5` | Raw `<div>` used where `<PricingCard>` exists in catalog | Replace with `<PricingCard>` from `@/components/ui/PricingCard` |
| 2 | P2 | missing_state | `src/components/pricing/PricingDisplay.tsx:20` | No empty state — blank when deals=[] | Add empty state: "No pricing plans available" with link to contact |

### Passed
- ✅ Semantic HTML — heading hierarchy correct
- ✅ Loading state — skeleton shown during fetch
- ✅ Error state — error boundary with retry button
- ✅ Keyboard navigation — all elements reachable via Tab
- ✅ Responsive — layout adapts at 375/768/1280px
- ✅ Color contrast — all text meets 4.5:1 ratio
```

## Pipeline Handoff

**Invoked by:** your routing/planning pipeline when UI changes detected
**Dispatches to:** your path auditor (depth=full only), your code review step (reads UX report)
**Consumed by:** your code review pipeline (see conventions for repo integration)

## What Fails If You Skip

| Skip | Consequence |
|------|-------------|
| Component catalog check | Duplicate components accumulate — 3 different pricing cards doing the same thing |
| Loading/empty/error states | Users see blank pages, crashes, or unhelpful error messages |
| Keyboard navigation | Keyboard-only users cannot use the feature — accessibility regression |
| Responsive check | Mobile users get broken layouts — horizontal scroll, tiny touch targets |
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
