// branch-ownership.mjs — per-session branch-ownership sentinel for the SHARED
// main checkout (#265). Pure JS so plain-node tests can import the SAME rules.
//
// The shared checkout is a multi-actor resource: parallel pi sessions share ONE
// working tree, and branch state mutates under live sessions (auto-sync's
// session_start force-switch, unguarded `git checkout` from any session). This
// module records a per-session baseline {repoKey, branch, head} and provides
// pure decision functions for the guard's M1 (warn on branch deviation),
// M2 (block commit/push off-baseline), M3 (gate branch-state mutations), and
// the ownership allowance (own-branch hygiene ops in agent-infra main).
//
// Deliberately self-contained: it must NOT import classify-git.mjs (keeps the
// destructive-git classifier dependency-free for jiti loading, per the #99
// degradation contract). The small amount of command tokenization duplicated
// here (cd/-C/--git-dir extraction) is cross-checked against classify-git's
// skimmer by test-branch-ownership.mjs (T2 cross-consistency matrix).

import { execSync } from "node:child_process";
import { resolve, join } from "node:path";
import {
  mkdirSync, writeFileSync, readFileSync, rmSync, openSync, writeSync, closeSync,
  realpathSync,
} from "node:fs";
import { homedir } from "node:os";
import { createHash } from "node:crypto";

export const DEFAULT_LOCK_AGE_MS = 10 * 60_000;
export const DEFAULT_LOCK_RETRY_MS = 200;
export const DEFAULT_LOCK_TIMEOUT_MS = 10_000;

export function lockDir() {
  return process.env.AGENT_LOCKS_DIR || join(homedir(), ".pi", "agent", "locks");
}

function _lockPath(key) {
  return join(lockDir(), `${createHash("sha1").update(String(key)).digest("hex")}.lock`);
}

function _pidAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    return e.code === "EPERM"; // exists but not ours
  }
}

function _sleepSync(ms) {
  try {
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
  } catch {
    // fallback busy-wait (never expected on node)
  }
}

/**
 * Git-common-dir identity of a repo — NOT basename. Main checkout and ALL its
 * worktrees share the same common dir → same key (that is the point: M2 must
 * compare the SESSION's baseline repo, then exempt worktrees by effective
 * git-dir, never by cwd). Two repos with the same basename at different paths
 * get DIFFERENT keys. Returns null when not a git repo.
 */
export function repoKey(cwd) {
  try {
    const out = execSync("git rev-parse --git-common-dir", {
      encoding: "utf-8", cwd, timeout: 5000,
    }).trim();
    return _norm(resolve(cwd, out)); // common-dir may be relative to cwd
  } catch {
    try {
      return _norm(resolve(execSync("git rev-parse --show-toplevel", {
        encoding: "utf-8", cwd, timeout: 5000,
      }).trim()));
    } catch {
      return null;
    }
  }
}

// Normalize through symlinks (macOS: /tmp→/private/tmp, /var→/private/var) so
// keys computed from different path spellings of the same repo compare equal.
function _norm(p) {
  try {
    return realpathSync(p);
  } catch {
    return p;
  }
}

/**
 * Read branch state from a repo: { gitDir, branch (null if detached), head }.
 * Single combined git call (latency mitigation, plan AC/perf row).
 * Returns null when git fails (callers apply the fail-closed policy).
 * @param {string} cwd
 * @param {string} [gitDir] explicit --git-dir (resolved) override
 */
export function readBranchState(cwd, gitDir) {
  const flags = gitDir ? `--git-dir="${gitDir}"` : "";
  try {
    // Order matters: --abbrev-ref applies to ALL following args, so the plain
    // HEAD (full sha) must come BEFORE --abbrev-ref HEAD (branch name).
    const out = execSync(
      `git ${flags} rev-parse --git-dir HEAD --abbrev-ref HEAD`,
      { encoding: "utf-8", cwd, timeout: 5000 },
    ).trim().split("\n");
    const [gd, head, branch] = out;
    if (!gd || !head) return null;
    return {
      // git resolves the gitdir FILE form (worktree `.git` files with
      // `gitdir: ...` lines) — always use git's RESOLVED answer, never the
      // input path (the input may be the `.git` file itself).
      gitDir: resolve(cwd, gd),
      branch: branch === "HEAD" ? null : branch,
      head,
    };
  } catch {
    return null;
  }
}

