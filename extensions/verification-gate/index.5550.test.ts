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
 *       reported main's whole 12-commit delta. D1 is the direction that proves
 *       the narrowing FIRES. D2 ALSO fails pre-fix (the branch's own file is
 *       absent from main's-delta scope), so D1/D2 are not opposite directions —
 *       D2 guards the empty-scope failure D1 alone would not catch.
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
// Hermetic git config. The #1491 narrowing now reads `vgate.integrationRef` from
// git config, so an AMBIENT global/system config carrying a declaration would
// make the no-declaration fixtures (F4/F5/F6) narrow against the wrong ref. Pin
// GIT_CONFIG_GLOBAL to an empty temp file and disable the system config.
const TEST_GITCONFIG = join(TEST_ROOT, ".gitconfig");
writeFileSync(TEST_GITCONFIG, "");
process.env.GIT_CONFIG_GLOBAL = TEST_GITCONFIG;
process.env.GIT_CONFIG_SYSTEM = "/dev/null";
process.env.GIT_CONFIG_NOSYSTEM = "1";

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

/** Declare the integration ref via the per-clone config surface (#1491) — the
 * ONLY surface that activates the narrowing. A checked-in file cannot: it is a
 * shared, clone-relative name, so a fork clone inherits `origin/main` where
 * `origin` is the FORK. */
function declareByConfig(repo: string, ref: string): void {
  git(repo, `config vgate.integrationRef ${ref}`);
}

/** Write the checked-in `.vgate/integration-ref` (#1491) — an AGREEMENT TRIPWIRE,
 * not an activation surface. When present it must match the config, else the
 * declaration is refused. Landing it documents the repo's intended ref; it does
 * NOT narrow on its own (that is the fork-vector fail-open, one level up). */
function declareByFile(repo: string, ref: string): void {
  mkdirSync(join(repo, ".vgate"), { recursive: true });
  writeFileSync(join(repo, ".vgate", "integration-ref"), ref + "\n");
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
  // #1491 — the narrowing now requires an explicit declaration. These fixtures
  // are ordinary single-remote repos whose integration ref is `origin/main`, so
  // the operator's declaration is what activates the narrowing (D1–D3).
  declareByConfig(repo, "refs/remotes/origin/main");
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

// ══ DIRECTION (b) — THE CASES THE NARROWING MUST REFUSE ══
//
// These are the fail-opens adversarial reviews found across TWO versions of this
// fix: an ABSENT baseMain (F1), a behind-base --force push (F2), and a DECLARED
// topic upstream (F3) from the abandoned PR #1494; plus the two vectors of
// agent-infra #1491 that closed the NAME-based guard — a FORK's `main` named
// `origin/main` (F4) and a legacy `main` on a master-default remote (F5).
//
// The landed implementation (#1484 + #1491) closes:
//   F1 STRUCTURALLY, by keeping `baseRef = tracking` for tier A and overriding it
//      only when every guard passes (`narrowedBase ?? baseRef`), so the
//      missing-ref path is unreachable;
//   F2 with the tri-state `isAncestorOrEqual(...) === true` proof;
//   F3/F4/F5 with the DECLARATION guard: the base must EQUAL an explicitly
//      declared integration ref, so a base that is not it (a topic upstream, a
//      fork's `main`, a legacy `main`) keeps the wider pre-#3716 scope.
//
// LOAD-BEARING MATRIX — each guard neutered, and which direction catches it.
// Reproduced by mutation on this tree. "." = green, "X" = red. The first six
// columns are the ORIGINAL matrix; its pairings (G1→F2, G2→F3, G3→D3/F1/F3)
// must not drift:
//
//   mutation                                      D1 D2 D3 F1 F2 F3
//   --------------------------------------------------------------
//   (none — the landed code)                       .  .  .  .  .  .
//   G1  tri-state proof forced true                .  .  .  .  X  .
//   G2  declared-ref EQUALITY removed (the
//       declaration is still required)             .  .  .  .  .  X
//   G3  baseRef = baseMain (the UNCONDITIONAL
//       form — NOT #1494's ancestry-conditional
//       form, which gave a different row)          .  .  X  X  .  X
//
// This is the ORIGINAL matrix; its pairings (G1→F2, G2→F3, G3→D3/F1/F3) are
// unchanged. The two #1491 vectors, F4 (fork-as-origin) and F5 (legacy `main`),
// are witnessed by the declaration REQUIREMENT. F5 ALSO reddens under G3 — its
// `baseMain` IS the legacy `main` in that fixture — so G3's row above is scoped
// to the original six directions:
//
//   mutation                              F4 F5
//   ---------------------------------------------
//   (none — the landed code)                .  .
//   G1 tri-state proof forced true          .  .
//   G2 declared-ref equality removed        .  .
//   G3 baseRef = baseMain (unconditional)   .  X
//   G4 declaration requirement removed      X  X
//
// Reproduced by mutation on this tree (each mutation applied to `index.ts`, the
// suite run, the file restored). Against the RETIRED name guard, F4 and F5 are
// the only two REDs — the #1491 fail-opens this change closes.
//
// So F2 witnesses the tri-state proof; F3 witnesses the declared-ref equality;
// F4/F5 witness the declaration requirement (the #1491 guard). All LOAD-BEARING,
// not decorative. F1 has NO guard to remove: it is a REGRESSION guard witnessing
// the retained tier-A base, and it reddens on demand under G3, the shape that
// reintroduces the missing-ref path. It is deliberately NOT presented as a
// witness to any new guard, because no neutering of the landed code reddens it —
// removing `baseOid !== null`, the OID checks OR either declaration conjunct
// leaves F1 green.
//
// Without this, "#1484 is safe" is an assertion about code nobody exercised.

section("#3716/F1 — an ABSENT baseMain must still BLOCK, never empty-allow");

test("F1: no origin/main + a rewritten branch → the authored file is still demanded", () => {
  // Tier A is selected on `trackingExists` ALONE, so a repo whose remote has no
  // `main` (master-default remote, renamed default, `--single-branch` clone)
  // reaches the narrowing with baseMain ABSENT. Without the guard the argv names
  // a missing ref, `git diff` exits 128, the catch yields null, null degrades to
  // the STAGED scope, and a clean index makes that EMPTY — an allow.
  const remote = join(TEST_ROOT, "f1.git");
  mkdirSync(remote, { recursive: true });
  git(remote, "init -q --bare -b master");
  const repo = join(TEST_ROOT, "f1");
  mkdirSync(repo, { recursive: true });
  git(repo, "init -q -b master");
  git(repo, "config user.email 5550@test");
  git(repo, "config user.name 5550");
  git(repo, "remote add origin " + remote);
  writeFileSync(join(repo, "seed.ts"), "s\n");
  git(repo, "add .");
  git(repo, "commit -q -m seed");
  git(repo, "push -q -u origin master");
  git(repo, "checkout -q -b feature");
  writeFileSync(join(repo, "owned.ts"), "o1\n");
  git(repo, "add .");
  git(repo, "commit -q -m owned");
  git(repo, "push -q -u origin feature");
  writeFileSync(join(repo, "owned.ts"), "o2\n");
  git(repo, "add .");
  git(repo, "commit -q --amend -m owned2"); // tracking is now NOT an ancestor
  equal(git(repo, "show-ref --verify --quiet refs/remotes/origin/main || echo ABSENT"), "ABSENT",
    "F1: (fixture) the remote has NO main ref — this is the baseMain-absent shape");
  equal(git(repo, "status --porcelain"), "",
    "F1: (fixture) the index is CLEAN, so a staged fallback would be EMPTY — what makes the fail-open silent");
  // #1491 — DECLARED (per-clone config), but the declared ref does not resolve:
  // the declaration must not narrow. The checked-in file AGREES (tripwire).
  declareByConfig(repo, "refs/remotes/origin/main");
  declareByFile(repo, "refs/remotes/origin/main");
  const scope = resolvePushRangeScope("git push origin feature", repo);
  ok(scope !== null,
    "F1: the resolver must return a scope, not null — null degrades to the staged scope and a clean index makes that an ALLOW");
  ok(files(scope!.files.join("\n")).includes("owned.ts"),
    "F1: the authored file must still be DEMANDED — RED under G3 (the abandoned unconditional base), NOT under any neutering of the landed guards; this is a regression guard for the retained tier-A `tracking` base");
});

section("#3716/F2 — a behind-base --force push must BLOCK, not report a false-empty range");

test("F2: reset behind the base + push --force → the rewound content is still demanded", () => {
  // If srcRef is an ancestor of baseMain, `baseMain...src` is EMPTY while tracking
  // need not be an ancestor — so the narrowing fires and reports an up-to-date
  // no-op for a push that REWINDS content. Without the tri-state guard this is an
  // allow; the guard only narrows on a PROVEN positive.
  const remote = join(TEST_ROOT, "f2.git");
  mkdirSync(remote, { recursive: true });
  git(remote, "init -q --bare -b main");
  const repo = join(TEST_ROOT, "f2");
  mkdirSync(repo, { recursive: true });
  git(repo, "init -q -b main");
  git(repo, "config user.email 5550@test");
  git(repo, "config user.name 5550");
  git(repo, "remote add origin " + remote);
  writeFileSync(join(repo, "base.txt"), "v1\n");
  git(repo, "add .");
  git(repo, "commit -q -m O");
  const O = git(repo, "rev-parse HEAD");
  git(repo, "push -q -u origin main");
  writeFileSync(join(repo, "base.txt"), "v2\n"); // main advances: this is the base
  git(repo, "add .");
  git(repo, "commit -q -m M");
  git(repo, "push -q origin main");
  git(repo, "checkout -q -b feature");
  writeFileSync(join(repo, "base.txt"), "v3\n");
  writeFileSync(join(repo, "feat.ts"), "f\n");
  git(repo, "add .");
  git(repo, "commit -q -m T");
  git(repo, "push -q -u origin feature");
  git(repo, "reset -q --hard " + O); // BEHIND the base
  // #1491 — the integration ref is DECLARED (origin/main); the tri-state proof
  // is what must refuse the narrowing (proof 1 fails: base is not an ancestor).
  declareByConfig(repo, "refs/remotes/origin/main");
  const scope = resolvePushRangeScope("git push --force origin feature", repo);
  ok(scope !== null, "F2: the resolver must return a scope, not null");
  const got = files(scope!.files.join("\n"));
  ok(got.includes("base.txt"),
    "F2: the content this force push REWINDS (base.txt) must be demanded — a false-empty merge-base range would allow it (RED without the tri-state guard)");
  ok(got.length > 0, "F2: the scope must never be empty for a push that rewinds the remote");
});

section("#1491/F3 — the narrowing base must be the DECLARED integration ref — a declared TOPIC upstream is not it");

test("F3: a DECLARED topic upstream must not become the narrowing's base", () => {
  // The measured fail-open this guard exists for (#3716, 2026-09-25):
  // `resolveTrustedBase` PREFERS a declared upstream (`branch.<cur>.merge`), and
  // that ref can be a TOPIC branch. The narrowing omits every path the pushed tip
  // shares with its base — so a topic base omits content the push LANDS on the
  // remote and ships it unverified. Here `branch.work.merge` is `refs/heads/develop`
  // and the branch is rebased onto `origin/develop`: narrowing against it hides
  // `D.txt` (develop-only, never integrated). Without the declaration guard the
  // scope is `["owned.ts"]`; with it, the wider pre-#3716 range demands `D.txt`.
  //
  // ⛔ An earlier version of this scenario used a FORK remote and passed WITH AND
  // WITHOUT the guard — it never provoked a non-integration base, because the
  // trusted base resolved to the legitimate `origin/main`. A passing test that
  // cannot fail is not evidence, so it was rebuilt against the real repro.
  const remote = join(TEST_ROOT, "f3.git");
  mkdirSync(remote, { recursive: true });
  git(remote, "init -q --bare -b main");
  const repo = join(TEST_ROOT, "f3");
  mkdirSync(repo, { recursive: true });
  git(repo, "init -q -b main");
  git(repo, "config user.email 5550@test");
  git(repo, "config user.name 5550");
  git(repo, "remote add origin " + remote);
  writeFileSync(join(repo, "seed.ts"), "s\n");
  git(repo, "add .");
  git(repo, "commit -q -m seed");
  git(repo, "push -q -u origin main");
  // `develop` is a TOPIC branch carrying D.txt, which origin/main never had.
  git(repo, "checkout -q -b develop main");
  writeFileSync(join(repo, "D.txt"), "d\n");
  git(repo, "add .");
  git(repo, "commit -q -m develop-D");
  git(repo, "push -q origin develop");
  git(repo, "checkout -q main");
  // `work` DECLARES develop as its upstream — this is what makes the trusted base
  // a topic branch rather than the integration branch.
  git(repo, "checkout -q -b work main");
  writeFileSync(join(repo, "owned.ts"), "o\n");
  git(repo, "add .");
  git(repo, "commit -q -m owned");
  // `-u` first (it creates refs/remotes/origin/work AND would OVERWRITE the
  // declared upstream), THEN declare develop as the upstream — the order matters,
  // and the fixture assertion below is what caught it.
  git(repo, "push -q -u origin work");
  git(repo, "config branch.work.remote origin");
  git(repo, "config branch.work.merge refs/heads/develop");
  // Rebase onto the TOPIC base — the narrowing's trigger; tracking diverges.
  git(repo, "rebase -q origin/develop");
  // #1491 — the operator declares the HOUSE integration ref, and the checked-in
  // file AGREES (tripwire). The resolved base is the topic upstream
  // (`origin/develop`), which does NOT equal the declaration, so the narrowing
  // must be refused.
  declareByConfig(repo, "refs/remotes/origin/main");
  declareByFile(repo, "refs/remotes/origin/main");
  equal(git(repo, "config branch.work.merge"), "refs/heads/develop",
    "F3: (fixture) the declared upstream must be the topic branch, or the trusted base is the integration branch and this case is not exercised");
  const tracking = "refs/remotes/origin/work";
  ok(git(repo, `merge-base ${tracking} refs/heads/work`) !== git(repo, `rev-parse ${tracking}`),
    "F3: (fixture) the branch must be DIVERGED from its tracking ref — the narrowing's trigger");
  const scope = resolvePushRangeScope("git push --force origin work", repo);
  ok(scope !== null, "F3: the resolver must return a scope, not null");
  const got = files(scope!.files.join("\n"));
  ok(got.length > 0,
    "F3: the scope must never be empty for a push that lands never-integrated content");
  // NOTE: `owned.ts` is deliberately NOT asserted here. It is byte-identical in the
  // tracking ref and the rebased head, so it is not part of the wider 2-dot delta —
  // it was verified when it was first pushed. The scope this direction must produce
  // is exactly the over-demand that makes the guard fail-closed: D.txt, which the
  // integration branch never had.
  equal(got.join(","), "D.txt",
    "F3: the guarded scope is the wider pre-#3716 delta — exactly [D.txt], the develop-only path the push lands",
  );
});

section("#1491/F4 — a FORK's `main` named `origin/main` must NOT become the narrowing base (fail-open, now BLOCKS)");

test("F4: fork-as-origin + push to upstream → the fork-only content the push LANDS is still demanded", () => {
  // agent-infra #1491, the first vector. `resolveTrustedBase` falls back to
  // `refs/remotes/origin/main`, which in a fork-as-`origin` layout is the FORK's
  // main. The old NAME guard accepted it, narrowed against the fork, and omitted
  // `fork-only.ts` — content the push LANDS on the CANONICAL remote (`upstream`).
  // With the #1491 declaration guard there is no declaration here, so the
  // narrowing is refused and the pre-#3716 range keeps `fork-only.ts`.
  const upstream = join(TEST_ROOT, "f4-upstream.git");
  mkdirSync(upstream, { recursive: true });
  git(upstream, "init -q --bare -b main");
  const fork = join(TEST_ROOT, "f4-fork.git");
  mkdirSync(fork, { recursive: true });
  git(fork, "init -q --bare -b main");
  const repo = join(TEST_ROOT, "f4");
  mkdirSync(repo, { recursive: true });
  git(repo, "init -q -b main");
  git(repo, "config user.email 5550@test");
  git(repo, "config user.name 5550");
  git(repo, "remote add origin " + fork);
  git(repo, "remote add upstream " + upstream);
  writeFileSync(join(repo, "baseline.ts"), "baseline\n");
  git(repo, "add .");
  git(repo, "commit -q -m baseline");
  git(repo, "push -q -u upstream main"); // canonical main = baseline
  // The FORK's main advances with content the canonical remote never integrates.
  git(repo, "checkout -q -b forkbase main");
  writeFileSync(join(repo, "fork-only.ts"), "fork\n");
  git(repo, "add .");
  git(repo, "commit -q -m fork-only");
  git(repo, "push -q origin forkbase:main"); // fork main = baseline + fork-only.ts
  git(repo, "checkout -q main");
  // feat is built on UPSTREAM/main, pushed to upstream/feat, then rebased onto the
  // FORK's main — so HEAD carries fork-only.ts but its tracking ref does not.
  git(repo, "checkout -q -b feat");
  writeFileSync(join(repo, "feat.ts"), "feat\n");
  git(repo, "add .");
  git(repo, "commit -q -m feat-work");
  git(repo, "push -q -u upstream feat"); // branch.feat.remote = upstream; tracking = baseline+feat
  git(repo, "fetch -q origin");
  git(repo, "rebase -q origin/main"); // rebased onto the FORK's main
  equal(git(repo, "config branch.feat.remote"), "upstream",
    "F4: (fixture) the branch's push remote must be `upstream` — the canonical remote");
  ok(git(repo, "rev-parse --verify refs/remotes/origin/main").length >= 40,
    "F4: (fixture) the fork's `origin/main` exists — the ref the old name guard accepted");
  equal(files(git(repo, "diff --name-only refs/remotes/upstream/feat HEAD")).join(","), "fork-only.ts",
    "F4: (fixture) the pre-#3716 2-dot range is `fork-only.ts` — what the push LANDS on the canonical remote");
  equal(files(git(repo, "diff --name-only refs/remotes/origin/main HEAD")).join(","), "feat.ts",
    "F4: (fixture) the OLD narrowing range (3-dot against the FORK's main) is only `feat.ts` — it omits the landed content");
  // NO declaration: the fail-closed default.
  const scope = resolvePushRangeScope("git push --force upstream feat", repo);
  ok(scope !== null, "F4: the resolver must return a scope, not null");
  const got = files(scope!.files.join("\n"));
  ok(got.includes("fork-only.ts"),
    "F4: `fork-only.ts` (landed on the canonical remote, byte-identical to the FORK's main) MUST be demanded — RED on the name guard, which narrowed against the fork and omitted it (BLOCK, not fail-open)");
});

section("#1491/F5 — a legacy `main` on a master-default remote must NOT become the narrowing base (fail-open, now BLOCKS)");

test("F5: origin/HEAD -> master with a legacy origin/main → the legacy-only content is still demanded", () => {
  // agent-infra #1491, the second vector (reviewer-reported, and in the same root
  // as the review's `origin/HEAD -> master` note): a single remote whose
  // integration branch is `master` also carries a legacy branch literally named
  // `main`. The old NAME guard accepted `refs/remotes/origin/main` as the
  // integration base, narrowed against the legacy branch, and omitted content the
  // push lands. With the #1491 declaration guard there is no declaration here, so
  // the narrowing is refused and the pre-#3716 range keeps `legacy-only.ts`.
  const remote = join(TEST_ROOT, "f5.git");
  mkdirSync(remote, { recursive: true });
  git(remote, "init -q --bare -b master"); // origin/HEAD -> master (the INTEGRATION branch)
  const repo = join(TEST_ROOT, "f5");
  mkdirSync(repo, { recursive: true });
  git(repo, "init -q -b master");
  git(repo, "config user.email 5550@test");
  git(repo, "config user.name 5550");
  git(repo, "remote add origin " + remote);
  writeFileSync(join(repo, "baseline.ts"), "baseline\n");
  git(repo, "add .");
  git(repo, "commit -q -m baseline");
  git(repo, "push -q -u origin master");
  // A legacy branch literally named `main`, carrying content master never had.
  git(repo, "checkout -q -b main master");
  writeFileSync(join(repo, "legacy-only.ts"), "legacy\n");
  git(repo, "add .");
  git(repo, "commit -q -m legacy");
  git(repo, "push -q origin main");
  git(repo, "checkout -q master");
  // feat built on master, pushed, then rebased onto the LEGACY main.
  git(repo, "checkout -q -b feat");
  writeFileSync(join(repo, "own.ts"), "own\n");
  git(repo, "add .");
  git(repo, "commit -q -m own");
  git(repo, "push -q -u origin feat"); // tracking = baseline + own
  git(repo, "fetch -q origin");
  git(repo, "symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master");
  git(repo, "rebase -q origin/main"); // rebased onto the LEGACY main
  equal(git(repo, "symbolic-ref --short refs/remotes/origin/HEAD"), "origin/master",
    "F5: (fixture) the remote's default branch must be `master` — the INTEGRATION branch");
  equal(files(git(repo, "diff --name-only refs/remotes/origin/feat HEAD")).join(","), "legacy-only.ts",
    "F5: (fixture) the pre-#3716 2-dot range is `legacy-only.ts` — legacy content the push lands");
  equal(files(git(repo, "diff --name-only refs/remotes/origin/main HEAD")).join(","), "own.ts",
    "F5: (fixture) the OLD narrowing range (3-dot against the legacy `main`) is only `own.ts` — it omits the landed legacy content");
  // NO declaration: the fail-closed default.
  const scope = resolvePushRangeScope("git push --force origin feat", repo);
  ok(scope !== null, "F5: the resolver must return a scope, not null");
  const got = files(scope!.files.join("\n"));
  ok(got.includes("legacy-only.ts"),
    "F5: `legacy-only.ts` (landed on the integration remote, byte-identical to the legacy `main`) MUST be demanded — RED on the name guard, which narrowed against the legacy `main` and omitted it (BLOCK, not fail-open)");
});

section("#1491/F6 — a CHECKED-IN declaration file alone must NOT narrow (the fork vector, one level up)");

test("F6: fork-as-origin + the SHIPPED `.vgate/integration-ref` but NO config → the landed content is still demanded", () => {
  // The #1491 decision ships `.vgate/integration-ref` = `refs/remotes/origin/main`
  // in agent-infra/tortoise. That value is a NAME, and it is checked in — so a
  // fork-as-`origin` clone INHERITS it, where `refs/remotes/origin/main` is the
  // FORK's main. If the file alone activated the narrowing, the fork vector F4
  // closes by absence would re-open by inheritance: the owner's stated "one
  // outcome this must not have". The per-clone config is the operator's
  // assertion; the file is only an agreement tripwire. No config here ⇒ no
  // narrowing, so the pre-#3716 range keeps `fork-only.ts`.
  const upstream = join(TEST_ROOT, "f6-upstream.git");
  mkdirSync(upstream, { recursive: true });
  git(upstream, "init -q --bare -b main");
  const fork = join(TEST_ROOT, "f6-fork.git");
  mkdirSync(fork, { recursive: true });
  git(fork, "init -q --bare -b main");
  const repo = join(TEST_ROOT, "f6");
  mkdirSync(repo, { recursive: true });
  git(repo, "init -q -b main");
  git(repo, "config user.email 5550@test");
  git(repo, "config user.name 5550");
  git(repo, "remote add origin " + fork);
  git(repo, "remote add upstream " + upstream);
  writeFileSync(join(repo, "baseline.ts"), "baseline\n");
  git(repo, "add .");
  git(repo, "commit -q -m baseline");
  git(repo, "push -q -u upstream main");
  git(repo, "checkout -q -b forkbase main");
  writeFileSync(join(repo, "fork-only.ts"), "fork\n");
  git(repo, "add .");
  git(repo, "commit -q -m fork-only");
  git(repo, "push -q origin forkbase:main");
  git(repo, "checkout -q main");
  git(repo, "checkout -q -b feat");
  writeFileSync(join(repo, "feat.ts"), "feat\n");
  git(repo, "add .");
  git(repo, "commit -q -m feat-work");
  git(repo, "push -q -u upstream feat");
  git(repo, "fetch -q origin");
  git(repo, "rebase -q origin/main");
  // The SHIPPED checked-in declaration — inherited, relative to the FORK's origin.
  declareByFile(repo, "refs/remotes/origin/main");
  equal(git(repo, "config --get vgate.integrationRef || echo UNSET"), "UNSET",
    "F6: (fixture) NO per-clone config — the file must not activate on its own");
  equal(files(git(repo, "diff --name-only refs/remotes/origin/main HEAD")).join(","), "feat.ts",
    "F6: (fixture) narrowing against the FORK's `origin/main` would omit the landed `fork-only.ts`");
  const scope = resolvePushRangeScope("git push --force upstream feat", repo);
  ok(scope !== null, "F6: the resolver must return a scope, not null");
  const got = files(scope!.files.join("\n"));
  ok(got.includes("fork-only.ts"),
    "F6: the INHERITED checked-in file alone must NOT narrow — `fork-only.ts` (landed on the canonical remote) MUST still be demanded; honoring the file without a per-clone assertion is the fail-open one level up");
});

section("#1491/F7 — the checked-in file is an AGREEMENT TRIPWIRE for the per-clone assertion");

test("F7: config alone activates; config + a DISAGREEING file is refused (fail closed)", () => {
  const { repo } = makeRepo("f7"); // makeRepo already sets the config + a bare origin
  git(repo, "checkout -q -b feature");
  writeFileSync(join(repo, "owned.ts"), "o\n");
  git(repo, "add .");
  git(repo, "commit -q -m owned");
  git(repo, "push -q -u origin feature");
  advanceMain(repo, 4);
  git(repo, "checkout -q feature");
  git(repo, "rebase -q origin/main");
  // Config asserts `origin/main` but the checked-in file asserts `origin/master`
  // — the two declarations disagree, so the shared, clone-relative one is refused.
  declareByFile(repo, "refs/remotes/origin/master");
  const g = (a: string) => git(repo, a);
  const baseOid = g("rev-parse refs/remotes/origin/main");
  const srcOid = g("rev-parse refs/heads/feature");
  const trackingOid = g("rev-parse refs/remotes/origin/feature");
  ok(g(`merge-base --is-ancestor ${baseOid} ${srcOid} && echo yes`) === "yes",
    "F7: (fixture) the declared base must be an ancestor — proof 1 would otherwise refuse for the wrong reason");
  ok(g(`merge-base --is-ancestor ${trackingOid} ${srcOid} || echo diverged`) === "diverged",
    "F7: (fixture) the tracking ref must be diverged — proof 2 would otherwise refuse for the wrong reason");
  const scope = resolvePushRangeScope("git push --force origin feature", repo);
  ok(scope !== null, "F7: the resolver must return a scope, not null");
  ok(files(scope!.files.join("\n")).includes("main-0.ts"),
    "F7: a DISAGREEING checked-in declaration must refuse the narrowing — main's delta is demanded again (fail closed)");
  // Now make the file AGREE: the declaration is confirmed and the narrowing fires.
  declareByFile(repo, "refs/remotes/origin/main");
  const agreed = resolvePushRangeScope("git push --force origin feature", repo);
  ok(agreed !== null, "F7: the resolver must return a scope, not null");
  equal(files(agreed!.files.join("\n")).join(","), "owned.ts",
    "F7: config + an AGREEING file confirms the declaration — the branch's own diff is the scope (the #3716 narrowing)");
});

console.log(`\n=== #5550 proof: ${passed} passed, ${failed} failed ===`);
rmSync(TEST_ROOT, { recursive: true, force: true });
if (failed > 0) process.exit(1);
console.log("✅ ALL #5550 PROOFS HELD");
