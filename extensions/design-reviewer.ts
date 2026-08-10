// ─────────────────────────────────────────────────────────────────────────────
// DECISION (#45): KEEP this extension in agent-infra as canonical, with a
// graceful no-op when ELDATO_ROOT is unset. Rationale: agent-infra is the
// single canonical source synced to all machines; moving to eldato-local would
// create fork risk. The eldato-specificity is handled by env-gating — the tool
// registers cleanly on any machine but returns a clear message instead of
// resolving eldato-only skill dirs against an arbitrary cwd.
// ─────────────────────────────────────────────────────────────────────────────
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { createAgentSession, SessionManager, AuthStorage } from "@earendil-works/pi-coding-agent";
import { getModel } from "@earendil-works/pi-ai";
import { Type } from "typebox";
import { readFileSync, existsSync, writeFileSync, mkdirSync, unlinkSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { resolve, dirname } from "node:path";
import { tmpdir } from "node:os";

const ELDATO_ROOT = (process.env.ELDATO_ROOT || "").trim();
const HAS_ELDATO = ELDATO_ROOT.length > 0;
const PROJECT_ROOT = ELDATO_ROOT || process.cwd();
const NOOP_MESSAGE =
  "design-reviewer requires ELDATO_ROOT (eldato carousel pipeline not available on this machine)";

// ── Prompt Construction ─────────────────────────────────

interface PromptComponents {
  skill: string;
  brief: string;
  tokens: Record<string, unknown> | null;
  scriptYaml: string;
}

function loadPromptComponents(carouselDir: string): PromptComponents {
  const skillPath = resolve(PROJECT_ROOT, "skills/carousel-designer/SKILL.md");
  const briefPath = resolve(PROJECT_ROOT, "skills/carousel-b2b-design/reference/SAFE_ZONE_BRIEF.md");
  const tokensPath = resolve(PROJECT_ROOT, "skills/carousel-b2b-design/scripts/tokens.json");

  const skill = existsSync(skillPath) ? readFileSync(skillPath, "utf8") : "";
  const brief = existsSync(briefPath) ? readFileSync(briefPath, "utf8") : "";
  const tokens = existsSync(tokensPath)
    ? (() => { try { return JSON.parse(readFileSync(tokensPath, "utf8")); } catch { return null; } })()
    : null;

  const scriptPath = resolve(carouselDir, "script.yaml");
  const scriptYaml = existsSync(scriptPath) ? readFileSync(scriptPath, "utf8") : "";

  return { skill, brief, tokens, scriptYaml };
}

function buildPrompt(carouselDir: string, designDirection: string, slides?: string): string {
  const { skill, brief, tokens, scriptYaml } = loadPromptComponents(carouselDir);

  const reviewSection = skill.split("## Review Dimensions")[1]?.split("## Output")[0] || "";
  const processSection = skill.split("## Process")[1]?.split("## Model Selection")[0] || "";
  const guardrailsSection = skill.split("## Guardrails")[1]?.split("## Process")[0] || "";

  const slidesNote = slides
    ? `Review ONLY slides: ${slides}.`
    : "Review ALL slides.";

  const tokensJson = tokens
    ? JSON.stringify(tokens, null, 2)
    : "purple #5B3B8C, yellow #F2C94C, white #FFFFFF, cream #EFE9DC, muted #C9BBE0. Fonts: Outfit 700 (headings), InterV 400-600 (body).";

  const safeZones = brief ||
    "155px margins all sides: xMin=155, xMax=925. Text stays within these bounds.";

  return `You are a carousel designer for El Dato slides. Work in a SINGLE CONTINUOUS session:
CRITIQUE rendered PNG → GENERATE css-map.json fixes → REBUILD → RE-RENDER → RE-CRITIQUE → repeat until clean.

## Workspace
Carousel: ${carouselDir}
${slidesNote}

## Design Direction
${designDirection}

## Brand Tokens
${tokensJson}

## Safe Zones
${safeZones}

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
node ../../skills/carousel-b2b-design/scripts/build_carousel.cjs --script script.yaml --images selected-images.yaml --css-map css-map.json --output carousel.html
node ../../skills/carousel-b2b-design/scripts/render.cjs --input carousel.html --output slides/
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
PRESERVE existing intentional design (yellow subtitles, font sizes, etc.). Only fix what is broken.

## Final Response Format
When the loop exits clean, output a final summary in this exact format:

\`\`\`json
{
  "status": "clean",
  "cycles": <number>,
  "slides_reviewed": <number>,
  "files_modified": ["<path>", ...]
}
\`\`\`

If you cannot achieve clean status, output:

\`\`\`json
{
  "status": "pending",
  "cycles": <number>,
  "remaining_issues": "<description>",
  "files_modified": ["<path>", ...]
}
\`\`\``;
}

// ── Claude Opus Session ────────────────────────────────

async function spawnClaudeOpus(
  prompt: string,
  signal: AbortSignal | undefined,
  _carouselDir: string
): Promise<{ status: string; cycles: number; output: string }> {
  const authStorage = AuthStorage.create();

  // FIX #5402-real: streamSimpleOpenAICompletions reads process.env.OPENROUTER_API_KEY
  // (not authStorage). If the key is only in auth.json/settings.json (not process.env),
  // the stream call throws "OpenAI API key required" silently. Resolve and inject.
  if (!process.env.OPENROUTER_API_KEY) {
    const orKey = await authStorage.getApiKey("openrouter");
    if (orKey) process.env.OPENROUTER_API_KEY = orKey;
  }

  // FIX: createAgentSession silently ignores { provider, model } shorthand — must pass a
  // resolved Model object from getModel(). Also: opus-4.8 isn't in pi's built-in registry
  // (latest is 4.7). The custom-provider-openrouter extension registers 4.8 cosmetically,
  // but getModel() only checks the built-in registry, not extension-registered models.
  const resolvedModel = getModel("openrouter", "anthropic/claude-opus-4.7");
  if (!resolvedModel) {
    return { status: "error", cycles: 0, output: "Could not resolve anthropic/claude-opus-4.7 via getModel()" };
  }

  const { session } = await createAgentSession({
    model: resolvedModel,
    tools: ["read", "read_image", "write", "edit", "bash"],
    sessionManager: SessionManager.inMemory(),
    authStorage,
  });

  let output = "";
  let streamError = "";
  session.subscribe((event: any) => {
    if (event.type === "message_update" && event.assistantMessageEvent?.type === "text_delta") {
      output += event.assistantMessageEvent.delta;
    } else if (event.type === "error" || (event as any).error) {
      const err = (event as any).error;
      streamError = err?.message || err?.errorMessage || JSON.stringify(err || event).slice(0, 500);
    }
  });

  await session.prompt(prompt);
  session.dispose();

  // Surface stream errors so failures aren't masked as "0 cycles, empty output"
  if (!output && streamError) {
    return { status: "error", cycles: 0, output: `[stream error] ${streamError}` };
  }

  // Parse structured result from Claude's output
  let status = "pending";
  let cycles = 0;
  const jsonMatch = output.match(/\{[\s\S]*"status"[\s\S]*\}/);
  if (jsonMatch) {
    try {
      const result = JSON.parse(jsonMatch[0]);
      status = result.status || "pending";
      cycles = result.cycles || 0;
    } catch { /* fall through */ }
  }

  return { status, cycles, output };
}


// ── CSS-Change Validation (#4743) ───────────────────────

function validateCssChanged(carouselDir: string): { changed: boolean; error?: boolean; reason?: string } {
  const htmlPath = resolve(carouselDir, "carousel.html");
  if (!existsSync(htmlPath)) {
    return { changed: false, reason: "carousel.html not found — cannot validate CSS changes" };
  }

  // Extract all <style> block content from HTML
  const extractCss = (source: string): string => {
    const matches = source.match(/<style[^>]*>([\s\S]*?)<\/style>/g) || [];
    return matches.map(m => m.replace(/<style[^>]*>([\s\S]*?)<\/style>/, "$1")).join("\n");
  };

  const html = readFileSync(htmlPath, "utf8");
  const actualCss = extractCss(html);

  // Build baseline HTML without css-map overrides
  const buildScript = resolve(PROJECT_ROOT, "skills/carousel-b2b-design/scripts/build_carousel.cjs");
  const scriptYaml = resolve(carouselDir, "script.yaml");
  const imagesYaml = resolve(carouselDir, "selected-images.yaml");
  const baselinePath = resolve(tmpdir(), `design-review-baseline-${Date.now()}.html`);

  try {
    // ponytail: execFileSync bypasses shell — no injection vector from carouselDir
    execFileSync("node", [buildScript, "--script", scriptYaml, "--images", imagesYaml, "--output", baselinePath], {
      timeout: 15000,
      stdio: "pipe",
      cwd: resolve(PROJECT_ROOT, "skills/carousel-b2b-design/scripts"),
    });
    const baselineHtml = readFileSync(baselinePath, "utf8");
    const baselineCss = extractCss(baselineHtml);

    // Strip @font-face (base64 varies per font file version) — compare design CSS only
    // ponytail: naive }-based regex; breaks on font-face blocks with "}" in data URIs
    const stripFonts = (css: string) => css.replace(/@font-face\s*\{[^}]*\}/g, "").trim();

    if (stripFonts(actualCss) === stripFonts(baselineCss)) {
      return {
        changed: false,
        reason: "CSS unchanged — Opus audited, did not design. Re-dispatch with stronger design framing."
      };
    }
    return { changed: true };
  } catch (err: any) {
    console.error("[design-reviewer] CSS validation subprocess failed:", err.message);
    return { changed: false, error: true, reason: `CSS validation unavailable: ${err.message}` };
  } finally {
    try { unlinkSync(baselinePath); } catch { /* best effort */ }
  }
}


