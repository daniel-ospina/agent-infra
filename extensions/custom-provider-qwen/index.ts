/**
 * extensions/custom-provider-qwen/index.ts — Qwen high-availability provider (plan T4)
 *
 * Registers a NEW provider id `qwen-ha` serving `qwen3.8-max` on the aliyuncs
 * compatible-mode endpoint, with per-request connection hygiene aimed at the
 * #152 failure mode (mid-stream connection kills → 3 failed retries → session
 * death, because Node's keep-alive pool served the retries a *dead socket* that
 * the aliyuncs load balancer had already reaped).
 *
 * ── Why a NEW provider id instead of overriding "qwen" ──────────────────────
 * pi's legacy `registerProvider("qwen", { ... })` config form accepts only an
 * `api` STRING ("openai-completions") — it cannot inject a custom `fetch` into
 * the OpenAI client. The only way to control connection pooling per provider is
 * the native form: `registerProvider(provider)` where the provider comes from
 * `createProvider({ api })` and `api` is a full `ProviderStreams` object. We
 * wrap pi-ai's real openai-completions streams and inject `options.fetch`.
 * Registering under a NEW id (`qwen-ha`) keeps the existing `qwen`/`qwen-tp`
 * wiring untouched (safer — no surprise behavior change for existing flows) and
 * gives the task-tool fallback work (#152/#154) an explicit target:
 * `TASK_FALLBACK_MODEL=qwen-ha/qwen3.8-max` or provider `qwen-ha`.
 *
 * ── How the fetch override works (verified against pi-ai 0.84.1 dist) ───────
 * `api/openai-completions.js` calls `createClient(model, ctx, apiKey,
 * options?.headers, options?.fetch, ...)` (line 128) and passes `fetch` into
 * `new OpenAI({ apiKey, baseURL, fetch, ... })` (line 514). `StreamOptions`
 * (`ProviderRequestOptions`) declares `fetch?: FetchFunction`. So wrapping the
 * real stream with `{ ...options, fetch: tunedFetch }` is sufficient — the
 * OpenAI SDK will route every qwen-ha HTTP request through our fetch.
 *
 * ── Connection hygiene mechanism ────────────────────────────────────────────
 * The tuned fetch hands every request an undici `Agent` built from this
 * package's OWN undici copy (pi's global dispatcher — keepAliveTimeout driven
 * by `httpIdleTimeoutMs`, currently 10 min — is too permissive for this
 * endpoint, which kills idle connections at ~8 min). The Agent:
 *
 *   pipelining: 0        — undici closes the socket after EVERY response
 *                          (client-h1.js: `socket[kReset] = true` when
 *                          `!client[kPipelining]`). No socket ever outlives a
 *                          request, so the LB can never hold a "dead" socket
 *                          we think is alive. Each assistant turn reconnects.
 *   keepAliveTimeout: 4s — backstop for any lingering-socket path: sockets idle
 *                          >4s are closed client-side, well under the LB TTL
 *                          (~8 min), so the pool never serves a reaped socket.
 *   connections: 4       — cap concurrent sockets per origin (parallel pi
 *                          sessions share the pool; 5th concurrent request
 *                          queues instead of piling onto the endpoint).
 *
 * Tradeoffs (documented): every turn pays a fresh TCP+TLS handshake
 * (~100-300ms on this route). For LLM streaming that is noise vs reliability
 * gain. Requests intentionally bypass pi's global dispatcher (and any
 * HTTP(S)_PROXY env handling it wires via EnvHttpProxyAgent — see
 * `createQwenAgent()` which honors proxy env vars when present).
 *
 * ── Env gates / config (never hardcoded secrets) ────────────────────────────
 *   QWEN_HA_DISABLE=1   — register nothing (logs once).
 *   QWEN_WS_BASE_URL    — endpoint override; default mirrors models.json
 *                         provider "qwen".
 *   QWEN_WS_API_KEY     — API key (existing key, reused — same resolution as
 *                         the stock qwen provider via `envApiKeyAuth`).
 *
 * ── Failure containment ─────────────────────────────────────────────────────
 * The factory never throws: pi-ai load, agent construction, provider build and
 * registration are all inside try/catch → warn + no registration on any setup
 * error, so pi startup is never blocked by this extension.
 *
 * Runtime import resolution: at runtime under pi, "@earendil-works/pi-ai" is
 * jiti-aliased to pi's own compat entry (which re-exports createProvider /
 * envApiKeyAuth / openAICompletionsApi); "undici" resolves from THIS package's
 * node_modules (same pattern as extensions/mcp-client). The factory loads pi-ai
 * lazily via dynamic import so module load stays cheap and failure is contained.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Agent, EnvHttpProxyAgent, fetch as undiciFetch } from "undici";
import type { Dispatcher } from "undici";
import type { FetchFunction, Provider, ProviderStreams } from "@earendil-works/pi-ai";

// ─────────────────────────────────────────────────────────────────────────────
// Identity + config
// ─────────────────────────────────────────────────────────────────────────────

export const PROVIDER_ID = "qwen-ha";
export const MODEL_ID = "qwen3.8-max";

/** Endpoint default — mirrors ~/.pi/agent/models.json provider "qwen". */
export const DEFAULT_BASE_URL =
  "https://ws-t54s8opy1qoqvnrc.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1";

