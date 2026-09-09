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
 * Resolve the .mcp.json path for the current session (#104).
 *
 * Resolution order:
 *  1. Walk UP from `startDir` (default process.cwd()), stopping at the git
 *     top-level when one is resolvable (same `git rev-parse --show-toplevel`
 *     logic as reflect-hook / main-worktree-guard). Non-git directories walk
 *     to the filesystem root. First `.mcp.json` found wins — this lets a
 *     per-repo config override the base config.
 *  2. Fallback: `~/.pi/agent/.mcp.json` (the bootstrapped base config
 *     installed by pi-bootstrap/setup.sh from templates/.mcp.base.json).
 *  3. null → no config anywhere; the caller logs a clear zero-servers message.
 *
 * Exported (named) for unit tests; the default export stays the extension hook.
 */
export function resolveMcpJsonPath(startDir: string = process.cwd()): string | null {
  let topLevel: string | null = null;
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
    if (existsSync(candidate)) return candidate;
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

  // Fallback: bootstrapped base config.
  const homeFallback = join(homedir(), ".pi", "agent", ".mcp.json");
  return existsSync(homeFallback) ? homeFallback : null;
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
    this.config = config;

    const servers = config.mcpServers;
    if (!servers) {
      console.log("[mcp-client] No mcpServers in .mcp.json");
      return;
    }

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
    // Track server names alongside results so error logs identify which server failed.
    const results = await Promise.allSettled(
      eager.map(async ([serverName, serverConfig]) => {
        const startTime = Date.now();
        const timeoutMs = serverConfig.timeoutMs ?? DEFAULT_CONNECTION_TIMEOUT_MS;
        await this.connectServer(serverName, serverConfig, timeoutMs);
        console.log(`[mcp-client] Connected to '${serverName}' (${Date.now() - startTime}ms)`);
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
        console.log(
          `[mcp-client] MCP server '${serverName}' unavailable — continuing without it`
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
    return Object.entries(this.config.mcpServers).map(([name, cfg]) => {
      const lazy = cfg.lazy === true;
      const loaded = this.findConnection(name) !== undefined;
      return {
        name,
        tier: lazy ? "lazy" : "core",
        status: loaded ? "loaded" : lazy ? "sleeping" : "not-loaded",
        purpose: cfg.purpose ?? "",
        whenToLoad: cfg.whenToLoad ?? "",
        cost: cfg.cost ?? "",
      };
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

  // #104: resolve .mcp.json with an upward search (cwd → git top-level) and
  // a ~/.pi/agent/.mcp.json fallback, instead of cwd-only. Log the search
  // path at warn level so a zero-server session is diagnosable at a glance.
  const searchedDir = process.cwd();
  const mcpJsonPath = resolveMcpJsonPath(searchedDir);
  if (mcpJsonPath) {
    console.log(
      `[mcp-client] Resolved .mcp.json: ${mcpJsonPath} (searched up from ${searchedDir} incl. ~/.pi/agent fallback)`
    );
  } else {
    console.log(
      `[mcp-client] WARN: no .mcp.json found (searched up from ${searchedDir}, then ~/.pi/agent/.mcp.json) — running with ZERO MCP servers. Run pi-bootstrap/setup.sh to install the base config, or add a per-repo .mcp.json.`
    );
    return;
  }

  await manager.connectAll(mcpJsonPath);
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
