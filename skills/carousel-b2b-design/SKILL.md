---
disable-model-invocation: true
name: carousel-b2b-design
description: Renders carousel slides to PNG via Playwright. Invoked by carousel-b2b-strategy. Takes script + selected images → builds HTML/CSS → renders each slide → runs 12-item checklist → outputs PNGs + carousel-preview.html.
subjects.team: organisation-design-team
allowed-tools: read write edit bash
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

# Carousel B2B Design

Renders branded carousel slides as 1080×1080 PNGs using the El Dato brand design system. Handles both slide types: photo-hero (photo full-bleed + text overlay) and text-slide (text on solid purple).

## Input

Reads from `docs/carousels/<slug>/`:
- `script.yaml` — slide definitions with copy and creative direction
- `selected-images.yaml` — Cloudinary URLs for photo slides

## Output

Writes to `docs/carousels/<slug>/`:
- `carousel.html` — self-contained HTML with all slides
- `carousel-preview.html` — browser-viewable sequence
- `slides/` — numbered PNGs (`01_portada.png` ... `NN_cta.png`)
- Uploads to Cloudinary at `eldato/carousels/<slug>/`


## Design Principles

- **Feed-scale verification:** Text must be readable at ~375px Instagram feed width. Font sizes below 28px on a 1080px canvas become ~10px at feed size — illegible. Review slides at simulated feed size before approval (#4599).
- **Adaptive gradients:** Gradient coverage must be proportional to text density. Less text = lighter scrim. A slide with 2 words should not have the same gradient as a slide with 200 words (#4599).
- **155px horizontal safe margin: All text and key content must stay within 155px of left/right edges (xMin=155, xMax=925 in tokens.json `safeZones.universal`). This prevents profile grid cropping on Instagram (#4645). Per-type exceptions are documented in `tokens.json` `safeZones.perTypeExceptions` (`.glass`=80px, `.stat`=100px) — these are centered full-bleed accent slides whose content never reaches the crop zone, NOT violations.

- **Self-contained previews only:** Every carousel build must produce a base64-embedded HTML preview that works offline — no server dependency for design review (#4599).

- **Passthrough text mode is the default (#4599):** Text auto-splitting on periods (regex `/(?<=\.)\s+(?=[A-ZÁÉÍÓÚÑ])/`) is **legacy** — it creates unwanted visual breaks that fight AI design. The default mode splits ONLY on explicit double-newlines (`\n\n`). Period-splitting is only used when no double-newlines exist AND no CSS map is active (bare build_carousel.cjs without AI design). CSS-map mode enables full passthrough where the AI controls all layout.

- **Per-slide CSS scoping via `data-slide` attributes (#4599):** All slide divs carry `data-slide="N"` attributes for scoped CSS selectors. Injection MUST use `indexOf('>')`, never regex — regex-based injection corrupted HTML (#4581).

- **Image status validation (#4574, #4599):** Every image in `selected-images.yaml` carries a `status` field (`used` | `not_used` | `discarded`). The build script rejects `discarded` images with a hard error and skips `not_used` images with a warning. Only `used` images are rendered into slides.

## Process

### Step 0 — Pre-Flight: Art Director Gate 1 (Mandatory)

Before building HTML, run the pre-render quality gate. This gate **BLOCKS rendering** — do NOT proceed on failure.

**Token hygiene:** Verify the canonical build script is tokenized:

```bash
grep -q "var(--purple)" skills/carousel-b2b-design/scripts/build_carousel.cjs || {
  echo "❌ build_carousel.cjs is not tokenized. Use the canonical version."
  exit 1
}
```

**Safe zone check:** Verify text elements survive Instagram cropping:
- Byline Y ≥ 120px (above top UI overlay zone)
- Hook headlines Y: 150–400px (survives 1:1 crop in old profile grid)
- CTA elements above Y: 1100px

**Typography limits:** Verify heading ≥ 32px, body ≥ 20px, ≤ 2 font families, ≤ 5 font sizes per slide at 1080px square canvas.

On pass: proceed to Step 1. On failure: return specific issues to orchestrator. Do NOT render.

### Step 1 — Validate Inputs

Validate `script.yaml` and `selected-images.yaml` against schemas. Fail fast on mismatch.

**Image status gate (#4574, #4599):** Scan `selected-images.yaml` for image status. Any `discarded` image must block the build — these images failed quality checks or were user-rejected. `not_used` images emit a warning and are skipped during rendering. Only `used` images are rendered into slides.

### Step 2 — Build HTML (Canonical Script — Mandatory)

**⚠️ CRITICAL: Always use the canonical build script.** Never write ad-hoc HTML generation code for carousel rendering.

```bash
node skills/carousel-b2b-design/scripts/build_carousel.cjs \
  --script docs/carousels/<slug>/script.yaml \
  --images docs/carousels/<slug>/selected-images.yaml \
  --output docs/carousels/<slug>/carousel.html
```

This script generates self-contained HTML with:
- Base64-embedded fonts (Outfit, InterV) via @font-face
- CSS variables for all brand tokens (`var(--purple)`, `var(--yellow)`, etc.)
- 12 slide types: photo-hero, photo-top, cta, pilar, bento, comparison, stat, glass, cheatsheet, tutorial, quote, text-slide
- Instagram safe zones encoded in margins/padding (universal: X 35–1045, Y 135–945 for 1080×1080 square canvas (chosen over 4:5 because Instagram profile grid crops to 1:1, cutting off text below ~150px)
- "Desliza →" swipe indicator on photo slides
- Proper text shadows on overlay elements for readability
- Gradient overlays with transparent top zone (not full-bleed — images remain visible)

**If a new slide type is needed, add it to `build_carousel.cjs`.** Do not write one-off HTML scripts. The canonical build script is the single source of truth for carousel rendering.

### Step 3 — Render via Playwright

```bash
node scripts/render.cjs \
  --input docs/carousels/<slug>/carousel.html \
  --output docs/carousels/<slug>/slides/
```

Each `.slide` div rendered at 1080×1080 via `element.screenshot()`. `device_scale_factor=1`.


### Step 3.5 — Upload to Cloudinary + Write cloudinary-urls.yaml

After rendering, upload all slide PNGs and write the canonical URL file:

```bash
SLUG="<slug>"
DIR="docs/carousels/$SLUG"

# Upload each slide PNG via Cloudinary MCP (mcp__cloudinary__upload-asset)
# Write cloudinary-urls.yaml with all secure_url values
cat > "$DIR/cloudinary-urls.yaml" << YAMLEOF
slides:
YAMLEOF
for f in $(ls "$DIR/slides/"*.png | sort); do
  num=$(basename "$f" | grep -o "^[0-9]*")
  # Actual upload via MCP: mcp__cloudinary__upload-asset with public_id=eldato/carousels/$SLUG/s$num
  echo "  $num: https://res.cloudinary.com/djzwqixjt/image/upload/.../s$num.png" >> "$DIR/cloudinary-urls.yaml"
done
```

**This file is REQUIRED by Gate 2.** Without it, the carousel cannot be published.

**Image metadata (#5049):** When uploading to Cloudinary, tag each image with structured metadata:
```bash
# For each slide upload, set Cloudinary metadata via MCP:
# - context: "carousel=<slug>|slide=<N>|type=rendered-slide"
# - tags: "carousel,<slug>,rendered-slide"
# Source images (backgrounds) use type=background-image with additional:
# - context: "carousel=<slug>|slide=<N>|type=background-image|status=<used|unused|rejected>|reason=<rejection reason if rejected>"
```

This enables agent queries like "find all unused founder portraits" or "what background images were rejected for carousel X?"


### Step 4 — 12-Item Checklist

Run checklist with fix loop:

1. Each slide is 1080×1080
2. Max 5 typographic variations per slide
3. Gradients use single `%` (verify via grep)
4. Byline legible on photo slides (scrim present)
5. Text outside 150px safe zone at bottom (WARN only — carousel-designer has final say)
6. No face cropping on photo slides
7. Consistent background within slide series
8. Yellow emphasis only on keywords, not body text (carousel-designer catches misuse)

> **🚫 PUNCH AUTO-PROMOTION BUG (fixed):** The build script MUST NOT auto-promote the last paragraph to `.punch` (96px yellow Outfit). Yellow/punch is ONLY for explicitly declared `emphasis` words in script.yaml. When no `emphasis` is set, ALL paragraphs render as `.setup` (white body text). The last sentence is just the conclusion — not inherently a hero punch line.
9. Spanish accents render correctly (í, ó, é, ñ)
10. No visible AI artifacts in generated images
11. File order correct (01→NN)
12. Caption + hashtags included

Cycle reporting: "Cycle 1: 4 issues → Cycle 2: 1 → Clean ✓"

> **155px safe margin check (#4973):** After render, verify horizontal padding >= 155px:
> ```bash
> grep -q 'text-slide.*padding:.*15[5-9]px\|text-slide.*padding:.*1[6-9][0-9]px\|text-slide.*padding:.*2[0-9][0-9]px' docs/carousels/<slug>/carousel.html || echo "⚠️  text-slide padding < 155px (#4973)"
> grep -q 'photo-hero.*padding: 0 15[5-9]px\|photo-hero.*padding: 0 1[6-9][0-9]px' docs/carousels/<slug>/carousel.html || echo "⚠️  photo-hero padding < 155px (#4973)"
> ```
> P0 if any slide type uses < 155px horizontal padding. Block delivery.
>
> **QA overlap with carousel-designer:** Items 2 (typography count), 5 (safe zones), and 8 (yellow emphasis) are relaxed per #4429. The `carousel-designer` skill provides visual judgment for these concerns — rule-based gates only catch obviously broken things. Contrast (≥4.5:1) and font size minimums (heading ≥32px, body ≥20px) remain hard gates.
>
> **Linter pass (mandatory post-render):** After checklist passes, run the visual hierarchy linter:
> ```bash
> node skills/carousel-b2b-design/scripts/linter.mjs docs/carousels/<slug>/carousel.html
> ```
> This checks contrast ratios (≥4.5:1 WCAG AA), safe zone positions, typography scale, and raw hex values. (Yellow area check removed per #4429 — carousel-designer handles visual judgment.)
> Linter P0 failures (contrast, safe zones) block delivery. P1/P2 are warnings.

### Step 5 — Output

- Upload PNGs to Cloudinary
- Generate `carousel-preview.html` (all slides in sequence)
- Post Cloudinary URLs + caption + Download All zip to GitHub issue
- Set `quality_gate` in output

## Brand Design System

### Colors
```
--purple:      #5B3B8C   (main brand)
--purple-deep: #3F2766   (gradients)
--purple-d2:   #34204F   (dark base)
--yellow:      #F2C94C   (emphasis — stops the scroll)
--white:       #FFFFFF
--cream:       #EFE9DC   (secondary text on purple)
--muted:       #C9BBE0   (labels, bylines)
```

### Typography
- **Outfit** (headings): weight 700, tracking -.03em. NO italic (use skewX(-9deg) for emphasis).
- **Inter** (body): weight 400–600.

### Slide Types

**Photo-Hero (Type A):** Photo full-bleed. Gradient overlay from bottom. Scrim top 200px for byline. Text in bottom third. Byline: `[logo] eldato · [yellow dot] · Daniel Ospina · Fundador`

**Text-Slide (Type B):** Solid purple/deep background. Eyebrow in yellow uppercase. Body in white/cream. Emphasis in yellow. Lots of negative space.

### Subtitle & Body Text Formatting

**Newlines:** `\n` in subtitle/body fields is converted to `<br>` (line break). Use `\n\n` (double newline) for paragraph spacing between sections.

**Bullet points:** Use `• ` (Unicode bullet + space) at the start of a line for list items. Example:
```yaml
subtitle: 'La gente compra:
• Entretenimiento y trivia.
• Experiencia guiada.


El negocio debe enfocarse en:
• Narrativa fuerte.
• Temática clara.'
```

**Design principle:** Break dense text into scannable chunks. Whitespace between sections is free readability. Every `\n\n` costs zero pixels and earns attention.

**Inline yellow (optional tool):** Words wrapped in `emphasis:` render in yellow at body size via the `.obl` class. This is an available tool — no slide is required to use it. Yellow emphasis works best for:
- The key takeaway sentence on a text slide (one per slide max)
- A surprising number or stat worth highlighting
- A conceptual pivot ("But here's what nobody tells you...")

Use when it serves the narrative. Slides without yellow are fine.

**Emphasis words:** Explicitly declare `emphasis:` in slide copy for words that should render in yellow Outfit. Never auto-infer emphasis from paragraph position. Without explicit emphasis, all text renders as white body copy.

### Canvas Configuration

Default canvas: **1080×1080** (1:1 Instagram square). Configurable via `tokens.json`:
```json
{ "canvas": { "width": 1080, "height": 1080 } }
```

To change aspect ratio, update `tokens.json` and the corresponding CSS `.slide` dimensions in `build_carousel.cjs`. The build script reads `tok.canvas.width` and `tok.canvas.height` for safe zone calculations.

### Swipe Indicator Rule

**"Desliza →" only on slide 1 (portada).** Never on subsequent slides. The swipe indicator teaches the gesture once; repeating it is visual noise. This rule is enforced in `buildPhotoHero()` via `slide.number === 1` check.


### gradient (the "n3" approved)
```css
background: linear-gradient(180deg,
  rgba(52,32,79,0) 0%,
  rgba(52,32,79,0) 32%,
  rgba(52,32,79,.40) 40%,
  rgba(40,25,66,.72) 48%,
  rgba(26,18,40,.92) 55%,
  rgba(26,18,40,.96) 100%);
```

### Top Scrim (for byline visibility)
```css
background: linear-gradient(180deg, rgba(26,16,40,.5), rgba(26,16,40,0));
height: 200px;
```

## Reference

- [Brand Tokens](reference/brand_tokens.md)
- [Slide Types Spec](reference/slide_types.md)
- [Fonts](scripts/fonts/)
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
