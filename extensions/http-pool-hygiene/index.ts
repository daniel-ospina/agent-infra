/**
 * extensions/http-pool-hygiene/index.ts — dead-connection reuse defence (#1110).
 *
 * Wires `pool-hygiene.mjs` into pi:
 *
 *   factory        resolve pi's own undici, build the hygienic dispatcher,
 *                  install the resilient fetch wrapper as `globalThis.fetch`
 *   session_start  re-assert the wrapper if anything replaced it
 *   turn_start     cheap identity re-check (pi reconfigures the dispatcher on
 *                  settings changes; the wrapper must stay outermost)
 *   message_end    a transport-class `stopReason: "error"` (e.g. a mid-stream
 *                  `terminated` kill, which fetch CANNOT catch because the
 *                  response was already handed to the caller) flushes the pool
 *                  so pi's own retry starts from an empty pool.
 *
 * The mechanism and its rationale live in `pool-hygiene.mjs`; this file is only
 * wiring. It never throws: a resolution failure degrades to a loud warning and
 * leaves pi's transport untouched (documented in README.md).
 *
 * Kill switch: PI_HTTP_POOL_HYGIENE=0 (also `false`/`disabled`)
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import {
  DISABLE_ENV,
  createResilientFetch,
  installResilientFetch,
  isWrapperInstalled,
  isConnectionClassMessage,
  readIdleTimeoutFromSettings,
  resolveDispatcherOptions,
  resolvePiUndici,
  resolveRetryHosts,
} from "./pool-hygiene.mjs";
import { existsSync, readFileSync } from "node:fs";

/** Log prefix — greppable, and shared with the test suite's assertions. */
export const LOG_PREFIX = "[http-pool-hygiene]";

/** Subset of the pi message shape this extension inspects. */
export interface AssistantMessageLike {
  role?: string;
  stopReason?: string;
  errorMessage?: string;
}

export interface HygieneDeps {
  /** Resolve undici (injectable for tests). */
  resolveUndici?: typeof resolvePiUndici;
  /** Settings reader (injectable for tests). */
  readSettings?: () => unknown | null;
  /** models.json reader (injectable for tests) — source of the retry allowlist. */
  readModels?: () => unknown | null;
  log?: (...args: unknown[]) => void;
  warn?: (...args: unknown[]) => void;
  env?: NodeJS.ProcessEnv;
}

/** Module-level handle so tests can drive/observe a single install. */
export interface HygieneHandle {
  wrapper: ReturnType<typeof createResilientFetch> | null;
  status: "installed" | "disabled" | "undici-unresolved" | "already-installed" | "install-failed";
  undiciPath: string | null;
  undiciSource: string | null;
  /** Hosts whose requests the wrapper may re-send (never non-provider traffic). */
  retryHosts: string[];
}

let handle: HygieneHandle = { wrapper: null, status: "disabled", undiciPath: null, undiciSource: null, retryHosts: [] };

/** Test seam — current install state. */
export function getHygieneHandle(): HygieneHandle {
  return handle;
}

/** Test seam — reset module state between runs. */
export function __resetHygieneForTests(): void {
  handle = { wrapper: null, status: "disabled", undiciPath: null, undiciSource: null, retryHosts: [] };
}

/**
 * Kill-switch values. `0`/`false` mirror pi's boolean-style settings; `disabled`
 * mirrors pi's own `httpIdleTimeoutMs: "disabled"` spelling (and the extension's
 * own announcement). A kill switch that silently ignores a documented spelling is
 * worse than no kill switch — it reads as armed while the extension stays on.
 */
function isDisabled(env: NodeJS.ProcessEnv): boolean {
  const value = env[DISABLE_ENV]?.trim().toLowerCase();
  return value === "0" || value === "false" || value === "disabled";
}

/**
 * Build + install. Returns the handle (never throws).
 */
