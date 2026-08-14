// classify-git.mjs — shared destructive-git classification for main-worktree-guard.
// Pure JS so both index.ts (via jiti) and test.mjs can import the SAME rules.

import { execSync } from "node:child_process";
import { resolve, join } from "node:path";
import { existsSync, statSync } from "node:fs";

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
  { name: "merge", re: /\bgit\s+merge(?:$|\s)/ },
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
 * #207: pure TTL check for the file-based escape marker. Valid when the path
 * is a REGULAR FILE (directories/symlink targets never count — traversal
 * guard) younger than the TTL. `now`/`ttlMs` overridable for tests.
 */
export function isAllowMarkerValid(markerPath, now = Date.now(), ttlMs = 15 * 60_000) {
  try {
    const st = statSync(markerPath);
    if (!st.isFile()) return false; // dirs/symlinks-to-dirs are not markers
    return now - st.mtimeMs <= ttlMs;
  } catch {
    return false; // absent/unreadable → not allowed (fail-closed)
  }
}

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
 * cross-checked by test-branch-ownership.mjs's consistency matrix). */
function _tokenize(command) {
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
        tok += ch; i++; continue;
      }
      if (ch === "'" || ch === '"') { quote = ch; i++; continue; }
      if (/\s/.test(ch)) break;
      // Shell metacharacters are token boundaries too — `git add .&&git commit`
      // must tokenize as TWO invocations (review P2: no-space compounds evaded M2).
      // Consume the metachar so the outer loop advances (an empty-token break
      // would infinite-loop — i never moves past it).
      if (ch === "&" || ch === "|" || ch === ";" || ch === "(" || ch === ")") { i++; break; }
      if (ch === "\\" && i + 1 < s.length) { tok += s[i + 1]; i += 2; continue; }
      tok += ch; i++;
    }
    if (tok) tokens.push(tok);
  }
  return tokens;
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

/** Extract EVERY git invocation in a compound command (handles
 * `git add . && git commit -m x` — the commit is what decideM2 must gate).
 * @returns {Array<{verb: string|null, args: string[]}>}
 */
function _allGitInvocations(command) {
  const tokens = _tokenize(command);
  const invocations = [];
  let i = 0;
  while (i < tokens.length) {
    if (tokens[i] !== "git") { i++; continue; }
    i++;
    while (i < tokens.length) {
      const t = tokens[i];
      if (/^GIT_DIR=/.test(t) || /^GIT_WORK_TREE=/.test(t)) { i++; continue; }
      if (t === "cd") { i += 2; continue; }
      if (t === "-C" || t === "--cd") { i += 2; continue; }
      if (t.startsWith("--git-dir=") || t === "--git-dir") { i += t === "--git-dir" ? 2 : 1; continue; }
      if (t === "--work-tree") { i += 2; continue; }
      if (t.startsWith("--work-tree=")) { i++; continue; }
      if (t === "--namespace") { i += 2; continue; }
      if (t.startsWith("--namespace=")) { i++; continue; }
      if (t === "--no-pager" || t === "-p" || t === "--paginate") { i++; continue; }
      if (t === "-c" || t === "--config") { i += 2; continue; }
      if (t.startsWith("-")) { i++; continue; }
      break;
    }
    const verb = tokens[i] ?? null;
    const args = [];
    i++;
    while (i < tokens.length && tokens[i] !== "git") {
      if (!["&&", ";", "||", "|", "&", "(", ")"].includes(tokens[i])) args.push(tokens[i]);
      i++;
    }
    invocations.push({ verb, args });
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
  const invocations = _allGitInvocations(command);
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
