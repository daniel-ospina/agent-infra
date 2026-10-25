// test-sanctioned-pin-merge-base.mjs — #2818: freshness is a property of a
// COMMIT, never of a merge result assembled from two of them.
//
// THE DEFECT THIS PINS. `verify` judged the pin by reading the pin and the
// sanctioned scripts out of the same CHECKOUT — which in a PR job is GitHub's
// synthetic MERGE of the head onto the base branch's tip. A merge result takes
// each file from whichever side changed it, so a branch that legitimately re-cut
// its pin beside its OWN sanctioned-script edit carried that pin next to the
// scripts an UNRELATED merge had since changed on `main`. The verdict therefore
// tracked how far `main` had moved, not what the change did: merging one PR turned
// every other open PR red, and re-cutting them only moved the problem to the next
// merge (the treadmill).
//
// THE THREE CASES THE ISSUE REQUIRES, and the one this suite additionally pins —
// the merged-tree INVERSION that proves the fix is load-bearing:
//
//   (a)  a change that does not touch the sanctioned surface element the base
//        branch moved PASSES, however far the base has moved …
//   (a′) … while the SAME commit, judged on the merged tree (the pre-#2818
//        reading, `diskTree`), FAILS. Revert `--ref` in ci.yml and this suite
//        reds: that inversion is the non-vacuity proof.
//   (b)  a change that edits a sanctioned script WITHOUT re-cutting FAILS.
//   (b′) a change that DELETES one without re-cutting FAILS (a removal is stale
//        too — the pin would exempt a relpath the tree no longer ships).
//   (c)  a change that edits it AND re-cuts PASSES.
//
// Zero-dep: `node:*` + the `git` binary, hermetic repos under `os.tmpdir()`.
// Run: node extensions/main-worktree-guard/test-sanctioned-pin-merge-base.mjs
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { computePin, diskTree, gitTree, parseRefArg, pinReport, PIN_REL } from "./sanctioned-pin-tree.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = join(HERE, "..", "..");

const INDEX_REL = "extensions/main-worktree-guard/index.ts";
const RAIL = "scripts/admin-merge.sh"; // the leaf `main` moves in these fixtures
const REVIEW = "scripts/record-review.sh"; // the leaf a PR moves in case (a)
const HELPER = "scripts/lib/diff-normalize.py"; // part of the delegation closure

const INDEX_SRC = [
  "// fixture: the sanctioned leaf set, in the shipped format",
  "const SANCTIONED_SCRIPT_RELPATHS = [",
  `  "${RAIL}",`,
  `  "${REVIEW}",`,
  "];",
  "",
].join("\n");
const railV1 = '#!/bin/bash\nhelper="$(dirname "$0")/lib/diff-normalize.py"\npython3 "$helper" "$@" # rail v1\n';
const railV2 = '#!/bin/bash\nhelper="$(dirname "$0")/lib/diff-normalize.py"\npython3 "$helper" "$@" # rail v2\n';
const reviewV1 = "#!/bin/bash\necho review v1\n";
const reviewV2 = "#!/bin/bash\necho review v2\n";

let pass = 0, fail = 0;
function expect(name, got, expected) {
  const ok = JSON.stringify(got) === JSON.stringify(expected);
  console.log(`${ok ? "✅" : "❌"} ${name}: ${JSON.stringify(got)}${ok ? "" : ` (expected ${JSON.stringify(expected)})`}`);
  ok ? pass++ : fail++;
}

function write(root, rel, content) {
  const p = join(root, rel);
  mkdirSync(dirname(p), { recursive: true });
  writeFileSync(p, content);
}

function git(root, ...args) {
  return execFileSync("git", args, { cwd: root, stdio: ["ignore", "pipe", "pipe"] }).toString().trim();
}

/** The pin for `root`'s CURRENT working tree, committed — exactly what `--cut`
 *  does on a branch (`--cut` is the only sanctioned way to move the artifact, so a
 *  fixture that hand-writes digests would not prove anything about real PRs). */
