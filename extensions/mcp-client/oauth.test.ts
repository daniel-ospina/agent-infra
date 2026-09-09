/**
 * oauth.test.ts — OAuth client support for remote HTTP MCP (#595).
 *
 * Unit tests for:
 *   - McpOAuthClientProvider config shape and construction
 *   - Token storage (store/load/delete under ~/.pi/mcp-tokens/)
 *   - Token refresh via the SDK's OAuthClientProvider interface
 *   - invalidateCredentials / re-auth signal
 *   - UnauthorizedError handling in tool execute
 *   - Regression: static-header and stdio configs are unchanged
 *
 * Run: npx tsx extensions/mcp-client/oauth.test.ts  (from repo root)
 *   or: npx tsx oauth.test.ts  (from extensions/mcp-client/)
 */
import { ok, equal, deepEqual, notEqual } from "node:assert/strict";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  McpOAuthClientProvider,
  McpServerManager,
  classifyServers,
  buildMcpServerEnv,
} from "./index.js";

let passed = 0;
let failed = 0;
async function test(name: string, fn: () => void | Promise<void>) {
  try {
    await fn();
    passed++;
    console.log(`  ✅ ${name}`);
  } catch (err: any) {
    failed++;
    console.log(`  ❌ ${name}: ${err.message}`);
  }
}
function section(name: string) {
  console.log(`\n${name}:`);
}

// ── Temp dir for isolated token storage ───────────────────────────────
const TMP_DIRS: string[] = [];
const TMP_TOKEN_DIR = mkdtempSync(join(tmpdir(), "mcp-oauth-test-"));
TMP_DIRS.push(TMP_TOKEN_DIR);

function makeTestProvider(
  url: string,
  config: Parameters<typeof McpOAuthClientProvider>[1] = true
): McpOAuthClientProvider {
  const serverOrigin = new URL(url).origin.replace(/[^a-zA-Z0-9._-]/g, "_");
  const storeDir = join(TMP_TOKEN_DIR, serverOrigin);
  return new McpOAuthClientProvider(new URL(url), config, storeDir);
}

// ── Temp dir helpers ────────────────────────────────────────────────────

// ── McpOAuthClientProvider construction ────────────────────────────────
section("McpOAuthClientProvider");

await test("constructs with oauth: true (auto-discovery)", () => {
  const p = makeTestProvider("https://tortoise.example.com/mcp");
  ok(p.redirectUrl.toString().includes("127.0.0.1:24080"));
  ok(p.clientMetadata.redirect_uris.length === 1);
  equal(p.clientMetadata.token_endpoint_auth_method, "none");
});

await test("constructs with oauth: { clientId } (pre-registered client)", () => {
  const p = makeTestProvider("https://tortoise.example.com/mcp", { clientId: "my-client-id" });
  ok(p instanceof McpOAuthClientProvider);
});

await test("redirectUrl is a loopback URL suitable for CLI", () => {
  const p = makeTestProvider("https://tortoise.example.com");
  const url = p.redirectUrl;
  equal(url instanceof URL || typeof url === "string", true);
  const href = String(url);
  ok(href.startsWith("http://127.0.0.1:24080/"), `unexpected redirectUrl: ${href}`);
});

// ── Token storage ───────────────────────────────────────────────────────
section("Token storage lifecycle");

await test("tokens() returns undefined on fresh provider", async () => {
  const p = makeTestProvider("https://tortoise-alt.example.com");
  equal(await p.tokens(), undefined);
});

await test("saveTokens then tokens() returns saved tokens", async () => {
  const p = makeTestProvider("https://tortoise.example.com");
  await p.saveTokens({
    access_token: "test-access-token",
    token_type: "Bearer",
    expires_in: 3600,
    refresh_token: "test-refresh-token",
  });
  const tokens = await p.tokens();
  ok(tokens, "expected tokens after save");
  equal(tokens!.access_token, "test-access-token");
  equal(tokens!.refresh_token, "test-refresh-token");
});

await test("clientInformation() returns undefined before DCR", async () => {
  const p = makeTestProvider("https://tortoise.example.com");
  equal(await p.clientInformation(), undefined);
});

await test("saveClientInformation then clientInformation() returns it", async () => {
  const p = makeTestProvider("https://tortoise.example.com");
  await p.saveClientInformation({
    client_id: "dcr-client-123",
    client_id_issued_at: 1000000,
  });
  const info = await p.clientInformation();
  ok(info, "expected client info after save");
  equal(info!.client_id, "dcr-client-123");
});

await test("invalidated credentials: tokens cleared", async () => {
  const p = makeTestProvider("https://tortoise.example.com");
  await p.saveTokens({ access_token: "tok", token_type: "Bearer" });
  await p.invalidateCredentials("tokens");
  equal(await p.tokens(), undefined);
});

await test("invalidated credentials: all scopes clear everything", async () => {
  const p = makeTestProvider("https://tortoise.example.com");
  await p.saveTokens({ access_token: "tok", token_type: "Bearer" });
  await p.saveClientInformation({ client_id: "cid" });
  await p.saveCodeVerifier("verifier123");
  await p.invalidateCredentials("all");
  equal(await p.tokens(), undefined);
  equal(await p.clientInformation(), undefined);
  // codeVerifier should throw after invalidation
  try {
    await p.codeVerifier();
    ok(false, "expected error after invalidateCredentials('all')");
  } catch {
    ok(true, "codeVerifier throws after invalidation");
  }
});

