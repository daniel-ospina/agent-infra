import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { isToolCallEventType } from "@earendil-works/pi-coding-agent";
import { execSync } from "child_process";
import { isPrintMode } from "../shared/print-mode.js";
// #966: the command parsers are ONE copy shared with verification-gate, in
// extensions/shared/. This file used to define its own extractPrNumber /
// extractRepoFlag / extractGhRepoEnv / parseCdChains / expandCdTarget /
// extractCdPath; the copies drifted for a month and the two suites pinned
// opposite answers for the same input. The definitions now live only in
// shared/git-command-parse.ts; the drift-pin in index.test.ts keeps a local
// copy from ever coming back.
import {
  expandCdTarget,
  extractCdPath,
  extractGhRepoEnv,
  extractPrNumber,
  extractRepoFlag,
  parseCdChains,
  unquotedMask,
  type CdChainInfo,
} from "../shared/git-command-parse.js";
import * as fs from "fs";
import * as os from "os";
import { resolve as resolvePath, dirname } from "path";
import { fileURLToPath } from "url";
import { appendJsonl, type GateEventName } from "../shared/audit-log.js";
// Re-exported public surface (tests and external consumers import from
// ./index.js) — the DEFINITION lives only in shared/.
export {
  expandCdTarget,
  extractCdPath,
  extractGhRepoEnv,
  extractPrNumber,
  extractRepoFlag,
  parseCdChains,
  type CdChainInfo,
};

/**
 * #984 — the ARGV-LEVEL layer.
 *
 * The string scanner answers "will this command text make gh perform an admin
 * merge?" and seven adversarial rounds each closed one splice and found the next
 * (`--ad""min`, `$'--admin'`, `xargs {}`, `-${V:--}admin=true`, `$V-admin=true`).
 * That class is not closable in a scanner, and the reason is a proof rather than
 * an impression: resolving `$VAR`/`$(…)` requires EVALUATING a shell, which a gate
 * cannot do without running the very command it exists to refuse.
 *
 * So we put a `gh` shim ahead of the real `gh` on PATH for every bash call. By the
 * time `gh` runs, bash has finished: `-${V:--}admin=true` IS the literal string
 * `--admin`, with no splice left to hide behind. `event.input` is mutable and the
 * mutation affects real execution (docs/extensions.md), which is what makes this
 * enforcement rather than advice.
 *
 * The scanner stays as the fast first layer — it gives better messages and costs
 * nothing — now backed by a layer that does not share its limit.
 */
const EXTENSION_DIR = (() => {
  try {
    return dirname(fileURLToPath(import.meta.url));
  } catch {
    return null;
  }
})();

/** Warn ONCE per session when the argv-level layer is missing — silence would make
 *  a degraded guard look like a working one. */
let ghShimAbsenceWarned = false;

/**
 * Resolve the shim directory, or null when no shim is installed.
 *
 * `AGENT_GH_SHIM_DIR` lets an operator (or a consumer install) point at a shim
 * somewhere else; the default is this checkout's `scripts/gh-shim`.
 */
export function resolveGhShimDir(): string | null {
  const explicit = process.env.AGENT_GH_SHIM_DIR;
  const candidates: string[] = [];
  if (explicit) candidates.push(explicit);
  if (EXTENSION_DIR) candidates.push(resolvePath(EXTENSION_DIR, "..", "..", "scripts", "gh-shim"));
  for (const dir of candidates) {
    try {
      if (fs.existsSync(resolvePath(dir, "gh"))) return dir;
    } catch {
      /* an unreadable candidate is not a match */
    }
  }
  return null;
}

/**
 * Materialize the shim at a NEUTRAL path and return that directory.
 *
 * Injecting the CHECKOUT's path would put the branch name into every bash command:
 * this very worktree is `…/930-admin-merge-rail/scripts/gh-shim`, and `admin` in the
 * injected text flips the gates of OTHER extensions, which read the same mutated
 * `event.input.command` after this handler (VGATE #984: with a path containing
 * `admin`, `isGitOp(patched)` is TRUE for a command that is not a git op). The
 * neutral directory keeps the injected text free of gate-relevant words.
 */
export const NEUTRAL_GH_SHIM_DIR = resolvePath(os.homedir(), ".pi", "agent", "shims");

export function materializeGhShim(sourceDir: string | null): string | null {
  if (!sourceDir) return null;
  try {
    fs.mkdirSync(NEUTRAL_GH_SHIM_DIR, { recursive: true });
    const target = resolvePath(NEUTRAL_GH_SHIM_DIR, "gh");
    const src = fs.realpathSync(resolvePath(sourceDir, "gh"));
    const current = fs.existsSync(target) ? fs.realpathSync(target) : null;
    if (current !== src) {
      try {
        fs.rmSync(target, { force: true });
      } catch {
        /* a missing target is the expected case */
      }
      try {
        fs.symlinkSync(src, target);
      } catch {
        fs.copyFileSync(src, target);
        fs.chmodSync(target, 0o755);
      }
    }
    return fs.existsSync(target) ? NEUTRAL_GH_SHIM_DIR : null;
  } catch {
    return null;
  }
}

/** Resolved ONCE per session — with a revalidation, because this runs on EVERY bash call. */
let ghShimDirCache: string | null | undefined;
function activeGhShimDir(): string | null {
  if (ghShimDirCache !== undefined) {
    // REVALIDATE before reuse. A session outlives a worktree: if the link is removed,
    // or its target is deleted (removing a worktree dangles every link into it), the
    // cached directory would still be prepended to PATH while containing no `gh` — so
    // PATH lookup falls through to the REAL gh and the argv layer is silently absent
    // for the rest of the session (VGATE #984). One existsSync per bash call.
    if (ghShimDirCache !== null && fs.existsSync(resolvePath(ghShimDirCache, "gh"))) {
      return ghShimDirCache;
    }
  }
  ghShimDirCache = materializeGhShim(resolveGhShimDir());
  return ghShimDirCache;
}

/**
 * Prefix a bash command with the shim directory on PATH.
 *
 * Returns null when there is nothing to do — no shim resolved, or the operator's
 * kill switch is set. The kill switch exists because this touches EVERY bash call:
 * `AGENT_GH_SHIM=0` turns the layer off without editing code.
 *
 * `export PATH=…` on its OWN LINE, so the command's text is otherwise untouched
 * and its exit status is still the command's (`&&` would change both).
 */
