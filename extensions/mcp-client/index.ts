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
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

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
}

// ── MCP Server Manager ──────────────────────────────────────────────

/** Expand ${VAR} patterns in header values from environment */
function expandEnvVars(obj: Record<string, string>): Record<string, string> {
  const result: Record<string, string> = {};
  for (const [key, value] of Object.entries(obj)) {
    result[key] = value.replace(/\$\{([^}]+)\}/g, (_, name) => process.env[name] ?? "");
  }
  return result;
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
    // Clean up to avoid orphan processes (esp. for stdio transports that spawn child processes)
    try { await client.close(); } catch { /* best effort */ }
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

class McpServerManager {
  private connections: McpConnection[] = [];

  async connectAll(mcpJsonPath: string): Promise<void> {
    let config: McpJson;
    try {
      const raw = await readFile(mcpJsonPath, "utf-8");
      config = JSON.parse(raw);
    } catch {
      console.error(`[mcp-client] Could not read ${mcpJsonPath}, skipping MCP`);
      return;
    }

    const servers = config.mcpServers;
    if (!servers) {
      console.error("[mcp-client] No mcpServers in .mcp.json");
      return;
    }

    // Filter by PI_MCP_SERVERS env var if set
    const allowedServers = getAllowedServers();
    const serverEntries = Object.entries(servers).filter(([name]) =>
      !allowedServers || allowedServers.has(name)
    );

    if (allowedServers) {
      const skipped = Object.keys(servers).filter(s => !allowedServers.has(s));
      console.error(`[mcp-client] PI_MCP_SERVERS set → loading ${serverEntries.length} of ${Object.keys(servers).length} servers (skipped: ${skipped.join(", ")})`);
    }

    const CONNECTION_TIMEOUT_MS = 15000;

    // Connect to all servers in parallel with per-server timeout.
    // Track server names alongside results so error logs identify which server failed.
    const results = await Promise.allSettled(
      serverEntries.map(async ([serverName, serverConfig]) => {
        const startTime = Date.now();
        await this.connectServer(serverName, serverConfig, CONNECTION_TIMEOUT_MS);
        console.error(`[mcp-client] Connected to '${serverName}' (${Date.now() - startTime}ms)`);
        return serverName;
      })
    );

    let succeeded = 0;
    for (let i = 0; i < results.length; i++) {
      const result = results[i]!;
      if (result.status === "rejected") {
        // Use the server name from the input array at the same index
        const serverName = serverEntries[i]?.[0] ?? "unknown";
        console.error(
          `[mcp-client] Failed to connect to MCP server '${serverName}': ${result.reason?.message ?? result.reason}`
        );
      } else {
        succeeded++;
      }
    }
    console.error(`[mcp-client] Connected to ${succeeded}/${serverEntries.length} servers`);
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

    if (config.url) {
      // URL-based transport (e.g., Supabase MCP, remote servers)
      const headers = config.headers ? expandEnvVars(config.headers) : undefined;
      transport = new StreamableHTTPClientTransport(
        new URL(config.url),
        {
          requestInit: headers ? { headers } : undefined,
        }
      );
    } else if (config.command) {
      // Stdio transport (local process)
      const env = { ...process.env, ...(config.env ?? {}) };
      transport = new StdioClientTransport({
        command: config.command,
        args: config.args ?? [],
        env,
        cwd: config.cwd,
      });
    } else {
      throw new Error(
        `Server '${name}' has neither 'command' nor 'url'`
      );
    }

    // Connect with timeout
    await connectWithTimeout(name, client, transport, timeoutMs);

    this.connections.push({ client, serverName: name });
  }

  async registerTools(pi: ExtensionAPI): Promise<void> {
    // Dedup: skip tools already registered (e.g., from a prior session's stale state
    // or native pi registration). Prevents "Component already exists" warnings.
    // getAllTools() may throw during extension loading if the runtime isn't bound yet;
    // fall back to registering all tools in that case.
    let existingTools: Set<string>;
    try {
      existingTools = new Set(pi.getAllTools().map(t => t.name));
    } catch {
      existingTools = new Set();
    }

    for (const { client, serverName } of this.connections) {
      try {
        const { tools } = await client.listTools();
        for (const tool of tools) {
          const toolName = `mcp__${serverName}__${tool.name}`;
          const safeName = toolName.replace(/\./g, "_");

          if (existingTools.has(safeName)) {
            console.error(`[mcp-client] Skipped duplicate tool: ${safeName}`);
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
            async execute(
              _toolCallId,
              params: Record<string, unknown>
            ) {
              const startMs = Date.now();
              console.error(`[mcp-client] → ${serverName}/${tool.name}`);
              try {
                const result = await client.callTool({
                  name: tool.name,
                  arguments: params,
                }, undefined, { timeout: 3_600_000 });

                console.error(`[mcp-client] ← ${serverName}/${tool.name} (${Date.now() - startMs}ms)`);
                const textContent = result.content
                  .filter((c: any) => c.type === "text")
                  .map((c: any) => c.text)
                  .join("\n");

                return {
                  content: [
                    {
                      type: "text" as const,
                      text:
                        textContent || JSON.stringify(result.content),
                    },
                  ],
                  details: { serverName, toolName: tool.name },
                };
              } catch (err: any) {
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

          console.error(`[mcp-client] Registered tool: ${safeName}`);
        }
        console.error(
          `[mcp-client] Registered ${tools.length} tools from '${serverName}'`
        );
      } catch (err: any) {
        console.error(
          `[mcp-client] Failed to list tools from '${serverName}': ${err.message}`
        );
      }
    }
  }

  async disconnectAll(): Promise<void> {
    for (const { client, serverName } of this.connections) {
      try {
        await client.close();
        console.error(`[mcp-client] Disconnected from '${serverName}'`);
      } catch {
        // Best effort
      }
    }
    this.connections = [];
  }
}

// ── Extension Entry Point ───────────────────────────────────────────

export default async function (pi: ExtensionAPI) {
  const manager = new McpServerManager();
  const mcpJsonPath = resolve(process.cwd(), ".mcp.json");

  await manager.connectAll(mcpJsonPath);
  await manager.registerTools(pi);

  pi.on("session_shutdown", async () => {
    await manager.disconnectAll();
  });

  // #5672: suppress startup banner in print mode (task sub-agent output)
  if (process.env.PI_MODE !== 'print') {
    console.error(`[mcp-client] MCP client extension loaded`);
  }
}
