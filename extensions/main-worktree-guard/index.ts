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
//     checkout — the #347 amplifier. Three surfaces: (a) the write/edit gate
//     BLOCKS hub-targeted main-checkout edits (agent-infra included, #615) and
//     warns on WORKTREE-session absolute-path writes into the hub matching the
//     WIP patterns; (b) bash-write detection warns on hub-targeted heredoc/tee/
//     python open() writes (heuristic, never blocks); (c) the session-start
//     hub-discipline check gains an untracked-WIP inventory (docs/plans/,
//     migrations/, scratch) + a throttled (5 min) periodic re-scan. All
//     warnings dedupe per pattern/path and are suppressed under the env hatch.
//  7. (#618/#621) TARGET-AWARE HUB-WRITE GATING: the write/edit gate and the
//     tracked-file bash gate resolve the WRITE TARGET's repo checkout, not the
//     session cwd. A tracked-file write into ANY repo's MAIN checkout is gated
//     wherever the session sits — worktree sessions (were exempt via the
//     epic-529 early-return), foreign/non-git cwds (were invisible to
//     readHubDisorder / _mainTopLevel), and other repos' sessions
//     (agent-infra-rooted controllers writing tortoise/premise-labs main after
//     the #615 removal). The bash gate runs for EVERY command (a clean
//     main-rooted session writing another hub via bash is gated too — review
//     fold-in); same-vs-cross-checkout is judged by the SESSION's checkout,
//     never a command `cd`-site; cross-checkout tracked AND `.git/`-metadata
//     writes block regardless of hub state. Cycle-2 fold-ins: main checkouts
//     NESTED under the session's own checkout tree (submodules / vendored /
//     private copies) are not shared hubs and are not frozen; `.git/`-metadata
//     writes freeze in every state except a same-rooted CLEAN main (never a
//     build side-effect); a TTL marker bypasses the cross-checkout bash gate
//     exactly like the write/edit route (M4 D3's disordered-own-hub freeze
//     stays); the write/edit gate also blocks cross-cwd overwrites of EXISTING
//     untracked hub files (another session's hub WIP) — only genuinely NEW
//     files are additive. Worktree sessions still write
//     their OWN worktree freely — its targets resolve to that worktree's
//     checkout, never a main checkout. Main-ness and worktree-ness are judged
//     STRUCTURALLY (gitdir vs commondir realpaths — the path-substring test
//     misread a main checkout under a `worktrees/` directory as a linked
//     worktree). Env hatch + TTL marker bypass the clean-hub write gate; M4's
//     disordered-hub freeze stays active under the marker.
//
// Worktrees are ISOLATED — none of this applies inside a worktree. The only
// escape hatches are AGENT_ALLOW_MAIN_EDITS=1 (or ELDATO_ALLOW_MAIN_EDITS=1,
// the env hatch set at session start) and the TTL'd file marker (#207), both
// for deliberate solo sessions. Their M-gate effects DIFFER: under the ENV
// hatch M2/M3/M4 are all inactive (the M4 hub-state block is wrapped in
// `if (!_isAllowMainEdits())`) and M1 detection stays ACTIVE; under the TTL
// MARKER only M2/M3 are inactive while M4 stays ACTIVE (D3 — a stranded lane
// recovers with the marker but cannot resume feature work in the hub). There
// is NO auto-bypass: the guard blocks every time, so a rogue/parallel agent
// cannot retry its way past it.
//
// Degradation contract:
//  - classify-git.mjs load failure → bash git guard degrades to warn-only
//    (fail-safe, never false-blocks) while the write/edit guard stays fully
//    enforced.
//  - branch-ownership.mjs load failure → M1/M2/M3 are OFF (one-time warn) and
//    the guard falls back to the frozen-legacy classifier for EVERY repo — no
//    agent-infra exemption (#615); write/edit never depends on either module.
//  - isWorktreeCwd defaults are SPLIT: the bash path fails OPEN (() => true —
//    a worktree lookalike is treated as isolated), the write/edit path fails
//    CLOSED (() => false — an unverifiable target is treated as main and
//    blocked). This fixes the latent fail-open at the old shared default.
// The TTL'd file-based escape marker (~/.pi/agent/.allow-main-edits, #207)
// allows a deliberate mid-session escalation — see README.md.

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { isToolCallEventType } from "@earendil-works/pi-coding-agent";
import { execSync } from "node:child_process";
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
let wholeCommandDeleteTargets: (verdict: string, command: string) => string[] = () => [];
let getWorktreeBranches: () => Map<string, string[]> = () => new Map();
let isBranchInMainCheckout: (branch: string) => boolean = () => false;
let getMainCheckoutBranch: () => string | null = () => null;
let isAgentInfraRepo: (cwd?: string, env?: Record<string, string | undefined>) => boolean = () => false;
// #1484 M4 hub-state gate + script-backdoor closure. Fail-safe defaults: every
// decision degrades to inactive/allow so a failed import NEVER false-blocks
// (the git commands were allow-listed before M4; the guard stays permissive).
let readHubDisorder: (cwd: string, opts?: { skipWorktree?: boolean }) => { disorder: string | null; branch: string | null } = () => ({ disorder: null, branch: null });
let evaluateHubGateWithTargets: (command: string, currentBranch: string | null, sessionCwd?: string, checkedOutBranches?: Set<string> | null) => { verdict: "non-git" | "allowed" | "recovery" | "block"; reason?: string; exempted?: boolean } = () => ({ verdict: "non-git" });
let commandExecutionCwd: (command: string, sessionCwd?: string) => string | null = () => null;
let resolveTargetTopLevel: (targetPath: string, cwd?: string) => string | null = () => null;
// #618/#621: TARGET-aware checkout classification (the shared mechanism both
// hub-write issues consume). Fail-safe defaults: inert (null/[]) so a failed
// import NEVER false-blocks — the write gates degrade to today's behavior.
let resolveTargetCheckout: (targetPath: string, cwd?: string) => { top: string; isMain: boolean } | null = () => null;
let trackedRelsIn: (repoTop: string, rels: string[]) => string[] = () => [];
let hasDotGitAncestor: (p: string) => boolean = () => false;
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
let bashWriteTargetsResolved: (command: string, cwd?: string) => ({ resolvedPath: string; via: string; site: string; cwd: string; scriptToks?: { path: string; cwd: string }[] })[] = () => [];
// #437 (C): bash-write gate for TRACKED hub files in a DISORDERED hub (pure
// intersect of bash-write candidates with index-tracked rels). Fail-safe
// default: inert (null) — a failed import NEVER false-blocks (same contract
// as the #350 warn helpers; the gate is opt-in by explicit call only).
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
     extractPushDeleteBranch, wholeCommandDeleteTargets, getWorktreeBranches, isBranchInMainCheckout,
     getMainCheckoutBranch, isAgentInfraRepo, ALLOW_MAIN_EDITS_MARKER_TTL_MS,
     isAllowMarkerActive, isAllowMarkerPath, isAllowMarkerCommand,
     extractMarkerReason, parseMarkerContent, isAllowMarkerRealpath,
     readAllowMarkerState, readHubDisorder,
     extractScriptPath, scriptGitVerdict, evaluateHubGateWithTargets,
     commandExecutionCwd, resolveTargetTopLevel, matchHubWipPattern,
     extractBashWriteTargets, classifyUntrackedWip, branchDeleteAllowance, newFileWriteCollisionFree,
     bashWriteTargetsResolved, resolveTargetCheckout, trackedRelsIn, hasDotGitAncestor } =
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
      "   checked out destroys that session's upstream (#73 / incident 2026-08-06).",
      "   → Switch those worktrees/main to another branch first, then retry.",
      "   → Or set AGENT_ALLOW_MAIN_EDITS=1 (or ELDATO_ALLOW_MAIN_EDITS=1) to override.",
    ].join("\n"),
  };
}

