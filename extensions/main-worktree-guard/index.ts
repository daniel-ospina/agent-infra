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
//     writes block regardless of hub state. #625 extends the SAME-checkout
//     decision to be state-independent too: a tracked hub-main write from a
//     hub-rooted session blocks whether that hub is CLEAN or disordered (the
//     old clean-hub carve-out let one compound `printf … >> MEMORY.md && git
//     add && git commit && git push` through), and the bash walker now
//     surfaces the in-place overwrite VERBS (sed -i / perl -pi / awk -i
//     inplace / cp / mv / install / truncate / dd of=) that carried no
//     write-primitive token. Cycle-2/3 fold-ins: main checkouts
//     NESTED under a session's own checkout tree are private subtrees (not
//     shared hubs) and are not frozen ONLY when the session itself is a
//     NON-main checkout — a worktree/private checkout owns its tree; a
//     MAIN-rooted session's nested checkouts (submodules under a hub) stay
//     frozen (an ancestor MAIN over sibling hubs must not lift the freeze,
//     cycle-3 B-1); `.git/`-metadata writes freeze for every session in every
//     state except an active TTL marker's own-rooted clean recovery window
//     (never a build side-effect); a TTL marker bypasses the cross-checkout
//     bash gate exactly like the write/edit route (M4 D3's disordered-own-hub
//     freeze stays); the write/edit gate and the bash route both block
//     cross-checkout overwrites of EXISTING untracked hub files (another
//     session's hub WIP) — only genuinely NEW files are additive (cycle-3
//     A-2 bash parity); script-chain budget exhaustion fails closed ONLY on
//     hub-proximity evidence (a >64-token hub-free fan-out must not
//     false-block, cycle-3 A-1). Worktree sessions still write
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
// #627: non-shell code-interpreter payload surface (python -c / node -e / …).
// Fail-safe defaults inert so a failed import NEVER false-blocks.
let extractCodePayload: (command: string) => { kind: "inline" | "file" | "stdin-file" | "module" | "stdin"; value: string | null } | null = () => null;
let codePayloadGitVerdict: (content: string, currentBranch: string | null, executionCwd?: string, sessionCwd?: string) => "allow" | "block" = () => "allow";
// #744 skew-guard temps: the import block below uses RENAME destructuring
// (`extractCodePayload: _extractCodePayload`) so the typeof guard can test the
// freshly-imported value BEFORE it overwrites the fail-safe default above.
// In a destructuring ASSIGNMENT (no `let`/`const` keyword) every `prop: ident`
// target must already be a declared binding — ESM is always strict mode, so an
// undeclared target throws ReferenceError. That throw lands inside the try
// below, is swallowed by the catch, and ABORTS the import at that target. The
// assignment is left-to-right, so targets listed BEFORE it stay bound to the
// real exports — but every target from there on keeps its fail-safe default and
// `classifierLoaded` never flips, silently disabling the #627/#628/#350 gates
// and the disordered-hub write helpers for every session (#697 shipped this).
// Seeded with the same fail-safe defaults the guards fall back to.
let _extractCodePayload: typeof extractCodePayload = () => null;
let _codePayloadGitVerdict: typeof codePayloadGitVerdict = () => "allow";
// #350: hub-WIP hygiene helpers (warn-only). Fail-safe defaults: inert
// (null/[]) so a failed import NEVER false-blocks — these warnings are
// discipline prompts, not gates.
let matchHubWipPattern: (resolvedPath: string) => "docs/plans" | "migrations" | "scratch" | null = () => null;
let extractBashWriteTargets: (command: string, cwd?: string) => { resolvedPath: string; via: string }[] = () => [];
// #628: disordered-hub new-file volume policy (pure decision in classify-git).
let hubNewFileVolumeVerdict: (count: number) => "warn" | "escalate" | "block" = () => "warn";
let HUB_NEW_FILE_WARN_BUDGET = 10;
let HUB_NEW_FILE_BLOCK_CAP = 25;
// #744 skew-guard temps (same contract as the #627 pair above): declared
// targets for the rename destructuring in the import block — without these the
// assignment throws ReferenceError and the catch below degrades the import.
let _hubNewFileVolumeVerdict: typeof hubNewFileVolumeVerdict = () => "warn";
let _HUB_NEW_FILE_WARN_BUDGET = 10;
let _HUB_NEW_FILE_BLOCK_CAP = 25;
let classifyUntrackedWip: (porcelain: string) => { untracked: string[]; wip: { path: string; pattern: string }[] } = () => ({ untracked: [], wip: [] });
// #437 (C): PER-WRITE-SITE bash-write candidates (cd-aware) for the
// disordered-hub gate + the pure tracked intersect. Fail-safe defaults inert.
let bashWriteTargetsResolved: (command: string, cwd?: string) => ({ resolvedPath: string; via: string; site: string; cwd: string; scriptToks?: { path: string; cwd: string }[] })[] = () => [];
// #709: the working-tree-discard family + its effect decision. Fail-safe
// defaults: [] / false → M5 is inert when the classifier fails to load (the
// gate must never false-block on a degraded import; test-module-load.mjs is
// the regression tripwire for the degradation itself).
let extractWorkingTreeDiscards: (command: string) => { form: string; scope: string; pathspecs: string[]; fromTree?: boolean; verb: string; args: string[]; inv: unknown }[] = () => [];
let discardDestroysWip: (porcelain: string, d: { scope: string; fromTree?: boolean }) => boolean = () => false;
let resolveInvocationTarget: (inv: unknown, sessionCwd?: string, baseCwd?: string) => { effectiveCwd: string; gitDir: string; worktreePath: string | null; worktreeBranch: string | null; isWorktree: boolean; foreignWorktree: boolean } | null = () => null;
// M5 fail-closed helper: xargs/find `-exec` placeholder pathspec. Fail-safe
// default false is safe — a degraded import leaves extractWorkingTreeDiscards
// inert (`[]`), so nothing reaches this call.
let wtIsPlaceholderPathspec: (p: unknown) => boolean = () => false;
// Fail-safe default = the old bare-word regex: a degraded import must not make
// the piped-code arms over-claim, and must not silently widen them either.
let wtPipelineFeedsShell: (cmd: string) => boolean =
  (cmd: string) => /\|\s*(?:\S*\/)?(?:bash|sh|zsh|dash|ksh)\s*$/.test(String(cmd ?? ""));
