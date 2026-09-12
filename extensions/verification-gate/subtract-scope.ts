// #755 — Merge-scope subtraction: drop base-identical paths from a merge's
// verification scope. See docs/plans/2026-09-11-755-vgate-merge-scope.md §2/§3
// (the single normative statement of the rule).
//
// ⛔ This module is the ONLY statement of the rule. If you change a guard here,
// search the plan doc for other statements of the same mechanism — restatement
// drift is this change's documented failure mode.
//
// Loader note: a nested .ts sibling of index.ts is NOT auto-loaded by pi's
// extension loader (only index.ts/index.js or package.json#pi.extensions at a
// directory root). No registration is needed for this file.
//
// Import discipline: `import type` ONLY from ./index.js. index.ts:2 value-imports
// the pi SDK, so a value import would break the zero-dep `verify` CI job.

import type { DiffScope } from "./index.js";
import { execFileSync } from "node:child_process";

// ── Vocabulary ───────────────────────────────────────
// Declared ONCE; shared by SubCtx.arm() and SubAudit.arm.
// No "ghRecord" member: ghCommitRecordScope is a router, so a gh-chain ctx is
// built by the DELEGATE producer and carries the delegate's label.
export type ArmLabel = "staged" | "worktree" | "wtPath" | "branch" | "push";
export type RecordedSide = "index" | "worktree" | "wtPath" | "ref";

/** gate_skip reasons contributed by this module. `index.ts` spreads this into
 *  GATE_SKIP_REASONS, so this ARRAY is the single definition of the vocabulary —
 *  but note the emit sites still spell the string, because `GateSkipReason` is a
 *  string-literal union and a literal always typechecks against it. The tripwire
 *  guards "no literal is listed twice in the arrays", NOT "the literal appears
 *  only here"; renaming a member below would silently leave an emit site
 *  emitting the old string. Kept as literals (not `SUBTRACT_SKIP_REASONS[1]`)
 *  so the audit JSON stays greppable. */
export const SUBTRACT_SKIP_REASONS = [
  "base_identical_satisfied",
  "subtract_disabled_by_env",
] as const;

export interface SubAudit {
  arm: ArmLabel;
  recordedSide: RecordedSide;
  t: { ref: string; oid: string };
  b: { ref: string; oid: string };
  /** The RECORDED side the comparison actually ran against. Without it, a
   *  subtraction made with the wrong recorded side logs a plausible line.
   *  oid is null for index/worktree/wtPath — no read-only OID exists there. */
  r: { ref: string; oid: string | null } | null;
  mergeBaseOid: string | null;
  trackingRefOid: string | null;
  /** THIS arm's removals (per-arm provenance). Scope-wide union and the
   *  filtered `subtractedPaths` are derived at the emit site. */
  perArmSubtracted: string[];
  guards: {
    mergeBaseCount: number | null;
    bIsAncestorOfT: boolean | null;
    tIsAncestorOfSecondParent: boolean | null;
    trackingRefIsAncestorOfB: boolean | null;
  };
}

export interface SubResult {
  scope: DiffScope;
  removed: string[];
  audit: SubAudit | null;
}

// ── The injected context ─────────────────────────────
// Raw primitives, NOT pre-computed booleans. Every one has a declared
// fail-closed sentinel (see the plan's sentinel table): a failure must produce
// "do not subtract".
export interface SubCtx {
  arm(): ArmLabel;
  recordedSide(): RecordedSide;
  recordedSideRef(): string | null;
  recordedSideOid(): string | null;
  t(): { ref: string; oid: string };
  b(): { ref: string; oid: string };
  mergeBaseOid(): string | null;
  trackingRefOid(): string | null;
  /** `true` means "P differs from T's recorded entry" ⇒ condition (1) FAILS.
   *  Sentinel on failure: `true` (never subtract). */
  differsFromBase(p: string): boolean;
  /** Same polarity for condition (2). Sentinel on failure: `true`. */
  differsFromBranchSide(p: string): boolean;
  /** T's tree entry. Sentinel on failure: `null` ⇒ ineligible. */
  baseEntry(p: string): { mode: string; blob: string } | null;
  /** Exactly 1 permits subtraction; 0/>=2/null all block. */
  mergeBaseCount(): number | null;
  /** TRI-STATE. `0`⇒true, `1`⇒false (a valid negative, NOT a failure),
   *  `128`/other/throw⇒null. Guard (3) passes only on explicit `false`;
   *  guards (4)/(5) only on explicit `true`. */
  isAncestorOrEqual(a: string, b: string): boolean | null;
  /** Parent list, resolved from the OID pinned at ctx build — NEVER from a bare
   *  ref name, which a concurrent `update-ref`/`reset` could retarget between
   *  ctx build and this probe (that would let guard (4) pass against a different
   *  commit than guards (1)-(3) were evaluated against ⇒ under-gate). Token 0
   *  (the commit itself) is dropped. */
  parentRefs(): string[];
  /** Sentinel on failure: `true` (never subtract). */
  isShallowRepository(): boolean;
  srcRef(): string | null;
  trackingRef(): string | null;
}