function cutAndCommit(root, message) {
  const doc = computePin(diskTree(root), "fixture pin — #2818");
  writeFileSync(join(root, PIN_REL), JSON.stringify(doc, null, 2) + "\n");
  git(root, "add", "-A");
  git(root, "commit", "-qm", message);
}

/** A hermetic framework checkout with a committed, fresh pin on `main`. */
function makeRepo() {
  const root = mkdtempSync(join(tmpdir(), "sanctioned-pin-merge-base-"));
  git(root, "init", "-q", "-b", "main");
  git(root, "config", "user.email", "t@t");
  git(root, "config", "user.name", "t");
  write(root, "manifest.json", "{}\n");
  write(root, "README.md", "fixture\n");
  write(root, INDEX_REL, INDEX_SRC);
  write(root, RAIL, railV1);
  write(root, REVIEW, reviewV1);
  write(root, HELPER, "# helper v1\n");
  git(root, "add", "-A");
  git(root, "commit", "-qm", "base");
  cutAndCommit(root, "base: cut the pin");
  return root;
}

/** Commit `mutate` on a branch cut from `main`, then move `main` on (a DIFFERENT
 *  sanctioned script, so the two sides never conflict — the point is an UNRELATED
 *  merge), then materialise the merge GitHub would build and check both readings. */
function scenario(name, { branch = null, mainMoves = false }) {
  const root = makeRepo();
  const head = (() => {
    if (!branch) return "main";
    git(root, "checkout", "-q", "-b", "pr");
    branch(root);
    return "pr";
  })();
  if (mainMoves) {
    git(root, "checkout", "-q", "main");
    write(root, REVIEW, reviewV2);
    write(root, HELPER, "# helper v2\n");
    cutAndCommit(root, "main: an unrelated merge moves the sanctioned surface");
  }
  git(root, "checkout", "-q", "main");
  if (head !== "main") {
    try {
      git(root, "merge", "-q", "--no-ff", "-m", "merge pr", head);
    } catch {
      // Both sides re-cut the pin, so the MERGE ITSELF conflicts on that one file
      // — the shape every lane hit on this repo. Resolve it the way a lane does
      // ("keep MY re-cut", i.e. the branch's pin) and leave the merged tree with
      // the branch's pin beside main's scripts: that is the artifact `verify`
      // judged, and the reason the verdict tracked main's movement.
      git(root, "checkout", "--theirs", "--", PIN_REL);
      git(root, "add", "--", PIN_REL);
      git(root, "commit", "-qm", "merge pr (pin conflict kept from the branch)");
    }
  }
  const headSha = git(root, "rev-parse", head === "main" ? "HEAD" : `refs/heads/${head}`);
  return { root, headSha, head: gitTree(root, headSha), merged: diskTree(root) };
}

const staleOf = (tree) => pinReport(tree).stale;

