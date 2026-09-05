---
title: "Issue #476 sC3 — session_start setModel semantics vs CLI --model (print & interactive)"
type: engineering
domain: operations
doc_status: live
subjects.team: epistemic-team
created: 2026-09-05
aboutSubjects: provider-failover, builtin-tools, provider-failover-extension
aboutObjects: agent-infra, pi, issue-476
---

# sC3 Finding — `session_start` setModel semantics vs CLI `--model` (print & interactive)

**Date:** 2026-09-05
**Spike:** sC3 (issue #476 — provider-exhaustion failover)
**Researcher:** source-verification agent
**Source:** pi runtime dist at `/Users/danielospina/.local/share/pi-node/node-v22.23.2-darwin-arm64/lib/node_modules/@earendil-works/pi-coding-agent/dist/` (path prefix `P:` below)
**Method:** grep dist for `setModel` / `session_start` / `getModel`; read print-mode entry, session construction, extension runner, interactive init ordering. No web, no git.

## Findings

1. **CLI model is resolved at session construction and baked into `agent.state.model` BEFORE any extension event fires.**
   `main.js:353` `resolveCliModel({cliProvider: parsed.provider, cliModel: parsed.model, ...})` → `options.model` (in `buildSessionOptions`); `main.js:651-659` passes `model: sessionOptions.model` into `createAgentSessionFromServices`; chunk `createAgentSession`: `agent = new Agent({initialState:{systemPrompt:"", model, thinkingLevel, tools:[]}, ...})`. So with `pi -p --provider X --model Y`, `agent.state.model = Y` from the moment the session exists. Extension *factories* run during resource loading (registering handlers) but no `session_start` handler has fired yet, and no request has been made.

2. **`session_start` is emitted ONLY from `session.bindExtensions()` — never at construction.**
   `P:core/agent-session.js:150` default `_sessionStartEvent = {type:"session_start", reason:"startup"}`; emitted at `agent-session.js:1851` inside `bindExtensions()` (1831-1852). `_buildRuntime` (2120-2135) creates the ExtensionRunner and binds core actions but does NOT emit `session_start`. Emission happens per mode:
   - **Print:** `P:modes/print-mode.js` `rebindSession()` calls `session.bindExtensions({mode:"print"|"json", ...})`; `runPrintMode` does `await rebindSession()` **before** `initialMessage`/`messages` loop calls `session.prompt(...)` (print-mode.js, prompt calls at end of try block). Single emission, reason `"startup"` (initial runtime is created with no `sessionStartEvent`, main.js:674).
   - **Interactive:** `interactive-mode.js:1445-1447` `bindCurrentSessionExtensions()` → `session.bindExtensions({mode:"tui", ...})`; called from `init()` via `rebindCurrentSession()` (interactive-mode.js:757, 1555). UI starts first (comment at 693) then `run()` fires `initialMessage`/`initialMessages` prompts (859-872) and the user-turn loop (878+). So `session_start` precedes the first request here too.

3. **`ctx.model` is populated at `session_start`; there is no `ctx.getModel()` method — in ANY mode.**
   Handler ctx is built by `ExtensionRunner.createContext()` (P:core/extensions/runner.js:455-530): it exposes a `get model()` getter that calls `this.getModel` (runner.js:461-483), but never adds a `getModel` function. `this.getModel` defaults to `() => undefined` (runner.js:129) and is replaced at `bindCore` with the session's `getModel: () => this.model` context action (agent-session.js:1984, wired at runner.js:175). Session getter `get model() { return this.agent.state.model; }` (agent-session.js:583-584). Net: at print `session_start`, `ctx.model` = CLI model `Y`; `ctx.getModel` is `undefined` (absent) — true in print AND interactive AND rpc (types.d.ts `ExtensionContext` ~209-253 declares only the `model` property; no `getModel`; `getModel` exists only as the internal `ExtensionContextActions` slot, types.d.ts:1244). The module-level `pi` API (loader.js `createExtensionAPI`) exposes `setModel` but also NO `getModel`.
   *Nuance vs plan wording:* "ctx.getModel() undefined in print mode" is technically true but not print-specific — the method does not exist on handler contexts anywhere in this dist.

4. **`setModel` semantics: mutates `agent.state.model` immediately; applies at next request/turn start. It does not re-drive or rewrite an in-flight request; it is NOT "future turns only" with respect to session_start.**
   `agent-session.js:1201-1219` `setModel(model, options={})`: `checkAuth` → `this.agent.state.model = model` → `sessionManager.appendModelChange` → optional `persist` → `setThinkingLevel` → `_emitModelSelect(model, previousModel, "set")`. Model for a request is snapshotted at run/turn start: agent `createLoopConfig` returns `model: this._state.model` (chunk) and the per-turn refresh hook returns `model: this.agent.state.model` fresh each turn (agent-session.js:302-322 `prepareNextTurnWithContext`). Because `session_start` fires BEFORE the first `session.prompt` in both modes (finding 2), a `session_start` handler calling `pi.setModel(newProvider,newModel)` changes `agent.state.model` before the first loop starts → **the FIRST request uses the new model, overriding CLI `--model`**. CLI `--model` is the initial value only; nothing locks it. There is no documented "future turns only" caveat (docs/extensions.md:1686-1701 documents only "Set the current model. Returns false if no API key"). If `setModel` were called while a request is mid-stream, the in-flight stream keeps the model captured at loop start and the change applies from the next turn/request onward.

5. **No reason field on `setModel`; `model_select` carries a fixed `source`.**
   Extension API: `setModel(model)` only (loader.js:338-341; types.d.ts:986). Session `setModel(model, options)` only supports `options.persist` (agent-session.js:1201; interactive call sites 4011 `{persist:false}`, 4142 `{persist}`, 4734 `{persist:true}`). `_emitModelSelect` emits `model_select` with hardcoded `source: "set"` (agent-session.js:1188-1198, 1215-1218) — no "startup"/"manual" provenance. `session_start` reason is only `"startup"|"reload"|"new"|"resume"|"fork"` (types.d.ts:416-423; agent-session-runtime.js:141,165,211,229,246,283). A provider-failover extension **cannot pass its own reason** through `setModel` today.

## Verdicts

- session_start fires pre-first-request: **YES** (print: print-mode.js rebind→bindExtensions before prompts; interactive: init→bind before run() prompts/loop)
- ctx.model populated at session_start: **YES** (runner.js ctx.model getter → agent-session getModel action → agent.state.model = CLI model)
- ctx.getModel() undefined in print: **YES** — and in every other mode (no such method on handler ctx in this dist)
- setModel = future turns only: **NO as blanket rule** — it is "next request onward"; against an *in-flight* stream it is effectively future-turns-only (no re-drive), but a `session_start` call happens before any request, so it governs turn 1
- session_start setModel can override CLI --model for turn 1 in print: **YES** (state mutation precedes first prompt; nothing re-locks the CLI model)

## Implications for #476 design

- **A proactive `session_start` hop in a print child IS technically viable** to override the child's CLI `--model` for its very first (and only) request — but this is exactly what the plan does NOT want for print children (CLI `--model` must stay authoritative there). Therefore the extension must **NOT call setModel from `session_start` in print children**; it should gate on `ctx.mode` (`"print"`/`"json"` → leave CLI model untouched; `"tui"` → hop allowed). In interactive, `session_start` runs before the first prompt too, so the same guard applies if the design also wants `pi -p` CLI input respected in interactive-with-initial-message.
- Because setModel takes effect from the *next request start* and interactive prompts run one user turn at a time, a latch-clearing (return-to-primary) hop in interactive changes the **next user turn onward** — no in-flight turn is disturbed. Confirmed viable: interactive-mode loop calls `session.prompt(userInput)` per turn; `setModel` between turns only rewrites `agent.state.model` for the next loop.
- In print, a *mid-run* failover hop is impossible for turn 1 by construction (single prompt; session_start precedes it). Any print-mode failover must therefore either (a) accept the CLI model for turn 1 and rely on turn-level retry/steering that print mode does not have, or (b) detect exhaustion only for interactive/RPC where a subsequent turn exists. If #476 wants print children to fail over at all, the extension must use a mechanism that fires before the request *within* the run — `setModel` alone cannot re-drive the in-flight first request.
- No reason provenance exists for setModel hops; the extension cannot tag its own reason. The `model_select` event it triggers carries `source:"set"`, indistinguishable from a manual `/model` switch. If provenance matters for logging/debugging #476 hops, the extension should record its own side-channel (e.g., appendEntry/custom event) or request a future runtime reason param.
