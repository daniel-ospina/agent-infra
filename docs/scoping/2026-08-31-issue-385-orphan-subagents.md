# Issue #385 — Scoping: parent-independent reaping of orphaned dispatched pi work

Status: SCOPED (double diamond verified)
Date: 2026-08-31
Level: task | Complexity: standard (Org Infra medium, Config low)
Branch: (worktree 385-orphans on origin/main)
Plan: `docs/plans/2026-08-31-issue-385-plan.md` · Diverge: `docs/plans/2026-08-31-issue-385-solution-diverge.md`

---

## Confirmed Problem (problem-verify clean, cycle 2)

> Every reaping path for dispatched pi work (task sub-agents, subagent-tool children, their MCP grandchildren) executes inside the parent pi's process **and** event loop; a SIGKILLed parent (Jetsam or any cause) voids all of them and surviving process trees reparent to PID 1 where they accumulate — so orphan cleanup must be made **parent-independent**: the orphan detects its own existence via `process.ppid → 1` (empirically verified on macOS 25.5.0) and self-terminates by killing its own descendant tree (MCP grandchildren) before exit. A warn-first session-start sweep (dry-run default, `--apply` manual gate) is the bridge for pre-existing orphans. Wedged-parent-while-alive and swarm_daemon workers are declared out of scope (follow-ups).

Confidence: 80 (both independent convergers). Falsification: ppid stability breaks / wedged-class spurious / leak self-limits / discriminator unreadable / causal chain disproven — none falsified.

## Verification Gates

| Gate | Cycles | Result |
|------|--------|--------|
| problem-verify (2 verifiers) | 2 | Cycle 1: 1 P1 (`ps eww` env falsified claim — controller re-tested: env IS visible on macOS 25.5.0, version-sensitive; fixed argv-first + env best-effort) + P2s. Cycle 2: NO P0/P1 (both) |
| solution-verify (2 verifiers) | 2 | Cycle 1: 1 P1 (class-9 overstatement) + 13 P2/P3/P4 (all fixed in plan). Cycle 2: NO P0/P1 (both) |
| second-model coherence (deepseek-v4-pro) | 1 | 2 P1s (Linux subreaper gap undocumented; `ps eww` macOS gate unverified in artifact/CI) — both fixed (doc + required-verification promotion; empirical evidence added) + 6 P2s fixed |
| Phase 7 parallel review | 2 | Agent #1: 1 P1 (bash fixture can never pass 24h cutoff — fixed: `--cutoff 0`) + P2s (auto-sync ⚠️ filter, timer seams) + P3s. Agent #4: 2 P1s (group-kill vs live-terminal safety — fixed: group-kill only when pgid==pid; argv gate dropped — pair-ENV-only classifier catches the Jetsam-burst MCP class) + P2s (attribution log, young-child case, sweep ORPHAN_WATCHDOG=0 valve) + P3s — all fixed. Re-review: below |

## Plan (chosen solution — Approach A)

**Child-side ppid watchdog integrated into `extensions/task-heartbeat.ts`** (the child-side extension already shipped to every print-mode dispatch child):
- Gate split: `taskHeartbeatActive()` unchanged (emitter); NEW `orphanWatchdogActive()` = identity pair `TASK_HEARTBEAT=1 ∧ PI_MODE=print` ∧ `ORPHAN_WATCHDOG≠0` — DISABLE-agnostic (arms task + subagent children; exempts swarm workers + user one-shots; resolves the class-3 swarm question in the safe direction).
- Module-load scope; predicate `ppid !== originalPpid || ppid === 1` (subreaper + boot-race arms); double-confirm + min-uptime (60s); self-termination = direct-children TERM → 4s grace → SIGKILL survivors + pgid catch-net → exit(137); unref'd poll (15s); injectable seams for tests.

