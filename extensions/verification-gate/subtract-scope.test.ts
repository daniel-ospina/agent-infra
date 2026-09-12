// #755 — merge-scope subtraction. Unit pins for the rule, the sentinel table,
// and the real-git adapter.
//
// ⛔ SDK-FREE. This file is run by ci.yml's `verify` job, which performs NO
// `npm ci`, so `./index.js` may be imported as a TYPE only (index.ts:2 is a
// value import of the pi SDK). The parser row-family pins live in index.test.ts
// for exactly that reason.

import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync, readFileSync, mkdirSync, rmSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { DiffScope } from "./index.js";
import {
  subtractCommitArm,
  subtractPushArm,
  makeSubBundle,
  makeGitSubCtx,
  isShallowRepository,
  resolveTrustedBase,
  SUBTRACT_SKIP_REASONS,
  type SubCtx,
  type RecordedSide,
  type ArmLabel,
} from "./subtract-scope.js";

// ── fixtures ─────────────────────────────────────────
// The fixture is the TDD entry point: it must bind the CURRENT interface, or it
// cannot exercise it. Every primitive the sentinel table marks required appears
// here — an omitted one makes the arm throw a TypeError instead of returning
// { scope, audit }.

const SCOPE: DiffScope = {
  files: ["base.ts", "authored.ts", "link", "sub", "gone.ts", "wt-only.ts"],
  renameOldPaths: [],
  clean: true,
};

// A/D/M around the guard edges: base.ts is base-identical (subtractable),
// authored.ts differs from BOTH refs, wt-only.ts differs from both, link/sub
// are non-regular on T, gone.ts has no entry on T.
const STATUSES = new Map<string, string>([
  ["base.ts", "M"],
  ["authored.ts", "M"],
  ["link", "M"],
  ["sub", "M"],
  ["gone.ts", "M"],
  ["wt-only.ts", "M"],
]);

function mkCtx(over: Partial<SubCtx> = {}): SubCtx {
  const base: SubCtx = {
    arm: () => "staged",
    recordedSide: () => "index",
    recordedSideRef: () => null,
    recordedSideOid: () => null,
    t: () => ({ ref: "refs/remotes/origin/main", oid: "t-oid" }),
    b: () => ({ ref: "HEAD", oid: "b-oid" }),
    mergeBaseOid: () => "mb-oid",
    trackingRefOid: () => "tr-oid",
    // Sentinel `true` = "differs" ⇒ conditions (1)/(2) fail ⇒ never subtract.
    differsFromBase: (p) => p === "authored.ts" || p === "wt-only.ts" || p === "gone.ts",
    differsFromBranchSide: (p) => p === "authored.ts" || p === "wt-only.ts" || p === "gone.ts",
    baseEntry: (p) =>
      p === "link" ? { mode: "120000", blob: "s" }
        : p === "sub" ? { mode: "160000", blob: "c" }
          : p === "gone.ts" ? null
            : { mode: "100644", blob: "same" },
    mergeBaseCount: () => 1,
    isAncestorOrEqual: (a, b) =>
      a === "b-oid" && b === "t-oid" ? false      // (3) healthy
        : a === "t-oid" && b === "R2" ? true       // (4) healthy
          : a === "tr-oid" && b === "b-oid" ? true // (5) healthy
            : false,
    parentRefs: () => ["R1", "R2"],
    isShallowRepository: () => false,
    srcRef: () => "HEAD",
    trackingRef: () => "refs/remotes/origin/topic",
  };
  return { ...base, ...over };
}

/** Run and return the kept file list + whether an audit line was produced. */
function runCommit(ctx: SubCtx | null, scope: DiffScope = SCOPE, statuses = STATUSES) {
  const r = subtractCommitArm(scope, statuses, ctx);
  return { files: r.scope.files, audited: r.audit !== null, audit: r.audit, scope: r.scope };
}
function runPush(ctx: SubCtx | null, scope: DiffScope = SCOPE, statuses = STATUSES) {
  const r = subtractPushArm(scope, statuses, ctx);
  return { files: r.scope.files, audited: r.audit !== null, audit: r.audit, scope: r.scope };
}

