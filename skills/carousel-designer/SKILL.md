---
name: carousel-designer
description: Visual design critique for rendered carousel slides. Single Opus session critiques composite slide images, generates CSS fixes, and re-reviews in a continuous loop until clean. Final verification by separate DeepSeek model. Plugs into art-director Gate 2 for post-render carousel QA.
allowed-tools: read task bash mcp__gemini__gemini-analyze-image
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

# Design Reviewer

Evaluates rendered carousel slide images against approved copy, design direction, and brand tokens. Uses a **single Opus session** for critique + CSS fix generation + re-review — no context lost between steps. A separate DeepSeek session provides cold final verification.

**Architecture:** Single-agent same-session iteration for the core loop (4× cheaper, 4× faster than multi-agent). Final verification by separate model catches blind spots.

**Scope:** Carousel pipeline only. Primary integration: `art-director` Gate 2.

## Input

| Parameter | Required | Description |
|-----------|----------|-------------|
| `carousel_dir` | Yes | Path to `docs/carousels/<slug>/` containing rendered PNGs, script.yaml, carousel.html |
| `token_path` | No | Path to tokens.json. Default: `.agents/skills/carousel-b2b-design/scripts/tokens.json` |
| `design_direction` | Yes | User's words describing aesthetic (e.g., "editorial, clean, purple family, yellow accent") |

Additional inputs read from carousel directory:
- `script.yaml` — approved copy per slide (source of truth for text accuracy)
- `tokens.json` — brand colors, typography scale, safe zones
- `slides/*.png` — rendered PNGs from Playwright
- `carousel.html` — rendered HTML (for CSS fix injection)

## Architecture: Single-Agent Loop with Cold Verification

```
┌─ Single Opus session (critique + fix + re-review) ──────┐
│                                                          │
│  Receives: rendered PNGs + script.yaml + tokens +        │
│            design direction + narrative roles             │
│  ↓                                                        │
│  For each slide: critiques composite image                │
│  (vision: 98.5% acuity, 3.75MP at 2576px)                │
│  ↓                                                        │
│  Generates CSS fixes as JSON map (schema-validated)       │
│  ↓                                                        │
│  Playwright re-renders → Opus re-critiques                │
│  ↓                                                        │
│  Objective refresh every 3 turns: re-inject design        │
│  direction + approved copy to prevent context drift        │
│  ↓                                                        │
│  Max 5 iterations per session → checkpoint + restart      │
│  (new Opus session with prior summary) if not clean       │
│  ↓                                                        │
│  Exit: all slides return NO ISSUES FOUND                  │
│                                                          │
└──────────────────────────────────────────────────────────┘
    ↓
Cold DeepSeek verification: copy-accuracy check
    against script.yaml (separate session, no design context)
    ↓
Writes review-status.yaml (clean + content hash)
```

## Guardrails

| Risk | Mitigation |
|------|-----------|
| Context drift after 5-8 turns | Objective refresh every 3 turns. Checkpoint+restart at 5 iterations |
| Hallucination from iterative self-rewriting | CSS output validated against JSON schema. Cold DeepSeek copy check |
| Single agent develops blind spots | Cold DeepSeek verifies copy accuracy independently |
| Persistence deficit (task abandonment) | Hard stall: 3× identical fingerprint → escalate to human |

## Process

### Step 1 — Validate Inputs

- Confirm `carousel_dir` exists and contains `script.yaml`, `slides/`, `carousel.html`
- Load tokens from `token_path` or use inline fallback
- Read design direction, approved copy (script.yaml), narrative roles
- Compute content shape per slide: char counts, bullet counts, line counts

### Step 2 — Single Opus Critique + Fix Loop

Launch ONE Opus session. Within that session, iterate:

**2a — Critique composite slides:**
For each rendered PNG in `slides/`, Opus (via `read_image`) critiques against:
1. Copy accuracy — does rendered text match script.yaml exactly? (P0 if mismatch)
2. Brand fit — within design direction? Purple family? Yellow accent? Outfit/Inter feel? (P1)
3. Typography — appropriate for content density, clear hierarchy (P1)
4. Contrast — text legible over backgrounds? (P1 if clearly unreadable)
5. Composition — text-image interplay for photo-hero slides (P1), balanced layout for other slides (P2)
6. Spanish only — no English text anywhere (P0)

