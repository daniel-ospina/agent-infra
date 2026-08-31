# Issue #385 — Scope Phase 4 (SOLUTION-DIVERGE): parent-independent reaping of orphaned dispatched pi work

Status: SCOPING — Phase 4 diverge (NO winner chosen — this document diverges only)
Date: 2026-08-31
Level: project | Complexity: TBD (rated at converge)
Branch: (worktree 385-orphans on origin/main)

Predecessors: Phase 1–3 (problem-diverge, problem-converge, controller verification — mechanism and
facts below are controller-verified; this file carries Phase 4 only).

---

## Confirmed problem (controller-verified, reproduced verbatim)

> Every reaping path for dispatched pi work (task sub-agents, subagent-tool children, their MCP
> grandchildren) executes inside the parent pi's process and event loop; a SIGKILLed parent (Jetsam or
> any cause) voids all of them and surviving process trees reparent to PID 1 where they accumulate — so
> orphan cleanup must be made parent-independent: the orphan detects its own existence via
> process.ppid→1 and self-terminates by killing its own descendant tree (MCP grandchildren) before
> exit. A warn-first session-start sweep (dry-run default, --apply manual gate, argv-based
> classification) is the bridge for pre-existing orphans. Wedged-parent-while-alive is declared
> follow-up. Cross-repo impact: the extension set ships globally (tortoise, eldato inherit).

## Key verified facts (from controller research; spot-re-checked against this checkout)

