#!/usr/bin/env node
/**
 * check-version-stamp.test.mjs — the suite that keeps `check-version-stamp.mjs` from going
 * vacuously green (agent-infra#1760).
 *
 * THE POINT OF THIS FILE. A version-drift check that always says `in-sync` is worse than no
 * check: it certifies a surface nobody verified. So every verdict is pinned by a MUTATION that
 * removes the thing the verdict depends on — delete the stamp and the check must go red, edit
 * one installed byte and it must go red, move the install off main's line and it must go red —
 * and each mutation is preceded by a CONTROL assertion that the unmutated surface is green, so a
 * suite that passed by refusing everything could not masquerade as correct.
 *
 * THE ONE ARM THAT MATTERS MOST is `mutation: an off-main-line commit is drift`: it builds a
 * commit that `git rev-list --count` calls **1** away from main while
 * `git merge-base --is-ancestor` says NO, and asserts the verdict is `drift`. That is the
 * measured fact this check exists for (#1760: `e8d5ce29` vs `origin/main`), and pinning it is
 * what stops a future "simplification" back to a commit count.
 *
 * Zero dependencies (node stdlib only), like the repo's other `scripts/check-*.test.mjs` suites.
 * Run: node scripts/check-version-stamp.test.mjs
 */

import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const CLI = path.join(REPO_ROOT, "scripts", "check-version-stamp.mjs");

let passed = 0;
let failed = 0;
const failures = [];