Severity: P0 = copy mismatch or illegible text (blocks delivery). P1 = brand/typography issues + text-image interplay failures on photo-hero slides. P2 = minor composition improvements.

**2b — Generate CSS fixes:**
For each slide with issues, Opus generates CSS fixes as a JSON map:
```json
{
  "0": ".photo-hero h1 { font-size: 92px; } .photo-hero .sub { font-size: 42px; }",
  "3": ".text-slide .setup { font-size: 36px; line-height: 1.4; }"
}
```
Keys are 0-indexed slide indices. Values are CSS blocks targeting existing HTML class selectors. Output is validated against JSON schema before injection.

**2c — Re-render and re-critique:**
- Inject CSS fixes into `<style id="slide-N">` elements in carousel.html
- Run Playwright render (`render.cjs`)
- Opus re-critiques the re-rendered PNGs within the same session
- Repeat until all slides return NO ISSUES FOUND

**2d — Prevent context drift:**
Every 3 turns, re-inject into the Opus prompt:
```xml
<objective_refresh>
  <design_direction>(user's words)</design_direction>
  <approved_copy>(verbatim from script.yaml)</approved_copy>
  <current_status>cycle N, X slides with issues, Y clean</current_status>
</objective_refresh>
```

**2e — Checkpoint at 5 iterations:**
If not clean after 5 iterations within the session:
1. Summarize: current state, remaining issues, attempted fixes
2. Start fresh Opus session with summary as context
3. Increment `session` in review-status.yaml
4. Continue loop in new session

### Step 3 — Cold DeepSeek Verification

After Opus loop exits clean, dispatch a **separate DeepSeek session** with:
- All rendered PNGs
- script.yaml (approved copy)
- No context of the Opus design session

DeepSeek verifies: does the rendered text in each PNG match the approved copy EXACTLY? This catches blind spots the Opus session may have developed during iteration.

If DeepSeek finds copy mismatches → P0, return to Step 2 (Opus loop to fix).

### Step 4 — Write review-status.yaml

On clean (Opus loop + DeepSeek verification both pass):

```yaml
status: clean
cycles: N
session: N
content_hash: "sha256:..."  # computed by shared utility
fingerprint: "sha256:..."    # null when clean
last_review_at: "ISO-8601"
slides: N
```

On pending (issues remain):
```yaml
status: pending
cycles: N
session: N
fingerprint: "sha256:..."    # hash of current issue list
issues_count: N
```

### Step 5 — Log Design Changes (Template Feedback Loop)

After the carousel is approved, the orchestrator (DeepSeek) reads the css-map.json that Opus generated and classifies each change. Append an entry to `docs/carousels/design-log.yaml`:

```yaml
- slug: <slug>
  date: <ISO8601>
  cycles: <N>
  changes:
    structural: []   # template was missing this capability
    stylistic: []    # taste choice for this specific carousel
```

Classification rules:
- Structural: Template could not do this. Adding this capability would help future carousels. Examples: missing CSS rule, missing DOM element, new slide type needed.
- Stylistic: Taste choice for this piece. Multiple right answers. Examples: font size change, padding tweak, color adjustment.

DeepSeek classifies (text task, not visual — $0.005 vs $0.50). Opus just generates the raw css-map.json.

Review cadence: Every 5-10 carousels, manually review the structural column. If the same structural fix appears 3+ times, candidate for build_carousel.cjs defaults. Stylistic changes are diverse by nature — ignore.

Exit condition: After 5 carousels, if no structural fix repeats across entries, the log has no value. Remove it. This is exploratory.

## Model Selection

