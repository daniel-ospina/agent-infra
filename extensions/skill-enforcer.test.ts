/**
 * skill-enforcer.test.ts — #1321 (deployed-layout manifest enforcement) and
 * #1322 (layout-independent read identity), plus the duplicate-line and
 * nudge-mode defects the plan review found inside the same fail-open class.
 *
 * Run: npx tsx extensions/skill-enforcer.test.ts   (from any agent-infra checkout)
 *
 * Zero-dep by construction: `skill-enforcer.ts` has no runtime import outside
 * `node:*` and `./shared/*` (the pi SDK value import is inlined — see the file
 * header), so this suite runs on a bare checkout with no `npm ci`.
 *
 * ── Fixture honesty (read before trusting a green run) ───────────────────────
 * pi loads extensions with **jiti**, which keeps the SYMLINK path in
 * `__dirname` (the #1321 mechanism). CI has no jiti, so the child fixtures run
 * the same shape through `tsx` with `NODE_OPTIONS=--preserve-symlinks`, which
 * reproduces the identical `__dirname` semantics. That claim is not assumed:
 * every symlink leg asserts a **loader precondition** first — a probe symlinked
 * into the farm must report `__dirname` = the FARM directory while
 * `realpathSync(__filename)` is the real file. If a tsx/Node upgrade starts
 * realpathing, the precondition fails with a clear message instead of the test
 * passing vacuously. A real jiti leg runs when jiti is resolvable (this fleet
 * workstation) and reports as skipped otherwise.
 */
import { ok, equal, deepEqual } from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, symlinkSync, copyFileSync, linkSync, existsSync, realpathSync, readdirSync } from "node:fs";
import { tmpdir, homedir } from "node:os";
import { join, resolve, dirname } from "node:path";
import { spawnSync } from "node:child_process";

import hook, {
  loadManifest,
  manifestBanner,
  manifestCounts,
  MANIFEST_LOAD,
  MANIFEST_PATH,
  MANIFEST_RULES,
  MANIFEST_RESOLUTION,
  MODULE_DIR,
  REPO_DIR,
  canonicalSkillName,
  canonicalSkillFile,
  canonicalSkillsRoot,
  CANONICAL_FARM_ERROR,
  skillRoots,
  skillDisplayPath,
  skillFileFor,
  resolveManifestPath,
  _setSkillReadsFileForTest,
  _setManifestForTest,
} from "./skill-enforcer.js";

const REPO_ROOT = resolve(__dirname, "..");
const REAL_MANIFEST = join(REPO_ROOT, "enforcement", "dangerous-ops.txt");

let passed = 0;
let failed = 0;
const failures: string[] = [];
async function test(name: string, fn: () => void | Promise<void>) {
  try {
    await fn();
    passed += 1;
    console.log(`  ✅ ${name}`);
  } catch (err) {
    failed += 1;
    failures.push(name);
    console.log(`  ❌ ${name}\n     ${err instanceof Error ? err.message : String(err)}`);
  }
}
function section(name: string) {
  console.log(`\n${name}`);
}

const TMP: string[] = [];
function tmpDir(prefix: string): string {
  const d = realpathSync(mkdtempSync(join(tmpdir(), prefix)));
  TMP.push(d);
  return d;
}
function cleanup() {
  // Restore the real HOME BEFORE removing the fixture, so nothing post-exit
  // resolves `~/.pi` into a directory that is about to disappear.
  if (FIXTURE_HOME) process.env.HOME = REAL_HOME;
  for (const d of TMP) rmSync(d, { recursive: true, force: true });
}

// ── fake pi host ─────────────────────────────────────
type Handler = (event: unknown, ctx: unknown) => unknown;
interface FakePi {
  on(name: string, fn: Handler): void;
  fire(name: string, event: unknown): Promise<any>;
}
function makePi(): FakePi {
  const handlers: Record<string, Handler[]> = {};
  return {
    on(name: string, fn: Handler) {
      (handlers[name] ??= []).push(fn);
    },
    async fire(name: string, event: unknown) {
      let last: unknown;
      for (const fn of handlers[name] ?? []) {
        const res = await fn(event, {});
        if (res && (res as { block?: boolean }).block) return res;
        if (res) last = res;
      }
      return last;
    },
  };
}

// ── env hygiene (T12) ────────────────────────────────
// The ambient fleet shell really does carry SKILL_ENFORCER_DISABLED=1 and
// PI_MODE=print, and AGENT_INFRA_PATH here points at a DIFFERENT checkout than
// this module's realpath. A control that inherits those passes vacuously.
function scrubBypassEnv() {
  delete process.env.SKILL_ENFORCER_DISABLED;
  delete process.env.AGENT_ALLOW_MAIN_EDITS;
  delete process.env.ELDATO_ALLOW_MAIN_EDITS;
  delete process.env.AGENT_SKILLS_PREFIX;
  delete process.env.ELDATO_SKILLS_PREFIX;
}

// A fresh handler set, a fresh reads file, and a session that has started.
async function newSession(): Promise<{ pi: FakePi; reads: string }> {
  scrubBypassEnv();
  const reads = join(tmpDir("se-reads-"), "skill-reads.json");
  _setSkillReadsFileForTest(reads);
  const pi = makePi();
  hook(pi as never);
  await pi.fire("session_start", {});
  return { pi, reads };
}

function persistedNames(reads: string): string[] {
  if (!existsSync(reads)) return [];
  const parsed = JSON.parse(readFileSync(reads, "utf-8")) as Array<{ file: string }>;
  return parsed.map(e => e.file).sort();
}

const COMMIT = { toolName: "bash", input: { command: "git commit -m x" } };
const TORTOISE_SEARCH = { toolName: "mcp__tortoise__tortoise_search", input: {} };
const TORTOISE_WRITE = { toolName: "mcp__tortoise__tortoise_create_point", input: {} };

// ── fixtures ─────────────────────────────────────────
const PI_STUB_PKG = "@earendil-works/pi-coding-agent";

// Seam for RE-DERIVING THE RED without mutating this checkout — the
// working-tree-discard guard (#709) rightly blocks reverting a tracked file in
// place, so the pre-fix module is fed in from outside instead:
//   git show HEAD:extensions/skill-enforcer.ts > /tmp/pre-fix.ts
//   SE_TEST_MODULE_SRC=/tmp/pre-fix.ts npx tsx extensions/skill-enforcer.test.ts
// Sections A-F still exercise THIS checkout's module (in-process import); only
// section G (the deployed-layout leg) swaps, which is exactly the defect.
const EXT_SRC = process.env.SE_TEST_MODULE_SRC ?? join(REPO_ROOT, "extensions", "skill-enforcer.ts");
const WORKTREE_CMD = "git worktree add /tmp/se-probe";

// ── Hermetic DEPLOYED layout (#1327) ─────────────────
// The suite must run against the provenance model, which means a REAL skill
// file must be reachable through the path pi serves. Rather than write into the
// developer's `~/.pi` (forbidden — see the hermeticity leg), `main()` swaps
// `process.env.HOME` to a fixture before the first session and gives it the
// deployed shape: `~/.pi/agent/skills` as a real directory of per-skill symlinks
// into the canonical farm. That is also the shape that lets a leg plant a
// forgery NEXT TO the real skill, which is #1327 in the deployed layout.
const REAL_HOME = homedir();
/** The developer's OWN reader cache — the child runs must never touch it. */
const REAL_READS_FILE = join(REAL_HOME, ".pi", "agent", "skill-reads.json");
let FIXTURE_HOME = "";
let PI_SKILLS = "";
let WORKTREE_SKILL = "";
/** Skills the suite's fixture HOME serves, beyond the ones it plants per leg. */
const FIXTURE_SKILLS = ["commit-workflow", "using-git-worktrees", "issue-scoping", "how-to-use-tortoise"];

/** Materialise a skill under `<base>/<shape>/<name>/SKILL.md`. `forged` writes
 *  content the canonical farm does not have — the #1327 forgery. `copy` is
 *  byte-identical but a DIFFERENT inode (the sync.sh folder-copy machine). */
