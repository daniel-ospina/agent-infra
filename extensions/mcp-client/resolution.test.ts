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

import { resolveMcpJsonPath, resolveMcpConfigPaths, mergeMcpLayers, expandEnvVars, buildMcpServerEnv, McpServerManager } from "./index.js";

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

  // #1656: seo-intelligence is the research-ladder RUNG 1 server, added to the
  // base template after this suite was written; it is lazy (starts on demand).
  // `exa` was removed from the base template by owner ruling 2026-10-31 (never
  // wanted; external research is Perplexity), so it is not in `expected`.
  const expected = [
    "brave-search",
    "playwright-browser",
    "gemini",
    "seo-intelligence",
    "tortoise",
    // #3382 — the orchestrator MCP ships in the base so every repo receives it; it is lazy, and it
    // is an INTERNAL tool, which is precisely why it belongs here (machine-local, never shipped)
    // rather than in a product repo's tracked `.mcp.json`.
    "orchestrator",
  ];
  deepEqual(Object.keys(config.mcpServers).sort(), [...expected].sort());

  const tortoise = config.mcpServers.tortoise;
  // graph-mcp-provision: the base entry is the HOSTED server. It replaced the local stdio entry
  // (`${TORTOISE_HOME}/.venv/bin/python3 -m tortoise.mcp_server` + a local FalkorDB) because
  // pi-bootstrap/cell-install.sh could not install that shape on a cell at all — no checkout, no
  // venv, no local DB — so every cell lane ran with ZERO MCP servers. Asserted here so a revert to
  // stdio is caught by CI rather than by a fleet of lanes writing GRAPH-UNREACHABLE.
  equal(tortoise.type, "http", "tortoise is the hosted HTTP server");
  equal(tortoise.url, "https://api.premiselabs.co/mcp/", "tortoise points at the hosted endpoint");
  // ⛔ THE REPO'S OWN `.mcp.json` IS THE COPY THAT WINS the `tortoise` name for every agent-infra
  // lane: both layers are now read and MERGED (#3612), the repo's entry winning per field, so this
  // file — not the template — decides an agent-infra lane's `tortoise`; the template's copy is what a
  // repo WITHOUT this file receives. Its own `_comment` claims a
  // byte-identical shape to the template's — and NOTHING checked that, so a revert here would
  // return agent-infra lanes to the legacy server while `cell-install --verify` still certified the
  // base config. Asserted for the fields a lane actually needs.
  const repoConfig = JSON.parse(
    readFileSync(new URL("../../.mcp.json", import.meta.url), "utf8"),
  );
  const repoTortoise = repoConfig.mcpServers?.tortoise;
  ok(repoTortoise !== undefined, "the repo-root .mcp.json declares tortoise (the copy a lane resolves first)");
  for (const key of ["type", "url", "headers", "lazy", "timeoutMs"] as const) {
    equal(
      JSON.stringify(repoTortoise?.[key]),
      JSON.stringify(tortoise[key]),
      `the repo-root .mcp.json's tortoise.${key} matches the template (a revert here is invisible to --verify)`,
    );
  }

  ok(
    String(tortoise.headers?.Authorization ?? "").includes("${"),
    "tortoise auth is env-indirect — no key in a shared config file",
  );
  // ⛔ THE HEADER MUST NAME THE STANDARD VARIABLE. `TORTOISE_MCP_API_KEY` is the standard name
  // (`skills/research/SKILL.md`; #5153/#5343) and `TORTOISE_API_KEY` is the legacy alias, so an
  // entry expanding the legacy name goes EMPTY on the box the mandate was filed from — the owner's
  // finding on #3374, where the entry said one name and the docs told the operator to provision the
  // other. A revert to the legacy name is otherwise invisible: the header still contains `${`.
  ok(
    String(tortoise.headers?.Authorization ?? "").includes("${TORTOISE_MCP_API_KEY}"),
    "tortoise auth names the STANDARD variable ${TORTOISE_MCP_API_KEY} (the legacy TORTOISE_API_KEY would send an empty Bearer on this box)",
  );
  equal(tortoise.command, undefined, "tortoise is not the legacy stdio entry");

  // Tiering: everything is lazy now, `tortoise` included. The hosted server's cold handshake
  // exceeds pi's default connect budget, and this entry lands on memory-constrained cells where a
  // core server would block every session start.
  equal(config.mcpServers.tortoise.lazy, true, "tortoise is lazy (slow hosted handshake)");
  ok(config.mcpServers.tortoise.timeoutMs >= 30000, "tortoise carries a connect budget above the default");
  equal(config.mcpServers["playwright-browser"].lazy, true, "playwright is lazy");
  equal(config.mcpServers.gemini.lazy, true, "gemini is lazy");
  equal(config.mcpServers["brave-search"].lazy, true, "brave-search is lazy");
  equal(
    config.mcpServers["seo-intelligence"].lazy,
    true,
    "seo-intelligence is lazy (#1656 — research ladder starts on demand)",
  );
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

