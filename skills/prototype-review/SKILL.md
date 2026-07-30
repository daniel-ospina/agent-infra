---
name: prototype-review
description: Automated review-fix cycle for El Dato HTML prototypes. Dispatches 3 parallel NVIDIA reviewers (ux-coherence, accessibility, user-journey-logic) per cycle, merges issues, runs fixer, and loops until clean or hard cap. Invoked after ui_prototype generates an HTML file. Can also be invoked manually on any prototype HTML file.
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

> **Sync note:** Local copy at `.agents/skills/prototype-review/SKILL.md`. Repo copy at `operations/skills/prototype-review/SKILL.md`. Keep in sync.

# Prototype Review

Automated review-fix cycle for El Dato HTML prototypes. Ensures prototype quality (UX coherence, accessibility, user journey logic) before handoff.

## When to Use

- After `ui_prototype` generates an HTML prototype file (automatic invocation)
- After `issue-scoping` implements a React fork prototype (automatic, `--mode=react-diff`)
- Manually on any prototype: `prototype-review docs/prototypes/YYYY-MM-DD-<feature>.html [--spec "what this demonstrates"]`
- Manually on a React diff: `prototype-review --mode=react-diff --diff=<path> --base=<branch> [--spec "what this demonstrates"]`

## Arguments

`prototype-review <html-path> [--spec <description>] [--ux-guidelines <extra-guidelines>] [--mode=html|react-diff] [--diff=<path>] [--base=<branch>]`

- `html-path`: path to the prototype HTML file (required for `--mode=html`, ignored for `--mode=react-diff`)
- `--spec`: description of what the prototype demonstrates (recommended; defaults to filename)
- `--ux-guidelines`: optional extra UX guidelines beyond El Dato defaults
- `--mode`: `html` (default) or `react-diff`
- `--diff`: path to git diff file (required for `--mode=react-diff`)
- `--base`: base branch for diff (default: `main`, for `--mode=react-diff`)

## Mode Detection

If `--mode` is not specified, auto-detect:
- If `<html-path>` ends in `.html` → `--mode=html`
- If `--diff` is provided → `--mode=react-diff`
- If `<html-path>` ends in `.diff` → `--mode=react-diff`

## React Diff Mode (`--mode=react-diff`)

When reviewing a React component fork (prototype IS the implementation), the review shifts from visual HTML inspection to code structure analysis. The goal: verify the diff is minimal, correct, and pattern-compliant.

### Review Cycle (React Diff)

```
┌─────────────────────────────────────────────────────┐
│ Cycle N (of max 3)                                  │
│                                                     │
│  Phase 1: Code Review (task sub-agent)              │
│  ┌──────────────────────────────────────────────┐   │
│  │ React Diff Reviewer                          │   │
│  │  - Component reuse (existing over new)       │   │
│  │  - Pattern compliance (matches codebase)     │   │
│  │  - Diff minimality (only what issue needs)   │   │
│  │  - Mock data correctness (all states)        │   │
│  │  - Anti-pattern check (no divergence)        │   │
│  └──────────────────────┬───────────────────────┘   │
│                         ▼                            │
│  Phase 2: Fix (apply issues to React code)           │
│                         │                            │
│  Phase 3: Cycle Status                               │
│       ┌─────────────────┼─────────────────┐          │
│       ▼                 ▼                 ▼          │
│    [clean]          [issues]          [capped]       │
│       │                 │                 │          │
│   CONVERGENCE       NEXT CYCLE      CAPPED EXIT      │
└─────────────────────────────────────────────────────┘
```

### Phase 1 — Dispatch React Diff Reviewer

Dispatch a Pi `task` sub-agent:

```
You are reviewing a React component diff for a prototype fork. The changes are already
implemented in React — your job is to verify the diff is correct and minimal.

DIFF FILE: <path to diff>
BASE BRANCH: main
ISSUE: <title + body>
AFFECTED FILES: <list>
PROJECT ROOT: <absolute path>

Read the diff file. For each changed file, read the full file to understand the context.
Then evaluate against these dimensions:

1. COMPONENT REUSE:
   - Does the diff introduce new components when existing ones would work?
   - Check docs/teams/eldato-app-team/ux/component_catalog.md for available components
   - Does it use raw divs/buttons where shadcn/ui components exist?
   - Example: "<button> → should be <Button variant> from components/ui/"

2. PATTERN COMPLIANCE:
   - Does the new code match existing patterns in the same file?
   - Same data-fetching patterns? Same state management? Same error handling?
   - Same design tokens (bg-card, text-primary, not hardcoded colors)?
   - Same import patterns?

3. DIFF MINIMALITY:
   - Does the diff ONLY add what the issue requires?
   - Are there unrelated refactors, reformattings, or "improvements"?
   - Are there unnecessary imports added?
   - Flag any change not directly related to the issue.

4. MOCK DATA CORRECTNESS:
   - Are mock data objects clearly marked with `// ponytail: mock data`?
   - Do mocks exercise ALL states (loading, empty, error, success, edge cases)?
   - Are there any real API calls left unmocked that would fail?

