# Safe Zone Brief — Carousel Rendering

Authoritative safe-zone contract for the carousel render pipeline.
Consumed by `carousel-designer.ts` / `design-reviewer.ts` (falls back to
these defaults when the file is absent) and `carousel-b2b-design`.

## Canvas

- **Canvas width:** 1080px (fixed, 16:9)
- **Safe margins:** **155px** on all sides
  - `xMin = 155`, `xMax = 925`
  - `yMin = 155`, `yMax = 625`
- Text and critical visual content stay **within these bounds**.
  Full-bleed backgrounds may extend to the canvas edge.

## Typography limits

- Headline: ≤ 6 words (emphasis ≤ 6 words total)
- Body: readable at slide scale; no text below ~24px at 1080px canvas
- Contrast: WCAG AA minimum for text over image backgrounds

## Token source of truth

- `skills/carousel-b2b-design/scripts/tokens.json` — brand tokens,
  155px horizontal safe margin, canvas dimensions, typography limits
- `skills/carousel-b2b-design/reference/brand_tokens.md` — brand color/type
- `skills/carousel-b2b-design/reference/slide_types.md` — per-slide-type
  required fields and layout constraints

## Verification

- Render → PNG per slide (Playwright) → visual regression against
  `reference/visual-regression-ci.md` spec
- Any text outside xMin/xMax or yMin/yMax = layout violation (P0)