try {
  // ── (a0) a pristine branch: nothing to re-cut, however far `main` has moved ──
  {
    const { root, head } = scenario("a0", {
      branch: (r) => { write(r, "README.md", "fixture + an unrelated edit\n"); git(r, "add", "-A"); git(r, "commit", "-qm", "docs: unrelated"); },
      mainMoves: true,
    });
    expect(`(a0) a change that touches nothing sanctioned PASSES with the base moved (judged on ${head.ref})`,
      staleOf(head), []);
    rmSync(root, { recursive: true, force: true });
  }

  // ── (a) the change re-cut beside ITS OWN leaf; an UNRELATED merge moved another
  //        sanctioned script on main. This is the treadmill shape: the merged tree
  //        carries the branch's pin next to main's scripts. ──
  {
    const root = makeRepo();
    git(root, "checkout", "-q", "-b", "pr");
    write(root, REVIEW, reviewV2);
    cutAndCommit(root, "pr: review script + re-cut");
    const prHead = git(root, "rev-parse", "pr");
    git(root, "checkout", "-q", "main");
    write(root, RAIL, railV2); // an UNRELATED sanctioned script changes on main
    write(root, HELPER, "# helper v2\n");
    cutAndCommit(root, "main: an unrelated merge moves the sanctioned surface");
    git(root, "checkout", "-q", "main");
    try {
      git(root, "merge", "-q", "--no-ff", "-m", "merge pr", prHead);
    } catch {
      git(root, "checkout", "--theirs", "--", PIN_REL);
      git(root, "add", "--", PIN_REL);
      git(root, "commit", "-qm", "merge pr (pin conflict kept from the branch)");
    }

    const head = gitTree(root, prHead);
    const merged = diskTree(root);
    // The change does not touch the leaf main moved — proven, not assumed.
    const touched = git(root, "diff", "--name-only", `${git(root, "merge-base", "HEAD", prHead)}`, prHead)
      .split("\n").filter(Boolean);
    expect("(a) the fixture's PR does NOT touch the sanctioned script the base branch moved",
      touched.includes(RAIL), false);
    expect(`(a) …and PASSES, however far the base has moved (judged on ${head.ref})`, staleOf(head), []);
    // NON-VACUITY: the pre-#2818 reading — this same commit, judged on the merged
    // tree — FAILS. If this arm ever passes, the fix has become inert (or the
    // fixture has stopped reproducing the treadmill) and this suite is lying.
    expect("(a′) NON-VACUITY: the SAME change judged on the MERGED tree FAILS (the pre-#2818 reading; reverting `--ref` reds this)",
      staleOf(merged).length > 0, true);
    rmSync(root, { recursive: true, force: true });
  }

  // ── (b) touches a sanctioned script WITHOUT re-cutting ⇒ FAILS ──
  {
    const { root, head } = scenario("b", {
      branch: (r) => { write(r, RAIL, railV2); git(r, "add", "-A"); git(r, "commit", "-qm", "pr: edit the rail, no re-cut"); },
    });
    expect(`(b) a change that edits ${RAIL} WITHOUT re-cutting FAILS`,
      staleOf(head).includes(RAIL), true);
    rmSync(root, { recursive: true, force: true });
  }

  // ── (b′) DELETES a sanctioned script WITHOUT re-cutting ⇒ FAILS ──
  {
    const { root, head } = scenario("b2", {
      branch: (r) => { rmSync(join(r, REVIEW)); git(r, "add", "-A"); git(r, "commit", "-qm", "pr: delete a sanctioned script, no re-cut"); },
    });
    expect(`(b′) a change that DELETES ${REVIEW} without re-cutting FAILS (a removal is stale too)`,
      staleOf(head).includes(`${REVIEW} (missing)`), true);
    rmSync(root, { recursive: true, force: true });
  }

  // ── (c) touches it AND re-cuts ⇒ PASSES (with the base moved, and without) ──
  for (const mainMoves of [false, true]) {
    const { root, head } = scenario("c", {
      branch: (r) => { write(r, RAIL, railV2); cutAndCommit(r, "pr: edit the rail + re-cut"); },
      mainMoves,
    });
    expect(`(c) a change that edits ${RAIL} AND re-cuts PASSES (base ${mainMoves ? "moved" : "unmoved"})`,
      staleOf(head), []);
    rmSync(root, { recursive: true, force: true });
  }

  // ── (b″) a pin that DROPPED a delegate is stale, not fresh ──
  // Both directions of the closure must be part of the freshness verdict: the
  // shipped gate asserted "the pin names every executed helper" separately, so a
  // `stale` that only walked pin→tree reported a shrunk closure as fresh — and any
  // caller trusting it alone (this suite included) would have turned that into a
  // false PASS on exactly the `ci_exemption.py` class the closure exists for.
  {
    const root = makeRepo();
    const doc = computePin(diskTree(root), "fixture pin — #2818");
    const dropped = Object.keys(doc.delegates).find((r) => r === HELPER) ?? Object.keys(doc.delegates)[0];
    delete doc.delegates[dropped];
    writeFileSync(join(root, PIN_REL), JSON.stringify(doc, null, 2) + "\n");
    git(root, "add", "-A");
    git(root, "commit", "-qm", "pr: drop a delegate from the pin, leave the script executing it");
    expect(`(b″) a pin whose closure DROPPED ${dropped} (still executed) FAILS`,
      staleOf(gitTree(root, "HEAD")).includes(`${dropped} (unpinned delegate)`), true);
    rmSync(root, { recursive: true, force: true });
  }

  // ── (r) the reference argument itself: no silent fall back ──
  // `--ref ""` selecting the working tree is the treadmill returning invisibly:
  // the check would read the merged tree again and report green.
  {
    const throws = (argv) => { try { parseRefArg(argv); return false; } catch { return true; } };
    expect("(r1) `--ref` with an empty value is an ERROR, not a fall back to the working tree",
      throws(["--ref", ""]), true);
    expect("(r1) `--ref` with no value is an ERROR", throws(["--ref"]), true);
    expect("(r2) no `--ref` means the working tree (a push to main, or the change itself)",
      parseRefArg([]).ref, null);
    expect("(r3) `--ref <rev>` selects that commit", parseRefArg(["--ref", "abc123"]).ref, "abc123");
  }

  // ── WIRING: the fix is only a fix where CI actually judges the change's commit.
  // The check is a no-op gate if the step omits `--ref` (the merged tree is read
  // again) or if the checkout cannot see the head commit. Both are asserted here
  // because neither failure has any other symptom. ──
  {
    const ci = readFileSync(join(REPO, ".github/workflows/ci.yml"), "utf-8");
    const verifyBlock = (() => {
      const at = ci.indexOf("\n  verify:\n");
      if (at < 0) return null;
      const rest = ci.slice(at + 1);
      const next = rest.slice(1).search(/\n  [a-z][a-z0-9-]*:\n/);
      return next < 0 ? rest : rest.slice(0, next + 1);
    })();
    expect("(w0) ci.yml's `verify` job exists", verifyBlock !== null, true);
    if (verifyBlock) {
      // ⛔ COMMENT LINES ARE STRIPPED FIRST. These comments quote the very
      // literals asserted below (`--ref …`, `fetch-depth: 2`, this suite's
      // filename), so a substring test over the raw block stays TRUE after the
      // run lines are deleted — an assertion that cannot fail, guarding the one
      // failure it exists for (review P2, 2026-10-25). Only executable YAML is
      // searched, so each assertion is falsified by removing what it names.
      const live = verifyBlock.split("\n").filter((l) => !/^\s*#/.test(l)).join("\n");
      expect("(w1) …judges freshness on the PR HEAD COMMIT, not the synthetic merge",
        live.includes('test-sanctioned-identity.mjs --ref "${{ github.event.pull_request.head.sha }}"'), true);
      expect("(w2) …and its checkout carries the merge commit's two parents (fetch-depth: 2), so the head tree is present",
        /actions\/checkout@v4\n\s+with:\n(?:\s+#.*\n)*\s+fetch-depth: 2/.test(live), true);
      expect("(w3) …and this suite runs in the same job (an unwired suite passes by never running)",
        /^\s+(?:run:|- run:)\s*node extensions\/main-worktree-guard\/test-sanctioned-pin-merge-base\.mjs\s*$/m.test(live), true);
    }
    expect("(w4) the post-merge lane collects this suite by the extensions/*/test*.mjs glob",
      /(^|\/)test[^/]*\.mjs$/.test("extensions/main-worktree-guard/test-sanctioned-pin-merge-base.mjs"), true);
  }
} finally {
  // every fixture repo is removed by its arm; nothing global to clean up
}

console.log(`\n${fail === 0 ? "✅" : "❌"} ${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
