---
name: google-slides
description: "Creates branded Google Slides presentations for El Dato. 3-phase pipeline: Brief → Generate → Review. Uses Composio Google Slides integration for markdown→Slides conversion with El Dato brand tokens. Supports optional image generation for storyboarding. Vision-model design critique via read_image (Opus-class) for visual quality."
subjects.team: organisation-design-team
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

> **Canonical:** `agent-infra/skills/google-slides/SKILL.md` — git-tracked source of truth. Pi reads via `~/.pi/agent/skills`; consumers hard-link into `operations/skills`. Paths below are agent-infra-relative (`skills/...`); in consumer repos resolve via `$SKILLS_PREFIX` (default `operations/skills/`).

# Google Slides Presentation Skill

Creates branded Google Slides presentations for El Dato — pitch decks, strategy docs, internal reports, partner presentations. Automates slide generation from structured input with brand token application, typography enforcement, and visual design critique.

**Scope:** El Dato branded presentations. Spanish-primary (English supported for partner/internal decks). B2B and internal use.

## When to Use

- "Create a presentation about..."
- "Make a deck for..."
- "I need slides for..."
- `/skill:google-slides`

## Pipeline Overview

3 phases. No status.yaml, no state tracking — single-session by default.

```
Brief (5 questions) → Generate (markdown → Composio) → Review (programmatic + vision-model)
                                                              ↑_______________↓
                                                              (iterate up to 3x)
```

### Phase 1 — Brief

Ask 5 questions. No more, no less. All have defaults — user can accept with "yes" or customize.

| # | Question | Default |
|---|----------|---------|
| 1 | **Title?** (presentation title) | Required — no default |
| 2 | **Audience?** (internal / partner / client / public) | internal |
| 3 | **Tone?** (formal / professional / casual) | professional |
| 4 | **Slide count?** (approximate) | 8 |
| 5 | **Images?** (storyboarding — generate AI images for key slides?) | no |

After brief, confirm: "Creating [audience] deck '[title]' — [N] slides, [tone] tone, [with/without] images. Proceed?"

### Phase 2 — Generate

Two parallel tracks:

**Track A — Content (always):**
1. Build structured content from brief answers
2. Apply brand preamble (colors, fonts, typography) from `brand-adapter.md`
3. Assemble markdown with slide-type templates from `templates/`
4. Create presentation via `GOOGLESLIDES_CREATE_SLIDES_MARKDOWN`
5. Apply brand refinements via `GOOGLESLIDES_PRESENTATIONS_BATCH_UPDATE`

**Track B — Images (only if Phase 1 Question 5 = yes):**
1. Identify which slides need images (storyboard selection)
2. Generate prompts per slide — based on slide content and tone
3. Generate images via OpenRouter API (single-pass, no character sheets)
4. Upload to Cloudinary → get public URLs
5. Embed images in markdown before Track A Step 3