// ── The rule (conditions 0-3,E,F and push-only 4,5) ──
const REGULAR_MODES = new Set(["100644", "100755"]);

/** The pure predicate. Any unprovable input returns false ⇒ no subtraction. */
export function passesGuards(
  ctx: SubCtx,
  statuses: Map<string, string>,
  p: string,
  pushArm: boolean
): boolean {
  // (E) eligibility: A/M only. D/T/R/C/U/X/B are never subtracted.
  const st = statuses.get(p);
  if (st !== "A" && st !== "M") return false;
  // (F) regular file on T (excludes gitlinks 160000 and symlinks 120000).
  const entry = ctx.baseEntry(p);
  if (entry === null || !REGULAR_MODES.has(entry.mode)) return false;
  // (0) exactly one merge base
  if (ctx.mergeBaseCount() !== 1) return false;
  // (1) P's entry on the RECORDED SIDE equals its entry on T.
  //     This is the side-sensitive condition: the recorded side is the index,
  //     the worktree, the named WT path, or the ref, depending on the arm.
  if (ctx.differsFromBase(p)) return false;
  // (2) P's entry on B equals its entry on merge-base(T,B).
  //     NOT "the recorded side": `diff <T>...<B>` is by definition
  //     `diff merge-base(T,B) <B>`, so this tests B. It coincides with the
  //     recorded side only for the `branch` arm (recorded side = HEAD = B).
  //     Swapping (1) and (2) here would be an under-gate; as written, an
  //     unprovable (2) can only over-gate.
  if (ctx.differsFromBranchSide(p)) return false;
  // (3) B is NOT ancestor-or-equal of T — passes only on an explicit `false`.
  // ⛔ Every ancestry query runs off the immutable OIDs resolved once at ctx
  // build, so a concurrent `update-ref` cannot tear the read.
  if (ctx.isAncestorOrEqual(ctx.b().oid, ctx.t().oid) !== false) return false;
  if (pushArm) {
    // (4) T is ancestor-or-equal of some NON-FIRST parent of srcRef.
    //     The parent list comes off the OID pinned at ctx build, so a
    //     concurrent update-ref cannot retarget it (see SubCtx.parentRefs).
    //     `parentRefs()` returns the parents with token 0 already dropped, so
    //     `.slice(1)` drops the FIRST parent — guard (4) is about a merge's
    //     non-first parent, because the first parent is the branch's own side.
    const tOid = ctx.t().oid;
    if (!ctx.parentRefs().slice(1).some((r) => ctx.isAncestorOrEqual(tOid, r) === true)) return false;
    // (5) trackingRef is ancestor-or-equal of B — only an explicit `true`
    // passes. A missing tracking OID is unprovable ⇒ no subtraction.
    const trOid = ctx.trackingRefOid();
    if (trOid === null) return false;
    if (ctx.isAncestorOrEqual(trOid, ctx.b().oid) !== true) return false;
  }
  return true;
}