// ── #176: heartbeat nonce must never reach MCP servers ──────────────────
section("buildMcpServerEnv — heartbeat nonce scrub (#176)");

await test("TASK_HEARTBEAT_NONCE is scrubbed; other env + config.env preserved", () => {
  const prevNonce = process.env.TASK_HEARTBEAT_NONCE;
  const prevHb = process.env.TASK_HEARTBEAT;
  process.env.TASK_HEARTBEAT_NONCE = "secret-nonce-123";
  process.env.TASK_HEARTBEAT = "1";
  try {
    const env = buildMcpServerEnv({ env: { MY_SERVER_KEY: "abc" } });
    equal(env.TASK_HEARTBEAT_NONCE, undefined, "nonce must not reach MCP servers (they inherit the child's fd 2)");
    equal(env.TASK_HEARTBEAT, "1", "non-secret gate vars pass through harmlessly");
    equal(env.MY_SERVER_KEY, "abc", "config.env expansion preserved");
    equal(env.PATH, process.env.PATH, "parent env preserved");
  } finally {
    if (prevNonce === undefined) delete process.env.TASK_HEARTBEAT_NONCE;
    else process.env.TASK_HEARTBEAT_NONCE = prevNonce;
    if (prevHb === undefined) delete process.env.TASK_HEARTBEAT;
    else process.env.TASK_HEARTBEAT = prevHb;
  }
});

// ── (cleanup + summary moved to the end of this file: leaving the sweep here stranded every
//    fixture created by the tests below it — six-plus `mcp-layers-*` dirs leaked per run) ──


// ══════════════════════════════════════════════════════════════════════════════════════════════
// THE BASE IS A LAYER, NOT A FALLBACK. Measured 2026-11-06: `orchestrator` reached agent-infra
// (which has its own .mcp.json) and never tortoise, because the resolver returned the FIRST file it
// found and the hub's base was only a fallback — so a server added to the hub later was invisible to
// every repo that carries a local config. The only workaround was writing internal tooling into a
// TRACKED PRODUCT file, which is the hub/product confusion this fleet must not create.
// ══════════════════════════════════════════════════════════════════════════════════════════════
section("base layer + repo delta");

await test("BOTH layers resolve — a repo config does not hide the base", () => {
  const repo = tempDir("mcp-layers-both-");
  gitInit(repo);
  writeJson(repo, ".mcp.json", { mcpServers: { repoOnly: { command: "x" } } });
  const home = tempDir("mcp-layers-both-home-");
  mkdirSync(join(home, ".pi", "agent"), { recursive: true });
  writeJson(join(home, ".pi", "agent"), ".mcp.json", { mcpServers: { baseOnly: { command: "y" } } });

  const origHome = process.env.HOME;
  try {
    process.env.HOME = home;
    const layers = resolveMcpConfigPaths(repo);
    equal(layers.repo, join(repo, ".mcp.json"), "repo layer resolved");
    equal(layers.base, join(home, ".pi", "agent", ".mcp.json"),
      "base layer resolved TOO — this is the fix (it used to be a fallback only)");
  } finally {
    if (origHome === undefined) delete process.env.HOME;
    else process.env.HOME = origHome;
  }
});

await test("a repo entry of the SAME name wins; the base's other servers survive", () => {
  const merged = mergeMcpLayers(
    { mcpServers: { shared: { command: "base-cmd" }, onlyBase: { command: "b" } } } as never,
    { mcpServers: { shared: { command: "repo-cmd" } } } as never,
  );
  equal(merged.shared?.command, "repo-cmd", "the REPO entry wins a name collision");
  ok(merged.onlyBase, "and the base's other servers are not lost");
});

await test("PER FIELD: a `url`-changing override KEEPS lazy/timeoutMs but NEVER carries the base's credentials", () => {
  // The shape `docs/quickstart-selfhosted.md` tells a self-host user to write. `lazy` and `timeoutMs`
  // must be inherited (a name-level spread dropped them → an EAGER connect at every session start on
  // memory-constrained cells, the failure the base entry's own `_comment` records). The base's
  // `headers` must NOT be: `.mcp.json` is a TRACKED file, so inheriting a bearer token into a
  // repo-chosen URL hands the fleet's key to whatever that file names.
  const merged = mergeMcpLayers(
    {
      mcpServers: {
        tortoise: {
          type: "http",
          url: "https://api.premiselabs.co/mcp/",
          headers: { Authorization: "Bearer ${TORTOISE_MCP_API_KEY}" },
          lazy: true,
          timeoutMs: 60000,
        },
      },
    } as never,
    { mcpServers: { tortoise: { url: "http://localhost:8000/mcp" } } } as never,
  );
  const t = merged.tortoise as Record<string, unknown> | undefined;
  equal(t?.url, "http://localhost:8000/mcp", "the field the repo DID set wins");
  equal(t?.headers, undefined,
    "the base's Authorization header must NOT follow a repo to a new URL — restating it is the repo's call");
  equal(t?.lazy, true, "`lazy` is inherited — dropping it makes a hosted server EAGER on every cell");
  equal(t?.timeoutMs, 60000, "`timeoutMs` is inherited");
});

