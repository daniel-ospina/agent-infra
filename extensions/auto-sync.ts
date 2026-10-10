// auto-sync.ts — Level-1 machine sync for agent-infra (session_start)
//
// On session start, if AGENT_INFRA_PATH is set:
//   - ANY unmerged index entry → LOUD banner with the offending paths + a
//     code-aware remedy, in every mode, and no pull attempt (#1661). The banner
//     distinguishes a live merge/rebase/cherry-pick/revert (finish or abort it)
//     from the abandoned index-only state the issue measured — a rebase INVERTS
//     --ours/--theirs, so a blanket --theirs is unsafe there.
//   - fetch origin and compare HEAD vs origin/main
//   - behind → AGENT_SYNC_MODE=auto  : run sync.sh (pull --ff-only + refresh config)
//   - behind → AGENT_SYNC_MODE=warn  : print a hint to run `cd "$AGENT_INFRA_PATH" && ./sync.sh`
//   - behind ≥ AGENT_SYNC_STALE_COMMITS (default 25) → staleness banner (#1661)
//   - print mode → never pulls, but traces staleness instead of returning
//     silently, so a sub-agent's environment is not invisibly stale (#1661)
//   - ahead  → report unpushed commits + push hint (informational; never pushes)
//   - diverged → surface git status/log guidance + next step (ff blocked)
//   - current → silent
//
// Safety: only ever pulls (never pushes). sync.sh fails loudly on divergence.
// Secrets never sync: auth.json and env vars stay machine-local by design.

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { existsSync, lstatSync, readFileSync, readlinkSync, realpathSync, rmSync } from "node:fs";
import { join } from "node:path";
import { execSync, execFileSync } from "node:child_process";
import { isPrintMode } from "./shared/print-mode.js";
import { repoKey, acquireRepoLock, releaseRepoLock } from "./shared/branch-ownership.mjs";

export function shortHead(repo: string, ref = "HEAD"): string {
  try {
    return execSync(`git -C "${repo}" rev-parse --short ${ref}`, { encoding: "utf-8" }).trim();
  } catch {
    return "?";
  }
}

/** Commits HEAD is ahead of origin/main (0 when undetermined). */
export function aheadCount(repo: string): number {
  try {
    const out = execSync(`git -C "${repo}" rev-list --count origin/main..HEAD`, { encoding: "utf-8" }).trim();
    const n = Number(out);
    return Number.isInteger(n) ? n : 0;
  } catch {
    return 0;
  }
}

/** Commits origin/<branch> has that HEAD lacks (0 when undetermined). */
export function behindCount(repo: string, branch = "main"): number {
  try {
    const out = execSync(`git -C "${repo}" rev-list --count HEAD..origin/${branch}`, { encoding: "utf-8", timeout: 10_000 }).trim();
    const n = Number(out);
    return Number.isInteger(n) && n >= 0 ? n : 0;
  } catch {
    return 0;
  }
}

/** #1661: at or above this many commits behind origin/main the pin is reported
 * as a banner, not a one-line hint. Override with AGENT_SYNC_STALE_COMMITS. */
export const DEFAULT_STALE_COMMITS = 25;

export function stalenessThreshold(env: Record<string, string | undefined> = process.env): number {
  const raw = Number(env.AGENT_SYNC_STALE_COMMITS);
  return Number.isInteger(raw) && raw > 0 ? raw : DEFAULT_STALE_COMMITS;
}

/**
 * #1661 (2): the "your tooling is old" banner. EMPTY below `threshold` — a
 * one-commit-behind checkout is normal and must stay quiet. Above it, the
 * magnitude of the pin (the thing that was invisible) is stated explicitly.
 * Pure (repo is only interpolated) so it is directly unit-testable.
 */
export function stalenessBanner(repo: string, behind: number, threshold: number): string[] {
  if (behind < threshold) return [];
  return [
    `[auto-sync] 🐌 your loaded extensions are ${behind} commits behind origin/main — this checkout is pinned at ${shortHead(repo)}.`,
    `[auto-sync]    extensions/ on disk is NOT what origin/main ships; a bug you are chasing may already be fixed there.`,
    `[auto-sync]    Sync: cd "${repo}" && ./sync.sh`,
  ];
}

/** Unmerged porcelain codes — the `U*`/`AA`/`DD` conflict shapes (#1661). */
const UNMERGED_CODES = new Set(["DD", "AU", "UD", "UA", "DU", "AA", "UU"]);

export interface UnmergedEntry { path: string; detail: string }

/**
 * #1661 (1): unmerged index entries — leftover stage-1/2/3 entries that make
 * every `git pull --ff-only` fail forever, whether they come from the abandoned
 * index-only state (no MERGE_HEAD) or a live merge/rebase/cherry-pick/revert
 * (caller distinguishes via `unmergedOp`). `git status --porcelain` supplies the
 * reader-friendly code (`UU`, `AA`, `DD`, …) and `git ls-files -u` the
 * authoritative stage list; they are UNIONED so a shape either source misses is
 * still caught. Never throws — this is a diagnostic, not a gate, so an
 * unreadable repo yields [] (no false alarm) rather than breaking session start.
 */
