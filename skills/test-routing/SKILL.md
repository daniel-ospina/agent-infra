---
name: test-routing
description: "Entry point for verification dispatch. Reads integration surface map + complexity ratings, determines required verification domains and depth, dispatches to sub-skills. Domain-aware (code/content/config/research/ux) + complexity-proportional. Use before implementing any feature to route to correct verification."
domain: engineering
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
---

> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

> **Multi-repo:** This skill is universal. For repo-specific tooling (Supabase, file paths, pipeline skills), see `repo-conventions.md`. If your repo uses different tools, adapt the patterns below.

# Test Routing — Verification Dispatch

## Overview

Routes every feature to the correct verification based on what domain it touches and how complex it is. Think of this as the `issue-workflow` of verification: detect → dispatch.

**Announce at start:** "I'm using the test-routing skill to dispatch verification."

Invoked by `writing-plans` after `test-design` produces the integration surface map. Also invoked by `code-review` to detect missing verification layers.

### When to Use

- After test-design produces an integration surface map (planning time)
- During code-review to check coverage gaps (merge time)
- Anytime you need to know "what verification does this feature need?"

### When NOT to Use

- Pure copy/label/i18n changes with no logic → no verification needed
- Documentation-only changes → no verification needed
- The feature already has a verification plan from a prior routing run → reuse it

## Taxonomy & Registry

The canonical registry of verification domains and their destinations. New sub-skills register here.

### Domain Dispatch Table

| Domain | Detection | Destinations (this epic) | Destinations (deferred) |
|--------|----------|--------------------------|------------------------|
| **code** | Surface map has DB/API/state surfaces | test-writing (unit), test-integration, test-e2e, check:coverage-pruning, check:arch:changed, check:mutation | — |
| **content** | Issue has content/editorial/deal labels | content-verification → content-strategy-agent | — |
| **config** | Changes to config files, env vars, CI | config-validation → scripts/check-* | — |
| **research** | Issue is research/investigation | research-verification → research skill adversarial review | — |
| **ux** | UI changes, new components, style changes | ux-verification | ux-path-auditor (existing, for UX=high) |

### Complexity-Proportional Depth Scaling

Verification depth scales with issue complexity ratings. Higher rating → deeper verification.

```
UX=low     → component catalog check only
UX=medium  → + common failure patterns (loading/empty/error states)
UX=high    → + full ux-path-auditor dispatch

Architecture=low    → unit tests only
Architecture=medium → + integration tests for DB surfaces
Architecture=high   → + e2e tests for critical paths + architectural-soundness review

Ontology=low   → no special checks
Ontology=medium → schema-correctness if DB schema changes
Ontology=high   → + ontology-alignment review

Accessibility=low  → no special checks
Accessibility=medium → basic a11y checks (contrast, headings, alt text)
Accessibility=high   → + full accessibility audit
```

### Skill Registry

