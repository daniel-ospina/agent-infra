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
import { execSync } from "node:child_process";
import { resolve, dirname, join } from "node:path";
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
let evaluateHubGate: (command: string, currentBranch: string | null) => { verdict: "non-git" | "allowed" | "recovery" | "block"; reason?: string } = () => ({ verdict: "non-git" });
// #347: per-invocation target-aware M4 gate + execution-cwd resolution + write
// target toplevel. Fail-safe defaults degrade to inactive (gate → non-git /
// null) so a failed import NEVER false-blocks; on classify-git load failure
// readHubDisorder also degrades to null → M4 off (existing contract).
let evaluateHubGateWithTargets: (command: string, currentBranch: string | null, sessionCwd?: string) => { verdict: "non-git" | "allowed" | "recovery" | "block"; reason?: string } = () => ({ verdict: "non-git" });
let commandExecutionCwd: (command: string, sessionCwd?: string) => string | null = () => null;
let resolveTargetTopLevel: (targetPath: string, cwd?: string) => string | null = () => null;
let extractScriptPath: (command: string) => string | null = () => null;
let scriptGitVerdict: (path: string, currentBranch: string | null) => "allow" | "block" = () => "allow";
let classifierLoaded = false;
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
     readAllowMarkerState, readHubDisorder, evaluateHubGate,
     extractScriptPath, scriptGitVerdict, evaluateHubGateWithTargets,
     commandExecutionCwd, resolveTargetTopLevel } =
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
      const inWorktree = isWorktreeCwdWrite(resolve(process.cwd()));
      if (inWorktree) return;
      const currentBranch = getMainCheckoutBranch();
      const porcelain = execSync("git status --porcelain", {
        encoding: "utf-8", timeout: 5000,
      }).trim();
      const onNonMain = currentBranch && currentBranch !== "main" && currentBranch !== "master";
      const dirty = porcelain.length > 0;

      if (isAgentInfraRepo()) {
        // Downgraded agent-infra variant: branch deviation is the NORM in the
        // infra repo (in-main feature work per #99) — warn on dirty tree only.
        if (dirty) {
          console.warn(`[main-worktree-guard] ⚠️ agent-infra main checkout is DIRTY (${porcelain.split("\n").length} change(s)) — parallel sessions may collide; commit or stash before other agents start.`);
        }
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
        lines.push(
          "║                                                                  ║",
          "║  The main checkout is a shared hub — parallel agents may collide. ║",
          "║  Feature work should happen in isolated worktrees.                ║",
          "║  → Invoke the using-git-worktrees skill to create one.            ║",
          "║  → Set AGENT_ALLOW_MAIN_EDITS=1 to suppress this warning.         ║",
          "╚══════════════════════════════════════════════════════════════════╝",
          "",
        );
        console.warn(lines.join("\n"));
      }
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
          // #347: per-invocation target resolution — git ops whose effective
          // target is an isolated worktree are exempt from hub disorder; every
          // other invocation (hub, foreign, unresolvable) keeps today's block.
          const gate = evaluateHubGateWithTargets(command, st.branch, resolve(process.cwd()));
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

      // ── Degradation fallback (branch-ownership OR detailed classifier
      // unavailable): behave exactly like today — agent-infra exempt,
      // string-verdict destructive blocks for non-infra main, marker bypass. ──
      if (!branchOwnership || !classifierLoaded) {
        if (isAgentInfraRepo()) return undefined;
        if (_isAllowMainEdits()) return undefined;
        const verdict = classifyGitCommand(command);
        if (verdict.startsWith("block:")) {
          if (verdict === "block:push-delete") {
            const branchNames = extractPushDeleteBranch(command);
            if (branchNames && branchNames.length > 0) {
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
              if (blockedBranches.length > 0) {
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
            }
            return undefined;
          }
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
      return undefined;
    }

    const targetPath = (event.input as { path?: string }).path;

    // #99 write/edit exemption for the infra repo itself (retained): agent-infra
    // is where infra fixes land; the branch-ownership gates (M1/M2/M3) now cover
    // its bash git surface instead.
    if (isAgentInfraRepo()) {
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
      return {
        block: true,
        reason: [
          "⛔ File edits in the main checkout are blocked.",
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
        const porcelain = execSync("git status --porcelain", {
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
          lines.push(
            "║                                                                  ║",
            "║  The main checkout is a shared hub — parallel agents may collide. ║",
            "║  Feature work should happen in isolated worktrees.                ║",
            "║  → Invoke the using-git-worktrees skill to create one.            ║",
            "║  → Set AGENT_ALLOW_MAIN_EDITS=1 to suppress this warning.         ║",
            "╚══════════════════════════════════════════════════════════════════╝",
            "",
          );
          console.warn(lines.join("\n"));
        }
      }
    } catch (e) {
      // Degrade silently — this is a non-blocking discipline check
      console.warn("[main-worktree-guard] ⚠️ Hub discipline check failed:", String(e));
    }
  }
}