export function unmergedEntries(repo: string): UnmergedEntry[] {
  const found = new Map<string, string>();
  try {
    const recs = execFileSync("git", ["-C", repo, "status", "--porcelain", "-z"], { encoding: "utf-8", timeout: 15_000 }).split("\0");
    for (let i = 0; i < recs.length; i++) {
      const rec = recs[i];
      if (rec.length < 4) continue;
      const code = rec.slice(0, 2);
      // #1661 (review): porcelain-v1 -z emits an EXTRA NUL record after a
      // rename/copy — the ORIGINAL path (`R  <new>\0<old>\0`). Re-reading it as
      // `XY PATH` turns a benign `git mv` whose old name starts with an unmerged
      // code (e.g. "AUTHORS" → "AU") into a phantom entry with a truncated path
      // ("HORS"); session_start would then print the STUCK banner and return
      // while sync.sh's `git ls-files -u` is clean, freezing sync for the whole
      // session. Consume the original-path record.
      if (code[0] === "R" || code[0] === "C" || code[1] === "R" || code[1] === "C") {
        i++;
        continue;
      }
      if (UNMERGED_CODES.has(code)) found.set(rec.slice(3), code);
    }
  } catch { /* git unavailable / not a repo — no signal */ }
  try {
    for (const rec of execFileSync("git", ["-C", repo, "ls-files", "-u", "-z"], { encoding: "utf-8", timeout: 15_000 }).split("\0")) {
      const tab = rec.indexOf("\t");
      if (tab === -1) continue;
      const path = rec.slice(tab + 1);
      if (!path || found.has(path)) continue;
      found.set(path, `stage ${rec.slice(0, tab).trim().split(/\s+/).pop() ?? "?"}`);
    }
  } catch { /* ignore */ }
  return [...found.entries()]
    .sort((a, b) => a[0].localeCompare(b[0]))
    .map(([path, detail]) => ({ path, detail }));
}

/**
 * #1661 (review): what, if anything, is mid-flight in the checkout. The
 * abandoned conflict the issue is about has NO sequencer state ("index-only");
 * a live merge/rebase/cherry-pick/revert leaves MERGE_HEAD / CHERRY_PICK_HEAD /
 * REVERT_HEAD or a rebase-merge|rebase-apply directory. The distinction matters
 * because the banner must not assert "no MERGE_HEAD" for a live merge, and a
 * rebase INVERTS --ours/--theirs relative to a merge, so the old blanket
 * `checkout --theirs` remedy could silently discard the user's commit.
 */
export type UnmergedOp = "index-only" | "merge" | "rebase" | "cherry-pick" | "revert";

export function unmergedOp(repo: string): UnmergedOp {
  let gitDir: string;
  try {
    // `--git-path` is cwd-relative (and a linked worktree's .git is a FILE), so
    // resolve the absolute per-worktree git dir once and join names onto it.
    gitDir = execFileSync("git", ["-C", repo, "rev-parse", "--absolute-git-dir"], { encoding: "utf-8", timeout: 5_000 }).trim();
  } catch {
    return "index-only";
  }
  const has = (name: string): boolean => gitDir.length > 0 && existsSync(join(gitDir, name));
  if (has("rebase-merge") || has("rebase-apply")) return "rebase";
  if (has("CHERRY_PICK_HEAD")) return "cherry-pick";
  if (has("REVERT_HEAD")) return "revert";
  if (has("MERGE_HEAD")) return "merge";
  return "index-only";
}

/**
 * #1661 (review): a remedy valid for the entry's conflict shape. `--theirs`
 * needs index stage 3 and `--ours` needs stage 2; DD has neither and AU/UD lack
 * stage 3, DU/UA lack stage 2 — so the old hard-coded `--theirs` errored
 * ("path ... does not have their version") for those codes. Pure.
 */
function remedyCommands(repo: string, e: UnmergedEntry): string[] {
  const keepTheirs = `git -C "${repo}" checkout --theirs "${e.path}" && git -C "${repo}" add "${e.path}"`;
  const keepOurs = `git -C "${repo}" checkout --ours "${e.path}" && git -C "${repo}" add "${e.path}"`;
  const remove = `git -C "${repo}" rm "${e.path}"`;
  switch (e.detail) {
    case "DD": // deleted on both sides — no stage 2 or 3
      return [`both sides deleted this path: ${remove}`];
    case "UD": // deleted by them — stage 2 only
      return [`origin deleted this path — keep yours: ${keepOurs}`, `or match origin: ${remove}`];
    case "DU": // deleted by us — stage 3 only
      return [`origin has this path and you deleted it — take origin's: ${keepTheirs}`];
    case "AU": // added by us — stage 2 only
      return [`you added this path — keep yours: ${keepOurs}`, `or match origin: ${remove}`];
    case "UA": // added by them — stage 3 only
      return [`origin added this path — take it: ${keepTheirs}`];
    case "UU":
    case "AA":
      return [`keep origin's version: ${keepTheirs}`, `or keep yours: ${keepOurs}`];
    default: // ls-files fallback detail ("stage 1"/"stage 2"/"stage 3"/"stage ?")
      if (e.detail.includes("2")) return [`keep yours (stage 2): ${keepOurs}`];
      if (e.detail.includes("3")) return [`keep origin's version (stage 3): ${keepTheirs}`];
      if (e.detail.includes("1")) return [`base-only entry: ${remove}`];
      return [`inspect: git -C "${repo}" status`, `then keep origin's version: ${keepTheirs}`];
  }
}