/**
 * Quote-aware tokenizer for a shell command string. Preserves quoted
 * multi-word tokens as single tokens (path with spaces in `git -C "my repo"`).
 */
export function tokenize(command) {
  const tokens = [];
  const s = String(command ?? "");
  let i = 0;
  while (i < s.length) {
    while (i < s.length && /\s/.test(s[i])) i++;
    if (i >= s.length) break;
    let tok = "";
    let quote = null;
    while (i < s.length) {
      const ch = s[i];
      if (quote) {
        if (ch === quote) { quote = null; i++; continue; }
        if (ch === "\\" && quote === '"' && i + 1 < s.length) { tok += s[i + 1]; i += 2; continue; }
        tok += ch; i++;
        continue;
      }
      if (ch === "'" || ch === '"') { quote = ch; i++; continue; }
      if (/\s/.test(ch)) break;
      // Shell metachars + subshell parens are token boundaries (mirrors
      // classify-git.mjs) — `git add .&&git commit` and `(git commit)` must
      // tokenize as separate invocations (reviews P2-A/P2, cycles 1-3).
      if (ch === "&" || ch === "|" || ch === ";" || ch === "(" || ch === ")") { i++; break; }
      if (ch === "\\" && i + 1 < s.length) { tok += s[i + 1]; i += 2; continue; }
      tok += ch; i++;
    }
    if (tok) tokens.push(tok);
  }
  return tokens;
}

/**
 * Extract the git invocation from a command string:
 *   { cdCwd, gitDirHint, cHints, verb, rest } | null
 * - cdCwd: LAST cd target (sequential chained cd's resolved by caller against
 *   sessionCwd — bash semantics: `cd a && cd b` ends in b relative to a).
 * - gitDirHint: from --git-dir[=]<path> or a leading GIT_DIR=<path> env prefix.
 * - cHints: every `-C <path>` in order (multi -C chains resolve sequentially).
 * - verb/rest: tokens from the first non-flag token after `git` onward.
 */
