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
 * line is cheaper than a spurious silence). `<<<` here-strings are not heredocs and are untouched.
 * Gating is unaffected: this is applied by `isPushOrPrCreateCommand` only, which no gate consults.
 */
export function stripHeredocBodies(command: string): string {
  const lines = command.split("\n");
  const out: string[] = [];
  for (let i = 0; i < lines.length; i++) {
    const open = /<<(-?)\s*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\2/.exec(lines[i]);
    if (!open) {
      out.push(lines[i]);
      continue;
    }
    const stripTabs = open[1] === "-";
    const word = open[3];
    // Keep the COMMAND line (the redirect is part of it), drop the body and the terminator.
    out.push(lines[i].slice(0, open.index) + lines[i].slice(open.index, open.index + open[0].length));
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

function scanTokens(command: string): ScanTokens {
  // bash removes a backslash-newline outright, so `g\<newline>h` is the command
  // `gh`. Do the same before tokenizing, or the continuation splits the name.
  // #1203: the mandated rail's own filename is neutralized BEFORE tokenizing, so
  // the path cannot supply the words `admin`/`merge` the verbs and flags are read
  // from. Length-preserving, so every offset below still addresses `command`.
  const joined = stripRepoArgs(withoutMandatedRailPath(command)).replace(/\\\r?\n/g, "");
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
const PR_NON_MERGE_SUBCOMMANDS = new Set([
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
  const lines = stdout.split("\n").filter((l) => l.length > 0);
  if (lines.length === 0) return null;
  const line = lines[lines.length - 1];
  const tab = line.indexOf("\t");
  if (tab < 0) return null;
  const status = line.slice(0, tab).trim();
  const hash = line.slice(tab + 1).trim();
  if (status !== "ok") return null;
  return isDiffSha256(hash) ? hash : null;
}

/**
 * The PR's live normalized three-dot diff digest, or null when it cannot be
 * computed. The repo is taken from the SAME resolved context the gate verified
 * the head through, and is RE-VALIDATED here (a `--repo` flag is user-controlled
 * text) before it reaches an argv element. Every failure — no repo, no helper,
 * no `gh`/`openssl`/`python3`, the 300-file cap, a network failure, a timeout —
 * returns null, which the gate reads as "no identity" and blocks on the head.
 */
export function getPrLiveDiffHash(pr: number, ctx: RepoContext): string | null {
  if (prDiffHashOverride !== null) return prDiffHashOverride(pr, ctx);
  const helper = resolveDiffHashHelper();
  if (helper === null) return null;
  const repo = ctx.repo ?? (ctx.cwd ? repoFromGitRemote(ctx.cwd) : null);
  if (!repo || !/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repo)) return null;
  try {
    // execFileSync, NOT a shell string: every argument is passed as an argv
    // element, so no value here can be re-parsed as shell syntax.
    const out = execFileSync("bash", [helper, "--print-diff-hash", String(pr), repo], {
      cwd: ctx.cwd,
      timeout: 60000,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    });
    return parseDiffHashHelperOutput(out);
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
        `current diff, so the verdict is CARRIED FORWARD on content identity) — allowing merge`,
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
  "   → NOTHING IN THE BLOCKED COMMAND RAN. A blocked tool call is a no-op: if it bundled a",
  "     sub-agent launch alongside the git op, the launch DID NOT HAPPEN (#1492). Verify the",
  "     artifact, never the send. The refused command is recorded in gate-events.jsonl.",
  "   → Read skills/code-review/SKILL.md for the review dispatch protocol (operations/skills/code-review/SKILL.md in consumer repos).",
  "   → Dispatch reviewers via task sub-agents, then retry the git operation.",
  // #2148: name the command the RAIL will demand, not just the missing action. A lane told only
  // "dispatch a reviewer" satisfies this gate and is then refused by the merge registry for lack of
  // an attestation — the second refusal needs a command, and this is the moment to hand it over.
  "   → A dispatch alone does not land the PR: the rail also needs the attestation at the FINAL head —",
  `      ${REVIEWER_PREFLIGHT_RECORD_CMD}`,
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
    // #2148 — the audience, resolved per FACTORY INSTANCE (a session's `KIND` is exported by its
    // launcher and never changes mid-session). See `reviewerRoleFor`.
    const reviewerRole = reviewerRoleFor();

    // ── session_start ──────────────────────────────
    pi.on("session_start", async (_event, _ctx) => {
      dispatchCount = 0;
      countedCollectRuns.clear();
      preflightInjected = false;
      earlyPushNoticePrinted = false;

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
            console.log("[review-enforcer] 🚫 Admin-merge evidence gate blocked");
            logGateEvent("merge_gate_block", {
              pr: adminPr,
              reason: "admin_merge_no_evidence",
              command: auditCommand(command), // #1492: the refused command, not just the reason
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
        const currentDiffHash =
          record && isDiffSha256(record.diff_sha256) &&
          currentHead !== null &&
          record.head_sha !== currentHead
            ? getPrLiveDiffHash(prNumber, ctx)
            : null;
        // #285 Fix C: the no-record block message is shape-aware (task
        // sub-agents get the "parent must record the review" variant).
        const result = evaluateMergeGate(
          prNumber, record, currentHead, ctx, isTaskSubAgent(), currentMergeBase, currentDiffHash
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
        logGateEvent("gate_block", {
          reason: "no_reviewers_dispatch",
          tier: "micro",
          command: auditCommand(command), // #1492: the refused command, not just the reason
        }); // #516: durable audit
        return { block: true, reason: MICRO_BLOCK_MESSAGE };
      }

      console.log("[review-enforcer] 🚫 Blocked — no reviewers dispatched");
      logGateEvent("gate_block", {
        reason: "no_reviewers_dispatch",
        tier: tier === "" ? "unlabeled" : tier,
        command: auditCommand(command), // #1492: the refused command, not just the reason
      }); // #516: durable audit
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
      if (reviewDetails?.background === true || reviewInput?.background === true) return undefined;
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
