// classify-git.mjs — shared destructive-git classification for main-worktree-guard.
// Pure JS so both index.ts (via jiti) and test.mjs can import the SAME rules.
//
// Also home of the escape-marker (#207) rules — ALLOW_MAIN_EDITS_MARKER_TTL_MS,
// isAllowMarkerActive, parseMarkerContent, isAllowMarkerPath, isAllowMarkerCommand,
// extractMarkerReason, isAllowMarkerRealpath, readAllowMarkerState — so test.mjs
// exercises the SAME marker logic index.ts uses (dependency-injected, fail-safe
// default = inactive → block).

import { execSync, execFileSync } from "node:child_process";
import { resolve, join, dirname } from "node:path";
import { existsSync, statSync, readFileSync, realpathSync, readdirSync } from "node:fs";

//
// Purpose: in the SHARED main checkout, branch-state-changing git operations
// (reset, checkout/switch, pull/merge/rebase, clean, force-push, branch -D,
// restore, stash pop) clobber other agents' working trees and move branches
// out from under them. Worktrees are isolated — these are only dangerous in
// the main checkout.

// Known limitation: classification is regex-based over the raw command string,
// so text inside string literals/comments (e.g. `echo "git pull"`) is a rare
// false positive. Accepted — agents rarely echo git commands, and the block
// message explains the escape hatch.
export const DESTRUCTIVE_GIT_PATTERNS = [
  { name: "reset", re: /\bgit\s+reset\b/ },
  { name: "clean", re: /\bgit\s+clean\b/ },
  // #210: require space/EOL after "merge" — \b matched the hyphen in
  // `git merge-base` (word boundary), blocking a read-only ancestor check and
  // pushing the session into a 29h nested-pi detour (2026-08-11). The
  // space/EOL requirement inherently excludes the read-only merge-* family
  // (merge-base, merge-file, merge-tree) while keeping real merges blocked.
  { name: "merge", re: /\bgit\s+merge\b(?!-)/ },
  { name: "rebase", re: /\bgit\s+rebase\b/ },
  { name: "pull", re: /\bgit\s+pull\b/ },
  { name: "branch-force-delete", re: /\bgit\s+branch\s+-\w*D\b/ },
  { name: "force-push", re: /\bgit\s+push\b[^;&|]*(-f|--force)\b/ },
  { name: "push-delete", re: /\bgit\s+push\b[^;&|]*(--delete\b|\s:\S+)/ },
  { name: "force-checkout", re: /\bgit\s+(checkout|switch)\s+(-f|--force)\b/ },
  { name: "checkout-discard-all", re: /\bgit\s+(checkout|switch)\s+-{0,2}\s*\.(\s|$|[;&|])/ },
  // Bare-ref or -b branch switch: `git checkout main`, `git checkout -b feat/x`,
  // `git checkout -` (previous branch). Explicitly NOT `git checkout -- <path>`
  // (path restore) and NOT other flags (`-p`, `-m`, ...). Must come AFTER
  // checkout-discard-all so `git checkout .` classifies as discard-all.
  { name: "checkout-branch", re: /\bgit\s+(checkout|switch)\s+(-b\s+)?(?!--)(?!-\w)(\S+)/ },
  { name: "restore", re: /\bgit\s+restore\b/ },
  { name: "stash-pop", re: /\bgit\s+stash\s+(pop|apply|drop|clear)\b/ },
];

/**
 * Classify a shell command for main-checkout safety.
 * @param {string} command
 * @returns {"allow" | "allow-non-git" | `block:${string}`}
 */
export function classifyGitCommand(command) {
  const c = String(command ?? "").trim();
  if (!c) return "allow";
  if (!/\bgit\b/.test(c)) return "allow-non-git";
  for (const { name, re } of DESTRUCTIVE_GIT_PATTERNS) {
    if (re.test(c)) return `block:${name}`;
  }
  return "allow";
}

// ── Detailed classifier (#265) ────────────────────────────────────────────
// classifyGitCommand above is FROZEN byte-identical (back-compat — test.mjs's
// existing string assertions + external importers depend on it; it carries NO
// new matchers). classifyGitCommandDetailed is the NEW object-returning
// classifier that index.ts consumes EXCLUSIVELY (call-site contract, plan
// deviation 8 / cycle-3 fold-in). It verb-anchors the SAME legacy patterns on
// the SKIMMED command (`git -c k=v checkout main` ≡ `git checkout main`) and
// adds commit / push / branch-state classification for the ownership gates.

/** Quote-aware tokenizer (mirrors branch-ownership.mjs; kept local so
 * classify-git stays dependency-free for jiti loading — the two are
 * cross-checked by test-branch-ownership.mjs's consistency matrix).
 *
 * Unlike branch-ownership's `tokenize`, this EMITS shell operators (`&&`, `||`,
 * `|`, `&`, `;`, `(`, `)`) and redirects (`>`, `>>`, `<`, `<<`, and fd-prefixed
 * forms like `2>`, `2>>`, `2>&1`, `1>&2`, `2>&-`) as their own tokens so
 * `_allGitInvocations` can delimit a git invocation's args at a pipe/redirect
 * instead of swallowing the trailing `tail`/`head`/`echo` consumer into the
 * verb's arg list (#337). The fd digit must ABUT the redirect (no space) — a
 * space makes the number a real arg (`git add 2 > out` keeps `2`). */
function _tokenize(command) {
  const tokens = [];
  const s = String(command ?? "");
  let i = 0;
  while (i < s.length) {
    while (i < s.length && /\s/.test(s[i])) i++;
    if (i >= s.length) break;

    // Two-char operators (`>>`/`<<` are redirects, not just `>`+`>`).
    const two = s.slice(i, i + 2);
    if (two === "&&" || two === "||" || two === ">>" || two === "<<") {
      tokens.push(two);
      i += 2;
      continue;
    }

    const ch = s[i];

    // fd-prefixed redirect (no intervening space): `2>`, `2>>`, `2<`, `2<<`,
    // `2>&1`, `1>&2`, `2>&-`. Consume the whole redirect operator as ONE token
    // so `git checkout main 2>&1 | tail -3` leaves `checkout` with just `main`.
    if (/[0-9]/.test(ch)) {
      let j = i;
      while (j < s.length && /[0-9]/.test(s[j])) j++;
      if (j < s.length && (s[j] === ">" || s[j] === "<")) {
        let k = j + 1;
        if (k < s.length && (s[k] === ">" || s[k] === "<")) k++;
        if (k < s.length && s[k] === "&") {
          k++;
          while (k < s.length && /[0-9-]/.test(s[k])) k++;
        }
        tokens.push(s.slice(i, k));
        i = k;
        continue;
      }
    }

    // Single-char shell operators: pipes, list separators, redirects, subshells.
    if (ch === "&" || ch === "|" || ch === ";" || ch === "(" || ch === ")" || ch === ">" || ch === "<") {
      tokens.push(ch);
      i++;
      continue;
    }

    // Regular token (quote- and escape-aware).
    let tok = "";
    let quote = null;
    while (i < s.length) {
      const c = s[i];
      if (quote) {
        if (c === quote) { quote = null; i++; continue; }
        if (c === "\\" && quote === '"' && i + 1 < s.length) { tok += s[i + 1]; i += 2; continue; }
        tok += c; i++; continue;
      }
      if (c === "'" || c === '"') { quote = c; i++; continue; }
      if (/\s/.test(c)) break;
      if (c === "&" || c === "|" || c === ";" || c === "(" || c === ")" || c === ">" || c === "<") break;
      if (c === "\\" && i + 1 < s.length) { tok += s[i + 1]; i += 2; continue; }
      tok += c; i++;
    }
    if (tok) tokens.push(tok);
  }
  return tokens;
}

/** Shell operators that end a git invocation's arg list (a pipe/redirect/chain
 * means the NEXT word starts a new command — a `tail`/`head`/`echo` consumer). */
