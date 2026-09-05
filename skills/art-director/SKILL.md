---
name: art-director
description: Thin design system orchestrator for the carousel pipeline. Receives carousel content from carousel-b2b-strategy, enforces design rules, validates tokens and safe zones pre-render, and routes post-render output to QA skills. Not a design tool — routes and gates.
subjects.team: organisation-design-team
allowed-tools: read bash task
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

# Art Director — Design System Orchestrator

Thin orchestrator. Routes content through design rules, enforces token usage, gates quality before and after rendering. Does NOT design — it validates and routes.

**Scope:** Carousel pipeline only. Invoked by `carousel-b2b-strategy` after copy completes, before design renders. Also invoked post-render to route QA.

## Design Rules (The Spec)

These are the interface that `layout-composer` (#4291) and `visual-hierarchy-linter` (#4292) implement against.

### Tokens

Single source of truth: `skills/carousel-b2b-design/scripts/tokens.json`

<!-- Canonical values in tokens.json — update both if tokens change. Inline copy below is a convenience fallback. -->
```json
{
  "purple": "#5B3B8C",      // Main brand, Type B backgrounds
  "purpleDeep": "#3F2766",   // Gradients
  "purpleD2": "#34204F",     // Dark base
  "yellow": "#F2C94C",       // Emphasis only — NEVER body text
  "white": "#FFFFFF",        // Primary text on dark
  "cream": "#EFE9DC",        // Secondary text
  "muted": "#C9BBE0"         // Labels, bylines
}
```

### Typography

**Canonical source:** `tokens.json` → `typography` key.

| Font | Weight | Role |
|------|--------|------|
| Outfit | 700 | Headlines, punch lines |
| InterV | 400, 500, 600, 700 | Body, labels, bylines |

- Max 2 font families per carousel
- Max 3 distinct font sizes per slide
- Heading minimum: 32px (at 1080px canvas)
- Body minimum: 20px (at 1080px canvas)
- Headline-to-body ratio: ~1:2.5
- Emphasis (yellow) max: 10% of text elements per slide

### Color Usage

| Rule | Detail |
|------|--------|
| 60-30-10 | 60% dominant (purple/dark), 30% secondary (white/cream), 10% accent (yellow) |
| Yellow | Emphasis ONLY — never body text, never full paragraphs |
| White | Primary text on dark backgrounds |
| Cream | Secondary/supporting text |
| Muted | Labels, bylines, eyebrow text |
| Contrast | Text-on-background ≥ 4.5:1 (WCAG AA) |

### Safe Zones (1080×1080 square canvas)

**Canonical source:** `tokens.json` → `safeZones` key. Values below are the authoritative reference.
Also documented in `docs/teams/organisation-design-team/domains (S1)/capability/2026-06-21-instagram-format-research.md` (eldato repo) for context.

| Zone | X Range | Y Range | Reason |
|------|---------|---------|--------|
| Universal safe zone | 35–1045 | 135–945 | 1080×1080 square canvas (see #4500 for rationale) |
| Bottom UI overlay | — | 930–1080 | Like/comment/save bar |
| Top UI overlay | — | 0–120 | Handle + caption (variable) |
| Dots zone | — | 980–1060 | Slide counter dots |

**Copy placement rules:**
- Hook headline: Y=150–400, max 40 chars
- Body text: fully within universal safe zone
- CTA: Y=900–1100 (above bottom overlay)
- Swipe indicator: Y=1050–1180, right side (NOT bottom-right)

### Slide Type Selection

Based on content type (from brief.yaml):

| Content Type | Recommended Slide Types |
|-------------|------------------------|
| pillar (3-pilares) | `pilar` slides (1 per pillar) or `bento` grid |
| comparison (before/after) | `comparison` split-slide |
| tips (N tips) | `cheatsheet` numbered list |
| story (narrative) | `photo-top` sequence or `quote` testimonial |
| cta (closing) | `cta` with photo + gradient |
| stats (data-driven) | `stat` big-number card |
| tutorial (step-by-step) | `tutorial` numbered step |
| glass (elegant insight) | `glass` frosted card |

Valid slide types: `photo-hero`, `photo-top`, `text-slide`, `pilar`, `cta`, `bento`, `comparison`, `stat`, `glass`, `cheatsheet`, `tutorial`, `quote`

## Process

This skill is invoked at two distinct points in the carousel pipeline. Which steps run depends on the invocation mode:

- **Pre-render (Gate 1):** Invoked after copy generation, before design renders. Runs Steps 1–3.
- **Post-render (Gate 2):** Invoked after design renders output PNGs. Runs Steps 4–5.

### Pre-Render Process (Gate 1)

#### Step 1 — Receive Content

Invoked by `carousel-b2b-strategy` after copy generation. Inputs:
- `script.yaml` — slide-by-slide copy and type assignments

Validate structural and token-level rules. Image cross-reference runs at Gate 2 (post-images).

#### Step 2 — Pre-Render Gate (Gate 1)

Run before `carousel-b2b-design` renders. Checks:

##### Token Validation
```bash
# Scan build_carousel.cjs CSS for raw hex values.
# Allowed: var(--purple), var(--yellow), etc.
# Forbidden: #5B3B8C, #F2C94C, etc. (except in :root block definition)
node -e "
const fs = require('fs');
const css = fs.readFileSync('skills/carousel-b2b-design/scripts/build_carousel.cjs','utf8');

// Extract CSS from template literal: const CSS = (fontFace) => \`...CSS...\`;
const cssMatch = css.match(/const CSS\\s*=\\s*\\([^)]*\\)\\s*=>\\s*\`([\\s\\S]*?)\`;/);
const extractedCSS = cssMatch ? cssMatch[1] : '';
if (!extractedCSS.trim()) {
  console.log('Token gate: SKIPPED — no CSS template literal found in build_carousel.cjs');
  process.exit(0);
}

// Load tokens with fallback — tokens.json may not exist yet (created by #4291)
let tokens;
try {
  tokens = require('skills/carousel-b2b-design/scripts/tokens.json');
} catch (e) {
  tokens = { purple: '#5B3B8C', purpleDeep: '#3F2766', purpleD2: '#34204F',
             yellow: '#F2C94C', white: '#FFFFFF', cream: '#EFE9DC', muted: '#C9BBE0' };
}

const hexes = Object.values(tokens);
// Strip :root block before checking (hexes are allowed there)
const rootBlock = extractedCSS.match(/:root\\s*\\{[^}]*\\}/);
const cssToCheck = rootBlock ? extractedCSS.replace(rootBlock[0], '') : extractedCSS;

let failed = false;
for (const hex of hexes) {
  if (cssToCheck.includes(hex)) {
    console.log('RAW HEX FOUND: ' + hex + ' — replace with var(--*)');
    failed = true;
  }
}
if (failed) { process.exit(1); }
console.log('Token gate: PASS');
"
```

##### Safe Zone Validation
- Check hook headline Y position ≠ top 135px (cropped in 1:1 grid)
- Check CTA Y position ≠ bottom 250px (under UI overlay)
- Check swipe indicator not in bottom 150px

##### Typography Limits
- Count font families used: must be ≤ 2
- Count distinct font sizes per slide: must be ≤ 3
- Verify heading ≥ 32px, body ≥ 20px

If any check fails: return issues to carousel-b2b-strategy. Do NOT proceed to render.

#### Step 3 — Route to Design

On Gate 1 pass: route `script.yaml` to `carousel-b2b-design`.
The design skill builds HTML/CSS via the `carousel_designer` tool (Opus HTML primary path).
Image cross-reference validation runs at Gate 2 (post-render).

### Post-Render Process (Gate 2)

#### Step 4 — Post-Render Gate (Gate 2)

After render completes, run three QA checks:

**1. Linter (static CSS analysis):**
```bash
node skills/carousel-b2b-design/scripts/linter.mjs docs/carousels/<slug>/carousel.html
```
Checks: contrast ratios, safe zone positions, typography scale, emphasis color area, raw hex values.

**2. Visual regression (pixel diff):**
```bash
npx playwright test skills/carousel-b2b-design/scripts/visual-regression.spec.ts
```
Compares rendered PNGs against baseline templates. Catches CSS regressions and rendering drift.

**3. Design reviewer (AI visual critique):**
```
/carousel-designer image_paths=docs/carousels/<slug>/slides/*.png
```
Uses Claude vision (`read_image`) + DeepSeek with design tokens. Reviews: brand compliance, typography, contrast, safe zones, composition, rendering quality.

All three run in parallel via `task` sub-agents. Aggregate results into a single pass/fail report.

**Note:** #4292 is built (linter.mjs, 33KB). Gate 2 runs: linter.mjs + visual regression (#4296) + carousel-designer (#4401). The carousel-b2b-strategy skill dispatches these via task sub-agents (wiring: #4403).

#### Step 5 — Return

Return gate results to `carousel-b2b-strategy`. Pass/fail with specific issues. On pass, carousel proceeds to delivery.

## Quality Gates Summary

| Gate | When | What | Blocks Render? |
|------|------|------|---------------|
| Gate 1 | Pre-render | Token hygiene, safe zones, typography limits | YES |
| Gate 2 | Post-render | Linter (#4292) + visual regression (#4296) + carousel-designer (#4401) | NO (warns) |

## Reference

- Integration: wired into `carousel-b2b-strategy` at Steps 3.6 (Gate 1) and 6.5 (Gate 2) via #4403. Original skill scaffolding: #4304.
- Design tokens: `skills/carousel-b2b-design/scripts/tokens.json`
- Build script: `skills/carousel-b2b-design/scripts/build_carousel.cjs`
- Instagram format research: `docs/teams/organisation-design-team/domains (S1)/capability/2026-06-21-instagram-format-research.md` (eldato repo — fetch: `gh api repos/daniel-ospina/eldato/contents/<path> --jq .content | base64 -d`)
- Epic research: `docs/epics/2026-06-21-frontend-design-upgrade-research.md`
- Layout composer: #4291 (implements slide templates per these rules)
- Visual hierarchy linter (#4292): `skills/carousel-b2b-design/scripts/linter.mjs` (Gate 2 automated checks)
- Visual regression: #4296 (rendering consistency baselines)
- Design reviewer: #4401 (AI visual design critique, Gate 2)
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
