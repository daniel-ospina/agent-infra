// sanctioned-pin-tree.mjs — #2818: the pin and the surface it pins are read from
// ONE tree, never from two different commits glued together.
//
// THE DEFECT THIS EXISTS FOR. `sanctioned-scripts.pin.json` records the sha256 of
// the audited bytes of every sanctioned relpath (and of the delegation closure
// they execute by their own location). The freshness check asks a question about
// a CHANGE — "did this change drift the sanctioned surface without re-cutting?" —
// but it answered it by reading the pin out of the checkout and the scripts out of
// the same checkout, which in CI is GitHub's synthetic MERGE of the PR head onto
// the base branch's TIP. Those two sides of one merge result come from different
// commits, so the answer depended on how far `main` had moved instead of on what
// the change did: a branch that legitimately re-cut its pin for one sanctioned
// script went red the moment an unrelated merge changed another one, because the
// merge result carried the branch's pin beside `main`'s scripts. That is the
// treadmill in #2818 (merging re-invalidates the artifact on every other open PR).
//
// THE RULE. Freshness is a property of a COMMIT: "the pin agrees with the
// sanctioned surface as they both exist in this tree". Comparing the two sides of
// one commit answers the change question and cannot be invalidated by an unrelated
// merge, because `main`'s movement is not in that commit. `--ref <rev>` selects
// the commit (the PR head in CI); the default is the working tree, which is the
// correct (and only) reading on a push to `main`.
//
// ⛔ THE POLARITY THIS MUST KEEP — the check is not weakened, only re-anchored:
//   (a) a change that does not drift the sanctioned surface passes however far the
//       base branch has moved (nothing about the base is consulted);
//   (b) a change that DOES drift it — edits or deletes a pinned script or one of
//       its delegates — without re-cutting still FAILS (the pin in the same tree
//       no longer describes the bytes beside it);
//   (c) a change that drifts it AND re-cuts still PASSES.
// A version that always passes would be worse than the treadmill it replaces.
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join, posix } from "node:path";

/** The pin artifact, relative to a framework checkout root. */
export const PIN_REL = "extensions/main-worktree-guard/sanctioned-scripts.pin.json";
/** The module whose `SANCTIONED_SCRIPT_RELPATHS` list is the surface's leaf set. */
export const INDEX_REL = "extensions/main-worktree-guard/index.ts";
/** The framework fingerprint file: a tree without it is a deployed COPY, not the repo. */
export const FRAMEWORK_FINGERPRINT_REL = "manifest.json";

// The sanctioned relpaths are read from the SOURCE, not restated here: a suite
// with its own copy of the list goes green while the shipped list is edited.
const SANCTIONED_LIST_RE = /^\s+"(scripts\/[^"]+)",$/gm;

