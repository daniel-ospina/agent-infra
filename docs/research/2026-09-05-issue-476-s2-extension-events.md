---
title: "Issue #476 s2 — extension-event semantics for detecting provider credit exhaustion (HTTP 402)"
type: engineering
domain: operations
doc_status: live
subjects.team: epistemic-team
created: 2026-09-05
aboutSubjects: provider-failover, builtin-tools, task-heartbeat, provider-failover-extension
aboutObjects: agent-infra, pi, issue-476
---

# Issue #476 s2 — Extension-Event Semantics for Detecting Provider Credit Exhaustion (HTTP 402)

- **Date:** 2026-09-05
- **Spike:** s2 (issue #476 — provider-exhaustion failover)
- **Question:** (1) Does `message_end` fire when an assistant turn FAILS (stopReason `"error"`/provider error)? Does its payload carry `errorMessage` text and any status code? (2) Does `after_provider_response` fire on HTTP 402 and with what fields? (3) Best interactive latch key for "provider returned 402"; enumerate every event/hook exposing an HTTP status or provider error. (4) Do extension events fire in `pi -p` print-mode children too? (5) Full ExtensionAPI hook list relevant to observing provider failures.
- **Method:** Read-only source analysis. Repo: `.worktrees/476/` (`pi-bootstrap/pi-config/models.json` — api used by agent-infra models). Pi runtime `…/node_modules/@earendil-works/pi-coding-agent/`: `dist/core/sdk.js`, `dist/core/agent-session.js`, `dist/core/extensions/types.d.ts`, `dist/modes/print-mode.js`, `dist/modes/interactive/interactive-mode.js`, plus deps `@earendil-works/pi-agent-core/dist/agent.js|agent-loop.js`, `@earendil-works/pi-ai/dist/api/{pi-messages,openai-completions,anthropic-messages,mistral-conversations}.js`, `@earendil-works/pi-ai/dist/utils/{retry,provider-retry,error-body}.js`, `node_modules/{openai,anthropic}/client.js`. No web searches, no git ops.

## Findings

### 1. `message_end` DOES fire on failed turns, with `errorMessage` text but NO status code
- Provider functions never reject the turn uncaught: they push an `{type:"error", reason:"error", error: assistantMessage}` event onto the stream (`pi-messages.js` L293; `openai-completions.js` catch → L486, stream error event; `anthropic-messages.js` same pattern). The agent loop consumes it as a terminal event and **always emits `message_end`**: `agent-loop.js` L229–241 (`case "error"` → `response.result()` → `emit({type:"message_end", message: finalMessage})`, L240).
- If the provider fn truly THROWS, `agent.js` `runWithLifecycle` catches (L343) and `handleRunFailure` (L349–366) synthesizes a failure assistant message and emits `message_start` → `message_end` (L362) → `turn_end` → `agent_end`. `message_end` therefore fires on every failed turn in both paths.
- The failed message shape (pi-ai `AssistantMessage`): `stopReason: "error" | "aborted"`, `errorMessage?: string` (`pi-ai/dist/types.d.ts` L305–324). **No status/numeric field exists on the message.** `agent.js` L357–358 sets `stopReason: aborted ? "aborted" : "error"` and `errorMessage: error.message`. Whether the text contains `"402"` depends on the API layer: pi-messages prefixes it (`"402 Payment Required: …"`, `pi-messages.js` L45); SDK paths carry provider body text (`error-body.js` `formatProviderError`) which may omit the numeric status (Anthropic bodies are plain text; OpenAI error strings usually include the code, not the HTTP status).
- Extension payload for `message_end` is exactly `{type:"message_end", message}` (`agent-session.js` L484–495 → `extensionRunner.emitMessageEnd`), typed `MessageEndEvent {type; message: AgentMessage}` (`types.d.ts` L588–592). No status code anywhere.

### 2. `after_provider_response` fires only on statuses the API layer lets through; fields = status + headers only
- Single emission site: `sdk.js` L215–225 — `onResponse` hook gated on `runner.hasHandlers("after_provider_response")` (L217), emitting `{type:"after_provider_response", status: response.status, headers: response.headers}`. Payload type `AfterProviderResponseEvent {type; status: number; headers: Record<string,string>}` (`types.d.ts` L533–540). **No body, no error text.**
- The hook is invoked by each provider API implementation after the HTTP call. Whether it fires on 402 splits by transport:
  - **Raw-fetch APIs call it BEFORE their `!response.ok` gate → fires on ANY status incl. 402:** `pi-messages.js` L272–281 (fetch → `onResponse` L275 → `if(!response.ok) throw` L278–281); `mistral-conversations.js` L171–174 (same order).
  - **SDK-backed APIs never fire it on non-2xx — the SDK throws first:** `openai-completions.js` L185–190 (awaited `client.chat.completions.create(...).withResponse()` inside `retryProviderRequest`, then `onResponse` L190); `openai/client.js` L408+ `if(!response.ok)` → throws `APIError` (L258 area); same for `anthropic-messages.js` L382–387 / `node_modules/@anthropic-ai/sdk/client.js` `makeRequest` `!response.ok` → `throw err`. A 402 is not retried (`provider-retry.js` L17–21 retries only 408/409/429/5xx), so it surfaces as an exception before `onResponse`.
- agent-infra's own models (`pi-bootstrap/pi-config/models.json`) use `"api": "openai-completions"` → **for the real #476 provider paths, `after_provider_response` will NOT fire on a 402.**

### 3. Interactive latch candidates — only ONE event exposes a structured HTTP status
- `after_provider_response` (`status: number`) is the ONLY extension event carrying an HTTP status. Its 402-firing is transport-dependent (Finding 2). When it fires (raw-fetch APIs, or any 2xx call) it fires for EVERY provider HTTP call inside a turn — including tool-loop iterations and each retry — before the stream is consumed (`types.d.ts` L533 doc comment), so it is early but noisy (needs per-provider-call state).
- `message_end` fires on ALL failed turns with `message.errorMessage` (text only, status-code presence provider-dependent) — available on every path including openai-completions.
- `turn_end` carries the same failed `message` object (`types.d.ts` L570–575; emitted after `message_end` per `agent-loop.js` L229–241 + L108), `agent_end` carries the whole `messages` array (L555–562), `agent_settled` carries nothing. None carry a status.
- **No session-level error event exists.** Session events are `session_start`, `session_info_changed`, `session_before_*`, `session_compact`, `session_compact_failed` (has `errorMessage?` — compaction only, L464–476), `session_shutdown` (teardown reason only), `session_tree` (`types.d.ts` L798 union, L416–530). No `session_end`/`session_error` event with provider errors.
- Corroboration: pi treats exhaustion wording as NON-retryable (`pi-ai/dist/utils/retry.js` L4–16: `insufficient_quota`, `"billing"`, `"available balance"`, `"quota exceeded"`, `"Monthly usage limit reached"` → `isRetryableAssistantError` false, L168–174), so a 402 turn is terminal (no silent auto-retry to mask it).

### 4. Extension events DO fire in print-mode (`pi -p`) children
- `dist/main.js` builds ONE runtime/session (L674, extensions loaded in the shared session construction: `agent-session.js` L2124–2129 creates `ExtensionRunner` from `resourceLoader.getExtensions()` and publishes it to `extensionRunnerRef`) and dispatches modes from the same runtime (L760+). `pi -p`/json → `runPrintMode` receives `runtimeHost.session` (`print-mode.js` L18, L52) and calls `session.bindExtensions(...)` (L53) exactly like interactive (`interactive-mode.js` L1447). Extension event dispatch is mode-independent: the AgentSession bridges every agent event to the extension runner in `_handleAgentEvent` → `_emitExtensionEvent` (`agent-session.js` L343, L442–533) for BOTH modes. Print text mode additionally mirrors a failed last message to stderr and exits 1 (`print-mode.js` L112–120: `stopReason error/aborted` → `console.error(errorMessage)`).
- So sub-agents / headless runs (the failover children in #476) fire `message_end`/`turn_end`/`agent_end`/`agent_settled` to loaded extensions, and `after_provider_response` when their transport allows (Finding 2).

### 5. ExtensionAPI surface relevant to observing provider failures (complete `on()` list)
`types.d.ts` L891+ `ExtensionAPI.on(...)`: `project_trust`, `resources_discover`, `session_start`, `session_info_changed`, `session_before_switch|fork|compact|tree`, `session_compact`, `session_compact_failed`, `session_shutdown`, `session_tree`, `context`, `before_provider_request`, `before_provider_headers`, `after_provider_response`, `before_agent_start`, `agent_start`, `agent_end`, `agent_settled`, `turn_start`, `turn_end`, `message_start`, `message_update`, `message_end`, `tool_execution_start|update|end`, `model_select`, `thinking_level_select`, `tool_call`, `tool_result`, `user_bash`, `input` — plus imperative `registerTool/registerCommand/registerShortcut/registerFlag/registerMessageRenderer/registerProvider/setModel/sendMessage/sendUserMessage/exec/appendEntry/…` (types.d.ts L924–~1010). **Provider-failure-relevant: `after_provider_response` (only status), `message_end`/`turn_end`/`agent_end` (via `message.errorMessage`).**

## Verdicts
- message_end on failed turns w/ errorMessage: **YES** — fires for every failed turn (stream-error event or thrown-error synthesis) with `message.errorMessage`; NO structured status, text only (agent-loop.js L229–241, agent.js L349–366).
- after_provider_response on 402 w/ status: **PARTIAL/NO for agent-infra** — fires with `{status, headers}` only on transports that reach `onResponse` before the ok-gate (pi-messages/mistral); SDK-backed `openai-completions` (agent-infra's api) throws on 402 before the hook → no event (sdk.js L215–225 vs openai-completions.js L185–190).
- interactive latch key status===402 viable: **PARTIAL** — the only status-bearing event, but unreliable for the real provider paths; fallback = `message_end` errorMessage-text latch (needs text/pattern, not status).
- extension events fire in `pi -p` children: **YES** — same runtime/session + `bindExtensions` in print-mode.js L53.

## Implications for the #476 design
- **`message_end` → in-child stderr marker survives source contact.** It fires on the failure in both interactive and print children with `errorMessage` text; the child extension handler can emit the exhaustion marker on the failing turn (matches sB1 contract). Caveat: classify by TEXT (pattern over `errorMessage`), not a numeric status — there is no status on the message; pi-messages/mistral prefix `"402"`, SDK errors may not.
- **`after_provider_response.status === 402` as the interactive latch is fragile as-designed.** For the openai-completions/openai-responses/anthropic SDK paths used by agent-infra providers, the 402 throws inside the SDK and the hook never fires; and where it does fire it fires on every intermediate 2xx provider call, so a latch needs per-call state anyway. Prefer latching `message_end` (stopReason `"error"` + exhaustion text) or make the latch tolerant of both signals.
- **No session-end error event** exists to use as a clean session-scoped hook; per-turn events (`message_end` → `agent_end` → `agent_settled`) are the only reliable observability, and `agent_settled` is the earliest point where the whole run is known terminal.
- pi's own retry layer already classifies exhaustion wording as non-retryable, so a 402 turn is terminal rather than auto-retried — the extension only needs to observe, not outrace a retry loop, but it must hook events fast (provider errors surface within the single failing turn).