await test("a repo that restates `headers` alongside its own `url` gets exactly those headers", () => {
  const merged = mergeMcpLayers(
    { mcpServers: { tortoise: { url: "https://api.premiselabs.co/mcp/", headers: { Authorization: "Bearer ${TORTOISE_MCP_API_KEY}" } } } } as never,
    { mcpServers: { tortoise: { url: "https://self.example/mcp", headers: { Authorization: "Bearer ${LOCAL_KEY}" } } } } as never,
  );
  const t = merged.tortoise as Record<string, unknown> | undefined;
  deepEqual(t?.headers, { Authorization: "Bearer ${LOCAL_KEY}" }, "an explicit header wins outright");
});

await test("an UNCHANGED url still inherits the base's credentials (a pure delta keeps auth)", () => {
  const merged = mergeMcpLayers(
    { mcpServers: { tortoise: { url: "https://api.premiselabs.co/mcp/", headers: { Authorization: "Bearer K" }, lazy: true } } } as never,
    { mcpServers: { tortoise: { lazy: false } } } as never,
  );
  const t = merged.tortoise as Record<string, unknown> | undefined;
  equal(t?.lazy, false, "the repo's toggle wins");
  deepEqual(t?.headers, { Authorization: "Bearer K" },
    "the destination is unchanged, so the credentials issued for it still apply");
});

await test("TRANSPORT IS ATOMIC: a repo `command` drops the base's url AND its credentials", () => {
  // connectServer tests `url` BEFORE `command`, so a merged entry carrying both silently ignored the
  // repo's stdio daemon and kept talking to the base endpoint — with no warning.
  const merged = mergeMcpLayers(
    { mcpServers: { tortoise: { type: "http", url: "https://api.premiselabs.co/mcp/", headers: { Authorization: "Bearer K" }, lazy: true } } } as never,
    { mcpServers: { tortoise: { command: "/usr/bin/python3", args: ["-m", "tortoise.mcp_server"] } } } as never,
  );
  const t = merged.tortoise as Record<string, unknown> | undefined;
  equal(t?.command, "/usr/bin/python3", "the repo's transport is the one that runs");
  equal(t?.url, undefined, "the base url must not survive — it would win at connectServer's `if (config.url)`");
  equal(t?.headers, undefined, "nor may its credentials");
  equal(t?.lazy, true, "non-transport metadata is still inherited");
});

await test("TRANSPORT IS ATOMIC: a repo `url` drops the base's command/args/env/cwd", () => {
  const merged = mergeMcpLayers(
    { mcpServers: { t: { command: "/usr/bin/python3", args: ["-m", "x"], env: { SECRET: "s" }, cwd: "/tmp" } } } as never,
    { mcpServers: { t: { url: "https://self.example/mcp" } } } as never,
  );
  const entry = merged.t as Record<string, unknown> | undefined;
  equal(entry?.url, "https://self.example/mcp");
  for (const field of ["command", "args", "env", "cwd"]) {
    equal(entry?.[field], undefined, `stdio field ${field} must not survive an HTTP override`);
  }
});

await test("an entry declaring BOTH transports keeps the BASE entry — an ambiguous delta is not a removal", () => {
  // Dropping the merged entry removed the hub's memory graph from that repo, while the warning said
  // the entry was "ignored" and the documented invariant says a repo cannot REMOVE a base server.
  const merged = mergeMcpLayers(
    { mcpServers: { t: { url: "https://api.premiselabs.co/mcp/", lazy: true } } } as never,
    { mcpServers: { t: { url: "https://self.example/mcp", command: "/bin/sh" } } } as never,
  );
  const t = merged.t as Record<string, unknown> | undefined;
  ok(t, "the base server must SURVIVE an ambiguous repo entry");
  equal(t?.url, "https://api.premiselabs.co/mcp/", "and it is the BASE entry, untouched");
  equal(t?.command, undefined, "the ambiguous delta is not applied");
});

await test("a BASE entry declaring BOTH transports is dropped at the read, with a warning", async () => {
  // The docs promise an ambiguous entry is rejected — which was only true for a REPO entry: a base entry
  // declaring both was copied verbatim with no warning while connectServer silently used `url`.
  const repoDir = tempDir("mcp-bind-baseboth-repo-");
  const homeDir = tempDir("mcp-bind-baseboth-home-");
  mkdirSync(join(homeDir, ".pi", "agent"), { recursive: true });
  writeJson(repoDir, ".mcp.json", { mcpServers: {} });
  writeJson(join(homeDir, ".pi", "agent"), ".mcp.json", {
    mcpServers: {
      broken: { url: "https://x/mcp", command: "/bin/sh" },
      fine: { url: "https://ok.example/mcp", lazy: true },
    },
  });

  const manager = new McpServerManager();
  const logs = await withCapturedLogs(() =>
    manager.connectAllLayers({
      base: join(homeDir, ".pi", "agent", ".mcp.json"),
      repo: join(repoDir, ".mcp.json"),
    })
  );
  const cfg = (manager as unknown as { config: { mcpServers: Record<string, unknown> } }).config;
  ok(!("broken" in cfg.mcpServers), "an ambiguous BASE entry must be dropped, not silently resolved to `url`");
  ok(cfg.mcpServers.fine, "and a valid base entry still loads");
  ok(
    logs.some(l => l.includes("declares BOTH") && l.includes("base layer")),
    `the base layer must be named in the warning — got:\n${logs.join("\n")}`
  );
});