/**
 * #1661 (1): the LOUD banner for unmerged index entries. `op` (from
 * `unmergedOp`) selects the wording: the abandoned index-only conflict the issue
 * is about, or a live merge/rebase/cherry-pick/revert that must be concluded
 * before syncing. The remedy is chosen per conflict code (see remedyCommands)
 * rather than a blanket `--theirs`. No shell is run here (repo/paths are only
 * interpolated), so this is pure and unit-testable. Empty for a clean index.
 */
export function unmergedBanner(repo: string, entries: UnmergedEntry[], op: UnmergedOp = "index-only"): string[] {
  if (entries.length === 0) return [];
  const list: string[] = [`[auto-sync]    ${entries.length} unmerged path(s):`];
  for (const e of entries.slice(0, 6)) list.push(`[auto-sync]      ${e.path}  [${e.detail}]`);
  if (entries.length > 6) list.push(`[auto-sync]      …and ${entries.length - 6} more (git -C "${repo}" ls-files -u)`);

  if (op !== "index-only") {
    return [
      `[auto-sync] ⛔ ${op.toUpperCase()} IN PROGRESS with unmerged paths — sync must wait until it is concluded.`,
      ...list,
      `[auto-sync]    Finish: resolve each path, \`git -C "${repo}" add <path>\`, then \`git -C "${repo}" ${op} --continue\`.`,
      `[auto-sync]    Or abort: git -C "${repo}" ${op} --abort`,
      `[auto-sync]    (${op} inverts --ours/--theirs relative to a merge — do not blind-apply a keep-theirs command.)`,
      `[auto-sync]    Then re-sync: cd "${repo}" && ./sync.sh`,
    ];
  }

  return [
    `[auto-sync] ⛔ STUCK MERGE CONFLICT in agent-infra's index — every sync fails and the extensions you loaded are FROZEN.`,
    `[auto-sync]    (index-only stuck state — no MERGE_HEAD, so a plain sync can never recover.)`,
    ...list,
    `[auto-sync]    Resolve one path at a time, then stage it:`,
    ...remedyCommands(repo, entries[0]).map((c) => `[auto-sync]      ${c}`),
    `[auto-sync]      (a [DD] path must be \`git rm\`d; --theirs needs stage 3, --ours needs stage 2)`,
    `[auto-sync]    Then re-sync: cd "${repo}" && ./sync.sh`,
  ];
}

/**
 * Sync state of the repo vs origin/<branch> (call after `git fetch`):
 *   "current"   HEAD === origin/<branch>
 *   "behind"    origin/<branch> has commits HEAD lacks (ff pull possible)
 *   "ahead"     HEAD has unpushed commits origin/<branch> lacks (ff pull is a no-op)
 *   "diverged"  neither side is an ancestor of the other (ff pull blocked)
 *
 * `branch` defaults to "main" — pass the repo's real default branch (#1245,
 * for repos that are not agent-infra).
 */
export function syncState(repo: string, branch = "main"): "current" | "behind" | "ahead" | "diverged" {
  const remoteRef = `origin/${branch}`;
  let head: string, remote: string;
  try {
    head = execSync(`git -C "${repo}" rev-parse HEAD`, { encoding: "utf-8", timeout: 10_000 }).trim();
    remote = execSync(`git -C "${repo}" rev-parse ${remoteRef}`, { encoding: "utf-8", timeout: 10_000 }).trim();
  } catch {
    return "current"; // can't determine — don't act
  }
  if (head === remote) return "current";
  // HEAD is an ancestor of origin/<branch> → local is behind (equality excluded above).
  try {
    execSync(`git -C "${repo}" merge-base --is-ancestor HEAD ${remoteRef}`, { stdio: "ignore", timeout: 10_000 });
    return "behind";
  } catch {
    /* not behind */
  }
  // origin/<branch> is an ancestor of HEAD → local has unpushed commits.
  try {
    execSync(`git -C "${repo}" merge-base --is-ancestor ${remoteRef} HEAD`, { stdio: "ignore", timeout: 10_000 });
    return "ahead";
  } catch {
    /* neither is an ancestor → true divergence */
  }
  return "diverged";
}

/**
 * Conservative branch-name guard for #1245: recovery interpolates the branch
 * into shell commands, so it refuses anything outside a safe charset rather
 * than shell-quoting a name Git would accept. An exotic (but legal) default
 * branch simply keeps the old report-only behaviour — fail-closed.
 */
export function isSafeBranchName(branch: string): boolean {
  return /^[A-Za-z0-9._/-]+$/.test(branch) && !branch.startsWith("-") && !branch.includes("..");
}

