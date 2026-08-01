# Slide Types — CSS Spec

## Dimensions
- **Format:** 1:1 square
- **Size:** 1080 × 1080 px
- **Safe zone:** Bottom 150px — never place text here (Instagram UI overlay in boosted posts)

## Type A — Photo Full-Bleed

Used for: Portada, Historia personal, Cierre/CTA

### Structure
```
┌──────────────────────────────┐
│ [Byline: logo eldato · name] │ ← top 70px, left 80px, z-index 3
│                              │
│                              │
│         [PHOTO]              │ ← position: absolute, inset: 0, z-index 0
│                              │    background-size: cover
│                              │
│  ┌────────────────────────┐  │
│  │ Gradient overlay       │  │ ← z-index 1
│  │ (rises from bottom)    │  │
│  │                        │  │
│  │ [HEADLINE — Outfit]    │  │ ← z-index 2
│  │ [subtitle — Inter]     │  │    padding: 0 80px 158px
│  └────────────────────────┘  │
│                    [Desliza →]│ ← right 80px, bottom 60px
└──────────────────────────────┘
```

### CSS Classes
- `.photo-hero` — Portada (gradient from top, full coverage)
- `.photo-top` — Historia (gradient from bottom 24%, lighter overlay)
- `.cta` — CTA slide (angled gradient from left, button)

### Gradient (n3 approved)
```css
background: linear-gradient(180deg,
  rgba(52,32,79,0) 0%,
  rgba(52,32,79,0) 32%,
  rgba(52,32,79,.40) 40%,
  rgba(40,25,66,.72) 48%,
  rgba(26,18,40,.92) 55%,
  rgba(26,18,40,.96) 100%);
```

### Top Scrim (byline visibility)
```css
background: linear-gradient(180deg, rgba(26,16,40,.5), rgba(26,16,40,0));
height: 200px;
position: absolute;
top: 0;
z-index: 1;
```

### Typography Limits
Max 3 variations per slide. Example:
1. Headline (Outfit, large, white)
2. Subtitle (Inter, medium, cream)
3. Emphasis (Outfit/Inter, same size, yellow) ← counts as variation 3

Byline and eyebrow are system elements, not counted in the 3-type limit.

## Type B — Text on Purple

Used for: Argumento, Framework, Pilares, Veredicto

### Structure
```
┌──────────────────────────────┐
│                              │
│     [EYEBROW — yellow]       │ ← Inter 700, uppercase, tracking .2em
│                              │
│     [HEADLINE — Outfit]      │ ← 90px, white, letter-spacing -.035em
│                              │
│     [Body text — Inter]      │ ← 46px, white/cream, line-height 1.32
│                              │
│     [Emphasis — yellow]      │ ← 46px, yellow, weight 600
│                              │
│          (negative space)     │
│                              │
│    ⚠️ 150px safe zone ⚠️     │ ← no text below this line
└──────────────────────────────┘
```

### CSS Classes
- `.text-slide` — Base (96px top padding, 150px bottom safe zone)
- `.bg-purple` — `#5B3B8C` background (main)
- `.bg-deep` — `#34204F` background (veredicto, conclusions)

### Pilar Variant
- Yellow numbered badge (94×94, rounded 24px)
- Pilar name in yellow uppercase Inter
- Headline in Outfit 90px
- Body text + emphasis line

## Background Consistency Rule

Slides in a series (Pilar 1/2/3, Tip 1/2/3/4/5) MUST share the same background color. The number badge signals progression — changing the background adds visual noise without encoding meaning. Only change background when marking a new section (e.g., last pilar → veredicto).

## Checklist

See SKILL.md §12-Item Checklist for the canonical list. Summary below for reference:

1. ✅ Each slide is 1080×1080
2. ✅ Max 3 typographic variations per slide
3. ✅ Gradients use single `%` (verify with grep — no `%%`)
3a. ✅ Photo-hero gradient starts at 32%, covers text zone at 92-96% opacity
3b. ✅ Headline + subtitle have text-shadow on photo slides for legibility
4. ✅ Byline legible on photo slides (top scrim present)
5. ✅ Text outside 150px safe zone at bottom
6. ✅ No face cropping on photo slides
7. ✅ Consistent background within slide series
8. ✅ Yellow emphasis only on keywords, not body text
9. ✅ Spanish accents render correctly (í, ó, é, ñ)
10. ✅ No visible AI artifacts in generated images
11. ✅ File order correct (01→NN)
12. ✅ Caption + hashtags included

## Gradient Rule (System — not per-image tuning)

The gradient on photo-hero slides follows a fixed rule, not per-image tuning:

```
0-32%:  zero gradient (preserve photo, face zone)
32-48%: ramp band (tight, fast transition)
48-100%: 92-96% opacity (text legibility zone)

Headline: text-shadow 0 4px 20px rgba(0,0,0,0.5) for extra legibility on any photo
Subtitle: text-shadow 0 2px 12px rgba(0,0,0,0.5)
```

**Why this works across all photos:** The `.content` div is `margin-top: auto` (bottom-aligned), so text always lives in the bottom ~40% of the slide regardless of photo composition. The gradient covers the text zone without touching the upper portion where faces/subjects typically sit.

Default gradient works across photos (text sits in bottom ~40%). When composition review flags a P1 interplay issue, the fixer may apply a directional gradient via CSS override (e.g., 105deg angled variant). For future builds, use `scrim_override` to select a lighter/directional variant. Do NOT change global defaults.
