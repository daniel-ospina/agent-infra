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
  │               a head-bound record already at this head → `scripts/admin-merge.sh <PR>`, the
  │               repo's own rail, which posts its own head-bound evidence and merges.
  │               NO record at this head → the reviewer path above runs FIRST (#1825): the rail is
  │               the MERGE authority, not an exemption from the review one, and this repo's only
  │               required check (`pipeline-compliance` check (c)) accepts nothing but its record.
  │               `gh pr merge` is NEVER called here: it would land on the required checks alone
  │               and bypass the rail. Refused `RAIL_TRIES` (3) times at one head → PARK that head
  │               (state/parked-<PR> holds the head).
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
| `orch-loop.sh` | launchd (or `nohup`) | candidates.txt, dispatched.txt, checked.txt, `state/queue-state`, `gh` PR state | heartbeat, `.orch.lock`, `.batch`, `state/{claims-snapshot,last-open-n,sweep-etag,sweep-stamp,sweep-defer-until,parked-*,fixcount-*,rerun-*,argv-*}`, `.refresh.lock`/`.refresh-blocked`, log | a cycle that cannot list PRs must not read as "empty" — a FAILED listing is logged and the sweep is skipped, never treated as CLEAN. Its cycle line carries `queue=<state>` beside `backlog=`, so a refresh that could not READ the pool cannot be read as "nothing to do" (agent-infra#1931) |
| `refresh-candidates.sh` | orch-loop (backgrounded) | `gh` issues, `.open_iss`, `.pr_brs`, `state/collided` | candidates.txt (+`.pool`, `.pool-read`, `.pool-err`), checked.txt, `state/queue-state`, `state/collided`, **rewrites dispatched.txt (the reaper)**, the scout worktree | must never PREPEND; the backlog is FIFO so a later P0 joins at the BACK (bounded: refresh runs only while backlog < 6). A permanent provisioning failure exits 3 and writes `$O/.refresh-blocked`. The pool read is recorded as ONE of `EMPTY` / `READ(n)` / `PARTIAL(<tiers>)` / `UNREADABLE` — `EMPTY` only ever for a read that SUCCEEDED and listed nothing (agent-infra#1931). reads `state/collided`. Its per-pass budget is **slots filled**, not candidates touched: a candidate the pre-flight cannot MOVE (COLLISION/INCOMPLETE/degraded/no verdict) fills no slot, so the walk continues behind it up to `2 × LIMIT` pre-flight runs — a blocked head must not consume the whole window (agent-infra#1729) — AND bounded by the **REST core budget it can still afford**: below `CORE_RESERVE + one candidate` it judges fewer candidates (still completely, and naming the stop) or, if it can afford none, refuses TRANSIENTLY — always AFTER the `dispatched.txt` reaper, so a starved pass still un-blacklists an issue that is open with no PR, and never falls through to `checked 0; backlog now 0` (agent-infra#2022) |
| `dispatch-merge.sh` | orch-loop (argv issue ids) | argv issue ids, `git worktree list` | worktree, `lane-*` + `chain-*` tmux sessions | refuses non-numeric issue ids; a failed `worktree add` skips rather than half-dispatching |
| `lane.sh` | dispatch-merge (tmux) | issue body + comments | the worktree/branch/PR, `logs/prompt-<N>.txt`, walltime row (via `run_agent`) | the implementer; runs with local review gates bypassed because the PARENT owns the gate. Hard-requires `spawn-gate.sh` (exit 78 without it) |
| `chain-merge.sh` | dispatch-merge (tmux) | the lane's PR | merge-one run; exits with merge-one's status | waits (≤90 min) for the PR to exist before running the chain |
| `merge-one.sh` | chain-merge, orch-loop, fix-one | PR diff + head, `repo-authority.sh`, `claims.sh` | review comment, PR body marker, claim ref, `state/{mergeclaim-*,needsfix-*,parked-*,merged-*.done,railcount-*}`, walltime row | refuses to run at all if `repo-authority.sh` is missing or stale (fail-closed); the reviewer emits `CLEAN <url>` / `ISSUES <n>`, and **any non-CLEAN outcome (including a failed/timed-out reviewer) writes `needsfix-<PR>-<head>`** |
| `fix-one.sh` | orch-loop (tmux) | the reviewer's comment, `state/needsfix-*`, the failing check's log | a new commit on the branch, `state/fixbail-<PR>-<head>` (cross-box refusal), a **decrement** of `state/fixcount-<PR>` on load refusal, a fixer walltime row | the controller books the `MAX_FIX_TRIES` attempt at spawn; fix-one refunds it when no agent ran and re-runs merge-one on success |
| `repo-authority.sh` | **sourced** by orch-loop, merge-one | this repo's required status checks | the merge contract: `REQ`, `REQ_SOURCE`, `merge_authority` (gate/rail/unknown) | **fail-closed** — an unreadable, un-normalisable, or unrepresentable check set refuses rather than guessing |
| `spawn-gate.sh` | **sourced** by lane.sh and fix-one.sh **and EXECUTED as `pi`** (installed at `$HOME/.pi/agent/bin/pi`, first on PATH) | load / capacity, and the disk floor | the go/no-go for a `pi`, the walltime row, and `~/.pi/agent/state/spawn-gate.tsv` (one row per invocation, allowed runs included) | ⛔ **TWO MODES, ONE FILE (#1884).** Sourced, it is the helper the ported callers use; executed as `pi`, it is the SPAWN POINT, so a caller that sources nothing at all — a hand-written `tmux new-session … "pi -p …"` runner, which is exactly what started three lanes on a box at load 258 — is still refused, loudly (reading, ceiling, item, caller) and counted, with `PI_GATE_REFUSED=76` (translated to 75 + `AGENT_STARTED=0` by `run_agent`, and to `exit 75` with NO `needsfix` marker by `merge-one.sh`). `orch-loop.sh` still does not source it (it has its own `can_spawn`), and its `pi`-spawning paths now inherit the spawn-point gate. Limits are in the file's own header — above all the absolute-path/PATH-reset invocation, which is deliberately also the operator's rescue route |
| `claims.sh` | **sourced** by orch-loop, merge-one, fix-one | `refs/claims/*` | claim refs; `claim_snapshot` writes `state/claims-snapshot` | fail-open on an unreachable store (logs it); never fail-closed |
| `launchd-cycle.sh` | **sourced** by `install.sh` (+ the durability suite, with a `launchctl` stub first on `PATH`) | the rendered plist, `launchctl print`, `$O/heartbeat` | `$O/state/launchd-loaded.sha256` (via install.sh), the launchd job itself | the ONE implementation of stop/enable/(re)start/verify for this job. ⛔ Never writes a persistent disable (`bootout`/`enable`/`bootstrap`/plain `load` only), never mutates a job that was not loaded from this plist, and a start that cannot prove pid + new process + advanced heartbeat + no relaunch exits non-zero |
| `install.sh` | a human | env, `launchd.plist.template`, `launchd-cycle.sh` | the plist, `$O/state/launchd-loaded.sha256` (on a successful `--start`) | renders + lints + `mv`s the plist and **never mutates launchd on a plain run**; `--start`/`--restart` start the loop and PROVE it started, `--uninstall` removes it and reads the domain back. Prints the verified start/stop commands an operator copies. Warns on drift between the repo copy and `$O` for the scripts the daemon runs |
| `selftest.sh` | a human / CI | the shipped scripts | pass/fail | offline; drives the shipped code rather than grepping it |
| `check-port-drift.sh` | a human | `port-provenance.txt`, tortoise ref | pass/fail | gates the tortoise-side removal. **Compares against a PIN, so a stale pin reports work that has moved (see §6.4)** |
| `test-claims.sh` / `test-crossbox.sh` / `test-gates.sh` / `spawn-gate.test.sh` / `refresh-scout.test.sh` / `sweep-quota.test.sh` / `claim-exclusion.test.sh` / `install-launchd-durability.test.sh` | a human / CI | — | pass/fail | each pins one regression contract. `test-claims.sh` cannot prove cross-box atomicity on one machine; `claim-exclusion.test.sh` is the closest available — N processes raced at a barrier against a real `receive-pack` — and prints the per-operation exclusion table README §7.2d records. `install-launchd-durability.test.sh` is HERMETIC (a `launchctl` stub first on `PATH`, a throwaway `$HOME`/$O) and is a CI shard: it asserts the forbidden end state directly — "not running AND (a persistent disable written OR exit 0)" is a failure |

**Manual utility:** `adopt-fix.sh` — materialises a worktree for a foreign branch and runs
`fix-one.sh` against a specific PR by hand; exits with the fixer's status.

**Retired** (`retired/`): `auto-loop.sh`, `dispatch.sh`, `do-merge.sh`, `refix.sh`, `sweep.sh`,
`watch-one.sh`. Earlier iterations of the same idea, no longer invoked, kept for the record —
`README.md` §9 is the authority.

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
| `refs/claims/<PR>-<sha12>` (remote) | `claims.sh` | released by the EXIT trap (fenced); expired by lease; reaped by `claim_prune` (hourly, backgrounded, from the sweep — #1749) **and NOW ALSO when the holder is ORPHANED** (#2094: its host is a former name of this box, a local pid that is gone **— PR claims only**, because an ISSUE claim is minted by the controller and released by the chain so a restart must not free it — or a host on `CLAIM_DEAD_HOSTS`/absent from a `CLAIM_KNOWN_HOSTS` roster) | **cross-box** claim. Lease is DATA (`owner`, `lease_until`) because a remote pid cannot be probed — except on THIS box, where the local pid rule does probe (with a control probe, so a broken `ps` abstains). `owner` is `<host>:<pid>` re-derived on every call |
| `state/claim-hosts` | `claims.sh` (`claim_owner`) | never — append-only, one host name per line | the names THIS box has answered to. A claim stamped by one of them is **orphaned** (#2094): renaming a machine must not leave its own leases unreclaimable, and no roster ships to say so. ⛔ INVARIANT: this state dir is EXCLUSIVE TO ONE BOX — a name on this list is treated as DEAD, so a shared/mirrored `$HOME` or `$O` would let one machine's hostname orphan a peer's live claims. Recording never creates the dir (an absent state dir records nothing) and never uses a seam identity. ⛔ INVARIANT: `hostname -s` must be UNIQUE across the fleet — the local-pid rule treats an owner host equal to this box's own name as proof that the pid can be probed HERE, so two boxes sharing a short name each read the other's live worker pid as locally absent and reap its PR claim. Neither remedy on this page covers that case (no `claim-hosts` line is involved and the shared name is the CURRENT one): give a cloned cell image a unique hostname before it mints its first claim. ⛔ AND THE SELF-HEAL ASSUMES A FREED NAME IS NEVER REASSIGNED: a name on this list is treated as a name THIS MACHINE still owns, so if the old name is later handed to ANOTHER box, every claim THAT box mints under it reads as this box's own dead claim — for every keying — and, worse, the local-pid rule probes that foreign pid HERE, finds a local absence, and calls a LIVE remote worker's PR claim orphaned (the steal direction). The blast radius is self-limited only while the name is exclusive to this box. Remedy, once no outstanding claim can still carry it (after `CLAIM_TTL_MAX` / `CLAIM_ISSUE_TTL`): drop the name from this file — a recycled host name otherwise revives a fleet-wide reap |
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
| `~/.pi/agent/state/spawn-gate.tsv` | the SPAWN POINT — `spawn-gate.sh` executed as `pi` (#1884) | one-generation rotation at 5 MiB (`.1` kept) | one row per `pi` invocation, allowed AND refused: epoch, verdict, load, max_load, pid, ppid, KIND, TAG, cwd, caller. It lives under `$HOME` rather than `$O` because a hand-written runner is under no obligation to have `$O` set — and a series that records only refusals cannot answer "how close did we get" |
| `state/last-open-n` | `orch-loop.sh` | rewritten on each SUCCESSFUL open-PR count | the last good count; reused when a later count fails, so a failure never reads as 0 |
| `state/refresh-funnel` | `refresh-candidates.sh` (one atomic write per pass) | read by `orch-loop.sh`'s `dispatch_funnel()`, printed as `[dispatch] <listed> candidates -> <per-reason counts> -> <n> dispatched` | the per-pass DISPATCH FUNNEL: `listed`, `judged`, `queued`, `collision`, `landed`, `unjudged`, `skipped_checked`, `skipped_dispatched`, `not_reached`, `limit`, `reconciled`, `at`. The parts must reconcile with the pool and the judged split must sum to the number judged, and the writer says so when they do not — with the honest limit that `not_reached` is derived from the other counts, so the pool check catches OVER-counting (one row in two buckets, a verdict arm that counts nothing), not a row that was never counted (< 0 is floored, and an unusable pool count publishes `reconciled=0`). It exists because `[dispatch] backlog empty queue=READ(223)` was printed while 223 candidates had been read and every one was filtered away — a contradiction that hid a total dispatch stop for hours (agent-infra#2040). A missing file reads `UNRECORDED`, never as an empty funnel |
| `state/queue-state` | `refresh-candidates.sh` (one write per pass) | read by `orch-loop.sh`'s `queue_state_token()` (cycle line + the `[dispatch]` funnel line), printed with the AGE of the reading | what the last pool READ saw — `EMPTY` / `READ(<n>)` / `PARTIAL(<tiers>)` / `UNREADABLE`, plus the epoch of the read. `EMPTY` is reserved for a read that SUCCEEDED and listed nothing; absence of the file (or an unparseable one) reads `UNKNOWN`, never `EMPTY` — the absence of a measurement is not a measurement of emptiness (agent-infra#1931) |
| `state/collided` | `refresh-candidates.sh` (rewritten once per pass: fresh records carried over, expired dropped, this pass's collisions added) | each record lapses `POOL_COLLISION_TTL` (900 s) after it was written | `"<expiry-epoch> <issue>"` per line — candidates a peer was holding at the last pre-flight. A pass walks PAST a fresh record without spending a pre-flight run, so the same blocked head is not re-bought every pass; a skipped candidate stays unqueued and un-`checked`, so it is **deferred, never dropped** — when the record lapses it is judged again (agent-infra#1729). Only a COLLISION is recorded: a DEGRADED/INCOMPLETE/verdict-less answer is an environment failure and must stay visible every pass (#1736) |
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
| `merge-priority (<n> unowned of <m> open PRs in <repo> — PRs before issues)` | `MERGE_PRIORITY_AT` | 25 | **headroom only, not a gate**: the gate is threshold-free — `unowned > 0` closes the issue path (agent-infra#2099). This value only selects the drain posture (`MAX_REVIEW+2` / `MAX_FIX+2`)
| `DRAIN STALLED — no PR merged in <n>m while <k> un-owned remain …` | `MERGE_STALL_MIN` | 180 min | **display only.** Names a stalled drain; it releases nothing. The age-based RELEASE rows that used to follow (`state/merge-priority-blocked-since`, `state/merge-priority-released-until`, `MP_HELD`) were deleted in agent-infra#2099 and are pinned absent by `test-gates.sh` — an un-owned PR closes the issue path on its own, and "nothing landed" is a capacity problem, not a licence to open work
| `load=<n>>=max_load=<m>` | `MAX_LOAD` | **derived**: `10#$_NCPU * 10`, where `_NCPU` is `sysctl -n hw.ncpu` / `nproc` / `getconf _NPROCESSORS_ONLN`, falling back to 4 — so 40 on an unprobeable host. If the derived value fails `is_limit`, it falls back to 40 | the plist may pin a different value |
| `lanes=<n>>=max_lanes=<m>` | `MAX_LANES` | **derived**: `10#$_NCPU * 5 / 2` (2.5 × cores, floored — 25 on a 10-core box, 10 on a 4-core box or a failed probe; a derived value that fails `is_limit` falls back to 10) | the plist may pin a different value: a **valid** pin wins and is never recomputed; an **invalid** one is refused by `install.sh` and repaired by the loop to the derived default. Capacity is the ceiling, not a lane count: a flat 4 (and this box's pinned 8) closed this gate while the load/memory gates still had headroom |
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
| nothing dispatching | the `[dispatch]` funnel line, then the `[dispatch] skipped (…)` line | the funnel says WHERE the candidates went (`N candidates -> 0 queued, 6 unjudged (pre-flight), 213 not reached (limit) -> 0 dispatched`): nothing queued is a refresh/pre-flight problem, queued-but-zero-dispatched is a gate (see §5), and `held: …` names it. `held: merge-priority` means at least one **unowned** (nothing live is working it) PR is open — threshold-free (agent-infra#2099); the queue is held for the PR work, and `[dispatch] DRAIN STALLED` names a drain that is not landing, without releasing anything
| candidates read, nothing queued, `unjudged` ≈ `judged` | the `?#N INCOMPLETE from the pre-flight` lines, then `tools/fleet_state.py build` | the pre-flight could not JUDGE, which is not "no work". The claim gate needs the fleet board's liveness read; an unreadable board (e.g. `workspaces_measured: false`) makes every candidate INCOMPLETE and the refresh aborts — measured 2026-10-18 on all three cells |
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
