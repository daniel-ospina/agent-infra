/**
 * index.5550.test.ts — the push-scope proof for #5550.
 *
 * ⛔ WHAT MAKES THIS A PROOF AND NOT A GREEN LINE. An earlier attempt at this
 * fix shipped a test that PASSED AGAINST THE UNFIXED CODE: it hardcoded the base
 * ref and compared two hand-built argvs, so nothing it asserted could observe
 * whether `resolvePushRangeScope` had changed at all. It ran green, and it
 * carried zero evidence. Every direction below therefore calls
 * `resolvePushRangeScope` — THE CHANGED FUNCTION — against a real repo built by
 * real git, and compares its RETURNED SCOPE. A reference value computed from git
 * is allowed only as an expectation to DIFF against, never as the answer.
 *
 * THE THREE DIRECTIONS (they are not variations on one theme):
 *
 *   D1  REBASED (tracking is NOT an ancestor of src) — the reported set must be
 *       the BRANCH'S OWN files, not main's. RED on the pre-fix code, which
 *       reported main's whole 12-commit delta. This is the one direction that
 *       fails when the fix is absent, so it is the direction that proves it.
 *   D2  the branch's OWN file must still be REPORTED. Guards the opposite
 *       failure: a "fix" that shrinks the set to nothing would silence the gate.
 *       It MUST be present — an empty scope is how the comparator was measured
 *       to fail OPEN elsewhere (#5550 review).
 *   D3  INCREMENTAL (tracking IS an ancestor) — the reported set must be
 *       UNCHANGED from the pre-fix 2-dot-on-tracking form. This is the direction
 *       the first (rejected) fix missed: taking the integration base
 *       unconditionally changed the ordinary case from [f2] to [f1, f2] AND
 *       made the #755/#3398 push-arm base-identical subtraction stop running
 *       (e2e scenarios 80/81 red). RED on that rejected form.
 *
 * Run: npx tsx index.5550.test.ts
 */
