> **Canonical:** `agent-infra/skills/google-slides/brand-adapter.md` — consumers hard-link into `operations/skills`. Token path below is agent-infra-relative; in consumer repos resolve via `$SKILLS_PREFIX` (default `operations/skills/`).

# Brand Token Adapter for Google Slides

Maps El Dato brand tokens (`skills/carousel-b2b-design/scripts/tokens.json` — canonical agent-infra path) to Google Slides theming via Composio `BATCH_UPDATE` operations.

## Color Mapping

| Brand Token | Hex | Google Slides Usage |
|------------|-----|-------------------|
| Purple | `#5B3B8C` | Header/title backgrounds, accent shapes, slide number color |
| Deep Purple | `#3F2766` | Footer backgrounds, dark section dividers |
| Yellow | `#F2C94C` | CTA highlights, bullet points, accent lines (<10% coverage) |
| Cream | `#EFE9DC` | Content area backgrounds, body text backgrounds |
| Muted | `#C9BBE0` | Borders, secondary shapes, subtle dividers |
| White | `#FFFFFF` | Text on dark backgrounds, slide backgrounds |

## BATCH_UPDATE Color Application Strategy

### Phase 1: Theme Selection
Use `creative_purple` theme in `GOOGLESLIDES_CREATE_SLIDES_MARKDOWN` as baseline:
```
Theme: creative_purple
```
This provides purple-adjacent defaults. Then override with exact brand colors.

### Phase 2: Per-Element Color Updates (via BATCH_UPDATE)

**Header slides (title, section dividers):**
```json
{
  "updateShapeProperties": {
    "objectId": "<shape_id>",
    "shapeProperties": {
      "shapeBackgroundFill": {
        "solidFill": {
          "color": {
            "rgbColor": {"red": 0.357, "green": 0.231, "blue": 0.549}
          }
        }
      }
    },
    "fields": "shapeBackgroundFill.solidFill.color"
  }
}
```

**Content slides (bullets, tables, text):**
```json
{
  "updatePageProperties": {
    "objectId": "<page_id>",
    "pageProperties": {
      "pageBackgroundFill": {
        "solidFill": {
          "color": {
            "rgbColor": {"red": 0.937, "green": 0.914, "blue": 0.863}
          }
        }
      }
    },
    "fields": "pageBackgroundFill"
  }
}
```

**Text style (headings):**
```json
{
  "updateTextStyle": {
    "objectId": "<text_element_id>",
    "style": {
      "foregroundColor": {
        "opaqueColor": {
          "rgbColor": {"red": 0.357, "green": 0.231, "blue": 0.549}
        }
      },
      "fontFamily": "Outfit",
      "fontSize": {"magnitude": 36, "unit": "PT"},
      "bold": true
    },
    "fields": "foregroundColor,fontFamily,fontSize,bold"
  }
}
```

**Text style (body):**
```json
{
  "updateTextStyle": {
    "objectId": "<text_element_id>",
    "style": {
      "foregroundColor": {
        "opaqueColor": {
          "rgbColor": {"red": 0.247, "green": 0.149, "blue": 0.412}
        }
      },
      "fontFamily": "Inter",
      "fontSize": {"magnitude": 24, "unit": "PT"}
    },
    "fields": "foregroundColor,fontFamily,fontSize"
  }
}
```

## RGB Color Reference

| Hex | RGB (0-255) | RGB (0-1 for API) |
|-----|------------|-------------------|
| `#5B3B8C` | 91, 59, 140 | 0.357, 0.231, 0.549 |
| `#3F2766` | 63, 39, 102 | 0.247, 0.153, 0.400 |
| `#F2C94C` | 242, 201, 76 | 0.949, 0.788, 0.298 |
| `#EFE9DC` | 239, 233, 220 | 0.937, 0.914, 0.863 |
| `#C9BBE0` | 201, 187, 224 | 0.788, 0.733, 0.878 |
| `#FFFFFF` | 255, 255, 255 | 1.0, 1.0, 1.0 |

## Typography Configuration

**Font families (Google Fonts, available in Slides):**
- Headings: `Outfit` (weights: 400, 500, 600, 700, 800, 900)
- Body: `Inter` (weights: 300, 400, 500, 600)

**Size hierarchy:**
- Title slide heading: 48pt
- Section heading: 36pt
- Slide heading: 32pt
- Body text: 24pt (20pt minimum)
- Captions/footnotes: 16pt

**Yellow accent rule:** Max 10% of slide elements use yellow (F2C94C). Overuse dilutes impact.

## Safe Zones (16:9 Aspect Ratio)

Carousel safe zones are for 1:1 (1080x1080). Presentations use 16:9.

```
+---------------------------------------------------+
|  80px                                              |
|  +---------------------------------------------+  |
|  |              TITLE AREA (top 20%)            |  |
|  |                                             |  |
|  +---------------------------------------------+  |
|  |                                             |  |
|  |            CONTENT AREA (60%)               |  |
|  |                                             |  |
|  |                                             |  |
|  +---------------------------------------------+  |
|  |           FOOTER / CTA (bottom 20%)         |  |
|  +---------------------------------------------+  |
|                                                   80px
+---------------------------------------------------+
```

Margins: 80px all sides. Content must not bleed into margin zone.
Footer height: bottom 20% of slide (for logo, page numbers, CTA).

## Markdown Brand Preamble

When generating via `GOOGLESLIDES_CREATE_SLIDES_MARKDOWN`, the theme directive applies baseline colors. Brand-specific refinements are applied post-creation via BATCH_UPDATE.

The markdown preamble for brand-aware generation:
```
Theme: creative_purple
```

Post-creation refinements (applied in review Phase 3 Pass 1):
1. All shape backgrounds checked against brand palette
2. All text colors checked against brand palette
3. Font families verified (Outfit/Inter)
4. Font sizes verified (min 20px body, 32px headings)
5. Yellow usage checked (<10% of elements)
6. Safe zone margins verified (80px)
