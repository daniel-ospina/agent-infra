/**
 * MCP Client Extension for pi
 *
 * Connects to MCP servers defined in .mcp.json and registers
 * each tool as a pi tool with the naming convention:
 *   mcp__<server_name>__<tool_name>
 *
 * Supports both stdio (command + args) and URL-based (SSE) transports.
 *
 * This provides the same MCP tool interface that Claude Code has built-in,
 *
 * SUPABASE MCP TOKEN NOTE: All pi agents share a single SUPABASE_ACCESS_TOKEN.
 * When the Supabase MCP session expires (~1hr inactivity), ALL concurrent agents
 * lose DB access simultaneously. Agents should fall back to psql + $DATABASE_URL.
 * Pre-warming the connection at session start reduces mid-session expiry risk.
 * See #4105 for long-term fix (auto-refresh / per-agent tokens).
 * making skills portable between setups.
 */
/* eslint-disable @typescript-eslint/no-explicit-any */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type, type TSchema } from "typebox";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import type {
  OAuthClientProvider,
  OAuthClientMetadata,
  OAuthClientInformationMixed,
  OAuthTokens,
  OAuthDiscoveryState,
} from "@modelcontextprotocol/sdk/client/auth.js";
import { UnauthorizedError } from "@modelcontextprotocol/sdk/client/auth.js";
import { execSync } from "node:child_process";
import { existsSync, realpathSync, mkdirSync } from "node:fs";
import { readFile, writeFile, rm } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { isPrintMode } from "../shared/print-mode.js";

// ── OAuth config (#595) ────────────────────────────────────────────

/**
 * OAuth configuration for remote HTTP MCP servers.
 *
 * `oauth: true` → auto-discovery: fetch `/.well-known/oauth-protected-resource/<transport-scope>`
 *   metadata; DCR if the server supports dynamic registration; fall back to a config-provided
 *   client_id if `clientId` is supplied.
 *
 * `oauth: { clientId: "..." }` → same auto-discovery path, but uses the provided client_id
 *   instead of (or falling back from) DCR.
 */
export type OAuthConfig = true | { clientId?: string };

/** Server origin → token file path under ~/.pi/mcp-tokens/<origin>/. */
function mcpTokenDir(origin: string): string {
  return join(homedir(), ".pi", "mcp-tokens", origin);
}

/**
 * Read a JSON file from the token store directory, returning `undefined` if missing.
 */
async function readStoreJson<T>(dir: string, file: string): Promise<T | undefined> {
  try {
    const raw = await readFile(join(dir, file), "utf-8");
    return JSON.parse(raw) as T;
  } catch {
    return undefined;
  }
}

/**
 * Write a JSON file to the token store directory, creating the dir and setting chmod 600.
 */
async function writeStoreJson(dir: string, file: string, data: unknown): Promise<void> {
  mkdirSync(dir, { recursive: true });
  const fpath = join(dir, file);
  await writeFile(fpath, JSON.stringify(data, null, 2), { mode: 0o600 });
}

/** Delete a store file (ignore if missing). */
async function deleteStoreFile(dir: string, file: string): Promise<void> {
  try {
    const fpath = join(dir, file);
    await rm(fpath, { force: true });
  } catch {
    /* best effort */
  }
}

/**
 * OAuthClientProvider for pi's mcp-client.
 *
 * Implements RFC 9728 discovery → DCR → PKCE authorization-code flow, with
 * rotating refresh tokens stored per-server under ~/.pi/mcp-tokens/<origin>/.
 *
 * This provider is designed for a CLI environment where:
 *   1. Redirect URLs are printed for the user to open in a browser
 *   2. Authorization codes are provided via the calling code (not an HTTP callback)
 *   3. Token refresh happens transparently on expiry
 *   4. Failed refresh surfaces a clear signal (logged error with re-auth URL)
 */
export class McpOAuthClientProvider implements OAuthClientProvider {
  /** Base URL of the MCP server (used for origin and discovery). */
  private serverUrl: URL;
  /** Optional pre-configured client_id (public client). */
  private configuredClientId?: string;
  /** Path to the token store directory for this server. */
  private storeDir: string;
  /** Cached discovery state. */
  private _discoveryState?: OAuthDiscoveryState;
  /** PKCE code verifier for the current authorization flow. */
  private _codeVerifier?: string;
  /** Token information, cached in-memory during a session. */
  private _tokens?: OAuthTokens;
  /** Cached client information (from DCR or config). */
  private _clientInfo?: OAuthClientInformationMixed;
  /** The authorization URL last emitted. */
  private _pendingAuthUrl?: URL;
  /** Whether we've already logged the re-auth message. */
  private _reauthLogged = false;

  constructor(serverUrl: URL, config: OAuthConfig, storeDir?: string) {
    this.serverUrl = serverUrl;
    const origin = serverUrl.origin.replace(/[^a-zA-Z0-9._-]/g, "_");
    this.storeDir = storeDir ?? mcpTokenDir(origin);
    if (typeof config === "object" && config.clientId) {
      this.configuredClientId = config.clientId;
    }
  }

  // ── OAuthClientProvider implementation ────────────────────────────

  /**
   * The redirect URL presented to the authorization server.
   * For CLI use, we use a loopback URL. The user will be redirected there
   * and we instruct them to copy the authorization code from the URL.
   */
  get redirectUrl(): string | URL {
    return new URL("http://127.0.0.1:24080/callback");
  }

  /** Client metadata describing this MCP client (pi). */
  get clientMetadata(): OAuthClientMetadata {
    return {
      redirect_uris: [String(this.redirectUrl)],
      token_endpoint_auth_method: "none", // public client
      grant_types: ["authorization_code", "refresh_token"],
      response_types: ["code"],
      client_name: "pi-mcp-client",
    };
  }

  /** Load previously registered client information. */
  async clientInformation(): Promise<OAuthClientInformationMixed | undefined> {
    if (this._clientInfo) return this._clientInfo;
    const saved = await readStoreJson<OAuthClientInformationMixed>(
      this.storeDir,
      "client-info.json"
    );
    if (saved) this._clientInfo = saved;
    return saved;
  }

  /** Save client information after DCR (or pre-set a configured client_id). */
  async saveClientInformation(info: OAuthClientInformationMixed): Promise<void> {
    this._clientInfo = info;
    await writeStoreJson(this.storeDir, "client-info.json", info);
  }

  /** Load existing tokens for the current session. */
  async tokens(): Promise<OAuthTokens | undefined> {
    if (this._tokens) return this._tokens;
    const saved = await readStoreJson<OAuthTokens>(this.storeDir, "tokens.json");
    if (saved) this._tokens = saved;
    return saved;
  }

  /** Store new tokens after a successful authorization or refresh. */
  async saveTokens(tokens: OAuthTokens): Promise<void> {
    this._tokens = tokens;
    this._reauthLogged = false; // reset re-auth flag on successful token save
    await writeStoreJson(this.storeDir, "tokens.json", tokens);
  }

  /**
   * Redirect the user to the authorization URL.
   * For CLI, we log the URL and store it for the user to open in a browser.
   */
  async redirectToAuthorization(authorizationUrl: URL): Promise<void> {
    this._pendingAuthUrl = authorizationUrl;
    console.log(
      `[mcp-client] 🔐 OAuth authorization required for '${this.serverUrl.origin}'`
    );
    console.log(
      `[mcp-client] Open this URL in your browser to authorize:\n` +
      `  ${authorizationUrl.href}\n` +
      `After authorizing, you will be redirected to ${this.redirectUrl}?code=...`
    );
    console.log(
      `[mcp-client] To complete authorization, call mcp_finish_auth with the \"code\" parameter from the redirect URL.`
    );
  }

  /** Store the PKCE code verifier before redirecting. */
  async saveCodeVerifier(codeVerifier: string): Promise<void> {
    this._codeVerifier = codeVerifier;
    await writeStoreJson(this.storeDir, "code-verifier.json", { codeVerifier });
  }

  /** Load the PKCE code verifier for the current session. */
  async codeVerifier(): Promise<string> {
    if (this._codeVerifier) return this._codeVerifier;
    const saved = await readStoreJson<{ codeVerifier: string }>(
      this.storeDir,
      "code-verifier.json"
    );
    if (saved?.codeVerifier) {
      this._codeVerifier = saved.codeVerifier;
      return saved.codeVerifier;
    }
    throw new Error(
      `[mcp-client] No PKCE code verifier found for '${this.serverUrl.origin}'. Re-authorization required.`
    );
  }

  /**
   * Invalidate credentials on server-issued token expiry (invalid_grant).
   * Clears tokens, client info, and code verifier so the next connection
   * attempt starts fresh with discovery + re-authorization.
   */
  async invalidateCredentials(scope: "all" | "client" | "tokens" | "verifier" | "discovery"): Promise<void> {
    if (scope === "tokens" || scope === "all") {
      this._tokens = undefined;
      await deleteStoreFile(this.storeDir, "tokens.json");
    }
    if (scope === "client" || scope === "all") {
      this._clientInfo = undefined;
      await deleteStoreFile(this.storeDir, "client-info.json");
    }
    if (scope === "verifier" || scope === "all") {
      this._codeVerifier = undefined;
      await deleteStoreFile(this.storeDir, "code-verifier.json");
    }
    if (scope === "discovery" || scope === "all") {
      this._discoveryState = undefined;
      await deleteStoreFile(this.storeDir, "discovery-state.json");
    }

    if (!this._reauthLogged) {
      this._reauthLogged = true;
      console.log(
        `[mcp-client] 🔐 Token expired for '${this.serverUrl.origin}' — re-authorization required.`
      );
      if (this._pendingAuthUrl) {
        console.log(
          `[mcp-client] Open the authorization URL in your browser:\n` +
          `  ${this._pendingAuthUrl.href}`
        );
      }
    }
  }

  // ── Discovery persistence ───────────────────────────────────────────

  async saveDiscoveryState(state: OAuthDiscoveryState): Promise<void> {
    this._discoveryState = state;
    await writeStoreJson(this.storeDir, "discovery-state.json", state);
  }

  async discoveryState(): Promise<OAuthDiscoveryState | undefined> {
    if (this._discoveryState) return this._discoveryState;
    const saved = await readStoreJson<OAuthDiscoveryState>(
      this.storeDir,
      "discovery-state.json"
    );
    if (saved) this._discoveryState = saved;
    return saved;
  }

  // ── Helpers for finishAuth ──────────────────────────────────────────

  /** The pending authorization URL, if any. */
  get pendingAuthUrl(): URL | undefined {
    return this._pendingAuthUrl;
  }

  /** Clear pending auth state (after successful finishAuth). */
  clearPendingAuth(): void {
    this._pendingAuthUrl = undefined;
  }

  /** The server URL (for transport lookup). */
  get serverOrigin(): string {
    return this.serverUrl.origin;
  }
}

// ── Lifecycle constants (#199) ─────────────────────────────────────

