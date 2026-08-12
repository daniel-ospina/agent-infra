import type { ExtensionAPI, ToolCallEvent, ToolCallEventResult, ToolResultEvent } from "@earendil-works/pi-coding-agent";
import { isToolCallEventType } from "@earendil-works/pi-coding-agent";
import { execSync } from "node:child_process";
import { relative, resolve } from "node:path";
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync, existsSync, mkdirSync, unlinkSync, realpathSync, statSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import { register } from "../shared/health.js";
import { appendJsonl } from "../shared/audit-log.js";
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

function bridgePath(): string {
  return join(BRIDGE_DIR, "latest.json");
}

function writeBridge(projectRoot: string, files: string[]): void {
  try {
    mkdirSync(BRIDGE_DIR, { recursive: true });
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
    writeFileSync(bridgePath(), JSON.stringify(payload));
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
      // Match-or-drop: only merge when the stored (verifier-authoritative)
      // hash still matches the file on disk. Never recompute a fresh hash.
      if (vf.hash !== hashFile(parsed.root, parsed.path)) continue;
      verifiedSet.set(vf.path, vf.hash);
      blockAttempts.delete(vf.path);
      recovered++;
    } catch {
      // Deleted/unhashable file — treat as no-match (fail-closed skip).
    }
  }
  if (recovered > 0) {
    console.log(`[verification-gate] 📂 Bridge recovery: merged ${recovered} verified files for this worktree`);
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
const GH_PR_PATTERN = /(^|\s)gh\s+pr\s+(create|merge)(?=\s|$)/;

export function isGitOp(command: string): boolean {
  return GIT_COMMIT_PATTERN.test(command) || GH_PR_PATTERN.test(command);
}

export function isGitCommit(command: string): boolean {
  return GIT_COMMIT_ONLY_PATTERN.test(command);
}

// ponytail: parse cd prefixes in bash commands so git ops in worktrees
// resolve to the correct repo root. pi's bash tool keeps process.cwd()
// unchanged even when the shell script starts with "cd /worktree &&".
export function extractCdPath(command: string): string | null {
  const m = command.match(/(?:^|\s)cd\s+(['"]?)([^;&|]+?)\1\s*(?:&&|;)/);
  return m ? resolve(m[2]) : null;
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
  try { realAbs = realpathSync(abs); } catch { /* keep lexical */ }
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
      extensionEnabled = false;
      console.log("[verification-gate] ⏸️  Disabled — ELDATO_SKIP_VGATE=1");
      appendJsonl({ event: "gate_bypass", extension: "verification-gate", reason: "escape_hatch", session_cwd: process.cwd() }); // #60: durable audit record (fail-safe)
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
      console.log("[verification-gate] ⏩ Bypassed — ELDATO_SKIP_VGATE=1 (per-command)");
      appendJsonl({ event: "gate_bypass", extension: "verification-gate", reason: "per_command_escape_hatch", session_cwd: process.cwd() }); // #60: durable audit record (fail-safe)
      return undefined;
    }

    const command = String(event.input.command ?? "");
    if (!isGitOp(command)) return undefined;

    // #7574: re-hash verified files if a prior git commit was allowed.
    // lint-staged (pre-commit hook) may have modified files (ESLint --fix),
    // changing their hashes. Capture the post-lint state before the next check.
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

    // Determine cwd — prefer cd prefix in command (worktree support)
    const inputCwd = event.input.cwd ? String(event.input.cwd) : process.cwd();
    const cdPath = extractCdPath(command);
    const cwd = resolveGitRoot(cdPath ?? inputCwd);

    // #190: mid-session bridge recovery — defense-in-depth for the incident's
    // event-miss class (a merge that landed via another path, e.g. a sub-agent's
    // own tool_result handler, becomes visible at the next git op).
    recoverBridgeForRoot(normalizeWorktreeRoot(cwd));

    // Compute diff
    let changedFiles: string[];
    if (GH_PR_PATTERN.test(command)) {
      changedFiles = computeBranchDiff(cwd);
    } else {
      changedFiles = computeStagedDiff(cwd);
    }

    if (changedFiles.length === 0) {
      // No changed files — allow
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
      } else if (verifiedHash !== currentHash) {
        mismatched.push({ file, expected: verifiedHash, actual: currentHash });
      }
    }

    // #7591: auto-bypass after N persistent blocks on the same files.
    // Track block attempts per file; allow if any file hits threshold.
    if (unverified.length > 0 || mismatched.length > 0) {
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
    const reason = [
      "⛔ Verification gate — blocking git operation.",
      "",
      ...reasons,
      "",
      `  → Dispatch the verifier sub-agent:`,
      `    task(prompt='[VGATE] verify files: ${allBlocked.join(' ')}. Classification: <UI|backend|both>. Project root: ${cwd}.', ...)`,
      "",
      "  Verifier response format — use one of:",
      '    1. Plain text: "PASS" on its own line (simplest)',
      '    2. JSON: {"status":"PASS","failures":[],"verified_files":[{"path":"...","hash":"..."}]}',
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
      if (vgateFailures >= VGATE_FAILURE_THRESHOLD) { extensionEnabled = false; console.log("[verification-gate] ⏸️ Auto-bypassed after 3 consecutive VGATE dispatch failures"); }
      return undefined;
    }

    const textContent = content
      .filter((c): c is { type: "text"; text: string } => c.type === "text")
      .map(c => c.text)
      .join("\n");

    if (!textContent) {
      console.error("[verification-gate] ⚠️ Verifier sub-agent returned no text content. Format: response must contain 'PASS' or valid JSON {status, failures, verified_files}.");
      vgateFailures++;
      if (vgateFailures >= VGATE_FAILURE_THRESHOLD) { extensionEnabled = false; console.log("[verification-gate] ⏸️ Auto-bypassed after 3 consecutive VGATE dispatch failures"); }
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
        if (foreign) lastBlockedFiles = []; // stale context — do not filter against it
        const normRoot = normalizeWorktreeRoot(projectRoot);

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
          if (isDir && lastBlockedFiles.length > 0) {
            for (const blocked of lastBlockedFiles) {
              if (blocked.startsWith(f)) promptFiles.add(blocked);
            }
          } else {
            promptFiles.add(f);
          }
        }

        // #190: bounded fallback — zero prompt files (format deviation) with a
        // genuine `verify files:` dispatch and a block context merges the
        // blocked diff (the gate-generated prompt names exactly those files).
        // The literal marker bounds this to file-verification dispatches; a
        // paraphrase without it stays blocked (fail-closed). Never applies to
        // the JSON branch (a JSON PASS names its files in verified_files).
        let mergeFiles: string[];
        if (promptFiles.size === 0 && lastBlockedFiles.length > 0 && /verify files:/i.test(prompt)) {
          mergeFiles = [...lastBlockedFiles];
          console.error(`[verification-gate] ⚠️ Plain-text PASS with zero prompt files — falling back to ${lastBlockedFiles.length} blocked files`);
        } else {
          mergeFiles = [...promptFiles];
        }

        // #190: shared diff-scoping — blocked-context filter (#5673) or, when
        // the context is empty/foreign, staged-diff scoping (never a blind
        // pass-through; known registry keys stay mergeable per #38).
        const { kept: filteredPromptFiles, skipped } = scopeFiles(mergeFiles, projectRoot, lastBlockedFiles, verifiedSet);
        let merged = 0;
        for (const file of filteredPromptFiles) {
          try {
            const relPath = normalizeRegistryPath(projectRoot, file);
            const key = compoundKey(normRoot, relPath);
            const hash = hashFile(projectRoot, file);
            verifiedSet.set(key, hash);
            blockAttempts.delete(key);
            merged++;
          } catch {
            // file may not exist at expected path — skip
          }
        }
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
      if (vgateFailures >= VGATE_FAILURE_THRESHOLD) { extensionEnabled = false; console.log("[verification-gate] ⏸️ Auto-bypassed after 3 consecutive VGATE dispatch failures"); }
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
  if (process.env.PI_MODE !== 'print') {
    console.log("[verification-gate] ✅ Loaded — blocking git operations until verification complete");
  }

  } catch (err: any) {
    console.error("[verification-gate] ❌ Failed to load:", err.message);
  }
}
