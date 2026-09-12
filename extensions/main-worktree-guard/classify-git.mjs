// classify-git.mjs — shared destructive-git classification for main-worktree-guard.
// Pure JS so both index.ts (via jiti) and test.mjs can import the SAME rules.
//
// Also home of the escape-marker (#207) rules — ALLOW_MAIN_EDITS_MARKER_TTL_MS,
// isAllowMarkerActive, parseMarkerContent, isAllowMarkerPath, isAllowMarkerCommand,
// extractMarkerReason, isAllowMarkerRealpath, readAllowMarkerState — so test.mjs
// exercises the SAME marker logic index.ts uses (dependency-injected, fail-safe
// default = inactive → block).

import { execSync, execFileSync } from "node:child_process";
import { resolve, join, dirname, relative, basename } from "node:path";
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
  // #587: git's parse-options MERGES NOARG short flags into ONE cluster, so
  // `-Dq` ≡ `-D -q` and `git branch -q -D x` / `--quiet -D x` all HARD-delete
  // (probe-verified rc=0); the branch name is always the following POSITIONAL
  // (git has no attached-name form — `-Dold` is unknown-switch rc 129). The
  // old `-\w*D\b` required the D TERMINAL at a word boundary AND the cluster
  // immediately after `branch\s`, so every trailing-flag cluster (`-Dq`, `-Dv`,
  // `-Dqv`) and separated-flag form bypassed. Widen to a run-scan (force-push
  // precedent): a single-dash short cluster containing uppercase D ANYWHERE in
  // the branch option run is a force delete. Case distinguishes HARD -D from
  // SOFT -d/--delete — lowercase stays allow (P1-B merged-only, git-enforced)
  // UNLESS composed with force (next entry). The `(?![A-Za-z]*u)` guard stops
  // `-u<value>` (set-upstream-to's ATTACHED value — the ONLY arg-taking short
  // among branch's flags, e.g. `-uDevel`) from false-matching as a delete
  // cluster; `--long` tokens can't match (`[A-Za-z]*` cannot cross the second
  // dash), and name tokens lack a leading dash. The guard is deliberately
  // BROADER than -u alone: it rejects any cluster whose letter run contains u
  // (incl. `-Du<value>` / `-qDu<value>` mixes) — safe because delete +
  // set-upstream-to is a git MODE CONFLICT (probe-verified rc 129, nothing
  // deleted), so no real force-delete is ever masked. The leading `["']?`
  // tolerates a quoted flag token (`git branch "-Dq" x`) for the FROZEN string
  // path's degradation fallback (echo/string-literal over-match is the
  // documented accepted class). The token boundary is a SINGLE `[ \t]`
  // (shell-token semantics: options are space/tab-separated on one line) — a
  // `\s+` after the `[^;&|]*` run would re-scan the same whitespace it already
  // consumed, giving quadratic blowup on a long whitespace run (measured: 20KB
  // spaces → seconds; review fold-in #587). KNOWN STRING-LEVEL RESIDUAL: a
  // metachar inside a QUOTED branch name placed BEFORE the flags
  // (`git branch "feat&x" -Dq`) truncates the `[^;&|]*` run at the string
  // level — the detailed path closes it via the token-level hard-delete verdict
  // in the branch-state arm (quote-stripped args), which index.ts consumes
  // EXCLUSIVELY.
  { name: "branch-force-delete", re: /\bgit\s+branch\b[^;&|]*[ \t]["']?-(?![A-Za-z]*u)[A-Za-z]*D/ },
  // #587 review fold-in: -D is documented as `--delete --force`, and git
  // accepts the SOFT spellings composed with force as HARD deletes of UNMERGED
  // branches — `git branch -d -f x`, `-df x`, `-fd x`, `-d --force x`,
  // `--delete --force x` all delete unmerged branches rc=0 (probe-verified),
  // defeating the P1-B "merged-only, git-enforced" premise that keeps bare
  // -d/--delete on the allow list. So a branch option run that contains BOTH a
  // delete spelling AND a force spelling is a force delete: delete = the
  // `--delete` long form with its UNAMBIGUOUS prefix abbreviations (`--d`..
  // `--delete` — branch's only `--d*` option, probe-verified; parity with the
  // push family's `--del` handling, #443) or a single-dash cluster whose
  // letters include d/D (u-guarded); force = `--force`/`--forc` (unambiguous —
  // `--for` is ambiguous with `--format`, rc 129; anchored `(?![A-Za-z0-9])` so
  // `--forcfoo` — an unknown-option rc-129 no-op — is NOT force, keeping both
  // layers' force sets identical to the token arm) or a single-dash cluster
  // including f (u-guarded). The D-cluster entry above already covers pure -D
  // forms; this one is the d+force composition. Force-CREATE (`git branch -f x
  // main` — no delete token) never reaches this pattern: the M3 force arm
  // classifies it separately (branch-state mutation, ownership-gated).
  { name: "branch-force-delete", re: /\bgit\s+branch\b(?=[^;&|]*[ \t](?:["']?--d(?:e(?:l(?:e(?:t(?:e)?)?)?)?)?|["']?-(?![A-Za-z]*u)[A-Za-z]*[dD]))(?=[^;&|]*[ \t](?:["']?--forc(?:e)?(?![A-Za-z0-9])|["']?-(?![A-Za-z]*u)[A-Za-z]*f))[^;&|]*/ },
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
// classifyGitCommand's function TEXT above is FROZEN byte-identical
// (back-compat — test.mjs's existing string assertions + external importers
// depend on the exact body). New destructive matchers are added to the SHARED
// DESTRUCTIVE_GIT_PATTERNS array that both it and classifyGitCommandDetailed
// iterate — which DOES extend string-level blocking for new command shapes
// (#587 adds the branch -D cluster + delete+force entries). What is frozen is
// the function body itself, not the pattern set it consumes.
// classifyGitCommandDetailed is the NEW object-returning classifier that
// index.ts consumes EXCLUSIVELY (call-site contract, plan deviation 8 /
// cycle-3 fold-in). It verb-anchors the SAME legacy patterns on the SKIMMED
// command (`git -c k=v checkout main` ≡ `git checkout main`) and adds
// commit / push / branch-state classification for the ownership gates.

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
// ── #627: non-shell CODE interpreters (python/node/ruby/perl/php/…) ────────
// The #1484 script-backdoor closure was SHELL-only (SHELL_INTERPRETERS +
// shell-syntax content scans), so `python3 -c "subprocess.run(['git','reset',
// '--hard'])"` carried a git payload invisibly to BOTH the backdoor gate and
// the structured classifier (the payload is quoted/arrayed, so no `git` token
// sits at a shell command position). This block adds the code-payload surface:
// interpreter recognition (basename + version normalized so `python3.11` /
// `/usr/bin/python3` / `venv/bin/python` all match), inline/file payload
// extraction, and a code-aware git-candidate scanner that feeds the SAME
// invocation verdict the shell script surface uses (so a worktree-targeted or
// read-only git op from code keeps working — false-blocks stay exceptional).
//
// `inline` = flags that CONSUME the following word as the code payload.
// `operand` = flags that consume the following word as a NON-payload operand
// (`python3 -W ignore -c …`, `ruby -I lib -e …`, `node -r ./setup -e …`,
// `php -d k=v -r …`) — without this table the operand was mistaken for the
// payload and the real flag+payload were never parsed (a complete bypass).
// Single-dash flags are parsed LETTER BY LETTER (POSIX cluster semantics):
// `python3 -Sc` = -S + -c, `perl -we` = -w + -e, `ruby -Ilib -e` etc.
const CODE_INTERPRETER_FAMILIES = {
  python: { inline: ["-c"], operand: ["-W", "-X", "-Q"], moduleFlag: true, label: "python" },
  python2: { inline: ["-c"], operand: ["-W", "-X", "-Q"], moduleFlag: true, label: "python" },
  python3: { inline: ["-c"], operand: ["-W", "-X", "-Q"], moduleFlag: true, label: "python" },
  node: { inline: ["-e", "-p"], operand: ["-r", "-C"], longInline: ["--eval", "--print"], longOperand: ["--require", "--loader", "--import", "--conditions", "--max-old-space-size"], label: "node" },
  nodejs: { inline: ["-e", "-p"], operand: ["-r", "-C"], longInline: ["--eval", "--print"], longOperand: ["--require", "--loader", "--import", "--conditions", "--max-old-space-size"], label: "node" },
  deno: { inline: [], subcommandInline: ["eval"], label: "deno" },
  bun: { inline: ["-e"], longInline: ["--eval"], operand: ["-r"], longOperand: ["--preload"], label: "bun" },
  ruby: { inline: ["-e"], operand: ["-I", "-r", "-C", "-K", "-E", "-0"], longOperand: ["--encoding"], label: "ruby" },
  ruby2: { inline: ["-e"], operand: ["-I", "-r", "-C", "-K", "-E", "-0"], label: "ruby" },
  ruby3: { inline: ["-e"], operand: ["-I", "-r", "-C", "-K", "-E", "-0"], label: "ruby" },
  perl: { inline: ["-e", "-E"], operand: ["-I", "-M", "-m", "-F"], label: "perl" },
  perl5: { inline: ["-e", "-E"], operand: ["-I", "-M", "-m", "-F"], label: "perl" },
  php: { inline: ["-r"], operand: ["-d", "-c", "-z", "-f"], longInline: ["--run"], label: "php" },
  php5: { inline: ["-r"], operand: ["-d", "-c", "-z", "-f"], longInline: ["--run"], label: "php" },
  php7: { inline: ["-r"], operand: ["-d", "-c", "-z", "-f"], longInline: ["--run"], label: "php" },
  php8: { inline: ["-r"], operand: ["-d", "-c", "-z", "-f"], longInline: ["--run"], label: "php" },
  lua: { inline: ["-e"], operand: ["-l"], label: "lua" },
  lua5: { inline: ["-e"], operand: ["-l"], label: "lua" },
  luajit: { inline: ["-e"], operand: ["-l"], label: "lua" },
  rscript: { inline: ["-e"], label: "r" },
  julia: { inline: ["-e"], operand: ["-L"], longInline: ["--eval"], label: "julia" },
  coffee: { inline: ["-e"], operand: ["-r"], label: "coffee" },
  tsx: { inline: ["-e"], label: "tsx" },
  "ts-node": { inline: ["-e"], operand: ["-r"], label: "ts-node" },
  groovy: { inline: ["-e"], label: "groovy" },
  pwsh: { inline: ["-c", "-l"], longInline: ["-Command"], operand: ["-File", "-ConfigurationName", "-InputFormat", "-OutputFormat"], caseInsensitive: true, label: "pwsh" },
  powershell: { inline: ["-c", "-l"], longInline: ["-Command"], operand: ["-File", "-ConfigurationName", "-InputFormat", "-OutputFormat"], caseInsensitive: true, label: "pwsh" },
  osascript: { inline: ["-e"], operand: ["-l"], label: "osascript" },
};

/** Resolve a command token to a code-interpreter family, or null. Strips the
 * directory (`venv/bin/python3`) and a trailing version suffix (`python3.11`,
 * `php8`). Git itself is never an interpreter (guard: `git -c k=v` would match
 * the `-c` inline flag of an unrelated family otherwise). */
function _codeInterpreterFamily(token) {
  const raw = String(token ?? "");
  if (!raw) return null;
  let base = basename(raw);
  if (/\.exe$/i.test(base)) base = base.slice(0, -4); // Windows spellings
  if (/git$/.test(base)) return null;
  const m = base.match(/^([A-Za-z][A-Za-z0-9-]*?)(?:\.[0-9]+)*$/);
  if (!m) return null;
  return CODE_INTERPRETER_FAMILIES[m[1].toLowerCase()] ?? null;
}

/**
 * Extract a code interpreter's payload from a token stream at the interpreter
 * token index. Returns `{kind, value, end}` (`end` = index AFTER the payload)
 * or null when no payload was resolved (bare `interpreter --help`, unknown
 * flags only). `kind`: "inline" | "file" | "stdin-file" | "module" | "stdin".
 * Handles the attached spellings real CLIs accept (`-c'code'` → the tokenizer
 * yields `-ccode`; `--eval=code`) alongside the spaced form.
 */
function _codePayloadFromTokens(tokens, i) {
  const table = _codeInterpreterFamily(tokens[i]);
  if (!table) return null;
  // Case folding applies ONLY to case-insensitive CLIs (PowerShell); elsewhere
  // `-E` (ruby encoding operand) must not collapse onto `-e` (payload flag).
  const ci = !!table.caseInsensitive;
  const fold = (s) => (ci ? String(s).toLowerCase() : String(s));
  const inline = table.inline || [];
  const operand = table.operand || [];
  const longInline = table.longInline || [];
  const longOperand = table.longOperand || [];
  const inList = (arr, x) => arr.some((f) => fold(f) === x);
  const payloads = []; // every inline payload spelling found (union — node uses
                      // the LAST `-e`, ruby/perl/osascript concatenate ALL)
  let moduleVal = null, stdinFile = null, stdin = false, fileVal = null, fileEnd = null;
  let j = i + 1;
  const stop = (n) => _isShellBoundary(n) || n === "&&" || n === "||" || n === "&" || n === "|" || n === "(" || n === ")";
  // Subcommand form: `deno eval 'code'`. Flags before the subcommand are
  // skipped (`deno run --allow-net x` is a FILE form; `deno eval -q 'code'`
  // still resolves the payload after the flags).
  if (table.subcommandInline && inList(table.subcommandInline, String(tokens[j] ?? "").toLowerCase())) {
    j++;
    while (j < tokens.length && String(tokens[j]).startsWith("-")) j++;
    if (tokens[j] !== undefined) payloads.push(tokens[j]);
    j++;
  }
  while (j < tokens.length) {
    const n = tokens[j];
    // PowerShell parameter binding is case-insensitive; other CLIs are not
    // (`ruby -E utf8` is an encoding operand, `-e` is the payload flag).
    const lower = fold(n);
    if (/^[0-9]+[<>]&[0-9]*-?$|^[0-9]+[<>]&-$|^[<>]&[0-9]*-?$|^[<>]&-$/.test(n)) { j++; continue; }
    if (n === "<" || n === "0<") { if (tokens[j + 1] !== undefined) stdinFile = tokens[j + 1]; j += 2; continue; }
    if (n === ">" || n === ">>" || n === "<<" || n === "&>" || n === ">&" || n === "&>>" || /^(?:[0-9]+)?[<>]/.test(n)) { j += 2; continue; }
    if (stop(n)) break;
    if (n === "-") { stdin = true; j++; continue; }
    // Long options: --eval=code / --eval code (case-insensitive); --require foo.
    if (lower.startsWith("--")) {
      const eq = lower.indexOf("=");
      const name = eq >= 0 ? lower.slice(0, eq) : lower;
      if (inList(longInline, name)) {
        if (eq >= 0) { payloads.push(String(n).slice(eq + 1)); j++; continue; }
        if (tokens[j + 1] !== undefined) payloads.push(tokens[j + 1]);
        j += 2; continue;
      }
      if (name === "--module") { if (tokens[j + 1] !== undefined) moduleVal = tokens[j + 1]; j += 2; continue; }
      if (inList(longOperand, name)) { j += (eq >= 0 ? 1 : 2); continue; }
      j++; continue; // unknown long option: don't consume the next token (may be the payload)
    }
    // Exact single-dash MULTI-CHAR flags (`pwsh -Command '…'`, `pwsh -File x`).
    if (lower.length > 2 && lower.startsWith("-")) {
      if (inList(inline, lower) || inList(longInline, lower)) { if (tokens[j + 1] !== undefined) payloads.push(tokens[j + 1]); j += 2; continue; }
      if (inList(operand, lower) || inList(longOperand, lower)) { j += 2; continue; }
    }
    // Single-dash flag or CLUSTER (-Sc, -we): POSIX letter-by-letter.
    if (lower.length > 1 && lower.startsWith("-")) {
      const cluster = lower.slice(1);
      for (let ci = 0; ci < cluster.length; ci++) {
        const short = "-" + cluster[ci];
        if (short === "-m" && ci === 0 && table.moduleFlag) { if (tokens[j + 1] !== undefined) moduleVal = tokens[j + 1]; j += 2; break; }
        if (inList(inline, short)) {
          const rest = String(n).slice(2 + ci);
          // `-pe` = `-p -e` (all remaining letters are known flags) vs `-cfoo`
          // (attached payload). Only the latter consumes the remainder.
          const restAllFlags = rest.length > 0 && [...rest].every((c) => inList(inline, "-" + c) || inList(operand, "-" + c));
          if (rest && !restAllFlags) { payloads.push(rest); j++; break; }
          if (!rest) { if (tokens[j + 1] !== undefined) payloads.push(tokens[j + 1]); j += 2; break; }
          continue; // keep clustering (the payload flag is later in the run)
        }
        if (inList(operand, short)) { j += (cluster.slice(ci + 1) === "" ? 2 : 1); break; }
        if (ci === cluster.length - 1) j++;
      }
      continue;
    }
    if (!String(n).startsWith("-")) { if (fileVal === null) { fileVal = n; fileEnd = j + 1; } j++; continue; }
    j++; // lone '-' handled above; anything else is operand-less
  }
  if (payloads.length) return { kind: "inline", value: payloads.join("\n"), end: j };
  if (moduleVal !== null) return { kind: "module", value: moduleVal, end: j };
  if (stdinFile !== null) return { kind: "stdin-file", value: stdinFile, end: j };
  if (stdin) return { kind: "stdin", value: null, end: j };
  if (fileVal !== null) return { kind: "file", value: fileVal, end: fileEnd };
  return null;
}

/** Extract a code interpreter's payload from a raw command string (leading
 * position only — env prefixes / `cd` / spawners / separators / subshell
 * parens allowed, mirroring extractScriptPath). */
export function extractCodePayload(command) {
  const tokens = _tokenize(command);
  let i = 0;
  while (i < tokens.length) {
    const t = tokens[i];
    if (/^[A-Za-z_][A-Za-z0-9_]*=/.test(t)) { i++; continue; }
    if (t === "cd") { i += 2; continue; }
    if (SPAWNER_WORDS.has(t) && !SHELL_INTERPRETERS.has(t) && !_codeInterpreterFamily(t)) {
      let k = i + 1;
      let found = -1;
      while (k < tokens.length) {
        const n = tokens[k];
        if (_isShellBoundary(n) || n === "&&" || n === "||" || n === "&" || n === "|" || n === "(" || n === ")") break;
        if (SHELL_INTERPRETERS.has(n) || _codeInterpreterFamily(n)) { found = k; break; }
        k++;
      }
      if (found >= 0) { i = found; continue; }
      i++;
      continue;
    }
    if (t === "&&" || t === ";" || t === "||") { i++; continue; }
    if (t === "(" || t === ")") { i++; continue; }
    if (/^[0-9]+[<>]&[0-9]*-?$|^[0-9]+[<>]&-$|^[<>]&[0-9]*-?$|^[<>]&-$/.test(t) || t === "<&" || /^[<>]&/.test(t)) { i++; continue; }
    break;
  }
  if (i >= tokens.length) return null;
  return _codePayloadFromTokens(tokens, i);
}

// ── #627 execution-sink + argv-anchor scanning (review-cycle-2 rewrite) ─────
// A payload is scanned only when it BOTH (a) references a process-execution
// sink (module/method identifier presence — deliberately broad, so aliased
// imports and variable indirection are covered) AND (b) contains an argv-shaped
// `git …` command in COMMAND POSITION. Command position comes from the TOKEN
// STREAM — array element 0, a top-level/assigned command string, or a token
// following only shell-interpreter / wrapper words — not from a sink call
// window. That is what makes variable indirection
// (`cmd = ["git","reset"]; subprocess.run(cmd)`), aliased/destructured imports
// (`from subprocess import run; run([...])`, `import subprocess as sp`), and
// wrapper argv (`["bash","-c","git reset --hard"]`, `["sudo","git",…]`)
// visible, while prose/data stay inert (`print('git reset')`,
// `['echo','git reset needed']`, `{git:'repo'}`, `/git/`, `re.exec(s)`, a
// docstring, `x = "os.system('git reset')"`).

/** Process-execution sink identifiers (identifier-presence gate). Broad on
 * purpose: it only unlocks the anchor scan; the command-position rule does the
 * precision work. Bare `exec`/`spawn`/`system` require a non-`.` preceding char
 * (the `re.exec(s)` false-positive class) and a call/arg shape, which also
 * covers the paren-less Ruby/Perl `system "git reset"`. */
const CODE_SINK_IDENTIFIER_RE = /\b(?:subprocess|child_process|Open3|Runtime\s*\.\s*getRuntime|execSync|execFileSync|execFile|spawnSync|Popen|check_call|check_output|passthru|shell_exec|proc_open|popen|pty|asyncio|multiprocessing)\b|\bos\s*\.\s*(?:system|popen|exec\w*|spawn\w*|posix_spawn\w*)\b|\bdo\s+shell\s+script\b|[.\]\[]\s*(?:run|exec\w*|spawn\w*|posix_spawn\w*|popen|system|Popen|check_\w+|passthru|proc_open|getoutput|getstatusoutput|create_subprocess_\w+)\s*\(/;
const CODE_SINK_BARE_RE = /(?:^|[^.\w])(?:exec|spawn)\s*\(|\bsystem\s*(?:\(|["'`])|`/;
/** Sink module aliases introduced by an import in the payload
 * (`import subprocess as sp`, `from child_process import …`). Destructured
 * method names are covered by the single-segment rule; `as`-aliased module
 * receivers need this map. */
function _codeSinkAliases(content) {
  const set = new Set();
  const c = String(content ?? "");
  for (const m of c.matchAll(/\bfrom\s+(?:subprocess|child_process|Open3)\s+import\s+([^;\n]+)/g)) {
    for (const part of m[1].split(",")) {
      const t = part.trim().replace(/\(|\)/g, "").trim();
      if (!t) continue;
      const as = t.match(/^\w+\s+as\s+(\w+)$/);
      set.add(as ? as[1] : t);
    }
  }
  for (const m of c.matchAll(/\bimport\s+(?:subprocess|child_process|Open3)\s+as\s+(\w+)/g)) set.add(m[1]);
  return set;
}
function _hasCodeExecSink(content) {
  const c = String(content ?? "");
  return CODE_SINK_IDENTIFIER_RE.test(c) || CODE_SINK_BARE_RE.test(c);
}

/** Method names that spawn a child process (command-position test). */
const CODE_SINK_METHODS = new Set([
  "run", "call", "check_output", "check_call", "Popen", "popen", "system",
  "exec", "exec_", "execSync", "execFile", "execFileSync", "spawn", "spawnSync",
  "spawnChildProcess", "passthru", "shell_exec", "proc_open", "exec_command", "getRuntime",
  // #627 cycle-3: real spawn primitives the narrow list missed.
  "getoutput", "getstatusoutput", "create_subprocess_exec", "create_subprocess_shell",
  "execv", "execvp", "execve", "execvpe", "execl", "execlp", "execle",
  "posix_spawn", "posix_spawnp", "spawnl", "spawnle", "spawnlp", "spawnlpe",
  "spawnv", "spawnve", "spawnvp", "spawnvpe", "spawnPosix",
]);
/** Module/receiver names that make a following `.method(` a sink. */
const CODE_SINK_MODULES = new Set(["subprocess", "child_process", "os", "Open3", "Runtime"]);
/** Sink methods whose NAME alone identifies a spawn primitive even on an
 * unknown receiver (`cp.execSync(...)`). Generic method names (`run`, `exec`,
 * `call`, `system`, `getoutput`) require a known module/alias receiver, so a
 * regex `re.exec(s)` or a db `db.run("…")` is NOT treated as a sink (#627
 * cycle-4 correctness P2). */
const CODE_SINK_STRONG_METHODS = new Set([
  "execSync", "execFileSync", "execFile", "spawnSync", "spawn", "spawnChildProcess",
  "Popen", "passthru", "shell_exec", "proc_open", "popen", "posix_spawn", "posix_spawnp",
  "execv", "execvp", "execve", "execvpe", "execl", "execlp", "execle",
  "spawnl", "spawnle", "spawnlp", "spawnlpe", "spawnv", "spawnve", "spawnvp", "spawnvpe",
  "create_subprocess_exec", "create_subprocess_shell",
]);
/** Words that may precede the real command inside an argv array without
 * disqualifying command position (`["sudo","git",…]`, `["bash","-c","git …"]`). */
const CODE_WRAPPER_WORDS = new Set([
  "sudo", "doas", "env", "nice", "ionice", "timeout", "command", "builtin",
  "nohup", "setsid", "stdbuf", "xargs", "exec", "time",
  // AppleScript `do shell script "git reset"` statement words + expression
  // keywords that may precede the sink in a multi-statement `-e` payload.
  "do", "shell", "script", "set", "to", "return",
]);

/** Is the token at index k in COMMAND POSITION? Walks back over flags and
 * wrapper words to the enclosing `[` (argv array), `=`/`:`/`;` (assignment or
 * new statement), a SINK call, or the payload start. A literal/bare word that
 * is neither a wrapper nor a sink method ends the walk as NOT a command. */
function _isCodeCommandPosition(toks, k, aliases = null) {
  // An argv array's ELEMENT 0 is a command regardless of the enclosing call
  // (`sh(['git','reset'])`, `list(['git','reset'])`, `subprocess.run(*[[…]])`).
  // The payload-level sink gate already ran, so this cannot fire on inert data
  // that carries no spawn primitive.
  const prev = toks[k - 1];
  if (prev && !prev.lit && prev.v === "[") {
    const before = toks[k - 2];
    // `["echo"] + ["git",…]` is data concatenation, not a command argv.
    if (!(before && !before.lit && before.v === "+")) return true;
  }
  if (prev && !prev.lit && (prev.v === "*" || prev.v === "**")) {
    const before = toks[k - 2];
    if (before && !before.lit && before.v === "[") return true;
  }
  let skip = 0;
  for (let i = k - 1; i >= 0; i--) {
    if (skip > 0) { skip--; continue; }
    const t = toks[i];
    const v = t.v;
    if (t.lit) {
      if (/^-/.test(v)) continue; // quoted flag (`"-c"`), e.g. argv wrappers
      if (/^\d+$/.test(v)) continue; // an operand value (`timeout 5 git …`)
      if (SHELL_INTERPRETERS.has(v) || CODE_WRAPPER_WORDS.has(v) || SHELL_INTERPRETERS.has(basename(v))) continue;
      if (CODE_SINK_METHODS.has(v) || (aliases && aliases.has(v))) continue; // `'execSync'` bracket key / alias
      if (CODE_SINK_MODULES.has(v)) continue; // `x['run']`, `getattr(subprocess,'run')`
      return false;
    }
    if (v === "[" || v === "]" || v === ")" || v === "*" || v === "**") continue; // nested array / splat
    if (v === "(") {
      // The callee is the preceding token; the tokenizer keeps a dotted chain
      // (`subprocess.run`, `os.system`, `re.exec`) as ONE token, so classify by
      // its last component plus the receiver. A non-sink call does NOT end the
      // walk — the argv may be wrapped (`shlex.split('git reset')`,
      // `list([...])`, `getattr(subprocess,'run')([...])`); keep walking to the
      // enclosing sink (skipping the callee token). A payload with no sink
      // anywhere ends as NOT a command.
      const name = (toks[i - 1] && toks[i - 1].v) || "";
      if (name === "]") return true; // computed member call `cp['execSync'](…)`
      const segs = name.split(".").filter(Boolean);
      const method = segs[segs.length - 1];
      if (CODE_SINK_METHODS.has(method) || (aliases && aliases.has(method))) {
        if (segs.length === 1) return true; // destructured/aliased callee
        const recv = segs[segs.length - 2];
        if (CODE_SINK_MODULES.has(recv) || CODE_SINK_METHODS.has(recv)) return true;
        if (aliases && aliases.has(recv)) return true; // `import subprocess as sp`
        // Method name alone identifies the primitive (`cp.execSync(…)`); generic
        // names on an unknown receiver (`re.exec(s)`, `db.run("…")`) do not.
        return CODE_SINK_STRONG_METHODS.has(method);
      }
      skip = 1; // skip the non-sink callee token and keep walking outward
      continue;
    }
    if (v === ",") continue; // may be an earlier wrapper argv element
    if (v === ";" || v === "=" || v === ":" || v === "\n") return true;
    if (v === "}") return false;
    if (v === "-" || /^-[A-Za-z]/.test(v)) continue; // flags
    if (/^\d+$/.test(v)) continue; // bare operand value
    if (/^(?:[rbfuRBFU]{1,2}|L)$/.test(v)) continue; // f-string / raw / bytes prefix
    if (CODE_SINK_METHODS.has(v) || (aliases && aliases.has(v))) return true; // paren-less `system "git reset"`
    if (CODE_SINK_MODULES.has(v)) continue; // module receiver
    if (SHELL_INTERPRETERS.has(v) || CODE_WRAPPER_WORDS.has(v)) continue;
    return false; // a word (callee / variable)
  }
  return true;
}

/** Lex a code payload into literals + bare words (punctuation becomes its own
 * token) so git args can be reassembled across `['git','reset','--hard']`.
 * Triple-quoted strings (Python docstrings) are ONE literal token, so a
 * docstring example cannot anchor (#627 reviewer P2). */
function _codeTokens(s) {
  const out = [];
  let i = 0;
  while (i < s.length) {
    const ch = s[i];
    const triple = (ch === '"' || ch === "'") && s[i + 1] === ch && s[i + 2] === ch;
    if (triple) {
      let j = i + 3; let buf = "";
      while (j < s.length && !(s[j] === ch && s[j + 1] === ch && s[j + 2] === ch)) { buf += s[j]; j++; }
      out.push({ lit: true, v: buf });
      i = j + 3;
      continue;
    }
    if (ch === '"' || ch === "'" || ch === "`") {
      let j = i + 1; let buf = "";
      while (j < s.length && s[j] !== ch) {
        if (s[j] === "\\" && j + 1 < s.length) { buf += s[j + 1]; j += 2; continue; }
        buf += s[j]; j++;
      }
      out.push({ lit: true, v: buf });
      i = j + 1;
      continue;
    }
    if (/[A-Za-z0-9_./$@~-]/.test(ch)) {
      let j = i; while (j < s.length && /[A-Za-z0-9_./$@~-]/.test(s[j])) j++;
      out.push({ lit: false, v: s.slice(i, j) });
      i = j; continue;
    }
    if (/\s/.test(ch)) { i++; continue; }
    out.push({ lit: false, v: ch });
    i++;
  }
  return out;
}
/** The argument separators a code call may put BETWEEN consecutive git args
 * (`['git', 'reset']`) — skipped while gathering, unlike `)`/`;`/`=` which end
 * the command. Brackets are DEPTH-TRACKED (a closer at depth 0 ends the
 * command) so a trailing kwarg after the array cannot be swallowed into the
 * verb list (`['git','branch','-a'], cwd=hub` must stay a LIST). */
const _CODE_ARG_STOP = new Set([";", "=", ":", "+", "&", "|", "!", "<", ">", "?", "\n"]);

/** Reassemble candidate `git …` command strings from a code payload. Anchors
 * on an argv/bare `git` word or a command-line literal that is in COMMAND
 * POSITION, then gathers arg-shaped tokens with bracket-depth tracking.
 * `cwd=<literal>` / `cwd: <literal>` becomes an implicit `git -C <cwd>` so the
 * invocation's target resolves against the caller's worktree (#347 parity).
 * Returns `{cmds, unresolved}` — `unresolved` counts command-shaped git anchors
 * with no resolvable verb (the per-reference fail-closed signal). */
/** Index just past a keyword-argument's VALUE expression, honouring bracket
 * nesting (`env={"A":"1"}`, `cwd=os.path.join(a,b)`). */
function _skipCodeValue(toks, start) {
  let j = start;
  let depth = 0;
  while (j < toks.length) {
    const v = toks[j].v;
    if (!toks[j].lit) {
      if (v === "[" || v === "{" || v === "(") depth++;
      else if (v === "]" || v === "}" || v === ")") { if (depth === 0) break; depth--; }
      else if (depth === 0 && (v === "," || v === ";")) break;
    }
    j++;
  }
  return j;
}

/** Strip leading command wrappers + their operands from a command-line
 * literal so `sudo git …`, `nice -n 5 git …`, `eval git …` normalize to
 * `git …` (#627 cycle-4 adversarial P1). */
const _CODE_WRAPPER_PREFIX_RE = /^(?:(?:sudo|doas|env|nice|ionice|timeout|nohup|setsid|stdbuf|time|command|builtin|eval|exec|xargs)\b(?:\s+-\S+|\s+\d+)*\s+)*(?:[A-Za-z_]\w*=\S*\s+)*/;

function _codeArgGitCommands(content) {
  const toks = _codeTokens(String(content ?? ""));
  const aliases = _codeSinkAliases(content);
  const cmds = [];
  let unresolved = 0;
  // AppleScript `do shell script "git reset --hard"` — only for an AppleScript-
  // looking payload (a comment/docstring mentioning it must stay inert).
  if (/^\s*(?:set|do|tell|return|on)\b/.test(String(content ?? ""))) {
    for (const mm of String(content ?? "").matchAll(/do\s+shell\s+script\s+["'`]([\s\S]*?)["'`]/g)) {
      for (const seg of mm[1].split(/&&|\|\||;|\n/)) {
        const s = seg.trim();
        if (/^(?:\S*\/)?git\s+\S/.test(s)) cmds.push(s);
      }
    }
  }
  for (let k = 0; k < toks.length; k++) {
    const t = toks[k];
    const raw = t.v;
    const isGitWord = /(?:^|\/)git$/.test(raw);
    // A command-line literal ANYWHERE in the string (`"cd /hub && git reset"`,
    // `"sudo git reset --hard"`) — the split below extracts the git segments.
    const isGitStr = t.lit && /(?:^|[\s&|;])(?:\S*\/)?git\s+\S/.test(raw) && !/^-/.test(raw);
    if (!isGitWord && !isGitStr) continue;
    // an assignment TARGET (`git = "x"`) cannot be a command
    if (isGitWord && !t.lit && toks[k + 1] && !toks[k + 1].lit && toks[k + 1].v === "=") continue;
    if (!_isCodeCommandPosition(toks, k, aliases)) continue;
    if (t.lit && (/\s/.test(raw) || !isGitWord)) {
      // a literal command line (`"git reset --hard"`, `"cd x && git reset"`)
      for (const seg of raw.split(/&&|\|\||;|\n/)) {
        const s = seg.trim().replace(_CODE_WRAPPER_PREFIX_RE, "");
        if (/^(?:\S*\/)?git\s+\S/.test(s)) cmds.push(s);
      }
      continue;
    }
    // argv / bare-word form: gather until the surrounding call/array ends.
    const parts = ["git"];
    let j = k + 1;
    // If the anchor is the first element of an argv array/paren, the matching
    // opener sits BEFORE k — start at depth 1 so the closer is matched.
    let depth = (toks[k - 1] && !toks[k - 1].lit && (toks[k - 1].v === "[" || toks[k - 1].v === "(")) ? 1 : 0;
    let cwdValue = null;
    while (j < toks.length) {
      const n = toks[j];
      if (!n.lit && (n.v === "[" || n.v === "(")) { depth++; j++; continue; }
      if (!n.lit && (n.v === "]" || n.v === ")")) { if (depth === 0) break; depth--; j++; continue; }
      if (!n.lit && n.v === ",") { j++; continue; }
      if (!n.lit && (n.v === "+" || n.v === "*")) { j++; continue; } // argv concat / splat
      if (!n.lit && n.v === "#") { // in-array comment: skip to EOL
        while (j < toks.length && toks[j].v !== "\n") j++;
        continue;
      }
      if (!n.lit && (n.v === "=" || n.v === ":")) {
        if (parts[parts.length - 1] === "cwd" && toks[j + 1] && toks[j + 1].lit) {
          parts.pop();
          cwdValue = toks[j + 1].v;
          j += 2;
          continue;
        }
        break;
      }
      // A bare word followed by `=`/`:` is a KEYWORD ARGUMENT name, not a git
      // arg (`capture_output=True`, `cwd=repo`, `text=True`). Drop it and skip
      // its whole value expression (balanced brackets).
      if (!n.lit && toks[j + 1] && !toks[j + 1].lit && (toks[j + 1].v === "=" || toks[j + 1].v === ":") && /^[A-Za-z_]\w*$/.test(n.v)) {
        if (n.v === "cwd" && toks[j + 2] && toks[j + 2].lit) { cwdValue = toks[j + 2].v; j += 3; continue; }
        j = _skipCodeValue(toks, j + 2);
        continue;
      }
      if (!n.lit && _CODE_ARG_STOP.has(n.v)) break;
      if (n.lit) { parts.push(n.v); j++; continue; }
      if (/^[A-Za-z0-9_./$@~-]+$/.test(n.v)) { parts.push(n.v); j++; continue; }
      break;
    }
    const cmd = cwdValue
      ? ["git", "-C", cwdValue, ...parts.slice(1)].join(" ")
      : parts.join(" ");
    if (parts.length === 1) { k = j - 1; continue; } // lone `git` (e.g. which('git'))
    const invs = allGitInvocations(cmd);
    if (invs.some((iv) => iv.verb) || /(?:^|\s)--(?:version|help)(?:\s|$)/.test(cmd)) cmds.push(cmd);
    else unresolved++;
    k = j - 1;
  }
  return { cmds: [...new Set(cmds)], unresolved };
}

/**
 * Candidate `git …` command strings a CODE payload can execute, plus the
 * count of command-shaped git anchors with no resolvable verb. Pure and
 * exported for pins (#627). The execution-sink gate is the false-block guard:
 * an inert literal (`print('git reset --hard')`, a docstring, a test fixture)
 * with no sink reference yields no candidates, matching the shell surface
 * (where `echo 'git reset'` is allowed).
 * @param {string} content
 * @returns {{ cmds: string[], unresolved: number }}
 */
export function extractCodeGitCommandsDetailed(content) {
  const c = String(content ?? "");
  if (!_hasCodeExecSink(c)) return { cmds: [], unresolved: 0 };
  return _codeArgGitCommands(c);
}

/**
 * Back-compat/pin surface: the candidate list only.
 * @param {string} content
 * @returns {string[]}
 */
export function extractCodeGitCommands(content) {
  return extractCodeGitCommandsDetailed(content).cmds;
}

/**
 * #627: gate a CODE payload's git content with the SAME allowlist + per-
 * invocation target resolution as scriptGitVerdict (parity: read-only /
 * sanctioned / worktree-isolated invocations pass; hub mutations block).
 * Fails closed when an execution-sink reference co-occurs with a command-
 * shaped `git` anchor that cannot be resolved into a command with a verb (a
 * payload variable, an unparseable construction) — static analysis cannot
 * prove those git-free. NOTE: dynamically CONSTRUCTED commands with no `git`
 * spelling anywhere (`'gi'+'t'`, `chr(103)+…`, base64) carry no anchor and are
 * a documented residual (README), not covered by the counter.
 * @param {string} content
 * @param {string|null} currentBranch
 * @param {string} executionCwd
 * @param {string} sessionCwd
 * @returns {"allow"|"block"}
 */
export function codePayloadGitVerdict(content, currentBranch, executionCwd = process.cwd(), sessionCwd = process.cwd()) {
  const c = String(content ?? "");
  const invocations = [];
  // The payload may ITSELF be a command line rather than host-language code
  // (`pwsh -Command 'git reset --hard'`, `pwsh -Command 'cd /hub && git reset'`).
  // Run the shell scan ONLY for a shell-shaped payload (starts with git, or has
  // a `&&`/`;`/`|` git segment) — an unconditional shell scan mis-parses ordinary
  // host code (`print("git")` -> bogus `)` verb; a `//` comment is not `#`).
  // Shell-shaped when a bare `git <cmd>` segment sits at the start or after a
  // shell separator/substitution/backtick — NOT inside a quoted string (quoted
  // prose and host-language literals are handled by the code scanner above).
  // `#`/`//` comments are removed first so a commented-out command cannot fire.
  const shellProbe = _stripShellComments(c).replace(/(^|[\s;])\/\/[^\n]*/g, "$1");
  const GIT_SEG = "(?:(?:sudo|doas|env|nice|ionice|timeout|nohup|setsid|stdbuf|time|command|builtin|eval|exec|xargs)\\s+(?:-\\S+\\s+|\\d+\\s+)*)*(?:\\S*\\/)?git\\s+(?![=:])\\S";
  if (new RegExp(`(?:^|[\\s;&|(\`$])${GIT_SEG}`).test(shellProbe)) {
    const shellText = _stripShellComments(shellProbe);
    if (_unverifiableGitContent(shellText)) return "block";
    for (const inv of allGitInvocations(shellText)) {
      if (inv.verb === "__unverifiable__") return "block";
      invocations.push(inv);
    }
  }
  const { cmds, unresolved } = extractCodeGitCommandsDetailed(c);
  for (const cmd of cmds) {
    if (_unverifiableGitContent(cmd)) return "block";
    for (const inv of allGitInvocations(cmd)) {
      if (inv.verb === "__unverifiable__") return "block";
      invocations.push(inv);
    }
  }
  if (invocations.length > 0 && _gitInvocationsVerdict(invocations, currentBranch, executionCwd, sessionCwd) === "block") return "block";
  // Fail-closed PER REFERENCE (#627 reviewer P2: a resolved read-only op must
  // not launder an unresolved mutation elsewhere in the same payload): a
  // command-shaped `git` anchor with no resolvable verb (payload variable,
  // concatenated string) is unverifiable — static analysis cannot prove it
  // git-free.
  if (unresolved > 0) return "block";
  return "allow";
}

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
    // Round-4 F1 (post-fix reviewer P2): the fdSingle forms are ONLY the
    // GLUED fd-dup/close operators with digits or a dash (`2>&1`, `2>&-`,
    // `>&1`, `<&0`, `>&-`) — a BARE `>&`/`<&` (zero digits, no dash) takes a
    // word OPERAND like any redirect (`>& git` dups stdout+stderr to the FILE
    // `git`; `<& file` dups stdin from the file) and must skip op+operand, or
    // the operand word is walked as a command and phantom-counted (the same
    // phantom-token ordinal drift the extractor now skips). Also `<<<`
    // here-strings: _tokenize splits `<<<` into `<<` + `<` + word — consume
    // the split `<` with the operator and the WORD as the operand (real bash:
    // `<<< git` feeds `git` to stdin, never executes it).
    if (t === "<<" && tokens[i + 1] === "<") { i += 3; continue; } // <<< word (here-string)
    if (t === ">" || t === ">>" || t === "<" || t === "<<" || t === "&>" || t === ">&" || t === "&>>" || /^(?:[0-9]+)?[<>]/.test(t) || /^[0-9]+[<>]&[0-9]*-?$|^[0-9]+[<>]&-$|^[<>]&(?:[0-9]+|-)$/.test(t)) {
      const fdSingle = /^[0-9]+[<>]&[0-9]*-?$|^[0-9]+[<>]&-$|^[<>]&(?:[0-9]+|-)$/.test(t); // 2>&1 — no separate operand
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
        // 'git reset'` ran the inline (probe moved HEAD). Round-4 F1 (post-fix
        // reviewer P2): fdSingle requires digits or a dash — bare `>&`/`<&`
        // take a word operand (`>& git` = stdout+stderr to the FILE `git`).
        if (/^[0-9]+[<>]&[0-9]*-?$|^[0-9]+[<>]&-$|^[<>]&(?:[0-9]+|-)$/.test(n)) { j++; continue; }
        // Round-18 (final gate P1): skip redirect operators + operands too
        // (`bash < /dev/null -c 'git commit'` broke at the bare `<` and never
        // walked the inline — probe; the inline committed to the hub).
        if (n === ">" || n === ">>" || n === "<" || n === "<<" || n === "&>" || n === ">&" || n === "&>>" || /^(?:[0-9]+)?[<>]/.test(n)) {
          if (n === "<<" && tokens[j + 1] === "<") j += 3; // <<< here-string (round-4 F1)
          else j += 2;
          continue;
        }
        const isInlineC = n === "-c" || n === "--command" || (/^-[A-Za-z]*c[A-Za-z]*$/.test(n) && !n.startsWith("--"));
        if (isInlineC) {          // Round-5 (security F3): skip flags AFTER -c too — `bash -c -x 'git
          // reset'` takes the first NON-flag token as the command string.
          // Round-7 (reviewer P1): a single-dash LETTER RUN containing c
          // (`bash -lc '…'`, `sh -ec '…'`) is the same inline form — bash
          // parses the run char-by-char, and `extractScriptPath` already knew
          // that; the walker did not, so the payload was skipped as a script.
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
                // #596 round-3: an interpreter-inline (`sh -c '…'`) payload is
                // ONE opaque token to branch-ownership's tokenizer — its git
                // invocations are invisible there, so they must never shift the
                // stateVerbOccurrence ordinal the repo layer resolves with.
                cmdVisible: false,
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
    // #627: non-shell CODE interpreters (python/node/ruby/perl/php/…) — the
    // sibling of the shell script backdoor above. Recurse the INLINE payload's
    // reconstructed git candidates through this same walker so the structured
    // classifier (M2/M3/M4 + #347 per-invocation target resolution) sees
    // code-carried git ops; the payload is one opaque token to branch-
    // ownership's tokenizer (cmdVisible:false). FILE payloads are read by
    // index.ts's _backdoorBlock via codePayloadGitVerdict — the walker stays
    // fs-free. Position handling mirrors the shell branch (which intentionally
    // over-matches `echo bash -c '…'`): the sink requirement inside
    // extractCodeGitCommands keeps inert literals from becoming candidates.
    if (_codeInterpreterFamily(t)) {
      const payload = _codePayloadFromTokens(tokens, i);
      if (payload && payload.kind === "inline" && typeof payload.value === "string") {
        const base = [...frame().chain];
        for (const cand of extractCodeGitCommands(payload.value)) {
          const nested = allGitInvocations(cand, frame().vars);
          for (const ni of nested) {
            h.onGitEnd?.({
              ...ni,
              cdChain: [...base, ...ni.cdChain],
              cHints: [...(frame().pipeActive ? frame().chain.slice(0, frame().baseLen) : []), ...ni.cHints],
              cmdVisible: false,
            });
          }
        }
      }
      // #627 reviewer P1: emit the script-token signal so commandExecutionCwd
      // returns the code invocation's cd-chain (the #347 worktree-parity base
      // `_backdoorBlock` resolves the payload against). Without this,
      // `cd <wt> && python3 -c '…git commit…'` resolved against the hub and
      // false-blocked the documented worktree case.
      h.onScriptToken?.([...frame().chain]);
      i = payload ? payload.end : i + 1;
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
              cmdVisible: false,
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
    // #596 round-3: cmdVisible = this git invocation was spelled with the
    // LITERAL token `git` (vs a $VAR-resolved word `G=git; $G branch …` or an
    // absolute path `/usr/bin/git branch …`) — the only spellings
    // branch-ownership's extractGitInvocation can see. Extractor-invisible
    // invocations must never shift the stateVerbOccurrence ordinal the repo
    // layer resolves with, and a SELECTED mutation that is invisible resolves
    // its M3 repo at the session cwd (index.ts).
    const cmdVisible = t === "git";
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
        // classify as a bare push of the current branch). fdSingle forms need
        // digits or a dash (bare `>&`/`<&` take a word operand — round-4 F1
        // post-fix reviewer P2); `<<<` here-strings are `<<` + split `<` + word.
        if (g === "<<" && tokens[i + 1] === "<") { i += 3; continue; }
        if (g === ">" || g === ">>" || g === "<" || g === "<<" || g === "&>" || g === ">&" || g === "&>>" || /^(?:[0-9]+)?[<>]/.test(g) || /^[0-9]+[<>]&[0-9]*-?$|^[0-9]+[<>]&-$|^[<>]&(?:[0-9]+|-)$/.test(g)) {
          const fdSingle = /^[0-9]+[<>]&[0-9]*-?$|^[0-9]+[<>]&-$|^[<>]&(?:[0-9]+|-)$/.test(g); // 2>&1 — no separate operand
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
      cmdVisible,
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

// ── #709: working-tree-discard family (command layer) ──────────────────────
// The legacy destructive arms key on the VERB and exempt worktrees wholesale,
// so the incident verb (`git checkout -- <path>`) runs ungated (it classifies
// `allow`; test.mjs pins that) and every OTHER discard verb is worktree-exempt.
// This extractor names the commands whose EFFECT is to rewrite working-tree
// content from the index/a commit, so index.ts can key the gate on
// `git status` (does the discard destroy uncommitted work?) instead of on argv.
//
// Deliberately SEPARATE from classifyGitCommand(Detailed): those verdicts are
// pinned by test.mjs and consumed by the M2/M3/M4 arms — widening them would
// change those arms. PURE (no git, no fs); index.ts does the effect probe.
//
// Descriptor: { form, scope: "all"|"paths"|"revert-hints", pathspecs,
//               fromTree, verb, args, inv }
//   scope "all"   — the whole checkout is discarded (checkout -f, reset --hard,
//                   switch --discard-changes)
//   scope "paths" — only the listed pathspecs
//   fromTree      — the SOURCE is a tree/commit, so a staged-only change is
//                   destroyed too. `checkout -- <paths>` / bare `restore`
//                   restore from the INDEX: only a worktree-vs-index
//                   difference is lost.
//
// NOT in the family (documented residuals):
//   - `git clean`   — untracked-only. It never touches TRACKED work, and
//                     build-artifact cleanup (`git clean -fdx`) in a private
//                     worktree is ordinary; the hub-state (M4) and legacy arms
//                     still block it in a shared main checkout.
//   - `git stash push` — stores, does not discard.
//   - `git restore --staged` alone — index-only; git leaves the working-tree
//                     content in place and re-adding recovers it (#709 note).
//   - `cp <backup> <tracked>` and arbitrary interpreter writers that rewrite a
//                     tracked file from a non-git source — indistinguishable
//                     from an edit without reading content; the #625 in-place
//                     overwrite gate already covers the shared-main case.
const _WT_DISCARD_FORCE_LONG = ["-f", "--force"];

/** Non-flag args of an invocation. */
function _wtDiscardPositionals(args) {
  return (args ?? []).filter((a) => a !== "--" && !String(a).startsWith("-"));
}

/** Does a single-dash short cluster contain `letter` (`-fq` ≡ `-f -q`)?
 *  Digits are legal cluster members too (`git apply -R3` ≡ `-R -3`, reviewer
 *  round-3 P1: the digit-less regex let `-R3`/`-3R` revert a patch ungated). */
function _wtDiscardShortCluster(args, letter) {
  return (args ?? []).some((a) => /^-[A-Za-z0-9]+$/.test(a) && a.slice(1).includes(letter));
}

/**
 * git accepts any UNAMBIGUOUS long-option prefix (`--har` ≡ `--hard`,
 * `--discard-ch` ≡ `--discard-changes`). Exact-spelling tests are therefore a
 * FAIL-OPEN bypass (reviewer-reproduced: `git reset --har` destroyed a dirty
 * file while M5 allowed it). Over-matching is safe here — a block still needs
 * the effect probe to find uncommitted work.
 */
function _wtLongPrefix(token, full) {
  const t = String(token ?? "");
  return t === full || (t.startsWith("--") && t.length > 2 && full.startsWith(t));
}

/** Any arg matching a long flag by exact spelling or unambiguous prefix. */
function _wtHasLong(args, full) {
  return (args ?? []).some((t) => _wtLongPrefix(t, full));
}

/** git's noarg force spellings, incl. unambiguous long prefixes (`--forc`). */
function _wtDiscardForce(args) {
  const a = args ?? [];
  return a.some((t) => _WT_DISCARD_FORCE_LONG.includes(t)) ||
    _wtHasLong(a, "--force") ||
    _wtDiscardShortCluster(a, "f");
}

/** `--pathspec-from-file[=f]` / `--pathspec-file-nul` hide the target list in a
 *  FILE — the effect is not statically resolvable → the caller fails closed. */
function _wtHasPathspecFile(args) {
  return (args ?? []).some((t) => String(t).startsWith("--pathspec-from-file") || String(t) === "--pathspec-file-nul");
}

/** xargs/find `-exec` placeholders — the real pathspec is supplied at runtime.
 *  Exported so index.ts's fail-closed set has ONE implementation (a second
 *  inline copy had already drifted — reviewer round-4 P2). */
export function wtIsPlaceholderPathspec(p) {
  const s = String(p);
  return s === "{}" || s === "{}+" || s === "+" || s.includes("{}");
}

function _wtDiscardFromCheckout(args) {
  const a = args ?? [];
  if (_wtHasPathspecFile(a)) return { scope: "all", pathspecs: [], fromTree: false, form: "checkout-pathspec-file", unverifiable: true };
  // Conflict-resolution spellings (`--ours`/`--theirs`/`-m`/`--merge`/
  // `--conflict=<style>`) are the SANCTIONED way to resolve an UNMERGED path —
  // `discardDestroysWip` skips `U`/`AA`/`DD` entries. But on a plain MODIFIED
  // file they are a normal index-source checkout that destroys WIP (reviewer
  // round-3 P1, probe-verified against real git: `git checkout --ours
  // dirty.txt` reverted the file). So emit a descriptor and let the EFFECT
  // probe decide — the unmerged skip keeps real conflict resolution working.
  const conflictish = a.some((t) => t === "--ours" || t === "--theirs" || t === "-m" ||
    _wtLongPrefix(t, "--merge") || _wtLongPrefix(t, "--conflict") || String(t).startsWith("--conflict=") ||
    // `-2`/`-3` are the numeric stage shortcuts for `--ours`/`--theirs`
    // (`-2q` too) — same effect-keyed path (reviewer round-4 P2).
    (/^-[0-9qv]+$/.test(String(t)) && /[23]/.test(String(t))));
  if (conflictish) {
    const cdd = a.indexOf("--");
    const cpos = (cdd !== -1 ? a.slice(cdd + 1) : _wtDiscardPositionals(a)).filter(Boolean);
    // `git checkout -m <branch>` (no path) is a switch-with-merge, not a path
    // restore — leave it out (the M3 branch arm owns switching).
    if (cpos.length === 0) return null;
    return { scope: "paths", pathspecs: cpos, fromTree: false, form: "checkout-conflict" };
  }
  const creates = a.some((t) => /^-[bBcCt]/.test(String(t)) || t === "--orphan" || t === "--detach" || t === "--track");
  const dd = a.indexOf("--");
  if (dd !== -1) {
    // After `--` EVERY token is a pathspec (leading dashes included: `-x` is a
    // legal filename). Zero pathspecs (`git checkout --` fed by xargs) is a
    // runtime-supplied target list → conservative scope `all`.
    const pathspecs = a.slice(dd + 1).filter((p) => p !== "");
    if (pathspecs.length === 0) return { scope: "all", pathspecs: [], fromTree: false, form: "checkout-pathspec-empty" };
    // A tree-ish before `--` overwrites the index too; flags do not count
    // (reviewer P2: `git checkout -q -- f` is index-source).
    const fromTree = a.slice(0, dd).some((t) => t !== "--" && !String(t).startsWith("-"));
    return { scope: "paths", pathspecs, fromTree, form: "checkout-paths" };
  }
  // Bare path forms git accepts without `--`: `git checkout .`, `./x`, `:/x`,
  // `:(magic)` (a ref can never start with `:`) — and a SINGLE bare token,
  // which git resolves as a ref (switch) only when it names one; otherwise it
  // is a path restore (`git checkout f.txt` reverts f.txt — the incident verb's
  // twin without `--`, reviewer round-4 P1). The ref-vs-path ambiguity is
  // resolved by the caller's `rev-parse` probe before the effect probe.
  const pos = _wtDiscardPositionals(a);
  const pathish = pos.filter((p) => p === "." || String(p).startsWith("./") || String(p).startsWith(":"));
  if (pathish.length > 0) {
    return { scope: "paths", pathspecs: pathish, fromTree: pos.length > pathish.length, form: "checkout-paths-bare" };
  }
  // `git checkout <tree-ish> <paths>` WITHOUT `--` is a real path restore in
  // git (reviewer P1: `git checkout HEAD a.txt` destroyed a dirty file). Only
  // when a branch-create flag is present is the token list a create form.
  if (!creates && pos.length >= 2) {
    // `pos[0]` is a tree-ish ONLY when it names a commit; otherwise git treats
    // EVERY positional as a pathspec (reviewer round-7 P1: `git checkout
    // dirty.txt clean.txt` silently dropped the first path from the probe).
    // The handler's `rev-parse` probe resolves it (`ambiguousTree`).
    return { scope: "paths", pathspecs: pos.slice(1), fromTree: true, form: "checkout-treish-paths", ambiguousTree: pos[0], allPathspecs: pos };
  }
  // `git checkout -p/--patch` discards selected hunks interactively — the same
  // effect as `git restore -p` (which the restore helper already gates).
  if (_wtDiscardShortCluster(a, "p") || _wtHasLong(a, "--patch")) {
    if (pos.length === 0) return { scope: "all", pathspecs: [], fromTree: false, form: "checkout-patch-all" };
    return { scope: "paths", pathspecs: pos, fromTree: false, form: "checkout-patch" };
  }
  if (_wtDiscardForce(a)) {
    // `git checkout -f <one token>`: a REF is a forced switch (discards ALL
    // local changes → whole-tree scope); a PATH restores just that path. The
    // handler's `rev-parse` probe resolves it (reviewer round-5 P2 false
    // positive: `git checkout -f clean.txt` blocked on an unrelated dirty
    // file).
    if (!creates && pos.length === 1) {
      return { scope: "all", pathspecs: pos, fromTree: false, form: "checkout-force", ambiguousRef: true, refIsAll: true };
    }
    return { scope: "all", pathspecs: [], fromTree: false, form: "checkout-force" };
  }
  // A single bare token is ref-or-path (see above) — checked LAST so
  // `-f main` / `-p f` keep their force/patch semantics.
  if (!creates && pos.length === 1) {
    return { scope: "paths", pathspecs: pos, fromTree: false, form: "checkout-bare-path", ambiguousRef: true };
  }
  return null;
}

function _wtDiscardFromRestore(args) {
  const a = args ?? [];
  // `--staged` is the EXACT `-S` (or a cluster that is not the attached
  // `-s<ref>` form): `git restore -sSTABLE f` restores from the ref STABLE, and
  // reading it as `--staged` made the arm return null — index-only — while git
  // destroyed the worktree (reviewer round-7 P1).
  const stagedTok = a.find((t) => _wtLongPrefix(t, "--staged") || t === "-S" ||
    (/^-[A-Za-z0-9]+$/.test(String(t)) && !/^-s/.test(String(t)) && String(t).slice(1).includes("S")));
  // `--source=<rev>` (the `=` spelling) AND `-s <rev>` / `--source <rev>`.
  const sourceTok = a.find((t) => _wtLongPrefix(t, "--source") || String(t).startsWith("--source=") || t === "-s" || /^-s\S/.test(String(t)));
  const worktreeTok = a.find((t) => _wtLongPrefix(t, "--worktree") || t === "-W" || _wtDiscardShortCluster([t], "W"));
  // An ambiguous abbreviation (`--s`) matches BOTH --staged and --source —
  // never take the index-only early return for it.
  const ambiguous = !!stagedTok && !!sourceTok && stagedTok === sourceTok && String(stagedTok).startsWith("--");
  const staged = !!stagedTok && !ambiguous;
  const worktree = !!worktreeTok;
  // Index-only restore is explicitly non-destructive (#709) — checked BEFORE
  // the fail-closed pathspec-file branch, or `git restore --staged
  // --pathspec-from-file=list` would block an index-only reset (reviewer
  // round-5 P2).
  if (staged && !worktree) return null;
  if (_wtHasPathspecFile(a)) return { scope: "all", pathspecs: [], fromTree: true, form: "restore-pathspec-file", unverifiable: true };
  // A `--source=<tree>` WITHOUT `--staged` restores the WORKTREE only — the
  // index keeps the staged blob, so a staged-only change is recoverable and
  // must not block (reviewer round-4 P2). The index is reset only when
  // `--staged` survives (with or without `--worktree`).
  const fromTree = staged;
  const pathspecs = [];
  for (let i = 0; i < a.length; i++) {
    const t = a[i];
    if (t === "--") { for (let j = i + 1; j < a.length; j++) if (a[j]) pathspecs.push(a[j]); break; }
    if (t === "-s" || _wtLongPrefix(t, "--source")) { i++; continue; }
    if (String(t).startsWith("--source=") || /^-s\S/.test(String(t))) continue;
    if (String(t).startsWith("-")) continue;
    pathspecs.push(t);
  }
  if (pathspecs.length === 0) {
    // `git restore` with no pathspec is a usage error (git does nothing) — the
    // round-1 xargs case is covered by the extractor's feeder fallback
    // (reviewer round-6 P2 false positive).
    return null;
  }
  return { scope: "paths", pathspecs, fromTree, form: "restore-worktree" };
}

function _wtDiscardFromSwitch(args) {
  const a = args ?? [];
  if (_wtHasLong(a, "--discard-changes") || _wtDiscardForce(a)) {
    return { scope: "all", pathspecs: [], fromTree: false, form: "switch-discard" };
  }
  return null;
}

function _wtDiscardFromReset(args) {
  const a = args ?? [];
  if (!_wtHasLong(a, "--hard")) return null;
  const dd = a.indexOf("--");
  if (dd !== -1) {
    const pathspecs = a.slice(dd + 1).filter(Boolean);
    if (pathspecs.length > 0) return { scope: "paths", pathspecs, fromTree: true, form: "reset-hard-paths" };
  }
  return { scope: "all", pathspecs: [], fromTree: false, form: "reset-hard" };
}

function _wtDiscardFromCheckoutIndex(args) {
  const a = args ?? [];
  // Without -f/--force git REFUSES to overwrite a modified file — nothing to gate.
  if (!_wtDiscardForce(a)) return null;
  // `--prefix=<dir>` / `--temp` EXPORT the index elsewhere (the documented
  // `git checkout-index -a -f --prefix=/tmp/out/` recipe) — the working tree is
  // untouched (reviewer round-3 P2 false positive).
  if (a.some((t) => String(t).startsWith("--prefix") || String(t) === "--temp" || _wtDiscardShortCluster([String(t)], "t"))) return null;
  if (_wtHasPathspecFile(a)) return { scope: "all", pathspecs: [], fromTree: true, form: "checkout-index-pathspec-file", unverifiable: true };
  // `--stdin`/`-z` supply the path list on STDIN — not statically resolvable
  // (reviewer round-3 P1: `printf 'f\n' | git checkout-index -f --stdin`
  // restored the file while M5 allowed it).
  if (a.some((t) => t === "--stdin" || t === "-z")) return { scope: "all", pathspecs: [], fromTree: false, form: "checkout-index-stdin", unverifiable: true };
  if (_wtDiscardShortCluster(a, "a") || _wtHasLong(a, "--all")) {
    // `checkout-index` copies FROM the index: a staged-only entry is already in
    // the worktree, so only a WORKTREE-vs-index difference (Y ≠ ' ') is
    // destroyed. Expressed as the whole-tree pathspec scope (reviewer round-4
    // P2: `fromTree` here false-blocked staged-only work).
    return { scope: "paths", pathspecs: ["."], fromTree: false, form: "checkout-index-all" };
  }
  const dd = a.indexOf("--");
  const pathspecs = (dd !== -1 ? a.slice(dd + 1) : _wtDiscardPositionals(a)).filter(Boolean);
  if (pathspecs.length === 0) return null;
  return { scope: "paths", pathspecs, fromTree: false, form: "checkout-index" };
}

/** `git rm -f <paths>` deletes index+worktree entries (a discard of the file's
 *  uncommitted content). Without -f git refuses to remove a modified file. */
function _wtDiscardFromRm(args) {
  const a = args ?? [];
  // `--cached` removes the INDEX entry only (worktree file untouched) and
  // `-n`/`--dry-run` deletes nothing — both are read-only w.r.t. the working
  // tree (reviewer round-3 P2 false positives; same class as `restore
  // --staged`).
  if (a.some((t) => _wtLongPrefix(t, "--cached") || _wtLongPrefix(t, "--dry-run") || t === "-n" || _wtDiscardShortCluster([t], "n"))) return null;
  if (!_wtDiscardForce(a)) return null;
  const dd = a.indexOf("--");
  const pathspecs = (dd !== -1 ? a.slice(dd + 1) : _wtDiscardPositionals(a)).filter(Boolean);
  if (pathspecs.length === 0) return { scope: "all", pathspecs: [], fromTree: true, form: "rm-force-all" };
  return { scope: "paths", pathspecs, fromTree: true, form: "rm-force" };
}

/** `git read-tree --reset -u HEAD` overwrites index+worktree wholesale. */
function _wtDiscardFromReadTree(args) {
  const a = args ?? [];
  if (!_wtHasLong(a, "--reset")) return null;
  if (!(_wtDiscardShortCluster(a, "u") || _wtHasLong(a, "--update"))) return null;
  return { scope: "all", pathspecs: [], fromTree: true, form: "read-tree-reset-update" };
}

/** `git apply -R <patch>` reverses an applied patch — a one-command revert of
 *  tracked WIP. The touched paths live in the patch file (not statically
 *  known), so the scope is conservatively `all` (reviewer round-2 P2). */
function _wtDiscardFromApply(args) {
  const a = args ?? [];
  const reversed = a.some((t) => String(t) === "--reverse" ||
    (String(t).length >= 5 && String(t).startsWith("--rev") && "--reverse".startsWith(String(t)))) ||
    _wtDiscardShortCluster(a, "R");
  if (!reversed) return null;
  // Dry-run / reporting flags mean NOTHING is applied (reviewer round-3 P2:
  // `git apply -R --check|--stat|--numstat|--summary` only reports).
  if (a.some((t) => _wtLongPrefix(t, "--check") || _wtLongPrefix(t, "--stat") ||
    _wtLongPrefix(t, "--numstat") || _wtLongPrefix(t, "--summary"))) return null;
  // `--cached` is index-only — not a WORKING-TREE discard (reviewer round-4 P2,
  // same class as `restore --staged`).
  if (a.some((t) => _wtLongPrefix(t, "--cached"))) return null;
  // Default `git apply` writes the WORKTREE only; `--index` and `--3way`
  // (implied by a `-3` cluster member) also overwrite the index.
  const indexTouch = a.some((t) => _wtLongPrefix(t, "--index") || _wtLongPrefix(t, "--3way") ||
    (/^-[A-Za-z0-9]+$/.test(String(t)) && String(t).slice(1).includes("3")));
  return { scope: "all", pathspecs: [], fromTree: indexTouch, form: "apply-reverse" };
}

/**
 * Blank heredoc DATA bodies and `#` comments before extraction.
 *
 * The shared `allGitInvocations` walker parses heredoc bodies as command text,
 * so `cat <<'EOF' … git checkout -- x … EOF` produced a phantom descriptor
 * (reviewer P2 false positive). A body is DATA unless its consumer executes its
 * stdin — a SHELL or a CODE interpreter (`python3 <<PY`, `perl <<P`, `node`) —
 * or the body is piped INTO one (`cat <<'EOF' | bash`), in which case it is
 * real code and is kept (and re-extracted, because the walker does not reach
 * the piped form). Comments are shell comments only when unquoted, so the scan
 * is quote-aware: `echo "a << b"` did NOT open a heredoc, and a mid-line
 * `# git reset --hard` is NOT a command (reviewer round-2 P1/P2 false
 * positives + a quote-blind phantom-heredoc BLINDING bug).
 * One pending heredoc at a time — multiple openers on one line is a documented
 * residual (the first body is blanked, the rest are parsed normally).
 */
const _WT_SPAWNER_WORDS = new Set(["env", "nice", "nohup", "command", "sudo", "doas", "setsid", "stdbuf", "time", "timeout", "exec", "ionice", "busybox"]);
const _WT_KEYWORDS = new Set(["then", "do", "else", "elif", "if", "while", "until", "for", "done", "fi", "esac", "case", "in", "!", "time", "eval", "true", "false", ":", "set", "export", "declare", "local", "return", "test", "cd", "shopt"]);
const _WT_SHELL_WORDS = /^(?:bash|sh|zsh|dash|ksh|ash|mksh|oksh|fish|csh|tcsh|source|\.)$/;
const _WT_CODE_WORDS = /^(?:python[0-9.]*|perl|ruby|node|nodejs|pwsh|powershell|deno|osascript|php|lua|Rscript)$/;

/**
 * The interpreter a heredoc-feeding line actually runs, skipping spawner
 * wrappers and their flags/operands (`env bash`, `nice bash`, `timeout 5
 * bash`, `sudo -u root /bin/sh`, `busybox sh`) and accepting absolute paths
 * (`/bin/sh`). Returns the token, or null when the head is not an interpreter
 * (`grep bash f` must NOT read as one — reviewer round-3 P1).
 */
function _wtHeadInterpreter(line) {
  const toks = String(line).trim().split(/[\s;|&()]+/).filter(Boolean);
  const isInterp = (t) => {
    const b = basename(String(t));
    return _WT_SHELL_WORDS.test(b) || _WT_CODE_WORDS.test(b);
  };
  for (let i = 0; i < toks.length; i++) {
    const t = toks[i];
    if (isInterp(t)) return t;
    if (i === 0) {
      // Only a spawner / shell keyword / env-assignment / flag / REDIRECTION
      // may precede the interpreter (`then bash <<EOF`, `2>/dev/null bash
      // <<EOF` — reviewer round-6 P1).
      const ok = _WT_SPAWNER_WORDS.has(t) || _WT_KEYWORDS.has(t) || t.startsWith("-") ||
        /^[A-Za-z_][A-Za-z0-9_]*=/.test(t) || /^[0-9]*[<>]/.test(t);
      if (!ok) return null;
    }
  }
  return null;
}

/**
 * Split a comment-stripped opener line into command segments on UNQUOTED
 * list operators, then return the segment that owns the `<<`. The consumer is
 * not necessarily the first token of the LINE (`true && bash <<EOF`,
 * `set -e; bash <<EOF`, `{ bash <<EOF`) — reading the whole line as if the head
 * were the consumer blanked a body the walker would otherwise have parsed
 * (reviewer round-4 P1).
 */
function _wtOpenerSegment(line) {
  const s = String(line ?? "");
  const segs = [];
  let cur = "";
  let quote = null;
  let opened = -1; // index of the segment owning the first UNQUOTED `<<`
  for (let i = 0; i < s.length; i++) {
    const ch = s[i];
    if (quote) { if (ch === quote) quote = null; cur += ch; continue; }
    if (ch === "\\") { cur += ch + (s[i + 1] ?? ""); i++; continue; }
    if (ch === "'" || ch === '"') { quote = ch; cur += ch; continue; }
    // A QUOTED `<<` (`echo 'a<<b' && bash <<EOF`) must not claim the opener —
    // that demoted the real shell heredoc to data and blanked its body
    // (reviewer round-5 P1).
    if (ch === "<" && s[i + 1] === "<" && opened === -1) { opened = segs.length; cur += "<<"; i++; continue; }
    if (ch === ";" || ch === "&" || ch === "|" || ch === "(" || ch === "{" || ch === "}" || ch === ")") {
      segs.push(cur); cur = ""; continue;
    }
    cur += ch;
  }
  segs.push(cur);
  return opened >= 0 ? segs[opened] : s;
}

/** A shell executes its stdin heredoc as SHELL text; a code interpreter
 *  (python/perl/ruby/node/…) executes it as CODE — the two need different
 *  extraction paths. `null` = a positively identified DATA consumer (body is
 *  not code). An UNRESOLVABLE head (`$SH <<EOF`, `$(which sh) <<EOF`) is not
 *  proof of a data consumer → the body is kept so the walker can see it
 *  (fail toward detection, never toward silently blanking code). */
function _wtHeredocKind(line) {
  if (_wtLinePipesToInterpreter(line)) return "shell";
  const seg = _wtOpenerSegment(line);
  const interp = _wtHeadInterpreter(seg);
  if (interp === null) return /[$`]/.test(seg) ? "shell" : null;
  return _WT_SHELL_WORDS.test(basename(String(interp))) ? "shell" : "code";
}
function _wtLinePipesToInterpreter(line) {
  return String(line).split("|").slice(1).some((seg) => _wtHeadInterpreter(seg) !== null);
}

/** Quote-aware scan of one line: returns the comment-stripped text and the
 *  delimiter of the FIRST unquoted heredoc opener (or null).
 *
 *  `#` starts a comment only at a WORD START — after real whitespace or a list
 *  operator, not after an ESCAPED whitespace. Testing the raw preceding char
 *  treated `echo a\ #b && git checkout -- f` as a comment and truncated the
 *  live discard off the line (reviewer round-4 P1).
 *
 *  Two further sharp edges (reviewer round-5 P1):
 *   - `<<` inside `(( ))`/`$(( ))` ARITHMETIC is a shift operator, not a
 *     heredoc — opening one blanked the rest of the command.
 *   - the delimiter is RE-EMITTED after `<<` (it used to be dropped), because
 *     the shared walker's redirect branch skips `<<` PLUS the next token — with
 *     the delimiter gone it ate the next real command word, so a discard on a
 *     later line (`cat <<EOF … EOF` then `git checkout -- f`) was invisible.
 *  `carry` threads quote/arithmetic state across lines (a `<<` inside a
 *  multi-line quoted string is not a heredoc either).
 */
function _wtScanLine(line, carry) {
  let i = 0;
  let out = "";
  let quote = carry?.quote ?? null;
  let arith = carry?.arith ?? 0;
  let delim = null;
  let atWordStart = carry?.atWordStart ?? true;
  while (i < line.length) {
    const ch = line[i];
    if (quote) {
      if (ch === quote) quote = null;
      out += ch; i++; atWordStart = false; continue;
    }
    if (arith > 0) {
      if (ch === "(" && line[i + 1] === "(") { arith++; out += "(("; i += 2; continue; }
      if (ch === ")" && line[i + 1] === ")") { arith--; out += "))"; i += 2; continue; }
      out += ch; i++; atWordStart = false; continue;
    }
    if (ch === "\\") { out += ch + (line[i + 1] ?? ""); i += 2; atWordStart = false; continue; }
    if (ch === "(" && line[i + 1] === "(") { arith++; out += "(("; i += 2; atWordStart = false; continue; }
    if (ch === "'") { quote = ch; out += ch; i++; atWordStart = false; continue; }
    if (ch === '"') { quote = ch; out += ch; i++; atWordStart = false; continue; }
    if (ch === "#" && atWordStart) break; // comment
    if (ch === " " || ch === "\t" || ch === ";" || ch === "&" || ch === "|" || ch === "(") {
      out += ch; i++; atWordStart = true; continue;
    }
    if (ch === "<" && line[i + 1] === "<") {
      let j = i + 2;
      if (line[j] === "-") j++;
      while (line[j] === " " || line[j] === "\t") j++;
      let q = null;
      if (line[j] === "'" || line[j] === '"') { q = line[j]; j++; }
      let d = "";
      // An UNQUOTED delimiter is a shell word: it stops at whitespace / shell
      // metacharacters, NOT at the first non-word char. Stopping early (`<<E-O-F`
      // → delimiter `E`) left the terminator unmatched, so the body swallowed
      // every following line — including a later discard (reviewer round-6 P1).
      while (j < line.length && (q ? line[j] !== q : !/[\s;&|<>(){}'"\\]/.test(line[j]))) { d += line[j]; j++; }
      if (q && line[j] === q) j++;
      if (d && delim === null) delim = d;
      // Re-emit the delimiter so the walker's `<<` + operand skip consumes the
      // placeholder, never the next real command token. An opener with no
      // delimiter (`<<` in arithmetic) emits bare `<<`.
      out += d ? `<< ${d}` : "<<";
      i = j;
      continue;
    }
    out += ch; i++; atWordStart = false;
  }
  if (carry) { carry.quote = quote; carry.arith = arith; carry.atWordStart = atWordStart; }
  return { text: out, delim };
}

function _wtStripHeredocData(text, codeBodies) {
  const lines = String(text ?? "").split("\n");
  const out = [];
  let pending = null; // { delim, kind, buf }
  const carry = { quote: null, arith: 0, atWordStart: true };
  for (const line of lines) {
    if (pending) {
      const t = line.trim();
      if (t === pending.delim) {
        out.push("");
        if (pending.kind && codeBodies) codeBodies.push({ kind: pending.kind, text: pending.buf.join("\n") });
        pending = null;
        continue;
      }
      if (pending.kind) { out.push(line); pending.buf.push(line); continue; }
      out.push("");
      continue;
    }
    const { text: code, delim } = _wtScanLine(line, carry);
    if (delim !== null) pending = { delim, kind: _wtHeredocKind(code), buf: [] };
    out.push(code);
  }
  return out.join("\n");
}

/** `git show <rev>:<path>` / `cat-file` committed-path hints (the manual
 *  revert shape `git show HEAD:x > x`). Slashy revs (`refs/heads/main:p`,
 *  `origin/main:p`) and the INDEX source (`:p`) are the same revert — the
 *  hint is intersected with the command's write targets, so over-matching is
 *  safe (reviewer round-4 P2). */
function _wtDiscardShowTargets(args) {
  const out = [];
  for (const t of args ?? []) {
    if (t === "blob") continue;
    const idx = /^:(.+)$/.exec(String(t));
    if (idx) { out.push(idx[1]); continue; }
    const m = /^([^:\s]+):(.+)$/.exec(String(t));
    if (m && m[2]) out.push(m[2]);
  }
  return out;
}

/**
 * Quote-aware backtick command-substitution spans. The shared walker tokenizes
 * `$( … )` but a backtick span stays inside one token, so `` `git checkout --
 * f` `` produced no descriptor (reviewer round-3 P2). Single quotes suppress
 * substitution; inside double quotes it still runs.
 */
function _wtBacktickSpans(text) {
  const s = String(text ?? "");
  const out = [];
  const capture = (from) => {
    let j = from;
    let buf = "";
    while (j < s.length && s[j] !== "`") { if (s[j] === "\\") { j++; if (j >= s.length) break; } buf += s[j]; j++; }
    if (buf.trim()) out.push(buf);
    return j + 1;
  };
  let i = 0;
  let inSingle = false;
  let inDouble = false;
  while (i < s.length) {
    const ch = s[i];
    if (ch === "\\") { i += 2; continue; }
    if (inSingle) {
      if (ch === "'") inSingle = false;
      i++;
      continue;
    }
    // Inside double quotes an apostrophe is ORDINARY — it must not flip the
    // single-quote state and hide a later backtick (reviewer round-4 P2).
    if (inDouble) {
      if (ch === '"') { inDouble = false; i++; continue; }
      if (ch === "`") { i = capture(i + 1); continue; }
      i++;
      continue;
    }
    if (ch === "'") { inSingle = true; i++; continue; }
    if (ch === '"') { inDouble = true; i++; continue; }
    if (ch === "`") { i = capture(i + 1); continue; }
    i++;
  }
  return out;
}

/**
 * `git -c alias.<name>=<cmd>` / `git config alias.<name> <cmd>` definitions
 * INSIDE this command, so a later `git <name> …` can be resolved instead of
 * sailing past the verb-keyed extractor (reviewer round-3 P2: `git -c
 * alias.z='checkout --' z dirty.txt` reverted a dirty file). An alias defined
 * in an EARLIER command is a documented residual (needs a config read).
 */
function _wtInlineAliases(command) {
  const map = {};
  for (const m of String(command ?? "").matchAll(/alias\.([A-Za-z0-9._-]+)=("[^"]*"|'[^']*'|\S+)/g)) {
    map[m[1]] = String(m[2]).replace(/^['"]|['"]$/g, "");
  }
  for (const m of String(command ?? "").matchAll(/\bgit\s+config\s+(?:--\S+\s+)*alias\.([A-Za-z0-9._-]+)\s+("[^"]*"|'[^']*'|\S+)/g)) {
    map[m[1]] = String(m[2]).replace(/^['"]|['"]$/g, "");
  }
  return map;
}

/**
 * ANSI-C command words: bash expands `$'\x67it'` to `git` BEFORE execution, so
 * the walker must see the decoded form (reviewer round-4 P2). M5-only
 * pre-pass — the shared tokenizer is untouched. Brace alternation (`{git,}`)
 * and a command-position `$(…)` remain in the documented open-ended
 * grammar-spelling residual (README Residuals 1/3).
 */
function _wtAnsiDecode(text) {
  return String(text ?? "").replace(/\$'([^']*)'/g, (m, body) => {
    const decoded = _ansiTranslate(body);
    // Only substitute when the decoded text is a single PLAIN command word.
    // Decoding arbitrary bytes used to inject real shell syntax into the text
    // (`echo $'"' ; git checkout -- f` decoded to an unclosed quote and blinded
    // everything after it) — reviewer round-5 P1.
    return /^[A-Za-z0-9_./-]+$/.test(decoded) ? decoded : m;
  });
}

/**
 * Quote-aware `$( … )` command-substitution spans (paren-balanced). The shared
 * walker tokenizes a QUOTED substitution as part of one word and never
 * descends, so `echo "$(git checkout -- f)"` produced no descriptor — even
 * though double quotes do not stop substitution (reviewer round-5 P2).
 */
function _wtSubstSpans(text) {
  const s = String(text ?? "");
  const out = [];
  let i = 0;
  let inSingle = false;
  while (i < s.length) {
    const ch = s[i];
    if (ch === "\\") { i += 2; continue; }
    if (inSingle) { if (ch === "'") inSingle = false; i++; continue; }
    if (ch === "'") { inSingle = true; i++; continue; }
    if (ch === "$" && s[i + 1] === "(") {
      let depth = 1;
      let j = i + 2;
      let buf = "";
      let q = null;
      while (j < s.length && depth > 0) {
        const c = s[j];
        if (q) { if (c === q) q = null; buf += c; j++; continue; }
        if (c === "'") { q = c; buf += c; j++; continue; }
        if (c === "\"") { q = c; buf += c; j++; continue; }
        if (c === "(") depth++;
        else if (c === ")") { depth--; if (depth === 0) { j++; break; } }
        buf += c; j++;
      }
      if (buf.trim()) out.push(buf);
      i = j;
      continue;
    }
    i++;
  }
  return out;
}

/** The verbs `extractWorkingTreeDiscards` keys on (a feeder-fed invocation of
 *  one of these with no resolvable pathspec is conservatively whole-tree). */
/** Terminal global flags: `git --version` can NEVER take a feeder-supplied
 *  subcommand (reviewer round-11 P2) — but the walker consumes such flags, so
 *  the invocation arrives with EMPTY args and is indistinguishable from the
 *  bare feeder-fed `git` this arm exists for. The narrow fail-closed cost is
 *  documented in the README instead of guessed at here. */
const _WT_FAMILY_VERBS = new Set(["checkout", "restore", "switch", "reset", "checkout-index", "rm", "read-tree", "apply"]);

/**
 * Payloads a shell interpreter reads from its STDIN: here-strings
 * (`bash <<< 'git checkout -- f'`) and process substitution
 * (`bash <(printf 'git checkout -- f')`) on a line whose head IS a shell
 * interpreter. The shared walker cannot resolve these as command words, so the
 * caller fails closed when one mentions a discard-family verb. A non-interpreter
 * head (`echo <<< "git …"`, `diff <(ls) <(ls)`) is inert and skipped
 * (reviewer round-6 P1).
 */
function _wtStdinPayloads(text) {
  const out = [];
  for (const line of String(text ?? "").split("\n")) {
    if (!line.includes("<<<") && !line.includes("<(")) continue;
    const head = _wtHeadInterpreter(line);
    if (head === null || !_WT_SHELL_WORDS.test(basename(String(head)))) continue;
    const hs = /<<<\s*(?:'([^']*)'|"([^"]*)"|(\S+))/.exec(line);
    if (hs) out.push(hs[1] ?? hs[2] ?? hs[3] ?? "");
    for (let i = line.indexOf("<("); i !== -1; i = line.indexOf("<(", i + 2)) {
      let depth = 1;
      let j = i + 2;
      let buf = "";
      while (j < line.length && depth > 0) {
        const c = line[j];
        if (c === "(") depth++;
        else if (c === ")") { depth--; if (depth === 0) break; }
        buf += c; j++;
      }
      if (buf.trim()) out.push(buf);
    }
  }
  return out;
}

/**
 * Inline `-c` payloads of shell interpreters, one per command segment and
 * spawner/keyword aware (`bash -lc '…'`, `if x; then sh -ec '…'; fi`,
 * `env bash -c '…'`). Used by index.ts to fail closed on an OPAQUE payload and
 * to seed the script walk for a literal one (reviewer round-7 P1/P2).
 * @param {string} command
 * @returns {Array<{text: string, opaque: boolean}>}
 */
export function wtShellInlinePayloads(command) {
  const out = [];
  const text = String(command ?? "");
  const segs = [];
  let cur = "";
  let quote = null;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (quote) { if (ch === quote) quote = null; cur += ch; continue; }
    if (ch === "\\") { cur += ch + (text[i + 1] ?? ""); i++; continue; }
    if (ch === "'" || ch === '"') { quote = ch; cur += ch; continue; }
    if (ch === ";" || ch === "&" || ch === "|" || ch === "(" || ch === "{" || ch === "}" || ch === ")" || ch === "\n") {
      segs.push(cur); cur = ""; continue;
    }
    cur += ch;
  }
  segs.push(cur);
  for (const seg of segs) {
    const head = _wtHeadInterpreter(seg);
    if (head === null || !_WT_SHELL_WORDS.test(basename(String(head)))) continue;
    const toks = _wtShellWords(seg);
    for (let i = 0; i < toks.length; i++) {
      const t = toks[i];
      if (!(t === "-c" || t === "--command" || (/^-[A-Za-z]*c[A-Za-z]*$/.test(t) && !t.startsWith("--")))) continue;
      let k = i + 1;
      while (k < toks.length && toks[k].startsWith("-")) k++;
      const payload = toks[k];
      if (payload !== undefined) out.push({ text: payload, opaque: /[$`]/.test(payload) });
      break;
    }
  }
  return out;
}

/**
 * Quote-aware shell WORD split. Whitespace separates words only when
 * UNQUOTED; quote characters and backslash escapes are PRESERVED in the token
 * (the callers strip outer quotes themselves, and the extractors re-tokenize).
 * A plain `split(/\s+/)` truncated every payload containing a space to its
 * first word — `bash -c "$(printf 'git checkout -- f')"` became `"$(printf`,
 * which hid the verb and made the fail-closed arm allow a real discard
 * (reviewer round-7 P1).
 */
function _wtShellWords(s) {
  const out = [];
  let cur = "";
  let started = false;
  let quote = null;
  for (let i = 0; i < s.length; i++) {
    const ch = s[i];
    if (quote) { cur += ch; if (ch === quote) quote = null; continue; }
    if (ch === "\\") { cur += ch + (s[i + 1] ?? ""); i++; started = true; continue; }
    if (ch === "'" || ch === '"') { quote = ch; cur += ch; started = true; continue; }
    if (ch === " " || ch === "\t" || ch === "\r") {
      if (started) { out.push(cur); cur = ""; started = false; }
      continue;
    }
    cur += ch; started = true;
  }
  if (started) out.push(cur);
  return out;
}

/**
 * Join backslash-newline line continuations (`git \<LF> checkout -- f` runs
 * `git checkout -- f`). The tokenizer saw `git`, `\`, `checkout` and found no
 * invocation (reviewer round-7 P1).
 */
export function joinContinuations(command) {
  return String(command ?? "").replace(/\\\r?\n/g, "");
}

/**
 * True when the pipeline's LAST segment runs an interpreter, using the same
 * head analysis as the heredoc walker — spawners, flags and redirections are
 * accepted (`… | env bash`, `… | bash -x`, `… | sh -s`, `… | 2>/dev/null bash`),
 * not just a bare shell word at end-of-command. The old regex demanded the bare
 * form, so ANY flag or spawner disabled both the piped-file seed and the
 * piped-shell fail-closed arm (reviewer round-9 P1).
 *
 * EVERY segment after the first `|` is inspected (a trailing filter used to
 * re-hide the consumer, `printf 'git checkout -- f\n' | bash | cat` — reviewer
 * round-10 P1), and an interpreter that carries its OWN code/script operand
 * reads the pipe as DATA, not code — `python3 -m json.tool`, `bash -c 'wc -l'`
 * and `bash script.sh` must not fail closed (reviewer round-10 P2). A stdin
 * ALIAS (`/dev/stdin`, `/dev/fd/0`, `-`) is an ABSENT operand: `python3
 * /dev/stdin` executes the pipe as a script (reviewer round-10 P1).
 * @param {string} command
 * @returns {boolean}
 */
export function wtPipelineFeedsShell(command) {
  const STDIN_ALIAS = /^(?:-|\/dev\/stdin|\/dev\/fd\/0|\/proc\/self\/fd\/0)$/;
  // A REDIRECTION is not an operand either (`… | bash 2>/dev/null` executes the
  // pipe as code; treating `2>/dev/null` as a script operand silently disabled
  // the whole arm — reviewer round-11 P0).
  const REDIRECT = /^[0-9]*(?:>>?|<<?|<>|>&|<&|&>)/;
  return String(command ?? "").split("|").slice(1).some((seg) => {
    const head = _wtHeadInterpreter(seg);
    if (head === null) return false;
    const base = basename(String(head));
    const toks = _wtShellWords(seg);
    const idx = toks.findIndex((t) => basename(String(t)) === base);
    return toks.slice(idx + 1).every((t) => t.startsWith("-") || STDIN_ALIAS.test(t) || REDIRECT.test(t));
  });
}

/**
 * Extract every working-tree-discard invocation from a shell command (#709).
 * @param {string} command
 * @returns {Array<{form: string, scope: string, pathspecs: string[], fromTree: boolean, verb: string, args: string[], inv: any}>}
 */
export function extractWorkingTreeDiscards(command, _depth = 0) {
  const out = [];
  const unhandled = [];
  try {
    const codeBodies = [];
    // ONE stripped text feeds every scan: heredoc DATA bodies and `#` comments
    // are removed there, so the substitution passes below cannot surface a
    // phantom discard from data (`cat <<EOF … $(git checkout -- f) … EOF`)
    // — reviewer round-6 P2. SHELL code-heredoc bodies stay in `stripped`, so
    // real substitutions inside them remain reachable.
    const stripped = _wtStripHeredocData(_wtAnsiDecode(joinContinuations(command)), codeBodies);
    const invs = allGitInvocations(stripped);
    // Here-strings (`bash <<< 'git checkout -- f'`) and process substitution
    // (`bash <(printf 'git checkout -- f')`) feed an interpreter from a payload
    // the walker cannot resolve as a command word — fail closed when such a
    // payload mentions a discard-family verb (reviewer round-6 P1).
    for (const payload of _wtStdinPayloads(stripped)) {
      if (/(?:^|\s)(?:git\s+)?(?:checkout|restore|switch|reset|rm|apply|read-tree|checkout-index)\b/.test(payload)) {
        out.push({ form: "stdin-payload", scope: "all", pathspecs: [], fromTree: true, verb: "stdin", args: [], inv: null, unverifiable: true });
      }
    }
    const aliases = _depth < 2 ? _wtInlineAliases(command) : {};
    for (const inv of invs) {
      const verb = inv?.verb;
      const args = inv?.args ?? [];
      // A non-static verb (`git "$@"` behind a shell function, `git $CMD`) is
      // not statically resolvable — fail closed rather than sail past the
      // verb-keyed switch (reviewer round-5 P1).
      if (typeof verb === "string" && /[$`]/.test(verb)) {
        out.push({ form: "unverifiable-verb", scope: "all", pathspecs: [], fromTree: true, verb, args, inv, unverifiable: true });
        continue;
      }
      // An alias-invoked discard has a verb the family does not know — expand
      // the alias we saw defined above and re-extract (round-3 P2). The alias
      // VALUE is a git subcommand (git's `!`-prefixed form is arbitrary shell
      // text → fail closed).
      const alias = verb && Object.prototype.hasOwnProperty.call(aliases, verb) ? aliases[verb] : null;
      if (alias) {
        const val = String(alias).trim();
        if (val.startsWith("!")) {
          out.push({ form: "alias-shell", scope: "all", pathspecs: [], fromTree: true, verb: "alias", args: [], inv: null, unverifiable: true });
          continue;
        }
        const expanded = /^git\s/.test(val) ? `${val} ${args.join(" ")}` : `git ${val} ${args.join(" ")}`;
        for (const nested of extractWorkingTreeDiscards(expanded, _depth + 1)) out.push(nested);
        continue;
      }
      let d = null;
      if (verb === "checkout") d = _wtDiscardFromCheckout(args);
      else if (verb === "restore") d = _wtDiscardFromRestore(args);
      else if (verb === "switch") d = _wtDiscardFromSwitch(args);
      else if (verb === "reset") d = _wtDiscardFromReset(args);
      else if (verb === "checkout-index") d = _wtDiscardFromCheckoutIndex(args);
      else if (verb === "rm") d = _wtDiscardFromRm(args);
      else if (verb === "read-tree") d = _wtDiscardFromReadTree(args);
      else if (verb === "apply") d = _wtDiscardFromApply(args);
      if (d) out.push({ ...d, verb, args, inv });
      if (!d) unhandled.push({ verb, args, inv });
    }
    // A FEEDER supplies the pathspec at runtime (`printf 'f\n' | xargs git
    // checkout`, `find … -exec git checkout-index -f`), so the helper sees zero
    // positionals and returns null (reviewer round-5 P2). When the command
    // carries a feeder and a family verb produced no descriptor, fall back to
    // the conservative whole-tree descriptor — the effect probe still decides.
    if (/(?:^|[\s|;&(])(?:[\w./-]*\/)?\\?["']?xargs["']?(?![A-Za-z0-9_.-])/.test(String(command ?? "")) || /\bfind\b[\s\S]*?-exec\b/.test(String(command ?? ""))) {
      // The FEEDER can also supply the VERB itself (`printf 'checkout -- f\n' |
      // xargs git`) — the walker then sees a bare `git` invocation with no verb,
      // which is not in `unhandled` keyed on a family verb, so nothing was
      // emitted and the discard ran ungated (reviewer round-9 P1). A null-verb
      // invocation under a feeder whose text names a family verb is exactly as
      // unresolvable as the pathspec-fed form, and gets the same conservative
      // whole-tree descriptor (the effect probe still decides).
      for (const u of unhandled) {
        if (u.verb && _WT_FAMILY_VERBS.has(u.verb)) {
          out.push({ form: "feeder-pathspec", scope: "all", pathspecs: [], fromTree: false, verb: u.verb, args: u.args, inv: u.inv });
        } else if (!u.verb) {
          // A null-verb `git` under a feeder means the SUBCOMMAND comes from the
          // feed (`printf 'checkout -- f\n' | xargs git`) — the text probe that
          // gated this was evadable (`printf 'check\'\'out -- f\n' | xargs git`,
          // `printf 'check\x6fut -- f\n' | xargs git`), so it now fails closed
          // unconditionally (reviewer round-10 P1). A feeder-fed `git` with a
          // literal verb (`… | xargs git status`) never reaches this branch.
          out.push({ form: "feeder-verb", scope: "all", pathspecs: [], fromTree: false, verb: "feeder", args: u.args, inv: u.inv });
        }
      }
    }
    // Backtick / `$( … )` command substitution: the walker does not descend
    // into a quoted span (reviewer round-3/5 P2). Scanned on the STRIPPED text
    // so heredoc data and comments cannot produce phantom descriptors
    // (round-6 P2). Recurse, bounded like the heredoc walk.
    if (_depth < 2) {
      for (const span of _wtBacktickSpans(stripped)) {
        for (const nested of extractWorkingTreeDiscards(span, _depth + 1)) out.push(nested);
      }
      for (const span of _wtSubstSpans(stripped)) {
        for (const nested of extractWorkingTreeDiscards(span, _depth + 1)) out.push(nested);
      }
    }
    // Code heredocs (`bash <<EOF`, `cat <<EOF | bash`, `python3 <<PY`) execute
    // their body, but the git walker does not reach it — re-extract from the
    // captured body, bounded to 2 levels. SHELL bodies are parsed directly;
    // CODE bodies go through the same code-payload extractor the `-c`/`-e`
    // surface uses (reviewer round-2 P2).
    if (_depth < 2) {
      for (const body of codeBodies) {
        if (body.kind === "shell") {
          for (const nested of extractWorkingTreeDiscards(body.text, _depth + 1)) out.push(nested);
        } else {
          for (const cand of extractCodeGitCommands(body.text)) {
            for (const nested of extractWorkingTreeDiscards(cand, _depth + 1)) out.push(nested);
          }
        }
      }
    }
    // Non-git revert shape: the committed path is the SOURCE of a redirect, so
    // the pure extractor can only surface the hint; index.ts intersects it with
    // the command's bash write targets (and their resolved absolute paths).
    const hints = [];
    for (const inv of invs) {
      if (inv?.verb === "show" || inv?.verb === "cat-file") {
        for (const p of _wtDiscardShowTargets(inv.args ?? [])) hints.push(p);
      }
    }
    if (hints.length > 0) {
      out.push({ form: "cat-file-revert", scope: "revert-hints", pathspecs: hints, fromTree: true, verb: "show", args: [], inv: null });
    }
  } catch { /* pure walker — never throw into the gate */ }
  return out;
}

/**
 * #709 effect decision (pure): given `git status --porcelain=v1` output for the
 * discard's target scope, would the discard destroy uncommitted work?
 *
 *  - scope "all"   → any TRACKED entry (X or Y ≠ ' '); `??`/`!!` excluded
 *                    (`checkout -f`/`reset --hard` do not delete untracked files).
 *  - scope "paths" → a listed path with a WORKTREE-vs-INDEX difference
 *                    (`Y ≠ ' '`) — `checkout --`/bare `restore` restore from the
 *                    index; a tree/commit source (`fromTree`) also overwrites the
 *                    index, so a staged-only change (`X ≠ ' '`) is destroyed too.
 * @param {string} porcelain
 * @param {{scope: string, fromTree?: boolean}} d
 * @returns {boolean}
 */
export function discardDestroysWip(porcelain, d) {
  const lines = String(porcelain ?? "").split(/\r?\n/).filter((l) => l.length > 0);
  for (const l of lines) {
    const x = l[0];
    const y = l[1];
    if (x === "?" || x === "!") continue; // untracked / ignored
    // Unmerged entries (`UU`, `AA`, `DD`, `AU`…) are an UNRESOLVED conflict,
    // not uncommitted work being discarded — `git checkout --ours/--theirs` is
    // the sanctioned resolution (reviewer P2).
    if (x === "U" || y === "U" || (x === "A" && y === "A") || (x === "D" && y === "D")) continue;
    if (d?.scope === "all") {
      if (x !== " " || y !== " ") return true;
      continue;
    }
    if (d?.fromTree ? (x !== " " || y !== " ") : (y !== " ")) return true;
  }
  return false;
}

/**
 * #596: does a `git branch` invocation MUTATE branch state (per the branch
 * arm's OWN triggers — exact mirror, reusing the SAME helpers, so selection
 * and arm cannot drift)? TRUE for rename/move (exact -m/-M, merged clusters
 * -Mq/-mv/…, the --move/--mo/--mov long forms), hard OR soft delete
 * (branchDeleteNames), pure force-create (narrow token test incl. clusters /
 * --forc), and force-copy (destination mutation). FALSE for the arm's benign
 * classes: plain create (`git branch <name>`), list forms (-l/-a/-r and the
 * list-mode f-clusters -fl/-lf/-fa), SOFT copy (-c/-cq/--copy/--cop — a
 * new-ref-only create), and the mixed-mode / u-guarded / rc-129 no-op
 * spellings — none of which sets branchState in the arm. This predicate is
 * what lets classifyGitCommandDetailed skip a benign LEADING branch segment
 * when selecting the invocation the M3 gate must classify (#596).
 * @param {string[]} args
 * @returns {boolean}
 */
export function _branchInvMutatesBranchState(args) {
  if (args.includes("-m") || args.includes("-M") ||
      args.some((x) => (x === "--move" || x === "--mo" || x === "--mov") ||
        (/^-[A-Za-z]+$/.test(x) && _branchMode(x)?.family === "move"))) {
    return true;
  }
  if (branchDeleteNames("branch", args) !== null ||
      args.some(isBranchForceCreateTokenNarrow)) {
    return true;
  }
  return _branchCopyState(args).forceCopy;
}

/**
 * Detailed classification of a shell command (consumed EXCLUSIVELY by
 * main-worktree-guard/index.ts). Shape:
 *   { verdict, repoHint, gitDirHint, verb, verbArgs, branchState,
 *     newBranch, deleteTargets, pushDst, pushTargets, isPushDelete,
 *     renameFrom, renameTo, syncSource, stateVerb, stateArgs, stateOpCount }
 * - verdict: legacy `block:*` strings for destructive patterns (verb-anchored),
 *   plus NEW `block:commit` / `block:push` / `block:force-push`; `allow` /
 *   `allow-non-git` otherwise.
 * - branchState: true for checkout/switch/symbolic-ref/update-ref/branch ops
 *   that mutate the checkout's branch (M3 gate runs on these regardless of
 *   verdict — symbolic-ref/update-ref/branch -f have NO legacy pattern).
 * - stateVerb/stateArgs: the FIRST state-MUTATING invocation's verb/args (M3
 *   must classify the invocation that changes branch state, not invocations[0]
 *   — P1-A; #596: selection skips benign branch leads, see classifyGitCommand-
 *   Detailed). stateVerbOccurrence: the 0-based ordinal of that invocation
 *   among EXTRACTOR-VISIBLE same-verb invocations (repo-hint attribution for
 *   later-segment mutations). stateInvVisible: false when the selected
 *   mutation is invisible to branch-ownership's tokenizer (interpreter-inline
 *   payload / $VAR / abs-path git — the M3 repo then resolves at the session
 *   cwd). stateOpCount: TOTAL branch-state invocations in the command —
 *   the #591 benign-force carve-out requires exactly 1 (the gate classifies
 *   only the FIRST mutating invocation; a second own-branch force segment
 *   must not grant the carve-out a foreign later segment could launder
 *   through).
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
    deleteTargets: [], pushDst: null, pushTargets: [], isPushDelete: false,
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
  // that misses, on EVERY invocation's SKIMMED reconstruction (`git -C x
  // checkout main` ≡ `git checkout main` — the -C/-c/GIT_DIR prefixes defeat
  // the raw regexes' `git\s+branch` adjacency, which is exactly why they were
  // verified bypasses). #587 (review fold-in): the re-test covers every
  // invocation, not just the first — a prefixed destructive verb in a LATER
  // compound segment (`git fetch origin && git -C . branch -Dq x`) previously
  // escaped both passes. index.ts resolves the effective repo from the STATE
  // invocation, so worktree/foreign-targeted deletes stay exempt downstream.
  const raw = String(command ?? "").trim();
  for (const { name, re } of DESTRUCTIVE_GIT_PATTERNS) {
    if (re.test(raw)) { out.verdict = `block:${name}`; break; }
  }
  if (out.verdict === "allow") {
    for (const inv of invocations) {
      const skimmed = `git ${inv.verb ?? ""} ${(inv.args || []).join(" ")}`.trim();
      if (skimmed === "git") continue;
      let hit = false;
      for (const { name, re } of DESTRUCTIVE_GIT_PATTERNS) {
        if (re.test(skimmed)) { out.verdict = `block:${name}`; hit = true; break; }
      }
      if (hit) break;
    }
  }

  const commitInv = invocations.find((v) => v.verb === "commit");
  const pushInv = invocations.find((v) => v.verb === "push");
  // #596: stateInv SELECTION — the FIRST branch-state verb in command order is
  // NOT necessarily the state-MUTATING one. A benign leading branch segment
  // (`git branch side`, `git branch -c a b`, list forms) sets NO branchState in
  // the arm, and the arm inspects ONLY stateInv's args — so every LATER
  // rename/copy/force-create (the M3-ONLY families: no legacy verdict) escaped
  // M3 while git executed them rc 0 (`git branch side ; git branch -Mq feat/x
  // rnX` force-renames the current branch; `git branch side && git branch -fq
  // feat/other main` force-creates a foreign ref — probe-verified). Deletes
  // survived only because the invocation-blind legacy string pass skims every
  // segment (#587 fold-in); rename/copy/force-create have NO legacy verdict →
  // M3 is their only gate → the positional shadowing was a full bypass.
  // Fix: scan ALL branch-state invocations and select the first the arm would
  // classify as MUTATING (checkout/switch unconditionally — the arm sets
  // branchState for any; a HEAD/refs-heads symbolic-ref/update-ref — the arm's
  // conditional; a git branch whose args the branch arm mutates on — exact
  // helper mirror below), falling back to the FIRST state-verb invocation when
  // NONE mutates (all-benign commands keep today's stateVerb/stateArgs exposure
  // and the arm leaves branchState false). branchState is then true iff the
  // command CONTAINS a branch-state mutation, regardless of segment position;
  // stateVerb/stateArgs point at the mutation the M3 gate must classify.
  const stateInvs = invocations.filter((v) =>
    ["checkout", "switch", "symbolic-ref", "update-ref", "branch"].includes(v.verb));
  // Round-4 (reviewer P1b follow-up): the MUTATING predicate is reused both
  // for the single selection below AND for stateMutations (every mutating
  // branch-state invocation) — index.ts gates EVERY main-resolving mutation
  // so a leading `-C <wt>` mutation can't blanket-exempt a later MAIN one.
  const _isStateMutating = (v) => {
    if (v.verb === "checkout" || v.verb === "switch") return true;
    if (v.verb === "symbolic-ref" || v.verb === "update-ref") {
      const pos = (v.args || []).filter((x) => !x.startsWith("-"));
      return (v.verb === "symbolic-ref" && pos[0] === "HEAD") ||
        (v.verb === "update-ref" && pos[0] &&
          (/^refs\/heads\//.test(pos[0]) || pos[0] === "HEAD"));
    }
    return v.verb === "branch" && _branchInvMutatesBranchState(v.args);
  };
  const stateMutations = stateInvs.filter(_isStateMutating);
  const stateInv = stateMutations[0] ?? stateInvs[0] ?? null;
  const syncInv = invocations.find((v) => ["merge", "pull", "rebase"].includes(v.verb));

  // ── push: refspec targets + force-push hygiene (highest priority — a
  // compound commit+push is adequately gated by the push target check) ──
  if (pushInv) {
    const legacyVerdict = out.verdict;
    const args = pushInv.args;
    const joined = `git push ${args.join(" ")}`;
    // #443 clean-hub parity (mirrors the #439 disordered-hub closure): delete
    // detection was exact-only (`--delete` / `:branch`), so the documented
    // `-d` short form, merged no-arg short clusters containing `d` (`-dq`), and
    // git's unambiguous long-option abbreviations (`--del`, `--dele`, `--delet`,
    // `--de`) classified as plain pushes and skipped the #73
    // sibling-checked-out-anywhere block. All of those spellings delete
    // (probe-verified); `--d` is ambiguous with `--dry-run` and git REJECTS it
    // (probe-verified rc 129) — not a delete, matching `_isPushDeleteFlagToken`.
    // Value-slot aware: a delete-shaped token consumed as `-o`/`--push-option`'s
    // VALUE (`git push origin -o -d feat/x` — the `-d` is -o's value, a normal
    // push) must not count, and an empty-source colon swallowed as a value
    // (`-qo :tag`) must not either. Same slot model the whole-command
    // extractor uses, so the two #443 surfaces stay in parity.
    const optSlots = _markOptionValueSlots(args);
    const deleteIdx = args.findIndex((a, i) => !optSlots[i] && _isPushDeleteFlagToken(a));
    const hasColonTargets = args.some((a, i) => !optSlots[i] && /^:/.test(a));
    if (deleteIdx !== -1 || hasColonTargets || legacyVerdict === "block:push-delete") {
      out.isPushDelete = true;
      out.verdict = "block:push-delete";
      // git treats the FIRST positional as the repository and every further
      // positional as a delete refspec when a delete form is present
      // (`git push --delete origin a b` deletes a AND b — probe-verified;
      // `git push --delete origin a` likewise). A lone positional is kept as a
      // target only when it is an empty-source `:branch` delete (implicit
      // origin); a lone BARE positional makes git error ("--delete doesn't make
      // sense without any refs") — the keep is a harmless over-capture that
      // matches today's `git push --delete feat/x` classification.
      const positionals = args.filter((x) => !x.startsWith("-"));
      const rawTargets = positionals.length > 1 ? positionals.slice(1) : positionals;
      out.pushTargets = rawTargets
        .map((x) => _stripQuotes(x).replace(/^:/, "").replace(/^refs\/heads\//, ""))
        .filter(Boolean);
      // LATER-SEGMENT fold-in (#504): when NO delete form is present in this
      // (first) push invocation yet the FROZEN raw legacy verdict is
      // block:push-delete, the delete spelling lives in a LATER segment of a
      // compound (`git push origin main && git push origin --delete b`). This
      // invocation's positionals are ordinary PUSH refspecs, NOT delete
      // targets — labeling them as such produces a phantom "main" that
      // false-fires the #73 coordinated check in the full path (a regression
      // vs origin/main's empty pushTargets). Fall back to the whole-command
      // extractor, exactly as the degraded arm does, so the real target(s)
      // across every later segment are attributed. NOTE — the extractor is
      // string-matched, so this now shares the degraded arm's documented
      // echo/comment over-match (a text that merely MENTIONS a complete
      // `git push … --delete <target>` also populates targets; sibling-
      // conditional safe-direction, consistent with the frozen --delete
      // echo precedent). Parenthesized later segments (`(git push … -d c)`) are
      // a tracked residual (token-level paren suffix).
      if (deleteIdx === -1 && !hasColonTargets) {
        out.pushTargets = extractPushDeleteBranch(String(command)) ?? [];
      }
      // KNOWN IMPRECISION (parity-preserving, safe direction): a push-option
      // VALUE consumed by `-o`/`--push-option` that appears as a standalone arg
      // (`git push origin -do draft feat/x` → git deletes only feat/x; `draft`
      // is -o's value) over-captures into pushTargets (here ["draft",
      // "feat/x"]). Identical imprecision predates #443 for `--delete` +
      // `-o`, errs toward BLOCKING (never toward a bypass), and the phantom
      // target only matters if a branch literally named after the option value
      // is checked out in a sibling. Not value-parsed to stay in the #439/#443
      // mirror scope.
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
      // #626: capture the branch across git's FULL create/force-create/orphan
      // surface (attached shorts + long forms), not just exact `-b`/`-B` tokens.
      out.newBranch = _checkoutCreateBranch(verb, args);
    } else if (verb === "symbolic-ref" || verb === "update-ref") {
      const pos = args.filter((x) => !x.startsWith("-"));
      if ((verb === "symbolic-ref" && pos[0] === "HEAD") ||
          (verb === "update-ref" && pos[0] && (/^refs\/heads\//.test(pos[0]) || pos[0] === "HEAD"))) {
        out.branchState = true;
      }
    } else if (verb === "branch") {
      // #592: rename/move arm widened from EXACT-token (-m/-M) to git's full
      // spelling surface (sibling closure: #587 delete clusters, #591
      // force-create clusters). git merges NOARG shorts into ONE token, so the
      // move letter can sit anywhere in a cluster (`-Mq` ≡ `-M -q`, `-mv` ≡
      // `-m -v` — both rename rc 0, probe-verified) and git accepts the
      // documented long form plus its UNAMBIGUOUS prefix abbreviations
      // (`--move`/`--mov`/`--mo`; --m is ambiguous with --merged rc 129).
      // Mode letters WIN over -f (#591), so a move-composed cluster is a
      // rename, not a force-create. These set branchState exactly like the
      // exact `-m`/`-M` forms they are byte-identical to in git (before #592
      // they fell through to verdict allow + branchState false → M3 never
      // entered from the shared main checkout). 1-positional git semantics:
      // `(-m|-M) [<old>] <new>` — a SINGLE positional renames the CURRENT
      // branch (renameFrom null → renameTo = the new name; decideM3
      // substitutes currentBranch via classifyBranchOp's from:null).
      if (args.includes("-m") || args.includes("-M") ||
          args.some((x) => (x === "--move" || x === "--mo" || x === "--mov") ||
            (/^-[A-Za-z]+$/.test(x) && _branchMode(x)?.family === "move"))) {
        const pos = _branchPositionals(args);
        out.branchState = true;
        out.renameFrom = pos.length > 1 ? (pos[0] ?? null) : null;
        out.renameTo = pos.length > 1 ? (pos[1] ?? null) : (pos[0] ?? null);
      } else if (branchDeleteNames("branch", args) ||
                 args.some(isBranchForceCreateTokenNarrow)) {
        // #591: the branch arm's force-create trigger is TOKEN-level (any
        // spelling git force-creates with — see isBranchForceCreateToken), so
        // merged NOARG clusters (`-fq` ≡ `-f -q`) and the unambiguous
        // long-prefix abbreviation (`--forc`) set branchState exactly like the
        // plain `-f`/`--force` forms they are byte-identical to in git
        // (probe-verified rc 0). Before #591 they fell through to verdict
        // allow + branchState false → M3 never entered from the shared main
        // checkout. Review fold-in (#591 round 2): the trigger uses the NARROW
        // pure-force-create predicate — git's MODE letters win over -f
        // (`-fl x main` LISTs rc 0, `-cf a b` copies, `-Df x` deletes — a
        // mode-composed f-cluster is NOT a force-create, probe-verified), so
        // list/copy/move/delete-composed clusters stay out of the M3 force
        // path (deletes take the delNames verdict arm above; copy/move
        // clusters are #592's family, byte-identical to pre-#591).
        // P1-B: -D/-d delete must set newBranch so the allowance target list is
        // non-empty (a ceremony `git branch -D $PR_BRANCH` on the own branch is
        // allowed; without this, ownershipAllowed([]) is false -> false-block).
        // #543: `git branch -D a b` is a MULTI-TARGET delete — git deletes each
        // target independently and only stops at the first refusal (`git branch
        // -D main feat/other` refuses the checked-out main but deletes
        // feat/other, rc=1). newBranch (the first name) alone would let
        // `<baseline|own> <foreign>` slip the trailing foreign target past the
        // ownership allowance, so the branch-delete extraction must capture
        // EVERY -d/-D/--delete name (merged NOARG flag-clusters like `-Dq` ≡
        // `-D -q` contribute NO name — #587: the suffix is flags, never an
        // attached branch name — the target is the following positional) via
        // branchDeleteNames — the all-targets discipline pushTargets already
        // gives the push family (#443). newBranch stays the FIRST name for
        // back-compat (single-target callers/tests); index.ts prefers
        // deleteTargets. Force-create (M3 force arm — `-f`/`--force`/clusters/
        // `--forc`) is NOT a delete — branchDeleteNames returns null for it and
        // newBranch keeps the first positional (the force-create target).
        out.branchState = true;
        const delNames = branchDeleteNames("branch", args);
        if (delNames) {
          out.deleteTargets = delNames;
          out.newBranch = delNames[0] ?? null;
        } else {
          // #592 (round-2 fold): newBranch = the real mutation target — for a
          // pure force-create the FIRST positional; for a force-composed COPY
          // (an exact -f/--force beside a copy spelling — `-f -c main side`)
          // the narrow-force token fired this arm before the force-copy arm,
          // so capture the DESTINATION (2nd positional) to stay consistent
          // with classifyBranchOp's op:force branch=dst (M3 keys on that, but
          // the field must not advertise the SOURCE). Value-aware extraction
          // (--sort/--format swallow the next argv) in both cases.
          const pos = _branchPositionals(args);
          const cp = _branchCopyState(args);
          out.newBranch = cp.copyMode
            ? ((pos[1] ?? pos[0]) ?? null)
            : (pos[0] ?? null);
        }
        // #587 (review fold-in, TOKEN-level hard-delete verdict): the legacy
        // patterns scan the raw/skimmed STRING, where a `[^;&|]*` run boundary
        // is truncated by metachars inside QUOTED branch names placed BEFORE
        // the flags (`git branch "feat&x" -Dq` — real git hard-deletes rc=0),
        // and quoted flag tokens break the token adjacency. The quote-aware
        // tokenizer already stripped both classes down to plain args here, so
        // derive the HARD verdict from the tokens (mirror of the push family's
        // token-level `_isPushDeleteFlagToken`, #443): hard = an uppercase-D
        // cluster (u-guarded) OR a delete + force composition. Soft -d/--delete
        // (no force, no D) keeps the allow verdict; force-CREATE (`-f x main` —
        // delNames null) is untouched (M3 force arm). The upgrade applies when
        // the legacy/commit/push passes left an overridable verdict — the raw
        // string pass gives branch-force-delete precedence over the commit/push
        // arms (`git commit -m x && git branch -Dq y` blocks as
        // branch-force-delete), so a metachar-truncated twin must not downgrade
        // to block:commit/block:push (review fold-in round 4).
        const hardUpperD = args.some((x) =>
          // #591 (round-3 fold): value-aware flag run — a tracking-directive
          // VALUE's letters never read as mode letters (`-Dftdirect`'s D is in
          // the run and IS a hard delete; `-ftdirect`'s value "direct" carries
          // no D and delNames is null there anyway).
          /^-[A-Za-z]+$/.test(x) && /D/.test((_branchToken(x)?.run) ?? ""));
        const hardForce = delNames && args.some(isBranchForceCreateToken);
        const overridable = out.verdict === "allow" || out.verdict === "block:commit" ||
          out.verdict === "block:push" || out.verdict === "block:force-push";
        if (overridable && (hardUpperD || hardForce)) {
          out.verdict = "block:branch-force-delete";
        }
        // #591 (round-3 fold): the raw/skimmed STRING pass reads delete and
        // force letters from the whole letter run, so a pure force-create's
        // tracking-directive VALUE letters trip it (`-ftdirect victim base` is
        // `-f --track=direct` — a real force-CREATE rc 0, but the "d" in
        // "direct" makes the line-87 branch-force-delete pattern fire with
        // phantom delete intent). The token-level read here is authoritative
        // (delNames null = no delete token in THIS invocation), so when no
        // other branch invocation in the command is a real delete either,
        // downgrade the misfire to allow and let the M3 force arm gate the
        // force-create (own-branch ceremony → benign carve-out; foreign → M3
        // block). A genuine compound delete elsewhere (`git branch -fq x y &&
        // git branch -Dq z`) has a branch-delete invocation → no downgrade.
        if (delNames === null && out.verdict === "block:branch-force-delete" &&
            !invocations.some((v) => v.verb === "branch" &&
              branchDeleteNames("branch", v.args) !== null)) {
          out.verdict = "allow";
        }
      } else if (_branchCopyState(args).forceCopy) {
        // #592: FORCE-COPY family (-C/-Cq/-cf/-fC/-f -c/--force --copy) — the
        // copy family was not branch-state tracked AT ALL before #592 (even
        // the exact `-C` fell through to verdict allow + branchState false
        // while git OVERWRITES an existing free dst rc 0 — the same
        // shared-ref mutation M3 gates for `branch -f`). Set branchState +
        // expose the DESTINATION as newBranch (2nd positional of `-C src dst`;
        // 1st of a 1-positional `-C dst`, which copies the current branch) —
        // mirroring the force-create arm's target capture. M3 keys on
        // classifyBranchOp's op:"force" branch=dst: a dst equal to the
        // checkout's own current branch is git-refused rc 128 (benign → #591
        // carve-out); foreign / non-checked-out overwrite targets block. SOFT
        // copy (-c/-cq/--copy, no force) only ever creates a NEW ref (git
        // refuses an existing dst rc 128) → like `git branch <name>`: NO
        // branchState (allow); mixed-mode single tokens (-mc/-mD/-Dc — rc-129
        // no-ops) fall through the same way.
        out.branchState = true;
        const pos = _branchPositionals(args);
        out.newBranch = pos.length > 1 ? (pos[1] ?? pos[0]) : (pos[0] ?? null);
      }
    }
    // P1-A: expose the STATE-mutating invocation's verb/args — M3 must classify
    // the invocation that changes branch state, not invocations[0] (a compound
    // `git pull && git checkout main` would otherwise classify "pull" and skip
    // the gate, or false-block the #376 ceremony return-to-original carve-out).
    // #596 (round-2 reviewer, refined round-3): stateVerbOccurrence — the
    // 0-based ordinal of stateInv among the command's EXTRACTOR-VISIBLE
    // invocations with the SAME verb (cmdVisible — spelled with the literal
    // `git` token; interpreter-inline / $VAR / abs-path-git spellings are ONE
    // opaque token to branch-ownership's tokenizer and must not shift the
    // ordinal — a quoted `sh -c "git branch -Mq …"` mutation between visible
    // segments used to land the ordinal on a LATER `-C <wt>` invocation,
    // wrongly worktree-exempting the payload). index.ts resolves the effective
    // repo with preferVerb = stateVerb, which picks the preferVerbOccurrence-th
    // same-verb invocation; when the MUTATING invocation is itself
    // extractor-invisible (stateInvVisible false — a quoted-payload mutation
    // runs at the shell cwd), index.ts resolves the M3 repo at the session cwd.
    out.stateVerbOccurrence = 0;
    for (const v of stateInvs) {
      if (v === stateInv) break;
      if (v.verb === stateInv.verb && v.cmdVisible !== false) out.stateVerbOccurrence++;
    }
    out.stateInvVisible = stateInv.cmdVisible !== false;
    out.stateVerb = verb;
    out.stateArgs = args;
    // #596 round-4 (reviewer follow-up): the SELECTED mutating invocation's
    // OWN resolution hints (cdChain/cHints/gitDirHint/vars), captured
    // boundary-aware by _walkShell. index.ts resolves the M3 repo from THESE
    // instead of replaying the stateVerbOccurrence ordinal through
    // branch-ownership's boundary-less tokenizer — a replay mis-attribution
    // (interpreter-inline / script-file / redirect-operand phantoms, or an
    // interpreter word used as a git ARG whose next token the extractor
    // consumes) landed the ordinal on a DIFFERENT invocation whose -C hints
    // wrongly worktree-exempted a mutation that runs at the shell cwd.
    out.stateHints = stateInv && stateInv.cmdVisible !== false
      ? { cdChain: stateInv.cdChain, cHints: stateInv.cHints, gitDirHint: stateInv.gitDirHint, vars: stateInv.vars }
      : null; // extractor-invisible mutation → index.ts resolves at the session cwd (stateInvVisible false path)
    // Round-4 (reviewer P1b follow-up): EVERY mutating branch-state invocation
    // (visible → its own boundary-aware hints; invisible payload → null hints,
    // resolved at the shell cwd). index.ts M3 gates each main-resolving one so
    // a leading worktree mutation cannot exempt a later MAIN mutation.
    out.stateMutations = stateMutations.map((v) => ({
      verb: v.verb,
      args: v.args,
      invVisible: v.cmdVisible !== false,
      hints: v.cmdVisible !== false
        ? { cdChain: v.cdChain, cHints: v.cHints, gitDirHint: v.gitDirHint, vars: v.vars }
        : null,
    }));
  }
  // #591 (review fold-in, compound-launder guard): count EVERY branch-state
  // invocation in the command. The M3 benign-force carve-out (a force-create
  // whose target is the checkout's OWN branch) must only fire for a command
  // whose sole branch-state mutation is that own-branch attempt — in a `;`
  // compound (`git branch -f own ; git branch -fq foreign x`) the carve-out
  // on segment 1 would otherwise let segment 2's FOREIGN force-create execute
  // even though the M3 gate classifies only ONE invocation (the first
  // mutating one — #596; pre-#591 the exact-force segment 1 blocked the whole
  // command). stateOpCount ≥ 2 → decideM3 refuses the carve-out → default
  // block restores pre-#591 compound parity.
  out.stateOpCount = invocations.filter((v) =>
    ["checkout", "switch", "symbolic-ref", "update-ref", "branch"].includes(v.verb)).length;
  // #591 (round-3→5 fold): a shell construct may hide a branch-state git
  // invocation from the count above (collapse to opaque tokens → stateOpCount
  // undercounts). Exposed here so index.ts can refuse the M3 benign-force
  // carve-out when hidden state mutation is present. The scan ORs the
  // branch-state-mutating substitution scan (_hasHiddenStateSubst) with the
  // hub-gate's hardened unverifiable-git shape set (_unverifiableGitContent:
  // piped-stdin shells, process substitution, heredocs, alias/function
  // definitions, spawner $VARs — round-6→19 review-hardened; the carve-out
  // bound reuses it so the construct coverage cannot drift).
  out.hiddenStateSubst =
    _hasHiddenStateSubst(String(command ?? "")) ||
    _unverifiableGitContent(String(command ?? ""));

  // #596 round-4 (reviewer P1a follow-up): the M2 commit/push repo must come
  // from the classifier's boundary-aware walk of the commit/push invocation,
  // but commitHints/pushHints must describe the FIRST EXTRACTOR-VISIBLE
  // commit/push (cmdVisible — literal `git` spelling). The old replay only
  // ever saw visible invocations; an invisible interpreter-inline payload
  // (`sh -c "git -C <wt> commit -m z"`) precedes the real main commit in
  // invocation order, and using ITS `-C <wt>` hints exempted the real
  // OFF-baseline MAIN commit (round-4 regression). commitInv/pushInv (any
  // commit/push incl. invisible) still drive the VERDICT; the hints feed the
  // repo resolution only for the visible first one.
  const commitVisInv = invocations.find((v) => v.verb === "commit" && v.cmdVisible !== false);
  const pushVisInv = invocations.find((v) => v.verb === "push" && v.cmdVisible !== false);
  out.commitHints = commitVisInv
    ? { cdChain: commitVisInv.cdChain, cHints: commitVisInv.cHints, gitDirHint: commitVisInv.gitDirHint, vars: commitVisInv.vars }
    : null;
  out.pushHints = pushVisInv
    ? { cdChain: pushVisInv.cdChain, cHints: pushVisInv.cHints, gitDirHint: pushVisInv.gitDirHint, vars: pushVisInv.vars }
    : null;

  return out;
}

/**
 * Is this cwd inside a git WORKTREE (as opposed to the main checkout)?
 * Main checkout: git-common-dir is ".git" (or the real .git path).
 * Worktree:      git-common-dir resolves into <main>/.git/worktrees/<name>.
 */
// -- STRUCTURAL linked-worktree test (#618/#621 adversarial-review F1) ------
// Distinguishes a repo's MAIN checkout from a LINKED WORKTREE by comparing the
// realpath of `git rev-parse --git-dir` against `--git-common-dir`: in the
// MAIN checkout both resolve to the SAME real directory (`<top>/.git`); in a
// linked worktree `--git-dir` points UNDER the common dir
// (`<common>/.git/worktrees/<name>`). The historical path-substring test
// (`gitDir.includes("/worktrees/")`) was path-STRING dependent and failed
// OPEN for a MAIN checkout whose OWN path contained a `worktrees` segment:
// from a subdirectory git prints the ABSOLUTE gitdir (`~/worktrees/repo/.git`),
// the substring matched, and the repo was misread as a linked worktree
// (isMain:false → the #618/#621 hub-write gate silently lifted for every
// target under that repo's subdirectories — probe-verified 2026-09-09).
// git prints repo-relative paths when cwd is under the gitdir's parent and
// absolute otherwise; resolve() against cwd normalizes BOTH spellings, and
// realpathSync canonicalizes a symlinked `.git`.
// Not a git repo → throws (callers catch — isWorktreeCwd degrades to false =
// treat as main, the safe/block default).
export function gitCheckoutIsLinkedWorktree(cwd) {
  const gitDir = execSync("git rev-parse --git-dir", {
    encoding: "utf-8", cwd, timeout: 5000, stdio: ["ignore", "pipe", "ignore"],
  }).trim();
  const commonDir = execSync("git rev-parse --git-common-dir", {
    encoding: "utf-8", cwd, timeout: 5000, stdio: ["ignore", "pipe", "ignore"],
  }).trim();
  if (!gitDir || !commonDir) return false;
  const g = resolve(cwd, gitDir);
  const c = resolve(cwd, commonDir);
  if (g === c) return false; // same spelling (main at its toplevel: both ".git")
  return realpathSync(g) !== realpathSync(c);
}

export function isWorktreeCwd(cwd) {
  try {
    return gitCheckoutIsLinkedWorktree(cwd);
  } catch {
    return false; // not a git repo — treat as main (safe default: block)
  }
}

/**
 * #443 (clean-hub parity, mirrors #439): is this arg a `git push` delete
 * spelling? git accepts — all probe-verified to delete remote branches:
 *   - `-d` (the documented short form of `--delete`)
 *   - merged no-arg short-flag clusters containing `d` (`-dq` = -d --quiet);
 *     git merges only push's no-arg short alphabet (v q n u 4 6 d f — the #439
 *     M4 set), so `-odraft`/`-uofoo` (attached option VALUES) are NOT clusters
 *   - merged clusters where the arg-taking `-o` (push-option) follows the
 *     delete short (`-do draft b` = -d -o draft b — git consumes the rest of
 *     the token / next argv as -o's value; probe-verified to delete). A `d`
 *     AFTER the first `o` is part of -o's VALUE, never an option.
 *   - `--delete` and its unambiguous long-option PREFIX abbreviations
 *     (`--de`, `--del`, `--dele`, `--delet`)
 * `--d` is NOT a delete: it is ambiguous with `--dry-run` and git REJECTS it
 * (rc 129, probe-verified) — it never deletes anything.
 */

/**
 * Mark option-VALUE slots across a token array for push's arg-taking option.
 * git's parse-options consumes the NEXT argv as the value of a standalone
 * `-o`/`--push-option`, and of ANY merged no-arg short cluster terminated by
 * `o` (`-do`, `-qo`, `-fo`, `-dqo` …; `-o` alone is the degenerate case) —
 * probe-verified (`git push origin -d -qo msg b` deletes only b, and
 * `git push origin -o -d feat/x` consumes the `-d` as -o's VALUE, so nothing
 * is deleted). The consumed token must never be mistaken for a delete flag,
 * an empty-source colon refspec, or a delete target. Inline attached values
 * (`-doDraft`, `-odraft`, `--push-option=x`) carry their value in-token
 * (chars trail the `o` → no match) — no slot. Consecutive arg-takers PAIR
 * OFF (git parse-options never re-parses a consumed value as an option): in
 * `-o -o -d b` the first `-o` consumes the second `-o`, so `-d` is a REAL
 * delete flag — already-consumed slots are skipped in the scan. The
 * valueSlot index is TRUE at the slot position (i+1), so callers check
 * `valueSlot[i]` before treating token[i] as a flag/target.
 * @param {string[]} tokens
 * @returns {boolean[]}
 */
function _markOptionValueSlots(tokens) {
  const valueSlot = new Array(tokens.length).fill(false);
  for (let i = 0; i < tokens.length; i++) {
    if (valueSlot[i]) continue; // already consumed as a value — never an option
    const t = tokens[i];
    const oTerminatedCluster = /^-[vqnu46df]*o$/.test(t);
    if (t === "--push-option" || oTerminatedCluster) {
      if (i + 1 < tokens.length) valueSlot[i + 1] = true; // value = next argv
    }
  }
  return valueSlot;
}

function _isPushDeleteFlagToken(a) {
  if (a === "-d" || a === "--delete" || a.startsWith("--delete=")) return true;
  // `-dq`/`-qd`/`-df` … merged short clusters containing the delete short.
  if (/^-[vqnu46df]{2,}$/.test(a) && a.includes("d")) return true;
  // `-do`/`-dqo draft …` — the delete short merged BEFORE the arg-taking `-o`
  // (only chars before the first `o` are parsed options; the rest is -o's
  // value). `-odraft` never matches: there the `d` is inside -o's value.
  if (/^-[vqnu46df]*d[vqnu46df]*o/.test(a)) return true;
  // Unambiguous `--delete` prefix abbreviations (`--de`|`--del`|`--dele`|`--delet`).
  if (/^--de(l(?:e(?:t)?)?)?$/.test(a)) return true;
  return false;
}

/** Short-name a raw delete target token (`:refs/heads/feat/x` → `feat/x`). */
function _cleanDeleteTarget(x) {
  return x
    .replace(/^["']|["']$/g, "")   // strip surrounding quotes
    .replace(/^:+/, "")             // leading empty-source colon(s)
    .replace(/^refs\/heads\//, "") // full ref
    .replace(/^heads\//, "");       // git dst-inference (`:heads/main`)
}

/**
 * Extract the branch name from `git push [remote] --delete <branch>`.
 * Handles both short names ("feat/x") and full refs ("refs/heads/feat/x").
 * #443: the legacy raw-string regex was exact-only (`--delete`/`:branch`), so
 * `-d`/`--del`(-prefix) spellings returned null and the degradation-fallback
 * #73 sibling-checked-out check never fired for them. Rewritten token-based to
 * cover the full delete spelling family AND to stop false-positive captures of
 * non-delete coloned refspecs (`git push origin main:feature` has a SOURCE so
 * it is a normal push, not a delete — the empty-source form starts the token
 * with `:`).
 * @param {string} command
 * @returns {string|null} branch name (short form) or null
 */
export function extractPushDeleteBranch(command) {
  const c = String(command ?? "").trim();
  if (!/\bgit\s+push\b/.test(c)) return null;
  // Compound commands carry several `git push` segments (`a && git push … ;
  // git push …`) — detect deletes per segment, stopping at shell operators
  // (the original regex's [^;&|]* contract).
  const branches = [];
  const segRe = /\bgit\s+push\b([^;&|]*)/g;
  let sm;
  while ((sm = segRe.exec(c)) !== null) {
    const tokens = sm[1].trim().split(/\s+/).filter(Boolean);
    if (tokens.length === 0) continue;
    // Arg-taking options consume a value (`-o draft`, `--push-option draft`,
    // merged `-do draft` = -d -o draft; inline `-doDraft`/`--push-option=x`
    // carry their value in-token). A consumed value is NOT a flag and NOT a
    // delete target — without this, `-do draft old-feat` would capture the -o
    // VALUE `draft` as the target and lose the real `old-feat` (probe-verified:
    // git deletes only old-feat). Mark value slots so the scans below skip
    // them. Mirrors git's parse-options short-flag merging.
    const valueSlot = _markOptionValueSlots(tokens);
    for (let i = 0; i < tokens.length; i++) {
      const t = tokens[i];
      if (valueSlot[i]) continue; // consumed as an option VALUE — never a flag/target
      // Shell quoting is stripped before git sees an arg, so detect flags and
      // empty-source colons on the quote-stripped token (`':feat/x'` is a
      // delete; a pre-#443 quote-aware extractor handled it, keep that).
      const tq = t.replace(/^["']|["']$/g, "");
      if (_isPushDeleteFlagToken(tq)) {
        // git's positional model: when a delete flag is present and ≥2
        // positionals follow it with none BEFORE it, the FIRST is the
        // REPOSITORY (`git push --delete origin c` deletes c on origin —
        // probe-verified; `git push --delete origin a b` deletes a AND b).
        // When the repo precedes the flag (`git push origin --delete a b`)
        // every following positional is a delete refspec. The extractor's
        // documented single-target contract keeps the first real refspec, so
        // a repo that TRAILS the flag is dropped. (A lone positional after
        // the flag with no repo anywhere is git-invalid — kept as a harmless
        // over-capture matching the original extractor.)
        const before = [];
        const following = [];
        for (let j = 0; j < tokens.length; j++) {
          if (j === i || tokens[j].startsWith("-") || valueSlot[j]) continue;
          (j < i ? before : following).push(tokens[j]);
        }
        if (following.length === 0) continue; // no refspec after the flag → git errors, nothing deleted
        const targetTok = following.length >= 2 && before.length === 0 ? following[1] : following[0];
        branches.push(_cleanDeleteTarget(targetTok));
      } else if (/^:/.test(tq)) {
        // Empty-source colon refspec (`:feat/x`) = a delete. src:dst refspecs
        // (`main:feature`) never start with `:` — they stay plain pushes.
        branches.push(_cleanDeleteTarget(tq));
      }
    }
  }
  const out = branches.filter(Boolean);
  // Dedupe: `-d :old/x` is counted by the flag path AND the colon path for
  // the SAME refspec (git deletes it once). Distinct targets stay distinct.
  const uniq = [...new Set(out)];
  return uniq.length > 0 ? uniq : null;
}

/**
 * Pure decision helper for the full-path compound-delete glue (#443 R6/R7):
 * the detailed matcher describes only the FIRST push invocation, so a delete
 * spelling in a LATER compound segment of the -d/--del family (which carries NO
 * frozen legacy evidence) is invisible to its pushTargets. Given the matcher
 * verdict for that first invocation and the raw command, return the whole-
 * command delete targets a push-family verdict must additionally protect — or
 * [] when the verdict is not push-family (block:push-delete already carries its
 * targets via the fold-in, and non-push verdicts are unrelated). Kept pure and
 * exported so the index.ts orchestration glue is unit-testable here.
 * @param {string} verdict detailed matcher verdict for the first invocation
 * @param {string} command raw command text
 * @returns {string[]}
 */
export function wholeCommandDeleteTargets(verdict, command) {
  if (verdict !== "block:push" && verdict !== "block:force-push") return [];
  return extractPushDeleteBranch(command) ?? [];
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
    // In a linked worktree the main checkout is a separate entity — null
    // (structural test: gitdir vs commondir realpaths — see
    // gitCheckoutIsLinkedWorktree; path-substring matching misread main
    // checkouts whose own path contains a `worktrees` segment).
    if (gitCheckoutIsLinkedWorktree(process.cwd())) {
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
 * Identification only — NOT an enforcement exemption. The #99 carve-out is
 * removed (#615): agent-infra's main checkout gets the same hub discipline as
 * every other repo (M4 disorder gates + write/edit block + hub-state checks).
 * The flag still feeds branch-ownership M2/M3 ceremony semantics (own-baseline
 * work in agent-infra worktrees; the #376 ceremony return-to-original arm —
 * in-hub create-new is blocked since #626), and repo-freshness
 * (auto-sync owns the repo). Shared-state edits (MEMORY.md, skills, config,
 * extension code) land via worktrees → merge → sync, never direct in-hub.
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
  // #444: check-ignore is a PURE QUERY (evaluates gitignore rules, writes
  // nothing) — unknown-verb fail-closed previously false-blocked both the
  // direct surface and hub-worktree.sh's `.worktrees/`-ignored check (the real
  // hub-worktree.sh content must gate ALLOW once extractScriptPath resolves
  // arg-taking scripts).
  "check-ignore",
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
 * #591 (round 2): the BROAD force-token test — ANY git-branch force spelling:
 * the exact long `--force`/`--forc` (unambiguous prefix abbreviations; `--for`
 * is ambiguous with `--format` rc 129, `--forcfoo` unknown rc 129 → excluded)
 * or a single-dash short cluster whose letter run contains `f` (git merges
 * NOARG shorts, so `-Df`/`-df`/`-fq` … all carry force). Used by the
 * delete+force composition check (#587) where force is mode-blind — with a
 * delete token present git IS deleting (`-Df x` = hard delete), so every
 * f-bearing cluster counts. The `(?![A-Za-z]*u)` guard mirrors #587's delete
 * side: branch's only arg-taking short is `-u<value>` (set-upstream-to), which
 * consumes the token rest as its value, so a u-containing letter run is
 * set-upstream mode — probe-verified: `-ufoo`, `-fuDevel … main` error (rc
 * 128/129) and create/delete NOTHING, so no real force op is masked.
 * @param {string} a
 * @returns {boolean}
 */
export function isBranchForceCreateToken(a) {
  return a === "--force" || a === "--forc" ||
    /^-(?![A-Za-z]*u)[A-Za-z]*f/.test(a);
}

/**
 * #591 (round 3 + fold): parse a single-dash git-branch token the way git's
 * parse-options does — NOARG shorts merge into ONE run scanned LEFT→RIGHT, and
 * an ARG-VALUE-TAKING short stops the run and consumes the REST of the token
 * as its attached value. branch's value-takers: `u` (set-upstream-to — a
 * REQUIRED value; the #587 u-guard excludes ANY u-containing token from
 * delete/force/copy/move wholesale, since those modes conflict with
 * set-upstream rc 129 and delete/create nothing) and `t` (--track,
 * PARSE_OPT_OPTARG — a NON-TERMINAL t consumes the rest of the token as its
 * tracking DIRECTIVE; a TERMINAL t is a plain NOARG flag = --track default).
 * Letters inside an attached value are VALUE, never mode letters (round-3
 * fold): `-ftdirect` parses `-f --track=direct` (a force-CREATE rc 0 —
 * probe-verified victim moved) and its "direct" must NOT read as delete/copy
 * letters, while `-Dftdirect` (`-D -f --track=direct`) IS a hard delete whose
 * D/f sit in the run. Returns { run, tValue }: run = the NOARG flag letters
 * before the first value-taker; tValue = the directive a mid-run t consumed
 * (null when no mid-run t). Returns null when x is not a single-dash letter
 * token or contains u.
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
 * #591 (round 3 + fold): the NARROW pure-force-create test — a force-create
 * ONLY when git is actually in CREATE mode. git's mode letters WIN over -f
 * (probe-verified): `-fl x main`/`-lf`/`-fa` LIST rc 0 (no ref moves —
 * `-l`/`-a`/`-r` force list mode), `-cf a b`/`-fC a b` COPY the destination,
 * `-Df x` DELETEs, `-mf a b` moves — none is a force-create, and flagging one
 * as such false-blocks benign list commands or misroutes copy/move mutations
 * to the force-create M3 path. git merges only the NOARG shorts; branch's
 * CREATE-mode NOARG letters are {f,v,q,i} (probe-verified rc 0: `-i` does NOT
 * force list mode — `git branch -i x main` creates like `-i` were absent;
 * only l/a/r do) and `f` is REPEATABLE (`-ff`, `-fqf` ≡ `-f -q -f` — probe
 * rc 0). Letters are read VALUE-AWARELY via _branchToken (see there): the run
 * holds the NOARG letters before the first value-taker, so a TERMINAL `t`
 * (`-ft`/`-fvt` create rc 0) sits in the run while a NON-TERMINAL t consumes
 * the rest of the token as its --track directive VALUE — git accepts exactly
 * "direct"/"inherit" there (`-ftinherit`, `-fitinherit`, `-fqtdirect`,
 * `-qftinherit` … all force-create rc 0 — round-3 reviewer P1, the
 * tracking-directive ceremony family), and any other remainder is a parse
 * error (`-tf`/`-ftq`/`-tqf`/`-ftVerbose`/`-ftdirectx` rc 129, creates
 * nothing → excluded). So a pure force-create short cluster is a run matching
 * `[qvif]*f[qvif]*t?` (the u-guard is implicit: _branchToken returns null for
 * u). Long compositions with an EXACT `--force` stay branchState by the
 * long-form clause — pre-#591 parity (the exact `--force` token always
 * triggered M3; `git branch --force --list` is a nonsense no-op, documented
 * residual). Shared shape with classifyBranchOp in branch-ownership.mjs
 * (cross-pinned); both layers MUST agree or a spelling bypasses the M3 gate
 * (branchState true but op "other" skips it).
 * @param {string} a
 * @returns {boolean}
 */
export function isBranchForceCreateTokenNarrow(a) {
  if (a === "--force" || a === "--forc") return true;
  const tok = _branchToken(a);
  if (!tok) return false;
  // A mid-run t consumed a tracking directive: only git's two VALID --track
  // values force-create rc 0; any other remainder is a parse error rc 129.
  if (tok.tValue !== null && tok.tValue !== "direct" && tok.tValue !== "inherit") {
    return false;
  }
  return /^[qvif]*f[qvif]*t?$/.test(tok.run);
}

/**
 * #592: mode-family reader for a single-dash branch token — EXACT duplicate
 * of branch-ownership.mjs's _branchMode (cross-pinned; a drift between the
 * layers would set branchState in one and op "other" in the other — silently
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
 * #592: copy-family state — EXACT duplicate of branch-ownership.mjs's
 * _branchCopyState (cross-pinned). See there for the git semantics: SOFT copy
 * (-c/-cq/--copy, no force) only creates a NEW ref (existing dst refused rc
 * 128) → allow like `git branch <name>` — NOT a branch-state trigger; FORCE
 * copy (uppercase C in a copy run = git's --copy --force, or any force
 * spelling — -Cq/-cf/-fC/-f -c/--force --copy, all probe-verified to clobber a
 * free dst rc 0) mutates the DESTINATION ref → branchState true so M3 gates it
 * (dst == currentBranch passes through to git's rc-128 refusal via the #591
 * carve-out; foreign/non-checked-out overwrite targets block).
 * @param {string[]} args
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
 * duplicate of branch-ownership.mjs's _branchPositionals (cross-pinned). See
 * there for the git semantics: --sort/--format under every UNAMBIGUOUS prefix
 * git accepts (--so/--sor/--sort — --so is minimal: --show-current diverges
 * at --sh, --s is ambiguous with --show-current rc 129; --form/--forma/
 * --format — --fo/--for are ambiguous with --force rc 129) consume the
 * SEPARATE next argv as their REQUIRED value even in copy/move/force-create
 * mode (probe-verified rc 0 + real ref mutation), so the naive non-dash filter
 * would count that value as a branch-name positional and corrupt the M3
 * dst/from/to extraction. Other branch value-takers never land a value in the
 * branch-name slot of an rc-0 MUTATING invocation: the list-filter options
 * --points-at/--contains/--no-contains/-u/--set-upstream-to and
 * --merged/--no-merged error rc 128/129 (usage) BEFORE mutating in
 * copy/move/delete arms (probe-verified), while --column/--color/--abbrev/--track
 * are OPTARG options that only ever take an ATTACHED `=` value — a following
 * word is a positional in git and here alike (`-C --color always main t2` is
 * "too many branches" rc 128); under `-f` the LIST-printing filters
 * (--points-at/--contains/--merged/...) flip git to rc-0 no-mutation LIST
 * mode, while --sort/--format are ACCEPTED and still force-create rc 0 (hence
 * the swallow modeled above). Attached `--sort=x` never consumes the next
 * argv; `--` terminates flag
 * parsing.
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

/**
 * #626: resolve a checkout/switch long option NAME to its create kind using
 * git's parse-options UNAMBIGUOUS-PREFIX rules (probe-verified git 2.50.1).
 * VERB-AWARE — the two verbs have different option tables:
 *   git switch  : --create, --force-create, --orphan
 *                 (`--cre=foo` ≡ `--create=foo`, `--force-c` ≡ `--force-create`)
 *   git checkout: --orphan ONLY — it has NO --create/--force-create, so its
 *                 `--c*` resolves to --conflict and `--f*` to --force. Those are
 *                 VALID commands and must NOT classify as creates.
 * `--force` (and for checkout `--f`/`--fo`/`--for`/`--forc`) is the force flag,
 * not force-create → null. Ambiguous prefixes git itself rejects (switch `--c`,
 * `--f`..`--forc`, `--o`; checkout `--o`) are still classified as their create
 * kind — fail-closed on an rc-129 command is harmless.
 * Duplicated from branch-ownership's _longCreateKind (classify-git must not
 * import branch-ownership — test pin C2/D2). Keep the two in sync.
 */
function _longCreateKind(verb, name) {
  if (!name) return null;
  if ("orphan".startsWith(name)) return "orphan"; // both verbs have --orphan
  if (verb === "switch") {
    if (name === "force") return null; // --force: the force flag, not --force-create
    if ("create".startsWith(name)) return "create-new";
    if ("force-create".startsWith(name)) return "force-create";
  }
  return null;
}

/**
 * #626: the branch NAME created (or force-created/an orphan) by a checkout/switch
 * argv, across git's full spelling surface — attached short clusters
 * (`-bfoo`, `-fb foo`, `-cfoo`, `-Cfoo`) and the long forms
 * `--create[=v]` / `--force-create[=v]` / `--orphan[=v]` plus their unambiguous
 * verb-specific prefixes (`switch --cre=foo`, `switch --force-c main`,
 * `checkout --orph v`). Mirrors branch-ownership's _checkoutCreateOpt (kept
 * duplicated — classify-git must not import branch-ownership, test pin C2/D2).
 * Returns null when no create option is present.
 */
function _checkoutCreateBranch(verb, args) {
  for (let i = 0; i < args.length; i++) {
    const x = args[i];
    if (x === "--") return null;
    const long = /^--([^=]+)(?:=(.*))?$/.exec(x);
    if (long && _longCreateKind(verb, long[1])) {
      return long[2] !== undefined ? long[2] : (args[i + 1] ?? null);
    }
    const sc = /^-(?!-)([A-Za-z]+)(.*)$/.exec(x);
    if (sc) {
      const k = sc[1].search(/[bBcC]/);
      if (k !== -1) {
        const attached = sc[1].slice(k + 1) + sc[2];
        return attached.length > 0 ? attached : (args[i + 1] ?? null);
      }
    }
  }
  return null;
}

/**
 * #591 (round-3→5 fold): does `raw` HIDE a branch-STATE-MUTATING git invocation
 * in content allGitInvocations cannot see per-invocation? allGitInvocations
 * collapses `$(…)`/backticks/eval/alias/piped-shell payloads to opaque tokens,
 * so `git branch -fq own old ; echo "$(git branch -fq victim old)"` reports
 * stateOpCount 1 (only the visible segment) and the M3 benign carve-out on the
 * own-branch segment would let the hidden FOREIGN force-create execute
 * (pre-#591 the exact-force own segment blocked the whole command). The scan
 * covers, with a QUOTE-AWARE paren walk (a `)` inside quotes must not close a
 * `$(…)` span early — round-5 reviewer P1, probe-verified rc 0):
 *   - `$(…)` spans and backticks, recursing into nested spans;
 *   - ANSI-C `$'…'` literals (`sh -c $'git branch -fq victim main'` — the
 *     tokenizer reads the ANSI form as an unresolvable `$VAR`, missing the
 *     inline; round-5 reviewer P1);
 *   - static `eval "…"/'…'` literals;
 *   - a top-level `__unverifiable__` segment (eval/alias/`$VAR` command
 *     indirection whose expansion cannot be classified — round-4 reviewer P2,
 *     probe-verified `EV="git branch -fq victim main"; eval $EV` moves a
 *     foreign ref rc 0): fail closed — content that cannot be PROVEN free of
 *     another state mutation must refuse the carve-out (same rationale as M4's
 *     fail-closed `__unverifiable__` block);
 *   - escaped backticks (`\``) signal NESTED backtick content — unparseable →
 *     fail closed.
 * Each payload is re-tokenized and scanned for a MUTATING branch invocation:
 * checkout/switch/symbolic-ref/update-ref always, git branch via the
 * arm-exact _branchInvMutatesBranchState mirror (rename incl. #592 clusters /
 * long forms, delete, force-create, force-copy — #596 round-2 consolidation;
 * the scan previously recognized only exact -m/-M + delete + narrow-force, so
 * a hidden `-Mq`/`--move`/`-Cq` payload laundered the benign-force carve-out)
 * — non-mutating branch READS (`--show-current`, `--list`, rev-parse
 * payloads) stay benign-eligible so `git branch -fq own $(git rev-parse
 * HEAD)` isn't a false block. index.ts ORs this with the
 * hub-gate's _unverifiableGitContent (piped-stdin shells, process
 * substitution, heredocs, alias/function definitions, spawner `$VAR`s — the
 * round-6→19 hardened shape set) before refusing the carve-out (decideM3's
 * hiddenStateSubst bound). Exported for cross-layer pins (test.mjs).
 * @param {string} raw
 * @returns {boolean}
 */
/**
 * #591 (round-7/8): ANSI-C $'…' escape translation — \n \t \r \a \b \f \v \\ \'
 * \" \$ \e/\E \cX and zsh's \C-X/\Cx (char & 0x1f: \cJ/\C-J = LF) \xHH
 * \uHHHH (1-4 hex digits,
 * greedy — \uA = LF, cycle-5 P1) \UHHHHHHHH (1-8 digits, greedy) and octal. Code points
 * above 0x10FFFF clamp to U+FFFD (cycle-5 P2) rather than throwing.
 * Applied to ANSI-C payloads BEFORE scanning: an untranslated multiline payload
 * (`sh -c $'echo a\ngit branch -fq victim main'`) tokenizes as ONE glued word
 * and the hidden git invocation is invisible (round-6/7 reviewers P1, probe-
 * verified rc 0). Identity for non-ANSI text.
 * @param {string} s
 * @returns {string}
 */
export function ansiTranslate(s) { return _ansiTranslate(s); }

function _ansiTranslate(s) {
  const ansiMap = { n: "\n", t: "\t", r: "\r", "\\": "\\", "'": "'", '"': '"', $: "$", a: "\u0007", b: "\b", f: "\f", v: "\v", e: "\u001b", E: "\u001b" };
  return s.replace(/\\((?:c|C-?)[A-Za-z]|x[0-9a-fA-F]{1,2}|u[0-9a-fA-F]{1,4}|U[0-9a-fA-F]{1,8}|[0-7]{1,3}|[eE\\'"$ntrabvf])/g, (mm, e) => {
    if (e[0] === "x") return String.fromCharCode(parseInt(e.slice(1), 16));
    if (e[0] === "u" || e[0] === "U") {
      // bash/zsh decode \u with 1-4 hex digits and \U with 1-8, greedily
      // (`\uA` = LF — round-7 cycle-4 reviewer P1, probe-verified rc 0), and
      // reject code points > 0x10FFFF (round-8 cycle-5 P2: String.fromCodePoint
      // would throw a RangeError on valid shell input — clamp instead).
      const cp = parseInt(e.slice(1), 16);
      return cp > 0x10FFFF ? "\uFFFD" : String.fromCodePoint(cp);
    }
    if (e[0] === "c" || e[0] === "C") {
      // bash spells \cX, zsh (the agent shell) spells \C-X / \Cx — both decode
      // to char & 0x1f (\C-J = LF, re-splits the payload — round-9 cycle-6b
      // reviewer P1, probe-verified rc 0 in real zsh). Optional hyphen: "C-X"
      // -> e[2], "CJ"/"cJ" -> e[1].
      const ch = e.length > 2 ? e[2] : e[1];
      return String.fromCharCode(((ch ?? "").charCodeAt(0) ?? 0) & 0x1f);
    }
    if (/^[0-7]+$/.test(e)) return String.fromCharCode(parseInt(e, 8));
    return ansiMap[e] ?? mm;
  });
}

export function _hasHiddenStateSubst(raw) {
  const source = String(raw ?? "");
  const mutates = (inv) => {
    if (["checkout", "switch", "symbolic-ref", "update-ref"].includes(inv.verb)) return true;
    // #596 (round-2 reviewer F1): consolidate on the arm-exact mirror — the
    // stale inline copy only knew exact -m/-M + delete + narrow-force, so the
    // #592 rename-cluster/long-form and force-COPY spellings (-Mq/--move/
    // -Cq/…) were invisible here and a hidden payload of that surface
    // laundered the #591 benign-force carve-out (probe-verified rc 0).
    return inv.verb === "branch" && _branchInvMutatesBranchState(inv.args);
  };
  // Quote-aware payload collector: `$(…)`/`<(…)`/`>(…)` spans close only on a
  // paren OUTSIDE quotes/escapes; ANSI-C `$'…'` literals; backticks pair to
  // the next (top-level escaping already fails closed above the collector).
  const collect = (src) => {
    const spans = [];
    let i = 0;
    const n = src.length;
    while (i < n) {
      const c = src[i];
      if (c === "$" && src[i + 1] === "'") {
        let j = i + 2;
        while (j < n && src[j] !== "'") { if (src[j] === "\\") j++; j++; }
        // ANSI-C $'…' escapes translate BEFORE scanning: a multiline payload
        // (`sh -c $'echo a\ngit branch -fq victim main'`) carries the real
        // newline as \n — without translation the payload tokenizes as ONE
        // glued word and the hidden git invocation is invisible (round-6
        // cycle-3 reviewer P1, probe-verified rc 0).
        // Round-7 (cycle-4 reviewers P1): ANSI-C escapes translate BEFORE
        // scanning (see _ansiTranslate) — \cJ = a real newline re-splits the
        // payload into a second command; without translation the payload
        // tokenizes as ONE glued word and the hidden git invocation is
        // invisible (probe-verified rc 0).
        spans.push(_ansiTranslate(src.slice(i + 2, j)));
        i = j < n ? j + 1 : n;
        continue;
      }
      if ((c === "$" || c === "<" || c === ">") && src[i + 1] === "(") {
        let depth = 1;
        let q = null; // null | '"' | "'"
        let j = i + 2;
        while (j < n && depth > 0) {
          const d = src[j];
          if (q !== null) {
            if (d === "\\") j++;
            else if (d === q) q = null;
          } else if (d === "\"" || d === "'") q = d;
          else if (d === "(") depth++;
          else if (d === ")") depth--;
          j++;
        }
        spans.push(src.slice(i + 2, Math.max(i + 2, j - 1)));
        i = j;
        continue;
      }
      if (c === "`") {
        const j = src.indexOf("`", i + 1);
        spans.push(src.slice(i + 1, j > -1 ? j : src.length));
        i = j > -1 ? j + 1 : src.length;
        continue;
      }
      i++;
    }
    return spans;
  };
  // Top-level unverifiable segment (eval/alias/$VAR command indirection) —
  // its expansion is unclassifiable, so it may hide a second state mutation.
  if (allGitInvocations(source).some((inv) => inv.verb === "__unverifiable__")) return true;
  if (/\\`/.test(source)) return true; // nested-backtick escaping — fail closed
  // $(<file) bash file-read substitution: the content is opaque file text fed
  // to the shell (`eval "$(< /tmp/payload)"` runs whatever the file holds —
  // round-6 cycle-3 reviewer P2, probe-verified rc 0). Also checked per-span in
  // scan() because ANSI-C translation can REVEAL a decoded `$(<` (\x24\x3c).
  if (/\$\(</.test(source)) return true;
  const seen = new Set();
  const scan = (inner, isProcSubst) => {
    if (inner === undefined || inner.length === 0 || seen.has(inner)) return false;
    seen.add(inner);
    if (/\$\(</.test(inner)) return true; // decoded file-read substitution inside a span (\x24\x3c …)
    if (isProcSubst && /\bgit\b/.test(inner)) return true; // executable text fed to a shell (round-19 parity)
    for (const inv of allGitInvocations(inner)) {
      if (inv.verb === "__unverifiable__") return true;
      if (mutates(inv)) return true;
    }
    for (const sub of collect(inner)) {
      if (scan(sub, false)) return true;
    }
    return false;
  };
  for (const inner of collect(source)) {
    if (scan(inner, false)) return true;
  }
  // process substitution `<(…)`/`>(…)`: its body is executable text the
  // classifier cannot evaluate (bash <(echo 'git branch …') runs it) — the
  // content is scanned separately so a git word ANYWHERE is a risk.
  const procRe = /[<>]\(([^)]*)\)/g;
  let pm;
  while ((pm = procRe.exec(source)) !== null) {
    if (scan(pm[1] ?? "", true)) return true;
  }
  for (const t of _tokenize(source)) {
    for (const inner of collect(t)) {
      if (scan(inner, false)) return true;
    }
  }
  // static eval literals (non-static `eval $EV` → __unverifiable__ above):
  // plain "…"/'…' scan raw; ANSI-C $'…' payloads translate FIRST (an eval'd
  // $'…' can smuggle a decoded `$(<` or newline-split git — round-7 cycle-4
  // reviewer P1, probe-verified rc 0).
  const evalRe = /eval\s+(?:\$'([^']*)'|"([^"]*)"|'([^']*)')/g;
  let m;
  while ((m = evalRe.exec(source)) !== null) {
    const ansi = m[1];
    const payload = ansi !== undefined ? _ansiTranslate(ansi) : (m[2] ?? m[3] ?? "");
    if (payload.length > 0 && scan(payload, false)) return true;
  }
  // git-level alias indirection (round-6/7 cycles, reviewers P1, probe-verified
  // rc 0): `git branch -fq own main ; git -c alias.br='git branch -fq victim
  // main' br` hides the real command behind the alias NAME — the invocation walk
  // sees verb "br" and stateOpCount stays 1, so the benign carve-out would fire
  // while the alias force-creates a FOREIGN branch. Refuse when a statically-
  // visible config alias VALUE (a) carries a state-mutating git spelling via
  // scan(), (b) starts with '!' — git's shell-command alias marker, the WHOLE
  // value is arbitrary shell text (`alias.br='!git branch -fq victim main'`,
  // round-7 cycle-4 P1, probe-verified rc 0), or (c) whose first word is a
  // branch-state verb (args are appended at the call site: `alias.x=branch x
  // -fq victim main`). Whole-value-quoted `-c "alias.br=…"` and the
  // GIT_CONFIG_PARAMETERS env form are separate passes below. Benign values
  // (status/log/diff) pass. (STANDALONE alias invocation after configuration
  // and the same-command `git config --add alias.x … && git x` persist+invoke
  // are the pre-existing gap → issue #594.)
  const cfgAlias = /(?:\-c|\-\-config)(?:\s+["']?alias\.|=alias\.)([A-Za-z0-9_.\/-]+)=(?:"([^"]*)"|'([^']*)'|(\S+))/g;
  let cm;
  while ((cm = cfgAlias.exec(source)) !== null) {
    const val = cm[2] ?? cm[3] ?? cm[4] ?? "";
    if (val.startsWith("!")) return true; // shell-command alias — unverifiable shell text
    const firstWord = val.trim().split(/\s+/)[0];
    if (["branch", "checkout", "switch", "symbolic-ref", "update-ref"].includes(firstWord)) return true;
    if (val.length > 0 && scan(val, false)) return true;
  }
  // whole-value-quoted -c "alias.x=…" / -c 'alias.x=…' (the quote sits BEFORE
  // the config name — the pass above only tolerates a quote right after the
  // space; round-7 cycle-4 reviewer P1, probe-verified rc 0).
  const cfgAliasQ = /(?:\-c|\-\-config)\s+(["'])(alias\.[A-Za-z0-9_.\/-]+)=([^"']*)\1/g;
  let cq;
  while ((cq = cfgAliasQ.exec(source)) !== null) {
    const val = cq[3] ?? "";
    if (val.startsWith("!")) return true;
    const firstWord = val.trim().split(/\s+/)[0];
    if (["branch", "checkout", "switch", "symbolic-ref", "update-ref"].includes(firstWord)) return true;
    if (val.length > 0 && scan(val, false)) return true;
  }
  // opaque env-backed aliases: --config-env=alias.x=ENV, GIT_CONFIG_KEY_n\d+=
  // alias.x, and GIT_CONFIG_PARAMETERS (git's internal -c env — round-7 cycle-4
  // reviewer P1, probe-verified rc 0) all refuse the carve-out.
  if (/(?:\-\-config\-env[=\s]+\S*alias\.|GIT_CONFIG_KEY_\d+=alias\.|GIT_CONFIG_PARAMETERS=[^;]*alias\.)/.test(source)) return true;
  return false;
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
 *   branch forms: `git branch -d|-D|--delete <b>...` plus merged NOARG
 *     flag-clusters containing the delete short (`-Dq` = -D --quiet, `-dq` =
 *     -d --quiet — #587); cluster suffixes are FLAGS, never attached names,
 *     so targets are the following positionals only.
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
    // #587 (review fold-in): git merges NOARG shorts into ONE token, so the
    // delete short can sit ANYWHERE in a single-dash cluster (`-Dq`, `-dq`,
    // `-qD`, `-qd`, `-qvD`) — not just first — mirroring the push family's
    // `_isPushDeleteFlagToken` any-position detection (#443). The `u`-prefix
    // exclusion mirrors the regex guard: `-u<value>` (set-upstream-to) is not
    // a delete. Long form: `--delete` with its unambiguous `--d*` prefix
    // abbreviations (`--d`, `--de`, `--del`, … — branch's only `--d*` option;
    // parity with #443's push `--del` handling).
    // #591 (round-3 fold): delete letters are read from the token's VALUE-
    // AWARE flag run only (see _branchToken) — letters an arg-taking short
    // consumed as an attached VALUE (`-ftdirect`'s "direct" — a real force-
    // CREATE rc 0) must not read as delete letters. Non-u/non-mid-t tokens
    // keep the whole-run semantics (`-Dq`, `-qD`, `-Dold` still delete-flag).
    const hasDelete = a.some((x) => /^--d/.test(x) ||
      (/^-[A-Za-z]+$/.test(x) && /[dD]/.test((_branchToken(x)?.run) ?? "")));
    if (!hasDelete) return null;
    const names = [];
    for (const x of a) {
      // #587: git's parse-options merges NOARG shorts into one token, so any
      // single-dash d/D token (`-Dq`, `-dq`, `-D`, `-Dold`) is a delete-flag
      // CLUSTER — the suffix is more flags (or, for invalid letters like the
      // `o` in `-Dold`, an rc-129 error that deletes nothing), NEVER an
      // attached branch name. The old `/^-[dD][^-]/ → slice(2)` capture read
      // `-Dq` as a phantom name "q" — an over-capture that poisoned
      // deleteTargets (own-branch `-Dq feat/x` listed ["q","feat/x"] and
      // false-blocked the ceremony once -Dq classifies block). Targets are
      // the following positionals only.
      if (/^-[dD]/.test(x)) continue;
      if (x === "--delete") continue;
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

// ── #628: disordered-hub new-file VOLUME policy ────────────────────────────
// The #436 carve-out (newFileWriteCollisionFree) is COLLISION-free, not
// harm-free: an unbounded run of new hub files grows the dirty set the hub's
// recovery must carry, and the M4 carve-out returns before any write-time
// prompt. Policy (decided in #628 scoping): warn at write time for EVERY new
// hub file while disordered (all paths — not just the #350 WIP patterns),
// escalate once a session crosses the budget, and BLOCK past the hard cap
// (a session that has written 25 new files into a disordered hub needs a
// worktree, not a bigger allowance). The cap is a TRUE positive by
// construction (the hub's only legal state is main+clean), so it does not
// violate the "false-blocks are not acceptable" doctrine.
export const HUB_NEW_FILE_WARN_BUDGET = 10;
export const HUB_NEW_FILE_BLOCK_CAP = 25;

/**
 * Volume verdict for the Nth new hub file written by ONE session while the
 * hub is disordered. Pure + exported for pins (#628).
 * @param {number} count — 1-based count INCLUDING the current write
 * @returns {"warn"|"escalate"|"block"}
 */
export function hubNewFileVolumeVerdict(count) {
  const n = Number.isFinite(count) ? Math.floor(count) : 0;
  if (n <= HUB_NEW_FILE_WARN_BUDGET) return "warn";
  if (n <= HUB_NEW_FILE_BLOCK_CAP) return "escalate";
  return "block";
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
    `   → Reconcile branch state first: \`git fetch\` (an M4-sanctioned recovery verb),`,
    `     then create the branch in an ISOLATED WORKTREE —`,
    `     \`git worktree add -b ${branch} <path> origin/${branch}\` (in-hub`,
    `     \`checkout -b\` is BLOCKED, #626) — and retry from there.`,
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

// Does any ancestor of `p` (p itself included) carry the exact name `.git`?
// Drives the git-internal walk in resolveTargetCheckout (a target under a
// repo's `.git/` metadata dir must keep walking up to the OWNING checkout; a
// genuinely non-git path has no `.git` ancestry and stops after one probe).
// Exported so index.ts can cheaply decide whether a SYMLINKED/external-gitdir
// SPELLING (whose realpath lost the `.git` segment) still deserves a
// spelling-based classify pass (cycle-2 F4-a).
export function hasDotGitAncestor(p) {
  let cur = resolve(p);
  for (;;) {
    if (basename(cur) === ".git") return true;
    const parent = dirname(cur);
    if (parent === cur) return false;
    cur = parent;
  }
}
const _hasDotGitAncestor = hasDotGitAncestor;

/**
 * #618/#621 — the TARGET-aware checkout classification for a write/edit path
 * (the shared mechanism both hub-write issues consume). Resolves the git
 * checkout CONTAINING a target path (walking up to the nearest existing
 * ancestor so writes into not-yet-created dirs still resolve) and classifies
 * it MAIN-checkout vs linked-worktree:
 *   - top    = resolve-normalized git toplevel of the containing checkout (or
 *              null when the path is outside any git repo)
 *   - isMain = true when the containing checkout is the repo's MAIN checkout
 *              — judged STRUCTURALLY (gitCheckoutIsLinkedWorktree realpath
 *              comparison; the old git-dir path-substring test misread a
 *              main checkout whose own path contains a `worktrees` segment)
 *              — a "hub main" path whose tracked files must be gated no
 *              matter where the session sits.
 * Git-internal targets (a path INSIDE a repo's `.git` metadata dir — hooks/,
 * config, worktrees/) fail `rev-parse --show-toplevel` from within `.git`;
 * the walk continues PAST the nearest `.git` directory to the OWNING checkout
 * so `<hub>/.git/hooks/pre-commit` resolves to the hub MAIN (never to "outside
 * any git repo" — the write gates must be able to gate it). For a genuinely
 * non-git path (no `.git` segment in the ancestry) the loop exits after ONE
 * failed probe — no unbounded ancestor scanning on the hot path.
 * Worktree targets return { top, isMain:false } — isolated by construction, so
 * callers let them through (epic-529: a worktree session's own edits resolve
 * to ITS worktree checkout, never a main checkout).
 * @param {string} targetPath — write/edit target (relative to cwd or absolute)
 * @param {string} [cwd]
 * @returns {{ top: string, isMain: boolean } | null}
 */
export function resolveTargetCheckout(targetPath, cwd = process.cwd()) {
  try {
    const abs = resolve(cwd, targetPath ?? "");
    let dir = abs;
    // A DIRECTORY input IS the checkout dir to classify (session cwds,
    // already-created target dirs); a FILE input classifies via its parent
    // dir; a not-yet-existing path walks up to the nearest existing dir.
    if (existsSync(dir) && !statSync(dir).isDirectory()) dir = dirname(dir);
    while (!existsSync(dir)) {
      const parent = dirname(dir);
      if (parent === dir) break;
      dir = parent;
    }
    for (let hops = 0; hops < 64; hops++) {
      try {
        const top = execSync("git rev-parse --show-toplevel", {
          encoding: "utf-8", cwd: dir, timeout: 5000, stdio: ["ignore", "pipe", "ignore"],
        }).trim();
        if (top) {
          return { top: resolve(top), isMain: !gitCheckoutIsLinkedWorktree(dir) };
        }
      } catch { /* not a checkout from `dir` — try the relevant ancestor */ }
      const parent = dirname(dir);
      if (parent === dir) break;
      // Walk up ONLY while the probe still sits under a `.git` DIRECTORY in
      // its ancestry (a git-internal target whose owner checkout sits above
      // the topmost .git). A non-git path (no .git segment) or an ordinary
      // repo path that already resolved breaks here — one failed probe total
      // on the hot path (cost control), never an unbounded ancestor scan.
      if (!_hasDotGitAncestor(dir)) break;
      dir = parent;
    }
    return null;
  } catch {
    return null;
  }
}

/**
 * #618/#621 — ONE bounded index query for candidate rels in a repo checkout:
 * `git ls-files --error-unmatch` prints exactly the TRACKED rels (exit≠0 when
 * any path is untracked — stdout still carries the tracked matches). Returns
 * the tracked subset (empty array when none). Callers pair it with
 * firstHubTrackedWrite to pick the first tracked candidate.
 * @param {string} repoTop — the checkout's git toplevel (cwd for the query)
 * @param {string[]} rels — repo-relative candidate paths
 * @returns {string[]}
 */
export function trackedRelsIn(repoTop, rels) {
  if (!repoTop || !Array.isArray(rels) || rels.length === 0) return [];
  let out = "";
  try {
    out = execFileSync("git", ["ls-files", "--error-unmatch", "--", ...rels], {
      cwd: repoTop, encoding: "utf-8", timeout: 5000,
    }).toString();
  } catch (e) {
    // execFileSync throws on exit≠0 but stdout still carries the tracked
    // matches — read the captured stdout (same pattern as index.ts #437).
    out = (e && typeof e === "object" && "stdout" in e && e.stdout ? String(e.stdout) : "");
  }
  return out.split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
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
 * #437 (C): intersect bash-write candidates with hub-INDEX-tracked paths —
 * the decision that turns the #350 warn-only bash-write heuristic into a
 * GATE for tracked hub files in a DISORDERED hub. PURE (no git): the caller
 * (index.ts) supplies the tracked set from ONE bounded `git ls-files
 * --error-unmatch` call; candidates carry their hub-relative rel alongside
 * the resolved absolute path. Untracked/new-file targets are NOT this gate's
 * concern (they keep the #350 warn-only treatment — legit WIP scratch).
 * @param {{resolvedPath: string, rel: string}[]} candidates hub-resolved write targets
 * @param {string[]} trackedRels hub-relative rels known to be index-tracked
 * @returns {{resolvedPath: string, rel: string} | null}
 */
export function firstHubTrackedWrite(candidates, trackedRels) {
  const norm = (r) => String(r ?? "").replace(/^\/+/, "").replace(/^(\.\/)+/, "");
  const tracked = new Set((trackedRels ?? []).map(norm));
  for (const c of candidates ?? []) {
    const rel = norm(c.rel);
    if (rel && tracked.has(rel)) return c;
  }
  return null;
}



/**
 * #437 (C) review-hardening (v6): PER-WRITE-SITE resolved bash-write candidates
 * for the disordered-hub GATE. Bash-correct semantics (probe-verified):
 *  - cd applies to FOLLOWING commands (at the next &&/;/||/newline/`)`/end),
 *    never within its own simple command — redirections on the cd command
 *    (`cd docs > list.txt`) resolve PRE-cd; `cd docs && echo x > f` POST-cd.
 *    A pending cd DIES at isolation boundaries (`|` pipe segments / `&`
 *    background lists reseed to the list-start cwd — subshell semantics).
 *  - heredoc BODIES are stdin data — skipped ENTIRELY in the walk (they never
 *    shift the cwd, emit tee/cd words, or swallow trailing code; an
 *    unterminated heredoc swallows to EOF, matching bash's heredoc wait).
 *    python `open()` inside python-heredoc bodies is caught by the raw regex
 *    at the python token's extent + cwd (the 2026-08-31 incident shape).
 *  - python `open()` candidates emit ONLY inside a python interpreter's
 *    extent — quoted prose / grep-for-text never emit (legacy hasPython gate).
 *  - `-c`/`eval` payloads recurse (real code at the site cwd); script-file
 *    tokens surfaced for the caller's read (scriptGitVerdict parity).
 *    Interpreter FLAGS skip mirroring the git side: -c / letter-runs-with-c →
 *    payload; --rcfile/--init-file/-O/-o skip flag+operand; every other
 *    -flag/--option is operand-less (`bash -l x.sh`, `bash --norc x.sh` still
 *    reach the script); `< f` / `bash -s < f` stdin scripts surface as script
 *    tokens; interpreter-fed heredocs (`bash <<'EOF'`) recurse the BODY as
 *    CODE (bash/sh/zsh/dash/ksh read stdin) — cat-style bodies stay data.
 *  - escaped `\>` never starts a redirect; `2>`/fd-dup/close never emit.
 * PURE (no git; fs only for cd-target existence). Caller filters
 * hub-equality + tracked-ness. Documented residuals (out of threat model):
 * a cd TARGET that is an unresolved `$VAR` (`for d in sub; do cd $d && echo x
 * > f; done`) leaves the cwd at the token site (no shell state — same family
 * as the git-side M4 conservative $VAR handling; cycle-26 P2-3 documented);
 * python write modes OUTSIDE `open(...,'w*'|'a*')` (e.g. `r+`, `x`) and
 * pathlib write_text/write_bytes are not matched (the 2026-08-31 incident
 * used 'w'); unquoted-delim heredoc bodies
 * can carry `$(…)`/backtick substitution (bodies are walked as data except
 * for the interpreter-heredoc carve-out above); REDIRECT OPERANDS that are
 * shell expansions (`> $OUT`, `> "$FILE"`, `> $(cmd)`, `> ~/x` / `~user/x`)
 * stay LITERAL — the pure walker has no shell state to resolve them (an
 * `echo x > $OUT` pointing at a tracked hub file needs a deliberate
 * variable-binding + expansion; cycle-18 P2-2, in the same family the
 * git-side M4 classifier handles by conservative null/block on unresolved
 * `$VAR` in cd-chains); multi-line arithmetic whose `<<` RHS is a variable
 * AND whose `))` closer sits on the SAME line as the `<<` with the opener
 * on an EARLIER line (`(( a\n<< b + c ))` — closer not `))`-adjacent, not a
 * later-line closer, delim not numeric) is the remaining shift swallow
 * corner; `source`/`.` file targets ARE surfaced as script tokens (cycle-18
 * P2-1) — the caller's existsSync + content walk gates their tracked writes
 * exactly like `bash f` scripts. MECHANISM BOUNDARY (post-#474 review): the
 * gate scans bash write PRIMITIVES — `>`/`>>`/`>&` redirects, `tee`, python
 * `open(...,'w'|'a')` — NOT in-place overwrite VERBS (`sed -i`, `perl -pi`,
 * `cp`/`mv` onto a tracked file, `install`, `dd of=`, `tar -x`/`unzip -o`
 * into the hub, `patch -p1`): those contain no write-primitive construct. Since
 * #625 the in-place OVERWRITE VERBS ARE gated too (`sed -i`, `perl -pi`,
 * `awk -i inplace`, the `cp`/`mv`/`install`/`rsync`/`ln` destination (a
 * DIRECTORY destination resolves per-source to `dir/<basename(src)>`),
 * `truncate`, `dd of=`, `gsed`, `sort -o` (bundled `-ro` too, and any
 * UNAMBIGUOUS long-option prefix), `sponge`,
 * `ed`/`ex`/`vi`/`vim`/`nvi`, a bundled `-t` target-directory (`cp -ft dir`),
 * and a noclobber-override `>|` redirect) at COMMAND
 * position — `git mv a b` / `echo cp a b` stay ARG positions. Remaining
 * residuals (tracked separately): verb-in-ARG fan-outs (`find -exec`, `xargs`),
 * archive/member writers (`tar -x`, `unzip -o`, `patch`), DIRECTORY-TREE copies
 * whose per-file targets are not in the command string (`cp -R src/ dst/`,
 * `rsync -a src/ dst/`), backtick command substitution (the `$( )` form IS
 * walked), arbitrary interpreter writers (`node -e writeFileSync`, `ruby -e
 * File.write`, `php -r file_put_contents`), an rsync option that takes a
 * separate operand but is not in the rsync operand list (`--flag=value` forms
 * are self-delimiting), and a bare `rm` of a tracked file (a delete, not an
 * overwrite).
 */
// #625: command-position words whose invocation WRITES a file with no
// write-primitive token — the in-place OVERWRITE verbs. `sed`/`perl`/`awk`
// only when their in-place mode is present (checked in the handler);
// `cp`/`mv`/`install`/`truncate`/`dd` always write an operand.
const INPLACE_WRITE_VERBS = new Set([
  "sed", "gsed", "perl", "awk", "gawk", "mawk", "cp", "mv", "install", "truncate", "dd",
  "rsync", "ln", "sort", "sponge", "ed", "ex", "vi", "vim", "nvi",
]);
// #625 cycle-8: GNU getopt_long accepts any UNAMBIGUOUS long-option prefix
// (`--in-pl` == `--in-place`, `--expr` == `--expression`), so an exact-spelling
// match alone is a FAIL-OPEN bypass of the in-place closure (`sed --in-pl s/a/b/
// <hub>/AGENTS.md` resolved to ZERO targets and the gate allowed it). Resolve
// a prefix against the verb's REAL long-option table: an exact name wins, a
// prefix resolves only when exactly ONE name matches (ambiguous/unknown → null,
// i.e. not an option — the safe direction here, since every in-place spelling is
// reachable by an exact or unique-prefix match). Mirrors the sort/rsync handlers.
const _resolveLong = (tbl, name) => {
  if (Object.prototype.hasOwnProperty.call(tbl, name)) return name;
  const hits = Object.keys(tbl).filter((nm) => nm.startsWith(name));
  return hits.length === 1 ? hits[0] : null;
};
// sed/gsed long options: name → separate-operand arity (1 = takes the next word,
// 0 = no argument; `--flag=value` is self-delimiting).
const SED_LONG = {
  "in-place": 0, expression: 1, file: 1, "line-length": 1, "follow-symlinks": 0,
  debug: 0, posix: 0, quiet: 0, silent: 0, sandbox: 0, separate: 0, unbuffered: 0,
  "null-data": 0, "zero-terminated": 0, "regexp-extended": 0, binary: 0, help: 0, version: 0,
};
// gawk/awk (gawk extension) long options. `--include inplace` is the in-place
// mechanism; `include`/`file`/`source`/etc. take a separate operand.
const AWK_LONG = {
  include: 1, file: 1, source: 1, assign: 1, exec: 1, "field-separator": 1, load: 1,
  "dump-variables": 0, profile: 0, "pretty-print": 0, lint: 0, "lint-old": 0, posix: 0,
  traditional: 0, "re-interval": 0, "gen-pot": 0, "non-decimal-data": 0,
  "characters-as-bytes": 0, sandbox: 0, debug: 0, optimize: 0, nostalgia: 0, version: 0,
  help: 0, "use-lc-numeric": 0, bignum: 0, csv: 0, copyright: 0,
};
const _isSedInPlaceLong = (w) => {
  if (typeof w !== "string" || !w.startsWith("--")) return false;
  const eq = w.indexOf("=");
  return _resolveLong(SED_LONG, w.slice(2, eq === -1 ? undefined : eq)) === "in-place";
};

export function bashWriteTargetsResolved(command, sessionCwd = process.cwd()) {
  const s = String(command ?? "");
  const out = [];
  const seen = new Set();
  const base0 = resolve(sessionCwd || process.cwd());
  const push = (raw, cwd, via, site = "top") => {
    const t = _stripQuotes(String(raw ?? "").trim());
    if (!t || t === "/dev/null" || t.startsWith("/dev/")) return;
    const resolved = resolve(cwd, t);
    const key = `${via}:${resolved}`;
    if (seen.has(key)) return;
    seen.add(key);
    // #618/#621: carry the SITE cwd (the dir the write executes from) so the
    // caller can classify same-checkout vs deliberate cross-checkout writes
    // (a candidate whose resolved target sits in a DIFFERENT checkout than
    // its site cwd is a hub write the session shell is not rooted in).
    out.push({ resolvedPath: resolved, via, site, cwd: resolve(cwd) });
  };
  // Bash cwd semantics (probe-verified):
  //  - cd applies to FOLLOWING commands (at the next &&/;/||/newline/`)`/end),
  //    never within its own simple command (redirections resolve PRE-cd).
  //  - `|` pipe segments and `&` backgrounded lists run in subshells — a cd
  //    since the list's last continuation boundary does NOT survive them;
  //    `( )` subshells snapshot the cwd and restore on `)`.
  //  - heredoc BODIES are stdin data (skipped entirely in the walk; bodies
  //    never shift the cwd, emit tee/cd words, or swallow trailing code — an
  //    unterminated heredoc swallows to EOF, matching bash's heredoc wait).
  const frames = [{ cwd: base0, pending: null, forkCwd: null, forkAlts: [] }];
  // pipeBase: cwd at the start of the current PIPE list (updated at every
  // continuation boundary incl. &&); asyncBase: cwd at the start of the
  // current async segment (updated only at ;/newline/start/(/post-& — NOT at
  // && — so `cd docs && true & echo x > f` reseeds the echo to the PRE-cd
  // cwd, matching bash: the WHOLE `cd docs && true` list is async).
  const pipeBase = [base0];
  const asyncBase = [base0];
  let skipStart = -1;   // active heredoc-body region [skipStart, skipEnd):
  let skipEnd = -1;     // the header remainder is walked; the body is jumped
  // simple-command arg-position state (cycle-22 P1): special-word handlers
  // (cd/python/tee/interpreters/exec/eval/./source) fire ONLY on the FIRST
  // word of a simple command (after assignments/spawners/redirects) — `grep
  // tee f`, `echo bash -c '…'`, `echo cd /tmp && …` are ARG positions.
  let segHadWord = false;          // a command word seen in this segment
  let caseDepth = 0;               // case … in p) … esac — a pattern terminator ) is NOT a frame pop (cycle-25 P2-1)
  let casePattern = false;         // cycle-36 P2-1: inside a case, words between `in` and the arm's `)` are PATTERNS — never dispatched
  let caseValPending = false;      // cycle-37 F3: after `case` the NEXT word is the cased VALUE — never dispatched (bash doesn't execute it)
  let caseValConsumed = false;     // cycle-37 F1: only a case's OWN `in` (after its value) opens the pattern phase — a for/select `in` inside an arm must NOT
  const caseCwdStack = [];         // cycle-37 F2: each case arm runs from the pre-case cwd (real bash executes ONE arm) — restore at every arm terminator + esac
  let forceCmdNext = false;        // a leading \\ escape dropped — the word is at command position
  let spawnerPending = null;       // sudo/env/xargs/… — next real word is a command
  let envSawAssign = false;        // cycle-34 P2-2: env option parsing ENDS at the first name=value operand
  let spawnerOperandNext = false;  // a spawner flag that takes an operand
  const SPAWNER_WORDS = new Set(["sudo", "env", "xargs", "nohup", "command", "time", "nice", "doas", "stdbuf", "timeout", "builtin", "exec", "setsid"]); // exec = spawner prefix (r37 P3); setsid cycle-32 P1-1
  let dirStack = [];            // pushd/popd directory stack (cycle-23 F2)
  let dirStackSnapshots = [];  // FULL copy per ( - restored at ) (cycle-24 P1 r29 D1-D3:
                               // a subshell gets a COPY — ( popd ) must not eat an inherited entry)
  const SPAWNER_FLAG_OPERANDS = {
    exec: ["-a"],   // cycle-32 P1-2: exec -a argv0 cmd
    sudo: ["-u", "--user", "-g", "--group", "-C", "-h", "--host", "-D", "-T", "-r", "-t", "-p", "-U"],
    env: ["-u", "--unset", "-C", "--chdir", "-S"],
    xargs: ["-a", "-E", "-I", "-L", "-n", "-P", "-s", "-d", "-i", "--max-args", "--max-lines", "--replace", "--max-procs"],
    nice: ["-n"],
    timeout: ["-s", "-k", "--signal", "--kill-after"],
  };
  const RESET_WORDS = new Set(["then", "do", "else", "elif", "fi", "done", "esac", "in", "if", "while", "until", "case", "for", "select", "function", "{", "}", "!", "[[", "]]", "time"]);
  const redirs = [];
  const pythons = [];
  const tees = [];
  const verbToks = [];
  const inlinePays = [];
  const scriptToks = [];
  const n = s.length;
  const f = () => frames[frames.length - 1];
  // cycle-38 P1 (r38 reviewer): a MATCHED case arm's trailing cd persists past
  // esac (case runs in the current shell). The walker can't know which arm
  // matched, so when any arm ended deeper than the case entry it resumes the
  // continuation at that arm's terminal cwd AND emits an entry-base twin for
  // direct writes (the unmatched-arm reality). Return the twin entry or null.
  const forkTwins = (o) => {
    const fr = f();
    if (!fr.forkCwd || !fr.forkAlts || !fr.forkAlts.length) return [];
    return fr.forkAlts.map((b) => ({ ...o, cwd: b }));
  };
  const pipeB = () => pipeBase[pipeBase.length - 1];
  const asyncB = () => asyncBase[asyncBase.length - 1];
  const skipWs = (k) => { while (k < n && /\s/.test(s[k])) k++; return k; };
  const readWord = (k) => {
    let w = "";
    let q = null;
    while (k < n && !(q === null && (/\s/.test(s[k]) || ";|&()".includes(s[k]) || s[k] === ">" || s[k] === "<"))) {
      const ch = s[k];
      if (q) {
        // Inside double quotes bash treats `\` as an escape ONLY before
        // `$` / `` ` `` / `"` / `\` / newline; before any other char it is
        // literal (cycle-8 P2/P3: over-stripping false-positived on paths
        // like "MEMORY\.md").
        if (q === '"' && ch === "\\" && k + 1 < n && "\"\\$`\n".includes(s[k + 1])) {
          if (s[k + 1] !== "\n") w += s[k + 1];   // backslash-newline is a line continuation
          k += 2; continue;
        }
        if (ch === q) q = null; else w += ch; k++;
        continue;
      }
      // ANSI-C `$'…'`: decode escapes so a decoded `>` (\x3e / \076) is a real
      // redirect and a decoded path matches the tracked rel (#625 cycle-7).
      if (ch === "$" && s[k + 1] === "'") {
        let kk = k + 2, inner = "";
        while (kk < n && s[kk] !== "'") {
          if (s[kk] === "\\" && kk + 1 < n) { inner += s[kk] + s[kk + 1]; kk += 2; continue; }
          inner += s[kk]; kk++;
        }
        w += _ansiTranslate(inner);
        k = kk + 1;
        continue;
      }
      if (ch === "$" && s[k + 1] === '"') { q = '"'; k += 2; continue; }   // $"…" == "…"
      if (ch === "'" || ch === '"') { q = ch; k++; continue; }
      if (ch === "\\") {
        if (k + 1 < n && s[k + 1] === "\n") {
          // `\`+newline is a LINE CONTINUATION: bash deletes it and re-scans the
          // remaining text, so what follows still decides the word boundary.
          // A LEADING continuation + indent (`> \<NL>  f`) is just prefix
          // whitespace before the operand — skipping it is required, else the
          // word ends empty and the operand is dropped (#625 cycle-12 P1: the
          // redirect/tee operand path ALLOWed a tracked hub-main write). A
          // MID-WORD continuation followed by whitespace still TERMINATES the
          // word (`a\<NL>  b` is two words); with no whitespace it joins
          // (`a\<NL>b` → `ab`).
          const k2 = k + 2;
          if (k2 < n && /\s/.test(s[k2])) {
            if (w === "") { k = skipWs(k2); continue; }
            return { w, k: k2 };
          }
          k += 2; continue;
        }
        if (k + 1 < n) { w += s[k + 1]; k += 2; continue; }
      }
      w += ch; k++;
    }
    return { w, k };
  };
  const readShellArg = readWord;   // alias (same shell-argument semantics)
  // #625: in-place OVERWRITE verb targets — a write with no primitive token.
  // Command-position only (the caller dispatches on the simple-command word,
  // mirroring the `tee` branch): `git mv a b` / `echo cp a b` are ARG
  // positions and never reach here. Returns RAW operand strings; push()
  // resolves them against the site cwd. Over-match is the safe direction (a
  // non-tracked candidate is inert). Each verb's operand-taking flags are
  // consumed so a script/operand word is never mistaken for a file.
  const verbTargets = (verb, k0, siteCwd) => {
    const v = verb === "gsed" ? "sed" : verb; // GNU-sed spelling sibling
    const words = [];
    const skipParen = (j0) => {
      // Skip a balanced `( … )` group (quote-aware) — `$( )`, `<( )`, `>( )`.
      // The group content is not verb arguments, but a LITERAL operand after
      // it is (#625 cycle-3 P2).
      let d = 0, q = null;
      for (let j = j0; j < n; j++) {
        const c = s[j];
        if (c === "\\") { j++; continue; }   // `\(` / `\)` are literals, not nesting (#625 cycle-4 B1)
        if (q) { if (c === q) q = null; continue; }
        if (c === '"' || c === "'" || c === "`") { q = c; continue; }
        if (c === "(") d++;
        else if (c === ")" && --d === 0) return j + 1;
      }
      return n;
    };
    let k = skipWs(k0);
    while (k < n) {
      const c0 = s[k];
      // `#` at a word boundary starts a comment — stop the scan (mirrors the
      // main walker). Else the comment word becomes the LAST positional and the
      // real destination is dropped (#625 cycle-3 P1).
      if (c0 === "#" && (k === 0 || /[\s;&|(\n]/.test(s[k - 1]))) break;
      // `\` + newline is a line continuation — whitespace in bash (#625
      // cycle-3 P3).
      if (c0 === "\\" && s[k + 1] === "\n") { k = skipWs(k + 2); continue; }
      // `$( … )` / `<( … )` / `>( … )`: skip the balanced group, keep scanning.
      if (c0 === "(" || ((c0 === "<" || c0 === ">") && s[k + 1] === "(")) {
        k = skipWs(skipParen(c0 === "(" ? k : k + 1));
        continue;
      }
      if (";&|\n".includes(c0)) break;
      // Redirect with an OPTIONAL fd prefix (`2> f`, `2>&1`, `> f`, `&> f`):
      // consume operator + operand, never a verb target. The fd digits MUST be
      // consumed before readWord (which stops only at `>`), else
      // `cp a b 2>&1` parses `2` as the destination and the real target is
      // missed (#625 review P1).
      if (c0 === ">" || c0 === "<" || /[0-9]/.test(c0)) {
        let rk = k;
        while (rk < n && /[0-9]/.test(s[rk])) rk++;
        if (rk < n && (s[rk] === ">" || s[rk] === "<")) {
          const opStart = rk;
          while (rk < n && "<>&|".includes(s[rk])) rk++; // `|` for the `>|` noclobber-override form
          const op = s.slice(opStart, rk);
          rk = skipWs(rk);
          const opnd = readWord(rk);
          const nextK = skipWs(opnd.k > rk ? opnd.k : rk + 1);
          // `<<DELIM` opens a heredoc BODY — data, not a verb argument; stop
          // the scan there (the main walker skips the body).
          if (op.includes("<<")) { k = nextK; break; }
          k = nextK;
          continue;
        }
      }
      const w = readWord(k);
      // Advance past the parsed word. An EMPTY QUOTED word (`''`/`""` — the BSD
      // `sed -i ''` idiom) is a real positional slot; keep it in `words` so the
      // script/operand boundary stays aligned, but advance with w.k (a stale
      // k+1 lands inside the next word's quotes and mangles the command —
      // #625 review P1).
      if (w.w === "" && w.k <= k) { k = k + 1; continue; }
      words.push(w.w);
      k = skipWs(w.k);
    }
    const out = [];
    const isFlag = (w) => w.length > 1 && w[0] === "-";
    // A destination that is an existing DIRECTORY (or spelled with a trailing
    // slash) writes `dir/<basename(src)>` for each source — `cp src .` targets
    // `./src`, NOT the directory. Without this, `cp /tmp/evil/AGENTS.md .` from
    // a clean hub main surfaced the bare root dir, which classify skips
    // (rel === "") — a tracked-file overwrite with zero gate (#625 review P1).
    const dstIsDir = (dst) => {
      if (!dst) return false;
      if (/[/\\]$/.test(dst)) return true;
      try { return existsSync(resolve(siteCwd, dst)) && statSync(resolve(siteCwd, dst)).isDirectory(); } catch { return false; }
    };
    const emitDst = (dst, sources, alsoSources) => {
      if (dstIsDir(dst)) {
        for (const src of sources) out.push(join(dst, basename(src)));
      } else if (dst) {
        out.push(dst);
      }
      if (alsoSources) for (const src of sources) out.push(src);
    };
    if (v === "sed" || v === "perl") {
      // -i / --in-place = in-place edit. The script operand (-e/--expression,
      // -f/--file in sed; -e/-E in perl) does NOT write — consume it (attached
      // or as the next word) so it is never mistaken for a file. The cluster is
      // parsed LETTER BY LETTER: `-I./lib` in perl is ONE attached operand (not
      // a flag run), and a lowercase `i` INSIDE an attached operand
      // (`-MTime::HiRes`) is NOT the in-place flag — a `split(".")`/includes
      // scan both missed the real vector AND false-blocked read-only commands
      // (#625 review P1/P2).
      let inPlace = false;
      let hasScriptFlag = false;
      let expectOperand = false;
      let endOpts = false;
      const positionals = [];
      for (let wi = 0; wi < words.length; wi++) {
        const w = words[wi];
        if (expectOperand) { expectOperand = false; continue; }
        // BSD `sed -i ''` — the empty quoted word is the in-place SUFFIX, not a
        // positional (leaving it in the list makes the sed script the "file",
        // a spurious candidate — #625 review A3).
        if (w === "" && wi > 0 && (_isSedInPlaceLong(words[wi - 1]) || /^-[a-zA-Z]*i$/.test(words[wi - 1]))) continue;
        if (!endOpts && w === "--") { endOpts = true; continue; }
        if (!endOpts && isFlag(w) && w !== "-") {
          if (w.startsWith("--")) {
            // getopt_long abbreviation: `--in-pl`/`--in-pl=.bak` ARE
            // `--in-place` (#625 cycle-8 P1 — exact spelling alone was a
            // fail-open bypass). `--expr`/`--fil`/`--line-l` resolve likewise.
            const eq = w.indexOf("=");
            const resolved = _resolveLong(SED_LONG, w.slice(2, eq === -1 ? undefined : eq));
            if (resolved === "in-place") { inPlace = true; continue; }
            if (resolved !== null && SED_LONG[resolved] === 1) {
              if (resolved === "expression" || resolved === "file") hasScriptFlag = true;
              if (eq === -1) expectOperand = true;   // `--flag=value` is self-delimiting
            }
            continue;
          }
          const cluster = w.slice(1);
          let ci = 0;
          while (ci < cluster.length) {
            const ch = cluster[ci];
            if (ch === "i") { inPlace = true; ci = cluster.length; continue; } // optional attached suffix
            if (v === "sed" ? (ch === "e" || ch === "f") : (ch === "e" || ch === "E")) {
              hasScriptFlag = true;
              if (ci + 1 < cluster.length) ci = cluster.length; // attached operand
              else { expectOperand = true; ci++; }
              continue;
            }
            // `-F`/`-M`/`-m`/`-x` take an ATTACHED operand only; a bare one is
            // not followed by its value, so it must not swallow the next word
            // (`perl -F -pi -e …` — bare `-F` is not a separator operand, and
            // letting it consume `-pi` loses in-place mode; #625 cycle-3 P3).
            if (v === "perl" && (ch === "F" || ch === "M" || ch === "m" || ch === "x")) {
              if (ci + 1 < cluster.length) ci = cluster.length;
              else ci++;
              continue;
            }
            if (v === "perl" && ch === "I") {
              if (ci + 1 < cluster.length) ci = cluster.length; // attached operand
              else { expectOperand = true; ci++; }
              continue;
            }
            ci++;
          }
          continue;
        }
        positionals.push(w);
      }
      if (!inPlace) return out;
      // No -e/-f: the first positional IS the script (sed) / program (perl).
      const files = hasScriptFlag ? positionals : positionals.slice(1);
      for (const f of files) out.push(f);
      return out;
    }
    if (v === "awk" || v === "gawk" || v === "mawk") {
      // gawk in-place extension: `-i inplace`, `-iinplace`, `--include inplace`,
      // `--include=inplace`.
      let inPlace = false;
      let hasProgFlag = false;
      let expectOperand = false;
      const positionals = [];
      for (let wi = 0; wi < words.length; wi++) {
        const w = words[wi];
        if (expectOperand) { expectOperand = false; continue; }
        if (isFlag(w) && w !== "-") {
          if (w.startsWith("--")) {
            // gawk also accepts getopt_long abbreviations: `--incl inplace`
            // IS `--include inplace` (#625 cycle-8 P1).
            const eq = w.indexOf("=");
            const resolved = _resolveLong(AWK_LONG, w.slice(2, eq === -1 ? undefined : eq));
            if (resolved === "include") {
              if (eq === -1) {
                if (words[wi + 1] === "inplace") { inPlace = true; expectOperand = true; }
                else if (AWK_LONG[resolved] === 1) expectOperand = true;
              } else if (w.slice(eq + 1) === "inplace") inPlace = true;
              continue;
            }
            if (resolved !== null && AWK_LONG[resolved] === 1) {
              // `--file`/`--source`/`--exec` PROVIDE the program, so the first
              // positional is a DATA file. Without hasProgFlag the handler's
              // `positionals.slice(1)` ate it and dropped the in-place target
              // entirely (#625 cycle-11 P1 REGRESSION: `gawk -i inplace --file
              // p.awk <hub>/f` and `gawk --incl inplace --source '{print}'
              // <hub>/f` resolved to ZERO targets → the gate ALLOWED a tracked
              // hub-main edit; the short `-f`/`-e` forms still gated).
              if (resolved === "file" || resolved === "source" || resolved === "exec") hasProgFlag = true;
              if (eq === -1) expectOperand = true;
              continue;
            }
            continue;
          }
          if (w === "-i" || w === "-f" || w === "-v" || w === "-E") {
            if (w === "-i" && words[wi + 1] === "inplace") { inPlace = true; expectOperand = true; }
            else { if (w === "-f" || w === "-E") hasProgFlag = true; expectOperand = true; }
            continue;
          }
          if (w === "-iinplace") { inPlace = true; continue; }
          continue;
        }
        positionals.push(w);
      }
      if (!inPlace) return out;
      const files = hasProgFlag ? positionals : positionals.slice(1);
      for (const f of files) out.push(f);
      return out;
    }
    if (v === "cp" || v === "mv" || v === "install") {
      let targetDir = null;
      let expectTarget = false;
      let expectOperand = false;
      let endOpts = false;
      const positionals = [];
      for (const w of words) {
        if (expectTarget) { targetDir = w; expectTarget = false; continue; }
        if (expectOperand) { expectOperand = false; continue; }
        if (!endOpts && w === "--") { endOpts = true; continue; }
        if (!endOpts && isFlag(w) && w !== "-") {
          if (w === "-t" || w === "--target-directory") { expectTarget = true; continue; }
          if (w.startsWith("--target-directory=")) { targetDir = w.slice("--target-directory=".length); continue; }
          if (w === "-S" || w === "--suffix") { expectOperand = true; continue; }
          if (v === "install" && (w === "-m" || w === "-o" || w === "-g")) { expectOperand = true; continue; }
          if (!w.startsWith("--") && /^-[a-zA-Z]/.test(w)) {
            // GNU bundling (`cp -ft dir`, `install -Dt dir`): scan the cluster
            // LEFT TO RIGHT and stop at the first operand-taking letter — `S`
            // (cp/mv/install) or install's `m`/`o`/`g`/`B` consumes the REST of
            // the cluster as its attached operand, so a `t` inside that operand
            // (`-S.tmp`, `-gstaff`) is NOT a target-directory (#625 cycle-1 B3
            // + cycle-2 P1).
            const cluster = w.slice(1);
            for (let ci = 0; ci < cluster.length; ci++) {
              const ch = cluster[ci];
              if (ch === "t") {
                const rest = cluster.slice(ci + 1);
                if (rest) targetDir = rest; else expectTarget = true;
                break;
              }
              if (ch === "S" || (v === "install" && (ch === "m" || ch === "o" || ch === "g" || ch === "B"))) {
                if (ci + 1 >= cluster.length) expectOperand = true;
                break;
              }
            }
          }
          continue;
        }
        positionals.push(w);
      }
      // mv REMOVES its sources as well as writing the destination — a tracked
      // SOURCE is a tracked-file mutation. cp/install only READ their sources.
      const alsoSources = v === "mv";
      // A destination requires at least ONE source: a single-operand
      // `cp f` / `mv f` / `install f` is a malformed no-op ("missing
      // destination file operand", rc≠0) that writes NOTHING — emitting its
      // lone operand as a destination was a pure false block (#625 cycle-8 P2,
      // same carve-out as single-operand rsync list mode).
      if (targetDir) {
        if (positionals.length > 0) emitDst(targetDir, positionals, alsoSources);
      } else if (positionals.length > 1) {
        emitDst(positionals[positionals.length - 1], positionals.slice(0, -1), alsoSources);
      }
      return out;
    }
    if (v === "truncate") {
      let expectOperand = false;
      let endOpts = false;
      for (const w of words) {
        if (expectOperand) { expectOperand = false; continue; }
        if (!endOpts && w === "--") { endOpts = true; continue; }
        if (!endOpts && isFlag(w) && w !== "-") {
          if (w === "-s" || w === "--size" || w === "-r" || w === "--reference") { expectOperand = true; continue; }
          if (w.startsWith("--size=") || w.startsWith("--reference=")) continue;
          if (/^-s./.test(w) || /^-r./.test(w)) continue;
          continue;
        }
        out.push(w);
      }
      return out;
    }
    if (v === "rsync" || v === "ln") {
      // Destination is the LAST positional. rsync PERMUTES options, so a bare
      // flag operand may appear AFTER the destination (`rsync -a src dst
      // --exclude foo`) — operand-taking flags MUST be consumed, else the
      // operand becomes the "destination" and the real one is missed
      // (#625 review P2). The list must contain ONLY options that take a
      // SEPARATE operand: a no-argument flag in here (`--owner`, `--itemize-
      // changes`, `--dry-run`, `-v`) swallows the real destination and drops
      // the gate (#625 cycle-2 P1). rsync uses popt, which accepts any
      // UNAMBIGUOUS long-option prefix (`--max-del 0` == `--max-delete 0`), so
      // the list is prefix-matched with exact names winning (#625 cycle-3 A4).
      // `--flag=value` is self-delimiting. A genuinely UNKNOWN operand-taking
      // option remains a documented residual — a prev-positional fail-safe was
      // tried and caused false blocks on read-only exports
      // (`rsync -a tracked.md -v /tmp/dst`), so it is gone.
      // A full arity table (name → takes a separate operand) for rsync's long
      // options. Prefix matching MUST consider the BOOLEAN options too: an
      // operand-only list made `--checksum` (a complete boolean option that
      // prefixes `--checksum-seed`) consume the destination — a real bypass and
      // a false block (#625 cycle-4 P1). `null` = ambiguous/unknown → not an
      // operand (the safe direction for a read).
      const RSYNC_LONG = [
        ["--verbose", 0], ["--quiet", 0], ["--no-motd", 0], ["--checksum", 0], ["--archive", 0],
        ["--recursive", 0], ["--relative", 0], ["--no-implied-dirs", 0], ["--backup", 0], ["--update", 0],
        ["--inplace", 0], ["--append", 0], ["--append-verify", 0], ["--dirs", 0], ["--old-dirs", 0],
        ["--mkpath", 0], ["--links", 0], ["--copy-links", 0], ["--copy-unsafe-links", 0], ["--safe-links", 0],
        ["--munge-links", 0], ["--copy-dirlinks", 0], ["--keep-dirlinks", 0], ["--hard-links", 0],
        ["--perms", 0], ["--executability", 0], ["--acls", 0], ["--xattrs", 0], ["--chmod", 1],
        ["--owner", 0], ["--group", 0], ["--devices", 0], ["--specials", 0], ["--times", 0],
        ["--atimes", 0], ["--open-noatime", 0], ["--omit-dir-times", 0], ["--omit-link-times", 0],
        ["--super", 0], ["--fake-super", 0], ["--sparse", 0], ["--preallocate", 0], ["--dry-run", 0],
        ["--whole-file", 0], ["--checksum-choice", 1], ["--one-file-system", 0], ["--block-size", 1],
        ["--rsh", 1], ["--existing", 0], ["--ignore-existing", 0], ["--remove-source-files", 0],
        ["--delete", 0], ["--delete-before", 0], ["--delete-during", 0], ["--delete-delay", 0],
        ["--delete-after", 0], ["--delete-excluded", 0], ["--ignore-errors", 0], ["--force", 0],
        ["--max-delete", 1], ["--max-size", 1], ["--min-size", 1], ["--max-alloc", 1], ["--partial", 0],
        ["--partial-dir", 1], ["--backup-dir", 1], ["--suffix", 1], ["--checksum-seed", 1],
        ["--checkpoint-action", 1], ["--info", 1], ["--debug", 1], ["--stderr", 1], ["--outbuf", 1],
        ["--config", 1], ["--dparam", 1], ["--copy-as", 1],
        ["--copy-devices", 0], ["--write-devices", 0], ["--delete-missing-args", 0], ["--delay-updates", 0], ["--prune-empty-dirs", 0], ["--numeric-ids", 0],
        ["--usermap", 1], ["--groupmap", 1], ["--chown", 1], ["--timeout", 1], ["--contimeout", 1],
        ["--ignore-times", 0], ["--size-only", 0], ["--modify-window", 1], ["--temp-dir", 1], ["--fuzzy", 0],
        ["--compare-dest", 1], ["--copy-dest", 1], ["--link-dest", 1], ["--compress", 0],
        ["--compress-choice", 1], ["--compress-level", 1], ["--skip-compress", 1], ["--cvs-exclude", 0],
        ["--filter", 1], ["--exclude", 1], ["--exclude-from", 1], ["--include", 1], ["--include-from", 1],
        ["--files-from", 1], ["--from0", 0], ["--protect-args", 0], ["--secluded-args", 0], ["--trust-sender", 0],
        ["--address", 1], ["--port", 1], ["--sockopts", 1], ["--password-file", 1], ["--early-input", 1],
        ["--blocking-io", 0], ["--stats", 0], ["--human-readable", 0], ["--progress", 0],
        ["--itemize-changes", 0], ["--remote-option", 1], ["--out-format", 1], ["--log-file", 1],
        ["--log-file-format", 1], ["--log-format", 1], ["--list-only", 0], ["--bwlimit", 1],
        ["--stop-after", 1], ["--fsync", 0], ["--write-batch", 1], ["--only-write-batch", 1],
        ["--read-batch", 1], ["--protocol", 1], ["--iconv", 1], ["--ipv4", 0], ["--ipv6", 0],
        ["--version", 0], ["--help", 0], ["--daemon", 0], ["--no-detach", 0], ["--old-args", 0],
        ["--rsync-path", 1], ["--msgs2stderr", 0],
      ];
      const RSYNC_OP_SHORT = new Set(["-e", "-f", "-B", "-T", "-M"]);   // rsync `-S` is --sparse, NOT --suffix
      const isRsyncOperand = (w) => {
        const eq = w.indexOf("=");
        const name = eq === -1 ? w : w.slice(0, eq);
        if (RSYNC_OP_SHORT.has(name)) return true;
        const exact = RSYNC_LONG.find(([nm]) => nm === name);
        if (exact) return exact[1] === 1;
        const hits = RSYNC_LONG.filter(([nm]) => nm.startsWith(name));
        return hits.length === 1 && hits[0][1] === 1;   // ambiguous/unknown → not an operand
      };
      const LN_OPERAND_FLAGS = new Set(["-t", "--target-directory", "-S", "--suffix"]);
      let expectOperand = false;
      let expectTarget = false;
      let targetDir = null;
      let endOpts = false;
      const positionals = [];
      for (const w of words) {
        if (expectTarget) { targetDir = w; expectTarget = false; continue; }
        if (expectOperand) { expectOperand = false; continue; }
        if (!endOpts && w === "--") { endOpts = true; continue; }
        if (!endOpts && isFlag(w) && w !== "-") {
          if (v === "ln" && (w === "-t" || w === "--target-directory")) { expectTarget = true; continue; }
          if (v === "ln" && w.startsWith("--target-directory=")) { targetDir = w.slice("--target-directory=".length); continue; }
          if (v === "ln" && !w.startsWith("--") && /^-[a-zA-Z]/.test(w)) {
            // Same left-to-right cluster parse as cp/mv/install: `S` consumes
            // the rest as an attached suffix, so `-S.tmp` is not `-t mp`.
            const cluster = w.slice(1);
            for (let ci = 0; ci < cluster.length; ci++) {
              const ch = cluster[ci];
              if (ch === "t") {
                const rest = cluster.slice(ci + 1);
                if (rest) targetDir = rest; else expectTarget = true;
                break;
              }
              if (ch === "S") {
                if (ci + 1 >= cluster.length) expectOperand = true;
                break;
              }
            }
            continue;
          }
          if (v === "rsync" ? isRsyncOperand(w) : LN_OPERAND_FLAGS.has(w)) {
            if (!w.includes("=")) expectOperand = true;   // `--flag=value` is self-delimiting
            continue;
          }
          continue;
        }
        positionals.push(w);
      }
      if (targetDir) {
        emitDst(targetDir, positionals, false);
      } else if (positionals.length > 0) {
        const last = positionals[positionals.length - 1];
        if (v === "ln" && positionals.length === 1) {
          // `ln TARGET` (2nd form) creates CWD/basename(TARGET) (#625 A1).
          emitDst(siteCwd, [last], false);
        } else if (v === "rsync" && positionals.length === 1) {
          // Single-operand rsync is a LIST-only invocation — writes nothing
          // (#625 cycle-4 B5).
        } else {
          emitDst(last, positionals.slice(0, -1), false);
        }
      }
      return out;
    }
    if (v === "dd") {
      for (const w of words) if (w.startsWith("of=")) out.push(w.slice(3));
      return out;
    }
    if (v === "sort") {
      // `sort -o FILE` writes FILE (attached `-oFILE`/`--output=FILE` or the
      // next word). A plain `sort file` is read-only → no target. `-o` may be
      // BUNDLED behind other letters (`sort -ro out`) (#625 review A2), so the
      // short cluster is scanned LEFT TO RIGHT: `t`/`k`/`S`/`T` take an
      // operand, which may be attached (`-to` means separator `o`) — those are
      // consumed, never re-read as `-o` (#625 cycle-2 P2). Long options accept
      // any UNAMBIGUOUS prefix (getopt_long does) — `--out=FILE` IS `--output`
      // (#625 cycle-3 B1).
      const SORT_LONG = [
        ["--output", "out"], ["--field-separator", "op"], ["--key", "op"], ["--buffer-size", "op"],
        ["--temporary-directory", "op"], ["--random-source", "op"], ["--compress-program", "op"],
        ["--files0-from", "op"], ["--batch-size", "op"], ["--sort", "op"], ["--parallel", "op"],
        ["--check", "none"], ["--debug", "none"], ["--help", "none"], ["--version", "none"],
        ["--ignore-leading-blanks", "none"], ["--dictionary-order", "none"], ["--ignore-case", "none"],
        ["--general-numeric-sort", "none"], ["--ignore-nonprinting", "none"], ["--month-sort", "none"],
        ["--human-numeric-sort", "none"], ["--version-sort", "none"], ["--numeric-sort", "none"],
        ["--random-sort", "none"], ["--reverse", "none"], ["--stable", "none"], ["--unique", "none"],
        ["--merge", "none"], ["--zero-terminated", "none"],
      ];
      const resolveLong = (name) => {
        const hits = SORT_LONG.filter(([nm]) => nm.slice(2).startsWith(name));
        return hits.length === 1 ? hits[0][1] : null;   // ambiguous/unknown → non-write
      };
      let outputNext = false;
      let skipNext = false;
      let endOpts = false;
      for (const w of words) {
        if (skipNext) { skipNext = false; continue; }
        if (outputNext) { out.push(w); outputNext = false; continue; }
        if (!endOpts && w === "--") { endOpts = true; continue; }
        if (!endOpts && w === "-o") { outputNext = true; continue; }
        if (!endOpts && w.startsWith("--")) {
          const body = w.slice(2);
          const eq = body.indexOf("=");
          const kind = resolveLong(eq === -1 ? body : body.slice(0, eq));
          if (kind === "out") {
            if (eq === -1) outputNext = true; else out.push(body.slice(eq + 1));
          } else if (kind === "op" && eq === -1) skipNext = true;
          continue;
        }
        if (!endOpts && w.startsWith("-") && w.length > 1) {
          const cluster = w.slice(1);
          for (let ci = 0; ci < cluster.length; ci++) {
            const ch = cluster[ci];
            if (ch === "o") {
              const rest = cluster.slice(ci + 1);
              if (rest) out.push(rest); else outputNext = true;
              break;
            }
            if (ch === "t" || ch === "k" || ch === "S" || ch === "T") {
              if (ci + 1 >= cluster.length) skipNext = true;
              break;
            }
          }
        }
      }
      return out;
    }
    if (v === "sponge" || v === "ed" || v === "ex" || v === "vi" || v === "vim" || v === "nvi") {
      // `sponge FILE...` writes every FILE; `ed`/`ex`/`vi`/`vim` edit their
      // file operands in place. EVERY positional is a candidate (vim/ex write
      // the FIRST of several files, so last-only misses them) (#625 cycle-2
      // P1). `+cmd` tokens are ex commands, not files, and a bare `-` is
      // stdin/stdout — neither is a candidate. Option operands (`-c/--command`
      // for ed/ex; `-c/--cmd`, `-u`, `-S`, `-i`, `-T`, `-W` for the vi family)
      // are consumed so they are never mistaken for files.
      let expectOperand = false;
      let endOpts = false;
      const positionals = [];
      for (const w of words) {
        if (expectOperand) { expectOperand = false; continue; }
        if (!endOpts && w === "--") { endOpts = true; continue; }
        if (!endOpts && isFlag(w) && w !== "-") {
          if ((v === "ed" || v === "ex") && (w === "-c" || w === "--command")) { expectOperand = true; continue; }
          if ((v === "vi" || v === "vim" || v === "nvi") &&
              (w === "-c" || w === "--cmd" || w === "-u" || w === "--rcfile" || w === "-S" ||
               w === "--session" || w === "-i" || w === "-T" || w === "-W" ||
               w === "--startuptime" || w === "--servername")) { expectOperand = true; continue; }
          continue;
        }
        if (w === "-" || w.startsWith("+")) continue;   // stdin / ex command
        positionals.push(w);
      }
      for (const f of positionals) emitDst(f, [], false);
      return out;
    }
    return out;
  };
  const applyPending = () => {
    const fr = f();
    if (fr.pending) { fr.cwd = fr.pending; fr.pending = null; }
    pipeBase[pipeBase.length - 1] = fr.cwd;   // &&/;/newline: pipes start here
  };
  const updateAsyncBase = () => { asyncBase[asyncBase.length - 1] = f().cwd; };
  const lineEndOf = (i0) => { const e = s.indexOf("\n", i0); return e === -1 ? n : e; };
  // cycle-11: real bash `bash <<'EOF' x.sh` — a FILE POSITIONAL (no -s) on
  // the heredoc header is the SCRIPT; the body is stdin DATA. Returns the
  // first non-flag word on the header line after the opener (skipping extra
  // redirects fd>/< / >& / <& / >> …) — or null.
  const heredocHeaderPositional = (i0) => {
    if (s[i0 + 2] === "<") return null;      // <<< here-string: no header line
    const end = lineEndOf(i0);
    let p = i0 + 2;
    while (p < end && !/\s/.test(s[p])) p++; // past the delimiter token
    while (p < end) {
      p = skipWs(p);
      if (p >= end) break;
      const c = s[p];
      if (c === ">" || c === "<" || c === "&" || (c >= "0" && c <= "9")) {
        let q = p;
        while (q < end && /[<>&|0-9-]/.test(s[q])) q++; // operator run
        while (q < end && !/\s/.test(s[q])) q++;        // operand word
        p = q;
        continue;
      }
      const w = readWord(p);
      if (w.w === "") break;
      if (w.w.startsWith("-")) { p = w.k; continue; }
      return w.w;
    }
    return null;
  };
  // Heredoc-body region for the delims on the CURRENT header line: returns
  // [regionStart, regionEnd) covering the bodies in order, or null for a
  // here-string `<<<` (data, not a heredoc). The HEADER remainder (code after
  // the marker on the same line — `cat <<EOF && echo x > f`) is NOT in the
  // region: the walker scans it and jumps only [regionStart, regionEnd).
  // Multi-heredoc bodies (`cat <<A <<B`) are searched FORWARD from the
  // previous body's end (no double-count). Unterminated → [start, n)
  // (bash waits for the delim — trailing text is body, never executed code).
  const heredocRegion = (i0) => {
    if (s[i0 + 2] === "<") return null; // <<< here-string
    // arithmetic-context guard (cycle-15 D1, cycle-16 VGATE X1-X5): inside
    // (( … )) / $(( … )) a `<<` is the SHIFT operator, never a heredoc —
    // treating it as one swallowed the rest of the command. The scan is
    // SAME-LINE and quote/comment-aware: only a `((` in CODE position before
    // i0 (no `))` closer between, not inside '…'/"…" spans or after a `#`
    // comment) counts — `echo '(( n' && cat <<EOF` must NOT be suppressed.
    {
      let j = i0 - 1;
      const nl = s.lastIndexOf("\n", i0);
      while (j > nl) {
        const c = s[j];
        if (c === "'") {
          j--;
          while (j > nl && s[j] !== "'") j--; // skip the sq span
          j--;
          continue;
        }
        if (c === '"') {
          j--;
          while (j > nl) {
            if (s[j] === "\\") j -= 2;
            else if (s[j] === '"') break;
            else j--;
          }
          j--;
          continue;
        }
        if (c === "#" && (j === 0 || /[\s;&|(\n]/.test(s[j - 1]))) break; // comment: no arith before it on this line
        if (c === ")" && s[j - 1] === ")") break; // a )) closer between → not inside arithmetic
        if (c === "(" && s[j - 1] === "(") return null; // (( still open in code position
        j--;
      }
    }
    const le = lineEndOf(i0);
    const line = s.slice(i0, le);
    const delims = [];
    // <<- flag captured so terminator lines may strip LEADING TABS ONLY
    // (bash: plain << needs an EXACT column-0 delimiter line — any leading
    // ws or trailing padding keeps the body open — cycle-12 finding).
    // Quote-aware scan: a `<<` inside "…"/'…' prose is NOT a heredoc marker
    // (cycle-13 P1 — `cat <<EOF && echo "pass <<token"` must not add a bogus
    // delimiter that swallows the region to EOF).
    const qre = /<<(-)?[ \t]*(?:"([^"]*)"|'([^']*)'|([^|&;()<>\s'"]+))/;
    let p2q = 0;
    let sq = false, dq = false;
    while (p2q < line.length) {
      const c = line[p2q];
      if (sq) { if (c === "'") sq = false; p2q++; continue; }
      if (dq) { if (c === "\\") p2q += 2; else { if (c === '"') dq = false; p2q++; } continue; }
      if (c === "'") { sq = true; p2q++; continue; }
      if (c === '"') { dq = true; p2q++; continue; }
      if (c === "<" && line[p2q + 1] === "<") {
        const mq = qre.exec(line.slice(p2q));
        if (mq) {
          // cycle-16 P1: a `<<` whose delimiter is all-digits or is followed
          // by `))` (after optional ws) is an ARITHMETIC SHIFT, not a heredoc
          // (`$((1 << 2))`, `(( a << b ))`, incl. multi-line forms where the
          // (( opener sits on an earlier line and the same-line guard can't
          // see it). Rejecting keeps the rest of the command from being
          // swallowed as an unterminated "body".
          const dqEnd = p2q + mq[0].length;
          let dx = dqEnd;
          while (dx < line.length && (line[dx] === " " || line[dx] === "\t")) dx++;
          if ((line[dx] === ")" && line[dx + 1] === ")") || (mq[4] !== undefined && /^[0-9]+$/.test(mq[4]))) return null;
          delims.push({ d: mq[2] ?? mq[3] ?? mq[4], tabStrip: !!mq[1] });
          p2q = dqEnd;
          continue;
        }
      }
      p2q++;
    }
    if (delims.length === 0) return null;
    let searchFrom = le === n ? n : le + 1;
    let regionStart = searchFrom;
    let regionEnd = searchFrom;
    for (const { d, tabStrip } of delims.slice(0, 64)) {
      let lineStart = searchFrom;
      let found = false;
      while (lineStart <= n) {
        const le2 = s.indexOf("\n", lineStart);
        const leAt = le2 === -1 ? n : le2;
        const cand = s.slice(lineStart, leAt);
        const norm = tabStrip ? cand.replace(/^\t+/, "") : cand;
        if (norm === d) { regionEnd = leAt; found = true; break; }
        if (le2 === -1) break;
        lineStart = le2 + 1;
      }
      if (!found) {
        // cycle-17 residual: an arithmetic shift whose `))` closer sits on a
        // LATER line than the `<<` (`(( acc = base\n<< bits\n)) && echo x >
        // f` — delimiter is a plain word, closer not adjacent). Before
        // committing to an unterminated swallow, peek the next few body lines
        // for a line that opens with `))` (the arith closer).
        let pk = searchFrom;
        for (let tries = 0; tries < 3 && pk <= n; tries++) {
          const pl2 = s.indexOf("\n", pk);
          const plAt = pl2 === -1 ? n : pl2;
          if (/^\s*\)\)/.test(s.slice(pk, plAt))) return null;
          if (pl2 === -1) break;
          pk = pl2 + 1;
        }
        return [regionStart, n];
      }
      searchFrom = regionEnd < n ? regionEnd + 1 : n;
    }
    return [regionStart, regionEnd];
  };
  let i = 0;
  while (i < n) {
    // jump an active heredoc-body region (header remainder was walked before)
    if (i >= skipStart && skipStart !== -1) { i = skipEnd; skipStart = -1; skipEnd = -1; continue; }
    const ch = s[i];
    if (ch === "\\") {
      if (i + 1 < n && /[A-Za-z0-9_./~-]/.test(s[i + 1])) { forceCmdNext = true; i++; continue; } // \\cd ≡ cd — drop the escape
      i += 2; continue; // \\> etc — escaped non-word stays inert
    }
    if (/\s/.test(ch)) { if (ch === "\n") { applyPending(); updateAsyncBase(); segHadWord = false; spawnerPending = null; spawnerOperandNext = false; envSawAssign = false; } i++; continue; }
    if (ch === "#" && (i === 0 || /[\s;&|(\n]/.test(s[i - 1]))) { while (i < n && s[i] !== "\n") i++; continue; }
    if (ch === "(") {
      if (casePattern) {
        // cycle-43 P2-1: a `(` in the PATTERN phase is case syntax (paren-led
        // arm `(a)`, extglob `@(a|b)`) — NOT a subshell. Pushing a frame here
        // leaks it (the pattern arm's `)` is a non-pop), so a REAL enclosing
        // subshell's `)` later pops the wrong frame and every subsequent write
        // resolves from a stale cwd.
        i++; continue;
      }
      applyPending();
      frames.push({ cwd: f().cwd, pending: null, forkCwd: f().forkCwd, forkAlts: f().forkAlts ? [...f().forkAlts] : [] }); // cycle-40 F2: a subshell inherits the parent's case-fork realities
      pipeBase.push(f().cwd); asyncBase.push(f().cwd); updateAsyncBase();
      segHadWord = false; spawnerPending = null; spawnerOperandNext = false; envSawAssign = false;
      dirStackSnapshots.push(dirStack.slice());
      i++; continue;
    }
    if (ch === ")") {
      // cycle-36 P2-1/P2-2: a `)` closes an ARM only while in the PATTERN phase
      // (`case x in a|b) …`). A `)` in the arm BODY is a normal subshell close —
      // the old caseDepth>0 blanket gate leaked the frame (cwd stuck inside the
      // subshell → later writes attributed to the wrong dir → missed blocks).
      if (casePattern) {
        casePattern = false;
        segHadWord = false; spawnerPending = null; spawnerOperandNext = false; envSawAssign = false; // the arm body is a NEW command (cycle-26 P2-1)
        if (caseCwdStack.length > 0) {
          // cycle-37 F2: each arm evaluates from the pre-case cwd — an earlier
          // arm's cd must not bleed into this arm's resolution.
          const cst = caseCwdStack[caseCwdStack.length - 1];
          const preTerm = f().cwd;
          f().cwd = cst.cwd;
          f().pending = null;
          // cycle-38 P1: this arm ended deeper than the case entry — remember
          // its terminal cwd (a MATCHED arm's cd persists past esac in bash).
          if (preTerm !== cst.cwd) { if (!cst.terms) cst.terms = []; if (!cst.terms.includes(preTerm)) cst.terms.push(preTerm); }
        }
        i++; continue;                     // case-pattern terminator (y) — NOT a subshell close
      }
      if (frames.length > 1) { frames.pop(); pipeBase.pop(); asyncBase.pop(); }
      applyPending(); updateAsyncBase();
      segHadWord = false; spawnerPending = null; spawnerOperandNext = false; envSawAssign = false;
      if (dirStackSnapshots.length > 0) dirStack = dirStackSnapshots.pop(); // subshell copy semantics
      i++; continue;
    }
    if (ch === "&") {
      if (s[i + 1] === "&") { applyPending(); segHadWord = false; spawnerPending = null; spawnerOperandNext = false; envSawAssign = false; i += 2; continue; } // && continuation
      if (s[i + 1] === ">") {
        // &> / &>> — redirect-ALL (stdout+stderr), NOT background-&: the
        // operand belongs to the FOLLOWING command at the CURRENT cwd
        // (cd docs && echo hi &> f resolves docs/f — cycle-8 P2)
        let p2 = i + 2;
        if (s[p2] === ">") p2++;
        p2 = skipWs(p2);
        const operand = readWord(p2);
        if (operand.w && !/^-?[0-9]*$/.test(operand.w)) { const _rt1 = { raw: operand.w, cwd: f().cwd }; redirs.push(_rt1, ...forkTwins(_rt1)); }
        i = operand.k;
        continue;
      }
      f().pending = null;              // a cd in the async list dies with the subshell
      f().cwd = asyncB();              // the WHOLE async list ran at the segment start
      pipeBase[pipeBase.length - 1] = f().cwd;
      updateAsyncBase();
      segHadWord = false; spawnerPending = null; spawnerOperandNext = false; envSawAssign = false;
      i++;
      continue;
    }
    if (ch === "|") {
      if (s[i + 1] === "|") { applyPending(); segHadWord = false; spawnerPending = null; spawnerOperandNext = false; envSawAssign = false; i += 2; continue; } // || continuation
      f().pending = null;
      f().cwd = pipeB();               // pipe segments from the pipe-list start
      segHadWord = false; spawnerPending = null; spawnerOperandNext = false; envSawAssign = false;
      i++;
      continue;
    }
    if (ch === ";") {
      if (s[i + 1] === ";") {
        // `;;` ends an arm — the next arm's words are PATTERNS again (cycle-36
        // P2-1); `;;&` (keep matching) is the same; `;&` (fallthrough body) is
        // deliberately NOT pattern-phase (the next arm body runs commands).
        if (caseDepth > 0 && s[i + 2] !== "&") casePattern = true;
        applyPending(); updateAsyncBase(); segHadWord = false; spawnerPending = null; spawnerOperandNext = false; envSawAssign = false;
        i += 2; continue;
      }
      applyPending(); updateAsyncBase(); segHadWord = false; spawnerPending = null; spawnerOperandNext = false; envSawAssign = false; i++; continue;
    }
    // redirects (incl. fd-prefixed)
    if (ch === ">" || (ch >= "0" && ch <= "9")) {
      let k = i;
      while (k < n && s[k] >= "0" && s[k] <= "9") k++;
      const fdRun = s.slice(i, k);
      if (fdRun && s[k] !== ">" && s[k] !== "<") {
        // plain digits, NOT an fd: if a spawner flag operand is pending the
        // number IS that operand (nice -n 5 / sudo -u 501) — consume it so the
        // next real word dispatches as the command (cycle-32 P1-3); otherwise
        // the number is data.
        if (spawnerOperandNext) spawnerOperandNext = false;
        i = k; continue;
      }
      // fd-prefixed INPUT (`0<f`, `1<f`, `2<f`) is a READ, never a write — hand
      // it to the `<` branch. Treating `0<file` as `>file` false-blocked
      // read-only stdin redirects (#625 cycle-3 B3).
      if (s[k] === "<") { i = k; continue; }
      if (s[k] === ">" && s[k + 1] === "&") {
        // `N>&M` / `N>&-` is a dup/close (no file). Legacy `>&file` (target not
        // an fd) DOES write the file, so keep it.
        const tgt = readWord(skipWs(k + 2));
        if (/^[0-9-]*$/.test(tgt.w)) { i = tgt.k; continue; }
        const _rtd = { raw: tgt.w, cwd: f().cwd }; redirs.push(_rtd, ...forkTwins(_rtd));
        i = tgt.k; continue;
      }
      // `N>f` / `N>>f` / `N>|f` opens f with O_TRUNC for ANY fd — a tracked-file
      // mutation even when no content is written through it (`echo x 3>f 1>&3`,
      // `2>f` truncation) (#625 cycle-3 B2). The operand is emitted; `/dev/*`
      // and non-tracked files are filtered downstream, so the match is inert.
      let p = k + 1;
      let op = ">";
      const n1 = s[k + 1];
      if (n1 === ">" || n1 === "|") { op += n1; p = k + 2; }
      p = skipWs(p);
      const operand = readWord(p);
      const _rt2 = { raw: operand.w, cwd: f().cwd }; redirs.push(_rt2, ...forkTwins(_rt2));        // pre-cd (pending not applied)
      i = operand.k;
      continue;
    }
    if (ch === "<") {
      if (s[i + 1] === "<") {
        if (s[i + 2] === "<") {
          // <<< here-string: the content is DATA (and may contain a python-ish
          // open()/redirect-looking text) — skip the operand, keep scanning
          let k = i + 3;
          k = skipWs(k);
          i = readWord(k).k;
          continue;
        }
        if (i >= skipStart && skipStart !== -1) {
          // a SECOND `<<` on the SAME header line (cat <<A <<B): its body is
          // already inside the active region — skip this delim token only
          let k = i + 2;
          if (s[k] === "-") k++;
          k = skipWs(k);
          const qd = s[k] === "'" || s[k] === '"' ? s[k] : null;
          if (qd) { k++; while (k < n && s[k] !== qd) k++; k++; }
          else k = readWord(k).k;
          i = k;
          continue;
        }
        const rg = heredocRegion(i);
        if (rg) {
          // walk the header remainder first; jump the body [start, end) at the
          // top of the loop (cat <<EOF && echo x > f — echo runs after cat
          // finishes reading the body → its write must still be detected)
          skipStart = rg[0]; skipEnd = rg[1];
          i += 2;
          continue;
        }
        i += 2;
        continue;
      }
      let k = i + 1;
      if (s[k] === "<") k++;                                // <<< here-string
      k = skipWs(k);
      i = readWord(k).k;
      continue;
    }
    if (ch === "'" || ch === '"') {
      const qq = ch;
      // cycle-30 P2-2: a FULLY-QUOTED word at a TRUE command position
      // ("tee" f.md / 'bash' -c '...' / "cd" /tmp ≡ the unquoted word —
      // bash strips quotes before tokenizing). Prose quotes after a command
      // word (echo "tee x") keep the span-skip below.
      const qPrev = i === 0 ? undefined : s[i - 1];
      const qAtCmd = !segHadWord && (i === 0 || (qPrev !== undefined && /[;&|({ \t\n]/.test(qPrev)));
      let k = i + 1;
      let wholeWord = false;
      if (qAtCmd) {
        while (k < n && s[k] !== qq) { if (qq === '"' && s[k] === "\\") k += 2; else k++; }
        const afterQ = k < n ? s[k + 1] : undefined;
        wholeWord = k >= n || afterQ === undefined || /\s|[;&|()\n<>]/.test(afterQ);
        if (wholeWord) {
          // fall through to the readWord dispatch below (readWord strips the
          // quotes) — do NOT consume the span as data
        } else {
          k = i + 1;
          while (k < n && s[k] !== qq) { if (qq === '"' && s[k] === "\\") k++; k++; }
          i = k + 1;
          continue;
        }
      }
      if (!wholeWord && !qAtCmd) {
        k = i + 1;
        while (k < n && s[k] !== qq) {
          // backslash escapes ONLY inside DOUBLE quotes (bash single quotes
          // have no escape — `'a\\'` closes at the quote after the backslash;
          // treating \ as an escape swallowed to the next quote — cycle-14
          // P2-2: `echo 'C:\\' && echo z > tracked.md` was missed).
          if (qq === '"' && s[k] === "\\") k++;
          k++;
        }
        i = k + 1;
        continue;
      }
    }    const w0 = readWord(i);
    const wstart = i;
    i = w0.k;
    const prev = s[wstart - 1];
    const atCmdPos = forceCmdNext || wstart === 0 || (prev !== undefined && /[;&|()\s\n]/.test(prev)); // ) = case-arm start (cycle-26 P2-1)
    forceCmdNext = false;
    if (!atCmdPos || w0.w === "") continue;
    const cwd = f().cwd;
    // `case x in` — only the CASE's own `in` (preceded by its value word)
    // opens the PATTERN phase. cycle-36 P2-1 set this on ANY `in` with
    // caseDepth>0 — a `for i in …` inside an arm wrongly flipped to pattern
    // (cycle-37 F1: loop-body commands suppressed → missed writes).
    if (w0.w === "in" && caseDepth > 0 && (caseValConsumed || caseValPending)) {
      casePattern = true;
      caseValConsumed = false;
      caseValPending = false;
      caseCwdStack.push({ cwd: f().cwd, terms: undefined }); // cycle-37 F2: arms evaluate from this cwd
      continue;
    }
    if (caseValPending) {
      // cycle-37 F3: the cased-VALUE word (`case ./run.sh in …`) is never
      // executed by bash — consume it without dispatching (no direct-exec /
      // tee / cd handlers may fire on it). `in` itself is handled above (a
      // quote-span may have swallowed the value first).
      caseValPending = false;
      caseValConsumed = true;
      continue;
    }
    // ── case PATTERN phase (cycle-36 P2-1): between `case x in` and an arm's
    // `)` the words are PATTERNS — bash never executes them. A `|`/`;;`/newline
    // resets segHadWord, so without this gate `case x in a|./release.sh|b)`
    // would dispatch the pattern word as a command (false block). Only case/
    // esac pass through during the phase.
    if (casePattern) {
      // cycle-41 P2: ONLY a BARE esac terminates (quoted "esac"/'esac' is a
      // valid pattern literal — `case $x in "esac") cd sub;; esac` — and bash
      // rejects a bare esac as a pattern). Quote chars inside the raw word
      // span ⇒ pattern literal ⇒ skip (mirror of the cycle-40 F1 `case` fix).
      const rawW = s.slice(wstart, w0.k);
      // cycle-42 P2: bash reserves `esac` POSITIONALLY — only at a
      // pattern-list start (after `in`/`;;`) is it the terminator. After `|`
      // or `(` it is a LIVE literal pattern member (`case $X in y|esac)`
      // matches X=esac) — closing early reattributes the arm cd as
      // unconditional and drops the entry reality.
      let bk = wstart - 1;
      while (bk >= 0 && /\s/.test(s[bk])) bk--;
      const prevSig = bk >= 0 ? s[bk] : "";
      if (w0.w === "esac" && !/[`'"]/.test(rawW) && prevSig !== "|" && prevSig !== "(") {
        caseDepth = Math.max(0, caseDepth - 1);
        casePattern = false;
        caseValConsumed = false; caseValPending = false;
        if (caseCwdStack.length > 0) {
          const cso = caseCwdStack.pop();
          // cycle-38 P1: the LAST arm's terminal is only visible here (no next
          // arm to peek-restore it) — and its trailing cd may still be pending
          // (an arm ending at esac without `;;`).
          applyPending();
          const terms = cso.terms || [];
          const lastArmT = f().cwd;
          if (lastArmT !== cso.cwd && !terms.includes(lastArmT)) terms.push(lastArmT);
          if (terms.length > 0) {
            // a MATCHED case arm's cd persists past esac — resume at the last
            // cd-ing arm's terminal; the OTHER possible bases (the case entry +
            // earlier arms' terminals) are forkAlts so direct writes also emit
            // entry/arm twins (union over every arm-matched reality — bash runs
            // exactly one arm, the value is unknown).
            f().cwd = terms[terms.length - 1];
            if (!f().forkCwd) {
              f().forkCwd = terms[terms.length - 1];
              f().forkAlts = [cso.cwd, ...terms.slice(0, -1)].filter((x) => x !== f().forkCwd);
              f().forkAlts = [...new Set(f().forkAlts)].slice(0, 64);
            } else {
              // cycle-39 F1: a LATER cd-ing case while a fork is active — its
              // entry (the pre-case primary cwd) is another real outcome
              // (later case unmatched) — union it into the alts.
              let alts2 = [...f().forkAlts, cso.cwd];
              // cycle-40 F3: the later case's value is ORTHOGONAL to the
              // earlier fork — its cd-ing arm also runs from EVERY earlier
              // base. Derive each alt's matched-arm terminal via the arm's
              // relative step from the case entry.
              const relT = relative(cso.cwd, terms[terms.length - 1]);
              if (relT && relT !== ".") {
                for (const b of f().forkAlts) {
                  const nb = resolve(b, relT);
                  if (existsSync(nb)) alts2.push(nb);
                }
              }
              f().forkAlts = [...new Set(alts2.filter((x) => x !== f().cwd))].slice(0, 64);
            }
          } else f().cwd = cso.cwd;
        }
      }
      // cycle-40 F1: a pattern-phase word `case` (case $x in case)) is a
      // PATTERN literal — never opens a nested case (leaking caseDepth would
      // disable the caseDepth===0 alt-shift gate forever).
      continue;
    }
    // ── simple-command arg-position gate (cycle-22 P1) ──────────────────────
    // Only the FIRST word of a simple command (optionally after redirects /
    // env-assignment prefixes / a spawner prefix) may be cd/python/tee/an
    // interpreter/exec/eval/./source. A special word AFTER a plain command
    // word is an ARG (`grep tee f`, `echo bash -c '…'`, `echo cd /tmp && …`).
    if (spawnerOperandNext) { spawnerOperandNext = false; continue; }
    if (spawnerPending !== null) {
      if (w0.w.startsWith("-") && !(spawnerPending === "env" && envSawAssign)) {
        // cycle-34 P2-2: env option parsing ENDS at the first name=value
        // operand — `env FOO=bar -S 'tee x.md'` treats -S as the utility name
        // (rc=127, nothing runs). Flags after an env assignment are the command.
        const opd = SPAWNER_FLAG_OPERANDS[spawnerPending];
        if (opd && opd.includes(w0.w) && !(spawnerPending === "env" && (w0.w === "-S" || w0.w === "--split-string"))) spawnerOperandNext = true;
        // env -S 'cmd string': env SPLITS the string and APPENDS every trailing
        // operand — one exec line (cycle-33 P2-1). Capture the full remainder
        // of the simple command (to segment end) verbatim and recurse it as one
        // inline payload: `env -S 'tee a.md' b.md` → a.md+b.md,
        // `env -S 'sh -c' 'echo hi > b.md'` → b.md.
        if (spawnerPending === "env" && (w0.w === "-S" || w0.w === "--split-string")) {
          let kS = skipWs(w0.k);
          let dq = null;
          let jS = kS;
          let stripped = "";
          while (jS < n && jS - kS < 4096) {
            const cS = s[jS];
            if (dq === null && (cS === "\n" || cS === ";" || cS === "&")) break;
            if (dq !== null && cS === "\\") { stripped += s[jS + 1] ?? ""; jS += 2; continue; }
            if (dq === null && (cS === "'" || cS === '"')) { dq = cS; jS++; continue; }
            if (dq !== null && cS === dq) { dq = null; jS++; continue; }
            stripped += cS;
            jS++;
          }
          const stp = stripped.trim();
          // cycle-34 P2-1: env does NOT interpret shell operators inside the -S
          // string — `env -S 'echo hi > f.md'` prints "hi > f.md" and writes
          // NOTHING (operators are literal argv). Only when the -S command is a
          // SHELL with -c do the operators become real code. So: drop
          // whitespace-delimited operator tokens for non-shell payloads.
          const isShellC = /^(bash|sh|zsh|dash|ksh|ash|mksh|busybox)\b/.test(stp) && /(^|\s)-c(\s|$)/.test(stp);
          const payload = isShellC
            ? stp
            : stp.replace(/(?:^|\s+)(?:>>|<<|&&|\|\||[><|&;()])+(?=\s|$)/g, " ").trim();
          if (payload) { const _ip1 = { payload, cwd }; inlinePays.push(_ip1, ...forkTwins(_ip1)); }
          spawnerPending = null;
          spawnerOperandNext = false;
          i = jS;      // let the loop re-handle the separator at jS
          continue;
        }
        continue;
      }
      if (/^[A-Za-z_][A-Za-z0-9_]*=/.test(w0.w)) {
        // cycle-34 P2-2: for env, an assignment ends option parsing.
        if (spawnerPending === "env") envSawAssign = true;
        continue; // spawner env prefix
      }
      // cycle-32 P1-1: a CHAINED spawner (env env tee, command exec tee,
      // sudo env tee, builtin exec tee) re-pends — the next real word is the
      // command.
      const wBase3 = w0.w.lastIndexOf("/") >= 0 ? w0.w.slice(w0.w.lastIndexOf("/") + 1) : w0.w;
      if (SPAWNER_WORDS.has(wBase3)) { spawnerPending = wBase3; envSawAssign = false; continue; }
      spawnerPending = null; envSawAssign = false; // the first real word IS the command
      segHadWord = true;
    } else if (/^[A-Za-z_][A-Za-z0-9_]*=/.test(w0.w)) {
      continue;                         // assignment prefix — next word is the command
    } else if (segHadWord) {
      continue;                         // an ARG of the current command — demote
    } else if (RESET_WORDS.has(w0.w)) {
      if (w0.w === "case") { caseDepth++; caseValPending = true; caseValConsumed = false; }
      else if (w0.w === "esac") {
        caseDepth = Math.max(0, caseDepth - 1);
        caseValConsumed = false; caseValPending = false;
        if (caseCwdStack.length > 0) {
          const cso = caseCwdStack.pop();
          // cycle-38 P1: the LAST arm's terminal is only visible here (no next
          // arm to peek-restore it) — and its trailing cd may still be pending
          // (an arm ending at esac without `;;`).
          applyPending();
          const terms = cso.terms || [];
          const lastArmT = f().cwd;
          if (lastArmT !== cso.cwd && !terms.includes(lastArmT)) terms.push(lastArmT);
          if (terms.length > 0) {
            // a MATCHED case arm's cd persists past esac — resume at the last
            // cd-ing arm's terminal; the OTHER possible bases (the case entry +
            // earlier arms' terminals) are forkAlts so direct writes also emit
            // entry/arm twins (union over every arm-matched reality — bash runs
            // exactly one arm, the value is unknown).
            f().cwd = terms[terms.length - 1];
            if (!f().forkCwd) {
              f().forkCwd = terms[terms.length - 1];
              f().forkAlts = [cso.cwd, ...terms.slice(0, -1)].filter((x) => x !== f().forkCwd);
              f().forkAlts = [...new Set(f().forkAlts)].slice(0, 64);
            } else {
              // cycle-39 F1: a LATER cd-ing case while a fork is active — its
              // entry (the pre-case primary cwd) is another real outcome
              // (later case unmatched) — union it into the alts.
              let alts2 = [...f().forkAlts, cso.cwd];
              // cycle-40 F3: the later case's value is ORTHOGONAL to the
              // earlier fork — its cd-ing arm also runs from EVERY earlier
              // base. Derive each alt's matched-arm terminal via the arm's
              // relative step from the case entry.
              const relT = relative(cso.cwd, terms[terms.length - 1]);
              if (relT && relT !== ".") {
                for (const b of f().forkAlts) {
                  const nb = resolve(b, relT);
                  if (existsSync(nb)) alts2.push(nb);
                }
              }
              f().forkAlts = [...new Set(alts2.filter((x) => x !== f().cwd))].slice(0, 64);
            }
          } else f().cwd = cso.cwd;
        }
      }
      continue;                         // { } then/do/! etc — the next word is the command
    } else {
      segHadWord = true;                // the command word (special or plain)
      const wBase2 = w0.w.lastIndexOf("/") >= 0 ? w0.w.slice(w0.w.lastIndexOf("/") + 1) : w0.w;
      if (SPAWNER_WORDS.has(wBase2)) { spawnerPending = wBase2; envSawAssign = false; continue; }
    }
    if (w0.w === "cd" || w0.w === "pushd") {
      const nxt = skipWs(i);
      const tgt = readWord(nxt);
      i = tgt.k;
      if (w0.w === "pushd") {
        // flag / +N / bare forms don't cd (conservative no-op) — only a dir operand
        if (!tgt.w || tgt.w.startsWith("-") || /^[+-][0-9]/.test(tgt.w)) { f().pending = null; continue; }
        dirStack.push(f().cwd);
      }
      if (tgt.w && tgt.w !== "~" && !tgt.w.startsWith("~/") && tgt.w !== "-") {
        const next = resolve(cwd, tgt.w);
        f().pending = existsSync(next) ? next : null;       // failed cd — unchanged
        const frcd = f();
        if (frcd.forkCwd && frcd.forkAlts.length && caseDepth === 0) {
          // cycle-38 P1: COMMON tail cds (outside any case arm) apply to every
          // arm-matched reality — shift the fork alts by the same relative
          // step. cycle-39 F1: a cd inside a LATER case's arm is conditional
          // (only the matched-arm reality takes it) — it must NOT shift the
          // alts, which represent realities that never ran that arm.
          frcd.forkAlts = [...new Set(frcd.forkAlts.map((b) => { const nx = resolve(b, tgt.w); return existsSync(nx) ? nx : b; }))].slice(0, 64);
        }
      } else f().pending = null;
      continue;
    }
    if (w0.w === "popd") {
      const tgt = readWord(skipWs(i));
      i = tgt.k;
      if (tgt.w && (tgt.w.startsWith("-") || /^[+-][0-9]/.test(tgt.w))) { continue; } // -n/+N: no cd
      const d = dirStack.pop();
      f().pending = d !== undefined && existsSync(d) ? d : null; // empty stack → bash no-op
      continue;
    }
    if (w0.w === "python" || w0.w.startsWith("python")) {
      // python interpreter extent for open()-attribution: a real python
      // heredoc (python3 - <<EOF — the incident shape) OR a -c payload OR the
      // end of the python's own segment (next &&/||/;/|/&/\n — NEVER past it,
      // so a later `echo open(...)` prose cannot be attributed to python).
      // ORDER matters: check -c FIRST (a quoted payload may itself contain
      // `<<` bit-shifts — `python3 -c 'x = 1 << 4'` — which must NOT parse as
      // a heredoc). The heredoc scan is quote-aware over the line AFTER the
      // python token's args (a `<<` inside a quoted arg is not a heredoc).
      let ext = n;
      let k0 = skipWs(i);
      const first = readWord(k0);
      let afterArgs = first.k;
      if (first.w === "-" ) {
        // python3 - <<EOF / python3 - script.py
        const nxt = skipWs(first.k);
        afterArgs = nxt;
      }
      if (first.w === "-c" || /^-[a-zA-Z]*c/.test(first.w)) {
        // -c payload (quoted) — extent = end of the payload, honoring \" escapes
        // in double quotes (cycle-26 P2-2: `python3 -c "a=\"v\"; open(\"f\",…)"`
        // truncated at the first escaped quote → opens after it were dropped).
        const k3 = skipWs(first.k);
        const q3 = s[k3];
        if (q3 === "'" || q3 === '"') {
          let kk = k3 + 1;
          while (kk < n && s[kk] !== q3) {
            if (q3 === '"' && s[kk] === "\\") kk += 2;
            else kk++;
          }
          ext = Math.min(n, kk + 1);
        } else {
          const pl = readWord(k3);
          ext = pl.k;
        }
      } else {
        // heredoc on the python's line (quote-aware)? python3 - <<EOF feeds
        // python's stdin — its body IS python code (open() there is real).
        const nl = s.indexOf("\n", i);
        const lineEndAt = nl === -1 ? n : nl;
        let hm = null;
        {
          let scan = i;
          let qq = null;
          while (scan < lineEndAt && !hm) {
            const c2 = s[scan];
            if (qq) { if (c2 === qq) qq = null; scan++; continue; }
            if (c2 === "'" || c2 === '"') { qq = c2; scan++; continue; }
            if (c2 === "<") {
              const m = /^<<(-)?[ \t]*(?:"([^"]*)"|'([^']*)'|([^|&;()<>\s'"]+))/.exec(s.slice(scan, lineEndAt));
              if (m && !(s[scan + 2] === "<")) { hm = m; break; }
            }
            scan++;
          }
        }
        if (hm) {
          const delim = hm[2] ?? hm[3] ?? hm[4];
          const tabStrip = !!hm[1];
          const bodyStart = nl === -1 ? n : nl + 1;
          const lines = s.slice(bodyStart).split("\n");
          for (let li = 0; li < lines.length; li++) {
            const cand = lines[li];
            const norm = tabStrip ? cand.replace(/^\t+/, "") : cand;
            if (norm === delim) { ext = bodyStart + lines.slice(0, li + 1).join("\n").length; break; }
          }
        } else {
          // segment end: first of &&/||/;/|/&/\n after the python token
          const ends = [n];
          for (const sep of ["&&", "||", ";", "|", "&", "\n"]) {
            const idx = s.indexOf(sep, afterArgs);
            if (idx !== -1) ends.push(idx);
          }
          ext = Math.min(...ends);
        }
      }
      const _py = { idx: wstart, extentEnd: ext, cwd }; pythons.push(_py, ...forkTwins(_py));
      continue;
    }
    {
      // cycle-30 P2-1: path-qualified tee (/usr/bin/tee ≡ tee) — basename
      // normalization mirrors the interpreter branch below.
      const teeBase = w0.w.lastIndexOf("/") >= 0 ? w0.w.slice(w0.w.lastIndexOf("/") + 1) : w0.w;
      if (teeBase === "tee") { const _tt = { idx: wstart, end: w0.k, cwd }; tees.push(_tt, ...forkTwins(_tt)); continue; }
    }
    {
      // #625: in-place OVERWRITE verbs (sed -i / perl -pi / awk -i inplace /
      // cp / mv / install / truncate / dd of= / rsync / ln / sort -o / sponge /
      // ed / ex) — a write with NO primitive token, resolved as a target
      // through the SAME hub/tracked gate.
      const verbBase = w0.w.lastIndexOf("/") >= 0 ? w0.w.slice(w0.w.lastIndexOf("/") + 1) : w0.w;
      if (INPLACE_WRITE_VERBS.has(verbBase)) {
        for (const raw of verbTargets(verbBase, i, cwd)) {
          const _vb = { raw, cwd, via: verbBase };
          verbToks.push(_vb, ...forkTwins(_vb));
        }
        continue;
      }
    }
    {
      // interpreter scan condition (cycle-23 F1): bare OR path-qualified
      // shells (/usr/bin/bash ≡ bash), `source`/`.` (with their arg-position
      // sub-gate), and DIRECT-EXEC script paths (`./run.sh`, `/abs/x.sh` —
      // git-side extractScriptPath parity: /^\\.{0,2}\// is a script).
      const w0Base = w0.w.lastIndexOf("/") >= 0 ? w0.w.slice(w0.w.lastIndexOf("/") + 1) : w0.w;
      const isInterp = w0Base === "bash" || w0Base === "sh" || w0Base === "zsh" || w0Base === "dash" || w0Base === "ksh";
      const isDot = w0.w === "." || w0.w === "source";
      if (isDot)
      // source/. f run f in the CURRENT shell — a sourced file's tracked
      // writes must be gated like any script (cycle-18 P2-1 parity with the
      // git-side SHELL_INTERPRETERS list). BUT the ubiquitous `find .`, `git
      // add .`, `echo .` put a bare `.` in ARGUMENT position — only a `.`/
      // source at TRUE command position (start or after ;/&&/||/|/&/\n,
      // skipping whitespace) is the dot builtin (cycle-19 P2-1).
      if (w0.w === "." || w0.w === "source") {
        let b = wstart - 1;
        while (b >= 0 && (s[b] === " " || s[b] === "\t")) b--; // stop AT \n so it tests as a boundary (r23 X7)
        let trueCmdPos = b === -1 || "[;&|({\n}!".includes(s[b]);
        // env-assignment prefix: `VAR=val . f` / `A=1 B=2 . f` — the dot is
        // the assignment's command (cycle-21 P2-1).
        if (!trueCmdPos) {
          let bb = b;
          while (bb >= 0) {
            let e = bb;
            while (e >= 0 && /[A-Za-z0-9_=]/.test(s[e])) e--; // include `=` so VAR=val reads as one token
            const tok = s.slice(e + 1, bb + 1);
            if (tok === "" || !tok.includes("=")) break;
            trueCmdPos = true;
            bb = e;
            while (bb >= 0 && (s[bb] === " " || s[bb] === "\t")) bb--;
          }
        }
        if (!trueCmdPos) {
          // reserved words / prefix commands also put `.` at a true command
          // position: `{ . f; }`, `if x; then . f; fi`, `! . f`, `time . f`,
          // `fn() { . f; }`, `if . f; then` (cycle-20 P2-1 + cycle-21 P2-2).
          let wb = b;
          while (wb >= 0 && /[A-Za-z_]/.test(s[wb])) wb--;
          const prevWord = s.slice(wb + 1, b + 1);
          if (["then", "do", "else", "elif", "time", "fi", "done", "esac", "in", "function", "if", "while", "until", "case"].includes(prevWord)) trueCmdPos = true;
        }
        if (!trueCmdPos) { i = w0.k; continue; }
      }
      if (!(isInterp || isDot)) {
        // DIRECT-EXEC script path (`./run.sh`, `/abs/x.sh`) — surface as a
        // script token so the caller content-walks it (cycle-23 F1; git-side
        // extractScriptPath parity: a command word starting ./ ../ or / is a
        // script). Any other word falls through to the exec/eval handlers.
        if (/^\.{0,2}\//.test(w0.w)) { const _st1 = { path: w0.w, cwd, mode: "direct" }; scriptToks.push(_st1, ...forkTwins(_st1)); i = w0.k; continue; } // cycle-24 P2: exec-bit-gated by the caller
        // NOT an interpreter-shaped word — fall OUT of this handler to the
        // exec/eval checks below (no scan, no continue).
      } else {
      // skip leading FLAGS mirroring the git-side round-19/20 semantics:
      //  -c/--command (incl. single-dash letter runs CONTAINING c — bash
      //   parses -xc/-ec left to right and -c consumes the payload) → recurse
      //   the payload; --rcfile/--init-file/-O/-o take an OPERAND (skip 2);
      //   every OTHER -flag / --long-option is operand-less (skip 1 — so
      //   `bash -l /tmp/x.sh` and `bash --norc /tmp/x.sh` still reach the
      //   script path); REDIRECTS between the interpreter and a heredoc
      //   (`bash 2>/dev/null <<EOF`, `bash > log <<EOF`) are consumed like
      //   the top-level walker; `< f` DEFERS a stdin-script token (a LATER
      //   `<<` overrides it — last stdin wins → the heredoc body is CODE);
      //   `<<'EOF'` with no script path yet → body recursed as code and the
      //   HEADER REMAINDER walked (skipStart/skipEnd region); the first
      //   non-flag word is the script path.
      let k = skipWs(i);
      let done = false;
      let deferredStdin = null;
      let sawDashS = false;              // -s: stdin IS the program (args positional)
      while (!done && k < n) {
        k = skipWs(k);
        if (k >= n) break;
        const at = s[k];
        if (at === ">" || (at >= "0" && at <= "9")) {
          let rk = k;
          while (rk < n && /[0-9]/.test(s[rk])) rk++;
          const fdRun = s.slice(k, rk);           // fd prefix (bare/0/1 = content)
          const contentFd = fdRun === "" || fdRun === "0" || fdRun === "1";
          if (s[rk] === ">") {
            let p2 = rk + 1;
            if (s[p2] === ">" || s[p2] === "|") {
              p2++;
              p2 = skipWs(p2);
              const opnd = readWord(p2);
              if (contentFd && opnd.w && !/^-?[0-9]*$/.test(opnd.w)) { const _rt3 = { raw: opnd.w, cwd: f().cwd }; redirs.push(_rt3, ...forkTwins(_rt3)); }
              k = opnd.k;
              continue;
            }
            if (s[p2] === "&") {
              p2++;
              if (/[0-9-]/.test(s[p2])) {
                // fd dup/close (2>&1, >&-): NO file operand
                while (p2 < n && /[0-9-]/.test(s[p2])) p2++;
                k = p2;
                continue;
              }
              // >& file — legacy redirect-ALL: the operand IS a content write
              p2 = skipWs(p2);
              const opnd = readWord(p2);
              if (opnd.w && !/^-?[0-9]*$/.test(opnd.w)) { const _rt4 = { raw: opnd.w, cwd: f().cwd }; redirs.push(_rt4, ...forkTwins(_rt4)); }
              k = opnd.k;
              continue;
            }
            p2 = skipWs(p2);
            const opnd = readWord(p2);
            if (contentFd && opnd.w && !/^-?[0-9]*$/.test(opnd.w)) { const _rt3 = { raw: opnd.w, cwd: f().cwd }; redirs.push(_rt3, ...forkTwins(_rt3)); }
            k = opnd.k;
            continue;
          }
          if (s[rk] === "<") {
            const q2 = skipWs(rk + 1);
            if (s[q2] === "&") {
              // input-direction dup/close (2<&1, 2<&-, <&1, <&-): NO file
              // operand — resume after the dup target (cycle-8 P1 parity)
              let p2 = q2 + 1;
              while (p2 < n && /[0-9-]/.test(s[p2])) p2++;
              k = p2;
              continue;
            }
            k = readWord(q2).k;
            continue;
          }
          k = rk;
          continue;
        }
        if (at === "<") {
          // bare input dup/close (<&1, <&-, <&0): NO file operand
          if (s[k + 1] === "&") {
            let p2 = k + 2;
            while (p2 < n && /[0-9-]/.test(s[p2])) p2++;
            k = p2;
            continue;
          }
          // stdin redirect: bash < f / bash -s < f — the operand is the script
          if (s[k + 1] === "<") {
            // heredoc-fed interpreter. Cycle-11: with NO -s a file POSITIONAL
            // on the header (`bash <<'EOF' x.sh`) is the SCRIPT — the body is
            // stdin DATA; alone or with -s the body is the program.
            const hr = heredocRegion(k);
            if (hr) {
              const body = s.slice(hr[0], hr[1]);
              if (!sawDashS) {
                const hpos = heredocHeaderPositional(k);
                if (hpos) {
                  const _st2 = { path: hpos, cwd }; scriptToks.push(_st2, ...forkTwins(_st2)); // x.sh IS the program
                } else if (body.trim()) { const _ip2 = { payload: body, cwd }; inlinePays.push(_ip2, ...forkTwins(_ip2)); }
              } else if (body.trim()) { const _ip2 = { payload: body, cwd }; inlinePays.push(_ip2, ...forkTwins(_ip2)); }
              skipStart = hr[0]; skipEnd = hr[1];       // body jumped by the main loop
            }
            deferredStdin = null;                // heredoc overrides < f
            i = k + 2;                           // header remainder WALKED
            done = true;
            continue;
          }
          let k2 = k + 1;
          k2 = skipWs(k2);
          const sp = readWord(k2);
          deferredStdin = { path: sp.w };
          k = sp.k;
          continue;                              // a later << overrides; else EOF pushes it
        }
        const w1 = readWord(k);
        if (w1.w === "" ) { done = true; continue; }
        if (w1.w === "-c" || w1.w === "--command") {
          const k2 = skipWs(w1.k);
          const _arg = readWord(k2);
          const _ip3 = { payload: _arg.w, cwd }; inlinePays.push(_ip3, ...forkTwins(_ip3));
          i = _arg.k;
          done = true;
        } else if (/^-[a-zA-Z]+$/.test(w1.w) && w1.w.includes("c")) {
          // single-dash letter run containing c (bash -lc '…', sh -ec '…')
          const k2 = skipWs(w1.k);
          const _arg = readWord(k2);
          const _ip3 = { payload: _arg.w, cwd }; inlinePays.push(_ip3, ...forkTwins(_ip3));
          i = _arg.k;
          done = true;
        } else if (w1.w === "--rcfile" || w1.w === "--init-file" || w1.w === "-O" || w1.w === "-o") {
          const k2 = skipWs(w1.k);
          k = readWord(k2).k;                    // flag + operand
        } else if (w1.w.startsWith("-") && w1.w !== "-") {
          if (w1.w === "-s") sawDashS = true;    // bash -s: commands from stdin
          k = w1.k;                              // operand-less flag/option — skip 1
        } else if (deferredStdin !== null) {
          if (sawDashS) {
            k = w1.k;                            // -s given: positional args, stdin is the program
          } else {
            // NO -s: a positional FILE after `< f` is the SCRIPT (real bash:
            // bash < f x.sh runs x.sh — cycle-10 P2-10 parity with B38).
            deferredStdin = null;                // < f becomes a plain input redirect
            const _st3 = { path: w1.w, cwd }; scriptToks.push(_st3, ...forkTwins(_st3));
            i = w1.k;
            done = true;
          }
        } else if (sawDashS) {
          k = w1.k;                            // -s: positional is $0 — keep
                                               // scanning for < f / <<EOF (the real program)
        } else {
          const _st3 = { path: w1.w, cwd }; scriptToks.push(_st3, ...forkTwins(_st3));  // the script path
          i = w1.k;
          done = true;
        }
      }
      if (!done) {
        if (deferredStdin !== null) { const _st4 = { path: deferredStdin.path, cwd, viaStdin: true }; scriptToks.push(_st4, ...forkTwins(_st4)); }
        i = Math.max(i, k);
      }
      continue;
      } // end else: interpreter scan
    }
    // (cycle-33 P3-1) The former `if (w0.w === "exec")` handler was DELETED —
    // exec is a spawner-prefix word (SPAWNER_WORDS) since r37-P3; fresh-command
    // and chained-spawner routes both re-pend it, so this block was dead code.
    // exec-driven interpreter/tee/script scanning runs via the standard chain.

    if (w0.w === "eval" || w0.w === "trap") {
      // quoted eval/trap ('echo x > f') — the STANDARD form — must recurse on
      // the UNQUOTED payload; bare eval collects words until a boundary/newline.
      // `trap` runs its first operand as code in the same shell, so its payload
      // is walked the same way (#625 cycle-4 B2). Leading option tokens are
      // skipped first (`trap --`, `trap -p`, `trap -l`, `eval --`) and ANSI-C
      // quoting (`$'…'` / `$"…"`) is recognized — both otherwise left the raw
      // quoted text as one word, so the `>` was never seen (#625 cycle-5 P1).
      let k = skipWs(i);
      let sawList = false;
      while (k < n) {
        const opt = readWord(k);
        const isList = opt.w === "-p" || opt.w === "--print" || opt.w === "-l" || opt.w === "--list";
        const isOpt = opt.w === "--" || (w0.w === "trap" && isList);
        if (!isOpt || opt.k <= k) break;
        if (isList) sawList = true;
        k = skipWs(opt.k);
      }
      if (w0.w === "trap") {
        // `trap -p`/`-l`: the remaining operands are signal specs, never an
        // action (false-positive fix, cycle-7 P3).
        if (sawList) { i = k; continue; }
        // The action is trap's FIRST operand. A quoted one is read with shell
        // semantics; an UNQUOTED one still needs one level of unescaping
        // (`trap echo\ x\ \>tracked.md EXIT` really writes the file at signal
        // time) — cycle-8 P1.
        const a = readWord(k);
        if (a.w && a.k > k) {
          const _ip = { payload: a.w, cwd }; inlinePays.push(_ip, ...forkTwins(_ip));
          i = a.k;
        }
        continue;
      }
      // `eval` concatenates ALL its arguments into ONE command — read every
      // argument with shell quote semantics (ANSI-C `$'…'` decoded per arg) and
      // join (#625 cycle-6 B4, cycle-7 P1). Advance over spaces/tabs ONLY (not
      // `\n`) so the loop's newline terminator fires and the following line is
      // not swallowed (#625 cycle-8 P1).
      const parts = [];
      let j = k;
      while (j < n && !";|&()\n".includes(s[j])) {
        const a = readWord(j);
        if (a.k <= j) break;
        parts.push(a.w);
        j = a.k;
        while (j < n && (s[j] === " " || s[j] === "\t" || s[j] === "\r")) j++;
      }
      const payload = parts.join(" ").trim();
      if (payload) { const _ip = { payload, cwd }; inlinePays.push(_ip, ...forkTwins(_ip)); }
      i = j;
      continue;
    }
  }
  applyPending();
  for (const r of redirs) push(r.raw, r.cwd, "redirect", "site");
  for (const v of verbToks) push(v.raw, v.cwd, v.via, "site");
  for (const t of tees) {
    // cycle-36 B: the collection must stop at the first top-level `;`/`&`/`|`/`)`
    // boundary too — `echo hi | tee a.md; cat tracked.md` would otherwise collect
    // `cat`/`tracked.md` as tee targets (false block on a later command's words).
    // Quote-aware so a `;` inside a quoted word (e.g. a here-doc delimiter or
    // quoted arg) does not split.
    let segEnd = -1;
    let dqT = null;
    for (let kT = t.idx; kT < n; kT++) {
      const cT = s[kT];
      // `\`+newline is a LINE CONTINUATION — the tee command continues on the
      // next line (bash deletes the pair), so it is NOT a segment boundary.
      // Treating it as one truncated `lim` at the continuation and dropped every
      // operand after it (#625 cycle-13 P1: `printf y | tee \<NL> -a <hub>/f`
      // captured no target while bash appended to the tracked file).
      if (dqT === null && cT === "\\" && s[kT + 1] === "\n") { kT++; continue; }
      if (dqT === null && cT === "\n") { segEnd = kT; break; }
      if (dqT === null && (cT === ";" || cT === "&" || cT === "|" || cT === ")")) { segEnd = kT; break; }
      if (dqT !== null && cT === "\\") { kT++; continue; }
      if (dqT === null && (cT === "'" || cT === '"')) { dqT = cT; continue; }
      if (dqT !== null && cT === dqT) { dqT = null; }
    }
    if (segEnd === -1) segEnd = n;
    const lim = segEnd === -1 ? n : Math.min(segEnd, t.idx + 300);
    // slice from the END of the tee word (a quote-led or path-qualified tee
    // starts earlier than +3 — cycle-30 P2-1/P2-2)
    const teeWordEnd = t.end ?? t.idx + 3;
    // Tee positionals are read with the same quote-aware `readWord` as every
    // other write route, so `$'…'`/`$"…"` decode correctly, an apostrophe or
    // a space inside `$'…'` cannot split the word, ANSI-C escapes cannot inject
    // whitespace into the token stream, and a trailing `# comment` is dropped
    // (#625 cycle-9 A-P3 / B-P2). A word starting with `#` at a word boundary
    // begins a comment; operators/redirections end the tee segment.
    const rawWords = [];
    {
      let p = skipWs(teeWordEnd);
      while (p < lim) {
        const c = s[p];
        if (c === "#" && (p === 0 || /[\s;&|(\n]/.test(s[p - 1]))) break;
        if (c === ";" || c === "&" || c === "|" || c === "(" || c === ")" || c === "\n") break;
        if (c === ">" || c === "<" || (c >= "0" && c <= "9")) {
          let rp = p;
          while (rp < lim && s[rp] >= "0" && s[rp] <= "9") rp++;
          if (rp < lim && (s[rp] === ">" || s[rp] === "<")) {
            while (rp < lim && "<>&|".includes(s[rp])) rp++;
            const ao = readWord(skipWs(rp));
            p = ao.k > rp ? ao.k : rp + 1;
            continue;
          }
        }
        const w = readWord(p);
        if (w.k <= p) { p++; continue; }
        if (w.w !== "") rawWords.push(w.w);
        p = skipWs(w.k);
      }
    }
    // ALL non-flag positionals are write targets (echo x | tee a.md b.md).
    // cycle-16 P2 + cycle-29 (review): a heredoc header `tee f <<EOF` feeds
    // tee from the BODY — drop `<<` and the DELIMITER word only; positionals
    // AFTER the delimiter are REAL targets (bash: `tee a.md <<EOF b.md` writes
    // a.md AND b.md — the earlier dropAll guard dropped them).
    const words = [];
    let heredocDrop = 0;
    let redirDrop = 0;
    for (const w of rawWords) {
      if (heredocDrop > 0) { heredocDrop--; continue; }
      if (redirDrop > 0) { redirDrop--; continue; }   // `<`/`>` operand is a read/redirect, not a tee target (#625 cycle-7 P3)
      if (w === "<<" || w === "<<-") { heredocDrop = 1; continue; }
      if (/^[0-9]*(<|<<|>>?>|&>>?)$/.test(w) || w === "<&" || w === ">&" || w === "<>") { redirDrop = 1; continue; }
      if (_isShellBoundary(w)) continue;
      words.push(w);
    }
    for (const w of words) {
      if (!w.startsWith("-") && !w.startsWith(">") && !w.startsWith("<")) {
        push(w, t.cwd, "tee", "site");
      }
    }
  }
  // python open(): only inside a python interpreter extent (quoted prose and
  // grep-for-text NEVER emit — the interpreter gate the legacy extractor had)
  const pyRe = /open\s*\(\s*\\{0,4}["']([^"']+?)\\{0,4}["']\s*,\s*\\{0,4}["'][wa][^"']*["']/g;
  if (s.length <= 64 * 1024 && pythons.length > 0) {
    const chdirRe = /os\.chdir\s*\(\s*\\{0,4}["']([^"']+?)\\{0,4}["']\s*\)/g; // lazy group mirrors pyRe (r32 P5: greedy ate the closing-\\ escape)
    let m;
    while ((m = pyRe.exec(s)) !== null) {
      // cycle-39 F2: a python site may exist at MULTIPLE fork bases (the
      // cycle-38 case-fork twins share idx/extentEnd with different cwd) —
      // attribute the open() to EVERY containing site so the unmatched-arm
      // reality is not silently dropped (find() kept only the first).
      const sites = pythons.filter((p2) => m.index >= p2.idx && m.index < p2.extentEnd);
      if (!sites.length) continue;
      // cycle-25 P2-2: os.chdir() inside the python extent shifts the write
      // target — replay the chdirs BEFORE this open() against the site cwd.
      for (const site of sites) {
        let pyCwd = site.cwd;
        chdirRe.lastIndex = site.idx;
        let cm;
        while ((cm = chdirRe.exec(s)) !== null && cm.index < m.index) {
          if (cm.index >= site.idx && cm.index < site.extentEnd && !/^\s*$/.test(cm[1])) {
            pyCwd = /^\//.test(cm[1]) ? cm[1] : resolve(pyCwd, cm[1]);
          }
        }
        push(m[1], pyCwd, "python", "site");
      }
    }
  }
  for (const p2 of inlinePays) {
    if (!p2.payload || p2.payload.length > 8192) continue;
    const innerR = bashWriteTargetsResolved(p2.payload, p2.cwd);
    for (const inner of innerR) {
      const key = `${inner.via}:${inner.resolvedPath}`;
      if (seen.has(key)) continue;
      seen.add(key);
      out.push({ ...inner, site: "inline" });
    }
    // cycle-21 P2-3: a source/./script word INSIDE a recursed payload (`bash
    // -c 'source /tmp/evil.sh'`) is a scriptTok of the inner result — merge
    // it so the caller content-walks the nested file too.
    for (const innerSt of innerR.scriptToks || []) {
      if (!scriptToks.some((t) => t.path === innerSt.path && t.cwd === innerSt.cwd)) scriptToks.push(innerSt);
    }
  }
  out.scriptToks = scriptToks;
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
 * @param {{ skipWorktree?: boolean }} [opts]
 * @returns {{ disorder: string|null, branch: string|null }}
 */
export function readHubDisorder(cwd, { skipWorktree = true } = {}) {
  try {
    // Linked worktrees never report hub disorder (D5 — isolated by
    // construction; a worktree gitdir/`.git/worktrees/…` cwd included). The
    // test is STRUCTURAL (gitdir vs commondir realpaths) — the old
    // path-substring test misread a main checkout whose own path contains a
    // `worktrees` segment as a worktree and silently skipped its disorder.
    if (gitCheckoutIsLinkedWorktree(cwd)) return { disorder: null, branch: null };
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

const SHELL_INTERPRETERS = new Set(["bash", "sh", "zsh", "dash", "ksh", "ash", "mksh", "oksh", "source"]);

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
  // Reviewer round-5 P2 regression guard: basename matching must apply ONLY to
  // ABSOLUTE tokens (`/bin/sh`, `/usr/bin/env`). Matching a RELATIVE token's
  // basename retired the M4 script-content closure for colliding names —
  // `./time evil.sh` (a script named `time`) resolved to null instead of
  // `./time`, so the script was never read.
  const isSpawnerTok = (x) => SPAWNER_WORDS.has(x) || (String(x).startsWith("/") && SPAWNER_WORDS.has(basename(String(x))));
  const isShellTok = (x) => SHELL_INTERPRETERS.has(x) || (String(x).startsWith("/") && SHELL_INTERPRETERS.has(basename(String(x))));
  let i = 0;
  while (i < tokens.length) {
    const t = tokens[i];
    if (/^[A-Za-z_][A-Za-z0-9_]*=/.test(t)) { i++; continue; }   // env prefix
    if (t === "cd") { i += 2; continue; }                         // cd prefix
    // `busybox sh evil.sh` — the applet is the interpreter, not `busybox`
    // (reviewer round-3 P1).
    if (t === "busybox") { i++; continue; }
    if (isSpawnerTok(t) && !isShellTok(t)) {
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
        if (isShellTok(n)) { found = true; break; }
        k++;
      }
      if (found) { i = k; continue; }
      // No interpreter after the spawner: an ABSOLUTE/relative PATH token is
      // the script itself (`./time evil.sh`, `/tmp/time evil.sh` — the
      // round-5 P2 regression guard), a bare spawner word is not.
      if (/^\.{0,2}\//.test(t)) break;
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
  if (isShellTok(t)) { // abs path: `/bin/sh evil.sh`
    // (#444) The script operand is the FIRST non-flag, non-redirect positional
    // after the interpreter — NOT the last. `bash script.sh <arg>...` hands
    // the trailing tokens to the script as $1… (probe-verified against real
    // bash), so the old last-positional rule resolved a trailing ARG (usually
    // a non-file) and scriptGitVerdict never ran on the real script — the M4
    // script-content closure (#1484 Slice E) was bypassed for argument-taking
    // scripts (`bash hub-worktree.sh feat/x <repo>` gated <repo>). Round-19
    // (final gate P1) semantics are preserved: `bash --rcfile decoy evil.sh`,
    // `bash -O extglob evil.sh`, `bash < /dev/null -x evil.sh` all execute
    // evil.sh — the FIRST positional IS evil.sh in each. Once the script
    // operand is found the scan STOPS: later tokens are the script's own
    // arguments, never parsed as bash flags.
    //
    // Stdin-program modes: `-s` (and any single-dash letter run CONTAINING s —
    // bash parses -se/-es/-xs char-by-char) demotes every positional to
    // $0/$1; the program then comes from stdin — a `< f` operand's file (f)
    // or a heredoc body (#437 round-13 VGATE sub-case). `-c`/`--command` (and
    // runs CONTAINING c — -ec/-sc/-cs; c consumes the next word as the
    // command string) means an inline → return null (gated by the normal
    // classifier). `--` ends option parsing: the NEXT operand is the script
    // even when dash-leading (`bash -- x.sh -x aaa` → x.sh). Option operands:
    // --rcfile/--init-file/-O/-o (space and `=`-attached forms) and the o/O
    // run letters consume the following word. POSIX `+`-toggles mirror the
    // letter runs (`bash +e evil.sh` runs evil.sh — +x/+e/+eu, bare `+`;
    // +o/+O take an operand, +c is an inline, +s demotes like -s). Process
    // substitution `<( … )` is an FD, not a file (null —
    // _unverifiableGitContent fails closed).
    let j = i + 1;
    let sawInline = false;      // -c/--command → inline string (null)
    let sawDashS = false;       // -s → positionals are $0/$1; program is stdin
    let sawDoubleDash = false;  // -- → option parsing is over
    let stdinOperand = null;
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
          stdinOperand = tokens[j + 1]; // the stdin file — the program only with -s, or without a script positional
        }
        j += 2;
        continue;
      }
      if (_isShellBoundary(n)) break;
      if (sawDoubleDash) return n; // after `--` ANY operand is the script (dash-leading too)
      if (n === "--") { sawDoubleDash = true; j++; continue; }
      if (n === "-c" || n === "--command" || n.startsWith("--command=")) {
        sawInline = true;
        j++; // the command string (next word / attached value) is never a file
        continue;
      }
      if (n === "--rcfile" || n === "--init-file") { j += 2; continue; } // space-form operand
      if (n.startsWith("--rcfile=") || n.startsWith("--init-file=")) { j++; continue; } // attached value
      if (/^[+-][a-zA-Z]+$/.test(n)) {
        // single-dash flag/letter-run (plus the POSIX `+` toggle twin: bash
        // +e/+x/+eu x.sh runs x.sh; +o/+O take an operand, +c is an inline
        // command, +s demotes like -s) — bash parses the run char-by-char:
        // c → inline command string (consumes the next word) → null; o/O →
        // the option value is the next word; s → stdin-program mode; every
        // other letter is an operand-less flag. Probes: -ec/-sc/-cs / +c run
        // the payload inline; -se/-es/-xs / +s set stdin mode; -so posix /
        // -sO extglob consume posix/extglob AND set stdin mode.
        const run = n.slice(1);
        if (run.includes("c")) { sawInline = true; j++; continue; }
        if (run.includes("o") || run.includes("O")) j++; // consume the operand word
        if (run.includes("s")) sawDashS = true;
        j++;
        continue;
      }
      if (n.startsWith("-") || n === "+") { j++; continue; } // other operand-less -flag/--option / bare + toggle
      // A non-flag, non-redirect operand:
      if (sawInline) { j++; continue; } // -c: $0/$1 args — never a script file
      if (sawDashS) { j++; continue; }  // -s: $0/$1 — the program is stdin (redirect seen above)
      return n;                         // THE script — later tokens are its args ($1…)
    }
    if (sawInline) return null; // `-c 'inline'` — gated by the normal classifier
    if (sawProcessSub) return null; // `bash <(echo 'git …')` — FD, not a file (fail-closed via _unverifiableGitContent)
    // No script positional: a stdin redirect's operand IS the program —
    // `bash < evil.sh`, and with -s the ONLY program source (`bash -s < f
    // arg1` → f; arg1 is $1, #437 round-13 VGATE sub-case).
    return stdinOperand && !stdinOperand.startsWith("-") ? stdinOperand : null;
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
  return scriptContentGitVerdict(content, currentBranch, executionCwd, sessionCwd);
}

/**
 * Content-level script verdict (the file reader — scriptGitVerdict — delegates
 * here; #627's code surface shares it for parity).
 * @param {string} content
 * @param {string|null} currentBranch
 * @param {string} executionCwd
 * @param {string} sessionCwd
 * @returns {"allow"|"block"}
 */
export function scriptContentGitVerdict(content, currentBranch, executionCwd = process.cwd(), sessionCwd = process.cwd()) {
  const strippedContent = _stripShellComments(content);
  // Round-7: run the scan on COMMENT-STRIPPED content (a comment like
  // `# runs $(git rev-parse)` must not false-block an otherwise-clean script).
  // Round-6 (second-model P2): the script surface needs the same substitution /
  // eval / alias fail-closed — a script containing `echo "$(git -C <hub>
  // reset --hard)"` yields zero invocations and would otherwise be "allow".
  if (_unverifiableGitContent(strippedContent)) return "block";
  return _gitInvocationsVerdict(allGitInvocations(strippedContent), currentBranch, executionCwd, sessionCwd);
}

/**
 * Shared per-invocation verdict for a git-content surface (script file or
 * #627 code payload): the hub-recovery allowlist PLUS the per-invocation
 * target resolution the structured gate uses (#347 worktree exemption, foreign
 * worktrees, main-protection, pull-refspec-dst). Extracted verbatim from
 * scriptGitVerdict so the code surface cannot drift from the script surface.
 * @param {Array<object>} invocations
 * @returns {"allow"|"block"}
 */
function _gitInvocationsVerdict(invocations, currentBranch, executionCwd, sessionCwd) {
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