/** API key env vars — same key the existing qwen providers already use. */
export const API_KEY_ENV_VARS = ["QWEN_WS_API_KEY"];

/** Optional endpoint override. */
export const BASE_URL_ENV = "QWEN_WS_BASE_URL";

/** Kill switch: `1` (or `true`) disables registration. */
export const DISABLE_ENV = "QWEN_HA_DISABLE";

// ─────────────────────────────────────────────────────────────────────────────
// Connection hygiene
// ─────────────────────────────────────────────────────────────────────────────

/**
 * undici Agent options for qwen-ha requests.
 *
 * See the header comment for the per-knob rationale. `pipelining: 0` is the
 * primary mechanism (close after every response → zero long-lived sockets);
 * keepAlive* are the idle backstop; connections caps the pool.
 */
export const AGENT_OPTIONS = {
  keepAliveTimeout: 4_000, // idle sockets die client-side at ~4s ≪ LB kill TTL (~8 min)
  keepAliveMaxTimeout: 4_000, // undici's slow-start ceiling — pin to the same value
  keepAliveTimeoutThreshold: 500, // apply the keepalive timer to sockets idle ≥500ms
  connections: 4, // max concurrent sockets per origin (parallel pi sessions)
  pipelining: 0, // undici: no pipelining AND close-after-response (socket[kReset])
  headersTimeout: 300_000, // network-layer backstop only; pi's timeoutMs owns the request budget
  bodyTimeout: 600_000, // matches pi's default httpIdleTimeoutMs request budget
  allowH2: false, // aliyuncs compatible-mode is HTTP/1.1; matches pi's dispatcher
} as const;

/**
 * Build the undici dispatcher used for qwen-ha requests.
 *
 * @param AgentCtor injectable constructor for tests
 * @param options   option overrides (tests)
 *
 * Honors HTTP(S)_PROXY env vars (as pi's global dispatcher does) by switching
 * to EnvHttpProxyAgent — otherwise the tuned Agent would silently bypass a
 * proxy the rest of pi honors. Defaults to the plain Agent when no proxy env
 * var is set.
 */
export function createQwenAgent(
  AgentCtor: typeof Agent = Agent,
  options: Record<string, unknown> = {},
): Dispatcher {
  const proxyConfigured = !!(process.env.HTTP_PROXY || process.env.HTTPS_PROXY ||
    process.env.http_proxy || process.env.https_proxy);
  const Ctor = proxyConfigured ? EnvHttpProxyAgent : AgentCtor;
  return new Ctor({ ...AGENT_OPTIONS, ...options }) as unknown as Dispatcher;
}

/**
 * Wrap the real (undici) fetch so every qwen-ha request goes through
 * `agent` via undici's `init.dispatcher` extension. `init` is spread into a
 * NEW object — the caller's init is never mutated.
 */
export function buildTunedFetch(
  agent: Dispatcher,
  fetchImpl: FetchFunction = undiciFetch as unknown as FetchFunction,
): FetchFunction {
  return (input, init) =>
    fetchImpl(input, { ...init, dispatcher: agent } as RequestInit & { dispatcher: unknown });
}

// ─────────────────────────────────────────────────────────────────────────────
// Stream wrapper — inject the tuned fetch into pi-ai's openai-completions API
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Wrap pi-ai's openai-completions `ProviderStreams` so every stream call
 * receives `options.fetch = tunedFetch`. All other options (apiKey, signal,
 * timeoutMs, headers, …) pass through untouched.
 */
