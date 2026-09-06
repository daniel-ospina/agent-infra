---
title: "#469 — pi session hygiene (idle REPL reaping) — internal research brief"
type: engineering
domain: operations
doc_status: draft
subjects.team: organisation-design-team
created: 2026-09-05
aboutSubjects: pi, cmux, organisation-design-team
aboutObjects: agent-infra, issue-469
---

# Research Brief — #469: idle pi REPL sessions are never reaped

> **Findings date:** 2026-09-05
> **Method (internal-only):** the subject state (pi fleet, cmux session registry, pi session JSONLs, pi/cmux configs) exists only on the dev box — external web research cannot inform it. Evidence = live probes (ps, cmux CLI + `~/.cmuxterm` store, pi session files, pi/cmux docs on disk) + in-repo precedent, mirroring the issue-279 in-repo design-review method. All measurements taken live on the M5/32GB dev box 2026-09-05 local evening; per-note times approximate.

## Context & Questions

Issue #469's Research Needed asks three questions, answered below with local evidence:

1. **Idle semantics** — what counts as idle (last user prompt? last tool activity? cmux `updated` unreliability?)
2. **Mechanism** — cmux `agent-hibernation <on|off>` vs pi-side idle-exit flag vs agent-infra reaper
3. **Resumability window** — keep idle < N alive; reconcile with cmux ghost records

## Findings

### 1. Idle semantics — pi's own session JSONL is the ground-truth last-activity signal

- pi autosaves every conversation entry to `~/.pi/agent/sessions/--<cwd>--/<started-at>_<session-uuid>.jsonl` (docs/sessions.md + session-format.md). Every record carries an ISO `timestamp` (session open, messages, tool results, model changes — all pi activity). **The last parseable entry timestamp = pi's own last activity.** Session files survive process death → resume via `pi -r` / `pi -c` / `pi --session <uuid>` unaffected by killing the process.
- cmux's per-session records (`~/.cmuxterm/pi-hook-sessions.json`, read by `cmux sessions list`) include `session_id` (== pi session uuid), `pid`, `agent_lifecycle` (`running|idle|needsInput|unknown`), `runtime_status`, `updated_at`. Record's `session_id` links the cmux surface to the pi JSONL file → the reaper can join ps → cmux record → pi file.
- **cmux store schema (drift-pinned live 2026-09-05):** keys are **camelCase** (`sessionId`, `agentLifecycle`, `runtimeStatus`, `updatedAt`, `pidStartSeconds`, `pidStartMicroseconds`, `cwd`, `startedAt`…). The store file has **no `storedPidExists` field** (aliveness is computed at `cmux sessions list` read time — snake_case CLI output must not be conflated with the file schema). `updatedAt` is a **float epoch** in the store file (str-ISO seen in CLI output — parser must be type-defensive and not depend on it; JSONL is the idle source). `pidStartSeconds` (int epoch, second granularity) + `pidStartMicroseconds` exist on all records — the **incarnation-fence field** for the 1:many pid hazard. **1:many pid→records is normal and broad: 75–76 live pids hold ≥2 cmux records**, incl. twin records with identical `pidStartSeconds` where one is `idle` and one `running` (pid 36849) — per-pid lifecycle veto is load-bearing.
- **Validation (live):** for file-backed sessions, cmux `updated_at` ≈ pi's last JSONL entry (e.g. pid 42680: cmux 09-01 19:35 vs pi 19:35:42; pid 96446: 09-03 12:58 vs 12:58:29; pid 31565: 09-04 15:29 vs 15:29:53). Both refresh on pi activity. Issue's warning stands: cmux `updated` *can* also tick on surface activity (focus/output), so it is a **secondary** signal. **Primary idle = pi JSONL last entry; lifecycle `running`/`needsInput` = hard never-reap gate.**
- **Robustness caveat:** JSONL entries can be multi-KB single lines (tool results) — naive `tail` parses fail mid-line; a correct reader scans back for the last complete line. ~4 of 22 live sessions had no resolvable last entry in this probe (giant lines / compaction rewrite windows) — a reaper must treat "no proof of idleness" as **not idle** (fail-closed, conservative).