const _SHELL_OPS = new Set(["&&", "||", "|", "&", ";", "(", ")"]);
function _isShellBoundary(tok) {
  if (_SHELL_OPS.has(tok)) return true;
  if (tok === ">" || tok === ">>" || tok === "<" || tok === "<<") return true;
  // fd-prefixed redirects emitted by _tokenize: `2>`, `2>>`, `2<`, `2<<`, `2>&1`,
  // `1>&2`, `2>&-`.
  if (/^[0-9]+(?:>>?|<<?)$/.test(tok)) return true;
  if (/^[0-9]+>&[0-9]*-?$/.test(tok)) return true;
  return false;
}

/**
 * Strip leading git GLOBAL flags (-C <path>, -c k=v, --git-dir[=],
 * --work-tree[=], --namespace, --no-pager, -p) and env/cd prefixes so the
 * verb-anchored matchers see `git checkout main` for
 * `cd /x && GIT_DIR=.. git -C y -c k=v checkout main`.
 * @returns {{ rest: string[], repoHint: string|null, gitDirHint: string|null }}
 *   rest = tokens from the subcommand onward (first non-flag token after git).
 */
export function skimGitGlobalFlags(command) {
  const tokens = _tokenize(command);
  let repoHint = null;
  let gitDirHint = null;
  let i = 0;
  while (i < tokens.length) {
    const t = tokens[i];
    if (/^GIT_DIR=(.*)$/.test(t)) { gitDirHint = t.slice("GIT_DIR=".length).replace(/^["']|["']$/g, ""); i++; continue; }
    if (/^GIT_WORK_TREE=/.test(t)) { i++; continue; }
    if (t === "cd") { i += 2; continue; }
    if (t === "git") break;
    i++;
  }
  if (i >= tokens.length || tokens[i] !== "git") return { rest: [], repoHint, gitDirHint };
  i++;
  while (i < tokens.length) {
    const t = tokens[i];
    if (t === "-C" || t === "--cd") { repoHint = tokens[i + 1] ?? null; i += 2; continue; }
    if (t.startsWith("--git-dir=")) { gitDirHint = t.slice("--git-dir=".length); i++; continue; }
    if (t === "--git-dir") { gitDirHint = tokens[i + 1] ?? ""; i += 2; continue; }
    if (t === "--work-tree") { i += 2; continue; }
    if (t.startsWith("--work-tree=")) { i++; continue; }
    if (t === "--namespace") { i += 2; continue; }
    if (t.startsWith("--namespace=")) { i++; continue; }
    if (t === "--no-pager" || t === "-p" || t === "--paginate") { i++; continue; }
    if (t === "-c" || t === "--config") { i += 2; continue; }
    if (t.startsWith("-")) { i++; continue; }
    break;
  }
  return { rest: tokens.slice(i), repoHint, gitDirHint };
}

function _stripQuotes(s) { return String(s ?? "").replace(/^["']|["']$/g, ""); }

function _refspecDst(refspec) {
  if (!refspec || refspec === "") return null;
  const r = _stripQuotes(refspec);
  const dst = r.includes(":") ? r.split(":").pop() : r;
  if (dst === "HEAD") return null;
  return dst.replace(/^refs\/heads\//, "");
}

/** Expand `$VAR` / `${VAR}` in a cd target against same-segment assignments
 * (mirrors branch-ownership's _expandCdVars — #337). Returns the expanded
 * target, or null when any `$VAR` is unresolvable (caller treats as
 * conservative → no exemption). Tokens from _tokenize are already quote-
 * stripped; the strip here is a safety net for direct callers. */
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

/** realpath a path; null on failure (nonexistent / ENOENT → conservative). */
function _realpathSafe(p) {
  try {
    return realpathSync(p);
  } catch {
    return null;
  }
}

/** Resolve a cd-chain (already var-expanded at walk time) against a base cwd.
 * Failed-cd semantics (cycle-4 P3, state (a)): a target that does not resolve
 * to an existing directory discards the failed target AND everything after it;
 * the resolved prefix stands (bash keeps the cwd before the failed cd). A null
 * entry (unresolvable $VAR / tilde / cd-) → whole chain null → conservative
 * (no exemption). */
function _resolveCdChain(cdChain, sessionCwd) {
  let cwd = sessionCwd ? resolve(sessionCwd) : process.cwd();
  for (const target of cdChain || []) {
    if (target === null || target === "~" || target.startsWith("~/") || target === "-") {
      return null;
    }
    const next = resolve(cwd, target);
    if (!existsSync(next)) break; // failed cd — keep the resolved prefix
    cwd = next;
  }
  return cwd;
}

/** Worktree map: canonical gitDir → worktree path, derived from the
 * `<common>/worktrees/<name>/gitdir` reverse-pointer files (git worktree list
 * --porcelain has NO gitdir column — empirically verified) + the filesystem
 * layout. Main checkout excluded by construction (its common dir is `common`
 * itself, never under `common/worktrees/`). Per-entry try/catch: stale admin
 * dirs (rm -rf <wt> without prune → ENOENT) are skipped, other worktrees stay
 * exempt (T34). Map key = realpath of the admin dir (which `git rev-parse
 * --git-dir` returns for a worktree cwd — probe-verified), NOT the reverse-
 * pointer content (which is the gitfile path <wt>/.git and differs).
 * @param {string} sessionCwd — the guard's session root (the hub).
 * @returns {Map<string,string>}
 */
function _worktreeGitdirMap(sessionCwd) {
  const map = new Map();
  try {
    const commonRaw = execSync("git rev-parse --git-common-dir", {
      encoding: "utf-8", cwd: resolve(sessionCwd), timeout: 5000, stdio: ["ignore", "pipe", "ignore"],
    }).trim();
    const common = _realpathSafe(resolve(sessionCwd, commonRaw));
    if (common === null) return map;
    const adminRoot = join(common, "worktrees");
    if (!existsSync(adminRoot)) return map;
    for (const name of readdirSync(adminRoot)) {
      try {
        const gitfile = readFileSync(join(adminRoot, name, "gitdir"), "utf-8").trim();
        const wtPath = _realpathSafe(dirname(gitfile));
        const adminKey = _realpathSafe(join(adminRoot, name));
        if (wtPath === null || adminKey === null) continue; // stale entry — skip
        map.set(adminKey, wtPath);
      } catch {
        // per-entry skip — never abort the whole map for one stale dir
      }
    }
  } catch {
    // whole-map conservative fallback (empty map → no exemptions)
  }
  return map;
}

/** Resolve a git invocation's effective target. Returns
 * { effectiveCwd, gitDir, worktreePath, isWorktree } or null (unresolvable /
 * git/fs failure → conservative, no exemption).
 * @param {{cdChain?: Array<string|null>, cHints?: string[], gitDirHint?: string|null, workTreeHint?: string|null}} inv
 * @param {string} sessionCwd — cwd frame for the worktree MAP (the hub).
 * @param {string} [baseCwd] — cd-chain/cHints resolution base (scriptGitVerdict
 *   passes executionCwd; the bash gate passes sessionCwd).
 */
export function resolveInvocationTarget(inv, sessionCwd = process.cwd(), baseCwd = sessionCwd) {
  try {
    const chainCwd = _resolveCdChain(inv.cdChain || [], baseCwd);
    if (chainCwd === null) return null; // unresolvable cd → conservative
    let cwd = chainCwd;
    for (const c of inv.cHints || []) cwd = resolve(cwd, c);
    cwd = _realpathSafe(cwd);
    if (cwd === null) return null;
    let raw;
    if (inv.gitDirHint) {
      // args-array form (execFileSync — execSync has NO array overload, cycle-4
      // P1): no shell interpolation; git resolves gitfiles to the canonical
      // git-dir.
      raw = execFileSync("git", ["--git-dir=" + resolve(cwd, inv.gitDirHint), "rev-parse", "--git-dir"], {
        encoding: "utf-8", cwd, timeout: 5000, stdio: ["ignore", "pipe", "ignore"],
      }).trim();
    } else {
      raw = execSync("git rev-parse --git-dir", { encoding: "utf-8", cwd, timeout: 5000, stdio: ["ignore", "pipe", "ignore"] }).trim();
    }
    const gitDir = _realpathSafe(resolve(cwd, raw));
    if (gitDir === null) return null;
    const worktreePath = _worktreeGitdirMap(sessionCwd).get(gitDir) ?? null;
    if (worktreePath === null) {
      return { effectiveCwd: cwd, gitDir, worktreePath: null, isWorktree: false };
    }
    const cwdReal = _realpathSafe(cwd);
    if (cwdReal === null) return null;
    const inside = cwdReal === worktreePath || cwdReal.startsWith(worktreePath + "/");
    // workTree mismatch guard: a work-tree hint pointing OUTSIDE the worktree
    // means the invocation operates on a foreign working tree → not isolated.
    if (inv.workTreeHint) {
      const wt = _realpathSafe(resolve(cwd, inv.workTreeHint));
      if (wt !== null && !(wt === worktreePath || wt.startsWith(worktreePath + "/"))) {
        return { effectiveCwd: cwd, gitDir, worktreePath, isWorktree: false };
      }
    }
    return { effectiveCwd: cwd, gitDir, worktreePath, isWorktree: inside };
  } catch {
    return null; // conservative — never false-exempt
  }
}

/** Extract EVERY git invocation in a compound command (handles
 * `git add . && git commit -m x` — the commit is what decideM2 must gate).
 * Extended shape (#347): per-invocation { verb, args, cdChain, cHints,
 * gitDirHint, workTreeHint, vars } — cdChain is subshell- AND pipe-scoped
 * (bash semantics, probe-verified): `(` pushes a chain copy / `)` pops (cds
 * inside parens never leak); every `|` pipeline segment runs in a subshell
 * seeded from C0 = the chain at the last command boundary BEFORE the first
 * pipe segment, and segment cds are discarded at the pipeline end.
 * cd targets are var-expanded AT WALK TIME against segment-local vars; an
 * unresolvable `$VAR` pushes a null marker (conservative → no exemption).
 * {verb, args} are unchanged for existing consumers.
 * @returns {Array<{verb: string|null, args: string[], cdChain: Array<string|null>, cHints: string[], gitDirHint: string|null, workTreeHint: string|null, vars: object}>}
 */
export function allGitInvocations(command) {
  const tokens = _tokenize(command);
  const invocations = [];
  // Per-paren-depth frame: chain, vars, baseLen (chain length at last
  // boundary), pipeC0 (chain before the first pipe segment), pipeActive.
  const stack = [{ chain: [], vars: {}, baseLen: 0, pipeC0: null, pipeActive: false }];
  const frame = () => stack[stack.length - 1];
  const boundary = () => {
    const f = frame();
    if (f.pipeActive && f.pipeC0) f.chain.splice(0, f.chain.length, ...f.pipeC0); // pipeline ended — restore C0
    f.pipeActive = false;
    f.pipeC0 = null;
    f.vars = {};
    f.baseLen = f.chain.length;
  };
  let pendingHints = {}; // GIT_DIR= / GIT_WORK_TREE= env prefixes — next command only
  let i = 0;
  while (i < tokens.length) {
    const t = tokens[i];
    if (t === "cd") {
      const target = tokens[i + 1] ?? null;
      i += 2;
      const f = frame();
      const expanded = target === null ? null : _expandCdVars(target, f.vars);
      f.chain.push(expanded);
      continue;
    }
    if (t === "(") {
      const f = frame();
      if (f.pipeActive && f.pipeC0) f.chain.splice(0, f.chain.length, ...f.pipeC0);
      stack.push({ chain: [...f.chain], vars: {}, baseLen: f.chain.length, pipeC0: null, pipeActive: false });
      pendingHints = {};
      i++;
      continue;
    }
    if (t === ")") {
      if (stack.length > 1) stack.pop();
      pendingHints = {};
      i++;
      continue;
    }
    if (t === "|") {
      const f = frame();
      if (!f.pipeActive) {
        f.pipeC0 = f.chain.slice(0, f.baseLen); // C0 = chain at the last boundary BEFORE the first pipe segment
        f.pipeActive = true;
      }
      f.chain.splice(0, f.chain.length, ...(f.pipeC0 || [])); // discard segment cds, reseed from C0
      f.vars = {};
      f.baseLen = f.chain.length;
      pendingHints = {};
      i++;
      continue;
    }
    if (t === "&&" || t === "||" || t === ";") { boundary(); pendingHints = {}; i++; continue; }
    if (/^GIT_DIR=/.test(t)) { pendingHints.gitDirHint = t.slice("GIT_DIR=".length); i++; continue; }
    if (/^GIT_WORK_TREE=/.test(t)) { pendingHints.workTreeHint = t.slice("GIT_WORK_TREE=".length); i++; continue; }
    if (/^[A-Za-z_][A-Za-z0-9_]*=/.test(t)) {
      const eq = t.indexOf("=");
      frame().vars[t.slice(0, eq)] = t.slice(eq + 1);
      i++;
      continue;
    }
    if (t !== "git") { i++; continue; }
    // ── git invocation ──
    i++;
    const f = frame();
    const cHints = [];
    let gitDirHint = pendingHints.gitDirHint ?? null;
    let workTreeHint = pendingHints.workTreeHint ?? null;
    pendingHints = {};
    while (i < tokens.length) {
      const g = tokens[i];
      if (/^GIT_DIR=/.test(g)) { gitDirHint = g.slice("GIT_DIR=".length); i++; continue; }
      if (/^GIT_WORK_TREE=/.test(g)) { workTreeHint = g.slice("GIT_WORK_TREE=".length); i++; continue; }
      if (g === "cd") { i += 2; continue; }
      if (g === "-C" || g === "--cd") { cHints.push(tokens[i + 1] ?? ""); i += 2; continue; }
      if (g.startsWith("--git-dir=")) { gitDirHint = g.slice("--git-dir=".length); i++; continue; }
      if (g === "--git-dir") { gitDirHint = tokens[i + 1] ?? null; i += 2; continue; }
      if (g.startsWith("--work-tree=")) { workTreeHint = g.slice("--work-tree=".length); i++; continue; }
      if (g === "--work-tree") { workTreeHint = tokens[i + 1] ?? null; i += 2; continue; }
      if (g === "--namespace") { i += 2; continue; }
      if (g.startsWith("--namespace=")) { i++; continue; }
      if (g === "--no-pager" || g === "-p" || g === "--paginate") { i++; continue; }
      if (g === "-c" || g === "--config") { i += 2; continue; }
      if (g.startsWith("-")) { i++; continue; }
      break;
    }
    const verb = tokens[i] ?? null;
    const args = [];
    i++;
    // #337: STOP at a pipe/redirect/chain instead of skipping it — the trailing
    // `tail`/`head`/`echo` consumer of a wrapper (`git ... 2>&1 | tail -3`) must
    // NOT pollute the verb's arg list. The NEXT `git` token still starts a new
    // invocation (every invocation is gated, so a destructive op in ANY segment
    // still blocks).
    while (i < tokens.length && tokens[i] !== "git" && !_isShellBoundary(tokens[i])) {
      args.push(tokens[i]);
      i++;
    }
    invocations.push({
      verb, args,
      cdChain: f.pipeActive ? f.chain.slice(0, f.baseLen) : [...f.chain],
      cHints, gitDirHint, workTreeHint,
      vars: { ...f.vars },
    });
  }
  return invocations;
}

/**
 * Detailed classification of a shell command (consumed EXCLUSIVELY by
 * main-worktree-guard/index.ts). Shape:
 *   { verdict, repoHint, gitDirHint, verb, verbArgs, branchState,
 *     newBranch, pushDst, pushTargets, isPushDelete, renameFrom, renameTo,
 *     syncSource }
 * - verdict: legacy `block:*` strings for destructive patterns (verb-anchored),
 *   plus NEW `block:commit` / `block:push` / `block:force-push`; `allow` /
 *   `allow-non-git` otherwise.
 * - branchState: true for checkout/switch/symbolic-ref/update-ref/branch ops
 *   that mutate the checkout's branch (M3 gate runs on these regardless of
 *   verdict — symbolic-ref/update-ref/branch -f have NO legacy pattern).
 * - force-push hygiene: `--force-with-lease` / `--force-if-includes` are NOT
 *   force (the legacy `--force\b` regex false-matches them); a force-with-lease
 *   push classifies `block:push` (ownership path), not `block:force-push`.
 */
export function classifyGitCommandDetailed(command) {
  const { repoHint, gitDirHint } = skimGitGlobalFlags(command);
  const invocations = allGitInvocations(command);
  const out = {
    verdict: "allow", repoHint, gitDirHint, verb: invocations[0]?.verb ?? null,
    verbArgs: invocations[0]?.args ?? [], branchState: false, newBranch: null,
    pushDst: null, pushTargets: [], isPushDelete: false,
    renameFrom: null, renameTo: null, syncSource: null,
  };
  if (invocations.length === 0) return { ...out, verdict: "allow-non-git" };

  // ── verb-anchored legacy destructive patterns ──
  // Run on the RAW command (compound chains: `git pull && git merge`), and if
  // that misses, on the SKIMMED first invocation (`git -C x checkout main` ≡
  // `git checkout main` — the -C/-c/GIT_DIR prefixes defeat the raw regexes,
  // which is exactly why they were verified bypasses).
  const raw = String(command ?? "").trim();
  const skimmedFirst = `git ${invocations[0].verb ?? ""} ${(invocations[0].args || []).join(" ")}`.trim();
  for (const { name, re } of DESTRUCTIVE_GIT_PATTERNS) {
    if (re.test(raw)) { out.verdict = `block:${name}`; break; }
  }
  if (out.verdict === "allow" && skimmedFirst !== "git") {
    for (const { name, re } of DESTRUCTIVE_GIT_PATTERNS) {
      if (re.test(skimmedFirst)) { out.verdict = `block:${name}`; break; }
    }
  }

  const commitInv = invocations.find((v) => v.verb === "commit");
  const pushInv = invocations.find((v) => v.verb === "push");
  const stateInv = invocations.find((v) =>
    ["checkout", "switch", "symbolic-ref", "update-ref", "branch"].includes(v.verb));
  const syncInv = invocations.find((v) => ["merge", "pull", "rebase"].includes(v.verb));

  // ── push: refspec targets + force-push hygiene (highest priority — a
  // compound commit+push is adequately gated by the push target check) ──
  if (pushInv) {
    const legacyVerdict = out.verdict;
    const args = pushInv.args;
    const joined = `git push ${args.join(" ")}`;
    const deleteIdx = args.findIndex((a) => a === "--delete" || a.startsWith("--delete="));
    const colonTargets = args.filter((a) => /^:/.test(a));
    if (deleteIdx !== -1 || colonTargets.length > 0 || legacyVerdict === "block:push-delete") {
      out.isPushDelete = true;
      out.verdict = "block:push-delete";
      out.pushTargets = [...(deleteIdx !== -1 ? args.slice(deleteIdx + 1) : []), ...colonTargets]
        .filter((x) => !x.startsWith("-"))
        .map((x) => _stripQuotes(x).replace(/^:/, "").replace(/^refs\/heads\//, ""))
        .filter(Boolean);
    } else if (legacyVerdict === "allow" || legacyVerdict === "block:force-push") {
      out.verdict = "block:push";
      // git push [remote] [refspec...] — the FIRST positional is the REMOTE
      // when there are ≥2 positionals (push.default=simple: refspec == src)
      const positionals = args.filter((x) => !x.startsWith("-"));
      const refspecs = positionals.length > 1 ? positionals.slice(1) : [];
      out.pushTargets = refspecs.map(_refspecDst).filter((x) => x !== null && x !== undefined);
      out.pushDst = out.pushTargets.length === 1 ? out.pushTargets[0] : null;
      const hasPlainForce = /(^|\s)-f(\s|$)/.test(joined) || /(^|\s)--force(\s|$)/.test(joined);
      if (out.verdict === "block:force-push" || hasPlainForce) {
        if (hasPlainForce) out.verdict = "block:force-push";
        else out.verdict = "block:push"; // legacy --force\b false-matched lease/includes
      }
    }
    // legacyVerdict was some other destructive (reset etc.) → keep it
  }

  // ── commit matcher (excludes commit-graph/commit-tree) — only when no
  // push or legacy destructive verdict already applies ──
  if (commitInv && !pushInv && out.verdict === "allow") {
    out.verdict = "block:commit";
  }

  // ── sync-source for merge/pull/rebase (ownership allowance) ──
  if (syncInv && !pushInv) {
    const args = syncInv.args;
    const pos = args.filter((x) => !x.startsWith("-"));
    if (syncInv.verb === "merge") out.syncSource = pos[0] ?? null;
    else if (pos.length > 1) out.syncSource = pos[1] ?? null; // pull/rebase [remote] [ref]
    else out.syncSource = pos[0] ?? null;
  }

  // ── branch-state verbs (M3 gate) ──
  if (stateInv) {
    const verb = stateInv.verb;
    const args = stateInv.args;
    if (verb === "checkout" || verb === "switch") {
      out.branchState = true;
      const flag = ["-B", "--orphan", "-b", "-c"].find((f) => args.includes(f));
      if (flag) {
        const idx = args.indexOf(flag);
        out.newBranch = args[idx + 1] ?? null;
      }
    } else if (verb === "symbolic-ref" || verb === "update-ref") {
      const pos = args.filter((x) => !x.startsWith("-"));
      if ((verb === "symbolic-ref" && pos[0] === "HEAD") ||
          (verb === "update-ref" && pos[0] && (/^refs\/heads\//.test(pos[0]) || pos[0] === "HEAD"))) {
        out.branchState = true;
      }
    } else if (verb === "branch") {
      if (args.includes("-m") || args.includes("-M")) {
        const pos = args.filter((x) => !x.startsWith("-"));
        out.branchState = true;
        out.renameFrom = pos[0] ?? null;
        out.renameTo = pos[1] ?? null;
      } else if (args.includes("-f") || args.includes("--force") ||
                 args.includes("-D") || args.includes("-d")) {
        // P1-B: -D/-d delete must set newBranch so the allowance target list is
        // non-empty (a ceremony `git branch -D $PR_BRANCH` on the own branch is
        // allowed; without this, ownershipAllowed([]) is false -> false-block).
        out.branchState = true;
        out.newBranch = args.filter((x) => !x.startsWith("-"))[0] ?? null;
      }
    }
    // P1-A: expose the STATE-mutating invocation's verb/args — M3 must classify
    // the invocation that changes branch state, not invocations[0] (a compound
    // `git pull && git checkout main` would otherwise classify "pull" and skip
    // the gate, or false-block the sanctioned create-new carve-out).
    out.stateVerb = verb;
    out.stateArgs = args;
  }

  return out;
}

/**
 * Is this cwd inside a git WORKTREE (as opposed to the main checkout)?
 * Main checkout: git-common-dir is ".git" (or the real .git path).
 * Worktree:      git-common-dir resolves into <main>/.git/worktrees/<name>.
 */
export function isWorktreeCwd(cwd) {
  try {
    // --git-dir in a linked worktree resolves into <main>/.git/worktrees/<name>;
    // in the main checkout it is just ".git" (or the real .git path).
    const gitDir = execSync("git rev-parse --git-dir", {
      encoding: "utf-8", cwd, timeout: 5000,
    }).trim();
    return gitDir.includes("/worktrees/") || gitDir.endsWith("/worktrees");
  } catch {
    return false; // not a git repo — treat as main (safe default: block)
  }
}

/**
 * Extract the branch name from `git push [remote] --delete <branch>`.
 * Handles both short names ("feat/x") and full refs ("refs/heads/feat/x").
 * @param {string} command
 * @returns {string|null} branch name (short form) or null
 */
export function extractPushDeleteBranch(command) {
  const c = String(command ?? "").trim();
  // Match both --delete <branch> (preferred) and :branch (old-style).
  // Branch names: alphanumeric + / - _ . only (no ; & |)
  const re = /\bgit\s+push\b[^;&|]*(?:--delete\s+([^\s;&|]+)|:([^\s;&|]+)(?!\S))/g;
  const branches = [];
  let m;
  while ((m = re.exec(c)) !== null) {
    const raw = (m[1] || m[2]).replace(/^["']|["']$/g, ""); // strip quotes
    branches.push(raw.replace(/^refs\/heads\//, ""));
  }
  return branches.length > 0 ? branches : null;
}

/**
 * Get a map of branch ref → worktree paths (from git worktree list --porcelain).
 * Works from any checkout (main or worktree).
 * @returns {Map<string, string[]>} key: "refs/heads/<name>", value: [worktree paths]
 */
export function getWorktreeBranches() {
  const branches = new Map();
  try {
    const out = execSync("git worktree list --porcelain", {
      encoding: "utf-8", timeout: 5000,
    });
    let currentPath = null;
    for (const line of out.split("\n")) {
      if (line.startsWith("worktree ")) {
        currentPath = line.slice("worktree ".length);
      } else if (line.startsWith("branch ") && currentPath) {
        const branch = line.slice("branch ".length);
        if (!branches.has(branch)) branches.set(branch, []);
        branches.get(branch).push(currentPath);
      }
    }
  } catch {
    // If git worktree list fails, return empty map (safe default)
  }
  return branches;
}

/**
 * Check if a branch is checked out in the MAIN checkout (not a worktree).
 * @param {string} branch - branch short name (e.g. "feat/x")
 * @returns {boolean}
 */
export function isBranchInMainCheckout(branch) {
  try {
    const currentBranch = execSync("git branch --show-current", {
      encoding: "utf-8", timeout: 5000,
    }).trim();
    return currentBranch === branch;
  } catch {
    // Fail-safe: if we can't verify, assume checked out (block)
    return true;
  }
}

/**
 * Get the branch checked out in the MAIN checkout (not a worktree).
 * Returns null if in a worktree, detached HEAD, or git unavailable.
 * @returns {string|null}
 */
export function getMainCheckoutBranch() {
  try {
    const gitDir = execSync("git rev-parse --git-dir", {
      encoding: "utf-8", timeout: 5000,
    }).trim();
    // If git-dir resolves into worktrees/, we're in a worktree — the main
    // checkout is a separate entity, so return null.
    if (gitDir.includes("/worktrees/") || gitDir.endsWith("/worktrees")) {
      return null;
    }
    return execSync("git branch --show-current", {
      encoding: "utf-8", timeout: 5000,
    }).trim() || null;
  } catch {
    return null;
  }
}

/**
 * Is `cwd` inside the agent-infra repo itself (the infrastructure repo)?
 * The guard skips enforcement for agent-infra because it is a small infra repo
 * whose main checkout is where infra fixes land (#99).
 *
 * Detection order — no single source of truth, no env var required:
 *   1. Env exact-match: canonical `AGENT_INFRA_PATH` (exported to ~/.zshrc by
 *      pi-bootstrap/setup.sh), then legacy `AGENT_INFRA_ROOT` — the resolved git
 *      toplevel must equal the resolved env value.
 *   2. Repo fingerprint (always active): `manifest.json` + `pi-bootstrap/setup.sh`
 *      present at the git toplevel — unique to agent-infra checkouts, so it also
 *      works in sub-agents / fresh shells where the env var is unset.
 *
 * @param {string} [cwd]  git cwd (default process.cwd())
 * @param {object} [env]  environment to read (default process.env)
 * @returns {boolean}
 */
export function isAgentInfraRepo(cwd = process.cwd(), env = process.env) {
  let topLevel;
  try {
    topLevel = resolve(
      execSync("git rev-parse --show-toplevel", {
        encoding: "utf-8", cwd, timeout: 5000,
      }).trim()
    );
  } catch {
    return false; // not in a git repo (or git unavailable) — never agent-infra
  }
  // 1) Exact env-var match (canonical AGENT_INFRA_PATH first, legacy ROOT second)
  for (const name of ["AGENT_INFRA_PATH", "AGENT_INFRA_ROOT"]) {
    const root = env[name];
    if (root && resolve(topLevel) === resolve(String(root))) return true;
  }
  // 2) Repo fingerprint: manifest.json + pi-bootstrap/setup.sh at the toplevel
  return (
    existsSync(join(topLevel, "manifest.json")) &&
    existsSync(join(topLevel, "pi-bootstrap", "setup.sh"))
  );
}

// ── Escape marker (#207) ────────────────────────────────────────────────────
// TTL'd file marker at ~/.pi/agent/.allow-main-edits: a deliberate, audited,
// session-scoped mid-session escalation window for a guard-blocked session.
// All decision logic lives here (dependency-injected, isAgentInfraRepo(cwd, env)
// pattern) so index.ts (via jiti) and test.mjs exercise the SAME rules.
// Fail-safe: any failure (absent / unreadable / expired / unparseable /
// unscoped / mismatched / symlinked) → inactive → block. Never env-overridable.

// Single source of truth for the marker TTL — a security parameter, so it is
// deliberately NOT env-overridable (testability comes via function params).
export const ALLOW_MAIN_EDITS_MARKER_TTL_MS = 15 * 60 * 1000;

/**
 * Is the marker fresh? mtime-based TTL, strict `<` (a marker exactly TTL old
 * is expired). `touch` refreshes the window. Re-read per tool_call — never
 * cached at module level.
 * @param {object|null} stats  fs.Stats from statSync (null = absent)
 * @param {number} [nowMs]     injected clock (default Date.now())
 * @param {number} [ttlMs]     injected TTL (default ALLOW_MAIN_EDITS_MARKER_TTL_MS)
 * @returns {boolean}
 */
export function isAllowMarkerActive(stats, nowMs = Date.now(), ttlMs = ALLOW_MAIN_EDITS_MARKER_TTL_MS) {
  if (!stats) return false; // absent → fail-safe block
  const age = nowMs - stats.mtimeMs;
  if (!Number.isFinite(age)) return false; // non-finite mtime → block
  // P2 (review): a future-dated mtime (age < 0) would extend the TTL
  // indefinitely via `touch -d 2099-...` — reject beyond a 60s clock-skew
  // tolerance instead of trusting any negative age.
  if (age < -60_000) return false;
  return age < ttlMs;
}

/**
 * Parse the one-JSON-line marker content. Missing fields are the read-side
 * match's problem, not the parser's.
 * @param {string} content
 * @returns {object|null} parsed {session_id?, reason?, ts?} or null
 */
export function parseMarkerContent(content) {
  try {
    const parsed = JSON.parse(String(content ?? "").trim());
    return parsed !== null && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : null;
  } catch {
    return null;
  }
}

/**
 * Exact-match path guard: the given path must resolve EXACTLY to
 * <home>/.pi/agent/.allow-main-edits. Traversal / sibling / unrelated
 * candidates → false; throw → false.
 * @param {string} path
 * @param {string} home
 * @returns {boolean}
 */
export function isAllowMarkerPath(path, home) {
  try {
    return resolve(String(path)) === resolve(join(home, ".pi", "agent", ".allow-main-edits"));
  } catch {
    return false;
  }
}

/**
 * Extract the trailing `# reason` comment from a marker command.
 * @param {string} command
 * @returns {string|null} trimmed reason, or null when absent/empty
 */
export function extractMarkerReason(command) {
  const c = String(command ?? "").trim();
  const hashIdx = c.indexOf("#");
  if (hashIdx === -1) return null;
  const reason = c.slice(hashIdx + 1).trim();
  return reason || null;
}

/**
 * Is `command` a bare `touch <marker-path>` (optional trailing `# reason`)?
 * One-command-per-touch contract (F10c): chains containing `&&`, `;`, `|`,
 * `$(...)`, backticks are rejected — the guard classifies the WHOLE command
 * before any stamping, so a combined `touch ... && git ...` one-liner stays
 * inert. `printf`/`echo`/redirect to the marker path → false (out-of-contract:
 * the shell write would clobber the guard's stamp → unscoped → blocked).
 * Tilde / `$HOME` expansion (incl. quoted variants) happens BEFORE resolve.
 * @param {string} command
 * @param {string} home
 * @returns {boolean}
 */
export function isAllowMarkerCommand(command, home) {
  const c = String(command ?? "").trim();
  if (!c) return false;
  // Reject command chains / pipes / substitution (one command per touch).
  if (/&&|\||;|\$\(|`/.test(c)) return false;
  // Strip a trailing `# reason` comment before matching the touch form.
  let rest = c;
  const hashIdx = rest.indexOf("#");
  if (hashIdx !== -1) rest = rest.slice(0, hashIdx).trim();
  // Bare `touch <single-path-token>` only — no flags, exactly one argument.
  const m = /^touch\s+(\S+)\s*$/.exec(rest);
  if (!m) return false;
  return isAllowMarkerPath(_expandMarkerToken(m[1], home), home);
}

/**
 * The SOLE symlink defense (pinned firing form, F6/round-2 F3): reject ANY
 * symlink indirection — realpathSync(path) must equal resolve(path). A broken
 * link or nonexistent path makes realpathSync throw → false (absent → block).
 * No isSymbolicLink() branch anywhere (statSync follows symlinks).
 * @param {string} path
 * @returns {boolean}
 */
export function isAllowMarkerRealpath(path) {
  try {
    return realpathSync(String(path)) === resolve(String(path));
  } catch {
    return false;
  }
}

/**
 * Full read-side marker state: active for THIS session ⟺ realpath-clean AND
 * mtime fresh AND content parses AND session_id matches. Any failure → false
 * (block). This is the exact function index.ts calls per tool_call.
 * @param {string} path
 * @param {string|null|undefined} sessionId
 * @param {number} [nowMs]
 * @param {number} [ttlMs]
 * @returns {boolean}
 */
export function readAllowMarkerState(path, sessionId, nowMs = Date.now(), ttlMs = ALLOW_MAIN_EDITS_MARKER_TTL_MS) {
  try {
    if (!isAllowMarkerRealpath(path)) return false;
    const stats = statSync(path);
    if (!isAllowMarkerActive(stats, nowMs, ttlMs)) return false;
    const content = readFileSync(path, "utf-8");
    const parsed = parseMarkerContent(content);
    if (!parsed) return false;
    const sid = parsed.session_id;
    if (typeof sid !== "string" || !sessionId || sid !== sessionId) return false;
    return true;
  } catch {
    return false;
  }
}

// ── M4: hub-state gate (#1484) ─────────────────────────────────────────────
// The shared main checkout (the hub) must stay on `main` and clean. When it is
// off-main or dirty, the guard BLOCKS all git ops except the sanctioned
// recovery allowlist (Slice B): checkout main/master, pull --ff-only, fetch,
// status, log, worktree add/list/prune/remove, push origin <checked-out-branch>
// (WIP preservation — the stranded branch's commits must not silently die),
// and the escape-marker touch. Read-only ops stay allowed. Everything else
// (commit, push of any OTHER branch, checkout -b, merge/rebase/reset/clean,
// write/edit in the hub) is blocked — even under the TTL marker (D3: only the
// env flag AGENT_ALLOW_MAIN_EDITS=1 is a full bypass).
// Pure JS so test.mjs exercises the SAME rules index.ts applies.

/** Verbs that can mutate repo/remote state and are therefore NOT read-only in
 * a disordered hub without argument guards (handled in isHubRecoveryInvocation). */
const HUB_GUARDED_VERBS = new Set([
  "branch", "tag", "stash", "submodule", "symbolic-ref", "remote", "worktree",
]);

/** Read-only verbs — safe to run in a disordered hub (no state mutation). */
const HUB_READONLY_VERBS = new Set([
  "status", "log", "diff", "show", "show-ref", "blame", "remote", "rev-parse",
  "rev-list", "ls-files", "ls-tree", "ls-remote", "grep", "shortlog",
  "describe", "name-rev", "cat-file", "for-each-ref", "help", "version",
  "merge-base", "merge-tree", "merge-file", "merge-index", "merge-msg",
  "merge-one-file", "mergetool", "check-ref-format", "var", "hash-object",
  "count-objects", "verify-pack", "verify-commit", "verify-tag", "config",
  "reflog", "whatchanged", "cherry", "fsck",
]);

/** Mutating git verbs with NO sanctioned recovery form — always blocked. */
const HUB_MUTATING_VERBS = new Set([
  "commit", "add", "merge", "rebase", "reset", "clean", "restore", "rm",
  "mv", "cherry-pick", "revert", "am", "apply", "update-ref",
  "update-index", "checkout-index", "gc", "prune", "repack", "notes",
  "replace", "filter-branch", "format-patch", "bundle", "send-email",
  "checkout", "switch", "pull", "push", "fetch",
]);

/**
 * Classify ONE git invocation (verb + args) against the hub-recovery
 * allowlist. Returns:
 *   "recovery" — a sanctioned recovery op (checkout main, pull --ff-only,
 *                fetch, status, log, worktree ops, push of the checked-out
 *                branch).
 *   "readonly" — a harmless read (diff/show/blame/...).
 *   "block"    — a mutation outside the allowlist (commit, checkout -b,
 *                foreign push, merge, reset, clean, ...).
 * @param {string} verb
 * @param {string[]} args
 * @param {string|null} currentBranch — branch checked out in the hub (for the
 *   push carve-out; null = detached → foreign pushes are unknowable → block).
 */
export function isHubRecoveryInvocation(verb, args, currentBranch) {
  const a = args || [];
  const pos = a.filter((x) => !x.startsWith("-"));
  const flag = (f) => a.includes(f);
  switch (verb) {
    case "checkout":
    case "switch":
      // ONLY `checkout main|master` (recovery). Path-restore (--), discard-all
      // (.), previous-branch (-), create/force/orphan/detach forms → block.
      if (a.includes("--")) return "block";
      if (["-b", "-B", "-c", "-f", "--force", "--orphan", "--detach"].some(flag)) return "block";
      if (pos.length !== 1 || pos[0] === "." || pos[0] === "-") return "block";
      return pos[0] === "main" || pos[0] === "master" ? "recovery" : "block";
    case "pull":
      // Plain pull may merge — only --ff-only is lossless recovery.
      return flag("--ff-only") ? "recovery" : "block";
    case "fetch":
      return "recovery";
    case "status":
    case "log":
      return "recovery";
    case "worktree": {
      // Worktree ops never mutate the hub's own branch/index — all subcommands
      // are sanctioned recovery tooling.
      const sub = pos[0];
      if (!sub) return "recovery";
      return ["add", "list", "prune", "remove"].includes(sub) ? "recovery" : "block";
    }
    case "push": {
      // WIP preservation: push of the CHECKED-OUT branch to origin is the one
      // allowed push (the stranded lane's 38 commits must not silently die).
      // Force/delete/mirror/tags and foreign targets → block.
      if (flag("-f") || flag("--force") || flag("--delete") ||
          a.includes("--mirror") || a.includes("--tags")) return "block";
      if (!currentBranch) return "block"; // detached hub — push target unknowable
      const refspecs = pos.length > 1 ? pos.slice(1) : [];
      const dsts = refspecs.length
        ? refspecs.map((r) => _refspecDst(r)).filter((x) => x !== null && x !== undefined)
        : [currentBranch]; // bare push → push.default=simple → current branch
      if (dsts.length === 0) return "block";
      return dsts.every((d) => d === currentBranch) ? "recovery" : "block";
    }
    default:
      break;
  }
  if (HUB_MUTATING_VERBS.has(verb)) return "block";
  if (HUB_GUARDED_VERBS.has(verb)) {
    // Verbs with a read-only form and a mutating form — gate on the args.
    if (verb === "branch") {
      // `git branch` bare / -a / -r / -vv / --show-current = list (read-only);
      // create (`git branch foo`), delete/rename/force → block.
      if (["-d", "-D", "-m", "-M", "-f", "--force"].some(flag)) return "block";
      // #337: `--show-current` is a STANDALONE read-only mode — git ignores
      // trailing operands (verified: `git branch --show-current echo === ...`
      // prints the branch and exits 0), so a wrapper suffix must not flip a
      // list into a branch-create.
      if (flag("--show-current")) return "readonly";
      return pos.length > 0 ? "block" : "readonly";
    }
    if (verb === "tag") return pos.length > 0 ? "block" : "readonly"; // create/delete
    if (verb === "stash") {
      const sub = pos[0];
      if (!sub) return "block"; // bare `git stash` = push
      return sub === "list" || sub === "show" ? "readonly" : "block";
    }
    if (verb === "submodule") {
      const sub = pos[0];
      if (!sub) return "block";
      return ["status", "foreach", "summary"].includes(sub) ? "readonly" : "block";
    }
    if (verb === "symbolic-ref") {
      return pos[0] === "HEAD" ? "block" : "readonly"; // HEAD = branch-state change
    }
    if (verb === "remote") {
      const sub = pos[0];
      if (!sub || ["-v", "show", "get-url", "list"].includes(sub)) return "readonly";
      return "block"; // add/remove/set-url/prune mutate remote config/refs
    }
    return "block"; // worktree handled above; unreachable guard
  }
  if (HUB_READONLY_VERBS.has(verb)) return "readonly";
  return "block"; // fail-closed: unknown git verb is not sanctioned recovery
}

/**
 * Evaluate a WHOLE shell command against the hub-recovery allowlist.
 * Every git invocation in a compound command is gated (`git pull && git
 * commit` → block on the commit). Returns:
 *   { verdict: "non-git" }             — no git invocation (not gated)
 *   { verdict: "allowed" }             — all invocations read-only
 *   { verdict: "recovery" }            — at least one sanctioned recovery op,
 *                                        none blocked
 *   { verdict: "block", reason }       — a non-sanctioned mutation present
 * @param {string} command
 * @param {string|null} currentBranch — hub's checked-out branch (push carve-out)
 */
export function evaluateHubGate(command, currentBranch) {
  const invocations = allGitInvocations(command);
  if (invocations.length === 0) return { verdict: "non-git" };
  let sawRecovery = false;
  for (const inv of invocations) {
    if (!inv.verb) continue;
    const v = isHubRecoveryInvocation(inv.verb, inv.args, currentBranch);
    if (v === "block") {
      return {
        verdict: "block",
        reason: [
          `⛔ Hub-state gate (M4): the shared main checkout is OFF-MAIN or DIRTY (#1484).`,
          `   Blocked: \`git ${inv.verb} ${inv.args.join(" ")}\``,
          `   Sanctioned recovery ops only: git checkout main|master, git pull`,
          `   --ff-only, git fetch, git status, git log, git worktree`,
          `   add|list|prune, git push origin <checked-out-branch> (WIP), marker touch.`,
          `   → Terminal recovery: cd <repo> && git checkout main && git pull --ff-only`,
          `   → Feature work: bash scripts/checkout-hygiene/hub-worktree.sh <branch>`,
        ].join("\n"),
      };
    }
    if (v === "recovery") sawRecovery = true;
  }
  return { verdict: sawRecovery ? "recovery" : "allowed" };
}

/** #347 — evaluateHubGate with PER-INVOCATION target resolution. Classify
 * first (recovery/readonly → zero resolution cost — sanctioned regardless of
 * target); on a `block` verdict, resolve the invocation's effective target and
 * EXEMPT it when it is an isolated worktree (worktree-list membership + cwd
 * containment). Anything else (hub, foreign, unresolvable) keeps today's
 * block. Same verdict vocabulary as evaluateHubGate (non-git/allowed/recovery/
 * block); evaluateHubGate stays contract-identical for existing callers/tests.
 * @param {string} command
 * @param {string|null} currentBranch — hub's checked-out branch (push carve-out)
 * @param {string} [sessionCwd] — session root; the worktree MAP is derived here
 *   (M4 only fires when session cwd IS the hub).
 */
export function evaluateHubGateWithTargets(command, currentBranch, sessionCwd = process.cwd()) {
  const invocations = allGitInvocations(command);
  if (invocations.length === 0) return { verdict: "non-git" };
  let sawRecovery = false;
  for (const inv of invocations) {
    if (!inv.verb) continue;
    const v = isHubRecoveryInvocation(inv.verb, inv.args, currentBranch);
    if (v === "block") {
      const target = resolveInvocationTarget(inv, sessionCwd, sessionCwd);
      if (target && target.isWorktree) continue; // #347: isolated worktree target
      return {
        verdict: "block",
        reason: [
          `⛔ Hub-state gate (M4): the shared main checkout is OFF-MAIN or DIRTY (#1484).`,
          `   Blocked: \`git ${inv.verb} ${inv.args.join(" ")}\``,
          `   Sanctioned recovery ops only: git checkout main|master, git pull`,
          `   --ff-only, git fetch, git status, git log, git worktree`,
          `   add|list|prune, git push origin <checked-out-branch> (WIP), marker touch.`,
          `   → Terminal recovery: cd <repo> && git checkout main && git pull --ff-only`,
          `   → Feature work: bash scripts/checkout-hygiene/hub-worktree.sh <branch>`,
        ].join("\n"),
      };
    }
    if (v === "recovery") sawRecovery = true;
  }
  return { verdict: sawRecovery ? "recovery" : "allowed" };
}

/** #347 — the execution cwd of a shell command: the cdChain state AT the
 * script-path token (interpreter/script position, not end-of-command), with
 * the SAME subshell/pipe-scoped chain semantics as allGitInvocations. Returns
 * null when no script token is found or a cd is unresolvable (caller falls
 * back to the session cwd — true bash semantics when a cd fails).
 * @param {string} command
 * @param {string} [sessionCwd]
 * @returns {string|null}
 */
export function commandExecutionCwd(command, sessionCwd = process.cwd()) {
  const tokens = _tokenize(command);
  const stack = [{ chain: [], vars: {}, baseLen: 0, pipeC0: null, pipeActive: false }];
  const frame = () => stack[stack.length - 1];
  const boundary = () => {
    const f = frame();
    if (f.pipeActive && f.pipeC0) f.chain.splice(0, f.chain.length, ...f.pipeC0);
    f.pipeActive = false;
    f.pipeC0 = null;
    f.vars = {};
    f.baseLen = f.chain.length;
  };
  for (let i = 0; i < tokens.length; i++) {
    const t = tokens[i];
    if (/^[A-Za-z_][A-Za-z0-9_]*=/.test(t)) {
      const eq = t.indexOf("=");
      frame().vars[t.slice(0, eq)] = t.slice(eq + 1);
      continue;
    }
    if (t === "cd") {
      const target = tokens[i + 1] ?? null;
      i++;
      const f = frame();
      const expanded = target === null ? null : _expandCdVars(target, f.vars);
      f.chain.push(expanded);
      continue;
    }
    if (t === "(") {
      const f = frame();
      if (f.pipeActive && f.pipeC0) f.chain.splice(0, f.chain.length, ...f.pipeC0);
      stack.push({ chain: [...f.chain], vars: {}, baseLen: f.chain.length, pipeC0: null, pipeActive: false });
      continue;
    }
    if (t === ")") { if (stack.length > 1) stack.pop(); continue; }
    if (t === "|") {
      const f = frame();
      if (!f.pipeActive) {
        f.pipeC0 = f.chain.slice(0, f.baseLen);
        f.pipeActive = true;
      }
      f.chain.splice(0, f.chain.length, ...(f.pipeC0 || []));
      f.vars = {};
      f.baseLen = f.chain.length;
      continue;
    }
    if (t === "&&" || t === "||" || t === ";") { boundary(); continue; }
    // script-path token: return the chain state AT this point (cycle-4 P2).
    if (SHELL_INTERPRETERS.has(t)) {
      const next = tokens[i + 1];
      if (next && !next.startsWith("-")) return _resolveCdChain(frame().chain, sessionCwd);
      continue; // `-c` inline or flag — not a script file (gated by the normal classifier)
    }
    if (t === ".") {
      const next = tokens[i + 1];
      if (next && !next.startsWith("-")) return _resolveCdChain(frame().chain, sessionCwd);
      continue;
    }
    if (/^\.{0,2}\//.test(t)) return _resolveCdChain(frame().chain, sessionCwd); // ./x.sh direct execution
  }
  return null; // no script file executed
}

/** #347 — resolve the git TOP-LEVEL of a write/edit target path (walking up to
 * the nearest existing ancestor dir so writes into not-yet-created dirs still
 * resolve). Returns the resolve-normalized toplevel (mirroring _mainTopLevel)
 * or null on git/fs failure (caller falls through — downstream warns-not-blocks).
 * @param {string} targetPath — write/edit tool path (relative to cwd)
 * @param {string} [cwd]
 * @returns {string|null}
 */
export function resolveTargetTopLevel(targetPath, cwd = process.cwd()) {
  try {
    let dir = dirname(resolve(cwd, targetPath ?? ""));
    while (!existsSync(dir)) {
      const parent = dirname(dir);
      if (parent === dir) break;
      dir = parent;
    }
    const top = execSync("git rev-parse --show-toplevel", {
      encoding: "utf-8", cwd: dir, timeout: 5000, stdio: ["ignore", "pipe", "ignore"],
    }).trim();
    return top ? resolve(top) : null;
  } catch {
    return null;
  }
}

/**
 * Hub disorder of a repo checkout: "off_main" | "dirty" | "both" | null.
 * The hub's only legal state is main/master + empty porcelain — untracked
 * files count as dirty (`status --porcelain` includes them).
 * Resolves the MAIN checkout via git-common-dir semantics (getMainCheckoutBranch
 * pattern) so it works from a worktree too (D5) — pass the session cwd.
 * @param {string} cwd
 * @param {{ skipWorktree?: boolean, skipInfra?: boolean, env?: object }} [opts]
 * @returns {{ disorder: string|null, branch: string|null }}
 */
export function readHubDisorder(cwd, { skipWorktree = true, skipInfra = true, env } = {}) {
  try {
    if (skipWorktree && isWorktreeCwd(cwd)) return { disorder: null, branch: null };
    if (skipInfra && isAgentInfraRepo(cwd, env)) return { disorder: null, branch: null }; // #99
    const gitDir = execSync("git rev-parse --git-dir", {
      encoding: "utf-8", cwd, timeout: 5000,
    }).trim();
    if (gitDir.includes("/worktrees/") || gitDir.endsWith("/worktrees")) {
      return { disorder: null, branch: null };
    }
    const branch = execSync("git branch --show-current", {
      encoding: "utf-8", cwd, timeout: 5000,
    }).trim() || null;
    const porcelain = execSync("git status --porcelain", {
      encoding: "utf-8", cwd, timeout: 5000,
    }).trim();
    const onMain = branch === "main" || branch === "master";
    const dirty = porcelain.length > 0;
    if (onMain && !dirty) return { disorder: null, branch };
    const disorder = !onMain && dirty ? "both" : onMain ? "dirty" : "off_main";
    return { disorder, branch };
  } catch {
    return { disorder: null, branch: null }; // degrade — never false-block on git errors
  }
}

// ── Script backdoor closure (#1484, Slice E) ────────────────────────────────
// The documented escape (`write /tmp/x.sh` + `bash /tmp/x.sh`) executes
// arbitrary git unblocked. Closure: when the session cwd IS the hub main
// checkout, shell-script execution whose content performs a non-sanctioned git
// mutation is blocked (a script's git ops are gated EXACTLY like direct git
// ops — recovery scripts like hub-worktree.sh keep working).

const SHELL_INTERPRETERS = new Set(["bash", "sh", "zsh", "dash", "ksh", "source"]);

/**
 * Extract the script path from a shell command, or null when the command does
 * not execute a script FILE (inline `-c` strings are the caller's command
 * itself and are gated by the normal classifier). Only LEADING positions count
 * (env-prefix / cd / separators allowed) so `git add ./foo` never false-matches.
 * @param {string} command
 * @returns {string|null}
 */
export function extractScriptPath(command) {
  const tokens = _tokenize(command);
  let i = 0;
  while (i < tokens.length) {
    const t = tokens[i];
    if (/^[A-Za-z_][A-Za-z0-9_]*=/.test(t)) { i++; continue; }   // env prefix
    if (t === "cd") { i += 2; continue; }                         // cd prefix
    if (t === "&&" || t === ";" || t === "||") { i++; continue; } // separators
    if (t === "(" || t === ")") { i++; continue; }                 // #347: subshell wrappers
    break;
  }
  if (i >= tokens.length) return null;
  const t = tokens[i];
  if (SHELL_INTERPRETERS.has(t)) {
    const next = tokens[i + 1];
    if (!next || next.startsWith("-")) return null; // flags / -c inline
    return next;
  }
  if (t === ".") { // `. script`
    const next = tokens[i + 1];
    return next && !next.startsWith("-") ? next : null;
  }
  if (/^\.{0,2}\//.test(t)) return t; // ./x.sh or /abs/x.sh direct execution
  return null;
}

/**
 * Gate a script FILE's git content against the hub-recovery allowlist.
 * "block" = the script performs a non-sanctioned git mutation (backdoor
 * pattern); "allow" = no git, or all git ops are sanctioned/read-only.
 * Unreadable/missing file → "allow" (the file doesn't exist yet — nothing to
 * execute; a later call re-checks after the write).
 * @param {string} path
 * @param {string|null} currentBranch
 * @returns {"allow"|"block"}
 */
export function scriptGitVerdict(path, currentBranch, executionCwd = process.cwd(), sessionCwd = process.cwd()) {
  let content;
  try {
    content = readFileSync(path, "utf-8");
  } catch {
    return "allow";
  }
  const invocations = allGitInvocations(_stripShellComments(content));
  for (const inv of invocations) {
    if (!inv.verb) continue;
    if (isHubRecoveryInvocation(inv.verb, inv.args, currentBranch) === "block") {
      // #347: per-invocation target exemption — the worktree map comes from the
      // SESSION repo (the guard's hub; explicit param for testability),
      // executionCwd is the script's cd-chain base. Worktree-targeted script
      // content is isolated; content that targets the hub (or a foreign /
      // unresolvable target) still blocks.
      const target = resolveInvocationTarget(inv, sessionCwd, executionCwd);
      if (target && target.isWorktree) continue;
      return "block";
    }
  }
  return "allow";
}

/** Strip shell comments (# … to EOL) quote-aware — a `# git commit` remark in a
 * script's prose must not gate as a real invocation, and an inline ` # reason`
 * on a recovery line must not poison its arg list. */
function _stripShellComments(content) {
  return String(content).split("\n").map((line) => {
    let inS = false, inD = false;
    for (let i = 0; i < line.length; i++) {
      const ch = line[i];
      if (ch === "'" && !inD) { inS = !inS; continue; }
      if (ch === '"' && !inS) { inD = !inD; continue; }
      if (ch === "#" && !inS && !inD) return line.slice(0, i);
    }
    return line;
  }).join("\n");
}

// Expand a path token: strip surrounding quotes, expand `~` / `$HOME`
// (incl. ${HOME} and quoted variants) BEFORE resolve + exact-match.
function _expandMarkerToken(token, home) {
  let t = String(token).trim();
  if (
    (t.startsWith('"') && t.endsWith('"') && t.length >= 2) ||
    (t.startsWith("'") && t.endsWith("'") && t.length >= 2)
  ) {
    t = t.slice(1, -1);
  }
  if (t === "~") t = home;
  else if (t.startsWith("~/")) t = join(home, t.slice(2));
  t = t.replace(/\$\{HOME\}|\$HOME\b/g, home);
  return t;
}
