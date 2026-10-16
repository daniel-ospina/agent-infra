/**
 * skill-registry.test.ts — #1323: the skill farm must work on every repo, or
 * say so.
 *
 * Run: npx tsx extensions/skill-registry.test.ts   (from any agent-infra checkout)
 *
 * Zero-dep by construction: `skill-registry.ts` has no runtime import outside
 * `node:*` (the pi SDK import is TYPE-only and erased by tsx), so this suite runs
 * on a bare checkout with no `npm ci` — asserted, not assumed (see the
 * import-surface section at the end).
 *
 * ── What the suite pins, and why each leg is worth its lines ─────────────────
 * #1323's four indicators, one section each:
 *   1. no warning naming a path that cannot exist  → "source of the warning"
 *   2. an empty input never reads as success        → "empty is not success"
 *   3. a stale farm copy is surfaced                → "staleness"
 *   4. no regression for the layout it replaced     → "source discovery"
 * Plus the two hazards the rewrite introduces and MUST therefore prove it
 * handles: a SYMLINKED farm (never write through it) and a LINKED WORKTREE
 * (never link a sandbox into the machine's farm).
 *
 * Negative controls are first-class: a foreign live symlink must NOT be
 * removed, a diverging farm copy must NOT be overwritten (asserted byte-for-byte),
 * a dangling link that matches no source must NOT be touched, and a healthy
 * farm must produce NO output at all.
 */