// ── M4: hub-state gate (#1484) ─────────────────────────────────────────────
// The hub's only legal states are main+clean. When the session cwd IS the hub
// main checkout (agent-infra included since #615) and the hub is off-main or
// dirty, every git op is
// gated by the recovery allowlist (classify-git evaluateHubGateWithTargets) and
// write/edit in the hub is blocked. #347: each git invocation's EFFECTIVE
// target is resolved — invocations targeting an isolated worktree (worktree-
// list membership + cwd containment) are exempt from hub disorder; the
// write/edit M4 block gates only HUB-targeted writes (hub-equality); the script
// backdoor resolves against the command's execution cwd. M4 stays ACTIVE under
// the TTL marker (D3 — mirrors M1's detect-stays-active contract): a stranded
// lane can recover with the marker but cannot resume feature work in the hub.
// Only AGENT_ALLOW_MAIN_EDITS=1 (env, session start) is a full bypass. Worktree
// sessions are exempt (D5 — isolated by construction). Agent-infra is NOT
// exempt: the #99 carve-out is removed (#615) — its main checkout gets the
// same M4 discipline as every other hub.
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
// either via the write/edit tool (agent-infra included in the block since
// #615) or via bash heredoc/tee/python (unguarded). All three surfaces below
// WARN — never block: the write/edit block for main-checkout edits is
// unchanged; these are discipline prompts surfacing the violation at write time.
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

// ── #618/#621: target-aware checkout resolution (the shared mechanism) ─────
// resolveTargetCheckout (classify-git) classifies the checkout CONTAINING a
// path: git toplevel + MAIN-checkout vs linked-worktree (git-dir under
// .git/worktrees/). Both the write/edit gate and the bash tracked-write gate
// resolve each TARGET here instead of trusting the session cwd. Cost control:
// one git call per DISTINCT realpath-normalized path, cached per session.
// Positive results are sticky (a checkout's repo-ness and main-ness are
// stable within a session); NULL results (non-git paths) get the negative-TTL
// re-check (MAIN_TOP_RETRY_MS) so a mid-session `git init` cannot leave the
// gate blind forever. Bounded (TARGET_CHECKOUT_CACHE_MAX — oldest evicted).
const TARGET_CHECKOUT_CACHE_MAX = 1024;
const targetCheckoutCache = new Map<string, { top: string; isMain: boolean } | null>();
const targetCheckoutNullAt = new Map<string, number>();
function _checkoutOf(p: string): { top: string; isMain: boolean } | null {
  try {
    const key = _realpathNearest(resolve(p));
    const hit = targetCheckoutCache.get(key);
    if (hit !== undefined) {
      if (hit !== null) return hit;
      const at = targetCheckoutNullAt.get(key) ?? 0;
      if (Date.now() - at < MAIN_TOP_RETRY_MS) return null; // negative-TTL
      targetCheckoutCache.delete(key);
      targetCheckoutNullAt.delete(key);
    }
    let r: { top: string; isMain: boolean } | null = null;
    try { r = resolveTargetCheckout(key); } catch { r = null; }
    if (targetCheckoutCache.size >= TARGET_CHECKOUT_CACHE_MAX) {
      // Bound enforced on EVERY insert (positive entries included — the old
      // null-only eviction let positive keys grow past the cap unboundedly
      // on a many-file batch; oldest-evicted is fine — a re-request just
      // re-resolves, and positive stickiness only matters under the cap).
      const oldest = targetCheckoutCache.keys().next().value as string | undefined;
      if (oldest !== undefined) { targetCheckoutCache.delete(oldest); targetCheckoutNullAt.delete(oldest); }
    }
    targetCheckoutCache.set(key, r);
    if (r === null) targetCheckoutNullAt.set(key, Date.now());
    return r;
  } catch {
    return null; // never false-block on resolution failure
  }
}

// Is the realpath-normalized target path an INDEX-TRACKED file in its repo?
// ONE bounded `git ls-files --error-unmatch` — only reached for candidates
// already classified as lying in a hub MAIN checkout (the gate's tracked
// intersect; never on the general hot path).
function _targetTrackedAt(top: string, tgtReal: string): boolean {
  try {
    if (!tgtReal.startsWith(top + "/")) return false;
    const rel = tgtReal.slice(top.length + 1);
    if (!rel) return false;
    return trackedRelsIn(top, [rel]).length > 0;
  } catch {
    return false; // fail-safe — never false-block on git/parse errors
  }
}

// Cycle-2 F4-a: a hub whose `.git` is a SYMLINK to an external gitdir loses
// its `.git` path segment once realpath'd — the realpath-based classify then
// finds no checkout (the external gitdir's ancestors are not a work tree) and
// the target looks "outside any git repo". Test the UNREALPATH'd SPELLING
// too (cheap `.git`-segment gate first, then a RAW resolveTargetCheckout —
// never the realpath cache, which would destroy the segment). Returns the
// owning MAIN + the .git-metadata rel (exact ".git" pointer or ".git/…"),
// or null.
function _gitMetaSpellingTop(rawAbs: string): { top: string; rel: string } | null {
  try {
    if (!hasDotGitAncestor(rawAbs)) return null;
    const ck = resolveTargetCheckout(rawAbs);
    if (!ck || !ck.isMain) return null;
    const rel = rawAbs.startsWith(ck.top + "/")
      ? rawAbs.slice(ck.top.length).replace(/^[/\\]+/, "")
      : "";
    if (!rel || (rel !== ".git" && !rel.startsWith(".git/"))) return null;
    return { top: ck.top, rel };
  } catch {
    return null;
  }
}

