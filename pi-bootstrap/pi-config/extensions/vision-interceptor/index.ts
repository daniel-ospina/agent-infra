/**
 * Vision Interceptor Extension for pi
 *
 * Intercepts pasted/dropped images (Ctrl+V) before they reach the LLM and
 * describes them using a vision-capable model. This lets non-vision models
 * (like DeepSeek v4) "see" images by receiving text descriptions instead.
 *
 * Also registers a `read_image` tool for on-demand image reading from files.
 *
 * Supported vision backends (auto-detected, or set VISION_PROVIDER env var):
 *   - openrouter — OpenRouter (OpenAI-compatible, uses OPENROUTER_API_KEY)
 *   - anthropic — Claude API
 *   - openai    — OpenAI GPT-4V
 *
 * Usage:
 *   1. Set: export OPENROUTER_API_KEY=sk-or-...
 *   2. Paste images with Ctrl+V in pi
 *   3. The extension auto-describes them before DeepSeek sees them
 */

import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { StringEnum } from "@mariozechner/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

// ── Configuration ──────────────────────────────────────────────────

interface VisionConfig {
  /** Which provider to use: "openrouter" | "anthropic" | "openai" | "auto" */
  provider: string;
  /** Model ID (provider-specific). If unset, uses default for provider. */
  model?: string;
  /** Environment variable name for the API key */
  apiKeyEnv?: string;
}

const DEFAULT_CONFIG: VisionConfig = {
  provider: "auto",
  model: undefined,
};

/** Load config from JSON files (global + project merged) */
function loadConfig(cwd: string): VisionConfig {
  const paths = [
    resolve(cwd, ".pi", "extensions", "vision-interceptor.json"),
    resolve(cwd, ".pi", "vision-interceptor.json"),
    resolve(process.env.HOME || "~", ".pi", "agent", "extensions", "vision-interceptor.json"),
  ];

  let config = { ...DEFAULT_CONFIG };

  for (const p of paths) {
    try {
      if (existsSync(p)) {
        const raw = JSON.parse(readFileSync(p, "utf-8"));
        config = { ...config, ...raw };
      }
    } catch {
      // skip unreadable files
    }
  }

  // Env var overrides everything
  if (process.env.VISION_PROVIDER) config.provider = process.env.VISION_PROVIDER;
  if (process.env.VISION_MODEL) config.model = process.env.VISION_MODEL;

  return config;
}

/** Read an env var from shell config files as fallback */
function readFromShellConfig(varName: string): string | undefined {
  const configPaths = [
    resolve(process.env.HOME || "~", ".zshrc"),
    resolve(process.env.HOME || "~", ".bashrc"),
    resolve(process.env.HOME || "~", ".bash_profile"),
    resolve(process.env.HOME || "~", ".profile"),
  ];
  for (const configPath of configPaths) {
    try {
      if (existsSync(configPath)) {
        const content = readFileSync(configPath, "utf-8");
        const match = content.match(
          new RegExp(`export\\s+${varName}\\s*=\\s*["']?([^"'\\n]+)["']?`),
        );
        if (match) return match[1].trim();
      }
    } catch {
      // skip unreadable files
    }
  }
  return undefined;
}

/** Auto-detect which vision provider to use based on available API keys */
function detectProvider(): "openrouter" | "anthropic" | "openai" | null {
  // ponytail: OpenRouter first (preferred), then Anthropic, then OpenAI
  if (process.env.OPENROUTER_API_KEY || readFromShellConfig("OPENROUTER_API_KEY")) return "openrouter";
  if (process.env.ANTHROPIC_API_KEY || readFromShellConfig("ANTHROPIC_API_KEY")) return "anthropic";
  if (process.env.OPENAI_API_KEY || readFromShellConfig("OPENAI_API_KEY")) return "openai";
  return null;
}

function getProviderConfig(config: VisionConfig): {
  provider: "openrouter" | "anthropic" | "openai";
  model: string;
  apiKey: string;
} | null {
  let provider = config.provider as string;
  if (provider === "auto") {
    const detected = detectProvider();
    if (!detected) return null;
    provider = detected;
  }

  let apiKey: string | undefined;
  let defaultModel: string;

  switch (provider) {
    case "openrouter":
      apiKey = process.env.OPENROUTER_API_KEY || readFromShellConfig("OPENROUTER_API_KEY");
      defaultModel = "openai/gpt-4o";
      break;
    case "anthropic":
      apiKey = process.env.ANTHROPIC_API_KEY || readFromShellConfig("ANTHROPIC_API_KEY");
      defaultModel = "claude-sonnet-4-5";
      break;
    case "openai":
      apiKey = process.env.OPENAI_API_KEY || readFromShellConfig("OPENAI_API_KEY");
      defaultModel = "gpt-4o";
      break;
    default:
      return null;
  }

  if (!apiKey) return null;

  return {
    provider: provider as "openrouter" | "anthropic" | "openai",
    model: config.model || defaultModel,
    apiKey,
  };
}