function plantSkill(
  base: string,
  shape: string,
  name: string,
  mode: "forged" | "copy" | "hardlink" | "dir-symlink",
): string {
  const dir = join(base, ...shape.split("/"), name);
  const canonical = join(REPO_ROOT, "skills", name, "SKILL.md");
  if (mode === "dir-symlink") {
    mkdirSync(dirname(dir), { recursive: true });
    symlinkSync(join(REPO_ROOT, "skills", name), dir, "dir");
    return join(dir, "SKILL.md");
  }
  mkdirSync(dir, { recursive: true });
  const file = join(dir, "SKILL.md");
  if (mode === "forged") writeFileSync(file, "anything at all\n");
  else if (mode === "copy") copyFileSync(canonical, file);
  else {
    try {
      linkSync(canonical, file);
    } catch (err) {
      // A hard link is the documented consumer layout (scripts/link-skills.sh),
      // but it cannot cross filesystems: where `tmpdir()` is its own mount the
      // link is EXDEV. Fall back to the byte-identical copy — the SAME
      // acceptance property via the other identity branch (the inode branch is
      // separately exercised by the dir-symlink legs, where `statSync` follows
      // to the canonical inode). Anything other than EXDEV is a real error.
      if ((err as NodeJS.ErrnoException).code !== "EXDEV") throw err;
      copyFileSync(canonical, file);
    }
  }
  return file;
}

/** Run `fn` with `process.cwd()` at `dir` — `skillRoots()` reads cwd per call. */
async function inDir<T>(dir: string, fn: () => T | Promise<T>): Promise<T> {
  const prev = process.cwd();
  process.chdir(dir);
  try { return await fn(); } finally { process.chdir(prev); }
}

/**
 * A `~/.pi/agent/extensions`-shaped farm. `kind` decides whether the extension
 * is a SYMLINK to `EXT_SRC` (the deployed layout, #1321) or a COPY (which
 * exercises the env-fallback resolution path, T9).
 */
function makeFarm(kind: "symlink" | "copy"): { root: string; driver: string } {
  const root = tmpDir(`se-farm-${kind}-`);
  const ext = join(root, "extensions");
  mkdirSync(ext, { recursive: true });
  if (kind === "symlink") symlinkSync(EXT_SRC, join(ext, "skill-enforcer.ts"));
  else copyFileSync(EXT_SRC, join(ext, "skill-enforcer.ts"));
  // mirrors pi-bootstrap/pi-config/extensions/shared -> repo extensions/shared
  symlinkSync(join(REPO_ROOT, "extensions", "shared"), join(ext, "shared"));

  // Loader precondition probe: a symlink whose target lives OUTSIDE this
  // directory, so `__dirname` and `realpathSync(__filename)` can be compared.
  const probeReal = join(root, "probe-real");
  mkdirSync(probeReal, { recursive: true });
  writeFileSync(join(probeReal, "probe.cjs"), "module.exports = { dir: __dirname, real: require('node:fs').realpathSync(__filename) };\n");
  symlinkSync(join(probeReal, "probe.cjs"), join(ext, "probe.cjs"));

  // Pre-fix `skill-enforcer.ts` value-imports this package (removed by the
  // inline); the stub lets the RED run reach its assertions instead of dying
  // on ERR_PACKAGE_PATH_NOT_EXPORTED. Post-fix it is unused.
  const pkgDir = join(root, "node_modules", "@earendil-works", "pi-coding-agent");
  mkdirSync(pkgDir, { recursive: true });
  writeFileSync(join(pkgDir, "package.json"), JSON.stringify({ name: PI_STUB_PKG, version: "0.0.0-fixture", main: "index.cjs" }));
  writeFileSync(join(pkgDir, "index.cjs"), "exports.isToolCallEventType = (toolName, event) => !!event && event.toolName === toolName;\n");

  const driver = join(root, "driver.cjs");
  writeFileSync(driver, driverSource());
  return { root, driver };
}

/**
 * Copy the REAL manifest into a copy-farm, so the extension can arm its rules
 * under the `dirname(__filename)`-relative resolution too. This is the layout
 * that exposes #1322's read-identity defect WITHOUT #1321's empty manifest
 * masking it.
 */
function armCopyFarm(): { root: string; driver: string } {
  const c = makeFarm("copy");
  mkdirSync(join(c.root, "enforcement"), { recursive: true });
  copyFileSync(REAL_MANIFEST, join(c.root, "enforcement", "dangerous-ops.txt"));
  return c;
}

// CommonJS so the console patch is installed BEFORE the extension is required
// (module-load `reportManifestState()` must be captured).
function driverSource(): string {
  return `
const logs = [];
const ol = console.log, oe = console.error;
console.log = (...a) => logs.push("log: " + a.join(" "));
console.error = (...a) => logs.push("err: " + a.join(" "));
(async () => {
let probe = null;
try { const p = require("./extensions/probe.cjs"); probe = { dir: p.dir, real: p.real, preserved: p.dir !== p.real }; } catch (e) { probe = { error: String(e && e.message) }; }
let mod = null, loadError = null;
try { mod = require("./extensions/skill-enforcer.ts"); } catch (e) { loadError = String((e && e.stack) || e); }
if (!mod) { console.log = ol; console.error = oe; process.stdout.write(JSON.stringify({ loadError, logs, probe })); return; }
// Never touch the developer's real reader cache; the pre-fix module has no seam
// and would, which is why the red run is recorded with it backed up.
if (typeof mod._setSkillReadsFileForTest === "function") mod._setSkillReadsFileForTest(process.cwd() + "/driver-reads.json");
const handlers = [];
let hookError = null;
try { mod.default({ on: (n, f) => handlers.push([n, f]) }); } catch (e) { hookError = "hookError: " + String((e && e.message) || e); logs.push(hookError); }
let health = null;
try {
  const r = require("./extensions/shared/health.ts").getReport();
  health = r.extensions.find((e) => e.name === "skill-enforcer") || { absent: r.extensions.map((e) => e.name) };
} catch (e) { health = { error: String(e && e.message) }; }
async function fire(event) {
  for (const [n, f] of handlers) {
    if (n !== "tool_call") continue;
    const res = await f(event, {});
    if (res && res.block) return res;
  }
  return null;
}
// #1322 read-identity probe: a manifest-armed rule must clear when the skill is
// read through the path pi actually advertises (~/.pi/agent/skills/...).
const before = await fire({ toolName: "bash", input: { command: ${JSON.stringify(WORKTREE_CMD)} } });
await fire({ toolName: "read", input: { path: ${JSON.stringify(WORKTREE_SKILL)} } });
const after = await fire({ toolName: "bash", input: { command: ${JSON.stringify(WORKTREE_CMD)} } });
// T7 probe: an unanchored /tmp read must NEVER satisfy a gate, whatever the
// ambient SKILLS_PREFIX override says.
await fire({ toolName: "read", input: { path: "/tmp/evil/skills/commit-workflow/SKILL.md" } });
const evil = await fire({ toolName: "bash", input: { command: "git commit -m x" } });
// #1327 probe: a SKILL.md FORGED inside a trusted root (cwd/skills/, which is
// the agent's own checkout) must not clear the git gate either...
const fs = require("node:fs"), path = require("node:path");
const forgedDir = path.join(process.cwd(), "skills", "commit-workflow");
fs.mkdirSync(forgedDir, { recursive: true });
const forgedSkill = path.join(forgedDir, "SKILL.md");
fs.writeFileSync(forgedSkill, "not the real skill\\n");
await fire({ toolName: "read", input: { path: forgedSkill } });
const forged = await fire({ toolName: "bash", input: { command: "git commit -m x" } });
// ...and the POSITIVE CONTROL for that leg: the real skill at the canonical path
// still clears the same gate, so forgedCommitBlocked cannot pass vacuously.
await fire({ toolName: "read", input: { path: ${JSON.stringify(join(REPO_ROOT, "skills", "commit-workflow", "SKILL.md"))} } });
const realCommit = await fire({ toolName: "bash", input: { command: "git commit -m x" } });
// Restore only now, so the FACTORY-time banner is captured too — the pre-fix
// module announces itself here (and not at all under PI_MODE=print), which is
// the artifact the red leg is about.
console.log = ol; console.error = oe;
process.stdout.write(JSON.stringify({
  probe,
  loadError,
  hookError,
  blockedBeforeRead: !!(before && before.block),
  blockedAfterRead: !!(after && after.block),
  evilCommitBlocked: !!(evil && evil.block),
  forgedCommitBlocked: !!(forged && forged.block),
  realCommitBlocked: !!(realCommit && realCommit.block),
  canonicalFarm: mod.CANONICAL_SKILLS_RESOLUTION ?? (mod.canonicalSkillsRoot ? mod.canonicalSkillsRoot() : null),
  canonicalFarmError: mod.CANONICAL_FARM_ERROR ?? null,
  blockReason: (before && before.reason) || null,
  // Defensive: the PRE-FIX module has none of these (that is the red signal),
  // and a driver that throws would report nothing at all.
  MODULE_DIR: mod.MODULE_DIR,
  REPO_DIR: mod.REPO_DIR,
  MANIFEST_PATH: mod.MANIFEST_PATH,
  source: mod.MANIFEST_RESOLUTION && mod.MANIFEST_RESOLUTION.source,
  ok: mod.MANIFEST_LOAD && mod.MANIFEST_LOAD.ok,
  error: (mod.MANIFEST_LOAD && mod.MANIFEST_LOAD.error) || null,
  warnings: (mod.MANIFEST_LOAD && mod.MANIFEST_LOAD.warnings) || [],
  counts: mod.manifestCounts ? mod.manifestCounts() : null,
  banner: mod.manifestBanner ? mod.manifestBanner(mod.MANIFEST_LOAD, mod.MANIFEST_PATH) : null,
  health,
  logs,
}, null, 1));
})();
`;
}