// #618/#621: the write/edit block reason for a cross-cwd write into a hub
// MAIN checkout (the session is NOT rooted in that main — worktree session,
// foreign/non-git cwd, or another repo's session). Names the TARGET repo's
// hub discipline and the sanctioned routes. `.git/`-metadata targets
// (hooks/, config) get the same freeze — they are never index-tracked but
// a cross-cwd write into them is the same deliberate-hub-write vector
// (adversarial-review F4).
function _hubTargetWriteBlockReason(rel: string, top: string, wipHint: string): string {
  const gitMeta = rel === ".git" || rel.startsWith(".git/");
  return [
    `⛔ File write to a hub ${gitMeta ? "git-metadata file" : "tracked file"} blocked (${rel}).`,
    ...(wipHint ? [wipHint] : []),
    `   The target resolves to ${top} — that repo's shared MAIN checkout`,
    `   (#618/#621). Hub writes are gated by the TARGET repo wherever the`,
    `   session sits: worktree, foreign/non-git cwd, and other-repo sessions`,
    `   get the same freeze as a hub-rooted session. Only new-file writes`,
    `   stay allowed (additive/visible); tracked-file and ${gitMeta ? ".git/" : ""}overwrites block.`,
    `   → Work in a worktree of that repo: invoke the using-git-worktrees skill.`,
    `   → Or set AGENT_ALLOW_MAIN_EDITS=1 (or ELDATO_ALLOW_MAIN_EDITS=1) to`,
    `     override (deliberate solo sessions only).`,
  ].join("\n");
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
// #350 write-gate WARNING (never block): a write/edit target inside a hub
// MAIN checkout matching the WIP patterns (docs/plans/, migrations, scratch).
// Pure pattern pre-filter first (cheap), then hub containment against the
// resolved main toplevel (realpath-normalized both sides). `hubTop` is the
// already-resolved MAIN toplevel when the caller has proven target main-ness
// (#618/#621 target-aware gate — avoids re-deriving against the session's own
// cached main, which is wrong for cross-repo targets); when omitted, the
// session's cached main toplevel is used (the pre-#618 own-hub semantics).
// Dedupes per (pattern, path) per session.
function _maybeWarnHubWipWrite(targetPath: string | undefined, hubTop?: string) {
  try {
    if (!targetPath) return;
    if (_isAllowMainEdits()) return;
    const pattern = matchHubWipPattern(targetPath);
    if (!pattern) return;
    const resolved = _realpathNearest(resolve(process.cwd(), targetPath));
    const mainTop = hubTop ?? _cachedMainTopLevel();
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

// #437 (C) + #618/#621: bash-write GATE for TRACKED files in hub MAIN
// checkouts — the root-cause closure for the dirty-hub inflow (session
// 01a05704 wrote tracked hub files via python/heredoc after write/edit tools
// blocked; the #350 bash-write path was warn-only). Since #618/#621 the gate
// is TARGET-aware: each write candidate's CONTAINING CHECKOUT is resolved via
// resolveTargetCheckout (not the session cwd), and hub discipline is applied
// per target. The gate runs for EVERY non-hatched bash command (no
// session-hub-state precondition — a CLEAN main-rooted controller writing
// ANOTHER repo's hub via python/heredoc/tee is the #621 channel too), and the
// per-candidate semantics are:
//   - SAME-checkout — the SESSION's own checkout IS that main (judged by the
//     session cwd's checkout, NEVER by the command's transient cd-site: a
//     worktree/foreign session that `cd`s into a hub and writes is still a
//     deliberate cross-checkout session): #437 semantics — block tracked
//     overwrites ONLY while that main is DISORDERED (build/formatter/
//     npm-install side effects on a clean main must never false-block;
//     tracked-ness is exact via `git ls-files`).
//   - CROSS-checkout — session shell NOT rooted in the target main (a
//     worktree session writing its own repo's main, a foreign/non-git cwd, or
//     another repo's session, incl. a clean agent-infra main): block TRACKED
//     overwrites regardless of hub state, PLUS any write into that main's
//     `.git/` metadata (hooks/, config — never index-tracked, so the tracked
//     intersect cannot see them). These are the vectors behind the 2026-09-08
//     mass `.husky/pre-commit` rewrite from the GitHub parent dir and the
//     wt-session python open() probes into premise-labs/tortoise AGENTS.md.
// NEW-file writes and untracked WIP keep the warn-only treatment (#350 / the
// #436 collision-free carve-out). Script-file content (`bash /tmp/x.sh`) is
// walked with the SAME per-candidate classifier (bounded depth). There is NO
// cheap pre-bail: bashWriteTargetsResolved is a PURE string walk (zero git
// spawns on a write-free command), and the earlier bail fired exactly for
// worktree/foreign sessions (their hub disorder reads null) — letting
// `bash -c '…'` / sudo-tee / spawner-wrapped payloads past the walker
// (adversarial-review F3). Fail-safe: any git/parse error → null (never
// false-block). One bounded `git ls-files` per distinct target top for all
// its candidates.
function _hubBashTrackedWrite(command: string, sessionDisorder: string | null, markerOn: boolean): { resolvedPath: string; rel: string; kind?: "script-depth" } | null {
  try {
    if (!classifierLoaded) return null;
    const base = resolve(process.cwd());
    // cycle-27 P2: the base MUST be the session cwd — bashWriteTargetsResolved
    // applies the command's OWN cd chain from its session base (script tokens
    // carry their site cwd). Passing a pre-consumed execCwd (already cd'd by
    // commandExecutionCwd for the git-side _backdoorBlock) DOUBLE-APPLIED the
    // relative cd (`cd docs && bash x.sh` with a docs/docs/ dir present made
    // x.sh resolve one level too deep → existsSync miss → content never walked).
    const extracted = bashWriteTargetsResolved(command, base);
    const targets = extracted.filter((t) => (t as { resolvedPath?: string }).resolvedPath);
    if (targets.length === 0 && !(extracted as { scriptToks?: unknown[] }).scriptToks?.length) return null;
    // The session's OWN checkout (cached) is the same-vs-cross reference.
    // sameCheckout is TRUE only when the SESSION is rooted in the candidate's
    // main; the candidate's transient command-site cwd (a `cd` into the hub)
    // is deliberately NOT consulted — a `cd` by a foreign/worktree session is
    // still a cross-checkout write (adversarial-review F1: the old site-cwd
    // comparison demoted `cd <hub> && echo x > AGENTS.md` to "same-checkout"
    // and let a clean hub's tracked file be overwritten from any cwd).
    const sessionCheck = _checkoutOf(base);
    const sessionTop = sessionCheck ? sessionCheck.top : null;
    const sessionOwnHub = sessionCheck && sessionCheck.isMain ? sessionCheck.top : null;
    const grouped = new Map<string, { tPath: string; rel: string }[]>();
    let gitInternalHit: { resolvedPath: string; rel: string } | null = null; // a hub-main .git-metadata write (hooks/config/pointer)
    // Classify ONE write candidate (top-level write or script-content write):
    // resolve its containing checkout; skip non-main (worktree/non-git)
    // targets and any main checkout NESTED under the session's own tree (a
    // private repo / submodule / vendored copy the session owns — not a
    // shared-hub write; cycle-2 correctness F1b); same-checkout candidates
    // gate only on the SESSION's hub disorder (== that main's — the session IS
    // rooted there); cross-checkout candidates (session shell NOT rooted in
    // the target main) are deliberate hub writes — any tracked target blocks,
    // and so does any `.git/`-metadata target (never index-tracked — must
    // still freeze). Under an active TTL marker the gate keeps ONLY M4 D3's
    // disordered-OWN-hub freeze (parity with the write/edit route, whose #618
    // gate the marker return precedes; cycle-2 P2). Candidates that pass are
    // grouped per top so the tracked query stays ONE bounded `git ls-files`.
    const classify = (t: { resolvedPath?: string; cwd?: string }) => {
      const tPath = t.resolvedPath;
      if (!tPath) return;
      const tReal = _realpathNearest(tPath);
      const ck = _checkoutOf(tReal);
      if (!ck || !ck.isMain) {
        // Symlinked/external-gitdir spelling: realpath resolved a symlinked
        // `.git` dir to an EXTERNAL gitdir whose ancestors are no work tree,
        // so the realpath classify found nothing — but the SPELLING
        // (`<hub>/.git/hooks/pre-commit`) still carries the `.git` segment and
        // classifies to the owning main (cycle-2 F4-a). Test it before
        // declaring the target isolated.
        const meta = _gitMetaSpellingTop(tPath);
        if (meta) { gitInternalHit = { resolvedPath: tPath, rel: meta.rel }; }
        return;
      }
      const rel = tReal.slice(ck.top.length).replace(/^[/\\]+/, "");
      if (!rel || tReal === ck.top) return;
      // A main checkout strictly NESTED under the session's own checkout tree
      // is the session's private working subtree (never a shared hub whose
      // other sessions sit elsewhere) — the cross-checkout freeze does not
      // reach inside the session's own tree (cycle-2 correctness F1b).
      if (sessionTop && sessionTop !== ck.top && ck.top.startsWith(sessionTop + "/")) {
        return;
      }
      const sameCheckout = sessionOwnHub !== null && sessionOwnHub === ck.top;
      // .git-metadata rel (exact ".git" pointer file OR ".git/..." internals):
      // never index-tracked and never a build side-effect — a same-rooted
      // CLEAN main is #437-open, every other geometry (cross-checkout any
      // state, disordered own main — incl. under a TTL marker via M4 D3)
      // blocks, mirroring the write/edit tool's freeze of the same spelling
      // (cycle-2 F4 rel-exact + P1).
      const gitMeta = rel === ".git" || rel.startsWith(".git/");
      if (markerOn) {
        if (!sameCheckout) return; // marker bypasses the #618 cross gate (tool parity)
        if (sessionDisorder === null) return; // clean own main under the marker — open recovery window
        if (gitMeta) { gitInternalHit = { resolvedPath: tPath, rel }; return; } // M4 D3 freeze
      } else if (gitMeta) {
        gitInternalHit = { resolvedPath: tPath, rel };
        return;
      } else if (sameCheckout) {
        if (sessionDisorder === null) return; // clean same-checkout main — documented residual (#437)
      }
      // reached → disordered-same-checkout OR deliberate cross-checkout: the
      // tracked test decides.
      const arr = grouped.get(ck.top) ?? [];
      arr.push({ tPath, rel });
      grouped.set(ck.top, arr);
    };
    for (const t of targets) classify(t as { resolvedPath?: string; cwd?: string });
    // Script-file content (`bash /tmp/x.sh` / `source f` / `. f`): resolve +
    // read (<=64KB) and run the same walker over the script body — its
    // redirects/tee/python run in the SCRIPT's own process against the caller's
    // cwd (git-side scriptGitVerdict reads the same way; bounded read,
    // fail-open on error). cycle-21 P2-3: NESTED script/source chains
    // (wrapper.sh sources lib.sh) are followed to a bounded depth.
    const scriptToks = (extracted as { scriptToks?: { path: string; cwd: string }[] }).scriptToks ?? [];
    const seenScripts = new Set<string>();
    const pendingScripts = scriptToks.slice();
    // 64-iteration budget (was 8): a fan-out of sourced helpers is common, and
    // a chain deeper than the budget is unverifiable — cycle-2 P2 hardened the
    // old depth-8 exhaustion (a write at depth ≥9 was never walked) to FAIL
    // CLOSED (mirror the git-side _unverifiableGitContent doctrine) instead of
    // silently letting a deep chain's hub write through.
    let depthBudget = 64;
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
          classify(inner as { resolvedPath?: string; cwd?: string });
        }
        for (const nested of (innerR as { scriptToks?: { path: string; cwd: string }[] }).scriptToks ?? []) {
          pendingScripts.push(nested);
        }
      } catch { /* never false-block */ }
    }
    if (gitInternalHit) return gitInternalHit;
    if (pendingScripts.length > 0) {
      // Budget exhausted with script tokens still unprocessed — their write
      // content is UNVERIFIABLE. Fail closed (the git-side script gate does
      // the same for unreadable content): a >64-level script chain is
      // pathological/obfuscated; blocking beats silently letting its hub
      // write through (cycle-2 P2).
      return { resolvedPath: base, rel: "script-chain", kind: "script-depth" };
    }
    if (grouped.size === 0) return null;
    // ONE bounded index query per DISTINCT target top: `git ls-files
    // --error-unmatch` prints exactly the TRACKED rels (exit≠0 when any path
    // is untracked — stdout still carries the tracked matches).
    for (const [top, recs] of grouped) {
      const rels = [...new Set(recs.map((r) => r.rel))];
      const tracked = new Set(trackedRelsIn(top, rels));
      for (const r of recs) if (tracked.has(r.rel)) return { resolvedPath: r.tPath, rel: r.rel };
    }
    return null;
  } catch {
    return null; // never false-block
  }
}

