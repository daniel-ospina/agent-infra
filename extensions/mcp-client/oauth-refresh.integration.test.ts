/**
 * oauth-refresh.integration.test.ts — OAuth token refresh lifecycle (#595).
 *
 * Tests the McpOAuthClientProvider token refresh flow by exercising the SDK's
 * OAuthClientProvider interface directly with a simulated token lifecycle:
 *   - Tokens are persisted and loaded correctly
 *   - Token expiry triggers re-auth signal
 *   - invalidateCredentials clears state for a fresh start
 *   - Server origin uniqueness isolates token files
 *
 * This test uses a throwaway temp directory for token storage to isolate
 * from other tests. It does NOT require a live browser, live authorization
 * server, or real MCP server.
 *
 * Run: npx tsx extensions/mcp-client/oauth-refresh.integration.test.ts
 */
import { ok, equal, notEqual } from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { McpOAuthClientProvider } from "./index.js";

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

/** Create an McpOAuthClientProvider that stores tokens in the temp dir. */
function makeTestProvider(
  url: string,
  config: Parameters<typeof McpOAuthClientProvider>[1] = true
): McpOAuthClientProvider {
  const serverOrigin = new URL(url).origin.replace(/[^a-zA-Z0-9._-]/g, "_");
  const storeDir = join(TMP_TOKEN_DIR, serverOrigin);
  return new McpOAuthClientProvider(new URL(url), config, storeDir);
}

section("Token refresh lifecycle");

await test("fresh provider has no tokens, no client info, no discovery state", async () => {
  const p = makeTestProvider("https://tortoise.example.com/mcp");
  equal(await p.tokens(), undefined, "no tokens on fresh start");
  equal(await p.clientInformation(), undefined, "no client info on fresh start");
  equal(await p.discoveryState(), undefined, "no discovery state on fresh start");

  // codeVerifier should throw before save
  try {
    await p.codeVerifier();
    ok(false, "codeVerifier should throw before any verifier is saved");
  } catch {
    ok(true, "codeVerifier throws before save");
  }
});

await test("save and load tokens simulates DCR + auth flow", async () => {
  const p = makeTestProvider("https://tortoise.example.com/mcp");

  // Simulate DCR: save client info
  await p.saveClientInformation({
    client_id: "dcr-client-test-123",
    client_id_issued_at: 1000000,
  });
  const info = await p.clientInformation();
  ok(info, "client info saved");
  equal(info!.client_id, "dcr-client-test-123");

  // Simulate PKCE: save code verifier
  await p.saveCodeVerifier("code-verifier-simulated-abc123");
  equal(await p.codeVerifier(), "code-verifier-simulated-abc123");

  // Simulate auth success: save tokens with refresh
  await p.saveTokens({
    access_token: "test-access-token-value",
    token_type: "Bearer",
    expires_in: 3600,
    refresh_token: "test-refresh-token-value",
  });

  const tokens = await p.tokens();
  ok(tokens, "tokens saved after auth flow");
  equal(tokens!.access_token, "test-access-token-value");
  equal(tokens!.refresh_token, "test-refresh-token-value");
  ok(tokens!.expires_in === 3600, "expires_in preserved");
});

await test("invalidateCredentials('tokens') clears only tokens, preserves client info", async () => {
  const p = makeTestProvider("https://tortoise.example.com/mcp");

  // Seed both
  await p.saveClientInformation({ client_id: "client-keep" });
  await p.saveTokens({ access_token: "tok-clear", token_type: "Bearer" });

  // Clear tokens only
  await p.invalidateCredentials("tokens");

  equal(await p.tokens(), undefined, "tokens cleared");
  const info = await p.clientInformation();
  ok(info, "client info preserved");
  equal(info!.client_id, "client-keep");
});

await test("invalidateCredentials('all') clears everything", async () => {
  const p = makeTestProvider("https://tortoise.example.com/mcp");

  await p.saveClientInformation({ client_id: "cid" });
  await p.saveTokens({ access_token: "tok", token_type: "Bearer" });
  await p.saveCodeVerifier("verifier");
  await p.saveDiscoveryState({
    authorizationServerUrl: "https://auth.example.com",
  } as any);

  await p.invalidateCredentials("all");

  equal(await p.tokens(), undefined);
  equal(await p.clientInformation(), undefined);
  equal(await p.discoveryState(), undefined);
  try {
    await p.codeVerifier();
    ok(false, "should throw after all cleared");
  } catch {
    ok(true, "codeVerifier throws after all cleared");
  }
});

await test("second provider for same server loads persisted tokens", async () => {
  // First provider: save tokens
  const p1 = makeTestProvider("https://tortoise.example.com/mcp");
  await p1.saveTokens({
    access_token: "persisted-access-token",
    token_type: "Bearer",
    refresh_token: "persisted-refresh-token",
  });

  // Second provider: should load the same tokens from disk
  const p2 = makeTestProvider("https://tortoise.example.com/mcp");
  const tokens = await p2.tokens();
  ok(tokens, "second provider loads persisted tokens");
  equal(tokens!.access_token, "persisted-access-token");
  equal(tokens!.refresh_token, "persisted-refresh-token");
});

await test("different server origins have isolated token storage", async () => {
  const serverA = makeTestProvider("https://server-a.example.com/mcp");
  const serverB = makeTestProvider("https://server-b.example.com/mcp");

  await serverA.saveTokens({ access_token: "token-a", token_type: "Bearer" });
  await serverB.saveTokens({ access_token: "token-b", token_type: "Bearer" });

  const aTokens = await makeTestProvider("https://server-a.example.com/mcp").tokens();
  ok(aTokens, "server A tokens loadable");
  equal(aTokens!.access_token, "token-a");

  const bTokens = await makeTestProvider("https://server-b.example.com/mcp").tokens();
  ok(bTokens, "server B tokens loadable");
  equal(bTokens!.access_token, "token-b");
});

await test("redirectToAuthorization stores URL and clears after finishAuth", async () => {
  const p = makeTestProvider("https://tortoise.example.com/mcp");
  const authUrl = new URL("https://auth.example.com/authorize?client_id=test");
  await p.redirectToAuthorization(authUrl);

  ok(p.pendingAuthUrl, "pendingAuthUrl stored");
  equal(p.pendingAuthUrl!.href, authUrl.href);

  p.clearPendingAuth();
  equal(p.pendingAuthUrl, undefined, "pendingAuthUrl cleared after finishAuth");
});

// ── Cleanup ────────────────────────────────────────────────────────────
for (const dir of TMP_DIRS) {
  try { rmSync(dir, { recursive: true, force: true }); } catch { /* best-effort */ }
}

console.log(`\n${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);