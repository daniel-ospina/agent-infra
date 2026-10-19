---
title: "Orchestrator harness — autonomous lane dispatch and merge rail (`~/orchestrator`)"
type: operations
domain: platform
created: 2026-10-12
ownedBy: organisation-design-team
subjects.team: organisation-design-team
aboutSubjects: organisation-design-team
aboutObjects: daniel-ospina/tortoise, tortoise#8246, daniel-ospina/agent-infra, agent-infra#1700, agent-infra#1712
doc_status: draft
---

# Orchestrator harness

> **Component reference:** [`ARCHITECTURE.md`](./ARCHITECTURE.md) — per-script I/O and failure
> surface, the state-file lifecycle, the gate constants, triage and invariants. This file remains
> the authority for provenance, install, merge policy and measured results.

> **What this is.** A self-contained, single-host harness that turns one laptop into an
> autonomous delivery lane: it sweeps the open PR queue, dispatches GitHub issues into
> isolated worktrees as autonomous `pi` lanes, runs a fresh-context review → signed-record
> → merge chain on each result, and repairs the PRs whose reviewer found real problems.
>
> **Where it came from.** Built ad hoc in `~/orchestrator/` on one box during the
> 2026-10-10 → 2026-10-11 run that merged ~99 PRs (77 of them between
> `2026-10-10T23:45Z` and `2026-10-11T21:22Z`). It was never version-controlled. It was first
> versioned in tortoise as `operations/orchestrator-harness/` (PRs #8251, #8308, #8329, #8298;
> tracked by tortoise#8246) as the handover so it could be **evaluated** before being adopted.
>
> **Where it lives now.** `agent-infra/scripts/orchestrator-harness/` (relocation:
> agent-infra#1700). The home is agent-infra because this is fleet/agent operations, not
> tortoise product code — the merge rail it sits alongside (`admin-merge.sh`, `atomic-land.sh`)
> and the fleet's box-level script `cadence-nudge.sh` are already in `agent-infra/scripts/`, as
> are the multi-file tool subdirectories `checkout-hygiene/`, `ci/` and `gh-shim/`. Three scripts
> this same change versions into that directory existed only in local config before:
> `ci_runner_gate.sh` (the CI runner-label fallback gate), `cloud-cell-bringup.sh` (cell bring-up)
> and `cloud-cell-supervisor.sh` (the per-cell launcher — on a cell it is what starts this
> controller, since launchd is macOS-only).
> The old tortoise path
> (`operations/orchestrator-harness/`) is replaced by a stub pointer to this home in a follow-up
> tortoise PR that opens only after this one merges — tracked by tortoise#8432 (the relocation
> issue); until that PR lands the old path is a stale duplicate, so do not run it.
>
> ⛔ **Every post-copy change through tortoise `ef59f6d6f` has been PORTED here (agent-infra#1712),
> and that port is the precondition for removing the tortoise copy.** This directory is a
> point-in-time copy taken at 2026-10-13 05:50 local (= 10:50Z) from tortoise `0e060082f`. **Eight**
> tortoise commits touching this directory merged between `0e060082f` and `ef59f6d6f`
> (2026-10-13T15:48:33 local) — the declared port point — and all eight are present here:
>
> | commit | tortoise | what it carries |
> |---|---|---|
> | `8fe1e7b13` | #8437 | core-derived load ceiling, `MIN_MEM_FREE_MB`, the dead `REPO` default corrected — `orch-loop.sh`, `install.sh`, `refresh-candidates.sh`, `launchd.plist.template`, `README.md`, `selftest.sh` |
> | `a59858d07` | #8465/#8467 | dispatch pool ordered by **severity**, not issue number — `refresh-candidates.sh` + `selftest.sh` |
> | `ff6d1bc19` | #8471 | the follow-up that makes #8465's self-tests discriminate — `refresh-candidates.sh` + `selftest.sh` |
> | `77a0c32bd` | #8515 | `checked.txt` written only on the terminal CLEAN verdict (agent-infra#1716) — `refresh-candidates.sh`, `selftest.sh`, `README.md` |
> | `b559cb02a` | #8516 | INT/TERM `exit` rather than returning from the trap, so the lock and the process end together (agent-infra#1715) — `orch-loop.sh` + `merge-one.sh` + `selftest.sh` |
> | `45dd16cc8` | #8519 | a FAILED PR listing is not an EMPTY one; the reaper fails closed (agent-infra#1705) — `refresh-candidates.sh`, `selftest.sh`, `README.md` |
> | `26f6c9488` | #8514 | portable load/swap/mtime/memory probes and `nproc` core count, so the Linux cell controller runs (agent-infra#1702) — `orch-loop.sh`, `install.sh`, `selftest.sh`, `README.md` |
> | `ef59f6d6f` | #8518 | required checks classified by **allow-list polarity**, not a deny-list, so an unrecognised or null conclusion is red rather than reading `PENDING` (agent-infra#1714) — `orch-loop.sh`, `fix-one.sh`, `selftest.sh`, `README.md` |
>
> ⚠️ **A COUNT is the wrong anchor; the SHA is.** Three different counts were each correct at a
> different moment while this port was being written: `26f6c9488` and `ef59f6d6f` both landed
> *between* a fetch of `origin/main` and the commit built on that fetch, so even a freshly-read ref
> was stale by the time it was used. The instruction for any future copy is therefore: **re-fetch,
> diff the tortoise tree against this one at that moment, port everything not present, and record
> the SHA you ported to here.** The removal PR must re-run that diff against the then-current
> tortoise tip: a port is only complete *relative to a declared sha*, and removing the tortoise copy
> while any delta remains deletes the only tree carrying that fix.
> The last of them merged at 15:16 local **while this port was being written**, which is the point:
> a hand-kept list only catches what its author already knew. Two guards exist instead of a list.
>
> 1. **`port-provenance.txt`** pins the tortoise blob hash of every file at the port's sync point,
>    and **`check-port-drift.sh`** fails if the tortoise tree no longer matches it, naming the file.
>    Run it before the follow-up tortoise PR removes anything:
>    `./check-port-drift.sh --tortoise /path/to/tortoise`.
> 2. **The ported `selftest.sh` checks are the anti-regression guard** — each of the seven commits
>    added checks that are RED on the pre-fix tree (16 for #1702 alone), so a reverted port fails the
>    suite rather than merely looking different.
>
> ⚠️ **The follow-up has a second obligation the sha list never covered.** tortoise's **open**
> branch `fix/8468-closure-linkage` also rewrites this directory (severity-ordered pool, a
> `.prio`-keyed P0 bypass of the merge-priority gate, `merged-not-closed.sh`, a `Closes`-not-`Refs`
> lane brief). It is **not** on `main`, so it is deliberately not ported here — it is still under
> review, and porting it would create a second home for work that has not landed. The live box is
> already running an earlier revision of it. Either that branch merges first, or the removal PR
> must port it; removing the directory while it is open orphans it.
>
> ⚠️ **This port is faithful EXCEPT for a declared set of fail-open / false-PASS fixes.** These are
> agent-infra's, not tortoise's — a later diff between the two trees WILL show them, and they must not
> be read as lost work in either direction:
>
> | divergence | why it is here |
> |---|---|
> | `orch-loop.sh` guards **every** limit with `is_limit` (digits **and** at most nine of them) before its first arithmetic read — `MAX_LANES`, `MAX_REVIEW`, `MERGE_PRIORITY_AT`, `MAX_FIX`, `MAX_FIX_TRIES`, `BATCH`, `CYC`, `STALE_MIN`, `SWEEP_MAX_AGE`, `SWEEP_MIN_REMAIN` (and `MAX_LOAD`/`MIN_SWAP_FREE`/`MIN_MEM_FREE_MB`, which had `is_num`: the first two are plist-supplied gates that `[` would ERR on at or above 2**63, the last is plist-supplied too, so all three moved to `is_limit`) | two failure modes, both fail-**OPEN**: `[ -ge ]` on a non-number is FALSE and FALSE in the gate chain ALLOWS, so `MAX_LANES=4x` dropped the lane cap, `MERGE_PRIORITY_AT=notanum` removed the drain-before-dispatch gate, `BATCH=abc` dispatched the whole backlog in one cycle, and `MAX_FIX_TRIES=abc` let fixer attempt 10 run past a cap of 3. `[` also ERRORS at or above 2**63, so an absurd-but-numeric limit opened them the same way. `is_num` itself stays unbounded for an **epoch mtime** (already 10 digits), but `_NCPU` is now `is_limit` too: its source is the host (`sysctl`/`nproc`), not the plist, so an absurd-but-numeric probe reached `$(( 10#$_NCPU * 10 ))` and WRAPPED — 99999999999999999999 to 3875820019684212726, 19 digits but still BELOW 2**63-1, so `[ -ge ]` does NOT ERROR: it simply never binds and the gate OPENS **silently** (the earlier wording said `[ -ge ]` ERRORS here — corrected, fifth review round 2026-10-14) — and 2**63 to exactly 0, which `is_limit` ACCEPTS because install.sh allows 0 for every limit but CYC (`[ "$L" -ge 0 ]` is always true, so the gate CLOSES and the box dispatches nothing). `install.sh` now mirrors the loop's guard (`is_limit` + the `_NCPU >= 1` probe guard + the two MAX_LOAD guards) because install.sh is what substitutes `__MAX_LOAD__` into the live plist — the wrap survived there on the real production path |
> | `orch-loop.sh` reads base 10 where it read base 8 | `$((MAX_REVIEW + 2))` read `030` as **octal** (26, not 30) and `$((STALE_MIN * 60))` did the same. `MERGE_PRIORITY_AT` already normalised with `10#` |
> | `install.sh` refuses a non-integer, an out-of-range value, or a value carrying a `__TOKEN__` | `MAX_LANES=4x` was written into the live launchd plist and `install.sh` exited 0, so the plist lied about the ceiling; and the sed rules run in order, so `OR=__MAX_LANES__` rendered as the default (then a literal `4`, now 2.5× cores) — exit 0, valid XML, and the daemon then ran `gh --repo <default>` |
> | `install.sh` renders to a temp file and `mv`s it into place, and asserts no `__…__` survived | the redirect truncates `$PLIST` **before** `sed` runs, so rejecting after writing straight to it left the live plist empty or poisoned — and §9's next step (`launchctl unload && load`) then failed, so a rejected re-install destroyed a working daemon config. `plutil -lint` cannot see a substitution that did not take |
> | `install.sh` creates the plist's directory (`mkdir -p "$(dirname "$PLIST")"`) | an agent-infra addition, not a lost tortoise line: a sandboxed or first-time `HOME` has no `Library/LaunchAgents` and the redirect then died |
> | `selftest.sh` pins the documented default of every host-independent limit, drives the swap gate with real swap (`SWTOTAL` != 0) **and** a non-default ceiling, drives `install.sh` instead of grepping it, and extracts the coercion lines to RUN them | the default-agreement check could not see both files drifting **together**; `SWTOTAL=0` short-circuits the swap gate before the comparison; a source-text pin survives the guard being disabled (`if false && grep …`); and a fixture that re-implements the pattern in the test asserts nothing about the shipped code |
> | `orch-loop.sh` moves the sweep's PR **listing** to a conditional REST call (`gh api --paginate -i` + `If-None-Match`, ETag in `state/sweep-etag`, age floor `SWEEP_MAX_AGE`) and takes its rate-limit signal from the **response headers** (`x-ratelimit-remaining`/`-reset`/`Retry-After`) rather than `/rate_limit`; the `# BEGIN sweep-quota` helper block (`sweep_fail_kind`/`sweep_defer_until`) and the new `sweep-quota.test.sh` are agent-infra-only (and the ported `selftest.sh` gains the section that runs it, with its coercion-count pin) | a `304` is not charged to the primary rate limit, so the listing is free, and the `/rate_limit` counter was measured reporting `graphql 4933/5000` while **every** GraphQL call failed — a cell that cannot list PRs cannot merge and read as idle-but-fine (agent-infra#1762). tortoise still carries the polling sweep, so a faithful port must not delete this block as "unported work": port it or keep it |
>
> The upstream-logic defects found in the same review are **not** diverged here; they are tracked
> instead — `fix-one.sh`'s spaced-check-name word-splitting (agent-infra#1703), `can_spawn()`'s
> load-only gate (agent-infra#1732) and the classifier's inert `(app, name)` grouping
> (agent-infra#1733) are all still present, matching tortoise.
>
> **Status: evaluation artifact.** Nothing here installs or runs on its own. `install.sh`
> renders a launchd plist and *prints* the load command; it does not execute it.
> Tracked by tortoise#8246.

---

## 1. Why it exists

The repo's normal path is one agent, one issue, one PR, human-paced. On a box that is left
running overnight that path is idle most of the time. This harness keeps the box saturated
without a human in the loop:

- **Fan-out:** N simultaneous implementation lanes, each in its own git worktree.
- **Fan-in:** a per-PR chain that reviews, records the review as a gate artifact, and merges.
- **Back-pressure:** every cycle is gated on load average and swap, so the box throttles
  itself instead of thrashing. Above `MERGE_PRIORITY_AT` **unowned** open PRs (25) — open PRs
  nothing is currently working, derived from the loop's own worker sessions, cross-box claims and
  unconsumed reviewer-findings markers — the balance shifts to **draining**: new lanes stop being
  dispatched and the reviewer AND fixer headroom rises (`MAX_REVIEW+2` / `MAX_FIX+2`), because a
  merge backlog means the scarce capacity belongs to review and merge, not to opening more PRs.
  Counting TOTAL open PRs instead capped the fleet on a busy queue: a PR mid-review, mid-fix,
  mid-merge — or held by a claim on another box — read as congestion. Measured 2026-10-16, two live
  cells logged `merge-priority (20 open PRs — draining)` at `lanes=1` of a configured 32 with
  59-86% CPU idle and 13.9 GB RAM free (agent-infra#1824; see the tuning table in §4).
  ⚠️ A cross-box claim is a **declared window**, not proof of life — `claims.sh` is explicit that a
  lease is *data, not liveness* (a remote pid cannot be probed), so an abandoned-but-unexpired
  claim reads as owned until the lease expires. The residuals and their direction are recorded on
  `pr_owned()` in `orch-loop.sh`.
- **Self-healing:** a PR whose reviewer reports real findings is routed to a *fixer*, fixed,
  and re-reviewed — rather than being left red forever (this is the bug that stranded ~15
  PRs before it was fixed; see §7).

It deliberately does **not** use the `task` sub-agent tool. Workers are separate `pi -p`
processes in tmux sessions, so a killed worker cannot take the controller down with it.

---

## 2. Architecture

```text
                      launchd  com.eldato.orchestrator-loop  (RunAtLoad + KeepAlive)
                                        │
                                  orch-loop.sh        ← the controller, one process
                                        │
        ┌───────────────────────────────┼────────────────────────────────┐
        │                               │                                │
   (1) merge sweep              (2) capacity-gated dispatch      (3) backlog refresh
        │                               │                                │
        │  for every open non-draft PR  │  read candidates.txt            │  refresh-candidates.sh
        │  read repo's required checks  │  skip if in dispatched.txt      │  pre-flight each issue
        │                               │  dispatch-merge.sh:             │  (collision_preflight.py)
        │   GREEN   → merge authority   │    git worktree add             │  append CLEAN ones
        │   PENDING → auto (gate mode)  │    tmux new lane-<N>  ──┐       │
        │   FAILED  → see below         │    tmux new chain-<N> ──┤       │
        └───────────────────────────────┴─────────────────────────┼───────┘
                                                                  │
                        ┌─────────────────────────────────────────┘
                        ▼
        lane-<N>   → lane.sh   : pi -p in .worktrees/tm-<N>, implement → commit → push → open PR
                        │
        chain-<N>  → chain-merge.sh : poll for the PR to appear, then
                        ▼
        merge-<PR> → merge-one.sh :
                        the repo's merge authority decides the whole step (agent-infra#1764)
                        gate mode (the repo REQUIRES `ai-review-gate`):
                        1. fresh-context reviewer → posts its review as a PR comment (the audit artifact)
                        2. CLEAN   → record-review.sh (HMAC-signed marker into the PR body)
                                     → wait for ai-review-gate SUCCESS → gh pr merge --squash
                            ISSUES  → touch state/needsfix-<PR>-<head>   ← hands off to the fixer path
                        rail mode (the repo does NOT require the gate — e.g. agent-infra):
                        1. `scripts/admin-merge.sh <PR>` — the repo's own rail, which posts its own
                           head-bound evidence and merges. No reviewer is run and `gh pr merge` is
                           NEVER called: it would land on the required checks alone, bypassing the rail.
                           Refused 3x at one head → PARK that head.
                        ▼
        fix-<PR>   → fix-one.sh  : materialises a worktree for the branch (including foreign
                                   branches), runs a fixer over the reviewer's findings, pushes a
                                   new commit, then re-runs merge-one.sh end-to-end
```

### Worker types

| Session | Script | Writes to | Purpose |
|---|---|---|---|
| `lane-<N>` | `lane.sh` | `.worktrees/tm-<N>` on `feat/<N>-tm` | implement issue #N → commit → push → open PR |
| `chain-<N>` | `chain-merge.sh` | — | wait for the lane's PR, then delegate to `merge-one.sh` |
| `merge-<PR>` | `merge-one.sh` | — | **repo-authority-dependent**: gate mode = fresh review → signed record → wait green → squash-merge; rail mode = the repo's own `scripts/admin-merge.sh` |
| `fix-<PR>` | `fix-one.sh` | the PR's worktree | repair findings **or a failing required check**, push, re-run the merge chain |
| `cell-doctor` | `cloud-cell-doctor.sh loop` | `state/roles/`, `logs/doctor.log` | the cell's **own** scheduled roles — `doctor` (reap + restart a missing controller), `merge` (land attested PRs on the standard rail), `hygiene` (caches/worktrees). Started by `cloud-cell-supervisor.sh start`; see §6.5.7 |

### State files (`$O/`)

| File | Meaning |
|---|---|
| `heartbeat` | epoch seconds, rewritten every cycle — the liveness probe |
| `state/queue-state` | what the last pool READ saw, with the epoch of the read — `EMPTY`, `READ(<n>)`, `PARTIAL(<tiers>)` or `UNREADABLE`. `orch-loop.sh` prints it in the cycle line as `queue=$(queue_state_token)`, so a refresh that could not read the pool (`queue=UNREADABLE`) is never mistaken for a fleet with nothing to do (`queue=EMPTY`); an absent file reads `UNKNOWN`, never `EMPTY` (agent-infra#1931) |
| `.orch.lock` | atomic single-instance lock (noclobber create); stale locks are reclaimed |
| `candidates.txt` | the dispatch backlog: issue numbers that passed collision pre-flight |
| `dispatched.txt` | issues already handed to a lane — **pruned** when the issue is still open, no PR branch matches it and no `lane-<N>` is live (see §7.1) |
| `checked.txt` | issues whose pre-flight returned **CLEAN** (the terminal verdict); an **errored** pre-flight and a **COLLISION** leave no entry, so the next pass re-attempts them (agent-infra#1716). A reaped number is dropped from it too, so the pre-flight re-queues the issue |
| `state/collided` | `"<expiry-epoch> <issue>"` per line — candidates a peer was holding at the last pre-flight. A pass walks PAST a fresh record without spending a pre-flight run, so a blocked pool HEAD is not re-bought on every pass; a skipped candidate stays out of `candidates.txt` and out of `checked.txt`, so it is **deferred, never dropped** — the record lapses after `POOL_COLLISION_TTL` (900 s) and the candidate is judged again (agent-infra#1729). Only a COLLISION is recorded: a DEGRADED / INCOMPLETE / verdict-less answer is an environment failure and stays visible on every pass (agent-infra#1736) |
| `state/mergeclaim-<PR>.lock` | single-owner claim: only one worker may review/record/merge a given PR |
| `state/needsfix-<PR>-<head>` | "a reviewer found real issues at this exact head" |
| `state/fixcount-<PR>` | fixer attempts for that PR, capped by `MAX_FIX_TRIES` |
| `state/parked-<PR>` | terminal state: the fixer cap was reached at the head recorded inside the file, so the sweep skips it until a new push re-arms it |
| `state/rerun-<PR>-<runid>` | CI re-run already requested for this run — prevents loops |
| `state/merged-<PR>.done` | merge confirmation |
| `state/last-open-n` | the last SUCCESSFUL open-PR count; reused only when positive if a later count fails — a failure never reads as 0 |
| `state/last-open-prs` | the `number:headOid` rows from that same SUCCESSFUL listing — the **ownership scan's** input (`unowned_pr_count`). Written on success and REMOVED on a failed listing, so a fallback count is never paired with the previous listing's rows; absent rows mean **nothing is owned** (the whole count is unowned), which is the fail-closed direction. Both files come from ONE `gh pr list` call. |
| `state/roles/<role>.state` | the cell doctor's LAST-PASS record per role (`last_pass_at`, `last_pass_epoch`, `passes`, `last_rc`, `last_result`), written atomically and only by a completed pass — `status` reads it, so "never ran" is distinguishable from "idle" (§6.5.7) |
| `state/roles/.desired` | the cell is SUPPOSED to be running; written by `start`, removed by `stop`, so the doctor restarts a controller that `stop` did not silence |
| `state/roles/loop.ident` | `pid|<identity>` for the doctor loop, where the identity is `proc:<starttime>` from `/proc/<pid>/stat` on Linux and `ps -o lstart=` where `/proc` does not exist — `status` verifies BOTH before reporting the loop RUNNING, so a recycled pid (after a tmux server restart, an OOM kill or a crash) cannot make a dead loop read as alive |
| `state/roles/merge.attempts` | `PR head epoch reason` for every rail call the merge role made — the head-level cooldown that stops a REFUSED head being retried blind |
| `logs/` | one log per worker: `lane-*.log`, `chain-*.log`, `merge-*.log`, `fix-*.log`, `orch-loop.log` |
| `wip/` | dirty-worktree captures taken before a shutdown (see §6) |

### Why the *reviewer* is a separate process from the *controller*

`merge-one.sh` spawns a fresh-context `pi -p` reviewer that has never seen the implementing
lane's reasoning. It reads the changed files at the PR head (`git show origin/<branch>:<path>`)
rather than only diff hunks, and posts its verdict as a PR comment. That comment is the
evidence the `record-review.sh` signature points at, so the merge gate is auditable after
the fact: the PR body names the comment it was signed against.

### Non-blocking dispatch — the orchestrator keeps its own time

`nonblocking-dispatch.sh` launches a headless worker and **returns immediately**. It exists because
the built-in `task`/`subagent` tools always block the caller (agent-infra#1662): an orchestrator that
dispatches N workers pays `max(worker)` wall-clock and cannot react to anything until the slowest
settles.

It is deliberately thin. It carries **no agent invocation of its own** — it backgrounds
`run_agent()` from `spawn-gate.sh`, so a background worker is load-gated exactly like `lane.sh` and
`fix-one.sh`, gets the same wall-clock watchdog, and appends the same `state/walltime.tsv` row with
`KIND=bg`. Routing it through the helper is also what keeps `spawn-gate.test.sh`'s invoker census an
equality: a direct spawn here would be a fourth, ungated launch path.

```bash
bash nonblocking-dispatch.sh <name> <worktree-dir> <prompt-file> [timeout-seconds]
bash nonblocking-dispatch.sh --status <name>     # running | done rc=0 | failed rc=N | lost
```

Status comes from the worker's own exit-status file plus a pid probe — **never `%CPU`**, which reads
0 for a worker that is merely WAITING (`docs/ops/fleet-liveness.md`). "launched" is the only success
this script reports: it cannot tell you the work succeeded.

⛔ **Nothing here reviews anything.** The worker runs with `AGENT_SKIP_REVIEW_GATE=1` (a child has no
`task` tool and cannot satisfy the gates itself), so **the PARENT owns the review gate** — hand the
PR to `chain-merge.sh`, which polls for it and runs `merge-one.sh`. A background worker whose PR is
never handed to the chain is unreviewed code by default.

⚠️ `install.sh` does **not** copy it — it places no `*.sh` in `$O` at all, only `gh-rest/gh`
(`install.sh:352`); everything else is the operator's `cp`, §4 step 1. Its `DRIFTED` warning iterates
an explicit list of eleven `*.sh` plus `gh-rest/gh` (`install.sh:490-494`), and this file is not on
it, so you get no named `cp` line for it. ⛔ A stale copy is
still REPORTED, twice: the provenance stamp's `deployedMatchesSource` compares **every** shipped
`*.sh` against `$O` (`install.sh:621-632`), and `check-deployed-drift.sh` fails on any differing
blob. What puts this file in `$O` is the manual copy in §4 —
`cp scripts/orchestrator-harness/*.sh ~/orchestrator/`. Run it from the harness directory, and
re-run that `cp` after editing this script.

⚠️ This is a stopgap for an open gap, not the fix. **agent-infra#1666** lands non-blocking dispatch
as a first-class primitive (`task({ background: true })` plus `task_status`/`task_collect`). Once that
merges it supersedes this script for `task`-based orchestrators; the harness keeps this one for its
own `pi` workers, which do not go through `task`.

---

## 3. Prerequisites

| Dependency | Why | Notes |
|---|---|---|
| `tmux` | every worker is a detached tmux session | `brew install tmux` |
| `gh` (authenticated) | all queue + PR operations | needs push access to the target repo |
| `pi` on `PATH` | the worker runtime (`pi -p --provider deepseek --model deepseek-v4-flash`) | provider/model are literals in `lane.sh`/`merge-one.sh`/`fix-one.sh` — change them there |
| `uv` | `lane.sh` runs `uv sync --extra embeddings --extra parity` in each worktree | tortoise-specific; `refresh-candidates.sh`'s SCOUT venv is repo-aware since agent-infra#1736 (skipped when there is no `pyproject.toml`; the extras are read from that project) |
| `python3` | `orch-loop.sh`'s required-check classifier and `fix-one.sh`'s failing-check list | absent, the classifier returns an empty verdict, no case arm matches, and **every PR is skipped in silence** |
| `~/.pi/agent/scripts/record-review.sh` | writes the HMAC-signed review marker the `ai-review-gate` check verifies | shipped by `agent-infra`; **gate mode only** — a repo that does not require the gate consumes no such marker, so `merge-one.sh` does not mint one there. A cell's `start` provisions it when the cell has none — see below |
| **the operational layer** (`~/.pi/agent/{scripts,extensions,skills,AGENTS.md,settings.json}`) | a lane is only as guarded as its `pi`; without the layer a box has **no review-enforcer, no verification-gate, no main-worktree-guard, no search-guard, no audit-logger, no skills** | installed by `pi-bootstrap/cell-install.sh`, and on a cell it runs from `cloud-cell-bringup.sh --check`. Measured 2026-10-15 on a live cell: `scripts/` did not exist at all (24/24 declared farm files absent), and the merge path died `rc=127` on the missing `record-review.sh` (agent-infra#1723) |
| **`AI_REVIEW_GATE_KEY`** | the merge authority — env var, or `~/.pi/agent/.ai-review-gate-key` | **this harness cannot merge a gate-mode repo without it.** Treat as a secret; never commit it |
| the target repo's branch protection | the REQUIRED-check list and the merge authority are read from it at runtime (agent-infra#1764) | `gh api repos/$OR/branches/main/protection/required_status_checks`. `REQ=…` in the cell env / `keys.env` overrides the read. Unreadable → `FALLBACK_REQ` (non-empty, fail-closed). Requires admin read on the repo, else the fallback applies every cycle and nothing merges |
| `REVIEW_GATE` (optional) | names the check that IS the merge authority — the repo's gate | defaults to `ai-review-gate`; set it only for a repo whose gate has another name. It is read from the environment, so an ambient/`keys.env` value takes effect: **an override that changes the merge authority away from what the repo's own declaration gives is logged** as `⚠️ … CHANGES the merge authority`, naming the consequence. On a rail repo a flip to `gate` authority means a RAW merge (no head-bound evidence), so treat that line as an error, not noise |
| a collision pre-flight tool | `refresh-candidates.sh` refuses overlapping dispatches | resolved **per repo** (agent-infra#1736): the target repo's own `tools/collision_preflight.py`, else a tortoise checkout (`TORTOISE_REPO`, or its legacy `TORTOISE` alias). The tool requires **Python >= 3.12** and refuses an older interpreter with exit 3 and no verdict, so the selected interpreter (scout venv, or a bare `python3` when there is no `pyproject.toml`) is version-gated: `--check` and the refresh both refuse a too-old one (permanent `rc=3`) instead of queueing nothing in silence. `SCOUT_PY` pins the interpreter, like `SCOUT_UV` pins `uv`. Put `TORTOISE_REPO` in `keys.env` — the controller session re-sources it, while an ambient-only export does not reach a pre-existing tmux server |
| `.worktrees/` gitignored in the target repo | worktrees are created under it | `git check-ignore .worktrees` |

**`cloud-cell-supervisor.sh check` vouches only for what it actually probes, and refuses to certify
a cell missing any of them: `tmux`, an authenticated `gh`, `git`, `python3`, `pi`, a cloned repo
whose `origin` remote names the SAME repo the queue dispatches (`OR` is derived from it; a mismatch,
or a pair that cannot be read, is refused naming both values — agent-infra#1901), a checkout
with the worker scripts in `$O`, and — since agent-infra#1717 — a non-empty, executable
`~/.pi/agent/scripts/record-review.sh` with its `lib/diff-normalize.py` sibling.** The rest of the
table is *not* a refusal by name: a missing `AI_REVIEW_GATE_KEY` is a **warning** — a keyless cell
still runs a controller and is still a **MERGE ACTOR** (`gh pr merge --auto` does not go through the
key; see the ⛔ measured note at the top of `cloud-cell-supervisor.sh`), it just cannot complete a
*signed* merge in a gate-mode repo. The `.worktrees/` gitignore is not probed at all, and
`tools/collision_preflight.py` is not a dependency `check` refuses on by that name: the only by-name
read in `cloud-cell-supervisor.sh` itself is `repo_vendors_tool()`, which uses it solely to decide
whether an operator's `TORTOISE_REPO` is relevant. The refusal is indirect but real — the #1736
dispatch-provisioning probe (`refresh-candidates.sh --check`, which `cmd_check` runs) reads that same
literal path and refuses a repo that resolves no copy of it — so `check` does refuse that cell in
effect.
Its verdict is the literal line `CELL CAN RUN A CONTROLLER`, so a dependency that is absent must
fail *there* — a cell that is blessed and then discovers the gap mid-review pays for the discovery:
`git`, `python3`, `pi` and `~/.pi/agent/scripts/record-review.sh` are fatal, `uv` warns (as it does
in `install.sh`) — but the #1736 dispatch probe (`refresh-candidates.sh --check`, which `cmd_check`
runs) refuses a `pyproject.toml` repo whose scout venv has to be built while `uv` does not resolve on
`PATH`, so `uv` is fatal in effect there. And `start` provisions the record step from this checkout
when the cell has none (agent-infra#1717).

**Single-host assumption.** Everything is local: tmux sessions, worktrees, logs, the key.
There is no scheduler, no queue service, no shared database. Two boxes running this against
the same repo work fine *because* GitHub is the coordination medium — but they will duplicate
work unless they coordinate (see §5, "broad mode").

### GitHub API surface — the REST adapter (`gh-rest`)

The harness reaches GitHub through `gh`, whose hot paths (`pr view`, `pr checks`, `pr list`,
`issue list`) are **GraphQL**. GraphQL has its own secondary limit, and when GitHub refuses it the
failure is silent rather than loud: measured 2026-10-17, every GraphQL call returned
`graphql_rate_limit` (even `{viewer{login}}`) while the primary quota still read `4511/5000` and the
REST endpoints answered normally. A five-minute window with **every harness process killed** did not
clear it.

That one asymmetry stopped both halves of the harness, and neither log line named the cause:

| Capability | Broken call | Symptom |
|---|---|---|
| dispatch | `fleet_state.py` board read (`gh pr list`) | *"the GitHub board could not be read"* → board stale → claim gate `INCOMPLETE` → backlog 0 |
| merging | sweep per-PR reads (`gh pr view`, `gh pr checks`) | `NOCHECKS` → fail-closed → **no PR could merge** (19 mergeable PRs, hours) |

`gh-rest/gh` is a PATH shim that supplies the REST equivalents for exactly those shapes and
**delegates everything else verbatim** — including `gh api`, which is already REST:

| Translated | REST endpoint |
|---|---|
| `pr view --json …` | `GET /repos/{o}/{r}/pulls/{n}` |
| `pr checks --json …` | `GET /repos/{o}/{r}/commits/{sha}/check-runs` |
| `pr list --json …` | `GET /repos/{o}/{r}/pulls?state=…` |
| `issue list` / `issue view --json …` | `GET /repos/{o}/{r}/issues…` (PRs filtered out) |
| `pr ready` | `POST …/pulls/{n}/ready_for_review` |
| `pr merge` (incl. `--match-head-commit`) | `PUT …/pulls/{n}/merge` |
| `pr comment --body` | `POST …/issues/{n}/comments` |

### The layer underneath: `gh-limit` (#1988)

Four boxes act as **one GitHub account**, so they share one REST bucket and one GraphQL bucket.
Nothing serialised the harness's calls and nothing backed off when a box was refused, so one box's
burst became another box's secondary limit — and the refused call was read by its caller as "no
data", which is how a cell that could not merge looked like a cell with nothing to do.

`gh-limit.py` is the one implementation of GitHub's documented policy (serialise; honour
`retry-after`; honour the bucket's `x-ratelimit-reset` when it is empty; otherwise wait at least a
minute and grow exponentially; fail after a bounded number of attempts). It is reached from two thin
entry points, both of which put it FIRST on the harness's `PATH`, so no call site has to remember it
and no new call site can forget it:

| Entry point | Where | Installed by |
|---|---|---|
| `gh-rest/gh` (the REST adapter above) | Mac | `install.sh` → `$O/gh-rest` first on the daemon PATH |
| `gh-limit/gh` (nothing but the layer) | cloud cells | `cloud-cell-supervisor.sh` → `$O/gh-limit` first on the controller PATH **and** published through tmux `update-environment`; `deploy-crossbox.sh` seeds the same two files and passes the PATH on the controller's `new-session` line (it does not touch `update-environment`) |

⛔ **The shim has to be re-asserted after the tool-dir prepend.** Every gh-calling harness script
opens with `export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH`, which puts a REAL `gh` ahead of the
seeded shim on any box whose gh lives in one of those dirs (measured: on the Mac it does), leaving
an inert layer that reports protection and provides none. `orch-loop.sh`, `merge-one.sh`,
`fix-one.sh`, `lane.sh` and `chain-merge.sh` therefore re-prepend `$O/gh-limit`/`$O/gh-rest` after
that line — and so does `nonblocking-dispatch.sh`, which calls no `gh` itself but spawns a whole
worker session in-process, so its PATH becomes that worker's PATH.

The predicate, exactly: **every `*.sh` in this directory that prepends those tool dirs AND invokes
`gh` must carry BOTH stanzas** (`$O/gh-limit` and `$O/gh-rest`), plus `nonblocking-dispatch.sh` for
the spawning reason above, and `gh-limit.test.sh` fails naming the file and the missing stanza. It is
a per-file two-line obligation — not an unpickable one — and a new script written outside this
directory is not covered by it. Two further entry paths exist so the common callers do not depend on
that obligation: the Mac adapter already resolves the layer for every call it serves, and the
heartbeat's own telemetry tools (`objective.py`, `merge-queue.py`, `beta-progress.py`,
`queue-dispatch.py`, `ask-owner.py`, `turn-classify.py`, `turn-end.py`, `undelivered-answers.py`,
`pr-doctor.py`) prefer `$O/gh-rest/gh` then `$O/gh-limit/gh` over their pinned real binary — derived
from `$O`, never from PATH. ⛔ THAT DOES NOT KEEP #1872'S PIN BY ITSELF: the layer resolves the real
`gh` by walking PATH, so the tools that have a pinned candidate hand it through as
`GH_REST_REAL_GH`/`GH_LIMIT_REAL_GH`; the three that never had one let the layer walk.

Why two entry points rather than one: moving the call sites onto REST is #1978/#1986's change, and
mixing a REST translation into a cell with a new backoff would make a translation bug and a backoff
bug indistinguishable. The wrapper therefore translates nothing; the REST adapter additionally
translates, and both call the same helper.

Notes worth keeping:

* **Single flight is per box, not per account.** Boxes cannot see each other; what this buys is a
  burst of 1 per box instead of 1 per lane. The lock is held per ATTEMPT and released across the
  wait, so a sleeping caller does not park the box — the invariant is "no two requests overlap",
  and the `/rate_limit` probe, which runs during backoff, holds it too.
* **A successful call is invisible** (stdout/stderr replayed byte for byte) because callers parse
  merged output. Retries are announced in `$GH_LIMIT_DIR/events.log`; only a FINAL failure writes to
  stderr.
* **A limited box says so**: `$GH_LIMIT_DIR/last-limit` is printed by `orch-loop.sh`'s cycle line as
  `gh=rate_limited(bucket=graphql reset=<epoch> <age>)`, age-bounded to 15 minutes so a past limit
  cannot pass as a current one — and as `gh=recovered(bucket=… <age>)` once a later call succeeded,
  because a record is not a state. The failure text carries the words "rate limit", which is the
  phrase `objective.py`'s transport markers turn into `VERDICT=GH-RATE-LIMITED`.
* **The waits belong to the call sites that can afford them.** `GH_LIMIT_NO_WAIT=1` makes the layer
  record the limit and return at once (and bounds the LOCK wait to `GH_LIMIT_NO_WAIT_LOCK_S`, 5 s, so
  a busy box cannot queue a 90 s reader to death); the nine heartbeat tools set it, because they are
  killed at 90-420 s while the first documented backoff is 60 s — sleeping there converts a
  RATE-LIMITED verdict into a timeout. The shim is also `exec`'d, not spawned, so a caller's timeout
  or `run_bounded`'s TERM kills the helper instead of orphaning it mid-backoff against a bucket
  GitHub has already refused.
* **A shim is identified by its own sentinel line** (`harness-gh-shim-marker`), not by the helper
  beside it: the missing helper is the fail-open state, and keying identity on it made two shims
  resolve into each other and every gh call exit 127.
* **Conditional REST is a GET only.** `gh api <path>` (optionally `--jq`) stores its ETag per URL and
  replays a 304 from cache — free, because a 304 is not charged to the primary limit. The cached body
  is base64 (`byte-exact` on replay, binary included) and the cache is bounded, since every distinct
  poll URL earns an entry. Any shape whose output this layer would have to re-create by hand
  (`--paginate`, `--template`, `-H`, `-f`, a non-GET method) is left completely alone, and an
  unframeable response is returned AS-IS — never re-requested (a second request on a box that is
  being refused is exactly what the layer exists to prevent; the suite pins one request, no re-run).

**Design: an adapter, not a fork.** No harness file changes, so every cell stays on one harness
version — the convergence property this repo exists to protect — while the API surface becomes a
deployment concern. `install.sh` copies the shim to `$O/gh-rest/gh` and puts that directory **first**
on the daemon `PATH`, so controller, lanes, chains and merge workers all inherit it.

**Two deliberate refusals.** `pr merge --auto` is a GraphQL-only mutation (REST cannot express
auto-merge), so it is *delegated* — it fails loudly while GraphQL is refused rather than pretending
to have armed. And nothing is guessed: a failed REST call exits non-zero with the API's own message
instead of returning an empty result that would read as "nothing to do".

**The rule that keeps it honest:** a flag or filter the adapter does not model **delegates the whole
call** to the real `gh`. It never drops a flag and answers anyway — dropping one is not a slow answer,
it is a *wrong* one. Review of the first draft found that same bug at three severities, each of which
would have caused the failure the adapter exists to prevent:

| Dropped | Consequence |
|---|---|
| `pr list --head` | `chain-merge.sh` polls for "the branch's PR", gets the newest open PR, **merges an unrelated PR** and records the review marker against it |
| `issue list --label` | the three severity queries return the same unfiltered list, so every issue is tier 0 and P0-before-P2 ordering inverts (#8465) |
| `pr comment` output | `merge-one.sh` cannot extract the evidence URL and **parks every reviewed PR** with a false diagnosis |

**Verify it** (offline; drives a stub `gh`, needs no credentials, 28 assertions):

```bash
bash gh-rest.test.sh
```

The invocations in the suite are **copied from the callers** (`chain-merge.sh`, `refresh-candidates.sh`,
`fix-one.sh`, `merge-one.sh`), not invented — the first draft asserted shapes nobody used and shipped
two P0s green. They pin: `--paginate` returning concatenated arrays; positionals starting at `$3`;
a handler that falls through printing twice; REST's `open`/`true` vs gh's `OPEN`/`MERGEABLE`; REST
`/issues` including PRs; `--limit`; legacy commit statuses (a protection context that is not a check
run); a 200 whose body says `merged: false`; and a failing `--jq` exiting non-zero instead of looking
like "no rows".

**Known gap (tracked separately):** the install stamp and `check-deployed-drift.sh` fold their payload
over `$O/*.sh` only, so this adapter — like `launchd.plist.template` — is outside the deployed-bytes
record. Adding it in one place alone makes every healthy deployment read as drift, so it needs the
stamp, the drift checker and the selftest moved together.

---

## 4. Install

**On a cmux cloud cell**, `scripts/cloud-cell-bringup.sh --check` provisions the toolchain,
the network, the provider, `gh` auth/push, the target-repo clone, the dispatch pre-flight and
**the operational layer** — that last one from the agent-infra checkout already on the cell via
`pi-bootstrap/cell-install.sh`, and it REFUSES to print `CELL READY` if the layer cannot be
installed. Two things a `CELL READY` does NOT speak for, and which the operator still owns:
**`AI_REVIEW_GATE_KEY`** (push it in `keys.env`; what actually ENFORCES it is the
`ai-review-gate` check on each PR — `cloud-cell-supervisor.sh check` only WARNS, and says so)
and **`AGENT_INFRA_PATH`**, which the `AGENTS.md` this step
installs declares as a prerequisite — nothing on the cell sets it (`session-checks` and
`auto-sync` silently skip without it, and `sequence-enforcer` in gate mode reports an
unpassable checkpoint), so export it in the cell session's environment. `cell-install.sh` copies
the farm set that `pi-bootstrap/setup.sh` declares (parsed, not re-listed), every extension in
`manifest.json`'s ship-list except `cmux-session.ts` (a Linux cell has no cmux desktop app),
the skill tree, the sub-agent definitions, `templates/AGENTS.base.md` and a merged
`settings.json`; run it with `--verify` to check an existing cell with no writes.

**On a Mac (or any box you own),** do all four steps below from the ROOT of an agent-infra
checkout:

```bash
# 1. Run all four steps from the ROOT of an agent-infra checkout — the harness now lives there.
#    Put it where $O will point (default ~/orchestrator): the daemon executes $O/<script>,
#    not the shipped copies.
mkdir -p ~/orchestrator && cp scripts/orchestrator-harness/*.sh ~/orchestrator/
mkdir -p ~/orchestrator/logs ~/orchestrator/state ~/orchestrator/wip

# 2. Point it at your box. MOST values are overridable with a default; REPO is NOT — see below.
export OR=daniel-ospina/tortoise         # owner/repo
export REPO=$HOME/eldato/tortoise        # REQUIRED: the target repo's local main checkout.
                                         # FOUR scripts refuse an unset REPO by name:
                                         # orch-loop.sh and deploy-mac-orchestrator.sh exit 78;
                                         # install.sh exits 1 via die(); cloud-cell-quiesce.sh
                                         # exits 1 via ${REPO:?}. deploy-mac-orchestrator.sh
                                         # RELAUNCHES the controller, so its guard runs BEFORE it
                                         # stops the running one. Without that, a shipped default
                                         # naming one developer's home causes one of two things on
                                         # any other machine: REPO missing -> the controller dies
                                         # at startup and crash-loops under KeepAlive; REPO wrong
                                         # but existing -> the refresh aborts every cycle while
                                         # the controller keeps beating. ⛔ SEVEN shipped SHELL
                                         # scripts still carry a REPO default of their own — the
                                         # complete grep over `*.sh`, `retired/` and `*.test.sh`
                                         # excluded:
                                         # refresh-candidates.sh:18, report.sh:24,
                                         # cloud-cell-supervisor.sh:93,
                                         # deploy-crossbox.sh:23,
                                         # pi-reap-worktrees.sh:1174 (`${REPO:-$PWD}`),
                                         # stale-worktrees.sh:35 (`REPO="$PWD"`) and
                                         # stale-main-triage.sh:16 (`${1:-$PWD}`). The `$PWD`
                                         # three are the worst shape: $PWD is `/` under launchd,
                                         # so the default resolves to a real non-repo directory
                                         # and fails later as `not a git repository: /` instead
                                         # of at the REPO boundary. ⛔ TWO of the same class are not
                                         # shell scripts, and they are the rawest form of it — a
                                         # hardcoded home with NO env override, used only to import
                                         # the SDK: `goal-state.py:29`
                                         # (`REPO = "/Users/<someone>/Documents/GitHub/tortoise"`)
                                         # and `seed-goal-map.py:29` (the same literal passed straight
                                         # to `sys.path.insert`). Tracked separately. #1977 covers
                                         # the first and the third; the other five are untracked. So export REPO in
                                         # the daemon AND the session env (#1935).
export O=$HOME/orchestrator              # the harness state directory
export SCOPE=own                         # drain scope: auto (default) | own | broad.
                                         # A fleet runs ONE broad box; the rest pin own (section 5).
                                         # install.sh renders this into the plist (launchd
                                         # inherits no shell env) and refuses a bad value.

# 3. Render + install the launchd agent (does NOT load it). Invoke it BY PATH, from that same
#    repo root: install.sh resolves `launchd.plist.template` from ITS OWN directory, so
#    `cd ~/orchestrator && ./install.sh` dies with "missing template" — step 1 copies only *.sh.
bash scripts/orchestrator-harness/install.sh

# 4. Start it when you mean to — and have the start PROVEN, not assumed.
#    install.sh --start renders, then `launchctl enable` → `bootout` → `bootstrap` (falling back to
#    the legacy `load` if bootstrap fails), then verifies the label has a PID **and** that
#    ~/orchestrator/heartbeat advanced. It exits non-zero with one actionable line if either fails.
#
#    Two tunables, both optional: `START_TIMEOUT` (seconds to wait for that pid+heartbeat, default
#    30) and `LC_HB_STALE` (how old the heartbeat may be before a LOADED job counts as "not
#    cycling", default `2*CYC + 300` — derived from this cell's cycle, because a fixed bound fails a
#    healthy CYC=900 cell). A validation run (no flag) touches no launchd state at all.
#
#    ⛔ NEVER `launchctl load -w` / `unload -w` here: `-w` writes a PERSISTENT Disabled override
#    (`man launchctl`), so an unload/load pair whose bootstrap fails leaves the controller
#    removed AND disabled, silently. Measured 2026-10-17: 48 min of dead dispatch, then 19 more
#    (agent-infra#1975).
bash scripts/orchestrator-harness/install.sh --start
```

Step 3 also records **which harness commit this box runs** in `$O/.agent-infra-stamp.json`
(agent-infra#1745; see §9). Run `install.sh` from the agent-infra checkout as shown — if the source
is not a git repo the record reads `UNKNOWN` and `check-deployed-drift.sh` exits 2 rather than
passing, which is the intended fail-closed behaviour and not an install failure.

```bash
# liveness / stop
cat ~/orchestrator/heartbeat                 # epoch seconds, should be < ~5 min old
tmux ls                                      # lane-*, chain-*, merge-*, fix-*
```

`install.sh --uninstall` removes the agent (`launchctl bootout`), **reads the domain back**, and only then
deletes the plist — if the label is still **LOADED** it exits non-zero and keeps the plist instead of
printing ✅ (a `KeepAlive` job sitting inside its respawn throttle is loaded with NO pid, which is why
the verdict is not a pid test), and if the read itself fails it exits non-zero too rather than calling an
unreadable domain "removed". It writes **no** persistent Disabled override, so a later `--start` is a
plain start rather than a start that has to fight a sticky disable first.

Every mutating path (`--start`, `--restart`, `--uninstall`) first checks two things, and refuses with
one line rather than acting if either fails: **`$HOME` must be the real home** (a sandboxed `$HOME`
acts in the real user's domain — agent-infra#446; tests opt in with `ELDATO_ALLOW_TEST_HOME=1` plus a
`launchctl` stub on PATH), and **a job already loaded under this label must be loaded from this
plist** — `launchctl bootout <domain> <path>` resolves the removal by the LABEL it reads out of that
plist (measured), so without that check a sandboxed run would remove the production controller. A
third read guards both of those: `launchctl print` failing is **UNKNOWN**, never "not loaded", so an
unreadable domain (or an unreadable account record) makes the run refuse instead of acting on a guess.

`ELDATO_ALLOW_NON_DARWIN=1` is the suite's test-only bypass of the installer's macOS precondition (the
only automated gate runs on Linux, and `--start`/`--uninstall` are the incident's own path). It is the
same discipline as `ELDATO_ALLOW_TEST_HOME=1` and never applies to a normal run.

Run the offline self-test first — it needs no network, tmux server or git writes. **Every check
exercises the shipped script** (it extracts the real classifier, `sess()`, the claim block and the
reaper, or runs `install.sh` for real) rather than re-implementing the logic — a test that
re-implements the fix passes on the broken copy and proves nothing. `need()` fails a check whose
extraction comes back empty, so a check cannot pass by driving nothing; the live total is printed
by `./selftest.sh` rather than quoted here.

```bash
./selftest.sh          # run it for the live list. Covers: syntax, exact session matching, the
                       # fail-closed gate classifier, claim atomicity and stale-claim recovery,
                       # the reaper's keep/reap decisions, rejection of a hostile branch name,
                       # install.sh rendering with a hostile path, limit-default consistency,
                       # placeholder parity, the daemon PATH (shim exclusion + execute-probe) and
                       # the failed-count fallback, README overclaim guards, credential scan,
                       # repo-aware scout provisioning and the permanent/transient refresh split
                       # (refresh-scout.test.sh, #1736)
```

**The gate key only reaches the daemon if it is a FILE.** `install.sh` deliberately does not copy a
secret into a world-readable plist, and launchd inherits no shell environment — so an env-only
`AI_REVIEW_GATE_KEY` is reported as insufficient, not as "present". The box cannot merge without it.

### Tuning (10-core / 32 GB box — the values that were actually used)

| Var | Value | Why |
|---|---|---|
| `MAX_LOAD` | `cores*10` (100 on a 10-core box; sanity ceiling) | dispatch stops above this 1-min load |
| `MAX_LANES` | **derived**: `10#$_NCPU * 5 / 2` — 2.5× cores, floored (25 on a 10-core box, 10 on a 4-core box, 10 on an unprobeable host) | concurrent implementation lanes. **Capacity gates dispatch, not a lane count** (owner ruling, 2026-10-17, verbatim: *"dispatch should be gated on capacity, not on number of lanes. max lanes 8 is too low. that needs to be configured to 2.5x the number of CPUs"*). The shipped default was a flat `4`, and the box this was measured on had its plist **pinned** at `8`: `[cap] load=79/100 lanes=9/8 … [dispatch] skipped (lanes=9>=max_lanes=8)` — 21 points of load headroom and comfortable swap/memory, so dispatch was refused for a lane count while capacity was available. A **valid** pin (plist/`keys.env`) still wins and is never recomputed; an **invalid** one is refused by `install.sh` and repaired by the loop to the derived default; a derived value that fails `is_limit` falls back to `10`. ⚠️ The plist **pins** the number, so a box picks this default up only on a fresh `install.sh` render. ⚠️ `2.5 × cores` is ALSO `LOAD_SUSPEND_THRESHOLD`'s default (`docs/ops/load-policy.md` §2) — that is a 1-minute **load** threshold, this is a count of **lanes**; they are not one ceiling |
| `MAX_REVIEW` | `4` | concurrent `merge-<PR>` reviewers |
| `MERGE_PRIORITY_AT` | `25` | above this many **unowned** open PRs (nothing currently working them — no `fix-`/`merge-` session, no live cross-box claim, no unconsumed `needsfix-*` marker), **merging takes priority**: dispatch of new lanes stops (unless none are running) and reviewer **and fixer** headroom rises to `MAX_REVIEW+2` / `MAX_FIX+2`. It was `10` against the TOTAL open count, which capped the fleet on a healthy queue (measured 2026-10-16: `lanes=1` of 32, 59-86% CPU idle, on a cell logging `merge-priority (20 open PRs — draining)` with 17 of those 20 already `BEHIND`/`DIRTY`) |
| `MAX_FIX` | `3` | concurrent `fix-<PR>` fixers |
| `MAX_FIX_TRIES` | `3` | per-PR fixer attempts before it is left alone |
| `MIN_SWAP_FREE` | `600` | MB. ⛔ Two limits worth knowing before trusting it: on a host with **no swap at all** (`SwapTotal: 0`, i.e. a container) the gate is **INERT by design** — `swap_total=0` reads as uninitialised, not as pressure (`orch-loop.sh:1438` for the gate, `:1413-1415` and `:1431` for the rule), so capacity there is decided by load and memory only — and on a host that **has** swap the metric is a level, not a counter: swap that has been used stays used, so a past spike holds the FREE level down and the gate flaps across its own threshold (measured `swap_free=549M<=min_swap_free=600M` at load 5.4 of a 64 ceiling; agent-infra#1961). `MIN_MEM_FREE_MB` is the metric that reflects the present |
| `MIN_MEM_FREE_MB` | `512` | MB of *available* memory (`MemAvailable` on Linux, else `MemFree`+`Cached`; `free`+`inactive` on macOS). macOS shows pressure as compression with swap flat, so swap alone does not see it |
| `BATCH` | `2` | issues dispatched per cycle |
| `CYC` | `240` | seconds between cycles |
| `STALE_MIN` | `40` | a worker whose log has not grown in this many minutes is presumed hung and its session is killed (§6) |
| `LANE_TIMEOUT` | `2400` | wall-clock limit on a lane's `pi` run (s) |
| `REVIEW_TIMEOUT` | `1800` | wall-clock limit on a reviewer `pi` run (s) |
| `FIX_TIMEOUT` | `2400` | wall-clock limit on a fixer `pi` run (s) |
| `SWEEP_MAX_AGE` | `600` | (s) the longest a `304 Not Modified` may reuse the cached PR listing before the sweep forces a full one. A completed check run does **not** reliably change the listing's ETag, so this floor is what stops a green PR sitting behind a cached "unchanged" forever (#1762) |
| `SWEEP_MIN_REMAIN` | `20` | when `x-ratelimit-remaining` is at or below this, the **next** sweep is deferred to the reset rather than hammering the shared bucket (#1762) |

⛔ **`STALE_MIN`, `SWEEP_MAX_AGE`, `SWEEP_MIN_REMAIN` and the three wall-clock timeouts are NOT rendered into the plist.** The template
carries 16 placeholders — the ten limits above them, `SCOPE`, `O`, `REPO`, `OR`, `PATH` and `HOME`
— and no `__STALE_MIN__`/`__SWEEP_MAX_AGE__`/`__SWEEP_MIN_REMAIN__`/`__LANE_TIMEOUT__`/`__REVIEW_TIMEOUT__`/`__FIX_TIMEOUT__`. So exporting one
of these and re-running `install.sh` silently has no effect, and a hand-added plist key is
overwritten by the next render. Set them through `$ENV_FILE` on a cell, or edit the defaults in the
scripts.

⛔ **And every limit that IS rendered must be a whole number, in range, and not a template token.**
The ten are substituted verbatim — deliberately not routed through the escaping path, since a whole
number has nothing to escape — so `install.sh` validates each before rendering: digits only, at most
nine of them (`[` errors at or above 2**63, and an errored test reads FALSE, which OPENS the gate it
configures), `CYC` additionally at least 5 (see below), and no `__…__` pattern, because the sed rules run in order and `OR=__MAX_LANES__`
therefore rendered as the default (then `4`, now 2.5× cores) and still exited 0. It then renders to a **temp file**, lints that, asserts
no placeholder survived, and only then moves it into place — the redirect truncates its target before
`sed` runs, so rejecting after writing straight to `$PLIST` left the live plist empty and the next
`launchctl unload && load` failed. The loop coerces the same values on its own, so a bad plist is
refused at both ends, and every limit is coerced *before* its first arithmetic read, because `[ -ge ]`
on a non-number is FALSE and a false test in the gate chain OPENS the gate.

⚠️ **`0` is a valid integer for most limits** — for `MIN_SWAP_FREE`/`MIN_MEM_FREE_MB` it means the
gate can never bind (disabled). Set one of those only when that is what you mean.
⛔ **`CYC` is the exception: it has a 5-second floor.** It is the one limit where `0` is not merely
useless but harmful — `sleep $(( CYC - JIT + RANDOM % (2*JIT+1) ))` becomes `sleep 0` or a negative
argument, so the controller revisits every cycle with no delay and hammers the GitHub API.
`install.sh` refuses `CYC<5` at render time and `orch-loop.sh` floors a zero/bad value to its 240s
default, so the two ends cannot disagree. `CYC=5` (a deliberately fast cycle) is still accepted.

**The CONTROLLER's spawn decisions are load-gated — not just lane dispatch.** A Mac reboot lands in an indexing
storm (Spotlight, `PerfPowerServices`, `duetexpertd`) that routinely pushes 1-min load past 200. The
lane gate already respected `MAX_LOAD`; the merge sweep did not, so a fresh boot got six reviewers
piled onto the spike. `can_spawn()` now guards the five spawn sites in `orch-loop.sh` — conflict
fixer, rail merge worker (GREEN), re-record fixer, re-record merge worker, CI-red fixer — while the
cheap actions (`gh pr ready`, `gh run rerun`, and `gh pr merge` in *gate* mode) stay ungated, so
**gate-mode** merges keep flowing during a spike and nothing is
starved. ⚠️ **On a rail-mode repo the merge is itself a gated worker, so it does NOT keep flowing.**
agent-infra#1764 moved the rail into a `merge-<PR>` worker (the inline rail run measured ~27 s of
BLOCKED controller cycle, halting dispatch); that worker is slot- and load-gated like every other
spawn, so a spike holds rail merges back with the rest. That is the intended trade, not an
oversight. ⛔ **That is the controller's *decisions*, not every spawn.** Three worker entry points
spawn a `pi` agent with no `MAX_LOAD` read of their own — `chain-<N>` → `merge-one.sh` (the
first-review path for every own-lane PR), `fix-one.sh` → `merge-one.sh`, and `adopt-fix.sh` →
`fix-one.sh`; tracked as agent-infra#1720.

⚠️ **`can_spawn()` tests load only.** The available-memory gate applies to *lane dispatch*, not to
these five spawn sites — the two cover different populations. Raising `MAX_LOAD` therefore narrows
the band in which the spawn sites hold back (`16`–`99` is now permitted, where `16` used to hold).
Closing that needs `can_spawn()` to consult memory as well, which changes the one-line shape its
self-test extracts from the shipped file; tracked as agent-infra#1732 rather than half-done here.

**Swap, not lanes, is what actually throttles an 8 GB box.** Observed at 15 concurrent workers on the
original 8 GB host: `swap_free=588M` → dispatch correctly refused. On THAT host raising `MAX_LANES`
alone buys nothing; it just moves the pressure into the compressor. It is not a general rule, and the
lane ceiling was a second, independent cap: on today's 32 GB host capacity was available (21 points
of `MAX_LOAD` headroom, comfortable swap and memory) while dispatch was refused by a lane count —
which is why `MAX_LANES` is now derived from cores instead of pinned to a small literal (§4).
`swap_total=0` right after boot is treated as
*uninitialised*, not as pressure (that bug silently blocked all dispatch for the first minutes
after a restart until it was fixed) — and that same rule makes the gate **inert for ever** on a host
that never has swap, which is a fact to know rather than a defect to fix here (agent-infra#1961).

**The capacity probes are portable: Linux cell + macOS host.** `#1702`. Every probe used to be a
macOS primitive, so on a Linux cell `load1()` returned empty (the `MAX_LOAD` gate could never bind),
swap read as `0` (the gate skipped by its own "uninitialised" rule), and the reaper's
`stat -f '%m'` became an arithmetic error that killed the controller one cycle after its first
dispatch — every lane/merge/fix writes the log the reaper stats. Each probe now has a Linux path
(`/proc/loadavg`, `/proc/meminfo`, `nproc`) and a macOS one (`sysctl`, `vm_stat`), and the reaper's
mtime probe is a GNU-then-BSD `stat` ladder with a numeric guard (GNU first on purpose: GNU
`stat -f` writes the filesystem listing to **stdout** before exiting 1, so a BSD-first `||` ladder is
the bug itself).

⚠️ **Available memory was the fifth macOS-only probe, and the only one that fails CLOSED.** The gate
is deliberately "UNKNOWN is not ample" (`mem_probe_failed` → do not add work), so with a `vm_stat`-only
probe every Linux cell set `MEM_UNKNOWN=1` on every cycle: load, lanes and swap could all be healthy
and the memory gate still bound — the controller completed cycles, logged `mem_probe_failed` and
dispatched nothing, which is a *different* false green from the one #1702 removes. `mem_avail_mb()`
therefore reads `/proc/meminfo` (`MemAvailable`, else `MemFree`+`Cached`) on a cell and keeps the
`vm_stat` `free`+`inactive` parse on macOS. The fail-closed ruling for a genuinely unreadable probe is
unchanged — only its Linux measurability is.

A load reading that is *unreadable* stays the documented **fail-open** (`can_spawn()` defaults it to
`0`): both supported platforms are measurable now, and failing closed on an unreadable probe would
turn "no load back-pressure" into a permanent controller outage. `install.sh` still refuses to run
off macOS (it renders a launchd plist) — the portability that matters is `orch-loop.sh`, the file
`cloud-cell-supervisor.sh` starts.

---

## 5. Merge policy and safety invariants

1. **The gate is never bypassed — but WHICH gate is the repo's own answer (agent-infra#1764).**
   The required-check list is read from the target repo's branch protection, not hardcoded. A repo
   that requires `ai-review-gate` (tortoise) must have it `<SUCCESS>` —
   `SKIPPED`/`NEUTRAL`/absent do **not** count, because that means no signed review exists — and
   `merge-one.sh` additionally refuses to merge if the recorded head ≠ the current head, so a
   post-review push invalidates the evidence automatically. A repo that does NOT require it
   (agent-infra: `pipeline-compliance`) is merged through its **own rail**
   (`scripts/admin-merge.sh`), which posts its own head-bound evidence; the harness never falls back
   to a raw `gh pr merge` there. Either way the fail-closed rule holds *inside* the repo's own
   required set: a required check that has not reported is `PENDING`, never green, and an
   unreadable protection endpoint uses `FALLBACK_REQ` (non-empty), never an empty set.
1b. **One owner per PR, per box.** Every path into `merge-one.sh` (the lane's `chain-<N>`, a
   `fix-<PR>`, and the controller's sweep) takes the same atomic `state/mergeclaim-<PR>.lock` first.
   Without it a freshly opened PR gets two concurrent reviewers racing one head: duplicate evidence
   comments, duplicate `record-review` writes, and an `ISSUES`/`CLEAN` interleaving.
   **This is a local file, so it serialises one box only** — two boxes sharing a repo are not
   coordinated by it (§7.2b, tortoise#5052).
2. **The reviewer must state a plain outcome.** Its final line is exactly `CLEAN <comment-url>`
   or `ISSUES <n>`. A CLEAN comment may not assert an unresolved outcome. The enforcer is the
   evidence veto in `scripts/record-review.sh`, and its vocabulary is `NOT CLEAN`, "requires human
   attention/input/review", "unresolved issues",
   "auto-fix stalled/failed/reached/converged/aborted/stuck", "test review capped",
   `[ADVERSARIAL-BOUND]`, and a **counted** `N issues remain`. The count is
   deliberate: a bare "issues remain" is NOT matched, because the veto must not false-refuse the
   legitimate clean phrasing "No issues remain after the fixes" — which also means a CLEAN comment
   whose body says (uncounted) that issues remain does pass the veto. Quote the gate's list, not a
   wider one.
3. **Scope adapts to the queue — and can be pinned.** `open PRs > 10` → **broad** mode: the sweep
   covers every non-draft PR in the repo except the branch classes it deliberately never touches
   (`design/`, `scope/`, `dependabot/` — the selector is
   `select(.headRefName|test("^design/|^scope/|^dependabot/")|not)`), not just this box's. `≤ 10` →
   own branches only (`*-tm`, `*-cap`, `fix/*`). Broad mode is how this box drains a peer's queue;
   it is also how two boxes accidentally duplicate work if they both run broad. `SCOPE` overrides
   the count: `auto`
   (default — the rule above), `own` (own-only even above the threshold), `broad` (broad even below
   it); any other value is fatal, so a typo cannot silently pick a scope. In a multi-box fleet
   exactly one box takes `broad` and the rest pin `SCOPE=own` (measured 2026-10-13: an unpinned
   fresh cell logged `[scope] open=14 -> BROAD` and auto-armed #8425/#8420 within ~25s).
   ⛔ **This is a partition, not coordination.** Ownership is still inferred from *local*
   branches/worktrees, which are invisible across boxes, so two `own`-pinned boxes can still race
   the same PR (§7.2b, tortoise#5052) — the pin must not be mistaken for a claim registry.
   ⛔ **And it is not the cross-box barrier for any operation.** It selects PR branches by naming
   convention, which every box shares; what excludes a concurrent holder is the claim registry, now
   measured per operation in **§7.2d** (agent-infra#1908). That measurement retires the pin's
   *safety* role for dispatch and review and keeps an exclusion requirement on the landing row.
4. **Drafts are deliberately excluded** from the sweep — a peer's draft PR is not yours to
   merge. The cost is that a *peer's* draft stalls until they ready it. Our **own** lanes' drafts do
   not: the sweep selects drafts whose branch matches the harness's own patterns (`*-tm`, `*-cap`,
   `fix/*`), readies them once, and sweeps them from the next cycle (see §7.2).
5. **Workers never touch the main checkout.** Every lane runs in `.worktrees/tm-<N>`; the
   controller only reads. `lane.sh` instructs its agent not to create or remove worktrees.
6. **No `task` sub-agents.** Extensions that would gate a nested agent (`review-enforcer`,
   `verification-gate`, `loop-enforcer`, `sequence-enforcer`) are explicitly disabled for
   workers, and the *harness* is the review gate instead.
7. **The key is the crown jewel.** The box that holds `AI_REVIEW_GATE_KEY` can authorise
   merges. It lives at `~/.pi/agent/.ai-review-gate-key`, is never written to logs, and is
   never copied into this bundle.
8. **One controller.** `.orch.lock` is created with `set -o noclobber`; a second start exits
   immediately, and a lock whose PID is dead is reclaimed.
9. **GitHub data never reaches a shell.** Inputs from the API are validated before use:
   `safe_ref` admits only `[A-Za-z0-9._/-]` **and** requires `git check-ref-format --branch`; PR ids
   must be all digits (`is_num`); worker arguments travel in a file and the daemon launches
   `merge-one.sh --argv <file>`, so no PR-derived value is embedded in the `sh -c` string that
   `tmux new-session` executes **on any live path**. (`retired/auto-loop.sh` still contains the old
   unsafe interpolation, annotated in place — it is unreachable from the live scripts and exists
   only as history; do not reuse it.) Branch names were the hole: git **permits** `'` `;` `$` `` ` `` `&` `|`
   `(` `)` `{` `}` `"` `<` `>` `#` in a ref (only spaces are forbidden, and `${IFS}` supplies
   those), so a fork PR on `fix/x';touch${IFS}/tmp/x;#` achieved arbitrary command execution on the
   host holding the merge key. Reproduced before the fix; the self-test now pins the validator.

### 5.3 Untrusted input and worker containment — read before running this unattended

This harness passes **attacker-controlled text** to language-model agents with shell access. Be
clear about what is and is not enforced:

- **Not sandboxed.** The spawned reviewer and fixer run with `AGENT_SKIP_REVIEW_GATE=1`,
  `ELDATO_SKIP_VGATE=1`, `AGENT_ALLOW_MAIN_EDITS=1`, `SKILL_ENFORCER_DISABLED=1` and
  `LOOP_ENFORCER_DISABLED=1`, with `bash` and `gh` on `PATH`. "Do NOT merge" and "do not touch the
  main checkout" are **prompt instructions, not controls**.
- **Prompt injection is possible.** `fix-one.sh` reads the PR's comments into the fixer prompt as
  the authoritative review, and `merge-one.sh` feeds the reviewer the PR title, body and diff. A
  malicious PR body can therefore attempt to steer an agent that has shell access.
- **What actually constrains it.** `gh pr merge` is reached only on a **gate-mode** repo (one whose
  branch protection requires `ai-review-gate`), and only after `record-review.sh` has written a
  signed marker for the exact head (§5.1), with `merge-one.sh` additionally waiting for
  `ai-review-gate` to read `SUCCESS`. On a **rail-mode** repo (agent-infra) the harness instead
  invokes `scripts/admin-merge.sh`, which posts its own head-bound evidence and merges with
  `--admin`; the harness does not call `gh pr merge` there at all, and auto-merge is deliberately
  never armed. The same refusal is one layer deeper: a merge worker whose OWN branch-protection
  read fails (REQ_SOURCE=fallback, no REQ override) exits 5 before reviewing or merging anything
  — which covers every ingress, including `chain-merge.sh` and `fix-one.sh`. A rogue *agent* cannot merge through the harness path; it could still `gh pr merge`
  or `git push` directly if the token permits, which is a property of the token, not this code.
- **What is deliberately not done:** the gate key is never placed in a prompt, a plist, a log or a
  command line, and no script creates a secret-bearing file.
- **Open item (tortoise#8246):** contain the workers properly — a read-only key path, no
  merge-scoped token during review, and treating PR content as delimited data rather than
  instructions. Until then, run this on a box whose GitHub token you would accept being used by an
  agent that has read a hostile PR body.

---

## 6. Operating notes

### Deliberate stop (handing the laptop to a human)

The ritual, in order — the point is that **no uncommitted work is lost**:

1. `bash scripts/orchestrator-harness/install.sh --uninstall` (from the checkout root, as §4): the
   installer resolves `launchd-cycle.sh` and `launchd.plist.template` from its OWN directory, so the
   CHECKOUT's copy is the guarded one — a copy that lacks `launchd-cycle.sh` refuses with "missing
   …launchd-cycle.sh" (fail closed, never a silent degrade to the legacy verbs), while a pre-#1975
   `install.sh` still sitting under `$O` has no guard at all, so never run that one — `bootout` + remove
   the plist, so it does
   not restart on boot and no persistent Disabled override is written (which is what `unload -w` did;
   agent-infra#1975). It READS THE DOMAIN BACK afterwards — "is the label still loaded", not "does it
   have a pid", because a `KeepAlive` job inside its 10s respawn throttle is loaded with no pid — and
   fails if the job is still there.
2. `pkill -f "[b]ash $O/orch-loop.sh"` — SCOPED on purpose: an unscoped `-f orch-loop.sh` also
   matches peer controllers, fixtures and tests (`deploy-mac-orchestrator.sh:51-56` measured four),
   and `[b]` keeps the pattern from matching the pkill command line itself. ⛔ **Verify before you
   delete the lock:** the scoped pattern does NOT match a `cd ~/orchestrator && ./orch-loop.sh`
   start (`bash ./orch-loop.sh`), so run `pgrep -fl '[o]rch-loop'` and confirm YOUR controller is
   gone. Removing the lock while it still sweeps lets the next start pass `acq()` — two autonomous
   controllers on one PR queue, which §5.2/§5.3 assume cannot happen. Then `rm -f $O/.orch.lock`.
3. Freeze workers: `tmux kill-server` (or kill sessions individually) and check for strays.
4. Capture every dirty worktree: `git -C <wt> diff HEAD > $O/wip/<name>.patch`, plus a
   copy of untracked files and a `.status` file recording `git status --porcelain`.
5. Post a note on the coordination issue naming the open PRs, so a peer box keeps draining.

Durable state survives a reboot regardless: the signing key, review records, the worktrees'
`.git`, and every PR on GitHub.

### Restart recovery (what has to be re-derived by hand)

Workers do not survive a reboot and their tmux sessions are gone, so the controller has no
record that they existed. Today this is recovered by reading `git worktree list`, the
`$O/logs/*.log` tails, and the `wip/` patches. **This is the main operational weakness — see
§7.1.**

### Detecting a hung worker (do this first if the queue stops moving)

`pi -p` has no internal timeout, so a reviewer or fixer can hang indefinitely — and because the
concurrency caps count **tmux sessions**, one hang permanently occupies a slot. Observed
2026-10-12: three merge workers hung for 6–9 hours (one had spawned a `find /` that ran for 8
hours), so half the merge capacity was dead weight overnight while the queue looked busy.

```bash
# a worker whose log has not grown in 40+ minutes is hung
tmux ls -F '#{session_name}' | grep -E '^(merge|lane|fix)-' | while read s; do
  f=~/orchestrator/logs/$s.log
  printf '%s silent %ss\n' "$s" "$(( $(date +%s) - $(stat -f %m "$f") ))"
done | sort -k3 -n -r | head
```

`orch-loop.sh` now reaps these itself (`STALE_MIN`, default 40): the session is killed and the PR
is re-dispatched on the next sweep, with `claim_live()` freeing the dead owner's claim.

⛔ **That is ONE signal over ONE population** — the controller's own tmux sessions, judged on log
mtime, and only while the controller itself is alive. It also decides on a **single** mtime sample,
with no CPU tolerance and no second observation. A lane on a box with no controller, or a process
that left no log, is outside it too. §6.5.1 states the requirement; do not read this paragraph as
satisfying it.

### Reading the logs

`$O/logs/orch-loop.log` is the controller's decision log; every line is prefixed by a tag:

```text
[scope] open=24 -> BROAD (auto)             ← or (pinned SCOPE=own) / (pinned SCOPE=broad)
[cap] load=7/100 lanes=4/4 mem_avail=11761M/512M swap_free=588M/600M   ← every gate names its ceiling
[dispatch] load=7 lanes=4 -> 4429 4489
[refresh] queue=READ(7) — every priority tier was READ; 7 candidate(s) listed (agent-infra#1931)
[refresh] +#4508 CLEAN -> backlog
#8219 FAILED:ai-review-gate          ← per-PR verdict for the required checks
#8192 fixer attempt 1                ← routed to a fixer, not a re-record
...
[cap] load=104/100 lanes=4/4 mem_avail=11890M/512M swap_free=588M/600M
[dispatch] skipped (load=104>=max_load=100)   ← and WHY, naming the binding gate
```

⛔ **`backlog=0` alone is never a clearance** (agent-infra#1931). The cycle line carries the pool's
READ state beside it, and `EMPTY` is the only form that means "no work":

```text
=== <date> load=2 lanes=0 backlog=0 queue=UNREADABLE(3m) ===     ← BLIND: the last pool read FAILED
=== <date> load=2 lanes=0 backlog=0 queue=PARTIAL(P0-blocker)(3m) ===  ← a SUBSET, not a pool
=== <date> load=2 lanes=0 backlog=0 queue=EMPTY(12s) ===          ← read successfully, genuinely empty
[dispatch] backlog empty queue=UNREADABLE(3m)                    ← the claim carries the state too
```

The age is part of the token on purpose: a value frozen by a refresh that stopped writing cannot pass
as a fresh reading. `UNKNOWN` means no pass has EVER recorded a read — it is not `EMPTY`.

---

## 6.5 Self-healing: wedges

> ⛔ **REQUIREMENTS, not a description of this tree.** Each item is what a conforming install MUST
> do, with the measurement that motivates it, and each ends with the honest status of the shipped
> code today — `IMPLEMENTED` with its `file:line`, `PARTIAL` (naming which half is missing), or
> `GAP` with the tracker. Read it as the standard a box is judged against. A requirement nothing
> implements must never read as a feature, because the whole class it describes is INVISIBLE: the
> box looks alive and does nothing. Line numbers are as of this commit — a `file:line` here is a
> pointer to the code that exists NOW, and a rewrite (agent-infra#1976 rewrites §6.5.6's) moves it.
>
> The owner requirement, verbatim: *"the harness must automatically un-wedge lanes, automatically fix
> PRs, and automatically dispatch issues."* Those are one requirement seen from three sides —
> something must NOTICE, DECIDE and ACT on a schedule that does not depend on the controller being
> healthy. **THIS section specifies the first side — un-wedging — in full.** The other two are
> specified where they are built and are not repeated here: fixing a PR is §5 (`merge-one.sh` marks
> `needsfix-*`, `fix-one.sh` fixes and re-runs the chain) and dispatching issues is §2/§7.2d
> (capacity-gated dispatch against the claimed backlog). Both are IMPLEMENTED; neither is
> re-specified below, so do not read this section's statuses as verdicts on them.

### 6.5.1 A stuck lane is reaped, on a bound that is a number

**MUST.** Every lane in the fleet's own enumeration whose progress signal has not advanced for a
stated bound is reaped with no human. The bound is a **number**; it is judged against the lane's
**OWN** expected duration (never another class of process's); and the decision takes **two
consecutive observations**, or an explicit CPU tolerance, never one reading — a single sample cannot
tell a long model call from a freeze.

**Why (measured).** One **4-core cell** — §4's derivation gives that box `MAX_LANES=10` — held **10
lanes aged 17–29 hours**, each with *minutes* of CPU and no progress, plus a **5.8 GB** abandoned
worktree. That is a box at its lane ceiling, with a full disk, producing nothing — and nothing reaped
any of them. A human found it by reading a report, which is the gap stated exactly: the condition had
no signal of its own.

**Status: PARTIAL — the cell's own doctor now reaps the fleet's harness namespace with two
observations, a CPU tolerance and a human-ancestry gate (§6.5.7), and the controller's own lanes are
still reaped by `orch-loop.sh` with the older one-sample rule. What is NOT met: the doctor exists
only where `cloud-cell-supervisor.sh start` launched it (a Mac cell's launchd job still does not run
it), and the controller's own `reap_stale_workers()` — which runs only while the controller is alive
— still uses one mtime sample, no CPU tolerance, and one 40-minute bound for `lane`, `merge` and
`fix` alike. The doctor's bound is per-run and requires the lane's subtree to show no CPU delta, so
the two in-tree reapers disagree; the doctor is the one this MUST is being met by.**
`reap_stale_workers()` (`orch-loop.sh:420`) reaps only the controller's OWN
`lane|merge|fix` tmux sessions, on log-mtime staleness past `STALE_MIN=40` (`orch-loop.sh:409`) —
one signal, one population, and only while a controller is alive. The fleet-level reapers are
launchd jobs (`templates/launchd/com.tortoise.branch-reaper.plist`,
`com.eldato.pi-session-reaper.plist`), i.e. **absent on a Linux cell** (agent-infra#1864, #1927). The
consolidated disk reaper is the exception since #2048: ONE installer schedules it on both (a systemd
timer on a cell, `com.eldato.disk-reaper` on a Mac, the same pass and flags).
`tools/fleet/lane_liveness.py:68` deliberately REPORTS `dead` and files an issue, and reaps nothing.
The worktree reaper ships **dry-run** and preserves anything with uncommitted work
(`pi-reap-worktrees.sh:8-32,194`). What is missing is not another kill. The process reaper in §6.5.3
already exists — and #1859, closed 2026-10-16, found it **dead because its script had been recovered
and was never reinstalled**: it survived only as
`~/.pi/agent/state/recovered-1161/pi-reap-orphans.sh.with-ancestry-gate`, with no job pointing at it
(its last run was Sep 16, as of that close). That is the same defect as §6.5.6, stated twice in three
days: **a fix that exists is not a fix.** So the live trackers are agent-infra#1244 (the lane-level
rule exists only as prose), #1862/#1863 (restore the orphan reaper **and schedule it**), and #1927 (a
scheduler the cells run).

### 6.5.2 The instrument that decides must itself be bounded

**MUST.** The read that decides whether a lane is wedged has an **overall wall-clock budget for the
whole read** — not a per-call one, which bounds each `cmux`/`ps` call and lets total cost grow with
the number of lanes. When the budget expires the read returns **FAILED**. "Cannot read" and "nothing
there" must never render identically, and a timeout must never become an empty successful result.

**Why (measured).** The lane snapshot took **>60 s under load**, and its caller — `pr-doctor`, the
pass whose whole job is un-wedging lanes — refused itself. The whole failure is ONE log line, wrapped
here for width with the interpreter path elided (the log carries this box's home):

```text
[<ts>] pr-doctor: LANE READ FAILED -- cannot dispatch this pass: lane-actions read failed rc=1:
  lane-actions: lane-status.py failed: TimeoutExpired(['/usr/bin/python3', '<…>/lane-status.py',
  '--json', '--sample', '12.0'], …)
```

Five message variants carry that one line. Counted over the **distinct failed passes** in the log
(log-LINE counts in brackets, because a wrapped line is not a second pass) at the 2026-10-18T00:42Z
read — **800** passes, 1318 lines: `lane-status.py failed: TimeoutExpired` **483** (798), `REFUSING a
DEGRADED snapshot` **247** (425), `snapshot UNVERIFIABLE (N of an unknown fleet size) -- re-scanning
without the cache` **61** (80), and **9** in two rarer forms (`TIMEOUT … no answer within 300s`, 1
pass / 2 lines; and `rc=-1: TimeoutExpired` under a CommandLineTools interpreter, 8 passes / 13
lines). In the third the cached scan
declines to vouch for a roster it cannot see whole, so it re-scans uncached, which is the read that
times out in the first; in the second the reader refuses a snapshot it can see is degraded. Either way
the cost grows with the number of lanes, the only bound on the WHOLE read is a CALLER's, and the pass
dies instead of returning a verdict. The log keeps growing, so treat these as a dated snapshot, not a
constant.

Measured in `~/.pi/agent/state/pr-doctor.log`, read 2026-10-18T00:42Z:

| day | failed passes | successful passes | share failed |
|---|---|---|---|
| 2026-10-16 | 148 | 192 | **44%** — the “every other run” figure |
| 2026-10-17 | 47 | 149 | 24% |

Counted as distinct timestamps, with `pass:` lines as the successes. The un-wedger could not read the
thing it un-wedges for a large share of a day, and each failed pass dispatched nothing.

**Status: PARTIAL — a WHOLE-READ budget now exists for the lane roster, and the reader it wraps
still has none of its own.** The polarity is IMPLEMENTED: `lane-status.py` raises `SystemExit(3)`
rather than publish an empty roster; `lane-actions.py` refuses a `degraded` snapshot
(`_refuse_if_degraded`); `queue-dispatch.py` raises `LaneReadError` naming the timeout instead of
returning `[]`; `pr-doctor.py` refuses the pass **when it has work to place** — and deliberately
stays exit 0 on a blind read with nothing classified, because manufacturing a failure out of an idle
beat is its own defect (`:812-819`).

New as of 2026-10-18: `lane-actions.py` takes **one deadline for the whole read** (`--budget`) and
splits it across its two attempts, so the cached pass can no longer consume the retry's allowance and
the tool cannot outlive the caller waiting on it; a failed re-scan returns the roster already read
with `COMPLETENESS UNMEASURED` on stderr instead of discarding a readable datum. `pr-doctor.py`
consumes the **published** roster (`$STATE/lane-status.last.json` via `lane-actions.py --stdin`,
**2.8 s measured**) instead of paying a scan on every pass, and falls back to a bounded scan when that
file is absent, stale, degraded, partition-less or unreadable — saying which happened.

What does NOT exist: a deadline inside `lane-status.py` itself. Every remaining bound on the whole
read is a CALLER's — `queue-dispatch.py`'s 600 s on its direct `lane-status.py` call, `pr-doctor.py`'s
`LANE_BUDGET_S + margin` on the fallback scan. (The reader does hold per-CALL bounds — 60 s, 45 s,
45 s — and that is exactly the shape this MUST rules out: it bounds each probe and lets their SUM grow
with the fleet.) `queue-dispatch.py` still prints the residual: *"lane-status.py has no internal
deadline, so this is the only stop between a stalled scan and an unbounded wait"*.

⛔ AND THE PASS MUST SAY WHAT IT DID. A dispatcher that refuses is a failure the fleet can see: every
exit of `pr-doctor.py` writes `$STATE/pr-doctor.status.json` (`rc`, a one-line reason, the PRs that
went out) and prints `dispatched N of M queued — <why>`, so `dispatched 0` is never healthy while the
queue has runnable items; `objective.py` renders the last pass's verdict as `PR-DOCTOR(last run):
RED rc=N Nm ago — <reason>` beside the queue's own shape, and `heartbeat-loop.sh` prints the same
verdict and launchd's last exit. `queue-dispatch.py` consumes that record's `issue_work` field as a
**gate**: new issue work is SKIPPED while un-owned PRs exist, and the gate refuses only on a positive,
FRESH reading (a missing, stale, unreadable or refused record blocks nothing and says so).

agent-infra#1774, #1788.

### 6.5.3 Ancestry is the safety rail

**MUST.** Any process whose chain reaches a human terminal (`Terminal.app`, `iTerm`, a login shell)
is never touched, however parked it looks. `ppid 1` proves nothing on its own: a daemonising service
reparents to 1 **by design**. If either read is ambiguous, REPORT and do not reap.

**Why.** It is the one gate that stops a reaper destroying a human's work, and both failure
directions have already been measured: too little reaping (the ≈22 CPU-hours across six undetected
runaways recorded on #1142) and too much (#1393 deleted a live worktree). A reaper that skips this
gate is a lane-killer, not a reaper.

**Status: IMPLEMENTED** — by three carriers that do NOT carry the same gates, so say which one you
mean. `orphan-reap.py` walks to the top (`ancestry()`, `:175`; the rule at `:17-19`) **and** adds the
two gates `ppid 1` cannot express: launchd registration (gate 4 — a managed daemon has an owner) and
designed-daemon (gate 5 — pidfile, daemon flag, recently-touched output, or any live holder of a
socket it owns). Gate 5 was added AFTER a dry run passed gates 1-4 on three processes and all three
were wrong to reap (gate 4 came earlier, after the reaper killed the owner's own UI). It ships
**dry-run** (`:195`) and nothing schedules it today (§6.5.1).
`lane-watchdog.py:467` (`human_above()`) has the ancestry walk only — armed by
`heartbeat-loop.sh:365-368`, and one of the two carriers that actually RUN. `pi-reap-idle.sh` carries
the same idea as an ADDITIVE third gate that can only REFUSE (`:55`, `:381-429`), and its hourly job
ships armed. ⛔ Note what is NOT that guard:
`reap_stale_workers()` (`orch-loop.sh:420`) kills by **tmux session name**, which is safe for the
sessions the harness itself created and is not an ancestry test — do not read one as the other.

### 6.5.4 Reaping releases what the lane held

**MUST.** A reap returns the lane's resources: its worktree, its branches, and its test container.
Otherwise "reaped" means "the process is gone and the disk is still full", which is the state the
5.8 GB measurement is actually about.

**Status: GAP** on all three — but for three different reasons, and only the first is by design:

- **Worktree.** Removed only when it is clean, unreferenced, reachable and **7 days** old
  (`pi-reap-worktrees.sh:8-32`, and the job ships dry-run, `:194`), so an abandoned worktree holding
  any uncommitted work is PRESERVE by construction. Correct, and not a release.
- **Branches.** A deleter exists and is fenced — `cleanup-stale-branches.sh` runs `git branch -d`, then
  falls back to a compare-and-swap only for the `merged` class (`:2044`, `:102-110`), and its remote
  leg is `git push origin --delete --force-with-lease=<ref>:<oid>` (`:1546`, again `:1657`). Nothing in
  the harness invokes it: the reapers here never delete a branch, and its own job ships with NO
  execute flag, so the pass "classifies and reports and deletes nothing"
  (`templates/launchd/com.tortoise.branch-reaper.plist:40-43`).
- **Test container.** **No harness code manages one.** On a Mac cell the heaviest disposable thing a
  lane owns is its `.venv` — agent-infra#1949 exists to reap exactly that and is still open; a Linux
  cell has no container lifecycle here at all.

agent-infra#1858 (disk measurement), #1864/#1927 (scheduling).

### 6.5.5 What is deliberately NOT automatic

**MUST.** The following stay out of automation, with the reason stated rather than assumed:

- **A candidate with diagnostic value stays.** Evidence beats tidiness — `orphan-reap.py:36`
  ("Reapable != right to reap"), and `pi-reap-worktrees.sh`'s PRESERVE verdicts.
- **Arming is a per-machine operator decision, and the shipped default DIFFERS by job — say which
  one you mean.** The worktree reaper ships DRY-RUN (`pi-reap-worktrees.sh:194`), and so does
  `orphan-reap.py` (`:195`) — with nothing scheduling it. The two that actually run are ARMED:
  `heartbeat-loop.sh:365-368` passes `--apply` unless `LANE_WATCHDOG_APPLY=0`, and
  `com.eldato.pi-session-reaper.plist:30,49-50` sets `REAP_DRY_RUN=0` "by design". The rule that
  decides it is the same either way: a wrong reap destroys work, a wrong non-reap only costs disk.
- **`lane_liveness.py` never acts on `wedged`/`idle`** — it escalates `dead` only (`:68`). The one kill
  on a wedge signal is `lane-watchdog.py` (`os.kill`, `:623`), and it targets a frozen CHILD process,
  never the lane.
- **A P0-consequence action stays human** (data loss, deletion, spend) — the standing rule in
  `AGENTS.md`. Automatic reaping is bounded by exactly that line.

**Status: PARTIAL — three of the four exclusions are code; the fourth is prose only.** Each bullet
names where its exclusion actually lives; there is no single file that says "these four stay human".
`orphan-reap.py`'s five gates and `pi-reap-worktrees.sh`'s PRESERVE verdicts are real checks;
"P0-consequence" is an instruction to whoever arms the job, and nothing verifies it.

### 6.5.6 The controller must be un-removable by a routine install

**MUST.** `install.sh --start` / `--restart` must **enable and load** the job (`launchctl enable` → `bootout` →
`bootstrap`, falling back to legacy `load`, and saying which path ran), **assert** the outcome (the
label loaded with a pid, and the heartbeat file advancing within ~30 s), and exit **non-zero** if
either fails. A **watchdog** must restore a REMOVED service: `KeepAlive` relaunches a job that EXITS
(a bare `<true/>` on ANY exit, not only a crash — `launchd.plist.template:15-18`), and does nothing
for a job that is no longer loaded.

**Why (measured).** `launchctl unload -w` **writes a persistent Disabled override**, and the `load -w`
that follows has to bootstrap to clear it — and that bootstrap is what failed on 2026-10-17
(`Bootstrap failed: 5: Input/output error`). launchd's own log:

```text
15:21:41  Setting service com.eldato.orchestrator-loop to disabled
15:21:41  removing service: com.eldato.orchestrator-loop
```

The controller was **absent**, not crashed, and it dispatched nothing for 48 minutes and then 19,
with the heartbeat simply gone — the only signal that it had happened.

**Status: the installer half is CLOSED (#1975).** Every requirement in the list above is now either
implemented or explicitly not claimed:

| requirement | where |
|---|---|
| never write a persistent Disabled override | no shipped line invokes `disable`, `unload`, or `-w` (asserted from the stub's argv log wherever the path runs, **and** from a source scan of every TOP-LEVEL `*.sh`/`*.template` in `scripts/orchestrator-harness/` where it cannot (`*.test.sh` excluded — its fixtures must be free to contain those verbs; subdirectories such as `retired/` and the rest of the repo are not reached by the glob — hand-checked at the time of writing, not by a test)); `--uninstall` uses `bootout` only |
| clear a disable a previous flow already wrote | `lc_start` runs `enable` before `bootout`/`bootstrap`; the status it writes is read back with `print-disabled` |
| actually load the job (not just PRINT the command) | `install.sh --start` / `--restart` call `lc_start`; a plain run never starts anything |
| assert the job came back | `lc_assert_running`: new pid + heartbeat strictly advanced + `runs` did not move across the settle window |
| remove by proof, not by label | `lc_guard_mutate` reads the loaded job's `path =` and refuses unless it is this plist |
| an unreadable domain is UNKNOWN | `lc_probe` is the tri-state read, and every DECISION POINT that must distinguish 'not loaded' from 'could not read' re-probes with it: `lc_ensure`, the `--uninstall` read-back in `install.sh` (`block="$(lc_probe "$LABEL")"` — its verdict is the probe's own status, not a derived second read), `lc_guard_mutate`, `lc_assert_running`, `lc_assert_stable`, and `lc_bootout` (which refuses to treat a label as 'not loaded' rather than removing by a failed read). The thin wrappers `lc_pid` and `lc_runs` fold UNKNOWN into empty, so their callers must not read empty as 'not loaded'. Those decisions re-probe — **except `lc_restart`, and that is a hole this row names rather than hides**: a restart is unconditional, so it needs no probe to decide *whether* to act, but the folded `lc_pid` read it takes BEFORE the start is passed into `lc_assert_running` as `replaced`, so when that read is UNREADABLE (rather than 'not loaded') `replaced` is empty and the "the old process survived the start" check is silently SKIPPED. Not every read in the file is tri-state: `lc_min_runtime` falls back to launchd's own 10 s default, and a successful-but-empty `print-disabled` reads as `unset` (no override), because that is exactly what it means |

⛔ **What is still GAP is the reporting side, and it is the item that matters most**: nothing
**detects** a job that has been disabled or booted out — `KeepAlive`/`RunAtLoad`
(`launchd.plist.template:15-18`) relaunch a job that EXITS, which is not the same state as one launchd
no longer has, and `com.eldato.lane-liveness.plist` watches LANES by design with no controller alive.
On 2026-10-17 the label was disabled twice more *during this PR's own review* by agent sessions running
the pre-#1975 flow from other checkouts; both times a human reading `launchctl print` found it, not an
instrument. A watchdog that runs `enable` + `bootstrap` when the label is absent, and reports it, is
the missing piece — agent-infra#1860.

### 6.5.7 The cell's own roles run on a schedule, not when someone looks

**MUST.** A cell that can dispatch must also **land**, **repair** and **un-wedge** without a human,
and its `status` must be able to say **"this role has never run"** — because a cell that dispatched
its backlog and then did nothing prints exactly what a working cell prints (`controller: RUNNING`,
`lanes: 0`).

**Why (measured 2026-10-18, pi-cell-2/pi-cell-3).** A cloud cell ran exactly one loop
(`orch-loop.sh`). A green PR with a clean review record at its head sat **unlanded** until a human
ran the rail, and a wedged `lane-*` session held its slot until someone noticed — and the supervisor
could only answer *"is the tmux session up?"*. `status` reported `controller: RUNNING`, so the box
looked healthy while producing nothing. This is the §6.5 opening requirement's *"something must
NOTICE, DECIDE and ACT on a schedule that does not depend on the controller being healthy"* applied
to the cell, and the doctor is the something.

**Implementation: `cloud-cell-doctor.sh`**, launched as tmux session `cell-doctor` by
`cloud-cell-supervisor.sh start` (removed by `stop`; `.desired` in `state/roles/` records the
intent so a `stop` is not undone by the next pass). **A `stop` always WINS over an in-flight
`start`**: `stop` bumps a generation counter (`state/roles/.stop-generation`) as its first action,
and `start` snapshots it on entry and tears down whatever it created if it moved — the doctor's own
`supervisor start` restart can take minutes, and process-group signalling cannot close that window
(its recorded pid is a `timeout` wrapper, so killing it orphans the real child). The doctor loop's
command string carries the operator's `DOCTOR_SESSION`, `SESSION`, `SCOPE`, `HARNESS_REF` and pin
paths for the same reason it re-sources `ENV_FILE`: a tmux session is served from the server's
environment, and a restart that re-derives the defaults would come back under a *second* doctor
session (two loops on one state dir) or under the wrong scope. Roles, each idempotent with its own lock and
its own `state/roles/<role>.state` last-pass record:

| Role | Interval | What it ACTUALLY does |
|---|---|---|
| `reap` | 120 s | one wedged-session pass over the HARNESS namespace only (`lane-*`, `chain-*`, `merge-*`, `fix-*`); see the decision below |
| `doctor` | 120 s | `reap` + controller supervision: restart `orch-loop.sh` when its session is **gone** and the cell is `.desired`; a **stale-but-present** controller is reported, never killed |
| `merge` | 300 s | land PRs that already have a **clean attestation at THIS head** by EXECUTING `scripts/admin-merge.sh` — the standard rail, never a re-implementation |
| `hygiene` | 3600 s | `uv cache prune` (not `cache clean`), worktree-root caches, and the **shipped** `pi-reap-worktrees.sh` (dry-run unless `HYGIENE_WORKTREES=apply`, or `auto` + the box is under disk pressure) |
| `loop` | 10 s tick | the timer; every role also runs once immediately on start |
| `status` | — | the liveness table; the stale bounds account for every role that runs BETWEEN two passes of the same role (the roles run in sequence in one loop), so a busy-but-healthy cell is not reported STALE; **exit 1** when a started cell has a role that never ran, went stale, or whose LAST pass failed (`rc≠0` — a failed controller restart, a cannot-verify read). One clean pass clears it, so a transient failure reads as one failing pass, not as a dead cell. A loop younger than `DOCTOR_GRACE_S` (300 s) — or a role whose FIRST pass is still running (`state/roles/.<role>.running`, what `run_role_pass` writes, bounded by `ALL_PASSES_S` so a killed loop's leftover cannot hide a dead role for ever) — prints `WAITING` instead — its first doctor pass samples every lane, so `start && status` must not call a healthy cell dead; a cell with no loop-age record is judged immediately (fail-closed) |

**The reap decision is the safety core**, and it is the §6.5.1 rules applied to the fleet
namespace: a session is a candidate only if its log has not grown for `REAP_MIN_S` (**2700 s**, above
the controller's own `STALE_MIN=40` and the harness stall bound); the decision then takes **two
observations** `REAP_SAMPLE_S` apart; and the lane's **subtree must show no CPU delta**, because a
long model call is not a wedge. The whole read has an **overall** budget (`REAP_TIMEOUT`, 300 s) —
a per-call bound would let the total grow with the fleet — and each `tmux`/`ps`/`gh` call is
separately bounded (`READ_CALL_TIMEOUT` for tmux/ps, `MERGE_READ_TIMEOUT` for the queue listing;
without `timeout(1)` the bound is enforced by the shell itself, so its absence cannot silently
re-open an unbounded read). A pass that spends the budget STOPS at the lane it reached and
records `rc=3 cannot-verify`; it never acts on a partial read and never reports the lanes it did not
reach as quiet (§6.5.2, and the 800-failed-passes measurement there). Three exclusions are hard: a session with an **attached client**, a
session whose ancestry reaches a **human terminal**, and a session with **no log** are reported and
skipped. A read that cannot be taken is `SKIP ... cannot-verify` — never a reap, and never a pass.

**A `stop` is honoured MID-PASS too.** `stop` TERMs the loop and KILLs it if it does not go, but the
loop's destructive steps (the merge rail, `uv cache prune`, the worktree sweep/reaper) run in the
FOREGROUND, and bash defers a TERM trap while it waits on a foreground child — so a TERM+KILL lands on
a loop that was mid-rail and orphans that child, which then finishes (a merge that lands, a reaper
that keeps deleting) after `stop` returned 0. Each pass therefore snapshots `.desired` and the stop
generation on entry and re-checks them immediately before every destructive call: once a stop has
arrived, nothing NEW is started. (A stop that lands *inside* an already-running rail still lets that
rail finish — killing a merge mid-flight is worse — and that residual is named here, not hidden.)

**An unreadable read is never an empty one.** A missing `tmux`, or a `tmux ls` that fails for any
reason other than "no server running", makes `reap` record `rc=3 cannot-verify` instead of a clean
pass over zero lanes; the same unreadable list makes `hygiene` SKIP the worktree-cache sweep (its
"no workers are live" guard fails closed). `hygiene` records `rc=3` when `uv cache prune` itself fails (or is
cut at `HYGIENE_TIMEOUT`), when it cannot run the cache sweep, and when it cannot find the
shipped worktree reaper at all — "could not find the tool" was the silent no-op this role exists to
remove. The loop's own liveness is identity-fenced (`state/roles/loop.ident` = `pid|<identity>`, `/proc` start time where the kernel offers one), so a
recycled pid cannot make a dead loop read as RUNNING.

**The merge role only offers a PR to the rail when the cell holds its OWN clean attestation for the
HEAD it is looking at** (`~/.pi/agent/reviews/<owner>-<repo>-<pr>.json` at `$CELL_HOME`, so a cell's
review state is not the Mac's). It does not review, classify checks or merge on its own evidence —
that is `merge-one.sh`'s job, and #1872 measured two classifiers disagreeing on 4 of 11 live PRs.
A refusal is recorded **verbatim** (with its reason), the pass still exits 0 (a refusal is data, not
a failed read), and the same head is not retried for `MERGE_RETRY_S` (**3600 s**) — a new push moves
the head and re-arms it. An unreadable open-PR listing is `rc=3`, never an empty queue. **It takes the same per-PR link the
controller's `merge-one.sh` takes** (`$O/state/mergeclaim-<pr>.lock`, noclobber + a live-owner test):
without it the doctor could rail a head that a `merge-one.sh` worker is already reviewing on the same
box — duplicate evidence, duplicate record-review writes, one worker's needsfix landing after the
other merged. A claim held by a live worker is a clean skip that names the holder; a stale claim is
reclaimed; only the claim the pass took is released. **So is an
unreadable review STORE**: a permissions failure on `~/.pi/agent/reviews`, or an attestation file
that is present but unparseable, is `rc=3 cannot-verify` for that candidate — it used to render exactly
like "no attestation", so every candidate was skipped and the pass reported a clean *nothing to
land* while reviewed PRs silently never landed. A store that simply has no attestation for a PR is
still an ordinary, clean skip. The rail runs
FROM `$REPO` (a subshell `cd`, as `merge-one.sh` does), because its flake reproduction is
`git -C "$PWD" worktree add … <base>` and the loop's own cwd is the harness. The whole pass is
bounded by `MERGE_BUDGET_S` (**2400 s**), checked before each candidate: a spent budget ends the pass
`rc=3` and names the PRs it never tried.

**Status: IMPLEMENTED for a cell started by the current supervisor.** Three residuals, named:

- **It runs only where `start` launched it.** The supervisor starts the loop, so a cloud cell gets it;
  a Mac cell's `orch-loop.sh` launchd job does not, and nothing schedules the doctor there.
- **`cmd_check` now refuses a cell without it** (it is in the required-worker list in `cmd_check`), so a cell
  pinned to an older harness fails `check`/`start` loudly instead of silently running one loop — the
  correct direction, but it means the pin must be moved before those cells can start again.
- **Landing is not releasing.** The merge role gets a PR merged; it does not delete branches, reap a
  merged PR's worktree, or manage a test container — §6.5.4 stays GAP.

---

## 7. Gaps: what is fixed, what is not

Details and evidence for the remaining items: tortoise#8246. Same failure class in the fleet rail:
agent-infra#1678, #1680, #1683.

### 7.1 Dispatch bookkeeping never expires — **FIXED in this PR**

`orch-loop.sh` prunes `candidates.txt` against `dispatched.txt`, so an issue number is recorded as
"handled" the first time it is handed to a lane, and nothing re-checked whether that dispatch
**delivered**. A lane that dies (reboot, OOM, crash) stranded its issue permanently — invisible to
both the loop and to issue-triage, because the issue stays open with no PR.

Observed: **#4114, #4095, #3554** were dispatched 2026-10-10, their lanes died in a shutdown, and
each sat with a dirty worktree, no PR, and no re-attempt for >24 h.

**Fix:** the background refresh now runs a reaper — for each `dispatched.txt` entry, if the issue is
still open **and** no PR branch matches the number **and** no `lane-<N>` session is live, the entry
is removed from `dispatched.txt` **and** `checked.txt` so the pre-flight re-queues it. Four of the
self-test's checks pin exactly this decision table (`4114` reaped, `8888` kept for its PR, `9999`
kept because it is closed, `7777` kept for its live lane).

⛔ **A failed listing is not an empty one.** The reaper refuses the whole pass unless both
`.open_iss` and `.pr_brs` are **present**; the capture deletes a list when `gh` fails, so "the read
failed" (absent) is distinguishable from "the answer is none" (present but empty). Before the
guard, a failed `gh pr list` left an empty `.pr_brs`, `has_pr` was false for every issue, and
`dispatched.txt` was cleared — so `orch-loop.sh` re-spawned a lane for an issue that already had a
PR (duplicate work against the shared queue, agent-infra#1705). The self-test's failure-path checks
pin both halves (absent → nothing reaped and `checked.txt` untouched; empty-but-readable → still
reaps), and the capture site is driven directly with a stub `gh`.

### 7.2 Draft PRs are invisible to the sweep — **FIXED in this PR**

The selector was `select(.isDraft|not)` and nothing readied our own lanes' drafts, so a draft ran
its checks, failed `ai-review-gate`, and no worker ever touched it. Observed: **#8219**
(`feat/3524-tm`) and **#8085** (`feat/1037-tm`) sat with failed gates and an already-recorded
`ISSUES` verdict, stranded purely by the flag.

**Fix:** the sweep now includes drafts that match the harness's **own** branch patterns
(`*-tm`, `*-cap`, `fix/*`) and readies them once (`gh pr ready`) before the next cycle processes
them. Foreign drafts are excluded exactly as before — #4212 (`scope/w6b-graph-candidate`) is
another box's draft and is correctly left alone. (Note the two exclusions are independent: a PR on
`design/`, `scope/` or `dependabot/` is never swept even when it is not a draft — see §5.)

### 7.2c Conflicted PRs — **FIXED in this PR**

A CONFLICTING PR can never merge, but the sweep classified it GREEN/PENDING and called `gh pr merge`
on it every cycle, so the queue looked busy while nothing moved (observed: #8245, #8226, #8193, #8104). They are now routed to `fix-one.sh`, which integrates `origin/main`, resolves the conflict, and re-runs the review chain — capped by `MAX_FIX_TRIES` and parkable like any other fix loop. The
fixer prompt states that when a PR is CONFLICTING the conflict *is* the task.

### 7.2b Cross-box duplicate work — **FIXED in this PR**

The per-PR claim (§5.1b) is a **local file**, so it makes concurrency safe *within one box*. Two
boxes sweeping the same repo still both evaluate the same PR and the same issue, and the boxes
share GitHub, not a coordinator. The registry is now `refs/claims/<PR>-<head-sha12>` in the
repository the boxes already share (`<head-sha12>` because the key is `claim_key()`, which truncates
the head sha to its first 12 characters): `git push` to a ref is an **atomic create-or-fail** (a
CAS), so it needs no broker and no service, and the namespace is **outside `refs/heads/*`**, so it
triggers no workflow and never appears as a branch. **Verified empirically** on both
`daniel-ospina/agent-infra` and `daniel-ospina/tortoise`: pushing a probe ref to `refs/claims/*`
created **zero** workflow runs and **zero** check-runs, matching the static picture (every
`on: push` in both repos is filtered to `branches: [main]` or `tags`). `claims.sh` holds the
primitive; `merge-one.sh` resolves HEAD **before** claiming and exits 0 when another box owns that
head; `fix-one.sh` takes the **same** claim on the current head for the fixer's duration and
releases it before re-entering `merge-one.sh` (otherwise the reviewer-only claim left two boxes free
to spawn a fixer for the same PR); `orch-loop.sh` refreshes **every** claim in **one** fetch per
cycle into `state/claims-snapshot`, so `claim_live()` costs no per-PR network call. The lease is
**data, not liveness** (a remote pid cannot be probed), derived as `REVIEW_TIMEOUT + 1200` for the
reviewer and `FIX_TIMEOUT + 1200` for the fixer, and carried in the claim commit. Both tunables are
validated with `is_limit` (digits **and** at most nine of them) **before** that arithmetic, and
`claims.sh` clamps the ttl again at its own arithmetic site — because an overflowed lease is the
worst kind of failure: it goes **negative**, `_lease_of`'s `[0-9]*` cannot parse the minus sign, an
unparseable lease is read as **LIVE**, and `claim_prune` can never reap it, so that PR/head is frozen
across every box with no automatic recovery. Every
release/reclaim is `--force-with-lease`, so a box holding a **stale** commit (one that is no longer
the ref's tip) cannot release the winner's claim. Three hardening points from the adversarial
review of this PR: a **read-back failure on the create path still surfaces the commit we pushed**,
so the caller can fenced-release a claim that did exist instead of orphaning it for the whole lease;
a **failed reclaim push is classified by re-reading the ref** — unchanged or unreadable is an
infrastructure failure (rc=2, fail-open), a moved ref is a genuine lost race (rc=1) — rather than
reporting every transient error as a lost race and failing closed; and worker lease-read temp refs
live under `refs/claims-tmp/*`, **not** the pruned `refs/claims-cache/*` namespace, so
`claim_snapshot --prune` can no longer delete a concurrent read mid-flight. It **fails open on
purpose** — if the claim store is unreachable the harness proceeds and logs it — because
agent-infra#1709's headline finding is that duplicate execution is unavoidable and the side effects
must be idempotent per head, so failing closed would stall the whole fleet on one transient error.
`SCOPE=own` (§5, item 3) remains a useful partition but is no longer the only cross-box barrier —
and §7.2d measures what the barrier actually covers, per operation.

### 7.2d ISSUE dispatch was the uncovered window — **FIXED in agent-infra#1850**

`refs/claims/<PR>-<head-sha12>` is **content-addressed on a head sha**, so it cannot express an
issue at all: `claim_ref <pr> <sha>` has no sha to address, `claim_live()` returns 1 on an empty
one, and the whole registry was therefore **bypassed for issue dispatch**. That is the longest
exposure the fleet has, because it is the *whole working period of a lane before its first push*:
the pre-flight's own surfaces are immutable history (open/closed PRs, `gh` assignee) plus
**per-machine** git state (`git worktree list`, local branches), and `refresh-candidates.sh` selects
issues where `(.assignees|length)==0` while **nothing assigns on dispatch** — so every box reads
every issue as free. Measured 2026-10-16: two cells were pointed at `daniel-ospina/tortoise`, whose
pool held six P0 blockers with no PR for any of them.

The extension is a **key, not a mechanism**: `refs/claims/issue-<N>` uses the same CAS (a ref push),
the same lease-as-data commit, the same `--force-with-lease` fencing and the same `claim_prune`
reap. The decisions that are not obvious:

- **The key is `issue-<N>`, and the box id stays in the commit's `owner=` field.** `issue-<N>-<box>`
  was rejected deliberately: a per-box key is not a CAS — two boxes mint two distinct refs and both
  pushes succeed, so the ref can only be *read*, never *won*, and the pre-flight read alone cannot
  close the gap (it runs **before** the claim, so both boxes can read CLEAN and then both claim).
  `issue-<N>` is also idempotent for the same work, and its `issue-` prefix is disjoint from the PR
  key `<N>-<sha12>`, so a PR claim for the same number neither blocks nor is blocked.
- **The ref's home is the TARGET repo's origin** (`CLAIM_REPO`, i.e. the repo whose issue number is
  claimed) — never the harness repo. Every would-be dispatcher of that issue already resolves
  `$REPO`/`--repo` to it, so it is the one namespace all of them read; a claim pushed into
  agent-infra would be invisible to a peer dispatching tortoise, which is exactly the collision that
  was measured.
- **Claimed by `orch-loop.sh` when it forms its dispatch batch**, not by `dispatch-merge.sh`: a
  refused issue is then not written to `dispatched.txt` and not put in `.batch`, so it stays in
  `candidates.txt` and is re-attempted next cycle — no blacklist for the reaper to undo, and no
  worktree, lane or chain spawned for work another box owns. **Re-leased by `chain-merge.sh` on
  every exit path** (clean merge, failed merge, and the 90-minute "no PR appeared" timeout) through
  a trap, fenced on the commit this box pushed; a box that dies mid-lane leaves it to the lease,
  which is sized (`CLAIM_ISSUE_TTL`, default 3 h) to cover lane + chain — releasing early is the
  normal path, so the lease only runs its full length when the box is gone.
- **The pre-flight now CONSULTS it, and fails CLOSED.** `refresh-candidates.sh` calls
  `claim_issue_preflight` after a clean tool verdict and branches on its **exit code**, never on
  output text: **0 CLEAN** (no claim, or the only claim expired) queues the issue; **1 COLLISION**
  (a live claim, or a lease that cannot be parsed — a lease nobody can read is treated as live) is
  left unchecked, so the window is re-attempted when it closes; **2 INCOMPLETE** (the registry could
  not be READ — `git ls-remote` failed, or the local clock is unreadable) is never queued and counts
  toward the run's aggregate `INCOMPLETE=n` line, and a pass that produced **no usable verdict at
  all** exits transient (rc=1) — so an unreadable registry that queues nothing is a red run, not a
  quiet one; **3 NOT PROVISIONABLE** (the registry is present but
  predates the issue key — an `$O/claims.sh` with no `claim_issue_*` functions, i.e. the drift
  `install.sh` reports) refuses the issue the same way, and rc=3 also earns a **`.refresh-blocked`**
  marker (the provisioning channel: `orch-loop.sh` stops retrying and `status` names the reason), so a
  persistent condition is visible rather than a silent no-queue. rc=2 does **not** write that marker —
  it is transient by construction, so the pass exits 1 and the cycle is logged `FAILED rc=1` and
  retried; the marker would make a network blip look like a broken cell. This
  is the opposite polarity from the PR claim's fail-open, and it was applied to **every** exit, not
  just the obvious one: an unrecognised status is treated as INCOMPLETE, so no future code path can
  widen the CLEAN arm by accident. The one limit is stated rather than hidden — a box where
  `claims.sh` is **not installed at all** falls through to the pre-registry behaviour **loudly**,
  because making a missing file refuse would turn such a box merge-only, a bigger and less
  reversible failure. (The file reaches `$O` by `cp -p "$H"/*.sh "$O"/` in
  `scripts/deploy-crossbox.sh` — `install.sh` itself only diffs and reports drift; it does not copy.)

Two incidental defects are fixed with it: `claim_release` read its third/fourth arguments **bare**
under `set -u`, so a caller with no commit to fence on aborted with
`line 260: $4: unbound variable` instead of taking the documented refusal — a release that **errors**
leaves the claim held for the whole lease (3 h of a free issue, for the issue key).

`test-claims.sh` (I1–I10) pins the issue key against live origin from two scratch repositories (each
`git init` + `remote add origin <bare repo>` — **not** clones), including the **non-vacuity case for
this defect**: A claims an issue with **no branch, no PR and no push of anything but the claim ref**,
and B's pre-flight read must not be CLEAN — a test that only passes after a push does not test it.
Its keys are random per run (`PR`/`ISSUE` overridable), because two concurrent runs of the suite used
to collide on one fixed pair of refs in the **production** `refs/claims` namespace and delete each
other's refs mid-CAS — a green suite then reported 15–19 false failures, and the fleet runs several
reviewers of one PR at once. Measured (reproduce with the base commit of this PR as `<rev>`):

```bash
T=$(mktemp -d); cp scripts/orchestrator-harness/*.sh "$T/"
git show <rev>:scripts/orchestrator-harness/claims.sh > "$T/claims.sh"
CLAIMS_SH="$T/claims.sh" bash scripts/orchestrator-harness/test-claims.sh   # 65 passed, 45 failed
```

`claim-cwd.test.sh` pins the claim builder's **cwd independence** — the property a redeploy silently
took away on 2026-10-18, when the launchd cell (whose WorkingDirectory is **not** a repository)
refused every candidate in the queue while the controller looked alive:

```
[dispatch] #4513 NOT dispatched — could not build claim commit
```

The builder returned an EMPTY hash, so nothing entered the batch — a total dispatch stall that emits
no error of its own. Two independent hunks, each with its OWN discriminator:

- **`_git` must `cd` into `CLAIM_REPO` in a subshell, not hand git `-C`.** The `-C` form still STARTS
  in the caller's cwd and has to resolve it, which is exactly what the affected cells deny
  (`fatal: Unable to read current working directory: Operation not permitted`). The check runs the
  SHIPPED builder with its cwd set to a directory that cannot be resolved at all, and asserts a claim
  commit is produced and the ref lands on the target origin. **This is the hunk that unblocked
  dispatch.**
- **`CLAIM_REPO` must derive from `REPO`, not `.`** — hardening, not the incident's cause: the
  controller assigns `CLAIM_REPO="$REPO"` itself (`orch-loop.sh`), and every other shipped caller
  sets it explicitly. An ABSOLUTE `$REPO` is used as named (it needs no resolution, so no cwd can
  make it wrong); a RELATIVE one is used only when the cwd is not already a work-tree root, and
  otherwise `.` wins — see the six `cd` hazards below, which is why the simple form is not enough.

⛔ **`cd` IS NOT A FREE SWAP FOR `-C` — six defects found in the first three versions of this fix**,
each measured and each now pinned by the suite. `-C` treats its argument literally; `cd` is a builtin
with its own resolution rules:

- **an EMPTY `CLAIM_REPO`** — `cd ""` SUCCEEDS and leaves the cwd alone, so `|| return 1` never fired
  and a full acquire pushed `refs/claims/…` into the **caller's** repo, a repository nobody named.
  Closed in both orderings: the value that reaches `_git`, and an empty value that is already SET
  when the file is sourced (kept refused instead of being coerced into a default);
- **`$CDPATH`** — the builtin searches it for a relative path, and a same-named directory there WINS
  over the local one (measured), so a relative `CLAIM_REPO` ran every git call — and pushed the claim
  — in a repo the caller never named. `-C` never did that;
- **a RELATIVE `$REPO` from a caller already inside it** — `fix-one.sh` and `merge-one.sh` `cd "$REPO"`
  and then source this file with no `CLAIM_REPO`, so `$REPO` resolved from inside `$REPO` names
  `$REPO/$REPO`, which does not exist: every claim refused with the SAME `could not build claim
  commit` the fix exists to remove;
- **a same-named SUBDIRECTORY that is itself a repo** — the same caller shape, where `$REPO/$REPO`
  does exist. A default keyed on `[ -d "$REPO" ]` then ran every git call in the INNER repo and
  acquired with `RESULT=acquired` on an origin nobody named — a wrong-repo claim, silently, which is
  the duplicate dispatch this registry exists to prevent. Hence the cwd-work-tree-root test;
- **a BARE `cd` OPTION** — `CLAIM_REPO=-P` is not a path: `cd -P` takes NO operand and SUCCEEDS into
  `$HOME` (measured), so without the `--` a bare-option value claims into whatever repo `$HOME`
  happens to be. `-C` read it as a directory name and failed;
- **an ABSOLUTE `$REPO` while standing in ANOTHER repo's root** — the cwd-root test alone answers `.`
  there, so a caller naming repo B absolutely got `RESULT=acquired` with the ref on repo A's origin,
  silently: the same wrong-repo class one shape over. An absolute path needs no resolution, so it is
  used as named and the heuristic is left to the relative case.

Measured, which is what the suite is for (four baselines, `/tmp` copies via the `CLAIMS_SH` seam):

```bash
CLAIMS_SH=<pre-fix main>            bash …/claim-cwd.test.sh   # 19 passed, 17 FAILED (C1, C2, C5, C10)
CLAIMS_SH=<the two hunks alone>     bash …/claim-cwd.test.sh   # 20 passed, 16 FAILED (C5–C9)
CLAIMS_SH=<round-1 fixes, no cwd test / no SET test>          # 31 passed, 5 FAILED (C5 pre-set, C8)
CLAIMS_SH=<round-2 fixes, no absolute-REPO branch>            # 33 passed, 3 FAILED (C10)
CLAIMS_SH=<shipped, with `cd --` removed>                     # 33 passed, 3 FAILED (C9)
```

Each guard is pinned by exactly ONE check, so a later "simplification" of any single one of them
reddens the suite on its own:

```bash
CLAIMS_SH=<shipped, `cd --` removed>      bash …/claim-cwd.test.sh  # C9 reds alone — fail-open into $HOME
CLAIMS_SH=<shipped, absolute branch gone> bash …/claim-cwd.test.sh  # C10 reds alone — claims on the cwd repo
```

⛔ **The stand-in, stated**: the OS denial (TCC/EPERM on the process cwd) cannot be constructed
hermetically, so the first check puts a `git` shim first on PATH whose only job is that read
(`/bin/pwd -P` on the cwd it was STARTED in) before exec'ing the real git. The DENIAL is modelled;
`claims.sh`, the commit, the acquisition and the assertion are real. Non-vacuity is measured against
the pre-fix file, and the RED run fails with the incident's own log line:

```bash
CLAIMS_SH=<pre-fix main> bash scripts/orchestrator-harness/claim-cwd.test.sh  # 19 passed, 17 failed
bash scripts/orchestrator-harness/claim-cwd.test.sh                           # 36 passed, 0 failed
```

To reproduce `<pre-fix main>`: `git show <main>:scripts/orchestrator-harness/claims.sh > $TMP/claims.sh`.

`refresh-scout.test.sh` drives the **shipped** refresh step and the **shipped** dispatch block against
a real local origin for the collision, unreachable, absent, stale-registry and unrecognised-status
verdicts, plus the fenced release on the chain's exit path and the generation guard. Measured (the
counts cover the whole #1850 change — the feature and this fix round — not the fix alone):

```bash
cp scripts/orchestrator-harness/*.sh "$T/"
for f in claims refresh-candidates orch-loop chain-merge dispatch-merge; do
  git show <rev>:scripts/orchestrator-harness/$f.sh > "$T/$f.sh"; done
( cd "$T" && bash ./refresh-scout.test.sh )                                  # PASS=72 FAIL=67
```

Three further defects in the same family are fixed and pinned with it, all fail-**open** directions:

- **The pre-flight's clock is guarded.** `date +%s` is a *second* input to the same decision, and if
it cannot be read the old comparison `[ "$now" -le "$until" ]` was neither true nor an error the
code handled — bash prints `integer expression expected` and the test is FALSE, so the reader fell
through to CLEAN. An unreadable clock is now rc=2 INCOMPLETE, alongside an unreadable registry.
- **The release record is generation-guarded.** A chain captures the commit it pushed when it becomes
the holder; the record file is keyed on the **issue**, so if the same box re-acquires after its lease
lapses, a newer generation overwrites it. A release that read the file when its trap fired would
fence on the new commit — which **is** the ref tip — delete the live holder's claim and free a busy
issue for a peer. The captured generation is compared and a mismatch **refuses** the release (naming
it), leaving the newer record for its own release. ⚠️ The guard is deliberately **inert on the
no-chain path** in `dispatch-merge.sh`: that release runs seconds after the record was written, so
the record *is* that dispatch's generation — there is no older holder to refuse, and the fence is the
record's value. It earns its keep in `chain-merge.sh`, whose trap can fire hours later, after the same
box has re-acquired and overwritten the record.
- **The lease polarity has ONE implementation** (`_lease_unparseable` / `_lease_is_live`) shared by
`claim_acquire`, `claim_issue_preflight` and `claim_prune` — three copies of the same comparison, and
"a lease that cannot be read is live" is exactly the predicate they must not answer differently.
(`orch-loop.sh`'s `claim_live` keeps a fourth deliberately: it reads the local SNAPSHOT rather than a
ref and `selftest.sh` extracts it standalone, so it cannot share an in-process helper.)

### 7.2d Does a claim EXCLUDE? — **MEASURED, per operation** (agent-infra#1908)

agent-infra#1908 held the retirement of the `SCOPE=own` partition **conditional**: retire it only
once a claim is *demonstrated* to exclude a concurrent holder, and only for the operations that
tolerate at-least-once. A registry that exists is not that demonstration — #1850 landed the **code**,
and a claim had never been observed refusing anything under real contention. `claim-exclusion.test.sh`
is the measurement, and this section is its recorded output. **This table is copied from that suite**;
if a row changes polarity the suite goes red and names the row, so it cannot go stale silently.

```bash
./claim-exclusion.test.sh                 # hermetic: a throwaway bare origin, the CI form
./claim-exclusion.test.sh --origin live   # THIS checkout's origin, in a $$-scoped namespace
```

**What it actually does, and its limit.** It releases **N independent processes** (default 6) at a
barrier against a **real `git receive-pack`**, each presenting as a different box through
`CLAIM_OWNER_ID`, so the CAS is genuinely raced rather than replayed sequentially. Each racer waits
`n × 3 ms` after the barrier: released in the same microsecond, every push contends for the same
`<ref>.lock` and the losers are refused by **git's ref lock** before they ever reach the CAS —
measured by forcing the create push and still getting exactly one winner, which would have let a
defeated CAS report EXCLUDES. Two boxes are never that synchronised, so the stagger measures the case
the CAS has to handle. **Non-vacuity, measured:** with the stagger in place, pointing `CLAIMS_SH` at
a copy of `claims.sh` whose create push is forced (`push -q --force`) reddens **M2** with
`2 winners in one lap`, while the shipped `claims.sh` is 15/15 green — so the suite discriminates a
defeated CAS from an exclusive one. **Limit, stated:** the default origin is a bare
repo in the sandbox, so this measures ref-update atomicity, not the network. `--origin live` closes
that gap on demand (it leaves no claim ref and no probe branch behind — the trap deletes both).

| operation | claim key | duplicate behaviour MEASURED | tolerates at-least-once? |
|---|---|---|---|
| **dispatch** (start a fixer/reviewer) | `refs/claims/issue-<N>` | 3/3 laps × 6 racers: **exactly one** winner per lap; every loser gets rc=1 and is told *who* holds it (`held by box2:1529071 until …`) | **yes** — side effects are idempotent |
| **review / record evidence** | `refs/claims/<PR>-<sha12>` | 3/3 laps × 6 racers: **exactly one** winner; loser refused | **yes** — the cost of a duplicate is a duplicate comment |
| **landing: the same head** | `refs/claims/<PR>-<sha12>` | the same CAS as review; the second worker exits **before** it reviews or merges (`merge-one.sh`, `CROSS_RC=1`) | **only for that head** |
| **landing: the PR moved to a new head** | `<PR>-<sha12>` — **a different key** | **both acquire.** Measured: an issue/PR claim is content-addressed on the HEAD, so two heads of ONE PR are two distinct CASes and the claim cannot express *"this PR"* | **NO — see below** |
| **fencing** (release / stale write) | the ref's **value** | a loser's release is refused (rc=1, ref unchanged); a **fast-forwardable** push leased on a stale base is refused — by the lease, not by non-fast-forward | n/a — a fence, not a claim |

**So, per operation:**

- **Dispatch and review are retired from the `SCOPE=own` question.** The measurement shows the claim
excludes, on both keys, under real concurrency — and `SCOPE=own` was **never** what excluded them:
it selects which *PR branches* this box's **sweep** looks at (`*-tm`, `*-cap`, `fix/*`), by a naming
convention every box shares, so two `own`-pinned boxes select the same PRs. The code has said so
since the pin was added (§5 item 3, "a partition, not coordination"); the measurement now says the
claim covers those two classes without it.
- **Landing is NOT retired, and must not be.** The claim is per-head. Two boxes at two heads of one
PR hold **two live claims** and both proceed toward a merge of the same PR. `SCOPE=own` does not
cover that either (it is a selection filter, and the PR is in both boxes' selection), so this row
keeps an **exclusion requirement that nothing in the harness currently satisfies**. Naming the row
that justifies keeping it is the whole point: *landing: the PR moved to a new head*
(**agent-infra#1952** carries the decision: add a per-PR exclusion, or exempt the row explicitly).
- **What the merge path does have, and what it does not.** `merge-one.sh` re-reads `LIVE_HEAD` before
merging and requires a **signed marker for that live head**, so the merged content is at least the
head some reviewer signed. It does **not** pin `gh pr merge` to a sha, so the guard is a read, not a
fence, and the window between the two is real. ⛔ **That last sentence is read from the code, not
measured** — exercising `gh pr merge` on a moved head needs GitHub, so it is not claimed as a
measured merge outcome here.

**For §0.3/§0.4/§0.5 when they land.** Those sections (the requirements and the keep/legacy
inventory, agent-infra#1905) are not on `main` yet, so this section — not them — is the source of
record for the measurement today. §0.4's "at-least-once with idempotent side effects" is accurate for
the **dispatch** and **review** rows and **not** for the landing row; §0.5's `SCOPE=own` row may move
from *retired* to *retired, see measurement* for the first two and must not for the third.

### 7.2e A refresh that cannot READ the pool reported an empty queue — **FIXED in agent-infra#1931**

`backlog=0` was the same line whether the pool had been read and was empty or the pool listing had
**failed**. Measured 2026-10-17: a cell refused on **131 consecutive passes** (its abort was correct)
and dispatched nothing while 15 PRs were open; on every one of those cycles the controller's line
read `backlog=0`, which is what a fleet with nothing to do also reads. The abort named the tiers in
prose, but nothing carried a *state* an operator or an instrument could key on, and a **partial**
read was reported with the identical sentence as a total one.

**Fix:** the pool read is now ONE of four named outcomes, in one vocabulary: `EMPTY` (every tier was
read and listed nothing — the only answer that may mean "no work"), `READ(<n>)` (every tier read,
n candidates), `PARTIAL(<tiers>)` (some tiers could not be read, so the survivors are a subset and
nothing is queued from it — #1736's rule, kept), and `UNREADABLE` (no tier could be read: the fleet
is blind). The state is persisted to `state/queue-state` with the epoch of the read, and
`orch-loop.sh` prints it as `queue=$(queue_state_token)` in the per-cycle heartbeat line and beside
`[dispatch] backlog empty`, with the age of the reading (a frozen value cannot pass as a fresh one).
An absent or unparseable record prints `UNKNOWN`, never `EMPTY`. The refusal polarity is unchanged
and still fail-closed: a failed read exits TRANSIENT, never a green "nothing to do".

⚠️ **Deliberately NOT fixed here** — this is the *reporting contract*, not the transport, and not the
provisioning verdict: the fleet's shared gh backoff for GitHub's secondary (concurrency) limit is
agent-infra#1910, and a refresh whose resolved tool directory is behind `origin/main` still says so
only through its own existing refusals (issue #1931's directions 1 and 3, which this change does not
touch). A pass that cannot read the pool now says `queue=UNREADABLE` while it refuses.

### 7.3 The harness is unversioned (this directory is the remedy)

Until now it existed only as `~/orchestrator/*.sh` on one machine: no history, no review,
no way to hand it to another box, and no way to know which of the 14 scripts were live. §9
records which are live and which are retired.

### 7.4 Defects found in the first review of this artifact (all fixed here)

These are kept as a record because each one is a *failure mode of the design*, not a typo.
(`retired/` fixes are annotated in place and only parsed — the retired tree is dead code.)

| Defect | Impact | Fix |
|---|---|---|
| `MAX_LOAD` was rendered into the plist and documented as live back-pressure, but never compared to anything | the load ceiling did not exist; a lanes-bound stall logged itself as a load stall | the dispatch gate now tests load first and names the binding gate in `[dispatch] skipped (…)` |
| `SKIPPED`/`NEUTRAL` counted as satisfying **every** required check, including the merge authority | a skipped `ai-review-gate` read as `GREEN` and the PR merged **without any signed review** — a fail-open on the one gate that matters | the classifier requires explicit `SUCCESS` for `ai-review-gate` (absent counts as failed) |
| A lane's PR is driven by `chain-<N>`, whose session name the controller's in-flight guard could not see | two concurrent `merge-one.sh` runs per PR: duplicate evidence comments, duplicate `record-review` writes, `ISSUES`/`CLEAN` interleaving | atomic per-PR claim file, honoured by all three paths |
| `fixcount` was incremented and the findings marker deleted *before* the fixer spawn was attempted | a killed/failed spawn consumed one of `MAX_FIX_TRIES` and destroyed the findings, so no fixer ever ran | spawn first; bookkeep only on success, message the failure otherwise |
| Reaching `MAX_FIX_TRIES` fell through to the re-record branch | an unfixable PR burned a full fresh-context review **every cycle, forever** | terminal `state/parked-<PR>` state, keyed to the head so a new push re-arms it |
| `tmux has-session -t fix-82` prefix-matches `fix-820` | PRs whose number prefixes a running worker's were starved of attention for as long as it lived | exact session-name matching (`tmux ls -F … \| grep -qx`) |
| `refresh-candidates.sh` `cd`-ed into a scout worktree nothing ever created | on a fresh box the refresh exited 1 every cycle and the backlog silently never refilled | provision the worktree and its venv on first use, or fail loudly |
| `install.sh` reported an env-only gate key as present | the daemon silently started without it and the "merge role" install.sh just blessed did not work | only a key *file* is authoritative; env-only is reported as insufficient |
| **`refresh-candidates.sh` hardcoded a tortoise/Python shape** (`uv sync --extra embeddings --extra parity` and tortoise's `tools/collision_preflight.py`) | a cell pointed at a non-Python repo (agent-infra has no `pyproject.toml`) aborted **every** cycle, and because `orch-loop.sh` runs the refresh in a **backgrounded subshell** the non-zero exit could not fail the loop: the controller reported `RUNNING` with `lanes: 0` **forever** — a cell that looks alive and can only merge (agent-infra#1736) | the venv step is skipped only when it is genuinely **not applicable** (no `pyproject.toml`) — a real `uv sync` failure is still fatal, loud, and prints uv's own output; the extras are read from the project; the tool is resolved per repo (own copy, else a `TORTOISE_REPO` checkout) and its absence is a **permanent** `rc=3`; `--check` gives the same verdict read-only so `cloud-cell-supervisor.sh check`/`start` refuse a merge-only repo with the reason; and `orch-loop.sh` now reads the rc — permanent writes a `MERGE-ONLY` marker and stops retrying, transient still retries |
| **the merge-key preflight asked "is there a key?" in four mutually inconsistent ways** | every divergence is a false green on the one check that decides whether a cell signs its reviews: `install.sh` and `cmd_check` tested the key **file** by *size*, and a 1-byte newline — exactly what `echo "$KEY" > file` writes for an unset variable — read as present; `cmd_check` tested the **`keys.env` value** for raw non-emptiness, while the consumer strips whitespace and treats the result as absent; the **precedence was file-first** while the consumer is env-first, so a whitespace-only value shadowed a valid file (its fallback never runs on a non-empty raw value); and the file was read from `$HOME`, which `keys.env` may repoint while the session forces `HOME` back to `$CELL_HOME` after the source | both the file and the value are tested for **normalized content** at every site, the order matches the consumer (env first, the file as its fallback), the file is read from `$CELL_HOME` — the home the session actually uses (`keyfile_has_key` states it explicitly, and the supervisor re-exports `HOME=$CELL_HOME` after sourcing so both agree on every path) — and each of the four cases has a check that a mutation turns red, except that the two HOME guards are now equivalent: with the re-export in place, reading `$HOME` or `$CELL_HOME` gives the same answer, so the behavioural pin is the check that a keys.env `HOME=` cannot change the verdict. |
| Plist rendered with unescaped `sed` replacements | a `&` in a path expanded to the matched placeholder, producing a *valid* plist pointing at wrong paths (so `plutil -lint` cannot catch it) | escape `\`, `&` and `\|` in every substituted value |
| `retired/do-merge.sh` logged `rc=$?` after an unquoted `$(date)` | every merge failure logged as `rc=0` | capture the status first |
| `retired/watch-one.sh` built the fixer prompt from a log the reviewer had not written yet | the fixer always ran against an empty FINDINGS section | build the prompt after the reviewer run |
| the pre-fix sweep logged `#<PR> re-record` even when the concurrency cap suppressed the spawn (`{A\|\|B\|\|C;} \|\| D && echo` parses as `({A\|\|B\|\|C} \|\| D) && echo`) | a stalled drain looked busy | explicit `if/elif` branches |
| **this file's own self-test** re-implemented the fixed logic instead of reading the shipped scripts | it passed on the broken copy, so it pinned nothing | every check now extracts and drives the real classifier, `sess()`, claim block and reaper, or runs `install.sh`; §9/§7 claims corrected |
| `MAX_REVIEW` defaulted to 2 in `orch-loop.sh` but 4 in `install.sh`, the plist it renders, and §4 | running the loop directly (not via the plist) silently halved reviewer concurrency against the documented value; the `${MAX_REVIEW:-4}` fallback was dead code | default is 4 everywhere, and the self-test resolves all 10 limit defaults in both scripts and asserts they agree — including with the limits supplied via the environment, which is how the plist delivers them |
| the live sweep dropped the `CLOSED` guard that `retired/sweep.sh` had, keeping only `MERGED` | a PR listed open that closed in between fell through to `gh pr ready` + `gh pr merge` every cycle and logged `#<PR> merge fail` forever | `case "$PR_ST" in MERGED\|CLOSED) continue ;;` |
| `retired/auto-loop.sh` and `retired/sweep.sh` still carried the fail-open `ai-review-gate` classifier | shipping "the record" with the very bug being fixed invites reuse of it | both annotated in place as retired-with-known-fail-open |
| §3 and §8 admitted cross-box duplication while §5.1b said "one owner per PR" | the invariant was stated more strongly than the code delivers | §5.1b scoped to per-box; §7.2b states the open cross-box gap |
| **a PR branch name was interpolated into the `sh -c` string `tmux new-session` executes** | **arbitrary command execution on the unattended host that holds the merge key.** git permits `'` `;` `$` `` ` `` `&` `\|` `(` `)` `{` `}` `"` `<` `>` `#` in a ref name, so a fork PR on `fix/x';touch${IFS}/tmp/x;#` broke out of the quotes. Reproduced end-to-end before fixing | `safe_ref` allowlist + `check-ref-format`; numeric-only PR ids; and worker args now travel in a file (`--argv`) so no PR-derived value is interpolated at all |
| **the check classifier was a deny-list** (`bad = FAILURE\|ERROR\|CANCELLED\|TIMED_OUT\|ACTION_REQUIRED`) | a conclusion in **neither** list — one GitHub has not documented, or a **null** one — read `PENDING`, and `PENDING` arms the merge (`gh pr merge --auto`): the merge decision failed **open**. At the same time `CANCELLED` was named *red*, so a normally-superseded run (`cancel-in-progress: true`) was routed to `fix-one.sh` or to `gh run rerun` — failing **closed** on a green PR. `fix-one.sh`'s failing-check list named `CANCELLED` too, so such a run burned a capped fixer attempt (agent-infra#1714) | the classifier is an **allow-list with polarity**, the rule `admin-merge.sh` and `record-review.sh` already implement: non-red only for a NAMED conclusion (`success`/`neutral`/`skipped`/`cancelled`/`stale`), in-flight only for a NAMED status, and **everything else RED** — so an unrecognised or null conclusion blocks instead of arming; grouping is per `(app, name)` (newest attempt by `id`) so one app cannot mask another's — ⚠️ but the only call site feeds it `gh pr checks --json name,state,workflow`, which carries neither `id` nor `app`, so the grouping is in force only for a surface that carries them (agent-infra#1733); and an **empty** surface is `NOCHECKS`, never `GREEN`. `fix-one.sh` uses the same allow-list (agent-infra#1714) |
| the claim-file guard added in the first fix round introduced a permanent stall | the controller treated *the existence of* `mergeclaim-<PR>.lock` as "in flight", but only `merge-one.sh` removes it — a SIGKILLed worker or a reboot mid-merge left the PR skipped forever with no fixer and no re-record | `claim_live()` tests the recorded pid with `kill -0` and removes a dead owner's claim |
| 6 self-test checks passed vacuously because an empty extraction did not fail the check | the round-1 vacuity fix was incomplete: checks depending on `sess()`, the claim block or the reaper passed when the shipped script had no such code | `need()` turns a missing extraction into a FAIL |
| **a hung worker held a concurrency slot for 9 hours** | `pi -p` has no timeout and the caps count **tmux sessions**, so a hung reviewer (or a runaway `find /` it spawned) permanently reduced merge throughput while the queue looked busy — three slots were dead weight overnight on 2026-10-12 | portable `run_agent()` wall-clock limit (bash `wait` + watchdog subshell, since macOS ships no `timeout`) plus a `reap_stale_workers()` sweep that kills any worker silent for `STALE_MIN` minutes |
| **only `ai-review-gate` and `python-ci-gate` failures had a remediation path** | a PR red on any *other* required check (`docs`, `test-isolation`, `license-surface`, `legal-e2e`, `pricing-artifact`) was merely logged, so it sat red forever with **no worker at all**. Observed: #8278 carried two new `docs`-lint findings (MD056, an unescaped `\|` in a table row; MD046, fence style — fixed in `f15923b`) and #8193 a new `MD018` finding — both with zero workers for hours. ⛔ **And the name list was itself a tortoise constant (#1764):** on agent-infra a red `pipeline-compliance` matched none of those five, so the fix reappeared there | those checks now route to `fix-one.sh` too — but the arm is now **derived from the repo's own required set** (#1764), so a red required check routes on *any* repo (agent-infra's `pipeline-compliance` included) — capped and parkable like every other fix loop; and `fix-one.sh` fetches the failing check's **log** into the prompt, because it previously only ever read a reviewer comment — for a CI failure there may be no comment at all. ⚠️ **Known residual (agent-infra#1703):** that fetch reads the workflow RUN's `--log-failed` and `tail -80`, so a multi-failed-job run can hand the fixer the wrong job's log; tracked, not fixed here. |

### 7.4b Defects found in the agent-infra#1700 review (fixed here)

| Defect | Impact | Fix |
|---|---|---|
| **`cmd_check` never tested `record-review.sh`, and neither cell script provisioned it (agent-infra#1717)** | `merge-one.sh` executes `$HOME/.pi/agent/scripts/record-review.sh` to mint the signed marker, and a fresh cell has no such file. `cmd_check` printed `CELL CAN RUN A CONTROLLER` anyway (a false PASS on the only question that verdict answers), the cell ran a full fresh-context review — up to `REVIEW_TIMEOUT` = 1800 s, **paid** — and only then hit 127. The pre-fix `exit 3` left no terminal state at all — nothing was recorded and nothing was parked: it returns from the `CLEAN*)` arm, and the `*)` arm that writes the fixer marker is reached only for a non-CLEAN verdict, so the marker was never written on this path either way: the next cycle saw an unmarked `FAILED:ai-review-gate` and spawned another review, **one paid review per cycle, forever** | `cmd_check` probes the runtime dependencies the loop actually invokes — `git`, `python3`, `pi` (`uv` warns, matching `install.sh`) and the recorder path it reads from `$CELL_HOME` — and refuses to print the verdict without them; `start` provisions the recorder from the checkout. The record step is also checked **before** the paid review in `merge-one.sh`, and any of its failures (absent, empty, non-executable, non-regular-file, non-zero rc, an `rc=0` record that posted **no signed marker** into the PR body, or a CLEAN verdict that named no comment) writes the controller's own terminal `state/parked-<PR>` marker at the reviewed head plus a `state/parkreason-<PR>` naming why — and the worker itself refuses to re-review a head it has already parked, so the `chain-<N>`/`fix-<one.sh>` paths that never consult the controller cannot re-pay either. The controller's own park sites (`orch-loop.sh`, conflict/fix/CI caps) write the same `parkreason-<PR>` pair through `park_ctrl()`, so a **controller** park at a moved head never leaves the previous head's reason behind for the exit-5 refusal to misreport. ⚠️ **Residual:** `merge-one.sh`'s own rail cap writes `state/parked-<PR>` directly and no `parkreason-<PR>`; that site `exit 0`s before the exit-5 refusal can print a reason, so it cannot itself misreport — but a human reading `state/parkreason-<PR>` beside a newer marker still can. A later push changes the head and re-arms the PR by construction |

### 7.4c Defects found in the agent-infra#1850 review (fixed here)

Eight of the ten are fail-**open** in a gate whose whole purpose is to refuse: each certifies a busy or
unverifiable issue as free, hands it to a second box, or lets a release run without its fence. (The two
that are not: the silent-release row, which leaves the claim **held**, and the `CLAIM_COMMIT` row, which
is state hygiene.) Pinned
by `test-claims.sh` (I10, I9(5), I9(7)) and `refresh-scout.test.sh` §8(g) (unrecognised status),
§9(iii) (stale-registry dispatch), §10 (fenced + generation-guarded release, the CAPTURE that wires
it, and the no-generation refusal) and §11 (the chain-failure branch). The last three were found in
the later review cycles, precisely by asking what each new assertion would do if the line it protects
were deleted.

| Defect | Impact | Fix |
|---|---|---|
| **the CLEAN arm was a wildcard** (`case $rc in 0) queue;; 1) COLLISION;; *) INCOMPLETE`) | the intended set is {0,1,2}; `*)` silently absorbed everything else, so a **stale** registry (`rc=3`) and an unexecutable `claims.sh` (`rc=127`) both queued the issue — the pre-flight asking its question and then ignoring a "cannot answer" | explicit `0` / `1` / `2`+`*` / `3` arms; anything unrecognised is INCOMPLETE, so no future status widens CLEAN by default |
| **`claim_issue_preflight`'s clock was unguarded** | `date +%s` is a *second* input to the same decision — the `ls-remote` read that proves "no claim ref exists" does not need it, but the lease comparison does. On an unreadable clock `[ "$now" -le "$until" ]` is FALSE (bash prints `integer expression expected`), so a **held** claim's reader fell through to `return 0` — a **false CLEAN** in the one direction the gate exists to prevent | a non-numeric/empty `now` is rc=2 INCOMPLETE, alongside an unreadable registry |
| **the release record was read when the trap FIRED, not when the claim was taken** | the record file is keyed on the **issue**, so a box that re-acquires after its lease lapses overwrites it. The older chain's trap then fenced on the *new* commit — which **is** the ref tip — and deleted the live holder's claim, freeing a busy issue for a peer: the exact duplicate the key exists to prevent | `chain-merge.sh` captures the commit at chain start (`claim_issue_record_commit`) and `claim_issue_release_record` refuses on a generation mismatch, naming it and leaving the newer record intact |
| **a registry too old to take a claim still dispatched** | `refresh-candidates.sh` refused every issue on such a box (`rc=3`) while `orch-loop.sh` acquired anyway, found no `claim_issue_acquire`, and **dispatched unclaimed** — the fail-open half of the same condition, and the collision on two boxes | present-but-stale is now split from genuinely-absent: the loop refuses the dispatch and names the fix; only a **missing** `claims.sh` (pre-registry box) falls through, loudly |
| **release failures were silent** (`>/dev/null 2>&1 && echo`) | a refused or failed release left the claim held for its whole lease (3 h of a free issue) with nothing in the log to say so — and `CLAIM_RESULT` was lost because the helper ran in a subshell | the helper `declare -f`s the function, sources `claims.sh` into the **current** shell, passes the captured commit, and logs the reason on every failure branch |
| **the chain-failure arm released a claim whose LANE was still running** | the lane is spawned *before* the chain in the same loop body, so "no chain will ever run" was true while "nothing is running" was **not**: the release declared an issue this box was actively implementing free, a peer claimed it and duplicated the work, and this box still opened a PR nothing would merge | stop the lane first (exact session match) and release only once it is confirmed gone; if it cannot be stopped, **keep** the claim — the lease expiring it is the safe direction |
| **a chain with NO captured generation still released** | the capture is empty when the handover record was absent at chain start (`orch-loop.sh`'s `claim_issue_record` failed) or `$O/claims.sh` predates the reader. `claim_issue_release_record` treats an empty expectation as "read the record now" — right for `dispatch-merge.sh`, whose release is milliseconds after the write, but WRONG for a trap that can fire **hours** later: the record then holds the newer holder's own commit, which **is** the ref tip, so the stale chain deleted a live claim | `chain-merge.sh` refuses the release when it has no captured generation, names the reason and lets the lease reap it (one lease lost vs duplicated work on two boxes) |
| **`CLAIM_COMMIT` was a per-CYCLE global** (not fail-open — state hygiene) | `claims.sh` reset it only when sourced, so an acquire that failed *before* any push (`rc=2`: unreadable ref, unfetchable claim) left the **previous** issue's commit in it. `orch-loop.sh`'s "rc=2 with a claim commit → record it and try a fenced release" then wrote a handover record for an issue this box never claimed, consumed it, and logged a release that never happened — the fence keeps the registry safe, but the *log* is what an operator reads | cleared at the top of `_claim_acquire_at`, so the value always means "what THIS attempt may have pushed" |
| **a chain RE-RUN by hand captured a generation it never took** | the capture read the handover record, and the same box can hold the same issue twice (its lease lapsed and the loop re-acquired while the old chain still waited). A re-run starts *after* the re-acquire, so it captured the NEWER generation — the one on the ref tip — and its trap deleted the live holder's claim. Both this file's timeout message and `nonblocking-dispatch.sh` invite exactly that re-run | the generation is now **injected by the spawning process** (`dispatch-merge.sh`, in the loop body that wrote the record) and inherited by `chain-merge.sh`, which never re-derives it. A chain started any other way has none and refuses, leaving the claim to its lease |
| **the suite's other two teardowns leased on the OBSERVED tip** | `--force-with-lease=<ref>:<observed>` is a conditional *write*, not an ownership check (it refuses only if the ref moves in the microseconds between the `ls-remote` and the push), so `cleanup_issue_ref` deleted whatever was at `issue-<N>` — reachable with the documented `ISSUE=` override, and with `PR`/`ISSUE` equal. The probe was fixed; these two were not | ownership now comes from the **registry's own lease** (`<id>:<pid>`, and the suite runs all boxes from one process), plus a whitelist of the synthetic lease ids the sections hand-build. A claim this run did not create is left alone and named |

### 7.5 Still open, deliberately not fixed here

> **Eight entries that were here are now FIXED**; all but two have been removed from this list: the
> fail-open reaper when the PR listing fails (agent-infra#1705, tortoise#8519), `checked.txt`
> written before the pre-flight verdict (agent-infra#1716, tortoise#8515), the returning INT/TERM
> trap in `orch-loop.sh` and `merge-one.sh` (agent-infra#1715, tortoise#8516), the controller's
> macOS-only capacity probes (agent-infra#1702, tortoise#8514), the deny-list check classifier in
> `orch-loop.sh` (agent-infra#1714, tortoise#8518), this directory being older than its source
> (agent-infra#1712 — see the provenance note at the top of this file), and
> `cloud-cell-bringup.sh` deleting the pushed gh token only on the success branch
> (agent-infra#1718 — fixed in this branch, independent of the #1712 port), and
> `cmd_check` never testing `record-review.sh` (agent-infra#1717 — fixed in this branch; see §7.4b).
>
> The two that keep a bullet below do so as the *record* of the failure mode, not as open defects:
> agent-infra#1705 (the fail-open reaper) and agent-infra#1712 (this directory's provenance pin) —
> both closed.

- **`can_spawn()` gates on load only, so the memory ceiling does not cover the five controller spawn
  sites** (agent-infra#1732). Lane dispatch is bounded by swap and available memory; the five spawn
  sites are bounded by load alone, so raising `MAX_LOAD` widens the band in which they proceed while
  memory is already the binding gate. §4 states the gap; this is its tracker item.
- **The check classifier's `(app, name)` grouping and its newest-by-`id` selection cannot take effect
  at the call site** (agent-infra#1733). `gh pr checks --json name,state,workflow` carries no `id` and
  no `app`, so the newest attempt is decided by row order, and two non-Actions checks that share a
  name collapse into one bucket — the masking the grouping exists to prevent. §7.4's grouping claim
  holds only for a surface that carries `id`/`app`.

- **`state/` and `wip/` grow without bound.** There is no time- or size-based retention: nothing
  expires `merged-*.done`, `fixcount-*`, `parked-*` or stale `rerun-*`. (`mergeclaim-*.lock` and
  `needsfix-*` are pruned when they are consumed or their owner dies — `merge-one.sh`'s `trap`, the
  controller's `claim_live()`, and the successful-fixer path — so they are bounded by traffic, not by
  time.) Needs a retention rule rather than an ad-hoc `find -mtime`.
- **`[ -z "$WT" ] && { … }` as a script's last statement** makes the exit status that of the
  test. The shipped `fix-one.sh` ends with a positive `echo` so it no longer leaks a non-zero
  status, but the pattern is easy to reintroduce — a `exit 0` at the end of each script would pin it.
- **Worktree reaping.** Every dispatch and every foreign-branch fixer adds a worktree; the box
  carried ~150 by the end of the run. Nothing removes them after their PR merges.
- **A persistently-colliding issue can consume the whole refresh window (agent-infra#1729).**
  `refresh-candidates.sh` spends its pre-flight budget *before* it reads the verdict, and since
  agent-infra#1716 a `COLLISION`/no-verdict pre-flight writes no `checked.txt` — so while the first
  `LIMIT` pool entries keep colliding, the entries behind them are never pre-flighted and the
  backlog silently stops refilling (the log still reports a normal `checked N; backlog now M`).
  Faithful to upstream tortoise#8515, not a porting defect; bounded by `LIMIT` (6 from the loop).
- **The fixer's CI-log fetch (agent-infra#1703).** `fix-one.sh` reads the workflow run's
  `--log-failed | tail -80` rather than the failed *job's* log, so a multi-failed-job run can feed
  the fixer the wrong check's output. Raised as a P1 in the tortoise#8298 review and never applied.
- **The runner-label gate reports success on values it never read (agent-infra#1704).** In
  `ci_runner_gate.sh`, an unreadable queue count falls through to "healthy" (the integer test
  errors and the `||` chain reads that as false) and `set_labels()` reports success when the runner
  enumeration fails (the loop runs zero times and `[ "$fail" -eq 0 ]` succeeds). Both are false
  PASSes on a gate that changes runner labels.
  **✔ FIXED in agent-infra** — both now return 2 (could-not-measure), name the failure, and leave the
  state file and the notification untouched; pinned by `scripts/ci_runner_gate.test.sh` (a bash shard
  in both CI lanes), which is red on the pre-fix tree.
- **The reaper fails open when the PR listing fails (agent-infra#1705).** `refresh-candidates.sh`
  writes an empty `.pr_brs` on a failed listing, so `has_pr` is false for every issue and PR-bearing
  issues are un-blacklisted and re-dispatched. Same class as the `open_pr_count()` fail-closed fix
  in §7.4, in a file that fix did not reach.
- **`dispatch-merge.sh` interpolates `$REPO`/`$OR` unguarded (agent-infra#1710).** Both are built into
  a tmux `sh -c` lane/chain command with no metacharacter guard — the class closed for `$O` in
  `orch-loop.sh` and for six values in `cloud-cell-supervisor.sh`. A `'` in either closes the quoted
  span; separately, a lane that dies instantly is still logged as a successful spawn.
- **The merge key reaches the controller but not the merge workers (agent-infra#1711).** The workers
  are spawned through a second tmux boundary, and a tmux session is served from the SERVER's
  environment, so with a pre-existing server a keys.env key is reported present by `cmd_check` while
  every merge runs keyless (a false PASS; `record-review.sh` then posts an UNSIGNED marker). The
  same boundary also drops `$O`, so under a non-default `$O` the workers write `state/` the
  controller never reads — recorded with the measurements on that issue.
- **This directory was older than its source (agent-infra#1712) — ported, and now pinned.** Seven
  commits merged on tortoise `main` after the copy was taken (2026-10-13 10:50Z, `eda7df136`); all
  seven are ported here, listed in the provenance note at the top. `port-provenance.txt` pins every
  file's tortoise blob hash at that sync point and `check-port-drift.sh` fails if the tortoise tree
  moves again. ⚠️ Still open, and not fixable from here: tortoise's **unmerged**
  `fix/8468-closure-linkage` branch rewrites this same directory (P0 bypass, `.prio`,
  `merged-not-closed.sh`, lane brief). The removal PR must either wait for it to merge or port it —
  deleting the directory while that branch is open orphans that work.
- **A keys.env with a top-level `exit` disables the supervisor silently (agent-infra#1713).** The
  file is sourced in the supervisor's own shell, so `exit`/`exec` ends the script: `start` returns 0
  having created no session.
- **`ci_runner_gate.sh` is versioned here but wired to nothing (agent-infra#1719).** No
  `templates/launchd/` job renders it and `pi-bootstrap/setup.sh`'s farm lists omit it, so this box
  still executes a hand-made duplicate at `~/.pi/agent/scripts/` — a fix here never reaches the copy
  that runs — and a second box has no fallback gate at all.
  **✔ FIXED in agent-infra** — `templates/launchd/com.tortoise.ci-runner-gate.plist` renders the job
  under the label the hand-made duplicate already used (so the installer converges that machine
  rather than stranding a duplicate), and `pi-bootstrap/setup.sh` (fleet_srcs) farms the script to
  the path the plist executes.
- **Two worker launch paths still spawn ungated (agent-infra#1720, partly fixed).** `merge-one.sh`'s
own `run_agent` (reached by `chain-<N>` — the first-review path for every own-lane PR — and by
  `fix-one.sh`) and `cloud-cell-bringup.sh:278` read no `MAX_LOAD`. `lane.sh`, `fix-one.sh` and
  (through it) `adopt-fix.sh` now call the shared `run_agent()` in `spawn-gate.sh`, which is what this
  entry used to list as ungated; both residuals are asserted BY NAME in `spawn-gate.test.sh:125-140`
  (§9).

---

## 8. Measured results

Branch-signature proxy: this box opens `*-tm` / `*-cap` / `*-night` / `*-evening` branches;
everything else in these counts is a peer box. Attribution by branch name is a proxy, not a
certificate — but the split is unambiguous.

| Window | This box | Peer | Notes |
|---|---|---|---|
| 2026-10-10 → 2026-10-12 (48 h) | **94 merged** | 41 merged | |
| 2026-10-11T04Z → 2026-10-12T05Z (24 h) | 51 merged | 27 merged | hour-by-hour below |
| Peak hour (2026-10-11T18Z) | **8 merged** | 0 | 8 PRs in 60 minutes |
| The 2026-10-10T23:45Z → 2026-10-11T21:22Z run | 77 → **99 merged** | — | this box's own handover record |

Hourly histogram (00:00Z–23:00Z on 2026-10-11, merged / this-box):

```text
04: 1/1   05: 4/3   06: 3/2   07: 5/5   09: 3/3   10: 3/2   11: 3/3
13: 2/1   14: 3/2   15: 4/2   16: 6/5   17: 7/5   18: 8/8   19: 3/3
20: 3/1   21: 3/1   22: 5/4   23: 2/1
```

Observed steady state on the original 8 GB host: 15 concurrent workers (4 lanes + 4 chains + 3 fixers +
4 reviewers), load 7–18, swap 588 M–832 M free, dispatch throttled by the swap gate.

**Honest caveat on the comparison.** Two boxes running this harness against one repo
duplicate work unless they coordinate: both may pick the same issue, and both run the merge
sweep over the *same* PR queue. A large part of the throughput above is the harness keeping
a box saturated for hours with no human, plus the box holding the merge key — not an
algorithmic advantage. The claim worth evaluating is *utilisation*, not *efficiency per PR*.

---

## 9. What is shipped

**Live** (reachable from `orch-loop.sh`):

| Script | Role |
|---|---|
| `orch-loop.sh` | the controller: merge sweep → capacity-gated dispatch → backlog refresh |
| `claims.sh` | cross-box claim registry: `refs/claims/<PR>-<head-sha12>` for PRs and `refs/claims/issue-<N>` for issues (agent-infra#1850), same CAS, lease-as-data and `--force-with-lease` fencing. Sourced by `orch-loop.sh`, `refresh-candidates.sh`, `chain-merge.sh`, `dispatch-merge.sh`, `merge-one.sh` and `fix-one.sh` |
| `repo-authority.sh` | **the per-repo merge contract** (agent-infra#1764): reads THIS repo's required status checks and derives whether the review gate applies to it, so the controller no longer enforces tortoise's check names on every repo. Fail-closed — an unreadable or unrepresentable set refuses. Sourced by `orch-loop.sh` and `merge-one.sh` |
| `spawn-gate.sh` | the load and disk gate (`disk_free_mb`/`disk_ok` `:193-231`, `can_spawn` `:269`) plus the ONE `run_agent()` (`:305`) used by `lane.sh` and `fix-one.sh`, so a `lane`/`fix` worker started by hand is gated exactly like one the controller spawned. ⛔ Not every spawn goes through it: `merge-one.sh` defines its own `run_agent` (`:74`, called `:461`) for the reviewer, and `cloud-cell-bringup.sh:278` invokes `pi -p` with no gate at all (`agent-infra#1720`). Both residuals are asserted **by name** in `spawn-gate.test.sh:125-140`, whose census is an EQUALITY over `scripts/` — so a new ungated invoker fails the suite instead of arriving unannounced, within that census's three declared limits (`spawn-gate.test.sh:98-106`) |
| `dispatch-merge.sh` | creates the worktree and starts the `lane-*` + `chain-*` pair for an issue |
| `lane.sh` | the implementation worker (prompt template included) |
| `chain-merge.sh` | waits for the lane's PR, then runs the merge chain |
| `merge-one.sh` | fresh review → signed record → wait green → merge; marks `needsfix-*` |
| `fix-one.sh` | fixes a reviewer's findings, pushes, re-runs the merge chain |
| `refresh-candidates.sh` | pre-flights issues (collision check) into the backlog |
| `selftest.sh` | offline checks; each one drives the shipped code. Not part of the loop |
| `install.sh` / `launchd-cycle.sh` | the installer, and the ONE implementation of stop/enable/(re)start/verify for the launchd job (§4). A plain `install.sh` never touches a loaded job; `--start`/`--restart` harness the loop and PROVE it started. The library never writes a persistent disable and never mutates a job that was not loaded from this plist |
| `install-launchd-durability.test.sh` | the agent-infra#1975 contract — no persistent-disable verb in code or in a copyable README command, `bootstrap`→`load` fallback, the ownership guard, and "not running AND (disabled OR exit 0)" as a FAILURE. Hermetic (`launchctl` stub first on `PATH`, throwaway `$HOME`/`$O`), and a CI shard via `scripts/run-bash-shards.sh` |
| `test-gates.sh` | the `mp_reason` dispatch-gate rule table, extracted from the shipped `orch-loop.sh`. Not part of the loop |
| `test-claims.sh` | the PR **and issue** claim CAS against live origin from two scratch repos (`git init` + `remote add`, not clones; random keys per run so concurrent runs cannot collide). Not the cross-box proof (one machine), but red on a defeated CAS. Not part of the loop |
| `claim-exclusion.test.sh` | **the measurement:** N processes released at a barrier against a real (bare) origin, per operation class, answering *does a duplicate holder get refused*. Prints the table §7.2d records; hermetic, a CI shard |
| `gh-limit.test.sh` | #1988 the layer UNDER every gh call: one call in flight per box — the retry path AND the `/rate_limit` probe (measured from the stub's own timestamps, with an unserialised control that MUST overlap), the documented backoff order (`retry-after` → the bucket's reset → ≥60s doubling, 4 attempts, then a loud failure), the failing bucket NAMED, `>= 1s` between mutations, conditional REST (`if-none-match` → a 304 replayed byte-exactly from a bounded cache), and the shim surviving the `/opt/homebrew` PATH prepend in every gh-calling script. Fake clock, stub gh, hermetic, a CI shard |
| `gh-rest.test.sh` | the `gh` REST adapter's argv-to-argv **TRANSLATION**, offline against a stub `gh`: `pr list --head` must not widen to the newest open PR and `pr comment` must print a URL (both shipped green once, as P0s, when nothing asserted them). Hermetic, a CI shard |
| `test-crossbox.sh` | drives the real `merge-one.sh` claim acquire + trap release with `gh` stubbed. Not part of the loop |
| `refresh-scout.test.sh` | the agent-infra#1736 contract — repo-aware scout provisioning, per-repo tool resolution, the permanent/transient refresh split — plus the agent-infra#1850 issue-claim pre-flight verdict table (CLEAN/COLLISION/INCOMPLETE/NOT PROVISIONABLE/unrecognised), the dispatch-side claim, and the fenced + generation-guarded release. Also the agent-infra#1729 pass budget: a blocked pool HEAD does not consume the window, the collision ledger defers (never drops) a held candidate, and ONLY a COLLISION is recorded — a DEGRADED answer never is. Not part of the loop |
| `refresh-quota.test.sh` | the per-pass API **spend** contract (agent-infra#2022 / #1736 follow-up): the board cache is enabled under the TOOL's own seam (`COLLISION_PREFLIGHT_BOARD_CACHE`, not the legacy no-op name the tool treats as a caller-named-cache attack), so one pass rebuilds the board once instead of once per candidate; a pass that can only afford SOME of its window judges those completely, queues work and NAMES the stop; a pass that can afford none refuses TRANSIENTLY — after the `dispatched.txt` reaper has run — rather than reporting an empty backlog. Charges a modeled core budget from a stub `gh`, so it needs no network. A CI shard |
| `check-port-drift.sh` | gates the tortoise-side removal: fails if the tortoise harness moved past the pinned sync point (`port-provenance.txt`). Not part of the loop |
| `cloud-cell-doctor.sh` | the cell's scheduled roles — `reap` / `doctor` / `merge` / `hygiene` / `status` (§6.5.7). Launched as tmux `cell-doctor` by `cloud-cell-supervisor.sh start`; `merge` EXECUTES `scripts/admin-merge.sh` and never re-implements it |
| `cloud-cell-doctor.test.sh` | #1989: drives the shipped doctor and the supervisor's role verbs against stubbed tmux/ps/rail — a lane whose child is still writing is NOT reaped, an attached/human-tty lane is NOT touched, the rail is gated on a clean attestation at the head, a refusal is recorded and not retried at the same head, and `status` FAILS a started cell whose roles never ran. A CI shard |
| `cloud-cell-record-dep.test.sh` | #1717: drives `cloud-cell-supervisor.sh check/start` and `merge-one.sh` against a stubbed toolchain — the recorder is a checked, provisioned dependency, and a record failure parks. Registered in `scripts/run-bash-shards.sh`, so both CI lanes run it |
| `check-deployed-drift.sh` | answers whether the DEPLOYED `$O` matches the repo: the recorded commit against the live ref (`merge-base --is-ancestor`, never a commit count), the recorded payload hash against the deployed bytes, and every repo-shipped `*.sh` blob against its `$O` copy. Exit 0 match / 1 drift / **2 UNKNOWN — never a pass** (agent-infra#1745). Not part of the loop |
| `report.sh` | read-only operator summary: merges in a window, per-kind agent wall-time and cap-hit rate from `state/walltime.tsv`, live `refs/claims/*`, queue health, and the last dispatch decisions. Safe to run while the loop is working. Not part of the loop |

**Manual utility:** `adopt-fix.sh` — run `fix-one.sh` against a specific PR by hand;
`nonblocking-dispatch.sh` — launch a headless worker in the background and return immediately (§2).
Neither is part of the loop.

**Retired** (`retired/`, kept so nothing is lost): `auto-loop.sh`, `dispatch.sh`,
`do-merge.sh`, `refix.sh`, `sweep.sh`, `watch-one.sh`. These are earlier iterations of the
same idea and are no longer invoked; they are included for the record, not for use.

### Which harness commit is this box running? (agent-infra#1745)

On the deployed laptop box the question had **no answer**: the daemon executes `$O/<script>` and
`~/orchestrator` is not a git checkout at all (`git rev-parse --show-toplevel` → `fatal: not a git
repository`). `install.sh` now records the source identity into `$O/.agent-infra-stamp.json` — the
SAME cell-shaped record `cloud-cell-supervisor.sh` writes on a cmux cell, so there is one stamp
concept, not two. `commit` names the source tree, `payloadSha256` covers the `*.sh` the daemon
actually executes (the commit cannot see a post-install hand edit to `$O`; the hash cannot say
whether the commit is on the repo's line), and `agentInfraDirty` says whether that source tree was
clean when it was copied. The answer is a file read, not a `git` call.

```bash
sed -n 's/.*"commit"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$O/.agent-infra-stamp.json"
```

`check-deployed-drift.sh` answers the next question — does the deployed `$O` actually match the repo?

```bash
./check-deployed-drift.sh            # 0 = match, 1 = drift, 2 = UNKNOWN (cannot verify)
```

⛔ **`UNKNOWN` is never a pass.** A missing record, an unreadable one, `commit: UNKNOWN` (the source
was not a checkout), or an unresolvable ref exits **2**, not 0. That is the rule #1790 measured on
the cells: `check` printed `CELL CAN RUN A CONTROLLER` over a tree that was not on `main`'s line,
and over a copy whose bytes matched `main` but which carried no git identity. The laptop is the
same class with a worse starting point — no record at all — so its absence fails the check loudly
instead of reading as healthy.

**Portability edits applied to the shipped loop.** Three per-box constants became overridable — with
this box's values still the default for `OR` and `O`, and **no default in the scripts that refuse
their own REPO**; SEVEN shipped shell scripts still carry one, plus an eighth instance in a `.py`
(#1935/#1977, enumerated in §4 step 2). The launchd
`PATH` is no longer one of them: `install.sh` renders the `__PATH__` placeholder from the directories
`tmux`/`gh`/`uv`/`pi` actually resolve to, refusing any `*/shims`, `*/shims/*` or `*/.pi/*` directory
because macOS TCC makes such a symlink EPERM under launchd, and then probes each tool by executing it.
⛔ Cite the two helper defaults by SYMBOL (`REPO="${REPO:-…}"`), not by line: #1977 deletes those
exact lines.

```bash
OR="${OR:-daniel-ospina/tortoise}"
REPO="${REPO:-}"        # ⛔ REQUIRED, no default — the loop refuses it by name (above;
                        # refresh-candidates.sh:18 and cloud-cell-supervisor.sh:93 are
                        # #1977's; five more carry one, listed in step 2)
O="${O:-$HOME/orchestrator}"
```

The shipped copies are **not** byte-identical to the ones running on the original box: they are
those copies **plus every §7.4 fix** (and the §7.4b and §7.4c ones). `install.sh` compares the scripts it invokes — the ten loop
scripts in §9 plus the manual `adopt-fix.sh`, and `gh-rest/gh` — against the running copies at `$O` and warns loudly
on drift, because the daemon executes `$O/<script>` — a fix that only lands in this directory is not
in effect. That set is the one `install.sh`'s drift loop lists; `selftest.sh` is shipped but not
compared, since the daemon does not run it. If you are adopting this onto an existing box, sync
them (`cp <harness>/*.sh $O/`) and restart the loop before trusting any §5 invariant.

⛔ **Copying the scripts is not enough when a *limit* changed.** The launchd plist carries its own
environment block, rendered by `install.sh` from these defaults, and that environment **overrides the
script's own**. A job already loaded with `MAX_LOAD=16` keeps `16` no matter what `orch-loop.sh` now
defaults to. `install.sh` overwrites the plist *file* but does not reload an already-loaded job, and
`launchctl load -w` on a job that is already loaded does not reliably re-read it. So for a limits
change: re-run `bash scripts/orchestrator-harness/install.sh --restart` — it re-renders, `bootout`s,
`bootstrap`s and then verifies pid + heartbeat. (Plain `… install.sh --start` also reloads, but only when
the loaded job was NOT recorded as this render — the render launchd was last seen loading is written to
`$O/state/launchd-loaded.sha256` at every successful start, because "the file did not change" is not the
question: a plain run overwrites the plist without reloading it. An absent record is reported as
UNKNOWN, not as "the old settings are live", and unknown reloads once. So a validation run cannot
disturb a healthy controller, and the first `--start` after upgrading records the render. A plain
`… install.sh` never touches a loaded job; it warns, naming `--restart` only when it can show the loaded
job is on an older render.)

⚠️ **And `launchctl bootout` touches nothing when the controller was not started by launchd.** A loop
started as `nohup … orch-loop.sh` from a session has no launchd job at all, so a bootout/bootstrap pair
is a no-op *for that process* and the old controller keeps the old limits: the operator believes a
limits change took effect when it did not. The two reads that answer it are
`launchctl print gui/$(id -u)/com.eldato.orchestrator-loop` (its `path` and `pid` — or `rc=113` when
there is no job) and `cat ~/orchestrator/.orch.lock`; `install.sh --start`/`--restart` **refuse** to
start while `$O/.orch.lock` holds a live pid that launchd is not running (launchd's copy would exit at
once on that lock and `KeepAlive` would relaunch it forever) and tell you to stop it first. Stop a
session-started controller with `pkill -f "[b]ash $O/orch-loop.sh"` (§6) rather than with `launchctl`.

> Do not record "on this box the loop runs under nohup" as a fact — it is a state, and it changes: on
> 2026-10-17 this box was launchd-owned for part of the day and session-owned for another part. Read
> the two commands above at the moment you care.

Everything else is still tortoise-shaped and must be changed on another target: the branch
suffix (`tm`), `feat/<N>-tm` naming, `lane.sh`'s `uv sync --extra embeddings --extra parity`, the
`TORTOISE_TEST_CARVE_OUT=1 .venv/bin/python -m pytest` invocation.
The required-check list is NOW repo-aware: it is read from the target repo's branch protection
(`gh api repos/$OR/branches/main/protection/required_status_checks`), `REQ=…` overrides the read,
and `FALLBACK_REQ` in `repo-authority.sh` is the non-empty fail-closed last resort when protection
cannot be read. The merge authority follows from that set: a repo requiring the review gate merges
via `gh pr merge` after the gate goes green, and a repo that does not is merged through its own
`scripts/admin-merge.sh` (agent-infra#1764).
Two things that were on this list are now repo-aware: the collision pre-flight tool is resolved per
repo (the target repo's own copy, else a `TORTOISE_REPO` checkout) and the scout venv step is skipped for
a repo with no `pyproject.toml` — and a repo that can be provisioned is verified at `check` time —
agent-infra#1736.

---

## 10. Open questions for the evaluator

1. ~~Does this belong in `agent-infra` (symlink-distributed via `manifest.json` + `sync.sh`,
   pull-only) rather than in a repo's `operations/`?~~ **Answered 2026-10-13:** moved to
   `agent-infra/scripts/orchestrator-harness/` (agent-infra#1700).
2. Should the two boxes coordinate through an explicit claim registry instead of branch-name
   heuristics? tortoise#5052 already proposes "an authoritative, expiring claim registry" —
   §7.1 is the same problem seen from the dispatcher's side. **Partly answered 2026-10-15/16:**
   both keys now exist (`refs/claims/<PR>-<head-sha12>` for merges, `refs/claims/issue-<N>` for
   dispatch — §7.2b/§7.2d). What is still open is **coverage, not mechanism**: every path that can
   take work must remember to acquire, and an issue claim is still no proof of life.
3. Is a `~/`-rooted bash harness the right shape at all, or should this fold into the fleet
   rail's cmux workspaces (agent-infra#1683)?