await test("a `type` that contradicts the declared transport keeps the BASE entry", () => {
  // `type` is the schema's transport selector, and connectServer dispatches on url/command — so
  // `{"type":"http","command":…}` would silently run over stdio.
  const merged = mergeMcpLayers(
    { mcpServers: { t: { url: "https://api.premiselabs.co/mcp/", lazy: true } } } as never,
    { mcpServers: { t: { type: "http", command: "/bin/sh" } } } as never,
  );
  const t = merged.t as Record<string, unknown> | undefined;
  equal(t?.url, "https://api.premiselabs.co/mcp/", "the base entry stands");
  equal(t?.command, undefined, "the contradictory delta is not applied");
});

await test("a NORMALISED restatement of the same url still inherits the base's credentials", () => {
  // Raw string equality stripped the credentials for a host-case or trailing-space difference, with
  // nothing logged — a bare 401 with no diagnostic.
  const merged = mergeMcpLayers(
    { mcpServers: { t: { url: "https://api.premiselabs.co/mcp/", headers: { Authorization: "Bearer K" } } } } as never,
    { mcpServers: { t: { url: "https://API.PREMISELABS.CO/mcp/" } } } as never,
  );
  const t = merged.t as Record<string, unknown> | undefined;
  deepEqual(t?.headers, { Authorization: "Bearer K" },
    "the same destination restated differently must keep its credentials — new URL().href normalises both");
});

await test("rewriting only `args` does NOT inherit the base's env — args decides what runs", () => {
  // `npx -y @good/mcp` and `npx -y @evil/mcp` share a command. Comparing `command` alone inherited the
  // base's API key into a repo-chosen package (measured).
  const merged = mergeMcpLayers(
    { mcpServers: { g: { command: "npx", args: ["-y", "@good/mcp"], env: { GEMINI_API_KEY: "k" } } } } as never,
    { mcpServers: { g: { args: ["-y", "@evil/mcp"] } } } as never,
  );
  const g = merged.g as Record<string, unknown> | undefined;
  deepEqual(g?.args, ["-y", "@evil/mcp"], "the repo's package runs");
  equal(g?.env, undefined, "but it must NOT receive the key that was issued for the other package");
});

await test("a repo that only touches `lazy` keeps the base's env (pure launch-identity delta)", () => {
  const merged = mergeMcpLayers(
    { mcpServers: { g: { command: "npx", args: ["-y", "@good/mcp"], env: { GEMINI_API_KEY: "k" }, lazy: true } } } as never,
    { mcpServers: { g: { lazy: false } } } as never,
  );
  const g = merged.g as Record<string, unknown> | undefined;
  equal(g?.lazy, false, "the toggle wins");
  deepEqual(g?.env, { GEMINI_API_KEY: "k" }, "same launch, so its env still applies");
});

await test("a `timeoutMs`-only override keeps EVERY field it did not set, so the server stays spawnable", () => {
  const merged = mergeMcpLayers(
    { mcpServers: { tortoise: { type: "http", url: "https://api.premiselabs.co/mcp/", headers: { Authorization: "Bearer K" }, timeoutMs: 60000 } } } as never,
    { mcpServers: { tortoise: { timeoutMs: 40000 } } } as never,
  );
  const t = merged.tortoise as Record<string, unknown> | undefined;
  equal(t?.timeoutMs, 40000, "the raised budget applies");
  equal(t?.url, "https://api.premiselabs.co/mcp/", "and the url survives — otherwise: neither 'command' nor 'url'");
  deepEqual(t?.headers, { Authorization: "Bearer K" }, "the destination is unchanged, so auth survives");
});

await test("a non-object server entry is dropped from EITHER layer, never handed to classifyServers", () => {
  const merged = mergeMcpLayers(
    { mcpServers: { tortoise: { url: "https://x/mcp" }, baseGhost: null } } as never,
    { mcpServers: { tortoise: null, ghost: 42 } } as never,
  );
  equal((merged.tortoise as Record<string, unknown> | undefined)?.url, "https://x/mcp",
    "a null override is not an override — the base entry stands, and nothing throws");
  ok(!("ghost" in merged), "a scalar entry from the repo layer is not a server");
  ok(!("baseGhost" in merged), "nor is one from the BASE layer — both loops are guarded");
});

