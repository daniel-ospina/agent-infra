import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  pi.registerProvider("openrouter", {
    name: "OpenRouter",
    baseUrl: "https://openrouter.ai/api/v1",
    apiKey: "$OPENROUTER_API_KEY",
    api: "openai-completions",
    headers: {
      "HTTP-Referer": "https://github.com/daniel-ospina/eldato",
      "X-Title": "El Dato"
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