// ── Image Type Helpers ─────────────────────────────────────────────

interface ImageSource {
  type: "base64";
  mediaType: string;
  data: string;
}

interface ImageContent {
  type: "image";
  source: ImageSource;
}

function isImageContent(item: unknown): item is ImageContent {
  if (!item || typeof item !== "object") return false;
  const img = item as Record<string, unknown>;
  return (
    img.type === "image" &&
    typeof img.source === "object" &&
    img.source !== null &&
    (img.source as Record<string, unknown>).type === "base64" &&
    typeof (img.source as Record<string, unknown>).data === "string"
  );
}

// ── Vision API Calls ──────────────────────────────────────────────

const VISION_PROMPT = `Describe this image in thorough detail. Include:
- All visible text, code, error messages, or terminal output (transcribe verbatim)
- UI elements, layouts, and visual structure
- Colors, styling, and visual highlights
- Any relevant context that would help someone who can't see the image

Be precise and thorough. The description will be used by another AI as a substitute for seeing the image directly.`;

const DESIGN_CRITIQUE_PROMPT = `Critique this image as a carousel slide design reviewer. Evaluate:

1. BRAND: Colors match El Dato tokens? (purple #5B3B8C, yellow #F2C94C, white #FFFFFF, cream #EFE9DC). Yellow used for emphasis only, not body text. Raw hex values without token mapping?

2. TYPOGRAPHY: Outfit for headings (700 weight, min 32px). Inter for body (400-700, min 20px). Max 2 font families. Max 5 distinct font sizes per slide.

3. CONTRAST: Text-on-background >= 4.5:1. White/yellow text on purple legible? Photo overlay gradients sufficient?

4. SAFE ZONES (1080x1080 canvas): Text within X:35-1045, Y:135-945. Critical content above Y:930 (bottom action bar). Handle/caption zone (Y:0-120) clear.

5. COMPOSITION: Single focal point. Balanced layout. Clear visual hierarchy (headline > body > CTA). 60-30-10 color ratio.

6. RENDERING: AI artifacts? Blur? Spanish accents (ioen) correct? Text clipped or truncated? Gradients smooth?

7. INFO INTEGRITY (P0): Every sentence from the script present? Emphasis words retain surrounding context? Any text truncated or partially rendered?

8. TEXT-IMAGE: Image visible through gradient? Layout serves content? Text legible at ~375px Instagram feed width?

9. PLATFORM FIT: Readable at Instagram feed preview size? 1:1 crop zone contains key message? Mobile tap targets adequate?

Return structured issues: ISSUE -> severity:P0|P1|P2 -> dimension -> description -> suggestion. Or NO ISSUES FOUND.`;

async function describeWithAnthropic(
  image: ImageContent,
  model: string,
  apiKey: string,
  signal?: AbortSignal,
  prompt?: string,
): Promise<string> {
  const response = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-api-key": apiKey,
      "anthropic-version": "2023-06-01",
      "anthropic-dangerous-direct-browser-access": "true",
    },
    body: JSON.stringify({
      model,
      max_tokens: 2000,
      messages: [
        {
          role: "user",
          content: [
            {
              type: "image",
              source: {
                type: "base64",
                media_type: image.source.mediaType,
                data: image.source.data,
              },
            },
            { type: "text", text: prompt || VISION_PROMPT },
          ],
        },
      ],
    }),
    signal,
  });

  if (!response.ok) {
    const errText = await response.text();
    throw new Error(`Anthropic API error (${response.status}): ${errText.slice(0, 500)}`);
  }

  const data = (await response.json()) as {
    content?: Array<{ type: string; text?: string }>;
  };
  const textBlocks = data.content?.filter((b) => b.type === "text") ?? [];
  return textBlocks.map((b) => b.text ?? "").join("\n") || "(no description returned)";
}