| Skill | File | Status | Domains |
|-------|------|--------|---------|
| test-writing | `../test-writing/SKILL.md` | existing | code (unit, includes PBT guidance) |
| test-design | `../test-design/SKILL.md` | existing | code (planning, includes PBT guidance) |
| test-review | `../test-review/SKILL.md` | existing | code (quality) |
| test-integration | `../test-integration/SKILL.md` | new (#6065) | code (integration) |
| test-e2e | `../test-e2e/SKILL.md` | new (#6066) | code (e2e) |
| check-coverage-pruning | `scripts/check-coverage-pruning.cjs` | new (#6461) | code (coverage) |
| check-arch | `scripts/cron-quality-gates.sh arch` | new (#6463) | code (architecture) |
| check-mutation | `scripts/cron-quality-gates.sh mutation` | new (#6460) | code (mutation) |
| ux-verification | `../ux-verification/SKILL.md` | new (#6067) | ux |
| content-verification | `../content-verification/SKILL.md` | new (#6114) | content |
| config-validation | `../config-validation/SKILL.md` | new (#6115) | config |
| research-verification | `../research-verification/SKILL.md` | new (#6116) | research |
| ux-path-auditor | `../ux-path-auditor/SKILL.md` | existing | ux (full audit) |

## Process

### Step 1 — Detect Domain

Determine the primary domain from the issue context:

```
IF issue has code changes:

  Check surface map (from test-design):
    - DB surfaces present → code domain, integration layer needed
    - API surfaces present → code domain, integration layer needed
    - Critical path UI changes → code domain, e2e layer needed
    - Pure logic, no external deps → code domain, unit only

  Check UI changes:
    - New components or style changes → ux domain
    - Existing component usage only → ux domain (light)

IF issue is content/editorial/deal → content domain
IF issue is config/infra/CI → config domain
IF issue is research/investigation → research domain
```

Multiple domains can apply to one feature. Route to all applicable.

### Step 2 — Read Complexity Ratings

Extract from the issue body or plan doc:

```
UX: low | medium | high
Architecture: low | medium | high
Ontology: low | medium | high
Accessibility: low | medium | high
```

If ratings are missing, default to `medium` for all axes (safe default — over-verify rather than under-verify).

### Step 3 — Determine Verification Depth

For each applicable domain, apply the complexity-proportional scaling rules from the Taxonomy section:

Example:
```
Architecture=high, DB surfaces present
→ test-integration (depth=full) + test-e2e (depth=smoke) + architectural-soundness review

UX=medium, UI changes present
→ ux-verification (depth=standard) — component catalog + failure patterns, no full audit
```

### Step 4 — Dispatch

Produce the verification plan and dispatch to sub-skills:

1. For each destination skill, read its SKILL.md to get the detailed process
2. Pass the relevant surface map subset + depth parameter
3. Skills that are deferred return a pointer to the existing pipeline instead

**Fallback:** If any destination skill is unavailable or errors, the router degrades gracefully: return what's available, note what's missing, and let the existing ad-hoc behavior continue (test-design runs, agents self-discover test-writing). Router failure must not block the pipeline.

### Step 5 — Output Verification Plan

```markdown
## Verification Plan

**Domain(s):** code, ux
**Complexity:** Architecture=high, UX=medium, Ontology=low, Accessibility=low

### Destinations

| # | Skill | Depth | Reason |
|---|-------|-------|--------|
| 1 | test-writing | standard | Pure logic surfaces present |
| 2 | test-integration | full | DB surfaces: profiles (write), deals (read) |
| 3 | test-e2e | smoke | Critical path: reservation flow |
| 4 | ux-verification | standard | UI changes: new pricing display, UX=medium |

### Skipped

| Skill | Reason |
|-------|--------|
| test-e2e (full) | Architecture=high but no multi-page flow detected |
| architectural-soundness | Architecture=high — dispatch separately via code-review |

### Deferred

| Domain | Reason |
|--------|--------|
| content | Not applicable — no content changes |
| config | Not applicable — no config changes |
```

## Pipeline Handoff

**Invoked by:** your planning pipeline (after surface map is produced) and your code review step (coverage gap detection). Both are mandatory — pipeline-wired, not agent-discovered.

**Dispatches to:**
- `test-writing` — unit tests for pure logic
- `test-integration` — integration tests for DB/API surfaces
- `test-e2e` — e2e tests for critical paths
- `ux-verification` — UX checks for UI changes
- `content-verification` — content reviewer pipeline gate
- `config-validation` — config check script gate
- `research-verification` — adversarial review gate

**After dispatch:** Embed the verification plan in your plan document (planning time) or attach to PR review (merge time). The dispatched sub-skills produce the actual test files/checks.

See `repo-conventions.md` for repo-specific pipeline skill names and integration points.

## What Fails If You Skip

| Skip | Consequence |
|------|-------------|
| Domain detection | Features route to wrong verifier — e.g., content issue gets unit test suggestion |
| Complexity scaling | Over-testing simple features (wasted time) or under-testing complex features (escaped bugs) |
| Fallback on error | Router crash blocks the pipeline — no verification happens at all |
| Non-code domains | Content/config/research issues get code-test suggestions — nonsensical routing |
