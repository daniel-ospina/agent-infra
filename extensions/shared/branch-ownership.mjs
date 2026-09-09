// branch-ownership.mjs — per-session branch-ownership sentinel for the SHARED
// main checkout (#265). Pure JS so plain-node tests can import the SAME rules.
//
// The shared checkout is a multi-actor resource: parallel pi sessions share ONE
// working tree, and branch state mutates under live sessions (auto-sync's
// session_start force-switch, unguarded `git checkout` from any session). This
// module records a per-session baseline {repoKey, branch, head, original} and
// provides pure decision functions for the guard's M1 (warn on branch
// deviation), M2 (block commit/push off-baseline), M3 (gate branch-state
// mutations), and the ownership allowance (own-branch hygiene ops in
// agent-infra main). `original` = the branch recorded at session_start BEFORE
// any create-new re-baseline — immutable; M3's #376 ceremony return-to-main
// carve-out lets a session switch back to it.
//
// Deliberately self-contained: it must NOT import classify-git.mjs (keeps the
// destructive-git classifier dependency-free for jiti loading, per the #99
// degradation contract). The small amount of command tokenization duplicated
// here (cd/-C/--git-dir extraction) is cross-checked against classify-git's
// skimmer by test-branch-ownership.mjs (T2 cross-consistency matrix).

