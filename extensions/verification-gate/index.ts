import type { ExtensionAPI, ToolCallEvent, ToolCallEventResult, ToolResultEvent } from "@earendil-works/pi-coding-agent";
import { isToolCallEventType } from "@earendil-works/pi-coding-agent";
import { execSync } from "node:child_process";
import { relative, resolve } from "node:path";
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync, existsSync, mkdirSync, unlinkSync, realpathSync } from "node:fs";
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
        // #37: compound keys encode worktree root — extract root + relative
        // path for hashing. Legacy plain-path entries use projectRoot as-is.
        // Bridge stores REPO-RELATIVE path (e2e contract #38): the compound
        // form is internal to the registry, not persisted.
        const parsed = parseCompoundKey(f);
        if (parsed) {
          verifiedFiles.push({ path: parsed.path, hash: hashFile(parsed.root, parsed.path) });
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

export function extractJson(text: string): VerificationResult | null {
  // Step 1: raw JSON.parse
  try {
    const trimmed = text.trim();
    return JSON.parse(trimmed) as VerificationResult;
  } catch {
    // continue
  }

  // Step 2: last ```json fence
  const fenceMatch = text.match(/```json\s*([\s\S]*?)```/g);
  if (fenceMatch) {
    try {
      return JSON.parse(fenceMatch[fenceMatch.length - 1].replace(/```json\s*|\s*```/g, "").trim());
    } catch {
      // continue
    }
  }

  // Step 3: last { to } pair
  const lastOpen = text.lastIndexOf("{");
  const lastClose = text.lastIndexOf("}");
  if (lastOpen !== -1 && lastClose !== -1 && lastClose > lastOpen) {
    try {
      return JSON.parse(text.slice(lastOpen, lastClose + 1));
    } catch {
      // fall through
    }
  }

  return null;
}

// ── Schema validation ─────────────────────────────────

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
      typeof f.hash === "string"
  );
}

// ── Plugin ────────────────────────────────────────────