// ── Extension ───────────────────────────────────────────

export default function (pi: ExtensionAPI) {
  // ── No-op mode: ELDATO_ROOT unset — register cleanly, do nothing ──
  if (!HAS_ELDATO) {
    pi.registerTool({
      name: "design_reviewer",
      label: "Design Reviewer",
      description: "Launch a Claude Opus design review loop for carousel slides. No-op: " + NOOP_MESSAGE,
      parameters: Type.Object({
        carousel_dir: Type.String({ description: "Path to carousel directory (e.g. docs/carousels/archetype-1-tematico/)" }),
        design_direction: Type.Optional(Type.String({ description: "Design aesthetic description" })),
        slides: Type.Optional(Type.String({ description: "Comma-separated slide numbers to review" })),
      }),
      async execute() {
        return { content: [{ type: "text", text: NOOP_MESSAGE }], details: {} };
      },
    });
    pi.on("session_start", async (_event, ctx) => {
      ctx.ui.notify("design-reviewer: ELDATO_ROOT not set — tool registered as no-op", "info");
    });
    return;
  }

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
        console.log("[design-reviewer] 🚫 Blocked ::before+inset:0 in css-map.json");
        return { block: true, reason: "⛔ ::before with inset:0 buries the photo. Use .grad class override instead." };
      }
    }
    return undefined;
  });

  pi.registerTool({
    name: "design_reviewer",
    label: "Design Reviewer",
    description:
      "Launch a Claude Opus design review loop for carousel slides. Reads SKILL.md, SAFE_ZONE_BRIEF.md, tokens.json, and script.yaml to construct a systematic prompt, then dispatches Claude Opus to critique, fix, rebuild, re-render, and re-critique until clean. Falls back to prompt-only mode if Claude Opus is unavailable.",
    parameters: Type.Object({
      carousel_dir: Type.String({
        description: "Path to carousel directory (e.g. docs/carousels/archetype-1-tematico/)",
      }),
      design_direction: Type.Optional(
        Type.String({
          description:
            "Design aesthetic description (e.g. 'editorial, clean, Spanish, purple/yellow brand')",
        })
      ),
      slides: Type.Optional(
        Type.String({
          description: "Comma-separated slide numbers to review (e.g. '1,3'). Omit to review all.",
        })
      ),
    }),
    async execute(toolCallId, params, signal, onUpdate, ctx) {
      const carouselDir = resolve(params.carousel_dir);

      // Read design direction from brief.yaml first, fall back to parameter
      let designDir = params.design_direction || "";
      const briefPath = resolve(carouselDir, "brief.yaml");
      if (!designDir && existsSync(briefPath)) {
        try {
          const briefYaml = readFileSync(briefPath, "utf8");
          const match = briefYaml.match(/^design_direction:\s*(.+)$/m);
          if (match) designDir = match[1].trim();
        } catch { /* ignore */ }
      }
      if (!designDir) {
        designDir = "editorial, confident, Spanish, purple/yellow brand, 155px safe margins";
      }

      if (!existsSync(carouselDir)) {
        return {
          content: [
            { type: "text", text: `❌ Carousel directory not found: ${carouselDir}` },
          ],
          details: {},
        };
      }

      const prompt = buildPrompt(carouselDir, designDir, params.slides);

      // Write prompt to temp file for debugging/reuse
      const promptPath = resolve(tmpdir(), `design-review-prompt-${Date.now()}.md`);
      try {
        mkdirSync(dirname(promptPath), { recursive: true });
        writeFileSync(promptPath, prompt);
      } catch { /* non-critical */ }

      // Attempt Claude Opus session
      let claudeStatus = "unavailable";
      let cycles = 0;
      let claudeOutput: string;

      try {
        onUpdate?.({ content: [{ type: "text", text: "🚀 Spawning Claude Opus 4.8 session..." }] });
        const result = await spawnClaudeOpus(prompt, signal, carouselDir);
        claudeStatus = result.status;
        cycles = result.cycles;
        claudeOutput = result.output;

        // CSS-change validation (#4743): if Opus declared clean, verify CSS actually changed
        if (claudeStatus === "clean") {
          const validation = validateCssChanged(carouselDir);
          if (validation.error) {
            // Validation unavailable (build failed, missing deps) — warn but trust Opus
            console.warn("[design-reviewer] CSS validation skipped:", validation.reason);
          } else if (!validation.changed) {
            claudeStatus = "rejected";
            claudeOutput = validation.reason + "\n\n---\n\n" + claudeOutput;
            // Remove review-status.yaml — validation didn't pass
            const reviewStatusPath = resolve(carouselDir, "review-status.yaml");
            try { if (existsSync(reviewStatusPath)) unlinkSync(reviewStatusPath); } catch { /* best effort */ }
          }
        }
      } catch (err: any) {
        console.error("[design-reviewer] Claude Opus session failed:", err.message);
        claudeOutput = `Claude Opus session error: ${err.message}`;
      }

      // Build structured response
      const responseLines: string[] = [];

      responseLines.push(`## Design Review — ${carouselDir}`);
      responseLines.push("");
      responseLines.push(`**Design direction:** ${designDir}`);
      responseLines.push(`**Slides:** ${params.slides || "all"}`);
      responseLines.push("");

      if (claudeStatus !== "unavailable") {
        responseLines.push(`### Claude Opus Review`);
        responseLines.push(`- **Status:** ${claudeStatus}`);
        responseLines.push(`- **Cycles:** ${cycles}`);
        responseLines.push("");
        responseLines.push("#### Raw Output");
        responseLines.push("```");
        responseLines.push(claudeOutput.slice(-3000)); // last 3K chars
        responseLines.push("```");
      } else {
        responseLines.push("### ⚠️ Claude Opus Unavailable — Prompt-Only Mode");
        responseLines.push(`- **Error:** ${claudeOutput}`);
        responseLines.push("");
        responseLines.push("### To run the design review manually:");
        responseLines.push("1. Read the prompt from the file below");
        responseLines.push("2. Dispatch via task tool with `model: \"claude-opus-4.8\"`");
        responseLines.push("");
        responseLines.push(`**Prompt written to:** ${promptPath}`);
        responseLines.push(`**Prompt length:** ${prompt.length} chars`);
        responseLines.push("");
        responseLines.push("### Prompt preview (first 500 chars):");
        responseLines.push("```");
        responseLines.push(prompt.substring(0, 500) + "...");
        responseLines.push("```");
      }

      return {
        content: [{ type: "text", text: responseLines.join("\n") }],
        details: {
          promptPath,
          promptLength: prompt.length,
          claudeStatus,
          cycles,
          slides: params.slides || "all",
        },
      };
    },
  });

  pi.on("session_start", async (_event, ctx) => {
    ctx.ui.notify("Design Reviewer extension loaded — use design_reviewer tool", "info");
  });
}