/** Default idle-stop threshold for lazy servers (30 min). */
export const DEFAULT_IDLE_TIMEOUT_MS = 30 * 60 * 1000;
/** How often the idle sweep checks for lazy servers past their idle timeout. */
export const IDLE_SWEEP_INTERVAL_MS = 60 * 1000;

// ── Eager-connect retry (#802) ─────────────────────────────────────
//
// A remote server is cold on its first request after idle: measured against
// the hosted Tortoise MCP, the first request after ~45s idle took 15.55s
// (right at the 15s budget) and after ~100s idle it stalled 35.4s then
// returned a zero-byte 503, while warm latency was 0.30s. The cold path thus
// straddles the default budget BY DESIGN, so a single timeout is not evidence
// the server is down — it is evidence the server was woken.
//
// Fix: retry a failed eager connect once. This rescues a cold start that only
// slightly overshoots the budget — the 15.55s datum: attempt 1 wakes the
// server and attempt 2 (after a short pause) lands on the warm path. A 30s+
// cold start (the 35.4s datum) still needs a raised `timeoutMs` — attempt 2
// begins ≈15.3–18.3s after attempt 1 and gives up at ≈30–33s, before a 35.4s
// answer arrives. The retry is deliberately bounded to one attempt so total
// startup can never exceed 2× the per-server `timeoutMs` (15s default → ≤30s
// worst case, before transport teardown) — startup must not hang. Operators
// raising `timeoutMs` raise BOTH attempt budgets; it remains the cold-start
// budget knob.

/** Max attempts per eager server connect (1 initial + 1 retry). */
export const EAGER_CONNECT_MAX_ATTEMPTS = 2;
/** Pause before the eager retry — the first attempt already woke the server. */
export const EAGER_CONNECT_RETRY_DELAY_MS = 250;

/**
 * #802: deterministic errors — retrying cannot change the outcome, so skip the
 * retry and fail immediately (no pointless startup delay). Covers missing
 * transport config and auth outcomes (a retry would re-emit the OAuth URL with
 * a fresh PKCE verifier).
 */
export function isRetryableEagerConnectError(err: unknown): boolean {
  const msg = err instanceof Error ? err.message : String(err);
  // Missing transport config — deterministic.
  if (/has neither 'command' nor 'url'/.test(msg)) return false;
  // Auth outcomes (401/403, OAuth-required) are deterministic too, and a retry
  // rebuilds the OAuth provider with a FRESH PKCE verifier: it emits the
  // browser auth URL a second time and overwrites the stored verifier, while
  // the user is most likely acting on the first URL. Do not retry auth.
  if (err instanceof UnauthorizedError) return false;
  if (/\b(401|403)\b/.test(msg) || /unauthorized/i.test(msg)) return false;
  return true;
}

/**
 * #802: connect one eager server, retrying a transient failure once.
 *
 * Exported (named) so the retry policy is testable without a live server.
 * `connect` is injected so callers can wrap `connectServer`. Throws the last
 * error after the attempt budget is spent.
 */
export async function connectEagerWithRetry(
  name: string,
  connect: () => Promise<void>,
  opts: { maxAttempts?: number; retryDelayMs?: number } = {}
): Promise<{ attempts: number }> {
  const requestedAttempts = opts.maxAttempts ?? EAGER_CONNECT_MAX_ATTEMPTS;
  // Guard against a caller passing 0/negative/NaN — an empty loop would throw
  // an undefined `lastErr` and surface as "...: undefined" in the log.
  const maxAttempts =
    Number.isFinite(requestedAttempts) && requestedAttempts >= 1
      ? Math.floor(requestedAttempts)
      : 1;
  const retryDelayMs = opts.retryDelayMs ?? EAGER_CONNECT_RETRY_DELAY_MS;
  let lastErr: unknown;

  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      await connect();
      return { attempts: attempt };
    } catch (err) {
      lastErr = err;
      if (attempt >= maxAttempts || !isRetryableEagerConnectError(err)) break;
      const msg = err instanceof Error ? err.message : String(err);
      console.log(
        `[mcp-client] Eager connect to '${name}' failed (attempt ${attempt}/${maxAttempts}): ${msg} — retrying in ${retryDelayMs}ms`
      );
      if (retryDelayMs > 0) {
        await new Promise<void>((resolve) => setTimeout(resolve, retryDelayMs));
      }
    }
  }

  throw lastErr;
}

// ── Types ──────────────────────────────────────────────────────────

interface McpServerConfig {
  // Stdio transport
  command?: string;
  args?: string[];
  env?: Record<string, string>;
  cwd?: string;
  // URL transport (SSE/streamable HTTP)
  url?: string;
  headers?: Record<string, string>;
  // Connection timeout override (ms). Defaults to 15000 if unset.
  timeoutMs?: number;
  // ── Lifecycle tiering (#199) ────────────────────────────────────
  // lazy: true → NOT connected at startup; load on demand via mcp_load.
  lazy?: boolean;
  // Idle-stop threshold for lazy servers (ms). Defaults to DEFAULT_IDLE_TIMEOUT_MS.
  idleTimeoutMs?: number;
  // Catalog metadata (surfaced via mcp_catalog; no connect needed).
  purpose?: string;
  whenToLoad?: string;
  cost?: string;
  // ── OAuth (#595) ────────────────────────────────────────────────
  // Enable OAuth 2.1 authorization-code PKCE flow for remote HTTP MCP servers.
  // `oauth: true` = auto-discovery with DCR; `oauth: { clientId: "..." }` uses a
  // pre-configured public client. Requires `url` to be set. Tokens are stored in
  // ~/.pi/mcp-tokens/<origin>/ and NEVER written to .mcp.json or env.
  oauth?: import("./index.js").OAuthConfig;
}

interface McpJson {
  mcpServers: Record<string, McpServerConfig>;
}

// ── JSON Schema → TypeBox converter ────────────────────────────────

function jsonSchemaToTypeBox(schema: any): TSchema {
  if (!schema || typeof schema !== "object") return Type.String();

  const { type, properties, required, items, description } = schema;

  if (type === "string") {
    const opts: any = {};
    if (description) opts.description = description;
    return Type.String(opts);
  }

  if (type === "number" || type === "integer") {
    const opts: any = {};
    if (description) opts.description = description;
    return Type.Number(opts);
  }

  if (type === "boolean") {
    const opts: any = {};
    if (description) opts.description = description;
    return Type.Boolean(opts);
  }

  if (type === "object" && properties) {
    const shape: Record<string, TSchema> = {};
    const requiredSet = new Set(required ?? []);
    for (const [key, propSchema] of Object.entries(properties)) {
      const converted = jsonSchemaToTypeBox(propSchema);
      shape[key] = requiredSet.has(key) ? converted : Type.Optional(converted);
    }
    const opts: any = {};
    if (description) opts.description = description;
    return Type.Object(shape, opts);
  }

  if (type === "array" && items) {
    return Type.Array(jsonSchemaToTypeBox(items));
  }

  return Type.String();
}

// ── MCP Server Manager ──────────────────────────────────────────────

interface McpConnection {
  client: Client;
  serverName: string;
  lazy: boolean;
  idleTimeoutMs: number;
  lastUsed: number;
  /** OAuth provider, if the server uses OAuth (#595). */
  oauthProvider?: McpOAuthClientProvider;
}

// ── MCP Server Manager ──────────────────────────────────────────────

/**
 * Expand ${VAR} and ${VAR:-default} patterns in env-dependent values.
 *
 * Plain ${VAR} → process.env[VAR] (empty string when unset).
 * ${VAR:-default} → process.env[VAR] when set+non-empty, else `default`;
 * the default is expanded recursively, so nested expressions like
 * ${TORTOISE_HOME:-${HOME}/Documents/GitHub/tortoise} work.
 *
 * #104: the `:-` form was previously unsupported — a literal
 * "TORTOISE_HOME:-/home/user/tortoise" was looked up as one key and
 * resolved to "" whenever TORTOISE_HOME was unset, silently breaking the
 * base config's tortoise cwd/PYTHONPATH. Regex replacement cannot parse
 * nested braces, so a small scanner tracks ${ ... } depth explicitly.
 */
/**
 * Env for a stdio MCP server: the parent env (servers need API keys etc.)
 * plus expanded config.env — MINUS the task-heartbeat nonce (#176). MCP
 * servers inherit the child's fd 2 (MCP SDK stdio default stderr:"inherit");
 * with the nonce they could forge valid [task-heartbeat] markers on the very
 * pipe the parent parses. Without it, forged markers are rejected by the
 * parent's expectedNonce check. Exported for unit tests.
 */
export function buildMcpServerEnv(config: { env?: Record<string, string> }): Record<string, string | undefined> {
  const env: Record<string, string | undefined> = { ...process.env, ...(config.env ? expandEnvVars(config.env) : {}) };
  delete env.TASK_HEARTBEAT_NONCE;
  return env;
}

export function expandEnvVars(obj: Record<string, string>): Record<string, string> {
  const result: Record<string, string> = {};
  for (const [key, value] of Object.entries(obj)) {
    result[key] = expandExpr(value);
  }
  return result;
}

/** Expand ${...} (optionally with a nested default) in one string. */
function expandExpr(str: string): string {
  let out = "";
  let i = 0;
  while (i < str.length) {
    const start = str.indexOf("${", i);
    if (start === -1) {
      out += str.slice(i);
      break;
    }
    out += str.slice(i, start);

    // Find the matching close brace, respecting nested ${ ... } pairs.
    let depth = 1;
    let j = start + 2;
    while (j < str.length && depth > 0) {
      if (str.startsWith("${", j)) {
        depth++;
        j += 2;
      } else if (str[j] === "}") {
        depth--;
        j++;
      } else {
        j++;
      }
    }
    if (depth > 0) {
      // Unterminated — emit the remainder verbatim.
      out += str.slice(start);
      break;
    }

    const expr = str.slice(start + 2, j - 1);
    const [name, ...rest] = expr.split(":-");
    const direct = process.env[name.trim()];
    if (direct !== undefined && direct !== "") {
      out += direct;
    } else {
      const def = rest.join(":-");
      out += def ? expandExpr(def) : "";
    }
    i = j;
  }
  return out;
}

