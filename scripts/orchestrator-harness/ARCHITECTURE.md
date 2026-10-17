# Harness architecture — components, state, and intended behaviour

**Companion to [`README.md`](./README.md).** `README.md` is the originating document and the
authority for *why* the harness exists, its provenance, install steps, merge policy, operating
notes, gaps and measured results. **This file is the component-level reference only**: what each
script does, what it reads and writes, how the state files live and die, what the gate constants
are, the sharp edges that were verified against the code, triage, and invariants.

Read this when you need to answer "what is this file for?", "who clears this marker?", or "why did
the loop refuse to dispatch?". Do **not** read it for install or policy — those are
[`README.md` §3–§5](./README.md). Where this file and `README.md` disagree, `README.md` and the
code win; the inventory of what is shipped vs retired lives in `README.md` §9.

---

## 1. Intended behaviour, in one paragraph

One `bash` process (`orch-loop.sh`) runs on a timer. Each cycle it **drains before it expands**:
it sweeps the open PR queue and merges anything green, repairs anything red, and only when the
queue is under control does it open **new** work — dispatching a GitHub issue into its own
`git worktree`, running an autonomous agent (`lane.sh`) that commits, pushes and opens a PR, and
then running a fresh-context **reviewer** over that PR in a separate process. (The reviewer runs on
the **gate** repos only — a repo whose merge authority is its own rail is merged by that rail and no
harness reviewer is spawned; see §2 and `README.md` §5.1.) A merge is a *decision made by the
repo's own contract* (`repo-authority.sh`), not by a hardcoded check name. Everything the loop
refuses to do — because the box is loaded, swap is thin, the lane budget is full, or the PR backlog
is over threshold — is **named in the log**, never silent.

The design assumption throughout: **no mechanism guarantees a job runs once**, so a job may run
twice and every side effect is made safe to repeat. Claims exist to *reduce* duplicates, not to
promise their absence.

---

## 2. End-to-end lifecycle and hand-offs

This is the control flow, in order. For the ASCII diagram and the worker-type table, see
`README.md` §2; the state files each step touches are in §4 below.

```
issue (open, labelled P0/P1/P2, unassigned)
  │
  ├─ refresh-candidates.sh   pool = unassigned P0-blocker ∪ P1-severe ∪ P2-moderate, minus
  │                           title-prefixed epics/owner-decisions (P0 also excludes
  │                           lane/decision/analysis/investigation) — ORDERED BY SEVERITY FIRST,
  │                           then issue number (tortoise#8465/#8467).
  │                           A bare `sort -n` on the numbers alone ordered by AGE, which put
  │                           hundreds of P2s ahead of the eligible P0s.
  │                           each candidate is pre-flighted (collision pre-flight) → append CLEAN
  │                           ones → candidates.txt (FIFO: its ORDER IS the dispatch priority)
  │
  ├─ orch-loop.sh dispatch   gates first (§5); reads candidates.txt top-down, skips dispatched.txt
  │                           dispatch-merge.sh <repo> <owner/repo> <issue...>
  │                             → `git worktree add .worktrees/tm-<N> -b feat/<N>-tm origin/main`
  │                             → tmux `lane-<N>` + tmux `chain-<N>`
  │
  ├─ lane.sh (lane-<N>)      pi -p in the worktree: implement → commit → push → open PR. The PR
  │                           body's `Closes #<N>` keyword (or `Refs #<N>` for partial work) is
  │                           what closes the issue.
  │
  ├─ chain-merge.sh (chain-<N>)
  │                           polls up to 90 min for a PR on the branch, then runs merge-one.sh
  │                           IN THIS SESSION and exits with merge-one.sh's status.
  │
  ├─ merge-one.sh            (runs under whichever session spawned it: chain-<N>, merge-<PR>, or
  │     1. resolve the head SHA            fix-<PR>)
  │     2. acquire the LOCAL lock (state/mergeclaim-<PR>.lock, noclobber)
  │     3. acquire the CROSS-BOX claim (refs/claims/<PR>-<head12>) — refuse and exit 0 if held
  │     4. ask repo-authority.sh WHICH MODE this repo is in:
  │          gate mode  (the repo REQUIRES the review gate):
  │               reviewer → post the review as a PR comment (the audit artifact)
  │                   CLEAN   → record-review.sh (HMAC-signed marker into the PR body)
  │                           → wait for the gate check to go SUCCESS → `gh pr merge --squash`
  │                   ISSUES  → state/needsfix-<PR>-<head>   (hands off to the fixer)
  │          rail mode  (the repo does NOT require it — e.g. agent-infra):
  │               `scripts/admin-merge.sh <PR>` — the repo's own rail posts its own head-bound
  │               evidence and merges. `gh pr merge` is NEVER called here: it would land on the
  │               required checks alone and bypass the rail. Refused `RAIL_TRIES` (3) times at one
  │               head → PARK that head (state/parked-<PR> holds the head).
  │     5. release the cross-box claim (EXIT trap, bounded to 20s, fenced on our own commit)
  │
  ├─ fix-one.sh (fix-<PR>)   reads the reviewer's findings (and any failing required check's log)
  │                           → edits in a worktree → pushes a new commit → releases the fixer
  │                           claim → re-runs merge-one.sh end-to-end. A new head RE-ARMS the PR.
  │
  └─ terminal states          merged-<PR>.done      merged
                              parked-<PR>          needs a human — either MAX_FIX_TRIES exhausted
                                                   at this head, or the rail refused at this head