- `process.ppid` updates to 1 after reparenting on macOS (live-verified); polling costs zero exec calls.
- `extensions/task-heartbeat.ts` is the child-side extension shipped in the global set; `default()`
  returns early unless `TASK_HEARTBEAT=1 && PI_MODE=print && TASK_HEARTBEAT_DISABLE!=1`. The tick
  interval lives there (`session_start`-scoped, unref'd).
- Subagent-extension children get `TASK_HEARTBEAT=1, PI_MODE=print, TASK_HEARTBEAT_DISABLE=1`
  (emitter inert — no nonce/parser); task-tool children get `TASK_HEARTBEAT=1` + per-dispatch nonce;
  swarm_daemon children get `PI_MODE=print` only. Interactive pi never sets PI_MODE and never passes -p.
- Sub-agents spawn **detached** (own pgid/session via setsid) with `stdio:["ignore","pipe","pipe"]`
  (both dispatchers) — stdin is ignored, so no stdin-EOF signal is available to the child. MCP servers
  are children of the sub-agent (inherit env + pgid; stderr inherited).
- Sub-agent argv: `pi -p …` or `node <pi-entry-script> -p …` (`getPiInvocation` in both dispatchers).
- All parent-side cleanup — `shared/process-sweep.ts` (settle-path pgid sweep, own-pgid REFUSED
  guard), `shared/tree-kill.ts` (`getChildPids`/`parsePidList`), the 6h hard-cap timer,
  mcp-client's `process.on("exit")` transport kill — dies with the parent. The mcp-client exit handler
  covers only *tracked stdio transports*; untracked forks (bash, nested tools) need a tree walk.
- Precedent: `scripts/scan-orphans.sh` (dry-run default, `--apply` manual gate, warn-only wiring in
  auto-sync `session_start`); `templates/launchd/*` + `scripts/install-launchd.sh` (idempotent
  installer, worktree-safe path resolution); `ci-main.yml` extension accumulator runs only 4 tsx
  suites **explicitly** — new suites must be appended; extension tests use injectable-hook patterns
  (`process-sweep.test.ts` injects killGroup/listGroup); bash tests are self-contained `scripts/*.test.sh`.

## Orphan classes scored below (the 9-class surface)

| # | Class | Parent-death signal available |
|---|-------|-------------------------------|
| 1 | task-tool sub-agent alive, parent SIGKILLed | child `ppid` → 1 |
| 2 | subagent-extension child alive, parent SIGKILLed | child `ppid` → 1 |
| 3 | swarm_daemon worker alive, daemon dies | child `ppid` → 1 (env PI_MODE=print only) |
| 4 | MCP grandchild of class 1 (child dead) | reparented; pgid survives; MCP stdin EOF |
| 5 | MCP grandchild of class 2 | same |
| 6 | MCP grandchild of class 3 | same |
| 7 | bash-fork grandchild (tool-spawned, pgid-inherited) | reparented; pgid survives |
| 8 | setsid-escaped grandchild (own session) | invisible to ppid walks AND parent pgid |
| 9 | pre-existing accumulated orphans (predate the fix; incl. interactive-pi MCP transports) | none — needs sweep bridge |

All three approaches share the **warn-first session-start sweep bridge** (mandated by the confirmed
problem for class 9): dry-run default, `--apply` manual gate, argv+ppid classification, warn-only
wiring in `auto-sync` `session_start` — the `scan-orphans.sh` precedent verbatim, applied to
*processes* instead of worktree records. The approaches diverge on the **primary mechanism** for
classes 1–8 (and future kills).

---

## Approach A — Child-side ppid watchdog, integrated into task-heartbeat.ts

**The existing child-side life-sign extension grows a self-termination arm** (the controller's
proposed mechanism, hosted in the file that already ships to every print-mode child).

**Architecture.** Split the single gate in `task-heartbeat.ts` into two independent gates:
- `taskHeartbeatActive(env)` — UNCHANGED (`TASK_HEARTBEAT=1 && PI_MODE=print && !DISABLE`) — the
  marker emitter. Zero behavior change; `TASK_HEARTBEAT_DISABLE=1` keeps meaning "no emitter".
- `orphanWatchdogActive(env)` — NEW: `PI_MODE === "print" && ORPHAN_WATCHDOG !== "0"` (new opt-out
  var, default on). The watchdog runs in **every** print-mode child regardless of DISABLE and of
  `TASK_HEARTBEAT` — covering task children (1), subagent children (2), and swarm children (3) from
  the env they already receive, with **zero spawn-site changes**.

Watchdog mechanics (module-load scope, NOT `session_start`-scoped — a child wedged before the session
starts must still self-terminate):
1. At load, capture `const originalPpid = process.ppid` and start an unref'd poll
   (`setInterval`, ~15s, zero exec per poll).
2. Orphan predicate: `process.ppid !== originalPpid || process.ppid === 1`. The `|| 1` arm covers
   the boot race (parent died before the extension loaded → load-time ppid is already 1 → a
   pure "changed" detector would never fire). The changed-ppid form is also Linux-subreaper-portable
   (adoption to a non-1 subreaper still counts as changed).
3. Confirm guard: two consecutive positive polls before acting (transient-reparent insurance).
4. Min-uptime guard (~60s): never self-terminate before the child has been alive a full minute.
5. Self-termination: `treeKill` the child's own descendant tree via the shared
   `getChildPids`/`treeKill` (children-first, so MCP grandchildren classes 4/5/6 and bash forks 7 die;
   the PPID walk works here because the child is alive — its children are only reparented when *it*
   dies), then `process.exit(137)` with a stderr log line (`[task-heartbeat] orphan_watchdog …`,
   EPIPE-guarded — the stderr pipe's parent is dead). The mcp-client `process.on("exit")` transport
   kill also runs on `process.exit` (exit handlers fire) as a second net for tracked transports.

**Files touched.**
- `extensions/task-heartbeat.ts` — gate split, watchdog arm, exported `orphanWatchdogActive`,
  `isOrphaned(ppid, originalPpid)`, injectable ppid getter + killTree hook (test seam).
- `extensions/task-heartbeat.orphan.test.ts` — NEW unit suite (injectable pattern).
- `scripts/sweep-orphans.sh` — NEW bridge sweep (see shared bridge spec below).
- `scripts/sweep-orphans.test.sh` — NEW bash suite (temp dir, real orphans).
- `extensions/auto-sync.ts` — warn-only wiring of the sweep at `session_start` (scan-orphans pattern).
- `.github/workflows/ci-main.yml` — append the new tsx suite to the extension accumulator
  (explicit — only 4 suites are wired today).

**Coverage.** 1–7 ✓ (watchdog + descendant kill); 8 ✗ residual (declared follow-up; sweep argv pass
may catch some); 9 ✓ (sweep bridge). Future kills: any new dispatcher that sets `PI_MODE=print` is
covered with no wiring.

**Reliability when wedged mid-tool-call.** Event-loop-alive wedges (async never-resolving awaits —
the common MCP-disconnect class) → the poll interval still fires → covered. Synchronously-blocked
children (execSync hang inside the child's own process) → timer starved → watchdog misses; the sweep
bridge is the backstop (external, event-loop-independent). Documented residual, not silent.

**Testability.** Unit: pure predicate tests (`isOrphaned` truth table incl. boot-race and
subreaper arms), gate-split tests (DISABLE no longer disables the watchdog — assert the semantic
shift explicitly), self-termination path with injected killTree + fake exit. The E14 drift guard
guards the marker FORMAT only — untouched. Bash: dry-run lists / `--apply` kills / guards (own pgid,
age cutoff) against real reparented orphans.

**Risk of killing live work.** `ppid` cannot change while the original parent is alive — the false
positive surface is near zero; double-confirm + min-uptime add margin. The one open item: swarm
worker *resume* semantics must be verified (see shared verification items — if the daemon expects
workers to survive its restart, the watchdog must exempt class 3).

**Effort.** S–M: one file's mechanics + gate split, one new unit suite, one sweep script + wiring.
Reuses the shipped extension file (no new manifest entry).

**Interaction with parent-side mechanisms.** No double-kill by construction: the watchdog fires only
when the parent is dead, and every parent-side reaper (settle-path pgid sweep, hard-cap, mcp-client
exit kill) runs only while the parent is alive — the two kill domains are mutually exclusive on
parent liveness. Parent-side retry semantics are unaffected (a dead parent never retries; #195
worktree-residue recovery unchanged). `killProcessGroup`'s ESRCH-swallow makes a concurrent
sweep-vs-watchdog race (the sweep killing a pgid the dying child already emptied) benign.

**Cross-repo blast radius.** Ships a behavior change in the globally-inherited task-heartbeat.ts:
subagent children that were fully inert under `TASK_HEARTBEAT_DISABLE=1` now run the watchdog (a
behavior change on tortoise/eldato farms) — the #285 comment block and the extension header must be
updated to state that DISABLE disables only the emitter. A watchdog bug = self-killed sub-agents on
every farm; the min-uptime + confirm guards and the `ORPHAN_WATCHDOG=0` valve are the mitigations.

**Best fit if** …the controller's prescribed mechanism (child-side self-termination) is accepted and
the team prefers one child-side extension owning the whole dispatch lifecycle, with a small-surface
change and minimal new-file inventory in the global extension set.

---

## Approach B — Standalone orphan-watchdog extension (own gate, zero spawn-site changes)

**A new, independent child-side extension** — same mechanism as A, but architecturally separated
from the heartbeat contract.

**Architecture.** New flat file `extensions/orphan-watchdog.ts` with its OWN gate family
(`ORPHAN_WATCHDOG` / `ORPHAN_WATCHDOG_DISABLE` / `ORPHAN_WATCHDOG_INTERVAL_MS` /
`ORPHAN_WATCHDOG_MIN_UPTIME_MS`), its own unref'd poll timer, and the same self-termination
sequence as A (capture load-time ppid → poll → double-confirm + min-uptime →
`treeKill` own descendants → `process.exit(137)`). Gate: `PI_MODE === "print" && ORPHAN_WATCHDOG !==
"0"` — satisfied by the env all three dispatchers already set (task, subagent, swarm), so **no
spawn-site edits anywhere**, including swarm_daemon (whose spawn site may live outside this repo).

The heartbeat extension is untouched: `TASK_HEARTBEAT_DISABLE=1` keeps meaning "inert extension",
the marker contract and its E14 drift guards stay exactly as shipped, and the #285 subagent semantics
don't drift. The two concerns are now orthogonal: heartbeat = parent-side silence detection; watchdog
= orphan self-termination.

**Files touched.**
- `extensions/orphan-watchdog.ts` — NEW (flat, self-contained, `import type` only, no runtime pi
  deps; reuses `shared/tree-kill.js`).
- `extensions/orphan-watchdog.test.ts` — NEW unit suite (injectable ppid / killTree / exit).
- `manifest.json` — add `orphan-watchdog.ts` to `extensions/` entries (setup.sh globs `extensions/*`,
  so it ships on next sync once listed).
- `scripts/sweep-orphans.sh`, `scripts/sweep-orphans.test.sh`, `extensions/auto-sync.ts`,
  `.github/workflows/ci-main.yml` — the shared bridge sweep + wiring + accumulator append (as A).

**Coverage.** Identical to A for classes 1–7 and 9, with one structural advantage: class 3 (swarm)
is covered by the same uniform gate with no gate-split semantics to reason about (A covers swarm only
because its watchdog gate happens to read PI_MODE alone — B makes that the whole design). 8 residual.

**Reliability when wedged mid-tool-call.** Same as A (event-loop-alive wedges covered; sync-blocked
wedges fall to the sweep backstop).

**Testability.** Cleaner than A: pure gate + pure predicate, no interaction with the heartbeat gate
matrix, no semantic-shift assertions needed. Sweep tests identical.

**Risk of killing live work.** Same near-zero false-positive surface (ppid-change is parent-death
truth); same swarm-resume verification item; separate opt-out valve from the heartbeat machinery.

**Effort.** M: a new extension file + manifest entry + unit suite, plus the shared sweep. Slightly
more total code than A (a second poll timer runs per child, second file in the global set) — but
each piece is simpler and independently testable.

**Interaction with parent-side mechanisms.** Same mutual-exclusion-on-parent-liveness property as A;
no interaction with heartbeat internals at all (A must take care not to disturb the tick timer's
unref/clear lifecycle — B has no such coupling).

**Cross-repo blast radius.** A new globally-shipped extension — same farm-wide inheritance as A, but
with the heartbeat contract fully quarantined: zero risk to the E14 marker surface, zero doc drift on
`TASK_HEARTBEAT_DISABLE`. The blast radius is a *new* capability added to every print-mode child
rather than a *changed* meaning of an existing one — easier to reason about, and trivially revertable
by removing the file entry.

**Best fit if** …separation of concerns is preferred, the `TASK_HEARTBEAT_DISABLE`/#285 semantics must
not shift, swarm coverage must be uniform without touching swarm_daemon's spawn site, and the team
accepts one more extension file in the global set.

---

## Approach C — Dispatch registry + external continuous sweeper (launchd agent; no child-side code)

**An out-of-process mechanism: a spawn-time pgid registry file the parent writes, diffed by an
external sweeper that runs continuously (launchd) and at session start.** This is the
architecture-veto approach: it satisfies the outcome (no accumulation) without the confirmed
problem's mandated child-side self-termination — a legitimate diverge to weigh in converge.

**Architecture.**
1. **Registry write (parent-side, at spawn):** in `builtin-tools/index.ts` `spawnSubAgent` and
   `extensions/subagent/index.ts`, immediately after spawn, append one JSONL line to
   `$HOME/.pi/agent/dispatch-registry.jsonl`: `{ts, dispatchId, childPid, childPgid, nonce}` (the
   pgid is the durable handle that survives reparenting — already captured at both sites today).
   On settle (after the existing `sweepProcessGroup` resolves), the parent prunes its line. The
   write is atomic (tmp+rename), failure-silent (a registry write error must never affect the
   dispatch), and the line's *staleness* — a parent killed before prune — IS the orphan signal.
2. **Sweeper `scripts/sweep-orphans.sh` (two passes):**
   - **Pass 1 — registry pass (`--registry`, the continuous mode):** for each line: childPid alive
     and `ppid==1` → orphan → `killProcessGroup(childPgid)`; childPid dead but pgid has live members
     → orphan MCP/bash descendants → `killProcessGroup(childPgid)`; childPid dead and pgid empty →
     prune (ghost detection, scan-orphans GHOST-RECORDS pattern). Subreaper-adoption agnostic: the
     pgid-liveness check needs no ppid at all.
   - **Pass 2 — argv bridge pass (always, the class-9 bridge):** `ps -axo pid=,ppid=,pgid=,args=`;
     classify `ppid==1` AND argv matching `pi -p` / `node <entry> -p` / `--print` AND age cutoff AND
     pgid != current session's pgid (own-pgid REFUSED guard reused from `sweepProcessGroup`) →
     `killProcessGroup(their pgid)` — one group kill reaps the whole orphan tree.
   - Dry-run default; `--apply` manual gate for both passes; `--auto-apply` only for pass 1 (see 3).
3. **Scheduling:** (i) session-start warn-only wiring in auto-sync (bridge, scan-orphans precedent);
   (ii) OPTIONAL continuous mode: `templates/launchd/com.eldato.dispatch-orphan-sweep.plist` running
   the script with `--apply --registry` every 15 min, installed via the existing idempotent
   `install-launchd.sh` (worktree-safe path resolution precedent) — machines opt in; CI/docker
   (no launchd) simply don't install it.

**Files touched.** `extensions/builtin-tools/index.ts` + `extensions/subagent/index.ts` (registry
write/prune — ~6 lines each); `extensions/shared/dispatch-registry.ts` (NEW shared helper:
append/prune/read, injectable path, malformed-line tolerance); `scripts/sweep-orphans.sh` (NEW);
`scripts/sweep-orphans.test.sh` (NEW); `templates/launchd/com.eldato.dispatch-orphan-sweep.plist`
(NEW); `extensions/auto-sync.ts` (warn-only wiring); `.github/workflows/ci-main.yml` (append suites).

**Coverage.** 1–7 ✓ (registry + pgid kill — precise, adoption-agnostic); 8 ~ (pass 2's argv match
catches setsid-escaped *pi* children; escaped non-pi MCP servers remain residual, declared
follow-up); 9 ✓ (pass 2 is literally the sweep-only bridge). Future kills: any dispatcher that
spawns `pi -p` is covered by pass 2 with zero wiring; registry precision for new dispatchers needs a
2-line write (a documented pattern, not code).

**Reliability when wedged mid-tool-call.** BEST of the three: the sweeper is external — it does not
depend on the orphan's event loop at all. A sync-blocked or fully hung orphan is reaped as soon as
the sweep runs (parent death is the only precondition). On a launchd-opted-in machine this is
bounded by the schedule (≤15 min); on session-start-only machines, by the next pi session.

**Testability.** Registry helper: tsx unit tests (injectable path; append/prune/read; crash-mid-line
tolerance). Sweep script: bash tests in a temp dir that create REAL orphans (spawn a detached child,
exit the parent → child reparents to PID 1) and assert classify / dry-run / `--apply` / guards (own
pgid, age cutoff, ghost prune, argv mismatch no-op). Plist render test follows the
`install-launchd.test.sh` pattern if the template ships.

**Risk of killing live work.** LOWEST: the sweep touches only registry-listed pgids whose parent
death is verified, plus argv-matched `ppid==1` processes outside the current session's group; dry-run
default; launchd auto-apply is opt-in per machine and pass 1 only (registry-anchored). The registry
write itself is the main new risk — it must be failure-silent so a broken registry can never break a
dispatch (the dispatch path must not await or depend on it).

**Effort.** L: two spawn-site writes + settle-prune, a shared registry helper, a two-pass sweep
script + bash tests, a launchd template + install wiring, auto-sync wiring, CI appends. Highest
surface, but each piece is small and the sweep/prune machinery is precedent-backed.

**Interaction with parent-side mechanisms.** The registry prune rides the existing settle path
(after `sweepProcessGroup` resolves) — no new kill path. Concurrent settle-sweep vs sweeper on the
same pgid is benign (`killProcessGroup` swallows ESRCH; verify-empty on an emptied group passes).
Retry semantics unchanged. The registry doubles as an audit trail feeding postmortem (#195-style
reconciliation) — a byproduct no child-side approach gives.

**Cross-repo blast radius.** Spawn-site registry writes ship globally (tortoise/eldato inherit —
must be zero-risk, silent-fail, no dispatch-path coupling); the launchd job is machine-opt-in; the
sweep script runs only where `AGENT_INFRA_PATH` is configured (auto-sync is already gated on it).
Note: if swarm_daemon's spawn site lives outside agent-infra (pi package), registry precision for
class 3 is a cross-repo touch — pass 2's argv classification still covers swarm workers
(`PI_MODE=print` children of a dead daemon reparent to 1 with `pi -p` argv).

**Best fit if** …the team vetoes code inside the child (distrust of in-child self-kill on every
farm), continuous cleanup matters (swarm-heavy machines), wedged-while-blocked orphans must be reaped
regardless of the orphan's event-loop state, or registry-based auditability is valued. Divergence
note for converge: C does NOT implement the confirmed problem's mandated self-termination mechanism
— it meets the outcome by external reaping instead; the mechanism decision must be revisited
explicitly in Phase 5.

---

## Comparison summary

| Dimension | A — watchdog in task-heartbeat.ts | B — standalone watchdog extension | C — registry + external sweeper |
|---|---|---|---|
| Mechanism locus | in-child (ppid poll) | in-child (ppid poll) | out-of-process (registry + pgid diff) |
| Class 1–7 coverage | ✓ (needs gate split for 2/3) | ✓ uniform (env gate) | ✓ (registry + argv pass) |
| Class 8 (setsid-escape) | residual | residual | residual (argv pass catches pi children) |
| Class 9 (pre-existing) | ✓ sweep bridge | ✓ sweep bridge | ✓ sweep bridge (pass 2) |
| Wedged mid-tool-call | event-loop-alive only | event-loop-alive only | regardless of orphan state |
| Kill-live-work risk | near-zero (ppid truth + guards) | near-zero (same) | lowest (external, guarded, dry-run) |
| Heartbeat/#285 semantics | shifted (DISABLE no longer full-inert) | untouched | untouched |
| Spawn-site changes | none | none | 2 sites (+1 cross-repo for swarm) |
| New global-ship surface | changed file | new file | changed 2 files + new shared helper |
| Test surface | unit + bash + accumulator append | unit + bash + accumulator append | unit + bash + plist render + accumulator append |
| Effort | S–M | M | L |
| Audit trail | no | no | yes (registry) |
| Continuous cleanup | no (session-gated) | no (session-gated) | yes (launchd opt-in) |

All three require: `scripts/sweep-orphans.sh` (dry-run default / `--apply` manual gate / argv+ppid
classification / own-pgid REFUSED / age cutoff), `scripts/sweep-orphans.test.sh`, warn-only
auto-sync wiring, and explicit ci-main.yml accumulator appends (the 4-suite only gotcha).

## Shared verification items (resolve before converge)

1. **swarm_daemon worker resume semantics** — does the daemon expect workers to survive its death?
   If yes, class 3 must be exempted in A/B (gate on an env the daemon sets) and in C (registry tag);
   if no (work is lost by daemon death anyway — the presumed case), class 3 is reaped like the rest.
2. **swarm_daemon spawn site location** — in-repo (builtin-tools) or pi package? Determines whether
   C's registry write for class 3 is in-repo or cross-repo.
3. **Linux subreaper adoption** — ppid may become a non-1 subreaper: A/B's *changed-ppid* predicate
   handles it; C's pgid-liveness handles it; pass 2's `ppid==1` classifier does NOT — document the
   Linux gap or extend pass 2 with `ps eww` env-marker matching (macOS/Linux).
4. **Boot race** — parent dies before the child's extension loads: load-time ppid is already 1; the
   `ppid === 1 || ppid !== original` predicate + min-uptime guard covers it in A/B (spec'd above).
5. **Wedged-parent-while-alive** — declared follow-up in the confirmed problem; out of scope in all
   three (no approach claims to reap a live parent's children).

## Deliverable note

This is Phase 4 (solution-diverge) only. No winner is selected here; Phase 5 (solution-converge)
must re-verify the mechanism decision (in-child self-termination per the confirmed problem vs C's
external reaping), the class-3 exemption question, and then rate complexity and write acceptance
criteria against the chosen approach.
