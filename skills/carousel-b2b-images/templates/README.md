# Image Templates

Registry of image generation templates for carousel slides. Each template defines the prompt shape, quality checks, and rendering rules for a specific image category.

## Schema

```yaml
name: <template-name>          # unique identifier, used as image_template value in script.yaml
version: "1.0"                 # schema version for migration tracking
description: <when to use>     # human-readable guidance for template selection
byline: true|false             # whether to show "Daniel Ospina · Fundador" byline on slides using this image
prompt_prefix: |               # prepended before creative_direction from the slide
  <scene, composition, expression, lighting instructions>
prompt_suffix: |               # appended after creative_direction (negative prompts, texture keywords)
  <anti-patterns, quality keywords>
reference_images: []           # list of reference image filenames for image-to-image (founder-portrait only)
quality_checks:
  auto_reject: [check1, ...]   # checks that BLOCK delivery — regenerate if failed
  warn: [check2, ...]          # checks that warn but allow delivery
scrim:
  type: heavy-purple|medium-purple|light-purple|none  # gradient overlay intensity
model_preference:
  primary: <model-id>          # preferred OpenRouter model
  fallback: <model-id>         # fallback if primary is unavailable
image_config:
  aspect_ratio: "4:5"          # Instagram carousel feed
  image_size: "2K"             # output resolution
```

## Available Templates

| Template | byline | scrim | auto_reject | use case |
|----------|--------|-------|-------------|----------|
| `founder-portrait` | true | heavy-purple | face_integrity, depth_of_field | Daniel in environment |
| `food-product` | false | light-purple | depth_of_field, subject_clarity | Plated dishes, cocktails |
| `ambient-interior` | false | medium-purple | composition_balance, no_ai_hallucination | Restaurant/bar/café spaces |
| `action-people` | false | medium-purple | face_count_sanity, no_uncanny_expressions | Crowds, events, social |
| `text-graphic` | false | none | text_zone_cleanliness | Typography-first backgrounds |

## Adding a New Template

1. Copy an existing template YAML as a starting point
2. Fill in all required fields per the schema above
3. Document the new template in this README's table
4. Update the storyboarding step in `carousel-b2b-strategy/SKILL.md` to include the new template in the selection table
5. Test with a single-slide carousel before multi-slide use

## Backward Compatibility

Templates replace the legacy `needs_founder` boolean flag. The mapping is:

| `needs_founder` | `image_template` |
|----------------|-----------------|
| `true` | `founder-portrait` |
| `false` | `ambient-interior` |

`needs_founder` is deprecated. New carousels MUST use `image_template` instead. When `needs_founder` is present without `image_template`, the pipeline logs a deprecation warning but still operates correctly.