await test("base ONLY still resolves (the old fallback path, preserved)", () => {
  const cwd = tempDir("mcp-layers-baseonly-");
  const home = tempDir("mcp-layers-baseonly-home-");
  mkdirSync(join(home, ".pi", "agent"), { recursive: true });
  writeJson(join(home, ".pi", "agent"), ".mcp.json", { mcpServers: { baseOnly: { command: "y" } } });

  const origHome = process.env.HOME;
  try {
    process.env.HOME = home;
    const layers = resolveMcpConfigPaths(cwd);
    equal(layers.repo, null, "no repo layer");
    equal(layers.base, join(home, ".pi", "agent", ".mcp.json"), "base layer resolved");
  } finally {
    if (origHome === undefined) delete process.env.HOME;
    else process.env.HOME = origHome;
  }
});

await test("neither layer → both null (nothing invented)", () => {
  const cwd = tempDir("mcp-layers-none-");
  const home = tempDir("mcp-layers-none-home-");
  const origHome = process.env.HOME;
  try {
    process.env.HOME = home;
    const layers = resolveMcpConfigPaths(cwd);
    equal(layers.repo, null, "no repo layer");
    equal(layers.base, null, "no base layer");
  } finally {
    if (origHome === undefined) delete process.env.HOME;
    else process.env.HOME = origHome;
  }
});

// ═════════════════════════════════════════════════════════════════════════════════════════════
// connectAllLayers — the BINDING, not just the merge function.
//
// `mergeMcpLayers`' ordering is pinned above, but that alone does not pin the CALL SITE: calling
// `mergeMcpLayers(repo, base)` — which re-introduces base-shadows-repo for every session — left this
// suite 16/16 green (measured in review, #3614). These drive the manager end to end. Every fixture
// server is `lazy: true`, so `classifyServers` skips it at startup and no process is ever spawned.
// ═════════════════════════════════════════════════════════════════════════════════════════════
section("connectAllLayers — the layer→argument binding and its failure modes");

/** Capture what the manager logs, so a WARN can be asserted rather than assumed. */
async function withCapturedLogs(fn: () => Promise<void>): Promise<string[]> {
  const lines: string[] = [];
  const orig = console.log;
  console.log = (...args: unknown[]) => {
    lines.push(args.map(String).join(" "));
  };
  try {
    await fn();
  } finally {
    console.log = orig;
  }
  return lines;
}

await test("BOTH layers merge at the CALL SITE — repo wins the collision, base's others survive", async () => {
  const repoDir = tempDir("mcp-bind-both-repo-");
  const homeDir = tempDir("mcp-bind-both-home-");
  mkdirSync(join(homeDir, ".pi", "agent"), { recursive: true });
  writeJson(repoDir, ".mcp.json", {
    mcpServers: { shared: { command: "repo-cmd", lazy: true }, repoOnly: { command: "r", lazy: true } },
  });
  writeJson(join(homeDir, ".pi", "agent"), ".mcp.json", {
    mcpServers: { shared: { command: "base-cmd", lazy: true }, baseOnly: { command: "b", lazy: true } },
  });

  const manager = new McpServerManager();
  await manager.connectAllLayers({
    base: join(homeDir, ".pi", "agent", ".mcp.json"),
    repo: join(repoDir, ".mcp.json"),
  });

  // Runtime read of a TS-private field: this asserts the config the session actually got, which is
  // the only thing that proves the ARGUMENT ORDER at the call site.
  const cfg = (manager as unknown as { config: { mcpServers: Record<string, { command?: string }> } }).config;
  equal(cfg.mcpServers.shared?.command, "repo-cmd", "the REPO entry wins — base must never shadow a repo");
  ok(cfg.mcpServers.baseOnly, "the base's non-colliding server survives");
  ok(cfg.mcpServers.repoOnly, "the repo's own server is present");
});

await test("an UNREADABLE repo layer keeps the base's servers AND says so, naming the repo layer", async () => {
  const repoDir = tempDir("mcp-bind-badrepo-repo-");
  const homeDir = tempDir("mcp-bind-badrepo-home-");
  mkdirSync(join(homeDir, ".pi", "agent"), { recursive: true });
  writeFileSync(join(repoDir, ".mcp.json"), '{ "mcpServers": { "shared": { "lazy": true }, } }'); // trailing comma
  writeJson(join(homeDir, ".pi", "agent"), ".mcp.json", {
    mcpServers: { baseOnly: { command: "b", lazy: true } },
  });

  const manager = new McpServerManager();
  const logs = await withCapturedLogs(() =>
    manager.connectAllLayers({
      base: join(homeDir, ".pi", "agent", ".mcp.json"),
      repo: join(repoDir, ".mcp.json"),
    })
  );

  const cfg = (manager as unknown as { config: { mcpServers: Record<string, unknown> } }).config;
  ok(cfg.mcpServers.baseOnly, "the base's servers are NOT taken away by a broken repo file");
  ok(
    logs.some(l => l.includes("WARN") && l.includes("repo layer") && l.includes("NOT in effect")),
    `a broken repo layer must be reported by NAME and by consequence — got:\n${logs.join("\n")}`
  );
  ok(
    logs.some(l => l.includes("layers in effect")) && !logs.some(l => l.includes("layers in effect: base + repo")),
    "the in-effect line must NOT claim the repo layer applied"
  );
});