let wtShellInlinePayloads: (cmd: string) => { text: string; opaque: boolean }[] =
  // FAIL-SAFE fallback, not inert: a stale/partial classify-git.mjs (the export
  // missing while `classifierLoaded` is still true) must not silently delete the
  // opaque `-c` arm. This is the same quote-aware scan, minus the spawner/keyword
  // head analysis — it can only OVER-report, which keeps the arm fail-closed.
  (cmd: string) => {
    const out: { text: string; opaque: boolean }[] = [];
    const re = /(?:^|[\s;&|(])(?:[\w./-]*\/)?(?:bash|sh|zsh|dash|ksh|ash|mksh|oksh)\s+(?:-[A-Za-z]*c[A-Za-z]*|--command)\s+("[^"]*"|'[^']*'|\S+)/g;
    for (const m of String(cmd ?? "").matchAll(re)) {
      const t = m[1] ?? "";
      out.push({ text: t, opaque: /[$`]/.test(t) });
    }
    return out;
  };
let joinContinuations: (cmd: string) => string = (c: string) => String(c ?? "");
let ansiTranslate: (s: string) => string = (s: string) => String(s ?? "");
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
     extractCodePayload: _extractCodePayload, codePayloadGitVerdict: _codePayloadGitVerdict,
     commandExecutionCwd, resolveTargetTopLevel, matchHubWipPattern,
     extractBashWriteTargets, classifyUntrackedWip, branchDeleteAllowance, newFileWriteCollisionFree,
     bashWriteTargetsResolved, resolveTargetCheckout, trackedRelsIn, hasDotGitAncestor,
     hubNewFileVolumeVerdict: _hubNewFileVolumeVerdict, HUB_NEW_FILE_WARN_BUDGET: _HUB_NEW_FILE_WARN_BUDGET,
     HUB_NEW_FILE_BLOCK_CAP: _HUB_NEW_FILE_BLOCK_CAP } =
    await import("./classify-git.mjs"));
  // #709: M5's exports are read from the (cached) module namespace rather than
  // added to the destructuring assignment above — every new target there is a
  // new assertion in test-module-load.mjs Part A, and that suite's contract is
  // exactly 49 passed / 0 failed.
  const _m5 = await import("./classify-git.mjs");
  extractWorkingTreeDiscards = _m5.extractWorkingTreeDiscards;
  discardDestroysWip = _m5.discardDestroysWip;
  resolveInvocationTarget = _m5.resolveInvocationTarget;
  if (typeof _m5.wtIsPlaceholderPathspec === "function") wtIsPlaceholderPathspec = _m5.wtIsPlaceholderPathspec;
  if (typeof _m5.wtPipelineFeedsShell === "function") wtPipelineFeedsShell = _m5.wtPipelineFeedsShell;
  if (typeof _m5.wtShellInlinePayloads === "function") wtShellInlinePayloads = _m5.wtShellInlinePayloads;
  if (typeof _m5.joinContinuations === "function") joinContinuations = _m5.joinContinuations;
  if (typeof _m5.ansiTranslate === "function") ansiTranslate = _m5.ansiTranslate;
  hubNewFileVolumeVerdict = _hubNewFileVolumeVerdict;
  HUB_NEW_FILE_WARN_BUDGET = _HUB_NEW_FILE_WARN_BUDGET;
  HUB_NEW_FILE_BLOCK_CAP = _HUB_NEW_FILE_BLOCK_CAP;
  // #627 bindings: same stale-classify-git skew guard as #628 — a missing
  // export must leave the fail-safe defaults (an undefined here would throw in
  // _backdoorBlock, whose catch turns the whole #627 gate fail-OPEN).
  if (typeof _extractCodePayload === "function") extractCodePayload = _extractCodePayload;
  if (typeof _codePayloadGitVerdict === "function") codePayloadGitVerdict = _codePayloadGitVerdict;
  // Stale-classify-git skew guard: a missing export must leave the fail-safe
  // defaults (never overwrite a function with undefined → TypeError on the
  // write branch).
  if (typeof _hubNewFileVolumeVerdict !== "function") hubNewFileVolumeVerdict = () => "warn";
  if (typeof _HUB_NEW_FILE_WARN_BUDGET !== "number") HUB_NEW_FILE_WARN_BUDGET = 10;
  if (typeof _HUB_NEW_FILE_BLOCK_CAP !== "number") HUB_NEW_FILE_BLOCK_CAP = 25;
  // #709 skew guard (same contract): a stale/short classify-git must leave M5
  // inert rather than bind `undefined` and throw inside the bash gate.
  if (typeof extractWorkingTreeDiscards !== "function") extractWorkingTreeDiscards = () => [];
  if (typeof discardDestroysWip !== "function") discardDestroysWip = () => false;
  if (typeof resolveInvocationTarget !== "function") resolveInvocationTarget = () => null;
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
// touch command. try/catch fail-silent (F7) — when the stamp write FAILS no
// stamp exists, so the shell `touch` then leaves an EMPTY (unparseable →
// inert) marker: readAllowMarkerState stays false → blocked. A failed stamp
// never weakens the gate (and a later guard-observed touch re-stamps over it).
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
// #628: disordered-hub new-file volume policy — per-session counter (pid =
// one pi process = one session) + per-path warn dedupe. See classify-git
// hubNewFileVolumeVerdict for the pure decision + constants.
const hubNewFileCounts = new Map<number, number>();
const warnedNewFileTargets = new Set<string>();

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

// #628 (write-time signal): the disordered-hub M4 new-file carve-out returns
// BEFORE the #350 WIP prompt, so new hub files accumulated silently. Every
// carve-out write now warns (all paths — not just WIP patterns) and the
// warning escalates past the budget; the caller blocks past the hard cap.
// Prompts follow the documented marker contract: suppressed under the env
// hatch AND an active TTL marker (the marker is an audited solo-session
// window); the CAP block is M4 discipline and stays active under the marker
// (D3 — the marker never re-enables hub writes).
function _warnHubNewFile(targetPath: string, count: number, level: "warn" | "escalate") {
  const L = (t: string) => "║  " + t.padEnd(62) + "║";
  const lines = [
    "",
    "╔══════════════════════════════════════════════════════════════════╗",
    L("⚠️  NEW FILE IN A DISORDERED HUB — PUT IT IN A WORKTREE (#628)"),
    "╠══════════════════════════════════════════════════════════════════╣",
    L(`Target: ${_truncatePath(targetPath, 52)}`),
    L(`New hub files this session: ${count} (budget ${HUB_NEW_FILE_WARN_BUDGET}, cap ${HUB_NEW_FILE_BLOCK_CAP})`),
    L(""),
    ...(level === "escalate"
      ? [
        L("Budget exceeded — this is accumulation, not a one-off. The hub's"),
        L("only legal state is main+clean; stop adding to the dirty set."),
        L(`Further new files block past ${HUB_NEW_FILE_BLOCK_CAP}.`),
      ]
      : [
        L("The hub is off-main/dirty. New files are allowed (additive, they"),
        L("cannot collide with a sibling's WIP) but they GROW the dirty set"),
        L("the hub recovery must later carry."),
      ]),
    L("→ Recover the hub, then work in a worktree:"),
    L("  bash scripts/checkout-hygiene/hub-worktree.sh <branch>"),
    "╚══════════════════════════════════════════════════════════════════╝",
    "",
  ];
  console.warn(lines.join("\n"));
}

// Deduped per path per session (mirrors warnedWipTargets). Suppressed under
// the env hatch / active marker per the marker contract; the volume COUNTER
// still advances (the cap must count even while prompts are suppressed).
function _maybeWarnHubNewFile(targetPath: string, count: number, level: "warn" | "escalate") {
  try {
    if (_isAllowMainEdits()) return;
    if (readAllowMarkerState(_markerPath(), _currentSessionId(undefined))) return;
    const key = `newfile:${count > HUB_NEW_FILE_WARN_BUDGET ? "escalated" : "warn"}:${targetPath}`;
    if (warnedNewFileTargets.has(key)) return;
    warnedNewFileTargets.add(key);
    _warnHubNewFile(targetPath, count, level);
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
//     deliberate cross-checkout session): #437 semantics, EXTENDED by #625 to
//     a state-INDEPENDENT decision — block tracked overwrites whether that
//     main is clean or disordered (the write/edit route has been a permanent
//     target-aware gate since #618/#621; the old clean-hub carve-out let a
//     compound `printf … >> MEMORY.md && git add && git commit && git push`
//     through). Own-main UNTRACKED/new writes stay allowed (build/formatter
//     side effects on genuinely new files must never false-block; tracked-
//     ness is exact via `git ls-files`).
//   - CROSS-checkout — session shell NOT rooted in the target main (a
//     worktree session writing its own repo's main, a foreign/non-git cwd, or
//     another repo's session, incl. a clean agent-infra main): block TRACKED
//     overwrites regardless of hub state, PLUS any write into that main's
//     `.git/` metadata (hooks/, config — never index-tracked, so the tracked
//     intersect cannot see them), PLUS any overwrite of an EXISTING untracked
//     hub file (destroys another session's uncommitted hub WIP — only
//     genuinely NEW files are additive; cycle-3 A-2 parity with the tool
//     route). These are the vectors behind the 2026-09-08
//     mass `.husky/pre-commit` rewrite from the GitHub parent dir and the
//     wt-session python open() probes into premise-labs/tortoise AGENTS.md.
// NEW-file writes keep the warn-only treatment (#350 / the #436
// collision-free carve-out; a session's OWN disordered-main untracked writes
// stay allowed — build/formatter side effects, #437). Script-file content
// (`bash /tmp/x.sh`) is walked with the SAME per-candidate classifier
// (bounded depth). There is NO cheap pre-bail: bashWriteTargetsResolved is a
// PURE string walk (zero git spawns on a write-free command), and the earlier
// bail fired exactly for worktree/foreign sessions (their hub disorder reads
// null) — letting `bash -c '…'` / sudo-tee / spawner-wrapped payloads past
// the walker (adversarial-review F3). Fail-safe: any git/parse error → null
// (never false-block). One bounded `git ls-files` per distinct target top for
// all its candidates.
function _hubBashTrackedWrite(command: string, sessionDisorder: string | null, markerOn: boolean): { resolvedPath: string; rel: string; kind?: "script-depth" | "untracked-existing" } | null {
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
    // targets and any main checkout NESTED under the session's own tree when
    // the SESSION is a NON-main checkout (a private repo / submodule /
    // vendored copy under a worktree the session owns — not a shared-hub
    // write; cycle-2 F1b + cycle-3 B-1 cap: a MAIN-rooted session's nested
    // checkouts stay frozen); same-checkout candidates
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
      // is the session's private working subtree ONLY when the SESSION ITSELF
      // is a NON-main checkout (a worktree/private checkout — its tree is
      // session-private by construction). A MAIN-rooted session has no
      // private subtree: that main (a hub) is shared with every other session
      // of the repo, so a submodule/vendored checkout nested under it is
      // shared too and stays frozen (cycle-3 B-1: the pure path-containment
      // exemption let an ancestor MAIN — a parent repo over sibling hubs —
      // lift every cross-hub freeze; cap the exemption at non-main sessions,
      // which closes the ancestor vector since that session is main-rooted).
      if (sessionCheck && !sessionCheck.isMain && sessionTop && sessionTop !== ck.top && ck.top.startsWith(sessionTop + "/")) {
        return;
      }
      const sameCheckout = sessionOwnHub !== null && sessionOwnHub === ck.top;
      // .git-metadata rel (exact ".git" pointer file OR ".git/..." internals):
      // never index-tracked and never a build side-effect — every session in
      // every state blocks it EXCEPT an active TTL marker's same-rooted CLEAN
      // main (its open recovery window; disordered own main still freezes via
      // M4 D3 under the marker), mirroring the write/edit tool's freeze of the
      // same spelling (cycle-2 F4 rel-exact + P1; cycle-3 B-2 doc parity).
      const gitMeta = rel === ".git" || rel.startsWith(".git/");
      if (markerOn) {
        if (!sameCheckout) return; // marker bypasses the #618 cross gate (tool parity)
        if (sessionDisorder === null) return; // clean own main under the marker — open recovery window
        if (gitMeta) { gitInternalHit = { resolvedPath: tPath, rel }; return; } // M4 D3 freeze
      } else if (gitMeta) {
        gitInternalHit = { resolvedPath: tPath, rel };
        return;
      }
      // #625: NO clean-same-checkout early return. The gate decides on the
      // command's EFFECT (does it write a TRACKED hub-main file?), not on
      // pre-execution hub disorder — the write/edit route has been a permanent
      // target-aware gate since #618/#621, while the old #437 "clean
      // same-checkout" residual let a hub-rooted main+CLEAN session commit
      // tracked shared files with ONE compound (`printf … >> MEMORY.md && git
      // add && git commit && git push`: no disorder → M4's git gate skipped,
      // decideM2 saw an on-baseline session). Own-main UNTRACKED writes stay
      // allowed (the `crossTop` guard below freezes an existing-untracked
      // overwrite only CROSS-checkout — genuinely-new build/formatter side
      // effects keep working).
      // reached → same-checkout (clean OR disordered) OR deliberate
      // cross-checkout: the tracked test decides.
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
    // a chain deeper than the budget is unverifiable. Exhaustion fails closed
    // ONLY on hub-proximity evidence (grouped candidates or a disordered
    // own-main session); a hub-free chain must not false-block (cycle-3 A-1).
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
      // content is UNVERIFIABLE. Fail closed ONLY on hub-proximity evidence:
      // the walk already placed a candidate under the block-or-block-if-
      // tracked tests (grouped) or the session shell is rooted in a hub main
      // (the classic chain-write incident shape). A >64-token chain that
      // never resolved any target into a hub-main candidate AND is not rooted
      // in a DISORDERED hub (non-git /tmp cwd, a worktree fan-out of sourced
      // helpers, or a clean own hub) stays NO evidence of a hub write —
      // failing closed there false-blocks legit wide source fan-outs
      // (cycle-3 A-1). Residual: a >64-token chain
      // whose hub write sits in the unprocessed tail slips (documented; the
      // tool route is authoritative and the write gate is marker/tool-checked).
      if (grouped.size === 0 && !(sessionOwnHub !== null && sessionDisorder !== null)) return null;
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
      // cycle-3 A-2: a CROSS-checkout rec that EXISTS but is NOT tracked is an
      // existing-untracked overwrite — the bash route mirrored the tool
      // route's tracked + .git freezes but not its existing-untracked one;
      // freeze it here (bash untracked surface otherwise unchanged: a
      // same-rooted-disordered session's own-main untracked writes stay
      // allowed — build/formatter side effects, #437). Under an active marker
      // no cross-checkout rec ever reaches grouping (marker branch returns
      // early), so no markerOn guard is needed here.
      const crossTop = sessionOwnHub === null || sessionOwnHub !== top;
      if (crossTop) {
        for (const r of recs) {
          try {
            if (existsSync(r.tPath) && statSync(r.tPath).isFile()) return { resolvedPath: r.tPath, rel: r.rel, kind: "untracked-existing" as const };
          } catch { /* keep walking */ }
        }
      }
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
function _hubBashWriteBlockReason(hit: { resolvedPath: string; rel: string; kind?: "script-depth" | "untracked-existing" }): string {
  if (hit.kind === "untracked-existing") {
    return [
      `⛔ Bash write to an existing UNTRACKED file in a hub main blocked (${hit.rel}).`,
      `   The write target's repo is a shared MAIN checkout (#618/#621); a`,
      `   cross-checkout overwrite of an EXISTING untracked hub file destroys`,
      `   another session's uncommitted hub WIP. Only genuinely NEW files`,
      `   (additive + visible) are allowed cross-checkout (cycle-3 A-2 — the`,
      `   bash route mirrors the write/edit tool's existing-untracked freeze).`,
      `   → Work in a worktree of the TARGET repo (using-git-worktrees skill,`,
      `     or bash scripts/checkout-hygiene/hub-worktree.sh <branch>).`,
      `   → Or set AGENT_ALLOW_MAIN_EDITS=1 (or ELDATO_ALLOW_MAIN_EDITS=1) to`,
      `     override (deliberate solo sessions only).`,
    ].join("\n");
  }
  if (hit.kind === "script-depth") {
    return [
      "⛔ Bash script execution blocked — script chain exceeds the verify budget.",
      `   A script/source chain deeper than the guard's walk budget was detected`,
      `   with hub-main candidates already in view (or the session shell rooted`,
      `   in a DISORDERED hub main); its tail writes into hub-main`,
      `   checkouts are UNVERIFIABLE and the guard fails closed rather than risk`,
      `   a tracked hub file write. A chain with NO hub proximity is not blocked`,
      `   (cycle-3 A-1).`,
      `   → Run the shell commands directly (in a worktree), or flatten the chain.`,
      `   → Or set AGENT_ALLOW_MAIN_EDITS=1 (or ELDATO_ALLOW_MAIN_EDITS=1) to`,
      `     override (deliberate solo sessions only).`,
    ].join("\n");
  }
  const gitMeta = hit.rel === ".git" || hit.rel.startsWith(".git/");
  return [
    `⛔ Bash write to a hub ${gitMeta ? "git-metadata file" : "tracked file"} blocked (${hit.rel}).`,
    `   The write target's repo is a shared MAIN checkout (#618/#621) — bash`,
    `   write primitives AND in-place overwrite verbs (sed -i, perl -pi, cp,`,
    `   mv, install, truncate, dd of=) respect the SAME gate as the write/edit`,
    `   tools: a DELIBERATE cross-checkout write (your session is not rooted`,
    `   in that repo) freezes regardless of hub state, a session rooted in`,
    `   that repo's main freezes on tracked overwrites (clean OR disordered),`,
    `   and hub .git-metadata writes (hooks/, config) freeze for every session in`,
    `   every state except an active escape-marker's own-rooted clean recovery window.`,
    `   NEW-file writes and own-main untracked writes stay allowed. Only`,
    `   session-start host env (AGENT_ALLOW_MAIN_EDITS=1) bypasses — a`,
    `   mid-command export cannot.`,
    `   → Work in a worktree of the TARGET repo (using-git-worktrees skill,`,
    `     or bash scripts/checkout-hygiene/hub-worktree.sh <branch>).`,
    `   → Or set AGENT_ALLOW_MAIN_EDITS=1 (or ELDATO_ALLOW_MAIN_EDITS=1) to`,
    `     override (deliberate solo sessions only).`,
  ].join("\n");
}

// ── M5 (#709): working-tree-discard gate (effect-keyed) ────────
// The legacy destructive arms key on the VERB (so `git checkout -- <path>` —
// the incident verb — classifies `allow`, pinned by test.mjs) and exempt
// worktrees wholesale (so `git restore`/`checkout .`/`reset --hard` run free
// where the `pi -p` mutation-test fixers work). M4 catches the incident verb
// only while the hub is DISORDERED (test.mjs:2247). M5 keys on the EFFECT
// instead: a discard-family command is blocked when the checkout it targets is
// carrying uncommitted state the discard would destroy — in the hub AND in a
// linked worktree. Read-only commands, clean targets, untracked-only dirt and
// index-only restores stay allow. Placed AFTER the env/marker hatch return, so
// both hatches bypass it unchanged (task children are unhatched by #617/#623,
// which is why this is the enforcement surface for them).

/** Bounded porcelain probe for a discard's target checkout.
 *  @returns true = would destroy uncommitted work; false = nothing to destroy;
 *           null = unverifiable (caller fails closed). */
function _discardStatusPorcelain(probeCwd: string, d: { scope: string; pathspecs: string[]; fromTree?: boolean }): boolean | null {
  try {
    const args = ["status", "--porcelain=v1"];
    if (d.scope === "paths" && d.pathspecs.length > 0) args.push("--", ...d.pathspecs);
    // execFileSync (array args, no shell): pathspecs are DATA — a path
    // containing shell metacharacters can never become a command.
    const out = execFileSync("git", args, {
      cwd: probeCwd, encoding: "utf-8", timeout: 5000, stdio: ["ignore", "pipe", "ignore"],
    });
    return discardDestroysWip(String(out), d);
  } catch (e) {
    const msg = String((e as { stderr?: unknown })?.stderr ?? "") + String((e as { message?: string })?.message ?? e);
    // Not a checkout (or a bare repo): there is no working tree to destroy.
    if (/not a git repository|must be run in a work tree|does not have a working tree/i.test(msg)) return false;
    return null; // unverifiable → fail closed
  }
}

/** Shared block reason for M5. */
function _worktreeDiscardBlockReason(
  d: { form: string; scope: string; pathspecs: string[] },
  probeCwd: string,
  unverifiable: string | null,
): string {
  const target = d.pathspecs.length > 0 ? d.pathspecs.slice(0, 5).join(", ") : "(the whole working tree)";
  return [
    `⛔ Working-tree discard blocked — it would destroy uncommitted work (#709).`,
    `   Form: ${d.form}   Target: ${target}`,
    `   Checkout: ${probeCwd}`,
    ...(unverifiable ? [`   ⚠️ ${unverifiable} — failing closed.`] : []),
    `   The guard gates the EFFECT, not the verb: \`git checkout -- <path>\``,
    `   classifies as a plain path restore, so it used to run ungated in a`,
    `   linked worktree (where pi -p mutation-test fixers run) and in a CLEAN`,
    `   hub — the 2026-09-10 leaked-mutant path. This checkout carries`,
    `   uncommitted changes to tracked files that this command would revert.`,
    `   → Probe a mutation on a COPY, never in place (#664):`,
    `       cp <file> /tmp/probe-<file>   # mutate + test the copy, then rm it`,
    `       # or: git worktree add /tmp/probe <ref>, test inside it`,
    `   → Inspect first: git status --porcelain; git diff <path>.`,
    `   → Deliberate discard: set AGENT_ALLOW_MAIN_EDITS=1 (or`,
    `     ELDATO_ALLOW_MAIN_EDITS=1), or stamp the ~/.pi/agent/.allow-main-edits`,
    `     marker — both bypass this gate unchanged.`,
  ].join("\n");
}

/** Placeholder tokens declared by `xargs -I<tok>` / `-I <tok>` — the token is
 *  substituted into the child command at execution time, so it can carry the
 *  code the gate would otherwise walk (`printf … | xargs -I@ sh -c '@'`).
 *  Arbitrary by design, hence read from the invocation instead of `{}`
 *  (reviewer round-8b P1). */
function _wtXargsPlaceholders(command: unknown): string[] {
  const out: string[] = [];
  for (const m of String(command ?? "").matchAll(/(?:^|\s)-I\s*("[^"]*"|'[^']*'|\S+)/g)) {
    const tok = String(m[1] ?? "").replace(/^["']|["']$/g, "");
    if (tok && tok !== "-") out.push(tok);
  }
  return out;
}

/** True when `text` names a discard-family verb. The LONG verbs stay substring
 *  matches — they are distinctive, and a verb embedded in a PATH or FILENAME
 *  (`bash -c "$(cat /tmp/checkout-undo.sh)"`) is a real signal (reviewer
 *  round-8: word-anchoring them let that payload fail OPEN). `rm` is the one
 *  that needs a word boundary, or `format`/`normal`/`terraform` false-block an
 *  unresolvable payload that names no verb at all. */
const _MENTIONS_DISCARD_VERB = (text: unknown): boolean => {
  // ANSI-C quoting hides a verb from a raw-text scan (`bash -c $'git
  // \x63heckout -- f'` really discards), and the direct extractor already
  // decodes it — the fail-closed test must look at the same text
  // (reviewer round-8b).
  let s = String(text ?? "");
  try { s = ansiTranslate(s); } catch { /* malformed escape → raw text stands */ }
  return /(?:checkout|restore|switch|reset|read-tree|apply)|(?:^|[^A-Za-z0-9_-])rm(?:[^A-Za-z0-9_-]|$)/.test(s);
};

/** M5 gate: returns a block reason when `command` would discard uncommitted
 *  tracked work in the checkout it targets, else null. Covers the direct argv
 *  surface, interpreter-inline payloads (via allGitInvocations) and the
 *  script-file surface (`bash /tmp/restore.sh`) to a bounded depth. */
function _worktreeDiscardBlock(command: string): string | null {
  if (!classifierLoaded) return null; // degraded import → inert (module-load tripwire guards this)
  // Backslash-newline line continuations (`git \<LF> checkout -- f`) are joined
  // by the shell BEFORE it tokenizes — join them here too, so every textual arm
  // below sees the same command the shell runs (reviewer round-7 P1).
  command = joinContinuations(command);
  // Cheap superset pre-bail. NOT a raw-verb regex: the tokenizer resolves
  // quote-split verbs (`git ch'ec'kout -- x` ≡ `git checkout -- x`, reviewer
  // P1), so the only safe textual bail is "no `git` anywhere and no script to
  // read". The extractor is a pure string walk — the same cost the full
  // classifier already pays per bash call.
  //
  // Round-3 P1: the bail itself must not defeat the tokenizer — a quote/escape
  // or `$'…'`-concat name (`g"it"`, `'g'it`, `g\it`, `$'\x67it'`) has no
  // literal `git` word but DOES run git. Bail only when the command contains
  // no quoting/expansion character at all.
  let _scriptPath = extractScriptPath(command);
  // A FILE piped into a shell interpreter (`cat /tmp/undo.sh | bash`) carries no
  // literal `git` either — it must survive the bail so the script walk can read
  // it (reviewer round-5 P1).
  const pipesToShell = wtPipelineFeedsShell(command);
  // Runtime placeholder tokens declared by `xargs -I<tok>` — the token is
  // substituted at execution time, so it is never a literal path/spec (reviewer
  // round-9 P1).
  const xargsPlaceholders = _wtXargsPlaceholders(command);
  if (!/\bgit\b/.test(command) && !_scriptPath && !pipesToShell && !/['"\\$`]/.test(command)) return null;
  let direct: ReturnType<typeof extractWorkingTreeDiscards> = [];
  try { direct = extractWorkingTreeDiscards(command) ?? []; } catch { return null; }
  const sessionCwd = resolve(process.cwd());
  const execCwd = commandExecutionCwd(command, sessionCwd) ?? sessionCwd;

  // Executable-shebang script (`./undo.sh`, `/tmp/undo.sh`): extractScriptPath
  // only recognises interpreter WORDS (`bash x.sh`), so a directly-executed
  // script would otherwise never be read (reviewer P1).
  if (!_scriptPath) {
    const firstTok = String(command).trim().split(/\s+/)[0] ?? "";
    if (/^[.~]?\//.test(firstTok) || firstTok.startsWith("/")) {
      try {
        const p = realpathSync(resolve(execCwd, firstTok));
        const st = statSync(p);
        if (st.isFile() && (st.mode & 0o111) !== 0) _scriptPath = firstTok;
      } catch { /* nonexistent/non-executable — not a script invocation */ }
    }
  }

  // A script path that is not statically resolvable (`bash $S`, `cat x.sh |
  // sh`) cannot be read and walked — fail closed (reviewer round-5 P1).
  if (_scriptPath && /[$`]/.test(_scriptPath)) {
    return _worktreeDiscardBlockReason({ form: "script-indirection", scope: "all", pathspecs: [] }, execCwd, "the script path is not statically resolvable");
  }

  // Probe sets: the command itself, plus any script FILES it runs/sources
  // (`bash /tmp/restore.sh` is the documented backdoor shape — M4's
  // _backdoorBlock closes it only for hub sessions, so a worktree `pi -p`
  // child could otherwise hide a discard there). Bounded depth 3, 64KB per
  // file, cycle-guarded; a read failure is a no-op (the direct argv surface
  // still gates).
  //
  // `baseCwd` is the frame resolveInvocationTarget applies the invocation's own
  // cdChain to: for DIRECT argv invocations that is the SESSION cwd (the chain
  // is already expressed relative to it — passing the execution cwd
  // DOUBLE-APPLIED the cd and false-blocked `cd .. && bash noop.sh && git
  // checkout -- <clean file>`, reviewer P1). `writeCwd` (redirect targets) IS
  // the execution cwd.
  const sets: { discs: ReturnType<typeof extractWorkingTreeDiscards>; baseCwd: string; writeCwd: string; script: string | null }[] = [
    { discs: direct, baseCwd: sessionCwd, writeCwd: execCwd, script: null },
  ];
  try {
    const seen = new Set<string>();
    // Seeds: the resolved script path, plus any FILE piped into a shell
    // interpreter (`cat /tmp/undo.sh | bash`), which `extractScriptPath` cannot
    // see because the head of the line is not the interpreter (reviewer
    // round-5 P1).
    const seeds: string[] = [];
    if (_scriptPath) seeds.push(_scriptPath);
    const pipeSeg = String(command).split("|");
    const execPlaceholder = /(?:^|\s)(?:[\w./-]*\/)?(?:bash|sh|zsh|dash|ksh|ash|mksh)\s+(?:-[A-Za-z]+\s+)?\{/.test(String(command));
    if (pipeSeg.length > 1 && pipesToShell) {
      for (const tok of String(pipeSeg.slice(0, -1).join("|")).split(/\s+/)) {
        if (!tok || tok.startsWith("-") || /[$`*?]/.test(tok)) continue;
        try {
          const real = realpathSync(resolve(execCwd, tok));
          if (statSync(real).isFile() && statSync(real).size <= 64 * 1024) seeds.push(tok);
        } catch { /* not a readable file */ }
      }
    }
    // `printf 'git checkout -- f\n' | bash` feeds the shell CODE from a producer
    // the seed loop cannot resolve (it only seeds readable FILES). Fail closed
    // when the command names a discard-family verb (reviewer round-8 P1). A
    // genuine `cat undo.sh | bash` never reaches here (no verb in the text; the
    // file seed is what catches it).
    if (pipeSeg.length > 1 && pipesToShell && _MENTIONS_DISCARD_VERB(command)) {
      return _worktreeDiscardBlockReason({ form: "piped-shell-payload", scope: "all", pathspecs: [] }, execCwd, "a piped shell payload is not statically resolvable");
    }
    // `find <file> -exec sh {} \;` runs the file as a script (reviewer round-7
    // P2) — seed every existing file token of the command.
    if (execPlaceholder) {
      for (const tok of String(command).split(/\s+/)) {
        if (!tok || tok.startsWith("-") || /[$`*?]/.test(tok)) continue;
        try {
          const real = realpathSync(resolve(execCwd, tok));
          if (statSync(real).isFile() && statSync(real).size <= 64 * 1024) seeds.push(tok);
        } catch { /* not a readable file */ }
      }
    }
    let p: string | null = seeds.shift() ?? null;
    for (let depth = 0; depth < 3 && p; depth++) {
      let real: string;
      try { real = realpathSync(resolve(execCwd, p)); } catch { p = seeds.shift() ?? null; continue; }
      if (seen.has(real)) { p = seeds.shift() ?? null; continue; }
      seen.add(real);
      let content: string;
      try {
        if (!existsSync(real) || !statSync(real).isFile() || statSync(real).size > 64 * 1024) { p = seeds.shift() ?? null; continue; }
        content = readFileSync(real, "utf8");
      } catch { p = seeds.shift() ?? null; continue; }
      if (/(checkout|restore|switch|reset|show|cat-file|read-tree|rm)/.test(content)) {
        sets.push({ discs: extractWorkingTreeDiscards(content) ?? [], baseCwd: execCwd, writeCwd: execCwd, script: p });
      }
      p = extractScriptPath(content) ?? seeds.shift() ?? null;
    }
  } catch { /* script walk is best-effort — never false-block on its failure */ }

  // `eval '<payload>'` (reviewer P1): allGitInvocations does not walk eval
  // payloads, so extract them here (one level — a nested eval is a documented
  // residual). Round-8 P1: the arm also has to see the UNQUOTED variable form
  // (`eval $P`), and an unresolvable payload fails closed on the COMMAND's
  // verbs — `P='git checkout -- f'; eval "$P"` previously fell through at the
  // payload-scoped verb test and destroyed the file.
  for (const m of String(command).matchAll(/\beval\s+(\$)?(['"])([\s\S]*?)\2|\beval\s+(\S+)/g)) {
    const payload = m[1] ? ansiTranslate(m[3] ?? m[4] ?? "") : (m[3] ?? m[4] ?? "");
    const bare = payload.replace(/^["']|["']$/g, "");
    const vm = /^\$(\w+)$|^\$\{(\w+)\}$/.exec(bare);
    const name = vm?.[1] ?? vm?.[2];
    if (name) {
      const am = new RegExp(`(?:^|[;&\\s])${name}=("[^"]*"|'[^']*'|\\S+)`).exec(String(command));
      const val = am ? String(am[1]).replace(/^["']|["']$/g, "") : null;
      if (val && !/[$`]/.test(val)) {
        sets.push({ discs: extractWorkingTreeDiscards(val) ?? [], baseCwd: execCwd, writeCwd: execCwd, script: null });
        continue;
      }
    }
    if (/[$`]/.test(payload)) {
      // Still opaque (env-fed `$P`, `$(…)`): the `-c` arm's contract — fail
      // closed when the command names a discard verb.
      if (_MENTIONS_DISCARD_VERB(command)) {
        return _worktreeDiscardBlockReason({ form: "eval-payload", scope: "all", pathspecs: [] }, execCwd, "an `eval` payload is not statically resolvable");
      }
      continue;
    }
    if (!_MENTIONS_DISCARD_VERB(payload)) continue;
    sets.push({ discs: extractWorkingTreeDiscards(payload) ?? [], baseCwd: execCwd, writeCwd: execCwd, script: null });
  }

  // `xargs -I<tok> … <shell> -c '<tok>'` — the placeholder token is ARBITRARY and
  // is substituted from the pipe/input at execution time, so the payload cannot
  // be resolved statically. The extractor cannot even see this payload: the
  // segment head is `xargs`, which is not a spawner word, so the whole segment
  // is skipped. Check the invocation pair directly and fail closed (reviewer
  // round-8b P1).
  if (xargsPlaceholders.length > 0 &&
      /(?:^|[\s;|&(])(?:[\w./-]*\/)?(?:bash|sh|zsh|dash|ksh|ash|mksh)\s+(?:-[A-Za-z]*c[A-Za-z]*|--command)(?![A-Za-z])/.test(String(command))) {
    return _worktreeDiscardBlockReason({ form: "interpreter-c-payload", scope: "all", pathspecs: [] }, execCwd, "an interpreter `-c` payload is a runtime placeholder");
  }

  // Interpreter `-c` payloads: `allGitInvocations` resolves a LITERAL payload,
  // but an opaque one (`bash -c "$S"`) yields no invocation at all. Resolve a
  // same-command assignment (`S='git checkout -- f'; bash -c "$S"`) and probe
  // it; anything that is STILL opaque fails closed when the command mentions a
  // discard-family verb.
  //
  // The verb test is deliberately over the WHOLE command, not just the payload
  // segment (reviewer round-7, second pass): the payload's value can come from
  // a producer the walker cannot follow — `S=$(printf 'git checkout -- f')`,
  // `printf -v S '%s' 'git checkout -- f'`, `read -r S <<<'git checkout -- f'`,
  // `eval "S='git checkout -- f'"`, `printf … > /tmp/p.sh; bash -c "$(cat
  // /tmp/p.sh)"` — and payload-scoping let every one of those destroy WIP. This
  // is the pre-round-7 contract: an unresolvable opaque payload sharing a
  // command with a discard verb is exactly the case the arm exists for. The
  // cost is a conservative block on `bash -c "$L" && git checkout main`; that
  // ambiguity is the arm's documented residual, not a false positive to trade
  // real discards for.
  for (const pl of wtShellInlinePayloads(command)) {
    // A RUNTIME placeholder inside the payload (`-I{}` is by far the common
    // form) can never be resolved statically (reviewer round-8 P1).
    if (/\{\}/.test(pl.text)) {
      return _worktreeDiscardBlockReason({ form: "interpreter-c-payload", scope: "all", pathspecs: [] }, execCwd, "an interpreter `-c` payload is a runtime placeholder");
    }
    if (!pl.opaque) {
      // A literal payload that runs/sources a SCRIPT FILE seeds the bounded
      // walk (`bash -c 'source /tmp/undo.sh'`, round-7 P1). Outer quotes are
      // stripped first — `extractScriptPath` tokenizes the payload as a COMMAND,
      // and a leading `'` would make `'source` an unrecognised head.
      try {
        const sp = extractScriptPath(pl.text.replace(/^["']|["']$/g, ""));
        if (sp && !/[$`]/.test(sp)) sets.push({ discs: extractWorkingTreeDiscards(readFileSync(resolve(execCwd, sp), "utf8")) ?? [], baseCwd: execCwd, writeCwd: execCwd, script: sp });
      } catch { /* missing/unreadable — the direct surface still gates */ }
      continue;
    }
    const bare = pl.text.replace(/^["']|["']$/g, "");
    // Opaque, but its ONLY substitution reads a statically named FILE
    // (`bash -c "$(cat /tmp/undo.sh)"`): seed the bounded script walk from that
    // file rather than relying on the verb appearing in the command text
    // (reviewer round-8b P1). Anything the walk cannot resolve still falls
    // through to the verb test below.
    const catM = /^\$\(\s*(?:cat|bat)\s+([^\s)$]+)\s*\)$|^`cat\s+([^`]+)`$/.exec(bare);
    const catPath = catM?.[1] ?? catM?.[2];
    if (catPath && !/[$`*?]/.test(catPath)) {
      try {
        const real = realpathSync(resolve(execCwd, catPath));
        if (statSync(real).isFile() && statSync(real).size <= 64 * 1024) {
          sets.push({ discs: extractWorkingTreeDiscards(readFileSync(real, "utf8")) ?? [], baseCwd: execCwd, writeCwd: execCwd, script: catPath });
          continue;
        }
      } catch { /* missing/unreadable → the verb test still applies */ }
    }
    const vm = /^\$(\w+)$|^\$\{(\w+)\}$/.exec(bare);
    const name = vm?.[1] ?? vm?.[2];
    if (name) {
      const am = new RegExp(`(?:^|[;&\\s])${name}=("[^"]*"|'[^']*'|\\S+)`).exec(String(command));
      if (am) {
        const val = String(am[1]).replace(/^["']|["']$/g, "");
        // A value that is ITSELF opaque (`S=$(printf 'git checkout -- f')`,
        // `read`-fed, `printf -v`-fed) is NOT resolved — falling through to the
        // fail-closed test is the whole point. Only a statically readable value
        // is probed and short-circuits (reviewer round-7, second pass).
        if (!/[$`]/.test(val)) {
          sets.push({ discs: extractWorkingTreeDiscards(val) ?? [], baseCwd: execCwd, writeCwd: execCwd, script: null });
          continue;
        }
      }
    }
    if (_MENTIONS_DISCARD_VERB(command)) {
      return _worktreeDiscardBlockReason({ form: "interpreter-c-payload", scope: "all", pathspecs: [] }, execCwd, "an interpreter `-c` payload is not statically resolvable");
    }
  }

  if (sets.every((s) => s.discs.length === 0)) return null;

  for (const set of sets) {
    // The `cat-file-revert` form (`git show HEAD:x > x`) needs the source's
    // bash WRITE targets (pure string walk) to find where the content lands.
    let writeTargets: string[] = [];
    if (set.discs.some((d) => d.form === "cat-file-revert")) {
      try {
        const src = set.script === null ? command : readFileSync(resolve(execCwd, set.script), "utf8");
        writeTargets = extractBashWriteTargets(src, set.writeCwd).map((t) => resolve(set.writeCwd, t.resolvedPath));
      } catch { /* best-effort — a miss only means no extra block */ }
    }

    for (const d of set.discs) {
      // Fail closed on anything whose blast radius is not statically known:
      // `--pathspec-from-file` (the list lives in a FILE), an unresolvable
      // `$VAR`/backtick pathspec, or an xargs/find `-exec` placeholder.
      const unresolvable = (d as { unverifiable?: boolean }).unverifiable === true ||
        d.pathspecs.some((p) => /[$`]/.test(String(p))) ||
        // Brace expansion (`git checkout -- {dirty,clean}.txt`) is expanded by
        // the SHELL; the probe would pass the literal token to git, match
        // nothing, read the tree as clean and release the discard (reviewer
        // round-8 P2). Not statically resolvable → fail closed.
        d.pathspecs.some((p) => /[{}]/.test(String(p))) ||
        d.pathspecs.some((p) => xargsPlaceholders.includes(String(p).replace(/^["']|["']$/g, ""))) ||
        d.pathspecs.some((p) => wtIsPlaceholderPathspec(p));
      if (unresolvable) {
        return _worktreeDiscardBlockReason(d, execCwd, "the target pathspec is not statically resolvable");
      }

      let probeCwd: string;
      let scope: { scope: string; pathspecs: string[]; fromTree?: boolean } = d;
      if (d.form === "cat-file-revert") {
        const lands = writeTargets.filter((t) => d.pathspecs.some((p) => resolve(set.writeCwd, p) === t));
        if (lands.length === 0) continue; // the committed content is not redirecting onto its own path
        probeCwd = set.writeCwd;
        scope = { scope: "paths", pathspecs: lands.map((t) => relative(set.writeCwd, t) || "."), fromTree: true };
      } else {
        let eff: { effectiveCwd: string; worktreePath?: string | null } | null = null;
        try { eff = resolveInvocationTarget(d.inv, sessionCwd, set.baseCwd); } catch { eff = null; }
        if (eff === null) {
          return _worktreeDiscardBlockReason(d, set.baseCwd, "the invocation's effective repo could not be resolved (unresolvable cd/$VAR)");
        }
        probeCwd = eff.effectiveCwd;
        // `--work-tree=<dir>` / a worktree git-dir targets a DIFFERENT working
        // tree than the cwd (reviewer P2): probe the work-tree when it exists.
        const wtHint = (d.inv as { workTreeHint?: string | null } | null)?.workTreeHint;
        if (wtHint && wtHint !== "\u0000") {
          try {
            const wtReal = realpathSync(resolve(probeCwd, wtHint));
            if (existsSync(wtReal)) probeCwd = wtReal;
          } catch { /* unresolvable work-tree → keep the cwd probe */ }
        }
      }
      // A single bare `git checkout <token>` is a REF SWITCH when the token
      // names one and a PATH RESTORE otherwise (`git checkout f.txt` reverts
      // f.txt — the incident verb's twin without `--`, reviewer round-4 P1).
      // `git checkout -f <token>` inverts the default: a ref is a FORCED switch
      // (destroys all local changes → keep whole-tree scope), a path is a
      // single-path restore (reviewer round-5 P2).
      if ((d as { ambiguousRef?: boolean }).ambiguousRef && d.pathspecs.length === 1) {
        let isRef = false;
        try {
          execFileSync("git", ["rev-parse", "--verify", "--quiet", `${d.pathspecs[0]}^{commit}`],
            { cwd: probeCwd, stdio: ["ignore", "ignore", "ignore"] });
          isRef = true;
        } catch { /* not a ref → treat as a path */ }
        const refIsAll = (d as { refIsAll?: boolean }).refIsAll === true;
        if (isRef && !refIsAll) continue; // a plain branch/tag switch, not a discard
        if (!isRef && refIsAll) scope = { scope: "paths", pathspecs: d.pathspecs, fromTree: false };
      }
      // `git checkout <tok> <paths>`: the first positional is a tree-ish ONLY
      // when it names a commit; otherwise EVERY positional is a pathspec
      // (reviewer round-7 P1).
      if ((d as { ambiguousTree?: string }).ambiguousTree && (d as { allPathspecs?: string[] }).allPathspecs) {
        let isRef = false;
        try {
          execFileSync("git", ["rev-parse", "--verify", "--quiet", `${(d as { ambiguousTree?: string }).ambiguousTree}^{commit}`],
            { cwd: probeCwd, stdio: ["ignore", "ignore", "ignore"] });
          isRef = true;
        } catch { /* not a ref → all positionals are pathspecs */ }
        if (!isRef) scope = { scope: "paths", pathspecs: (d as { allPathspecs?: string[] }).allPathspecs ?? d.pathspecs, fromTree: false };
      }
      const dirty = _discardStatusPorcelain(probeCwd, scope);
      if (dirty === true) return _worktreeDiscardBlockReason(d, probeCwd, null);
      if (dirty === null) return _worktreeDiscardBlockReason(d, probeCwd, "the target checkout's status could not be read");
    }
  }
  return null;
}

// Script-backdoor closure (Slice E): the documented escape
// (`write /tmp/x.sh` + `bash /tmp/x.sh`) is closed by gating the script's git
// content with the SAME recovery allowlist — a script that performs a
// non-sanctioned git mutation is blocked. Recovery scripts (hub-worktree.sh:
// fetch + worktree add) keep working. Returns a block reason or null.
function _backdoorBlock(command: string, execCwd?: string): string | null {
  try {
    if (isWorktreeCwdWrite(resolve(process.cwd()))) return null; // worktree sessions are isolated
    // #627: non-shell CODE interpreters (python -c / python <file> / node -e /
    // ruby -e / perl -e / php -r / …) carry git payloads past the SHELL-only
    // script gate — the payload is quoted/arrayed, so evaluateHubGateWithTargets
    // sees no git token either. Resolve the code payload BEFORE
    // extractScriptPath: the latter's `/abs/path` rule would resolve
    // `/usr/bin/python3` and read the interpreter BINARY as a script.
    // codePayloadGitVerdict shares the script surface's allowlist + per-
    // invocation target resolution, so read-only and worktree-targeted git ops
    // from code keep working (false-blocks stay exceptional).
    const code = extractCodePayload(command);
    // #627 scope: INLINE interpreter payloads (`python -c`, `node -e`,
    // `ruby -e`, `perl -e`, `php -r`, `pwsh -Command`, …). File / module /
    // stdin payloads are NOT content-gated here — reading an arbitrary
    // repo script (e.g. the guard's own `node test.mjs`) against the
    // hub-recovery allowlist false-blocks legitimate test fixtures that run
    // git in temp repos, which is the same semantics the shell surface has
    // (#1484). File/shebang/module/stdin forms are documented residuals
    // (README backdoor table + tracked follow-ups).
    if (code && code.kind === "inline") {
      const base = execCwd ? resolve(execCwd) : resolve(process.cwd());
      const content = code.value ?? "";
      {
        const branch = getMainCheckoutBranch();
        // #627 reviewer P2: an opaque inline payload (`python3 -c "$PYCODE"`,
        // `python3 -c "$(cat code.py)"`) is not statically resolvable. Mirror
        // the shell surface's round-11 `sh -c '$VAR'` arm: a valid payload
        // variable whose command assigns a git-bearing value is unverifiable →
        // block. A non-git command string still allows (no blanket block).
        const opaqueInline =
          /^\s*\$(?:\{?[A-Za-z_][A-Za-z0-9_]*\}?|\([\s\S]*\)|\[[\s\S]*\])\s*$/.test(content);
        const verdict = opaqueInline
          ? (/\bgit\b/.test(command) ? "block" : "allow")
          : codePayloadGitVerdict(content, branch, base, resolve(process.cwd()));
        if (verdict === "block") {
          return [
            `⛔ Script execution blocked — git-bearing code payload in the shared main checkout (#627).`,
            `   The non-shell interpreter backdoor (python -c, node -e, ruby -e,`,
            `   perl -e, php -r, pwsh -Command) is closed: the inline payload`,
            `   contains a non-sanctioned git operation.`,
            `   → Run the git commands directly (recovery: git checkout main && git pull --ff-only),`,
            `     or work in an isolated worktree:`,
            `     bash scripts/checkout-hygiene/hub-worktree.sh <branch>`,
          ].join("\n");
        }
      }
      return null; // resolved inline code invocation — no shell script to gate
    }
    if (code) return null; // non-inline code form — out of #627 scope (residual)
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
// IMMUTABLE — the own-baseline RENAME re-baseline updates only `.branch` (#376:
// the ceremony return-to-original carve-out switches back to `original`,
// provably the session's own starting state). In-hub create-new no longer
// re-baselines (#626 blocks it — worktree ceremonies never reach decideM3).
// A lock-contended start (pendingBaseline → first-tool_call record) sets
// original null → the #376 carve-out fails closed (the tree may already sit on
// ANOTHER session's branch — not provably own).
const baselines = new Map<number, { repoKey: string; branch: string | null; head: string; original: string | null }>();
const warnedDeviations = new Map<number, Set<string>>();
const pendingBaseline = new Set<number>(); // lock contended at session_start → record on first tool_call
// Branches THIS pid renamed its own baseline to via the M3 rename carve-out,
// scoped by
// repoKey (#376 review fold-in): their LOCAL deletion stays allowed after the
// ceremony return re-bases the baseline to main (git refuses deleting a branch
// checked out anywhere, so a pid-owned local delete is collision-free). Scoped
// per repo and marked only in the BASELINE repo, so an owned name from one
// agent-infra checkout can never authorize a delete in another (review fold-in).
// Never seeded from session state. (create-new is no longer marked — in-hub
// create-new is blocked since #626 and never re-baselines.)
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
    // #628 reviewer P3: the new-file volume counter is per-SESSION state — a
    // resumed/reused process must not inherit a prior session's count.
    hubNewFileCounts.clear();
    warnedNewFileTargets.clear();
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
        // was clean. Same-checkout writes now gate on the command's EFFECT for
        // a session's own hub too: a TRACKED hub-main write blocks whether the
        // hub is clean or disordered (#625 — the old clean-hub early-return let
        // a compound `printf … >> MEMORY.md && git add && git commit && git
        // push` through); own-main untracked/NEW writes stay free, so running
        // unconditionally costs only the pure string walk on write-free
        // commands. Under an active
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
              // #628: volume policy — warn at write time for EVERY new hub file
              // (all paths, not just the #350 WIP patterns), escalate past the
              // budget, BLOCK past the hard cap. The counter is per-session and
              // only advances while the hub is disordered (this branch).
              const pid = process.pid;
              const newFileCount = (hubNewFileCounts.get(pid) ?? 0) + 1;
              hubNewFileCounts.set(pid, newFileCount);
              const volume = hubNewFileVolumeVerdict(newFileCount);
              if (volume === "block") {
                return {
                  block: true,
                  reason: [
                    `⛔ New-file write blocked — new-file cap exhausted in a disordered hub (#628).`,
                    `   This session has created ${newFileCount - 1} new files directly in the`,
                    `   shared main checkout while it is OFF-MAIN or DIRTY (cap ${HUB_NEW_FILE_BLOCK_CAP}).`,
                    `   New files are additive (they cannot collide with a sibling's uncommitted`,
                    `   work) but unbounded accumulation is the #347 amplifier, and the hub's`,
                    `   only legal state is main+clean.`,
                    `   → Recover first: cd <repo> && git checkout main && git pull --ff-only`,
                    `   → Do feature work in a worktree: bash scripts/checkout-hygiene/hub-worktree.sh <branch>`,
                  ].join("\n"),
                };
              }
              _maybeWarnHubNewFile(targetPath, newFileCount, volume);
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

    // ── Escape marker (#207): the guard-stamped bash route is the ONLY
    // minting path (#620) ──
    // Runs BEFORE the hatch/marker bypass so a marker touch from ANY session
    // — the AGENT_ALLOW_MAIN_EDITS=1 env hatch included — is guard-stamped
    // {session_id, reason, ts} + audited here instead of minting an
    // un-stamped, un-audited marker file (the 2026-09-08 evidence: a 3-line
    // plain-text marker outside the gate_bypass audit trail). M4 ran above and
    // a bare `touch <marker>` is pure non-git → never M4-blocked, so F10c (a
    // BLOCKED command never stamps) still holds; a compound
    // `touch … && git …` is not a marker command (single-command contract)
    // and stays git-classified first.
    if (isBash) {
      const command = (event.input as { command?: string }).command ?? "";
      if (isAllowMarkerCommand(command, homedir())) {
        _stampMarker(_markerPath(), _currentSessionId(_ctx), extractMarkerReason(command));
        return undefined;
      }
    }
    // The write/edit tool can never mint the marker either — a write to the
    // marker path is blocked in EVERY session state (hatch / active-marker /
    // worktree / agent-infra): an agent could `write` a stamped-looking JSON
    // straight to the file with no gate_bypass audit event. Route creation
    // through the bash touch path (guard-stamped + audited).
    if (isWrite || isEdit) {
      const targetPath = (event.input as { path?: string }).path ?? "";
      if (resolve(process.cwd(), targetPath) === resolve(_markerPath())) {
        return {
          block: true,
          reason: [
            "⛔ The escape-marker file must be created via a bash `touch` command,",
            "   not the write/edit tool — the guard stamps {session_id, reason, ts}",
            "   and audits the creation only on the bash route (#207).",
          ].join("\n"),
        };
      }
    }

    // ── bash: branch-ownership + destructive git ──
    // Marker OR branch covers bash + write + edit in one check point (#266).
    if (_isAllowMainEdits() || readAllowMarkerState(_markerPath(), _currentSessionId(_ctx))) {
      return undefined;
    }
    if (isBash) {
      const command = (event.input as { command?: string }).command ?? "";
      // ── M5 (#709): effect-keyed working-tree-discard gate ──
      // Runs BEFORE the degradation/full classifier arms and BEFORE the
      // worktree exemptions below, so a discard is caught whether or not
      // branch-ownership loaded, and in a linked worktree as well as the hub.
      // It sits AFTER the env/marker hatch return above, so both hatches
      // bypass it unchanged.
      const discardBlock = _worktreeDiscardBlock(command);
      if (discardBlock) return { block: true, reason: discardBlock };
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
            // #598: branches this pid renamed its own baseline to are owned
            // (the #543/#588 ownership check). The read
            // is keyed on the MUTATION's repo (muEff.repoKey): _markOwned
            // writes under baseline.repoKey when the baseline repo IS the
            // mutation repo; with NO baseline, under muEff.repoKey; a baseline
            // in a DIFFERENT repo records nothing (repo-scoped — the rename
            // _markOwned call below guards on repoKey equality).
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
            // Synchronous re-baseline: the own-baseline RENAME (create-new
            // never re-baselines since #626 — in-hub create-new is blocked)
            // adopts the new branch NOW — the next tool_call emits ZERO M1
            // warns (AC3). Record the renamed-to branch — scoped to the
            // BASELINE repo — so its post-ceremony LOCAL delete is still
            // allowed after the #376 return re-baselines to the original
            // (#376 review fold-in).
            if (branchOp.op === "rename" && branchOp.to) {
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
      // semantics — the hatch is a full bypass). Marker-command stamping moved
      // ABOVE this point (the pre-bypass section, #620): a marker touch from any
      // session — env hatch included — is stamped + audited there, so a bare
      // `touch <marker>` can never fall through to mint un-stamped here.
      if (allowActive) return undefined;

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
          // #376 review fold-in: branches this pid renamed its own baseline
          // to (scoped to THIS repo) stay locally deletable after the ceremony
          // return re-bases the baseline (own-branch hygiene). create-new is
          // never marked — it is blocked since #626 and never re-baselines.
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

    // (Marker-path write/edit block moved to the pre-bypass section above —
    // #620: the write tool can never mint the escape marker in ANY session
    // state; the audited bash touch route is the only mint.)

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
    // is the session's private working subtree ONLY when the SESSION is a
    // NON-main checkout (worktree/private — tree is session-private by
    // construction). A MAIN-rooted session's nested checkouts (submodule /
    // vendored copy under a hub) are shared with every other session of that
    // hub and stay frozen — the exemption is capped at non-main sessions so an
    // ancestor MAIN (a parent repo over sibling hubs) can never lift the
    // cross-hub freeze (cycle-3 B-1; the real sibling-hub vectors — the
    // GitHub parent dir, other repos' main checkouts — are never under a
    // worktree's private tree either).
    if (sessionCheck && !sessionCheck.isMain && sessionTop && tgtCheck.top.startsWith(sessionTop + "/")) {
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