export function buildWrappedApi(realApi: ProviderStreams, tunedFetch: FetchFunction): ProviderStreams {
  return {
    stream: (model, context, options) => realApi.stream(model, context, { ...options, fetch: tunedFetch }),
    streamSimple: (model, context, options) => realApi.streamSimple(model, context, { ...options, fetch: tunedFetch }),
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// Provider assembly
// ─────────────────────────────────────────────────────────────────────────────

/**
 * The slice of pi-ai this extension needs, so tests can stub it without
 * resolving the package (and pi resolves it at runtime via its own jiti
 * aliasing to the compat entrypoint).
 */
export interface PiAiModule {
  createProvider: typeof import("@earendil-works/pi-ai").createProvider;
  envApiKeyAuth: typeof import("@earendil-works/pi-ai").envApiKeyAuth;
  openAICompletionsApi: typeof import("@earendil-works/pi-ai").openAICompletionsApi;
}

/** Resolve the endpoint: QWEN_WS_BASE_URL override, else the known default. */
export function resolveBaseUrl(): string {
  const override = process.env[BASE_URL_ENV]?.trim();
  return override || DEFAULT_BASE_URL;
}

/**
 * Assemble the qwen-ha Provider via pi-ai's createProvider with the wrapped
 * api. The model mirrors models.json provider "qwen" → qwen3.8-max (same
 * compat, thinkingLevelMap, context/maxTokens), so swapping
 * `qwen/qwen3.8-max` → `qwen-ha/qwen3.8-max` is behavior-identical except for
 * the connection hygiene.
 */
export function buildProvider(piAi: PiAiModule, tunedFetch: FetchFunction, baseUrl: string): Provider {
  const api = buildWrappedApi(piAi.openAICompletionsApi(), tunedFetch);
  return piAi.createProvider({
    id: PROVIDER_ID,
    name: "Qwen (High-Availability)",
    baseUrl,
    auth: { apiKey: piAi.envApiKeyAuth("Qwen (High-Availability) API key", [...API_KEY_ENV_VARS]) },
    models: [
      {
        id: MODEL_ID,
        name: "Qwen3.8 Max",
        api: "openai-completions",
        provider: PROVIDER_ID,
        baseUrl,
        reasoning: true,
        input: ["text", "image"],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        contextWindow: 1_000_000,
        maxTokens: 131_072,
        thinkingLevelMap: {
          minimal: null,
          low: "low",
          medium: "medium",
          high: null,
          xhigh: "xhigh",
          max: null,
        },
        compat: {
          thinkingFormat: "qwen",
          supportsDeveloperRole: false,
          supportsStore: false,
          supportsReasoningEffort: false,
        },
      },
    ],
    api,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Extension factory (failure-contained)
// ─────────────────────────────────────────────────────────────────────────────

let disableWarningLogged = false;

/**
 * Extension body. Injectable pi-ai loader keeps tests hermetic; the default
 * export wires the real loader. Never throws.
 */
export async function runExtension(
  pi: ExtensionAPI,
  piAiLoader: () => Promise<PiAiModule>,
): Promise<void> {
  if (process.env[DISABLE_ENV] === "1" || process.env[DISABLE_ENV]?.toLowerCase() === "true") {
    if (!disableWarningLogged) {
      disableWarningLogged = true;
      console.warn(`[custom-provider-qwen] ${DISABLE_ENV}=1 — qwen-ha registration skipped`);
    }
    return;
  }
  try {
    const piAi = await piAiLoader();
    const agent = createQwenAgent();
    const tunedFetch = buildTunedFetch(agent);
    const provider = buildProvider(piAi, tunedFetch, resolveBaseUrl());
    pi.registerProvider(provider);
    console.log(
      `[custom-provider-qwen] registered ${PROVIDER_ID}/${MODEL_ID} — ` +
      `tuned fetch: keepAlive ${AGENT_OPTIONS.keepAliveTimeout}ms, pipelining ${AGENT_OPTIONS.pipelining}, connections ${AGENT_OPTIONS.connections}`,
    );
  } catch (err) {
    // Never throw out of the factory: pi startup must not be blocked.
    console.warn(`[custom-provider-qwen] registration failed (provider not registered): ${err instanceof Error ? err.message : String(err)}`);
  }
}

/** Test seam — reset module-level warn-once state between test runs. */
export function __resetWarnFlagsForTests(): void {
  disableWarningLogged = false;
}

/**
 * pi extension factory. pi-ai is imported lazily (resolved by pi's jiti
 * aliasing to its own compat entrypoint at runtime).
 */
export default function (pi: ExtensionAPI): Promise<void> {
  return runExtension(pi, () => import("@earendil-works/pi-ai"));
}