// ── HAPPY PATH ───────────────────────────────────────
test("#755 — commit arm subtracts ONLY the base-identical regular file", () => {
  const { files, audited, audit } = runCommit(mkCtx());
  assert.deepEqual(files, ["authored.ts", "link", "sub", "gone.ts", "wt-only.ts"]);
  assert.equal(audited, true);
  assert.deepEqual(audit!.perArmSubtracted, ["base.ts"]);
  assert.equal(audit!.arm, "staged");
  assert.equal(audit!.recordedSide, "index");
});

test("#755 — push arm subtracts the same set when guards (4)/(5) hold", () => {
  const ctx = mkCtx({ arm: () => "push", recordedSide: () => "ref", recordedSideRef: () => "HEAD", recordedSideOid: () => "r-oid" });
  const { files, audited } = runPush(ctx);
  assert.deepEqual(files, ["authored.ts", "link", "sub", "gone.ts", "wt-only.ts"]);
  assert.equal(audited, true);
});

// ── ANTI-VACUITY: the audit is the thing an assertion on `files` cannot catch ──
test("#755 ANTI-VACUITY — a no-ctx degradation returns the RAW scope, no audit", () => {
  const { files, audited } = runCommit(null);
  assert.deepEqual(files, SCOPE.files); // unchanged, NOT silently emptied
  assert.equal(audited, false);
});

// ── ONE INDEPENDENT NEGATIVE PER GUARD ───────────────
// Guard (0): only exactly one merge base permits subtraction.
for (const count of [0, 2, null, 3]) {
  test(`#755 guard (0) — mergeBaseCount ${String(count)} ⇒ no subtraction`, () => {
    const { files, audited } = runCommit(mkCtx({ mergeBaseCount: () => count as number | null }));
    assert.deepEqual(files, SCOPE.files);
    assert.equal(audited, false);
  });
}

test("#755 guard (1) — differsFromBase ⇒ no subtraction (per path, not whole-scope)", () => {
  const { files } = runCommit(mkCtx({ differsFromBase: () => true }));
  assert.deepEqual(files, ["base.ts", "authored.ts", "link", "sub", "gone.ts", "wt-only.ts"]);
});

test("#755 guard (2) — differsFromBranchSide ⇒ no subtraction", () => {
  const { files, audited } = runCommit(mkCtx({ differsFromBranchSide: () => true }));
  assert.deepEqual(files, SCOPE.files);
  assert.equal(audited, false);
});

test("#755 guard (3) — isAncestorOrEqual(B,T) === false passes", () => {
  const { audited } = runCommit(mkCtx({ isAncestorOrEqual: (a, b) => (a === "b-oid" && b === "t-oid" ? false : true) }));
  assert.equal(audited, true);
});

test("#755 guard (3) — TRUE blocks (B is an ancestor-or-equal of T)", () => {
  const { files, audited } = runCommit(mkCtx({ isAncestorOrEqual: () => true }));
  assert.deepEqual(files, SCOPE.files);
  assert.equal(audited, false);
});

// ⛔ The cycle-5/6/7 P0: `--is-ancestor` exit 128 conflated with exit 1 turned a
// FAILED query into "not an ancestor", which ENABLES subtraction.
test("#755 guard (3) — null (query failed, exit 128) does NOT enable subtraction", () => {
  const { files, audited } = runCommit(mkCtx({ isAncestorOrEqual: () => null }));
  assert.deepEqual(files, SCOPE.files);
  assert.equal(audited, false);
});

test("#755 guard (4) — passes only on an explicit true for a NON-FIRST parent", () => {
  const push = (fn: SubCtx["isAncestorOrEqual"]) =>
    runPush(mkCtx({ arm: () => "push", recordedSide: () => "ref", recordedSideRef: () => "HEAD", recordedSideOid: () => "r-oid", isAncestorOrEqual: fn }));
  // healthy: (3) false, (4) true on R2, (5) true
  assert.equal(push((a, b) => (a === "b-oid" && b === "t-oid" ? false : a === "t-oid" && b === "R2" ? true : a === "tr-oid" && b === "b-oid" ? true : false)).audited, true);
  // (4) says false only for the SECOND parent ⇒ blocked (first parent must not count)
  assert.equal(push((a, b) => (a === "b-oid" && b === "t-oid" ? false : a === "t-oid" && b === "R1" ? true : a === "tr-oid" && b === "b-oid" ? true : false)).audited, false);
  // (4) null ⇒ blocked
  assert.equal(push((a, b) => (a === "b-oid" && b === "t-oid" ? false : a === "t-oid" ? null : a === "tr-oid" && b === "b-oid" ? true : false)).audited, false);
});