export function withGhShim(command: string, shimDir: string | null): string | null {
  if (process.env.AGENT_GH_SHIM === "0") return null;
  if (!shimDir) return null;
  return `export PATH=${JSON.stringify(shimDir)}:"$PATH"\n${command}`;
}

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
 *
 * ⚠️ Its value removal is NOT quote-aware: `\s+\S+` takes only the FIRST
 * whitespace-delimited word, so a quoted value (`--repo "see <url> here"`) keeps its
 * TAIL in the output. Every caller here only looks for WORDS (`gh`, `pr`, `merge`,
 * `--admin`), which is unaffected — but never read a positional/selector out of this
 * output: that tail held a PR URL and `extractMergeSelector` returned it as the
 * selector (wrong PR + wrong repo, VGATE #1007 cycle 4). It reads the ORIGINAL tail
 * instead, and re-finds the verb with `MERGE_VERB_RE`.
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
 * `unquotedMask` — the module-wide quote model — now lives in
 * extensions/shared/git-command-parse.ts (#966) and is imported above. The
 * helper doc (`Which characters of \`command\` sit OUTSIDE a quoted region?`)
 * moved with it; `matchUnquoted` / `countUnquotedMergeVerbs` / `scanTokens`
 * below are its consumers here, and the shared masked PR scan is the other —
 * one model, so they cannot drift.
 */
/**
 * `RegExp.exec` that skips any match starting INSIDE a quoted region (mask[i] false).
 * `MERGE_VERB_RE` is a text search, so `gh pr view "gh pr merge <url> --admin"` matched
 * the QUOTED verb and attributed that URL's repo to a non-merge command (fresh review,
 * P2). The mask is `unquotedMask`'s — the same quote model the rest of this file uses,
 * so the two cannot drift.
 */
function matchUnquoted(re: RegExp, text: string, mask: boolean[]): RegExpExecArray | null {
  const scan = new RegExp(re.source, `${re.flags.replace("g", "")}g`);
  let m: RegExpExecArray | null;
  while ((m = scan.exec(text)) !== null) {
    if (mask[m.index] === true) return m;
    scan.lastIndex = m.index + 1;
  }
  return null;
}

/**
 * PRECISE count of real (unquoted) `gh pr merge` verbs — the counterpart of
 * `countMergeVerbs`, which over-counts BY DESIGN for the admin-merge compound guard (an
 * over-count there only costs a retry). Repo attribution needs the precise one: an
 * over-count discards a legitimate URL repo (re-review P2). Same `MERGE_VERB_RE` and same
 * `unquotedMask`, so this cannot become a second, disagreeing text model.
 */
function countUnquotedMergeVerbs(command: string): number {
  const mask = unquotedMask(command);
  const scan = new RegExp(MERGE_VERB_RE.source, "g");
  let n = 0;
  let m: RegExpExecArray | null;
  while ((m = scan.exec(command)) !== null) {
    if (mask[m.index] === true) n++;
    else scan.lastIndex = m.index + 1;
  }
  return n;
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
  let prev = i === 0 ? null : scan.tokens[i - 1];
  // `bash -c -- '...'` is valid: `--` separates the option from the script. Look
  // THROUGH it, or the introducer stops being recognised (cycle-4 review P0-2).
  if (prev === "--" && i >= 2) prev = scan.tokens[i - 2];
  return (
    prev === null ||
    // A newline is a command separator too: `gh pr merge 111 --admin\n"gh" pr
    // merge 999 --admin` is two commands. Without \n here the second (fully
    // quoted) verb lost its command position and the compound count stayed 1.
    /[;&|(){!\n\r]/.test(scan.gaps[i]) ||
    COMMAND_INTRODUCERS.test(prev) ||
    /^-[a-z]*c$/.test(prev) || // `sh -c '...'`, `bash -lc '...'`
    // Other real command positions. A redirection (`2>/dev/null`, `>/dev/null`),
    // an assignment prefix (`FOO=bar`) or a reserved word (`if`, `while`, ...)
    // all put the next word in command position; enumerating only the introducers
    // and `-c` let `2>/dev/null "gh" pr merge 1 --admin` skip BOTH gates
    // (cycle-4 review P0-1).
    /^(\d*[<>]|&>>?)/.test(prev) || // redirection (`2>/dev/null`)
    /^[A-Za-z_][A-Za-z0-9_]*=/.test(prev) || // assignment prefix
    /^(if|then|elif|else|while|until|do|done|case|esac|select|in)$/.test(prev)
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
    if (!hasUnresolvableConstruct(command)) return false;
    // A `$`-bearing ARGUMENT anywhere in the merge command means the flag may be
    // hidden in it. The whitespace anchor missed the QUOTED form
    // `gh pr merge 999 "$(printf '\x2d\x2d\x61dmin')"`, whose `$` follows a `"`.
    // Carve out only the POSITION argument — the first token after `merge` — so the
    // common `gh pr merge "$PR" --squash` stays outside the gate (cycle-4 P0-3).
    // Only a `$`-bearing token that is an ARGUMENT OF THE MERGE counts. Scoping it
    // to anything `$`-bearing in the command made `cd "$HOME/wt" && gh pr merge 7`
    // an admin merge, which hijacked the cd-attribution gate and reported the
    // wrong reason (cycle-4 regression caught by the existing cd tests).
    const scan = scanTokens(command);
    let mergeIdx = -1;
    for (let i = 1; i < scan.tokens.length; i++) {
      if (dequote(scan.tokens[i]) === "merge" && dequote(scan.tokens[i - 1]) === "pr") {
        mergeIdx = i;
        break;
      }
    }
    if (mergeIdx === -1) {
      // The VERB WORD may itself be construct-spliced, so the exact token match
      // finds no `merge` and everything below is skipped: ``gh pr m`printf erge`
      // 999 $V`` and ``gh p`printf r` merge 999 $V`` are both real admin merges
      // (cycle-5 review P0, third seam).
      //
      // The signal is a CONSTRUCT IN A VERB POSITION — the token right after `gh`
      // or right after `pr`. Requiring only "construct + the words gh and pr" was
      // too broad (it made `gh pr view $X` an admin merge), and requiring `pr` to
      // be a word missed ``gh p`printf r` …``, where `printf` hides it.
      const hasConstructTokenAfter = (word: string): boolean => {
        for (let i = 0; i < scan.tokens.length - 1; i++) {
          if (dequote(scan.tokens[i]) !== word) continue;
          if (/[$`]/.test(scan.tokens[i + 1] ?? "")) return true;
        }
        return false;
      };
      if (!hasUnresolvableConstruct(command)) return false;
      return hasConstructTokenAfter("gh") || hasConstructTokenAfter("pr");
    }
    // The literal word `merge` gates the rest, but it must come AFTER the
    // spliced-verb fallback above: ``gh pr m`printf erge` …`` has no literal
    // `merge` at all (cycle-5 review P0, third seam).
    if (!/(^|[^\w])merge\b/.test(normalizeForFlagScan(command))) return false;

    // Work on the RAW text after the `merge` word, not on tokens: the separator
    // split breaks `$(printf ...)` into `"$` + `printf` + ..., so a token-local test
    // missed a QUOTED substitution supplying the flag (cycle-4 P0-3).
    // NOTE: backticks count. `hasUnresolvableConstruct` counts them, but this loop
    // tested only `/\$/`, so a backtick-substituted flag was invisible
    // (cycle-5 review P0, first seam).
    const afterMerge = command
      .slice(scan.starts[mergeIdx] + scan.tokens[mergeIdx].length)
      .replace(/^\s+/, "")
      .split(/\s+/)
      .filter(Boolean);
    // A literal number LATER in the argument list means the POSITION was not the
    // first argument, so the flag may be sitting in the first slot:
    // `V=$(printf x --adm); gh pr merge $V 999` is a real admin merge
    // (cycle-5 review P0, second seam). With no later number, a first-slot variable
    // is the ordinary `gh pr merge "$PR" --squash` and stays clean.
    // A value-flag's value is never the flag.
    const laterBareNumber = afterMerge.slice(1).some((a) => /^\d+$/.test(a));
    const VALUE_FLAGS = new Set([
      "--body", "-b", "--body-file", "-F", "--subject", "-t",
      "--author-email", "--repo", "-R", "--match-head-commit",
    ]);
    for (let i = 0; i < afterMerge.length; i++) {
      const arg = afterMerge[i];
      if (i > 0 && VALUE_FLAGS.has(afterMerge[i - 1])) continue;
      if (!/[$`]/.test(arg)) continue;
      if (i === 0) {
        if (/\$\(|`/.test(arg)) return true; // a CONSTRUCTED value in the position slot
        if (laterBareNumber) return true; // the position was actually later
        continue; // a genuine `$PR` position argument
      }
      return true;
    }
    return false;
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
  /** #1348 — the MERGE BASE the clean-low guard certified. The attestation is the
   * three-dot diff `compare/<base>...<head>`, and `merge_base_commit.sha` is the
   * commit that diff is taken FROM: it identifies the certified CONTENT. Pinning
   * the base branch's TIP instead would false-block every record on the next
   * unrelated merge to the base branch, while still being the weaker signal.
   * Written ONLY for clean-low (every other verdict keeps its record shape) and
   * REQUIRED for a clean-low merge: a post-record `gh pr edit --base` moves the
   * merge base and changes what merges while the head sha still matches. */
  merge_base_sha?: string;
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
  source: "url" | "flag" | "env" | "cd" | "record" | "fallback";
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
 *
 * All helpers below live in extensions/shared/git-command-parse.ts (#966).
 */
export function resolveRepoContext(command: string, record: ReviewRecord | null): RepoContext {
  // #1007: a PR URL in the SELECTOR outranks every other source, because gh resolves
  // the merge against the URL and IGNORES --repo/GH_REPO. Probed live rather than
  // assumed (2026-09-14):
  //   gh pr view <agent-infra URL> --repo <tortoise>  → returned the agent-infra URL
  //   gh pr merge <URL to a repo that does not exist> --repo <one that does>  →
  //       "Could not resolve to a Repository with the name '…definitely-not-a-repo-xyz'"
  //   gh pr merge <URL to one that exists> --repo <one that does not>  →
  //       failed on the URL's PR, never on the bogus --repo
  // So reading the evidence from anywhere but the URL's repo verifies a PR gh is not
  // about to merge. The URL wins here for the same reason it wins in gh.
  const selector = extractMergeSelector(command);
  // A COMPOUND command is resolved PER VERB by the caller, and the two extractors need not
  // agree on WHICH verb: `extractPrNumber` is a text match (first `gh pr merge <digits>`),
  // while `extractMergeSelector` takes the FIRST verb — so `gh pr merge <url>; gh pr merge
  // 123` would attribute the url verb's repo to a number taken from a later verb and read
  // another repo's evidence (fresh review, P2).
  //
  // ⚠️ NOT `countMergeVerbs`: that one is deliberately CONSERVATIVE for the admin path (it
  // counts every command-position `gh` under an unresolvable construct, where an over-count
  // only costs a retry). Over-counting here DROPS a legitimate URL repo — re-review found
  // `x="say gh pr merge 1"; gh pr merge <url> --admin`, where it returned 2 and the URL repo
  // was discarded. This counter is PRECISE instead: the same `MERGE_VERB_RE` + the same
  // `unquotedMask`, so a quoted mention is not a verb.
  //
  // It counts a real second verb spelled with `;`, `&&`, a newline, `|`, a subshell, a
  // glued `;` or a repo pair in the gaps. It UNDER-counts a verb hidden inside `sh -c '…'`
  // or a splice (`gh pr $'merge' 123`) — measured (round-4 review). That is benign here and
  // deliberate: the shared `maskQuoted` hides those same spellings from `extractPrNumber`, so the
  // number and the repo stay consistent (both resolve the FIRST verb) instead of the repo
  // being taken from one verb and the number from another.
  if (selector.repo && countUnquotedMergeVerbs(command) <= 1) {
    return { repo: selector.repo, source: "url" };
  }
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

/** #1348 — the PR's CURRENT base sha (the base branch's tip), read from the REST
 * pool. Used only by getPrMergeBaseSha below. Returns null on ANY failure. */
export function getPrBaseSha(pr: number, ctx: RepoContext): string | null {
  try {
    const out = runGh(`gh api repos/{owner}/{repo}/pulls/${pr} --jq .base.sha`, {
      cwd: ctx.cwd,
      timeout: 15000,
      env: ctx.repo ? { ...process.env, GH_REPO: ctx.repo } : undefined,
    });
    const sha = out.trim();
    return /^[0-9a-f]{40}$/.test(sha) ? sha : null;
  } catch {
    return null;
  }
}

/** #1348 — the MERGE BASE of the PR's current base branch and its head, read from
 * the REST pool. Only the clean-low record reader needs it, so it is called
 * lazily (never on a plain `clean` merge, where two extra API calls would have no
 * reader). Two calls: the base sha, then `.merge_base_commit.sha` of
 * `compare/<base>...<head>` — exactly the field the producer's guard pinned, so
 * the two sides compare like with like.
 *
 * Returns null on ANY failure (network, bad repo, a fork head, a response without
 * a merge base). clean-low treats an unverifiable merge base as a BLOCK — its
 * whole attestation is the base-relative diff, and it is the cheapest verdict to
 * re-record — so a transient failure is a false block, never a fail-open. Both
 * interpolated values are 40-hex-validated BEFORE they reach the command string. */
export function getPrMergeBaseSha(pr: number, head: string | null, ctx: RepoContext): string | null {
  if (head === null || !/^[0-9a-f]{40}$/.test(head)) return null;
  const env = ctx.repo ? { ...process.env, GH_REPO: ctx.repo } : undefined;
  const baseSha = getPrBaseSha(pr, ctx);
  if (baseSha === null) return null;
  try {
    const out = runGh(
      `gh api repos/{owner}/{repo}/compare/${baseSha}...${head} --jq .merge_base_commit.sha`,
      { cwd: ctx.cwd, timeout: 15000, env }
    );
    const mb = out.trim();
    return /^[0-9a-f]{40}$/.test(mb) ? mb : null;
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

/**
 * #1348 — the verdicts that unlock a merge, in ONE place. The allowlist in
 * evaluateMergeGate and mergeGateBlockReason used to be two independent
 * expressions of the same vocabulary, so a new verdict added to one site and
 * forgotten at the other would silently mislabel the merge telemetry. Both now
 * consult this list.
 *
 * `clean-low` attests the Low value of the canonical tier table's §Change
 * Classification `Code impact` column (agent-infra #1348): every changed path of
 * the recorded revision is prose or a stylesheet.
 * This gate deliberately does NOT re-derive that shape — the record IS the
 * attestation, and the only place the shape can be read is the producer's
 * clean-low guard in record-review.sh. A local re-check here would be a second,
 * weaker writer of the class.
 *
 * The refusal text below is DERIVED from this list, never re-literalised: a
 * verdict added here that was forgotten in the message is exactly the drift the
 * single source exists to prevent.
 */
export const ACCEPTED_VERDICTS: readonly string[] = ["clean", "clean-micro", "clean-low"];

export function isAcceptedVerdict(verdict: string): boolean {
  return ACCEPTED_VERDICTS.includes(verdict);
}

export type MergeGateResult =
  | { status: "block"; reason: string; reasonTag?: string }
  | { status: "failopen"; warning: string }
  | { status: "allow"; message: string };

// Pure gate decision — separated from I/O so it is unit-testable.
export function evaluateMergeGate(
  pr: number,
  record: ReviewRecord | null,
  currentHead: string | null,
  ctx: RepoContext,
  taskSubAgent: boolean = false,
  currentMergeBase: string | null = null,
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
          "   → Micro issue (complexity:micro): record-review.sh <PR> <head_sha> clean-micro [owner/repo]",
          "   → Content-only diff (docs/ with a content extension, or a named root prose file — any tier): record-review.sh <PR> <head_sha> clean-low [owner/repo]",
          "   → Standard/complex issue: run the code-review skill, then record-review.sh <PR> <head_sha> clean [owner/repo]",
          "   → The bypass flag does NOT unlock sub-agent merges (#285).",
        ]
      : [
          "✅ Review enforcement (merge registry) gate is working correctly.",
          `❌ No review record found for PR #${pr} — the code-review gate has not recorded a clean review.`,
          "   → Micro issue (complexity:micro): complete the micro flow (pre-flight + a review dispatch naming the diff), then",
          "   →   record-review.sh <PR> <head_sha> clean-micro [owner/repo]",
          "   → Content-only diff (docs/ with a content extension, or a named root prose file — any tier, no code paths): record-review.sh <PR> <head_sha> clean-low [owner/repo]",
          "   → Standard/complex issue: run the code-review skill (Step 10 records clean on convergence), then",
          "   →   record-review.sh <PR> <head_sha> clean [owner/repo]",
          "   → Emergency: set AGENT_SKIP_REVIEW_GATE=1 (or ELDATO_SKIP_REVIEW_GATE=1) and restart to bypass all gates.",
        ];
    return {
      status: "block",
      reason: lines.join("\n"),
    };
  }
  if (!isAcceptedVerdict(record.verdict)) {
    // #513: two-path remediation — the record's tier is not readable from the
    // record (only the verdict), so both paths are named statically.
    return {
      status: "block",
      reason: [
        `❌ Review record for PR #${pr} has verdict "${record.verdict}" — only ${ACCEPTED_VERDICTS.map((v) => `"${v}"`).join(", ")} unlocks a merge.`,
        "   → Micro issue (complexity:micro): re-record via the micro flow: record-review.sh <PR> <head_sha> clean-micro [owner/repo]",
        "   → Content-only diff (docs/ with a content extension, or a named root prose file — any tier): record-review.sh <PR> <head_sha> clean-low [owner/repo]",
        "   → Standard/complex issue with any code path: run the code-review skill, then record-review.sh <PR> <head_sha> clean [owner/repo]",
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
    //
    // #1348: this path also bypasses the clean-low merge-base binding further
    // down — an unverifiable head means the base cannot be compared either.
    // DECLARED rather than narrowed: the interactive fail-open is #138's
    // decision to make, and clean-low inherits it here exactly as
    // clean/clean-micro do (see the #1348 plan, class C7).
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
    //
    // #1348: EXCEPT clean-low, whose advice must NOT be "re-record at the same
    // verdict". That verdict is a claim about the DIFF's SHAPE, not about
    // reaching a tier through a flow, and a moved head has an unverified shape —
    // the producer's guard refuses (exit 4) as soon as code arrived, so the
    // same-verdict advice is unsatisfiable in exactly the case that fires it.
    // The shape has to be re-derived, not carried forward.
    const reRecordAdvice =
      record.verdict === "clean-low"
        ? "   → The branch moved — the certified diff no longer exists, so the shape must be re-derived: re-check whether the NEW head is still content-only, then re-record with the verdict named explicitly (record-review.sh <PR> <head_sha> clean-low [owner/repo]); if it is no longer content-only, run the code-review skill and record clean (record-review.sh <PR> <head_sha> clean [owner/repo])."
        : `   → The branch moved — re-review the new head and re-record at the same verdict: record-review.sh <PR> <head_sha> ${record.verdict} [owner/repo]`;
    return {
      status: "block",
      reason: [
        `❌ PR #${pr} head has advanced since the review was recorded.`,
        `   Recorded: ${record.head_sha.slice(0, 12)}   Current: ${currentHead.slice(0, 12)}`,
        reRecordAdvice,
      ].join("\n"),
      reasonTag: "head_advanced",
    };
  }
  // #1348 — the clean-low attestation is CONTENT-relative: its guard certifies
  // `compare/<base>...<head>`, whose content is identified by the MERGE BASE.
  // Pinning only the head lets a post-record `gh pr edit --base` swap what
  // merges into main while the head sha still matches and the certified diff
  // stayed docs-only. This is the same hazard the producer guard already closes
  // for `--force-stale`, and the same class of revision binding as the head
  // check above.
  //
  // Why the merge base and NOT `.base.sha`: the base branch's tip moves on every
  // unrelated merge into it while the certified diff is unchanged, so binding the
  // tip would expire every clean-low record within minutes and false-block the
  // very merge the record was minted for. The merge base is invariant under those
  // advances and moves exactly when the base is repointed or rewritten.
  //
  // Scope: clean-low ONLY. clean/clean-micro records carry no merge base (their
  // record shape is unchanged) and their identical base-blindness is
  // pre-existing — filed as agent-infra #1362, not silently widened here.
  //
  // Fail-CLOSED on an unreadable merge base, unlike the interactive #138 head
  // fail-open above: the whole attestation IS the base-relative diff, and
  // clean-low is the cheapest verdict to re-record, so "could not verify" must
  // never read as "certified Low".
  //
  // Unreachable when the HEAD itself is unverifiable: the branch above returns
  // first (fail-closed for a task sub-agent, fail-open for an interactive
  // session), so the #138 interactive fail-open bypasses this binding too —
  // declared in the #1348 plan (C7), not silently claimed away here.
  if (record.verdict === "clean-low") {
    const recordMb =
      typeof record.merge_base_sha === "string" && /^[0-9a-f]{40}$/.test(record.merge_base_sha)
        ? record.merge_base_sha
        : null;
    // Distinguished in the MACHINE tag, not only in the prose: "the attestation
    // was invalidated" and "we could not read it" are different operational
    // events, and the audit trail (gate-events.jsonl) is what reconstructs block
    // rates by reason.
    if (recordMb === null || currentMergeBase === null) {
      return {
        status: "block",
        reasonTag: "base_unverifiable",
        reason: [
          `❌ PR #${pr} carries a clean-low record whose certified merge base cannot be confirmed.`,
          `   Recorded: ${recordMb ? recordMb.slice(0, 12) : "(absent from the record)"}   Current: ${currentMergeBase ? currentMergeBase.slice(0, 12) : "(unreadable)"}`,
          "   clean-low certifies the three-dot diff of the PR's base branch against the head, and",
          "   the merge base is the commit that identifies its content. One side could not be read",
          "   (a gh/API failure, an unreachable fork head, or a hand-minted record).",
          "   → Re-record once the base is readable, naming the verdict explicitly:",
          "   →   record-review.sh <PR> <head_sha> clean-low [owner/repo]",
          "   → If the diff is no longer content-only, run the code-review skill and record clean:",
          "   →   record-review.sh <PR> <head_sha> clean [owner/repo]",
        ].join("\n"),
      };
    }
    if (currentMergeBase !== recordMb) {
      return {
        status: "block",
        reasonTag: "base_advanced",
        reason: [
          `❌ PR #${pr} has a clean-low record certified against a DIFFERENT merge base.`,
          `   Recorded: ${recordMb.slice(0, 12)}   Current: ${currentMergeBase.slice(0, 12)}`,
          "   The PR's base branch was repointed (gh pr edit --base) or rewritten, so the certified",
          "   diff is no longer the diff that would merge — at the SAME head sha.",
          "   → Re-check whether the current diff is still content-only, then re-record with the",
          "     verdict named explicitly:",
          "   →   record-review.sh <PR> <head_sha> clean-low [owner/repo]",
          "   → Otherwise run the code-review skill and record clean:",
          "   →   record-review.sh <PR> <head_sha> clean [owner/repo]",
        ].join("\n"),
      };
    }
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
// block branches (no review record / non-clean verdict / head advanced / merge
// base advanced or unverifiable). The tag is the authoritative source when the
// branch sets one (#1348); this fallback covers the branches that do not, and is
// only reached through logMergeGateDecision when no tag was set.
export function mergeGateBlockReason(record: ReviewRecord | null): string {
  if (!record) return "no_review_record";
  if (!isAcceptedVerdict(record.verdict)) return "verdict_not_clean";
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
      { pr, ...verdict, reason: result.reasonTag ?? mergeGateBlockReason(record) },
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
 * are OPEN GAPS, not safe assumptions. Read this as the authoritative list; if a
 * shape is not matched by the code and not named here, that is a bug in this file,
 * not a safe assumption.
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
 * (A construct-supplied dash such as `-${V:--}admin=true` was on this list in an
 * earlier revision and is now CLOSED by rule 2 below — verified, not assumed.
 * BRACE EXPANSION is closed ONLY in the forms where the expanded word still
 * contains `admin`: `--adm{in,}` is NOT gated, because the expansion also yields
 * `--adm`/`--ad`, which gh rejects, so it never produced an executed merge. Do not
 * read an earlier "brace expansion … CLOSED" wording as wider than this.)
 *
 * #1007 — THE SELECTOR SHAPE. The selector may be a bare number or ONE PR URL
 * (`extractMergeSelector`). A BRANCH selector is NOT resolved and stays a
 * fail-closed block: resolving it needs a `gh` call, i.e. this gate asking the thing
 * it is gating for the identity it is about to check. A QUOTED URL
 * (`gh pr merge "https://…/pull/1" --admin`) still blocks here — this layer does not
 * dequote, exactly as it has never dequoted a `"123"` selector. The argv-level shim
 * sees the URL already dequoted, so those shapes resolve THERE, not here: an
 * over-block at the outer layer, never a bypass. Both directions are pinned in
 * `index.test.ts` ("extractMergeSelector") and `tests/gh-shim/run.sh` §11.
 *
 * A `$VAR`- or `$()`-SUPPLIED FLAG is CLOSED by failing closed: any `$`-bearing
 * ARGUMENT of the merge beyond the position argument makes the command an admin
 * merge, because `V=--admin; gh pr merge 999 $V` reaches gh as an admin merge while
 * no text scan can see the word `admin`. The POSITION argument is exempt (in either
 * quoting form) and a value-flag's value is exempt, so `gh pr merge "$PR" --squash`
 * and `gh pr merge 999 --body "$(cat msg)"` stay outside the gate — the common
 * shapes are NOT over-blocked. Not claimed: that every `$`-bearing later argument
 * really is the flag. A false hit costs a retry; a miss is an unevidenced merge.
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
 *
 * #984 — WHAT LAYERING THE SHIM ON TOP OF THIS CHANGES. The gaps ABOVE are limits
 * of THIS layer, and the CONSTRUCT-SPLICE class among them is now covered by
 * `scripts/gh-shim/gh`, which decides the same question from its own argv, where
 * bash has already finished (`-${V:--}admin=true` IS the literal `--admin` by
 * then); the `tool_call` handler below puts that shim on PATH for every bash call.
 * A scanner cannot resolve `$VAR` without evaluating a shell, which a gate must not
 * do, so the class is covered by a layer that does not share this one's limit
 * rather than by more rules here. This scanner stays as the fast first layer
 * (better messages, no process spawn).
 *
 * NOT COVERED BY EITHER LAYER — do not read the paragraph above as wider than this.
 * These stay open, and are re-stated in the shim's own header: `gh alias` (gh
 * expands the alias AFTER the shim has run), a command that discards the shim's
 * PATH entry (`env -i`, an explicit `PATH=` reset) or calls the real gh by
 * ABSOLUTE path, and argv already expanded in a parent process.
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
  return extractMergeSelector(command).pr;
}

/**
 * The ONE PR-URL shape this gate resolves (#1007):
 * `https://github.com/<owner>/<repo>/pull/<digits>`.
 *
 * The number is IN the token, so accepting a URL does not mean asking `gh` who the
 * PR is. Everything else is refused, and each refusal is deliberate:
 *   - any other host — the host cannot be carried into `--repo`, so the evidence
 *     would be read from a different host's repo;
 *   - `?`/`#` (gh routes `…/pull/1?s=1` to the same PR, but "route-equivalent" is
 *     not "the same string", and this layer must not normalise);
 *   - an extra path segment or trailing `/`;
 *   - a BRANCH name — resolving one needs a `gh` call, i.e. asking the gated thing
 *     for the identity it is about to check. It stays a fail-closed block.
 * This is the SAME shape `scripts/gh-shim/gh::parse_pr_url` accepts, on purpose:
 * the two layers must not disagree about what is a PR (see the parity note there).
 */
const PR_URL_RE = /^https:\/\/github\.com\/([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+)\/pull\/([0-9]+)$/;

export interface MergeSelector {
  pr: number | null;
  /** `owner/repo` when the selector was a PR URL, else null. */
  repo: string | null;
}

/**
 * Split a command segment into the ARGV words gh would see — respecting QUOTES.
 *
 * `scanTokens` splits on whitespace regardless of quoting, which is right for the rules
 * that ask "does the text contain X" and WRONG here: `--body "see <url> here"` is ONE
 * argv value, so a URL inside it is not the selector. A whitespace split leaves that URL
 * as a free token, and the gate would then certify a DIFFERENT PR (in a different repo)
 * than gh merges — a FAIL-OPEN, found by VGATE on #1007's first cycle.
 *
 * An unterminated quote is NOT an error here: the caller's `;`/`&&` segment split is not
 * quote-aware either, so an unterminated region usually means the segment was CUT, and
 * everything after the flag is then one value. Consuming it as one word is what keeps
 * `gh pr merge 123 --admin --body "msg with ; in it"` allowed (the positional is found
 * before the value) while refusing a body-hosted URL standing in for a missing one.
 * BACKSLASHES ARE ALWAYS ESCAPES, in every context — including inside single quotes,
 * where bash has none. That is deliberate, and it is the SAFE direction: it can only
 * keep a quoted region OPEN longer than bash would, never close it EARLIER. Closing
 * early is the only way this function can turn a value's contents into a free token,
 * and a free URL token is what makes the gate certify a different PR (in a different
 * repo) than gh merges. VGATE found that fail-open three times on #1007 — first from a
 * whitespace split, then through `\"` inside a double-quoted value (and the `$'…\'…'`
 * form), then through a NESTED substitution whose inner quotes closed the OUTER region.
 * Over-reading a quote can only REFUSE a command gh would have run, which is the
 * direction this gate is allowed to be wrong in.
 *
 * NESTED REGIONS ARE MODELLED, because a nested region's quotes are INDEPENDENT of the
 * enclosing one: `"$( … " … " …)"` keeps the OUTER quote open across the inner ones,
 * so a URL inside the value never becomes a free token. Levels are tracked per region
 * (`$( … )`, backticks), with backslash escaping inside all of them, and a paren depth
 * so `$((1+2))` and `$( (a) )` close where bash closes them.
 *
 * STILL NOT A SHELL (see the STATED LIMITS above): constructs this cannot model — a
 * `case`-pattern `)` inside `$( … )`, here-docs — could still end a region early. The
 * argv-level shim is the AUTHORITY for exactly this reason; this layer is the fast one,
 * not the correct one.
 */
interface SubLevel {
  kind: "root" | "paren" | "tick";
  q: "'" | '"' | null;
  depth: number;
  /** `case` … `esac` saw no `esac` yet: its pattern `)` must NOT close the region. */
  caseDepth: number;
}

function splitArgvWords(segment: string): string[] {
  const words: string[] = [];
  let cur = "";
  let started = false;
  let word = ""; // the current UNQUOTED word, for `case`/`esac` recognition
  const lv: SubLevel[] = [{ kind: "root", q: null, depth: 0, caseDepth: 0 }];
  for (let i = 0; i < segment.length; i++) {
    const c = segment[i];
    const s = lv[lv.length - 1];
    // A `case` pattern is closed by a BARE `)`, which is not the region's `)`.
    // Without this, `$(case x in y) <url> esac) 123` popped the substitution at the
    // pattern and left `<url>` as a free token — the URL then stood in for the
    // positional (VGATE #1007 cycle 3's sibling).
    const flushWord = () => {
      if (word === "case") s.caseDepth++;
      else if (word === "esac" && s.caseDepth > 0) s.caseDepth--;
      word = "";
    };
    if (s.q === "'") {
      // No escapes in bash's single quotes — but see the header: escaping here can only
      // keep the region open longer, which is the safe direction.
      cur += c;
      if (c === "\\" && i + 1 < segment.length) { cur += segment[++i]; continue; }
      if (c === "'") s.q = null;
      continue;
    }
    if (s.q === '"') {
      cur += c;
      if (c === "\\" && i + 1 < segment.length) { cur += segment[++i]; continue; }
      if (c === '"') { s.q = null; continue; }
      if (c === "$" && segment[i + 1] === "(") {
        flushWord();
        cur += segment[++i];
        lv.push({ kind: "paren", q: null, depth: 1, caseDepth: 0 });
        continue;
      }
      if (c === "`") { flushWord(); lv.push({ kind: "tick", q: null, depth: 0, caseDepth: 0 }); continue; }
      continue;
    }
    // Unquoted AT THIS LEVEL (a `"` opened inside `$( … )` does not quote the outer one).
    if (c === "\\" && i + 1 < segment.length) { flushWord(); cur += c + segment[++i]; started = true; continue; }
    if (c === "'" || c === '"') { flushWord(); s.q = c; cur += c; started = true; continue; }
    if (c === "$" && segment[i + 1] === "(") {
      flushWord();
      cur += segment[++i];
      lv.push({ kind: "paren", q: null, depth: 1, caseDepth: 0 });
      started = true;
      continue;
    }
    if (c === "`") {
      flushWord();
      if (s.kind === "tick") lv.pop();
      else lv.push({ kind: "tick", q: null, depth: 0, caseDepth: 0 });
      cur += c;
      started = true;
      continue;
    }
    if (c === "(" && s.kind === "paren") { flushWord(); s.depth++; cur += c; started = true; continue; }
    if (c === ")" && s.kind === "paren" && s.caseDepth === 0) {
      flushWord();
      s.depth--;
      if (s.depth === 0) lv.pop();
      cur += c;
      started = true;
      continue;
    }
    // Only the ROOT level splits words: a substitution is ONE word to the shell. But
    // whitespace ends a WORD at every level — without that, `case`/`esac` inside a
    // substitution was never recognized and a pattern `)` popped the region early.
    if (/\s/.test(c)) {
      flushWord();
      if (lv.length === 1) {
        if (started) { words.push(cur); cur = ""; started = false; }
      } else {
        cur += c;
      }
      continue;
    }
    word += c;
    cur += c;
    started = true;
  }
  if (started) words.push(cur);
  return words;
}

/**
 * The PR selector of a `gh pr merge`, resolved to `{ pr, repo }` (#1007).
 *
 * ONE token walk serves both the number and the URL's repo, and the walk is
 * quote-aware. Both properties are load-bearing: a raw regex for the repo would also
 * match a URL inside a `--body "…"` value and read the evidence from the WRONG repo,
 * and a whitespace tokenizer would hand that same URL back as if it were the
 * positional. Either one is a FAIL-OPEN (a foreign repo's certificate certifies a merge
 * it was never computed for), not an over-block.
 */
// `gh pr merge`, tolerating a repo pair in ANY gap between the three words
// (`gh -R owner/repo pr merge 123`, `gh pr -R owner/repo merge 123`) — the spellings
// `stripRepoArgs` used to normalise, re-found here in the ORIGINAL text.
//
// ⚠️ The three value alternatives MUST stay DISJOINT and each MUST match at least one
// character. An earlier form (`=\S+|\s+…|\S*`) was ambiguous — `=\S+` and `\S*` both match
// `=a`, and `\S*` matches the EMPTY string — so under the unbounded `(?:\s+REPO_PAIR)*`
// a failing tail enumerated 2^k splits: measured 80 ms at 20 `--repo=` tokens, 1.3 s at
// 26, 5.2 s at 28 and 20.8 s at 30 (~3x per token), on a function that runs on EVERY
// git-shaped bash call — a command-string denial of service in the gate itself
// (code-review P1). Disjoint first characters (`=`, whitespace, neither) make it linear;
// `index.test.ts` pins a time bound so a future edit cannot quietly restore the blowup.
const REPO_PAIR = String.raw`(?:-R|--repo)(?:=\S+|\s+(?:"[^"]*"|'[^']*'|[^\s=]\S*)|[^\s=]\S+)`;
const MERGE_VERB_RE = new RegExp(
  String.raw`\bgh\b(?:\s+${REPO_PAIR})*\s+pr(?:\s+${REPO_PAIR})*\s+merge\b`,
);

export function extractMergeSelector(command: string): MergeSelector {
  // The selector is read from the ORIGINAL text, never from `stripRepoArgs`'s output:
  // that function removes only the first whitespace-delimited word of a value, so a
  // quoted `--repo "see <url> here"` left its TAIL (URL included) as free text and the URL
  // branch below returned that URL as the selector — a wrong-PR AND wrong-repo evidence
  // read (VGATE #1007 cycle 4, P0; a regression the URL feature introduced, since the old
  // `^\d+$`-only walk ignored the leaked URL and found the real positional). The walk
  // skips a `--repo`/`-R` VALUE quote-aware (`valueFlags`), and `MERGE_VERB_RE` re-finds
  // the verb in the original — so `stripRepoArgs` is not needed here at all, and using it
  // only added a way to over-block (a leaked tail hid the verb from the canonical text).
  const verb = matchUnquoted(MERGE_VERB_RE, command, unquotedMask(command));
  if (verb === null) return { pr: null, repo: null };
  const segment = command.slice(verb.index + verb[0].length).split(/;|&&|\|\||\||\n/)[0] ?? "";
  const tokens = splitArgvWords(segment);
  // Every `gh pr merge` flag that takes a VALUE must be here, or its value can be read
  // as the positional. `-A`/`--hostname` were missing (VGATE, #1007 cycle 1), so
  // `gh pr merge -A <url> 123 --admin` resolved to the URL's PR. This set mirrors the
  // shim's `VALUE_FLAGS` (`scripts/gh-shim/gh`) — the two layers must not disagree.
  const valueFlags = new Set([
    "--repo", "-R", "--body", "-b", "--body-file", "-F", "--subject",
    "-t", "--author-email", "-A", "--match-head-commit", "--hostname",
  ]);
  for (let i = 0; i < tokens.length; i++) {
    const tok = tokens[i];
    if (valueFlags.has(tok)) {
      i++; // skip the flag's value
      continue;
    }
    if (/^--[A-Za-z-]+=/.test(tok)) continue; // --flag=value
    if (/^\d+$/.test(tok)) {
      // The SHIM forwards a bare positional to gh as the LITERAL digits, so a value that
      // `Number()` cannot round-trip makes the two layers name different PRs: above 2^53
      // it rounds (`9007199254740993` -> `…992`) and a leading zero normalises
      // (`01006` -> `1006`). This is the same rule the URL digits below already apply,
      // and the same rule the shim applies to both spellings — refuse rather than let the
      // layers disagree about which PR's evidence to read (fresh review, P2).
      const n = Number(tok);
      if (n < 1 || !Number.isSafeInteger(n) || String(n) !== tok || tok.length > 15) {
        return { pr: null, repo: null };
      }
      return { pr: n, repo: null };
    }
    const m = PR_URL_RE.exec(tok);
    if (m) {
      // `Number()` is lossy above 2^53 and maps `01006` → `1006`, while the shim passes
      // the literal digits. Refuse rather than let the two layers disagree about the PR
      // they name (a divergence here is a wrong-PR evidence read, not a cosmetic one).
      const digits = m[3];
      const n = Number(digits);
      // ≤15 digits is the SAME bound the shim applies (`parse_pr_url`): short enough that
      // a JS `Number` is exact, so the two layers can never disagree about which PR the
      // digits name. Over it, `Number` is lossy and the gate would read a different PR's
      // evidence — refuse instead.
      if (n < 1 || digits.length > 15 || !Number.isSafeInteger(n) || String(n) !== digits) {
        return { pr: null, repo: null };
      }
      return { pr: n, repo: `${m[1]}/${m[2]}` };
    }
  }
  return { pr: null, repo: null };
}

/**
 * Evidence must be **non-vacuous**, not merely present (#930 adversarial class
 * 2 — forgery/vacuity). A marker line alone proves nothing: the evidence body
 * must carry the comparison's own counts AND a ZERO residual — `unique to this
 * PR: 0` (the pre-#3756 shape) or `blocked by the decision: 0` beside an empty
 * residual section (the shape the rail emits now). A body computed over an
 * empty or unparsed failing set cannot produce this without the comparison
 * having produced *some* numeric line — but see the
 * `evidenceBodyIsCertifying` docstring for what this honestly cannot prove: a
 * hand-typed line is one `printf` away, so this closes vacuity, not forgery.
 */

/**
 * Classify the body's `final residual` section(s) — the `evidence_list` block
 * whose entries are the residual (BLOCKED ∪ UNATTRIBUTABLE) — as one of
 * `absent` | `empty` | `entries` | `ambiguous` | `silent`.
 *
 * THE SECTION IS THE SEMANTIC ANCHOR (#1429): the rail renders it through
 * `evidence_list`, which prints one `- ` bullet per entry and falls back to its
 * empty text ONLY when the list is empty. So "renders no entry" IS "the residual
 * is zero", however either side words its prose.
 *
 * This is a five-way state, not a boolean, because "no entry in the section" is
 * satisfied by four things that are NOT a measured zero:
 *   absent    — no section at all. A legacy certificate may omit it, but the
 *               current clause must never read absence as a measured zero;
 *   ambiguous — more than one section, an unclosed one, or one whose region is
 *               broken by nesting/an HTML comment (below). A first-match read
 *               would accept an empty decoy placed before the real, bulleted
 *               section (declared threat T2), and the rail always closes its
 *               block, so a missing `</details>` means this is not that block;
 *   silent    — the section exists but states nothing;
 *   entries   — it renders at least one `- ` entry, i.e. a NON-ZERO residual.
 *
 * DELIMITING THE SECTION. The body runs from after the FIRST summary to the
 * FIRST `</details>`, and is refused as `ambiguous` when the region before that
 * close carries `<details` or `<!--`. That closes the T2 variant a
 * first-`</details>` read still allows: a NESTED `<details>…</details>`, or a
 * close hidden inside an HTML comment (`<!-- </details> -->`), ends the region
 * EARLY, so a `- ` entry rendered AFTER it is never seen and the truncated
 * prefix reads as the empty zero. The rail emits neither shape, so refusing both
 * is correct AND fail-closed. Mirrors `scripts/verify-admin-merge-evidence.sh`.
 *
 * ENGINE PARITY. This is the mirror of the jq predicate, which is shipped to
 * `gh --jq` (gojq/RE2) and also run by system `jq` (Oniguruma). Those disagree
 * on `\s`/`\S`/`[[:space:]]` for invisible spaces, so every class here is
 * written out in ASCII (`[ \t\r\n]`, `[!-~]`) to match the jq side exactly.
 * `[!-~]` is the stricter choice: a section carrying only an invisible space is
 * `silent` in every engine, so parity does not cost the refusal.
 *
 * LINEAR on purpose: one `exec`, one `test`, one `indexOf` — no `g`-flag walk and
 * no lazy `[\s\S]*?` capture. This runs once PER MARKER inside the caller's loop,
 * so a hostile 64 KB comment carrying many markers, tags, or summaries must not
 * be able to stall the gate.
 */
const RESIDUAL_SUMMARY = /<summary>[^<]*final residual[^<]*<\/summary>/;
function residualSectionState(
  body: string,
): "absent" | "empty" | "entries" | "ambiguous" | "silent" {
  const first = RESIDUAL_SUMMARY.exec(body);
  if (first === null) return "absent";
  const after = body.slice(first.index + first[0].length);
  if (RESIDUAL_SUMMARY.test(after)) return "ambiguous"; // a second section — never guess which
  const end = after.indexOf("</details>");
  if (end === -1) return "ambiguous"; // unterminated — the rail always closes its block
  const section = after.slice(0, end);
  if (/<details|<!--/.test(section)) return "ambiguous"; // nesting/a hidden close ends it early
  // The section must STATE its emptiness — at least one PRINTABLE ASCII
  // character. NOT `\S`, which is Unicode-aware in JS but ASCII-only in the jq
  // engines: `[!-~]` is engine-independent, and it is the STRICTER choice (a
  // section carrying only an invisible space is `silent` everywhere, so parity
  // costs no refusal). Mirrors the jq predicate's `[!-~]` exactly.
  if (!/[!-~]/.test(section)) return "silent";
  // LINE-ANCHORED list item — `evidence_list` renders `- <entry>` at a line
  // start, and the empty text must stay free to contain a hyphen. The test also
  // covers the OTHER markers GitHub renders as a list item (`* `, `+ `, `1. `):
  // the producer only ever emits `- `, so covering them costs nothing and closes
  // the "the section renders an entry but the gate reads it as empty" surface.
  // This mirrors the jq predicate's `(^|\n)[ \t]*([-*+]|[0-9]+\.)[ \t]`
  // exactly: an unanchored or narrower test on either side makes the two
  // consumers disagree on the same body.
  if (/(^|\n)[ \t]*([-*+]|\d+\.)[ \t]/.test(section)) return "entries";
  return "empty";
}
/** The body's `PR head:` value, lowercased, or null when absent. */
export function evidenceHeadInBody(body: string): string | null {
  const m = /PR head:[ \t\r\n]*([0-9a-fA-F]{7,40})\b/.exec(body);
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
  // THE ZERO RESIDUAL, in EITHER accepted shape (#1429). Both are accepted
  // deliberately: the rail is the PRODUCER and its current clause is the
  // contract, while the legacy clause keeps evidence posted before the #3756
  // rename valid — narrowing the rail back to the obsolete literal would
  // re-legalise the stronger, unsupported `unique to this PR` claim.
  // The `(?=[ \t\r\n]|$)` tail (not `\b`) is what refuses a fractional/numeric
  // continuation like `0.5` or `01`, mirroring the argv-level verifier. The
  // whitespace class is ASCII-explicit for the engine-parity reason above: the
  // jq side is `[ \t\r\n]`, and `\s` here would also swallow U+00A0/U+2000….
  //
  // The residual rule applies WHENEVER a section is PRESENT, whichever clause
  // matched. The pre-#3756 producer also printed its zero as an unconditional
  // literal, so a body that lists residual entries must not be able to certify by
  // choosing the legacy wording instead — that is the same fail-open. A legacy
  // body that omits the section ENTIRELY is still accepted: that is the shape
  // already posted before the rename.
  const legacyZero = /PR failing:[ \t\r\n]*\d+[ \t\r\n]*\|[ \t\r\n]*main failing:[ \t\r\n]*\d+[ \t\r\n]*\|[ \t\r\n]*unique to this PR:[ \t\r\n]*0(?=[ \t\r\n]|$)/;
  const decisionZero =
    /PR failing:[ \t\r\n]*\d+[ \t\r\n]*\|[ \t\r\n]*main failing:[ \t\r\n]*\d+[ \t\r\n]*\|[ \t\r\n]*blocked by the decision:[ \t\r\n]*0(?=[ \t\r\n]|$)/;
  const residualState = residualSectionState(body);
  const zeroResidualCertifies =
    (legacyZero.test(body) && (residualState === "absent" || residualState === "empty")) ||
    (decisionZero.test(body) && residualState === "empty");
  return (
    headNamesTheMarker &&
    zeroResidualCertifies &&
    // The lane is named in the provenance line (`... union of N runs of
    // <lane>:`) — accept it, but never accept a missing provenance line.
    // `.+` (greedy, to the LAST `):`), not `[^:()]+`: a lane may be named by a workflow
    // NAME rather than a file, and `gh` accepts names containing `:` and `(`/`)` —
    // `--workflow 'CI: tests'` and `--workflow 'tests (unit)'` both emitted valid rail
    // evidence that this contract refused, blocking a legitimate merge (cycle-3 review).
    /main compared \(union of \d+ runs?(?: of .+)?\):/.test(body)
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
  "   → Docs-only sets (VGATE content-shape exempt) need a lightweight reviewer dispatch that names the diff and returns a verdict on it — a one-line verdict is enough. The floor counts the dispatch; the dispatch is expected to be a real review that returns a verdict, not a sign-off:",
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

      // #984: the ARGV-LEVEL layer runs FIRST and for EVERY bash call, not only
      // for git ops — the shim has to be on PATH before the command runs, and a
      // command that does not look like a merge to the scanner is exactly the
      // case the scanner cannot decide. The string gates below then act as the
      // fast first layer, unchanged.
      //
      // `rawCommand` is what the CALLER wrote: the injected prefix names the shim
      // path (`…/gh-shim/gh`), so scanning the MUTATED text would feed the gates a
      // `gh` word that the author never wrote.
      const rawCommand = String(event.input.command ?? "");
      const shimDir = activeGhShimDir();
      if (shimDir === null && !ghShimAbsenceWarned && process.env.AGENT_GH_SHIM !== "0") {
        ghShimAbsenceWarned = true;
        console.log(
          "[review-enforcer] ⚠️  #984 argv-level gh shim not found — only the string scanner " +
            "is active, so bash token splicing can still hide an admin merge. " +
            "Set AGENT_GH_SHIM_DIR, or install scripts/gh-shim."
        );
      }
      const shimmed = withGhShim(rawCommand, shimDir);
      if (shimmed !== null) event.input.command = shimmed;

      const command = rawCommand;
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
        // #1348: fetch the merge base ONLY for a clean-low record whose HEAD has
        // already matched — it is the one verdict whose attestation is
        // content-relative, so any other merge must not pay for extra API calls
        // with no reader (null is safe there: the base branch in evaluateMergeGate
        // is clean-low-scoped), and a PR that is going to block on `head_advanced`
        // must not pay two synchronous reads (15s timeout each) whose result no
        // branch reads. A head-mismatched clean-low returns at the head branch,
        // which precedes the base branch.
        const currentMergeBase =
          record && record.verdict === "clean-low" &&
          currentHead !== null &&
          record.head_sha === currentHead
            ? getPrMergeBaseSha(prNumber, currentHead, ctx)
            : null;
        // #285 Fix C: the no-record block message is shape-aware (task
        // sub-agents get the "parent must record the review" variant).
        const result = evaluateMergeGate(
          prNumber, record, currentHead, ctx, isTaskSubAgent(), currentMergeBase
        );
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