await test("a repo layer that parses to `null` is a STATED failure, never a silent zero", async () => {
  const repoDir = tempDir("mcp-bind-nulljson-repo-");
  const homeDir = tempDir("mcp-bind-nulljson-home-");
  mkdirSync(join(homeDir, ".pi", "agent"), { recursive: true });
  writeFileSync(join(repoDir, ".mcp.json"), "null");
  writeJson(join(homeDir, ".pi", "agent"), ".mcp.json", {
    mcpServers: { baseOnly: { command: "b", lazy: true } },
  });

  const manager = new McpServerManager();
  const logs = await withCapturedLogs(() =>
    manager.connectAllLayers({
      base: join(homeDir, ".pi", "agent", ".mcp.json"),
      repo: join(repoDir, ".mcp.json"),
    })
  );

  ok(
    logs.some(l => l.includes("WARN") && l.includes("repo layer") && l.includes("NOT in effect")),
    `\`null\` is not a config — it must be reported, not read as an empty healthy layer — got:\n${logs.join("\n")}`
  );
});

await test("a non-string `url`/`command`, or an invalid `type`/name, is DROPPED at the layer read", async () => {
  // `connectServer` reads `if (config.url)` and would STRINGIFY a non-string into a real request; and
  // `sse` is rejected by pi (`docs/mcp.md`). A typo must not become a live destination.
  const repoDir = tempDir("mcp-bind-invalid-repo-");
  const homeDir = tempDir("mcp-bind-invalid-home-");
  mkdirSync(join(homeDir, ".pi", "agent"), { recursive: true });
  writeJson(repoDir, ".mcp.json", {
    mcpServers: {
      arrayUrl: { url: ["https://attacker.example/collect"] },
      arrayCommand: { command: ["/bin/sh", "-c", "x"] },
      sseType: { type: "sse", url: "https://x/mcp" },
      "bad name!": { url: "https://x/mcp" },
      keep: { url: "https://ok.example/mcp", lazy: true },
    },
  });
  writeJson(join(homeDir, ".pi", "agent"), ".mcp.json", { mcpServers: {} });

  const manager = new McpServerManager();
  const logs = await withCapturedLogs(() =>
    manager.connectAllLayers({
      base: join(homeDir, ".pi", "agent", ".mcp.json"),
      repo: join(repoDir, ".mcp.json"),
    })
  );

  const cfg = (manager as unknown as { config: { mcpServers: Record<string, unknown> } }).config;
  ok(cfg.mcpServers.keep, "a valid entry still loads");
  for (const bad of ["arrayUrl", "arrayCommand", "sseType", "bad name!"]) {
    ok(!(bad in cfg.mcpServers), `\`${bad}\` must be dropped, not stringified into a live request`);
  }
  ok(
    logs.some(l => l.includes("non-string")) && logs.some(l => l.includes("type")) &&
      logs.some(l => l.includes("not a valid server name")),
    `each rejection must name its reason — got:\n${logs.join("\n")}`
  );
});

await test("a NON-STRING `url` still drops the base credentials in the merge (presence, not string-ness)", () => {
  // Defence in depth for a caller that hands the merge raw JSON without `asMcpJson`'s validation:
  // `connectServer` would STRINGIFY `["https://attacker/…"]` into a real request, so a guard keyed on
  // "is `url` a non-empty string?" would silently keep the bearer token.
  const merged = mergeMcpLayers(
    { mcpServers: { t: { url: "https://api.premiselabs.co/mcp/", headers: { Authorization: "Bearer K" }, oauth: true } } } as never,
    { mcpServers: { t: { url: ["https://attacker.example/collect"] } } } as never,
  );
  const t = merged.t as Record<string, unknown> | undefined;
  equal(t?.headers, undefined, "the base's Authorization header must not follow a non-string url");
  equal(t?.oauth, undefined, "nor its oauth config");

  // Symmetric on the stdio side: a non-string `command` is still a CHANGED launch.
  const stdio = mergeMcpLayers(
    { mcpServers: { g: { command: "npx", args: ["-y", "@good/mcp"], env: { K: "1" } } } } as never,
    { mcpServers: { g: { command: ["/bin/sh", "-c", "x"] } } } as never,
  );
  equal((stdio.g as Record<string, unknown> | undefined)?.env, undefined,
    "the base's env must not follow a non-string command");
});

await test("a `__proto__` key cannot poison the merged map's prototype", () => {
  // Measured before the fix: the merged map's PROTOTYPE became the repo's entry object, and
  // `loadServer` (resolving `mcpServers[name]`) could reach a server `catalog()` never listed.
  const merged = mergeMcpLayers(
    { mcpServers: { real: { url: "https://ok/mcp" } } } as never,
    JSON.parse('{"mcpServers":{"__proto__":{"hidden":{"command":"/bin/sh"}}}}') as never,
  );
  equal(Object.getPrototypeOf(merged), null, "the map must have a null prototype");
  equal((merged as Record<string, unknown>).hidden, undefined, "nothing may be reached by prototype");
  ok(merged.real, "and ordinary servers still merge");
});