test("#755 guard (5) — a missing tracking OID is unprovable ⇒ no subtraction", () => {
  const { audited } = runPush(
    mkCtx({ arm: () => "push", recordedSide: () => "ref", recordedSideRef: () => "HEAD", recordedSideOid: () => "r-oid", trackingRefOid: () => null })
  );
  assert.equal(audited, false);
});

test("#755 guard (5) — null verdict ⇒ no subtraction", () => {
  const { audited } = runPush(
    mkCtx({
      arm: () => "push", recordedSide: () => "ref", recordedSideRef: () => "HEAD", recordedSideOid: () => "r-oid",
      isAncestorOrEqual: (a, b) => (a === "b-oid" && b === "t-oid" ? false : a === "t-oid" && b === "R2" ? true : null),
    })
  );
  assert.equal(audited, false);
});

test("#755 — the commit arm does NOT evaluate guards (4)/(5) (linear commit still subtracts)", () => {
  const ctx = mkCtx({ parentRefs: () => [], isAncestorOrEqual: (a, b) => (a === "b-oid" && b === "t-oid" ? false : false) });
  assert.equal(runCommit(ctx).audited, true);
});

test("#755 shallow repository ⇒ no subtraction (sentinel true)", () => {
  const { files, audited } = runCommit(mkCtx({ isShallowRepository: () => true }));
  assert.deepEqual(files, SCOPE.files);
  assert.equal(audited, false);
});

// ── ELIGIBILITY (E) and the regular-file guard (F) ──
for (const st of ["D", "T", "R", "C", "U", "X", "B"]) {
  test(`#755 eligibility — status ${st} is never subtracted`, () => {
    const statuses = new Map(STATUSES);
    statuses.set("base.ts", st);
    const { audited } = runCommit(mkCtx(), SCOPE, statuses);
    assert.equal(audited, false);
  });
}
for (const st of ["A", "M"]) {
  test(`#755 eligibility — status ${st} IS eligible`, () => {
    const statuses = new Map(STATUSES);
    statuses.set("base.ts", st);
    assert.equal(runCommit(mkCtx(), SCOPE, statuses).audited, true);
  });
}

test("#755 guard (F) — a gitlink (160000) on T is not subtracted", () => {
  const { files } = runCommit(mkCtx(), { ...SCOPE, files: ["sub"] }, new Map([["sub", "M"]]));
  assert.deepEqual(files, ["sub"]);
});

test("#755 guard (F) — a symlink (120000) on T is not subtracted", () => {
  const { files } = runCommit(mkCtx(), { ...SCOPE, files: ["link"] }, new Map([["link", "M"]]));
  assert.deepEqual(files, ["link"]);
});

test("#755 guard (F) — an executable regular file (100755) IS subtracted", () => {
  const ctx = mkCtx({ baseEntry: () => ({ mode: "100755", blob: "b" }) });
  const { files } = runCommit(ctx, { ...SCOPE, files: ["run.sh"] }, new Map([["run.sh", "M"]]));
  assert.deepEqual(files, []);
});

test("#755 guard (F) — no entry on T (path added by the branch) is not subtracted", () => {
  const { files } = runCommit(mkCtx(), { ...SCOPE, files: ["gone.ts"] }, new Map([["gone.ts", "M"]]));
  assert.deepEqual(files, ["gone.ts"]);
});

// ── ABSENCE SEMANTICS + the shrink invariant ─────────
test("#755 — a scope that did not shrink keeps NO `subtractions` key (absent, never [])", () => {
  const scope: DiffScope = { files: ["authored.ts"], renameOldPaths: [], clean: true };
  const r = subtractCommitArm(scope, STATUSES, mkCtx());
  assert.equal(r.audit, null);
  assert.equal("subtractions" in r.scope, false);
});

test("#755 — renameOldPaths is never orphaned (a rename target is ineligible anyway)", () => {
  const scope: DiffScope = { files: ["base.ts"], renameOldPaths: ["base.ts"], clean: true };
  const r = subtractCommitArm(scope, STATUSES, mkCtx());
  assert.equal(r.audit, null);
  assert.deepEqual(r.scope.files, ["base.ts"]);
});