| Role | Model | Why |
|------|-------|-----|
| Visual critique + CSS fix | Claude Opus (read_image) | 98.5% visual acuity, 3.75MP resolution, can see text at 2576px |
| Cold copy verification | DeepSeek (text comparison) | Separate session catches blind spots Opus missed |
| Excluded | llama, stable-diffusion, any model below Gemini Flash | Too low quality — hallucinates text on non-English slides (#4599) |

## Review Dimensions

### Copy Accuracy (P0)
- Rendered text matches script.yaml EXACTLY — character by character
- Spanish only — no English text, no hallucinated content
- All approved fields present: headline, subtitle, eyebrow, body, emphasis

### Brand Fit (P1)
- Within user's design direction (not rigid token rules)
- Purple family dominant, yellow accent sparingly
- Outfit/Inter font family preference (direction, not hard rule)
- Editorial, clean aesthetic

### Typography (P1)
- Size appropriate for content density (long text = smaller, short = bolder)
- Clear hierarchy: eyebrow > headline > body > label
- Line height and spacing support readability

### Contrast (P1)
- Text legible over backgrounds and photos
- White text on dark/purple: clearly readable
- Text over photo: gradient scrim sufficient

### Composition — Text-Image Interplay (photo-hero slides, P1; other slides, P2)

**Composition severity boundaries:**
- **P1 (photo-hero only):** Text over image focal point (face, key subject). Gradient buries image concept — visible portion doesn't represent the image's story. Feed-scale thumbnail illegible (375px).
- **P2 (all slides):** Subtle balance improvements. "Could breathe more." Minor negative-space tweaks.

- **Focal point:** What is the image's focal point? What story does the image tell? If the vision model is uncertain about the focal point (low confidence), skip interplay checks and note "focal point uncertain" in review output.
- **Overlay coverage:** What portion is visible through the overlay? Does it represent the image's concept?
- **Text placement:** Does text placement respect the focal point? (visual balance — readability stays in Contrast)
- **Overlay removal test:** Visualize without the overlay gradient. Does the image work on its own?
- **Directional gradient test:** Would an angled gradient (105deg, matching CTA slide precedent) improve text-image interplay?
- **Feed scale:** At 375px wide (Instagram feed), does the composition read as a coherent thumbnail?
- **Escalation:** If scrim_override changes (YAML) are needed, flag as P1 with note "requires scrim_override" — these can't be resolved by CSS fixes and fingerprint-stall escalates to human after 3 cycles.
- **Fallback:** If the angled scrim doesn't resolve within 2 fixer cycles, emit a human-flag note rather than cycling indefinitely.
- For non-photo-hero slides: check balanced layout, not cluttered. Clear focal point.
- Adequate negative space

## Output

When clean, writes `review-status.yaml` to the carousel directory. The posting script (#4569) enforces this gate — no `status: clean`, no post.

## No Cycle Cap

Loop runs until clean. Natural peak at ~4-5 iterations per Opus session. Checkpoint+restart if more needed. Hard stall only when 3× identical fingerprint → escalate to human. No arbitrary cap.

## Integration

Invoked by `art-director` Gate 2 after Playwright render. The single-agent loop runs internally. Final DeepSeek verification runs before writing clean status.

## Standalone Usage

```
/carousel-designer carousel_dir=docs/carousels/<slug> design_direction="editorial, clean..."
```

## Reference
- [Slide Types Spec](../carousel-b2b-design/reference/slide_types.md) — gradient rules, safe zones, composition principles
- [Build Script](../carousel-b2b-design/scripts/build_carousel.cjs) — canonical CSS template, scrim presets

---

## ⛔ LOOP RULE — Mandatory Dispatch Prompt Component

Every design review dispatch prompt to Claude Opus MUST include this instruction verbatim:

````
## LOOP RULE (MANDATORY — DO NOT VIOLATE)

You are NOT done when you generate CSS fixes. You are done ONLY when:

1. You have REBUILT and RE-RENDERED the slides with your fixes applied
2. You have RE-READ the re-rendered PNGs with read_image
3. Your re-critique of the re-rendered PNGs returns NO ISSUES FOUND

If step 3 finds ANY issue → go back to fix, rebuild, re-render, re-read, re-critique.
Minimum 1 full cycle (overrides `No Cycle Cap` — enforce at least one rebuild+re-render even if initial render appears clean). No maximum — loop until clean.

A fix without re-critique on re-rendered output IS NOT A LOOP. It's an abandoned task.
````

### Post-Dispatch Verification

After the design reviewer dispatch returns, the orchestrator MUST verify the loop actually executed:

- [ ] `css-map.json` was modified (newer timestamp than before dispatch)
- [ ] `carousel.html` was rebuilt (newer timestamp than `css-map.json`)
- [ ] Slides were re-rendered (PNGs newer than `carousel.html`)
- [ ] At least 2 copies of the slide PNG exist (before/after fix — e.g., via timestamped filenames or backup directory) OR `review-status.yaml` metadata shows rebuild cycles > 0

If any check fails: the loop was NOT executed. Dispatch again with the LOOP RULE.
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
