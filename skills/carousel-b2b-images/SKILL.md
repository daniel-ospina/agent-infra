---
disable-model-invocation: true
name: carousel-b2b-images
description: Generates AI images for carousel slides via OpenRouter API. Invoked by carousel-b2b-strategy. Generates optimized prompts, submits to OpenRouter, runs quality checks, uploads to Cloudinary, and presents options for user selection.
allowed-tools: read write edit bash web_search web_fetch task
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

# Carousel B2B Images

Generates AI images for carousel slides. Only generates for slides where `needs_image: true` (photo-hero and photo-top types). Uses OpenRouter unified API for model flexibility.

## Input

Reads from `docs/carousels/<slug>/`:
- `script.yaml` — to know which slides need images and their creative direction
- `character-sheet.yaml` — for prompt prefix and reference images (at `docs/carousels/character-sheet.yaml`)

## Output

Writes:
- `selected-images-pending.yaml` — 2-3 options per slide with Cloudinary URLs and `status` field
- Posts composite preview grids to GitHub issue (one per slide)

### selected-images.yaml Schema

Each image entry MUST include a `status` field (#4574):

```yaml
slides:
  1:
    cloudinary_url: "https://res.cloudinary.com/..."
    background_position: "center 16%"
    status: used       # used | not_used | discarded
```

| Status | Meaning | Build behavior |
|--------|---------|---------------|
| `used` | Selected for the final carousel build | Rendered into slides |
| `not_used` | Generated but not selected (kept for future reuse) | Warning only — not rendered |
| `discarded` | Failed quality checks or user-rejected | Hard error — build exits with code 1 |

The images skill must mark every image with the appropriate status when writing `selected-images.yaml`.

## Process

> **MCP Server Access:** This skill requires `gemini` (image generation) and `cloudinary` (upload) MCP servers. When dispatched as a sub-agent, pass `mcp_servers: "supabase,ai-workflow-tools,context7,gemini,cloudinary"` to the `task` tool. If these servers are unavailable, the orchestrator must generate images directly in-session using `mcp__gemini__gemini-generate-image` and `mcp__cloudinary__upload-asset`.

### Step 0 — Template Resolution

The storyboard phase (strategy skill Step 3.5) assigns `image_template` per slide. The images skill reads this assignment — it does NOT re-resolve templates.

1. Read `image_template` from `script.slides[N].image_template`.
2. If absent, error: `❌ Slide N: image_template is missing. Run storyboard phase first.`
3. If `needs_founder` is present, warn (deprecated field — ignored):
   > ⚠️ Slide N: `needs_founder` is deprecated. `image_template` from script.yaml takes precedence.
4. Load template YAML from `templates/<image_template>.yaml`.
5. All subsequent steps reference the loaded template for prompts, quality checks, reference images, model selection, and image config.

**Template → prompt shape:** Each template defines `prompt_prefix` (scene, composition, lighting) and `prompt_suffix` (negative prompts, anti-pattern keywords). The slide's `creative_direction` goes between them.

**Template → quality checks:** Each template defines `quality_checks.auto_reject` (blocking) and `quality_checks.warn` (non-blocking). If `template.byline` is `false`, skip face/skin texture checks.

**Template → model:** Use `template.model_preference.primary` for generation. Fall back to `template.model_preference.fallback` on 503/429.

**Template → image config:** Use `template.image_config.aspect_ratio` and `template.image_config.image_size`.

## Founder Reference Images (Cloudinary Upload) (#4599)

Founder portraits (Daniel) require permanent reference images on Cloudinary. Without them, AI generates random people. Three images are canonical:

| File | Cloudinary URL | Purpose |
|------|---------------|---------|
| `character-sheet.png` | `eldato/reference/character-sheet` | Full-body pose reference |
| `canonical-face-reference.jpeg` | `eldato/reference/canonical-face` | Close-up face for likeness |
| `canonical-portrait-reference.jpeg` | `eldato/reference/canonical-portrait` | Standard portrait framing |

**Upload API call format:**
```bash
curl -X POST "https://api.cloudinary.com/v1_1/$CLOUDINARY_CLOUD_NAME/image/upload" \
  -F "file=@canonical-face-reference.jpeg" \
  -F "public_id=eldato/reference/canonical-face" \
  -F "upload_preset=$CLOUDINARY_UPLOAD_PRESET"
```

**Reference images in OpenRouter API calls:** Use as `image_url` content blocks (NOT base64 — too large for the payload):
```json
{
  "model": "google/gemini-2.5-flash-image",
  "messages": [{
    "role": "user",
    "content": [
      {"type": "text", "text": "Generate a portrait matching the reference person..."},
      {"type": "image_url", "image_url": {"url": "https://res.cloudinary.com/djzwqixjt/image/upload/eldato/reference/canonical-face"}}
    ]
  }]
}
```

**Reusable script:** `scripts/upload-reference-images.sh` — uploads all three references in one command. Run once per environment. Reference images are permanent — they do not change between carousels.

## Saved Image Reuse

Before generating new images, check the saved catalog at `docs/carousels/saved/catalog.yaml`. If a matching image exists (same category, compatible scene, similar expression), present it as an option alongside newly generated ones. This saves API costs and builds an asset library over time.


### Catalog Schema
Each entry in `catalog.yaml` must have a `status` field:
- `available` — image generated, not yet used in any carousel
- `selected` — chosen for current carousel build (in-flight)
- `used` — carousel published successfully (transition at publish, not selection)
- `discarded` — failed quality checks or user rejected

Only `available` and `used` images may be reused. `discarded` images must be rejected by the build script (#4599).

## Image Prompting Guide

This guide teaches the agent HOW to craft prompts, not WHAT to say. Use it as a reference when building prompts from template + creative_direction.

### Model Selection

| Image Type | Primary Model | Fallback | Why |
|------------|--------------|----------|-----|
| Founder portraits | OpenRouter `gemini-3.1-flash-image-preview` | Gemini native | OpenRouter produces less plastic, more editorial portraits |
| Scene / interior | OpenRouter `gemini-3.1-flash-image-preview` | Gemini native | Better atmosphere, fewer clichés |
| Food / objects | Gemini native | OpenRouter | Gemini native handles close-up detail better |
| Abstract / texture | Either | Either | Difference is marginal |

**Gemini native tool caveat:** Tends toward plastic-looking, clichéd compositions with wrong atmosphere. Prefer OpenRouter + gemini-3.1-flash-image-preview for scenes and portraits unless the template specifies Gemini native.

### Prompt Structure

Build prompts as: `[prompt_prefix] + [creative_direction] + [prompt_suffix]`

- **prompt_prefix** (from template): Scene, composition, lighting style. Sets the stage.
- **creative_direction** (from script.yaml): What makes this slide unique — the specific atmosphere, cultural markers, subject details. This is where craftsmanship lives.
- **prompt_suffix** (from template): Negative prompts, anti-pattern keywords, quality constraints.

**Crafting creative_direction:**
- Atmosphere descriptors beat object lists: "loud, trendy restaurant with house music energy" > "people toasting at a table"
- Cultural specificity wins: "upper-class Mexican business owners" > "diverse businesspeople"
- Reference images as Cloudinary URLs (not base64 — too large): `reference_images: ["https://res.cloudinary.com/..."]`

### Anti-AI-Look Techniques

These phrases consistently reduce the plastic/generic AI look. Include them in prompt_suffix or negative space:

| Technique | Example | Why it works |
|-----------|---------|-------------|
| Editorial photography cue | "editorial photography, documentary style" | Shifts model toward photojournalism aesthetic |
| Negative constraints | "NOT plastic, NOT AI-looking, NOT stock photo" | Prevents synthetic skin textures and stock poses |
| Candid authenticity | "candid moment, unposed, natural expression" | Reduces stiff posing |
| Cultural specificity | "upper-class Mexican" not "businesspeople" | Prevents generic diversity clichés |
| Atmosphere over objects | "loud, trendy, house music energy" | Prevents check-list compositions |
| Negative space context | "NOT a nightclub, NOT a sports bar, NOT gringo" | Prevents category drift |
| Lighting specificity | "warm ambient light, golden hour, soft shadows" | Prevents flat studio lighting |

### Prompt Quality Self-Check

Before submitting a prompt, verify:
- [ ] prompt_prefix sets the scene (not just generic "a photo of")
- [ ] creative_direction adds specific, culturally-grounded detail
- [ ] prompt_suffix includes at least 2 anti-AI-look phrases
- [ ] Negative constraints use "NOT X" format (not "avoid X")
- [ ] Atmosphere is described before objects
- [ ] Reference images are Cloudinary URLs (if present)

### Pre-Generation Check
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