export default function (pi: ExtensionAPI) {
  try {

  register("verification-gate");

  // ── session_start ──────────────────────────────────
  pi.on("session_start", async (_event, _ctx) => {
    verifiedSet.clear();
    // Recover verification state from bridge file (survives reloads)
    const bridge = readBridge();
    if (bridge && bridge.status === "PASS") {
      for (const vf of bridge.verified_files) {
        // #37: only recover compound-keyed entries (worktree-root::relative-path).
        // Legacy plain-path entries are skipped — without a worktree root they
        // cannot be matched against the current session, and blindly loading
        // them would risk cross-worktree hash contamination.
        if (vf.path.includes(COMPOUND_SEP)) {
          verifiedSet.set(vf.path, vf.hash);
        }
      }
      console.log(`[verification-gate] 📂 Recovered ${verifiedSet.size} verified files from bridge`);
    }
    vgateFailures = 0;
    lastBlockedCwd = null;
    pendingRehash = null;
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
    clearBridge();
    lastBlockedCwd = null;
    lastBlockedFiles = [];
    pendingRehash = null;
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
    if (pendingRehash !== null) {
      const rehashRoot = pendingRehash;
      pendingRehash = null;
      const normRehashRoot = normalizeWorktreeRoot(rehashRoot);
      let rehashed = 0;
      for (const [key] of verifiedSet) {
        // #37: only re-hash entries belonging to this worktree.
        const parsed = parseCompoundKey(key);
        if (!parsed || parsed.root !== normRehashRoot) continue;
        try {
          verifiedSet.set(key, hashFile(parsed.root, parsed.path));
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
      const hasPass = /(?:^|\n)\s*PASS/i.test(textContent) || /✅.*PASS/i.test(textContent);
      const hasFail = /(?:^|\n)\s*FAIL/i.test(textContent) || /❌.*FAIL/i.test(textContent);

      if (hasPass && !hasFail) {
        // Extract file list and project root from the prompt
        // Format: "[VGATE] verify files: path1 path2. Classification: ... Project root: /path"
        const fileMatch = prompt.match(/verify files:\s*(.+?)(?=\.\s+Classification:|\.\s+Project root:|$)/);
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
        const projectRoot = resolveProjectRoot(lastBlockedCwd, prompt);
        const normRoot = normalizeWorktreeRoot(projectRoot);

        // #5673: filter to only files in the blocked diff (not full repo scan)
        // #37: use compound keys for comparison.
        const blockedSet = new Set(lastBlockedFiles);
        const filteredPromptFiles = lastBlockedFiles.length > 0
          ? [...promptFiles].filter(f => blockedSet.has(normalizeRegistryPath(projectRoot, f)))
          : [...promptFiles];
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
        const skipped = promptFiles.size - filteredPromptFiles.length;
        if (merged > 0) {
          console.log(`[verification-gate] ✅ Plain-text PASS — merged ${merged}/${promptFiles.size} files from prompt${skipped > 0 ? ` (skipped ${skipped} not in diff)` : ''} (${verifiedSet.size} total)`);
          writeBridge(resolveProjectRoot(lastBlockedCwd, prompt), Array.from(verifiedSet.keys()));
        } else {
          console.error(`[verification-gate] ⚠️ Plain-text PASS but could not hash any files (${promptFiles.size} in prompt)`);
        }
        lastBlockedCwd = null; // consume: avoid stale cwd shadowing a later manual verifier dispatch (#5607)
        return undefined;
      }

      console.error("[verification-gate] ⚠️ Failed to extract JSON from verifier output. Format: response must contain 'PASS' or valid JSON {status, failures, verified_files}.");
      // ponytail: fail-open — if verifier is unparseable, extract files from prompt
      // and mark them as verified anyway. Better to allow the commit than
      // block on a model JSON-compliance issue (#5724).
      const fileMatch = prompt.match(/verify files:\s*(.+?)(?=\.\s+Classification:|\.\s+Project root:|$)/);
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
        const projectRoot = resolveProjectRoot(lastBlockedCwd, prompt);
        const normRoot = normalizeWorktreeRoot(projectRoot);
        let merged = 0;
        for (const file of promptFiles) {
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
          writeBridge(resolveProjectRoot(lastBlockedCwd, prompt), Array.from(verifiedSet.keys()));
          vgateFailures = 0;
          lastBlockedCwd = null;
          return undefined;
        }
      }
      vgateFailures++;
      if (vgateFailures >= VGATE_FAILURE_THRESHOLD) { extensionEnabled = false; console.log("[verification-gate] ⏸️ Auto-bypassed after 3 consecutive VGATE dispatch failures"); }
      return undefined;
    }

    if (!isValidResult(result)) {
      // ponytail: if status is PASS but schema incomplete (missing verified_files),
      // fall through to plain-text fallback — extract files from prompt and hash them.
      // Verifier sub-agents often return {"status":"PASS"} without the full schema.
      if ((result as any).status === "PASS") {
        const fileMatch = prompt.match(/verify files:\s*(.+?)(?=\.\s+Classification:|\.\s+Project root:|$)/);
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
          const fallbackRoot = resolveProjectRoot(lastBlockedCwd, prompt);
          const normFallbackRoot = normalizeWorktreeRoot(fallbackRoot);
          let merged = 0;
          for (const file of promptFiles) {
            try {
              const relPath = normalizeRegistryPath(fallbackRoot, file);
              const key = compoundKey(normFallbackRoot, relPath);
              verifiedSet.set(key, hashFile(fallbackRoot, file));
              blockAttempts.delete(key);
              merged++;
            } catch { /* skip */ }
          }
          if (merged > 0) {
            console.log(`[verification-gate] ✅ Schema-invalid PASS — merged ${merged}/${promptFiles.size} files via prompt fallback (${verifiedSet.size} total)`);
            const verifiedPaths = Array.from(verifiedSet.keys());
            writeBridge(fallbackRoot, verifiedPaths);
            vgateFailures = 0;
            lastBlockedCwd = null;
            return undefined;
          }
        }
      }
      console.error("[verification-gate] ⚠️ Verifier JSON failed schema validation. Expected: {status: 'PASS'|'FAIL', failures: string[], verified_files: [{path, hash}]}.");
      vgateFailures++;
      if (vgateFailures >= VGATE_FAILURE_THRESHOLD) { extensionEnabled = false; console.log("[verification-gate] ⏸️ Auto-bypassed after 3 consecutive VGATE dispatch failures"); }
      return undefined;
    }

    if (result.status !== "PASS") {
      console.error(`[verification-gate] ❌ Verifier returned FAIL: ${result.failures.join("; ")}`);
      vgateFailures++;
      if (vgateFailures >= VGATE_FAILURE_THRESHOLD) { extensionEnabled = false; console.log("[verification-gate] ⏸️ Auto-bypassed after 3 consecutive VGATE dispatch failures"); }
      return undefined;
    }

    // #5673/#7595: merge verifier files into the registry. Keys are normalized
    // to repo-relative; known paths always update (re-verification is authoritative).
    const projectRoot = resolveProjectRoot(lastBlockedCwd, prompt);
    const { merged, skipped } = mergeVerifiedFiles(verifiedSet, blockAttempts, result.verified_files, projectRoot, lastBlockedFiles);

    vgateFailures = 0;
    console.log(`[verification-gate] ✅ Merged ${merged} verified files${skipped > 0 ? ` (skipped ${skipped} not in diff)` : ''} (${verifiedSet.size} total)`);
    // Write bridge file so future sessions/sub-agents can see verification status
    const verifiedPaths = Array.from(verifiedSet.keys());
    if (verifiedPaths.length > 0) {
      writeBridge(projectRoot, verifiedPaths);
    }
    lastBlockedCwd = null; // consume on successful merge
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
