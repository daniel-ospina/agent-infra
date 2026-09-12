import type { ExtensionAPI, ToolCallEvent, ToolCallEventResult, ToolResultEvent } from "@earendil-works/pi-coding-agent";
import { isToolCallEventType } from "@earendil-works/pi-coding-agent";
import { execSync } from "node:child_process";
import { relative, resolve, isAbsolute, join, dirname, basename, extname } from "node:path";
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync, existsSync, mkdirSync, unlinkSync, realpathSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { register } from "../shared/health.js";
import { appendJsonl } from "../shared/audit-log.js";
import { isPrintMode, argvAllowsTask } from "../shared/print-mode.js";
// #755 merge-scope subtraction. VALUE import of a nested sibling module — safe:
// pi's extension loader only auto-loads a directory's index.ts/index.js or its
// package.json#pi.extensions, so subtract-scope.ts is never registered as an
// extension on its own.
import {
  makeSubBundle,
  makeGitSubCtx,
  subtractCommitArm,
  subtractPushArm,
  SUBTRACT_SKIP_REASONS,
  type SubBundle,
  type SubAudit,
} from "./subtract-scope.js";
// ponytail: inlined from verification-gate-utils.ts — pi's extension loader treats every .ts in
// ~/.pi/agent/extensions/ as an extension and fails on a pure-helper module (no factory export).
// Do NOT re-extract to a sibling .ts; the directory+entry pattern (see main-worktree-guard) is the
// only way to split, and it's not worth it for 4 lines. See #5611. Encodes #5607's precedence.
export function resolveProjectRoot(blockedCwd: string | null, prompt: string): string {
  if (blockedCwd !== null) return resolve(blockedCwd);
  // ponytail: \S+ eats sentence punctuation — strip trailing dots so
  // "Project root: /path/to/repo." doesn't resolve to a nonexistent dir (#7470)
  const rootMatch = prompt.match(/Project root:\s*(\S+)/);
  if (rootMatch) return resolve(rootMatch[1].replace(/\.+$/, ""));
  // #7595: prefer the git root of cwd over raw cwd — repo-relative hashing and
  // bridge writes are anchored at the git root; a bare cwd base silently breaks them.
  return resolveGitRoot(process.cwd());
}

// #190: merge-root resolution with a wrong-root guard. The prompt's explicit
// `Project root:` is authoritative when it realpath-differs from the stashed
// block cwd (the dispatch targets a different worktree — the stale block
// context must not shadow it, or every proactive dispatch in worktree B would
// zero-merge against worktree A's stale state and recreate the blocked-until-
// auto-bypass loop). Returns { root, foreign } where foreign=true signals the
// caller to clear the stale lastBlockedFiles filter. Strict extraction (no
// resolveGitRoot(process.cwd()) fallback here): when the prompt has no root
// and no block context exists, resolveProjectRoot's own fallback applies.
export function resolveMergeRoot(blockedCwd: string | null, prompt: string): { root: string; foreign: boolean } {
  const rootMatch = prompt.match(/Project root:\s*(\S+)/);
  if (rootMatch) {
    const promptRoot = resolve(rootMatch[1].replace(/\.+$/, ""));
    if (blockedCwd !== null && normalizeWorktreeRoot(promptRoot) !== normalizeWorktreeRoot(blockedCwd)) {
      return { root: promptRoot, foreign: true };
    }
    return { root: promptRoot, foreign: false };
  }
  if (blockedCwd !== null) return { root: resolve(blockedCwd), foreign: false };
  return { root: resolveGitRoot(process.cwd()), foreign: false };
}

// #190: shared diff-scoping pre-filter for verifier PASS merges. When a block
// context exists, keep only files in the blocked diff (#5673). When the
// context is empty or foreign (wrong-root rebind), keep only files in the
// current staged diff OR already known in the registry (#38 known-path
// exemption) — prevents a full-repo-scan PASS from marking arbitrary files
// verified, on the plain-text, fail-open, AND JSON merge paths.
export function scopeFiles(
  files: string[],
  projectRoot: string,
  lastBlockedFiles: string[],
  known: { has(key: string): boolean } = new Set<string>()
): { kept: string[]; skipped: number } {
  const blockedSet = new Set(lastBlockedFiles);
  const normRoot = normalizeWorktreeRoot(projectRoot);
  let staged: Set<string> | null = null;
  const kept: string[] = [];
  let skipped = 0;
  for (const f of files) {
    const rel = normalizeRegistryPath(projectRoot, f);
    const key = compoundKey(normRoot, rel);
    // #38: known paths always merge (re-verification is authoritative) — a
    // stale lastBlockedFiles list (a previous block covering different files)
    // must NOT drop the update. Checked BEFORE the blocked-diff filter; the
    // filter only gates BRAND-NEW paths.
    if (known.has(key)) { kept.push(f); continue; }
    if (lastBlockedFiles.length > 0) {
      if (blockedSet.has(rel)) { kept.push(f); continue; }
      skipped++;
      continue;
    }
    // #755: the consumer path passes NO bundle — this scope feeds the
    // tool_result merge, not the gate, and there is no audit emit here. A
    // subtraction here would be a reachable, unaudited scope reduction.
    if (staged === null) staged = new Set(runStagedScope(projectRoot, null).files);
    if (staged.has(rel)) { kept.push(f); continue; }
    skipped++;
  }
  return { kept, skipped };
}

// ── Compound key helpers (#37) ───────────────────────
// Hash records are keyed on (worktree root + relative path), not just filename,
// to prevent cross-worktree collision: two worktrees in the same repo both
// contain "tortoise/sdk.py" → distinct entries. Uses "::" as a separator
// (illegal in macOS/Linux paths).

const COMPOUND_SEP = "::";

function compoundKey(worktreeRoot: string, relativePath: string): string {
  return `${worktreeRoot}${COMPOUND_SEP}${relativePath}`;
}

function parseCompoundKey(key: string): { root: string; path: string } | null {
  const sepIdx = key.indexOf(COMPOUND_SEP);
  if (sepIdx === -1) return null;
  return { root: key.substring(0, sepIdx), path: key.substring(sepIdx + 2) };
}

// Normalize worktree root for stable compound keys. macOS /var → /private/var
// symlinks must not produce different keys for the same directory.
function normalizeWorktreeRoot(root: string): string {
  try { return realpathSync(root); } catch { return root; }
}

// ── Types ────────────────────────────────────────────

interface VerifiedFile {
  path: string;
  hash: string;
}

interface VerificationResult {
  status: "PASS" | "FAIL";
  failures: string[];
  verified_files: VerifiedFile[];
}

// ── State ─────────────────────────────────────────────

const verifiedSet = new Map<string, string>(); // path → sha256 hash
let extensionEnabled = true;
let vgateFailures = 0;
const VGATE_FAILURE_THRESHOLD = 3;

// #561: ceremony-diagnostics state — the retried block message names the prior
// dispatch failure class + remedy + attempt count so a blocked agent fixes the
// dispatch instead of re-dispatching an identical verifier (6+ sub-agent run
// deaths, 2026-09-05/06 sweep). Classified per #132: DISPATCH-FORMAT classes
// (empty-content, no-text, unparseable, fail-open-refused) move dispatchStreak
// — messaging ONLY; this counter NEVER feeds any disable/bypass path (the
// vgateFailures latch and the #7591 auto-bypass keep their exact semantics).
// JUDGMENT (fail-verdict) and zero-merge-pass classes record the class for
// remedy text WITHOUT moving the streak (a FAIL is a successful dispatch; a
// zero-merge proves nothing about dispatch health). Any merged>0 dispatch
// resets both. Session-scoped (reset at session_start) — the streak dies with
// the process; durable state lives in the bridge + audit log.
type DispatchFailureClass = "empty-content" | "no-text" | "unparseable" | "fail-open-refused" | "fail-verdict" | "zero-merge-pass";
// #561 review r1 P2: narrow the streak-mover's API so a judgment class cannot
// type-check into the streak (the #132 invariant becomes compile-time).
type DispatchFormatClass = Exclude<DispatchFailureClass, "fail-verdict" | "zero-merge-pass">;
let lastDispatchClass: DispatchFailureClass | null = null;
let dispatchStreak = 0;
// ponytail: single-variable stash assumes one block→verify→merge flow per session turn.
// Pi sessions are separate Node processes (module state does not cross processes); within
// a session the agent loop is sequential. If concurrent verifier flows are ever needed, key by toolCallId.
let lastBlockedCwd: string | null = null;
let lastBlockedFiles: string[] = [];
// #7574: when VGATE allows a git commit, lint-staged (pre-commit hook) may modify files
// on disk (ESLint --fix). The stored verified hash is pre-lint, but the committed version
// is post-lint. Re-hash on the next git op to capture the post-lint state.
let pendingRehash: string | null = null;
// #190: the allowed commit's changed files — lint-staged can only have touched
// these; the rehash loop must NOT re-bless unrelated verified files from disk
// (narrowing #7574's whole-root rehash).
let pendingRehashFiles: string[] = [];
// #7591: auto-bypass after N persistent blocks on the same files.
// Tracks block attempts per file; resets when file is successfully verified.
const blockAttempts = new Map<string, number>();
const BLOCK_ATTEMPT_THRESHOLD = 3;
const BRIDGE_DIR = join(homedir(), ".pi", "agent", "verification");

// #825: true when this process is a builtin-tools TASK sub-agent (vs a bare
// headless `pi -p` or a swarm_daemon worker). builtin-tools sets BOTH
// PI_MODE=print AND TASK_HEARTBEAT=1 on task children (the task-heartbeat
// extension gates itself on exactly this pair); swarm_daemon workers set only
// PI_MODE=print, so isPrintModeEnv() alone would misclassify them — they have
// no parent session to report blocks to, and must keep the interactive
// dispatch message + #7591 auto-bypass (status quo). #264 review: builtin-tools
// sets TASK_HEARTBEAT=1 UNCONDITIONALLY on task children — even when the
// parent set TASK_HEARTBEAT_DISABLE=1 (the DISABLE flag only gates the
// task-heartbeat EMITTER, which that extension checks itself; it still flows
// to the child via the env spread). A task child can therefore NEVER fall
// back to the interactive path: #7591 auto-bypass is unreachable for
// sub-agent commits (#264 P2/P3).
// #483: EXPORTED so index.test.ts can pin the marker pair BEHAVIORALLY
// (constructed env objects) — pre-#483 the guard readFileSync'd this source
// and matched the literal text, so a cosmetic refactor (operand reorder,
// const extraction) failed it spuriously. The pair remains a cross-extension
// contract: review-enforcer's isTaskSubAgent and task-heartbeat's
// taskHeartbeatActive/orphanWatchdogActive read the same markers, and the
// three can't import each other (extension-loader constraint), so each pins
// the pair in its own suite. Only a semantic drift of the pair must fail.
export function isTaskSubAgent(
  env: Record<string, string | undefined> = process.env,
): boolean {
  // Env-param seam (mirrors task-heartbeat's taskHeartbeatActive): reads the
  // env via a parameter, never raw process.env — keeps the #228 print-mode
  // wiring gate (extensions/shared/print-mode-wiring.test.ts) green.
  return env.TASK_HEARTBEAT === "1" && env.PI_MODE === "print";
}

/**
 * #285 P1-1/P1-2b: refuse any path that would auto-DISABLE the gate for a
 * task sub-agent (the session_start escape hatch + the 3 vgateFailures
 * tool_result sites). Returns true when the bypass was REFUSED (task
 * sub-agent — plain-text WARN + durable audit, extensionEnabled stays true →
 * still blocking); false → the caller proceeds with its existing disable
 * behavior. Inlined module-level alongside isTaskSubAgent (extension-loader
 * constraint — no sibling helper file; see the ponytail note above).
 */
function refuseAutoBypassForSubAgent(): boolean {
  if (!isTaskSubAgent()) return false;
  console.warn("[verification-gate] ⚠️ Bypass refused for task sub-agent — VGATE stays ACTIVE (#285)");
  appendJsonl({ event: "gate_bypass_refused", extension: "verification-gate", subagent: true, session_cwd: process.cwd() });
  return true;
}

/**
 * #285 P1-A: task-tool-aware guidance for a refused bypass / a final block.
 * Task-capable sub-agents self-satisfy VGATE in-band (dispatch their own
 * [VGATE] verification and retry); task-RESTRICTED agents (--tools allowlists
 * without task — the 7 restricted user agents) cannot — the block is final,
 * they return to the parent session (which runs the verification ceremony and
 * will re-dispatch them). argv seam (default process.argv) keeps the e2e
 * deterministic.
 */
function subAgentProceedInstruction(): string {
  return argvAllowsTask()
    ? "To satisfy the gate, dispatch your own [VGATE] verification in-band via the task tool, then retry the git operation."
    : "STOP — this block is final; do not bypass; return to the parent session (it runs the verification ceremony and will re-dispatch you).";
}

function bridgePath(): string {
  return join(BRIDGE_DIR, "latest.json");
}

// ── #3255: worktree-aware root resolution ────────────────────────────────
// The git root of `process.cwd()` is the HUB whenever the session runs in the
// hub checkout and the change lives in a linked worktree — a bare `git push`
// with no `cd` prefix, or a task sub-agent started from the hub. Verification
// is dispatched with the WORKTREE as project root, so the bridge's compound
// keys are keyed on the worktree; the gate then hashes the hub's contents
// against worktree hashes, mismatches EVERY file, and blocks permanently — no
// verifier response can satisfy a comparison between two directories.
//
// `pickVerifiedRoot` is the pure decision (exported: unit-pinned). It returns a
// root to adopt ONLY when the cwd root has no verified entries and exactly one
// same-repo sibling does. Same-repo means a shared `--git-common-dir`, so an
// unrelated repository's entries can never be adopted; ambiguity (2+ siblings)
// falls back to the status quo, fail-closed like the rest of the gate.
export function pickVerifiedRoot(
  cwdRoot: string,
  roots: string[],
  commonDirOf: (root: string) => string | null,
): string | null {
  if (roots.length === 0) return null;
  const norm = normalizeWorktreeRoot(cwdRoot);
  if (roots.some((r) => normalizeWorktreeRoot(r) === norm)) return null; // own entries exist — status quo
  const mine = commonDirOf(cwdRoot);
  if (mine === null) return null;
  const siblings = roots.filter((r) => commonDirOf(r) === mine);
  return siblings.length === 1 ? siblings[0] : null;
}

function gitCommonDir(root: string): string | null {
  try {
    const out = execSync("git rev-parse --git-common-dir", {
      cwd: root,
      encoding: "utf-8",
      timeout: 3000,
    }).trim();
    // `--git-common-dir` is relative to the invocation cwd when not absolute.
    return out ? resolve(root, out) : null;
  } catch {
    return null;
  }
}

// Roots the bridge currently holds verified entries for.
export function bridgeRoots(): string[] {
  const bridge = readBridge();
  if (!bridge || bridge.status !== "PASS") return [];
  const roots = new Set<string>();
  for (const vf of bridge.verified_files) {
    const parsed = parseCompoundKey(vf.path);
    if (parsed) roots.add(parsed.root);
  }
  return Array.from(roots);
}

// Adopt a same-repo sibling root when the cwd root has nothing verified. Logs
// both paths so the mismatch is diagnosable from the transcript instead of
// presenting as an unexplained per-file hash failure (#3255).
function resolveWorktreeAwareRoot(root: string): string {
  const picked = pickVerifiedRoot(root, bridgeRoots(), gitCommonDir);
  if (picked === null) return root;
  console.log(
    `[verification-gate] ↔ #3255: no verified entries for ${normalizeWorktreeRoot(root)}; ` +
      `adopting ${picked} (same repo, has verified entries) as the git-op root`,
  );
  return picked;
}

function writeBridge(projectRoot: string, files: string[]): void {
  try {
    // #190 review: the bridge is a same-user trust channel — 0o700/0o600 so
    // other local users can neither read (absolute worktree paths + content
    // hashes) nor write it on shared hosts.
    mkdirSync(BRIDGE_DIR, { recursive: true, mode: 0o700 });
    const verifiedFiles: VerifiedFile[] = [];
    for (const f of files) {
      try {
        // #190: the bridge persists the FULL compound key (worktree-root::rel)
        // so recovery can be worktree-isolated (#37 property), and the
        // REGISTRY'S STORED hash — the verifier is the authority (#38), and a
        // disk re-hash at write time would let a post-PASS edit masquerade as
        // verified in the now-live bridge. Legacy plain-path entries fall
        // back to a disk hash (write-side safety only; recovery drops
        // non-compound entries fail-closed).
        const parsed = parseCompoundKey(f);
        if (parsed) {
          verifiedFiles.push({ path: f, hash: verifiedSet.get(f) ?? hashFile(parsed.root, parsed.path) });
        } else {
          verifiedFiles.push({ path: f, hash: hashFile(projectRoot, f) });
        }
      } catch {
        // #7595: one unhashable path (wrong root, deleted file) must not abort
        // the whole bridge write — before, a single failure silently left the
        // bridge stale and the next session recovered obsolete hashes.
      }
    }
    if (verifiedFiles.length === 0) {
      console.error("[verification-gate] bridge write skipped — no files could be hashed");
      return;
    }
    const payload = {
      status: "PASS",
      verified_files: verifiedFiles,
      timestamp: new Date().toISOString(),
    };
    writeFileSync(bridgePath(), JSON.stringify(payload), { mode: 0o600 });
  } catch (e) {
    console.error("[verification-gate] bridge write failed:", (e as Error).message);
  }
}