### 2. Mechanism — pi has no idle-exit; cmux hibernation is blocked for pi; an agent-infra reaper is the viable path

- **pi-side idle-exit flag: DOES NOT EXIST.** Full `pi --help` (installed 2026-08-27 build) has no idle/timeout/auto-exit option; grep of the CLI bundle for idle-exit settings is empty; settings.md/env-vars.md contain only transport-level `httpIdleTimeoutMs`/`websocketConnectTimeoutMs`. Confirms issue claim.
- **cmux `agent-hibernation` (docs/agents, fetched 2026-09-05):** semantics = kill idle background agent processes beyond `maxLiveTerminals` (default 12) after `idleSeconds` (default 5) quiet + ~60s confirmation, resume on tab return. **Not a fit for #469:** (the `pi_version_unverified` blocker is a cmux-side verification gap — even if it were fixed and pi made restorable, hibernation would still fail #469's targets below, so the upstream-unblock path is rejected, not just currently blocked)
  - Resume requires a "saved restorable agent session + launch data can build a resume command". **pi records show `fork_unavailable_reason: pi_version_unverified`** → cmux cannot currently build the pi resume path → routine hibernation excludes pi REPLs until cmux verifies the pi version (config/launchCommand surface present: `launch_arguments` records the pi binary).
  - Limit-gated (`> 12 live restorable terminals`) — with ≤12 live pi terminals nothing hibernates regardless of idle age; #469 wants age-based reaping regardless of count.
  - Opt-in global toggle affecting all agents machine-wide (claude/codex/pi), killing-then-resuming on tab focus (different UX contract than "keep recent sessions alive"; hidden cold-restart on focus).
  - Hibernation still leaves the underlying policy at cmux's discretion; #469 wants an org-infra owned, deterministic, measurable policy (Indicator 2: RSS drop measurable via ps aggregation).