function ok(label) {
  passed += 1;
  console.log(`   ✅ ${label}`);
}
function bad(label, detail) {
  failed += 1;
  failures.push(label);
  console.log(`   ❌ ${label}`);
  if (detail !== undefined) console.log(`      ${String(detail).split("\n").join("\n      ")}`);
}
function eq(label, actual, expected) {
  if (actual === expected) ok(label);
  else bad(label, `expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}
function contains(label, haystack, needle, shouldContain = true) {
  // `shouldContain=false` is the negative assertion the arms need ("the reason must NOT print a
  // commit count"). It used to be silently ignored — the flag was passed but this signature did not
  // accept it, so a "must not contain" silently became a "must contain" and asserted the opposite
  // of its own label.
  const has = String(haystack).includes(needle);
  if (has === shouldContain) ok(label);
  else bad(label, shouldContain
    ? `expected to contain ${JSON.stringify(needle)}; got:\n${haystack}`
    : `expected NOT to contain ${JSON.stringify(needle)}; got:\n${haystack}`);
}

/** Run the CLI. Never throws — the exit code IS the assertion target. */
function run(args, opts = {}) {
  try {
    const stdout = execFileSync(process.execPath, [CLI, ...args], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
      cwd: opts.cwd ?? REPO_ROOT,
    });
    return { code: 0, stdout, stderr: "" };
  } catch (err) {
    return { code: err.status ?? -1, stdout: err.stdout ?? "", stderr: err.stderr ?? "" };
  }
}

function git(cwd, ...args) {
  return execFileSync("git", ["-C", cwd, ...args], { encoding: "utf8" }).trim();
}

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "version-stamp-test-"));
const ORIGIN = path.join(TMP, "agent-infra");
const SURFACE = path.join(TMP, "surface");

function write(rel, body, base) {
  const abs = path.join(base, rel);
  fs.mkdirSync(path.dirname(abs), { recursive: true });
  fs.writeFileSync(abs, body);
}

/** The fixture agent-infra checkout: a real git repo so ancestry is genuinely exercised. */
function makeOrigin() {
  fs.mkdirSync(ORIGIN, { recursive: true });
  git(ORIGIN, "init", "-q", "-b", "main");
  git(ORIGIN, "config", "user.email", "t@example.invalid");
  git(ORIGIN, "config", "user.name", "test");
  write("manifest.json", JSON.stringify({ version: "0.1.0", files: {} }, null, 2) + "\n", ORIGIN);
  write("extensions/alpha.ts", "export const alpha = 1;\n", ORIGIN);
  write("skills/one/SKILL.md", "# one\n", ORIGIN);
  write("scripts/one.sh", "#!/bin/bash\necho one\n", ORIGIN);
  git(ORIGIN, "add", "-A");
  git(ORIGIN, "commit", "-q", "-m", "base");
}

/** An installed surface: the payload as a real directory of copies, as a hand-install looks. */
function makeSurface() {
  for (const rel of ["extensions/alpha.ts", "skills/one/SKILL.md", "scripts/one.sh"]) {
    write(rel, fs.readFileSync(path.join(ORIGIN, rel), "utf8"), SURFACE);
  }
  fs.writeFileSync(path.join(SURFACE, ".agent-infra-version"), "0.1.0\n");
}

function stamp(cur = SURFACE) {
  return JSON.parse(fs.readFileSync(path.join(cur, ".agent-infra-stamp.json"), "utf8"));
}
function writeStampRaw(cur, obj) {
  fs.writeFileSync(path.join(cur, ".agent-infra-stamp.json"), JSON.stringify(obj, null, 2) + "\n");
}
function clearStamp(cur = SURFACE) {
  fs.rmSync(path.join(cur, ".agent-infra-stamp.json"), { force: true });
}
function verify(...extra) {
  return run(["--surface", SURFACE, "--repo", ORIGIN, "--ref", "main", "--no-fetch", "--quiet", ...extra]);
}
function stampNow() {
  return run(["--write", "--surface", SURFACE, "--repo", ORIGIN]);
}

console.log("== check-version-stamp suite (agent-infra#1760) ==\n");

try {
  makeOrigin();
  makeSurface();

  // ── 1. the control: a stamped surface is green ────────────────────────────────────────────
  console.log("1. control — a freshly stamped surface is in-sync");
  {
    const w = stampNow();
    eq("--write exits 0", w.code, 0);
    eq("stamp file exists", fs.existsSync(path.join(SURFACE, ".agent-infra-stamp.json")), true);
    const s = stamp();
    eq("stamp version is 1", s.version, 1);
    eq("stamp records the install commit", s.agentInfra.commit, git(ORIGIN, "rev-parse", "HEAD"));
    eq("stamp records a payload hash", /^[0-9a-f]{64}$/.test(s.payload.hash), true);
    eq("stamp records the payload roots", JSON.stringify(s.payload.roots), JSON.stringify(["extensions", "skills", "scripts"]));
    const v = verify();
    eq("verify exits 0", v.code, 0);
    contains("verdict is in-sync", v.stdout, "in-sync");
  }

  // ── 2. THE REQUIRED MUTATION: remove the stamp → the check goes red ───────────────────────
  console.log("\n2. mutation — the stamp is REMOVED");
  {
    clearStamp();
    const v = verify();
    eq("verify exits 1 (not 0)", v.code, 1);
    contains("verdict is unstamped", v.stdout, "unstamped");
    contains("reason names the missing stamp", v.stdout, "no stamp file");
    stampNow(); // restore the control for the next arm
    eq("control restored (green again)", verify().code, 0);
  }

  // ── 3. an off-main-line commit is drift, and a commit COUNT would have said "1 behind" ────
  console.log("\n3. mutation — the install sits OFF main's line (the measured e8d5ce29 shape)");
  {
    // `side` branches from the shared base and takes one commit; `main` takes one commit of its own.
    // So `side` is 1 commit from `main` BY COUNT and is NOT an ancestor of it — the e8d5ce29 shape.
    git(ORIGIN, "checkout", "-q", "-b", "side");
    write("extensions/side.ts", "export const side = 1;\n", ORIGIN);
    git(ORIGIN, "add", "-A");
    git(ORIGIN, "commit", "-q", "-m", "side");
    const side = git(ORIGIN, "rev-parse", "HEAD");
    git(ORIGIN, "checkout", "-q", "main");
    write("extensions/mainonly.ts", "export const m = 1;\n", ORIGIN);
    git(ORIGIN, "add", "-A");
    git(ORIGIN, "commit", "-q", "-m", "main moves on");
    const mainSha = git(ORIGIN, "rev-parse", "HEAD");

    // Assert the PRECONDITION: a count-based check would report a trivially small number.
    eq("count-based distance is 1 (the lie)", git(ORIGIN, "rev-list", "--count", `${side}..main`), "1");
    let ancestor = true;
    try {
      execFileSync("git", ["-C", ORIGIN, "merge-base", "--is-ancestor", side, mainSha]);
    } catch {
      ancestor = false;
    }
    eq("but it is NOT an ancestor (the truth)", ancestor, false);

    // Now stamp the surface as if it had been installed from `side`.
    const s = stamp();
    writeStampRaw(SURFACE, { ...s, agentInfra: { ...s.agentInfra, commit: side } });
    const v = verify();
    eq("verify exits 1", v.code, 1);
    contains("verdict is drift", v.stdout, "drift");
    contains("reason says NOT an ancestor", v.stdout, "NOT an ancestor");
    contains("reason never prints a commit count", v.stdout, "behind", false);

    writeStampRaw(SURFACE, { ...s, agentInfra: { ...s.agentInfra, commit: mainSha } });
    eq("control — same surface at main's own tip is green", verify().code, 0);
  }

  // ── 4. a hand-edited install is drift, even though the commit is still on main's line ─────
  console.log("\n4. mutation — one installed byte changes (the +18.8 KB cmux-session.ts shape)");
  {
    stampNow();
    eq("control is green before the edit", verify().code, 0);
    const victim = path.join(SURFACE, "extensions", "alpha.ts");
    fs.appendFileSync(victim, "// hand-edited after install\n");
    const v = verify();
    eq("verify exits 1", v.code, 1);
    contains("verdict is drift", v.stdout, "drift");
    contains("reason is the payload hash", v.stdout, "payload hash");
    fs.writeFileSync(victim, "export const alpha = 1;\n");
    eq("control — restoring the bytes is green again", verify().code, 0);
  }

  // ── 5. files ADDED or REMOVED after stamping are drift too ───────────────────────────────
  console.log("\n5. mutation — a file is added to / removed from the installed payload");
  {
    stampNow();
    const extra = path.join(SURFACE, "scripts", "local-only.sh");
    fs.writeFileSync(extra, "#!/bin/bash\necho local\n");
    eq("added file → exit 1", verify().code, 1);
    contains("added file names the payload reason", verify().stdout, "payload hash");
    fs.rmSync(extra);

    const removed = path.join(SURFACE, "skills", "one", "SKILL.md");
    const kept = fs.readFileSync(removed);
    fs.rmSync(removed);
    eq("removed file → exit 1", verify().code, 1);
    fs.mkdirSync(path.dirname(removed), { recursive: true });
    fs.writeFileSync(removed, kept);
    eq("control — both restored is green", verify().code, 0);
  }

  // ── 5b. a whole payload ROOT that appears after stamping is drift (the fail-open arm) ─────
  // Stamping used to record only the roots that EXISTED, and verification then hashed only those
  // recorded roots — so a root absent at stamp time could never change the digest, and a surface
  // could gain an entire `extensions/` tree and still verify `in-sync`. This arm is the one that
  // fails if that narrowing ever comes back.
  console.log("\n5b. mutation — a payload ROOT appears after stamping");
  {
    const ext = path.join(SURFACE, "extensions");
    const savedAlpha = fs.readFileSync(path.join(ext, "alpha.ts"), "utf8");
    fs.rmSync(ext, { recursive: true });
    stampNow();
    eq("control — stamped with extensions/ absent is green", verify().code, 0);

    fs.mkdirSync(ext, { recursive: true });
    fs.writeFileSync(path.join(ext, "sneaky.ts"), "export const sneaky = 1;\n");
    const v = verify();
    eq("a NEW payload root is drift, not in-sync", v.code, 1);
    contains("new root names the payload reason", v.stdout, "payload hash");

    fs.rmSync(path.join(ext, "sneaky.ts"));
    fs.writeFileSync(path.join(ext, "alpha.ts"), savedAlpha);
    stampNow();
    eq("control — original root restored and re-stamped is green", verify().code, 0);
  }

  // ── 6. fail-CLOSED stamp shapes: every one of these is unstamped, never in-sync ──────────
  console.log("\n6. fail-closed — a stamp that cannot answer the question is NOT a pass");
  {
    stampNow();
    const good = stamp();

    fs.writeFileSync(path.join(SURFACE, ".agent-infra-stamp.json"), "{ not json");
    eq("unparseable stamp → exit 1", verify().code, 1);
    contains("unparseable stamp is unstamped", verify().stdout, "unstamped");

    writeStampRaw(SURFACE, { ...good, version: 999 });
    eq("wrong stamp version → exit 1", verify().code, 1);
    contains("wrong version names the version", verify().stdout, "version");

    writeStampRaw(SURFACE, { ...good, agentInfra: { ...good.agentInfra, commit: null } });
    const v = verify();
    eq("commit:null → exit 1", v.code, 1);
    contains("commit:null is unstamped", v.stdout, "unstamped");
    contains("commit:null reason names the unanswerable ancestry", v.stdout, "ancestry is unanswerable");

    writeStampRaw(SURFACE, { ...good, payload: { ...good.payload, hash: "nope" } });
    eq("malformed payload hash → exit 1", verify().code, 1);
    contains("malformed hash is unstamped", verify().stdout, "unstamped");

    writeStampRaw(SURFACE, { ...good, payload: { ...good.payload, algo: "md5" } });
    eq("wrong payload algo → exit 1", verify().code, 1);

    stampNow();
    eq("control — a good stamp after all that is green", verify().code, 0);
  }

  // ── 7. an empty / unverifiable surface set is NOT a green set ────────────────────────────
  console.log("\n7. an empty or unverifiable run exits 2, never 0");
  {
    const empty = run(["--surface", path.join(TMP, "does-not-exist"), "--repo", ORIGIN, "--ref", "main", "--no-fetch", "--quiet"]);
    // A --surface that does not exist is still a NAMED surface, so it is classified (unstamped),
    // not silently dropped — dropping it would be the "missing surface reads as absent" hole.
    eq("a named-but-absent surface is unstamped (exit 1)", empty.code, 1);
    contains("named-but-absent surface is reported unstamped", empty.stdout, "unstamped");

    const noSurfaces = run(["--surface", ""], {});
    if (noSurfaces.code !== 0) ok("a blank surface argument never exits 0");
    else bad("a blank surface argument never exits 0", noSurfaces.stdout);

    const badRef = run(["--surface", SURFACE, "--repo", ORIGIN, "--ref", "no-such-ref", "--no-fetch", "--quiet"]);
    eq("an unresolvable ref exits 2", badRef.code, 2);
    contains("unresolvable ref says cannot resolve", badRef.stderr + badRef.stdout, "cannot resolve ref");

    const badRepo = run(["--surface", SURFACE, "--repo", TMP, "--ref", "main", "--no-fetch", "--quiet"]);
    eq("a checkout with no manifest.json exits 2", badRepo.code, 2);
  }

  // ── 8. the machine-readable report ───────────────────────────────────────────────────────
  console.log("\n8. --json carries the three verdicts and the resolved target");
  {
    clearStamp();
    const v = verify("--json");
    const report = JSON.parse(v.stdout);
    eq("report names the target ref", report.ref, "main");
    eq("report carries the resolved sha", /^[0-9a-f]{40}$/.test(report.sha), true);
    eq("counts has in-sync/drift/unstamped", JSON.stringify(Object.keys(report.counts).sort()), JSON.stringify(["drift", "in-sync", "unstamped"]));
    eq("one result per surface", report.results.length, 1);
    eq("verdict is unstamped", report.results[0].verdict, "unstamped");
    eq("exit 1 accompanies the report", v.code, 1);
  }

  // ── 9. the linked-repo discovery that makes `sync`'s linked set stampable ────────────────
  console.log("\n9. default surface discovery finds a linked repo by its LEGACY pin too");
  {
    const root = path.join(TMP, "repos");
    const linked = path.join(root, "a-linked-repo");
    fs.mkdirSync(linked, { recursive: true });
    fs.writeFileSync(path.join(linked, ".agent-infra-version"), "0.1.0\n");
    const unlinked = path.join(root, "not-linked");
    fs.mkdirSync(unlinked, { recursive: true });
    const mod = await import(path.join(REPO_ROOT, "scripts", "check-version-stamp.mjs"));
    const found = mod.linkedSurfaces(root);
    eq("a repo carrying only .agent-infra-version is discovered", found.includes(linked), true);
    eq("a directory that is not linked is not discovered", found.includes(unlinked), false);
    eq("the unlinked directory is not silently counted as a surface", found.length, 1);
  }
} finally {
  fs.rmSync(TMP, { recursive: true, force: true });
}

console.log("");
if (failed === 0) {
  console.log(`✅ check-version-stamp suite: ${passed} assertion(s) passed`);
  process.exit(0);
}
console.log(`❌ check-version-stamp suite: ${failed} of ${passed + failed} assertion(s) FAILED`);
for (const f of failures) console.log(`   - ${f}`);
process.exit(1);