await test("a `type`-only delta on a stdio base is REFUSED (the check runs on the EFFECTIVE entry)", () => {
  // Checking the delta alone let `{"type": "http"}` be applied to a stdio base, producing exactly the
  // incoherent entry the check exists to reject.
  const merged = mergeMcpLayers(
    { mcpServers: { g: { command: "npx", args: ["-y", "@good/mcp"], lazy: true } } } as never,
    { mcpServers: { g: { type: "http" } } } as never,
  );
  const g = merged.g as Record<string, unknown> | undefined;
  equal(g?.type, undefined, "the contradictory type is not applied");
  equal(g?.command, "npx", "and the base entry is kept intact");
});

await test("`args: []` vs absent `args` is the SAME launch, so the base's env survives", () => {
  // `connectServer` does `config.args ?? []`, so these spawn identically — comparing them as different
  // dropped the credentials for a no-op restatement.
  const merged = mergeMcpLayers(
    { mcpServers: { g: { command: "npx", env: { K: "1" } } } } as never,
    { mcpServers: { g: { args: [] } } } as never,
  );
  const g = merged.g as Record<string, unknown> | undefined;
  deepEqual(g?.env, { K: "1" }, "an empty args list is not a different launch");
});

await test("`connectAll` funnels through the sanitiser: no crash, clean stored config, clean catalog", async () => {
  // `connectAll` is a public method on an exported class and is the pattern two suites follow; it hands
  // raw `JSON.parse` output straight to connectConfig, bypassing asMcpJson and mergeMcpLayers.
  const dir = tempDir("mcp-bind-legacy-");
  const file = join(dir, ".mcp.json");
  writeFileSync(file, JSON.stringify({ mcpServers: { tortoise: null, ghost: 42, real: { url: "https://ok.example/mcp", lazy: true } } }));

  const manager = new McpServerManager();
  // ⛔ CLEAR `PI_MCP_SERVERS` FIRST. When it is set, `classifyServers` excludes an unlisted name
  // BEFORE it reads `cfg.lazy` — so this test passed vacuously on any box with that variable exported
  // (measured) while still crashing the moment it is unset, which is the CI shape.
  const prevAllowed = process.env.PI_MCP_SERVERS;
  delete process.env.PI_MCP_SERVERS;
  try {
    await withCapturedLogs(() => manager.connectAll(file)); // must not throw
  } finally {
    if (prevAllowed === undefined) delete process.env.PI_MCP_SERVERS;
    else process.env.PI_MCP_SERVERS = prevAllowed;
  }
  ok(true, "a non-object entry no longer throws out of the extension factory");
  // ⛔ PIN THE FUNNEL ITSELF. `connectConfig` sanitises once so EVERY reader is safe; without this
  // assertion that mechanism can be deleted silently, because classifyServers and catalog() each guard
  // independently — and the next reader added to `this.config` would resurrect the crash.
  const stored = (manager as unknown as { config: { mcpServers: Record<string, unknown> } }).config
    .mcpServers;
  ok(
    !Object.hasOwn(stored, "tortoise") && !Object.hasOwn(stored, "ghost"),
    "the stored config itself must be clean — the funnel, not just the readers, drops invalid entries"
  );
  equal(Object.getPrototypeOf(stored), null, "and it is a null-prototype map");
  // `mcp_catalog` is the tool every error message tells the operator to run, and it reads `cfg.lazy`.
  // Before the sanitise-once fix the crash simply MOVED here.
  const entries = manager.catalog();
  ok(
    entries.every(e => e.name !== "tortoise" && e.name !== "ghost"),
    "invalid entries are absent from the catalog"
  );
  ok(
    entries.some(e => e.name === "real"),
    "and the valid one is still listed — catalog() must not be the tool that throws"
  );
});

await test("`catalog()` survives a manager whose config was assigned directly", () => {
  // `this.config` is sanitised by connectConfig, but a caller (or a test) can assign it directly — and
  // `catalog()` is the tool every error message tells the operator to run, so it must not throw.
  const manager = new McpServerManager();
  (manager as unknown as { config: unknown }).config = {
    mcpServers: { bad: null, ghost: 42, real: { url: "https://ok.example/mcp", lazy: true } },
  };
  const entries = manager.catalog();
  ok(entries.some(e => e.name === "real"), "the valid entry is listed");
  ok(entries.every(e => e.name !== "bad" && e.name !== "ghost"), "invalid entries are skipped");
});