function run(scope: DiffScope, statuses: Map<string, string>, ctx: SubCtx | null, pushArm: boolean): SubResult {
  // No ctx ⇒ no subtraction (the kill switch, and the six `null` wiring
  // positions). `clean` and `renameOldPaths` pass through untouched.
  if (ctx === null) return { scope, removed: [], audit: null };
  // A parse anomaly sets clean=false and routes an unconditional parse-block
  // downstream. The status map is then PARTIAL, so subtraction must not run —
  // guarded HERE as well as at the producer, so the rule cannot be bypassed by
  // calling the arm entry point directly.
  if (!scope.clean) return { scope, removed: [], audit: null };
  if (ctx.isShallowRepository()) return { scope, removed: [], audit: null };
  if (ctx.mergeBaseCount() !== 1) return { scope, removed: [], audit: null };

  const removed: string[] = [];
  const kept = scope.files.filter((p) => {
    if (!passesGuards(ctx, statuses, p, pushArm)) return true;
    removed.push(p);
    return false;
  });
  // Invariant, failing CLOSED: absent (never []) when nothing was subtracted.
  if (removed.length === 0) return { scope, removed, audit: null };

  // Rename targets carry status R ⇒ ineligible, so `renameOldPaths` can never
  // be orphaned by a subtraction. Assert it rather than assume it.
  const removedSet = new Set(removed);
  if (scope.renameOldPaths.some((o) => removedSet.has(o))) {
    return { scope, removed: [], audit: null };
  }

  return {
    scope: { ...scope, files: kept },
    removed,
    audit: {
      arm: ctx.arm(),
      recordedSide: ctx.recordedSide(),
      t: ctx.t(),
      b: ctx.b(),
      r: ctx.recordedSideRef() === null ? null : { ref: ctx.recordedSideRef()!, oid: ctx.recordedSideOid() },
      mergeBaseOid: ctx.mergeBaseOid(),
      trackingRefOid: ctx.trackingRefOid(),
      perArmSubtracted: removed,
      guards: {
        mergeBaseCount: ctx.mergeBaseCount(),
        bIsAncestorOfT: ctx.isAncestorOrEqual(ctx.b().oid, ctx.t().oid),
        tIsAncestorOfSecondParent: pushArm ? secondParentCheck(ctx) : null,
        trackingRefIsAncestorOfB: pushArm && ctx.trackingRefOid() !== null
          ? ctx.isAncestorOrEqual(ctx.trackingRefOid()!, ctx.b().oid)
          : null,
      },
    },
  };
}

function secondParentCheck(ctx: SubCtx): boolean | null {
  const tOid = ctx.t().oid;
  const parents = ctx.parentRefs().slice(1);
  if (parents.length === 0) return null;
  const verdicts = parents.map((r) => ctx.isAncestorOrEqual(tOid, r));
  if (verdicts.some((v) => v === true)) return true;
  if (verdicts.some((v) => v === null)) return null;
  return false;
}

export function subtractCommitArm(
  scope: DiffScope,
  statuses: Map<string, string>,
  ctx: SubCtx | null
): SubResult {
  return run(scope, statuses, ctx, false);
}

export function subtractPushArm(
  scope: DiffScope,
  statuses: Map<string, string>,
  ctx: SubCtx | null
): SubResult {
  return run(scope, statuses, ctx, true);
}

// ── Git adapter ──────────────────────────────────────
// argv-only (execFileSync), NUL-preserving (never .trim()), tri-state.
// NOT gitProbe: that helper is shell-string interpolated, trims, and collapses
// every exit code into null — a binary contract that cannot express "no".

function gitOut(cwd: string, args: string[]): string | null {
  try {
    return execFileSync("git", args, {
      cwd,
      encoding: "utf-8",
      timeout: 5000,
      maxBuffer: 64 * 1024 * 1024,
      stdio: ["ignore", "pipe", "ignore"],
    });
  } catch {
    return null;
  }
}

/** Tri-state exit-code probe (the localBranchExists precedent). */
function gitTri(cwd: string, args: string[]): boolean | null {
  try {
    execFileSync("git", args, { cwd, timeout: 5000, stdio: "ignore" });
    return true;
  } catch (e) {
    const rc = (e as { status?: unknown } | null)?.status;
    if (rc === 1) return false; // an explicit NEGATIVE, not a failure
    return null; // 128 / signal / spawn failure
  }
}

