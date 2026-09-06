import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  pi.registerProvider("openrouter", {
    name: "OpenRouter",
    baseUrl: "https://openrouter.ai/api/v1",
    apiKey: "$OPENROUTER_API_KEY",
    api: "openai-completions",
    headers: {
      // #47 de-branded: attribution headers are env-configurable with neutral
      // defaults (OPENROUTER_HTTP_REFERER / OPENROUTER_APP_TITLE).
      "HTTP-Referer": process.env.OPENROUTER_HTTP_REFERER || "https://github.com/daniel-ospina/agent-infra",
      "X-Title": process.env.OPENROUTER_APP_TITLE || "agent-infra"
    },
    models: [
      {
        id: "anthropic/claude-opus-4.8",
        name: "Claude Opus 4.8",
        reasoning: false,
        input: ["text", "image"],
        cost: { input: 5, output: 25, cacheRead: 0, cacheWrite: 0 },
        contextWindow: 1000000,
        maxTokens: 32000
      },
      // #476 hop legs: the alias-family chain (extensions/shared/
      // provider-failover.ts) routes deepseek-v4-flash/-pro exhaustion onto
      // these OpenRouter slugs when the primary balance is out. OpenRouter
      // lists the same models the deepseek-official account serves, so the
      // models array REPLACES models.json entries for provider "openrouter"
      // at runtime (s7) — without them a hop-leg dispatch would fail to
      // resolve the model. Cost/maxTokens sourced from the equivalent
      // openrouter.models[] rows in models-store.json (catalog authority, s7);
      // contextWindow honors the global clamp (300K).
      {
        id: "deepseek/deepseek-v4-flash",
        name: "DeepSeek V4 Flash (via OpenRouter)",
        reasoning: false,
        input: ["text"],
        cost: { input: 0.0882, output: 0.1764, cacheRead: 0.01764, cacheWrite: 0 },
        contextWindow: 300000,
        maxTokens: 131072
      },
      {
        id: "deepseek/deepseek-v4-pro",
        name: "DeepSeek V4 Pro (via OpenRouter)",
        reasoning: false,
        input: ["text"],
        cost: { input: 0.435, output: 0.87, cacheRead: 0.003625, cacheWrite: 0 },
        contextWindow: 300000,
        maxTokens: 384000
      }
    ]
  });
}
