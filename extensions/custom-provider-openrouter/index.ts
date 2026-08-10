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
      }
    ]
  });
}
