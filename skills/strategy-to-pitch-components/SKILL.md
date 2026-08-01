---
name: strategy-to-pitch-components
description: Bridge strategy analysis into hypothesis-driven, culturally-grounded pitch components for the WhatsApp outreach agent — produces TypeScript constants with confidence tracking, manifest, sales research brief. Abundant human gates for tight alignment.
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

# Strategy to Pitch Components

> ⚠️ **This file is an index.** It contains ZERO workflow instructions.
> You have NOT loaded this skill yet. The actual workflow is in the files below.

## What you are missing

- [ ] `workflow/01-mode-and-setup.md` — mode detection, confidence tracking initialization
- [ ] `workflow/02-phase-1-sales-research.md` — Sales Research Brief generation
- [ ] `workflow/03-phase-2-generation.md` — pitch component generation from strategy + research
- [ ] `workflow/04-phase-3-4-adversarial.md` — adversarial review + refinement cycles
- [ ] `workflow/05-phase-5-6-output.md` — manifest creation, final output, human gates

## What fails if you skip

| If you skip... | This breaks... |
|----------------|----------------|
| All sub-files | No pitch components produced. WhatsApp outreach agent has no messaging. |
| `workflow/01` | Wrong mode selected. Confidence tracking not initialized. Components lack confidence scores. |
| `workflow/02` | Sales research not done. Pitch components generated blind — no prospect context. |
| `workflow/03` | No pitch components generated. Pipeline produces nothing. |
| `workflow/04` | Unreviewed components ship. Hallucinated claims in outreach messages. No adversarial validation. |
| `workflow/05` | Manifest not created. Human gates skipped. Components not versioned or trackable. |

## Reference (read when directed)

- `references/component-schema.md` — TypeScript interface definitions for pitch components
- `references/protocols.md` — review protocol definitions, confidence tracking rules
- `references/incremental-mode.md` — incremental mode behavior vs full build
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
