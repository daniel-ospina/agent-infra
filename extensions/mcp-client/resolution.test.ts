/**
 * resolution.test.ts — .mcp.json resolution + base-config parsing for
 * extensions/mcp-client/index.ts (#104).
 *
 * Run: npx tsx extensions/mcp-client/resolution.test.ts  (from any agent-infra checkout)
 *
 * Uses real throwaway git repos + temp HOME dirs so the upward search and the
 * ~/.pi/agent fallback are exercised against genuine filesystem semantics.
 */
import { execSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  writeFileSync,
  rmSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ok, equal, deepEqual } from "node:assert/strict";

import { resolveMcpJsonPath, expandEnvVars } from "./index.js";

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

// ── Temp helpers ─────────────────────────────────────────────────────────
const TMP_DIRS: string[] = [];
function tempDir(prefix: string): string {
  const dir = mkdtempSync(join(tmpdir(), prefix));
  TMP_DIRS.push(dir);
  return dir;
}
function gitInit(dir: string) {
  execSync("git init -q", { cwd: dir });
}
function writeJson(dir: string, file: string, data: unknown) {
  writeFileSync(join(dir, file), JSON.stringify(data, null, 2));
}

// ── Tests ────────────────────────────────────────────────────────────────

section("resolveMcpJsonPath — upward search in a git repo");
await test("finds .mcp.json at git top-level from a nested subdir", () => {
  const repo = tempDir("mcp-resolve-repo-");
  gitInit(repo);
  writeJson(repo, ".mcp.json", { mcpServers: { rootServer: {} } });
  const sub = join(repo, "a", "b", "c");
  mkdirSync(sub, { recursive: true });

  const found = resolveMcpJsonPath(sub);
  ok(found, "expected a resolution");
  equal(found, join(repo, ".mcp.json"));
});

await test("nearest .mcp.json wins (subdir beats git top-level)", () => {
  const repo = tempDir("mcp-resolve-nested-");
  gitInit(repo);
  writeJson(repo, ".mcp.json", { mcpServers: { rootServer: {} } });
  const sub = join(repo, "pkg");
  mkdirSync(sub, { recursive: true });
  writeJson(sub, ".mcp.json", { mcpServers: { pkgServer: {} } });

  const found = resolveMcpJsonPath(sub);
  ok(found, "expected a resolution");
  equal(found, join(sub, ".mcp.json"));
});

await test("does not escape the git top-level (no stray parent pickup)", () => {
  const repo = tempDir("mcp-resolve-bound-");
  gitInit(repo);
  // Isolate HOME so a real ~/.pi/agent/.mcp.json (installed by setup.sh) can
  // never leak into this test — the walk must terminate at the git top-level.
  const fakeHome = tempDir("mcp-resolve-home-");
  const prevHome = process.env.HOME;
  process.env.HOME = fakeHome;
  try {
    // Put a decoy ABOVE the git top-level: it must NOT win.
    const parent = join(repo, "..");
    const decoy = join(parent, ".mcp.json");
    const hadDecoy = existsSync(decoy);
    if (!hadDecoy) writeJson(parent, ".mcp.json", { mcpServers: { decoy: {} } });
    const sub = join(repo, "deep");
    mkdirSync(sub, { recursive: true });

    const found = resolveMcpJsonPath(sub);
    // in-repo config (if any) OR nothing — never the decoy, never ~/.pi fallback
    ok(found === null || found.startsWith(repo), `resolved outside repo: ${found}`);
    if (!hadDecoy) rmSync(decoy, { force: true });
  } finally {
    process.env.HOME = prevHome;
    rmSync(fakeHome, { recursive: true, force: true });
  }
});

section("resolveMcpJsonPath — ~/.pi/agent fallback");
await test("falls back to ~/.pi/agent/.mcp.json when repo has no config", () => {
  const cwd = tempDir("mcp-resolve-noconfig-"); // not a git repo
  const fakeHome = tempDir("mcp-resolve-home-");
  const piAgent = join(fakeHome, ".pi", "agent");
  mkdirSync(piAgent, { recursive: true });
  writeJson(piAgent, ".mcp.json", { mcpServers: { baseServer: {} } });

  const origHome = process.env.HOME;
  try {
    process.env.HOME = fakeHome;
    const found = resolveMcpJsonPath(cwd);
    ok(found, "expected fallback resolution");
    equal(found, join(piAgent, ".mcp.json"));
  } finally {
    if (origHome === undefined) delete process.env.HOME;
    else process.env.HOME = origHome;
  }
});

await test("returns null when nothing exists anywhere", () => {
  const cwd = tempDir("mcp-resolve-none-"); // not a git repo
  const fakeHome = tempDir("mcp-resolve-nohome-"); // no .pi/agent/.mcp.json

  const origHome = process.env.HOME;
  try {
    process.env.HOME = fakeHome;
    equal(resolveMcpJsonPath(cwd), null);
  } finally {
    if (origHome === undefined) delete process.env.HOME;
    else process.env.HOME = origHome;
  }
});

section("templates/.mcp.base.json");
await test("parses as valid config with the expected server set", () => {
  const basePath = join(
    process.cwd(),
    "templates",
    ".mcp.base.json",
  );
  ok(existsSync(basePath), `missing ${basePath}`);
  const config = JSON.parse(readFileSync(basePath, "utf-8"));

  const expected = ["exa", "brave-search", "playwright-browser", "gemini", "tortoise"];
  deepEqual(Object.keys(config.mcpServers).sort(), [...expected].sort());

  const tortoise = config.mcpServers.tortoise;
  ok(tortoise.command === "python3", "tortoise uses local stdio spawn");
  ok(tortoise.cwd.includes("TORTOISE_HOME"), "tortoise cwd uses TORTOISE_HOME");
  ok(tortoise.env.PYTHONPATH.includes("TORTOISE_HOME"), "PYTHONPATH uses TORTOISE_HOME");
});

section("expandEnvVars — ${VAR} and ${VAR:-default}");
await test("plain ${VAR} expands from the environment", () => {
  const out = expandEnvVars({ a: "${HOME}/x" });
  equal(out.a, `${process.env.HOME}/x`);
});

await test("unset ${VAR} expands to empty string (backward compatible)", () => {
  delete process.env.MCP_TEST_UNSET;
  const out = expandEnvVars({ a: "${MCP_TEST_UNSET}" });
  equal(out.a, "");
});

await test("${VAR:-default} uses the default when unset", () => {
  delete process.env.MCP_TEST_UNSET;
  const out = expandEnvVars({ a: "${MCP_TEST_UNSET:-fallback}" });
  equal(out.a, "fallback");
});

await test("${VAR:-default} uses the env value when set", () => {
  process.env.MCP_TEST_SET = "real-value";
  const out = expandEnvVars({ a: "${MCP_TEST_SET:-fallback}" });
  equal(out.a, "real-value");
  delete process.env.MCP_TEST_SET;
});

await test("defaults support nested ${...} expansion", () => {
  delete process.env.TORTOISE_HOME;
  const out = expandEnvVars({
    cwd: "${TORTOISE_HOME:-${HOME}/Documents/GitHub/tortoise}",
  });
  equal(out.cwd, `${process.env.HOME}/Documents/GitHub/tortoise`);
});

// ── Cleanup + summary ────────────────────────────────────────────────────
for (const dir of TMP_DIRS) {
  try {
    rmSync(dir, { recursive: true, force: true });
  } catch {
    /* best-effort */
  }
}

console.log(`\n${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
