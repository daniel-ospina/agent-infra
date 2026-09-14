import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { isToolCallEventType } from "@earendil-works/pi-coding-agent";
import { execSync } from "child_process";
import { isPrintMode } from "../shared/print-mode.js";
import * as fs from "fs";
import * as os from "os";
import { resolve as resolvePath } from "path";
import { appendJsonl, type GateEventName } from "../shared/audit-log.js";

// ── gh invocation seam (testable) ─────────────────────
// ESM named imports of builtin CJS modules (child_process) are not patchable
// from tests, so gh calls route through runGh(). Tests inject a fake via
// _setRunGhOverride() to exercise failure paths deterministically (no real gh).
/** Options for the gh runner (mirrors execSync's opts we use). */
export interface GhRunOpts {
  cwd?: string;
  timeout?: number;
  env?: NodeJS.ProcessEnv;
}

let runGhOverride: ((cmd: string, opts?: GhRunOpts) => string) | null = null;

/** TEST SEAM: replace the gh runner (returns the command's stdout, throws on
 * failure). Pass null to restore the real execSync-backed runner. Honored only
 * under NODE_ENV=test (review #212 security pass) so production code can never
 * accidentally honor a stray override. */
export function _setRunGhOverride(
  fn: ((cmd: string, opts?: GhRunOpts) => string) | null
): void {
  if (process.env.NODE_ENV === "test" || fn === null) runGhOverride = fn;
}

function runGh(cmd: string, opts?: GhRunOpts): string {
  if (runGhOverride !== null) return runGhOverride(cmd, opts);
  return execSync(cmd, { encoding: "utf-8", ...opts });
}

// Dual-support: check AGENT_* first, then ELDATO_* (Phase 1 — #7549)
function _getEnv(name: string): string | undefined {
  return process.env[`AGENT_${name}`] ?? process.env[`ELDATO_${name}`];
}
function _skipReviewGate(): boolean {
  return _getEnv("SKIP_REVIEW_GATE") === "1";
}

// #285 P1-2b: local task-sub-agent discriminator — mirrors verification-gate's
// isTaskSubAgent (TASK_HEARTBEAT=1 ∧ PI_MODE=print, the marker pair BOTH
// dispatchers force on task children). Drift-guarded by the E14-style source
// test in index.test.ts. Env-param seam (same pattern as verification-gate)
// keeps the #228 print-mode wiring gate green.
function isTaskSubAgent(
  env: Record<string, string | undefined> = process.env,
): boolean {
  return env.TASK_HEARTBEAT === "1" && env.PI_MODE === "print";
}
// Namespaced marker files (Phase 1 — #7549)
const ISSUE_COMPLEXITY_FILE = "/tmp/agent-issue-complexity";

// ponytail: binary counter — any task dispatch counts. Simpler than name-matching.
// Gate trusts the agent is well-intentioned but forgetful, not adversarial.

// ── Git operation patterns ────────────────────────────

const GIT_COMMIT_PATTERN = /(^|\s)git\s+(commit|push)(?=\s|$)/;

/**
 * Remove the bash token-splicing the scanner CAN resolve, so a flag spelled
 * across quotes or escapes is seen the way gh sees it.
 *
 * Bash re-joins a single token across these before gh ever sees argv:
 *   `--ad""min=true`, `--ad\min=true`, `--ad\<newline>min=true`, `--ad'min'=true`
 * all reach gh as `--admin=true`, while the RAW string contains no `--admin`.
 * So we drop quote characters, drop backslash-newline continuations, and drop
 * backslashes (which only ever escape the next character).
 *
 * It is NOT a shell. Two families stay unresolved and are handled differently:
 *   - what `isUnresolvableFlagToken` catches (ANSI-C quoting, a `$`/backtick in a
 *     dash-token) is REFUSED — fail closed;
 *   - what NOTHING here catches — brace expansion (`--{admin,squash}`), `xargs`
 *     `{}`, and `$(…)`/backticks that SUPPLY the `--` or the whole flag — is an
 *     OPEN GAP. It is stated in `hasAdminMergeFlag`'s docstring and tracked as a
 *     follow-up; the only real fix is argv-level enforcement (a `gh` shim).
 */