function readBridge(): { status: string; verified_files: VerifiedFile[] } | null {
  try {
    if (!existsSync(bridgePath())) return null;
    const raw = readFileSync(bridgePath(), "utf-8");
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

function clearBridge(): void {
  try { if (existsSync(bridgePath())) unlinkSync(bridgePath()); } catch { /* best-effort */ }
} // #5673: scope verifier to diff files, not full repo

// ── Bridge recovery (#190) ────────────────────────────
// The bridge is a cross-process recovery channel: any session/process that
// merges a PASS writes it (full-set snapshot of its verifiedSet). Recovery
// merges back only entries that (a) belong to the CURRENT worktree root
// (compound-key isolation, #37) and (b) whose STORED hash still matches disk
// (match-or-drop — never re-hash: a post-PASS edit must fail closed, not be
// re-blessed from disk). Stale/cross-root entries are inert, so the bridge
// is safe to leave in place across session shutdowns — clearBridge is NOT
// called on session_shutdown (a sub-agent's shutdown must not delete the
// parent's bridge; print-mode sub-agents fire session_shutdown on exit).
let lastRecoveryMtime = 0;
// #3255: the recovery cache must also key on WHICH root was recovered. A bare
// `git push` from a hub session resolves the hub root first and the worktree
// root later; without this the mtime guard would skip the second recovery and
// the verified entries would stay invisible for the rest of the session.
let lastRecoveredRoot = "";

function recoverBridgeForRoot(normRoot: string): number {
  try {
    const st = statSync(bridgePath());
    // Perf guard: skip when the bridge hasn't been written since our last
    // recovery — nothing new to recover (mtime granularity edge cases are
    // fail-closed: a skipped recovery just means a re-block + re-verify).
    if (st.mtimeMs <= lastRecoveryMtime && lastRecoveredRoot === normRoot) return 0;
    lastRecoveryMtime = st.mtimeMs;
    lastRecoveredRoot = normRoot;
  } catch {
    // No bridge (or unreadable) — nothing to recover. Corrupt JSON is
    // handled inside readBridge (returns null).
    return 0;
  }
  const bridge = readBridge();
  if (!bridge || bridge.status !== "PASS") return 0;
  let recovered = 0;
  for (const vf of bridge.verified_files) {
    try {
      const parsed = parseCompoundKey(vf.path);
      if (!parsed || parsed.root !== normRoot) continue; // foreign root — inert
      // #190 review: containment — an out-of-root rel (../) is inert against
      // the block check (git names are repo-relative) but hashFile would read
      // outside the root; drop such keys before hashing.
      const relPath = normalizeRegistryPath(parsed.root, parsed.path);
      if (relPath.startsWith("..") || isAbsolute(relPath)) continue;
      // Match-or-drop: only merge when the stored (verifier-authoritative)
      // hash still matches the file on disk (sha1 or sha256, #320). Never
      // recompute a fresh hash — a post-PASS edit must fail closed.
      if (!hashMatchesDisk(parsed.root, relPath, vf.hash)) continue;
      verifiedSet.set(vf.path, vf.hash);
      blockAttempts.delete(vf.path);
      recovered++;
    } catch {
      // Deleted/unhashable file — treat as no-match (fail-closed skip).
    }
  }
  if (recovered > 0) {
    console.log(`[verification-gate] 📂 Bridge recovery: merged ${recovered} verified files for this worktree`);
    // #190 review: audit parity with gate_bypass — a silent verifiedSet
    // injection must leave a durable record (the bridge is a same-user trust
    // channel; any recovery is worth an audit entry).
    appendJsonl({ event: "gate_recovery", extension: "verification-gate", recovered, session_cwd: process.cwd() });
  }
  return recovered;
}

// ── Git operation detection — shared verb-invocation scanner (#490 T2) ──
// Replaces the lookahead-mis-binding regex family (GIT_COMMIT_PATTERN /
// GIT_COMMIT_ONLY_PATTERN deleted here — the findGitVerbInvocation scanner
// below is the single source for both the INTERCEPTION surface (isGitOp /
// isGitCommit) and the classifier containment (findGitCommit → the P0 guard
// and the D2/sweep wrappers). #487 P0-guard coupling: findGitCommit stays a
// thin `{"commit"}` wrapper over the same scanner so containment can never
// drift from interception.
//
// Model: a git subcommand INVOCATION is `git` + zero or more GLOBAL options
// + a verb (commit/push/…). We scan for candidate `git` words (quote-UNAWARE
// `\bgit\b` — the legacy `(^|\s)git` anchor let quote/metachar-abutting git
// words slip, e.g. `sh -c 'git commit'`, `cd /repo&&git commit`; the \b scan
// is the interception-widening surface of #490 T2), then tokenize the text
// AFTER the candidate with a fresh bash-argv-style tokenizer (whitespace +
// unquoted `;&|()<>` split, backslash escapes + backslash-newline join,
// quoted regions = one token, a quote abutting accumulated chars ends the
// word so `commit'` normalizes to the verb `commit`). The first token that is
// not a global option must be the verb; anything else ends the candidate
// (git requires the subcommand directly after globals — `git status` is not
// a commit even if `commit` appears later).
//
// Global-option KIND table (atomic, head-anchored — git parses globals
// before the subcommand, so a candidate is only ever walking its own head):
//   session-value  — `-c <name>=<value>` EXACT (space form only; git rejects
//                    attached `-cNAME=VALUE` — verified "unknown option", so
//                    no attached arm) consumes ONE atomic value token. This
//                    closes the legacy mis-bind where the regex lookahead
//                    bound the VERB inside the `-c` VALUE
//                    (`git -c commit.gpgsign=false commit -m x` mis-parsed
//                    as a bare commit at the value's `commit` word → the
//                    real command was un-intercepted).
//   session-bool   — no-value globals (`--no-pager`, `-p`, `-P`, `--paginate`,
//                    `--bare`, `--no-replace-objects`, …) consume nothing.
//   redirect       — `-C <path>` / `--git-dir <d>` / `--work-tree <w>` /
//                    `--namespace <ns>` / `--super-prefix <p>` mark the
//                    invocation FOREIGN (its repo checkout differs from the
//                    session cwd — the hook cannot scope it). Space form
//                    consumes the ONE value token; ATTACHED `=` form
//                    (`--git-dir=/x`) carries its own value and consumes
//                    NOTHING (the value token follows independently).
//   unknown dash   — verb wins (next token IS the verb → treat as boolean);
//                    otherwise consume ONE following NON-dash token as its
//                    value (`--shallow-file /x`); a following dash token is
//                    never consumed (`git --no-color -c x=y commit` must not
//                    swallow the `-c` — the legacy regex backtracked here,
//                    the naive one-token heuristic would lose the verb).
//                    Attached `--foo=bar` unknowns carry their value and
//                    consume nothing. Mirrors the legacy regex's generic
//                    breadth for future git globals (no narrowing
//                    regression).
//
// FOREIGN boundary (the reason redirects are flagged, not aborted): the
// interception surface (isGitOp/isGitCommit — `foreignRedirect: "skip"`)
// treats a redirect as "this candidate targets another checkout" → skip it
// and keep scanning (a LATER cwd-scoped `git …` in the same command still
// fires; the -C/--git-dir/--work-tree ceremony spellings of the fixer loop
// and docs stay un-intercepted exactly as today — skills/code-review/
// references/fixer-loop.md L122/L130 rely on it). The CLASSIFIERS
// (findGitCommit and the push recognizers — `foreignRedirect: "tolerate"`)
// keep parsing past redirects so containment inside an already-gated command
// is unchanged: `git -C repo commit` IS a commit for the P0 guard, while the
// push recognizers treat a FOREIGN head push as scaffolding (a different
// checkout's push is not this scope's op — today's adjacency regexes
// classified it the same way).
// #204 review P2-1: gh's merge verb with the optional global -R/--repo flag
// between `gh` and `pr` — `gh -R owner/name pr merge 123` is a valid spelling
// and must route into the merge-scope path like the post-verb flag form.
const GH_PR_MERGE_VERB = /(?:^|\s)gh(?:\s+(?:--repo|-R)(?:=|\s+)[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)?\s+pr\s+merge(?=\s|$)/;

export interface GitVerbInvocation {
  /** byte offset of the candidate `git` word in the scanned text */
  index: number;
  /** byte offset AFTER the verb token (incl. a closing quote — callers slice the rest) */
  end: number;
  /** matched verb ("commit" | "push") */
  verb: string;
  /** a repo-redirecting global (-C/--git-dir/--work-tree/--namespace/--super-prefix) appeared */
  foreign: boolean;
}

type ForeignMode = "skip" | "tolerate";

// Exact-token match ONLY (space form). `-c` rejects attached values (verified).
const GIT_SESSION_VALUE = new Set(["-c"]);
// No-value git globals (cwd-neutral). Unknown dashes behave the same via the
// verb-wins heuristic; these are listed for documentation + exactness.
const GIT_SESSION_BOOL = new Set(["--no-pager", "-p", "-P", "--paginate", "--bare", "--no-replace-objects", "--no-replace-objects=1"]);
// Repo-redirecting globals → foreign invocation.
const GIT_REDIRECT = new Set(["-C", "--git-dir", "--work-tree", "--namespace", "--super-prefix"]);

function isSpaceChar(ch: string): boolean {
  return ch === " " || ch === "\t" || ch === "\n" || ch === "\r" || ch === "\f";
}

function isTokenSeparator(ch: string): boolean {
  return ch === ";" || ch === "&" || ch === "|" || ch === "(" || ch === ")" || ch === "<" || ch === ">";
}

interface ShellToken {
  /** decoded content (quotes stripped, escapes resolved) */
  content: string;
  /** byte offset of the first decoded char */
  rawStart: number;
  /** byte offset just past the token's last RAW char (incl. a trailing quote) */
  rawEnd: number;
}

// Read one bash-argv-style token starting at `from` (skipping separators/
// whitespace first). Bash word model: unquoted whitespace and the metachar
// set `;&|()<>` end a word; a backslash escapes the next char (a
// backslash-newline pair is dropped — line continuation); a quoted region is
// part of the current word with the quotes stripped; a quote that abuts
// accumulated chars ENDS the word so `commit'` (the closing quote of a
// wrapper like `sh -c 'git commit'`) normalizes to `commit`. Returns null at
// end of text.
function readShellToken(text: string, from: number, joinQuoted = false): ShellToken | null {
  const len = text.length;
  let p = from;
  while (p < len && (isSpaceChar(text[p]) || isTokenSeparator(text[p]))) p++;
  if (p >= len) return null;
  const rawStart = p;
  let content = "";
  let quote: string | null = null;
  while (p < len) {
    const ch = text[p];
    if (quote !== null) {
      if (ch === "\\") {
        if (p + 1 < len) { content += text[p + 1]; p += 2; continue; }
        p++; continue;
      }
      if (ch === quote) { quote = null; p++; if (!joinQuoted) break; continue; } // closing quote: default ends the word; joinQuoted continues (bash concatenation)
      content += ch; p++; continue;
    }
    if (ch === "'" || ch === '"') {
      if (content.length > 0) {
        if (joinQuoted) { quote = ch; p++; continue; } // bash: an abutting quote JOINS the current word (option values)
        p++; break; // quote abutting chars — end the word (verb normalization)
      }
      quote = ch; p++; continue;              // word starts with a quote
    }
    if (isSpaceChar(ch) || isTokenSeparator(ch)) break;
    if (ch === "\\") {
      if (p + 1 < len && text[p + 1] === "\n") { p += 2; continue; } // line continuation
      if (p + 1 < len) { content += text[p + 1]; p += 2; continue; }  // escaped char
      p++; continue;
    }
    content += ch; p++;
  }
  // EOF with an open quote or plain content: the accumulated word still flushes.
  if (content.length === 0 && rawStart === p) return null;
  return { content, rawStart, rawEnd: p };
}

// Head-anchored atomic scan: tokenize the text AFTER a candidate `git` word
// and walk the global-option table until the first non-option token. Returns
// the verb invocation (first match in scan order) or null. When
// foreignRedirect = "skip", a redirect abandons the candidate (continue
// scanning later candidates) — the interception surface must not fire on
// other-checkout invocations. When "tolerate", the candidate keeps parsing
// and the match carries `foreign: true` — classifier containment.
function findGitVerbInvocation(
  text: string,
  verbs: ReadonlySet<string>,
  foreignRedirect: ForeignMode,
): GitVerbInvocation | null {
  const gitWord = /\bgit\b/g;
  let searchFrom = 0;
  while (searchFrom <= text.length) {
    gitWord.lastIndex = searchFrom;
    const m = gitWord.exec(text);
    if (m === null || m.index === undefined) return null;
    const candStart = m.index;
    searchFrom = candStart + m[0].length; // resume AFTER this candidate if it yields nothing
    let foreign = false;
    let p = searchFrom;
    for (;;) {
      const tok = readShellToken(text, p);
      if (tok === null) break; // candidate exhausted without a verb
      p = tok.rawEnd;
      const t = tok.content;
      if (t.startsWith("-")) {
        if (t === "-c") { // session-value: consume the ONE atomic value token (bash word-concat — #490 T2)
          const val = readShellToken(text, p, true);
          if (val !== null) p = val.rawEnd;
          continue;
        }
        if (GIT_SESSION_BOOL.has(t)) continue;
        if (GIT_REDIRECT.has(t)) {
          foreign = true;
          const val = readShellToken(text, p, true); // space form consumes its value (bash word-concat — #490 T2)
          if (val !== null) p = val.rawEnd;
          if (foreignRedirect === "skip") break; // other checkout — abandon candidate
          continue;
        }
        // Redirect ATTACHED `=` form (`--git-dir=/x`, `--work-tree=/x`): value
        // embedded — consumes nothing, still foreign.
        if (t.includes("=") && (t.startsWith("--git-dir=") || t.startsWith("--work-tree=") || t.startsWith("--namespace=") || t.startsWith("--super-prefix="))) {
          foreign = true;
          if (foreignRedirect === "skip") break;
          continue;
        }
        // Unknown dash: verb wins; else consume ONE non-dash token; a dash
        // token is never a value (do not swallow a following -c). Attached
        // `=` unknowns carry their value and consume nothing.
        if (t.includes("=")) continue;
        // Verb-wins probe in DEFAULT mode: a verb is always a plain word, and the
        // default-mode quote-abutting rule terminates cleanly at a wrapper's
        // closing quote (`sh -c 'git --no-optional-locks commit' && git push` —
        // the quote ends the word, the verb matches, the candidate survives).
        // Join mode here would treat the closing quote as an opening
        // concatenation quote and swallow the rest of the command (P1, #490 T2 r3).
        const verbProbe = readShellToken(text, p);
        if (verbProbe === null) break;
        if (verbs.has(verbProbe.content)) continue; // verb wins → this dash is a boolean; CONTINUE so the next iteration returns the verb (break here abandoned the candidate — #490 T2 P1)
        if (verbProbe.content.startsWith("-")) { p = verbProbe.rawStart; continue; } // never a value — re-process the dash token next
        // Not the verb → it is the option's VALUE: consume it in join mode (bash
        // word-concatenation — an abutting quote is part of the value).
        const val = readShellToken(text, p, true);
        if (val === null) break;
        p = val.rawEnd;
        continue;
      }
      // First non-option token: must be the verb.
      if (verbs.has(t)) {
        return { index: candStart, end: tok.rawEnd, verb: t, foreign };
      }
      break; // non-verb positional (status/branch/…) — not an invocation
    }
    // Candidate yielded no invocation. Resume scanning AFTER the head region
    // this candidate consumed (its option names/values) — otherwise `\bgit\b`
    // re-scans inside option tokens like `--git-dir=/x` (the `git` inside the
    // option name is a word boundary) and fabricates a candidate whose globals
    // start mid-option.
    if (p > searchFrom) searchFrom = p;
  }
  return null;
}

const GIT_VERB_SET = { commit: new Set(["commit"]), push: new Set(["push"]), commitPush: new Set(["commit", "push"]) };

// findGitCommit — the thin `{commit}` wrapper over this scanner — lives with
// its detailed contract comment beside the containment consumers (~L1079).

const GH_PR_PATTERN = /(^|\s)gh(?:\s+(?:--repo|-R)(?:=|\s+)[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)?\s+pr\s+(create|merge)(?=\s|$)/;
// #540 M2 — create-only member of GH_PR_PATTERN. The gh+commit widening fires ONLY for
// `gh pr create` (the op that ships THIS branch's commits); `gh pr merge` merges REMOTELY
// and stays on the #204 merge-scope machinery (a local commit in the same command never
// widens a merge's branch scope — verb-anchored, symmetric with isMergeCommand).
const GH_PR_CREATE = /(^|\s)gh(?:\s+(?:--repo|-R)(?:=|\s+)[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)?\s+pr\s+create(?=\s|$)/;
// #7574: pendingRehash must arm only on COMMITS (lint-staged runs pre-commit,
// not pre-push). The commit-only scan below replaces GIT_COMMIT_ONLY_PATTERN;
// the cwd-neutral-global spelling (`git -c x=y commit`) now arms correctly
// (#490 T2).

export function isGitOp(command: string): boolean {
  // Interception surface: cwd-neutral invocations only (foreign redirects =
  // other checkouts — the hook cannot scope them; the -C ceremony of the
  // fixer loop stays un-intercepted). Env-form redirects (GIT_DIR=x git …)
  // are NOT git globals — the inline assignment precedes the candidate and
  // the invocation stays cwd-scoped exactly as today (status-quo pin).
  const git = findGitVerbInvocation(command, GIT_VERB_SET.commitPush, "skip");
  return git !== null || GH_PR_PATTERN.test(command);
}

export function isGitCommit(command: string): boolean {
  return findGitVerbInvocation(command, GIT_VERB_SET.commit, "skip") !== null;
}

// ── Content-shape exemption (#472 mechanism a) ───────
// Single source for the doc contract (01-preflight.md VGATE-SHAPE-RULE fence —
// index.test.ts drift test keeps the two in sync). Docs/CSS/static classes are
// exempt; ANY file under a build-output segment (public/ dist/ build/, any
// depth) is a GENERATED artifact and stays gated. Fail-closed: the class list
// is CLOSED — every other extension (and extension-less files: Dockerfile,
// LICENSE) keeps the gate ON. Case-insensitive match (path lowercased first —
// macOS default FS is case-insensitive); the doc fence tokens are lowercase
// (02-commit-pr.md Step 1.5), so lowercasing never diverges from them.
// Exact-segment match: `build-guide/` is NOT `build/` and stays exempt.
export const SHAPE_EXEMPT_EXTENSIONS: readonly string[] = [".md", ".css", ".scss", ".html"];
export const BUILD_OUTPUT_SEGMENTS: readonly string[] = ["public", "dist", "build"];

export function isShapeExemptFile(repoRelativePath: string): boolean {
  const lower = repoRelativePath.toLowerCase(); // macOS default FS is case-insensitive; repo path case is not normalized by git
  if (!SHAPE_EXEMPT_EXTENSIONS.includes(extname(lower))) return false;
  for (const segment of lower.split("/")) {
    if (BUILD_OUTPUT_SEGMENTS.includes(segment)) return false;
  }
  return true;
}

// ponytail: parse cd prefixes in bash commands so git ops in worktrees
// resolve to the correct repo root. pi's bash tool keeps process.cwd()
// unchanged even when the shell script starts with "cd /worktree &&".
// #204 review P2-2: the cd must sit at a REAL command boundary (start, or
// after &&/;/||/| — and a bare newline, which bash treats as a separator)
// — a `cd /tmp &&` sequence inside quoted prose (e.g. `--comment "see cd
// /tmp && x"`) must not poison the resolved cwd (a poisoned cwd fed the
// merge-scope repo/head comparison → false skip).
export function extractCdPath(command: string): string | null {
  // Quote-aware: mask quoted regions so a `cd /tmp &&` inside --comment/
  // --body prose can never anchor the separator scan (review #230 P2-3:
  // `gh pr merge 1 --comment "see; cd /tmp && x"` poisoned the cwd). A quoted
  // region that directly follows `cd ` is the cd ARGUMENT — preserved so
  // `cd "/path with spaces" && git …` still extracts.
  const masked = command.replace(
    /(["'])(?:\\.|(?!\1)[\s\S])*\1/g,
    (q: string, _quote: string, offset: number) => {
      const before = command.slice(Math.max(0, offset - 4), offset);
      return /cd\s+$/.test(before) ? q : " ".repeat(q.length);
    },
  );
  const m = masked.match(/(?:^|&&\s*|;\s*|\|\|\s*|\|\s*|\n\s*)\s*cd\s+(['"]?)([^;&|]+?)\1\s*(?:&&|;)/);
  return m ? resolve(m[2]) : null;
}

// ── Merge scope resolution (#204) ─────────────────────
// `gh pr merge` merges REMOTELY — the local checkout's `git diff
// origin/main...HEAD` is only meaningful when (a) the cwd repo IS the PR's
// repo AND (b) the checkout is on the PR head branch. In orchestrator flows
// both premises break: a session in repo A merging a PR in repo B (explicit
// --repo/GH_REPO or not), or a same-repo checkout sitting on a stale/wrong
// branch with unmerged residue. Blocking on that residue is a false block and
// (per #190) the drift files get blessed into verifiedSet + the bridge once a
// verifier dispatch resolves it — contaminating later sessions in the same
// worktree root. The skip path below returns BEFORE computeBranchDiff, so no
// changedFiles, no block, no verifiedSet/bridge writes: drift can never reach
// the registry or the recovery channel.
//
// Cross-repo is decidable WITHOUT gh/network: an explicit --repo/-R/GH_REPO
// names a repo; compare to the cwd origin (parsed from `git remote get-url
// origin`). With no flag/env, gh targets the cwd repo by construction →
// same-repo path. The head check (`gh pr view <n> --json headRefOid`) is the
// only network call and only fires on the same-repo path.
//
// ponytail: extractRepoFlag/extractGhRepoEnv/extractPrNumber are local copies
// of review-enforcer's helpers (extensions/review-enforcer/index.ts). A
// cross-extension import would couple the two extensions' independent load
// graphs — pi's loader compiles each extension as its own module (#5611) — and
// the regexes are tiny (rule of two: promote to extensions/shared/ when a
// third consumer appears). Keep them in sync with the review-enforcer source.

// #204 review P2-2: verb-anchored merge detection. GH_PR_PATTERN is a
// substring scan, so `gh pr create --body "run gh pr merge 42"` would match
// the merge verb inside quoted prose and route a CREATE into the merge-scope
// path (possibly skipping its branch-diff verification). Strip cd/&& prefixes
// and inline env assignments, then the command itself must START with
// `gh pr merge`. A chained merge (`gh issue create ... && gh pr merge 123`)
// is NOT anchored → fail-closed status-quo verify (old behavior, no skip).
export function isMergeCommand(command: string): boolean {
  const stripped = command
    .replace(/^\s+/, "")
    .replace(/^(?:cd\s+(?:['"][^'"]+['"]|[^\s;&|]+)\s*&&\s*)+/i, "")
    .replace(/^(?:[A-Za-z_][A-Za-z0-9_]*=\S+\s+)+/, "");
  // Anchored at ^ (with the optional global flag): the merge verb must be the
  // command's OWN first verb, never a substring in prose or a chained command.
  return /^gh(?:\s+(?:--repo|-R)(?:=|\s+)[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)?\s+pr\s+merge(?=\s|$)/.test(stripped);
}

// #204 review P2-1: return the merge command's OWN invocation text — from the
// last command separator before the merge verb through the next separator
// after it, with quoted strings removed. A `--repo`/`GH_REPO` belonging to a
// DIFFERENT command (chained with &&/;), or to quoted prose (e.g. `--comment
// "see --repo fake/x"`), must never decide this merge's scope — a false
// cross_repo would skip verification of a genuine same-repo merge. Keeps
// `GH_REPO=x ` prefixes and gh's global `-R owner/name` (no separator). A
// genuinely quoted flag VALUE (`--repo "a/b"`) degrades to no-match →
// fail-closed verify, never a skip.
export function mergeCommandWindow(command: string): string {
  const verb = command.match(GH_PR_MERGE_VERB);
  if (!verb) return command;
  const verbStart = verb.index ?? 0;
  const verbEnd = verbStart + verb[0].length;
  const sepRe = /&&|\|\||;|\n|\|/g;
  let segStart = 0;
  for (const m of command.slice(0, verbStart).matchAll(sepRe)) {
    segStart = (m.index ?? 0) + m[0].length;
  }
  const tail = command.slice(verbEnd);
  const tailSep = tail.search(sepRe);
  const tailEnd = tailSep === -1 ? tail.length : tailSep;
  return command.slice(segStart, verbEnd + tailEnd).replace(/"[^"]*"/g, " ").replace(/'[^']*'/g, " ");
}

// Priority 1: explicit --repo owner/name (or -R, or --repo=owner/name) flag.
/** Normalize a raw repo capture to exactly OWNER/REPO: strip a leading
 * [HOST/] segment (gh accepts GH_REPO=[HOST/]OWNER/REPO; --repo is
 * OWNER/REPO only). A value with >2 segments after host-stripping, or an
 * empty/garbage identity, yields null — fail-closed (review #230 P2-2: the
 * unanchored capture turned "github.com/owner/repo" into the garbage
 * identity "github.com/owner" and flipped same-repo merges into wrong
 * cross-repo skips). */
function normalizeRepoCapture(raw: string): string | null {
  const parts = raw.split("/").filter(Boolean);
  if (parts.length === 2) return parts.join("/");
  if (parts.length === 3) return `${parts[1]}/${parts[2]}`; // host/owner/repo
  return null; // 4+ segments — garbage identity, fail-closed
}

export function extractRepoFlag(command: string): string | null {
  // 2-3 segments: a HOST/ prefix must reach normalizeRepoCapture (the old
  // two-segment capture turned "github.com/owner/repo" into "github.com/owner").
  const m = command.match(/(?:--repo|-R)(?:=|\s+)([A-Za-z0-9_.-]+(?:\/[A-Za-z0-9_.-]+){1,3})/);
  return m ? normalizeRepoCapture(m[1]) : null;
}

// Priority 2: GH_REPO=owner/name env assignment prefix in the command.
export function extractGhRepoEnv(command: string): string | null {
  const m = command.match(/(?:^|\s)GH_REPO=([A-Za-z0-9_.-]+(?:\/[A-Za-z0-9_.-]+){1,3})/);
  return m ? normalizeRepoCapture(m[1]) : null;
}

// Extract the PR number from `gh pr merge <n>` (merge branch only). The number
// may sit before or after flags (`gh pr merge 123 --squash` and
// `gh pr merge --squash 123` are both valid gh spellings), so scan the token
// stream after the merge verb for the first pure-integer token — flag values
// (owner/name repos, quoted bodies) never tokenize as a bare integer.
export function extractPrNumber(command: string): number | null {
  const m = command.match(GH_PR_MERGE_VERB);
  if (!m) return null;
  const rest = command.slice((m.index ?? 0) + m[0].length);
  for (const token of rest.split(/\s+/)) {
    if (/^\d+$/.test(token)) return parseInt(token, 10);
  }
  return null;
}

// Parse owner/name from a git remote URL: GitHub SSH (git@github.com:o/n.git),
// ssh://git@ (colon form), HTTPS/git:// (https://github.com/o/n.git, incl.
// port or credentials). Host-agnostic on purpose — any host's owner/name is a
// valid identity for the cwd-repo comparison. Anything else (local paths,
// garbage, missing remote) → null → fail-closed to the same-repo path: an
// unparseable origin must never produce an accidental skip. Trailing .git/
// slashes are stripped and the result must be a valid owner/name shape, so
// cosmetic remote drift cannot yield a garbage identity.
export function repoNameFromRemote(url: string): string | null {
  const trimmed = url.trim();
  if (!trimmed) return null;
  const ssh = trimmed.match(/^(?:git@|ssh:\/\/git@)[^:]+:(.+)$/);
  const http = trimmed.match(/^(?:https?|git|ssh):\/\/[^/]+\/(.+)$/);
  const raw = (ssh ?? http)?.[1];
  if (!raw) return null;
  const clean = raw.replace(/\.git\/?$/, "").replace(/\/+$/, "");
  return /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(clean) ? clean : null;
}

// GitHub repo identity is case-insensitive and cosmetic `.git`/trailing-slash
// drift must never false-mismatch — normalize both sides of the comparison so
// a same-repo merge can never be skipped on repo-identity grounds.
function normalizeRepoName(repo: string | null): string | null {
  if (!repo) return null;
  return repo.toLowerCase().replace(/\.git\/?$/, "").replace(/\/+$/, "");
}

function isCrossRepo(cwdRepo: string | null, explicitRepo: string | null): boolean {
  const cwdRepoN = normalizeRepoName(cwdRepo);
  const explicitRepoN = normalizeRepoName(explicitRepo);
  return !!explicitRepoN && !!cwdRepoN && explicitRepoN !== cwdRepoN;
}

// Redact credentials from a command before it hits the audit log (the audit
// files are world-readable — an inlined GH_TOKEN=… must never persist).
function redactCommand(command: string): string {
  return command
    .replace(/\b(?:GH|GITHUB)_TOKEN=\S+/gi, "***")
    .replace(/ghp_[A-Za-z0-9]+/g, "ghp_***")
    .replace(/github_pat_[A-Za-z0-9_]+/g, "github_pat_***");
}

// #472: shared gate_skip audit — field shape identical to the #204 merge-scope
// skip (:1105) so all skip surfaces stay audit-synced (#60).
//
// #755: the reason union is DERIVED from one runtime constant so a live call
// site cannot be excluded by the type. Each literal is written in EXACTLY ONE
// place (duplicate array members are asserted against in Task 8's tripwire).
const MERGE_SCOPE_DECISION_REASONS = [
  "cross_repo",
  "head_mismatch",
  "same_repo_head_match",
  "same_repo_head_unknown",
] as const;
const GATE_SKIP_REASONS = [
  "push_range_empty",
  "delete_push_no_content",
  "content_shape_exempt",
  ...MERGE_SCOPE_DECISION_REASONS,
  ...SUBTRACT_SKIP_REASONS,
] as const;
export type GateSkipReason = (typeof GATE_SKIP_REASONS)[number];

function logGateSkip(reason: GateSkipReason, command: string, cwd: string, extra: Record<string, unknown> = {}): void {
  appendJsonl({
    event: "gate_skip",
    extension: "verification-gate",
    reason,
    session_cwd: process.cwd(),
    target_cwd: cwd,
    command: redactCommand(command),
    ...extra,
  });
}

export interface MergeScopeDecision {
  verify: boolean;
  reason: (typeof MERGE_SCOPE_DECISION_REASONS)[number];
}

// Pure merge-scope decision (review-enforcer evaluateMergeGate style — I/O
// separated so the 4-combo table is unit-testable).
//
//   explicitRepo | localHead vs prHead   | action
//   ------------ | -------------------- | -------------------------------
//   ≠ cwdRepo    | —                    | skip (cross_repo)
//   = (or none)  | == (worktree merge)  | verify (status quo, no regression)
//   = (or none)  | ≠ (stale checkout)   | skip (head_mismatch)
//   = (or none)  | prHead unknown       | verify (fail-closed)
//
// Fail-closed everywhere: unknown localHead OR prHead (gh/network failure) →
// verify (status quo); unparseable cwdRepo (null) can never produce a
// cross_repo skip on repo grounds.
export function evaluateMergeScope(
  cwdRepo: string | null,
  explicitRepo: string | null,
  localHead: string | null,
  prHead: string | null
): MergeScopeDecision {
  // GitHub repo identity is case-insensitive; cosmetic `.git`/trailing-slash
  // drift must never produce a false cross_repo skip (normalized comparison).
  if (isCrossRepo(cwdRepo, explicitRepo)) {
    return { verify: false, reason: "cross_repo" };
  }
  if (localHead !== null && prHead !== null && localHead !== prHead) {
    return { verify: false, reason: "head_mismatch" };
  }
  return {
    verify: true,
    reason: localHead !== null && prHead !== null ? "same_repo_head_match" : "same_repo_head_unknown",
  };
}

function originRemote(cwd: string): string | null {
  try {
    const out = execSync("git remote get-url origin", { encoding: "utf-8", cwd, timeout: 5000 }).trim();
    return out || null;
  } catch {
    return null;
  }
}

function localHeadSha(cwd: string): string | null {
  try {
    const out = execSync("git rev-parse HEAD", { encoding: "utf-8", cwd, timeout: 5000 }).trim();
    return out || null;
  } catch {
    return null;
  }
}

// Current PR head via gh. When the merge command resolved an explicit repo
// (--repo flag / GH_REPO= env), FORCE it with --repo — gh's own resolution
// (flag > GH_REPO env > cwd) could otherwise hijack the head check to a
// different repo when the session env carries a stale GH_REPO (review #230
// P1: wrong skip + the #190 drift-contamination vector re-opens). When no
// explicit repo, the head check and the actual merge inherit the same env,
// so they agree. Same shape as review-enforcer's getPrHeadSha. null on ANY
// failure (network, gh missing, 404) — fail-closed.
function getPrHeadSha(pr: number, cwd: string, explicitRepo?: string | null): string | null {
  try {
    const repoArg = explicitRepo ? ` --repo ${explicitRepo}` : "";
    const out = execSync(`gh pr view ${pr} --json headRefOid --jq .headRefOid${repoArg}`, {
      encoding: "utf-8",
      cwd,
      timeout: 15000,
    });
    const sha = out.trim();
    return sha || null;
  } catch {
    return null;
  }
}

// I/O orchestration for the hook: repo resolution + head fetch, returning the
// pure decision. Cross-repo short-circuits BEFORE any gh call (network-free).
export function resolveMergeScope(command: string, cwd: string): MergeScopeDecision {
  // Scan only the merge command's own invocation: a `--repo` in a quoted arg
  // or a chained command belongs to a different command and must not decide
  // this merge's scope (false cross_repo → skipped same-repo verification).
  const window = mergeCommandWindow(command);
  const explicitRepo = extractRepoFlag(window) ?? extractGhRepoEnv(window);
  const cwdRepo = repoNameFromRemote(originRemote(cwd));
  // Normalized comparison (case-insensitive, .git/trailing-slash tolerant) —
  // cross-repo is decidable without gh/network: short-circuit BEFORE the call.
  if (isCrossRepo(cwdRepo, explicitRepo)) {
    return { verify: false, reason: "cross_repo" };
  }
  const pr = extractPrNumber(window);
  const localHead = localHeadSha(cwd);
  const prHead = pr !== null ? getPrHeadSha(pr, cwd, explicitRepo) : null;
  return evaluateMergeScope(cwdRepo, explicitRepo, localHead, prHead);
}

// ── Delete-shaped push classification (#472 mechanism b) ──
// A remote-ref deletion (`git push origin --delete X` / `git push --delete
// origin X` / `git push origin :X`) ships NO local file content — a staged-diff
// check over a zero-byte deletion inspects the ENTIRE index and blocks on other
// sessions' parked WIP (the #470 cleanup incident). WHOLE-COMMAND purity:
// fires only when EVERY gated op in the command is a delete-shaped push; any
// content refspec, git commit, or gh pr create|merge anywhere falls back to
// today's gating (fail-closed).
//
// Deliberately narrower than a full bash lexer: the regex layer holding #5571
// heredoc / #204 prose edge cases is untouched; only this predicate parses, and
// only push-shaped segments it can prove pure.

// Quote-aware top-level split on real separators (&& || ; | \n AND single &
// — bash background operator: `a & git push origin main` backgrounds the first
// op and runs the content push; a single & can never appear inside a
// legitimate unquoted token, so flushing on it is safe and closes the
// fail-open where the content push after & was absorbed as a delete target).
// EXCEPTIONS (redirect syntax, NOT backgrounding): `&>` (ch followed by >) and
// `>&` (ch preceded by >, as in 2>&1) are redirects — no flush there; the
// redirect token is dropped later. Separators inside quotes are prose and never
// split. Backslash-newline continuations are handled INLINE in the non-quote
// path (no global pre-join) so the 05-cleanup literal `…2>/dev/null \` +
// newline + `|| echo …` yields one push segment + one non-gated echo segment
// AND a trailing `\` on a COMMENT line cannot swallow the next real line
// (bash terminates comments at the newline regardless of a trailing
// backslash — review P1-1).
function splitCommandSegments(command: string): string[] {
  const segments: string[] = [];
  let cur = "";
  let quote: string | null = null;
  const flush = () => { if (cur.trim()) { segments.push(cur); cur = ""; } };
  for (let i = 0; i < command.length; i++) {
    const ch = command[i];
    if (quote !== null) {
      cur += ch;
      if (ch === "\\" && i + 1 < command.length) { cur += command[++i]; continue; }
      if (ch === quote) quote = null;
      continue;
    }
    if (ch === "'" || ch === '"') { quote = ch; cur += ch; continue; }
    // #472 (plan D5 conformance): a `#` while OUTSIDE any quote and with only
    // whitespace accumulated since the last separator/newline starts a bash
    // full-line comment — pure scaffolding that must never poison the quote
    // scan (an apostrophe in "session's worktree" would otherwise open an
    // unterminated quote state and collapse real segments — the 05-cleanup
    // ceremony block). QUOTE-AWARE by construction: this branch is unreachable
    // while quote !== null, so a `#`-leading line INSIDE an open multi-line
    // string is data and keeps its closing quote (a blind pre-regex strip
    // deleted that quote and masked a real content push after a multi-line
    // value — review M1). Skip to end of line without flushing: nothing
    // executable can follow a comment on the same line in bash — the trailing
    // backslash of a comment line is INERT comment text (the newline
    // terminates the comment in real bash) and is consumed by this skip, so a
    // content line after a backslash-terminated comment is its own segment
    // (review P1-1); the real newline is processed by the "\n" branch below.
    if (ch === "#" && cur.trim() === "") {
      while (i + 1 < command.length && command[i + 1] !== "\n") i++;
      continue;
    }
    if (ch === "\\" && i + 1 < command.length && command[i + 1] === "\n") { i++; continue; } // inline backslash-newline continuation (join, no flush)
    if (ch === "\n") { flush(); continue; }
    if ((ch === "&" || ch === "|") && command[i + 1] === ch) { flush(); i++; continue; } // && ||
    if (ch === "&" && command[i + 1] === ">") { cur += ch; continue; } // &> redirect
    if (ch === "&" && i > 0 && command[i - 1] === ">") { cur += ch; continue; } // >& redirect (2>&1)
    if (ch === ";" || ch === "|" || ch === "&") { flush(); continue; } // ; | single-& background
    cur += ch;
  }
  flush();
  return segments;
}

// Strip cd/&& prefixes, inline env assignments, and command-prefix verbs
// (sudo/env/nohup/time/command) from a segment head — so a prefix-verb form the
// extension's interception patterns would still match (`sudo git push origin
// main`, `nohup git commit`) classifies identically to the bare form instead of
// being mis-treated as scaffolding. Loop until stable (cd chains + env + prefix
// verbs may combine).
function stripSegmentHead(segment: string): string {
  let s = segment.trim();
  for (let i = 0; i < 5; i++) {
    const next = s
      .replace(/^(?:cd\s+(?:['"][^'"]+['"]|[^\s;&|]+)\s*&&\s*)+/i, "")
      .replace(/^(?:(?:env|sudo|nohup|time|command)\s+)+/, "")
      .replace(/^(?:[A-Za-z_][A-Za-z0-9_]*=\S+\s+)+/, "");
    if (next === s) break;
    s = next;
  }
  return s;
}

// Quote-aware tokenizer for a push segment's argument text: keeps quoted
// values ("$BRANCH") as ONE token; strips the quote characters (D6).
function tokenizePushArgs(text: string): string[] {
  const tokens: string[] = [];
  let cur = "";
  let quote: string | null = null;
  const flush = () => { if (cur.length > 0) { tokens.push(cur); cur = ""; } };
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (quote !== null) {
      if (ch === "\\" && i + 1 < text.length) { cur += text[++i]; continue; }
      if (ch === quote) { quote = null; flush(); continue; }
      cur += ch;
      continue;
    }
    if (ch === "'" || ch === '"') { quote = ch; continue; }
    if (/\s/.test(ch)) { flush(); continue; }
    cur += ch;
  }
  flush();
  return tokens;
}

// Shell redirection token (2>/dev/null, 2>&1, >file, >>file). DROPPED
// anywhere in a push segment — a redirect is never a boundary and never a
// refspec.
function isRedirectToken(token: string): boolean {
  return /^(?:\d+)?(?:>>?|<<?|&>|>&)/.test(token);
}

// True when segment is `git … push` (cwd-scoped, head-anchored after
// stripSegmentHead; cwd-neutral globals like `-c x=y` / `--no-pager` between
// `git` and `push` are tolerated via the shared verb scanner — #490 T2
// mechanism d) whose args are a remote PLUS deletion forms ONLY. Requires an
// explicit ∃-deletion marker (D4) — bare `git push origin`
// (no marker) is NOT pure (vacuous-truth guard). Any other flag, a second
// remote, a bare content refspec, or an unknown shape → false (fail-closed).
// A redirect-global (`-C`/`--git-dir`/…) push is a DIFFERENT checkout's op →
// false (callers treat it as scaffolding).
function isPureDeletionPushSegment(segment: string): boolean {
  const stripped = stripSegmentHead(segment);
  const inv = findGitVerbInvocation(stripped, GIT_VERB_SET.push, "tolerate");
  if (inv === null || inv.index !== 0 || inv.foreign) return false;
  const rest = stripped.slice(inv.end);
  const tokens = tokenizePushArgs(rest);
  let sawRemote = false;
  let sawDeletionMarker = false;
  let sawDeleteFlag = false;   // --delete/-d seen (either position)
  for (const token of tokens) {
    if (isRedirectToken(token)) continue;
    if (token === "--delete" || token === "-d") { sawDeleteFlag = true; continue; }
    if (token.startsWith("-")) return false; // any other flag → fail-closed
    // :refspec deletion — marker must be a NON-EMPTY LITERAL ref name
    // (`:feat/x`, `:refs/heads/feat/x`). Bare `:` is git's matching-push
    // fallback that SHIPS CONTENT, and `:$VAR` can expand empty at runtime →
    // both return false (fail-closed; review P1). Only the blessed `--delete
    // "$BRANCH"` ceremony is variable-tolerant (empty → git errors, no push).
    if (token.startsWith(":")) {
      if (!/^:[A-Za-z0-9][A-Za-z0-9._/\-]*$/.test(token)) return false;
      sawDeletionMarker = true;
      continue;
    }
    if (!sawRemote) { sawRemote = true; continue; } // first non-flag = remote
    // Subsequent bare tokens are delete targets ONLY if a --delete flag was
    // seen; otherwise they are content refspecs → not pure.
    if (sawDeleteFlag) {
      // Review deep-P2 (delete-target absorption): an absorbed "delete target"
      // must be a SINGLE LITERAL shell word. Reject tokens carrying command
      // substitution / backtick residue (`$(git push origin main)`, backtick)
      // or quote-swallowed prose with whitespace/newline (an inline-comment
      // apostrophe after the push opens an unterminated quote that would
      // absorb a following content-push line into one target token). A real
      // content push hidden either way must keep the gate ON (fail-closed).
      // The blessed `--delete "$BRANCH"` ceremony token (`$BRANCH`) is a clean
      // single word and passes; ref names (feat/x, refs/heads/x, tags/v1.0)
      // pass.
      if (!/^[A-Za-z0-9_$@./:-]+$/.test(token)) return false;
      sawDeletionMarker = true;
      continue;
    }
    return false;
  }
  return sawRemote && sawDeletionMarker;
}

// Matches a `git … commit` subcommand invocation anywhere in a segment,
// tolerating git global options between `git` and `commit` (`-C repo`,
// `-c k=v`, `--no-pager`, `--git-dir=…`). Returns `{ index, end }` — the
// match's start offset AND the byte offset AFTER the `commit` verb (incl. a
// closing quote) — or null when the segment holds no commit invocation. Used
// by BOTH predicates as fail-closed containment — `git -C repo commit -am x`
// must register as a commit or the `-a` sweep rides the docs exemption
// (review P2-1). Head-anchored OR wrapper-prefixed: substring scan symmetric
// with the interception surface (the quote-UNAWARE `\bgit\b` candidate scan
// also catches `! git commit`, `sh -c 'git commit …'`, `sudo … git commit`;
// the shared scanner's containment can never drift from isGitOp — #490 T2
// single-source invariant). Callers decide how to treat offset: isDeletionPush
// only needs presence (`!== null`, any commit anywhere flips purity);
// isBareCommitShape requires a HEAD-ANCHORED match (`index === 0` —
// stripSegmentHead already normalized prefix verbs, so a nonzero offset means
// a wrapper/negation form that is not provably bare, resolution A).
function findGitCommit(stripped: string): { index: number; end: number } | null {
  const inv = findGitVerbInvocation(stripped, GIT_VERB_SET.commit, "tolerate");
  return inv === null ? null : { index: inv.index, end: inv.end };
}

// Whole-command purity (D5): true iff the command has ≥1 push op AND every
// gated op (a git commit|push invocation per the shared verb scanner; gh pr
// create|merge per GH_PR_PATTERN — INCLUDING the global -R/--repo spelling)
// is a delete-shaped push. Scaffolding segments (assignments, gh pr view, git
// branch -D, full-line comments, if/fi, $(…)) never flip purity — FULL-LINE
// `#` comments are stripped quote-aware in splitCommandSegments before this
// scan (an apostrophe in a comment must not open a quote state). An INLINE
// comment carrying a literal gated-verb string after real code (`echo hi #
// then: git commit -am x`) is not stripped and DOES flip purity: fail-closed,
// symmetric with the gate's own substring interception patterns (both see the
// raw text).
export function isDeletionPush(command: string): boolean {
  let sawPush = false;
  for (const segment of splitCommandSegments(command)) {
    const stripped = stripSegmentHead(segment);
    // CONTAINMENT BACKSTOP (fail-closed, symmetric with the interception
    // surface): the gate's interception + gh patterns are SUBSTRING scans —
    // they fire on `sh -c 'git commit …'`, `! git commit …`,
    // wrapper-prefixed forms etc. Head-anchored checks alone would treat such
    // wrapper segments as scaffolding and let mechanism (b) short-circuit a
    // command that really contains a commit/merge.
    //   1. gh pr create|merge anywhere (bare, -R/--repo, or wrapper) → false
    //   2. git commit anywhere (bare or wrapper) → false
    //   3. head-anchored cwd-scoped `git … push` → isPureDeletionPushSegment
    //      decides (the verb-scan tolerates cwd-neutral globals: `-c x=y`,
    //      `--no-pager` between `git` and `push` classify like the bare form)
    //   4. git push in a WRAPPER form → cannot prove purity → false
    //   5. git push behind a repo redirect (-C/--git-dir/…) → a DIFFERENT
    //      checkout's op — scaffolding, never this scope's purity (today's
    //      adjacency regexes classified it the same way)
    //   6. no gated verb → scaffolding, ignored (D5)
    const ghOp = /\bgh(?:\s+(?:--repo|-R)(?:=|\s+)[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)?\s+pr\s+(?:create|merge)\b/;
    if (ghOp.test(stripped)) return false;
    if (findGitCommit(stripped) !== null) return false;
    const pushInv = findGitVerbInvocation(stripped, GIT_VERB_SET.push, "tolerate");
    if (pushInv !== null) {
      if (pushInv.foreign) continue;        // other checkout's push — scaffolding (5)
      if (pushInv.index !== 0) return false; // wrapper push — not provably pure (4)
      sawPush = true;
      if (!isPureDeletionPushSegment(segment)) return false;
      continue;
    }
    // else: scaffolding — ignored (D5)
  }
  return sawPush;
}

// ── D2 commit-form guard (FORALL semantics + fail-closed whitelist) ──
// A docs/CSS/static exemption may apply to an op only when EVERY `git commit`
// invocation in the command is a BARE commit (explicit `git add` + `git
// commit`, no -a/--all/--amend/pathspec, per 02-commit-pr.md Step 1);
// non-commit gated ops (push, gh pr create/merge) qualify on file shape
// alone — isBareCommitShape is vacuously true when no commit invocation
// exists (e2e scenarios 39/39b/47 pin the push/pr-create/pr-merge
// exemptions). FORALL: if ANY commit invocation is non-bare, the whole
// command is non-bare.
//
// FAIL-CLOSED MODEL: instead of modeling every git flag (bundles, -a/-o/-i
// sweeps, attached values), the guard ALLOWS only a small whitelist of benign
// exact tokens and REJECTS everything else (→ VGATE runs → safe direction).
const BARE_COMMIT_VALUE_FLAGS = new Set(["-m", "-F", "-C", "-c"]);
const BARE_COMMIT_VALUE_LONG = new Set(["--message", "--file", "--reedit-message", "--reuse-message"]);
const BARE_COMMIT_BOOLEAN = new Set(["-s", "-S", "-q", "-v", "-e", "-n", "--signoff", "--no-verify", "--no-edit", "--edit", "--quiet", "--verbose"]);

export function isBareCommitShape(command: string): boolean {
  for (const segment of splitCommandSegments(command)) {
    const stripped = stripSegmentHead(segment);
    // CONTAINMENT (fail-closed): wrapper-prefixed commits count as commit
    // segments (the shared scanner is symmetric with the interception surface)
    // so the -a sweep can never ride a docs-only staged set to an exemption.
    const commitMatch = findGitCommit(stripped); // head-anchored OR global-flag form — fail-closed containment (review P2-1)
    if (commitMatch === null) continue;          // no commit invocation → vacuous segment
    // HEAD-ANCHORED ONLY (review resolution A): stripSegmentHead already
    // normalizes prefix verbs (sudo/env/nohup/time/command), so a match at
    // index 0 IS the real command head — `git -C repo commit -m x` is a bare
    // commit and may parse. A match at offset > 0 means a wrapper/negation
    // prefix (`bash -c 'git commit …'`, `sh -c '…'`, `! git commit …`,
    // `sudo -u me git commit …` — the -u arg is not stripped) — not provably
    // bare → VGATE runs (fail-closed, plan: wrapper form never exempt).
    if (commitMatch.index !== 0) return false;
    const rest = stripped.slice(commitMatch.end);
    const tokens = tokenizePushArgs(rest);
    let afterDashDash = false;
    for (let i = 0; i < tokens.length; i++) {
      const tok = tokens[i];
      if (afterDashDash) return false;               // pathspec after -- → non-bare
      if (tok === "--") { afterDashDash = true; continue; }
      if (tok.startsWith("--")) {
        if (BARE_COMMIT_VALUE_LONG.has(tok)) { i++; continue; } // consume value
        if (BARE_COMMIT_BOOLEAN.has(tok)) continue;
        return false; // unknown long → non-bare (fail-closed)
      }
      if (tok.startsWith("-")) {
        if (BARE_COMMIT_VALUE_FLAGS.has(tok)) { i++; continue; } // -m x: consume value
        if (BARE_COMMIT_BOOLEAN.has(tok)) continue;
        // Any OTHER single-dash token (-a, -am, -am"x", -mx, -o, -i, …) is
        // REJECTED: may be a sweep, pathspec mode, or attached-value spelling.
        return false;
      }
      // Review 2a-2 (adjudicated — NOT fixed): a trailing bash comment
      // (`git commit -m x # docs WIP`) reads its words as pathspecs → non-bare
      // → VGATE runs. That is fail-closed friction ONLY, and a #-break fix
      // opened two fail-open spellings (quoted `"#file"` pathspec; a
      // backslash-continued line after an inline comment swallowing a real
      // second command — bash ends comments at the REAL newline). Reverted:
      // fail-closed beats friction-free (documented known over-gate).
      return false; // bare positional token = pathspec → non-bare
    }
  }
  return true; // no commit segment, or every commit bare → guard satisfied
}

// ── #489 — auto-sweep commit classification (diff-scope mirror of the D2 guard) ──
// isBareCommitShape decides the content-shape EXEMPTION; commitSweepClass decides the
// DIFF SURFACE. `git commit -a` / `--all` record the tracked WORKING TREE, not just the
// staged index — a gate scoped to `git diff --cached` lets a staged-docs verifier PASS
// unlock a commit that then sweeps dirty, never-verified code (the #489 hole). Values:
// "sweep" (every head-anchored commit invocation in the command sweeps → hook diffs
// `git diff HEAD`, exactly what the sweep records); "mixed" (≥1 sweep + ≥1 non-sweep
// head-anchored invocation → hook verifies staged ∪ worktree — the non-sweep commit
// records index-only content invisible to a WT-only scope); "none" (no sweep — staged/
// index scope unchanged, #489 T2). Token model mirrors git's parser: required-value
// shorts m/F/C/c/t consume rest-of-cluster or the NEXT token (even dash-leading —
// `git commit -m --amend` is message "--amend", not an amend); optional-value shorts S/u
// consume ATTACHED cluster chars only, never the next token (`-Sa` = gpg keyid a,
// `-uall` = untracked mode all — neither sweeps; `-S -a` DOES sweep); required-value
// longs consume the next token; scanning continues past positional/pathspec and unknown
// tokens — only `--` (pathspec terminator) and end-of-stream end flag parsing. The
// head-anchor gate is now the scanCommitCommandAgg walker (#539): PROVABLY-executing
// wrapper/negation/quoted-env prefixes are peeled and the payload re-run through the
// full segment pipeline (the #489 wrapper/negation/prose "none" carve-out is closed
// for the sh/bash -c / ! / eval / quoted-env families — scanCommitSegmentText below);
// repo-redirecting globals (`-C`/`--git-dir`/`--work-tree`) stay
// recognized-but-un-gated BY DESIGN post-#490: a `-C` commit targets another
// checkout whose files this root must never verify (cwd-neutral env/-c/--no-pager
// spellings ARE intercepted via the shared scanner — closed #490).
export type CommitSweepClass = "sweep" | "mixed" | "none";

// #489/#538 SHARED token model: required-value LONG options on `git commit` — each
// consumes the NEXT token as its value (even dash-leading: `git commit --message -a` is
// a bare commit with subject "-a"). --encoding is NOT a git commit option (verified
// empirically: "error: unknown option `encoding'") and must NOT be added — a
// wrongly-included boolean would skipNext over a real `-a` → false negative. Shared by
// BOTH post-verb scanners (sweep + WT-path) so the git option-value model can never
// drift between them (#538).
const COMMIT_VALUE_LONGS = new Set([
  "--message", "--file", "--reedit-message", "--reuse-message", "--author",
  "--date", "--template", "--cleanup", "--fixup", "--squash", "--trailer",
  "--pathspec-from-file",
]);

// Scan ONE commit invocation's post-verb token stream for BOTH diff-scope signals,
// mirroring git's option parser token order. Required-value shorts m/F/C/c/t consume
// rest-of-cluster or the NEXT token; optional-value shorts S/u consume ATTACHED cluster
// chars only (never the next token); required-value longs (COMMIT_VALUE_LONGS) consume
// the next token; scanning continues past positional/pathspec + unknown tokens — only
// `--` (pathspec terminator) and end-of-stream end flag parsing. A positional token IS a
// pathspec (git commit takes no non-path positional argument); after `--` every
// remaining token is a pathspec. Callers: commitSweepClass reads .sweep (#489 — the
// full-tree `-a`/`--all` auto-sweep); wtPathCommitInfo reads .pathspecs/.pathspecFromFile
// (#538 — the named-path WT-commit forms).
interface CommitInvocationScan {
  sweep: boolean;             // `-a` short char (bundle member: -am, -vam, -qa, ...) or `--all`
  pathspecs: string[];        // positional tokens — the NAMED pathspecs (globs verbatim)
  pathspecFromFile: boolean;  // --pathspec-from-file (space OR `=` spelling) — names live in a file
}
function scanCommitInvocation(rest: string): CommitInvocationScan {
  const tokens = tokenizePushArgs(rest);
  const res: CommitInvocationScan = { sweep: false, pathspecs: [], pathspecFromFile: false };
  let skipNext = false;
  let afterDashDash = false;
  for (let i = 0; i < tokens.length; i++) {
    const tok = tokens[i];
    if (skipNext) { skipNext = false; continue; }
    if (afterDashDash) { res.pathspecs.push(tok); continue; } // everything after `--` is a pathspec
    if (tok === "--") { afterDashDash = true; continue; }
    if (tok === "--all") { res.sweep = true; continue; }
    if (tok.startsWith("--")) {
      if (tok === "--pathspec-from-file") { res.pathspecFromFile = true; skipNext = true; continue; }
      if (tok.startsWith("--pathspec-from-file=")) { res.pathspecFromFile = true; continue; }
      if (COMMIT_VALUE_LONGS.has(tok)) skipNext = true; // required-value long consumes next token
      continue;                              // boolean/unknown longs are not sweep/pathspec forms
    }
    if (tok.startsWith("-") && tok.length > 1) {
      for (let j = 1; j < tok.length; j++) {
        const c = tok[j];
        if (c === "a") res.sweep = true;     // -a sweep (latch — keep scanning the cluster)
        if (c === "m" || c === "F" || c === "C" || c === "c" || c === "t") {
          // required-value short: attached rest is the value; bare form takes the NEXT token
          if (j + 1 < tok.length) break;
          skipNext = true;
          break;
        }
        if (c === "S" || c === "u") {
          // optional-value short: consumes ATTACHED rest only (`-Sa` keyid a, `-uall` mode)
          break;
        }
        // booleans (e/i/n/o/q/s/v) and unknown chars: continue scanning the cluster
      }
      continue;
    }
    // positional token — a NAMED pathspec (git permutes options and positionals, so
    // keep scanning for flags AFTER a positional too)
    res.pathspecs.push(tok);
  }
  return res;
}

// ── #539 — wrapper/negation/quoted-env commit invocation normalization ──
// #489/#538 classify ONLY head-anchored commit invocations. stripSegmentHead
// normalizes prefix verbs + cd&& + UNQUOTED env assignments but NOT the
// wrapper/negation/quoted-env families, so a real executed sweep hides at
// index > 0 and classifies "none" → staged scope → with staged docs verified
// the wrapper's `-a`/`--all` sweep ships dirty never-verified code (the #489
// hole, empirically confirmed for every family below). This residual (named in
// the #538 scoping table) is closed HERE, in the COMMIT classifiers only:
// isDeletionPush / parsePushRefSpecs / isBareCommitShape keep stripSegmentHead
// byte-identical — the #472 plan doc pins `GIT_SSH_COMMAND="ssh -o
// BatchMode=yes" git push origin --delete foo` as a documented no-fix over-gate
// (quoted env values must stay OPAQUE to the push purity decision).
//
// Wrapper model — scanCommitCommandAgg drives BOTH classifiers over a shared
// per-invocation scan. For each segment, normalizeCommitSegment normalizes the
// head (quote-aware env peel + cd&&/prefix verbs, WITHOUT stripSegmentHead's
// env regex which mangles quoted values), then unwrapExecutingHead peels
// PROVABLY-executing prefixes (true command position only — prose segments
// never unwrap) and re-runs the peeled payload through the FULL segment
// pipeline: a `-c` payload / eval arg is parsed by a shell, so nested
// separators (`sh -c 'a && git commit -am x'`) execute and must split again.
// Peel families (each bounded by the depth cap below):
//   1. `! cmd` negation — the pipeline after ! IS executed (status inverted).
//   2. shell -c payload — bash/sh/zsh/dash/ksh (path-qualified basename,
//      SHELL_INTERPRETERS parity with main-worktree-guard's classifier) plus
//      no-arg option clusters: the command string is the NEXT argv word after
//      a cluster containing c (`-c`, `-ce`, `-ec`, `-cae`, `-cx` … —
//      empirically the payload is always the next WORD, never cluster text:
//      chars after c are ordinary options that still apply; `bash -cecho hi`
//      errors on the trailing -o before running anything, so a value-taking
//      char in the cluster stays unprovable → no unwrap); trailing words are
//      $0.. positional params and never execute → cut (no ghost sweeps from
//      arg text). Long options with values (--rcfile/--init-file) are consumed
//      and scanning continues (they never move the -c position); a value-taking
//      SHORT char (bash -O, zsh/ksh -o) makes the -c position unprovable → no
//      unwrap. A script-file / -s / stdin shell (no -c) never unwraps.
//   3. `eval args` — the builtin concatenates its argv words (quotes already
//      stripped by the outer shell) with spaces and parses+executes the
//      result → content-join and re-run.
//   4. quoted env prefixes — `FOO="bar baz" git commit -am x`: the executed
//      git sits at the true head once the assignment peels.
// Anything unprovable (script shells, option-carrying sudo/env, prose,
// nested repo-switching payloads — see wrapperPayloadSwitchesRepo) falls
// through to today's fail-closed handling (unparsed wrapper commit →
// non-sweep; coexisting sweep → "mixed" — the #489 round-2 reviewer
// finding, preserved verbatim).
const SHELL_C_INTERPRETERS = new Set(["bash", "sh", "zsh", "dash", "ksh"]);
// No-arg option-cluster chars allowed BEFORE a trailing -c (bash -lc / -ec /
// -xec / -aec / -Cec … → the NEXT token is the command string). UNION of the
// shells' no-value short startup options (bash -a -b -C -e -f -h -i -l -m -n -p
// -r -s -t -u -v -x -c; dash/zsh/ksh subsets). VALUE-taking options are
// deliberately absent — bash -O takes a value and zsh/ksh -o take a value — a
// value-taking char in the cluster makes the -c position unprovable → no
// unwrap (documented residual). LONG options are handled separately below:
// --rcfile/--init-file consume their value word and scanning CONTINUES (they
// do not move the -c position — `bash --rcfile /dev/null -c '…'` still runs
// the payload); other no-value longs are skipped.
const SHELL_C_CLUSTER_NOARG = new Set(["c", "a", "b", "C", "e", "f", "h", "i", "l", "m", "n", "p", "r", "s", "t", "u", "v", "x"]);
// cd&& chains + prefix-verb strip — stripSegmentHead minus its env regex (the
// classifier's env peel must run FIRST so quoted values are never mangled).
// Prefix verbs: env/sudo/nohup/time/command (stripSegmentHead parity) PLUS exec
// — `exec git commit -am x` replaces the shell with the git command, so the
// sweep executes (review cycle-3 P0); bare exec with only a redirect (`exec
// 3<f`, `exec >log`) leaves a non-git remainder → vacuous, harmless.
const COMMIT_SEGMENT_HEAD = /^(?:cd\s+(?:['"][^'"]+['"]|[^\s;&|]+)\s*&&\s*)+|^(?:(?:exec|env|sudo|nohup|time|command)\s+)+/;

// Peel ONE bash env-assignment prefix (`NAME=value`), quote-aware: the value is
// the REST OF THE BASH WORD — quoted regions ('…' verbatim; "…" honoring \"
// escapes) and unquoted chars concatenate (`FOO="x"bar` → FOO=xbar;
// `FOO='it'\''s'` → FOO=it's) and the word ends at the first UNQUOTED
// whitespace. Returns the text AFTER the assignment + trailing whitespace, or
// null when the head is not an assignment or the assignment consumes the whole
// text (a bare `FOO=bar` runs no command). ⛔ The whole-word scan is REQUIRED,
// not a nicety: pre-#539 stripSegmentHead's `NAME=\S+` regex stripped the
// no-space concat form (`FOO="x"bar git commit -am x` → head-anchored sweep),
// so peeling only clean-boundary values would REGRESS that form to a wrapper.
function stripEnvAssignmentPrefix(s: string): string | null {
  const n = s.length;
  let i = 0;
  if (i >= n || !/[A-Za-z_]/.test(s[i])) return null;
  i++;
  while (i < n && /[A-Za-z0-9_]/.test(s[i])) i++;
  if (i >= n || s[i] !== "=") return null;
  i++;
  if (i >= n) return null;
  // Value: the rest of the bash word, quote-aware, until unquoted whitespace.
  while (i < n) {
    const c = s[i];
    if (c === "'") {
      i++;
      while (i < n && s[i] !== "'") i++;
      if (i >= n) return null; // unterminated quote — not a clean assignment
      i++;
      continue;
    }
    if (c === '"') {
      i++;
      while (i < n && s[i] !== '"') {
        if (s[i] === "\\" && i + 1 < n) i += 2;
        else i++;
      }
      if (i >= n) return null;
      i++;
      continue;
    }
    if (c === "\\" && i + 1 < n) {
      i += 2; // escaped char — part of the value
      continue;
    }
    if (/\s/.test(c)) break;
    i++;
  }
  if (i >= n) return null; // assignment consumed the whole text — no command follows
  while (i < n && /\s/.test(s[i])) i++;
  const rest = s.slice(i);
  return rest.length === 0 ? null : rest;
}

function stripEnvAssignmentPrefixes(s: string): string {
  for (let i = 0; i < 16; i++) {
    const next = stripEnvAssignmentPrefix(s);
    if (next === null) break;
    s = next;
  }
  return s;
}

// Segment-head normalization for the COMMIT classifiers: stripSegmentHead-
// equivalent (cd&& chains + prefix verbs) BUT with the env assignment handled
// quote-aware BEFORE the regexes — stripSegmentHead's `NAME=\S+` regex consumes
// `FOO="bar ` out of `FOO="bar baz" git …` and leaves a mangled `baz" git …`
// head (the #539 quoted-env-hidden variant). Fixpoint so env heads REVEALED by
// prefix-verb stripping (`sudo FOO="x y" git commit …`) peel next iteration.
function normalizeCommitSegment(segment: string): string {
  let s = segment.trim();
  for (let i = 0; i < 6; i++) {
    const before = s;
    s = stripEnvAssignmentPrefixes(s);
    s = s.replace(COMMIT_SEGMENT_HEAD, "");
    if (s === before) break;
  }
  return s;
}

// A peeled payload whose executed text can switch the repo the commit runs in
// (a nested `cd` command at a command boundary, or a repo-redirecting git
// global at a command boundary) is a DIFFERENT checkout — this hook can only
// scope the session cwd (#490 foreign boundary). Refuse the unwrap so the
// segment keeps today's fail-closed wrapper handling instead of WT-scoping
// THIS repo for a commit that runs in ANOTHER. BOTH arms are command-boundary
// anchored (start / after ; & | newline) so prose that merely MENTIONS the
// words (`echo "use git -C to switch"`, a message arg) never refuses the
// unwrap and hides a REAL sweep in the same payload (review cycle-4 P1).
function wrapperPayloadSwitchesRepo(payload: string): boolean {
  if (/(?:^|[;&|\n]+)\s*cd(?=\s|$)/.test(payload)) return true;
  return /(?:^|[;&|\n]+)\s*git\b[^;&|\n]*(?:\s-C\b|--git-dir|--work-tree|--namespace|--super-prefix)/.test(payload);
}

// Peel PROVABLY-executing wrapper prefixes from a normalized segment head and
// return the payload text to re-run through the FULL pipeline, or null when
// the head is not a provably-unwrappable wrapper. Depth-bounded loop so
// wrapper chains compose (`! eval "bash -c 'git commit -am x'"`); a peel that
// hits an unprovable or repo-switching payload aborts the WHOLE unwrap (null)
// → today's unparsed-wrapper handling.
function unwrapExecutingHead(text: string): string | null {
  let cur = text;
  let peeledAny = false;
  for (let depth = 0; depth < 6; depth++) {
    const head = readShellToken(cur, 0);
    if (head === null) break;
    // (1) `!` negation — the following pipeline executes (exit status inverted).
    if (head.content === "!" && /\s/.test(cur[head.rawEnd] ?? " ")) {
      cur = cur.slice(head.rawEnd).trim();
      peeledAny = true;
      continue;
    }
    // (2) eval — concatenates its argv words with spaces, then parses+executes.
    if (head.content === "eval") {
      const words: string[] = [];
      let p = head.rawEnd;
      for (;;) {
        const w = readShellToken(cur, p);
        if (w === null) break;
        words.push(w.content);
        p = w.rawEnd;
      }
      if (words.length === 0) break; // bare `eval` — no-op
      const joined = words.join(" ");
      if (wrapperPayloadSwitchesRepo(joined)) return null;
      cur = joined;
      peeledAny = true;
      continue;
    }
    // (3) shell interpreter -c payload.
    const base = head.content.slice(head.content.lastIndexOf("/") + 1);
    if (SHELL_C_INTERPRETERS.has(base)) {
      let payload: string | null = null;
      let p = head.rawEnd;
      for (;;) {
        const w = readShellToken(cur, p);
        if (w === null) break;
        const t = w.content;
        if (!t.startsWith("-")) break; // script file / -s stdin / non-option — no provable -c
        if (t === "--") break;          // end of shell options → script path follows
        if (t === "-c") {
          const pl = readShellToken(cur, w.rawEnd);
          payload = pl === null ? "" : pl.content;
          break; // trailing words are $0.. positional params — CUT
        }
        if (t.startsWith("--")) {
          if (t === "--rcfile" || t === "--init-file") {
            const val = readShellToken(cur, w.rawEnd);
            if (val === null) break;
            p = val.rawEnd;
          } else {
            p = w.rawEnd; // no-value long option — keep walking
          }
          continue;
        }
        const chars = t.slice(1).split("");
        const allNoArg = chars.every((ch) => SHELL_C_CLUSTER_NOARG.has(ch));
        if (chars.includes("c")) {
          // ANY all-no-arg cluster containing c (`-c`, `-ce`, `-ec`, `-cae`,
          // `-cx`, `-cCe` …) takes the command string as the NEXT argv word —
          // verified empirically across bash/dash/zsh/ksh: `bash -ce 'echo
          // hi'` runs the payload with -e still applied (chars after c are
          // ordinary options; they never consume the payload word). A cluster
          // with a VALUE-taking char (-Oc, or -cecho whose trailing o needs an
          // option-name arg) is unprovable → break (bash itself errors on
          // those before running anything).
          if (!allNoArg) break;
          const pl = readShellToken(cur, w.rawEnd);
          if (pl === null) break;
          payload = pl.content;
          break;
        }
        if (!allNoArg) break; // value-taking short option — unprovable
        p = w.rawEnd;         // no-value cluster (-l/-e/-x/-a …) — keep walking
      }
      if (payload === null) break; // shell without a provable -c → stop the peel
      if (payload.length > 0 && wrapperPayloadSwitchesRepo(payload)) return null;
      cur = payload;
      peeledAny = true;
      continue;
    }
    break; // head is not a wrapper — stop peeling
  }
  return peeledAny ? cur : null;
}

// Aggregated diff-scope signals across every EXECUTED commit invocation in a
// command (recursive through provably-executing wrappers).
interface CommitInvocationAgg {
  sweep: boolean;            // ≥1 executed commit invocation sweeps (-a/--all)
  nonSweepCommit: boolean;   // ≥1 executed commit invocation is a non-sweep commit
  pathspecs: string[];       // named pathspecs of executed WT-path invocations
  pathspecFromFile: boolean; // --pathspec-from-file seen (names unreadable from text)
}

const EMPTY_COMMIT_AGG: CommitInvocationAgg = { sweep: false, nonSweepCommit: false, pathspecs: [], pathspecFromFile: false };

function scanCommitCommandAgg(command: string, depth: number): CommitInvocationAgg {
  const agg: CommitInvocationAgg = { sweep: false, nonSweepCommit: false, pathspecs: [], pathspecFromFile: false };
  for (const segment of splitCommandSegments(command)) {
    const inner = scanCommitSegmentText(normalizeCommitSegment(segment), depth);
    agg.sweep = agg.sweep || inner.sweep;
    agg.nonSweepCommit = agg.nonSweepCommit || inner.nonSweepCommit;
    agg.pathspecFromFile = agg.pathspecFromFile || inner.pathspecFromFile;
    agg.pathspecs.push(...inner.pathspecs);
  }
  return agg;
}

function scanCommitSegmentText(stripped: string, depth: number): CommitInvocationAgg {
  if (stripped.length === 0) return EMPTY_COMMIT_AGG;
  const unwrapped = unwrapExecutingHead(stripped);
  if (unwrapped !== null) {
    if (depth >= 8) {
      // nesting cap — cannot see inside; today's fail-closed wrapper posture
      // (an unparsed wrapper commit may ship the whole index → non-sweep).
      return { sweep: false, nonSweepCommit: true, pathspecs: [], pathspecFromFile: false };
    }
    return scanCommitCommandAgg(unwrapped, depth + 1);
  }
  const commitMatch = findGitCommit(stripped); // substring scan — head-anchored OR wrapper form
  if (commitMatch === null) return EMPTY_COMMIT_AGG; // no commit invocation — vacuous segment
  if (commitMatch.index !== 0) {
    // UNPARSED wrapper/negation/prose commit invocation — cannot prove its
    // flags; its (bare) commit half ships the WHOLE index (staged-only content
    // whose disk state == HEAD is invisible to `git diff HEAD`), so a
    // composite that ALSO contains a head-anchored sweep must classify "mixed"
    // → union(staged, WT) scope. Fail-closed: treating wrappers as invisible
    // let `sh -c 'git commit -m y' && git commit -am x` ship staged-only code
    // unverified (reviewer finding, #489 round 2). #539 peeled wrappers never
    // reach this arm — only genuinely unprovable shapes (prose, script shells)
    // do.
    return { sweep: false, nonSweepCommit: true, pathspecs: [], pathspecFromFile: false };
  }
  const scan = scanCommitInvocation(stripped.slice(commitMatch.end));
  return {
    sweep: scan.sweep,
    nonSweepCommit: !scan.sweep,
    pathspecs: scan.pathspecs,
    pathspecFromFile: scan.pathspecFromFile,
  };
}

export function commitSweepClass(command: string): CommitSweepClass {
  const agg = scanCommitCommandAgg(command, 0);
  if (!agg.sweep) return "none";
  return agg.nonSweepCommit ? "mixed" : "sweep";
}

// ── #538 — WT-path commit classification (diff-scope mirror extension, T2 carve-out) ──
// `git commit <pathspec>` / `git commit -o|--only <path>` / `-i|--include <path>` record
// the NAMED paths' WORKING-TREE state, not just the staged index: git defaults to
// only-mode whenever pathspecs are given (`-o`/`-i` are NOARG booleans — the paths arrive
// as positionals), and only-mode takes the named paths' DISK content, ignoring content
// staged for OTHER paths (empirically verified: `git commit -qm cA -- src/app.ts` with a
// staged docs file + dirty src/app.ts committed the code's dirty WT content and left the
// docs staged; `-i`/`--include` additionally records the whole staged index). A gate
// scoped to `git diff --cached` lets a staged-docs verifier PASS unlock
// `git commit -m x src/app.ts` while the commit ships src/app.ts's never-verified dirty
// WT content — the #489 T2 carve-out residual (#489's commitSweepClass covers only the
// FULL-tree `-a`/`--all` sweep; these forms are a PARTIAL sweep over the named paths).
// The hook's scope for a WT-path command must therefore be union(staged, named-path WT)
// — the named paths' HEAD-vs-working-tree state (`git diff HEAD -- <paths>`) is exactly
// what the form records. This classifier returns null when the command has NO WT-path
// commit invocation (bare / amend / sweep-only / vacuous) and otherwise the union of
// named pathspecs across every WT-path commit invocation. #539 EXTENSION: the shared
// scanCommitCommandAgg walker peels provably-executing wrappers, so a wrapper-hidden
// WT-path form (`sh -c 'git commit -m x f.ts'`, `eval "git commit f.ts -m x"`) now
// contributes its named pathspecs (the #538 scoping table's "wrapper-hidden sweep +
// wt-path variants" residual). Unparsed wrappers (prose / script shells) still
// contribute nothing. A composite that ALSO contains a sweep is handled by the
// sweep-first routing (the sweep's full-WT scope ⊇ any named-path scope).
export interface WtPathCommitInfo {
  // Union of the NAMED pathspec tokens across every WT-path commit invocation (globs and
  // pathspec magic kept verbatim — git expands them when the caller passes them to
  // `git diff HEAD -- <pathspecs>`). Empty only when pathspecFromFile is true.
  pathspecs: string[];
  // true when a WT-path invocation reads its pathspecs via --pathspec-from-file — the
  // names live in a FILE, not the command text, so the caller cannot enumerate them here
  // and must fall back to the FULL working-tree scope (the only statically-known
  // superset; fail-closed — only-mode records ⊆ the full WT set).
  pathspecFromFile: boolean;
}

export function wtPathCommitInfo(command: string): WtPathCommitInfo | null {
  const agg = scanCommitCommandAgg(command, 0);
  if (agg.pathspecs.length === 0 && !agg.pathspecFromFile) return null;
  return { pathspecs: agg.pathspecs, pathspecFromFile: agg.pathspecFromFile };
}

// ── #540 — in-batch mutation-chain classification (residual closure) ──────
// VGATE's tool_call hook computes its diff ONCE from the repo state BEFORE the
// command executes. A single tool_call that mutates state IN-BATCH — `echo x >
// f.ts && git add f.ts && git commit -m y` (or `… && git commit -am x`) — shows
// an EMPTY diff at hook time (neither the write nor the add has run) →
// "no changed files — allow" → unverified content lands in HEAD (the #540 hole;
// pre-existing since #38, documented residual of #489). The fix is a SHAPE
// REFUSAL, not a wider scope: for an in-batch file WRITE the content does not
// exist at hook time — there is nothing a pre-verification scope could verify —
// so the only sound pre-execution action is to refuse the compound and require
// the mutation and the commit to be SEPARATE tool_calls (each intermediate
// state then sits in the hook-time snapshot the normal scopes read).
//
// Classifier contract — commitChainMutationClass returns "in-batch-mutation"
// when the command executes a commit AND some executed segment BEFORE that
// commit is not provably content-neutral. Segment classes (in ORDER):
//   "commit"   — a head-anchored `git … commit` invocation after normalizeCommitSegment
//                (wrapper-peeled payloads classify at their true head; a commit only
//                CONSUMES staged/WT content the hook snapshot already contains — it can
//                never CREATE file content a later commit records invisibly, so commit+
//                commit chains stay legal — scenario 48 Leg G pin).
//   "neutral"  — the normalize fixpoint emptied the segment (cd&&/env/prefix verbs/
//                comments); a bare `cd`/`:`/`true`; a git READ-only verb; an stdout-only
//                echo/printf (no unquoted file redirect); a pure env assignment. These
//                cannot change the file set an executed commit records.
//   "mutating" — EVERYTHING else: file redirects, git add/checkout/reset/restore/rm/mv/
//                push/fetch/merge, arbitrary programs (python/node/tee/cat/sed/scripts),
//                gh ops, and wrapper payloads at the nesting cap. Fail-closed: an unknown
//                verb/program is assumed able to mutate repo content.
// Ordering across segments matters (a mutating op AFTER the last commit — `git commit -m
// x && git add y` — stages for a FUTURE op exactly like a separate non-intercepted `git
// add` tool_call and is NOT refused); wrapper expansion preserves order by splicing the
// payload's own segment classes into the sequence (`sh -c 'git add x && git commit -m y'`
// → [mutating, commit] → refused; `sh -c 'git commit -am x'` → [commit] → legal). The
// nesting cap expands a wrapper to [mutating, commit] (fail-closed: cannot see inside —
// it may both mutate and commit).
//
// SOUNDNESS (cannot be gamed by re-arrangement): only provably content-neutral shapes
// may precede a commit; none of them can change what the commit records, so every legal
// commit's record-set is fully described by the hook-time snapshot → the existing scope
// producers bound it → the verify/block loop is sound. Any attempt to combine mutation
// + commit in one tool_call is refused REGARDLESS of how the mutation is spelled; the
// refusal feeds NO #7591 blockAttempts / lastBlockedFiles (mirror of the parse-block
// posture — an unverifiable shape must never auto-bypass on repetition).

// Closed set of git verbs that provably cannot change the index / working tree / refs
// of the repo whose commit the classifier is guarding (reads + pure queries only).
// Unknown git verbs are NOT in the set → the enclosing segment classifies "mutating"
// (fail-closed). Keep deliberately conservative: a read verb listed here that git later
// gives write semantics would reopen the refusal's soundness claim.
const GIT_READ_ONLY_VERBS = new Set([
  "status", "log", "diff", "show", "rev-parse", "branch", "remote", "config",
  "ls-files", "ls-tree", "cat-file", "rev-list", "describe", "name-rev",
  "merge-base", "blame", "grep", "shortlog", "whatchanged", "count-objects",
  "for-each-ref", "symbolic-ref", "check-attr", "check-ignore", "diff-tree",
  "diff-index", "diff-files", "tag", "help", "version", "var", "cherry",
  "fmt-merge-msg", "rerere", "verify-commit", "verify-tag", "mailinfo",
  "check-mailmap", "credential-fill", "hash-object", "mktree", "mktag", "archive",
]);

// Quote-aware probe: does the text carry an UNQUOTED `>`/`>>` file redirect
// (anything that writes a file from the shell's perspective)? Bash operators:
// `&>file` redirects BOTH streams to file (a file write); `>&fd` / `N>&M`
// (`2>&1`, `>&2`) duplicate a descriptor (NOT a file write); `/dev/null`
// targets write nothing we gate. Only used to split stdout-only echo/printf
// (neutral) from redirecting echo/printf (mutating: `echo x > f.ts` can
// overwrite a TRACKED file a later sweep records).
type ChainClass = "commit" | "neutral" | "mutating";

function segmentWritesFile(text: string): boolean {
  let quote: string | null = null;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (quote !== null) {
      if (ch === "\\" && i + 1 < text.length) { i++; continue; }
      if (ch === quote) quote = null;
      continue;
    }
    if (ch === "'" || ch === "\"") { quote = ch; continue; }
    if (ch === ">") {
      // `>&fd` / `N>&M` fd-dup/close forms have `&` NEXT (`2>&1`, `>&2`, `>&-`).
      // ⛔ review-r1 P1 + review-r2 P2-1: a `>` whose PREVIOUS char is `&` is the `&>file`
      // redirect-BOTH operator (a FILE WRITE) — and `>&word` with a NON-descriptor target
      // is ALSO redirect-both to a file (`echo x >& f.ts`). Only skip when the token after
      // `&` is a descriptor (all digits, or `-` for fd-close).
      if (i + 1 < text.length && text[i + 1] === "&") {
        let k = i + 2;
        while (k < text.length && (text[k] === " " || text[k] === "\t")) k++;
        const isFdTarget = k < text.length && text[k] === "-" ? true
          : (() => {
              if (k >= text.length || !/\d/.test(text[k])) return false;
              let d = k;
              while (d < text.length && /\d/.test(text[d])) d++;
              return d === text.length || /[\s;&|<>\n]/.test(text[d]);
            })();
        if (isFdTarget) continue; // descriptor dup/close — no file write
        // `>&word` (non-descriptor) / `&>file` — a file write: fall through to the
        // /dev/null tolerance below (i stays on the `>`, j resumes right after it).
      }
      // /dev/null targets write nothing we gate (incl. `>/dev/null`, `2>/dev/null`, `&>/dev/null`).
      let j = i + 1;
      while (j < text.length && (text[j] === " " || text[j] === "\t")) j++;
      if (text.startsWith("/dev/null", j)) {
        i = j + "/dev/null".length - 1;
        continue;
      }
      return true;
    }
  }
  return false;
}

function chainCommandClasses(command: string, depth: number): ChainClass[] {
  const out: ChainClass[] = [];
  for (const segment of splitCommandSegments(command)) {
    out.push(...chainSegmentClass(normalizeCommitSegment(segment), depth));
  }
  return out;
}

// review-r2 P2-2 + review-r3 P1 — pure EXECUTION MODIFIERS. COMMIT_SEGMENT_HEAD strips a
// BARE prefix verb (`sudo git commit`, `env FOO=1 git commit`) but NOT verbs with args
// (`timeout 5 git commit`, `nice -n 5 git commit`, `sudo -u me git commit` — the bare
// `sudo` strips, leaving a `-u me` dash remnant; `timeout`/`nice`/`stdbuf`/`ionice`/`chrt`
// are not stripped at all). The FALLBACK below therefore recognizes execution modifiers as
// commit-CARRIERS: any segment whose head is a known modifier (or a dash remnant of a
// stripped prefix verb) with bare `git … commit` text after its args executes that commit
// VERBATIM (modifiers mutate nothing themselves) → classify ["commit"] so M1's ordering
// refusal still catches an in-batch mutation in an EARLIER segment (`echo x > f.ts &&
// timeout -s KILL 10 git commit -am x` → refuse) and M2's widening still fires. review-r3
// P1 specifically: option VALUES after a modifier (`timeout -s KILL 10 …`) must not lose
// the commit class — this head-based classification is value-agnostic and cannot.
// ⛔ Deliberately NO attempt to parse modifier option values into "the command position":
// the earlier peelCommandModifier did and its value-taking handling was wrong (the commit
// class vanished for `timeout -s KILL 10 git commit`, re-opening the M1/M2 bypass). The
// cost: a PURE shell payload under a modifier (`timeout 5 sh -c 'git commit -am x'`)
// carries the shell-carrier marker below → refuses (over-refusal, recoverable by dropping
// the sh -c wrapper) — an accepted exotic corner (documented in the plan doc).
const MODIFIER_VERBS = new Set([
  "timeout", "ionice", "chrt", "stdbuf", "nice", "nohup", "time", "command",
  "sudo", "env", "exec",
]);

function chainSegmentClass(stripped: string, depth: number): ChainClass[] {
  if (stripped.length === 0) return ["neutral"];
  // Provably-executing wrapper → its payload executes IN PLACE: splice the payload's
  // own segment classes into the sequence (order preserved across the wrapper).
  const unwrapped = unwrapExecutingHead(stripped);
  if (unwrapped !== null) {
    if (depth >= 8) return ["mutating", "commit"]; // nesting cap — may mutate AND commit (fail-closed)
    const inner = chainCommandClasses(unwrapped, depth + 1);
    return inner.length > 0 ? inner : ["neutral"];
  }
  // Head-anchored executed commit (index 0 after normalize; a match at index > 0 is
  // prose/script text that does NOT execute a commit in this segment — `echo "run git
  // commit -am x"` is a neutral stdout line, never a reroute).
  const commitMatch = findGitCommit(stripped);
  if (commitMatch !== null && commitMatch.index === 0) return ["commit"];
  const head = readShellToken(stripped, 0);
  if (head === null) return ["neutral"];
  const t = head.content;
  // Pure env assignment (its own segment after an `&&` split) + export declarations set
  // shell state only — never repo content.
  if (/^[A-Za-z_][A-Za-z0-9_]*=[^\s;&|]*$/.test(stripped)) return ["neutral"];
  if (/^export\s+[A-Za-z_][A-Za-z0-9_]*\s*$/.test(stripped) || /^export\s+[A-Za-z_][A-Za-z0-9_]*=[^\s;&|]*$/.test(stripped)) return ["neutral"];
  if (t === "cd" || t === ":" || t === "true" || t === "false" || t === "exit") return ["neutral"];
  if (t === "echo" || t === "printf") return segmentWritesFile(stripped) ? ["mutating"] : ["neutral"];
  if (t === "git") {
    // Read-only verb carve-out: a git READ cannot stage/commit/move content itself — but its
    // OUTPUT can be redirected over a TRACKED file (`git status > src/app.ts`), which a later
    // sweep would record → a redirecting read is a mutation candidate, not neutral.
    const readInv = findGitVerbInvocation(stripped, GIT_READ_ONLY_VERBS, "tolerate");
    if (readInv !== null && readInv.index === 0 && !segmentWritesFile(stripped)) return ["neutral"];
    return ["mutating"]; // git add/checkout/reset/restore/rm/mv/push/fetch/… or an unknown verb
  }
  // Fallback — arbitrary program / script shell / execution modifier: assumed able to
  // mutate. review-r1 P2: a segment whose text carries a git-commit invocation at a NON-head
  // offset may EXECUTE that commit inside an unwrappable program (`env -S "… && git commit
  // …"`, `xargs … sh -c "…"`, `find … -exec sh -c "…"`) — emit the [mutating, commit] pair
  // (cap-wrapper parity) so M1/M2 fire on the self-contained mutation+commit. review-r2
  // P2-2 REFINEMENT: the pair fires only when an EXECUTING SHELL-CARRIER sits before the git
  // text — a shell interpreter `-c` payload or a separator (`&&`/`||`/`;`/`|`/newline).
  // review-r3 P1: WITHOUT a shell carrier, a segment whose head is a known execution modifier
  // (timeout/nice/stdbuf/ionice/chrt — never stripped by normalize) or a dash REMNANT of a
  // stripped prefix verb (`sudo -u me git commit` → normalize leaves `-u me …`) runs the
  // following `git … commit` VERBATIM and mutates nothing itself → classify ["commit"] (the
  // commit class must survive modifier option VALUES — `timeout -s KILL 10 git commit` — so
  // M1's ordering refusal still fires for an earlier in-batch mutation and M2's widening
  // still fires; value-agnostic by construction). A dash-headed segment always traces to a
  // stripped prefix verb (a literal bash command cannot start with `-`), so its bare git
  // text is executed, never prose. `gh` stays carved out: gh executes NO local shell —
  // git-commit-looking text inside its option values (--body/--title/--comment) is inert
  // prose and refusing a pure gh op for it is NOT split-recoverable over-refusal
  // (scenario 39/68b parity).
  if (t !== "gh") {
    const nonHeadCommit = findGitCommit(stripped);
    if (nonHeadCommit !== null && nonHeadCommit.index > 0) {
      const before = stripped.slice(0, nonHeadCommit.index);
      const shellCarrier = /\b(?:sh|bash|zsh|dash|ksh)\b[^;&|\n]*(?:-[A-Za-z]*)?\s-c\b/.test(before)
        || /(?:&&|\|\||;|\||\n)/.test(before);
      if (shellCarrier) return ["mutating", "commit"];
      if (MODIFIER_VERBS.has(t) || t.startsWith("-")) return ["commit"];
    }
  }
  return ["mutating"];
}

// M1 — the hook's refusal signal. "in-batch-mutation" iff a mutating segment precedes an
// executed commit in command order (a mutating entry that ALSO carries a commit — the cap
// wrapper expansion — trivially precedes its own "commit" twin). Commit-free commands
// (pure pushes / gh ops / delete chains) return "none" regardless of their mutation
// content — a push cannot record content created in the same command (it ships committed
// HEAD; the write only touches disk).
export function commitChainMutationClass(command: string): "in-batch-mutation" | "none" {
  const seq = chainCommandClasses(command, 0);
  for (let i = 0; i < seq.length; i++) {
    if (seq[i] !== "mutating") continue;
    for (let j = i + 1; j < seq.length; j++) {
      if (seq[j] === "commit") return "in-batch-mutation";
    }
  }
  return "none";
}

// M2 trigger — did the command PROVABLY execute a commit (head-anchored after wrapper
// peel)? Prose that merely MENTIONS `git commit` (echo/gh --body values) never counts —
// such segments classify by their HEAD (echo/gh → neutral/mutating, not "commit"). Used
// by the gh arm to widen the routing scope (see ghCommitRecordScope below).
export function commandRunsCommit(command: string): boolean {
  return chainCommandClasses(command, 0).some((c) => c === "commit");
}

// ── #487 — content-push RANGE scoping (T1: a content push verifies the pushed
// range, never the whole index) ───────────────────────
// Pure layer: classifier → tier resolver → argv builder (present state; the
// TDD stub round that RED-pinned the unit sections is long landed).
// Mirror of the evaluateMergeScope pure-decision + e2e-orchestration split:
// shape/tier tables are unit-tested subprocess-free; the I/O orchestrator
// resolvePushRangeScope probes the repo and is e2e-only (same
// no-unit-import choice as resolveMergeScope). Design record + accepted
// residuals: docs/plans/2026-09-06-issue-487-vgate-push-range.md.
//
// FAIL-CLOSED CONTRACT (whole command): ANY unmappable shape (tag push,
// --all/--tags/--mirror, wrapper push, URL remote, delete+content mix, any
// non-whitelisted push flag), ANY git commit or gh pr create|merge presence
// (the P0 guard — findGitCommit substring containment, wrapper-inclusive), or
// ANY probe failure → resolvePushRangeScope returns null → the caller's
// status-quo staged scope (runStagedScope). NEVER error→[] (the
// runBranchScope catch→clean-empty fail-open precedent is the
// cautionary inversion). An empty RESOLVED range is audited push_range_empty
// and allowed (an up-to-date push ships nothing).

// src/dst are PLAIN ref names (no colon), validated by regex; colon = the
// refspec had an explicit `:` (src:dst split) vs the bare same-name form — the
// resolver's dst=HEAD guard keys off it (a bare `HEAD` positional derives dst
// from the current branch; `HEAD:HEAD` must fall to tier C).
export interface PushRefSpec { src: string; dst: string; colon: boolean; }

export type PushParseResult =
  | { eligible: true; refspecs: PushRefSpec[]; bare: boolean; remote: string | null }
  | { eligible: false; reason: "has_commit" | "has_gh" | "no_push" | "mixed_delete" | "unmappable" | "wrapper" };

// Fail-closed flag whitelist (bare-token equality ONLY): any other `-` token,
// including an ATTACHED value (`--force-with-lease=<val>`), → unmappable.
const PUSH_FLAG_WHITELIST = new Set(["-u", "--set-upstream", "-f", "--force", "--force-with-lease"]);
const PUSH_REFNAME = /^[A-Za-z0-9_][A-Za-z0-9_./-]*$/;
// Remote NAME (never a URL): shared by the classifier (explicit positionals) and
// the resolver's git-state guard (config branch.<cur>.remote VALUE) so the two
// can never drift apart (review cycle-2 P2).
const PUSH_REMOTE_NAME = /^[A-Za-z0-9_.-]+$/;
const GH_PR_OP = /\bgh(?:\s+(?:--repo|-R)(?:=|\s+)[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)?\s+pr\s+(?:create|merge)\b/;

function parsePushRefspecToken(token: string): PushRefSpec | null {
  if (token.includes(":")) {
    if (token.split(":").length > 2) return null;              // >1 colon
    const parts = token.split(":");
    const src = parts[0];
    const dst = parts[1];
    // An EMPTY src is git's delete-colon form (`:feat/x`) — handled by
    // isPureDeletionPushSegment BEFORE this content parse ever sees it; if one
    // reaches here inside a content segment it must fail closed (not map).
    if (src.length === 0) return null;
    if (!PUSH_REFNAME.test(src) || !PUSH_REFNAME.test(dst)) return null;
    if (src.startsWith("refs/tags/") || dst.startsWith("refs/tags/")) return null; // tag push
    return { src, dst, colon: true };
  }
  if (!PUSH_REFNAME.test(token)) return null;
  if (token.startsWith("refs/tags/")) return null;               // tag push
  return { src: token, dst: token, colon: false };
}

// PURE — splitCommandSegments/stripSegmentHead/tokenizePushArgs/findGitCommit
// + isPureDeletionPushSegment only. Whole-command semantics (isDeletionPush
// mirror): eligible iff ≥1 head-anchored CONTENT push segment exists AND every
// gated segment mapped (delete segments in a content chain → mixed_delete;
// commit/gh anywhere → has_commit/has_gh — P0 guard FIRST, wrapper-inclusive).
export function parsePushRefSpecs(command: string): PushParseResult {
  const refspecs: PushRefSpec[] = [];
  let remote: string | null = null;
  let bare = false;
  let pushCount = 0;
  let sawPureDelete = false;
  for (const segment of splitCommandSegments(command)) {
    const stripped = stripSegmentHead(segment);
    // P0 guard (containment — substring, wrapper-inclusive, symmetric with the
    // gate's own interception surface): any commit ANYWHERE flips the whole
    // command to the status-quo staged scope. Checked before everything else.
    if (findGitCommit(stripped) !== null) return { eligible: false, reason: "has_commit" };
    if (GH_PR_OP.test(stripped)) return { eligible: false, reason: "has_gh" };
    const pushInv = findGitVerbInvocation(stripped, GIT_VERB_SET.push, "tolerate");
    if (pushInv !== null) {
      // Redirect-global push → a DIFFERENT checkout's op — scaffolding (the
      // hook can never intercept it, so no scope decision is needed; today's
      // adjacency regexes classified it the same way).
      if (pushInv.foreign) continue;
      // Wrapper push (index > 0) → cannot prove shape (mirrors the
      // isDeletionPush wrapper arm).
      if (pushInv.index !== 0) return { eligible: false, reason: "wrapper" };
      if (isPureDeletionPushSegment(segment)) { sawPureDelete = true; continue; }
      pushCount++;
      const rest = stripped.slice(pushInv.end);
      const tokens = tokenizePushArgs(rest);
      const positionals: string[] = [];
      for (const token of tokens) {
        if (isRedirectToken(token)) continue;
        if (PUSH_FLAG_WHITELIST.has(token)) continue;
        if (token.startsWith("-")) return { eligible: false, reason: "unmappable" }; // any non-whitelisted flag
        positionals.push(token);
      }
      if (positionals.length === 0) {
        // No positionals → bare push candidate (config-upstream ceremony).
        if (pushCount > 1 || bare || refspecs.length > 0) return { eligible: false, reason: "unmappable" }; // bare mixed with other pushes
        bare = true;
        continue;
      }
      const [first, ...restPos] = positionals;
      // URL remote (contains `/`, `@`, `:` outside the ref regex) → unmappable.
      if (!PUSH_REMOTE_NAME.test(first)) return { eligible: false, reason: "unmappable" };
      if (restPos.length === 0) {
        // Remote + no refspecs → bare with remote fixed (git pushes the current
        // branch to its configured upstream under that remote).
        if (pushCount > 1 || bare || refspecs.length > 0) return { eligible: false, reason: "unmappable" };
        bare = true;
        if (remote === null) remote = first; else if (remote !== first) return { eligible: false, reason: "unmappable" };
        continue;
      }
      const segRefspecs: PushRefSpec[] = [];
      for (const rs of restPos) {
        const parsedRs = parsePushRefspecToken(rs);
        if (parsedRs === null) return { eligible: false, reason: "unmappable" };
        segRefspecs.push(parsedRs);
      }
      if (remote === null) remote = first; else if (remote !== first) return { eligible: false, reason: "unmappable" }; // multi-remote content push
      refspecs.push(...segRefspecs);
      continue;
    }
    // else: scaffolding (pull/rebase/checkout/echo/assignments) — ignored
  }
  if (pushCount === 0) return { eligible: false, reason: "no_push" };
  if (sawPureDelete) return { eligible: false, reason: "mixed_delete" }; // delete + content chain → whole-command staged
  // Order-independent mixing guard: a bare push + an explicit-refspec push in one
  // command cannot be represented (the bare half needs config resolution, the
  // explicit half needs the refspec) — a bare-first command must NOT silently
  // drop the explicit refspecs at the return below (review cycle-2 P1).
  if (bare && refspecs.length > 0) return { eligible: false, reason: "unmappable" };
  if (bare) return { eligible: true, refspecs: [], bare: true, remote };
  return { eligible: true, refspecs, bare: false, remote };
}

// PURE 4-combo — second arg = "tier-B base ref resolves" (the preference is
// applied by the I/O resolver BEFORE the call, so this is a 2×2 boolean).
export function resolvePushTier(trackingExists: boolean, baseMainExists: boolean): "A" | "B" | "C" {
  if (trackingExists) return "A";
  return baseMainExists ? "B" : "C";
}

// PURE argv builder — baseRef is the FULLY RESOLVED base ref (never DWIM);
// src is the resolved local ref (refs/heads/<x> or HEAD). Tier A = 2-dot
// (space form — the remote branch also LOSES remote-side-only files on a
// diverged/force push); tier B = 3-dot first-push base. Injection safety:
// every value that reaches the argv is whitelist-validated before it is
// interpolated — classifier tokens by PUSH_REFNAME/remote regex, and
// git-state-derived values (checked-out branch name, config remote) by the
// GIT_STATE guards in resolvePushRangeScope — so no shell metachars can reach
// the execSync string (execSync runs /bin/sh -c; nothing here sets shell:false).
export function buildPushRangeDiffCommand(tier: "A" | "B", baseRef: string, src: string, nameStatusZ = false): string {
  const arg = nameStatusZ ? "--name-status -z" : "--name-only";
  if (tier === "A") return `git diff ${arg} ${baseRef} ${src}`;
  return `git diff ${arg} ${baseRef}...${src}`;
}

// ── #487 — I/O orchestration (Task 4): repo probes + per-refspec range diff ──
// Exported like resolveMergeScope (e2e-only — NOT unit-imported, mirroring the
// resolveMergeScope no-unit-import choice). Returns the pushed-range file set
// or null → the caller's status-quo staged scope. Fail-closed contract above.

function gitProbe(cwd: string, args: string): string | null {
  try {
    return execSync(`git ${args}`, { cwd, encoding: "utf-8", timeout: 5000 }).trim();
  } catch {
    return null;
  }
}

function refExists(cwd: string, ref: string): boolean {
  return gitProbe(cwd, `rev-parse --verify --quiet ${ref}`) !== null;
}

function gitConfigGet(cwd: string, key: string): string | null {
  const v = gitProbe(cwd, `config --get ${key}`);
  return v === null || v === "" ? null : v;
}

function symbolicRefShort(cwd: string): string | null {
  const v = gitProbe(cwd, "symbolic-ref --short HEAD");
  return v === null || v === "" ? null : v;
}

// Refname/remote validation for GIT-STATE-DERIVED values before they reach an
// execSync string. execSync runs /bin/sh -c (NO shell:false anywhere in this
// file), so ANY interpolated value must pass a strict whitelist: git refnames
// legally allow shell metachars (`;`, `|`, `$`, …) — a checked-out branch or a
// config `branch.<cur>.remote` value from a hostile repo is arbitrary shell
// input until validated. Classifier-validated tokens (PUSH_REFNAME /
// PUSH_REMOTE_NAME) are already safe; these guards close the resolver's two
// unvalidated inputs (security review P1). Validation failure → null (tier C).
// Accepted tier-C residuals of the guards (fail-closed, documented — review
// cycle-2): a hierarchical config remote name (`org/team`) or a non-ASCII
// branch name is rejected by the whitelist even though neither carries shell
// metachars → bare pushes over parked WIP keep the staged check (status-quo,
// pre-#487 behavior).
export function resolvePushRangeScope(command: string, cwd: string, sub?: SubBundle | null): DiffScope | null {
  const parsed = parsePushRefSpecs(command);
  if (!parsed.eligible) return null; // commit/gh/unmappable/wrapper/no_push — zero subprocess on bare commits
  // Bare push (no refspecs): derive remote + dst + src from the branch config
  // (04-merge-deploy.md L208/L247 `git push --force-with-lease` ceremony — the
  // earlier `git push -u` in 02-commit-pr.md set branch.<cur>.remote/.merge).
  let { refspecs, remote } = parsed;
  if (parsed.bare) {
    const current = symbolicRefShort(cwd);
    if (current === null) return null; // detached/unborn — cannot map
    // ⛔ Injection guard: `current` (a git-state value, user-writable via
    // symbolic-ref/checkout) is interpolated into config keys and refs — it
    // must pass the refname whitelist BEFORE any execSync string is built
    // (security review P1; refnames allow `;`/`|`/`$`).
    if (!PUSH_REFNAME.test(current)) return null;
    if (remote === null) {
      remote = gitConfigGet(cwd, `branch.${current}.remote`);
      if (remote === null) return null;
    }
    // ⛔ Injection guard: the config VALUE branch.<cur>.remote is user-writable
    // repo state — validate before it reaches refs/remotes/… strings.
    if (!PUSH_REMOTE_NAME.test(remote)) return null;
    const mergeCfg = gitConfigGet(cwd, `branch.${current}.merge`);
    const m = mergeCfg !== null ? /^refs\/heads\/([A-Za-z0-9_.\/-]+)$/.exec(mergeCfg) : null;
    if (m === null) return null; // no/odd upstream config → tier C (push.default=current residual)
    refspecs = [{ src: current, dst: m[1], colon: false }];
  }
  if (refspecs.length === 0) return null; // defensive
  // Multi-refspec union: files dedup, renameOldPaths dedup, clean = AND over
  // the refspec parses (mixed-union rule).
  const union: DiffScope = { files: [], renameOldPaths: [], clean: true };
  let sawTierA = false;
  for (const rs of refspecs) {
    let { src, dst } = rs;
    // src = HEAD special-case — NO-COLON ONLY (a positional `HEAD` pushes to
    // the current branch's same-name remote branch; real git never targets a
    // branch literally named HEAD). COLON src=HEAD (`HEAD:main`, `HEAD:HEAD`)
    // falls to the generic probes below → refs/heads/HEAD unresolvable → null.
    let srcIsHead = false;
    if (src === "HEAD" && !rs.colon) {
      const current = symbolicRefShort(cwd);
      if (current === null) return null;
      // Injection guard: `current` is interpolated into dst/tracking strings.
      if (!PUSH_REFNAME.test(current)) return null;
      if (gitProbe(cwd, "rev-parse --verify HEAD") === null) return null; // unborn
      dst = current;
      srcIsHead = true;
    }
    // dst normalization + dst=HEAD guard. ⛔ The guard sits BEFORE src
    // resolution, so a COLON `HEAD:HEAD` (src=dst=HEAD, no-colon derivation
    // skipped) is nulled HERE — the src probe below never sees it (second-model
    // gate: the plan's "HEAD:HEAD nulls at the src probe" wording was wrong;
    // the guard is the nulling site for every dst=HEAD colon form). A real
    // clone's refs/remotes/origin/HEAD is the DEFAULT-branch symbolic ref — it
    // must never become a tier-A base for a remote branch literally named HEAD.
    if (dst.startsWith("refs/heads/")) dst = dst.slice("refs/heads/".length);
    if (dst === "HEAD") return null;
    // src resolution (local side of the diff).
    let srcRef: string | null = null;
    if (srcIsHead) {
      srcRef = "HEAD";
    } else if (src.startsWith("refs/heads/")) {
      if (!refExists(cwd, src)) return null;
      srcRef = src;
    } else if (src === "HEAD") {
      // COLON src=HEAD with a NON-HEAD dst (`HEAD:main` — HEAD:HEAD already
      // nulled by the dst guard above): refs/heads/HEAD is never a real branch,
      // so this probe fails → null → tier C (accepted residual — the dst=HEAD
      // guard covers colon dst forms; a tag literally named HEAD is not probed
      // here, the probe just fails on refs/heads/HEAD).
      if (!refExists(cwd, "refs/heads/HEAD")) return null;
      srcRef = "refs/heads/HEAD";
    } else {
      const branch = `refs/heads/${src}`;
      const tag = `refs/tags/${src}`;
      const bOk = refExists(cwd, branch);
      const tOk = refExists(cwd, tag);
      if (bOk && tOk) return null; // git ambiguity — cannot prove shape
      if (tOk) return null;        // tag push → whole-command staged
      if (!bOk) return null;       // unresolvable src
      srcRef = branch;
    }
    if (remote === null) return null; // defensive — explicit refspecs always carry a remote
    // Tier decision. baseMainExists is fed AFTER the tier-B base preference:
    // <remote>/main when remote ≠ origin and that ref exists, else the house
    // origin/main (computeBranchDiff precedent) — the pure table stays a 2×2.
    const tracking = `refs/remotes/${remote}/${dst}`;
    const trackingExists = refExists(cwd, tracking);
    let baseMain = "refs/remotes/origin/main";
    if (remote !== "origin" && refExists(cwd, `refs/remotes/${remote}/main`)) {
      baseMain = `refs/remotes/${remote}/main`;
    }
    const baseMainExists = refExists(cwd, baseMain);
    const tier = resolvePushTier(trackingExists, baseMainExists);
    if (tier === "C") return null; // whole-command rule: ANY tier C → staged
    const baseRef = tier === "A" ? tracking : baseMain;
    if (tier === "A") sawTierA = true;
    // 2-dot (A) / 3-dot (B) `--name-status -z` diff. The builder emits the
    // FULL `git diff …` argv (unit-pinned) — run it directly (NOT through
    // gitProbe, which would double the `git` prefix). ANY throw → null
    // (staged) — NEVER error→[] (the computeBranchDiff catch→[] fail-open
    // precedent inverted). No trim: -z rows are NUL-delimited raw path bytes.
    let diffOut: string | null = null;
    try {
      diffOut = execSync(buildPushRangeDiffCommand(tier, baseRef, srcRef, true), {
        cwd, encoding: "utf-8", timeout: 5000, maxBuffer: 64 * 1024 * 1024,
      });
    } catch {
      diffOut = null;
    }
    if (diffOut === null) return null;
    const parsed = parseDiffNameStatusDetailed(diffOut);
    // #755: per-refspec subtraction, BEFORE the union (subtraction is per-arm,
    // pre-union — there is no union-level eligibility rule and no consumer for
    // one). `trackingRef` is `tracking` exactly as derived from `dst` inside
    // `resolvePushRangeScope` — that local is ALSO the tier input, so it is
    // never re-derived from srcRef.
    const subbed = subtractForArm(cwd, parsed.scope, parsed.statuses, sub, {
      arm: "push",
      recordedSide: "ref",
      srcRef: srcRef ?? undefined,
      trackingRef: tracking,
    });
    union.files.push(...subbed.files);
    union.renameOldPaths.push(...subbed.renameOldPaths);
    union.clean = union.clean && subbed.clean;
    if (subbed.subtractions !== undefined) {
      union.subtractions = [...(union.subtractions ?? []), ...subbed.subtractions];
    }
  }
  if (union.files.length === 0 && union.renameOldPaths.length === 0 && union.clean) {
    // #755: suppress push_range_empty when the emptiness was CAUSED by
    // subtraction — the single emitted line is then the handler's richer
    // base_identical_satisfied (which carries T/B/merge-base/guard-5 OIDs and
    // the paths). The rule it would violate is the one stated at the emit site
    // below: "at most one base_identical_satisfied per op; it may co-exist with
    // a per-path reason". A per-path reason and this op-level line CAN both
    // appear; push_range_empty must not, because it occupies the SAME op-level
    // slot and would misreport a full subtraction as an up-to-date push.
    // emitting only the bare push_range_empty would make a forged-T full
    // subtraction indistinguishable from a legitimate up-to-date push.
    // `subtractions` is ABSENT (not []) on the ordinary no-subtraction push,
    // so the `?? 0` is load-bearing — a bare `.length` throws on the common path.
    const subtractedSomething = (union.subtractions?.length ?? 0) > 0;
    // Up-to-date push ships nothing — audited INSIDE the resolver so the
    // caller's shared silent empty-allow never hides the range decision.
    // Note: with multi-refspec commands the tier payload is "A" iff ANY
    // refspec resolved tier A (order-independent any-A-wins — second-model
    // gate wording fix; mixed A+B empty ranges label "A"); cosmetic audit
    // metadata only — the allow + audit reason are identical in every ordering.
    // ⛔ Trust boundary (security review P2, documented): tier A reads LOCAL
    // remote-tracking refs — same-user-writable repo state (git update-ref is
    // not a gated verb) that can steer an empty range → audited allow. The
    // gate's contract is same-user verification, not local-state hardening:
    // the index was equally trusted pre-#487 and the bypass here is AUDITED
    // (push_range_empty) where the old silent empty-allow was not. A stale
    // tracking ref BEHIND the live remote under-scopes a --force push in the
    // same trust class (the gate never saw remote-side-only files — identical
    // to computeBranchDiff's origin/main staleness); the pull --rebase
    // pre-push ceremony (01-preflight) refreshes it.
    if (!subtractedSomething) logGateSkip("push_range_empty", command, cwd, { tier: sawTierA ? "A" : "B" });
    return { files: [], renameOldPaths: [], clean: true, ...(subtractedSomething ? { subtractions: union.subtractions } : {}) };
  }
  // Fresh object ⇒ any field not explicitly rebuilt is dropped. `subtractions`
  // is therefore carried explicitly and null-safely.
  return {
    files: Array.from(new Set(union.files)),
    renameOldPaths: Array.from(new Set(union.renameOldPaths)),
    clean: union.clean,
    ...(union.subtractions !== undefined && union.subtractions.length > 0
      ? { subtractions: union.subtractions }
      : {}),
  };
}

// ── Diff computation (#559 T1: rename-source plumbing) ──
// All diff scopes switch to `git diff --name-status -z` (NUL-separated
// porcelain). git emits path columns RAW in -z mode (no C-quoting — control
// chars/quotes/tabs and non-ASCII names parse raw and hash correctly), and
// rename/copy rows carry the OLD path: `R100\0<old>\0<new>\0` vs name-only's
// collapsed `docs/code.md`. The OLD path is what the content-shape gate must
// measure — `git mv src/app.ts docs/code.md` must NOT ride the docs exemption
// (issue #559 T1). A defensive `clean` flag stays on the parse (unreachable
// from real git output — the allow sites must be fail-closed against future
// format drift) and routes an unconditional parse-block (applyScopeGate).

export interface DiffScope {
  /** changed paths — rename/copy rows contribute the NEW path (name-only parity) */
  files: string[];
  /** rename/copy SOURCE paths (the old side of R/C rows) */
  renameOldPaths: string[];
  /** NUL-stream parsed without anomaly (false ⇒ parse-block, never allow) */
  clean: boolean;
  /** #755: per-arm merge-scope subtraction audit. ABSENT (never `[]`) when
   *  nothing was subtracted. `combineScopes` concatenates it and reads nothing
   *  else, so `DiffScope`-shaped literals without the key stay valid. */
  subtractions?: SubAudit[];
}

// Pure `--name-status -z` parser. Row grammar (byte-exact, verified against
// git): a one-letter status + optional similarity score, NUL, then the path
// column(s) — one path for A/M/D/T/U/X/B (`A\0<path>\0`), TWO for R/C rows
// (`R100\0<old>\0<new>\0` — old first). Every row's last path ends with a
// trailing NUL — that final empty token is the terminator, not an anomaly.
// NUL contract (unit-pinned): `parseDiffNameStatus("")` → clean with no
// rows; a trailing-NUL multi-row stream → clean with the full file set; an
// interior-consecutive-NUL / unknown-status / truncated-row stream →
// `clean=false` (fail-closed: the caller must parse-block, never allow).
// `diff.renames=false` equivalence: git then emits D+A split rows instead of
// R — the OLD path lands in `files` (D row) and gates normally; renameOldPaths
// stays empty (no regression, the old path still surfaces). No quoting/
// decoding anywhere — paths raw. Exec-failure and parse-anomaly never share a
// channel: the producers' catch → clean-empty preserves today's error
// semantics (documented residual, #559 plan §1); only a NUL-stream anomaly is
// newly fail-closed.
export function parseDiffNameStatus(output: string): DiffScope {
  // Thin wrapper — the seven G1 full-object deepEqual pins compare `.scope`, so
  // splitting the parser must not change the returned object's shape.
  return parseDiffNameStatusDetailed(output).scope;
}

/** #755 — the same parse, plus the per-path STATUS map the eligibility rule
 *  needs (`A`/`M` are subtractable; `D`/`T`/`R`/`C`/`U`/`X`/`B` are not).
 *  R/C rows key the NEW path (the path that lands in `files`). An anomaly
 *  yields a PARTIAL map consistent with `files` and `clean: false` — the
 *  parse-block runs first, so a partial map is never consulted.
 *
 *  Home: `index.test.ts` owns the row-family pins. It must NOT be tested from
 *  subtract-scope.test.ts, which must stay SDK-free (index.ts:2 is a value import). */
export function parseDiffNameStatusDetailed(output: string): {
  scope: DiffScope;
  statuses: Map<string, string>;
} {
  const files: string[] = [];
  const renameOldPaths: string[] = [];
  const statuses = new Map<string, string>();
  if (output === "") return { scope: { files, renameOldPaths, clean: true }, statuses };
  // NUL contract: every git -z stream is NUL-terminated (each row's last
  // path column ends with NUL). A non-empty stream lacking the final
  // terminator is truncated → anomaly (fail-closed).
  if (!output.endsWith("\0")) {
    return { scope: { files, renameOldPaths, clean: false }, statuses };
  }
  const tokens = output.split("\0");
  // Trailing NUL terminator: git ends every row's last path column with NUL.
  if (tokens.length > 0 && tokens[tokens.length - 1] === "") tokens.pop();
  let clean = true;
  const statusRe = /^([AMDRCTUXB])(\d*)$/; // status letter + optional similarity score
  let i = 0;
  while (i < tokens.length) {
    const m = statusRe.exec(tokens[i]);
    if (m === null) { clean = false; break; } // interior NUL / unknown status → anomaly
    const letter = m[1];
    i++;
    if (letter === "R" || letter === "C") {
      // 3-field row: OLD path then NEW path.
      if (m[2] === "" || i + 1 >= tokens.length) { clean = false; break; } // bare R/C without score, or truncated
      if (tokens[i] === "" || tokens[i + 1] === "") { clean = false; break; } // empty path column — defensive symmetry with the name-only branch (fail-closed)
      renameOldPaths.push(tokens[i]);
      files.push(tokens[i + 1]);
      statuses.set(tokens[i + 1], letter);
      i += 2;
    } else {
      // #755: git appends a similarity score to a single-path row in exactly one
      // case — `M`, for file rewrites. git-diff(1) RAW OUTPUT FORMAT: "Status
      // letter M may be followed by a score (denoting the percentage of
      // dissimilarity) for file rewrites" (R/C always carry one, but those are
      // 3-field rows handled above). A score on any OTHER single-path letter
      // (A/D/T/U/X/B) is not producible by git → anomaly, fail closed.
      //
      // ⛔ An earlier version of this guard rejected `M<score>` too, on the false
      // premise that scores appear only on R/C rows; `git diff -B --name-status -z`
      // emits `M100` for a rewrite, so that would have hard-blocked a legitimate
      // op the moment any gate diff command gained `-B`. The gate passes no `-B`
      // today, so it was latent — but the invariant was wrong as written.
      if (m[2] !== "" && letter !== "M") { clean = false; break; }
      if (i >= tokens.length) { clean = false; break; }
      if (tokens[i] === "") { clean = false; break; } // empty path token
      files.push(tokens[i]);
      statuses.set(tokens[i], letter);
      i++;
    }
  }
  return { scope: { files, renameOldPaths, clean }, statuses };
}

function execDiffStatusZ(cwd: string, cmd: string): string | null {
  try {
    // NO trim: -z output is NUL-terminated raw path bytes — trimming could
    // strip legitimate leading/trailing whitespace in file names.
    return execSync(cmd, { cwd, encoding: "utf-8", timeout: 5000, maxBuffer: 64 * 1024 * 1024 });
  } catch {
    return null;
  }
}

// DEDUPE ∪ helper for mixed sweep unions (files dedup, renameOldPaths dedup,
// clean AND over the members). Pure + exported (unit-pinned — the mixed arm's
// combination rule is otherwise comment-only).
export function combineScopes(a: DiffScope, b: DiffScope): DiffScope {
  const core: DiffScope = {
    files: Array.from(new Set([...a.files, ...b.files])),
    renameOldPaths: Array.from(new Set([...a.renameOldPaths, ...b.renameOldPaths])),
    clean: a.clean && b.clean,
  };
  // #755: concatenate the per-arm subtraction audits, null-safely AND
  // absence-preservingly — `[...a.subtractions, ...]` would throw
  // `undefined is not iterable` on the G4 literals (index.test.ts:3188/3189/
  // 3194) and on every ordinary scope, while always materialising `[]` would
  // falsify the "absent, never []" contract the emit site keys on.
  // Reads NOTHING else on `a`/`b`, so the G4 pins stay green.
  const subs = [...(a.subtractions ?? []), ...(b.subtractions ?? [])];
  return subs.length > 0 ? { ...core, subtractions: subs } : core;
}

function resolveGitRoot(cwd: string): string {
  try {
    return execSync("git rev-parse --show-toplevel", {
      encoding: "utf-8",
      cwd,
      timeout: 3000,
    }).trim();
  } catch {
    return cwd; // fallback: don't break if git is unavailable
  }
}

// #755: shared per-arm subtraction wrapper. Placed here because all five
// producers route through it — it is the ONLY place a producer gets a ctx, and
// `makeGitSubCtx` is called HERE (the producer owns `arm`/`recordedSide`), so a
// caller can never supply a valid-but-wrong recorded side.
function subtractForArm(
  cwd: string,
  scope: DiffScope,
  statuses: Map<string, string>,
  sub: SubBundle | null | undefined,
  args: { arm: "staged" | "worktree" | "wtPath" | "branch" | "push"; recordedSide: "index" | "worktree" | "wtPath" | "ref"; pathspecs?: string[]; srcRef?: string; trackingRef?: string }
): DiffScope {
  // No bundle ⇒ no subtraction. This is the kill switch and the six `null`
  // wiring positions.
  if (sub === undefined || sub === null) return scope;
  // A parse anomaly routes an unconditional parse-block downstream; the
  // status map is PARTIAL, so it must never be consulted.
  if (!scope.clean) return scope;
  try {
    const ctx = makeGitSubCtx(cwd, { bundle: sub, ...args });
    if (ctx === null) return scope;
    const r = args.arm === "push"
      ? subtractPushArm(scope, statuses, ctx)
      : subtractCommitArm(scope, statuses, ctx);
    // The coupled invariant, failing CLOSED: a scope that shrank without an
    // audit returns the producer's OWN unchanged scope — never a throw (a
    // clean over-gate with an audit line beats a hard "Extension failed"
    // abort, which would block the op either way).
    if (r.audit === null) return scope;
    if (r.scope.files.length === scope.files.length) return scope;
    return { ...r.scope, subtractions: [r.audit] };
  } catch {
    // Fail closed: over-gate, never under-gate.
    return scope;
  }
}

// Staged scope — `git diff --cached`. A git-level failure (missing repo,
// corrupt index) keeps the legacy catch→empty status quo (the op itself will
// fail at git commit time); parse ANOMALIES inside the NUL stream are the
// fail-closed layer and set clean=false.
function runStagedScope(cwd: string, sub?: SubBundle | null): DiffScope {
  const out = execDiffStatusZ(cwd, "git diff --cached --name-status -z");
  if (out === null) return { files: [], renameOldPaths: [], clean: true };
  const { scope, statuses } = parseDiffNameStatusDetailed(out);
  return subtractForArm(cwd, scope, statuses, sub, { arm: "staged", recordedSide: "index" });
}

// #489: the file set a sweep commit (`git commit -a`/`--all`) actually records — the
// tracked WORKING TREE vs HEAD. Unborn HEAD (no commits yet): `git commit -a` records
// only the index (verified empirically), and `git diff HEAD` errors — the staged-diff
// fallback is the exact `-a` set for that state. Any OTHER diff failure (corrupt index,
// permission) is logged and falls back to the staged scope (status-quo semantics; a
// genuinely broken repo fails at `git commit` time anyway) — accepted residual, see the
// #489 plan surface-map row 2.
function runWorktreeScope(cwd: string, sub?: SubBundle | null): DiffScope {
  try {
    execSync("git rev-parse --verify HEAD", { encoding: "utf-8", cwd, timeout: 5000, stdio: "ignore" });
  } catch {
    // Unborn HEAD. Passes NO bundle: the recorded side switches to the index,
    // so forwarding a worktree ctx would subtract branch-authored content.
    return runStagedScope(cwd, null);
  }
  const out = execDiffStatusZ(cwd, "git diff HEAD --name-status -z");
  if (out === null) {
    console.error("[verification-gate] ⚠️ git diff HEAD failed — falling back to staged scope:");
    return runStagedScope(cwd, null);
  }
  const { scope, statuses } = parseDiffNameStatusDetailed(out);
  return subtractForArm(cwd, scope, statuses, sub, { arm: "worktree", recordedSide: "worktree" });
}

// #538: the file set a WT-path commit (`git commit <pathspec>` / `-o`/`--only` /
// `-i`/`--include` — see wtPathCommitInfo) actually records: the NAMED paths'
// WORKING-TREE state vs HEAD. `git diff HEAD --name-status -z -- <pathspecs>` passes the
// raw pathspecs (verbatim globs/magic) to git's own pathspec machinery — single source
// of expansion truth. Shell-single-quote each pathspec first: tokenizePushArgs already
// STRIPPED the user's quoting, so a name containing spaces would otherwise re-split
// (execSync spawns a shell). Unborn HEAD: only-mode on an unborn branch requires the
// pathspec to match a file KNOWN TO GIT (empirically: untracked files error "pathspec
// did not match"), and records the staged file's disk content — the staged set is a
// SOUND SUPERSET of what the commit can record there, so the staged fallback mirrors
// runWorktreeScope with no under-gate. Any OTHER diff failure is logged and falls back
// to the staged scope (status-quo semantics — a repo broken enough to fail pathspec
// diffing fails at `git commit` time anyway; same accepted residual as
// runWorktreeScope). Parse anomalies inside the NUL stream stay fail-closed via
// parseDiffNameStatus (clean=false).
function shellQuoteSingle(s: string): string {
  return "'" + s.replace(/'/g, "'\\''") + "'";
}

function runWtPathScope(cwd: string, pathspecs: string[], sub?: SubBundle | null): DiffScope {
  try {
    execSync("git rev-parse --verify HEAD", { encoding: "utf-8", cwd, timeout: 5000, stdio: "ignore" });
  } catch {
    return runStagedScope(cwd, null); // unborn HEAD — staged set ⊇ what only-mode can record
  }
  const cmd = `git diff HEAD --name-status -z -- ${pathspecs.map(shellQuoteSingle).join(" ")}`;
  const out = execDiffStatusZ(cwd, cmd);
  if (out === null) {
    console.error("[verification-gate] ⚠️ git diff HEAD -- <pathspecs> failed — falling back to staged scope:");
    return runStagedScope(cwd, null);
  }
  const { scope, statuses } = parseDiffNameStatusDetailed(out);
  return subtractForArm(cwd, scope, statuses, sub, { arm: "wtPath", recordedSide: "wtPath", pathspecs });
}

// Branch scope (`gh pr create` + the merge-scope verify path) — origin/main...HEAD.
// Exec failure → clean-empty preserves the documented status-quo catch→[] fail-open
// precedent (#559 plan §1 residual; availability rationale — non-main-default repos and
// transient timeouts must not hard-block).
function runBranchScope(cwd: string, sub?: SubBundle | null): DiffScope {
  const out = execDiffStatusZ(cwd, "git diff origin/main...HEAD --name-status -z");
  if (out === null) return { files: [], renameOldPaths: [], clean: true };
  const { scope, statuses } = parseDiffNameStatusDetailed(out);
  // Live arm: R = HEAD, B = HEAD, T = the RESOLVED trusted base (NOT the
  // hardcoded origin/main this diff uses — when the branch tracks a non-origin
  // remote those differ, and the arm can fire legitimately).
  return subtractForArm(cwd, scope, statuses, sub, { arm: "branch", recordedSide: "ref", srcRef: "HEAD" });
}

// #540 M2 — the record-set a command's EXECUTED commits will add to the branch when a
// `gh pr create` follows them in the SAME tool_call. The gh arm's branch scope
// (`git diff origin/main...HEAD`) is computed BEFORE the in-command commits run, so a
// sweep/bare/pathspec commit's content (dirty WT code, staged code) is invisible to it →
// empty-branch allow → the PR ships unverified content. The record scope mirrors the
// non-gh routing EXACTLY (#489/#538 classifiers, same producers): pure sweep → WT;
// mixed → union(staged, WT); WT-path forms → union(staged, named-path WT) with the
// full-WT fallback for --pathspec-from-file; otherwise (bare/amend/vacuous) → staged.
// The caller unions this with runBranchScope — never replaces it (pre-existing branch
// commits not recorded by THIS command stay in scope).
function ghCommitRecordScope(command: string, cwd: string, sub?: SubBundle | null): DiffScope {
  // Router only — it threads the bundle to whichever producer it delegates to;
  // each delegate builds its own ctx with its own arm/recordedSide.
  const scls = commitSweepClass(command);
  if (scls === "sweep") return runWorktreeScope(cwd, sub);
  if (scls === "mixed") return combineScopes(runStagedScope(cwd, sub), runWorktreeScope(cwd, sub));
  const wp = wtPathCommitInfo(command);
  if (wp !== null) {
    const namedWt = wp.pathspecFromFile ? runWorktreeScope(cwd, sub) : runWtPathScope(cwd, wp.pathspecs, sub);
    return combineScopes(runStagedScope(cwd, sub), namedWt);
  }
  return runStagedScope(cwd, sub);
}

// ── Pure gate decision (#559 T1) ─────────────────────
// Single post-resolution routing site for the hook: routes the four outcomes
// of a resolved scope — parse-block (NUL anomaly: unconditional, BEFORE the
// whole allow chain — no #7591 counter, no lastBlockedFiles; a format drift
// must never silently allow), empty-allow, exempt-allow (the content-shape
// exemption now measures rename SOURCES too: a docs-shaped file set is exempt
// only when EVERY rename/copy OLD path is also shape-exempt — `git mv
// src/app.ts docs/code.md` gates ON), verify.
// ⛔ Ordering is load-bearing: the hook must call this BEFORE the #7591
// auto-bypass region — a refactor routing parse-block after the blockAttempts
// increment re-opens vacuous auto-bypass.

export type ScopeGateDecision =
  | { kind: "parse-block"; block: { block: true; reason: string }; event: "gate_block_parse_failure" }
  | { kind: "empty-allow" }
  | { kind: "exempt-allow" }
  | { kind: "verify" };

export function applyScopeGate(
  changedFiles: string[],
  renameOldPaths: string[],
  clean: boolean,
  bare: boolean,
  isExempt: (p: string) => boolean,
): ScopeGateDecision {
  // Parse-block FIRST — an anomaly is never allowed, even when the file set
  // is empty (a drift that swallows rows must block, not ride the empty or
  // the #7591 path).
  if (!clean) {
    return {
      kind: "parse-block",
      event: "gate_block_parse_failure",
      block: {
        block: true,
        reason: [
          "⛔ Verification gate — diff parse anomaly (name-status -z format drift).",
          "  The git diff output could not be parsed cleanly; nothing was allowed.",
          "  → Re-run the operation; if it persists, the gate's diff parser needs a format update.",
          "  (No verifier dispatch can clear this — only ELDATO_SKIP_VGATE escapes.)",
        ].join("\n"),
      },
    };
  }
  if (changedFiles.length === 0) return { kind: "empty-allow" };
  // Content-shape exemption. Commit-form guard (bare) + destination shape +
  // RENAME-SOURCE shape (issue #559 T1): a rename/copy whose OLD path is not
  // shape-exempt forces the gate ON even when every listed file is docs-/
  // css-shaped. Tree-observability limit (documented): R rows fire only when
  // the rename source exists in a compared tree (base/HEAD/index) — code
  // content whose path is docs-shaped at EVERY observable tree (in-session
  // add→mv, in-range add→mv) is structurally indistinguishable from a docs
  // create and remains the accepted residual; the copying-code-into-fresh-
  // `.md` residual is the same class.
  if (bare && changedFiles.every((f) => isExempt(f)) && renameOldPaths.every((p) => isExempt(p))) {
    return { kind: "exempt-allow" };
  }
  return { kind: "verify" };
}

// Pure consumption helper for the hook's routing site. The hook's diff+gate
// region is e2e-unreachable for parse-block (real git cannot emit a NUL
// anomaly), so the four routes are unit-pinned here — parse-block carries the
// event name + block shape with NO lastBlockedFiles/blockAttempts side
// effects (the hook emits the audit + returns block; it never writes block
// state, so #7591 auto-bypass is structurally unreachable for parse-blocks).

export type ScopeGateRoute =
  | { action: "parse-block"; event: "gate_block_parse_failure"; block: { block: true; reason: string } }
  | { action: "empty-allow" }
  | { action: "exempt-allow"; files: string[] }
  | { action: "verify"; files: string[] };

export function routeScopeGate(gate: ScopeGateDecision, files: string[]): ScopeGateRoute {
  switch (gate.kind) {
    case "parse-block":
      return { action: "parse-block", event: gate.event, block: gate.block };
    case "empty-allow":
      return { action: "empty-allow" };
    case "exempt-allow":
      return { action: "exempt-allow", files };
    case "verify":
      return { action: "verify", files };
  }
}

function hashFile(projectRoot: string, filePath: string): string {
  const absPath = resolve(projectRoot, filePath);
  const content = readFileSync(absPath);
  return createHash("sha256").update(content).digest("hex");
}

/**
 * #320: verifier-submitted hashes may be sha1 (40-hex) or sha256 (64-hex) —
 * LLM verifiers pick whatever hash tool they know, and an algorithm mismatch
 * must not false-block an unchanged file. Accept a match with EITHER
 * algorithm (inferred by hex length; hex compare is case-insensitive). The
 * check is anti-drift (file changed between verification and commit) and any
 * content change flips both digests, so sha1 acceptance does not weaken it.
 * Unknown lengths are compared as sha256 → fail closed (no match → block).
 */
export function hashMatchesDisk(projectRoot: string, filePath: string, storedHash: string): boolean {
  const absPath = resolve(projectRoot, filePath);
  const content = readFileSync(absPath);
  const algo = storedHash.length === 40 ? "sha1" : "sha256";
  return createHash(algo).update(content).digest("hex") === storedHash.toLowerCase();
}

// #7595: verifier sub-agents may return absolute paths (e.g.
// "/Users/x/repo/src/a.ts") or root-relative forms ("./src/a.ts") while
// git diff yields repo-relative paths ("src/a.ts"). Registry keys must be
// repo-relative or the block check never matches and every commit is blocked
// as "unverified" despite fresh PASS responses. Normalize before keying.
export function normalizeRegistryPath(projectRoot: string, filePath: string): string {
  const abs = resolve(projectRoot, filePath);
  // realpath both sides: macOS /var → /private/var (symlink) and other
  // symlinked roots must not produce ../ keys that never match git's
  // realpath'd toplevel. Fall back to lexical paths when a path is gone.
  let realRoot = projectRoot;
  let realAbs = abs;
  try { realRoot = realpathSync(projectRoot); } catch { /* keep lexical */ }
  try {
    // realpath the PARENT DIR only. realpathSync(abs) resolves a symlinked
    // FILE to its target, so a committed symlink (e.g. agent-infra drift
    // fixtures, scripts/ and CI-workflow links) would be registered under the
    // TARGET's relative path — a key that never matches git's verbatim path
    // and blocks every commit touching it (#305).
    realAbs = join(realpathSync(dirname(abs)), basename(abs));
  } catch { /* keep lexical */ }
  const rel = relative(realRoot, realAbs);
  return rel === "" ? filePath : rel;
}

// Merge a verifier PASS's verified_files into the registry.
// - #37: every key is a compound key (worktree-root::repo-relative), preventing
//   cross-worktree hash contamination.
// - #7595: every path is normalized to repo-relative before compounding.
// - #38/#7595: re-verification of an already-known path ALWAYS updates its
//   hash — the verifier is the authority. A stale lastBlockedFiles list (the
//   previous block in the session may have covered different files) must not
//   drop the update.
// - #5673: brand-new paths are still scoped to the blocked diff, so a
//   full-repo-scan response can't mark arbitrary files as verified.
export function mergeVerifiedFiles(
  verifiedSet: Map<string, string>,
  blockAttempts: Map<string, number>,
  verifiedFiles: VerifiedFile[],
  projectRoot: string,
  lastBlockedFiles: string[]
): { merged: number; skipped: number } {
  const normRoot = normalizeWorktreeRoot(projectRoot);
  const blockedSet = new Set(lastBlockedFiles.map(f => compoundKey(normRoot, f)));
  let merged = 0;
  let skipped = 0;
  for (const vf of verifiedFiles) {
    const relPath = normalizeRegistryPath(projectRoot, vf.path);
    const key = compoundKey(normRoot, relPath);
    const known = verifiedSet.has(key);
    const inBlockedDiff = lastBlockedFiles.length === 0 || blockedSet.has(key);
    if (!known && !inBlockedDiff) {
      skipped++;
      continue;
    }
    verifiedSet.set(key, vf.hash);
    blockAttempts.delete(key);
    merged++;
  }
  return { merged, skipped };
}

// #336: hash-and-merge a set of files into the registry using their CURRENT
// disk state. Used when a verifier returns PASS WITHOUT verifier-supplied
// hashes (plain-text PASS, or JSON with empty verified_files): the verifier
// judged the files ready but supplied no per-file hashes, so the gate records
// the current disk hash. The caller diff-scopes the file list (scopeFiles) so
// a hash-less PASS can never mark arbitrary files verified. Recording the
// current hash (not a blind "verified forever") preserves fail-closed: a
// post-PASS edit flips the hash and the block check re-blocks.
export function hashAndMergeFiles(
  verifiedSet: Map<string, string>,
  blockAttempts: Map<string, number>,
  files: string[],
  projectRoot: string
): number {
  const normRoot = normalizeWorktreeRoot(projectRoot);
  let merged = 0;
  for (const file of files) {
    try {
      const relPath = normalizeRegistryPath(projectRoot, file);
      if (relPath.startsWith("..") || isAbsolute(relPath)) continue; // out-of-root — inert (#190 review)
      const key = compoundKey(normRoot, relPath);
      const hash = hashFile(projectRoot, relPath);
      verifiedSet.set(key, hash);
      blockAttempts.delete(key);
      merged++;
    } catch {
      // file may not exist at expected path — skip (deleted/unhashable)
    }
  }
  return merged;
}

// ── JSON extraction ───────────────────────────────────

/**
 * Backward string-aware scan for the matching open brace of a candidate
 * closed at `closeIdx`. Tracks string state ("…") and escaped quotes so
 * braces inside string values never anchor a slice. Returns -1 when no
 * balanced open brace exists (unbalanced prose → caller skips, never aborts).
 * #132: the old lastIndexOf("{")…lastIndexOf("}") pair was string-blind and
 * grabbed the innermost object (or the appended stderr noise object).
 */
function findMatchingOpenBrace(text: string, closeIdx: number): number {
  let depth = 0;
  let inString = false;
  for (let i = closeIdx; i >= 0; i--) {
    const ch = text[i];
    if (inString) {
      if (ch === '"' && !isEscaped(text, i)) {
        inString = false;
      }
      continue;
    }
    if (ch === '"') {
      // Enter string state only on a real (un-escaped) quote — the backslash
      // parity check handles odd-count literal quotes inside values (P2).
      if (!isEscaped(text, i)) inString = true;
    } else if (ch === "}") {
      depth++;
    } else if (ch === "{") {
      depth--;
      if (depth === 0) return i;
    }
  }
  return -1;
}

/** True when the char at `idx` is escaped by an ODD run of backslashes. */
function isEscaped(text: string, idx: number): boolean {
  let bs = 0;
  for (let i = idx - 1; i >= 0 && text[i] === "\\"; i--) bs++;
  return bs % 2 === 1;
}

/**
 * Enumerate parseable JSON candidates from text, newest-first (reverse
 * scan, string-aware). Returns every balanced brace-matched slice that
 * JSON.parse accepts — schema gating happens in extractJson.
 * On a parse failure we advance past the CLOSE brace (not the open one) so
 * inner balanced candidates inside an unparseable outer slice are still
 * enumerated (P2: lazy-model `{result: {...}}` outer keys).
 * Extraction seam: loop-enforcer shares this bug class (#135); move these
 * pure functions to extensions/shared/json-scan.ts when a second consumer
 * exists (rule of two).
 */
function extractJsonCandidates(text: string): unknown[] {
  const candidates: unknown[] = [];
  let idx = text.length - 1;
  while (idx >= 0) {
    const close = text.lastIndexOf("}", idx);
    if (close === -1) break;
    const open = findMatchingOpenBrace(text, close);
    if (open !== -1) {
      const slice = text.slice(open, close + 1);
      try {
        candidates.push(JSON.parse(slice));
        idx = open - 1;
      } catch {
        // unparseable candidate — skip its CLOSE and retry inner candidates
        idx = close - 1;
      }
    } else {
      idx = close - 1;
    }
  }
  return candidates;
}

export function extractJson(text: string): VerificationResult | null {
  // Step 1: raw JSON.parse — gated: only schema-valid results are returned.
  try {
    const parsed = JSON.parse(text.trim()) as VerificationResult;
    if (isValidResult(parsed)) return parsed;
  } catch {
    // continue
  }

  // Step 2: last ```json fence — gated; a schema-invalid last fence falls
  // through to candidate enumeration (a valid earlier fence still wins).
  const fenceMatch = text.match(/```json\s*([\s\S]*?)```/g);
  if (fenceMatch) {
    for (let i = fenceMatch.length - 1; i >= 0; i--) {
      try {
        const parsed = JSON.parse(fenceMatch[i].replace(/```json\s*|\s*```/g, "").trim()) as VerificationResult;
        if (isValidResult(parsed)) return parsed;
      } catch {
        // continue scanning earlier fences
      }
    }
  }

  // Step 3: brace-matched reverse candidate scan — newest-first; the LAST
  // schema-valid candidate wins (the model emits the verdict last, and the
  // appended stderr noise is schema-invalid so it is skipped). #132.
  for (const candidate of extractJsonCandidates(text)) {
    if (isValidResult(candidate)) return candidate;
  }

  return null;
}

// ── Schema validation ─────────────────────────────────

// Placeholder values the block message's format template shows as examples
// ("path":"...","hash":"...") — a literal-LLM response echoing them would
// register a never-matching hash and block commits forever (#132).
const PLACEHOLDER_VALUES = new Set(["", "...", "__placeholder__"]);

export function isValidResult(obj: any): obj is VerificationResult {
  if (!obj || typeof obj !== "object") return false;
  if (typeof obj.status !== "string" || !["PASS", "FAIL"].includes(obj.status)) return false;
  if (!Array.isArray(obj.failures)) return false;
  if (!Array.isArray(obj.verified_files)) return false;
  return obj.verified_files.every(
    (f: any) =>
      typeof f === "object" &&
      f !== null &&
      typeof f.path === "string" &&
      !PLACEHOLDER_VALUES.has(f.path) &&
      typeof f.hash === "string" &&
      !PLACEHOLDER_VALUES.has(f.hash)
  );
}

// #561: ceremony-diagnostics helpers (module-level for the pure-export unit
// suite). The tool_result handler records dispatch outcomes; the NEXT blocked
// git op reads them and names the failure class + remedy, escalating at the
// 3-strike threshold. Messaging only — see the state-block comment for the
// #132 class taxonomy (dispatch-format classes move the streak; judgment /
// zero-merge classes record remedy text only; any merge resets).
const DISPATCH_CLASS_REMEDIES: Record<DispatchFailureClass, string> = {
  "empty-content": "the verifier returned empty content — its response must contain PASS on its own line, or the exact JSON {status, failures, verified_files}. The dispatch prompt must say `verify files:` (PLURAL) naming the repo-relative paths from the block message.",
  "no-text": "the verifier returned no text content — same requirement: PASS on its own line or the exact JSON {status, failures, verified_files} shape.",
  unparseable: "the verifier response was not parseable — it must contain PASS on its own line, or exact JSON {status, failures, verified_files}. Re-dispatch with the prompt exactly as printed above.",
  "fail-open-refused": "the verifier response was unparseable and the fail-open merge was REFUSED for this task sub-agent (#285) — files were NOT recorded. Re-dispatch a verifier whose response is PASS on its own line or the exact JSON shape.",
  "fail-verdict": "the verifier judged the files NOT ready — do NOT re-dispatch blindly; address the failures it listed, fix the files, then re-dispatch.",
  "zero-merge-pass": "the verifier PASSed but nothing was recorded (its file list matched no block/diff scope). Re-dispatch naming the EXACT blocked files printed above.",
};

/**
 * #561: state-bearing diagnostics appended to a blocked git op after a failed
 * [VGATE] dispatch. Empty state (lastDispatchClass null) appends nothing —
 * fresh-session messages are byte-identical, keeping all pinned message tests
 * intact. `audience` splits the escalation copy: an interactive session has no
 * parent to return to; a task-capable sub-agent is told to stop and surface the
 * block when it cannot produce a compliant verifier response.
 *
 * Escalation fires only when the LAST dispatch was a dispatch-FORMAT class —
 * the streak counts format failures, and a judgment/zero-merge outcome that
 * lands at streak ≥ 3 must never render the "malformed dispatches" header
 * (it would mislabel a healthy FAIL verdict as a format failure, #132).
 */
const FORMAT_CLASSES: ReadonlySet<DispatchFailureClass> = new Set(["empty-content", "no-text", "unparseable", "fail-open-refused"]);
export function formatCeremonyDiagnostics(klass: DispatchFailureClass, streak: number, audience: "interactive" | "capable" = "capable"): string {
  const remedy = `  ${DISPATCH_CLASS_REMEDIES[klass]}`;
  if (streak >= VGATE_FAILURE_THRESHOLD && FORMAT_CLASSES.has(klass)) {
    const escalation =
      audience === "interactive"
        ? "A 3rd consecutive malformed dispatch auto-disables the gate for this session (one-way latch, #132) — fix the dispatch to satisfy the format requirements above and re-run the session; do NOT re-dispatch the same verifier shape (identical re-dispatches also trip the #7591 block-attempt auto-bypass)."
        : "The gate stays ACTIVE and will NOT auto-bypass (#285). Fix the dispatch to satisfy the format requirements above, then retry the git operation. If you cannot produce a compliant verifier response, stop and return to the parent session with this block message.";
    return [
      "",
      `⛔ Escalation: ${streak} consecutive malformed VGATE dispatches (last: ${klass}).`,
      "  STOP re-dispatching the same verifier shape.",
      remedy,
      escalation,
    ].join("\n");
  }
  return ["", `⚠️ Previous VGATE dispatch did not verify these files (${klass} — attempt ${streak}):`, remedy].join("\n");
}

/** #561: a dispatch-FORMAT failure (empty/no-text/unparseable/refused) — moves the streak. */
export function recordDispatchFailure(klass: DispatchFormatClass): void {
  lastDispatchClass = klass;
  dispatchStreak++;
}

/** #561: a judgment/zero-merge outcome — remedy text only, NEVER moves the streak (#132). */
export function recordDispatchJudgment(klass: DispatchFailureClass): void {
  lastDispatchClass = klass;
}

/** #561: any merged>0 dispatch proves dispatch health — reset class + streak. */
export function recordDispatchSuccess(): void {
  lastDispatchClass = null;
  dispatchStreak = 0;
}

/** #561: read-only state accessor — lets the pure-export unit suite pin the taxonomy post-conditions (record fns return void). */
export function dispatchState(): { klass: DispatchFailureClass | null; streak: number } {
  return { klass: lastDispatchClass, streak: dispatchStreak };
}

/**
 * #285 P1-A Surface 1: the sub-agent block message, task-tool-aware. The old
 * text unconditionally claimed "This session HAS the task tool" — false for
 * the 7 task-restricted user agents (--tools allowlists without task: planner,
 * verifier, reviewer, scout, code-reviewer, bug-scanner, product-verifier).
 * Task-capable → in-band self-satisfy (dispatch [VGATE] via the task tool,
 * retry). Task-restricted → FINAL block: return to the parent session (it runs
 * the verification ceremony and will re-dispatch). The argv param is the e2e
 * seam (the harness's process.argv has no --tools → task-capable by default).
 */
export function buildSubAgentBlockMessage(
  reasons: string[],
  cwd: string,
  allBlocked: string[],
  argv: string[] = process.argv,
): string {
  const taskCapable = argvAllowsTask(argv);
  const action = taskCapable
    ? [
        "  This session has the task tool, so verify them in-band",
        "  before retrying — do not ask the parent to re-run this task.",
        "",
        "  → Dispatch your own VGATE verification (self-satisfy the gate):",
        `    task(prompt='[VGATE] verify files: ${allBlocked.join(' ')}. Classification: <UI|backend|both>. Project root: ${cwd}. Return ONLY JSON: {"status":"PASS","failures":[],"verified_files":[{"path":"<repo-relative>","hash":"<sha256>"}]}.', ...)`,
        "",
        "  → On PASS, retry the git operation. Sub-agent commits get NO #7591",
        "    auto-bypass: an unverified commit blocks every time until verified.",
      ]
    : [
        "  This session is task-RESTRICTED (task is not in the tool allowlist),",
        "  so the gate cannot be satisfied in-band.",
        "  STOP — this block is final; do not bypass; return to the parent",
        "  session (it runs the verification ceremony and will re-dispatch you).",
      ];
  return [
    "⛔ Verification gate — blocking git operation (sub-agent).",
    "",
    ...reasons.map(l => l.replace("verifier sub-agent", "the parent session")),
    "",
    "  This session is a task sub-agent: it inherits the parent session's",
    "  verified-file registry via the bridge file, and these files are NOT",
    "  covered by it.",
    ...action,
  ].join("\n");
}

// ── Plugin ────────────────────────────────────────────

export default function (pi: ExtensionAPI) {
  try {

  register("verification-gate");

  // ── session_start ──────────────────────────────────
  pi.on("session_start", async (_event, _ctx) => {
    verifiedSet.clear();
    // #190: recover verification state from the bridge, root-filtered + stored-
    // hash match-or-drop. (Replaces the blind loader — the bridge now persists
    // compound keys with verifier-authoritative hashes.)
    const sessionRoot = normalizeWorktreeRoot(resolveWorktreeAwareRoot(resolveGitRoot(process.cwd())));
    const recovered = recoverBridgeForRoot(sessionRoot);
    if (recovered > 0) {
      console.log(`[verification-gate] 📂 Recovered ${recovered} verified files from bridge`);
    } else if (isTaskSubAgent()) {
      // #264 P2: bridge-absent (or stale) task-sub-agent session — the parent's
      // verified-file registry is not available here, so EVERY changed-file
      // commit will block until this session self-dispatches VGATE verification.
      // Surfaced in the child's startup output so the parent sees it in the
      // task result instead of discovering the dead-end only via a silent
      // all-block task report.
      // #285 P1-A Surface 2: task-tool-aware instruction — a restricted
      // sub-agent cannot self-satisfy in-band; the block is final.
      const taskCapable = argvAllowsTask();
      console.log(`[verification-gate] ⚠️ Sub-agent session started with 0 bridge-recovered files for root ${sessionRoot} — the parent's verified-file registry is not available to this session; every changed-file commit will block until VGATE verification is dispatched ${taskCapable ? "(in-band via the task tool)." : "by the parent session — this session is task-restricted, so return to the parent (the block is final)."}`);
      appendJsonl({ event: "gate_recovery_empty", extension: "verification-gate", subagent: true, root: sessionRoot, session_cwd: process.cwd() });
    }
    lastRecoveryMtime = 0;
    vgateFailures = 0;
    lastBlockedCwd = null;
    lastBlockedFiles = [];
    pendingRehash = null;
    pendingRehashFiles = [];
    blockAttempts.clear();
    lastDispatchClass = null; // #561: ceremony diagnostics are session-scoped
    dispatchStreak = 0;

    // Detect: disabled when no write/edit capability or opt-out
    // ponytail: dedicated escape hatch — ELDATO_ALLOW_MAIN_EDITS is the worktree
    // guard's bypass and must not disable commit verification (#7470)
    if (process.env.ELDATO_SKIP_VGATE === "1") {
      // #285 Fix B: a polluted parent launch env (swarm_daemon sets
      // ELDATO_SKIP_VGATE=1) must NOT disable the gate in a task child — the
      // escape hatch belongs to the interactive parent session only; the child
      // either self-satisfies VGATE in-band or returns to the parent. The
      // deliberate-flag case (an emergency ELDATO_SKIP_VGATE=1 set by a human
      // for a task sub-agent) is refused the same way: the gate stays ACTIVE.
      if (refuseAutoBypassForSubAgent()) {
        console.warn(`[verification-gate] ${subAgentProceedInstruction()}`);
      } else {
        extensionEnabled = false;
        console.log("[verification-gate] ⏸️  Disabled — ELDATO_SKIP_VGATE=1");
        appendJsonl({ event: "gate_bypass", extension: "verification-gate", reason: "escape_hatch", session_cwd: process.cwd() }); // #60: durable audit record (fail-safe)
      }
    } else {
      extensionEnabled = true;
    }
  });

  // ── session_shutdown ───────────────────────────────
  pi.on("session_shutdown", async (_event, _ctx) => {
    verifiedSet.clear();
    // #190: clearBridge is intentionally NOT called here. The bridge is the
    // cross-process recovery channel; a sub-agent's shutdown (print-mode pi -p
    // fires session_shutdown on exit) must not delete the parent's bridge, and
    // D1's stored-hash match-or-drop makes any stale entry inert (fail-closed).
    lastBlockedCwd = null;
    lastBlockedFiles = [];
    pendingRehash = null;
    pendingRehashFiles = [];
  });

  // ── tool_call: block git/gh ops ────────────────────
  pi.on("tool_call", async (event, _ctx): Promise<ToolCallEventResult | undefined> => {
    if (!isToolCallEventType("bash", event)) return undefined;
    if (!extensionEnabled) return undefined;

    // #37: per-command bypass — read ELDATO_SKIP_VGATE at hook time,
    // not only at session load. Allows mid-session emergency bypass
    // when a stale-hash block strikes.
    if (process.env.ELDATO_SKIP_VGATE === "1") {
      if (refuseAutoBypassForSubAgent()) {
        // #285 Fix B: refused — fall through so the command is STILL gated
        // (blocked unless the files are verified); the WARN above + this
        // instruction tell the child how to proceed.
        console.warn(`[verification-gate] ${subAgentProceedInstruction()}`);
      } else {
        console.log("[verification-gate] ⏩ Bypassed — ELDATO_SKIP_VGATE=1 (per-command)");
        appendJsonl({ event: "gate_bypass", extension: "verification-gate", reason: "per_command_escape_hatch", session_cwd: process.cwd() }); // #60: durable audit record (fail-safe)
        return undefined;
      }
    }

    const command = String(event.input.command ?? "");
    if (!isGitOp(command)) return undefined;

    // #7574: re-hash verified files if a prior git commit was allowed.
    // lint-staged (pre-commit hook) may have modified files (ESLint --fix),
    // changing their hashes. Capture the post-lint state before the next check.
    // Determine cwd — prefer cd prefix in command (worktree support)
    const inputCwd = event.input.cwd ? String(event.input.cwd) : process.cwd();
    const cdPath = extractCdPath(command);
    const cwd = resolveWorktreeAwareRoot(resolveGitRoot(cdPath ?? inputCwd));

    // #190: mid-session bridge recovery FIRST — defense-in-depth for the
    // incident's event-miss class (a merge that landed via another path, e.g.
    // a sub-agent's own tool_result handler, becomes visible at the next git
    // op). Must run BEFORE the pendingRehash writeBridge snapshot: the rehash
    // overwrites the bridge with the parent registry, which would destroy a
    // sub-agent's freshly-written mid-session entry before recovery could
    // merge it (review #214 ordering bug).
    recoverBridgeForRoot(normalizeWorktreeRoot(cwd));

    // #190: narrowed to the allowed commit's files (pendingRehashFiles) — only
    // those could have been touched by lint-staged; re-hashing the whole root
    // would re-bless unrelated verified files from disk.
    if (pendingRehash !== null) {
      const rehashRoot = pendingRehash;
      pendingRehash = null;
      const rehashFiles = pendingRehashFiles;
      pendingRehashFiles = [];
      const normRehashRoot = normalizeWorktreeRoot(rehashRoot);
      let rehashed = 0;
      for (const f of rehashFiles) {
        const key = compoundKey(normRehashRoot, normalizeRegistryPath(rehashRoot, f));
        if (!verifiedSet.has(key)) continue;
        try {
          verifiedSet.set(key, hashFile(normRehashRoot, normalizeRegistryPath(rehashRoot, f)));
          rehashed++;
        } catch { /* file may have been deleted */ }
      }
      if (rehashed > 0) {
        writeBridge(rehashRoot, Array.from(verifiedSet.keys()));
        console.log(`[verification-gate] 🔄 Re-hashed ${rehashed} files after commit (lint-staged may have modified them)`);
      }
    }

    // #472 mechanism (b): delete-shaped pushes ship NO local file content — a
    // remote-ref deletion must not trigger a whole-index staged-diff check
    // (the #470 cleanup block over another session's parked WIP). Short-circuit
    // BEFORE any diff computation — THIS op creates no NEW verifiedSet/bridge
    // entries (a pendingRehash armed by a PRIOR allowed commit may already
    // have re-hashed + written the bridge above — content-neutral, no new
    // blessings). Purity-gated (isDeletionPush): any content refspec / git
    // commit / gh pr op in the command falls back to today's gating
    // (fail-closed). #487: the CONTENT half of a push is now range-scoped
    // (resolvePushRangeScope below — pushed range vs the whole index); the
    // delete short-circuit itself is untouched and still fires first.
    if (isDeletionPush(command)) {
      console.log("[verification-gate] ⏭️ Skipping VGATE — delete-shaped push: no local content ships");
      logGateSkip("delete_push_no_content", command, cwd);
      return undefined;
    }

    // #540 M1 — in-batch mutation-chain REFUSAL (state mutation + commit in ONE tool_call).
    // The hook snapshot is taken BEFORE the command runs; a command that writes/stages
    // content in-batch and then commits it (echo > f.ts && git add f.ts && git commit,
    // git add x && git commit, … && git commit -am y) shows an EMPTY diff at hook time →
    // the empty-allow would let unverified content land in HEAD (the #540 residual,
    // pre-existing since #38). Refuse the SHAPE — the only sound pre-execution action for
    // content that does not exist at hook time — and require the mutation + commit to be
    // separate tool_calls so the pure commit's record-set sits in the hook snapshot and
    // the normal scopes bound it. ⛔ Load-bearing placement: AFTER recoverBridgeForRoot +
    // the top-of-op pendingRehash loop + the delete-push short-circuit (scenario 41's
    // post-fix greenness depends on the Leg-A allowed commit's armed pendingRehash
    // executing before ANY block return) and BEFORE the sweep/WT/gh scope computation
    // (a refusal after empty-allow is reachable would re-open the hole). No
    // blockAttempts / lastBlockedFiles writes — an unverifiable SHAPE must never
    // auto-bypass on repetition (parse-block parity): only ELDATO_SKIP_VGATE escapes.
    if (commitChainMutationClass(command) === "in-batch-mutation") {
      appendJsonl({ event: "gate_block_in_batch_chain", extension: "verification-gate", reason: "state_mutation_before_commit_same_tool_call", session_cwd: process.cwd(), command: redactCommand(command), target_cwd: cwd });
      console.log("[verification-gate] 🚫 Blocked — in-batch mutation chain (state mutation + commit in one command)");
      return {
        block: true,
        reason: [
          "⛔ Verification gate — in-batch mutation chain: this command both MUTATES repo state and COMMITS in a single tool_call.",
          "  The gate verifies the state that exists BEFORE the command runs; content created or staged inside the same",
          "  command (file writes, git add/checkout/reset/restore/rm, program output) is invisible to it — an empty",
          "  pre-state would ride the 'no changed files' allow and commit unverified content.",
          "  → Split the operation: run the file write / staging as its OWN tool_call, then commit separately.",
          "    The pure commit is then gated against the real staged/working-tree state (this refusal does NOT",
          "    auto-bypass — a repeated identical chain is refused every time).",
          "  → Or set ELDATO_SKIP_VGATE=1 to bypass (emergency only).",
        ].join("\n"),
      };
    }

    // Compute diff — #489: auto-sweep commits (`-a`/`--all`) record the
    // working tree, not just the index; their verification file set must be
    // HEAD-vs-working-tree (`git diff HEAD` — exactly what the sweep commits)
    // or the staged-docs verifier PASS lets the swept code ride unverified
    // (D2 forces the gate to run but cannot widen the file set). Classifier:
    // "sweep" (pure-sweep command) → WT diff only (no wasted staged
    // subprocess); "mixed" (sweep + non-sweep commit in one command) →
    // deduped union(staged, WT) — a WT-only scope would blind the gate to
    // index-only content a BARE commit in the chain records (NAME-scoped:
    // disk-hash verification cannot verify staged-only content whose disk
    // state equals HEAD — pre-existing limitation of the disk-based verifier,
    // not introduced here); "none" → today's staged scope. Mixed sweep+gh-pr
    // chains fall to the gh arm below, which widens the branch scope to
    // union(branch, commit-record-scope) when the command executes a commit
    // (#540 M2 — the in-command commit's record-set is invisible to the gh
    // branch diff computed at hook time). ⛔ This block sits
    // AFTER the top-of-op pendingRehash loop + recoverBridgeForRoot — do not
    // move it above them (scenario 41's post-fix greenness depends on the
    // Leg-A allowed commit's armed pendingRehash executing before the block
    // check).
    const sweepClass = commitSweepClass(command);
    // #538: WT-path commit forms (pathspec / `-o`/`--only` / `-i`/`--include` — see
    // wtPathCommitInfo) record the NAMED paths' WORKING-TREE state, not just the staged
    // index — the same hole class as #489's `-a` sweep, over a PARTIAL (named) file set.
    // Consulted only when the sweep classifier says "none": a sweep command is already
    // handled by the sweep-first branch below (its full-WT scope ⊇ any named-path
    // scope), and gh chains route through the gh arm whose commit+gh widening unions
    // the named-path record-set when a commit executes (#540 M2).
    // Pure detector (zero subprocess) — commit-bearing commands still resolve fast.
    const wtPath = wtPathCommitInfo(command);
    // #755 — read the kill switch ONCE per op, then build the OP-LEVEL bundle
    // ONCE. The bundle (not a ctx) is threaded below; each producer builds its
    // own SubCtx inside subtractForArm, so a valid-but-wrong recordedSide has no
    // syntactic representation. When the flag is set, `sub` is null at every
    // position ⇒ today's over-broad scope is restored, with one audited marker.
    const subDisabled = process.env.ELDATO_VGATE_NO_SUBTRACT === "1";
    const sub: SubBundle | null = subDisabled ? null : makeSubBundle(cwd);
    if (subDisabled) {
      console.log("[verification-gate] ℹ️ Merge-scope subtraction disabled (ELDATO_VGATE_NO_SUBTRACT)");
      logGateSkip("subtract_disabled_by_env", command, cwd); // silence would be inconsistent with ELDATO_SKIP_VGATE, which is audited
    }
    let scope: DiffScope;
    if (sweepClass !== "none" && !GH_PR_PATTERN.test(command)) {
      const worktree = runWorktreeScope(cwd, sub);
      scope = sweepClass === "sweep" ? worktree
        : combineScopes(runStagedScope(cwd, sub), worktree);
    } else if (GH_PR_PATTERN.test(command)) {
      // #204: `gh pr merge` merges REMOTELY. Only the PR's own repo+head can
      // be verified locally; anything else is unrelated branch residue that
      // must neither block nor reach verifiedSet/bridge (drift contamination).
      // `gh pr create` is NOT scoped — its diff IS this branch's files. The
      // merge-vs-create split is verb-anchored (isMergeCommand), so a create
      // whose --body merely MENTIONS "gh pr merge <n>" is never routed here.
      // ⛔ PRESERVE VERBATIM — the merge-scope skip below returns undefined
      // (console.log + logGateSkip) and must not be dropped (scenario 19).
      if (isMergeCommand(command)) {
        const decision = resolveMergeScope(command, cwd);
        if (!decision.verify) {
          console.log(`[verification-gate] ⏭️ Skipping verification for gh pr merge — ${decision.reason}: nothing local represents the PR`);
          logGateSkip(decision.reason, command, cwd); // #60: durable audit record — skipped verification must leave a trace
          return undefined; // before computeBranchDiff: no files, no block, no registry/bridge writes
        }
      }
      // #540 M2 — gh+commit chains: `git commit -am x && gh pr create` (or a bare/pathspec
      // commit followed by gh pr create) computes the branch scope BEFORE the in-command
      // commit runs — the commit's own record-set (dirty WT for a sweep, staged for a bare
      // commit, named-path WT for pathspec forms) is invisible to `git diff
      // origin/main...HEAD` → an empty branch → empty-allow → unverified content ships in
      // the PR. When the command PROVABLY executes a commit (commandRunsCommit — prose in
      // --body/echo NEVER counts) AND contains `gh pr create` (create-only: the op that
      // ships THIS branch; a same-command `gh pr merge` keeps the #204 machinery above),
      // widen to union(branch, ghCommitRecordScope) — the record scope mirrors the
      // #489/#538 routing exactly. `gh pr create && git commit` shapes never reach here
      // (M1's ordering refusal fires first — the gh op is a mutation candidate preceding
      // the commit). Pure gh pr create (no executed commit) keeps the branch scope below
      // unchanged (scenarios 39/68b pins).
      if (commandRunsCommit(command) && GH_PR_CREATE.test(command)) {
        scope = combineScopes(runBranchScope(cwd, sub), ghCommitRecordScope(command, cwd, sub));
      } else {
        scope = runBranchScope(cwd, sub);
      }
    } else if (wtPath !== null) {
      // #538: WT-path commit → union(staged, named-path WT). The named paths'
      // HEAD-vs-working-tree diff (`git diff HEAD -- <pathspecs>`, git-expanded —
      // runWtPathScope) is EXACTLY what the form records: only-mode takes the named
      // paths' disk content (staged-for-others ignored, empirically verified) and
      // include-mode additionally records the whole staged index — the union is the
      // sound over-approximation for every form, mirroring the #489 "mixed" union.
      // A --pathspec-from-file form cannot be enumerated from the command text →
      // union(staged, FULL worktree), the statically-known superset (fail-closed:
      // only-mode records ⊆ the full WT set). The staged union arm is never a NEW
      // over-gate vs today: WT-path forms are already non-bare (D2), so staged files
      // in the same command were already gate-verified pre-#538.
      const namedWt = wtPath.pathspecFromFile
        ? runWorktreeScope(cwd, sub)
        : runWtPathScope(cwd, wtPath.pathspecs, sub);
      scope = combineScopes(runStagedScope(cwd, sub), namedWt);
    } else {
      // #487 T1: a content push (no git commit anywhere in the command) verifies
      // the PUSHED RANGE — HEAD vs the remote-tracking ref (tier A, 2-dot) or
      // the first-push base (tier B, 3-dot) — never the whole index, so another
      // session's parked WIP in the index cannot false-block `git push origin
      // main` of already-committed HEAD. Commit-time behavior is UNCHANGED:
      // commit-bearing commands resolve null fast inside (classifier, zero
      // subprocess) → the staged scope below. resolvePushRangeScope is
      // fail-closed — null (→ staged) on EVERY fallback: unmappable shape
      // (tags/--all/--mirror/wrapper/URL remote), mixed delete+content chains
      // (scenario 44 legs 2-3), commit/gh presence (the P0 backstop,
      // wrapper-inclusive), no usable base (tier C), any git failure — NEVER []
      // on error (the computeBranchDiff catch→[] fail-open
      // precedent). An empty RESOLVED range is audited push_range_empty inside.
      // #755 — the `??` operand serves TWO different commands, and they need
      // DIFFERENT bundles:
      //   • a PUSH command: `resolvePushRangeScope` handles it; the operand fires
      //     only when the push range is unresolvable (tier C / failure) ⇒ pass
      //     NO bundle (tier-C semantics are a stated non-goal).
      //   • a COMMIT-bearing command: `resolvePushRangeScope` returns null at its
      //     eligibility check (it is not a push at all), so the operand IS the
      //     commit arm and MUST carry the bundle — otherwise the merge leg never
      //     subtracts (caught by e2e scenario 77).
      // `parsePushRefSpecs` is a pure classifier (zero subprocess), so asking it
      // here costs nothing.
      const pushAttempt = parsePushRefSpecs(command).eligible;
      const pushScope = resolvePushRangeScope(command, cwd, pushAttempt ? sub : null);
      scope = pushScope ?? runStagedScope(cwd, pushAttempt ? null : sub);
    }

    // #755 audit — emitted here, AFTER the chain closes and BEFORE
    // applyScopeGate, so the full-subtraction ⇒ empty-allow case is
    // still audited. ⛔ Do not anchor this inside the push branch: that would
    // skip every commit arm. At most one base_identical_satisfied per op; it
    // may co-exist with a per-path reason for the same op.
    if (scope.subtractions !== undefined && scope.subtractions.length > 0) {
      const removed = new Set<string>();
      for (const a of scope.subtractions) for (const p of a.perArmSubtracted) removed.add(p);
      const kept = new Set(scope.files);
      logGateSkip("base_identical_satisfied", command, cwd, {
        // Scope-wide: the union of the per-arm removals, FILTERED to paths
        // absent from the final post-subtraction scope (an arm that removed a
        // path another arm kept did not subtract it).
        subtractedPaths: Array.from(removed).filter((p) => !kept.has(p)),
        arms: scope.subtractions,
      });
    }

    // ⛔ #559 T1 single routing site — load-bearing ordering: applyScopeGate
    // decides parse-block FIRST (unconditional on !clean), so a NUL-stream
    // anomaly can never ride the empty-allow / exemption / verify / #7591
    // chain below. Do NOT move this routing after the blockAttempts increment
    // region — a refactor routing parse-block after it re-opens vacuous
    // auto-bypass (accepted-unpinned, pinned on the pure gate instead).
    const gate = applyScopeGate(scope.files, scope.renameOldPaths, scope.clean, isBareCommitShape(command), isShapeExemptFile);
    const route = routeScopeGate(gate, scope.files);
    if (route.action === "parse-block") {
      // No lastBlockedFiles write, no blockAttempts feed — parse-block never
      // auto-bypasses; only ELDATO_SKIP_VGATE escapes. The audit is explicit
      // (the block return itself does not audit).
      appendJsonl({ event: "gate_block_parse_failure", extension: "verification-gate", reason: "name_status_z_anomaly", session_cwd: process.cwd(), command: redactCommand(command), target_cwd: cwd });
      console.log("[verification-gate] 🚫 Blocked — diff parse anomaly (name-status -z format drift)");
      return route.block;
    }
    if (route.action === "empty-allow") {
      // No changed files — allow
      return undefined;
    }
    if (route.action === "exempt-allow") {
      const changedFiles = route.files;
      // #472 mechanism (a): content-shape exemption — docs/CSS/static-only
      // sets (no build-output paths) skip VGATE (01-preflight.md "Verification Gate";
      // mirrors 02-commit-pr.md Step 1.5's Micro content class). TIER-INDEPENDENT:
      // content shape decides, never the complexity label. ALLOW-ONLY: no NEW
      // verifiedSet/bridge entries originate from the exempt op — the registry
      // stays verifier-authoritative; a later MIXED op verifies everything fresh
      // (docs included). Commit-form guard (isBareCommitShape): among `git
      // commit` invocations only the bare form qualifies — `-a`/`--all`/`--amend`/
      // pathspec anywhere re-gates the whole command (D2); push / gh pr
      // create|merge ops with no commit invocation qualify on file shape alone
      // (isBareCommitShape is vacuous on pure pushes — e2e scenarios 47/56 pin
      // the exemption on BOTH the staged set and the #487 RANGE set).
      // Exempt files are not registered here, so a post-exempt lint-staged
      // rewrite cannot stale-hash a future block via THIS op — but a bare
      // exempt COMMIT still arms the #7574 re-hash (review deep-P2): the file
      // may already be registered from an EARLIER mixed VGATE PASS, and the
      // pre-commit hook's rewrite would otherwise go stale with no safety net.
      // #487: the file set this exemption reads is range-scoped for content
      // pushes (tier A/B) with a tier-C staged fallback — the check is
      // identical regardless of which source produced changedFiles.
      // #559 T1: the gate's rename-source check (renameOldPaths.every exempt)
      // already ran in applyScopeGate — this branch is reachable only when
      // every changed file AND every R/C old path is shape-exempt.
      console.log(`[verification-gate] ⏭️ Skipping VGATE — ${changedFiles.length} docs/static file(s): content-shape exemption (tier-independent)`);
      logGateSkip("content_shape_exempt", command, cwd, { files: changedFiles.length });
      // deep-review P2: mirror the verified-allow branch — a bare exempt
      // COMMIT arms the #7574 pendingRehash so the next git op re-hashes the
      // committed files from disk (clearing any lint-staged rewrite of a file
      // registered by an earlier MIXED pass); pushes/gh ops leave it unset
      // (lint-staged runs on commit, not push — same as the verified-allow
      // branch below).
      // Trust boundary (rewritten for #559): the exemption measures rename/
      // copy SOURCE paths alongside destinations — an R/C row whose OLD path
      // is not shape-exempt forces the gate ON even when the new path is
      // docs-shaped (`git mv src/app.ts docs/code.md` no longer rides the
      // docs exemption). Detection is tree-observable, not total: R rows fire
      // only while the source exists in a COMPARED tree (index/HEAD/range
      // base); C rows fire only when the copied content duplicates the
      // PRE-IMAGE of a file modified/deleted in the same diff (no -C is
      // passed; diff.renames=copies can still surface C) — a copy of an
      // UNTOUCHED source emits a plain A row. Accepted residuals, no
      // total-closure claim: (1) copying code into a fresh `.md` (plain A —
      // indistinguishable from a docs create); (2) code content whose path is
      // docs-shaped at EVERY observable tree — an in-session/in-range add→mv
      // cancels to a plain A row because the source never exists in a
      // compared tree (tree-observability limit); (3) valid-UTF-8 path bytes
      // only — invalid-UTF-8 names (Linux-only) still decode-loss
      // ENOENT→skip (narrowed residual of the C-quote class); (4) producer
      // exec-failure keeps status-quo semantics (#559 plan §1 residual list).
      if (isGitCommit(command)) {
        pendingRehash = cwd;
        pendingRehashFiles = [...changedFiles];
      }
      return undefined;
    }

    // verify path — renameOldPaths never reach verify/hash/naming (consumed
    // only by the gate); changedFiles stays the new-path projection.
    const changedFiles = route.files;
    if (changedFiles.length === 0) {
      // (unreachable — empty-allow handled above; defensive)
      return undefined;
    }

    // #37: normalize worktree root for stable compound keys.
    const worktreeRoot = normalizeWorktreeRoot(cwd);

    // Check verification
    const unverified: string[] = [];
    interface Mismatch { file: string; expected: string; actual: string }
    const mismatched: Mismatch[] = [];

    for (const file of changedFiles) {
      let currentHash: string;
      try {
        currentHash = hashFile(cwd, file);
      } catch {
        // File doesn't exist (deleted) — skip verification
        continue;
      }
      const key = compoundKey(worktreeRoot, file);
      const verifiedHash = verifiedSet.get(key);
      if (verifiedHash === undefined) {
        unverified.push(file);
      } else if (!hashMatchesDisk(cwd, file, verifiedHash)) {
        mismatched.push({ file, expected: verifiedHash, actual: currentHash });
      }
    }

    // #7591: auto-bypass after N persistent blocks on the same files —
    // interactive / non-task-sub-agent sessions only; #825 sub-agents get NO
    // auto-bypass (a block is final). Track block attempts per file; allow
    // only when ALL blocked files hit the threshold.
    if (unverified.length > 0 || mismatched.length > 0) {
      // #825/#264: task sub-agents (builtin-tools children — TASK_HEARTBEAT=1 +
      // PI_MODE=print) get NO #7591 auto-bypass: a block is final. They inherit
      // the parent's verified registry via the bridge; retrying must never
      // silently commit unverified files. The sub-agent self-satisfies the gate
      // in-band — it HAS the task tool, so it dispatches its own VGATE
      // verification (the tool_result handler below merges PASS exactly like
      // the parent's) and only then retries the commit.
      if (!isTaskSubAgent()) {
        const allBlockedFiles = [...unverified, ...mismatched.map(m => m.file)];
        let autoBypassed = 0;
        for (const f of allBlockedFiles) {
          const key = compoundKey(worktreeRoot, f);
          const attempts = (blockAttempts.get(key) ?? 0) + 1;
          blockAttempts.set(key, attempts);
          if (attempts >= BLOCK_ATTEMPT_THRESHOLD) {
            autoBypassed++;
          }
        }
        if (autoBypassed === allBlockedFiles.length) {
          console.log(`[verification-gate] ⏩ Auto-bypassed after ${BLOCK_ATTEMPT_THRESHOLD}+ attempts on ${allBlockedFiles.length} files`);
          return undefined;
        }
      }
    }

    if (unverified.length === 0 && mismatched.length === 0) {
      // All verified, hashes match — reset block counters for these files
      for (const f of changedFiles) { blockAttempts.delete(compoundKey(worktreeRoot, f)); }
      console.log(`[verification-gate] ✅ ${changedFiles.length} files verified — allowing`);
      // #7574: if we just allowed a commit, flag for re-hash on next git op.
      // lint-staged (pre-commit hook) modifies files on disk, changing their hashes.
      // Use commit-only pattern — push does NOT trigger lint-staged.
      if (isGitCommit(command)) {
        pendingRehash = cwd;
        // #190: narrow the rehash to the files of the allowed commit — only
        // those could have been modified by lint-staged.
        pendingRehashFiles = [...changedFiles];
      }
      return undefined;
    }

    // #7590: include expected vs actual hash in mismatch diagnostics
    const reasons: string[] = [];
    if (unverified.length > 0) {
      reasons.push(`  Unverified files (not checked by verifier sub-agent):`);
      unverified.forEach(f => reasons.push(`    - ${f}`));
    }
    if (mismatched.length > 0) {
      reasons.push(`  Hash mismatch (file changed since verification):`);
      mismatched.forEach(m => {
        reasons.push(`    - ${m.file}`);
        reasons.push(`      expected: ${m.expected}`);
        reasons.push(`      actual:   ${m.actual}`);
        // #561: dual-cause remedy — a mismatch is EITHER a genuine post-PASS
        // edit OR a verifier hash-transcription error; name both + the fix so
        // the agent re-verifies current bytes instead of re-dispatching blindly.
        reasons.push(`      remedy: file edited after verification OR verifier hash typo — never hand-type sha256: run sha256sum ${m.file} and re-dispatch the exact hash`);
      });
    }

    const allBlocked = [...unverified, ...mismatched.map(m => m.file)];
    // #825/#264: task sub-agents inherit the parent's verified-file registry via
    // the bridge — a block here means these files are NOT covered by it. The
    // child self-satisfies the gate in-band (it HAS the task tool and its own
    // tool_result handler merges a VGATE PASS exactly like the parent's) —
    // dispatch its own VGATE verification, then retry the commit. The
    // no-auto-bypass guard stays: a blocked sub-agent must still get verified
    // (just via its own dispatch), never silently committed. #285 P1-A: the
    // message is now task-tool-aware (buildSubAgentBlockMessage branches for
    // task-restricted agents — the old text unconditionally claimed the task
    // tool).
    const ceremonyDiag = lastDispatchClass ? formatCeremonyDiagnostics(lastDispatchClass, dispatchStreak, isTaskSubAgent() ? "capable" : "interactive") : ""; // #561: append at the CALL SITE only — buildSubAgentBlockMessage stays hermetic for its pinned tests
    const reason = isTaskSubAgent()
      ? buildSubAgentBlockMessage(reasons, cwd, allBlocked) + ceremonyDiag
      : [
          "⛔ Verification gate — blocking git operation.",
          "",
          ...reasons,
          "",
          `  → Dispatch the verifier sub-agent:`,
          `    task(prompt='[VGATE] verify files: ${allBlocked.join(' ')}. Classification: <UI|backend|both>. Project root: ${cwd}. Return ONLY JSON: {"status":"PASS","failures":[],"verified_files":[{"path":"<repo-relative>","hash":"<sha256>"}]}.', ...)`,
          "",
          "  → Or set ELDATO_SKIP_VGATE=1 to bypass (emergency only).",
        ].join("\n") + ceremonyDiag;

    console.log(`[verification-gate] 🚫 Blocked: ${unverified.length} unverified, ${mismatched.length} mismatched`);
    lastBlockedCwd = cwd; // stash authoritative cwd for the merge path (#5607)
    lastBlockedFiles = [...changedFiles]; // #5673: scope verifier to diff files only
    return { block: true, reason };
  });

  // ── tool_result: capture verifier subagent output ──
  pi.on("tool_result", async (event, _ctx) => {
    // Only intercept subagent/task tool results (Claude Code: subagent, Pi: task)
    if (event.toolName !== "subagent" && event.toolName !== "task") return undefined;

    const input = event.input as Record<string, unknown> | undefined;
    if (!input) return undefined;

    // Identify verifier by agent name (Claude Code subagent) or prompt content (Pi task tool).
    // Pi'"'"'s task tool has no agent parameter — detect verifier from prompt string instead.
    const agent = input.agent as string | undefined;
    const prompt = String(input.prompt ?? input.task ?? "");
    const isVerifier = agent === "verifier" || prompt.includes("[VGATE]");
    if (!isVerifier) return undefined;

    // Extract JSON from content
    const content = event.content;
    if (!content || content.length === 0) {
      console.error("[verification-gate] ⚠️ Verifier sub-agent returned empty content. Format: prompt must say 'verify files:' (plural); response must contain 'PASS' or valid JSON {status, failures, verified_files}.");
      recordDispatchFailure("empty-content"); // #561
      vgateFailures++;
      // #285 P1-1: a task sub-agent never auto-disables on repeated dispatch
      // failures — the threshold disable is refused (WARN + audit, gate stays
      // ACTIVE → still blocking).
      // #561 review r1 P2: extensionEnabled guard — the audit + disable fire
      // ONCE per enabled→disabled transition; a malformed dispatch after the
      // latch is down must not append duplicate forensic records.
      if (extensionEnabled && vgateFailures >= VGATE_FAILURE_THRESHOLD && !refuseAutoBypassForSubAgent()) {
        // #561: the latch is one-way and in-process — audit it so a silently
        // disabled interactive gate leaves a durable forensic record.
        appendJsonl({ event: "gate_bypass", extension: "verification-gate", reason: "vgate_failure_threshold_disable", session_cwd: process.cwd() });
        extensionEnabled = false;
        console.log("[verification-gate] ⏸️ Auto-bypassed after 3 consecutive VGATE dispatch failures");
        // #561 review r2: surface the STOP-and-fix escalation HERE — the only
        // output an interactive session actually receives at the latch (the
        // next git op early-returns on the !extensionEnabled guard before any
        // block message assembles). Honest copy: the gate HAS auto-disabled.
        console.error(formatCeremonyDiagnostics(lastDispatchClass ?? "unparseable", dispatchStreak, "interactive"));
      }
      return undefined;
    }

    const textContent = content
      .filter((c): c is { type: "text"; text: string } => c.type === "text")
      .map(c => c.text)
      .join("\n");

    if (!textContent) {
      console.error("[verification-gate] ⚠️ Verifier sub-agent returned no text content. Format: response must contain 'PASS' or valid JSON {status, failures, verified_files}.");
      recordDispatchFailure("no-text"); // #561
      vgateFailures++;
      // #285 P1-1: no threshold auto-disable for task sub-agents (see the
      // empty-content site — same refusal).
      // #561 review r1 P2: extensionEnabled guard (single-fire audit, see 2499).
      if (extensionEnabled && vgateFailures >= VGATE_FAILURE_THRESHOLD && !refuseAutoBypassForSubAgent()) {
        // #561: audited one-way latch (see the empty-content site).
        appendJsonl({ event: "gate_bypass", extension: "verification-gate", reason: "vgate_failure_threshold_disable", session_cwd: process.cwd() });
        extensionEnabled = false;
        console.log("[verification-gate] ⏸️ Auto-bypassed after 3 consecutive VGATE dispatch failures");
        console.error(formatCeremonyDiagnostics(lastDispatchClass ?? "unparseable", dispatchStreak, "interactive")); // #561 review r2: surface the escalation at the latch (see the empty-content site)
      }
      return undefined;
    }

    const result = extractJson(textContent);

    // Plain-text fallback (Pi task sub-agents often return markdown, not JSON)
    if (!result) {
      // #132 A.3b: an explicit FAIL judgment (schema-incomplete JSON FAIL or
      // plain-text FAIL) must block, never fail open — "don't commit" is not
      // a JSON-compliance issue. Not a dispatch failure either: keep blocking,
      // log, do NOT increment vgateFailures and do NOT merge. Consume stale
      // block state like every terminal path (#5607).
      // STRUCTURAL detection: word-boundary line/❌ heuristics (so FAILED /
      // Failure / Failing prose never match) + a brace-anchored JSON probe
      // covering lazy spellings {status: FAIL} / {'status':'FAIL'}.
      // P2: also covers list-marker lines (- FAIL:, * FAIL:), inline verdict
      // labels (Result: FAIL, Verdict: FAIL), and past-tense FAILED on line/
      // ❌ anchors (still excludes "Failure"/"Failing" prose via \b).
      const hasFail = /(?:^|\n)\s*(?:[-*•]|\d+\.)?\s*FAIL(?:\b|:|—)/i.test(textContent)
        || /❌.*FAIL(?:\b|:|—)/i.test(textContent)
        || /(?:^|\n)\s*(?:result|verdict|status|outcome)\s*[:=]\s*FAIL(?:\b|:|—)/i.test(textContent)
        || /(?:^|\n)\s*(?:[-*•]|\d+\.)?\s*FAILED(?:\b|:|—)/i.test(textContent)
        || /❌.*FAILED(?:\b|:|—)/i.test(textContent)
        || /\{\s*['"]?status['"]?\s*:\s*['"]?FAIL['"]?/i.test(textContent)
        // Order-independent: status in ANY key position ({"failures":[...],"status":"FAIL"}).
        // Tradeoff (re-review P2): unanchored, so a PASS response QUOTING a prior
        // status:FAIL in prose would block — accepted: FAIL-quoting PASS prose is
        // rarer than the fail-open danger of status-second FAIL verdicts.
        || /(?:^|[^\w])['"]?status['"]?\s*[:=]\s*['"]?FAIL['"]?/i.test(textContent);
      if (hasFail) {
        console.error("[verification-gate] ❌ Verifier FAILED (unparseable verdict): keep blocking, no merge");
        recordDispatchJudgment("fail-verdict"); // #561: judgment class — remedy text only, streak unchanged (#132)
        lastBlockedCwd = null;   // consume stale block state (#5607)
        lastBlockedFiles = [];
        return undefined;
      }
      // #190: hasPass parity with hasFail — list/bold markers (-, *, **, ***)
      // and a word boundary so PASSED/PASSES never match (the fail-open branch
      // below still rescues genuinely unparseable-but-verifier-intent responses).
      const hasPass = /(?:^|\n)\s*(?:[-*•]|\d+\.)?\s*\*{0,3}PASS(?:\b|:|—)/i.test(textContent)
        || /✅.*PASS(?:\b|:|—)/i.test(textContent);

      if (hasPass) {
        // #190: wrong-root guard — a prompt whose explicit `Project root:`
        // realpath-differs from the stashed block cwd targets a different
        // worktree; the stale block context must not shadow it (or every
        // proactive dispatch in worktree B would zero-merge against A's stale
        // state and recreate the blocked-until-auto-bypass loop).
        const { root: projectRoot, foreign } = resolveMergeRoot(lastBlockedCwd, prompt);
        // #190 review: expand directory paths against the PRE-clear blocked
        // list (a foreign dispatch must still resolve dirs from the real block
        // context), then clear the stale context atomically — lastBlockedCwd
        // together with lastBlockedFiles, so no half-cleared (old-root + empty
        // filter) state survives.
        const blockedSnapshot = [...lastBlockedFiles];

        // Extract file list from the prompt. #190: broadened regex accepts
        // `\n\nClassification:` and no-period separators (incident dispatch #1).
        // Format: "[VGATE] verify files: path1 path2. Classification: ... Project root: /path"
        const fileMatch = prompt.match(/verify files:\s*(.+?)(?=(?:\.|\n)\s*(?:Classification:|Project root:|$))/);
        const rawFiles = fileMatch ? fileMatch[1].split(/\s+/).filter(Boolean) : [];
        // Expand directory paths: if a path ends with / or doesn't contain a dot,
        // treat it as a directory and include all staged files under that directory.
        const promptFiles = new Set<string>();
        for (const f of rawFiles) {
          const isDir = f.endsWith('/') || !f.includes('.');
          if (isDir && blockedSnapshot.length > 0) {
            for (const blocked of blockedSnapshot) {
              if (blocked.startsWith(f)) promptFiles.add(blocked);
            }
          } else {
            promptFiles.add(f);
          }
        }

        if (foreign) {
          // stale context — do not filter against it (atomic clear)
          lastBlockedFiles = [];
          lastBlockedCwd = null;
        }

        // #336: when the prompt names files, merge those (diff-scoped). When it
        // names none (deviant/foreign prompt, or a verifier dispatched without
        // the literal `verify files:` phrase), fall back to the files the gate
        // is CURRENTLY blocking — the authoritative set — instead of
        // zero-merging. The pre-#336 fallback only fired for standalone verdict
        // lines AND only when the prompt contained `verify files:`; a plain
        // PASS from any other dispatch shape recorded nothing and forced a
        // re-dispatch loop. Prose echoes ("PASS criteria are met") never reach
        // this branch (hasPass is line-anchored), so the fallback stays
        // fail-safe: it only fires on a genuine PASS signal.
        let mergeFiles: string[];
        if (promptFiles.size > 0) {
          mergeFiles = [...promptFiles];
        } else if (lastBlockedFiles.length > 0) {
          mergeFiles = [...lastBlockedFiles];
          console.error(`[verification-gate] ⚠️ Plain-text PASS with zero prompt files — falling back to ${lastBlockedFiles.length} blocked files`);
        } else {
          mergeFiles = [];
        }

        // #190: shared diff-scoping — blocked-context filter (#5673) or, when
        // the context is empty/foreign, staged-diff scoping (never a blind
        // pass-through; known registry keys stay mergeable per #38).
        const { kept: filteredPromptFiles, skipped } = scopeFiles(mergeFiles, projectRoot, lastBlockedFiles, verifiedSet);
        const merged = hashAndMergeFiles(verifiedSet, blockAttempts, filteredPromptFiles, projectRoot);
        if (merged > 0) {
          console.log(`[verification-gate] ✅ Plain-text PASS — merged ${merged}/${mergeFiles.length} files from prompt${skipped > 0 ? ` (skipped ${skipped} not in diff)` : ''} (${verifiedSet.size} total)`);
          writeBridge(projectRoot, Array.from(verifiedSet.keys()));
          recordDispatchSuccess(); // #561: a merge proves dispatch health — reset streak here too (deliberate: the vgateFailures latch does NOT reset on plain-text PASS; this is messaging-only and does not touch the latch)
          lastBlockedCwd = null; // consume on successful merge (#5607)
        } else {
          // #190: zero-merge does NOT consume the block context — a retry
          // dispatch still needs lastBlockedCwd/lastBlockedFiles (a malformed
          // first dispatch must not erase the state the retry depends on).
          console.error(`[verification-gate] ⚠️ Plain-text PASS but could not hash any files (${mergeFiles.length} in scope)`);
          recordDispatchJudgment("zero-merge-pass"); // #561
        }
        return undefined;
      }

      console.error("[verification-gate] ⚠️ Failed to extract JSON from verifier output. Format: response must contain 'PASS' or valid JSON {status, failures, verified_files}.");
      // ponytail: fail-open — if verifier is unparseable, extract files from prompt
      // and mark them as verified anyway. Better to allow the commit than
      // block on a model JSON-compliance issue (#5724).
      // #190: broadened regex + wrong-root guard + staged-diff scoping, same as
      // the plain-text branch (never a blind pass-through).
      const fileMatch = prompt.match(/verify files:\s*(.+?)(?=(?:\.|\n)\s*(?:Classification:|Project root:|$))/);
      const rawFiles = fileMatch ? fileMatch[1].split(/\s+/).filter(Boolean) : [];
      const promptFiles = new Set<string>();
      for (const f of rawFiles) {
        const isDir = f.endsWith('/') || !f.includes('.');
        if (isDir && lastBlockedFiles.length > 0) {
          for (const blocked of lastBlockedFiles) {
            if (blocked.startsWith(f)) promptFiles.add(blocked);
          }
        } else {
          promptFiles.add(f);
        }
      }
      if (promptFiles.size > 0) {
        // #285 P2-B: refuse the #5724 fail-open prompt-merge for task
        // sub-agents — an unparseable verifier response must NOT silently
        // bless the prompt files in a child (the child's own re-dispatch with
        // the required JSON format is the path). Mirror the hasFail terminal:
        // no merge, NO vgateFailures increment, block state
        // (lastBlockedCwd/lastBlockedFiles) PRESERVED so the re-dispatch still
        // has its subject. Interactive sessions keep the #5724 fail-open
        // unchanged (model JSON-compliance noise must not block a legit user).
        if (isTaskSubAgent()) {
          console.warn("[verification-gate] ⚠️ Verifier unparseable — fail-open REFUSED for task sub-agent; files NOT recorded; re-dispatch with the required JSON format (#285)");
          appendJsonl({ event: "gate_bypass_refused", extension: "verification-gate", subagent: true, reason: "fail_open_refused", session_cwd: process.cwd() });
          recordDispatchFailure("fail-open-refused"); // #561: dispatch-format class — moves the streak (latch divergence: vgateFailures does NOT count this class; the streak is messaging-only)
          return undefined;
        }
        const { root: projectRoot, foreign } = resolveMergeRoot(lastBlockedCwd, prompt);
        if (foreign) lastBlockedFiles = [];
        const normRoot = normalizeWorktreeRoot(projectRoot);
        const { kept: scopedFiles } = scopeFiles([...promptFiles], projectRoot, lastBlockedFiles, verifiedSet);
        let merged = 0;
        for (const file of scopedFiles) {
          try {
            const relPath = normalizeRegistryPath(projectRoot, file);
            const key = compoundKey(normRoot, relPath);
            verifiedSet.set(key, hashFile(projectRoot, file));
            blockAttempts.delete(key);
            merged++;
          } catch { /* file may not exist at expected path */ }
        }
        if (merged > 0) {
          console.log(`[verification-gate] ⚠️ Verifier unparseable — fail-open: merged ${merged}/${promptFiles.size} files from prompt`);
          writeBridge(projectRoot, Array.from(verifiedSet.keys()));
          vgateFailures = 0;
          recordDispatchSuccess(); // #561
          lastBlockedCwd = null;
          return undefined;
        }
      }
      recordDispatchFailure("unparseable"); // #561
      vgateFailures++;
      // #285 P1-1: no threshold auto-disable for task sub-agents (refused —
      // gate stays ACTIVE → still blocking).
      // #561 review r1 P2: extensionEnabled guard (single-fire audit, see 2499).
      if (extensionEnabled && vgateFailures >= VGATE_FAILURE_THRESHOLD && !refuseAutoBypassForSubAgent()) {
        // #561: audited one-way latch (see the empty-content site).
        appendJsonl({ event: "gate_bypass", extension: "verification-gate", reason: "vgate_failure_threshold_disable", session_cwd: process.cwd() });
        extensionEnabled = false;
        console.log("[verification-gate] ⏸️ Auto-bypassed after 3 consecutive VGATE dispatch failures");
        console.error(formatCeremonyDiagnostics(lastDispatchClass ?? "unparseable", dispatchStreak, "interactive")); // #561 review r2: surface the escalation at the latch (see the empty-content site)
      }
      return undefined;
    }

    // #132 A.4: the schema-invalid branch is REMOVED — extractJson (A.1) now
    // returns only schema-valid results or null, so !isValidResult(result) is
    // unreachable here. Schema-invalid PASS previously fell through to the
    // prompt-file merge; that path is now reached via the null path (plain-text
    // fallback → fail-open prompt-merge). Equivalent for the pure-JSON case
    // (same prompt merge, same reset-if-merged>0, same lastBlockedCwd consume);
    // a MIXED shape (line-start PASS + schema-invalid JSON) now additionally
    // diff-scopes via the #5673 filter — stricter, intended. Schema-invalid
    // FAIL intent is handled deliberately by A.3b (blocks).

    if (result.status !== "PASS") {
      console.error(`[verification-gate] ❌ Verifier returned FAIL: ${result.failures.join("; ")}`);
      recordDispatchJudgment("fail-verdict"); // #561: judgment class — remedy text only, streak unchanged (#132)
      // #132: a FAIL is a SUCCESSFUL dispatch — the verifier ran and judged the
      // files unready. Keep blocking (nothing to merge) but do NOT count it as a
      // dispatch failure: 3 legitimate FAIL verdicts must not silently disable the
      // gate. No reset either — a FAIL proves nothing about dispatch health.
      // Consume stale block state like every terminal path (#5607).
      lastBlockedCwd = null;
      lastBlockedFiles = [];
      return undefined;
    }

    // #5673/#7595: merge verifier files into the registry. Keys are normalized
    // to repo-relative; known paths always update (re-verification is authoritative).
    // #190: wrong-root guard + shared diff-scoping — empty/foreign context scopes
    // against the current staged diff, never a blind pass-through.
    const { root: projectRoot, foreign } = resolveMergeRoot(lastBlockedCwd, prompt);
    if (foreign) lastBlockedFiles = []; // stale block context — do not filter against it

    // #336: a schema-valid PASS with EMPTY verified_files carries no
    // verifier-supplied hashes — the pre-#336 code zero-merged here (records
    // nothing) and every commit/PR create re-blocked despite a fresh PASS.
    // Fall back to the files the gate is CURRENTLY blocking: hash them at
    // merge time (current disk state) so a post-PASS edit still re-blocks
    // (fail-closed), and diff-scope them so a hash-less PASS can never mark
    // arbitrary files verified. A foreign (wrong-root) block context is
    // already cleared above → lastBlockedFiles is empty → zero-merge.
    if (result.verified_files.length === 0) {
      const fallbackMerged = hashAndMergeFiles(verifiedSet, blockAttempts, lastBlockedFiles, projectRoot);
      if (fallbackMerged > 0) {
        vgateFailures = 0;
        recordDispatchSuccess(); // #561
        console.log(`[verification-gate] ✅ PASS (empty verified_files) — recorded ${fallbackMerged} blocked files from disk (${verifiedSet.size} total)`);
        writeBridge(projectRoot, Array.from(verifiedSet.keys()));
        lastBlockedCwd = null; // consume on successful merge (#5607)
      } else {
        // #190: zero-merge does NOT consume the block context — a retry
        // dispatch still needs lastBlockedCwd/lastBlockedFiles.
        console.error(`[verification-gate] ⚠️ PASS with empty verified_files and no block context — zero-merge, failure streak NOT reset (#132)`);
        recordDispatchJudgment("zero-merge-pass"); // #561
      }
      return undefined;
    }

    const { kept: scopedVerifiedFiles, skipped: scopeSkipped } = scopeFiles(
      result.verified_files.map(vf => vf.path),
      projectRoot,
      lastBlockedFiles,
      verifiedSet
    );
    const scopedResults = result.verified_files.filter(vf => scopedVerifiedFiles.includes(vf.path));
    const { merged, skipped } = mergeVerifiedFiles(verifiedSet, blockAttempts, scopedResults, projectRoot, lastBlockedFiles);
    const totalSkipped = skipped + scopeSkipped;

    // #132 A.5: only a merge proves dispatch health. A zero-merge PASS (all files
    // skipped as not-in-diff, or empty verified_files) must NOT reset the failure
    // streak — it would mask a broken verifier. Precedent: index.ts:642/686.
    if (merged > 0) {
      vgateFailures = 0;
      recordDispatchSuccess(); // #561: a merge proves dispatch health
      console.log(`[verification-gate] ✅ Merged ${merged} verified files${totalSkipped > 0 ? ` (skipped ${totalSkipped} not in diff)` : ''} (${verifiedSet.size} total)`);
      // Write bridge file so future sessions/sub-agents can see verification status
      const verifiedPaths = Array.from(verifiedSet.keys());
      if (verifiedPaths.length > 0) {
        writeBridge(projectRoot, verifiedPaths);
      }
      lastBlockedCwd = null; // consume on successful merge (#5607)
    } else {
      // #190: zero-merge does NOT consume the block context — a retry dispatch
      // still needs lastBlockedCwd/lastBlockedFiles.
      console.error(`[verification-gate] ⚠️ PASS but merged 0 files${totalSkipped > 0 ? ` (${totalSkipped} skipped as not in diff)` : ' (empty verified_files)'} — failure streak NOT reset (#132)`);
      recordDispatchJudgment("zero-merge-pass"); // #561
    }
    return undefined;
  });

  // #5672: suppress startup banner in print mode (task sub-agent output)
  if (!isPrintMode()) {
    console.log("[verification-gate] ✅ Loaded — blocking git operations until verification complete");
  }

  } catch (err: any) {
    console.error("[verification-gate] ❌ Failed to load:", err.message);
  }
}
