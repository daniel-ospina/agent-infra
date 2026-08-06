import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { readFileSync, existsSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";

const PROJECT_ROOT = process.env.ELDATO_ROOT || process.cwd();

function loadPromptComponents(carouselDir: string) {
  const skillPath = resolve(PROJECT_ROOT, ".agents/skills/carousel-designer/SKILL.md");
  const briefPath = resolve(PROJECT_ROOT, ".agents/skills/carousel-b2b-design/reference/SAFE_ZONE_BRIEF.md");
  const tokensPath = resolve(PROJECT_ROOT, ".agents/skills/carousel-b2b-design/scripts/tokens.json");
  
  const skill = existsSync(skillPath) ? readFileSync(skillPath, 'utf8') : '';
  const brief = existsSync(briefPath) ? readFileSync(briefPath, 'utf8') : '';
  const tokens = existsSync(tokensPath) ? (() => { try { return JSON.parse(readFileSync(tokensPath, 'utf8')); } catch { return null; } })() : null;
  
  const scriptPath = resolve(carouselDir, 'script.yaml');
  const scriptYaml = existsSync(scriptPath) ? readFileSync(scriptPath, 'utf8') : '';
  
  return { skill, brief, tokens, scriptYaml };
}

function buildPrompt(carouselDir: string, designDirection: string, slides?: string) {
  const { skill, brief, tokens, scriptYaml } = loadPromptComponents(carouselDir);
  
  const reviewSection = skill.split('## Review Dimensions')[1]?.split('## Output')[0] || '';
  if (!reviewSection) console.log('[carousel-designer] ⚠ Review Dimensions section not found in SKILL.md');
  const processSection = skill.split('## Process')[1]?.split('## Model Selection')[0] || '';
  if (!processSection) console.log('[carousel-designer] ⚠ Process section not found in SKILL.md');
  const guardrailsSection = skill.split('## Guardrails')[1]?.split('## Process')[0] || '';
  
  const slidesNote = slides 
    ? `Review ONLY slides: ${slides}.` 
    : 'Review ALL slides.';
  
  return `You are a carousel designer for El Dato slides. Work in a SINGLE CONTINUOUS session:
CRITIQUE rendered PNG → GENERATE css-map.json fixes → REBUILD → RE-RENDER → RE-CRITIQUE → repeat until clean.

## Workspace
Carousel: ${carouselDir}
${slidesNote}

## Design Direction
${designDirection}

## Brand Tokens
${tokens ? JSON.stringify(tokens, null, 2) : 'purple #5B3B8C, yellow #F2C94C, white #FFFFFF, cream #EFE9DC, muted #C9BBE0. Fonts: Outfit 700 (headings), InterV 400-600 (body).'}

## Safe Zones
${brief || '155px margins all sides: xMin=155, xMax=925. Text stays within these bounds.'}

## Approved Copy (DO NOT EDIT TEXT)
\`\`\`yaml
${scriptYaml}
\`\`\`

${processSection}

${guardrailsSection}

${reviewSection}

## Build Commands
\`\`\`bash
cd ${carouselDir}
node ../../../operations/skills/carousel-b2b-design/scripts/build_carousel.cjs --script script.yaml --images selected-images.yaml --css-map css-map.json --output carousel.html
node ../../../operations/skills/carousel-b2b-design/scripts/render.cjs --input carousel.html --output slides/
\`\`\`

## LOOP RULE (MANDATORY — DO NOT VIOLATE)

You are NOT done when you generate CSS fixes. You are done ONLY when:

1. You have REBUILT and RE-RENDERED the slides with your fixes applied
2. You have RE-READ the re-rendered PNGs with read_image
3. Your re-critique of the re-rendered PNGs returns NO ISSUES FOUND

If step 3 finds ANY issue → go back to fix, rebuild, re-render, re-read, re-critique.
Minimum 1 full cycle (even if you think your fixes are obviously correct).
No maximum — loop until clean. No cycle cap.

A fix without re-critique on re-rendered output IS NOT A LOOP.

## CSS Fixes
Modify only css-map.json. Keys are 0-indexed slide indices.
DO NOT modify script.yaml text (only scrim_override fields).
Output "NO ISSUES FOUND" when all reviewed slides pass.
Write review-status.yaml when clean.

## Gradient Constraints (MANDATORY)

1. Use ONLY the \`.grad\` class for overlay gradients. NEVER use \`::before\` with \`inset: 0\` or any pseudo-element gradient workaround.
2. Photo MUST be visible through the gradient. There must be a clear transparent band (≤10% opacity) at 60–70% height so the image's focal point is visible.
3. Maximum top opacity: 75%. Higher = buried photo, rejected.
4. Gradient MUST NOT be uniform — must fade through multiple stops (not solid color at any point).

## Preserve Intentional Design
PRESERVE existing intentional design (yellow subtitles, font sizes, etc.). Only fix what is broken.`;
}

export default function (pi: ExtensionAPI) {
  // ── Hook: block ::before + inset:0 in css-map.json ──
  pi.on("tool_call", async (event, _ctx) => {
    if (event.toolName !== "write" && event.toolName !== "edit") return undefined;
    const input = event.input as any;
    if (!input?.path?.includes("css-map.json")) return undefined;

    const texts: string[] = [];
    if (input.content) texts.push(input.content);
    if (input.edits) for (const e of input.edits) if (e.newText) texts.push(e.newText);

    for (const t of texts) {
      if (t.includes("::before") && t.includes("inset: 0")) {
        console.log("[carousel-designer] 🚫 Blocked ::before+inset:0 in css-map.json");
        return { block: true, reason: "⛔ ::before with inset:0 buries the photo. Use .grad class override instead." };
      }
    }
    return undefined;
  });


  pi.registerTool({
    name: "carousel_designer",
    label: "Design Reviewer",
    description: "Launch a Claude Opus design review loop for carousel slides. Reads SKILL.md, SAFE_ZONE_BRIEF.md, tokens.json, and script.yaml to construct a systematic prompt, then dispatches Claude Opus to critique, fix, rebuild, re-render, and re-critique until clean.",
    parameters: Type.Object({
      carousel_dir: Type.String({ description: "Path to carousel directory (e.g. docs/carousels/archetype-1-tematico/)" }),
      design_direction: Type.Optional(Type.String({ description: "Design aesthetic description (e.g. 'editorial, clean, Spanish, purple/yellow brand')" })),
      slides: Type.Optional(Type.String({ description: "Comma-separated slide numbers to review (e.g. '1,3'). Omit to review all." })),
    }),
    async execute(toolCallId, params, signal, onUpdate, ctx) {
      const carouselDir = resolve(params.carousel_dir);
      
      // Read design direction from brief.yaml first, fall back to parameter, warn if both absent
      let designDir = params.design_direction || '';
      const briefPath = resolve(carouselDir, 'brief.yaml');
      if (!designDir && existsSync(briefPath)) {
        try {
          const briefYaml = readFileSync(briefPath, 'utf8');
          const match = briefYaml.match(/^design_direction:\s*(.+)$/m);
          if (match) designDir = match[1].trim();
        } catch { /* non-critical: brief.yaml parsing is optional */ }
      }
      if (!designDir) {
        console.warn('[carousel-designer] ⚠️ No design_direction in brief.yaml or parameter — using generic fallback.');
        designDir = 'editorial, confident, Spanish, purple/yellow brand, 155px safe margins';
      }
      
      if (!existsSync(carouselDir)) {
        return { content: [{ type: "text", text: `❌ Carousel directory not found: ${carouselDir}` }], details: {} };
      }
      
      const prompt = buildPrompt(carouselDir, designDir, params.slides);
      
      // Write prompt for the orchestrator to use
      const promptPath = resolve(tmpdir(), `design-review-prompt-${Date.now()}.md`);
      try { writeFileSync(promptPath, prompt); } catch (e) {
        return { content: [{ type: "text", text: `❌ Failed to write prompt: ${e.message}` }], details: {} };
      }

      return {
        content: [{ type: "text", text: `## Design Review Prompt Generated

**Carousel:** ${carouselDir}
**Slides:** ${params.slides || 'all'}
**Design direction:** ${designDir}

### Prompt written to: ${promptPath}

### To dispatch Claude Opus:
\`\`\`
Read the prompt from ${promptPath} and dispatch via task tool
\`\`\`

### Prompt preview (first 500 chars):
${prompt.substring(0, 500)}...` }],
        details: { promptPath, promptLength: prompt.length },
      };
    },
  });

  pi.on("session_start", async (_event, ctx) => {
    ctx.ui.notify("Design Reviewer extension loaded — use carousel_designer tool", "info");
  });
}