import { equal, deepEqual, ok, strictEqual } from "node:assert/strict";
import {
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readlinkSync,
  readdirSync,
  realpathSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

import hook, {
  HASH_MAX_BYTES,
  MODULE_DIR,
  REPO_DIR,
  SKILL_ROOT_SHAPES,
  _setSyncOptionsForTest,
  collectSources,
  defaultFarmDir,
  dirSignature,
  enumerateSkills,
  isLinkedWorktree,
  projectRoot,
  runSync,
} from "./skill-registry.js";

const REPO_ROOT = resolve(__dirname, "..");
const MODULE_SRC = join(REPO_ROOT, "extensions", "skill-registry.ts");

let passed = 0;
const failures: string[] = [];
async function test(name: string, fn: () => void | Promise<void>) {
  try {
    await fn();
    passed += 1;
    console.log(`  ✅ ${name}`);
  } catch (err) {
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
  for (const d of TMP) rmSync(d, { recursive: true, force: true });
}

// ── fixtures ─────────────────────────────────────────────────────────────────
function writeSkill(root: string, shape: readonly string[], name: string, extra: Record<string, string> = {}): string {
  const dir = join(root, ...shape, name);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "SKILL.md"), `---\nname: ${name}\ndescription: ${name} skill\n---\n\n# ${name}\n`);
  for (const [rel, content] of Object.entries(extra)) {
    const p = join(dir, rel);
    mkdirSync(dirname(p), { recursive: true });
    writeFileSync(p, content);
  }
  return dir;
}
function fakePi() {
  const handlers: Record<string, Array<() => unknown>> = {};
  return {
    on(name: string, fn: () => unknown) {
      (handlers[name] ??= []).push(fn);
    },
    async fire(name: string) {
      for (const fn of handlers[name] ?? []) await fn();
    },
  };
}
async function withConsole(fn: () => Promise<void>): Promise<{ logs: string[]; warns: string[]; errors: string[] }> {
  const logs: string[] = [];
  const warns: string[] = [];
  const errors: string[] = [];
  const prev = [console.log, console.warn, console.error];
  console.log = (...a: unknown[]) => void logs.push(a.join(" "));
  console.warn = (...a: unknown[]) => void warns.push(a.join(" "));
  console.error = (...a: unknown[]) => void errors.push(a.join(" "));
  try {
    await fn();
    return { logs, warns, errors };
  } finally {
    [console.log, console.warn, console.error] = prev;
  }
}
/** The handler's view, driven against fixtures — never the real ~/.pi. */
async function fireHandler(farm: string, projectRootDir: string, moduleRoot: string) {
  _setSyncOptionsForTest({ farm, projectRoot: projectRootDir, moduleRoot });
  const pi = fakePi();
  hook(pi as never);
  try {
    return await withConsole(async () => {
      await pi.fire("session_start");
    });
  } finally {
    _setSyncOptionsForTest(null);
  }
}
function git(cwd: string, args: string[]) {
  const r = spawnSync("git", args, { cwd, encoding: "utf-8" });
  if (r.status !== 0) throw new Error(`git ${args.join(" ")} failed in ${cwd}: ${r.stderr}`);
  return r.stdout.trim();
}
/** A real main checkout (and optionally a linked worktree off it). */
function mainCheckout(): { main: string; linked: string } {
  const main = tmpDir("sr-main-");
  git(main, ["init", "-q"]);
  git(main, ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init"]);
  const linked = join(tmpDir("sr-wt-"), "wt");
  git(main, ["worktree", "add", "-q", "--detach", linked, "HEAD"]);
  return { main, linked };
}

// ── source discovery (indicator 4) ───────────────────────────────────────────
async function main() {
section("source discovery — the shape's layout must keep working (indicator 4)");

await test("every known skill root shape is enumerated, and only dirs holding SKILL.md are skills", () => {
  const root = tmpDir("sr-shapes-");
  const names: string[] = [];
  for (const shape of SKILL_ROOT_SHAPES) {
    const n = `sk-${shape.join("-")}`;
    writeSkill(root, shape, n);
    names.push(n);
  }
  mkdirSync(join(root, "skills", "not-a-skill"), { recursive: true }); // no SKILL.md
  writeFileSync(join(root, "skills", "plain-file"), "x");
  mkdirSync(join(root, "skills", ".hidden"), { recursive: true });
  writeFileSync(join(root, "skills", ".hidden", "SKILL.md"), "x");

  const found = enumerateSkills(root);
  deepEqual(found.skills.map((s) => s.name).sort(), [...names].sort());
  deepEqual(found.errors, []);
  // The eldato/consumer shape is one of them — the layout the old probe served.
  ok(found.skills.some((s) => s.root === join(root, "operations", "skills")));
});

await test("a symlinked skill dir is followed; a BROKEN link is skipped, not fatal", () => {
  const root = tmpDir("sr-link-");
  const real = writeSkill(tmpDir("sr-real-"), ["skills"], "target");
  const skills = join(root, "skills");
  mkdirSync(skills, { recursive: true });
  symlinkSync(real, join(skills, "aliased"), "dir");
  symlinkSync(join(root, "gone"), join(skills, "broken"), "dir");

  const found = enumerateSkills(root);
  deepEqual(found.skills.map((s) => s.name), ["aliased"]);
  deepEqual(found.errors, []);
});

await test("a skill root that exists but cannot be read is an ERROR, not 'no skills'", () => {
  const root = tmpDir("sr-enotdir-");
  writeFileSync(join(root, "skills"), "not a directory"); // readdir → ENOTDIR
  const found = enumerateSkills(root);
  deepEqual(found.skills, []);
  equal(found.errors.length, 1);
  ok(found.errors[0].includes(join(root, "skills")), "the error must name the unreadable root");
});

await test("shape precedence: a name in `skills/` wins over the same name in `operations/skills/`", () => {
  const project = tmpDir("sr-dedup-");
  const a = writeSkill(project, ["skills"], "same");
  writeSkill(project, ["operations", "skills"], "same");
  const farm = join(tmpDir("sr-farm-"), "skills");
  const { sources } = collectSources({ projectRoot: project, moduleRoot: project, farm });
  deepEqual(sources.map((s) => s.name), ["same"]);
  strictEqual(sources[0].dir, realpathSync(a));
});

await test("LINKED WORKTREE guard: a lane's sandbox root contributes no sources", () => {
  const { main, linked } = mainCheckout();
  strictEqual(isLinkedWorktree(main), false);
  strictEqual(isLinkedWorktree(linked), true);
  writeSkill(main, ["skills"], "from-main");
  writeSkill(linked, ["skills"], "from-worktree");

  const collected = collectSources({ projectRoot: linked, moduleRoot: main, farm: join(tmpDir("sr-f-"), "skills") });
  deepEqual(collected.sources.map((s) => s.name), ["from-main"]);
  deepEqual(collected.skippedRoots, [linked]);
});

await test("SELF-LINK guard: a root whose `skills/` IS the farm contributes nothing", () => {
  const farm = join(tmpDir("sr-self-"), "skills");
  writeSkill(farm, [], "in-farm");
  const collected = collectSources({ projectRoot: dirname(farm), moduleRoot: dirname(farm), farm });
  deepEqual(collected.sources, []);
});

// ── linking (the capability the extension exists for) ────────────────────────
section("linking — additive, idempotent, non-destructive");

await test("a missing farm is created and the project's skills are linked to it", () => {
  const project = tmpDir("sr-linkproj-");
  const one = writeSkill(project, ["operations", "skills"], "alpha");
  writeSkill(project, ["skills"], "beta");
  const farm = join(tmpDir("sr-linkfarm-"), "agent", "skills");

  const r = runSync({ farm, projectRoot: project, moduleRoot: project });
  strictEqual(r.ok, true);
  strictEqual(r.farm.mode, "created");
  deepEqual(r.linked, ["alpha", "beta"]);
  deepEqual(r.stale, []);
  strictEqual(readlinkSync(join(farm, "alpha")), realpathSync(one));
  ok(existsSync(join(farm, "beta", "SKILL.md")));
});

await test("a second run changes nothing (idempotent)", () => {
  const project = tmpDir("sr-idem-");
  writeSkill(project, ["skills"], "alpha");
  const farm = join(tmpDir("sr-idemfarm-"), "skills");
  runSync({ farm, projectRoot: project, moduleRoot: project });
  const r = runSync({ farm, projectRoot: project, moduleRoot: project });
  strictEqual(r.ok, true);
  deepEqual(r.linked, []);
  deepEqual(r.repaired, []);
  deepEqual(r.stale, []);
});

await test("NEGATIVE CONTROL: a diverging farm COPY is reported stale and never overwritten", () => {
  const project = tmpDir("sr-stale-");
  writeSkill(project, ["skills"], "alpha", { "workflow/step.md": "NEW" });
  const farm = join(tmpDir("sr-stalefarm-"), "skills");
  const copy = join(farm, "alpha");
  mkdirSync(copy, { recursive: true });
  writeFileSync(join(copy, "SKILL.md"), "OLD BYTES\n");
  writeFileSync(join(copy, "workflow-step.md"), "OLD\n");

  const r = runSync({ farm, projectRoot: project, moduleRoot: project });
  deepEqual(r.stale, ["alpha"]);
  deepEqual(r.linked, []);
  strictEqual(readFileSync(join(copy, "SKILL.md"), "utf-8"), "OLD BYTES\n"); // untouched
  strictEqual(lstatSync(copy).isSymbolicLink(), false); // still a real directory
});

await test("a farm copy that EQUALS its source is neither stale nor relinked", () => {
  const project = tmpDir("sr-equal-");
  const src = writeSkill(project, ["skills"], "alpha", { "workflow/step.md": "SAME" });
  const farm = join(tmpDir("sr-equalfarm-"), "skills");
  mkdirSync(join(farm, "alpha"), { recursive: true });
  for (const rel of ["SKILL.md", "workflow/step.md"]) {
    mkdirSync(dirname(join(farm, "alpha", rel)), { recursive: true });
    writeFileSync(join(farm, "alpha", rel), readFileSync(join(src, rel)));
  }
  const r = runSync({ farm, projectRoot: project, moduleRoot: project });
  deepEqual(r.stale, []);
  deepEqual(r.linked, []);
});

await test("a change to a supporting file (SKILL.md unchanged) is still detected as staleness", () => {
  const project = tmpDir("sr-sub-");
  const src = writeSkill(project, ["skills"], "alpha", { "workflow/step.md": "NEW" });
  const farm = join(tmpDir("sr-subfarm-"), "skills");
  mkdirSync(join(farm, "alpha", "workflow"), { recursive: true });
  writeFileSync(join(farm, "alpha", "SKILL.md"), readFileSync(join(src, "SKILL.md")));
  writeFileSync(join(farm, "alpha", "workflow", "step.md"), "OLD");
  const r = runSync({ farm, projectRoot: project, moduleRoot: project });
  deepEqual(r.stale, ["alpha"]);
});

await test("NEGATIVE CONTROL: the staleness walk NEVER dereferences a symlink (the #1051 class)", () => {
  const project = tmpDir("sr-loop-");
  const dir = writeSkill(project, ["skills"], "alpha");
  symlinkSync(dir, join(dir, "self"), "dir"); // a self-loop
  symlinkSync("/", join(dir, "root"), "dir"); // a link to the FILESYSTEM ROOT

  const sig = dirSignature(dir);
  ok(sig, "a signature must be produced");
  ok(sig.includes("self:LINK:"), sig);
  ok(sig.includes("root:LINK:/"), sig);
  strictEqual(sig.includes("DEPTH-LIMIT"), false, "no descent at all into a symlink — not even bounded descent");
  // The property must not break the comparison: identical links compare EQUAL.
  const farm = join(tmpDir("sr-loopfarm-"), "skills");
  const copy = join(farm, "alpha");
  mkdirSync(copy, { recursive: true });
  writeFileSync(join(copy, "SKILL.md"), readFileSync(join(dir, "SKILL.md")));
  symlinkSync(dir, join(copy, "self"), "dir");
  symlinkSync("/", join(copy, "root"), "dir");
  const r = runSync({ farm, projectRoot: project, moduleRoot: project });
  strictEqual(r.ok, true);
  deepEqual(r.stale, []);
});

await test("NEGATIVE CONTROL: a live foreign symlink is left alone and not reported", () => {
  const project = tmpDir("sr-foreign-");
  writeSkill(project, ["skills"], "alpha");
  const elsewhere = writeSkill(tmpDir("sr-elsewhere-"), ["skills"], "alpha");
  const farm = join(tmpDir("sr-foreignfarm-"), "skills");
  mkdirSync(farm, { recursive: true });
  symlinkSync(elsewhere, join(farm, "alpha"), "dir");

  const r = runSync({ farm, projectRoot: project, moduleRoot: project });
  ok(r.ok);
  deepEqual(r.linked, []);
  deepEqual(r.repaired, []);
  deepEqual(r.stale, []);
  deepEqual(r.conflicts, []);
  strictEqual(readlinkSync(join(farm, "alpha")), elsewhere); // still the foreign target
});
await test("a DANGLING link whose name matches a source is repaired to that source", () => {
  const project = tmpDir("sr-dangle-");
  const src = writeSkill(project, ["skills"], "alpha");
  const farm = join(tmpDir("sr-danglefarm-"), "skills");
  mkdirSync(farm, { recursive: true });
  symlinkSync(join(tmpDir("sr-moved-"), "old-location"), join(farm, "alpha"), "dir");

  const r = runSync({ farm, projectRoot: project, moduleRoot: project });
  deepEqual(r.repaired, ["alpha"]);
  deepEqual(r.linked, []);
  strictEqual(readlinkSync(join(farm, "alpha")), realpathSync(src));
});

await test("NEGATIVE CONTROL: a dangling link that matches NO source is not touched", () => {
  const project = tmpDir("sr-dangle2-");
  writeSkill(project, ["skills"], "alpha");
  const farm = join(tmpDir("sr-dangle2farm-"), "skills");
  mkdirSync(farm, { recursive: true });
  const orphan = join(tmpDir("sr-orphan-"), "gone");
  symlinkSync(orphan, join(farm, "unrelated"), "dir");

  const r = runSync({ farm, projectRoot: project, moduleRoot: project });
  deepEqual(r.repaired, []);
  deepEqual(r.linked, ["alpha"]);
  strictEqual(readlinkSync(join(farm, "unrelated")), orphan);
});

await test("a plain FILE where a skill belongs is a conflict — reported, never replaced", () => {
  const project = tmpDir("sr-conflict-");
  writeSkill(project, ["skills"], "alpha");
  const farm = join(tmpDir("sr-conflictfarm-"), "skills");
  mkdirSync(farm, { recursive: true });
  writeFileSync(join(farm, "alpha"), "I am a file");

  const r = runSync({ farm, projectRoot: project, moduleRoot: project });
  deepEqual(r.conflicts, ["alpha"]);
  deepEqual(r.linked, []);
  strictEqual(readFileSync(join(farm, "alpha"), "utf-8"), "I am a file");
});

// ── delegated (symlinked) farm ───────────────────────────────────────────────
section("delegated farm — never write through a symlink");

await test("a symlinked farm is not written to; source skills it lacks are REPORTED", () => {
  const project = tmpDir("sr-deleg-");
  writeSkill(project, ["skills"], "present");
  writeSkill(project, ["skills"], "absent");
  const delegated = tmpDir("sr-delegated-");
  mkdirSync(join(delegated, "present"), { recursive: true });
  writeFileSync(join(delegated, "present", "SKILL.md"), "---\nname: present\n---\n");
  const farmLink = join(tmpDir("sr-delegfarm-"), "skills");
  symlinkSync(delegated, farmLink, "dir");

  const before = readdirSync(delegated).sort();
  const r = runSync({ farm: farmLink, projectRoot: project, moduleRoot: project });
  strictEqual(r.farm.mode, "symlink");
  strictEqual(r.farm.realPath, realpathSync(delegated));
  deepEqual(r.missing, ["absent"]);
  deepEqual(r.linked, []);
  deepEqual(before, readdirSync(delegated).sort()); // nothing written through the link
});

await test("a dangling farm symlink is a loud failure — nothing is created", () => {
  const project = tmpDir("sr-badfarm-");
  writeSkill(project, ["skills"], "alpha");
  const gone = join(tmpDir("sr-gonetarget-"), "nope");
  const farmLink = join(tmpDir("sr-badfarmlink-"), "skills");
  symlinkSync(gone, farmLink, "dir");

  const r = runSync({ farm: farmLink, projectRoot: project, moduleRoot: project });
  strictEqual(r.ok, false);
  equal(r.errors.length, 1);
  ok(r.errors[0].includes(gone));
  strictEqual(existsSync(gone), false);
});

await test("a farm path that is a FILE is a loud failure", () => {
  const project = tmpDir("sr-filefarm-");
  writeSkill(project, ["skills"], "alpha");
  const farm = join(tmpDir("sr-filefarmdir-"), "skills");
  writeFileSync(farm, "not a directory");

  const r = runSync({ farm, projectRoot: project, moduleRoot: project });
  strictEqual(r.ok, false);
  equal(r.farm.mode, "unusable");
  equal(r.errors.length, 1);
});

await test("an unreadable source root fails loudly while the readable one still syncs", () => {
  const project = tmpDir("sr-badsrc-");
  writeFileSync(join(project, "skills"), "not a directory"); // ENOTDIR
  const good = tmpDir("sr-goodsrc-");
  writeSkill(good, ["skills"], "alpha");
  const farm = join(tmpDir("sr-mixfarm-"), "skills");

  const r = runSync({ farm, projectRoot: project, moduleRoot: good });
  strictEqual(r.ok, false); // an input that could not be read is NEVER a pass
  equal(r.errors.length, 1);
  deepEqual(r.linked, ["alpha"]); // the readable root still made progress
});

// ── empty is not success (indicator 2) ───────────────────────────────────────
section("empty is not success (indicator 2)");

await test("NEGATIVE CONTROL: with no sources, the handler prints NOTHING at all", async () => {
  const empty = tmpDir("sr-empty-");
  const empty2 = tmpDir("sr-empty2-");
  const farm = join(tmpDir("sr-emptyfarm-"), "skills");
  const out = await fireHandler(farm, empty, empty2);
  deepEqual(out, { logs: [], warns: [], errors: [] });
  strictEqual(existsSync(farm), false, "an empty source set must not even create a farm");
});

await test("the report's `ok` is true ONLY when no error was recorded", () => {
  const project = tmpDir("sr-ok-");
  writeSkill(project, ["skills"], "alpha");
  const farm = join(tmpDir("sr-okfarm-"), "skills");
  const healthy = runSync({ farm, projectRoot: project, moduleRoot: project });
  strictEqual(healthy.ok, true);
  const noRoots = runSync({ farm, projectRoot: join(project, "skills"), moduleRoot: join(project, "skills") });
  strictEqual(noRoots.ok, true); // a project with no skill roots at all is NOT an error
  deepEqual(noRoots.sources, []);
  const unusableFarm = join(tmpDir("sr-okfarm2-"), "skills");
  writeFileSync(unusableFarm, "not a directory");
  const unusable = runSync({ farm: unusableFarm, projectRoot: project, moduleRoot: project });
  strictEqual(unusable.ok, false);
});

await test("the handler prints a success line ONLY when it changed something", async () => {
  const project = tmpDir("sr-handler-");
  writeSkill(project, ["skills"], "alpha");
  const farm = join(tmpDir("sr-handlerfarm-"), "skills");

  const first = await fireHandler(farm, project, project);
  equal(first.logs.length, 1);
  ok(first.logs[0].includes("linked 1"), first.logs[0]);
  deepEqual(first.warns, []);
  deepEqual(first.errors, []);

  const second = await fireHandler(farm, project, project);
  deepEqual(second, { logs: [], warns: [], errors: [] });
});

// ── staleness + failures are surfaced (indicators 2 and 3) ───────────────────
section("staleness and failure reporting (indicators 2 and 3)");

await test("a stale farm copy is named, with a remedy that EXISTS on this machine", async () => {
  const project = tmpDir("sr-stalehandler-");
  writeSkill(project, ["skills"], "alpha");
  const farm = join(tmpDir("sr-stalehandlerfarm-"), "skills");
  mkdirSync(join(farm, "alpha"), { recursive: true });
  writeFileSync(join(farm, "alpha", "SKILL.md"), "OLD");

  const out = await fireHandler(farm, project, project);
  equal(out.warns.length, 1);
  ok(out.warns[0].includes("alpha"), out.warns[0]);
  ok(out.warns[0].includes("STALE COPIES"), out.warns[0]);
  const remedy = out.warns[0].match(/"([^"]*sync\.sh)"/)?.[1];
  ok(remedy, `the remedy must be named: ${out.warns[0]}`);
  ok(existsSync(remedy as string), `the named remedy must exist: ${remedy}`);
  deepEqual(out.logs, []); // a stale copy is not a success
  deepEqual(out.errors, []);
});

await test("a delegated farm names the skills pi cannot see", async () => {
  const project = tmpDir("sr-deleghandler-");
  writeSkill(project, ["skills"], "absent");
  const delegated = tmpDir("sr-deleghandlerreal-");
  const farmLink = join(tmpDir("sr-deleghandlerfarm-"), "skills");
  symlinkSync(delegated, farmLink, "dir");

  const out = await fireHandler(farmLink, project, project);
  equal(out.warns.length, 1);
  ok(out.warns[0].includes("absent"), out.warns[0]);
  ok(out.warns[0].includes(realpathSync(delegated)), out.warns[0]);
  deepEqual(out.logs, []);
});

await test("a failure is an ERROR line and never a success line", async () => {
  const project = tmpDir("sr-errorhandler-");
  writeSkill(project, ["skills"], "alpha");
  const farm = join(tmpDir("sr-errorhandlerfarm-"), "skills");
  writeFileSync(farm, "not a directory");

  const out = await fireHandler(farm, project, project);
  deepEqual(out.logs, []);
  equal(out.errors.length, 1);
  ok(out.errors[0].startsWith("[skill-registry] ❌"), out.errors[0]);
});

await test("the handler can never crash session startup (hostile paths)", async () => {
  const project = tmpDir("sr-crashproj-");
  writeSkill(project, ["skills"], "alpha");
  const notADir = join(tmpDir("sr-crashfile-"), "regular-file");
  writeFileSync(notADir, "x");
  const cases: Array<{ farm: string; projectRoot: string; moduleRoot: string }> = [
    { farm: "\u0000/not/a/path", projectRoot: "\u0000", moduleRoot: "\u0000" },
    { farm: join(notADir, "skills"), projectRoot: project, moduleRoot: project }, // mkdir → ENOTDIR
    { farm: join(tmpDir("sr-crashfarm-"), "skills"), projectRoot: project, moduleRoot: "\u0000" },
  ];
  for (const opts of cases) {
    _setSyncOptionsForTest(opts);
    const pi = fakePi();
    hook(pi as never);
    try {
      const out = await withConsole(async () => {
        await pi.fire("session_start"); // must RESOLVE, never reject
      });
      if (out.errors.length > 0) ok(out.errors[0].startsWith("[skill-registry] ❌"), out.errors[0]);
      if (out.errors.length > 0) deepEqual(out.logs, []); // never a success line beside a failure
    } finally {
      _setSyncOptionsForTest(null);
    }
  }
  // The un-creatable farm is the one that MUST be loud.
  _setSyncOptionsForTest({ farm: join(notADir, "skills"), projectRoot: project, moduleRoot: project });
  const pi = fakePi();
  hook(pi as never);
  try {
    const out = await withConsole(async () => {
      await pi.fire("session_start");
    });
    equal(out.errors.length, 1);
    ok(out.errors[0].includes("cannot create the skill farm"), out.errors[0]);
  } finally {
    _setSyncOptionsForTest(null);
  }
});

// ── the warning #1323 was filed for ──────────────────────────────────────────
section("source of the warning (indicator 1)");

await test("nothing in a repo with no `operations/` can name a path inside it", async () => {
  const project = tmpDir("sr-noops-");
  writeSkill(project, ["skills"], "alpha");
  deepEqual(enumerateSkills(project).errors, []);
  const farm = join(tmpDir("sr-noopsfarm-"), "skills");
  const out = await fireHandler(farm, project, project);
  const text = [...out.logs, ...out.warns, ...out.errors].join("\n");
  strictEqual(text.includes("skill_registry.py"), false);
  strictEqual(text.includes("AGENT_INFRA_PATH"), false);
  strictEqual(text.includes("operations/tools"), false);
  equal(out.logs.length, 1); // it actually did the job instead of warning
});

await test("the module carries no Python generator and no env-var path fallback", () => {
  const src = readFileSync(MODULE_SRC, "utf-8");
  // Scan CODE, not prose: the header explains the defect it removed, which is
  // the one place those literals are still allowed to appear.
  const code = src
    .split("\n")
    .filter((line) => {
      const t = line.trim();
      return !(t.startsWith("//") || t.startsWith("*") || t.startsWith("/*"));
    })
    .join("\n");
  for (const banned of ["skill_registry.py", "AGENT_INFRA_PATH", "skills-registry.json"]) {
    strictEqual(code.includes(banned), false, `${banned} must be gone from the code (the unreachable path of #1323)`);
  }
  ok(src.includes("skill_registry.py"), "the header must still record WHAT was removed and why");
});

// ── real-repo smoke + module surface ─────────────────────────────────────────
section("smoke tests on this checkout");

await test("the module resolves its own repo by REALPATH, not by `__dirname` (#1321 discipline)", () => {
  strictEqual(MODULE_DIR, realpathSync(MODULE_DIR));
  strictEqual(REPO_DIR, resolve(__dirname, ".."));
  ok(existsSync(join(REPO_DIR, "skills")), `${REPO_DIR}/skills must exist`);
  ok(existsSync(join(REPO_DIR, "extensions", "skill-registry.ts")));
  strictEqual(defaultFarmDir("/home/x"), "/home/x/.pi/agent/skills");
});

await test("a real checkout links its whole skill set into a fresh farm (> 50, non-vacuity floor)", () => {
  const { main } = mainCheckout();
  rmSync(join(main, "skills"), { recursive: true, force: true });
  // Copy the real skills into the fixture so the count is this repo's, not a stub.
  const target = join(main, "skills");
  mkdirSync(target, { recursive: true });
  for (const entry of readdirSync(join(REPO_ROOT, "skills"))) {
    if (!existsSync(join(REPO_ROOT, "skills", entry, "SKILL.md"))) continue;
    mkdirSync(join(target, entry), { recursive: true });
    writeFileSync(join(target, entry, "SKILL.md"), readFileSync(join(REPO_ROOT, "skills", entry, "SKILL.md")));
  }
  const farm = join(tmpDir("sr-smokefarm-"), "skills");
  const r = runSync({ farm, projectRoot: main, moduleRoot: main });
  strictEqual(r.ok, true);
  ok(r.linked.length > 50, `expected the real skill set, linked ${r.linked.length}`);
  for (const name of r.linked) ok(existsSync(join(farm, name, "SKILL.md")));
});

await test("the module has no runtime import outside `node:*` (zero-dep — runs with no npm ci)", () => {
  const src = readFileSync(MODULE_SRC, "utf-8");
  const specifiers = [...src.matchAll(/from\s+"([^"]+)"/g)].map((m) => m[1]);
  ok(specifiers.length > 0);
  for (const spec of specifiers) {
    ok(spec.startsWith("node:") || spec === "@earendil-works/pi-coding-agent", `unexpected import: ${spec}`);
  }
  ok(
    src.includes('import type { ExtensionAPI } from "@earendil-works/pi-coding-agent"'),
    "the pi SDK import must stay TYPE-only",
  );
});

await test("the fallback of `projectRoot` is cwd, and the constants are coherent", () => {
  const dir = tmpDir("sr-nogit-");
  strictEqual(projectRoot(dir), dir); // not a work tree → cwd itself
  strictEqual(HASH_MAX_BYTES > 0, true);
  strictEqual(dirSignature(dir), null); // an empty tree has no signature
});

// ── the deployed layout (the #1321 mechanism) ────────────────────────────────
section("deployed layout — loaded through a farm symlink (the #1321 mechanism)");

await test("T8/T1 — a farm-symlinked module still resolves the REAL repo, and links the project", () => {
  const farmRoot = tmpDir("sr-farmload-");
  const ext = join(farmRoot, "extensions");
  mkdirSync(ext, { recursive: true });
  symlinkSync(join(REPO_ROOT, "extensions", "skill-registry.ts"), join(ext, "skill-registry.ts"));
  // Loader precondition: a symlink whose TARGET is outside this directory, so
  // `__dirname` and `realpathSync(__filename)` can be compared. Without the
  // precondition the leg could pass vacuously after a loader upgrade.
  const probeReal = join(farmRoot, "probe-real");
  mkdirSync(probeReal, { recursive: true });
  writeFileSync(
    join(probeReal, "probe.cjs"),
    "module.exports = { dir: __dirname, real: require('node:fs').realpathSync(__filename) };\n",
  );
  symlinkSync(join(probeReal, "probe.cjs"), join(ext, "probe.cjs"));

  const { main } = mainCheckout();
  writeSkill(main, ["skills"], "linked-from-farm");
  const driver = join(farmRoot, "driver.cjs");
  writeFileSync(
    driver,
    `const path = require("node:path");
(async () => {
  let probe = null;
  try { const p = require("./extensions/probe.cjs"); probe = { dir: p.dir, real: p.real, preserved: p.dir !== p.real }; }
  catch (e) { probe = { error: String(e && e.message) }; }
  let mod = null, loadError = null;
  try { mod = require("./extensions/skill-registry.ts"); } catch (e) { loadError = String((e && e.stack) || e); }
  if (!mod) { process.stdout.write(JSON.stringify({ probe, loadError })); return; }
  const handlers = [];
  mod.default({ on: (n, f) => handlers.push(f) });
  const farm = path.join(process.env.SR_FARM, "skills");
  mod._setSyncOptionsForTest({ farm, projectRoot: process.env.SR_PROJECT, moduleRoot: mod.REPO_DIR });
  const logs = [];
  const [ol, ow, oe] = [console.log, console.warn, console.error];
  console.log = (...a) => logs.push("log: " + a.join(" "));
  console.warn = (...a) => logs.push("warn: " + a.join(" "));
  console.error = (...a) => logs.push("err: " + a.join(" "));
  await handlers[0]();
  console.log = ol; console.warn = ow; console.error = oe;
  const fs = require("node:fs");
  const linked = fs.existsSync(farm) ? fs.readdirSync(farm).sort() : [];
  process.stdout.write(JSON.stringify({ probe, loadError, MODULE_DIR: mod.MODULE_DIR, REPO_DIR: mod.REPO_DIR, linked, logs }));
})();`,
  );
  const res = spawnSync("npx", ["tsx", driver], {
    cwd: farmRoot,
    env: { ...process.env, NODE_OPTIONS: "--preserve-symlinks", SR_FARM: farmRoot, SR_PROJECT: main },
    encoding: "utf8",
    timeout: 240000,
  });
  const start = res.stdout.indexOf("{");
  const json = start >= 0 ? JSON.parse(res.stdout.slice(start)) : null;
  ok(json, `driver produced no JSON.\nstdout:\n${res.stdout}\nstderr:\n${res.stderr}`);
  strictEqual(json.probe?.preserved, true, `loader precondition failed (probe=${JSON.stringify(json.probe)}) — this leg must be re-derived`);
  strictEqual(json.loadError, null, `module failed to load: ${json.loadError}`);
  strictEqual(realpathSync(json.MODULE_DIR), realpathSync(join(REPO_ROOT, "extensions")));
  strictEqual(realpathSync(json.REPO_DIR), realpathSync(REPO_ROOT));
  deepEqual(json.linked, ["linked-from-farm"]);
  equal(json.logs.length, 1);
});

// ── summary ──────────────────────────────────────────────────────────────────
cleanup();
console.log(`\n${failures.length === 0 ? "✅" : "❌"} ${passed} passed, ${failures.length} failed`);
if (failures.length > 0) {
  for (const f of failures) console.log(`   - ${f}`);
  process.exit(1);
}
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
