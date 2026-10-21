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
> lane brief). This PR ports it: `merged-not-closed.sh`, the severity-ordered pool and the
> `Closes`-not-`Refs` lane contract are in, and **the `.prio`-keyed P0 bypass is NOT** — main's
> merge-priority rule became unconditional (owner ruling, 2026-10-18), which supersedes it; see
> "Ports taken from the retired fork" below.
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
  itself instead of thrashing. While **any** unowned but workable open PR remains, the only work this
  cell creates is **taking one on** (§7.2f): issues are not picked until the un-owned queue is empty.
  An "unowned" PR is one **nothing live is working** — the test is a live process whose cwd is on that
  PR's head ref (or whose path carries the PR number), plus a live claim from another box; session
  names, `needsfix-*` markers and local claim refs are NOT ownership, because they outlive the process
  that wrote them. Because a merge backlog means the scarce capacity belongs to review and merge, the
  reviewer AND fixer headroom rises (`MAX_REVIEW+2` / `MAX_FIX+2`) rather than the fleet idling.
  Counting TOTAL open PRs instead capped the fleet on a busy queue: a PR mid-review, mid-fix,
  mid-merge — or held by a claim on another box — read as congestion. Measured 2026-10-16, two live
  cells logged `merge-priority (20 open PRs — draining)` at `lanes=1` of a configured 32 with
  59-86% CPU idle and 13.9 GB RAM free (agent-infra#1824; see the tuning table in §4).
  ⚠️ A cross-box claim is a **declared window**, not proof of life — `claims.sh` is explicit that a
  lease is *data, not liveness* (a REMOTE pid cannot be probed), so an abandoned claim reads as owned
  until the lease expires — **unless the holder can be shown ORPHANED** (§7.2b, `agent-infra#2094`:
  this box's own former host name, a host on `CLAIM_DEAD_HOSTS`, a host absent from a current
  `CLAIM_KNOWN_HOSTS` roster, or a local pid that is gone for a PR claim). The residual is a claim
  from a host none of those rules can judge — an unknown name with no roster — which still reads as
  owned until its lease expires; it is an under-count of orphanhood on purpose, because the
  over-count direction steals a live peer's work. The direction is recorded on `pr_owned()` in
  `orch-loop.sh`.
- **Self-healing:** a PR whose reviewer reports real findings is routed to a *fixer*, fixed,
  and re-reviewed — rather than being left red forever (this is the bug that stranded ~15
  PRs before it was fixed; see §7).
- **A capacity pool, not only an isolation boundary.** The five machines are not five independent
  single-host harnesses that happen to share a repo; they are **one pool of capacity** over one
  queue. So a per-machine capacity decision must never become a fleet-wide one: when a box refuses
  an item because *it* is full, the item stays **eligible on every other box**. That is the
  requirement this document calls **R8** (agent-infra#1909), and it is not automatic — the refusal
  used to hold the cross-box issue claim for 90 minutes while the chain waited for a PR no agent
  could open, so one load spike made the issue ineligible on all five boxes at once. Measured
  2026-10-17: the Mac refused at load 98-180 (correctly) while cell-2 sat at 0.29 load with 14.5 GB
  free and cell-3 at 0.04 load, and **47 P0/P1 issues went untouched with ~20 vCPU idle on the same
  account**; the gap was filled by hand with six manually-created dispatch lanes. The transfer
  mechanism is in §7.2d — and it is deliberately **not** built on load average: the signal is the
  worker gate's own refusal, whatever it bound on (that gate binds on **load or disk**; the
  lanes/swap/memory terms belong to the controller's separate gate, which refuses before any claim is
  taken), because load is a
  symptom of contention rather than a measure of capacity (`docs/ops/load-policy.md`), and a
  capacity gate a caller can skip is not a gate (agent-infra#1884).

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
                        1. a head-bound review RECORD already in the store at this head → straight to
                           the rail (the normal case: the lane's own review pass recorded one)
                        2. otherwise the review path above RUNS FIRST (agent-infra#1825): the rail is
                           no longer an excuse to skip the review, because `pipeline-compliance`
                           check (c) — this repo's only required check — accepts nothing but that
                           record. Then → `scripts/admin-merge.sh <PR>`, the repo's own rail, which
                           posts its own head-bound evidence and merges. `gh pr merge` is NEVER
                           called here: it would land on the required checks alone, bypassing the rail.
                           Refused 3x at one head → PARK that head.
                        ▼
        fix-<PR>   → fix-one.sh  : materialises a worktree for the branch (including foreign
                                   branches), runs a fixer over the reviewer's findings, pushes a
                                   new commit, then re-runs merge-one.sh end-to-end
```

### State files written by the merge sweep

| file | written by | lifetime |
|---|---|---|
| `state/prclass.tsv` | the sweep's classifier, one row per PR per cycle | folded at the top of the next cycle by `lo_class_compact` (it decides the ORDER only) |
| `state/pr-meta.tsv` | the 200 listing, PR → `created_at` | rewritten on every 200 (never appended) |
| `state/last-open-prs` | `open_pr_count`, `number:headOid:headRefName` | rewritten per read; DELETED on a failed read (so "no rows" means "not known to be owned") |
| `state/prdisp.tsv` | the sweep + the parent, `pr \t head \t token \t act\|wait \t reason` (**agent-infra#2126**) | **truncated by the parent before the sweep**, at most one row per PR per cycle. It is a RECORD of what the drain acted on or why it did not — never an input to the count or the gate (pinned by `test-gates.sh` and `pr-dispatch.test.sh`). `act` means an action the cycle ACTUALLY took — a worker spawned, a merge issued, an auto-merge armed, a draft readied, or a CI rerun — and `wait` means a row with a printed reason; both count ROWS (the line prints `row(s)`), and the swept set also carries owned PRs, so neither number is ever printed as a count of un-owned PRs. `first #N` and the funnel's "dispatching"/"NO UNIT SPAWNED" wording are both derived from it, so a printed claim has an action or a named wait behind it — and a cycle that recorded nothing says so instead. Two degraded states are named instead of guessed: an **unwritable** `state/` reads `record UNWRITABLE … UNKNOWN, not zero`, and a cycle with **no recorded rows** reads `NO ROWS … either the listing returned no rows, or the record could not be written … UNKNOWN, not zero` (a truncate succeeds with no allocation, so a full `state/` passes the writability probe and then fails every write — the row count cannot tell those two causes apart, so the line names both). The funnel is handed the same third fact, so it cannot print a measured zero for a cycle that measured nothing. On a population that is not enumerable (the count came from the listing while the ledger only holds the swept set) the line carries an explicit `NOT enumerable this cycle` caveat — the two numbers have different denominators and are never printed as if they shared one. |

### Worker types

| Session | Script | Writes to | Purpose |
|---|---|---|---|
| `lane-<N>` | `lane.sh` | `.worktrees/tm-<N>` on `feat/<N>-tm` | implement issue #N → commit → push → open PR |
| `chain-<N>` | `chain-merge.sh` | — | wait for the lane's PR, then delegate to `merge-one.sh` |
| `merge-<PR>` | `merge-one.sh` | — | **repo-authority-dependent**: gate mode = fresh review → signed record → wait green → squash-merge; rail mode = (a head-bound record already at the head, else the same fresh review → signed record first) → the repo's own `scripts/admin-merge.sh` (#1825) |
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
| `state/mergeclaim-<PR>.lock` | single-owner claim: only one worker may review/record/merge a given PR. **Per box** — the cross-box fence for the landing path is `refs/claims/pr-<PR>` in the shared repo (§7.2b) |
| `state/needsfix-<PR>-<head>` | "a reviewer found real issues at this exact head" |
| `state/fixcount-<PR>` | fixer attempts for that PR, capped by `MAX_FIX_TRIES` |
| `state/parked-<PR>` | terminal state: the fixer cap was reached at the head recorded inside the file, so the sweep skips it until a new push re-arms it |
| `state/rerun-<PR>-<runid>` | CI re-run already requested for this run — prevents loops |
| `state/merged-<PR>.done` | merge confirmation |
| `state/last-open-n` | the last SUCCESSFUL open-PR count; reused only when positive if a later count fails — a failure never reads as 0 |
| `state/last-open-prs` | the `number:headOid:headRefName` rows from that same SUCCESSFUL listing — the **ownership scan's** input (`unowned_pr_count`) and the selection's population. The head ref is what the live-process predicate is matched against; a row is only used when it has all three fields, so a truncated file cannot read as "nothing is owned". A missing/unreadable file is UNKNOWN, not empty: `open_pr_count` REMOVES it on a failed read and the gate then blocks on the fail-closed listing count. Written on success and REMOVED on a failed listing, so a fallback count is never paired with the previous listing's rows; absent rows mean **nothing is owned** (the whole count is unowned), which is the fail-closed direction. Both files come from ONE `gh pr list` call. |
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
(the `cp "$HERE/gh-rest/gh"` staging line); everything else is the operator's `cp`, §4 step 1. Its
`DRIFTED` warning iterates an explicit `for f in …` list (`DRIFTED=""` in `install.sh`), and this
file **is** on it (added when `pr-doctor`'s dispatch was wired to it, #1890), so a missing or stale
`$O/nonblocking-dispatch.sh` names itself instead of silently leaving every background dispatch to
fail. ⛔ A stale copy is
still REPORTED, twice: the provenance stamp's `deployedMatchesSource` compares **every** shipped
`*.sh` against `$O`, and `check-deployed-drift.sh` fails on any differing
blob. What puts this file in `$O` is the install step in §4 — `deploy-mac-orchestrator.sh`, the
symlink-farm route, or (legacy, plain-directory `$O` only) `cp scripts/orchestrator-harness/*.sh
~/orchestrator/`. Whichever you used, re-run it after editing this script: on a symlink farm the
`cp` form refuses with "are the same file". There, re-point the links at the new
checkout (or re-run your farm installer) — do **not** run the plain `cp`, and note that
`deploy-mac-orchestrator.sh`'s `install_file` ends the farm: it writes a temp file and renames it
onto the destination (`mv -f`), and a rename over a symlink replaces the LINK, so `$O/<script>`
becomes a real copy and `doctor` then reports `kind=stamp` instead of `kind=linked-checkout`.

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
| `pi` on `PATH` | the worker runtime (`pi -p --provider deepseek --model deepseek-v4-flash`) | provider/model are literals in the shared `run_agent` (`spawn-gate.sh`, sourced by `lane.sh`/`fix-one.sh`) and in `merge-one.sh` — change them there |
| `uv` | `lane.sh` runs `uv sync --extra embeddings --extra parity` in each worktree | tortoise-specific; `refresh-candidates.sh`'s SCOUT venv is repo-aware since agent-infra#1736 (skipped when there is no `pyproject.toml`; the extras are read from that project) |
| `python3` | `orch-loop.sh`'s required-check classifier and `fix-one.sh`'s failing-check list | absent, the classifier returns an empty verdict, no case arm matches, and **every PR is skipped in silence** |
| `~/.pi/agent/scripts/record-review.sh` | writes the HMAC-signed review marker the `ai-review-gate` check verifies | shipped by `agent-infra`; **gate mode only** — a repo that does not require the gate consumes no such marker, so `merge-one.sh` does not mint one there. A cell's `start` provisions it when the cell has none — see below |
| **the operational layer** (`~/.pi/agent/{scripts,extensions,skills,AGENTS.md,settings.json}`) | a lane is only as guarded as its `pi`; without the layer a box has **no review-enforcer, no verification-gate, no main-worktree-guard, no search-guard, no audit-logger, no skills** | installed by `pi-bootstrap/cell-install.sh`, and on a cell it runs from `cloud-cell-bringup.sh --check`. Measured 2026-10-15 on a live cell: `scripts/` did not exist at all (24/24 declared farm files absent), and the merge path died `rc=127` on the missing `record-review.sh` (agent-infra#1723) |
| **`AI_REVIEW_GATE_KEY`** | the merge authority — env var, or `~/.pi/agent/.ai-review-gate-key` | **this harness cannot merge a gate-mode repo without it.** Treat as a secret; never commit it |
| **`DEEPSEEK_API_KEY`** | the WORKER RUNTIME's provider credential — `pi -p --provider deepseek` (in the shared `run_agent` that `spawn-gate.sh` defines, sourced by `lane.sh`/`fix-one.sh`, and in `merge-one.sh`) cannot authenticate without it | `start` publishes the NAME (never the value) into tmux `update-environment`, so a worker the controller spawns inherits the value the controller sourced from `keys.env`. Measured 2026-10-16: with the name absent a cell still MERGES (the rail needs no agent) while every review and fixer died `No API key found for deepseek` — RUNNING, burning its dispatch capacity, unable to review, fix or dispatch (agent-infra#1852). `keys.env`/the shell is the authoritative source: a listed name the creating client lacks is STRIPPED by tmux, so a value living only on the tmux server is not a supported configuration. Treat as a secret; never commit it |
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
*signed* merge in a gate-mode repo. **`DEEPSEEK_API_KEY` is the same shape, one step further:**
`start` now publishes the NAME into tmux `update-environment` (agent-infra#1852, below), but `check`
does **not** probe that a VALUE exists anywhere — a name held by neither `keys.env` nor the ambient
shell is stripped by tmux, so every review and fixer still dies `No API key found for deepseek` while
`check` prints the banner. That probe is #1852's candidate fix 3, deliberately NOT claimed by
agent-infra#1896: it has its own false-block risk (a value that lives only in the key FILE, or a cell
provisioned for a provider other than deepseek), so it is tracked on the issue rather than asserted
here. Do not read `CELL CAN RUN A CONTROLLER` as proof that a worker can authenticate.

The `.worktrees/` gitignore is not probed at all, and
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
`ask-owner.py`, `turn-classify.py`, `turn-end.py`, `undelivered-answers.py`, `pr-doctor.py` —
EIGHT, not the nine this list carried before agent-infra#1874 retired `retired/queue-dispatch.py`;
a retired tool is not in the beat, so it is not counted here) prefer `$O/gh-rest/gh` then
`$O/gh-limit/gh` over their pinned real binary — derived from `$O`, never from PATH.
⛔ THAT DOES NOT KEEP #1872'S PIN BY ITSELF: the layer resolves the real
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
  a busy box cannot queue a 90 s reader to death); the EIGHT heartbeat tools set it (it was nine
  until agent-infra#1874 retired `retired/queue-dispatch.py`; the count is the same eight
  `docs/ops/gh-rate-limits.md` lists), because they are killed at 90-420 s while the first documented
  backoff is 60 s — sleeping there converts a
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

⛔ **"Installed" and "ACTIVE" are different questions, and the layer answers only the first.**
`docs/ops/ACTIVATION-MATRIX.md` (agent-infra) is the one place that records, per component, how it
becomes active on a Mac vs a Linux cell and whether that is **provisioned** (a shipped file installs
it and a read-back verifies it) or **improvised** (a shell-rc line, a hand-written plist, a symlink
into a worktree, an operator-pushed file — nothing re-creates it). Read it before concluding that a
green `CELL READY` means a guarded lane: two components that decide whether the box is *unattended*
— the argv-level `gh` shim and the controller watchdog — are improvised on the Mac and absent on
cells today. `cell-install.sh --verify` now prints one `activation:` line for the shim, resolved
through the **same** candidates `review-enforcer` reads, so the row is checked rather than asserted.

**On a Mac (or any box you own),** do all four steps below from the ROOT of an agent-infra
checkout:

```bash
# 1. Run all four steps from the ROOT of an agent-infra checkout — the harness now lives there.
#    Put it where $O will point (default ~/orchestrator): the daemon executes $O/<script>,
#    not the shipped copies.
#
#    ⛔ PREFER THE VERSIONED SHAPE — this is §11's rule, applied to the install step (§11 is why the
#    three-way fork happened: `~/orchestrator` was 8 of 8 files with NO git). Two supported routes:
#      * macOS:  bash scripts/deploy-mac-orchestrator.sh   (copies the harness, stamps the commit)
#      * any box: make $O a symlink farm into a git clone, so "which commit is this?" has an answer —
#                 bin/harness doctor reports that as kind=linked-checkout
#
#    ⚠️ THE PLAIN `cp` BELOW IS THE LEGACY ROUTE AND IT IS NOT A FIX PATH: on the symlink-farm shape it
#    does not merely go stale, it FAILS — measured: `cp scripts/orchestrator-harness/x.sh $O/` where
#    `$O/x.sh` is a symlink into this checkout prints `cp: '…/x.sh' and '…/o/x.sh' are the same file`
#    and exits 1, naming no next step. Use it only when $O is a plain directory you intend to keep as
#    one, and re-run it after every harness edit (a copy is not a fix — §11).
mkdir -p ~/orchestrator && cp scripts/orchestrator-harness/*.sh ~/orchestrator/
mkdir -p ~/orchestrator/logs ~/orchestrator/state ~/orchestrator/wip

# 2. Point it at your box. MOST values are overridable with a default; REPO is NOT — see below.
export REPO=$HOME/eldato/tortoise        # REQUIRED: the target repo's local main checkout.
# ⛔ OR is DERIVED from $REPO's origin remote (agent-infra#2040) — do NOT pin it unless this box must
# grade a DIFFERENT repo's queue than the one it dispatches into. A standing literal here meant the
# controller counted one repo's open PRs while dispatching another's issues (measured 2026-10-18).
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

**The load gate is installed as `pi` itself (agent-infra#1884).** `spawn-gate.sh` is double-duty: the
library `lane.sh`/`fix-one.sh` source, AND an executable that both installers copy to
`$HOME/.pi/agent/bin/pi`, one of the first directories on PATH on every surface (and kept in the
runner-gate plist PATH, so the daemon and the tmux children it starts inherit it). Every process that
runs `pi` therefore resolves the GATE, not just the callers that remembered to source it: a
hand-written `tmux new-session -d -s x "… pi -p …"` runner included. That path was the defect —
nothing refused, logged or counted, and the box went to load 258 against its own `MAX_LOAD=100`. A
refusal is loud (1-min load, ceiling, the item, and the calling process), counted in
`~/.pi/agent/state/spawn-gate.tsv` (allowed runs too; bounded by a one-generation rotation at 5 MiB,
because this is the highest-volume sink in the tree and a device that fills silently is #1765's
defect), and exits 76, which `run_agent` translates to
the callers' usual `AGENT_LOAD_REFUSED`/`AGENT_STARTED=0`. Its stated limits are in the file's header:
the real binary by ABSOLUTE path or a `PATH` reset is not gated (deliberately — that is the
operator's rescue route when the box is over its ceiling, and the refusal message prints it), a
caller that exports its own `MAX_LOAD` sets its own ceiling, and a box where neither installer has
run has no shim. `pi-bootstrap/cell-install.sh --verify` byte-compares the installed copy.

### Tuning (10-core / 32 GB box — the values that were actually used)

| Var | Value | Why |
|---|---|---|
| `MAX_LOAD` | `cores*10` (100 on a 10-core box; sanity ceiling) | dispatch stops above this 1-min load |
| `MAX_LANES` | **derived**: `10#$_NCPU * 5 / 2` — 2.5× cores, floored (25 on a 10-core box, 10 on a 4-core box, 10 on an unprobeable host) | concurrent implementation lanes. **Capacity gates dispatch, not a lane count** (owner ruling, 2026-10-17, verbatim: *"dispatch should be gated on capacity, not on number of lanes. max lanes 8 is too low. that needs to be configured to 2.5x the number of CPUs"*). The shipped default was a flat `4`, and the box this was measured on had its plist **pinned** at `8`: `[cap] load=79/100 lanes=9/8 … [dispatch] skipped (lanes=9>=max_lanes=8)` — 21 points of load headroom and comfortable swap/memory, so dispatch was refused for a lane count while capacity was available. A **valid** pin (plist/`keys.env`) still wins and is never recomputed; an **invalid** one is refused by `install.sh` and repaired by the loop to the derived default; a derived value that fails `is_limit` falls back to `10`. ⚠️ The plist **pins** the number, so a box picks this default up only on a fresh `install.sh` render. ⚠️ `2.5 × cores` is ALSO `LOAD_SUSPEND_THRESHOLD`'s default (`docs/ops/load-policy.md` §2) — that is a 1-minute **load** threshold, this is a count of **lanes**; they are not one ceiling |
| `MAX_REVIEW` | `4` | concurrent `merge-<PR>` reviewers |
| `MERGE_PRIORITY_AT` | `25` | **no longer a gate — headroom only.** The gate is threshold-free (§7.2f): one workable un-owned PR is enough to stop the issue path, and there is no age-based release (a stalled drain gets `DRAIN STALLED`, never a licence to open work). This value now only selects the *drain posture* — from here the reviewer/fixer headroom rises to `MAX_REVIEW+2` / `MAX_FIX+2`, so a 25-PR backlog is drained by the capacity that actually clears it instead of being capped to a trickle. Kept as a name because operators and the `[cap]` line read it |
| `MERGE_STALL_MIN` | `180` | **display only.** The age at which the `[dispatch] DRAIN STALLED — no PR merged in <age>m while <n> un-owned remain` diagnostic fires. It gates **nothing**: the issue path is closed by un-owned PRs, not by a land age, so a big or unreadable value can never open it. An unset or non-numeric value falls back to 180; a land marker stamped in the FUTURE prints `DRAIN STALL UNMEASURED` (neither a stall nor an all-clear) instead of a fresh `0m` |
| `MERGE_PRIORITY_MAX_AGE_MIN` | `180` | **display only** — the `[cap] last_land=` field and the `DRAIN STALLED` line. ⛔ This knob used to bound an age-based RELEASE of the gate; that was **deleted** (agent-infra#2099): the release turned *PRs are not landing* into *dispatch more issues*, hiding a stall behind fresh activity, and no unattended lane can move the unowned count itself (every session authenticates as the same GitHub user). `test-gates.sh` pins the release machinery ABSENT |
| `FUNNEL_MAX_AGE_MIN` | `30` | how old a `state/refresh-funnel` record may be before the `[dispatch]` line prints `funnel STALE(<age> > <bound>)` instead of that record's decomposition. The refresh exits before writing its funnel on the pool-read and provisioning paths, so an old pass's numbers can sit beside a newer `queue=READ(n)` — a record is not a state |
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

⚠️ **The account's CONCURRENCY cap is a shared FLEET resource — the ceiling on parallelism is
neither CPU, RAM nor disk.** Every limit in the table above bounds *this box*: load, lanes, swap,
memory. None of them bounds the account. GitHub's **secondary** limit is a **concurrency** limit
(documented at no more than 100 requests in flight, **shared across REST and GraphQL**), and
`GET /rate_limit` **cannot see it** — it reports the primary budget only, and a refusal may carry
no `retry-after` at all. So a healthy `graphql.remaining` next to a refused call is the documented
blind spot, not a contradiction, and **it is not evidence that the fleet is healthy**. Measured
2026-10-17: five boxes' controllers plus hand-dispatched workers, each issuing `gh` calls with
nothing coordinating them, refused on every GraphQL call while the counter read `used: 541` of
5000 (agent-infra#1910, superseding the point-budget framing of agent-infra#1762).

The defence is a **fleet-wide courtesy gate in the `gh` shim** (`scripts/gh-shim/gh`), which is why
it is not a harness variable: it applies to every `gh` call a pi session makes, not only to the
controller's. It bounds concurrent `gh` processes per machine, spaces call starts, and on a
rate-limit refusal writes a **shared cooldown** so the next call waits instead of walking into the
same burst — one refusal-and-wait per burst rather than one per lane.

| Var (shim env) | Default | Why |
|---|---|---|
| `AGENT_GH_GATE_MAX_INFLIGHT` | `2` | concurrent `gh` processes **per machine**. The account ceiling is 100 *shared across all machines*, so a per-machine cap must be well under it — 2 leaves room for ~50 boxes. Raising it multiplies across the fleet, not just here |
| `AGENT_GH_GATE_INTERVAL_MS` | `250` | minimum ms between call **starts**. Adds latency by design: that spacing alone is ~12 s over 50 calls, and the gate's own bookkeeping adds ~0.5–0.9 s per call on bash 3.2 (no `EPOCHREALTIME`, so `perl` supplies the ms clock), so budget **~55–60 s** for a 50-call sweep, not ~12 s. `0` trades the burst protection for throughput |
| `AGENT_GH_GATE_MAX_ATTEMPTS` | `3` | total attempts on a rate-limit refusal, including the first. ⛔ **per WHOLE COMMAND, and it MULTIPLIES with gh-limit's 4:** one call can execute the same argv up to 12 times, including non-idempotent creates and comments. "The tighter layer wins" holds for concurrency and for a single wait, and is **false** for attempts — a caller that declared its own bound must suppress the sleep (`AGENT_GH_GATE_NO_WAIT=1`, or gh-limit's `GH_LIMIT_NO_WAIT=1`) |
| `AGENT_GH_GATE_RETRY_BASE` | `60` | seconds to wait when a refusal carries **no** `retry-after` (GitHub's own guidance is "at least one minute"). Floor 1 s: an immediate identical retry cannot succeed by construction |
| `AGENT_GH_GATE_RETRY_MAX` | `900` | ceiling on any single wait, including a server-supplied `retry-after` (a value too large for the shell to hold is treated as **absent**, not clamped — a wrapped value would be written into the shared cooldown and park the box) |
| `AGENT_GH_GATE_ACQUIRE_TIMEOUT` | `300` | seconds to wait for a free slot before running the call **UNGATED** (announced). This is the knob that decides the fail-open behaviour: the gate is a courtesy, so its own failure must not become a fleet stall |
| `AGENT_GH_GATE_LOCK_TIMEOUT_MS` | `2000` | ms to wait for the gate's own mutex. Keep it above `MAX_INFLIGHT × INTERVAL_MS`: nested and ungated calls can exceed the slot cap, and a timed-out tick is skipped (announced, fail-open) |
| `AGENT_GH_GATE_DIR` | `~/.pi/agent/gh-gate` | the per-machine gate state (`slots/`, `cooldown.*`). One *user's* count — two users on one box do not share it |

⛔ **`MAX_LANES` is not the lever for this.** Adding lanes adds `gh` callers, and a lane that
blocks on the gate is a lane that is not producing. The only true capacity increase is a separate
rate-limit pool — GitHub App **installation** tokens have their own budget (5,000/h per
installation) — and that is a decision, not a tuning change.

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
1b. **One owner per PR, per box — and, for LANDING, one owner per PR ACROSS boxes.** Every path
   into `merge-one.sh` (the lane's `chain-<N>`, a `fix-<PR>`, and the controller's sweep) takes the
   same atomic `state/mergeclaim-<PR>.lock` first, then `refs/claims/pr-<PR>` (**before** the paid
   reviewer) and `refs/claims/<PR>-<head-sha12>` (§7.2b).
   Without the local lock a freshly opened PR gets two concurrent reviewers racing one head: duplicate
   evidence
   comments, duplicate `record-review` writes, and an `ISSUES`/`CLEAN` interleaving.
   **The lock is a local file, so it serialises one box only** — two boxes sharing a repo are not
   coordinated by it (§7.2b, tortoise#5052). The per-head claim coordinates them per HEAD; the
   per-PR claim coordinates them per PR, which is the only key that can express "one lander".
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
[dispatch] 223 candidates -> 0 queued, 0 peer-owned (claim), 0 already landed, 6 unjudged (pre-flight), 0 blacklisted (checked), 0 already dispatched, 0 peer-held (ledger skip), 217 not reached (limit) -> 0 dispatched (backlog=0, queue=READ(223)(9m))
```

The age is part of the token on purpose: a value frozen by a refresh that stopped writing cannot pass
as a fresh reading. `UNKNOWN` means no pass has EVER recorded a read — it is not `EMPTY`.

⛔ **A FILTERED-TO-ZERO FUNNEL IS NOT A CLEARANCE EITHER** (agent-infra#2040). The line above used
to read `[dispatch] backlog empty queue=READ(223)` — the pool was read (223 candidates) and the
backlog was empty, and nothing said which step ate the 223. That contradiction idled all three cloud
cells for hours. The dispatch line is now a DECOMPOSITION, and its parts reconcile with the pool
(`listed = queued + peer-owned + landed + unjudged + blacklisted + already-dispatched + peer-held(skipped) + not-reached`):

```text
[dispatch] 223 candidates -> 0 queued, 0 peer-owned (claim), 0 already landed, 6 unjudged (pre-flight), 0 blacklisted (checked), 0 already dispatched, 0 peer-held (ledger skip), 217 not reached (limit) -> 0 dispatched (backlog=0, queue=READ(223)(9m))
[dispatch] 223 candidates -> 0 queued, … , 154 not reached (limit) -> 2 dispatched | held: … ← `held:` names the gate when one blocks
[dispatch] DRAIN STALLED — no PR merged in 359m while 52 un-owned remain. The issue path stays CLOSED
           (un-owned PRs first): this is a land/capacity problem to fix, not a reason to open new work.
```

⛔ **`peer-held (ledger skip)` IS NOT `not reached (limit)`** (review finding P2-1). A candidate a recent
pass recorded as held by a peer is walked past at no network cost, and it used to be counted NOWHERE — so
it inflated the DERIVED `not_reached` part, the one an operator reads as "raise `LIMIT`", printed beside a
`limit=` at its real value. On a four-box fleet with a fresh collision ledger that is the ordinary case,
not an edge case. A record written before the key existed simply omits the part (no invented zero).

`unjudged` is the one to read first: it means the pre-flight could not JUDGE, which is not "no work".
`UNRECORDED` (no `state/refresh-funnel` yet) is never rendered as an empty funnel.

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
launchd jobs (`templates/launchd/com.tortoise.worktree-reaper.plist`,
`com.eldato.pi-session-reaper.plist`), i.e. **absent on a Linux cell** (agent-infra#1864, #1927).
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
(`_refuse_if_degraded`); the retired `retired/queue-dispatch.py` raised `LaneReadError` naming the
timeout instead of returning `[]` (a record of the polarity, not a live reader — agent-infra#1874);
`pr-doctor.py` refuses the pass **when it has work to place** — and deliberately
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
read is a CALLER's — `pr-doctor.py`'s `LANE_BUDGET_S + margin` on the fallback scan. (The reader does
hold per-CALL bounds — 60 s, 45 s, 45 s — and that is exactly the shape this MUST rules out: it bounds
each probe and lets their SUM grow with the fleet.) The retired `retired/queue-dispatch.py` was the
other bound — 600 s on its direct `lane-status.py` call — and it printed the residual: *"lane-status.py
has no internal deadline, so this is the only stop between a stalled scan and an unbounded wait"*.
That caller is gone (agent-infra#1874), so the sole remaining caller bound is `pr-doctor.py`'s.

⛔ AND THE PASS MUST SAY WHAT IT DID. A dispatcher that refuses is a failure the fleet can see: every
exit of `pr-doctor.py` writes `$STATE/pr-doctor.status.json` (`rc`, a one-line reason, the PRs that
went out) and prints `dispatched N of M queued — <why>`, so `dispatched 0` is never healthy while the
queue has runnable items; `objective.py` renders the last pass's verdict as `PR-DOCTOR(last run):
RED rc=N Nm ago — <reason>` beside the queue's own shape, and `heartbeat-loop.sh` prints the same
verdict and launchd's last exit. The `issue_work` field is **PUBLISHED AND UNREAD**: the retired
`retired/queue-dispatch.py` was its only consumer — it SKIPPED new issue work while un-owned PRs
existed, refusing only on a positive, FRESH reading (a missing, stale, unreadable or refused record
blocked nothing and said so).
⛔ DO NOT READ THIS AS A LIVE GATE (agent-infra#1874 retired the dispatcher): nothing consults
`issue_work` today. The owner's PR-first selection now lives in
`scripts/orchestrator-harness/live-ownership.sh` — the shell half of the same rule, landed in
agent-infra#2129 and called from `orch-loop.sh` by that same commit (NOT by #1894, which wired the
`pr-doctor` SPAWN path and never touches this module) — and that module does not read `issue_work`
either, which is what makes the field PUBLISHED AND UNREAD rather than merely re-homed. The orphan is
disclosed in `scripts/heartbeat-loop.sh` and in the retirement note at the foot of this file.

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
mean. `orphan-reap.py` walks to the top (`ancestry()`; the rule in its header under *THE THREE
REQUIRED GATES*) **and** adds the gates `ppid 1` cannot express: launchd registration (gate 4 — a
managed daemon has an owner), designed-daemon (gate 5 — pidfile, daemon flag, recently-touched
output, or any live holder of a socket it owns) and diagnostic value (gate 6 — a candidate naming a
work item, holding a lane transcript or holding a recent write is REPORTED, never killed). Gate 5
was added AFTER a dry run passed gates 1-4 on three processes and all three were wrong to reap
(gate 4 came earlier, after the reaper killed the owner's own UI). It ships **dry-run** (default
invocation; `--apply` is the explicit flag) and nothing schedules it today (§6.5.1).

⛔ **The ancestry gate is now REACHABLE, and that was #1244's finding.** The reaper used to require
`ppid == 1` as a candidacy precondition, which made this gate INERT BY CONSTRUCTION: if a
candidate's parent is launchd its chain is `[candidate, launchd]`, so no hop is left in which a
human terminal could appear — a gate whose population excludes the case it exists for, exactly the
class #1244 named ("#1207 gates the reaper, which could never have seen them"). Candidacy is now
argv-shaped at any depth (`ppid 1` is reported, never used as evidence) and `ancestry()` is the
gate. The reach is stated rather than assumed: the walk terminates at the first recognised host app
or interactive shell (a login shell, or any shell owning a TTY under the caller's uid), and a walk
that cannot reach the top is **INCONCLUSIVE ⇒ REPORT**, never a clean walk.

The other two gate families are in the module, not in prose, because both had already failed that
way: gate 1's window and tolerance are the stated constants `WINDOW_S` / `TOLERANCE_S` (printed in
every report and pinned by `scripts/orphan_reap.test.py`, whose `--mutations` mode disables each
gate and requires its paired test to go RED), and gate 3 is a DATA table of per-class expected
distributions (`PROC_CLASSES`, each row carrying the measurement it came from) so a class with no
measured distribution is INCONCLUSIVE rather than reaped on a guess. Every decision is logged to
`$ORPHAN_REAP_STATE_DIR/orphan-reap-decisions.jsonl` with pid, class, age, cpu delta, window,
tolerance, ancestry path and verdict, every gate outcome and the reason; exit codes are `0` pass
complete / `2` usage / `3` fail-closed (a read the pass needed was unavailable ⇒ nothing signalled).
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

- **A candidate with diagnostic value stays.** Evidence beats tidiness — `orphan-reap.py`'s gate 6
  ("Reapable != right to reap", and its header clause of the same name), and
  `pi-reap-worktrees.sh`'s PRESERVE verdicts.
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
`orphan-reap.py`'s six gates and `pi-reap-worktrees.sh`'s PRESERVE verdicts are real checks;
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

**Implementation: `cloud-cell-doctor.sh`**, launched as tmux session `cell-doctor` (the
`$DOCTOR_SESSION` default — a fixed name, not derived from `$SESSION`) by
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
| `status` | — | the liveness table; the stale bounds account for every role that runs BETWEEN two passes of the same role (the roles run in sequence in one loop), so a busy-but-healthy cell is not reported STALE; **exit 1** when a started cell has a role that never ran, went stale, or whose LAST pass failed (`rc≠0` — a failed controller restart, a cannot-verify read), or whose record carries **no readable `rc`** at all (`FAILED  the record holds no readable rc` — a truncated or hand-edited state file; an unreadable verdict is cannot-verify, never a clean pass). One clean pass clears it, so a transient failure reads as one failing pass, not as a dead cell. A loop younger than `DOCTOR_GRACE_S` (300 s) — or a role whose FIRST pass is still running (`state/roles/.<role>.running`, what `run_role_pass` writes, bounded by `ALL_PASSES_S` so a killed loop's leftover cannot hide a dead role for ever) — prints `WAITING` instead — its first doctor pass samples every lane, so `start && status` must not call a healthy cell dead; a cell with no loop-age record is judged immediately (fail-closed) |

**The reap decision is the safety core**, and it is the §6.5.1 rules applied to the fleet
namespace: a session is a candidate only if its log has not grown for `REAP_MIN_S` (**2700 s**, above
the controller's own `STALE_MIN=40` and the harness stall bound); the decision then takes **two
observations** `REAP_SAMPLE_S` apart; and the lane's **subtree must show no CPU delta**, because a
long model call is not a wedge. The whole read has an **overall** budget (`REAP_TIMEOUT`, 300 s) —
a per-call bound would let the total grow with the fleet — and each `tmux`/`ps`/`gh` call is
separately bounded (`READ_CALL_TIMEOUT` for tmux/ps, `MERGE_READ_TIMEOUT` for the queue listing;
without `timeout(1)` the bound is enforced by the shell itself, so its absence cannot silently
re-open an unbounded read, and a configured bound of `0` is REFUSED at startup because `timeout 0`
runs the command with *no* timeout at all — a bound that silently removes itself under the name of a
bound). A pass that spends the budget STOPS at the lane it reached and
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

### 6.5.8 The box re-pins ITSELF once per cycle, and names a stale checkout on every spawn line

**MUST.** A cell must not run code simply because nobody pulled. Once per cycle `orch-loop.sh`
calls **`harness-refresh.sh`**, which fetches the ref, compares this box's **pin** with its tip by
**hash equality / `merge-base --is-ancestor`** (never a commit count), and either advances the pin or
**refuses loudly** and names which relation blocked it: `dirty`, `ahead`, `diverged`, `unknown`.

**Why (measured 2026-10-20).** Three cells sat on a checkout **27 commits behind `origin/main` with
an EMPTY `HARNESS-PIN`**, so fixes that had landed hours earlier were running nowhere. Nothing
fetched, nothing compared, and an empty pin was indistinguishable from a current one because no
reader ever refused it. Separately, a live-tested patch existed only as a working-tree edit and was
lost to the next pull — which is why `dirty` REFUSES rather than adopting over it.

**The relations, and what a caller may assume.** `current` (pin == tip) · `restart-pending` (pin ==
tip, the running controller still executes the previous commit — NOT a failure and NOT a reason to
re-deploy) · `behind` (+`repinned` when this box has a materialiser) · `dirty`/`ahead`/`diverged`/
`unknown` (all refusals; nothing is touched). Exit: `0` current, `10` repinned, `11` pin mended
(empty/absent/not-a-commit pin repaired from what the box actually runs), `20` dirty, `21` ahead,
`22` diverged, `23` unknown/un-adoptable, `25` behind with no materialiser. One machine line first —
`harness relation=… running=… ref=… pin=… action=… fetch=…` — then prose; the controller parses the
record, never the wording. `fetch` is the **freshness of the comparison itself** (`ok`, `stale` — the
fetch failed or timed out, `local` — the ref is not an `origin/*` ref, `notfetched` — `--no-fetch`), and
a `current` against a comparison that is not `ok` is **cannot-verify**: the controller turns it into the
token `stale:<sha12>` rather than going silent, and `status` says so beside the relation. A fetch that
cannot complete is not a comparison, and the box must not read as current because the network was down.

**It does not fast-forward the tree it is running from, and it is not a second seeder.** The advance
is delegated to the box's own materialiser (`cloud-cell-supervisor.sh apply --force --pin-only`),
which creates the per-commit pin worktree and leaves the tree being executed alone. `--pin-only`
skips `seed_and_stamp` **on purpose**: seeding `$O` under a live controller would swap the helpers
(`lane.sh`, `claims.sh`, …) a loop calls while the loop itself is still the old `orch-loop.sh` — a
version skew no other path produces. The next `start` re-seeds `$O` from the new pin, so the box
moves as one piece and the window in between is reported as `restart-pending`.

**A lane is never spawned from a behind checkout without that fact on the spawn line.**
`HARNESS_TOKEN` is empty only for `current`; otherwise it is `<relation>:<sha12>` and it is appended to
**every** dispatch row (`disp`) and to the `lane-`/`chain-` spawn line in `dispatch-merge.sh`
(`[harness=…]`). An absent token reads `unknown`, never `current`. Refusals go to `$LOG` **and** to
stderr, once per cycle — a warning that prints on every tool call is how #1140's noise hid a signal.
`HARNESS_REFRESH=off` disables the re-pin and says, once per cycle, that a stale checkout will now go
unnamed (a pinned-build escape hatch, not a way to avoid a red line).

**Status: IMPLEMENTED.** Residual, named: a re-pin changes what the box will run, not what it is
running — `$O` and the controller both move at the next `start` (which re-seeds `$O` from the pin),
and until then every spawn line says `restart-pending`. The controller does not restart *itself*
onto the new pin, deliberately: a self-restart mid-cycle is a liveness risk this PR does not take.

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
reviewer and `FIX_TIMEOUT + 1200` for the fixer, and carried in the claim commit.

**A claim can also be DEAD while its term is not (#2094).** Renaming a machine used to orphan every
lease it held: `claim_owner()` stamped `$(hostname -s):$$`, liveness was "`lease_until` is in the
future", and `claim_prune` reaped by expiry alone — so the old host name never matched again and a
future-stamped lease was immune for its whole term (measured: 14 leases, **14 held by dead pids, 0
alive**; the dispatcher printed `held by …` for each and then `backlog empty queue=READ(192)`).
`claims.sh` now answers a second question — `claim_orphan_reason(owner[, ref])` — and `claim_acquire`,
`claim_issue_preflight`, `claim_prune` and `orch-loop.sh`'s `claim_live()` all consult it:

| rule | when it fires | why it cannot steal a live peer |
|---|---|---|
| **own former names** | the owner host is a name THIS box has carried (`state/claim-hosts`) | the list only ever holds names this box answered to (written from the real `hostname -s`, never from a seam), and it requires the `hostname` probe to answer — a blind probe abstains. Nothing ships a roster, so this is what makes a rename self-heal. ⚠️ **Read the residual in the next paragraph: this rule runs for EVERY keying, so it can free an in-flight ISSUE claim.** |
| **local pid** | the owner host IS this host, **one of its former names**, or **the machine's own probed `hostname -s`** (which stays local even when a `CLAIM_OWNER_HOST` seam is set — otherwise a seam-presenting box cannot judge a claim it stamped with its real name) — and `ps -p <pid>` says the pid is gone | **PR claims ONLY.** A PR claim is minted by the worker (`merge-one`/`fix-one`), so its pid IS the worker. An ISSUE claim is minted by the CONTROLLER and released by the CHAIN, so a controller restart (every deploy) would have this delete a live lane’s barrier and re-open the duplicate — the rule is keyed, not global. A LIVE local pid therefore OUTRANKS the host name — that ordering is the P0 fixed in `720e780d`, where the former-name rule reaped a renamed box’s own live merge/fix claim. It also needs a control probe (`ps -p $$`) to prove `ps` can answer at all; an instrument failure abstains, never steals. ⛔ AND IT REQUIRES `hostname -s` TO BE **UNIQUE ACROSS THE FLEET**: the premise above is that the owner's host naming this box proves the pid is local, and nothing asserts that premise. Two boxes sharing a short name (cells provisioned from one image) each mint `<sameName>:<pid>`, and each then probes the OTHER's live worker pid locally, reads an absence and returns ORPHANED — `claim_prune` deletes it and the pre-flight reports CLEAN, the steal direction this column says cannot happen. The `state/claim-hosts` remedy below does NOT cover it (no history line is involved, and the shared name is the box's CURRENT name), so set a unique hostname before a cloned cell image mints its first claim |
| **`CLAIM_DEAD_HOSTS`** | the owner host is listed | an explicit deny list — a mis-entry over-reaps only the host it names |
| **`CLAIM_KNOWN_HOSTS`** | the roster is SET, **names this box**, and does not list the owner host | a roster that does not name this box is stale (its usual cause is the very rename) and **abstains**; an unset roster never means "every peer is dead" |

⛔ **THE SELF-HEAL ASSUMES A FREED NAME IS NEVER REASSIGNED.** `state/claim-hosts` is a list of names
THIS MACHINE owns, so a name handed to another box afterwards makes every claim that box mints read as
this box's own dead claim — for every keying — and the local-pid rule then probes the foreign pid HERE,
reads a local absence, and calls a LIVE remote worker's PR claim orphaned: the steal direction, from a
name that is no longer ours. The self-limiting claim holds only while the name is exclusive to this
box. Remedy: once no outstanding claim can still carry the name (after `CLAIM_TTL_MAX` / `CLAIM_ISSUE_TTL`),
delete the line from `state/claim-hosts` before the name is reused elsewhere.

⚠️ **The roster is an allow list, so an INCOMPLETE one over-reaps**: a roster that names this box and merely omits a live peer declares that peer dead and re-dispatches its unexpired work across two boxes — the failure this registry exists to prevent, reached from the opposite direction. It must be COMPLETE and authoritative, which is why the deny list (`CLAIM_DEAD_HOSTS`) is the safer knob for a one-off dead host and is checked first.

⚠️ **`CLAIM_OWNER_HOST` (the test/simulation seam) is honest about its cost, once per process.** It
stamps claims with a name the **HOST** rules cannot judge, so an ISSUE claim minted here cannot be
reclaimed by this box (a PR claim still can, via its pid — the local-pid rule judges the seam name fine,
because it probes the process rather than trusting the name) — and it
**suppresses `state/claim-hosts` recording**, which silently disables the rename self-heal. It is still
supported (the harnesses and cross-box simulations need it), but it warns on stderr when it differs
from the running host. Nothing in a deployed cell sets it.

⚠️ **The self-heal covers renames AFTER this ships, not the leases a rename already stranded.** A
name can only be recognised as *former* if the box recorded it while that name was still current, and
the recorder did not exist before this change — so the leases the incident measured (including the
literal `9768s left` line above) need a ONE-TIME cleanup, after which the mechanism holds. Stated
because "self-healing" reads as "retroactive".

⚠️ **Use the pid-preserving remedy, not `CLAIM_DEAD_HOSTS`.** Append the old name to
`state/claim-hosts` (“this box wore it”) — the former-name rule then probes the pid, so a
`<oldName>:<live pid>` PR claim reads held-by-live and a dead one is reclaimed. `CLAIM_DEAD_HOSTS=<old-name>`
instead declares the name dead *outright*, and the deny list is checked on the host rules only — it
never consults a pid. What it reaps is therefore: an **ISSUE** claim from that name (whose chain may
be running — see the residual above), and a **PR** claim whose host was never recorded in
`state/claim-hosts`. On a PR claim minted by this box the pid rule answers FIRST — the name is in the
history, so the pid is probed and a live worker returns `held-by-live` (rc=1) before the deny list is
reached (measured at head). So the deny list is safe for PR claims this box minted, and is NOT safe
for the ISSUE claims of a lane that is still in flight: apply it only when no lane is mid-merge.

⛔ **THE PID REMEDY IS THE SAFER ONE FOR *PR* KEYS ONLY — IT DOES NOT PRESERVE AN ISSUE CLAIM EITHER**
(cycle-11 review: an earlier version of this paragraph offered it as the way to *avoid* the hazard just
described, which sent the operator straight into it). For an **ISSUE** key the local-pid arm is
skipped entirely — an issue claim is minted by the controller, not by the lane — so the former-name
**host rule** is reached and fires, and a live lane's barrier is freed exactly as the deny list frees
it (pinned by O10(e), which measures an ISSUE claim stamped `<former name>:<live pid>` → ORPHANED and
the same owner on a PR ref → held-by-live, in one pair; O10(b) pins the end-to-end reclaim). The difference is
strictly that a **PR** claim stamped `<oldName>:<live pid>` returns `held-by-live` under the pid remedy
and is reaped under the deny list. **Neither remedy preserves an in-flight ISSUE claim**, so the only
mitigation for those is the condition both share: do not rename — or run the one-time cleanup — while
lanes are in flight; otherwise let the next prune free their issue claims and let them finish.

⚠️ **THE HOST RULES RUN FOR EVERY KEYING, AND THAT HAS A CONSEQUENCE WORTH STATING PLAINLY.** They
answer "is the holder a live LANE?", and a name that no box answers to is dead *as an identity* — but
the holder and the work are different processes for an ISSUE claim (the controller mints it, the lane's
chain works and releases it). So after a rename, the first hourly `claim_prune` on the renamed box
**frees its own in-flight ISSUE claims while their chains keep running**, and a peer may then dispatch
the same issue. That is accepted rather than fixed: a barrier held by a name nobody answers to is
indistinguishable from an abandoned one for every peer, so the alternative is a claim nothing can ever
reclaim (the incident). The guarantee is therefore **"the claim is safe until the next prune"**, not
"until the lease expires" — and `dispatched.txt` protects only the box that wrote it. If you rename a
box with lanes in flight, expect the next prune to free their issue claims and let them finish; the PR
keying (where the minting pid IS the worker) is unaffected.

An orphaned holder is reclaimable **regardless of `lease_until`**, the pre-flight reports it CLEAN
(the CAS still has to be won), and `claim_prune` reaps it. An **unparseable** lease keeps its
existing polarity — LIVE — and is never re-examined for orphanhood: those rules are a reason to stop
trusting a *term*, not evidence about a *holder*. Every `held by …` hold reason and every pre-flight
COLLISION carries a machine-readable token, `held-by-live` or `held-by-orphan` (the lost-CAS refusal
`lost the reclaim race for <ref>` carries neither — it reports a race, not a hold), and
`refresh-candidates.sh` reports how many candidates a live
claim withheld and how many were queued *although a claim existed* (its only claim is orphaned), so a
claim-driven empty backlog can no longer read as "no work".

**The lease has a CEILING as well as a default.** `CLAIM_TTL` (1800s) and `CLAIM_ISSUE_TTL`
(10800s) are *defaults* for their keying; `CLAIM_TTL_MAX` (7200s) and `CLAIM_ISSUE_TTL` bound what a
caller may stamp. Above the ceiling a ttl is **clamped to the ceiling** (never to the shorter
default — that would expire merge-one's deliberate 3000s mid-merge) and the clamp **says so on
stderr**, because `CLAIM_LEASE = REVIEW_TIMEOUT + 1200` and `FIX_LEASE = FIX_TIMEOUT + 1200`: raising
either timeout past `CLAIM_TTL_MAX - 1200` requires raising `CLAIM_TTL_MAX` in the same change, or
the claim expires before the review it was taken for. The verification is `claim-orphan.test.sh`,
which reads the stamped term back out of the **pushed claim commit**. Both tunables are
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

#### The landing key `refs/claims/pr-<N>` — the per-head key cannot answer "is one box landing this PR?" (agent-infra#1952)

The registry above is **content-addressed on the head sha**, so `refs/claims/<PR>-<head-sha12>` says
*"another box is working THIS HEAD"*. That is the right question for a **review** — a pushed update is
legitimately new work, and a duplicate review costs one duplicate comment. It is the wrong question
for **landing a merge**, which is the one operation #1908's per-operation table records as *not*
tolerating at-least-once: `gh pr merge` is **not pinned to a sha**, so the second lander merges
whatever head is current at the moment it runs, against a signed marker bound to the head *it*
reviewed. Two boxes that see one PR at two different heads mint **two distinct keys** and each wins
its own CAS; that was measured — do not take it from this paragraph (row **M3** of
`claim-exclusion.test.sh`, recorded in the per-operation table).

So landing takes a **second, coarser ref, `refs/claims/pr-<N>`**, *in addition to* the head key — the
head key is **not** re-keyed, because that would reverse rec 1 (`claims.sh`'s "KEY =
<PR>-<head-sha12>, NOT <PR>") and make a pushed update wait behind a stale claim for its predecessor
head. `merge-one.sh` takes `pr-<N>` **first** and `<N>-<sha12>` **second**, at every ingress (the
lane's `chain-<N>`, a `fix-<PR>`, and the sweep), so the two refs have one total order and cannot be
taken in opposite orders by two boxes. The landing claim is taken **before the paid reviewer runs**,
so the losing box pays nothing, and it is released by the `EXIT` trap after the merge — both releases
bounded (~20 s each), head first and the PR-wide ref second, so the coarser ref — the one every box
must see free — is the last to be dropped. A refusal (`rc=1`) exits **before** the review; an
**unreachable** registry (`rc=2`) fails **open** and logs it, the same policy the head claim uses
(§7.2b above), and a box whose `$O/claims.sh` predates `claim_pr_acquire` is a **named** log state,
not a silent degradation.

⛔ **What is measured, and what is not.** `test-gates.sh` §"THE LANDING CLAIM" pins the mechanism
hermetically against a throwaway bare origin: the second box is **refused the same PR** (L1), the
three keys stay independent and the head key stays per-head (L2), a non-holder's fenced release is
refused (L3), a release genuinely frees the PR (L4), the row is non-vacuous — a forced create push
makes both boxes win, so L1 can go red (L5) — and `merge-one.sh` acquires before the reviewer,
widens its trap **before** the acquire, and releases on every exit (L6–L8); L9 pins that a failed
head acquire cannot carry the landing commit into the head release. `claim-exclusion.test.sh` **M6**
is the concurrency measurement of the same key, and its row is recorded in §7.2d. What is **not**
measured is the merge itself: `gh pr merge` on a moved
head needs GitHub, so the residual — a head that moves inside the marker-check→merge window — is
closed only to the extent that a second **lander** is excluded; a push that races an in-flight merge
from elsewhere is still possible and is why the marker is re-read at the live head.

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
  every exit path** (clean merge, failed merge, the 90-minute "no PR appeared" timeout, and — see
  §7.2d — a capacity refusal, where it exits at once rather than waiting) through
  a trap, fenced on the commit this box pushed; a box that dies mid-lane leaves it to the lease,
  which is sized (`CLAIM_ISSUE_TTL`, default 3 h) to cover lane + chain — releasing early is the
  normal path, so the lease only runs its full length when the box is gone.
- **The pre-flight now CONSULTS it, and fails CLOSED.** `refresh-candidates.sh` calls
  `claim_issue_preflight` after a clean tool verdict and branches on its **exit code**, never on
  output text: **0 CLEAN** (no claim, the only claim expired, **or the only claim is ORPHANED** —
  #2094: its holder cannot be a live lane, so the pre-flight reports what the acquire will do and the
  acquire still has to win the CAS) queues the issue; **1 COLLISION**
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

The registry now carries **three** keys, one question each, and none is a re-keying of another:
`<PR>-<sha12>` ("this head", review/evidence), `issue-<N>` ("this issue", dispatch), and
`pr-<N>` ("this PR", **landing** — §7.2b). They cannot collide: the `issue-` and `pr-` prefixes
put them in their own families, and `<N>-<sha12>` always carries a dash, so a PR number alone never
addresses a head.

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
`CLAIM_OWNER_HOST`, so the CAS is genuinely raced rather than replayed sequentially. (It was
`CLAIM_OWNER_ID`; #2094 renamed the seam to the HOST so the owner's `<pid>` stays the racing
process's own, and `claim_owner` now REJECTS a `CLAIM_OWNER_ID` whose host is not the running host —
a claim stamped under a host that no longer exists is unreclaimable for its whole lease.) Each racer waits
`n × 3 ms` after the barrier: released in the same microsecond, every push contends for the same
`<ref>.lock` and the losers are refused by **git's ref lock** before they ever reach the CAS —
measured by forcing the create push and still getting exactly one winner, which would have let a
defeated CAS report EXCLUDES. Two boxes are never that synchronised, so the stagger measures the case
the CAS has to handle. **Non-vacuity, measured:** with the stagger in place, pointing `CLAIMS_SH` at
a copy of `claims.sh` whose create push is forced (`push -q --force`) reddens **M2** with
`2 winners in one lap`, while the shipped `claims.sh` passes the whole suite (20/20) — so the suite
discriminates a
defeated CAS from an exclusive one. The same mutation applied to the **landing** key —
`claim_pr_acquire` replaced by a fail-open `return 0` — reddens **M6** three ways (six winners in a
lap, the second holder at another head *acquiring*, and the refusal naming no holder), so the per-PR
row cannot pass on a registry that excludes nothing. **Limit, stated:** the default origin is a bare
repo in the sandbox, so this measures ref-update atomicity, not the network. `--origin live` closes
that gap on demand (it leaves no claim ref and no probe branch behind — the trap deletes both).

| operation | claim key | duplicate behaviour MEASURED | tolerates at-least-once? |
|---|---|---|---|
| **dispatch** (start a fixer/reviewer) | `refs/claims/issue-<N>` | 3/3 laps × 6 racers: **exactly one** winner per lap; every loser gets rc=1 and is told *who* holds it (`held by box2:1529071 until …`) | **yes** — side effects are idempotent |
| **review / record evidence** | `refs/claims/<PR>-<sha12>` | 3/3 laps × 6 racers: **exactly one** winner; loser refused | **yes** — the cost of a duplicate is a duplicate comment |
| **landing: the same head** (per-head key) | `refs/claims/<PR>-<sha12>` | the same CAS as review; the second worker exits **before** it reviews or merges (`merge-one.sh`, `CROSS_RC=1`) | **only for that head** |
| **landing: the PR moved to a new head** (per-head key) | `<PR>-<sha12>` — **a different key** | **both acquire.** Measured (M3): an issue/PR claim is content-addressed on the HEAD, so two heads of ONE PR are two distinct CASes and the per-head claim cannot express *"this PR"* | **NO** — which is why landing ALSO takes the key below |
| **landing: one PR at ANY head** (the **LANDING key**, agent-infra#1952) | `refs/claims/pr-<N>` (`claim_pr_acquire`) | **M6: exactly one winner per PR** (3/3 laps × 6 racers), and a sequential second holder at a **different head** of the same PR is **refused** (rc=1, names the holder) — the exact case M3 measures as *allowed* on the per-head key | **NO** — so it must EXCLUDE, and per PR it now does |
| **fencing** (release / stale write) | the ref's **value** | a loser's release is refused (rc=1, ref unchanged); a **fast-forwardable** push leased on a stale base is refused — by the lease, not by non-fast-forward | n/a — a fence, not a claim |

**So, per operation:**

- **Dispatch and review are retired from the `SCOPE=own` question.** The measurement shows the claim
excludes, on both keys, under real concurrency — and `SCOPE=own` was **never** what excluded them:
it selects which *PR branches* this box's **sweep** looks at (`*-tm`, `*-cap`, `fix/*`), by a naming
convention every box shares, so two `own`-pinned boxes select the same PRs. The code has said so
since the pin was added (§5 item 3, "a partition, not coordination"); the measurement now says the
claim covers those two classes without it.
- **Landing was NOT retired on the per-head key — and the decision that row pointed at has since
been TAKEN, in the direction of adding the exclusion.** The per-head rows are unchanged and still
measured: two boxes at two heads of one PR hold **two live claims**, so that key cannot be the landing
fence, and `SCOPE=own` does not cover it either (it is a selection filter, and the PR is in both
boxes' selection). agent-infra#1952 answered *landing: the PR moved to a new head* by adding a
**per-PR** key rather than exempting the row: landing also takes `refs/claims/pr-<N>` (§7.2b), and
**M6 measures that key** — one winner per PR across racers, and a second holder at a different head
**refused**. So the landing *claim* now has an observed exclusion, and the two per-head rows stay in
this table as the reason the second key exists (M3 stays green *because* the review key was
 deliberately not re-keyed). What M6 still does not measure is the merge itself: `gh pr merge` is not
pinned to a sha, so the marker-read→merge window is covered only to the extent that a second
**lander** is excluded (§7.2b, "What is measured, and what is not").
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
`orch-loop.sh` prints it as `queue=$(queue_state_token)` in the per-cycle heartbeat line and at the
end of the `[dispatch]` funnel line, with the age of the reading (a frozen value cannot pass as a
fresh one).
An absent or unparseable record prints `UNKNOWN`, never `EMPTY`. The refusal polarity is unchanged
and still fail-closed: a failed read exits TRANSIENT, never a green "nothing to do".

⚠️ **Deliberately NOT fixed here** — this is the *reporting contract*, not the transport, and not the
provisioning verdict: the fleet's shared gh backoff for GitHub's secondary (concurrency) limit is
agent-infra#1910, and a refresh whose resolved tool directory is behind `origin/main` still says so
only through its own existing refusals (issue #1931's directions 1 and 3, which this change does not
touch). A pass that cannot read the pool now says `queue=UNREADABLE` while it refuses.

### 7.2d A capacity refusal consumed the item's turn — FIXED in agent-infra#1909

**The defect.** R1 (a box dispatches only when it has capacity) worked exactly as designed on
2026-10-17 and that is why the queue stalled: the Mac refused at load 98→180 while cell-2 sat at
0.29 load with 14.5 GB free and cell-3 at 0.04. Nothing turned a refusal into "another box may take
this", because the refusal's consequences were invisible and **long-lived**:

1. `lane.sh`'s gate refused, so no agent ran and no PR could ever appear.
2. `chain-merge.sh` then waited its full **90 minutes** for that PR — holding `refs/claims/issue-<N>`
   the whole time, because releasing it is its EXIT trap's job.
3. Every peer's `claim_issue_preflight` reads a live claim as **COLLISION**, so ONE box's capacity
   decision made the issue ineligible on **all five** boxes for 90 minutes (up to `CLAIM_ISSUE_TTL`,
   3 h, if the chain were killed). That is the `parked-*` failure R8 forbids, arrived at by a
   different route: the item's turn was consumed by a machine that did no work.
4. Nothing stopped the refusing box from re-winning the claim next cycle and being refused again —
   starving the peers it had just yielded to.

**The mechanism**, three parts and no new network traffic (it rides the claim the refusal was
already holding):

| part | where | what it does |
|---|---|---|
| the **record** | `lane.sh` writes `state/capacity-refused-<N>`, one line: `<refused_epoch>\t<yield_until>\t<load\|disk>` | the refusal becomes durable and readable. Cleared when a lane actually runs, so a stale record cannot outlive its dispatch |
| the **release** | `chain-merge.sh` reads field 1 and exits **at once** with the gate's own code (75 load / 77 disk) | the EXIT trap does the FENCED release it already did — so peers see CLEAN within one poll interval instead of after 90 minutes. Field 1 is what makes it per-dispatch: a record from an earlier run cannot end a LIVE lane's wait, which would let a peer open a second lane for the same issue — and the bound needs ORDERING SLACK, because `dispatch-merge.sh` spawns the LANE first: the record is written ~4 ms after the lane's fork while the chain reads its start ~8-15 ms after its own, so the record is normally a fraction of a second to a second OLDER than `CHAIN_START`. A bare `epoch >= CHAIN_START` therefore discards real refusals whenever a second boundary falls between the two, which is precisely when the box is loaded enough to refuse. `CAPACITY_REFUSAL_GRACE_SECS` (default 60) supplies the slack, capped by the record's OWN yield window (`until - epoch`), so it still cannot admit a record older than the stand-down it declares. ⛔ **the cap is STRICTLY shorter than that window, and that is load-bearing:** this box may not re-dispatch before `until`, so every legitimately-arriving chain has `epoch <= CHAIN_START - win`; a slack equal to `win` would then admit the single second `epoch == CHAIN_START - win` — an EARLIER dispatch's record ending a LIVE lane's wait — so the effective slack is `min(CAPACITY_REFUSAL_GRACE_SECS, win - 1)`. **Required relation: `CAPACITY_REFUSAL_GRACE_SECS < CAPACITY_YIELD_SECS`** (the shipped defaults satisfy it, 60 < 900, and the clamp holds the bound for every other pairing); re-read this line before tuning either knob |
| the **stand-down** | `orch-loop.sh`'s `capacity_yield_live()` reads field 2 and the dispatch loop `continue`s before the claim | releasing the claim makes the issue *eligible* on a peer; it does not make the peer *win* the CAS. While the yield is live this box leaves the issue **unconsumed** (no `dispatched.txt` row, no claim ref), so it stays a candidate here *and* free for every peer; when the yield expires the ordinary path resumes |

**Decisions worth not re-litigating.**

- **The signal is the gate's own refusal, not load average.** Whatever actually bound is named
  (`load` or `disk` — opposite remedies), and the transfer is driven by the refusal event. Load is a
  symptom of contention rather than a measure of capacity (`docs/ops/load-policy.md`), which is also
  why a lowering of `MAX_LOAD` (#1907) could not have moved a single item. ⚠️ NOTE what the record
  can carry: the WORKER gate binds on **load or disk** only (`spawn-gate.sh`), so those are the only
  two values field 3 can ever hold; the lanes/swap/memory terms belong to the CONTROLLER's own gate,
  which refuses *before* any claim is taken and therefore writes no record at all (§1 above).
- **The yield is gate-independent, deliberately.** `load` clears when the box quietens and `disk`
  never does, but both produce the same `CAPACITY_YIELD_SECS` stand-down: the field names the remedy
  for whoever reads the record, and it must not shorten the transfer window (a disk refusal is not
  evidence that a peer is free *now*). Residual, named rather than hidden: a box whose disk is full
  re-attempts each candidate once the yield expires, because the controller's gate has no disk term
  to stop it earlier — bounded by the yield (900 s), not parked for ever.
- **The controller-level gate needs nothing.** It refuses *before* any claim is taken, so nothing is
  held and nothing consumes the item's turn; the transfer machinery exists only for the worker-level
  refusal, where an issue has already been claimed and a chain is waiting for it.
- **Every reader fails OPEN — and the two readers do NOT check the same thing.** A missing, empty,
  garbled, non-numeric or wrong-shaped record is **not** a refusal in either reader: treating one as
  a refusal would suppress dispatch, which is the fleet-wide idleness R8 removes, re-introduced by a
  corrupt byte. Past that, each consumes the fields it needs and no others:
  - `chain-merge.sh` uses **field 1** (numeric, and inside this dispatch's window: `epoch` at or after
    this chain's start minus the ordering slack, and not older than the record's own yield window).
    It reports **field 3** as the exit code (75 load / 77 disk) and maps an unrecognised value to
    `load`, because the refusal itself is already proven by field 1 and refusing to end the wait over
    one corrupt byte is the behaviour this section forbids. It never reads field 2: an incoherent
    yield window must not make a proven refusal unreadable.
  - `orch-loop.sh`'s `capacity_yield_live()` uses **fields 1 and 2 together**, and only a COHERENT pair
    (`epoch < until`, `until` in the future) is a yield; an incoherent one is not, because it would
    park the item.
- **`CAPACITY_YIELD_SECS` (default 900) is clamped to 1..86400 and `0` is REFUSED**, not honoured:
  a zero-length yield would silently restore the defect while looking configured.
- **A rejected record is now VISIBLE.** `chain-merge.sh` logs, once per run, when a record is present
  but not admitted as this dispatch's. Before that it was indistinguishable from a lane that had
  simply not opened its PR yet — a discarded refusal cost the whole 90-minute wait and read as an
  ordinary timeout.
- **A YIELDED backlog no longer reads as stillness — and it now says so through the FUNNEL.** A
  cycle in which every candidate sits inside its yield window leaves `.batch` empty. The pre-#2040
  sentence then printed `backlog empty queue=READ(3)` and the cycle stayed that way for as long as the
  yield (up to 24 h at the clamp) — self-contradictory on the one line an operator reads to answer "is
  there work?". ⛔ #2040 later proved that SENTENCE itself was the defect (`backlog empty
  queue=READ(223)` while 223 candidates had been read and every one filtered away), so resolving this
  branch against it does **not** resurrect the claim: the yield count rides the funnel that replaced it
  (`dispatch_funnel`'s `yields=<n>`, in words: "this is NOT \"the fleet has nothing to do\""). The note
  is **additive** — measured by the loop, never one of the refresh's reconciled buckets — so a yielded
  backlog is visible on the no-dispatch line AND a yields note can never make an unreconciled funnel
  read as summed. With no yields the line is byte-for-byte the #2040 shape, so nothing that parses it
  changes.

`capacity-transfer.test.sh` drives the shipped `lane.sh` and `chain-merge.sh` and extracts
`capacity_yield_live()`, `dispatch_funnel()` and `cap_refusal_gate()` from the live scripts, with a
**local bare repo** as the shared origin so the released claim is a real fenced push.

⛔ **THE TWO MEASUREMENTS ARE NOT THE SAME RUN, AND THEY DO NOT HAVE THE SAME TOTAL** — quote them
per side, never as one:

| tree | `bash scripts/orchestrator-harness/capacity-transfer.test.sh` |
|---|---|
| **this suite's own tree** (post-fix) — `52 / 0` at the round-2 boundary fix; the same tree reported `46 / 0` at `b9f7633f`/`dcc24feb`, before §2b3's 6 sites existed | `passed: 52   failed: 0` — all 52 assertion sites |
| **the pre-change scripts** (`origin/main`'s `lane.sh`/`chain-merge.sh`/`orch-loop.sh`/`claims.sh` beside the new suite) | `passed: 10   failed: 28` — **38** sites reached |

The 14-site gap is two extraction-gated blocks that skip LOUDLY when the function they drive does
not exist: §3's **9** behavioural checks (`capacity_yield_live()` is absent from the pre-change
controller) and §2b3's **5** boundary checks (`cap_refusal_gate()` is absent from the pre-change
chain; the section's own "present" check is reached there and reds).
**52 is therefore unreachable on the pre-change tree and 38 is unreachable on this one** — a
pre-change run that reports 52, or a post-change run that reports 38, is measuring the wrong tree.
The pre-change passes are the checks that assert a refusal *didn't* happen and the ones pinning
behaviour this change leaves alone (§1 x3, §2 x3, §5 x4; e.g. "no `yields=` with no yields"). Per
section, pre-change → post-change: §1 10 → 10, §2 15 → 20, §3 1 → 10, §4 5 → 5, §5 7 → 7, so only
the two extraction-gated blocks move. The suite's `pi`/`gh`/`df` stubs are
**exported bash functions**, not files on PATH: both tested scripts re-prepend absolute dirs
(`/opt/homebrew/bin:/usr/local/bin`), so a PATH stub loses to the machine's real binary — measured on
the writing runner, where `/usr/local/bin/pi` beat the stub, and on any macOS deployment box, where
`/opt/homebrew/bin/gh` would have made `gh pr list` a real authenticated call from a suite that
promises no network. Residuals, named rather than hidden: the
review/fix path's load refusal (`merge-one.sh` returning 75) is re-dispatched by the sweep and is
**not** transferred, because it is work on an existing PR rather than an un-owned queue item; and
the stand-down is per **issue**, so a box at capacity still holds no view of *which* peer is idle —
peers take refused work by the ordinary severity-ordered pool, not by being told to.

### 7.2f PRs before issues — the dispatch ORDER, and ownership as a LIVE fact (owner ruling, 2026-10-18)

**The rule, as the owner stated it:** (1) take on UN-OWNED PRs first — "owned" means a LIVE PROCESS is
working that PR, not "someone intended to"; (2) fixing/salvaging a PR counts as taking it on, so a
conflicted or red PR is exactly the work; (3) only when NO un-owned PR remains may the dispatcher
create new work by picking issues; (4) and only if spare capacity remains; (5) never cap lanes to a
trickle to avoid this — the bottleneck is the queue, not the lane count.

**What was measured, and why the old gate could not see it:** 25 open non-draft PRs, **0** owned by a
live process, 25 un-owned. Nothing was working them. `pr-doctor` reported 21 "running" lanes while a
live-cwd scan found **none** of them holding a PR branch — its notion of "running" was not ownership.
Meanwhile `orch-loop.sh` gated issue dispatch on `unowned > MERGE_PRIORITY_AT` (**25**), so exactly
that state read as "not a backlog" and the box opened MORE work from issues: throughput stalled at
~4 merges/hour while the queue grew.

**The predicate is now a live fact** (`live-ownership.sh`, one probe per cycle):
a PR is owned **iff** some running process's cwd is inside a checkout whose checked-out branch is that
PR's `head.ref`, **or** inside a worktree whose PATH carries the PR number (`aig-wt-2001`,
`pr1963`, `1730-fix` — anchored on a marker token, so a date directory `2026-10-17` is not mistaken
for PR #2026). Cell ownership is the same predicate one level up: a process cwd under that box's
clone. Process cwd is read with ONE probe (`lsof -a -d cwd -Fpn`; `ls -l /proc/*/cwd` on Linux) and
joined against `git worktree list --porcelain` by LONGEST prefix, so a worktree under
`.worktrees/x` names its own branch rather than the repo's.

⛔ **What no longer counts as ownership, and it is the point:** a `fix-<PR>`/`merge-<PR>` **tmux
session name** (a reviewer reads the PR through `gh` and holds no branch; a session outlives its
work), a **`needsfix-<PR>-<head>` marker** (it *authorises* a spawn, it does not prove one ran), and a
**local claim ref whose holder died** (the lease outlives the process by design — `claims.sh`:
"LEASE = DATA, NOT LIVENESS"). Each of those is a record of INTENT, and reading intent as work is what
produced the measurement above.

**Five guards make the predicate hard to fool, each added after a review that falsified the earlier
version** (`test-gates.sh` pins all five, `live-ownership.test.sh` drives four of them against real
processes):

* **A shared ref is not PR identity.** A fork PR's `headRefName` is only a branch name, so branch
  equality alone let any PR whose head ref was `main`/`master`/`patch-1` read OWNED because some
  process was merely *sitting* on that branch. Refs every repo has are refused; only the path rule may
  decide them.
* **A leftover cwd is not a branch.** A process whose cwd is in a deleted/unregistered
  `.worktrees/<x>` fell back to the ROOT checkout by longest prefix and reported the root's branch.
  Such rows are marked `(stale)` and match no PR. (Measured on this box: two `main` rows, one from a
  deleted `.worktrees/fix/1712-…/scripts/…` cwd.)
* **A live pid is not a worker.** `merge-one.sh` writes nothing but `$$` into its lock, so a recycled
  pid would keep a PR "owned" for ever — self-reinforcing, because the controller then never spawns
  the worker that would delete the lock. Ownership now requires the pid's **command line** to be the
  merge worker *and* to name that PR — in **both** spawn forms: positional (`merge-one.sh <repo> <or>
  <pr> <branch>`) and the rail's `--argv state/argv-<PR>`, where the number appears only inside a
  filename. (`claim_live` deliberately keeps the looser any-live-pid test: there the direction is "do
  not spawn", and a stricter test would `rm -f` a live worker's lock.)
* **Ownership never inherits the spawn guard's looseness.** The cross-box arm used to delegate to
  `claim_live`, whose first arm is that loose lock test — so a stale `mergeclaim-<PR>.lock` with a
  recycled pid lent liveness to an **expired** foreign lease, and the PR left the queue for ever. The
  lease reader is now its own function (`claim_lease_live`): two callers, two questions, one reader
  each.
* **A `(stale)`/`(cell)` row matches no PR — by PATH as well as by branch.** Marking the branch was
  half a fix: the path arm never read it, so one leftover process in a deleted
  `.worktrees/fix/1712-abc` still owned PR #1712. Both arms refuse those rows, and `lo_select_rows`
  applies the same shared-ref list as `lo_owns_branch` so the funnel's marks cannot disagree with the
  gate inside one cycle.
* **A quiet box is an ANSWER; a failed census is UNKNOWN.** `lo_scan` returns 0 when the census read
  the process table — including when no process is inside this repo (that means *everything is
  un-owned*, the drain direction) — and 2 only when the probe itself failed or read nothing. Before
  this, a healthy idle box reported `UNREADABLE` every cycle, which is how a real alarm stops being
  one. The probe is captured before it is parsed, so an absent/broken `lsof` cannot look like a
  successful empty census. And when the scan does fail, the loop BLANKS `LO_LIVE`: the module cannot
  always delete its own output (an unwritable `state/` cannot be written to *or* cleaned), so a stale
  table must be made unreadable rather than trusted.
* **A fallback may not LOWER the gate.** When the per-PR rows are gone, the count is the whole open
  listing ("assume nothing is owned"), and the scope-filtered swept set can read fully owned. The floor
  is applied (`⚠️ fail-closed floor: …`) so the smaller number can never open the issue path.
  ⛔ `SWEEP_LIST` does **NOT** survive a non-200 sweep: it is reset every cycle (`SWEEP_LIST=""`
  before the request) and only filled on a 200, so a 304 or a deferral leaves the sweep loop with
  ZERO rows to read. An earlier version of this paragraph claimed otherwise; the same false claim was
  in the loop's own comment and in a test comment, and all three were repaired with agent-infra#2126.
  The consequence is the reason the per-PR disposition ledger exists: on such a cycle the sweep
  attempts nothing, so the only honest thing the cycle can do is NAME that (`[pr] PR path: NO UNIT
  SPAWNED this cycle — … no per-PR read this cycle`), never imply a dispatch.

⚠️ **Three residuals, stated rather than hidden.** (a) A *reviewer* in flight holds no branch, so its
PR reads un-owned: that over-counts the work queue — the safe direction here (take on MORE PR work,
never less) — and the unchanged `sess`/`claim_live` spawn guards still refuse to double-work a PR. (b)
A claim held by **another box** *is* counted, because a remote pid cannot be probed and the lease is
the only evidence that can exist; a claim held by **this** box is not (only a live process is). (c)
The sweep's own `OWN`/`UNOWNED` marks come from ONE awk pass over branch+path, while the gate's count
also applies the merge-lock and foreign-claim arms — so the funnel's `owned` figure can UNDER-count
by those two (a PR another box is merging still reads `UNOWNED` there, and can be named as `first`).
The gate's number is unaffected, the shared-ref list is now the same in both (so they cannot disagree
in the dangerous direction), and the spawn guards still refuse the double work; unifying them into one
pass is a follow-up, not a silent gap.

**The reviewer/fixer headroom now follows the gate's predicate too** (`unowned > 0`, not
`unowned > MERGE_PRIORITY_AT`): with the gate blocking on ONE un-owned PR, keeping the old size
threshold would have drained the measured 25-PR queue at the pre-change WIP — the "capped to a trickle"
shape the ruling forbids. `is_num` guards the count, because an errored `[ … -gt … ]` is FALSE and
would silently pick the smaller budget.

**The order is printed every cycle, and the choice is auditable in one line:**

```
[select] population=swept (open-rows=0 swept=61 fallback_open=26)
[select] 61 PRs: 56 un-owned (5 owned, 0 parked/needs-human excluded) -> dispatching PR-takeover (first #1161 — conflicted before pending, oldest first) ; issues: SKIPPED (un-owned PRs exist)
[dispatch] issues BLOCKED — 56 un-owned PR(s) remain; this cycle's work is the PR queue (first #1161)
[dispatch] drain alive — last land 12m ago (#9065); 56 un-owned remain
```

(The first two lines are a REAL cycle on this repo's live queue; the third is that cycle's next line
when `state/merged-*.done` exists — `population=` says which of the three sources answered, so a
degraded population is visible rather than inferred. `open-rows=0` there is the GraphQL listing having
been rate-limited while the REST sweep succeeded: exactly the fallback this design exists for.)

* **Conflicted before merely-pending, oldest first**, and the sweep now ACTS in that order, so a
  scarce fixer/reviewer slot goes to the PR that unblocks the queue rather than to whichever PR
  GitHub listed last (REST lists newest-first). Classes come from the last observation the sweep
  made (`state/prclass.tsv`, folded to one row per PR per cycle); the age comes from the listing's
  `created_at`, which rides the SAME request.
* **`issues: SKIPPED` has a reason, always.** An un-owned set that is non-empty, an unreadable
  count, or a capacity gate: `busy` and `draining` must never be the same reading of the log.
* The funnel's verdict **gates** the issue path (`LO_CHOICE`), so a printed decision cannot be
  ignored by the code that acts on it.
* **No threshold and no lane cap.** `MERGE_PRIORITY_AT` survives only as the reviewer/fixer headroom
  trigger (a backlog SIZE, which is what it actually measured); `MAX_LANES` and the capacity gates are
  untouched.
* **A lost funnel line is a HOLD, not a re-decision.** The fallback used to key on the line being
  empty, so a failed write to `state/` silently re-decided the cycle from the capacity gate — and with
  nothing binding that gate, that OPENS the issue path while the funnel had chosen PR work. The
  fallback now keys on **availability** (is `lo_select` defined?): module present but silent ⇒ issue
  path closed and the reason named; module absent ⇒ the documented registry-only degrade.
* **The parked subtraction is over UN-OWNED PRs only.** The count already excludes owned PRs, so
  subtracting a PR that was both parked and owned removed a unit that was never in the minuend — with
  exactly one un-owned PR left that floored the gate to 0 and opened the issue path.
* **There is NO release arm, and there will not be one.** A drain that stops landing prints
  `DRAIN STALLED — no PR merged in <n>m (last #<pr>) while <n> un-owned remain` and the issue path
  stays closed. The temptation — "nothing has landed in 4h, so let issues through" — converts *PRs are
  not landing* into *dispatch more issues*, which is how a stall hides behind fresh activity. The
  ruling is unconditional (`Only when NO un-owned PR remains may the dispatcher create new work`), so a
  stall is a LAND/CAPACITY problem to fix, and the line exists to name it. `test-gates.sh` pins the
  absence of such an arm, and pins that the stall AGE is printed only — never handed to the gate.
* **Parked PRs are excluded from the gate's number** — a PR parked at `MAX_FIX_TRIES` is one the
  harness itself declared needs-a-human, and letting it hold the issue path shut forever would be the
  "stale flag that latches a gate" failure. The count is printed so the subtraction is visible.

Proof: `live-ownership.test.sh` spawns REAL processes in REAL worktrees and asserts owned / un-owned
/ stale-registry-claiming-owned-but-dead, plus the four selection cases (3 un-owned; 0 un-owned +
capacity; 0 un-owned + no capacity; registry-says-owned-but-process-dead). It was mutation-tested:
disabling the branch arm, inverting the conflict rank, and removing the PR-first block each turn it
RED (the first version of the suite did NOT catch a disabled branch arm — the fixture's worktree path
answered through the path rule — which is why §1b of that suite isolates the branch arm).

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
| **the scout worktree was created once and never updated** — the pass pre-flighted with whatever copy `chore/dispatch-scout` froze at (measured 2026-10-19: **191** commits behind `origin/main`; re-measured 2026-10-20 on a cell: **258** behind, the branch tip still `430ff7cce` from 2026-10-16) | a fix to the gate could not reach the harness that runs it: the cell pre-flighted with a lane-liveness reader whose cmux verb that build no longer has, so **every** candidate came back `INCOMPLETE`, the pass ABORTED `judged 12 / usable 0`, and the cell dispatched nothing behind a log line that read `FAILED rc=1 (transient — retried next cycle)` (agent-infra#2174) | the pass now `git fetch` es `main` into `refs/remotes/origin/main` (destination named, so a mis-mapped `remote.origin.fetch` cannot make a no-op fetch look like currency) and moves the scout to that tip **on every pass**, logging the gate it judged with (`[refresh] gate: <path> cksum=<n>`, plus `unversioned=1` when the gate lives in a tree this pass cannot version); a scout that cannot be refreshed **refuses to judge**, naming the sha and the failed step, with rc=3 (`NOT PROVISIONABLE`: `.git` link that does not resolve, no `origin`, no `main`, no `origin/main` after a fetch, a gate whose bytes are not the ones at the checked-out commit) or rc=1 (`TRANSIENT`: network, uncommitted tracked work, commits not in `origin/main`, an untracked file in the way) — so the loop writes a MERGE-ONLY marker only for the permanent causes, quoting the refusal; `--check` refuses the offline-judgeable causes too, read-only: a scout whose `.git` link does not resolve, a worktree with no `origin`, commits ahead of `origin/main`, or (when a move is needed) uncommitted tracked work — the last two as rc=1 with a `TRANSIENT: scout` token, so the two consumers' diagnosis follows the refusal instead of always naming a provisioning defect — plus, for a scout that is its own worktree, a gate that is untracked or edited relative to `HEAD`; remote reachability, a trunk that is not `main`, and that byte test on a NON-worktree scout are deliberately left to nobody: the byte test is skipped on both paths for that shape, whose whole protection is the announced `unversioned=1` (#2217); uncommitted work in the scout is never discarded |
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
- **The capacity gate was SOURCE-ONLY (agent-infra#1884) — the spawn point now owns it.** The load
  gate was a library a caller had to SOURCE, so the control was exactly as strong as the weakest
  caller, and a caller that omitted it was not merely ungated but INVISIBLE: no refusal, no log line,
  no count. Measured 2026-10-16: the orchestrator started three lanes from
  `tmux new-session -d -s <name> "… pi -p …"`, no `lane.sh`, so `MAX_LOAD` was never read — on a box
  at load 258 on 10 cores against its own ceiling of 100. **✔ FIXED** — `spawn-gate.sh` is also an
  executable installed as `$HOME/.pi/agent/bin/pi` (first on PATH), so every `pi` resolves the gate; a
  refusal names the reading/ceiling/item/caller, is counted in `~/.pi/agent/state/spawn-gate.tsv`,
  and exits 76 (translated to the callers' 75). Named residuals: an invocation that bypasses PATH
  (absolute path, `env -i`, a `PATH` reset) is not gated — that is the operator's documented rescue,
  and `MAX_LOAD` stays the operator's own tunable — and the **`task`/sub-agent dispatch does not pass
  through PATH at all** (`getPiInvocation` spawns `process.execPath` + the entry script so a truncated
  PATH cannot cause ENOENT), so a `task` child is a SECOND spawn point this gate does not cover
  (agent-infra#1920).
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
  moves again. tortoise's `fix/8468-closure-linkage` branch rewrote this same directory (P0 bypass,
  `.prio`, `merged-not-closed.sh`, lane brief); this PR ports it, minus the P0 bypass, which main's
  unconditional drain rule supersedes.
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
| `lane.sh` | the implementation worker (prompt template included). Since agent-infra#2148 it hard-requires `reviewer-preflight.sh`, prints the reviewer requirement once **before** any work, and splices the reviewer step into the generated brief — the requirement is no longer discovered by being refused at the rail |
| `reviewer-preflight.sh` | the reviewer requirement, disclosed up front (agent-infra#2148): `reviewer_preflight_line` / `reviewer_brief_section` for the three audiences (`self` = the lane lands through the rail; `harness` = a worker that pushes code while `merge-one.sh` mints the attestation; `reviewer` = merge-one.sh's own reviewer session, which posts the verdict comment and must not push, record or merge — no brief section, by design). The `self` line also names the override for a launcher that exports no `KIND` ("if your brief says you have no `task` tool, that overrides this") — the content-repo copy of `lane.sh` is in that state today (tortoise#8432). Sourced by `lane.sh`; also `--line`/`--brief`. Its wording is drift-pinned against the pi side (`extensions/shared/reviewer-preflight.ts`) and carried by `templates/LANE-BRIEF.md` |
| `chain-merge.sh` | waits for the lane's PR, then runs the merge chain |
| `merge-one.sh` | fresh review → signed record → wait green → merge; marks `needsfix-*` |
| `fix-one.sh` | fixes a reviewer's findings, pushes, re-runs the merge chain |
| `refresh-candidates.sh` | pre-flights issues (collision check) into the backlog |
| `selftest.sh` | offline checks; each one drives the shipped code. Not part of the loop |
| `install.sh` / `launchd-cycle.sh` | the installer, and the ONE implementation of stop/enable/(re)start/verify for the launchd job (§4). A plain `install.sh` never touches a loaded job; `--start`/`--restart` harness the loop and PROVE it started. The library never writes a persistent disable and never mutates a job that was not loaded from this plist |
| `install-launchd-durability.test.sh` | the agent-infra#1975 contract — no persistent-disable verb in code or in a copyable README command, `bootstrap`→`load` fallback, the ownership guard, and "not running AND (disabled OR exit 0)" as a FAILURE. Hermetic (`launchctl` stub first on `PATH`, throwaway `$HOME`/`$O`), and a CI shard via `scripts/run-bash-shards.sh` |
| `test-gates.sh` | the `mp_reason` dispatch-gate rule table, extracted from the shipped `orch-loop.sh`; the repo-authority contract and the rail branch driven from `merge-one.sh`; and (agent-infra#1952) the **landing claim** — a second box refused the same PR, three independent keys, fenced release, release frees the PR, non-vacuity, and `merge-one.sh`'s acquire-before-the-review ordering. Hermetic. Not part of the loop |
| `test-claims.sh` | the PR **and issue** claim CAS against live origin from two scratch repos (`git init` + `remote add`, not clones; random keys per run so concurrent runs cannot collide). Not the cross-box proof (one machine), but red on a defeated CAS. Not part of the loop |
| `claim-exclusion.test.sh` | **the measurement:** N processes released at a barrier against a real (bare) origin, per operation class, answering *does a duplicate holder get refused*. Prints the table §7.2d records; hermetic, a CI shard |
| `gh-limit.test.sh` | #1988 the layer UNDER every gh call: one call in flight per box — the retry path AND the `/rate_limit` probe (measured from the stub's own timestamps, with an unserialised control that MUST overlap), the documented backoff order (`retry-after` → the bucket's reset → ≥60s doubling, 4 attempts, then a loud failure), the failing bucket NAMED, `>= 1s` between mutations, conditional REST (`if-none-match` → a 304 replayed byte-exactly from a bounded cache), and the shim surviving the `/opt/homebrew` PATH prepend in every gh-calling script. Fake clock, stub gh, hermetic, a CI shard |
| `gh-rest.test.sh` | the `gh` REST adapter's argv-to-argv **TRANSLATION**, offline against a stub `gh`: `pr list --head` must not widen to the newest open PR and `pr comment` must print a URL (both shipped green once, as P0s, when nothing asserted them). Hermetic, a CI shard |
| `test-crossbox.sh` | drives the real `merge-one.sh` claim acquire + trap release with `gh` stubbed. Not part of the loop |
| `refresh-scout.test.sh` | the agent-infra#1736 contract — repo-aware scout provisioning, per-repo tool resolution, the permanent/transient refresh split — plus the agent-infra#1850 issue-claim pre-flight verdict table (CLEAN/COLLISION/INCOMPLETE/NOT PROVISIONABLE/unrecognised), the dispatch-side claim, and the fenced + generation-guarded release. Also the agent-infra#1729 pass budget: a blocked pool HEAD does not consume the window, the collision ledger defers (never drops) a held candidate, and ONLY a COLLISION is recorded — a DEGRADED answer never is. Not part of the loop |
| `refresh-quota.test.sh` | the per-pass API **spend** contract (agent-infra#2022 / #1736 follow-up): the board cache is enabled under the TOOL's own seam (`COLLISION_PREFLIGHT_BOARD_CACHE`, not the legacy no-op name the tool treats as a caller-named-cache attack), so one pass rebuilds the board once instead of once per candidate; a pass that can only afford SOME of its window judges those completely, queues work and NAMES the stop; a pass that can afford none refuses TRANSIENTLY — after the `dispatched.txt` reaper has run — rather than reporting an empty backlog. Charges a modeled core budget from a stub `gh`, so it needs no network. A CI shard |
| `check-port-drift.sh` | gates the tortoise-side removal: fails if the tortoise harness moved past the pinned sync point (`port-provenance.txt`). Not part of the loop |
| `cloud-cell-doctor.sh` | the cell's scheduled roles — `reap` / `doctor` / `merge` / `hygiene` / `status` (§6.5.7). Launched as tmux `cell-doctor` (`$DOCTOR_SESSION`) by `cloud-cell-supervisor.sh start`; `merge` EXECUTES `scripts/admin-merge.sh` and never re-implements it |
| `cloud-cell-doctor.test.sh` | #1989: drives the shipped doctor and the supervisor's role verbs against stubbed tmux/ps/rail — a lane whose child is still writing is NOT reaped, an attached/human-tty lane is NOT touched, the rail is gated on a clean attestation at the head, a refusal is recorded and not retried at the same head, and `status` FAILS a started cell whose roles never ran. A CI shard |
| `cloud-cell-doctor.hardening.test.sh` | #1989, the HARDENING half (a separate suite, not a fork of the one above): every read the doctor acts on must be classified, so an unreadable session list / client list / ancestry walk / pane read / log mtime / process table / open-PR read / review record is cannot-verify rather than an answer, while a benign non-answer (a fresh box with no server, a lane that ended between reads) is not; an action that did not take (a refused or unverifiable kill, cpu that went DOWN) is never a reap; the rail's rc classifier is a PREDICATE (`124..127`, any `128+N`); and a REHEARSAL IS NOT A VERDICT — `--dry-run` keeps the worse of (stored verdict, its own) and says in the record that it was a rehearsal, on every role. A CI shard |
| `cloud-cell-record-dep.test.sh` | #1717: drives `cloud-cell-supervisor.sh check/start` and `merge-one.sh` against a stubbed toolchain — the recorder is a checked, provisioned dependency, and a record failure parks. Registered in `scripts/run-bash-shards.sh`, so both CI lanes run it |
| `check-deployed-drift.sh` | answers whether the DEPLOYED `$O` matches the repo: the recorded commit against the live ref (`merge-base --is-ancestor`, never a commit count), the recorded payload hash against the deployed bytes, and every repo-shipped `*.sh` blob against its `$O` copy. Exit 0 match / 1 drift / **2 UNKNOWN — never a pass** (agent-infra#1745). Not part of the loop |
| `report.sh` | read-only operator summary: merges in a window, per-kind agent wall-time and cap-hit rate from `state/walltime.tsv`, live `refs/claims/*`, queue health, and the last dispatch decisions. Safe to run while the loop is working. Not part of the loop |

**Manual utility:** `adopt-fix.sh` — run `fix-one.sh` against a specific PR by hand;
`nonblocking-dispatch.sh` — launch a headless worker in the background and return immediately (§2).
Neither is part of the loop.

**Retired** (`retired/`, kept so nothing is lost): `auto-loop.sh`, `dispatch.sh`,
`do-merge.sh`, `refix.sh`, `sweep.sh`, `watch-one.sh`. These are earlier iterations of the
same idea and are no longer invoked; they are included for the record, not for use.

**Retired from the heartbeat, kept here for the record:** `retired/queue-dispatch.py` — the
lane-table dispatcher the beat ran until 2026-10-17 (agent-infra#1874, the retirement half of
#1890). It fed work only to lanes that already existed and were DONE-IDLE, so it could not start
work that had no lane; `pr-doctor.py` replaced it and is now the beat's only dispatch entry point.
Its SPAWN path is switched on: #1894 (#1890) pointed `pr-doctor.py` at `nonblocking-dispatch.sh`
(§2 above), so a dispatch starts a fresh worker in the PR's own worktree and no longer needs a
pre-existing idle lane — `idle_lanes()` is gone from the file. (This paragraph read "NOT SWITCHED
ON YET … CALLED BY NOTHING" until #1894 merged; that was true when the dispatcher was retired and
is false now.)
⛔ It is wired to nothing and farmed by nothing — re-arming it would restore a SECOND dispatch
path, which is the divergence #1890 exists to remove.

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
OR=                     # ⛔ DERIVED from $REPO's origin (repo-slug.sh); an explicit value wins
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

---

## 11. Single source of truth: this directory

**This directory is the ONLY copy of the harness.** Measured 2026-10-19 (blob hashes, 8 chars), before
consolidation the same eight files existed in three places:

| file | agent-infra `main` | tortoise `main` | live `~/orchestrator` | classes | fix preserved / file retired |
|---|---|---|---|---|---|
| `orch-loop.sh` | `e069af29` | `a1ffab3d` | `b4b89547` | (a) + (b) | (a) `P0_BYPASS_MERGE_PRIORITY` + `p0_merge_priority_override` → **NOT PORTED: superseded by main's unconditional drain rule (owner ruling 2026-10-18), see the reconcile note below**; (b) tortoise + live are older generations → replaced |
| `spawn-gate.sh` | `a7dba947` | `f7af7919` | `a7dba947` | (b) | tortoise carried no fix; it lacked the shared-gate refactor → replaced |
| `refresh-candidates.sh` | `a3ac5019` | `facc9a1d` | `a3ac5019` | (a) + (b) | (a) `landed.txt` (skip/write/prune/report), `RETRY_MAX` → ported; (b) otherwise older → replaced |
| `claims.sh` | `d1604686` | **absent** | `d1604686` | (b) | tortoise fork never had it → retired |
| `nonblocking-dispatch.sh` | `5e3fe2b1` | **absent** | `5e3fe2b1` | (b) | tortoise fork never had it → retired |
| `lane.sh` | `3dc22993` | `03400e8d` | `3dc22993` | (a) + (b) | (a) `Closes #N` required / bare `Refs` refused → ported; (b) tortoise lacked the PATH/source-order fix → replaced |
| `install.sh` | `3c0d14a8` | `de2ce83a` | `db02dfb3` | (a) + (b) + (c) | (a) `merged-not-closed.sh`/`spawn-gate.sh` drift list → ported (the `P0_BYPASS` render is **NOT** ported, same reason as `orch-loop.sh`); (b) tortoise lacked `SCOPE`/key-file validation; (c) macOS-only **by design** — Linux names `scripts/cloud-cell-supervisor.sh` |
| `selftest.sh` | `2318d1e0` | `04174f50` | `5675377c` | (a) + (b) | (a) tortoise's landed/RETRY_MAX checks → ported (adapted); (b) otherwise older → replaced |

The live copy was **not** a hand-fork: it was an untracked copy of agent-infra generation
`2ddd5b5a1` (blob-identical on all eight files), one commit behind `main`. That is the same defect
by another route — an unversioned copy cannot be updated, audited, or healed — so it was converted
to symlinks into a git checkout rather than deleted. Its one-generation lag is what `doctor` reports
as `deployed bytes=DIFFERS` on the SYMLINK-into-checkout arm (it reads the target checkout's git
identity, so a lagging checkout is visible) — and NOT via the stamp arm, which needs
`.agent-infra-stamp.json`: an un-stamped conversion reads `check-deployed-drift.sh` = 2 UNKNOWN, by
design (see "which instrument answers which question" below).

The consequence was structural, not cosmetic: every fix had to be applied by hand in three places,
each box ran a different generation, and "self-healing" was impossible because there was no authority
to heal *toward*. And it was actively losing work: the `landed.txt` / `RETRY_MAX` half of
`refresh-candidates.sh` (tortoise#8560/#8625/#8469) was **deleted** by the tortoise retirement before
this pass ported it — the retirement's own premise, "every fix was ported first", was false for that
file.

**The rule.** A fix is ported HERE first. `operations/orchestrator-harness/` in tortoise is retired
to a pointer, and **tortoise CI fails if a harness script reappears there** — that check is
tortoise's `tools/check-harness-fork.sh`, run as a step of the `manifest-integrity` job in tortoise's
`.github/workflows/python-ci.yml` (a `needs:` of its required `python-ci-gate`), because it is
tortoise's tree that must stay retired. ⛔ **NOT** a `.github/workflows/harness-single-source.yml` in
tortoise — that file does not exist: it was removed on purpose, because a path-scoped workflow is not
a required context (the guard's own header records that). The same filename HERE is a different
check (canonical completeness + non-vacuity of this repo's copy, not the retired tortoise path). The
live copy is a versioned checkout of this repo rather than an orphan directory of hand-copied files.

**The instrument.** `check-single-source.sh` asserts all three halves and FAILS on any of them:

```bash
./check-single-source.sh                                  # canonical completeness
./check-single-source.sh --fork ../tortoise/operations/orchestrator-harness
./check-single-source.sh --o ~/orchestrator               # deployed bytes == canonical bytes
./check-single-source.sh --require-target --o ~/orchestrator # the CI form: checking nothing is a failure
```

⚠️ `--require-target` counts a target only when at least one file was ACTUALLY compared. With
`--fork <dir>` on the CORRECT retired state (the directory absent, or holding only a pointer README)
nothing is compared, so `--require-target --fork <dir>` exits **2 UNKNOWN** — by design, and it prints
`ok: retired location is absent (<dir>)` (an absent path) or `ok: <dir> holds none of the 8 fork-arm
files (…)` (a directory that exists but carries none of them) immediately before it. The CI form
therefore passes `--o` (a real comparison), and the fork step of that job plants a fixture without
`--require-target`.

Three shapes are now UNKNOWN rather than a clean answer, in BOTH arms: a path that exists but does not
resolve (a dangling symlink — `-e` is false for it, so it used to read as "absent"), a path that exists
but is not a directory, and a directory that cannot be searched (`-f` is false for every file inside,
which used to read as "no fork" / "eight files missing"). And asking either arm to compare canonical
with ITSELF (`--o <this directory>`, or `--fork <this directory>`, which includes the symlink farm
README §11 recommends) is UNKNOWN: a self-comparison proves nothing and its "delete it" message would
name the source of truth.

**The fork arm's file list is curated and its one exclusion is named.** It looks for the `SHARED`
set (the eight files whose divergence caused the measured incident) plus a printed note naming
`merge-one.sh` as deliberately excluded — tortoise still holds the only copy of the unported
#8484/#8589 fix, so a fork arm covering it would fail the real retired location. Everything else is
covered by the deployed arm, which byte-compares every SHIPPED file — `*.sh`, `gh-limit.py`,
`gh-rest/gh` and `gh-limit/gh` (a `*.sh` glob excluded the last three, which is the very file the
arm's header claims it caught) — and by `check-deployed-drift.sh`'s shipped-surface half.

**Scope of what is observed, stated honestly:** the check only looks where it is told. The fork arm
observes the paths passed via `--fork` (or the colon-separated `HARNESS_FORK_PATHS` that
`bin/harness doctor` uses), and the deployed arm observes `$O`/`--o`. Nothing walks the filesystem
looking for copies — an ignore-blind walk is the fleet's most expensive habit (#1069), so a fork
check must be explicit about what it looked at. The CI job proves the check is **non-vacuous** with
a planted fixture; *watching the real tortoise path* is the tortoise-side job.

⛔ **`HARNESS_FORK_PATHS` is unset by default, so `doctor`'s fork arm does not run until an operator
names the retired locations** — and its `--json` surface says which it was: `"forksChecked": false`
with `"forks": "not checked"`, never a bare `OK` that a consumer could read as "no fork found". Set
it in the shell you run `doctor` from (it is an OPERATOR setting, not a daemon one: launchd inherits
no shell environment and the plist does not render it, so putting it there would change nothing):

```bash
export HARNESS_FORK_PATHS=$HOME/eldato/tortoise/operations/orchestrator-harness   # colon-separated
bin/harness doctor        # the forks line now names a verdict for that path
```

A path containing a space is fine — it is used verbatim (it used to be rewritten by a whitespace
strip, which made a spaced path report `ok` for a directory that did not exist).

Exit `2` is `UNKNOWN` — "could not verify" is never a pass, the same doctrine as
`check-deployed-drift.sh`.

### Platform differences are NAMED, not accidental

The harness runs on two platforms with two supervisors. This is a legitimate difference and it is
expressed as **a shared code path plus an explicit platform branch**, never as two drifting copies:

| | macOS (darwin) | cloud cells (linux) |
|---|---|---|
| supervisor | launchd | systemd unit **or** a running `cloud-cell-supervisor.sh` process |
| installer | `scripts/orchestrator-harness/install.sh` | `scripts/cloud-cell-supervisor.sh` |
| job label/unit | `com.eldato.orchestrator-loop` | an `orchestrator-*`/`com.eldato.orchestrator-*` unit |
| status verb | `launchctl print gui/$UID/<label>` | `<repo>/scripts/cloud-cell-supervisor.sh status` (the supervisor's own verb — NOT a `pgrep -f` match) |
| `timeout(1)` | absent — `run_agent` uses a bash `wait` + watchdog | present, but the same fallback is used |

⚠️ The Linux supervisor probe is NAMED and STATE-CHECKED, not a substring match (review P1).
Measured on a cell 2026-10-19: `systemctl list-units` contained `eldato-disk-reaper.service` in state
`failed`, and an `eldato|orchestr` grep reported `supervisor systemd … verdict OK` for a box with no
harness supervisor at all — a false answer to the one question the verb exists to answer. The probe
now requires (a) an ORCHESTRATOR unit name, (b) ACTIVE state, and (c) never treats a unit FILE on
disk as evidence that one is loaded (the macOS arm already refused that inference). A cell whose
supervisor is the process (tmux + process table, which is how `cloud-cell-supervisor.sh` works) is
reported as `supervisor process`, with the evidence named.

### Which instrument answers which question (all three, and they DISAGREE by design)

| question | instrument | what it needs | its `2` means |
|---|---|---|---|
| is the harness ONE source — canonical complete, no re-fork, deployed bytes equal? | `check-single-source.sh` | a repo (and optionally `--o`/`--fork`) | nothing was compared |
| which commit is this box RUNNING, and does it match the record? | `check-deployed-drift.sh` | the deployment's `.agent-infra-stamp.json` | no record → cannot answer (the #1745 laptop state) |
| what is this box (platform, supervisor, installer, canonical vs deployed kind)? | `bin/harness doctor` | nothing but a shell; read-only | some field could not be read |

⛔ THEY DISAGREE ON PURPOSE, AND NO ONE OF THEM IS "the" answer (review P2). On an un-stamped
symlink-into-checkout box — the shape this section recommends — `check-single-source --o` says 0,
`doctor` says 0, and `check-deployed-drift` says **2**, because only the last one requires a RECORD
of what was installed. On a box with no deployment at all the same three read 0 / 0 / **2**. That is
not a contradiction to be papered over: each `2` means "this instrument cannot answer", and the
reader must take the answer from the instrument that CAN. A future consumer should read
`doctor` for the box's shape, `check-single-source` for the bytes, and `check-deployed-drift` for
the audited history — and if a green verdict is needed from all three, deploy with a STAMP: `install.sh`
writes `.agent-infra-stamp.json` on the Mac (`STAMP="$O/.agent-infra-stamp.json"`), and the cell's
`seed_and_stamp` → `stamp_write` writes the same record. ⚠️ The Mac copier
(`deploy-mac-orchestrator.sh`) does NOT write one — it copies bytes, so a box deployed only by it leaves
`check-deployed-drift.sh` at 2 (measured: `UNKNOWN: no harness record … this is NOT a pass`), which is
the honest answer to "which commit is this box running?" when nothing recorded it.
⛔ AND THIS SCRIPT CANNOT ANSWER ITS OWN DEPLOYMENT QUESTION (corrected review P2, cycle 7): it ships to
`$O`, so `$O/check-single-source.sh --o $O` is canonical compared with itself — it now refuses
(`UNKNOWN: … a self-comparison proves nothing`) instead of reporting `targets compared: 1` and staying
green over a stale edit.

`install.sh` is macOS-only **on purpose** and says so; on Linux it names the cell supervisor rather
than dying with no next step. Ask any box which branch it is on:

```bash
bin/harness doctor          # platform, supervisor + evidence, canonical commit, deployed kind, fork state
bin/harness doctor --json   # the same, machine-readable
```

`doctor` exits `0` healthy, `1` drift, `2` UNKNOWN. A known platform with **no** supervisor loaded is
reported as drift: "no job loaded" is exactly the state an operator mistakes for a quiet box. The
supervisor label must be the ORCHESTRATOR's on both platforms (`HARNESS_UNIT_RE`, one anchored
pattern): a `com.eldato.*` unit belongs to some other job, and a `com.tortoise.*` launchd job belongs
to another repo, so neither answers "is THIS box supervised". ⛔ The same pattern, byte for byte, is
what `report.sh`'s macOS controller line matches with: `doctor` and the operator report answer the
same question, so a looseness on either side is a false liveness claim on that side alone (measured:
the report called a box whose own job was LOADED-but-not-running `UP (pid 999)` on another repo's
pid, while `doctor` said `supervisor: none`). The pattern is duplicated rather than sourced because
`bin/harness` ships from `bin/` and the `$O` copier would not carry a shared file to both — so
`selftest.sh` asserts the two literals are IDENTICAL, and a loosening on one side reds the suite.

### Ports taken from the retired fork

The tortoise copy was an old generation — except for fixes it received after the handover that never
came back. Those were ported IN, not discarded:

| fix | why it mattered | where |
|---|---|---|
| `Closes #N` required; a bare `Refs` is refused | a finished lane writing `Refs` never closes its issue, and nothing re-reads it: 25 of 36 open P0-blockers already had merged PRs (tortoise#8468) | `lane.sh` — the brief text, i.e. an instruction to the lane, NOT a gate: `check-pipeline-compliance.sh` accepts the `Still open: <indicator>` traceability form for any diff, so the backstop is a reviewer and `merged-not-closed.sh`, not a refusal |
| `merged-not-closed.sh` | the fleet could not answer "which open issues already have a merged PR?" — no tool existed | new file |
| `landed.txt` (skip / write / prune / report) + `RETRY_MAX` | a LANDED verdict written to `checked.txt` retires an OPEN issue from the backlog permanently and invisibly; and an entry that never answers starves the whole pool behind it (tortoise#8560/#8625/#8629/#8469 P2) | `refresh-candidates.sh` (reaper) + `selftest.sh` |
| `verdict_kind()` / `apply_verdict_marker()` | a verdict-LESS reviewer run (stall/crash/timeout) must not authorise a fixer: 7 of 7 cap-hits in one window were verdict-less and 4 were parked "needs a human", never reviewed | `merge-one.sh` |
| ⛔ a P0-blocker outranks the merge-priority gate (BP0, `P0_BYPASS_MERGE_PRIORITY`, `.prio` map) | **NOT carried — reconciled onto main and superseded.** The fork's measurement (19 open PRs, 0 lanes, 33 P0-blockers, 0 closed in 12h) was taken against a gate that closed *below* `MERGE_PRIORITY_AT`; main's rule is unconditional (owner ruling, 2026-10-18: "while ONE un-owned PR remains, it is the work"), so a P0 exception would reopen new issue work on top of an un-worked PR queue — the defect that ruling ends. Nothing reads `.prio` on main | `orch-loop.sh` (rebase: hunk dropped), `refresh-candidates.sh`, `install.sh`, plist |

Everything else the fork carried is here. The BP0 override and its `.prio` rank map are the ONE
part of it that is not: main reached the same goal by removing the threshold outright, and keeping
the override would let a P0 dispatch while un-owned PRs sit unworked — the exact behaviour the owner
ruling forbids. If BP0 is wanted back, it is a **reopen of that ruling**, argued where the ruling
lives — not a merge-time default.

**One fix is still unported, and one file is still in tortoise because of it:** `merge-one.sh`'s
#8484/#8589 detached-reviewer checkout (the reviewer should run in its own tree, and the
`AGENT_ALLOW_MAIN_EDITS` export withdrawn). Deleting the only copy of an unported fix is the silent
destruction this consolidation must not commit, so that file stays, tortoise's guard allows it **by
name** and says so in its output, and this paragraph is the record. Port it, then delete it and drop
it from that guard's `ALLOWED` list.

⛔ **tortoise's `ALLOWED` names TWO scripts, not one** — `ALLOWED="README.md merge-one.sh
merged-not-closed.sh"`. `merge-one.sh` is the unported #8484/#8589 fix above. `merged-not-closed.sh`
is **this PR's** file, still carried in tortoise until #2160 lands: once it has landed there, delete
that copy **and** drop it from `ALLOWED` too, or the guard keeps an exception for a file whose only
supposed home is here. (`README.md` is the pointer itself.) The follow-up is two deletions, not one.
