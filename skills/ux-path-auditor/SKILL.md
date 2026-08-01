---
name: ux-path-auditor
description: Walks every step of every journey in a path-map.json via Playwright MCP, runs a 10-check audit checklist at each screen (desktop + mobile viewports), captures DOM/console/network evidence, deduplicates findings, and writes audit-report.json
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

# UX Path Auditor

> ⚠️ **This file is an index.** It contains ZERO workflow instructions.
> You have NOT loaded this skill yet. The actual workflow is in the files below.
> Proceeding without reading them means UX audit steps will be skipped.

## What you are missing

- [ ] `workflow/01-setup.md` — load path-map.json, initialize Playwright browser, determine audit scope
- [ ] `workflow/02-walk-journeys.md` — navigate every screen, capture evidence per step
- [ ] `workflow/03-desktop-checks.md` — 10-check audit checklist at each screen, 1280px viewport
- [ ] `workflow/04-mobile-checks.md` — same 10 checks at 375px viewport
- [ ] `workflow/05-output.md` — deduplicate findings, write audit-report.json

## What fails if you skip

| If you skip... | This breaks... |
|----------------|----------------|
| All sub-files | No UX audit produced. audit-report.json not written. QA pipeline stalls. |
| `workflow/01` | Path-map.json not loaded. Browser not initialized. Wrong or missing routes audited. |
| `workflow/02` | Screens not navigated. DOM/console/network evidence not captured. Audit has no data. |
| `workflow/03` | Desktop viewport checks skipped — 50% of audit missing. Layout issues on wide screens undetected. |
| `workflow/04` | Mobile checks skipped — mobile UX bugs ship. Most El Dato traffic is mobile. |
| `workflow/05` | Duplicate findings not merged. Report format broken. ux-problem-triage can't consume output. |

## Reference (read when directed by workflow files)

- `references/error-handling.md` — Playwright timeouts, navigation failures, selector recovery
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