/**
 * Merge the hub's BASE layer with a repo's DELTA — **per server, then PER FIELD**: the repo wins
 * every field it sets and inherits every field it omits.
 *
 * ⛔ A NAME-LEVEL REPLACEMENT WAS THE FIRST BUG (#3614 review). Spreading at the server-name level
 * made an override entry a whole-entry REPLACEMENT, so `{"tortoise": {"timeoutMs": 40000}}` — the
 * recovery hint this file prints — produced an entry with no `command` and no `url` and made the
 * server permanently unspawnable, and `{"tortoise": {"url": …}}` dropped `lazy: true`, making a
 * hosted server EAGER at every session start on memory-constrained cells.
 *
 * ⛔ BUT A NAIVE PER-FIELD SPREAD IS WORSE, IN TWO WAYS THIS FUNCTION NOW GUARDS AGAINST.
 *
 * 1. **NO SECRET IS INHERITED INTO A DIFFERENT DESTINATION.** `.mcp.json` is a TRACKED file,
 *    modifiable by any PR and present in any cloned repo. Inheriting `headers` into a repo entry that
 *    changes `url` handed the base's bearer token to whatever that file named (measured: a repo entry
 *    `{"url": "http://127.0.0.1:PORT/collect"}` received `Authorization: Bearer <the real key>`);
 *    inheriting `env` into an entry that changed `command` did the same for a spawned child. So base
 *    `headers`/`oauth` are inherited ONLY when the destination is unchanged (compared NORMALISED, so
 *    a restated URL is still the same destination), and base `env` ONLY when the same thing is
 *    LAUNCHED (`command` + `args` + `cwd` — `args` decides what runs, so comparing `command` alone
 *    left `npx -y @evil/mcp` able to inherit the key of `npx -y @good/mcp`).
 *
 *    ⛔ THIS IS NOT A SECURITY BOUNDARY, AND MUST NOT BE DESCRIBED AS ONE. It prevents ACCIDENTAL
 *    inheritance only. A repo-authored entry can still write `"Authorization": "Bearer
 *    ${TORTOISE_MCP_API_KEY}"` itself and `expandEnvVars` will resolve it from the environment
 *    (measured: the repo-chosen destination received the real key), and every stdio child already
 *    inherits the parent's whole `process.env` via `buildMcpServerEnv` regardless of this function.
 *    A repo's `.mcp.json` is therefore TRUSTED INPUT — the real boundary is a project-trust gate on
 *    reading it, which pi has (`docs/mcp.md`: "Project configuration is read only after project trust
 *    is granted") and this extension does not. Filed as #3634; do not mistake these guards for it.
 *
 * 2. **TRANSPORT IS ATOMIC.** `connectServer` tests `url` BEFORE `command`, so a merged entry
 *    carrying both silently ignores the repo's `command` (measured: a repo switching the base's
 *    hosted server to its own stdio daemon kept talking to the base URL, with no warning). Base
 *    fields of the OTHER transport are therefore dropped when the repo declares one. An entry declaring
 *    BOTH transports is ambiguous: as a delta over a base entry it is ignored and the base entry is kept
 *    (a repo cannot remove a base server either), and as a repo-only entry it is kept and warns — it
 *    runs over `url`, which is what `connectServer` does with it, so refusing it would zero a config
 *    that works. `type` is NEVER a reason to drop or ignore anything; see `RECOGNISED_TYPES`.
 *
 * ⛔ OVERRIDES: pi's replace-on-transport rule for a project entry — `docs/mcp.md` says "A project
 * entry replaces a user-level entry with the same name", and its "keeps the rest, including env,
 * headers, and auth" carve-out is scoped to entries that define NO `command`/`url`/`type` — a fleet
 * base layer is machine-local and never ships, and repos legitimately delta one field of it, so the
 * merge is per field with the two guards above instead of a wholesale replacement. Because that is a
 * deliberate departure from the platform default, it is stated here rather than presented as
 * convergence; a reader holding `docs/mcp.md` must not "correct" this back without reading why.
 *
 * Pure and exported so the ordering and the guards are pinned by tests rather than by reading a spread.
 */

/** Fields that only mean anything for an HTTP transport (dropped when a repo declares stdio). */
const HTTP_TRANSPORT_FIELDS = ["url", "headers", "oauth"] as const;
/** Of those, the ones that carry a SECRET, so may not follow a repo to a different destination. */
const HTTP_CREDENTIAL_FIELDS = ["headers", "oauth"] as const;
/** Fields that only mean anything for a stdio transport (dropped when a repo declares HTTP). */
const STDIO_TRANSPORT_FIELDS = ["command", "args", "env", "cwd"] as const;
/** Of those, the one that carries secrets declared for a spawned process. */
const STDIO_CREDENTIAL_FIELDS = ["env"] as const;

/**
 * A server name pi accepts: letters, digits, `_` and `-` (`docs/mcp.md`).
 *
 * ⛔ PLUS an explicit rejection of the PROTOTYPE-SHAPED names, which the charset admits. What this buys
 * is HYGIENE, not pollution safety: the pollution defence is the null-prototype merge map plus
 * `Object.hasOwn`, and `connectConfig` also stores a null-prototype sanitised map. That map makes
 * `__proto__` an ORDINARY OWN KEY instead of a prototype setter — so a prototype-shaped name that
 * reaches `connectConfig` is STORED AND RESOLVED, not filtered: `connectConfig` checks that an entry is
 * an object and never checks its name (`loadServer("__proto__")` resolves and spawns it — measured).
 * This set and the merge's `isValidServerName` call are therefore the ONLY name locks; do not delete
 * them believing `connectConfig` already refuses those names, because it does not. pi's own
 * name rule (`docs/mcp.md`) is only the charset, which ADMITS all three — on the null-prototype map they
 * would be accepted as ordinary servers — so refusing them is THIS client's hygiene rule, stricter than
 * pi by choice, not a platform requirement. Do not read it as the thing that prevents pollution.
 */
const PROTOTYPE_SHAPED_NAMES = new Set(["__proto__", "constructor", "prototype"]);

function isValidServerName(name: string): boolean {
  return /^[A-Za-z0-9_-]+$/.test(name) && !PROTOTYPE_SHAPED_NAMES.has(name);
}

/**
 * ⛔ `type` IS NEVER DISQUALIFYING IN THIS CLIENT — a RECORDED DECISION, not an oversight.
 * `McpServerConfig` has no `type` field and `connectServer` selects the transport from `url`/`command`
 * alone, so `type` is inert here. Two sibling files rule on it explicitly:
 * `pi-bootstrap/lib/merge-mcp.py` ("On a url the operator chose, a non-http `type` is their business
 * and is preserved with the entry (the client never reads `type`)"; a self-hosted `type: "sse"`
 * "WORKS — replacing it would destroy the operator's config") and `pi-bootstrap/cell-install.sh`
 * ("refusing `sse` here would refuse a config that WORKS"). Rejecting an entry for its `type` would
 * therefore reverse that ruling AND zero a self-hosted config the installer certifies — so an
 * unrecognised `type` only earns a warning, never a drop.
 */
const RECOGNISED_TYPES = new Set(["stdio", "http", "streamable-http"]);

/**
 * `is`/`are` for a list of field names: agreement follows the NOUN, not the count. `headers` is one
 * field but a plural noun, so keying on `dropped.length` produced "the base's headers is NOT
 * inherited" — machine-sounding text in the one diagnostic an operator reads to understand why auth
 * vanished (a bare 401 with no other signal).
 */
function fieldVerb(fields: readonly string[]): "is" | "are" {
  return fields.length > 1 || fields[0] === "headers" ? "are" : "is";
}

function isServerEntry(value: unknown): value is McpServerConfig {
  return !!value && typeof value === "object" && !Array.isArray(value);
}

/** Is `field` PRESENT on this entry (regardless of type — a wrong type is still a declared field)? */
function hasField(entry: McpServerConfig, field: string): boolean {
  return (entry as Record<string, unknown>)[field] !== undefined;
}

/**
 * Does this entry DECLARE `field` as a transport? PRESENCE is not enough for the transport tests: an
 * empty string cannot select a transport (`connectServer` dispatches on `if (config.url)` — TRUTHINESS),
 * so counting it as declared made a repo entry look ambiguous when it really runs over its `command`,
 * and made a genuine transport switch look like an ambiguous delta and get discarded. The CREDENTIAL
 * guards still key on `hasField` deliberately: `{"url": ["https://attacker/…"]}` is a typo that must
 * count as a CHANGED destination, not as "no transport declared".
 */
function declaresTransport(entry: McpServerConfig, field: "url" | "command"): boolean {
  const value = (entry as Record<string, unknown>)[field];
  return typeof value === "string" && value !== "";
}

/**
 * `type` is OPTIONAL and is an AGREEMENT constraint, not a transport selector: `command` selects stdio
 * and `url` selects streamable HTTP, and `type` — when present — must agree (`docs/mcp.md`).
 * `connectServer` dispatches on `url`/`command` and never reads `type`, so an incoherent entry would
 * silently run over the OTHER transport from the one the operator wrote (measured:
 * `{"type":"http","command":…}` ran over stdio).
 *
 * Evaluated on the EFFECTIVE entry, not the delta: a `{"type":"http"}`-only override is otherwise
 * applied to a stdio base and produces exactly the incoherent entry this rejects.
 */
function typeDisagrees(entry: McpServerConfig): boolean {
  const type = (entry as Record<string, unknown>).type;
  // An unrecognised or non-string `type` cannot disagree with anything this client acts on.
  if (typeof type !== "string" || !RECOGNISED_TYPES.has(type)) return false;
  const declaresStdio = hasField(entry, "command");
  const declaresHttp = hasField(entry, "url");
  if (!declaresStdio && !declaresHttp) return false;
  if (type === "stdio") return declaresHttp && !declaresStdio;
  return declaresStdio && !declaresHttp;
}

/**
 * Are two destinations the same server? Compared NORMALISED via `new URL().href`, so host case,
 * default port and surrounding whitespace are ignored — a repo restating the same endpoint must not
 * lose its credentials with no diagnostic. A TRAILING SLASH still distinguishes two destinations
 * (`/mcp` and `/mcp/` are routed separately by many servers), and that direction is fail-closed.
 *
 * A non-string on either side (a config typo such as `"url": ["…"]`) is NOT the same destination:
 * `connectServer` would stringify it into a real request, so the safe answer is "different".
 */
function sameDestination(a: unknown, b: unknown): boolean {
  if (typeof a !== "string" || typeof b !== "string") return false;
  const normalise = (value: string): string => {
    try {
      return new URL(value).href;
    } catch {
      return value;
    }
  };
  return normalise(a) === normalise(b);
}

/**
 * Is this the same LAUNCH? What a stdio child runs is the `(command, args, cwd)` triple, not the
 * command alone: `npx -y @good/mcp` and `npx -y @evil/mcp` share a command and run different code,
 * so comparing only `command` left the base's `env` reachable by rewriting `args` (measured).
 *
 * `args` absent and `args: []` spawn IDENTICALLY (`connectServer` does `config.args ?? []`), so they
 * must compare equal or a no-op restatement would drop the credentials.
 */
function sameLaunch(a: McpServerConfig, b: McpServerConfig): boolean {
  if (a.command !== b.command) return false;
  if ((a.cwd ?? "") !== (b.cwd ?? "")) return false;
  return JSON.stringify(a.args ?? []) === JSON.stringify(b.args ?? []);
}