function normalizeForFlagScan(command: string): string {
  return command.replace(/\\\r?\n/g, "").replace(/["'\\]/g, "");
}

/**
 * Does the command hide a substitution inside a DASH-TOKEN, in a form this
 * scanner REFUSES rather than guesses at?
 *
 *   - ANSI-C / locale quoting: `$'--admin'`, `$'--adm\x69n'`, `--adm$'\x69'n`.
 *     Decoding `\xNN` is exactly the guessing this gate must not do.
 *   - a substitution inside a LITERAL `--` token: `--admi${X}n=true`,
 *     `--admin=$(echo true)`, `` --admin=`true` ``.
 *
 * NARROWER THAN IT SOUNDS, deliberately so: the second rule requires the `--` to
 * be LITERAL. A construct can supply the dash itself — `-${V:--}admin=true`,
 * `$V-admin=true`, `-$(printf %s '-')admin=true` all reach gh as `--admin=true` —
 * and this function does NOT catch those. `hasAdminMergeFlag` catches them
 * separately, by a construct-plus-`admin` rule; see the STATED LIMITS there, which
 * names what remains open. Do not read this function as covering "a substitution
 * inside a dash-token" in general: it covers the case where the `--` is visible.
 */
function isUnresolvableFlagToken(command: string, probe: string): boolean {
  if (/\$['"]/.test(command)) return true;
  return /--[^\s]*[$`]/.test(probe);
}

/**
 * Bash constructs that ASSEMBLE a token from pieces, which this scanner does not
 * evaluate: any `$` (variable reference, `${…}`, `$'…'`, `$("…")`, `$(…)`),
 * backticks, and brace expansion (`{a,b}`).
 *
 * A bare `$VAR` counts: `M=merge; gh pr $M 123 --admin=true` really does perform
 * an admin merge, and a construct set without `$` missed it entirely (VGATE round
 * 6). Being generous here is safe because rule 2 is only consulted after the
 * literal form fails AND the caller conjuncts with `hasAdminMergeFlag`, so
 * `gh pr comment --body "$(…)"` stays outside the gate.
 *
 * Plain `'`/`"` quoting is deliberately NOT here — it is resolved (quotes are
 * stripped) and treating it as unresolvable made every quoted MENTION look like an
 * operation, e.g. `echo "git commit -m x"` (VGATE round 4).
 */
function hasUnresolvableConstruct(command: string): boolean {
  return /\$|`|\{|\}/.test(command);
}

/**
 * Is this a `gh pr merge` command?
 *
 * Two ways to answer yes, and both are needed:
 *   1. the literal, NORMALIZED form — quotes and backslashes are how bash
 *      re-joins one token, so `gh pr "merge" 123` and `gh pr m\\erge 123` are
 *      merges while their raw text is not;
 *   2. an UNRESOLVABLE shape — if the text carries a construct this scanner cannot
 *      evaluate (see `hasUnresolvableConstruct`) and `pr` + `merge` both appear
 *      once quotes are stripped, we refuse to let the spelling HIDE the operation.
 *      This is what closes `gh pr $'merge' 123`, `gh $'pr' merge 123`,
 *      `$'gh' pr merge 123`, `g$'h' pr merge 123` and `gh pr merge$(…) 123`.
 *
 * Three VGATE rounds each found one more position where a splice hid the verb
 * (r3 the verb itself, r5 an ANSI-C verb, r6 the `gh`/`pr` words and a
 * substitution glued to the verb). Enumerating positions is what made that
 * possible, so rule 2 keys on the CONSTRUCT, not on a position: any unresolvable
 * construct plus the two verb words anywhere is treated as a merge. The caller
 * then applies the admin gate, which is itself fail-closed, so a false hit costs
 * a retry while a miss is an unevidenced admin merge.
 */
/**
 * gh's GLOBAL `-R/--repo <value>` flag may sit between any two gh words, so
 * `gh -R owner/repo pr merge 123` is a valid spelling of `gh pr merge 123`.
 * (The repo already fixed this for the merge-scope recogniser in
 * `extensions/verification-gate/index.ts` - `GH_PR_MERGE_VERB`, #204 - and #930
 * did not carry it over, so the most realistic spelling for a multi-repo
 * operator skipped BOTH gates.)
 *
 * Removing the repo pair up front makes every downstream shape compare against
 * the same canonical text, rather than teaching each of four patterns about an
 * optional flag in a different position.
 */
function stripRepoArgs(command: string): string {
  // The value may be ATTACHED (`-Rowner/repo`), `=`-joined, or a separate word.
  // Requiring `=` or whitespace after the flag missed gh's valid pflag spelling
  // `gh -Rowner/repo pr merge 999 --admin`, which then skipped BOTH gates entirely
  // (cycle-3 review P0).
  return command.replace(/(^|\s)(?:-R|--repo)(?:=\S*|\s+\S+|\S*)/g, "$1");
}

export function isGhPrMergeCommand(command: string): boolean {
  const bare = stripRepoArgs(command);
  const probe = normalizeForFlagScan(bare);
  // `[^\w]` rather than `\s` before `gh`: a separator GLUED to the word
  // (`true;gh pr merge 1`, `(gh pr merge 1`) leaves no whitespace to anchor on.
  if (/(^|[\s;&|(){!])gh\s+pr\s+merge(?=\s|$)/.test(probe)) return true;
  if (!hasUnresolvableConstruct(command)) return false;
  // `[^\w]` rather than `\s` before each word: after stripping quotes a spliced
  // word keeps its residue, so the probe holds `$merge` / `$pr` — a
  // whitespace-anchored match missed exactly the cases this rule exists for
  // (VGATE round 6).
  const hasPr = /(^|[^\w])pr\b/.test(probe);
  const hasMerge = /(^|[^\w])merge\b/.test(probe);
  const hasGh = /(^|\W)gh\b/.test(bare) || /(^|\W)gh\b/.test(probe);
  // Requiring BOTH verb words misses a splice INSIDE a word: `gh pr m$'erge'`
  // normalizes to `m$erge`, where `merge` never appears contiguously. So
  // `gh` + `pr` under a construct is enough to treat the text as a merge too.
  // That is still narrow: the caller also requires an admin flag, so a
  // `gh pr comment --body "$(…)"` is not gate-relevant.
  return (hasPr && hasMerge) || (hasGh && hasPr);
}

const GH_PR_PATTERN = /(^|[\s;&|(){!])gh\s+pr\s+(create|merge)(?=\s|$)/;

/**
 * Which characters of `command` sit OUTSIDE a quoted region?
 *
 * Needed because a quote-split COMMAND NAME (`g"h" pr merge …`, `''gh pr merge …`,
 * `\gh pr merge …`) is bash-re-joined to `gh` while the raw text contains no
 * contiguous `gh`, and a quoted MENTION (`echo "gh pr merge 1 --admin=true"`) is
 * the opposite: it DOES contain `gh`, but inside the quotes, so it is not a
 * command at all. The two are indistinguishable from the normalized text — both
 * normalize to `gh pr merge` — so the distinction has to come from quote state.
 *
 * Tracks `'…'` and `"…"` (with `\` escapes outside single quotes).
 */
function unquotedMask(command: string): boolean[] {
  const mask = new Array<boolean>(command.length).fill(true);
  let quote: string | null = null;
  for (let i = 0; i < command.length; i++) {
    const ch = command[i];
    if (quote === null) {
      if (ch === "\\") {
        if (i + 1 < command.length) i++;
        continue;
      }
      if (ch === "'" || ch === '"') {
        quote = ch;
        mask[i] = false;
        continue;
      }
      mask[i] = true;
    } else {
      mask[i] = false;
      if (ch === quote) quote = null;
      else if (quote === '"' && ch === "\\" && i + 1 < command.length) mask[++i] = false;
    }
  }
  return mask;
}

/**
 * Is a `gh` COMMAND NAME present in `command` — i.e. would the shell really run
 * `gh`, rather than the text merely quoting the string "gh"?
 *
 * Two cases are a real command name:
 *   1. a partially-unquoted token that de-quotes to `gh` — `g"h"`, `''gh`, `\gh`,
 *      `gh`. The splice is inside the word, so wherever it sits it is the name it
 *      resolves to.
 *   2. a FULLY quoted token — `"gh"`, `'gh'` — but ONLY in command position. A
 *      fully-quoted word is executable; a fully-quoted ARGUMENT is a string. So
 *      `"gh" pr merge 1 --admin=true` runs, while `echo "gh pr merge 1
 *      --admin=true"` only prints. Command position = the first word, a word after
 *      a separator, or a word after a command-introducing keyword.
 *
 * Text alone cannot separate those two — `echo "gh …"` and `"gh" …` normalize
 * identically — so the distinction has to come from quote state (unquotedMask) plus
 * position. VGATE round 11 found the fully-quoted half missing: the previous rule
 * ("at least one character outside a quoted region") admitted `''gh` and `g"h"`
 * while excluding `"gh"`, an inconsistency inside one family.
 */
const COMMAND_INTRODUCERS =
  /^(command|sudo|env|exec|nohup|nice|time|xargs|do|then|else|eval|sh|bash|zsh|dash|ksh)$/;

/** A separator GLUED to the following word: `true;gh pr merge 1`, `(gh pr merge 1`. */
const GLUED_SEPARATOR = /^[;&|(){!]+/;

/**
 * Split `command` into the words a shell would see, recording where each one
 * starts and which characters sit outside a quoted region.
 *
 * Split on SEPARATORS as well as whitespace: `true;gh pr merge 1` is two commands
 * with no space between them and `(gh pr merge 1` is one — a whitespace-only split
 * leaves `;gh` / `(gh` as single tokens that never equal `gh`.
 */
interface ScanTokens {
  joined: string;
  mask: boolean[];
  tokens: string[];
  starts: number[];
  gaps: string[];
}

function scanTokens(command: string): ScanTokens {
  // bash removes a backslash-newline outright, so `g\<newline>h` is the command
  // `gh`. Do the same before tokenizing, or the continuation splits the name.
  const joined = stripRepoArgs(command).replace(/\\\r?\n/g, "");
  const mask = unquotedMask(joined);
  const tokens = joined.split(/[\s;&|(){!]+/).filter((t) => t.length > 0);
  const starts: number[] = [];
  const gaps: string[] = [];
  let at = 0;
  let prevEnd = 0;
  for (const tok of tokens) {
    const start = joined.indexOf(tok, at);
    starts.push(start);
    at = start + tok.length;
    // The text BETWEEN the previous token and this one. Separators are not part
    // of any token, so a separator is only visible in this gap: `true && "gh" ...`
    // has prev=`true` but `&&` in the gap, and `true;gh ...` is the same command
    // written with no space.
    gaps.push(joined.slice(prevEnd, start));
    prevEnd = start + tok.length;
  }
  return { joined, mask, tokens, starts, gaps };
}

/** A shell word with its quoting removed: `"gh"`, `''gh`, `\gh`, `` `gh `` → `gh`. */
function dequote(tok: string): string {
  return tok.replace(/["'\\`]/g, "").replace(GLUED_SEPARATOR, "");
}

/** Would the shell RUN this word as `gh` (rather than merely quoting the string)? */
function isGhWordAt(scan: ScanTokens, i: number): boolean {
  const tok = scan.tokens[i];
  if (tok === undefined || dequote(tok) !== "gh") return false;
  const start = scan.starts[i];
  // A splice INSIDE the word (`g"h"`, `''gh`, `\gh`) is the command name wherever
  // it sits. A FULLY quoted word (`"gh"`) is executable only in command position.
  const partiallyUnquoted = [...tok].some((_, k) => scan.mask[start + k]);
  if (partiallyUnquoted) return true;
  const prev = i === 0 ? null : scan.tokens[i - 1];
  return (
    prev === null ||
    // A newline is a command separator too: `gh pr merge 111 --admin\n"gh" pr
    // merge 999 --admin` is two commands. Without \n here the second (fully
    // quoted) verb lost its command position and the compound count stayed 1.
    /[;&|(){!\n\r]/.test(scan.gaps[i]) ||
    COMMAND_INTRODUCERS.test(prev) ||
    /^-[a-z]*c$/.test(prev) // `sh -c '...'`, `bash -lc '...'`
  );
}

function hasBareGhWord(command: string): boolean {
  const scan = scanTokens(command);
  return scan.tokens.some((_, i) => isGhWordAt(scan, i));
}

/**
 * The rail's ADMIN-GATE relevance test. `isGitOp` and the `tool_call` gate BOTH
 * use this one function — they cannot disagree. VGATE round 9 caught exactly that
 * failure: `isGitOp` said yes (so the handler ran) while the caller's separate
 * `isGhPrMergeCommand && hasAdminMergeFlag` said no, and `gh p$'r' merge 123
 * --admin=true` was ALLOWED with no head-bound evidence. One predicate, one answer.
 *
 * `hasAdminMergeFlag` is fail-closed, so on its own it is far too broad to be a
 * relevance test — it returns true for `echo $'hello'` (ANSI-C quoting) and for
 * `echo "admin $USER"` (a construct plus the word `admin`), and using it as one
 * blocked ordinary shell commands at zero dispatches (round 9). It must therefore
 * be conjoined with a shape test.
 */
export function isAdminMergeCommand(command: string): boolean {
  if (!hasAdminMergeFlag(command)) {
    // A `$VAR` can SUPPLY the flag: `V=--admin; gh pr merge 999 $V` reaches gh as
    // an admin merge while no text scan can see the word `admin`. That is a class
    // the STATED LIMITS block does not name (it names a `$VAR`-supplied VERB), so
    // per this file's own contract it is a bug, not a documented limit — and it is
    // indistinguishable from a benign `gh pr merge $PR --squash`. Fail CLOSED.
    // The cost is that an UNQUOTED `$PR` needs the evidence comment; the quoted
    // `"$PR"` form (the common one) is unaffected, since its `$` is not preceded
    // by whitespace. Documented in STATED LIMITS.
    // `merge` must be a WORD in the text — `isGhPrMergeCommand` is deliberately
    // broad (any `gh` + `pr` under a construct), so reusing it here made a benign
    // `gh pr view $X` admin-gated.
    return (
      hasUnresolvableConstruct(command) &&
      /(^|[^\w])merge\b/.test(normalizeForFlagScan(command)) &&
      /(^|\s)\$[{(A-Za-z_]/.test(command)
    );
  }
  const bare = stripRepoArgs(command);
  const probe = normalizeForFlagScan(bare);
  if (hasUnresolvableConstruct(bare)) {
    // Unreadable AND possibly a merge: a `gh` word, or both `pr` and `merge`.
    // This is what catches `gh p$'r' merge …`, `$'gh' pr merge …`, `g$'h' pr
    // merge …` WITHOUT the word list that rounds 6-8 kept re-finding a seam in.
    return (
      /(^|[^\w])gh\b/.test(probe) ||
      (/(^|[^\w])pr\b/.test(probe) && /(^|[^\w])merge\b/.test(probe))
    );
  }
  // Readable text, so the only way it is still a merge is a quote-split verb
  // behind a BARE `gh` (quotes are deliberately not a construct). Requiring the
  // `gh` to be bare is what keeps a quoted MENTION — `echo "gh pr merge 1
  // --admin=true"`, `rg 'gh pr merge' scripts/` — outside the gate; gating those
  // was a real over-block that fired on heredocs and greps (VGATE round 8).
  const bareGh = hasBareGhWord(command);
  return bareGh && /(^|[\s;&|(){!])gh\s+pr\s+merge/.test(probe);
}

// Exported so the test suite can pin this predicate DIRECTLY. VGATE round 7
// showed that an unexported `isGitOp` could have its conjunction dropped — the
// exact round-4 regression — while the shipped suite stayed green, because the
// test replicated the predicate instead of exercising it.
export function isGitOp(command: string): boolean {
  // RAW, as before. Normalizing here made a quoted MENTION look like an
  // operation (`echo "git commit -m x"`, `rg 'gh pr merge' scripts/` matched
  // only after the quotes were stripped), turning harmless commands into gate
  // hits — a regression introduced by the `gh pr "merge"` fix and caught by
  // VGATE round 4.
  if (GIT_COMMIT_PATTERN.test(command) || GH_PR_PATTERN.test(command)) return true;
  if (isGhPrMergeCommand(command) && hasBareGhWord(command)) return true;
  return isAdminMergeCommand(command);
}

// ── Merge registry gate (#138) ────────────────────────
// The gate must verify PRs in ANY repo. A previous prototype resolved the repo
// from the pi process cwd, so `gh pr merge <n>` for a PR in repo B — run from a
// session whose cwd is repo A — failed with "Could not resolve to a
// PullRequest with the number of N". Repo context is therefore resolved in
// priority order from the merge command itself, then the review record, with
// the pi cwd as a fail-open fallback (never block on an unresolvable repo).

export interface ReviewRecord {
  pr: number;
  head_sha: string;
  verdict: string;
  reviewed_at?: string;
  repo?: string; // owner/name — written by record-review.sh (optional, older records lack it)
}

/**
 * Registry key (#426): PR numbers collide across repos (a stale DMeer #441
 * record sat in agent-infra's 441.json and blocked its merge). Records are
 * now keyed <owner>-<repo>-<pr>.json when the repo is known. The slug
 * embeds both owner and repo in [A-Za-z0-9_.-]+ form — collision-free within
 * a single owner (a trailing -<pr> split is unambiguous). Two owners whose
 * slugs coincide (a-b/c vs a/b-c → a-b-c) overwrite the SAME file on disk;
 * readReviewRecord defends that class by comparing the record's embedded
 * repo field against the requested repo (P2-1, cycle 2). Legacy <pr>.json
 * stays readable ONLY via the fallback paths below.
 */
export function reviewRecordFile(repo: string | undefined, pr: number): string {
  const dir = reviewsDir();
  return repo
    ? resolvePath(dir, `${repo.replace("/", "-")}-${pr}.json`)
    : resolvePath(dir, `${pr}.json`);
}

function readRecordFile(path: string): ReviewRecord | null {
  try {
    const raw = fs.readFileSync(path, "utf8");
    const rec = JSON.parse(raw) as ReviewRecord;
    if (!rec || typeof rec.head_sha !== "string" || typeof rec.verdict !== "string") return null;
    // Security (#212 review): record.repo is interpolated into shell strings by
    // the gate — enforce the same charset the flag/env sources are validated
    // with. An invalid record is treated as absent (fail-closed).
    if (rec.repo !== undefined && !/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(rec.repo)) return null;
    return rec;
  } catch {
    return null; // missing or corrupt record → treated as "no review"
  }
}

/**
 * Resolve owner/name from the origin remote of a git worktree — no network.
 * The effective cwd for `gh pr merge` is the LAST cd in the command chain
 * (extractCdPath) else the pi session cwd; the gh CLI itself would infer the
 * repo the same way. #426 review P0-1: plain `gh pr merge N` (no --repo /
 * GH_REPO= / cd) must still hit the repo-qualified registry, so the gate
 * resolves the repo from the merge ENVIRONMENT, not just the command text.
 */
export function repoFromGitRemote(dir: string): string | null {
  try {
    const url = execSync(`git -C "${dir}" config --get remote.origin.url`, {
      timeout: 3000,
      stdio: ["ignore", "pipe", "ignore"],
      encoding: "utf8",
    }).trim();
    const m = url.match(/github\.com[:/]([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+?)(?:\.git)?$/);
    return m ? m[1] : null;
  } catch {
    return null; // not a git dir / no origin / not GitHub → caller falls back
  }
}

export interface RepoContext {
  repo?: string; // owner/name → passed as --repo to the gate's own gh calls
  cwd?: string; // resolved cd path → passed as cwd to the gate's own gh calls
  source: "flag" | "env" | "cd" | "record" | "fallback";
}

// Extract the PR number from `gh pr merge <n>` (matches GH_PR_PATTERN verbs).
export function extractPrNumber(command: string): number | null {
  const m = command.match(/gh\s+pr\s+merge\s+(\d+)/);
  return m ? parseInt(m[1], 10) : null;
}

// Priority 1: explicit --repo owner/name (or -R, or --repo=owner/name) flag.
export function extractRepoFlag(command: string): string | null {
  // Value may be attached (`-Rowner/repo`), `=`-joined, or a separate word.
  const m = command.match(/(?:--repo|-R)(?:=|\s+)?([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)/);
  return m ? m[1] : null;
}

// Priority 2: GH_REPO=owner/name env assignment prefix in the command.
export function extractGhRepoEnv(command: string): string | null {
  const m = command.match(/(?:^|\s)GH_REPO=([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)/);
  return m ? m[1] : null;
}

/**
 * Repo context is resolved in priority order from the merge command itself
 * (extractRepoFlag, then GH_REPO=, then cd — LAST cd in the chain wins, since
 * that is the effective cwd when the gh command runs), with the pi process
 * cwd as a fail-open fallback (never block on an unresolvable repo).
 *
 * The cd scan is SEGMENT-based (split on &&/;/newline), not a regex over the
 * whole command: prose arguments like `--comment "see; cd /tmp && …"` must
 * never parse as a cd chain (verification-gate fixed this class in #230), and
 * a bash-style newline-separated `cd /x\ngh pr merge` IS a cd chain (#426
 * review cycle 2 P2-2). parseCdChains ALSO reports unattributable cds (cycle
 * 3 P2-1): bash expands `~`, `$VAR`/`$(…)`/backticks and runs subshell
 * `(cd … && …)` — targets the parser cannot resolve statically. When such a cd
 * is present but unparsed, the effective merge cwd is UNKNOWN and the gate
 * must not fall back to the session cwd's repo (that fallback is how a
 * `cd ~/…/DMeer && merge` would get authorized by an agent-infra record —
 * the reverse #426).
 */

/** Expand a cd target the way bash would when statically resolvable.
 * `~`/`~/…` → home; a path still containing $/backtick is unresolvable
 * statically → null (bash WOULD expand it, so callers treat the cwd as
 * unattributable rather than guessing). */
export function expandCdTarget(path: string): string | null {
  if (path === "~") return os.homedir();
  if (path.startsWith("~/")) return resolvePath(os.homedir(), path.slice(2));
  if (/[$`]/.test(path)) return null;
  return resolvePath(path);
}

export interface CdChainInfo {
  last: string | null; // resolved path of the last parseable `cd <path>`
  unattributable: boolean; // a cd bash WILL run but we can't resolve its target
}

export function parseCdChains(command: string): CdChainInfo {
  // Quote-aware scan splitting on &&/;\n OUTSIDE quotes — prose like
  // `--comment "see; cd /tmp && …"` must never parse as a cd chain (#230
  // class). Counts standalone `cd` words outside quotes so unparseable forms
  // (subshell `(cd …`, `cd $VAR`, `cd "$(…)"`) are detected, not silently
  // mis-attributed to the session cwd (cycle 3 P2-1).
  const segments: string[] = [];
  let cur = "", q: string | null = null, esc = false;
  let cdWords = 0;
  for (let i = 0; i < command.length; i++) {
    const c = command[i];
    if (esc) { cur += c; esc = false; continue; }
    if (q) {
      cur += c;
      if (c === "\\") esc = true;
      else if (c === q) q = null;
      continue;
    }
    if (c === '"' || c === "'") { q = c; cur += c; continue; }
    if (c === "&" && command[i + 1] === "&") { segments.push(cur); cur = ""; i++; continue; }
    if (c === ";" || c === "\n" || c === "|") {
      // `|` (incl. `||`) splits too — the real `cd /x || exit 1` idiom must
      // not capture `|| exit 1` into the cd target (cycle 4 P3).
      if (c === "|" && command[i + 1] === "|") i++;
      segments.push(cur); cur = ""; continue;
    }
    if (c === "c" && command.startsWith("cd", i)) {
      const after = command[i + 2];
      const before = command[i - 1];
      if (
        (after === undefined || /[\s;&|()]/.test(after)) &&
        (before === undefined || /[\s;&|(\n]/.test(before))
      ) {
        cdWords++;
      }
    }
    cur += c;
  }
  segments.push(cur);
  let last: string | null = null;
  for (const seg of segments) {
    const m = seg.match(/^\s*cd\s+(['"]?)(.+?)\1\s*$/);
    if (m) last = m[2];
  }
  if (last !== null) {
    const resolved = expandCdTarget(last.trim());
    return { last: resolved, unattributable: resolved === null };
  }
  // Bare `cd` (no target) → HOME in bash.
  const bare = segments.some((s) => /^\s*cd\s*$/.test(s));
  if (bare) return { last: os.homedir(), unattributable: false };
  // Any OTHER unparsed cd word (subshell `(cd …`, `cd $VAR`, `cd "$(…)"`, …)
  // means the effective cwd is unattributable — say so.
  return { last: null, unattributable: cdWords > 0 };
}

export function extractCdPath(command: string): string | null {
  return parseCdChains(command).last;
}

export function resolveRepoContext(command: string, record: ReviewRecord | null): RepoContext {
  const flag = extractRepoFlag(command);
  if (flag) return { repo: flag, source: "flag" };
  const env = extractGhRepoEnv(command);
  if (env) return { repo: env, source: "env" };
  const cdPath = extractCdPath(command);
  if (cdPath) return { cwd: cdPath, source: "cd" };
  if (record?.repo) return { repo: record.repo, source: "record" };
  return { source: "fallback" };
}

// Review records live at ~/.pi/agent/reviews/<PR>.json (written by record-review.sh).
export function reviewsDir(): string {
  return resolvePath(os.homedir(), ".pi", "agent", "reviews");
}

export function readReviewRecord(pr: number, repo?: string): ReviewRecord | null {
  // #426: repo-qualified lookup when the gate resolved the repo (from the merge
  // command --repo/GH_REPO/cd, or the merge environment's git remote). A record
  // written for ANOTHER repo must never satisfy this repo's gate.
  if (repo) {
    const qualified = readRecordFile(reviewRecordFile(repo, pr));
    if (qualified && qualified.repo !== undefined && qualified.repo !== repo) {
      // The file exists but claims a different repo (identical-slug overwrite
      // across owners, or tampering) — audit + treat as absent (P2-1).
      logGateEvent("review_record_collision", { pr, recordRepo: qualified.repo, gateRepo: repo });
      return null;
    }
    if (qualified) return qualified;
    // Legacy migration fallback: pre-#426 records live at <pr>.json with the
    // repo embedded. Read it ONLY when it belongs to this repo (or predates
    // the repo field entirely) — a cross-repo collision fails closed.
    const legacy = readRecordFile(reviewRecordFile(undefined, pr));
    if (legacy && legacy.repo !== undefined && legacy.repo !== repo) {
      // Real #426 collision (e.g. DMeer#441's record in 441.json while gating
      // agent-infra #441) — audit + treat as absent.
      logGateEvent("review_record_collision", { pr, recordRepo: legacy.repo, gateRepo: repo });
      return null;
    }
    return legacy;
  }
  // No repo context (flag/env/cd/remote all failed — the gh merge itself
  // would run in the session cwd). Trust ONLY records whose key proves their
  // repo:
  //   • a single uniquely-matching qualified file (<owner>-<repo>-<pr>.json),
  //   • a repo-less legacy record (predates the repo field — cannot be foreign).
  // A number-keyed legacy record that EMBEDS a repo is rejected (#426 review
  // P0-2): it may belong to a different repo's PR with the same number, and
  // must not satisfy this merge — nor drive the head lookup for the wrong PR.
  try {
    const dir = reviewsDir();
    const matches = fs
      .readdirSync(dir)
      .filter((f) => new RegExp(`^[A-Za-z0-9_.-]+-[A-Za-z0-9_.-]+-${pr}\.json$`).test(f));
    if (matches.length === 1) {
      const rec = readRecordFile(resolvePath(dir, matches[0]));
      if (rec) return rec;
    } else if (matches.length > 1) {
      logGateEvent("review_record_collision", { pr, ambiguous: matches });
      return null;
    }
  } catch {
    /* reviews dir absent → no qualified files */
  }
  const legacy = readRecordFile(reviewRecordFile(undefined, pr));
  if (legacy && legacy.repo !== undefined) {
    logGateEvent("review_record_collision", { pr, recordRepo: legacy.repo, gateRepo: null });
    return null;
  }
  return legacy;
}

// ── GraphQL rate-limit resilience (#192) ─────────────
// `gh pr view --json …` uses the GraphQL pool, which resets independently of
// the REST pool (`gh api rate_limit` is REST). Parallel sessions can exhaust
// the GraphQL pool while REST stays healthy (observed 2026-08-12, tortoise
// #982: the gate blocked mid-merge on "GraphQL: API rate limit already
// exceeded"). The gate must wait for the reset window and retry — not hard-
// fail the ceremony, and not silently skip head verification (the #138
// fail-open path) when the pool is merely temporarily exhausted.

/** True when a gh error message is the GraphQL rate-limit exhaustion signature.
 * Requires BOTH a rate-limit phrase AND a graphql mention (either order), or
 * the "already exceeded" phrasing — the bare "api rate limit" phrase is NOT
 * enough (REST-pool exhaustion is a different pool whose correct response is
 * not a bounded GraphQL wait; review #212). */
export function isGraphQLRateLimitError(msg: string): boolean {
  const m = msg ?? "";
  const rateLimitPhrase = /rate\s*limit/i.test(m);
  const mentionsGraphQL = /graphql/i.test(m);
  return (mentionsGraphQL && rateLimitPhrase) || /already exceeded/i.test(m);
}

/** Max wall-clock time (ms) the gate waits for the GraphQL reset window (#192).
 * Env-overridable (REVIEW_GATE_RATE_LIMIT_MAX_WAIT_MS); default 10 min — the
 * observed recovery was ~5 min; a full 1h window is reachable by raising it. */
export function rateLimitMaxWaitMs(): number {
  const n = parseInt(process.env.REVIEW_GATE_RATE_LIMIT_MAX_WAIT_MS ?? "600000", 10);
  return Number.isInteger(n) && n > 0 ? n : 600000;
}

/** Seconds until the GraphQL pool resets, read via the REST rate_limit endpoint
 * (independent pool — healthy when GraphQL is exhausted). null on failure. */
export function graphQLResetInSecs(cwd?: string): number | null {
  try {
    const out = runGh(`gh api rate_limit --jq '.resources.graphql.reset'`, { cwd, timeout: 15000 });
    const reset = parseInt(out.trim(), 10);
    if (!Number.isInteger(reset)) return null;
    return Math.max(0, reset - Math.floor(Date.now() / 1000));
  } catch {
    return null;
  }
}

function sleepAsync(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

/** REST-pool fallback for the PR head (#192): `gh api repos/{owner}/{repo}/pulls/{pr}`
 * uses the REST pool, which resets independently of the GraphQL pool — healthy
 * even when `gh pr view`'s GraphQL pool is exhausted. gh fills the {owner}/{repo}
 * placeholders from the resolved repo context (--repo flag / GH_REPO env / cwd
 * git remote). Returns the head SHA, or null on any failure (network, bad repo,
 * REST pool also rate-limited) — callers then decide wait-for-reset vs fail-open. */
export function getPrHeadShaViaRest(pr: number, ctx: RepoContext): string | null {
  // NOTE: `gh api` does NOT accept --repo (verified gh 2.97.0: "unknown flag") —
  // the repo is injected via GH_REPO env (the documented placeholder source).
  const cmd = `gh api repos/{owner}/{repo}/pulls/${pr} --jq .head.sha`;
  try {
    const out = runGh(cmd, {
      cwd: ctx.cwd,
      timeout: 15000,
      env: ctx.repo ? { ...process.env, GH_REPO: ctx.repo } : undefined,
    });
    const sha = out.trim();
    return sha || null;
  } catch {
    return null;
  }
}

/**
 * Current PR head via the gate's own gh call, using the resolved repo context
 * (cwd for `cd ... &&` prefixes, --repo flag for explicit owner/name). Returns
 * null on ANY non-rate-limit failure (network, bad repo, gh missing) — the
 * #138 fail-open signal. On GraphQL rate-limit exhaustion (#192) it FIRST tries
 * the independent REST pool (`gh api repos/{owner}/{repo}/pulls/{pr}` — instant
 * recovery, observed healthy while GraphQL was 0/5000); only if REST is also
 * unavailable does it wait for the GraphQL reset window (bounded by
 * rateLimitMaxWaitMs, polling `gh api rate_limit`) and retry — so a
 * parallel-session GraphQL burn cannot strand a merge or silently skip head
 * verification.
 */
export async function getPrHeadSha(pr: number, ctx: RepoContext): Promise<string | null> {
  const repoArg = ctx.repo ? ` --repo ${ctx.repo}` : "";
  const deadline = Date.now() + rateLimitMaxWaitMs();
  let attempt = 0;
  for (;;) {
    try {
      const out = runGh(`gh pr view ${pr} --json headRefOid --jq .headRefOid${repoArg}`, {
        cwd: ctx.cwd,
        timeout: 15000,
      });
      const sha = out.trim();
      return sha || null;
    } catch (e: any) {
      const msg = (e?.stderr ?? e?.message ?? "").toString();
      if (!isGraphQLRateLimitError(msg)) return null; // non-rate-limit → fail-open as before
      // #192: GraphQL pool exhausted → the independent REST pool is usually
      // healthy (observed 2026-08-12: REST 4978/5000, GraphQL 0/5000). Resolve
      // the head there INSTANTLY instead of sleeping for the reset window.
      const restSha = getPrHeadShaViaRest(pr, ctx);
      if (restSha !== null) {
        console.warn(
          `[review-enforcer] ♻️ #192: GraphQL rate limit — resolved head via REST ` +
          `(gh api pulls/${pr}) instead of waiting for the reset window`
        );
        return restSha;
      }
      // REST also unavailable (both pools down, network, bad repo) → wait for
      // the GraphQL reset window (bounded) and retry, as before.
      const waitSecs = graphQLResetInSecs(ctx.cwd);
      const remaining = deadline - Date.now();
      const waitMs = waitSecs === null
        ? Math.min(30000, remaining) // cannot read reset → fixed-interval poll
        : Math.min(waitSecs * 1000 + 5000, remaining); // reset + 5s buffer
      if (waitMs <= 0 || waitSecs === null && remaining < 30000) {
        console.warn(
          `[review-enforcer] ⚠️ #192: GraphQL rate limit outlasted the ` +
          `${Math.round(rateLimitMaxWaitMs() / 1000)}s cap — failing open (head verification skipped)`
        );
        return null;
      }
      attempt++;
      console.warn(
        `[review-enforcer] ⏳ #192: GraphQL rate limit (attempt ${attempt}) — ` +
        `waiting ${Math.round(waitMs / 1000)}s for the reset window, then retrying`
      );
      await sleepAsync(waitMs);
    }
  }
}

export type MergeGateResult =
  | { status: "block"; reason: string }
  | { status: "failopen"; warning: string }
  | { status: "allow"; message: string };

// Pure gate decision — separated from I/O so it is unit-testable.
export function evaluateMergeGate(
  pr: number,
  record: ReviewRecord | null,
  currentHead: string | null,
  ctx: RepoContext,
  taskSubAgent: boolean = false,
): MergeGateResult {
  if (!record) {
    // #285 Fix C: the emergency-bypass line is FALSE for task sub-agents — the
    // skip flag is already forced on them (#825) and the merge-registry gate
    // stays ACTIVE (#285 P1-2b), so the line would instruct an action that
    // cannot unlock the merge. Shape-aware: the parent session must record the
    // review instead. #513: the remediation is TWO-PATH (micro records
    // clean-micro via the micro flow; standard/complex runs the code-review
    // skill and records clean) — the gate has no tier read, so both paths are
    // named statically.
    const lines = taskSubAgent
      ? [
          "✅ Review enforcement (merge registry) gate is working correctly.",
          `❌ No review record found for PR #${pr} — the code-review gate has not recorded a clean review.`,
          "   → The parent session must record the review for the PR's tier:",
          "   →   Micro issue (complexity:micro): record-review.sh <PR> <head_sha> clean-micro [owner/repo]",
          "   →   Standard/complex issue: run the code-review skill, then record-review.sh <PR> <head_sha> clean [owner/repo]",
          "   → The bypass flag does NOT unlock sub-agent merges (#285).",
        ]
      : [
          "✅ Review enforcement (merge registry) gate is working correctly.",
          `❌ No review record found for PR #${pr} — the code-review gate has not recorded a clean review.`,
          "   → Micro issue (complexity:micro): complete the micro flow (pre-flight + a review dispatch naming the diff), then",
          "   →   record-review.sh <PR> <head_sha> clean-micro [owner/repo]",
          "   → Standard/complex issue: run the code-review skill (Step 10 records clean on convergence), then",
          "   →   record-review.sh <PR> <head_sha> clean [owner/repo]",
          "   → Emergency: set AGENT_SKIP_REVIEW_GATE=1 (or ELDATO_SKIP_REVIEW_GATE=1) and restart to bypass all gates.",
        ];
    return {
      status: "block",
      reason: lines.join("\n"),
    };
  }
  if (record.verdict !== "clean" && record.verdict !== "clean-micro") {
    // #513: two-path remediation — the record's tier is not readable from the
    // record (only the verdict), so both paths are named statically.
    return {
      status: "block",
      reason: [
        `❌ Review record for PR #${pr} has verdict "${record.verdict}" — only "clean" or "clean-micro" unlocks a merge.`,
        "   → Micro issue (complexity:micro): re-record via the micro flow: record-review.sh <PR> <head_sha> clean-micro [owner/repo]",
        "   → Standard/complex issue: run the code-review skill, then record-review.sh <PR> <head_sha> clean [owner/repo]",
      ].join("\n"),
    };
  }
  if (currentHead === null) {
    // #285: FAIL-CLOSED for task sub-agents. The #138 fail-open — "never
    // strand a cross-repo interactive merge" — exists for interactive
    // sessions that can diagnose/resolve a gh failure themselves. A task
    // sub-agent cannot: under the restricted-agent posture an unverifiable
    // head must NOT merge silently. It escalates to the parent session, which
    // runs the merge ceremony interactively (where fail-open still applies).
    if (taskSubAgent) {
      return {
        status: "block",
        reason: [
          "✅ Review enforcement (merge registry) gate is working correctly.",
          `❌ Could not verify head of PR #${pr} via gh (repo context: ${ctx.source}) — head verification is mandatory for sub-agent merges.`,
          "   → The sub-agent cannot complete the merge ceremony here.",
          "   → Return to the parent session: it records the review and runs the merge interactively.",
          `   →   record-review.sh <PR> <head_sha> ${record.verdict} [owner/repo]`,
          "   → The #138 fail-open (merge without head verification) is interactive-only; sub-agent merges are fail-closed (#285).",
        ].join("\n"),
      };
    }
    // Fail-open with a loud warning: transient gh errors (network etc.) or an
    // unresolvable repo must never strand a cross-repo merge — blocking is
    // exactly the bug #138 fixes. Tell the user how to make it resolvable.
    // #513: re-record at the SAME verdict the record holds (re-recording
    // `clean` over a clean-micro record would falsely certify a multi-agent
    // review at micro; the reverse would downgrade a real review).
    const advice =
      ctx.source === "fallback" && !ctx.repo
        ? "The repo could not be resolved (no --repo/GH_REPO/cd, and the session cwd is not a GitHub worktree). If this PR is in " +
          `another repo, re-record with repo info — record-review.sh <PR> <head_sha> ${record.verdict} owner/repo — ` +
          "or pass --repo owner/repo to gh pr merge."
        : `If this persists, re-record with repo info — record-review.sh <PR> <head_sha> ${record.verdict} owner/repo — ` +
          "or pass --repo owner/repo to gh pr merge.";
    return {
      status: "failopen",
      warning:
        `⚠️  [review-enforcer] Could not verify head of PR #${pr} via gh (repo context: ${ctx.source}). ` +
        `Allowing merge WITHOUT head verification. ${advice}`,
    };
  }
  if (record.head_sha !== currentHead) {
    // #513: re-record at the SAME verdict the record holds (a micro PR's
    // re-record is clean-micro via the micro flow; a standard/complex PR's is
    // clean via the code-review skill) — never a hardcoded `clean`.
    return {
      status: "block",
      reason: [
        `❌ PR #${pr} head has advanced since the review was recorded.`,
        `   Recorded: ${record.head_sha.slice(0, 12)}   Current: ${currentHead.slice(0, 12)}`,
        `   → The branch moved — re-review the new head and re-record at the same verdict: record-review.sh <PR> <head_sha> ${record.verdict} [owner/repo]`,
      ].join("\n"),
    };
  }
  return {
    status: "allow",
    message:
      `[review-enforcer] ✅ Merge registry gate passed for PR #${pr} ` +
      `(${record.verdict} review, head ${currentHead.slice(0, 12)} matches) — allowing merge`,
  };
}

// ── Durable audit trail (#60) ─────────────────────────
// Every gate bypass and review-dispatch event is appended to
// ~/.pi/agent/audit/gate-events.jsonl (see shared/audit-log.ts). Fail-safe:
// appendJsonl never throws, so auditing can never alter a gate decision.
// Optional `file` override exists for tests (temp log path).

export function logGateEvent(
  event: GateEventName,
  extra: Record<string, unknown> = {},
  file?: string
): void {
  appendJsonl(
    { event, extension: "review-enforcer", ...extra, session_cwd: process.cwd() },
    file
  );
}

// Short tag for merge_gate_block entries — mirrors evaluateMergeGate's
// block branches (no review record / non-clean verdict / head advanced).
export function mergeGateBlockReason(record: ReviewRecord | null): string {
  if (!record) return "no_review_record";
  if (record.verdict !== "clean" && record.verdict !== "clean-micro") return "verdict_not_clean";
  return "head_advanced";
}

// Record the merge-gate decision: block → merge_gate_block with a short
// reason; allow AND fail-open (allow-with-warning) → merge_gate_pass
// (fail-open marked via reason "failopen" so the audit trail shows the merge
// was allowed without head verification).
export function logMergeGateDecision(
  pr: number,
  result: MergeGateResult,
  record: ReviewRecord | null,
  file?: string
): void {
  // #513: carry the recorded verdict on pass AND block entries (null-safe —
  // the record is null on the unattributable-cd path) so the audit trail can
  // reconstruct WHICH verdict unlocked WHICH merge: merge_gate_pass {pr,
  // verdict} + the record's reviewed_at is the only joinable dispatch→merge
  // trail (review_dispatch events carry no PR identity).
  const verdict = record ? { verdict: record.verdict } : {};
  if (result.status === "block") {
    logGateEvent(
      "merge_gate_block",
      { pr, ...verdict, reason: mergeGateBlockReason(record) },
      file
    );
  } else {
    logGateEvent(
      "merge_gate_pass",
      { pr, ...verdict, ...(result.status === "failopen" ? { reason: "failopen" } : {}) },
      file
    );
  }
}

// ── #930: safe-admin-merge evidence gate ──────────────
// `--admin` bypasses required checks, so nothing makes it *safe*: it cannot tell
// a check already red on main from a NEW failure the PR introduces (tortoise
// #3420 merged carrying a test that was not in main's failing set, and main
// ratcheted redder). The chokepoint is scripts/admin-merge.sh; this gate closes
// the other half — a RAW `gh pr merge … --admin` is refused unless the PR
// carries an `<!-- admin-merge-safety: <head-sha> -->` evidence comment bound
// to the CURRENT head SHA, so every push invalidates prior evidence.
//
// Flag shapes the gate must catch (a single regex on `--admin` is not enough —
// `extractPrNumber` requires the number to follow `gh pr merge` immediately, so
// every one of these previously slipped past the merge-registry gate entirely):
//   gh pr merge --admin 123          (flag BEFORE the number)
//   gh pr merge 123 --admin
//   gh pr merge --admin=true 123
//   gh pr merge 123 --admin=TRUE     (any Go-true spelling: 1, t, T, True …)
//   gh pr merge --squash --admin 123
//   gh pr merge --admin              (no number → cannot bind evidence)
const ADMIN_MERGE_EVIDENCE_RE = /<!--\s*admin-merge-safety:\s*([0-9a-fA-F]{7,40})\s*-->/g;

/**
 * Is an `--admin` flag present in a `gh pr merge` command, with a value that
 * makes the merge an ADMIN merge? Bare `--admin`, `--admin=`, every Go-true
 * spelling (`=true`, `=TRUE`, `=True`, `=t`, `=T`, `=1`, `="true"`) and every
 * value we cannot RESOLVE are. Only a resolvable Go-FALSE value (`0`, `f`, `F`,
 * `FALSE`, `false`, `False`) is an ordinary merge and must not be refused.
 *
 * FAIL-CLOSED ON THE UNRESOLVABLE (why this is not `val === "true"`):
 * we see a raw command STRING, not argv. Bash lowers `--admin\=true`,
 * `--admin=$'true'`, ``--admin=`true` ``, `--admin=$(echo true)`,
 * `--admin=${X:-true}`, `--admin=tr""ue` and `--admin=true; …` all to a real
 * `--admin=true` before gh sees them. We cannot evaluate a shell, so we do not
 * pretend to: a value that is not a resolvable false spelling is treated as an
 * admin merge. The previous rule (`=== "true"` only) returned false for every
 * one of those spellings, and the command then fell through to the merge-registry
 * gate and merged WITH NO EVIDENCE — a live fail-open in the declared arg-order
 * evasion class (#930 review P1, cycle 2; VGATE cycle 2).
 *
 * COST OF THE SAFE DIRECTION: `--admin=zork`, `--admin=''` and a quoted
 * `--title "--admin=TRUE"` are now refused although gh would have rejected the
 * command (or read the flag as a value). Refusing a command gh would have
 * refused anyway costs nothing; accepting one it would have merged is the hole.
 * The value charset excludes shell metacharacters and quotes so a compound
 * command's tail (`--admin=true && gh pr merge …`) is not swallowed into the value.
 *
 * QUOTES, ESCAPES AND LINE CONTINUATIONS ARE RESOLVED BEFORE MATCHING. Bash
 * re-joins a single token across these, so `--ad""min=true`, `--ad\min=true`,
 * `--ad\<newline>min=true` and `--ad'min'=true` all reach gh as a real
 * `--admin=true` while the raw string carries no literal `--admin`. Three VGATE
 * rounds each found another member of this family being missed, so the scanner
 * no longer enumerates: see `normalizeForFlagScan` (what is resolved) and
 * `isUnresolvableFlagToken` (what is refused instead of guessed at).
 *
 * STATED LIMITS — WHAT THIS CANNOT SEE (a raw-string scanner, not a shell). These
 * are OPEN GAPS, not safe assumptions, and are tracked for argv-level enforcement.
 * Read this as the authoritative list; if a shape is not matched by the code and
 * not named here, that is a bug in this file, not a safe assumption.
 *   - `xargs`/`{}` assembling the flag from parts that never co-occur with the
 *     word `admin`, e.g. `printf '%s' --ad | xargs -I{} gh pr merge 123 {}min`;
 *   - anything expanded UPSTREAM of the string (a `$VAR` in the caller's argv);
 *   - an equivalent merge issued as `gh api … /merge`, through a `gh alias`, or
 *     from a `$VAR`-expanded argv;
 *   - in `isGitOp`, a `$VAR`-SUPPLIED verb with NO admin flag is not treated as a
 *     merge, so it bypasses the MERGE-REGISTRY gate (`V=pr; gh $V merge 123
 *     --squash`). With an admin flag the rule below catches it, and an ANSI-C verb
 *     (`gh p$'r' …`) is refused by rule 2(a) regardless. The registry gate is
 *     outside #930's scope, so this is noted, not fixed.
 * (Brace expansion `--{admin,squash}` and a construct-supplied dash such as
 * `-${V:--}admin=true` were on this list in an earlier revision and are now
 * CLOSED by rule 2 below — verified, not assumed.)
 *
 * A `$VAR`-SUPPLIED FLAG is CLOSED by failing closed, and the cost is stated: a
 * merge shape with an unresolvable construct and a BARE `$VAR` argument is treated
 * as an admin merge (`isAdminMergeCommand`), because `V=--admin; gh pr merge 999
 * $V` reaches gh as an admin merge while no text scan can see the word `admin`.
 * This also refuses the benign unquoted `gh pr merge $PR --squash`. The QUOTED form
 * `gh pr merge "$PR" --squash` (the common one) is unaffected — its `$` is not
 * preceded by whitespace — and the evidence comment is the documented way through.
 *
 * A complete gate cannot be built on this surface: it needs argv-level
 * enforcement (a `gh` shim/allowlist). This file's claims are bounded to what it
 * actually implements:
 *   - resolvable splices (quotes, backslashes, line continuations) are resolved;
 *   - a construct plus the word `admin` is refused (rule 2) — that is what closes
 *     the ASSEMBLED-FLAG family `-${V:--}admin=true`, `$V-admin=true`,
 *     `-$(printf %s '-')admin=true`, which VGATE round 7 showed reaching gh as
 *     `--admin=true` while the earlier dash-anchored rule missed them;
 *   - a spliced VERB is refused rather than read (`isGhPrMergeCommand`).
 * It does NOT claim exhaustive coverage, and it does not:
 *   - OVER-BLOCKS, acceptably and visibly: any `gh pr merge` carrying a construct
 *     (a `$`, backtick or brace) AND the word `admin` is refused unless it has
 *     head-bound evidence — including a harmless `echo "gh pr merge 1
 *     --admin=true"`, and a `--body "ask the admin"` beside a `$VAR`. The remedy
 *     is the mandated `scripts/admin-merge.sh`; the alternative was a bypass.
 */
export function hasAdminMergeFlag(command: string): boolean {
  // 1. Normalize the splicing bash resolves before gh sees argv (quotes,
  //    backslashes, line continuations), so `--ad""min=true` and `--ad\min=true`
  //    are seen as `--admin=true` rather than hiding the flag. (VGATE rounds 1-3:
  //    each of these returned FALSE while gh received a real admin merge.)
  const probe = normalizeForFlagScan(command);
  // 2. Fail CLOSED on what we cannot resolve. Guessing here is what produced
  //    seven rounds of fail-opens, so the rule is "unresolvable ⇒ admin merge".
  //    (a) ANSI-C quoting, or a `$`/backtick inside a literal `--` token;
  if (isUnresolvableFlagToken(command, probe)) return true;
  //    (b) a construct that could ASSEMBLE the flag — the dashes included. VGATE
  //    round 7: `-${V:--}admin=true`, `$V-admin=true` and
  //    `-$(printf %s '-')admin=true` all reach gh as `--admin=true`, and a rule
  //    anchored on a literal `--` misses every one. Keying on the CONSTRUCT plus
  //    the word `admin` (rather than on a dash position) is what closes the
  //    family; it is narrow in the direction that matters, because a construct
  //    WITHOUT the word `admin` — e.g. the common `gh pr merge "$PR" --squash` —
  //    is untouched.
  if (hasUnresolvableConstruct(command) && /admin/i.test(command)) return true;
  // 3. The literal flag. Token-anchored: `--admin` must be a WHOLE flag. A
  //    `--adminx` typo is not a bypass (gh rejects it as an unknown flag), and
  //    refusing it would be exactly the false block this rail must not produce.
  //    `=` may carry a Go-false value; anything else is a bypass (see GO_FALSE).
  const re = /(?:^|[\s])--admin(?:=([^\s;&|()`$<>]*))?(?=$|[\s;&|()`$<>])/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(probe)) !== null) {
    const val = m[1];
    // ONLY a resolvable Go-false value makes this an ordinary merge. Bare (`val
    // === undefined`), empty, Go-true, and unparseable values all count as an
    // admin merge: we fail CLOSED on anything we cannot resolve.
    if (val === undefined || !GO_FALSE.has(val)) return true;
  }
  return false;
}

/**
 * The Go `strconv.ParseBool` spellings that mean FALSE — the ONLY values under
 * which `--admin=<v>` is not an admin merge. Case-SENSITIVE, exactly as Go is.
 */
const GO_FALSE = new Set(["0", "f", "F", "FALSE", "false", "False"]);

/**
 * Extract the PR number from a `gh pr merge` command REGARDLESS of flag order
 * (#930 adversarial class 4 — arg-order evasion). The segment runs from `gh pr
 * merge` to the first shell terminator (`;`, `&&`, `||`, `|`, newline), so a
 * number belonging to a LATER command can never be attributed to this merge.
 * Flags that take a value are skipped together with their value; every
 * value-less merge flag is listed so a later number is still found. Returns
 * null when no PR number is present (e.g. `gh pr merge --admin` on the current
 * branch) — a null answer must FAIL CLOSED for an admin merge, never fall
 * through to the dispatch-count path.
 */
/**
 * How many `gh pr merge` verbs the command carries.
 *
 * `extractMergePrNumber` deliberately truncates at the first `;`/`&&`/`||`/`|`,
 * and the gate evaluates exactly ONE PR - so a compound
 * `gh pr merge 111 --admin; gh pr merge 999 --admin` is judged against 111's
 * evidence and then merges 999 with `--admin` and no evidence at all. The caller
 * treats >1 as a fail-closed block rather than guessing which PR was meant.
 */
export function countMergeVerbs(command: string): number {
  // This MUST use the same recognizer the gate uses (`isGhWordAt`), not a second
  // regex. Cycle-2 review: a regex here counted 1 for
  // `gh pr merge 111 --admin; sh -c 'gh pr merge 999 --admin'` — the second verb
  // is wrapped, so it did not match — the `> 1` fail-closed guard was skipped and
  // 999 merged unevidenced. Two disagreeing predicates is the exact failure this
  // file keeps re-learning (VGATE round 9), so the count walks the same tokens.
  const scan = scanTokens(command);
  // A construct-SPLICED verb (`gh pr $'merge' 999`, `gh p$'r' merge 999`) dequotes
  // to a residue, so an exact `dequote(tok) === "merge"` test does not see it and
  // the compound guard was skipped — the second PR merged unevidenced (cycle-3
  // review P0). When the text carries any unresolvable construct, every
  // command-position `gh` is counted CONSERVATIVELY: this count is only ever used
  // as `> 1` on a command already known to be an admin merge, so an over-count
  // costs a retry while an under-count is an unevidenced merge.
  const unresolvable = hasUnresolvableConstruct(command);
  let n = 0;
  for (let i = 0; i < scan.tokens.length; i++) {
    if (!isGhWordAt(scan, i)) continue;
    if (unresolvable) {
      n++;
      continue;
    }
    if (dequote(scan.tokens[i + 1] ?? "") !== "pr") continue;
    if (dequote(scan.tokens[i + 2] ?? "") !== "merge") continue;
    n++;
  }
  return n;
}

export function extractMergePrNumber(command: string): number | null {
  const canonical = stripRepoArgs(command);
  const idx = canonical.search(/gh\s+pr\s+merge\b/);
  if (idx === -1) return null;
  const rest = canonical.slice(idx).replace(/^gh\s+pr\s+merge\b/, "");
  const segment = rest.split(/;|&&|\|\||\||\n/)[0] ?? "";
  const tokens = segment.split(/\s+/).filter(Boolean);
  const valueFlags = new Set([
    "--repo", "-R", "--body", "-b", "--body-file", "-F", "--subject",
    "-t", "--author-email", "--match-head-commit",
  ]);
  for (let i = 0; i < tokens.length; i++) {
    const tok = tokens[i];
    if (valueFlags.has(tok)) {
      i++; // skip the flag's value
      continue;
    }
    if (/^--[A-Za-z-]+=/.test(tok)) continue; // --flag=value
    if (/^\d+$/.test(tok)) return Number(tok);
  }
  return null;
}

/**
 * Evidence must be **non-vacuous**, not merely present (#930 adversarial class
 * 2 — forgery/vacuity). A marker line alone proves nothing: the evidence body
 * must carry the comparison's own counts, with `unique to this PR: 0`. A body
 * computed over an empty or unparsed failing set cannot produce this line without
 * the comparison having produced *some* numeric line — but see the
 * `evidenceBodyIsCertifying` docstring for what this honestly cannot prove: a
 * hand-typed line is one `printf` away, so this closes vacuity, not forgery.
 */
/** The body's `PR head:` value, lowercased, or null when absent. */
export function evidenceHeadInBody(body: string): string | null {
  const m = /PR head:\s*([0-9a-fA-F]{7,40})\b/.exec(body);
  return m ? m[1].toLowerCase() : null;
}

/**
 * Is `body` a CERTIFYING evidence comment for the marker SHA `markerSha`?
 *
 * What this CANNOT do: prove the comparison actually ran. The counts line is
 * text, and a determined agent can type it. No agent-side check can close that
 * (it is why the honest limit is stated rather than papered over).
 *
 * What it CAN do — and did not, before this fix — is refuse an internally
 * INCONSISTENT comment. The body's `PR head:` must name the SAME revision as
 * the marker that unlocked the gate; the caller separately binds the marker to
 * the CURRENT head. So pasting a valid marker onto an unrelated body (or
 * hand-typing counts beside a `PR head:` the marker does not name) no longer
 * certifies.
 */
export function evidenceBodyIsCertifying(body: string, markerSha: string): boolean {
  const bodyHead = evidenceHeadInBody(body);
  if (bodyHead === null) return false;
  const marker = markerSha.toLowerCase();
  // Prefix-tolerant in BOTH directions, mirroring the caller's head binding: a
  // short SHA is legitimate in either line, but the two must denote one commit.
  // (This was asymmetric until review cycle 2: a full-length marker with a
  // short `PR head:` returned false while the reverse returned true, so the
  // comment described a tolerance the code did not have.)
  const headNamesTheMarker =
    marker === bodyHead || marker.startsWith(bodyHead) || bodyHead.startsWith(marker);
  return (
    headNamesTheMarker &&
    /PR failing:\s*\d+\s*\|\s*main failing:\s*\d+\s*\|\s*unique to this PR:\s*0\b/.test(body) &&
    // The lane is named in the provenance line (`... union of N runs of
    // <lane>:`) — accept it, but never accept a missing provenance line.
    /main compared \(union of \d+ runs?(?: of [^:()]+)?\):/.test(body)
  );
}

export type AdminMergeGateResult =
  | { status: "block"; reason: string }
  | { status: "allow"; message: string };

/**
 * Pure decision for the admin-merge evidence gate.
 *
 * `comments` is the PR's comment bodies, or null when the fetch FAILED — a
 * failed fetch is `block` (fail-closed): an admin merge is a bypass, and a
 * bypass must not be granted because gh was unreachable.
 */
export function evaluateAdminMergeGate(
  pr: number | null,
  currentHead: string | null,
  comments: string[] | null,
  override: boolean,
): AdminMergeGateResult {
  if (override) {
    return {
      status: "allow",
      message:
        "[review-enforcer] ⚠️  ADMIN-MERGE OVERRIDE — the head-bound evidence gate was " +
        "bypassed by AGENT_ADMIN_MERGE_OVERRIDE=1 (audited). Ensure the operator has " +
        "approved this admin merge; the post-merge detector still runs.",
    };
  }
  const remediation = [
    "   → Run the mandated rail instead: scripts/admin-merge.sh <PR>",
    "     It computes the failing set (union over main's last N runs), refuses a genuinely",
    "     new failure, and posts the head-bound evidence this gate requires.",
    "   → Deliberate operator override: set AGENT_ADMIN_MERGE_OVERRIDE=1 (or the ELDATO_",
    "     alias) and restart (audited as admin_merge_override).",
  ];
  if (pr === null) {
    return {
      status: "block",
      reason: [
        "✅ Review enforcement (admin-merge evidence) gate is working correctly.",
        "❌ `gh pr merge --admin` carries no resolvable PR number, so no head-bound evidence can be checked.",
        ...remediation,
      ].join("\n"),
    };
  }
  if (currentHead === null) {
    return {
      status: "block",
      reason: [
        "✅ Review enforcement (admin-merge evidence) gate is working correctly.",
        `❌ Could not verify the current head of PR #${pr} — an admin merge cannot be bound to evidence without it.`,
        ...remediation,
      ].join("\n"),
    };
  }
  if (comments === null) {
    return {
      status: "block",
      reason: [
        "✅ Review enforcement (admin-merge evidence) gate is working correctly.",
        `❌ Could not read PR #${pr}'s comments to look for head-bound admin-merge evidence — failing CLOSED for a bypass.`,
        ...remediation,
      ].join("\n"),
    };
  }
  for (const body of comments) {
    ADMIN_MERGE_EVIDENCE_RE.lastIndex = 0;
    let m: RegExpExecArray | null;
    while ((m = ADMIN_MERGE_EVIDENCE_RE.exec(body)) !== null) {
      const sha = m[1].toLowerCase();
      // Head-SHA BINDING (#930 adversarial class 1 — stale evidence): a marker
      // minted at head X must not unlock head Y. Accept a prefix match so a
      // short SHA in the marker still binds, but only when it is a prefix of the
      // CURRENT head — never a prefix of some earlier one.
      const bound = sha.length >= 40
        ? currentHead.toLowerCase() === sha
        : currentHead.toLowerCase().startsWith(sha);
      if (bound && evidenceBodyIsCertifying(body, sha)) {
        return {
          status: "allow",
          message:
            `[review-enforcer] ✅ Admin-merge evidence verified for PR #${pr} ` +
            `(marker bound to head ${currentHead.slice(0, 12)}, evidence non-vacuous) — allowing --admin merge`,
        };
      }
    }
  }
  return {
    status: "block",
    reason: [
      "✅ Review enforcement (admin-merge evidence) gate is working correctly.",
      `❌ PR #${pr} has no \`admin-merge-safety\` evidence bound to its CURRENT head (${currentHead.slice(0, 12)}).`,
      "   Evidence is head-bound: every push to the PR invalidates it, so a stale marker is refused.",
      "   A marker alone is also refused — the evidence body must carry the comparison counts.",
      ...remediation,
    ].join("\n"),
  };
}

/** The PR's comment bodies, or null when the fetch failed (fail-closed). */
export function getPrComments(pr: number, ctx: RepoContext): string[] | null {
  const repoArg = ctx.repo ? ` --repo ${ctx.repo}` : "";
  try {
    // `--jq '[.comments[].body]'` → ONE JSON array of bodies. The plain
    // `.comments[].body` form prints one body per line, which silently SPLITS a
    // multi-line evidence comment (the marker line would arrive as its own
    // "comment" with no counts) — a real vacuity hole, not a formatting nit.
    const out = runGh(`gh pr view ${pr} --json comments --jq '[.comments[].body]'${repoArg}`, {
      cwd: ctx.cwd,
      timeout: 15000,
    });
    const parsed = JSON.parse(out);
    if (!Array.isArray(parsed)) return null;
    return parsed.filter((b): b is string => typeof b === "string");
  } catch {
    return null;
  }
}

/** The admin-merge override hatch, mirroring the repo's AGENT_/ELDATO_ env convention. */
function _adminMergeOverride(): boolean {
  return _getEnv("ADMIN_MERGE_OVERRIDE") === "1";
}

// ── Block message ─────────────────────────────────────

// #517: the code-review-skill path is repo-layout-dependent — agent-infra
// keeps skills at skills/, consumer repos sync them to operations/skills/
// (the consumer-repo hardlink location). The extension is repo-agnostic
// (runs in both layouts and in deployed copies), so BLOCK_MESSAGE names BOTH
// layouts rather than doing runtime repo detection: the blocked agent reads
// whichever path exists in their repo. Pinned by index.test.ts #517 + T1b
// (tail-anchored, so the pin survives both forms).
const BLOCK_MESSAGE = [
  "✅ Review enforcement gate is working correctly.",
  "❌ No reviewers were dispatched in this session before the git operation.",
  "   → Read skills/code-review/SKILL.md for the review dispatch protocol (operations/skills/code-review/SKILL.md in consumer repos).",
  "   → Dispatch reviewers via task sub-agents, then retry the git operation.",
  "   → Emergency: set AGENT_SKIP_REVIEW_GATE=1 (or ELDATO_SKIP_REVIEW_GATE=1) and restart to bypass all gates.",
].join("\n");
export { BLOCK_MESSAGE };

// #485: micro is no longer a 0-dispatch pass-through — the VGATE docs/CSS/static
// shape skip (#472) removed the backstop that made that leniency safe (a
// docs-only micro commit at 0 dispatches cleared every enforced gate). Micro now
// BLOCKS at 0 dispatches like every tier. The micro remediation must NOT point
// at the code-review skill: micro skips the multi-agent code-review gate
// (commit-workflow 03-code-review.md), so BLOCK_MESSAGE above would misdirect a
// blocked micro agent.
export const MICRO_BLOCK_MESSAGE = [
  "✅ Review enforcement gate is working correctly.",
  "❌ No reviewers were dispatched in this session before the git operation (micro tier).",
  "   → Micro skips the multi-agent code-review GATE (commit-workflow 03-code-review.md) — the review-enforcer ≥1-dispatch rule still applies (#485).",
  "   → Docs-only sets (VGATE content-shape exempt) need a lightweight reviewer dispatch naming the diff — even a trivial one-line review counts:",
  "   →   task(prompt='[REVIEW] docs-only change — verify claims/consistency against the docs diff; return NO ISSUES FOUND or list issues')",
  "   → Code sets satisfy the dispatch via VGATE: its [VGATE] verification dispatch counts as the required sub-agent dispatch. With VGATE disabled/bypassed, dispatch any lightweight task sub-agent — the gate counts any sub-agent dispatch (the `task` or `subagent` tool).",
  "   → Emergency: set AGENT_SKIP_REVIEW_GATE=1 (or ELDATO_SKIP_REVIEW_GATE=1) and restart to bypass all gates.",
].join("\n");

// #485: uniform ≥1-dispatch policy declaration — every tier blocks at 0
// dispatches. Declarative: consumed by the drift-pin test (fence ↔ export
// compare in index.test.ts T2) only — the block decision is uniform, so no
// production branch consults it; T1/T1b/T3 carry the code↔behavior pins.
// Keys: micro/standard/complex = marker values written by 01-preflight Tier
// Detection; unknown = the literal pre-flight TIER when the issue is
// unlabeled; unlabeled = no marker file present. All map to "block".
export const TIER_RULE = {
  micro: "block",
  standard: "block",
  complex: "block",
  unknown: "block",
  unlabeled: "block",
} as const;

// ── Extension ─────────────────────────────────────────

export default function (pi: ExtensionAPI) {
  try {
    // ── State ──────────────────────────────────────
    let extensionEnabled = true;
    let dispatchCount = 0;

    // ── session_start ──────────────────────────────
    pi.on("session_start", async (_event, _ctx) => {
      dispatchCount = 0;

      // Warn about env vars that never reach Node.js from bash export
      // (these have no effect — tier is read from marker file, skip gate from escape hatch)
      const complexityVar = process.env.AGENT_ISSUE_COMPLEXITY || process.env.ELDATO_ISSUE_COMPLEXITY;
      if (complexityVar) {
        console.log(
          "⚠️  REVIEW-ENFORCER: ISSUE_COMPLEXITY detected in parent shell " +
          `— this has no effect. Tier is read from ${ISSUE_COMPLEXITY_FILE} marker file. ` +
          "Unset this env var to clear the stale state."
        );
      }

      if (_skipReviewGate()) {
        if (isTaskSubAgent()) {
          // #285 P1-2b/P2-a: AGENT_SKIP_REVIEW_GATE=1 is FORCED on task
          // children by both dispatchers (#825) — for them it is NOT a bypass:
          // review DISPATCH stays parent-enforced (the parent runs the review
          // ceremony for the PR as a whole), and the merge-registry gate stays
          // ACTIVE below. Audit the truthful event — gate_bypass/escape_hatch
          // would be a false record for a session that is NOT bypassed.
          extensionEnabled = true;
          console.log(
            "[review-enforcer] review DISPATCH is parent-enforced (#825) — the parent session runs the review ceremony; VGATE + merge-registry gate protect this PR"
          );
          appendJsonl({ event: "review_gate_parent_enforced", extension: "review-enforcer", subagent: true, session_cwd: process.cwd() });
        } else {
          extensionEnabled = false;
          console.log(
            "⚠️  REVIEW GATES DISABLED — all quality checks bypassed.",
            "To re-enable, unset AGENT_SKIP_REVIEW_GATE (or ELDATO_SKIP_REVIEW_GATE) and restart."
          );
          // #60: durable audit record — the console.log JSON below stays, this
          // ADDS the persistent trail (append-only JSONL, fail-safe).
          logGateEvent("gate_bypass", { reason: "escape_hatch" });
          // bypass log — machine-readable JSON. Only emit in interactive mode:
          // in print mode (sub-agents) this bare JSON would land on stderr and
          // contaminate tool-result content, breaking downstream JSON parsers.
          // Same guard as the startup banner below. #133
          if (!isPrintMode()) {
            console.log(
              JSON.stringify({
                event: "gate_bypass",
                reason: "escape_hatch",
                timestamp: new Date().toISOString(),
              })
            );
          }
        }
      } else {
        extensionEnabled = true;
      }
    });

    // ── session_shutdown ───────────────────────────
    pi.on("session_shutdown", async (_event, _ctx) => {
      dispatchCount = 0;
      // Clear marker file to prevent persistent state leakage across sessions
      try {
        if (fs.existsSync(ISSUE_COMPLEXITY_FILE)) {
          fs.unlinkSync(ISSUE_COMPLEXITY_FILE);
          console.log(`[review-enforcer] 🧹 Cleared ${ISSUE_COMPLEXITY_FILE} marker on shutdown`);
        }
      } catch (_err) { /* best-effort cleanup */ }
    });

    // ── tool_call: block git ops if no reviewers (uniform ≥1-dispatch, all tiers) ──
    pi.on("tool_call", async (event, _ctx) => {
      if (!isToolCallEventType("bash", event)) return undefined;
      if (!extensionEnabled) return undefined;

      const command = String(event.input.command ?? "");
      if (!isGitOp(command)) return undefined;

      // #930: the admin-merge evidence gate runs FIRST (before the merge
      // registry). `--admin` bypasses required checks, so it is refused unless
      // the PR carries evidence bound to the CURRENT head SHA. On a pass it
      // FALLS THROUGH to the merge-registry gate — the two gates are
      // independent and both must pass.
      if (isAdminMergeCommand(command)) {
        // P1 (fresh review): a compound command is judged against ONE PR, so
        // `gh pr merge 111 --admin; gh pr merge 999 --admin` would pass on 111
        // and then merge 999 unevidenced. Fail closed.
        if (countMergeVerbs(command) > 1) {
          console.log("[review-enforcer] 🚫 Admin-merge evidence gate blocked (compound merge)");
          logGateEvent("merge_gate_block", { reason: "admin_merge_compound_command" });
          return {
            block: true,
            reason:
              "This command contains more than one `gh pr merge`. The admin-merge evidence " +
              "gate can only certify ONE PR per call, so it cannot prove the others are " +
              "evidenced. Run them as separate commands.",
          };
        }
        const adminPr = extractMergePrNumber(command);
        // #426 context resolution, reuse: --repo / GH_REPO / cd / fallback.
        const adminCtx = resolveRepoContext(command, null);
        const adminHead = adminPr !== null ? await getPrHeadSha(adminPr, adminCtx) : null;
        const adminComments =
          adminPr !== null && adminHead !== null ? getPrComments(adminPr, adminCtx) : null;
        const adminOverride = _adminMergeOverride();
        const adminResult = evaluateAdminMergeGate(
          adminPr, adminHead, adminComments, adminOverride
        );
        if (adminResult.status === "block") {
          console.log("[review-enforcer] 🚫 Admin-merge evidence gate blocked");
          logGateEvent("merge_gate_block", {
            pr: adminPr,
            reason: "admin_merge_no_evidence",
          });
          return { block: true, reason: adminResult.reason };
        }
        console.log(adminResult.message);
        logGateEvent("merge_gate_pass", {
          pr: adminPr,
          reason: adminOverride ? "admin_merge_override" : "admin_merge_evidence_ok",
        });
      }

      // #138: merge registry gate runs FIRST for `gh pr merge` commands.
      // A recorded clean review (registry record) IS the evidence — merges do
      // NOT also require dispatchCount > 0. That gate stays for git
      // commit/push and gh pr create, below.
      const prNumber = extractPrNumber(command) ?? extractMergePrNumber(command);
      if (prNumber !== null) {
        // #426: repo resolution is command-first (--repo / GH_REPO / cd), then
        // the merge ENVIRONMENT — git remote of the cd target, else of the pi
        // session cwd — so plain `gh pr merge N` still hits the repo-qualified
        // registry. record.repo is deliberately NOT used to pick the PR for
        // head verification (review P0-2 false-allow: a foreign record must
        // not drive the head lookup for the wrong repo's PR).
        const cmdCtx = resolveRepoContext(command, null);
        const cdInfo = parseCdChains(command);
        // Cycle 4 P1: an unattributable cd (`cd $VAR`, `cd "$(…)"`, subshell
        // `(cd …)`) means the merge runs SOMEWHERE ELSE — but the no-repo read
        // and head-verify machinery below would attribute it to the session
        // cwd's repo (the exact wrong-repo-record allow this PR kills). Such
        // merges are handled here, before any record read or head fetch:
        // sub-agents fail CLOSED; interactive sessions get a VISIBLE fail-open
        // with remediation (consistent with #138's interactive-only fail-open
        // — the external ai-review-gate required check stays the backstop).
        const unattrib = cmdCtx.source === "fallback" && !cmdCtx.repo && cdInfo.unattributable && !cdInfo.last;
        if (unattrib) {
          const advice =
            "The merge command's cd target is not statically resolvable (subshell/$VAR/backtick cd, e.g. `(cd …)`, `cd $X`). " +
            `PR #${prNumber} cannot be attributed to a repo — re-run with an absolute-path cd or pass --repo owner/repo.`;
          if (isTaskSubAgent()) {
            const msg = `[review-enforcer] 🚫 Merge registry gate blocked — ${advice}`;
            logMergeGateDecision(prNumber, { status: "block", reason: msg }, null); // #60
            return { block: true, reason: msg };
          }
          const warn = `⚠️  [review-enforcer] ${advice} Allowing merge WITHOUT repo attribution or review-record check (interactive fail-open).`;
          console.log(warn);
          logMergeGateDecision(prNumber, { status: "failopen", warning: warn }, null); // #60
          return undefined;
        }
        // Session-cwd fallback fires ONLY for commands with NO cd at all (a
        // parsed cd target is resolved above; anything else would authorize a
        // cross-repo merge with the wrong repo's record).
        const cdPath = cmdCtx.source === "cd" ? cmdCtx.cwd : cdInfo.last;
        const envRepo =
          cmdCtx.repo ??
          (cdPath ? repoFromGitRemote(cdPath) : null) ??
          (cmdCtx.source === "fallback" && !cdInfo.unattributable && !cdInfo.last
            ? repoFromGitRemote(process.cwd())
            : null);
        const ctx = envRepo ? { ...cmdCtx, repo: envRepo } : cmdCtx;
        const record = readReviewRecord(prNumber, envRepo ?? undefined);
        const currentHead = await getPrHeadSha(prNumber, ctx);
        // #285 Fix C: the no-record block message is shape-aware (task
        // sub-agents get the "parent must record the review" variant).
        const result = evaluateMergeGate(prNumber, record, currentHead, ctx, isTaskSubAgent());
        if (result.status === "block") {
          console.log("[review-enforcer] 🚫 Merge registry gate blocked merge");
          logMergeGateDecision(prNumber, result, record); // #60: durable audit record
          return { block: true, reason: result.reason };
        }
        logMergeGateDecision(prNumber, result, record); // #60: durable audit record (pass or fail-open)
        console.log(result.status === "failopen" ? result.warning : result.message);
        return undefined;
      }

      // #285 P1-2b: task sub-agents skip the DISPATCH-count gate — review
      // dispatch is parent-enforced (#825) and their own in-band [VGATE]
      // dispatches are never counted (tool_result noise fix below). Only the
      // merge-registry gate above stays ACTIVE for them (fail-closed on
      // missing reviews/<PR>.json).
      const taskSubAgent = isTaskSubAgent();
      if (dispatchCount > 0 || (taskSubAgent && _skipReviewGate())) {
        console.log(
          taskSubAgent && dispatchCount === 0
            ? "[review-enforcer] ✅ Git op allowed — review DISPATCH is parent-enforced for this sub-agent (#825); the merge-registry gate protects merges"
            : `[review-enforcer] ✅ ${dispatchCount} reviewer dispatch(es) — allowing git op`
        );
        return undefined;
      }

      // #485: uniform ≥1-dispatch block — every tier (micro, standard, complex,
      // unlabeled) blocks at 0 dispatches. The tier read survives ONLY for
      // message selection: micro skips the multi-agent code-review gate
      // (03-code-review.md), so its remediation differs from BLOCK_MESSAGE.
      // Pinned by index.test.ts (behavioral T1/T1b + fence drift T2 + source
      // shape T3). The #285 task-sub-agent early return above is untouched.
      let tier = "";
      try {
        if (fs.existsSync(ISSUE_COMPLEXITY_FILE)) {
          tier = fs.readFileSync(ISSUE_COMPLEXITY_FILE, "utf8").trim().toLowerCase();
        }
      } catch (_err) { /* best-effort */ }
      // #516: BOTH block returns below must emit a durable audit entry — the
      // pre-#516 dispatch-count block wrote console only (no appendJsonl),
      // unlike the merge-registry gate's logMergeGateDecision trail, so
      // blocked-op frequency/attribution was unreconstructible from
      // gate-events.jsonl. Emit gate_block + reason no_reviewers_dispatch + the
      // TIER_RULE-vocabulary tier (micro | standard | complex | unknown |
      // unlabeled; marker-absent maps to "unlabeled") so the tier of every
      // blocked op — the docs-only micro class (#485) included — is
      // reconstructible. Pinned by index.test.ts T1 (micro) + T1b (others).
      if (tier === "micro") {
        console.log("[review-enforcer] 🚫 Blocked — no reviewers dispatched (micro tier)");
        logGateEvent("gate_block", { reason: "no_reviewers_dispatch", tier: "micro" }); // #516: durable audit
        return { block: true, reason: MICRO_BLOCK_MESSAGE };
      }

      console.log("[review-enforcer] 🚫 Blocked — no reviewers dispatched");
      logGateEvent("gate_block", { reason: "no_reviewers_dispatch", tier: tier === "" ? "unlabeled" : tier }); // #516: durable audit
      return { block: true, reason: BLOCK_MESSAGE };
    });

    // ── tool_result: count sub-agent dispatches ────
    pi.on("tool_result", async (event, _ctx) => {
      // The gate counts ANY sub-agent dispatch: the `task` tool or the
      // specialized-agent `subagent` tool (extensions/subagent). Both are
      // sub-agent dispatches — the content-free floor (#485 F2) makes no
      // quality distinction, and the #485 second-model gate flagged that a
      // docs-only micro change reviewed via the `subagent` tool must not
      // false-block post-flip (micro relies on this counter as its only gate;
      // VGATE is shape-exempt and code review is skipped at micro).
      if (event.toolName !== "task" && event.toolName !== "subagent") return undefined;
      // #285 P2: task sub-agents never count dispatches — review DISPATCH is
      // parent-enforced (#825), and their own in-band [VGATE] dispatches must
      // not be counted/audited as review dispatches. (Today they never reach
      // this point: extensionEnabled was false; under P1-2b it stays true, so
      // this early return is what keeps the noise out.)
      if (isTaskSubAgent()) return undefined;
      if (!extensionEnabled) return undefined;

      dispatchCount++;
      console.log(
        `[review-enforcer] 📊 Reviewer dispatch counted (total: ${dispatchCount})`
      );
      // #60: durable per-event record — the running total is stamped on each
      // entry so the dispatch count is reconstructible from the audit log.
      logGateEvent("review_dispatch", { dispatch_count: dispatchCount });
      return undefined;
    });

    // ── startup banner ────────────────────────────
    if (!isPrintMode()) {
      console.log("[review-enforcer] ✅ Loaded — binary review dispatch enforcement active");
    }
  } catch (err: any) {
    console.log("[review-enforcer] ❌ Failed to load:", err.message);
  }
}
