/**
 * Builtin Tools Extension for pi
 *
 * Provides tools that Claude Code has built-in but pi doesn't:
 *   - web_search  — Perplexity search (replaces WebSearch)
 *   - web_fetch   — Fetch and extract page content (replaces WebFetch)
 *   - todo_write  — Task tracking (replaces TodoWrite)
 *   - task        — Sub-agent dispatcher (replaces Agent/Task tool)
 */
/* eslint-disable @typescript-eslint/no-explicit-any */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { readFileSync } from "node:fs";
import { spawn } from "node:child_process";
import { resolve } from "node:path";
import { retry, createCircuitBreaker } from "../shared/retry.js";
import { register } from "../shared/health.js";

// ── Helpers ─────────────────────────────────────────────────────────

/** Resolve the Perplexity API key from env or a configurable .env file */
export function getPerplexityKey(): string | undefined {
  // Check environment first
  if (process.env.PERPLEXITY_API_KEY) return process.env.PERPLEXITY_API_KEY;

  // Try AGENT_MCP_ENV_PATH for an explicit .env path
  const envPath = process.env.AGENT_MCP_ENV_PATH;
  if (envPath) {
    try {
      const envContent = readFileSync(envPath, "utf-8");
      const match = envContent.match(/PERPLEXITY_API_KEY=(.+)/);
      if (match) return match[1].trim();
    } catch {
      // .env file not found or unreadable
    }
  }

  // Fall back to $AGENT_INFRA_PATH/../.env
  const infraPath = process.env.AGENT_INFRA_PATH;
  if (infraPath) {
    try {
      const fallbackPath = resolve(infraPath, "..", ".env");
      const envContent = readFileSync(fallbackPath, "utf-8");
      const match = envContent.match(/PERPLEXITY_API_KEY=(.+)/);
      if (match) return match[1].trim();
    } catch {
      // .env file not found or unreadable
    }
  }

  return undefined;
}

/** Strip HTML tags and extract readable text */
// #36: Ensure sub-agent PATH includes common python3 locations.
// The parent pi process (running under cmux) may have a truncated PATH that
// drops /opt/homebrew/bin and /usr/local/bin. Sub-agents inherit process.env
// faithfully but that doesn't help if the parent's PATH was already truncated.
// Prepend known locations so MCP servers using bare `python3` resolve.
export const PATH_EXTRA_DIRS = [
  "/opt/homebrew/bin",
  "/usr/local/bin",
  "/home/linuxbrew/.linuxbrew/bin",
];

export function augmentPath(inheritedPath: string): string {
  const extraDirs = PATH_EXTRA_DIRS.filter(
    (d) => !inheritedPath.split(":").includes(d)
  );
  return extraDirs.length > 0
    ? [...extraDirs, inheritedPath].join(":")
    : inheritedPath;
}

export function getSubAgentPath(): string {
  return augmentPath(process.env.PATH ?? "");
}

export function stripHtml(html: string): string {
  return html
    .replace(/<script[^>]*>[\s\S]*?<\/script>/gi, "")
    .replace(/<style[^>]*>[\s\S]*?<\/style>/gi, "")
    .replace(/<[^>]+>/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/\s+/g, " ")
    .trim();
}

// ── TODO State ──────────────────────────────────────────────────────

interface TodoItem {
  id: string;
  content: string;
  status: "pending" | "in_progress" | "completed";
}

let todos: TodoItem[] = [];

/** Restore todos from session entries on startup */
function restoreTodos(pi: ExtensionAPI): void {
  pi.on("session_start", async (_event, ctx) => {
    for (const entry of ctx.sessionManager.getEntries()) {
      if (entry.type === "custom" && (entry as any).customType === "todo-state") {
        const data = (entry as any).data;
        if (data?.todos) {
          todos = data.todos;
        }
      }
    }
  });
}

// ── Extension Entry Point ───────────────────────────────────────────