// ── the DELEGATION CLOSURE ────────────────────────────────────────────────
// Every file a sanctioned script executes BY ITS OWN LOCATION (`$SELF_DIR/x`,
// `$(dirname "$0")/x`) is part of the program that actually runs, so it is part
// of the identity: the exemption skips the content walk for the WHOLE
// invocation, and a pinned leaf beside an agent-chosen `ci_exemption.py` is a
// launcher, not the rail (reproduced at review). Computed from the script TEXT
// so the set cannot be forgotten — a new `$SELF_DIR/helper.sh` in any listed
// script appears here on the next `--cut`.
// The `$(dirname "$0")` family AND the `BASH_SOURCE[0]:-$0` family (which is what
// two sanctioned scripts actually use — `check-pipeline-compliance.sh` sources
// `$SELF_DIR/record-review.sh` and `record-review.sh` runs
// `$SELF_DIR/lib/diff-normalize.py`), with the `--` separator both spellings use.
const SELF_DIR_REF = /(?:\$\{?SELF_DIR\}?|\$\{?SCRIPT_DIR\}?|\$\(dirname\s+(?:--\s+)?"?(?:\$0|\$\{?BASH_SOURCE\[0\](?::-\$0)?\}?)"?\)|\$\(cd\s+(?:--\s+)?"?\$\(dirname\s+(?:--\s+)?"?(?:\$0|\$\{?BASH_SOURCE\[0\](?::-\$0)?\}?)"?\)"?\s*&&\s*pwd(?:\s+-P)?\)|\$\{?(?:BASH_SOURCE\[0\]|0)\}?%{1,2}\/\*)[\"/]*(\/?[A-Za-z0-9_.\-/]+\.(?:sh|py|bash|mjs|js|cjs))/g;

export const sha256 = (bytes) => createHash("sha256").update(bytes).digest("hex");

/**
 * A tree of files addressed by repo-relative path — the ONE source both sides of
 * the freshness comparison are read from.
 *
 * The working tree (`ref === null`, what `--cut` writes and what a push to `main`
 * must be judged against) and any committed git tree (`ref === "<rev>"`) expose
 * the same two operations, so the freshness rule cannot accidentally mix them.
 */
export function diskTree(root) {
  return {
    ref: null,
    root,
    label: `${root} (working tree)`,
    has: (rel) => existsSync(join(root, rel)),
    read: (rel) => (existsSync(join(root, rel)) ? readFileSync(join(root, rel)) : null),
  };
}

/**
 * The committed tree of `<rev>`, read through git plumbing.
 *
 * Throws (never silently degrades to the working tree) when `rev` is not a
 * readable tree: a check that cannot read its reference must not report a PASS
 * about some other tree. That failure mode is exactly how a pinned gate goes
 * inert, and the caller is expected to surface it as a FAIL with this message.
 */
export function gitTree(root, rev) {
  const git = (args) =>
    execFileSync("git", ["-C", root, ...args], { maxBuffer: 256 * 1024 * 1024 });
  let listing;
  try {
    listing = git(["ls-tree", "-r", "-z", "--name-only", rev]);
  } catch (e) {
    const detail = String((e && e.stderr) || (e && e.message) || e).trim().split("\n")[0];
    throw new Error(`cannot read tree ${JSON.stringify(rev)} in ${root} — ${detail}`);
  }
  const files = new Set(listing.toString("utf8").split("\0").filter(Boolean));
  const cache = new Map();
  return {
    ref: rev,
    root,
    label: `${rev} (git tree)`,
    has: (rel) => files.has(rel),
    read: (rel) => {
      if (!files.has(rel)) return null;
      if (!cache.has(rel)) cache.set(rel, git(["cat-file", "blob", `${rev}:${rel}`]));
      return cache.get(rel);
    },
  };
}

/**
 * `parseRefArg(argv)` — the gate's ONE way to choose the tree under test.
 *
 * `--ref <rev>` names a COMMIT; its absence means the working tree. An empty or
 * missing value is an ERROR, never "fall back to the working tree": that fallback
 * is indistinguishable from a green run (review P2, 2026-10-25 — `--ref ""` passed
 * while reading the very merged tree this change exists to stop reading), and a
 * check that cannot read its reference must never report a PASS about another
 * tree. There is deliberately no environment-variable spelling: an ambient
 * variable would let the tree under test be redirected without appearing in the
 * command the workflow runs.
 */
export function parseRefArg(argv) {
  const cut = argv.includes("--cut");
  const at = argv.indexOf("--ref");
  if (at < 0) return { cut, ref: null };
  const value = argv[at + 1];
  if (typeof value !== "string" || value === "" || value.startsWith("--")) {
    throw new Error("--ref requires a non-empty <rev> (omit --ref entirely to judge the working tree)");
  }
  return { cut, ref: value };
}

/** The sanctioned LEAF relpaths, read from `index.ts` in `tree`. */
export function sanctionedPaths(tree) {
  const src = tree.read(INDEX_REL);
  if (src === null) {
    throw new Error(`${INDEX_REL} is not present in ${tree.label} — cannot read the sanctioned list`);
  }
  return [...src.toString("utf8").matchAll(SANCTIONED_LIST_RE)].map((m) => m[1]);
}

/**
 * The delegation closure of `sanctioned`, resolved inside `tree`: every file a
 * listed script (or a file already in the closure) executes by its own location,
 * mapped to the sha256 of its bytes in that tree.
 */
export function closureOf(tree, sanctioned) {
  const seen = new Set(sanctioned);
  const frontier = [...sanctioned];
  while (frontier.length) {
    const rel = frontier.pop();
    const bytes = tree.read(rel);
    if (bytes === null) continue;
    for (const m of bytes.toString("utf8").matchAll(SELF_DIR_REF)) {
      const name = m[1].replace(/^\/+/, "");
      // Both spellings a `$SELF_DIR/x` reference can resolve to: relative to the
      // repo's `scripts/` (the `SELF_DIR` convention) and relative to the
      // referring file's own directory (the `$(dirname "$0")` convention).
      // Both are NORMALISED before the lookup: a reference may climb
      // (`$SELF_DIR/../verify-admin-merge-evidence.sh` in the gh shim), and a key
      // carrying `..` is not the repo-relative path the pin records — the pin
      // names `scripts/verify-admin-merge-evidence.sh`, so the closure must too.
      for (const raw of [`scripts/${name}`, `${dirname(rel)}/${name}`]) {
        const cand = posix.normalize(raw);
        if (cand.startsWith("../") || cand === ".." || cand.startsWith("/")) continue;
        if (!tree.has(cand)) continue;
        if (seen.has(cand)) continue;
        seen.add(cand);
        frontier.push(cand);
      }
    }
  }
  const out = {};
  // Sanctioned relpaths are NOT excluded: one sanctioned script sources/execs
  // another (`check-pipeline-compliance.sh` sources `record-review.sh`), and the
  // exemption is granted for the whole invocation — so the executed sibling has to
  // be verified too, not skipped because it also appears in the leaf list.
  for (const r of [...seen].sort()) {
    const bytes = tree.read(r);
    if (bytes !== null) out[r] = sha256(bytes);
  }
  return out;
}

/**
 * The pin document `--cut` writes for `tree`. Throws if a sanctioned leaf is
 * absent from the tree: a pin for a file that is not there describes nothing.
 */
export function computePin(tree, why) {
  const sanctioned = sanctionedPaths(tree);
  const digests = {};
  for (const rel of sanctioned) {
    const bytes = tree.read(rel);
    if (bytes === null) throw new Error(`missing sanctioned script ${rel} in ${tree.label} — cannot pin a file that is not there`);
    digests[rel] = sha256(bytes);
  }
  return { _why: why, version: 2, sha256: digests, delegates: closureOf(tree, sanctioned) };
}

/**
 * The freshness report for ONE tree: is the pin in this tree a faithful record of
 * the sanctioned surface in this tree?
 *
 * `stale` is empty iff (1) every sanctioned leaf is pinned, (2) every pinned leaf
 * digest equals the bytes in this tree (a REMOVAL is stale too — the pin would
 * otherwise exempt a relpath the framework no longer ships), and (3) every
 * delegate the listed scripts actually execute by their own location is present
 * and pinned to the bytes in this tree.
 */
export function pinReport(tree) {
  const report = {
    tree: tree.label,
    ref: tree.ref,
    sanctioned: [],
    present: false,
    doc: null,
    parseError: null,
    pin: {},
    delegates: {},
    closure: {},
    stale: [],
  };
  report.sanctioned = sanctionedPaths(tree);
  const raw = tree.read(PIN_REL);
  if (raw === null) {
    report.parseError = `${PIN_REL} is not present in ${tree.label}`;
    return report;
  }
  report.present = true;
  try {
    report.doc = JSON.parse(raw.toString("utf8"));
  } catch (e) {
    report.parseError = String((e && e.message) || e);
    return report;
  }
  report.pin = report.doc.sha256 ?? {};
  report.delegates = report.doc.delegates ?? {};
  report.closure = closureOf(tree, report.sanctioned);
  report.stale = [
    ...report.sanctioned.filter((r) => !tree.has(r)).map((r) => `${r} (missing)`),
    ...report.sanctioned.filter((r) => tree.has(r) && report.pin[r] !== sha256(tree.read(r))),
    ...Object.keys(report.delegates)
      .filter((r) => !tree.has(r) || report.delegates[r] !== sha256(tree.read(r)))
      .map((r) => `${r} (delegate)`),
    // BOTH directions of the closure. The loop above asks "is every delegate the
    // PIN names still the bytes beside it?"; this asks "is every helper the scripts
    // actually EXECUTE still pinned?" — the direction that catches a pin edited to
    // drop a delegate (the `ci_exemption.py` class). Without it `stale` reports
    // fresh for a pin whose closure shrank, and any caller that trusts `stale`
    // alone turns that into a false PASS (review P2, 2026-10-25).
    ...Object.keys(report.closure)
      .filter((r) => typeof report.delegates[r] !== "string")
      .map((r) => `${r} (unpinned delegate)`),
  ];
  return report;
}