- **agent-infra reaper: fits.** Repo precedent exists for exactly this shape:
  - launchd template infrastructure (`templates/launchd/com.eldato.<job>.plist` + `scripts/install-launchd.sh`, idempotent render/install, issue #304; jobs: corruption-canary 15-min, fleet-cost-weekly Sunday 06:30).
  - **TCC constraint (#427):** launchd cannot read `~/Documents` repos → scripts that launchd runs are **farmed (copied)** to `~/.pi/agent/scripts/` by `pi-bootstrap/setup.sh` (fleet_srcs farm exists for fleet-cost-weekly.sh + friends).
  - Script conventions: bash + `.test.sh` beside script (fleet-cost-weekly.test.sh, install-launchd.test.sh), env seams for tests, `set -uo pipefail`, exit codes 0/1/2. **Note: the family's JSONL parser is not bash** — `session-postmortem.sh` parses via three inline `python3 -` heredocs (lines ~64 `parse_sessions` via `$@`, ~229 summary via `$METRIC`, ~257 transcript via `$SESSION`; python3 is already a farm runtime dependency), so a reaper parser written as inline python3 (or a `python3 -` subcommand) matches precedent; orchestration stays bash.
  - Existing fleet scripts parse pi JSONLs (session-postmortem.sh shared parser; fleet-cost-report.sh weekly cadence) — the reaper joins the same family (a different concern: process/memory hygiene, orthogonal to the #365/#340 session-cost contracts the issue lists as Related; #341 is #365's parent issue in that family).
  - Graceful exit path: cmux socket CLI `send [--surface <id>] <text>` (send `/exit`), fallback SIGTERM (idle pi has no in-flight work; session autosaved per entry → nothing lost). `close-surface` exists but closes the pane; `/exit` keeps the pane for a fresh `pi -c` (better UX + keeps cmux surface records coherent).

### 3. Resumability window + ghost records

- **Window:** the issue proposal (12h) was **falsified by diurnal churn on live data** — of the 13 morning-flagged "≥14h" sessions, 8 resumed active mid-day (62% same-day false-positive rate); process age mostly measures "operator asleep/away", not "finished work". **Reconciled default threshold = 24h idle** (env-overridable; matches the issue's own Target "0 idle >24h after a pass"), reaping the 29.6–98.1h-idle hoarder class while anything touched within a day survives. Live candidates at 16:45: 5 sessions (42680/55080/96446/31565/49053 ≈ 301MB); a 6th (87897) crossed 24h by 22:11 (≈ 305MB for 6). Sessions idle < 12h (e.g. 89338 idle 3.1h, 13389 idle 0.2h) must stay alive.
- **Ghost records:** `pi-hook-sessions.json` holds **3,675 pi records; 3,622 `stored_pid_exists=false`** (~6.6MB, 09-05 16:39). Registry bloat is far worse than the issue's "101/87" (that count was the default non-`--all` view, limit 100). **Ghost records are cmux's restore registry** — cmux rebuilds panes/workspaces from them on relaunch and `cmux sessions` lists them deliberately ("active, restorable, or transcript-backed"). Deleting them would break cmux's resume affordances for panes whose process is merely dead. **Conclusion: do NOT delete cmux records in this issue** — reaping targets the pi *process*; cmux records of dead pi processes are expected state (they age into the registry as `pid_exists=no`, cmux-internal lifecycle). A cmux-side prune of records whose session files are also gone is a separate concern → file as follow-up issue during scoping if it survives analysis.
- **Never-touch guarantees:** the reaper's kill gate is an **ALLOWLIST, not a blocklist** — reap only when `agentLifecycle == idle` AND `runtimeStatus == idle`, **per pid (union rule): every record matching the pid/incarnation must be `idle`; any non-idle twin vetoes** (identical-`pidStartSeconds` idle+running twins like pid 36849 must never yield a reap — a per-record evaluation would fail open). **Every other value is never-kill**: running, needsInput, unknown, `error`, and None/absent (runtimeStatus's real vocabulary includes `error` 436 + None 207 of 3,675 records — a blocklist encoding only running/needsInput/unknown would fail open on those). Additional guarantees: (b) skip sessions whose pi file cannot prove idleness (fail-closed), (c) exclude the caller's own session/ancestors (interactive one-shot runs), (d) only operate on pi processes parented by cmux panes (tty'd, launch args = the pi binary) — never another session's checkout (reaper doesn't touch git/worktrees at all).
- **Join order + pid-reuse hazard (live example):** the ps→cmux-record→pi-file join is 1:many — pid 42680 currently has TWO cmux records (a stale tortoise record session 01a051bf updated 08-30 with NO pi JSONL, and the live premise-labs record 01a05e71 with a JSONL). Pid reuse with leftover hook records means a reaper must resolve **session_id → pi JSONL existence + last-entry FIRST**, and only then pair the pid — a stale record's idle age must never be applied to a young live session. Records with no pi JSONL can only be reaped on secondary signals, or skipped (conservative default).

## In-repo precedent (no new patterns invented)

- `scripts/install-launchd.sh` + `templates/launchd/*.plist` (#304) — new scheduled job = new plist template, StartInterval or StartCalendarInterval, comment header w/ issue + canonical script path.
- `pi-bootstrap/setup.sh` scripts farm (fleet_srcs, #373/#427) — a launchd-invoked script must be added to the farm so `~/.pi/agent/scripts/` copy stays current.
- `scripts/fleet-cost-weekly.sh` / `fleet-cost-report.sh` / `session-postmortem.sh` — pi session JSONL tooling conventions; env seams (`PI_SESSIONS_DIR`) for tests; `.test.sh` beside script.
- Policy docs home: `docs/ops/*.md` (frontmatter title/type/domain/doc_status/subjects.team/created + aboutSubjects/aboutObjects), e.g. load-policy.md, cost-config-policy.md.

## Raw Notes

> Note: probe instants are approximate (single bash batch at ~21:38–21:47Z); every quantitative value below was re-verified against live state at review time (2026-09-05 ~21:48Z) and held.

- ~21:38Z — [probe] cmux records total 3,675 (`pi-hook-sessions.json` sessions dict; 3,676 incl. one mid-probe write); `stored_pid_exists` True=53/False=3,622 (CLI-computed); runtime_status dist idle 2966/error 436/needsInput 47/running 19/None 207; agent_lifecycle idle 3511/running 157/needsInput 3/unknown 4. Default `cmux sessions list` caps output at 100 → explains the issue's "101 records / 87 ghosts" undercount.
- ~22:11Z — [probe] 24h-threshold pass on live fleet: 6 provably-idle >24h candidates ≈305MB (42680 98.1h/47MB, 55080 67.1h/49MB, 96446 56.7h/54MB, 31565 30.2h/54MB, 49053 29.6h/97MB, 87897 ~67.9h/50MB — the 6th, crossed 24h between the 16:45 probe and 22:11); sub-threshold examples that must survive: 89338 idle 3.1h/84MB, 13389 idle 0.2h/139MB. Every tty'd pi REPL is its own pgid leader (pid==pgid).
- ~22:11Z — [probe] 1:many pid→records is broad: 75–76 live pids hold ≥2 cmux records (42680/36849/67002/72397 verified), incl. twins with identical `pidStartSeconds` where one record is `idle` and the other `running`; `pidStartSeconds`/`pidStartMicroseconds` present on all records; store-file keys camelCase, no `storedPidExists` field, `updatedAt` float-epoch.
- ~21:38Z — [probe] ps: 40 pi processes total; 22 tty'd (interactive REPL, zsh-parented in cmux panes) ≈ 4,034MB RSS.
- ~21:39Z — [probe] pi JSONL last-entry == cmux `updated_at` for file-backed idle sessions (42680/55080/96446/31565/49053/89338, matching to the second) — both track pi activity; cmux `updated` additionally ticks on surface activity per issue #469 (secondary signal only).
- ~21:40Z — [probe] cmux `docs agents` (raw agent-hooks.md fetched): hibernation kills idle background agents beyond `maxLiveTerminals` (default 12) after `idleSeconds` (default 5) + `confirmationSeconds` (~60s); routine path requires a restorable session + resumable launch; pi records carry `fork_unavailable_reason: pi_version_unverified`; the memory-pressure path also requires transcript-backed restorable agents.
- ~21:41Z — [probe] pi CLI `--help` + bundle grep: no idle-exit/auto-exit option or setting (only transport-level `httpIdleTimeoutMs`/`websocketConnectTimeoutMs` in settings.md).
- ~21:42Z — [probe] candidates idle > 12h with lifecycle idle + file-backed last-activity: 42680 (98.1h, 47MB, premise-labs), 55080 (67.1h, 49MB), 96446 (56.7h, 54MB), 31565 (30.2h, 54MB), 49053 (29.6h, 97MB) = 5 sessions ≈ 300MB.
- ~21:43Z — [probe] cmux CLI surface: `send [--surface <id>] <text>`, `send-key`, `read-screen`, `close-surface`, `surface resume set|show|get|clear`, `agent-hibernation on|off`; `sessions list` reads `~/.cmuxterm/*-hook-sessions.json` without a live socket.
- ~21:44Z — [probe] ~4/22 live tty'd sessions had an unparseable last entry (giant single-line JSONL entries spanning the probe window) — reaper must reverse-scan for the last complete line and treat unprovable as not-idle.
- ~21:47Z — [probe] pid-reuse hazard: pid 42680 has TWO cmux records (stale tortoise 01a051bf w/o JSONL + live premise-labs 01a05e71 w/ JSONL).