```

The **gate-mode vs rail-mode split is decided by `repo-authority.sh`** (`merge_authority`): the
authority is `gate` when the repo's required set contains `REVIEW_GATE` (default `ai-review-gate`),
`rail` otherwise, and `unknown` (which refuses) for an empty, un-normalisable, or
whitespace-bearing contract. `orch-loop.sh` and `merge-one.sh` both source that file so the two
cannot disagree; `merge-one.sh` refuses (exit 5) on an unknown contract at *every* ingress,
including `chain-merge.sh` and `fix-one.sh`.

---

## 3. Component inventory

Live scripts and their I/O. `README.md` §9 lists the same scripts with one-line roles; this table
adds the **reads**, the **writes / emits** and the failure surface.

| Script | Invoked / sourced by | Reads | Writes / emits | Notable failure surface |
|---|---|---|---|---|
| `orch-loop.sh` | launchd (or `nohup`) | candidates.txt, dispatched.txt, checked.txt, `gh` PR state | heartbeat, `.orch.lock`, `.batch`, `state/{claims-snapshot,last-open-n,sweep-etag,sweep-stamp,sweep-defer-until,parked-*,fixcount-*,rerun-*,argv-*}`, `.refresh.lock`/`.refresh-blocked`, log | a cycle that cannot list PRs must not read as "empty" — a FAILED listing is logged and the sweep is skipped, never treated as CLEAN |
| `refresh-candidates.sh` | orch-loop (backgrounded) | `gh` issues, `.open_iss`, `.pr_brs` | candidates.txt (+`.pool`), checked.txt, **rewrites dispatched.txt (the reaper)**, the scout worktree | must never PREPEND; the backlog is FIFO so a later P0 joins at the BACK (bounded: refresh runs only while backlog < 6). A permanent provisioning failure exits 3 and writes `$O/.refresh-blocked` |
| `dispatch-merge.sh` | orch-loop (argv issue ids) | argv issue ids, `git worktree list` | worktree, `lane-*` + `chain-*` tmux sessions | refuses non-numeric issue ids; a failed `worktree add` skips rather than half-dispatching |
| `lane.sh` | dispatch-merge (tmux) | issue body + comments | the worktree/branch/PR, `logs/prompt-<N>.txt`, walltime row (via `run_agent`) | the implementer; runs with local review gates bypassed because the PARENT owns the gate. Hard-requires `spawn-gate.sh` (exit 78 without it) |
| `chain-merge.sh` | dispatch-merge (tmux) | the lane's PR | merge-one run; exits with merge-one's status | waits (≤90 min) for the PR to exist before running the chain |
| `merge-one.sh` | chain-merge, orch-loop, fix-one | PR diff + head, `repo-authority.sh`, `claims.sh` | review comment, PR body marker, claim ref, `state/{mergeclaim-*,needsfix-*,parked-*,merged-*.done,railcount-*}`, walltime row | refuses to run at all if `repo-authority.sh` is missing or stale (fail-closed); the reviewer emits `CLEAN <url>` / `ISSUES <n>`, and **any non-CLEAN outcome (including a failed/timed-out reviewer) writes `needsfix-<PR>-<head>`** |
| `fix-one.sh` | orch-loop (tmux) | the reviewer's comment, `state/needsfix-*`, the failing check's log | a new commit on the branch, `state/fixbail-<PR>-<head>` (cross-box refusal), a **decrement** of `state/fixcount-<PR>` on load refusal, a fixer walltime row | the controller books the `MAX_FIX_TRIES` attempt at spawn; fix-one refunds it when no agent ran and re-runs merge-one on success |
| `repo-authority.sh` | **sourced** by orch-loop, merge-one | this repo's required status checks | the merge contract: `REQ`, `REQ_SOURCE`, `merge_authority` (gate/rail/unknown) | **fail-closed** — an unreadable, un-normalisable, or unrepresentable check set refuses rather than guessing |
| `spawn-gate.sh` | **sourced** by lane.sh and fix-one.sh | load / capacity at source time | the go/no-go for a `pi`, and the walltime row | ⛔ **NOT the only `pi` invocation.** `merge-one.sh` still carries its OWN `run_agent()` with **no load gate**, and `orch-loop.sh` does not source this file at all (it has its own `can_spawn`). `spawn-gate.sh`'s own header names both gaps; `agent-infra#1720` tracks them |
| `claims.sh` | **sourced** by orch-loop, merge-one, fix-one | `refs/claims/*` | claim refs; `claim_snapshot` writes `state/claims-snapshot` | fail-open on an unreachable store (logs it); never fail-closed |
| `install.sh` | a human | env, `launchd.plist.template` | the plist | prints the load command; does **not** start the loop. Warns on drift between the repo copy and `$O` for the scripts the daemon runs |
| `selftest.sh` | a human / CI | the shipped scripts | pass/fail | offline; drives the shipped code rather than grepping it |
| `check-port-drift.sh` | a human | `port-provenance.txt`, tortoise ref | pass/fail | gates the tortoise-side removal. **Compares against a PIN, so a stale pin reports work that has moved (see §6.4)** |
| `test-claims.sh` / `test-crossbox.sh` / `test-gates.sh` / `spawn-gate.test.sh` / `refresh-scout.test.sh` / `sweep-quota.test.sh` | a human / CI | — | pass/fail | each pins one regression contract. `test-claims.sh` cannot prove cross-box atomicity on one machine |

