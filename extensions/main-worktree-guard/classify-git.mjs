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
import { homedir } from "node:os";
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
    // Check THREE-char `&>>` BEFORE the two-char `&>` (round-4: `&>>` was dead
    // behind `&>` — the bug reviewer probe).
    const three = s.slice(i, i + 3);
    if (three === "&>>") {
      tokens.push(three);
      i += 3;
      continue;
    }
    const two = s.slice(i, i + 2);
    if (two === "&&" || two === "||" || two === ">>" || two === "<<" || two === "&>" || two === ">&") {
      tokens.push(two);
      i += 2;
      continue;
    }

    const ch = s[i];

    // fd-prefixed redirect (no intervening space): `2>`, `2>>`, `2<`, `2<<`,
    // `2>&1`, `1>&2`, `2>&-`. Consume the whole redirect operator as ONE token
    // so `git checkout main 2>&1 | tail -3` leaves `checkout` with just `main`.
    // Round-17 (final gate P1): digit-less fd-dup/close forms — POSIX
    // `[n]<&word` with n DEFAULTING to 0: `<&1`, `<&-`, `<&0` (the old code
    // split `<&0` into `<`+`&`+`0`; `bash <&0 evil.sh` ran the script ungated).
    if (ch === "<" && s[i + 1] === "&") {
      let k = i + 2;
      while (k < s.length && /[0-9-]/.test(s[k])) k++;
      tokens.push(s.slice(i, k));
      i = k;
      continue;
    }
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

    // Regular token (quote- and escape-aware). sawQuote tracks whether the word
    // region contained ANY quote — a word that ENDS empty after a quote-pair
    // (`""` / `''` / `''""`) is a REAL bash argument (an empty word) and must
    // survive tokenization as the _EMPTY_QUOTED sentinel (#366 round-3): the
    // old `if (tok)` filter dropped it, turning `popd ""` into a bare popd
    // (truncate) — a hub-targeted commit after it was exempted. A token that is
    // empty WITHOUT quotes is impossible (the loop always appends a char before
    // breaking unless a quote consumed the word), so tok==="" && sawQuote is
    // exactly the empty-quoted case.
    let tok = "";
    let quote = null;
    let sawQuote = false;
    while (i < s.length) {
      const c = s[i];
      if (quote) {
        if (c === quote) { quote = null; i++; continue; }
        if (c === "\\" && quote === '"' && i + 1 < s.length) { tok += s[i + 1]; i += 2; continue; }
        tok += c; i++; continue;
      }
      if (c === "'" || c === '"') { quote = c; sawQuote = true; i++; continue; }
      if (/\s/.test(c)) break;
      if (c === "&" || c === "|" || c === ";" || c === "(" || c === ")" || c === ">" || c === "<") break;
      if (c === "\\" && i + 1 < s.length) { tok += s[i + 1]; i += 2; continue; }
      tok += c; i++;
    }
    if (tok) tokens.push(tok);
    else if (sawQuote) tokens.push(_EMPTY_QUOTED); // empty-quoted word → REAL empty arg (sentinel)
  }
  return tokens;
}

/** Sentinel token emitted by _tokenize for an EMPTY-QUOTED shell word (`""` /
 * `''` / `''""`). bash treats such a word as a REAL argument — an empty word.
 * The old `if (tok)` filter silently DROPPED it, which made `popd ""` parse as
 * a bare popd (truncate) and `popd +0 ""` as boundary-next `+0` (truncate):
 * the chain resolved to the worktree and a hub-targeted `git commit` was
 * exempted (probe-verified bypass, #366 round-3 — real commit landed on the
 * HUB while the guard said allowed). The NUL prefix cannot collide with a real
 * shell word (bash words are NUL-terminated C strings) and keeps the token
 * TRUTHY — a literal `""` would be re-dropped by consumers that check
 * truthiness. Every consumer that cannot interpret it degrades conservatively:
 * the cd-chain resolver hits a nonexistent path (existsSync → false) → break →
 * keeps the resolved prefix — the exact bash `cd ""` semantics (cwd unchanged);
 * resolveInvocationTarget's realpathSafe throws ERR_INVALID_ARG_VALUE on the
 * NUL path → null → conservative; verb matchers compare against specific flag
 * strings and never match the sentinel.
 */
const _EMPTY_QUOTED = "\u0000EMPTY";

/** Shell operators that end a git invocation's arg list (a pipe/redirect/chain
 * means the NEXT word starts a new command — a `tail`/`head`/`echo` consumer). */
