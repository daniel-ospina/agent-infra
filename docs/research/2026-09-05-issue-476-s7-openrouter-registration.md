---
title: "Issue #476 s7 — openrouter deepseek-slug hop legs via the custom-provider-openrouter extension models array"
type: engineering
domain: operations
doc_status: live
subjects.team: epistemic-team
created: 2026-09-05
aboutSubjects: provider-failover, custom-provider-openrouter, check-cost-config
aboutObjects: agent-infra, pi, issue-476
---

# Issue #476 s7 — openrouter deepseek-slug hop legs via the custom-provider-openrouter extension models array

Date: 2026-09-05 · Spike: s7 (provider-exhaustion failover) · Branch: feat/476-provider-failover
Runtime read: pi dist @ `/Users/danielospina/.local/share/pi-node/node-v22.23.2-darwin-arm64/lib/node_modules/@earendil-works/pi-coding-agent` (dist, line refs below). No keys read or printed.

## Question
Registering openrouter deepseek-slug hop legs in a RUNNING pi session via the existing custom-provider-openrouter extension models array: merge semantics vs models.json, modelOverrides interaction, slash-id acceptance, registration form, 300K-clamp survival + cost-guard scope, live-vs-template/live-farm state.

## Method
Read-only: pi dist JS (provider-composer, model-runtime, model-registry, model-resolver, model-config, extensions/runner+loader, types.d.ts), pi-ai dist (openrouter builtin, openai-completions body), repo (extension index.ts, pi-bootstrap/pi-config/models.json + models-store.json, scripts/check-cost-config.sh, pi-bootstrap/setup.sh, sync.sh), live agent dir (~/.pi/agent models.json/models-store.json/extensions, key values scrubbed). jq/python tree walks only; no secrets exposed.

## Findings

1. **Merge semantics: the extension models array REPLACES, not unions.** Compose pipeline is `base(builtin) → applyModelsJson(models.json cfg) → applyExtension(extension cfg) → per-id modelOverrides` (provider-composer.js:292-300). `applyExtension` (provider-composer.js:112-127): when `config.models` is present it returns ONLY `config.models.map(...)` — the incoming (builtin+models.json) list is discarded; it is consulted solely as `defaults` for `api`/`baseUrl` per matching id (or models[0]) at lines 119-124. Legacy re-registration merges only the provider-level config object (`{...previous}` + defined keys, model-runtime.js:562-568); the `models` ARRAY value is replaced wholesale — no per-model union. JSDoc states it outright: "If `models` is provided: replaces all existing models for this provider" (types.d.ts:994, 1083). **Observable today**: live models.json `openrouter` defines NO models (only `modelOverrides`), yet the extension's single opus model is the openrouter list — the 276-362-slug pi.dev catalog is already fully replaced by the extension at runtime.

2. **modelOverrides DO apply to extension-registered models, and the override wins per field.** `modelOverrides` is applied LAST, after extension replacement, keyed by composed `model.id` only: `const override = config?.modelOverrides?.[model.id]; return override ? applyModelOverride(model, override) : model` (provider-composer.js:297-300). `applyModelOverride` uses nullish precedence — `contextWindow: override.contextWindow ?? model.contextWindow` (provider-composer.js:40) — so `providers.openrouter.modelOverrides["deepseek/deepseek-v4-flash"].contextWindow = 300000` clamps an extension-registered leg of the same id regardless of the leg's own contextWindow. No provider-prefix in the override key space: key == model id.

3. **Slash-containing model ids are fully supported; the id IS the upstream slug.** No validation rejects slashes: models.json schema `id: Type.String({minLength: 1})` (model-config.js:137); extension `ProviderModelConfig.id: string` (types.d.ts:1111); `applyExtension` performs no id checks. pi's id namespace is (provider, id) — full ref `openrouter/deepseek/deepseek-v4-flash`, store keys `provider\0id` (model-runtime.js) — and the openai-completions request sends `model: model.id` verbatim (pi-ai dist/api/openai-completions.js:156), so OpenRouter routes on the literal slug. The current extension already ships slash id `anthropic/claude-opus-4.8`, and the resolver treats OpenRouter-style slash ids as first-class (`defaultModelPerProvider.openrouter = "moonshotai/kimi-k2.6"`; CLI inference comments, model-resolver.js:388, 410). **Caveat**: a BARE `deepseek/deepseek-v4-flash` ref resolves via provider-inference to the models.json `deepseek` provider when one exists (model-resolver.js:319-341) — hop legs must be addressed canonically (`openrouter/deepseek/deepseek-v4-flash`), which is the standard addressing for slash-id openrouter models anyway.