async function describeWithOpenAI(
  image: ImageContent,
  model: string,
  apiKey: string,
  signal?: AbortSignal,
  prompt?: string,
): Promise<string> {
  const dataUrl = `data:${image.source.mediaType};base64,${image.source.data}`;

  const response = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      model,
      messages: [
        {
          role: "user",
          content: [
            { type: "text", text: prompt || VISION_PROMPT },
            { type: "image_url", image_url: { url: dataUrl } },
          ],
        },
      ],
      max_tokens: 2000,
      temperature: 0.1,
    }),
    signal,
  });

  if (!response.ok) {
    const errText = await response.text();
    throw new Error(`OpenAI API error (${response.status}): ${errText.slice(0, 500)}`);
  }

  const data = (await response.json()) as {
    choices?: Array<{ message?: { content?: string } }>;
  };
  return data.choices?.[0]?.message?.content ?? "(no description returned)";
}
async function describeWithOpenRouter(
  image: ImageContent,
  model: string,
  apiKey: string,
  signal?: AbortSignal,
  prompt?: string,
): Promise<string> {
  const dataUrl = `data:${image.source.mediaType};base64,${image.source.data}`;

  const response = await fetch("https://openrouter.ai/api/v1/chat/completions", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${apiKey}`,
      "HTTP-Referer": "https://eldato.com.mx",
      "X-Title": "El Dato Vision Interceptor",
    },
    body: JSON.stringify({
      model,
      messages: [
        {
          role: "user",
          content: [
            { type: "text", text: prompt || VISION_PROMPT },
            { type: "image_url", image_url: { url: dataUrl } },
          ],
        },
      ],
      max_tokens: 2000,
      temperature: 0.1,
    }),
    signal,
  });

  if (!response.ok) {
    const errText = await response.text();
    throw new Error(`OpenRouter API error (${response.status}): ${errText.slice(0, 500)}`);
  }

  const data = (await response.json()) as {
    choices?: Array<{ message?: { content?: string } }>;
  };
  return data.choices?.[0]?.message?.content ?? "(no description returned)";
}

async function describeImage(
  image: ImageContent,
  provider: "openrouter" | "anthropic" | "openai",
  model: string,
  apiKey: string,
  signal?: AbortSignal,
  prompt?: string,
): Promise<string> {
  const effectivePrompt = prompt || VISION_PROMPT;
  switch (provider) {
    case "openrouter":
      return describeWithOpenRouter(image, model, apiKey, signal, effectivePrompt);
    case "anthropic":
      return describeWithAnthropic(image, model, apiKey, signal, effectivePrompt);
    case "openai":
      return describeWithOpenAI(image, model, apiKey, signal, effectivePrompt);
  }
}

// ── File-based image reading (for read_image tool) ─────────────────

function imageMimeType(ext: string): string {
  const mimeMap: Record<string, string> = {
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".gif": "image/gif",
    ".webp": "image/webp",
    ".bmp": "image/bmp",
    ".svg": "image/svg+xml",
    ".tiff": "image/tiff",
    ".tif": "image/tiff",
  };
  return mimeMap[ext.toLowerCase()] || "image/png";
}

function encodeImageFile(filePath: string): ImageContent | null {
  try {
    const ext = filePath.slice(filePath.lastIndexOf(".")).toLowerCase();
    const mimeType = imageMimeType(ext);
    const data = readFileSync(filePath, { encoding: "base64" });
    return {
      type: "image",
      source: { type: "base64", mediaType: mimeType, data },
    };
  } catch {
    return null;
  }
}

// ── Extension Entry Point ──────────────────────────────────────────

export default function visionInterceptor(pi: ExtensionAPI) {
  if (process.env.VISION_INTERCEPTOR_DISABLED === "1") {
    console.log("[vision-interceptor] ⏭️  Disabled");
    return;
  }

  // ═════════════════════════════════════════════════════════════
  // Image Input Interception
  // ═════════════════════════════════════════════════════════════
  pi.on("input", async (event, ctx) => {
    if (!event.images || event.images.length === 0) {
      return { action: "continue" };
    }

    const config = loadConfig(ctx.cwd);
    const providerCfg = getProviderConfig(config);

    if (!providerCfg) {
      // No vision provider available — let the images through as-is
      // (the LLM will either ignore them or error, but we tried)
      ctx.ui.notify(
        "⚠ No vision provider API key found. Set OPENROUTER_API_KEY, ANTHROPIC_API_KEY, or OPENAI_API_KEY.",
        "warning",
      );
      return { action: "continue" };
    }

    ctx.ui.setStatus("vision", "🔍 Analyzing image...");

    const descriptions: string[] = [];
    const errors: string[] = [];

    for (let i = 0; i < event.images.length; i++) {
      const img = event.images[i];
      if (!isImageContent(img)) continue;

      ctx.ui.setStatus("vision", `🔍 Analyzing image ${i + 1} of ${event.images.length}...`);

      try {
        const desc = await describeImage(
          img,
          providerCfg.provider,
          providerCfg.model,
          providerCfg.apiKey,
        );
        descriptions.push(desc);
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        errors.push(`Image ${i + 1}: ${msg}`);
        ctx.ui.notify(`❌ Failed to analyze image ${i + 1}: ${msg}`, "error");
      }
    }

    ctx.ui.setStatus("vision", undefined);

    // Build the image descriptions block
    let imageContext = "";
    if (descriptions.length > 0) {
      imageContext =
        descriptions.length === 1
          ? `\n\n--- [Image attached — analyzed by ${providerCfg.provider}/${providerCfg.model}] ---\n${descriptions[0]}\n--- [End image description] ---`
          : `\n\n--- [${descriptions.length} images attached — analyzed by ${providerCfg.provider}/${providerCfg.model}] ---\n` +
            descriptions.map((d, i) => `[Image ${i + 1}]:\n${d}`).join("\n\n") +
            `\n--- [End image descriptions] ---`;
    }

    if (errors.length > 0) {
      imageContext += `\n\n[Warning: ${errors.length} image(s) could not be analyzed: ${errors.join("; ")}]`;
    }

    const newText = event.text
      ? `${event.text}${imageContext}`
      : imageContext.trim();

    return {
      action: "transform",
      text: newText,
      // Strip images so DeepSeek doesn't receive them
      images: undefined,
    };
  });

  // ═════════════════════════════════════════════════════════════
  // read_image tool
  // ═════════════════════════════════════════════════════════════
  pi.registerTool({
    name: "read_image",
    label: "Read Image",
    description:
      "Read an image file and return a detailed text description. Use this when you need to understand what's in an image file (screenshot, photo, diagram, etc.). The image is analyzed by a vision-capable model and the description is returned as text.",
    promptSnippet: "Read an image file and return a text description (via vision model)",
    promptGuidelines: [
      "Use read_image when the user asks about an image file, screenshot, photo, or diagram. The tool analyzes the image with a vision model and returns a detailed description.",
    ],
    parameters: Type.Object({
      path: Type.String({
        description: "Path to the image file (absolute or relative). Supports png, jpg, gif, webp, bmp, svg.",
      }),
      provider: Type.Optional(
        StringEnum(["openrouter", "anthropic", "openai"] as const),
      ),
      model: Type.Optional(
        Type.String({
          description: "Vision model to use. If not specified, uses the default for the provider.",
        }),
      ),
      purpose: Type.Optional(
        StringEnum(["design-critique"] as const),
      ),
    }),
    async execute(_toolCallId, params, signal, onUpdate, ctx) {
      const absolutePath = resolve(ctx.cwd, params.path.replace(/^@/, ""));

      // Encode the image
      const image = encodeImageFile(absolutePath);
      if (!image) {
        throw new Error(
          `Could not read image file: ${params.path}. Make sure the file exists and is a supported image format (png, jpg, gif, webp, bmp, svg).`,
        );
      }

      // Get provider config
      const config = loadConfig(ctx.cwd);
      if (params.provider) config.provider = params.provider;
      if (params.model) config.model = params.model;

      const providerCfg = getProviderConfig(config);
      if (!providerCfg) {
        throw new Error(
          "No vision provider API key found. Set OPENROUTER_API_KEY, ANTHROPIC_API_KEY, or OPENAI_API_KEY environment variable.",
        );
      }

      onUpdate?.({
        content: [
          {
            type: "text",
            text: `Analyzing image "${params.path}" with ${providerCfg.provider}/${providerCfg.model}...`,
          },
        ],
      });

      const prompt = params.purpose === "design-critique" ? DESIGN_CRITIQUE_PROMPT : VISION_PROMPT;

      const description = await describeImage(
        image,
        providerCfg.provider,
        providerCfg.model,
        providerCfg.apiKey,
        signal,
        prompt,
      );

      return {
        content: [
          {
            type: "text",
            text: `[Image: ${params.path} — analyzed by ${providerCfg.provider}/${providerCfg.model}]\n\n${description}`,
          },
        ],
        details: {
          path: params.path,
          provider: providerCfg.provider,
          model: providerCfg.model,
        },
      };
    },
  });

  console.log(
    "[vision-interceptor] Loaded. Image paste interception active. read_image tool registered.",
  );
}