import { execFileSync, execSync } from "node:child_process";
import { resolve, join } from "node:path";
import {
  mkdirSync, writeFileSync, readFileSync, rmSync, openSync, writeSync, closeSync,
  realpathSync, existsSync,
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
 * Does a LOCAL branch ref exist in the repo at `cwd`? Tri-state probe used by
 * the M3 rename gate (#598): git's branch refs are repo-global (shared across
 * worktrees of the same common dir), so probing from any worktree cwd of the
 * resolved repo answers what `git branch -M <src> <dst>` would overwrite.
 * Returns true (exists) / false (cleanly absent) / null (git failure —
 * unknown; callers must map null fail-CLOSED). argv-based (execFileSync) so a
 * refname can never reach a shell. When `gitDir` is given (the mutation's
 * RESOLVED admin dir), the probe runs with `--git-dir` so it interrogates the
 * exact repo git will write — a `--git-dir=<other>` mutation must never be
 * checked against the cwd repo's refs (round-1 reviewer P2).
 * `git rev-parse --verify --quiet` exits 0 when the ref resolves; when it
 * exits 1 the ref does NOT resolve — that covers both a cleanly ABSENT ref
 * AND a broken-present loose ref (a DANGLING symref, or loose content that is
 * not a valid object name — both make rev-parse exit 1 while git branch -M
 * would still clobber the ref file rc 0). NOTE: a loose ref holding a VALID
 * sha whose object is missing still RESOLVES (rc 0 → EXISTS via the primary
 * probe — the safe direction), so only the dangling-symref / invalid-content
 * forms reach the rc-1 fallback. The rc-1 fallback checks the loose-ref file
 * (git rev-parse --git-path refs/heads/<name> + existsSync) so a
 * broken-but-present foreign ref is treated as EXISTS (block), never as a
 * free name (round-2 reviewer P2 — pre-fallback a dangling symref dst read
 * as free and the carve-out let a real rc-0 clobber through). Packed refs
 * resolve rc 0 and never reach the fallback. Any other exit (bad repo rc 128
 * etc.) stays null — unknown, never a clean not-found.
 * @param {string} cwd
 * @param {string} name local branch name (no refs/heads/ prefix)
 * @param {string} [gitDir] resolved git dir override (--git-dir)
 * @returns {boolean|null}
 */
export function localBranchExists(cwd, name, gitDir) {
  if (!cwd || typeof name !== "string" || name.length === 0) return null;
  const prefix = gitDir ? [`--git-dir=${gitDir}`] : [];
  const probe = (args) => {
    try {
      execFileSync("git", [...prefix, ...args], {
        encoding: "utf-8", cwd, timeout: 5000, stdio: "ignore",
      });
      return true;
    } catch (e) {
      return e && e.status;
    }
  };
  const rc = probe(["rev-parse", "--verify", "--quiet", `refs/heads/${name}`]);
  if (rc === true) return true;
  if (rc !== 1) return null; // any other exit = unknown (callers map null fail-CLOSED)
  // rc 1: the ref does not RESOLVE. Distinguish a cleanly ABSENT ref from a
  // broken-but-present one (dangling symref, or loose content that is not a
  // valid object name — a valid-sha missing-object ref resolves rc 0 above)
  // via the loose-ref file, which exists for every loose ref whether or not it
  // resolves (--git-path only maps the path; packed refs resolved rc 0 above
  // and never reach here).
  try {
    const refPath = execFileSync("git", [...prefix, "rev-parse", "--git-path", `refs/heads/${name}`], {
      encoding: "utf-8", cwd, timeout: 5000,
    }).trim();
    if (!refPath) return null;
    // --git-path prints cwd-relative when the gitdir is implied; resolve
    // against the probe cwd (absolute gitdirs print absolute paths — resolve
    // passes them through unchanged).
    return existsSync(resolve(cwd, refPath));
  } catch {
    return null; // --git-path failed → unknown (fail-closed at callers)
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

// Shell redirect-operator token shapes the SHARED tokenizer can emit as a
// standalone token (space-separated / fd-prefixed; `&` always splits, so
// `2>&1` → ["2>","1"] and `&> f` → [">","f"] never appear glued): bare `>`
// `>>` `<` `<<`, here-string `<<<`, and digit-prefixed forms `2>` `2>>` …
// (mirror of classify-git's redirect regexes modulo the shared `&` boundary).
// A glued `>out` / `2>err` / `>>git` token is NOT an operator here — its
// operand is glued in and can never be a standalone `git` phantom.
function isShellRedirectOp(t) {
  return /^(?:[0-9]+)?[<>]{1,3}$/.test(t);
}

// Interpreter words classify-git's _walkShell recognizes (classify-git.mjs
// SHELL_INTERPRETERS — duplicated deliberately; branch-ownership must stay
// import-free of classify-git per the #99 degradation contract).
const SHELL_INTERP_WORDS = new Set(["bash", "sh", "zsh", "dash", "ksh", "source"]);

/**
 * Extract the git invocation from a command string:
 *   { cdCwd, gitDirHint, cHints, verb, rest } | null
 * - cdCwd: LAST cd target (sequential chained cd's resolved by caller against
 *   sessionCwd — bash semantics: `cd a && cd b` ends in b relative to a).
 * - gitDirHint: from --git-dir[=]<path> or a leading GIT_DIR=<path> env prefix.
 * - cHints: every `-C <path>` in order (multi -C chains resolve sequentially).
 * - verb/rest: tokens from the first non-flag token after `git` onward.
 * @param {string} command
 * @param {string|null} [preferVerb]
 * @param {number} [preferVerbOccurrence] 0-based ordinal of the same-verb
 *   invocation to return (#596 round-2): when preferVerb matches multiple
 *   invocations, the caller may select a LATER one — the M3-relevant
 *   branch-state invocation can be a later compound segment (benign leads are
 *   skipped by the classifier) and repo hints (-C/--git-dir/cd) must be
 *   attributed to THAT invocation, not the first same-verb one. Default 0 = the
 *   first match (every pre-#596 caller).
 */
export function extractGitInvocation(command, preferVerb = null, preferVerbOccurrence = 0) {
  const tokens = tokenize(command);
  let cdChain = [];
  let i = 0;
  // Pre-scan: collect the cd-chain as we walk (cd persists across invocations
  // in bash). When preferVerb is set, we scan ALL invocations and return the
  // one whose verb matches (review P2, cycle 3: `git -C <wt> status && git
  // checkout main` — the branch-state gate must resolve the repo for the
  // CHECKOUT, whose -C/hints differ from the first invocation). #596
  // round-2: the preferVerbOccurrence-th same-verb match wins (see the
  // signature JSDoc); earlier same-verb matches are skipped but their cd
  // effects still accumulate (bash cd persists).
  // #337: also collect same-command `VAR=value` assignments so a `cd $WT`
  // (or `cd "${WT}"`) can be resolved against them by resolveEffectiveRepo.
  let envGitDir = null;
  const vars = {};
  let verbMatches = 0;
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
    // #596 round-4 (F1 — phantom-token ordinal asymmetry): a shell REDIRECT
    // operator + operand never starts a command (classify-git's _walkShell
    // skips both: `echo x > git branch side` runs echo, never `git branch`).
    // When the operand is a literal `git`, counting it here as a branch-state
    // invocation shifts the stateVerbOccurrence ordinal OFF the real mutation
    // (a phantom lead ahead of a `-C <wt>` benign segment makes occurrence 1
    // land on the WORKTREE invocation → the main `-Mq` is worktree-exempt —
    // the round-4 reviewer F1 bypass). Operand = exactly the next token; the
    // token after it stays the command word (`> /dev/null git commit`). The
    // shared tokenizer never emits an fd-redirect as ONE token (`2>&1` →
    // ["2>", "1"]; `&` is always a boundary) so op + operand is always 2.
    if (isShellRedirectOp(t)) { i += 2; continue; }
    // Same F1 class via the interpreter-inline shape: classify-git walks a
    // `bash -c <payload>` by treating the payload as ONE opaque nested command
    // whose git words are cmdVisible:false (round-3) — they must never shift
    // the ordinal. An UNQUOTED `sh -c git branch side` payload is a literal
    // `git` token here; consume interpreter + flags + the `-c`/`--command`
    // payload (exactly one token, per bash -c semantics) and resume AFTER it
    // (payload positionals stay walked by BOTH layers → parity preserved).
    // Scope is deliberately the `-c` payload ONLY, never the interpreter's
    // script-FILE path: in this boundary-less token stream `bash evil.sh ;
    // git commit` and `git status bash ; git commit` are indistinguishable
    // from `bash evil.sh git …` (the `;` is dropped), and classify-git does
    // NOT fire interpreter handling inside a preceding git invocation's args
    // (round-4 probes C7–C9) — consuming a non-`-c` first token as a script
    // path could eat a real later `git` (round-4 reviewer P1 follow-up: it
    // shifted the ordinal onto a trailing `-C <wt>` invocation and
    // worktree-exempted a MAIN mutation). The script-file spelling
    // (`bash git -C <wt> branch …`) is closed at the index.ts M3/M2 repo
    // resolution instead: classify-git exposes the SELECTED mutation's OWN
    // boundary-aware hints (stateHints / commitHints) and the gates resolve
    // from those — never from this replay's occurrence arithmetic.
    if (SHELL_INTERP_WORDS.has(t)) {
      let j = i + 1;
      let resume = null;
      while (j < tokens.length) {
        const n = tokens[j];
        if (isShellRedirectOp(n)) { j += 2; continue; } // `bash < /dev/null -c '…'` (round-18 mirror)
        if (n === "-c" || n === "--command") {
          let m = j + 1;
          while (m < tokens.length && tokens[m].startsWith("-")) m++; // `bash -c -x '…'` (round-5 mirror)
          resume = m < tokens.length ? m + 1 : tokens.length; // payload consumed — resume AFTER it
          break;
        }
        if (!n.startsWith("-")) break; // script path / plain word — do NOT consume (see above)
        j++;
        if (n === "--rcfile" || n === "--init-file" || n === "-O" || n === "-o") j++; // flag operands (round-20 mirror)
      }
      i = resume ?? i + 1; // no auto-increment — every branch advances i explicitly
      continue;
    }
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
    if (preferVerb && verbMatches < preferVerbOccurrence) { verbMatches++; i = j; continue; } // earlier same-verb match — skip (cd effects already accumulated)
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
 * @param {string|null} [preferVerb]
 * @param {number} [preferVerbOccurrence] 0-based ordinal among same-verb
 *   invocations (#596 round-2: when the M3-relevant branch-state invocation is
 *   a LATER compound segment — benign leads are skipped — the repo hints must
 *   come from THAT invocation, not the first same-verb one; a `-C <wt>` lead
 *   would wrongly worktree-exempt a main mutation and vice versa).
 */
export function resolveEffectiveRepo(command, sessionCwd, preferVerb = null, preferVerbOccurrence = 0) {
  const inv = extractGitInvocation(command, preferVerb, preferVerbOccurrence);
  if (!inv) return null;
  return resolveRepoFromInv(inv, sessionCwd);
}

/**
 * Resolve the effective repo from a git invocation's OWN resolution hints
 * ({ cdChain, cHints, gitDirHint, vars }) — no command re-tokenization.
 * #596 round-4 (reviewer follow-up): index.ts resolves the M3/M2 repo from
 * the classifier's boundary-aware walk of the SELECTED mutation/commit
 * invocation (exposed as stateHints / commitHints / pushHints by
 * classifyGitCommandDetailed) instead of replaying the occurrence ordinal
 * through branch-ownership's boundary-less tokenizer. Replay
 * mis-attributions (interpreter-inline / script-file / redirect-operand
 * phantoms, or an interpreter word used as a git ARG whose next token the
 * extractor consumes) landed the ordinal on a DIFFERENT invocation whose -C
 * hints wrongly worktree-exempted a mutation running at the shell cwd
 * (round-4 reviewer P1). classify-git's walk is boundary-aware, so its
 * per-invocation hints are the reference truth for the exemption decision.
 * Same git-faithful resolution as resolveEffectiveRepo's tail:
 *   (1) cd-chain resolves to a final cwd (sequential, last-wins);
 *   (2) each -C <path> resolves relative to the current cwd, in order;
 *   (3) gitDir = resolved --git-dir hint / GIT_DIR env (resolved against the
 *       FINAL cwd), else <finalCwd>/.git;
 *   (4) repoKey = git-common-dir of the RESOLVED gitDir; isWorktree = resolved
 *       gitDir contains "/worktrees/" (NEVER cwd-derived);
 *   (5) currentBranch read FROM the resolved repo.
 * Returns null when git fails (caller applies fail-closed policy).
 * @param {{cdChain?: Array<string|null>, cHints?: string[], gitDirHint?: string|null, vars?: object}|null} inv
 * @param {string} [sessionCwd]
 */
export function resolveRepoFromInv(inv, sessionCwd = process.cwd()) {
  if (!inv) return null;
  let cwd = sessionCwd ? resolve(sessionCwd) : process.cwd();
  for (const cd of inv.cdChain || []) {
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
  for (const c of inv.cHints || []) {
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
    // #591 (review fold-in): BARE repos have no worktree, so git's symbolic
    // HEAD branch is NOT checked out anywhere and `git branch -f <that>`
    // SUCCEEDS rc 0 — the decideM3 benign-force carve-out (premise: git
    // refuses to touch the checked-out branch) must not fire there.
    isBare: _isBareGitDir(state.gitDir),
    currentBranch: state.branch,
  };
}

/** Is `<gitDir>` the admin dir of a BARE repository (no worktree can exist)?
 * Probe: `git rev-parse --is-bare-repository` with the resolved admin dir.
 * Failure → true (conservative: the benign-force carve-out needs certainty
 * that a worktree protects the branch). */
function _isBareGitDir(gitDir) {
  try {
    return execSync(
      `git --git-dir="${gitDir}" rev-parse --is-bare-repository`,
      { encoding: "utf-8", timeout: 5000 },
    ).trim() === "true";
  } catch {
    return true;
  }
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

/**
 * #591 (round-3 fold): value-aware single-dash branch-token parse — the
 * EXACT duplicate of classify-git.mjs's _branchToken (cross-pinned; both
 * layers MUST agree or a spelling bypasses the M3 gate). git's parse-options
 * merges NOARG shorts into ONE run scanned left→right; an ARG-VALUE-TAKING
 * short stops the run and consumes the token REST as its attached value.
 * branch's value-takers: `u` (set-upstream-to — REQUIRED value; the #587
 * u-guard excludes ANY u-containing token from delete/force/copy/move
 * wholesale, since those modes conflict with set-upstream rc 129) and `t`
 * (--track, PARSE_OPT_OPTARG — a NON-TERMINAL t consumes the rest as its
 * tracking DIRECTIVE; a TERMINAL t is a plain NOARG flag). Value letters
 * never read as mode letters: `-ftdirect` = `-f --track=direct` (a force-
 * CREATE rc 0) — its "direct" must not read as delete/copy; `-Dftdirect` IS a
 * delete (`-D -f --track=direct`, D/f in the run). Returns { run, tValue }
 * or null (non-token / u).
 * @param {string} x
 * @returns {{ run: string, tValue: string|null }|null}
 */
function _branchToken(x) {
  if (typeof x !== "string" || !/^-[A-Za-z]+$/.test(x)) return null;
  const s = x.slice(1);
  let run = "";
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (c === "u") return null; // set-upstream value-taker — mode-conflict rc129 (u-guard parity)
    if (c === "t" && i < s.length - 1) {
      // mid-run t: parse-options OPTARG consumes the token rest as its
      // --track directive value — remaining letters are VALUE, not flags.
      return { run, tValue: s.slice(i + 1) };
    }
    run += c;
  }
  return { run, tValue: null };
}

/**
 * #591 (round-3 fold): pure-force-create token test — EXACT duplicate of
 * classify-git.mjs's isBranchForceCreateTokenNarrow semantics (cross-pinned;
 * branch-ownership must not import classify-git). See the classify-git doc:
 * create-mode NOARG letters {f,v,q,i} with repeatable f, optional TERMINAL t
 * in the run, and a NON-TERMINAL t must consume exactly "direct"/"inherit"
 * (rc-0 force-creates); any other remainder is a parse error rc 129.
 * @param {string} x
 * @returns {boolean}
 */
function _narrowForceCreate(x) {
  if (x === "--force" || x === "--forc") return true;
  const tok = _branchToken(x);
  if (!tok) return false;
  if (tok.tValue !== null && tok.tValue !== "direct" && tok.tValue !== "inherit") {
    return false;
  }
  return /^[qvif]*f[qvif]*t?$/.test(tok.run);
}

/**
 * #592: mode-family reader for a single-dash branch token — EXACT duplicate
 * of classify-git.mjs's _branchMode (cross-pinned; a drift between the layers
 * would set branchState in one and op "other" in the other — silently
 * skipping M3). git's MODE letters are MUTUALLY EXCLUSIVE: d/D (delete),
 * m/M (move/rename), c/C (copy) — any token whose value-aware run mixes ≥2
 * families is a parse-conflict rc-129 no-op (probe-verified: -mc/-cm/-mD/-cD/
 * -dm/-dc/-Dm/-Dc/-DC/-DM/-Md/-Cm ALL usage-error rc 129 and mutate NOTHING),
 * so mixed runs never classify as any mode. The force letter f and the NOARG
 * q/v/i/t compose (they are NOT mode families — `-df x` hard-deletes, `-cf`
 * is a force-copy, #587/#591 probes). Case = FORCE within a family: uppercase
 * M ≡ --move --force (`-M` clobbers an existing dst rc 0 where soft `-m`
 * refuses rc 128), C ≡ --copy --force (probe-verified).
 * @returns {{family: "delete"|"move"|"copy", force: boolean}|null}
 */
function _branchMode(x) {
  const tok = _branchToken(x);
  if (!tok) return null;
  const run = tok.run;
  const hasD = /[dD]/.test(run), hasM = /[mM]/.test(run), hasC = /[cC]/.test(run);
  const families = (hasD ? 1 : 0) + (hasM ? 1 : 0) + (hasC ? 1 : 0);
  if (families !== 1) return null; // no mode / mixed-mode rc-129 no-op
  if (hasD) return { family: "delete", force: /D/.test(run) };
  if (hasM) return { family: "move", force: /M/.test(run) };
  return { family: "copy", force: /C/.test(run) };
}

/**
 * #592: copy-family state — EXACT duplicate of classify-git.mjs's
 * _branchCopyState (cross-pinned; a drift between the layers would set
 * branchState in one and op "other" in the other — silently skipping M3).
 * copyMode = a token whose
 * value-aware run is the COPY family (mixed-mode runs excluded above) OR the
 * git-valid long form/abbreviation `--copy`/`--cop` (--co is ambiguous with
 * --column/--contains/--color, rc 129 → excluded; --copfoo unknown-option rc
 * 129 → excluded — git-valid spellings only, #591 --forc/--forcfoo parity).
 * forceCopy = copyMode AND (an uppercase C in a copy run — git's -C is
 * --copy --force — OR a force spelling anywhere in the args: exact
 * --force/--forc or a u-guarded `f` in a value-aware run). Probe-verified:
 * -C/-Cq/-cf/-fC/-f -c/--force --copy/--force --cop ALL clobber an existing
 * FREE dst rc 0 (the shared-ref mutation M3 gates), while SOFT copy (-c/-cq/
 * --copy, no force) refuses an existing dst rc 128 and only ever creates a
 * NEW ref (git branch <name> parity — allow today).
 * @returns {{copyMode: boolean, forceCopy: boolean}}
 */
function _branchCopyState(args) {
  const mode = (x) => (/^-[A-Za-z]+$/.test(x) ? _branchMode(x) : null);
  const copyMode = args.some((x) => x === "--copy" || x === "--cop") ||
    args.some((x) => mode(x)?.family === "copy");
  if (!copyMode) return { copyMode: false, forceCopy: false };
  const cForce = args.some((x) => mode(x)?.family === "copy" && mode(x).force === true);
  const fForce = args.some((x) => x === "--force" || x === "--forc" ||
    (/^-[A-Za-z]+$/.test(x) && /f/.test((_branchToken(x)?.run) ?? "")));
  return { copyMode: true, forceCopy: cForce || fForce };
}

/**
 * #592 (round-2 review fold-in): branch positional extraction — EXACT
 * duplicate of classify-git.mjs's _branchPositionals (cross-pinned). The
 * naive `args.filter(x => !x.startsWith("-"))` counts an option VALUE consumed
 * from the next argv as a branch-name positional, corrupting dst/from/to
 * extraction for the M3 gate. git's parse-options lets a mutating-mode
 * invocation carry LIST options whose REQUIRED value is consumed from the
 * SEPARATE next argv (probe-verified rc 0 + real ref mutation): `--sort` and
 * `--format` under every UNAMBIGUOUS prefix git accepts (`--so`/`--sor`/
 * `--sort` — --so is minimal: --show-current diverges at --sh, --s is
 * ambiguous with --show-current rc 129; `--form`/`--forma`/`--format` — --fo/
 * --for are ambiguous with --force rc 129). Other branch value-takers never
 * land a value in the branch-name slot of an rc-0 MUTATING invocation: the
 * list-filter options --points-at/--contains/--no-contains/-u/--set-upstream-to
 * and --merged/--no-merged error rc 128/129 (usage) BEFORE mutating in
 * copy/move/delete arms (probe-verified), while --column/--color/--abbrev/--track
 * are OPTARG options that only ever take an ATTACHED `=` value — a following
 * word is a positional in git and here alike (`-C --color always main t2` is
 * "too many branches" rc 128); under `-f` the LIST-printing filters
 * (--points-at/--contains/--merged/...) flip git to rc-0 no-mutation LIST
 * mode, while --sort/--format are ACCEPTED and still force-create rc 0 (hence
 * the swallow modeled above). Attached `--sort=x` never consumes the next
 * argv. A `--` terminator ends
 * flag parsing (everything after is a positional).
 * @param {string[]} args
 * @returns {string[]} the true positional (branch-name) argv slots
 */
function _branchPositionals(args) {
  const pos = [];
  let flagsDone = false;
  for (let i = 0; i < args.length; i++) {
    const x = args[i];
    if (!flagsDone && x === "--") { flagsDone = true; continue; }
    if (!flagsDone && x.startsWith("-")) {
      if (/^--so(?:rt?)?$/.test(x) || /^--form(?:at?)?$/.test(x)) i++; // consumes the next argv as its value
      continue;
    }
    pos.push(x);
  }
  return pos;
}

export function classifyBranchOp(subcmd, args) {
  const a = args || [];
  if (subcmd === "checkout" || subcmd === "switch") {
    if (a.includes("--")) return { op: "other" };          // path-restore form
    const flag = (f) => a.includes(f);
    if (flag("--orphan")) return { op: "orphan" };
    if (flag("-B")) return { op: "force-create", branch: _branchAfter(a, "-B") };
    if (flag("-b") || flag("-c")) return { op: "create-new", branch: _branchAfter(a, flag("-b") ? "-b" : "-c") };
    if (flag("-f") || flag("--force") || flag("--discard-changes")) return { op: "force" }; // --discard-changes is git's force-switch alias (throws away local modifications — second-model gate fold-in)
    if (flag("--detach")) return { op: "detach" };
    if (a.includes("-")) return { op: "switch-existing", target: "-" }; // prev branch
    const pos = a.filter((x) => !x.startsWith("-"));
    if (pos.length === 0) return { op: "other" };
    if (pos[0] === "." || pos[0] === "--") return { op: "other" }; // discard-all
    // #376 security fold-in (review P1): >1 non-flag positional = tree-ish +
    // pathspec WITHOUT `--` — git treats this as a PATH-RESTORE, not a branch
    // switch (`git checkout main .` discards uncommitted tree changes). Must
    // NOT reach the M3 switch-existing carve-out (which would allow it when the
    // target equals the original baseline). Classify "other" → the legacy
    // block:checkout-branch / block:checkout-discard-all verdict still blocks.
    if (pos.length > 1) return { op: "other" }; // path-restore form
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
    // #592: rename/move arm widened from EXACT-token (-m/-M) to git's full
    // spelling surface (the sibling-closure family: #587 delete clusters,
    // #591 force-create clusters). git merges NOARG shorts into ONE token, so
    // the move letter can sit anywhere in a cluster (`-Mq` ≡ `-M -q`, `-mv` ≡
    // `-m -v` — both rename rc 0, probe-verified), and git accepts the
    // documented long form plus its UNAMBIGUOUS prefix abbreviations
    // (`--move`/`--mov`/`--mo`; --m is ambiguous with --merged rc 129). Mode
    // letters WIN over -f (#591), so a move-composed cluster is a rename, not
    // a force-create. 1-positional git semantics: `(-m|-M) [<old>] <new>` — a
    // SINGLE positional renames the CURRENT branch (old omitted → from null →
    // decideM3 substitutes currentBranch for the #265 own-baseline carve-out;
    // two positionals are old new).
    if (a.includes("-m") || a.includes("-M") ||
        a.some((x) => (x === "--move" || x === "--mo" || x === "--mov") ||
          (/^-[A-Za-z]+$/.test(x) && _branchMode(x)?.family === "move"))) {
      const pos = _branchPositionals(a);
      return {
        op: "rename",
        from: pos.length > 1 ? (pos[0] ?? null) : null, // null → rename CURRENT branch
        to: pos.length > 1 ? (pos[1] ?? null) : (pos[0] ?? null),
      };
    }
    // #591 (round-2/3 review fold-ins): classify git-branch invocations by
    // git's OWN mode resolution, not token shape. Two forces interact:
    //   (a) FORCE-CREATE detection is token-level — git merges NOARG shorts
    //       into one cluster (`-fq` ≡ `-f -q`); branch's CREATE-mode NOARG
    //       letters are {f,v,q,i} with f repeatable (`-ff`, `-fi`, `-if`,
    //       `-fqf` … probe rc 0; `-i` alone even creates — only l/a/r force
    //       LIST mode) plus an optional TERMINAL `t` (track — `-ft`/`-fvt` rc
    //       0; a mid-run t consumes the rest: `-tf` rc 129) — and `--force`
    //       accepts its unambiguous prefix abbreviation `--forc`.
    //   (b) MODE letters WIN over -f (probe-verified): d/D = DELETE mode
    //       (`-df x` deletes), c/C = COPY, m/M = MOVE, l/a/r = LIST (`-fl x
    //       main` lists rc 0, no ref moves) — none is a force-create. Deletes
    //       must stay op "other" so they flow to the #587/#543 verdict +
    //       ownership-allowance gate (a pid's post-ceremony local delete of
    //       its OWN merged branch stays allowed; op force would M3-block it).
    if (a.some((x) => /^--d/.test(x) ||
        // #591 (round-3 fold): value-aware flag run (see _branchToken) — a
        // tracking-directive VALUE's letters (`-ftdirect`'s "direct", a real
        // force-CREATE) never read as delete letters; the u-guard is inside
        // _branchToken (null on u).
        (/^-[A-Za-z]+$/.test(x) && /[dD]/.test((_branchToken(x)?.run) ?? "")))) {
      return { op: "other" }; // delete mode → #587/#543 verdict + ownership path
    }
    // #592: COPY family (-c/-C/--copy/--cop) — added whole (pre-#592 the copy
    // family was not branch-state tracked AT ALL: even the exact `-C` fell to
    // op "other" → verdict allow → M3 never entered from the shared main
    // checkout, while `git branch -C src dst` OVERWRITES an existing free dst
    // rc 0 — the same shared-ref mutation M3 gates for `branch -f`). SOFT
    // copy (lowercase c, no force letter) only ever CREATES a NEW ref — an
    // existing dst is refused rc 128 — so it is benign like `git branch
    // <name>` (op "other" → allow; no M3). FORCE copy (uppercase C = git's
    // --copy --force, or any force composition — probe-verified -C/-Cq/-cf/
    // -fC/-f -c/--force --copy all clobber a free dst rc 0) mutates the
    // DESTINATION ref: classified op "force" with branch = the DST (the
    // SECOND positional of `-C src dst`, the FIRST of 1-positional `-C dst`
    // which copies the current branch) — dst == currentBranch is git-REFUSED
    // rc 128 ("cannot force update the branch '…' used by worktree") and dst
    // checked out in a sibling worktree likewise, so the #591 benign-force
    // carve-out (branch === currentBranch) applies unchanged; foreign /
    // non-checked-out overwrite targets hit the M3 default block.
    const { copyMode, forceCopy } = _branchCopyState(a);
    if (copyMode) {
      if (forceCopy) {
        const pos = _branchPositionals(a);
        return { op: "force", branch: (pos[1] ?? pos[0]) ?? null };
      }
      return { op: "other" }; // soft copy — new-ref-only create (git refuses existing dst)
    }
    if (a.some(_narrowForceCreate)) {
      // #592: copy/move compositions never reach here (the rename arm above
      // and the copy arm above intercept every m/M/c/C spelling and the
      // --move/--mo/--mov/--copy/--cop long forms), so a narrow-force token at
      // this point is a PURE force-create whose mutation target is the FIRST
      // positional (the #591 round-2 copyOrMove branch-nulling guard is
      // superseded — the destination-mutation frame now lives in the copy arm,
      // keyed on the real DST so the benign carve-out can never misfire on a
      // current-branch SOURCE).
      const pos = _branchPositionals(a);
      return { op: "force", branch: pos[0] ?? null };
    }
    return { op: "other" }; // create/list/soft-copy/delete/mixed-mode — not the force-create M3 path
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
 *   rename of the session's OWN baseline branch → { reBaseline: <to> } — but
 *     NOT onto an EXISTING branch that is neither the branch being renamed
 *     nor owned by this session (#598: renameDstExists + ownedBranches — that
 *     forced rename clobbers a foreign ref rc 0 → block). The carve-out also
 *     requires the rename to run in the repo that recorded the baseline
 *     (baseline.repoKey === repoKey — the #376 discipline; a name collision
 *     in another clone never re-baselines) and a non-null renamed branch
 *     (a detached 1-pos rename — from null — passes through to git's rc-128
 *     refusal, never a phantom reBaseline).
 *   switch-existing to the session's ORIGINAL baseline branch (baseline.original
 *     — the branch recorded at session_start BEFORE any create-new re-baseline):
 *     allowed in agent-infra main → { reBaseline: <target> } — the sanctioned
 *     post-ceremony return-to-main (#376). The target is the session's de-facto
 *     own baseline: the branch the shared tree was on when THIS session started
 *     (the lock serializes concurrent starts only — a resumed/overlapping start
 *     records whatever branch was current). Harm is bounded exactly like the
 *     create-new carve-out: M2 still blocks off-baseline commits. The
 *     synchronous re-baseline keeps the next tool_call's M1 warn silent.
 *   everything else (switch-existing to any OTHER branch / force / force-create
 *   / orphan / detach / symbolic-ref HEAD / update-ref refs/heads / branch -f
 *   targeting a branch other than the checkout's OWN current branch — #591:
 *   a force-create whose target IS the branch currently checked out is
 *   git-refused rc 128, so the benign own-branch ceremony passes through to
 *   git's refusal, but only in a NON-bare repo whose command has exactly one
 *   state mutation (isBare false + stateOpCount 1; see the carve-out) / #592
 *   force-COPY (`git branch -C src dst` and every force-copy spelling — -Cq,
 *   -cf, -fC, -f -c, --force --copy: op "force" with branch = the DST) — same
 *   refusal premise: a dst equal to the checkout's OWN current branch is
 *   git-refused rc 128, so the same benign carve-out gates it, while foreign /
 *   non-checked-out overwrite targets block) →
 *   block. The #376 return arm additionally requires repoKey === baseline.repoKey
 *   (the resolved repo is the ONE where the original baseline was recorded — a
 *   cd into a DIFFERENT agent-infra clone must not authorize a switch there).
 */
export function decideM3({ branchOp, isAgentInfra, baseline, currentBranch, repoKey, stateOpCount = 1, isBare = false, hiddenStateSubst = false, renameDstExists = false, ownedBranches }) {
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
    // #592: the rename arm now also receives cluster/long-form renames
    // (-Mq/--move/--mov/--mo — identical decideM3 semantics as the exact
    // -m/-M they are byte-identical to in git; see classifyBranchOp).
    // #598: the #265/#592 own-baseline carve-out (from === baseline.branch →
    // reBaseline) is only SAFE for a rename onto a FREE name — git renames the
    // own checkout branch rc 0 without touching any second ref. A FORCED
    // rename onto an EXISTING ref (renameDstExists — the index.ts adapter
    // probes the resolved repo) that is NOT the branch being renamed and NOT
    // owned by this session CLOBBERS that foreign ref rc 0 (probe-verified
    // for `-M <baseline> <existing>`, the 1-pos `-M <existing>` rename-current
    // form, and the --so/--sort value-swallow shapes; git self-refuses only
    // when the dst is checked out in a worktree, rc 128). The branch being
    // renamed is `from`; for the 1-pos form classifyBranchOp returns from:null
    // and the substitution below resolves it to currentBranch, so the
    // old-name check runs against the CURRENT checkout branch (a classifier-
    // visible old name is impossible there). ownedBranches (this session's
    // created/renamed-to branches in this repo — the #543/#588 ownership
    // check) still allows overwriting the session's OWN refs. Round-1 review
    // fold-in: the carve-out is scoped to the repo that recorded the baseline
    // (baseline.repoKey === repoKey — the #376 discipline): a rename in a
    // DIFFERENT agent-infra clone whose checked-out branch merely shares the
    // baseline NAME must not re-baseline the session or consult the baseline
    // repo's owned set against another repo's refs (cross-clone name-collision
    // false-ownership; index.ts also probes — and _markOwned writes — only
    // within the mutation's own repo). Round-3/4 review fold-in: the arm also
    // requires from != null — a DETACHED session (currentBranch null) with a
    // 1-pos rename would otherwise collide null into the name checks; git
    // REFUSES a detached rename rc 128, so the null-from case passes through
    // below instead of re-baselining onto a phantom name.
    const from = branchOp.from ?? currentBranch;
    if (
      from != null
      && baseline
      && baseline.repoKey != null
      && baseline.repoKey === repoKey
      && from === baseline.branch
      && branchOp.to
    ) {
      const dst = branchOp.to;
      const owned = !!ownedBranches
        && (typeof ownedBranches.has === "function"
          ? ownedBranches.has(dst)
          : (Array.isArray(ownedBranches) && ownedBranches.includes(dst)));
      if (renameDstExists && dst !== from && !owned) {
        return {
          block: true,
          reason: [
            `⛔ git branch -m/-M/-Mq/--move blocked in the MAIN checkout.`,
            `   Why: "${dst}" already exists as a branch this session does not`,
            `   own — a forced rename would overwrite that foreign ref (git`,
            `   refuses rc 128 if it is checked out in any worktree, and the`,
            `   soft form refuses rc 128 either way) (#598).`,
            `   → Rename onto a free name, or onto one of this session's`,
            `     own branches.`,
          ].join("\n"),
        };
      }
      return { reBaseline: branchOp.to };
    }
    if (branchOp.to && from == null) {
      // Round-3/4 review fold-in: a 1-pos rename (rename current — from is
      // null because classifyBranchOp could not see an old name) on a
      // DETACHED main checkout (currentBranch null) is git-REFUSED rc 128
      // ("cannot rename the current branch while not on any") — no ref can
      // ever move, so pass through benignly (the #591/#592 pass-to-git-
      // refusal carve-out class) instead of re-baselining onto a phantom name
      // (the pre-#598 null===null collision) or blocking with a wrong reason.
      // A 2-pos rename always carries a non-null from, so this branch is
      // exactly the detached 1-pos form.
      return null;
    }
    if (baseline && branchOp.to && from === baseline.branch) {
      // Round-2 reviewer P2: the rename's from IS the baseline branch name but
      // the resolved repo is NOT the repo that recorded the baseline (a
      // cross-clone name collision, or a degraded repo) — the generic
      // "not this session's baseline" text below would mislead a user whose
      // branch name IS the baseline; the carve-out is repo-scoped (#598).
      return {
        block: true,
        reason: [
          `⛔ git branch -m/-M/-Mq/--move blocked in the MAIN checkout.`,
          `   Why: this rename runs in a different checkout than the one that`,
          `   recorded this session's baseline "${baseline.branch}" — the`,
          `   own-baseline rename carve-out is repo-scoped (#598).`,
          `   → Run the rename in the repo where this session started, or`,
          `     work in an isolated worktree (using-git-worktrees skill).`,
        ].join("\n"),
      };
    }
    return {
      block: true,
      reason: [
        `⛔ git branch -m/-M/-Mq/--move blocked in the MAIN checkout.`,
        `   Why: renaming a branch mutates branch state in the shared tree (#265).`,
        `   → Renaming the session's OWN baseline branch is allowed; this rename`,
        `     targets "${from ?? "(current)"}" which is not this session's baseline.`,
      ].join("\n"),
    };
  }
  // #591 benign-force carve-out (extended to force-COPY by #592): force-create
  // (`git branch -f <b> [<start>]` — and its merged-cluster / --forc spellings,
  // all of which classify op "force" with branch = first positional) and
  // force-copy (`git branch -C src dst` / every force-copy spelling — op
  // "force" with branch = the DST) mutate the TARGET ref, so foreign / stale
  // targets hit the default block below. But when the target IS the branch
  // currently checked out in the effective repo (branchOp.branch ===
  // currentBranch — "the current checkout's own branch"), git itself REFUSES
  // the update: "cannot force update the branch '<b>' used by worktree at
  // '<path>'" (probe-verified rc 128 for `--force <own>` and `-fq <own>`
  // alike). No shared ref can ever move, so blocking would be a needless false
  // positive on a legitimate ceremony step (e.g. an own-branch fast-forward
  // attempt) — allow it through to git's natural rc-128 refusal. Round-2
  // review fold-ins bound the carve-out:
  //   (a) CHECKOUT-force (`git checkout -f <t>` / `switch --discard-changes`)
  //       never matches: classifyBranchOp returns op "force" WITHOUT a branch
  //       field there (it discards uncommitted work rather than merely
  //       resetting a ref) — `branchOp.branch != null` keeps those blocked.
  //   (b) copy/move-composed force (classifyBranchOp omits branch for those —
  //       the mutation target is the SECOND positional, not pos[0]) never
  //       matches; detached main-checkout starts (currentBranch null) can
  //       never equal a named target → blocked.
  //   (c) isBare: a BARE effective repo has NO worktree to protect the branch
  //       git reports as its symbolic HEAD — `git branch -fq main HEAD` in a
  //       bare repo moves the ref rc 0 (probe-verified), so the carve-out's
  //       "git refuses it" premise fails there → refuse the carve-out
  //       (round-1 reviewer P2).
  //   (d) stateOpCount > 1: the M3 gate classifies only the FIRST state
  //       invocation; a `;`-compound whose later segment force-creates a
  //       FOREIGN branch would otherwise launder through a benign first
  //       segment (pre-#591 the exact-force first segment blocked the whole
  //       command) → refuse the carve-out for multi-state commands (round-2
  //       reviewer P1).
  //   (e) hiddenStateSubst: a shell substitution ($(…)/backticks/eval) may
  //       hide a branch-state git invocation the tokenizer collapsed to one
  //       opaque token — stateOpCount then undercounts (`git branch -fq own
  //       old ; echo "$(git branch -fq victim old)"` reports 1) and the
  //       carve-out on the own-branch segment would let the hidden FOREIGN
  //       force-create execute → refuse when the classifier detected one
  //       (round-3 reviewer P2; classify-git._hasHiddenStateSubst).
  if (op === "force" && branchOp.branch != null && branchOp.branch === currentBranch
      && (stateOpCount ?? 1) === 1 && !isBare && !hiddenStateSubst) {
    return null;
  }
  // #376 carve-out: sanctioned ceremony return-to-baseline — switch back to the
  // branch this session STARTED on (before any create-new re-baseline), allowed
  // in agent-infra main only. No original recorded (contended/detached start —
  // the tree may already sit on ANOTHER session's branch) → fail-closed block.
  // The resolved repo must be the SAME repo that recorded the original baseline
  // (repoKey equality — M2 semantics); a baseline owned by another agent-infra
  // checkout must not authorize a switch in this one (review fold-in, #376).
  if (
    op === "switch-existing"
    && isAgentInfra
    && baseline?.original
    && baseline?.repoKey != null
    && baseline.repoKey === repoKey
    && branchOp.target === baseline.original
  ) {
    return { reBaseline: branchOp.target };
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
      `   → Agent-infra ceremony return: git checkout back to the branch your`,
      `     session STARTED on (its original baseline) is allowed (#376).`,
    ].join("\n"),
  };
}

/**
 * Ownership allowance (agent-infra main, own baseline branch):
 *   merge/pull/rebase → current branch == baseline branch suffices (the
 *     mutation only ever advances the session's OWN branch; syncSource
 *     presence is not required — bare `git pull` pulls the own upstream).
 *   push / force-push / push-delete → EVERY named target == baseline branch
 *     (all-targets semantics — a multi-refspec `git push origin feat/1 other/2`
 *     must never slip a foreign target past the gate; symmetric with the
 *     delete case).
 *   branch-force-delete (LOCAL `git branch -D`) → every named target ==
 *     baseline branch OR a branch THIS session itself created via the M3
 *     create-new/rename carve-outs (ownedBranches — #376 review fold-in: after
 *     the sanctioned ceremony return-to-baseline the baseline is main again,
 *     but deleting the session's OWN merged ceremony branch locally must still
 *     pass; git already refuses deleting a branch checked out in ANY worktree,
 *     so a pid-owned local delete is collision-free). Remote pushes/deletes of
 *     owned branches stay baseline-only.
 */
export function ownershipAllowed({ opKind, currentBranch, baselineBranch, targets, syncSource, ownedBranches }) {
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
      if (t.length === 0) return false;
      if (opKind === "branch-force-delete") {
        const own = (ownedBranches || []).filter((b) => b !== "main" && b !== "master");
        return t.every((x) => x === baselineBranch || own.includes(x));
      }
      return t.every((x) => x === baselineBranch);
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
