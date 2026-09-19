// auto-sync.ts — Level-1 machine sync for agent-infra (session_start)
//
// On session start, if AGENT_INFRA_PATH is set:
//   - fetch origin and compare HEAD vs origin/main
//   - behind → AGENT_SYNC_MODE=auto  : run sync.sh (pull --ff-only + refresh config)
//   - behind → AGENT_SYNC_MODE=warn  : print a hint to run `cd "$AGENT_INFRA_PATH" && ./sync.sh`
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
    if (isPrintMode()) return; // sub-agents: no pulls, no noise

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

    console.log(`[auto-sync] ⚠️  agent-infra update available — run: ${syncHint}`);
  });
}