test("#755 — clean:false short-circuits (the status map may be PARTIAL)", () => {
  const r = subtractCommitArm({ ...SCOPE, clean: false }, STATUSES, mkCtx());
  assert.equal(r.audit, null);
  assert.deepEqual(r.scope.files, SCOPE.files);
});

test("#755 — `clean` passes through untouched on a successful subtraction", () => {
  const r = subtractCommitArm({ ...SCOPE, clean: true }, STATUSES, mkCtx());
  assert.equal(r.scope.clean, true);
});

// ── VOCABULARY ───────────────────────────────────────
test("#755 — SUBTRACT_SKIP_REASONS has exactly two distinct members", () => {
  assert.deepEqual([...SUBTRACT_SKIP_REASONS], ["base_identical_satisfied", "subtract_disabled_by_env"]);
  assert.equal(new Set(SUBTRACT_SKIP_REASONS).size, SUBTRACT_SKIP_REASONS.length);
});

// ── REAL-GIT: the adapter, end to end ────────────────
function git(cwd: string, args: string[]): string {
  return execFileSync("git", args, { cwd, encoding: "utf-8", stdio: ["ignore", "pipe", "ignore"] });
}
function write(cwd: string, rel: string, body: string): void {
  const abs = join(cwd, rel);
  mkdirSync(join(abs, ".."), { recursive: true });
  writeFileSync(abs, body);
}
function mkRepo(): string {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), "vg756-")));
  git(dir, ["init", "-q", "-b", "main"]);
  git(dir, ["config", "user.email", "t@example.com"]);
  git(dir, ["config", "user.name", "t"]);
  return dir;
}