/**
 * #203: lossless recovery for a checkout stranded on a non-default branch.
 * Squash-merged PR work leaves a feature branch with commits that never land
 * on main (its tree is often byte-identical to origin/main) — the checkout
 * then reports "diverged" forever: ff-pull can't help, the main-worktree-guard
 * blocks agent-side resets, and auto-sync warns every session while main
 * drifts further ahead. Recovery is ONLY attempted when provably lossless:
 *   - the tracked working tree is byte-identical to origin/<branch>
 *     (`git diff origin/<branch> --quiet` exits 0), AND
 *   - every untracked file is absent from origin/<branch> (→ abort: new work) or
 *     byte-identical to it (same mode and same blob) — otherwise abort (→ safe to
 *     remove; the branch switch restores it), AND
 *   - the INDEX holds nothing origin/<branch> lacks (a `MM` staged-only edit is
 *     invisible to a worktree diff, yet the switch resets the index), AND
 *   - every index-flagged path (`git ls-files -v`, any tag other than `H`) holds
 *     the same (mode, blob) as origin/<branch> — `assume-unchanged` /
 *     `skip-worktree` are invisible to `git diff`, so the checks above read clean
 *     for pinned local content.
 * On success the checkout ends on `<branch>` at `origin/<branch>` (0 divergence)
 * — the stranded branch itself is left untouched (refs preserved). Never runs
 * in "ahead" state (unpushed commits are real work) and never when the tree
 * holds genuine uncommitted changes.
 *
 * #265: the repo lock serializes recovery-vs-recovery across concurrent pi
 * processes. When called from session_start the lock is ALREADY held (passed
 * via opts.lockHeld) — same-pid re-acquire is re-entrant so recovery never
 * self-skips; direct calls (tests) acquire internally. All lossless checks are
 * RE-VERIFIED under the lock immediately before any mutation (rmSync/checkout)
 * — no rmSync is ever based on pre-lock state.
 *
 * #1245: `opts.branch` generalizes it beyond agent-infra (default "main" keeps
 * every existing call site byte-for-byte identical). repo-freshness.ts calls it
 * for ANY repo — under the same lossless gate, never a weaker one, and never on
 * a busy or foreign-worktree checkout.
 */
export function tryLosslessRecover(
  repo: string,
  opts: { lockHeld?: boolean; branch?: string } = {},
): { recovered: boolean; reason?: string } {
  // #1245 (review): canonicalise to the WORK TREE ROOT before anything else.
  // The checks below run with `-C <root>` and every join() is relative to it,
  // while the mutation (`checkout -f` + `merge --ff-only`) is WORKTREE-WIDE. A
  // caller passing a SUBDIRECTORY would otherwise scope `ls-files` and
  // `diff -- .` to that subtree while still switching the whole worktree — a
  // modification outside the subtree would be invisible and then destroyed.
  // The repo lock is keyed on the root for the same reason.
  let root: string;
  try {
    root = execFileSync("git", ["-C", repo, "rev-parse", "--show-toplevel"], { encoding: "utf-8", timeout: 10_000 }).trim();
  } catch {
    return { recovered: false, reason: "could not resolve the work tree root (fail-closed)" };
  }
  if (!root) return { recovered: false, reason: "not a git work tree — recovery skipped" };
  const key = repoKey(root);
  let lock: { held: boolean } | null = null;
  if (!opts.lockHeld) {
    lock = key ? acquireRepoLock(key, process.pid, { timeoutMs: 3000 }) : { held: false };
    if (!lock.held) {
      return { recovered: false, reason: "repo lock busy — recovery skipped" };
    }
  }
  try {
    return tryLosslessRecoverUnderLock(root, opts.branch ?? "main");
  } finally {
    if (lock && key) releaseRepoLock(key, process.pid);
  }
}

/** #1245: cap on a file we will read in order to compare it. A larger one is
 * refused UNREAD (never pulled into memory) — fail-closed. */
const MAX_COMPARE_BYTES = 64 * 1024 * 1024;

/** What GIT sees at a worktree path — the only faithful input to a lossless
 * comparison, and deliberately NOT `existsSync`/`hash-object -- <path>`, both of
 * which FOLLOW symlinks:
 *   - `existsSync` follows, so a DANGLING symlink reads as "absent" although the
 *     dirent and its target string exist → `lstatSync` is used instead (only
 *     ENOENT is absent);
 *   - `hash-object -- <path>` follows, hashing the POINTEE, while git stores a
 *     symlink as a blob of its TARGET STRING → the bytes are read here and piped
 *     through `hash-object --stdin`, which cannot follow and computes the hash
 *     in the repo's own object format.
 * `mode` is the git mode (100644 / 100755 / 120000). Anything that is neither a
 * bounded regular file nor a symlink is reported `unusable` WITHOUT being
 * opened — reading a FIFO would block forever while holding the repo lock.
 * ONLY `ENOENT` is `absent`: folding EACCES/ENOTDIR/ELOOP onto "absent" would let
 * a caller that treats absent as skippable (step 3b) skip the guard on a path it
 * could not actually inspect — fail-open in a fail-closed check (#873's class).
 * Exported for direct unit testing. */
export type LocalEntryRead =
  | { kind: "absent" }
  | { kind: "unusable"; why: string }
  | { kind: "entry"; mode: string; blob: string };

export function readLocalEntry(repo: string, rel: string): LocalEntryRead {
  const abs = join(repo, rel);
  let st: ReturnType<typeof lstatSync>;
  try {
    st = lstatSync(abs);
  } catch (e) {
    if ((e as NodeJS.ErrnoException)?.code === "ENOENT") return { kind: "absent" };
    return { kind: "unusable", why: `unreadable (${(e as NodeJS.ErrnoException)?.code ?? "unknown error"})` };
  }
  let mode: string;
  let input: string | Buffer;
  try {
    if (st.isSymbolicLink()) {
      mode = "120000";
      input = readlinkSync(abs);
    } else if (st.isFile()) {
      if (st.size > MAX_COMPARE_BYTES) return { kind: "unusable", why: `a ${st.size}-byte file (over the ${MAX_COMPARE_BYTES}-byte comparison cap)` };
      mode = (st.mode & 0o111) !== 0 ? "100755" : "100644";
      input = readFileSync(abs);
    } else {
      return { kind: "unusable", why: "not a regular file or symlink" };
    }
  } catch (e) {
    // A read that fails (EACCES, ENOENT after the lstat, …) must never throw out
    // of here: `freshnessTick` wraps the call, but auto-sync's session_start
    // block has no catch, so a throw becomes a rejected handler.
    return { kind: "unusable", why: `unreadable (${(e as NodeJS.ErrnoException)?.code ?? "unknown error"})` };
  }
  try {
    const blob = execFileSync("git", ["-C", repo, "hash-object", "--stdin"], { input, encoding: "utf-8", timeout: 30_000 }).trim();
    return { kind: "entry", mode, blob };
  } catch {
    return { kind: "unusable", why: "not hashable" };
  }
}