export function mergeMcpLayers(
  base: McpJson | null,
  repo: McpJson | null,
): Record<string, McpServerConfig> {
  // ⛔ NULL-PROTOTYPE MAP. `merged[name] = …` on a plain object sends a `__proto__` key to the
  // prototype SETTER instead of adding a server: verified, the merged map's prototype became the repo's
  // entry object, and `loadServer` (which resolves `mcpServers[name]`) could reach a server that
  // `catalog()` — which enumerates `Object.entries` — never lists. THIS null prototype (plus the
  // `Object.hasOwn` reads below) is the actual defence; `isValidServerName` rejecting prototype-shaped
  // names is the second lock, and `isValidServerName` here is the belt for a raw-JSON caller.
  const merged: Record<string, McpServerConfig> = Object.create(null);
  const baseServers = (base?.mcpServers ?? {}) as Record<string, unknown>;
  const repoServers = (repo?.mcpServers ?? {}) as Record<string, unknown>;

  for (const [name, entry] of Object.entries(baseServers)) {
    // A non-object entry is not a server, and it must not reach classifyServers, which reads
    // `cfg.lazy` and would throw out of the extension factory — killing the whole session with no
    // file or entry named (`{"mcpServers": {"tortoise": null}}` did exactly that). `asMcpJson`
    // already reports these; this is the belt for a caller that hands the merge raw JSON.
    if (!isServerEntry(entry) || !isValidServerName(name)) continue;
    merged[name] = { ...entry };
  }

  for (const [name, entry] of Object.entries(repoServers)) {
    if (!isServerEntry(entry) || !isValidServerName(name)) continue;
    // `Object.hasOwn`, never a truthiness read. `merged` is null-prototype HERE (below), so this is not
    // load-bearing today — the name lock above already refuses `constructor`/`__proto__`/`prototype`. It
    // is the belt for the day this map is built as a plain object: then `merged["constructor"]` would
    // answer a FUNCTION and a repo-only server with that name would silently take the DELTA path.
    const inherited = Object.hasOwn(merged, name) ? merged[name] : undefined;
    if (!inherited) {
      // No base entry to defend, so the ruling is the same as for the BASE layer: a repo-only entry
      // declaring both transports WORKS over `url` (`connectServer` tests it first) and `origin/main`
      // refused nothing — dropping it would zero a working server. Warn and keep.
      if (declaresTransport(entry, "url") && declaresTransport(entry, "command")) {
        console.log(
          `[mcp-client] WARN: repo entry "${name}" declares BOTH "url" and "command" — ambiguous; it is ` +
            `KEPT and will run over "url" (the order this client dispatches in). Declare ONE transport.`
        );
      }
      if (typeDisagrees(entry)) {
        // WARN, never drop: `type` is inert in this client (see RECOGNISED_TYPES), so refusing the entry
        // would destroy a config that works — the ruling `merge-mcp.py`/`cell-install.sh` already made.
        console.log(
          `[mcp-client] note: repo entry "${name}" declares a "type" that disagrees with its transport — ` +
            `this client selects the transport from url/command, so the entry is kept as written.`
        );
      }
      merged[name] = { ...entry };
      continue;
    }

    const repoDeclaresHttp = declaresTransport(entry, "url");
    const repoDeclaresStdio = declaresTransport(entry, "command");
    if (repoDeclaresHttp && repoDeclaresStdio) {
      // Two transports in one entry is ambiguous, not a delta. Guessing would silently pick `url`
      // (connectServer tests it first) and ignore the command the operator actually wrote.
      console.log(
        `[mcp-client] WARN: repo entry "${name}" declares BOTH "url" and "command" — the entry is ` +
          `ambiguous, so it is IGNORED and the base's entry is kept. Declare ONE transport.`
      );
      continue;
    }
    const carry = { ...inherited } as Record<string, unknown>;
    // The base's `type` describes the base's transport, so it must not outlive a SWITCH: keeping it
    // beside the new transport produced `{type:"http", command:…}` — a stale label contradicting the
    // entry it now describes. A SAME-transport delta KEEPS it, because there it still describes the
    // entry: the contract is that the repo wins every field it SETS and inherits every field it OMITS
    // (`SETUP-NEW-MACHINE.md`), and an identical `url` restatement silently lost the operator's own
    // label. Compared by transport CLASS (url first, the order `connectServer` dispatches in), not by
    // "did the repo declare something".
    {
      const baseTransport = declaresTransport(inherited, "url")
        ? "http"
        : declaresTransport(inherited, "command")
          ? "stdio"
          : "none";
      const effectiveTransport = repoDeclaresHttp ? "http" : repoDeclaresStdio ? "stdio" : baseTransport;
      if (baseTransport !== effectiveTransport) delete carry.type;
    }
    if (repoDeclaresHttp) {
      for (const field of STDIO_TRANSPORT_FIELDS) delete carry[field];
    } else if (repoDeclaresStdio) {
      for (const field of HTTP_TRANSPORT_FIELDS) delete carry[field];
    }

    // ⛔ THE GUARD IS EVALUATED ON THE **EFFECTIVE** ENTRY, not on what the repo happened to restate.
    // Two reasons, both measured:
    //   * `{"args": ["-y", "@evil/mcp"]}` changes what launches while `command` stays the base's, so a
    //     guard keyed on "did the repo set command/url?" let the base's API key reach the repo's package.
    //   * `{"type": "http"}` on a stdio base produces an incoherent entry, so the `type` check must run
    //     after projection too.
    // Presence — not a string check — is the trigger: `{"url": ["https://attacker/…"]}` is a config
    // typo that `connectServer` STRINGIFIES into a real request, so it must be treated as a changed
    // destination, not as "no transport declared". (The layer read rejects such an entry anyway; this
    // is the belt for a caller that hands the merge raw JSON.)
    const projected = { ...carry, ...entry } as unknown as McpServerConfig;
    if (typeDisagrees(projected) && hasField(entry, "type")) {
      // Only a warning, for the reason recorded on RECOGNISED_TYPES: `type` is inert here, so dropping
      // or ignoring the delta would destroy a working config over a field this client never reads.
      // Attributed to the repo entry ONLY when the repo is the one that wrote a `type`: the projection
      // can be incoherent because the BASE's label was, and `asMcpJson` has already reported that —
      // blaming the repo sent the operator to edit a file that does not contain the field.
      console.log(
        `[mcp-client] note: repo entry "${name}" declares a "type" that disagrees with its transport — ` +
          `this client selects the transport from url/command, so the entry is kept as written.`
      );
    }
    // TWO INDEPENDENT GUARDS, not `if/else if`. They defend different things — what LAUNCHES and what
    // an endpoint RECEIVES — and a projected entry can change both at once (`{url: …, args: […]}`, or a
    // base entry that declares both transports). Selecting one guard by presence let a repo suppress the
    // HTTP credential guard with a field the client never dispatches on (`{url: "https://attacker/mcp",
    // command: ""}`): the base's `Authorization` followed the repo to a NEW endpoint with nothing logged.
    if (hasField(projected, "command")) {
      if (!sameLaunch(inherited, projected)) {
        const dropped = STDIO_CREDENTIAL_FIELDS.filter(field => carry[field] !== undefined);
        for (const field of dropped) delete carry[field];
        if (dropped.length > 0) {
          console.log(
            `[mcp-client] note: repo entry "${name}" changes what it LAUNCHES (command/args/cwd), so ` +
              `the base's ${dropped.join("/")} ${fieldVerb(dropped)} NOT inherited.`
          );
        }
      }
    }
    if (hasField(projected, "url") && !sameDestination(inherited.url, projected.url)) {
      const dropped = HTTP_CREDENTIAL_FIELDS.filter(field => carry[field] !== undefined);
      for (const field of dropped) delete carry[field];
      if (dropped.length > 0) {
        console.log(
          `[mcp-client] note: repo entry "${name}" changes the destination, so the base's ` +
            `${dropped.join("/")} ${fieldVerb(dropped)} NOT inherited — ` +
            `the base's credentials belong to the base's own endpoint.`
        );
      }
    }

    merged[name] = { ...carry, ...entry };
  }
  return merged;
}

/**
 * A parsed `.mcp.json` must be a JSON OBJECT carrying an `mcpServers` object.
 *
 * `JSON.parse` admits `null`, arrays and scalars, and every one of those used to pass through as a
 * "readable" layer that then contributed zero servers with NO message — so `"null"` in a repo file
 * silently produced the base's config instead (measured, #3614 review). A layer that is not a config
 * is not a silent zero; it is a stated failure.
 *
 * Entries inside `mcpServers` are validated too, and a non-object entry is DROPPED with a warning
 * rather than passed on: `{"mcpServers": {"tortoise": null}}` used to survive this validator and
 * then throw `TypeError: Cannot read properties of null (reading 'lazy')` out of the extension
 * factory, which ends the session with no file, entry or cause named.
 *
 * Non-`mcpServers` top-level keys are preserved — the caller spreads them as the layer's own config.
 * A layer that OMITS `mcpServers` therefore still contributes its keys (it simply declares no
 * servers); only a layer whose `mcpServers` is PRESENT but not an object is refused.
 */