import { ok, equal } from "node:assert/strict";
import { execSync } from "node:child_process";
import { mkdtempSync, writeFileSync, mkdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { resolvePushRangeScope } from "./index.js";

const TEST_ROOT = mkdtempSync(join(tmpdir(), "vgate-5550-"));

let passed = 0;
let failed = 0;

function test(name: string, fn: () => void): void {
  try {
    fn();
    passed++;
    console.log(`  ✅ ${name}`);
  } catch (err) {
    failed++;
    console.log(`  ❌ ${name}: ${(err as Error).message}`);
  }
}

function section(name: string): void {
  console.log(`\n── ${name} ──`);
}

function git(repo: string, args: string): string {
  return execSync(`git ${args}`, { cwd: repo, encoding: "utf-8", timeout: 20000 }).trim();
}

function files(joined: string): string[] {
  return joined.split("\n").map((s) => s.trim()).filter(Boolean).sort();
}

/** A repo with a real bare remote, so tracking refs actually exist. */
function makeRepo(name: string): { repo: string; remote: string } {
  const remote = join(TEST_ROOT, `${name}.git`);
  mkdirSync(remote, { recursive: true });
  git(remote, "init -q --bare -b main");
  const repo = join(TEST_ROOT, name);
  mkdirSync(repo, { recursive: true });
  git(repo, "init -q -b main");
  git(repo, "config user.email 5550@test");
  git(repo, "config user.name 5550");
  git(repo, "remote add origin " + remote);
  writeFileSync(join(repo, "seed.ts"), "s\n");
  git(repo, "add .");
  git(repo, "commit -q -m seed");
  git(repo, "push -q -u origin main");
  return { repo, remote };
}

/** Push main forward by `n` one-file commits — the divergence the defect inflated. */
function advanceMain(repo: string, n: number): string[] {
  git(repo, "checkout -q main");
  const names: string[] = [];
  for (let i = 0; i < n; i++) {
    const f = `main-${i}.ts`;
    names.push(f);
    writeFileSync(join(repo, f), `m${i}\n`);
    git(repo, "add .");
    git(repo, `commit -q -m main-${i}`);
  }
  git(repo, "push -q origin main");
  return names;
}

section("#5550 D1 — a REBASED branch reports its OWN change set, not main's");

test("D1: the resolver returns the branch's authored files after a rebase (RED pre-fix)", () => {
  const { repo } = makeRepo("d1");
  git(repo, "checkout -q -b feature");
  const owned = ["owned-a.ts", "owned-b.ts", "owned-c.ts"];
  for (const f of owned) writeFileSync(join(repo, f), `${f}\n`);
  git(repo, "add .");
  git(repo, "commit -q -m authored");
  git(repo, "push -q -u origin feature"); // tracking exists => tier A
  const mainFiles = advanceMain(repo, 12);
  git(repo, "checkout -q feature");
  git(repo, "rebase -q origin/main");

  // (fixture) tracking is NOT an ancestor after the rebase — the diverged case.
  const tracking = "refs/remotes/origin/feature";
  const mb = git(repo, `merge-base ${tracking} refs/heads/feature`);
  ok(mb !== git(repo, `rev-parse ${tracking}`),
    "D1: (fixture) the rebased branch must be DIVERGED from its tracking ref — otherwise this case is not exercised");

  const scope = resolvePushRangeScope("git push origin feature", repo);
  ok(scope !== null, "D1: the resolver must return a scope, not null (null degrades to the staged scope)");
  const got = files(scope!.files.join("\n"));
  equal(got.join(","), owned.slice().sort().join(","),
    `D1: the reported set must be the branch's OWN files — RED pre-fix, where the 2-dot branch-head range reported main's ${mainFiles.length}-file delta`);
  for (const f of mainFiles) {
    ok(!got.includes(f), `D1: main's own ${f} must NOT be reported`);
  }
});

section("#5550 D2 — the branch's OWN unverified file is still REPORTED");

test("D2: an unverified file in the branch's own set is present in the scope", () => {
  const { repo } = makeRepo("d2");
  git(repo, "checkout -q -b feature");
  const owned = ["own-1.ts", "own-2.ts"];
  for (const f of owned) writeFileSync(join(repo, f), `${f}\n`);
  git(repo, "add .");
  git(repo, "commit -q -m authored");
  git(repo, "push -q -u origin feature");
  advanceMain(repo, 6);
  git(repo, "checkout -q feature");
  git(repo, "rebase -q origin/main");

  const scope = resolvePushRangeScope("git push origin feature", repo);
  ok(scope !== null, "D2: the resolver must return a scope");
  const got = files(scope!.files.join("\n"));
  // The delivered gate blocks on exactly this set, so a file MISSING here is a
  // file the push would ship unverified. Guard the opposite failure from D1:
  // D1 alone would also pass if the set were EMPTY.
  for (const f of owned) {
    ok(got.includes(f), `D2: the branch's own unverified ${f} MUST still be reported — an empty scope would silence the gate`);
  }
  ok(got.length > 0, "D2: the scope must never be empty for a push that ships authored content");
});

section("#5550 D3 — an INCREMENTAL push is UNCHANGED (the rejected fix's blind spot)");

test("D3: with tracking an ANCESTOR the set equals the pre-fix 2-dot-on-tracking set (RED on the rejected unconditional form)", () => {
  const { repo } = makeRepo("d3");
  git(repo, "checkout -q -b feature2");
  writeFileSync(join(repo, "f1.ts"), "f1\n");
  git(repo, "add .");
  git(repo, "commit -q -m c1");
  git(repo, "push -q -u origin feature2"); // tracking = this commit
  writeFileSync(join(repo, "f2.ts"), "f2\n");
  git(repo, "add .");
  git(repo, "commit -q -m c2"); // unpushed — the incremental delta

  // (fixture) tracking IS an ancestor — the ordinary incremental push.
  const tracking = "refs/remotes/origin/feature2";
  equal(git(repo, `merge-base ${tracking} refs/heads/feature2`), git(repo, `rev-parse ${tracking}`),
    "D3: (fixture) tracking must be an ancestor — otherwise this is the diverged case");

  // The PRE-FIX expectation, computed from git with the pre-fix argv. This is an
  // EXPECTATION to diff against, not the answer: the answer below comes from the
  // changed function.
  const preFix = files(git(repo, `diff --name-only ${tracking} refs/heads/feature2`));
  equal(preFix.join(","), "f2.ts", "D3: (fixture) the pre-fix form reports only the newly pushed file");

  const scope = resolvePushRangeScope("git push origin feature2", repo);
  ok(scope !== null, "D3: the resolver must return a scope");
  const got = files(scope!.files.join("\n"));
  equal(got.join(","), preFix.join(","),
    `D3: the INCREMENTAL case must be byte-identical to pre-fix (${preFix.join(",")}) — RED on the rejected unconditional form, which re-reports already-verified files`);
});

console.log(`\n=== #5550 proof: ${passed} passed, ${failed} failed ===`);
rmSync(TEST_ROOT, { recursive: true, force: true });
if (failed > 0) process.exit(1);
console.log("✅ ALL #5550 PROOFS HELD");