// #437 (C) + #618/#621: the block reason for a tracked-hub bash write — states
// the coherent rule (bash writes respect the same hub gate as the write/edit
// tools, resolved against the WRITE TARGET's repo — a DELIBERATE cross-
// checkout write into any hub main freezes regardless of hub state, a session
// shell rooted in a disordered main freezes on tracked overwrites, and a
// cross-checkout write into a hub's `.git/` metadata freezes too; only
// session-start host env bypasses; a mid-command `export` cannot) plus the
// sanctioned ways forward (salvage / worktree).
function _hubBashWriteBlockReason(hit: { resolvedPath: string; rel: string; kind?: "script-depth" }): string {
  if (hit.kind === "script-depth") {
    return [
      "⛔ Bash script execution blocked — script chain exceeds the verify budget.",
      `   A script/source chain deeper than the guard's walk budget was detected;`,
      `   its writes into hub-main checkouts are UNVERIFIABLE and the guard fails`,
      `   closed rather than risk a tracked hub file write (cycle-2 P2).`, 
      `   → Run the shell commands directly (in a worktree), or flatten the chain.`,
      `   → Or set AGENT_ALLOW_MAIN_EDITS=1 (or ELDATO_ALLOW_MAIN_EDITS=1) to`,
      `     override (deliberate solo sessions only).`,
    ].join("\n");
  }
  const gitMeta = hit.rel === ".git" || hit.rel.startsWith(".git/");
  return [
    `⛔ Bash write to a hub ${gitMeta ? "git-metadata file" : "tracked file"} blocked (${hit.rel}).`,
    `   The write target's repo is a shared MAIN checkout (#618/#621) — bash`,
    `   write primitives respect the SAME gate as the write/edit tools: a`,
    `   DELIBERATE cross-checkout write (your session is not rooted in that`,
    `   repo) freezes regardless of hub state, a session rooted in a`,
    `   DISORDERED main freezes on tracked overwrites, and hub .git-metadata`,
    `   writes (hooks/, config) freeze in every state but a same-rooted clean main.`,
    `   Untracked/new-file writes stay allowed. Only session-start host env`,
    `   (AGENT_ALLOW_MAIN_EDITS=1) bypasses — a mid-command export cannot.`,
    `   → Work in a worktree of the TARGET repo (using-git-worktrees skill,`,
    `     or bash scripts/checkout-hygiene/hub-worktree.sh <branch>).`,
    `   → Or set AGENT_ALLOW_MAIN_EDITS=1 (or ELDATO_ALLOW_MAIN_EDITS=1) to`,
    `     override (deliberate solo sessions only).`,
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
// carries no sessionId). Baseline = { repoKey, branch, head, original } of the
// shared MAIN checkout at session_start. M1 dedupe: Set of "from→to" deviations.
// `original` = the branch recorded at an UNCONTENDED session_start and is
// IMMUTABLE — create-new/rename re-baselines update only `.branch` (#376: the
// ceremony return-to-main carve-out switches back to `original`, provably the
// session's own starting state). A lock-contended start (pendingBaseline →
// first-tool_call record) sets original null → the #376 carve-out fails closed
// (the tree may already sit on ANOTHER session's branch — not provably own).
const baselines = new Map<number, { repoKey: string; branch: string | null; head: string; original: string | null }>();
const warnedDeviations = new Map<number, Set<string>>();
const pendingBaseline = new Set<number>(); // lock contended at session_start → record on first tool_call
// Branches THIS pid created via the M3 create-new/rename carve-outs, scoped by
// repoKey (#376 review fold-in): their LOCAL deletion stays allowed after the
// ceremony return re-bases the baseline to main (git refuses deleting a branch
// checked out anywhere, so a pid-owned local delete is collision-free). Scoped
// per repo and marked only in the BASELINE repo, so an owned name from one
// agent-infra checkout can never authorize a delete in another (review fold-in).
// Never seeded from session state.
const ownedBranches = new Map<number, Map<string, Set<string>>>();

function _markOwned(pid: number, repoKey: string | null | undefined, branch: string) {
  if (!repoKey || !branch) return;
  let byRepo = ownedBranches.get(pid);
  if (!byRepo) { byRepo = new Map(); ownedBranches.set(pid, byRepo); }
  let set = byRepo.get(repoKey);
  if (!set) { set = new Set(); byRepo.set(repoKey, set); }
  set.add(branch);
}

function _recordBaseline(pid: number) {
  if (!branchOwnership) return;
  try {
    const cwd = resolve(process.cwd());
    const state = branchOwnership.readBranchState(cwd);
    if (!state) return;
    const key = branchOwnership.repoKey(cwd);
    if (!key) return;
    if (!baselines.has(pid)) {
      // Contended-start fallback (pendingBaseline): the tree may already sit on
      // another session's branch → do NOT claim an original (#376 review fold-in:
      // the carve-out needs a provable own start, so it fails closed here).
      baselines.set(pid, { repoKey: key, branch: state.branch, head: state.head, original: null });
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
                baselines.set(pid, { repoKey: key, branch: state.branch, head: state.head, original: state.branch });
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

      // #615: the downgraded agent-infra branch is REMOVED — agent-infra gets
      // the same hub-discipline warn as every other repo (main+clean is the
      // hub's only legal state; shared-state edits land via worktrees).
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
    // work in the hub); only the env flag disables it. Read-only ops and
    // worktree sessions stay exempt — agent-infra is NOT exempt (#615).
    if (!_isAllowMainEdits()) {
      if (isBash) {
        const command = (event.input as { command?: string }).command ?? "";
        // #347: execution-cwd-aware backdoor (script path + content gating
        // resolve against the command's cd-target, not the session cwd).
        const execCwd = commandExecutionCwd(command, process.cwd()) ?? undefined;
        const backdoor = _backdoorBlock(command, execCwd);
        if (backdoor) return { block: true, reason: backdoor };
        const st = _hubState();
        // #618/#621: the tracked bash-write gate runs for EVERY non-hatched bash
        // command, resolving each write TARGET's checkout (review fold-in on the
        // caller precondition). A CLEAN main-rooted session (the #621 controller
        // geometry — agent-infra on main+clean) writing another repo's hub via
        // python/heredoc/tee is a deliberate cross-checkout write and must block
        // exactly like the write/edit tool does; the old `st.disorder ||
        // !_sessionIsMainRooted()` guard skipped it because the SESSION's OWN hub
        // was clean. Same-checkout clean-main writes stay free INSIDE the gate
        // (#437's residual — classify returns null), so running unconditionally
        // costs only the pure string walk on write-free commands. Under an active
        // TTL marker only M4 D3's disordered-own-hub freeze remains (parity with
        // the write/edit route, whose #618 gate the marker return precedes — the
        // marker is an audited solo-session recovery hatch, not a license to
        // write other hubs).
        const markerOn = readAllowMarkerState(_markerPath(), _currentSessionId(_ctx));
        const bashWrite = _hubBashTrackedWrite(command, st.disorder, markerOn);
        if (bashWrite) return { block: true, reason: _hubBashWriteBlockReason(bashWrite) };
        if (st.disorder) {
          // #437 (C): bash writes to TRACKED hub files while the hub is
          // disordered — the dirty-hub inflow closure (the write/edit gate
          // already freezes overwrites; this mirrors it for the bash route).
          // Runs BEFORE the git gate so a command whose git verbs are
          // read-only but whose redirects overwrite a tracked hub file (the
          // manual `git show HEAD:x > x` revert trick) is still blocked —
          // the sanctioned path is hub-worktree.sh salvage (#435).
          // (The #618/#621 target-aware tracked-write gate runs ABOVE, for the
          // disordered case too — sessionDisorder is threaded through.)
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
      // unavailable): string-verdict destructive blocks for main, marker
      // bypass. No repo exemption — agent-infra degrades identically (#615). ──
      if (!branchOwnership || !classifierLoaded) {
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
        // The extractor is string-matched, so a command that merely MENTIONS a
        // delete push (`echo git push origin -d b`, comments) is conservatively
        // over-matched — a false-block only when the target is checked out
        // elsewhere; identical safe-direction over-match exists for the frozen
        // `--delete` spelling (DESTRUCTIVE_GIT_PATTERNS echo precedent).
        // A `block:force-push` verdict that ALSO carries a delete spelling
        // (`git push --force origin --delete b` / `-d b` — the force-less twin
        // is caught via the allow path) runs the coordinated check too; when
        // no sibling holds the target, it FALLS THROUGH to the generic block
        // arm below so the main-checkout force-push block is preserved.
        const pushDeleteVerdict = verdict === "block:push-delete" ||
          (verdict === "allow" && rawDeleteNames.length > 0) ||
          (verdict === "block:force-push" && rawDeleteNames.length > 0);
        if (pushDeleteVerdict) {
          const blocked = _coordinatedDeleteBlock(rawDeleteNames);
          if (blocked) return blocked;
          if (verdict === "block:push-delete" || verdict === "allow") return undefined;
          // verdict === block:force-push: fall through to the generic arm.
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
      // #596: stateVerbOccurrence makes the resolution follow the MUTATING
      // branch-state invocation even when it is a LATER compound segment — a
      // benign first segment's hints (-C/--git-dir) must not worktree-exempt a
      // main mutation (or main-gate a worktree-scoped one). Round-3: when the
      // selected mutation is EXTRACTOR-INVISIBLE (stateInvVisible false — an
      // interpreter-inline `sh -c 'git branch …'` payload, a `$VAR`-resolved
      // command word, or an absolute-path git), branch-ownership's tokenizer
      // cannot attribute its hints at all; the payload runs at the shell cwd,
      // so resolve the M3 repo at the SESSION cwd (conservative — the
      // main-checkout gates apply; fail-closed, never a worktree exemption the
      // repo layer cannot verify).
      let eff;
      if (det.stateVerb && det.stateInvVisible === false) {
        eff = branchOwnership.resolveEffectiveRepo("git status", process.cwd());
      } else if (det.stateVerb && det.stateHints) {
        // #596 round-4 (reviewer follow-up): resolve the M3 repo from the
        // CLASSIFIER's own boundary-aware walk of the SELECTED mutating
        // invocation (stateHints = its cdChain/cHints/gitDirHint/vars) instead
        // of replaying the stateVerbOccurrence ordinal through
        // branch-ownership's boundary-less tokenizer. Replay
        // mis-attributions (interpreter-inline / script-file / redirect-
        // operand phantoms, or an interpreter word used as a git ARG whose
        // next token the extractor consumed) landed the ordinal on a DIFFERENT
        // invocation and wrongly worktree-exempted a mutation running at the
        // shell cwd (round-4 reviewer P1 bypass). classify-git's walk is
        // boundary-aware → its hints are the reference truth.
        eff = branchOwnership.resolveRepoFromInv(det.stateHints, process.cwd());
      } else {
        eff = branchOwnership.resolveEffectiveRepo(command, process.cwd(), det.verb, 0);
      }
      const allowActive = _isAllowMainEdits();

      // M3: branch-state gate — applies in ANY main checkout (resolved,
      // target-aware). Worktree-effective commands are exempt (cycle-4
      // verified: -C <wt> --git-dir=<main>/.git checkout operates on MAIN →
      // eff.isWorktree is false → NOT exempt). #596 round-4 (reviewer P1b
      // follow-up): a command is exempt only when EVERY mutating branch-state
      // invocation is worktree-scoped — a leading `-C <wt>` mutation must not
      // blanket-exempt a LATER MAIN mutation in the same compound (round-4
      // spellings like `echo x &> git branch side ; git -C <wt> branch -fq … ;
      // git branch -Mq <foreign>` flipped block→allow when the phantom operand
      // stopped being counted; the phantom-free twin was the same gap). Each
      // main-resolving mutation runs the decideM3 gate; the first
      // block/reBaseline decides.
      if (det && det.branchState && !allowActive) {
        const mutations = (det.stateMutations && det.stateMutations.length > 0)
          ? det.stateMutations
          : [{ verb: det.stateVerb, args: det.stateArgs, invVisible: det.stateInvVisible !== false, hints: det.stateHints }];
        for (const mu of mutations) {
          const branchOp = branchOwnership.classifyBranchOp(mu.verb ?? det.verb, mu.args ?? det.verbArgs);
          if (!branchOp || branchOp.op === "other") continue;
          // Resolve THIS mutation's repo: the classifier's own boundary-aware
          // hints (visible spellings); extractor-invisible spellings
          // (interpreter-inline payloads) execute at the shell cwd → session
          // repo (round-3 stateInvVisible-false policy).
          let muEff = mu.hints
            ? branchOwnership.resolveRepoFromInv(mu.hints, process.cwd())
            : (mu.invVisible === false
              ? branchOwnership.resolveEffectiveRepo("git status", process.cwd())
              : null);
          if (!muEff) {
            return {
              block: true,
              reason: "⛔ Branch-state command blocked — could not resolve the effective repo (fail-closed; #265).",
            };
          }
          if (muEff.isWorktree) continue; // THIS mutation is wt-scoped — exempt
          const baseline = baselines.get(pid);
          const isInfra = isAgentInfraRepo(muEff.effectiveCwd);
          // #598: a forced rename of the session's own baseline onto an
          // EXISTING branch this session does not own clobbers that foreign
          // ref rc 0 — probe whether the rename DST already exists in the
          // repo git will write (tri-state: a failed probe is treated as
          // exists → block — fail-closed). gitDir-anchored so a
          // `--git-dir=<other>` mutation is never checked against the cwd
          // repo's refs. Only the decideM3 rename arm consumes it (the
          // force/create/switch arms key on branch/currentBranch alone).
          const dstExists = (branchOp.op === "rename" && branchOp.to != null)
            ? branchOwnership.localBranchExists(muEff.effectiveCwd, branchOp.to, muEff.gitDir) !== false
            : false;
          const m3 = branchOwnership.decideM3({
            branchOp, isAgentInfra: isInfra, baseline,
            currentBranch: muEff.currentBranch,
            // #376 review fold-in: the return-to-original carve-out is scoped
            // to the repo that recorded the baseline (repoKey equality — M2
            // semantics); a baseline owned by another checkout must not
            // authorize a switch here.
            repoKey: muEff.repoKey,
            // #598: branches this pid CREATED (create-new) or renamed its own
            // baseline to are owned (the #543/#588 ownership check). The read
            // is keyed on the MUTATION's repo (muEff.repoKey): _markOwned
            // writes under baseline.repoKey when the baseline repo IS the
            // mutation repo; with NO baseline, under muEff.repoKey; a baseline
            // in a DIFFERENT repo records nothing (repo-scoped — the create-
            // new/rename _markOwned calls below guard on repoKey equality).
            // The rename arm requires baseline.repoKey === repoKey, so for the
            // rename allow-path the muEff.repoKey read is the write key — the
            // own-baseline rename carve-out still holds when the dst is one of
            // the session's OWN refs (renaming onto a foreign ref blocks
            // above).
            ownedBranches: ownedBranches.get(pid)?.get(muEff.repoKey ?? ""),
            // #598: whether the rename DST ref already exists (probed above
            // for rename ops only; the carve-out's free-name case stays
            // allowed).
            renameDstExists: dstExists,
            // #591: the benign-force carve-out (own-branch force-create
            // passes through to git's rc-128 refusal) requires a NON-bare
            // repo (bare repos have no worktree protecting the branch) and a
            // command whose ONLY branch-state mutation is that own-branch
            // attempt (later `;`-compound segments — stateOpCount from the
            // classifier).
            isBare: muEff.isBare === true,
            stateOpCount: det.stateOpCount ?? 1,
            // #591 (round-3 fold): a shell substitution may hide another
            // branch-state invocation from stateOpCount (collapse to one
            // opaque token) — refuse the benign carve-out when the
            // classifier detected one (_hasHiddenStateSubst).
            hiddenStateSubst: det.hiddenStateSubst === true,
          });
          if (m3?.block) return { block: true, reason: m3.reason };
          if (m3?.reBaseline) {
            // Synchronous re-baseline: the allowed carve-out / own rename
            // adopts the new branch NOW — the next tool_call emits ZERO M1
            // warns (AC3). Record branches this pid CREATED (create-new) or
            // renamed its own baseline to — scoped to the BASELINE repo — so
            // their post-ceremony LOCAL delete is still allowed after the #376
            // return re-baselines to the original (#376 review fold-in).
            if (branchOp.op === "create-new" && branchOp.branch) {
              if (!baseline || (muEff.repoKey != null && baseline.repoKey === muEff.repoKey)) {
                _markOwned(pid, baseline?.repoKey ?? muEff.repoKey, branchOp.branch);
              }
            } else if (branchOp.op === "rename" && branchOp.to) {
              if (!baseline || (muEff.repoKey != null && baseline.repoKey === muEff.repoKey)) {
                _markOwned(pid, baseline?.repoKey ?? muEff.repoKey, branchOp.to);
              }
            }
            _rebaseline(pid, m3.reBaseline);
            return undefined;
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
        // #543: branch -D multi-target — the classifier's deleteTargets carries
        // EVERY -d/-D/--delete name (mirror of pushTargets' all-targets
        // semantics). git performs PARTIAL deletes on multi-target `-D`
        // (`git branch -D main feat/other` refuses the checked-out main but
        // deletes feat/other, rc=1), so the allowance must validate ALL names
        // ⊆ baseline∪owned — a first-target-only list (the old newBranch
        // capture) would let `<baseline|own> <foreign>` slip the trailing
        // foreign branch past the gate. Prefer deleteTargets over the single
        // newBranch fallback whenever present.
        const targets = det.pushTargets && det.pushTargets.length > 0
          ? det.pushTargets
          : ((det.deleteTargets && det.deleteTargets.length > 0)
            ? det.deleteTargets
            : (det.newBranch ? [det.newBranch] : []));
        if (branchOwnership.ownershipAllowed({
          opKind: allowanceKind,
          currentBranch: eff.currentBranch,
          baselineBranch: baseline?.branch ?? null,
          targets,
          syncSource: det.syncSource,
          // #376 review fold-in: branches this pid created (scoped to THIS
          // repo) stay locally deletable after the ceremony return re-bases the
          // baseline (own-branch hygiene).
          ownedBranches: ownedBranches.get(pid)?.get(eff.repoKey ?? ""),
        })) {
          // #443: det.pushTargets describe ONLY the first push invocation. A
          // delete in a LATER compound segment of the -d/--del family (no
          // frozen legacy evidence) is invisible to them, so an own-baseline
          // first push (`git push origin main && git push origin -d b` from a
          // baseline-main hub session) must NOT let this allowance swallow the
          // whole command — a sibling-held `b` would delete unguarded (the
          // `--delete` twin classifies block:push-delete targets ["b"] and
          // DOES block). Skip the allowance whenever the whole-command
          // extractor reveals a delete target that is not the session's own
          // baseline; own-branch ceremonies (extractor targets ⊆ baseline,
          // e.g. `… && git push origin -d feat` while on feat) still allow.
          // PUSH-FAMILY ONLY (wholeCommandDeleteTargets gates on the verdict):
          // non-push allowance kinds (pull/merge/rebase/branch -D) keep their
          // base decision — a `git pull origin main && git push origin -d b`
          // compound is an origin/main parity gap (the pull allowance already
          // swallowed it before #443), out of this push-spelling scope.
          const wcDeletes = wholeCommandDeleteTargets(det.verdict, command);
          const baselineBranch = baseline?.branch ?? null;
          // Unknown baseline (no way to tell own from foreign) → keep the
          // allowance's base decision exactly as before.
          const foreignDelete = baselineBranch !== null && wcDeletes.some((b) => b !== baselineBranch);
          if (!foreignDelete) return undefined;
          // foreign later-segment delete present → fall through to the #73 arms.
        }
      }

      // ── push --delete: retained #73 coordinated check (foreign targets) ──
      // The matcher is per-FIRST-push-invocation; a delete spelling in a LATER
      // compound segment is attributed via the whole-command extractor (matcher
      // fold-in for legacy-evidenced `--delete`/`:b` — verdict block:push-delete
      // — and here for the #443 `-d`/`--del` family, which carries NO frozen
      // legacy evidence so the verdict is block:push). A plain-push verdict
      // whose command contains real delete targets elsewhere must still run the
      // sibling-coordinated check; when nothing is held it FALLS THROUGH to M2
      // below, so the first segment's push stays gated exactly as origin/main
      // gated it. String-evidence echo/comment over-match is the documented
      // safe-direction class shared with the degradation arm.
      if (det.verdict === "block:push-delete" && det.pushTargets.length > 0) {
        const blocked = _coordinatedDeleteBlock(det.pushTargets);
        if (blocked) return blocked;
        return undefined; // foreign deletes with no checked-out targets — allowed (today's behavior)
      }
      if (det.verdict === "block:push" || det.verdict === "block:force-push") {
        const laterDeletes = wholeCommandDeleteTargets(det.verdict, command);
        if (laterDeletes.length > 0) {
          const blocked = _coordinatedDeleteBlock(laterDeletes);
          if (blocked) return blocked;
          // no sibling holds the target(s) → fall through to M2 below (the
          // first segment's push stays gated exactly as origin/main gated it).
        }
      }

      // ── M2: commit/push ownership (block off-baseline) ──
      if (det.verdict === "block:commit" || det.verdict === "block:push" || det.verdict === "block:force-push") {
        // #596 (round-3 reviewer P2-2): M2 must gate the COMMIT/PUSH's own
        // repo, not the M3 state-invocation repo — a compound with an
        // off-baseline MAIN commit and a later `-C <wt>`-scoped branch
        // mutation would otherwise reuse the worktree-exempt eff and let the
        // off-baseline commit through (the pre-#596 single-eff conflation
        // predates this PR for 2-segment forms; the 3-segment benign-lead form
        // flipped block→allow in round-2). preferVerb = the verdict's verb
        // resolves the commit/push invocation's own repo.
        const gateVerb = det.verdict === "block:commit" ? "commit" : "push";
        // #596 round-4 (reviewer P1 follow-up): the commit/push repo ALWAYS
        // comes from the classifier's boundary-aware commit/push invocation
        // hints (commitHints/pushHints — a block:commit/block:push verdict
        // implies the invocation exists; hint-less commits resolve at the
        // session cwd). The extractor replay phantom-counted script-file
        // attempts (`bash git -C <wt> commit -m z` — consumed by the
        // classifier as interpreter+path) and the no-stateVerb path
        // (eff = replay of det.verb) wrongly worktree-exempted the REAL main
        // commit.
        let m2Eff = branchOwnership.resolveRepoFromInv(
          gateVerb === "commit" ? det.commitHints : det.pushHints, process.cwd());
        // #596 round-4 (F2): null m2Eff under a block:commit/block:push
        // verdict means the hints-based read failed (git read error, or the
        // invocation was extractor-invisible — an interpreter-inline payload
        // is ONE opaque token to the repo layer). Mirror the M3
        // stateInvVisible===false round-3 policy: the payload executes at the
        // shell cwd, so resolve the commit/push repo at the SESSION cwd.
        // Fail-closed is preserved — session-cwd gates apply, never a silent
        // pass; an OFF-baseline session still blocks, while the round-4
        // regression (blocking an ON-baseline invisible commit that
        // pre-round-3 allowed) is undone.
        if (!m2Eff) {
          m2Eff = branchOwnership.resolveEffectiveRepo("git status", process.cwd());
        }
        if (!m2Eff) {
          return {
            block: true,
            reason: "⛔ git commit/push blocked — could not verify repo ownership (git read failed; fail-closed, #265).",
          };
        }
        const baseline = baselines.get(pid);
        const m2 = branchOwnership.decideM2({
          effectiveRepo: m2Eff, baseline, currentBranch: m2Eff.currentBranch,
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

    // ── write/edit: TARGET-aware hub-main gate (#618/#621) ──
    // The block resolves the WRITE TARGET's containing checkout (classify-git
    // resolveTargetCheckout), NOT the session cwd: a tracked-file write into
    // ANY repo's MAIN checkout is blocked from ANY session location — worktree
    // sessions (were exempt via the epic-529 early-return), foreign/non-git
    // cwds (were invisible — no session toplevel to compare), and other
    // repos' sessions (agent-infra-rooted controllers writing
    // tortoise/premise-labs/DMeer/eldato main after the #615 removal — the
    // #99 exemption was removed, but the gate must apply per TARGET so writes
    // INTO agent-infra worktrees stay fine while writes into other hubs
    // block). Targets inside ANY worktree stay free — a worktree's working
    // tree is private by construction, and a worktree session editing its own
    // worktree resolves to THAT worktree's checkout, never a main checkout
    // (epic-529 preserved structurally).
    const targetPath = (event.input as { path?: string }).path;
    if (_isAllowMainEdits()) {
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

    // Classify the TARGET's checkout (cached per realpath-normalized path).
    // Not in a git repo, or in a linked WORKTREE → isolated by construction:
    // own worktree, sibling/foreign worktree, /tmp, ~/.pi — free (the old
    // "outside project" / "worktree session" allows). Symlinked/external-
    // gitdir spellings: their realpath loses the `.git` segment, so test the
    // SPELLING before declaring an unclassified target isolated (cycle-2 F4).
    const tgtReal = _realpathNearest(resolvedTarget);
    const tgtCheck = _checkoutOf(tgtReal);
    if (!tgtCheck || !tgtCheck.isMain) {
      const meta = _gitMetaSpellingTop(resolvedTarget);
      if (meta) {
        return {
          block: true,
          reason: _hubTargetWriteBlockReason(meta.rel, meta.top, ""),
        };
      }
      return undefined;
    }
    const sessionCheck = _checkoutOf(resolve(process.cwd()));
    const sessionTop = sessionCheck ? sessionCheck.top : null;
    const sessionOwnsThisMain = !!sessionCheck && sessionCheck.isMain && sessionCheck.top === tgtCheck.top;
    const wipPattern = matchHubWipPattern(targetPath ?? "");
    const wipHint = wipPattern
      ? `   This looks like ${WIP_PATTERN_LABEL[wipPattern] ?? wipPattern} written directly into main — the #347 amplifier; use a worktree.`
      : "";
    if (sessionOwnsThisMain) {
      // A session rooted in a hub's own main checkout: ALL main writes block
      // (tracked AND new — today's permanent gate; the M4-disorder new-file
      // carve-out ran upstream under disorder; agent-infra included since
      // #615). #350: surface the WIP-pattern violation in the block reason.
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
    // A main checkout strictly NESTED under the session's own checkout tree
    // (private repo / submodule / vendored copy inside the session's work
    // area) is not a shared hub — the session owns that subtree, so the
    // cross-checkout freeze does not reach it (cycle-2 correctness F1b; the
    // real sibling-hub vectors — the GitHub parent dir, other repos' main
    // checkouts — are never under the session's own tree).
    if (sessionTop && tgtCheck.top.startsWith(sessionTop + "/")) {
      return undefined;
    }
    // Cross-cwd write into a hub main (worktree session / foreign non-git
    // cwd / another repo's session): TRACKED-file overwrites block — the
    // silent-destruction vector (#618 mass-hook rewrite from the GitHub
    // parent dir; #621 infra-rooted cross-repo leak). `.git/`-metadata
    // targets (hooks/, config, the .git pointer file) are NEVER index-tracked
    // — a cross-cwd write into a hub's .git is the same deliberate-hub-write
    // vector and blocks too (adversarial-review F4 + cycle-2 rel-exact). An
    // EXISTING UNTRACKED hub file is also an overwrite, not an additive new
    // file: cross-session it silently destroys another session's uncommitted
    // hub WIP, so it blocks (cycle-2 P2); only genuinely NEW files stay free.
    if (targetPath) {
      const rel0 = tgtReal.startsWith(tgtCheck.top + "/")
        ? tgtReal.slice(tgtCheck.top.length + 1)
        : "";
      const gitMeta = rel0 === ".git" || rel0.startsWith(".git/");
      const tracked = _targetTrackedAt(tgtCheck.top, tgtReal);
      let existsFile = false;
      try { existsFile = existsSync(tgtReal) && statSync(tgtReal).isFile(); } catch { /* treat as nonexistent */ }
      if (gitMeta || tracked || existsFile) {
        const rel = rel0 || tgtReal.slice(tgtCheck.top.length).replace(/^[/\\]+/, "") || tgtReal;
        if (gitMeta || tracked) {
          return {
            block: true,
            reason: _hubTargetWriteBlockReason(rel, tgtCheck.top, wipHint),
          };
        }
        // existing-untracked overwrite: destructive of another session's hub WIP.
        return {
          block: true,
          reason: [
            `⛔ File write blocked — overwriting an existing UNTRACKED file in a hub main (${rel}).`,
            ...(wipHint ? [wipHint] : []),
            `   The target resolves to ${tgtCheck.top} — that repo's shared MAIN checkout`,
            `   (#618/#621). Cross-session overwrites are destructive: an existing`,
            `   untracked file in a hub main is another session's uncommitted WIP.`,
            `   Only genuinely NEW files (additive + visible) are allowed cross-cwd.`,
            `   → Work in a worktree of that repo: invoke the using-git-worktrees skill.`,
            `   → Or set AGENT_ALLOW_MAIN_EDITS=1 (or ELDATO_ALLOW_MAIN_EDITS=1) to`,
            `     override (deliberate solo sessions only).`,
          ].join("\n"),
        };
      }
    }
    // New/untracked targets into a hub main: additive + visible → #350
    // warn-only when the WIP patterns match (never block).
    _maybeWarnHubWipWrite(targetPath, tgtCheck.top);
    return undefined;
  });

  // #5672: suppress startup banner in print mode (task sub-agent output)
  if (!isPrintMode()) {
    console.log("[main-worktree-guard] ✅ Loaded — blocking write/edit + destructive git in main checkout");
  }
  // ── Session-start hub discipline check (#73) ──
  // In the main checkout: warn if on a non-main branch or dirty working tree.
  // Non-blocking — the write/edit guard still protects; this is a discipline prompt.
  // #615: agent-infra is INCLUDED (the #99 exemption is removed — its main
  // checkout is a pure hub too). Marker parity: an active escape marker also
  // suppresses the warning. Documented
  // limitation: at module load ctx is unavailable, so this degrades to the
  // env-only session id — for interactive sessions where the extension host
  // lacks PI_SESSION_ID the read is false and the warning shows (fail-safe; the
  // per-tool_call check is authoritative).
  if (!_isAllowMainEdits() && !readAllowMarkerState(_markerPath(), _currentSessionId(undefined))) {
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