**Sweep bridge `scripts/sweep-orphans.sh`** (scan-orphans pattern): dry-run default, `--apply` manual gate; classifier = ppid==1 ∧ stat≠Z ∧ env exact-token `TASK_HEARTBEAT=1` (**pair-ENV-only** — Phase 7: drops the argv gate so MCP grandchildren, which inherit the pair env, are caught; the dead-child Jetsam-burst corner becomes covered) ∧ etime age cutoff (`--cutoff 0` disables for tests) ∧ settle re-verify (ppid+env) ∧ own-pgid REFUSED; **kill primitive is group-composition safe** — group-kill only when pgid==pid (detached), per-pid otherwise (a non-detached orphan shares the parent's session group — never group-signal a live terminal); `ORPHAN_WATCHDOG=0` honored as a sweep valve too; `🧹` + `⚠️` warning-line contract.

**Wiring:** auto-sync session_start warn-only (scan-orphans precedent) + auto-sync.test.ts fixture; ci-main accumulator appends (tsx suite → extension-tests; bash suite → script-validate); #285 drift-guard extension for the new predicate.

**Tests:** `extensions/task-heartbeat.orphan.test.ts` (tsx injectable — gate matrix incl. DISABLE-agnostic shift + swarm exemption, isOrphaned truth table, fire-sequence TERM→KILL escalation + exit 137 + self-never-signalled + fired latch + unref'd timer + arm returns {timer,poll}) · `scripts/sweep-orphans.test.sh` (real reparented orphans, portable detach via setsid/python3 os.setsid, `--cutoff 0` for positive assertions, non-detached group-survival fixture, zombie + degradation-⚠️ + 🧹 marker; runs the macOS `ps eww` branch locally + Linux `/proc` branch in CI).

Phase 7 refinements: watchdog fire sequence is exception-proof (try/finally → pgid catch-net + exit(137) always run) with a durable `~/.pi/agent/orphan-watchdog.log` attribution append; the argv-parity drift guard (Step 5) was REMOVED — the argv gate no longer exists.

Full detail: `docs/plans/2026-08-31-issue-385-plan.md`.

## External Research (Phase 1.5 artifact)

> **Trigger assessment:** Architecture axis = high (process-lifecycle design, novel in-repo mechanism); Org-Infra axis = medium (macOS-only platform semantics). External research fired via the diverge agents (medium confidence, per-framing provenance).

| Axis | Finding | Framing / provenance |
|------|---------|----------------------|
| Architecture — orphan reaping primitives | Linux production patterns (PR_SET_CHILD_SUBREAPER, systemd scopes/cgroups) are supervisor-side and inapplicable to an ad-hoc macOS CLI; pidfile+startup-sweep is the weak pattern. Canonical macOS: children of a SIGKILLed process reparent to launchd (PID 1). | canonical + pitfalls — Perplexity (diverge Agent B) |
| Architecture — child-side detection | Node `process.ppid` is dynamic on macOS and flips to 1 after reparenting (controller live-verified, macOS 25.5.0 — 5-tick test). `ps eww -p` shows same-user env (controller live-verified: TASK_HEARTBEAT=1, PI_MODE=print visible; tail truncation + version-sensitivity noted). `ps -o etime` format parity macOS/Linux verified live (`06-21:35:06` day-prefix). | canonical — in-repo + controller empirical |
| Org Infra — classification risk | PPID-1 + no-tty is the canonical double-fork daemon / tmux-detach signature → any SIGKILL-capable sweep must under-kill (warn-first, dry-run default, hard env discriminator). macOS Jetsam kills by priority band + footprint (memorystatus_kill; `memorystatus_control` errors; `jetsam_event` reports victim names) — orphan pages are also compression targets. | competitor-precedent + pitfalls — Perplexity (diverge Agent B, medium confidence) |
| Org Infra — CI/containers | Container/VM PID 1 differs (namespace init, systemd); zombies persist where PID 1 does not reap → stat-Z exclusion in classifier + acceptance polls. Subreaper adoption on Linux → changed-ppid watchdog arm; sweep `ppid==1` gate has a documented Linux gap. | pitfalls — Perplexity (diverge Agent B) + controller |

### Integration Docs

No new third-party dependencies. All primitives in-repo: `shared/tree-kill.ts` (`getChildPids`, `treeKill`, `parsePidList`), `shared/process-sweep.ts` (`getPgid`, `listPgid`, `killProcessGroup`, `sweepProcessGroup` with own-pgid REFUSED), `shared/print-mode.ts` (`VALUE_TAKING_FLAGS`, `argvHasPrintFlag` semantics), `scan-orphans.sh` (dry-run/`--apply` bash pattern), `auto-sync.ts` (session_start warn-only wiring precedent), `ci-main.yml` (accumulator). Node built-ins only. Bash: ps/pgrep/kill/date — all precedent-covered.

## Rejected Alternatives

- **B — standalone `extensions/orphan-watchdog.ts`** (own gate family, heartbeat contract untouched, new manifest entry, trivially revertable): rejected — same mechanism, but a new global-set file + manifest entry + second per-child poll timer for ~30 lines; A's gate split verified non-entangled. B's structural advantage (uniform class-3 coverage) voided by the safe-direction class-3 exemption.
- **C — dispatch registry (JSONL at spawn) + external two-pass sweeper (launchd opt-in)**: architecture-veto (no in-child code). Highest effort; honest residuals = best-effort registry (write is failure-silent by its own spec) + out-of-process kill surface. Its genuine wedged-proof advantage is real but unrated vs the acceptance (O1 measures the watchdog path; sync-blocked orphans are a rare, declared residual). Retained: sweep bridge, fail-closed env classifier, launchd continuous mode (follow-up 5).
- **Warn-only-only (no watchdog)**: rejected — a startup sweep is still parent-side (requires a new session with a healthy event loop) and cannot see the hung-children-under-a-live-parent class.
- **Child-side hard age cap** (wedged-parent detector): dropped — a ≥6h cap conflicts with legit long pipeline runs (#363 history) and changes parent-side retry semantics.

## Wiring Check

| Touch Point | Type | Covered By | Status |
|-------------|------|------------|--------|
| `extensions/task-heartbeat.ts` | child-side extension (edit) | Step 1 — gate split + watchdog | ✅ |
| `extensions/task-heartbeat.orphan.test.ts` | new unit suite | Step 2 + ci-main append | ✅ |
| `scripts/sweep-orphans.sh` / `.test.sh` | new sweep + bash suite | Steps 3–4 + ci-main script-validate | ✅ |
| `extensions/shared/print-mode.test.ts` | ~~parity drift guard~~ REMOVED (Step 5 — argv gate dropped) |
| `extensions/auto-sync.ts` + `auto-sync.test.ts` | session_start warn-only wiring | Step 6 | ✅ |
| `.github/workflows/ci-main.yml` | accumulator appends | Step 7 | ✅ |
| `pi-bootstrap/pi-config/extensions/` | symlink farm (single-file edit propagates) | Step 8 + `check-pi-config-extensions.sh` | ✅ |
| `manifest.json` | no new extension | — | ✅ no change |
| cross-repo (tortoise/eldato inherit) | blast-radius doc (#285 comment, header) | Step 1h | ✅ |
| mcp-client `process.on("exit")` | second net on exit(137) | fire sequence | ✅ |
| E14 marker drift guard | builtin-tools.test.ts (local; CI in follow-up issue) | Step 8 | ⚠️ local-only (separate issue filed) |

## Review Cycle Log

- problem-diverge: 2 agents (framings + devil's advocate) → 4 framings, assumptions A1–A12 tagged, 9-class orphan surface.
- problem-converge: 2 agents, independent, same definition @80.
- problem-verify C1: Verifier A 1 P1 (env visibility) + P2s; Verifier B 2 P1s (grandchild cascade, age-cap semantics) + P2s → controller fixed all 3 P1s.
- problem-verify C2: both NO ISSUES FOUND (with P2-level refinement items incorporated).
- solution-diverge: 1 agent → A/B/C + comparison + 9-class scoring + verification items.
- solution-converge: 1 agent → plan; 3 validation corrections (FLAW-1 symlink farm; FLAW-2 self-signal hazard; FLAW-3 valve placement).
- solution-verify C1: A 7 issues (2 P2, 5 P3/P4), B 1 P1 + P2s → all fixed in plan.
- solution-verify C2: both NO P0/P1 (13–14 fixes confirmed; 2 P2 spec corrections + P3s fixed).
- second-model coherence: 2 P1s (subreaper gap, ps eww verification) + P2s → all fixed.
- Phase 7: codebase/docs review + devil's advocate on the final plan (below).

## Complexity

| Domain | Rating | Rationale |
|--------|--------|-----------|
| Org Infra | medium | small mechanism, precedent-backed patterns, but behavior change on globally-inherited child-side extension (farm blast radius) + new sweep surface with fail-closed classifier |
| Config | low | new env vars (clamped, fail-closed defaults), sweep CLI flags, warn-only wiring; no config-file/schema changes |

## Follow-ups (separate issues, NOT absorbed)

1. CI hygiene: wire `process-sweep.test.ts`, `tree-kill.test.ts`, `builtin-tools.test.ts` (incl. E14) into ci-main accumulator.
2. Swarm lifecycle: class 3/6 ownership.
3. Wedged-parent-while-alive reaping.
4. Class-8 setsid-escape + dead-child-MCP + interactive-pi-MCP transport reaping (env-agnostic classifier).
5. Continuous sweep mode (launchd, opt-in).