function childEnv(extra: Record<string, string | undefined>): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = { ...process.env };
  for (const k of ["SKILL_ENFORCER_DISABLED", "AGENT_ALLOW_MAIN_EDITS", "ELDATO_ALLOW_MAIN_EDITS", "AGENT_SKILLS_PREFIX", "ELDATO_SKILLS_PREFIX", "AGENT_INFRA_PATH", "ELDATO_INFRA_PATH", "PI_MODE", "NODE_OPTIONS"]) delete env[k];
  for (const [k, v] of Object.entries(extra)) {
    if (v === undefined) delete env[k];
    else env[k] = v;
  }
  return env;
}

function runDriver(driver: string, env: NodeJS.ProcessEnv): { status: number; stdout: string; stderr: string; json: any } {
  const res = spawnSync("npx", ["tsx", driver], { env, cwd: dirname(driver), encoding: "utf8", timeout: 240000 });
  const stdout = res.stdout ?? "";
  let json: any = null;
  const start = stdout.indexOf("{");
  if (start >= 0) {
    try { json = JSON.parse(stdout.slice(start)); } catch { /* leave null */ }
  }
  return { status: res.status ?? -1, stdout, stderr: res.stderr ?? "", json };
}

/** Dump a child run into an assertion message — the RED has to be self-evidencing. */
function describeRun(r: { json: any; stderr: string }): string {
  return JSON.stringify(
    {
      loadError: r.json?.loadError,
      MODULE_DIR: r.json?.MODULE_DIR,
      REPO_DIR: r.json?.REPO_DIR,
      MANIFEST_PATH: r.json?.MANIFEST_PATH,
      source: r.json?.source,
      ok: r.json?.ok,
      error: r.json?.error,
      banner: r.json?.banner,
      counts: r.json?.counts,
      blockedBeforeRead: r.json?.blockedBeforeRead,
      blockedAfterRead: r.json?.blockedAfterRead,
      forgedCommitBlocked: r.json?.forgedCommitBlocked,
      realCommitBlocked: r.json?.realCommitBlocked,
      canonicalFarm: r.json?.canonicalFarm,
      canonicalFarmError: r.json?.canonicalFarmError,
      health: r.json?.health,
      logs: r.json?.logs,
    },
    null,
    1,
  );
}

function findJiti(): string | null {
  const explicit = process.env.PI_JITI_PATH;
  if (explicit && existsSync(explicit)) return explicit;
  const base = join(REAL_HOME, ".local", "share", "pi-node");
  if (!existsSync(base)) return null;
  try {
    for (const v of readdirSync(base)) {
      const p = join(base, v, "lib", "node_modules", "@earendil-works", "pi-coding-agent", "node_modules", "jiti", "lib", "jiti.mjs");
      if (existsSync(p)) return p;
    }
  } catch { /* none */ }
  return null;
}