function asMcpJson(value: unknown, label: string): McpJson | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const rawServers = (value as { mcpServers?: unknown }).mcpServers;
  if (rawServers === undefined) {
    // No `mcpServers` is not a BROKEN layer — it is a layer with no servers. Rejecting it dropped the
    // whole file, so its top-level keys vanished and the log called a valid config unusable.
    return { ...(value as Record<string, unknown>), mcpServers: {} } as McpJson;
  }
  if (!rawServers || typeof rawServers !== "object" || Array.isArray(rawServers)) return null;

  const servers: Record<string, McpServerConfig> = Object.create(null);
  for (const [name, entry] of Object.entries(rawServers as Record<string, unknown>)) {
    const suffix = label.startsWith("base")
      ? // A base entry is the machine's own config: the "removal" sentence below is about a REPO layer
        // and would be nonsense here, in the one message a user reads while debugging.
        `Fix that entry in the base config; it is skipped, and its servers are unavailable.`
      : `A server cannot be REMOVED from a repo layer; see #3612 for the disabled-tombstone proposal.`;

    if (!isValidServerName(name)) {
      // pi restricts server names to `[A-Za-z0-9_-]` (`docs/mcp.md`), and the prototype-shaped names
      // are rejected on top of that. Rejection here is the SECOND lock; the null-prototype merge map
      // plus `Object.hasOwn` is what actually prevents pollution.
      console.log(
        `[mcp-client] WARN: ${label} entry name "${name}" is not a valid server name ` +
          `(letters, digits, "_" and "-" only, and not a prototype-shaped name) — dropped.`
      );
      continue;
    }
    if (!entry || typeof entry !== "object" || Array.isArray(entry)) {
      // `null` is the tempting way to say "not here" — and there is no tombstone in this schema
      // (#3612), so say why the entry was dropped instead of crashing the session.
      console.log(`[mcp-client] WARN: ${label} entry "${name}" is not an object — dropped. ` + suffix);
      continue;
    }
    // A transport that is not a string is a config TYPO, and a dangerous one: `connectServer` reads
    // `if (config.url)` and would STRINGIFY an array into a real request — so a non-string is refused
    // WITH its entry, because a stringified destination is exactly what must never reach the client.
    //
    // An EMPTY STRING is a typo of the other kind and needs the opposite treatment: that `if`
    // dispatches on TRUTHINESS, so `url: ""` does not select HTTP — the entry simply runs over its
    // `command` (`{url:"", command:…}` connects over stdio, measured). Dropping the whole ENTRY would
    // therefore zero a config that works, which is the failure this file rules against everywhere. So
    // the empty FIELD is removed and the entry kept: the projected entry then matches what the client
    // would have done anyway, and the both-transports warning ("it will run over url") stops being a
    // lie. Only an entry left with NO transport at all — which has nothing to run — is dropped.
    const typed = entry as Record<string, unknown>;
    // What `connectServer` does with the field decides what is safe here — it dispatches on
    // `if (config.url)`, TRUTHINESS:
    //   * a TRUTHY non-string (`["https://attacker/…"]`, `{}`) is STRINGIFIED into a real request, so
    //     it is refused WITH its entry — a stringified destination must never reach the client;
    //   * a FALSY value (`""`, `null`, `false`, `0`) is simply NOT SELECTED: dispatch falls through to
    //     the other transport, so the entry may still work and refusing it would zero a working config
    //     (this file's recurring failure). The FIELD is removed and the entry kept.
    const badTransport = (["url", "command"] as const).find(
      field =>
        typed[field] !== undefined && typeof typed[field] !== "string" && !!typed[field]
    );
    if (badTransport) {
      console.log(
        `[mcp-client] WARN: ${label} entry "${name}" has a non-string "${badTransport}" — dropped ` +
          `(a truthy non-string is stringified into a real request, so it must not reach the client). ` +
          suffix
      );
      continue;
    }
    const deadTransports = (["url", "command"] as const).filter(
      field => typed[field] !== undefined && !typed[field]
    );
    if (deadTransports.length > 0) {
      for (const field of deadTransports) {
        console.log(
          `[mcp-client] WARN: ${label} entry "${name}" has an empty "${field}" — that field is removed. ` +
            `A falsy value cannot select a transport (the client dispatches on whether the field is ` +
            `set to a value), so it is ignored rather than treated as a declared transport.`
        );
        delete typed[field];
      }
      if (typed.url === undefined && typed.command === undefined) {
        console.log(
          `[mcp-client] WARN: ${label} entry "${name}" declares no usable transport — dropped. ` + suffix
        );
        continue;
      }
    }
    // An unrecognised `type` is NOT an error here (see RECOGNISED_TYPES) — but it is worth saying out
    // loud, because the operator wrote it expecting an effect this client will not give it.
    if (typed.type !== undefined && !(typeof typed.type === "string" && RECOGNISED_TYPES.has(typed.type))) {
      console.log(
        `[mcp-client] note: ${label} entry "${name}" has "type": ${JSON.stringify(typed.type)} — this ` +
          `client selects the transport from url/command and never reads type, so the entry is KEPT as written.`
      );
    }
    // A RECOGNISED `type` that CONTRADICTS the entry's own transport is inert to this client but means
    // the operator expected an effect it will not get (`{"type":"http",command:…}` runs over stdio —
    // measured). A REPO entry is reported by `mergeMcpLayers`, which evaluates the EFFECTIVE entry (the
    // delta may be what makes it incoherent); a BASE entry never passes through that path — the merge
    // copies base entries verbatim — so it is reported here or nowhere. WARN only: `type` must never
    // disqualify an entry (see `RECOGNISED_TYPES`).
    if (label.startsWith("base") && typeDisagrees(entry as McpServerConfig)) {
      console.log(
        `[mcp-client] note: ${label} entry "${name}" declares a "type" that disagrees with its transport — ` +
          `this client selects the transport from url/command, so the entry is kept as written.`
      );
    }
    // ⛔ BOTH TRANSPORTS: THE BASE LAYER IS WARNED ABOUT HERE, AND THE REPO RULING IS LEFT TO THE MERGE.
    // `connectServer` tests `url` BEFORE `command`, so such an entry runs over HTTP and ignores the
    // `command`. The ruling has TWO halves — a repo DELTA is ignored (base kept), a repo-ONLY entry is
    // kept — and only `mergeMcpLayers` can tell them apart, because only there is the base's own entry
    // visible. Dropping a repo entry HERE made that tested distinction unreachable: a repo-only
    // ambiguous entry was silently unloaded, while `mergeMcpLayers` and `SETUP-NEW-MACHINE.md` both
    // promise it is KEPT and runs over `url` (dropping it zeroes a config that works — the same failure
    // the `type` ruling forbids). So the layer read only warns, and only for the layer whose entries the
    // merge copies verbatim and never inspects. A repo cannot REMOVE a base server either way: the merge
    // keeps the base entry when the repo entry is a delta.
    if (label.startsWith("base") && typed.url !== undefined && typed.command !== undefined) {
      console.log(
        `[mcp-client] WARN: ${label} entry "${name}" declares BOTH "url" and "command" — ambiguous; ` +
          `it is KEPT and will run over "url" (that is the order this client dispatches in). ` +
          `Remove one to be explicit.`
      );
    }
    servers[name] = entry as McpServerConfig;
  }
  return { ...(value as Record<string, unknown>), mcpServers: servers } as McpJson;
}

export interface McpConfigPaths {
  /** `~/.pi/agent/.mcp.json` — the hub's shared layer. Never ships, may be absent. */
  base: string | null;
  /** The first `.mcp.json` walking up from the cwd — the repo's delta. May be absent. */
  repo: string | null;
}

/**
 * Resolve the .mcp.json path for the current session (#104) — the SINGLE-PATH form.
 *
 * ⛔ THIS IS A BACK-COMPAT SHIM, NOT THE RESOLVER'S CONTRACT. It answers "which ONE file is the
 * repo-local config, else which ONE file is the base" — exactly the shape that made the base inert
 * (#3612), because it can only ever name one of the two. Every caller that CONNECTS must use
 * `resolveMcpConfigPaths` + `mergeMcpLayers` so the base layer is not hidden by a repo file.
 * Kept for existing callers and tests.
 *
 * Exported (named) for unit tests; the default export stays the extension hook.
 */
export function resolveMcpJsonPath(startDir: string = process.cwd()): string | null {
  const layers = resolveMcpConfigPaths(startDir);
  return layers.repo ?? layers.base;
}

/**
 * BOTH layers that can define MCP servers (#3612).
 *
 * ⛔ THE BASE IS A LAYER, NOT A FALLBACK. `agent-infra` is the hub: skills, gates, AGENTS.md and the
 * harness are authored there and derived into every repo, and `~/.pi/agent/.mcp.json` is the same kind
 * of thing — the hub's per-machine shared config, installed from `templates/.mcp.base.json` and shipped
 * to nobody. A repo's own `.mcp.json` is a DELTA on that layer.
 *
 * The old first-match rule made the base inert for every repo that carries a local config: adding a
 * server to the hub's base reached only the repos WITHOUT one. For a product repo (tortoise) the only
 * workaround was to write internal tooling into a TRACKED product file — the hub/product confusion
 * this fleet must not create. Measured 2026-11-06.
 *
 * Resolution order, per layer and now run INDEPENDENTLY (#104's walk semantics are unchanged):
 *   1. repo — walk UP from `startDir` (default process.cwd()), stopping at the git top-level when one
 *      is resolvable (same `git rev-parse --show-toplevel` logic as reflect-hook /
 *      main-worktree-guard). Non-git directories walk to the filesystem root. First `.mcp.json` found
 *      wins. OPTIONAL — absent is normal.
 *   2. base — `~/.pi/agent/.mcp.json` (the bootstrapped base config installed by
 *      pi-bootstrap/setup.sh from templates/.mcp.base.json). Resolved WHETHER OR NOT a repo file was
 *      found — that is the whole of #3612. OPTIONAL — absent is normal.
 *
 * Both null → no config anywhere; the caller logs the clear zero-servers message.
 */
export function resolveMcpConfigPaths(startDir: string = process.cwd()): McpConfigPaths {
  let topLevel: string | null = null;
  let repo: string | null = null;
  let base: string | null = null;
  try {
    // realpath the git output once so the walk-up stop comparison below is
    // symlink-robust (worktrees / symlinked checkouts may resolve differently).
    topLevel = realpathSync(
      execSync("git rev-parse --show-toplevel", {
        cwd: startDir,
        encoding: "utf-8",
        timeout: 3000,
        stdio: ["ignore", "pipe", "ignore"], // silence git stderr for non-repos
      }).trim()
    );
  } catch {
    topLevel = null; // not in a git repo (or git unavailable) — walk to fs root
  }

  let dir = resolve(startDir);
  while (true) {
    const candidate = join(dir, ".mcp.json");
    if (existsSync(candidate)) { repo = candidate; break; }
    if (topLevel) {
      let realDir: string | null = null;
      try {
        realDir = realpathSync(dir);
      } catch {
        realDir = null;
      }
      if (realDir === topLevel) break;
    }
    const parent = dirname(dir);
    if (parent === dir) break; // hit filesystem root
    dir = parent;
  }

  // ⛔ THE BASE IS RESOLVED WHETHER OR NOT A REPO FILE WAS FOUND. It used to be a FALLBACK, taken
  // only when the walk found nothing — which made the hub's shared layer inert in every repo that
  // carries its own config (measured 2026-11-06: `orchestrator` reached agent-infra and never
  // tortoise, and the only workaround was writing internal tooling into a TRACKED product file).
  const homeFallback = join(homedir(), ".pi", "agent", ".mcp.json");
  base = existsSync(homeFallback) ? homeFallback : null;
  return { base, repo };
}

/** Connect to a single MCP server with a timeout. Cleans up on failure to avoid orphan processes. */
async function connectWithTimeout(
  name: string,
  client: Client,
  transport: StdioClientTransport | StreamableHTTPClientTransport,
  timeoutMs: number = 15000
): Promise<void> {
  const connect = client.connect(transport);
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(
      () => reject(new Error(`Connection to '${name}' timed out after ${timeoutMs}ms`)),
      timeoutMs
    );
  });

  try {
    await Promise.race([connect, timeout]);
  } catch (err) {
    // #36: Clean up to avoid orphan processes. Add a 3s timeout to client.close()
    // so a hung transport teardown doesn't block the connection failure path.
    try {
      await Promise.race([
        client.close(),
        new Promise<void>((resolve) => setTimeout(resolve, 3000)),
      ]);
    } catch { /* best effort */ }
    throw err;
  } finally {
    if (timer) clearTimeout(timer);
  }
}

/** Parse PI_MCP_SERVERS env var. Returns undefined if not set (load all), or a Set of allowed server names. */
function getAllowedServers(): Set<string> | undefined {
  const raw = process.env.PI_MCP_SERVERS?.trim();
  if (!raw) return undefined;
  return new Set(raw.split(",").map(s => s.trim()).filter(Boolean));
}

/**
 * #199: partition declared servers into the eager core (connect at startup)
 * and lazy servers (skip at startup, load on demand via mcp_load).
 *
 * - No PI_MCP_SERVERS → non-lazy servers are eager; lazy servers are skipped.
 * - PI_MCP_SERVERS set → ONLY the named servers load, and they load eagerly
 *   (explicitly naming a lazy server forces eager — skills pass e.g.
 *   gemini,cloudinary to the task tool's mcp_servers param for image work).
 *   Unnamed servers are excluded entirely.
 *
 * Exported (named) for unit tests.
 */