5. ANTI-PATTERNS:
   - No hardcoded colors (use design tokens)
   - No invented component patterns (copy from adjacent code)
   - No amber/yellow Tailwind classes
   - No rounded-xl on buttons, no shadow-md on cards

For each issue, return:
ISSUE:
  severity: P0|P1|P2
  dimension: component-reuse|pattern-compliance|diff-minimality|mock-data|anti-pattern
  location: [file:line]
  description: <what's wrong>
  suggestion: <how to fix>

P0 = structural problem (wrong component, missing state, breaks existing patterns)
P1 = important gap (missing error state, unnecessary import)
P2 = improvement (could use existing component, minor style issue)

If no issues: NO ISSUES FOUND
```

### Phase 2 — Fix

If issues found:
1. Read each ISSUE block
2. Edit the affected React file(s) to fix the issue
3. Re-run the diff: `git diff main -- <affected files> > <diff path>`
4. Next cycle reviews the updated diff

### Phase 3 — Loop Control

| Condition | Action |
|-----------|--------|
| `NO ISSUES FOUND` | **Convergence** — diff is clean |
| Issues found AND `cycle < 3` | **Next cycle** |
| Issues found AND `cycle == 3` | **Capped exit** |
| Sub-agent unavailable | **Graceful exit** — surface partial results |

**React diff mode uses max 3 cycles (not 5).** Code review converges faster than visual review — if 3 cycles don't clear it, the issue needs human attention.

### Changelog

Same format as HTML mode. Track ISSUE blocks resolved per cycle.

---

## HTML Mode (`--mode=html`, default)

The original HTML prototype review flow. Unchanged from previous version.

## Phase 0 — Config Read

Read `operations/ai-workflow-tools/config.json`. Extract:

- `prototype_review.max_cycles` → `MAX_CYCLES` (default 5)
- `prototype_review.parallel_reviewers` → `PARALLEL_REVIEWERS` (default 3)

If the config file is missing or malformed, use the defaults above.

**Concurrency control:** This skill dispatches reviewers via the MCP `prototype_review_cycle` wrapper, which handles parallelism internally. When refactoring to use `subagent({ tasks: [...] })` directly, cap at 8 parallel agents, stagger 200ms, and apply exponential retry backoff (1s, 2s, 4s) + jitter ±200ms. See `parallel-orchestrator` reference skill for the full pattern.

## Mode Routing

At invocation, check the detected mode:

```
if MODE == "react-diff":
    → Jump to "React Diff Mode" section above
    → Use 3-cycle max, code-review dimensions
    → Skip MCP prototype_review_cycle (HTML-only tool)

if MODE == "html":
    → Continue below (standard HTML review)
    → Use 5-cycle max, visual review dimensions
    → Use MCP prototype_review_cycle
