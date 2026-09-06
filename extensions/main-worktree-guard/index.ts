// See also: pi settings.json PreToolUse hook for Claude Code equivalent.
// This extension is the authoritative definition.
//
// Guards the SHARED main checkout of a project against:
//  1. write/edit tool calls (collision between parallel agents),
//  2. destructive/state-changing git commands via the bash tool (git reset
//     --hard, branch checkout/switch, pull/merge/rebase, clean, force-push,
//     branch -D, restore, stash pop),
//  3. (#265) cross-session BRANCH OWNERSHIP: the shared checkout is a
//     multi-actor resource — one session's `git checkout` moves the branch
//     under every other session, so commits land on the wrong branch and
//     reviewers read stale heads. A per-session baseline is recorded at
//     session_start; M1 warns on branch deviation (every tool_call), M2
//     blocks commit/push off-baseline, M3 gates branch-state mutations, and
//     an ownership allowance keeps the agent-infra merge ceremony working.
//  4. (#1484) HUB DISCIPLINE (M4): the hub's only legal states are main+clean.
//     When the session cwd IS the hub and it is off-main or dirty, every git
//     op outside the sanctioned recovery allowlist is BLOCKED (checkout
//     main/master, pull --ff-only, fetch, status, log, worktree ops, push
//     origin <checked-out-branch>, marker touch) and write/edit is blocked —
//     even under the TTL marker (only AGENT_ALLOW_MAIN_EDITS=1 disables it).
//     The script backdoor (`bash /tmp/x.sh` with git ops) is closed: a
//     script's git content is gated by the SAME allowlist.
//  4b. (#437) BASH-WRITE GATE on the disordered hub: while the hub is off-main
//     or dirty, a bash write to an INDEX-TRACKED hub file (heredoc/tee/`>`
//     redirect/python open(…,"w") — the mechanism that created the
//     2026-08-31 tortoise dirt after write/edit blocked) is BLOCKED, mirroring
//     the write/edit freeze on the bash route. Untracked/new-file writes stay
//     warn-only (#350) / allowed (#436 carve-out).
//  5. (#347) WORKTREE-TARGET EXEMPTION: M4 resolves each git invocation's
//     EFFECTIVE target (cd-chains, -C, GIT_DIR/--git-dir, subshell/pipe
//     scoping, worktree-list membership + cwd containment) and EXEMPTS
//     invocations whose target is an isolated worktree — a hub-rooted session
//     that `cd`s into a worktree is no longer frozen by hub disorder. The
//     write/edit M4 block is target-aware (hub-equality: only hub-targeted
//     writes block); the script backdoor resolves against the command's
//     execution cwd. No total-bash-gate bypass: the exemption is
//     per-invocation and semantic (never path-string-based); hub/foreign/
//     unresolvable targets keep today's gating.
//  6. (#350) HUB-WIP HYGIENE WARNINGS (never blocks): agents write WIP (plan
//     docs to docs/plans/, migrations, scratch files) directly in the hub main
//     checkout — the #347 amplifier. Three warn-only surfaces: (a) the
//     write/edit gate warns (agent-infra exemption + worktree-session
//     absolute-path writes into the hub) when the target matches the WIP
//     patterns; (b) bash-write detection warns on hub-targeted heredoc/tee/
//     python open() writes (heuristic, never blocks); (c) the session-start
//     hub-discipline check gains an untracked-WIP inventory (docs/plans/,
//     migrations/, scratch) + a throttled (5 min) periodic re-scan. All
//     warnings dedupe per pattern/path and are suppressed under the env hatch.
//
// Worktrees are ISOLATED — none of this applies inside a worktree. The only
// escape hatch is AGENT_ALLOW_MAIN_EDITS=1 (or ELDATO_ALLOW_MAIN_EDITS=1) or
// the TTL'd file marker (#207) for deliberate solo sessions; under the hatch
// M2/M3 are inactive (escape-hatch contract preserved) but M1 detection stays
// ACTIVE and M4 stays ACTIVE (a stranded lane recovers with the marker but
// cannot resume feature work in the hub). There is NO auto-bypass: the guard
// blocks every time, so a rogue/parallel agent cannot retry its way past it.
//
// Degradation contract:
//  - classify-git.mjs load failure → bash git guard degrades to warn-only
//    (fail-safe, never false-blocks) while the write/edit guard stays fully
//    enforced.
//  - branch-ownership.mjs load failure → M1/M2/M3 are OFF (one-time warn) and
//    the guard falls back to TODAY's behavior (agent-infra exempt); write/edit
//    never depends on either module.
//  - isWorktreeCwd defaults are SPLIT: the bash path fails OPEN (() => true —
//    a worktree lookalike is treated as isolated), the write/edit path fails
//    CLOSED (() => false — an unverifiable target is treated as main and
//    blocked). This fixes the latent fail-open at the old shared default.
// The TTL'd file-based escape marker (~/.pi/agent/.allow-main-edits, #207)
// allows a deliberate mid-session escalation — see README.md.

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { isToolCallEventType } from "@earendil-works/pi-coding-agent";
import { execSync, execFileSync } from "node:child_process";
import { resolve, dirname, join, relative } from "node:path";
import { realpathSync, existsSync, statSync, readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { isPrintMode } from "../shared/print-mode.js";
import { appendJsonl } from "../shared/audit-log.js";

// Shared destructive-git rules (also used by test.mjs). If the import ever
// fails (jiti resolution edge case), the bash guard degrades to warn-only
// while write/edit protection stays fully enforced.
let classifyGitCommand: (cmd: string) => string = () => "allow";
let classifyGitCommandDetailed: (cmd: string) => any = () => ({ verdict: "allow" });
let isWorktreeCwd: (cwd: string) => boolean = () => true;      // bash path: fail-open
let isWorktreeCwdWrite: (cwd: string) => boolean = () => false; // write/edit: fail-closed
let extractPushDeleteBranch: (cmd: string) => string[] | null = () => null;
let getWorktreeBranches: () => Map<string, string[]> = () => new Map();
let isBranchInMainCheckout: (branch: string) => boolean = () => false;
let getMainCheckoutBranch: () => string | null = () => null;
let isAgentInfraRepo: (cwd?: string, env?: Record<string, string | undefined>) => boolean = () => false;
// #1484 M4 hub-state gate + script-backdoor closure. Fail-safe defaults: every
// decision degrades to inactive/allow so a failed import NEVER false-blocks
// (the git commands were allow-listed before M4; the guard stays permissive).
let readHubDisorder: (cwd: string, opts?: { skipWorktree?: boolean; skipInfra?: boolean; env?: Record<string, string | undefined> }) => { disorder: string | null; branch: string | null } = () => ({ disorder: null, branch: null });
let evaluateHubGateWithTargets: (command: string, currentBranch: string | null, sessionCwd?: string, checkedOutBranches?: Set<string> | null) => { verdict: "non-git" | "allowed" | "recovery" | "block"; reason?: string; exempted?: boolean } = () => ({ verdict: "non-git" });
let commandExecutionCwd: (command: string, sessionCwd?: string) => string | null = () => null;
let resolveTargetTopLevel: (targetPath: string, cwd?: string) => string | null = () => null;
let extractScriptPath: (command: string) => string | null = () => null;
let scriptGitVerdict: (path: string, currentBranch: string | null, executionCwd?: string, sessionCwd?: string) => "allow" | "block" = () => "allow";
// #350: hub-WIP hygiene helpers (warn-only). Fail-safe defaults: inert
// (null/[]) so a failed import NEVER false-blocks — these warnings are
// discipline prompts, not gates.
let matchHubWipPattern: (resolvedPath: string) => "docs/plans" | "migrations" | "scratch" | null = () => null;
let extractBashWriteTargets: (command: string, cwd?: string) => { resolvedPath: string; via: string }[] = () => [];
let classifyUntrackedWip: (porcelain: string) => { untracked: string[]; wip: { path: string; pattern: string }[] } = () => ({ untracked: [], wip: [] });
// #437 (C): PER-WRITE-SITE bash-write candidates (cd-aware) for the
// disordered-hub gate + the pure tracked intersect. Fail-safe defaults inert.
let bashWriteTargetsResolved: (command: string, cwd?: string) => ({ resolvedPath: string; via: string; site: string; scriptToks?: { path: string; cwd: string }[] })[] = () => [];
// #437 (C): bash-write gate for TRACKED hub files in a DISORDERED hub (pure
// intersect of bash-write candidates with index-tracked rels). Fail-safe
// default: inert (null) — a failed import NEVER false-blocks (same contract
// as the #350 warn helpers; the gate is opt-in by explicit call only).
let firstHubTrackedWrite: (candidates: { resolvedPath: string; rel: string }[], trackedRels: string[]) => { resolvedPath: string; rel: string } | null = () => null;
let classifierLoaded = false;
let branchDeleteAllowance: (targetNames: string[], currentBranch: string | null, checkedOutBranches?: Set<string>) => boolean = () => false;
let newFileWriteCollisionFree: (relPath: string, untrackedPaths: string[]) => boolean = () => false;
let ALLOW_MAIN_EDITS_MARKER_TTL_MS = 15 * 60 * 1000;
// Escape-marker (#207) rules live in classify-git.mjs so test.mjs exercises the
// SAME logic. Fail-safe defaults: every marker function degrades to inactive
// (false/null) so a failed import NEVER silently allows.
let isAllowMarkerActive: (stats: unknown, nowMs?: number, ttlMs?: number) => boolean = () => false;
let isAllowMarkerPath: (path: string, home: string) => boolean = () => false;
let isAllowMarkerCommand: (command: string, home: string) => boolean = () => false;
let extractMarkerReason: (command: string) => string | null = () => null;
let parseMarkerContent: (content: string) => Record<string, unknown> | null = () => null;
let isAllowMarkerRealpath: (path: string) => boolean = () => false;
let readAllowMarkerState: (path: string, sessionId: string | null | undefined, nowMs?: number, ttlMs?: number) => boolean = () => false;
try {
  ({ classifyGitCommand, classifyGitCommandDetailed, isWorktreeCwd,
     extractPushDeleteBranch, getWorktreeBranches, isBranchInMainCheckout,
     getMainCheckoutBranch, isAgentInfraRepo, ALLOW_MAIN_EDITS_MARKER_TTL_MS,
     isAllowMarkerActive, isAllowMarkerPath, isAllowMarkerCommand,
     extractMarkerReason, parseMarkerContent, isAllowMarkerRealpath,
     readAllowMarkerState, readHubDisorder,
     extractScriptPath, scriptGitVerdict, evaluateHubGateWithTargets,
     commandExecutionCwd, resolveTargetTopLevel, matchHubWipPattern,
     extractBashWriteTargets, classifyUntrackedWip, branchDeleteAllowance, newFileWriteCollisionFree,
     firstHubTrackedWrite, bashWriteTargetsResolved } =
    await import("./classify-git.mjs"));
  classifierLoaded = true;
  isWorktreeCwdWrite = isWorktreeCwd; // real function once loaded
} catch (e) {
  console.warn("[main-worktree-guard] ⚠️ classify-git.mjs failed to load — bash git guard DISABLED:", String(e));
}

// #265: branch-ownership sentinel (baseline + M1/M2/M3 decisions + repo lock).
// Try/catch-guarded: load failure → M1/M2/M3 OFF + one-time warn; write/edit
// never depends on it.
let branchOwnership: any = null;
try {
  branchOwnership = await import("../shared/branch-ownership.mjs");
} catch (e) {
  console.warn("[main-worktree-guard] ⚠️ branch-ownership.mjs failed to load — M1/M2/M3 branch-ownership guards DISABLED (falling back to legacy behavior):", String(e));
}

// Dual-support: check AGENT_* first, then ELDATO_* (Phase 1 — #7549)
function _getEnv(name: string): string | undefined {
  return process.env[`AGENT_${name}`] ?? process.env[`ELDATO_${name}`];
}
// ── TTL'd file-based escape marker (#207) ─────────────────────
// The env hatch (AGENT_ALLOW_MAIN_EDITS=1) cannot be set on a RUNNING pi
// process — a stranded main checkout was unrecoverable by agents until a
// human intervened in a terminal. A deliberate solo session can now grant
// itself the same bypass for a bounded window by creating a marker file:
//
//   touch ~/.pi/agent/.allow-main-edits
//
// The marker is TTL'd (default 15 min), re-read on every tool_call (never
// cached), and never applies to parallel sessions automatically. Creation is
// logged with a reason when the reason is provided (marker content = reason).
function _isAllowMainEdits(): boolean {
  return _getEnv("ALLOW_MAIN_EDITS") === "1";
}
// ── Escape marker (#207) helpers ────────────────────────────────────────────
// Marker path is derived per call (lazy like gateEventsFile()) — never a
// module-level constant, so a $HOME change (tests, alternate agent dirs) works.
function _markerPath(): string {
  return join(homedir(), ".pi", "agent", ".allow-main-edits");
}
// Session id: env first (per-process scoping — pi writes PI_SESSION_ID into
// bash-tool child envs; subagents resolve their OWN id), then the ctx
// sessionManager fallback (loop-enforcer precedent), else null → fail-safe
// (a headless session with no id can never have an active marker).
function _currentSessionId(ctx?: { sessionManager?: { getSessionId?: () => string } }): string | null {
  return process.env.PI_SESSION_ID ?? ctx?.sessionManager?.getSessionId?.() ?? null;
}
// Guard-stamping at creation-observation: write the stamp BEFORE allowing the
// touch command. try/catch fail-silent (F7) — on failure the marker stays
// absent → block; a failed stamp never weakens the gate.
function _stampMarker(path: string, sessionId: string | null, reason: string | null): void {
  try {
    // P2 (review): ensure ~/.pi/agent exists — a missing dir made the stamp
    // (and thus the whole touch path) silently dead.
    mkdirSync(dirname(path), { recursive: true });
    const content = JSON.stringify({
      session_id: sessionId,
      reason: reason ?? null,
      ts: new Date().toISOString(),
    });
    writeFileSync(path, content + "\n", { flag: "w" });
    const expiresAt = new Date(Date.now() + ALLOW_MAIN_EDITS_MARKER_TTL_MS).toISOString();
    appendJsonl({
      event: "gate_bypass",
      extension: "main-worktree-guard",
      reason: "main_edits_marker",
      session_id: sessionId,
      marker_path: path,
      ttl_ms: ALLOW_MAIN_EDITS_MARKER_TTL_MS,
      expires_at: expiresAt,
      marker_content: content, // bare touch still records a timestamped creation (F10d)
    });
    console.log(
      `[main-worktree-guard] 🔓 Escape marker active for session ${sessionId} until ${expiresAt}${reason ? ` (reason: ${reason})` : ""}`
    );
  } catch (e) {
    console.warn("[main-worktree-guard] ⚠️ Escape-marker stamp failed (fail-silent — marker stays absent → block):", String(e));
  }
}

function _mainTopLevel(): string | null {
  try {
    return resolve(
      execSync("git rev-parse --show-toplevel", {
        encoding: "utf-8", cwd: resolve(process.cwd()), timeout: 5000,
      }).trim()
    );
  } catch {
    return null;
  }
}

// #73: coordinated remote-branch-delete block — a push-delete of a branch that
// ANY session still has checked out (the hub or a sibling worktree) destroys
// that session's upstream (incident 2026-08-06). Shared by the degradation-
// fallback arms below: the exact legacy verdict AND the #443 -d/--del spelling
// arm. Returns null (allow) when none of the deleted branches is checked out
// anywhere — foreign deletes with no checked-out targets are allowed.
function _coordinatedDeleteBlock(branchNames: string[]): { block: true; reason: string } | null {
  if (!branchNames || branchNames.length === 0) return null;
  const worktreeBranches = getWorktreeBranches();
  const blockedBranches: string[] = [];
  for (const branchName of branchNames) {
    const branchRef = `refs/heads/${branchName}`;
    const checkedOutPaths = [...(worktreeBranches.get(branchRef) || [])];
    if (isBranchInMainCheckout(branchName)) {
      const mainTopLevel = _mainTopLevel();
      const mainLabel = mainTopLevel || "main checkout";
      if (!checkedOutPaths.includes(mainLabel)) checkedOutPaths.push(mainLabel);
    }
    if (checkedOutPaths.length > 0) {
      blockedBranches.push(`"${branchName}" — checked out in: ${checkedOutPaths.join(", ")}`);
    }
  }
  if (blockedBranches.length === 0) return null;
  return {
    block: true,
    reason: [
      `⛔ Cannot delete — the following branches are currently checked out:`,
      ...blockedBranches.map((b: string) => `   • ${b}`),
      "",
      "   Why: deleting a remote branch while another session has it",
      "   checked out destroys that session's upstream (incident 2026-08-06).",
      "   → Switch those worktrees/main to another branch first, then retry.",
      "   → Or set AGENT_ALLOW_MAIN_EDITS=1 (or ELDATO_ALLOW_MAIN_EDITS=1) to override.",
    ].join("\n"),
  };
}

// ── M4: hub-state gate (#1484) ─────────────────────────────────────────────
// The hub's only legal states are main+clean. When the session cwd IS the hub
// main checkout (non-infra) and the hub is off-main or dirty, every git op is
// gated by the recovery allowlist (classify-git evaluateHubGateWithTargets) and
// write/edit in the hub is blocked. #347: each git invocation's EFFECTIVE
// target is resolved — invocations targeting an isolated worktree (worktree-
// list membership + cwd containment) are exempt from hub disorder; the
// write/edit M4 block gates only HUB-targeted writes (hub-equality); the script
// backdoor resolves against the command's execution cwd. M4 stays ACTIVE under
// the TTL marker (D3 — mirrors M1's detect-stays-active contract): a stranded
// lane can recover with the marker but cannot resume feature work in the hub.
// Only AGENT_ALLOW_MAIN_EDITS=1 (env, session start) is a full bypass. Worktree
// sessions and agent-infra are exempt (D5 / #99).
function _hubState(): { disorder: string | null; branch: string | null } {
  try {
    return readHubDisorder(resolve(process.cwd()));
  } catch {
    return { disorder: null, branch: null }; // degrade — never false-block
  }
}

// #436 (B carve-out): collision-free NEW-FILE write allowance in a disordered
// hub (pure decision in classify-git newFileWriteCollisionFree — unit-tested).
// Overwrites of existing files (tracked or untracked) stay blocked: that is
// the hub-feature-edit vector (#347 amplifier) that created the dirty sets in
// the first place. Failsafe: any git/parse error → false (block).
function _hubNewFileWriteAllowed(targetPath: string): boolean {
  try {
    if (!targetPath || !classifierLoaded) return false;
    const resolved = resolve(process.cwd(), targetPath);
    if (existsSync(resolved)) return false; // overwrite, not a new file
    const mainTop = _mainTopLevel();
    if (!mainTop) return false;
    const rel = relative(mainTop, resolved);
    if (!rel || rel.startsWith("..")) return false; // outside hub
    const porcelain = execSync("git status --porcelain=v1 --untracked-files=all", {
      encoding: "utf-8", timeout: 5000,
    }).trim();
    if (!porcelain) return true; // hub clean (caller usually only asks when disordered — still safe)
    const { untracked } = classifyUntrackedWip(porcelain);
    return newFileWriteCollisionFree(rel, untracked);
  } catch {
    return false; // fail-safe — never carve out on error
  }
}

// ── #350: hub-WIP hygiene (write-gate WARNING + hub-hygiene check) ─────────
// The #347 amplifier: agents write WIP (plan docs to docs/plans/, migrations,
// scratch files) directly in the hub main checkout instead of a worktree,
// either via the write/edit tool (agent-infra is exempt from the block) or via
// bash heredoc/tee/python (unguarded). All three surfaces below WARN — never
// block: the write/edit block for main-checkout edits is unchanged; these are
// discipline prompts surfacing the violation at write time.
const HUB_HYGIENE_THROTTLE_MS = 5 * 60 * 1000; // periodic scan: at most once per 5 min
const MAIN_TOP_RETRY_MS = 30 * 1000;          // failed cache resolution: retry after 30s (never per-command)
const WIP_PATTERN_LABEL: Record<string, string> = {
  "docs/plans": "a plan doc in docs/plans/",
  migrations: "a migration in migrations/",
  scratch: "a scratch/backup file (.tmp/.bak/.scratch/~)",
};
let cachedMainTopLevel: string | null | undefined; // undefined = not yet resolved
let lastMainTopAttemptMs = 0;
let lastHubHygieneMs = 0;
const warnedWipTargets = new Set<string>(); // tool-call warnings: once per (pattern,path) per session
const warnedWipPaths = new Set<string>();    // inventory warnings: once per path per session

// The MAIN checkout's toplevel (git worktree list first entry = the primary
// worktree — empirically stable on git 2.50.1, though not formally guaranteed
// by git docs). Works from a hub session AND a worktree session. One git call
// at first use (warmed at session_start); a FAILED resolution is NOT cached
// terminally — the negative-TTL gate (MAIN_TOP_RETRY_MS) re-attempts on the
// next tool call after 30s, so a transient failure cannot disable the
// surfaces for the whole session. The retry is bounded to once per 30s and
// only fires on the rare null-cache path, so it never sits on the bash hot
// path for healthy sessions.
function _cachedMainTopLevel(): string | null {
  const now = Date.now();
  if (typeof cachedMainTopLevel === "string") return cachedMainTopLevel;
  if (lastMainTopAttemptMs !== 0 && now - lastMainTopAttemptMs < MAIN_TOP_RETRY_MS) {
    return cachedMainTopLevel ?? null; // negative-TTL: skip retry within the window
  }
  lastMainTopAttemptMs = now;
  try {
    const first = execSync("git worktree list --porcelain", {
      encoding: "utf-8", timeout: 5000,
    }).split("\n")[0] ?? "";
    // realpath-normalize (mirrors the #347 hub-equality doctrine — symlink
    // spellings of the hub must not diverge from the write-target side).
    cachedMainTopLevel = first ? realpathSync(resolve(first.replace(/^worktree\s+/, "").trim())) : null;
  } catch {
    cachedMainTopLevel = null;
  }
  return cachedMainTopLevel ?? null;
}

// Realpath the nearest EXISTING ancestor of a (possibly not-yet-created)
// target path, re-appending the missing tail — the realpath twin of
// resolveTargetTopLevel's walk-up, so hub-equality compares realpath-normalized
// paths on both sides (symlinked hub spellings converge).
function _realpathNearest(p: string): string {
  try {
    let d = p;
    let tail = "";
    while (!existsSync(d)) {
      const parent = dirname(d);
      if (parent === d) break;
      tail = d.slice(parent.length) + tail;
      d = parent;
    }
    return realpathSync(d) + tail;
  } catch {
    return p;
  }
}

function _truncatePath(p: string, max = 52): string {
  const s = String(p);
  return s.length <= max ? s : "…" + s.slice(-(max - 1));
}

// Shared box-drawn banner (matches the existing hub-discipline style; every
// content line is kept within the 62-char interior so the box stays square).
function _warnHubWip(pattern: string, targetPath: string, via?: string) {
  const label = WIP_PATTERN_LABEL[pattern] ?? pattern;
  const viaNote = via ? ` (via bash ${via})` : "";
  const L = (t: string) => "║  " + t.padEnd(62) + "║";
  const lines = [
    "",
    "╔══════════════════════════════════════════════════════════════════╗",
    L("⚠️  HUB WIP — PUT IT IN A WORKTREE (#350)"),
    "╠══════════════════════════════════════════════════════════════════╣",
    L(`Target: ${_truncatePath(targetPath, via ? 34 : 52)}${viaNote}`),
    L(`Pattern: ${label}`),
    L(""),
    L("Untracked WIP in main is the #347 amplifier: it marks the hub"),
    L("dirty, trips M4's freeze, and collides with parallel agents."),
    L("→ Create a worktree (one command):"),
    L("  bash scripts/checkout-hygiene/hub-worktree.sh <branch>"),
    "╚══════════════════════════════════════════════════════════════════╝",
    "",
  ];
  console.warn(lines.join("\n"));
}

// Inventory banner for the session-start / periodic hub-hygiene check.
function _warnHubWipInventory(wip: { path: string; pattern: string }[]) {
  if (wip.length === 0) return;
  const L = (t: string) => "║  " + t.padEnd(62) + "║";
  const lines = [
    "",
    "╔══════════════════════════════════════════════════════════════════╗",
    L("⚠️  UNTRACKED WIP IN MAIN — #347 AMPLIFIER (#350)"),
    "╠══════════════════════════════════════════════════════════════════╣",
    L("Untracked WIP in the shared main checkout — move it to a"),
    L("worktree (hub hygiene):"),
    ...wip.slice(0, 8).map((w) => L(`  • ${_truncatePath(w.path, 44)} (${w.pattern})`)),
    ...(wip.length > 8 ? [L(`  … and ${wip.length - 8} more`)] : []),
    L(""),
    L("Untracked WIP marks the hub dirty → M4 freezes every sibling"),
    L("session (the 2026-08-27 tortoise incident class)."),
    L("→ Create a worktree:"),
    L("  bash scripts/checkout-hygiene/hub-worktree.sh <branch>"),
    "╚══════════════════════════════════════════════════════════════════╝",
    "",
  ];
  console.warn(lines.join("\n"));
}

// Path-deduped inventory warning (shared by the session-start check and the
// periodic check — whichever fires first warns; the other is silent).
function _maybeWarnHubWipInventory(wip: { path: string; pattern: string }[]) {
  const fresh = wip.filter((w) => !warnedWipPaths.has(w.path));
  if (fresh.length === 0) return;
  for (const w of fresh) warnedWipPaths.add(w.path);
  _warnHubWipInventory(fresh);
}

// Bounded untracked-WIP classification from a COLLAPSED porcelain string:
// classify the collapsed entries directly, and expand per-file
// (--untracked-files=all) only when `?? ` entries exist — a clean hub costs
// zero extra git calls and a huge untracked tree cannot stall the check
// (the collapsed pass already flagged it dirty). Warn-only — degrades silently.
function _wipFromPorcelain(porcelain: string): { path: string; pattern: string }[] {
  try {
    if (!classifierLoaded) return []; // degraded: classifyUntrackedWip is inert
    const parsed = classifyUntrackedWip(porcelain);
    if (!porcelain.includes("?? ")) return parsed.wip;
    const all = execSync("git status --porcelain=v1 --untracked-files=all", {
      encoding: "utf-8", timeout: 5000,
    }).trim();
    return classifyUntrackedWip(all).wip;
  } catch {
    return []; // warn-only — degrade silently, never blocks
  }
}

// Classify untracked WIP in the session repo (two-phase, same bounded
// expansion as _wipFromPorcelain). Returns null on git failure / worktree
// session / classifier load failure (warn-only helper — degrades silently).
function _hubWipInventory(): { wip: { path: string; pattern: string }[] } | null {
  try {
    if (!classifierLoaded) return null; // degraded: classifyUntrackedWip is inert — stay dormant
    if (isWorktreeCwdWrite(resolve(process.cwd()))) return null; // worktree sessions are isolated
    const porcelain = execSync("git status --porcelain=v1", {
      encoding: "utf-8", timeout: 5000,
    }).trim();
    return { wip: _wipFromPorcelain(porcelain) };
  } catch {
    return null; // warn-only — degrade silently, never blocks
  }
}

// Throttled periodic hub-hygiene check (#350): once per HUB_HYGIENE_THROTTLE_MS
// re-scan the hub for untracked WIP and warn (path-deduped). NEVER per-command
// — the time throttle keeps it off the bash hot path; the cache is only
// refreshed when it is unresolved (a warm cache is stable within a session).
function _periodicHubHygieneCheck() {
  if (_isAllowMainEdits()) return; // full bypass — no prompts
  const now = Date.now();
  if (now - lastHubHygieneMs < HUB_HYGIENE_THROTTLE_MS) return;
  lastHubHygieneMs = now;
  try {
    _cachedMainTopLevel(); // refresh only when unresolved (negative-TTL bounds retries)
    const inv = _hubWipInventory();
    if (!inv) return;
    _maybeWarnHubWipInventory(inv.wip);
  } catch { /* warn-only */ }
}

// #350 write-gate WARNING (never block): a write/edit target inside the hub
// main checkout matching the WIP patterns (docs/plans/, migrations, scratch).
// Pure pattern pre-filter first (cheap), then hub-equality against the cached
// main toplevel (realpath-normalized both sides). Skips /tmp scratch-ish
// targets (hub-equality) and dedupes per (pattern, path) per session.
function _maybeWarnHubWipWrite(targetPath: string | undefined) {
  try {
    if (!targetPath) return;
    if (_isAllowMainEdits()) return;
    const pattern = matchHubWipPattern(targetPath);
    if (!pattern) return;
    const resolved = _realpathNearest(resolve(process.cwd(), targetPath));
    const mainTop = _cachedMainTopLevel();
    if (!mainTop) return;
    if (resolved !== mainTop && !resolved.startsWith(mainTop + "/")) return; // not hub-targeted
    const dedupeKey = `write:${pattern}:${resolved}`;
    if (warnedWipTargets.has(dedupeKey)) return;
    warnedWipTargets.add(dedupeKey);
    _warnHubWip(pattern, resolve(process.cwd(), targetPath)); // display the un-realpath'd path
  } catch { /* warn-only — never blocks */ }
}

// #350 bash-write detection (never block): heredoc/tee/python open() writing a
// WIP pattern into the hub main checkout. Pure quote-aware scan + cached hub
// toplevel (realpath-normalized) — no per-command git; warnings dedupe per
// (pattern, path) per session.
function _maybeWarnBashWrite(command: string) {
  try {
    if (_isAllowMainEdits()) return;
    const targets = extractBashWriteTargets(command, process.cwd());
    if (targets.length === 0) return;
    const mainTop = _cachedMainTopLevel();
    if (!mainTop) return;
    for (const t of targets) {
      const pattern = matchHubWipPattern(t.resolvedPath); // pure pre-filter FIRST — no fs on the hot path
      if (!pattern) continue;
      const resolvedReal = _realpathNearest(t.resolvedPath);
      if (resolvedReal !== mainTop && !resolvedReal.startsWith(mainTop + "/")) continue;
      const dedupeKey = `bash:${pattern}:${resolvedReal}`;
      if (warnedWipTargets.has(dedupeKey)) continue;
      warnedWipTargets.add(dedupeKey);
      _warnHubWip(pattern, t.resolvedPath, t.via);
    }
  } catch { /* warn-only — never blocks */ }
}

// #437 (C): bash-write GATE for TRACKED hub files in a DISORDERED hub — the
// root-cause closure for the dirty-hub inflow (session 01a05704 wrote tracked
// hub files via python/heredoc after write/edit tools blocked; the #350
// bash-write path was warn-only). Semantics mirror the M4 write/edit gate:
// while the hub is disordered, overwriting an EXISTING tracked hub file via
// bash is blocked; NEW-file writes and untracked WIP keep the warn-only
// treatment (and the #436 collision-free carve-out). Fail-safe: any git/
// parse error → null (never false-block). One bounded `git ls-files` spawn
// for all candidates, only while the hub is disordered. Uses the
// PER-WRITE-SITE extractor (bashWriteTargetsResolved — cd-aware, -c/eval
// recursion, heredoc-body/escaped-\> exclusion) + reads script-file content
// (`bash /tmp/x.sh` → the script's own writes are real code — git-side
// scriptGitVerdict parity).
function _hubBashTrackedWrite(command: string, execCwd?: string): { resolvedPath: string; rel: string } | null {
  try {
    if (!classifierLoaded || isWorktreeCwdWrite(resolve(process.cwd()))) return null;
    // cycle-27 P2: the base MUST be the session cwd — bashWriteTargetsResolved
    // applies the command's OWN cd chain from its session base (script tokens
    // carry their site cwd). Passing a pre-consumed execCwd (already cd'd by
    // commandExecutionCwd for the git-side _backdoorBlock) DOUBLE-APPLIED the
    // relative cd (`cd docs && bash x.sh` with a docs/docs/ dir present made
    // x.sh resolve one level too deep → existsSync miss → content never walked).
    const base = resolve(process.cwd());
    const extracted = bashWriteTargetsResolved(command, base);
    const targets = extracted.filter((t) => (t as { resolvedPath?: string }).resolvedPath);
    if (targets.length === 0 && !(extracted as { scriptToks?: unknown[] }).scriptToks?.length) return null;
    const mainTop = _cachedMainTopLevel();
    if (!mainTop) return null;
    // Hub-equality filter (realpath-normalized both sides — mirrors the #350
    // warn path): only targets physically inside the session hub qualify.
    // (Worktree targets — cd /wt && … — resolve OUTSIDE mainTop → exempt.)
    const candidates: { resolvedPath: string; rel: string }[] = [];
    for (const t of targets) {
      const tPath = (t as { resolvedPath: string }).resolvedPath;
      const resolvedReal = _realpathNearest(tPath);
      if (resolvedReal !== mainTop && !resolvedReal.startsWith(mainTop + "/")) continue;
      const rel = resolvedReal.slice(mainTop.length).replace(/^[/\\]+/, "");
      if (!rel || resolvedReal === mainTop) continue;
      candidates.push({ resolvedPath: tPath, rel });
    }
    // Script-file content (`bash /tmp/x.sh` / `source f` / `. f`): resolve +
    // read (<=64KB) and run the same walker over the script body — its
    // redirects/tee/python run in the SCRIPT's own process against the caller's
    // cwd (git-side scriptGitVerdict reads the same way; bounded read,
    // fail-open on error). cycle-21 P2-3: NESTED script/source chains
    // (wrapper.sh sources lib.sh) are followed to a bounded depth.
    const scriptToks = (extracted as { scriptToks?: { path: string; cwd: string }[] }).scriptToks ?? [];
    const seenScripts = new Set<string>();
    const pendingScripts = scriptToks.slice();
    let depthBudget = 8;
    while (pendingScripts.length > 0 && depthBudget-- > 0) {
      const st = pendingScripts.shift()!;
      const stKey = `${st.cwd || base}\u0000${st.path}`;
      if (seenScripts.has(stKey)) continue;
      seenScripts.add(stKey);
      try {
        const sp = resolve(st.cwd || base, st.path);
        if (!existsSync(sp) || !statSync(sp).isFile()) continue;
        // cycle-24 P2: a DIRECT-EXEC token (`./run.sh`) only runs when the
        // file is executable — a non-exec data file (./README.md) is
        // "permission denied" in real bash and its prose must never content-walk.
        if ((st as { mode?: string }).mode === "direct" && (statSync(sp).mode & 0o111) === 0) continue;
        const content = readFileSync(sp, "utf-8").slice(0, 64 * 1024);
        const innerR = bashWriteTargetsResolved(content, st.cwd || base);
        for (const inner of innerR) {
          const ip = (inner as { resolvedPath?: string }).resolvedPath;
          if (!ip) continue;
          const resolvedReal = _realpathNearest(ip);
          if (resolvedReal !== mainTop && !resolvedReal.startsWith(mainTop + "/")) continue;
          const rel = resolvedReal.slice(mainTop.length).replace(/^[/\\]+/, "");
          if (!rel || resolvedReal === mainTop) continue;
          candidates.push({ resolvedPath: ip, rel });
        }
        for (const nested of (innerR as { scriptToks?: { path: string; cwd: string }[] }).scriptToks ?? []) {
          pendingScripts.push(nested);
        }
      } catch { /* never false-block */ }
    }
    if (candidates.length === 0) return null;
    // ONE bounded index query for all candidates: `git ls-files
    // --error-unmatch` prints exactly the TRACKED rels (exit≠0 when any path
    // is untracked — stdout still carries the tracked matches; execFileSync
    // throws on exit≠0, so catch and read the captured stdout).
    let out = "";
    try {
      out = execFileSync("git", ["ls-files", "--error-unmatch", "--", ...candidates.map((c) => c.rel)], {
        cwd: mainTop, encoding: "utf-8", timeout: 5000,
      }).toString();
    } catch (e) {
      out = (e as { stdout?: Buffer | string }).stdout?.toString?.() ?? "";
    }
    const trackedRels = out.split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
    if (trackedRels.length === 0) return null;
    return firstHubTrackedWrite(candidates, trackedRels);
  } catch {
    return null; // never false-block
  }
}

// #437 (C): the block reason for a tracked-hub bash write — states the single
// coherent rule (bash writes respect the same hub gate as the write/edit
// tools; only session-start host env bypasses; a mid-command `export` cannot)
// plus the sanctioned ways forward (salvage / worktree / new-file path).
function _hubBashWriteBlockReason(hit: { resolvedPath: string; rel: string }): string {
  return [
    `⛔ Bash write to a tracked hub file blocked (${hit.rel}).`,
    `   The shared main checkout is OFF-MAIN or DIRTY (#1484) — bash WRITE`,
    `   PRIMITIVES to tracked files respect the SAME gate as the tools:`,
    `   >/>>/&> redirects, tee, and python open(...,"w"/"a").`,
    `   Untracked/new-file writes stay allowed; only session-start host env`,
    `   (AGENT_ALLOW_MAIN_EDITS=1) bypasses — a mid-command export cannot.`,
    `   (In-place overwrite VERBS like sed -i / cp are not a write primitive;`,
    `   prefer the salvage/worktree routes below for those.)`,
    `   → Capture the dirty set first (hub returns to main+CLEAN):`,
    `     bash scripts/checkout-hygiene/hub-worktree.sh salvage <branch> <repo>`,
    `   → Or write into a worktree (using-git-worktrees skill).`,
  ].join("\n");
}

// Script-backdoor closure (Slice E): the documented escape
// (`write /tmp/x.sh` + `bash /tmp/x.sh`) is closed by gating the script's git
// content with the SAME recovery allowlist — a script that performs a
// non-sanctioned git mutation is blocked. Recovery scripts (hub-worktree.sh:
// fetch + worktree add) keep working. Returns a block reason or null.
function _backdoorBlock(command: string, execCwd?: string): string | null {
  try {
    if (isWorktreeCwdWrite(resolve(process.cwd()))) return null; // worktree sessions are isolated
    if (isAgentInfraRepo()) return null; // #99 carve-out
    const scriptPath = extractScriptPath(command);
    if (!scriptPath) return null;
    // #347: resolve the script path + content gating against the command's
    // EXECUTION cwd (cd-resolved), not the session cwd — a hub session running
    // `cd <wt> && bash x.sh` resolves x.sh inside the worktree.
    const base = execCwd ? resolve(execCwd) : resolve(process.cwd());
    const resolved = resolve(base, scriptPath);
    if (!existsSync(resolved) || !statSync(resolved).isFile()) return null;
    const branch = getMainCheckoutBranch();
    if (scriptGitVerdict(resolved, branch, base, resolve(process.cwd())) === "block") {
      return [
        `⛔ Script execution blocked — git-bearing script in the shared main checkout (#1484).`,
        `   The script backdoor (write /tmp/x.sh + bash /tmp/x.sh) is closed:`,
        `   ${resolved} contains a non-sanctioned git operation.`,
        `   → Run the git commands directly (recovery: git checkout main && git pull --ff-only),`,
        `     or work in an isolated worktree:`,
        `     bash scripts/checkout-hygiene/hub-worktree.sh <branch>`,
      ].join("\n");
    }
    return null;
  } catch {
    return null; // fail-silent — never block on read/stat errors
  }
}

const WHY = [
  "⛔ Operation blocked in the MAIN checkout.",
  "   Why: the main checkout is SHARED between parallel agents. Branch-state",
  "   changes and hard resets here silently destroy other agents' uncommitted",
  "   work and move branches out from under them (incident 2026-08-06: a",
  "   `git reset --hard origin/main` wiped an in-progress PR mid-review; #265:",
  "   one session's checkout moved every other session's branch).",
  "   → Work in an isolated worktree: invoke the using-git-worktrees skill.",
  "   → Or set AGENT_ALLOW_MAIN_EDITS=1 (or ELDATO_ALLOW_MAIN_EDITS=1) for",
  "     deliberate solo sessions.",
].join("\n");

// ── #265 per-session baseline state ────────────────────────────────────────
// Keyed by process.pid (one pi process == one session; SessionStartEvent
// carries no sessionId). Baseline = { repoKey, branch, head } of the shared
// MAIN checkout at session_start. M1 dedupe: Set of "from→to" deviations.
const baselines = new Map<number, { repoKey: string; branch: string | null; head: string }>();
const warnedDeviations = new Map<number, Set<string>>();
const pendingBaseline = new Set<number>(); // lock contended at session_start → record on first tool_call

function _recordBaseline(pid: number) {
  if (!branchOwnership) return;
  try {
    const cwd = resolve(process.cwd());
    const state = branchOwnership.readBranchState(cwd);
    if (!state) return;
    const key = branchOwnership.repoKey(cwd);
    if (!key) return;
    if (!baselines.has(pid)) {
      baselines.set(pid, { repoKey: key, branch: state.branch, head: state.head });
    }
  } catch { /* degrade silently — M1/M2 skip without a baseline */ }
}

function _rebaseline(pid: number, branch: string) {
  const baseline = baselines.get(pid);
  if (baseline && branch) {
    baselines.set(pid, { ...baseline, branch }); // head refreshed lazily (unused in decisions)
  }
}

// ── M1: warn on branch deviation (every tool_call, all tool types) ────────
function _m1(pid: number) {
  if (!branchOwnership) return;
  const baseline = baselines.get(pid);
  if (!baseline) return;
  try {
    // P2-B: only warn for the BASELINE repo's MAIN checkout. A session that
    // cd'd into a worktree or another repo gets a spurious (and misleading)
    // "commits are BLOCKED" warning — commits are NOT blocked in a worktree.
    if (isWorktreeCwdWrite(resolve(process.cwd()))) return;
    const keyNow = branchOwnership.repoKey(process.cwd());
    if (!keyNow || keyNow !== baseline.repoKey) return;
    const state = branchOwnership.readBranchState(resolve(process.cwd()));
    if (!state) return;
    const dev = branchOwnership.decideM1(state.branch, baseline.branch);
    if (!dev) return;
    const key = `${dev.from}→${dev.to}`;
    let seen = warnedDeviations.get(pid);
    if (!seen) { seen = new Set(); warnedDeviations.set(pid, seen); }
    if (seen.has(key)) return;
    seen.add(key);
    console.warn(
      `[main-worktree-guard] ⚠️ MAIN CHECKOUT BRANCH CHANGED mid-session (#265): ` +
      `baseline "${dev.from}" → current "${dev.to}". Another session/process switched ` +
      `the shared tree. Commits are BLOCKED until you check out your own branch.`
    );
  } catch { /* warn-only — never blocks reads */ }
}

export default function (pi: ExtensionAPI) {
  // ── Session-start: record the branch-ownership baseline + hub check ──────
  pi.on("session_start", async () => {
    const pid = process.pid;
    if (branchOwnership) {
      try {
        // Only main-checkout sessions get a baseline (worktrees are isolated).
        if (!isWorktreeCwdWrite(resolve(process.cwd()))) {
          const key = branchOwnership.repoKey(process.cwd());
          if (key) {
            // RETRIES (bounded, ~20s ceiling), never skips: a session without a
            // baseline is unguarded. Fallback: record on the first tool_call.
            const lock = branchOwnership.acquireRepoLock(key, pid, { timeoutMs: 20_000, retryMs: 250 });
            if (lock.held) {
              const state = branchOwnership.readBranchState(process.cwd());
              if (state && !baselines.has(pid)) {
                baselines.set(pid, { repoKey: key, branch: state.branch, head: state.head });
              }
              branchOwnership.releaseRepoLock(key, pid);
            } else {
              pendingBaseline.add(pid);
            }
          }
        }
      } catch (e) {
        console.warn("[main-worktree-guard] ⚠️ baseline record failed:", String(e));
      }
    }

    // ── Hub-discipline check (rehomed from extension-init; #73) ──
    // #1484: runs in print mode too — a print-mode session rooted in the hub
    // gets the warn (daemons live in role-scoped worktrees, so legitimate
    // headless sessions never see it; the 29h silent incident was invisible
    // to them). Skipped only under the escape hatch.
    if (_isAllowMainEdits()) return;
    try {
      // #350: warm the cached hub toplevel before any tool_call so the
      // bash-write/write-gate warnings never trigger a git call mid-command,
      // and seed the periodic-hygiene throttle (the inventory already ran here).
      _cachedMainTopLevel();
      lastHubHygieneMs = Date.now();
      const inWorktree = isWorktreeCwdWrite(resolve(process.cwd()));
      if (inWorktree) return;
      const currentBranch = getMainCheckoutBranch();
      // #73 dirty check stays on COLLAPSED porcelain (untracked dirs → one
      // `?? dir/` entry) — fast and robust on hubs with large untracked trees;
      // the #350 inventory expands per-file below, bounded by a `?? ` gate.
      const porcelain = execSync("git status --porcelain=v1", {
        encoding: "utf-8", timeout: 5000,
      }).trim();
      const onNonMain = currentBranch && currentBranch !== "main" && currentBranch !== "master";
      const dirty = porcelain.length > 0;

      if (isAgentInfraRepo()) {
        // Downgraded agent-infra variant: branch deviation is the NORM in the
        // infra repo (in-main feature work per #99) — warn on dirty tree only,
        // plus the #350 untracked-WIP inventory (the #347 amplifier lives in
        // the infra hub too: plan docs in docs/plans/, migrations, scratch).
        if (dirty) {
          console.warn(`[main-worktree-guard] ⚠️ agent-infra main checkout is DIRTY (${porcelain.split("\n").length} change(s)) — parallel sessions may collide; commit or stash before other agents start.`);
        }
        _maybeWarnHubWipInventory(_wipFromPorcelain(porcelain));
        return;
      }
      if (onNonMain || dirty) {
        const issues: string[] = [];
        if (onNonMain) issues.push(`on branch "${currentBranch}" (not main/master)`);
        if (dirty) issues.push("working tree is dirty (uncommitted changes or untracked files)");

        const lines = [
          "",
          "╔══════════════════════════════════════════════════════════════════╗",
          "║  ⚠️  MAIN CHECKOUT — HUB DISCIPLINE WARNING                      ║",
          "╠══════════════════════════════════════════════════════════════════╣",
        ];
        for (const issue of issues) {
          lines.push(`║  ${issue.padEnd(62)}║`);
        }
        // #437 (C): routing nudge — the concrete one-liner beats the generic
        // skill pointer (cycle-28 P2: the SESSION_START copy must carry the
        // same nudge as the module-load copy — it is the one that fires on
        // /resume and in print-mode/task-sub-agent contexts).
        const nudge: string[] = [];
        nudge.push("Feature work should happen in isolated worktrees.");
        nudge.push("→ using-git-worktrees skill, or hub-worktree.sh <branch>");
        nudge.push("   (helper: agent-infra scripts/checkout-hygiene/)");
        if (dirty && !onNonMain) {
          nudge.push("→ dirty-on-main: hub-worktree.sh salvage <branch> first");
        }
        for (const n of nudge) {
          lines.push(`║  ${n.padEnd(62)}║`);
        }
        lines.push(
          "║  → Invoke the using-git-worktrees skill to create one.            ║",
          "║  → Set AGENT_ALLOW_MAIN_EDITS=1 to suppress this warning.         ║",
          "╚══════════════════════════════════════════════════════════════════╝",
          "",
        );
        console.warn(lines.join("\n"));
      }
      // #350: the untracked-WIP inventory (docs/plans/, migrations/, scratch)
      // — makes the #73 dirty-warn's WIP-doc pattern explicit. Bounded: the
      // per-file expansion runs only when the collapsed porcelain shows
      // untracked content (clean hub → zero extra git calls).
      _maybeWarnHubWipInventory(_wipFromPorcelain(porcelain));
    } catch (e) {
      // Degrade silently — this is a non-blocking discipline check
      console.warn("[main-worktree-guard] ⚠️ Hub discipline check failed:", String(e));
    }
  });

  pi.on("tool_call", async (event, _ctx) => {
    const pid = process.pid;

    // M1 runs on EVERY tool_call (read included — a reviewer whose tree moved
    // mid-review sees the warn before proceeding, AC8). Active under the
    // marker/flag AND in print mode (swarm-style detection, scenario 4).
    if (pendingBaseline.has(pid)) {
      pendingBaseline.delete(pid);
      _recordBaseline(pid); // BEFORE this tool_call's guard evaluation
    }
    _m1(pid);

    const isWrite = isToolCallEventType("write", event);
    const isEdit = isToolCallEventType("edit", event);
    const isBash = isToolCallEventType("bash", event);
    if (!isWrite && !isEdit && !isBash) {
      return undefined;
    }

    // ── M4: hub-state gate + script-backdoor closure (#1484) ──
    // Runs BEFORE the marker/flag bypass: M4 stays ACTIVE under the TTL marker
    // (D3 — a stranded lane recovers with the marker but cannot resume feature
    // work in the hub); only the env flag disables it. Read-only ops, worktree
    // sessions, and agent-infra stay exempt.
    if (!_isAllowMainEdits()) {
      if (isBash) {
        const command = (event.input as { command?: string }).command ?? "";
        // #347: execution-cwd-aware backdoor (script path + content gating
        // resolve against the command's cd-target, not the session cwd).
        const execCwd = commandExecutionCwd(command, process.cwd()) ?? undefined;
        const backdoor = _backdoorBlock(command, execCwd);
        if (backdoor) return { block: true, reason: backdoor };
        const st = _hubState();
        if (st.disorder) {
          // #437 (C): bash writes to TRACKED hub files while the hub is
          // disordered — the dirty-hub inflow closure (the write/edit gate
          // already freezes overwrites; this mirrors it for the bash route).
          // Runs BEFORE the git gate so a command whose git verbs are
          // read-only but whose redirects overwrite a tracked hub file (the
          // manual `git show HEAD:x > x` revert trick) is still blocked —
          // the sanctioned path is hub-worktree.sh salvage (#435).
          const bashWrite = _hubBashTrackedWrite(command, execCwd);
          if (bashWrite) return { block: true, reason: _hubBashWriteBlockReason(bashWrite) };
          // #347: per-invocation target resolution — git ops whose effective
          // target is an isolated worktree are exempt from hub disorder; every
          // other invocation (hub, foreign, unresolvable) keeps today's block.
          // #436 (B): branch ref-delete carve-out needs the checked-out-anywhere
          // set (hub + worktrees) — mirrors the degradation path semantics.
          const checkedOutNames = new Set<string>();
          try {
            for (const branchRef of getWorktreeBranches().keys()) {
              const short = branchRef.replace(/^refs\/heads\//, "");
              if (short && short !== branchRef) checkedOutNames.add(short);
            }
          } catch { /* empty set → only the hub's current branch protects */ }
          if (st.branch) checkedOutNames.add(st.branch);
          const gate = evaluateHubGateWithTargets(command, st.branch, resolve(process.cwd()), checkedOutNames);
          if (gate.exempted) {
            // #347 code-review: audit worktree exemptions — a deliberate gate
            // relaxation must be observable (the 2026-08-18 incident was a
            // silent gate failure).
            try {
              appendJsonl({
                event: "m4_worktree_exemption",
                extension: "main-worktree-guard",
                command: command.slice(0, 300),
                session_id: _currentSessionId(_ctx),
              });
            } catch { /* audit is best-effort — never blocks */ }
          }
          if (gate.verdict === "block") {
            return { block: true, reason: gate.reason ?? "" };
          }
          if (gate.verdict === "recovery" || gate.verdict === "allowed") {
            return undefined; // sanctioned recovery / read-only / worktree-isolated — done
          }
        }
      } else if (isWrite || isEdit) {
        // #347: the M4 disorder block is TARGET-AWARE (hub-equality) — only
        // HUB-targeted writes are blocked while the hub is disordered;
        // worktree/foreign//tmp targets are isolated (writes never mutate git
        // refs) and fall through to the marker bypass + downstream gate. D3
        // preserved: this block still runs BEFORE the marker bypass, so an
        // active TTL marker cannot write into the hub.
        const targetPath = (event.input as { path?: string }).path ?? "";
        const st = _hubState();
        if (st.disorder) {
          const targetTop = resolveTargetTopLevel(targetPath);
          const mainTop = _mainTopLevel();
          if (targetTop && targetTop === mainTop) {
            // #436 (B carve-out): a NEW-FILE write to a path outside the dirty
            // set / sibling untracked dirs is collision-free — allow it so
            // hub-resident sessions stop being forced to /tmp for legit new
            // docs (the API-keys-session friction, tortoise #2238). Overwrites
            // stay blocked. D3 preserved: the marker bypass does not re-enable
            // overwrites (this block still runs before the marker check).
            if (_hubNewFileWriteAllowed(targetPath)) {
              return undefined; // new-file write — collision-free by construction
            }
            return {
              block: true,
              reason: [
                `⛔ File edits blocked — the shared main checkout is OFF-MAIN or DIRTY (#1484).`,
                `   The hub's only legal states are main+clean. Non-recovery edits are`,
                `   blocked even under the TTL marker (D3).`,
                `   → Recover first: cd <repo> && git checkout main && git pull --ff-only`,
                `   → Do feature work in a worktree: bash scripts/checkout-hygiene/hub-worktree.sh <branch>`,
              ].join("\n"),
            };
          }
        }
      }
    }

    // ── bash: branch-ownership + destructive git ──
    // Marker OR branch covers bash + write + edit in one check point (#266).
    if (_isAllowMainEdits() || readAllowMarkerState(_markerPath(), _currentSessionId(_ctx))) {
      return undefined;
    }
    if (isBash) {
      const command = (event.input as { command?: string }).command ?? "";
      // #350: hub-WIP discipline prompts (never block) — bash-write detection
      // (heredoc/tee/python into the hub) + the throttled periodic hub-hygiene
      // scan (once per 5 min — never per-command).
      _maybeWarnBashWrite(command);
      _periodicHubHygieneCheck();

      // ── Degradation fallback (branch-ownership OR detailed classifier
      // unavailable): behave exactly like today — agent-infra exempt,
      // string-verdict destructive blocks for non-infra main, marker bypass. ──
      if (!branchOwnership || !classifierLoaded) {
        if (isAgentInfraRepo()) return undefined;
        if (_isAllowMainEdits()) return undefined;
        const verdict = classifyGitCommand(command);
        // #443 clean-hub parity: the FROZEN legacy classifier reports
        // `block:push-delete` for the exact `--delete`/`:branch` spellings
        // only, so the documented `-d` short form and `--del`-style
        // abbreviations classify "allow" and used to skip the #73
        // sibling-checked-out block below. `extractPushDeleteBranch` is now
        // whole-command and spelling-aware (all `-d`/`--del`/cluster forms,
        // multi-segment compounds, `-o` value consumption) — it is the single
        // target source here, exactly as the pre-#443 arm consumed it. The
        // detailed classifier is deliberately NOT consulted: its pushTargets
        // describe only the FIRST push invocation, so a raw `--delete` verdict
        // originating from a later segment would mis-attribute phantoms (e.g.
        // `git push origin main && git push origin --delete b` — "main" is not
        // a delete target; cycle-4 review). Gate the extra arm to legacy
        // NON-block verdicts ONLY: a legacy `block:*` (reset/clean/pull/…) must
        // keep its existing generic block below — an unrelated legacy block
        // must never be swallowed by the coordinated-delete arm's
        // allow-when-no-sibling-checkout return.
        const rawDeleteNames = extractPushDeleteBranch(command) ?? [];
        // `allow-non-git` is intentionally absent: a non-empty extractor
        // requires a literal `git push` token, so the legacy verdict for any
        // such command is `allow` or a `block:*` — never `allow-non-git`.
        if (verdict === "block:push-delete" ||
            (verdict === "allow" && rawDeleteNames.length > 0)) {
          const blocked = _coordinatedDeleteBlock(rawDeleteNames);
          if (blocked) return blocked;
          return undefined;
        }
        if (verdict.startsWith("block:")) {
          let inWorktree = true;
          try {
            inWorktree = isWorktreeCwd(resolve(process.cwd()));
          } catch (e) {
            console.warn("[main-worktree-guard] ⚠️ isWorktreeCwd threw — blocking (safe default):", String(e));
            inWorktree = false;
          }
          if (!inWorktree) {
            const kind = verdict.slice("block:".length);
            return {
              block: true,
              reason: [
                `⛔ Destructive git command blocked in the main checkout (${kind}).`,
                ...WHY.split("\n").slice(1),
              ].join("\n"),
            };
          }
        }
        return undefined;
      }

      // ── Full branch-ownership path (#265) ──
      const det = classifyGitCommandDetailed(command);
      // P2 (cycle 3): resolve the effective repo against the STATE-mutating
      // invocation — `git -C <wt> status && git checkout main` must gate on the
      // main checkout, not the worktree the first invocation pointed at.
      const eff = branchOwnership.resolveEffectiveRepo(command, process.cwd(), det.stateVerb ?? det.verb);
      const allowActive = _isAllowMainEdits();

      // M3: branch-state gate — applies in ANY main checkout (resolved,
      // target-aware). Worktree-effective commands are exempt (cycle-4
      // verified: -C <wt> --git-dir=<main>/.git checkout operates on MAIN →
      // eff.isWorktree is false → NOT exempt).
      if (det && det.branchState && !allowActive) {
        // P1-A: classify the STATE-mutating invocation (compound commands like
        // `git pull && git checkout main` must gate on the checkout, not the pull).
        const branchOp = branchOwnership.classifyBranchOp(det.stateVerb ?? det.verb, det.stateArgs ?? det.verbArgs);
        if (branchOp && branchOp.op !== "other") {
          if (!eff) {
            return {
              block: true,
              reason: "⛔ Branch-state command blocked — could not resolve the effective repo (fail-closed; #265).",
            };
          }
          if (!eff.isWorktree) {
            const baseline = baselines.get(pid);
            const isInfra = isAgentInfraRepo(eff.effectiveCwd);
            const m3 = branchOwnership.decideM3({
              branchOp, isAgentInfra: isInfra, baseline,
              currentBranch: eff.currentBranch,
            });
            if (m3?.block) return { block: true, reason: m3.reason };
            if (m3?.reBaseline) {
              // Synchronous re-baseline: the allowed carve-out / own rename
              // adopts the new branch NOW — the next tool_call emits ZERO M1
              // warns (AC3).
              _rebaseline(pid, m3.reBaseline);
              return undefined;
            }
          }
        }
      }

      // Under the escape hatch, M2/M3 are inactive (contract preserved) but M1
      // above stays active. Legacy destructive blocks are also bypassed (today's
      // semantics — the hatch is a full bypass).
      if (allowActive) return undefined;

      // ── Escape marker (#207): stamp + audit at creation-observation ──
      // ORDERING FIX (#1484): the stamp must run BEFORE the allow/allow-non-git
      // early return — a bare `touch <marker>` classifies "allow-non-git" and
      // was silently swallowed by that return, so the guard NEVER stamped and
      // the marker was inert in production (the 2026-08-18 incident's empty
      // unscoped marker file is exactly this bug's evidence). Git classification
      // ran FIRST (M3 above), so a blocked command NEVER stamps — `touch ... &&
      // git checkout main` is blocked and the touch never runs (F10c). Only an
      // ALLOWED bare `touch <marker>` (own command) reaches here.
      if (isAllowMarkerCommand(command, homedir())) {
        _stampMarker(_markerPath(), _currentSessionId(_ctx), extractMarkerReason(command));
        return undefined;
      }

      if (!det || det.verdict === "allow" || det.verdict === "allow-non-git") return undefined;

      // ── Ownership allowance (agent-infra main, own baseline branch) ──
      // Predicate split (plan deviation 7): sync ops (pull/rebase/merge) gate on
      // current-branch == baseline; push/delete/branch -D gate on ALL targets ==
      // baseline (all-targets — a multi-refspec push or mixed delete must never
      // slip a foreign target past the gate).
      const ALLOWANCE: Record<string, string> = {
        "block:pull": "pull",
        "block:merge": "merge",
        "block:rebase": "rebase",
        "block:push": "push",
        "block:force-push": "force-push",
        "block:push-delete": "push-delete",
        "block:branch-force-delete": "branch-force-delete",
      };
      const allowanceKind = ALLOWANCE[det.verdict];
      if (allowanceKind && eff) {
        const baseline = baselines.get(pid);
        const targets = det.pushTargets && det.pushTargets.length > 0
          ? det.pushTargets
          : (det.newBranch ? [det.newBranch] : []);
        if (branchOwnership.ownershipAllowed({
          opKind: allowanceKind,
          currentBranch: eff.currentBranch,
          baselineBranch: baseline?.branch ?? null,
          targets,
          syncSource: det.syncSource,
        })) {
          return undefined;
        }
      }

      // ── push --delete: retained #73 coordinated check (foreign targets) ──
      if (det.verdict === "block:push-delete" && det.pushTargets.length > 0) {
        const worktreeBranches = getWorktreeBranches();
        const blockedBranches: string[] = [];
        for (const branchName of det.pushTargets) {
          const branchRef = `refs/heads/${branchName}`;
          const checkedOutPaths = [...(worktreeBranches.get(branchRef) || [])];
          if (isBranchInMainCheckout(branchName)) {
            const mainTopLevel = _mainTopLevel();
            const mainLabel = mainTopLevel || "main checkout";
            if (!checkedOutPaths.includes(mainLabel)) checkedOutPaths.push(mainLabel);
          }
          if (checkedOutPaths.length > 0) {
            blockedBranches.push(`"${branchName}" — checked out in: ${checkedOutPaths.join(", ")}`);
          }
        }
        if (blockedBranches.length > 0) {
          return {
            block: true,
            reason: [
              `⛔ Cannot delete — the following branches are currently checked out:`,
              ...blockedBranches.map((b: string) => `   • ${b}`),
              "",
              "   Why: deleting a remote branch while another session has it",
              "   checked out destroys that session's upstream (#73 / incident 2026-08-06).",
              "   → Switch those worktrees/main to another branch first, then retry.",
            ].join("\n"),
          };
        }
        return undefined; // foreign deletes with no checked-out targets — allowed (today's behavior)
      }

      // ── M2: commit/push ownership (block off-baseline) ──
      if (det.verdict === "block:commit" || det.verdict === "block:push" || det.verdict === "block:force-push") {
        if (!eff) {
          return {
            block: true,
            reason: "⛔ git commit/push blocked — could not verify repo ownership (git read failed; fail-closed, #265).",
          };
        }
        const baseline = baselines.get(pid);
        const m2 = branchOwnership.decideM2({
          effectiveRepo: eff, baseline, currentBranch: eff.currentBranch,
          pushDst: det.pushDst, pushTargets: det.pushTargets,
          verdict: det.verdict, allowActive: false,
        });
        if (m2?.block) return { block: true, reason: m2.reason };
        return undefined; // on-baseline or unverifiable-but-exempt
      }

      // ── Legacy destructive blocks (main checkout only) ──
      const LEGACY_BLOCK = [
        "block:reset", "block:clean", "block:restore", "block:stash-pop",
        "block:checkout-discard-all", "block:force-checkout", "block:checkout-branch",
        "block:merge", "block:rebase", "block:pull", "block:branch-force-delete",
        "block:force-push",
      ];
      if (LEGACY_BLOCK.includes(det.verdict)) {
        if (eff && eff.isWorktree) return undefined;
        const kind = det.verdict.slice("block:".length);
        return {
          block: true,
          reason: [
            `⛔ Destructive git command blocked in the main checkout (${kind}).`,
            ...WHY.split("\n").slice(1),
          ].join("\n"),
        };
      }
      return undefined;
    }

    // ── write/edit: block edits to the main checkout ──
    // Worktrees are ISOLATED: if the session itself runs in a linked worktree,
    // `git rev-parse --show-toplevel` returns the worktree root for BOTH the
    // session cwd and any target inside it, so the mainTopLevel equality check
    // below would false-positive-block every edit (incident: epic-529 worktree
    // session blocked editing its own isolated worktree). A worktree's working
    // tree is private by construction — allow all edits from a worktree session.
    if (isWorktreeCwdWrite(resolve(process.cwd()))) {
      // #350: a worktree session writing WIP into the HUB via an absolute path
      // is still the #347 amplifier — warn (never block).
      _maybeWarnHubWipWrite((event.input as { path?: string }).path);
      return undefined;
    }

    const targetPath = (event.input as { path?: string }).path;

    // #99 write/edit exemption for the infra repo itself (retained): agent-infra
    // is where infra fixes land; the branch-ownership gates (M1/M2/M3) now cover
    // its bash git surface instead.
    if (isAgentInfraRepo()) {
      // #350: agent-infra is exempt from the write/edit BLOCK (#99), so the WIP
      // warning is the only signal for WIP written straight into the infra hub.
      _maybeWarnHubWipWrite(targetPath);
      return undefined;
    }
    if (_isAllowMainEdits()) {
      return undefined;
    }

    const mainTopLevel = _mainTopLevel();
    if (!mainTopLevel) {
      console.warn("[main-worktree-guard] ⚠️ Git unavailable for main repo — warn, not block");
      console.warn("[main-worktree-guard]   → Create a worktree: invoke the using-git-worktrees skill.");
      return undefined;
    }

    const resolvedTarget = resolve(process.cwd(), targetPath ?? "");

    // P2 (review): the write/edit tool is an UNAUDITED marker-creation path —
    // an agent could `write` a stamped JSON straight to the marker file,
    // bypassing the audited touch->stamp route (no gate_bypass audit event).
    // Force creation through the bash touch path (guard-stamped + audited).
    if (resolvedTarget === resolve(_markerPath())) {
      return {
        block: true,
        reason: [
          "⛔ The escape-marker file must be created via a bash `touch` command,",
          "   not the write/edit tool — the guard stamps {session_id, reason, ts}",
          "   and audits the creation only on the bash route (#207).",
        ].join("\n"),
      };
    }

    // If the target is OUTSIDE the project root, it's not a main-checkout edit — allow.
    const insideProject =
      resolvedTarget === mainTopLevel || resolvedTarget.startsWith(mainTopLevel + "/");
    if (!insideProject) {
      return undefined;
    }

    const targetCwd = targetPath ? dirname(resolvedTarget) : process.cwd();

    // Resolve symlinks to detect nested git repos (#5543)
    let resolvedCwd = targetCwd;
    try {
      if (existsSync(targetCwd)) {
        resolvedCwd = realpathSync(targetCwd);
      }
    } catch { /* keep unresolved if symlink resolution fails */ }

    let topLevel: string;
    try {
      topLevel = execSync("git rev-parse --show-toplevel", {
        encoding: "utf-8", cwd: resolvedCwd, timeout: 5000,
      }).trim();
    } catch {
      console.warn("[main-worktree-guard] ⚠️ Git unavailable for target path — warn, not block");
      console.warn("[main-worktree-guard]   → Target may be a new directory or outside a git repo.");
      return undefined;
    }

    if (topLevel === mainTopLevel) {
      // #350: surface the WIP-pattern violation in the block reason (same block
      // decision — the message now names the amplifier pattern).
      const wipPattern = matchHubWipPattern(targetPath ?? "");
      const wipHint = wipPattern
        ? `   This looks like ${WIP_PATTERN_LABEL[wipPattern] ?? wipPattern} written directly into main — the #347 amplifier; use a worktree.`
        : "";
      return {
        block: true,
        reason: [
          "⛔ File edits in the main checkout are blocked.",
          ...(wipHint ? [wipHint] : []),
          "   Why: Parallel agents editing main could silently overwrite each",
          "   other's uncommitted changes. Each agent needs its own branch.",
          "   → Create a worktree: invoke the using-git-worktrees skill.",
          "   → Or set AGENT_ALLOW_MAIN_EDITS=1 (or ELDATO_ALLOW_MAIN_EDITS=1) to override (solo sessions only).",
        ].join("\n"),
      };
    }

    return undefined;
  });

  // #5672: suppress startup banner in print mode (task sub-agent output)
  if (!isPrintMode()) {
    console.log("[main-worktree-guard] ✅ Loaded — blocking write/edit + destructive git in main checkout");
  }
  // ── Session-start hub discipline check (#73) ──
  // In the main checkout: warn if on a non-main branch or dirty working tree.
  // Non-blocking — the write/edit guard still protects; this is a discipline prompt.
  // Marker parity: an active escape marker also suppresses the warning. Documented
  // limitation: at module load ctx is unavailable, so this degrades to the
  // env-only session id — for interactive sessions where the extension host
  // lacks PI_SESSION_ID the read is false and the warning shows (fail-safe; the
  // per-tool_call check is authoritative).
  if (!isAgentInfraRepo() && !_isAllowMainEdits() && !readAllowMarkerState(_markerPath(), _currentSessionId(undefined))) {
    try {
      const inWorktree = isWorktreeCwd(resolve(process.cwd()));
      if (!inWorktree) {
        const currentBranch = getMainCheckoutBranch();
        // #350: the #73 dirty check stays on collapsed porcelain (fast); the
        // per-file WIP inventory is bounded by _wipFromPorcelain.
        const porcelain = execSync("git status --porcelain=v1", {
          encoding: "utf-8", timeout: 5000,
        }).trim();
        const onNonMain = currentBranch &&
          currentBranch !== "main" && currentBranch !== "master";
        const dirty = porcelain.length > 0;
        if (onNonMain || dirty) {
          const issues: string[] = [];
          if (onNonMain) issues.push(`on branch "${currentBranch}" (not main/master)`);
          if (dirty) issues.push("working tree is dirty (uncommitted changes or untracked files)");
          const lines = [
            "",
            "╔══════════════════════════════════════════════════════════════════╗",
            "║  ⚠️  MAIN CHECKOUT — HUB DISCIPLINE WARNING                      ║",
            "╠══════════════════════════════════════════════════════════════════╣",
          ];
          for (const issue of issues) {
            lines.push(`║  ${issue.padEnd(62)}║`);
          }
          const nudge: string[] = [];
          // #437 (C): routing nudge — the concrete one-liner beats the generic
          // skill pointer. Width-safe for the 62-char banner box; the helper
          // lives in agent-infra (scripts/checkout-hygiene/) and takes
          // <branch> or the salvage subcommand (#435) for dirty-on-main.
          nudge.push("Feature work should happen in isolated worktrees.");
          nudge.push("→ using-git-worktrees skill, or hub-worktree.sh <branch>");
          nudge.push("   (helper: agent-infra scripts/checkout-hygiene/)");
          if (dirty && !onNonMain) {
            // dirty-on-main: the deadlock state (#2238) — capture the set first.
            nudge.push("→ dirty-on-main: hub-worktree.sh salvage <branch> first");
          }
          for (const n of nudge) {
            lines.push(`║  ${n.padEnd(62)}║`);
          }
          lines.push(
            "║  → Invoke the using-git-worktrees skill to create one.            ║",
            "║  → Set AGENT_ALLOW_MAIN_EDITS=1 to suppress this warning.         ║",
            "╚══════════════════════════════════════════════════════════════════╝",
            "",
          );
          console.warn(lines.join("\n"));
        }
        // #350: the untracked-WIP inventory (path-deduped against the
        // session_start run — whichever fires first warns).
        _maybeWarnHubWipInventory(_wipFromPorcelain(porcelain));
      }
    } catch (e) {
      // Degrade silently — this is a non-blocking discipline check
      console.warn("[main-worktree-guard] ⚠️ Hub discipline check failed:", String(e));
    }
  }
}