export function classifyServers(
  servers: Record<string, McpServerConfig>,
  allowedServers: Set<string> | undefined
): { eager: [string, McpServerConfig][]; lazySkipped: string[] } {
  const eager: [string, McpServerConfig][] = [];
  const lazySkipped: string[] = [];
  for (const [name, cfg] of Object.entries(servers)) {
    // ⛔ THE BELT FOR A DIRECT CALLER. This function is exported, and it reads `cfg.lazy` — so a
    // non-object entry throws `reading 'lazy'`. The entry points do NOT need this: `connectConfig`
    // sanitises `mcpServers` once, so `classifyServers` reached through it only ever sees objects. This
    // covers a direct caller of the exported function, and a `this.config` assigned by hand.
    if (!isServerEntry(cfg)) {
      console.log(
        `[mcp-client] WARN: server "${name}" is not an object — skipped (no transport, and no crash)`
      );
      continue;
    }
    if (allowedServers && !allowedServers.has(name)) continue; // excluded by PI_MCP_SERVERS
    const forcedEager = allowedServers?.has(name) === true;
    if (cfg.lazy === true && !forcedEager) lazySkipped.push(name);
    else eager.push([name, cfg]);
  }
  return { eager, lazySkipped };
}

export class McpServerManager {
  private connections: McpConnection[] = [];
  // #92: serverName → stdio child pid, captured at connect time (the SDK's
  // `pid` getter returns null as soon as close() starts, so it can't be read
  // later). Used to force-kill orphaned transports when disconnectAll times
  // out or pi exits without a clean session shutdown.
  private transportPids = new Map<string, number>();
  // #199: parsed config (all declared servers, incl. lazy) + extension API,
  // retained so mcp_catalog / mcp_load work after eager connect is done.
  private config: McpJson | null = null;
  private pi: ExtensionAPI | null = null;
  private registeredTools = new Set<string>();
  private seededTools = false;
  private idleSweepTimer: ReturnType<typeof setInterval> | null = null;

  constructor() {
    // #92: last-resort synchronous sweep — if the process exits without
    // session_shutdown, force-kill any still-tracked stdio children so they
    // can't outlive pi. 'exit' handlers can't await, so this is a direct
    // SIGKILL; on normal exits disconnectAll clears the map first.
    process.on("exit", () => {
      for (const [serverName, pid] of this.transportPids) {
        try {
          process.kill(pid, 0); // existence probe — throws if already gone
          process.kill(pid, "SIGKILL");
          console.log(
            `[mcp-client] killed orphaned transport for '${serverName}' (pid ${pid}) on process exit`
          );
        } catch {
          /* already gone */
        }
      }
    });
  }

  async connectAll(mcpJsonPath: string): Promise<void> {
    let config: McpJson;
    try {
      const raw = await readFile(mcpJsonPath, "utf-8");
      config = JSON.parse(raw);
    } catch {
      console.log(`[mcp-client] Could not read ${mcpJsonPath}, skipping MCP`);
      return;
    }
    await this.connectConfig(config);
  }

  /**
   * Connect from BOTH layers: the hub's base config underneath, the repo's `.mcp.json` over it.
   *
   * ⛔ MERGE ORDER IS `{ **base, **repo }` — the repo is LAST, so a repo FIELD wins against the base's,
   * per server and per field. What that means in practice:
   *   * an override that sets only `timeoutMs` / `lazy` / catalog metadata keeps the base's `url`,
   *     `headers`, `oauth` and the rest — the destination and the launch are unchanged;
   *   * an override that CHANGES `url` keeps `lazy`/`timeoutMs` but **DROPS `headers`/`oauth`**, which
   *     belong to the endpoint they were issued for; an override that changes the LAUNCH
   *     (`command`/`args`/`cwd`) **DROPS the base's `env`**. See `mergeMcpLayers` for both guards.
   * The base must never be able to shadow what a repo declares: it is spread FIRST, so every field the
   * repo sets wins — `~/.pi/agent/.mcp.json` is
   * machine-local, and letting it override a repo would make one box's config change what a
   * checked-out repo means.
   *
   * ⛔ A LAYER THAT FAILS TO READ IS SAID SO, BY NAME. A broken repo file must not take the hub's
   * servers away with it — so the surviving layer is still used — but the base is machine-local, so
   * silently substituting it is the ONE inversion this merge exists to forbid: a repo pinning its own
   * local daemon would quietly connect to whatever this box's base points at instead. The warning
   * names the layer, the path, the reason, and that its servers are NOT in effect.
   *
   * Read-side only: nothing is written, and `setup.sh`'s `{**dst, **src}` policy for the base file is
   * untouched.
   *
   * ⛔ `DELTA` IS ONE-WAY. A repo can ADD a server, or OVERRIDE fields of one of the base's; it
   * cannot REMOVE a base server, because there is no tombstone in this schema and `McpServerConfig`
   * has no `disabled` field. A base server that is wrong or unspawnable for one repo cannot be vetoed
   * from that repo — see #3612 for the tombstone (`"<name>": { "disabled": true }`) that would
   * close this. Writing `"<name>": null` is NOT that: it is dropped with a warning (see `asMcpJson`),
   * and the base's entry still applies.
   */
  async connectAllLayers(paths: McpConfigPaths): Promise<void> {
    const read = async (p: string | null, layer: "base" | "repo"): Promise<McpJson | null> => {
      if (!p) return null;
      let raw: string;
      try {
        raw = await readFile(p, "utf-8");
      } catch (err) {
        console.log(
          `[mcp-client] WARN: ${layer} layer ${p} could not be read (${(err as Error).message}) — ` +
            `its servers are NOT in effect`
        );
        return null;
      }
      let parsed: unknown;
      try {
        parsed = JSON.parse(raw);
      } catch (err) {
        console.log(
          `[mcp-client] WARN: ${layer} layer ${p} is not valid JSON (${(err as Error).message}) — ` +
            `its servers are NOT in effect`
        );
        return null;
      }
      const config = asMcpJson(parsed, `${layer} layer ${p}`);
      if (!config) {
        // `JSON.parse` admits `null`, arrays and scalars. Without this arm they read as a HEALTHY
        // layer that contributes zero servers, with nothing logged (measured: `"null"` in a repo
        // file silently resolved to the base's servers).
        console.log(
          `[mcp-client] WARN: ${layer} layer ${p} is not an object with an "mcpServers" object — ` +
            `its servers are NOT in effect`
        );
        return null;
      }
      return config;
    };
    const base = await read(paths.base, "base");
    const repo = await read(paths.repo, "repo");
    if (!base && !repo) {
      console.log("[mcp-client] No readable .mcp.json in either layer");
      return;
    }
    const merged = mergeMcpLayers(base, repo);
    // State which layers are ACTUALLY supplying servers. A repo whose file failed is the case where
    // this line is the only thing that tells the operator its entries never applied.
    const inEffect = [base ? "base" : null, repo ? "repo" : null].filter(Boolean).join(" + ");
    const count = Object.keys(merged).length;
    console.log(
      `[mcp-client] MCP layers in effect: ${inEffect} — ${count} server(s)` +
        (count === 0 ? " — running with ZERO MCP servers" : "")
    );
    // Non-`mcpServers` top-level keys are spread from BOTH layers (repo last, repo wins). Spreading
    // only the present layer would silently amputate a base-only key the moment a repo file appears.
    await this.connectConfig({ ...(base ?? {}), ...(repo ?? {}), mcpServers: merged } as McpJson);
  }

  private async connectConfig(config: McpJson): Promise<void> {
    // ⛔ SANITISE ONCE, HERE, so every reader of `this.config` is safe: `classifyServers` (below),
    // `catalog()` (mcp_catalog), `loadServer`/the reconnect path, and the idle sweep. This is the single
    // funnel both entry points go through, so a non-object entry (`{"tortoise": null}` in a legacy or
    // hand-written config that bypassed `asMcpJson`) can no longer throw `reading 'lazy'` anywhere — the
    // crash used to move from the extension factory to whichever tool ran next.
    const sanitised: Record<string, McpServerConfig> = Object.create(null);
    const rawServers = config?.mcpServers;
    const declaresServers =
      !!rawServers && typeof rawServers === "object" && !Array.isArray(rawServers);
    if (declaresServers) {
      for (const [name, entry] of Object.entries(rawServers as Record<string, unknown>)) {
        if (!isServerEntry(entry)) {
          console.log(
            `[mcp-client] WARN: server "${name}" is not an object — skipped (no transport, and no crash)`
          );
          continue;
        }
        sanitised[name] = entry;
      }
    }
    this.config = { ...config, mcpServers: sanitised } as McpJson;

    // Test the CONFIG, not the sanitised map: an empty map is also what a config with no `mcpServers`
    // key produces, and that case must keep its own message.
    if (!declaresServers) {
      console.log("[mcp-client] No mcpServers in .mcp.json");
      return;
    }

    const servers = sanitised;

    // #199: eager core connects at startup; lazy servers are skipped and
    // remain discoverable via mcp_catalog + loadable via mcp_load.
    const allowedServers = getAllowedServers();
    const { eager, lazySkipped } = classifyServers(servers, allowedServers);

    if (lazySkipped.length > 0) {
      console.log(
        `[mcp-client] ${lazySkipped.length} lazy server(s) not loaded at startup (load on demand via mcp_load): ${lazySkipped.join(", ")}`
      );
    }
    if (allowedServers) {
      const excluded = Object.keys(servers).filter(s => !allowedServers.has(s));
      console.log(
        `[mcp-client] PI_MCP_SERVERS set → loading ${eager.length} of ${Object.keys(servers).length} servers eagerly (excluded: ${excluded.join(", ")})`
      );
    }

    const DEFAULT_CONNECTION_TIMEOUT_MS = 15000;

    // Connect to all eager servers in parallel with per-server timeout.
    // Each server can override via timeoutMs in .mcp.json (e.g. tortoise needs ~30s for warm-up).
    // #802: a failed attempt is retried ONCE — remote servers are cold on first
    // use and the failure is expected, not exceptional (see connectEagerWithRetry).
    // Track server names alongside results so error logs identify which server failed.
    const results = await Promise.allSettled(
      eager.map(async ([serverName, serverConfig]) => {
        const startTime = Date.now();
        const timeoutMs = serverConfig.timeoutMs ?? DEFAULT_CONNECTION_TIMEOUT_MS;
        const { attempts } = await connectEagerWithRetry(serverName, () =>
          this.connectServer(serverName, serverConfig, timeoutMs)
        );
        console.log(
          `[mcp-client] Connected to '${serverName}' (${Date.now() - startTime}ms${attempts > 1 ? `, attempt ${attempts}` : ""})`
        );
        return serverName;
      })
    );

    let succeeded = 0;
    for (let i = 0; i < results.length; i++) {
      const result = results[i]!;
      if (result.status === "rejected") {
        // Use the server name from the input array at the same index
        const serverName = eager[i]?.[0] ?? "unknown";
        const errMsg = result.reason?.message ?? String(result.reason);
        console.log(
          `[mcp-client] Failed to connect to MCP server '${serverName}': ${errMsg}`
        );
        // #36: Fail-fast — MCP unavailable, continuing without it.
        // Sub-agents already work without MCP; hanging at exit wastes ~8min.
        // #802: name the recovery command — the agent/user cannot call a
        // health tool for a server whose tools never registered, so the log
        // line is the only signal. mcp_load retries the connection on demand
        // and registers the tools for the rest of the session.
        console.log(
          `[mcp-client] MCP server '${serverName}' unavailable — continuing without it. ` +
            // Only the fields named here change — `mergeMcpLayers` is per-field, so an entry that sets
            // just `timeoutMs` keeps the base's `url`/`headers`/`lazy`. A whole-entry override used to
            // be the fix this line recommended, and it made the server unspawnable.
            `Recover with: mcp_load ${serverName} (or raise "timeoutMs" in .mcp.json for a slow cold start — set only that field).`
        );
      } else {
        succeeded++;
      }
    }
    console.log(`[mcp-client] Connected to ${succeeded}/${eager.length} eager servers`);
  }