/** The (mode, blob) pair origin holds at `rel`, in ONE `ls-tree` read. Null when
 * origin does not track a BLOB there — absent, a directory (mode 040000), or a
 * gitlink (160000, a submodule). Those are not blobs, so no content comparison
 * is meaningful and the caller must refuse rather than compare a tree id. */
export function readOriginEntry(repo: string, remoteRef: string, rel: string): { mode: string; blob: string } | null {
  try {
    const entry = execFileSync("git", ["-C", repo, "ls-tree", "-z", remoteRef, "--", `:(literal)${rel}`], { encoding: "utf-8", timeout: 10_000 })
      .split("\0").filter(Boolean)[0] ?? "";
    const m = /^(\d{6}) \w+ ([0-9a-f]+)\t/.exec(entry);
    if (!m || (m[1] !== "100644" && m[1] !== "100755" && m[1] !== "120000")) return null;
    return { mode: m[1], blob: m[2] };
  } catch {
    return null;
  }
}

function tryLosslessRecoverUnderLock(repo: string, branch: string): { recovered: boolean; reason?: string } {
  if (!isSafeBranchName(branch)) {
    return { recovered: false, reason: `unsupported default-branch name ${JSON.stringify(branch)} — recovery skipped` };
  }
  if (syncState(repo, branch) !== "diverged") {
    return { recovered: false, reason: "not diverged — recovery not applicable" };
  }
  const remoteRef = `origin/${branch}`;
  // 1. untracked files first — the tracked-diff below must exclude them (a
  //    file present in origin/<branch> but untracked in the working tree reads
  //    as "deleted" in `git diff <commit>`, which would false-positive).
  //    `-z` + NUL split: raw paths, no quotepath escaping and no newline fold,
  //    and NO trim (a leading/trailing space is part of the name).
  let untracked: string[];
  try {
    untracked = execFileSync("git", ["-C", repo, "ls-files", "--others", "--exclude-standard", "-z"], { encoding: "utf-8", timeout: 30_000 })
      .split("\0").filter(Boolean);
  } catch {
    return { recovered: false, reason: "could not list untracked files" };
  }
  // 2. tracked working tree must match origin/<branch> exactly (lossless).
  //    `:(exclude,literal)` — NOT a bare `':(exclude)'+name`: a name containing a
  //    glob metacharacter (an untracked `a*.txt`) would otherwise exclude the
  //    TRACKED `a.txt` from the diff too, hiding a real modification and letting
  //    step 4 overwrite it (verified: `:(exclude)a*.txt` drops `a.txt` from
  //    `ls-files`, the literal form keeps it). Args are an ARRAY, so no shell
  //    quoting is involved and a quote in a name cannot break the pathspec.
  const excludePaths = untracked.map((f) => `:(exclude,literal)${f}`);
  try {
    execFileSync("git", ["-C", repo, "diff", remoteRef, "--quiet", "--", ".", ...excludePaths], { stdio: "ignore", timeout: 30_000 });
  } catch {
    return { recovered: false, reason: `tracked tree differs from origin/${branch} (real uncommitted work — keep)` };
  }
  // 2b. #1245 (review): the INDEX must not hold staged content origin/<branch>
  //     lacks. Step 2 compares the WORKTREE to the ref, so it is blind to an
  //     index-only difference when the worktree file matches origin (the `MM`
  //     shape: stage v3, then write the worktree back to origin's bytes). Tag-'H'
  //     paths are skipped by step 3b on the assumption step 2 covers them, and
  //     step 4's `checkout -f` RESETS the index — so staged-only content was
  //     silently destroyed. `D`-only entries are allowed: origin has a file the
  //     index lacks and the switch restores it, so nothing local is lost — the
  //     same allowance the sibling reset path makes (repo-freshness
  //     dirtySuperseded, #178 L2).
  let staged: string;
  try {
    staged = execFileSync("git", ["-C", repo, "diff", "--cached", "--name-status", remoteRef, "--"], { encoding: "utf-8", timeout: 30_000 });
  } catch {
    return { recovered: false, reason: "could not compare the index to origin (fail-closed)" };
  }
  const stagedOnly = staged.split("\n").filter(Boolean).filter((l) => (l.split("\t")[0] || l) !== "D");
  if (stagedOnly.length > 0) {
    return { recovered: false, reason: `index holds ${stagedOnly.length} staged path(s) not on origin/${branch} (staged-only content — keep)` };
  }
  // 3. untracked files must not collide with origin/<branch> content — EACH
  //    file re-read immediately before removal (never based on pre-lock state).
  //    The comparison is (mode, BLOB BYTES) via readLocalEntry/readOriginEntry:
  //    the old compare decoded BOTH sides as UTF-8 strings, and Node folds every
  //    invalid byte to U+FFFD — so two DIFFERENT binary files compared EQUAL and
  //    step 4 removed local content that was never on origin (VGATE round 4,
  //    reproduced through freshnessTick).
  for (const f of untracked) {
    const local = readLocalEntry(repo, f);
    if (local.kind === "absent") {
      return { recovered: false, reason: `untracked file "${f}" vanished during the check — retry` };
    }
    if (local.kind === "unusable") {
      return { recovered: false, reason: `untracked path "${f}" is ${local.why} — keep (fail-closed)` };
    }
    const origin = readOriginEntry(repo, remoteRef, f);
    if (origin === null) {
      return { recovered: false, reason: `untracked file "${f}" is not on origin/${branch} as a regular file (new work — keep)` };
    }
    if (origin.blob !== local.blob || origin.mode !== local.mode) {
      return { recovered: false, reason: `untracked file "${f}" differs from origin/${branch} — keep` };
    }
  }
  // 3b. #1245 (VGATE, three rounds): `git diff`/`status` are blind to index-FLAGGED
  //     paths — `assume-unchanged` ('h'), `skip-worktree` ('S'), both ('s'), and
  //     any tag this code has never heard of — because the flag tells git to
  //     treat the worktree copy as identical whatever it actually holds. Step 2's
  //     byte-identity test therefore reads CLEAN for a tree holding pinned local
  //     content, and step 4's forced checkout overwrites it. All three rounds are
  //     reproduced defects of one class: destroyed pinned content ('h'), the same
  //     via the defeatable stat cache ('S'), and a RETARGETED or DANGLING SYMLINK
  //     (`hash-object` follows links, so a retarget hashed equal to origin's
  //     symlink blob while `existsSync` called a dangling link 'absent').
  //     Same class as the sibling reset path (repo-freshness dirtySuperseded,
  //     #178 L2).
  //
  //     The check is the INVERSE of an allow-list — every record whose tag is not
  //     'H' is examined, so an unknown flag fails CLOSED — and it compares the
  //     (mode, blob) pair git would restore at the path, through the same
  //     readLocalEntry/readOriginEntry pair as step 3 (lstat, never existsSync;
  //     the target STRING for a symlink; hashed by `hash-object --stdin` so it
  //     cannot follow a link; MODE compared, because a regular file and a symlink
  //     are both 'blob' to cat-file and only 100644/100755 vs 120000 separates
  //     them; a FIFO/directory is refused unread rather than blocking forever).
  let lsf: string;
  try {
    lsf = execFileSync("git", ["-C", repo, "ls-files", "-v", "-z"], { encoding: "utf-8", timeout: 10_000 });
  } catch {
    return { recovered: false, reason: "could not list index-flagged files (fail-closed)" };
  }
  for (const rec of lsf.split("\0").filter(Boolean)) {
    if (rec[0] === "H") continue; // plain cached entry — step 2's diff already covers it
    const tag = rec[0];
    const f = rec.slice(2); // -z emits raw paths, no quotepath C-escaping
    const local = readLocalEntry(repo, f);
    if (local.kind === "absent") continue; // sparse-checkout 'S' entry — no content to destroy
    if (local.kind === "unusable") {
      return { recovered: false, reason: `index-flagged path "${f}" (tag '${tag}') is ${local.why} — refusing (fail-closed)` };
    }
    const origin = readOriginEntry(repo, remoteRef, f);
    if (origin === null) {
      return { recovered: false, reason: `index-flagged path "${f}" (tag '${tag}') is not on origin/${branch} as a regular file — the switch would remove or replace it` };
    }
    if (local.blob !== origin.blob) {
      return { recovered: false, reason: `index-flagged path "${f}" (tag '${tag}') differs from origin/${branch} (pinned local content — keep)` };
    }
    if (local.mode !== origin.mode) {
      return { recovered: false, reason: `index-flagged path "${f}" (tag '${tag}') has local mode ${local.mode} vs origin/${branch} ${origin.mode} (file/symlink/exec-bit change — keep)` };
    }
  }
  // 3c. #1245 (review): the paths the switch can WRITE are the union of the local
  //     <branch> tree and origin/<branch>'s tree — `checkout -f` writes the
  //     former from the index, the ff-merge then moves to the latter. An IGNORED
  //     file sitting at one of those paths (e.g. a gitignored file where the
  //     LOCAL branch still tracks a path origin deleted) is invisible to steps
  //     1-3 and would be destroyed. Files at paths in NEITHER tree (node_modules,
  //     a .env elsewhere) are never written, so they must NOT block recovery.
  //     The collision test is SYMMETRIC: a directory entry collides when a
  //     tracked path sits at or under it, and a FILE entry collides when its own
  //     path is tracked OR a tracked path sits UNDER it — `checkout -f` would
  //     replace that ignored file with a directory, destroying its only copy.
  const written = new Set<string>();
  for (const ref of [branch, remoteRef]) {
    try {
      for (const p of execFileSync("git", ["-C", repo, "ls-tree", "-r", "--name-only", "-z", ref], { encoding: "utf-8", timeout: 30_000 }).split("\0")) {
        if (p) written.add(p);
      }
    } catch {
      return { recovered: false, reason: `could not list the tree of ${ref} (fail-closed)` };
    }
  }
  let statusZ: string;
  try {
    statusZ = execFileSync("git", ["-C", repo, "status", "--porcelain", "-z", "--ignored=traditional"], { encoding: "utf-8", timeout: 30_000 });
  } catch {
    return { recovered: false, reason: "could not list untracked/ignored paths (fail-closed)" };
  }
  const writtenArr = [...written];
  for (const entry of statusZ.split("\0").filter(Boolean)) {
    if (!entry.startsWith("?? ") && !entry.startsWith("!! ")) continue;
    const raw = entry.slice(3);
    const isDir = raw.endsWith("/");
    const p = isDir ? raw.slice(0, -1) : raw;
    const collides = written.has(p) || writtenArr.some((t) => t.startsWith(p + "/"));
    if (!collides) continue;                 // never written by the switch — not a blocker
    if (!isDir && untracked.includes(p)) continue; // already identity-checked in step 3
    return { recovered: false, reason: `untracked/ignored path "${raw}" sits where the switch writes (keep)` };
  }
  // 3d. #1245 (review): the switch is only possible when no OTHER worktree holds
  //     <branch> — `git checkout -f <branch>` aborts with "already checked out"
  //     AFTER step 4 has already deleted the untracked residue. Kept INSIDE the
  //     primitive so the residue is never spent on a switch that cannot happen,
  //     whatever the caller believes: a `prunable` record (directory gone, record
  //     kept) still blocks GIT, so it must block this step even though it must
  //     not block a pull.
  let worktrees: string;
  let toplevel: string;
  try {
    worktrees = execFileSync("git", ["-C", repo, "worktree", "list", "--porcelain"], { encoding: "utf-8", timeout: 10_000 });
    toplevel = execFileSync("git", ["-C", repo, "rev-parse", "--show-toplevel"], { encoding: "utf-8", timeout: 10_000 }).trim();
  } catch {
    return { recovered: false, reason: "could not list worktrees (fail-closed)" };
  }
  const same = (p: string): string => {
    try { return realpathSync(p); } catch { return p; }
  };
  const selfTop = same(toplevel);
  for (const entry of worktrees.split("\n\n")) {
    const lines = entry.split("\n");
    const wtLine = lines.find((l) => l.startsWith("worktree "));
    const branchLine = lines.find((l) => l.startsWith("branch "));
    if (!wtLine || !branchLine) continue;
    if (branchLine.slice("branch ".length).replace(/^refs\/heads\//, "") !== branch) continue;
    if (same(wtLine.slice("worktree ".length)) === selfTop) continue;
    return { recovered: false, reason: `another worktree holds ${branch} — the switch would fail, refusing BEFORE touching any residue` };
  }
  // 3e. #1245 (review): step 4 is `checkout -f <branch>` THEN `merge --ff-only
  //     origin/<branch>`. If the local <branch> is not an ancestor of
  //     origin/<branch>, the merge fails AFTER the checkout has already MOVED the
  //     worktree and the residue was removed — a failed recovery that still moved
  //     the checkout (and overwrote files from the local branch's stale tree).
  //     Verify the fast-forward is possible BEFORE anything is touched.
  try {
    execFileSync("git", ["-C", repo, "merge-base", "--is-ancestor", branch, remoteRef], { stdio: "ignore", timeout: 10_000 });
  } catch {
    return { recovered: false, reason: `local ${branch} is not an ancestor of origin/${branch} — the fast-forward would fail, refusing before any move` };
  }
  // 4. lossless — drop residue, switch to the default branch, fast-forward.
  try {
    for (const f of untracked) rmSync(join(repo, f), { force: true });
    execSync(`git -C "${repo}" checkout -f ${branch}`, { stdio: "ignore", timeout: 30_000 });
    execSync(`git -C "${repo}" merge --ff-only ${remoteRef}`, { stdio: "ignore", timeout: 30_000 });
    return { recovered: true };
  } catch (e: any) {
    return { recovered: false, reason: `switch failed: ${e?.message ?? e}` };
  }
}

export default function (pi: ExtensionAPI) {
  pi.on("session_start", async () => {
    const infraPath = process.env.AGENT_INFRA_PATH;
    if (!infraPath) return;          // not configured — silent
    if (!existsSync(infraPath)) return;

    // #1661 (1): the unmerged-index check runs BEFORE the print-mode return,
    // before the fetch and before any mutation. Leftover unmerged stage-1/2/3
    // entries make `git pull --ff-only` refuse forever, and this used to fail
    // into silence — exactly the state a sub-agent must never be told nothing
    // about. `unmergedOp` distinguishes the abandoned index-only state from a
    // live merge/rebase/cherry-pick/revert so the banner does not misdiagnose it
    // (a rebase inverts --ours/--theirs). Read-only and cheap, so it runs in
    // every mode, and a pull is pointless until the index is resolved.
    const unmerged = unmergedEntries(infraPath);
    if (unmerged.length > 0) {
      for (const line of unmergedBanner(infraPath, unmerged, unmergedOp(infraPath))) console.log(line);
      return;
    }

    // #1661 (3): sub-agents still never pull — but they no longer return with
    // ZERO signal. A stale toolset is now visible to a print-mode sub-agent
    // (no fetch here: the count uses the last-fetched origin/main ref, a lower
    // bound, so print-mode startup stays network-free).
    if (isPrintMode()) {
      const behind = behindCount(infraPath);
      if (behind > 0) {
        const loud = stalenessBanner(infraPath, behind, stalenessThreshold());
        if (loud.length > 0) for (const line of loud) console.log(line);
        else console.log(`[auto-sync] ⏭️ print mode — no pull; extensions loaded from ${infraPath} @ ${shortHead(infraPath)} (${behind} commit(s) behind origin/main)`);
      }
      return;
    }

    try {
      execSync(`git -C "${infraPath}" fetch origin --quiet`, { timeout: 30_000, stdio: "ignore" });
    } catch {
      return; // offline — silent
    }

    // #195 L3: warn-only orphan sweep — aborted dispatches leave worktrees/
    // branches recorded in the teardown manifest; surface them within a day
    // without ever auto-deleting (scan-orphans.sh --apply is the manual gate).
    try {
      const out = execSync(`bash "${infraPath}/scripts/scan-orphans.sh" --repo "${infraPath}" 2>&1`, {
        timeout: 30_000,
        encoding: "utf-8",
      });
      const lines = out.trim().split("\n").filter((l) => l.includes("⚠️") || l.includes("👻") || l.includes("🧹"));
      if (lines.length > 0) {
        console.log(`[auto-sync] 🧹 ${lines.length} orphaned worktree/branch record(s) — inspect:`);
        console.log(lines.slice(0, 5).map((l) => `    ${l.trim()}`).join("\n"));
        console.log(`    Cleanup: bash "${infraPath}/scripts/scan-orphans.sh" --apply`);
      }
    } catch {
      // scanner missing/offline — silent (warn-only by design)
    }

    const state = syncState(infraPath);
    const syncHint = `cd "${infraPath}" && ./sync.sh`;
    const behind = state === "behind" ? behindCount(infraPath) : 0;

    // #1661 (2): surface a LARGE pin. The checkout could sit hundreds of commits
    // behind with nothing but the one-line "update available" hint below.
    for (const line of stalenessBanner(infraPath, behind, stalenessThreshold())) console.log(line);

    // ahead → nothing to fetch; report unpushed commits so they're not silently skipped.
    if (state === "ahead") {
      const n = aheadCount(infraPath);
      console.log(
        `[auto-sync] ℹ️  agent-infra is ahead of origin/main (local ${shortHead(infraPath)}) — ` +
        (n > 0 ? `${n} unpushed commit(s) on main` : "unpushed local commit(s)")
      );
      console.log(`    Push when ready: git -C "${infraPath}" push origin main`);
      return;
    }

    // #265: every MUTATION (lossless recovery, sync.sh run) is serialized by the
    // repo lock — concurrent pi processes never interleave force-switches or
    // ff-pulls. Clean acquire/release logs NOTHING (tests assert zero output on
    // the "current → silent" path); only foreign contention warns (skip —
    // recovery is convenience, never correctness-critical).
    const mutates = state === "diverged" ||
      (state === "behind" && (process.env.AGENT_SYNC_MODE || "warn") === "auto");
    if (mutates) {
      const key = repoKey(infraPath);
      const lock = key
        ? acquireRepoLock(key, process.pid, { timeoutMs: 3000, retryMs: 200 })
        : { held: false };
      if (!lock.held) {
        console.log(`[auto-sync] ⏭️ repo lock busy — another session is syncing; skipping this start`);
        return;
      }
      try {
        if (state === "diverged") {
          const rec = tryLosslessRecover(infraPath, { lockHeld: true });
          if (rec.recovered) {
            console.log(`[auto-sync] 🔁 stranded checkout recovered — now on main at ${shortHead(infraPath)} (tree matched origin/main losslessly)`);
            return;
          }
          console.log(`[auto-sync] ⚠️  agent-infra has diverged from origin/main — fast-forward sync blocked:`);
          console.log(`    Local : ${shortHead(infraPath)}`);
          console.log(`    Remote: ${shortHead(infraPath, "origin/main")}`);
          console.log(`    Inspect: git -C "${infraPath}" status`);
          console.log(`    History: git -C "${infraPath}" log --oneline --left-right HEAD...origin/main`);
          console.log(`    Next: stash or commit local work, then re-run sync:`);
          console.log(`        ${syncHint}`);
          if (rec.reason) console.log(`    (auto-recovery skipped: ${rec.reason})`);
          return;
        }
        // behind + AGENT_SYNC_MODE=auto → sync.sh under the lock
        try {
          const out = execSync(`bash "${infraPath}/sync.sh" 2>&1`, { timeout: 180_000, encoding: "utf-8" });
          console.log(`[auto-sync] ✅ agent-infra updated to ${shortHead(infraPath)} — config refreshed`);
          const lines = out.trim().split("\n").filter(l => l.includes("warning") || l.includes("⚠"));
          if (lines.length) console.log(lines.slice(0, 3).map(l => `    ${l}`).join("\n"));
        } catch (e: any) {
          const err = e as { stdout?: Buffer | string; message?: string };
          const detail = (err.stdout ? err.stdout.toString() : err.message || "unknown error")
            .split("\n").filter(Boolean).slice(0, 4).join("\n    ");
          console.log(`[auto-sync] ⚠️  update available but auto-sync failed:`);
          console.log(`    ${detail}`);
          console.log(`[auto-sync]    Run manually: ${syncHint}`);
        }
        return;
      } finally {
        releaseRepoLock(key, process.pid);
      }
    }

    if (state !== "behind") return; // current — silent

    console.log(`[auto-sync] ⚠️  agent-infra update available (${behind} commit(s) behind) — run: ${syncHint}`);
  });
}