export function installHygiene(deps: HygieneDeps = {}): HygieneHandle {
  const env = deps.env ?? process.env;
  const log = deps.log ?? console.log;
  const warn = deps.warn ?? console.warn;

  if (isDisabled(env)) {
    handle = { wrapper: null, status: "disabled", undiciPath: null, undiciSource: null, retryHosts: [] };
    log(`${LOG_PREFIX} ${DISABLE_ENV}=0 — connection-pool hygiene disabled`);
    return handle;
  }

  const resolveUndici = deps.resolveUndici ?? resolvePiUndici;
  const resolved = resolveUndici();
  if (!resolved.undici) {
    // Loud, never silent: an unresolved undici means pi keeps its unbounded
    // keep-alive ceiling and dead pooled sockets stay reachable (#1110).
    handle = {
      wrapper: null,
      status: "undici-unresolved",
      undiciPath: null,
      undiciSource: resolved.source,
      retryHosts: [],
    };
    warn(
      `${LOG_PREFIX} ⚠️ undici could not be resolved from pi's install — dead-connection reuse ` +
        `protection is OFF (#1110). Sessions may fail retries after a connection kill.`,
    );
    return handle;
  }

  const settings = deps.readSettings?.() ?? null;
  const options = resolveDispatcherOptions(env, { settingsJson: settings });
  const retryHosts = resolveRetryHosts({ env, modelsJson: deps.readModels?.() ?? null });
  const wrapper = createResilientFetch({
    fetchImpl: resolved.undici.fetch as unknown as typeof fetch,
    undici: resolved.undici,
    options,
    retryHosts,
    log,
  });

  const result = installResilientFetch(wrapper);
  handle = {
    wrapper,
    status: result.installed ? "installed" : (result.reason as HygieneHandle["status"]),
    undiciPath: resolved.path,
    undiciSource: resolved.source,
    retryHosts: [...retryHosts],
  };
  log(
    `${LOG_PREFIX} ${result.installed ? "installed" : result.reason} — ` +
      `keepAliveMaxTimeout=${options.keepAliveMaxTimeout}ms (server hint ceiling), ` +
      `transparent retry hosts=${retryHosts.size ? [...retryHosts].join(",") : "none (provider writes only)"}, ` +
      `undici=${resolved.source}${resolved.path ? ` (${resolved.path})` : ""}`,
  );
  return handle;
}

/** Default settings reader — pi's global agent settings file. */
export function readGlobalSettings(deps: { env?: NodeJS.ProcessEnv } = {}): unknown | null {
  const env = deps.env ?? process.env;
  const settings = readIdleTimeoutFromSettings(agentDirFile(env, "settings.json"));
  return settings === null ? null : { httpIdleTimeoutMs: settings };
}

/** Default models.json reader — the configured providers are the retry allowlist. */
export function readGlobalModels(deps: { env?: NodeJS.ProcessEnv } = {}): unknown | null {
  const file = agentDirFile(deps.env ?? process.env, "models.json");
  if (!file || !existsSync(file)) return null;
  try {
    return JSON.parse(readFileSync(file, "utf8"));
  } catch {
    return null;
  }
}

function agentDirFile(env: NodeJS.ProcessEnv, name: string): string | null {
  const agentDir = env.PI_CODING_AGENT_DIR?.trim() || `${env.HOME ?? ""}/.pi/agent`;
  return agentDir ? `${agentDir}/${name}` : null;
}

/**
 * Re-assert the wrapper if something replaced `globalThis.fetch`.
 *
 * ALSO the runtime-reconfiguration hook. pi rebuilds its OWN dispatcher when
 * `httpIdleTimeoutMs` changes at runtime (the settings UI's
 * `onHttpIdleTimeoutMsChange` → `configureHttpDispatcher(timeoutMs)`), but it
 * does NOT replace `globalThis.fetch` once ours is installed — pi only
 * re-installs its own fetch when it still sees the fetch *it* installed
 * (`shouldInstallGlobals`). So `isWrapperInstalled()` staying true is NOT
 * evidence that nothing changed: this call is the only place that can notice a
 * settings change, and it must therefore re-resolve the configuration every
 * time. `wrapper.reconfigure` is idempotent — an unchanged configuration does
 * not rotate the pool, so steady-state reuse is untouched.
 *
 * The NEW fetch is adopted as the wrapper's base (`rebase`) rather than
 * discarded: another extension may have deliberately instrumented fetch after
 * we loaded, and clobbering it would silently drop its work. Returns true when
 * a re-assert (re-install) happened.
 */