  private async connectServer(
    name: string,
    config: McpServerConfig,
    timeoutMs: number = 15000
  ): Promise<void> {
    const client = new Client(
      { name: "pi-mcp-client", version: "1.0.0" },
      { capabilities: {} }
    );

    let transport: StdioClientTransport | StreamableHTTPClientTransport;
    let oauthProvider: McpOAuthClientProvider | undefined;

    if (config.url) {
      // URL-based transport (e.g., Supabase MCP, remote servers)
      const headers = config.headers ? expandEnvVars(config.headers) : undefined;
      const opts: ConstructorParameters<typeof StreamableHTTPClientTransport>[1] = {
        requestInit: headers ? { headers } : undefined,
      };

      if (config.oauth) {
        // OAuth 2.1 authorization-code PKCE flow (#595)
        oauthProvider = new McpOAuthClientProvider(new URL(config.url), config.oauth);
        opts.authProvider = oauthProvider;
      }

      transport = new StreamableHTTPClientTransport(
        new URL(config.url),
        opts
      );
    } else if (config.command) {
      // Stdio transport (local process)
      // Expand ${VAR} placeholders in config.env (same as headers above) so
      // servers like @houtini/gemini-mcp receive real values, not literal
      // "${VAR}" strings (e.g. GEMINI_API_KEY). See tortoise issue #240.
      const env = buildMcpServerEnv(config);
      transport = new StdioClientTransport({
        // #199: command may contain ${VAR} placeholders (e.g. the tortoise
        // base config points at ${TORTOISE_HOME}/.venv/bin/python3) — expand
        // like env/cwd, or the spawn fails with ENOENT.
        command: expandExpr(config.command),
        args: config.args ?? [],
        env,
        // cwd may contain ${VAR} placeholders (e.g. TORTOISE_HOME in the base
        // config) — expand like env/headers, or the spawn fails with ENOENT.
        cwd: config.cwd ? expandEnvVars({ cwd: config.cwd }).cwd : undefined,
      });
    } else {
      throw new Error(
        `Server '${name}' has neither 'command' nor 'url'`
      );
    }

    // Connect with timeout
    await connectWithTimeout(name, client, transport, timeoutMs);

    // #92: remember the stdio child pid for the orphan-kill path. Must be
    // captured here, right after connect: the SDK's pid getter reads the
    // private _process field, which is cleared as soon as close() begins.
    // URL-based transports spawn no child process.
    if (transport instanceof StdioClientTransport) {
      const pid = transport.pid;
      if (pid !== null) this.transportPids.set(name, pid);
    }

    // #199: track tier + last-used for the idle sweep.
    this.connections.push({
      client,
      serverName: name,
      lazy: config.lazy === true,
      idleTimeoutMs: config.idleTimeoutMs ?? DEFAULT_IDLE_TIMEOUT_MS,
      lastUsed: Date.now(),
      oauthProvider,
    });
  }

  async registerTools(pi: ExtensionAPI): Promise<void> {
    this.pi = pi;
    this.seedExistingTools();
    // #199: only connected (eager) servers have tools to register at startup;
    // lazy servers register their tools on demand via loadServer → registerServerTools.
    for (const { serverName } of [...this.connections]) {
      await this.registerServerTools(serverName);
    }
  }

  /** Seed the dedup set from tools pi already knows about (native / prior registration). */
  private seedExistingTools(): void {
    if (this.seededTools || !this.pi) return;
    this.seededTools = true;
    try {
      for (const t of this.pi.getAllTools()) this.registeredTools.add(t.name);
    } catch {
      // runtime not bound yet — rely on registeredTools only
    }
  }

  /** Record a server as recently used (resets its idle timer). */
  private markUsed(serverName: string): void {
    const conn = this.findConnection(serverName);
    if (conn) conn.lastUsed = Date.now();
  }

  private findConnection(serverName: string): McpConnection | undefined {
    return this.connections.find((c) => c.serverName === serverName);
  }

  /** Register every tool from one connected server under mcp__<server>__<tool>. */
  async registerServerTools(serverName: string): Promise<string[]> {
    const conn = this.findConnection(serverName);
    const pi = this.pi;
    if (!conn || !pi) return [];
    const { client } = conn;
    const registered: string[] = [];
    try {
      const { tools } = await client.listTools();
      for (const tool of tools) {
        const toolName = `mcp__${serverName}__${tool.name}`;
        const safeName = toolName.replace(/\./g, "_");

        if (this.registeredTools.has(safeName)) {
          console.log(`[mcp-client] Skipped duplicate tool: ${safeName}`);
          continue;
        }

        let parameters: TSchema;
        try {
          parameters = jsonSchemaToTypeBox(tool.inputSchema);
        } catch {
          parameters = Type.Object({
            arguments: Type.Optional(
              Type.String({ description: "Tool arguments as JSON string" })
            ),
          });
        }

        pi.registerTool({
          name: safeName,
          label: `${serverName}:${tool.name}`,
          description:
            tool.description ?? `MCP tool: ${serverName}/${tool.name}`,
          parameters,
          execute: async (_toolCallId, params: Record<string, unknown>) => {
            const startMs = Date.now();
            try {
              // #199: a lazy server may have been idle-stopped — reconnect on
              // next use so a registered tool stays valid across the sweep
              // (lazy proxy: the server starts again on first tool call).
              let conn = this.findConnection(serverName);
              if (!conn) {
                const cfg = this.config?.mcpServers[serverName];
                if (!cfg) {
                  return {
                    content: [
                      { type: "text" as const, text: `MCP server '${serverName}' is not configured (see mcp_catalog).` },
                    ],
                    details: { serverName, toolName: tool.name, isError: true },
                  };
                }
                await this.connectServer(serverName, cfg, cfg.timeoutMs ?? 15000);
                conn = this.findConnection(serverName);
                if (!conn) {
                  return {
                    content: [
                      { type: "text" as const, text: `MCP server '${serverName}' failed to reconnect.` },
                    ],
                    details: { serverName, toolName: tool.name, isError: true },
                  };
                }
              }
              this.markUsed(serverName);
              const client = conn.client;
              console.log(`[mcp-client] → ${serverName}/${tool.name}`);
              const result = await client.callTool(
                { name: tool.name, arguments: params },
                undefined,
                { timeout: 3_600_000 }
              );

              console.log(`[mcp-client] ← ${serverName}/${tool.name} (${Date.now() - startMs}ms)`);
              const textContent = result.content
                .filter((c: any) => c.type === "text")
                .map((c: any) => c.text)
                .join("\n");

              return {
                content: [
                  {
                    type: "text" as const,
                    text: textContent || JSON.stringify(result.content),
                  },
                ],
                details: { serverName, toolName: tool.name },
              };
            } catch (err: any) {
              if (err instanceof UnauthorizedError) {
                const msg = err.message ?? `MCP server '${serverName}' requires re-authorization`;
                console.log(`[mcp-client] 🔐 Re-authorization needed for '${serverName}': ${msg}`);
                // #595: surface a clear re-auth signal in the error return. The
                // session coordinator can read this message to prompt the user.
                return {
                  content: [
                    {
                      type: "text" as const,
                      text: `🔐 OAuth re-authorization needed for '${serverName}'. The access token has expired or was revoked. To re-authorize, you may need to connect again. Error: ${msg}`,
                    },
                  ],
                  details: { serverName, toolName: tool.name, isError: true, reauthNeeded: true },
                };
              }
              return {
                content: [
                  {
                    type: "text" as const,
                    text: `MCP tool '${tool.name}' failed: ${err.message}`,
                  },
                ],
                details: {
                  serverName,
                  toolName: tool.name,
                  isError: true,
                },
              };
            }
          },
        });

        this.registeredTools.add(safeName);
        registered.push(safeName);
        console.log(`[mcp-client] Registered tool: ${safeName}`);
      }
      console.log(
        `[mcp-client] Registered ${tools.length} tools from '${serverName}'`
      );
    } catch (err: any) {
      console.log(
        `[mcp-client] Failed to list tools from '${serverName}': ${err.message}`
      );
    }
    return registered;
  }

  /**
   * #36/#92: disconnect a single server, preserving the exact forced-close
   * semantics of the original disconnectAll (5s client.close timeout → orphan
   * kill on hang). Shared by disconnectAll, the #199 idle sweep, and re-loads
   * via loadServer. No new teardown code — the same path.
   */
  private async closeServer(serverName: string): Promise<void> {
    const conn = this.findConnection(serverName);
    if (!conn) return;
    const { client } = conn;
    const DISCONNECT_TIMEOUT_MS = 5000;
    let timer: ReturnType<typeof setTimeout> | undefined;
    let timedOut = false;
    try {
      const closeOp = client.close();
      const timeout = new Promise<void>((resolve) => {
        timer = setTimeout(() => {
          timedOut = true;
          console.log(
            `[mcp-client] Disconnect from '${serverName}' timed out after ${DISCONNECT_TIMEOUT_MS}ms — forcing`
          );
          resolve();
        }, DISCONNECT_TIMEOUT_MS);
      });
      await Promise.race([closeOp, timeout]);
      if (timer) clearTimeout(timer); // don't leave a dangling timer that logs spuriously
      if (timedOut) {
        // #92: the race above resolved, but the hung transport child is
        // still around — kill it so no orphan MCP process outlives pi.
        await this.killOrphanedTransport(serverName);
      }
      console.log(`[mcp-client] Disconnected from '${serverName}'`);
    } catch {
      if (timer) clearTimeout(timer);
      // Best effort — never block process exit
    }
    this.transportPids.delete(serverName);
    this.connections = this.connections.filter((c) => c.serverName !== serverName);
  }

  async disconnectAll(): Promise<void> {
    this.stopIdleSweep();
    // Snapshot names first: closeServer mutates this.connections.
    const names = this.connections.map((c) => c.serverName);
    for (const name of names) {
      await this.closeServer(name);
    }
    this.transportPids.clear();
    this.connections = [];
  }