export default function (pi: ExtensionAPI) {
  register("builtin-tools");

  // Restore TODO state from session
  restoreTodos(pi);

  // ═══════════════════════════════════════════════════════════════
  // web_search — Perplexity web search
  // ═══════════════════════════════════════════════════════════════
  //
  // MODEL PRICING (per 1M tokens + per-request fee):
  //   sonar ................. $1 input / $1 output / $0.005 req — DEFAULT (cheapest)
  //   sonar-pro ............. $3 input / $15 output / $0.006 req — better quality
  //   sonar-reasoning ....... $2 input / $8 output / $0.005 req
  //   sonar-deep-research ... GATED — $2/$8 tokens + $2 citation + $3 reasoning
  //                           + $0.005/search-query. One call = $5–40+. Requires
  //                           EXPLICIT user approval.
  //   sonar-reasoning-pro ... GATED — same gate as deep-research.
  //
  // CHEAPEST FOR MULTI-ANGLE: mcp__seo-intelligence__perplexity_research
  //   (Search API, $0.005/query flat, no token costs)
  //
  pi.registerTool({
    name: "web_search",
    label: "Web Search",
    description:
      "Search the web using Perplexity. Returns titles, URLs, and content snippets. Use for finding documentation, facts, or any web content. Default model: sonar (cheapest). sonar-deep-research and sonar-reasoning-pro are GATED — require explicit user approval.",
    promptSnippet: "Search the web via Perplexity (sonar by default)",
    promptGuidelines: [
      "Use web_search when you need to find current information, documentation, or facts from the web.",
      "Default model is 'sonar' (cheapest: $1/$1 per M tokens). Do NOT use 'sonar-deep-research' or 'sonar-reasoning-pro' without EXPLICIT user approval — these cost $5–40+ per call (14M+ reasoning tokens observed in billing).",
      "For multi-angle research, prefer mcp__seo-intelligence__perplexity_research (Search API, $0.005/query — cheapest option).",
      "For quick single-question lookups, prefer mcp__seo-intelligence__perplexity_search (Search API, $0.005/query).",
    ],
    parameters: Type.Object({
      query: Type.String({ description: "The search query" }),
      max_results: Type.Optional(
        Type.Number({ description: "Number of results (1-20, default 5)" })
      ),
      model: Type.Optional(
        Type.String({
          description:
            "Perplexity model: 'sonar' (default, cheapest $1/$1), 'sonar-pro' ($3/$15, better quality), 'sonar-reasoning' ($2/$8). 'sonar-deep-research' and 'sonar-reasoning-pro' are GATED — do NOT use without explicit user approval (costs $5–40+/call).",
        })
      ),
    }),
    async execute(_toolCallId, params) {
      const apiKey = getPerplexityKey();
      if (!apiKey) {
        return {
          content: [
            {
              type: "text",
              text: "PERPLEXITY_API_KEY not set. Set it via PERPLEXITY_API_KEY env var, AGENT_MCP_ENV_PATH (path to .env file), or $AGENT_INFRA_PATH/../.env",
            },
          ],
        };
      }

      const model = params.model ?? "sonar";

      // ── Deep Research Gate ────────────────────────────────────────
      const GATED_MODELS = ["sonar-deep-research", "sonar-reasoning-pro"];
      if (GATED_MODELS.includes(model)) {
        console.log(
          `[perplexity] 🚫 DEEP RESEARCH BLOCKED — model=${model} query="${params.query.slice(0, 80)}..."`
        );
        return {
          content: [
            {
              type: "text",
              text:
                `⛔ DEEP RESEARCH GATE — model "${model}" requires explicit user approval.\n\n` +
                `Deep research costs $5–40+ per call (14.5M reasoning tokens observed in our billing — one call burned $43 in reasoning alone). \n\n` +
                `Use model="sonar" (default, $1/$1 per M tokens) or model="sonar-pro" ($3/$15 per M) instead. ` +
                `For multi-angle research, use mcp__seo-intelligence__perplexity_research (Search API, $0.005/query — cheapest).\n\n` +
                `To use deep research, the user must explicitly approve by saying something like: ` +
                `"I approve using sonar-deep-research for [specific purpose]. I understand it costs $5–40+ per call."`,
            },
          ],
        };
      }

      // ── Cost logging ──────────────────────────────────────────────
      console.log(
        `[perplexity] 🔍 model=${model} query="${params.query.slice(0, 80)}..."`
      );

      try {
        const response = await fetch("https://api.perplexity.ai/chat/completions", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Authorization: `Bearer ${apiKey}`,
          },
          body: JSON.stringify({
            model,
            messages: [
              {
                role: "system",
                content: `Search the web for the following query. Return numbered results with title, URL, and a brief snippet for each. Return at most ${params.max_results ?? 5} results. Be precise and cite sources. Do NOT use deep research — this is a quick search query.`,
              },
              { role: "user", content: params.query },
            ],
          }),
          signal: AbortSignal.timeout(30000),
        });

        if (!response.ok) {
          const errText = await response.text();
          console.error(`[perplexity] ❌ HTTP ${response.status}: ${errText.slice(0, 200)}`);
          return {
            content: [
              { type: "text", text: `Perplexity search failed (${response.status}): ${errText}` },
            ],
          };
        }

        const data = (await response.json()) as any;
        const text =
          data.choices?.[0]?.message?.content ?? JSON.stringify(data);

        // Log token usage if available
        const usage = data.usage;
        if (usage) {
          console.log(
            `[perplexity] ✅ model=${model} prompt_tokens=${usage.prompt_tokens ?? 0} completion_tokens=${usage.completion_tokens ?? 0}`
          );
        }

        return {
          content: [{ type: "text", text }],
          details: { query: params.query, model },
        };
      } catch (err: any) {
        console.error(`[perplexity] ❌ error: ${err.message}`);
        return {
          content: [{ type: "text", text: `Web search error: ${err.message}` }],
        };
      }
    },
  });

  // ═══════════════════════════════════════════════════════════════
  // web_fetch — Fetch and extract a web page
  // ═══════════════════════════════════════════════════════════════
  pi.registerTool({
    name: "web_fetch",
    label: "Web Fetch",
    description:
      "Fetch a web page and extract its text content. Use for reading documentation, articles, or any web page content.",
    promptSnippet: "Fetch and extract text from a web page URL",
    promptGuidelines: [
      "Use web_fetch to extract text content from a URL. Pass the full URL including https://.",
    ],
    parameters: Type.Object({
      url: Type.String({ description: "The full URL to fetch (including https://)" }),
      max_length: Type.Optional(
        Type.Number({ description: "Maximum characters to return (default 10000)" })
      ),
    }),
    async execute(_toolCallId, params) {
      try {
        const response = await fetch(params.url, {
          headers: {
            "User-Agent": "Mozilla/5.0 (compatible; pi-coding-agent/1.0)",
            Accept: "text/html,application/xhtml+xml",
          },
          signal: AbortSignal.timeout(15000),
        });

        if (!response.ok) {
          return {
            content: [
              {
                type: "text",
                text: `Failed to fetch ${params.url}: HTTP ${response.status}`,
              },
            ],
          };
        }

        const contentType = response.headers.get("content-type") ?? "";
        if (!contentType.includes("text/html") && !contentType.includes("text/plain")) {
          return {
            content: [
              {
                type: "text",
                text: `Cannot extract text from ${params.url}: content type is ${contentType}`,
              },
            ],
          };
        }

        const html = await response.text();
        let text = stripHtml(html);
        const maxLen = params.max_length ?? 10000;
        if (text.length > maxLen) {
          text = text.slice(0, maxLen) + `\n\n[... truncated at ${maxLen} characters]`;
        }

        return {
          content: [{ type: "text", text }],
          details: { url: params.url, contentLength: text.length },
        };
      } catch (err: any) {
        return {
          content: [{ type: "text", text: `Web fetch error: ${err.message}` }],
        };
      }
    },
  });

  // ═══════════════════════════════════════════════════════════════
  // todo_write — Task tracking
  // ═══════════════════════════════════════════════════════════════
  pi.registerTool({
    name: "todo_write",
    label: "Todo Write",
    description:
      "Create and manage a structured task list. Use to track progress through multi-step workflows. Each call replaces the entire list.",
    promptSnippet: "Write or update a structured task list",
    promptGuidelines: [
      "Use todo_write to create and update a task list. Each call replaces all previous todos. Mark items as pending, in_progress, or completed.",
    ],
    parameters: Type.Object({
      todos: Type.Array(
        Type.Object({
          id: Type.String({ description: "Unique task identifier" }),
          content: Type.String({ description: "Task description" }),
          status: Type.String({ description: "pending, in_progress, or completed" }),
        }),
        { description: "The full list of tasks (replaces all previous todos)" }
      ),
    }),
    async execute(_toolCallId, params) {
      todos = params.todos.map((t: any) => ({
        id: t.id,
        content: t.content,
        status: t.status as TodoItem["status"],
      }));

      // Persist to session
      pi.appendEntry("todo-state", { todos });

      // Format for display
      const statusIcon = (s: string) =>
        s === "completed" ? "✓" : s === "in_progress" ? "▶" : "○";
      const lines = todos.map(
        (t) => `  ${statusIcon(t.status)} [${t.id}] ${t.content}`
      );

      return {
        content: [{ type: "text", text: `Tasks:\n${lines.join("\n")}` }],
        details: { count: todos.length },
      };
    },
  });

  // ═══════════════════════════════════════════════════════════════
  // task — Sub-agent dispatcher
  // ═══════════════════════════════════════════════════════════════

  // ponytail: per-purpose circuit breaker for sub-agent dispatch.
  // Opens after 3 consecutive zero-output failures, half-open after 60s.
  const taskCircuitBreaker = createCircuitBreaker({ threshold: 3, cooldownMs: 60_000 });

  /**
   * Spawn a sub-agent and return its output. Returns undefined on zero-output
   * timeout (retryable) so the retry wrapper can re-spawn.
   */
  function spawnSubAgent(model: string, provider: string, subAgentEnv: Record<string, string | undefined>, args: string[]): Promise<{ content: any[]; details: Record<string, unknown> } | undefined> {
    return new Promise((resolve) => {
      const proc = spawn("pi", args, {
        cwd: process.cwd(),
        shell: false,
        stdio: ["ignore", "pipe", "pipe"],
        env: subAgentEnv,
      });

      let stdout = "";
      let stderr = "";
      let lastHeartbeat = Date.now();
      let settled = false;
      const HEARTBEAT_TIMEOUT_MS = 660_000;
      const FIRST_OUTPUT_TIMEOUT_MS = 60_000;
      let hasOutput = false;

      const appendCap = (s: string, add: string, cap: number) => {
        const merged = s + add;
        return merged.length > cap ? merged.slice(-cap) : merged;
      };
      const cleanStderr = (s: string) => s.replace(/\x1b\[[0-9;]*[a-zA-Z]/g, "").replace(/[\x00-\x08\x0b\x0c\x0e-\x1f]/g, "");

      proc.stdout.on("data", (data: Buffer) => {
        stdout = appendCap(stdout, data.toString(), 1_000_000);
        lastHeartbeat = Date.now();
        hasOutput = true;
      });
      proc.stderr.on("data", (data: Buffer) => {
        stderr = appendCap(stderr, data.toString(), 1_000_000);
        lastHeartbeat = Date.now();
        hasOutput = true;
      });

      const doResolve = (value: { content: any[]; details: Record<string, unknown> } | undefined) => {
        if (settled) return;
        settled = true;
        resolve(value);
      };

      const startedAt = Date.now();
      const heartbeat = setInterval(() => {
        const elapsed = Date.now() - startedAt;

        // Tier 1 — First-output timeout: return undefined to trigger retry (#5926)
        if (!hasOutput && elapsed > FIRST_OUTPUT_TIMEOUT_MS) {
          clearInterval(heartbeat);
          proc.kill("SIGTERM");
          const sigkillTimer = setTimeout(() => { if (!proc.killed) proc.kill("SIGKILL"); }, 5000);
          proc.once("close", () => clearTimeout(sigkillTimer));
          console.error(`[task] sub-agent produced no output in ${FIRST_OUTPUT_TIMEOUT_MS / 1000}s — retryable`);
          doResolve(undefined);
          return;
        }

        // Tier 2 — Silence threshold: partial output exists, return it
        if (Date.now() - lastHeartbeat > HEARTBEAT_TIMEOUT_MS) {
          clearInterval(heartbeat);
          const lastOutput = stdout.slice(-500);
          proc.kill("SIGTERM");
          const sigkillTimer = setTimeout(() => { if (!proc.killed) proc.kill("SIGKILL"); }, 5000);
          proc.once("close", () => clearTimeout(sigkillTimer));
          doResolve({
            content: [{ type: "text", text: `⚠️ Sub-agent reached silence threshold (${HEARTBEAT_TIMEOUT_MS / 1000}s). Partial results below — parent should decide: accept, re-dispatch, or escalate.\n\n--- last stderr ---\n${cleanStderr(stderr.slice(-2000))}\n\n--- last stdout ---\n${lastOutput}` }],
            details: { model, provider, killed: true, reason: "silence-threshold", heartbeatTimeout: HEARTBEAT_TIMEOUT_MS },
          });
        }
      }, 10_000);

      proc.on("close", (code: number) => {
        clearInterval(heartbeat);
        const stderrClean = cleanStderr(stderr.trim()).slice(-4000);
        const errInfo = stderrClean ? `\n\n--- stderr ---\n${stderrClean}` : "";
        if (code === 0 && stdout.trim()) {
          doResolve({ content: [{ type: "text", text: stdout.trim() + errInfo }], details: { model, provider } });
        } else {
          const output = stdout.trim();
          const text = output || stderr.trim() || `Sub-agent exited with code ${code}`;
          const extra = output ? errInfo : "";
          doResolve({ content: [{ type: "text", text: text + extra }], details: { model, provider, exitCode: code } });
        }
      });

      proc.on("error", (err: Error) => {
        clearInterval(heartbeat);
        // Spawn errors (pi not found, etc.) are NOT retryable — return the error
        doResolve({ content: [{ type: "text", text: `Sub-agent failed: ${err.message}\n\n--- stderr ---\n${cleanStderr(stderr).slice(-4000)}` }], details: { model, provider, isError: true } });
      });
    });
  }

  pi.registerTool({
    name: "task",
    label: "Task (Sub-agent)",
    description:
      "Dispatch a sub-agent to perform a focused task with isolated context. The sub-agent runs pi in print mode with the given prompt and returns results. Use for delegating self-contained work like code analysis, research, or review.",
    promptSnippet: "Dispatch a sub-agent to perform a specific task",
    promptGuidelines: [
      "Use task to delegate focused, self-contained work to a sub-agent with fresh context. Provide a clear, detailed prompt.",
      "The sub-agent runs pi in print mode (-p) with access to read, bash, edit, and write tools.",
      "For complex multi-turn tasks, break them into multiple task calls or handle them yourself.",
      "Sub-agents have NO access to the current session context — provide all necessary information in the prompt.",
    ],
    parameters: Type.Object({
      prompt: Type.String({
        description: "The full prompt for the sub-agent, including all context it needs",
      }),
      model: Type.Optional(
        Type.String({
          description:
            "Model to use (default: deepseek-v4-flash).",
        })
      ),
      mcp_servers: Type.Optional(
        Type.String({
          description:
            "Comma-separated MCP server names for this sub-agent. Inherits parent's PI_MCP_SERVERS by default. Add gemini,cloudinary for image generation tasks.",
        })
      ),
    }),
    async execute(_toolCallId, params) {
      const model = params.model ?? "deepseek-v4-flash";
      const provider = model.startsWith("claude") ? "anthropic" : "deepseek";

      // #36: Ensure sub-agent PATH includes common python3 locations.
      const augmentedPath = getSubAgentPath();

      const subAgentEnv: Record<string, string | undefined> = {
  ...process.env,
  PATH: augmentedPath,
  PI_SKIP_VERSION_CHECK: "1",
  // Skip extensions sub-agents never need (one-shot, no git/slack/loops/vision).
  // Gate overrides: sub-agents can't dispatch `task` to satisfy verification-gate
  // or review-enforcer → deadlock → 480s hang. Parent session enforces gates centrally.
  SKILL_ENFORCER_DISABLED: "1",
  LOOP_ENFORCER_DISABLED: "1",
  SLACK_BRIDGE_DISABLE: "1",
  VISION_INTERCEPTOR_DISABLED: "1",
  ELDATO_ALLOW_MAIN_EDITS: "1",  // dual-support: also set AGENT_ variant (#7549)
  AGENT_ALLOW_MAIN_EDITS: "1",
  ELDATO_SKIP_VGATE: "1",        // sub-agents lack `task` tool; parent enforces gates
  AGENT_SKIP_REVIEW_GATE: "1",   // sub-agents lack `task` tool; parent enforces gates
};
      if (params.mcp_servers) {
        subAgentEnv.PI_MCP_SERVERS = params.mcp_servers;
      }

      const args = ["-p", "--provider", provider, "--model", model, "--no-session", params.prompt];

      // Retry on zero-output failures (model/network hang) with backoff + circuit breaker.
      // Does NOT retry when sub-agent produces partial output — those go to the caller.
      const result = await retry(
        () => spawnSubAgent(model, provider, subAgentEnv, args),
        {
          maxAttempts: 3,
          baseDelayMs: 1000,
          maxDelayMs: 16000,
          circuitBreaker: taskCircuitBreaker,
          onRetry: (attempt, delayMs) => {
            console.log(`[task] retry ${attempt}/${3} — waiting ${delayMs}ms`);
          },
        },
      );

      if (result.status === "circuit_open") {
        return {
          content: [{ type: "text", text: "❌ Sub-agent circuit breaker open — too many consecutive zero-output failures. Wait 60s before retrying." }],
          details: { model, provider, status: "circuit_open", retries: result.retries },
        };
      }

      if (result.status === "failed") {
        return {
          content: [{ type: "text", text: `❌ Sub-agent failed after ${result.retries} attempts with no output. Model may be hung or overloaded.` }],
          details: { model, provider, status: "failed", retries: result.retries, elapsedMs: result.elapsedMs },
        };
      }

      // Success or partial output
      if (result.value) {
        return result.value;
      }

      // Fallback (shouldn't reach here)
      return {
        content: [{ type: "text", text: "Sub-agent returned no result." }],
        details: { model, provider },
      };
    },
  });

  // #5672: suppress startup banner in print mode (task sub-agent output)
  if (process.env.PI_MODE !== 'print') {
    console.log("[builtin-tools] Registered: web_search, web_fetch, todo_write, task");
  }
}
