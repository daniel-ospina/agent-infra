# Creative Brief Template

The creative brief is the central contract document. Every carousel starts here. Fill every field — specificity saves time downstream.

## Template

```yaml
schema_version: "1.0"
mode: guided | gates | autonomous
voice: b2b
format: carousel | single-image
channel: instagram | facebook
structure: 3-pilares | 5-tips | before-after | custom
platforms: [instagram]           # instagram | facebook | linkedin | tiktok
aspect_ratio: "4:5"             # Derived from platforms[0] — do NOT set manually
slide_count: 8..12
belief_statement: "After seeing this, the business owner should believe..."
design_direction: "warm, intimate, bar conversation"  # aesthetic for design reviewer
tone: "confrontational but honest, natural Spanish"    # voice for copy skill
constraints: ""                                         # user constraints (e.g. "no frameworks, short lines")
cta: "Link en bio →"  # max 80 chars
audience_description: "Dueños de negocios locales en México, 30-50 años"
hashtags:
  - "#negocioslocales"
  - "#marketingdigital"
  - "#pymesmexico"
```

## Field Guide

### belief_statement
The north star. Every slide should contribute to making the viewer believe this.
- Good: "After seeing this, the business owner should believe that fixing distribution is more important than hiring another agency."
- Bad: "After seeing this, they should know about marketing." (too vague)

### structure
Pre-built templates:
- **3-pilares:** Portada → Trampa → Historia A → Historia B → Insight → Pilar 1 → Pilar 2 → Pilar 3 → Veredicto → CTA
- **5-tips:** Portada → Contexto → Tip 1 → Tip 2 → Tip 3 → Tip 4 → Tip 5 → Conclusión → CTA
- **before-after:** Portada → El problema → La causa → La solución → El resultado → CTA
- **custom:** Free-form slide-by-slide definition

### design_direction
Aesthetic description for the design reviewer. Describes the visual mood.
- Good: "warm, intimate, bar conversation, amber lighting"
- Good: "bold, confrontational, high contrast, editorial"
- Bad: "nice looking" (too vague)

### tone
Voice description for the copy skill. How should the copy sound?
- Good: "confrontational but honest, like a friend at a bar"
- Good: "professional but approachable, founder-to-founder"
- Bad: "good tone" (too vague)

### constraints
User-specified constraints. What should the pipeline avoid?
- Example: "no frameworks (too many in recent posts)"
- Example: "short punchy lines, no long paragraphs"
- Example: "no discount-focused language"

### cta
Keep it short. Common patterns:
- "Link en bio →"
- "Comenta 'info' y te explico"
- "Comparte si conoces a alguien que lo necesite"
- "Guarda esto para después"

### hashtags
3-5 max. Niche-focused, avoid saturated giants. Examples:
- #negocioslocales #restaurantesmexico #pymemexico #marketingreal

### platforms
Array of target platforms for the carousel. Default: `["instagram"]`.

Platform determines `aspect_ratio` derivation:
- `instagram` → carousel feed, `aspect_ratio: "4:5"`
- `facebook` → carousel, `aspect_ratio: "1:1"`
- `linkedin` → carousel/document, `aspect_ratio: "1:1"`
- `tiktok` → photo mode, `aspect_ratio: "9:16"`

Multiple platforms can be specified (e.g., `[instagram, facebook]`). `aspect_ratio` is derived from `platforms[0]`.

### aspect_ratio
**Derived field — do NOT set manually.** Derived from `platforms[0]` at pipeline start.

Documented for transparency. Current mapping:
| Platform | aspect_ratio |
|----------|-------------|
| instagram | "4:5" |
| facebook | "1:1" |
| linkedin | "1:1" |
| tiktok | "9:16" |

Backward compatibility: briefs without `platforms` default to `["instagram"]` with `aspect_ratio: "4:5"`.