```

---

## Review Cycle (HTML Mode)

```
┌─────────────────────────────────────────────────────┐
│ Cycle N (of max 5)                                  │
│                                                     │
│  Phase 1: Review (3 parallel NVIDIA reviewers)      │
│  ┌────────────┐ ┌─────────────┐ ┌────────────────┐  │
│  │ UX-Coherence│ │Accessibility│ │User-Journey-   │  │
│  │  Reviewer   │ │  Reviewer   │ │Logic Reviewer  │  │
│  └──────┬──────┘ └──────┬──────┘ └──────┬─────────┘  │
│         │               │               │             │
│  Phase 2: Merge & Dedup                              │
│         └───────────────┼───────────────┘             │
│                         ▼                            │
│  Phase 3: Fix (1 NVIDIA fixer)                       │
│                         │                            │
│  Phase 4: Cycle Status                               │
│       ┌─────────────────┼─────────────────┐          │
│       ▼                 ▼                 ▼          │
│    [clean]          [issues]          [capped]       │
│       │                 │                 │          │
│   CONVERGENCE       NEXT CYCLE      CAPPED EXIT      │
└─────────────────────────────────────────────────────┘
```

## Phase 1 — MCP Tool Dispatch

Per cycle, invoke: `mcp__ai-workflow-tools__prototype_review_cycle` with:

```json
{
  "html_path": "<absolute path to prototype HTML>",
  "spec": "<what this prototype demonstrates>",
  "ux_guidelines": "<optional extra guidelines>",
  "cycle": <current cycle number>,
  "project_root": "<repo root>"
}
```

The tool handles:
- Dispatching 3 parallel NVIDIA reviewers with stagger jitter
- Merging + deduplicating ISSUE blocks (same location + ≥70% similar description → keep higher severity)
- Dispatching 1 NVIDIA fixer if issues found (rewriting HTML in place)
- Graceful handling of reviewer/fixer unavailability

## Phase 2 — Parse Tool Output

Parse the first line of the tool response:

- `STATUS: unavailable` → surface partial result + warning, exit loop immediately
- `STATUS: capped` → same as unavailable (treat as graceful failure)

Otherwise, parse:
- `FILES_MODIFIED:` — path where HTML was rewritten (or `(none)` if no issues or fixer failed)
- `CYCLE:` — cycle number (sanity check)
- `ISSUES_FOUND: N` — count of issues after dedup
- Any `⚠️` warning lines — surface to user verbatim
- ISSUE blocks after `---` separator

## Phase 3 — Loop Control

| Condition | Action |
|-----------|--------|
| `ISSUES_FOUND: 0` | **Convergence** — prototype is clean |
| `ISSUES_FOUND: N > 0` AND `cycle < MAX_CYCLES` | **Next cycle** — tool already fixed HTML; next call reviews the fixed version |
| `ISSUES_FOUND: N > 0` AND `cycle == MAX_CYCLES` | **Capped exit** — return remaining issues to user |
| `STATUS: unavailable` or `STATUS: capped` | **Graceful exit** — return partial results + warning |

**Progress report (non-blocking, after each cycle):**
```
Prototype review cycle [N]/[MAX]: [count] issues found.
[If continuing: "Starting cycle N+1..."]
[If clean: "Prototype is clean after N cycle(s)."]
[If capped: "Reached max cycles — [count] issues remain."]
```

**Auto-Continue After Clean Review:**

When convergence is reached (0 issues, clean):
1. **Open the prototype in the browser:** `open <html-path>`
2. **Output a brief summary** with assumptions and key flows
3. **CONTINUE IMMEDIATELY** to the next phase (e.g., journey table formalization in epic-plan). Do NOT pause for "proceed" or "approve this prototype." The review cycle IS the quality gate.

When capped or graceful exit:
- If issues are fixable → fix them, re-run review
- If issues require human UX decision → pause with structured question + research
- If MCP tool unavailable → skip prototype gate, proceed with narrative validation

## Changelog Tracking

Maintain a changelog across cycles:

```
| Cycle | Issues Found | Issues Resolved |
|-------|-------------|-----------------|
| 1     | 4           | 4 (fixer ran)   |
| 2     | 1           | 1 (fixer ran)   |
| 3     | 0           | — (clean)       |
```

Track which ISSUE blocks appeared in cycle N and were absent in cycle N+1 (resolved by fixer).

## Exit & Output

### Convergence (clean)

```markdown
## Prototype Review — Clean

**Prototype:** `<html-path>`
**Cycles:** N
**Status:** All reviewers passed — no issues remaining.

### Changelog
| Cycle | Issues Found | Resolved |
|-------|-------------|----------|
| 1     | 3           | 3        |
| 2     | 0           | —        |

Prototype is ready for handoff.
```

### Capped Exit (issues remain)

```markdown
## Prototype Review — Requires Human Input

**Status:** Capped after [N] cycles
**Remaining issues:** [count] (P0×_ P1×_ P2×_)

### Unresolved Issues

[full list of remaining ISSUE blocks]

**Prototype path:** `<html-path>`

Please review these issues manually and either:
- Fix them and re-run `prototype-review`
- Approve the prototype as-is (issues noted but won't block)
```

### Graceful Exit (NVIDIA unavailable)

```markdown
## Prototype Review — Partial Results

**Status:** NVIDIA unavailable at cycle [N]
**Warning:** Results from this cycle may be incomplete.

[any ISSUE blocks returned before failure]

**Prototype path:** `<html-path>`
```

## Announce

At invocation, announce:
"Running prototype-review on `[html-path]`. Pi uses DeepSeek v4 Pro by default. Up to [MAX_CYCLES] review cycles."
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