test("#755 REAL GIT — a base-identical path is subtracted, a branch-authored one is kept", () => {
  const dir = mkRepo();
  try {
    // Base: two files.
    write(dir, "base.ts", "base v1\n");
    write(dir, "authored.ts", "authored v1\n");
    git(dir, ["add", "."]);
    git(dir, ["commit", "-qm", "base"]);
    git(dir, ["update-ref", "refs/remotes/origin/main", "HEAD"]);

    // Upstream advances base.ts; the branch touches only authored.ts, then
    // MERGES the upstream in — so base.ts reaches the index as a base-identical
    // change (the flood this issue is about).
    git(dir, ["checkout", "-q", "-b", "upstream"]);
    write(dir, "base.ts", "base v2\n");
    git(dir, ["add", "."]);
    git(dir, ["commit", "-qm", "upstream touches base"]);
    git(dir, ["update-ref", "refs/remotes/origin/main", "HEAD"]);
    git(dir, ["checkout", "-q", "main"]);
    write(dir, "authored.ts", "authored v2\n");
    git(dir, ["add", "."]);
    git(dir, ["commit", "-qm", "branch touches authored"]);
    git(dir, ["merge", "--no-commit", "--no-ff", "upstream"]);

    // ⛔ REALITY CHECK (learned from this test's first run): after a merge,
    // `git diff --cached` shows ONLY the INCOMING side's changes — the branch's
    // own already-committed work is in HEAD, so it does not appear. Add an
    // uncommitted branch-authored change to the index so the scope contains BOTH
    // a base-identical path and a genuinely branch-authored one.
    write(dir, "authored.ts", "authored v3 (uncommitted, index only)\n");
    git(dir, ["add", "authored.ts"]);

    const staged = git(dir, ["diff", "--cached", "--name-only"]).trim().split("\n").filter(Boolean);
    assert.deepEqual(staged.sort(), ["authored.ts", "base.ts"]);

    const bundle = makeSubBundle(dir);
    assert.notEqual(bundle, null, "the trusted base must resolve");
    const ctx = makeGitSubCtx(dir, { bundle: bundle!, arm: "staged", recordedSide: "index" });
    assert.notEqual(ctx, null);

    const scope: DiffScope = { files: ["authored.ts", "base.ts"], renameOldPaths: [], clean: true };
    const statuses = new Map([["authored.ts", "M"], ["base.ts", "M"]]);
    const r = subtractCommitArm(scope, statuses, ctx);

    assert.deepEqual(r.scope.files, ["authored.ts"], "base.ts must be subtracted, authored.ts kept");
    assert.notEqual(r.audit, null);
    assert.deepEqual(r.audit!.perArmSubtracted, ["base.ts"]);
    assert.equal(r.audit!.mergeBaseOid !== null, true);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("#755 REAL GIT — a merge whose ONLY incoming change is base-identical ⇒ empty scope, WITH an audit", () => {
  // The empty-allow the audit exists for: the subtraction removes everything,
  // and the op must be auditable rather than silently allowed.
  const dir = mkRepo();
  try {
    write(dir, "base.ts", "v1\n");
    git(dir, ["add", "."]);
    git(dir, ["commit", "-qm", "base"]);
    git(dir, ["update-ref", "refs/remotes/origin/main", "HEAD"]);
    git(dir, ["checkout", "-q", "-b", "upstream"]);
    write(dir, "base.ts", "v2\n");
    git(dir, ["add", "."]);
    git(dir, ["commit", "-qm", "up"]);
    git(dir, ["update-ref", "refs/remotes/origin/main", "HEAD"]);
    git(dir, ["checkout", "-q", "main"]);
    // ⛔ The branch MUST diverge from T, or guard (3) correctly blocks: if HEAD
    // is an ancestor-or-equal of the trusted base, merging T in takes T's
    // content wholesale and subtracting would remove the incoming change.
    write(dir, "feature-only.ts", "branch work\n");
    git(dir, ["add", "."]);
    git(dir, ["commit", "-qm", "branch diverges"]);
    git(dir, ["merge", "--no-commit", "--no-ff", "upstream"]);

    const bundle = makeSubBundle(dir);
    assert.notEqual(bundle, null);
    const ctx = makeGitSubCtx(dir, { bundle: bundle!, arm: "staged", recordedSide: "index" });
    assert.notEqual(ctx, null);
    const scope: DiffScope = { files: ["base.ts"], renameOldPaths: [], clean: true };
    const r = subtractCommitArm(scope, new Map([["base.ts", "M"]]), ctx);
    assert.deepEqual(r.scope.files, []);
    assert.notEqual(r.audit, null, "a full subtraction MUST still be audited");
    assert.deepEqual(r.audit!.perArmSubtracted, ["base.ts"]);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("#755 REAL GIT — no merge in progress (B not an ancestor-twin) subtracts nothing", () => {
  const dir = mkRepo();
  try {
    write(dir, "base.ts", "base v1\n");
    git(dir, ["add", "."]);
    git(dir, ["commit", "-qm", "base"]);
    git(dir, ["update-ref", "refs/remotes/origin/main", "HEAD"]);
    // A branch-authored change that merely REPLACES base.ts content with the
    // same bytes is NOT enough — the content equals T, so it IS subtract-
    // eligible only when all guards hold; here guard (3) must block because
    // HEAD == T (B is an ancestor-or-equal of T).
    write(dir, "base.ts", "base v1\n");
    git(dir, ["add", "."]);
    const bundle = makeSubBundle(dir);
    assert.notEqual(bundle, null);
    const ctx = makeGitSubCtx(dir, { bundle: bundle!, arm: "staged", recordedSide: "index" });
    assert.notEqual(ctx, null);
    const scope: DiffScope = { files: ["base.ts"], renameOldPaths: [], clean: true };
    const r = subtractCommitArm(scope, new Map([["base.ts", "M"]]), ctx);
    assert.deepEqual(r.scope.files, ["base.ts"]);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("#755 REAL GIT — resolveTrustedBase prefers the tracking remote, else origin/main", () => {
  const dir = mkRepo();
  try {
    write(dir, "a.ts", "a\n");
    git(dir, ["add", "."]);
    git(dir, ["commit", "-qm", "base"]);
    git(dir, ["update-ref", "refs/remotes/origin/main", "HEAD"]);
    const base = resolveTrustedBase(dir);
    assert.notEqual(base, null);
    assert.equal(base!.ref, "refs/remotes/origin/main");
    assert.equal(base!.oid.length, 40);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("#755 REAL GIT — the tracking remote WINS over the origin/main fallback", () => {
  // The half that was untested: a regression that ignored branch.<cur>.remote /
  // branch.<cur>.merge would still pass the origin/main-fallback test above.
  const dir = mkRepo();
  try {
    write(dir, "a.ts", "a\n");
    git(dir, ["add", "."]);
    git(dir, ["commit", "-qm", "base"]);
    const branch = git(dir, ["rev-parse", "--abbrev-ref", "HEAD"]).trim();
    // Both candidate refs exist and point at DIFFERENT commits, so which one is
    // chosen is observable.
    write(dir, "b.ts", "b\n");
    git(dir, ["add", "."]);
    git(dir, ["commit", "-qm", "second"]);
    git(dir, ["update-ref", "refs/remotes/origin/main", "HEAD"]);
    git(dir, ["update-ref", "refs/remotes/upstream/main", "HEAD~"]);
    git(dir, ["config", `branch.${branch}.remote`, "upstream"]);
    git(dir, ["config", `branch.${branch}.merge`, "refs/heads/main"]);
    const base = resolveTrustedBase(dir);
    assert.notEqual(base, null);
    assert.equal(base!.ref, "refs/remotes/upstream/main",
      "the configured tracking remote must win over the origin/main fallback");
    assert.equal(base!.oid, git(dir, ["rev-parse", "refs/remotes/upstream/main"]).trim());
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("#755 REAL GIT — an unresolvable trusted base ⇒ no bundle ⇒ no subtraction", () => {
  const dir = mkRepo();
  try {
    write(dir, "a.ts", "a\n");
    git(dir, ["add", "."]);
    git(dir, ["commit", "-qm", "base"]);
    // No refs/remotes/origin/main at all.
    assert.equal(resolveTrustedBase(dir), null);
    assert.equal(makeSubBundle(dir), null);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("#755 REAL GIT — isShallowRepository is false in a full clone", () => {
  const dir = mkRepo();
  try {
    assert.equal(isShallowRepository(dir), false);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("#755 REAL GIT — a hostile filename (space, $, quote, newline) is subtracted correctly", () => {
  const dir = mkRepo();
  try {
    const hostile = 'weird $x "q\nnl.ts';
    write(dir, hostile, "v1\n");
    git(dir, ["add", "-A"]);
    git(dir, ["commit", "-qm", "base"]);
    git(dir, ["update-ref", "refs/remotes/origin/main", "HEAD"]);
    git(dir, ["checkout", "-q", "-b", "upstream"]);
    write(dir, hostile, "v2\n");
    git(dir, ["add", "-A"]);
    git(dir, ["commit", "-qm", "up"]);
    git(dir, ["update-ref", "refs/remotes/origin/main", "HEAD"]);
    git(dir, ["checkout", "-q", "main"]);
    // Diverge (see the guard-(3) note in the previous test).
    write(dir, "feature-only.ts", "branch work\n");
    git(dir, ["add", "."]);
    git(dir, ["commit", "-qm", "branch diverges"]);
    git(dir, ["merge", "--no-commit", "--no-ff", "upstream"]);
    const bundle = makeSubBundle(dir);
    assert.notEqual(bundle, null);
    const ctx = makeGitSubCtx(dir, { bundle: bundle!, arm: "staged", recordedSide: "index" });
    assert.notEqual(ctx, null);
    const scope: DiffScope = { files: [hostile], renameOldPaths: [], clean: true };
    const r = subtractCommitArm(scope, new Map([[hostile, "M"]]), ctx);
    assert.deepEqual(r.scope.files, [], "the hostile path must be subtracted exactly once, by exact name");
    assert.deepEqual(r.audit!.perArmSubtracted, [hostile]);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("#755 REAL GIT — a GITLINK in the trusted base is SKIPPED, not fatal", () => {
  // A real gitlink (`160000 commit`) in the base tree used to make parseLsTreeZ
  // return null → makeSubBundle null → subtraction silently DISABLED for the
  // whole repo, with no audit line, in any repo whose base contains a submodule.
  // The sibling regular file must still reach baseEntries (the eligibility
  // precondition guard (F) reads) — the pin proves presence + regular mode, not
  // that a subtraction happened.
  const dir = mkRepo();
  try {
    write(dir, "a.ts", "a\n");
    git(dir, ["add", "."]);
    git(dir, ["commit", "-qm", "base"]);
    // The gitlink must be COMMITTED into the tree origin/main points at:
    // makeSubBundle reads `ls-tree -r -z <oid>`, i.e. a committed tree. Writing
    // the index alone (update-index without commit) leaves NO non-blob record in
    // that stream, so the test would pass against the old `return null` — it was
    // vacuous until this commit line was added.
    git(dir, ["update-index", "--add", "--cacheinfo", "160000,0000000000000000000000000000000000000001,submod"]);
    git(dir, ["commit", "-qm", "add-gitlink"]);
    git(dir, ["update-ref", "refs/remotes/origin/main", "HEAD"]);
    // Anti-vacuity: prove the non-blob record really is in the trusted base tree.
    const tree = git(dir, ["ls-tree", "-r", "-z", "refs/remotes/origin/main"]);
    assert.ok(tree.includes("160000 commit"),
      "fixture must actually place a non-blob record in the trusted base tree");
    const bundle = makeSubBundle(dir);
    assert.notEqual(bundle, null, "a gitlink must NOT disable the whole bundle");
    assert.equal(bundle!.baseEntries.get("submod"), undefined, "the gitlink entry is skipped");
    assert.equal(bundle!.baseEntries.get("a.ts")!.mode, "100644", "the sibling regular file survives");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("#755 REAL GIT — the bundle's baseEntries carry mode + blob for a regular file", () => {
  const dir = mkRepo();
  try {
    write(dir, "a.ts", "a\n");
    git(dir, ["add", "."]);
    git(dir, ["commit", "-qm", "base"]);
    git(dir, ["update-ref", "refs/remotes/origin/main", "HEAD"]);
    const bundle = makeSubBundle(dir);
    assert.notEqual(bundle, null);
    assert.equal(bundle!.baseEntries.get("a.ts")!.mode, "100644");
    assert.equal(bundle!.baseEntries.get("a.ts")!.blob.length, 40);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("#755 REAL GIT — a WHOLLY identical recorded side still subtracts (empty diff is not a parse failure)", () => {
  // The strongest form of the property: the recorded side equals T for the whole
  // tree, so `diff <T> <recordedSide>` is EMPTY. Treating an empty stream as a
  // parse failure made conditions (1)/(2) return the fail-closed `true` for every
  // path — silently defeating subtraction exactly where it should fire hardest
  // (e.g. `git checkout <T> -- .` with HEAD still diverged).
  const dir = mkRepo();
  try {
    write(dir, "a.ts", "a\n");
    write(dir, "b.ts", "b\n");
    git(dir, ["add", "."]);
    git(dir, ["commit", "-qm", "base"]);
    git(dir, ["update-ref", "refs/remotes/origin/main", "HEAD"]);
    // Diverge HEAD with a branch-only file, then make the index EXACTLY T's tree.
    write(dir, "c.ts", "c\n");
    git(dir, ["add", "."]);
    git(dir, ["commit", "-qm", "diverge"]);
    // --no-overlay is REQUIRED: a plain `checkout <T> -- .` is an OVERLAY, so it
    // restores a.ts/b.ts but leaves the branch-only c.ts in the index — the
    // per-arm diff is then non-empty and the `out === ""` path is never reached
    // (that made this pin vacuous against the old `return null`).
    git(dir, ["checkout", "--no-overlay", "refs/remotes/origin/main", "--", "."]);
    // Anti-vacuity: the per-arm diff really is zero bytes.
    assert.equal(git(dir, ["diff", "--no-renames", "--raw", "-z", "refs/remotes/origin/main", "--cached"]), "",
      "fixture must actually produce an EMPTY per-arm diff");
    const bundle = makeSubBundle(dir);
    assert.notEqual(bundle, null);
    const ctx = makeGitSubCtx(dir, { bundle: bundle!, arm: "staged", recordedSide: "index" });
    assert.notEqual(ctx, null);
    // With a PROVABLY empty diff the path genuinely does not differ from T, so
    // `differsFromBase` is `false` — NOT the fail-closed `true` that a failed
    // probe yields. The fail-closed `true` is a different code path, pinned
    // separately.
    assert.equal(ctx!.differsFromBase("a.ts"), false,
      "an empty diff means nothing differs — not a parse failure");
    // Guards (0)/(1)/(2) all hold for the whole restored tree, so EVERY eligible
    // path is subtracted. Under the old code this returned the full list.
    const scope: DiffScope = { files: ["a.ts", "b.ts"], renameOldPaths: [], clean: true };
    const r = subtractCommitArm(scope, new Map([["a.ts", "M"], ["b.ts", "M"]]), ctx);
    assert.deepEqual(r.scope.files, [],
      "an all-identical recorded side must subtract every eligible path, not none");
    assert.deepEqual(r.audit?.perArmSubtracted, ["a.ts", "b.ts"],
      "and the audit records them (anti-vacuity: a no-op would leave this absent)");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("#755 REAL GIT — the branch arm resolves HEAD ONCE (subprocess-count pin, not an OID-equality pin)", () => {
  // ⛔ An OID-equality assertion CANNOT pin this: with no concurrent writer both
  // the old (two probes) and new (one probe + reuse) code return the same OID, so
  // such a pin is green against the bug — verified by sabotage. The only
  // observable difference is the NUMBER of `rev-parse` calls, so count them with a
  // PATH shim. (This is also the plan's Task 2 "count pin on a PATH shim", which
  // was otherwise never implemented.)
  const dir = mkRepo();
  const shimDir = mkdtempSync(join(tmpdir(), "vg755-shim-"));
  const realGit = execFileSync("sh", ["-c", "command -v git"], { encoding: "utf-8" }).trim();
  const log = join(shimDir, "calls.log");
  try {
    write(dir, "a.ts", "a\n");
    git(dir, ["add", "."]);
    git(dir, ["commit", "-qm", "base"]);
    git(dir, ["update-ref", "refs/remotes/origin/main", "HEAD"]);
    writeFileSync(log, "");
    writeFileSync(join(shimDir, "git"), `#!/bin/sh\nprintf '%s\\n' "$*" >> "${log}"\nexec "${realGit}" "$@"\n`, { mode: 0o755 });
    const prevPath = process.env.PATH;
    process.env.PATH = `${shimDir}:${prevPath}`;
    try {
      const bundle = makeSubBundle(dir);
      assert.notEqual(bundle, null);
      writeFileSync(log, "");
      const ctx = makeGitSubCtx(dir, {
        bundle: bundle!, arm: "branch", recordedSide: "ref", srcRef: "HEAD",
      });
      assert.notEqual(ctx, null);
      const calls = readFileSync(log, "utf-8").split("\n").filter((l) => l !== "");
      const headProbes = calls.filter((l) => l.startsWith("rev-parse ") && l.trim().endsWith("HEAD"));
      assert.equal(headProbes.length, 1,
        `the branch arm must probe HEAD exactly once (R reuses the pinned B OID); saw ${headProbes.length}: ${JSON.stringify(headProbes)}`);
      // Sanity: the shim really was in the path for these probes.
      assert.ok(calls.length >= 2, `shim must have observed the ctx build, saw ${calls.length} calls`);
      assert.equal(ctx!.recordedSideOid(), ctx!.b().oid);
    } finally {
      process.env.PATH = prevPath;
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
    rmSync(shimDir, { recursive: true, force: true });
  }
});

// ── THE ISOLATING pairMemo PIN ───────────────────────
// Without this, an implementation that caches a FAILED `diff T...B` as an empty
// Set passes everything else while subtracting every path whose recorded side
// matches T. Both membership diffs must be separated to observe it.
test("#755 ISOLATING — a failed per-pair `diff T...B` (and NOT the per-arm diff) blocks subtraction", () => {
  // Simulated at the primitive boundary: condition (1) is healthy (differsFromBase
  // false for base.ts) while the pair query is UNKNOWN (sentinel `true`).
  const ctx = mkCtx({
    differsFromBase: (p) => p !== "base.ts",
    differsFromBranchSide: () => true, // ← the failed-pair sentinel
  });
  const { files, audited } = runCommit(ctx, { ...SCOPE, files: ["base.ts"] }, new Map([["base.ts", "M"]]));
  assert.deepEqual(files, ["base.ts"], "an unknown pair verdict must NOT subtract");
  assert.equal(audited, false);
});

test("#755 ISOLATING — a failed per-arm diff (and NOT the pair diff) blocks subtraction", () => {
  const ctx = mkCtx({ differsFromBase: () => true, differsFromBranchSide: (p) => p !== "base.ts" });
  const { files, audited } = runCommit(ctx, { ...SCOPE, files: ["base.ts"] }, new Map([["base.ts", "M"]]));
  assert.deepEqual(files, ["base.ts"]);
  assert.equal(audited, false);
});