await test("prototype-shaped server names are rejected (the second lock, not the first)", () => {
  const merged = mergeMcpLayers(
    { mcpServers: { real: { url: "https://ok/mcp" } } } as never,
    JSON.parse(
      '{"mcpServers":{"__proto__":{"command":"/bin/sh"},"constructor":{"command":"/bin/sh"},"prototype":{"command":"/bin/sh"}}}'
    ) as never,
  );
  equal(Object.getPrototypeOf(merged), null, "the map stays null-prototype");
  for (const bad of ["__proto__", "constructor", "prototype"]) {
    ok(!Object.hasOwn(merged, bad), `\`${bad}\` must not become a server`);
  }
  ok(merged.real, "a normal server still merges");
});

await test("a `null` server ENTRY does not crash the session — it is dropped, with a warning", async () => {
  // `{"mcpServers": {"tortoise": null}}` used to pass asMcpJson and then throw
  // `TypeError: Cannot read properties of null (reading 'lazy')` out of the extension factory,
  // ending the session with no file, entry or cause named.
  const repoDir = tempDir("mcp-bind-nullentry-repo-");
  const homeDir = tempDir("mcp-bind-nullentry-home-");
  mkdirSync(join(homeDir, ".pi", "agent"), { recursive: true });
  writeJson(repoDir, ".mcp.json", { mcpServers: { tortoise: null, ghost: 42 } });
  writeJson(join(homeDir, ".pi", "agent"), ".mcp.json", {
    mcpServers: { tortoise: { type: "http", url: "https://api.premiselabs.co/mcp/", lazy: true } },
  });

  const manager = new McpServerManager();
  const logs = await withCapturedLogs(() =>
    manager.connectAllLayers({
      base: join(homeDir, ".pi", "agent", ".mcp.json"),
      repo: join(repoDir, ".mcp.json"),
    })
  );

  const cfg = (manager as unknown as { config: { mcpServers: Record<string, unknown> } }).config;
  ok(cfg.mcpServers.tortoise, "the base's entry still applies — `null` is not a removal");
  ok(!("ghost" in cfg.mcpServers), "a scalar entry is not a server");
  ok(
    logs.some(l => l.includes("WARN") && l.includes('entry "tortoise"') && l.includes("dropped")),
    `a dropped entry must be named, and say removal is impossible — got:\n${logs.join("\n")}`
  );
});

await test("a layer with NO `mcpServers` key is a valid layer — its top-level keys survive", async () => {
  // Rejecting it dropped the whole file: its keys vanished and the log called a valid config
  // unusable. A layer that declares no servers is not a broken layer.
  const repoDir = tempDir("mcp-bind-noservers-repo-");
  const homeDir = tempDir("mcp-bind-noservers-home-");
  mkdirSync(join(homeDir, ".pi", "agent"), { recursive: true });
  writeJson(repoDir, ".mcp.json", { autoEnableCodemode: false, _comment: "no servers here" });
  writeJson(join(homeDir, ".pi", "agent"), ".mcp.json", {
    mcpServers: { baseOnly: { command: "b", lazy: true } },
  });

  const manager = new McpServerManager();
  const logs = await withCapturedLogs(() =>
    manager.connectAllLayers({
      base: join(homeDir, ".pi", "agent", ".mcp.json"),
      repo: join(repoDir, ".mcp.json"),
    })
  );

  const cfg = (manager as unknown as { config: Record<string, unknown> }).config;
  equal(cfg.autoEnableCodemode, false, "a repo layer's top-level key must not be amputated");
  ok(
    (cfg.mcpServers as Record<string, unknown>).baseOnly,
    "and the base's servers still apply"
  );
  ok(
    !logs.some(l => l.includes("WARN") && l.includes("repo layer")),
    `a layer that simply declares no servers must not be reported as broken — got:\n${logs.join("\n")}`
  );
});

await test("non-`mcpServers` top-level keys survive from BOTH layers (base is not amputated)", async () => {
  const repoDir = tempDir("mcp-bind-toplevel-repo-");
  const homeDir = tempDir("mcp-bind-toplevel-home-");
  mkdirSync(join(homeDir, ".pi", "agent"), { recursive: true });
  writeJson(repoDir, ".mcp.json", { mcpServers: {}, baseDialect: "repo-wins" });
  writeJson(join(homeDir, ".pi", "agent"), ".mcp.json", {
    mcpServers: { baseOnly: { command: "b", lazy: true } },
    futureKey: "from-base",
  });

  const manager = new McpServerManager();
  await manager.connectAllLayers({
    base: join(homeDir, ".pi", "agent", ".mcp.json"),
    repo: join(repoDir, ".mcp.json"),
  });

  const cfg = (manager as unknown as { config: Record<string, unknown> }).config;
  equal(cfg.futureKey, "from-base", "a base-only top-level key must not vanish because a repo file exists");
  equal(cfg.baseDialect, "repo-wins", "the repo still wins on a top-level collision");
});

// ── Cleanup + summary (LAST — after every fixture is created) ────────────
for (const dir of TMP_DIRS) {
  try {
    rmSync(dir, { recursive: true, force: true });
  } catch {
    /* best-effort */
  }
}

console.log(`\n${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
