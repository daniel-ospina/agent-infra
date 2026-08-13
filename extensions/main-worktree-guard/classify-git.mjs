// classify-git.mjs — shared destructive-git classification for main-worktree-guard.
// Pure JS so both index.ts (via jiti) and test.mjs can import the SAME rules.
//
// Also home of the escape-marker (#207) rules — ALLOW_MAIN_EDITS_MARKER_TTL_MS,
// isAllowMarkerActive, parseMarkerContent, isAllowMarkerPath, isAllowMarkerCommand,
// extractMarkerReason, isAllowMarkerRealpath, readAllowMarkerState — so test.mjs
// exercises the SAME marker logic index.ts uses (dependency-injected, fail-safe
// default = inactive → block).

import { execSync } from "node:child_process";
import { resolve, join } from "node:path";
import { existsSync, statSync, readFileSync, realpathSync } from "node:fs";

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
