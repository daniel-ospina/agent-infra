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
      // contextWindow tracks the global clamp (700K since #1213; 300K
      // before it) so this declared table cannot silently disagree with the
      // shipped `models.json` modelOverrides, which are applied LAST and had
      // already resolved these slugs at 700K. NOTE: these outgoing legs are
      // UNPROBED at 700K (filed — only api.deepseek.com was driven past 300K);
      // an over-ceiling request on a leg fails LOUDLY (recoverable provider
      // error) and is recorded by extensions/compaction-watchdog.ts.
      // (Exception: the V4.1 row
      // below has NO entry in the shipped store — see its own comment for the
      // provenance of its rates.)
      //
      // #727: the flash hop leg is `deepseek/deepseek-v4.1-flash` — the SAME
      // generation the deepseek-official primary serves (the slug maps onto the
      // flash family in familyOf), so a failover no longer silently changes the
      // model generation. `reasoning` is CONFIGURABLE here, carrying the levels
      // the deepseek primary can express (off/high/max — `off` is implicit
      // there and explicit here because OpenRouter needs a concrete effort
      // value); minimal/low/medium stay unmapped for hop parity: the upstream
      // slug accepts them, the primary cannot express them, and a hop must not
      // change the session's thinking level. `input` includes image because the
      // slug accepts images (probed live 2026-09-14: an 8x8 red PNG → "Red") —
      // the same declaration the venice `deepseek-v4-1-flash` entry carries for
      // this model generation; the deepseek-official text-only row is the
      // outlier. COST PROVENANCE: this slug has NO row in the shipped
      // pi-bootstrap/pi-config/models-store.json, so the rates below come from
      // the live OpenRouter catalog (`GET /api/v1/models` + the slug's endpoints).
      // They are the **DeepSeek first-party OFF-PEAK window** (weekends, plus
      // weekdays outside 01:00-04:00 and 06:00-10:00 UTC): $0.15/$0.60 per M,
      // cache-read $0.003 (verified 2026-09-15). The catalog's reference rate —
      // and the peak windows — is 2x that ($0.30/$1.20, cache-read $0.006), so
      // hourly cost accounting sees the best case here; the delta vs the legacy
      // 0423 slug is recorded in docs/providers.md for BOTH windows (#727
      // indicator c). The flat cheap endpoint (Relace: same $0.15/$0.60) prices
      // cache-read at $0.015, 5x the windowed value — the declared cache-read
      // belongs to the DeepSeek endpoint, not to a generic "the slug" rate.
      {
        id: "deepseek/deepseek-v4.1-flash",
        name: "DeepSeek V4.1 Flash (via OpenRouter)",
        reasoning: true,
        thinkingLevelMap: { off: "none", minimal: null, low: null, medium: null, high: "high", max: "max" },
        input: ["text", "image"],
        cost: { input: 0.15, output: 0.6, cacheRead: 0.003, cacheWrite: 0 },
        contextWindow: 700000,
        maxTokens: 384000
      },
      // Legacy-generation leg (upstream "DeepSeek V4 Flash 0423"), kept in the
      // table as RESOLUTION-ONLY (`RESOLUTION_ONLY_LEGS` in provider-failover.ts
      // — no longer a chain hop target and never served to a fresh advance). It
      // stays REGISTERED and IN-TABLE because stale state is real: a pre-#727
      // latch file / in-flight marker / session pinned to this slug must still
      // resolve. A table miss would make nextLegAfter's startIdx -1, restarting
      // the walk at legs[0]: for an in-flight marker that is the DRAINING root
      // (#715 — the write path walks the pre-write state, where the root is not
      // yet unavailable), for a read-side latch/session the first AVAILABLE leg.
      {
        id: "deepseek/deepseek-v4-flash",
        name: "DeepSeek V4 Flash 0423 (via OpenRouter, legacy)",
        reasoning: false,
        input: ["text"],
        cost: { input: 0.0882, output: 0.1764, cacheRead: 0.01764, cacheWrite: 0 },
        contextWindow: 700000,
        maxTokens: 131072
      },
      {
        id: "deepseek/deepseek-v4-pro",
        name: "DeepSeek V4 Pro (via OpenRouter)",
        reasoning: false,
        input: ["text"],
        cost: { input: 0.435, output: 0.87, cacheRead: 0.003625, cacheWrite: 0 },
        contextWindow: 700000,
        maxTokens: 384000
      }
    ]
  });
}