4. **Registration form = legacy/config form (plan's "extension-legacy-form" — correct).** Extension calls the two-arg overload `registerProvider(name, config)` (extensions/custom-provider-openrouter/index.ts:5). Overloads at types.d.ts:1043-1044; dispatch at model-registry.js:85-93 (string branch → `runtime.registerProvider(name, config)`), stored in `extensionProviders` = the compose "extension" overlay (model-runtime.js:555-568), NOT `nativeExtensionProviders` (native single-arg `registerProvider(provider)` → base, model-runtime.js:546-550). Initial-load registrations are queued and flushed at runner bind (runner.js:186-206); post-bind calls apply immediately (runner.js:228-241).

5. **300K clamps survive; cost guard never scans the extension.** After replacement, effective deepseek-leg cw = 300000 (both the leg's own field and the models.json override agree; override would win even if they disagreed per §2); opus keeps 1000000 (no override key). Guard `scripts/check-cost-config.sh` scans ONLY `$SHIPPED_DIR/pi-bootstrap/pi-config/{models.json, models-store.json, settings.json}` and `$LIVE_DIR/~/.pi/agent/{…}` (lines 43-44, 237-251) — it never parses extension .ts, so extension-registered models are OUT OF SCOPE and cannot false-positive. Flip side: the guard also cannot enforce the clamp on extension legs — models.json `modelOverrides` is the enforcement authority (config wins over catalog AND extension). Live models-store.json today carries deepseek openrouter legs at cw 1024000-1048576 (guard WARN class, lines 249-250).

6. **Live config matches the branch template; the live extension farm loads custom-provider-openrouter.** Live `~/.pi/agent/models.json` openrouter == worktree pi-bootstrap (6 override keys, all 300000); both differ from master (400000) — live is NOT stale vs the branch, it was cost-fixed today (baks: models.json.bak-costfix-20260905, models.json.bak-300k-20260905). Live `~/.pi/agent/extensions/custom-provider-openrouter/index.ts` is byte-identical to the repo copy. Farming: repo symlink farm lives at `pi-bootstrap/pi-config/extensions/*` → `extensions/*`; `setup.sh` materializes real COPIES into `~/.pi/agent/extensions` (keeps only repo-resolving symlinks; lines 152-181). pi discovers `agentDir/extensions/*/index.ts` at load (loader.js:536-563, 608-660; no enable gate). So: a repo edit to the extension models array reaches a RUNNING session only after `setup.sh` re-runs (manual, or `sync.sh` after pull — sync.sh refuses non-main branches, sync.sh:8-14) and the next pi start; the live openrouter copy is currently the single-opus version.

## Verdicts
- extension models array REPLACES models.json models for the same provider id: **YES** (provider-composer.js:112-127, 292-300; types.d.ts:994)
- modelOverrides apply to extension-registered models: **YES** (provider-composer.js:297-300, 40)
- slash model ids accepted: **YES** (no validation; id = upstream slug, pi-ai openai-completions.js:156; already shipped)
- live farm loads custom-provider-openrouter: **YES** (live copy byte-identical; loader.js global-dir discovery)

## Cost-authority caveat (post-review P2)
The shipped models-store openrouter catalog (276 models) carries `deepseek/deepseek-v4-flash`,
`-0731`, `-pro`, `~deepseek/deepseek-v4-flash-latest` — but NOT `-vision-exp` / `-pro-0813`
(those exist only in the live 362-model store). Phase 4 must either register only legs present in
the shipped store, or mark the missing-id legs `costUnknown` — never invent prices (sC2 convention).
The 6 modelOverrides keys remain the clamp authority for whichever legs are registered.

## Phase 4 registration recipe
1. **Edit**: repo `extensions/custom-provider-openrouter/index.ts` models array (single source). Re-run `pi-bootstrap/setup.sh` to re-materialize `~/.pi/agent/extensions/custom-provider-openrouter/index.ts`, then start/reload pi. No models.json models change needed (openrouter provider there is overrides-only by design).
2. **Add legs** as complete `ProviderModelConfig` objects (id/name/reasoning/input/cost/contextWindow/maxTokens — only api/baseUrl inherit from defaults, provider-composer.js:118-124): ids exactly `deepseek/deepseek-v4-flash`, `deepseek/deepseek-v4-pro` (+ -0731/-vision-exp/-0813/`~deepseek/deepseek-v4-flash-latest` if those hop legs are wanted), each `contextWindow: 300000` matching the existing models.json override keys, cost/cw rates sourced from the equivalent `openrouter.models[]` entries in `pi-bootstrap/pi-config/models-store.json` (catalog authority; do not invent prices).
3. **Keep** `providers.openrouter.modelOverrides` (6 keys, 300000) in both shipped and live models.json — they are the guard-facing clamp and win over the extension per §2.
4. **Address canonically** in any failover wiring: `openrouter/deepseek/deepseek-v4-flash`, never the bare slug (§3 caveat).