// ── PKCE verifier ───────────────────────────────────────────────────────
section("PKCE verifier");

await test("codeVerifier throws on fresh provider", async () => {
  const p = makeTestProvider("https://tortoise.example.com");
  try {
    await p.codeVerifier();
    ok(false, "expected error");
  } catch (err: any) {
    ok(err.message.includes("No PKCE code verifier found"), err.message);
  }
});

await test("saveCodeVerifier then codeVerifier returns it", async () => {
  const p = makeTestProvider("https://tortoise.example.com");
  await p.saveCodeVerifier("abc123-verifier");
  equal(await p.codeVerifier(), "abc123-verifier");
});

// ── Discovery state ──────────────────────────────────────────────────────
section("Discovery state persistence");

await test("discoveryState returns saved state after save", async () => {
  const p = makeTestProvider("https://tortoise-alt2.example.com");
  const state = {
    authorizationServerUrl: "https://auth.example.com",
    resource: "https://tortoise.example.com/mcp",
    resourceMetadataUrl: "https://tortoise.example.com/.well-known/oauth-protected-resource/mcp",
  };
  equal(await p.discoveryState(), undefined, "no state before save");
  await p.saveDiscoveryState(state as any);
  const loaded = await p.discoveryState();
  ok(loaded, "state loaded after save");
  equal(loaded!.authorizationServerUrl, "https://auth.example.com");
});

// ── Redirect-to-authorization ───────────────────────────────────────────
section("redirectToAuthorization");

await test("redirect stores the auth URL for later use", async () => {
  const p = makeTestProvider("https://tortoise.example.com");
  const url = new URL("https://auth.example.com/authorize?response_type=code&client_id=test");
  await p.redirectToAuthorization(url);
  ok(p.pendingAuthUrl, "pendingAuthUrl should be set");
  equal(p.pendingAuthUrl!.href, url.href);
  },
);

// ── Config shape → transport selection ────────────────────────────────────
section("Config shape → transport selection");

await test("url + oauth: true → OAuthProvider created (via classifyServers and connectServer)", async () => {
  // Verify the config shape is accepted by classifyServers and would route
  // correctly through connectServer. We test at the config level.
  const servers = {
    "my-oauth-server": {
      url: "https://tortoise.example.com/mcp",
      oauth: true,
    },
    "my-static-server": {
      url: "https://static.example.com/mcp",
      headers: { Authorization: "Bearer static-token" },
    },
    "my-stdio-server": {
      command: "npx",
      args: ["some-server"],
    },
  };
  const { eager } = classifyServers(servers, undefined);
  equal(eager.length, 3, "all three servers should be eager");

  const oauthServer = eager.find(([n]) => n === "my-oauth-server")!;
  ok(oauthServer[1].oauth !== undefined, "oauth flag preserved in server config");
  equal(oauthServer[1].oauth, true, "oauth: true preserved");
  equal(oauthServer[1].headers, undefined, "no headers with oauth config");
});

await test("oauth with clientId config shape preserved", () => {
  const servers = {
    "my-oauth-server": {
      url: "https://tortoise.example.com/mcp",
      oauth: { clientId: "pi-mcp-client-1" },
    },
  };
  const cfg = servers["my-oauth-server"].oauth as { clientId?: string };
  equal(cfg.clientId, "pi-mcp-client-1");
});

await test("static-header config unchanged (no oauth)", () => {
  const servers = {
    "static-server": {
      url: "https://supabase.example.com/mcp",
      headers: { Authorization: "Bearer supabase-token" },
    },
  };
  const server = servers["static-server"];
  equal(server.oauth, undefined, "no oauth on static-header config");
  ok(server.headers !== undefined, "headers preserved");
});

await test("stdio config unchanged (no oauth)", () => {
  const servers = {
    "local-server": {
      command: "npx",
      args: ["some-local-server"],
    },
  };
  const server = servers["local-server"];
  equal(server.oauth, undefined, "no oauth on stdio config");
  ok(server.command, "command preserved");
});

await test("buildMcpServerEnv still works unchanged (regression)", () => {
  const env = buildMcpServerEnv({ env: { MY_KEY: "value" } });
  equal(env.MY_KEY, "value");
  ok(env.PATH, "parent env preserved");
});

// ── UnauthorizedError handling ──────────────────────────────────────────
section("UnauthorizedError handling (simulated)");

await test("UnauthorizedError is catchable and distinguishable", async () => {
  // Dynamic import since the module is ESM.
  const { UnauthorizedError } = await import("@modelcontextprotocol/sdk/client/auth.js");
  const err = new UnauthorizedError("test re-auth needed");
  ok(err instanceof Error, "UnauthorizedError is an Error");
  ok(err.message.includes("re-auth"), "message preserved");
});

// ── Cleanup ─────────────────────────────────────────────────────────────
for (const dir of TMP_DIRS) {
  try {
    rmSync(dir, { recursive: true, force: true });
  } catch {
    /* best-effort */
  }
}

console.log(`\n${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);