**Manual utility:** `adopt-fix.sh` — materialises a worktree for a foreign branch and runs
`fix-one.sh` against a specific PR by hand; exits with the fixer's status.

**Retired** (`retired/`): `auto-loop.sh`, `dispatch.sh`, `do-merge.sh`, `refix.sh`, `sweep.sh`,
`watch-one.sh`. Earlier iterations of the same idea, no longer invoked, kept for the record —
`README.md` §9 is the authority. Also `retired/queue-dispatch.py`: the lane-table dispatcher the
heartbeat ran until 2026-10-17, retired by agent-infra#1874 (`pr-doctor.py` is the beat's only
dispatch entry point; nothing farms or invokes the retired copy).

**Non-script files:** `README.md` (provenance/install/policy), this file, `port-provenance.txt`
(the pinned sync point), `launchd.plist.template` (rendered by `install.sh`).

---

## 4. State-file lifecycle

**Location.** Paths are relative to `$O/` (default `~/orchestrator`), and **most**
(but not all) live under `$O/state/`; the location is given per row. The head SHA is the re-arm
key for the PR markers: a new push changes the head, so a marker carrying the old head stops
applying and the PR becomes eligible again.

| Path | Written by | Cleared / re-armed by | Meaning |
|---|---|---|---|
| `state/mergeclaim-<PR>.lock` | `merge-one.sh` | removed on clean exit (EXIT trap); a stale lock whose pid is dead is reclaimed by `claim_live()` | **local, one-box** single-owner lock (`set -o noclobber`). Holds a pid |
| `refs/claims/<PR>-<sha12>` (remote) | `claims.sh` | released by the EXIT trap (fenced); expired by lease; `claim_prune` hourly | **cross-box** claim. Lease is DATA (`owner`, `lease_until`) because a remote pid cannot be probed |
| `state/needsfix-<PR>-<head>` | `merge-one.sh` (any non-CLEAN outcome) | deleted when a fixer is spawned; re-created at a new head; re-touched by `refund_bailed_fixer` | "the reviewer found real issues, failed, or timed out AT THIS HEAD" |
| `state/fixbail-<PR>-<head>` | `fix-one.sh` (cross-box CAS refusal) | consumed by `refund_bailed_fixer` (rm) | "a fixer was refused this head by another box" — proof no work happened, so the attempt is refunded |
| `state/fixcount-<PR>` | `orch-loop.sh` (booked at spawn) | decremented by `fix-one.sh` (load refusal) and `refund_bailed_fixer`. **Not head-keyed** (⚠ see §6.2) | fixer attempts consumed for this PR |
| `state/railcount-<PR>` | `merge-one.sh` (rail mode) | reset when the stored head ≠ the current head | `"<head> <n>"` — rail refusals at this head, capped by `RAIL_TRIES` (3) |
| `state/parked-<PR>` | `orch-loop.sh`, `merge-one.sh` | a later push re-arms it (the stored head stops matching) | needs a human; the loop skips the PR while parked at this head |
| `state/merged-<PR>.done` | `merge-one.sh` | never | merge completed |
| `state/rerun-<PR>-<runid>` | `orch-loop.sh` | never | a failed CI run was already re-triggered; stops a rerun storm |
| `candidates.txt` (`$O/`, not `state/`) | `refresh-candidates.sh` (append + dedupe) | consumed by dispatch; pruned by `orch-loop.sh` (drops ids already in `dispatched.txt`); rewritten atomically (`mv`) | the dispatch backlog. **FIFO — order IS priority** |
| `dispatched.txt` (`$O/`) | `orch-loop.sh` (append) | **reaped by `refresh-candidates.sh`** — an entry is removed when the issue is still open, no PR branch matches it, and no `lane-<N>` is live (agent-infra#1705 / tortoise#8519) | issues already dispatched |
| `checked.txt` (`$O/`) | `refresh-candidates.sh` (on the terminal CLEAN verdict only) | dropped for a reaped issue, so pre-flight re-queues it | issues already pre-flighted |
| `state/claims-snapshot` | `orch-loop.sh` (one `claim_snapshot` per cycle) | rewritten each cycle | all live claims, so `claim_live()` pays no per-PR network call |
| `state/walltime.tsv` | `spawn-gate.sh`'s `run_agent` (lane, fix-one) **and** `merge-one.sh`'s own `run_agent` | never — **append-only** | one row per agent invocation: epoch, kind, tag, cap, elapsed, rc. The per-PR logs are truncated on rerun, so this is the only durable series |
| `state/last-open-n` | `orch-loop.sh` | rewritten on each SUCCESSFUL open-PR count | the last good count; reused when a later count fails, so a failure never reads as 0 |
| `heartbeat` (`$O/`) | `orch-loop.sh` | overwritten each cycle | liveness: age > a few cycles means the controller is stuck or dead |

The full list of every file under `$O/` (including `.orch.lock`, the sweep-cache files, and the
per-worker logs) is in `README.md` §2.

---

## 5. Gates — what the loop refuses to do, and the constant that decides it

Every gate names itself in the log (`[dispatch] skipped (<reason>)`). Constants are read from the
**environment at process start** — the plist's `EnvironmentVariables` **overrides the script
default**, so a job already loaded keeps the old value until it is reloaded (or the box reboots).

| Gate / limit (emitted string where the loop logs one) | Constant | Default | Notes |
|---|---|---|---|
| `merge-priority (<n> open PRs — draining before opening more)` | `MERGE_PRIORITY_AT` | 10 | fires only when `open > threshold` **AND** `lanes + workers >= 1`, so it names *work in flight*, not merely an open queue |
| `load=<n>>=max_load=<m>` | `MAX_LOAD` | **derived**: `10#$_NCPU * 10`, where `_NCPU` is `sysctl -n hw.ncpu` / `nproc` / `getconf _NPROCESSORS_ONLN`, falling back to 4 — so 40 on an unprobeable host. If the derived value fails `is_limit`, it falls back to 40 | the plist may pin a different value |
| `lanes=<n>>=max_lanes=<m>` | `MAX_LANES` | 4 | |
| `swap_free=<n>M<=min_swap_free=<m>M` | `MIN_SWAP_FREE` | 600 | `swap_total=0` means swap is uninitialised (fresh boot), NOT pressure — allowed |
| `mem_probe_failed (capacity unknown -> do not add work)` | — | — | unreadable memory ⇒ refuse, never assume |
| `mem_avail=<n>M<=min_mem_free_mb=<m>M` | `MIN_MEM_FREE_MB` | 512 | |
| (reviewer budget, not a `[dispatch]` string) | `MAX_REVIEW` | 4 | `review_slots()` returns `MAX_REVIEW` normally and `10#MAX_REVIEW + 2` while `open > MERGE_PRIORITY_AT` — the `+2` headroom is real and read base-10 deliberately (a leading-zero value would otherwise be octal) |
| (fixer concurrency, not a `[dispatch]` string) | `MAX_FIX` | 3 | caps concurrent `fix-<PR>` sessions |
| fixer attempts | `MAX_FIX_TRIES` | 3 | at the cap → park at this head |
| dispatch batch | `BATCH` | 2 | issues per cycle |
| cycle | `CYC` | 240s | floored at 5; jittered ±20% so several boxes stop waking together |

Every one of these is coerced with `is_limit` (digits **and** at most nine of them) before its
first arithmetic read, because `[ -ge ]` on a non-number is FALSE and a false test in the gate
chain **opens** the gate. The wall-clock timeouts (`LANE_TIMEOUT`, `REVIEW_TIMEOUT`, `FIX_TIMEOUT`)
are separate and are documented in `README.md` §4.

**Why the same gate text can mean opposite things.** `mp_reason` fires only while at least one
agent is in flight, so a logged `merge-priority` block always has `lanes + workers >= 1`; a block
with `lanes=0 workers=0` cannot be produced by this rule. That is why the `workers=` counter is
logged beside the gate: without it, a block while the box is saturated and a block while it is idle
are indistinguishable in the log. `mp_reason`'s own comment records the measured case
(2026-10-13: the lanes-only form let dispatch through on 4/4 sampled blocks, `lanes=0 workers=8`).

---

## 6. Known sharp edges (verified against the code)

1. **`dispatched.txt` IS reaped — a dead lane alone does not strand an issue.**
   `refresh-candidates.sh` removes an entry when the issue is still open, no PR branch matches it,
   and no `lane-<N>` is live (`README.md` §7.1, agent-infra#1705 / tortoise#8519). The reaper refuses
   the whole pass if either `.open_iss` or `.pr_brs` is *absent*, so a failed listing cannot read as
   "no PRs" and un-blacklist a PR-bearing issue. The residual is `checked.txt`: a pre-flight that
   returns no verdict (or a COLLISION) writes no entry — so it re-attempts — but a persistent
   COLLISION can consume the whole refresh window (`README.md` §7.5, agent-infra#1729).

2. **`fixcount-<PR>` is not keyed on the head SHA.** `parked-<PR>`, `needsfix-<PR>-<head>` and
   `railcount-<PR>` all carry a head, and a push re-arms them; `fixcount` is a bare counter, so
   attempts accumulated at a superseded revision carry into the new head and can park it
   immediately. (`merged-*.done` and `rerun-*` are deliberately terminal/run-keyed, not head-keyed.)

3. **A verdict-less reviewer run is indistinguishable from `ISSUES` at the marker level.** The
   `*)` arm in `merge-one.sh` writes `needsfix-<PR>-<head>` for both, so a run killed at its cap
   causes the controller to spend a `MAX_FIX_TRIES` attempt and can produce a park caused by
   timeouts rather than findings. The `rc=143` row in `walltime.tsv` is the only *durable* place the
   distinction survives — the per-run `[timeout]` log line is erased when that log is re-truncated.

4. **`check-port-drift.sh` compares against a pin, not against reality.** It hashes the tortoise
   tree at a git ref against `port-provenance.txt`; a file in the pin that the ref no longer carries
   is reported as `pinned as ported, but <ref> no longer has it`, and a file in the ref that the pin
   does not list is reported as unpinned drift. Both are findings about the *pin*, so the fix is to
   port and re-pin (`--repin`), not to delete the source copy.

5. **A deployed box has no recorded identity.** `install.sh` copies loose `*.sh` files into `$O`
   and nothing writes a revision marker there, so "which commit is this box running?" cannot be
   answered from the box. (Deployment observation, not a line of this directory's code; named here
   because it is the first question when a fix "does not take" — see the sync note in
   `README.md` §9.)

6. **Never overwrite a running script.** `bash` reads a script incrementally, so overwriting
   `$O/<script>` while the controller is executing it can run a torn script. Unload the loop, copy,
   then load (or write to a temp file and `mv` atomically). A property of `bash`, not of the harness.

---

## 7. Triage

| Symptom | First place to look | Likely cause |
|---|---|---|
| queue not moving | `$O/logs/orch-loop.log` tail, then `$O/heartbeat` | controller dead or stuck; heartbeat age says which. Check `launchctl list \| grep orchestrator` — it may never have been launched by launchd at all |
| nothing dispatching | the `[dispatch] skipped (…)` line | a named gate: see §5. If it says `merge-priority`, more than `MERGE_PRIORITY_AT` PRs are open with at least one worker in flight |
| a worker produces nothing | `$O/state/walltime.tsv` (`rc`, `elapsed` vs `cap`) | hit the cap. Then find WHAT it was doing — the per-run log is truncated on rerun, so use `~/.pi/agent/audit/audit.jsonl`, which records every `tool_call` |
| PR red forever with no worker | `state/parked-<PR>` + `state/fixcount-<PR>` | parked at the attempt cap. The park stores a head, so a push re-arms it |
| issue never picked up | `grep <n> dispatched.txt` and `grep <n> checked.txt` | either still blacklisted (the reaper clears `dispatched.txt` once the issue has no PR and no live lane) or it never passed pre-flight (`$O/.refresh-blocked`, or a COLLISION) |
| two boxes on the same PR | `git ls-remote origin 'refs/claims/*'` | the claim should prevent it; if a claim is present with a dead owner it expires by lease |
| capture/counters look wrong | `state/walltime.tsv` vs the per-run log | the per-run log is truncated on every rerun — the series is authoritative |

---

## 8. Invariants an operator must not break

1. **Do not delete a drifted source copy** before the drift is ported — that deletes the only copy
   of the change (`check-port-drift.sh` exists to gate exactly this).
2. **Do not raise a gate without capacity.** Raising `MERGE_PRIORITY_AT` or `MAX_REVIEW` adds
   in-flight work; the reviewer headroom (`MAX_REVIEW + 2`) is what the drain mode relies on, and
   the box's real throttle is usually swap or available memory, not the load ceiling.
3. **Do not put a value in the plist you have not reloaded.** Env is read once, at process start.
4. **Do not treat a verdict-less run as a verdict.** `rc=143` is not `ISSUES`.
5. **Do not `pkill -f` with a pattern that could appear in a prompt.** Prompts are passed as argv
   elements (`"$(cat "$prompt")"`), so a pattern matching prompt *text* kills the worker. Kill by
   recorded pid.
