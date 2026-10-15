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

import { execFileSync, spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const CLI = path.join(REPO_ROOT, "scripts", "check-version-stamp.mjs");
// The module's pure pieces, driven directly by the arms that need to call them rather than shell out.
const mod = await import(CLI);

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

/** Run the CLI. Never throws — the exit code IS the assertion target, and BOTH streams are kept. */
function run(args, opts = {}) {
  // spawnSync, not execFileSync: a SUCCESSFUL run's stderr (warnings) must be observable too, and
  // `execFileSync` only surfaces stderr by throwing.
  const r = spawnSync(process.execPath, [CLI, ...args], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    cwd: opts.cwd ?? REPO_ROOT,
  });
  return { code: r.status ?? -1, stdout: r.stdout ?? "", stderr: r.stderr ?? "" };
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

    const noSurfaces = run(["--surface", "", "--repo", ORIGIN, "--ref", "main", "--no-fetch"], { cwd: TMP });
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
    const found = mod.linkedSurfaces(root);
    eq("a repo carrying only .agent-infra-version is discovered", found.includes(linked), true);
    eq("a directory that is not linked is not discovered", found.includes(unlinked), false);
    eq("the unlinked directory is not silently counted as a surface", found.length, 1);
  }

  // ── 10. an option-shaped ref must be REFUSED, not handed to `git fetch` as an option ─────
  // `--ref origin/--upload-pack=<cmd>` used to reach `git fetch origin --upload-pack=<cmd>` and
  // execute <cmd>. The fix is two-layer: `--` terminates option parsing, and the branch name is
  // validated (no leading '-', conservative charset).
  console.log("\n10. security — an option-shaped ref is refused, not executed");
  {
    const marker = path.join(TMP, "f1-pwned");
    fs.rmSync(marker, { force: true });

    // CONTROL first: a real branch still fetches through the hardened path.
    git(ORIGIN, "remote", "add", "origin", ORIGIN);
    try {
      const good = mod.refreshRef(ORIGIN, "origin/main");
      eq("control — a real origin/<branch> still fetches", good.fetched, true);
      eq("control — a good fetch carries no warning", good.warning, null);
    } finally {
      git(ORIGIN, "remote", "remove", "origin");
    }

    const evil = `origin/--upload-pack=touch ${marker};echo`;
    const v = run(["--surface", SURFACE, "--repo", ORIGIN, "--ref", evil]);
    eq("option-shaped ref → exit 2 (cannot verify)", v.code, 2);
    eq("the injected command did NOT run", fs.existsSync(marker), false);
    contains("the refusal names a bad ref", v.stderr + v.stdout, "bad ref");
  }

  // ── 11. an unreadable payload directory is cannot-verify, NEVER read as empty/in-sync ─────
  // Stamped with `extensions/` absent, then `extensions/` appears and cannot be read. Treated as
  // empty it contributes nothing, the digest equals the stamp, and a CHANGED surface goes green.
  console.log("\n11. fail-closed — a payload directory that cannot be read");
  {
    const surface2 = path.join(TMP, "surface-unreadable");
    fs.rmSync(surface2, { recursive: true, force: true });
    fs.mkdirSync(path.join(surface2, "skills", "one"), { recursive: true });
    fs.writeFileSync(path.join(surface2, "skills", "one", "SKILL.md"), "# one\n");
    const w = run(["--write", "--surface", surface2, "--repo", ORIGIN]);
    eq("control — stamped with extensions/ absent", w.code, 0);
    eq("control — that surface is green", run(["--surface", surface2, "--repo", ORIGIN, "--ref", "main", "--no-fetch", "--quiet"]).code, 0);

    fs.mkdirSync(path.join(surface2, "extensions"), { recursive: true });
    fs.writeFileSync(path.join(surface2, "extensions", "smuggled.ts"), "export const x = 1;\n");
    const ext2 = path.join(surface2, "extensions");
    fs.chmodSync(ext2, 0o000);
    let revokeWorked = false;
    try {
      try {
        fs.readdirSync(ext2);
      } catch {
        revokeWorked = true;
      }
      if (!revokeWorked) {
        ok("skipped — chmod did not revoke read access (running as root?)");
      } else {
        const v = run(["--surface", surface2, "--repo", ORIGIN, "--ref", "main", "--no-fetch", "--quiet"]);
        eq("unreadable dir → exit 1, never 0", v.code, 1);
        contains("unreadable dir is unstamped (cannot verify)", v.stdout, "unstamped");
        contains("the reason names the path", v.stdout, "extensions");
        contains("the reason names the errno", v.stdout, "EACCES");
      }
    } finally {
      fs.chmodSync(ext2, 0o755);
    }
  }

  // ── 12. a failed stamp write must leave the PREVIOUS stamp intact (atomic temp+rename) ────
  console.log("\n12. data-loss — a failed --write must not destroy the existing stamp");
  {
    stampNow();
    const before = fs.readFileSync(path.join(SURFACE, ".agent-infra-stamp.json"), "utf8");
    fs.chmodSync(SURFACE, 0o555); // no new file can be created in the directory
    let failed;
    try {
      // A sibling temp write cannot be created here, so the write fails. In-place truncation would
      // already have destroyed the stamp; temp+rename must leave it untouched.
      failed = run(["--write", "--surface", SURFACE, "--repo", ORIGIN]);
    } finally {
      fs.chmodSync(SURFACE, 0o755);
    }
    const after = fs.readFileSync(path.join(SURFACE, ".agent-infra-stamp.json"), "utf8");
    if (failed.code === 0) {
      ok("skipped — the write succeeded anyway (read-only dir not enforced here)");
    } else {
      eq("the write FAILED (control)", failed.code, 2);
      eq("the previous stamp is byte-identical", after, before);
      eq("and it is still valid/green", verify().code, 0);
    }
  }

  // ── 13. ancestry outcomes are THREE, not two ─────────────────────────────────────────────
  // `merge-base --is-ancestor` exits 1 (not an ancestor) and 128 (no such object), and `git()`
  // collapsed both to null — so a DESCENDANT of the target read as "off main's line" (false), and
  // an absent stamped commit read as a definite divergence instead of cannot-verify.
  console.log("\n13. ancestry — ahead-of-target and absent-commit differ from off-the-line");
  {
    stampNow();
    const good = stamp();

    // (a) the stamped commit is a DESCENDANT of the target.
    git(ORIGIN, "checkout", "-q", "-b", "ahead");
    write("extensions/ahead.ts", "export const ahead = 1;\n", ORIGIN);
    git(ORIGIN, "add", "-A");
    git(ORIGIN, "commit", "-q", "-m", "ahead");
    const ahead = git(ORIGIN, "rev-parse", "HEAD");
    git(ORIGIN, "checkout", "-q", "main");
    const targetSha = git(ORIGIN, "rev-parse", "HEAD");
    let targetIsAncestor = true;
    try {
      execFileSync("git", ["-C", ORIGIN, "merge-base", "--is-ancestor", targetSha, ahead]);
    } catch {
      targetIsAncestor = false;
    }
    eq("precondition — target IS an ancestor of the stamped commit", targetIsAncestor, true);

    writeStampRaw(SURFACE, { ...good, agentInfra: { ...good.agentInfra, commit: ahead } });
    const va = verify();
    eq("descendant of target → exit 1 (still drift)", va.code, 1);
    contains("reason says AHEAD of the ref", va.stdout, "AHEAD of");
    contains("reason is NOT the false 'off main's line'", va.stdout, "off main's line", false);

    // (b) the stamped commit is not in this repo at all.
    const ghost = "0".repeat(39) + "1";
    writeStampRaw(SURFACE, { ...good, agentInfra: { ...good.agentInfra, commit: ghost } });
    const vb = verify();
    eq("absent stamped commit → exit 1, never 0", vb.code, 1);
    contains("absent commit is unstamped (cannot verify)", vb.stdout, "unstamped");
    contains("reason names the missing object", vb.stdout, "not present");
    contains("absent commit is NOT called a divergence", vb.stdout, "off main's line", false);

    writeStampRaw(SURFACE, { ...good });
    eq("control — the good stamp is green again", verify().code, 0);
  }

  // ── 14. payload.roots must be EXACTLY the fixed set (reader's universe == writer's) ───────
  console.log("\n14. fail-closed — payload.roots cannot narrow the reader's universe");
  {
    stampNow();
    const good = stamp();
    eq("control — the untouched stamp is green", verify().code, 0);

    for (const roots of [[], ["skills"]]) {
      // The CORRECT hash is kept: a mismatched root list alone must be refused, so the arm cannot
      // pass merely because the digests happened to differ.
      writeStampRaw(SURFACE, { ...good, payload: { ...good.payload, roots } });
      const v = verify();
      eq(`roots=${JSON.stringify(roots)} → exit 1`, v.code, 1);
      contains(`roots=${JSON.stringify(roots)} is unstamped, never in-sync`, v.stdout, "unstamped");
      contains(`roots=${JSON.stringify(roots)} reason names the roots`, v.stdout, "payload.roots");
    }

    writeStampRaw(SURFACE, { ...good });
    eq("control — restored stamp is green", verify().code, 0);
  }

  // ── 15. `kind` at the repo root is agent-infra-checkout, not installed-surface ───────────
  console.log("\n15. kind — the surface that IS the checkout");
  {
    eq("kind at the repo root is agent-infra-checkout", mod.buildStamp(ORIGIN, ORIGIN).kind, "agent-infra-checkout");
    eq("kind inside the checkout is agent-infra-checkout", mod.buildStamp(path.join(ORIGIN, "scripts"), ORIGIN).kind, "agent-infra-checkout");
    eq("kind away from the repo is installed-surface", mod.buildStamp(SURFACE, ORIGIN).kind, "installed-surface");
  }

  // ── 16. $AGENT_INFRA_REPOS_ROOT is honoured; an explicit argument wins over it ────────────
  console.log("\n16. discovery — $AGENT_INFRA_REPOS_ROOT scopes the scan");
  {
    const envRoot = path.join(TMP, "env-repos");
    const linked = path.join(envRoot, "linked-repo");
    fs.mkdirSync(linked, { recursive: true });
    fs.writeFileSync(path.join(linked, ".agent-infra-version"), "0.1.0\n");
    const argRoot = path.join(TMP, "arg-repos");
    const argLinked = path.join(argRoot, "arg-repo");
    fs.mkdirSync(argLinked, { recursive: true });
    fs.writeFileSync(path.join(argLinked, ".agent-infra-version"), "0.1.0\n");

    const saved = process.env.AGENT_INFRA_REPOS_ROOT;
    process.env.AGENT_INFRA_REPOS_ROOT = envRoot;
    try {
      const found = mod.linkedSurfaces(undefined);
      eq("the env-var root is scanned", found.includes(linked), true);
      const viaArg = mod.linkedSurfaces(argRoot);
      eq("an explicit argument wins over the env var", viaArg.includes(argLinked) && !viaArg.includes(linked), true);
    } finally {
      if (saved === undefined) delete process.env.AGENT_INFRA_REPOS_ROOT;
      else process.env.AGENT_INFRA_REPOS_ROOT = saved;
    }
  }

  // ── 17. an empty --surface is refused (path.resolve("") is the CWD) ──────────────────────
  console.log("\n17. safety — an empty --surface must not stamp the CWD");
  {
    const cwd = path.join(TMP, "empty-surface-cwd");
    fs.mkdirSync(cwd, { recursive: true });
    const v = run(["--surface", "", "--repo", ORIGIN, "--write"], { cwd });
    eq("empty --surface → exit 2", v.code, 2);
    eq("nothing was stamped in the CWD", fs.existsSync(path.join(cwd, ".agent-infra-stamp.json")), false);
    contains("the refusal names the empty value", v.stderr + v.stdout, "non-empty");
  }

  // ── 18. a failed fetch warns on stderr even under --quiet, and never changes the exit code ─
  console.log("\n18. staleness — the fetch warning survives --quiet");
  {
    stampNow();
    eq("control — the surface is green", verify().code, 0);
    git(ORIGIN, "update-ref", "refs/remotes/origin/main", git(ORIGIN, "rev-parse", "HEAD"));
    git(ORIGIN, "remote", "add", "origin", path.join(TMP, "no-such-remote"));
    try {
      const v = run(["--surface", SURFACE, "--repo", ORIGIN, "--ref", "origin/main", "--quiet"]);
      contains("--quiet still shows the fetch warning on stderr", v.stderr, "could not fetch");
      eq("--quiet exit is unchanged by the warning", v.code, 0);
      const j = run(["--surface", SURFACE, "--repo", ORIGIN, "--ref", "origin/main", "--quiet", "--json"]);
      contains("--json records the warning field", JSON.stringify(JSON.parse(j.stdout).warning), "could not fetch");
    } finally {
      git(ORIGIN, "remote", "remove", "origin");
    }
  }

  // ── 19. a symlink in the payload is digested as its TARGET STRING, not its content ────────
  // Mutation-sensitive: a mutant that FOLLOWS the link digests identical CONTENT on both sides and
  // cannot see the re-point; a mutant that ignores links cannot see it either. Only recording the
  // target string makes a re-point visible.
  console.log("\n19. mutation — a re-pointed symlink is drift, an unchanged one is in-sync");
  {
    const a = path.join(SURFACE, "scripts", "same-a.sh");
    const b = path.join(SURFACE, "scripts", "same-b.sh");
    fs.writeFileSync(a, "#!/bin/bash\necho identical\n");
    fs.writeFileSync(b, "#!/bin/bash\necho identical\n");
    const link = path.join(SURFACE, "scripts", "link.sh");
    fs.rmSync(link, { force: true });
    fs.symlinkSync("same-a.sh", link);
    stampNow();
    eq("control — an unchanged symlink is in-sync", verify().code, 0);

    fs.rmSync(link);
    fs.symlinkSync("same-b.sh", link); // identical CONTENT, different TARGET STRING
    const v = verify();
    eq("a re-pointed symlink is drift", v.code, 1);
    contains("the re-pointed link names the payload reason", v.stdout, "payload hash");

    fs.rmSync(link);
    fs.symlinkSync("same-a.sh", link);
    eq("control — re-pointing back is green", verify().code, 0);

    fs.rmSync(link);
    fs.rmSync(a, { force: true });
    fs.rmSync(b, { force: true });
    stampNow();
  }

  // ── 20. --no-repos disables ONLY the linked-repo scan; the pi surface remains ────────────
  // The flag is documented in two places as "only the pi surface" (header CLI list + --help).
  // Both ternaries used to test `opts.noRepos`, so the list came back EMPTY and the tool
  // refused to check anything (exit 2) — the exact opposite of its documented meaning.
  console.log("\n20. --no-repos still checks the pi surface");
  {
    const savedPi = process.env.AGENT_INFRA_PI_HOME;
    stampNow();
    process.env.AGENT_INFRA_PI_HOME = SURFACE;
    try {
      const v = run(["--no-repos", "--repo", ORIGIN, "--ref", "main", "--no-fetch", "--quiet"]);
      if (v.code === 2) bad("--no-repos does not hand back an empty set", v.stderr + v.stdout);
      else ok("--no-repos does not hand back an empty set");
      contains("the pi surface is still classified", v.stdout, SURFACE);
      contains("and it is reported in-sync", v.stdout, "in-sync");
    } finally {
      if (savedPi === undefined) delete process.env.AGENT_INFRA_PI_HOME;
      else process.env.AGENT_INFRA_PI_HOME = savedPi;
    }
  }

  // ── 21. an EMPTY surface set is "nothing was verified" (exit 2) ─────────────────────────
  // Deleting the `surfaces.length === 0` guard used to leave this whole suite GREEN (measured),
  // because no arm ever built an empty set. Point the pi home at a path that does not exist and
  // disable the linked scan, so `[piSurface()]` filters to [] — the state the guard exists for.
  console.log("\n21. fail-closed — an empty surface set is 'nothing was verified' (exit 2)");
  {
    const savedPi = process.env.AGENT_INFRA_PI_HOME;
    const savedRoot = process.env.AGENT_INFRA_REPOS_ROOT;
    process.env.AGENT_INFRA_PI_HOME = path.join(TMP, "no-such-pi-home");
    process.env.AGENT_INFRA_REPOS_ROOT = path.join(TMP, "no-such-repos-root");
    try {
      const v = run(["--no-repos", "--repo", ORIGIN, "--ref", "main", "--no-fetch", "--quiet"]);
      eq("an empty surface set exits 2, never 0", v.code, 2);
      contains("the refusal says nothing was verified", v.stderr + v.stdout, "nothing was verified");
    } finally {
      if (savedPi === undefined) delete process.env.AGENT_INFRA_PI_HOME;
      else process.env.AGENT_INFRA_PI_HOME = savedPi;
      if (savedRoot === undefined) delete process.env.AGENT_INFRA_REPOS_ROOT;
      else process.env.AGENT_INFRA_REPOS_ROOT = savedRoot;
    }
  }

  // ── 22. an empty --repo names nothing and must not fall through to a default ─────────────
  // `resolveRepo` reads `""` as UNNAMED and falls through to $AGENT_INFRA_PATH / this module's
  // root — the substitution the explicit-`--repo` fix removed for a named value, left open for a
  // blank one. `--surface ""` is refused; `--repo ""` must be too.
  console.log("\n22. safety — an empty --repo must not resolve to some other checkout");
  {
    const v = run(["--surface", SURFACE, "--repo", "", "--ref", "main", "--no-fetch", "--quiet"]);
    eq("empty --repo → exit 2 (bad usage)", v.code, 2);
    contains("the refusal names the empty value", v.stderr + v.stdout, "non-empty");
  }

  // ── 23. a stamp from a DIRTY source checkout cannot certify in-sync ──────────────────────
  // The stamp records `agentInfra.dirty`; nothing read it, so an install copied from a checkout
  // with an uncommitted payload edit verified `in-sync` — the false green this check exists for.
  console.log("\n23. fail-closed — a dirty source checkout is drift, never in-sync");
  {
    stampNow();
    eq("control — a clean source stamps green", verify().code, 0);
    const alphaPath = path.join(ORIGIN, "extensions", "alpha.ts");
    const original = fs.readFileSync(alphaPath, "utf8");
    fs.writeFileSync(alphaPath, original + "export const uncommitted = 1;\n");
    try {
      const w = stampNow();
      eq("--write still exits 0 (the state is recorded, not hidden)", w.code, 0);
      contains("--write warns that the source is dirty", w.stderr, "DIRTY");
      eq("the stamp records dirty=true", stamp().agentInfra.dirty, true);
      const v = verify();
      eq("a dirty-source stamp exits 1", v.code, 1);
      contains("the verdict is drift", v.stdout, "drift");
      contains("the reason names the dirty source", v.stdout, "DIRTY source checkout");
      contains("the reason never reads in-sync", v.stdout, "in-sync", false);

      // `dirty: null` (the status probe failed) or an ABSENT field is the same class of
      // unanswerable as `commit: null` — it must be unstamped, never a pass.
      const dirtyStamp = stamp();
      for (const unknown of [null, undefined]) {
        writeStampRaw(SURFACE, { ...dirtyStamp, agentInfra: { ...dirtyStamp.agentInfra, dirty: unknown } });
        const vn = verify();
        eq(`dirty=${String(unknown)} → exit 1`, vn.code, 1);
        contains(`dirty=${String(unknown)} is unstamped, never in-sync`, vn.stdout, "unstamped");
        contains(`dirty=${String(unknown)} reason names agentInfra.dirty`, vn.stdout, "agentInfra.dirty");
      }
    } finally {
      fs.writeFileSync(alphaPath, original);
    }
    stampNow();
    eq("control — re-stamped from a clean checkout is green", verify().code, 0);
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