const _SHELL_OPS = new Set(["&&", "||", "|", "&", ";", "(", ")"]);
function _isShellBoundary(tok) {
  if (_SHELL_OPS.has(tok)) return true;
  if (tok === ">" || tok === ">>" || tok === "<" || tok === "<<" || tok === "&>" || tok === ">&" || tok === "&>>") return true;
  // fd-prefixed redirects emitted by _tokenize: `2>`, `2>>`, `2<`, `2<<`, `2>&1`,
  // `1>&2`, `2>&-`.
  if (/^[0-9]+(?:>>?|<<?)$/.test(tok)) return true;
  if (/^[0-9]+[<>]&[0-9]*-?$|^[0-9]+[<>]&-$|^[<>]&[0-9]*-?$|^[<>]&-$/.test(tok)) return true;
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
  // git dst-inference shorthand: `:heads/main` / `backup:heads/main` resolve
  // to refs/heads/main on the remote (#439 P1 — probe-verified; a disordered
  // hub `git fetch origin backup:heads/main` moved local refs/heads/main).
  return dst.replace(/^refs\/heads\//, "").replace(/^heads\//, "");
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

/** Issue #351 (P2 hardening): derive git's OWN worktree list (`git worktree
 * list --porcelain`) as a realpath-normalized set of worktree paths, for the
 * reverse-pointer map cross-check. Porcelain has NO gitdir column
 * (empirically verified — plan P0), so the cross-check compares the map's
 * DERIVED wtPath against git's reported worktree paths. git resolves its view
 * from the SAME reverse-pointer files, so a fully-consistent deliberate craft
 * (reverse-pointer + back-referencing gitfile) passes both — documented
 * residual, out of the accidental-collision threat model. The cross-check
 * rejects PARTIAL/INCONSISTENT crafts whose reverse-pointer content git cannot
 * resolve from its own frame — e.g. RELATIVE gitdir content: git resolves it
 * against the admin dir, the guard's dirname() against the process cwd
 * (probe-verified divergence), and content pointing at a non-gitfile path is
 * omitted from porcelain entirely. Also guards the derivation against future
 * drift in git's own worktree model.
 * Parsed with `--porcelain -z` (NUL-delimited fields — git ≥ 2.36; the `-z`
 * option for `git worktree list` landed in 2.36.0): a path
 * with an EMBEDDED newline is accepted by git at creation (probe-verified;
 * an earlier line-split parse mis-split such paths and would have
 * false-blocked the worktree via the cross-check) and survives the NUL
 * split verbatim. Older git without `-z` → exec failure → null → cross-check
 * skipped (documented degradation + one-time warn). No whitespace stripping
 * at all — a trailing-space or trailing-CR path realpaths to itself.
 * @param {string} sessionCwd — cwd frame (the hub) for `git worktree list`.
 * @returns {Set<string>|null} realpath'd worktree paths, or null when git
 *   cannot run — the caller SKIPS the cross-check on null: a secondary git
 *   call at map-build time must never become a new false-block source (the
 *   two-way back-reference validation stays the primary gate).
 */
export function worktreeListPorcelainPaths(sessionCwd = process.cwd()) {
  try {
    const out = execSync("git worktree list --porcelain -z", {
      encoding: "utf-8", cwd: resolve(sessionCwd), timeout: 5000, stdio: ["ignore", "pipe", "ignore"],
    });
    const paths = new Set();
    // NUL-delimited fields: every `worktree <path>` field starts a record.
    // Records are `\0\0`-separated; the NUL split alone preserves embedded
    // newlines/whitespace in paths (review #353 round-1 P2 — a `.trim()` or
    // line-split here would realpath-fail legit paths and false-block them).
    for (const field of out.split("\0")) {
      if (field.startsWith("worktree ")) {
        const rp = _realpathSafe(field.slice("worktree ".length));
        if (rp !== null) paths.add(rp);
      }
    }
    return paths;
  } catch {
    return null; // git unavailable / pre-2.36 → cross-check skipped (no false-blocks)
  }
}

// One-time warn flag: the porcelain skip must be diagnosable without spamming
// the per-invocation map-build hot path (review #353 P2).
let _porcelainSkipWarned = false;

/** Worktree map: canonical gitDir → worktree path, derived from the
 * `<common>/worktrees/<name>/gitdir` reverse-pointer files (git worktree list
 * --porcelain has NO gitdir column — empirically verified) + the filesystem
 * layout. Main checkout excluded by construction (its common dir is `common`
 * itself, never under `common/worktrees/`). Per-entry try/catch: stale admin
 * dirs (rm -rf <wt> without prune → ENOENT) are skipped, other worktrees stay
 * exempt (T34). Entries whose derived wtPath `git worktree list --porcelain`
 * does not list are additionally rejected (issue #351 cross-check; when git
 * cannot run the cross-check is SKIPPED with a one-time warn — fail-safe,
 * never a new false-block source). Map key = realpath of the admin dir (which
 * `git rev-parse --git-dir` returns for a worktree cwd — probe-verified), NOT
 * the reverse-pointer content (which is the gitfile path <wt>/.git and
 * differs).
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
    const adminNames = readdirSync(adminRoot);
    if (adminNames.length === 0) return map; // no linked worktrees → nothing to cross-check (skip the spawn)
    // Issue #351: cross-check the reverse-pointer derivation against git's own
    // view ONCE per map build. null (git failure / git < 2.36) → cross-check
    // skipped — a secondary git call must never become a new false-block
    // source; the skip is surfaced ONCE (diagnosability, review #353 P2).
    const porcelainPaths = worktreeListPorcelainPaths(sessionCwd);
    if (porcelainPaths === null && !_porcelainSkipWarned) {
      _porcelainSkipWarned = true;
      console.warn(
        `[main-worktree-guard] ⚠️ porcelain cross-check unavailable (git worktree list failed) — ` +
        `#351 hardening SKIPPED while unavailable (re-engages automatically on recovery); ` +
        `two-way validation still active (conservative).`
      );
    }
    for (const name of adminNames) {
      try {
        const gitfile = readFileSync(join(adminRoot, name, "gitdir"), "utf-8").trim();
        const wtPath = _realpathSafe(dirname(gitfile));
        const adminKey = _realpathSafe(join(adminRoot, name));
        if (wtPath === null || adminKey === null) continue; // stale entry — skip
        // #347 code-review VULN-003: the reverse-pointer file is WRITABLE (an
        // ungated non-git shell echo can craft it). Two-way validation: the
        // resolved worktree must contain a `.git` whose content back-references
        // THIS admin dir — otherwise reject the entry (crafted content must not
        // poison the map value and turn a hub-targeted op into a "worktree").
        let backRef = null;
        try {
          backRef = readFileSync(join(wtPath, ".git"), "utf-8");
        } catch {
          continue; // no .git back-reference → not a git worktree → reject
        }
        // Round-5 (second-model P2): EXACT back-reference — parse the gitdir
        // line and compare equality (a substring match let a crafted `wt-evil`
        // gitfile pass for admin dir `wt`).
        const gm = backRef.match(/gitdir:\s*(.+)/);
        if (!gm || _realpathSafe(resolve(gm[1].trim())) !== adminKey) continue; // crafted/stale → reject
        // Issue #351 porcelain cross-check: git's OWN `git worktree list` must
        // list this worktree path. A craft the two-way check accepts (back-
        // referencing gitfile exists) but git cannot resolve from its own frame
        // (relative reverse-pointer content, dangling gitfile) is rejected
        // conservatively here — the entry never poisons the exemption map.
        if (porcelainPaths !== null && !porcelainPaths.has(wtPath)) continue;
        map.set(adminKey, wtPath);
      } catch {
        // per-entry skip — never abort the whole map for one stale dir
      }
    }
    // Round-3 (second-model P2): admin dirs exist but NO entry survived the
    // two-way validation — the git layout may have changed (a silent re-freeze
    // of the exact incident class this fix cures). One-time diagnosable warn.
    if (adminNames.length > 0 && map.size === 0) {
      console.warn(
        `[main-worktree-guard] ⚠️ worktree map empty despite ${adminNames.length} admin dir(s) — ` +
        `git layout may have changed; worktree-target exemption DISABLED (conservative).`
      );
    }
  } catch {
    // whole-map conservative fallback (empty map → no exemptions)
  }
  return map;
}

/** Exported alias for tests: the map builder is the only way to observe the
 * porcelain cross-check's per-entry rejection (the crafted-entry fixture never
 * reaches resolveInvocationTarget's rev-parse — the fake admin dir is not a
 * real git dir, so the conservative block there would mask the map-level pin). */
export const worktreeGitdirMap = _worktreeGitdirMap;

/** Resolve a git invocation's effective target. Returns
 * { effectiveCwd, gitDir, worktreePath, worktreeBranch, isWorktree } or null
 * (unresolvable / git/fs failure → conservative, no exemption). worktreeBranch
 * is the checked-out branch of a resolved worktree (used by the shared-ref
 * verb gate — the push carve-out must re-derive from the worktree's HEAD, not
 * the hub's, code-review #4).
 * #355: containment is now git's EFFECTIVE-TARGET semantics, not just cwd:
 * `gitDirHint` resolving to a mapped worktree's gitdir AND `workTreeHint`
 * resolving inside that worktree is a POSITIVE signal (isWorktree: true even
 * with effectiveCwd outside the worktreePath) — `git --git-dir=<wt>/.git
 * --work-tree=<wt> <verb>` fully determines git's repo + work-tree and is
 * byte-equivalent to the exempted `-C <wt>` form. `--git-dir` ALONE stays
 * blocked (work-tree defaults to cwd = hub → cross-contamination; the signal
 * is workTreeHint-REQUIRED by construction). Consumers evaluateHubGateWithTargets
 * (M4) and scriptGitVerdict read only isWorktree/worktreeBranch; effectiveCwd
 * remains the walker-resolved cwd for all other cases. The branch probe is
 * effective-target-aware (cwd-independent): `git --git-dir=<gitDir> branch
 * --show-current` reads the worktree's OWN HEAD from any cwd — a hub probe is
 * structurally impossible (inside=true ⇒ gitDir is a mapped worktree's admin
 * dir).
 * ⚠️ INPUT CONTRACT (#349): the fields resolveInvocationTarget READS are
 * ({cdChain, cHints, gitDirHint, workTreeHint, indexFileHint, objDirsHint,
 * configOverrides, configEnvOverrides, envPrefixes});
 * the full emitted allGitInvocations invocation shape also carries
 * verb/args/vars. There is NO `cmd` field. Calling with a raw-command shape
 * like `{cmd: 'cd <wt> && git add -A', args: [...]}` trivially yields an
 * EMPTY cdChain → effectiveCwd = baseCwd (the hub) → isWorktree:false. That
 * result is EXPECTED for the wrong shape, NOT evidence of a parsing bug — a
 * `{cmd}` probe is what misdiagnosed issue #349.
 * @param {{cdChain?: Array<string|null>, cHints?: string[], gitDirHint?: string|null, workTreeHint?: string|null, indexFileHint?: string|null, objDirsHint?: string|null}} inv
 * @param {string} sessionCwd — cwd frame for the worktree MAP (the hub).
 * @param {string} [baseCwd] — cd-chain/cHints resolution base (scriptGitVerdict
 *   passes executionCwd; the bash gate passes sessionCwd).
 */
export function resolveInvocationTarget(inv, sessionCwd = process.cwd(), baseCwd = sessionCwd) {
  try {
    // Round-6 (final gate P2): unresolvable $VAR in a -C/--git-dir/--work-tree/
    // INDEX operand ("\u0000" sentinel from the walker) → conservative.
    if ((inv.cHints || []).includes("\u0000") || inv.gitDirHint === "\u0000" ||
        inv.workTreeHint === "\u0000" || inv.indexFileHint === "\u0000" || inv.objDirsHint === "\u0000") {
      return null;
    }
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
    // Issue #397 (cross-repo worktree ops): the worktree map used to be built
    // from the SESSION cwd frame ONLY, so a worktree of a DIFFERENT repo (e.g.
    // an agent-infra worktree reached from a tortoise session) missed the map
    // and was conservatively classified hub-targeted — M4 then blocked every
    // sanctioned agent-infra mutation (2026-08-30 #387: 4 commits, 3 pushes,
    // a PR body and a tag all had to be delegated to gate-exempt sub-agents).
    // Fall back to deriving the map from the invocation's OWN frame — the cwd
    // where git itself just resolved gitDir — so foreign-repo worktrees are
    // recognized with the SAME two-way back-reference + porcelain cross-check
    // (equally conservative). The hit is tagged foreignWorktree so consumers
    // can apply foreign-repo semantics (a foreign wt shares NO ref namespace
    // with the session hub). Same-frame invocations skip the redundant rebuild
    // (identical map by construction); the fallback fires only on a session-map
    // miss, i.e. foreign/odd geometries — rare on the gate's hot path.
    const sessionMap = _worktreeGitdirMap(sessionCwd);
    let worktreePath = sessionMap.get(gitDir) ?? null;
    let foreignWorktree = false;
    // sessionReal null (dead/unresolvable sessionCwd) must NOT look like a
    // "different frame": the session map is empty for a dead cwd, and without
    // this guard a SESSION worktree reached via a real baseCwd would be tagged
    // foreignWorktree → fail-open past shared-ref/main-protection (code-review
    // P2, #397). Dead session cwd → conservative (no fallback, isWorktree
    // false).
    const sessionReal = _realpathSafe(sessionCwd);
    if (worktreePath === null && sessionReal !== null && sessionReal !== cwd) {
      const hit = _worktreeGitdirMap(cwd).get(gitDir);
      // cycle-2 P2 closure: repo-identity check — a SESSION worktree (reached
      // while the session map's whole build transiently failed) must never be
      // tagged foreign (shared-ref/main-protection fail-open).
      if (hit !== undefined && !_sameRepoAsSession(gitDir, sessionCwd)) {
        worktreePath = hit;
        foreignWorktree = true;
      }
    }
    if (worktreePath === null) {
      return { effectiveCwd: cwd, gitDir, worktreePath: null, worktreeBranch: null, isWorktree: false, foreignWorktree: false };
    }
    const cwdReal = _realpathSafe(cwd);
    if (cwdReal === null) return null;
    // #355: workTreeHint realpath — computed ONCE, shared by the positive
    // containment signal AND the mismatch guard (one realpath, both guards —
    // they can never disagree at the realpath-normalization boundary).
    const wtHintReal = inv.workTreeHint ? _realpathSafe(resolve(cwd, inv.workTreeHint)) : null;
    // #355 positive containment signal: gitDirHint resolving to a mapped
    // worktree's gitdir (map hit above ⇒ worktreePath !== null) AND workTreeHint
    // resolving inside that worktree ⇒ git's effective target IS the worktree
    // regardless of cwd. `git --git-dir=<wt>/.git --work-tree=<wt> <verb>` from
    // the hub cwd is byte-equivalent to the exempted `git -C <wt> <verb>` (both
    // operate on the wt index, zero hub interaction; probed on git 2.50.1).
    // workTreeHint-REQUIRED: `--git-dir` ALONE (work-tree defaults to cwd = hub)
    // stages HUB files into the wt index — cross-contamination — and must NOT
    // fire (structural by BOTH-hints).
    // wtHintInside & the mismatch guard below share wtHintReal → mutually exclusive
    // by construction: the signal fires only when workTreeHint is INSIDE the wt, the
    // guard returns isWorktree:false when it's OUTSIDE, and the branch probe is gated
    // after the mismatch return — `inside` never leaks into the probe for mismatch cases.
    const wtHintInside = !!(inv.gitDirHint && inv.workTreeHint) &&
      wtHintReal !== null &&
      (wtHintReal === worktreePath || wtHintReal.startsWith(worktreePath + "/"));
    const inside = wtHintInside || cwdReal === worktreePath || cwdReal.startsWith(worktreePath + "/");
    // workTree mismatch guard (unchanged semantics — shared wtHintReal): a
    // work-tree hint pointing OUTSIDE the worktree means the invocation operates
    // on a foreign working tree → not isolated. Mutually exclusive with
    // wtHintInside by construction.
    if (inv.workTreeHint) {
      if (wtHintReal !== null &&
          !(wtHintReal === worktreePath || wtHintReal.startsWith(worktreePath + "/"))) {
        return { effectiveCwd: cwd, gitDir, worktreePath, worktreeBranch: null, isWorktree: false };
      }
    }
    // Index/object-redirect guard (round-3, second-model P2): GIT_INDEX_FILE /
    // GIT_OBJECT_DIRECTORY resolving OUTSIDE the worktree redirects the
    // mutation into the hub's state — not isolated.
    if (inv.indexFileHint) {
      const idx = _realpathSafe(resolve(cwd, inv.indexFileHint)) ?? resolve(cwd, inv.indexFileHint); // resolve fallback for not-yet-existing (round-4)
      if (!(idx === worktreePath || idx.startsWith(worktreePath + "/"))) {
        return { effectiveCwd: cwd, gitDir, worktreePath, worktreeBranch: null, isWorktree: false };
      }
    }
    if (inv.objDirsHint) {
      const od = _realpathSafe(resolve(cwd, inv.objDirsHint.split(":")[0] ?? "")) ?? resolve(cwd, inv.objDirsHint.split(":")[0] ?? "");
      if (!(od === worktreePath || od.startsWith(worktreePath + "/"))) {
        return { effectiveCwd: cwd, gitDir, worktreePath, worktreeBranch: null, isWorktree: false };
      }
    }
    // The worktree's checked-out branch (shared-ref carve-out; git read failure
    // → null → conservative). Only when the invocation IS worktree-contained.
    let worktreeBranch = null;
    if (inside) {
      try {
        // Cwd-INDEPENDENT probe (#355): --git-dir is a global option valid on
        // `branch`. With the resolved admin dir (gitDir), the probe reads the
        // WT's OWN HEAD from ANY cwd — inside=true ⇒ worktreePath !== null ⇒
        // gitDir is a mapped worktree's admin dir, so a hub probe is
        // structurally impossible. Value-identical to the old cwd-scoped probe
        // for every cwd-contained case (gitfile resolution ≡ direct admin-dir
        // read; the map's two-way validation guarantees wt/.git back-references
        // this admin dir). Replaces the old probe 1:1 — zero extra spawn.
        // Explicit --git-dir also beats ambient GIT_DIR env (CLI > env),
        // fixing the old probe's latent mis-derivation (probe-verified).
        worktreeBranch = execFileSync("git", ["--git-dir=" + gitDir, "branch", "--show-current"], {
          encoding: "utf-8", timeout: 5000, stdio: ["ignore", "pipe", "ignore"],
        }).trim() || null;
      } catch {
        worktreeBranch = null; // git read failure → conservative (unchanged)
      }
    }
    return { effectiveCwd: cwd, gitDir, worktreePath, worktreeBranch, isWorktree: inside, foreignWorktree: inside && foreignWorktree };
  } catch {
    return null; // conservative — never false-exempt
  }
}

/** Extract EVERY git invocation in a compound command (handles
 * `git add . && git commit -m x` — the commit is what decideM2 must gate).
 * Extended shape (#347): per-invocation { verb, args, cdChain, cHints,
 * gitDirHint, workTreeHint, indexFileHint, objDirsHint, vars } — cdChain is
 * subshell- AND pipe-scoped (bash semantics, probe-verified): `(` pushes a
 * chain copy / `)` pops (cds
 * inside parens never leak); every `|` pipeline segment runs in a subshell
 * seeded from C0 = the chain at the last command boundary BEFORE the first
 * pipe segment, and segment cds are discarded at the pipeline end.
 * cd targets are var-expanded AT WALK TIME against segment-local vars; an
 * unresolvable `$VAR` pushes a null marker (conservative → no exemption).
 * {verb, args} are unchanged for existing consumers.
 * @returns {Array<{verb: string|null, args: string[], cdChain: Array<string|null>, cHints: string[], gitDirHint: string|null, workTreeHint: string|null, indexFileHint: string|null, objDirsHint: string|null, vars: object}>}
 */
/** Shared shell-chain walker (#347 code-review P1): ONE parser for the
 * cd-chain state machine consumed by allGitInvocations AND commandExecutionCwd
 * — a fix to the chain semantics lands in both consumers, never one (the
 * guard's most-patched code: #337 pipes/redirects, #347 subshell/pipe scoping).
 * Bash-faithful semantics (probe-verified on git 2.50.1 / bash 3.2):
 *  - cd targets push onto the chain; subshell parens push/pop chain copies
 *    (cds inside parens never leak out);
 *  - `|` pipelines: every segment runs in a subshell seeded from C0 (the chain
 *    at the last boundary before the first pipe); segment cds are discarded;
 *  - `&` backgrounds the preceding list — the whole list runs in a subshell,
 *    so its cds never apply to the foreground: chain resets to C0 (conservative);
 *  - `&&`/`||`/`;` are command boundaries (vars persist — real shell state);
 *  - `VAR=x` is a STATEMENT (persists) when followed by a boundary, a PREFIX
 *    (env-only for the next command — does NOT persist, and is NOT visible to
 *    that command's own word expansion) when followed by a command token;
 *    cd $VAR expands against PRIOR-segment vars only (bash: `WT=/x cd "$WT"`
 *    expands $WT to the PRE-assignment value — same-segment shadowing is
 *    unresolvable → null → conservative block, code-review VULN-001);
 *  - `export GIT_DIR=`/`export GIT_WORK_TREE=` persist for the whole command
 *    (bash env state — code-review VULN-002) and apply to every git invocation;
 *    the bare `GIT_DIR=x` prefix form is next-command-only.
 * @param {string} command
 * @param {object} h — optional handlers: onCd(expanded), onBoundary(),
 *   onParenPush(), onParenPop(), onPipe(), onScriptToken(chainSnapshot),
 *   onOther(token), onGitStart(frame), onGitEnd({verb,args,cHints,gitDirHint,
 *   workTreeHint,cdChain,vars}).
 */
function _walkShell(command, h = {}, seedVars = {}) {
  const tokens = _tokenize(command);
  // Per-paren-depth frame: chain, vars (persisted shell state), segVars (vars
  // at the last boundary — the expansion scope for a segment's own words),
  // baseLen (chain length at last boundary), pipeC0, pipeActive, pushtack
  // (issue #354: chain length at each pushd — popd truncates back to it, D1).
  // seedVars (round-13): command-level assignments passed into nested walks
  // (`-c` inlines, substitution spans) so mid-span `$VAR` command words resolve.
  const stack = [{ chain: [], vars: { ...seedVars }, segVars: { ...seedVars }, baseLen: 0, pipeC0: null, pipeActive: false, persistHints: { gitDirHint: null, workTreeHint: null }, pushtack: [] }];
  const frame = () => stack[stack.length - 1];
  const refreshSeg = (f) => { f.segVars = { ...f.vars }; };
  const restoreC0 = (f) => { if (f.pipeActive && f.pipeC0) f.chain.splice(0, f.chain.length, ...f.pipeC0); };
  const boundary = (clearChain) => {
    const f = frame();
    restoreC0(f);
    f.pipeActive = false;
    f.pipeC0 = null;
    if (clearChain) f.chain.splice(0, f.chain.length); // `&` — backgrounded list cds never apply
    f.baseLen = f.chain.length;
    refreshSeg(f);
    h.onBoundary?.();
  };
  const subshellReset = (f) => { f.baseLen = f.chain.length; refreshSeg(f); }; // round-13: pipe segments INHERIT vars (bash) — `G=git; echo x | $G reset` must resolve G
  let pendingHints = {}; // GIT_DIR=x / GIT_WORK_TREE=x prefixes — next command only
  let prevWasBoundary = true; // cd is the builtin only in command-word position (round-3)
  let spawnerPending = false; // round-14: a spawner's args keep command position
  let i = 0;
  while (i < tokens.length) {
    const t = tokens[i];
    if (t === "cd" && prevWasBoundary && !spawnerPending) {
      // Round-15 (final gate P1): while a spawner's args are pending, `cd` is
      // NOT the shell builtin — only eval/command propagate cd to the current
      // shell; env/sudo/nice/time run it in a subprocess, so the parent cwd
      // stays the hub (`env -i cd <wt>; git commit` ran git in the hub —
      // probe; the round-14 spawner window had made it wt-exempt → allowed).
      const next = tokens[i + 1];
      const hasTarget = next !== undefined && !_isShellBoundary(next);
      const target = hasTarget ? next : null; // bare cd / cd <boundary> → null marker (T45a)
      i += hasTarget ? 2 : 1;
      const f = frame();
      // Bare cd / ~ / cd- → unresolvable (conservative). $VAR expansion against
      // PRIOR-segment vars only — same-segment assignment is bash-invisible.
      const expanded = (target === null || target === "~" || target.startsWith("~/") || target === "-")
        ? null
        : _expandCdVars(target, f.segVars);
      f.chain.push(expanded);
      h.onCd?.(expanded);
      prevWasBoundary = false;
      continue;
    }
    // Issue #354: pushd/popd are REAL cwd-state builtins (like cd) — recognized
    // in the SAFE direction only (no bypass). Design D1: popd truncates the
    // chain to the PRE-pushd boundary (a per-frame pushtack records the chain
    // length at each pushd), NOT "pop the last entry" — the naive form diverges
    // from bash when a cd intervenes (`pushd wt; cd sub; popd` → bash cwd is the
    // HUB; pop-last would resolve the wt → bypass). Bare pushd / pushd
    // <boundary> / flag forms (`-n`, `+N`, `-N`, `--`) never cd → null marker;
    // an empty-stack popd (bash errors, cwd unchanged) → null marker — both
    // conservative (no exemption). Same command-position guard as cd: a
    // pushd/popd after a spawner (`sudo pushd`) runs in a subprocess and must
    // not mutate the parent chain.
    //
    // Issue #366 review (P1 SECURITY BYPASS, round-2): only a BARE popd (next
    // token undefined / shell boundary) — plus `--` (bash's option terminator
    // — probe-verified: `popd -- <any operand>` behaves like bare popd, cds
    // to the new top) and `+0` with NOTHING after it (removes the top, cds to
    // the new top = the pre-pushd cwd) — truncates to the pushtack boundary.
    // EVERY other argument form keeps cwd at the CURRENT stack top, i.e. the
    // HUB for a wt→hub pushd chain (probe-verified on bash 3.2): `-n` sets
    // NOCD (pops WITHOUT cd); `+N`/`-N` with N≥1 / `-0` remove a NON-top
    // entry — for the pinned pushd-chain (3-stack with the session root on
    // the stack) `+0 -1` keeps cwd at the HUB (accurate block — null-mark is
    // REQUIRED; on a true 2-stack `cd wt && pushd hub` bash would cd to the
    // new top, but that shape is not the pinned test); path-like operands are
    // errors (no pop, no cd — cwd stays hub). CRITICAL (cycle-2
    // review): bash 3.2's popd scans the ENTIRE argument list — a `+0`
    // followed by ANY word (`popd +0 -n`, `popd +0 /x`, `popd +0 -1`,
    // `popd +0 foo` — all probe-verified) parses to a NON-truncating form →
    // no cd to the new top → cwd stays at the hub. Truncating for those
    // forms would resolve the chain to the wt and exempt a hub-targeted
    // mutation → guard bypass. The null-marker path consumes ALL popd
    // argument tokens up to the next shell boundary (bash's arg scan consumes
    // every word) so the walker stays in sync, and pushes a NULL marker
    // (conservative → block, never exempt), mirroring the pushd branch's flag
    // handling and the cd branch's bare-cd pattern.
    if (t === "pushd" && prevWasBoundary && !spawnerPending) {
      const next = tokens[i + 1];
      const isFlagForm = next !== undefined && (next.startsWith("-") || /^\+[0-9]+$/.test(next));
      const hasTarget = next !== undefined && !_isShellBoundary(next) && !isFlagForm;
      const target = hasTarget ? next : null; // bare / <boundary> / flag → null marker
      i += hasTarget ? 2 : 1;
      const f = frame();
      // Bare / ~ / cd- / unresolvable $VAR → null marker (mirrors the cd branch).
      const expanded = (target === null || target === "~" || target.startsWith("~/") || target === "-")
        ? null
        : _expandCdVars(target, f.segVars);
      if (expanded === null) {
        f.chain.push(null); // conservative — never a bypass
      } else {
        f.pushtack.push(f.chain.length); // D1: record the PRE-pushd boundary
        f.chain.push(expanded);
      }
      h.onCd?.(expanded);
      prevWasBoundary = false;
      continue;
    }
    if (t === "popd" && prevWasBoundary && !spawnerPending) {
      const next = tokens[i + 1];
      const hasArg = next !== undefined && !_isShellBoundary(next);
      // #366 round-2: the D1 truncate is valid ONLY for bare popd / `--` /
      // `+0` with NOTHING after it. `+0` is a truncate form ONLY when
      // tokens[i+2] is undefined or a shell boundary — bash 3.2's popd scans
      // the ENTIRE argument list, so `popd +0 -n` (NOCD), `popd +0 /x`,
      // `popd +0 -1`, `popd +0 foo` all parse to NON-truncating forms → no cd
      // → cwd stays at the current stack top (the HUB for a wt→hub chain;
      // probe-verified). Any other argument (alone OR following `+0`) → NULL
      // marker so the chain resolves conservatively (block) and the hub-
      // targeted mutation is never exempted. Consume ALL popd argument tokens
      // up to the next shell boundary (bash's arg scan consumes every word)
      // so the walker never desyncs.
      // #366 round-3: an EMPTY-QUOTED operand (`""` / `''`) is a REAL bash
      // argument — the tokenizer emits the _EMPTY_QUOTED sentinel for it, so
      // `popd ""` has next = sentinel (hasArg → NOT a truncate form → NULL
      // marker; probe: bash treats `popd ""` as a pop-without-cd — cwd stays
      // at the hub) and `popd +0 ""` has tokens[i+2] = sentinel, which is NOT
      // a shell boundary (_isShellBoundary(sentinel) → false) → NOT a truncate
      // form → NULL marker (probe: `popd +0 ""` / `popd "" +0` /
      // `popd +0 '' ''` all keep cwd at the hub). The empty-quoted arg is
      // NEVER a shell boundary — it is a real word.
      const isTruncateForm = !hasArg || next === "--" || (next === "+0" && (tokens[i + 2] === undefined || _isShellBoundary(tokens[i + 2])));
      if (!isTruncateForm) {
        let j = i + 1;
        while (j < tokens.length && !_isShellBoundary(tokens[j])) j++;
        i = j;
        const f = frame();
        f.chain.push(null); // conservative — cwd stays at the current top (the hub)
        prevWasBoundary = false;
        continue;
      }
      i += hasArg ? 2 : 1; // bare popd / `--` / boundary-next `+0` — consume the argument token too
      const f = frame();
      const mark = f.pushtack.pop();
      if (mark === undefined) {
        f.chain.push(null); // empty stack → bash errors, cwd unchanged → conservative
      } else {
        f.chain.splice(mark, f.chain.length - mark); // D1: truncate to the pre-pushd state
      }
      prevWasBoundary = false;
      continue;
    }
    if (t === "(") {
      const f = frame();
      restoreC0(f);
      stack.push({ chain: [...f.chain], vars: { ...f.vars }, segVars: { ...f.segVars }, baseLen: f.chain.length, pipeC0: null, pipeActive: false, persistHints: { ...f.persistHints }, pushtack: [...f.pushtack] }); // round-12: bash subshells INHERIT variables (issue #354: and a COPY of the dir stack)
      pendingHints = {};
      prevWasBoundary = true;
      h.onParenPush?.();
      i++;
      continue;
    }
    // Round-13 (final gate P1): compound-command reserved words (for/do/done/
    // if/then/else/elif/fi/while/until/select/!/case/esac) start a new command
    // word position — a following `$VAR` must resolve (`G=git; for i in 1; do
    // $G …; done` ran git — probe). They never consume command position.
    if (COMPOUND_WORDS.has(t)) { i++; prevWasBoundary = true; continue; }
    if (t === "{" || t === "}") { i++; prevWasBoundary = true; continue; } // brace-group boundaries (round-11)
    if (t === ")") {
      if (stack.length > 1) stack.pop();
      pendingHints = {};
      prevWasBoundary = true;
      h.onParenPop?.();
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
      subshellReset(f);
      pendingHints = {};
      frame().persistHints = { gitDirHint: null, workTreeHint: null }; // pipe segments are subshells — exports don't leak
      prevWasBoundary = true;
      h.onPipe?.();
      i++;
      continue;
    }
    if (t === "&&" || t === "||" || t === ";") { boundary(false); pendingHints = {}; prevWasBoundary = true; spawnerPending = false; i++; continue; }
    if (t === "&") { boundary(true); pendingHints = {}; frame().persistHints = { gitDirHint: null, workTreeHint: null }; prevWasBoundary = true; spawnerPending = false; i++; continue; } // background — whole list in a subshell
    if (t === "export") {
      // Round-4: `export` consumes ALL following words as args (none is a
      // command word — `export cd <wt> && git commit` does NOT run cd). Only
      // GIT_DIR/GIT_WORK_TREE assignments (or bare names) affect persistHints.
      let j = i + 1;
      while (j < tokens.length && !_isShellBoundary(tokens[j])) {
        const n = tokens[j];
        if (/^GIT_DIR=(.*)$/.test(n)) { frame().persistHints.gitDirHint = n.slice("GIT_DIR=".length); }
        else if (/^GIT_WORK_TREE=(.*)$/.test(n)) { frame().persistHints.workTreeHint = n.slice("GIT_WORK_TREE=".length); }
        else if (n === "GIT_DIR") { frame().persistHints.gitDirHint = null; }
        else if (n === "GIT_WORK_TREE") { frame().persistHints.workTreeHint = null; }
        else if (/^[A-Za-z_][A-Za-z0-9_]*=/.test(n)) {
          // Round-11: `export G=git` sets the var (bash) — the $VAR command-word
          // resolution (final gate P1) reads frame().vars.
          frame().vars[n.slice(0, n.indexOf("="))] = n.slice(n.indexOf("=") + 1);
        }
        j++;
      }
      i = j;
      prevWasBoundary = true;
      continue;
    }
    if (t === "unset") {
      // Round-4: `unset` consumes ALL following args; deletes the named var
      // from persisted shell state (not just GIT_DIR/GIT_WORK_TREE — `unset
      // WT` must clear a stale WT used by a later `cd "$WT"`, security P2).
      let j = i + 1;
      while (j < tokens.length && !_isShellBoundary(tokens[j])) {
        const n = tokens[j];
        if (n === "GIT_DIR") frame().persistHints.gitDirHint = null;
        else if (n === "GIT_WORK_TREE") frame().persistHints.workTreeHint = null;
        else if (/^[A-Za-z_][A-Za-z0-9_]*$/.test(n)) {
          delete frame().vars[n];
          delete frame().segVars[n];
        }
        j++;
      }
      i = j;
      prevWasBoundary = true;
      continue;
    }
    if (/^GIT_DIR=/.test(t)) { pendingHints.gitDirHint = t.slice("GIT_DIR=".length); i++; continue; }
    if (/^GIT_WORK_TREE=/.test(t)) { pendingHints.workTreeHint = t.slice("GIT_WORK_TREE=".length); i++; continue; }
    // Round-3 (second-model P2): index/object-redirect env vars are hub-mutation
    // vectors (`GIT_INDEX_FILE=<hub>/.git/index git add` from a wt stages the
    // HUB's index) — captured like GIT_DIR and conservatively blocked when they
    // resolve outside the worktree.
    if (/^GIT_INDEX_FILE=/.test(t)) { pendingHints.indexFileHint = t.slice("GIT_INDEX_FILE=".length); i++; continue; }
    if (/^GIT_OBJECT_DIRECTORY=/.test(t) || /^GIT_ALTERNATE_OBJECT_DIRECTORIES=/.test(t)) { pendingHints.objDirsHint = t.slice(t.indexOf("=") + 1); i++; continue; }
    // Redirects (bare + fd-prefixed + &>) never start a command — skip them
    // (and their operand) WITHOUT clearing prevWasBoundary, so a redirect-led
    // command word is still recognized: `> /dev/null cd <wt> && git commit` runs
    // the cd (round-4 bug reviewer R4-11).
    if (t === ">" || t === ">>" || t === "<" || t === "<<" || t === "&>" || t === ">&" || t === "&>>" || /^(?:[0-9]+)?[<>]/.test(t) || /^[0-9]+[<>]&[0-9]*-?$|^[0-9]+[<>]&-$|^[<>]&[0-9]*-?$|^[<>]&-$/.test(t)) {
      const fdSingle = /^[0-9]+[<>]&[0-9]*-?$|^[0-9]+[<>]&-$|^[<>]&[0-9]*-?$|^[<>]&-$/.test(t); // 2>&1 — no separate operand
      i += fdSingle ? 1 : 2;
      continue;
    }
    if (/^[A-Za-z_][A-Za-z0-9_]*=/.test(t)) {
      const eq = t.indexOf("=");
      // Statement-vs-prefix (round-3 P1): scan past io-redirects + their operands
      // and env prefixes — an assignment is a STATEMENT (persists) only when no
      // command word follows; `VAR=x > /dev/null git fetch` is a PREFIX (env-only).
      let j = i + 1;
      let isStatement = true;
      while (j < tokens.length) {
        const n = tokens[j];
        // Redirects (+ operands) and fd-redirects first — they are ALSO shell
        // boundaries for the args loop but do NOT terminate an assignment
        // statement (`VAR=x > /dev/null git fetch` is a PREFIX, round-3).
        if (/^(?:[0-9]+)?[<>]/.test(n) || n === ">" || n === ">>" || n === "<" || n === "<<" || n === "&>" || n === ">&" || n === "&>>" || /^[0-9]+[<>]&[0-9]*-?$|^[0-9]+[<>]&-$|^[<>]&[0-9]*-?$|^[<>]&-$/.test(n)) {
          j += 2; // redirect + its operand
          continue;
        }
        if (_isShellBoundary(n)) break; // boundary → statement
        if (/^[A-Za-z_][A-Za-z0-9_]*=/.test(n)) { j++; continue; } // another prefix
        isStatement = false; // a command word follows → prefix
        break;
      }
      if (isStatement) frame().vars[t.slice(0, eq)] = t.slice(eq + 1);
      // else: env PREFIX — does NOT persist, NOT visible to the next command's own
      // word expansion (bash). Captured as envPrefixes (cycle-5 P1): the gate's
      // own config probes need the same env git sees (`HUBPUSH=<hub> git
      // --config-env=remote.origin.url=HUBPUSH push …` silently re-points a
      // foreign push at the hub).
      // prevWasBoundary stays TRUE for prefixes (the next token is the command
      // word), EXCEPT redirects+operands in between: skip them in the main walk
      // WITHOUT clearing prevWasBoundary — `VAR=x > /dev/null cd /wt` runs the cd
      // (round-4 bug reviewer; previously the `>`/operand hit onOther → a real cd
      // was missed → false-block freeze).
      if (!isStatement) {
        (pendingHints.envPrefixes || (pendingHints.envPrefixes = [])).push(t);
        let k = i + 1;
        while (k < tokens.length && (/^(?:[0-9]+)?[<>]/.test(tokens[k]) || tokens[k] === ">" || tokens[k] === ">>" || tokens[k] === "<" || tokens[k] === "<<" || tokens[k] === "&>" || tokens[k] === ">&" || tokens[k] === "&>>" || /^[0-9]+[<>]&[0-9]*-?$|^[0-9]+[<>]&-$|^[<>]&[0-9]*-?$|^[<>]&-$/.test(tokens[k]))) {
          k += 2; // skip redirect + operand
        }
        i = k - 1; // the loop's i++ lands on the command word
      }
      i++;
      continue;
    }
    // Script-path tokens (backdoor surface): interpreter + flags + path,
    // `. script`, or ./x.sh direct execution. Round-4: skip ALL leading
    // interpreter flags (`bash -x evil.sh` — the old code returned null on the
    // first `-x`), and gate `-c 'inline command'` content by recursively
    // walking it (the interpreter-inline bypass: `bash -c 'git reset --hard'`
    // previously produced zero invocations → the whole M4 gate was skipped).
    if (SHELL_INTERPRETERS.has(t)) {
      let j = i + 1;
      let sawInline = false;
      while (j < tokens.length) {
        const n = tokens[j];
        // Round-16 (final gate P1): skip operand-less fd redirects (`2<&1`,
        // `2<&-`) when scanning for -c / the script path — `bash 2<&1 -c
        // 'git reset'` ran the inline (probe moved HEAD).
        if (/^[0-9]+[<>]&[0-9]*-?$|^[0-9]+[<>]&-$|^[<>]&[0-9]*-?$|^[<>]&-$/.test(n)) { j++; continue; }
        // Round-18 (final gate P1): skip redirect operators + operands too
        // (`bash < /dev/null -c 'git commit'` broke at the bare `<` and never
        // walked the inline — probe; the inline committed to the hub).
        if (n === ">" || n === ">>" || n === "<" || n === "<<" || n === "&>" || n === ">&" || n === "&>>" || /^(?:[0-9]+)?[<>]/.test(n)) {
          j += 2;
          continue;
        }
        if (n === "-c" || n === "--command") {          // Round-5 (security F3): skip flags AFTER -c too — `bash -c -x 'git
          // reset'` takes the first NON-flag token as the command string.
          let m = j + 1;
          while (m < tokens.length && tokens[m].startsWith("-")) m++;
          const inline = tokens[m];
          if (inline !== undefined && !_isShellBoundary(inline)) {
            // Recursively walk the inline command (its cds resolve from the
            // CURRENT chain) and forward its git invocations.
            const base = [...frame().chain];
            const nested = allGitInvocations(inline, frame().vars); // round-13: seed the nested walk with the current shell state
            for (const ni of nested) {
              h.onGitEnd?.({
                ...ni,
                cdChain: [...base, ...ni.cdChain],
                cHints: [...(frame().pipeActive ? frame().chain.slice(0, frame().baseLen) : []), ...ni.cHints],
              });
            }
            sawInline = true;
            i = m + 1;
          }
          break;
        }
        if (!n.startsWith("-")) break; // first non-flag = the script path
        // Round-20 (security P1): skip flag OPERANDS for operand-taking flags
        // (`bash --rcfile decoy -c 'git commit'` broke at `decoy` and never
        // walked the inline — probe committed to the hub).
        j++;
        if (n === "--rcfile" || n === "--init-file" || n === "-O" || n === "-o") j++;
      }
      if (!sawInline) {
        // first non-flag token = script path (skip ALL flags)
        let k = i + 1;
        while (k < tokens.length && tokens[k].startsWith("-")) k++;
        if (k < tokens.length) {
          h.onScriptToken?.([...frame().chain]);
          i = k + 1;
        } else {
          i++;
        }
      }
      prevWasBoundary = false;
      continue;
    }
    if (t === ".") {
      const next = tokens[i + 1];
      if (next && !next.startsWith("-")) {
        h.onScriptToken?.([...frame().chain]);
        i += 2;
      } else {
        i++;
      }
      prevWasBoundary = false;
      continue;
    }
    if (/^\.{0,2}\//.test(t) && !/^(?:.*\/)?git$/.test(t)) {
      h.onScriptToken?.([...frame().chain]);
      i++;
      prevWasBoundary = false;
      continue;
    }
    // Round-11 (final gate P1): treat ANY token whose basename is `git` as a
    // git invocation start — `/usr/bin/git commit` bypassed the tokenizer's
    // bare-`git` check. ALSO resolve a command-position `$VAR` against
    // prior-segment assignments (`G=git; $G -C <hub> reset --hard` bypassed the
    // ENTIRE gate — allGitInvocations saw no git token; frame().vars already
    // tracks G=git, the value was in hand and unused). Unresolvable `$VAR`
    // command words (`$EDITOR`, `$BROWSER`) fall through (no false-block).
    let isGitToken = /^(?:.*\/)?git$/.test(t);
    if (!isGitToken && prevWasBoundary && /^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?$/.test(t)) {
      const name = t.replace(/^\$\{?/, "").replace(/\}?$/, "");
      const val = frame().vars[name];
      if (val !== undefined) {
        const words = String(val).trim().split(/\s+/);
        if (/^(?:.*\/)?git$/.test(words[0])) {
          if (words.length > 1) {
            // Round-12 (final gate P1): a MULTIWORD git value (`G="git -C <hub>
            // reset"; $G`) cannot be expanded into the invocation shape — the
            // real args live inside the var. Emit an unverifiable marker so the
            // gate fails closed.
            h.onGitEnd?.({
              verb: "__unverifiable__", args: [], cdChain: [...frame().chain], cHints: [],
              gitDirHint: null, workTreeHint: null, indexFileHint: null, objDirsHint: null, configOverrides: [], configEnvOverrides: [], envPrefixes: [], vars: { ...frame().vars },
            });
            i++;
            prevWasBoundary = false;
            continue;
          }
          isGitToken = true;
        }
      }
    }
    if (!isGitToken) {
      // Round-12/14 (final gate P1): a SPAWNER at command position
      // (env/command/sudo/xargs/exec/...) runs its following $VAR as the
      // spawned command. While spawnerPending, keep command position across the
      // spawner's OWN argument tokens (flags, flag operands, env assignments) —
      // `sudo -u root $G` / `env -i $G` resolve `$G` (the old one-token window
      // let `env -i $G reset` run git — probe moved HEAD). `cat $FILE` stays an
      // ordinary arg (cat is not a spawner).
      const isSpawner = prevWasBoundary && SPAWNER_WORDS.has(t);
      h.onOther?.(t);
      i++;
      if (isSpawner) spawnerPending = true;
      prevWasBoundary = spawnerPending; // keep command position while the spawner's args are pending
      continue;
    }
    spawnerPending = false; // a git-resolving token ends the spawner window
    // ── git invocation ──
    i++;
    const f = frame();
    const cHints = [];
    // Cycle-4 P1: -c/--config overrides are captured (key/value pairs) so the
    // gate's OWN config probes (push-remote resolution, _pushRemoteIsSessionHub)
    // see the SAME effective config git uses — `git -c remote.origin.url=<hub>
    // push origin …` silently re-points the push at the hub otherwise.
    // Cycle-5 P1: --config-env=<name>=<envvar> is the env-indirection form.
    const configOverrides = [];
    const configEnvOverrides = [];
    // Round-3 P1: a bare per-command prefix WINS over an exported value (bash:
    // `export GIT_DIR=/a; GIT_DIR=/b git …` runs with /b — probe-verified).
    let gitDirHint = pendingHints.gitDirHint ?? frame().persistHints.gitDirHint ?? null;
    let workTreeHint = pendingHints.workTreeHint ?? frame().persistHints.workTreeHint ?? null;
    let indexFileHint = pendingHints.indexFileHint ?? null;
    let objDirsHint = pendingHints.objDirsHint ?? null;
    const envPrefixes = pendingHints.envPrefixes ? [...pendingHints.envPrefixes] : [];
    pendingHints = {};
    h.onGitStart?.(f);
    // Round-6 (final gate P2): -C/--git-dir/--work-tree/INDEX operands are
    // var-expanded against PRIOR-segment vars at walk time, mirroring the cd
    // path — `VAR=<wt> && git -C "$VAR" commit` froze because the literal
    // `$VAR` resolved as a path. Unresolvable → "\u0000" sentinel (resolveInvocationTarget
    // treats it as conservative — null would be ambiguous with "no hint").
    const expand = (raw) => {
      if (raw === null || raw === undefined) return null;
      const e = _expandCdVars(raw, f.segVars);
      return e === null ? "\u0000" : e;
    };
    while (i < tokens.length) {
      const g = tokens[i];
      if (/^GIT_DIR=/.test(g)) { gitDirHint = expand(g.slice("GIT_DIR=".length)); i++; continue; }
      if (/^GIT_WORK_TREE=/.test(g)) { workTreeHint = expand(g.slice("GIT_WORK_TREE=".length)); i++; continue; }
      if (g === "cd") { i += 2; continue; }
      if (g === "-C" || g === "--cd") { cHints.push(expand(tokens[i + 1] ?? null)); i += 2; continue; }
      if (g.startsWith("--git-dir=")) { gitDirHint = expand(g.slice("--git-dir=".length)); i++; continue; }
      if (g === "--git-dir") { gitDirHint = expand(tokens[i + 1] ?? null); i += 2; continue; }
      if (g.startsWith("--work-tree=")) { workTreeHint = expand(g.slice("--work-tree=".length)); i++; continue; }
      if (g === "--work-tree") { workTreeHint = expand(tokens[i + 1] ?? null); i += 2; continue; }
      if (/^GIT_INDEX_FILE=/.test(g)) { indexFileHint = expand(g.slice("GIT_INDEX_FILE=".length)); i++; continue; }
      if (/^GIT_OBJECT_DIRECTORY=/.test(g) || /^GIT_ALTERNATE_OBJECT_DIRECTORIES=/.test(g)) { objDirsHint = expand(g.slice(g.indexOf("=") + 1)); i++; continue; }
      if (g === "--namespace") { i += 2; continue; }
      if (g.startsWith("--namespace=")) { i++; continue; }
      if (g === "--no-pager" || g === "-p" || g === "--paginate") { i++; continue; }
      if (g === "-c" || g === "--config") { configOverrides.push(tokens[i + 1] ?? "\u0000"); i += 2; continue; }
      if (g === "--config-env") { configEnvOverrides.push(tokens[i + 1] ?? "\u0000"); i += 2; continue; } // cycle-6 P1: space form
      if (g.startsWith("--config-env=")) { configEnvOverrides.push(g.slice("--config-env=".length)); i++; continue; }
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
    while (i < tokens.length && !/^(?:.*\/)?git$/.test(tokens[i])) {
      const g = tokens[i];
      if (_isShellBoundary(g)) {
        // Round-5 (security P2): redirects (+ operands) do NOT terminate a
        // simple command's args — only `; & | && || ( )` do (`git push > /tmp/l
        // origin main:main` must keep its refspec args; truncating them would
        // classify as a bare push of the current branch).
        if (g === ">" || g === ">>" || g === "<" || g === "<<" || g === "&>" || g === ">&" || g === "&>>" || /^(?:[0-9]+)?[<>]/.test(g) || /^[0-9]+[<>]&[0-9]*-?$|^[0-9]+[<>]&-$|^[<>]&[0-9]*-?$|^[<>]&-$/.test(g)) {
          const fdSingle = /^[0-9]+[<>]&[0-9]*-?$|^[0-9]+[<>]&-$|^[<>]&[0-9]*-?$|^[<>]&-$/.test(g); // 2>&1 — no separate operand
          i += fdSingle ? 1 : 2;
          continue;
        }
        break; // real command boundary
      }
      args.push(g);
      i++;
    }
    h.onGitEnd?.({
      verb, args, cHints, gitDirHint, workTreeHint, indexFileHint, objDirsHint,
      configOverrides, configEnvOverrides, envPrefixes,
      cdChain: f.pipeActive ? f.chain.slice(0, f.baseLen) : [...f.chain],
      vars: { ...f.vars },
    });
    prevWasBoundary = false;
  }
  return tokens;
}

/** Extract EVERY git invocation in a compound command (handles
 * `git add . && git commit -m x` — the commit is what decideM2 must gate).
 * Extended shape (#347): per-invocation { verb, args, cdChain, cHints,
 * gitDirHint, workTreeHint, indexFileHint, objDirsHint, vars } — cdChain is
 * subshell- AND pipe-scoped
 * (shared _walkShell; bash semantics, probe-verified). cd targets are
 * var-expanded against PRIOR-segment vars only; an unresolvable `$VAR` (or
 * bare cd / ~ / cd-) pushes a null marker (conservative → no exemption).
 * {verb, args} are unchanged for existing consumers.
 * @returns {Array<{verb: string|null, args: string[], cdChain: Array<string|null>, cHints: string[], gitDirHint: string|null, workTreeHint: string|null, indexFileHint: string|null, objDirsHint: string|null, configOverrides: string[], vars: object}>}
 */
export function allGitInvocations(command, seedVars = {}) {
  const invocations = [];
  _walkShell(command, {
    onGitEnd: (inv) => invocations.push(inv),
  }, seedVars);
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
  if (invocations.length === 0) {
    // Round-5 (security F1): the raw destructive-pattern pass must run BEFORE
    // the zero-invocation early return — `eval "git reset --hard"` /
    // `echo "$(git pull …)"` / backticks collapse to ONE opaque token, so
    // allGitInvocations finds nothing, but the RAW text still matches the
    // legacy patterns (`git reset --hard` inside the string). The old early
    // return made these a full M4/M2/legacy bypass (probe-verified).
    const raw0 = String(command ?? "").trim();
    for (const { name, re } of DESTRUCTIVE_GIT_PATTERNS) {
      if (re.test(raw0)) {
        return { ...out, verdict: `block:${name}` };
      }
    }
    return { ...out, verdict: "allow-non-git" };
  }

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
      // Round-23 (final gate P1): force-create in ANY spelling (attached
      // short-option `-Cmain`/`-Bmain`, long-option equals `--force-create=`)
      // evaded the exact-match flag list and classified the HUB-path checkout
      // as sanctioned recovery (`cd <hub> && git switch -Cmain master` moved
      // refs/heads/main — probe). Block on the spelling family — same as the
      // worktree gate (shared-ref move ≡ branch -f).
      if (["-b", "-B", "-c", "-C", "-f", "--force", "--create", "--force-create", "--orphan", "--detach"].some(flag) ||
          a.some((x) => x.startsWith("--force-create=") || /^-[bBcC][^-]/.test(x))) return "block";
      if (pos.length !== 1 || pos[0] === "." || pos[0] === "-") return "block";
      return pos[0] === "main" || pos[0] === "master" ? "recovery" : "block";
    case "fetch":
    case "pull": {
      // Round-4 (security re-review F3): fetch/pull are sanctioned recovery
      // ONLY when the refspec does not write the protected branch —
      // `git fetch origin +backup:refs/heads/main` redirects main to a
      // non-main history (probe-verified). Only EXPLICIT `:dst` refspecs
      // matter (`git fetch origin main` has an implicit dst under
      // refs/remotes/); a dst of refs/heads/main|master is a shared-branch-ref
      // mutation → block.
      for (const x of a) {
        if (x.includes(":") && (_refspecDst(x) === "main" || _refspecDst(x) === "master")) return "block";
      }
      if (verb === "pull" && !flag("--ff-only")) return "block";
      return "recovery";
    }
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
      // Force/delete/mirror/tags/--all/--prune/--follow-tags and foreign
      // targets → block. Round-3 P1: the `:branch` EMPTY-SOURCE refspec form is
      // a remote-branch DELETION — block it even when the dst matches; a bare
      // `HEAD` refspec resolves to the checked-out branch. #439 P2: git merges
      // no-arg short flags into clusters (`-dq` = -d --quiet) — exact-match
      // misses them, so a cluster made ONLY of push's no-arg short alphabet
      // (v q n u 4 6 d f) containing d or f (push's destructive shorts) blocks.
      // Attached push-option values (`-odraft`, `-uofoo`) contain other letters
      // (o) and are NOT clusters — they keep flowing (cycle-5 probe).
      const hasShortDestructiveCluster = a.some((x) => /^-[vqnu46df]+$/.test(x) && /[df]/.test(x));
      // #439 P2 (cycle-6): git accepts unambiguous long-option PREFIX
      // abbreviations (`--del` = --delete, `--mir` = --mirror) — exact-match
      // misses them. Block any arg that is a strict prefix of a destructive
      // long option (same set the exact list blocks; --force-with-lease is
      // NOT in either set — parity with the existing exact behavior).
      const DESTRUCTIVE_LONGS = ["--delete", "--force", "--mirror", "--prune", "--tags", "--all", "--follow-tags"];
      const hasDestructiveAbbrev = a.some((x) =>
        /^--[a-z][a-z0-9-]*$/.test(x) &&
        DESTRUCTIVE_LONGS.some((opt) => opt.startsWith(x) && x.length < opt.length));
      if (flag("-f") || flag("--force") || flag("--delete") || flag("-d") ||
          hasShortDestructiveCluster || hasDestructiveAbbrev ||
          a.includes("--mirror") || a.includes("--tags") ||
          a.includes("--all") || a.includes("--prune") || a.includes("--follow-tags")) return "block";
      if (!currentBranch) return "block"; // detached hub — push target unknowable
      const refspecs = pos.length > 1 ? pos.slice(1) : [];
      if (refspecs.some((r) => /^\+*:/.test(r))) return "block"; // empty-source = delete
      const dsts = refspecs.length
        ? refspecs.map((r) => (r === "HEAD" ? currentBranch : _refspecDst(r))).filter((x) => x !== null && x !== undefined)
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
 * #436 (B carve-out): extract the deleted branch SHORT names from a branch /
 * push-delete git invocation, or null when the invocation is not a ref-delete
 * OR is outside the MINIMAL SAFE SHAPE SET (fail-closed on ambiguity):
 *   push forms allowed: `git push [origin] --delete <b>...` and
 *     `git push [origin] :<b>...` — the remote (when present) must be
 *     exactly `origin`; NOTHING else may precede the delete flag / colon
 *     targets (git treats pre-flag positionals as delete refspecs too:
 *     `git push origin pr1467 --delete stale` deletes pr1467 AND stale —
 *     probe-verified, #439 P1-1); local-path/URL/`.`/other-name remotes are
 *     refused (a `git push . --delete main` removes the local trunk with no
 *     server gate — #439 P1-2).
 *   branch forms: `git branch -d|-D|--delete <b>...` (merged `-Db` accepted).
 * Main/master targets are NOT filtered here — branchDeleteAllowance blocks
 * them unconditionally.
 * @param {string} verb
 * @param {string[]} args
 * @returns {string[]|null} deleted branch short names, or null
 */
export function branchDeleteNames(verb, args) {
  const a = args || [];
  if (verb === "push") {
    const flagIdx = a.findIndex((x) => x === "--delete" || x.startsWith("--delete="));
    const colonTargets = a.filter((x) => /^:/.test(x));
    if (flagIdx === -1 && colonTargets.length === 0) return null;
    // Leading positionals: with --delete, only a single `origin` remote may
    // precede the flag; any other pre-flag positional is a git delete refspec
    // (P1-1) or a non-origin remote (P1-2) → refuse the carve-out.
    const leading = flagIdx !== -1
      ? a.slice(0, flagIdx).filter((x) => !x.startsWith("-"))
      : a.filter((x) => !x.startsWith("-") && !/^:/.test(x));
    if (leading.length > 1) return null;
    if (leading.length === 1 && leading[0] !== "origin") return null;
    const rawTargets = flagIdx !== -1
      ? a.slice(flagIdx + 1).filter((x) => !x.startsWith("-"))
      : colonTargets;
    const clean = (x) => x
      .replace(/^["']|["']$/g, "")
      .replace(/^:+(refs\/heads\/)?/, "")
      .replace(/^refs\/heads\//, "")
      .replace(/^heads\//, ""); // git dst-inference: `:heads/main` → refs/heads/main (#439 P1)
    const names = [...new Set(rawTargets.map(clean).filter((x) => x.length > 0))];
    return names.length > 0 ? names : null;
  }
  if (verb === "branch") {
    const hasDelete = a.some((x) => x === "-d" || x === "-D" || x === "--delete" ||
      /^-[dD]./.test(x) && !x.startsWith("--"));
    if (!hasDelete) return null;
    const names = [];
    for (const x of a) {
      if (/^-[dD][^-]/.test(x)) { names.push(x.slice(2)); continue; }
      if (x === "-d" || x === "-D" || x === "--delete") continue;
      if (x.startsWith("-") || x === "--") continue;
      names.push(x);
    }
    return names.filter((n) => n.length > 0).length > 0
      ? names.filter((n) => n.length > 0)
      : null;
  }
  return null;
}

/**
 * #436 (B carve-out): branch ref-cleanup allowance for a DISORDERED hub.
 *
 * Deleting a branch that nobody has checked out cannot disturb the dirty set
 * or any sibling session: `git branch -D <b>` of a branch checked out in any
 * worktree is refused by git itself, and `git push --delete <b>` only harms a
 * sibling whose worktree (or the hub) has <b> checked out — hence the
 * checked-out-anywhere gate (mirror of the degradation path's semantics,
 * `index.ts` push-delete block). The hub's own branch is always checked out in
 * the hub → always blocked here.
 *
 * main/master are blocked UNCONDITIONALLY (#439 P1-2): the protected trunk
 * must never be reachable through the carve-out, even when the hub is off-main
 * (a `git push . --delete main` removes the LOCAL trunk with no server gate;
 * the disordered hub cannot restore origin/main). branchDeleteNames already
 * refuses non-origin/local-path/ambiguous push shapes (#439 P1-1).
 *
 * Fail-safe: an unresolvable/empty checkedOutBranches set still blocks a
 * target equal to currentBranch; empty names → no allowance.
 *
 * @param {string[]} targetNames — deleted branch SHORT names.
 * @param {string|null} currentBranch — the hub's checked-out branch.
 * @param {Set<string>} [checkedOutBranches] — branch SHORT names checked out
 *   anywhere (hub + all worktrees); empty/absent → only currentBranch protects.
 * @returns {boolean} true when the delete is collision-free (allow).
 */
export function branchDeleteAllowance(targetNames, currentBranch, checkedOutBranches = new Set()) {
  const names = Array.isArray(targetNames) ? targetNames.filter(Boolean) : [];
  if (names.length === 0) return false; // unparseable targets → no carve-out
  return names.every((n) => {
    if (n === "main" || n === "master") return false; // protected trunk — never allow
    if (n === currentBranch) return false; // the hub's own branch — never allow
    if (checkedOutBranches && checkedOutBranches.has(n)) return false; // a sibling worktree
    return true;
  });
}

/**
 * #436 (B carve-out): collision-free NEW-FILE write decision (pure).
 *
 * A write to a path that does not exist AND is not inside the IMMEDIATE
 * container of a sibling untracked file cannot clobber anything — the exact
 * thing the M4 write freeze protects against. Overwrites of existing files
 * (tracked or untracked) stay blocked (caller checks existence): that is the
 * hub-feature-edit vector (#347 amplifier). Sibling untracked containers come
 * from the EXPANDED porcelain paths (--untracked-files=all).
 *
 * Documented residuals (#439 P2-4, additive-only — the existsSync overwrite
 * gate holds and distinct new filenames never collide in git): (1) only the
 * IMMEDIATE container of an untracked leaf is protected — a deeper tracked
 * dir that merely CONTAINS a sibling's new subdir stays writable (two new
 * files with different names in the same tracked dir are the normal parallel
 * case; git tracks them as distinct untracked paths); (2) paths are compared
 * lexically (resolve-normalized), so a tracked symlink alias pointing into an
 * untracked dir can bypass the container check — warn-only consequence.
 * @param {string} relPath — target path RELATIVE to the hub toplevel.
 * @param {string[]} untrackedPaths — untracked file/dir paths from the
 *   EXPANDED porcelain (classifyUntrackedWip(expanded).untracked).
 * @returns {boolean} true when the new-file write is collision-free (allow).
 */
export function newFileWriteCollisionFree(relPath, untrackedPaths) {
  const rel = String(relPath ?? "").replace(/\\/g, "/").replace(/^\//, "");
  if (!rel || rel.startsWith("../") || rel.split("/").includes("..")) return false;
  const paths = Array.isArray(untrackedPaths) ? untrackedPaths : [];
  for (const raw of paths) {
    const u = String(raw).replace(/^["']|["']$/g, "").replace(/\\/g, "/").replace(/\/$/, "");
    if (!u || u === ".") continue;
    const container = u.includes("/") ? u.slice(0, u.lastIndexOf("/")) : ".";
    if (u === rel) return false; // dirty path itself (paranoia — rel should not exist)
    if (rel.startsWith(u + "/")) return false; // inside an untracked file/dir path
    if (container !== "." && rel.startsWith(container + "/")) return false; // sibling's untracked dir
  }
  return true;
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

/** Verbs whose mutation is provably WORKTREE-LOCAL (working tree + index + the
 * wt's OWN checked-out branch only) — auto-exempt for worktree targets.
 * Everything else (push/update-ref/symbolic-ref/tag/branch/remote/stash/
 * object-store/UNKNOWN verbs like `git subtree push`) is re-classified against
 * the worktree's OWN branch — recovery carve-outs (e.g. push of the wt's
 * branch) apply, everything else blocks. Round-3: INVERTED allowlist — the
 * denylist form let unknown verbs (subtree push of main) and `stash` (shared
 * refs/stash) slip through as auto-exempt (code-review round-3 probes).
 * Worktrees share the hub's REF NAMESPACE (only working tree/index isolated). */
const WORKTREE_LOCAL_VERBS = new Set([
  "commit", "add", "rm", "mv", "restore", "checkout", "switch", "reset",
  "merge", "rebase", "cherry-pick", "revert", "clean", "apply", "am", "pull",
]);

function _mainProtectionReason(inv, ...notes) {
  const note = notes.join(" "); // round-21 (P2): variadic — 7 call sites pass TWO literals
  return [
    `⛔ Hub-state gate (M4): the shared main checkout is OFF-MAIN or DIRTY (#1484).`,
    `   Blocked: \`git ${inv.verb} ${inv.args.join(" ")}\``,
    `   ${note}`,
    `   → Terminal recovery: cd <repo> && git checkout main && git pull --ff-only`,
    `   → Feature work: bash scripts/checkout-hygiene/hub-worktree.sh <branch>`,
  ].join("\n");
}

/** Common-dir identity helpers (#397 cycle-2 closures): repo identity is the
 * git-common-dir — a session worktree ALWAYS shares the session repo's common
 * dir, a foreign worktree NEVER does, and a push remote whose path resolves
 * into the session repo (hub, its worktrees, or a bare repo) is the hub's own
 * ref store. `git -C <dir> rev-parse --git-common-dir` returns a relative path
 * from a main checkout / absolute from a worktree — both normalized here. */
function _repoCommonDir(repoDir) {
  try {
    const raw = execFileSync("git", ["-C", repoDir, "rev-parse", "--git-common-dir"], {
      encoding: "utf-8", timeout: 5000, stdio: ["ignore", "pipe", "ignore"],
    }).trim();
    return _realpathSafe(raw.startsWith("/") ? raw : resolve(repoDir, raw));
  } catch {
    return null; // not a git repo / git failure
  }
}

function _gitdirCommonDir(gitDir) {
  try {
    const raw = execFileSync("git", ["--git-dir=" + gitDir, "rev-parse", "--git-common-dir"], {
      encoding: "utf-8", timeout: 5000, stdio: ["ignore", "pipe", "ignore"],
    }).trim();
    return _realpathSafe(raw.startsWith("/") ? raw : resolve(gitDir, raw));
  } catch {
    return null;
  }
}

/** Issue #397 (cycle-2 P2 closure): the foreignWorktree tag must be repo-
 * identity-checked, not frame-implied. If the SESSION map's whole build
 * transiently fails (empty map) while the invocation-frame build succeeds, a
 * SESSION worktree would be tagged foreign → shared-ref/main-protection
 * fail-open. A session wt always shares the session repo's common dir; a
 * foreign wt never does. Conservative direction (cycle-3 P2): ANY probe
 * failure → treat as the SESSION repo (never foreign-tag a possibly-session
 * worktree); only a PROVEN common-dir mismatch (both probes succeed, dirs
 * differ) means foreign. */
function _sameRepoAsSession(gitDir, sessionCwd) {
  const gdCommon = _gitdirCommonDir(gitDir);
  const sCommon = _repoCommonDir(resolve(sessionCwd));
  if (gdCommon === null || sCommon === null) return true; // unverifiable → conservative: same repo
  return gdCommon === sCommon;
}

/** Issue #397 (cycle-2 P1 closure): a push/fetch whose remote operand resolves
 * into the SESSION HUB's repo (same git-common-dir identity — covers the hub,
 * its worktrees, and bare repos) rewrites the hub's OWN refs — the exact state
 * M4 protects — so the foreign carve-out must NOT exempt it. Handles every
 * operand form git accepts: scheme URLs (file:// is a LOCAL transport —
 * stripped and identity-checked; http/ssh/git/git@host:path are non-local and
 * stay exempt — the documented residual: a NON-local URL can still advance the
 * session repo's REMOTE refs; its LOCAL refs are unreachable), CONFIGURED
 * remote names (resolved via remote.<name>.pushurl/.url and re-classified —
 * cycle-3 P1: `remote add hub <hub-path>` then `push hub main` rewrote the
 * hub's local main, demonstrated), and direct local paths (absolute or
 * relative — resolved against the invocation's effective cwd, git -C
 * semantics). Bare pushes resolve the effective remote (remote.pushDefault →
 * branch.<cur>.remote → origin). A local-path-looking operand that cannot be
 * resolved FAILS CLOSED (block — git would fail the push anyway).
 * @param {{verb:string,args:string[]}} inv
 * @param {object|null} target — resolveInvocationTarget output (gitDir /
 *   effectiveCwd / worktreeBranch used)
 * @param {string} sessionCwd
 */
/** Effective git config overrides for the gate's OWN probes (cycles 4-5 P1
 * closures): -c/--config pairs, --config-env=<name>=<envvar> indirections
 * (resolved against statement vars → env prefixes → process.env), GIT_CONFIG_*
 * env prefixes, and statement GIT_CONFIG_* vars — so the probes see the SAME
 * effective config git uses (`-c remote.origin.url=<hub>` / `HUBPUSH=<hub> git
 * --config-env=remote.origin.url=HUBPUSH push …` silently re-point a foreign
 * push at the hub otherwise). Returns { cfgArgs, cfgEnv } to spread onto
 * execFileSync. */
function _effectiveConfig(inv) {
  const cfgArgs = [];
  for (const o of inv.configOverrides || []) {
    if (o && o !== "\u0000") cfgArgs.push("-c", o);
  }
  for (const ce of inv.configEnvOverrides || []) {
    const eq = ce.indexOf("=");
    if (eq <= 0) continue;
    const name = ce.slice(0, eq), envName = ce.slice(eq + 1);
    const val = (inv.vars && inv.vars[envName]) ??
      (inv.envPrefixes || []).map((p) => { const e = p.indexOf("="); return e > 0 && p.slice(0, e) === envName ? p.slice(e + 1) : null; }).find((v) => v !== null) ??
      process.env[envName];
    if (val !== undefined && val !== null) cfgArgs.push("-c", `${name}=${val}`);
  }
  const cfgEnv = {};
  for (const p of inv.envPrefixes || []) {
    const eq = p.indexOf("=");
    if (eq > 0 && p.startsWith("GIT_CONFIG_")) cfgEnv[p.slice(0, eq)] = p.slice(eq + 1);
  }
  try {
    const n = Number(inv.vars && inv.vars.GIT_CONFIG_COUNT);
    if (Number.isInteger(n) && n > 0 && n <= 64) {
      for (let k = 0; k < n; k++) {
        const key = inv.vars && inv.vars[`GIT_CONFIG_KEY_${k}`];
        if (key) cfgEnv[`GIT_CONFIG_KEY_${k}`] = key, cfgEnv[`GIT_CONFIG_VALUE_${k}`] = (inv.vars && inv.vars[`GIT_CONFIG_VALUE_${k}`]) ?? "";
      }
      cfgEnv.GIT_CONFIG_COUNT = String(n);
    }
  } catch { /* malformed count → ignore */ }
  return { cfgArgs, cfgEnv };
}

/** Issue #397 (cycle-2 P1 closure): a push/fetch whose remote operand resolves
 * into the SESSION HUB's repo (same git-common-dir identity — covers the hub,
 * its worktrees, and bare repos) rewrites the hub's OWN refs — the exact state
 * M4 protects — so the foreign carve-out must NOT exempt it. Handles every
 * operand form git accepts: scheme URLs (file:// is a LOCAL transport —
 * stripped and identity-checked; http/ssh/git/git@host:path are non-local and
 * stay exempt — the documented residual: a NON-local URL can still advance the
 * session repo's REMOTE refs; its LOCAL refs are unreachable), CONFIGURED
 * remote names (resolved via remote.<name>.pushurl/.url — INCLUDING
 * -c/--config/--config-env/GIT_CONFIG_* overrides — and re-classified),
 * `--repo=` (a FALLBACK only — git: the positional <repository> takes
 * precedence), and direct local paths (absolute or relative — resolved against
 * the invocation's effective cwd, git -C semantics). Bare pushes (and
 * refspec-first forms like `push HEAD:main`) resolve the effective remote
 * (remote.pushDefault → branch.<cur>.remote → origin). A local-path-looking
 * operand that cannot be resolved FAILS CLOSED (block — git would fail the
 * push anyway).
 * @param {{verb:string,args:string[],configOverrides?:string[],configEnvOverrides?:string[],envPrefixes?:string[],vars?:object}} inv
 * @param {object|null} target — resolveInvocationTarget output (gitDir /
 *   effectiveCwd / worktreeBranch used)
 * @param {string} sessionCwd
 */
function _pushRemoteIsSessionHub(inv, target, sessionCwd) {
  const gitDir = target && target.gitDir;
  // 0. effective config for the gate's own probes (cycle-4/5 P1 closures)
  const { cfgArgs, cfgEnv } = _effectiveConfig(inv);
  const gitConfigGet = (key) => {
    try {
      return execFileSync("git", [...cfgArgs, "--git-dir=" + gitDir, "config", "--get", key], {
        encoding: "utf-8", timeout: 5000, stdio: ["ignore", "pipe", "ignore"],
        env: { ...process.env, ...cfgEnv },
      }).trim();
    } catch { return ""; } // key unset → empty (git config --get exits 1 on missing keys)
  };
  // 1. remote operand: the first non-option positional is the <repository>
  // (git: the positional TAKES PRECEDENCE over --repo — cycle-5 P1);
  // value-taking options skip their value token (cycle-3/5/6 P1s: -o/
  // --push-option/--repo/--receive-pack/--exec/--upload-pack/--depth/--refmap,
  // plus combined short forms like -fo = -f -o <v>); --repo's value is the
  // FALLBACK when no positional repository exists; a refspec-looking first
  // positional (`src:dst` / `:dst`, non-scheme, non-scp) is NOT a repository.
  const VALUE_OPTS = new Set(["-o", "--push-option", "--repo", "--receive-pack", "--exec", "--upload-pack", "--depth", "--refmap", "--jobs"]);
  const args = inv.args || [];
  let remote = null;
  let repoFallback = null;
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (VALUE_OPTS.has(a)) { if (a === "--repo") repoFallback = args[i + 1] ?? null; i++; continue; }
    if (a.startsWith("--repo=")) { repoFallback = a.slice("--repo=".length); continue; }
    if (a.startsWith("-")) {
      // combined short flags whose LAST letter takes a value (-fo = -f -o <v>)
      if (/^-[^-]{2,}$/.test(a) && a.endsWith("o")) { i++; continue; }
      continue;
    }
    if (a.includes(":") && !/^[A-Za-z][A-Za-z0-9+.-]*:\/\//.test(a) && !/^[^/\s]+@[^/\s]+:/.test(a)) continue; // refspec (`src:dst`/`:dst`/`+src:dst`) — not a repo operand
    remote = a;
    break;
  }
  if (remote === null) remote = repoFallback;
  // 2. bare push → effective remote (push.default chain); none → no vector
  if (remote === null && gitDir) {
    remote = gitConfigGet("remote.pushDefault");
    if (!remote && target.worktreeBranch) remote = gitConfigGet(`branch.${target.worktreeBranch}.remote`);
    if (!remote) {
      try {
        const remotes = execFileSync("git", [...cfgArgs, "--git-dir=" + gitDir, "remote"], {
          encoding: "utf-8", timeout: 5000, stdio: ["ignore", "pipe", "ignore"],
          env: { ...process.env, ...cfgEnv },
        }).split("\n").filter(Boolean);
        if (remotes.includes("origin")) remote = "origin";
      } catch { /* no default remote resolvable */ }
    }
  }
  if (remote === null) return false;
  // 3. classify the operand → local repo path or null (non-local transport)
  const toPath = (s) => {
    if (/^file:\/\//.test(s)) {
      // file:// is a LOCAL transport — strip the scheme + an optional
      // localhost HOST ONLY (never the path's leading slash — cycle-4 P1:
      // `file://localhost/private/…` must keep `/private/…`).
      let p = s.slice("file://".length);
      if (p.startsWith("localhost")) p = p.slice("localhost".length);
      return /^[^/]/.test(p) ? null : p; // file://host/... — non-local host
    }
    if (/^[A-Za-z][A-Za-z0-9+.-]*:\/\//.test(s) || /^[^/\s]+@[^/\s]+:/.test(s)) return null;
    return s; // local path (absolute or relative)
  };
  let repoPath = null;
  if (/^[A-Za-z][A-Za-z0-9+.-]*:\/\//.test(remote) || /^[^/\s]+@[^/\s]+:/.test(remote)) {
    repoPath = toPath(remote); // file:// → path; http/ssh/git/scp → null (exempt)
  } else if (gitDir) {
    // pushurl overrides url; each lookup independently (missing key exits 1 —
    // a shared try/catch would abort the whole resolution, cycle-3 debug).
    const pushUrl = gitConfigGet(`remote.${remote}.pushurl`);
    const url = pushUrl || gitConfigGet(`remote.${remote}.url`);
    repoPath = url ? toPath(url) : toPath(remote); // not configured → treat operand as a local path (conservative)
  } else {
    repoPath = toPath(remote);
  }
  if (repoPath === null) return false; // non-local transport — documented residual
  const base = target && target.effectiveCwd ? resolve(target.effectiveCwd) : resolve(sessionCwd);
  // cycle-4 P3: expand a leading ~/ (the shell would have before git saw it)
  const expanded = repoPath.startsWith("~/") ? join(homedir(), repoPath.slice(2)) : repoPath;
  const targetReal = _realpathSafe(resolve(base, expanded));
  if (targetReal === null) return true; // local-path-looking operand unresolvable → FAIL CLOSED
  const tCommon = _repoCommonDir(targetReal);
  const sCommon = _repoCommonDir(resolve(sessionCwd));
  return tCommon !== null && sCommon !== null && tCommon === sCommon;
}

/** Issue #397 hardening — fail loudly, never move the wrong branch. Verifies
 * that a sanctioned-recovery `git checkout <branch>` (main/master only — the
 * recovery target) can actually succeed in the repo owning `gitDir`: the
 * branch exists locally (refs/heads/&lt;b&gt;) or has a UNIQUE remote-tracking DWIM
 * source (exactly one refs/remotes/&lt;configured-remote&gt;/&lt;b&gt; — git's checkout
 * --guess iterates CONFIGURED remotes, so a crafted tracking ref with no
 * configured remote does NOT DWIM, and a multi-remote match is ambiguous →
 * checkout fails). Tag refs do NOT satisfy the check (a tag checkout lands
 * detached, not on the branch). Any git read failure → false (conservative:
 * never bless a possibly-doomed checkout).
 * Mirrors git's own decision surface so the gate fails loudly BEFORE the
 * checkout runs — `git checkout -q main 2>/dev/null` swallows the failure,
 * the agent proceeds believing it is on main, and the next destructive op
 * moves the CURRENT branch (2026-08-30 #387: a swallowed checkout failure
 * preceded a reset that moved feat/387-ci-central to main).
 * Residuals (documented, out of micro scope): `git -c checkout.guess=false`
 * disables DWIM entirely (the gate still blesses a DWIM-able checkout — the
 * failure is then VISIBLE unless stderr is swallowed); a dirty working tree
 * can still fail the checkout at run time (predicting conflicts requires a
 * side-effecting probe). The hardening closes the SILENT-failure class.
 * @param {string} gitDir — the invocation's resolved git-dir (session hub's
 *   .git, or a worktree admin dir; refs + remote config are repo-global so
 *   either resolves).
 * @param {string} branch — "main" / "master" (recovery targets only).
 * @param {object} [inv] — the invocation (configOverrides/envPrefixes threaded
 *   into the probes — cycle-5 P3: a crafted `-c remote.origin.fetch=…` must
 *   not diverge the gate's DWIM view from git's).
 */
function _recoveryCheckoutVerifiable(gitDir, branch, inv) {
  const { cfgArgs, cfgEnv } = _effectiveConfig(inv);
  const run = (args) => execFileSync("git", [...cfgArgs, "--git-dir=" + gitDir, ...args], {
    encoding: "utf-8", timeout: 5000, stdio: ["ignore", "pipe", "ignore"], env: { ...process.env, ...cfgEnv },
  });
  try {
    run(["show-ref", "--verify", "--quiet", "refs/heads/" + branch]);
    return true; // local branch exists
  } catch {
    /* fall through to the DWIM check */
  }
  // DWIM (git checkout --guess / unique_tracking_name): count the configured
  // remotes whose FETCH REFSPEC maps refs/heads/<b> onto an EXISTING tracking
  // ref. A planted refs/remotes/* entry whose remote has no matching fetch
  // refspec does NOT DWIM (git refuses — cycle-2 P3 probe); non-standard
  // refspec destinations (e.g. refs/remotes/mirror/*) are honored exactly like
  // git does. Per-refspec matching also handles multi-component remote names
  // (`origin/sub` → refs/remotes/origin/sub/*). Exactly one matching remote =
  // git's ambiguity contract (0 or 2+ → checkout fails).
  let matches = 0;
  try {
    const remotes = run(["remote"]).split("\n").filter((n) => n.length > 0);
    for (const r of remotes) {
      const fetches = (() => {
        try {
          return run(["config", "--get-all", `remote.${r}.fetch`]).split("\n").filter((n) => n.length > 0);
        } catch {
          return []; // no fetch refspec configured → this remote is no DWIM source
        }
      })();
      for (const f of fetches) {
        const fq = f.replace(/^\+/, ""); // drop the forced flag
        const [src, dst] = fq.split(":");
        if (!src || !dst) continue;
        const si = src.indexOf("*"), di = dst.indexOf("*");
        if (si === -1 || di === -1) continue; // single-refspec — not a heads mapping
        if (src.slice(0, si) !== "refs/heads/" || src.slice(si + 1) !== "") continue; // must cover refs/heads/*
        const mapped = dst.slice(0, di) + branch + dst.slice(di + 1);
        try {
          run(["show-ref", "--verify", "--quiet", mapped]);
          matches++;
          break; // one matching refspec per remote
        } catch {
          /* tracking ref absent — keep scanning */
        }
      }
    }
  } catch {
    return false; // git read failure → conservative: refuse to bless the checkout
  }
  return matches === 1;
}

/** Shared block-reason for the recovery-checkout hardening (#397) — loud +
 * actionable (fail loudly, never move the wrong branch). */
function _recoveryCheckoutBlockReason(inv, branch) {
  return [
    `⛔ Hub-state gate (M4): the shared main checkout is OFF-MAIN or DIRTY (#1484).`,
    `   Blocked: \`git ${inv.verb} ${branch}\` — no branch "${branch}" exists in the target`,
    `   repo (no refs/heads/${branch}, no unique remote-tracking DWIM source; a tag named`,
    `   "${branch}" would check out DETACHED, not the branch).`,
    `   A silently-failed checkout strands the repo on the CURRENT branch while the agent`,
    `   believes it is on "${branch}" — a subsequent destructive op would move the WRONG`,
    `   branch (#397).`,
    `   → Reconcile branch state first: \`git checkout -b ${branch} origin/${branch}\``,
    `     (or \`git fetch\`) then retry.`,
  ].join("\n");
}

/** Round-10 (final gate P1): paren-balanced extraction of $( … ) and backtick
 * spans from a token (a naive `[^)]*` truncated at the FIRST `)` — nested
 * substitutions evaded; security reviewer probe destroyed a hub commit). */
function _extractSubstitutionSpans(token) {
  const spans = [];
  let i = 0;
  while (i < token.length) {
    if (token[i] === "$" && token[i + 1] === "(") {
      let depth = 1, j = i + 2;
      while (j < token.length && depth > 0) {
        if (token[j] === "(") depth++;
        else if (token[j] === ")") depth--;
        j++;
      }
      spans.push(token.slice(i + 2, Math.max(i + 2, j - 1)));
      i = j;
    } else if (token[i] === "`") {
      const j = token.indexOf("`", i + 1);
      spans.push(token.slice(i + 1, j > -1 ? j : token.length));
      i = j > -1 ? j + 1 : token.length;
    } else {
      i++;
    }
  }
  return spans;
}

/** Shell words that SPAWN a command — a `$VAR` in their ARGUMENTS is the
 * spawned command (`$(env $G reset)` = `git reset`; `$(cat $FILE)` is safe —
 * cat is not a spawner). */
const SPAWNER_WORDS = new Set(["env", "sudo", "command", "xargs", "exec", "nohup", "nice", "time", "timeout", "stdbuf", "setsid", "eval", "sh", "bash", "zsh", "dash", "ksh"]);

/** Compound-command reserved words (round-13): they start a new command-word
 * position — a following `$VAR` must resolve as the command. */
const COMPOUND_WORDS = new Set(["for", "do", "done", "if", "then", "else", "elif", "fi", "while", "until", "select", "!", "case", "esac"]);

/** Does a substitution span carry an unverifiable git execution? Token-level
 * scan: literal git; a `$VAR` as the first command token (skipping leading env
 * assignments); an interpreter or path as the first command token (script-in-
 * substitution); a SPAWNER at command position (start or after pipe/`;`) with
 * any `$VAR` argument. Recurses into nested substitutions (paren-balanced). */
function _spanCarriesGit(inner, cmdVars = {}) {
  // Literal git in the span: classify each git invocation — READ-ONLY and
  // sanctioned-recovery verbs pass (`git describe`, `git status` in a commit
  // message must NOT re-freeze the worktree commit — second-model P1);
  // mutations/unknown verbs fail closed. A bare prose "git" word (no
  // invocation) passes.
  for (const gi of allGitInvocations(inner, cmdVars)) { // round-13: seed with command assignments — mid-span $VAR resolves
    if (gi.verb === "__unverifiable__") return true;
    // Round-13 (second-model P1): `git symbolic-ref <non-HEAD>` is a shared-ref
    // mutation on the direct surface (T64) but isHubRecoveryInvocation returns
    // "readonly" — mirror the special case here so the substitution surface
    // does not re-open it.
    if (gi.verb === "symbolic-ref" && !(gi.args || []).includes("HEAD")) return true;
    if (gi.verb && isHubRecoveryInvocation(gi.verb, gi.args, null) === "block") return true;
  }
  for (const sub of _extractSubstitutionSpans(inner)) {
    if (_spanCarriesGit(sub, cmdVars)) return true;
  }
  const t = _tokenize(inner);
  let k = 0;
  while (k < t.length && (/^[A-Za-z_][A-Za-z0-9_]*=/.test(t[k]) || t[k] === "{" || t[k] === "}")) k++; // env prefixes + brace-group openers (R11-4)
  const first = t[k];
  if (first === undefined) return false;
  if (/^\$(\{[A-Za-z_][A-Za-z0-9_]*\}|[A-Za-z_][A-Za-z0-9_]*)/.test(first)) {
    // $VAR as command: resolve against the command's own assignments
    // (`G=git; $( { $G reset; } )` — the outer G is known here; R11-4).
    // Unassigned (env-provided $EDITOR) passes.
    const name = first.replace(/^\$\{?/, "").replace(/\}?$/, "");
    if (cmdVars[name] !== undefined && /^(?:.*\/)?git$/.test(String(cmdVars[name]).trim().split(/\s+/)[0])) return true;
    return false;
  }
  if (SHELL_INTERPRETERS.has(first) || /^\.{0,2}\//.test(first)) return true; // interpreter/path
  for (let i = k; i < t.length; i++) {
    if (SPAWNER_WORDS.has(t[i]) && (i === k || t[i - 1] === "|" || t[i - 1] === ";")) {
      if (t.slice(i + 1).some((a) => /\$/.test(a))) return true;
    }
  }
  return false;
}

/** Round-6+: content-scoped UNVERIFIABLE-git detection. The invocation walk
 * cannot see git inside $( ) / backticks / eval / alias / function indirection
 * / piped-stdin shells (they collapse to opaque tokens or bypass the walk).
 * Fail closed while the hub is disordered — but only for the construct's OWN
 * content (a worktree-exempt `git commit` before a `$(date)` must not
 * false-block). */
function _unverifiableGitContent(command) {
  const c = String(command ?? "");
  // Command-level assignments — the $VAR command-word resolution in spans and
  // -c inlines resolves against these (`G=git; $( { $G reset; } )` — the nested
  // walk's fresh frame has no G, but the OUTER command assigned it; R11-4).
  const cmdVars = {};
  for (const m of c.matchAll(/(?:^|[;&|\s])(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=([^\s;&|]+)/g)) {
    cmdVars[m[1]] = m[2];
  }
  // Round-19 (final gate P1): process substitution `<( echo 'git …' )` feeds
  // a shell interpreter a script with NO file — the content is executable
  // text (probe: `bash <(echo 'git commit')` committed to the hub). Classify
  // the <( )/>( ) spans like $() content.
  for (const m of c.matchAll(/[<>]\(([^)]*)\)/g)) {
    // The FD's CONTENT is what the shell executes — a git word ANYWHERE in the
    // substitution output is unverifiable (bash <(echo 'git commit') runs git;
    // `bash <(echo 'git status')` is conservatively blocked too — the gate
    // cannot evaluate echo's output).
    if (/\bgit\b/.test(m[1] ?? "") || _spanCarriesGit(m[1] ?? "")) return true;
  }
  // Round-11 (security P1): span extraction on the RAW command (unquoted
  // `$( … )` splits into `$`/`(` tokens — the token-level scan missed them).
  for (const inner of _extractSubstitutionSpans(c)) {
    if (_spanCarriesGit(inner, cmdVars)) return true;
  }
  const tokens = _tokenize(c);
  for (const t of tokens) {
    for (const inner of _extractSubstitutionSpans(t)) {
      if (_spanCarriesGit(inner, cmdVars)) return true;
    }
  }
  // Round-14 (final gate P1): heredoc bodies fed to a shell interpreter are
  // executable text (`cat <<'EOF' | sh` + `git -C <hub> reset` moved HEAD —
  // probe; the piped-stdin closure's remaining open syntax). A heredoc + a
  // shell interpreter + git content is unverifiable → fail-closed.
  if (/<</.test(c) && /(?:^|[\s|;])(?:sh|bash|zsh|dash|ksh)\b/.test(c) && /\bgit\b/.test(c)) return true;
  // Round-11 (final gate P1): an interpreter `-c` inline command starting with
  // a $VAR command word that is ASSIGNED in the command is unverifiable —
  // `export G=git; sh -c '$G reset'` fails closed; `sh -c '$EDITOR x'` (env
  // var, not command-assigned) passes (the second-model's no-blanket-block
  // warning).
  const cInlineVar = c.match(/\b(?:sh|bash|zsh|dash|ksh)\s+-c\s+['"]?\$(\{?[A-Za-z_][A-Za-z0-9_]*\}?)/);
  if (cInlineVar) {
    const name = cInlineVar[1].replace(/[{}]/g, "");
    if (new RegExp(`(?:^|[;&|\\s])(?:export\\s+)?${name}=`).test(c)) return true;
  }
  for (let i = 0; i < tokens.length; i++) {
    const t = tokens[i];
    if (t === "eval") {
      const rest = tokens.slice(i + 1, i + 4).join(" ");
      if (/\bgit\b/.test(rest) || _spanCarriesGit(rest, cmdVars)) return true; // round-12: pass cmdVars — `eval $G` resolves
    }
    if ((t === "alias" || t === "function") && tokens[i + 1]) {
      const def = tokens.slice(i + 1, i + 3).join(" ");
      if (/\bgit\b/.test(def)) return true;
    }
  }
  // Round-10/11 (security P1): piped-stdin shell — `printf 'git …' | bash` runs
  // the piped text as commands. Classify the PIPED CONTENT (tokens between the
  // pipe and a shell interpreter at ANY position — `| bash | cat`, `| bash -s`
  // evaded the final-segment rule): mutations/unknowns/$VAR-command → block;
  // read-only/recovery content (`echo 'git log' | bash`) passes.
  const tokensAll = tokens;
  for (let i = 0; i < tokensAll.length; i++) {
    if (tokensAll[i] === "|" && i + 1 < tokensAll.length && SHELL_INTERPRETERS.has(tokensAll[i + 1])) {
      const piped = tokensAll.slice(0, i).join(" ");
      const pInns = allGitInvocations(piped);
      if (pInns.length === 0) {
        // Literal git text piped to a shell — classify the raw `git <verb>`
        // occurrences (a `printf 'git log' | bash` passes — readonly; a
        // `printf 'git reset' | bash` blocks).
        const verbs = [...piped.matchAll(/\bgit\s+([A-Za-z][A-Za-z0-9-]*)/g)].map((m) => m[1]);
        if (verbs.some((v) => isHubRecoveryInvocation(v, [], null) === "block")) return true;
        if (piped.includes("git") && /\$[A-Za-z_]/.test(piped)) return true; // $VAR + git text → unverifiable
      }
      for (const pi of pInns) {
        if (pi.verb && isHubRecoveryInvocation(pi.verb, pi.args, null) === "block") return true;
      }
      continue; // round-12 (second-model P1): scan EVERY pipe-to-shell segment — the
      // old `return false` after the first clean segment let `echo x | bash &&
      // printf 'git reset' | sh` through (the second segment ran the hub reset).
    }
  }
  return false;
}

/** Round-20 (second-model P1): checkout/switch force-create and main-protection
 * shared by the bash gate AND scriptGitVerdict (the script surface previously
 * lacked these — `cd <wt> && bash evil.sh` with `git checkout -B main` content
 * force-moved the protected branch while the hub was disordered; probe).
 * force-create (-B/-C/--force-create) with a positional target is `git branch
 * -f` in disguise — a SHARED-ref move, not worktree-local (`branch -f` and
 * `update-ref` are already blocked). Returns a block reason or null. */
function _worktreeCheckoutBlock(inv, target, currentBranch) {
  const args = inv.args || [];
  const pos = args.filter((x) => !x.startsWith("-"));
  // Round-21 (final gate P1): attached short-option args (`-Cmain` ≡ `-C
  // main`, `-Bfeat/x` ≡ `-B feat/x`) and bare/dash forms (`checkout -B -`)
  // evaded the exact-match + pos-length check — probe: `switch -Cmain` moved
  // refs/heads/main. Block on the MERE PRESENCE of a force-create flag (a
  // bare `-B`/`-C` is malformed anyway — blocking is harmless).
  const hasForceMove = args.some((x) => x === "-B" || x === "-C" || x === "--force-create" || x.startsWith("--force-create=") || /^-[BC][^-]/.test(x));
  if (hasForceMove) {
    return _mainProtectionReason(inv,
      `force-create checkout/switch moves a SHARED branch ref (≡ git branch -f) — not worktree-local.`);
  }
  if (pos.length >= 1 && (pos[0] === "main" || pos[0] === "master") &&
      currentBranch !== "main" && currentBranch !== "master") {
    return _mainProtectionReason(inv,
      `checkout/switch of the hub's protected branch "${pos[0]}" from a worktree while the hub`,
      `is off-main — the wt would take it and its commits/pushes would mutate it.`);
  }
  if (target.worktreeBranch === "main" || target.worktreeBranch === "master") {
    return _mainProtectionReason(inv,
      `The worktree is checked out on the hub's protected branch "${target.worktreeBranch}" —`,
      `its mutations would advance the shared main ref.`);
  }
  return null;
}

/** #347 — evaluateHubGate with PER-INVOCATION target resolution. Classify
 * first (recovery/readonly → zero resolution cost — sanctioned regardless of
 * target); on a `block` verdict, resolve the invocation's effective target and
 * EXEMPT it when it is an isolated worktree (worktree-list membership + cwd
 * containment) AND the verb is worktree-LOCAL (round-3 inverted allowlist).
 * Shared-ref/unknown verbs are re-classified against the worktree's own branch
 * (code-review #4/round-3). Main-protection (round-3 P1): a worktree on
 * main/master is the hub's protected branch — mutations block; `checkout main`
 * from a worktree while the hub is OFF-main (main free) blocks. Anything else
 * (hub, foreign, unresolvable) keeps today's block. Same verdict vocabulary as
 * evaluateHubGate (non-git/allowed/recovery/block); evaluateHubGate stays
 * contract-identical for existing callers/tests.
 * @param {string} command
 * @param {string|null} currentBranch — hub's checked-out branch (push carve-out)
 * @param {string} [sessionCwd] — session root; the worktree MAP is derived here
 *   (M4 only fires when session cwd IS the hub).
 */
export function evaluateHubGateWithTargets(command, currentBranch, sessionCwd = process.cwd(), checkedOutBranches = null) {
  const invocations = allGitInvocations(command);
  // Round-5/6 (second-model P1): eval / $( ) / backtick / alias / function
  // command substitution is an UNVERIFIABLE one-token shell construct — the
  // substituted content runs ungated by the invocation walk. Fail closed BEFORE
  // the invocation loop (a preceding worktree-exempt `continue` must not skip
  // the check): if any substitution/indirection content carries git, block while
  // the hub is disordered (content-scoped — `git commit -m "$(date)"` passes).
  if (_unverifiableGitContent(command)) {
    return {
      verdict: "block",
      reason: [
        `⛔ Hub-state gate (M4): the shared main checkout is OFF-MAIN or DIRTY (#1484).`,
        `   Blocked: command substitution / eval / alias indirection with git content — the`,
        `   substituted invocation cannot be verified per-invocation (fail-closed).`,
        `   → Terminal recovery: cd <repo> && git checkout main && git pull --ff-only`,
        `   → Feature work: bash scripts/checkout-hygiene/hub-worktree.sh <branch>`,
      ].join("\n"),
    };
  }
  if (invocations.length === 0) return { verdict: "non-git" };
  let sawRecovery = false;
  let exempted = false;
  for (const inv of invocations) {
    if (!inv.verb) continue;
    if (inv.verb === "__unverifiable__") {
      return {
        verdict: "block", exempted: false,
        reason: [
          `⛔ Hub-state gate (M4): the shared main checkout is OFF-MAIN or DIRTY (#1484).`,
          `   Blocked: unverifiable \$VAR command expansion (multiword git value) —`,
          `   the expanded invocation cannot be classified per-invocation (fail-closed).`,
          `   → Terminal recovery: cd <repo> && git checkout main && git pull --ff-only`,
          `   → Feature work: bash scripts/checkout-hygiene/hub-worktree.sh <branch>`,
        ].join("\n"),
      };
    }
    const v = isHubRecoveryInvocation(inv.verb, inv.args, currentBranch);
    // Main-protection interception for the SANCTIONED form: `checkout main` from
    // a worktree while the hub is off-main lets the wt take the protected branch
    // (git allows it — main is free) and then commit/push mutate main.
    if (v === "recovery" && (inv.verb === "checkout" || inv.verb === "switch")) {
      const pos = (inv.args || []).filter((x) => !x.startsWith("-"));
      if (pos.length === 1 && (pos[0] === "main" || pos[0] === "master")) {
        const target = resolveInvocationTarget(inv, sessionCwd, sessionCwd);
        if (target) {
          // Issue #397 hardening — fail loudly, never move the wrong branch: a
          // sanctioned-recovery checkout of main/master whose branch CANNOT be
          // checked out in the target repo (no refs/heads/<b>, no unique
          // remote-tracking DWIM source) is refused loudly. Applies regardless
          // of the session hub's branch: the checkout's success depends on the
          // TARGET repo's refs, and a foreign-repo checkout is otherwise
          // unobserved by the gate. `git checkout -q main 2>/dev/null` swallows
          // the failure, the agent proceeds believing it is on main, and the
          // next destructive op runs against the CURRENT branch (2026-08-30
          // #387: a swallowed checkout failure preceded a reset that moved
          // feat/387-ci-central to main).
          if (!_recoveryCheckoutVerifiable(target.gitDir, pos[0], inv)) {
            return {
              verdict: "block", exempted: false,
              reason: _recoveryCheckoutBlockReason(inv, pos[0]),
            };
          }
          // Main-protection guards the SESSION hub's protected branch. A
          // FOREIGN worktree (different repo than the session hub — recognized
          // via the invocation-frame map fallback) taking its OWN repo's main
          // is the foreign repo's business: git repos never share ref
          // namespaces, so the wt cannot advance the session hub's main
          // (2026-08-30 #387: agent-infra worktree ops from a tortoise session).
          if (currentBranch !== "main" && currentBranch !== "master" &&
              target.isWorktree && !target.foreignWorktree &&
              target.worktreeBranch !== "main" && target.worktreeBranch !== "master") {
            return {
              verdict: "block", exempted: false, // audit must NOT log blocked ops (round-4)
              reason: _mainProtectionReason(inv,
                `Worktree checkout of the hub's protected branch "${pos[0]}" while the hub is`,
                `off-main — the wt would take "${pos[0]}" and its commits/pushes would mutate it.`),
            };
          }
        }
      }
      sawRecovery = true;
      continue;
    }
    if (v === "block") {
      const target = resolveInvocationTarget(inv, sessionCwd, sessionCwd);
      if (target && target.isWorktree) {
        exempted = true;
        // Issue #397: a FOREIGN worktree (different repo than the session hub,
        // hit via the invocation-frame map fallback) is FULLY isolated from the
        // hub by construction — git repos never share ref namespaces — so every
        // session-hub protection below (shared-ref verb re-classification,
        // main-protection, protected-branch refspec guards) is a false block
        // for it: its mutations only ever touch the FOREIGN repo's own refs.
        // Only the session repo's own worktrees share the hub's ref namespace
        // (2026-08-30 #387: agent-infra worktree commits/pushes/tags from a
        // tortoise session were all false-blocked as if they touched tortoise).
        // Documented residual (code-review P2): a foreign-wt push that EXPLICITLY
        // names the session repo's origin URL (`git -C <foreign-wt> push
        // <session-origin-url> <sha>:refs/heads/main`) can still advance the
        // session repo's REMOTE refs — the gate cannot cheaply compare remote
        // URLs; the session HUB's LOCAL refs remain untouchable.
        if (target.foreignWorktree) {
          // cycle-2 P1 closure: a push/fetch whose remote operand is a LOCAL
          // PATH into the session hub rewrites the hub's OWN refs — blocked
          // outright (never re-classified as the wt's own branch: the
          // destination refs live in the session repo).
          if ((inv.verb === "push" || inv.verb === "fetch") &&
              _pushRemoteIsSessionHub(inv, target, sessionCwd)) {
            return {
              verdict: "block", exempted: false,
              reason: _mainProtectionReason(inv,
                `push/fetch from a foreign worktree targeting the SESSION HUB via a local`,
                `path — not isolated (the hub's own refs are at stake).`),
            };
          }
          // cycle-6 P3: a checkout/switch of main/master that classified as a
          // BLOCK verb (e.g. `checkout main --` — the "--" breaks the recovery
          // pattern) still needs the recovery-checkout hardening: fail loudly
          // when the branch cannot be checked out in the target repo (#387
          // silent-failure class).
          if (inv.verb === "checkout" || inv.verb === "switch") {
            const pos = (inv.args || []).filter((x) => !x.startsWith("-"));
            if (pos.length === 1 && (pos[0] === "main" || pos[0] === "master") &&
                !_recoveryCheckoutVerifiable(target.gitDir, pos[0], inv)) {
              return {
                verdict: "block", exempted: false,
                reason: _recoveryCheckoutBlockReason(inv, pos[0]),
              };
            }
          }
          continue; // the foreign repo's own business — isolated
        }
        // Round-5 (second-model P1): `pull` is worktree-LOCAL but accepts a
        // fetch-style refspec whose dst can be the protected branch — the dst
        // guard must run BEFORE the local-verb exemption (`cd <wt> && git pull
        // origin +main:refs/heads/main` rewrote main — probe). Same for fetch.
        if (inv.verb === "pull" || inv.verb === "fetch") {
          for (const x of inv.args || []) {
            if (x.includes(":") && (_refspecDst(x) === "main" || _refspecDst(x) === "master")) {
              return {
                verdict: "block", exempted: false,
                reason: _mainProtectionReason(inv,
                  `pull/fetch refspec dst writes the hub's protected branch — not isolated.`),
              };
            }
          }
        }
        // Round-20 (second-model P1): shared checkout/switch guard — force-create
        // (-B/-C/--force-create) moves a SHARED ref (≡ branch -f) and the
        // main-protection (wt-on-main, checkout-main-while-off-main) now also
        // applies to NON-main force-create targets (`checkout -B feat/other`
        // moved refs/heads/feat/other — probe) and to the SCRIPT surface.
        if (inv.verb === "checkout" || inv.verb === "switch") {
          const cb = _worktreeCheckoutBlock(inv, target, currentBranch);
          if (cb) return { verdict: "block", exempted: false, reason: cb };
        }
        // Main-protection (round-3 P1): a worktree on the hub's protected branch
        // is NOT isolated for mutations (commits/pushes move the shared main ref).
        if (target.worktreeBranch === "main" || target.worktreeBranch === "master") {
          return {
            verdict: "block", exempted: false, // audit must NOT log blocked ops (round-3/4)
            reason: _mainProtectionReason(inv,
              `The worktree is checked out on the hub's protected branch "${target.worktreeBranch}" —`,
              `its mutations would advance the shared main ref.`),
          };
        }
        // Round-4 (security F2 + second-model P1): `checkout -B main` from a wt
        // force-moves the shared main ref — intercept ANY checkout/switch whose
        // TARGET branch is main/master (not just the sanctioned `checkout main`
        // recovery form, which the recovery-interception above handles).
        if (inv.verb === "checkout" || inv.verb === "switch") {
          const pos = (inv.args || []).filter((x) => !x.startsWith("-"));
          if (pos.length >= 1 && (pos[0] === "main" || pos[0] === "master")) {
            return {
              verdict: "block", exempted: false,
              reason: _mainProtectionReason(inv,
                `Worktree checkout targeting the hub's protected branch "${pos[0]}" while the hub`,
                `is off-main — the wt would take "${pos[0]}" and its commits/pushes would mutate it.`),
            };
          }
        }
        if (!WORKTREE_LOCAL_VERBS.has(inv.verb)) {
          // Round-4 (security P2): `git symbolic-ref <non-HEAD>` from a wt
          // rewrites a SHARED ref (refs/remotes/origin/HEAD probe) — the
          // readonly classification is unsafe for worktree targets.
          if (inv.verb === "symbolic-ref") {
            return {
              verdict: "block", exempted: false,
              reason: _mainProtectionReason(inv,
                `symbolic-ref from a worktree target rewrites a shared ref — not isolated.`),
            };
          }
          // Shared-ref/remote/unknown verb: re-classify against the WORKTREE's
          // own branch — the recovery carve-out (e.g. push origin
          // <checked-out-branch>) derives from the wt's HEAD, not the hub's.
          const wv = isHubRecoveryInvocation(inv.verb, inv.args, target.worktreeBranch);
          if (wv === "block") {
            return {
              verdict: "block", exempted: false, // audit must NOT log blocked ops as exemptions (round-3)
              reason: _mainProtectionReason(inv,
                `Shared-ref/remote/unknown mutation from a worktree target — worktrees share`,
                `the hub's ref namespace. Sanctioned: git push origin <the worktree's branch>.`),
            };
          }
          if (wv === "recovery") sawRecovery = true;
          continue; // readonly / sanctioned recovery for the wt's own branch — allowed
        }
        continue; // worktree-local verb — isolated
      }
      // #436 (B carve-out): collision-free branch ref-delete in the
      // disordered hub — `git push origin --delete <b>` / `git branch -D <b>`
      // where <b> is checked out nowhere (hub + worktrees) cannot touch the
      // dirty set or any sibling. Per-invocation, so a compound
      // `delete && commit` still blocks on the commit (no laundering).
      // Opt-in: only callers that pass a checkedOutBranches Set (index.ts M4
      // gate) activate the carve-out — a null/absent set keeps fail-closed.
      const delNames = checkedOutBranches ? branchDeleteNames(inv.verb, inv.args) : null;
      if (delNames && branchDeleteAllowance(delNames, currentBranch, checkedOutBranches)) {
        sawRecovery = true; // sanctioned cleanup op — command may proceed
        continue;
      }
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
    if (v === "recovery" && inv.verb === "push") {
      // Round-5 (security F3-adjacent): the push carve-out derives from the
      // HUB's branch — `cd <wt> && git push origin main:main` gets "recovery"
      // at first pass (dst matches the hub branch) and never re-classifies
      // against the WORKTREE's branch. Re-validate recovery pushes whose target
      // is a worktree against the wt's own branch.
      const target = resolveInvocationTarget(inv, sessionCwd, sessionCwd);
      if (target && target.isWorktree) {
        // Issue #397: a FOREIGN worktree pushes only the foreign repo's refs —
        // the session-hub re-validation (wt's own branch / protected branch)
        // doesn't apply. `cd <foreign-wt> && git push origin <anything>` cannot
        // touch the session hub (disjoint ref namespaces).
        // cycle-2 P1 closure: a local-path remote resolving into the session
        // hub is NOT a foreign push — it rewrites the hub's own refs.
        if (target.foreignWorktree && _pushRemoteIsSessionHub(inv, target, sessionCwd)) {
          return {
            verdict: "block", exempted: false,
            reason: _mainProtectionReason(inv,
              `push from a foreign worktree targeting the SESSION HUB via a local`,
              `path — not isolated (the hub's own refs are at stake).`),
          };
        }
        if (!target.foreignWorktree) {
          // Round-12 (second-model P2): a wt on the hub's protected branch must
          // not push it via HEAD/bare forms either (`git push origin HEAD` /
          // bare `git push` from a wt on main classify recovery but push main).
          if (target.worktreeBranch === "main" || target.worktreeBranch === "master") {
            return {
              verdict: "block", exempted: false,
              reason: _mainProtectionReason(inv,
                `push from a worktree on the hub's protected branch "${target.worktreeBranch}" —`,
                `would advance the shared main ref.`),
            };
          }
          if (isHubRecoveryInvocation(inv.verb, inv.args, target.worktreeBranch) === "block") {
            return {
              verdict: "block", exempted: false,
              reason: _mainProtectionReason(inv,
                `push from a worktree target of a branch other than the worktree's own — not isolated.`),
            };
          }
        }
      }
      sawRecovery = true;
      continue;
    }
    if (v === "recovery") sawRecovery = true;
    // Round-4 (security P2): `git symbolic-ref <non-HEAD>` from a worktree
    // rewrites a SHARED ref (refs/remotes/origin/HEAD probe) — the readonly
    // classification is unsafe for worktree targets.
    if (v === "readonly" && inv.verb === "symbolic-ref" && !(inv.args || []).includes("HEAD")) {
      const target = resolveInvocationTarget(inv, sessionCwd, sessionCwd);
      // Issue #397: a FOREIGN worktree's symbolic-ref writes only the foreign
      // repo's refs (disjoint namespace) — the session-hub shared-ref concern
      // doesn't apply.
      if (target && target.isWorktree && !target.foreignWorktree) {
        return {
          verdict: "block", exempted: false,
          reason: _mainProtectionReason(inv,
            `symbolic-ref from a worktree target rewrites a shared ref — not isolated.`),
        };
      }
    }
    // Round-5 (second-model P1): eval / $( ) / backtick command substitution is
    // an UNVERIFIABLE one-token shell construct — handled pre-loop by
    // _unverifiableGitContent (a preceding worktree-exempt `continue` must not
    // skip the fail-closed check, final gate P1).
  }
  return { verdict: sawRecovery ? "recovery" : "allowed", exempted };
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
  // Shared _walkShell chain semantics (subshell/pipe/&/vars) — a script token
  // stops the walk and returns the chain state AT that point (cycle-4 P2).
  let result = null;
  _walkShell(command, {
    onScriptToken: (chain) => {
      if (result === null) result = _resolveCdChain(chain, sessionCwd);
    },
  });
  return result;
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

// ── #350: hub-WIP hygiene — write-gate WARNING + hub-hygiene check ──────────
// The #347 amplifier: agents write WIP (plan docs to docs/plans/, migrations,
// scratch files) directly in the hub main checkout instead of an isolated
// worktree. These helpers are PURE classification (no git, no fs) — index.ts
// decides hub-ness (is the path inside the hub main checkout?) and when to
// WARN (never block). /tmp scratch-ish targets are FINE — the caller's
// hub-equality gate excludes them before any warning.

const WIP_SCRATCH_SUFFIXES = [".tmp", ".bak", ".scratch"];

/**
 * Classify a path against the hub-WIP patterns (#350):
 *   "docs/plans" — a `docs` segment immediately followed by a `plans` segment
 *   "migrations" — any path segment named exactly `migrations`
 *   "scratch"    — basename ends with .tmp / .bak / .scratch / `~` (vim backup)
 * Returns null when no pattern matches. PATTERN-ONLY: hub-ness is the caller's
 * job — `/tmp/foo.tmp` classifies "scratch" here but must NOT warn (index.ts
 * gates on hub-equality first). Segment-aware (never prefix-string):
 * `/repo/docs/plans-extra/x.md` and `/repo/notdocs/plans/x.md` do not
 * false-match docs/plans.
 * @param {string} resolvedPath
 * @returns {"docs/plans"|"migrations"|"scratch"|null}
 */
export function matchHubWipPattern(resolvedPath) {
  const p = String(resolvedPath ?? "").replace(/\\/g, "/");
  // Segment patterns take precedence over the scratch suffix (a plan doc named
  // `foo.tmp` inside docs/plans/ is a plan doc — the WHERE is the actionable
  // signal; the scratch label is the fallback for unlocated scratch files).
  const segs = p.split("/").filter((s) => s.length > 0);
  for (let i = 0; i < segs.length; i++) {
    if (segs[i] === "migrations") return "migrations";
    if (segs[i] === "docs" && segs[i + 1] === "plans") return "docs/plans";
  }
  const base = p.split("/").pop() ?? "";
  if (base.endsWith("~")) return "scratch";
  for (const s of WIP_SCRATCH_SUFFIXES) if (base.endsWith(s)) return "scratch";
  return null;
}

/**
 * Extract NON-GIT write targets from a bash command (#350 Indicators: heredoc /
 * tee / python open() writes bypass the write/edit tool gate). Heuristic and
 * NEVER blocking — the caller warns only:
 *   - redirect operators OUTSIDE quotes (`>`, `>>`, `>&`, `>|`, `&>`, `&>>`,
 *     `0>`/`1>`) → the target (stderr `2>` and fd-dup/close `2>&1`/`>&-` are
 *     NOT content writes; `/dev/null` skipped; quoted `>` in read-only commands
 *     like `grep ">" x.md` is NOT a redirect — quote-aware scan)
 *   - `tee <path>` → the tee target (first non-flag positional)
 *   - python `open("<path>", "w"|"a"…)` → the path (incl. backslash-escaped
 *     quotes: `python3 -c "open(\"x.md\",\"w\")"`)
 * Targets resolve against `cwd` (the session cwd — a heuristic: cd-prefixed
 * writes are false-negatives, acceptable for a warning-only heuristic; a
 * warning is cheap, a missed one is not an incident).
 * @param {string} command
 * @param {string} [cwd]
 * @returns {{ resolvedPath: string, via: "redirect"|"tee"|"python" }[]}
 */
export function extractBashWriteTargets(command, cwd = process.cwd()) {
  const out = [];
  const seen = new Set();
  const push = (raw, via) => {
    const t = _stripQuotes(String(raw ?? "").trim());
    if (!t || t === "/dev/null" || t.startsWith("/dev/")) return;
    const resolved = resolve(cwd, t);
    if (seen.has(resolved)) return;
    seen.add(resolved);
    out.push({ resolvedPath: resolved, via });
  };
  // Quote-aware redirect scan over the RAW command (the shared _tokenize
  // strips quotes, so a quoted `>` in a read-only command would tokenize as a
  // bare `>` and false-positive as a redirect — round-1 closure). fd-dup/close
  // forms (`2>&1`, `1>&2`, `>&-`) have a digit/dash operand → skipped.
  const s = String(command);
  let i = 0;
  while (i < s.length) {
    const ch = s[i];
    if (ch === "'") { const close = s.indexOf("'", i + 1); i = close === -1 ? s.length : close + 1; continue; }
    if (ch === '"') { const close = s.indexOf('"', i + 1); i = close === -1 ? s.length : close + 1; continue; }
    let fd = "";
    let j = i;
    while (j < s.length && /[0-9]/.test(s[j])) { fd += s[j]; j++; }
    if (j < s.length && s[j] === ">") {
      let k = j + 1;
      let op = ">";
      if (k < s.length && (s[k] === ">" || s[k] === "|" || s[k] === "&")) { op += s[k]; k++; }
      let p = k;
      while (p < s.length && /\s/.test(s[p])) p++;
      let operand = "";
      while (p < s.length && !/\s/.test(s[p])) {
        const c = s[p];
        if (c === "'" || c === '"') {
          const q = c;
          p++;
          while (p < s.length && s[p] !== q) operand += s[p++];
          if (p < s.length) p++;
          continue;
        }
        if (";&|()".includes(c)) break;
        operand += c;
        p++;
      }
      // `>& <fd>` / `>&-` are fd-dup/close, not file writes; stderr `2>` is
      // not content. Content fds: bare/0/1.
      const isDup = op.includes("&") && /^-?[0-9]*$/.test(operand);
      const isContentFd = fd === "" || fd === "0" || fd === "1";
      if (!isDup && isContentFd) push(operand, "redirect");
      i = p > k ? p : k;
      continue;
    }
    // A digit run not followed by `>` can never start a redirect — skip the
    // whole run in one step (round-2 perf closure: O(L) not O(L²) on long
    // numeric payloads like `echo 1111… > foo`).
    if (j > i) { i = j; continue; }
    i++;
  }
  // tee: first non-flag positional — but ONLY when `tee` is the command in its
  // pipeline segment (first token or after a boundary), not an ARGUMENT to
  // another command (`grep tee x.md` searches a file for the word "tee").
  const tokens = _tokenize(command);
  let prevBoundary = true;
  for (let i = 0; i < tokens.length; i++) {
    const t = tokens[i];
    if (_isShellBoundary(t)) { prevBoundary = true; continue; }
    if (t === "tee" && prevBoundary) {
      for (let j = i + 1; j < tokens.length; j++) {
        const n = tokens[j];
        if (_isShellBoundary(n)) break;
        if (n === "-a") continue;
        if (n.startsWith("-")) continue;
        push(n, "tee");
        break;
      }
      prevBoundary = false;
      continue;
    }
    prevBoundary = false;
  }
  // python open() writes — regex over the raw command; tolerate backslash-
  // escaped quotes (`open(\"x\",\"w\")` inside a double-quoted shell string).
  // Lazy path capture so the closing escaped-quote backslash is not eaten.
  // Round-2 hardening: (a) require a python interpreter token in the command
  // so quoted prose (`git commit -m "open('x.tmp','w')"`) does not false-
  // positive; (b) bound the backslash run to \\\\{0,4} and skip the scan for
  // commands over 64KB — no quadratic backtracking on adversarial input.
  // Round-3 (second-model P2): the gate also matches versioned (`python3.11`)
  // and path-qualified (`/usr/bin/python3`, `venv/bin/python`) interpreters.
  const pyRe = /open\s*\(\s*\\{0,4}["']([^"']+?)\\{0,4}["']\s*,\s*\\{0,4}["'][wa][^"']*["']/g;
  const hasPython = /(?:^|[\/\s;|&(])python(?:2|3)?(?:\.[0-9]+)*(?:[\s;|&)]|$)/.test(String(command));
  if (hasPython && s.length <= 64 * 1024) {
    let m;
    while ((m = pyRe.exec(String(command))) !== null) push(m[1], "python");
  }
  return out;
}

/**
 * Parse `git status --porcelain` (v1) output for UNTRACKED WIP (#350).
 * Untracked lines start with `?? `; porcelain v1 collapses untracked
 * DIRECTORIES to a single `?? dir/` entry (pass --untracked-files=all for
 * per-file entries). Classifies each entry with matchHubWipPattern — the #347
 * amplifier inventory for the session-start / periodic hub-hygiene check.
 * @param {string} porcelain
 * @returns {{ untracked: string[], wip: { path: string, pattern: string }[] }}
 */
export function classifyUntrackedWip(porcelain) {
  const untracked = [];
  const wip = [];
  for (const line of String(porcelain ?? "").split("\n")) {
    if (!line.startsWith("?? ")) continue;
    let p = line.slice(3).trim();
    if (!p) continue;
    p = p.replace(/^"(.*)"$/, "$1"); // quoted-spelling paths (spaces)
    untracked.push(p);
    const pat = matchHubWipPattern(p);
    if (pat) wip.push({ path: p, pattern: pat });
  }
  return { untracked, wip };
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
    if (SPAWNER_WORDS.has(t) && !SHELL_INTERPRETERS.has(t)) {
      // round-17 (P2): `exec bash evil.sh` / `env bash evil.sh` — the OUTER
      // spawner is not the interpreter. Round-18 (P1): jump to the FIRST
      // interpreter past the spawner's flags/operands (`sudo -u root bash
      // evil.sh` — `-u`'s operand `root` broke the scan; probe executed the
      // script ungated). No interpreter before a boundary → the spawner's own
      // command is non-interpreter (keep scanning from the next token).
      let k = i + 1;
      let found = false;
      while (k < tokens.length) {
        const n = tokens[k];
        if (_isShellBoundary(n) || n === "&&" || n === "||" || n === "&" || n === "|" || n === "(" || n === ")") break;
        if (SHELL_INTERPRETERS.has(n)) { found = true; break; }
        k++;
      }
      if (found) { i = k; continue; }
      i++;
      continue;
    }
    if (t === "&&" || t === ";" || t === "||") { i++; continue; } // separators
    if (t === "(" || t === ")") { i++; continue; }                 // #347: subshell wrappers
    if (/^[0-9]+[<>]&[0-9]*-?$|^[0-9]+[<>]&-$|^[<>]&[0-9]*-?$|^[<>]&-$/.test(t) || t === "<&" || /^[<>]&/.test(t)) { i++; continue; } // round-17: fd-dup/close prefixes
    break;
  }
  if (i >= tokens.length) return null;
  const t = tokens[i];
  if (SHELL_INTERPRETERS.has(t)) {
    // Round-19 (final gate P1): the script file is the LAST positional
    // (non-flag, non-redirect) token before a boundary — `bash --rcfile decoy
    // evil.sh`, `bash -O extglob evil.sh`, `bash < /dev/null -x evil.sh` all
    // execute evil.sh (the old scan broke at the first flag-operand and gated
    // the WRONG file — probe: evil.sh ran ungated). If no positional exists,
    // a stdin redirect's operand IS the script (`bash < evil.sh`); `-c`/
    // `--command` means an inline (return null — gated by the normal
    // classifier); process substitution `<( … )` is an FD, not a file (null —
    // _unverifiableGitContent fails closed on the content).
    let j = i + 1;
    let sawInline = false;
    let stdinOperand = null;
    let lastPositional = null;
    let sawProcessSub = false;
    while (j < tokens.length) {
      const n = tokens[j];
      // Redirects FIRST — they are also shell boundaries but are NOT command
      // terminators in this scan (B34 regression: `bash < evil.sh` broke at
      // the `<` before the redirect branch ran).
      if (/^[0-9]+[<>]&[0-9]*-?$|^[0-9]+[<>]&-$|^[<>]&[0-9]*-?$|^[<>]&-$/.test(n)) { j++; continue; } // fd-dup/close — no operand
      if (n === "<(" || n.startsWith("<(")) { sawProcessSub = true; j++; continue; } // process substitution FD
      if (n === ">" || n === ">>" || n === "<" || n === "<<" || n === "&>" || n === ">&" || n === "&>>" || /^(?:[0-9]+)?[<>]/.test(n)) {
        if (n === "<" || n === "<<" || n === "0<" || n === "0<<") {
          stdinOperand = tokens[j + 1]; // the stdin file (script only if no positional follows)
        }
        j += 2;
        continue;
      }
      if (_isShellBoundary(n)) break;
      if (n.startsWith("-")) {
        // Round-20 (security P1): skip flag OPERANDS for operand-taking flags
        // (`bash --rcfile decoy -c 'git commit'` broke at `decoy` and never
        // walked the inline — probe committed to the hub). -c/--command handled
        // above; --rcfile/--init-file/-O/-o take an operand; simple flags (-x,
        // -e, -i) don't — conservatively skip the next token for all but known
        // operand-less flags.
        if (n === "-c" || n === "--command") { sawInline = true; j++; continue; }
        j++;
        if (n === "--rcfile" || n === "--init-file" || n === "-O" || n === "-o") j++;
        continue;
      }
      lastPositional = n;
      j++;
    }
    if (sawInline) return null; // `-c 'inline'` — gated by the normal classifier
    if (sawProcessSub) return null; // `bash <(echo 'git …')` — FD, not a file (fail-closed via _unverifiableGitContent)
    if (lastPositional !== null) return lastPositional; // the script ARGUMENT (last positional)
    return stdinOperand && !stdinOperand.startsWith("-") ? stdinOperand : null; // the stdin file IS the script
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
  // Round-6 (second-model P2): the script surface needs the same substitution /
  // eval / alias fail-closed — a script containing `echo "$(git -C <hub>
  // reset --hard)"` yields zero invocations and would otherwise be "allow".
  // Round-7: run the scan on COMMENT-STRIPPED content (a comment like
  // `# runs $(git rev-parse)` must not false-block an otherwise-clean script).
  const strippedContent = _stripShellComments(content);
  if (_unverifiableGitContent(strippedContent)) return "block";
  for (const inv of invocations) {
    if (!inv.verb) continue;
    if (inv.verb === "__unverifiable__") return "block"; // round-12: multiword $VAR command
    const v = isHubRecoveryInvocation(inv.verb, inv.args, currentBranch);
    // Round-20 (second-model P1): the script surface lacked the bash gate's
    // recovery-checkout main-protection — `cd <wt> && bash evil.sh` with
    // `git checkout main` content (hub off-main) takes the protected branch.
    if (v === "recovery" && (inv.verb === "checkout" || inv.verb === "switch")) {
      const pos = (inv.args || []).filter((x) => !x.startsWith("-"));
      const target = resolveInvocationTarget(inv, sessionCwd, executionCwd);
      // Issue #397: mirror the bash gate's recovery-checkout hardening — a
      // script whose checkout of main/master cannot succeed in the target repo
      // (no local branch, no unique DWIM source) is the #387 silent-failure
      // class (swallowed failure → wrong-branch reset); block it loudly. The
      // main-protection guard below is session-hub-scoped: a FOREIGN worktree
      // (different repo — invocation-frame map hit) taking its OWN repo's main
      // cannot touch the session hub (disjoint ref namespaces).
      if (target && pos.length === 1 && (pos[0] === "main" || pos[0] === "master") &&
          !_recoveryCheckoutVerifiable(target.gitDir, pos[0], inv)) return "block";
      if (target && target.isWorktree && !target.foreignWorktree &&
          _worktreeCheckoutBlock(inv, target, currentBranch)) return "block";
    }
    if (v === "block") {
      // #347: per-invocation target exemption — the worktree map comes from the
      // SESSION repo (the guard's hub; explicit param for testability),
      // executionCwd is the script's cd-chain base. Worktree-targeted content
      // with worktree-LOCAL verbs is isolated; shared-ref/remote verbs are
      // re-classified against the worktree's own branch (code-review #4);
      // content that targets the hub (or a foreign/unresolvable target) blocks.
      const target = resolveInvocationTarget(inv, sessionCwd, executionCwd);
      if (target && target.isWorktree) {
        // Issue #397: a FOREIGN worktree is FULLY isolated from the session hub
        // (disjoint ref namespaces) — every session-hub protection below is a
        // false block for it, mirror of the bash gate's foreign continue.
        if (target.foreignWorktree) {
          // cycle-2 P1 closure (mirror of the bash gate): a push/fetch in script
          // content whose remote operand is a local path into the session hub
          // rewrites the hub's own refs — not isolated.
          if ((inv.verb === "push" || inv.verb === "fetch") &&
              _pushRemoteIsSessionHub(inv, target, sessionCwd)) return "block";
          continue;
        }
        // Round-5 (second-model P1): pull refspec dst guard BEFORE the local-verb
        // exemption (mirror of the bash-gate hoist).
        if (inv.verb === "pull" || inv.verb === "fetch") {
          for (const x of inv.args || []) {
            if (x.includes(":") && (_refspecDst(x) === "main" || _refspecDst(x) === "master")) return "block";
          }
        }
        // Round-20 (second-model P1): shared checkout/switch guard — the script
        // surface previously had NO main-protection (`cd <wt> && bash evil.sh`
        // with `git checkout -B main` content force-moved the protected branch;
        // probe). Mirrors the bash gate via the shared helper.
        if (inv.verb === "checkout" || inv.verb === "switch") {
          if (_worktreeCheckoutBlock(inv, target, currentBranch)) return "block";
        }
        // Main-protection (round-3): a worktree on the hub's protected branch
        // is NOT isolated for mutations.
        if (target.worktreeBranch === "main" || target.worktreeBranch === "master") return "block";
        if (!WORKTREE_LOCAL_VERBS.has(inv.verb)) {
          // shared-ref/remote/unknown verb — re-classify against the wt's branch
          if (isHubRecoveryInvocation(inv.verb, inv.args, target.worktreeBranch) === "block") return "block";
          continue;
        }
        continue;
      }
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
      // Round-7 (final gate P2): bash starts a comment only at a WORD-START
      // `#` (line start or preceded by whitespace) — `echo a#b && git reset`
      // keeps `a#b` as one word and runs the reset; the old truncate-at-any-`#`
      // let it through as a "comment".
      if (ch === "#" && !inS && !inD && (i === 0 || /\s/.test(line[i - 1]))) return line.slice(0, i);
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
