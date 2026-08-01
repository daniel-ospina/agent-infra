---
name: carousel-b2b-copy
description: Generates carousel copy and creative direction from a creative brief. Invoked by carousel-b2b-strategy. Runs internal review loop (tone, brand, structure) before presenting script to user.
allowed-tools: read write edit bash task
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

# Carousel B2B Copy

Generates the script and creative direction for each slide of a B2B carousel. Takes a creative brief → produces V1 script → runs internal review loop → outputs final script as both YAML (`script.yaml`) and readable markdown (`script.md`).

**Scope:** B2B only — Daniel Ospina / founder voice.

## Input

Reads `docs/carousels/<slug>/brief.yaml` (Creative Brief schema). Validates against schema before processing.

## Output

Writes to `docs/carousels/<slug>/`:
- `script.yaml` — structured Script schema (consumed by images and design skills)
- `script.md` — human-readable markdown for user review and editing

## Process

### Step 1 — Generate V1 Script

Read the creative brief. For each slide (brief.slide_count slides), generate:
- Slide type (photo-hero or text-slide)
- Copy fields (headline, subtitle, eyebrow, body, emphasis words)
- Creative direction for photo-hero slides (scene, gaze, composition, mood)

Must produce exactly `brief.slide_count` slides.

### Step 2 — Internal Review Loop

Dispatch 3 parallel reviewer sub-agents (fresh `task` for each):

1. **Tone reviewer:** Does this match Daniel's voice? Confrontational-but-honest? Bar test? Natural Spanish?
2. **Brand reviewer:** Are emphasis words correctly marked? Yellow only for keywords? No corporate tone?
3. **Structure reviewer:** Does the carousel follow the chosen template? Correct slide types? Builds toward CTA?

**Quorum (counts APPROVALS):**
- 0/3 approve → BLOCKED (fail)
- 1/3 approve → BLOCKED (require human override)
- 2/3 approve → PASSED with warning
- 3/3 approve → PASSED clean

Fix issues, re-dispatch fresh reviewers. **Convergence-gated; safety cap: 10 cycles.** On cap → BLOCKED with `issues_remaining`.

### Step 3 — Write Output

Write `script.yaml` with `quality_gate` field. Write `script.md` as human-readable storyboard with template assignments and creative direction per slide. This is the user-facing storyboard document. Format:

```markdown
# Carousel: <slug>

## Slide 1 — Portada (photo-hero)
**Headline:** Contratar una agencia no resuelve tu marketing.
**Subtitle:** Te explico por qué — y qué sí lo resuelve.
**Emphasis:** no resuelve
**Creative direction:** Founder portrait, café, looking at camera, subject right

---

## Slide 2 — La trampa (text-slide, purple)
**Eyebrow:** LA TRAMPA
**Body:** $5,000, $10,000, hasta $20,000 al mes...
**Emphasis:** ¿Pero cuántos visitan tu negocio?
```

### Step 4 — Interactive Refinement

The orchestrator (in main chat) can brainstorm lines with the user and edit `script.md` directly. For directed variants:

```
/regenerate slide:4 type:copy changes: "make it more confrontational, shorter"
```

Re-runs generation for that slide only, re-runs review loop on changed slides.

### Step 4 — Humanizer Pass

Run the final script through `content-humanizer` to strip AI writing patterns:

```bash
# Invoke content-humanizer with the script content
# Pass page_type="carousel-b2b" and language="es"
# The humanizer removes 33 AI patterns while preserving Daniel's voice
```

Re-run a lightweight review on the humanized version (check humanizer didn't break anything: no dropped words, no meaning changes).

**Phase complete:** Script is now humanized AND reviewed. Ready for storyboard.

### Step 5 — Interactive Refinement

The orchestrator (in main chat) can brainstorm lines with the user and edit `script.md` directly. For directed variants:

```
/regenerate slide:4 type:copy changes: "make it more confrontational, shorter"
```

Re-runs generation for that slide only, re-runs review loop on changed slides, then re-runs humanizer.

## Reference

- [Copy Playbook](reference/copy-playbook.md)
- [Slide Structures](reference/slide-structures.md)
- [Voice Profiles](../carousel-b2b-strategy/reference/voice-profiles.md)

## Instagram Slide Limit

**Hard constraint:** Instagram carousels support a maximum of **10 slides**. The copy skill MUST design all carousel briefs to fit within this limit. The posting script (`ig-post-carousel.ts`) also enforces this at post time, but designing within the limit at copy stage avoids wasted design work.

### Slide budget template

| Role | Count | Notes |
|------|-------|-------|
| Hook / portada | 1 | Grab attention |
| Credibility / founder | 1 | Why listen to us |
| Framework / concept | 1-2 | The big idea |
| Examples / details | 4-5 | Evidence, specifics |
| CTA / closing | 1 | Next step |

**Total: max 10 slides.** If content exceeds 10 slides, split into a multi-part series:

```yaml
# Part 1 carousel
slug: topic-part-1
slide_count: 10
series:
  part: 1
  total: 2
  next_slug: topic-part-2

# Part 2 carousel  
slug: topic-part-2
slide_count: 8
series:
  part: 2
  total: 2
  prev_slug: topic-part-1
```

Each part gets its own brief, images, design, and review. Cross-link in captions ("Parte 1 de 2 — síguenos para la segunda parte").
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