// ── suite ────────────────────────────────────────────
async function main() {
  // ── Hermetic DEPLOYED fixture (#1327) ────────────────
  // Swap HOME BEFORE any session: the extension resolves `~/.pi/agent/skills`
  // per call, and the provenance legs must read a REAL skill through the path pi
  // serves. Writing the developer's own ~/.pi is refused (see the hermeticity
  // leg). `npm_config_cache` keeps `npx tsx` on the developer's cache so the
  // fixture HOME cannot make a child try to download the runner.
  FIXTURE_HOME = tmpDir("se-home-");
  process.env.HOME = FIXTURE_HOME;
  process.env.npm_config_cache ??= join(REAL_HOME, ".npm");
  PI_SKILLS = join(FIXTURE_HOME, ".pi", "agent", "skills");
  WORKTREE_SKILL = join(PI_SKILLS, "using-git-worktrees", "SKILL.md");
  mkdirSync(join(PI_SKILLS, "reviewers"), { recursive: true });
  for (const name of FIXTURE_SKILLS) {
    symlinkSync(join(REPO_ROOT, "skills", name), join(PI_SKILLS, name), "dir");
  }
  symlinkSync(
    join(REPO_ROOT, "skills", "reviewers", "duplication-architecture"),
    join(PI_SKILLS, "reviewers", "duplication-architecture"),
    "dir",
  );

  section("A. manifest load semantics — T2/T3/T4/T10 (#1321)");
  const dir = tmpDir("se-manifest-");

  await test("missing manifest → ok=false, loud reason, no rules", () => {
    const r = loadManifest(join(dir, "nope.txt"));
    equal(r.ok, false);
    ok(/not found/.test(r.error ?? ""), `error should name the missing path, got ${r.error}`);
    equal(Object.keys(r.rules).length, 0);
  });

  await test("blank and comments-only manifests → ok=false (0 entries, never a silent success)", () => {
    for (const body of ["", "\n\n", "# only a comment\n# and another\n"]) {
      const p = join(dir, "m.txt");
      writeFileSync(p, body);
      const r = loadManifest(p);
      equal(r.ok, false, `body ${JSON.stringify(body)} must not read as loaded`);
      ok(/0 entries/.test(r.error ?? ""), `error should name 0 entries, got ${r.error}`);
    }
  });

  await test("T10 — a repeated skill name APPENDS rules instead of clobbering", () => {
    const p = join(dir, "dup.txt");
    writeFileSync(p, "alpha # git commit # hard # first\nalpha # gh pr review # nudge # second\n");
    const r = loadManifest(p);
    equal(r.ok, true, `expected ok, got ${r.error}`);
    equal(r.rules.alpha?.length, 2);
    deepEqual(r.rules.alpha?.map(x => x.mode), ["hard", "nudge"]);
    ok(r.rules.alpha?.[0]?.patterns[0]?.test("git commit"));
    ok(r.rules.alpha?.[1]?.patterns[0]?.test("gh pr review"));
  });

  await test("T4 — a pattern-less entry is dropped and makes the load not-ok", () => {
    const p = join(dir, "empty.txt");
    writeFileSync(p, "alpha # # hard # no pattern\nbeta # git commit # hard # ok\n");
    const r = loadManifest(p);
    equal(r.ok, false);
    ok(/alpha/.test(r.warnings.join("\n")), `warning should name the entry, got ${r.warnings.join("|")}`);
    equal(r.rules.alpha, undefined, "a pattern-less entry must not pretend to gate");
    equal(r.rules.beta?.length, 1, "the remaining entries still enforce");
  });

  await test("T4 — an invalid regex is reported, not thrown", () => {
    const p = join(dir, "badre.txt");
    writeFileSync(p, "alpha # ( # hard # broken\n");
    let threw = false;
    let r: ReturnType<typeof loadManifest> | undefined;
    try { r = loadManifest(p); } catch { threw = true; }
    equal(threw, false, "loadManifest must not throw");
    equal(r!.ok, false);
    ok(/invalid pattern/.test(r!.warnings.join("\n")));
  });

  await test("T4 — a line whose mode is not exactly `hard`/`nudge` is a DEFECT, not a silent downgrade", () => {
    const p = join(dir, "mode.txt");
    writeFileSync(p, "alpha # git commit # HARD # shouted\nbeta # git commit # hard # ok\n");
    const r = loadManifest(p);
    equal(r.ok, false, "an unrecognised mode must not read as a healthy load");
    ok(/unrecognised mode/.test(r.warnings.join("\n")), `got ${r.warnings.join("|")}`);
    equal(r.rules.alpha, undefined, "'HARD' must never be silently enforced as a nudge");
    equal(r.rules.beta?.length, 1, "its correctly-spelled sibling still enforces");
  });

  await test("T4 — a missing mode field is likewise a defect, not a default", () => {
    const p = join(dir, "nomode.txt");
    writeFileSync(p, "alpha # git commit\n");
    const r = loadManifest(p);
    equal(r.ok, false);
    ok(/unrecognised mode/.test(r.warnings.join("\n")), `got ${r.warnings.join("|")}`);
  });

  await test("T4 — a '#' inside a field is malformed, not silently truncated", () => {
    const p = join(dir, "hash.txt");
    writeFileSync(p, "alpha # git commit # hard # message with # hash\n");
    const r = loadManifest(p);
    equal(r.ok, false);
    ok(/malformed/.test(r.warnings.join("\n")), `got ${r.warnings.join("|")}`);
  });

  section("B. the real manifest is fully armed — T10 (#1321 Indicator 2 precondition)");
  await test("MANIFEST_PATH is the manifest next to the REAL module", () => {
    equal(MODULE_DIR, join(REPO_ROOT, "extensions"));
    equal(REPO_DIR, REPO_ROOT);
    equal(MANIFEST_PATH, REAL_MANIFEST);
    equal(MANIFEST_RESOLUTION.source, "module");
    equal(realpathSync(MANIFEST_PATH), realpathSync(REAL_MANIFEST));
  });

  await test("4 unique skill gates / 6 rules — the file's non-comment line count survives", () => {
    equal(MANIFEST_LOAD.ok, true, `manifest should load, got ${MANIFEST_LOAD.error}`);
    deepEqual(manifestCounts(), { skills: 4, rules: 6 });
  });

  await test("commit-workflow's GIT gate survived its second manifest line", () => {
    const rules = MANIFEST_RULES["commit-workflow"] ?? [];
    const hard = rules.filter(r => r.mode === "hard");
    ok(hard.length >= 2, `expected ≥2 hard rules for commit-workflow, got ${hard.length}`);
    const all = hard.flatMap(r => r.patterns);
    for (const cmd of ["git commit -m x", "git push origin main", "git merge x", "gh pr create --draft"]) {
      ok(all.some(p => p.test(cmd)), `${cmd} must be armed by a hard commit-workflow rule`);
    }
    ok(all.some(p => p.test("gh pr review 1")), "the second line's gh-pr-review rule must survive too");
  });

  await test("how-to-use-tortoise keeps BOTH a hard verb rule and its broad nudge rule", () => {
    const rules = MANIFEST_RULES["how-to-use-tortoise"] ?? [];
    ok(rules.some(r => r.mode === "hard" && r.patterns.some(p => p.test("tortoise_create_point"))), "hard verb gate missing");
    ok(rules.some(r => r.mode === "nudge" && r.patterns.some(p => p.test("tortoise_search"))), "broad nudge rule missing");
  });

  await test("#6131 — the operator-taking generic verbs are HARD-armed, not left to the nudge rule", () => {
    // SKILL.md's Hard Gate claims BOTH `update(<operator_id>, …)` and
    // `delete(<operator_id>)` MUST go through the skill, and before #6131 the
    // prose list and this manifest's hard list were 1:1 (7 ops each). The two
    // generic verbs matched only the broad `tortoise_` NUDGE rule, so a lane
    // could relabel or delete an operator edge — the exact mutation the skill
    // exists to guard — without the skill ever being read. A nudge is not a
    // gate: it escalates only after repeated bypasses.
    const rules = MANIFEST_RULES["how-to-use-tortoise"] ?? [];
    const hard = rules.filter(r => r.mode === "hard").flatMap(r => r.patterns);
    for (const verb of ["tortoise_update", "tortoise_delete"]) {
      ok(
        hard.some(p => p.test(`mcp__tortoise__${verb}`)),
        `${verb} must be armed by a HARD rule — the nudge rule is not a gate`,
      );
    }
  });

  await test("banner reports the count and the rule count; a failed load never prints ✅", () => {
    const healthy = manifestBanner(MANIFEST_LOAD, MANIFEST_PATH);
    ok(healthy.includes("enforcing 4 skill gates from manifest"), healthy);
    ok(healthy.includes("(6 rules)"), healthy);
    ok(healthy.includes("✅"), healthy);
    const broken = manifestBanner({ rules: {}, ok: false, error: "manifest not found at /nope", warnings: [] }, "/nope");
    ok(!broken.includes("✅"), `a failed load must never print ✅: ${broken}`);
    ok(broken.includes("❌"), broken);
  });

  await test("a partially-defective manifest says DEGRADED / STILL ARMED — never `NOT ENFORCING`", () => {
    const p = join(dir, "partial.txt");
    writeFileSync(p, "alpha # git commit # hard # ok\nbeta # git worktree add # HARD # typo'd mode\n");
    const l = loadManifest(p);
    equal(l.ok, false);
    const banner = manifestBanner(l, p);
    ok(banner.includes("DEGRADED"), banner);
    ok(banner.includes("STILL ARMED"), `surviving rules are still blocking, so the banner must say so: ${banner}`);
    ok(!banner.includes("NOT ENFORCING"), `NOT ENFORCING would tell an operator the opposite of the truth: ${banner}`);
    ok(!banner.includes("✅"), banner);
  });

  await test("resolveManifestPath prefers the sibling and never lets the env override it", () => {
    const r = resolveManifestPath({ AGENT_INFRA_PATH: "/definitely/not/this/repo" });
    equal(r.source, "module");
    equal(r.path, REAL_MANIFEST);
  });

  section("C. canonical skill identity — T5/T6/T7 (#1322) + provenance (#1327)");
  const NAME = "commit-workflow";
  const CANONICAL = join(REPO_ROOT, "skills", NAME, "SKILL.md");

  await test("T5 — every served/consumer root resolves to the SAME canonical key", async () => {
    // Each layout must carry the REAL skill (a link or a copy of it) to register.
    const shapes = ["skills", "operations/skills", ".agents/skills", ".pi/skills"];
    for (const shape of shapes) {
      for (const mode of ["hardlink", "copy", "dir-symlink"] as const) {
        const base = tmpDir(`se-root-${mode}-`);
        const p = plantSkill(base, shape, NAME, mode);
        await inDir(base, () => equal(canonicalSkillName(p), NAME, `${shape} (${mode})`));
      }
    }
    // The pi-served path (a per-skill symlink under the fixture HOME) and the
    // canonical farm path itself, both without any fixture base.
    equal(canonicalSkillName(join(PI_SKILLS, NAME, "SKILL.md")), NAME, "pi user skills");
    equal(canonicalSkillName(CANONICAL), NAME, "module-repo skills/");
  });

  await test("T7 — a path outside every trusted root does NOT register", () => {
    for (const p of [
      `/tmp/evil/skills/${NAME}/SKILL.md`,
      `/tmp/evil/operations/skills/${NAME}/SKILL.md`,
      `/tmp/evil/.agents/skills/${NAME}/SKILL.md`,
      `/tmp/evil/.pi/agent/skills/${NAME}/SKILL.md`,
    ]) equal(canonicalSkillName(p), null, `${p} must not satisfy a gate`);
  });

  // ── #1327 — the residual this issue closes ──────────
  await test("#1327 — a SKILL.md FORGED inside a trusted root does NOT register", async () => {
    for (const shape of ["skills", "operations/skills", ".agents/skills", ".pi/skills"]) {
      const base = tmpDir(`se-forged-${shape.replace(/\//g, "-")}-`);
      const p = plantSkill(base, shape, NAME, "forged");
      await inDir(base, () =>
        equal(canonicalSkillName(p), null, `${shape}/${NAME}/SKILL.md carries a forged SKILL.md — it must not satisfy a gate (#1327)`),
      );
    }
  });

  await test("#1327 — the forgery is refused even through the path pi SERVES (per-skill dir, fixture HOME)", () => {
    // The deployed fixture HOME is a real `~/.pi/agent/skills` directory of
    // symlinks, so a forgery can be planted NEXT TO the real skills — the exact
    // shape #1327 describes (`~/.pi/agent/skills wherever it is writable`).
    const fakeHome = tmpDir("se-forged-home-");
    const skills = join(fakeHome, ".pi", "agent", "skills");
    mkdirSync(skills, { recursive: true });
    symlinkSync(join(REPO_ROOT, "skills", "how-to-use-tortoise"), join(skills, "how-to-use-tortoise"), "dir");
    const forged = plantSkill(join(fakeHome, ".pi", "agent"), "skills", NAME, "forged");
    const real = join(skills, "how-to-use-tortoise", "SKILL.md");
    const prev = process.env.HOME;
    process.env.HOME = fakeHome;
    try {
      equal(canonicalSkillName(real), "how-to-use-tortoise", "the real neighbour must still register");
      equal(canonicalSkillName(forged), null, "the forged neighbour must not");
    } finally {
      process.env.HOME = prev;
    }
  });

  await test("#1327 — a name the canonical farm does not ship can never register, whatever is planted", async () => {
    const base = tmpDir("se-ghost-");
    const skills = join(base, "skills");
    mkdirSync(skills, { recursive: true });
    const ghost = join(skills, "totally-made-up-skill", "SKILL.md");
    mkdirSync(join(skills, "totally-made-up-skill"), { recursive: true });
    writeFileSync(ghost, "frontmatter-ish:\nname: totally-made-up-skill\n");
    await inDir(base, () => equal(canonicalSkillName(ghost), null, "no canonical copy exists for this name"));
    equal(canonicalSkillFile("totally-made-up-skill"), null, "canonical lookup must agree");
  });

  await test("#1327 — an extra byte on otherwise canonical content is NOT the skill", async () => {
    const base = tmpDir("se-tamper-");
    const p = plantSkill(base, "skills", NAME, "copy");
    writeFileSync(p, readFileSync(CANONICAL, "utf-8") + "\n<!-- tampered -->\n");
    await inDir(base, () => equal(canonicalSkillName(p), null, "a tampered copy is not the skill — content identity is exact"));
  });

  await test("relative + trailing-slash paths normalise; nested skills key on the owning dir", () => {
    equal(canonicalSkillName(`skills/${NAME}/SKILL.md`), NAME, "cwd is the repo, which carries the canonical skill");
    equal(canonicalSkillName(CANONICAL + "/"), NAME);
    const nested = join(PI_SKILLS, "reviewers", "duplication-architecture", "SKILL.md");
    ok(existsSync(nested), `fixture missing: ${nested}`);
    equal(canonicalSkillName(nested), "duplication-architecture");
    equal(
      canonicalSkillFile("duplication-architecture"),
      join(REPO_ROOT, "skills", "reviewers", "duplication-architecture", "SKILL.md"),
      "a nested skill's canonical file is found under its nested shape, not at the farm root",
    );
    equal(canonicalSkillName(join(REPO_ROOT, "skills", NAME, "README.md")), null);
    equal(canonicalSkillName(""), null);
  });

  await test("no trusted root is ever degenerate (an empty root would match every absolute path)", () => {
    const roots = skillRoots();
    ok(roots.length > 0);
    for (const r of roots) {
      ok(r && r !== "/", `degenerate trusted root ${JSON.stringify(r)} — every absolute path would satisfy startsWith(that + "/")`);
      ok(r.startsWith("/"), `trusted root must be absolute: ${r}`);
    }
  });

  await test("skillDisplayPath names an EXISTING file for every manifest skill", () => {
    for (const name of Object.keys(MANIFEST_RULES)) {
      const p = skillDisplayPath(name);
      ok(existsSync(p), `display path for ${name} does not exist: ${p}`);
      equal(skillFileFor(name), p);
    }
    ok(skillRoots().length > 0);
  });

  await test("#1327 — the canonical provenance anchor is the farm beside THIS module, and it exists", () => {
    equal(CANONICAL_FARM_ERROR, null, `the checkout must carry skills/ next to the module: ${CANONICAL_FARM_ERROR}`);
    deepEqual(canonicalSkillsRoot(), { path: join(REPO_ROOT, "skills"), source: "module" });
    for (const name of Object.keys(MANIFEST_RULES)) {
      equal(canonicalSkillFile(name), join(REPO_ROOT, "skills", name, "SKILL.md"), `${name} must have a canonical copy (a gate nobody can satisfy is a false block)`);
    }
  });

  section("D. read-tracking + the git positive control — #1321 Ind 2, #1322 Ind 1/2/3");
  await test("git commit is BLOCKED before the read, and the reason names the skill + an existing path", async () => {
    const { pi } = await newSession();
    const res = await pi.fire("tool_call", COMMIT);
    ok(res && res.block === true, "git commit must be blocked while commit-workflow is unread (if this is undefined, the bypass env is still set)");
    ok(String(res.reason).includes("commit-workflow"), String(res.reason));
    const shown = skillDisplayPath("commit-workflow");
    ok(String(res.reason).includes(shown), `reason should name ${shown}`);
    ok(existsSync(shown), "the advertised remedy must exist");
  });

  await test("a read through the pi-served ~/.pi/agent/skills path clears it, and registers ONE canonical key", async () => {
    const { pi, reads } = await newSession();
    equal((await pi.fire("tool_call", COMMIT))?.block, true);
    await pi.fire("tool_call", { toolName: "read", input: { path: join(PI_SKILLS, "commit-workflow", "SKILL.md") } });
    equal((await pi.fire("tool_call", COMMIT))?.block, undefined, "the read must clear the gate");
    deepEqual(persistedNames(reads), ["commit-workflow"], "skill-reads.json must hold the canonical NAME (#1322 Ind 3)");
  });

  await test("T6 — a read through .agents/skills/ clears the gate too", async () => {
    const { pi, reads } = await newSession();
    const base = tmpDir("se-agents-");
    const planted = plantSkill(base, ".agents/skills", "commit-workflow", "hardlink");
    await inDir(base, async () => {
      await pi.fire("tool_call", { toolName: "read", input: { path: planted } });
      equal((await pi.fire("tool_call", COMMIT))?.block, undefined);
      deepEqual(persistedNames(reads), ["commit-workflow"]);
    });
  });

  await test("T7 — reading a forged unanchored path does NOT clear the gate", async () => {
    const { pi, reads } = await newSession();
    await pi.fire("tool_call", { toolName: "read", input: { path: "/tmp/evil/skills/commit-workflow/SKILL.md" } });
    equal((await pi.fire("tool_call", COMMIT))?.block, true, "a forged path must not satisfy the gate");
    deepEqual(persistedNames(reads), []);
  });

  // ── #1327 — the closed residual, end-to-end through the gate handler ──────
  await test("#1327 — a forged SKILL.md INSIDE a trusted root does NOT clear an armed gate", async () => {
    const base = tmpDir("se-forged-e2e-");
    const forged = plantSkill(base, "skills", "commit-workflow", "forged");
    await inDir(base, async () => {
      const { pi, reads } = await newSession();
      equal((await pi.fire("tool_call", COMMIT))?.block, true, "the git gate must be ARMED before the read (else this leg is vacuous)");
      await pi.fire("tool_call", { toolName: "read", input: { path: forged } });
      equal((await pi.fire("tool_call", COMMIT))?.block, true, "`mkdir -p <root>/commit-workflow && read` must not satisfy the gate (#1327)");
      deepEqual(persistedNames(reads), [], "a forgery must not persist as a read either");
    });
  });

  await test("#1327 — the SAME forged look-alike is accepted when it IS the canonical bytes", async () => {
    // The complement: a byte-identical copy (the sync.sh folder-copy machine) and
    // a hard link both prove the skill's instructions were reached.
    for (const mode of ["copy", "hardlink"] as const) {
      const base = tmpDir(`se-real-${mode}-`);
      const planted = plantSkill(base, "skills", "commit-workflow", mode);
      await inDir(base, async () => {
        const { pi } = await newSession();
        equal((await pi.fire("tool_call", COMMIT))?.block, true);
        await pi.fire("tool_call", { toolName: "read", input: { path: planted } });
        equal((await pi.fire("tool_call", COMMIT))?.block, undefined, `${mode} must clear the gate`);
      });
    }
  });

  await test("#6131 — the operator-taking verbs hard-block until the skill is read, then clear", async () => {
    const { pi } = await newSession();
    for (const verb of ["tortoise_update", "tortoise_delete"]) {
      const res = await pi.fire("tool_call", { toolName: `mcp__tortoise__${verb}`, input: {} });
      ok(res && res.block === true, `${verb} must be blocked while how-to-use-tortoise is unread`);
      ok(String(res.reason).includes("how-to-use-tortoise"), String(res.reason));
    }
    await pi.fire("tool_call", { toolName: "read", input: { path: join(REPO_ROOT, "skills", "how-to-use-tortoise", "SKILL.md") } });
    for (const verb of ["tortoise_update", "tortoise_delete"]) {
      equal(
        (await pi.fire("tool_call", { toolName: `mcp__tortoise__${verb}`, input: {} }))?.block,
        undefined,
        `${verb} must clear once the skill is read`,
      );
    }
  });

  await test("T11 — a nudge rule never hard-blocks (the manifest is armed, so this is now live)", async () => {
    const { pi } = await newSession();
    equal((await pi.fire("tool_call", TORTOISE_SEARCH))?.block, undefined, "an mcp nudge rule must not block");
    equal((await pi.fire("tool_call", { toolName: "bash", input: { command: "rg -n 'tortoise_' skills/" } }))?.block, undefined, "a bash nudge rule must not block");
    equal((await pi.fire("tool_call", TORTOISE_WRITE))?.block, true, "the hard verb list must still block a genuine write");
  });

  await test("prerequisite chain: writing-plans alone blocks write; with issue-scoping it does not", async () => {
    const { pi } = await newSession();
    await pi.fire("tool_call", { toolName: "read", input: { path: join(REPO_ROOT, "skills", "writing-plans", "SKILL.md") } });
    ok((await pi.fire("tool_call", { toolName: "write", input: { path: "x.ts" } }))?.block, "writing-plans without issue-scoping must block write");
    await pi.fire("tool_call", { toolName: "read", input: { path: join(PI_SKILLS, "issue-scoping", "SKILL.md") } });
    equal((await pi.fire("tool_call", { toolName: "write", input: { path: "x.ts" } }))?.block, undefined);
  });

  await test("before_agent_start nudges fire before a read, are suppressed after one, and name an existing file", async () => {
    const { pi } = await newSession();
    const nudge = await pi.fire("before_agent_start", { prompt: "let me commit this" });
    ok(nudge && nudge.message, "a commit-shaped prompt must produce a nudge");
    ok(String(nudge.message.content).includes(skillDisplayPath("commit-workflow")), String(nudge.message.content));
    ok(existsSync(skillDisplayPath("commit-workflow")));
    // Suppression must work through a NON-prefix path — the old key check did not.
    await pi.fire("tool_call", { toolName: "read", input: { path: join(PI_SKILLS, "commit-workflow", "SKILL.md") } });
    equal(await pi.fire("before_agent_start", { prompt: "let me commit this" }), undefined);
  });

  section("E. persisted reads — T13");
  await test("a legacy path-form entry restores to the canonical name", async () => {
    const { pi, reads } = await newSession();
    writeFileSync(reads, JSON.stringify([{ file: "operations/skills/commit-workflow/SKILL.md", readAt: Date.now() }]));
    await pi.fire("session_start", {});
    equal((await pi.fire("tool_call", COMMIT))?.block, undefined, "a legacy entry must still satisfy the gate");
    // Any subsequent read re-persists the whole set, so this is also the check
    // that the OLD entry is rewritten in canonical form (no path-shaped keys).
    await pi.fire("tool_call", { toolName: "read", input: { path: join(PI_SKILLS, "issue-scoping", "SKILL.md") } });
    deepEqual(persistedNames(reads), ["commit-workflow", "issue-scoping"]);
  });

  await test("a forged entry naming a non-existent skill is refused, loudly", async () => {
    const { pi, reads } = await newSession();
    writeFileSync(reads, JSON.stringify([{ file: "definitely-not-a-real-skill", readAt: Date.now() }]));
    const errs: string[] = [];
    const orig = console.error;
    console.error = (...a: unknown[]) => errs.push(a.join(" "));
    try { await pi.fire("session_start", {}); } finally { console.error = orig; }
    ok(errs.join("\n").includes("unresolvable"), `expected a diagnostic, got: ${errs.join("|")}`);
    equal((await pi.fire("tool_call", COMMIT))?.block, true);
  });

  await test("T13 — a PATH-SHAPED entry naming a ghost under a trusted root is refused, loudly", async () => {
    const { pi, reads } = await newSession();
    // `canonicalSkillName` is now identity-checked, so the NAME comes from the
    // shape and the canonical farm decides whether that name is a real skill.
    writeFileSync(reads, JSON.stringify([{ file: join(REPO_ROOT, "skills", "definitely-not-a-real-skill-xyz", "SKILL.md"), readAt: Date.now() }]));
    const errs: string[] = [];
    const orig = console.error;
    console.error = (...a: unknown[]) => errs.push(a.join(" "));
    try { await pi.fire("session_start", {}); } finally { console.error = orig; }
    ok(errs.join("\n").includes("unresolvable"), `a ghost path entry must be diagnosed, got: ${errs.join("|")}`);
    equal((await pi.fire("tool_call", COMMIT))?.block, true);
  });

  await test("T13 residual (#1327 boundary) — a persisted entry naming a REAL skill restores on the NAME alone", async () => {
    // Declared, not silent: the 24 h persistence window (#7416, by design; #1331
    // owns the window itself) is keyed on the NAME. #1327 narrowed the entry to
    // "must name a skill agent-infra ships" — it did NOT re-prove the recorded
    // path's provenance, and this pins that boundary explicitly.
    const base = tmpDir("se-t13-residual-");
    const forged = plantSkill(base, "skills", "commit-workflow", "forged");
    await inDir(base, async () => {
      const { pi, reads } = await newSession();
      writeFileSync(reads, JSON.stringify([{ file: forged, readAt: Date.now() }]));
      await pi.fire("session_start", {});
      equal((await pi.fire("tool_call", COMMIT))?.block, undefined, "the accepted T13 residual: a real NAME restores for <=24 h");
    });
  });

  await test("a corrupt reads file is diagnosed, not silently dropped, and does not throw", async () => {
    const { pi, reads } = await newSession();
    writeFileSync(reads, "{not json");
    const errs: string[] = [];
    const orig = console.error;
    console.error = (...a: unknown[]) => errs.push(a.join(" "));
    try { await pi.fire("session_start", {}); } finally { console.error = orig; }
    ok(/corrupt|unreadable/.test(errs.join("\n")), `expected a corruption diagnostic, got: ${errs.join("|")}`);
    equal((await pi.fire("tool_call", COMMIT))?.block, true);
  });

  section("F. #1328 — a `hard` rule fires on EVERY tool, not only bash / `mcp__*`");
  // A fixture manifest installed through the module's test seam, so the REAL
  // manifest (section B) is untouched after each leg. The pattern names BUILTIN
  // tools: before #1328 the line was accepted, counted as armed by the banner,
  // and could never fire — the only handler that sees a builtin tool name is the
  // nudge handler, and it skips `mode === "hard"`.
  const HARD_FIXTURE: Record<string, Array<{ patterns: RegExp[]; mode: "hard" | "nudge"; message?: string }>> = {
    "commit-workflow": [
      { patterns: [/^write$/, /^edit$/], mode: "hard", message: "Read commit-workflow first." },
    ],
  };

  await test("#1328 — a `hard` rule naming a builtin tool BLOCKS it until the skill is read", async () => {
    _setManifestForTest(HARD_FIXTURE);
    try {
      const { pi } = await newSession();
      const res = await pi.fire("tool_call", { toolName: "write", input: { path: "x.ts" } });
      ok(res?.block === true, "a hard rule naming `write` must block the write tool");
      ok(String(res.reason).includes("commit-workflow"), String(res.reason));
    } finally { _setManifestForTest(null); }
  });

  await test("#1328 — it fires on the named tool only, and the gate clears after the skill is read", async () => {
    _setManifestForTest(HARD_FIXTURE);
    try {
      const { pi } = await newSession();
      equal((await pi.fire("tool_call", { toolName: "edit", input: { path: "x.ts" } }))?.block, true, "`edit` is named by the rule");
      // An unnamed tool is untouched: the gate is the PATTERN, not a blanket
      // block on every builtin tool.
      equal((await pi.fire("tool_call", { toolName: "grep", input: { pattern: "x" } }))?.block, undefined, "an unnamed tool must not block");
      await pi.fire("tool_call", { toolName: "read", input: { path: join(REPO_ROOT, "skills", "commit-workflow", "SKILL.md") } });
      equal((await pi.fire("tool_call", { toolName: "write", input: { path: "x.ts" } }))?.block, undefined, "reading the skill must clear the builtin-tool gate");
    } finally { _setManifestForTest(null); }
  });

  await test("#1328 — the write/edit prerequisite branch no longer swallows the manifest hard gate", async () => {
    _setManifestForTest(HARD_FIXTURE);
    try {
      const { pi } = await newSession();
      await pi.fire("tool_call", { toolName: "read", input: { path: join(REPO_ROOT, "skills", "writing-plans", "SKILL.md") } });
      // The prerequisite chain is armed now. Bypassing IT must not bypass a
      // manifest `hard` rule naming the same tool.
      const res = await pi.fire("tool_call", { toolName: "write", input: { path: "x.ts", confirm: "prereq:writing-plans" } });
      ok(res?.block === true, "bypassing the prerequisite must not bypass the manifest hard rule");
      ok(String(res.reason).includes("commit-workflow"), String(res.reason));
    } finally { _setManifestForTest(null); }
  });

  await test("#1328 — the shipped manifest's hard rules reach no builtin tool (behaviour-neutral)", async () => {
    const { pi } = await newSession();
    for (const ev of [
      { toolName: "read", input: { path: "/etc/hostname" } },
      { toolName: "grep", input: { pattern: "x" } },
      { toolName: "find", input: { pattern: "x" } },
      { toolName: "web_search", input: { query: "x" } },
      { toolName: "todo_write", input: {} },
      { toolName: "task", input: {} },
    ]) {
      equal((await pi.fire("tool_call", ev))?.block, undefined, `${ev.toolName} must not be blocked by the shipped manifest`);
    }
  });

  await test("#1328 — a `hard` rule reaching for the gate-satisfaction tool is REFUSED at load, not armed", async () => {
    const p = join(tmpDir("se-read-gate-"), "m.txt");
    // `read` is how a skill gate is satisfied. Arming it would gate the
    // documented remedy for every unread gate, so the line must be refused
    // loudly and dropped — never counted as armed.
    writeFileSync(p, "alpha # ^read$ # hard # gate the remedy\n");
    const load = loadManifest(p);
    equal(load.ok, false, "a hard rule reaching for `read` must make the load not-ok");
    equal(load.rules.alpha, undefined, "the refused rule must not be armed");
    ok(/satisfied with/.test(load.warnings.join("\n")), `expected a refusal naming the satisfaction tool, got ${load.warnings.join("|")}`);
    // The refusal is scoped to `hard`: a NUDGE rule for the same tool is fine.
    writeFileSync(p, "alpha # ^read$ # nudge # remind, do not gate\n");
    equal(loadManifest(p).ok, true, "a nudge rule for `read` must still be accepted");
    // A hard rule that only OVERLAPS the reserved tool via a broad alternation
    // is refused too — partial enforcement is the silent downgrade #1321 banned.
    writeFileSync(p, "alpha # write|read # hard # gated remedy\n");
    ok(!loadManifest(p).ok, "a hard alternation that includes `read` must be refused, not partially armed");
  });

  section("G. static pins (regression guards, not behaviour)");
  const SOURCE = readFileSync(join(REPO_ROOT, "extensions", "skill-enforcer.ts"), "utf-8");
  await test("the SDK is imported for TYPES only — the module loads with zero node_modules", () => {
    ok(!/^\s*import\s+(?!type\b)[^;\n]*@earendil-works/m.test(SOURCE), "a runtime SDK import would break the bare-checkout suite");
    ok(SOURCE.includes('import type { ExtensionAPI, ToolCallEventResult } from "@earendil-works/pi-coding-agent"'));
    // #1330 — the predicate is no longer inlined HERE. It has one home
    // (shared/tool-call-event.ts) and is pinned against the real export by
    // extensions/verification-gate/tool-call-event-parity.test.ts; a private copy
    // in this file would drift under a pi upgrade with every gate still reporting
    // `✅ Loaded`. shared/tool-call-event.test.ts asserts this import repo-wide.
    ok(SOURCE.includes('import { isToolCallEventType } from "./shared/tool-call-event.js"'),
      "the shared predicate import must be present (it replaces the #1321 inline)");
    ok(!/function isToolCallEventType\(/.test(SOURCE), "the predicate must not be re-inlined here (#1330)");
  });
  await test("no gate key is built from SKILLS_PREFIX any more (only the display fallback)", () => {
    const hits = SOURCE.match(/SKILLS_PREFIX\}\$\{/g) ?? [];
    equal(hits.length, 1, `expected exactly one SKILLS_PREFIX key construction (the display fallback), got ${hits.length}`);
  });
  await test("#1327 — the read gate resolves the CANONICAL file and compares identity, shape alone is not enough", () => {
    ok(
      /canonicalSkillFileForRel\(match\.rel\)/.test(SOURCE),
      "canonicalSkillName must map the read's REL path onto the canonical farm — reverting to the shape-only match reopens #1327",
    );
    ok(
      /sameSkillFile\(match\.path, canonical\)/.test(SOURCE),
      "the canonical file must be compared for identity (same inode or same bytes) before the name is accepted",
    );
  });

  section("H. symlink-farm integration — T1/T8 (#1321, the deployed layout)");
  const realReadsBefore = existsSync(REAL_READS_FILE) ? readFileSync(REAL_READS_FILE, "utf-8") : null;
  const farm = makeFarm("symlink");
  const run = runDriver(farm.driver, childEnv({ NODE_OPTIONS: "--preserve-symlinks" }));

  await test("T8 (precondition) — the loader keeps the SYMLINK path, so this fixture reproduces #1321", () => {
    ok(run.json, `driver produced no JSON.\nstdout:\n${run.stdout}\nstderr:\n${run.stderr}`);
    ok(run.json.probe?.preserved === true, `loader precondition failed (probe=${JSON.stringify(run.json.probe)}) — the fixture would pass vacuously; this leg must be re-derived`);
  });

  await test("T1 — the deployed layout resolves the REAL manifest: 4 gates / 6 rules", () => {
    equal(run.json.loadError, null, `module failed to load: ${run.json.loadError}`);
    equal(run.json.MODULE_DIR, join(REPO_ROOT, "extensions"), `MODULE_DIR must be the REAL dir, not the farm\n${describeRun(run)}`);
    equal(run.json.REPO_DIR, REPO_ROOT);
    equal(run.json.source, "module");
    equal(realpathSync(run.json.MANIFEST_PATH), realpathSync(REAL_MANIFEST));
    equal(run.json.ok, true, `manifest must load in the farm\n${describeRun(run)}`);
    deepEqual(run.json.counts, { skills: 4, rules: 6 }, describeRun(run));
    ok(run.json.banner?.includes("enforcing 4 skill gates from manifest"), describeRun(run));
    ok(run.json.banner?.includes("(6 rules)"), describeRun(run));
    ok(run.json.banner?.includes("✅"), describeRun(run));
    ok(!run.json.logs.some((l: string) => l.includes("❌")), `a healthy farm must not warn: ${run.json.logs.join("|")}`);
  });

  await test("T2 — the reachable failure (no manifest anywhere) reports NOT ENFORCING, and health is failed", () => {
    const broken = makeFarm("copy");
    const r = runDriver(broken.driver, childEnv({}));
    ok(r.json, `driver produced no JSON.\nstdout:\n${r.stdout}\nstderr:\n${r.stderr}`);
    equal(r.json.loadError, null, String(r.json.loadError));
    equal(r.json.ok, false, `pre-fix this is undefined and the log line reads "✅ ... enforcing 0 skill gates"\n${describeRun(r)}`);
    ok(/manifest not found/.test(r.json.error ?? ""), describeRun(r));
    ok(r.json.banner?.includes("❌ NOT ENFORCING"), describeRun(r));
    ok(!r.json.banner?.includes("✅"), `never ✅ on a failed load: ${describeRun(r)}`);
    ok(
      r.json.logs.some((l: string) => l.startsWith("err: ") && l.includes("❌")),
      `the failure must reach stderr\n${describeRun(r)}`,
    );
    equal(r.json.health?.loaded, false, `health-check must see the failure\n${describeRun(r)}`);
    ok(/manifest not found/.test(String(r.json.health?.error)), describeRun(r));
  });

  await test("T2 — the loud failure is NOT print-mode gated", () => {
    const broken = makeFarm("copy");
    const r = runDriver(broken.driver, childEnv({ PI_MODE: "print" }));
    equal(r.json.ok, false, describeRun(r));
    ok(r.json.logs.some((l: string) => l.startsWith("err: ") && l.includes("❌")), `PI_MODE=print must not silence it\n${describeRun(r)}`);
  });

  await test("T3 — a comments-only manifest is an empty enforcement, reported as such", () => {
    const c = makeFarm("copy");
    mkdirSync(join(c.root, "enforcement"), { recursive: true });
    writeFileSync(join(c.root, "enforcement", "dangerous-ops.txt"), "# nothing armed yet\n# still nothing\n");
    const r = runDriver(c.driver, childEnv({}));
    equal(r.json.ok, false, describeRun(r));
    ok(/0 entries/.test(r.json.error ?? ""), describeRun(r));
    ok(r.json.banner?.includes("❌"), describeRun(r));
    ok(!r.json.banner?.includes("✅"), describeRun(r));
  });

  await test("T9 — a COPied extension falls back to AGENT_INFRA_PATH, and says so", () => {
    const c = makeFarm("copy");
    const r = runDriver(c.driver, childEnv({ AGENT_INFRA_PATH: REPO_ROOT }));
    equal(r.json.source, "env-fallback", describeRun(r));
    equal(r.json.ok, true, describeRun(r));
    deepEqual(r.json.counts, { skills: 4, rules: 6 }, describeRun(r));
    ok(
      r.json.logs.some((l: string) => l.includes("env-fallback") || l.includes("AGENT_INFRA_PATH")),
      `the fallback must be announced, not silent\n${describeRun(r)}`,
    );
    equal(r.json.health?.loaded, true, describeRun(r));
  });

  await test("#1322 Ind 1/2 — in the deployed layout, reading the skill through ~/.pi/agent/skills clears an ARMED rule", () => {
    const c = armCopyFarm();
    // AGENT_INFRA_PATH pins the canonical farm (the copy layout has no sibling
    // `skills/`), so this leg exercises PROVENANCE, not the degraded shape path.
    const r = runDriver(c.driver, childEnv({ AGENT_INFRA_PATH: REPO_ROOT }));
    // `blockedBeforeRead` is the behavioural arming guard — if the farm were not
    // armed it would be false and the test would be vacuous.
    equal(r.json.blockedBeforeRead, true, `${WORKTREE_CMD} must be blocked before the skill is read\n${describeRun(r)}`);
    equal(
      r.json.blockedAfterRead,
      false,
      `#1322 — the read came through the pi-served path (a symlink into the canonical farm), so the gate must clear\n${describeRun(r)}`,
    );
    equal(r.json.ok, true, describeRun(r));
  });

  // ── #1327 — the residual this issue closes, through the deployed loader ────
  await test("#1327 — in the deployed layout, a FORGED SKILL.md inside a trusted root does not clear an armed rule", () => {
    const c = armCopyFarm();
    const r = runDriver(c.driver, childEnv({ AGENT_INFRA_PATH: REPO_ROOT }));
    equal(r.json.evilCommitBlocked, true, `control: the unanchored /tmp read must not clear the gate\n${describeRun(r)}`);
    equal(
      r.json.forgedCommitBlocked,
      true,
      `#1327 — a forged <cwd>/skills/commit-workflow/SKILL.md must NOT satisfy the git gate\n${describeRun(r)}`,
    );
    equal(
      r.json.realCommitBlocked,
      false,
      `positive control: the same gate MUST clear once the real skill is read, else the leg above is vacuous\n${describeRun(r)}`,
    );
  });

  await test("#1327 — with no canonical farm the gates FAIL CLOSED, loudly (never a silent shape-only fallback)", () => {
    const c = armCopyFarm();
    const r = runDriver(c.driver, childEnv({}));
    equal(
      typeof r.json.canonicalFarmError,
      "string",
      `the module must report the missing farm\n${describeRun(r)}`,
    );
    ok(
      r.json.logs.some((l: string) => l.startsWith("err: ") && l.includes("❌") && l.includes("canonical skill farm")),
      `a missing farm must be loud + unconditional\n${describeRun(r)}`,
    );
    equal(r.json.health?.loaded, false, `health-check must see it\n${describeRun(r)}`);
    ok(
      /canonical skill farm/.test(String(r.json.health?.error)),
      `the health error must name the cause\n${describeRun(r)}`,
    );
    equal(
      r.json.blockedAfterRead,
      true,
      `no farm ⇒ no read can be certified, so the armed gate must still block\n${describeRun(r)}`,
    );
  });

  await test("T1 (real loader) — jiti loads the symlinked farm with the same result, or is reported skipped", () => {
    const jiti = findJiti();
    if (!jiti) {
      console.log("     ⏭️  jiti not resolvable on this host — the tsx --preserve-symlinks leg above is the CI guard");
      return;
    }
    const driver = join(farm.root, "jiti-driver.mjs");
    writeFileSync(driver, jitiDriverSource(jiti, join(farm.root, "extensions", "skill-enforcer.ts")));
    const r = runNode(driver, childEnv({}));
    ok(r.json, `jiti driver produced no JSON.\nstdout:\n${r.stdout}\nstderr:\n${r.stderr}`);
    equal(r.json.loadError, null, `jiti failed to load the extension\n${describeRun(r)}`);
    equal(r.json.MODULE_DIR, join(REPO_ROOT, "extensions"), describeRun(r));
    equal(r.json.ok, true, describeRun(r));
    deepEqual(r.json.counts, { skills: 4, rules: 6 }, describeRun(r));
    ok(r.json.banner?.includes("enforcing 4 skill gates from manifest"), describeRun(r));
  });

  await test("T7/P0 — an ABSOLUTE or base-escaping AGENT_SKILLS_PREFIX cannot widen the trusted roots", () => {
    const c = armCopyFarm();
    const control = runDriver(c.driver, childEnv({}));
    equal(control.json.evilCommitBlocked, true, `control: the /tmp read must not satisfy the gate\n${describeRun(control)}`);
    // Each must be refused, and the refusal must name the right reason.
    const cases: Array<[string, RegExp]> = [
      ["/", /is absolute/],
      ["/tmp", /is absolute/],
      ["   ", /is blank/],
      [".", /not a directory UNDER/],
      ["..", /not a directory UNDER/],
      ["../../../../../../../tmp", /not a directory UNDER/],
    ];
    for (const [prefix, reason] of cases) {
      const r = runDriver(c.driver, childEnv({ AGENT_SKILLS_PREFIX: prefix }));
      equal(
        r.json.evilCommitBlocked,
        true,
        `SKILLS_PREFIX=${JSON.stringify(prefix)} must NOT make /tmp/evil/skills/<n>/SKILL.md satisfy a gate\n${describeRun(r)}`,
      );
      ok(
        r.json.logs.some((l: string) => reason.test(l) && l.includes("refused")),
        `SKILLS_PREFIX=${JSON.stringify(prefix)} must be refused with a TRUE reason (${reason})\n${describeRun(r)}`,
      );
    }
    // A legitimate SHAPE still contributes its root.
    const good = runDriver(c.driver, childEnv({ AGENT_SKILLS_PREFIX: "myskills" }));
    ok(
      !good.json.logs.some((l: string) => l.includes("refused")),
      `a legitimate shape prefix must not be refused\n${describeRun(good)}`,
    );
  });

  // LAST, so the snapshot covers EVERY child leg above (including jiti — the
  // cycle-1 review found the snapshot was taken before it, leaving that leg
  // outside the class's own claim).
  await test("hermeticity — no child run writes the developer's real ~/.pi/agent/skill-reads.json", () => {
    const after = existsSync(REAL_READS_FILE) ? readFileSync(REAL_READS_FILE, "utf-8") : null;
    equal(after, realReadsBefore, `${REAL_READS_FILE} changed — the suite must never touch the real reader cache`);
  });

  console.log(`\n${failed === 0 ? "✅" : "❌"} ${passed} passed, ${failed} failed`);
  if (failed > 0) {
    console.log("failed:\n  - " + failures.join("\n  - "));
    cleanup();
    process.exit(1);
  }
  cleanup();
}

function jitiDriverSource(jitiPath: string, extPath: string): string {
  return `
import { createJiti } from ${JSON.stringify(jitiPath)};
const logs = [];
const ol = console.log, oe = console.error;
console.log = (...a) => logs.push("log: " + a.join(" "));
console.error = (...a) => logs.push("err: " + a.join(" "));
let ns = null, loadError = null;
try {
  const jiti = createJiti(import.meta.url, { moduleCache: false });
  ns = await jiti.import(${JSON.stringify(extPath)});
} catch (e) { loadError = String((e && e.stack) || e); }
if (ns && ns.MODULE_DIR === undefined && ns.default && ns.default.MODULE_DIR) ns = ns.default;
let hookError = null;
try { if (ns && typeof ns.default === "function") ns.default({ on: () => {} }); } catch (e) { hookError = String((e && e.message) || e); }
console.log = ol; console.error = oe;
process.stdout.write(JSON.stringify({
  loadError, hookError, logs,
  MODULE_DIR: ns && ns.MODULE_DIR,
  REPO_DIR: ns && ns.REPO_DIR,
  MANIFEST_PATH: ns && ns.MANIFEST_PATH,
  source: ns && ns.MANIFEST_RESOLUTION && ns.MANIFEST_RESOLUTION.source,
  ok: ns && ns.MANIFEST_LOAD && ns.MANIFEST_LOAD.ok,
  error: ns && ns.MANIFEST_LOAD && ns.MANIFEST_LOAD.error,
  counts: ns && ns.manifestCounts ? ns.manifestCounts() : null,
  banner: ns && ns.manifestBanner ? ns.manifestBanner(ns.MANIFEST_LOAD, ns.MANIFEST_PATH) : null,
}, null, 1));
`;
}

function runNode(driver: string, env: NodeJS.ProcessEnv) {
  const res = spawnSync(process.execPath, [driver], { env, cwd: dirname(driver), encoding: "utf8", timeout: 240000 });
  const stdout = res.stdout ?? "";
  let json: any = null;
  const start = stdout.indexOf("{");
  if (start >= 0) {
    try { json = JSON.parse(stdout.slice(start)); } catch { /* leave null */ }
  }
  return { status: res.status ?? -1, stdout, stderr: res.stderr ?? "", json };
}

main().catch(err => {
  console.error(err);
  cleanup();
  process.exit(1);
});