function refExists(cwd: string, ref: string): boolean {
  return gitTri(cwd, ["rev-parse", "--verify", "--quiet", ref]) === true;
}

function configGet(cwd: string, key: string): string | null {
  const out = gitOut(cwd, ["config", "--get", key]);
  if (out === null) return null;
  const v = out.replace(/\n$/, "");
  return v === "" ? null : v;
}

function symbolicRefShort(cwd: string): string | null {
  const out = gitOut(cwd, ["symbolic-ref", "--quiet", "--short", "HEAD"]);
  if (out === null) return null;
  const v = out.replace(/\n$/, "");
  return v === "" ? null : v;
}

/** `--no-renames --raw -z` record grammar:
 *  `:<old_mode> SP <new_mode> SP <old_sha> SP <new_sha> SP <status> NUL <path> NUL`.
 *  A parse that MISSES a path makes it look unlisted ⇒ conditions (1) AND (2)
 *  hold ⇒ it IS subtracted ⇒ UNDER-GATE. Hence: unknown ⇒ null, never empty. */
function parseRawZ(out: string): Set<string> | null {
  // An EMPTY stream is a PROVABLY empty diff, not a parse failure: git emitted
  // zero bytes, so zero paths changed. Treating it as a failure would make
  // conditions (1) and (2) return the fail-closed `true` for EVERY path
  // whenever the recorded side is wholly identical to T — exactly the strongest
  // form of the property this rule exists to detect (e.g. `git checkout <T> -- .`
  // with HEAD still diverged) — silently defeating the whole subtraction.
  if (out === "") return new Set();
  if (!out.endsWith("\0")) return null; // truncated
  const toks = out.split("\0");
  if (toks.length > 0 && toks[toks.length - 1] === "") toks.pop();
  const paths = new Set<string>();
  let i = 0;
  while (i < toks.length) {
    if (!toks[i].startsWith(":")) return null; // format drift
    i++;
    if (i >= toks.length || toks[i] === "") return null;
    paths.add(toks[i]);
    i++;
  }
  return paths;
}

/** `ls-tree -r -z`: `<mode> SP <type> SP <sha> TAB <path> NUL`. Split on NUL,
 *  then split each record at the FIRST TAB (a path may contain a TAB). */
function parseLsTreeZ(out: string): Map<string, { mode: string; blob: string }> | null {
  // An empty base tree is a valid tree with zero entries, not a parse failure.
  if (out === "") return new Map();
  if (!out.endsWith("\0")) return null;
  const toks = out.split("\0");
  if (toks.length > 0 && toks[toks.length - 1] === "") toks.pop();
  const map = new Map<string, { mode: string; blob: string }>();
  for (const rec of toks) {
    const tab = rec.indexOf("\t");
    if (tab < 0) return null;
    const meta = rec.slice(0, tab);
    const path = rec.slice(tab + 1);
    const sp1 = meta.indexOf(" ");
    const sp2 = meta.indexOf(" ", sp1 + 1);
    if (sp1 < 0 || sp2 < 0) return null;
    const mode = meta.slice(0, sp1);
    const type = meta.slice(sp1 + 1, sp2);
    const blob = meta.slice(sp2 + 1);
    // Non-blob entries (commit/tree) are SKIPPED, not fatal. A gitlink is a
    // normal thing for a trusted base to contain, and guard (F) already
    // excludes such a path per-path. Returning null here would make
    // makeSubBundle return null and silently disable subtraction for the WHOLE
    // op in any repo whose base tree contains a submodule — a silent no-op for
    // that repo, with no audit line.
    if (type !== "blob") continue;
    map.set(path, { mode, blob });
  }
  return map;
}

export function isShallowRepository(cwd: string): boolean {
  const out = gitOut(cwd, ["rev-parse", "--is-shallow-repository"]);
  if (out === null) return true; // sentinel: never subtract
  return out.trim() === "true";
}

/** The trusted base, used by BOTH legs so they cannot disagree.
 *  `refs/remotes/<remote>/<branch.<cur>.merge short name, else main>`, remote
 *  from branch.<current>.remote else origin; fallback refs/remotes/origin/main.
 *  null when nothing resolves ⇒ no subtraction. */