export function extractGitInvocation(command, preferVerb = null) {
  const tokens = tokenize(command);
  let cdChain = [];
  let i = 0;
  // Pre-scan: collect the cd-chain as we walk (cd persists across invocations
  // in bash). When preferVerb is set, we scan ALL invocations and return the
  // one whose verb matches (review P2, cycle 3: `git -C <wt> status && git
  // checkout main` — the branch-state gate must resolve the repo for the
  // CHECKOUT, whose -C/hints differ from the first invocation).
  // #337: also collect same-command `VAR=value` assignments so a `cd $WT`
  // (or `cd "${WT}"`) can be resolved against them by resolveEffectiveRepo.
  let envGitDir = null;
  const vars = {};
  while (i < tokens.length) {
    const t = tokens[i];
    if (/^GIT_DIR=(.*)$/.test(t)) { envGitDir = t.slice("GIT_DIR=".length).replace(/^["']|["']$/g, ""); i++; continue; }
    if (/^GIT_WORK_TREE=/.test(t)) { i++; continue; }
    if (/^[A-Za-z_][A-Za-z0-9_]*=/.test(t)) {
      const eq = t.indexOf("=");
      vars[t.slice(0, eq)] = t.slice(eq + 1).replace(/^["']|["']$/g, "");
      i++;
      continue;
    }
    if (t === "cd") { cdChain.push(tokens[i + 1] ?? null); i += 2; continue; }
    if (t !== "git") { i++; continue; }
    // ── candidate git invocation ──
    let gitDirHint = envGitDir;   // GIT_DIR env applies to all invocations
    const cHints = [];
    let j = i + 1;
    while (j < tokens.length) {
      const tt = tokens[j];
      if (tt === "-C" || tt === "--cd") { cHints.push(tokens[j + 1] ?? ""); j += 2; continue; }
      if (tt.startsWith("--git-dir=")) { gitDirHint = tt.slice("--git-dir=".length); j++; continue; }
      if (tt === "--git-dir") { gitDirHint = tokens[j + 1] ?? ""; j += 2; continue; }
      if (tt === "--work-tree" || tt === "--namespace") { j += 2; continue; }
      if (tt.startsWith("--work-tree=") || tt.startsWith("--namespace=")) { j++; continue; }
      if (tt === "--no-pager" || tt === "-p" || tt === "--paginate") { j++; continue; }
      if (tt === "-c" || tt === "--config") { j += 2; continue; } // -c k=v pairs
      if (tt.startsWith("-")) { j++; continue; } // unknown global flags — skip
      break; // first non-flag token = subcommand
    }
    const verb = tokens[j] ?? null;
    if (preferVerb && verb !== preferVerb) { i = j; continue; } // not the target — keep scanning
    return { cdChain: [...cdChain], gitDirHint, cHints, verb, rest: tokens.slice(j), vars };
  }
  return null;
}

/**
 * GIT-FAITHFUL effective-repo resolution (plan §Architecture; empirically
 * verified against git 2.50.1 in cycle 4):
 *   (1) cd-chain resolves to a final cwd (sequential, last-wins);
 *   (2) each -C <path> resolves relative to the current cwd, in order;
 *   (3) gitDir = resolved --git-dir hint / GIT_DIR env (resolved against the
 *       FINAL cwd — git resolves --git-dir relative to the cwd after ALL -C
 *       chdirs, regardless of option order), else <finalCwd>/.git;
 *   (4) repoKey = git-common-dir of the RESOLVED gitDir; isWorktree = resolved
 *       gitDir contains "/worktrees/" (NEVER cwd-derived — `-C <wt>
 *       --git-dir=<main>/.git checkout` operates on the MAIN checkout);
 *   (5) currentBranch read FROM the resolved repo.
 * Returns null when git fails (caller applies fail-closed policy).
 * @param {string} command
 * @param {string} sessionCwd
 */
export function resolveEffectiveRepo(command, sessionCwd, preferVerb = null) {
  const inv = extractGitInvocation(command, preferVerb);
  if (!inv) return null;
  let cwd = sessionCwd ? resolve(sessionCwd) : process.cwd();
  for (const cd of inv.cdChain) {
    if (!cd) continue;
    const expanded = _expandCdVars(cd, inv.vars);
    // #337: an unresolvable `$VAR` cd target (no same-command assignment) must
    // NOT resolve to a bogus literal path (`<cwd>/$WT` → git read fails →
    // fail-closed block). Conservatively fall back to the session cwd — the
    // KNOWN reference point (the hub/main checkout) so the main-checkout gates
    // still apply rather than guessing a worktree.
    if (expanded === null) continue;
    cwd = resolve(cwd, expanded); // bash: `cd a && cd b` ends in b, relative to a
  }
  for (const c of inv.cHints) {
    if (!c) continue;
    cwd = resolve(cwd, c); // -C resolves relative to the current cwd, in order
  }
  const gitDir = inv.gitDirHint ? resolve(cwd, inv.gitDirHint) : join(cwd, ".git");
  const state = readBranchState(cwd, gitDir);
  if (!state) return null;
  return {
    repoKey: repoKey(state.gitDir) ?? repoKey(cwd), // common dir of the RESOLVED repo
    gitDir: state.gitDir,
    effectiveCwd: cwd,
    isWorktree:
      state.gitDir.includes("/worktrees/") || state.gitDir.endsWith("/worktrees"),
    currentBranch: state.branch,
  };
}

/** Expand `$VAR` / `${VAR}` in a cd target against same-command assignments.
 * Returns the expanded path, or null when any `$VAR` is unresolvable (caller
 * falls back to the session cwd — conservative, #337). Tilde/home expansion is
 * out of scope (unchanged from the pre-#337 behavior). */
function _expandCdVars(token, vars) {
  let t = String(token ?? "").replace(/^["']|["']$/g, "");
  if (!t.includes("$")) return t;
  const map = vars || {};
  let ok = true;
  t = t.replace(/\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)/g, (m, braced, plain) => {
    const name = braced ?? plain;
    if (Object.prototype.hasOwnProperty.call(map, name)) return map[name];
    ok = false;
    return m;
  });
  return ok ? t : null;
}

// ── M3 pure classification of branch-state verbs ───────────────────────────
// Given a git subcommand + args, return the branch-op class:
//   create-new | force-create | orphan | switch-existing | force | rename |
//   detach | other
// `other` covers path-restore / discard-all / tag refs / non-HEAD refs — NOT
// a checkout branch-state mutation.
export function classifyBranchOp(subcmd, args) {
  const a = args || [];
  if (subcmd === "checkout" || subcmd === "switch") {
    if (a.includes("--")) return { op: "other" };          // path-restore form
    const flag = (f) => a.includes(f);
    if (flag("--orphan")) return { op: "orphan" };
    if (flag("-B")) return { op: "force-create", branch: _branchAfter(a, "-B") };
    if (flag("-b") || flag("-c")) return { op: "create-new", branch: _branchAfter(a, flag("-b") ? "-b" : "-c") };
    if (flag("-f") || flag("--force")) return { op: "force" };
    if (flag("--detach")) return { op: "detach" };
    if (a.includes("-")) return { op: "switch-existing", target: "-" }; // prev branch
    const pos = a.filter((x) => !x.startsWith("-"));
    if (pos.length === 0) return { op: "other" };
    if (pos[0] === "." || pos[0] === "--") return { op: "other" }; // discard-all
    return { op: "switch-existing", target: pos[0] };
  }
  if (subcmd === "symbolic-ref") {
    const pos = a.filter((x) => !x.startsWith("-"));
    if (pos[0] === "HEAD") return { op: "switch-existing" };
    return { op: "other" }; // e.g. refs/remotes/origin/HEAD — not checkout state
  }
  if (subcmd === "update-ref") {
    const pos = a.filter((x) => !x.startsWith("-"));
    if (pos[0] && (/^refs\/heads\//.test(pos[0]) || pos[0] === "HEAD")) {
      return { op: "switch-existing" };
    }
    return { op: "other" }; // tags / notes / etc.
  }
  if (subcmd === "branch") {
    if (a.includes("-m") || a.includes("-M")) {
      const pos = a.filter((x) => !x.startsWith("-"));
      return {
        op: "rename",
        from: pos[0] ?? null,   // null → rename CURRENT branch
        to: pos[1] ?? null,
      };
    }
    if (a.includes("-f") || a.includes("--force")) {
      const pos = a.filter((x) => !x.startsWith("-"));
      return { op: "force", branch: pos[0] ?? null };
    }
    return { op: "other" }; // create/list/delete-without-D — not checkout state
  }
  return { op: "other" };
}

function _branchAfter(args, flag) {
  const idx = args.indexOf(flag);
  return args[idx + 1] ?? null;
}

/**
 * Parse a push refspec's DESTINATION branch. push.default=simple semantics:
 *   "" / null        → null (caller substitutes current branch)
 *   "HEAD"           → null (caller substitutes current branch)
 *   "src:dst"        → dst (refs/heads/ prefix stripped)
 *   "src" (no colon) → src (dst == src under simple)
 */
export function parseRefspecDst(refspec) {
  if (!refspec || refspec === "") return null;
  const r = String(refspec).replace(/^["']|["']$/g, "");
  const dst = r.includes(":") ? r.split(":").pop() : r;
  if (dst === "HEAD") return null;
  return dst.replace(/^refs\/heads\//, "");
}

// ── Pure decision functions (guard index.ts is a thin adapter) ─────────────

/** M1: warn only on BRANCH deviation (HEAD advancement on the same branch is
 * normal — own commits/rebase/pull/auto-sync ff must never warn). */
export function decideM1(currentBranch, baselineBranch) {
  if (!baselineBranch) return null;
  if (currentBranch === baselineBranch) return null;
  return { warn: true, from: baselineBranch, to: currentBranch ?? "(detached HEAD)" };
}

/**
 * M2: block commit/push off-baseline in the SESSION's baseline repo.
 * Worktree-effective repos are exempt (isWorktree true → null).
 * pushTargets is authoritative when present (multi-refspec / --delete); else
 * pushDst, else currentBranch (bare push → push.default=simple).
 */
export function decideM2({
  effectiveRepo, baseline, currentBranch, pushDst, pushTargets, verdict, allowActive,
}) {
  if (allowActive) return null; // marker/flag: escape hatch — M2 inactive
  if (!effectiveRepo || effectiveRepo.isWorktree) return null;
  if (!baseline || effectiveRepo.repoKey !== baseline.repoKey) return null;
  if (verdict === "block:commit") {
    if (currentBranch === baseline.branch) return null;
    return {
      block: true,
      reason: [
        `⛔ Commit blocked — branch ownership violated.`,
        `   Session baseline branch: "${baseline.branch}"`,
        `   Resolved repo is on:      "${currentBranch ?? "detached HEAD"}"`,
        `   The shared checkout was switched out from under this session (#265).`,
        `   → Recover your branch: git checkout -b <your-branch> (agent-infra) or`,
        `     work in an isolated worktree (using-git-worktrees skill).`,
      ].join("\n"),
    };
  }
  if (verdict === "block:push" || verdict === "block:force-push" || verdict === "block:push-delete") {
    let targets = pushTargets && pushTargets.length > 0
      ? pushTargets
      : (pushDst ? [pushDst] : [currentBranch]);
    targets = targets.map((t) => (t === "HEAD" ? currentBranch : t)).filter(Boolean);
    if (targets.length === 0) return null;
    if (targets.every((t) => t === baseline.branch)) return null;
    return {
      block: true,
      reason: [
        `⛔ Push blocked — branch ownership violated.`,
        `   Session baseline branch: "${baseline.branch}"`,
        `   Push target(s): ${targets.join(", ")}`,
        `   Pushing to any branch other than the session's own baseline is`,
        `   cross-session contamination (#265).`,
        `   → Push your own branch, or check out your baseline branch first.`,
      ].join("\n"),
    };
  }
  return null;
}

/**
 * M3: gate branch-state mutations in the MAIN checkout.
 *   create-new (checkout -b / switch -c): allowed ONLY in agent-infra main →
 *     returns { reBaseline: <branch> } so the guard re-adopts the baseline
 *     SYNCHRONOUSLY (the allowed carve-out must never trigger a spurious M1
 *     warn on the next tool_call).
 *   rename of the session's OWN baseline branch → { reBaseline: <to> }.
 *   everything else (switch-existing / force / force-create / orphan / detach
 *   / symbolic-ref HEAD / update-ref refs/heads / branch -f) → block.
 */
export function decideM3({ branchOp, isAgentInfra, baseline, currentBranch }) {
  if (!branchOp) return null;
  const op = branchOp.op;
  if (op === "create-new") {
    if (isAgentInfra) return { reBaseline: branchOp.branch };
    return {
      block: true,
      reason: [
        `⛔ git checkout -b / switch -c blocked in the MAIN checkout.`,
        `   Why: creating a branch here switches the SHARED tree for every`,
        `   parallel session (#265).`,
        `   → Non-infra repos: create a worktree (using-git-worktrees skill).`,
        `   → Agent-infra: this is allowed only for the infra repo itself.`,
      ].join("\n"),
    };
  }
  if (op === "rename") {
    const from = branchOp.from ?? currentBranch;
    if (baseline && from === baseline.branch && branchOp.to) {
      return { reBaseline: branchOp.to };
    }
    return {
      block: true,
      reason: [
        `⛔ git branch -m/-M blocked in the MAIN checkout.`,
        `   Why: renaming a branch mutates branch state in the shared tree (#265).`,
        `   → Renaming the session's OWN baseline branch is allowed; this rename`,
        `     targets "${from ?? "(current)"}" which is not this session's baseline.`,
      ].join("\n"),
    };
  }
  return {
    block: true,
    reason: [
      `⛔ Branch-state change blocked in the MAIN checkout (${op}).`,
      `   Why: the main checkout is SHARED between parallel agents — switching`,
      `   branches here moves the tree out from under every other session and`,
      `   commits land on the wrong branch (#265).`,
      `   → Work in an isolated worktree: invoke the using-git-worktrees skill.`,
      `   → Agent-infra create-new: git checkout -b <branch> is allowed.`,
    ].join("\n"),
  };
}

/**
 * Ownership allowance (agent-infra main, own baseline branch):
 *   merge/pull/rebase → current branch == baseline branch suffices (the
 *     mutation only ever advances the session's OWN branch; syncSource
 *     presence is not required — bare `git pull` pulls the own upstream).
 *   push / force-push / push-delete / branch-force-delete → EVERY named
 *     target == baseline branch (all-targets semantics — a multi-refspec
 *     `git push origin feat/1 other/2` must never slip a foreign target
 *     past the gate; symmetric with the delete case).
 */
export function ownershipAllowed({ opKind, currentBranch, baselineBranch, targets, syncSource }) {
  if (!baselineBranch) return false;
  if (currentBranch !== baselineBranch) return false;
  switch (opKind) {
    case "merge":
    case "pull":
    case "rebase":
      return true;
    case "push":
    case "force-push":
    case "push-delete":
    case "branch-force-delete": {
      const t = (targets || []).map((x) => (x === "HEAD" ? currentBranch : x)).filter(Boolean);
      return t.length > 0 && t.every((x) => x === baselineBranch);
    }
    default:
      return false;
  }
}

// ── Repo lock (O_EXCL pidfile + stale-steal + TTL + same-pid re-entrant) ───
// Serializes auto-sync's mutations (recovery AND sync.sh) across concurrent
// pi processes. SILENT on the clean path (auto-sync tests assert zero output);
// warns only on stale-steal and foreign-contention skip. Same-pid re-acquire
// is re-entrant success (auto-sync recovery must never self-skip).
export function acquireRepoLock(key, pid = process.pid, opts = {}) {
  const timeoutMs = opts.timeoutMs ?? DEFAULT_LOCK_TIMEOUT_MS;
  const retryMs = opts.retryMs ?? DEFAULT_LOCK_RETRY_MS;
  const maxAgeMs = opts.maxAgeMs ?? DEFAULT_LOCK_AGE_MS;
  const path = _lockPath(key);
  mkdirSync(lockDir(), { recursive: true });
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    try {
      const fd = openSync(path, "wx");
      try {
        writeSync(fd, JSON.stringify({ pid, startedAt: Date.now() }));
      } finally {
        closeSync(fd);
      }
      return { held: true, lockPath: path, owner: pid };
    } catch (e) {
      if (e.code !== "EEXIST") throw e;
      let stale = false;
      try {
        const raw = JSON.parse(readFileSync(path, "utf-8"));
        const holderPid = raw.pid;
        const age = Date.now() - (raw.startedAt || 0);
        if (holderPid === pid) return { held: true, lockPath: path, owner: pid, reentrant: true };
        if (!_pidAlive(holderPid) || age > maxAgeMs) stale = true;
      } catch {
        stale = true; // unparseable/corrupt → stale
      }
      if (stale) {
        try {
          rmSync(path, { force: true });
          console.warn(`[branch-ownership] 🗑️ stole stale repo lock: ${path}`);
        } catch { /* ignore */ }
        continue;
      }
      if (Date.now() >= deadline) {
        return { held: false, lockPath: path, reason: "timeout" };
      }
      _sleepSync(retryMs);
    }
  }
}

export function releaseRepoLock(key, pid = process.pid) {
  const path = _lockPath(key);
  try {
    const raw = JSON.parse(readFileSync(path, "utf-8"));
    if (raw.pid === pid) rmSync(path, { force: true });
  } catch { /* absent/unreadable → no-op; silent */ }
}
