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
    if (staged === null) staged = new Set(computeStagedDiff(projectRoot));
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

function recoverBridgeForRoot(normRoot: string): number {
  try {
    const st = statSync(bridgePath());
    // Perf guard: skip when the bridge hasn't been written since our last
    // recovery — nothing new to recover (mtime granularity edge cases are
    // fail-closed: a skipped recovery just means a re-block + re-verify).
    if (st.mtimeMs <= lastRecoveryMtime) return 0;
    lastRecoveryMtime = st.mtimeMs;
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

// ── Git operation patterns ────────────────────────────

// (?=\s|$) lookahead: real commands have whitespace/end after the verb.
// Prevents false positives from documentation text like "git commit/push"
// appearing in heredoc bodies or --body string args (#5571).
const GIT_COMMIT_PATTERN = /(^|\s)git\s+(commit|push)(?=\s|$)/;
// #7574: commit-only pattern for pendingRehash. lint-staged runs as a pre-commit hook,
// not pre-push. Setting pendingRehash on push wastes I/O — the next git op re-hashes
// all verifiedSet entries from disk unnecessarily.
const GIT_COMMIT_ONLY_PATTERN = /(^|\s)git\s+commit(?=\s|$)/;
const GH_PR_PATTERN = /(^|\s)gh(?:\s+(?:--repo|-R)(?:=|\s+)[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)?\s+pr\s+(create|merge)(?=\s|$)/;
// #204 review P2-1: gh's merge verb with the optional global -R/--repo flag
// between `gh` and `pr` — `gh -R owner/name pr merge 123` is a valid spelling
// and must route into the merge-scope path like the post-verb flag form.
const GH_PR_MERGE_VERB = /(?:^|\s)gh(?:\s+(?:--repo|-R)(?:=|\s+)[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)?\s+pr\s+merge(?=\s|$)/;

export function isGitOp(command: string): boolean {
  return GIT_COMMIT_PATTERN.test(command) || GH_PR_PATTERN.test(command);
}

export function isGitCommit(command: string): boolean {
  return GIT_COMMIT_ONLY_PATTERN.test(command);
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
function logGateSkip(reason: string, command: string, cwd: string, extra: Record<string, unknown> = {}): void {
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
  reason: "cross_repo" | "head_mismatch" | "same_repo_head_match" | "same_repo_head_unknown";
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

// True when segment is `git push` whose args are a remote PLUS deletion forms
// ONLY. Requires an explicit ∃-deletion marker (D4) — bare `git push origin`
// (no marker) is NOT pure (vacuous-truth guard). Any other flag, a second
// remote, a bare content refspec, or an unknown shape → false (fail-closed).
function isPureDeletionPushSegment(segment: string): boolean {
  const stripped = stripSegmentHead(segment);
  if (!/^git\s+push(?=\s|$)/.test(stripped)) return false;
  const rest = stripped.replace(/^git\s+push\s*/, "");
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
// match's start offset AND the byte offset AFTER the `commit` verb — or null
// when the segment holds no commit invocation. Used by BOTH predicates as
// fail-closed containment — `git -C repo commit -am x` must register as a
// commit or the `-a` sweep rides the docs exemption (review P2-1).
// Head-anchored OR wrapper-prefixed: substring scan symmetric with
// GIT_COMMIT_ONLY_PATTERN's `(^|\s)` (the `\b` at the start also catches
// `! git commit`, `sh -c 'git commit …'`, `sudo … git commit`). Callers
// decide how to treat offset: isDeletionPush only needs presence (`!== null`,
// any commit anywhere flips purity); isBareCommitShape requires a
// HEAD-ANCHORED match (`index === 0` — stripSegmentHead already normalized
// prefix verbs, so a nonzero offset means a wrapper/negation form that is not
// provably bare, resolution A).
function findGitCommit(stripped: string): { index: number; end: number } | null {
  const m = stripped.match(/\bgit(?:\s+-[^\s]+(?:\s+(?!commit\b)(?:'[^']*'|"[^"]*"|\S+))?)*\s+commit\b/);
  if (!m || m.index === undefined) return null;
  return { index: m.index, end: m.index + m[0].length };
}

// Whole-command purity (D5): true iff the command has ≥1 push op AND every
// gated op (git commit|push per GIT_COMMIT_PATTERN; gh pr create|merge per
// GH_PR_PATTERN — INCLUDING the global -R/--repo spelling) is a delete-shaped
// push. Scaffolding segments (assignments, gh pr view, git branch -D,
// full-line comments, if/fi, $(…)) never flip purity — FULL-LINE `#` comments
// are stripped quote-aware in splitCommandSegments before this scan (an
// apostrophe in a comment must not open a quote state). An INLINE comment
// carrying a literal gated-verb string after real code (`echo hi # then: git
// commit -am x`) is not stripped and DOES flip purity: fail-closed, symmetric
// with the gate's own substring interception patterns (both see the raw
// text).
export function isDeletionPush(command: string): boolean {
  let sawPush = false;
  for (const segment of splitCommandSegments(command)) {
    const stripped = stripSegmentHead(segment);
    // CONTAINMENT BACKSTOP (fail-closed, symmetric with the interception
    // surface): the gate's GIT_COMMIT_PATTERN / GH_PR_PATTERN are SUBSTRING
    // scans — they fire on `sh -c 'git commit …'`, `! git commit …`,
    // wrapper-prefixed forms etc. Head-anchored checks alone would treat such
    // wrapper segments as scaffolding and let mechanism (b) short-circuit a
    // command that really contains a commit/merge.
    //   1. gh pr create|merge anywhere (bare, -R/--repo, or wrapper) → false
    //   2. git commit anywhere (bare or wrapper) → false
    //   3. head-anchored `git push` → isPureDeletionPushSegment decides
    //   4. git push in a WRAPPER form → cannot prove purity → false
    //   5. no gated verb → scaffolding, ignored (D5)
    const ghOp = /\bgh(?:\s+(?:--repo|-R)(?:=|\s+)[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)?\s+pr\s+(?:create|merge)\b/;
    if (ghOp.test(stripped)) return false;
    if (findGitCommit(stripped) !== null) return false;
    if (/^git\s+push(?=\s|$)/.test(stripped)) {
      sawPush = true;
      if (!isPureDeletionPushSegment(segment)) return false;
      continue;
    }
    if (/\bgit\s+push\b/.test(stripped)) return false; // wrapper push — not provably pure
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
    // segments (substring scan symmetric with GIT_COMMIT_ONLY_PATTERN) so the
    // -a sweep can never ride a docs-only staged set to an exemption.
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

// ── Diff computation ──────────────────────────────────

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

function computeStagedDiff(cwd: string): string[] {
  try {
    const out = execSync("git diff --cached --name-only", {
      encoding: "utf-8",
      cwd,
      timeout: 5000,
    }).trim();
    return out ? out.split("\n").filter(Boolean) : [];
  } catch {
    return [];
  }
}

function computeBranchDiff(cwd: string): string[] {
  try {
    const out = execSync("git diff origin/main...HEAD --name-only", {
      encoding: "utf-8",
      cwd,
      timeout: 5000,
    }).trim();
    return out ? out.split("\n").filter(Boolean) : [];
  } catch {
    return [];
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
    const sessionRoot = normalizeWorktreeRoot(resolveGitRoot(process.cwd()));
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
    const cwd = resolveGitRoot(cdPath ?? inputCwd);

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
    // (fail-closed).
    if (isDeletionPush(command)) {
      console.log("[verification-gate] ⏭️ Skipping VGATE — delete-shaped push: no local content ships");
      logGateSkip("delete_push_no_content", command, cwd);
      return undefined;
    }

    // Compute diff
    let changedFiles: string[];
    if (GH_PR_PATTERN.test(command)) {
      // #204: `gh pr merge` merges REMOTELY. Only the PR's own repo+head can
      // be verified locally; anything else is unrelated branch residue that
      // must neither block nor reach verifiedSet/bridge (drift contamination).
      // `gh pr create` is NOT scoped — its diff IS this branch's files. The
      // merge-vs-create split is verb-anchored (isMergeCommand), so a create
      // whose --body merely MENTIONS "gh pr merge <n>" is never routed here.
      if (isMergeCommand(command)) {
        const decision = resolveMergeScope(command, cwd);
        if (!decision.verify) {
          console.log(`[verification-gate] ⏭️ Skipping verification for gh pr merge — ${decision.reason}: nothing local represents the PR`);
          logGateSkip(decision.reason, command, cwd); // #60: durable audit record — skipped verification must leave a trace
          return undefined; // before computeBranchDiff: no files, no block, no registry/bridge writes
        }
      }
      changedFiles = computeBranchDiff(cwd);
    } else {
      changedFiles = computeStagedDiff(cwd);
    }

    if (changedFiles.length === 0) {
      // No changed files — allow
      return undefined;
    }

    // #472 mechanism (a): content-shape exemption — docs/CSS/static-only sets
    // (no build-output paths) skip VGATE (01-preflight.md "Verification Gate";
    // mirrors 02-commit-pr.md Step 1.5's Micro content class). TIER-INDEPENDENT:
    // content shape decides, never the complexity label. ALLOW-ONLY: no NEW
    // verifiedSet/bridge entries originate from the exempt op — the registry
    // stays verifier-authoritative; a later MIXED op verifies everything fresh
    // (docs included). Commit-form guard (isBareCommitShape): among `git
    // commit` invocations only the bare form qualifies — `-a`/`--all`/`--amend`/
    // pathspec anywhere re-gates the whole command (D2); push / gh pr
    // create|merge ops with no commit invocation qualify on file shape alone.
    // Exempt files are not registered here, so a post-exempt lint-staged
    // rewrite cannot stale-hash a future block via THIS op — but a bare
    // exempt COMMIT still arms the #7574 re-hash (review deep-P2): the file
    // may already be registered from an EARLIER mixed VGATE PASS, and the
    // pre-commit hook's rewrite would otherwise go stale with no safety net.
    if (changedFiles.length > 0 && isBareCommitShape(command) && changedFiles.every((file) => isShapeExemptFile(file))) {
      console.log(`[verification-gate] ⏭️ Skipping VGATE — ${changedFiles.length} docs/static file(s): content-shape exemption (tier-independent)`);
      logGateSkip("content_shape_exempt", command, cwd, { files: changedFiles.length });
      // deep-review P2: mirror the verified-allow branch — a bare exempt
      // COMMIT arms the #7574 pendingRehash so the next git op re-hashes the
      // committed files from disk (clearing any lint-staged rewrite of a file
      // registered by an earlier MIXED pass); pushes/gh ops leave it unset
      // (lint-staged runs on commit, not push — same as the verified-allow
      // branch below).
      // Trust boundary (review 2a-1, documented): the shape check measures
      // rename DESTINATIONS (`git mv src/app.ts docs/code.md` lists only the
      // new path) — a deliberate code→docs rename rides the exemption, same
      // class as copying code into a fresh `.md` (inherent to the Z-NARROW
      // extension-keyed design, accepted in plan D1; rename-source plumbing
      // is a follow-up).
      if (isGitCommit(command)) {
        pendingRehash = cwd;
        pendingRehashFiles = [...changedFiles];
      }
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
    const reason = isTaskSubAgent()
      ? buildSubAgentBlockMessage(reasons, cwd, allBlocked)
      : [
          "⛔ Verification gate — blocking git operation.",
          "",
          ...reasons,
          "",
          `  → Dispatch the verifier sub-agent:`,
          `    task(prompt='[VGATE] verify files: ${allBlocked.join(' ')}. Classification: <UI|backend|both>. Project root: ${cwd}. Return ONLY JSON: {"status":"PASS","failures":[],"verified_files":[{"path":"<repo-relative>","hash":"<sha256>"}]}.', ...)`,
          "",
          "  → Or set ELDATO_SKIP_VGATE=1 to bypass (emergency only).",
        ].join("\n");

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
      vgateFailures++;
      // #285 P1-1: a task sub-agent never auto-disables on repeated dispatch
      // failures — the threshold disable is refused (WARN + audit, gate stays
      // ACTIVE → still blocking).
      if (vgateFailures >= VGATE_FAILURE_THRESHOLD && !refuseAutoBypassForSubAgent()) {
        extensionEnabled = false;
        console.log("[verification-gate] ⏸️ Auto-bypassed after 3 consecutive VGATE dispatch failures");
      }
      return undefined;
    }

    const textContent = content
      .filter((c): c is { type: "text"; text: string } => c.type === "text")
      .map(c => c.text)
      .join("\n");

    if (!textContent) {
      console.error("[verification-gate] ⚠️ Verifier sub-agent returned no text content. Format: response must contain 'PASS' or valid JSON {status, failures, verified_files}.");
      vgateFailures++;
      // #285 P1-1: no threshold auto-disable for task sub-agents (see the
      // empty-content site — same refusal).
      if (vgateFailures >= VGATE_FAILURE_THRESHOLD && !refuseAutoBypassForSubAgent()) {
        extensionEnabled = false;
        console.log("[verification-gate] ⏸️ Auto-bypassed after 3 consecutive VGATE dispatch failures");
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
          lastBlockedCwd = null; // consume on successful merge (#5607)
        } else {
          // #190: zero-merge does NOT consume the block context — a retry
          // dispatch still needs lastBlockedCwd/lastBlockedFiles (a malformed
          // first dispatch must not erase the state the retry depends on).
          console.error(`[verification-gate] ⚠️ Plain-text PASS but could not hash any files (${mergeFiles.length} in scope)`);
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
          lastBlockedCwd = null;
          return undefined;
        }
      }
      vgateFailures++;
      // #285 P1-1: no threshold auto-disable for task sub-agents (refused —
      // gate stays ACTIVE → still blocking).
      if (vgateFailures >= VGATE_FAILURE_THRESHOLD && !refuseAutoBypassForSubAgent()) {
        extensionEnabled = false;
        console.log("[verification-gate] ⏸️ Auto-bypassed after 3 consecutive VGATE dispatch failures");
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
        console.log(`[verification-gate] ✅ PASS (empty verified_files) — recorded ${fallbackMerged} blocked files from disk (${verifiedSet.size} total)`);
        writeBridge(projectRoot, Array.from(verifiedSet.keys()));
        lastBlockedCwd = null; // consume on successful merge (#5607)
      } else {
        // #190: zero-merge does NOT consume the block context — a retry
        // dispatch still needs lastBlockedCwd/lastBlockedFiles.
        console.error(`[verification-gate] ⚠️ PASS with empty verified_files and no block context — zero-merge, failure streak NOT reset (#132)`);
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