export function resolveTrustedBase(cwd: string): { ref: string; oid: string } | null {
  const current = symbolicRefShort(cwd);
  let remote = current === null ? null : configGet(cwd, `branch.${current}.remote`);
  if (remote === null || remote === ".") remote = "origin";
  let branch = "main";
  if (current !== null) {
    const merge = configGet(cwd, `branch.${current}.merge`);
    if (merge !== null) {
      const m = /^refs\/heads\/(.+)$/.exec(merge);
      if (m !== null) branch = m[1];
    }
  }
  for (const ref of [`refs/remotes/${remote}/${branch}`, `refs/remotes/origin/main`]) {
    const oid = gitOut(cwd, ["rev-parse", "--verify", "--quiet", ref]);
    if (oid !== null) {
      const v = oid.replace(/\n$/, "");
      if (v !== "") return { ref, oid: v };
    }
  }
  return null;
}

/** Resolve the op-level bundle ONCE per gated git op. Returns null (⇒ no
 *  subtraction anywhere) when the trusted base is unresolvable. */
export function makeSubBundle(cwd: string): SubBundle | null {
  const base = resolveTrustedBase(cwd);
  if (base === null) return null;
  if (isShallowRepository(cwd)) return null;
  const tree = gitOut(cwd, ["ls-tree", "-r", "-z", base.oid]);
  if (tree === null) return null;
  const baseEntries = parseLsTreeZ(tree);
  if (baseEntries === null) return null;
  return { tOid: base.oid, tRef: base.ref, baseEntries, pairMemo: new Map() };
}

export interface SubBundle {
  tOid: string;
  tRef: string;
  baseEntries: Map<string, { mode: string; blob: string }>;
  /** Memoised per-(T,B) pair queries, so two arms sharing a pair issue ONE
   *  `merge-base --all` and ONE `diff T...B`, not two. Failure facets are
   *  `null`, never an empty Set — an empty Set would make condition (2) hold
   *  for every path ⇒ subtract everything ⇒ UNDER-GATE. */
  pairMemo: Map<string, {
    mergeBaseCount: number | null;
    mergeBaseOid: string | null;
    branchSideChanged: Set<string> | null;
  }>;
}

export interface MakeCtxArgs {
  bundle: SubBundle;
  arm: ArmLabel;
  recordedSide: RecordedSide;
  pathspecs?: string[];
  srcRef?: string;
  trackingRef?: string;
}

/** Built INSIDE each producer. `SubCtx` values never cross a function
 *  boundary, so a caller cannot supply a valid-but-wrong recorded side.
 *  Returns null on any unresolved handle ⇒ the producer keeps its own scope. */