export function reassertFetchWrapper(
  wrapper: ReturnType<typeof createResilientFetch> | null,
  log: (...args: unknown[]) => void = () => {},
  refresh?: () => { options?: unknown; retryHosts?: Set<string> } | undefined,
): boolean {
  if (!wrapper) return false;
  // Re-resolve the transport configuration FIRST, whether or not the wrapper was
  // displaced — this is what makes a runtime `httpIdleTimeoutMs` change (and a
  // provider added to `models.json` after install) take effect instead of being
  // pinned to whatever was current at install.
  if (typeof refresh === "function") {
    const next = refresh();
    wrapper.reconfigure(next?.options, next?.retryHosts);
  }
  if (isWrapperInstalled(wrapper)) return false;
  const foreign = globalThis.fetch;
  if (typeof foreign === "function") wrapper.rebase(foreign);
  installResilientFetch(wrapper);
  log(`${LOG_PREFIX} re-asserted fetch wrapper (adopted the fetch that replaced it, not discarded)`);
  return true;
}

/**
 * The message_end policy, extracted so it is directly testable:
 * flush the pool exactly when a turn died on a transport-class error.
 */
export function shouldFlushOnMessageEnd(message: AssistantMessageLike | undefined): boolean {
  if (!message || message.stopReason !== "error") return false;
  return isConnectionClassMessage(message.errorMessage ?? "");
}

/**
 * Extension body. Injectable for tests; the default export wires the real
 * pi-ai/undici resolution.
 */
export async function runExtension(pi: ExtensionAPI, deps: HygieneDeps = {}): Promise<void> {
  const env = deps.env ?? process.env;
  // ONE settings reader for both install and every re-assert. `deps.readSettings`
  // is a test seam; the production path must fall back to the real file, or the
  // first re-assert would pass `settingsJson: null`, silently resetting the
  // user's `httpIdleTimeoutMs` (including `0` = disabled) to the 300 s default.
  const readSettings = deps.readSettings ?? (() => readGlobalSettings({ env }));
  const readModels = deps.readModels ?? (() => readGlobalModels({ env }));
  const refresh = () => ({
    options: resolveDispatcherOptions(env, { settingsJson: readSettings() }),
    retryHosts: resolveRetryHosts({ env, modelsJson: readModels() }),
  });
  try {
    installHygiene({ readSettings, readModels, ...deps });
  } catch (err) {
    // Containment: a broken hygiene install must never block pi startup.
    const warn = deps.warn ?? console.warn;
    warn(`${LOG_PREFIX} install failed (transport left untouched): ${err instanceof Error ? err.message : String(err)}`);
    handle = { wrapper: null, status: "install-failed", undiciPath: null, undiciSource: null, retryHosts: [] };
    return;
  }

  pi.on("session_start", () => {
    reassertFetchWrapper(handle.wrapper, deps.log ?? console.log, refresh);
  });

  pi.on("turn_start", () => {
    reassertFetchWrapper(handle.wrapper, deps.log ?? console.log, refresh);
  });

  pi.on("message_end", (event) => {
    const message = (event as { message?: AssistantMessageLike } | undefined)?.message;
    if (!shouldFlushOnMessageEnd(message)) return;
    handle.wrapper?.flush(`message_end: ${message?.errorMessage ?? "connection error"}`);
  });
}

export default function (pi: ExtensionAPI): Promise<void> {
  return runExtension(pi);
}