**Brand application via BATCH_UPDATE:**
After markdown creation, apply brand colors:
- Shape backgrounds: purple (#5B3B8C) for headers, cream (#EFE9DC) for body
- Text colors: white (#FFFFFF) on purple, purple (#5B3B8C) on cream
- Accent elements: yellow (#F2C94C)
- Font family: Outfit for headings, Inter for body
- Font sizes: min 20px body, 32px+ headings

### Phase 3 — Review

<HARD-GATE id="universal-review">
**Review Loop Mandate:** EVERY presentation — regardless of slide count, audience, or complexity — must go through the full two-pass review loop. No presentation is exempt.

The agent MUST NOT present slides to the user until the exit condition is met. After Phase 2 (Generate) completes, proceed immediately to Phase 3 — this is not optional, not skippable, and not deferrable.

Claiming the presentation is "simple" or "good enough" is not a valid reason to skip review. The exit condition exists to enforce quality — skip it and you ship unbranded, un-reviewed slides.

**Review includes:**
1. Programmatic pass on ALL slides (brand tokens, typography, safe zones, content completeness)
2. Vision-model design critique on ALL slides (visual balance, color harmony, hierarchy, white space)
3. Fix -> re-render -> re-critique loop until clean (convergence-gated; safety cap: 10 cycles)
</HARD-GATE>

**Pass 1 — Programmatic (no vision needed):**
1. Fetch thumbnails via `GOOGLESLIDES_GET_PAGE_THUMBNAIL2` for EVERY slide (LARGE=1600px PNG)
2. Check brand compliance (colors, fonts, typography, safe zones) against tokens.json
3. Check content completeness (slide count, empty slides, broken layouts)
4. Fix ALL programmatic issues via `GOOGLESLIDES_PRESENTATIONS_BATCH_UPDATE` before proceeding to Pass 2

**Pass 2 — Vision-model design critique (Opus-class, sees thumbnails):**
1. Feed ALL slide thumbnails to vision model via `read_image` with `purpose="design-critique"`
2. Model critiques: visual balance, text-image interplay, color harmony, information hierarchy, white space
3. Map EVERY issue to a BATCH_UPDATE operation or markdown regeneration
4. Fix ALL P0 and P1 issues -> re-render thumbnails -> re-critique
5. Safety cap: 10 cycles (convergence-gated). On safety cap, document remaining issues and proceed.

**Exit condition:** Pass 1 clean on ALL slides AND Pass 2 returns "NO ISSUES FOUND" from vision model. Do NOT present slides to user until this is true.

## Composio Tool Usage

All tools use the `mcp__composio__COMPOSIO_MULTI_EXECUTE_TOOL` wrapper. Connection account: `aprestointernal@gmail.com`.

### GOOGLESLIDES_CREATE_SLIDES_MARKDOWN

Creates a presentation from markdown. Themes: default, corporate_blue, modern_dark, professional_gray, creative_purple, warm_orange, forest_green, minimal_beige.

Use `creative_purple` as baseline (closest to El Dato purple), refine with BATCH_UPDATE.

```json
{
  "tool_slug": "GOOGLESLIDES_CREATE_SLIDES_MARKDOWN",
  "arguments": {
    "title": "Presentation Title",
    "markdown_text": "Theme: creative_purple\n\n# Slide Title\nContent here\n\n---\n\n# Next Slide\nMore content"
  }
}
```

**Slide types in markdown:**
- Title: `# Title\nSubtitle`
- Bullets: `- item` or `* item`
- Tables: markdown tables
- Quotes: `> quote text`
- Images: `![alt](public_url)`
- Two-column: `|||` separator
- Plain text: paragraphs

### GOOGLESLIDES_PRESENTATIONS_BATCH_UPDATE

Applies refinements after creation. Key operations: replaceAllText, updateTextStyle, updateShapeProperties.

```json
{
  "tool_slug": "GOOGLESLIDES_PRESENTATIONS_BATCH_UPDATE",
  "arguments": {
    "presentationId": "<id from create>",
    "requests": [
      {"replaceAllText": {"containsText": {"text": "old", "matchCase": false}, "replaceText": "new"}},
      {"updateTextStyle": {}}
    ]
  }
}
```

### GOOGLESLIDES_GET_PAGE_THUMBNAIL2

Generates slide thumbnails for review. Use LARGE (1600px) for vision-model critique.

```json
{
  "tool_slug": "GOOGLESLIDES_GET_PAGE_THUMBNAIL2",
  "arguments": {
    "presentationId": "<id>",
    "pageObjectId": "<slide_page_id>",
    "thumbnailProperties.mimeType": "PNG",
    "thumbnailProperties.thumbnailSize": "LARGE"
  }
}
```

## Brand Tokens

From `skills/carousel-b2b-design/scripts/tokens.json` (canonical agent-infra path; consumer repos resolve via `$SKILLS_PREFIX`):

| Token | Value | Usage |
|-------|-------|-------|
| Purple | `#5B3B8C` | Headers, accents, logos |
| Deep Purple | `#3F2766` | Footer, dark backgrounds |
| Yellow | `#F2C94C` | Highlights, CTAs, accent (<10% of slide) |
| Cream | `#EFE9DC` | Body backgrounds, light sections |
| Muted | `#C9BBE0` | Secondary elements, borders |
| White | `#FFFFFF` | Text on dark backgrounds |

**Typography:**
- Headings: Outfit (Google Fonts, 9 weights)
- Body: Inter v3 (Google Fonts, built into Slides)
- Min body: 20px
- Min heading: 32px
- Max 2 font families per deck
- Max 3 font sizes per slide

**Safe zones (16:9):**
- Margins: 80px all sides
- Title area: top 20%
- Content area: middle 60%
- Footer/CTA: bottom 20%

## Optional Image Generation

When Phase 1 Question 5 = yes:

1. **Storyboard selection:** Which slides get images? (title slide, section dividers, concept slides)
2. **Prompt generation:** One prompt per image slide. Format: "Professional presentation slide image for [context]. [subject]. El Dato brand style — purple and gold accents. Clean, modern, corporate. No text on image."
3. **Image generation:** OpenRouter API. Single-pass — no iterative refinement.
4. **Cloudinary upload:** `upload-asset` with `resource_type: "image"`, folder `eldato-slides/`. Get public URL.
5. **Markdown embed:** `![slide description](cloudinary_public_url)` in markdown before Composio generation.

**Image guidelines:**
- No text overlays on images (text in slide layout, not image)
- Abstract/conceptual preferred over literal
- Consistent style across all images in a deck
- Images must be <50MB PNG/JPEG

## Vision-Model Review Protocol

After programmatic checks pass, dispatch a task sub-agent with vision capability:

```
You are a design reviewer. Examine these slide thumbnails for visual quality.
Check: visual balance, text-image interplay, color harmony, information hierarchy, white space, brand consistency.

For each issue found, specify:
- Slide number
- Problem description
- Suggested fix (BATCH_UPDATE operation or content change)
- Priority (P0=must fix, P1=should fix, P2=nice to have)

Be specific about what to change. Format as ISSUE blocks.
```

Use `read_image` with `purpose="design-critique"` and Opus-class model.

**Loop mechanics:**
1. Apply fixes from vision model critique
2. Re-render affected slide thumbnails
3. Re-dispatch reviewer with updated thumbnails
4. Safety cap: 10 cycles (convergence-gated). On safety cap, document remaining P0/P1 issues.

## Pre-Flight Checks

```bash
# 1. Brand tokens must exist — warn-and-continue: SKILL.md carries the full
#    token table inline, so a missing file degrades to inline tokens, not a hard stop.
TOKENS_JSON="${SKILLS_PREFIX:-operations/skills/}carousel-b2b-design/scripts/tokens.json"
# Fall back to agent-infra canonical layout
[ -f "$TOKENS_JSON" ] || TOKENS_JSON="skills/carousel-b2b-design/scripts/tokens.json"
if [ ! -f "$TOKENS_JSON" ]; then
  echo "⚠️ tokens.json not found (checked $TOKENS_JSON) — continuing with inline brand tokens from SKILL.md"
fi

# 2. Composio Google Slides connection verified active
# Account: aprestointernal@gmail.com (active since 2026-06-27)
```

## File Structure

```
skills/google-slides/            # Canonical in agent-infra; consumers hard-link this dir
├── SKILL.md              # This file
├── brand-adapter.md      # Brand token → Google Slides mapping
└── templates/            # Slide-type markdown templates
    ├── title.md
    ├── bullets.md
    ├── table.md
    ├── quote.md
    ├── image.md
    └── two-column.md
```

## Dependencies

- **Composio:** Google Slides (active, aprestointernal@gmail.com)
- **Brand tokens:** `skills/carousel-b2b-design/scripts/tokens.json` (canonical; consumer repos resolve via `$SKILLS_PREFIX`)
- **Cloudinary:** Image uploads (optional, storyboarding only)
- **OpenRouter:** Image generation (optional, storyboarding only)
- **Vision model:** Opus-class via `read_image` (design critique)

## V2 Roadmap

- Path B: HTML → .pptx → Google Slides import for polished output
- status.yaml: multi-session state tracking with resume
- Style discovery: 3 visual previews before generation
- Automated gates: spelling, slide count, brand compliance
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
