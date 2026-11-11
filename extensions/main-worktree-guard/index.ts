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
// recovers with the marker but cannot resume feature work in the hub). M4's
// recovery WINDOW is the part the marker opens: the named-path working-tree
// restore family (`git restore <path>` / `git checkout -- <path>`) classifies
// as recovery under either hatch, because a dirty hub cannot be cleared by the
// branch route M4 used to prescribe alone (#1484; measured 2026-11-02 — a hub
// carrying one truncated tracked file answered every restore with
// `git checkout main`, a no-op on a dirty tree, and stayed dirty ~12h). Every
// feature-work verb stays blocked under the marker: no commit, no branch
// create/force, no foreign push, and `checkout -- .` (whole-tree wipe) is
// refused — a deliberate discard must name its paths. There
// is NO auto-bypass: the guard blocks every time, so a rogue/parallel agent
// cannot retry its way past it.
//
// Degradation contract:
//  - classify-git.mjs TOTAL load failure → the bash git guard degrades to
//    non-blocking — one load-time warning, then every command passes silently
//    (fail-safe, never false-blocks) — AND the write/edit gate fails OPEN. (A
//    PARTIAL abort — the #744 shape — is different: it keeps whatever was bound
//    before the abort point, so the gates bound earlier keep working.)
//    The write/edit gate's target classification comes from the same import:
//    `resolveTargetCheckout` stays `() => null` and `hasDotGitAncestor` stays
//    `() => false`, so `_checkoutOf` returns null and the gate takes its
//    "!tgtCheck → isolated by construction" branch and ALLOWS the write. The
//    inert defaults are deliberate (a failed import must never false-block),
//    but the consequence is that a load failure is a SILENT LOSS OF
//    ENFORCEMENT, not a safe mode. Tracked as #761.
//  - branch-ownership.mjs load failure → M1/M2/M3 are OFF (one-time warn) and
//    the guard falls back to the frozen-legacy classifier for EVERY repo — no
//    agent-infra exemption (#615); write/edit never depends on THIS module (its
//    classify-git dependency is the bullet above, #761).
//  - isWorktreeCwd defaults are SPLIT: the bash path fails OPEN (() => true —
//    a worktree lookalike is treated as isolated), the write/edit path fails
//    CLOSED (() => false — an unverifiable SESSION cwd is treated as main and
//    blocked). This fixes the latent fail-open at the old shared default.
//    Note this covers the SESSION-cwd checks only — the TARGET-classification
//    path (`_checkoutOf`) is a separate input, and it is the one that fails
//    open when the import degrades (first bullet, #761).
// The TTL'd file-based escape marker (~/.pi/agent/.allow-main-edits, #207)
// allows a deliberate mid-session escalation — see README.md.

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { isToolCallEventType } from "@earendil-works/pi-coding-agent";
import { execSync, execFileSync } from "node:child_process";
import { resolve, dirname, join, relative, sep } from "node:path";
import { realpathSync, existsSync, lstatSync, statSync, readdirSync, readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { fileURLToPath } from "node:url";
import { createHash } from "node:crypto";
import { isPrintMode } from "../shared/print-mode.js";
import { appendJsonl } from "../shared/audit-log.js";

// Shared destructive-git rules (also used by test.mjs). If the import fails
// TOTALLY (jiti resolution edge case), the bash guard degrades to non-blocking
// and the write/edit gate fails OPEN — see the degradation contract above,
// #761. (A partial abort can leave the write/edit classification bound: its
// targets are #32/#34/#35-37 of 37, so an abort at the tail keeps it live.)
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
// #1129: the exemption's root anchor (pure fn in classify-git). Fail-safe
// default null → the inline realpath-first fallback runs; never null-holes the
// exemption (a stale module must not silently disable it) and never throws.
let _frameworkRootFromModuleUrl: ((moduleUrl: string) => string) | null = null;
// #1139 (review cycle-2 P1): the pipe-seed walk's tokenizer. Fail-safe default
// is the previous whitespace split (a stale module without `wtShellWords` keeps
// today's quote-blind behaviour rather than seeding nothing at all — fewer seeds
// would be the fail-OPEN direction); the same commit ships both halves, and
// test.mjs pins the export so the skew fails a test instead of silently
// reverting.
let wtShellWords: (s: string) => string[] = (s) => String(s).split(/\s+/);
// #1484 M4 hub-state gate + script-backdoor closure. Fail-safe defaults: every
// decision degrades to inactive/allow so a failed import NEVER false-blocks
// (the git commands were allow-listed before M4; the guard stays permissive).
let readHubDisorder: (cwd: string, opts?: { skipWorktree?: boolean }) => { disorder: string | null; branch: string | null; path: string | null; dirtyPaths: number } = () => ({ disorder: null, branch: null, path: null, dirtyPaths: 0 });
let evaluateHubGateWithTargets: (command: string, currentBranch: string | null, sessionCwd?: string, checkedOutBranches?: Set<string> | null, hubContext?: { disorder: string | null; branch: string | null; path: string | null; dirtyPaths: number } | null, opts?: { escapeActive?: boolean; hatchActive?: boolean } | null) => { verdict: "non-git" | "allowed" | "recovery" | "block"; reason?: string; exempted?: boolean } = () => ({ verdict: "non-git" });
let commandExecutionCwd: (command: string, sessionCwd?: string) => string | null = () => null;
let resolveTargetTopLevel: (targetPath: string, cwd?: string) => string | null = () => null;
// #1919: refuse a `git worktree add|move` whose target would land INSIDE a git
// checkout where git does not ignore it — the state that leaves the hub reading
// DIRTY forever while M4 refuses every verb that could move the worktree out.
// Fail-safe default: inert (null) — a failed import must never false-block a
// legitimate worktree creation.
let nestedWorktreeTargetViolation: (command: string, sessionCwd?: string) => string | null = () => null;
// #1919: the quote/comment-AWARE heredoc stripper the M5 discard extractor already
// uses. Fail-safe default: identity — a failed import must never HIDE a command
// (an inert stripper means the gate inspects the raw text, i.e. today's
// behaviour, never a blind spot).
let stripHeredocData: (text: string, codeBodies?: unknown[] | null) => string = (t) => t;
// #618/#621: TARGET-aware checkout classification (the shared mechanism both
// hub-write issues consume). Fail-safe defaults: inert (null/[]) so a failed
// import NEVER false-blocks — the write gates degrade to today's behavior.
let resolveTargetCheckout: (targetPath: string, cwd?: string) => { top: string; isMain: boolean } | null = () => null;
let trackedRelsIn: (repoTop: string, rels: string[]) => string[] = () => [];
let hasDotGitAncestor: (p: string) => boolean = () => false;
// #608: the classifier's OWN local-branch-delete name extractor (the whole
// `-d`/`-D`/`--delete` family incl. clusters and value-swallowing flags). Used
// to spend the pid-owned claim for EVERY branch a command deletes, not just the
// first invocation's. Fail-safe default: null — a failed import means no claim
// is spent, which is the pre-#608 behaviour and can never false-block.
let branchDeleteNames: (verb: string, args?: string[]) => string[] | null = () => null;
let extractScriptPath: (command: string) => string | null = () => null;
let extractScriptArgs: (command: string, scriptPath: string) => string[] = () => [];
let scriptGitVerdict: (path: string, currentBranch: string | null, executionCwd?: string, sessionCwd?: string, scriptArgs?: string[] | null, opts?: { viaInterpreter?: boolean }) => "allow" | "block" = () => "allow";
// #1485: does the invocation hand the file to an INTERPRETER (text) or execute
// it directly (a binary)? Default TRUE (walk it) when the module is degraded —
// the fail-closed direction, mirroring the other load-time defaults.
let scriptIsInterpreted: (command: string, scriptPath: string) => boolean = () => true;
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
// #3243 — the pipeline SPLIT, quote/extglob-aware. Fail-safe default = the old
// blind `split("|")` (it can only OVER-report, i.e. stay fail-closed).
let wtSplitPipeline: (cmd: string) => string[] = (cmd: string) => String(cmd ?? "").split("|");
// #3243 — is a command-position word shaped like a PATH (rather than a program's
// text that happens to contain a `/`)? Fail-safe default `true` preserves the
// previous over-blocking behaviour if the classifier import degrades.
let wtIsPathShapedScriptWord: (word: unknown) => boolean = () => true;
let wtShellInlinePayloads: (cmd: string) => { text: string; opaque: boolean; at?: number }[] =
  // FAIL-SAFE fallback, not inert: a stale/partial classify-git.mjs (the export
  // missing while `classifierLoaded` is still true) must not silently delete the
  // opaque `-c` arm. This is the same quote-aware scan, minus the spawner/keyword
  // head analysis — it can only OVER-report, which keeps the arm fail-closed.
  // `at` is the same own-offset the real tokenizer reports (review round-3 G1);
  // a payload it cannot place is -1, which the arm treats as UNRESOLVED.
  (cmd: string) => {
    const out: { text: string; opaque: boolean; at: number }[] = [];
    const re = /(?:^|[\s;&|(])(?:[\w./-]*\/)?(?:bash|sh|zsh|dash|ksh|ash|mksh|oksh)\s+(?:-[A-Za-z]*c[A-Za-z]*|--command)\s+("[^"]*"|'[^']*'|\S+)/g;
    for (const m of String(cmd ?? "").matchAll(re)) {
      const t = m[1] ?? "";
      const at = m.index === undefined ? -1 : m.index + m[0].length - t.length;
      out.push({ text: t, opaque: /[$`]/.test(t), at });
    }
    return out;
  };
let joinContinuations: (cmd: string) => string = (c: string) => String(c ?? "");
let ansiTranslate: (s: string) => string = (s: string) => String(s ?? "");
// #3444: the REMOTE-EXEC boundary (cmux vm exec <vm> -- … / ssh <host> … /
// docker exec <c> …). Fail-safe default = IDENTITY: a stale/partial
// classify-git.mjs must leave every local gate exactly as strict as it is today
// rather than letting an undefined call throw inside the tool hook (which aborts
// the bash call) — the same skew contract as the #709/#627 bindings above.
let maskRemoteExecPayloads: (command: string) => string = (c: string) => String(c ?? "");
// #437 (C): bash-write gate for TRACKED hub files in a DISORDERED hub (pure
// intersect of bash-write candidates with index-tracked rels). Fail-safe
// default: inert (null) — a failed import NEVER false-blocks (same contract
// as the #350 warn helpers; the gate is opt-in by explicit call only).
let classifierLoaded = false;
// #853: WHAT a degraded load must not stay silent about. `classifierLoaded === false` already
// means every binding above is a fail-safe stub; these carry the REASON to the two surfaces a
// session cannot miss — the startup self-test at `session_start` and the durable audit trail.
let _classifierLoadFailure: string | null = null;
const _classifierDegradedPids = new Set<number>();
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
// #1484: ONE three-shape dirty-hub recovery text, shared by every block message
// (M4's classifier reason and this file's write/edit + bash-write surfaces) so
// the advice cannot drift from the enforcement.
let hubDirtyRecoveryLines: (hubContext?: { disorder?: string | null } | null, hatchActive?: boolean) => string[] = () => [];
let isRepoSelectingEnvKey: (k: string) => boolean = () => false;
// Round 11 (P2): the REAL hatch state for the CURRENT tool call, resolved with the
// ctx session id (not the env-only form). `_hubWriteRecoverLines` used to derive
// it itself via `_currentSessionId(undefined)`, which is empty in production (pi
// sets PI_SESSION_ID only in bash CHILDREN), so the hatch-active paragraph was
// unreachable on the write/edit, bash-write and inline-payload surfaces.
let _currentHatchActive = false;
try {
  ({ classifyGitCommand, classifyGitCommandDetailed, isWorktreeCwd,
     extractPushDeleteBranch, wholeCommandDeleteTargets, getWorktreeBranches, isBranchInMainCheckout,
     getMainCheckoutBranch, isAgentInfraRepo, ALLOW_MAIN_EDITS_MARKER_TTL_MS,
     isAllowMarkerActive, isAllowMarkerPath, isAllowMarkerCommand,
     extractMarkerReason, parseMarkerContent, isAllowMarkerRealpath,
     hubDirtyRecoveryLines, isRepoSelectingEnvKey,
     readAllowMarkerState, readHubDisorder,
     extractScriptPath, scriptGitVerdict, scriptIsInterpreted, evaluateHubGateWithTargets,
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
  if (typeof _m5.wtSplitPipeline === "function") wtSplitPipeline = _m5.wtSplitPipeline;
  if (typeof _m5.wtIsPathShapedScriptWord === "function") wtIsPathShapedScriptWord = _m5.wtIsPathShapedScriptWord;
  if (typeof _m5.wtShellInlinePayloads === "function") wtShellInlinePayloads = _m5.wtShellInlinePayloads;
  // #3444: the remote-exec mask. Namespace read + typeof guard for the same
  // skew reason as #709/#627 — a stale module leaves the IDENTITY default, which
  // keeps today's (strict) behaviour instead of throwing in the hook.
  if (typeof _m5.maskRemoteExecPayloads === "function") maskRemoteExecPayloads = _m5.maskRemoteExecPayloads;
  if (typeof _m5.joinContinuations === "function") joinContinuations = _m5.joinContinuations;
  // #608: namespace read for the same reason as #709/#627 above (the
  // destructuring target list is pinned by test-module-load.mjs Part A).
  if (typeof _m5.branchDeleteNames === "function") branchDeleteNames = _m5.branchDeleteNames;
  if (typeof _m5.ansiTranslate === "function") ansiTranslate = _m5.ansiTranslate;
  // #1919: read from the namespace for the same reason as #709/#627 above — the
  // destructuring target list is pinned by test-module-load.mjs Part A.
  if (typeof _m5.nestedWorktreeTargetViolation === "function") {
    nestedWorktreeTargetViolation = _m5.nestedWorktreeTargetViolation;
  }
  if (typeof _m5.stripHeredocData === "function") {
    stripHeredocData = _m5.stripHeredocData;
  }
  hubNewFileVolumeVerdict = _hubNewFileVolumeVerdict;
  HUB_NEW_FILE_WARN_BUDGET = _HUB_NEW_FILE_WARN_BUDGET;
  HUB_NEW_FILE_BLOCK_CAP = _HUB_NEW_FILE_BLOCK_CAP;
  // #627 bindings: same stale-classify-git skew guard as #628 — a missing
  // export must leave the fail-safe defaults (an undefined here would throw in
  // _backdoorBlock, whose catch turns the whole #627 gate fail-OPEN).
  if (typeof _extractCodePayload === "function") extractCodePayload = _extractCodePayload;
  if (typeof _codePayloadGitVerdict === "function") codePayloadGitVerdict = _codePayloadGitVerdict;
  // #1129: the sanctioned-script exemption's anchor (see
  // frameworkRootFromModuleUrl). Namespace read + typeof guard, same skew
  // contract as #709/#627 above — a stale module leaves the inline fallback.
  if (typeof _m5.frameworkRootFromModuleUrl === "function") _frameworkRootFromModuleUrl = _m5.frameworkRootFromModuleUrl;
  // #1139: the quote-aware shell tokenizer the pipe-seed walk uses (same skew
  // contract as above).
  if (typeof _m5.wtShellWords === "function") wtShellWords = _m5.wtShellWords;
  // #967/#1484: the invocation's positional args feed the subcommand
  // reachability filter. Stale-module skew guard: a missing export leaves the
  // fail-safe default ([] → no reachability proof → the whole script gates).
  if (typeof _m5.extractScriptArgs === "function") extractScriptArgs = _m5.extractScriptArgs;
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
  // #853: record WHY, so the startup self-test can name the cause instead of a bare
  // "DISABLED". The console line stays (it is the only trace if the session never starts).
  _classifierLoadFailure = String(e);
  console.warn("[main-worktree-guard] ⚠️ classify-git.mjs failed to load — bash git guard DISABLED:", String(e));
}

// #265: branch-ownership sentinel (baseline + M1/M2/M3 decisions + repo lock).
// Try/catch-guarded: load failure → M1/M2/M3 OFF + one-time warn; write/edit
// never depends on it.
let branchOwnership: any = null;
// The extension host keeps ONE process-wide module registry for its entire
// life. A `../shared/branch-ownership.mjs` first imported by an EARLIER
// generation of this file is therefore served from cache on every later
// reload — present, cached, and missing any export added since it was first
// evaluated. Because a reload re-evaluates THIS file but NOT its dependencies,
// a newly-added call site here meets that stale namespace and throws
// `… is not a function` at RUNTIME, mid-decision, from inside the tool hook.
// The throw escapes the hook and aborts the entire bash tool call (pi's
// emitToolCall runs the handler with no try/catch), so the guard ends up
// blocking EVERY mutating git command (`add`/`commit`/`push`) instead of
// guarding it — a safety control failing into a total work stoppage, which its
// own degradation contract (above) is explicitly designed to avoid.
//
// The fix is VALIDATION, not cache-busting: verify that every export we call is
// actually present, and if not, take the documented M1/M2/M3-OFF path instead
// of throwing. The load-failure catch below never covers this case — the
// import SUCCEEDS, it just returns an old namespace.
//
// Do NOT "fix" this with a specifier query (`…branch-ownership.mjs?gen=N`).
// pi loads extensions through jiti, whose resolver STRIPS the query before the
// module registry sees it: `jiti.resolve("./dep.mjs?gen=1")` and
// `jiti.resolve("./dep.mjs?gen=2")` return the same path, and three different
// query specifiers in one jiti load yield ONE module instance (a native-ESM
// host honours the query instead). So the query is inert HERE — and in a
// native host it would leak one module instance per reload. An earlier version
// of this change carried exactly that query and documented it as the fix; it
// was a no-op in production.
//
// What this fix DOES guarantee: a namespace missing any of the members we call
// degrades to the documented M1/M2/M3-OFF path instead of throwing. What it does
// NOT guarantee: it cannot stop a throw from a member that EXISTS but fails at
// call time, nor from a stale module whose shape drifted under an unchanged
// name. Those still surface as an aborted tool call, because the host rethrows
// an extension error to BLOCK the call (`emitToolCall` itself has no try/catch;
// the host wrapper rethrows "Extension failed, blocking execution"). Closing
// that larger class means wrapping the branch-ownership block in a try/catch
// that falls back to the legacy classifier — filed as follow-up, deliberately
// not attempted here because it restructures a 300-line safety block with no
// test coverage for the fallback path.
//
// Also NOT covered by this guard: the same "loaded but stale" exposure exists in
// `classify-git.mjs` (only 2 of ~35 destructured targets carry a typeof guard)
// and in `extensions/auto-sync.ts` (a STATIC import of this same helper, no
// validation). Both are filed as follow-ups.
//
// Consequence, stated plainly: on a stale namespace this guard is DOWN for the
// life of the process. A reload cannot recover it (the registry survives
// reloads) — only a full pi restart can. That is still strictly better than
// breaking git, but it is NOT self-healing. Specifier tricks do NOT fix it (see
// above). A `.ts` helper WOULD hot-reload — jiti re-evaluates a `.ts`
// dependency on reload — so migrating `shared/branch-ownership.mjs` to `.ts`
// (or having the loader set `tryNative: false` for extension deps) is the real
// self-healing path, blocked only by the plain-Node test/consumer imports of
// the `.mjs`. Filed, not done here.
const _BRANCH_OWNERSHIP_MEMBERS = [
  "acquireRepoLock", "classifyBranchOp", "decideM1", "decideM2", "decideM3",
  "fastForwardOntoUpstreamProof", "localBranchExists", "ownershipAllowed",
  "readBranchState", "releaseRepoLock", "repoKey", "resolveEffectiveRepo",
  "resolveRepoFromInv",
] as const;
try {
  branchOwnership = await import("../shared/branch-ownership.mjs");
  const _missing = _BRANCH_OWNERSHIP_MEMBERS.filter(
    (k) => typeof branchOwnership?.[k] !== "function",
  );
  if (_missing.length > 0) {
    console.warn(
      "[main-worktree-guard] ⚠️ branch-ownership.mjs namespace is STALE/incomplete — M1/M2/M3 branch-ownership guards DISABLED (falling back to legacy behavior). Missing exports:",
      _missing.join(", "),
      "— ⚠️ THIS PERSISTS FOR THE LIFE OF THIS PROCESS: a reload cannot recover it, only a full pi restart can. Do that now if you need branch-ownership enforcement.",
    );
    branchOwnership = null;
  }
} catch (e) {
  // Clear the binding FIRST: if the import assigned a namespace and a later
  // property access in the validation threw (e.g. a jiti-interop getter), the
  // binding would otherwise stay set with no validation and be used unguarded.
  branchOwnership = null;
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

// ── M4: hub-state gate (#1484) ─────────────────────────────────────────────// The hub's only legal states are main+clean. When the session cwd IS the hub
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
function _hubState(): { disorder: string | null; branch: string | null; path: string | null; dirtyPaths: number } {
  try {
    return readHubDisorder(resolve(process.cwd()));
  } catch {
    return { disorder: null, branch: null, path: null, dirtyPaths: 0 }; // degrade — never false-block
  }
}

/** #1125 — the M4 WRITE/EDIT block must NAME the checkout and echo the resolved
 *  condition, exactly as the bash-route block does (classify-git
 *  `_m4CheckoutLines`). `"the shared main checkout"` is ambiguous across a
 *  machine carrying several checkouts; unnamed, it sent two agents to the wrong
 *  repository for ~40 minutes and produced a destructive-command request
 *  against a healthy repo. Returns null when the path could not be resolved
 *  (the message stays as it was — no fabricated context). */
function _m4CheckoutLine(st: { disorder: string | null; branch: string | null; path: string | null; dirtyPaths: number }): string | null {
  if (!st.path) return null;
  const bits: string[] = [];
  if (st.disorder === "off_main" || st.disorder === "both") bits.push(`off-main: ${st.branch ?? "<detached>"}`);
  if (st.disorder === "dirty" || st.disorder === "both") bits.push(`dirty: ${st.dirtyPaths} path(s)`);
  return `   Checkout: ${st.path}${bits.length > 0 ? ` (${bits.join(", ")})` : ""}`;
}

/** #1484 — the write/edit route's recovery advice must be as ACTIONABLE as the
 *  bash route's (review round 2, P2). This route keeps D3's freeze even under
 *  the hatch, so it cannot tell the reader to just edit; but it CAN tell them
 *  how to clear the dirt on the route that has a working escape — the bash
 *  named-path restore, which an active hatch sanctions. The old line said
 *  `git checkout main && git pull --ff-only`, which on a DIRTY hub is the very
 *  no-op this change removes from the bash message: git refuses to switch over
 *  modified paths. */
function _hubWriteRecoverLines(st: { disorder: string | null } | null, hatchActive: boolean = _currentHatchActive): string[] {
  // ONE text, shared with M4's classifier reason (round 9): the two used to
  // diverge, and only the classifier's covered all three dirt shapes.
  const lines = hubDirtyRecoveryLines(st, hatchActive);
  if (lines.length > 0) return lines;
  return [`   → Recover first: cd <repo> && git checkout main && git pull --ff-only`];
}

// #1919 — refuse a `git worktree add|move` whose target lands INSIDE a git
// checkout where git does not ignore it. The state such a worktree creates is
// born CLEAN and then reads DIRTY forever: git reports the nested worktree as an
// untracked directory, M4 freezes every git op, `worktree move` is off the
// recovery allowlist, and `prune` cannot remove a LIVE worktree — a gate closed
// against its own repair (the issue's measured refusal). Curing the hubs that
// already carry the state is `porcelainWithoutRegisteredWorktrees`; this refuses
// to create new ones. Independent of the hub's OWN state (a clean hub creates it
// just as well), and like M4 it stays active under the TTL marker — a stranded
// lane may recover, it may not manufacture the deadlock.
//
// NO literal-substring pre-filter (#1919 review P1). A `command.includes("worktree")`
// guard was a FAIL-OPEN: shell quoting spells the verb in ways git accepts and a
// literal check does not see — `git work"tree" add deep/x` runs `worktree`, the
// classifier REFUSES it, and the pre-filter returned null before the classifier
// ever ran, so the nested worktree was created and the hub deadlocked exactly as
// the issue describes. The cost of always parsing is one string walk, which is
// what the sibling gates in this handler already pay.
function _nestedWorktreeBlock(command: string): string | null {
  try {
    // HEREDOC BODIES are data, not commands (#1919 final review P2): a note,
    // README or plan that merely QUOTES `git worktree add 8779-optA` was refused
    // as an attempt to run it. The stripper is the SAME quote/comment-aware one
    // the M5 discard extractor uses (`stripHeredocData`) — a hand-rolled regex
    // was quote-blind and could HIDE a real invocation behind a `<<EOF` that
    // appeared in a comment or a string, which is a fail-open.
    return nestedWorktreeTargetViolation(stripHeredocData(command) ?? command, resolve(process.cwd()));
  } catch {
    return null; // degrade — never false-block on classifier failure
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

// ── #718: hub working-tree SWEEP detection ─────────────────────────────────
// Measured 2026-09-10 (#718): a session authored six artifacts in the shared
// hub (`agent-infra` main checkout) and a concurrent session returned the hub
// to `main`. NOTHING warned it — it learned when an `edit` came back ENOENT,
// roughly an hour later, and the work survived only because a sibling happened
// to run a salvage commit first. Recovery must not be a probabilistic function
// of whether a sibling snapshotted.
//
// M1 (#265) catches a BRANCH change and the #350 inventory (#350) warns about
// WIP that EXISTS. Neither can see a working tree rewritten while the branch
// stayed `main` — `git reset --hard`, `git checkout -f`, a sibling's salvage
// `rm`. Afterwards the hub is CLEAN and on main, so EVERY state check passes:
// the loss is invisible by construction, which is why #718 is a detection gap
// and not a discipline gap.
//
// The only thing that distinguishes "the hub is clean" from "the hub was
// erased" is a BASELINE — the dirty-path set THIS session observed. A path
// this session saw in `git status` and that is now absent did not commit
// itself out of existence: it was swept or reverted.
//
// Sampling (this is the load-bearing design choice): the observation runs on
// EVERY tool_call, behind a 1.5s burst throttle, for hub-ROOTED sessions only
// — the population the incident covers. Worktree sessions (every fleet lane)
// pay one `isWorktreeCwdWrite` call and nothing else. `git status
// --porcelain=v1` on the 2026-11-08 hub measures ~20ms, which is far cheaper
// than one missed edit, and sampling at the NEXT tool call is the entire point
// (the incident's hour of silence is the defect).
//
// Collapsed porcelain is deliberate: an untracked DIRECTORY arrives as one
// `?? dir/` entry — exactly the artifact shape the incident lost (`one new
// untracked skill directory`) — while a per-file expansion over a large
// untracked tree is unbounded. Documented residual: a single file removed from
// INSIDE an untracked directory that still has other entries does not change
// the collapsed entry, so THAT sub-case is not reported; a whole artifact
// (the reported loss) is.
const HUB_SWEEP_MIN_MS = 1500;      // burst ceiling: at most one status per 1.5s
const HUB_SWEEP_MAX_NAMED = 8;      // paths named in the banner; the rest are counted
const observedHubPaths = new Map<number, Set<string>>();  // pid → last observed dirty set
const warnedVanishedPaths = new Map<number, Set<string>>(); // pid → already reported
let lastHubSweepMs = 0;
let lastHubTreeSignature: string | null = null;
let cachedHubCommonDir: string | null | undefined; // undefined = not yet resolved

// The hub's git-common dir (the shared `.git` — a worktree's own gitdir is not
// this), resolved ONCE per process from the hub toplevel.
function _hubCommonDir(hubTop: string): string | null {
  if (cachedHubCommonDir !== undefined) return cachedHubCommonDir;
  try {
    cachedHubCommonDir = execSync("git rev-parse --path-format=absolute --git-common-dir", {
      cwd: hubTop, encoding: "utf-8", timeout: 5000,
    }).trim() || null;
  } catch {
    cachedHubCommonDir = null;
  }
  return cachedHubCommonDir;
}

// A cheap "may the working tree have changed?" signature: the index and the
// HEAD reflog (every checkout/reset/commit writes one of them — the incident's
// own evidence was `reset: moving to HEAD`) plus the hub ROOT (a path entered or
// left the tree). Three `stat`s, no child process. `null` = UNVERIFIABLE, which
// the caller reads as "changed" so a failed probe can never silence the check.
function _hubTreeSignature(hubTop: string): string | null {
  const common = _hubCommonDir(hubTop);
  if (!common) return null;
  const stamp = (p: string): string => {
    try { const s = statSync(p); return `${s.mtimeMs}:${s.size}`; } catch { return "E"; }
  };
  return [stamp(join(common, "index")), stamp(join(common, "logs", "HEAD")), stamp(hubTop)].join("|");
}

// `git status --porcelain=v1 -z` (collapsed) → the set of paths the hub reports
// as not-committed. Rename/copy entries carry BOTH sides and both are observed,
// so neither side's disappearance can be misread as a sweep.
// ⛔ `-z` IS LOAD-BEARING, not a style choice (#718 review round 4, Issue 1).
// Without it git C-quotes every path holding a non-ASCII byte, a `"` or a `\`
// under the default `core.quotePath=true`, spelling the bytes as OCTAL escapes:
// a modified `café.md` arrives as ` M "caf\303\251.md"`. Decoding that by hand
// is a trap — the previous `replace(/\\(.)/g, "$1")` consumed the octals ONE
// CHARACTER AT A TIME and produced the key `caf303251.md`, a name that cannot
// exist. `_hubPathIsGone` then lstat-ed that name, failed, and reported as
// ABSENT a path that was on disk AND in HEAD — the round-3 P1 ("set membership
// is not absence") reinstated through the path decoder, with a name the victim
// can neither `git status` nor restore. `-z` output is NEVER quoted
// (git-status(1)), so there is nothing to decode and nothing to get wrong; the
// repo already reads paths this way (`scripts/bg-rescue-wip.sh:343`). The cost
// of `-z` is that a rename's field order is reversed — `XY <to>\0<from>\0`,
// not `old -> new` — which is why the origin side is taken from the NEXT field.
// Any lossy step left is the utf-8 decode of the path bytes themselves, whose
// residual is declared in the README (`(f)`): a path that is not valid utf-8
// cannot be lstat-ed and so lands in the ABSENT population.
function _dirtyPathsFromPorcelain(porcelain: string): Set<string> {
  const out = new Set<string>();
  const entries = porcelain.split("\0");
  for (let i = 0; i < entries.length; i++) {
    const raw = entries[i];
    if (!raw) continue;
    const p = raw.slice(3); // `XY <path>`: XY is 2 columns, path starts at 3
    if (!p) continue;
    out.add(p);
    // Rename/copy (`R`/`C` in the index column): the ORIGIN path is the next
    // NUL-terminated field, positional — never a ` -> ` split, which a path
    // containing that literal substring would have broken.
    if (raw[0] === "R" || raw[0] === "C") {
      const from = entries[i + 1];
      if (from) { out.add(from); i++; }
    }
  }
  return out;
}

// The reflog is the forensic record of WHAT rewrote the tree: the incident's own
// evidence was `reset: moving to HEAD` / `checkout: moving from <branch> to
// main`. Bounded to the last 3 entries; only read on the warning path.
function _hubReflogTail(hubTop: string): string[] {
  try {
    return execSync("git reflog -3 --format='%gd %gs'", {
      cwd: hubTop, encoding: "utf-8", timeout: 5000,
    }).split("\n").map((l) => l.trim()).filter(Boolean);
  } catch {
    return []; // no reflog (fresh init / bare) is not an error
  }
}

// The banner. Warn-only, and it must be ACTIONABLE: #718's two other findings
// are (a) recovery depended on a coincidental salvage and (b) restoring whole
// files from a salvage re-imports EVERY session's half-written edit — the
// contamination that a verifier caught only because it read the diff, while a
// reconciliation by `git diff --stat` line counts looked plausible and passed.
// Both belong in the warning, not in a doc nobody reads mid-incident.
function _warnHubSweep(absent: string[], onDisk: string[], hubTop: string): void {
  const L = (t: string) =>
    "║  " + (t.length > 62 ? t.slice(0, 61) + "…" : t).padEnd(62) + "║";
  const named = (list: string[]) => [
    ...list.slice(0, HUB_SWEEP_MAX_NAMED).map((p) => L(`  • ${_truncatePath(p, 44)}`)),
    ...(list.length > HUB_SWEEP_MAX_NAMED
      ? [L(`  … and ${list.length - HUB_SWEEP_MAX_NAMED} more`)]
      : []),
  ];
  // RIGHT-truncate reflog lines: the `HEAD@{n}` prefix and the verb are the
  // information (a left-truncation would drop exactly those, #718's own evidence).
  const reflog = _hubReflogTail(hubTop).slice(0, 2).map((l) => L(`    ${l.length > 58 ? l.slice(0, 57) + "…" : l}`));
  // Two POPULATIONS, because they are different propositions (#718 review round
  // 3, P1). Set-membership in `git status` establishes only that a path left the
  // UNCOMMITTED set; it does NOT establish that the path is gone. `git add -A`
  // and `git commit` move work into the index/HEAD and delete nothing, so
  // telling that reader the paths are "ABSENT" sends them to a salvage restore
  // that re-imports stale pre-commit content into work already staged or
  // committed — the exact contamination #718 point 3 exists to prevent.
  const lines = [
    "",
    "╔══════════════════════════════════════════════════════════════════╗",
    L("⚠️  HUB WORKING TREE CHANGED UNDER YOU (#718)"),
    "╠══════════════════════════════════════════════════════════════════╣",
    ...(absent.length ? [
      L("Observed earlier this session, now ABSENT from the hub:"),
      ...named(absent),
      L(""),
    ] : []),
    ...(onDisk.length ? [
      L("Observed earlier, no longer UNCOMMITTED — still ON DISK:"),
      ...named(onDisk),
      L("  staged/committed elsewhere, or the edit was REVERTED —"),
      L("  check `git status` / `git log -1 --stat` BEFORE restoring."),
      L(""),
    ] : []),
    L("Something REWROTE the shared hub's working tree — a concurrent"),
    L("session/process swept it, or a hub command in THIS session did (a"),
    L("salvage NAMES every path it reverses, #854 — check your own tool"),
    L("output first)."),
    L("─ What moved it (the reflog records the verb):"),
    L(`  git -C ${_truncatePath(hubTop, 40)} reflog -10`),
    ...reflog,
    L("─ Where the work went (the routes this repo actually writes):"),
    L("  git -C <hub> log --all --oneline --grep=salvage"),
    L("  git -C <hub> ls-remote origin 'refs/wip/*'"),
    L("  git -C <hub> for-each-ref refs/wip-local"),
    L(""),
    L("⚠️  A salvage is a MIXTURE of every session's tree. Restore"),
    L("   ONLY the paths you authored, and read the diff CONTENTS:"),
    L("`git diff --stat` line counts are NOT a contamination check."),
    "╚══════════════════════════════════════════════════════════════════╝",
    "",
  ];
  console.warn(lines.join("\n"));
}

// Is the path still on disk under the hub? `lstatSync` (not `existsSync`) so a
// symlink counts as PRESENT — a symlink is content that still exists. An entry
// this cannot parse, or one that escapes the hub, is treated as GONE: the safe
// direction, because GONE is what warns.
// ⛔ A collapsed untracked DIRECTORY (`?? dir/`, trailing slash) is present by
// CONTENT, not by the survival of the directory NODE (#718 review round 4,
// Issue 2). That entry shape is exactly what the incident lost ("one new
// untracked skill directory"), and `rm dir/*` — or any partial sweep one level
// down — leaves the node while every byte of the work is gone. Asking `lstat`
// about the node there answered "present" for a TOTAL loss and printed the
// reassuring "still ON DISK" population, the exact inverse of the round-3 P1.
// An empty (or unreadable) directory is therefore GONE.
function _hubPathIsGone(hubTop: string, rel: string): boolean {
  if (!rel || rel.startsWith("/") || rel.split(/[\\/]/).includes("..")) return true;
  const abs = join(hubTop, rel);
  if (rel.endsWith("/")) {
    try { return readdirSync(abs).length === 0; } catch { return true; }
  }
  try { lstatSync(abs); return false; } catch { return true; }
}

// A collapsed untracked DIRECTORY that is now listed per-file is a porcelain
// REPRESENTATION change, not a change of state: `?? docs/` becomes
// `A  docs/plans/plan.md` the moment something stages it (git-status(1): `??`
// is untracked, `A ` is staged), and the directory's own entry disappears while
// the directory is untouched. Nothing was lost, so nothing is reported.
function _porcelainCollapsed(rel: string, current: Set<string>): boolean {
  if (!rel.endsWith("/")) return false;
  for (const c of current) if (c.startsWith(rel)) return true;
  return false;
}

// Diff the observed dirty-path set against the previous observation. Called by
// _hubSweepCheck only; never throws (warn-only, and a stderr failure in a
// session hook must never break a tool call).
function _observeHubTree(porcelain: string, hubTop: string): void {
  const pid = process.pid;
  const current = _dirtyPathsFromPorcelain(porcelain);
  const previous = observedHubPaths.get(pid);
  observedHubPaths.set(pid, current);
  let seen = warnedVanishedPaths.get(pid);
  if (!seen) { seen = new Set<string>(); warnedVanishedPaths.set(pid, seen); }
  // RE-ARM, never suppress forever (#718 review round 3, P2). A path observed
  // dirty AGAIN has demonstrably been re-authored, so a later disappearance is
  // a NEW loss. A permanent per-path-per-session `seen` made a repeat of the
  // incident class a silent miss — the opposite of what this arm is for. One
  // banner per LOSS is the requirement `C2` pins, not one per path per session.
  // ⛔ This must run on EVERY observation, before any early return: the call that
  // sees the path DIRTY is the one that re-arms it, and that call has nothing to
  // report itself.
  for (const p of current) seen.delete(p);
  // Nothing was ever observed dirty → nothing can have been lost. This is also
  // what keeps a legitimately-clean hub silent forever.
  if (!previous || previous.size === 0) return;
  const vanished = [...previous].filter((p) => !current.has(p) && !_porcelainCollapsed(p, current));
  if (vanished.length === 0) return;
  const fresh = vanished.filter((p) => !seen.has(p));
  if (fresh.length === 0) return; // already reported — one banner per loss, not per tool call
  for (const p of fresh) seen.add(p);
  const absent: string[] = [];
  const onDisk: string[] = [];
  for (const p of fresh) (_hubPathIsGone(hubTop, p) ? absent : onDisk).push(p);
  _warnHubSweep(absent, onDisk, hubTop);
}

// #718 detection entry point — hub-rooted sessions only; skipped under the env
// hatch (a deliberate solo session is the documented hatch contract, and
// HUB_HYGIENE_THROTTLE_MS's sibling check is skipped there for the same reason).
// Exported for nothing: called from session_start and every tool_call.
function _hubSweepCheck(): void {
  if (_isAllowMainEdits()) return;
  try {
    if (isWorktreeCwdWrite(resolve(process.cwd()))) return; // isolated — not this class
    const hubTop = _cachedMainTopLevel();
    if (!hubTop) return; // non-git cwd / unresolved: nothing to observe
    // Two gates, and only the second costs a child process. An UNCHANGED
    // signature inside the burst window means no git-level write and no entry
    // added/removed at the hub root — nothing to observe yet. Once the window
    // expires we observe regardless, which bounds every subtler change (a file
    // removed from inside an untracked directory) to one tool call.
    const now = Date.now();
    const sig = _hubTreeSignature(hubTop);
    if (sig !== null && sig === lastHubTreeSignature && now - lastHubSweepMs < HUB_SWEEP_MIN_MS) return;
    lastHubTreeSignature = sig;
    lastHubSweepMs = now;
    // GIT_OPTIONAL_LOCKS=0 is the repo's own convention for a read-only git call
    // in a SHARED tree (scripts/bg-rescue-wip.sh:33-34, :243): a plain `git
    // status` rewrites the real index and takes `.git/index.lock`, which would
    // make a LIVE lane's next git command fail at exactly the frequency this arm
    // samples (#718 review round 3). It also keeps our own probe from perturbing
    // the index signature the burst gate reads.
    // `-z` so git never C-quotes a path (see _dirtyPathsFromPorcelain).
    const porcelain = execSync("git status --porcelain=v1 -z", {
      cwd: hubTop, encoding: "utf-8", timeout: 5000,
      env: { ...process.env, GIT_OPTIONAL_LOCKS: "0" },
    });
    _observeHubTree(porcelain, hubTop);
  } catch { /* warn-only — degrade silently, never blocks */ }
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
/** Round 10 (P2): the hub state of the checkout a BLOCKED WRITE TARGETS (not the
 *  session's cwd — a cross-checkout write is about the OTHER hub, and telling
 *  that reader to `git checkout main` in a hub already on main and dirty is the
 *  #1484 no-op again). Falls back to the session hub when the target's repo
 *  cannot be resolved. */
function _targetHubState(resolvedPath: string): { disorder: string | null } | null {
  try {
    const top = resolveTargetTopLevel(resolvedPath) ?? _mainTopLevel();
    if (top) return readHubDisorder(top, { skipWorktree: true });
  } catch { /* fall through */ }
  return _hubState();
}

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
    // Round 9 (P1): THIS is the arm the incident's refusal #4 (`cp <worktree
    // copy> <truncated tracked file>`) hits — round 8's lines landed on the
    // untracked-existing branch instead.
    // Round 10 (P2): the state must be the HUB THE WRITE TARGETS, not the
    // session's cwd. Measured: session rooted in a clean hub A running
    // `cp A/a.txt B/tracked.txt` (B = a dirty hub main) was told
    // `git checkout main && git pull --ff-only` — a no-op on B, which is already
    // on main and dirty. The target's own disorder decides the advice.
    ..._hubWriteRecoverLines(_targetHubState(hit.resolvedPath)),
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
// index-only restores stay allow, and so do the framework's OWN sanctioned
// scripts (#1139 — SANCTIONED_SCRIPT_RELPATHS, the set-scoped exemption in the
// script walk below; a non-sanctioned script's discards stay gated). Placed
// AFTER the env/marker hatch return, so both hatches bypass it unchanged (task
// children are unhatched by #617/#623, which is why this is the enforcement
// surface for them).

/**
 * #1060 — the STATE predicate for a `cat-file-revert` descriptor
 * (`git show HEAD:<path> > <target>`). Returns a block reason, or null to allow.
 *
 * WHY THIS REPLACED A TEMPLATE COMPARISON. The arm used to intersect the
 * source pathspec (`HEAD:<path>` → `<path>`) with the command's bash write
 * targets by EXACT STRING EQUALITY of two independently-anchored templates.
 * Equality therefore held only when the two spellings matched character for
 * character, and that is wrong in BOTH directions:
 *
 *  - it FAILS OPEN on two spellings of one file
 *    (`git -C "$MAIN_REPO" show HEAD:dirty.txt > "$MAIN_REPO/dirty.txt"`) —
 *    no intersection, so the arm `continue`d and the redirect reverted TRACKED,
 *    MODIFIED content. The modification existed only in the working tree,
 *    was never a git object, and has no other copy: unrecoverable loss.
 *  - it FAILS CLOSED on any variable (`HEAD:"$x"`), because the generic
 *    unresolvable-pathspec rule caught the source and refused a read-only
 *    `git show` — the #940 friction, in the same hunk.
 *
 * The question the arm has to answer is about STATE ("does this redirect land
 * on content that would be lost?"), so it is answered with state:
 *
 *   - no redirect target at all ⇒ a pure read; nothing can be written;
 *   - otherwise probe `git status --porcelain` on every statically identifiable
 *     candidate checkout — `writeCwd`, plus the nearest EXISTING ancestor
 *     directory of each write target — and allow ONLY if all are free of
 *     tracked dirt.
 *
 * `discardDestroysWip` (scope "all") already separates tracked dirt (real loss)
 * from untracked-only dirt (nothing tracked is destroyed), so the arm neither
 * blocks on `??` scratch output nor conflates the two in its message. Unlike
 * the comparison it replaces, one wrong ALLOW here is unrecoverable, which is
 * why the arm is conservative: an unresolvable target is probed at its nearest
 * existing ancestor, and an unreadable status FAILS CLOSED.
 *
 * Declared residual: a target anchored to a name this command never assigns
 * (`> "$SOME_ENV_VAR/f"`) keeps the literal `$SOME_ENV_VAR` component and is
 * therefore probed at the command's own directory — the same conservative
 * answer the old arm gave by failing closed. A target anchored to a name the
 * command DOES assign is resolved here (`_wtCommandVars`), which is the fail-open
 * this predicate exists to close.
 */
function _catFileRevertStateBlock(
  d: { form: string; scope: string; pathspecs: string[] },
  writeTargetsRel: string[],
  writeCwd: string,
  command: string,
  scriptDir: string | null,
): string | null {
  // No redirect ⇒ nothing is written. This is the read-only `git show HEAD:x`
  // and the `git show HEAD:x > /dev/null` cases: no loss is possible. #1125 —
  // this arm is also why a read-only probe whose pathspec is a shell variable
  // (`git cat-file -e "origin/$BRANCH:$f"`) is allowed instead of fail-closed
  // on the unresolvable source: the hint has no LANDING SITE, so there is no
  // discard. The decision is ordered by EFFECT, not by the pathspec's spelling.
  if (writeTargetsRel.length === 0) return null;

  const vars = _wtCommandVars(command);
  const targets = writeTargetsRel.map((rel) => resolve(writeCwd, _wtSubstituteVars(rel, vars)));

  // Candidate checkouts, in a deterministic order: the write cwd FIRST (its
  // dirt is the one a relative target lands in, and it is the checkout the
  // message should name first), then each target's nearest existing ancestor,
  // then the checkout the discard was READ FROM when it came from a script.
  //
  // The script's own directory earns its place: a script's redirect is often
  // anchored to a name the script computes at runtime (`hub-worktree.sh`
  // derives `MAIN_REPO` from `git rev-parse --git-common-dir`), so it is not
  // statically resolvable from the command text — but the script FILE is a
  // statically identifiable checkout, and that is where such a discard can
  // land. On the clean fixture it changes nothing; with tracked dirt there it
  // is the difference between a block and an unrecoverable loss.
  const candidates = new Set<string>([writeCwd]);
  for (const t of targets) {
    let dir = dirname(t);
    // Bounded: a target under a not-yet-existing directory has no checkout of
    // its own, so the walk finds the nearest one that exists.
    for (let i = 0; i < 64 && !existsSync(dir); i++) {
      const parent = dirname(dir);
      if (parent === dir) break;
      dir = parent;
    }
    candidates.add(dir);
  }
  if (scriptDir !== null) candidates.add(scriptDir);

  for (const cand of candidates) {
    // Whole-checkout scope: the redirect's own path is not always statically
    // known (it may still carry an unresolved component), so the question asked
    // is the answerable one — "does this checkout hold tracked dirt at all?".
    const dirty = _discardStatusPorcelain(cand, { scope: "all", pathspecs: [] });
    if (dirty === false) continue;
    // The reason must name the REDIRECT, not the source: `git show HEAD:a > b`
    // discards `b`, and naming `a` here is the misattribution class #1139
    // removed from this message. Report targets relative to the checkout being
    // blamed when they are inside it, else their absolute spelling.
    const named = {
      form: d.form,
      scope: "paths",
      pathspecs: targets.map((t) => {
        const rel = relative(cand, t);
        return rel && !rel.startsWith("..") ? rel : t;
      }),
    };
    return _worktreeDiscardBlockReason(
      named,
      cand,
      dirty === null ? "the target checkout's status could not be read" : null,
    );
  }
  return null;
}

/**
 * #1060 — same-command `NAME=<literal>` assignments, used to resolve a `$NAME`
 * component in a `cat-file-revert` write target before it is resolved.
 *
 * ONLY unambiguous, literal values are returned: a name assigned twice with
 * different values, or assigned anything containing a substitution (`$`, a
 * backtick, a brace expansion), is dropped rather than guessed — an unresolved
 * component leaves the target at its nearest existing ancestor, which is the
 * conservative arm. The anchor `(?:^|[;&|(\s])` keeps `--foo=bar` and other
 * option operands out, and the value class stops at a separator so `V=/a/b;`
 * yields `/a/b` and not `/a/b;` (the trailing `;` would be a path component and
 * would break the ancestor walk this resolution exists to feed).
 */
function _wtCommandVars(command: string): Map<string, string> {
  const out = new Map<string, string>();
  const ambiguous = new Set<string>();
  for (const m of String(command).matchAll(/(?:^|[;&|(\s])([A-Za-z_][A-Za-z0-9_]*)=("[^"]*"|'[^']*'|[^\s;&|()]+)/g)) {
    const name = m[1];
    const val = _dequoteShellWord(m[2]);
    if (!val || /[$`]/.test(val) || /[{}]/.test(val)) { ambiguous.add(name); continue; }
    const prev = out.get(name);
    if (prev !== undefined && prev !== val) { ambiguous.add(name); continue; }
    out.set(name, val);
  }
  for (const n of ambiguous) out.delete(n);
  return out;
}

/** #1060 — replace `$NAME` / `${NAME}` with a resolved same-command assignment.
 *  An unknown name is left VERBATIM (never emptied): a silently-shortened path
 *  would name a different file and could clear a real block. */
function _wtSubstituteVars(p: string, vars: Map<string, string>): string {
  if (vars.size === 0 || !p.includes("$")) return p;
  return p.replace(/\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)/g,
    (whole, braced, bare) => vars.get(braced ?? bare) ?? whole);
}

/** #1885 — the value text of an assignment word, scanned the way a SHELL reads one
 *  word: quotes are honoured, a `$( )` / `( )` nest keeps its spaces, and the word
 *  ends at the first UNQUOTED, un-nested whitespace. That fidelity is the point:
 *  `S=$(printf ./undo.sh)` is ONE word, and a whitespace split truncated it to
 *  `$(` — which then read as "not path-shaped" and let a command-substitution
 *  script path through (measured). */
function _wtAssignValueAt(s: string, start: number): string {
  let quote: string | null = null;
  let depth = 0;
  let out = "";
  for (let i = start; i < s.length; i++) {
    const c = s[i];
    if (quote) {
      out += c;
      if (c === "\\" && quote === '"') { out += s[i + 1] ?? ""; i++; continue; }
      if (c === quote) quote = null;
      continue;
    }
    if (c === "'" || c === '"') { quote = c; out += c; continue; }
    if (c === "\\") { out += c + (s[i + 1] ?? ""); i++; continue; }
    if (c === "(") { depth++; out += c; continue; }
    if (c === ")") { depth = Math.max(0, depth - 1); out += c; continue; }
    if (depth === 0 && /\s/.test(c)) break;
    out += c;
  }
  return out;
}

/** #1885 — split `text` into command segments, with each segment's OFFSET in the
 *  original string. `_wtCommandSegments` (shared with the #1228 arms) drops positions,
 *  and the command-position arm needs them: an assignment AFTER the use site does not
 *  apply to it (`S=./undo.sh; $S; S=./noop.sh` runs `./undo.sh`).
 *
 *  It DELIBERATELY differs from `_wtCommandSegments` on two separators, and the caller
 *  compensates: `||` stays inside the segment and the word scan steps over it, and the `&`
 *  of `2>&1` / `&>` is NOT a separator (splitting it left a segment starting with `1`). Do
 *  not build a later arm on a "these two agree" assumption. */
function _wtSegmentsWithOffsets(text: string): { text: string; at: number }[] {
  const s = String(text ?? "");
  const out: { text: string; at: number }[] = [];
  let cur = "";
  let start = 0;
  let quote: string | null = null;
  for (let i = 0; i < s.length; i++) {
    const ch = s[i];
    if (quote) { if (ch === quote) quote = null; cur += ch; continue; }
    if (ch === "\\") { cur += ch + (s[i + 1] ?? ""); i++; continue; }
    if (ch === "'" || ch === '"') { quote = ch; cur += ch; continue; }
    if (ch === ";" || ch === "&" || ch === "\n") {
      // ⛔ `2>&1` and `&>` are REDIRECTIONS, not separators (review P2). Splitting on
      // their `&` left a segment whose first word was `1`, so
      // `S=./undo.sh; 2>&1 $S` was never scanned — and that is the commonest
      // redirection spelling in agent bash calls.
      const amp = ch === "&";
      const dupOrRedirect = amp && (s[i - 1] === ">" || s[i + 1] === ">" || s[i - 1] === "|");
      if (!dupOrRedirect) {
        out.push({ text: cur, at: start });
        if (amp && s[i + 1] === "&") i++;
        cur = "";
        start = i + 1;
        continue;
      }
    }
    cur += ch;
  }
  out.push({ text: cur, at: start });
  return out.filter((seg) => seg.text.trim() !== "");
}

/** #1885 — mask HEREDOC BODIES out of `text`, preserving LENGTH (so every offset the
 *  caller holds stays valid). A here-doc body is DATA, not commands: without this,
 *  `cat > notes.md <<'EOF'` with a body line that STARTS with `$S` made the arm read `$S`
 *  as a command word and refuse a command that runs nothing — a false block introduced
 *  with this arm (review P3). The body's own expansions are out of scope here: what is
 *  masked is a line that is data, never a command word. */
function _wtMaskHeredocBodies(text: string): string {
  const lines = String(text ?? "").split("\n");
  const masked: string[] = [];
  // ⛔ ARITHMETIC NESTING (review P2): `X=$(( 8 << n ))` is a SHIFT, not a heredoc.
  // `<<` followed by a blank and an IDENTIFIER matched the opener regex with delimiter
  // `n`, and every following line was then masked (no line ever equals `n`) — so
  // `X=$(( 8 << n ))` above `S=./undo.sh; $S` blanked the invocation and disabled the
  // whole #1885 arm (measured). A NUMERIC right operand (`X=$(( 8 << 1 ))`) masked
  // nothing, because `1` cannot start a delimiter — which is why the suite missed it.
  // While the depth is > 0 the scan is inside `$(( … ))` / `(( … ))`, where `<<` can
  // only be a SHIFT. The depth is carried ACROSS lines, because an arithmetic
  // expression may span them; the function stays length-preserving (nothing here
  // touches the emitted text), so every offset the caller holds remains valid.
  let arith = 0;
  // ⛔ BARE-PAREN BALANCE INSIDE ARITHMETIC (review round-3 G2). `))` closes arithmetic
  // ONLY at bare-paren depth 0: in `X=$(( (1+(2)) << n ))` the first two `)` close the
  // INNER groups, not the arithmetic, so the old test (`ch === ")" && line[c+1] === ")"`)
  // closed the depth early, the `<<` below it was then read as a HEREDOC opener with
  // delimiter `n`, and every following line was masked — blanking `S=./undo.sh; $S` and
  // disabling the whole #1885 arm (measured). A bare `(` opens a group, a bare `)` closes
  // one, and only a `))` with nothing open closes the arithmetic.
  //
  // ⛔ PER ARITHMETIC LEVEL, not one counter for the whole line (review round-3
  // verification): a NESTED `$((` inside an open bare group sits at the same `arith`
  // depth as the group, so a single `bare` was spent by the INNER arithmetic's `)` —
  // `A=$(( (2 + $((3)) ) ))` then left `arith` at 1, the following `<<EOF` was read as a
  // shift instead of a heredoc, the body was NOT masked, a body line was folded as a real
  // assignment, and the benign body value laundered the command into an ALLOW while bash
  // ran the discarding script (measured; BLOCK before this fix). The stack keeps each
  // level's own count, so a nested arithmetic closes ITSELF and never spends the
  // enclosing group's.
  //
  // `bare`/`arith` are carried ACROSS lines, because an arithmetic expression may span
  // them; nothing here touches the emitted text, so the function stays LENGTH-PRESERVING
  // (both readers depend on the offsets).
  let bare = 0;
  const bareStack: number[] = [];
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    masked.push(line);
    // ⛔ QUOTE- AND COMMENT-AWARE (review P2): a `<<` inside a quoted string or after a
    // `#` comment is not a redirection, but the regex form masked every following line —
    // `echo "a << EOF"` then blanked the rest of the command, including a real `$S`.
    //
    // ⛔ EVERY OPENER ON THE LINE, and a real SHELL WORD as the delimiter (review round-3
    // verification). The single-opener/identifier-only form left two fail-opens, both
    // measured with a real discard and both identical on origin/main: a legal delimiter
    // the identifier regex does not accept (`<<1`, `<<9EOF`, `<<E-O-F`) was never seen as a
    // heredoc at all, so its body was scannmed as CODE and a body line was folded as a real
    // assignment that laundered the invocation (ALLOW); and the body loop masks to EOF when
    // the delimiter it CAPTURED can never equal the real terminator. With the delimiter read
    // as the shell's word, every body ends where bash ends it. Several openers on one line
    // (`cat <<A <<B`) have their bodies in OPENER ORDER, so they are collected and masked
    // sequentially — masking only the first left the second body scannable.
    // The word class refuses `$`/backtick/backslash because such a delimiter is EXPANDED by
    // the shell at runtime and its terminator cannot be known statically: those stay
    // unmasked exactly as before (unchanged, documented residual).
    const hits: { delim: string; strip: boolean }[] = [];
    {
      let quote: string | null = null;
      let atWordStart = true;
      for (let c = 0; c < line.length; c++) {
        const ch = line[c];
        if (quote) {
          if (ch === "\\" && quote === '"') { c++; continue; }
          if (ch === quote) quote = null;
          continue;
        }
        if (ch === "'" || ch === '"') { quote = ch; atWordStart = false; continue; }
        if (ch === "\\") { c++; continue; }
        if (ch === "#" && atWordStart) break;          // comment: no redirection after it
        // Arithmetic openers/doors. `$((` is one token; a bare `((` is the
        // arithmetic COMMAND. `))` closes only when nothing else is open, so a
        // stray `))` in ordinary text cannot make the depth negative — and a `)`
        // that closes a bare GROUP inside arithmetic does not close the arithmetic
        // itself (review round-3 G2).
        if (ch === "$" && line[c + 1] === "(" && line[c + 2] === "(") { bareStack.push(bare); bare = 0; arith++; c += 2; atWordStart = false; continue; }
        if (ch === "(" && line[c + 1] === "(") { bareStack.push(bare); bare = 0; arith++; c++; atWordStart = false; continue; }
        if (arith > 0 && ch === "(") { bare++; atWordStart = false; continue; }
        if (arith > 0 && ch === ")") {
          if (bare === 0 && line[c + 1] === ")") { arith--; bare = bareStack.pop() ?? 0; c++; atWordStart = false; continue; }
          if (bare > 0) bare--;
          atWordStart = false; continue;
        }
        // `<<<` is a HERE-STRING, not a heredoc (nothing to mask) — and the guard must
        // skip EVERY `<` of it, not just the first (review round-4 verification): testing
        // only `line[c + 2] !== "<"` left the SECOND `<` reading `<< <arg>` as an opener,
        // so the here-string's ARGUMENT became a fake delimiter, the fake never appeared as
        // a line, the rest of the command was masked to EOF, and a real `git checkout --
        // f` on a later line ran ungated (measured: ALLOW here, BLOCK on the immediately
        // preceding revision; `cat <<< 1`, `<<< "a b"`, `<<< -x`, `<<<'a b'` all did it,
        // and the identifier-shaped `cat <<< x` was ALREADY open on origin/main). Hence
        // `line[c - 1] !== "<"` as well: an opener starts at the FIRST `<` of its run.
        if (arith === 0 && ch === "<" && line[c + 1] === "<" && line[c + 2] !== "<" && line[c - 1] !== "<") {
          const hm = /^<<-?\s*(?:'([^']*)'|"([^"]*)"|([^\s;&|<>()'"`$\\]+))/.exec(line.slice(c));
          if (hm) {
            const delim = hm[1] ?? hm[2] ?? hm[3] ?? "";
            if (delim) hits.push({ delim, strip: /^<<-/.test(hm[0]) });
          }
        }
        atWordStart = /\s/.test(ch);
      }
    }
    if (hits.length === 0) continue;
    for (const hit of hits) {
      let closed = false;
      for (i++; i < lines.length; i++) {
        const body = hit.strip ? lines[i].replace(/^\t+/, "") : lines[i];
        masked.push(" ".repeat(lines[i].length));
        if (body === hit.delim) { closed = true; break; }
      }
      // An UNTERMINATED heredoc: bash fails the whole command with a syntax error, so
      // masking the rest is inert — and it is what this function did before.
      if (!closed) break;
    }
  }
  return masked.join("\n");
}

/** #1885 — the ABSOLUTE offset of the SEGMENT containing `abs` (review round-3 G4 + its
 *  verification). bash expands a command word BEFORE it applies the `NAME=value` words
 *  written in the same command — they are an ENV PREFIX, not an assignment the command
 *  sees: `S=./noop.sh; S=./undo.sh $S` runs `./noop.sh`, and `P=./undo.sh bash -c "$P"`
 *  runs `bash -c ""`. So "the last assignment before the reference" is the wrong boundary;
 *  the fold must stop at the start of the reference's own command.
 *
 *  ⛔ THAT BOUNDARY IS THE WHOLE SEGMENT, NOT THE LAST `|` (review round-3 verification).
 *  Inside one segment every `NAME=value` word is a prefix of SOME pipeline stage, and a
 *  pipeline's stages run in SUBSHELLS — `S=./undo1885.sh; S=./noop1885.sh | $S` expands
 *  `$S` to the PARENT's `./undo1885.sh` and discards (measured), so an assignment to the
 *  left of a `|` must not be folded either. An earlier cut reset the boundary at each
 *  `|` and folded that left-hand prefix, which ALLOWED a real discard.
 *
 *  A separator ENDS a segment — `;`, `&`/`&&`, a newline. All of them are recognised with
 *  the SAME quoting and redirection rules the rest of the arm uses: a separator inside a
 *  quoted word is literal, a backslash escapes, and the `&` of `2>&1` / `&>` is part of a
 *  REDIRECTION (not a separator — reading it as one would put the boundary past the
 *  redirection).
 *
 *  It scans the HEREDOC-MASKED command, because the mask is length-preserving and a
 *  body's `;` is DATA: reading it as a separator would move the boundary LATER, which can
 *  only ever hide an assignment — the fail-open direction.
 *
 *  The returned scanner advances a cursor, so the per-reference cost over one command is
 *  the command's length ONCE, not once per reference (the O(refs x len) regression the
 *  fold's single-walk design exists to avoid). A BACKWARDS query rescans from 0: the
 *  callers emit source order, so that is a bug signal, and serving a stale boundary to it
 *  would be a fail-open. */
function _wtSimpleCommandAbsScanner(command: string): (abs: number) => number {
  const s = _wtMaskHeredocBodies(String(command ?? ""));
  let i = 0;
  let start = 0;
  let quote: string | null = null;
  return (abs: number) => {
    const end = Math.max(0, Math.min(abs, s.length));
    if (end < i) { i = 0; start = 0; quote = null; }
    for (; i < end; i++) {
      const c = s[i];
      if (quote) {
        if (c === "\\" && quote === '"') { i++; continue; }
        if (c === quote) quote = null;
        continue;
      }
      if (c === "\\") { i++; continue; }
      if (c === "'" || c === '"') { quote = c; continue; }
      if (c === "\n" || c === ";") { start = i + 1; continue; }
      if (c === "&") {
        // `2>&1`, `&>/dev/null` — a REDIRECTION, not a separator (the same rule
        // `_wtSegmentsWithOffsets` applies), and `|&` is ONE pipe operator, so its `&` is
        // not a separator either (reading it as one put a pipeline's left-hand prefix in a
        // PRECEDING segment, where the fold picks it up — measured ALLOW on
        // `S=./undo1885.sh; S=./noop1885.sh |& $S`). `&&` and a backgrounding `&` are.
        if (s[i - 1] === ">" || s[i + 1] === ">" || s[i - 1] === "|") continue;
        start = i + 1;
        if (s[i + 1] === "&") i++;
        continue;
      }
      // ⛔ `|` / `||` / `|&` are NOT boundaries: a pipeline's stages run in SUBSHELLS, so an
      // assignment to the left of one is never in effect for the right-hand command.
      // Resetting here FOLDED that left-hand prefix and ALLOWED a real discard
      // (`S=./undo1885.sh; S=./noop1885.sh | $S`, measured).
    }
    return start;
  };
}

/** One-shot form of {@link _wtSimpleCommandAbsScanner} (a single query per command). */
function _wtSimpleCommandAbs(command: string, abs: number): number {
  return _wtSimpleCommandAbsScanner(command)(abs);
}
/** #1885 — is an INLINE payload token expanded by the PARENT shell, or DEFERRED to a
 *  second parse? (review round-3 verification)
 *
 *  The simple-command boundary above exists because bash expands a command word BEFORE
 *  it applies the command's own `NAME=value` words — so for a PARENT-expanded reference
 *  the prefix is not in effect (`P=./undo1885.sh bash -c "$P"` really is
 *  `bash -c ""`). A SINGLE-QUOTED payload is NOT expanded by the parent: the child
 *  shell expands `$P` from its ENVIRONMENT, which DOES carry that prefix — so there the
 *  prefix IS the value that runs (`P=./undo1885.sh bash -c '$P'` runs `./undo1885.sh`,
 *  measured). Applying the boundary to the deferred spelling therefore turned a real
 *  discard into an ALLOW (measured on this handler; the verifier caught it).
 *
 *  `eval` is the same split: `eval "$P"` is expanded by the parent, `eval '$P'` is
 *  re-parsed by `eval` in a shell where the prefix IS in the environment (both measured).
 *
 *  Because the caller has already matched the whole token against `$NAME` / `${NAME}`,
 *  a single-quote character in the token is exactly the deferred case: the token is the
 *  reference plus its quoting, nothing else. */
function _wtInlinePayloadParentExpanded(token: string): boolean {
  return !/'/.test(String(token ?? ""));
}

/** #1885 — every same-command `NAME=value` / `NAME+=value` assignment, IN ORDER, with
 *  the value as written and its (segment, offset), so a caller can decide what was in
 *  effect AT A USE SITE.
 *
 *  QUOTE-AWARE, deliberately (review P1): a raw regex over the segment text also matched
 *  text inside a quoted STRING (`echo ' P=ls'`), which then won the positional read and
 *  turned a real discard into an allow — a narrowing of the pre-existing `eval` arm. The
 *  scan walks each segment with the same quote and escape rules `_dequoteShellWord`
 *  uses, so an assignment is only seen where the SHELL would perform one.
 *
 *  Why this is a SECOND reader and not `_wtCommandVars`: the two answer different
 *  questions and must keep answering them differently. A write target (#1060) wants the
 *  CONSERVATIVE answer — a name assigned twice, or to anything it cannot read, is dropped
 *  so the ancestor walk stays wide. An EXECUTED command word (#1885) wants the SHELL's
 *  answer at that point in the command. One quote-aware scan, and every consumer projects
 *  it POSITIONALLY (`_wtAssignBefore` / `_wtAssignBeforeAbs`), each named for what it
 *  decides.
 *
 *  `abs` is the assignment's offset in the WHOLE command, so a caller that knows where its
 *  use site is (the `eval` and `-c` payload arms do — review P1) can ask the same
 *  positional question the command-position arm asks, instead of "what is the last
 *  assignment anywhere". The heredoc mask is length-preserving and the keyword-prefix
 *  strip is measured, so `abs` addresses the ORIGINAL string. */
function _wtAssignmentsIn(command: string, mask = true): { name: string; text: string; append: boolean; seg: number; at: number; abs: number }[] {
  const out: { name: string; text: string; append: boolean; seg: number; at: number; abs: number }[] = [];
  // ⛔ MASKED HERE TOO, and for the same reason `_wtCommandWordRefs` masks (review P1):
  // an UNMASKED heredoc body splits into extra segments, so every segment index after it
  // differed between the two readers and `_wtAssignBefore`'s `a.seg > seg` test then threw
  // the assignment away — one heredoc before the invocation disabled the whole arm. The
  // mask is length-preserving and idempotent, so applying it in both readers keeps their
  // offsets identical.
  const segs = _wtSegmentsWithOffsets(mask ? _wtMaskHeredocBodies(command) : String(command ?? ""));
  for (let si = 0; si < segs.length; si++) {
    // `export S=…` / `declare S=…` / `local S=…` assign exactly like `S=…`. The stripped
    // prefix is MEASURED, not just removed: `abs` below must still address the original
    // command, and a prefix silently shortening the segment would shift every offset
    // after it by its length (review P1).
    const prefix = /^\s*(?:then|do|else|elif|if|while|until|for|fi|export|declare|local|readonly|typeset)\b/.exec(segs[si].text);
    const segAt = segs[si].at + (prefix ? prefix[0].length : 0);
    const seg = prefix ? segs[si].text.slice(prefix[0].length) : segs[si].text;
    let quote: string | null = null;
    for (let i = 0; i < seg.length; i++) {
      const c = seg[i];
      if (quote) {
        if (c === "\\") { i++; continue; }
        if (c === quote) quote = null;
        continue;
      }
      if (c === "'" || c === '"') { quote = c; continue; }
      if (c !== "\\" && (i === 0 || /[\s;&|({]/.test(seg[i - 1]))) {
        const m = /^([A-Za-z_][A-Za-z0-9_]*)(\+?)=/.exec(seg.slice(i));
        if (m) {
          const text = _wtAssignValueAt(seg, i + m[0].length);
          out.push({ name: m[1], text, append: m[2] === "+", seg: si, at: i, abs: segAt + i });
          i += m[0].length + text.length - 1;
          continue;
        }
      }
      if (c === "\\") i++;
    }
  }
  return out;
}

/** #1885 — what each name holds AT a use site: the last assignment STRICTLY BEFORE it.
 *  Position, not "last in the command" (review P1): `S=./undo.sh; $S; S=./noop.sh` runs
 *  `./undo.sh`, so a later assignment must not launder the earlier one.
 *
 *  ⛔ RESOLVED AT ASSIGNMENT TIME, not at the use site (review P1). bash expands a
 *  value when the ASSIGNMENT runs, so what a name holds is fixed at that point —
 *  `S=./undo.sh; T=$S; S=./noop.sh; $T` runs `./undo.sh`, but recording `T`'s RAW text
 *  and substituting at the use site resolved it to the LATER, benign `./noop.sh` and
 *  ALLOWED the discard (measured). Each assignment is therefore substituted against
 *  the map built by the assignments strictly BEFORE it, and only the resolved text is
 *  stored.
 *
 *  ONE FOLD, MANY POSITIONS (review P2): `_wtAssignmentsIn` is a full re-split +
 *  re-mask + re-walk, and re-running it per reference was O(refs x len) — ~1 s on a
 *  50 KB command with 200 assignments and 200 references. It now runs ONCE per command
 *  and the returned closure walks the (ascending) assignment list forward, folding only
 *  the assignments that fall between two references. A position that moves BACKWARDS
 *  rebuilds from the start: `_wtCommandWordRefs` emits source order, so that is a bug
 *  signal, and serving a stale map to it would be a fail-open.
 *
 *  `_wtAssignBeforeAbs` is the SAME fold asked by ABSOLUTE command offset, for the two
 *  callers that know where their payload starts but cannot name a segment — the `eval`
 *  and interpreter `-c` payload arms (review P1). Both build on one fold step
 *  (`_wtAssignFoldOne`): a second definition of "how an assignment folds" is a second
 *  answer to "what does this name hold", which is the drift this arm exists to remove. */
type _WtAssign = { name: string; text: string; append: boolean; seg: number; at: number; abs: number };

/** The value a name would EXPAND to right now: its readable literal when there is one,
 *  else its (possibly still unreadable) text. Shared with `_wtSubstituteVars`, which
 *  leaves an unknown name VERBATIM. */
function _wtAssignVarsNow(literal: Map<string, string>, text: Map<string, string>): Map<string, string> {
  const m = new Map<string, string>();
  for (const [k, v] of text) m.set(k, literal.get(k) ?? v);
  for (const [k, v] of literal) if (!m.has(k)) m.set(k, v);
  return m;
}

/** #1885 — ONE `${!NAME}` hop inside an assignment VALUE (review round-3 G3). The arm
 *  already resolves `${!NAME}` in COMMAND position, and `_wtSubstituteVars` expands only
 *  `${NAME}` / `$NAME`, so a value spelled `A=${!S}` stayed verbatim, the fold dropped the
 *  literal (`/[{}]/`), and the use site `$A` fell to "nothing readable, not path-shaped ⇒
 *  allow" — while bash ran the script the hop names (measured: `S=T; T=./undo.sh;
 *  A=${!S}; $A` ALLOWED, discarding `dirty.txt`).
 *
 *  The hop is resolved against the maps in effect AT THIS ASSIGNMENT, which is the same
 *  one-hop rule the command-word arm applies: `S` holds the NAME, and that name's value is
 *  what `A` receives. Only ONE hop — a chain is the same open-ended expansion family the
 *  README declares, and guessing a second hop is a second answer to "what does this
 *  hold".
 *
 *  LEAVE-VERBATIM cases, both deliberate: the inner name is assigned NOWHERE in this
 *  command (env-fed — documented residual 1: `A=${!B}; $A` stays ALLOWED), and the inner
 *  value is not a variable NAME (`${!…}` then denotes no readable value; bash itself
 *  errors on it). An unreadable HOP TARGET is left as that unreadable text — never a
 *  fabricated literal — so the use site's path-shape test decides, and a value that is
 *  path-shaped still fails CLOSED rather than falling to the allow arm. */
function _wtResolveIndirectHop(value: string, vars: Map<string, string>): string {
  if (!value.includes("${")) return value;
  return value.replace(/\$\{!([A-Za-z_][A-Za-z0-9_]*)\}/g, (whole, inner: string) => {
    const target = vars.get(inner);
    if (target === undefined) return whole;              // env-fed inner name — residual 1
    const tname = target.trim();
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(tname)) return whole;
    const hop = vars.get(tname);
    return hop === undefined ? whole : hop;              // env-fed hop target — residual 1
  });
}

/** Fold ONE assignment onto the state, resolving it against what was in effect before it
 *  (bash's eager expansion). `+=` onto a base that cannot be read is UNREADABLE — never
 *  the appended tail alone, since `S=$(pwd); S+=/undo.sh` holds `$(pwd)/undo.sh`. */
function _wtAssignFoldOne(
  a: { name: string; text: string; append: boolean },
  literal: Map<string, string>,
  text: Map<string, string>,
): void {
  // Substitution is skipped entirely unless the value can CONTAIN a reference, so the
  // common literal assignment costs nothing.
  const varsNow = a.text.includes("$") ? _wtAssignVarsNow(literal, text) : null;
  const value = varsNow ? _wtResolveIndirectHop(a.text, varsNow) : a.text;
  const resolved = varsNow ? _wtSubstituteVars(value, varsNow) : value;
  const deq = _dequoteShellWord(resolved);
  const prevLit = literal.get(a.name);
  const combined = a.append ? (prevLit === undefined ? null : prevLit + deq) : deq;
  text.set(a.name, a.append && text.has(a.name) ? text.get(a.name)! + resolved : resolved);
  if (combined === null || !combined || /[$`]/.test(combined) || /[{}]/.test(combined)) literal.delete(a.name);
  else literal.set(a.name, combined);
}

function _wtAssignBefore(assigns: _WtAssign[]):
  (seg: number, at: number, commandAbsStart?: number) => { literal: Map<string, string>; text: Map<string, string> } {
  const literal = new Map<string, string>();
  const text = new Map<string, string>();
  let cursor = 0;
  let prevSeg = -1;
  let prevAt = -1;
  return (seg: number, at: number, commandAbsStart = -1) => {
    if (seg < prevSeg || (seg === prevSeg && at < prevAt)) {
      cursor = 0;
      literal.clear();
      text.clear();
    }
    while (cursor < assigns.length) {
      const a = assigns[cursor];
      if (a.seg > seg || (a.seg === seg && a.at >= at)) break;
      // ⛔ ENV PREFIX, not an assignment (review round-3 G4). An assignment written in the
      // reference's OWN simple command is applied to that command's ENVIRONMENT, after
      // bash has already expanded its command word, so it is not "in effect" there:
      // `S=./noop.sh; S=./undo.sh $S` runs `./noop.sh`. `commandAbsStart` is the simple
      // command's absolute start (`_wtSimpleCommandAbsScanner`); -1 means the caller could
      // not establish one, and then the fold behaves as before rather than skipping.
      if (commandAbsStart >= 0 && a.abs >= commandAbsStart) break;
      _wtAssignFoldOne(a, literal, text);
      cursor++;
    }
    prevSeg = seg;
    prevAt = at;
    return { literal, text };
  };
}

/** #1885 — the same question by ABSOLUTE offset in the command (review P1). The `eval`
 *  and interpreter `-c` payload arms know where their payload starts, so they must read
 *  the assignment in effect THERE — not "the last one in the command" (which laundered
 *  `P='./undo.sh'; eval "$P"; P=ls` into an ALLOW) and not "drop the name when it is
 *  assigned twice" (which dropped BOTH and let the payload fall through to a verb test
 *  that cannot see a verb inside the script it names). Fresh state per call: a payload
 *  arm asks this once or twice per command, so there is nothing to carry. */
function _wtAssignBeforeAbs(assigns: _WtAssign[], abs: number): { literal: Map<string, string>; text: Map<string, string> } {
  const literal = new Map<string, string>();
  const text = new Map<string, string>();
  for (const a of assigns) {
    if (a.abs >= abs) break;
    _wtAssignFoldOne(a, literal, text);
  }
  return { literal, text };
}

/** #1885 — true when the command assigns `name` at or BEFORE the absolute offset `abs`
 *  (heredoc bodies included). Used only by the payload arms' fail-closed clause, and
 *  BOUNDED the same way the fold is (review round-3 G4): a same-simple-command
 *  `NAME=…` ENV PREFIX is not a value a PARENT-expanded payload can see, so it must not
 *  turn an unresolved payload into a refusal (`P=./undo1885.sh bash -c "$P"` runs
 *  `bash -c ""`). A DEFERRED payload keeps the unbounded-to-the-payload reading instead
 *  (see `_wtInlinePayloadParentExpanded`), because the prefix IS in the environment the
 *  child expands from. The UNMASKED list is what
 *  keeps origin/main's posture for the cases the mask hides — a value assigned only in a
 *  heredoc BODY is still "assigned, not readable at the call site" and still fails closed.
 *  `abs` < 0 means "anywhere" (the unbounded question). */
function _wtAssignsName(command: string, name: string, abs = -1): boolean {
  return _wtAssignmentsIn(command, false).some((a) => a.name === name && (abs < 0 || a.abs < abs));
}

/** #1885 — shell METACHARACTERS the shared tokenizer leaves attached to their word, split
 *  out as their own tokens.
 *
 *  `wtShellWords` splits on whitespace ONLY, and it is SHARED with the extractor, so it is
 *  not the place to change this. The consequence here was a fail-open one keystroke wide:
 *  `$S|cat` is ONE word, so the reference's suffix pattern took `|cat` as the LITERAL path
 *  suffix (`_wtLiteralSuffix` below), the composed path `./undo.sh|cat` did not exist,
 *  `realpathSync` threw, the `catch` swallowed it, no seed was pushed and the discarding
 *  script ran UNGATED — while `$S | cat`, with ONE SPACE, was blocked. The same word shape
 *  in the other order (`cat|$S`) hid the reference entirely. Splitting the operator run out
 *  makes `|` / `||` / `>` / `>>` / `2>&1` reach the EXISTING pipe and redirection branches
 *  and the reference reach the command-word branch, for both shapes.
 *
 *  Quoted text is NOT split (bash does not treat a quoted `|` as an operator): the quote
 *  state is tracked exactly as the tokenizer tracks it. `(` and `)` are deliberately NOT
 *  in the set — wrapper debris around a command word is stripped by the scanner and the
 *  `$( … )` / `( … )` bodies have their own arms, so splitting them would change those.
 *  Every produced token is a SUBSTRING of the original word, so the scanner's
 *  `seg.indexOf(word)` offsets still address the segment. */
function _wtSplitMetachars(words: string[]): string[] {
  const META = "|&;<>";
  const out: string[] = [];
  for (const w of words) {
    let cur = "";
    let quote: string | null = null;
    const flush = (): void => { if (cur) { out.push(cur); cur = ""; } };
    for (let i = 0; i < w.length; i++) {
      const ch = w[i];
      if (quote) {
        // Same escape rule as the tokenizer: inside double quotes `\` escapes only
        // `$"` / backtick / backslash / newline.
        if (quote === '"' && ch === "\\" && '"$`\\\n'.includes(w[i + 1] ?? "")) {
          cur += ch + (w[i + 1] ?? ""); i++; continue;
        }
        cur += ch; if (ch === quote) quote = null; continue;
      }
      if (ch === "\\") { cur += ch + (w[i + 1] ?? ""); i++; continue; }
      if (ch === "'" || ch === '"') { quote = ch; cur += ch; continue; }
      if (META.includes(ch)) {
        // A RUN of one metacharacter is ONE operator (`||`, `&&`, `>>`, `<<`). A `>`/`<`
        // followed by `&` (or `&` by a redirect) is the two-character redirect form, so
        // `2>&1` / `&>/dev/null` stay a single operator token for the redirection branch.
        let j = i;
        let run = "";
        while (j < w.length && w[j] === ch) { run += w[j]; j++; }
        if ((ch === ">" || ch === "<") && w[j] === "&") { run += "&"; j++; }
        else if (ch === "&" && (w[j] === ">" || w[j] === "<")) { run += w[j]; j++; }
        // `|&` is bash's pipe-with-stderr, ONE operator (`isPipe` matches `/^\|+&?$/`):
        // splitting it into `|` and `&` made `&` a command word, which ENDED the scan and
        // lost the reference in `S=./noop.sh |& $S` (measured FAIL by the round-3 case).
        else if (ch === "|" && w[j] === "&") { run += "&"; j++; }
        // A FILE-DESCRIPTOR prefix is PART of the redirection (`2>&1`, `2>>out`):
        // splitting `2` off made it a command word, which then ENDED the scan, so
        // `S=./undo.sh; 2>&1 $S` lost its reference (measured FAIL after the first
        // version of this splitter). Keep the digits attached.
        if (/^\d+$/.test(cur) && (ch === ">" || ch === "<" || ch === "&")) {
          cur += run; i = j - 1; continue;
        }
        flush();
        out.push(run);
        i = j - 1;
        continue;
      }
      cur += ch;
    }
    flush();
  }
  return out;
}

/** The LITERAL path suffix carried after a command-position reference (`$S.sh`,
 *  `${S}/x.sh`), CUT at the first shell metacharacter.
 *
 *  A metacharacter after the reference ends the command word — it is never part of the
 *  executed path — so carrying it made the composed path nonexistent and the seed
 *  silently vanish (the fail-open `_wtSplitMetachars` also closes for the unquoted
 *  spelling; this is the belt-and-braces half, and it is what keeps a quoted
 *  `"$S|x"` — where the operator legitimately is not an operator — from manufacturing
 *  a path the shell would never run either). */
function _wtLiteralSuffix(s: string): string {
  const cut = s.search(/[|&;<>]/);
  return cut === -1 ? s : s.slice(0, cut);
}

/** #1885 — the COMMAND WORD of every command segment, when that word is a variable
 *  REFERENCE; `modifier` is true when a parameter-expansion operator is inside the
 *  braces (`${S:?}`, `${S%%.sh}`), because those compute a DIFFERENT string than the
 *  variable holds and cannot be resolved by substitution.
 *
 *  Command position is a script position, and the gate must not depend on how it was
 *  spelled: `bash $S` resolves through `extractScriptPath`, a bare `$S` did not, so
 *  `S=./undo.sh; $S` ran UNGATED while `bash $S` was refused (#1885, measured on this
 *  handler). The scan is per SEGMENT (`true && $S`, `if x; then $S; fi`), and it steps
 *  over the prefixes a shell lets a command word carry: a leading `(`/`{`/`!`, shell
 *  keywords, redirections, `NAME=value` assignments, one spawner wrapper (`env $S`,
 *  `exec $S`, `sudo $S` — `env` counts: it is the commonest of them) and that
 *  wrapper's own options. A trailing `)` / `;` / `}` from the same wrapper is dropped.
 *
 *  A literal SUFFIX after the reference (`$S.sh`, `${S}.sh`, `${D}/bin/x`) is part of the
 *  path the shell executes, so it is carried and composed by the caller. Composition only
 *  ADDS a seed: it never suppresses the pre-existing expanded-token arm, so a path-shaped
 *  `$`-bearing word that arm already refuses stays refused (#1228). */
function _wtCommandWordRefs(text: string): { name: string; modifier: boolean; suffix: string; mod: string; indirect: boolean; seg: number; at: number; abs: number }[] {
  const refs: { name: string; modifier: boolean; suffix: string; mod: string; indirect: boolean; seg: number; at: number; abs: number }[] = [];
  const plain = /^\$\{([A-Za-z_][A-Za-z0-9_]*)\}$|^\$([A-Za-z_][A-Za-z0-9_]*)$/;
  const bracedSuffix = /^\$\{([A-Za-z_][A-Za-z0-9_]*)\}(.*)$/;
  const modified = /^\$\{([A-Za-z_][A-Za-z0-9_]*)([^}]*)/;
  const bareSuffix = /^\$([A-Za-z_][A-Za-z0-9_]*)(.+)$/;
  // ⛔ INDIRECT expansion (`${!NAME}`) is a REFERENCE TOO (review P2). None of the four
  // patterns above matches a leading `!`, so `S=T; T=./undo.sh; ${!S}` produced no
  // reference at all and was ALLOWED — while the interpreter spelling `bash ${!T}` was
  // blocked, i.e. the verdict again depended on the TEXT SHAPE of the invocation.
  const indirect = /^\$\{!([A-Za-z_][A-Za-z0-9_]*)\}/;
  // `builtin` is a WRAPPER, not an INSPECTION (review P2): it DISPATCHES the rest of its
  // words (`builtin exec $S`, `builtin eval $S`), so listing it with `[`/`test`/`type` —
  // whose operands are data — ended the scan at the command word and let
  // `S=./undo.sh; builtin exec $S` run the discarding script UNGATED (measured).
  const WRAPPERS = /^(?:command|exec|env|nohup|nice|time|setsid|stdbuf|ionice|sudo|doas|timeout|catchsegv|builtin)$/;
  const segs = _wtSegmentsWithOffsets(_wtMaskHeredocBodies(text));
  for (let si = 0; si < segs.length; si++) {
    const raw = segs[si].text;
    // Masks are length-preserving, so every offset below still addresses `text`.
    const stripped = raw.replace(/^\s*(?:then|do|else|elif|if|while|until|for|fi)\b/g, "");
    const seg = stripped.trim();
    if (!seg) continue;
    // `at` below is an offset inside `seg`, so the absolute offset of a reference is
    // `segAbsBase + at`. It is MEASURED from what the strip actually removed (the keyword
    // prefix and the leading whitespace), so it addresses the ORIGINAL command — which is
    // the coordinate system `_wtAssignmentsIn`'s `abs` and the payload offsets use, and
    // that is what makes the simple-command boundary (review round-3 G4) comparable at all.
    const segAbsBase = segs[si].at + (raw.length - stripped.length) + (stripped.length - stripped.trimStart().length);
    // `_wtSplitMetachars` (review P2, this branch) and the round-3 `segAbsBase` are
    // INDEPENDENT: the splitter only ever produces SUBSTRINGS of the tokenizer's words,
    // in order, so `seg.indexOf(word, cursor)` below still yields `at` for every token.
    const words = _wtSplitMetachars(wtShellWords(seg));
    // Wrapper flags that TAKE A VALUE, per wrapper. A blanket "any option takes a value"
    // rule ate the command word itself (`env -i $S`), and skipping only the flag made the
    // option's VALUE the command word (`nice -n 5 $S`) — both measured (review P1).
    const VALUE_OPTS: Record<string, RegExp> = {
      // `exec -a NAME cmd` — `-a` sets the command's argv[0], so its VALUE is a name, never
      // the command. Without this entry `-a` was skipped as a bare flag and its VALUE became
      // the command word, so `S=./undo.sh; exec -a x $S` (and the `builtin exec -a x $S`
      // spelling) ran the discarding script with `$S` treated as an ARGUMENT (measured).
      exec: /^-a$/,
      nice: /^(?:-n|--adjustment)$/,
      sudo: /^(?:-[ugChprtT]|--user|--group|--chdir|--prompt|--role|--type|--host|--close-from)$/,
      doas: /^(?:-[uC]|--user)$/,
      env: /^(?:-[uCS]|--unset|--chdir|--split-string)$/,
      ionice: /^(?:-[cnp]|--class|--classdata|--pid)$/,
      stdbuf: /^(?:-[ioe]|--input|--output|--error)$/,
      timeout: /^(?:-[sk]|--signal|--kill-after)$/,
      setsid: /^-$/,
    };
    const isPipe = (w: string): boolean => /^\|+&?$/.test(w.trim());
    // ⛔ EVERY command word of the segment is collected, not just the last one that
    // survived (review P1). The old scan NULLED its single `commandWord` on finding a
    // following pipe and only assigned again on the NEXT command word, so in
    // `S=./undo.sh; $S | cat` the sole surviving word was `cat`: the reference produced
    // no ref at all, the whole #1885 arm was skipped, and bash ran `./undo.sh` (measured,
    // ALLOWED). `S=./undo.sh; $S || true` is the same hole, and `S=./undo.sh; cat | $S`
    // was blocked only because the reference happened to be POSITIONALLY last — a
    // positional asymmetry, not a semantic rule.
    const commandWords: string[] = [];
    let i = 0;
    while (i < words.length) {
      const w = _dequoteShellWord(words[i]);
      // `(` / `{` / `!` / `|` separate or negate a COMMAND and are noise here. `[` / `[[`
      // are NOT: they are commands whose operand is data (`[ "$S" = x ]` runs nothing), so
      // stripping `[` made the operand look like the command word (review P2).
      if (isPipe(w)) { i++; continue; }
      const bare = w.replace(/^[(\{!]+/, "");
      if (!bare) { i++; continue; }                         // `(` / `{` / `!` alone
      if (/^[A-Za-z_][A-Za-z0-9_]*\+?=/.test(bare)) { i++; continue; }   // assignment
      if (/^\d*&?>>?/.test(bare) || /^\d*[<>]/.test(bare)) {
        // A redirection, with or without its attached target (`>out`, `2>&1`, `&>/dev/null`).
        if (/^\d*&?>>?$/.test(bare) || /^\d*[<>]+$/.test(bare)) i++;     // separate target word
        i++;
        continue;
      }
      const kw = bare.replace(/^.*\//, "");
      // An INSPECTION command: its operands are data, never executed. It ends ITS OWN
      // COMMAND only — `break`, never `return refs` (review P1), which aborted the scan for
      // the WHOLE command and re-opened #1885 behind one innocuous `[ -f x ];` prefix.
      //
      // ⛔ AND IT ENDS AT THE NEXT `||`, not at the end of the segment (review P2):
      // `[ -f zzz ] || $S` is ONE segment here (this splitter deliberately keeps `||`
      // inside it, see `_wtSegmentsWithOffsets`), and bash runs `$S` when the test fails.
      // Breaking out of the word loop skipped that invocation entirely; the scan now steps
      // over the pipe word exactly as the command-word path below does.
      //
      // ⛔ `builtin` is NOT here: it is a WRAPPER (below), because `builtin exec $S` RUNS
      // `$S`. Listing it as inspection ended the scan at the command word and allowed the
      // discard.
      if (/^(?:\[|\[\[|test|type|hash|which)$/.test(kw)) {
        let k = i + 1;
        while (k < words.length && !isPipe(_dequoteShellWord(words[k]))) k++;
        if (k >= words.length) break;
        i = k + 1;
        continue;
      }
      if (WRAPPERS.test(kw)) {
        // `command -v|-pv|-p -v $S` INSPECTS its operand instead of running it (review P2).
        if (kw === "command") {
          let j = i + 1, inspect = false;
          while (j < words.length && /^-/.test(_dequoteShellWord(words[j]))) {
            if (/^-[pP]*[vV][pPvV]*$/.test(_dequoteShellWord(words[j]))) inspect = true;
            j++;
          }
          if (inspect) {
            // Same `||` rule as the inspection arm above (review P2).
            let k = i + 1;
            while (k < words.length && !isPipe(_dequoteShellWord(words[k]))) k++;
            if (k >= words.length) { i = words.length; break; }
            i = k + 1;
            continue;
          }
        }
        i++;
        const valOpt = VALUE_OPTS[kw];
        while (i < words.length) {
          const opt = _dequoteShellWord(words[i]);
          if (!/^-/.test(opt)) break;
          const takesValue = valOpt ? valOpt.test(opt) : false;
          i++;
          if (takesValue && i < words.length) i++;
        }
        // `timeout 5 cmd` / `timeout -s KILL $T cmd` — the DURATION is the first operand by
        // SYNTAX, literal or not, so it is skipped unconditionally (review P2).
        if (kw === "timeout" && i < words.length) i++;
        continue;
      }
      // The first real word is this command's command word. A following `||` / `|` starts
      // ANOTHER command (`false || $S`), so the scan continues after it (review P1).
      commandWords.push(w);
      i++;
      let k = i;
      while (k < words.length && !isPipe(_dequoteShellWord(words[k]))) k++;
      if (k >= words.length) break;
      i = k + 1;
    }
    if (commandWords.length === 0) continue;
    // ⛔ MONOTONIC offset per word (review P1): `seg.indexOf(word)` always returns the
    // FIRST occurrence, so a word used twice in one segment read the value in effect at
    // the EARLIER use for both. A forward cursor gives each occurrence its own position.
    let searchFrom = 0;
    for (const word of commandWords) {
      // Trailing wrapper debris only. A `}` is stripped ONLY when it is not closing a
      // `${…}` expansion — `${S}` lost its brace to this and stopped matching at all.
      // ⛔ And a LEADING wrapper is debris too (review round-4, FAIL-OPEN): a group or
      // negation around the command word (`($S)`, `(${S})`, `!($S)`) is ONE shell word, so
      // the whole word was pushed with its wrapper attached, `/^\$NAME$/` never matched,
      // no reference existed, and the whole #1885 arm was skipped — ALLOW, while the
      // LITERAL spelling `(./undo.sh)` is blocked by the direct-word arm. The wrapper is
      // stripped for the REFERENCE MATCH only: `at`/`abs` below come from
      // `seg.indexOf(word)` on the ORIGINAL word (the stripped form is a substring of it,
      // so those offsets still point at the command word in the command).
      let dq = _dequoteShellWord(word).replace(/^[({!]+/, "").replace(/[);]+$/, "");
      if (!dq.startsWith("${")) dq = dq.replace(/\}+$/, "");
      // The offset of the command word inside its segment, so the caller reads the value in
      // effect AT this point (an assignment later in the command does not apply).
      const found = seg.indexOf(word, searchFrom);
      const at = found >= 0 ? found : Math.max(0, seg.indexOf(word));
      if (found >= 0) searchFrom = found + word.length;
      const ind = indirect.exec(dq);
      if (ind) { refs.push({ name: ind[1], modifier: false, suffix: dq.slice(ind[0].length), mod: "", indirect: true, seg: si, at, abs: segAbsBase + at }); continue; }
      const p = plain.exec(dq);
      if (p) { refs.push({ name: p[1] ?? p[2], modifier: false, suffix: "", mod: "", indirect: false, seg: si, at, abs: segAbsBase + at }); continue; }
      // `${NAME}/rest` and `$NAME/rest`: the base is exactly the variable, and the rest is
      // literal, so the executed path IS computable — composing it ADDS a seed (and can only
      // ever add a block). It never suppresses the pre-existing expanded-token arm, so a
      // shape that arm already refuses stays refused.
      const bs = bracedSuffix.exec(dq);
      if (bs) { refs.push({ name: bs[1], modifier: false, suffix: _wtLiteralSuffix(bs[2]), mod: "", indirect: false, seg: si, at, abs: segAbsBase + at }); continue; }
      const baresuf = bareSuffix.exec(dq);
      if (baresuf) { refs.push({ name: baresuf[1], modifier: false, suffix: _wtLiteralSuffix(baresuf[2]), mod: "", indirect: false, seg: si, at, abs: segAbsBase + at }); continue; }
      const m = modified.exec(dq);
      if (m) refs.push({ name: m[1], modifier: true, suffix: "", mod: m[2], indirect: false, seg: si, at, abs: segAbsBase + at });
    }
  }
  return refs;
}

/**
 * #1885 — the executable FILE(s) a resolved command-word candidate denotes, as seed paths.
 *  Path shape first (a plain `undo.sh` resolves through PATH, not through the cwd file),
 *  then the shell's WORD SPLIT: an UNQUOTED `$NAME` is split, so its FIRST field is a word
 *  the shell tries to run (`S="./undo.sh --flag"` runs `./undo.sh`), while a QUOTED
 *  reference is one word — BOTH are seeded, because a seed only ever ADDS a probe.
 *
 *  ⛔ The field set is the TRIMMED split, DEDUPLICATED (review P1): a PADDED value
 *  (`S=' ./undo.sh'`, `S="./undo.sh "`, a tab) has ONE non-empty field, so the old
 *  `fields.length > 1` test kept only the PADDED string — `realpathSync` threw on it, the
 *  `catch {}` swallowed the throw, and bash word-split the value to the real script
 *  (measured: ALLOWED while `S='./undo.sh'; $S` was blocked).
 *
 *  `expanded: true` means the candidate is a SHAPE the shell resolves at runtime, so no
 *  spelling of it can be read and the caller must fail closed.
 */
function _wtExecutableSeeds(candidate: string, execCwd: string): { seeds: string[]; expanded: boolean } {
  if (!(candidate.includes("/") || candidate.startsWith("~"))) return { seeds: [], expanded: false };
  if (_wtPathNeedsExpansion(candidate)) return { seeds: [], expanded: true };
  const seeds: string[] = [];
  for (const cand of new Set([candidate, ...candidate.trim().split(/\s+/).filter(Boolean)])) {
    try {
      const p = realpathSync(resolve(execCwd, cand));
      const st = statSync(p);
      if (st.isFile() && (st.mode & 0o111) !== 0) seeds.push(cand);
    } catch { /* nonexistent/non-executable — not a script invocation */ }
  }
  return { seeds, expanded: false };
}

/** Bounded porcelain probe for a discard's target checkout.
 *  @returns true = would destroy uncommitted work; false = nothing to destroy;
 *           null = unverifiable (caller fails closed). */
function _discardStatusPorcelain(probeCwd: string, d: { scope: string; pathspecs: string[]; fromTree?: boolean }): boolean | null {
  try {
    const args = ["status", "--porcelain=v1"];
    if (d.scope === "paths" && d.pathspecs.length > 0) args.push("--", ...d.pathspecs);
    // execFileSync (array args, no shell): pathspecs are DATA — a path
    // containing shell metacharacters can never become a command.
    //
    // #1139 (review P1): stderr is PIPED, not ignored. With a terminal `ignore`
    // Node leaves `error.stderr` null and `error.message` is only
    // `Command failed: git status …`, so the not-a-checkout test below could
    // NEVER match and the documented fail-open carve-out was DEAD CODE — a
    // discard whose resolved target is not a checkout was always blocked with
    // `null` (and, before #1139, with a message claiming the checkout was
    // dirty). Capturing stderr is what makes the branch reachable.
    const out = execFileSync("git", args, {
      cwd: probeCwd, encoding: "utf-8", timeout: 5000, stdio: ["ignore", "pipe", "pipe"],
    });
    return discardDestroysWip(String(out), d);
  } catch (e) {
    const msg = String((e as { stderr?: unknown })?.stderr ?? "") + String((e as { message?: string })?.message ?? e);
    // Not a checkout (or a bare repo): there is no working tree to destroy, so
    // this is the probe's one ALLOW arm. Everything else — an unreadable status
    // on a REAL checkout (index.lock contention, permissions, the 5s timeout) —
    // is `null` and fails closed at the caller.
    if (/not a git repository|must be run in a work tree|does not have a working tree/i.test(msg)) return false;
    return null; // unverifiable → fail closed
  }
}

/** Characters a backslash escapes INSIDE double quotes (POSIX: `$`, `` ` ``, `"`, `\`, newline).
 *  Outside quotes and inside them the rule differs, which is what
 *  `_dequoteShellWord` and the shared `wtShellWords` tokenizer must agree on. */
const _DQ_ESCAPABLE = new Set(["\"", "$", "`", "\\", "\n"]);

/**
 * Strip ONE shell word's quoting/escaping, the way the shell does (#1139,
 * review cycle-3 P1). `wtShellWords` returns words with their quotes and
 * escapes still in place; resolving a file path from one therefore needs a
 * faithful unquote, not a blanket character strip.
 *
 * HISTORY — the first two attempts were both wrong, in opposite directions.
 * A whitespace split with the quotes LEFT ON never resolved `"undo.sh"`
 * (fail-OPEN: a discard in a quoted piped script ran ungated). Replacing every
 * `["']` and every backslash anywhere in the token then mis-read the cases
 * where those characters are LITERAL: `'a\b.sh'` is one file named `a\b.sh`,
 * but the blanket strip produced `ab.sh` — a seed for a file the shell never
 * reads, and (worse than the residual it left) a REGRESSION against the
 * parent commit, where `a\b.sh` had been seeded correctly. The rules below are
 * the shell's: single quotes are literal until closed, a backslash escapes
 * anything outside quotes, and inside double quotes only `$`, `` ` ``, `"`,
 * `\` and newline.
 */
function _dequoteShellWord(raw: string): string {
  let out = "";
  let quote: string | null = null;
  for (let i = 0; i < raw.length; i++) {
    const c = raw[i];
    if (quote === "'") { if (c === "'") quote = null; else out += c; continue; }
    if (quote === "\"") {
      if (c === "\"") { quote = null; continue; }
      if (c === "\\" && _DQ_ESCAPABLE.has(raw[i + 1] ?? "")) { out += raw[i + 1]; i++; continue; }
      out += c; continue;
    }
    if (c === "'" || c === "\"") { quote = c; continue; }
    if (c === "\\") { out += raw[i + 1] ?? ""; i++; continue; }
    out += c;
  }
  return out;
}

/** Shared block reason for M5. */
function _worktreeDiscardBlockReason(
  d: { form: string; scope: string; pathspecs: string[] },
  probeCwd: string,
  unverifiable: string | null,
): string {
  const target = d.pathspecs.length > 0 ? d.pathspecs.slice(0, 5).join(", ") : "(the whole working tree)";
  // #1139 — the two arms must not read alike, and the fail-closed arm must not
  // name a cause it did not establish. The old single wording asserted "This
  // checkout carries uncommitted changes to tracked files that this command
  // would revert" in BOTH arms, which on a provably clean checkout
  // (`git status --porcelain` empty) sent the reader hunting a phantom dirty
  // tree — and printed the AGENT_ALLOW_MAIN_EDITS=1 bypass hatch as the remedy
  // for a discard the guard never located.
  //
  // The fail-closed arm is reached with NINE different reasons, and only two of
  // them are target-resolution failures (`the target pathspec …`, `the
  // invocation's effective repo …`). The rest are payload/script/status
  // failures (script-indirection, piped-shell-payload, eval-payload, the three
  // interpreter `-c` arms, and `the target checkout's status could not be read`
  // — where the target WAS resolved and only the probe failed). So the arm's
  // headline and remedy stay CAUSE-NEUTRAL and defer the specifics to the
  // `⚠️ ${unverifiable}` line above them (review fold-in: a header naming
  // "target not statically resolvable" for every one of the nine is the same
  // misattribution class this function exists to remove).
  // #1139: the remedy must be a REAL file — in the geometry where the guard is
  // loaded from a checkout with no `scripts/` (the T6 fixture), `_frameworkRoot`
  // is non-null but the path does not exist, and printing it would hand the
  // reader a command that cannot run (review cycle-2 P2).
  let sanctionedHelper: string | null = null;
  if (_frameworkRoot) {
    const p = resolve(_frameworkRoot, "scripts/checkout-hygiene/hub-worktree.sh");
    try { if (existsSync(p)) sanctionedHelper = p; } catch { sanctionedHelper = null; }
  }
  return [
    unverifiable !== null
      ? `⛔ Working-tree discard blocked — the discard's effect could not be verified, failing closed (#709).`
      : `⛔ Working-tree discard blocked — it would destroy uncommitted work (#709).`,
    `   Form: ${d.form}   Target: ${target}`,
    `   Checkout: ${probeCwd}`,
    ...(unverifiable !== null ? [`   ⚠️ ${unverifiable} — failing closed.`] : []),
    `   The guard gates the EFFECT, not the verb: \`git checkout -- <path>\``,
    `   classifies as a plain path restore, so it used to run ungated in a`,
    `   linked worktree (where pi -p mutation-test fixers run) and in a CLEAN`,
    `   hub — the 2026-09-10 leaked-mutant path.`,
    ...(unverifiable !== null
      ? [
          `   ⚠️ This block is NOT a claim that the checkout is dirty: the guard`,
          `   could not verify what this command would discard (see the reason`,
          `   line above), so it never compared it against real uncommitted work.`,
          `   Check first:`,
          `       git status --porcelain`,
          `   → Resolve what the guard could not — the reason line above names`,
          `     which of these it is: a literal path / literal \`cd\` (no \`$VAR\` or`,
          `     placeholder), a target whose status you can read, or a script`,
          `     whose discards are statically visible.`,
          `   → The sanctioned recovery surface, if that is what you wanted —`,
          `     address the FRAMEWORK CHECKOUT's own copy, because a`,
          `     worktree-local copy of it is gated by design (#1139):`,
          ...(sanctionedHelper
            ? [`       bash "${sanctionedHelper}" <branch>`]
            : [`       bash <framework-checkout>/scripts/checkout-hygiene/hub-worktree.sh <branch>`]),
          `   → This arm fails closed because the EFFECT was unverifiable, not`,
          `     because uncommitted work was found, so AGENT_ALLOW_MAIN_EDITS=1 is`,
          `     not its remedy: the hatch suppresses the whole gate instead of`,
          `     resolving the reason.`,
        ]
      : [
          `   This checkout carries uncommitted changes to tracked files that`,
          `   this command would revert (\`git status --porcelain\` was read for`,
          `   this scope).`,
          `   → Probe a mutation on a COPY, never in place (#664):`,
          `       D=$(git rev-parse --show-toplevel)/.worktrees/scratch-$$`,
          `       git worktree add --detach "$D" <ref>; ( cd "$D" && <cmd> )`,
          `       rm -rf "$D"                        # TREE first, then the record:`,
          `       git worktree remove --force "$D"   # this drops the record even when it`,
          `       # FAILS to delete the dir, so the reverse order hides a survivor.`,
          `       # Remove THAT record too if needed — a bare \`git worktree prune\``,
          `       # deregisters every worktree whose dir is not stat-able right now,`,
          `       # unrelated siblings included (#1141).`,
          `     A worktree shares the object store. NEVER \`git clone\` / \`cp -R\` /`,
          `     \`rsync\` the repo into /tmp: the copy outlives its owner and costs`,
          `     ~2.4M files of I/O per cycle (#1141). Where it exists, prefer`,
          `     \`scripts/scratch-worktree.sh run ...\` — it removes the worktree itself.`,
          `   → Inspect first: git status --porcelain; git diff <path>.`,
          // Round 4 (P2) — the remedy must depend on whether the hatch is ALREADY
          // active. Telling a hatched reader to stamp the marker it already holds
          // is the incident's "each prescription not working" signature: the real
          // cause is the window's own shape limit (one bare invocation, run from
          // the hub), which this branch never used to name.
          ...(_wtDiscardHatchActive
            ? [
                `   → Your hatch IS active: the window covers ONE bare invocation run`,
                `     from the dirty hub — no \`;\`/\`&&\`/pipe, no redirect, no \`cd … &&\``,
                `     prefix, no \`-C\`/\`GIT_DIR=\` target selection. Run it alone:`,
                `       git checkout -- <path>          # cwd is the hub`,
                // Round 17 (P3): the DIRECTORY carve-out is a documented trade-off;
                // it must be named on the surface a HATCHED reader actually sees
                // (this one), not only in the hatch-inactive text.
                `     NOTE a DIRECTORY operand (\`src\`, \`src/\`) IS admitted and discards that`,
                `     entire subtree, so name a FILE when that is what you mean.`,
              ]
            : [
                // Round 14 (P2): the two hatches are NOT equivalent and this
                // sentence said they were. `AGENT_ALLOW_MAIN_EDITS=1` is a FULL
                // bypass (it returns before M4/M5 are consulted, so `.`/globs ARE
                // permitted under it — measured); only the TTL MARKER opens the
                // narrow window. The pinned phrase is kept verbatim (test.mjs and
                // test-discard-gate pin it) and the scoping is stated around it.
                `   → Deliberate discard: set AGENT_ALLOW_MAIN_EDITS=1 (or`,
                `     ELDATO_ALLOW_MAIN_EDITS=1) — a FULL bypass of M4/M5, whole-tree`,
                `     discards included — or stamp the ~/.pi/agent/.allow-main-edits MARKER,`,
                `     which opens the same narrow recovery window as M4: name the paths,`,
                `     \`git restore <path>\` / \`git checkout -- <path>\`. Refused UNDER THE MARKER:`,
                `     a whole-tree discard (\`.\`, \`./\`, pathspec magic, a glob, a brace) — and`,
                `     NOTE a DIRECTORY operand (\`src\`, \`src/\`) IS admitted and discards that`,
                `     entire subtree, so name a FILE when that is what you mean.`,
              ]),
        ]),
  ].join("\n");
}

/** Placeholder tokens declared by `xargs -I<tok>` / `-I <tok>` — the token is
 *  substituted into the child command at execution time, so it can carry the
 *  code the gate would otherwise walk (`printf … | xargs -I@ sh -c '@'`).
 *  Arbitrary by design, hence read from the invocation instead of `{}`
 *  (reviewer round-8b P1). */
function _wtXargsPlaceholders(command: unknown): string[] {
  const out: string[] = [];
  // Scoped to REAL xargs segments: a bare `-I <arg>` belongs to some other
  // program too often to harvest globally (`grep -I clean.txt` false-blocked a
  // clean checkout, reviewer round-10 P2).
  for (const seg of String(command ?? "").split(/[|;&]/)) {
    // Accept a PATH-QUALIFIED, QUOTED or BACKSLASH-ESCAPED feeder word
    // (`/usr/bin/xargs`, `"xargs"`, `\xargs`) — scoping to a literal `xargs`
    // word let each spelling hide its `-I` placeholder and re-opened the
    // round-9 bypass (reviewer round-10 P1 / round-11 P1).
    if (!/(?:^|[\s(])(?:[\w./-]*\/)?\\?["']?xargs["']?(?![A-Za-z0-9_.-])/.test(seg)) continue;
    // `-J` is BSD xargs' replstr (macOS); `-I` is the POSIX/GNU one.
    for (const m of seg.matchAll(/(?:^|\s)-[IJ]\s*("[^"]*"|'[^']*'|\S+)/g)) {
      const tok = String(m[1] ?? "").replace(/^["']|["']$/g, "");
      if (tok && tok !== "-") out.push(tok);
    }
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

/** #1228 — TRUE when the SHELL decides what a token names at runtime, so the
 *  file it refers to cannot be read as literally spelled. Covers parameter and
 *  command substitution (`$`, backtick), globs (`*`, `?`, `[...]`), brace
 *  expansion (`{a,b}`) and tilde expansion (a LEADING `~`). The tokenizer
 *  strips quotes, so a QUOTED `~`/glob is indistinguishable from an unquoted
 *  one here; both fail closed — a false block costs an operator one retry with
 *  the literal spelling, while the fail-open it replaces loses uncommitted work
 *  silently. */
const _wtPathNeedsExpansion = (p: unknown): boolean => {
  const s = String(p ?? "");
  return /[$`*?[\]{}]/.test(s) || s.startsWith("~");
};

/** The refusal line for a DIRECT/wrapper expansion-shaped script path (#1228):
 *  what was OBSERVED (the expansion-form characters in the path), what it COSTS
 *  (an unreadable script may discard anywhere), and the edit that makes it
 *  verifiable. The runtime expansion is HEDGED, never asserted — a QUOTED
 *  metachar path is not expanded by the shell, and the tokenizer strips quotes
 *  before this looks (#1229/#1210: a refusal must not claim a cause it did not
 *  observe). The piped-producer refusal is a separate line, because it names a
 *  different observation (the producer token). */
const _WT_EXPANDED_SCRIPT_REASON =
  "the script path contains a shell-expansion form (`*`, `?`, `[...]`, " +
  "`{...}`, a leading `~`, `$` or a backtick), so it is not statically " +
  "resolvable as spelled — the shell may expand it at runtime, and an " +
  "unreadable script may discard uncommitted work in ANY checkout; pass the " +
  "path literally (e.g. `bash ./tools/your-script.sh`) so its contents can be " +
  "read and verified";

/** #1228 — split `text` into shell command segments at the separators that
 *  START a new command, ignoring separators inside quotes/escapes. A script
 *  invocation is not always at position 0 (`true && bash ./undo*.sh`,
 *  `if true; then bash ./undo*.sh; fi`); the position-0 arms missed it and the
 *  discard ran ungated (review cycle-2 P0). `|` is split only as `||` so an
 *  extglob `@(a|b)` is not cut in half. */
function _wtCommandSegments(text: string): string[] {
  const s = String(text ?? "");
  const out: string[] = [];
  let cur = "";
  let quote: string | null = null;
  for (let i = 0; i < s.length; i++) {
    const ch = s[i];
    if (quote) { if (ch === quote) quote = null; cur += ch; continue; }
    if (ch === "\\") { cur += ch + (s[i + 1] ?? ""); i++; continue; }
    if (ch === "'" || ch === '"') { quote = ch; cur += ch; continue; }
    if (ch === ";" || ch === "&" || ch === "\n") { out.push(cur); cur = ""; continue; }
    if (ch === "|" && s[i + 1] === "|") { out.push(cur); cur = ""; i++; continue; }
    cur += ch;
  }
  out.push(cur);
  return out.filter((seg) => seg.trim() !== "");
}

/** #1228 — the runtime-EXPANDED file a process substitution hands to an
 *  interpreter (`bash <(cat ./undo*.sh)`), or null. `<(...)` is an interpreter
 *  OPERAND that produces the script at runtime, so an expanded path inside it is
 *  the same unreadable-script hole (review cycle-2 P1). */
function _wtProcessSubExpansion(text: string): string | null {
  for (const m of String(text ?? "").matchAll(/[<>]\(([^()]*)\)/g)) {
    const inner = m[1].trim();
    // Only a process substitution that FEEDS A FILE to the interpreter — the
    // `<(cat <path>)` / `<(<producer>)` shape. A `<(…)` used as an ARGUMENT
    // (`diff <(a) <(b)`, `<(git -C "$repo" worktree list)`) is not a script
    // source and must not be refused (review cycle-2, false-blocked B8i).
    if (/^(?:cat|bat|tac|head|tail)\b/.test(inner) && _wtPathNeedsExpansion(inner)) return inner;
  }
  return null;
}

/** #1228 — the runtime-EXPANDED file a `$(cat …)` / `` `cat …` `` payload reads
 *  as its program source, or null. The STATIC form is handled elsewhere (read
 *  and probed); the expanded form names a file the shell chooses at runtime and
 *  must fail closed (review cycle-2 P0). */
function _wtCatOfExpandedPath(text: string): string | null {
  const m = /^\$\(\s*(?:cat|bat)\s+([^\s)$]+)\s*\)$|^`cat\s+([^`]+)`$/.exec(String(text ?? "").trim());
  const p = m?.[1] ?? m?.[2];
  return p && _wtPathNeedsExpansion(p) ? p : null;
}

/** #1228 — the runtime-EXPANDED script token a SINGLE command segment would run,
 *  or null. The script walk can only verify a path it can read AS SPELLED; an
 *  expanded one names a file the SHELL resolves at run time. Covers the
 *  interpreter operand and direct execution via `extractScriptPath`, the
 *  `~/…` / `sub/…` command-position shapes it misses, and extglob. */
function _wtExpandedScriptTokenIn(text: string): string | null {
  // A directly-executed path candidate. Fragments carrying control operators
  // are `case` patterns and operator debris, not commands — `case "$x" in
  // /tmp/*|/private/tmp/*) …` made every script that contains such a pattern
  // false-block (review cycle-2, B12a/B8i). An extglob operator keeps the word
  // a candidate even though it carries `(`/`)`.
  //
  // ⛔ …and a candidate must be PATH-SHAPED (#3243). The `[|&;()<>]` deny above
  // was the whole shape test, so a PROGRAM'S TEXT that happened to carry a `/`
  // and a `$` was claimed as an executed script path: the awk program
  // `/^tree=/{t=$2}` (an ARGUMENT to `awk`) and the sed expression
  // `s/[[:space:]]*$//` each refused the entire script containing them, with the
  // message "the script path contains a shell-expansion form" about a path that
  // was literal. `wtIsPathShapedScriptWord` is a POSITIVE grammar (expansion
  // forms are placeholders; what remains must be path components), so a real
  // expanded path is still a candidate and data cannot become one.
  const pathShaped = (w: string): boolean => wtIsPathShapedScriptWord(w);
  const directish = (w: string): boolean =>
    (w.includes("/") || w.startsWith("~")) && (!/[|&;()<>]/.test(w) || /[?*+@!]\(/.test(w)) && pathShaped(w);
  const unq = (w: string): string => w.replace(/^["']|["']$/g, "");
  const sp = extractScriptPath(text);
  const words = String(text).trim().split(/\s+/);
  const first = words[0] ?? "";
  const unqFirst = unq(first);
  const spUnq = sp === null ? null : unq(sp);
  // A leading `NAME=value` is an ASSIGNMENT, not a command — its value is not a
  // script path, and `WT_PATH="$MAIN_REPO/.worktrees/$BRANCH"` (and the value
  // side of `S='cat ./undo*.sh | bash'`) false-blocked the sanctioned recovery
  // helper once the segment scan reached it (review cycle-2). `extractScriptPath`
  // still resolves `FOO=bar bash ./x*.sh` because it skips env prefixes itself.
  const assignmentFirst = /^[A-Za-z_][A-Za-z0-9_]*=/.test(first);
  // Is the first word a shell/spawner (so `sp` is its OPERAND)? Duplicates the
  // classifier's word sets on purpose: a MISSING name only narrows this arm, it
  // cannot open a bypass — the `extractScriptPath` result is still checked.
  const firstIsShellLike = /^(?:bash|sh|zsh|dash|ksh|ash|mksh|oksh|fish|csh|tcsh|source|env|nice|nohup|command|sudo|doas|setsid|stdbuf|time|timeout|exec|ionice|busybox|xargs|find|eval)$/.test(
    unqFirst.replace(/^.*\//, ""),
  );
  // ⛔ THE SHAPE TEST MUST NOT DISARM A WRAPPER'S OPERAND (#3333 review, P0 — measured, and it is a
  // NEW fail-OPEN, not a narrowing). It shipped as `pathShaped(sp) || /^["']?\$/.test(sp)` on BOTH
  // positions of this branch, and `wtIsPathShapedScriptWord` rejects every word with no `/` and no
  // leading `~` (that is `directish`'s rule, and it is correct for a COMMAND word: a bare command
  // resolves through PATH). For an INTERPRETER OPERAND it is false: `bash undo*.sh` resolves the
  // operand against the CWD and execs it, so `extractScriptPath` returning `undo*.sh` was already the
  // right answer and the shape test then DELETED it. The word fell through the operand branch, failed
  // the extglob loop's own `pathShaped(w)`, could not reach `directish("bash")` (no `/`), and the
  // command was ALLOWED with an unreadable script that may `git checkout --` uncommitted work:
  // `bash undo*.sh`, `bash undo?.sh`, `bash undo[0-9].sh`, `bash undo{1}.sh`, `sh undo?.sh`,
  // `bash -x undo*.sh`, `bash undo?.sh arg`, `sudo bash undo*.sh`, `env A=1 bash undo*.sh`.
  //
  // So `firstIsShellLike` is an UNCONDITIONAL pass again, exactly as it was before #3243: a wrapper is
  // by definition followed by its OPERAND, and `extractScriptPath` returns that operand as `sp`. The
  // grammar stays where the position is genuinely AMBIGUOUS — a word that IS the segment's first word,
  // where program text and a real path are indistinguishable — which is all #3243 cycle-1 F3 ever
  // needed to narrow. ⛔ TWO OF THE THREE SPELLINGS THIS COMMENT USED TO CREDIT WITH THAT ARE NOT
  // SHAPED AS CLAIMED (#3333 review P1, measured — an unverified "all three stay ALLOW" would send
  // the next reader to write a failing arm, or to "fix" a correct refusal):
  //   • `/^tree=/{t=$2}` — `pathShaped` FALSE, so as a segment's first word it is program text and
  //     stays non-path. ALLOW inside a body, ALLOW as an `awk` program argument.
  //   • `s/[[:space:]]*$//` — `pathShaped` FALSE too, but the HANDLER still BLOCKs it standalone on
  //     both builds (a different arm). Predicate-level non-path, handler-level refusal.
  //   • `~520` — NOT a non-path: `pathShaped('~520')` is TRUE on both builds, and it is refused on
  //     both, which is what test-discard-gate.mjs B15h-i says ("`~520` still blocks (it IS a valid
  //     tilde expansion spelling)"). Only the program-text shape is pinned there.
  // The narrowing is intact either way — no spelling became newly blocked — but do not re-assert the
  // old sentence without re-measuring it.
  //
  // The `$`-rooted carve-out is kept as a DEFENSIVE belt, NOT as the load-bearing half — a claim this
  // comment made and a review measured false (#3333 review, P2). It changes NO verdict across 46
  // spellings (`$NB`, `"$NB"`, `${X}`, `$1`, `"$@"`, `$SCRIPT`, `${DIR}/x.sh`, `$(pwd)/x.sh`, each as
  // the first word, after `&&` and after `if`), because a bare `$VAR` never reaches this function at
  // all: `extractScriptPath('"$REAPER"')` is `null`. The #1228 fail-closed residual this comment used
  // to credit it with is held by a DIFFERENT arm, so do not look for it here.
  //
  // NAMED RESIDUAL (measured, pre-existing on both builds, #3333 review P2) — THREE mechanisms, and the
  // difference between the first two decides what a future fix has to touch (the third is not a
  // wrapper problem at all):
  //   (a) `operandPosition` is a NAME list, so a wrapper the set does not name leaves the operand in
  //       `sp` where it blocks only on THAT test — `. undo*.sh` (POSIX dot-source is missing while
  //       `source` is present), `runuser -u root -- bash undo*.sh`, `chroot / bash undo*.sh`,
  //       `flock /tmp/l bash undo*.sh`, `strace -f bash undo*.sh`, `watch -n1 bash undo*.sh`,
  //       `systemd-run --user bash undo*.sh`, `unbuffer bash undo*.sh`. Widening the name set closes
  //       these.
  //   (b) `extractScriptPath` returns NULL, so there is no operand to block at all — `"$BASH" undo*.sh`,
  //       `$BASH undo*.sh`, `"$SHELL" undo*.sh`. Widening `firstIsShellLike` does NOT touch these.
  //   (c) AND THE SAME CLASS ONE SPELLING OVER: a BARE direct-execution glob (`undo*.sh`, `undo?.sh`,
  //       `undo[0-9].sh`, `undo{1}.sh` as the FIRST WORD) is ALLOW on BOTH builds — `extractScriptPath`
  //       yields null and `directish` requires `/` or `~`, so no candidate is ever formed. Not a
  //       wrapper-naming problem at all; `./undo*.sh` IS blocked (the prefix forms a candidate).
  // All of the above are pre-existing on both builds. Recorded, not chased: each is a fail-closed
  // change of its own and none of them is what this arm is about (#3341).
  const operandPosition = firstIsShellLike || unqFirst === spUnq;
  // ⛔ THE SHAPE TEST STAYS INSIDE THE `sp &&` SHORT-CIRCUIT: `sp` is `string | null`, so hoisting it
  // into a `const` would call `pathShaped(null)` on every segment (runtime-safe — the predicate does
  // `String(word ?? "")` — but a narrowing hole the moment a typecheck exists).
  if (sp && _wtPathNeedsExpansion(sp) && operandPosition &&
    (firstIsShellLike || pathShaped(sp) || /^["']?\$/.test(sp))) {
    // Interpreter operand (`bash ./undo*.sh`, `bash undo*.sh`, `sudo bash …`), or a bare path
    // that IS the first word (direct execution, `./undo*.sh`).
    return sp;
  }
  // EXTGROUP (`shopt -s extglob`, or `bash -O extglob -c …`) truncates the
  // operand at `(`, so `extractScriptPath` returns a PREFIX and
  // `_wtPathNeedsExpansion(prefix)` is false on its own. Scan the raw words for
  // the full extglob token, but ONLY in a script position: an interpreter
  // operand, or a directly-executed word that is not a `case` pattern (those
  // end in `)`).
  if (sp !== null && spUnq !== null) {
    for (const w of words) {
      // #3243: a program's TEXT is not a script path — see `directish`. The
      // extglob operator must still be present, and `startsWith(spUnq)` is kept
      // (the operand `extractScriptPath` reports can stop anywhere inside the
      // group, so an "operator immediately after the prefix" test was too
      // strict and let `bash ./undo@(-g|).sh` through — caught by B13).
      // ⛔ AND, LIKE THE OPERAND BRANCH ABOVE, THE SHAPE TEST DOES NOT APPLY TO A WRAPPER'S OPERAND
      // (#3333 review, P0). `bash undo@(-g|).sh` is the extglob spelling of the same bare-relative
      // class — it has no `/` and no `~`, so `pathShaped(w)` deleted it and the command ran unread.
      // The grammar is consulted only for the ambiguous direct-execution position.
      if (unq(w).startsWith(spUnq) && /[?*+@!]\(/.test(w) && (firstIsShellLike || pathShaped(w)) && (firstIsShellLike || !w.endsWith(")"))) return w;
    }
  }
  if (!assignmentFirst && directish(first) && _wtPathNeedsExpansion(first)) return first;
  // EXTGROUP on a directly-executed word (`./undo@(-g|).sh`) — only a word that
  // IS the command, never an argument (`git add src/@(a|b).ts`), and never a
  // `case` pattern, which ends in `)`.
  //
  // #3243: "IS the command" is the rule this loop states and did NOT implement —
  // it walked EVERY word of the segment. On a whole script BODY that made any
  // argument containing `+(`/`@(` etc. an executed path (`env HOME=… ` followed
  // by a `$REAPER` operand, `sed -n 's/.*(+\([0-9]\...'`); on the body's first
  // word it made the `#!` SHEBANG line a "directly-executed path", which opened
  // the whole word list to the same hunt. Both are data, not the command.
  if (!assignmentFirst && directish(first)) {
    for (const w of words) {
      if (unq(w) === unqFirst && directish(w) && /[?*+@!]\(/.test(w) && !w.endsWith(")")) return w;
    }
  }
  return null;
}

/** #1228 — the runtime-EXPANDED script token `text` would run, or null. Applied
 *  to the whole text AND to every command segment, so a script invocation at a
 *  later position (`true && bash ./undo*.sh`, `if true; then bash …; fi`) is
 *  found too — plus the `$(cat <expanded>)` and `<(cat <expanded>)` forms. */
function _wtExpandedScriptToken(text: string): string | null {
  const s = String(text ?? "");
  const checks = [
    s,
    ..._wtCommandSegments(s).map((seg) => seg.replace(/^\s*(?:then|do|else|elif|if|while|until|for|fi)\b/, "")),
  ];
  for (const t of checks) {
    const hit = _wtExpandedScriptTokenIn(t) ?? _wtCatOfExpandedPath(t) ?? _wtProcessSubExpansion(t);
    if (hit) return hit;
  }
  return null;
}

/** #1228 — the first runtime-EXPANDED token of a pipeline whose consumer is a
 *  shell interpreter (`cat ./undo*.sh | bash`, `F=./undo.sh; cat $F | bash`), or
 *  null. The producer names a file the shell resolves at runtime, so the code
 *  fed to the interpreter cannot be read as spelled. The TOP-LEVEL walk already
 *  fails closed on this shape; a pipeline written one level in — inside an
 *  interpreter `-c` payload, an `eval` payload, or a nested script — was still
 *  skipped, so the identical unreadable producer ran UNGATED there. */
function _wtExpandedPipedProducer(text: string): string | null {
  // Trim BOTH ends: the shell words this test reads can come from a FILE
  // (`.script`, `$(cat file)`) whose body ends in a newline, and
  // `wtPipelineFeedsShell` does not treat a trailing newline as a word
  // separator — `"… | bash\n"` failed the consumer test and the producer was
  // skipped. The newline is not part of the pipeline's identity.
  const s = String(text ?? "").trim();
  // #3243 — the split must be quote-aware (see `wtSplitPipeline`): `split("|")`
  // read the `|` INSIDE a quoted grep alternation / sed expression / markdown
  // table as a pipeline, and then reported an arbitrary word of the "producer"
  // as "the piped producer … contains a shell-expansion form". A real pipeline's
  // `|` is unquoted, so the arm still fires on every form it was built for.
  const segs = wtSplitPipeline(s);
  if (segs.length < 2 || !wtPipelineFeedsShell(s)) return null;
  for (const raw of wtShellWords(segs.slice(0, -1).join("|"))) {
    const tok = _dequoteShellWord(raw);
    if (!tok || tok.startsWith("-")) continue;
    if (_wtPathNeedsExpansion(tok)) return tok;
  }
  return null;
}

/** #3243 — the refusal line when the expansion-shaped token was found in a
 *  script's BODY, not in the command's own path.
 *
 *  The two observations are NOT the same and must not share a sentence. `bash
 *  ./undo*.sh` really does spell an expanded PATH. A body finding is a NESTED
 *  invocation — `bash "$NB"` on line 256 of a file whose path is perfectly
 *  literal — and the old text (`_WT_EXPANDED_SCRIPT_REASON`) told the operator
 *  "the script path contains a shell-expansion form" plus the remedy "pass the
 *  path literally (e.g. `bash ./tools/your-script.sh`)", which they had ALREADY
 *  done. Measured six times in one day on this box (#3243): an unsatisfiable
 *  remedy reads as a broken gate, and the cheapest way out is to claim the suite
 *  is green without running it. The verdict is unchanged — only the observation,
 *  its LOCATION, and the remedy are now true.
 * @param scriptPath the file whose body was read
 * @param hit the observed nested shape
 * @param text the RAW text the hit was found in, for the line number. It is NOT
 *   prepared: the body-preparation hunk was measured and is not landed (see
 *   `_expRefusalForBody`), so a comment line is still in this text and a hit can
 *   still be reported at a comment's line — that is the recorded residual, and it
 *   is why the message names the token instead of promising the path is the cause.
 */
function _wtBodyExpandedReason(scriptPath: string, hit: _WtExpandedHit, text: string): string {
  const shown = String(scriptPath ?? "(script)");
  // ⛔ THE LINE IS ONLY CLAIMED WHEN IT IS UNAMBIGUOUS (#3243 review c2, note 4).
  // `indexOf` returns the FIRST occurrence, so a token that also appears earlier —
  // in a comment, in a string — reported a line that is not the invocation, in a
  // message whose whole purpose is honest attribution (`hit` carries no offset,
  // and threading one through the detection path is a change to load-bearing code
  // for a cosmetic gain). When the token is not unique, name the file and the
  // token and claim nothing about where.
  const first = text.indexOf(hit.token);
  const unique = first >= 0 && text.indexOf(hit.token, first + 1) < 0;
  const line = unique ? text.slice(0, first).split("\n").length : 0;
  const where = line > 0 ? `line ${line} of ${shown}` : `in ${shown}`;
  const observed =
    hit.kind === "producer"
      ? `its piped producer ${JSON.stringify(hit.token)} is fed to a shell as a script (${where})`
      : `${JSON.stringify(hit.token)} is invoked as a script (${where})`;
  return (
    `the body of ${shown} cannot be fully read — ${observed}, and that path is ` +
    "not statically resolvable as spelled (a `$`, a backtick or a glob is resolved " +
    "by the shell at run time), so the file it would execute cannot be read; an " +
    "unreadable script may discard uncommitted work in ANY checkout. Pass the " +
    `SHELL ITSELF a literal path (e.g. \`bash ./tools/your-script.sh\`), or spell the ` +
    `nested path literally IN ${shown} so the file it runs can be read and verified`
  );
}

/** The refusal reason for an expansion-shaped piped producer — one wording for
 *  the top-level arm and every wrapper/nested position that reuses it. Names
 *  the OBSERVED token and hedges the runtime expansion (see
 *  `_WT_EXPANDED_SCRIPT_REASON`). */
function _wtExpandedProducerReason(tok: string): string {
  return `the piped producer ${JSON.stringify(tok)} contains a shell-expansion ` +
    "form, so the file it feeds to the interpreter is not statically resolvable " +
    "as spelled — the shell may expand it at runtime, and the discard target is " +
    "UNKNOWN; pass the path literally so its contents can be read and verified";
}

/** #1228 — the runtime-EXPANDED script shape `text` would run, or null: the
 *  direct operand (`bash ./undo*.sh`), a piped producer the shell expands
 *  (`cat ./undo*.sh | bash`), or either of those inside an interpreter `-c`
 *  payload or an `eval` payload — depth-bounded at 6, and FAILING CLOSED at the
 *  bound. The expanded path was reachable at every position (command, payload,
 *  nested script), so one predicate decides them all and the verdict cannot
 *  depend on WHERE it is written. */
type _WtExpandedHit = { kind: "direct" | "producer"; token: string };
function _wtExpandedScriptShape(text: string, depth = 0): _WtExpandedHit | null {
  const s = String(text ?? "");
  const direct = _wtExpandedScriptToken(s);
  if (direct) return { kind: "direct", token: direct };
  const producer = _wtExpandedPipedProducer(s);
  if (producer) return { kind: "producer", token: producer };
  if (depth >= 6) {
    // At the cap an unresolved nested shell shape must not be assumed safe: a
    // `-c`-inside-`-c` chain can hide the same expanded path arbitrarily deep
    // (the old depth-3 cap let a 4-deep chain through — review cycle-2 P1).
    // Six levels is far past any real command; refusing here is fail-closed.
    return { kind: "direct", token: s.slice(0, 60) };
  }
  const payloads: string[] = wtShellInlinePayloads(s).map((p) => p.text);
  for (const m of s.matchAll(/\beval\s+(\$)?(['"])([\s\S]*?)\2|\beval\s+(\S+)/g)) {
    payloads.push(m[1] ? ansiTranslate(m[3] ?? m[4] ?? "") : (m[3] ?? m[4] ?? ""));
  }
  for (const raw of payloads) {
    const hit = _wtExpandedScriptShape(raw.replace(/^["']|["']$/g, ""), depth + 1);
    if (hit) return hit;
  }
  return null;
}

/** M5 gate: returns a block reason when `command` would discard uncommitted
 *  tracked work in the checkout it targets, else null. Covers the direct argv
 *  surface, interpreter-inline payloads (via allGitInvocations) and the
 *  script-file surface (`bash /tmp/restore.sh`) to a bounded depth. */
/** #1484 M4 recovery window — the M5 half (#709).
 *
 * Both gates must agree on the SAME window, or the hatch moves the refusal one
 * line down instead of removing it. Measured (review, 2026-11-02): with the TTL
 * marker ACTIVE and a hub carrying one truncated tracked file, M4 permitted
 * `git checkout -- <path>` and M5 then refused it — "Working-tree discard
 * blocked … it would destroy uncommitted work (#709)" — so the hub stayed
 * unrecoverable while BOTH messages claimed a hatch worked.
 *
 * The hatch state is PASSED IN (the caller already computed it, the same value
 * M4's `escapeActive` gets). Recomputing it here resolved the session id from
 * the ENV only (`_currentSessionId(undefined)`) while M4 and the marker STAMP
 * use the ctx form (`_currentSessionId(_ctx)`) — two different ids, so in the
 * production geometry (pi sets PI_SESSION_ID only in the CHILD env, not its own
 * process) this window silently never opened and "M4 permits, M5 refuses"
 * survived. Measured by review round 2 driving the real handler with a
 * ctx-stamped marker and no env id.
 *
 * SCOPE (all three required): an active hatch; the SESSION cwd is the DISORDERED
 * hub (a clean repo, a linked worktree and a foreign checkout are outside it);
 * and the command is ONE simple git invocation. The last clause closes the
 * compound hole round 2 measured: exempting the whole command let one permitted
 * restore neutralise M5 for everything after it (`git checkout -- other.txt; x=w;
 * git show HEAD:"$x" > "$x"` was ALLOWED, re-opening #1060/D8). */
function _m4HatchRecoveryWindow(command: string, hatchActive: boolean): boolean {
  if (!hatchActive || !classifierLoaded) return false;
  // A compound command is never in the window. NEWLINE is in the class
  // deliberately (review round 3, P1 — measured): the first cut listed `;` but
  // not `\n`, which is the shell's most common separator and a boundary
  // `allGitInvocations` itself splits on, so
  //   `git checkout -- wip.txt` NL `bash w.txt`   (w.txt = `git checkout -- .`)
  // was ALLOWED and wiped a sibling session's uncommitted work — a way to run a
  // script body the #1484 script backdoor refuses to run in command position.
  if (/[;&|<>`$()\n\r]/.test(command)) return false;
  // The window is the SESSION's disordered hub, so the invocation's TARGET must
  // be that hub too (review round 3, P2 — measured): `git -C <dirty checkout B>
  // checkout -- p` from a dirty hub A was ALLOWED, exempting M5 for a discard
  // aimed at a checkout that is NOT the hub (origin/main blocked it). A
  // repo-SELECTING flag can point the restore anywhere, so it is refused
  // outright — fail closed to M5; the plain form, run from the hub, is the
  // window and is what the message tells the reader to use.
  // Round 10 (P1, MEASURED — data loss): the reject required a separator AFTER
  // `-C`, so `env -C"<other>" git checkout -- tracked.txt` (BSD env accepts the
  // attached form; GNU env -C/--chdir on the Linux cells) slipped BOTH layers —
  // the parser only sees the `git` invocation, and M4's early-return then calls
  // the window so M5 never runs. It DESTROYED a foreign checkout's uncommitted
  // work where origin/main blocked it. The documented shape is "ONE bare
  // invocation run from the hub", so make that literal: the command must START
  // with `git`. That closes env -C/--chdir, env -i, nice, sudo, xargs and
  // `sh -c` in one predicate instead of enumerating wrappers.
  if (!/^\s*git\s/.test(command)) return false;
  if (/(^|\s)(-C|--git-dir|--work-tree|--prefix)(\s|=)/.test(command)) return false;
  // …and the ENV spelling of the same thing (round 4, P1 — MEASURED fail-open:
  // `GIT_DIR=<other>/.git GIT_WORK_TREE=<other> git checkout -- tracked.txt`
  // was ALLOWED and discarded a FOREIGN checkout's uncommitted work, where
  // origin/main blocked it. An enumerated flag list cannot cover a second
  // spelling family, so the window refuses ANY env-assignment prefix: a bare
  // restore needs none, and "one bare invocation, run from the hub" is the
  // shape the message tells the reader to use. Everything else falls back to
  // M5's normal (blocking) behaviour — fail closed, never fail open.)
  if (/(^|\s)[A-Za-z_][A-Za-z0-9_]*=/.test(command)) return false;
  // …and the AMBIENT env (round 6, P2 — MEASURED): with `GIT_DIR`/`GIT_WORK_TREE`
  // in the pi PROCESS env, a bare `git checkout -- tracked.txt` run from the dirty
  // hub targeted the OTHER checkout and rewrote its uncommitted work. Under the
  // TTL marker that was newly reachable (origin/main blocked it; only the env
  // hatch — a full bypass — allowed it there). No channel predicate can see the
  // process env, so it is checked directly.
  if (Object.keys(process.env).some(isRepoSelectingEnvKey)) return false;
  // …including the AMBIENT spelling of the config channel (round 7, P2 — the
  // `-c`/`--config-env` family r6 closed is also settable through the env:
  // GIT_CONFIG_PARAMETERS / GIT_CONFIG_COUNT+KEY_n/VALUE_n / GIT_CONFIG_GLOBAL /
  // GIT_CONFIG_SYSTEM all reached the window). Effect was inert (git ignores
  // core.worktree inside a worktree) so this was a classification gap, but the
  // fix is the principle rather than three more names: a bare restore needs NO
  // git config at all, so ANY `GIT_CONFIG_*` in the env puts it out of window.

  const st = _hubState();
  if (!st.disorder) return false; // the window exists only for a DISORDERED hub
  try {
    const base = resolve(process.cwd());
    const withHatch = evaluateHubGateWithTargets(command, st.branch, base, null, st, { escapeActive: true });
    if (withHatch.verdict !== "recovery") return false;
    const withoutHatch = evaluateHubGateWithTargets(command, st.branch, base, null, st);
    return withoutHatch.verdict === "block";
  } catch {
    return false; // degrade — never widen on a classifier failure
  }
}

// Round 4 (P2): set by _worktreeDiscardBlock, read by _worktreeDiscardBlockReason, so the
// block message can tell a hatched reader what its hatch actually covers.
let _wtDiscardHatchActive = false;

function _worktreeDiscardBlock(command: string, hatchActive = false): string | null {
  if (!classifierLoaded) return null; // degraded import → inert (module-load tripwire guards this)
  // #1484/#709 — the hatch's recovery window, decided ONCE and shared with M4.
  if (_m4HatchRecoveryWindow(command, hatchActive)) return null;
  // The reason builder needs the same datum so it can name the WINDOW (rather
  // than re-prescribe a hatch the reader already holds). Set per call, read
  // immediately — every path into `_worktreeDiscardBlockReason` runs through
  // this function.
  _wtDiscardHatchActive = hatchActive === true;
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
  // #1228: a command-position word the SHELL expands (`~/undo.sh`, `./undo*.sh`)
  // carries no `git`, no quote and no `$`/backtick, so the textual bail below
  // used to swallow it whole — the directly-executed sibling of the
  // `bash ./undo*.sh` hole. A word carrying a path separator (`sub/undo.sh`)
  // was swallowed for the same reason. Recognize either shape here so the
  // script walk runs; the walk itself decides readable-vs-expanded.
  const _firstWord = String(command).trim().split(/\s+/)[0] ?? "";
  const _pathLikeWord = _firstWord.includes("/") || _firstWord.startsWith("~");
  // #1228: an expanded SCRIPT invocation can also sit AFTER a separator
  // (`true && bash ./undo*.sh`, `if true; then bash …; fi`) — the bail below
  // only ever looked at the first word and swallowed those whole (review
  // cycle-2 P0). Bail only when the command mentions no path AND no shell
  // interpreter, so those shapes reach the segment scan. The shell names mirror
  // `classify-git.mjs`'s SHELL_INTERPRETERS; a MISSING name here would only
  // re-open the bail, so the list stays complete.
  const _pathOrShell = /[\/~]|\b(?:bash|sh|zsh|dash|ksh|ash|mksh|oksh|source)\b/.test(command);
  if (!/\bgit\b/.test(command) && !_scriptPath && !pipesToShell && !_pathLikeWord && !_pathOrShell && !/['"\\$`]/.test(command)) return null;
  let direct: ReturnType<typeof extractWorkingTreeDiscards> = [];
  try { direct = extractWorkingTreeDiscards(command) ?? []; } catch { return null; }
  const sessionCwd = resolve(process.cwd());
  const execCwd = commandExecutionCwd(command, sessionCwd) ?? sessionCwd;
  // #1228 — one refusal for every wrapper/nested position: the expanded script
  // shape (direct operand OR piped producer, one level in) is refused with the
  // reason that names what was observed. The top-level arms keep their own
  // refusals; this is what the wrapper and nested positions call, so the
  // verdict cannot depend on WHERE the same expanded path is written.
  const _expRefusal = (text: string): string | null => {
    const hit = _wtExpandedScriptShape(text);
    if (!hit) return null;
    return _worktreeDiscardBlockReason(
      { form: "script-indirection", scope: "all", pathspecs: [] },
      execCwd,
      hit.kind === "producer" ? _wtExpandedProducerReason(hit.token) : _WT_EXPANDED_SCRIPT_REASON,
    );
  };
  // ⛔ ONE predicate for every place a script FILE's own body is read — the two
  // command-position walks AND the `eval` / `-c` / `$(cat)` / assignment-value readers.
  // A SANCTIONED, PINNED script's body is audited bytes, so the arm does not apply to it
  // (`_isAuditedSanctionedScript` = sanctioned anchor + the pin's digest, never the path
  // alone); for anything else the refusal fires exactly as before. Patching only some of
  // these sites makes the verdict depend on WHERE the same body was reached — which is the
  // invariant `_expRefusal` itself states two lines above — and leaves the reported defect
  // (a framework script, including the mandated rail, unrunnable by a false block) alive on
  // the spellings that go through the other readers.
  const _expRefusalForBody = (scriptPath: string, body: string): string | null => {
    if (_isAuditedSanctionedScript(resolve(execCwd, scriptPath), _sha256OfBody(body))) return null;
    // ⛔ #3243 — THE BODY IS SCANNED AS THE RAW TEXT, AND A PREPARATION HUNK WAS MEASURED AND
    // REJECTED. The draft of this fix ran the body through `stripHeredocData` first (the
    // preparation `extractWorkingTreeDiscards` has always used: `#` comments removed
    // quote-aware, heredoc DATA blanked). It is CORRECT in principle — a comment's apostrophe
    // desynced the segment quote state for the rest of the file (#1949's class, on this arm),
    // so `scripts/install-harness-apply-timer.sh` was refused over the piped producer
    // `"boxs clock, on BOTH platforms\n# …"`, a COMMENT paragraph — and it is NOT LANDED,
    // because its measured effect on the defect it was meant to fix is a net loss:
    //
    //   preparation ON : 22 committed scripts newly RUN, 21 newly REFUSED (11 of them CI
    //                    suites — claim-reaper.test.sh, live-ownership.test.sh,
    //                    worktree-disk-probe.test.sh, run-bash-shards.recap.test.sh, …)
    //   preparation OFF: 17 committed scripts newly RUN,  0 newly REFUSED (73 of the 373
    //                    refused before this change, 56 after — measured in ONE environment;
    //                    see the README section for why the pair must not be mixed)
    //
    // (373 committed `*.sh`, this handler, the `pi -p` child env; the census is reproduced in
    // README's #3243 section.) Removing the comment artefact does not only delete DATA — it
    // also makes the arm REACH real `$VAR` operands it had been missing (`bash "$SW" stop`,
    // `bash "$REAPER"`), which is the deliberate over-block #3243 is about. An arm that
    // refuses 21 more suites than it did is the wrong direction for THIS issue; the
    // preparation is recorded on #3243 with these numbers instead of being landed here.
    const hit = _wtExpandedScriptShape(body);
    if (!hit) return null;
    return _worktreeDiscardBlockReason(
      { form: "script-indirection", scope: "all", pathspecs: [] },
      execCwd,
      _wtBodyExpandedReason(scriptPath, hit, body),
    );
  };

  // Executable-shebang script (`./undo.sh`, `/tmp/undo.sh`): extractScriptPath
  // only recognises interpreter WORDS (`bash x.sh`), so a directly-executed
  // script would otherwise never be read (reviewer P1).
  if (!_scriptPath) {
    const firstTok = String(command).trim().split(/\s+/)[0] ?? "";
    // #1228: a command-position word is a PATH candidate when it carries a
    // path separator (`sub/undo.sh` — the old `/^[.~]?\//` test missed it
    // entirely) or a leading `~`. What the SHELL expands (`~/undo.sh`,
    // `./undo*.sh`) is not statically resolvable, so it fails closed. A plain
    // relative word (`undo.sh`) is left alone: bash does not search the cwd,
    // so it resolves through PATH, not through this file.
    if (firstTok.includes("/") || firstTok.startsWith("~")) {
      if (_wtPathNeedsExpansion(firstTok)) {
        return _worktreeDiscardBlockReason(
          { form: "script-indirection", scope: "all", pathspecs: [] },
          execCwd,
          _WT_EXPANDED_SCRIPT_REASON,
        );
      }
      try {
        const p = realpathSync(resolve(execCwd, firstTok));
        const st = statSync(p);
        if (st.isFile() && (st.mode & 0o111) !== 0) _scriptPath = firstTok;
      } catch { /* nonexistent/non-executable — not a script invocation */ }
    }
  }

  // #1885 — A SCRIPT INVOKED THROUGH A VARIABLE IS THE SAME SCRIPT.
  //
  // Command position is a script position. `extractScriptPath` resolves an interpreter
  // OPERAND (`bash $S`) and a `/`-/`~`-prefixed direct word; a bare `$S` in command
  // position is neither, so nothing was seeded, the effect probe had nothing to gate, and
  // `S=./undo.sh; $S` ran UNGATED while `bash $S` was refused — same file, same discard
  // (measured on this handler; `test-discard-gate.mjs` B5d is the control). The verdict
  // must not depend on whether the path was spelled as an operand or as the command.
  //
  // THREE outcomes, and the third is why this is not a blanket refusal:
  //   1. the name's LAST assignment in this command is a LITERAL → gate it exactly as the
  //      literal spelling would be: seed the file and probe its EFFECT;
  //   2. that assignment is not statically readable but IS path-shaped (`S=$(pwd)/undo.sh`,
  //      `S=${DIR}/undo.sh`) → fail closed, naming what was observed. A value that is one
  //      hop from readable is SUBSTITUTED first (`D=./sub; S=$D/tool.sh` resolves through
  //      the same map), so the ordinary dir-prefix idiom is GATED, not refused;
  //   3. no assignment in this command → the value comes from the environment, so nothing
  //      distinguishes it from `$EDITOR file` or `CMD=ls; $CMD -la`. Those stay ALLOWED —
  //      refusing them is the #1776 false-block in the other direction — and it is a STATED
  //      residual: a bash tool call is a fresh shell, so an agent reaches this state only by
  //      exporting in its parent, a surface this gate does not own.
  //
  // ⛔ NOT gated on `!_scriptPath` (review P1): `bash ./noop.sh; S=./undo.sh; $S` otherwise
  // skipped the arm entirely, because `extractScriptPath` had already found `./noop.sh` — one
  // innocuous prefix restored the whole fail-open. These paths are therefore ADDED as seeds
  // below, beside whatever `_scriptPath` holds, never instead of it.
  //
  // `+=`, `export`/`declare`/`local`, spawner wrappers (`env`, `exec`, `sudo`), `!`, subshell
  // `( … )` / `{ … }` groups and redirection prefixes are all handled by the two helpers
  // (`_wtCommandWordRefs`), because each of them is a one-character way to re-open the same
  // hole. A parameter-expansion operator INSIDE the braces (`${S:?}`, `${S%%.sh}`) computes a
  // different string than the variable holds, so it cannot be substituted: it fails CLOSED when
  // the assignment is path-shaped, and is left alone otherwise (`${EDITOR:-vi}` has no
  // assignment, so it stays allowed).
  const cpSeeds: string[] = [];
  if (String(command).includes("$")) {
    const refs = _wtCommandWordRefs(command);
    if (refs.length > 0) {
      // Position-aware: for each reference, the value in effect AT that point. ONE fold
      // over ONE `_wtAssignmentsIn` result (review P2): re-running the full re-split +
      // re-mask + re-walk per reference was O(refs x len) — ~1 s on a 50 KB command with
      // 200 assignments and 200 references.
      const conservative = _wtCommandVars(command);
      const stateAt = _wtAssignBefore(_wtAssignmentsIn(command));
      // ⛔ THE ENV-PREFIX BOUNDARY (review round-3 G4). A `NAME=value` word written in the
      // SAME simple command as the reference is not in effect for the reference: bash
      // expands the command word first and only THEN adds the prefix to the command's
      // environment. Folding it read a value the shell never ran — `S=./noop.sh;
      // S=./undo.sh $S` was BLOCKED (bash runs `./noop.sh`), and `S=./undo.sh;
      // S=./noop.sh $S` was ALLOWED (bash runs `./undo.sh`, measured both ways). One
      // scanner per command, advancing over ascending references, so the cost is one pass.
      const cmdStartAt = _wtSimpleCommandAbsScanner(command);
      for (const ref of refs) {
        const last = stateAt(ref.seg, ref.at, cmdStartAt(ref.abs));
        // Substitute with the SHELL's answer first and #1060's conservative map second
        // (review P2): a name the arm itself resolved has been DROPPED from the conservative
        // map (`S=$1; S=./undo.sh; T=$S; $T`), so substituting from that map alone left the
        // `$` in place and the one-hop chain fell through to "no slash ⇒ allow" — the same
        // file the direct spelling blocks.
        const vars = new Map([...conservative, ...last.literal]);
        const literal = last.literal.get(ref.name);
        const text = last.text.get(ref.name);
        if (ref.indirect) {
          // `${!NAME}` INDIRECTION, ONE hop (review P2): NAME holds the NAME of the variable
          // that holds the executed path, and bash resolves the two, so the arm must too.
          //   * inner name unassigned in this command → the NAME comes from the environment,
          //     which is residual 1 (`A=${!B}; $A` stays ALLOWED);
          //   * inner value is not a variable NAME → `${!…}` cannot denote a path through it,
          //     so it is left alone UNLESS it is path-shaped, which fails closed;
          //   * the target name's value is unreadable but path-shaped → fail CLOSED, naming
          //     `${!NAME}`: an unreadable script may discard anywhere, and the whole point
          //     of this arm is that the SPELLING must not decide the verdict.
          const innerLit = last.literal.get(ref.name);
          const innerText = last.text.get(ref.name);
          if (innerLit === undefined && innerText === undefined) continue;
          const targetName = (innerLit ?? _wtSubstituteVars(innerText ?? "", vars)).trim();
          if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(targetName)) {
            if (targetName.includes("/") || targetName.startsWith("~") || /[$`]/.test(targetName)) {
              return _worktreeDiscardBlockReason(
                { form: "script-indirection", scope: "all", pathspecs: [] },
                execCwd,
                `the command word \`\${!${ref.name}}\` is an INDIRECT expansion whose inner name ` +
                  `(${ref.name}) holds \`${targetName}\`, which is not a variable name the guard can ` +
                  "follow, so the script it names is not statically resolvable; an unreadable " +
                  "script may discard uncommitted work in ANY checkout; pass the path literally " +
                  "(e.g. `bash ./tools/your-script.sh`) so its contents can be verified",
              );
            }
            continue;
          }
          const hopLit = last.literal.get(targetName);
          const hopText = last.text.get(targetName);
          if (hopLit === undefined && hopText === undefined) continue;   // env-provided
          let hopCand = hopLit;
          if (hopCand === undefined) {
            const hopSub = _wtSubstituteVars(hopText ?? "", vars);
            if (!/[$`]/.test(hopSub) && !/[{}]/.test(hopSub)) hopCand = hopSub;
            else if (hopSub.includes("/") || hopSub.startsWith("~") ||
                     (hopText ?? "").includes("/") || (hopText ?? "").startsWith("~")) {
              return _worktreeDiscardBlockReason(
                { form: "script-indirection", scope: "all", pathspecs: [] },
                execCwd,
                `the command word \`\${!${ref.name}}\` resolves through \`\$${targetName}\`, whose ` +
                  `value (${hopText ?? ""}) is not statically resolvable, so the script it names ` +
                  "cannot be read; an unreadable script may discard uncommitted work in ANY " +
                  "checkout; pass the path literally (e.g. `bash ./tools/your-script.sh`) so its " +
                  "contents can be verified",
              );
            } else continue;
          }
          const hopSeeded = _wtExecutableSeeds(ref.suffix ? hopCand! + ref.suffix : hopCand!, execCwd);
          if (hopSeeded.expanded) {
            return _worktreeDiscardBlockReason(
              { form: "script-indirection", scope: "all", pathspecs: [] },
              execCwd,
              _WT_EXPANDED_SCRIPT_REASON,
            );
          }
          for (const s of hopSeeded.seeds) cpSeeds.push(s);
          continue;
        }
        if (ref.modifier) {
          // `${S:?}`, `${S:-x}`, `${S:+x}`, `${S:=x}` return the variable's OWN value when it
          // is set, so with a literal in hand they are the literal (review P2: refusing them
          // blocked a determinable, benign command while the message said "its value is
          // …"). The substring operators (`%`, `##`, `/`, `:offset:len`) compute a DIFFERENT
          // string and stay fail-closed when the assignment is path-shaped.
          // ⛔ EXPLICIT CHARACTER SET, `-` FIRST (review/VGATE): `[?+-=]` is not a set of
          // four characters — `+-=` is a RANGE from `+` (0x2B) to `=` (0x3D), which contains
          // the DIGITS, so `:0:4` matched it and the arm gated the BASE while `${S:0:4}`
          // computes a different string. A live fail-open, measured: `S=x…x./undo.sh;
          // ${S:16}` was ALLOWED while bash runs `./undo.sh`.
          // ⛔ `+` is NOT a value operator (review P2): `${S+x}` expands to `x` and
          // `${S:+word}` to `word` — the WORD, not the variable — so treating it as
          // "returns its own value" gates the wrong path (measured with bash).
          const modCore = ref.mod.replace(/^:/, "");
          const wordOp = modCore.startsWith("+");
          const valueOp = !wordOp && /^[-?=]/.test(modCore);
          if (wordOp) {
            const word0 = _wtSubstituteVars(modCore.slice(1) + ref.suffix, vars);
            if (!word0) continue;                       // `${S:+}` expands to nothing
            const wSeeded = _wtExecutableSeeds(word0, execCwd);
            if (wSeeded.expanded) {
              return _worktreeDiscardBlockReason(
                { form: "script-indirection", scope: "all", pathspecs: [] },
                execCwd,
                _WT_EXPANDED_SCRIPT_REASON,
              );
            }
            for (const s of wSeeded.seeds) cpSeeds.push(s);
            continue;
          }
          if (valueOp && literal !== undefined) {
            const vSeeded = _wtExecutableSeeds(literal + ref.suffix, execCwd);
            if (vSeeded.expanded) {
              return _worktreeDiscardBlockReason(
                { form: "script-indirection", scope: "all", pathspecs: [] },
                execCwd,
                _WT_EXPANDED_SCRIPT_REASON,
              );
            }
            for (const s of vSeeded.seeds) cpSeeds.push(s);
            continue;
          }
          const shape = literal ?? text;
          if (shape !== undefined && (shape.includes("/") || shape.startsWith("~"))) {
            return _worktreeDiscardBlockReason(
              { form: "script-indirection", scope: "all", pathspecs: [] },
              execCwd,
              `the command word expands \`$${ref.name}\` with a parameter-expansion operator, so the ` +
                `script it names is not statically determinable (its value is ${shape}); an unreadable ` +
                "script may discard uncommitted work in ANY checkout; pass the path literally " +
                "(e.g. `bash ./tools/your-script.sh`) so its contents can be verified",
            );
          }
          continue;
        }
        let candidate = literal;
        if (candidate === undefined && text !== undefined) {
          const sub = _wtSubstituteVars(text, vars);
          if (!/[$`]/.test(sub) && !/[{}]/.test(sub)) candidate = sub;
          // ⛔ The PATH-SHAPE test reads the SUBSTITUTED value as well as the raw text
          // (review P1): `T=$(pwd)/undo.sh; S=$T; $S` leaves `text` as `$T` — no `/` — so
          // keying the fail-closed arm on the raw text alone skipped it, while the value in
          // effect is `$(pwd)/undo.sh`, which rule 3 refuses.
          else if (text.includes("/") || text.startsWith("~") || sub.includes("/") || sub.startsWith("~")) {
            return _worktreeDiscardBlockReason(
              { form: "script-indirection", scope: "all", pathspecs: [] },
              execCwd,
              `the command word \`$${ref.name}\` was assigned in this same command, but its value ` +
                `(${text}) is not statically resolvable, so the script it names cannot be read; ` +
                "an unreadable script may discard uncommitted work in ANY checkout; pass the path " +
                "literally (e.g. `bash ./tools/your-script.sh`) so its contents can be verified",
            );
          } else continue;
        }
        if (candidate === undefined) continue;   // environment-provided — see (3)
        // A literal suffix after the reference (`$S.sh`, `${S}/x.sh`) is part of the path the
        // shell executes, so compose it. Composition ADDS a seed and never suppresses an
        // existing arm, so the pre-existing expanded-token posture is unchanged.
        if (ref.suffix) candidate += ref.suffix;
        // Path shape, word split and the executable test live in ONE helper, so every arm
        // that resolves a command word (this one, `${S:+word}`, a value operator, the
        // indirect hop) applies the SAME rules (review P1/P2).
        const gated = _wtExecutableSeeds(candidate, execCwd);
        if (gated.expanded) {
          return _worktreeDiscardBlockReason(
            { form: "script-indirection", scope: "all", pathspecs: [] },
            execCwd,
            _WT_EXPANDED_SCRIPT_REASON,
          );
        }
        for (const s of gated.seeds) cpSeeds.push(s);
      }
    }
  }

  // An unresolvable script path (`bash $S`, `cat x.sh | sh`) is refused
  // unconditionally: the discard target is unknown, and an unreadable script may
  // discard uncommitted work in ANY checkout, so it cannot be assumed safe
  // (#709). The reason below names only what was measured — the shared helper
  // already renders "NOT a claim that the checkout is dirty" (#1139/PR #1152),
  // so this arm must never name a state it did not observe. What this change
  // touches is the MESSAGE only; the arm already failed closed.
  if (_scriptPath && /[$`]/.test(_scriptPath)) {
    return _worktreeDiscardBlockReason(
      { form: "script-indirection", scope: "all", pathspecs: [] },
      execCwd,
      // WHAT was measured (the path's text), WHAT it costs (an unreadable script
      // may discard anywhere), and the edit that makes it verifiable.
      "the script path contains a $ or a backtick, so it is not statically " +
        "resolvable — the shell may expand it at runtime, and an unreadable script may " +
        "discard uncommitted work in ANY checkout; pass the path literally (e.g. " +
        "`bash ./tools/your-script.sh`) so its contents can be read and verified",
    );
  }

  // #1228: the SAME fail-closed rule for every OTHER runtime-expansion form.
  // `bash ./undo*.sh` / `bash ~/undo.sh` / `bash ./undo-[g]lob.sh` carry no
  // `$`/backtick, so the arm above missed them: the shell expanded the path to
  // a REAL script that was never read, and its discard ran UNGATED. The verdict
  // must not depend on the TEXT SHAPE of the path — either the file is readable
  // as spelled, or the guard cannot verify the effect and refuses.
  if (_wtExpandedScriptToken(command)) {
    return _worktreeDiscardBlockReason(
      { form: "script-indirection", scope: "all", pathspecs: [] },
      execCwd,
      _WT_EXPANDED_SCRIPT_REASON,
    );
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
  const sets: { discs: ReturnType<typeof extractWorkingTreeDiscards>; baseCwd: string; writeCwd: string; script: string | null; digest: string | null }[] = [
    { discs: direct, baseCwd: sessionCwd, writeCwd: execCwd, script: null, digest: null },
  ];
  try {
    const seen = new Set<string>();
    // Seeds: the resolved script path, plus any FILE piped into a shell
    // interpreter (`cat /tmp/undo.sh | bash`), which `extractScriptPath` cannot
    // see because the head of the line is not the interpreter (reviewer
    // round-5 P1).
    const seeds: string[] = [];
    if (_scriptPath) seeds.push(_scriptPath);
    // #1228: a producer token that the shell expands cannot be read, so the
    // script it feeds to the interpreter is unknown — set + fail closed below.
    let unverifiableProducer: string | null = null;
    const pipeSeg = String(command).split("|");
    const execPlaceholder = /(?:^|\s)(?:[\w./-]*\/)?(?:bash|sh|zsh|dash|ksh|ash|mksh)\s+(?:-[A-Za-z]+\s+)?\{/.test(String(command));
    if (pipeSeg.length > 1 && pipesToShell) {
      // #1139 (review cycle-1 P1, T4-pipe): the whitespace split kept the SHELL
      // QUOTES, so `cat "undo.sh" | bash` resolved `'"undo.sh"'`, realpathSync
      // threw, the file was never read — and a discard inside it ran UNGATED,
      // while the identical unquoted spelling was walked.
      //
      // FIXED WITH THE SHARED, QUOTE-AWARE TOKENIZER (review cycle-2 P1). The
      // first attempt dequoted the whole segment then split on whitespace, which
      // does NOT reconstruct shell words: it INVENTED a seed for unquoted input
      // (`cat a b | bash` seeded `a`, `b` AND the non-existent `a b`) and
      // over-split a quoted one (`cat "a b" | bash` seeded `a` and `b`), so a
      // file that the shell NEVER reads could pin a false block. `wtShellWords`
      // returns exactly one token per shell word; each token is then dequoted
      // per-token (quotes + backslash escapes), and NOTHING is re-joined — so
      // every seed is a string the shell itself would read as one word, and
      // `cat -n "a b.sh" | bash` still resolves `a b.sh`.
      for (const raw of wtShellWords(String(pipeSeg.slice(0, -1).join("|")))) {
        const tok = _dequoteShellWord(raw);
        if (!tok || tok.startsWith("-")) continue;
        // #1228: a producer token the shell would EXPAND (`cat ./undo*.sh`,
        // `F=./undo.sh; cat $F`) names a file whose identity is runtime-decided.
        // Skipping it silently was the fail-open: the unresolvable spelling
        // sailed past the gate that blocks the identical literal spelling.
        // Fail closed; the literal spelling still seeds and is read below.
        if (_wtPathNeedsExpansion(tok)) { unverifiableProducer ??= tok; continue; }
        try {
          const real = realpathSync(resolve(execCwd, tok));
          if (statSync(real).isFile() && statSync(real).size <= 64 * 1024) seeds.push(tok);
        } catch { /* not a readable file */ }
      }
      if (unverifiableProducer) {
        return _worktreeDiscardBlockReason(
          { form: "script-indirection", scope: "all", pathspecs: [] },
          execCwd,
          _wtExpandedProducerReason(unverifiableProducer),
        );
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
    // #1885 — every command-position variable that resolved to an executable is a
    // script this command RUNS, so it is read and probed beside `_scriptPath`.
    // ⛔ IT MUST NOT SPEND THE PRE-EXISTING WALK BUDGET (review P1). Pushing these
    // seeds AHEAD of the pipe/`-exec` seeds let three helper scripts displace the
    // real producer: `find ./undo.sh -exec sh {} \; ; A=./n1.sh; $A; B=./n2.sh; $B;
    // C=./n3.sh; $C` was BLOCKED on the base and ALLOWED here, because the depth-3
    // walk never reached `./undo.sh` — a fail-open REGRESSION in the very gate this
    // arm is meant to widen.
    //
    // ⛔ TWO WALKS, TWO BUDGETS (review P2). Appending these seeds to `seeds` and
    // growing ONE shared bound by their count (`3 + cpSeeds.length`) still let the
    // PRE-EXISTING seeds consume the whole budget, because the `find`/pipe seeds are
    // pushed FIRST and the walk is bounded by a DEPTH COUNT, not by "three reads":
    // five `find` path tokens ahead of `A=./undo.sh; $A` walked five pre-existing
    // seeds, exhausted the bound, and never reached the script the command really
    // runs (measured: ALLOWED, while the same command with three tokens was blocked).
    // The pre-existing walk is therefore left EXACTLY as it was (bound 3, same
    // chain-following semantics, `seeds` untouched), and the command-position seeds
    // get their OWN bounded pass below, sharing `seen` so a script read once is not
    // read twice. Neither group can starve the other.
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
      // ⛔ PROBE ON THE PARSE, never on a substring allow-list (review P2): `apply` was
      // missing from the old `(checkout|restore|switch|reset|show|cat-file|read-tree|rm)`
      // prefilter, while the extractor DOES classify `git apply -R` as a whole-tree
      // discard (`form: "apply-reverse"`, `scope: "all"`). A script that reverts tracked
      // WIP that way was therefore READ here and then never PROBED — the opposite of this
      // walk's contract ("read, then gated on its EFFECT"). A `sets` entry with an empty
      // parse is inert, exactly like the sibling arms at the `eval` / `-c` / `cat`
      // readers, so the parse itself is the gate. Measured: the prefilter said NO for
      // `git apply -R p.patch` and `git apply --reverse p.patch`.
      const disc = extractWorkingTreeDiscards(content) ?? [];
      if (disc.length) {
        sets.push({ discs: disc, baseCwd: execCwd, writeCwd: execCwd, script: p, digest: _sha256OfBody(content) });
      }
      // ⛔ A SANCTIONED script's BODY is AUDITED BYTES, so the #1228 body arm does not
      // apply to it. WHY THE TWO EXEMPTIONS ARE NOT ONE: M4's #1129 arm skips its whole walk
      // for an audited leaf ("the walk is skipped for the whole invocation"), while M5's
      // #1139 arm is deliberately SET-scoped ("the SET is dropped, never the command", see
      // the SCOPE paragraph below) — so M5's exemption was honoured for the DISCARD verdict
      // and this refusal, re-derived from the SAME audited file inside the same walk,
      // escaped it. The digest makes the same audited-bytes claim M4 already makes, which is
      // why it is the key here. How the framework's own `gh` shim became unrunnable: its
      // body carries
      //     LC_ALL=C grep -qa '<marker>' <(head -c 8192 2>/dev/null < "$1")
      // and `_wtProcessSubExpansion` matches ANY `<(head|tail|cat|…)` whose inner text
      // needs a runtime expansion, so a PROCESS-SUBSTITUTION ARGUMENT to `grep` — not a
      // script source at all — was read as an expanded script path and every path-spelled
      // invocation of the shim was refused as "the script path contains a shell-expansion
      // form" (measured 2026-10-24; reds `test-script-backdoor.mjs` B5c on any box where
      // `gh` on PATH IS that shim).
      //
      // ⛔ THE PREDICATE IS THE DIGEST, NOT THE PATH. `_sanctionedScriptExemption` has two
      // arms and only arm 2 checks bytes; arm 1 is PATH ONLY by spec (the pre-existing
      // `~/.pi/agent` anchor, unchanged by #2332). Keying this stand-down on
      // `exemption !== null` therefore exempts ARBITRARY bytes at a sanctioned relpath
      // under the module's root — measured at review AND by the verifier: an unaudited
      // body planted at a sanctioned relpath was ALLOWED with the path-keyed version and
      // BLOCKED without it. That is the #1228 fail-open (silent destruction of other
      // sessions' uncommitted work, which an expanded operand resolves at runtime).
      // `_isAuditedSanctionedScript` adds the pin's sha256 for BOTH arms, so only the
      // shipped bytes can take it. Note the body's own discards are still PARSED above (the
      // set filter is what drops them), and the nested-script descent below is NOT skipped
      // — the audited-bytes claim is about THIS file only, so whatever its body names is
      // still walked.
      // #1228: a script we DID read runs an EXPANDED path — same unreadable-script hole
      // one level down, as a direct operand or as a piped producer; fail closed before the
      // walk silently skips it. #3243: through `_expRefusalForBody`, so the digest-keyed
      // sanctioned stand-down and the honest attribution are the SAME as every other body
      // reader (this site duplicated the stand-down). The BODY ITSELF is scanned exactly as
      // it was before this change — the body-preparation hunk was measured and is NOT
      // landed (see `_expRefusalForBody`), so nothing about this call prepares it.
      const expNested = _expRefusalForBody(real, content);
      if (expNested) return expNested;
      p = extractScriptPath(content) ?? seeds.shift() ?? null;
    }
    // #1885 — the SECOND, independently bounded walk: every command-position script the
    // command really executes, each read with the SAME ≤64 KB regular-file predicate and
    // probed on its EFFECT. `cpQueue` is its own queue, so a nested script found in a
    // command-position script is followed here (a script that runs another script is the
    // same one-level-down hole the pre-existing walk closes), and the +3 accounts for that
    // chain without ever waiting on a pre-existing seed.
    {
      const cpQueue = cpSeeds.slice();
      const cpBound = cpQueue.length + 3;
      for (let k = 0; k < cpQueue.length && k < cpBound; k++) {
        const seed = cpQueue[k];
        let real: string;
        try { real = realpathSync(resolve(execCwd, seed)); } catch { continue; }
        if (seen.has(real)) continue;
        seen.add(real);
        let content: string;
        try {
          if (!existsSync(real) || !statSync(real).isFile() || statSync(real).size > 64 * 1024) continue;
          content = readFileSync(real, "utf8");
        } catch { continue; }
        // Same parse-not-substring gate as the pre-existing walk above (review P2) —
        // `apply` / `--reverse` is a whole-tree discard the old prefilter never matched.
        const disc = extractWorkingTreeDiscards(content) ?? [];
        if (disc.length) {
          sets.push({ discs: disc, baseCwd: execCwd, writeCwd: execCwd, script: seed, digest: _sha256OfBody(content) });
        }
        // Same digest-keyed stand-down as the walk above — ONE predicate, both walks (a
        // sanctioned script reached through the command-position queue must not be gated by
        // a rule its sibling walk already exempts it from). The nested-script push below is
        // NOT skipped, for the same reason. #3243: `_expRefusalForBody` (see the sibling walk).
        const expNested = _expRefusalForBody(real, content);
        if (expNested) return expNested;
        const nested = extractScriptPath(content);
        if (nested && !seen.has(String(nested)) && !cpQueue.includes(nested)) cpQueue.push(nested);
      }
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
    // #1228: the payload-level expansion check runs FIRST — before the opaque
    // (`$`/backtick) branch, which `continue`s — so the `$(cat <expanded>)` and
    // `<(…)` forms are refused rather than skipped (review cycle-2 P0).
    const expEval = _expRefusal(payload);
    if (expEval) return expEval;
    // ⛔ The bound this payload's references are read at (review round-3 G4 + its
    // verification), hoisted OUT of the exact-`$NAME` arm because the compound-payload arm
    // below needs it too: `eval "$P"` is expanded by the PARENT (the prefix is not in
    // effect), while `eval '$P'` is re-parsed by `eval` in a shell where the prefix IS in
    // the environment (both measured).
    const evalAt = m.index ?? 0;
    const evalCmdStart = m[2] === "'" ? evalAt : _wtSimpleCommandAbs(command, evalAt);
    if (name) {
      // #1885 — the SAME word reader the command-position arm uses (review P1). The
      // old ad-hoc `\\S+` capture kept a trailing separator, so `S=./undo.sh; eval $S`
      // captured `./undo.sh;`, the stat below threw, and the payload fell through to
      // "no verb ⇒ allow" — while the identical command with one space before the `;`
      // blocked. The assignment WORD is read one way in all three readers.
      //
      // ⛔ POSITIONALLY, at THIS payload's offset (review P1). "The last assignment in the
      // command" laundered `P='./undo.sh'; eval "$P"; P=ls` (origin/main BLOCK → ALLOW);
      // dropping a twice-assigned name instead dropped BOTH, leaving the payload
      // unresolved and the verb test below to decide — and that test reads the COMMAND
      // text, which does not contain `git checkout` when the verb lives inside the script
      // the payload names (`P='./undo.sh'`). Both shapes are B5g regressions.
      // ⛔ POSITIONALLY, at THIS payload's offset (review P1), and only STRICTLY BEFORE the
      // `eval` word's own SIMPLE COMMAND when the PARENT expands the payload (review
      // round-3 G4): `P=./undo1885.sh eval "$P"` is an ENV PREFIX, so bash expands `$P`
      // from the previous environment and runs `eval ""`. A single-quoted payload is
      // re-parsed by `eval` itself, where the prefix IS in the environment, so it keeps the
      // payload-offset bound (`P=./undo1885.sh eval '$P'` runs `./undo1885.sh`, measured).
      const amRaw = _wtAssignBeforeAbs(_wtAssignmentsIn(command), evalCmdStart).text.get(name);
      const val = amRaw === undefined ? null : _dequoteShellWord(amRaw);
      // Assigned in this command, but not by the shell BEFORE this use site (the only
      // assignment is in a heredoc BODY, or comes after the `eval`). origin/main read
      // such a name as a resolved script and gated it; "unresolved" must not become the
      // ALLOW branch, so it fails closed with the payload form the opaque arm uses. An
      // assignment that is only an ENV PREFIX of this same `eval` command is excluded for
      // the same reason the fold excludes it (review round-3 G4).
      if (!val && _wtAssignsName(command, name, evalCmdStart)) {
        return _worktreeDiscardBlockReason({ form: "eval-payload", scope: "all", pathspecs: [] }, execCwd, `an \`eval\` payload (\`${name}\`) is assigned in this command but not statically readable AT the call site`);
      }
      if (val) {
        // #1228: a resolved `eval` value can itself be an expanded script shape
        // (`P='cat ./undo*.sh | bash'; eval "$P"`), or can NAME a readable
        // script file whose body runs one (`W=./outer.sh; eval "bash $W"`) — the
        // `-c` arm resolves both; mirror it here.
        const expVal = _expRefusal(val);
        if (expVal) return expVal;
        try {
          const real = realpathSync(resolve(execCwd, val));
          if (statSync(real).isFile() && statSync(real).size <= 64 * 1024) {
            const vContent = readFileSync(real, "utf8");
            const expFile = _expRefusalForBody(real, vContent);
            if (expFile) return expFile;
            sets.push({ discs: extractWorkingTreeDiscards(vContent) ?? [], baseCwd: execCwd, writeCwd: execCwd, script: val, digest: _sha256OfBody(vContent) });
          }
        } catch { /* not a readable file — the payload arms below still apply */ }
      }
      if (val && !/[$`]/.test(val)) {
        sets.push({ discs: extractWorkingTreeDiscards(val) ?? [], baseCwd: execCwd, writeCwd: execCwd, script: null, digest: null });
        continue;
      }
    }
    // ⛔ A COMPOUND payload that CONTAINS a reference is still code the shell RUNS, not an
    // opaque blob (review round-3 verification): `P=./undo1885.sh; eval "echo hi; $P"`
    // re-parses to `echo hi; ./undo1885.sh` and discards (measured; ALLOWED before this,
    // and identically on origin/main). The exact-`$NAME` reader above cannot see it, so
    // substitute the references this command CAN read and scan the RESULT. Only a result
    // with nothing unreadable left (`$` / backtick) is trusted; anything else stays opaque
    // and the fail-closed verb test below decides, exactly as before.
    if (/[$`]/.test(payload)) {
      const state = _wtAssignBeforeAbs(_wtAssignmentsIn(command), evalCmdStart);
      const sub = _wtSubstituteVars(payload, _wtAssignVarsNow(state.literal, state.text));
      if (sub !== payload && !/[$`]/.test(sub) && !/[{}]/.test(sub)) {
        const expSub = _expRefusal(sub);
        if (expSub) return expSub;
        sets.push({ discs: extractWorkingTreeDiscards(sub) ?? [], baseCwd: execCwd, writeCwd: execCwd, script: null, digest: null });
        try {
          const sp = extractScriptPath(sub);
          if (sp && !/[$`]/.test(sp)) {
            const scContent = readFileSync(resolve(execCwd, sp), "utf8");
            const expSc = _expRefusalForBody(sp, scContent);
            if (expSc) return expSc;
            sets.push({ discs: extractWorkingTreeDiscards(scContent) ?? [], baseCwd: execCwd, writeCwd: execCwd, script: sp, digest: _sha256OfBody(scContent) });
          }
        } catch { /* missing/unreadable — the substituted text's own discards still stand */ }
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
    // #1228: the payload can name a readable script FILE whose OWN body runs an
    // expanded path (`eval 'bash ./outer-glob.sh'`). Its discards are pushed AND
    // the payload's OWN discards are still extracted below — an earlier cut
    // `continue`d here, which skipped `eval 'bash ./clean.sh; git checkout --
    // dirty.txt'` entirely and was a fail-open REGRESSION (review cycle-2 P0).
    try {
      const sp = extractScriptPath(payload);
      if (sp && !/[$`]/.test(sp)) {
        const eContent = readFileSync(resolve(execCwd, sp), "utf8");
        const expFile = _expRefusalForBody(sp, eContent);
        if (expFile) return expFile;
        sets.push({ discs: extractWorkingTreeDiscards(eContent) ?? [], baseCwd: execCwd, writeCwd: execCwd, script: sp, digest: _sha256OfBody(eContent) });
      }
    } catch { /* missing/unreadable — the verb test below still applies */ }
    if (!_MENTIONS_DISCARD_VERB(payload)) continue;
    sets.push({ discs: extractWorkingTreeDiscards(payload) ?? [], baseCwd: execCwd, writeCwd: execCwd, script: null, digest: null });
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
    // ⛔ THE PAYLOAD'S OWN OFFSET, REPORTED BY THE TOKENIZER (review round-3 G1). This
    // used to be a TEXT SEARCH — `s.indexOf(pl.text, cursor)` with a `s.indexOf(pl.text)`
    // fallback — so an earlier IDENTICAL token won the search and the positional read
    // below answered about an offset that was NOT the call site:
    // `P=./noop.sh; A="$P"; P=./undo.sh; bash -c "$P"` was ALLOWED while bash really ran
    // `./undo.sh` (measured), because `"$P"` was found inside `A="$P"`. The cursor made
    // the SECOND copy right and the FIRST one wrong; dropping the fallback made it
    // fail-OPEN instead of unresolved. `wtShellInlinePayloads` therefore reports `at`,
    // and a payload whose offset cannot be established (-1) is UNRESOLVED — the
    // fail-closed arm below, never a guess.
    const payloadAt = typeof pl.at === "number" ? pl.at : -1;
    // The payload's own SIMPLE COMMAND start, so the read excludes an `NAME=…` ENV
    // PREFIX of the interpreter invocation (review round-3 G4): `P=./undo.sh bash -c
    // "$P"` runs `bash -c ""`, so folding that assignment FALSE-BLOCKED a benign command.
    // ⛔ ONLY FOR A PARENT-EXPANDED PAYLOAD. A single-quoted payload is expanded by the
    // CHILD, whose environment carries that prefix, so the prefix IS the value that runs —
    // `P=./undo1885.sh bash -c '$P'` discards `dirty.txt` (measured). There the bound stays
    // the payload's own offset, which is what origin/main read.
    const payloadParentExpanded = _wtInlinePayloadParentExpanded(pl.text);
    const payloadCmdStart = payloadAt >= 0
      ? (payloadParentExpanded ? _wtSimpleCommandAbs(command, payloadAt) : payloadAt)
      : -1;
    // A RUNTIME placeholder inside the payload (`-I{}` is by far the common
    // form) can never be resolved statically (reviewer round-8 P1).
    if (/\{\}/.test(pl.text)) {
      return _worktreeDiscardBlockReason({ form: "interpreter-c-payload", scope: "all", pathspecs: [] }, execCwd, "an interpreter `-c` payload is a runtime placeholder");
    }
    // Outer quotes are stripped first — `extractScriptPath` tokenizes the
    // payload as a COMMAND, and a leading `'` would make `'source` an
    // unrecognised head.
    const inner = pl.text.replace(/^["']|["']$/g, "");
    // #1228: an EXPANDED script path inside the payload is the same
    // unreadable-script hole one level in — as a direct operand (`bash -c
    // 'bash ./undo*.sh'`) or as a piped producer (`bash -c 'cat ./undo*.sh |
    // bash'`); both are ordinary agent shape, and the read below would
    // silently no-op (the literal `./undo*.sh` does not exist on disk). Runs
    // BEFORE the opaque split: a payload carrying a `$VAR` producer (`bash -c
    // 'F=./undo.sh; cat $F | bash'`) is `opaque`, and the branch below would
    // otherwise skip it.
    const expC = _expRefusal(inner);
    if (expC) return expC;
    if (!pl.opaque) {
      try {
        const sp = extractScriptPath(inner);
        if (sp && !/[$`]/.test(sp)) {
          const cContent = readFileSync(resolve(execCwd, sp), "utf8");
          // #1228: the payload names a readable script FILE, but that file's own
          // body can run an expanded path (`bash -c 'bash ./outer-glob.sh'`
          // where outer-glob.sh is `bash ./undo*.sh`) — the payload-text check
          // above cannot see it, and the static-discard probe below cannot read
          // the inner script. Same rule as the nested-script walk.
          const expFile = _expRefusalForBody(sp, cContent);
          if (expFile) return expFile;
          sets.push({ discs: extractWorkingTreeDiscards(cContent) ?? [], baseCwd: execCwd, writeCwd: execCwd, script: sp, digest: _sha256OfBody(cContent) });
        }
      } catch { /* missing/unreadable — the direct surface still gates */ }
      continue;
    }
    const bare = inner;
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
          const catContent = readFileSync(real, "utf8");
          // #1228: the content this file becomes the payload for can itself
          // carry an expanded script shape (`bash -c "$(cat /tmp/x.sh)"` where
          // x.sh pipes `./undo*.sh` into bash) — the static-discard probe below
          // cannot read it, so the nested-script rule applies here too.
          const expCat = _expRefusalForBody(real, catContent);
          if (expCat) return expCat;
          sets.push({ discs: extractWorkingTreeDiscards(catContent) ?? [], baseCwd: execCwd, writeCwd: execCwd, script: catPath, digest: _sha256OfBody(catContent) });
          continue;
        }
      } catch { /* missing/unreadable → the verb test still applies */ }
    }
    const vm = /^\$(\w+)$|^\$\{(\w+)\}$/.exec(bare);
    const name = vm?.[1] ?? vm?.[2];
    if (name) {
      // #1885 — the SAME word reader the command-position arm uses (review P1). The
      // old ad-hoc `\\S+` capture kept a trailing separator, so `S=./undo.sh; eval $S`
      // captured `./undo.sh;`, the stat below threw, and the payload fell through to
      // "no verb ⇒ allow" — while the identical command with one space before the `;`
      // blocked. The assignment WORD is read one way in all three readers.
      //
      // ⛔ POSITIONALLY, at THIS payload's own offset — REPORTED BY THE TOKENIZER now, not
      // recovered by a text search (review round-3 G1) — and bounded by the payload's own
      // simple command (review round-3 G4). A payload whose offset cannot be established is
      // left UNRESOLVED, which is the fail-closed arm below, never a guess.
      const amRaw = payloadCmdStart >= 0 ? _wtAssignBeforeAbs(_wtAssignmentsIn(command), payloadCmdStart).text.get(name) : undefined;
      if (!amRaw && _wtAssignsName(command, name, payloadCmdStart)) {
        // Assigned in this command, but not by the shell BEFORE this `-c` — an unresolved
        // payload must not become an ALLOW (review P1). Bounded the same way the fold is
        // (review round-3 G4 + its verification): an ENV PREFIX of the interpreter
        // invocation is not a value a PARENT-expanded payload can see.
        return _worktreeDiscardBlockReason({ form: "interpreter-c-payload", scope: "all", pathspecs: [] }, execCwd, `an interpreter \`-c\` payload (\`${name}\`) is assigned in this command but not statically readable AT the call site`);
      }
      if (amRaw !== undefined) {
        const val = _dequoteShellWord(amRaw);
        // A value that is ITSELF opaque (`S=$(printf 'git checkout -- f')`,
        // `read`-fed, `printf -v`-fed) is NOT resolved — falling through to the
        // fail-closed test is the whole point. Only a statically readable value
        // is probed and short-circuits (reviewer round-7, second pass).
        // #1228: the resolved value can itself be an expanded script shape
        // (`S='cat ./undo*.sh | bash'; bash -c "$S"`) — the static-discard
        // probe cannot read it, so fail closed before it.
        const expVal = _expRefusal(val);
        if (expVal) return expVal;
        if (!/[$`]/.test(val)) {
          sets.push({ discs: extractWorkingTreeDiscards(val) ?? [], baseCwd: execCwd, writeCwd: execCwd, script: null, digest: null });
          // #1885 — a readable payload that NAMES A SCRIPT is not code, it is an
          // invocation: `S=./undo.sh; bash -c $S` runs the file, and its body can
          // discard. Read it with the same predicates the command-position arm
          // applies (path word, real file, executable, bounded size).
          try {
            const words = val.trim().split(/\s+/).filter(Boolean);
            const first = words[0] ?? "";
            if (first.includes("/") || first.startsWith("~")) {
              const real = realpathSync(resolve(execCwd, first));
              const st = statSync(real);
              if (st.isFile() && (st.mode & 0o111) !== 0 && st.size <= 64 * 1024) {
                const pContent = readFileSync(real, "utf8");
                const expP = _expRefusalForBody(first, pContent);
                if (expP) return expP;
                sets.push({ discs: extractWorkingTreeDiscards(pContent) ?? [], baseCwd: execCwd, writeCwd: execCwd, script: first, digest: _sha256OfBody(pContent) });
              }
            }
          } catch { /* not a readable executable file — the code probe above stands */ }
          continue;
        }
      }
    }
    // ⛔ A COMPOUND payload that CONTAINS a reference is still code the interpreter RUNS
    // (review round-3 verification): `P=./undo1885.sh; bash -c "cd . && $P"` expands to
    // `cd . && ./undo1885.sh` and discards (measured; ALLOWED before this, identically on
    // origin/main). The exact-`$NAME` reader above cannot see it, so substitute the
    // references this command CAN read and scan the RESULT. Only a result with nothing
    // unreadable left is trusted; otherwise the payload stays opaque and the fail-closed
    // verb test below decides, exactly as before.
    if (pl.opaque && bare.includes("$")) {
      const state = _wtAssignBeforeAbs(_wtAssignmentsIn(command), payloadCmdStart);
      const sub = _wtSubstituteVars(bare, _wtAssignVarsNow(state.literal, state.text));
      if (sub !== bare && !/[$`]/.test(sub) && !/[{}]/.test(sub)) {
        const expSub = _expRefusal(sub);
        if (expSub) return expSub;
        sets.push({ discs: extractWorkingTreeDiscards(sub) ?? [], baseCwd: execCwd, writeCwd: execCwd, script: null, digest: null });
        try {
          const sp = extractScriptPath(sub);
          if (sp && !/[$`]/.test(sp)) {
            const scContent = readFileSync(resolve(execCwd, sp), "utf8");
            const expSc = _expRefusalForBody(sp, scContent);
            if (expSc) return expSc;
            sets.push({ discs: extractWorkingTreeDiscards(scContent) ?? [], baseCwd: execCwd, writeCwd: execCwd, script: sp, digest: _sha256OfBody(scContent) });
          }
        } catch { /* missing/unreadable — the substituted text's own discards still stand */ }
        continue;
      }
    }
    if (_MENTIONS_DISCARD_VERB(command)) {
      return _worktreeDiscardBlockReason({ form: "interpreter-c-payload", scope: "all", pathspecs: [] }, execCwd, "an interpreter `-c` payload is not statically resolvable");
    }
  }

  // #1139 — M5's own sanctioned-script exemption, the M5 twin of #1129's M4
  // exemption (`_backdoorBlock`). SAME list, SAME anchor: `SANCTIONED_SCRIPT_RELPATHS`
  // resolved under the running guard's OWN checkout, realpath-keyed on both
  // sides. Without it M4 and M5 disagree about the framework's recovery
  // helper — M4 exempts `hub-worktree.sh` while M5 blocks it anyway, which is
  // what made the file's own comment ("Recovery scripts … keep working")
  // false.
  //
  // The reported block: the salvage path reverts the hub's tracked dirt with
  // `git show "HEAD:$rest" > "$MAIN_REPO/$rest"`. The pure extractor can only
  // surface that as a `cat-file-revert` HINT whose pathspec is the SHELL LOOP
  // VARIABLE `$rest`, and the unresolvable-pathspec rule below then fails
  // closed — on a provably clean checkout, for a script whose every discard is
  // preceded by its own capture+push (and which refuses to clean the hub when
  // that push fails).
  //
  // SCOPE — the SET is dropped, never the command: `sets[0]` (the command's own
  // argv) always carries `script: null` and is always gated, and a script
  // reached through a second hop keeps its OWN set, so `bash /tmp/wrapper.sh`
  // that sources the sanctioned file is still gated on everything the wrapper
  // itself says. SAFETY — a set's `script` is always the file the set's discards were
  // READ from (the seed walk stores `realpathSync(resolve(execCwd, p))`'s content with
  // `p`; every other push site reads the file it stores and carries that body's sha256
  // alongside it), so the exemption can only ever drop discards that came from the
  // sanctioned file's OWN bytes — and, since #2775, only when those bytes ARE the pinned
  // ones. Naming the sanctioned path from elsewhere buys nothing — the content is still
  // that file's, and a wrapper's own discards stay in the wrapper's set. ⛔ THE PATH ALONE
  // WAS NOT ENOUGH (#2775): see the filter below for the measured fail-open that keyed on
  // `rel` alone.
  // KEYING — a copy at the same relpath in another checkout is NOT
  // exempt (the anchor is the guard's own checkout, not a repo fingerprint and
  // not the invoking cwd); the hub's own `scripts/` spelling still matches when
  // a session addresses it through a symlink, because both sides are realpath'd.
  // A wrong anchor here is fail-OPEN on other sessions' uncommitted work, which
  // is why this reuses the hardened #1129 helper instead of re-deriving one.
  //
  // AUDIT — one row per command, emitted only when a set was ACTUALLY dropped,
  // aggregating BY REALPATH and recording HOW MANY discards the relaxation hid.
  // A row that said only "an exemption fired" cannot answer "did this exemption
  // suppress a block?" (review fold-in); a row written from inside the filter
  // predicate fires even when nothing was dropped; and summing raw push-sites
  // double-counts, because the same sanctioned file can be pushed as TWO sets in
  // one command (the bounded walk's `seen` set is local to the walk; the inline
  // `-c` / `$( )` push sites never consult it), which reported 2 / 2 for
  // `bash <s>; bash -c 'source <s>'` (review cycle-2 P2).
  const exempted = new Map<string, { rel: string; via: "module-root" | "identity"; discards: number; forms: Set<string> }>();
  const gatedSets = sets.filter((s) => {
    if (s.script === null) return true; // the command's own argv is never exempt
    // ⛔ THE KEY IS THE BODY'S DIGEST, NOT THE PATH (#2775). This decision DROPS a discard
    // verdict that was parsed out of a file, so it is a claim about BYTES, and
    // `_sanctionedScriptExemption` alone is not enough: its arm 1 is PATH-ONLY by spec (the
    // pre-existing `~/.pi/agent` anchor), and on a copy-deployed box the module root is not a
    // git checkout, so an agent can mint a destructive script at a sanctioned relpath under
    // it and have its discards dropped instead of gated (`_isAuditedSanctionedScript`'s
    // docblock carries the measurement). `s.digest` is the sha256 of the very body these
    // discards were parsed from (every push site stores the content it read WITH the set), so
    // the narrowing pairs "the body I judged" with "the body I hashed" by construction — a
    // re-read here would be a TOCTOU an agent can win by rewriting the file between the two.
    let sa: { rel: string; via: "module-root" | "identity" } | null = null;
    // Fail closed on a probe failure: keep the set gated. `null` digest = no body behind the
    // set, which declines the exemption for the same reason a mismatch does.
    try { sa = s.digest === null ? null : _auditedSanctionedExemption(resolve(execCwd, s.script), s.digest); } catch { sa = null; }
    if (sa === null) return true;
    const rel = sa.rel;
    const via = sa.via;
    let real = resolve(execCwd, s.script);
    try { real = realpathSync(real); } catch { /* keep the lexical path as the key */ }
    const prev = exempted.get(real);
    if (prev) {
      // The same realpath always yields the same discard list (the content is
      // read from that file), so repeated push sites must NOT add up: `max`
      // keeps `discards_dropped` consistent with `sets_exempted` — a row saying
      // 1 set hid 2 discards misstates the suppression it exists to report
      // (review cycle-3 P2).
      prev.discards = Math.max(prev.discards, s.discs.length);
      for (const d of s.discs) prev.forms.add(d.form);
    } else {
      exempted.set(real, { rel, via, discards: s.discs.length, forms: new Set(s.discs.map((d) => d.form)) });
    }
    return false;
  });
  if (exempted.size > 0) {
    const rows = [...exempted.entries()];
    try {
      appendJsonl({
        event: "m5_script_exemption",
        extension: "main-worktree-guard",
        script: rows[0][1].rel,
        // WHICH arm granted it, as M4's row already records (`#2332`): an operator must be
        // able to tell a module-root exemption from a checkout one. `#2775` narrowed BOTH
        // arms to the pinned bytes, so the row now also names an identity the agent cannot
        // forge by writing a file.
        sanctioned_via: rows[0][1].via,
        script_realpath: rows[0][0],
        scripts: rows.map(([, v]) => v.rel),
        sets_exempted: rows.length,
        discards_dropped: rows.reduce((n, [, v]) => n + v.discards, 0),
        discard_forms: [...new Set(rows.flatMap(([, v]) => [...v.forms]))],
        framework_root: _frameworkRoot,
        session_cwd: sessionCwd,
        command: command.slice(0, 300),
        session_id: _currentSessionId(),
      });
    } catch { /* audit is best-effort — never blocks */ }
  }

  if (gatedSets.every((s) => s.discs.length === 0)) return null;

  for (const set of gatedSets) {
    // The `cat-file-revert` form (`git show HEAD:x > x`) needs the source's
    // bash WRITE targets (pure string walk) to find where the content lands.
    // #1060 — they are kept in their WRITE-CWD-RELATIVE spelling: the state
    // predicate substitutes a same-command `NAME=<literal>` assignment BEFORE
    // resolving, so an ABSOLUTE `$MAIN_REPO` is not re-anchored under the write
    // cwd (which is how the fail-open was measured).
    let writeTargetsRel: string[] = [];
    if (set.discs.some((d) => d.form === "cat-file-revert")) {
      try {
        const src = set.script === null ? command : readFileSync(resolve(execCwd, set.script), "utf8");
        writeTargetsRel = extractBashWriteTargets(src, set.writeCwd).map((t) => relative(set.writeCwd, t.resolvedPath) || ".");
      } catch { /* best-effort — a miss only means no extra block */ }
    }

    for (const d of set.discs) {
      // #1060 — the `cat-file-revert` form is decided on STATE (see
      // `_catFileRevertStateBlock`). It also must not run the generic
      // unresolvable-pathspec rule below: for this form the pathspec is the
      // read-only SOURCE (`HEAD:<path>`), which may legitimately be a shell
      // variable — the DESTRUCTION is the redirect, and that is what the state
      // predicate probes. The script's own directory is passed as a candidate
      // checkout (a script's redirect may be anchored to a name the script
      // computes at runtime).
      //
      // #1125 — and the state predicate is what makes the check EFFECT-ORDERED:
      // a `cat-file-revert` HINT is a discard ONLY when the reproduced committed
      // content LANDS on a path (the form's whole model is `git show HEAD:x >
      // x`). With NO write target in the command/script there is nowhere for the
      // content to land, so the hint cannot be a revert whatever its pathspec
      // spells — and a read-only probe (`git cat-file -e "origin/$BRANCH:$f"`,
      // `git show "$ref:$f"`) is exactly that shape. `_catFileRevertStateBlock`
      // answers that FIRST (`writeTargetsRel.length === 0 → null`), so the
      // fail-closed arm on an unresolvable pathspec no longer refuses a command
      // with no discard effect at all: the sanctioned read-only triage tool
      // `scripts/stale-main-triage.sh` could not be RUN by an agent on the dirty
      // hub it diagnoses, and the fleet-durability sweep's per-file `git
      // cat-file -e` loop was blocked in three repos (2026-09-17 evidence on
      // #1125). That is not a relaxation — whenever the command DOES carry a
      // write surface the state predicate still runs and still fails closed,
      // so `git show HEAD:$f > $f` keeps blocking, as does a resolvable hint
      // landing on its own path.
      if (d.form === "cat-file-revert") {
        let scriptDir: string | null = null;
        if (set.script !== null && !/[$`]/.test(set.script)) {
          try { scriptDir = dirname(resolve(execCwd, set.script)); } catch { scriptDir = null; }
        }
        const stateReason = _catFileRevertStateBlock(d, writeTargetsRel, set.writeCwd, command, scriptDir);
        if (stateReason !== null) return stateReason;
        continue;
      }

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
        d.pathspecs.some((p) => {
          const bare = String(p).replace(/^["']|["']$/g, "");
          // Equality OR a whole path SEGMENT — the placeholder is usually
          // interpolated INTO a path (`src/@`), but a bare substring test made
          // `-I c`/`-I .` match nearly every pathspec (`clean.txt`) and blocked a
          // clean target (reviewer round-10 P2). A PLACEHOLDER-SIGNIFICANT token
          // (multi-character, or one of the classic replstrs) may also appear as
          // a prefix/suffix (`@.txt`, `f@` — reviewer round-11 P1).
          return xargsPlaceholders.some((t) => {
            if (!t) return false;
            const significant = t.length > 1 || /^(?:@|%|\+|\{\})$/.test(t);
            return bare === t || bare.includes(`${t}/`) || bare.includes(`/${t}`) || (significant && bare.includes(t));
          });
        }) ||
        d.pathspecs.some((p) => wtIsPlaceholderPathspec(p));
      if (unresolvable) {
        return _worktreeDiscardBlockReason(d, execCwd, "the target pathspec is not statically resolvable");
      }

      let probeCwd: string;
      let scope: { scope: string; pathspecs: string[]; fromTree?: boolean } = d;
      // The remaining forms (`checkout --`, `restore`, `reset --hard`, …): the
      // invocation is resolved to its effective checkout and the probe is
      // scoped to the pathspecs it names. `cat-file-revert` returned above — it
      // is the one form whose pathspec is a SOURCE rather than a target.
      {
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

// #1129 — sanctioned framework scripts, keyed on the running guard's OWN
// checkout (never on a path the command supplies).
//
// WHY THIS EXISTS: `scriptGitVerdict` false-blocks the framework's own
// mandated preflight from a HUB-rooted session on PURE TEXT shapes —
// `scripts/check-pipeline-compliance.sh` contains ```bash fences inside a
// single-quoted TEST FIXTURE and a usage heredoc whose prose says "git
// remote", and either alone pins the verdict to `block` even though the
// script's only real git invocation is a read-only `remote get-url`. That
// block makes commit-workflow Step 1 (the mandated preflight) unrunnable.
//
// WHY A NAMED LIST AND NOT THE DIRECTORY (adversarial review P0): `scripts/`
// also carries git-DESTRUCTIVE helpers — `cleanup-worktree.sh` runs `git
// worktree remove --force` + `git branch -D` on an agent-supplied branch, and
// `cleanup-stale-branches.sh --execute` deletes remote branches. Neither needs
// a write, so "the write gate already covers authoring a malicious script"
// does NOT cover RUNNING a pre-existing destructive one; a directory-wide
// exemption would let a hub-rooted session destroy another session's
// uncommitted work with the content walker switched off. Only scripts whose
// git content is read-only or the documented recovery surface are listed.
//
// WHY THE GUARD'S OWN CHECKOUT — AND (since #2332) A FRAMEWORK CHECKOUT WITH THE
// AUDITED BYTES: the realpath anchor is derived from this module's location, so
// an agent-editable COPY of the framework (a linked worktree, where the write
// gate is lifted) has a different realpath and is NOT exempt. A repo-fingerprint
// anchor (isAgentInfraRepo) would have been forgeable by exactly that route, so
// the root is never trusted ON ITS OWN: see `_sanctionedScriptExemption` — the
// second arm requires the sanctioned relpath INSIDE a framework checkout AND a
// sha256 match against `sanctioned-scripts.pin.json`. The pin is the half that
// cannot be forged; the root check only confines the exemption to framework
// trees. A copy of the audited bytes at an arbitrary path stays BLOCKED, and a
// DIFFERENT script at a sanctioned relpath (renamed into a framework tree) is
// BLOCKED too.
const SANCTIONED_SCRIPT_RELPATHS = [
  // commit-workflow Step 1 (01-preflight.md) — the mandated pre-push gate.
  "scripts/check-pipeline-compliance.sh",
  // The recovery helper most guard messages recommend.
  "scripts/checkout-hygiene/hub-worktree.sh",
  // #1141 — the mandated scratch-checkout helper. It is the fix for the
  // /tmp copy debris, and it is NOT usable from a hub-rooted session without
  // this exemption: its content carries `git worktree add/remove/prune`,
  // `sparse-checkout` and `read-tree`, so the content walk blocked exactly the
  // hub-rooted reviewers the rule is written for — who then fell back to the
  // improvisation the issue exists to stop (code-review cycle-2 P1, driven
  // through this module's real handler). Same class as hub-worktree.sh (worktree
  // create/remove, resolved at runtime), and TIGHTER than it: removal is
  // confined by `owns()` to a path that is under the scratch root AND carries
  // the tool's marker AND whose admin gitdir is under the COMMON
  // .git/worktrees/ AND whose admin dir's own `gitdir` back-link names that
  // checkout — the last of which is written by git, so it cannot be forged to
  // deregister a worktree the caller does not control (code-review-cycle-9 P1),
  // so it cannot be pointed at the hub or another checkout.
  "scripts/scratch-worktree.sh",
  // #1484/#1141 class, second instance — the review RECORDER. `record-review.sh` is mandated by the
  // review/merge path and its git surface is READ-ONLY (`merge-tree` incl. `--write-tree`,
  // `merge-base`, `cat-file`, `ls-tree`, `rev-parse`, `rev-list`, `diff`) — no `checkout`/`reset`/
  // `clean`/`stash`/`commit`/`push`/`rebase`/`worktree remove`. It is therefore LESS privileged
  // than the two entries above, which do `worktree add/remove/prune`, `sparse-checkout` and
  // `read-tree`. Without this entry its content walk blocks exactly the hub-rooted lanes the merge
  // path is written for, and the only remaining route is the improvisation this guard exists to
  // stop: measured 2026-10-05, a lane that had completed a review (tortoise #7433, comment
  // 6000279278) could review but never RECORD, which left a reviewed-but-unlandable PR — and the
  // same step gates every `blocked` row of the drain, since the rail requires a record bound to the
  // current head.
  "scripts/record-review.sh",
  // #1485 — the MERGE RAIL itself. `bash scripts/admin-merge.sh <pr>` is the
  // sanctioned way to land a PR and this repo's own rail. Measured git surface
  // (the guard's own recognizer, line by line): FOUR invocations, all of them
  // hub-recovery-allowed and none a branch/history mutation — `rev-parse
  // --is-inside-work-tree`, `worktree add --detach --force`, and two guarded
  // `worktree remove --force` calls. All four target a `mktemp -d` path the
  // script creates and traps, which is why the invocation walk allows them; the
  // merge itself goes through `gh`, and the evidence check through
  // `record-review.sh`. ⚠️ The earlier wording here ("ZERO git invocations",
  // "read-only") was WRONG — corrected at review cycle 2 — and it mattered: the
  // exemption returns before the walk, so the confinement of those worktree ops
  // is a property of the script, not something this list re-checks. Its content
  // walk pinned `block` on the unresolvable-delegation text arm
  // (`$(bash "$SELF_DIR/ci-workflow-pr-evaluable.sh")`), which made the rail
  // unrunnable from a hub-rooted session — the reported #1485 false positive.
  // Same class as #1141/#1484: a NAMED, audited path, never a directory or a
  // content rule.
  "scripts/admin-merge.sh",
  // #1485 — the argv-level admin-merge shim (#984), which `command -v gh`
  // resolves to in this fleet (`~/.pi/agent/shims/gh` → this file). Measured:
  // ZERO git invocations in its content (it inspects argv and delegates to the
  // evidence/rail scripts); it pinned `block` on the same unresolvable-delegation
  // text arm (`$(bash "$VERIFY" …)`), which refused EVERY `gh` call routed
  // through the shim — including the read-only `gh issue list` this issue
  // reports. Exempting the path is the same trade as the rail above, and the file
  // is why the merge evidence gate can be enforced on argv at all.
  "scripts/gh-shim/gh",
];
const _frameworkRoot: string | null = (() => {
  try {
    // #1129 (code-review P0): realpath the MODULE, THEN walk up — the
    // computation lives in classify-git (pure, so it is tested against a real
    // symlinked extension dir); the inline form below is the SAME expression
    // and exists so a stale classify-git cannot silently disable the
    // exemption. pi deploys this extension from the symlink farm
    // `~/.pi/agent/extensions/<name>` → this checkout and its loader preserves
    // the symlink spelling, so a lexical `../..` yields `~/.pi/agent`: not the
    // checkout (exemption inert → the mandated preflight stays blocked) and not
    // a git checkout (agent-WRITABLE, so a minted
    // `<~/.pi/agent>/scripts/<listed relpath>` would take the exemption).
    if (_frameworkRootFromModuleUrl) return _frameworkRootFromModuleUrl(import.meta.url);
    const self = realpathSync(fileURLToPath(import.meta.url));
    return realpathSync(resolve(dirname(self), "..", ".."));
  } catch {
    return null; // unknown location → no exemption (fail-closed)
  }
})();

/** THE INVARIANTS this function must keep (#2332) — it must be able to tell
 *  "the sanctioned rail, run from a hub" from "an arbitrary script pretending
 *  to be the rail". There are TWO arms and they carry DIFFERENT invariants;
 *  collapsing them into one sentence was false of arm 1 (#2332 review P2):
 *
 *    arm 1  exempt IFF the file is the sanctioned path inside THE MODULE'S OWN
 *           CHECKOUT. PATH ONLY — no digest is checked on this arm (it is the
 *           pre-existing anchor, deliberately unchanged).
 *    arm 2  exempt IFF (a) the file IS at a sanctioned relpath inside a
 *           FRAMEWORK CHECKOUT, (b) its bytes ARE the audited bytes (the
 *           sha256 pinned in `sanctioned-scripts.pin.json`), and (c) every
 *           file the leaf executes by its own location hashes to its pin.
 *
 *  For arm 2, (a) alone is a FILENAME: any destructive script renamed
 *  `admin-merge.sh` inside a directory carrying the framework's two fingerprint
 *  files would pass — "a framework checkout" is purchasable (`git init` +
 *  `manifest.json` + `pi-bootstrap/setup.sh` are all allowed operations).
 *  (b) alone is a CONTENT RULE: the same bytes at ANY path would pass, which is
 *  exactly the rule #1485 rejected at review (a committed script whose content
 *  is destructive ran with the walk switched off).
 *  TOGETHER they name ONE artifact — the framework's own rail, in a framework
 *  tree, with the bytes the framework ships — and the half an agent cannot
 *  reach is the BINDING, not the digest (digests are public: they hash shipped
 *  files). Every individual ingredient is purchasable — a repo, its two
 *  fingerprint files, the audited bytes (copy them) — so the soundness does NOT
 *  rest on "this path is privileged". It rests on the closure below: the
 *  exemption only ever admits an invocation whose every file the pin NAMES is
 *  the audited one, so a forged tree that ships exactly the audited program runs
 *  the REAL rail, which is the sanctioned behaviour by definition. A different
 *  leaf, a different `ci_exemption.py`, a missing delegate — each declines the
 *  exemption and the content walk runs.
 *
 *  ⛔ DECLARED RESIDUAL — the closure is a NAMED SET, not an EXACT SET (#2332
 *  review P0, agent-infra #2365). An EXTRA file in one of the closed directories
 *  that the audited leaf loads IMPLICITLY is neither pinned nor noticed:
 *  reproduced at review with `scripts/re.py` beside `scripts/ci_exemption.py`
 *  (`python3 <path>/ci_exemption.py` puts that directory first on `sys.path`, so
 *  `import re` ran the injected module), and with
 *  `ADMIN_MERGE_FAILURE_SET_SH=<agent file> bash <fw>/scripts/admin-merge.sh`
 *  (the rail executes that override at its own call sites). So the sentence this
 *  comment used to carry — "the worst a forged tree can achieve is running the
 *  REAL rail" — is NOT yet true of a tree that adds files; it is true only of a
 *  tree that ships exactly the pinned set. Closing it needs the pin to enumerate
 *  every file under the closed directories (an exact-set closure), which is a
 *  pin-FORMAT change: filed as #2365, deliberately not attempted here.
 *
 *  WHY TWO ARMS (and why this is not a widening of what the guard protects):
 *  arm 1 is the pre-existing anchor, UNCHANGED — the module's own checkout.
 *  It is the arm that makes the `~/.pi/agent` *copy* farm work, which is a
 *  recorded deployment decision (#427, macOS TCC: "replacing farm symlink with
 *  real copy"; the repo copy is CI-tested while production mints execute the
 *  `~/.pi` copy) and the arm #1603/#1598 fixed the review RECORDER onto. Arm 2
 *  exists because the rail is exec'd from a tree that is NOT the module's own:
 *  a hub-rooted session runs `$AGENT_INFRA_PATH/scripts/admin-merge.sh`, and arm
 *  1 resolves only the module's own root, so it can never reach that file.
 *  ⛔ Corrected: this paragraph used to justify arm 2 by saying the farmed
 *  `~/.pi/agent` copy ships a PARTIAL scripts surface that does not contain
 *  `admin-merge.sh` (#2176). That is false as of #3531 — the rail joined
 *  `merge_gate_srcs` and is farmed flat to `$DEST/scripts/admin-merge.sh`, and on
 *  a copy-deployed box `_frameworkRoot` IS `~/.pi/agent`, so the FARMED copy is
 *  arm-1 eligible now. The #2176 case is therefore the CHECKOUT, not the farm —
 *  which is still exactly why arm 2 must exist, so do not delete it as
 *  unjustified: without it the mandated rail is refused from every hub-rooted
 *  session again. Caught live 2026-10-22: the mandated rail was refused
 *  from a hub-rooted session, i.e. the chokepoint that computes the failing set
 *  before an `--admin` merge was unrunnable, and the only routes left were the
 *  hatch or a bare `gh pr merge` that skips every comparison the rail makes
 *  (#2332). Both arms fail CLOSED: no pin, no framework root, an unreadable
 *  file, or a hash mismatch all return null → the content walk runs as before.
 *  Realpath-keyed on both sides, so a symlinked spelling resolves to the same
 *  file and a `scripts/<rel>` SYMLINK inside a framework tree still hashes the
 *  file it points at (a mismatch unless that target IS the audited bytes).
 *  ⚠️ SCOPE, stated exactly: arm 2 admits the audited leaf from ANY tree that
 *  carries the framework fingerprint — including a linked worktree of this
 *  framework at the pinned bytes — so the README must not claim otherwise. That
 *  is intentional: once the closure is pinned, WHERE the audited program runs
 *  from does not change what it does, and pretending the anchor is narrower than
 *  it is would be the more dangerous error. */
function _sanctionedScriptExemption(resolvedScript: string): { rel: string; via: "module-root" | "identity" } | null {
  let real: string;
  try {
    real = realpathSync(resolvedScript);
  } catch {
    return null;
  }
  // ── arm 1: the guard's own checkout (pre-existing behaviour, unchanged) ──
  if (_frameworkRoot) {
    for (const rel of SANCTIONED_SCRIPT_RELPATHS) {
      let sanctioned: string;
      try { sanctioned = realpathSync(resolve(_frameworkRoot, rel)); } catch { continue; }
      if (real === sanctioned) return { rel, via: "module-root" };
    }
  }
  // ── arm 2: identity — sanctioned relpath + framework root + audited bytes
  //    AND the audited DELEGATION CLOSURE (see the comment above: a leaf whose
  //    siblings the agent chose is not the sanctioned script, it is a launcher) ──
  // Cheap pre-filter FIRST: for a command that executes some other script this
  // returns before the pin is even read, which is the common case.
  const candidates = SANCTIONED_SCRIPT_RELPATHS.filter((rel) => real.endsWith(sep + rel));
  if (candidates.length === 0) return null;
  const pin = _sanctionedScriptPin();
  for (const rel of candidates) {
    const want = pin.sha256[rel];
    if (typeof want !== "string" || want.length !== 64) continue; // no pin → not exempt
    const root = real.slice(0, real.length - rel.length - 1);
    if (resolve(root, rel) !== real) continue;               // not literally <root>/<rel>
    if (!_isFrameworkCheckout(root)) continue;
    // The executed leaf is compared DIRECTLY, not via the pin's bookkeeping: a
    // pin whose `delegates` omits the leaf (a hand re-cut, a partially-replaced
    // deploy) must not admit arbitrary bytes at a sanctioned relpath (#2332
    // review cycle 3). The closure then covers the REST of the program, so each
    // half is independently load-bearing.
    if (_sha256Of(real) !== want) continue;
    if (!_delegationClosurePinned(root, pin.delegates, rel)) continue;
    return { rel, via: "identity" };
  }
  return null;
}

/** #2332 / #1485 — TRUE only when `resolved` is a sanctioned script whose bytes ARE the
 *  pinned, audited ones: arm 1 or arm 2 of `_sanctionedScriptExemption`, PLUS the digest.
 *
 *  ⛔ The digest is not belt-and-braces. `_sanctionedScriptExemption`'s arm 1 is PATH ONLY,
 *  deliberately (it is the pre-existing `~/.pi/agent` anchor, kept unchanged by #2332), so
 *  "the exemption applied" is ALSO true for arbitrary bytes written to a sanctioned relpath
 *  under the module's own root — which on a copy-deployed box (a real `scripts/` copy inside
 *  `~/.pi/agent`, which is not a git checkout and so is outside the write gate) an agent can
 *  mint. A caller that stands down a CONTENT-derived refusal is making a claim about the
 *  BYTES, so it must ask THIS question and never `_sanctionedScriptExemption(...) !== null`.
 *  The difference is measurable: at review, an unaudited `#!/bin/bash` + `bash ./undo*.sh`
 *  minted at a farm relpath was BLOCKED before such a stand-down and ALLOWED after it — the
 *  #1228 fail-open (silent destruction of other sessions' uncommitted work) that this
 *  helper's digest check keeps shut.
 *
 *  Both arms are considered, because both anchors were already trusted by their own
 *  callers; the digest then narrows BOTH to the shipped bytes.
 *
 *  ⛔ `bodyDigest` EXISTS BECAUSE OF A TOCTOU, not for tidiness: the callers below hold a
 *  body they ALREADY READ (`readFileSync(real, "utf8")`), and comparing a digest re-read
 *  from the same path pairs "the body I judged" with "the bytes I hashed" only if nothing
 *  writes the file in between — and an agent may run a writer concurrently. Hashing the
 *  bytes in hand makes the pairing true by construction. This mirrors the pin's own reason
 *  for being read at load (`_sanctionedScriptPin`): any read that happens AFTER the process
 *  started is a read an agent can influence. The digest is therefore REQUIRED: every call
 *  site has the body in hand, and there is deliberately no disk-read fallback for a caller
 *  that does not, because that fallback is the defect this parameter exists to remove. */
function _isAuditedSanctionedScript(resolved: string, bodyDigest: string): boolean {
  return _auditedSanctionedExemption(resolved, bodyDigest) !== null;
}

/** #2775 — the exemption OBJECT, narrowed to the pinned bytes: `{ rel, via }` when `resolved`
 *  is a sanctioned script whose body hashes to its pin, otherwise `null`.
 *
 *  This is `_isAuditedSanctionedScript`'s body with the verdict handed back instead of
 *  flattened to a boolean, for the two call sites that must ALSO record WHICH arm granted the
 *  relaxation (#2332's `sanctioned_via`) or name the relpath in an audit row. One predicate,
 *  three consumers: a second implementation of "is this the audited script" is how the
 *  path-keyed answer survived in one place and not another (#2775).
 *
 *  `bodyDigest` is the sha256 of the body the CALLER read — never a fresh read of the path,
 *  for the TOCTOU reason `_isAuditedSanctionedScript`'s docblock gives. */
function _auditedSanctionedExemption(resolved: string, bodyDigest: string): { rel: string; via: "module-root" | "identity" } | null {
  let real: string;
  try { real = realpathSync(resolved); } catch { return null; }
  const sa = _sanctionedScriptExemption(real);
  if (sa === null) return null;
  const want = _sanctionedScriptPin().sha256[sa.rel];
  if (typeof want !== "string" || want.length !== 64) return null;
  return bodyDigest === want ? sa : null;
}

/** The execution the exemption actually grants is leaf PLUS everything the leaf
 *  executes. `admin-merge.sh` runs `$SELF_DIR/ci_exemption.py` (the exemption
 *  GRADER) and `gh-shim/gh` runs `$SELF_DIR/../verify-admin-merge-evidence.sh`
 *  (which says in its own words that it must not be redirectable), and the walk
 *  is skipped for the whole invocation — so a pinned leaf beside an AGENT-CHOSEN
 *  delegate is a launcher for arbitrary content (reproduced at review: the
 *  audited rail at a forged root plus a one-line destructive
 *  `ci_exemption.py` ran `reset --hard`). Pinning the leaf alone is therefore
 *  not the identity; the closure is. Every pinned delegate must be PRESENT in
 *  the same framework root and hash to its pin, or the whole exemption is
 *  declined (fail-closed: absent, unreadable and mismatched are all `false`). */
function _delegationClosurePinned(root: string, delegates: Record<string, string>, leaf: string): boolean {
  const rels = Object.keys(delegates);
  if (rels.length === 0) return false; // an empty closure is not a verified one
  for (const rel of rels) {
    if (rel === leaf) continue; // the leaf is compared directly by the caller
    const want = delegates[rel];
    if (typeof want !== "string" || want.length !== 64) return false;
    const got = _sha256Of(resolve(root, rel));
    if (got === null) return false; // absent is not "unverified", it DECLINES
    if (got !== want) return false;
  }
  return true;
}

/** sha256 of a file, or null when it cannot be read (callers compare against a
 *  digest, so null never equals one — the fail-closed direction). */
function _sha256Of(path: string): string | null {
  try {
    return createHash("sha256").update(readFileSync(path)).digest("hex");
  } catch {
    return null;
  }
}

/** sha256 of the IN-MEMORY body a caller already holds — the TOCTOU-free form for a
 *  decision about specific bytes (see `_isAuditedSanctionedScript`'s `bodyDigest`). */
function _sha256OfBody(body: string): string {
  return createHash("sha256").update(body, "utf8").digest("hex");
}


/** Is `root` a framework CHECKOUT (the `isAgentInfraRepo` fingerprint, read
 *  from disk so this stays a pure path probe with no git invocation)? Arm 2
 *  needs it so the exemption is confined to framework trees; the pin — not this
 *  — is what makes forgery useless. Fail-closed on any probe error. */
function _isFrameworkCheckout(root: string): boolean {
  try {
    return existsSync(join(root, "manifest.json")) && existsSync(join(root, "pi-bootstrap", "setup.sh"));
  } catch {
    return false;
  }
}

/** The pinned digests, CAPTURED AT MODULE LOAD from the guard's own directory.
 *  Read-at-load, not read-on-first-call (#2332 review P0): the module tree is
 *  writable on a copy-deployed box, so any read that happens AFTER the process
 *  started is a read an agent can influence — `write ~/.pi/agent/extensions/
 *  main-worktree-guard/sanctioned-scripts.pin.json`, THEN run the script, and a
 *  lazily-populated cache would accept the forged pin on the very first
 *  exemption check. Reading at load puts the pin's integrity on the same footing
 *  as the code that reads it (where the guard is loaded from is the trust anchor
 *  pi already chose), and keeps the "needs a restart" boundary in one place
 *  instead of two: forging the pin is now as useful as forging `index.ts`.
 *  A re-cut is a deploy event, so it lands with the session restart the
 *  deployment already implies. Any read/parse failure yields an EMPTY pin → arm
 *  2 stays inert (fail-closed).
 *  DECLARED RESIDUAL (agent-infra #2365): reading at load closes the WRITE-AFTER-
 *  START window, not the pre-start one — a session that rewrites the pin and then
 *  restarts (or a fresh session on a writable copy-deploy) still wins arm 2. The
 *  successor is a digest of the pin compiled into `index.ts`, which this change
 *  does not do. */
const _PIN: { sha256: Record<string, string>; delegates: Record<string, string> } = (() => {
  const empty = { sha256: {}, delegates: {} };
  try {
    const raw = readFileSync(fileURLToPath(new URL("./sanctioned-scripts.pin.json", import.meta.url)), "utf-8");
    const parsed: unknown = JSON.parse(raw);
    const norm = (v: unknown): Record<string, string> => {
      const out: Record<string, string> = {};
      if (!v || typeof v !== "object") return out;
      for (const [k, d] of Object.entries(v as Record<string, unknown>)) {
        if (typeof d === "string") out[k] = d.toLowerCase();
      }
      return out;
    };
    return {
      sha256: norm((parsed as { sha256?: unknown }).sha256),
      delegates: norm((parsed as { delegates?: unknown }).delegates),
    };
  } catch {
    return empty;
  }
})();
function _sanctionedScriptPin(): { sha256: Record<string, string>; delegates: Record<string, string> } {
  return _PIN;
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
            `   → Run the git commands directly, or work in an isolated worktree:`,
            // Round 6 (P2): this was the last message still prescribing the
            // no-op. On a DIRTY hub `git checkout main && git pull --ff-only`
            // cannot run (git refuses to switch over modified paths), and it
            // never named the named-path restore the recovery window sanctions.
            // Round 9 (P2): and it listed the BARE `--staged` spelling, which
            // is the form this PR documents as non-convergent — it leaves the
            // file MODIFIED so the hub stays dirty. The shared three-shape text
            // replaces that list.
            ...(_hubState().disorder
              ? _hubWriteRecoverLines(_hubState())
              : [`     (recovery from an off-main hub: git checkout main && git pull --ff-only)`]),
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
    // #967/#1484: pass the invocation's positional args so a branch only a
    // DIFFERENT subcommand reaches cannot gate this one (e.g. `--probe` must
    // not be blocked by a `--reset`-only discard). [] is a real argv (no args)
    // — `$1` is then provably empty; undefined would be "unknown".
    const scriptArgs = extractScriptArgs(command, scriptPath);
    // #1129 — the framework's OWN sanctioned scripts are exempted before the
    // content walk (see SANCTIONED_SCRIPT_RELPATHS for why this is a named
    // list keyed on the guard's own checkout). Deliberate gate relaxation →
    // audited (best-effort, never blocks) so the exemption is observable.
    // ⛔ THE DECISION IS A CLAIM ABOUT BYTES, SO THE DIGEST DECIDES (#2775).
    // `_sanctionedScriptExemption` alone is the PATH answer: its arm 1 is path-keyed by spec
    // (the pre-existing `~/.pi/agent` anchor, deliberately unchanged by #2332), and on a
    // copy-deployed box the module root is not a git checkout — so an agent can create
    // `<moduleRoot>/scripts/<sanctioned relpath>` with any body it likes and have this skip
    // take the WHOLE content walk (measured 2026-10-24 and again 2026-11-08: the planted body
    // was ALLOWED here and BLOCKED at any other path). The #1129 relaxation is therefore
    // granted only for the pinned bytes, exactly as the #1228 body arm already requires.
    //
    // ⛔ WHY A DISK READ HERE IS CORRECT AND IS NOT THE FALLBACK `_isAuditedSanctionedScript`
    // REFUSES: no body is in hand at this site — the walk it stands down has not read anything
    // yet — so there is no "body I judged" to pair, and `_sha256Of` is the ONE read the
    // decision is made from. The window between this read and the shell's own read of the same
    // path is unchanged by this fix and is why the digest NARROWS the hole rather than closing
    // it; it is the same window arm 2 has always had.
    const sanctionedPath = _sanctionedScriptExemption(resolved);
    const sanctionedMatch = sanctionedPath === null
      ? null
      : _auditedSanctionedExemption(resolved, _sha256Of(resolved) ?? "");
    if (sanctionedMatch) {
      try {
        // #1129 (code-review P2): record the REALPATH that matched, not just
        // the listed relpath — with only the relpath, an exemption taken
        // through a file at the same relpath under a different root (the
        // pre-fix anchor pointed at `~/.pi/agent`) logs an identical row. The
        // session cwd is recorded too, since that is what an operator needs to
        // reconstruct where the command came from.
        appendJsonl({
          event: "m4_script_exemption",
          extension: "main-worktree-guard",
          script: sanctionedMatch.rel,
          // #2332 — WHICH arm granted it: `module-root` is the pre-existing
          // anchor (the `~/.pi/agent` copy farm / the module's own checkout),
          // `identity` is the root-agnostic arm (sanctioned relpath inside a
          // framework checkout + the pinned audited bytes). Without this field
          // an operator cannot tell a farm exemption from a checkout one — the
          // distinction this issue is entirely about.
          sanctioned_via: sanctionedMatch.via,
          script_realpath: realpathSync(resolved),
          framework_root: _frameworkRoot,
          session_cwd: resolve(process.cwd()),
          command: command.slice(0, 300),
          session_id: _currentSessionId(),
        });
      } catch { /* audit is best-effort — never blocks */ }
      return null;
    }
    // #1485 (review cycle 3): a magic header does not make a file a binary when a
    // SHELL is asked to read it — `bash x` strips the first line and runs the rest,
    // so a `printf`-prefixed script skipped the walk entirely. The invocation decides.
    const viaInterpreter = scriptIsInterpreted(command, scriptPath);
    if (scriptGitVerdict(resolved, branch, base, resolve(process.cwd()), scriptArgs, { viaInterpreter }) === "block") {
      // #743: label the SCRIPT's own checkout, not the session's. A linked
      // worktree's copy is not "the shared main checkout", and the old message
      // offered hub-worktree.sh — which creates a worktree but cannot make a
      // hub-rooted session run a content-gated script.
      let scriptInWorktree = false;
      try { scriptInWorktree = isWorktreeCwdWrite(resolve(dirname(resolved))); } catch { /* main (safe default) */ }
      // #1129 — report the file that was actually READ. The hub's `scripts/` is
      // a symlink into agent-infra, so the typed path names one checkout while
      // the gated CONTENT belongs to another; and since the verdict comes from
      // that content (not from session state), a verdict that flipped in the
      // field without a code change is checkable against the tree only if the
      // resolved path is printed.
      let realResolved = resolved;
      try { realResolved = realpathSync(resolved); } catch { /* keep the spelling */ }
      return [
        `⛔ Script execution blocked — script content contains a blocked git operation (#1484).`,
        `   The script backdoor (write /tmp/x.sh + bash /tmp/x.sh) is closed:`,
        `   ${resolved}`,
        ...(realResolved !== resolved ? [`   (resolves to: ${realResolved})`] : []),
        `   (script location: ${scriptInWorktree ? "a linked worktree" : "the shared main checkout"})`,
        `   (verdict source: the script's CONTENT as read at that path, resolved against the`,
        `    execution/session cwd below and the hub's current branch — not session state alone;`,
        `    execution cwd: ${base ?? resolve(process.cwd())}; session cwd: ${resolve(process.cwd())})`,
        `   performs a git operation that is not sanctioned against the shared main checkout.`,
        `   → Run the underlying git commands directly (each is gated on its own), or do`,
        `     this work in an isolated worktree (invoke the using-git-worktrees skill).`,
        `   → cd-ing into a worktree from a HUB-ROOTED session does not lift this — the`,
        `     gate keys on the session cwd. Start the session in the worktree, or set`,
        `     the documented AGENT_ALLOW_MAIN_EDITS escape hatch for a solo session.`,
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
// `head` is `string | null` because #2218 made readBranchState report an UNBORN
// HEAD as a readable repo (`head: null`). It is written, never read by a
// decision (refreshed lazily at _rebaseline, "unused in decisions"), so the
// null is inert — but the annotation must not claim a sha that may not exist.
const baselines = new Map<number, { repoKey: string; branch: string | null; head: string | null; original: string | null }>();
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

function _markOwned(pid: number, repoKey: string | null | undefined, branch: string | null | undefined) {
  if (!repoKey || !branch) return;
  let byRepo = ownedBranches.get(pid);
  if (!byRepo) { byRepo = new Map(); ownedBranches.set(pid, byRepo); }
  let set = byRepo.get(repoKey);
  if (!set) { set = new Set(); byRepo.set(repoKey, set); }
  set.add(branch);
}

// #608: ownership is a statement about the refs this pid CURRENTLY holds, not an
// append-only record of every name it ever touched. A name leaves the pid's
// hands on exactly two observable events — its own rename AWAY from that name,
// and its own approved LOCAL delete of it — and each unmarks here, so a name a
// sibling later recreates cannot inherit this pid's destructive allowance (the
// #598 own-dst overwrite and the #543/#376 own-branch `-D`).
function _unmarkOwned(pid: number, repoKey: string | null | undefined, branch: string | null | undefined) {
  if (!repoKey || !branch) return;
  const set = ownedBranches.get(pid)?.get(repoKey);
  if (set) set.delete(branch);
}

/** Will git's SOFT `-d` actually delete `name` in `cwd`? Faithful to git's own
 *  `branch_merged()` (`builtin/branch.c`), NOT to the prose of git-branch(1):
 *
 *    "the branch must be fully merged in its upstream branch, or in HEAD if no
 *     upstream was set"
 *
 *  The prose is silent on the case that decides this probe: an upstream
 *  CONFIGURED but GONE (`[gone]` after `git fetch --prune`). `%(upstream)` still
 *  prints the configured refname there, but `branch_merged()` resolves it and —
 *  when it does not resolve — leaves `reference_rev` NULL and falls back to
 *  `head_rev`, i.e. it treats "upstream set but gone" EXACTLY like "no upstream
 *  set" and DELETES the merged branch (measured, git 2.43.0: `-d` rc 0 with the
 *  remote ref absent). So the upstream is only consulted when it RESOLVES; the
 *  unresolvable case must fall back to HEAD, or this probe answers "kept" where
 *  git deletes — the fail-open direction, and a stale claim is exactly the #608
 *  destruction.
 *
 *  Unverifiable (git error, missing ref) → false: the claim is KEPT, the
 *  direction that cannot lose a ref. */
function _softDeleteWillSucceed(cwd: string, name: string): boolean {
  let target = "HEAD";
  try {
    const up = execFileSync("git", ["for-each-ref", "--format=%(upstream)", `refs/heads/${name}`],
      // #1139: stderr is CAPTURED, never swallowed by "ignore" — the repo-wide
      // pin in test.mjs forbids the `["ignore", "pipe", "ignore"]` shape, which
      // leaked a failure message AND made the not-a-checkout arm dead code.
      { cwd, timeout: 5000, encoding: "utf-8", stdio: ["ignore", "pipe", "pipe"] }).trim();
    if (up) {
      // Only a RESOLVABLE upstream constrains the delete; a `[gone]` one makes
      // git fall back to HEAD (see above). One extra spawn, soft-deletes only.
      let resolves = false;
      try {
        execFileSync("git", ["rev-parse", "--verify", "--quiet", up],
          { cwd, timeout: 5000, stdio: "ignore" });
        resolves = true;
      } catch { resolves = false; }
      if (resolves) target = up;
    }
  } catch { return false; }
  try {
    execFileSync("git", ["merge-base", "--is-ancestor", `refs/heads/${name}`, target],
      { cwd, timeout: 5000, stdio: "ignore" });
    return true;
  } catch { return false; }
}

/** #608 — the LOCAL branch deletes this command performs, hard vs soft.
 *
 *  The classifier's `deleteTargets` describes ONE invocation (the first mutating
 *  one), so a compound `git branch -D a && git branch -D b` reports only `a` —
 *  and the M3 loop already resolves EVERY mutating invocation (stateMutations),
 *  so the claim set is the union over all of them, named by the classifier's own
 *  extractor (`branchDeleteNames`), never a re-derived spelling. Hard vs soft
 *  comes from the SHIPPED classifier too: the single-invocation verdict is
 *  `block:branch-force-delete` exactly for git's force-delete family. */
function _localDeleteClaimNames(det: any): { hard: string[]; soft: string[] } {
  const hard: string[] = [];
  const soft: string[] = [];
  if (!det || typeof branchDeleteNames !== "function") return { hard, soft };
  const muts = (det.stateMutations && det.stateMutations.length > 0)
    ? det.stateMutations
    : [{ verb: det.stateVerb, args: det.stateArgs }];
  for (const mu of muts) {
    if (!mu || mu.verb !== "branch") continue;
    let names: string[] | null = null;
    try { names = branchDeleteNames("branch", mu.args ?? []); } catch { names = null; }
    if (!names || names.length === 0) continue;
    let isHard = true; // unverifiable → hard (spend unconditionally: fail-closed)
    try {
      isHard = classifyGitCommandDetailed(`git branch ${(mu.args || []).join(" ")}`).verdict === "block:branch-force-delete";
    } catch { isHard = true; }
    for (const n of names) (isHard ? hard : soft).push(n);
  }
  return { hard, soft };
}

/** Remove the ownership claims an ADMITTED command destroys.
 *
 *  A hard `-D` deletes whatever git can reach, so its name is spent outright.
 *  A soft `-d` deletes ONLY a merged branch, so its name is spent only when
 *  git's own predicate says it will go: spending a claim the command did not
 *  lose turns the standard `-d` → `-D` escalation on the session's OWN branch
 *  into a block (#3979 review P2). The other refusal — a branch checked out in
 *  a worktree — needs no probe, because git refuses `-D` there too, so no
 *  escalation is lost. Every probe is spawn-once and only runs when the command
 *  actually contains a local delete. */
function _spendLocalDeleteClaims(pid: number, repoKey: string | null | undefined,
                                 cwd: string | null | undefined,
                                 claims: { hard: string[]; soft: string[] }) {
  if (claims.hard.length === 0 && claims.soft.length === 0) return;
  for (const n of claims.hard) _unmarkOwned(pid, repoKey, n);
  if (claims.soft.length === 0) return;
  const where = cwd || process.cwd();
  for (const n of claims.soft) {
    if (_softDeleteWillSucceed(where, n)) _unmarkOwned(pid, repoKey, n);
  }
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

// ── #1144: effect-shaped sync allowance ─────────────────────────────────────
// The allowance's sync arm (pull/merge/rebase) is decided on the operation's
// EFFECT, never on its verb. Live 2026-09-17: `git rebase origin/main` on the
// SHARED tortoise hub's `main` moved that branch (rewriting the local tip onto
// origin/main) under 11 live sessions with NO hatch, while the comparable
// `git reset --hard origin/main` was refused and demanded
// AGENT_ALLOW_MAIN_EDITS=1. A verb cannot be enumerated to safety: this
// enforcement is a string scan, so both its false-positive surface (prose that
// only DESCRIBES a verb) and its false-negative surface (a spelling it does not
// enumerate) are functions of TEXT, not of EFFECT. See
// shared/branch-ownership.mjs → syncEffectAllowed (the predicate) and
// classify-git.mjs → syncEffectOf (the parsed half).
const SYNC_ALLOWANCE_KINDS = new Set<string>(["pull", "merge", "rebase"]);

/** Is the checkout at `cwd` free of uncommitted work? Unverifiable (git error,
 *  no cwd) collapses to false — the sync arm must not fire on a guess. */
function _checkoutTreeClean(cwd: string | null | undefined): boolean {
  if (!cwd) return false;
  try {
    const porcelain = execSync("git status --porcelain", {
      encoding: "utf-8", cwd, timeout: 5000,
    }).trim();
    return porcelain.length === 0;
  } catch {
    return false; // fail closed — never admit a shared-branch move unverified
  }
}

/** Assemble the `effect` record the sync arm needs from the LIVE checkout
 *  preconditions (own repo, clean tree) and the classifier's parsed effect +
 *  only-git-invocation flag. Returns null when the parsed half is absent so
 *  the predicate fails closed. */
function _syncAllowanceEffect(eff: any, baseline: any, det: any) {
  const parsed = det?.syncEffect ?? null;
  if (!parsed) return null;
  const scopeOwnRepo = !!(baseline?.repoKey && eff?.repoKey && baseline.repoKey === eff.repoKey);
  // #2277: a session with NO baseline for the sync op's repo (a foreign-rooted
  // lane, a /tmp-rooted lane) can still advance a hub that is PROVABLY behind:
  // clean tree, on its own default branch, HEAD an ancestor of that branch's
  // upstream, and no explicit source ref (so the target IS the upstream).
  // Measured, never inferred — any unmeasurable case fails closed.
  const foreignProof = (!scopeOwnRepo && eff?.unresolvedTarget !== true && eff?.isWorktree !== true
    && Array.isArray(parsed.positionals) && parsed.positionals.length === 0
    && branchOwnership?.fastForwardOntoUpstreamProof)
    ? branchOwnership.fastForwardOntoUpstreamProof(eff?.effectiveCwd ?? null, eff?.currentBranch ?? null)
    : null;
  const syncCwd = eff?.effectiveCwd ?? null;
  return {
    parsedEffect: parsed,
    onlyGitInvocation: det?.syncOnlyInvocation === true,
    scopeOwnRepo,
    // The clean-tree read must cover the checkout the op MOVES (the sync op's
    // own resolved repo), not the command-level `eff` — for a `-C` hop those
    // differ, and a dirty foreign hub is exactly what must stay refused.
    treeClean: _checkoutTreeClean(syncCwd),
    foreignHubFastForward: foreignProof?.ok === true,
    ffProofWhy: foreignProof && foreignProof.ok !== true ? foreignProof.why : undefined,
  };
}

/** #1144 (reviewer P0): resolve the SYNC invocation's OWN repo. `eff` is
 *  resolved from the state-mutating / first invocation's hints, so a compound
 *  whose first segment is `git -C <worktree> …` made `eff.isWorktree` true and
 *  worktree-exempted a LATER sync op that actually runs at the shell cwd
 *  (`git -C <wt> status && git rebase origin/main` — the `-C` binds only the
 *  status; the rebase moves the SHARED hub). Returns null when the sync
 *  invocation's target cannot be resolved → the predicate fails closed. */
function _syncEffectiveRepo(det: any) {
  if (!branchOwnership) return null;
  try {
    if (det?.syncInvVisible === false) {
      // extractor-invisible payload → it runs at the shell cwd (fail closed,
      // never a worktree exemption the repo layer cannot verify)
      return branchOwnership.resolveEffectiveRepo("git status", process.cwd());
    }
    if (det?.syncHints) return branchOwnership.resolveRepoFromInv(det.syncHints, process.cwd());
    return null; // no boundary-aware hints for the sync op → unverifiable
  } catch {
    return null;
  }
}

/** #1144 (cycle-2 reviewer P0) — the LEGACY_BLOCK arm's worktree exemption.
 *  `eff.isWorktree` is resolved from ONE invocation's hints, so a compound
 *  command beginning with `git -C <worktree> …` made it true and laundered a
 *  LATER destructive segment that runs at the shell cwd
 *  (`git -C <wt> status && git reset --hard origin/main` moved the shared hub).
 *  Returns:
 *    true      — EVERY git invocation in the command resolves to a worktree
 *    false     — at least one does not (or is invisible/unresolvable) → block
 *    undefined — the classifier emitted no per-invocation data (degraded
 *                build): the caller keeps its previous behaviour rather than
 *                hard-blocking every destructive op in a worktree session. */
function _allInvocationsWorktreeScoped(det: any): boolean | undefined {
  // #1144 follow-up (P0-3): a hidden shell substitution (`git -C <wt> status
  // && eval "git reset --hard origin/main"`, `… && "$(git reset --hard
  // origin/main)"`) EXECUTES a destructive git op that contributes NO
  // invocation, so `invocationHints` looks complete while the list is not.
  // "Every git invocation resolves inside a worktree" is then unprovable — and
  // the exemption exists precisely to skip the destructive block — so fail
  // closed. (The visible twin and the `sh -c` twin already block because their
  // second invocation IS in the list.) Checked BEFORE the empty-list degrade:
  // a zero-visible-invocation compound hiding its git still must not inherit
  // `eff.isWorktree`.
  if (det?.hiddenStateSubst === true) return false;
  const invs = det?.invocationHints;
  if (!Array.isArray(invs) || invs.length === 0) return undefined;
  if (!branchOwnership) return undefined;
  for (const inv of invs) {
    if (inv?.visible === false) return false; // shell cwd, unverifiable → fail closed
    try {
      const r = inv?.hints ? branchOwnership.resolveRepoFromInv(inv.hints, process.cwd()) : null;
      if (!r || r.isWorktree !== true) return false;
    } catch {
      return false;
    }
  }
  return true;
}

/** The sync arm's refusal. It states WHY, and — per #1144 — names the
 *  fast-forward forms whose effect IS safe, instead of pointing only at the
 *  human hatch: the asymmetry (hatch-required via one verb, hatch-free via
 *  another) is what made the verb-shaped allowance read as a defect. */
function _syncAllowanceBlockReason(kind: string, baseline: any, eff: any, det: any, effect: any): string {
  const parsed = det?.syncEffect ?? null;
  const branch = baseline?.branch ? `"${baseline.branch}"` : "(no session baseline recorded)";
  const why: string[] = [];
  if (!baseline) {
    why.push("   No baseline was recorded for this checkout, so ownership of the");
    why.push("   branch cannot be established — the allowance fails closed.");
  } else if (eff?.currentBranch !== baseline.branch) {
    why.push(`   This checkout is on "${eff?.currentBranch ?? "HEAD"}", not this session's`);
    why.push(`   baseline ${branch} — the allowance only ever covers the session's OWN branch.`);
  } else if (parsed?.rebaseEffect === true) {
    why.push("   A rebase-integration REPLACES the baseline tip instead of advancing it —");
    why.push("   that is the same branch move as the `reset`/`clean` this gate refuses.");
  } else if (parsed?.ffOnly !== true) {
    why.push("   Only a PROVABLE fast-forward is admitted. This form may resolve to a");
    why.push("   rebase (git config pull.rebase / branch.<name>.rebase) or mint a merge");
    why.push("   commit on the shared branch, so it fails closed.");
  }
  if (parsed?.unverifiable === true) {
    why.push("   The flag cannot be PROVEN to be an option here: a `--` terminator makes");
    why.push("   it a path/ref name, an unresolvable expansion is resolved by the shell");
    why.push("   AFTER this check, and an option shape outside the known flag sets can");
    why.push("   silently swallow or free an ff token — either way the effective");
    why.push("   fast-forward flag is unknown.");
  }
  if (parsed?.leavesDirty === true) {
    why.push("   It also leaves staged/index state in the shared tree (--squash/--no-commit).");
  }
  if (effect && effect.onlyGitInvocation !== true) {
    why.push("   The command contains other git operations, so the fast-forward evidence");
    why.push("   cannot cover what else it may do to the branch. → Run the sync on its own.");
  }
  if (effect && effect.scopeOwnRepo !== true && effect.foreignHubFastForward !== true) {
    why.push("   It targets a DIFFERENT repository than the one this session's baseline was");
    why.push("   recorded in, and it is not a PROVEN fast-forward onto that checkout's own");
    why.push("   upstream — the form that needs no ownership (#2277).");
    if (effect.ffProofWhy) why.push(`   Measured: ${effect.ffProofWhy}.`);
    why.push("   → To advance a clean hub you do not own, run `git -C <hub> pull --ff-only`");
    why.push("     on its own, with no source ref, on its default branch, with the hub clean");
    why.push("     and strictly behind its upstream.");
  }
  if (effect && effect.treeClean !== true) {
    why.push("   This checkout has uncommitted changes — nothing may move the branch now.");
  }
  return [
    `⛔ ${kind} blocked in the shared MAIN checkout — the fast-forward-only allowance does not cover it (#1144).`,
    `   Branch: ${branch} (this session's baseline, in a checkout SHARED between agents).`,
    ...why,
    "   → Permitted without a hatch: `git pull --ff-only` / `git merge --ff-only`",
    "     (a fast-forward cannot move the tip backwards or rewrite a commit).",
    "   → Work in an isolated worktree: invoke the using-git-worktrees skill.",
    "   → Or stamp the ~/.pi/agent/.allow-main-edits marker (15-min TTL) —",
    "     reachable from an ALREADY-RUNNING session — or set",
    "     AGENT_ALLOW_MAIN_EDITS=1 (or ELDATO_ALLOW_MAIN_EDITS=1) for deliberate",
    "     solo sessions.",
  ].join("\n");
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

// ── #853: the startup SELF-TEST for a degraded classifier ────────────────
// `classifierLoaded === false` means the load `catch` above fired: every binding in this file is
// still its fail-safe stub, so the bash git guard passes EVERY command and the write/edit target
// gate takes its "isolated by construction" branch and ALLOWS writes into the main checkout
// (#761). Until #853 both consequences were reported by exactly one `console.warn` at load, which
// nothing reads — a NO-OP GATE that looks enforced. This is the same correction `review-enforcer`
// made for the absent `gh` argv shim (`gh_shim_degraded`, #984/#3297): name the consequence and
// the remedy, and RECORD a durable gate event so a report can read the state without anyone
// parsing prose.
//
// It changes no verdict. A notification on a path that has already decided to allow cannot
// introduce a block, which is why this does not touch the module's never-false-block contract —
// the fail-CLOSED question stays open on #761 and is deliberately NOT decided here.
function _reportClassifierDegradation(ctx?: { ui?: { notify?: (msg: string, level?: string) => void } }): void {
  if (classifierLoaded) return;
  const pid = process.pid;
  if (_classifierDegradedPids.has(pid)) return; // once per session process; /resume must not spam
  _classifierDegradedPids.add(pid);
  const reason = _classifierLoadFailure ?? "classify-git.mjs did not bind the expected exports";
  const row = (s: string) => `║  ${s.padEnd(64)}║`;
  const lines = [
    "",
    "╔══════════════════════════════════════════════════════════════════╗",
    row("🚫  MAIN-WORKTREE GUARD — DEGRADED (a STATE, not a warning)"),
    "╠══════════════════════════════════════════════════════════════════╣",
    row("classify-git.mjs FAILED TO LOAD, so every gate it backs is OFF:"),
    row("  · bash git mutations in a main checkout → ALLOWED"),
    row("  · write/edit in a main checkout → FAILS OPEN (#761)"),
    row("This is NOT a safe mode. Nothing else in this session will stop a"),
    row("destructive git command in the shared main checkout."),
    row("FIX: reinstall the extension tree (pi-bootstrap/setup.sh, or"),
    row("cell-install.sh on a cell), then verify with:"),
    row("  node extensions/main-worktree-guard/test-module-load.mjs"),
    row("Deliberate acceptance: AGENT_ALLOW_MAIN_EDITS=1 (solo sessions)."),
    "╚══════════════════════════════════════════════════════════════════╝",
    `   cause: ${reason}`,
    "",
  ];
  // ── ORDER MATTERS: the DURABLE row is written FIRST, and each surface has its OWN try. ──
  // #853 review (cycle 2, P3): with a single `try` around all three surfaces and the row LAST, a
  // `ui.notify` that THREW skipped the row entirely — and because the pid is marked above, the loss
  // was PERMANENT for the process: the one surface a report can read would never learn the session
  // ran unguarded, while the banner suggested it could. A presentation surface must never be able to
  // cost the machine-readable record. Each arm is isolated for the same reason.
  try {
    appendJsonl({
      event: "guard_degraded",
      extension: "main-worktree-guard",
      reason: "classifier_load_failed",
      error: reason,
      session_cwd: process.cwd(),
    });
  } catch {
    // appendJsonl is already fail-safe internally; this arm exists so the property is LOCAL and
    // provable here too — a report must never change a verdict, including by throwing.
  }
  try {
    console.warn(lines.join("\n"));
  } catch { /* a console that throws must not cost the notify arm below */ }
  try {
    // A warn line in a noisy startup log is exactly what nothing reads (#853). An INTERACTIVE
    // session also gets the SDK's error-level notification; a print-mode lane's own log carries
    // the banner above, so the surface is never absent — only one of the two applies.
    if (!isPrintMode()) {
      ctx?.ui?.notify?.(
        "[main-worktree-guard] 🚫 DEGRADED — classify-git.mjs failed to load: the bash git guard " +
        "and the main-checkout write gate are OFF for this session. See the session log for the " +
        "cause and the fix.",
        "error"
      );
    }
  } catch {
    // The banner and the durable row above have already been delivered.
  }
}

export default function (pi: ExtensionAPI) {
  // ── Session-start: record the branch-ownership baseline + hub check ──────
  pi.on("session_start", async (_event, ctx) => {
    const pid = process.pid;
    // #853: the guard's startup self-test. FIRST, before every early return below — a degraded
    // classifier is exactly the case where those checks are inert, so a degradation report that
    // sat behind the escape-hatch return would be silent on the sessions that need it most.
    _reportClassifierDegradation(ctx as { ui?: { notify?: (msg: string, level?: string) => void } });
    // #628 reviewer P3: the new-file volume counter is per-SESSION state — a
    // resumed/reused process must not inherit a prior session's count.
    hubNewFileCounts.clear();
    warnedNewFileTargets.clear();
    // #718: the working-tree baseline is per-SESSION too — a resumed session has
    // not observed anything yet, so it must not inherit a prior tree's paths.
    observedHubPaths.clear();
    warnedVanishedPaths.clear();
    lastHubSweepMs = 0;
    lastHubTreeSignature = null;
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
      // #718: SEED the observed working-tree baseline. A session that starts on a
      // dirty hub has observed those paths; their disappearance later is the
      // sweep signal. (Idempotent: _hubSweepCheck records and returns.)
      _hubSweepCheck();
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
    // Round 11 (P2): resolve the hatch ONCE per tool call, with the CTX session
    // id, before any gate or message runs. The write/edit, bash-write and
    // inline-payload messages used to derive it themselves from the env-only id —
    // empty in production (pi sets PI_SESSION_ID only in bash CHILDREN) — so the
    // hatch-active paragraph was unreachable on exactly the surfaces a stranded
    // lane hits.
    _currentHatchActive = _isAllowMainEdits() || readAllowMarkerState(_markerPath(), _currentSessionId(_ctx));

    // M1 runs on EVERY tool_call (read included — a reviewer whose tree moved
    // mid-review sees the warn before proceeding, AC8). Active under the
    // marker/flag AND in print mode (swarm-style detection, scenario 4).
    if (pendingBaseline.has(pid)) {
      pendingBaseline.delete(pid);
      _recordBaseline(pid); // BEFORE this tool_call's guard evaluation
    }
    _m1(pid);
    // #718: re-observe the hub's working tree on EVERY tool call (hub-rooted
    // sessions only; 1.5s burst throttle). The incident's defect was that the
    // working session learned about the loss an hour later, at its next failing
    // `edit` — so observation belongs here, not in a 6h-gated SessionStart job.
    _hubSweepCheck();

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
        // #3444 — REMOTE-EXEC BOUNDARY. `cmux vm exec <vm> -- …`, `ssh <host> …`
        // and `docker exec <c> …` run the remainder of the command on ANOTHER
        // box, which this guard cannot see and does not protect. Every gate in
        // this block resolves PATHS and HUB STATE against the LOCAL checkout, so
        // a remote payload must not be judged by them (measured 2026-11-04:
        // `cmux vm exec cell -- sh -c 'git worktree add <rel>'` was refused by
        // #1919 with the LOCAL path named, and a remote `git checkout`/`git pull`
        // by #1484/#1144 — ~87 idle lanes on four cells, unusable from the hub).
        // The mask removes ONLY the payload text; a trailing local segment, a
        // local redirection target and a locally-executed substitution all stay
        // visible, so the local guarantees are unchanged (see
        // classify-git.mjs maskRemoteExecPayloads).
        const localCommand = maskRemoteExecPayloads(command);
        // #347: execution-cwd-aware backdoor (script path + content gating
        // resolve against the command's cd-target, not the session cwd).
        const execCwd = commandExecutionCwd(localCommand, process.cwd()) ?? undefined;
        const backdoor = _backdoorBlock(localCommand, execCwd);
        if (backdoor) return { block: true, reason: backdoor };
        const nestedWt = _nestedWorktreeBlock(localCommand);
        if (nestedWt) return { block: true, reason: nestedWt };
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
        const bashWrite = _hubBashTrackedWrite(localCommand, st.disorder, markerOn);
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
          // Round 10 (P1): the recovery window applies to ONE BARE `git`
          // invocation run from the hub. A WRAPPER (`env -C<dir>`, `nice`, `sudo`,
          // `xargs`, `sh -c`) is not that shape: the parser only reports the
          // inner `git` invocation, so a wrapper's own target selection is
          // invisible to it, and `env -C"<other>" git checkout -- tracked.txt`
          // destroyed a foreign checkout's uncommitted work with M4 classifying
          // recovery and M5 never consulted. Wiring the hatch to the shape (not
          // just to the window) makes M4 refuse those forms exactly as main does.
          const escapeActive = (_isAllowMainEdits() || markerOn) && /^\s*git\s/.test(localCommand);
          const gate = evaluateHubGateWithTargets(localCommand, st.branch, resolve(process.cwd()), checkedOutNames, st, { escapeActive, hatchActive: _currentHatchActive });
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
            // #805: M4's recovery allowlist sanctions `git push
            // <checked-out-branch>` for WIP preservation. M4 cannot see the
            // SESSION's baseline — pushing whatever branch the SHARED hub
            // happens to be on is exactly the cross-session contamination
            // (#265) the branch-ownership gate exists to refuse. Never let
            // this early-return swallow a push: fall through to the
            // ownership/M2 path below (which allows the session's OWN branch
            // and blocks foreign ones, incl. bare/`HEAD`/remote-only pushes).
            const pushDet = classifyGitCommandDetailed(localCommand);
            const gateablePush = pushDet?.verdict === "block:push" ||
              pushDet?.verdict === "block:force-push" ||
              pushDet?.verdict === "block:push-delete";
            if (!gateablePush) {
              // #1060 — this early-return used to SHADOW M5. It returned before
              // the working-tree-discard arm ever evaluated, so on a disordered
              // hub a `cat-file-revert` whose write target is a shell variable
              // (`git show HEAD:"$x" > "$x"`) was ALLOWED — the redirect's
              // spelling defeats the tracked-write gate above (`_hubBashTrackedWrite`
              // matches resolved hub paths), M4 blocks the discard VERB family
              // but `git show` is read-only by classification, and nothing else
              // was left to decide. The hub's tracked dirt is exactly what that
              // command destroys, so the effect gate must still be consulted
              // before the arm calls the command done.
              // Round 15: the MESSAGE needs the hatch itself, not the shape-gated
              // `escapeActive` — passing the latter told a hatched lane (refused for
              // being compound/wrapped) to stamp the marker it already holds.
              const discardReason = _worktreeDiscardBlock(localCommand, _currentHatchActive);
              if (discardReason) return { block: true, reason: discardReason };
              // #608 (#3979 review P2): this arm is an ADMISSION, and it sits
              // ~200 lines BEFORE the M3 funnel — so it used to admit a LOCAL
              // branch delete with the claim left intact. It is not a theoretical
              // path: with the hub disordered, `evaluateHubGateWithTargets` routes
              // `git branch -D <b>` through the #436 (B) carve-out
              // (classify-git.mjs branchDeleteNames + branchDeleteAllowance +
              // sawRecovery) and answers "allowed". Spend here for the same
              // reason the funnel does: every arm that ADMITS a local delete has
              // to spend it, or the stale claim re-authorizes a #598 own-dst
              // rename / #543 `-D` over a sibling's re-created branch. `pushDet`
              // is the same classification this arm already pays for.
              let m4RepoKey: string | null = null;
              try { m4RepoKey = branchOwnership?.repoKey?.(resolve(process.cwd())) ?? null; } catch { m4RepoKey = null; }
              _spendLocalDeleteClaims(pid, m4RepoKey, resolve(process.cwd()), _localDeleteClaimNames(pushDet));
              return undefined; // sanctioned recovery / read-only / non-push — done
            }
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
        const ctxLine = _m4CheckoutLine(st);
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
                    ...(ctxLine ? [ctxLine] : []),
                    `   This session has created ${newFileCount - 1} new files directly in the`,
                    `   shared main checkout while it is OFF-MAIN or DIRTY (cap ${HUB_NEW_FILE_BLOCK_CAP}).`,
                    `   New files are additive (they cannot collide with a sibling's uncommitted`,
                    `   work) but unbounded accumulation is the #347 amplifier, and the hub's`,
                    `   only legal state is main+clean.`,
                    ..._hubWriteRecoverLines(st),
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
                ...(ctxLine ? [ctxLine] : []),
                `   The hub's only legal states are main+clean. Non-recovery edits are`,
                `   blocked even under the TTL marker (D3).`,
                ..._hubWriteRecoverLines(st),
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
      // #3444 — the SAME remote-exec mask the M4 block above uses. This block
      // feeds M5 (the effect-keyed discard gate), the degradation classifier and
      // the full M3/M2/ownership/#1144 decision from ONE string, so masking here
      // is what stops a REMOTE `git pull`/`git checkout`/`git reset` being judged
      // by the LOCAL tree state (measured: #1144 refused a remote pull inside a
      // compound because the local hub had no baseline and the local tree was
      // dirty). The tail AFTER the remote command stays verbatim and gated.
      const localCommand = maskRemoteExecPayloads(command);
      // ── M5 (#709): effect-keyed working-tree-discard gate ──
      // Runs BEFORE the degradation/full classifier arms and BEFORE the
      // worktree exemptions below, so a discard is caught whether or not
      // branch-ownership loaded, and in a linked worktree as well as the hub.
      // It sits AFTER the env/marker hatch return above, so both hatches
      // bypass it unchanged.
      const discardBlock = _worktreeDiscardBlock(localCommand, false);
      if (discardBlock) return { block: true, reason: discardBlock };
      // #350: hub-WIP discipline prompts (never block) — bash-write detection
      // (heredoc/tee/python into the hub) + the throttled periodic hub-hygiene
      // scan (once per 5 min — never per-command).
      _maybeWarnBashWrite(localCommand);
      _periodicHubHygieneCheck();

      // ── Degradation fallback (branch-ownership OR detailed classifier
      // unavailable): string-verdict destructive blocks for main, marker
      // bypass. No repo exemption — agent-infra degrades identically (#615). ──
      if (!branchOwnership || !classifierLoaded) {
        if (_isAllowMainEdits()) return undefined;
        const verdict = classifyGitCommand(localCommand);
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
        const rawDeleteNames = extractPushDeleteBranch(localCommand) ?? [];
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
      const det = classifyGitCommandDetailed(localCommand);
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
        eff = branchOwnership.resolveEffectiveRepo(localCommand, process.cwd(), det.verb, 0);
      }
      const allowActive = _isAllowMainEdits();

      // #1144 (cycle-3 reviewer F3): a branch-state op's re-baseline is an
      // EFFECT of the command RUNNING, so it may only be APPLIED when the
      // command is actually admitted. Pre-fix, `_rebaseline` ran as soon as
      // `decideM3` sanctioned the carve-out — before the later gates had
      // decided — so a REFUSED compound (`git checkout main && git reset
      // --hard origin/main`, `… && git rebase origin/main`) still moved
      // `baselines[pid].branch` to the branch the refused checkout never
      // selected. Every later M1/M2/M3 decision keys on that field, so the
      // guard's own state named a branch the session is not on (a
      // stale-baseline false block, and a misleading `baseline "x" → current
      // …` M1 warning). The pending closure is applied exactly once, at the
      // admission returns below — the carve-out's own early return, or any
      // later gate that allows.
      let pendingRebaselines: Array<() => void> = [];
      // ── #607: an UNENUMERABLE branch-state mutation is a refusal ──
      // `det.hiddenStateMutation` (classify-git) is true exactly when a shell
      // substitution / backtick / `eval` / ANSI-C / process-substitution /
      // git-alias payload CARRIES A MUTATING BRANCH-STATE git invocation
      // (`_hasHiddenStateSubst`'s hardened collector — the branch-state half of
      // `hiddenStateSubst`, without that flag's broader unverifiable-git union).
      // The extractor cannot enumerate such a payload, so the M3 loop below gates
      // only the VISIBLE mutations: MEASURED at 6f508fc30 through the real handler
      // on a real hub — `echo "$(git branch -Mq main victim)"` ALLOWED (victim's
      // tip clobbered, rc 0), and every hidden-payload spelling after an M3-
      // SANCTIONED lead (`git branch -M main freeL ; echo "$(git branch -Mq freeL
      // victim)"`, the backtick twin, `eval '…'`) ALSO allowed — the sanctioned
      // lead changes nothing about the payload being unenumerable (#596's
      // hiddenStateSubst bound reaches only the #591 benign-force carve-out).
      // A branch-state mutation the guard cannot attribute to a repo/target must
      // never be admitted (#805: a gate that cannot determine the target REFUSES).
      //
      // WHY THIS IS LAST-RESORT, NOT FIRST: every other arm's refusal is MORE
      // specific (the sync arm names the permitted fast-forward forms, the legacy
      // arm names the destructive verb), and those arms doubling as the pin for
      // their own mechanism is why B9p/B9p3 assert their `#1144` marker. Folding
      // this into `admitAfterM3()` — the ONE funnel every admission passes through
      // — keeps each of them ahead of it while still closing the hole on commands
      // NOTHING else refuses (the measured ones above).
      //
      // SCOPE — NOT a blanket substitution block: a substitution carrying a
      // READ-ONLY git call (`$(git branch --show-current)`, `$(git rev-parse
      // HEAD)`, `$(git status --porcelain)`) does not set the flag, because
      // `_hasHiddenStateSubst`'s `mutates()` requires a MUTATING branch-state verb.
      //
      // ⛔ NO WORKTREE EXEMPTION, DELIBERATELY — and this is the SECOND attempt at
      // it. The first one exempted a session whose cwd resolved to a worktree, on
      // the premise "the payload runs at the shell cwd". That premise is FALSE: a
      // payload carries its OWN repo hints (`-C`/`--git-dir`/`--work-tree`/`cd`/
      // `GIT_DIR=`), so from a lane worktree
      // `echo "$(git -C <hub> branch -Mq main victim)"` executed rc 0 and clobbered
      // the hub's `victim` tip (MEASURED). The second attempt attributed the
      // payload's SPANS instead — and a fresh-context reviewer measured THAT open
      // too: `hiddenStateMutation` fires from arms that produce NO span
      // (`__unverifiable__` / `eval $VAR`, `$(<file)`, `-c alias.x=…`,
      // `GIT_CONFIG_PARAMETERS`), so ONE benign substitution anywhere in the
      // command paid for an exemption of an unattributable payload
      // (`echo "$(git rev-parse HEAD)"; eval $PAYLOAD` → ADMITTED from a worktree).
      // A gate whose exemption can be bought by unrelated text is not a gate, so
      // the exemption is GONE: an unenumerable branch-state mutation is refused in
      // every session the classifier is LOADED in — with one pre-existing exception
      // this gate does not close: the `!branchOwnership || !classifierLoaded`
      // degradation fallback below decides on the frozen legacy classifier, where the
      // flag does not exist at all (loudly reported; Part C pins the noise). The
      // remedy is the one that actually works — run the command DIRECTLY (in a
      // worktree that is then exempt as a visible mutation).
      //
      // PROCESS SUBSTITUTION: what actually fires, MEASURED (a review finding
      // claimed a read-only `<(git log …)` idiom is refused here — it is NOT).
      // `hiddenStateMutation` is false for `git diff --stat <(git log --oneline -1)`
      // and true for `git diff --stat <(git branch -Mq a b)`: the PRECISE predicate
      // judges a git-led body by its ARGUMENTS, so a read-only list resolves to a
      // non-mutating invocation and the flag stays false. ⛔ Do NOT credit the
      // conservative `isProcSubst && /\bgit\b/` arm (`_hasHiddenStateSubst`) here —
      // that flag is not the deciding path for this refusal — and note that both
      // predicates' `seen` caches are keyed on (CONTEXT, text) precisely because a
      // text-only key made the verdict depend on segment ORDER (measured: inert-first
      // admitted, exec-first refused, same two halves). Rows pin both halves, plus the
      // `)`-in-quotes and nested-`$(…)` spellings.
      const hiddenBranchStateRefusal = (): { block: true; reason: string } | null => {
        if (!det || det.hiddenStateMutation !== true) return null;
        return {
          block: true,
          reason: [
            "⛔ Branch-state command blocked (#607).",
            "   Why: the command hides a branch-state git invocation inside a shell",
            "   substitution / backticks / eval / alias / process-substitution payload.",
            "   The guard cannot see which ref it moves — and a payload can name its OWN",
            "   repo (-C / --git-dir / cd), so even a worktree session cannot rule out",
            "   that it clobbers or switches a branch in a SHARED main checkout (#265).",
            "   → Run the branch-state git command DIRECTLY (outside $(…), backticks,",
            "     eval and aliases). Direct branch-state commands in an isolated",
            "     worktree are exempt as before (using-git-worktrees skill).",
            "   Hatch, if this is deliberate solo work in the hub:",
            "     AGENT_ALLOW_MAIN_EDITS=1 or ~/.pi/agent/.allow-main-edits (#1239).",
          ].join("\n"),
        };
      };
      // #608: the ownership claims this command DESTROYS, spent at the ONE funnel
      // every admitted arm returns through (#3979 review P1b: the push-delete and
      // push/commit arms admitted a co-spelled `git branch -D` without spending,
      // and a compound naming two local deletes spent only the first). Derived
      // from EVERY mutating invocation, so an arm added later cannot skip it.
      const localDeleteClaims = _localDeleteClaimNames(det);
      const admitAfterM3 = (): undefined | { block: true; reason: string } => {
        // #607 refusal FIRST: a refused command must move nothing — neither the
        // session baseline (#1144 F3) nor the ownership claims spent below.
        const hiddenRefusal = hiddenBranchStateRefusal();
        if (hiddenRefusal) return hiddenRefusal;
        _spendLocalDeleteClaims(pid, eff?.repoKey ?? null, eff?.effectiveCwd ?? null, localDeleteClaims);
        // #607: apply the recorded re-baselines IN COMMAND ORDER — mid-command
        // propagation lets one compound carry more than one sanctioned move, and
        // overwriting a single slot dropped the earlier rename's `_markOwned`.
        const applies = pendingRebaselines;
        pendingRebaselines = [];
        for (const apply of applies) apply();
        return undefined;
      };

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
        // ── #607: MID-COMMAND BASELINE PROPAGATION ──
        // Each mutation used to be decided against the SESSION baseline — the
        // branch the session was on BEFORE the command ran — so a sanctioned
        // lead that MOVES the baseline (own-baseline rename, #376 return) left
        // every later segment judged against a branch the command itself had
        // already moved off. MEASURED at 6f508fc30 (real handler, real git):
        // `git branch -M main tmpA && git branch -M tmpA main` and `… && git
        // branch -M tmpA done` were BLOCKED — the legitimate two-segment rename
        // ceremony — because segment 2's source (`tmpA`) is not the session
        // baseline (`main`). The LAUNDER the pre-#1144 short-circuit allowed is
        // NOT re-opened by judging against the propagated baseline: the #1144
        // `stateCarveOutClean` closure is what refuses a mutating tail, and each
        // later segment still runs its OWN decideM3 (a foreign source or an
        // existing foreign rename DST still blocks).
        // Two pieces of prospective state, both REPO-KEYED (a mutation in another
        // checkout must never inherit this repo's prospective branch — decideM3's
        // rename arm is repoKey-scoped, and so is this):
        //   previewBranch — the branch this compound will be ON when the segment runs.
        //   freedNames    — names an EARLIER sanctioned rename of this compound
        //                   renames AWAY from, so the #598 dst probe must not read
        //                   them as "an existing foreign ref" (they are gone by the
        //                   time the segment runs). Only ever OWN lineage: a name is
        //                   added only as the `from` of a rename decideM3 already
        //                   sanctioned, i.e. the branch the session was on.
        const previewBranch = new Map<string, string>();
        const freedNames = new Map<string, Set<string>>();
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
          // #805: an UNRESOLVED target (bare cd / unexpandable $VAR / `-C`
          // sentinel) must never be worktree-exempted — the command may run in
          // the shared hub. Same fail-closed rule as M2.
          if (muEff.unresolvedTarget) {
            return {
              block: true,
              reason: "⛔ Branch-state command blocked — the command's target repository is unresolved (fail-closed; #805).",
            };
          }
          if (muEff.isWorktree) continue; // THIS mutation is wt-scoped — exempt
          const muRepoKey = muEff.repoKey ?? "";
          const sessionBaseline = baselines.get(pid);
          // #607: judge this segment against the baseline the compound will
          // have reached here, when an earlier segment of the SAME repo moved it.
          const prospective = previewBranch.get(muRepoKey);
          const baseline = (sessionBaseline && prospective != null
            && sessionBaseline.repoKey === muEff.repoKey)
            ? { ...sessionBaseline, branch: prospective }
            : sessionBaseline;
          const isInfra = isAgentInfraRepo(muEff.effectiveCwd);
          // #598: a forced rename of the session's own baseline onto an
          // EXISTING branch this session does not own clobbers that foreign
          // ref rc 0 — probe whether the rename DST already exists in the
          // repo git will write (tri-state: a failed probe is treated as
          // exists → block — fail-closed). gitDir-anchored so a
          // `--git-dir=<other>` mutation is never checked against the cwd
          // repo's refs. Only the decideM3 rename arm consumes it (the
          // force/create/switch arms key on branch/currentBranch alone).
          // #607: a name an EARLIER segment of this same compound renames away
          // from will not exist when this segment runs (the probe reads the repo
          // BEFORE the command executes), so a sanctioned rename-back
          // (`… && git branch -M tmp main`) was refused as a foreign clobber.
          const dstExists = (branchOp.op === "rename" && branchOp.to != null)
            ? (branchOwnership.localBranchExists(muEff.effectiveCwd, branchOp.to, muEff.gitDir) !== false)
              && !(freedNames.get(muRepoKey)?.has(branchOp.to) ?? false)
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
            // The re-baseline records the branch this sanctioned state op moves
            // the session to — the own-baseline RENAME (create-new never
            // re-baselines since #626 — in-hub create-new is blocked) adopts
            // the new branch NOW — the next tool_call emits ZERO M1 warns
            // (AC3) — and the renamed-to branch is recorded scoped to the
            // BASELINE repo, so its post-ceremony LOCAL delete is still allowed
            // after the #376 return re-baselines to the original (#376 review
            // fold-in). Both are applied only on ADMISSION (see below).
            const reBaseline = m3.reBaseline;
            // #1144 (cycle-3 reviewer F3): the re-baseline and the rename's
            // owned-branch record are consequences of the command RUNNING, so
            // they are applied only when a gate actually admits the command —
            // never here, where the later gates have not decided yet.
            const applyRebaseline = () => {
              if (branchOp.op === "rename" && branchOp.to) {
                if (!baseline || (muEff.repoKey != null && baseline.repoKey === muEff.repoKey)) {
                  const ownedKey = baseline?.repoKey ?? muEff.repoKey;
                  _markOwned(pid, ownedKey, branchOp.to);
                  // #608: the renamed-AWAY name leaves this pid's control — git
                  // moves the ref, so the old name is free for anyone. Keeping
                  // it in the owned set is a STALE authorization: a sibling that
                  // recreates the freed name would be clobbered by this pid's
                  // next `git branch -M <baseline> <that name>` (the #598
                  // own-dst allowance) or by its `git branch -D` (#543/#376).
                  // The old name is `branchOp.from`; for the 1-pos
                  // `branch -M <new>` form (from null) it is the checkout's
                  // current branch — the same substitution decideM3 makes.
                  _unmarkOwned(pid, ownedKey, branchOp.from ?? muEff.currentBranch);
                }
              }
              _rebaseline(pid, reBaseline);
            };
            // #1144 (reviewer P1): the carve-out may only close the WHOLE
            // command when every other git invocation is read-only. Pre-fix
            // this `return undefined` laundered a destructive LATER segment in
            // an agent-infra hub — `git checkout main && git reset --hard
            // origin/main` (and `… && git rebase origin/main`) ran with the
            // sanctioned return's blessing. Otherwise fall through to the
            // remaining gates, which see the command's real verdict.
            // #1144 (cycle-3 reviewer P0): `stateCarveOutClean` is a claim about
            // the WHOLE command's invocation list, so the classifier folds
            // `hiddenStateSubst` into it — a hidden shell payload (`eval "git
            // reset --hard …"`, `$(…)`, backticks) contributes no invocation and
            // would otherwise leave the list looking clean. The flag is consulted
            // at classification time, the same way `syncOnlyInvocation` and
            // `_allInvocationsWorktreeScoped` consult it.
            if (det.stateCarveOutClean === true) {
              // #607: through the funnel (admitAfterM3), so the order-preserving
              // apply and the hidden-branch-state gate both run on this path too;
              // `stateCarveOutClean` folds `hiddenStateSubst`, so it cannot
              // contradict that gate.
              pendingRebaselines.push(applyRebaseline);
              return admitAfterM3();
            }
            // Not closed by the carve-out — the later gates decide. Defer the
            // re-baseline until one of them admits: a REFUSED command must not
            // move the baseline every later M1/M2/M3 decision keys on (#1144
            // F3). `admitAfterM3()` applies it at each admission return.
            // #607: record the PROSPECTIVE baseline + the name this segment frees
            // for the segments AFTER it. Nothing is applied to session state here
            // — a refused compound must leave `baselines[pid]` untouched.
            previewBranch.set(muRepoKey, reBaseline);
            if (branchOp.op === "rename") {
              const from = branchOp.from ?? muEff.currentBranch;
              if (from) {
                const freed = freedNames.get(muRepoKey) ?? new Set<string>();
                freed.add(from);
                freedNames.set(muRepoKey, freed);
              }
            }
            pendingRebaselines.push(applyRebaseline);
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

      if (!det || det.verdict === "allow" || det.verdict === "allow-non-git") return admitAfterM3();

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
      // ── M2 mutation list (#605) — built BEFORE the ownership-allowance arm and
      // the push-delete arm, because BOTH used to close the whole command on one
      // segment's evidence and return (reviews F1, I1).
      // #596 round-4 (reviewer P1 follow-up): the commit/push repo ALWAYS comes
      // from the classifier's boundary-aware invocation hints (a
      // block:commit/block:push verdict implies the invocation exists;
      // hint-less commits resolve at the session cwd). The extractor replay
      // phantom-counted script-file attempts (`bash git -C <wt> commit -m z` —
      // consumed by the classifier as interpreter+path) and the no-stateVerb
      // path (eff = replay of det.verb) wrongly worktree-exempted the REAL main
      // commit.
      //
      // #605: and the hints must be those of EVERY commit/push invocation, not
      // only the FIRST extractor-visible one. `commitHints`/`pushHints` describe
      // the first visible invocation, so a fully-VISIBLE worktree-scoped LEAD
      // resolved the whole command to its worktree → decideM2 returned null →
      // the later OFF-baseline MAIN commit/push ran rc 0 (`git -C <wt> commit
      // -m z ; git commit -m x`, and the push twin; the reversed order blocks).
      // Each mutation now resolves its OWN repo (and a push its OWN refspecs),
      // and every main-resolving one is gated — block wins — exactly as the
      // round-4 M3 stateMutations loop does for branch-state mutations.
      const m2Mutations: any[] = [];
      // ⛔ ONLY INVOCATIONS THE COMMAND ACTUALLY CONTAINS (review round-5 F1).
      // This list used to SYNTHESIZE a mutation from `det.commitHints`/
      // `det.pushHints` when the classifier saw none — a fallback with no
      // referent: a `block:commit`/`block:push` verdict is only ever set because
      // an invocation exists (`classify-git.mjs` sets it from `commitInv`/
      // `pushInv`), and a degraded classifier returns `verdict: "allow"` and
      // leaves this path entirely. Its only effect was on the arms that gate
      // WITHOUT such a verdict: a `git pull --ff-only` (verdict block:pull, no
      // push invocation at all) got a PHANTOM push whose null hints resolved at
      // the session cwd, so a lane rooted outside any git repo — #2277's own
      // recovery shape — was refused with "⛔ git commit/push blocked — could not
      // verify repo ownership" on a command containing no commit and no push
      // (MEASURED). Gating must judge the compound's real invocations, exactly as
      // the comparator's per-subcommand model does.
      m2Mutations.push(...(det.commitMutations ?? []), ...(det.pushMutations ?? []));
      // ⛔ …BUT AN EMPTY LIST UNDER A PUSH VERDICT IS AN UNRESOLVABLE TARGET, NOT
      // "nothing to gate" (review round-6 F1). `block:force-push` and
      // `block:push-delete` are ALSO set by the raw-text pass in the classifier's
      // ZERO-INVOCATION early return (`classify-git.mjs:3932-3945`), which returns
      // BEFORE `commitMutations`/`pushMutations` are populated — so
      // `eval "cd <hub> && git push -f origin feat/other"` carries the verdict with
      // an EMPTY mutation list. MEASURED: every VISIBLE invocation yields ≥1
      // mutation (`git push -f`, `git push -f --all`, `git push --force --mirror`,
      // `git push --delete`, `git push origin -d stale` → 1 each), so an empty list
      // under these two verdicts is exactly "a push the tokenizer could not expand".
      //
      // Without this arm `gateMutations([])` returns undefined and the M2 arm admits:
      // MEASURED regression — a #2277 lane (rooted OUTSIDE any git repo) went
      // BLOCK → ALLOW on the very force-push it could not see, while
      // `block:commit`/`block:push` in the SAME arm line kept their gate. #805 is
      // the decision: a gate that cannot determine the target REFUSES, never
      // exempts. This restores the refusal the null resolution carried on main
      // (`main:index.ts:6323`); it does not extend it — a session whose cwd DOES
      // resolve keeps main's behaviour (one synthesized push, gated against the
      // session repo), so no new false block is introduced.
      //
      // S8 stays green: `git pull --ff-only` is `block:pull`, which implies no push
      // and is NOT in this set, so round 5's phantom-mutation removal stands.
      if (m2Mutations.length === 0 &&
          (det.verdict === "block:force-push" || det.verdict === "block:push-delete")) {
        if (!branchOwnership.resolveEffectiveRepo("git status", process.cwd())) {
          return {
            block: true,
            reason: "⛔ git commit/push blocked — could not verify repo ownership (git read failed; fail-closed, #265).",
          };
        }
      }
      // #805/#605: gate ONE commit/push mutation. Returns the refusal, or
      // undefined when this mutation is exempt/on-baseline.
      const gateOneMutation = (mu: any): { block: true; reason: string } | undefined => {
        // Resolve THIS mutation's repo: the classifier's own boundary-aware
        // hints (visible spellings); an extractor-invisible spelling
        // (interpreter-inline payload) executes at the shell cwd → session
        // repo (#596 round-4 F2 policy).
        let m2Eff = mu.hints
          ? branchOwnership.resolveRepoFromInv(mu.hints, process.cwd())
          : (mu.invVisible === false
            ? branchOwnership.resolveEffectiveRepo("git status", process.cwd())
            : null);
        // #596 round-4 (F2): a null read means the hints-based resolution failed
        // (git read error, or the invocation was extractor-invisible — an
        // interpreter-inline payload is ONE opaque token to the repo layer). The
        // payload executes at the shell cwd, so resolve at the SESSION cwd.
        // Fail-closed is preserved — session-cwd gates apply, never a silent
        // pass; an OFF-baseline session still blocks, while the round-4
        // regression (blocking an ON-baseline invisible commit that
        // pre-round-3 allowed) stays undone.
        if (!m2Eff) {
          m2Eff = branchOwnership.resolveEffectiveRepo("git status", process.cwd());
        }
        if (!m2Eff) {
          return {
            block: true,
            reason: "⛔ git commit/push blocked — could not verify repo ownership (git read failed; fail-closed, #265).",
          };
        }
        // THIS mutation is worktree-scoped — exempt it, and keep gating the rest
        // (`git -C <wt> commit ; git commit` must not blanket-exempt).
        // #805: an UNRESOLVED target (bare cd / unexpandable $VAR / `-C`
        // sentinel) is never worktree-exempt — the resolution may REPORT the
        // session worktree while the real target is the shared hub, so the
        // exemption must not short-circuit decideM2's fail-closed refusal
        // (reordering this ahead of the unresolvedTarget arm let
        // `cd $AGENT_INFRA_PATH && git commit` through in the #805 fixture).
        if (m2Eff.isWorktree && !m2Eff.unresolvedTarget) return undefined;
        const baseline = baselines.get(pid);
        // A mutation's own verb decides which decideM2 arm applies; a push keeps
        // the compound's force classification (force and plain push share one
        // decideM2 arm — the distinction is advisory).
        const muVerdict = mu.verb === "commit"
          ? "block:commit"
          : (det.verdict === "block:force-push" ? "block:force-push" : "block:push");
        // #805 P1: with NO baseline, decideM2 must know whether the resolved MAIN
        // checkout is THIS session's own (a worktree shares its common dir, so
        // `repoKey` equality identifies it) or the agent-infra hub — only those
        // two are refused; a different repo's MAIN checkout is ordinary
        // cross-repo work and stays allowed. Both probes spawn git, so they run
        // only in the (rare, anomalous) no-baseline case.
        const m2 = branchOwnership.decideM2({
          effectiveRepo: m2Eff, baseline, currentBranch: m2Eff.currentBranch,
          // #605: a push is gated against ITS OWN refspecs, never the first
          // push's — attributing the lead's targets to a later MAIN push blocks
          // or (when the lead named the session's baseline branch) ALLOWS the
          // wrong push.
          pushDst: mu.verb === "push" ? (mu.dst ?? null) : det.pushDst,
          pushTargets: mu.verb === "push"
            ? (Array.isArray(mu.targets) ? mu.targets : det.pushTargets)
            : det.pushTargets,
          verdict: muVerdict, allowActive: false,
          ...(baseline ? {} : {
            sessionRepoKey: branchOwnership.repoKey(process.cwd()) ?? null,
            effectiveIsAgentInfra: isAgentInfraRepo(m2Eff.effectiveCwd),
          }),
        });
        return m2?.block ? { block: true, reason: m2.reason } : undefined;
      };
      const gateMutations = (mutations: any[]): { block: true; reason: string } | undefined => {
        for (const mu of mutations) {
          // #605 (review I2): a DELETE-spelled push is the #73 coordinated-delete
          // arm's business, never M2's target comparison — pushing it at M2 would
          // refuse ordinary remote-branch cleanup. The rule keys on the MUTATION's
          // own field, not on the compound's verdict: keyed on the verdict path it
          // held only when the delete was the FIRST push (verdict
          // block:push-delete), so `git push origin main && git push origin -d
          // stale` (verdict block:push — a later-segment `-d` carries no frozen
          // legacy evidence) was BLOCKED while the byte-identical `--delete`
          // spelling was allowed. One rule, applied to every mutation.
          if (mu.verb === "push" && mu.isDelete) continue;
          const hit = gateOneMutation(mu);
          if (hit) return hit;
        }
        return undefined;
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
        // #1144: sync ops are admitted on their EFFECT, never their verb. The
        // record is built from the classifier's parsed effect of THIS
        // invocation plus the LIVE checkout preconditions OF THE SYNC OP'S OWN
        // REPO (syncEff — never the command-level `eff`, whose hints may come
        // from a different, worktree-scoped segment). A sync kind with no
        // record fails closed (see syncEffectAllowed).
        const isSyncKind = SYNC_ALLOWANCE_KINDS.has(allowanceKind);
        const syncEff = isSyncKind ? _syncEffectiveRepo(det) : null;
        const effect = isSyncKind ? _syncAllowanceEffect(syncEff, baseline, det) : undefined;
        if (branchOwnership.ownershipAllowed({
          opKind: allowanceKind,
          currentBranch: eff.currentBranch,
          baselineBranch: baseline?.branch ?? null,
          targets,
          syncSource: det.syncSource,
          effect,
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
          const wcDeletes = wholeCommandDeleteTargets(det.verdict, localCommand);
          const baselineBranch = baseline?.branch ?? null;
          // Unknown baseline (no way to tell own from foreign) → keep the
          // allowance's base decision exactly as before.
          const foreignDelete = baselineBranch !== null && wcDeletes.some((b) => b !== baselineBranch);
          if (!foreignDelete) {
            // #605 (review I1): `targets` above is `det.pushTargets` — the FIRST
            // push invocation's refspecs. So this allowance closed the WHOLE
            // compound on one segment's evidence, and the plain-MAIN twin of the
            // class this change fixes stayed open:
            //   `git push origin main ; git push origin feat/other`
            // (baseline main) — allowed on `main`, and the FOREIGN push ran. The
            // delete arm below had the same shape (F1). Gate every remaining
            // main-resolving mutation before admitting; delete-spelled pushes are
            // skipped inside gateMutations (their own arm decides them), so
            // ordinary remote-branch cleanup is unaffected.
            const hit = gateMutations(m2Mutations);
            if (hit) return hit;
            return admitAfterM3();
          }
          // foreign later-segment delete present → fall through to the #73 arms.
        } else if (isSyncKind && syncEff?.isWorktree !== true) {
          // #1144: the sync allowance DENIED. Fall to the legacy arm for the
          // verdict but with the effect-specific refusal. The exemption keys on
          // the SYNC OP'S OWN resolved repo (reviewer P0): a leading
          // `git -C <worktree> …` segment must not exempt a later sync op that
          // runs at the shell cwd (the shared hub). An unresolvable sync target
          // (`syncEff === null`) is refused — fail closed, never exempt.
          return {
            block: true,
            reason: _syncAllowanceBlockReason(allowanceKind, baseline, syncEff ?? eff, det, effect),
          };
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
      // #605 (review F1): the push-delete verdict is set from the WHOLE raw
      // command, so an UNRELATED `--delete` segment anywhere in a compound used
      // to reach an early return here and exempt EVERY other mutation in it —
      // `git -C <hub> push origin feat/other ; git push origin --delete stale`
      // and `git commit -m x ; git push origin --delete stale` both ran their MAIN
      // mutation ungated. The identical "a benign segment exempts a later MAIN
      // mutation" class this change closes, one level above the hints mechanism.
      // The delete-spelled pushes stay this arm's business (M2's target
      // comparison at them would refuse ordinary remote-branch cleanup), so the
      // arm gates the NON-delete mutations via gateMutations, which skips them by
      // each mutation's own `isDelete`.
      if (det.verdict === "block:push-delete") {
        // Two guards used to be one: `… && det.pushTargets.length > 0`. The
        // TARGET-COUNT half is the #73 check's precondition (with no refspec there
        // is nothing to look up), but the M2 leg must run on the VERDICT —
        // otherwise appending a no-op `git push --delete` (a git error: "--delete
        // doesn't make sense without any refs") exempted the whole command.
        // MEASURED before this split: `git push origin feat/other && git push
        // --delete` → ALLOW, while `git push origin feat/other` alone → BLOCK.
        //
        // #605 (review F3): and the #73 check must see EVERY delete invocation.
        // `det.pushTargets` is first-invocation-scoped, so
        // `git push origin --delete b && git push origin --delete
        // <sibling-held>` ran with the sibling-held target never checked —
        // MEASURED: ALLOW, while that delete ALONE → BLOCK (#73). Each
        // pushMutations entry carries its own targets, so the union is exact.
        const deleteTargets = [...new Set([
          ...(det.pushTargets ?? []),
          ...m2Mutations
            .filter((mu) => mu.verb === "push" && mu.isDelete)
            .flatMap((mu) => (Array.isArray(mu.targets) ? mu.targets : [])),
        ])];
        if (deleteTargets.length > 0) {
          const blocked = _coordinatedDeleteBlock(deleteTargets);
          if (blocked) return blocked;
        }
        const hit = gateMutations(m2Mutations);
        if (hit) return hit;
        return admitAfterM3(); // foreign deletes with no checked-out targets — allowed (today's behavior)
      }
      if (det.verdict === "block:push" || det.verdict === "block:force-push") {
        const laterDeletes = wholeCommandDeleteTargets(det.verdict, localCommand);
        if (laterDeletes.length > 0) {
          const blocked = _coordinatedDeleteBlock(laterDeletes);
          if (blocked) return blocked;
          // no sibling holds the target(s) → fall through to M2 below (the
          // first segment's push stays gated exactly as origin/main gated it).
        }
      }

      // ── M2: commit/push ownership (block off-baseline) ──
      // #596 (round-3 reviewer P2-2): M2 must gate the COMMIT/PUSH's own repo,
      // not the M3 state-invocation repo — a compound with an off-baseline MAIN
      // commit and a later `-C <wt>`-scoped branch mutation would otherwise
      // reuse the worktree-exempt eff and let the off-baseline commit through
      // (the pre-#596 single-eff conflation predates this PR for 2-segment
      // forms; the 3-segment benign-lead form flipped block→allow in round-2).
      // The mutation list and the per-mutation gate live ABOVE the delete arm
      // (#605 review F1), so a `--delete` anywhere in the command cannot exempt
      // the compound's other mutations either.
      if (det.verdict === "block:commit" || det.verdict === "block:push" || det.verdict === "block:force-push") {
        const hit = gateMutations(m2Mutations);
        if (hit) return hit;
        return admitAfterM3(); // on-baseline or unverifiable-but-exempt
      }

      // ── Legacy destructive blocks (main checkout only) ──
      const LEGACY_BLOCK = [
        "block:reset", "block:clean", "block:restore", "block:stash-pop",
        "block:checkout-discard-all", "block:force-checkout", "block:checkout-branch",
        "block:merge", "block:rebase", "block:pull", "block:branch-force-delete",
        "block:force-push",
      ];
      if (LEGACY_BLOCK.includes(det.verdict)) {
        // #1144 cycle-2 P0: the exemption must hold for EVERY git invocation in
        // the command, not just the one `eff` was resolved from — otherwise a
        // leading `git -C <worktree> …` segment launders a destructive segment
        // that actually runs at the shell cwd (`git -C <wt> status && git reset
        // --hard origin/main`). `undefined` (no per-invocation data) keeps the
        // previous single-invocation behaviour.
        if (eff && eff.isWorktree && _allInvocationsWorktreeScoped(det) !== false) return admitAfterM3();
        const kind = det.verdict.slice("block:".length);
        return {
          block: true,
          reason: [
            `⛔ Destructive git command blocked in the main checkout (${kind}).`,
            ...WHY.split("\n").slice(1),
          ].join("\n"),
        };
      }
      return admitAfterM3();
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
