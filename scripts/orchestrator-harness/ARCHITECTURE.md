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
  │                           ones → candidates.txt (FIFO: its ORDER IS the dispatch priority, EXCEPT
  │                           that up to PRODUCT_FLOOR batch slots are taken from
  │                           candidates.product.txt first — always filtered by candidates.txt, so the
  │                           backlog stays the authority; agent-infra#2054. It YIELDS to an emergency:
  │                           a P0-blocker in the batch window, an un-parked red-tree rail refusal, or
  │                           an emergency class that could not be read)
  │
  ├─ orch-loop.sh dispatch   gates first (§5); merges then reads the floor's order (`$O/.order`, else
  │                           candidates.txt) top-down, skips dispatched.txt
  │                           dispatch-merge.sh <repo> <owner/repo> <issue...>
  │                             → `git worktree add .worktrees/tm-<N> -b feat/<N>-tm origin/main`
  │                             → `worker-terminal.sh`: a DURABLE TERMINAL (`wt-lane-<N>`,
  │                               `wt-chain-<N>`) on a cmux box, a tmux session only on macOS
  │
  ├─ lane.sh (lane-<N>)      pi -p in the worktree: implement → commit → push → open PR. The PR
  │                           body's `Closes #<N>` keyword (or `Refs #<N>` for partial work) is
  │                           what closes the issue. Before the first byte of work, the launcher
  │                           prints the reviewer requirement once and splices the reviewer step
  │                           into the brief (#2148) — the requirement is not discovered by being
  │                           refused at the rail. A gate refusal starts no agent and writes
  │                           `state/capacity-refused-<N>` (`<epoch>\t<yield_until>\t<load|disk>`).
  │
  ├─ chain-merge.sh (chain-<N>)
  │                           polls up to 90 min for a PR on the branch, then runs merge-one.sh
  │                           IN THIS SESSION and exits with merge-one.sh's status. ⛔ It exits AT
  │                           ONCE — with the gate's code (75 load / 77 disk), releasing the
  │                           cross-box issue claim through its EXIT trap — when `lane.sh` recorded
  │                           a capacity refusal for THIS dispatch, because no PR can ever appear:
  │                           waiting would hold `refs/claims/issue-<N>` and make the issue
  │                           ineligible on every other box (agent-infra#1909, R8).
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
| `orch-loop.sh` | launchd (or `nohup`) | candidates.txt, **`candidates.product.txt` / `candidates.emergency.txt` / `.order`** (the product floor and its emergency yield), dispatched.txt, checked.txt, `state/queue-state`, **`state/product-class` / `state/emergency-class`** (each repeated beside its `reason=`), **`state/railrefusal-*`** (a `red-tree` class is an emergency), `gh` PR state | heartbeat, `.orch.lock`, `.batch`, `state/{claims-snapshot,last-open-n,sweep-etag,sweep-stamp,sweep-defer-until,parked-*,fixcount-*,redfix-*,rerun-*,argv-*}`, `.refresh.lock`/`.refresh-blocked`, log | **the RED-FIXER role (#2223)**: a rail refusal that names a red tree spawns ONE `fix-<PR>` lane (head-keyed, capped, before the parked guard), and a new head drops the refusal so the head is re-railed. A cycle that cannot list PRs must not read as "empty" — a FAILED listing is logged and the sweep is skipped, never treated as CLEAN. Its cycle line carries `queue=<state>` beside `backlog=`, so a refresh that could not READ the pool cannot be read as "nothing to do" (agent-infra#1931) |
| `refresh-candidates.sh` | orch-loop (backgrounded) | `gh` issues, `.open_iss`, `.pr_brs`, `state/collided` | candidates.txt (+`.pool`, `.pool-read`, `.pool-err`), **`candidates.product.txt` / `candidates.harness.txt` / `candidates.emergency.txt`** (the product-floor split and its emergency class, DERIVED from candidates.txt at the end of the pass, never accumulated), checked.txt, `state/queue-state`, `state/collided`, **`state/product-class` / `state/emergency-class`** (each split's recorded reason), **rewrites dispatched.txt (the reaper)**, the scout worktree | must never PREPEND; the backlog is FIFO so a later P0 joins at the BACK (bounded: refresh runs only while backlog < 6). A permanent provisioning failure exits 3 and writes `$O/.refresh-blocked`. The pool read is recorded as ONE of `EMPTY` / `READ(n)` / `PARTIAL(<tiers>)` / `UNREADABLE` — `EMPTY` only ever for a read that SUCCEEDED and listed nothing (agent-infra#1931). reads `state/collided`. Its per-pass budget is **slots filled**, not candidates touched: a candidate the pre-flight cannot MOVE (COLLISION/INCOMPLETE/degraded/no verdict) fills no slot, so the walk continues behind it up to `2 × LIMIT` pre-flight runs — a blocked head must not consume the whole window (agent-infra#1729) — AND bounded by the **REST core budget it can still afford**: below `CORE_RESERVE + one candidate` it judges fewer candidates (still completely, and naming the stop) or, if it can afford none, refuses TRANSIENTLY — always AFTER the `dispatched.txt` reaper, so a starved pass still un-blacklists an issue that is open with no PR, and never falls through to `checked 0; backlog now 0` (agent-infra#2022) |
| `dispatch-merge.sh` | orch-loop (argv issue ids) | argv issue ids, `git worktree list` | worktree, `lane-*` + `chain-*` workers (a durable terminal, or a tmux session on macOS — see `worker-terminal.sh`) | refuses non-numeric issue ids; a failed `worktree add` skips rather than half-dispatching |
| `worker-terminal.sh` | **sourced** by `orch-loop.sh` and `dispatch-merge.sh` (both refuse to run without it) | `cmux tree --json`, `state/worker-*` records, `state/env-<name>.sh` | a daemon-owned terminal (`cmux layout apply` on a cell, `surface new-terminal` where the CLI has it) or a tmux session on macOS; `state/worker-<name>`, `state/run-<name>.sh`, `state/env-<name>.sh` | ⛔ **a Linux box with no cmux surface REFUSES (`wt_launcher=none`) rather than falling back to tmux** — a tmux window (or a `setsid` child of a transient exec) dies at ~21 log lines, measured on all three cells, so a silent fallback is the defect this file removes. The census is fail-CLOSED (an unreadable `cmux tree` counts its workers ALIVE, so a daemon in trouble cannot raise a cap), and `wt_close` returns non-zero and KEEPS the record unless it can prove the surface is gone |
| `lane.sh` | dispatch-merge (`wt_spawn`) | issue body + comments | the worktree/branch/PR, `logs/prompt-<N>.txt`, `state/capacity-refused-<N>` (only on a gate refusal), walltime row (via `run_agent`) | the implementer; runs with local review gates bypassed because the PARENT owns the gate. Hard-requires `spawn-gate.sh` (exit 78 without it) **and `reviewer-preflight.sh`** (exit 78 without it — a lane whose brief silently omits the reviewer step is the #2148 defect). Prints the reviewer requirement once, up front, before any work, and splices the reviewer section into `logs/prompt-<N>.txt`. `LANE_DRY_RUN=1` stops after both artifacts exist (the #2148 suite drives that seam; no agent starts). A gate refusal starts no agent and writes `state/capacity-refused-<N>` |
| `reviewer-preflight.sh` | **sourced** by `lane.sh` (and executable: `--line [self\|harness\|reviewer]` / `--brief [self\|harness]`) | nothing | the ONE reviewer-requirement disclosure and brief section: what must happen before the rail, and the exact `task` / `record-review.sh` / rail commands | the three audiences differ on purpose — `self` (a controller-written, self-landing lane: it dispatches, records at the current head, then runs the rail; its line also names the override for a launcher that exports no `KIND`), `harness` (a worker that pushes code: `merge-one.sh` mints the attestation, so the lane pushes its FINAL head and never merges) and `reviewer` (`merge-one.sh`'s own reviewer session: it owns the verdict comment and must not push, record or merge; it has no brief section because merge-one.sh composes that prompt). An unknown role is REFUSED (never a silent default that addresses the wrong audience). Its wording is drift-pinned against `extensions/shared/reviewer-preflight.ts` by `extensions/shared/reviewer-preflight.test.ts`, which RENDERS all three roles through this helper and compares the lines byte for byte (`reviewer-preflight.test.sh` §A pins the same constants in bash); `templates/LANE-BRIEF.md` carries the step for controller-written briefs. The disclosed record command carries `--evidence`, because a fresh `clean` record without it is refused (tortoise#7391) — a disclosure naming the invocation without it hands the lane a command that cannot work (agent-infra#2148) |
| `chain-merge.sh` | dispatch-merge (`wt_spawn`) | the lane's PR, `state/capacity-refused-<N>` (epoch-bounded to ITS dispatch, with ordering slack) | merge-one run; exits with merge-one's status, or with the gate's code (75/77) on a capacity refusal — releasing the issue claim either way | waits (≤90 min) for the PR to exist before running the chain. A refusal record attributable to this dispatch ends the wait immediately instead (agent-infra#1909); the bounds are `CAPACITY_REFUSAL_GRACE_SECS` (default 60 — `dispatch-merge.sh` spawns the LANE first, so the record is normally marginally OLDER than this chain's start) capped by the record's own `until - epoch` — **strictly** shorter than it, `min(slack, win-1)`, because a slack equal to the record's own stand-down would admit the previous dispatch's record at the first second this box may re-dispatch (see README §7.2d) — so a genuinely stale record still cannot end a live lane's wait. A record that is present but not admitted is logged ONCE, so a discarded refusal does not read as a slow lane |
| `merge-one.sh` | chain-merge, orch-loop, fix-one | PR diff + head, `repo-authority.sh`, `claims.sh` | review comment, PR body marker, claim ref, `state/{mergeclaim-*,needsfix-*,parked-*,merged-*.done,railcount-*,railrefusal-*}`, walltime row | refuses to run at all if `repo-authority.sh` is missing or stale (fail-closed); the reviewer emits `CLEAN <url>` / `ISSUES <n>`, and **any non-CLEAN outcome (including a failed/timed-out reviewer) writes `needsfix-<PR>-<head>`** |
| `fix-one.sh` | orch-loop (`wt_spawn`) | the reviewer's comment, `state/needsfix-*`, the failing check's log | a new commit on the branch, `state/fixbail-<PR>-<head>` (cross-box refusal), a **decrement** of `state/fixcount-<PR>` on load refusal, a fixer walltime row | the controller books the `MAX_FIX_TRIES` attempt at spawn; fix-one refunds it when no agent ran and re-runs merge-one on success |
| `rail-refusal.sh` | **sourced** by `merge-one.sh`, `cloud-cell-doctor.sh` (writers) and `orch-loop.sh` (reader) | the rail attempt's own output, the environment the rail ran in | `state/railrefusal-<PR>` — the refusal's **class** (`red-tree`/`override`/`conflict`/`unreadable`/`other`), head, attempt ordinal, and the refusal line **verbatim** | **the ONE classifier** of a rail refusal (agent-infra#2223). It decides whether a fixer lane is spawned, so a second classifier would let two readers of one fact disagree (#1872's shape); a text it has never seen classes as `other`, which spawns nothing (allow-list polarity). Missing/stale is NOT fatal — the writers say loudly that the refusal went unrecorded, because a silent no-op would recreate the stall it exists to end |
| `repo-authority.sh` | **sourced** by orch-loop, merge-one | this repo's required status checks | the merge contract: `REQ`, `REQ_SOURCE`, `merge_authority` (gate/rail/unknown) | **fail-closed** — an unreadable, un-normalisable, or unrepresentable check set refuses rather than guessing |
| `spawn-gate.sh` | **sourced** by lane.sh and fix-one.sh **and EXECUTED as `pi`** (installed at `$HOME/.pi/agent/bin/pi`, first on PATH) | load / capacity, and the disk floor | the go/no-go for a `pi`, the walltime row, and `~/.pi/agent/state/spawn-gate.tsv` (one row per invocation, allowed runs included) | ⛔ **TWO MODES, ONE FILE (#1884).** Sourced, it is the helper the ported callers use; executed as `pi`, it is the SPAWN POINT, so a caller that sources nothing at all — a hand-written `tmux new-session … "pi -p …"` runner, which is exactly what started three lanes on a box at load 258 — is still refused, loudly (reading, ceiling, item, caller) and counted, with `PI_GATE_REFUSED=76` (translated to 75 + `AGENT_STARTED=0` by `run_agent`, and to `exit 75` with NO `needsfix` marker by `merge-one.sh`). `orch-loop.sh` still does not source it (it has its own `can_spawn`), and its `pi`-spawning paths now inherit the spawn-point gate. Limits are in the file's own header — above all the absolute-path/PATH-reset invocation, which is deliberately also the operator's rescue route |
| `claims.sh` | **sourced** by orch-loop, merge-one, fix-one | `refs/claims/*` | claim refs; `claim_snapshot` writes `state/claims-snapshot` | fail-open on an unreachable store (logs it); never fail-closed |
| `launchd-cycle.sh` | **sourced** by `install.sh` (+ the durability suite, with a `launchctl` stub first on `PATH`) | the rendered plist, `launchctl print`, `$O/heartbeat` | `$O/state/launchd-loaded.sha256` (via install.sh), the launchd job itself | the ONE implementation of stop/enable/(re)start/verify for this job. ⛔ Never writes a persistent disable (`bootout`/`enable`/`bootstrap`/plain `load` only), never mutates a job that was not loaded from this plist, and a start that cannot prove pid + new process + advanced heartbeat + no relaunch exits non-zero |
| `install.sh` | a human | env, `launchd.plist.template`, `launchd-cycle.sh` | the plist, `$O/state/launchd-loaded.sha256` (on a successful `--start`) | renders + lints + `mv`s the plist and **never mutates launchd on a plain run**; `--start`/`--restart` start the loop and PROVE it started, `--uninstall` removes it and reads the domain back. Prints the verified start/stop commands an operator copies. Warns on drift between the repo copy and `$O` for the scripts the daemon runs |
| `deploy-harness.sh` | a human (§4.1; the documented `bg/finish.sh` call site) | the SOURCE harness tree, `$O` (read-only checks), `$O/.agent-infra-stamp.json` | `$O` (the deployed bytes), `$O/.deploy-ledger.tsv`, one notification via `$O/bg/notify.sh` | refuses (`78`, nothing written) on: absent/non-harness source, any of the five identity anchors missing, an unreadable inventory, a source symlink, a SYMLINKED DIRECTORY on the deploy path under `$O` (writing through it would land bytes outside the runtime — review P2), source/target overlap, an empty source. `1` = a copy or verification actually failed (including a target FILE that is a symlink, refused per file). It never counts files from the target and never claims a restart |
| `deploy-harness.test.sh` | a human / CI | — | pass/fail | the #2041 contract; hermetic, a CI shard. Pins the measured false PASS (absent source + a 30-file target), a truncated inventory, a stale-but-real harness, symlinks (a source link, a target leaf link, and a symlinked PARENT directory — including a link that is an intermediate, not the deepest, component), a self-deploy **and a target nested inside the source** (both arms of the overlap test, refused for the named reason), the documented call shape (including that an ambient `HARNESS_SRC` cannot pick the source), that `install.sh`'s redeploy remedy names this helper rather than a bare `cp *.sh`, and that the payload fold agrees with `install.sh`'s own `prov_payload_hash` **driven from install.sh** rather than a copy of it |
| `selftest.sh` | a human / CI | the shipped scripts | pass/fail | offline; drives the shipped code rather than grepping it |
| `check-port-drift.sh` | a human | `port-provenance.txt`, tortoise ref | pass/fail | gates the tortoise-side removal. **Compares against a PIN, so a stale pin reports work that has moved (see §6.4)** |
| `test-claims.sh` / `test-crossbox.sh` / `test-gates.sh` / `spawn-gate.test.sh` / `refresh-scout.test.sh` / `sweep-quota.test.sh` / `claim-exclusion.test.sh` / `install-launchd-durability.test.sh` / `capacity-transfer.test.sh` | a human / CI | — | pass/fail | each pins one regression contract. `test-claims.sh` cannot prove cross-box atomicity on one machine; `claim-exclusion.test.sh` is the closest available — N processes raced at a barrier against a real `receive-pack` — and prints the per-operation exclusion table README §7.2d records. `install-launchd-durability.test.sh` is HERMETIC (a `launchctl` stub first on `PATH`, a throwaway `$HOME`/$O) and is a CI shard: it asserts the forbidden end state directly — "not running AND (a persistent disable written OR exit 0)" is a failure. `capacity-transfer.test.sh` drives the shipped `lane.sh`/`chain-merge.sh` and releases a REAL claim against a LOCAL bare repo |

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
| `refs/claims/<PR>-<sha12>` (remote) | `claims.sh` | released by the EXIT trap (fenced); expired by lease; reaped by `claim_prune` (hourly, backgrounded, from the sweep — #1749) **and NOW ALSO when the holder is ORPHANED** (#2094: its host is a former name of this box, a local pid that is gone **— PR claims only**, because an ISSUE claim is minted by the controller and released by the chain so a restart must not free it — or a host on `CLAIM_DEAD_HOSTS`/absent from a `CLAIM_KNOWN_HOSTS` roster) | **cross-box** claim. Lease is DATA (`owner`, `lease_until`) because a remote pid cannot be probed — except on THIS box, where the local pid rule does probe (with a control probe, so a broken `ps` abstains). `owner` is `<host>:<pid>` re-derived on every call |
| `state/claim-hosts` | `claims.sh` (`claim_owner`) | never — append-only, one host name per line | the names THIS box has answered to. A claim stamped by one of them is **orphaned** (#2094): renaming a machine must not leave its own leases unreclaimable, and no roster ships to say so. ⛔ INVARIANT: this state dir is EXCLUSIVE TO ONE BOX — a name on this list is treated as DEAD, so a shared/mirrored `$HOME` or `$O` would let one machine's hostname orphan a peer's live claims. Recording never creates the dir (an absent state dir records nothing) and never uses a seam identity. ⛔ INVARIANT: `hostname -s` must be UNIQUE across the fleet — the local-pid rule treats an owner host equal to this box's own name as proof that the pid can be probed HERE, so two boxes sharing a short name each read the other's live worker pid as locally absent and reap its PR claim. Neither remedy on this page covers that case (no `claim-hosts` line is involved and the shared name is the CURRENT one): give a cloned cell image a unique hostname before it mints its first claim. ⛔ AND THE SELF-HEAL ASSUMES A FREED NAME IS NEVER REASSIGNED: a name on this list is treated as a name THIS MACHINE still owns, so if the old name is later handed to ANOTHER box, every claim THAT box mints under it reads as this box's own dead claim — for every keying — and, worse, the local-pid rule probes that foreign pid HERE, finds a local absence, and calls a LIVE remote worker's PR claim orphaned (the steal direction). The blast radius is self-limited only while the name is exclusive to this box. Remedy, once no outstanding claim can still carry it (after `CLAIM_TTL_MAX` / `CLAIM_ISSUE_TTL`): drop the name from this file — a recycled host name otherwise revives a fleet-wide reap |
| `state/needsfix-<PR>-<head>` | `merge-one.sh` (any non-CLEAN outcome) | deleted when a fixer is spawned; re-created at a new head; re-touched by `refund_bailed_fixer` | "the reviewer found real issues, failed, or timed out AT THIS HEAD" |
| `state/fixbail-<PR>-<head>` | `fix-one.sh` (cross-box CAS refusal) | consumed by `refund_bailed_fixer` (rm) | "a fixer was refused this head by another box" — proof no work happened, so the attempt is refunded |
| `state/fixcount-<PR>` | `orch-loop.sh` (booked at spawn) | decremented by `fix-one.sh` (load refusal) and `refund_bailed_fixer`. **Not head-keyed** (⚠ see §6.2) | fixer attempts consumed for this PR |
| `state/railcount-<PR>` | `merge-one.sh` (rail mode) | reset when the stored head ≠ the current head | `"<head> <n>"` — rail refusals at this head, capped by `RAIL_TRIES` (3) |
| `state/railrefusal-<PR>` | `merge-one.sh` (rail mode, every ingress), `cloud-cell-doctor.sh` (its `merge` role) | replaced by the next refusal at a new head; `rail_refusal_clear` on a merge; `orch-loop.sh` drops it when the stored head ≠ the current head, which is what RE-ARMS the PR | the rail's last refusal for this PR: `head=`, `attempt=` (the writer's rail attempt for that head; the reader does not depend on it), `override=`, `class=`, `reason=` (VERBATIM) and `detail=`. The class decides whether the sweep spawns a red-fixer — only `red-tree` does |
| `state/fixgate-<PR>-<head>` | `fix-one.sh` (a controller-spawned fixer whose agent the load/disk gate refused) | consumed by the red-fixer role (refunds the per-head attempt); also reclaimed on a merge/close | "a fixer was dispatched for this head and NO agent ran". A gate refusal is not an attempt, and a disk refusal never clears by waiting — without this marker two refusals reach `MAX_RED_FIX_TRIES` and park a red PR with a reason that claims a fixer tried |
| `state/redfix-<PR>` | `orch-loop.sh` (red-fixer role) | reset when the stored head ≠ the current head; removed with the refusal | `"<head> <n>"` — red-fixer attempts at THIS head, capped by `MAX_RED_FIX_TRIES` (2). Head-keyed by construction, so a fixer's push buys a fresh budget (the `fixcount-<PR>` residual in §6.2 is deliberately not inherited) |
| `state/parked-<PR>` | `orch-loop.sh`, `merge-one.sh` | a later push re-arms it (the stored head stops matching) | needs a human; the loop skips the PR while parked at this head |
| `state/merged-<PR>.done` | `merge-one.sh` | never | merge completed |
| `state/rerun-<PR>-<runid>` | `orch-loop.sh` | never | a failed CI run was already re-triggered; stops a rerun storm |
| `candidates.txt` (`$O/`, not `state/`) | `refresh-candidates.sh` (append + dedupe) | consumed by dispatch; pruned by `orch-loop.sh` (drops ids already in `dispatched.txt`); rewritten atomically (`mv`) | the dispatch backlog. **FIFO — order IS priority**, qualified by the product floor below: up to `PRODUCT_FLOOR` slots of a batch are filled from `candidates.product.txt` first, so the head of a batch can be a LOWER-tier product issue while the backlog order still governs everything else (agent-infra#2054) |
| `candidates.product.txt` / `candidates.harness.txt` (`$O/`) | `refresh-candidates.sh` (`write_product_queues`, ONCE per pass) | `orch-loop.sh` reads the product queue for the floor, and only ever reads numbers that are ALSO in `candidates.txt` | the product-floor split. `product` = a `PRODUCT_REPOS` issue (default `daniel-ospina/tortoise`) WITHOUT the `harness` label; `harness` = everything else, including every agent-infra issue. ⛔ A FAILED `--label harness` listing classifies EVERY candidate as harness, so the product queue is empty and the floor reports itself unmet — never a product candidate invented from a read that did not answer. Both files are DERIVED from `candidates.txt` at the end of the pass, so a stale entry cannot resurrect work |
| `state/product-class` | `refresh-candidates.sh` (`write_product_queues`: invalidated to `PENDING` as its first action, then overwritten by every arm) | `orch-loop.sh`'s unmet-floor block, which repeats it verbatim beside `reason=` | WHICH arm classified the batch and what it measured: `NOT-A-PRODUCT-REPO …` / `BUDGET-SKIPPED …` / `LISTING-FAILED …` / `LISTING-TRUNCATED …` / `WRITE-FAILED …` / `OK product=<n> harness=<m>`, and `PENDING …` for a pass that has not split yet. It exists so the dispatch line never prints a QUESTION the refresh already answered, and so a MEASURED-empty queue (`OK product=0`) is distinguishable from an UNREAD one (`UNKNOWN`) — a routine case printed in the same words as a real failure is how the real failure stops being read. `PENDING` is reported as an UNKNOWN class, never as a measurement. ⛔ Only the writer invalidates the record: a pass that refuses or SKIPS before reaching it leaves the previous record standing, because neither queue file changed — that is a true description, not a stale flag (agent-infra#2054) |
| `candidates.emergency.txt` | `refresh-candidates.sh` (`write_emergency_queue`) | `floor_emergency` | the `P0-blocker` candidates, by their own label, intersected with `candidates.txt` in backlog order — the rows the floor must never displace. Created (possibly empty) by a completed read, REMOVED by every arm that could not classify, so ABSENT means UNKNOWN rather than empty |
| `state/emergency-class` | `refresh-candidates.sh` (`write_emergency_queue`; `OK p0=<n>` / `NOT-A-PRODUCT-REPO …` / `UNKNOWN-…`) | `orch-loop.sh` (`floor_emergency`) | why the emergency class is what it is; `floor_emergency` cross-checks an `OK` record against the queue's own line count and treats a mismatch — or an absent queue — as UNKNOWN. ⛔ THE OPPOSITE POLARITY FROM `state/product-class`: an unreadable PRODUCT class under-claims (nothing unclassifiable may satisfy the floor), while an unreadable EMERGENCY class stands the floor DOWN (`p0-unknown`), because "no P0 could be read" is not "there is no P0" |
| `.order` (`$O/`) | `orch-loop.sh` (`floor_choose_order`) | the dispatch loop's ONLY input when the floor applies (`done < "$ORDER_FILE"`) | the batch order: up to `PRODUCT_FLOOR` product candidates in their own order, then the merged backlog with those removed. Removed when the floor cannot produce an order (disabled, absent or unreadable product queue, or an EMERGENCY standing it down — the queue is read exactly as before), so a reader never finds an authoritative-looking stale file |
| `dispatched.txt` (`$O/`) | `orch-loop.sh` (append) | **reaped by `refresh-candidates.sh`** — an entry is removed when the issue is still open, no PR branch matches it, and no `lane-<N>` is live (agent-infra#1705 / tortoise#8519) | issues already dispatched |
| `checked.txt` (`$O/`) | `refresh-candidates.sh` (on the terminal CLEAN verdict only) | dropped for a reaped issue, so pre-flight re-queues it | issues already pre-flighted |
| `state/claims-snapshot` | `orch-loop.sh` (one `claim_snapshot` per cycle) | rewritten each cycle | all live claims, so `claim_live()` pays no per-PR network call |
| `state/capacity-refused-<N>` | `lane.sh` (gate refusal only; cleared when a lane actually runs) | **read** by `chain-merge.sh` (field 1 vs its own start minus the ordering slack, capped STRICTLY below the record's own window) and `orch-loop.sh`'s `capacity_yield_live()` (fields 1+2, coherent pair, vs now) | one line, `<refused_epoch>\t<yield_until>\t<load|disk>`. The transfer decision: the chain stops waiting and releases the claim, and the controller leaves the issue UNCONSUMED for a peer until the yield expires (agent-infra#1909, R8). The two readers consume DIFFERENT fields — the chain reports field 3 as the remedy (75/77, unknown → load) and never reads field 2; the controller requires a coherent `epoch < until` and never reads field 3 — which is what makes a corrupt byte fail OPEN in both. The yield is gate-independent (a `disk` refusal gets the same window as a `load` one) |
| `state/walltime.tsv` | `spawn-gate.sh`'s `run_agent` (lane, fix-one) **and** `merge-one.sh`'s own `run_agent` | never — **append-only** | one row per agent invocation: epoch, kind, tag, cap, elapsed, rc. The per-PR logs are truncated on rerun, so this is the only durable series |
| `~/.pi/agent/state/spawn-gate.tsv` | the SPAWN POINT — `spawn-gate.sh` executed as `pi` (#1884) | one-generation rotation at 5 MiB (`.1` kept) | one row per `pi` invocation, allowed AND refused: epoch, verdict, load, max_load, pid, ppid, KIND, TAG, cwd, caller. It lives under `$HOME` rather than `$O` because a hand-written runner is under no obligation to have `$O` set — and a series that records only refusals cannot answer "how close did we get" |
| `state/last-open-n` | `orch-loop.sh` | rewritten on each SUCCESSFUL open-PR count | the last good count; reused when a later count fails, so a failure never reads as 0 |
| `state/refresh-funnel` | `refresh-candidates.sh` (one atomic write per pass) | read by `orch-loop.sh`'s `dispatch_funnel()`, printed as `[dispatch] <listed> candidates -> <per-reason counts> -> <n> dispatched` | the per-pass DISPATCH FUNNEL: `listed`, `judged`, `queued`, `collision`, `landed`, `unjudged`, `skipped_checked`, `skipped_dispatched`, `skipped_landed`, `skipped_collided`, `not_reached`, `limit`, `reconciled`, `at`. (`skipped_landed` is part of the sum — a reader built without it prints parts that fall short of `listed` while `reconciled=1` claims they add up.) ⛔ EVERY WAY A ROW LEAVES THE FUNNEL WITHOUT BEING JUDGED HAS ITS OWN COUNTER (review finding P2-1): `not_reached` is DERIVED from the skip buckets, so an uncounted walk-past arm does not merely go missing — it INFLATES `not_reached`, which the dispatch line renders as `N not reached (limit)`, the one reading that tells an operator to raise `LIMIT`. The collision-ledger walk-past is therefore `skipped_collided`, and a record written before that key omits the part entirely (no invented zero). The parts must reconcile with the pool and the judged split must sum to the number judged, and the writer says so when they do not — with the honest limit that `not_reached` is derived from the other counts, so the pool check catches OVER-counting (one row in two buckets, a verdict arm that counts nothing), not a row that was never counted (< 0 is floored, and an unusable pool count publishes `reconciled=0`). It exists because `[dispatch] backlog empty queue=READ(223)` was printed while 223 candidates had been read and every one was filtered away — a contradiction that hid a total dispatch stop for hours (agent-infra#2040). A missing file reads `UNRECORDED`, never as an empty funnel. Since #1909 the line ALSO carries `yields=<n>` — candidates stood down by the capacity transfer — as an ADDITIVE note measured by the loop itself, never as one of the reconciled buckets, so a yielded backlog cannot read as stillness and cannot make an unreconciled funnel look summed |
| `state/queue-state` | `refresh-candidates.sh` (one write per pass) | read by `orch-loop.sh`'s `queue_state_token()` (cycle line + the `[dispatch]` funnel line), printed with the AGE of the reading | what the last pool READ saw — `EMPTY` / `READ(<n>)` / `PARTIAL(<tiers>)` / `UNREADABLE`, plus the epoch of the read. `EMPTY` is reserved for a read that SUCCEEDED and listed nothing; absence of the file (or an unparseable one) reads `UNKNOWN`, never `EMPTY` — the absence of a measurement is not a measurement of emptiness (agent-infra#1931) |
| `state/collided` | `refresh-candidates.sh` (rewritten once per pass: fresh records carried over, expired dropped, this pass's collisions added) | each record lapses `POOL_COLLISION_TTL` (900 s) after it was written | `"<expiry-epoch> <issue>"` per line — candidates a peer was holding at the last pre-flight. A pass walks PAST a fresh record without spending a pre-flight run, so the same blocked head is not re-bought every pass; a skipped candidate stays unqueued and un-`checked`, so it is **deferred, never dropped** — when the record lapses it is judged again (agent-infra#1729). Only a COLLISION is recorded: a DEGRADED/INCOMPLETE/verdict-less answer is an environment failure and must stay visible every pass (#1736) |
| `heartbeat` (`$O/`) | `orch-loop.sh` | overwritten each cycle | liveness: age > a few cycles means the controller is stuck or dead |
| `state/cycles` | `orch-loop.sh` (ONE append per cycle via `cycle-record.sh`) | never — **append-only**; `bin/harness status` reads the newest line and grades it | the SELF-DISPATCH PROOF: `start= end= cycle= interval= selected= selected_n= dispatched= ids= nothing= placement= placed_on= bound= lpc_self=`. It answers "is the controller cycling, what did it pick, what did it dispatch, and — when nothing — why" without a human reading a pane. **The verdict is the newest record's AGE, never a count**: `HEALTHY` (younger than TWO of the box's own cycles) / `DEGRADED` (older — rc 1) / `ABSENT` (no record — rc 2, and never "nothing to do") / `UNREADABLE` (rc 2). Measured 2026-10-21: cell-1's controller log was 37h stale and two cells had no log at its expected path, so "the controller is looping" was UNPROVEN — `heartbeat` above is a mtime, this is a record of what happened |
| `refs/boxes/<host>/<reading>` (the shared origin) | `capacity.sh`'s `cap_publish` — one ref per box per cycle, pruned host-scoped | read by `cap_read_fleet` with ONE `git ls-remote --refs refs/boxes/*` per cycle | the fleet's MEASURED capacity: `host ncpu load1 lpc lanes disk_free_mb mem_free_mb at`, encoded in the ref name (no fetch per box). The same channel and read primitive `claims.sh` uses. A box with no fresh record is **INELIGIBLE** to placement — an unreadable box never takes work, and if no box is eligible the dispatch is REFUSED with the bound it hit (see `docs/ops/fleet-capacity.md`) |
| `state/refresh-last` | `refresh-candidates.sh` (the `result=running` TOMBSTONE at entry, then the real outcome at most once; an exit no path converted is recorded as a FAILURE by its `EXIT` trap, rc=0 included) | read by `orch-loop.sh`'s origination block, once per cycle, as ONE snapshot | the refresh's OWN outcome: `result=ok|fail|running`, `stage=` (`startup|provision|list|persist|preflight|budget|judge|skip|handoff`), `rc=`, `at=`, `repo=`, `why=`, `cmd=` (the command that failed), plus `judged=`, `queued=`, `backlog=`, `handed=` and `unusable=`. It exists because the pass is **backgrounded**: its failure is one append-only log line, so the beat could not distinguish "a PR queue outranks issue work" (the ruling) from "origination can never start" (a broken box) and printed `[dispatch] skipped (merge-priority …)` for both (agent-infra#2229). The invariant the caller enforces is the PREFIX: `skipped (` **iff** a pass succeeded AND a usable candidate is deferred; `deferred (` when a candidate is queued but origination is unproven (a pass in flight, or no record yet); `nothing to defer` for a healthy pass with a drained queue (printing the pass's own `queued=`/`handed=`, never inferring from the empty queue); `BLOCKED: refresh failed — stage=<stage>: <why>` for a failed pass; `BLOCKED: … UNREADABLE (result=<what it read>)` for a record whose verdict this reader does not know (stale evidence is not a healthy pass — the #1736 direction); and `BLOCKED: no refresh pass has completed` for no record + an empty queue (with no evidence, "no work" and "origination never ran" are the same absence). The tombstone is what makes the last two honest: a killed pass cannot leave a previous `ok` behind. `result=running` is then read by AGE against the same bound the controller uses for the same pass (the 20 min stale-lock guard): a younger marker is a pass IN FLIGHT (`deferred (` with a queued candidate, `nothing to defer` with an empty queue — never `BLOCKED`, because the refresh only runs while the backlog is short, so an in-flight marker is the ordinary state on a short queue), and a marker past that bound is a pass that DIED (`BLOCKED`), as is a marker whose `at=` is unreadable (an unreadable stamp is not a fresh one). If `$O/state` is unwritable the record cannot be written at all, so the pass drops `$O/.refresh-unrecorded` (it has already proved it can write `$O`) and the reader treats that marker's PRESENCE as a failed pass regardless of what the stale record says — a record that cannot be stored is then a BLOCKED beat instead of a false green one. The pass also ENDS by naming the candidate it handed over, or `NONE` with the reason it judged nothing (`skip` for #1984's unchanged-input pass) |

The full list of every file under `$O/` (including `.orch.lock`, the sweep-cache files, and the
per-worker logs) is in `README.md` §2.

---

## 5. Gates — what the loop refuses to do, and the constant that decides it

Every gate names itself in the log as the REASON inside the `[dispatch]` gate line — `skipped (<reason>)` when origination is healthy, `deferred (<reason>)` / `nothing to defer (<reason>)` when origination is unproven, and `BLOCKED: … (<reason>)` when it is broken (agent-infra#2229, README §7.2) — so a gate constant below is grep-able in every one of those renderings. Constants are read from the
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
| `mem_avail=<n>M<=min_mem_free_mb=<m>M` | `MIN_MEM_FREE_MB` | 512 | the SAME constant and the same plain boundary bound the controller's spawn gate since agent-infra#1732: `can_spawn()` ANDs `mem_spawn_ok()` (`mem_avail <= MIN_MEM_FREE_MB`, or an UNKNOWN probe ⇒ no spawn), so the two gates cannot disagree about the `mem_avail` reading ITSELF. ⚠️ The `[cap]` gate has arms the spawn gate does not (`lanes=`, `swap_free=`, and the swap-joint `mem_avail <= 2*MIN_MEM_FREE_MB` above, which arms only when swap is ALSO tight): in that band a dispatch is refused while the spawn sites proceed — different populations, deliberately |
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
| nothing dispatching | the `[dispatch]` funnel line, then the `[dispatch]` GATE line (one of `skipped (…)`, `deferred (…)`, `nothing to defer (…)` or `BLOCKED: …` — agent-infra#2229; the table in README §7.2 is the reading guide) | the funnel says WHERE the candidates went (`N candidates -> 0 queued, 6 unjudged (pre-flight), 213 not reached (limit) -> 0 dispatched`): nothing queued is a refresh/pre-flight problem, queued-but-zero-dispatched is a gate (see §5), and `held: …` names it. ⛔ **If the line reads `BLOCKED: refresh failed —` the issue path is not deferred, it is BROKEN** (agent-infra#2229): read `state/refresh-last` (stage + why + the surface the pre-flight reported) and the pass's own `[refresh] FAILED stage=…` line. `BLOCKED: no refresh pass has completed` means no pass has EVER recorded an outcome on this box; `BLOCKED: … UNREADABLE (result=…)` means the record's verdict is not one this reader knows (it names what it read), and a stale record is not a healthy pass; `BLOCKED: a refresh pass wrote its start marker … stale bound` (or `… left a start marker that cannot be aged — <the real cause: clock unreadable / a FUTURE at= / a missing at=>`) means a pass started and never finished, past the 20 min bound the stale-`.refresh.lock` guard uses — the same number, so the beat and the controller cannot disagree; and `BLOCKED: a refresh pass finished and could not record its outcome (stage=… rc=… why=…)` means `state/` was unwritable, so `$O/.refresh-unrecorded` is the only record of that pass — `rc=0` there is a SUCCESS whose write failed. `skipped (` is printed **iff** a pass SUCCEEDED and a usable candidate is deferred; `deferred (` means a candidate is queued but origination is UNPROVEN (a pass is in flight, or no outcome is on record) — so "the beat says merge-priority" is evidence about the gate, never about origination. ⛔ Read `peer-held (ledger skip)` BEFORE `not reached (limit)`: a candidate the collision ledger already records as peer-held is walked past at no network cost and is counted in its OWN part, so `not reached (limit)` is the remainder — a large `peer-held` part is peer work in flight, not a `LIMIT` set too small (review finding P2-1). `held: merge-priority` means at least one **unowned** (nothing live is working it) PR is open — threshold-free (agent-infra#2099); the queue is held for the PR work, and `[dispatch] DRAIN STALLED` names a drain that is not landing, without releasing anything
| candidates read, nothing queued, `unjudged` ≈ `judged` | the `?#N INCOMPLETE from the pre-flight` lines, then `tools/fleet_state.py build` | the pre-flight could not JUDGE, which is not "no work". The claim gate needs the fleet board's liveness read; an unreadable board (e.g. `workspaces_measured: false`) makes every candidate INCOMPLETE and the refresh aborts — measured 2026-10-18 on all three cells |
| a worker produces nothing | `$O/state/walltime.tsv` (`rc`, `elapsed` vs `cap`) | hit the cap. Then find WHAT it was doing — the per-run log is truncated on rerun, so use `~/.pi/agent/audit/audit.jsonl`, which records every `tool_call` |
| an issue is open, free and NOT dispatching, while a box sits idle | `[dispatch] #N yielded to peers` in `$O/logs/orch-loop.log`, then `state/capacity-refused-<N>` | this box refused it at a gate and is standing down for the yield window, so a PEER is expected to claim it (`claim_issue_preflight` reads CLEAN once `refs/claims/issue-<N>` is released). If no box takes it, the yield has expired and the item is an ordinary candidate again — check the peer's `[dispatch]` line |
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