  // ── #199: catalog + on-demand load + idle sweep ─────────────────

  /** Connect a lazy server on demand and register its tools. */
  async loadServer(serverName: string): Promise<{ registered: string[]; alreadyLoaded: boolean }> {
    if (!this.config) throw new Error("No MCP config loaded in this session");
    const cfg = this.config.mcpServers[serverName];
    if (!cfg) {
      throw new Error(
        `Unknown MCP server '${serverName}' — run mcp_catalog to list available servers`
      );
    }

    if (this.findConnection(serverName)) {
      return { registered: [], alreadyLoaded: true };
    }

    const timeoutMs = cfg.timeoutMs ?? 15000;
    await this.connectServer(serverName, cfg, timeoutMs);
    console.log(`[mcp-client] Loaded '${serverName}' on demand`);
    this.seedExistingTools();
    const registered = await this.registerServerTools(serverName);
    return { registered, alreadyLoaded: false };
  }

  /** Static catalog of every declared server (no connect required). */
  catalog(): Array<{ name: string; tier: string; status: string; purpose: string; whenToLoad: string; cost: string }> {
    if (!this.config) return [];
    return Object.entries(this.config.mcpServers).flatMap(([name, cfg]) => {
      // `this.config` is sanitised by `connectConfig`, but `catalog()` is also reachable on a manager
      // whose config a test (or a future caller) assigned directly — and this is the tool every error
      // message tells the operator to run, so it must not be the one that throws.
      if (!isServerEntry(cfg)) return [];
      const lazy = cfg.lazy === true;
      const loaded = this.findConnection(name) !== undefined;
      return [{
        name,
        tier: lazy ? "lazy" : "core",
        status: loaded ? "loaded" : lazy ? "sleeping" : "not-loaded",
        purpose: cfg.purpose ?? "",
        whenToLoad: cfg.whenToLoad ?? "",
        cost: cfg.cost ?? "",
      }];
    });
  }

  /** Register the mcp_catalog + mcp_load tools (available in sub-agents too). */
  registerLifecycleTools(pi: ExtensionAPI): void {
    this.pi = pi;

    pi.registerTool({
      name: "mcp_catalog",
      label: "MCP server catalog",
      description:
        "List every declared MCP server: name, tier (core always-on / lazy on-demand), status (loaded/sleeping), purpose, when to load, and rough cost. Use this to discover tools, then mcp_load to start a lazy server before calling its tools.",
      parameters: Type.Object({}),
      execute: async () => {
        const entries = this.catalog();
        if (entries.length === 0) {
          return { content: [{ type: "text" as const, text: "No MCP servers declared in this session's .mcp.json." }] };
        }
        const lines = entries.map((e) => {
          const meta = [e.purpose, e.whenToLoad, e.cost].filter(Boolean).join(" | ");
          const status = e.status === "loaded" ? "loaded" : e.status === "sleeping" ? "sleeping (mcp_load to start)" : "not-loaded";
          return `- ${e.name} [${e.tier}, ${status}]${meta ? " — " + meta : ""}`;
        });
        return { content: [{ type: "text" as const, text: `MCP server catalog:\n${lines.join("\n")}` }] };
      },
    });

    pi.registerTool({
      name: "mcp_load",
      label: "Load MCP server on demand",
      description:
        "Start a lazy MCP server on first use and register its tools (named mcp__<server>__<tool>). Returns the registered tool names — call them on the NEXT turn. Servers auto-stop after an idle timeout. Use mcp_catalog to see what's available.",
      parameters: Type.Object({
        server: Type.String({ description: "MCP server name (see mcp_catalog)" }),
      }),
      execute: async (_toolCallId, params) => {
        const serverName = String(params.server ?? "").trim();
        if (!serverName) {
          return { content: [{ type: "text" as const, text: "mcp_load: 'server' is required (see mcp_catalog)." }] };
        }
        try {
          const { registered, alreadyLoaded } = await this.loadServer(serverName);
          if (alreadyLoaded) {
            return { content: [{ type: "text" as const, text: `MCP server '${serverName}' is already loaded.` }] };
          }
          const toolList = registered.length
            ? registered.map((r) => `- ${r}`).join("\n")
            : "(no tools registered)";
          return {
            content: [
              {
                type: "text" as const,
                text: `Loaded '${serverName}'. Registered tools:\n${toolList}\n\nCall them on the next turn.`,
              },
            ],
          };
        } catch (err: any) {
          return {
            content: [
              { type: "text" as const, text: `mcp_load failed for '${serverName}': ${err.message}` },
            ],
          };
        }
      },
    });

    // #595: OAuth finish-auth tool — lets the session complete the PKCE flow
    // after the user authorizes in their browser.
    pi.registerTool({
      name: "mcp_finish_auth",
      label: "Complete OAuth authorization",
      description:
        "Complete the OAuth authorization flow for an MCP server. Call this after " +
        "opening the authorization URL in your browser and pasting the 'code' parameter " +
        "from the redirect URL. The transport will then exchange the code for tokens and reconnect.",
      parameters: Type.Object({
        server: Type.String({ description: "MCP server name to complete authorization for" }),
        authorizationCode: Type.String({ description: "The 'code' parameter from the redirect URL after authorizing in the browser" }),
      }),
      execute: async (_toolCallId, params) => {
        const serverName = String(params.server ?? "").trim();
        const authCode = String(params.authorizationCode ?? "").trim();
        if (!serverName || !authCode) {
          return {
            content: [{ type: "text" as const, text: "mcp_finish_auth: both 'server' and 'authorizationCode' are required." }],
          };
        }
        const conn = this.findConnection(serverName);
        if (!conn) {
          return {
            content: [{ type: "text" as const, text: `Server '${serverName}' is not connected. Run mcp_load first if it is lazy, or check mcp_catalog.` }],
          };
        }
        // Use the client's transport if it implements finishAuth.
        // The StreamableHTTPClientTransport has a finishAuth method (the
        // SDK's Client itself does NOT — review P1, PR #604).
        const client = conn.client as any;
        const transport = client?.transport as any;
        if (typeof transport?.finishAuth !== "function") {
          return {
            content: [{ type: "text" as const, text: `Server '${serverName}' does not support OAuth finish-auth (transport may not be OAuth-capable).` }],
          };
        }
        try {
          await transport.finishAuth(authCode);
          // After finishAuth, clear the pending auth state on the provider.
          if (conn.oauthProvider) {
            conn.oauthProvider.clearPendingAuth();
          }
          return {
            content: [
              {
                type: "text" as const,
                text: `Authorization completed for '${serverName}'. Tokens exchanged successfully. You can now use ${serverName}'s tools.`,
              },
            ],
          };
        } catch (err: any) {
          return {
            content: [
              {
                type: "text" as const,
                text: `Authorization failed for '${serverName}': ${err.message}. You may need to re-authorize by calling mcp_load again.`,
              },
            ],
          };
        }
      },
    });
  }

  private startIdleSweep(): void {
    if (this.idleSweepTimer) return;
    this.idleSweepTimer = setInterval(() => {
      void this.sweepIdleServers();
    }, IDLE_SWEEP_INTERVAL_MS);
    // Don't keep a session alive solely for the idle sweep.
    if (typeof this.idleSweepTimer.unref === "function") this.idleSweepTimer.unref();
  }

  private stopIdleSweep(): void {
    if (this.idleSweepTimer) {
      clearInterval(this.idleSweepTimer);
      this.idleSweepTimer = null;
    }
  }

  /** Disconnect lazy servers idle past their idleTimeoutMs. */
  private async sweepIdleServers(): Promise<void> {
    const now = Date.now();
    const stale = this.connections.filter(
      (c) => c.lazy && now - c.lastUsed >= c.idleTimeoutMs
    );
    for (const conn of stale) {
      console.log(
        `[mcp-client] Idle sweep: stopping lazy server '${conn.serverName}' (idle ≥ ${conn.idleTimeoutMs}ms)`
      );
      await this.closeServer(conn.serverName);
    }
  }

  /**
   * #92: Force-kill the stdio child process of a transport whose close()
   * hung. SIGTERM first, a 2s grace period, then SIGKILL if still alive.
   * Every step is guarded — the child may already have exited (e.g. the SDK
   * finished killing it after the race resolved), and kill() on a dead pid
   * throws ESRCH.
   */
  private async killOrphanedTransport(serverName: string): Promise<void> {
    const pid = this.transportPids.get(serverName);
    if (pid === undefined) return; // URL transport or no child tracked
    const GRACE_MS = 2000;

    const isAlive = (): boolean => {
      try {
        process.kill(pid, 0); // existence probe, no signal sent
        return true;
      } catch {
        return false;
      }
    };

    if (!isAlive()) return; // already exited — nothing to kill

    try {
      process.kill(pid, "SIGTERM");
    } catch {
      return; // exited between the probe and the kill
    }

    await new Promise<void>((resolve) => setTimeout(resolve, GRACE_MS));

    if (isAlive()) {
      try {
        process.kill(pid, "SIGKILL");
      } catch {
        return; // exited during the grace period
      }
    }
    console.log(
      `[mcp-client] killed orphaned transport for '${serverName}' (pid ${pid})`
    );
  }
}

// ── Extension Entry Point ───────────────────────────────────────────

export default async function (pi: ExtensionAPI) {
  const manager = new McpServerManager();

  // #104: resolve .mcp.json with an upward search (cwd → git top-level) for the REPO's delta, and
  // resolve ~/.pi/agent/.mcp.json as the hub's BASE layer — BOTH, then merged with the repo winning
  // (#3612). It is no longer a fallback; naming it one was the defect. Log both paths so a
  // zero-server session is diagnosable at a glance.
  const searchedDir = process.cwd();
  const layers = resolveMcpConfigPaths(searchedDir);
  if (layers.repo || layers.base) {
    console.log(
      `[mcp-client] MCP layers: base=${layers.base ?? "(none)"} repo=${layers.repo ?? "(none)"} ` +
        `(repo fields win per server; an ambiguous repo entry leaves the base's entry in place; ` +
        `searched up from ${searchedDir})`
    );
  } else {
    console.log(
      `[mcp-client] WARN: no .mcp.json found (searched up from ${searchedDir}, then ~/.pi/agent/.mcp.json) — running with ZERO MCP servers. Run pi-bootstrap/setup.sh to install the base config, or add a per-repo .mcp.json.`
    );
    return;
  }

  await manager.connectAllLayers(layers);
  await manager.registerTools(pi);
  // #199: catalog + on-demand load tools (also present in sub-agents).
  manager.registerLifecycleTools(pi);
  // #199: periodic idle sweep stops lazy servers past their idle timeout.
  manager.startIdleSweep();

  pi.on("session_shutdown", async () => {
    await manager.disconnectAll();
  });

  // #5672: suppress startup banner in print mode (task sub-agent output)
  if (!isPrintMode()) {
    console.log(`[mcp-client] MCP client extension loaded`);
  }
}
