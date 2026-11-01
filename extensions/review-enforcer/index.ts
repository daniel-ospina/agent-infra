import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { isToolCallEventType } from "@earendil-works/pi-coding-agent";
import { execSync, execFileSync } from "child_process";
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
import { redactCommand } from "../shared/redact-command.js";
import {
  attemptClass,
  classifySpawnOutcome,
  describeSpawnCapacity,
  readMachineCapacity,
  spawnFaultClass,
  spawnFaultLabel,
  SPAWN_UNSPAWNABLE_TOKEN,
  type SpawnAttempt,
} from "../shared/spawn-capacity.js";
// #2148 — the reviewer requirement disclosed UP FRONT. The ≥1-dispatch rule and the merge-registry
// gate were both correct and both spoke only at the finish line, so a lane did the whole job (rebase,
// implement, test, push, PR) and was then refused. This module holds the disclosure's ONE wording
// (drift-pinned against the harness's bash helper in extensions/shared/reviewer-preflight.test.ts).
import {
  reviewerPreflightLine,
  reviewerPreflightMessage,
  reviewerFirstPushNotice,
  REVIEWER_PREFLIGHT_RECORD_CMD,
} from "../shared/reviewer-preflight.js";
import type { ReviewerRole } from "../shared/reviewer-preflight.js";
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
      if (isExecutableShim(dir)) return dir;
    } catch {
      /* an unreadable candidate is not a match */
    }
  }
  return null;
}

/**
 * Is `<dir>/gh` present AND EXECUTABLE — i.e. is this directory a shim at all?
 *
 * A PATH entry whose `gh` lacks the execute bit is SKIPPED by the shell, so the real
 * `gh` runs and nothing enforces. `existsSync` answers "is there a file there", which
 * is not the question any caller here is asking: a non-executable shim — an
 * `AGENT_GH_SHIM_DIR` misconfigured, an archive that dropped the mode, a `noexec`
 * mount, or a mid-session `chmod -x` — makes the argv layer silently absent while
 * every `existsSync` check reports it present. The pre-PR code read the datum the same
 * way, but the text gate was still unconditional then, so it was a backstop rather
 * than a fail-open; with the text gate deferring by design, the datum has to mean
 * "will actually run".
 */
export function isExecutableShim(dir: string): boolean {
  try {
    const p = resolvePath(dir, "gh");
    // A regular file, because the shell only runs a regular file: a DIRECTORY named `gh`
    // passes X_OK (search permission) but bash SKIPS the PATH entry — measured on this
    // box: with a directory named `gh` first on PATH, the next candidate ran. Treating
    // it as a shim would defer to a layer that never runs, the exact fail-open this
    // predicate exists to close. `statSync` follows the neutral symlink, which is what
    // the shell does with the path it is given.
    if (!fs.statSync(p).isFile()) return false;
    fs.accessSync(p, fs.constants.X_OK);
    return true;
  } catch {
    return false;
  }
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
  // A non-executable SOURCE is not a shim (see `isExecutableShim`): bash skips such a
  // PATH entry, so installing it would leave the real gh running while every caller
  // believes the argv layer is present. Refuse BEFORE touching the neutral path, so a
  // broken source can never displace a working link. The linked target is NOT re-checked
  // here: the decision point (`ghShimWillEnforce`) re-reads the same datum and fails
  // closed, so a second check could only duplicate it — and would be unreachable apart
  // from a TOCTOU window on the source's mode, i.e. a guard no test could cover.
  if (!isExecutableShim(sourceDir)) return null;
  try {
    fs.mkdirSync(NEUTRAL_GH_SHIM_DIR, { recursive: true });
    const target = resolvePath(NEUTRAL_GH_SHIM_DIR, "gh");
    const src = fs.realpathSync(resolvePath(sourceDir, "gh"));
    const current = fs.existsSync(target) ? fs.realpathSync(target) : null;
    if (current !== src) {
      // SWAP ATOMICALLY. `rm` then `symlink` leaves a window in which the neutral entry is
      // ABSENT — and that entry is machine-global (`~/.pi/agent/shims`), so a bash call in
      // the window (any OTHER session's) finds no `gh` there, falls through to the real gh,
      // and defeats the deferral this install exists to serve (E3 review P2). `rename` over
      // the path replaces it in one step on the same filesystem.
      const staged = resolvePath(NEUTRAL_GH_SHIM_DIR, `.gh.${process.pid}.staged`);
      try {
        fs.rmSync(staged, { force: true });
        fs.symlinkSync(src, staged);
        fs.renameSync(staged, target);
      } catch {
        // No symlinks on this filesystem (or a cross-device rename): fall back to a copy,
        // and drop the staging entry either way so a failure leaves no litter behind.
        try {
          fs.copyFileSync(src, target);
          fs.chmodSync(target, 0o755);
        } catch {
          /* the caller fails closed on a link that is absent or unusable */
        }
        try {
          fs.rmSync(staged, { force: true });
        } catch {
          /* nothing to remove */
        }
      }
    }
    return NEUTRAL_GH_SHIM_DIR;
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
    // for the rest of the session (VGATE #984). One executable-check per bash call —
    // and it must be the EXECUTABLE test, not `existsSync`: a shim that loses its
    // execute bit mid-session is exactly the silent absence this revalidation exists
    // to catch, and `existsSync` reports it present forever.
    if (ghShimDirCache !== null && isExecutableShim(ghShimDirCache)) {
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

/**
 * Will the ARGV-LEVEL layer enforce this command — i.e. may the text gate hand
 * over a read it could only GUESS? (#1776)
 *
 * The scanner and the shim answer the same question from two layers, and #984
 * settled that only the argv layer can answer it: resolving `$VAR`/`$(…)` means
 * EVALUATING a shell, which a gate cannot do without running the command it exists
 * to refuse. `hasAdminMergeFlag` therefore fails CLOSED on anything unresolvable —
 * and that same guess refused an ordinary `gh pr create` whose TITLE contained the
 * word `admin` (`gh pr create --title "fix(admin-merge): x" --body-file "$(mktemp)"`),
 * blocking agent-infra PR #1775 at zero dispatches.
 *
 * DECIDED FROM THE EXTENSION'S OWN STATE, NEVER FROM THE COMMAND TEXT.
 *
 * Reading the answer out of the command text is not a rule this predicate declines to
 * follow — it is not implementable (#984): no spelling test can tell whether the shell
 * will put the shim on PATH for a given command, and a partial blacklist is worse than
 * none because it claims a coverage it does not have. So this asks only two things,
 * both of them ours: is there an argv layer (`AGENT_GH_SHIM`), and is the directory we
 * injected for this call actually a shim (`shimDir`, the SAME value `withGhShim` was
 * given, so the injection and this decision cannot drift; "a shim" means a regular,
 * executable `gh` — a PATH entry the shell skips enforces nothing, see
 * `isExecutableShim`).
 *
 * WHAT IS OUT OF SCOPE, declared rather than implied — both classes are the shim's
 * own STATED LIMITS (`scripts/gh-shim/gh`), and both need the command to hide its flag
 * from the text layer first:
 *
 *   - a discarded PATH entry: `export "PATH"=…`, `env -i`, `sudo`, an absolute path
 *     to the real gh;
 *   - `gh alias` expansion: the argv is `gh <alias> …`, so an alias defined as
 *     `pr merge --admin` is invisible to BOTH layers.
 *
 * Neither is chased with a spelling list, and the boundary is the MERGE: the CALLER
 * defers only the unresolvable FLAG, and keeps this layer's fail-closed decision for any
 * command the text layer reads as a merge (`mergeVerbInText` — a `pr`/`merge` token pair,
 * or a token that blinds the read and sits IN A VERB POSITION: a substitution, brace
 * expansion, a redirection, or a repo-flag value — including an empty quote pair the shell
 * drops — that the token scan consumed with the flag). The first class is therefore
 * bounded by MEASUREMENT rather than by a claim: a command that discards the PATH entry
 * cannot get a merge deferred FOR ANY OF THE SHAPES PINNED IN THE BOUNDARY TEST — a
 * `$VAR`/`$'…'`/`${…}` flag, a brace-expanded verb, an ANSI-C-quoted verb pair, a verb
 * behind a substituted repo value, behind an empty-quoted repo flag, or behind a
 * redirection the shell consumes — each measured as a fail-open when found, each now a
 * test arm. A spelling that still gets a merge past the text layer lands in the second
 * class (an alias is expanded inside gh, after this process has run), and the post-merge
 * detector, not this gate, is the authority of record for both.
 *
 * The DEFERRAL'S OWN PREMISE is operator state, and is a declared limit rather than a
 * chased one: `AGENT_GH_SHIM_DIR` is set by the launcher, never by a command (a command
 * cannot change this process's environment), and pointing it at a directory that holds an
 * executable `gh` which is NOT the shim (a bin directory with the real gh) makes "the argv
 * layer is present" true in name only — the same class as `AGENT_GH_SHIM=0`, and visible
 * for the same reason: both are the operator's own switches.
 */
export function ghShimWillEnforce(shimDir: string | null): boolean {
  // Both halves are OURS and both must hold: the layer is switched on, AND the
  // directory we injected contains an EXECUTABLE `gh`. A PATH entry the shell skips
  // — missing, unreadable, or without the execute bit — enforces nothing, so
  // deferring to it would be a silent fail-open. Checking it HERE as well as in
  // `resolveGhShimDir`/`materializeGhShim` is deliberate: this is the decision point,
  // and a guard whose certainty rests on a caller's invariant is one refactor away
  // from certainty it no longer has. Cheap — the caller short-circuits on
  // `isAdminMergeCommand` first, so this runs only for admin-merge-class commands.
  return process.env.AGENT_GH_SHIM !== "0" && shimDir !== null && isExecutableShim(shimDir);
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
 * #2148 — the EARLY moment: the first `git push` (or `gh pr create`) of a session. That is where the
 * lane has just produced the artifact a reviewer will read, so the requirement can still be acted on
 * for the price of one dispatch instead of a whole re-run.
 *
 * Deliberately narrower than `isGitOp`: `git commit` is not this moment (a lane may commit many times
 * before a PR exists), and a push is what makes the head reviewable.
 *
 * ⛔ QUOTED DATA IS MASKED FIRST — this is a NOTICE with a once-per-session budget, not a gate, and
 * a false fire SPENDS that budget before the real push. The first version matched the raw text, so
 * `echo "run git push now"` and `git commit -m "wip: git push pending"` both fired (measured by a
 * fresh review) while the suite's single-quote fixture passed only because the closing quote abutted
 * the word. `unquotedMask` is the shared parser's own mask (#966), so this cannot drift from what
 * `isAdminMergeCommand` considers quoted data.
 */
const GIT_PUSH_PATTERN = /(^|\s)git\s+push(?=\s|$)/;
const GH_PR_CREATE_PATTERN = /(^|[\s;&|(){!])gh\s+pr\s+create(?=\s|$)/;

/** Blank out quoted spans (the mask keeps indices stable) so a mention cannot fire the notice. */
function unquotedOnly(command: string): string {
  const mask = unquotedMask(command);
  let out = "";
  for (let i = 0; i < command.length; i++) out += mask[i] ? command[i] : "\u0000";
  return out;
}

/**
 * Blank out HEREDOC BODIES (and their terminator) so a `git push` written into a commit message or a
 * note file cannot fire the notice.
 *
 * ⛔ `unquotedMask` models quotes only — a heredoc body is DATA, not a command, and the mask cannot
 * see it. Measured on this change: `git commit -F - <<'MSG' … git push … MSG` and
 * `cat >> NOTES.md <<'EOF' … git push … EOF` both read as a push, and because the notice has a
 * ONCE-PER-SESSION budget, the mention SPENT it — so the lane's real push got no notice at all. That
 * is the failure the mask was added to prevent, one construct over (fresh review, P2).
 *
 * Deliberately conservative: a heredoc whose terminator is not found, or an unterminated one, is
 * left ALONE (the notice may then fire early — it is a notice, never a block, and a spurious extra
 * line is cheaper than a spurious silence).
 *
 * ⛔ `<<<WORD` IS A HERE-STRING, NOT A HEREDOC, AND MUST NOT OPEN A BODY HERE (fresh review). The
 * opener regex reads the SECOND and THIRD `<` of `<<<WORD` as `<<` + word, so a `read -r x <<<MSG`
 * line used to start a body hunt for a later line equal to `MSG` — and if that line existed, the
 * lines between them (REAL commands, possibly the push) were blatted away. That direction is the
 * one the paragraph above calls the worst one: a MISSED notice, i.e. silence. The `(?<!<)` guard
 * rejects a `<<` that is itself the tail of `<<<`.
 * Gating is unaffected: this is applied by `isPushOrPrCreateCommand` only, which no gate consults.
 */
export function stripHeredocBodies(command: string): string {
  const lines = command.split("\n");
  const out: string[] = [];
  // The SAME carried state `maskHeredocData` uses (#1382 review cycle 1, P2): without it this path
  // read a `<< n` on an arithmetic continuation line as an opener and dropped a real `git push`
  // after it — behaviour inherited from the old regex, but it contradicted the "ONE opener reader"
  // claim in `heredocOpenersIn`, and an invariant the code does not keep is how the next reader
  // deletes the fix.
  const state: HeredocScanState = { quote: null, arith: 0, bare: 0, bareStack: [] };
  for (let i = 0; i < lines.length; i++) {
    const openers = heredocOpenersIn(lines[i], state);
    if (openers.length === 0) {
      out.push(lines[i]);
      continue;
    }
    const stripTabs = openers[0].stripTabs;
    const word = openers[0].delim;
    // KEEP THE OPENING LINE WHOLE, drop the body and the terminator. The whole line is bash COMMAND
    // syntax — text after the redirect (`<<'MSG' && git push`) is still the command — so cutting at
    // the token dropped a real push that followed it on the same line, and a quoted `<<EOF` earlier
    // on the line lost its closing quote, which masked away a real push further along (fresh review,
    // P2). The truncation was a bug in the first version of this helper.
    //
    // STATED RESIDUAL: two heredocs opened on ONE line (`cat <<'A' > x <<'B'`) — only the first is
    // stripped, so `B`'s body is still scanned. No lane writes that, and the failure direction is a
    // NOTICE that may fire a little early, never a gate decision (no gate consults this function).
    out.push(lines[i]);
    let j = i + 1;
    let closed = false;
    for (; j < lines.length; j++) {
      const probe = stripTabs ? lines[j].replace(/^\t+/, "") : lines[j];
      if (probe === word) {
        closed = true;
        break;
      }
    }
    if (!closed) {
      // Unterminated: keep the remainder as it was (never silently drop a command).
      for (let k = i + 1; k < lines.length; k++) out.push(lines[k]);
      return out.join("\n");
    }
    i = j; // skip body + terminator; the loop's ++ moves past the terminator
  }
  return out.join("\n");
}

export function isPushOrPrCreateCommand(command: string): boolean {
  const text = unquotedOnly(stripHeredocBodies(command));
  return GIT_PUSH_PATTERN.test(text) || GH_PR_CREATE_PATTERN.test(text);
}

/** One heredoc redirect found on a line. */
export interface HeredocOpener {
  /** The delimiter word, quotes already removed (`EOF`, `MSG`, `E-O-F`). */
  delim: string;
  /** `<<-`: leading TABS are stripped from the body and the terminator. */
  stripTabs: boolean;
}

/**
 * EVERY heredoc opener on one line, read QUOTE-, COMMENT- and ARITHMETIC-aware.
 *
 * ONE opener reader for the whole file: `stripHeredocBodies` (the #2148 notice) and
 * `maskHeredocData` (the admin-merge gate's data model) both take their openers from here, so the
 * two cannot disagree about which body exists — the drift this file keeps re-learning (two
 * predicates, two answers). Ported from `extensions/main-worktree-guard/index.ts`
 * (`_wtMaskHeredocBodies`), where four review rounds closed exactly these shapes; the reasons are
 * kept with the code because each one was a measured defect, not a hypothetical:
 *
 *  - `<<` inside a QUOTED string or after a `#` comment is not a redirection (`echo "a << EOF"`
 *    must not blank the rest of the command);
 *  - `$(( 8 << n ))` is a SHIFT, not a heredoc — arithmetic depth is tracked (and, by
 *    `maskHeredocData`, carried ACROSS lines, because an arithmetic expression may span them);
 *  - `<<<WORD` is a HERE-STRING: an opener starts at the FIRST `<` of a `<` run, so none of the
 *    three `<` may be read as a heredoc and no body may be hunted for;
 *  - the delimiter is a SHELL WORD, so `<<1`, `<<9EOF` and `<<E-O-F` are legal (an
 *    identifier-only regex never saw them, and their bodies were then scanned as commands);
 *  - SEVERAL openers on one line (`cat <<A > x <<B`) have their bodies in opener order, so all of
 *    them are returned; masking only the first left the second body readable.
 *
 * A `$`/backtick/backslash delimiter is EXPANDED by the shell at run time, so its terminator cannot
 * be known statically: those are refused here and the body stays unmasked (fail-closed), exactly as
 * before.
 */
export function heredocOpenersIn(line: string, state?: HeredocScanState): HeredocOpener[] {
  const hits: HeredocOpener[] = [];
  // ⛔ QUOTE STATE IS CARRIED ACROSS LINES (#1382 review cycle 1, P1 — verified: `echo "start` …
  // `cat <<'EOF'` … `end"` is a quoted STRING to bash, but a fresh per-line state read the middle
  // line as an opener and blanked every real command after it). A quoted string may span lines in
  // bash, so a caller scanning a WHOLE command passes `state`, and this function resumes inside the
  // string it left open.
  let quote: string | null = state?.quote ?? null;
  let atWordStart = true;
  // Depth of `$(( … ))` / `(( … ))` on THIS line, where `<<` can only be a SHIFT. `state` carries
  // it across lines for a caller that masks a WHOLE command: an arithmetic expression may span
  // lines, and a continuation line starting `<< n ))` would otherwise be read as an opener with
  // delimiter `n` — whose body never ends, blanking the rest of the command (a fail-OPEN, the one
  // direction this file may not be wrong in).
  let arith = state?.arith ?? 0;
  let bare = state?.bare ?? 0;
  const bareStack: number[] = state?.bareStack ?? [];
  for (let c = 0; c < line.length; c++) {
    const ch = line[c];
    if (quote) {
      if (ch === "\\" && quote === '"') {
        c++;
        continue;
      }
      if (ch === quote) quote = null;
      continue;
    }
    if (ch === "'" || ch === '"') {
      quote = ch;
      atWordStart = false;
      continue;
    }
    if (ch === "\\") {
      c++;
      continue;
    }
    if (ch === "#" && atWordStart) break; // comment: no redirection after it
    if (ch === "$" && line[c + 1] === "(" && line[c + 2] === "(") {
      bareStack.push(bare);
      bare = 0;
      arith++;
      c += 2;
      atWordStart = false;
      continue;
    }
    if (ch === "(" && line[c + 1] === "(") {
      bareStack.push(bare);
      bare = 0;
      arith++;
      c++;
      atWordStart = false;
      continue;
    }
    if (arith > 0 && ch === "(") {
      bare++;
      atWordStart = false;
      continue;
    }
    if (arith > 0 && ch === ")") {
      if (bare === 0 && line[c + 1] === ")") {
        arith--;
        bare = bareStack.pop() ?? 0;
        c++;
        atWordStart = false;
        continue;
      }
      if (bare > 0) bare--;
      atWordStart = false;
      continue;
    }
    // An opener is the FIRST `<` of its run, and never a `<<<` here-string.
    if (arith === 0 && ch === "<" && line[c + 1] === "<" && line[c + 2] !== "<" && line[c - 1] !== "<") {
      const stripTabs = line[c + 2] === "-";
      // The delimiter is the WHOLE shell WORD, which bash builds by CONCATENATION: `<<'E''OF'`,
      // `<<'EOF'x` and `<<E"OF"x` are one word. Reading only the first quoted/unquoted segment (the
      // first cut of this reader) produced a terminator that is a strict PREFIX of bash's, so the
      // body search never ended, the mask ran to end of command, and every REAL command after the
      // shell's true terminator became invisible — a fail-OPEN the reviewer measured (`cat <<'EOF'x`
      // … `EOFx` … two admin merges → ALLOWED, where the pre-change text BLOCKED).
      const word = heredocDelimiterWord(line, c + 2 + (stripTabs ? 1 : 0));
      if (word !== null) hits.push({ delim: word, stripTabs });
    }
    atWordStart = /\s/.test(ch);
  }
  if (state) {
    state.quote = quote;
    state.arith = arith;
    state.bare = bare;
    state.bareStack = bareStack;
  }
  return hits;
}

/**
 * The heredoc DELIMITER as the shell builds it: ONE word, assembled from every quoted and unquoted
 * segment (`'E''OF'` → `EOF`, `'EOF'x` → `EOFx`, `E"OF"` → `EOF`).
 *
 * Returns null when the word cannot be resolved STATICALLY — it contains a `$` or a backtick (the
 * shell EXPANDS the delimiter at run time, so the terminator is unknowable) or a backslash escape
 * (bash removes it, so the literal word is not the delimiter either). Null means "no opener": the
 * body stays READABLE, which is the fail-closed direction. No opener is recorded rather than a
 * guessed one, because a guessed delimiter that is a PREFIX of the real one masks to end of command
 * and hides real commands — the fail-OPEN this reader exists to prevent.
 */
function heredocDelimiterWord(line: string, from: number): string | null {
  let i = from;
  while (i < line.length && (line[i] === " " || line[i] === "\t")) i++;
  let word = "";
  while (i < line.length) {
    const ch = line[i];
    if (ch === "'") {
      const end = line.indexOf("'", i + 1);
      if (end === -1) return null;
      word += line.slice(i + 1, end);
      i = end + 1;
      continue;
    }
    if (ch === '"') {
      const end = line.indexOf('"', i + 1);
      if (end === -1) return null;
      const inner = line.slice(i + 1, end);
      // A `$`/backtick inside double quotes is still an EXPANSION.
      if (/[$`]/.test(inner)) return null;
      // ⛔ A BACKSLASH INSIDE DOUBLE QUOTES MAKES THE WORD UNKNOWABLE (#1382 review cycle 2, P0).
      // Bash removes it only before ``$\`"\\`` and newline (`<<"E\OF"` keeps `E\OF`); the previous
      // line removed it before ANY character and produced the delimiter `EOF`, which never matches
      // bash's terminator — so the mask ran to end of command and hid every real command after it
      // (measured: two admin merges ALLOWED). Resolving bash's exact rule is possible but pointless:
      // the body is only ever MASKED as an optimisation, so an escape here returns null (body
      // readable, fail-closed) instead of risking a second, subtler disagreement with the shell.
      if (inner.includes("\\")) return null;
      word += inner;
      i = end + 1;
      continue;
    }
    if (ch === "\\") return null; // an escape bash removes: the literal word is not the delimiter
    // ⛔ ONLY blanks and metacharacters END the word — `\r` is a WORD character to bash (#1382
    // cycle-3 hardening). With `\s` here, a CRLF opener (`… <<'EOF'\r`) read the delimiter as `EOF`
    // while bash's is `EOF\r`, so the terminator never matched and the mask ran to end of command.
    if (/[\n \t;&|<>()]/.test(ch)) break;
    if (ch === "$" || ch === "`") return null; // expanded at run time
    word += ch;
    i++;
  }
  return word === "" ? null : word;
}

/** Carried scan state for a caller reading a WHOLE command line by line. */
export interface HeredocScanState {
  /** An UNCLOSED quote character carried across lines (a quoted string may span them). */
  quote: string | null;
  arith: number;
  bare: number;
  bareStack: number[];
}

/**
 * Commands whose STDIN is DATA: they consume a heredoc body without executing it, so the body is
 * prose (a file's contents, a commit message, a report) and never a command.
 *
 * THE LIST IS SHAPED SO ITS FAILURE DIRECTION IS A REFUSAL: a consumer that is not here keeps its
 * body READABLE (fail-closed, so an unknown command may still be scanned as before), and every
 * entry must be a program that cannot run its stdin as code. That is why `sed`/`awk`/`ed`/
 * `python`/`perl`/`node`/`xargs`/`eval`/`source` are ABSENT (each can execute text), and why `git`
 * is handled separately and narrowly below.
 */
const HEREDOC_STDIN_DATA_CONSUMERS = new Set([
  "cat", "tee", "wc", "head", "tail", "grep", "egrep", "fgrep", "sort", "uniq", "cut", "tr",
  "nl", "rev", "tac", "paste", "fold", "expand", "unexpand", "strings", "od", "xxd", "base64",
  "md5sum", "sha1sum", "sha256sum", "shasum", "cksum", "file", "column", "comm", "join", "diff",
  "jq", "less", "more",
]);

/**
 * Commands that can only NAME a file: they neither run it nor hand it to something that can.
 *
 * ⛔ SEPARATE FROM `HEREDOC_STDIN_DATA_CONSUMERS`, which answers a different question (what may
 * CONSUME a heredoc body). `ls` does not read stdin at all, so listing it there would be a category
 * error — but `ls *.md` after `cat >> notes.md <<'EOF'` is one of the most common lane sequences
 * there is, and without it the glob arm reports the write-then-list shape as "written then executed"
 * and the reported prose refusal comes back (measured in this change's own final probe). Every entry
 * here can only display, stat or test a name: none of them can run a file's CONTENTS.
 */
const HEREDOC_FILE_NAMING_ONLY = new Set([
  ...HEREDOC_STDIN_DATA_CONSUMERS,
  "ls", "stat", "du", "readlink", "realpath", "dirname", "basename", "echo", "printf", "test", "[",
  // Filesystem MOVERS: they name a file, they never run its contents. Without these, the glob arm's
  // basename match made the ordinary write-then-clean-up sequence (`cat >> notes.md <<'EOF'` …
  // `rm *.md`) a "written then executed" refusal — the reported prose false positive returning from
  // the other side (#1382 cycle 11 review, P2). `chmod` is here too: it cannot run a file, and the
  // `chmod +x f; ./f` shape is caught by the SECOND segment's command word.
  "rm", "mv", "cp", "find", "touch", "mkdir", "chmod", "ln",
]);

/**
 * Is the reader at `word` SHADOWED anywhere in the command — by an alias, a function, or a `NAME=`
 * assignment — so that the word no longer names the program we proved it was?
 *
 * ⛔ DEQUOTED, not spelled. Measured on the sibling change (#1382 cycle 8): `alias c\at=bash` and
 * `alias c"a"t=bash` define `cat` as `bash`, and a scan that matched the SPELLING `cat` saw neither
 * — the body was masked while bash executed it. The text is dequoted first, so every spelling of
 * the name is considered; over-matching here only costs a refusal (the body stays readable).
 */
function heredocReaderIsShadowed(text: string, word: string): boolean {
  const w = word.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const dequoted = text.replace(/["'\\]/g, "");
  const anchored = (body: string) => new RegExp(`(^|[\\s;&|])${body}`);
  return (
    anchored(`alias\\s+${w}\\s*=`).test(dequoted) ||
    anchored(`function\\s+${w}\\b`).test(dequoted) ||
    anchored(`${w}\\s*\\(\\)`).test(dequoted) ||
    anchored(`${w}=`).test(dequoted)
  );
}

/**
 * The FILE PATHS a heredoc-opening line may write its body to: every `>`/`>>` redirect target, and
 * every non-flag argument of `tee`.
 *
 * WHY THIS EXISTS. Masking a body is sound only while the body cannot be EXECUTED. A body written
 * to a file and run by a LATER line of the SAME command is executable in one more step than the
 * `cat > x.sh <<'EOF' … EOF && bash x.sh` shape (which rule (1) already refuses) — and there the
 * file's name appears again as a word, which is the one thing that can be checked statically:
 *
 *   cat > /tmp/x.sh <<'EOF'
 *   gh pr merge 999 --admin
 *   EOF
 *   bash /tmp/x.sh
 *
 * Before masking, that body was scanned (over-broad, but it caught this). So a target that
 * reappears on a line that can EXECUTE a file — after an interpreter/runner word, or as that
 * line's own COMMAND WORD — is treated as unprovable and the body STAYS READABLE. A refusal, the
 * direction this file is allowed to be wrong in, and narrow on purpose: a target that recurs in a
 * plain command (`git add CHANGELOG.md` after `cat >> CHANGELOG.md <<'EOF'`, the most common lane
 * sequence there is) executes nothing, so it must not bring the prose refusal back. The argv layer
 * (#984) would catch the execution anyway; not relying on that is the point, because the residual
 * must not be silent.
 */
/**
 * The COMMAND WORD of a heredoc-opening line — its reader name as bash would resolve it, with the
 * opener and everything after it cut off and every quote removed (`c"a"t <<'EOF'` → `cat`,
 * `cat<<'EOF'` → `cat`).
 *
 * ⛔ FULLY DEQUOTED, edges and interior alike (#1382 review cycle 1, P2): stripping only the edges
 * left `c"a"t` and `c\at` unrecognised as the data consumer they are, so a two-merge PROSE body
 * under them was still refused — the exact false positive this change exists to remove.
 */
function heredocCommandWord(line: string): string {
  const head = line.replace(/<<-?[\s\S]*$/, "");
  const first = head.trim().split(/\s+/)[0] ?? "";
  return first.replace(/["'\\]/g, "");
}

/**
 * The `git` subcommands that can only NAME a file — never run one. Everything else (`bisect run`,
 * `rebase --exec`, `submodule foreach`, `-c alias.x=!sh`, …) may EXECUTE the target, so an unknown
 * subcommand is treated as an executor: the body stays readable, which is the refusal direction.
 */
const GIT_FILE_NAMING_SUBCOMMANDS = new Set([
  "add", "rm", "mv", "status", "diff", "log", "show", "commit", "push", "fetch", "pull",
  "checkout", "switch", "restore", "stash", "reset", "revert", "cherry-pick", "clone", "apply",
  "tag", "branch", "remote", "blame", "grep", "ls-files", "rev-parse", "describe", "merge-base",
  "worktree", "notes", "config", "cat-file", "hash-object",
]);

/** Would `line` EXECUTE the file named `target`?
 *
 * ⛔ SUBSTRING, not whole word, and the FIRST word decides (#1382 review cycle 1, P2 + cycle-2
 * hardening). Three runner spellings bash ran were missed by a whole-word runner list — `bash x`,
 * `. /tmp/x.sh` (POSIX dot-source) and `"$SHELL" /tmp/x.sh` — and so was `BASH_ENV=/tmp/x.sh` written
 * on a LATER line: a list of executor words cannot be complete. So any line that MENTIONS the target
 * may be running it, except a `git` line whose subcommand can only name a file. The over-refusal cost
 * is paid only by a command that writes a file and then merely mentions it outside git (`cat >> X` …
 * `grep X`), which is rare; the ordinary `cat >> CHANGELOG.md` … `git add CHANGELOG.md` sequence
 * stays masked, which is the case that would otherwise bring the reported false positive back.
 */
function heredocLineExecutes(
  line: string,
  target: string,
  scope = line,
  // ⛔ AN EXTRA NAMING VOCABULARY, for the ONE caller that asks a narrower question
  // (`withoutQuotedHeredocBodies`, the tracker-write CLASSIFICATION mask). Undefined for every other
  // caller, so `maskHeredocData`'s answer is unchanged to the byte — the proven over-refusal ("any
  // mention may be execution") is the default and stays that way.
  extraNaming?: ReadonlySet<string>,
): boolean {
  // ⛔ A PROCESS SUBSTITUTION RUNS A PROGRAM WITH THE TARGET AS ITS STDIN (#1382 cycle 10 review, P0 —
  // measured: `cat /tmp/x.sh > >(bash)` executes the file and contains NO `|` at all, so the pipe arm
  // never fired). `<(…)`/`>(…)` is a handle to the named file exactly like a pipe is, so a line that
  // names the target AND carries one is treated as executing it.
  if (/[<>]\(/.test(line) && heredocNamesTarget(line, target)) return true;
  // FIND RUNS WHAT IT FINDS, so the target need not be named on the line (#1382 cycle 12 review, P0 —
  // measured: `find . -execdir bash {}` masked the body, and `find` searches a TREE, so the written
  // file may never appear by name). A NON-runner exec (`-exec rm {}`) is still naming, which is why
  // the program word decides rather than the primary alone.
  {
    const prog = heredocFindExecProgram(line);
    if (prog !== null && heredocWordIsProgram(prog)) return true;
  }
  // ⛔ EVERY SEGMENT, not the whole line (#1382 review cycle 2, P1): `git status >/dev/null; bash
  // /tmp/r.sh` starts with `git`, so a whole-line command-word test ruled the LINE a naming command
  // and the body was masked while bash ran the file. A separator starts a new command, so each
  // segment is judged on its OWN first word — and a GLOB is a mention too (`. /tmp/g1.*`), which is
  // why the mention test lives INSIDE the loop rather than before it.
  //
  // ⛔ A READER THAT NAMES THE FILE MAY STILL RUN IT, ONE PIPE LATER (#1382 cycle 9 review, P0 —
  // measured fail-open introduced by the reader exemption below). `heredocSegmentIsNaming` proves
  // the READER cannot execute its argument, and the first version concluded the LINE could not
  // either. That is false: the reader's own STDOUT is a handle. `cat > /tmp/x.sh <<'EOF' … EOF`
  // followed by `cat /tmp/x.sh | bash` (or `| sh`, `| xargs … sh -c {}`) writes the body to a file
  // and runs it, while the only segment naming the target starts with `cat` — so the body was
  // masked and main refused the same command. The pipe is judged on the RAW line, before the
  // separator split, because the split discards exactly the `|` that carries the meaning.
  const pipedIntoProgram = heredocPipedIntoProgram(line);
  for (const segment of line.split(/[;|&]+/)) {
    if (!heredocNamesTarget(segment, target) && !heredocGlobMentions(segment, target)) continue;
    if (pipedIntoProgram) return true;
    if (!heredocSegmentIsNaming(segment, scope, extraNaming)) return true;
  }
  return false;
}

/** Does this word name a PROGRAM that can run text handed to it? The ONE vocabulary shared by the
 *  pipe arm and the `find -exec` arm, so the two cannot disagree. */
function heredocWordIsProgram(w: string): boolean {
  if (!w) return false;
  return (
    STDIN_PROGRAM_RUNNERS.has(w) ||
    STDIN_PROGRAM_INTERPRETER_RE.test(w) ||
    /(^|\/)(?:sh|bash|zsh|dash|ksh|ash|mksh|oksh)$/.test(w)
  );
}

/** The word after `find`'s exec primaries (`-exec`, `-execdir`, `-ok`, `-okdir`), or null. */
function heredocFindExecProgram(line: string): string | null {
  const words = line.trim().split(/\s+/).map((w) => w.replace(/["'\\]/g, ""));
  for (let i = 0; i < words.length; i++) {
    if (/^-(exec|execdir|ok|okdir)$/.test(words[i]) && words[i + 1]) return words[i + 1];
  }
  return null;
}

/** Is any stage AFTER the first of this line's pipeline a PROGRAM RUNNER (`… | bash`,
 *  `… | sh -s`, `… | python3`, `… | xargs … sh -c {}`)?
 *
 *  Reuses `STDIN_PROGRAM_RUNNERS` / `STDIN_PROGRAM_INTERPRETER_RE` — the same vocabulary
 *  `dataCharMask`'s `pipedIntoRunner` uses — so the two cannot disagree about what a program is.
 *  A bare `||` is a FALLBACK, not a pipe: its right-hand side never receives the left's stdout.
 *
 *  ⛔ "THE SAME VOCABULARY" IS NOT "THE SAME PREDICATE" (#1382 cycle 10 review, P2 — corrected):
 *  `pipedIntoRunner` accepts a WRAPPER word only when the word after it is a `STDIN_PROGRAM_RUNNERS`
 *  member, while this function also accepts an interpreter or a path-spelled shell one word along
 *  (`| env python3` is a runner here, data there). Today THIS side is the stricter one, so nothing
 *  is open — but a reader who "unifies" them by copying `pipedIntoRunner`'s wrapper arm would
 *  re-open `| env python3` on a body that python then executes. Narrowing this one to match is not
 *  a simplification; it is a fail-open. */
function heredocPipedIntoProgram(line: string): boolean {
  // ⛔ SHELL GROUPING IS NOT PART OF THE PROGRAM NAME (#1382-c9 review, measured): a downstream stage
  // written `(bash)`, `( bash )` or `{ bash; }` runs bash, and the first version compared the raw word
  // `(bash)` against the runner sets, missed it, and MASKED the body — a fail-open on the same shape
  // the pipe rule exists to catch. Leading `(`/`{`/`!` and trailing `)`/`}`/`;` are stripped before
  // the comparison. Only the FIRST word is de-grouped, not every word: matching any word in the
  // stage would re-break the ordinary `cat x.md | grep -i "sh"`, which is the false positive this
  // whole change removes.
  const deGroup = (w: string) => w.replace(/^[({!]+/, "").replace(/[)};]+$/, "");
  const isRunner = heredocWordIsProgram;
  // ⛔ A TOKEN BEFORE THE PROGRAM HIDES IT (#1382 cycle 10 review, P0 — measured: `| FOO=1 bash` and
  // `| 2>/dev/null bash` both executed the written file while the body stayed masked). An assignment
  // prefix and a leading redirection are both ordinary spellings, so they are SKIPPED — never the
  // whole tail of the stage (see the grouping note above: that is what re-breaks `| grep -i "sh"`).
  const isPrefixToken = (w: string) => /^[A-Za-z_][A-Za-z0-9_]*=/.test(w) || /^\d*[<>]/.test(w) || w === "!";
  const stages = line.split(/(?<!\|)\|(?!\|)/);
  for (let i = 1; i < stages.length; i++) {
    // `|&` is a pipe with stderr folded in — the `&` is not a command word.
    const words = stages[i].trim().replace(/^&\s*/, "").split(/\s+/).map((w) => w.replace(/["'\\]/g, ""));
    let k = 0;
    while (k < words.length && isPrefixToken(words[k])) k++;
    const first = deGroup(words[k] ?? "");
    // `{ bash; }` — the first WORD is nothing but grouping, so the program is the NEXT word. This
    // second look happens ONLY when the first word de-grouped to nothing; testing every word of a
    // stage instead would make the ordinary `cat x.md | grep -i "sh"` a program runner and bring
    // back the false positive this change exists to remove.
    if (!first) {
      let n = k + 1;
      while (n < words.length && isPrefixToken(words[n])) n++;
      if (isRunner(deGroup(words[n] ?? ""))) return true;
      continue;
    }
    if (isRunner(first)) return true;
    // A wrapper word can hide the program one word along (`| env FOO=1 bash`, `| nice -n 5 sh`).
    if (/(^|\/)(?:env|exec|command|nohup|nice|timeout|setsid|stdbuf|su|doas)$/.test(first)) {
      for (const w of words.slice(k + 1)) {
        const bare = deGroup(w);
        if (!bare || isPrefixToken(bare) || bare.startsWith("-")) continue;
        if (isRunner(bare)) return true;
      }
    }
  }
  return false;
}

/** A path as WRITTEN, normalized textually: `./a//b/./c` and `a/b/c` are the same file, and this
 *  function makes them the same STRING. No filesystem access — the shell may not have run yet. */
function heredocNormalizePath(p: string): string {
  const abs = p.startsWith("/");
  const parts: string[] = [];
  for (const seg of p.split("/")) {
    if (seg === "" || seg === ".") continue;
    if (seg === "..") {
      parts.pop();
      continue;
    }
    parts.push(seg);
  }
  return (abs ? "/" : "") + parts.join("/");
}

/** Does any word in `text` NAME `target` the file?
 *
 *  ⛔ NORMALIZED, NOT SUBSTRING (#1382 cycle 9 review, P0 — second measured fail-open introduced by
 *  the first version). Comparing the raw redirect target to the raw later word missed every spelling
 *  that reaches the SAME file: `cat > ./rq.sh …` then `bash rq.sh`; `cat > /tmp/x.sh …` then
 *  `cd /tmp; bash x.sh`; `bash /tmp//x.sh`; `bash /tmp/./x.sh`. Each was masked at the fix and
 *  refused by main. So the BASENAME counts as a form too: a `cd` or a `./` prefix changes the word
 *  without changing the file. Over-matching only keeps a body readable (a refusal), which is the
 *  direction this file is allowed to be wrong in. */
function heredocNamesTarget(text: string, target: string): boolean {
  // ⛔ THE RAW SUBSTRING IS KEPT, on purpose, and it is not redundant with the word walk below: a
  // path can hide inside a word that no path normalization reaches — `BASH_ENV=CHANGELOG.md bash -c
  // true` names the file with an assignment prefix, and the normalized word comparison missed it
  // (measured: an existing suite case went red within this change). Over-matching only keeps a body
  // readable, which is a refusal, so the crude arm stays and the normalized arms are added ON TOP.
  if (text.includes(target)) return true;
  // ⛔ `~` / `$HOME` ARE THE SAME DIRECTORY, and on this fleet's macOS default the filesystem is
  // case-INSENSITIVE (#1382 cycle 10 review, P2 — measured ALLOWED: `cat > ~/x.sh … bash $HOME/x.sh`,
  // and `bash /tmp/X.SH` for `/tmp/x.sh`). Both sides are expanded to a placeholder home and folded
  // to lower case before comparison; over-matching is a refusal here, the allowed direction.
  const canon = (p: string) =>
    heredocNormalizePath(
      p
        .replace(/^~(?=\/|$)/, "/@HOME")
        .replace(/^\$\{?HOME\}?(?=\/|$)/, "/@HOME")
        .replace(/["'\\]/g, ""),
    ).toLowerCase();
  const norm = canon(target);
  if (!norm) return false;
  const base = norm.slice(norm.lastIndexOf("/") + 1);
  for (const rawWord of text.split(/\s+/)) {
    const w = canon(rawWord);
    if (!w) continue;
    if (w === norm) return true;
    if (base && w === base) return true;
    // An ABSOLUTE spelling whose tail is the target's path from some point (`bash sub/x.sh` for
    // `./sub/x.sh`) — the `cd` that makes it absolute may sit on an earlier line.
    if (w.endsWith("/" + norm)) return true;
  }
  return false;
}

/** Could a GLOB word on this line reach `target`? `. /tmp/g1.*` runs a file whose exact name the
 *  written-target comparison cannot match, so a glob sharing the target's DIRECTORY counts. */
function heredocGlobMentions(line: string, target: string): boolean {
  // ⛔ THE GLOB ARM WAS DEAD FOR EVERY `./`, `../`, ROOT AND BARE-NAME TARGET (#1382 cycle 10
  // review, P1 — a regression this change introduced). Normalizing the target's DIRECTORY turns
  // `"./"` into `""`, so the `dir.length < 1` guard returned false before any comparison, and the
  // pre-fix code (which compared the RAW `"./"` prefix) refused those same commands. Measured:
  // `cat > ./x.sh … bash ./*.sh` and `cat > ../x.sh … bash ../*.sh` went from REFUSED on main to
  // MASKED here.
  //
  // The glob is now expanded to a REGEX and matched against the target itself (normalized, folded to
  // lower case, `~`/`$HOME` canonicalized), not against a directory prefix — so `./x.sh` vs `*.sh`,
  // a bare `x.sh` vs `x*.sh`, and `/tmp/e.sh` vs `/tmp/e.s[h]` all match, while a glob naming a
  // DIFFERENT file in the same directory does not. `[` is a metachar too (`bash /tmp/e.s[h]`).
  if (!/[?*[]/.test(line)) return false;
  const canon = (p: string) =>
    heredocNormalizePath(
      p
        .replace(/^~(?=\/|$)/, "/@HOME")
        .replace(/^\$\{?HOME\}?(?=\/|$)/, "/@HOME")
        .replace(/["'\\]/g, ""),
    ).toLowerCase();
  const norm = canon(target);
  if (!norm) return false;
  const base = norm.slice(norm.lastIndexOf("/") + 1);
  for (const rawWord of line.split(/\s+/)) {
    const w = canon(rawWord);
    if (!w || !/[?*[]/.test(w)) continue;
    const re = globToRegExp(w);
    // ⛔ A GLOB THAT IS NOT A VALID REGEX MUST NOT THROW OUT OF THE GATE (#1382 cycle 11 review, P1 —
    // measured: `bash f[z-a]` after writing `f.sh` threw `Range out of order in character class`
    // from `maskHeredocData` inside the `tool_call` handler). It fails CLOSED today because pi blocks
    // a tool call whose handler throws — but an unhandled exception on ordinary input is one
    // `try/catch` away from being a fail-open, so an uncompilable glob is treated as MATCHING (the
    // body stays readable) instead.
    // `null` means the glob could not be compiled — treat it as MATCHING (the body stays readable).
    let matched = re === null;
    if (re !== null) {
      try {
        matched = re.test(norm) || (base ? re.test(base) : false);
      } catch {
        matched = true;
      }
    }
    if (matched) return true;
  }
  return false;
}

/** `*`/`?`/`[...]` as a shell glob, anchored. Everything else is literal. */
function globToRegExp(glob: string): RegExp | null {
  let re = "^";
  for (let i = 0; i < glob.length; i++) {
    const ch = glob[i];
    if (ch === "*") re += ".*";
    else if (ch === "?") re += ".";
    else if (ch === "[") {
      const close = glob.indexOf("]", i + 1);
      if (close === -1) re += "\\[";
      else {
        re += glob.slice(i, close + 1).replace(/\\/g, "\\\\");
        i = close;
      }
    } else re += ch.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  }
  // An invalid character class (`[z-a]`) is a shell glob bash LEAVES LITERAL but a regex compiler
  // REJECTS. Returning null (rather than throwing) keeps the gate's decision in the gate.
  try {
    return new RegExp(re + "$");
  } catch {
    return null;
  }
}

/** Is this segment UNABLE to run a file it names — a `git` subcommand that only names one, or a
 *  proven text reader (`wc -l file`, `grep x file`, `cat file`)?
 *
 * ⛔ THE READER EXEMPTION IS NOT A LOOPHOLE (#1382 cycle 2, and a measured self-inflicted false
 * positive): without it, `cat >> notes.md <<'EOF' … EOF` followed by `wc -l notes.md` counted as
 * "written then executed" and the prose refusal came back — writing a file and then CHECKING it is
 * one of the most common lane sequences there is. A reader's own `exec` surface is what it does
 * with its STDOUT, so it can only ever DISPLAY a file, never run it; anything outside that set
 * (`bash`, `python3`, `source`, `chmod`, an unknown word) is still treated as an executor and keeps
 * the body readable.
 *
 * ⛔ THAT SENTENCE WAS FALSE AND IS CORRECTED HERE (#1382 cycle 10 review, P2 — measured): several
 * members of `HEREDOC_STDIN_DATA_CONSUMERS` carry an OPTION that runs a program — `sort
 * --compress-program=/tmp/x.sh FILE` (executed on temp spill) and `less` (`LESSOPEN=|cmd`, `!cmd`)
 * both MASK a body they can execute. The EXEMPTION is still right for the ordinary `grep x f` /
 * `wc -l f` / `cat f` case, and the pipe/execution arms above bound the rest, but the guarantee is
 * NOT "a reader can only display". What it really says is: this reader, with the arguments written
 * here, cannot run the file. So the reason a future reader would give for adding the NEXT "reader"
 * to that set — display-only — does not exist, and a member with an exec-bearing flag should be
 * REMOVED from it. Stated rather than fixed: the option-flag class is not covered by this change.
 * (See the declared residual in the #1382 issue comment; the argv layer (#984) is the layer that
 * sees the real invocation.)
 */
function heredocSegmentIsNaming(
  segment: string,
  scope = segment,
  extraNaming?: ReadonlySet<string>,
): boolean {
  // ⛔ A NAMING WORD THAT WRAPS A COMMAND SUBSTITUTION PROVES NOTHING (#1382 cycle 11 review, P0 —
  // measured ALLOWED: `ls "$(bash x.sh)"` and `echo "$(bash x.sh)"` masked a body they then ran).
  // The substitution's OUTPUT is the argument, so the reader is not reading the file — something else
  // is running it. Any `$(`, backtick or process substitution in the segment returns "not naming".
  if (/\$\(|`|[<>]\(/.test(segment)) return false;
  const words = segment.trim().split(/\s+/);
  const commandWord = (words[0] ?? "").replace(/["'\\]/g, "");
  // ⛔ SHADOWED IS NOT NAMING (#1382 cycle 11 review, P0 — measured ALLOWED: `ls() { bash "$@"; }`
  // then `ls x.sh` masked a body the function then RAN, and the same for `echo()`/`stat()`/`du()`).
  // The naming set is a claim about a PROGRAM; a function, alias or assignment of that name in the
  // command replaces the program. `heredocReaderIsShadowed` is the same test the OPENER's reader gets
  // — applying it here is what makes the two halves of the proof agree. The scope is the whole
  // command (over-conservative on ordering), which keeps a body readable, the allowed direction.
  if (heredocReaderIsShadowed(scope, commandWord)) return false;
  // ⛔ `find` IS NOT A NAMER WHEN IT EXECUTES (#1382 cycle 12 review, P0 — measured: `find x.sh -exec
  // bash {} \;` ran the body WHILE IT WAS MASKED, and five spellings that were REFUSED at e4e78a6f
  // — `-exec`, `-exec bash {} +`, `-name … -exec`, `-execdir`, `-ok` — became masks the moment `find`
  // joined the naming set wholesale). Its other primaries only name a file, which is why the whole
  // command was tempting; the exec primaries are the exception, and they are the one that matters.
  if (HEREDOC_FILE_NAMING_ONLY.has(commandWord) || extraNaming?.has(commandWord)) return true;
  if (commandWord !== "git") return false;
  // A git GLOBAL flag can re-point what runs (`-c alias.x=!sh`, `--exec-path`, `--upload-pack`).
  if (words.some((w) => /^(-c|--config-env|--exec-path|--upload-pack|--receive-pack)$/.test(w))) return false;
  const sub = words.slice(1).map((w) => w.replace(/["'\\]/g, "")).find((w) => !w.startsWith("-"));
  return GIT_FILE_NAMING_SUBCOMMANDS.has(sub ?? "");
}
function heredocWrittenTargets(line: string, readerOverride?: string): string[] {
  const out: string[] = [];
  const dequoteWord = (w: string) => w.replace(/["'\\]/g, "");
  // `>`/`>>` targets, quote-aware (a `>` inside a quoted delimiter or message is not a redirect).
  let quote: string | null = null;
  for (let c = 0; c < line.length; c++) {
    const ch = line[c];
    if (quote) {
      if (ch === "\\" && quote === '"') {
        c++;
        continue;
      }
      if (ch === quote) quote = null;
      continue;
    }
    if (ch === "'" || ch === '"') {
      quote = ch;
      continue;
    }
    if (ch === "\\") {
      c++;
      continue;
    }
    if (ch === ">") {
      if (line[c + 1] === ">") c++;
      if (line[c + 1] === "&") continue; // `>&2` is an FD, not a file
      const m = /^\s*(?:"([^"]*)"|'([^']*)'|([^\s;&|<>()+]+))/.exec(line.slice(c + 1));
      const target = m ? (m[1] ?? m[2] ?? m[3] ?? "") : "";
      if (target && target !== "/dev/null") out.push(dequoteWord(target));
      continue;
    }
  }
  // ⛔ THE READER MAY BE GIVEN, because the command word is not always the writer (#3161 P0). With a
  // COMPOUND opener line the FIRST word is the prefix's command (`cd /wt && tee /tmp/y.sh <<'EOF'`),
  // so the `tee`/`sort -o` arms below saw `cd` and returned NO target — and the caller that permits a
  // compound prefix then had no target to check against a later `bash /tmp/y.sh` (measured fail-open).
  // When the reader is given, the WORDS are its own SEGMENT too, so the prefix's words cannot enter
  // its argument list as phantom targets. Default unchanged, so `maskHeredocData` reads exactly what
  // it read before.
  const reader = readerOverride ?? heredocCommandWord(line);
  const words = (readerOverride
    ? line
        .split(/[;&|]+/)
        .filter((s) => (s.trim().split(/\s+/)[0] ?? "").replace(/["'\\]/g, "") === readerOverride)
        .pop() ?? line
    : line
  )
    .trim()
    .split(/\s+/)
    .map(dequoteWord);
  if (reader === "tee") {
    for (const w of words.slice(1)) if (w && !w.startsWith("-") && w !== "-") out.push(w);
  }
  // `sort -o FILE` / `sort --output=FILE` writes its stdin to a file too (#1382 review cycle 2, P2:
  // `sort` is a proven DATA consumer, so its `-o` target was the one writer this list missed).
  if (reader === "sort") {
    for (let k = 0; k < words.length; k++) {
      if (words[k] === "-o" || words[k] === "--output") {
        if (words[k + 1]) out.push(words[k + 1]);
      } else if (words[k].startsWith("--output=")) {
        out.push(words[k].slice("--output=".length));
      }
    }
  }
  return out;
}

/**
 * Can something EARLIER in the command change what the reader resolves to, or capture the body?
 *
 * ⛔ THE PROOF MUST COVER THE WHOLE COMMAND, NOT THE OPENER LINE (#1382 review cycle 2, P1 — two
 * measured bypasses, both of which bash executed while the gate ALLOWED):
 *
 *   PATH=/tmp/e:$PATH; export PATH     # /tmp/e/cat is `exec bash`
 *   cat <<'SH' … SH                    # body masked, then EXECUTED by the fake reader
 *
 *   x=$(cat <<'EOF' … EOF              # the `$(` is on an EARLIER line, so the opener line carried
 *   )                                  # no substitution …
 *   eval "$x"                          # … and the captured body reached eval
 *
 * So the rule is: refuse to mask when the PREFIX (a) assigns a PATH-relevant variable or exports one,
 * (b) leaves a command substitution OPEN, or (c) assigns a variable whose VALUE is a file this
 * heredoc writes (the path travels through the variable into `source "$f"`). Over-refusing only
 * costs a refusal; the ordinary `cat >> file <<'EOF'` prefix is empty and unaffected.
 */
function heredocPrefixIsUnprovable(prefix: string, targets: string[]): boolean {
  if (/(^|[\s;&|()])(?:export\s+)?(PATH|IFS|BASH_ENV|ENV|SHELLOPTS|BASHOPTS|LD_PRELOAD|LD_LIBRARY_PATH|CDPATH)=/.test(prefix)) {
    return true;
  }
  // ⛔ ANY SUBSTITUTION IN THE PREFIX REFUSES THE MASK. A depth COUNTER was here, and it was a
  // measured fail-OPEN: it treated a `)` inside a DOUBLE-QUOTED string, a `#` comment, or an escaped
  // `\)` as closing a substitution, so all four spellings below reached `eval` with the body masked
  // (fresh review, and re-measured here at the real gate before the fix):
  //
  //     x=$(                     # depth 1
  //     # ) closing note         # the counter reads this `)` and drops to 0 …
  //     cat <<'EOF'              # … so the body is "proven" DATA and masked …
  //     gh pr merge 1 --admin
  //     EOF
  //     )                        # … while bash is still INSIDE the substitution
  //     eval "$x"                # … and the captured body executes.
  //
  // A correct count is a shell parser — the class this file has already learned it cannot enumerate.
  // So the boundary moves instead of the parser growing: a prefix with NO `$(` and NO backtick is
  // provable; anything else is not. The cost is the pre-#1382 refusal for a heredoc written after a
  // substitution — a refusal this file was already making, never a permission it newly grants.
  if (prefix.includes("$(") || prefix.includes("`")) return true;
  for (const t of targets) if (t !== "" && t !== "-" && prefix.includes(t)) return true;
  return false;
}

/**
 * Does this line END IN A LINE CONTINUATION — an ODD number of trailing backslashes (the shell
 * removes a backslash-newline outright, so `\` + newline joins the next physical line onto this
 * one)? `\r` is stripped first: a CRLF command is the same command.
 *
 * ⛔ WHY THE MASK MUST SEE THIS (fresh review, P0, measured): the proof is LINE-LOCAL, and bash is
 * not. A trailing `\` hides everything the proof checks for on the NEXT line, so
 *
 *     cat <<'X' \
 *     | bash
 *     gh pr merge 1 --admin
 *     X
 *
 * read as "one simple command with no pipe" (`cat`, a data consumer) and the body was masked —
 * while bash joins the lines into `cat <<'X' | bash` and EXECUTES the body. The same continuation
 * split a redirect target (`cat <<'X' > \` / `/tmp/x.sh`) so the written-target scan saw no target
 * at all and a later `bash /tmp/x.sh` went unchecked. Both were measured ALLOWING at the real gate.
 * A command with continuations is therefore never masked: over-refusal is the direction this file
 * may be wrong in.
 */
function endsWithContinuation(line: string): boolean {
  const t = line.replace(/\r$/, "");
  let n = 0;
  for (let i = t.length - 1; i >= 0 && t[i] === "\\"; i--) n++;
  return n % 2 === 1;
}

/**
 * May this heredoc's body be treated as DATA — i.e. blanked before any gate reads the command?
 *
 * THE INVARIANT THIS SERVES, stated once: **a gate that fires on prose teaches agents to write
 * around it, which is how real bypasses hide.** A body under `cat >> file <<'EOF'` is the single
 * most common way an agent writes a Markdown file or a commit message, and prose ABOUT a merge is
 * not a merge. The measured cost of getting this wrong is a lane that cannot RECORD a defect it
 * just measured (#1382, and this lane's own first tool call).
 *
 * The proof is a SHAPE, not a guess, and everything it cannot prove keeps the body readable:
 *
 *  1. the opener line is ONE SIMPLE COMMAND — no `;`, `&`, `|`, `(`, `)` and no second `<`
 *     redirect outside quotes, so the heredoc has exactly one consumer and nothing else on the
 *     line changes what runs. A `>`/`>>` redirect IS allowed: writing the body to a file is the
 *     archetypal data sink (`cat >> NOTES.md <<'EOF'`), and excluding it was this fix's first bug —
 *     it left the reported command refused.
 *  2. no `$(`, backtick or `NAME=value` prefix before the opener: a command substitution puts the
 *     body's text back in COMMAND position (`$(cat <<'EOF' … EOF)`), and an assignment can shadow
 *     `PATH`.
 *  3. the command word is a proven DATA consumer (see the set above), or `git commit|tag` (whose
 *     `-F -` stdin is a message).
 *  4. that word is not shadowed by an alias/function/assignment anywhere in the command
 *     (`heredocReaderIsShadowed`).
 *
 * What this does NOT cover, stated rather than implied: a body written to a FILE that a LATER
 * command executes (`cat > x.sh <<'EOF' … EOF && bash x.sh` — the `&&` in (1) already keeps that
 * body readable). The argv layer (#984) is the answer for execution, which is why the caller only
 * masks while that layer is enforcing.
 *
 * ⛔ AND IT IS THE HEREDOC CLASS ONLY. A construct inside a QUOTED ARGUMENT (`echo 'the `gh pr`
 * guard refused merge-2235'`) still counts as a candidate and is still refused for carrying no
 * resolvable PR number. That over-block is KEPT, not fixed: #1425 records that four narrowing
 * attempts at the candidate rule each regressed a real bypass, and #1776's boundary test pins the
 * ACCEPTED OVER-BLOCK. A heredoc body is different in kind — it is not part of the command's words
 * at all — which is why it can be masked and a quoted argument cannot.
 */
function heredocBodyIsData(line: string): boolean {
  // (2) a substitution can put the body back in command position; an assignment can shadow PATH.
  if (/\$\(|`/.test(line)) return false;
  // (1) one simple command, quote-aware. `>`/`>>` allowed; a second `<` (e.g. another heredoc
  // opener, or `<file` input redirection) is not provable, so it is refused.
  let quote: string | null = null;
  let openerSeen = 0;
  for (let c = 0; c < line.length; c++) {
    const ch = line[c];
    if (quote) {
      if (ch === "\\" && quote === '"') {
        c++;
        continue;
      }
      if (ch === quote) quote = null;
      continue;
    }
    if (ch === "'" || ch === '"') {
      quote = ch;
      continue;
    }
    if (ch === "\\") {
      c++;
      continue;
    }
    if (/[;&|()]/.test(ch)) return false;
    if (ch === "<") {
      if (line[c + 1] === "<") {
        openerSeen++;
        c++; // the opener pair itself
        if (line[c + 1] === "-") c++;
        continue;
      }
      return false; // `<file` input redirection
    }
  }
  if (openerSeen === 0) return false;
  // (3) the command word, read the SAME way `maskHeredocData` reads it (`heredocCommandWord`): the
  // opener and everything after it cut off, every quote removed — so `cat<<'EOF'` and `c"a"t <<'EOF'`
  // are the data consumers they are, instead of two more spellings that keep the prose refusal.
  const words = line.trim().split(/\s+/);
  const first = words[0] ?? "";
  if (first === "" || /^[A-Za-z_][A-Za-z0-9_]*=/.test(first)) return false;
  const cmd = heredocCommandWord(line);
  if (cmd === "git") {
    // Only the subcommands whose stdin is a MESSAGE (`git commit -F -`, `git tag -F -`). A global
    // flag can move the subcommand or re-point git's config, so any `-c`/`--config*`/`--exec-path`
    // before it refuses the mask.
    const rest = words.slice(1).map((w) => w.replace(/["'\\]/g, ""));
    const sub = rest.find((w) => !w.startsWith("-"));
    if (sub !== "commit" && sub !== "tag") return false;
    if (rest.some((w) => /^-(c|C)$/.test(w) || /^--(config|config-env|exec-path)/.test(w))) return false;
    return true;
  }
  return HEREDOC_STDIN_DATA_CONSUMERS.has(cmd);
}

/**
 * #1382 — THE COMPOUND FRAME a heredoc opener sits INSIDE, if any.
 *
 * `heredocBodyIsData` proves the body is stdin DATA for the opener's OWN consumer, and for a LONE
 * simple command that is the whole story. A COMPOUND changes what happens to that consumer's
 * STDOUT, and the masker did not model it. Measured at the landed head of this file (run through a
 * real `bash`, each printing its marker — EXECUTIONS, not mentions):
 *
 *     if true; then             for x in 1; do              case x in
 *     cat <<'EOF'               cat <<'EOF'                 x) cat <<'EOF'
 *     gh pr merge 999 --admin   gh pr merge 999 --admin    gh pr merge 999 --admin
 *     EOF                       EOF                        EOF
 *     :                         done | bash                :;;
 *     fi | bash                                            esac | bash
 *
 * In each, `| bash` receives the COMPOUND's stdout, so the body executes while the gate — reading the
 * masked text — sees no `gh` word at all and returns before any check. Measured before this fix:
 * `isGitOp(raw)` true, `isGitOp(maskHeredocData(raw))` false. That is a FAIL-OPEN in the one gate
 * that guards every merge, and it is why the proof below is scoped: it holds for a lone command,
 * not for a body whose stdout still has somewhere to go.
 *
 * A STACK, not a depth counter: a `case` ARM ends in `)` (`case x in x) …`), which a bare counter
 * reads as closing a `(`, while a stack whose top is `case` ignores it. An unmatched closer is
 * IGNORED rather than decrementing, so the error stays on the fail-CLOSED side — an unmatched `fi`
 * can never make a deeper frame read as shallower.
 *
 * Conservative by construction: quoted text and `#` comments cannot open or close a frame, and
 * anything the scan cannot read leaves frames OPEN, i.e. "no mask" — a refusal, the direction this
 * file is allowed to be wrong in.
 */
type HeredocFrame = "if" | "loop" | "case" | "paren" | "brace";

/** The words of one line that can open or close a shell frame, quotes and comments removed. */
function heredocFrameTokens(line: string): string[] {
  let quote: string | null = null;
  let buf = "";
  for (let c = 0; c < line.length; c++) {
    const ch = line[c];
    if (quote) {
      if (ch === "\\" && quote === '"') {
        c++;
        continue;
      }
      if (ch === quote) quote = null;
      continue;
    }
    if (ch === "'" || ch === '"') {
      quote = ch;
      buf += " ";
      continue;
    }
    if (ch === "\\") {
      c++;
      buf += " ";
      continue;
    }
    if (ch === "#" && (buf === "" || /\s$/.test(buf))) break; // comment: no frame after it
    buf += ch;
  }
  return buf
    .replace(/([(){}])/g, " $1 ")
    .split(/[\s;&|]+/)
    .filter((t) => t !== "");
}

/** Apply one line's frame openers/closers to the carried stack. */
function heredocFramesAdvance(line: string, stack: HeredocFrame[]): void {
  const top = () => stack[stack.length - 1];
  for (const w of heredocFrameTokens(line)) {
    if (w === "if") stack.push("if");
    else if (w === "for" || w === "while" || w === "until" || w === "select") stack.push("loop");
    else if (w === "case") stack.push("case");
    else if (w === "(") stack.push("paren");
    else if (w === "{") stack.push("brace");
    else if (w === "fi") { if (top() === "if") stack.pop(); }
    else if (w === "done") { if (top() === "loop") stack.pop(); }
    else if (w === "esac") { if (top() === "case") stack.pop(); }
    else if (w === ")") { if (top() === "paren") stack.pop(); }
    else if (w === "}") { if (top() === "brace") stack.pop(); }
  }
}

/**
 * Is the heredoc opened on `openerIndex` inside a frame that is still OPEN there?
 *
 * The opener line's own PREFIX counts too (`{ cat <<'EOF'`): the `<<` is what delimits it.
 */
function heredocOpenerIsInsideFrame(lines: string[], openerIndex: number): boolean {
  const stack: HeredocFrame[] = [];
  // ⛔ THE SCAN MUST SKIP EARLIER HEREDOC BODIES. A body is DATA, so its text cannot close a frame —
  // but reading it as shell code let ONE prose `fi` / `}` / `)` / `esac` inside an earlier body pop a
  // frame bash still has open, after which this function reported "no frame" and the body below was
  // masked while the shell executed it. Measured fail-OPEN (marker printed by a real `bash`, gate
  // silent): `if true; then` / `cat <<'A' > notes.md` / `fi` / `A` / `cat <<'EOF'` … `EOF` / `:` /
  // `fi | bash`. Deliberately the same opener reader `maskHeredocData` uses, so the two cannot
  // disagree about which body exists.
  const st: HeredocScanState = { quote: null, arith: 0, bare: 0, bareStack: [] };
  for (let n = 0; n < openerIndex; n++) {
    const openers = heredocOpenersIn(lines[n], st);
    heredocFramesAdvance(lines[n], stack);
    if (openers.length === 0) continue;
    for (const op of openers) {
      let closed = false;
      for (n++; n < openerIndex; n++) {
        const probe = op.stripTabs ? lines[n].replace(/^\t+/, "") : lines[n];
        if (probe === op.delim) {
          closed = true;
          break;
        }
      }
      // The body never ended before the opener: the "opener" under test is inside a body, i.e. not
      // an opener at all. Treat it as enclosed — nothing is masked, which is the safe direction.
      if (!closed) return true;
    }
  }
  const at = lines[openerIndex].indexOf("<<");
  heredocFramesAdvance(at >= 0 ? lines[openerIndex].slice(0, at) : "", stack);
  return stack.length > 0;
}


/**
 * #1382 — blank out every heredoc BODY (and its terminator) whose body is DATA, LENGTH-PRESERVING so
 * every offset a later reader holds stays valid.
 *
 * This is the admin-merge gate's data model, applied ONCE at the `tool_call` entry so every gate
 * reads the same text: the candidate test, `hasLiteralAdminFlag`, `mergeVerbInText`,
 * `countMergeVerbs`, `extractPrNumber` and the merge registry. The AUDIT record keeps the caller's
 * raw text, and the shell is given the caller's raw command — masking is a READING of the command,
 * never a rewrite of it.
 *
 * Deliberately conservative in the only direction this file is allowed to be wrong in: a body under
 * a consumer that is not proven data, an unterminated body, a compound opener line, a command with a
 * LINE CONTINUATION (bash joins those lines, so a line-local proof reads a fragment), a substitution
 * anywhere in the prefix, or a shadowed reader keeps its body READABLE, so the gate refuses exactly
 * as it did before. Those shapes are the safety argument, and they are why the mask is applied
 * UNCONDITIONALLY rather than only while the argv layer (#984) enforces: what it blanks is proven
 * DATA, i.e. text this command cannot execute, so there is no invocation for a downstream reader to
 * catch. See the gate entry for the measured reason the old condition kept the false positive alive
 * on this fleet.
 *
 * ⛔ STATED RESIDUAL — AN OPEN GAP, NOT A SAFE ASSUMPTION. The proof is scoped to THIS command. A
 * body written to a file (`cat > /tmp/x.sh <<'EOF'`) is DATA to the writer, and nothing here follows
 * that file into a LATER tool call, where `bash /tmp/x.sh` carries no `gh` word for any text gate
 * to read. The argv-level shim (#984) is the layer that saw that execution, and
 * `docs/ops/ACTIVATION-MATRIX.md` row 1 records it as ABSENT on this fleet — the load-time #984
 * warning names the gap. Pinned by `#1382 (e)` in the suite so no lane reads this as covered. (The
 * same outcome was always reachable through surfaces this gate never inspected — the `write` tool, a
 * `python3 -c` payload — so this is a boundary of the INSTRUMENT, declared, not a control removed.)
 */
export function maskHeredocData(command: string): string {
  const lines = command.split("\n");
  const out: string[] = [];
  const blank = (s: string) => " ".repeat(s.length);
  // Carried ACROSS lines: an arithmetic expression can span them (a `<<` on a continuation line is a
  // SHIFT, not an opener), and so can a QUOTED STRING (an opener inside one is text). A false opener
  // masks to EOF — a fail-open.
  const state: HeredocScanState = { quote: null, arith: 0, bare: 0, bareStack: [] };
  for (let i = 0; i < lines.length; i++) {
    out.push(lines[i]);
    const openers = heredocOpenersIn(lines[i], state);
    if (openers.length === 0) continue;
    // ⛔ NO LINE CONTINUATIONS, ANYWHERE (fresh review, P0 — measured fail-OPEN). The proof below is
    // LINE-LOCAL; bash removes a backslash-newline and joins the next physical line onto this one.
    // So `cat <<'X' \` / `| bash` read as "one simple command, no pipe" and the body was masked
    // while bash piped it into `bash`; `cat <<'X' > \` / `/tmp/x.sh` hid the redirect target from
    // `heredocWrittenTargets`, so a later `bash /tmp/x.sh` was never checked either. A continuation
    // in the opener line OR in the prefix that feeds it makes every rule here a reading of a
    // FRAGMENT, which is not a proof — so nothing is masked. Over-refusal is the direction this
    // file may be wrong in.
    if (endsWithContinuation(lines[i])) continue;
    if (lines.slice(0, i).some(endsWithContinuation)) continue;
    // ⛔ A COMPOUND FRAME CAN HAND THE BODY TO A PROGRAM (#1382 — measured fail-OPEN in every
    // keyword and bracket frame; see `HeredocFrame`). `if … cat <<'EOF' … EOF … fi | bash` gives the
    // COMPOUND's stdout to bash, so the body EXECUTES while every rule below proves DATA for the
    // WRONG consumer and the gate, reading masked text, returns before any check.
    //
    // ⛔ INSIDE A FRAME, NOTHING IS MASKED — deliberately, with NO attempt to test whether this
    // particular frame's stdout reaches a program. A first version DID test it, and a fresh review
    // measured seven ways past the test, every one an execution with the gate silent: a prose `fi`
    // in an EARLIER heredoc body popping the frame; a POSIX `|` followed by a newline; `fi > f; bash
    // f` on ONE line; `bash <(if … fi)` (the sink precedes the opener); `fi | $SHELL` (the program is
    // a variable). Enumerating frame spellings × sink routes is a shell parser, and this file has
    // already recorded that it cannot enumerate that class — `heredocPrefixIsUnprovable` moved from a
    // depth counter to "ANY `$(` refuses the mask" for the same reason. So the boundary moves again:
    // a frame means "not provable", and the body keeps the pre-change refusal.
    //
    // STATED COST, and it is a real one: a heredoc that IS data, written INSIDE a frame (`if …; then
    // cat >> notes.md <<'EOF' … EOF; fi`), is no longer masked — so a framed report that quotes
    // `gh pr merge` is refused again. That is a false POSITIVE, the direction this file is allowed to
    // be wrong in; the alternative measured above is a silent admin merge. A lone writer with no
    // enclosing frame — the reported shape — is untouched.
    if (heredocOpenerIsInsideFrame(lines, i)) continue;
    if (!heredocBodyIsData(lines[i])) continue;
    const reader = heredocCommandWord(lines[i]);
    // ⛔ THE SHADOW SCAN STOPS AT THE OPENER LINE (#1382 review cycle 1, P2): it used to read the
    // WHOLE command, body included, so a report that QUOTED `cat() { bash; }` — an evidence file about
    // this very gate — disarmed the mask and brought the reported false positive back. An alias or a
    // function must be defined BEFORE the line that uses it, so the prefix is the sound scope (and a
    // later definition cannot retroactively change what an earlier line ran).
    if (heredocReaderIsShadowed(lines.slice(0, i + 1).join("\n"), reader)) continue;
    // A body written to a FILE that this same command can EXECUTE by a later line — unprovable, so
    // keep it readable (see `heredocLineExecutes`).
    const targets = heredocWrittenTargets(lines[i]);
    // ⛔ A REDIRECT TARGET THE SHELL WILL EXPAND IS NOT A NAME WE CAN COMPARE (#1382 cycle 10 review).
    // Measured: `cat > $HOME/x.sh <<'EOF' … EOF` + `bash ~/x.sh` was MASKED — the written-target
    // reader does not carry `$HOME` through as one word, so no comparison could see that the runner
    // reaches the same file. `$VAR` cannot be resolved here at all, so a `$`/backtick in any target
    // keeps the whole body READABLE (a refusal) instead of guessing. `~` is left maskable: it expands
    // to one known directory, and `heredocNamesTarget` canonicalizes it.
    if (targets.some((t) => /[$`]/.test(t))) continue;
    // The LATER lines are read with continuations resolved, for the same reason as the opener: a
    // runner spelled `bash \` / `/tmp/x.sh` executes the body just as plainly as `bash /tmp/x.sh`,
    // and a line-by-line scan saw neither half.
    const otherLines = lines
      .filter((_, n) => n !== i)
      .join("\n")
      .replace(/\\\r?\n/g, " ")
      // ⛔ A LINENBREAK AFTER `|` CONTINUES THE PIPELINE (POSIX). Only `\`-continuations were joined,
      // so `cat /tmp/x.sh |` <newline> `bash` read as two unrelated commands and the body was masked
      // while bash ran it (#1382 cycle 10 review, P0 — measured ALLOWED).
      .replace(/\|[ \t]*\r?\n/g, "| ")
      .split("\n");
    // The scope passed to the naming test is the WHOLE command (a function/alias/assignment may be
    // defined on any line), so a shadowed reader keeps the body readable from any direction.
    const scope = lines.join("\n");
    if (targets.some((t) => t !== "" && t !== "-" && otherLines.some((l) => heredocLineExecutes(l, t, scope)))) continue;
    // …and the PREFIX must not be able to change what the reader resolves to, capture the body, or
    // hold the written path in a variable.
    if (heredocPrefixIsUnprovable(lines.slice(0, i).join("\n"), targets)) continue;
    for (const opener of openers) {
      let closed = false;
      for (i++; i < lines.length; i++) {
        const probe = opener.stripTabs ? lines[i].replace(/^\t+/, "") : lines[i];
        out.push(blank(lines[i]));
        if (probe === opener.delim) {
          closed = true;
          break;
        }
      }
      // An UNTERMINATED heredoc is NOT a bash syntax error — measured: `printf 'cat <<EOF\nhi\n' > /tmp/u.sh;
      // bash /tmp/u.sh` WARNS ("here-document at line 1 delimited by end-of-file") and then EXECUTES the
      // command with the remainder as the body, exit 0 (#1382 cycle 9 review, P2 — the first version of
      // this comment asserted the opposite, and a later widening to a non-proven consumer would have
      // leaned on it). Masking the remainder is still sound HERE and for a narrower reason: the opener
      // passed `heredocBodyIsData`, so whatever follows is the body of a consumer this file proved
      // cannot execute its stdin, and nothing follows the body. If that proof ever widens, this branch
      // must stop masking — it is the proof, not the "syntax error", that carries the safety.
      if (!closed) break;
    }
  }
  return out.join("\n");
}

/**
 * #2148 — WHICH AUDIENCE the disclosure addresses. The harness exports `KIND` at every worker's
 * spawn point (`lane.sh` → `lane`, `fix-one.sh` → `fixer`, `merge-one.sh` → `reviewer`,
 * `nonblocking-dispatch.sh` → `bg`), so a worker session is identifiable without guessing from the
 * cwd or the brief. A KIND this list does not know falls back to `self`, whose line names the
 * override for that case (a brief saying "no task tool") — disclosure over silence, and true for
 * both audiences rather than a guess between them.
 *
 * ⛔ This matters because the audiences are told OPPOSITE things about who dispatches: a
 * `lane.sh` brief says "you have NO task tool — do NOT dispatch … Do NOT merge", so a self-role
 * disclosure injected into that same context would instruct two forbidden actions (found by two
 * independent fresh reviewers on this change).
 */
export function reviewerRoleFor(
  env: Record<string, string | undefined> = process.env,
): ReviewerRole {
  const kind = String(env.KIND ?? "").toLowerCase();
  // ⛔ `bg` IS A HARNESS WORKER TOO (agent-infra#2148 review). `nonblocking-dispatch.sh` exports
  // `KIND=bg` for a background worker it launches itself, and its own note says nothing reviews that
  // worker's PR — the parent/chain does. Leaving it out told a bg worker to dispatch and to run the
  // rail, repeating the exact contradiction this function exists to prevent, for one more audience.
  //
  // ⛔ `reviewer` IS NOT THAT AUDIENCE EITHER (second fresh review, P2). `merge-one.sh` launches it
  // with "Report only — do not fix code … Do NOT modify code, commit, or merge", so the harness
  // line's "push your FINAL head" is advice for code it must not touch. It gets its own role, whose
  // line names what it OWNS (the verdict comment) and the three things it must not do.
  if (kind === "reviewer") return "reviewer";
  return kind === "lane" || kind === "fixer" || kind === "bg" ? "harness" : "self";
}

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
  return withoutMandatedRailPath(command).replace(/\\\r?\n/g, "").replace(/["'\\]/g, "");
}

/**
 * #1203 — THE MANDATED RAIL'S OWN PATH IS NOT A MERGE VERB, AND ITS FILENAME IS
 * NOT AN `admin` FLAG.
 *
 * `scripts/admin-merge.sh` is the route this gate's OWN refusal tells a caller to
 * take. Its filename spells the two things the scanner keys on — the word `admin`
 * (rule 2's construct-plus-`admin` read) and the word `merge` — so a command that
 * merely INVOKES the rail is read as an admin merge, refused for carrying no
 * resolvable PR number, and thereby told to run the very rail it was refused for
 * running. Measured 2026-10-17 at HEAD, on the two spellings a lane actually
 * writes (the path is almost never static — the lane exports `$AGENT_INFRA_PATH`):
 *
 *   for pr in 3891; do bash $AGENT_INFRA_PATH/scripts/admin-merge.sh $pr; done
 *   gh run list --limit 1; bash $AGENT_INFRA_PATH/scripts/admin-merge.sh 3891
 *
 * Both are `isGitOp === true`, `isAdminMergeCommand === true`,
 * `extractMergePrNumber === null` — i.e. the "`gh pr merge --admin` carries no
 * resolvable PR number" block, for a command with no merge in it. The LITERAL
 * `bash scripts/admin-merge.sh 3891` is not gated at all (`isGitOp === false`), so
 * the current behaviour is an inconsistency between two spellings of the same
 * COMPLIANT route, not a control.
 *
 * The substitution is LENGTH-PRESERVING on purpose. `scanTokens` records byte
 * offsets (`starts`) that `isAdminMergeCommand` then slices the ORIGINAL command
 * with, to read the arguments after the `merge` word (the `$VAR`-supplied-flag
 * arm). A substitution that changed the length would shift every offset after the
 * path and make that read return the wrong text — a fail-open manufactured by the
 * fix itself. Equal length keeps ONE text model, which is the property this file
 * keeps re-learning it needs.
 *
 * WHAT THIS CANNOT HIDE (the declared threat surface of #1203):
 *   - the token is never the `gh` word and never a `--admin` flag — it is a path
 *     ending in `admin-merge.sh`, and `railscriptname` is neither — so no real
 *     merge VERB and no real FLAG is removed from the text;
 *   - the token's shell CONSTRUCT (`$`, backtick, brace) is left in place, so
 *     `hasUnresolvableConstruct` and `readsNonMergeGhCall`'s polarity see exactly
 *     what they saw before;
 *   - the rail is the COMPLIANT route, not a bypass: it computes and verifies the
 *     head-bound evidence itself, and its internal `gh pr merge --admin` is decided
 *     by the argv-level shim, i.e. the same invariant one layer down.
 * OUT OF SCOPE, and deliberately NOT narrowed here: the general "a command that
 * MENTIONS a merge anywhere is refused" class (#1382, #1124, #1776) and any
 * narrowing of the ANSI-C rule (#1425 — four narrowing attempts each regressed).
 * STATED LIMIT: a basename SPLIT by a backslash-newline continuation
 * (`admin-\<newline>merge.sh`) is not matched, because both normalizers resolve the
 * continuation AFTER this substitution. That spelling therefore keeps the old
 * over-block when the same call also carries a `pr`/`gh` word — left as an OVER-BLOCK
 * rather than moved, since resolving the continuation first is what would change the
 * offset model `isAdminMergeCommand` slices with (the fail-open direction).
 */
const MANDATED_RAIL_BASENAME = "admin-merge.sh";
/**
 * A neutral word of EXACTLY the basename's length — DERIVED, not written out, so the
 * length-preserving property cannot be broken by editing one constant and not the
 * other. (Today's value is `railscriptname`.) Derived rather than enforced by a
 * load-time `throw`: a module-level throw removes the WHOLE extension — every gate in
 * this file — which is exactly the silent-absence shape this guard exists to refuse.
 */
const MANDATED_RAIL_PLACEHOLDER = "railscriptname"
  .slice(0, MANDATED_RAIL_BASENAME.length)
  .padEnd(MANDATED_RAIL_BASENAME.length, "x");
/**
 * BOUNDARY-TIGHT, so the exemption is the gate's OWN route and not the substring: a
 * `my-admin-merge.sh` or an `admin-merge.sh.bak` is a different file, and exempting it
 * would be exempting a path this gate never mandated.
 */
const MANDATED_RAIL_RE = /(^|[^\w.-])admin-merge\.sh(?![.\w-])/g;
export function withoutMandatedRailPath(command: string): string {
  return command.replace(MANDATED_RAIL_RE, `$1${MANDATED_RAIL_PLACEHOLDER}`);
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
  //
  // An EMPTY QUOTE PAIR on the flag (`--repo"" owner/other`, `--repo'' …`, `-R""`) is
  // dropped by bash before gh sees it (measured: gh receives `--repo owner/other`), so the
  // `\S*` branch consumed only `--repo""` and left the VALUE in the stream — between `pr`
  // and `merge`, which broke the verb-pair read and deferred a real admin merge to an argv
  // layer the command had already discarded (E3 review P1; the base refused it). Removing
  // the empty pairs first makes the value the flag's, as bash makes it.
  //
  // A QUOTED value with a space inside it (`--repo "$(cat f)"`) is one word to bash and
  // two to `\S+`, so the same residue landed between the verb words and defeated the pair
  // read (A-cycle review P1, again refused by the base). The value is therefore consumed as
  // a whole quoted word first, then as a bare one.
  return command
    .replace(/""|''/g, "")
    .replace(/(^|\s)(?:-R|--repo)(?:=\S*|\s*(?:"[^"]*"|'[^']*'|\S+)|\S*)/g, "$1");
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
  /^(command|sudo|env|exec|nohup|nice|time|xargs|trap|coproc|do|then|else|eval|sh|bash|zsh|dash|ksh)$/;

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

function scanTokens(command: string, opts: { stripRepo?: boolean } = {}): ScanTokens {
  // bash removes a backslash-newline outright, so `g\<newline>h` is the command
  // `gh`. Do the same before tokenizing, or the continuation splits the name.
  // #1203: the mandated rail's own filename is neutralized BEFORE tokenizing, so
  // the path cannot supply the words `admin`/`merge` the verbs and flags are read
  // from. Length-preserving, so every offset below still addresses `command`.
  //
  // ⛔ `stripRepo: false` EXISTS BECAUSE THE STRIP DELETES AN ATTACKER-CHOSEN WORD (#2206 review,
  // P0). `stripRepoArgs` consumes the token AFTER `--repo`, and that token can be `git`: measured,
  // `for n in 1 2; do gh pr view $n; done; gh issue view 1 --repo git -c alias.p=push p origin
  // HEAD:refs/heads/x` certified as a READ at zero dispatches and ran an alias push — `git` was
  // gone from the token list `mentionsGitWord` scans, and `GIT_COMMIT_PATTERN` only knows
  // `commit`/`push`. The strip exists to stop a repo VALUE supplying `pr`/`merge`/`admin` words to
  // the VERB and FLAG reads; a rule that asks whether the text MENTIONS `git` must read the text as
  // written, because under-reading there costs a write and over-reading costs a retry.
  const pre = withoutMandatedRailPath(command);
  const joined = (opts.stripRepo === false ? pre : stripRepoArgs(pre)).replace(/\\\r?\n/g, "");
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

/**
 * The words whose argument is a PROGRAM THE SHELL RUNS: `sh -c '<payload>'`,
 * `eval '<payload>'`, `trap '<payload>' EXIT`, `xargs '<payload>'`. Quoted text
 * under one of these is CODE, so a verb pair inside it is a real invocation.
 *
 * ⚠️ NON-SHELL INTERPRETERS ARE DELIBERATELY ABSENT — see `dataCharMask`.
 */
const SHELL_PAYLOAD_RUNNERS = new Set([
  "sh", "bash", "zsh", "dash", "ksh", "ash", "mksh", "oksh", "source", ".",
  "eval", "trap", "xargs", "exec", "command", "env", "sudo", "nohup", "nice",
  "time", "coproc", "busybox",
  // `ssh <host> '<command>'` runs its argument in a REMOTE SHELL — pinned by the
  // #1776 boundary test, which spells the decoy that way.
  "ssh",
]);

/**
 * Commands that WRAP another program (`su`, `doas`, `timeout`, `setsid`,
 * `stdbuf`, `watch`, `chroot`, `flock`, …) — a bullet's operand can be the
 * program, so they participate in the SHELL-PAYLOAD decision, but only together
 * with a `-c` introducer (`su -c '<payload>'`, `timeout 5 sh -c '<payload>'`).
 *
 * ⚠️ They are NOT in `SHELL_PAYLOAD_RUNNERS`, and the distinction is measured
 * (cycle 2): a wrapper word alone made every quoted ARGUMENT of the wrapped
 * command code — `timeout 30 gh issue list --search '<mention>'`,
 * `flock /tmp/lock gh pr comment --body '<mention>'` each counted 1 and were
 * refused, which is the #1485 false-positive class returning through a side
 * door. Only `-c` turns a quoted region into a program.
 */
const SHELL_WRAPPER_WORDS = new Set([
  "sudo", "doas", "su", "runuser", "pkexec", "timeout", "setsid", "stdbuf",
  "watch", "chroot", "flock", "nice", "env", "nohup", "time", "command", "exec",
]);

/**
 * Commands whose STDIN is a PROGRAM: a shell or an interpreter (`python3`, `node`,
 * …), plus the executors that read a script from stdin (`make -f -`, `awk -f -`,
 * `xargs`). Used by `dataCharMask` for `… | <runner>`, where the previous stage's
 * quoted arguments are what the runner executes.
 *
 * Non-shell interpreters are ABSENT from `SHELL_PAYLOAD_RUNNERS` (their `-c`
 * payload is another language, and treating it as shell is the false positive
 * #1485 removes) but PRESENT here: a pipeline stage whose output is fed to an
 * interpreter is a program, which is a different question from what language the
 * text is written in.
 */
const STDIN_PROGRAM_RUNNERS = new Set([
  ...SHELL_PAYLOAD_RUNNERS, "make", "awk", "sed", "xargs",
]);
const STDIN_PROGRAM_INTERPRETER_RE =
  /(^|\/)(python[0-9.]*|node|deno|bun|ruby|perl|php|pwsh|powershell|lua|tclsh)$/;

/**
 * Flags whose VALUE is a program or a script: `osascript -e 'do shell script …'`,
 * `perl -e`, `sed -e`, `pwsh -Command`. A quoted region opened by one of these is
 * executable, whatever the command word is.
 *
 * ⚠️ `-c` is DELIBERATELY ABSENT. It is gh's `--comment`, sed's copy, and the
 * shell's "run this"; the shells are already payload runners by COMMAND WORD, so
 * the only thing adding `-c` here would buy is refusing an interpreter payload
 * that merely quotes a command — the false positive #1485 removes. A `pr merge`
 * pair inside `python3 -c "…"` is python source, not a shell invocation, and the
 * argv-level gh shim is what enforces the merge it might launch (#984).
 */
const EXEC_PAYLOAD_FLAGS = new Set(["-e", "--eval", "--execute", "--command", "-Command"]);

/**
 * Which characters of the command are DATA — quoted text the shell hands to
 * something that prints, stores or parses it, rather than runs?
 *
 * WHY THIS EXISTS (#1485). The scan tokens are split on whitespace and
 * separators REGARDLESS of quote state (that is what lets `"gh" pr merge`,
 * `sh -c '<payload>'` and `gh pr $'merge'` resolve), so the words of a quoted
 * ARGUMENT are indistinguishable from the words of the command: a python
 * payload's docstring line `gh pr merge 8754`, a `--jq` filter, a grep pattern
 * and a PR body all read as invocations. Measured 2026-10-18 in a hub session:
 * two read-only `gh run view` calls plus `grep -viE "^\s*$"` were refused with
 * "more than one `gh pr merge`", and a read-only `gh api` whose payload quoted
 * the rail was refused as an unevidenced admin merge.
 *
 * A quoted region is DATA unless one of these makes it code:
 *   - it is the WHOLE first word of the simple command (`"gh" pr merge 1` — a
 *     fully quoted command name is executable);
 *   - its command word is a SHELL payload runner (`sh -c '<payload>'`, `eval`,
 *     `trap`, `xargs`) — that text is a program;
 *   - it sits in the gh VERB SLOT (the first words after `gh`, where
 *     `gh pr "merge" 1` spells its own verb — quoting never makes an argv word
 *     data);
 *   - it contains a command SUBSTITUTION (`$(…)`, a backtick): bash runs that
 *     even inside double quotes, so everything from the substitution onward
 *     stays readable.
 *
 * ⚠️ DECLARED RESIDUAL — an interpreter payload (`python3 -c "…"`, `node -e "…"`)
 * is DATA here, because a verb pair in another language's source is not a shell
 * invocation: it can only merge a PR by handing an argv to `gh`, a runtime act
 * this text scan cannot see in ANY framing. That case is decided by the
 * argv-level gh shim (#984, `scripts/gh-shim/gh`), which resolves the argv of
 * whatever process calls `gh`; adding interpreters here would refuse every lane
 * command whose payload quotes a command in a docstring — the false positive
 * this function exists to remove.
 *
 * Direction of error: every uncertainty leaves the region EXECUTABLE (the
 * previous behaviour), so an unresolved shape can only add a refusal.
 */
function dataCharMask(scan: ScanTokens): boolean[] {
  const data = new Array<boolean>(scan.joined.length).fill(false);
  const { mask, starts, tokens, joined, gaps } = scan;
  const tokenAt = (pos: number): number => {
    for (let k = 0; k < starts.length; k++) {
      if (starts[k] <= pos && pos < starts[k] + tokens[k].length) return k;
    }
    return -1;
  };
  /** First token of the simple command containing token `i`. */
  const segStart = (i: number): number => {
    let k = i;
    while (k > 0 && !/[;&|(){!\n\r]/.test(gaps[k])) k--;
    return k;
  };
  /** Last token of the simple command containing token `i`. */
  const segEnd = (i: number): number => {
    let k = i;
    while (k + 1 < scan.tokens.length && !/[;&|(){!\n\r]/.test(gaps[k + 1])) k++;
    return k;
  };
  /**
   * Is token `i` inside a PROCESS SUBSTITUTION (`<(…)` / `>(…)`)? Its output is
   * consumed by whatever the FD is attached to — `. <(echo "$S $P $M 9 $V")`
   * SOURCES what echo prints — so the text inside is a program, and the #1776
   * boundary test pins that shape as fail-closed.
   */
  const processSubDepth: number[] = new Array<number>(joined.length).fill(0);
  {
    let depth = 0;
    for (let k = 0; k < joined.length; k++) {
      if (!mask[k]) { processSubDepth[k] = depth; continue; }
      if ((joined[k] === "<" || joined[k] === ">") && joined[k + 1] === "(") {
        depth++;
        processSubDepth[++k] = depth;
        continue;
      }
      if (joined[k] === ")" && depth > 0) depth--;
      processSubDepth[k] = depth;
    }
  }
  const inProcessSub = (i: number): boolean => (processSubDepth[starts[i]] ?? 0) > 0;
  /**
   * Is this simple command's OUTPUT piped into a program runner (`echo "$S $P $M 999
   * $V" | sh`, `… | python3`, `… | make -f -`)? Then its quoted arguments are a
   * PROGRAM, not text: the runner executes whatever the previous stage prints.
   * Missing this was a measured fail-open in the first cut of #1485 — the decoy
   * `gh pr view 1; echo "$C $P $M 999 $V" | python3` read as a non-merge gh call
   * and stood the gate down (pinned by the #1776 boundary test).
   */
  const pipedIntoRunner = (i: number): boolean => {
    const end = segEnd(i);
    if (end + 1 >= scan.tokens.length) return false;
    const gap = gaps[end + 1] ?? "";
    // A PIPE, not `||` (a fallback command does not consume the previous stage's
    // output as a program).
    if (!/(^|[^|])\|([^|]|$)/.test(gap)) return false;
    const next = shellWord(scan.tokens[end + 1]);
    return STDIN_PROGRAM_RUNNERS.has(next) || STDIN_PROGRAM_INTERPRETER_RE.test(next) ||
      // #1485 review: a PATH-spelled shell (`| /bin/sh`, `| /usr/bin/bash`) is the
      // same program as `| sh`, and `| /usr/bin/env sh` is one word away from it —
      // measured bypass: `echo 'gh pr merge 999 --admin' | /bin/sh` read as data.
      /(^|\/)(?:sh|bash|zsh|dash|ksh|ash|mksh|oksh)$/.test(next) ||
      (/(^|\/)(?:env|exec|command|nohup|nice|timeout|setsid|stdbuf|su|doas)$/.test(next) &&
        STDIN_PROGRAM_RUNNERS.has(shellWord(scan.tokens[end + 2] ?? "")));
  };
  let i = 0;
  while (i < mask.length) {
    if (mask[i]) { i++; continue; }
    const s = i;
    while (i < mask.length && !mask[i]) i++;
    const e = i; // [s, e) is one quoted region
    const ti = tokenAt(s);
    if (ti === -1) continue;
    const seg = segStart(ti);
    const cmdWord = shellWord(tokens[seg]);
    const isCommandName =
      ti === seg &&
      starts[ti] === s &&
      starts[ti] + tokens[ti].length === e &&
      !/^[A-Za-z_][A-Za-z0-9_]*\+?=/.test(tokens[ti]);
    const isShellPayload = SHELL_PAYLOAD_RUNNERS.has(cmdWord) ||
      /(^|\/)(?:sh|bash|zsh|dash|ksh|ash|mksh|oksh)$/.test(cmdWord);
    // #1485 review (P0, reproduced): the runner need not be the simple command's
    // FIRST word. `timeout 5 sh -c '<payload>'`, `env FOO=1 bash -c '<payload>'`,
    // `su -c '<payload>'`, `stdbuf -oL sh -c '<payload>'` are all shells running
    // the quoted text, and keying only on `tokens[seg]` read their payload as DATA
    // - which made `countMergeVerbs` 0 for a real admin merge, stood the evidence
    // gate down, and would have landed an unevidenced merge.
    //
    // The rule is deliberately NARROW: a shell payload is introduced by `-c`, and
    // a shell word appears earlier in the same simple command. Scanning "any
    // runner word anywhere earlier" instead was measured (cycle 2) to be a NEW
    // false positive of exactly the class #1485 fixes - `timeout 30 gh issue list
    // --search '<mention>'` and `flock /tmp/lock gh pr comment --body '<mention>'`
    // had their `gh` ARGUMENTS read as programs, counted 1, and were refused. In
    // those the region's introducer is `--search`/`-f`, not `-c`, so they stay
    // DATA. A non-shell interpreter is still not a runner: its `-c` payload is
    // another language's source (see the declared residual); `| python3` - a pipe
    // whose STDIN is the program - is a different question, handled in
    // `pipedIntoRunner`.
    const payloadFlagAfterShell = shellWord(tokens[ti - 1] ?? "") === "-c" && (() => {
      for (let k = seg; k < ti - 1; k++) {
        const w = shellWord(tokens[k]);
        if (!w) continue;
        if (SHELL_PAYLOAD_RUNNERS.has(w) || SHELL_WRAPPER_WORDS.has(w)) return true;
        if (/(^|\/)(?:sh|bash|zsh|dash|ksh|ash|mksh|oksh)$/.test(w)) return true;
      }
      return false;
    })();
    const isGhVerbSlot = /(^|\/)gh$/.test(cmdWord) && ti > seg && ti <= seg + 3;
    const isExecPayload = EXEC_PAYLOAD_FLAGS.has(shellWord(tokens[ti - 1] ?? ""));
    if (isCommandName || isShellPayload || payloadFlagAfterShell || isGhVerbSlot || isExecPayload || pipedIntoRunner(ti) || inProcessSub(ti)) {
      continue; // executable
    }
    // DATA — but a command substitution inside it still runs. Only a
    // DOUBLE-quoted region can carry one: `'…'` is literal all the way through, so
    // a backtick or `$(` written inside single quotes is text (that is the whole
    // point of quoting it, and treating it as a substitution refused commands
    // that merely quote a rail in a sed/python/`-m` argument).
    let from = e;
    if (joined[s] === '"') {
      for (let k = s; k + 1 < e; k++) {
        if (joined[k] === "$" && joined[k + 1] === "(") { from = k; break; }
        if (joined[k] === "`") { from = k; break; }
      }
    }
    for (let k = s; k < from; k++) data[k] = true;
  }
  return data;
}

/** Is the whole of token `i` DATA (quoted text, not the command's own words)? */
function isDataToken(scan: ScanTokens, data: boolean[], i: number): boolean {
  const start = scan.starts[i];
  const end = start + scan.tokens[i].length;
  if (start === undefined || end > data.length) return false;
  for (let k = start; k < end; k++) if (data[k] !== true) return false;
  return true;
}

/**
 * Is the token at `i` in COMMAND position — where the shell RUNS a word rather than passing
 * it as an argument? True at the start of the command, after an unquoted separator (`;`, `&`,
 * `|`, `(`, `{`, or a NEWLINE — bash separates commands on both), after a command introducer
 * (`env`, `time`, …), after `sh -c`, a redirection, an assignment prefix, or a reserved word
 * (`if`, `while`, …).
 *
 * ONE model, TWO consumers: `isGhWordAt` asks "is this word RUN as `gh`?", and the positive
 * read in `readsNonMergeGhCall` asks "could an executable word have been spelled away here?".
 * They MUST agree. The divergence between them was a live bypass (adversarial review, shape
 * 12): this guard knew only `;`-gaps and a shorter keyword list, so the same
 * `$C $P $M 999 $V` decoy written one line lower read as an ARGUMENT position and the
 * command reached the real `gh` as `pr merge 999 --admin`.
 */
function isCommandPositionAt(scan: ScanTokens, i: number): boolean {
  let prev = i === 0 ? null : scan.tokens[i - 1];
  // `bash -c -- '...'` is valid: `--` separates the option from the script. Look
  // THROUGH it, or the introducer stops being recognised (cycle-4 review P0-2).
  if (prev === "--" && i >= 2) prev = scan.tokens[i - 2];
  // The introducer, `-c` and reserved-word tests use the DEQUOTED word: the shell dequotes
  // before it decides, so `"eval"`, `\eval`, `ev"al"`, `"env"`, `sh '-c'` and `bash "-c"`
  // all RUN their next argument — testing the raw token read each of those as an ordinary
  // argument, and a constructed `gh pr merge` walked through the stand-down on it
  // (adversarial review, shape 13). `trap`/`coproc` are introducers for the same reason:
  // `trap "$G $P $M 999 $V" EXIT` executes the string at shell exit (shape 14).
  // The redirection and assignment-prefix tests stay RAW on purpose — a quoted
  // `">/dev/null"` is not a redirection — and staying raw there can only add refusals.
  const prevWord = prev === null ? "" : shellWord(prev);
  return (
    prev === null ||
    // A newline is a command separator too: `gh pr merge 111 --admin\n"gh" pr
    // merge 999 --admin` is two commands. Without \n here the second (fully
    // quoted) verb lost its command position and the compound count stayed 1.
    /[;&|(){!\n\r]/.test(scan.gaps[i]) ||
    COMMAND_INTRODUCERS.test(prevWord) ||
    /^-[a-z]*c$/.test(prevWord) || // `sh -c '...'`, `sh '-c' '...'`
    // Other real command positions. A redirection (`2>/dev/null`, `>/dev/null`),
    // an assignment prefix (`FOO=bar`) or a reserved word (`if`, `while`, ...)
    // all put the next word in command position; enumerating only the introducers
    // and `-c` let `2>/dev/null "gh" pr merge 1 --admin` skip BOTH gates
    // (cycle-4 review P0-1).
    /^(\d*[<>]|&>>?)/.test(prev) || // redirection (`2>/dev/null`)
    // An assignment prefix (`FOO=bar`, and bash's APPEND/ARRAY forms `FOO+=bar`, `FOO[0]=bar`)
    // or a reserved word (`if`, `while`, ...) all put the next word in command position. This
    // test reads the DEQUOTED word (`prevWord`), like the value clause that consults it: with
    // the raw token, a QUOTED `"X=1"` counted as a value for the exemption and as "not an
    // assignment" here, so a command string after it was exempted (`eval "X=1" $'<payload>'`
    // reached the real gh as `pr merge 999 --admin` — adversarial review, shape 20). The two
    // clauses read the same word or they can disagree about the same token.
    /^[A-Za-z_][A-Za-z0-9_]*(?:\[[^\]]*\])?\+?=/.test(prevWord) ||
    /^(if|then|elif|else|while|until|do|done|case|esac|select|in)$/.test(prevWord)
  );
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
  return isCommandPositionAt(scan, i);
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
/**
 * The CONSTRUCT class shared by the verb-read arms below: `$`, a backtick, `{`/`}` and a
 * redirection (`<`/`>`). Each BLINDS a read of the text, and each is removed or rewritten by
 * bash before gh sees it — measured: `gh {pr,merge} 999 $V` and `gh pr >/dev/null merge 999
 * $V` both reach gh as `pr merge 999 --admin`. An arm that stops at substitutions and
 * backticks reads no merge in those shapes, and a merge that reaches gh unread is a merge
 * this gate never saw.
 */
const CONSTRUCT = /[$`{}<>]/;
/**
 * The WORD `merge` — not `admin-merge`, not `mergeStateStatus`, not `hasAdminMergeFlag`. A
 * hyphen or a word character on either side means the text is naming a hyphenated identifier
 * rather than spelling a verb, and that distinction is measured: `<!-- admin-merge-safety: … -->`
 * must not read as a merge verb.
 */
const MERGE_WORD = /(^|[^\w-])merge([^\w-]|$)/;

/**
 * A word as bash would resolve it: quotes stripped (`dequote`) and an ANSI-C LEADING `$`
 * dropped, so `$'pr'` reads as `pr` (bash resolves those before gh runs). A `$` INSIDE a
 * word is a splice rather than a quote, and the construct-in-a-verb-position arm reads it.
 */
function shellWord(tok: string | undefined): string {
  return dequote(tok ?? "").replace(/^\$/, "");
}

/**
 * A word that could actually BE a gh subcommand (`pr`, `issue`, `create`, `update-branch`,
 * …): lowercase letters and hyphens. The shape matters, not the vocabulary — the point is
 * that a residue of the tokenizer's own text-level splitting (`.gh-repo)` out of
 * `--repo=$(cat .gh-repo)`, which bash parses as ONE word) must NOT be read as a
 * subcommand, because reading it as one turns a merge into a "non-merge gh call" and hands
 * the merge to the argv layer. Anything that does not fit fails the positive read, so the
 * admin-merge gate keeps its decision — the fail-CLOSED direction.
 */
const SUBCOMMAND_WORD = /^[a-z][a-z-]*$/;

/**
 * The `pr` subcommands that are NOT a merge. `merge` is deliberately absent, and so is
 * every spelling nobody has written yet: the POSITIVE read is what lets this layer stand
 * down, so a subcommand this list does not know — including the residue of a tokenizer
 * split, which can look exactly like a word — is read as NO positive read and the gate keeps
 * its decision. The list's failure direction is a REFUSAL, which is the direction this file
 * is allowed to be wrong in.
 */
export const PR_NON_MERGE_SUBCOMMANDS = new Set([
  "create", "view", "list", "comment", "close", "reopen", "edit", "diff", "checkout",
  "ready", "review", "status", "lock", "unlock", "checks", "update-branch", "revert",
]);

/**
 * The LONG flags whose next word is a VALUE. Only unambiguous long spellings are here: a
 * short flag is also some other tool's EXECUTE flag — `-c` is gh's `--comment` AND the
 * shell's "run this program" flag, and an exemption keyed on it let
 * `sh -c gh$'\x20'pr$'\x20'merge$'\x20'999$'\x20'$V` stand the text layer down (adversarial
 * review, shape 18). Since the list can only ever be an approximation, every entry must fail
 * in the refusal direction — which is why the ambiguous shorts (`-c`, `-f`, `-e`-likes) are
 * gone and `-q` is spelled `--jq`.
 */
const VALUE_POSITION_FLAGS = new Set([
  "--body", "--body-file", "--subject", "--title", "--author-email", "--match-head-commit",
  "--field", "--raw-field", "--input", "--method", "--message", "--notes", "--comment",
  "--label", "--add-label", "--remove-label", "--assignee", "--reviewer", "--search",
  "--query", "--jq", "--template",
]);

/**
 * A shell REDIRECTION OPERATOR with a resolvable target: `2>&1`, `>&2`, `<&-`,
 * `>/dev/null`, `2>out.txt`, `&>>log`. The shell consumes it before argv exists,
 * so it is not a word and cannot hide one. Enumerated by SHAPE, and anything
 * whose target is not plain (`>"$OUT"`, `>$(mktemp)`) does not match — those
 * keep the fail-closed reading.
 */
const REDIRECTION_TOKEN = /^(?:\d+)?(?:>>?|<<?)(?:&\d+-?|&-|&|\d+|[\w./~+=:@%-]+)?$|^&>>?(?:[\w./~+=:@%-]+)?$/;

/**
 * Does the text POSITIVELY read a gh invocation whose subcommand is written out and is NOT
 * a merge? This predicate — and its POLARITY — is the deferral's gate (#1776): the text
 * layer hands the argv layer only a command it can READ as a non-merge gh call, so every
 * way of blinding that read (a spliced word, brace expansion, a redirection, an empty quote
 * pair, a verb behind a construct or a global flag, a spelling nobody has thought of yet)
 * fails CLOSED — this layer keeps the gate — instead of open. ENUMERATING the spells does
 * not work: four review cycles each found one more blinding shape, every one of them a
 * measured bypass of a real merge, and each fix only moved the boundary to the next
 * spelling. Polarity moves it out of reach: an unreadable command is not a permission.
 *
 * `gh` must be a readable word; the next word must be a readable non-flag (a global flag
 * such as `--hostname` puts the subcommand where this cannot see it); a group other than
 * `pr` is a positive read (`issue`, `api`, `repo`, `run`, `auth`, …); under `pr`, the next
 * word must be readable and not `merge`. EVERY gh invocation in the text must satisfy
 * that, and the text must contain at least one — otherwise the answer is "no positive
 * read" and the admin-merge gate keeps its fail-closed decision. That is why the #1775
 * false positive (an ordinary `gh pr create` whose TITLE carries a construct and the word
 * `admin`) still stands down, while a merge spelled past the tokenizer does not.
 */
export function readsNonMergeGhCall(command: string): boolean {
  const scan = scanTokens(command);
  // #1485: quoted DATA is not this command's own words. A `$`-anchored regex in a
  // grep pattern (`grep -viE "^\s*$"`), a jq filter, a PR body or an inline
  // python payload were each read as a CONSTRUCT in an executable position, which
  // blinded the positive read and handed a read-only command to the evidence gate
  // (measured: two `gh run view` calls refused as "more than one `gh pr merge`").
  // A token wholly inside a data region is skipped by BOTH loops below; the
  // polarity is untouched — a construct OUTSIDE data still fails the read.
  const data = dataCharMask(scan);
  const isData = (i: number) => isDataToken(scan, data, i);
  // NO CONSTRUCT OUTSIDE A VALUE POSITION — the mechanism-level boundary, and the reason this
  // no longer grows a list. Seven review rounds each found a new way for a command to RUN
  // something the text cannot read: a construct in a verb position, a spliced or quoted
  // introducer, `trap`/`coproc`, a program assembled at runtime and piped to a shell, and then
  // the runners the executor list did not carry (`make -f -`, `osascript -e`, `. <(...)`).
  // Every fix was another spelling, so each round produced the next bypass. The property that
  // converges is POSITIONAL: a construct may sit only where a VALUE belongs. Anywhere else it
  // can be an executable word, a verb, a whole command string, or a program handed to a runner
  // the text never names — indistinguishable, so the read fails and this layer keeps the gate.
  for (let i = 0; i < scan.tokens.length; i++) {
    if (isData(i)) continue;
    const tok = scan.tokens[i];
    const w = shellWord(tok);
    if (w !== "gh" && /(^|\/)gh$/.test(w)) return false; // `/tmp/x/gh`, `$P/g''h`
    if (!CONSTRUCT.test(tok)) continue;
    // A REDIRECTION OPERATOR is resolved by the shell before argv exists: `2>&1`
    // contains a `>` but blinds nothing, and reading it as a construct made every
    // command that redirects stderr (or `/dev/null`) fail this positive read —
    // measured: two read-only `gh run view … 2>&1 | tail -3` calls were handed to
    // the evidence gate for a `>` that is not part of any word. A redirect whose
    // target is itself unresolvable (`>$OUT`) does NOT match this shape and keeps
    // the fail-closed reading.
    if (REDIRECTION_TOKEN.test(tok)) continue;
    const prevWord = shellWord(scan.tokens[i - 1] ?? "");
    // `prevWord.includes("=")` covers the `--flag=value` spelling, where the VALUE's opening
    // word carries the `=` (`--title="admin $(x)"`). The TOKEN itself carrying `=` is NOT an
    // exemption: `X=$(date) gh issue comment 5` is an assignment whose value runs a command.
    // And a value position must not be a COMMAND position: an assignment prefix (`Z=ok $R`)
    // puts the next word in command position while carrying `=`, which let a runner word be
    // exempted as a value (adversarial review, shape 18, second half).
    const inValuePosition =
      (VALUE_POSITION_FLAGS.has(prevWord) || prevWord.includes("=")) &&
      !isCommandPositionAt(scan, i);
    if (!inValuePosition) return false; // a `$`-bearing token where a value does not belong
  }
  let seen = false;
  for (let i = 0; i < scan.tokens.length; i++) {
    if (isData(i)) continue;
    if (shellWord(scan.tokens[i]) !== "gh") continue;
    seen = true;
    const group = scan.tokens[i + 1];
    if (group === undefined || CONSTRUCT.test(group)) return false;
    const g = shellWord(group);
    if (!SUBCOMMAND_WORD.test(g)) return false; // a global flag, or a tokenizer residue
    if (g !== "pr") continue; // `issue`, `api`, `repo`, … — read, and not a merge
    const sub = scan.tokens[i + 2];
    if (sub === undefined || CONSTRUCT.test(sub)) return false;
    const s = shellWord(sub);
    if (!SUBCOMMAND_WORD.test(s) || !PR_NON_MERGE_SUBCOMMANDS.has(s)) return false;
    continue; // `create`, `view`, `list`, … — read, and not a merge
  }
  return seen;
}

// ── #2204: a positively-readable READ is not a write ──────────────────────────
//
// MEASURED (2026-10-20, `~/.pi/agent/audit/gate-events.jsonl` on three cells): the
// ≥1-dispatch floor refused `… for n in 2058 2172 …; do gh pr view … done` and
// `for pr in …; do sha=$(gh api repos/…) …; done`. BOTH ARE READS. There is no reviewer to
// dispatch for reading a PR body, so the refusal was a false positive — and four lanes ended
// on it within ~60 s of starting, producing nothing. (A BARE `sha=$(gh api …)` never reached
// the floor — `isGitOp` needs a construct, and a lone substitution has none — so the loop
// WRAPPER is what makes the shape trippable; cycle-2 review measured the difference and the
// tests use the trippable form.)
//
// WHY THE FLOOR SAW A WRITE: the candidate came from `isGitOp`'s CANDIDATE arms, not
// from a write. `isGhPrMergeCommand` is deliberately broad — "any `gh` + `pr` under a
// construct" — and a loop supplies the construct (`$n`), so `gh pr view $n` reads as a
// merge CANDIDATE and falls through to the dispatch count. That is the same
// false-positive class the admin-merge gate fixed in #1776 and #2164, and it needs the
// same POLARITY rather than a longer allowlist: posit what a READ looks like, and refuse
// the escape unless every word of the command can be read as one.
//
// ⛔ A PREFIX LIST OF `gh` VERBS IS NOT THE PREDICATE. The failing shapes put the `gh`
// word INSIDE a shell construct — a `for` loop body, a `$(…)` — so nothing anchors on
// "the command starts with `gh`". This scan walks EVERY `gh` word in the text; the
// tokenizer splits on the shell's separators, including the `(` of `$(…)`, which is what
// makes a substitution's contents readable at all.
//
// ⛔ THIS MUST NOT WIDEN THE FLOOR. It is consulted only on the ZERO-dispatch path, it
// sits AFTER the admin-merge and merge-registry gates, and it answers false the moment
// the text carries a git write, an executable word this scan cannot read, or a program
// piped into a runner. `git commit` / `git push` at zero dispatches stay refused — that
// is pinned by #485 T1/T1b AND by the #2204 tests that pair a read WITH a write.

/**
 * ⛔ THE ESCAPE CERTIFIES **GH READS ONLY** — and this is the third design, chosen because the first
 * two were measurably unsound.
 *
 * DESIGN 1 certified a command when the text carried no known git WRITE verb (a deny list). A
 *   cycle-2 adversarial review shipped `git update-index`, `git checkout-index`, `git ci` and
 *   `git -c alias.p=push p` past it: with a deny list, a MISSING entry GRANTS the escape.
 * DESIGN 2 certified a git READ by allowlisting the subcommand, then (when a flag-named program was
 *   found) the flags, then (when a config key named one) the config namespaces. Each round closed a
 *   layer and the next round found the next one: `git grep -O<program>`, `git ls-remote
 *   --upload-pack=<program>`, `git -c core.pager='!git push' log`, `git -c core.gitProxy=p`,
 *   `git -c remote.o.uploadpack=p`, and finally `git -c protocol.ext.allow=always ls-remote
 *   ext::<program>` — which EXECUTES the program through a POSITIONAL argument, so no flag
 *   allowlist can ever cover it. That is the shape of the problem: git's argument surface is
 *   unbounded in the dimension that matters (any argument can name a program or transform one), and
 *   a text layer cannot read it.
 * DESIGN 3 (this one) removes the dimension instead of narrowing it: a command that mentions `git` at
 *   all is NOT certified here, however it is spelled. `git commit`/`git push` keep the floor (they
 *   are its subject); `git log` beside a read now costs a separate command. That is a real friction
 *   and it is the right trade: an escape from a review gate must not be able to run a program, and
 *   `git rev-parse`, `git log`, `git diff` are all one `;` away from being run on their own line.
 *
 * The measured cost of the false positive this escape exists to fix (`#2204`: four lanes died on
 * `for n in …; do gh pr view $n; done`) is unchanged: that shape and its siblings carry no git word.
 */

/**
 * The `gh` groups whose subcommands only READ, and the subcommands that qualify. An
 * allowlist ON PURPOSE: `create`, `merge`, `edit`, `comment`, `review`, `close`, `delete`,
 * `cancel`, `rerun` and every spelling nobody has written yet are ABSENT, so an unknown
 * sub-word fails the read and keeps the floor. Each entry is a gh READ only; a group that is
 * absent from this map (`secret`, `alias`, `gpg-key`, `ssh-key`, `extension`, … — setup and
 * write commands) makes the whole command fail the escape. `api` is handled separately (its
 * method decides), and `status` takes no subcommand at all (`GH_READ_GROUPS_NO_SUB`).
 */
export const GH_READ_SUBCOMMANDS: Record<string, string[]> = {
  pr: ["view", "list", "diff", "checks", "status"],
  issue: ["view", "list", "status"],
  repo: ["view", "list"],
  run: ["view", "list"], // NOT `download`: it WRITES artifact files into the working tree (#2206 review, P2)
  workflow: ["view", "list"],
  release: ["view", "list"],
  ruleset: ["view", "list"],
  search: ["prs", "issues", "repos", "code", "commits"],
  auth: ["status"],
  config: ["get", "list"],
  label: ["list"],
  gist: ["view", "list"],
  project: ["view", "list"],
};

/** `gh` groups that take no subcommand and only read. */
const GH_READ_GROUPS_NO_SUB = new Set(["status"]);

/**
 * A whole-word shell VARIABLE (`$F`, `$1`, `$@`, `$?`) — the shape that can stand in for a FLAG
 * (`gh api repos/x $F y=1` is `-f y=1`). A variable INSIDE a longer word (`repos/$owner/pulls/$pr`)
 * is a value, which a `gh api` endpoint legitimately is, so it does not match.
 */
const BARE_VARIABLE_WORD = /^\$[A-Za-z_][A-Za-z0-9_]*$|^\$[0-9]+$|^\$[@*?#!$-]$/;

/**
 * `gh api` flags that make the call a WRITE. `-f/--field`, `-F/--raw-field` and
 * `--input` switch gh to POST by themselves, and an explicit non-GET `-X/--method` is a
 * write however the endpoint is spelled. Reads (`--jq`, `--paginate`, `-X GET`, `-H`, …)
 * are untouched. `gh api graphql` is refused outright: a mutation is a write whose verb
 * the text cannot read.
 */
const API_READ_METHODS = new Set(["GET"]);

/**
 * Words that are SAFELY stripped before the executable: quote pairs and backslashes. `''git`,
 * `"git"`, `g"i"t` and `\git` all EXECUTE `git`, and a cycle-2 review measured all four certifying a
 * `commit` as a read because the write scan compared RAW words while every other predicate in this
 * file compares DEQUOTED ones. Normalizing the same way closes the class: an unreadable splice is a
 * refusal, never a pass.
 */
function normalizeProgramWord(w: string): string {
  return w.replace(/["'\\]/g, "");
}

/**
 * Does the text mention `git` anywhere — as a WORD, through the shell's own quoting?
 *
 * Deliberately blunt: `''git`, `\git`, `"git"`, `g"i"t` and `$'git'` all EXECUTE git, and design 2
 * lost the floor's own two verbs to exactly that splice, so the word is NORMALIZED the way the shell
 * would (`normalizeProgramWord` strips quotes and backslashes) before it is compared. A mention in a
 * quoted message (`-m "fix: git push"`) costs a refusal — it did before #2204 as well, through the
 * same `GIT_COMMIT_PATTERN`, and a mention is never worth an escape.
 */
function mentionsGitWord(command: string): boolean {
  if (GIT_COMMIT_PATTERN.test(command)) return true;
  // ⛔ NO `stripRepoArgs` ON THIS SCAN (#2206 review, P0 — see `scanTokens`' `stripRepo` note).
  // The stripped form is the right view for reading a VERB, and the wrong view for asking whether
  // `git` is mentioned: the strip eats the word after `--repo`, so a `git` sitting there vanished
  // and this predicate answered false. `GIT_COMMIT_PATTERN` caught `git commit`/`git push` on the
  // RAW text and nothing else, so every other write verb — and an alias push, the exact DESIGN-1
  // class — was certified. Both spellings are pinned in `index.test.ts` (negative table).
  for (const token of scanTokens(command, { stripRepo: false }).tokens) {
    if (normalizeProgramWord(token) === "git") return true;
  }
  return false;
}

/**
 * Programs a `$(…)` may run and still leave the command READABLE: each WRITES NOTHING and RUNS
 * NOTHING but itself — it computes a value from its arguments and prints it.
 *
 * ⛔ `sort` AND `uniq` WERE HERE AND WERE MEASURED WRITING FILES AND RUNNING PROGRAMS: `sort
 * --compress-program=<program>` executes that program, `sort -o <file>` and `uniq <in> <out>`
 * overwrite any file the session can write. Only the substitution's FIRST WORD was ever checked, so
 * an "harmless" program's own flags were the hole. Every entry here is now a program whose whole
 * argument surface is data — and `gh` is the only other name accepted, validated by the gh loop.
 *
 * ⛔ THIS LIST IS NOT WHAT MAKES A `gh api` CALL READ-ONLY, AND IT MUST NOT BE ASKED TO BE (#2206
 * review, P0). "Its whole argument surface is data" is a claim about a program's INPUTS; it says
 * nothing about its OUTPUT, and `printf` can ASSEMBLE any word: `gh api $(printf -- '-%s%s' X POST)
 * repos/o/r/pulls/1/merge` expands to the single argv word `-XPOST`, so the write flag never exists
 * in the text for `hasApiWriteFlagAnywhere` to find — it certified a merge and a PR self-approval.
 * Narrowing this list would be the DESIGN-2 loop (one layer closed per review round), so the
 * SUBSTITUTION DIMENSION is removed for the one gh verb that writes: `readsOnlyGhRead` refuses any
 * `gh api` whose argument list contains a substitution (`apiSegmentReads…`). `printf` stays usable
 * where its output is a VALUE (`gh pr view $(printf '%s' 5)`), which is what it was added for.
 */
const HARMLESS_SUBSTITUTION_PROGRAMS = new Set([
  "basename", "cut", "date", "dirname", "echo", "head", "hostname", "id", "jq", "mktemp",
  "md5sum", "printf", "pwd", "readlink", "realpath", "seq", "sha256sum", "tail", "tr", "wc",
  "whoami",
]);

/**
 * Is there a `gh api` WRITE flag in this scan, anywhere? `-f/--field`, `-F/--raw-field` and
 * `--input` switch gh to POST by themselves, and a non-GET `-X/--method` is a write however the
 * endpoint is spelled — including the ATTACHED spellings (`-fbody=x`, `-XPOST`), which pflag parses
 * exactly like the detached ones (a detached-only check let a PR self-approval read as a GET).
 * Defence in depth against the tokenizer splitting a substitution into its own statement; the
 * per-segment check in `readsOnlyGhRead` catches the same flags in their normal position.
 */
function hasApiWriteFlagAnywhere(scan: { tokens: string[] }): boolean {
  const at = (i: number) => normalizeProgramWord(scan.tokens[i] ?? "");
  const isGet = (v: string) => v.toUpperCase() === "GET";
  for (let i = 0; i < scan.tokens.length; i++) {
    // ⛔ QUOTED TOKENS ARE INCLUDED, deliberately. The data mask says "this span is DATA", and for a
    // `gh` invocation that is exactly wrong twice: `gh api x "-fbody=APPROVE"` and
    // `gh api x "$F=APPROVE"` both hand gh a WRITE flag as one argv word, because the shell strips
    // the quotes and expands the variable BEFORE argv exists. The per-segment api loop still skips
    // quoted spans (it reads structure); this check reads the argv the shell will actually build.
    const w = at(i);
    if (w === "-f" || w === "-F" || w === "--field" || w === "--raw-field" || w === "--input") return true;
    if (/^--(?:field|raw-field|input)=/.test(w)) return true;
    if (/^-[fF]./.test(w)) return true; // attached: `-fbody=x`, `-Fbody=@f`
    // ⛔ A VARIABLE GLUED TO `=` IN AN ARGUMENT (confirming review, decisive): `BARE_VARIABLE_WORD`
    // only matches a WHOLE variable, so `F=-fbody; gh api … $F=APPROVE` reached gh as
    // `-fbody=APPROVE` — a POST field, i.e. a PR self-approval — and was certified a read. The
    // expansion happens before argv exists, so this layer compares what the shell WILL produce:
    // a word whose expanded head is a variable immediately followed by `=` is a flag this text
    // cannot read. (`?per_page=$n` is the opposite order and stays readable.)
    if (/^\$(?:\{?[A-Za-z_][A-Za-z0-9_]*\}?|\d+)=/.test(w)) return true;
    if (w === "-X" || w === "--method") return !isGet(at(i + 1));
    if (/^--method=/.test(w)) return !isGet(w.slice("--method=".length));
    if (/^-X./.test(w)) return !isGet(w.slice(2));
  }
  return false;
}

/**
 * An executable whose BEHAVIOUR is a file (or a runner) this scan cannot read — `./push.sh`,
 * `bash scripts/x.sh`, `node build.js`, `source env.sh`, `xargs …`. Any of them can run git work, so
 * the read-only escape must not certify a command that runs one. A path (`includes("/")`) counts
 * too: `/usr/bin/gh` and `$P/run` are programs whose words are not in this text.
 *
 * SCOPE — AND A DECLARED WIDENING. This predicate certifies GIT work and gh writes; an arbitrary
 * program called by bare name (`rm`, `curl`, a compiled binary) is NOT certified, and when it is
 * bundled with a certified read the command is ALLOWED here even though the pre-#2204 gate refused
 * it whenever a construct made it a candidate (`for f in 1 2; do rm -rf /tmp/wt/$f; gh pr view $f; done`
 * — measured by a fresh review). That widening is DELIBERATE and it is stated rather than implied:
 * the floor's subject is review-before-shipping, not general command safety, and destructive
 * filesystem/git operations are held by their own gates (`extensions/main-worktree-guard`,
 * `extensions/verification-gate`) which do not depend on a dispatch count. Enumerating the
 * dangerous binaries here is the spelling-trap this file's doctrine rejects; certifying only a
 * read-only coreutils vocabulary instead would refuse the loop variables and globs that every
 * triage loop contains — the false positive #2204 exists to remove.
 */
/**
 * Programs whose ARGUMENTS can ship or mutate something no reviewer saw, so a command that
 * RUNS one is not a read even when the word `git` never appears.
 *
 * #2204's rule (1) refuses any command that MENTIONS git, which closes the git-shaped writes.
 * It does not close a remote write spelled WITHOUT git — measured at zero dispatches beside a
 * `gh pr view` read (fresh review, P2), each certified as a read and each really shipping:
 *   … ; curl -s -X PUT -H "Authorization: token $T" --data @c.json https://api.github.com/…
 *   … ; npm publish --access public
 *   … ; rsync -a ./ host:/srv/app/
 * ⛔ THIS IS A DENY LIST, SO IT IS INCOMPLETE BY CONSTRUCTION. The fail-closed form is a POSITIVE
 * allowlist of command-position words, which is a larger change than #2204 makes; the residual is
 * filed as #2755 (`osascript -e 'do shell script …'`, `rm -rf <dir>`, and `alias x=/tmp/p.sh; x`
 * are each certified a read at zero dispatches today) rather than implied closed by this set.
 */
const REMOTE_WRITE_PROGRAMS = new Set([
  "curl", "wget", "http", "https", "httpie", "nc", "ncat", "netcat", "socat",
  "npm", "npx", "pnpm", "yarn", "bun",
  "pip", "pip3", "gem", "cargo", "dotnet",
  "rsync", "scp", "sftp", "ftp", "sshpass",
  "aws", "gcloud", "az", "fly", "flyctl", "vercel", "netlify", "heroku",
  "docker", "podman", "kubectl", "helm", "terraform", "ansible", "ansible-playbook",
  "hub", "tea", "glab",
]);

function isUnreadableProgramWord(w: string): boolean {
  if (w === "") return false;
  if (w.includes("/")) return true;
  if (/\.(?:sh|bash|zsh|py|js|mjs|cjs|ts|rb|pl|php|ps1|bat|cmd)$/.test(w)) return true;
  return (
    SHELL_PAYLOAD_RUNNERS.has(w) ||
    STDIN_PROGRAM_RUNNERS.has(w) ||
    STDIN_PROGRAM_INTERPRETER_RE.test(w) ||
    REMOTE_WRITE_PROGRAMS.has(w)
  );
}

/**
 * Is token `i` the FILE TARGET of a redirection that belongs to a command already present
 * (`done > /tmp/out.txt`), as opposed to a word the shell will RUN (`> /dev/null /bin/bash`)?
 *
 * ⛔ THE OLD TEST WAS `REDIRECTION_TOKEN.test(tok(i - 1))`, AND IT WAS A P0 BYPASS (#2206 review).
 * Separators are stripped from TOKENS and survive only in the GAP, so in
 * `done >/dev/null; /bin/bash /tmp/x.sh` the previous TOKEN of `/bin/bash` is the redirection
 * `>/dev/null` although a `;` sits between them. The program check was therefore skipped and the
 * script RAN — a command certified "Read-only … the ≥1-dispatch floor covers writes, not reads"
 * that executed an unreviewed `/tmp/x.sh` (reproduced through the real `tool_call` handler).
 *
 * The target is now recognised POSITIONALLY: directly attached to its operator, ending its
 * segment, and with a command before the operator to attach the redirection to.
 */
/**
 * Is token `i` the COMMAND WORD of its own simple command — i.e. is the first word the shell
 * would resolve as a program here?
 *
 * ⛔ `isCommandPositionAt` CANNOT ANSWER THIS, AND ASSUMING IT DID WAS A P0 BYPASS (#2206 cycle-3
 * review). It reads the IMMEDIATELY preceding token, so a redirection whose TARGET is a separate
 * word puts that target between the operator and the program:
 *
 *     for n in 1; do gh pr view $n; done; > a /bin/bash /tmp/x.sh
 *
 * `/bin/bash`'s previous token is `a`, which is neither a separator nor an introducer, so
 * `isCommandPositionAt` said "not a command position" — while bash opens `a`, then RUNS `/bin/bash`
 * as the command of that segment. The command was certified `Read-only … the ≥1-dispatch floor
 * covers writes, not reads` and the script RAN (reproduced through the real `tool_call` handler).
 * Adding the target to the redirection spellings is not enough: the same hole is reached through
 * `2>&1`'s `&`-residue, so the question is answered POSITIONALLY instead.
 *
 * A word is the command word when everything between it and its segment start is EXCUSED: a
 * redirection operator, a word that is some operator's TARGET, an assignment prefix (`FOO=1`) or a
 * reserved word (`done`). The first word that is none of those is the command; every word after it
 * is an argument, and an argument is data to the shell — `gh pr view 1 > a /bin/bash` passes
 * `/bin/bash` to `gh`, it never runs it.
 */
function isSimpleCommandWordAt(scan: ScanTokens, i: number): boolean {
  const isSeparator = (gap: string | undefined): boolean => /[;&|(){!\n\r]/.test(gap ?? "");
  const reservedWord = /^(if|then|elif|else|while|until|do|done|case|esac|select|in)$/;
  const assignmentPrefix = /^[A-Za-z_][A-Za-z0-9_]*(?:\[[^\]]*\])?\+?=/;
  let j = i - 1;
  while (j >= 0) {
    const t = scan.tokens[j] ?? "";
    // A word directly after a redirection operator is that operator's TARGET, so it is never a
    // command word: `> a /bin/bash` opens `a` and then still needs its command. Consume the pair.
    if (j >= 1 && REDIRECTION_TOKEN.test(scan.tokens[j - 1] ?? "")) {
      j -= 2;
      continue;
    }
    const excused =
      REDIRECTION_TOKEN.test(t) ||
      assignmentPrefix.test(shellWord(t)) ||
      reservedWord.test(shellWord(t));
    if (!excused) return false; // a real word precedes → `i` is an ARGUMENT, not a program
    // A separator BEFORE this excused token means nothing earlier belongs to this command.
    if (isSeparator(scan.gaps[j])) return true;
    j--;
  }
  return true;
}

/**
 * Is there an UNQUOTED single `|` in the gap before token `i`?
 *
 * ⛔ THE PIPE TEST READ THE RAW GAP, SO A QUOTED `|` COUNTED AS A PIPE (#2206 cycle-3 review, P1).
 * The tokenizer splits on the character, so in the fleet's ordinary triage read
 *
 *     gh pr view $n --json comments --jq '.[] | .body'
 *
 * the quoted filter becomes the tokens `.[]`, `|`, `body'`, and the stage test then read `body` as a
 * pipeline STAGE — which is not a readable filter, so the read was refused. Same for
 * `grep -E 'open|closed'`. The shell runs neither as a pipe: both sit inside quotes, which the
 * shared parser's own `mask` (`unquotedMask`, #966) already records per character, so the test
 * consults it rather than re-deriving quote state here.
 */
function hasUnquotedPipeInGap(scan: ScanTokens, i: number): boolean {
  const gap = scan.gaps[i] ?? "";
  if (!gap.includes("|")) return false;
  const gapStart = (scan.starts[i] ?? 0) - gap.length;
  for (let k = 0; k < gap.length; k++) {
    if (gap[k] !== "|") continue;
    if (scan.mask[gapStart + k] !== true) continue; // inside quotes → data, not a pipe
    if (gap[k - 1] === "|" || gap[k + 1] === "|") continue; // `||` is a separator, not a pipe
    return true;
  }
  return false;
}

function isTrailingRedirectTarget(scan: ScanTokens, i: number): boolean {
  if (i < 1) return false;
  if (!REDIRECTION_TOKEN.test(scan.tokens[i - 1])) return false;
  // A separator between the operator and this word starts a NEW command, so this word is not a
  // target — it is whatever that new command runs.
  if (/[;&|(){!\n\r]/.test(scan.gaps[i] ?? "")) return false;
  // A target may be followed by MORE REDIRECTIONS of the same command (`> out 2>&1`, `> out 2>err`,
  // `> out <in`) but not by another command WORD. ⛔ The first version demanded this word END its
  // segment, which refused the canonical `> out 2>&1` — the exact loop shape this exemption exists
  // to protect (`for n in …; do gh pr view $n; done > /tmp/out 2>&1`) — and made the verdict depend
  // on the ORDER of the two redirections (#2206 review, P1 over-block).
  let segEnd = i;
  while (segEnd + 1 < scan.tokens.length && !/[;&|(){!\n\r]/.test(scan.gaps[segEnd + 1] ?? "")) segEnd++;
  for (let k = i + 1; k <= segEnd; k++) {
    if (
      !REDIRECTION_TOKEN.test(scan.tokens[k] ?? "") &&
      !REDIRECTION_TOKEN.test(scan.tokens[k - 1] ?? "")
    ) return false;
  }
  // `> /dev/null /bin/bash`: the operator has no command to attach to, so the word after it is the
  // command, not a target (the shell runs `/bin/bash` there).
  if (i < 2) return false;
  return !/[;&|(){!\n\r]/.test(scan.gaps[i - 1] ?? "");
}

/**
 * Does the command POSITIVELY read as read-only gh work? (agent-infra#2204)
 *
 * TRUE only when ALL of these hold:
 *   1. NO `git` WORD AT ALL (`mentionsGitWord`). This is the third design and it is deliberately
 *      blunt: every attempt to CERTIFY a git read by reading its text was measured unsound, and the
 *      last one (`git -c protocol.ext.allow=always ls-remote ext::<program>`) runs a program through a
 *      POSITIONAL argument, which no flag allowlist can see. `git log`/`git rev-parse` beside a read
 *      is therefore refused — run it on its own line;
 *   2. every non-data `gh` word is followed by a readable group + sub-word that is a
 *      gh READ — `pr view`, `issue view`, `api <GET-shaped>`, … — and at least ONE such
 *      word exists (an empty answer is not a read);
 *   3. no OPAQUE EXECUTABLE WORD: a construct in a command position (`$CMD`, `$'…'`,
 *      `${V}`, a `"$S"` handed to `sh -c`) could be the executable this scan cannot read,
 *      so it fails the read. Two exemptions, both of which leave the text READABLE rather
 *      than trusted: a REDIRECTION operator (the shell consumes it before argv exists)
 *      and a token whose dequoted form ends with `$` — a `$(…)` OPENING — but ONLY when the
 *      substitution's own command word is `gh` (`gh api …`), which is the shape #2204's
 *      `sha=$(gh api …)` evidence needs and the only thing this layer can read inside a
 *      substitution. A wider exemption is a measured false PASS: `gh pr view 1; $(cat /tmp/f)`
 *      with `git push` in `/tmp/f` EXECUTES that output, and the first version allowed it
 *      (fresh review, P1);
 *   4. every PIPELINE STAGE is a known data filter whose arguments cannot run a program or open
 *      an output file (`READ_PIPELINE_FILTERS` + `DATA_FILTER_SCRIPT_EXECUTES`). A shell or an
 *      interpreter reads its PROGRAM from that stream (`… | sh`, `… | python3`) and is refused, as
 *      is a WRAPPER WORD that hides one (`… | env -i bash`, `… | xargs -n1 sh`) and a filter SCRIPT
 *      that executes (`… | sed '1e /tmp/x.sh'`). Pure filters (`| jq`, `| head`, `| sed -n '3,12p'`)
 *      process the data and run nothing, so they stay allowed — refusing them would re-create
 *      #2204's false positive for the ordinary `gh pr view … --json body | jq -r .body` read.
 *
 * Any doubt answers FALSE and the floor keeps its decision. The polarity is the point:
 * an unreadable command is NOT a permission — the same rule as `readsNonMergeGhCall`,
 * applied to "is this a write" instead of "is this an admin merge".
 */
/**
 * Pipeline stages a zero-dispatch READ may be piped into — a POSITIVE allowlist of filters that
 * print what they are handed and cannot start a process.
 *
 * ⛔ Deliberately ABSENT, each for a measured reason: every shell and interpreter (`| sh`,
 * `| python3` — they read their PROGRAM from the stream); the wrapper words that hide one one token
 * later (`env`, `exec`, `command`, `nohup`, `nice`, `timeout`, `setsid`, `stdbuf`, `xargs` — the
 * first cut tested only the token immediately after the `|` and certified `| env -i bash` and
 * `| xargs -n1 sh`); and the filters whose FLAGS or second argument open an OUTPUT file (`sort -o f`,
 * `uniq in out`, `tee`), which is why `HARMLESS_SUBSTITUTION_PROGRAMS` excludes them too. `sed` and
 * `awk` are here because the triage corpus reads through them, and their SCRIPT is checked instead.
 */
const READ_PIPELINE_FILTERS = new Set([
  "jq", "head", "tail", "cut", "tr", "wc", "grep", "rg", "cat", "column", "nl", "rev", "fold",
  "sed", "awk",
]);

/**
 * The `sed`/`awk` SCRIPT constructs that EXECUTE or WRITE — the reason a data filter still needs
 * its arguments read.
 *
 * Measured bypass in the first cut: `… | sed '1e /tmp/x.sh'` was certified as a read and ran the
 * file (sed's `e` command executes the pattern space; `w`/`W` write one), and awk's `system()` /
 * `print > "f"` / `"cmd" | getline` do the same. An ordinary print script (`3,12p`, `s/a/b/`,
 * `NR>1`) matches none of these and stays a read.
 */
/**
 * Per-filter flags that turn a data filter into a program runner or an in-place writer.
 *
 * `-f`/`--file` puts the SCRIPT out of the command text, which is the only thing the
 * `DATA_FILTER_SCRIPT_EXECUTES` check can read. `rg --pre=<PROGRAM>` runs that program to
 * preprocess every file it searches. `sed -i`/`--in-place` and `awk -i inplace` WRITE.
 * `awk -E`/`--exec` is gawk's second `-f` spelling. Each is a measured bypass (#2206 review).
 *
 * Letters are matched only on an all-letters short bundle (`-n`, `-ni`), so `awk -F,` and
 * `sed -n '3,12p'` stay reads; `-F` (field separator) is deliberately NOT in awk's set.
 */
// ⛔ A `Map`, NOT a `Record` OBJECT (#2206 review, P1 — caught by this suite's own
// `gh constructor view 2` / `gh toString pr view 1` pins). A plain object lookup returns
// `Object.prototype.constructor` for the word `constructor`, so `badLong.test` threw out of the
// gate instead of returning a verdict. The same hazard exists for `__proto__` and `toString`.
const PIPELINE_FILTER_FORBIDDEN_LETTERS = new Map<string, string>([
  ["sed", "if"],
  ["awk", "fEi"],
]);
const PIPELINE_FILTER_FORBIDDEN_LONG = new Map<string, RegExp>([
  ["sed", /^--(?:in-place|file)/],
  ["awk", /^--(?:file|exec|include)/],
  ["rg", /^--pre/], // `--pre=<PROGRAM>` runs it; `--pre-glob` only pairs with it
]);

const DATA_FILTER_SCRIPT_EXECUTES =
  // The sed `e`/`w`/`W` COMMAND. The preceder class includes the QUOTES: a script is normally
  // written `sed '1e /tmp/x.sh'`, so the address is preceded by `'` and an anchor of `;{}` +
  // whitespace alone missed every real spelling of it (caught by re-running the probe).
  // ⛔ THE SCRIPT'S ADDRESS CAN BE A REGEX, SO THE PRECEDER CLASS MUST INCLUDE `/` AND `\`
  // (#2206 review, P1). The address group `([0-9$,/]*)` cannot match `/touch/`, so `sed '/touch/e'`
  // was certified a read and GNU sed RAN the pattern space. The trail is now a negative lookahead
  // instead of a terminator class: a bare `e`/`w`/`W` not inside a longer word is a sed command
  // letter wherever it sits. Appending `'`/`}`/`"`/`/`/`\` covers the spellings measured escaping.
  // A script whose `e`/`w` is part of a word (`/end/`, `NR>1`, `print`) still reads, because the
  // lookahead refuses only a STANDALONE letter.
  /(^|[;{}\s'"\/\\])(?:[0-9$,/]*|\/(?:\\.|[^\\/])*\/)\s*[ewW](?![A-Za-z])|s\/(?:\\.|[^\\/])*\/(?:\\.|[^\\/])*\/[a-z]*[ew]|system\s*\(|\b(?:print|printf)\b[^;{}]*[>|]|\|\s*getline/;

/**
 * Is the token at `k` part of a command substitution (`$(…)` or a backtick body)?
 *
 * The tokenizer splits `$(…)` on its `(` — the `$` ends one token and the program starts the next —
 * so the opening is visible only as a `$`-terminated word whose following GAP contains `(`.
 * ⛔ `${VAR}` IS **NOT** EXEMPT, AND THAT IS THE FAIL-CLOSED ANSWER (#2206 review, P2 — the
 * previous text here claimed the opposite). Its gap is `{`, not `(`, so it is not a substitution
 * this layer can read, and it is refused. An UNQUOTED `${VAR}` also undergoes word splitting: it
 * can expand to `git push`, so a doc that called `repos/${R}/pulls` readable was describing
 * behaviour the code never had, in the direction that costs a merge. Refusing it costs a retry.
 * readable). A backtick is a substitution wherever it appears.
 */
function hasSubstitutionAt(scan: { tokens: string[]; gaps: string[] }, k: number): boolean {
  const t = scan.tokens[k] ?? "";
  if (t.includes("`")) return true;
  return /\$$/.test(dequote(t)) && (scan.gaps[k + 1] ?? "").includes("(");
}

export function readsOnlyGhRead(command: string): boolean {
  if (mentionsGitWord(command)) return false;
  const scan = scanTokens(command);
  const data = dataCharMask(scan);
  const isData = (i: number) => isDataToken(scan, data, i);
  const tok = (i: number) => scan.tokens[i] ?? "";
  const word = (i: number) => shellWord(tok(i));
  const endOfSegment = (i: number): number => {
    let k = i;
    while (k + 1 < scan.tokens.length && !/[;&|(){!\n\r]/.test(scan.gaps[k + 1] ?? "")) k++;
    return k;
  };

  // (2b) A `gh api` WRITE flag ANYWHERE, not only in the api call's own segment. A substitution is
  // checked here as well as in the api loop because the TOKENIZER splits on the `(` of `$(…)`: the
  // flag's tokens land in their own statement, so the per-segment scan never sees them. That is the
  // measured shape `gh api repos/x $(echo -f title=pwn)` — and it is why the harmless-substitution
  // allowlist below cannot be the only defence: `echo` is a legitimate program whose OUTPUT can be
  // flags. Quoted spans are DATA (`isData`), so `-m "fix: -f x"` and a jq filter cost nothing.
  let apiPresent = false;
  for (let i = 0; i + 1 < scan.tokens.length; i++) {
    if (!isData(i) && word(i) === "gh" && word(i + 1) === "api") apiPresent = true;
  }
  if (apiPresent && hasApiWriteFlagAnywhere(scan)) return false;

  // (3) No opaque executable word, and no unreadable PROGRAM.
  //
  // ⛔ THIS LOOP DOES NOT SKIP DATA TOKENS BEFORE THE PROGRAM TEST (#2206 review, P0). `isData(i)`
  // used to be the first statement, and `isCommandName` only calls a quoted region a command name
  // when it is the FIRST token of the simple command — so an assignment or redirection prefix
  // demoted it to plain DATA and the program test never ran. Each of these RAN the script:
  //   gh pr view 1; X=1 "/tmp/x.sh"
  //   gh pr view 1; >/tmp/o "/tmp/x.sh"
  //   gh pr view 1; 2>/dev/null "/tmp/x.sh"
  // Quoting never prevents execution, so DATA status cannot excuse a token the shell runs. The
  // predicate below therefore applies to EVERY token; only the checks AFTER it (which read the raw
  // token for constructs and substitutions) stay data-exempt, because a quoted region is data to
  // those questions and owes them nothing.
  for (let i = 0; i < scan.tokens.length; i++) {
    const t = tok(i);
    // A shell/interpreter/script in a COMMAND position runs words this text does not contain.
    // Redirections are exempt, and so is their TARGET: `done > /tmp/out.txt` is not a program
    // (the shell opens the file before argv exists), and reading it as one refused every loop that
    // captured its own output — a shape #2204's evidence loops use. A PIPED-IN stage is exempt too:
    // its stdin is data, so `… | sed -n '3,12p'`, `… | awk 'NR>1'` and `… | jq .body` run nothing
    // (refusing them refused the ordinary `gh pr view … --json body | jq -r .body` read — fresh
    // review, P2). The pipeline case is judged by the shell/interpreter test in (4), not here.
    const gapBefore = scan.gaps[i] ?? "";
    const pipedIn = hasUnquotedPipeInGap(scan, i);
    // A WORD FRAGMENT directly attached to a substitution close is not necessarily a program: in
    // `gh pr view $(gh api repos/x --jq .a)/x` the `/x` token is the tail of a view ARGUMENT.
    // ⛔ The earlier example of this shape was `gh api repos/o/r/commits/$(gh api repos/x --jq
    // .sha)/check-runs`, and it does NOT hold: the `gh api` arm refuses ANY substitution in its
    // argument list (`hasSubstitutionAt`), deliberately, because an `echo`-fed flag is a write
    // (`gh api repos/x $(echo -f title=pwn)`). So the api spelling is refused by that arm before
    // this exemption can be reached — the exemption is live only for the non-api read verbs.
    //
    // ⛔ EVERY LEXICAL VERSION OF THIS TEST WAS A P0 BYPASS (#2206 review, two rounds). Round 1
    // exempted anything whose gap merely ENDED in `)` (`.trimEnd()`), so `$(…) /bin/bash` with a
    // SPACE counted. Round 2 required direct attachment and `!tok(i-1).endsWith("/")`, which still
    // certified `$(echo)/bin/bash` — the previous token is `/bin`, which does not end with a slash,
    // and bash assembles `/bin/bash` across the closer. Both RAN.
    //
    // The question is not how the fragment is SPELLED but whether the ASSEMBLED word is in command
    // position — and `isCommandPositionAt(scan, i)` cannot answer it, because `)` is itself in its
    // separator class, so it says "command position" for `repos/…/sha/check-runs` too. The opener
    // can answer it: the assembled word starts where the substitution opened, so it is a command
    // exactly when that opener is.
    const closerOpener = ((): number | null => {
      if (!/[)}\]]$/.test(gapBefore)) return null;
      for (let k = i - 1; k >= 0; k--) {
        if (/\$$/.test(tok(k)) && /^\s*\(/.test(scan.gaps[k + 1] ?? "")) return k;
      }
      return null;
    })();
    const attachedToClose =
      closerOpener !== null && /^\//.test(t) && !isCommandPositionAt(scan, closerOpener);
    // ⛔ A QUOTED WORD IN COMMAND POSITION IS STILL THE COMMAND (#2206 review, P0) — see the loop
    // header. This is the ONLY question a data token owes; below here the raw token is read for
    // constructs and substitutions, which a quoted region is data to.
    // ⛔ ONE COPY, AND `isSimpleCommandWordAt` IS WHY (#2206 cycle-3 review, P0 + P2). The
    // redirection-clause of `isCommandPositionAt` reads only the token IMMEDIATELY before the word,
    // so `> a /bin/bash` slipped through: the target `a` sat between the operator and the program.
    // The predicate is now answered positionally (see `isSimpleCommandWordAt`), and the SECOND,
    // byte-identical copy of this condition that used to follow the `isData` skip is deleted — it
    // could never be reached (same inputs, same expression), and it read as a class covered twice.
    if (
      !pipedIn &&
      !attachedToClose &&
      !isTrailingRedirectTarget(scan, i) &&
      (isCommandPositionAt(scan, i) || isSimpleCommandWordAt(scan, i)) &&
      !REDIRECTION_TOKEN.test(t) &&
      isUnreadableProgramWord(word(i))
    ) return false;
    if (isData(i)) continue;
    // Shell STRUCTURE (`{ …; }`, a subshell's parens, `[ … ]`) is not a program. Its BODY is scanned
    // on its own, so skipping the brace neither widens nor narrows what runs — `{ cut …; } | tr …`
    // was refused only because `{` sat in a command position (measured on the corpus).
    if (/^[{}()[\]]+$/.test(t)) continue;
    if (!CONSTRUCT.test(t)) continue;
    if (REDIRECTION_TOKEN.test(t)) continue; // `2>&1`, `>/dev/null` — not a word
    if (word(i) === "gh") continue; // the `` `gh` `` wrapper: read by the gh loop below
    // A `$(…)` OPENING is a substitution, and it RUNS. This layer can read one only when the
    // substitution's own command word is a KNOWN-LOCAL one, so the check is BEFORE the
    // command-position test — an ARGUMENT substitution runs too, and `gh api repos/x $(echo -f
    // title=pwn)` supplies a WRITE flag from inside one (fresh review, P1).
    //
    // The allowlist, not a blanket exemption: `$(cat /tmp/f)` executes whatever the file prints, and
    // the first version allowed it (fresh review, P1). `gh` is validated by the gh loop below; the
    // rest are programs whose whole argument surface is data (`HARMLESS_SUBSTITUTION_PROGRAMS` — and
    // `sort`/`uniq` are NOT there, because their flags were measured writing files and running
    // programs). `git` is NOT there either: `mentionsGitWord` refuses the whole command, so a
    // `$(git rev-parse HEAD)` costs a refusal like any other git mention.
    if (/\$$/.test(dequote(t))) {
      const nextTok = tok(i + 1);
      if (nextTok !== "" && !CONSTRUCT.test(nextTok)) {
        const inner = normalizeProgramWord(nextTok);
        if (inner === "gh" || HARMLESS_SUBSTITUTION_PROGRAMS.has(inner)) continue;
      }
      return false;
    }
    if (!isCommandPositionAt(scan, i)) continue; // an ARGUMENT (a value), not an executable
    return false;
  }

  // (4) Every PIPELINE STAGE must be a data filter that cannot run a program or open an output
  // file.
  //
  // ⛔ POSITIVE ALLOWLIST, NOT A LIST OF SHELLS. The first cut refused a shell/interpreter in the
  // token IMMEDIATELY after the `|`, and that certified three writes at ZERO dispatches (fresh
  // review, P1 — each reproduced through the real `tool_call` handler before it was fixed):
  //
  //   … | sed '1e /tmp/x.sh'   sed's `e` command RUNS /tmp/x.sh — whatever may be in it
  //   … | env -i bash          the runner is one WRAPPER WORD past the pipe, so the shell test
  //   … | xargs -n1 sh         never sees it; xargs builds a command from the stream
  //
  // A stage that is not a KNOWN filter is therefore refused: `env`, `xargs`, `sudo`, `nice`, a
  // shell, an interpreter, and also `sort`/`uniq`/`tee`, whose flags and second argument open
  // OUTPUT files (`sort -o f`, `uniq in out`) — the same reason `HARMLESS_SUBSTITUTION_PROGRAMS`
  // leaves them out. `sed`/`awk` stay allowed because the corpus reads through them
  // (`| sed -n '3,12p'`, `| awk 'NR>1'`), so their SCRIPT is inspected for the constructs that
  // execute or write (`DATA_FILTER_SCRIPT_EXECUTES`) — refusing the filter name outright would
  // re-create the false block that measurement cost.
  //
  // The polarity is this function's throughout: an unrecognised stage is NOT a read, so it costs a
  // retry (`| head`, `| jq`) instead of certifying a program that ran with no reviewer verdict.
  let sedOrAwkStage = false;
  for (let i = 1; i < scan.tokens.length; i++) {
    // ⛔ NO DATA SKIP BEFORE THE STAGE TEST (#2206 review, P0). `isData(i)` here skipped a QUOTED
    // stage word, and a quoted stage is still executed: `gh pr view 1 | "sort" -o /tmp/f` was
    // certified a read. The pipe test below is what identifies a stage; whether the word was written
    // with quotes is irrelevant to what the shell runs.
    if (!hasUnquotedPipeInGap(scan, i)) continue;
    // ⛔ NO `isData(i - 1)` SKIP (#2206 review, P1). It was meant to stop a QUOTED argument that
    // precedes the pipe from looking like a stage, but it skipped the STAGE CHECK ITSELF: one data
    // token was enough to certify `… gh pr view $n --json "body" | sort -o <file>` as a read, and
    // `sort -o` really wrote — it overwrote a repo's `.git/hooks/pre-commit` from a command the
    // gate had just declared read-only (reproduced through the real handler). The `isData(i)` test
    // above already governs the STAGE token; what precedes the pipe is irrelevant to that test.
    const w = word(i);
    if (!READ_PIPELINE_FILTERS.has(w)) return false;
    if (w === "sed" || w === "awk") sedOrAwkStage = true;
  }

  // (4b) A data filter is only a data filter while its FLAGS cannot name a program or open an
  // output file. This runs over EVERY position (a pipeline STAGE and a plain COMMAND), because the
  // script check below reads the command TEXT and a flag can put the script out of its reach.
  //
  // ⛔ EACH ENTRY IS A MEASURED BYPASS (#2206 review, P1), certified as a read at zero dispatches
  // and then really running/writing:
  //   … | rg --pre=/tmp/pre.sh needle dir      rg RUNS the preprocessor on every file it searches
  //   … | awk -f /tmp/ship.awk                 the script is out of band; it ran `git push`
  //   … | sed -n -f /tmp/ship.sed              same
  //   … | sed -i 's/a/b/' f , awk -i inplace   WRITES the named file
  for (let i = 0; i < scan.tokens.length; i++) {
    if (isData(i)) continue;
    const w = word(i);
    const badLetters = PIPELINE_FILTER_FORBIDDEN_LETTERS.get(w) ?? "";
    const badLong = PIPELINE_FILTER_FORBIDDEN_LONG.get(w);
    if (badLetters === "" && badLong === undefined) continue;
    const last = endOfSegment(i);
    for (let k = i + 1; k <= last; k++) {
      // Quoted or not, the shell passes a flag through verbatim, so this loop does NOT skip data.
      const ft = word(k);
      if (badLong !== undefined && badLong.test(ft)) return false;
      // ⛔ THE LEADING LETTERS OF THE BUNDLE, NOT THE WHOLE TOKEN (#2206 review, P1).
      // `/^-[A-Za-z]+$/` never matched a flag with a SUFFIX, and `sed -i.bak` / `-ni.bak` is the
      // ordinary in-place spelling on BSD and GNU sed: it WROTE the named file under a read
      // certification. Reading the letters before the first non-letter also closes `-f<file>`-
      // style attached spellings, while `-F,` (awk's field separator) stays a read because `F` is
      // not in awk's set.
      const letters = ft.startsWith("-") ? ft.slice(1).split(/[^A-Za-z]/, 1)[0] : "";
      if (
        badLetters !== "" &&
        letters !== "" &&
        [...letters].some((ch) => badLetters.includes(ch))
      ) return false;
    }
  }
  // ⛔ THE SCRIPT IS DATA ON THIS SCAN, SO IT IS READ FROM THE TEXT. `sed '1e /tmp/x.sh'` is ONE
  // quoted token, and the tokenizer splits quoted regions on `(`/`{`/`;` too, so a stage-by-stage
  // walk cannot see the script's own words. The construct test therefore runs over the command
  // TEXT, and it is the fail-closed direction: the over-approximation can only REFUSE a command
  // that carries an execute/write construct somewhere, never certify one that does.
  if (sedOrAwkStage && DATA_FILTER_SCRIPT_EXECUTES.test(command)) return false;

  // (2) Every gh invocation is a READ, and there is at least one.
  let seen = false;
  for (let i = 0; i < scan.tokens.length; i++) {
    if (isData(i)) continue;
    const w = word(i);
    // A PATH to a gh (`/usr/bin/gh`, `$P/g''h`) is not a read this scan can certify: it
    // could be any wrapper at all, and the caller's fail-closed reading applies.
    if (w !== "gh" && /(^|\/)gh$/.test(w)) return false;
    if (w !== "gh") continue;
    seen = true;
    const groupTok = tok(i + 1);
    if (groupTok === "" || CONSTRUCT.test(groupTok)) return false;
    const group = word(i + 1);
    if (!SUBCOMMAND_WORD.test(group)) return false; // a global flag puts the group out of reach
    if (GH_READ_GROUPS_NO_SUB.has(group)) continue; // `gh status`
    if (group === "api") {
      const last = endOfSegment(i);
      for (let k = i + 2; k <= last; k++) {
        // ⛔ A COMMAND SUBSTITUTION IN THE ARGUMENT LIST MAKES THE CALL UNREADABLE (#2206 review,
        // P0). Evaluated BEFORE the `isData` skip: bash runs a substitution inside DOUBLE quotes
        // too, so `gh api "repos/$(printf …)"` is the same hole quoted. `$(printf -- '-%s%s' X
        // POST)` is ONE argv word `-XPOST`; a backtick body assembles its words the same way. The
        // rule is the DIMENSION, not the program: an api call is a read only when every word gh
        // will receive is spelled in the text. `sha=$(gh api …)` is unaffected — there the
        // substitution WRAPS the call instead of feeding it, and its arguments carry no `$(`.
        if (hasSubstitutionAt(scan, k)) return false;
        if (isData(k)) continue;
        const t = tok(k);
        const flag = word(k);
        if (flag === "graphql") return false; // a mutation is a write
        // AN ENDPOINT IS A VALUE: `repos/$owner/pulls/$pr` carries a construct and is still
        // readable as an endpoint. A WHOLE-WORD variable is not — `gh api repos/x $F` could be
        // `-f key=value` — so that fails the read.
        if (BARE_VARIABLE_WORD.test(dequote(t))) return false;
        const eq = flag.indexOf("=");
        const name = eq === -1 ? flag : flag.slice(0, eq);
        const attached = eq === -1 ? "" : flag.slice(eq + 1);
        // A construct in a FLAG position could spell the write (`gh api repos/x -$F y=1`).
        if (flag.startsWith("-") && CONSTRUCT.test(t)) return false;
        // `-f/--field`, `-F/--raw-field` and `--input` switch gh to POST by themselves.
        if (name === "--field" || name === "--raw-field" || name === "--input") return false;
        // ⛔ THE ATTACHED SHORT SPELLING IS THE SAME FLAG: gh's pflag parsing accepts `-fbody=x`
        // and `-Fbody=@f` exactly as `-f body=x` / `-F body=@f` (both are POSTs). Matching only the
        // detached `-f`/`-F` let `gh api repos/o/r/pulls/1/reviews -fevent=APPROVE -fbody=lgtm` —
        // i.e. SELF-APPROVAL of a PR — read as a GET (fresh review, P1). Prefix, not equality.
        if (flag.startsWith("-f") || flag.startsWith("-F")) return false;
        // `-X POST`, `-XPOST`, `--method PATCH`, `--method=DELETE`: anything but GET is a write.
        if (name === "--method" || flag.startsWith("-X")) {
          const method = (
            attached || (name === "--method" ? "" : flag.slice(2)) || word(k + 1)
          ).toUpperCase();
          if (!API_READ_METHODS.has(method)) return false;
          if (!attached && flag.length <= 2) k++;
          continue;
        }
      }
      continue;
    }
    // ⛔ OWN-PROPERTY LOOKUP. `group` is attacker-chosen text, and a plain index reaches the
    // PROTOTYPE: `gh constructor view` yielded `Object` (not `undefined`), so `.includes` threw out
    // of the gate — a refusal with no `gate_block` row and no recovery message, which is the
    // "refused and indistinguishable in the log" defect #2204 names (fresh review, P2).
    const allowed = Object.prototype.hasOwnProperty.call(GH_READ_SUBCOMMANDS, group)
      ? GH_READ_SUBCOMMANDS[group]
      : undefined;
    if (allowed === undefined) return false;
    const subTok = tok(i + 2);
    if (subTok === "" || CONSTRUCT.test(subTok)) return false;
    const sub = word(i + 2);
    if (!SUBCOMMAND_WORD.test(sub) || !allowed.includes(sub)) return false;
    i += 2; // the group/sub words are consumed; neither is a `gh` word
  }
  return seen;
}

/**
 * Does the TEXT name a merge? True for a resolvable `pr merge`, and for a verb hidden
 * behind a construct in a verb position (`gh pr m`printf erge``, `gh p`printf r` merge`).
 *
 * This is the CANDIDATE rule's shared read (`isAdminMergeCommand` calls it on its
 * spliced-verb branch). The text layer hands the argv layer the unresolvable FLAG — never
 * the MERGE: the caller's boundary is `hasLiteralAdminFlag || mergeVerbInText ||
 * !readsNonMergeGhCall`, so a command the text READS as a merge cannot defer, for two
 * reasons that meet here — that is the only shape in which a hidden `--admin` can reach gh
 * AS AN ADMIN MERGE, and it is exactly the shape where the argv layer can be told not to
 * run for that command — `PATH="${PATH#*:}"; export PATH; gh pr merge 999 $'--admin'`
 * discards the injected entry, so deferring to it would decide nothing and let the merge
 * through. A command the layer merely OVER-reads — a construct plus the word `admin` with
 * no merge in it — cannot merge anything, so deferring THAT is what removes the false block
 * #1776 is about. The two predicates are INDEPENDENT halves, not one property: a readable
 * merge can still sit inside a decoy command (`S='gh pr merge 9 $V'; sh -c "$S"`, measured
 * `readsNonMergeGhCall === true`) — which is why the boundary is the disjunction above, and
 * why neither half may be dropped as "redundant".
 */
export function mergeVerbInText(command: string): boolean {
  const scan = scanTokens(command);
  // #1485: a verb pair inside quoted DATA is a MENTION, not an invocation — a
  // python payload's docstring line, a `--jq` filter, a PR body. `sh -c`/`eval`
  // payloads and a fully-quoted command name stay readable (see `dataCharMask`),
  // which is what keeps `sh -c 'gh pr merge 999 --admin'` a merge.
  const data = dataCharMask(scan);
  const isData = (i: number) => isDataToken(scan, data, i);
  const at = (i: number) => shellWord(scan.tokens[i]);
  for (let i = 1; i < scan.tokens.length; i++) {
    if (isData(i) || isData(i - 1)) continue;
    if (at(i) === "merge" && at(i - 1) === "pr") return true;
  }
  // The construct class is `CONSTRUCT` above; the verb word may itself be spliced, and then
  // no `pr`/`merge` token pair exists to find, so the signal is a CONSTRUCT IN A VERB
  // POSITION — the token right after `gh` or right after `pr`. Requiring only "construct +
  // the words gh and pr" was too broad (it made `gh pr view $X` an admin merge), and
  // requiring `pr` to be a word missed ``gh p`printf r` …``, where `printf` hides it. NOTE
  // this arm is the CANDIDATE rule's shared form (`isAdminMergeCommand`); the deferral's
  // boundary is `readsNonMergeGhCall`, whose polarity does not depend on reading every
  // spell.
  const afterIsConstruct = (word: string): boolean => {
    for (let i = 0; i < scan.tokens.length - 1; i++) {
      if (isData(i) || isData(i + 1)) continue;
      if (at(i) !== word) continue;
      if (CONSTRUCT.test(scan.tokens[i + 1] ?? "")) return true;
    }
    return false;
  };
  // A construct in a verb position can ALSO be hidden inside a token the repo-flag
  // stripper consumes together with its value: `gh pr --repo=$(cat x) merge 999 $V`
  // leaves `gh pr x) merge …`, so both arms above miss it and the merge went to the
  // argv layer — which the command itself can then disable by resetting PATH. The RAW
  // text still shows a construct-bearing token right after `gh`/`pr`. Erring here costs a
  // refusal; erring the other way costs the gate.
  //
  // This arm compares the raw WORDS as written: quoting is resolved by the token scan
  // above (`verbWord`), which is the arm the ANSI-C-spelled pair needs, and the raw arm
  // exists for the construct AFTER a word rather than for the word itself. Normalizing
  // here as well was measured as redundant — the suite does not distinguish it — so it is
  // not kept as an unverifiable second mechanism.
  const raw = withoutMandatedRailPath(command).trim().split(/\s+/);
  // NOT data-aware, deliberately: this arm is the last-resort conserver for a
  // construct in a verb position that the repo-flag stripper could have shuffled
  // out of the token stream (`gh pr --repo=$(cat x) merge 999 $V` → `gh pr x)
  // merge`), and it reads a WHITESPACE split with no offsets to test against the
  // quote model. Making it guess would weaken the arm in the direction that costs
  // the gate; leaving it conservative only keeps a MENTION of the form `gh pr $X
  // merge` inside a payload gated, which is a declared residual of #1485 (the
  // token arms above are what remove the false positives that were measured).
  const rawAfterIsConstruct = (word: string): boolean => {
    for (let i = 0; i < raw.length - 1; i++) {
      if (dequote(raw[i]) !== word) continue;
      if (CONSTRUCT.test(raw[i + 1] ?? "")) return true;
    }
    return false;
  };
  return (
    afterIsConstruct("gh") ||
    afterIsConstruct("pr") ||
    rawAfterIsConstruct("gh") ||
    rawAfterIsConstruct("pr")
  );
}

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
      // (cycle-5 review P0, third seam). `mergeVerbInText` is the shared form of that
      // signal — the same one the deferral uses to decide what it may hand over.
      if (!hasUnresolvableConstruct(command)) return false;
      return mergeVerbInText(command);
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
        // `continue` — a GENUINE `$PR` position argument, in either quoting form (pinned by
        // the carve-out test). Do NOT "fix" this by failing closed on every `$`-bearing
        // first slot: the caller's condition keeps its own decision for any `pr`/`merge`
        // PAIR (`mergeVerbInText`), so that would refuse every ordinary
        // `gh pr merge "$PR" --squash` — the #1776 false-positive class, at a far larger
        // volume. The residual it leaves is DECLARED and is a CLASS claim, not a spelling
        // claim: no test over this slot can separate a `$`-bearing PR VALUE from a
        // `$`-bearing FLAG, and one quote character moves a command between the two
        // readings (measured: the narrow arm `if (/^\$/.test(arg)) return true` closes the
        // unquoted spelling AND blocks the pinned unquoted ordinary form, while
        // `gh pr merge "$V"` stays allowed — so it buys nothing the class needs). What is
        // left is a flag whose VALUE is not in the command text (`V=$(cat f); gh pr merge
        // $V`) with no explicit PR number: a text scanner has no `admin` word to read, so
        // this layer is not a candidate and the decider is the argv layer — whose discard
        // (`export PATH=…`) is the shim's own STATED LIMITS entry. The same residual WITH a
        // PR number does not exist (`laterBareNumber` makes it a candidate: measured).
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
    //
    // It is a GUESS, so the CALLER does not act on it while the argv layer is
    // present: it resolves what this cannot, and its false positives are the reason
    // agent-infra#1776 exists — an ordinary `gh` call whose TEXT contains a construct
    // and the word `admin` (a PR TITLE supplies it) was read as a merge. Do NOT add
    // another arm here: #984's finding is that the class is not closable in a scanner —
    // every framing of "is this text an admin merge" that tried to be precise admitted a
    // bypass on the splice × repo-flag cross-product. The caller's condition is
    // `hasLiteralAdminFlag(command) || mergeVerbInText(command) ||
    // !ghShimWillEnforce(shimDir)`, and this guessing half is exactly what gets handed
    // over — only for a command that does NOT name a merge (`mergeVerbInText`). NOTE the
    // false block the LITERAL arm still produces (a quoted `--admin`, once this guess has
    // already made the command a candidate); it is deliberate, and
    // `hasLiteralAdminFlag` documents why the caller accepts it.
    //
    // ⛔ #3953: THE GUESS IS ABOUT AN OPERATION, NOT ABOUT VOCABULARY. It used to be
    // "the text contains the word `gh`, or the words `pr` AND `merge`", which made every
    // read-only command that merely NAMED a merge a merge it had to certify — the mandated
    // `commits/<sha>/check-runs` read, a `branches/main/protection` projection, a heredoc
    // body full of `hasAdminMergeFlag` identifiers. `mergeInvocationInText` asks instead
    // for a merge VERB in argv position, and it keeps the fail-closed halves that matter: a
    // spliced verb still counts, a verb inside a payload handed to a shell still counts, and
    // a `gh` whose group slot is unreadable (`V="pr merge"; gh $V 999 --admin`) still
    // counts. What it no longer counts is a READABLE `gh api`/`gh issue`/`gh pr view` call,
    // which cannot merge anything — that is the difference between the operation and the
    // word, and it is the whole of the #3953 class.
    return mergeInvocationInText(bare);
  }
  // Readable text, so the only way it is still a merge is a quote-split verb
  // behind a BARE `gh` (quotes are deliberately not a construct). Requiring the
  // `gh` to be bare is what keeps a quoted MENTION — `echo "gh pr merge 1
  // --admin=true"`, `rg 'gh pr merge' scripts/` — outside the gate; gating those
  // was a real over-block that fired on heredocs and greps (VGATE round 8).
  const bareGh = hasBareGhWord(command);
  return bareGh && /(^|[\s;&|(){!])gh\s+pr\s+merge/.test(probe);
}

/**
 * A QUOTED heredoc delimiter: `<<'EOF'`, `<<"EOF"`, `<<\EOF`. Quoted means NO expansion, so the body
 * is literal stdin DATA and can never become command lines of THIS command — the same proof
 * `heredocBodyIsData` makes, minus its refusal to look at a COMPOUND opener line.
 */
const QUOTED_HEREDOC = /<<-?(?:'([^']*)'|"([^"]*)"|\\([A-Za-z_][\w-]*))/;

/**
 * The consumers that treat a heredoc body as DATA. Deliberately tiny: every entry is measured, and a
 * word this list does not know keeps its body readable (fail-closed). `sed`/`awk` are NOT here — their
 * `-f -` / `-e` spellings read the body as a PROGRAM, and one entry cannot be both. `dd` is NOT here
 * either, and for the same reason: `dd of=/tmp/y.sh` WRITES the body to a file, and `dd`'s target is
 * not in `heredocWrittenTargets`' reader (`>`, `tee`, `sort -o`) — so a consumer the written-target
 * clause cannot follow is not one this masker may treat as a sink (#3161 P0, measured).
 */
const DATA_ONLY_CONSUMERS = new Set(["cat", "tee", "wc"]);

/**
 * RELAXATION 2 of `withoutQuotedHeredocBodies`, stated once and in one place: a command that can only
 * READ a file it is handed, so a line that names a heredoc's written target through it cannot be
 * EXECUTING that target.
 *
 * It is LOCAL, not part of `HEREDOC_FILE_NAMING_ONLY`, on purpose: that set is `maskHeredocData`'s
 * vocabulary, and widening it would move the mask every gate consumes (`gh` there would mask a body
 * merely because a LATER line reads the file — a behaviour change to the proven function, which this
 * change is not entitled to make). `gh` cannot source or exec a local path: `--body-file` reads it,
 * and `gh extension exec` resolves a NAME under gh's own extensions directory, never an arbitrary
 * written path. A line that PIPES the reader into a program, chains a second command, or hands the
 * path to an interpreter is still an execution (the pipe arm and the segment split both fire).
 */
const TRACKER_FILE_READERS: ReadonlySet<string> = new Set(["gh"]);

/**
 * Blank the BODY of every `<<'QUOTED'` heredoc, LENGTH-PRESERVING, for a CLASSIFICATION read only.
 *
 * ⛔ WHY THIS IS NOT `maskHeredocData` (#485 class, measured 2026-10-31 on pi-cell-1). The measured
 * parked command was
 *     cd <wt> && cat > /tmp/f.md <<'MDEOF'  …prose with `backticks`…  MDEOF
 *     gh pr comment <n> --repo <o/r> --body-file /tmp/f.md 2>&1 | tail -2; rm -f /tmp/f.md
 * `maskHeredocData` keeps that body readable for TWO independent reasons: (a) its opener line is
 * COMPOUND (`cd … && cat …`) and `heredocBodyIsData` refuses any `;&|()` there; (b) it over-refuses
 * ANY line that merely MENTIONS a written target, and `gh` is not in `HEREDOC_FILE_NAMING_ONLY`.
 * The prose then reached `isGhPrMergeCommand`'s broad arm as if it were operations, and a TRACKER
 * WRITE parked a lane for 45 minutes (`gate-events.jsonl`, 2026-10-30T19:41:53Z).
 *
 * ⛔ SO THE RELAXATIONS ARE EXACTLY TWO — that is the WHOLE delta between this function and the
 * proven one, and a fresh-context review measured the first version's delta at FIVE because it had
 * dropped the rest:
 *   R1. the PREFIX of the opener line may be COMPOUND (a). Nothing follows from a prefix about
 *       whether the BODY is data — provided the prefix cannot hand the body to anything, which is
 *       clause C4 below;
 *   R2. a written target may be MENTIONED by a tracker-write READER (b): `TRACKER_FILE_READERS`.
 * EVERY OTHER CLAUSE IS RESTORED, USING THE SAME PRIMITIVES `maskHeredocData` USES, so the two
 * cannot drift into different answers about the same question:
 *   C1. FRAME — `heredocOpenerIsInsideFrame`: inside `if`/`for`/`case`/`(`/`{`, the body's stdout
 *       may still reach a program (`fi | bash`), so nothing is masked;
 *   C2. WRITTEN TARGET + LATER LINE — `heredocWrittenTargets` + `heredocLineExecutes`: a body written
 *       to a file a later line can RUN keeps its text (`cat > /tmp/y.sh <<'EOF' … EOF` + `bash /tmp/y.sh`);
 *   C3. SHADOWED READER — `heredocReaderIsShadowed`: `cat() { bash; }` / `alias cat=bash` make the
 *       consumer clause a claim about a WORD, not a program;
 *   C4. PREFIX — `heredocPrefixIsUnprovable` (plus this line's own prefix, which R1 above would
 *       otherwise stop being checked) and `endsWithContinuation` on the prefix AND the opener line: a
 *       `$(`/backtick/`PATH=`/written-path prefix, or a `\`-joined line, makes every line-local rule
 *       here a reading of a FRAGMENT;
 *   C5. CONSUMER + REMAINDER — a data-only consumer word, and a remainder that is not a pipe, a
 *       substitution, a process substitution or a SECOND COMMAND (`&& bash /tmp/y.sh`).
 *
 * ⛔ WHY THE CLAUSES ARE NOT CEREMONY — the measured cost of dropping them (this file's own head,
 * measured by execution, each one `isGitOp()` false where it must be true): a body the same command
 * executes (`… <<'EOF' && bash /tmp/y.sh`), a shadowed reader, a `$(` on the opener line, a `\`
 * continuation on the PREFIX line, a frame, and a written-then-run file. The first version of this
 * function's docstring ARGUED them away ("with a QUOTED delimiter bash performs no expansion, and
 * the body is stdin to `cat`, which cannot run it"). That argument is true about the BODY and false
 * about the COMMAND — so `git -C /wt push` inside such a body was invisible, `isGitOp` returned
 * false, and the whole gate handler (the ≥1-dispatch floor, the admin-merge evidence gate, the merge
 * registry) was skipped. **Restore the clause, or delete the function — do not restate an argument
 * for a clause that is missing.**
 *
 * ⛔ STATED RESIDUAL — the SAME one `maskHeredocData` declares, and it is not narrowed here: this
 * follows the file the heredoc WRITES as far as a runner in the SAME command. It does not follow that
 * file into a LATER tool call (the argv layer, #984, is the answer there), and it does not follow it
 * through a `cp`/`mv` of the written path. Both were the proven masker's declared gap before this
 * function existed; a row in the suite marks the `cp` shape so no lane reads it as covered.
 *
 * ⛔ AND A THIRD ONE, MEASURED BY REVIEW (agent-infra#3161 round 4, P2) — `heredocNamesTarget` matches
 * a LITERAL path (and `~` / `$HOME`), never one ASSEMBLED FROM A VARIABLE, so a runner naming the
 * target only through an assignment escapes C2 and the body is blanked:
 *     cat > /tmp/y.sh <<'EOF'\ngit -C /wt push\nEOF\nd=/tmp; bash $d/y.sh
 * executes the push and reads `isGitOp` false. This is NOT a regression — the proven masker blanks it
 * too, so the pre-#3161 gate is equally blind — but C2's own wording ("a body written to a FILE a
 * later line can RUN keeps its text") reads as if it covered it, and an earlier revision of this
 * paragraph listed only the later-call and `cp`/`mv` gaps. Path-assembly is untracked on purpose: a
 * `$d` can be anything, and guessing a value is the fail-OPEN direction. The argv layer (#984) is
 * the answer, as it is for the other two.
 *
 * POLARITY, unchanged and stricter than `maskHeredocData` in two places: only a QUOTED delimiter is
 * masked (an UNQUOTED `<<EOF` EXPANDS, so its text stays readable here even though the proven masker
 * masks it); a delimiter this reader cannot resolve is not an opener; a `<<` inside an open quote or
 * a `#` comment is text; an unterminated body stays readable. Every one of those is fail-CLOSED.
 */
export function withoutQuotedHeredocBodies(command: string): string {
  const lines = command.split("\n");
  const out: string[] = [];
  let i = 0;
  while (i < lines.length) {
    let line = lines[i];
    const at = line.search(QUOTED_HEREDOC);
    if (at < 0) {
      out.push(line);
      i++;
      continue;
    }
    // Quote-blindness would let `echo "note <<'EOF'"` mask a real command after it: refuse to treat
    // an opener that sits inside an OPEN quote as an opener.
    let quote: string | null = null;
    let inComment = false;
    for (let c = 0; c < at; c++) {
      const ch = line[c];
      if (quote) {
        if (ch === "\\" && quote === '"') c++;
        else if (ch === quote) quote = null;
      } else if (ch === "'" || ch === '"') quote = ch;
      // A `#` COMMENT IS TEXT, NOT AN OPENER (fresh-context review, P1). Measured input:
      //     gh pr comment 1 --body-file /tmp/f.md  # cat <<'EOF'
      //     gh --repo o/r pr merge 9
      //     EOF
      // was read as an opener and BLANKED the executed merge two lines down — a fail-open. The rule
      // is `heredocFrameTokens`'s: a `#` at start-of-line or after whitespace, outside quotes.
      // Bash starts a comment at the beginning of a WORD, so a word-adjacent separator counts too:
      // `;#`, `&&#`, `|#`, `(#` all begin a comment, and an opener hidden behind one is TEXT, not an
      // opener. Narrow on purpose — the wider this predicate, the LESS masking, and less masking is
      // the fail-CLOSED direction (round-2 review measured `;#` under-masking an executed merge).
      else if (ch === "#" && (c === 0 || /[\s;&|()]/.test(line[c - 1]))) inComment = true;
    }
    if (quote !== null || inComment) {
      out.push(line);
      i++;
      continue;
    }
    const m = QUOTED_HEREDOC.exec(line.slice(at))!;
    const delim = m[1] ?? m[2] ?? m[3] ?? "";
    const remainder = line.slice(at + m[0].length);
    const prefixOnLine = line.slice(0, at);
    const consumer = (prefixOnLine.match(/(?:^|[;&|(]\s*)([A-Za-z_][\w.-]*)\s*[^;&|]*$/) ?? [])[1] ?? "";
    const refuse = () => {
      out.push(line);
      i++;
    };
    // ── CLAUSE C5 (consumer + remainder) ──────────────────────────────────────────────────────────
    // A body whose CONSUMER can run it is not data. Four halves, every one measured by review:
    //  (a) the REMAINDER of the opener line — `cat <<'EOF' | bash`, `$(cat …)`, a backtick;
    //  (b) the CONSUMER WORD itself — `sh <<'EOF'` / `bash -s` / `python` take the body as a SCRIPT,
    //      so a merge written inside one is EXECUTED even though the delimiter is quoted (round-2
    //      review, P0). Only a data-only consumer is masked, which is this function's polarity;
    //  (c) a SECOND COMMAND in the remainder — `cat > /tmp/y.sh <<'EOF' … EOF && bash /tmp/y.sh`
    //      (measured, P1) writes the body to a file and RUNS it on the same line, exactly as the
    //      later-line form does. `[;&]` is the whole class, so no spelling of a following command
    //      slips through;
    //  (d) a trailing `\` on the opener line (round 3): bash joins the next line, so the guard is
    //      line-local — and a PROCESS SUBSTITUTION in the remainder or the PREFIX
    //      (`cat <<'EOF' > >(sh)`, `tee >(sh) <<'EOF'`, `1> >(bash -s)`) hands the body to a shell.
    if (
      /\||\$\(|`/.test(remainder) ||
      /[;&]/.test(remainder) ||
      /\\\s*$/.test(line) ||
      /[<>]\(/.test(line) ||
      !DATA_ONLY_CONSUMERS.has(consumer)
    ) {
      refuse();
      continue;
    }
    if (delim === "") {
      refuse();
      continue;
    }
    // ── CLAUSE C1 (frame) ─────────────────────────────────────────────────────────────────────────
    // A compound KEYWORD or bracket frame can hand the body's stdout to a program (`fi | bash`), so
    // inside one nothing is masked — the proven masker's own measured fail-open (#1382).
    if (heredocOpenerIsInsideFrame(lines, i)) {
      refuse();
      continue;
    }
    // ── CLAUSE C4a (continuation) ─────────────────────────────────────────────────────────────────
    // The proof below is LINE-LOCAL and bash is not: a `\` at the end of this line, or of ANY line
    // that feeds it, joins two physical lines into one command. Measured fail-open: a prefix
    // continuation hid a `| sh` and a `> /tmp/y.sh`, and the body was masked while bash ran it.
    if (endsWithContinuation(line) || lines.slice(0, i).some(endsWithContinuation)) {
      refuse();
      continue;
    }
    // ── CLAUSE C3 (shadowed reader) ───────────────────────────────────────────────────────────────
    // Scope is the prefix THROUGH this line, for `maskHeredocData`'s reason: a definition must precede
    // its use, and reading the whole command let a body that merely QUOTED `cat() { bash; }` disarm
    // the mask. Measured fail-open: `cat() { bash; }` / `alias cat=bash` on an earlier line, then
    // `cat <<'EOF' … git push … EOF` → masked and ungated.
    if (heredocReaderIsShadowed(lines.slice(0, i + 1).join("\n"), consumer)) {
      refuse();
      continue;
    }
    // ── CLAUSE C2 (written target a later line can run) + CLAUSE C4b (prefix) ──────────────────────
    // A body written to a FILE that this same command can EXECUTE by a later line is unprovable, so
    // it keeps its text (measured P1: `cat > /tmp/y.sh <<'EOF' … EOF` + `bash /tmp/y.sh`). The ONE
    // declared relaxation is `TRACKER_FILE_READERS`: a mention through a reader that cannot run the
    // file is a READ, which is the parked shape this function exists for.
    const scope = lines.join("\n");
    // The WRITER is the LAST simple command before the opener, not the line's first word: a permitted
    // compound prefix (`cd /wt && tee /tmp/y.sh <<'EOF'`) would otherwise hide `tee`'s target from this
    // check, and a later `bash /tmp/y.sh` would run a body that was masked (measured, P0).
    const targets = heredocWrittenTargets(line, consumer);
    // A redirect target the shell will EXPAND is not a name we can compare (`$HOME`, a backtick).
    if (targets.some((t) => /[$`]/.test(t))) {
      refuse();
      continue;
    }
    // Later lines read with continuations RESOLVED, so a runner spelled `bash \` / `/tmp/y.sh` is as
    // visible as `bash /tmp/y.sh`, and a pipe continued onto the next line keeps its pipeline.
    const otherLines = lines
      .filter((_, n) => n !== i)
      .join("\n")
      .replace(/\\\r?\n/g, " ")
      .replace(/\|[ \t]*\r?\n/g, "| ")
      .split("\n");
    if (
      targets.some(
        (t) =>
          t !== "" &&
          t !== "-" &&
          otherLines.some((l) => heredocLineExecutes(l, t, scope, TRACKER_FILE_READERS)),
      )
    ) {
      refuse();
      continue;
    }
    // The prefix must not be able to change what the consumer resolves to, capture the body, or hold
    // the written path in a variable. THIS LINE'S OWN PREFIX is included because R1 above stops
    // `heredocBodyIsData` from looking at it — without that, `x=$(cat <<'EOF' …)` and
    // `PATH=/tmp/e:$PATH cat <<'EOF' …` were masked (measured fail-open). Split in two, because a
    // target THIS line writes is expected to appear in its own prefix: the earlier lines are checked
    // WITH the targets (`source "$f"` on an earlier line), the opener line's prefix WITHOUT them
    // (an assignment or a substitution there is the danger, not the redirect that writes the body).
    if (
      heredocPrefixIsUnprovable(lines.slice(0, i).join("\n"), targets) ||
      heredocPrefixIsUnprovable(prefixOnLine, [])
    ) {
      refuse();
      continue;
    }
    // The OPENER is a redirection whose target is a literal delimiter: it blinds nothing, so it is
    // rewritten to the plain redirection shape the tokenizer already exempts (`</dev/null`).
    line = line.slice(0, at) + "</dev/null" + line.slice(at + m[0].length);
    out.push(line);
    i++;
    const stripTabs = /^<<-/.test(m[0]);
    let closed = false;
    for (let j = i; j < lines.length; j++) {
      const probe = stripTabs ? lines[j].replace(/^\t+/, "") : lines[j];
      if (probe === delim) {
        // The BODY is blanked; the terminator line itself is kept verbatim (it is not a command).
        for (let k = i; k < j; k++) out.push(" ".repeat(lines[k].length));
        closed = true;
        i = j;
        break;
      }
    }
    // Unterminated: the body stays readable (nothing masked) — the safe direction.
    if (!closed) continue;
  }
  return out.join("\n");
}

/**
 * Does the text name the WORD `git` anywhere, outside a quoted-heredoc body? Used ONLY to veto the
 * tracker-write stand-down below (never to widen a gate).
 *
 * A WORD TEST, NOT A VERB SPELLING. A fresh-context review measured six spellings that a
 * `git\s+(commit|push)` anchor missed once this classifier existed, every one of them a REAL push or
 * commit reaching zero dispatches: `git -C <path> push`, `git --no-pager push`, `git -c k=v push`,
 * `git -C /wt commit -am x`, `$('git' push)`, `sh -c 'git -C /wt push'`. `-C` is this fleet's own
 * canonical form, so the class is reachable. Enumerating spellings is the thing this file keeps
 * re-learning not to do; the property that converges is the WORD, and the cost of the blunter test is
 * a refusal (`--body "run git log"`) — the direction this file is allowed to be wrong in.
 *
 * The quoted-heredoc BODY is excluded because it is DATA to this command (see
 * `withoutQuotedHeredocBodies`); a comment body that merely mentions git is the shape this classifier
 * exists to allow.
 */
// The leading class is SEPARATORS, not quotes. Including `'`/`"` here gated `echo "git commit -m x"`,
// which a pinned test requires stay outside (#1492: a quoted MENTION is not an operation), and a
// command-position analysis is what distinguishes the two correctly.
//
// ⛔ A WRITE **VERB**, NOT THE WORD `git` (agent-infra#3161 — a P0 the first form shipped). The first
// form of this arm was `/(^|[\s;&|(){!])git\s/`: ANY command containing `git ` became a "git op",
// INCLUDING every read-only inspection an agent runs before it has dispatched a reviewer. Measured
// on this branch against `origin/main` (`isGitOp` on 14 spellings, both trees): `origin/main`
// ALLOWED `git status`, `git log --oneline -3`, `git diff --stat`, `git fetch origin main`,
// `git rev-parse HEAD`, `git branch --show-current`, `git show HEAD:README.md` and
// `git status --porcelain`; the word arm BLOCKED all eight at zero dispatches. So a bare `git status`
// was refused until the lane dispatched a reviewer FOR THE `git status` — the fleet's most common
// command. The docstring below priced the blunt test as "a refusal (`--body "run git log"`)", i.e. a
// quoted mention; a refusal of the READ ITSELF was never priced, so this was not a disclosed residual,
// and no suite row covered a bare git read (which is why 358 green assertions missed it). The lane
// that shipped it could not see it: its own session ran with dispatch enforcement BYPASSED.
//
// The arm still CROSSES the global options that made a word test tempting — `git -C <path> push` (this
// fleet's canonical spelling), `git --no-pager push`, `git -c k=v commit`, `git -C /a -C /b commit` —
// because `-C`/`-c` take a VALUE, so a naive `git\s+(commit|push)` anchor saw `-C`. The option group
// is backtracking-safe: for `git --no-pager push` the optional value is declined and the verb matches.
//
// ⛔ THE VERB SET IS `GIT_COMMIT_PATTERN`'S, AND NOT ONE VERB WIDER. The arm exists for ONE measured
// fail-open — the fleet's canonical `git -C <path> push` could not cross a global option, so it
// matched no arm and reached ZERO dispatches — and the floor's own scope is stated two paragraphs
// up: "WRITES THAT LAND CODE". A working-tree or index verb lands nothing, so adding it here is the
// SAME over-block this file's previous commit had to fix for a bare `git status` (a word test
// refused the fleet's most common command). MEASURED, `isGitOp` on both trees, at zero dispatches:
// an earlier form of this pattern listed 20 verbs and turned `git add CHANGELOG.md`, `git add -A`,
// `git -C /wt add -A`, `git checkout -b feat/x`, `git switch -c feat/x`, `git clone <url> <dir>`,
// `git init -q`, `git pull --ff-only` and `git update-index --refresh` into REFUSALS that
// `origin/main` allows. `git add CHANGELOG.md` is the sharpest: it is the exact sequence
// `heredocLineExecutes`'s own note (above) says must stay allowed, so that form re-created the
// reported false positive one clause away from the paragraph forbidding it.
// A refusal is the fail-CLOSED direction, which is why an over-block can pass a review — but 20
// verbs is not a strictness choice, it is the floor claiming jurisdiction over the working tree. The
// remaining local verbs gain nothing: a `commit` or `push` that would SHIP their effect is already
// gated here, and `resolveShippedHeads` refuses a ref-moving prefix (`git reset --hard side && git
// push`) as evidence on its own.
// DECLARED RESIDUALS, unchanged from HEAD in kind and now stated rather than implied: an alias push
// (`git -c alias.p=push p origin …`), and `$('git' push)` / `sh -c 'git -C /wt push'` keep no arm
// HERE (nor did `GIT_COMMIT_PATTERN` at HEAD) — the quote sits where a command word's boundary would
// be, so the pattern cannot see through it. `writesOnlyTrackerRecords`' `mentionsGitWord` veto does
// NOT cover them either: that function is reachable only once a `gh`+`pr` candidate exists, so these
// spellings reach zero dispatches ALONE on both trees. The argv layer (#984) is the answer for the
// rest. (`git update-index` was listed here while the pattern armed it — the two disagreed; it is
// now genuinely unarmed, because it ships nothing.)
const GIT_WRITE_VERB_PATTERN =
  /(^|[\s;&|(){!])git\s+(?:-{1,2}[^\s;&|]+(?:\s+[^\s;&|]+)?\s+)*(?:commit|push)(?=\s|$)/;

function gitWordAnywhere(command: string): boolean {
  return GIT_WRITE_VERB_PATTERN.test(withoutQuotedHeredocBodies(command));
}

/**
 * A TRACKER WRITE, read positively (defect measured 2026-10-30/31, pi-cell-1).
 *
 * `gh pr comment` / `gh pr edit` / `gh issue comment` publish a RECORD; they cannot mint the rail's
 * attestation (record-review.sh — "a body edit cannot mint one"), cannot move code, and cannot merge.
 * The ≥1-dispatch floor covers WRITES THAT LAND CODE, so a tracker write is a READ-SIDE
 * classification at this floor, not a gated operation. What is NOT relaxed: any `git` verb anywhere
 * (including inside a substitution), an admin-merge flag, and any gh invocation this layer cannot
 * positively read as a non-merge — `gh issue comment 1 && gh pr merge 2`, a spliced verb, and an
 * unquoted heredoc body all keep the floor.
 */
export function writesOnlyTrackerRecords(command: string): boolean {
  // ⛔ ONE DEFINITION OF "THIS TEXT MENTIONS git" (agent-infra#3161 review). The first form carried a
  // private regex beside the module's own `mentionsGitWord`, and the private one was WEAKER: it
  // matched the literal characters `git`, so the quote/backslash SPLICES that `mentionsGitWord` was
  // written to normalize (`''git push`, `\git push`, `g"i"t push`, `$'git' push`) read as "no git
  // word" here — a fail-open inside the very veto that keeps a splice from standing the floor down.
  // `mentionsGitWord` is the pre-existing decision for this question (see its "third design" note),
  // so the duplicate goes and the veto inherits the splice-proofing.
  if (mentionsGitWord(withoutQuotedHeredocBodies(command))) return false;
  if (hasAdminMergeFlag(command)) return false;
  return readsNonMergeGhCall(withoutQuotedHeredocBodies(command));
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
  // ⛔ A `git` WRITE VERB IS A SHIPPING OP IN EVERY SPELLING (round-2 review, P0). The literal arm
  // above cannot cross a global option, so `git -C <path> push` — this fleet's own canonical form —
  // and `git --no-pager push` / `git -c k=v commit` matched NO arm and reached zero dispatches. The
  // fix is an ARM, not a veto: `gitWordAnywhere` below is a veto inside the tracker-write classifier,
  // which only speaks once some other arm has already made the command a candidate — a raw
  // `git -C /wt push` supplies no such candidate. Quoted-heredoc bodies are excluded because they are
  // DATA to this command; anything else with a git WRITE VERB is gated (a refusal). A git READ VERB
  // (`status`, `log`, `diff`, `show`, `rev-parse`, `branch`, `fetch`, …) is deliberately NOT here:
  // see `GIT_WRITE_VERB_PATTERN`'s note — it is a read, and refusing it never shipped anything.
  if (gitWordAnywhere(command)) return true;
  // ⛔ THE BROAD `gh`+`pr` ARM ASKS ITS OWN DOCUMENTED QUESTION (#485 class, measured
  // 2026-10-30/31 on pi-cell-1). `isGhPrMergeCommand`'s `hasGh && hasPr` arm exists to catch a
  // merge whose VERB this layer cannot read (`` gh pr m`printf erge` 999 ``). When the text
  // POSITIVELY reads every gh invocation as a NON-merge gh call, there is nothing left for the arm
  // to catch — and the cost of not asking was measured in `gate-events.jsonl`: 3 comment writes
  // (`gh pr comment <n> --body-file /tmp/x.md`, preceded by a `cat > … <<'EOF'` heredoc and a
  // `2>&1 | tail -2`) reached the ≥1-dispatch floor and parked a lane for 45 minutes on a
  // TRACKER WRITE. The predicate is `readsNonMergeGhCall`'s, not a second opinion: it fails CLOSED
  // on any construct outside a value position, so a spliced `--admin` merge and
  // `gh issue comment 1 && gh pr merge 2` both keep the gate (see index.test.ts).
  if (isGhPrMergeCommand(command) && hasBareGhWord(command) && !writesOnlyTrackerRecords(command)) return true;
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
  /** #1351 — the sha256 of the NORMALIZED three-dot diff this review certified,
   * as written by record-review.sh (#2982/#1362). It is the record's CONTENT
   * identity, the local counterpart of the `diff=<sha256>` the GitHub
   * ai-review-gate verifies in the signed marker: a merge-only
   * `gh pr update-branch` moves the head without changing this value, so the
   * two gates agree on what "reviewed" means.
   *
   * OPTIONAL. Records predating #2982 and records minted while the diff read was
   * degraded carry none, and their ABSENCE must fall back to the HEAD binding —
   * never to an accept (see evaluateMergeGate's carry arm). */
  diff_sha256?: string;
  /** Mint provenance written by record-review.sh (tortoise#7391). A `carried`
   * record is one re-bound to a NEW head after a verified carry; the #2349
   * DIAGNOSTIC surfaces it so a reader can tell "fresh review at this head" from
   * "carried from <sha>". OPTIONAL and NEVER read by a decision. */
  mint?: string;
  carried_from?: string;
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

/**
 * #2287/#2148 (measured 2026-10-22, this lane): the ≥1-dispatch floor counted ONLY
 * the in-session `task`/`subagent` tool_result, so a lane that obtained its review
 * from a SPAWNED reviewer PROCESS — `scripts/review-pr.sh`, the harness's
 * `merge-one.sh` reviewer, any `pi -p` child — was refused at its next git op with
 * "no reviewers dispatched" even though a reviewer HAD run and its verdict was on
 * the record. The floor was therefore satisfiable only one way, and the way the
 * documentation tells a lane to land (`review-pr.sh`, then the rail) was not it.
 *
 * The acceptance is a MECHANICAL artifact, not prose: `record-review.sh`'s registry
 * record (`~/.pi/agent/reviews/…json`) is the one thing a reviewer process leaves
 * behind, and the merge gate ALREADY trusts it as the attestation. This adds NO new
 * trust boundary — it reads the same file the rail reads — and it is bound to the
 * EXACT head being pushed/committed, so a record made at an older head still needs
 * a fresh review (no record for these bytes ⇒ still refused).
 *
 * ⛔ The negative case is the protection: no spawn ⇒ no record ⇒ refuse (pinned by
 * `index.spawn-evidence.test.ts`; the recorder refuses to mint one without the
 * evidence artifact, and `tests/review-pr/run.sh` §AE proves the no-spawn mutant
 * writes nothing). A record whose `repo` disagrees with the op's repo is treated as
 * absent (the #426 collision class), and ambiguity (two records for one head with
 * no repo context) is not evidence either.
 */
export interface ReviewProcessEvidence {
  pr: number;
  head_sha: string;
  verdict: string;
  repo?: string;
  recordPath: string;
}

/**
 * A review record bound EXACTLY to `headSha`. `repo` narrows the search when known
 * (a foreign repo's record must never satisfy this repo — #426). Returns null when
 * nothing matches, or when the match is ambiguous without repo context.
 */
export function headBoundReviewEvidence(headSha: string, repo: string | null): ReviewProcessEvidence | null {
  if (typeof headSha !== "string" || !/^[0-9a-f]{7,64}$/i.test(headSha.trim())) return null;
  const want = headSha.trim().toLowerCase();
  let entries: string[];
  try {
    entries = fs.readdirSync(reviewsDir()).filter((f) => f.endsWith(".json"));
  } catch {
    return null; // no registry → no evidence
  }
  const matches: ReviewProcessEvidence[] = [];
  for (const f of entries) {
    const path = resolvePath(reviewsDir(), f);
    const rec = readRecordFile(path);
    if (rec === null) continue;
    if (typeof rec.head_sha !== "string" || rec.head_sha.trim().toLowerCase() !== want) continue;
    if (repo !== null && rec.repo !== undefined && rec.repo !== repo) continue; // foreign record → inert
    if (repo !== null && rec.repo === undefined) continue; // no repo on the record ⇒ cannot be bound to THIS repo
    // #426 P0-2 parity: with NO repo context, a record that NAMES a repo cannot be bound to
    // this op (it may be another repo's PR with the same number); only a repo-less legacy record
    // is admissible, and only as the unique match (checked below).
    if (repo === null && rec.repo !== undefined) continue;
    matches.push({ pr: rec.pr, head_sha: want, verdict: rec.verdict, repo: rec.repo, recordPath: path });
  }
  if (matches.length === 0) return null;
  if (matches.length > 1) {
    // Two records at one head, no way to choose: not evidence. (With repo context
    // the loop above already filtered to this repo's records; a genuine duplicate
    // for one repo+head is still ambiguous.)
    logGateEvent("review_record_collision", { ambiguous: matches.map((m) => m.recordPath), head_sha: want });
    return null;
  }
  return matches[0];
}

/**
 * THE COMMITS AN OP ACTUALLY SHIPS - and nothing but the ones it ships.
 *
 * #2287 fresh-review P0 (2026-10-22, reproduced): the first revision of this helper asked only
 * "what is HEAD?", and HEAD is NOT the shipped object in several ordinary shapes. Each of these
 * authorized a git op from a record that describes other bytes:
 *
 *   git push origin side        HEAD is on the reviewed commit; the pushed BRANCH is not.
 *   git -C <other> push ...     the checkout, HEAD and repo are read from the session cwd.
 *   git commit -m wip           the committed bytes DO NOT EXIST YET - no record can describe them.
 *   git push --all / --mirror   many refs ship, one HEAD describes one of them.
 *
 * So the evidence path is opened ONLY for the shapes whose shipped commit is exactly HEAD, and is
 * closed (null => the >=1-dispatch floor applies unchanged) everywhere else. That is the
 * fail-closed direction: an unrecognised option, a refspec, a redirect, an unresolvable branch
 * name, or a commit all fall back to the ordinary floor rather than to an accept.
 */
/**
 * Git verbs that move a ref or rewrite the working tree. A command containing one of these cannot
 * be certified by a record bound to the HEAD read before it ran.
 */
const REF_MOVING_VERBS = new Set([
  "commit", "reset", "checkout", "switch", "branch", "merge", "rebase", "cherry-pick", "revert",
  "stash", "pull", "am", "apply", "restore", "rm", "mv", "tag", "update-ref", "symbolic-ref",
  "worktree", "clean", "notes", "filter-branch", "fast-import",
]);

/**
 * Git GLOBAL options that consume the following word as their VALUE. The first revision of this
 * file used the regex `git\s+(?:-[^\s]+\s+)*(verb)`, which only skips VALUELESS flags — so
 * `git -c user.name=x commit …` and `git -c core.hooksPath=/dev/null commit …` slipped past BOTH
 * the ref-moving guard and the "a commit ships bytes that do not exist yet" rule, and a record
 * bound to the superseded HEAD authorized the chained push (fresh review round 3, P0). The
 * verification-gate's `findGitVerbInvocation` models exactly this and consumes the `-c` value;
 * that scanner is not exported, so the model is mirrored here (see the drift note below).
 */
const GIT_GLOBAL_OPTS_WITH_VALUE = new Set([
  "-c", "-C", "--git-dir", "--work-tree", "--namespace", "--super-prefix", "--exec-path",
  "--config-env", "--attr-source",
]);

/**
 * The verb of every `git` invocation in the command, with its global options skipped.
 *
 * ⛔ DRIFT NOTE: this is a SECOND model of "git + global options + verb" (the first is
 * `findGitVerbInvocation` in extensions/verification-gate). It is duplicated because that module
 * value-imports the pi SDK and the shared parser module does not export a verb scanner; the
 * shapes it must agree on are pinned by `index.spawn-evidence.test.ts` (§unit — `-c` forms), so a
 * divergence shows up as a failing test rather than as a silent bypass.
 *
 * A FALSE POSITIVE (a quoted mention that splits into words) only closes the evidence path —
 * the ordinary dispatch floor applies — so the cheap split is safe in the fail-closed direction.
 */
export function gitVerbs(command: string): string[] {
  const words = command.split(/[\s;|&()]+/).filter((w) => w.length > 0);
  const verbs: string[] = [];
  for (let i = 0; i < words.length; i++) {
    const w = words[i];
    if (w !== "git" && !w.endsWith("/git")) continue;
    let j = i + 1;
    while (j < words.length) {
      const tok = words[j];
      if (tok.startsWith("-")) {
        j += GIT_GLOBAL_OPTS_WITH_VALUE.has(tok) ? 2 : 1;
        continue;
      }
      verbs.push(tok);
      break;
    }
  }
  return verbs;
}

/**
 * Does this command move a ref (or rewrite the tree) ANYWHERE in it — including behind a
 * `git -c …` global, an inline `GIT_DIR=` assignment, or a `fetch` that retargets the checked-out
 * branch (`--update-head-ok` with a `src:dst` refspec)?
 *
 * Every branch here CLOSES the evidence path (the ≥1-dispatch floor applies); none loosens a gate.
 */
export function commandMovesRefs(command: string): boolean {
  // An inline environment assignment can retarget the whole invocation (F4): `GIT_DIR=/other/.git
  // git push` reads THIS checkout's HEAD while git operates on another repository entirely.
  if (/(^|\s)GIT_(DIR|WORK_TREE|INDEX_FILE|OBJECT_DIRECTORY|COMMON_DIR|NAMESPACE)=/.test(command)) return true;
  // A shell builtin that moves the CHECKOUT (or an unattributable `cd`, whose target the gate
  // cannot resolve) makes the HEAD read here describe a different repository than the op ships.
  if (/(^|\s)(pushd|popd)(\s|$)/.test(command)) return true;
  if (parseCdChains(command).unattributable) return true;
  const verbs = gitVerbs(command);
  if (verbs.some((v) => REF_MOVING_VERBS.has(v))) return true;
  // `fetch` is not ref-moving on its own (it moves remote-tracking refs), but these two forms move
  // the CHECKED-OUT branch: verified locally (fresh review round 3, P1) — `git fetch
  // --update-head-ok origin +side:main` advanced main, i.e. the push then shipped unreviewed bytes.
  if (verbs.includes("fetch")) {
    // BOTH spellings: `--update-head-ok` and its short form `-u` (fresh review round 4, P0).
    if (/(^|\s)(-u|--update-head-ok)(\s|=|$)/.test(command)) return true;
    // A `src:dst` refspec token can write a destination ref — including a FULLY-QUALIFIED
    // `refs/heads/main`, which the first detector excluded by forbidding `/` in the dst.
    const tokens = command.split(/\s+/).filter((t) => t.length > 0);
    if (tokens.some((t) => /^[^:\s]+:[^:\s]+$/.test(t) && !t.includes("://"))) return true;
  }
  return false;
}

/**
 * Is this bash command FREE of every construct that can hide or move what it really runs?
 *
 * ⛔ WHY THIS EXISTS (fresh review round 4, P0 ×3). Rounds 1–3 tried to MODEl the command text:
 * a list of ref-moving verbs, a list of global options, a list of redirects. Each round found
 * another spelling that walks past the model, and every one was a live accept:
 *
 *   git "commit" -m x && git push origin main      (quotes — bash strips them and runs the verb)
 *   git c"ommit" -m x && git push origin main      (quoting INSIDE the word)
 *   git \commit -m x && git push origin main       (backslash escape)
 *   git $(printf commit) -m x && git push origin main   (command substitution)
 *   git co -m x && git push origin main            (alias — the noun is not the verb that runs)
 *   pushd /other && git push origin main           (a shell builtin moves the checkout)
 *   cd $OTHER && git push origin main              (an unattributable cd: HEAD read here, push there)
 *   git fetch -u . +refs/heads/side:refs/heads/main && git push …   (the short -u form)
 *   gh pr create -Hother                            (-H with an ATTACHED value)
 *
 * The lesson is not "add another pattern": a text model of a Turing-complete shell cannot be
 * completed by enumeration. So the evidence path is opened only for a command that contains NO
 * shell syntax at all — no quoting, no escapes, no substitution, no variables, no control
 * operators, no redirects, no subshells, no brace expansion, no newlines. With none of those, the
 * tokens ARE the argv, the verb is the verb, and `git commit`/`pushd`/an alias cannot hide.
 *
 * THIS IS A WHITELIST, and the fallback is the ordinary ≥1-dispatch floor — never an accept. A
 * lane that wants the record path runs the push as its own bare command:
 *
 *     git push origin <branch>          # accepted (with a head-bound record)
 *     gh pr create --title … --body-file …   # accepted (no -H/--head)
 *
 * `git push origin main 2>&1 | tail -3`, `git fetch && git push`, a quoted body, `cd … && push` —
 * all of them fall back to "dispatch a reviewer", which is the pre-existing, still-supported path.
 *
 * DECLARED RESIDUAL: this models the COMMAND, not the repository. A ref written outside git (a
 * direct write under .git/refs) in a PREVIOUS tool call is invisible here; the record is bound to
 * the head read at this op, so moving the branch to an unreviewed commit between calls is the
 * pre-existing TOCTOU of any pre-execution hook, not something this resolver can see.
 */
export function evidenceCommandIsPlain(command: string): boolean {
  // Any shell metacharacter, quote, escape, substitution, operator, redirect or newline: refuse.
  if (/['"`\\$(){}<>|&;\n\r]/.test(command)) return false;
  // A trailing/bare backslash would be an escape even without a following metacharacter.
  if (/\\/.test(command)) return false;
  // ⛔ PATHNAME EXPANSION IS ALSO "THE SHELL CHANGES THE TOKENS" (fresh review round 6, P1).
  // `*`, `?`, `[...]` and `~` are expanded BEFORE the command runs, so a command containing one
  // is NOT "its tokens are the argv" — which is the only reason a positional read is valid here.
  // Measured: `git push origin main -*` was ACCEPTED at the previous head, and in a checkout
  // containing a file named `--tags` bash expands the flag slot to it, so the dropped token
  // became `--tags` and the push shipped every tag — the exact long form the guard at the top of
  // `resolveShippedHeads` refuses. No legitimate accepted shape contains any of these: git forbids
  // `*`, `?`, `[` and `~` in a refname, and `!` is history expansion in an interactive shell.
  if (/[*?[\]~!]/.test(command)) return false;
  return true;
}

/**
 * The command's argv. Valid ONLY after `evidenceCommandIsPlain` has proved the command carries no
 * shell syntax at all — at which point its whitespace-separated tokens ARE the argv and nothing can
 * hide behind a quote or a substitution.
 *
 * Leading `NAME=value` assignments are skipped: they set the ENVIRONMENT, not the operand. (An
 * inline `GIT_DIR=` / `GIT_WORK_TREE=` redirect is refused separately by `commandMovesRefs`; it
 * cannot retarget the checkout through this helper.)
 */
function plainArgv(command: string): string[] {
  const words = command.split(/\s+/).filter((w) => w.length > 0);
  let i = 0;
  while (i < words.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(words[i])) i++;
  return words.slice(i);
}

/** `gh [--repo|-R <slug>] pr create …` — including the global form the gate's own messages print. */
function ghPrCreateArgv(argv: readonly string[]): boolean {
  if (argv[0] !== "gh") return false;
  let i = 1;
  const flag = argv[i];
  if (flag === "--repo" || flag === "-R") i += 2; // space form
  else if (typeof flag === "string" && (flag.startsWith("--repo=") || (flag.startsWith("-R") && flag.length > 2))) i += 1; // attached value
  return argv[i] === "pr" && argv[i + 1] === "create";
}

/** The remote `repoFromGitRemote` reads. The record's repo slug comes from THIS remote's URL. */
const ORIGIN_REMOTE = "origin";

export function resolveShippedHeads(
  command: string,
  ctx: unknown,
): { heads: string[]; repo: string | null; cwd: string } | null {
  // ⛔ FIRST: the command must be free of shell syntax (see evidenceCommandIsPlain). Everything
  // below is a reading of a command that provably runs exactly its tokens.
  if (!evidenceCommandIsPlain(command)) return null;

  // A repo/checkout redirect makes the op's HEAD unattributable from here (the gate has no
  // `-C` model - see resolveRepoContext) -> no evidence.
  if (/(^|\s)(-C|--git-dir|--work-tree|--namespace|--super-prefix)(=|\s|$)/.test(command)) return null;
  if (/(^|\s)(--all|--mirror|--tags|--follow-tags|--delete)([\s=]|$)/.test(command)) return null;
  // ⛔ A `-c <name>=<value>` global can change what a git command DOES (hooksPath, push.default,
  // refspec behaviour, an alias), so the shape the record was bound to is no longer the shape that
  // runs. A `git -c core.hooksPath=/dev/null commit && git push` is an ordinary idiom (fresh review
  // round 3, P0) — refuse the whole class rather than enumerate what a config can alter.
  if (/(^|\s)(-c|--config|--config-env)(=|\s)/.test(command)) return null;

  const opCtx = resolveRepoContext(command, null);
  const ctxCwd = (ctx as { cwd?: unknown } | undefined)?.cwd;
  const cwd = opCtx.cwd ?? (typeof ctxCwd === "string" ? ctxCwd : process.cwd());

  // ⛔ ANCHOR TO THE COMMAND POSITION, NOT TO THE TEXT (fresh review round 5, P2). The plain-command
  // check above proves this is ONE simple command with no shell syntax, so its TOKENS ARE THE ARGV
  // and the op is the FIRST word — not "a word somewhere in the line". The free-text test accepted
  // `echo gh pr create` (nothing ships) at 0 dispatches, and accepted `git commit -m gh pr create`
  // only INCIDENTALLY, because the ref-moving-verb guard caught the commit — not the "a commit ships
  // bytes that do not exist at hook time" rule named below. Anchoring makes both refuse by
  // construction instead of by luck.
  const argv = plainArgv(command);
  const isPush = argv[0] === "git" && argv[1] === "push";
  const isPrCreate = ghPrCreateArgv(argv);
  // `git commit` ships bytes that do not exist at hook time - a record can never describe them.
  if (!isPush && !isPrCreate) return null;

  // ⛔ REF-MOVING PREFIX (fresh review, P1): HEAD is read BEFORE the command runs, so a same-call
  // mutator moves the branch that the push/PR then ships. All of these authorized an op on a record
  // bound to the PRE-mutation HEAD: `git reset --hard side && git push origin main`,
  // `git branch -f main side && git push origin main`, `git checkout -B main side && git push`,
  // `git checkout side && gh pr create -f`. Any ref-moving verb anywhere in the command closes the
  // evidence path (fail-closed: the >=1-dispatch floor applies, nothing is bypassed).
  if (commandMovesRefs(command)) return null;
  // `gh pr create --head|-H <branch>` can open a PR for a branch that is not this checkout's.
  // ⛔ BOTH SPELLINGS (fresh review, P0): matching only `--head` left `gh pr create -H other`
  // opening the evidence path for another branch's commits. `gh pr create --help` lists
  // `-H, --head branch`.
  // `-H` with an ATTACHED value (`-Hother`) is the same flag (fresh review round 4, P0): match the
  // short form wherever it starts a word, not only when whitespace/= follows.
  if (isPrCreate && /(^|\s)(--head(=|\s|$)|-H)/.test(command)) return null;

  let head: string;
  let branch: string;
  try {
    head = execSync("git rev-parse HEAD", { cwd, timeout: 3000, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
    branch = execSync("git rev-parse --abbrev-ref HEAD", { cwd, timeout: 3000, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
  } catch {
    return null; // not a git checkout / detached lookup failed -> no evidence, floor stands
  }
  if (!/^[0-9a-f]{40,64}$/i.test(head)) return null;
  if (branch === "" || branch === "HEAD") return null; // detached: no named branch to reason about

  if (isPush) {
    // `git push <remote> <ref>` — and NOTHING ELSE. The argv is positional now, so there is no
    // text to slice and also no flag to reason about.
    const tail = argv.slice(2);
    // ⛔ NO FLAGS AT ALL (fresh review round 6, P1). Round 5 DROPPED every `-`-prefixed token and
    // then required exactly `<remote> <ref>`, which left the short forms of the flags the long-form
    // guard refuses: `git push origin main -d` (== `--delete`) was ACCEPTED and DELETES the remote
    // branch, and `git push --force-with-lease origin main` / `-f` / `-u` were accepted the same
    // way. A flag can change WHAT the op does without changing its positionals, so this arm accepts
    // the bare shape only. The cost is a false block on `git push -u origin <b>`: that falls back to
    // the ≥1-dispatch floor, which is always available and is what the printed remedy already names.
    if (tail.some((w) => w.startsWith("-"))) return null;
    const words = tail;
    // ⛔ EXACTLY `<remote> <ref>` (fresh review, P2). A bare `git push` / `git push origin`
    // ships whatever `push.default` or `remote.<remote>.push` selects — possibly refs that are not
    // HEAD — while the record is bound to HEAD.
    if (words.length !== 2) return null;
    if (words[0] === "" || words[1] === "") return null;
    if (words.some((w) => w.includes(":"))) return null; // explicit refspec -> not necessarily HEAD
    if (tail.some((w) => w.includes("+"))) return null; // forced refspec
    // ⛔ THE REMOTE MUST BE THE ONE THE RECORD'S REPO WAS READ FROM (fresh review round 5, P2).
    // `repoFromGitRemote` reads `remote.origin.url`, so the record is bound to ORIGIN's slug — but
    // the push arm accepted ANY remote name and still matched against that slug. `git push upstream
    // main` shipped HEAD and was authorized by ORIGIN's record: HEAD is still exactly what ships, so
    // this was not a byte-integrity hole, but "the op's repo" was not the binding that got checked,
    // and a doc/behaviour mismatch is how the next reader gets it wrong. Fail-closed: another remote
    // falls back to the ≥1-dispatch floor, which is always available.
    if (words[0] !== ORIGIN_REMOTE) return null;
    // `git push origin HEAD` ships exactly the commit HEAD resolves to — at least as precise as the
    // branch name, and git infers the same destination branch — so it is accepted. Refusing it was a
    // false block on a shape lanes actually use.
    if (words[1] !== branch && words[1] !== "HEAD") return null;
  }

  const repo = opCtx.repo ?? repoFromGitRemote(cwd);
  return { heads: [head], repo, cwd };
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

// ── #2349: WHAT THE GATE READ (diagnostics only — NEVER a decision) ──────────
//
// Both refusals used to print a CAUSE the gate had not read. The ≥1-dispatch
// floor said "no reviewers dispatched" while reading NO record at all; the merge
// and evidence gates said "no review record" / "no evidence" without naming
// WHICH of several states they were in. The registry is PER-MACHINE
// (~/.pi/agent/reviews on THIS box), so "no review exists" and "a review exists
// but its record is on another box" produced byte-identical text — and a lane
// that cannot tell them apart has no correct next action, so it aborts (measured
// 2026-10-22: 142 `no_reviewers_dispatch` blocks on one box, 156 local records
// against 3260 on the Mac, 55 of 104 open PRs visible from any one box).
//
// ⛔ NOTHING BELOW DECIDES ANYTHING. `observeReviewRecord` is a second,
// read-only pass over the same two paths `readReviewRecord` reads; every
// predicate, return value and exit code of the gate is untouched. The
// consistency pin in index.test.ts asserts the observer and the reader agree on
// presence over a fixture matrix, so the observer cannot silently drift.

export type RecordFileState =
  | { kind: "absent" }
  | { kind: "present" }
  | { kind: "foreign-repo"; repo: string | null }
  | { kind: "corrupt"; reason: string }
  /** Repo-less read: several repo-keyed candidates matched, so no single file is
   *  the one that was tried — distinct from "corrupt", which names a REAL file. */
  | { kind: "ambiguous"; files: string[] };

export interface ReviewRecordObservation {
  pr: number;
  repo: string | null;
  registryDir: string;
  /** For a repo-less read: the path GENERATOR, since no single file is tried. */
  qualifiedPath: string;
  legacyPath: string;
  qualified: RecordFileState;
  legacy: RecordFileState;
  /** Every repo-keyed file matching this PR, when no repo context resolved. */
  ambiguous: string[];
  /** What `readReviewRecord` returns for the same inputs (presence, not a decision). */
  record: ReviewRecord | null;
  mint?: string;
  carriedFrom?: string;
}

/** Read ONE record file and report its state — the reader's parse rules, no verdict. */
function observeRecordFile(path: string): { state: RecordFileState; rec: ReviewRecord | null } {
  let raw: string;
  try {
    raw = fs.readFileSync(path, "utf8");
  } catch (e: any) {
    // ENOENT is "absent"; anything else (EACCES, EISDIR) is a read we could not
    // make, and saying "absent" for it would be the very misreport this fixes.
    if (e?.code === "ENOENT") return { state: { kind: "absent" }, rec: null };
    return { state: { kind: "corrupt", reason: `unreadable (${e?.code ?? e?.message ?? "unknown"})` }, rec: null };
  }
  let parsed: any;
  try {
    parsed = JSON.parse(raw);
  } catch (e: any) {
    return { state: { kind: "corrupt", reason: `not JSON (${e?.message ?? "parse error"})` }, rec: null };
  }
  if (!parsed || typeof parsed.head_sha !== "string" || typeof parsed.verdict !== "string") {
    return { state: { kind: "corrupt", reason: "missing head_sha/verdict" }, rec: null };
  }
  if (parsed.repo !== undefined && !/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(parsed.repo)) {
    return { state: { kind: "corrupt", reason: `invalid repo field ${JSON.stringify(parsed.repo)}` }, rec: null };
  }
  return { state: { kind: "present" }, rec: parsed as ReviewRecord };
}

/**
 * Observe the review registry for (pr, repo) WITHOUT deciding anything.
 *
 * The RESULT mirrors `readReviewRecord`'s presence/absence and nothing else — the
 * gate reads the record through `readReviewRecord` exactly as before. This exists
 * so a refusal can say which of these it is, instead of calling them all "no
 * review record":
 *
 *   • no file on this box at all            → the review may live on ANOTHER box
 *   • a file that names a DIFFERENT repo    → present but inert (#426)
 *   • a file that is corrupt/unreadable     → present but unusable
 *   • several repo-keyed candidates         → ambiguous, trusted by neither
 *   • a usable record                       → then the HEAD/DIFF question is live
 */
export function observeReviewRecord(pr: number, repo?: string): ReviewRecordObservation {
  const registryDir = reviewsDir();
  const legacyPath = reviewRecordFile(undefined, pr);
  const obs: ReviewRecordObservation = {
    pr,
    repo: repo ?? null,
    registryDir,
    qualifiedPath: repo ? reviewRecordFile(repo, pr) : `${registryDir}/<owner>-<repo>-${pr}.json`,
    legacyPath,
    qualified: { kind: "absent" },
    legacy: { kind: "absent" },
    ambiguous: [],
    record: null,
  };
  const legacy = observeRecordFile(legacyPath);
  obs.legacy = legacy.state;
  if (repo) {
    const qualified = observeRecordFile(reviewRecordFile(repo, pr));
    if (qualified.rec) {
      if (qualified.rec.repo !== undefined && qualified.rec.repo !== repo) {
        obs.qualified = { kind: "foreign-repo", repo: qualified.rec.repo };
        // ⛔ MIRROR THE READER EXACTLY: `readReviewRecord` returns null HERE and
        // never reads the legacy file, so a repo-keyed file that claims another
        // repo SHADOWS a usable legacy record. Falling through would print
        // "another repo's record, inert here" AND "record: clean at head …" in the
        // same block — the self-contradicting diagnostic this change exists to
        // remove (fresh review of #2349, P1).
        return finishObservation(obs);
      }
      obs.qualified = qualified.state;
      obs.record = qualified.rec;
    } else {
      obs.qualified = qualified.state;
    }
    // Legacy migration fallback, exactly as readReviewRecord reads it.
    if (!obs.record && legacy.rec) {
      if (legacy.rec.repo !== undefined && legacy.rec.repo !== repo) {
        obs.legacy = { kind: "foreign-repo", repo: legacy.rec.repo };
      } else {
        obs.record = legacy.rec;
      }
    }
  } else {
    // No repo context: the reader scans the directory for repo-keyed candidates.
    // Report the candidates so "ambiguous" is visible instead of "absent".
    try {
      obs.ambiguous = fs
        .readdirSync(registryDir)
        // ⛔ KEEP THIS PATTERN SPELLED EXACTLY LIKE `readReviewRecord`'s. Both sit in a
        // TEMPLATE literal, where `\.` collapses to `.` — so both are a loose dot and
        // both match `…-2349Xjson`. That is why they agree; a previous version of this
        // observer wrote `\\.` (a real escape) and DISAGREED with the reader (reader:
        // present, observer: "no record on this box"). If you tighten the dot, change
        // BOTH call sites in one commit, and re-run the observer↔reader matrix.
        .filter((f) => new RegExp(`^[A-Za-z0-9_.-]+-[A-Za-z0-9_.-]+-${pr}.json$`).test(f));
    } catch {
      obs.ambiguous = []; // registry dir absent — genuinely nothing to list
    }
    if (obs.ambiguous.length === 1) {
      // Name the REAL file: a repo-less read knows the filename, and rendering the
      // `<owner>-<repo>-<pr>.json` generator instead made the refusal tell a lane to
      // inspect a path that does not exist (fresh review of #2349, P2).
      obs.qualifiedPath = resolvePath(registryDir, obs.ambiguous[0]);
      const rec = readRecordFile(obs.qualifiedPath);
      if (rec) {
        obs.qualified = { kind: "present" };
        obs.record = rec;
      } else {
        obs.qualified = { kind: "corrupt", reason: "unreadable record body" };
      }
    } else if (obs.ambiguous.length > 1) {
      obs.qualified = { kind: "ambiguous", files: obs.ambiguous };
      // ⛔ MIRROR THE READER: `readReviewRecord` returns null at >1 matches and never
      // reads `<pr>.json`, so an ambiguous PR is UNTRUSTED — restoring a legacy record
      // here would print "AMBIGUOUS … none is trusted" AND "record: clean at head …"
      // in one block (fresh review, cycle 3, P1).
      return finishObservation(obs);
    }
    if (!obs.record && legacy.rec) {
      if (legacy.rec.repo !== undefined) obs.legacy = { kind: "foreign-repo", repo: legacy.rec.repo };
      else obs.record = legacy.rec;
    }
  }
  return finishObservation(obs);
}

/** Attach the record's mint provenance (diagnostic only) and return the observation. */
function finishObservation(obs: ReviewRecordObservation): ReviewRecordObservation {
  if (obs.record) {
    if (typeof obs.record.mint === "string") obs.mint = obs.record.mint;
    if (typeof obs.record.carried_from === "string") obs.carriedFrom = obs.record.carried_from;
  }
  return obs;
}

/**
 * Which of the four "no usable record" states the observation is in.
 * Reporting only — `readReviewRecord` decided absence before this is consulted.
 */
export function classifyRecordMissState(obs: ReviewRecordObservation): string {
  if (obs.qualified.kind === "foreign-repo" || obs.legacy.kind === "foreign-repo") return RECORD_STATE_FOREIGN;
  if (obs.ambiguous.length > 1 || obs.qualified.kind === "ambiguous") return RECORD_STATE_AMBIGUOUS;
  if (obs.qualified.kind === "corrupt" || obs.legacy.kind === "corrupt") return RECORD_STATE_UNREADABLE;
  return RECORD_STATE_NO_RECORD;
}

/**
 * The "no usable record" diagnosis: what was read, WHICH state that is, and the
 * remedy for that state alone.
 *
 * The distinction is the whole point of #2349: `no record on this box` and `a
 * record exists on another box` are the same bytes on disk and different situations,
 * and only one of them is fixed by re-recording. Everything here is appended AFTER
 * the pre-existing block text, so every pinned remediation line (and the #285
 * task-sub-agent variant) is unchanged.
 */
export function describeRecordMiss(
  observation: ReviewRecordObservation | null,
  pr: number,
  repo: string | undefined
): string[] {
  const lines = ["   ⟦WHAT THIS GATE READ — registry observation, NOT a decision⟧"];
  if (!observation) {
    // No observation was supplied (a direct unit call). Name the paths it WOULD
    // read and say the state was not observed — never guess "absent".
    lines.push(`     repo-keyed   : ${reviewRecordFile(repo, pr)} — state not observed on this call`);
    lines.push(`     legacy       : ${reviewRecordFile(undefined, pr)} — state not observed on this call`);
    return lines;
  }
  lines.push(...describeRecordObservation(observation));
  const state = classifyRecordMissState(observation);
  lines.push(`     ⇒ STATE: ${state}`);
  const recordCmd = `${RECORD_SH} ${pr} <head_sha> <verdict> ${repo ?? "owner/repo"}`;
  if (state === RECORD_STATE_FOREIGN) {
    lines.push("       A record EXISTS and is readable — it names a different repo for the SAME PR number (#426).");
    lines.push(`     → remedy: record THIS repo's PR (${recordCmd}); the file above cannot be reused.`);
  } else if (state === RECORD_STATE_AMBIGUOUS) {
    lines.push("       More than one repo-keyed record matches this PR number and no repo context resolved the");
    lines.push("       ambiguity, so trusting either would be a guess (#426).");
    lines.push(`     → remedy: pass --repo owner/name to the merge so the qualified path is unambiguous, then ${recordCmd}.`);
  } else if (state === RECORD_STATE_UNREADABLE) {
    lines.push("       A file EXISTS at a registry path but could not be parsed/read — the gate treats it as absent.");
    lines.push(`     → remedy: inspect the file named above (a truncated write or a bad \`repo\` field), then re-record: ${recordCmd}.`);
  } else {
    lines.push("       NO file exists at either path ON THIS BOX. The registry is PER-MACHINE, so this is");
    lines.push("       \"not visible here\" — NOT necessarily \"no review happened\": a record minted on another box");
    lines.push("       (or under another HOME) is invisible to this gate, and this box sees only its own.");
    lines.push("     → remedy (a): if the review ran elsewhere, copy its <owner>-<repo>-<pr>.json into the repo-keyed");
    lines.push("       path above. → remedy (b): re-record here at the head you are merging:");
    lines.push(`       ${recordCmd}`);
  }
  return lines;
}

/** Escape a record field for display: JSON.stringify keeps it on ONE line. */
function displayRecordField(v: unknown, max = 40): string {
  return JSON.stringify(String(v ?? "").slice(0, max));
}

/** A record field that is safe to INTERPOLATE mid-sentence: control characters are
 *  replaced, so a hand-edited record cannot forge a new refusal LINE. The record
 *  reader validates only `typeof … === "string"` for `head_sha` and `verdict`, so
 *  neither is trusted as display text (fresh review of #2349, P2). */
function oneLine(v: unknown, max = 12): string {
  return String(v ?? "").replace(/[\u0000-\u001f\u007f]/g, "?").slice(0, max);
}

/**
 * The registry file the record ACTUALLY came from.
 *
 * `qualifiedPath` is a path GENERATOR in a repo-less read, and on the legacy
 * migration path the record is `<pr>.json` while the repo-keyed file may not exist
 * at all — printing `qualifiedPath + "(this is the record read)"` there answered
 * "which file did the gate read?" falsely in exactly the case #2349 is about.
 */
export function recordSourcePath(obs: ReviewRecordObservation): string {
  if (obs.qualified.kind === "present") return obs.qualifiedPath;
  if (obs.legacy.kind === "present") return obs.legacyPath;
  return obs.record ? obs.legacyPath : obs.qualifiedPath;
}

/** One line per filesystem state — the "what I read" block of a refusal. */
export function describeRecordObservation(obs: ReviewRecordObservation, indent = "     "): string[] {
  const fileState = (s: RecordFileState): string =>
    s.kind === "absent"
      ? "ABSENT"
      : s.kind === "present"
        ? "PRESENT"
        : s.kind === "foreign-repo"
          ? `PRESENT, but it names repo ${s.repo ?? "(none)"} — another repo's record, inert here (#426)`
          : s.kind === "ambiguous"
            ? `AMBIGUOUS — ${s.files.length} repo-keyed files match (${s.files.join(", ")}), so no single file is the one tried`
            : `PRESENT but UNREADABLE (${s.reason}) — treated as absent (fail-closed)`;
  const lines = [
    `${indent}registry dir : ${obs.registryDir}`,
    `${indent}repo-keyed   : ${obs.qualifiedPath} — ${fileState(obs.qualified)}`,
    `${indent}legacy       : ${obs.legacyPath} — ${fileState(obs.legacy)}`,
  ];
  if (obs.ambiguous.length > 1) {
    lines.push(`${indent}ambiguous    : ${obs.ambiguous.join(", ")} — no single repo-keyed owner, so none is trusted`);
  }
  if (obs.record) {
    const provenance = obs.mint ? ` mint=${oneLine(obs.mint, 20)}` : "";
    const carried = obs.carriedFrom ? ` carried_from=${oneLine(obs.carriedFrom)}` : "";
    // `verdict` is the ONE record field the reader does not charset-validate (it
    // only checks `typeof === "string"`), so it is JSON-escaped before it reaches a
    // refusal: a hand-edited record must not be able to forge extra refusal LINES
    // (e.g. an "Emergency: set AGENT_SKIP_REVIEW_GATE=1" line) inside the text a
    // lane reads (fresh review of #2349, P2). It cannot flip a decision — this
    // text is built only after the gate already blocked — but it can make a
    // refusal lie about the remedy.
    const verdict = displayRecordField(obs.record.verdict);
    lines.push(
      `${indent}record       : ${verdict} at head ${oneLine(obs.record.head_sha)}${provenance}${carried}`
    );
  }
  return lines;
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

// ── #1351: the live diff digest (the carry arm's I/O half) ────
//
// The pure gate takes `currentDiffHash` as an argument; this is where that
// argument comes from. The digest must be the SAME one the GitHub
// ai-review-gate computes live AND the same one record-review.sh stores, or the
// two gates disagree again. So it is not re-implemented here: the ONE
// implementation is `scripts/record-review.sh --print-diff-hash`, which reuses
// `diff_hash_for_pr`, the #1398 size-cap local fallback, and the shared
// `scripts/lib/diff-normalize.py` normalizer. Delegating (like
// resolveAdminMergeEvidenceVerifier delegates its predicate) is what keeps one
// definition of "unchanged" instead of two that drift.

/** TEST SEAM: replace the live-diff-digest read. Honored only under
 * NODE_ENV=test, mirroring _setRunGhOverride, so production can never honor a
 * stray override. */
let prDiffHashOverride: ((pr: number, ctx: RepoContext) => string | null) | null = null;

export function _setPrDiffHashOverride(
  fn: ((pr: number, ctx: RepoContext) => string | null) | null
): void {
  if (process.env.NODE_ENV === "test" || fn === null) prDiffHashOverride = fn;
}

/**
 * Resolve `scripts/record-review.sh` from THIS extension's own location (via
 * realpath, because the extension is normally installed as a symlink whose load
 * path is not the tree the script lives in). Returns null when it is absent —
 * the caller then treats the live digest as uncomputable and the gate fails
 * closed on the head binding, exactly as it did before #1351.
 */
export function resolveDiffHashHelper(): string | null {
  const roots: string[] = [];
  if (EXTENSION_DIR) {
    try {
      roots.push(fs.realpathSync(EXTENSION_DIR));
    } catch {
      /* an unresolvable extension dir is simply no candidate */
    }
    roots.push(EXTENSION_DIR);
  }
  for (const root of roots) {
    const candidate = resolvePath(root, "..", "..", "scripts", "record-review.sh");
    try {
      if (fs.existsSync(candidate)) return candidate;
    } catch {
      /* an unreadable candidate is not a match */
    }
  }
  return null;
}

/**
 * Parse the helper's stdout — the LAST non-empty line, whose shape is
 * `<status>\t<hash>`. ONLY `ok` carries an acceptable digest: every other
 * status (`empty`, `too_large`, `nondiff`, `unavailable`) means the diff could
 * not be READ, and a failed read must never be compared as if it were content.
 * Any other line shape, a missing hash, or a hash that is not a full 64-hex
 * digest (or is the empty-body constant) yields null.
 */
export function parseDiffHashHelperOutput(stdout: string): string | null {
  return parseDiffHashHelperOutputObserved(stdout).hash;
}

/**
 * #2349 — the SAME parse, plus WHY it yielded no digest.
 *
 * `getPrLiveDiffHash` returns null for every failed read, which is correct for a
 * decision (a failed read is not a matching read) and useless for a message: "live
 * digest unreadable" with no reason sends a lane to re-record a record that was
 * never the problem. The statuses are the producer's own vocabulary — `empty`,
 * `too_large`, `nondiff`, `unavailable` — so the reason names the real cause.
 * The parsing rules are IDENTICAL to the original; only the null carries a why.
 */
export function parseDiffHashHelperOutputObserved(stdout: string): { hash: string | null; reason: string | null } {
  const lines = stdout.split("\n").filter((l) => l.length > 0);
  if (lines.length === 0) return { hash: null, reason: "helper printed no status line" };
  const line = lines[lines.length - 1];
  const tab = line.indexOf("\t");
  if (tab < 0) return { hash: null, reason: `helper line has no <status>\\t<hash> shape (${line.slice(0, 60)})` };
  const status = line.slice(0, tab).trim();
  const hash = line.slice(tab + 1).trim();
  if (status !== "ok") {
    // `empty`/`nondiff` mean the PR's body carried no diff; `too_large` is the
    // 300-file API cap; `unavailable` is a failed fetch. All are the producer's
    // own status words, so no new vocabulary is invented here.
    return { hash: null, reason: `helper status "${status}" (no diff identity could be read)` };
  }
  if (!isDiffSha256(hash)) {
    // ⛔ NOT `hash.toUpperCase()` here: `isDiffSha256` is a type guard, so the
    // negative branch narrows `hash` to `never` and any property access is a tsc
    // error on a branch that can never be reached (fresh review of #2349, P2).
    // The reason is derived in a helper that sees a plain `string`.
    return { hash: null, reason: describeNonDiffValue(hash) };
  }
  return { hash, reason: null };
}

/** Why a value is not a diff identity — named without narrowing the caller's value. */
function describeNonDiffValue(v: string): string {
  if (v === EMPTY_BYTE_SHA256) return "helper returned the EMPTY-BODY digest — not a diff identity";
  if (/^[0-9a-fA-F]{64}$/.test(v) && v !== v.toLowerCase()) {
    return "helper returned an UPPERCASE digest — not a diff identity";
  }
  return "helper returned a value that is not a full 64-hex digest";
}

/**
 * How long the LIVE diff read may take (ms).
 *
 * ⛔ THIS BOUND WAS 60s AND THAT WAS A SILENT FALSE NEGATIVE (measured 2026-10-22).
 * The read is one `gh api` inside `record-review.sh`, and on this fleet every `gh`
 * invocation first queues at the SHARED gh gate (`~/.pi/agent/shims/gh`), whose
 * slot-acquire budget alone is 300s by default (`AGENT_GH_GATE_ACQUIRE_TIMEOUT`)
 * before a single byte of HTTP is sent. So under fleet contention — the exact
 * condition in which a dozen open PRs are waiting on the carry ARM — the child was
 * killed at 60s WHILE THE GATE WAS STILL QUEUEING, `execFileSync` threw, and the
 * caller received `null`.
 *
 * `null` is the arm's fail-closed signal, so nothing unsafe happened — but the
 * refusal it produced was `head_advanced` ("the branch moved — re-review the new
 * head"), i.e. a QUEUEING DELAY was rendered as a CONTENT CHANGE, and the lane paid
 * a whole fresh review for a diff that never changed. That is the same speech-act
 * error #1690 fixed for the head read ("an unreadable head is NOT a claim about
 * reality"), in the diff dimension — so it gets the same treatment: a bound that
 * outlasts the queue, and a refusal that says which of the two happened.
 *
 * The default mirrors the budget the HEAD read already waits under
 * (`rateLimitMaxWaitMs`, 10 min): a diff read is the same kind of shared-pool call and
 * was MEASURED at 399s end-to-end on 2026-10-22 while 40 PRs were open, so any bound
 * below that class keeps killing reads that were merely queued. Raise it where the
 * gate is configured with a longer acquire timeout. A genuinely unreachable API still
 * ends in `null` — bounded, and now legible.
 */
export function diffHashReadTimeoutMs(): number {
  // ⛔ A FULL-INTEGER PARSE, AND A FLOOR ON THE OVERRIDE. `parseInt` accepts any
  // leading-integer prefix, so a human spelling like `10m` yielded TEN MILLISECONDS —
  // the same killed-while-queueing read this function exists to prevent, silently
  // reintroduced fleet-wide by a config value (review, #2353 P2). An override is an
  // operator's stated intent, so a legitimate short value is honoured under test, but
  // outside test a bound below the floor is ignored rather than trusted.
  const raw = (process.env.REVIEW_ENFORCER_DIFF_HASH_TIMEOUT_MS ?? "").trim();
  const FLOOR_MS = 60_000;
  if (/^[0-9]+$/.test(raw)) {
    const explicit = Number.parseInt(raw, 10);
    if (explicit > 0 && (explicit >= FLOOR_MS || process.env.NODE_ENV === "test")) return explicit;
  }
  const acquire = parseInt(process.env.AGENT_GH_GATE_ACQUIRE_TIMEOUT ?? "", 10);
  const acquireMs = (Number.isInteger(acquire) && acquire > 0 ? acquire : 300) * 1000;
  // NOTE: the read itself retries (record-review.sh DIFF_FETCH_ATTEMPTS=3), so a path
  // whose every attempt queues can still outlast any single bound. That residual is
  // declared rather than papered over: the failure is now `diff_unreadable` (RETRY),
  // which is cheap and re-decidable, instead of a false "the content changed".
  return Math.max(600_000, acquireMs + 120_000);
}

/**
 * The PR's live normalized three-dot diff digest, or null when it cannot be
 * computed. The repo is taken from the SAME resolved context the gate verified
 * the head through, and is RE-VALIDATED here (a `--repo` flag is user-controlled
 * text) before it reaches an argv element. Every failure — no repo, no helper,
 * no `gh`/`openssl`/`python3`, the 300-file cap, a network failure, a timeout —
 * returns null, which the gate reads as "no identity" and blocks on the head.
 *
 * ⛔ NULL MEANS "COULD NOT READ", NEVER "READ AND DIFFERS". The two are
 * different operational events with different remedies (retry vs re-review), so
 * the caller must not collapse them: `evaluateMergeGate`'s `diffReadFailed`
 * argument exists to keep them apart at the one point that prints the remedy.
 */
export function getPrLiveDiffHash(pr: number, ctx: RepoContext): string | null {
  return getPrLiveDiffHashObserved(pr, ctx).hash;
}

/**
 * #2349 — `getPrLiveDiffHash` plus WHY it yielded no digest, for the refusal text.
 * The read, its guards and its return value are unchanged; the reason is
 * additional output, and the decision still consumes `hash` only.
 */
export function getPrLiveDiffHashObserved(
  pr: number,
  ctx: RepoContext
): { hash: string | null; reason: string | null } {
  if (prDiffHashOverride !== null) {
    const h = prDiffHashOverride(pr, ctx);
    return { hash: h, reason: h === null ? "test seam returned null" : null };
  }
  const helper = resolveDiffHashHelper();
  if (helper === null) {
    return { hash: null, reason: `${RECORD_SH} (--print-diff-hash) not found next to this extension` };
  }
  const repo = ctx.repo ?? (ctx.cwd ? repoFromGitRemote(ctx.cwd) : null);
  if (!repo || !/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repo)) {
    return { hash: null, reason: repo ? `repo ${JSON.stringify(repo)} is not owner/name` : "repo context unresolved" };
  }
  try {
    // execFileSync, NOT a shell string: every argument is passed as an argv
    // element, so no value here can be re-parsed as shell syntax.
    const out = execFileSync("bash", [helper, "--print-diff-hash", String(pr), repo], {
      cwd: ctx.cwd,
      timeout: diffHashReadTimeoutMs(),
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    });
    return parseDiffHashHelperOutputObserved(out);
  } catch (e: any) {
    const msg = (e?.stderr ?? e?.message ?? "").toString().trim();
    return {
      hash: null,
      reason: `--print-diff-hash failed (${e?.status != null ? `exit ${e.status}` : "no status"}${msg ? `: ${msg.split("\n")[0].slice(0, 120)}` : ""})`,
    };
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

/**
 * #1351 — the sha256 of the EMPTY byte string, named so it can never be
 * compared by accident.
 *
 * It is a CONSTANT shared by every "no content" input: hash an empty (or
 * non-diff) body and every PR gets this digest, so every stale record
 * "matches" it and an unreviewed revision merges. The producer already refuses
 * to mint it (it hashes nothing unless the body carries a `diff --git` entry),
 * and this predicate is the consumer's half of the same rule: a value equal to
 * the empty-body digest is NEVER a diff identity, on EITHER side, so it can
 * neither be claimed by a record nor supplied as the live hash. It makes the
 * carry arm fail CLOSED on a caller that hands it sha256("") instead of null. */
export const EMPTY_BYTE_SHA256 =
  "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

/** A full, lowercase, 64-hex diff digest — and NOT the empty-body constant.
 * Shape AND constant are both required: the carry comparison must be a full
 * 64-hex equality (never a prefix or a substring), and the empty-body digest
 * must never be able to satisfy it. */
export function isDiffSha256(v: unknown): v is string {
  return typeof v === "string" && /^[0-9a-f]{64}$/.test(v) && v !== EMPTY_BYTE_SHA256;
}

// ── #2349: the four states a moved head can be in, and the carry arm's exact text ──
//
// One refusal used to cover all of these, so the lane could not pick a next move.
// Each label below is the string a refusal PRINTS, and each has its own remedy —
// pinned by index.test.ts, because a message test that cannot fail is decoration.
export const RECORD_STATE_NO_RECORD = "no record on this box";
export const RECORD_STATE_FOREIGN = "a record exists but belongs to ANOTHER repo — inert here (#426)";
export const RECORD_STATE_UNREADABLE = "a record file exists but cannot be read — treated as absent (fail-closed)";
export const RECORD_STATE_AMBIGUOUS = "several repo-keyed records match this PR — none is trusted (#426)";
export const RECORD_STATE_HEAD_STALE = "record exists but head is stale";
export const RECORD_STATE_DIGEST_ABSENT =
  "record exists, diff digest absent (pre-#2982) — cannot carry";
export const RECORD_STATE_DIGEST_MISMATCH = "digest mismatch";
export const RECORD_STATE_LIVE_UNREADABLE = "live digest unreadable";
export const RECORD_STATE_CARRY_ALLOWED =
  "a moved head whose reviewed DIFF is unchanged IS allowed (carried, #1351)";

/**
 * The carry arm's predicate, CONJUNCT BY CONJUNCT, as the refusal prints it.
 *
 * #2349 review: a paraphrase of the predicate is how the text starts lying about
 * the code. The four rows are the four conjuncts of `evaluateMergeGate`'s carry
 * arm, in source order, and the last line states the consequence a lane most needs
 * and is least likely to know: ALL FOUR TRUE is an ALLOW, with no re-record.
 *
 * The live conjunct is reported as `[ ] not read` when the caller never read it —
 * true of the code (the caller computes the live digest only when the record
 * carries a usable one AND the head moved), and saying "unreadable" there would
 * invent a read that never happened.
 */
export function describeCarryConjuncts(
  record: ReviewRecord,
  currentHead: string,
  currentDiffHash: string | null,
  liveDiffReadReason: string | null,
  indent = "     "
): string[] {
  const rec = oneLine(record.head_sha);
  const live = oneLine(currentHead);
  const moved = record.head_sha !== currentHead;
  const recDigestOk = isDiffSha256(record.diff_sha256);
  const liveDigestOk = isDiffSha256(currentDiffHash);
  const equal = recDigestOk && liveDigestOk && record.diff_sha256 === currentDiffHash;
  const mark = (ok: boolean, read: boolean): string => (read ? (ok ? "[✓]" : "[✗]") : "[ ]");
  const recDigestNote = recDigestOk
    ? `${String(record.diff_sha256).slice(0, 12)}`
    : `ABSENT (pre-#2982 record, or a minted-while-degraded read) — cannot carry`;
  const liveRead = recDigestOk; // the caller only reads it when the record has one
  const liveDigestNote = !liveRead
    ? "NOT READ — the gate only reads the live diff when the record carries a usable digest"
    : liveDigestOk
      ? `${String(currentDiffHash).slice(0, 12)}`
      : `UNREADABLE${liveDiffReadReason ? ` (${liveDiffReadReason})` : ""}`;
  const equalNote = !liveRead
    ? "no comparison possible"
    : !recDigestOk || !liveDigestOk
      ? "no comparison possible"
      : `${String(record.diff_sha256).slice(0, 12)} ${equal ? "==" : "!="} ${String(currentDiffHash).slice(0, 12)}`;
  return [
    `${indent}carry arm, conjunct by conjunct (evaluateMergeGate, source order):`,
    `${indent}  ${mark(moved, true)} record.head_sha !== currentHead            recorded ${rec} vs live ${live}`,
    `${indent}  ${mark(recDigestOk, true)} isDiffSha256(record.diff_sha256)          ${recDigestNote}`,
    `${indent}  ${mark(liveDigestOk, liveRead)} isDiffSha256(currentDiffHash)           ${liveDigestNote}`,
    `${indent}  ${mark(equal, liveRead)} record.diff_sha256 === currentDiffHash  ${equalNote}`,
    `${indent}⇒ ${RECORD_STATE_CARRY_ALLOWED} — all four true carries the verdict forward with NO re-record.`,
  ];
}

/**
 * THE ONLY RUNNABLE SPELLING of the recorder, in one place (review of #2148, P1).
 *
 * `~/.pi/agent/scripts` is NOT on PATH — both the commit-workflow and code-review skills say so
 * explicitly ("Resolve record-review.sh explicitly"), and `merge-one.sh` runs it from
 * `$HOME/.pi/agent/scripts/`. A bare `record-review.sh …` in a refusal therefore fails with
 * `command not found` at the exact moment the lane is trying to land, and a repo-relative
 * `scripts/record-review.sh` only works inside agent-infra's own checkout. Every record command this
 * extension prints — micro, low, standard — goes through here, and a test refuses any message that
 * names the script any other way.
 */
const RECORD_SH = "~/.pi/agent/scripts/record-review.sh";

/**
 * The caveat every message carries when the verdict is INTERPOLATED (`${record.verdict}`) instead of
 * written out: the message cannot branch on the verdict without re-literalising the vocabulary the
 * C7 pin forbids at a call site, so it names the requirement in the same sentence instead. A
 * message that prints a `clean` invocation with no `--evidence` anywhere hands the lane a command
 * that exits 3 — the defect this issue is about, one branch over (reviews of #2148, P1).
 */
const EVIDENCE_CAVEAT =
  "(a clean verdict also needs --evidence comment:<review-comment-id>; clean-low/clean-micro do not)";

export type MergeGateResult =
  | { status: "block"; reason: string; reasonTag?: string }
  | { status: "failopen"; warning: string }
  | { status: "allow"; message: string; carried?: boolean };

/**
 * #513/#2347 — the ONE place the "a fresh review is owed" recipe is written, per tier.
 * Every arm that tells a lane to re-review uses it, so a future arm cannot re-introduce
 * the three defects this text has already shipped with: a truncated sha (refused by
 * record-review.sh, exit 2), a hardcoded `clean` laid over a tier verdict (a micro PR
 * sent to the full standard review its tier exempts, a clean-low one told to re-record
 * a shape it must re-derive), and `--evidence` promised to the two verdicts that accept
 * it and drop it.
 */
export function freshReviewAdvice(verdict: string, pr: number): string {
  const cmd = `${RECORD_SH} ${pr} <head_sha>`;
  if (verdict === "clean-low") {
    return (
      "     → Re-derive the SHAPE rather than re-recording it: re-check whether the NEW head is still\n" +
      `       content-only, then name the verdict explicitly — ${cmd} clean-low [owner/repo].\n` +
      `       If it is no longer content-only, run the code-review skill and record ${cmd} clean [owner/repo] --evidence comment:<review-comment-id>.`
    );
  }
  if (verdict === "clean-micro") {
    return (
      `     → Micro issue (complexity:micro): complete the micro flow, then ${cmd} clean-micro [owner/repo]\n` +
      "       (no --evidence: clean-micro certifies the micro PROCESS, not a review artifact)."
    );
  }
  return `     → Run the code-review skill, post its verdict as a PR comment, then ${cmd} clean [owner/repo] --evidence comment:<review-comment-id>`;
}

// Pure gate decision — separated from I/O so it is unit-testable.
export function evaluateMergeGate(
  pr: number,
  record: ReviewRecord | null,
  currentHead: string | null,
  ctx: RepoContext,
  taskSubAgent: boolean = false,
  currentMergeBase: string | null = null,
  // #1351 — the PR's LIVE normalized diff digest, computed by the caller (the
  // pure function performs no I/O). null means "not computed" — a missing tool,
  // an unreadable/empty/non-diff body, the 300-file API cap, or a network
  // failure. Every one of those is a FAILED READ, and a failed read is not a
  // matching read, so null blocks on the head binding like any other mismatch.
  currentDiffHash: string | null = null,
  // #1351 — WHY `currentDiffHash` is null. The caller ATTEMPTED a read (the
  // record carries a usable digest and the head moved) and it came back null:
  // either the read failed, or the body was empty/non-diff/over the 300-file
  // cap. That is NOT a statement that the content changed, and the two remedies
  // are opposites (RETRY the merge vs pay for a fresh review), so the caller
  // says which happened rather than letting the arm guess. Defaults to false
  // because the common null is "never asked" (a matching head, or a legacy
  // record with no digest), which must keep the unchanged `head_advanced` path.
  //
  // ⛔ ORDER: it is deliberately LAST. #2349's `observation` / `liveDiffReadReason`
  // (below) are the two message inputs that landed on `main` while this branch was
  // open, and they occupy positions 8-9 in every existing caller and test. Appending
  // the flag after them keeps that contract intact instead of silently re-binding
  // an observation object to a boolean parameter.
  // #2349: these two arguments are MESSAGE INPUTS ONLY. They reach a refusal's
  // text and nothing else — no branch below tests them, and no return value
  // depends on them (pinned by the "decision code" extraction in index.test.ts).
  //   observation        — what `observeReviewRecord` saw on disk, for the
  //                        "no record" arm (absent / foreign-repo / corrupt / ambiguous).
  //   liveDiffReadReason — why the live digest read yielded nothing, for the
  //                        moved-head arm (a failed READ is not a failed review).
  observation: ReviewRecordObservation | null = null,
  liveDiffReadReason: string | null = null,
  diffReadFailed: boolean = false,
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
          `   → Micro issue (complexity:micro): ${RECORD_SH} <PR> <head_sha> clean-micro [owner/repo]`,
          `   → Content-only diff (docs/ with a content extension, or a named root prose file — any tier): ${RECORD_SH} <PR> <head_sha> clean-low [owner/repo]`,
          // #2148 review: `--evidence` is part of the `clean` invocation — `record-review.sh` refuses a
          // FRESH clean without it (tortoise#7391, exit 3). A refusal that names a command which then
          // exits 3 hands the lane a second dead end at the moment it tries to land.
          `   → Standard/complex issue: run the code-review skill, then ${RECORD_SH} <PR> <head_sha> clean [owner/repo] --evidence comment:<review-comment-id>`,
          "   → The bypass flag does NOT unlock sub-agent merges (#285).",
        ]
      : [
          "✅ Review enforcement (merge registry) gate is working correctly.",
          `❌ No review record found for PR #${pr} — the code-review gate has not recorded a clean review.`,
          "   → Micro issue (complexity:micro): complete the micro flow (pre-flight + a review dispatch naming the diff), then",
          `   →   ${RECORD_SH} <PR> <head_sha> clean-micro [owner/repo]`,
          `   → Content-only diff (docs/ with a content extension, or a named root prose file — any tier, no code paths): ${RECORD_SH} <PR> <head_sha> clean-low [owner/repo]`,
          "   → Standard/complex issue: run the code-review skill (Step 10 records clean on convergence), post its verdict as a PR comment, then",
          `   →   ${RECORD_SH} <PR> <head_sha> clean [owner/repo] --evidence comment:<review-comment-id>`,
          "   → Emergency: set AGENT_SKIP_REVIEW_GATE=1 (or ELDATO_SKIP_REVIEW_GATE=1) and restart to bypass all gates.",
        ];
    // #2349: append WHAT WAS READ and which state that is — absent / foreign-repo /
    // corrupt / ambiguous — each with its own remedy. The pre-existing lines above
    // are untouched (pinned by #285/#513 and their tests).
    lines.push(...describeRecordMiss(observation, pr, ctx.repo));
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
        `   → Micro issue (complexity:micro): re-record via the micro flow: ${RECORD_SH} <PR> <head_sha> clean-micro [owner/repo]`,
        `   → Content-only diff (docs/ with a content extension, or a named root prose file — any tier): ${RECORD_SH} <PR> <head_sha> clean-low [owner/repo]`,
        `   → Standard/complex issue with any code path: run the code-review skill, post its verdict as a PR comment, then ${RECORD_SH} <PR> <head_sha> clean [owner/repo] --evidence comment:<review-comment-id>`,
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
          `   →   ${RECORD_SH} <PR> <head_sha> ${record.verdict} [owner/repo] ` + EVIDENCE_CAVEAT,
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
        ? `The repo could not be resolved (no --repo/GH_REPO/cd, and the session cwd is not a GitHub worktree). If this PR is in another repo, re-record with repo info — ${RECORD_SH} <PR> <head_sha> ${record.verdict} owner/repo — or pass --repo owner/repo to gh pr merge. ${EVIDENCE_CAVEAT}`
        : `If this persists, re-record with repo info — ${RECORD_SH} <PR> <head_sha> ${record.verdict} owner/repo — or pass --repo owner/repo to gh pr merge. ${EVIDENCE_CAVEAT}`;
    return {
      status: "failopen",
      warning:
        `⚠️  [review-enforcer] Could not verify head of PR #${pr} via gh (repo context: ${ctx.source}). ` +
        `Allowing merge WITHOUT head verification. ${advice}`,
    };
  }
  // #1351 — the DIFF binding: mirror the GitHub ai-review-gate's rule (b).
  //
  // A required GitHub check accepts a signed record when `diff=<sha256>` matches
  // the PR's CURRENT diff even though its `@ <sha>` is stale (tortoise#2982): a
  // merge-only `gh pr update-branch` moves the head without changing the
  // three-dot diff. The local gate was HEAD-only, so the SAME PR showed a green
  // required check AND a locally blocked merge — the two gates disagreed about
  // what "reviewed" means, and the fleet paid for a re-record the content never
  // required.
  //
  // ORDER IS THE SECURITY. This arm sits AFTER the head-unverifiable branch
  // (whose fail-open/fail-closed semantics are untouched) and BEFORE the
  // head-advanced block, so a match RETURNS allow instead of being overridden by
  // it. It fires ONLY on a STALE head: when the head matches, the head binding is
  // already satisfied and every later guard — the #1348 clean-low merge-base
  // binding included — must run exactly as it did before. A carried record does
  // not reach the merge-base branch at all, which is correct rather than a
  // bypass: a matching diff digest proves the CONTENT is identical, and the
  // clean-low claim is about the content's shape, so the binding's question is
  // already answered (a repointed base changes the diff and fails this arm).
  //
  // FAIL CLOSED on everything else. A record with NO usable `diff_sha256` falls
  // through to `head_advanced` — absence is not identity. So does an
  // uncomputable live hash. And both sides must be a full 64-hex digest that is
  // not the empty-body constant (isDiffSha256): equality is exact, never a
  // prefix or a substring.
  if (
    record.head_sha !== currentHead &&
    isDiffSha256(record.diff_sha256) &&
    isDiffSha256(currentDiffHash) &&
    record.diff_sha256 === currentDiffHash
  ) {
    return {
      status: "allow",
      carried: true,
      message:
        `[review-enforcer] ✅ Merge registry gate passed for PR #${pr} ` +
        `(${record.verdict} review, head moved ${record.head_sha.slice(0, 12)} → ${currentHead.slice(0, 12)} ` +
        `but the reviewed DIFF is unchanged — diff_sha256 ${currentDiffHash.slice(0, 12)} matches the PR's ` +
        `current diff, so the verdict is CARRIED FORWARD on content identity) — allowing merge\n` +
        // #2349: the SAME sentence the refusals print (one exported constant, so the
        // allow and the refusal cannot describe the rule differently). A lane that has
        // only ever read refusals needs to learn this arm EXISTS.
        `   ⇒ ${RECORD_STATE_CARRY_ALLOWED}.`,
    };
  }
  if (
    record.head_sha !== currentHead &&
    diffReadFailed &&
    // The flag says the caller ATTEMPTED a read, and a read is only attempted
    // when the record carries an identity. Requiring it here keeps the branch
    // self-consistent even for a caller that sets the flag unconditionally: a
    // record with NO usable digest can never be a "could not read" case, its
    // remedy is the unchanged one, and the text below quotes the digest.
    isDiffSha256(record.diff_sha256)
  ) {
    // #1351 — A FAILED READ IS NOT A CHANGED DIFF (#1690's speech act, in the
    // diff dimension). We got here because the record DOES carry a usable
    // digest and the head moved, i.e. the carry arm was REACHABLE — and then the
    // live digest could not be read (a shared-gh-gate queue longer than the
    // read bound, a rate-limit window, an empty/over-cap/non-diff body, a
    // network failure). Rendering that as `head_advanced` told the lane to pay
    // 20-40 minutes for a fresh review of content that may be byte-identical.
    //
    // FAIL CLOSED, and state the remedy that actually applies: RETRY. The retry
    // is cheap and it re-asks the only question that decides. The `[diff_unreadable]`
    // tag exists so the audit trail (gate-events.jsonl) can reconstruct these by
    // reason — `head_advanced` was two different operational events behind one tag.
    return {
      status: "block",
      reasonTag: "diff_unreadable",
      reason: [
        `❌ PR #${pr} head has moved (${record.head_sha.slice(0, 12)} → ${currentHead.slice(0, 12)}) and the`,
        "   reviewed DIFF could not be READ, so it could not be compared.",
        "   This is NOT a claim that the content changed — a read that failed is not a diff that differs.",
        // #2349 — say WHAT the read reported. This arm is the one place that
        // declares a failed read, so the reason #2349 threads through for the
        // head-stale arm belongs here too; dropping it would make this refusal
        // less informative than the narrower one it precedes.
        `   What the read reported: ${liveDiffReadReason ?? "(no reason reported by the caller)"}`,
        "   → RETRY the merge. A shared gh-gate queue, a rate-limit window or a transient API"
        + " failure is far cheaper than a re-review, and the carry arm re-decides on every attempt.",
        "   → Do NOT mint a fresh record for this: an unchanged diff CARRIES on the digest alone",
        `     (record diff_sha256 ${record.diff_sha256!.slice(0, 12)}…).`,
        "   → To see which case you are in without merging, compare the two digests:",
        `     ${RECORD_SH} --print-diff-hash ${pr} ${ctx.repo ?? "<owner/repo>"}`,
        `     (or in one step: ${RECORD_SH} --check-carry ${pr} ${ctx.repo ?? "<owner/repo>"}).`,
        "   → Only if that prints a digest DIFFERENT from the record's is a fresh review owed:",
        // ⛔ THREE DEFECTS HAVE LIVED ON THIS ONE LINE, each with its own wrong outcome
        // (reviews, #2353 P1 + round 2 F1):
        //   1. a TRUNCATED sha (`${currentHead.slice(0,12)}…`) LOOKS runnable — the two
        //      lines above ARE literal — and record-review.sh refuses anything short of
        //      40 hex with exit 2, so the advice dead-ended at the moment a lane tried to land;
        //   2. a hardcoded `clean` overrode the TIER: a micro PR was sent to the full
        //      standard review its tier exempts, and a clean-low one was told to re-record at
        //      the same verdict — which the sibling arm at `head_advanced` forbids verbatim,
        //      because that shape must be RE-DERIVED rather than carried forward;
        //   3. `--evidence` was appended unconditionally although only `clean` binds
        //      evidence (clean-micro/clean-low accept it and drop it), promising an artifact
        //      the record would not carry.
        // So the recipe is TIER-AWARE — written once, in `freshReviewAdvice` below, which
        // every "a fresh review is owed" arm shares — and `<head_sha>` is the placeholder
        // every neighbouring arm uses.
        freshReviewAdvice(record.verdict, pr),
      ].join("\n"),
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
        ? `   → The branch moved — the certified diff no longer exists, so the shape must be re-derived: re-check whether the NEW head is still content-only, then re-record with the verdict named explicitly (${RECORD_SH} <PR> <head_sha> clean-low [owner/repo]); if it is no longer content-only, run the code-review skill and record clean (${RECORD_SH} <PR> <head_sha> clean [owner/repo] --evidence comment:<review-comment-id>).`
        : `   → The branch moved — re-review the new head, post its verdict as a PR comment, and re-record at the same verdict: ${RECORD_SH} <PR> <head_sha> ${record.verdict} [owner/repo] ${EVIDENCE_CAVEAT}`;
    // #2349 — name WHICH moved-head state this is and its own remedy. These four
    // failure modes read identically before this: re-record (absent digest), fix the
    // READ and retry (unreadable live digest), re-review (digest mismatch). Only the
    // mismatch means the CONTENT changed.
    const recDigestOk = isDiffSha256(record.diff_sha256);
    const liveDigestOk = isDiffSha256(currentDiffHash);
    const staleState = !recDigestOk
      ? RECORD_STATE_DIGEST_ABSENT
      : currentDiffHash === null
        ? `${RECORD_STATE_LIVE_UNREADABLE}${liveDiffReadReason ? ` (${liveDiffReadReason})` : " (no reason reported)"}`
        : !liveDigestOk
          ? `${RECORD_STATE_LIVE_UNREADABLE} (the read returned a value that is not a full 64-hex digest)`
          : `${RECORD_STATE_DIGEST_MISMATCH} (${String(record.diff_sha256).slice(0, 12)} vs ${currentDiffHash.slice(0, 12)})`;
    const stateRemedy = !recDigestOk
      ? [
          "     → remedy: RE-REVIEW the new head — this record cannot show that the CURRENT diff was",
          "       reviewed at all (a pre-#2982 record carries no content identity, so there is nothing to",
          "       compare and nothing to carry). Then re-record at the head that will merge:",
          `       ${RECORD_SH} <PR> <head_sha> <verdict> [owner/repo]  (--evidence … for clean)`,
          "       ⛔ NOT a substitute: re-recording a `clean-micro`/`clean-low` (which need no --evidence)",
          "         WITHOUT that fresh review would mint a digest for a diff nobody reviewed.",
        ]
      : currentDiffHash === null || !liveDigestOk
        ? [
            "     → remedy: the review is fine — the READ failed. Fix the read, do NOT re-record to work",
            `       around it: \`${RECORD_SH} --print-diff-hash ${pr} ${ctx.repo ?? "owner/repo"}\` reports the same status,`,
            "       then retry the merge.",
          ]
        : [
            "     → remedy: the reviewed CONTENT changed, so this is a genuine RE-REVIEW, not a stale-head",
            "       nuisance — no digest equality is available to carry the verdict.",
          ];
    const recordWhere = observation
      ? [
          `   Record file: ${recordSourcePath(observation)}` +
            (observation.record
              ? observation.qualified.kind === "present"
                ? " (this is the record read)"
                : " (the LEGACY record read — no usable repo-keyed file)"
              : ""),
        ]
      : [];
    return {
      status: "block",
      reason: [
        `❌ PR #${pr} head has advanced since the review was recorded.`,
        `   Recorded: ${oneLine(record.head_sha)}   Current: ${oneLine(currentHead)}`,
        ...recordWhere,
        "   ⟦THE ARM THAT ALLOWS A MOVED HEAD — the four conjuncts below, in source order⟧",
        ...describeCarryConjuncts(record, currentHead, currentDiffHash, liveDiffReadReason),
        `     ⇒ STATE: ${RECORD_STATE_HEAD_STALE} — ${staleState}`,
        ...stateRemedy,
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
          `   →   ${RECORD_SH} <PR> <head_sha> clean-low [owner/repo]`,
          "   → If the diff is no longer content-only, run the code-review skill and record clean:",
          `   →   ${RECORD_SH} <PR> <head_sha> clean [owner/repo] --evidence comment:<review-comment-id>`,
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
          `   →   ${RECORD_SH} <PR> <head_sha> clean-low [owner/repo]`,
          "   → Otherwise run the code-review skill and record clean:",
          `   →   ${RECORD_SH} <PR> <head_sha> clean [owner/repo] --evidence comment:<review-comment-id>`,
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
      {
        pr,
        ...verdict,
        ...(result.status === "failopen" ? { reason: "failopen" } : {}),
        // #1351 — a merge allowed because the reviewed DIFF is unchanged at a
        // moved head is a materially different event from one allowed at a
        // matching head. Without this field the audit trail cannot tell them
        // apart, so a carried merge is unreconstructible from gate-events.jsonl
        // — the opposite of what a content-identity accept should be.
        ...(result.status === "allow" && result.carried ? { carried: true } : {}),
      },
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
 *     outside #930's scope, so this is noted, not fixed;
 *   - #1203 — a command that merely INVOKES the mandated rail is NOT an admin merge
 *     here, because the rail's own filename (`admin-merge.sh`) is neutralized before
 *     every read (`withoutMandatedRailPath`): its two words would otherwise be read
 *     as the flag (`admin`, rule 2) and the verb (`merge`), refusing the gate's own
 *     recommended route. A `--admin` handed to the rail as an ARGUMENT
 *     (`bash …/admin-merge.sh 999 --admin`) therefore stops being read as one — the
 *     rail accepts and drops that flag (`scripts/admin-merge.sh:5193`), computes and
 *     verifies the head-bound evidence itself, and its internal
 *     `gh pr merge --admin` is decided by the argv shim. The literal spelling
 *     (`bash scripts/admin-merge.sh 999 --admin`) was never gated.
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
 *   - OVER-BLOCKS, acceptably and visibly, WHENEVER THIS LAYER IS THE ONE DECIDING —
 *     which is the complement of the deferral: no usable argv-level shim, OR the
 *     command carries a literal `--admin`, OR the text names a merge. Under that
 *     condition a `gh pr merge` carrying a construct (a `$`, backtick or brace) AND the
 *     word `admin` is refused unless it has head-bound evidence — including a harmless
 *     `echo "gh pr merge 1
 *     --admin=true"` (a literal flag), and a `--body "ask the admin"` beside a `$VAR`
 *     (the text names a merge). What is DEFERRED is only the over-read that mentions
 *     `admin` under a construct with NO merge in it (`ghShimWillEnforce` +
 *     `mergeVerbInText`). The remedy for the block is the mandated
 *     `scripts/admin-merge.sh`; the alternative was a bypass.
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
  //    #1203: the mandated rail's own path is neutralized first — its filename is
  //    `admin-merge.sh`, and reading that as the flag/verb it is not is what refused
  //    the gate's own recommended route in a loop or beside another `gh` call.
  //    `normalizeForFlagScan` neutralizes too (idempotent), so the probe and the raw
  //    reads below cannot disagree about the same command.
  const cmd = withoutMandatedRailPath(command);
  const probe = normalizeForFlagScan(cmd);
  // 2. Fail CLOSED on what we cannot resolve. Guessing here is what produced
  //    seven rounds of fail-opens, so the rule is "unresolvable ⇒ admin merge".
  //    (a) ANSI-C quoting, or a `$`/backtick inside a literal `--` token;
  if (isUnresolvableFlagToken(cmd, probe)) return true;
  //    (b) a construct that could ASSEMBLE the flag — the dashes included. VGATE
  //    round 7: `-${V:--}admin=true`, `$V-admin=true` and
  //    `-$(printf %s '-')admin=true` all reach gh as `--admin=true`, and a rule
  //    anchored on a literal `--` misses every one. Keying on the CONSTRUCT plus
  //    the word `admin` (rather than on a dash position) is what closes the
  //    family; it is narrow in the direction that matters, because a construct
  //    WITHOUT the word `admin` — e.g. the common `gh pr merge "$PR" --squash` —
  //    is untouched.
  if (hasUnresolvableConstruct(cmd) && /admin/i.test(cmd)) return true;
  // 3. The literal flag — the DECISIVE read (see `hasLiteralAdminFlag`).
  return literalAdminFlagIn(probe);
}

/**
 * Does the command carry `--admin` as a LITERAL token — i.e. is the admin flag
 * readable from the text WITHOUT resolving a shell? (#1776)
 *
 * This is the polarity split the CALLER needs: `hasAdminMergeFlag` answers "is
 * this an admin merge?" as `unresolvable ⇒ YES` (parts 1-2, fail-closed guesses),
 * and a guess is not something the text layer can hand to a PR number, a head
 * lookup, or an evidence check — a guess is what refused an ordinary `gh pr
 * create` whose TITLE contained the word `admin` (agent-infra#1775). So the caller
 * asks this instead: a LITERAL `--admin` is a read that needs no resolution, and
 * the text layer keeps the decision for it even when the argv layer exists.
 *
 * Quote-splices are resolved by `normalizeForFlagScan` (`--ad""min` → `--admin`),
 * so they count as literal; `$VAR`/backtick/ANSI-C spellings do not.
 *
 * ACCEPTED RESIDUAL — this read is position-blind, so a quoted `--admin` that is not
 * an argument of any merge, in a command the guess arm has ALREADY made a candidate
 * (`gh pr create --title "fix(admin-merge): x" --body-file "$(mktemp)"`), keeps the
 * text-layer decision and is refused by the evidence gate for having no resolvable
 * PR number. Without a construct, the guess arm does not fire and the command is not
 * gated at all. That is a false block, it is deliberate, and it is the price of the
 * decisive half: the alternative is a spelling rule about where a token may sit, which
 * is the scanner trap this design abandons. The escape is SESSION-level, not per
 * command: the override is read from this extension's own environment, so a lane
 * recovering from this false block must start the session with
 * `AGENT_ADMIN_MERGE_OVERRIDE=1` (or the `ELDATO_` alias) — it is audited as
 * `admin_merge_override`. It is narrower than the guess it replaced.
 */
export function hasLiteralAdminFlag(command: string): boolean {
  return literalAdminFlagIn(normalizeForFlagScan(command));
}

/** The literal flag inside an already-normalized probe (see `hasAdminMergeFlag`). */
function literalAdminFlagIn(probe: string): boolean {
  // Token-anchored: `--admin` must be a WHOLE flag. A `--adminx` typo is not a
  // bypass (gh rejects it as an unknown flag), and refusing it would be exactly the
  // false block this rail must not produce. `=` may carry a Go-false value;
  // anything else is a bypass (see GO_FALSE).
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
 *
 * COUNTED FROM INVOCATIONS, NOT FROM TEXT (#1485). The pre-fix rule was
 * "if the command contains any `$`/backtick/brace, count EVERY `gh` word", which
 * is what closed the spliced-verb family — and what refused two read-only
 * `gh run view` calls ("This command contains more than one `gh pr merge`")
 * because a `grep -viE "^\s*$"` elsewhere supplied the construct. A word is now
 * counted only when the verb it selects can be a MERGE:
 *
 *   1. the word reads `gh` (quote/ANSI-C splices resolved), or is construct-bearing
 *      where the command word belongs — then
 *   2. the next word reads `pr`, or is construct-bearing (a spliced `pr`), and
 *   3. the word after that reads `merge`, or is construct-bearing (a spliced verb),
 *      or is NOT a readable subcommand word at all (the residue left by the
 *      repo-flag stripper: `gh pr x) merge 999`).
 *
 * A word in POSITION 2 that reads a real non-merge subcommand (`gh run view`,
 * `gh api …`, `gh pr view/list/checks`) makes the invocation provably NOT a
 * merge — the only reading this function is allowed to be precise about, because
 * no `gh` subcommand other than `pr merge` can merge a PR. Everything unreadable
 * still counts, so the fail-closed direction is unchanged.
 *
 * Tokens wholly inside a quoted DATA region are skipped (`dataCharMask`), so a
 * mention in a jq filter, a grep pattern, a PR body or an interpreter payload is
 * not an invocation; `sh -c`/`eval`/`trap` payloads and a fully-quoted command
 * name stay readable, which is what keeps those real merges counted.
 */
export function countMergeVerbs(command: string): number {
  // This MUST use the same recognizer the gate uses (`isGhWordAt` … here, the
  // same `shellWord`/`CONSTRUCT` reads), not a second regex. Cycle-2 review: a
  // regex here counted 1 for
  // `gh pr merge 111 --admin; sh -c 'gh pr merge 999 --admin'` — the second verb
  // is wrapped, so it did not match — the `> 1` fail-closed guard was skipped and
  // 999 merged unevidenced. Two disagreeing predicates is the exact failure this
  // file keeps re-learning (VGATE round 9), so the count walks the same tokens.
  const scan = scanTokens(command);
  const data = dataCharMask(scan);
  const isData = (i: number) => isDataToken(scan, data, i);
  const nextReadable = (i: number): number => {
    let k = i;
    while (k < scan.tokens.length && isData(k)) k++; // a data run is not an argv slot
    return k;
  };
  let n = 0;
  for (let i = 0; i < scan.tokens.length; i++) {
    if (isData(i)) continue;
    const word = shellWord(scan.tokens[i]);
    // 1. the gh word: readable as `gh`, or a construct where the command word
    // belongs (`$G pr merge 999`, `$'gh' pr merge 999`).
    if (word !== "gh" && !CONSTRUCT.test(scan.tokens[i])) continue;
    const ai = nextReadable(i + 1);
    const bi = nextReadable(ai + 1);
    if (ai >= scan.tokens.length) continue;
    const aTok = scan.tokens[ai];
    const a = shellWord(aTok);
    // 2. the group: `pr`, or a spliced one (`gh p$'r' merge`, `gh ${X}pr merge`).
    if (a !== "pr" && !CONSTRUCT.test(aTok)) continue;
    if (bi >= scan.tokens.length) continue;
    const bTok = scan.tokens[bi];
    const b = shellWord(bTok);
    // 3. the verb: `merge`, a spliced one (`gh pr $'merge'`, `gh pr ${X}merge`),
    // a residue that is no subcommand at all (`gh pr x) merge 999`, the repo-flag
    // stripper's leftovers), or a readable word that is simply not a subcommand
    // and is followed by `merge` (`gh pr x merge 999` — the same residue split by
    // a `)`). A construct at the GROUP position already ends the window: the
    // tokens of one brace expansion are not three invocations.
    const nextAfterB = scan.tokens[nextReadable(bi + 1)];
    const isMerge =
      b === "merge" ||
      CONSTRUCT.test(bTok) ||
      (a === "pr" && (!SUBCOMMAND_WORD.test(b) || shellWord(nextAfterB ?? "") === "merge"));
    if (!isMerge) continue;
    n++;
    // One window per invocation: without this, the tokens of a splice
    // (`gh ${X}pr merge` → `gh`, `$`, `X}pr`, `merge`) each open their own
    // window and one merge is counted two or three times — an over-count that
    // would refuse a SINGLE admin merge as "more than one".
    i = bi;
  }
  return n;
}

export function extractMergePrNumber(command: string): number | null {
  return extractMergeSelector(command).pr;
}

/** gh flags that take a VALUE and may sit before the group (`pr`): a global flag does
 * not make the group readable, and its value is not the group. Mirrors the shim's and
 * `extractMergeSelector`'s value list for the two flags gh accepts BEFORE the group. */
const GLOBAL_VALUE_FLAGS = new Set(["-R", "--repo", "-A", "--hostname"]);

/** A word with a shell ASSIGNMENT prefix removed (`CMD+=gh` → `gh`, `P=pr` → `pr`).
 * A verb assembled by appends (`CMD+=gh CMD+=' ' CMD+=pr …`) puts no token that IS the
 * word in the stream, and bash still runs `gh pr merge` — measured as a real bypass. */
function withoutAssignmentPrefix(word: string): string {
  return word.replace(/^[A-Za-z_][A-Za-z0-9_]*\+?=/, "");
}

/**
 * Is `scan.tokens[i]` a word that can BE the `gh` command word — readable (`gh`, `"gh"`), or a
 * construct where a command word belongs (`g$'h'`, `$GH`, `$'gh'`, `${GH}`)?
 *
 * ⛔ THE HARD PART IS WHAT IS *NOT* A WORD. `CONSTRUCT` is a character class (`[$`{}<>]`), so it
 * accepts RESIDUE: a heredoc's `<<'EOF'`, the `<` that `<!--` splits into, the `head}` tail of
 * `${head}`, the `-->` that closes an HTML marker. Reading those as the `gh` command word made a
 * heredoc that WRITES this gate's own evidence marker (`cat > f <<'EOF' … <!-- admin-merge-
 * safety: ${head} --> … EOF`) a REFUSED read-only command — measured in review cycle 4;
 * `origin/main` admits it. So a construct is accepted only when it CARRIES ITS INTRODUCER
 * (`$…`, a backtick, `{…}`), and the one residue that IS a word — the tail of a split `${X}`,
 * i.e. the tokens `$` + `X}` — is accepted only where the `${` itself begins a simple command.
 *
 * ⛔ NOT POSITION-GATED otherwise, deliberately: a wrapper's arguments put the command word out
 * of the position model's reach, and requiring command position lost 168 real admin merges
 * (`timeout 5 g$'h' $'pr' "merge" 999 --admin`) that `origin/main` refuses.
 */
function isGhCommandWordAt(scan: ScanTokens, i: number): boolean {
  const raw = scan.tokens[i];
  const w = shellWord(raw);
  // A BARE `$` is never a command word: `${RAIL}` tokenizes to `$` + `RAIL}`, and reading the `$`
  // as the command and `RAIL}` as its group made `bash ${RAIL} 999` a merge candidate — it would
  // have re-created #6395's refusal of the mandated rail.
  if (w === "") return false;
  if (w === "gh") return true;
  // A construct that CARRIES ITS INTRODUCER: `$GH`, `$'gh'`, `g$'h'`, `x${X}`, or a backtick.
  // Position does not matter — a wrapper's arguments put the command word out of the position
  // model's reach (`timeout 5 g$'h' $'pr' "merge" 999 --admin`, measured: position-gating this
  // lost 168 real admin merges that `origin/main` refuses).
  if (/[$`]/.test(raw)) return true;
  // A BRACE-EXPANSION word (`{pr,merge}`) is a construct too.
  if (/^\w*\{/.test(raw)) return true;
  // The ONE residue that IS a word: the TAIL of a split `${X}` (tokens `$` + `X}`), and only when
  // the `${` ITSELF begins a simple command — `GH=gh; ${GH} ${P} merge 999 --admin` is a real
  // merge `origin/main` refuses. Command position read at the TAIL is not usable: it is true for
  // a same-shaped `${head}` mid-line in a heredoc body, because the `{` of `${` reads as a group
  // separator to the gap test. The `${` token is where the word starts, so that is the token the
  // position is read at.
  if (!/^\w*\}$/.test(raw)) return false;
  if (i === 0 || scan.tokens[i - 1] !== "$") return false;
  return isCommandPositionAt(scan, i - 1);
}

/**
 * Does the command carry a `gh` command word — readable, or constructed (`g$'h'`, `$GH`)?
 *
 * NOT position-gated: this question is only ever asked TOGETHER with something else that is
 * already narrow (a merge-verb window, or a top-level `ghGroupIsUnreadable` that does its own
 * position test), and a wrapper's arguments put the command word out of the position model's
 * reach — position-gating it lost 168 real admin merges (`timeout 5 g$'h' $'pr' "merge" 999
 * --admin`) that `origin/main` refuses.
 */
export function hasGhCommandWord(command: string): boolean {
  const scan = scanTokens(command);
  for (let i = 0; i < scan.tokens.length; i++) {
    if (isGhCommandWordAt(scan, i)) return true;
  }
  return false;
}

/**
 * Is the GROUP slot of some `gh` command word itself UNREADABLE — a construct, where `pr` (or the
 * whole verb) would have to be, possibly behind a global flag?
 *
 * `V="pr merge"; gh $V 999 --admin` reaches gh as `gh pr merge 999 --admin` while this scanner
 * can see no verb at all, so this is the fail-closed floor under `mergeInvocationInText`. It is
 * deliberately slot-SCOPED rather than the old "a `gh` word appears anywhere" test: a readable
 * group (`gh api …`, `gh issue list …`) is not a merge and must not be read as one
 * (agent-infra#3953).
 */
function ghGroupIsUnreadable(command: string): boolean {
  const scan = scanTokens(command);
  for (let i = 0; i < scan.tokens.length; i++) {
    const w = shellWord(scan.tokens[i]);
    if (!isCommandPositionAt(scan, i)) continue;
    if (!isGhCommandWordAt(scan, i)) continue;
    let j = i + 1;
    while (j < scan.tokens.length && GLOBAL_VALUE_FLAGS.has(shellWord(scan.tokens[j]))) j += 2;
    if (j >= scan.tokens.length) continue;
    if (CONSTRUCT.test(scan.tokens[j])) {
      // ⛔ A construct in the GROUP slot only pays for itself behind a READABLE `gh`. Behind a
      // construct COMMAND word it degenerates into "two constructs and the word `admin`", the
      // vocabulary guess this predicate replaces: `bash $AIR/scripts/verify-admin-merge-
      // evidence.sh "$PR"`, `$PY $SCRIPT --check-admin-policy`, `$JQ "$F" --arg admin x` are
      // read-only and were refused as unevidenced admin merges (cycle-3 review, P1, measured).
      // The one thing that makes a construct-construct command a REAL merge is the verb: bash
      // hands gh `<group> merge <n> <flag>`, so require the merged word after the group slot.
      // Measured payload: `GH=gh; g$'h' $P "merge" 999 --admin`, `GH=gh; $GH $P 'merge' 999
      // --admin` (the `GH=gh` assignment is what makes origin/main read them, and a narrowing
      // that dropped them would be a fail-open against the base).
      if (w === "gh") return true;
      const verb = j + 1 < scan.tokens.length ? shellWord(scan.tokens[j + 1]) : "";
      if (verb === "merge") return true;
      continue;
    }
  }
  return false;
}

/**
 * Is there a `gh` … `pr` … `merge` WORD SEQUENCE in the token stream, allowing an ASSIGNMENT
 * prefix on each word?
 *
 * The third fail-closed fallback, for the spellings where the verb is present but glued to an
 * assignment so no token equals `gh`: measured `X='gh pr merge 999 --admin'; sh -c "$X"` produces
 * the token `X=gh`, and `CMD+=gh CMD+=' ' CMD+=pr … CMD+=merge` produces one assignment per word
 * — both were ALLOWED by the exact-word walk while the shell would run a real admin merge (a
 * fail-open; the base refused them).
 *
 * Two orderings are OR-ed, and the reason is measured. At the group stage a CONSTRUCT is
 * ambiguous: it can be the GROUP slot of an all-assembled invocation (`GH=gh; ${GH} ${P} $M 999
 * --admin`) or a fresh COMMAND word (`GH=gh; g$'h' "pr" merge 999 --admin`, where the `GH=gh`
 * assignment already opened the group stage). A single ordering loses one of the two — measured:
 * group-first lost 88 real admin merges that `origin/main` refuses, command-first lost 128. Both
 * orderings only ADD candidates, so OR-ing cannot widen the rule in a direction the other does
 * not already reach.
 */
function mergeVerbSequenceInTokens(command: string): boolean {
  return mergeVerbWalk(command, true) || mergeVerbWalk(command, false);
}

/**
 * The walk. `groupFirst` decides which reading wins for a construct at the group stage.
 *
 * ⛔ THE WORD TESTS ARE WHAT BOUND IT, NOT DISTANCE. A construct only counts as a word if it is
 * not a REDIRECTION (`2>/dev/null`, `> file`, `2>&1`, `<<<`), not a `-`-leading flag (read from the
 * DEQUOTED word, so `$'--dry-run'` is a flag), and not shell punctuation. A heredoc writing
 * `<!-- admin-merge-safety: ${head} -->` therefore has no reachable `gh`→group→verb triple: its
 * `<`, `<<'EOF'` and `-->` tokens are all excluded, and what remains (`head}`) cannot complete a
 * sequence — `origin/main` admits that heredoc, and the arms that refused it are the ones this PR
 * narrows (measured, review cycles 4 and 5). An intermediate ADJACENCY bound was removed once
 * these tests were in place: measured redundant on the whole corpus.
 */
function mergeVerbWalk(command: string, groupFirst: boolean): boolean {
  const scan = scanTokens(command);
  // 0: looking for the command word, 1: for `pr`, 2: for `merge`.
  let stage = 0;
  for (let i = 0; i < scan.tokens.length; i++) {
    const raw = scan.tokens[i];
    const w = shellWord(raw);
    const verbWord = withoutAssignmentPrefix(w);
    // The command word is `gh`, OR a construct where a command word belongs (`g$'h'`, `$GH`,
    // `X='gh pr merge 9'`, `CMD+=gh`). ⛔ OMITTING THE CONSTRUCT CASE WAS THE CYCLE-2 P0: bash
    // resolves `g$'h' "pr" merge 999 --admin` to `gh pr merge 999 --admin`, and with only a
    // literal `gh` accepted NO arm matched — the quoted `"pr"` is DATA to the data-aware count
    // whenever the simple command's first word is not literally `gh`, the group-slot arm wants a
    // construct in the GROUP, and this walk wanted the word `gh` in the COMMAND slot. Measured
    // across 1 500 generated inputs: 244 real admin merges fell through that one combination.
    // NOT position-gated, deliberately: `timeout 5 g$'h' "pr" merge …` and `sudo $GH "pr" merge
    // …` put the command word behind a WRAPPER's arguments, which the position model does not
    // resolve, and requiring command position there re-opened the same hole one wrapper deeper
    // (measured). A bare `$` is excluded, so `${RAIL}` (which tokenizes to `$` + `RAIL}`) cannot
    // be read as a command word.
    // A LEADING DASH MEANS A FLAG, NOT A WORD -- and it has to be read from the DEQUOTED word:
    // `$'--dry-run'` does not start with `-` as a RAW token, but bash hands gh a flag, so reading
    // the raw text only made `$PYTHON $SCRIPT $'--dry-run'` a three-construct "merge" (measured).
    // ⛔ A REDIRECTION IS NOT A VERB EITHER (review cycle 5, P1). `CONSTRUCT` lists `<`/`>` among
    // the shell metacharacters, so `2>/dev/null`, `>/tmp/out`, `2>&1` and `<<<` all qualified as
    // construct words -- and an adjacent construct at the verb stage returned true, so appending
    // ONE redirect to a read-only command made it a candidate:
    // `bash $AIR/scripts/verify-admin-merge-evidence.sh "$PR" 2>/dev/null` and
    // `jq --arg admin "$X" "$F" > /tmp/out` are refused at the cycle-4 head and admitted at
    // origin/main (measured) -- the cycle-3 over-block, re-opened one token over.
    const isConstructWord =
      CONSTRUCT.test(raw) &&
      w !== "" &&
      !w.startsWith("-") &&
      !raw.startsWith("-") &&
      !/^\d*[<>]/.test(raw) &&
      !/^&>>?/.test(raw) &&
      !/^[|&;()]+$/.test(raw);
    const isCommandWord = /\bgh\b/.test(w) || isConstructWord;
    if (stage === 2) {
      if (verbWord === "merge") return true;
      if (isConstructWord) return true;
      // A pure-whitespace assignment (`CMD+=' '`) is a SEPARATOR being assembled, not a verb
      // slot: skipping it is what lets `CMD+=gh CMD+=' ' CMD+=pr CMD+=' ' CMD+=merge` read as
      // one invocation (measured as a real bypass).
      if (verbWord.trim() === "") continue;
      // A word in the verb slot that is not the verb restarts the walk (a command word here can
      // begin a fresh sequence; anything else drops back to looking for one).
      stage = isCommandWord ? 1 : 0;
      continue;
    }
    if (stage === 1) {
      if (verbWord === "pr" || (groupFirst && isConstructWord)) {
        stage = 2;
        continue;
      }
    }
    if (isCommandWord) stage = 1;
  }
  return false;
}

/**
 * Could an ANSI-C quote be encoding a SEPARATOR — i.e. is the token structure of this
 * command not recoverable from the text?
 *
 * `sh -c gh$'\x20'pr$'\x20'merge$'\x20'999$'\x20'$V` is ONE whitespace-delimited token to
 * any reader that does not decode `\x20`, and a real `gh pr merge 999 --admin` to bash. Three
 * such spellings were measured as live bypasses of both layers when the surrounding rule
 * narrowed (the `$'\x20'` family, agent-infra#1425/#1776). Where the separators are not
 * recoverable, `mergeInvocationInText` falls back to the WORDS read — the same
 * over-approximation the #3953 narrowing removed elsewhere, kept here because here the
 * alternative is a fail-open, not a false block.
 */
function ansiCEncodesSeparator(command: string): boolean {
  return /\$'[^']*\\(?:x[0-9a-fA-F]{2}|[0-7]{1,3}|u[0-9a-fA-F]{2,4}|U[0-9a-fA-F]{4,8}|[tnrvf])/.test(
    command,
  );
}

/**
 * Does this command INVOKE a merge — the OPERATION, not the word? (agent-infra#3953)
 *
 * This is the candidate rule's argv-position read. The defect it closes is one line of
 * `isAdminMergeCommand`'s old over-approximation, which answered "is this an admin
 * merge?" with *"does the text contain the word `gh`, or the words `pr` AND `merge`?"*
 * once a construct and the word `admin` were present. A read-only command that merely
 * NAMES a merge therefore became a merge it had to certify:
 *
 *   gh api repos/o/r/branches/main/protection --jq '{enforce_admins: .enforce_admins}'
 *   cat > /tmp/x.mjs <<'EOF' … `gh api "…/check-runs?filter=all"` … probes['hasAdminMergeFlag'] …
 *
 * The `{}` / backticks supply the construct and `admin` supplies the word, so both were
 * refused with "no resolvable PR number" — a block on the very `check-runs` read the
 * fleet rules MANDATE for answering "is the tree healthy".
 *
 * The replacement asks for a merge VERB in argv POSITION, and nothing weaker:
 *   - the verb spelled (or spliced) in the argument list the shell will run — the token walk
 *     in `countMergeVerbs`, REUSED rather than re-implemented, because two predicates for
 *     "is this a merge" is the failure this file keeps re-learning. That walk is DATA-AWARE,
 *     so a verb inside plain quoted data (`echo 'gh pr merge 9'`) is not an invocation —
 *     while a payload handed to `sh -c`/`eval`/`trap` stays readable and still counts;
 *   - a `gh` whose GROUP slot is unreadable still counts (`V="pr merge"; gh $V 999 --admin`,
 *     `gh --hostname … $X 999 --admin`), because there the verb is not in the text at all;
 *   - a verb ASSEMBLED with assignments still counts (`CMD+=gh CMD+=pr CMD+=merge`,
 *     `X='gh pr merge 999 --admin'; sh -c "$X"`), where no token IS the word `gh`, and so
 *     does an assembled COMMAND word (`g$'h' "pr" merge 999 --admin`, `$GH "pr" merge …`);
 *   - ANYTHING `mergeVerbInText` names is a merge here too. That read is the caller's own,
 *     and it is quote-blind where this walk is data-aware, so it catches the construct in a
 *     VERB position behind a merely-quoted group word — a measured fail-open for the arms
 *     above (`M=merge; gh "pr" $M 999 --admin`, and the same inside `if`/`while`/`timeout`).
 *     The invariant is one-directional and pinned: `mergeVerbInText(c)` ⇒ this is true;
 *   - where the separators are ANSI-C escapes (`gh$'\x20'pr …`) the token structure is not
 *     recoverable, so it falls back to the WORDS read — an over-block kept deliberately,
 *     because the alternative there is a fail-open.
 *
 * WHAT IT DELIBERATELY NO LONGER COUNTS, and why that cannot merge anything: a construct
 * plus the word `admin` in a command whose `gh` calls are all READABLE NON-MERGE calls
 * (`gh api …`, `gh issue …`, `gh pr view …`). No `gh` subcommand other than `pr merge`
 * merges a PR, so a command with no merge verb in argv position cannot perform one; the
 * placeholder that used to stand in for that signal was the word `gh`, which is a
 * property of the VOCABULARY rather than of the operation.
 *
 * NOT NARROWED HERE (declared, not overlooked):
 *   - the LITERAL `--admin` arm stays exactly as wide as it was — a command carrying the
 *     flag AND a readable `gh pr merge` keeps the text layer's decision
 *     (`hasLiteralAdminFlag`);
 *   - a `--json`/`--search` value that spells a WHITESPACE-SEPARATED, UNQUOTED `pr` then
 *     `merge` word pair (`gh pr view 1 --json pr merge`, `gh issue list --search pr merge`)
 *     is still read as a verb pair, because at that point the text is indistinguishable from
 *     an invocation without an argv layer. That residual is an OVER-BLOCK — the direction this
 *     gate is allowed to be wrong in — and it is strictly narrower than the "any `gh` word"
 *     rule it replaces. ⛔ The QUOTED spelling is NOT affected and must not be cited as the
 *     example: `gh pr view 1 --jq 'pr merge'` is DATA (measured — `--jq` is a value-position
 *     flag, so the mask covers both words and this function answers false; review cycle 5, P2).
 *     A single token that merely contains both words (`--jq .merge`, `--json pr,merge`,
 *     `mergeStateStatus`, `hasAdminMergeFlag`) is likewise not a word pair and is admitted.
 */
export function mergeInvocationInText(command: string): boolean {
  // Same two normalizations the caller's own reads use: the rail's basename is not a
  // verb (`admin-merge.sh`), and a repo flag's value is not a verb (`gh -R pr merge 9`).
  const bare = stripRepoArgs(withoutMandatedRailPath(command));
  // The DATA-AWARE count, deliberately: an `sh -c`/`eval`/`trap` payload stays readable
  // through the mask (that is what keeps a wrapped verb an invocation), while a verb inside
  // plain quoted data is not COUNTED here. A data-insensitive count was measured to add no
  // coverage — every payload spelling it catches is already readable — and only widened the
  // rule onto `echo`.
  // ⛔ One arm below is DELIBERATELY quote-blind, so this FUNCTION can still answer true for
  // quoted data: `echo 'gh pr merge 9'` is not counted here (the count masks quoted data) but
  // the SEQUENCE WALK (arm 3) reads the words anyway, so this function answers true. That is
  // the fail-closed direction and it is accepted, not overlooked — a quoted MENTION of a merge
  // costs, at most, a resolvable PR number, while a missed INVOCATION costs the bypass. It is
  // NOT simply "a candidate at origin/main": with no CONSTRUCT in the text the caller takes its
  // readable-text branch, which requires a BARE `gh` word (`hasBareGhWord`) and a quoted mention
  // supplies none — so the end-to-end predicate stays false for a quote-only spelling (measured:
  // `echo 'gh pr merge 9 --admin'` has `hasAdminMergeFlag` true and is still false at
  // origin/main AND false here, while this function is true).
  // What must never vary is the ARM you are reading: the count is data-aware, the sequence
  // walk is quote-blind.
  // The shared count, tied to two other reads. On its own it is too blunt to be the candidate
  // rule: it walks constructs ANYWHERE, so a heredoc that WRITES this gate's own evidence marker
  // (`cat > f <<'EOF'` ... `<!-- admin-merge-safety: ${head} -->` ... `EOF`) counts as one merge
  // there (`countMergeVerbs` is 1, unchanged by this PR) while `origin/main` admits it. So the
  // window only counts when the command ALSO carries a `gh` command word (`hasGhCommandWord`,
  // NOT position-gated: a wrapper's arguments hide the position) AND the word `merge`
  // (`MERGE_WORD`, so a hyphenated identifier does not count). Measured with this gate removed:
  // that heredoc and the bare marker fragment became REFUSED read-only commands -- the exact
  // class #3953 is about.
  if (countMergeVerbs(bare) > 0 && hasGhCommandWord(bare) && MERGE_WORD.test(bare)) return true;
  if (ghGroupIsUnreadable(bare)) return true;
  if (mergeVerbSequenceInTokens(bare)) return true;
  // ⛔ NO DIVERGENCE FROM THE OTHER MERGE-READ (review cycle 1, P0). `mergeVerbInText` is
  // the read the CALLER's own condition uses (`hasLiteralAdminFlag || mergeVerbInText ||
  // !readsNonMergeGhCall`), and it is quote-BLIND where this walk is data-aware: it
  // recognises a construct sitting in a VERB position right after a bare `gh` or `pr` word.
  // Measured fail-open without this arm — bash hands gh `pr merge 999 --admin`, the base
  // refused it, and every arm above missed it because the GROUP word was merely QUOTED
  // (`"pr"` is not a CONSTRUCT) and the verb was a variable:
  //
  //   M=merge; GH_TOKEN=abc gh "pr" $M 99900010 --admin
  //   if true; then gh "pr" m$'e'rge 99900010 --admin; fi
  //   timeout 5 gh "pr" m$'e'rge 99900010 --admin
  //
  // `countMergeVerbs` skips the quoted `"pr"` as DATA whenever the simple command's first
  // word is not `gh` (an assignment prefix, a reserved word, a wrapper), so the verb window
  // never closes — while `mergeVerbInText` DOES name a merge for all of them. Two predicates
  // for "is this a merge" disagreeing is the failure this file keeps re-learning, so the
  // candidate rule is made a SUPERSET of that read rather than a second opinion beside it.
  // SCOPED PRECISELY: the pinned invariant is `mergeVerbInText(c) ⇒ mergeInvocationInText(c)`.
  // `isAdminMergeCommand` is a DIFFERENT (narrower) question — it also requires
  // `hasAdminMergeFlag`, so `gh pr merge 999` (no flag anywhere) is a merge this rule sees and
  // the ADMIN-merge gate does not, which is correct and is how the registry gate gets it.
  if (mergeVerbInText(bare)) return true;
  // The separators are not recoverable from the text, so the token arms above are not a
  // read of this command: refuse on the WORDS read, which is what the pre-#3953 rule did.
  if (ansiCEncodesSeparator(bare)) {
    const probe = normalizeForFlagScan(bare);
    return (
      /(^|[^\w])gh\b/.test(probe) ||
      (/(^|[^\w])pr\b/.test(probe) && /(^|[^\w])merge\b/.test(probe))
    );
  }
  return false;
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
 * Is `body` a CERTIFYING evidence comment for the revision `currentHead`?
 *
 * The second argument is the CURRENT head being merged — never the sha read out of the
 * marker. A caller that passed the marker's own value would make the verifier's
 * head-bound clauses self-satisfying (every comment reaching this function contains
 * that marker by construction); see the note inside for the reproduced bypass.
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
/**
 * The NEGATIVE CONTROL run against the delegate before it is trusted.
 *
 * It asserts the one invariant EVERY revision of this contract has honoured —
 * in the current spelling, in the retired `unique to this PR: 0` spelling, and
 * in any faithful future one: a body whose residual is NON-ZERO can never
 * certify. The probe is therefore contract-VERSION-agnostic: it does not name a
 * clause, so it cannot go stale the way a hand-written fixture does, and an
 * older-or-newer honest script passes it.
 *
 * It returns true only when the delegate REFUSED the probe. A script that exits 0 for
 * it — a no-op or stub install that would answer "certifying" to everything — is not
 * delegated to, and the merge is refused.
 *
 * STATED LIMIT, and it is stated because the first draft of this change claimed the
 * opposite: this is a guard against a BROKEN delegate, NOT a defence against a
 * HOSTILE one. The probe is distinguishable from outside — a fixed all-zero head and a
 * recognisable filename — so a delegate that refuses only the probe passes it, and no
 * black-box question can establish "is a contract". A fresh-context review defeated
 * the first draft exactly that way. The hostile case is handled where it can be:
 * by resolving the path from this file's own location, with no environment seam.
 */
function verifierRefusesNonZeroBody(verifier: string): boolean {
  const head = "0".repeat(40);
  const probe =
    "<!-- admin-merge-safety: " + head + " -->\nPR head: " + head +
    "\nmain compared (union of 1 run of python-ci.yml): s1:1" +
    "\nPR failing: 1 | main failing: 0 | blocked by the decision: 1" +
    "\nAttribution — FAILED tokens DROPPED by the parser (not test ids, so NEVER in a failing set): PR=0 | main=0.\n";
  let tmp: string | null = null;
  try {
    tmp = resolvePath(os.tmpdir(), `pi-admin-merge-probe-${process.pid}-${Date.now()}.md`);
    fs.writeFileSync(tmp, probe, "utf8");
    execFileSync("bash", [verifier, "--body-file", tmp, "--head", head], {
      stdio: "ignore",
      timeout: 15_000,
    });
    // Exit 0: it certified a NON-ZERO residual. No honest contract revision does.
    return false;
  } catch {
    // Non-zero exit — it refused, which is exactly what an honest delegate does.
    return true;
  } finally {
    if (tmp !== null) {
      try {
        fs.unlinkSync(tmp);
      } catch {
        /* best effort — a leftover temp file must not change the verdict */
      }
    }
  }
}

/**
 * Resolve the ONE implementation of the certificate contract, or null when it is
 * not installed.
 *
 * THE PATH IS DERIVED FROM THIS FILE'S OWN LOCATION AND FROM NOTHING ELSE. There is
 * deliberately no environment seam, and that is the shim's own settled answer to this
 * exact class: `scripts/gh-shim/gh` carries the comment "NO override: this path is
 * derived from the script's own location, so a caller cannot redirect the check at a
 * file of its choosing" — written after an earlier `AGENT_GH_SHIM_VERIFY` seam was
 * reachable IN PRODUCTION, where `AGENT_GH_SHIM_VERIFY=/dev/null` made the check exit
 * 0 and an unevidenced admin merge proceeded with no announcement.
 *
 * An earlier draft of this delegation resolved the script from the shim's tree
 * (`resolveGhShimDir()`, which prefers `AGENT_GH_SHIM_DIR`) and tried to compensate
 * with a probe; a fresh-context review showed a probe cannot be a trust boundary. The
 * seam is closed rather than compensated for.
 *
 * Symlinks ARE followed (via `realpathSync`), because the extension is installed as
 * one: `~/.pi/agent/extensions/review-enforcer` and
 * `pi-bootstrap/pi-config/extensions/review-enforcer` are both symlinks into the
 * checkout, so the path it is LOADED by is not the tree the script lives in — while
 * `../..` from the real directory is.
 */
export function resolveAdminMergeEvidenceVerifier(): string | null {
  const roots: string[] = [];
  if (EXTENSION_DIR) {
    try {
      roots.push(fs.realpathSync(EXTENSION_DIR));
    } catch {
      /* an unresolvable extension dir is simply no candidate */
    }
    // Also try the load path unresolved: harmless, and it keeps a NON-symlinked
    // install working if realpath is unavailable for any reason.
    roots.push(EXTENSION_DIR);
  }
  for (const root of roots) {
    const candidate = resolvePath(root, "..", "..", "scripts", "verify-admin-merge-evidence.sh");
    try {
      if (fs.existsSync(candidate)) return candidate;
    } catch {
      /* an unreadable candidate is not a match */
    }
  }
  return null;
}

export function evidenceBodyIsCertifying(body: string, currentHead: string): boolean {
  // #1388 clause 6 — SINGLE SOURCE, and this is the fix for the six-day outage.
  //
  // This function used to re-implement the clause set as its own regexes. That
  // made TWO implementations of one contract, and on 2026-09-17 `bcbb7df`
  // (#3756/PR #1147) renamed the producer's residual clause in four places
  // (`unique to this PR: 0` -> `blocked by the decision: 0`). The shim's
  // verifier kept requiring the old name; this file kept its own copy of the
  // same stale regex. Neither was caught, because every suite pinned HAND-WRITTEN
  // fixtures — a fixture does not notice that the producer moved. Every admin
  // merge fleet-wide was then refused, and the rail retracted over its own
  // evidence.
  //
  // So the predicate is not restated here. The one implementation is
  // `scripts/verify-admin-merge-evidence.sh`, which is also what the `gh` shim
  // calls (`scripts/gh-shim/gh`), and this gate now asks it the same question.
  // Delegating rather than mirroring is the difference between fixing the clause
  // once and fixing it twice — and drift between two copies is what caused this.
  //
  // FAIL CLOSED on every failure below: a gate that cannot run its check must
  // block, never allow. That is why a missing script or a missing `jq` refuses
  // the merge instead of silently certifying it.
  // THE HEAD PASSED HERE IS THE CURRENT HEAD, NOT THE MARKER'S OWN VALUE, and that
  // distinction is the whole of this gate's head binding. A confirming adversarial
  // review found the earlier call passing the sha CAPTURED FROM THE MARKER: since a
  // comment only reaches this function because it contains that marker, passing the
  // marker's own value made the verifier's head-bound clauses (`<!-- admin-merge-safety:
  // <head> -->`, `PR head: <head>`) SELF-SATISFYING, so a marker naming a 12-char
  // prefix certified in this layer while the shim refused it — two layers, two
  // verdicts, on the one clause (T5) that stops stale evidence unlocking a new head.
  // The marker's own binding is checked by `bound` at the CALL SITE (a prefix of the
  // current head, never of an earlier one); what is checked HERE is that the evidence
  // is the evidence for the head that is actually being merged.
  const verifier = resolveAdminMergeEvidenceVerifier();
  if (verifier === null) return false;
  // …and the delegate must first prove it is a CONTRACT and not a no-op. This is a
  // FAIL-OPEN GUARD, NOT A TRUST BOUNDARY, and the distinction is the whole point: the
  // probe is distinguishable, so a delegate that refuses only the probe passes it.
  // What stops a redirected delegate is the RESOLUTION below — the path comes from
  // this file's own location, with no environment seam — exactly as the shim does it.
  // What this catches is the honest accident: a broken or stubbed install whose
  // verifier exits 0 for everything, which would otherwise certify every merge
  // silently rather than loudly failing.
  if (!verifierRefusesNonZeroBody(verifier)) return false;

  let tmp: string | null = null;
  try {
    tmp = resolvePath(os.tmpdir(), `pi-admin-merge-evidence-${process.pid}-${Date.now()}-${Math.random().toString(36).slice(2)}.md`);
    fs.writeFileSync(tmp, body, "utf8");
    // `execFileSync`, not `execSync`: no shell, so the script path and the head
    // are argv rather than a command string. An enforcement gate should not have
    // a shell-interpolation surface at all.
    execFileSync("bash", [verifier, "--body-file", tmp, "--head", currentHead], {
      stdio: "ignore",
      timeout: 15_000,
    });
    return true;
  } catch {
    // Non-zero exit (the contract did not hold), a spawn failure, or a timeout.
    return false;
  } finally {
    if (tmp !== null) {
      try {
        fs.unlinkSync(tmp);
      } catch {
        /* best effort — a leftover temp file must not change the verdict */
      }
    }
  }
}


export type AdminMergeGateResult =
  // #2349: `reasonTag` names WHICH of the four block states fired, so the console
  // line can print the state instead of one sentence covering all of them. It is
  // added to the result and read ONLY for that line — the decision is the `status`.
  | { status: "block"; reason: string; reasonTag?: AdminMergeBlockTag }
  | { status: "allow"; message: string };

/** #2349 — the four distinct ways the admin-merge evidence gate blocks. */
export type AdminMergeBlockTag =
  | "admin_no_pr"
  | "admin_head_unreadable"
  | "admin_comments_unreadable"
  | "admin_no_evidence";

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
      reasonTag: "admin_no_pr",
      reason: [
        "✅ Review enforcement (admin-merge evidence) gate is working correctly.",
        "❌ STATE: no resolvable PR number — the command carries no readable admin merge selector, so no",
        "   head-bound evidence can be checked. (A mention of the admin-merge form inside a heredoc, a jq",
        "   filter, a PR/issue body or a grep pattern is DATA, not a merge: the text scanner cannot tell",
        "   those apart, and the argv-level gh shim decides them when it is installed.)",
        ...remediation,
      ].join("\n"),
    };
  }
  if (currentHead === null) {
    return {
      status: "block",
      reasonTag: "admin_head_unreadable",
      reason: [
        "✅ Review enforcement (admin-merge evidence) gate is working correctly.",
        `❌ STATE: PR #${pr} resolved, but its CURRENT head could not be READ (gh/API failure) — an admin merge cannot be bound to evidence without it.`,
        ...remediation,
      ].join("\n"),
    };
  }
  if (comments === null) {
    return {
      status: "block",
      reasonTag: "admin_comments_unreadable",
      reason: [
        "✅ Review enforcement (admin-merge evidence) gate is working correctly.",
        `❌ STATE: PR #${pr}'s head (${currentHead.slice(0, 12)}) is known, but its COMMENTS could not be READ — failing CLOSED for a bypass (a failed fetch is not "no evidence").`,
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
      if (bound && evidenceBodyIsCertifying(body, currentHead)) {
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
    reasonTag: "admin_no_evidence",
    reason: [
      "✅ Review enforcement (admin-merge evidence) gate is working correctly.",
      `❌ STATE: evidence missing — PR #${pr}'s comments were READ and none carries head-bound admin-merge evidence at the CURRENT head (${currentHead.slice(0, 12)}).`,
      "   Evidence is head-bound: every push to the PR invalidates it, so a stale marker is refused.",
      "   A marker alone is also refused — the evidence body must carry the comparison counts.",
      ...remediation,
    ].join("\n"),
  };
}

/**
 * #2349 — the ONE-LINE state the admin-merge evidence gate refused on.
 *
 * The gate has four distinct block states and used to print one sentence for all
 * of them. Measured 2026-10-22 (`gate-events.jsonl:2235`, `pr: null`): a lane running
 * `gh issue create --body-file` — nothing to merge — was refused with the same
 * words as a PR with genuinely missing evidence, so the lane could not tell which
 * fix applied. The tag comes from `evaluateAdminMergeGate` itself, so this line and
 * the refusal's reason cannot drift apart.
 */
export function adminMergeStateText(
  tag: AdminMergeBlockTag | undefined,
  pr: number | null,
  head: string | null,
): string {
  switch (tag) {
    case "admin_no_pr":
      return "no resolvable PR number — nothing in this command reads as a merge selector, so there is no PR to certify (a mention inside a heredoc/body/jq filter is DATA)";
    case "admin_head_unreadable":
      return `PR #${pr} resolved, but its current head could not be READ — evidence cannot be bound to an unknown head`;
    case "admin_comments_unreadable":
      return `PR #${pr} head ${head ? head.slice(0, 12) : "(unknown)"} known, but its COMMENTS could not be READ — fail-closed for a bypass`;
    case "admin_no_evidence":
      return `evidence MISSING — PR #${pr} comments read, none carries head-bound admin-merge evidence at ${head ? head.slice(0, 12) : "(unknown head)"}`;
    default:
      return "unclassified block";
  }
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
  "   → NOTHING IN THE BLOCKED COMMAND RAN. A blocked tool call is a no-op: if it bundled a",
  "     sub-agent launch alongside the git op, the launch DID NOT HAPPEN (#1492). Verify the",
  "     artifact, never the send. The refused command is recorded in gate-events.jsonl.",
  "   → Read skills/code-review/SKILL.md for the review dispatch protocol (operations/skills/code-review/SKILL.md in consumer repos).",
  "   → Dispatch reviewers via task sub-agents, then retry the git operation.",
  // #2287/#2148: a lane whose review came from a SPAWNED reviewer process (review-pr.sh,
  // the harness reviewer) does not need to re-do it through `task` — the registry record
  // bound to this op's head is accepted. Naming it here keeps the refusal satisfiable
  // from EITHER path, which is the whole point of the disclosure.
  // ⛔ AND NAME ITS CONDITION (fresh review round 5, P1). The record path is open only for a command
  // carrying NO shell syntax (see evidenceCommandIsPlain) — naming the record WITHOUT the shape
  // reproduced the #2287 defect one spelling over: a lane pushing `git push --force-with-lease`,
  // `git push -u origin $BR`, `cd … && git push` or `git push origin HEAD:refs/heads/<b>` was told
  // "a record satisfies this floor", followed the instruction, and stayed blocked. So the accepted
  // shapes are printed, and the sentence says plainly that anything else falls back to a dispatch.
  "   → A spawned reviewer PROCESS counts too — FOR THESE EXACT SHAPES ONLY. A review record bound",
  "     to this op's current HEAD (`review-pr.sh <PR>`, or record one with the command below)",
  "     satisfies this floor when the refused command is one of:",
  "        git push origin <this-branch>          (NO flags — `-f`, `-d`, `-u`, `-o …` fall back)",
  "        git push origin HEAD",
  "        gh pr create …            (no -H/--head, and no --repo pointing at another repo)",
  "     Any shell syntax closes that path — a pipe, `&&`, a quote, a redirect, `$VAR`, `cd … &&`,",
  "     `git push -u origin $BR` — because a shell can change WHAT RUNS and the record is bound to",
  "     BYTES. Run the push as its own bare command to use the record path; otherwise this floor",
  "     needs a reviewer DISPATCH (the `task` / `subagent` tool) in THIS session.",
  // #2148: name the command the RAIL will demand, not just the missing action. A lane told only
  // "dispatch a reviewer" satisfies this gate and is then refused by the merge registry for lack of
  // an attestation — the second refusal needs a command, and this is the moment to hand it over.
  "   → A dispatch alone does not land the PR: the rail also needs the attestation at the FINAL head —",
  `      ${REVIEWER_PREFLIGHT_RECORD_CMD}`,
  // #2349: say WHAT THIS FLOOR READ. Before #2287 it read only a dispatch count and the text said
  // so. #2287 gave it a head-bound-record path, which made that sentence FALSE — and left the
  // message CONTRADICTING its own spawn-path paragraph four lines above (fresh review round 5, P1).
  // The block below is only reached when no usable record was found, so "none" is a true statement
  // at the moment it prints. The registry-is-per-machine disclosure survives from #2349 because it
  // is still the reason a record can be invisible to THIS box.
  "   → WHAT THIS GATE READ: a head-bound review record for THIS op — found: NONE (no record at this",
  "     head for this repo on this box, or the command's shape closed that path — see above) — and the",
  "     reviewer DISPATCHES counted in THIS pi process (still 0). The registry is PER-MACHINE",
  "     (~/.pi/agent/reviews/<owner>-<repo>-<pr>.json), so a record minted on another box, or by a",
  "     parent session, is invisible here: for a lane whose reviewer ran elsewhere, a dispatch is the",
  "     only thing this floor can see. The datum it still needs is a dispatch IN THIS SESSION.",
  "   → Emergency: set AGENT_SKIP_REVIEW_GATE=1 (or ELDATO_SKIP_REVIEW_GATE=1) and restart to bypass all gates.",
].join("\n");
export { BLOCK_MESSAGE };

/** Chars of the command's END retained past the bound, so a trailing operation survives. */
export const TRUNCATION_TAIL = 200;

/**
 * The command a block REFUSED, redacted and bounded, for the durable audit trail (#1492).
 *
 * A `gate_block` entry records `reason` and `tier` — enough to COUNT blocks, not
 * enough to tell WHICH command was refused. This field answers that, and the
 * neighbouring hub-state gate carries a `command` field in the same stream, so the
 * shape is established.
 *
 * BOUNDED at BOTH ends. A head-only bound can drop a trailing `&& git push`, which is
 * the one thing this field exists to show, so the tail is kept as well (#1492).
 *
 * REDACTED before bounding: the audit files are world-readable, and the redactor is the
 * shared one both gates import, so the redaction rule cannot drift between them.
 */
export function auditCommand(command: string, limit = 2000): string {
  const redacted = redactCommand(command);
  if (redacted.length <= limit) return redacted;
  // The count is the REDACTED length and says so: redaction shortens the text, so an
  // unlabelled count would not be the refused command's length (#1492).
  return (
    `${redacted.slice(0, limit)}` +
    `… [truncated, ${redacted.length} chars after redaction] …` +
    `${redacted.slice(-TRUNCATION_TAIL)}`
  );
}

// ── #2349: the ≥1-dispatch floor says WHAT IT READ ─────────────────────────────
//
// The floor counts reviewer dispatches in THIS pi process, and (since #2287) first tries a
// head-bound `record-review.sh` registry record for the op. Its text said "no reviewers dispatched"
// and nothing else, so a lane whose reviewer ran in the parent session (dispatch is
// parent-enforced, #825) or on another box read it as "the review is missing" — a different fact,
// with a different next action, which this line now distinguishes explicitly.
//
// `recordState` exists so the value lands in the durable audit row: the fleet can
// then count how many refusals were "no record on this box" (the condition that was
// hand-measured at 3260-vs-156 records, 55/104 PRs visible) instead of inferring it.
export function describeDispatchFloorRead(
  command: string,
  tier: string,
  dispatchCount: number
): { lines: string[]; recordState: string } {
  const stateText = tier === "" ? "unlabeled" : tier;
  const lines = [
    `   → READ: reviewer dispatches counted in THIS pi process = ${dispatchCount}; tier=${stateText}.`,
    "     This floor ALSO tried a head-bound review record for this op and found NONE visible here,",
    "     so \"no record at this head\" and \"a record exists on another box\" read the same at this",
    "     point (the registry is PER-MACHINE).",
  ];
  // A command that reaches this floor names no PR BY CONSTRUCTION: every `gh pr merge`
  // and every `gh pr <verb> <n>` came back from the merge-registry branch above, which
  // always returns. So the honest extra datum is the REGISTRY ITSELF — how much of it is
  // on this box, and how much of that is even this repo's — because "the registry is
  // fragmented per machine" was the measured cause of the refusals this text explains.
  const ctx = resolveRepoContext(command, null);
  const repo = ctx.repo ?? (ctx.cwd ? repoFromGitRemote(ctx.cwd) : null) ?? repoFromGitRemote(process.cwd());
  const dir = reviewsDir();
  let total = 0;
  let forRepo = 0;
  try {
    const files = fs.readdirSync(dir).filter((f) => f.endsWith(".json"));
    total = files.length;
    if (repo) {
      const prefix = `${repo.replace("/", "-")}-`;
      forRepo = files.filter((f) => f.startsWith(prefix)).length;
    }
  } catch {
    total = -1; // registry dir absent — say so rather than reporting a confident 0
  }
  lines.push(
    total < 0
      ? `     REGISTRY on this box: ${dir} does not exist (0 records can be visible here).`
      : `     REGISTRY on this box: ${total} record(s) at ${dir}${repo ? `, ${forRepo} for ${repo}` : " (repo unresolved)"}.`
  );
  lines.push(
    "     This command names no PR, and its SHAPE decides whether a record could have been used at all" +
      " — the datum this gate needs is a reviewer dispatch in THIS session (or the parent's, for a sub-agent)."
  );
  return { lines, recordState: `no-pr-named (registry=${total}${repo ? `, repo=${forRepo}` : ""})` };
}

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
  "   → NOTHING IN THE BLOCKED COMMAND RAN. A blocked tool call is a no-op: if it bundled a",
  "     sub-agent launch alongside the git op, the launch DID NOT HAPPEN (#1492). Verify the",
  "     artifact, never the send. The refused command is recorded in gate-events.jsonl.",
  "   → Micro skips the multi-agent code-review GATE (commit-workflow 03-code-review.md) — the review-enforcer ≥1-dispatch rule still applies (#485).",
  "   → Docs-only sets (VGATE content-shape exempt) need a lightweight reviewer dispatch that names the diff and returns a verdict on it — a one-line verdict is enough. The floor counts the dispatch; the dispatch is expected to be a real review that returns a verdict, not a sign-off:",
  "   →   task(prompt='[REVIEW] docs-only change — verify claims/consistency against the docs diff; return NO ISSUES FOUND or list issues')",
  "   → Code sets satisfy the dispatch via VGATE: its [VGATE] verification dispatch counts as the required sub-agent dispatch. With VGATE disabled/bypassed, dispatch any lightweight task sub-agent — the gate counts any sub-agent dispatch (the `task` or `subagent` tool).",
  // #2148: micro's record command, so the refusal at the git op also names what the rail will read.
  `   → Then record the attestation at the FINAL head (micro): ${RECORD_SH} <PR> <head_sha> clean-micro [owner/repo]`,
  // #2349: same disclosure as the generic message, corrected post-#2287: the floor DOES consult a
  // head-bound record before it refuses, so "reads NO review record" was no longer true.
  "   → WHAT THIS GATE READ: a head-bound review record for THIS op — found: NONE (no record at this",
  "     head for this repo on this box, or the command carried shell syntax or a flag) — and the reviewer",
  "     DISPATCHES counted in THIS pi process (still 0). The registry is PER-MACHINE, so a record on",
  "     another box is invisible here. What unlocks this floor is a dispatch NOW.",
  "   → Emergency: set AGENT_SKIP_REVIEW_GATE=1 (or ELDATO_SKIP_REVIEW_GATE=1) and restart to bypass all gates.",
].join("\n");

/**
 * The tier the refusal names, in TIER_RULE's own vocabulary (#2204).
 *
 * `unknown` and "" are NOT tiers that were read — they are the two ways the tier can be
 * ABSENT (`unknown` = the pre-flight ran on an unlabeled issue and wrote that literal;
 * "" = no marker file at all). Both map to `unlabeled`, which is the vocabulary key for
 * "nobody determined a tier", not a tier value of its own.
 */
function tierLabel(tier: string): string {
  return tier === "" || tier === "unknown" ? "unlabeled" : tier;
}

/**
 * Provenance of a tier label (#2204 (3)): `read` only when a tier marker actually NAMED a tier.
 * `""` (no marker), `unknown` (the pre-flight's literal for an unlabeled issue) and `unlabeled` (the
 * vocabulary's key for "no tier") are all UNDETERMINED — a marker containing the word `unlabeled`
 * records that nobody determined a tier, and reading it as `read` would present the absence of a
 * tier as a tier of its own, which is the defect #2204 (3) named (cycle-2 review, P2).
 */
export function tierSourceFor(tier: string): "read" | "undetermined" {
  return tier === "" || tier === "unknown" || tier === "unlabeled" ? "undetermined" : "read";
}

/**
 * #2204 (3) — "`tier: unlabeled` must not read as the strictest tier": the refusal must
 * NAME the tier that triggered it, and say what `unlabeled` MEANS.
 *
 * The pre-#2204 messages named no tier at all, and the audit `tier` alone cannot say whether a tier
 * was DETERMINED: `unlabeled` is written when no marker exists and `unknown` is the pre-flight's
 * literal for an unlabeled issue, so a reader had to know the vocabulary to tell either from a real
 * tier — and the log made "stricter rules apply" look intentional. (That is what `tier_source` on
 * the audit entry answers directly; this message says it in words.)
 *
 * The message also carries the two halves of #2204 (2) — the refusal is NOT terminal, and a
 * read has a shape that does not need a reviewer at all. Neither line is decoration: the
 * measured failure was four lanes that took the refusal as the end of the run, and the
 * measured trigger was a command SHAPE (a loop, a `$(…)`) rather than a write.
 *
 * ⛔ THE RECOVERY ADVICE IS ROLE-AWARE. `role` is `reviewerRoleFor()`'s answer (#2148's split), and
 * it exists because this text now arrives as a MODEL-VISIBLE message that TRIGGERS A TURN
 * (`deliverBlockRecovery`), not only as a tool result. Telling a harness worker (whose brief says it
 * has no `task` tool and must not merge) to dispatch a reviewer is the exact contradiction #2148
 * removed for the pre-flight notice — and a `followUp` that forces a turn makes it worse, because the
 * lane is now being told to do something it cannot do. The roles that do not dispatch get the
 * direct instruction they can act on (push/report), plus the same "your brief overrides this" hedge.
 */
export function dispatchFloorMessage(tier: string, role: ReviewerRole = "self"): string {
  const base = tier === "micro" ? MICRO_BLOCK_MESSAGE : BLOCK_MESSAGE;
  const label = tierLabel(tier);
  const provenance =
    tier === ""
      ? "no tier marker was present (/tmp/agent-issue-complexity), so the tier was NEVER DETERMINED — " +
        "`unlabeled` here means NOBODY READ A TIER, not that a stricter tier was read. The ≥1-dispatch " +
        "floor is uniform (#485), so the same dispatch satisfies it at every tier."
      : tier === "unknown" || tier === "unlabeled"
        ? `the recorded value was \`${tier === "unknown" ? "unknown" : "unlabeled"}\`, which is what the ` +
          "pre-flight writes when the issue carried no complexity label. That is an UNDETERMINED tier, " +
          "not a stricter one: the ≥1-dispatch floor is uniform (#485), so the same dispatch satisfies " +
          "it at every tier."
        : "read from the tier marker (/tmp/agent-issue-complexity); this extension can see the " +
          "marker's CONTENT, not who wrote it.";
  const recovery =
    role === "reviewer"
      ? [
          "   → THIS REFUSAL IS NOT TERMINAL. Nothing ran. You are the REVIEWER: you do not dispatch,",
          "     push, record or merge — report the refused command to merge-one.sh and continue reporting.",
        ]
      : role === "harness"
        ? [
            "   → THIS REFUSAL IS NOT TERMINAL. Nothing ran and the session is still alive: push your",
            "     FINAL head and finish the report — the HARNESS reviewer (merge-one.sh) mints the",
            "     attestation for this PR, so do NOT dispatch and do NOT merge (#825).",
            "   → If your brief says you DO have a `task` tool and own the review, dispatch a reviewer and",
            "     re-run the SAME command instead.",
          ]
        : [
            "   → THIS REFUSAL IS NOT TERMINAL. Nothing ran and the session is still alive: dispatch a reviewer",
            "     (the `task` or `subagent` tool), then re-run the SAME command. Do not end the run on a block.",
            "   → If your brief says you have no `task` tool, that overrides this: do NOT dispatch and do NOT",
            "     merge — the parent's reviewer mints the attestation.",
          ];
  return [
    base,
    `   → Tier: ${label} — ${provenance}`,
    ...recovery,
    "   → If the command only READS (gh pr view / gh api / gh issue view), it should not have needed a",
    "     reviewer at all (#2204). Run the read as a plain standalone command on its own line —",
    "     `gh pr view <n>`, `gh api <GET path>`, `gh issue view <n>` — and it is allowed with ZERO",
    "     dispatches. A refusal means the text could not be certified as a read: a loop or a `$(…)`",
    "     that could hide a program, a path-spelled `gh`, a read bundled with a write, a `git` word",
    "     ANYWHERE in the command (put the git command on its own line — it needs no reviewer there,",
    "     but a git mention is never certified as a read), or a pipeline stage that can run a program",
    "     or write a file (`| bash`, `| env -i bash`, `| xargs -n1 sh`, `| sed '1e …'`, `| sort -o f`).",
  ].join("\n");
}

/**
 * #2665 — the CAPACITY refusal: a DISTINCT block message, not an extra sentence on the
 * compliance one.
 *
 * The two states are different faults with different remedies, and printing the wrong one
 * sends the lane to the wrong action:
 *
 *   compliance (`BLOCK_MESSAGE`)   the lane never dispatched → dispatch a reviewer NOW
 *   capacity   (this message)      a spawn was ATTEMPTED and produced no verdict → retry on a
 *                                  box that can serve it, and at the cap, stop and report
 *
 * ⛔ This is TIGHTER than the pre-#2665 floor, never looser: the attempt no longer counts as
 * a review (it used to, which let an unreviewed push through — `shared/spawn-capacity.ts`
 * carries the measured false PASS), and the requirement itself is untouched.
 */
export function unspawnableMessage(
  attempts: readonly SpawnAttempt[],
  /** The session's true attempt total — the ledger is a bounded RENDERING window. */
  total: number = attempts.length,
): string {
  return [
    "✅ Review enforcement gate is working correctly.",
    // ⛔ The header DERIVES its class from the same switch the body uses (review of #2665): the
    // previous hardcoded "CAPACITY fault" contradicted a body that said "SPAWN-SIDE refusal" in
    // the same message, and mislabelled a breaker as capacity.
    `⛔ Blocked — a \`task\`/\`subagent\` spawn produced NO verdict; 0 reviewer verdicts counted`,
    `   (${spawnFaultLabel(spawnFaultClass(attempts))}, not a compliance one).`,
    ...describeSpawnCapacity(attempts, readMachineCapacity(), total),
    // #2204 (2) + #2206 review (P2): this arm IS a refusal, and the docs (and the comment beside
    // the return) promise a refusal says it is not terminal. Only `terminate: false` was stated —
    // a field the MODEL never sees — while this text asked for a RETRY with nothing telling the
    // model the run continues, which is the measured failure #2204 (2) exists to fix.
    //
    // ⛔ IT DEFERS TO THE ACTION PARAGRAPH, IT DOES NOT NAME A RETRY (#2206 re-review, P1). The
    // first cut said "re-dispatch the reviewer (the RETRY above)" UNCONDITIONALLY, and
    // `describeSpawnCapacity` has five remedy branches: at the CAP it says "stop retrying … hand the
    // lane back", and on the latch "do NOT retry in a loop" — so the last line the model read
    // instructed the very retry the paragraph above forbade, and cited a RETRY that does not exist
    // at the cap. The ACTION paragraph is the last one emitted in EVERY branch and is the remedy
    // for the fault actually read, so it is what this line points at.
    "   → THIS BLOCK IS NOT TERMINAL: the run continues. Do not end the session on it —",
    "     the ACTION paragraph above is the remedy for THIS fault; follow it, then keep going.",
    "   → THE REQUIREMENT IS UNCHANGED: a reviewer verdict is still mandatory before this git op",
    `     (${SPAWN_UNSPAWNABLE_TOKEN} is what the BOX did, not a waiver). The rail will also demand`,
    `     the attestation at the FINAL head — ${REVIEWER_PREFLIGHT_RECORD_CMD}`,
  ].join("\n");
}

/**
 * How many attempt records the session keeps for rendering. Bounded so a re-dispatch loop
 * on a starved box cannot grow this state without limit; the TOTAL is counted separately
 * (`spawnAttemptsTotal`) so the refusal never understates how many were made.
 */
export const SPAWN_ATTEMPT_KEEP = 10;
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
    // #2665 — the ATTEMPT ledger, deliberately separate from `dispatchCount`. A spawn that
    // returned no verdict is not a dispatch (the floor's datum is a reviewer VERDICT), but it
    // IS evidence about the BOX, and the floor's refusal must be able to name it instead of
    // telling a lane that tried that it never dispatched at all.
    let spawnAttempts: SpawnAttempt[] = [];
    let spawnAttemptsTotal = 0;
    // #1662 review: run_ids whose terminal `task_collect` already counted as a
    // reviewer dispatch. `task_collect` is idempotent (the same terminal run
    // can be reaped repeatedly), so without this a repeated collect inflates
    // the ≥1-dispatch count and the durable `review_dispatch` audit total.
    const countedCollectRuns = new Set<string>();
    // #2148 — the up-front disclosure's state. `preflightInjected` is the once-guard for the
    // model-visible injection (the console line is emitted once by session_start itself);
    // `earlyPushNoticePrinted` is the once-guard for the first-push notice, which must not repeat
    // on every push. Both reset per session, so a resumed session is told again.
    let preflightInjected = false;
    let earlyPushNoticePrinted = false;
    // #2204 (2) — "a refusal must be survivable". The measured failure was a lane that took the
    // refusal as the end of the run: the block reason IS the tool result, but a `pi -p` lane that
    // has nothing else to do simply stops. This flag makes the refusal DELIVER a model-visible
    // recovery message once per session (see `deliverBlockRecovery` below). ONCE is the bound and
    // the reason it is safe: a per-block message would turn a lane that keeps retrying a refused
    // command into a token loop, and the recovery instruction does not get truer by repetition.
    let blockRecoverySent = false;
    // #2148 — the audience, resolved per FACTORY INSTANCE (a session's `KIND` is exported by its
    // launcher and never changes mid-session). See `reviewerRoleFor`.
    const reviewerRole = reviewerRoleFor();

    // ── session_start ──────────────────────────────
    pi.on("session_start", async (_event, _ctx) => {
      dispatchCount = 0;
      spawnAttempts = [];
      spawnAttemptsTotal = 0;
      countedCollectRuns.clear();
      preflightInjected = false;
      earlyPushNoticePrinted = false;
      blockRecoverySent = false;

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

      // ── #2148: THE REQUESTER'S EARLIEST READER ─────────────────────
      // Whatever the branch above decided, a session that can reach the rail must hear the
      // reviewer requirement BEFORE it does any work. Measured 2026-10-19: three lanes ran
      // their whole job and were refused at the finish line, having never been told. This
      // fires once per session, for EVERY non-sub-agent session — including a BYPASSED one,
      // where it is not redundant but MORE important, and where the enforcer that refuses is NOT
      // this one: with the flag set, `extensionEnabled` is false and the tool_call handler returns
      // at the `if (!extensionEnabled)` line — BEFORE `isGitOp` and before the merge-registry gate
      // at the bottom of the handler (review of #2148, P2: an earlier version of this comment said
      // "the only thing that will refuse the lane is the merge gate", which is false for a
      // non-sub-agent). What refuses a bypassed session is the RAIL: `admin-merge.sh` verifies the
      // head-bound evidence itself, and the repo's required review check (`ai-review-gate`) never
      // goes green without the signed record. #285's "the bypass does not unlock sub-agent merges"
      // holds here for a different reason — a task sub-agent is forced to `extensionEnabled = true`
      // a few lines above, so its merge IS gated locally.
      //
      // The emitted sentence ("the rail STILL refuses without an attestation") is about that
      // outside enforcement and stays true; do not "simplify" it into a claim about this gate.
      //
      // Task sub-agents are excluded by design: review dispatch is parent-enforced (#825), the
      // parent session prints this line for the PR as a whole, and a child's console output is
      // the parent's tool result — a second copy is noise, not disclosure.
      //
      // The ROLE picks the audience: a harness worker (`KIND` set by lane.sh / fix-one.sh /
      // merge-one.sh) is told the harness reviewer mints the attestation and that it must not
      // merge; everyone else is told how to dispatch, record and land themselves.
      if (!isTaskSubAgent()) {
        console.log(reviewerPreflightLine({ role: reviewerRole, bypassed: !extensionEnabled }));
        logGateEvent("reviewer_preflight", {
          phase: "session_start",
          role: reviewerRole,
          bypassed: !extensionEnabled,
        });
      }
    });

    // ── #2148: the same disclosure, on the MODEL-VISIBLE channel ─────────────
    // The console line above lands in the lane's log, which is what an operator greps. It is
    // NOT reliably in the model's context: a `pi -p` lane's prompt is the brief it was launched
    // with, and an extension's console output does not join it. So the FIRST agent start injects
    // the requirement as a session message — persisted, displayed, and read by the model — and
    // later turns do not repeat it (once, up front, exactly as the issue asks).
    pi.on("before_agent_start", async (_event, _ctx) => {
      if (preflightInjected) return undefined;
      preflightInjected = true;
      if (isTaskSubAgent()) return undefined;
      return {
        message: reviewerPreflightMessage({ role: reviewerRole, bypassed: !extensionEnabled }),
      };
    });

    // ── session_shutdown ───────────────────────────
    pi.on("session_shutdown", async (_event, _ctx) => {
      dispatchCount = 0;
      countedCollectRuns.clear();
      blockRecoverySent = false;
      // Clear marker file to prevent persistent state leakage across sessions
      try {
        if (fs.existsSync(ISSUE_COMPLEXITY_FILE)) {
          fs.unlinkSync(ISSUE_COMPLEXITY_FILE);
          console.log(`[review-enforcer] 🧹 Cleared ${ISSUE_COMPLEXITY_FILE} marker on shutdown`);
        }
      } catch (_err) { /* best-effort cleanup */ }
    });

    // ── #2204 (2): the refusal as a SURVIVABLE event ─────────────────────
    //
    // The block itself is a tool result — the model does read it. What the measurement shows is
    // that a lane with nothing left to do treats it as the END of the run (four dispatches, three
    // cells, zero output). A tool result cannot re-open a turn that is already finishing, so the
    // recovery instruction is ALSO delivered on the model-visible channel with `deliverAs:
    // "followUp"` + `triggerTurn: true`: "followUp" is defined as "delivered only when the agent
    // has no more tool calls", which is exactly the moment the run would otherwise stop, and
    // `triggerTurn` gives that moment a next turn.
    //
    // ONCE PER SESSION, deliberately: an unconditional message on every block would let a lane that
    // keeps retrying a refused command buy unbounded turns. One recovery is enough to say "this is
    // not terminal"; saying it twice is a loop. Guarded on `sendMessage` existing, so a host (or a
    // test double) without it cannot turn a refusal into a thrown exception on the gate path.
    //
    // ⛔ THE BUDGET IS SPENT BY A HAND-OFF, NOT BY AN ATTEMPT (fresh review, P2). The first version
    // set the flag before trying, so on a host without `sendMessage` (or one that threw) the session
    // lost its one recovery with nothing handed over AND the audit recorded
    // `phase: block_recovery` as if the model had been told. The flag is now set only when the send
    // path RAN — and the audit field is `send_queued`, not `delivered`: `ExtensionAPI.sendMessage`
    // returns `void` and the runtime is fire-and-forget with a swallowing error hook, so the most an
    // extension can observe is "handed to the SDK". A field called `delivered` would be a claim this
    // code cannot make (cycle-2 review, P2).
    //
    // The AUDIENCE comes from `reviewerRoleFor()` (#2148's split) — see `dispatchFloorMessage`: this
    // text now TRIGGERS A TURN, so telling a harness worker to dispatch a reviewer would be the
    // #2148 contradiction with a keystroke attached.
    // ⛔ `message` IS A PARAMETER, NOT ALWAYS THE COMPLIANCE TEXT (#2206 re-review, P1). The
    // capacity arm's diagnosis is "the BOX failed, re-running the blocked op cannot satisfy this
    // floor" — and dropping `dispatchFloorMessage` on it delivered `❌ No reviewers were dispatched
    // … Dispatch reviewers via task sub-agents, then retry the git operation`, i.e. the exact
    // wrong action #2665's own note above says printing BLOCK_MESSAGE on that arm produces. It
    // arrives as a `followUp` that TRIGGERS A TURN, so it is the instruction the model acts on.
    // The floor arm keeps the default; the capacity arm passes its own `unspawnableMessage`.
    const deliverBlockRecovery = (tier: string, rawCommand: string, message?: string): void => {
      if (blockRecoverySent) return;
      const body = message ?? dispatchFloorMessage(tier, reviewerRole);
      let sendQueued = false;
      if (typeof (pi as { sendMessage?: unknown }).sendMessage === "function") {
        try {
          (pi as any).sendMessage(
            { customType: "reviewer-block-recovery", content: body, display: true },
            { deliverAs: "followUp", triggerTurn: true }
          );
          sendQueued = true;
          blockRecoverySent = true;
        } catch (_err) { /* delivery must never throw into the gate path */ }
      }
      logGateEvent("reviewer_preflight", {
        phase: "block_recovery",
        tier: tier === "" ? "unlabeled" : tier,
        tier_source: tierSourceFor(tier),
        send_queued: sendQueued,
        // #1382: the audit row records the command the CALLER wrote. This helper receives the
        // masked READING for none of its own logic — `rawCommand` is the only thing it audits —
        // so it must be handed the caller's text, not the heredoc-masked rewrite.
        command: auditCommand(rawCommand),
      });
    };

    // ── tool_call: block git ops if no reviewers (uniform ≥1-dispatch, all tiers) ──
    pi.on("tool_call", async (event, toolCtx) => {
      if (!isToolCallEventType("bash", event)) return undefined;
      // `rawCommand` is read BEFORE the `extensionEnabled` gate: the #2148 early notice below must
      // also reach a BYPASSED lane (that is the one which reaches the rail unstopped).
      const rawCommand = String(event.input.command ?? "");

      // #984: the ARGV-LEVEL layer runs FIRST and for EVERY bash call, not only
      // for git ops — the shim has to be on PATH before the command runs, and a
      // command that does not look like a merge to the scanner is exactly the
      // case the scanner cannot decide. The string gates below then act as the
      // fast first layer, unchanged.
      //
      // `rawCommand` is what the CALLER wrote: the injected prefix names the shim
      // path (`…/gh-shim/gh`), so scanning the MUTATED text would feed the gates a
      // `gh` word that the author never wrote.

      // ── #2148: FAIL EARLY, NOT ONLY AT THE FINISH LINE ─────────────────────
      // "If the enforcer can detect at first push that no reviewer was ever dispatched, it should
      // say so at that point rather than only at merge time. The lane can then fix it while it
      // still has context." (the issue, verbatim). This runs BEFORE the `extensionEnabled` gate
      // below, deliberately: a BYPASSED lane is never stopped at its git op, so the FIRST notice
      // it would otherwise get is the rail's refusal — the finish line this notice exists to move.
      //
      // ⛔ DELIVERED AS A SESSION MESSAGE, not only a console line — that is what makes "while it
      // still has context" true. A fresh reviewer measured the first version: it logged the notice
      // while this file's own comment says a console line is NOT reliably in the model's context,
      // so the lane that most needed it (the harness worker, whose brief has no reviewer step for
      // its own session) never saw it. `deliverAs:"steer"` queues it behind the current turn's
      // tool calls and ahead of the next model call; the console line stays for the operator.
      //
      // It is a NOTICE, never a block: blocking a sub-agent's push at 0 dispatches would reverse
      // #285/#825 (review dispatch is parent-enforced), so the decision stays where it is.
      // Once per session: a lane that pushes five times must not be told five times.
      if (
        !isTaskSubAgent() &&
        dispatchCount === 0 &&
        !earlyPushNoticePrinted &&
        isPushOrPrCreateCommand(rawCommand)
      ) {
        earlyPushNoticePrinted = true;
        const notice = reviewerFirstPushNotice({
          role: reviewerRole,
          bypassed: !extensionEnabled,
        });
        console.log(notice);
        // Guarded: a host without sendMessage (or a test double) must not turn a NOTICE into a
        // thrown exception on the gate path.
        if (typeof (pi as { sendMessage?: unknown }).sendMessage === "function") {
          (pi as any).sendMessage(
            { customType: "reviewer-preflight", content: notice, display: true },
            { deliverAs: "steer" },
          );
        }
        logGateEvent("reviewer_preflight", {
          phase: "first_push",
          role: reviewerRole,
          bypassed: !extensionEnabled,
          command: auditCommand(rawCommand),
        });
      }

      if (!extensionEnabled) return undefined;
      const shimDir = activeGhShimDir();
      if (shimDir === null && !ghShimAbsenceWarned && process.env.AGENT_GH_SHIM !== "0") {
        ghShimAbsenceWarned = true;
        console.log(
          "[review-enforcer] ⚠️  #984 argv-level gh shim not found — only the string scanner " +
            "is active, so bash token splicing can still hide an admin merge, and a heredoc body " +
            "written to a script file and run by a LATER command is not followed by any text gate. " +
            "Set AGENT_GH_SHIM_DIR, or install scripts/gh-shim."
        );
      }
      const shimmed = withGhShim(rawCommand, shimDir);
      if (shimmed !== null) event.input.command = shimmed;

      // #1382: THE GATE READS A DATA MODEL, NOT THE BYTES THE USER TYPED. A heredoc body is stdin
      // DATA, not command lines: `cat >> evidence.md <<'EOF' … a log line that MENTIONS a merge …
      // EOF` writes a file and runs nothing, and refusing it is an INSTRUMENT FALSE POSITIVE — the
      // measured cost is an agent that cannot RECORD a defect it just found (this lane's own first
      // tool call, and #1382 before it). INVARIANT: a gate that fires on prose teaches agents to
      // write around it, which is how real bypasses hide.
      //
      // ⛔ UNCONDITIONAL, AND THAT IS THE POINT — masking is NOT a deferral. The first cut of this
      // fix applied the mask only while the argv layer (#984) enforced, on #1485's rule that "a
      // deferral is sound only while what it defers TO is installed". That rule is about standing a
      // DECISION down for text the scanner cannot read (the `merges === 0 && readsNonMergeGhCall`
      // path below, which stays shim-conditioned). Masking a body that `heredocBodyIsData` has
      // PROVEN is data is not that: such a body is never executed by this command (a proven stdin
      // consumer cannot run its stdin; a target it writes is refused when a later line can execute
      // it; a shadowed reader, a pipe, a substitution or an assignment prefix leaves the body
      // readable), so the mask cannot hide an invocation — it corrects a mis-read of one.
      //
      // THE CONDITION WAS WORSE THAN USELESS, it was the bug: this fleet runs with the argv layer
      // ABSENT (`docs/ops/ACTIVATION-MATRIX.md` row 1 — nothing installs `scripts/gh-shim`, and the
      // resolver returns null: measured on this cell), so tying the mask to it left the reported
      // defect refusing the reporter — a harmless `cat >> notes.md <<'EOF'` — in the only
      // environment where anybody hit it. Verified, not assumed: with the shim absent the
      // shim-conditioned build still refuses that command verbatim.
      const command = maskHeredocData(rawCommand);
      if (!isGitOp(command)) return undefined;

      // #930: the admin-merge evidence gate runs FIRST (before the merge
      // registry). `--admin` bypasses required checks, so it is refused unless
      // the PR carries evidence bound to the CURRENT head SHA. On a pass it
      // FALLS THROUGH to the merge-registry gate — the two gates are
      // independent and both must pass.
      //
      // #1776: but only for a read the TEXT layer can actually make. A literal
      // `--admin` needs no shell resolution, so it keeps the decision here even
      // with the argv layer installed — which is why
      // `export "PATH"=…; gh pr merge 999 --admin` is still refused. The rest of
      // `isAdminMergeCommand` is a fail-closed GUESS (a construct plus the word
      // `admin`, which a PR TITLE supplies), and a guess is not something an
      // evidence check should be run on: it refused an ordinary `gh pr create` at
      // zero dispatches. When the argv layer is installed it resolves what a guess
      // cannot, and it decides; when it is absent or switched off, this gate
      // refuses exactly as before. See `ghShimWillEnforce`.
      //
      // #1776: the deferral is the unresolvable FLAG, never the MERGE. Two halts bound it:
      // a LITERAL `--admin` keeps the decision in the layer that can make it, and
      // `readsNonMergeGhCall`'s POLARITY stands this layer down only for a command it can
      // POSITIVELY read as a non-merge gh call — a read that also fails when a
      // construct-bearing token sits where an executable or a verb belongs (a decoy readable
      // `gh …` cannot buy the deference for a merge that spelled its own words away) or when
      // a path to a `gh` appears. So a spliced or ANSI-C-quoted word, a brace expansion, a
      // redirection, a construct-supplied verb behind a global flag, an empty-quoted repo
      // value, a tokenizer residue, or a spelling this lane has not seen keeps the gate
      // instead of being handed to an argv layer the command itself can discard
      // (`PATH="${PATH#*:}"; export PATH; gh pr merge 999 $'--admin'`). A shape the text
      // READS as a merge cannot be a positive non-merge read, which is pinned in the
      // predicate test rather than asserted here.
      if (isAdminMergeCommand(command) &&
          (hasLiteralAdminFlag(command) || mergeVerbInText(command) ||
           !readsNonMergeGhCall(command) || !ghShimWillEnforce(shimDir))) {
        // #1485: count INVOCATIONS, not text. The count skips quoted data, so a
        // mention in a jq filter / grep pattern / PR body / interpreter payload no
        // longer inflates it (measured: two read-only `gh run view` calls plus
        // `grep -viE "^\s*$"` were refused as "more than one `gh pr merge`").
        const merges = countMergeVerbs(command);
        // P1 (fresh review): a compound command is judged against ONE PR, so
        // `gh pr merge 111 --admin; gh pr merge 999 --admin` would pass on 111
        // and then merge 999 unevidenced. Fail closed.
        if (merges > 1) {
          // #2349: name the count the gate actually read. "more than one merge" told a lane
          // nothing about WHAT it read; the number does, and the refused command is in the audit row.
          console.log(
            `[review-enforcer] 🚫 Admin-merge evidence gate blocked (compound merge) — STATE: ${merges} ` +
              "`gh pr merge` invocations read in this one command; the gate certifies ONE PR per call"
          );
          logGateEvent("merge_gate_block", { reason: "admin_merge_compound_command" });
          return {
            block: true,
            reason:
              "This command contains more than one `gh pr merge`. The admin-merge evidence " +
              "gate can only certify ONE PR per call, so it cannot prove the others are " +
              "evidenced. Run them as separate commands.",
          };
        }
        // #1485: ZERO merge invocations, and the argv scan POSITIVELY read every
        // `gh` in the command as a non-merge subcommand — there is no merge for an
        // evidence gate to certify, so the candidate came from DATA (a payload, a
        // jq filter, a PR body). Polarity is `readsNonMergeGhCall`'s: a command
        // whose gh invocations this scan cannot read (a construct outside a data
        // region, a `$P/g''h` path, an unresolvable verb) stays gated below.
        //
        // #1485 review (P0, reproduced): standing down is only sound while the
        // argv layer is INSTALLED, because that is what still sees a merge this
        // text scan mis-read as data (`timeout 5 sh -c '<payload>'`, a payload in
        // a prefix the data model does not know). With the shim off — a supported
        // state (`AGENT_GH_SHIM=0`) — nothing downstream would catch it, so the
        // previous conservative refusal is kept instead of a stand-down. Same
        // guard, same reason as the #1776 deferral above.
        if (merges === 0 && readsNonMergeGhCall(command) && ghShimWillEnforce(shimDir)) {
          console.log(
            "[review-enforcer] ✅ Admin-merge evidence gate: no merge invocation (mention only) — allowed"
          );
          logGateEvent("merge_gate_pass", { reason: "admin_merge_no_invocation" });
        } else {
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
            // #2349: four different states used to print this one sentence. The tag comes
            // from the gate itself, so the console line and the reason cannot disagree.
            console.log(
              `[review-enforcer] 🚫 Admin-merge evidence gate blocked — STATE: ${adminMergeStateText(
                adminResult.reasonTag,
                adminPr,
                adminHead,
              )}`
            );
            logGateEvent("merge_gate_block", {
              pr: adminPr,
              reason: "admin_merge_no_evidence",
              command: auditCommand(rawCommand), // #1492: the refused command, not just the reason
            });
            return { block: true, reason: adminResult.reason };
          }
          console.log(adminResult.message);
          logGateEvent("merge_gate_pass", {
            pr: adminPr,
            reason: adminOverride ? "admin_merge_override" : "admin_merge_evidence_ok",
          });
        }
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
        // #1351 — fetch the PR's LIVE diff digest only when it can change the
        // verdict: a record that carries a usable `diff_sha256` AND a head that
        // has actually moved. Nothing else reads it, so a matching head must not
        // pay for the read (the head binding already allows), and a record
        // without the field must not either (its absence falls through to the
        // head block — never to an accept). The read is the SAME normalized
        // digest the record stores and the GitHub gate computes, so the two
        // gates cannot disagree about what "reviewed" means.
        // #1351 — fetch the PR's LIVE diff digest only when it can change the
        // verdict: a record that carries a usable `diff_sha256` AND a head that
        // has actually moved. Nothing else reads it, so a matching head must not
        // pay for the read (the head binding already allows), and a record
        // without the field must not either (its absence falls through to the
        // head block — never to an accept). The read is the SAME normalized
        // digest the record stores and the GitHub gate computes, so the two
        // gates cannot disagree about what "reviewed" means.
        const diffReadAttempted =
          !!record && isDiffSha256(record.diff_sha256) &&
          currentHead !== null &&
          record.head_sha !== currentHead;
        // #2349: the live digest read reports WHY it yielded nothing, for the refusal
        // text only (a failed READ is not a failed review). The DECISION still consumes
        // `currentDiffHash` and nothing else, through the same predicate as before.
        const liveDiffRead = diffReadAttempted
          ? getPrLiveDiffHashObserved(prNumber, ctx)
          : { hash: null, reason: null };
        const currentDiffHash = liveDiffRead.hash;
        // #1351: an ATTEMPTED read that came back null is a FAILED READ — never a
        // changed diff. Without this the arm cannot tell "the content moved" from
        // "the shared gh gate queued longer than the read bound", and its refusal
        // told the lane to re-review in both cases (measured 2026-10-22).
        const diffReadFailed = diffReadAttempted && currentDiffHash === null;
        // #2349: the registry observation, taken ONCE and passed to the gate as a
        // MESSAGE INPUT. `record` above is still what `readReviewRecord` returned —
        // the observation is never consulted for a decision.
        const recordObservation = observeReviewRecord(prNumber, envRepo ?? undefined);
        // #285 Fix C: the no-record block message is shape-aware (task
        // sub-agents get the "parent must record the review" variant).
        const result = evaluateMergeGate(
          prNumber, record, currentHead, ctx, isTaskSubAgent(), currentMergeBase, currentDiffHash,
          recordObservation, liveDiffRead.reason, diffReadFailed
        );
        if (result.status === "block") {
          // #2349: name the state in the line the operator reads, reusing the SAME
          // tag the durable audit row carries (never a second, drifting vocabulary).
          console.log(
            `[review-enforcer] 🚫 Merge registry gate blocked merge — STATE: ${result.reasonTag ?? mergeGateBlockReason(record)}`
          );
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

      // #2287/#2148: a SPAWNED reviewer process is equivalent evidence to an
      // in-session `task` dispatch. The artifact is `record-review.sh`'s registry
      // record, bound to the EXACT head this op ships — the same file the merge
      // registry gate reads as the attestation. No record ⇒ no reviewer verdict ⇒
      // the floor below still refuses (the protection is unchanged).
      if (!taskSubAgent && dispatchCount === 0) {
        const op = resolveShippedHeads(command, toolCtx);
        // `repo === null` means the op's repo could not be resolved - then a record CANNOT be
        // bound to it (the #426 P0-2 rule the merge gate already applies: with no repo context
        // only a repo-less legacy record may match, never one that embeds somebody's repo).
        const evidence = op === null || op.repo === null
          ? null
          : headBoundReviewEvidence(op.heads[0], op.repo);
        if (evidence !== null) {
          console.log(
            `[review-enforcer] ✅ Reviewer process evidenced — review record for ${evidence.repo ?? "<unresolved repo>"}#${evidence.pr} ` +
              `bound to the pushed head ${evidence.head_sha.slice(0, 12)} (verdict: ${evidence.verdict}) — allowing git op`
          );
          logGateEvent("review_dispatch", {
            dispatch_count: dispatchCount,
            reason: "review_record_bound_head",
            pr: evidence.pr,
            head_sha: evidence.head_sha,
            record: evidence.recordPath,
          });
          return undefined;
        }
      }

      // #485: uniform ≥1-dispatch block — every tier (micro, standard, complex,
      // unlabeled) blocks at 0 dispatches. The tier read survives ONLY for
      // message selection: micro skips the multi-agent code-review gate
      // (03-code-review.md), so its remediation differs from BLOCK_MESSAGE.
      // Pinned by index.test.ts (behavioral T1/T1b + fence drift T2 + source
      // shape T3). The #285 task-sub-agent early return above is untouched.
      // Read ONCE, above the #2204 read escape, so the pass entry and the block entry cannot
      // disagree about the same command's tier.
      let tier = "";
      try {
        if (fs.existsSync(ISSUE_COMPLEXITY_FILE)) {
          tier = fs.readFileSync(ISSUE_COMPLEXITY_FILE, "utf8").trim().toLowerCase();
        }
      } catch (_err) { /* best-effort */ }

      // #2204: A READ IS NOT A WRITE — and the floor must not refuse one.
      //
      // MEASURED: `for n in …; do gh pr view $n … done` and `sha=$(gh api repos/…)` were
      // both refused with `no_reviewers_dispatch`, and four lanes ended on it without doing
      // any work. Neither is a write. The candidate came from `isGitOp`'s broad arms (a
      // construct plus `gh`+`pr` is enough), so the floor has to ask its OWN question —
      // "is this text positively a read?" — and stand down when the answer is yes.
      //
      // ⛔ PLACEMENT IS PART OF THE FIX. This sits AFTER the admin-merge and merge-registry
      // gates (a command that names a merge is decided there, with the evidence checks) and
      // AFTER the ≥1-dispatch / task-sub-agent early return above (a dispatched session is
      // unaffected). It is the ONLY relaxation, and `readsOnlyGhRead` fails closed on every
      // unreadable shape — so `git commit`/`git push` at zero dispatches still block here,
      // which is what the #2204 tests and #485 T1/T1b pin.
      if (readsOnlyGhRead(command)) {
        console.log(
          "[review-enforcer] ✅ Read-only command — the ≥1-dispatch floor covers writes, not reads (#2204)"
        );
        logGateEvent("gate_pass", {
          reason: "read_only_no_dispatch",
          tier: tier === "" ? "unlabeled" : tier,
          tier_source: tierSourceFor(tier),
          // #1382: the audit row records the command the CALLER wrote, not the masked reading.
          command: auditCommand(rawCommand),
        });
        return undefined;
      }

      // #516: BOTH block returns below must emit a durable audit entry — the
      // pre-#516 dispatch-count block wrote console only (no appendJsonl),
      // unlike the merge-registry gate's logMergeGateDecision trail, so
      // blocked-op frequency/attribution was unreconstructible from
      // gate-events.jsonl. Emit gate_block + reason no_reviewers_dispatch + the
      // TIER_RULE-vocabulary tier (micro | standard | complex | unknown |
      // unlabeled; marker-absent maps to "unlabeled") so the tier of every
      // blocked op — the docs-only micro class (#485) included — is
      // reconstructible. Pinned by index.test.ts T1 (micro) + T1b (others).
      //
      // #2204 (3): the tier vocabulary is unchanged (T1b pins it), but the entry now carries
      // `tier_source`, because `tier: unlabeled` could not be told apart from a REAL tier: it
      // was written both for "no marker" and for the pre-flight's literal `unknown`. A reader
      // of the JSONL can now see that no tier was determined — and the operator-facing message
      // says the same thing in words.
      const tierClassification = tierSourceFor(tier);
      if (tier === "micro") {
        // #2665: CAPACITY first — the fault is upstream of the tier, so the micro remediation
        // (which is about WHICH reviewer to dispatch) would misdirect here.
        if (spawnAttemptsTotal > 0) {
          const fault = spawnFaultClass(spawnAttempts).toUpperCase();
          console.error(
            `[review-enforcer] ⛔ Blocked — spawn produced NO verdict, 0 reviewer verdicts counted (${fault}: ${spawnAttemptsTotal} attempt(s))`
          );
          for (const line of describeSpawnCapacity(spawnAttempts, readMachineCapacity(), spawnAttemptsTotal))
            console.log(line);
          logGateEvent("gate_block", {
            reason: "review_gate_unspawnable",
            tier: "micro",
            spawn_attempts: spawnAttemptsTotal,
            spawn_outcomes: spawnAttempts.map((a) => a.outcome),
            // #1382: audit the caller's command. `command` is the heredoc-masked READING the
            // gates use, and masking blanks proven DATA — recording it would erase evidence.
            command: auditCommand(rawCommand),
          });
          // #2204 (2): stated EXPLICITLY on the capacity arm too. Its own text asks for a RETRY
          // (`describeSpawnCapacity`), so a refusal the model reads as the end of the run would
          // contradict the remedy it was just handed — the exact measured failure #2204 (2) fixes.
          // The value is the SDK default, so nothing changes at runtime; stating it is what stops a
          // future edit from reaching for `terminate: true` to "make the refusal stick".
          //
          // ⛔ AND THE MODEL-VISIBLE HALF, ON BOTH CAPACITY EMITTERS (#2206 re-review, P2): the
          // first fix added this call to the non-micro branch only, so a `pi -p` micro lane still
          // got a tool result and nothing that re-opens the turn — the exact #2204 (2) failure.
          deliverBlockRecovery("micro", rawCommand, unspawnableMessage(spawnAttempts, spawnAttemptsTotal));
          return {
            block: true,
            reason: unspawnableMessage(spawnAttempts, spawnAttemptsTotal),
            terminate: false,
          };
        }
        const floor = describeDispatchFloorRead(command, "micro", dispatchCount);
        console.log("[review-enforcer] 🚫 Blocked — no reviewers dispatched (micro tier)");
        for (const line of floor.lines) console.log(line);
        logGateEvent("gate_block", {
          reason: "no_reviewers_dispatch",
          tier: "micro",
          // #2349: WHAT the floor read about the registry, so the fleet can count
          // "no record on this box" refusals instead of hand-measuring them.
          record_state: floor.recordState,
          tier_source: "read",
          // #1382: the audit row records the command the CALLER wrote. `command` is the
          // heredoc-masked READING used by the gates; masking is never a rewrite of the record.
          command: auditCommand(rawCommand), // #1492: the refused command, not just the reason
        }); // #516: durable audit
        deliverBlockRecovery(tier, rawCommand);
        return { block: true, reason: dispatchFloorMessage("micro", reviewerRole), terminate: false };
      }

      // #2665: the lane that TRIED and could not get a verdict is a different state from the
      // lane that never dispatched. Same floor, different verdict — see `unspawnableMessage`.
      if (spawnAttemptsTotal > 0) {
        const fault = spawnFaultClass(spawnAttempts).toUpperCase();
        console.error(
          `[review-enforcer] ⛔ Blocked — spawn produced NO verdict, 0 reviewer verdicts counted (${fault}: ${spawnAttemptsTotal} attempt(s))`
        );
        for (const line of describeSpawnCapacity(spawnAttempts, readMachineCapacity(), spawnAttemptsTotal))
          console.log(line);
        logGateEvent("gate_block", {
          reason: "review_gate_unspawnable",
          tier: tier === "" ? "unlabeled" : tier,
          spawn_attempts: spawnAttemptsTotal,
          spawn_outcomes: spawnAttempts.map((a) => a.outcome),
          command: auditCommand(rawCommand), // #1492: the refused command, not just the reason
        });
        // #2204 (2): non-terminating, like the floor return below — see the note on the micro arm.
        // AND the model-visible half: `unspawnableMessage` now states it, and the recovery is
        // delivered here too (#2206 review, P2 — the arm stated `terminate: false` and nothing the
        // model reads, so a lane on the one arm #2204 calls "the refusal the model reads as the end
        // of the run" still read it that way). The message is THIS arm's, not the compliance text
        // (#2206 re-review, P1).
        deliverBlockRecovery(tier, rawCommand, unspawnableMessage(spawnAttempts, spawnAttemptsTotal));
        return {
          block: true,
          reason: unspawnableMessage(spawnAttempts, spawnAttemptsTotal),
          terminate: false,
        };
      }

      const floor = describeDispatchFloorRead(command, tier, dispatchCount);
      console.log("[review-enforcer] 🚫 Blocked — no reviewers dispatched");
      for (const line of floor.lines) console.log(line);
      logGateEvent("gate_block", {
        reason: "no_reviewers_dispatch",
        tier: tier === "" ? "unlabeled" : tier,
        record_state: floor.recordState, // #2349
        tier_source: tierClassification,
        // #1382: audit the caller's command, not the masked reading (see the micro arm above).
        command: auditCommand(rawCommand), // #1492: the refused command, not just the reason
      }); // #516: durable audit
      deliverBlockRecovery(tier, rawCommand);
      // `terminate: false` is EXPLICIT (#2204 (2)). The SDK contract is "the agent stops early only
      // when every finalized result in the batch is terminating", so a refusal that leaves this
      // unset is already non-terminating — stating it is what stops a future edit from reaching for
      // `terminate: true` to "make the refusal stick". The measured failure was the MODEL treating
      // the block as terminal; `deliverBlockRecovery` is the model-visible half of that fix.
      return { block: true, reason: dispatchFloorMessage(tier, reviewerRole), terminate: false };
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
      // #1662: a `task({ background: true })` dispatch returns at DISPATCH, not
      // completion — counting it would satisfy the ≥1-dispatch gate while the
      // reviewer is still running (a fail-open on the git-op gate). Count the
      // reviewer when its verdict is actually reaped: the terminal
      // `task_collect`. The returns-early notice and a not-finished collect are
      // both ignored.
      const reviewDetails = (event as { details?: { background?: boolean; terminal?: boolean; run_id?: string } }).details;
      // #1662 review: the pre-spawn refusal / halted-chain / invalid-session-id
      // results are built BEFORE the background branch, so they carry NO
      // `details.background` — a refused `task({ background: true })` would then
      // fall through and `dispatchCount++`, satisfying the ≥1-dispatch gate for a
      // child that was never created. Read the tool INPUT too (the same dual
      // signal `verification-gate` uses), so every background result —
      // dispatched, refused, or halted — is recognised as background.
      const reviewInput = (event as { input?: { background?: boolean } }).input;
      const isTerminalCollect =
        event.toolName === "task_collect" && reviewDetails?.terminal === true;
      if (event.toolName !== "task_collect" && event.toolName !== "subagent" && event.toolName !== "task") return undefined;
      // #285 P2: task sub-agents never count dispatches — review DISPATCH is
      // parent-enforced (#825), and their own in-band [VGATE] dispatches must
      // not be counted/audited as review dispatches. (Today they never reach
      // this point: extensionEnabled was false; under P1-2b it stays true, so
      // this early return is what keeps the noise out.)
      if (isTaskSubAgent()) return undefined;
      if (!extensionEnabled) return undefined;
      if (event.toolName === "task_collect" && !isTerminalCollect) return undefined;
      // #1662 review: `task_collect` is idempotent — every result carries the
      // `run_id` it reaped (`details: view`). Count each run's verdict once, so
      // re-collecting a finished lane cannot inflate the dispatch total (and
      // the durable review_dispatch audit count) past the real dispatches.
      if (isTerminalCollect) {
        const collectRunId =
          typeof reviewDetails?.run_id === "string" ? reviewDetails.run_id : "";
        if (collectRunId) {
          if (countedCollectRuns.has(collectRunId)) return undefined;
          countedCollectRuns.add(collectRunId);
        }
      }

      // #2665: a spawn that produced NO VERDICT is an ATTEMPT, not a dispatch — classified BEFORE
      // the background early-return, because a REFUSED background spawn (`status:"invalid-cwd"`
      // with `background:true`, the #1662 shape) used to return as "no reviewers dispatched": the
      // capacity-read-as-compliance mislabel this change exists to remove. Before the split, the
      // counter below fired on ANY `task`/`subagent` result, so a retry-exhausted
      // (`status:"failed"`), cut (`killed:true`) or pre-spawn-refused child satisfied the
      // ≥1-dispatch floor and the lane's unreviewed `git push` was ALLOWED — a false PASS,
      // measured (see `shared/spawn-capacity.ts`). The classification reads ONLY fields the
      // producer set, and the evidence it read is carried into the audit row and the refusal.
      const spawn = classifySpawnOutcome({
        // A terminal `task_collect` result is a `TaskRunStatusView`: the CHILD's composed payload
        // sits at `view.details`, and the run's own `status`/`reason` sit at the top level. Read
        // BOTH (nested last, so the child's own `killed`/`exitCode` win), because classifying on
        // the view alone re-opened the same fail-open one path over (review of #2665): the
        // background status mapping reports a no-output `clean-empty` settle as `done`, so the
        // view said "done" while the child's details carried `exitCode:0` with no output — and
        // the FOREGROUND path already classifies that same shape as `cut`.
        details: isTerminalCollect
          ? {
              ...(reviewDetails as Record<string, unknown>),
              ...((typeof (reviewDetails as { details?: unknown })?.details === "object" &&
              (reviewDetails as { details?: unknown }).details !== null
                ? (reviewDetails as { details: Record<string, unknown> }).details
                : {}) as Record<string, unknown>),
            }
          : (reviewDetails as Record<string, unknown> | undefined),
        isError: (event as { isError?: unknown }).isError,
      });
      if (spawn.outcome !== "verdict") {
        spawnAttemptsTotal++;
        spawnAttempts.push({ tool: event.toolName, outcome: spawn.outcome, evidence: spawn.evidence });
        // Bounded ledger WITH CLASS COVERAGE (review of #2665): dropping the oldest entry
        // unconditionally let a breaker seen once age out of the window, after which a
        // breaker-plus-failures ledger printed the CAPACITY "retry under less load" remedy. Drop
        // the OLDEST entry whose class has a LATER duplicate, so every class that occurred
        // survives the window. (A first-match drop was wrong in the not-found case: it evicted
        // exactly the UNIQUE-class oldest the rule protects — measured [breaker, 11×failed].)
        if (spawnAttempts.length > SPAWN_ATTEMPT_KEEP) {
          let dropAt = -1;
          for (let i = 0; i < spawnAttempts.length - 1; i++) {
            const cls = attemptClass(spawnAttempts[i]);
            if (spawnAttempts.slice(i + 1).some((a) => attemptClass(a) === cls)) {
              dropAt = i;
              break;
            }
          }
          spawnAttempts.splice(dropAt >= 0 ? dropAt : 0, 1);
        }
        console.error(
          `[review-enforcer] ⚠️ Sub-agent spawn produced NO verdict (${spawn.outcome}: ${spawn.evidence}) — ` +
            `recorded as ATTEMPT ${spawnAttemptsTotal}, NOT counted as a dispatch (#2665)`
        );
        logGateEvent("review_spawn_no_verdict", {
          tool: event.toolName,
          outcome: spawn.outcome,
          evidence: spawn.evidence,
          spawn_attempts: spawnAttemptsTotal,
          dispatch_count: dispatchCount,
        });
        return undefined;
      }
      // #1662: a `task({ background: true })` dispatch returns at DISPATCH — counting it would
      // satisfy the ≥1-dispatch gate while the reviewer is still running. A verdict-less
      // background result was classified ABOVE (as an attempt); this guards the COUNTING only.
      if (reviewDetails?.background === true || reviewInput?.background === true) return undefined;

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
