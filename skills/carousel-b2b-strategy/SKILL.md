---
name: carousel-b2b-strategy
description: 7-phase stateful pipeline for B2B carousel content with status.yaml tracking and cross-session resume. Use when asked to create a carousel, social media post, or thought leadership content. NEVER create carousel content without reading this skill — this is a pipeline with persistent state, not a one-shot content task.
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
version: 1.0.0
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

# Carousel B2B Strategy (Orchestrator)

Orchestrates the creation of branded carousels and single-image social media posts for El Dato's B2B marketing. Manages the full pipeline: strategy brief → copy generation → image generation → graphic design → delivery.

**Scope:** B2B only — founder thought leadership (Daniel Ospina's voice), selling El Dato to local businesses. Spanish-only for v1. B2C content is out of scope.

## When to Use

- "Create a carousel about..."
- "I need a social media post for..."
- "/skill:carousel-b2b-strategy"
- Any B2B content creation request for Instagram/Facebook

## Pipeline Modes

Asked at invocation start. Default: **B (Gates Only).**

| Mode | Behavior | Touchpoints |
|------|----------|-------------|
| A — Guided | Stop after every skill, wait for `/approve` | Strategy → Copy → Images → Design → Delivery |
| B — Gates Only | Auto-proceed, stop at quality gates | Brief → Copy (after review) → Images (selection) → Final review |
| C — Autonomous | Everything auto, warnings logged | Brief only |

Switch modes mid-pipeline via `/mode A`.


## Pre-Flight Checks

Before creating any carousel, verify the environment. Run each check. If any fails, tell the user exactly what to install and how — do NOT proceed with cryptic errors.

```bash
# 1. GitHub CLI (needed for issue creation)
type gh >/dev/null 2>&1 || { echo "❌ gh CLI not found."; echo "   Install: https://github.com/cli/cli#installation"; echo "   Then: gh auth login"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "❌ gh not authenticated. Run: gh auth login"; exit 1; }

# 2. OpenRouter API key (needed for image generation)
[ -n "$OPENROUTER_API_KEY" ] || { echo "❌ OPENROUTER_API_KEY not set."; echo "   Get key at https://openrouter.ai/keys"; echo "   Add to shell config: export OPENROUTER_API_KEY="sk-or-v1-...""; exit 1; }

# 3. Playwright (needed for rendering)
npx playwright --version >/dev/null 2>&1 || { echo "❌ Playwright not found."; echo "   Run: npx playwright install chromium"; exit 1; }

# 4. Fonts (needed for brand typography) — present either in this repo (skills/) or linked (operations/pi-config/skills/)
if [ ! -f skills/carousel-b2b-design/scripts/fonts/outfit.ttf ] && [ ! -f operations/pi-config/skills/carousel-b2b-design/scripts/fonts/outfit.ttf ]; then
  echo "❌ Fonts missing."; echo "   Run: git pull origin main"; exit 1;
fi

# 5. Node.js
type node >/dev/null 2>&1 || { echo "❌ Node.js not found."; echo "   Install Node.js ≥20: https://nodejs.org"; exit 1; }

# 6. npm dependencies
[ -d node_modules/playwright ] || { echo "❌ npm dependencies not installed."; echo "   Run: npm install"; exit 1; }

# 7. Template seed script (build_carousel.cjs provides valid HTML structure for carousel_designer to refine)
[ -f skills/carousel-b2b-design/scripts/build_carousel.cjs ] || echo "⚠️ build_carousel.cjs not found — template seed unavailable. carousel_designer can still generate from scratch.";

# 8. yaml npm package (needed for status.yaml read/write)
node -e "require('yaml')" >/dev/null 2>&1 || { echo "❌ 'yaml' npm package not found."; echo "   Run: npm install yaml"; exit 1; }
```

**Common fixes for Klara's machine:**
- No Homebrew → install gh directly from https://github.com/cli/cli/releases/latest
- No Node.js → install via nvm (works without sudo): `curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash`
- Skills not showing → symlink missing: in consumer repos skills link to `operations/pi-config/skills/` (see `scripts/link-skills.sh`); in agent-infra they live in `skills/` directly
- Running from main checkout → create a worktree or set `ELDATO_ALLOW_MAIN_EDITS=1`

If ALL checks pass, proceed with the carousel. Otherwise, surface the first failure with its fix.


## Process

### Status Tracking Protocol

Every step writes to `docs/carousels/<slug>/status.yaml` using the `write_status` helper:

```bash
write_status() {
  # Usage: write_status <slug> <phase> <status> [reason]
  local slug="$1" phase="$2" status="$3" reason="${4:-null}"
  local dir="docs/carousels/$slug"
  local file="$dir/status.yaml"
  local tmp="$dir/status.yaml.tmp"
  [ -f "$file" ] || { echo "❌ status.yaml not found at $file" >&2; return 1; }
  
  node -e "
    const yaml = require('yaml');
    const fs = require('fs');
    const file = process.argv[1], tmp = process.argv[2], phase = process.argv[3], status = process.argv[4], reason = process.argv[5];
    let doc = yaml.parse(fs.readFileSync(file, 'utf8'));
    doc.updated = new Date().toISOString();
    doc.phases[phase].status = status;
    doc.phases[phase].at = (status === 'complete' || status === 'failed') ? new Date().toISOString() : null;
    doc.phases[phase].reason = reason === 'null' ? null : reason;
    // Derive current_phase: first phase where status ≠ complete and ≠ skipped
    const phaseList = ['strategy','copy','storyboard','gate1','images','design','gate2'];
    doc.current_phase = phaseList.find(p => doc.phases[p].status !== 'complete' && doc.phases[p].status !== 'skipped') || phaseList[phaseList.length - 1];
    // Guard: warn if transitioning to images but storyboard never ran
    if (phase === 'images' && doc.phases.storyboard && doc.phases.storyboard.status === 'pending' && doc.phases.storyboard.at === null) {
      console.warn('⚠️  Storyboard phase was skipped. Image templates may be wrong. Consider running storyboard first.');
      console.warn('    Proceeding anyway — this is a warning, not a block.');
    }
    fs.writeFileSync(tmp, yaml.stringify(doc));
    const fd = fs.openSync(tmp, 'a');
    fs.fsyncSync(fd);
    fs.closeSync(fd);
  " "$file" "$tmp" "$phase" "$status" "$reason"
  mv "$tmp" "$file"  # atomic — same-filesystem rename
  
  # Checkpoint to Tortoise/FalkorDB for cross-session/worktree recovery (#5044)
  # tortoise checkpoint --wing eldato --room carousel-pipeline --content "$(cat $file)" --source_file "$file" 2>/dev/null || true
}
```

**Atomic write rule:** Always write to `status.yaml.tmp`, `fsync`, then `mv` to `status.yaml`. Never write directly. A same-filesystem `mv` is atomic — it either replaces the file or leaves the original intact.

### Resume Logic

At orchestrator start (after pre-flight checks, before Step 1):

1. Check if `docs/carousels/<slug>/status.yaml` exists.
2. If yes:
   - **Query Tortoise for latest state (#5044):** Check FalkorDB for cross-session state. If Tortoise has a newer `updated` timestamp, use that state and warn: `⚠️ Tortoise has newer state than local status.yaml`.
   - **Consistency validation (#5044):** If `design: complete` or `gate2: complete`, then `images` must also be `complete`. If `gate2: complete` then `design` must also be `complete`. Auto-correct inconsistent phases and warn.
   - Read `current_phase` and derive it from phase statuses (first phase where status ≠ `complete` and ≠ `skipped`).
   - If stored `current_phase` differs from derived, auto-correct and warn:  
     `⚠️ current_phase corrected: stored=<stored>, derived=<derived>`
   - **Stale `in_progress` recovery:** For every phase where status is `in_progress` and `at` timestamp is >30 minutes old, mark as `failed` with reason `"stale — pipeline crashed"`. This preserves the crash record and prevents phases from appearing perpetually in-progress.
   - Skip all phases before `current_phase`. Phases marked `failed` by stale recovery are re-run.
   - Surface: **"Resuming carousel '<slug>' from phase: <current_phase> <N phases marked stale>"` (if any stale phases recovered).**
3. If no: proceed from Step 1 (new carousel).

---

### Instagram Readiness (#4599)
- Token validity: verify IG_ACCESS_TOKEN can query /me/accounts
- IG account linkage: confirm Instagram account linked to Facebook Page under same Business Manager
- Reference images: confirm Cloudinary references exist
- Model availability: confirm design model (Opus/GPT-4o) accessible — do not proceed with llama

### Content Theme Validation (#4599)
- Before full production, validate theme against audience fit for B2B founder-voice content

### Phase 0: State Discovery (ALWAYS RUN FIRST)

**This phase is non-negotiable.** Skipping it causes pipeline corruption (duplicate briefs, lost state, orphaned images).

1. Check if `docs/carousels/<slug>/status.yaml` exists
2. If exists → follow **Resume Logic** (below). Do NOT create a new carousel or overwrite state.
3. If not → proceed to Step 1 (Discuss Brief)

### Step 1 — Discuss Brief

Ask structured questions to fill the creative brief:
- **Belief statement:** "After seeing this, the business owner should believe ___"
- **Design direction:** Visual aesthetic (e.g., "warm, intimate, bar conversation")
- **Tone:** Voice for the copy (e.g., "confrontational but honest, natural Spanish")
- **Constraints:** What to avoid (e.g., "no frameworks, short lines")
- **Channel + format:** Instagram carousel / Facebook carousel / single image
- **Key concept:** Framework (3-pilares, 5-tips, before-after, custom)
- **CTA:** What action? (link in bio, comment, DM)
- **Audience:** Who are we talking to?
- **Slide count:** 8-12

Write `docs/carousels/<slug>/brief.yaml` per the Creative Brief schema.

**After brief.yaml is written**, create the initial status.yaml:

```bash
mkdir -p "docs/carousels/$slug"
cat > "docs/carousels/$slug/status.yaml" << 'STATUSEOF'
schema_version: "1.0"
slug: <slug>
pipeline: carousel-b2b
created: <ISO8601>
updated: <ISO8601>
phases:
  strategy:    {status: complete, at: <ISO8601>, reason: null}
  copy:        {status: pending, at: null, reason: null}
  storyboard:  {status: pending, at: null, reason: null}
  gate1:       {status: pending, at: null, reason: null}
  images:      {status: pending, at: null, reason: null}
  design:      {status: pending, at: null, reason: null}
  gate2:       {status: pending, at: null, reason: null}
current_phase: copy
STATUSEOF
# Replace placeholders with actual values
node -e "
  const yaml = require('yaml');
  const fs = require('fs');
  const now = new Date().toISOString();
  let doc = yaml.parse(fs.readFileSync('docs/carousels/$slug/status.yaml', 'utf8'));
  doc.created = now;
  doc.updated = now;
  doc.slug = '$slug';
  doc.phases.strategy.at = now;
  fs.writeFileSync('docs/carousels/$slug/status.yaml.tmp', yaml.stringify(doc));
  fs.fsyncSync(fs.openSync('docs/carousels/$slug/status.yaml.tmp', 'a'));
"
mv "docs/carousels/$slug/status.yaml.tmp" "docs/carousels/$slug/status.yaml"
```

### Step 2 — Create Tracking Issue

```bash
gh issue create --title "Carousel: <slug>" --label "Content Creation" --body "<brief summary>"
```

Set workflow label: `content-creating`.

### Step 3 Pre-Check — Copy Skip Detection

Before dispatching the copy skill, check if copy and humanizer already completed.

```bash
STATUS_FILE="docs/carousels/$slug/status.yaml"
SCRIPT_FILE="docs/carousels/$slug/script.yaml"
BRIEF_FILE="docs/carousels/$slug/brief.yaml"

if [ -f "$STATUS_FILE" ]; then
  # P0 Fix 3: Check ALL phases before storyboarding, not just copy
  SKIP_OK=true
  for phase in copy; do
    PHASE_STATUS=$(node -e "const y=require('yaml'),fs=require('fs');const d=y.parse(fs.readFileSync('$STATUS_FILE','utf8'));console.log(d.phases['$phase']?.status||'pending')")
    if [ "$PHASE_STATUS" != "complete" ] && [ "$PHASE_STATUS" != "skipped" ]; then
      echo "Phase $phase is $PHASE_STATUS — cannot skip. Resuming from $phase."
      SKIP_OK=false
      break
    fi
  done
  if [ "$SKIP_OK" = "true" ]; then
    # Verify script.yaml slide count matches brief.yaml
    if [ -f "$SCRIPT_FILE" ] && [ -f "$BRIEF_FILE" ]; then
      SCRIPT_COUNT=$(node -e "const y=require('yaml'),fs=require('fs');console.log(y.parse(fs.readFileSync('$SCRIPT_FILE','utf8')).slides?.length||0)")
      BRIEF_COUNT=$(node -e "const y=require('yaml'),fs=require('fs');console.log(y.parse(fs.readFileSync('$BRIEF_FILE','utf8')).slide_count||0)")
      if [ "$SCRIPT_COUNT" -ne "$BRIEF_COUNT" ]; then
        echo "⚠️ Script has $SCRIPT_COUNT slides, brief expects $BRIEF_COUNT. Regenerating copy."
        SKIP_OK=false
      fi
    fi
    # Scan for placeholder text before skipping
    if [ -f "$SCRIPT_FILE" ]; then
      PLACEHOLDERS=$(grep -c -i -E 'TODO|TKTK|\[placeholder\]' "$SCRIPT_FILE" || echo 0)
      EMPTY_HEADLINES=$(node -e "const y=require('yaml'),fs=require('fs');const d=y.parse(fs.readFileSync('$SCRIPT_FILE','utf8'));const s=d.slides||[];console.log(s.filter(s=>!s.copy?.headline||s.copy.headline.trim()==='').length)")
      if [ "$PLACEHOLDERS" -gt 0 ] || [ "$EMPTY_HEADLINES" -gt 0 ]; then
        echo "⚠️ Script has $PLACEHOLDERS placeholder(s) and $EMPTY_HEADLINES empty headline(s). Refusing to skip — regenerate copy."
        SKIP_OK=false
      fi
    fi
  fi
  if [ "$SKIP_OK" = "true" ]; then
    MODE=$(node -e "const y=require('yaml'),fs=require('fs');const d=y.parse(fs.readFileSync('$STATUS_FILE','utf8'));console.log(d.mode||'gates')")
    if [ "$MODE" = "autonomous" ]; then
      echo "✅ Mode C: Auto-skipping copy generation (already complete)."
      write_status "$slug" copy skipped "already complete"

      # Proceed to Step 3.5 (storyboarding — humanizer now runs inside copy skill)
    else
      # Mode A/B: ask user
      echo "📝 Copy exists and is complete. Skip generation? [yes]/no"
      read -r USER_INPUT
      if [ "$USER_INPUT" != "yes" ]; then
        echo "Regenerating copy..."
        SKIP_OK=false
      else
        echo "Skipping copy generation."
      fi
    fi
  fi
fi
```

If `SKIP_OK` is `true` after this check, skip Steps 3 and 3.5 entirely — proceed directly to [Step 3.5 — Storyboarding](#step-36--storyboarding--creative-concept-human-gate).

### Step 3 — Dispatch Copy Skill

**Phase start:** `write_status <slug> copy in_progress`

```bash
# Via task sub-agent with absolute paths
task --prompt "Generate carousel script for carousel '<slug>'.
Read brief: docs/carousels/<slug>/brief.yaml
Reference: voice profiles at reference/voice-profiles.md and copy playbook at reference/copy-playbook.md
Context from brief discussion:
- Tone: <tone from brief — e.g. 'confrontational but honest, bar conversation'>
- Constraints: <user constraints — e.g. 'no frameworks, short punchy lines'>
- Narrative arc: <arc — e.g. 'hook → problem → insight → CTA'>
- Audience: <audience from brief.yaml>
Generate V1 script, run internal review loop (tone, brand, structure reviewers).
Write script.yaml and script.md to docs/carousels/<slug>/"
```

Wait for completion. Read `quality_gate` from `script.yaml`.

**Phase complete:** `write_status <slug> copy complete`

### Step 3.4 — Validate Script Output (Structural Gate)

After copy completes, run structural validation before storyboarding:

```bash
node scripts/validate-script.cjs docs/carousels/$slug/script.yaml docs/carousels/$slug/brief.yaml
```

Checks (L1 — deterministic structural):
- Slide count matches brief.yaml
- Required fields per slide type (headline+subtitle for photo-hero, at least one of headline/body for text-slide)
- `image_template` assigned to every `needs_image: true` slide
- No placeholder text (TODO, TKTK)
- All emphasis words are short keywords (not full sentences)

On failure: feed structured errors back to copy skill for repair (max 2 retries). Block on field presence errors (P0). Warn on template assignment errors (P1).

### Step 3.5 — Storyboarding / Creative Concept (Human Gate)

**Phase start:** `write_status <slug> storyboard in_progress`

After copy is approved and humanized, decide the visual strategy for every slide BEFORE generating images. This step produces a storyboard that maps each slide to a visual treatment.

**This is a human gate.** The storyboard must be approved before proceeding to images.

**Process:**

1. Read the approved  — understand the narrative arc.
2. For each slide, decide:
   - **Slide type** — use the art-director slide type selection table (content type → recommended types). Available types: photo-hero, photo-top, cta, pilar, bento, comparison, stat, glass, cheatsheet, tutorial, quote, text-slide.
   - **Image template** — select from the template registry based on visual content. Write `image_template` per slide:
     
     | Slide context | `image_template` |
     |---------------|-----------------|
     | Founder portrait (portada, personal story, founder in environment) | `founder-portrait` |
     | Food/dish photography | `food-product` |
     | Restaurant/bar/café interior | `ambient-interior` |
     | Crowd/event/social gathering | `action-people` |
     | Text-only (quote, statistic, argument, framework, CTA without photo) | `text-graphic` |
     | Concept image — image IS the argument, makes you think (metaphor, illustration of a point) | `concept-image` |
     | Hook image — pure attention grab, makes you stop scrolling (curiosity, tension, surprise) | `hook-image` |
     
     Also write `needs_founder` for backward compat:
     - `needs_founder: true` when `image_template == "founder-portrait"`
     - `needs_founder: false` for all other templates
     - `needs_founder` is **deprecated** — new carousels SHOULD use `image_template` only. Old carousels without `image_template` will have `needs_founder` mapped by the images skill (Step 0).
   - **Image strategy** — derived from template: founder portrait, concept image, abstract/pattern, or text-only (needs_image: true/false). Templates with reference_images (founder-portrait) always have needs_image: true.
   - **Creative direction** — scene, mood, composition for slides needing images.

3. **Slide 1 hook strategy (explicit decision):** The hook slide should be decided deliberately, not defaulted. Options:
   - **Founder portrait** — intimate, personal, "I'm telling you this" (best when the belief is personal/opinionated)
   - **Concept image** — provocative, "what IS this?" (best when the concept is visual/novel, e.g., 11 archetypes framework)
   - **Bold text-only** — typographic, "this statement is strong enough alone" (best for a single powerful idea)
   - **Stat/data viz** — shocking number (best for data-driven stories)
   - **Split layout** — image left, text right (best when both visual and statement need equal weight)
   - **"Open loop" technique** — partial statement, creates curiosity gap ("#1 of 11", blurred result preview)
   - **Concept image** — image IS the argument, makes you think before reading (person at threshold, metaphor, illustration). Use `concept-image` template.
   - **Hook image** — pure attention grab, makes you stop scrolling (microwave countdown, watermelon drop, door opening). Use `hook-image` template.

4. Write updated  with finalized  and  per slide.

5. Present the storyboard to the user as a table:



**User confirms:** "/approve" or "/revise slide:N: [feedback]". On approval:

**Phase complete:** `write_status <slug> storyboard complete`

Proceed to Step 3.7 (Gate 1).

### Step 3.7 — Art Director Gate 1 (Pre-Render)

**Phase start:** `write_status <slug> gate1 in_progress`

After copy finalizes, validate design rules before images and rendering:

```bash
task --prompt "Run art-director Gate 1 (pre-render) for carousel at docs/carousels/<slug>/.
Read script.yaml. Validate:
1. Token hygiene (no raw hex values in build CSS)
2. Safe zone compliance (text placement, CTA position)
3. Typography limits (≤2 font families, ≤3 sizes/slide, heading ≥32px, body ≥20px)
Return pass/fail with specific issues. Gate blocks render on failure.
Note: image-script cross-reference runs at Gate 2 (post-images)."
```

**If Gate 1 fails:** `write_status <slug> gate1 failed "Gate 1 issues"` — return issues to user. Do NOT proceed.
**If Gate 1 passes:** `write_status <slug> gate1 complete`

Write immutable approved copy (#5051):
```bash
cp docs/carousels/<slug>/script.yaml docs/carousels/<slug>/approved-script.yaml
# Add approval metadata
node -e "
  const yaml = require('yaml'); const fs = require('fs'); const crypto = require('crypto');
  const file = 'docs/carousels/<slug>/approved-script.yaml';
  let doc = yaml.parse(fs.readFileSync(file, 'utf8'));
  doc.approved_at = new Date().toISOString();
  doc.content_hash = 'sha256:' + crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
  doc.approved_by = 'user';
  fs.writeFileSync(file + '.tmp', yaml.stringify(doc));
  fs.fsyncSync(fs.openSync(file + '.tmp', 'a'));
" && mv docs/carousels/<slug>/approved-script.yaml.tmp docs/carousels/<slug>/approved-script.yaml
```

Continue to Step 4.

### Step 4 — Dispatch Images Skill

**Phase start:** `write_status <slug> images in_progress`

After copy completes (sequential — images needs `script.yaml` for `creative_direction`):

```bash
task --prompt "Generate images for carousel '<slug>'.
Read script: docs/carousels/<slug>/script.yaml
Read character sheet: docs/carousels/character-sheet.yaml
Slides needing images: <list from script.yaml — slides with needs_image: true>
Image templates per slide: <from script.yaml — image_template field>
For founder-portrait slides: use OpenRouter with reference images from character-sheet.yaml Cloudinary URLs.
For concept-image slides: use Gemini MCP (gemini-generate-image).
Quality check per template rules. Upload to Cloudinary at eldato/carousels/<slug>/.
Write selected-images-pending.yaml with 2-3 options per slide.
Note: MCP servers required — dispatch with mcp_servers='supabase,ai-workflow-tools,context7,gemini,cloudinary'"
```

Wait for completion. Post composite preview grids to issue.

**Phase complete:** `write_status <slug> images complete`

### Step 4.5 — Automated Design Review

### Design Path Selection

Two design paths are available:


### Opus HTML Dispatch (#4633)

To dispatch Opus for carousel design, provide full context — the 2-3x quality improvement over CSS injection depends on it (#4646):
1. Approved copy (`script.yaml`)
2. Approved images (`selected-images.yaml`)  
3. Design direction (words describing aesthetic)
4. Reference carousel images (from `docs/carousels/approved/` catalog)
5. Brand brief: pin icon + "eldato" on every slide, purple/yellow colors, Outfit/Inter fonts
6. Safe zones: `tokens.json` (from `operations/skills/carousel-b2b-design/scripts/tokens.json` — contains 155px horizontal safe margin, canvas dimensions, typography limits)

Opus generates complete `carousel.html`. Then:
```bash
node operations/skills/carousel-b2b-design/scripts/render.cjs --input carousel.html --output slides/ --preview carousel-preview.html
```

<HARD-GATE id="copy-immutability">
**Copy Immutability Rule:** The design engine (Opus HTML, build_carousel.cjs, or any AI agent) may modify CSS, HTML structure, layout, typography, spacing, colors, and visual design. But copy text in `script.yaml` is the single source of truth — approved copy is immutable. The design engine MUST NOT:
- Change headlines, body text, or captions
- Shorten text to work around overflow bugs
- Reorder or restructure slide copy
- Modify hook text, slide numbers, or formatting within copy fields

Any copy change requires user approval. If a design constraint (overflow, legibility) makes copy changes tempting, flag the constraint as a P0 issue and present the proposed copy change to the user for explicit approval. Never modify copy silently.
</HARD-GATE>

The review loop: Opus sees rendered PNGs → critiques → regenerates HTML → repeats until clean. When clean, create `approved-caption.txt` with user-approved caption, then post via `ig-post-carousel.ts`.


**Opus HTML (primary — #4644):** Opus generates complete self-contained carousel.html with full creative control. Produces 2-3x better design quality than template-based rendering (#4590). Uses Playwright for PNG output. This is the default path — always try Opus first.

**build_carousel.cjs (template seed):** Static CSS template engine. Generates valid HTML structure with brand rules enforced (safe zones, gradient structure, byline format). carousel_designer (Opus) starts from this seed and refines via CSS iteration. Template-first + AI refinement is cheaper and more reliable than AI-from-scratch — deterministic HTML structure, sub-second generation, and brand consistency enforced at the template level.

<HARD-GATE id="universal-review">
**Review Loop Mandate:** EVERY carousel — Opus HTML or build_carousel.cjs — must go through the full review loop. No carousel is exempt based on complexity, template path, or agent judgment. The review loop includes:
1. carousel-designer: read_image on each slide PNG, critique against tokens.json
2. Linter: node linter.mjs on carousel.html
3. Art Director Gate 2: post-render QA

The agent MUST NOT skip review by claiming the carousel is "simple" or "good enough." If review-status.yaml blocks posting without review passing, the review MUST run — the gate exists to enforce this.



After images are generated and carousel is rebuilt, dispatch a GPT-4o design review on the rendered slides:

```bash
task --prompt "Run design review on rendered slides at docs/carousels/<slug>/slides-canonical/ using GPT-4o via OpenRouter (key in .env.local). Send each PNG as base64. Check: legibility, artifacts, brand colors, typography, composition. Output structured P0/P1/P2 issues. P0 issues block proceeding."
```

This catches contrast failures, rendering artifacts, and missing elements BEFORE the user sees them. Runs automatically — no user input needed.

### Step 5 — User Image Selection (Gate)

User selects images via structured comments:
```
/select slide:1 option:B
/select slide:3 option:A
```

Orchestrator echoes confirmation. On `/approve all` or `yes` → write `selected-images.yaml`.

**Image status tracking (#4574):** Every image in `selected-images.yaml` must carry a `status` field (`used` | `not_used` | `discarded`). The build script rejects `discarded` images with a hard error and skips `not_used` images with a warning. Only `used` images are rendered into slides.

### Step 6 — Dispatch Design (Opus HTML via carousel_designer)

**Phase start:** `write_status <slug> design in_progress`

The `carousel_designer` tool (Pi extension) handles the full design loop: build HTML → render PNGs → critique → fix → re-render → re-critique until clean. It reads script.yaml, selected-images.yaml, tokens.json, and design direction from brief.yaml.

```bash
# Via carousel_designer tool — single canonical dispatch
carousel_designer --carousel_dir docs/carousels/<slug>/ --design_direction "<direction from brief.yaml>"
```

The tool generates a Claude Opus prompt. Dispatch via:
```bash
task --prompt "$(cat /tmp/design-review-prompt-*.md)" --model "claude-opus-4-5"
```

Wait for clean exit (NO ISSUES FOUND on re-rendered PNGs).

**Fallback:** If Claude Opus is unavailable, build_carousel.cjs can render directly without AI refinement. Quality will be lower — the template provides structure but no visual polishing.

**Phase complete:** `write_status <slug> design complete`

### Step 6.5 — Art Director Gate 2 (Post-Render)

**Phase start:** `write_status <slug> gate2 in_progress`

After design renders PNGs, run post-render QA:

```bash
task --prompt "Run art-director Gate 2 (post-render) for carousel at docs/carousels/<slug>/.
The design skill has rendered PNGs to docs/carousels/<slug>/slides/.
Run:
1. linter.mjs: node skills/carousel-b2b-design/scripts/linter.mjs docs/carousels/<slug>/carousel.html
2. Visual regression: npx playwright test skills/carousel-b2b-design/scripts/visual-regression.spec.ts (if baselines exist)
3. carousel-designer: read_image on each slide PNG, critique against tokens.json (brand, typography, contrast, safe zones, composition, rendering)
4. Image-script cross-reference: every needs_image slide has an image in selected-images.yaml
Aggregate results. Return pass/fail with specific issues."
```


Before the Gate 2 task dispatch, verify cloudinary-urls.yaml exists and is current:
```bash
CLOUDINARY_FILE="docs/carousels/<slug>/cloudinary-urls.yaml"
CAROUSEL_HTML="docs/carousels/<slug>/carousel.html"
if [ ! -f "$CLOUDINARY_FILE" ]; then
  echo "❌ cloudinary-urls.yaml missing — render phase must upload slides to Cloudinary"
  write_status <slug> gate2 failed "cloudinary-urls.yaml missing"
  exit 1
fi
if [ "$CAROUSEL_HTML" -nt "$CLOUDINARY_FILE" ]; then
  echo "⚠️  cloudinary-urls.yaml is older than carousel.html — slides may be stale. Re-render."
fi
```

**If Gate 2 fails:** `write_status <slug> gate2 failed "<summary>"` — non-blocking (warns). Issues posted to tracking issue.
**If Gate 2 passes:** `write_status <slug> gate2 complete`

Gate 2 is non-blocking (warns). Issues are posted to the tracking issue for review.

### Step 7 — Delivery

Post final PNGs (Cloudinary URLs) + caption to issue. Generate `carousel-preview.html`. Set label to `content-created`.

## State Management

### status.yaml Schema

The pipeline state is tracked in `docs/carousels/<slug>/status.yaml`. This is the single source of truth — labels are derived.

```yaml
# docs/carousels/<slug>/status.yaml
schema_version: "1.0"
slug: <carousel-slug>
pipeline: carousel-b2b
created: <ISO8601>
updated: <ISO8601>
phases:
  strategy:    {status: pending, at: null, reason: null}
  copy:        {status: pending, at: null, reason: null}
  storyboard:  {status: pending, at: null, reason: null}
  gate1:       {status: pending, at: null, reason: null}
  images:      {status: pending, at: null, reason: null}
  design:      {status: pending, at: null, reason: null}
  gate2:       {status: pending, at: null, reason: null}
current_phase: strategy
```

**Phase status values:** `pending | in_progress | complete | skipped | failed`

### Atomic Write Protocol

**ALWAYS write to `status.yaml.tmp` first, then `mv status.yaml.tmp status.yaml`.** A same-filesystem `mv` is atomic — it either completes or leaves the original file intact. Never write directly to `status.yaml`.

```bash
# CORRECT — atomic
node -e "..." > "docs/carousels/$slug/status.yaml.tmp" && mv "docs/carousels/$slug/status.yaml.tmp" "docs/carousels/$slug/status.yaml"

# WRONG — can leave a half-written file on crash
node -e "..." > "docs/carousels/$slug/status.yaml"
```

### current_phase Invariant

On every status.yaml load, derive `current_phase` from phase statuses (first phase where status ≠ `complete` and ≠ `skipped`). If the stored `current_phase` field differs from the derived value, auto-correct and warn:

```
⚠️ current_phase corrected: stored=copy, derived=humanizer
```

This invariant prevents drift between the explicit field and the ground-truth phase statuses.

### Phase Status Writes

Every orchestrator step writes status via `write_status <slug> <phase> <status> [reason]`:

| Event | Command |
|-------|---------|
| Phase starts | `write_status <slug> <phase> in_progress` |
| Phase completes | `write_status <slug> <phase> complete` |
| Phase skipped | `write_status <slug> <phase> skipped "<reason>"` |
| Phase fails | `write_status <slug> <phase> failed "<reason>"` |

The `write_status` helper (defined in §Process → Status Tracking Protocol):
- Sets the phase's `status`, `at` (timestamp on complete/failed), and `reason` (on skipped/failed)
- Updates `updated` to now
- Derives `current_phase` from phase statuses
- Writes to `.tmp`, `fsync`, then `mv` (atomic)

### Labels

Labels are derived from status.yaml, not set manually.

Labels lifecycle: `content-creating` → `content-created` → `content-reviewing` → `content-ready`

Self-clean stale `content-creating` labels at startup. Resume from `status.yaml` when re-invoked with same slug.

## Command Grammar

| Command | Scope | Description |
|---------|-------|-------------|
| `/select slide:N option:X` | Image selection | Pick image option for slide N |
| `/approve` | Copy, Final review | Approve current step |
| `/approve all` | Image selection | Approve all pending slides |
| `/approve with changes: [notes]` | Copy, Final | Approve with revision notes |
| `/regenerate slide:N type:image\|copy` | Any | Regenerate with optional `changes:"..." count:N` |
| `/revise slide:N: [feedback]` | Copy | Request specific revisions |
| `/undo` | After /select, /regenerate | Revert last command (1 level) |
| `/cancel` | Any | Abort entire pipeline |
| `/retry` | Error state | Re-attempt last failed operation |
| `/resume-from slide:N` | Error state | Resume from slide N |
| `/mode A\|B\|C` | Any | Switch pipeline mode |
| `/save slide:N option:X category:... tags:...` | Image selection | Save unused option for reuse |
| `/help` | Any | Show all commands |

## Status Updates

Canonical format: `[EMOJI] [Phase]: [Status] — [Detail]`

Examples:
- `📝 Strategy: Creating brief...`
- `✅ Copy: Cycle 2 — Clean ✓`
- `🖼️ Images: 3/5 slides generated`
- `🎨 Design: Cycle 1 — 4 issues → fixing...`
- `🔍 Art Director Gate 1: PASS — tokens, safe zones, typography ✓`
- `⚠️ Art Director Gate 2: 3 issues (P1×2 contrast, P2×1 safezones) — non-blocking`
- `✅ Carousel complete! 10 slides ready`

## Interactive Refinement

The orchestrator runs in your main chat session. After copy/images are generated, you can brainstorm in chat:
- "Give me 3 alternatives for slide 3's headline"
- "What if we swap slides 4 and 5?"
- "Make the tone more aggressive on slide 7"

The orchestrator edits files directly or dispatches focused sub-agents. This mirrors the Claude-web workflow: chat is the brainstorming surface, sub-agents handle heavy lifting.

## Reference

- [Creative Brief Template](reference/creative-brief-template.md)
- [Voice Profiles](reference/voice-profiles.md)
- [Epic Doc](../../../docs/teams/organisation-design-team/domains (S1)/capability/2026-06-16-carousel-skill.md) — eldato repo (fetch: `gh api repos/daniel-ospina/eldato/contents/<path> --jq .content | base64 -d`)
- [Research Brief](../../../docs/teams/organisation-design-team/domains (S1)/capability/2026-06-16-carousel-skill-research.md) — eldato repo (fetch: `gh api repos/daniel-ospina/eldato/contents/<path> --jq .content | base64 -d`)

- [Instagram Auth Reference](reference/instagram-auth.md)
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