export function makeGitSubCtx(cwd: string, args: MakeCtxArgs): SubCtx | null {
  const { bundle, arm, recordedSide } = args;

  // B: the branch side. Commit-shaped arms diff against HEAD; the push arm
  // diffs against the merge commit's first parent.
  let bRef: string;
  if (arm === "push") {
    if (args.srcRef === undefined) return null;
    bRef = `${args.srcRef}^1`;
  } else {
    bRef = "HEAD";
  }
  const bOid = gitOut(cwd, ["rev-parse", "--verify", "--quiet", bRef]);
  if (bOid === null) return null;
  const bOidV = bOid.replace(/\n$/, "");
  if (bOidV === "") return null;

  // R: the recorded side's diff argument (resolved to an OID where one exists).
  // ⛔ When the recorded side IS the branch side it must REUSE bOidV rather than
  // re-probing. For the `branch` arm both are literally "HEAD", and two separate
  // `rev-parse` calls could straddle a concurrent `checkout`/`update-ref`, letting
  // condition (1) evaluate against one commit while conditions (2)/(3) evaluate
  // against another — the same torn-read class the guard-(4) fix closed. Resolving
  // once is also what the module's header promises: "every ancestry query runs off
  // the immutable OIDs resolved once at ctx build".
  const rOid = recordedSide === "ref" && args.srcRef !== undefined
    ? (args.srcRef === bRef
        ? bOidV
        : (gitOut(cwd, ["rev-parse", "--verify", "--quiet", args.srcRef]) ?? "").replace(/\n$/, "") || null)
    : null;
  if (recordedSide === "ref" && rOid === null) return null;

  const rArgs = (extra: string[]): string[] => {
    if (recordedSide === "index") return ["diff", "--no-renames", "--raw", "-z", bundle.tOid, "--cached"];
    if (recordedSide === "worktree") return ["diff", "--no-renames", "--raw", "-z", bundle.tOid];
    if (recordedSide === "wtPath") {
      return ["diff", "--no-renames", "--raw", "-z", bundle.tOid, "--", ...extra];
    }
    return ["diff", "--no-renames", "--raw", "-z", bundle.tOid, rOid!];
  };

  const baseRaw = gitOut(cwd, rArgs(args.pathspecs ?? []));
  const baseChanged = baseRaw === null ? null : parseRawZ(baseRaw);

  // Pair-keyed memo for the two per-(T,B) queries.
  const key = `${bundle.tOid}..${bOidV}`;
  let pair = bundle.pairMemo.get(key);
  if (pair === undefined) {
    const mb = gitOut(cwd, ["merge-base", "--all", bundle.tOid, bOidV]);
    let count: number | null = null;
    let mbOid: string | null = null;
    if (mb !== null) {
      const ids = mb.split("\n").map((s) => s.trim()).filter((s) => s !== "");
      count = ids.length;
      mbOid = count === 1 ? ids[0] : null;
    }
    const dotRaw = gitOut(cwd, ["diff", "--no-renames", "--raw", "-z", `${bundle.tOid}...${bOidV}`]);
    pair = {
      mergeBaseCount: count,
      mergeBaseOid: mbOid,
      branchSideChanged: dotRaw === null ? null : parseRawZ(dotRaw),
    };
    bundle.pairMemo.set(key, pair);
  }
  const thisPair = pair;

  const tOid = bundle.tOid;
  const trackingRefName = args.trackingRef ?? null;
  const trackingOid = trackingRefName === null
    ? null
    : (gitOut(cwd, ["rev-parse", "--verify", "--quiet", trackingRefName]) ?? "").replace(/\n$/, "") || null;

  const ancestor = (a: string, b: string): boolean | null => gitTri(cwd, ["merge-base", "--is-ancestor", a, b]);

  return {
    arm: () => arm,
    recordedSide: () => recordedSide,
    recordedSideRef: () => (recordedSide === "ref" ? (args.srcRef ?? null) : null),
    // index/worktree/wtPath have NO read-only OID (a worktree-only change
    // reports dst SHA 0000000; GIT_READ_ONLY_VERBS has no write-tree).
    recordedSideOid: () => rOid,
    t: () => ({ ref: bundle.tRef, oid: tOid }),
    b: () => ({ ref: bRef, oid: bOidV }),
    mergeBaseOid: () => thisPair.mergeBaseOid,
    trackingRefOid: () => trackingOid,
    differsFromBase: (p) => (baseChanged === null ? true : baseChanged.has(p)),
    differsFromBranchSide: (p) =>
      thisPair.branchSideChanged === null ? true : thisPair.branchSideChanged.has(p),
    baseEntry: (p) => bundle.baseEntries.get(p) ?? null,
    mergeBaseCount: () => thisPair.mergeBaseCount,
    isAncestorOrEqual: (a, b) => ancestor(a, b),
    parentRefs: () => {
      // rOid is the recorded side's OID, pinned at ctx build. Both arms that
      // reach guard (4) use recordedSide "ref", so this is the src OID.
      if (rOid === null) return [];
      const out = gitOut(cwd, ["rev-list", "--parents", "-n", "1", rOid]);
      if (out === null) return [];
      const toks = out.trim().split(/\s+/).filter((s) => s !== "");
      return toks.slice(1); // token 0 is the commit itself
    },
    isShallowRepository: () => isShallowRepository(cwd),
    srcRef: () => args.srcRef ?? null,
    trackingRef: () => trackingRefName,
  };
}
