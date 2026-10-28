---
title: "The self-healing contract — every harness capability, and how a caller tells ALIVE from REFUSING from IDLE"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-10-24
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-2700, orchestrator-harness, fleet
---

# The self-healing contract

**Why this file exists.** On 2026-10-24 the fleet's repair actuator was deployed, scheduled every
30 minutes, logging — and had repaired nothing for hours. Three independent defects were stacked and
**each one looked like health from outside**: a dispatcher that predated the `prfix` work kind
(`REFUSING: … predates the repair kind`, `rc=2`, every pass), an `objective.py` reading a repo nothing
had set (`OBJECTIVE_REPO` unset ⇒ agent-infra's SHAs read against tortoise's commit API ⇒ `422 No
commit found for SHA` on all 58 PRs ⇒ every pass refused), and a launchd job that could not traverse
`~/Documents` (`fatal: Unable to read current working directory` while `gh` reads still worked).

The general shape is the thing to fix: **a capability that is deployed, scheduled and logging can be
unable to do its job, and its "I refuse" state is indistinguishable from "nothing to do" in every
aggregate we publish.** So every capability below answers exactly three questions, and a capability
that cannot answer the middle one has not earned its place:

1. **What it promises** — the effect it exists to produce, in one sentence.
2. **How a caller distinguishes ALIVE from REFUSING from IDLE** — the artifact, the token and the exit
   code a reader that never sees a terminal or `launchctl list` can act on. **This is the answer that
   was missing**, and it is not "the file exists" (all four machines pass that) nor "the unit is
   active" (§1.2 measured both lying on the same box).
3. **What repairs it** — the specific remedy for REFUSING, per state.

⛔ **A capability whose refusal cannot be read from outside is a gap, and is named as one here** with
the issue that owns closing it. Nothing in this file is aspirational: each row was measured on at
least one machine on 2026-10-24, and the command is named.

---

## 1. The measurement this file is built on (re-measured 2026-10-24 14:44–14:53Z)

Measured **from cell-4** (`vm-ce2c2fc9fd844a32851d46c3723b903e`), which is the machine the epic's own
inventory table called the *broken* one. Every line below is output, not memory; the transcript is in
§1.3.

### 1.1 What is directly measurable from this box, and what is not

| machine | channel | result |
|---|---|---|
| **cell-4** (this box) | local shell | **MEASURED, fully** (§1.3) |
| **cell-3** `vm-915c3930…` | `cmux vm exec shiny-rose-ocelot -- …` | ⛔ **UNREADABLE** — `cmux: link to 'shiny-rose-ocelot' exited`; `/tmp/cell-home/.cmux/peer-links/shiny-rose-ocelot.log`: `cmux-tui: no known daemon matches this route; connect with an invitation`. Filed: **#2345** |
| **cell-1** `vm-efa6cc8fdb97…` | `cmux vm exec early-ivory-moth -- …` | ⛔ **UNREADABLE** — same failure, same log file |
| **local Mac** | none | ⛔ **UNREADABLE — there is no channel from a cell to the Mac.** `cmux vm ls` lists only the three cloud cells; `cmux self peers` lists the other two cells; there is no ssh route. The only cross-box channel is `git` refs on the queue repo's origin (§3.10) |

**This is itself the first contract finding, and it is not incidental:** the fleet's cross-box channel
is `git` refs on the queue repo's origin (`capacity.sh`'s header: *"The fleet's boxes share exactly ONE
channel: the queue repo's origin"*). A capability audit run from a cell therefore **cannot inventory a
peer machine** — only infer from what that peer published. That is sufficient for capacity (§3.10) and
insufficient for everything else, so `C5` (per-machine parity) is blocked on a read channel as well as
on activation. It also means **any parity claim about the Mac in this file is a RECORD, not a
measurement** — and is marked as such.

### 1.2 Corrections to the epic's inventory table (measurement wins; the table is not edited)

| epic row (or mandate item) | measured 2026-10-24 | verdict |
|---|---|---|
| `eldato-orchestrator` on cell-4 — the epic's false-PASS example: *"cell-4's controller unit is `inactive` and it still looked healthy in the fleet report"* | **14:46:01Z** `systemctl is-active eldato-orchestrator` → `inactive`; `enabled` → `not-found`; `0` unit files. **14:50:22Z** → `active` (unit installed 14:47:43Z by #2402), with `MainPID = /bin/bash …/cloud-cell-supervisor.sh start`, whose journal line is `controller already running (pid 684873684873) — this unit supervises the cell now: waiting for it to go, then taking over (a stop or a restart ends this wait)` | **The proxy is wrong in BOTH directions.** At 14:46 an `inactive` unit sat over a **live** controller (pid 684873, `HEALTHY age=180`, `[dispatch]` cycle records, live `merge-*` worker sessions — 3 at 14:46Z, 2 at 14:47Z). At 14:50 an `active` unit means a supervisor **waiting for a foreign pid**, while the running controller executes the **older** snapshot `d4ccaf6ee8e6` and the pin names `130638e40658`. "Unit is active" is not an effect test — measured on the box the epic cites. |
| **precedence rule: ">N unmerged PRs ⇒ merging outranks new work"** — the epic's cell: *"❌ implemented nowhere"* | `orch-loop.sh`, the comment above `mp_reason`: *"Merge priority: while any UN-OWNED PR remains, the box's work is the PR queue, not new PRs."* Shipped, and observable: cell-4's newest cycle record reads `dispatched=0 nothing=gate:merge-priority_(5_un-owned_of_13_open_PR(s)_—_PRs_before_issues)` | **Already implemented — and NOT as a threshold.** #2099 (owner ruling, 2026-10-18) *removed* the threshold: *"for as long as ANY workable un-owned PR remains, issues are not opened — no threshold, no age, no evidence arm"*. The epic's mandate item 4 asks for "a threshold that is a measured number with a written rationale"; **that design is superseded by a recorded owner decision** and must not be re-introduced (see §6, `OVERRIDES:`). |
| **universal dispatcher (one seam: place this lane on the machine with headroom)** — the epic's cell: *"❌ two ad-hoc scripts (`dispatch_generic.py`, `nonblocking-dispatch.sh`)"* | `capacity.sh` ships `cap_probe_local` / `cap_publish` / `cap_read_fleet` / `cap_place`, is sourced each cycle by `orch-loop.sh` (from `$O`, falling back to its own directory), and every cycle writes `[capacity] placement=… place=… lpc_self=… ceiling_lpc=… bound=…`. Cell-4's cycle record: `placement=place placed_on=cmux bound=none lpc_self=57` | **The seam exists.** Its *real* defect is different and worse: **its fleet view collapses to one box** (§3.10, measured). |
| *"no machine except the Mac has an actuator that lands anything"* (the epic's own reading of its table) | tortoise **16 PRs merged in the 8 h to 14:50Z**, two of them at **14:47:28Z** and **14:47:52Z**; agent-infra **11** in the same window; cell-4 held live `merge-*` worker sessions at 14:46Z | **Cells do land work.** ⚠️ Attribution is the gap: **no landing record carries the box that landed it** (§3.3), so "can this machine land?" is unanswerable from the artifacts — which is the dispatcher's own question. |
| **`pr-doctor` actually running** (epic: ❌ on every cell) | cell-4: `pgrep -f '[p]r-doctor.py'` → `0`; `pr-doctor.log` mtime `2026-10-22T12:55:05Z` (2 days); `0` systemd/launchd units matching `pr-doctor` | ✅ **Confirmed on cell-4.** Peers `UNREADABLE` (§1.1). |
| **`auto-rail` actuator running** (epic: ✅ on the Mac, ❌ elsewhere) | a tree search for `auto-rail` and for `autorail`, **and** `git log --all -S'auto-rail'` over the history **excluding this document** (`-- . ':(exclude)docs/ops/self-healing-contract.md'` — the file you are reading is the only thing in this repo that names the string) → **no source hits**; not in tortoise's tree or history either | ⛔ **Unattributable capability**: `com.tortoise.auto-rail` exists only as a launchd label on one machine, with **no source in any repo**. It cannot be repaired from a branch and cannot be audited off the Mac. See `C5`. |
| the mandate's item 3, verbatim — *"a per-spawn gate let `pr-doctor` put 16 workers on a Mac already at load 57"* | no such measurement is recorded in the repo. The measured instance on record in `spawn-gate.sh`'s comment beginning *"There is no `lane.sh` in that path"* is **three lanes at load 258 on 10 cores** (`MAX_LOAD=100`) via a `tmux new-session` runner that never sourced the gate | ⚠️ **The epic's figure is UNVERIFIED here.** The *mechanism* it describes is real and documented (§3.9). |

**The doubled pid in the first row is a second, independent finding:** the shipped emitter composes that phrase once (`_who="pid $(_pids_join "$_own")"` in `cloud-cell-supervisor.sh`, with the comment recording `"pid 15562491556249"` as the round-9 #2402 defect), so the **running** copy on this box predates that fix — the same skew §1.3 measures (pin `130638e40658`, running `d4ccaf6ee8e6`). The quote is verbatim from the journal at 14:47:43Z.

**A correction to a citation, kept out of the table on purpose.** The `auto-rail` row first read
`rg -ni 'auto-rail\|autorail'` — and that command cannot produce the finding it was cited for: `rg` is
Rust-regex, where a backslash-escaped bar is a LITERAL pipe, so the pattern searches for the single
string `auto-rail|autorail` and reports 0 hits whether or not either spelling exists. Inside a GFM table
cell the escape also renders back to a bare bar, so the defective form would have read as a WORKING
command — which is why this note is prose and the cell names two searches that can fail instead.

### 1.3 Transcript — cell-4 (verbatim, the commands whose output is quoted above)

```
$ hostname; nproc; cat /proc/loadavg
cmux                        <- ⛔ the cloud cells' shared hostname; see §3.10
8
5.30 5.39 7.94 6/3911 2480133

$ cat /tmp/cell-home/.harness-path
/tmp/cell-home/harness/130638e40658/scripts/orchestrator-harness
$ pgrep -af '[o]rch-loop.sh' | sed -n 3p        # the DEEPEST of the chain, never the first match
684873 bash /tmp/cell-home/harness/d4ccaf6ee8e6/scripts/orchestrator-harness/orch-loop.sh
                  ^^^^^^^^^^^^ RUNNING an older snapshot than the pin above

$ cat /tmp/cell-home/orchestrator/.orch.lock
684873
$ tail -1 /tmp/cell-home/orchestrator/state/cycles
start=1792853253 end=1792853398 cycle=8 interval=240 selected=pr:9884 selected_n=13 dispatched=0 \
  ids=- nothing=gate:merge-priority_(5_un-owned_of_13_open_PR(s)_—_PRs_before_issues) \
  placement=place placed_on=cmux bound=none lpc_self=57 shapes=13
$ bash /tmp/cell-home/orchestrator/cycle-record.sh status
HEALTHY age=180 cycles=355 interval=240 bound=480 why=fresh          (rc=0)

$ systemctl is-active eldato-orchestrator   # 14:46Z: 'inactive'.  14:50Z: 'active', MainPID=cloud-cell-supervisor.sh start
$ pgrep -f '[p]r-doctor.py' | wc -l
0
$ ls -l /tmp/cell-home/.pi/agent/state/pr-doctor.log
-rw-r--r-- 1 cmux cmux 51652 2026-10-22T12:55:05Z
$ grep -c '^\[cap\]' /tmp/cell-home/orchestrator/logs/controller.log
0
$ tail -1 /tmp/cell-home/orchestrator/logs/controller.log
date: write error: No space left on device        <- and mtime 10 h old, see §3.1

$ bash scripts/orchestrator-harness/capacity.sh probe
host=cmux ncpu=8 load1=530 lpc=66 lanes=1 disk_free_mb=4649 mem_free_mb=2176 at=1792853433 \
  procs=1412 procs_max=4692 fork=1 src=cgroup

$ cmux vm exec shiny-rose-ocelot -- hostname
cmux: link to 'shiny-rose-ocelot' exited; see /tmp/cell-home/.cmux/peer-links/shiny-rose-ocelot.log
$ tail -1 /tmp/cell-home/.cmux/peer-links/shiny-rose-ocelot.log
cmux-tui: no known daemon matches this route; connect with an invitation
```

---

## 2. The contract, in machine form

**One convention before the properties: every citation in this file names a file, a symbol or a quoted
line — never a line number, and never a live count.** A number rots the moment an unrelated edit lands
above it or another shard is wired, and a design document whose pointers are wrong is worse than none: it
sends the next lane to the wrong line with the authority of a citation. (The repo recorded the same
lesson in `.github/workflows/harness-single-source.yml`, above its steps: *"No line numbers for the steps
above, deliberately: citing them made THIS comment stale the moment it was inserted … A name survives an
edit; a line number does not."* This document was corrected twice for ignoring it before the convention
was written down here.)

Three properties, and every capability below is graded against all three:

| property | test | why it is the one that matters |
|---|---|---|
| **ALIVE** | the capability's *own record of the effect* is fresh and non-empty | a process, a unit state, a file's existence and a log's presence all pass while the effect is absent |
| **REFUSING** | a **named** token, with a **reason** and a **next action**, on a surface a reader that is not a terminal can parse (stdout line, sidecar field, exit code) | this is the state the fleet could not see. `nothing to do` and `I could not read the world` must never share a bit |
| **IDLE** | an **explicit** statement of emptiness, in the vocabulary the writer actually emits — `nothing=no_candidate` (the controller), `queue is empty: no open non-draft PRs` (the repair actuator's reason) | "exit 0, printed nothing" is the shape that reads as health in every aggregate. ⛔ `nothing=none` is NOT an emptiness token: it means work WAS dispatched |

Two corollaries, both learned the hard way and both encoded below:

- **A refusal is not a failure** (`capacity.sh`, its `EXIT` line: *"1 refused (a REFUSAL IS NOT A FAILURE, it is
  the answer)"*). A caller that treats refusal as failure will suppress it; a caller that treats it as success is
  the incident.
- **CANNOT-VERIFY IS NEVER A PASS.** `check-deployed-drift.sh`: *"AN ABSENT, UNREADABLE OR UNKNOWN
  IDENTITY IS `UNKNOWN`, AND CANNOT-VERIFY IS NEVER A PASS."* The same statement appears in
  `capacity.sh` (`probe_unreadable` ⇒ ineligible), `cycle-record.sh` (rc 2 for `ABSENT`/`UNREADABLE`),
  and `cloud-cell-supervisor.sh`'s `worker_census` (`exit 3` when no answer can be had, *"UNKNOWN (exit 3) is
  NOT zero"*).

**And the exit code is a surface, read by POLARITY** (#2710). Where a capability's codes partition
*verdict* from *refusal*, `0` means *an answer this capability knows how to read* and `2` means *it could
not answer* — an unknown word included, because an allow-list is the only polarity that cannot leak
(a deny-list lets an unrecognised conclusion fall through the gap read as a pass). **A non-zero code is
not automatically a refusal:** `check-deployed-drift.sh` uses `1` for `DRIFT`, a confident answer that
the bytes differ, and `2` for `UNKNOWN`/cannot-verify; `capacity.sh` uses `1` for a placement refusal
that is itself the answer. `2` is the fleet's cannot-verify code across `check-deployed-drift.sh`,
`cycle-record.sh`, `pr-doctor.py` and `objective.py`, so a caller that has learned that one rule can read
all four. A capability that emits its own vocabulary must still honour it.

---

## 3. Per capability

Each subsection is exactly three answers. `state:` is the measured state of each machine at
2026-10-24 14:50Z where it was readable; `NC` = not checked (no channel, §1.1).

### 3.1 Controller / scheduler — `scripts/orchestrator-harness/orch-loop.sh`

**Promises.** Each cycle: read the PR queue and the issue pool, decide (merge-priority gate first),
place the batch, spawn workers, and **record what it decided** — for as long as the box is up.

**ALIVE vs REFUSING vs IDLE.** The record is `$O/state/cycles`, one line per cycle, written by
`cycle-record.sh`; `cycle_verdict` grades its **newest** record and exits **0 HEALTHY · 1
DEGRADED/FORK-STARVED · 2 ABSENT/UNREADABLE (never a pass)** (`cycle-record.sh`, its header `EXIT` line).
The three states a caller must read apart live in the *fields*, not the verdict:
`dispatched=<n> nothing=none` = **ALIVE** (work placed); `dispatched=0 nothing=no_candidate` =
**IDLE** (a readable world, nothing selected); `dispatched=0 nothing=gate:<name>(<reason>)` or
`placement=fork_held` = **REFUSING, with the binding gate named** (`load=…>=max_load=…`,
`capacity-placement(bound=…)`, `gate:merge-priority(<n> un-owned of <m> open PR(s))`,
`fork_headroom`); `dispatched=0 nothing=placed_elsewhere:<n>` = the work went to a **peer box** (not a
refusal and not idle — the placement seam did its job).
⛔ **`nothing=none` is the ALIVE marker, never the IDLE one** — the writer states the rule in its own
comment: *"`nothing=none` is printed only when something WAS dispatched, so an idle cycle can never read
as a working one."* An earlier draft of this document had that backwards (it read IDLE from
`nothing=none`), which would have made every working cycle read as idle and every idle one unreadable;
the writer's branch order is the authority.
⛔ **The verdict alone cannot separate REFUSING from IDLE**: cell-4 printed `HEALTHY` with
`dispatched=0` and a `gate:merge-priority` refusal. That is deliberate (a draining box *is* healthy)
but it means **a reader that prints only the verdict is reading a cycling-ness test, not an effect
test** — which is exactly the confusion this epic is about.
⛔ **AND ONE NAMED GATE IS NOT A REASON (#2924, #2927).** The gate arms are evaluated in order and
`GATE_WHY` keeps only the **first** that fired, so the first arm — `merge-priority`, set whenever any
workable un-owned PR exists — MASKS every capacity gate behind it. Measured on the Mac controller over
**385 instrumented cycles** (2026-10-24→27, of which **384** reached the gate): **349** of those 384
closed the issue path naming `merge-priority` with **25 of 25 lane slots free**; **88.5%** of the
gated cycles *also* had a capacity gate that would have refused, and **64** were refused while
`ci-queue` itself read `ok`. So the `[dispatch]` line's `(<gate>)` field
alone could not tell "waiting for the PR sweep" (healthy, and the sweep is what clears it) from
"throttled by a gate nobody can see" (the defect). The line now carries an appended, additive
**gate vector** — `| gates: merge-priority(<n> un-owned) fork=ok fork_bound=ok(…) lanes=<n>/<max>
load=ok(<l>/<max>) placement=… ci-queue=<verdict> slots=<n> free of <max> swap=… mem=…` — one named
verdict per arm, **in evaluation order, whether the arm won or not**, with the measured number it was
decided on. The two lane tokens are mutually exclusive by construction: `slots=<n> free of <max>`
when a slot remains, `lanes_full=<n>>=<max>(0 slots free)` when none does. It is produced by the arms themselves (each assigns `GATE_WHY` only if still unset — the
old first-wins semantics, byte for byte — and appends its own verdict), so a new arm cannot be added
invisibly; `test-gates.sh` grades the co-binding case, the first-wins order, and two mutants (vector
removed ⇒ a masked capacity refusal goes invisible again; arms made unconditional ⇒ the order
flips). ⛔ **Scope, stated rather than implied:** the CYCLE RECORD still carries the winning arm only
(`nothing=gate:<first>`); the vector rides the log line, and moving it into the record is #2924's
remaining half.
**Do not read `$O/logs/controller.log`.** Measured today: mtime **10 h stale**, **0** `[cap]` lines,
last line `date: write error: No space left on device` — while the controller was cycling and landing.

**What repairs it.** `nothing=gate:load…` → wait (a load refusal clears itself). `gate:merge-priority`
→ drain the queue: this is the gate working, not a fault. `placement=refuse bound=…` → the *fleet*
needs a box (`load_per_cpu`), a prune (`disk`), or a restart (`fork_*`). `DEGRADED` (freshness) →
restart the controller (`cloud-cell-supervisor.sh stop && start`; on the Mac `install.sh --restart`,
never `unload -w`). `FORK-STARVED` → **from outside the box** (nothing inside can fork to clean up).

**state.** cell-4 ALIVE (`HEALTHY age=180`, 355 records). cell-3: ALIVE at 14:47:40Z — inferred from
its own published capacity record (§3.10), not read directly. cell-1 / Mac: NC.

### 3.2 Service supervision — `eldato-orchestrator.service`, `cloud-cell-supervisor.sh`, launchd

**Promises.** Keep exactly ONE controller running on the box, across the death of the controller *and*
the death of the shell that started it.

**ALIVE vs REFUSING vs IDLE.** There is no effect here — the effect belongs to §3.1, and this
capability's only honest readout is **which pid the box considers its controller**: `$O/.orch.lock`
(the controller writes its own `$$`), cross-checked against the deepest `pgrep -af '[o]rch-loop.sh'`
match, **and against the snapshot path in that match's argv**. `systemctl is-active` is **not** a
readout of this capability: measured today, `active` while the unit's own log said
`controller already running (pid 684873684873) — this unit supervises the cell now: waiting for it to
go, then taking over (a stop or a restart ends this wait)` (quoted verbatim and in full in §1.2, which
also reads the doubled pid). A second supervisor over a foreign controller is `ACTIVE` and doing
nothing.

**What repairs it.** Converge to one: stop the stray **by exact pid** (enumerate with `ppid` and
`cmdline` first — never `pkill -f`), then `install-controller-service.sh` / `install.sh --restart`,
then assert `.orch.lock` names the new pid **and** a fresh cycle record. ⛔ Never `launchctl unload -w`.

**state.** cell-4: two supervisors, one controller (§1.2). Mac: RECORDED (`com.eldato.orchestrator-loop`,
tmux-pane entrypoint required by TCC — `docs/ops/fleet-harness-baseline.md` §3.1), not re-measured.

### 3.3 Merge rail — `scripts/admin-merge.sh` (+ `verify-admin-merge-evidence.sh`)

**Promises.** A merge happens **only** with evidence bound to the exact revision being landed: the
failing-test set computed against main, a residual exemption decision, and a head-bound evidence
comment (`<!-- admin-merge-safety: <HEAD> -->`). `gh pr merge --admin` bypasses required checks, so
this script *is* the gate; `extensions/review-enforcer/` refuses a raw `--admin` merge that carries no
head-bound evidence, so bypass is safe or it does not happen.

**ALIVE vs REFUSING vs IDLE.**
- ALIVE: `gh pr merge` returned 0 **and the PR's state is `MERGED`** — the rail's own header states
  that *"`gh pr merge`'s EXIT STATUS is a statement about the SEND"*, and a queued `--auto` exits 0
  with the PR still open. A failure **after** the marker is posted posts a head-bound **RETRACTION**.
- REFUSING: `admin-merge: ✗ BLOCK — <reason>` on stderr, machine tags `[merge_unreadable]`,
  `[head_unreadable]`, `[draft_unreadable]`, and **exit 1**. Usage/knob errors are exit 2; there is no
  other refusal code.
- IDLE: not a state this capability has (it acts on one PR when asked). Its *caller* has one (§3.4).

**What repairs it.** A record bound to the current head blocks a branch update **full stop** — remedy:
re-review and re-record at a new head, or re-trigger the PR's checks by an event that does not move
it. `blocked-by-rail` classes (`flip-gate`/`drift-guard`/`provenance`) are repaired by the dispatcher
(§3.6). Under an unreadable record the rail **fails closed by name** (a file whose `head_sha` is
missing/short/non-hex is not "no record").
⛔ **Gap: nothing attributes a landing to the box that performed it** (no host in the land path), so
"which machine can land" cannot be answered from artifacts — the dispatcher's own question. `C3`.

**state.** cell-4: rail present at the pin and in the checkout, and **landing** (2 merges at 14:47Z; 16
tortoise + 11 agent-infra in 8 h).

### 3.4 Drain loop — `lander.sh` / `merge-one.sh` / `chain-merge.sh`

**Promises.** Walk the queue of green PRs and land them one at a time, naming why nothing landed.

**ALIVE vs REFUSING vs IDLE.** `lander.sh` distinguishes the states *before* the rail:
`PENDING → WAIT. Not an action, not a failure, not a "blocked" report`; `FAILED → SKIP, and NAME the
failing checks`; a landed PR is re-read after the attempt and never re-handed to the rail. Its verdict
surface is its per-PR log plus the post-attempt state re-read (`state, mergeable`), which the file
documents as the thing its precedent got wrong.
**Gap: `merge-one.sh`, `chain-merge.sh` and `dispatch-merge.sh` have no suite of their own** (§5.2).

**What repairs it.** The measured blocker is CI latency, not review (2026-10-22: PRs `MERGEABLE`,
`reviewDecision: null`, `statusCheckRollup = PENDING` with 127 runs queued) — so the remedy is
back-pressure (§3.16), not a retry.

**state.** cell-4: live `merge-*` sessions at 14:46Z.

### 3.5 Review evidence — `record-review.sh`, `review-pr.sh`

**Promises.** A clean review verdict is **recorded, bound to the reviewed head**, and a record can only
be minted by a fresh-context reviewer that returned a clean verdict.

**ALIVE vs REFUSING vs IDLE.** ALIVE = a record file at
`~/.pi/agent/reviews/<owner>-<repo>-<pr>.json` carrying `head_sha`, `repo`, `verdict`
(`clean|clean-micro|clean-low`), `diff_sha256`, and mint provenance (`"mint":"fresh"|"carried"`, with
`carried_from`/`carried_at` on a carried record). REFUSING = no record + a **printed** reason
(`tests/review-pr/run.sh` pins: findings are *not* recorded and exit **7**; no auth / missing `pi` /
no verdict / a head that moved mid-review all refuse with no record; an unchanged head is never
re-recorded).
IDLE does not apply — a review is requested, not scheduled.

**What repairs it.** Re-run `review-pr.sh` at the new head; a **base-only** head move CARRYs
(`tests/record-review/run.sh` pins the carry), lane work REFUSES.

**state.** NC on cell-4 (no review records produced there in the window measured); the capability is
exercised and pinned in CI (§5.1).

### 3.6 Repair actuator — `scripts/pr-doctor.py`

**Promises.** Every pass, drive every open non-draft PR toward `merged`: classify it via `objective.py`
and **dispatch** the work (call the rail / repair the gate / re-trigger / rebase / review+record+rail /
fix the red).

**ALIVE vs REFUSING vs IDLE.** The exit contract is a single table and it is a machine surface:
`0` a readable pass (it dispatched, **or** there was genuinely nothing to do — the line names which,
`queue is empty: no open non-draft PRs`); `2` **REFUSING** — *"I could not read the world, or could not
deliver to it"*, logged as `REFUSING: <reason>` and mirrored into `state/pr-doctor.status.json` with
`rc`, `read` (`open_prs` | `transport` | …), `reason` and `repo`; `3` **NOT DELIVERED** — the work was
legible and none of it went out: no worker took an order that was placed, **or** a durable state (a
worktree holding uncommitted work, a refusing transport) stopped the order before delivery; `6`
**NO-CAPACITY** — the spawn GATE refused the order (its own bound: `load` | `disk` | `land-backlog` |
`fork` | `capability`), nothing was consumed and no transport was involved, so the response is the
BOUND's own remedy
and never a repair — `load`/`land-backlog` clear by themselves, `disk` needs a reclaim, `fork`
needs the box restarted or drained **from outside** (it is out of processes, and waiting on load will
never clear it), and `capability` needs the box measured and repaired by hand (it could not complete
one model call and return); `4` crash; `64` the command line is unusable (**not** 2, so a launchd
typo cannot masquerade as a refusal). ⛔ The sidecar **must** be overwritten by a refusing pass —
otherwise the previous pass's `ok` stands and *"a failure only `launchctl list` can witness is a
silent failure"*. `scripts/test_pr_doctor.py` §10 pins exactly that agreement.
⛔ **AND `0` IS NOT REACHABLE FROM A PASS THAT REFUSED AN ORDER** (#2710, measured 2026-10-27). A
worktree refusal that will not clear by waiting (uncommitted work, commits the PR head does not have)
records a row and a cooldown; until #2710 it did **not** join the `undeliverable` axis, so a pass whose
only outcome was four such refusals printed `dispatched 0 of 4 queued — refused-recorded=4` and exited
**0** — this table's own word for "readable, nothing to do" — five times in one day while four PRs sat
stuck, and each one was cleared by hand. It now exits `3`. ⛔ **AND EVERY PASS THAT COVERS THE ROW, not
only the one that records it:** the first version of this fix refused on the recording pass and then
returned to `0` for the 44 minutes of the row's own cooldown, which is the loop the issue is about. A
`kind: refused` row inside its cooldown therefore counts as undelivered work (a `kind: spawn` row in
its cooldown is a worker in flight, and stays clean), the row carries its own `refusals` count, and
after `REFUSAL_ESCALATE_AT` consecutive refusals **at one head** the pass prints `ESCALATE #<n>` naming
the worktree and the repair — on the verdict line too, not only in the log. A head move starts a new
episode. The two *causes* — a box with no room vs the transport refusing — are separated into `6` and
`3` by agent-infra#2291 (below); what is decided here is that neither may read as a clean pass.
⛔ **AND THE ACCOUNTING IS ITS OWN PASS OVER THE QUEUE** (review round 2, P1 — reproduced, twice).
The first attempt only hoisted it above the class-budget `continue`; the dispatch loop still `break`s on
`dispatched >= budgets["total"]`, so with a zero total (a saturated box, or `--max 0`) it broke on the
first row not in a cooldown. Measured, same two rows, only the PR numbers swapped: `EXIT rc=3` +
`ESCALATE` when the refused row sorted first, `EXIT rc=0` with no escalation when it sorted second — a
verdict that depends on PR-number ordering is not a verdict. Every classified row is now ACCOUNTED for
first, in its own loop, and the dispatch loop covers only the rest. ⛔ **And a refusal whose 45-minute
cooldown has EXPIRED is counted when the pass has no budget to retry it** (review round 3, reproduced):
without that, the same false clean reappeared 46 minutes later, when a saturated pass (`total == 0`, or
`--max 0`) broke out of the dispatch loop before reaching the row. The budget is the only reason such a
row is not retried, so the budget is what decides whether the pass may still call itself clean. A corrupted count (a non-number,
`inf` from `1e999`, or a negative) degrades to "unknown count" rather than crashing the pass, and the
escalation list marks its truncation (`+N more`) instead of silently naming the first four.
⛔ **AND THE ACCOUNTING PRECEDES THE BUDGET GATE** (review round 2, P1 — reproduced). A `kind: refused`
row never launched a worker, so it has no `$O/bg/<worker>.pid`; `_worker_state` answers `unknown` for it,
and `pass_budgets` was charging it to its class. At the SHIPPED defaults (`MAX_FIX=3`) the incident's
**four** refusals exhausted the fix budget, and the budget gate sits ABOVE the cooldown arm — so the pass
skipped the accounting entirely and printed `dispatched 0 of 4 queued — budget=4` with `EXIT rc=0`. That is
the same silent clean pass, at the default capacity, with the row count the incident measured. A refusal
consumes nothing (`void_refused_rows` already states the rule), so it may not hold a budget slot, and the
cooldown/refusal arm now runs BEFORE the gate: a pass over its dispatch budget still COUNTS and NAMES the
refusals it covers. The cooldown and placed-order causes are also counted separately, so the verdict line
cannot say "no worker accepted" about a pass in which no order was placed.

⛔ **AND THE PASS VERDICT ON THAT AXIS IS PINNED BY NAME (#2710; measured 2026-10-28 — five
consecutive 45-minute windows, 18–25 PRs unmoving, `rc=0` while the heartbeat stayed fresh).**
`scripts/test_pr_doctor.py`'s #2710 block drives it: `test_FOUR_refused_rows_at_the_SHIPPED_caps_still_refuse_and_escalate`
(the shipped `MAX_FIX`=3 path), `test_a_pass_WAITING_OUT_a_refusal_cooldown_is_not_a_clean_pass` (the
44-minutes-out-of-45 hole — **and** the opposite verdict, since a `kind: spawn` row in its cooldown must
still be `0`), `test_a_SATURATED_pass_still_refuses_and_names_a_refused_row`, and
`test_an_EXPIRED_cooldown_refusal_is_not_dropped_by_a_saturated_pass` (both row orderings, because that
defect was ordering-dependent). So the rule cannot be satisfied by answering "not clean" to everything.

⛔ **#2708's remaining cut is the STALE-HELPER half of the same class** — a refusal that does not say
WHICH copy judged it. `nonblocking-dispatch.sh` resolved `brief-gate.sh` from four candidates and then
said only that "the gate" refused, so after the 2026-10-28 case 3 measurement (the driver resolved
`$O/objective.py` while the fix landed on `~/.pi/agent/scripts/objective.py`) an operator was sent to
the copy they had just repaired. The refusal now names `$bg_lib`.

⚠️ **Re-read against #2710, which landed first:** `3` was later BROADENED to *"legible work, none of it
out"* so that a durable pre-delivery refusal (a dirty worktree, a refusing transport) no longer reads
`0`. That is the same axis this split moves to `6` — and the two do not overlap: `3` is **"the chain
would not take it"** (repair it), `6` is **"the GATE measured the box and said not now"** (wait, or
prune/add capacity). A gate refusal consumes nothing, and **whether it clears by itself is the AXIS's
answer, not a property of the code** — `load`/`land-backlog` clear as the box drains, `disk` needs a
reclaim, `fork` needs a restart from outside, `capability` needs a hand repair (the box cannot finish
one call), and in none of the five is the remedy a repair of the
transport (`GATE_REFUSAL_ACTION`, and `scripts/test_pr_doctor.py`'s
`test_the_gate_axis_table_is_the_GATES_own_numbers`). ⛔ So `6` must never be reported with a universal
*"it clears by itself"* — that sentence is the same class of collapse as the one this change removes,
written into prose instead of into a counter. The rebase that merged the two kept both statements of
the axis in this file.

**`3` and `6` are the same sentence in two different worlds (agent-infra#2291).** Both used to be `3`
with `N order(s) no worker accepted`, because a gate refusal and a transport failure are both
`record=False` in `dispatch()`. Measured, same pass shape on 2026-10-27:
`EXIT rc=3 -- refused-recorded=4; 4 order(s) no worker accepted` — four stale-worktree refusals (repair
the tree) reporting the code a genuinely overloaded box produces (wait). So:

- the code is split, and `6` is **not a new number**: `scripts/pr-repair-loop.sh` (the cell's repair
  unit, which runs this actuator) already declares `EXIT_DEFERRED=6` for "the machine said not now", and
  it maps `pr-doctor`'s `6` onto that same row (`decision=deferred`, `reason=dispatcher-no-capacity`);
- the **verdict is named** in the sidecar for **every exit** — `verdict` (`OK` | `REFUSING` |
  `UNDELIVERED` | `NO-CAPACITY` | `CRASH` | `USAGE`), `reason`, `next_action`, plus `no_room`,
  `no_room_bound` and `room` (the box's own measurement) on the `6` path. It is applied inside
  `record_exit` as a total default derived from `rc` (so an early refusal path cannot ship a record
  with no verdict), and `_finish` overrides only the bound-specific `next_action`;
- the **box measurement is the fleet's existing one**, not a second one: `room` is the raw record from
  `bash $O/capacity.sh probe <checkout>` (`host ncpu load1 lpc lanes disk_free_mb mem_free_mb at procs
  procs_max fork src`, agent-infra#2253), read once *after* the decision and **never** used to take it —
  the gate already decided, on its own numbers. An unreadable probe is recorded as
  `room_read: false` with the reason and does not change the code, because the refusal stands on the
  gate's measurement (`capacity.sh` exits 254 when the read itself could not fork, 2 when a core field
  could not be measured);
- the readers agree on the word: `heartbeat-loop.sh` prints `PR-DOCTOR WAITING rc=6`,
  `objective.py::pr_doctor_last_run` renders `WAITING (no capacity)`, `repo_row()` says `verdict=WAITING`.
  **None of them reads `6` as `ok`** (§2: cannot-verify is never a pass) and none reads it as `RED`.
  ⛔ AND ALL THREE ARE FRESHNESS-BOUNDED FIRST FOR `0` AND `6` (#2291 review, P2 — the first version
  of this paragraph claimed it for every code and for all three readers, which the code refutes).
  `heartbeat-loop.sh` and `objective.py::pr_doctor_last_run` read the SAME 2400 s bound before the
  word, so a `NO-CAPACITY` record past it reads `RED UNREPORTED (verdict is STALE)` in the beat and
  `UNREPORTED (verdict is STALE, …)` in the objective — and a box that filled up and then died cannot
  print the reassuring word for ever. `repo_row()` takes no age at all (it renders one pass's counts),
  and for `2`/`3`/`4` the two readers word an old record differently — `RED rc=N` in the beat versus
  `UNREPORTED (verdict is STALE…)` in the objective. Both are non-green and neither is `ok`; they are
  not the same sentence, so this paragraph does not claim they are.

**What repairs it.** Read `read=` and `reason=` from the sidecar, then: `read=transport` +
`predates the repair kind` → refresh `$O` with `install.sh` (a stale dispatcher silently downgrades
every repair to a creation spawn). `read=open_prs` + HTTP 404/422 on every PR → **the repo is wrong**
(`OBJECTIVE_REPO`, §3.7). A row in `refused` state → the worktree it names is not disposable: repair it
(the refusal text carries the action) and the cooldown clears on the next pass after a dispatch. No
process at all → this is the one repair nothing does automatically on a cell today: `C5`.

**state.** cell-4: **not running** — `0` processes, log 2 days old, no unit. cell-3/1/Mac: NC.
RECORDED: on the Mac the launchd job is the only producer, and it cannot traverse `~/Documents`
without the tmux-pane FDA grant (`fleet-harness-baseline.md` §3.1).

### 3.7 Classifier — `scripts/objective.py`

**Promises.** ONE vocabulary for "what does this PR need", read by both the beat and the dispatcher, so
two readers of one queue cannot disagree (measured 2026-10-16: they disagreed on 4 of 11 PRs, 36%).

**ALIVE vs REFUSING vs IDLE.** ALIVE = one machine-parsed line:
`OBJECTIVE VERDICT=AT-TARGET|ADVANCING|REGRESSING|FIX-MAIN|GH-RATE-LIMITED|UNKNOWN repo=<owner/name>
repo_src=env|checkout|default …`. IDLE is `AT-TARGET` (queue depth below `TARGET_PRS`). REFUSING is
**`UNKNOWN`** (and `GH-RATE-LIMITED`, which is the same fact about the same tick: the world could not be
read), and `UNKNOWN error=<…>` is the shape a *wrong* read takes.
⛔ **The exit code now agrees with the line (#2710; fixed here, was the epic's defect 2).** `0` only for
a verdict in `READABLE_VERDICTS`; `2` for everything else, including a word this file has never seen
(the allow-list polarity in §2). Before it, `main()` fell off the end on every path, so
`VERDICT=UNKNOWN` **exited 0** and the ONE state that means "the read did not happen" was
indistinguishable, to a launcher, from `AT-TARGET`. ⛔ **And blindness outranks the verdict word:**
`build()`'s ladder puts `FIX-MAIN` above the blind-queue arm, so a RED main beside an unreadable queue
printed `VERDICT=FIX-MAIN … queue=UNREADABLE` — a readable word over an unread world. The code refuses on
any `BLINDNESS_TOKENS` fact whatever word accompanies it; §2's rule, applied where it bites. ⛔ **And the
inventory must be COMPLETE, or the rule has a hole** (review round 2, reproduced): `queue_read=BLIND(…)` —
the file's own word for "the QUEUE read did not answer", printed beside the counts it disowns — was not in
`BLINDNESS_TOKENS`, so `VERDICT=AT-TARGET … queue_read=BLIND(4/4 unread, samples=4) -- the QUEUE counts are
NOT a clearance` exited **0**. Both spellings (`BLIND(`, `UNREADABLE(`) now refuse; `REST(` deliberately does
not, because it is a decided non-blind degradation. `error=` is matched as a FIELD, not a substring: a
required check legitimately named `pytest (error=timeout)` was refusing a fully readable line.
⛔ **And a required set that does not describe this repo is `UNKNOWN`, never `GREEN`** (review round 2, P1 —
reproduced, and it is the worst shape this issue names). `REQUIRED` is tortoise's set by default and this
change made `REPO` follow the checkout/`OR`, so on any other repo those gates are not the ones being run:
`req_red` empty, nothing in flight, `GREEN` — measured with three ALL-RED checks on the head,
`main_health() -> ('GREEN', [])`. The repo half of the seam landed in round 1; this is the half that says
"I cannot judge this repo with another repo's gates". ⛔ **And the question is asked of the REPO, never of
the name list** — the second review round measured why a presence test is wrong: on tortoise main
`ef02b7acd` the five reusable-workflow gates are published as `main-health / docs` (not `docs`), and the
GraphQL `statusCheckRollup` returned seven names containing none of them, so "no required name present"
is TRUE on the very repo the rubric describes. A presence-based guard would have made the primary box a
permanent refusal (exit 2 every tick) with no shipped remedy. `REQUIRED_REPO` names the repo the bundled
set was read from; a supplied set (`OBJECTIVE_REQUIRED`, resolved from branch protection) is judged as
before. ⛔ **One residual is named, not hidden:** a SUPPLIED set whose names have gone stale still answers
`GREEN`, because absence cannot distinguish a stale declaration from a transport that renders names
differently (measured above: GraphQL 7 names, REST 22, same sha); refusing on absence would be a
permanent over-block on a correct configuration, and the seam repair is `#2518`.
✅ **A required CONTEXT name is not a check-run name — a PRE-EXISTING false PASS, closed here.** Branch
protection requires `docs`; a reusable workflow publishes `main-health / docs`. A bare `c in red` could
not see a red required gate at all (measured on the same head: the surface carries `main-health / docs`,
`main-health / legal-e2e`, `main-health / license-surface`, `main-health / pricing-artifact`,
`main-health / test-isolation`; the required contexts are the leaves). Required names are now matched on
the exact name OR its ` / ` leaf, in BOTH directions, so `main=GREEN` can no longer sit over a red
required gate. Matching only ADDS names, so it cannot turn a RED into a GREEN.
⛔ **The repo is an input with a NAMED source, and a mismatch refuses.** `REPO_DEFAULT`
(`daniel-ospina/tortoise`) was `OBJECTIVE_REPO or <that literal>`: silent, and never compared with the
checkout the process stands in — so measured 2026-10-24 an agent-infra doctor read tortoise's check-runs
for agent-infra's SHAs and GitHub answered `422 No commit found for SHA` for every PR while the log
looked like a quiet queue. `resolve_repo()` applies the rule the SUPERVISOR already had for `OR`:

- a **declared** repo — `OBJECTIVE_REPO`, then `OR` (which `orch-loop.sh` exports into every child, so a
  controller cannot be silently re-pointed by whatever cwd its pass inherits) — wins (`repo_src=env`);
- a checkout that derives a DIFFERENT slug is a NAMED REFUSAL
  (`error=repo_mismatch(read=…, checkout=… next=…)`) issued **before the first `gh` call**;
- a declaration that could **not be compared** (deriver missing, `git` unusable) says so on the line as
  `repo_check=uncompared:<why>` — an inert comparison must not read as a satisfied one;
- with nothing declared, the checkout you stand in IS the repo (`repo_src=checkout`, derived by
  `repo-slug.sh`'s `derive_or`, the ONE deriver — never a second parser);
- and only when nothing is derivable does the default answer, now stamped `repo_src=default` on every
  line so it can never be silent again. The segment is APPENDED, not prepended: the fleet reads this
  line through a fixed cut and the `| PR-DOCTOR …` fact is deliberately early.
⚠️ **Remaining gap, stated narrowly.** The default is made loud, not removed: the Mac's beat runs the
FARM copy (`~/.pi/agent/scripts/`), which is not a git checkout and carries no `repo-slug.sh`, so on
that box `repo_src=default` is the expected reading until the farm carries the deriver (named on
`#2518`). And the module-level `REPO` is still `env or default` for the two importers that supply the
variable themselves (`pr-doctor.py`, `pr-loop.py`); the CLI is where the contract is enforced.

**What repairs it.** `UNKNOWN error=repo_mismatch(…)` ⇒ unset `OBJECTIVE_REPO` or run from the checkout
named; `UNKNOWN error=…` naming `422 No commit found for SHA` ⇒ set `OBJECTIVE_REPO`; a
`repo_src=default` on a box that DOES stand in a checkout ⇒ deploy `repo-slug.sh` with this script;
`GH-RATE-LIMITED` ⇒ wait (the gh limit layer is doing its job).

**state.** cell-4: present at the pin (`scripts/objective.py`), no consumer running (§3.6).

### 3.8 Dispatcher — `nonblocking-dispatch.sh` (+ `worker-terminal.sh`)

**Promises.** Start ONE worker for one unit of work, in the background, through the load gate, and
leave behind the files that answer "did it start, is it alive, how did it end".

**ALIVE vs REFUSING vs IDLE.** The **kind is a closed vocabulary, and a kind it cannot honour is
refused by name**: `kind '$WK' is not bg or prfix` → exit **2**; a missing or stale `spawn-gate.sh`
(no `run_agent`) → exit **78** (*"refusing to start an ungated worker"*). ALIVE = `.pid` + `.rc` +
`.started` (`name/worktree/branch/kind/prompt/started/cap`) exist and the worker is in the liveness
census. ⛔ **Liveness is the worker's own exit-status file, never `%CPU`** (`%CPU == 0` means
*waiting*, a lane blocked in a long tool call sits at 0 %).

**What repairs it.** `exit 78` → reinstall the harness (§3.14). `kind not bg|prfix` → the deployed `$O`
copy predates the kind: refresh `$O`. A `.rc` that never appears → the worker died before its wrapper
wrote it; the ledger row is the only trace.

**state.** cell-4: present (`prfix_hits=5`), workers live (2 `fix-*`, 2 `merge-*`).

### 3.9 Spawn gate — `scripts/orchestrator-harness/spawn-gate.sh`

**Promises.** No `pi` starts on a box over its ceiling — installed as `$HOME/.pi/agent/bin/pi`, first on
`PATH`, so *"A caller cannot opt out by omission because it is not asked."*

**ALIVE vs REFUSING vs IDLE.** REFUSING is a `[load-gate] REFUSED …` / `[disk-gate] REFUSED …` /
`[fork-gate] REFUSED …` / `[land-backlog] REFUSED …` line plus a **ledger row** in
`$HOME/.pi/agent/state/spawn-gate.tsv` (`epoch, verdict, load, max_load, pid, ppid, KIND, TAG, cwd,
caller`) — and **ALLOWED runs are recorded too** (*"a series that records only refusals cannot answer
'how close did we get'"*). Exit codes: 73 fork, 74 land backlog, 75 load, 76 pi, 77 disk, 78 fork.
IDLE does not apply (it gates, it does not act).
⛔ **This gate is PER SPAWN by design and that is the epic's structural complaint**: each invocation
takes a fresh reading and holds no cross-spawn budget, so a bulk dispatch of N workers is admitted one
at a time and can overshoot by up to N−1 workers. The measured incident on record is **three lanes at
load 258 on 10 cores** through a runner that never sourced the gate. (The epic's own words — *"a
per-spawn gate let `pr-doctor` put 16 workers on a Mac already at load 57"* — do not match any
measurement recorded in the repo, §1.2.)
⛔ **And the `task`/sub-agent fan-out does not pass through `PATH` at all** (`spawn-gate.sh`, the comment
beginning *"THE `task`/SUB-AGENT DISPATCH IS ANOTHER SPAWN POINT"*, #1920), so the one fan-out path a
modern lane actually uses is ungated.

**What repairs it.** `disk` → prune (§3.15). `fork` → from outside the box. `load` → wait, or let
placement (§3.10) move the work. `land-backlog` → drain (§3.4).

**state.** cell-4: present, ledger **22 rows, 964 min old** (no spawn through the gate in 16 h — the
live workers were started by the controller directly).

### 3.10 Placement / universal dispatcher — `scripts/orchestrator-harness/capacity.sh`

**Promises.** Answer ONE question — *where does this unit of work run* — from measured capacity:
`nproc`, `load1`, `lpc` (load per CPU ×100), free disk, free memory, **fork headroom**, TTL-bounded
freshness; refuse rather than place blind.

**ALIVE vs REFUSING vs IDLE.** ALIVE = `place=<host> lpc=… evaluated=N eligible=M`; **REFUSING =
`refuse bound=<the dominant bound> detail=… evaluated=N eligible=0`** with the bound named
(`fork_headroom`/`fork_probe`/**`fork_unknown`**/`disk`/`load_per_cpu`/`memory`/`probe_stale`/
`probe_unreadable`/`no_probe`/**`box_unknown`**/**`identity_collision`**, plus `usage` on the exit-2 arms), exit **1** (*"a REFUSAL IS NOT A FAILURE, it is the answer"*); IDLE does not apply.
Exit **2 = "cannot answer"** — and that is MORE than the transport: the sub-cases are an unreadable fleet
channel (`cap_read_fleet`), `refuse bound=usage detail=no-self-host|clock-unreadable` on a `place` call,
`probe=unreadable` on a `probe`, and an unknown verb. ⛔ Read the reason line before deciding which: a
`bound=usage` on `place` is a caller defect, not a git fault — the same "shared code, read the reason"
rule as `harness-refresh.sh`'s 23 (§3.12). Exit 254 = the probe itself could not fork (a *reading*, not a
crash).
The fleet channel is keyed by **(host, boxid)** — full shape
`refs/boxes/<host>/<boxid>/<at>-<ncpu>-<load1>-<lanes>-<disk>-<mem>-<procs>-<max>-<fork>-<boot>` — on the
queue repo's origin, read with one `git ls-remote --refs`. `boxid` is the per-box identity (§ below); a
pre-#2707 two-segment ref decodes as `box_unknown` and is refused, never silently dropped. A box's ref is
deletable only by the box that a LOCAL authorship ledger (`CAP_STATE_DIR`, default `${TMPDIR:-/tmp}/pi-capacity`, ring-bounded at `CAP_LEDGER_KEEP=32`; one filesystem
per box) proves wrote it, or once it is STALE — never because it merely shares a key with the pruner.

⛔ **MEASURED DEFECT (2026-10-24, this box) — the fleet view collapses to ONE box.**
`cap_host` defaults to `hostname -s`, and **two boxes demonstrably share the hostname `cmux`**: cell-4
measured directly (`$ hostname` → `cmux`), plus a **4-core box** publishing under that same key — cell-3 by
**elimination, not by a read** (cell-1 and cell-4 are 8-core, and §1.1 says a peer cannot be inventoried
from a cell; the numbers are `fleet-capacity.md`'s). Nothing overrides it — no deploy path sets
`CAP_HOST`. So both publish under the SAME key, and `cap_publish` prunes
`refs/boxes/<that host>/*` on every publish — **each box deletes its peers' records**. Evidence, in two
halves:
- this box's own probe: `host=cmux ncpu=8 …` — but `refs/boxes/cmux/1792853260-4-336-0-25297-4514-9-4692-1`
  in **tortoise** carries **`ncpu=4`**, which is not this 8-core box: **another box** published it under
  the same key 20 s earlier (cell-3 by elimination — inferred, not read, §1.1);
- `refs/boxes` in **agent-infra** carries two keys, neither of them cell-4's live reading: `Daniels-MacBook-Air`
  (130 records, newest 14:36:29Z) and a `cmux` record **34 h stale** (`ncpu=4`, 2026-10-23 04:50Z). The Mac
  publishes into a different **work repo** — cell-4's `REPO=/tmp/cell-t3` is tortoise — so a box's
  `cap_place` only ever reads the records published to ITS repo, and the two halves of the fleet cannot see
  each other (#2281 is the multi-repo controller half).
Consequence: `cap_place` compares against a fleet of one and always answers `place=<self>` — cell-4's
cycle record literally says `placed_on=cmux`. The seam, its thresholds (8.00 refuse / 4.00 prefer /
TTL 900 s / 500 MB disk / 512 MB mem / 200 fork headroom) and its fail-closed direction are all
correct; the **identity and the transport are not**. `C3`.
✅ `CAP_YIELD_AT_LPC=400` (the *prefer-elsewhere* line) **is live, and it is read by the CONTROLLER, not by
`cap_place`**: `orch-loop.sh` compares `CAP_LPC_SELF` against it and hands the work to the less-loaded box at
or above it. The split is deliberate (placement chooses a box; the controller decides whether to yield) and
`capacity-placement.test.sh` pins both the default and the gate. ⚠️ An earlier draft of this document called
it inert — wrong, and corrected in review round 1: `capacity.sh` alone does not read it, which is not the
same thing.

**What repairs it.** `bound=disk` → prune; `bound=memory` → find the leak; `bound=load_per_cpu` → the
fleet needs a box; `bound=fork_*` → external restart; `probe_unreadable` → the instrument, not the box;
`identity_collision` → two boxes publish under ONE key: fix the deployment's identity (a pinned
`CAP_BOXID` on two boxes, a shared private IP, an image-cloned id) — and do NOT "unstick" placement,
because the fleet cannot name the box it would place on. One benign cause has the same shape and no fix
needed: a box whose OWN pre-reboot ref is still under its key (a recreated cell, or a `TMPDIR` that did not
survive) — it clears on that ref going stale (≤ `CAP_PROBE_TTL`), or by deleting that one ref.
`box_unknown` → the ref names no box: a pre-#2707 box (upgrade it), or a box with no derivable identity —
which is also not placeable BY ITSELF, so pin `CAP_BOXID` on it rather than leaving it nameless.
For the identity defect: a per-box identity (`C3`), not a wider ceiling.

**✅ REPAIRED 2026-10-28 (#2707).** The identity is derived from the box's own network identity (Darwin:
`kern.uuid`; Linux: the routable IPv4 — the only two sources MEASURED to differ across the cells;
`/etc/machine-id` and `/proc/…/boot_id` are measured IDENTICAL on all three, so machine-id is deliberately
NOT a fallback — a box with no derivable identity refuses to publish rather than inventing one). The
channel is keyed `refs/boxes/<host>/<boxid>/…`, so three `cmux` boxes hold three keys, and `cap_publish`
prunes only refs its local ledger proves it wrote plus STALE ones. `foreign=` reports a second writer under
this box's key, and the reader marks such a record `collide=1`, which `cap_place` refuses on
(`bound=identity_collision`) instead of picking the newest. Residual, stated: two boxes sharing key AND
`ncpu` AND a `boot` reading that is equal *or unreadable* carry no distinguishing fact in the channel, so the reader keeps the newest of that key —
neither box destroys the other's record any more, and the identity sources are restricted to the
measured-unique ones so that case is not reachable by the cloned-image path. Rollout: a box still on the
old tree prunes host-wide with no authorship test and will delete upgraded peers' records — upgrade a
whole hostname group together.

**state.** cell-4: `lpc=66` (0.66×) eligible, published every cycle; cell-3: publishing (inferred);
Mac: published at **14:36:29Z**, `ncpu=8 load1=514 lanes=0 disk_free=39881MB mem_free=997MB` (6-slot
legacy form, no `boxid` ⇒ **ineligible** to a peer on current code: it is now ~34 h old so the bound that
names it is `probe_stale` — age is checked before identity — and once a fresh record carries no `boxid` the
bound is `box_unknown`, which is the one that survives self-healing).

### 3.11 Claims — `claims.sh` (+ `claim-reaper.sh`)

**Promises.** One box at a time works one issue/PR, decided by an atomic CAS on `refs/claims/*`.

**ALIVE vs REFUSING vs IDLE.** ALIVE = the claim ref exists and names a live holder; a *stale* claim is
REFUSING-no-more (`claim-reaper.sh` releases **only when the holder is demonstrably gone**, with
`box:<pid>` identity and ORPHANED-HOST reclamation after a rename — `claim-orphan.test.sh`,
`claim-exclusion.test.sh`, `claim-cwd.test.sh`). `claims.sh` prints its own refusal when it cannot
build the claim commit (`could not build claim commit`, the message that fired 793 consecutive times
on the Mac with a healthy `[cap]` line — the baseline doc's §4 proof that a `[cap]` line is not a
deployment proof).

**What repairs it.** A claimant whose box is gone → let `claim-reaper.sh` run; a claim that cannot be
built → fix the cwd/identity (§3.11: `claim-cwd.test.sh` pins `git -C` from a cwd that is not a
repo).

**state.** NC on cell-4 (claims are repo-scoped; the box was merging rather than dispatching).

### 3.12 Refresh — `refresh-candidates.sh` + `harness-refresh.sh`

**Promises.** (a) Keep the backlog pool non-empty from open P0/P1/P2 issues that pass pre-flight;
(b) keep the box's harness **pin** truthful with `origin/main`.

**ALIVE vs REFUSING vs IDLE.** `refresh-candidates.sh` appends CLEAN issues and writes the per-reason record
`state/refresh-funnel` (`listed=… judged=… queued=…` …), which `orch-loop.sh` RENDERS once as the
`[dispatch] <listed> candidates -> … -> <n> dispatched` line. The state this contract requires of it:
**IDLE is an empty funnel in which every reason is a NAMED counter**, never a bare empty file.

The measured freeze that this pins: a refresh ABORTed mid-pass leaving a **partial** `candidates.txt`
of 42 entries — and `42` is not `< 6`, so the old backlog trigger never fired again and the queue froze
for **six hours**. `refresh-candidates.sh` REFUSES with the pre-flight's OWN rc and carries its command
and stderr line (#2659) — a failed refresh is never a silent success — while `harness-refresh.sh` reports its own
outcomes by code, in its own words — **`0` `current` OR `restart-pending`** (the pin names the tip and the
running controller still executes an OLDER tree: reported as `restart-pending`, never as `current`, because
calling it `current` *"would be a false PASS about code that is not running yet"* — read the record for
which), `10` repinned (the materialiser ran and recorded whether the pin advanced or `$O` was re-seeded),
`11` mended (the pin was empty/absent/not-a-commit),
`20` REFUSED dirty, `21` REFUSED ahead, `22` REFUSED diverged, **`23` REFUSED unknown** (the ref/repo/running
commit cannot be resolved — *cannot-verify is not a pass* — or the materialiser failed), `25` behind with
NO materialiser, `26` REFUSED blocked (a `--re-seed` would change the code under a running controller).
⛔ `23` is the SCRIPT'S SHARED CODE: it means cannot-verify **or** an unusable command line — the argument
parser has no separate usage code, so a missing option value and an unresolvable ref both exit 23. Read the
reason line before deciding which; do not read `23` as "always my typo" (an operator then dismisses a
cannot-verify refusal) and do not read it as "always the instrument" (a typo then looks like a fleet fault).

**What repairs it.** A frozen pool → `refresh-candidates.sh` by hand and read the funnel; a pin that
cannot advance → `cloud-cell-supervisor.sh apply`.

**state.** cell-4: pin/process skew (§1.3) — the pin is truthful with `origin/main`, the **running**
controller is not. `harness-refresh.sh` moves the pin; nothing moves a running controller.

### 3.13 Liveness / reapers — `lane-status.py`, `lane-watchdog.py`, `orphan-reap.py`, `pi-reap-*`, `disk-reaper.sh`, `reap-lane-venvs.sh`

**Promises.** Reap what is provably dead, keep what is working, and never reap a human's session.

**ALIVE vs REFUSING vs IDLE.** `docs/ops/fleet-liveness.md` defines **exactly five** states and always
names the evidence: `dead | running-quiet | wedged | idle | unknown`, with `unknown` a **named
abstention** (exit 3) and a reason vocabulary (`ps-unreadable`, `jsonl-age-unknown`, `no-holder-record`,
`turn-state-unknown`, `tail-after-compaction`, …). The reapers have their own four —
`LIVE`, `PARKED-REAPABLE`, `KEEP-HUMAN`, `UNVERIFIABLE` — declared in `scripts/orphan-reap.py`
(`POOL_STATES`), which is also where the `UNVERIFIABLE (no-progress-channel:…)` abstention below lives.
⛔ **The declared hole a universal dispatcher must not repeat:** a `pi` that leaves no bindable session
file (a print-mode `task` child, a resumed session keeping its original name-stamp) has **no progress
channel**, so its PARKED row abstains as `UNVERIFIABLE (no-progress-channel:<binding>)` rather than
"nothing to reap". **Liveness is a transcript signal.** A dispatcher that reports on work by reading a
transcript will report nothing about a worker that has none.

**What repairs it.** `UNVERIFIABLE` → a human; a stale JSONL with no tool in flight → the watchdog; disk
pressure → `disk-reaper.sh`.

**state.** cell-4: disk `4649 MB` free (97 % used) — above the 500 MB floor, so no refusal, but the
`ENOSPC` in `controller.log` is what a floor *at* the floor looks like.

### 3.14 Deployment provenance — `check-deployed-drift.sh`, `deploy-harness.sh`, `check-single-source.sh`

**Promises.** Answer *are the bytes this box executes the bytes we reviewed?* — with three independent
halves (IDENTITY from `.agent-infra-stamp.json`, RELATION of the recorded commit to the ref, BYTES by
blob sha of every shipped `*.sh`), **and refuse to answer "fine" when it cannot answer at all**.

**ALIVE vs REFUSING vs IDLE.** The exit code IS the contract: **0 OK · 1 DRIFT · 2 UNKNOWN**
(*"AN ABSENT, UNREADABLE OR UNKNOWN IDENTITY IS `UNKNOWN`, AND CANNOT-VERIFY IS NEVER A PASS"*). A
failed fetch prints a `WARNING` and then compares the **LOCAL** ref, *"which may be stale"* — so an `OK`
on that path is NOT proof the box is current, and the script's header says exactly that: it refuses to
compare silently, not to compare. (An earlier draft of this document dropped the word "silently" and
thereby turned a warned-but-stale comparison into a guarantee it does not give.) `--surface` extends it to *every* place a
harness script lives on the box (the running controller's dir, `$O`, the pin, every pinned snapshot,
`$HOME/orchestrator`), because #1790 measured up to **four** `orch-loop.sh` trees on one cell.
Pinned in CI by `selftest.sh` (its 15 `check-deployed-drift:` assertions — §5.1) plus a small delta suite
(`check-deployed-drift.test.sh`, §5.1) for the two things `selftest.sh` does not assert.
**DECIDED (#2710, item 3 of its scope): `scripts/harness-up`'s `exec` row owns the running-process vs
PIN question, and this script must not be asked it.** `--surface` DOES read the running controller's
directory from the process table and compares it — against **`$REF`**. It never compares the running
directory against the **PIN**, and it should not start: the two are different questions with different
definitions of the pin (`HARNESS-PIN` is a COMMIT, `HARNESS_PIN_FILE` is a DIRECTORY, and `up` refuses
unless the pair agrees), and a second implementation of that pair check is exactly the drift
`repo-slug.sh` exists to end. Measured today the skew is real — pin `130638e40658`, running
`…/harness/d4ccaf6ee8e6/…orch-loop.sh` — so a `$REF` comparison here reports drift (correct) but cannot
say "the pin and the runner disagree", which is the state that persists after a pin moves. That answer is
`scripts/harness-up`'s `exec` row (#2286, pinned by `scripts/harness-surface.test.sh`), which reads the
running controller's OWN argv and compares that tree's COMMIT with the pin. A reader who needs it asks
`harness-up`, not `check-deployed-drift --surface`; this row is written down so the next lane does not
"fix" the absence by adding the second implementation. `C6`.

**What repairs it.** 1 → reinstall from the ref (`deploy-harness.sh`), then re-run. 2 → write the stamp
/ make the dir readable; a missing stamp is not "probably fine". A pin/process skew → restart the
controller so it resolves the pin.

**state.** cell-4: **DRIFT-shaped by the running-process half** (pin ≠ running), while the stamp half is
unknowable off-box for the other three.

### 3.15 Disk — `disk-reaper.sh`

**Promises.** One entry point for the three disk sinks that stop a cell, reporting a `df` delta and
never a `du` sum.

**ALIVE vs REFUSING vs IDLE.** ALIVE = the `df` delta it prints; REFUSING = its own refusal line when
a sink cannot be proven reclaimable. `spawn-gate.sh`'s disk floor and `cloud-cell-supervisor.sh`'s
`cmd_check_disk` use **opposite polarity on purpose** (in a live dispatch path an unreadable `df` fails
**open**, because failing closed would stop every lane on the box forever; at pre-flight it fails
closed) — the reason is stated in `spawn-gate.sh`'s comment beginning *"THE POLARITY IS MIXED ON
PURPOSE"* and must not be "unified".

**What repairs it.** It is the repair. Its own failure mode is "reaped nothing because it could not
prove it was safe" — which it must say.

**state.** cell-4: 97 % used, 4649 MB free.

### 3.16 CI back-pressure — `ci-queue.sh` + `gh-limit.py`

**Promises.** (a) Do not send more CI than the queue can absorb; (b) serialise `gh` so four boxes do
not act as one rate-limited account.

**ALIVE vs REFUSING vs IDLE.** `ci-queue.sh` produces the verdict; the **consumers** are `orch-loop.sh` — which
turns it into the named gate line `GATE_WHY="${GATE_WHY:-ci-queue($CIQ_VER)}"` for the ISSUE path and withholds the CI
RERUN — and `dispatch-merge.sh`, which defers an issue→PR batch. `gh-limit` **records the limit and returns at once** (`NO_WAIT`), so
the caller sees a `RATE-LIMITED` verdict rather than an in-call sleep that outlives it.

**What it may and may not gate (measured 2026-10-27, cell 4).** Only work that ADDS a new CI run: the
issue→PR path, batch dispatch, and a rerun. **Repair is never queue-gated** — a red-check fixer, a
review-findings fixer, a conflict fixer and the PR-sickness queue all act on a PR that already exists,
so their bound is this box's lane slots and load gate instead. The basis is a decision plus a
measurement, **not** a cost claim: a repair push *does* start a fresh run. On this repo many of them
also supersede that PR's own earlier run — but **supersession is a property of the workflow, not of
"a repair push"**: only a workflow that declares a `concurrency:` group cancels its predecessor, and
a workflow with **no** `concurrency:` block stacks the new run. Enumerated by trigger at this commit,
the four workflows that fire on a PR push are `.github/workflows/ci.yml` (`group:
ci-${{ github.ref }}`, `cancel-in-progress: true`) and `.github/workflows/harness-single-source.yml`
(same shape) — these **supersede** — and `.github/workflows/pipeline-compliance.yml` plus
`.github/workflows/workflow-lock.yml`, both `pull_request*` with `[opened, synchronize, reopened,
edited]` and **no** `concurrency:` block, deliberately (#2474: a per-PR group cannot tell a head from
its successor, and a cancelled leg reads non-red — which on `pipeline-compliance` would leave the
repo's ONLY required check green-with-no-verdict on the newest tree) — these **stack**. So a repair
push DOES add a run on the required check, every time. **Name the property, not a list:** the previous
revision of this passage named one stacking workflow and there are two, which is what a hand-kept
list of filenames buys. Supersession is therefore a per-workflow detail, not the reason repair is
ungated: what the measurement showed is that the number being gated on was the wrong quantity.
Gating repair on the queue skipped **41 consecutive
dispatches in one window** while 8 self-hosted
runners and ~11 lane slots sat idle: the queue being read belonged to GitHub-HOSTED concurrency.
The ceiling's `runners` term is the fleet's registered/online size, or the account's hosted allowance
when the endpoint answers a parsed `total_count: 0`. ⛔ It is **never the in-progress job count when
nothing could be read** (branch (c)): there the term is the module's own one-runner floor and the token
names the reading that failed (`fleet=unreadable(…)`). The one branch that keeps the in-progress count
is the measured-poor one — the endpoint answered with a DECLARED fleet and nothing online — where
executing jobs are a genuine supply lower bound, and dropping it there was measured to pin the ceiling
at 2 (arm (b12)).
IDLE = the queue is below the bound; REFUSING = at/over it, with the version string naming why.

**What repairs it.** Nothing on the box — this is a *wait* state, and the remedy is fewer lanes, which
is what §3.10's placement is for.

**state.** NC on cell-4.

---

## 4. The per-machine state table (2026-10-24 14:50Z)

**Every code this table uses, decoded** — a code that is not defined is how a summary starts lying:

| code | means |
|---|---|
| `✅` | **measured** on that box, present and working |
| `❌` | **measured** on that box, absent or inert |
| `❌*` | **provably absent fleet-wide from provenance or transport, not from a per-box read** — the artifact does not exist anywhere (no source in any repo) or the channel cannot carry it (a per-repo namespace). It is `❌` on every box *because of that*, never because each box was read |
| `NC` | **no channel** — the box could not be read at all (§1.1), so its state is UNKNOWN here |
| `REC` | **recorded, not re-measured** — a prior measurement or a plist/label, carried as a record |
| `INF` | **inferred** from that box's OWN published artifact (a capacity record it wrote), not read from the box |
| `REC ✅` | a RECORD that says present/working — the box was **not** re-read in this pass; §1.1 is why |
| `REC ⚠️` | a record that also carries a known defect (named in the cell) |
| `REC (label only)` | a record whose only evidence is a plist/label on one machine — closer to a name than to a measurement |
| `⚠️` | **measured, present, but not the capability** — the surface exists and does not do the job |
| `n/a` | that machine has no such surface by design (e.g. a Linux unit on the Mac) |

| capability | cell-4 | cell-3 | cell-1 | Mac |
|---|---|---|---|---|
| controller cycling | ✅ `HEALTHY age=180`, 355 cycles | INF from its 14:47:40Z capacity record | NC | REC ✅ |
| one supervisor, one controller | ⚠️ two supervisors / one controller (§3.2) | NC | NC | REC ✅ (tmux entrypoint) |
| `eldato-orchestrator` unit | ⚠️ active **and waiting for a foreign pid** — it does not own the controller (§3.2) | NC | NC | n/a (launchd) |
| merge rail present | ✅ | NC | NC | REC ✅ |
| **landing happens** | ✅ 2 merges at 14:47Z | NC | NC | REC ✅ |
| landing **attributed to a box** | ❌ nowhere | ❌* | ❌* | ❌* |
| `pr-doctor` running | ❌ (log 2 d old, 0 procs) | NC | NC | REC ✅ |
| `pr-doctor` survives its session | ❌ no unit | NC | NC | REC ✅ (with TCC caveat) |
| `nonblocking-dispatch` takes `prfix` | ✅ | NC | NC | NC |
| `auto-rail` actuator | ❌* no source in any repo | ❌* | ❌* | REC (label only) |
| precedence rule (merge before new work) | ✅ in code + observed in the cycle record | NC | NC | NC |
| placement seam present | ✅ | INF (publishes) | NC | REC ✅ (publishes) |
| **placement sees more than one box** | ❌ (§3.10) | ❌* | ❌* | ❌* |
| `check-deployed-drift` | ✅ present; pin ≠ running (§1.3) | NC | NC | REC ⚠️ (remedy destroys — baseline §3.1) |
| disk above floor | ✅ (4649 MB ≈ 97 % used) | NC | NC | NC |

**What the ❌s mean, read column by column** (the table above distinguishes a MEASURED cell from one
INFERRED from the box's own published record and from one RECORDED off-box, so this summary must not
flatten them again — and neither should a reader who quotes only this list):

- **Landing attribution: `❌` on cell-4, `❌*` on the other three** — no record anywhere names the box
  that landed a PR (the land path has no host field at all, which is what `❌*` means).
- **`pr-doctor`'s activation and survivability: `❌` on cell-4, `NC` on cell-3 and cell-1 (no read
  channel), `REC ✅` on the Mac** — the Mac's ✅ is a RECORD, not a re-measurement.
  Both of those are `C5` (#2709).
- **`❌*` on every cell, `REC (label only)` on the Mac**: `auto-rail`'s provenance — it has no source in
  any repo (a fleet-wide provenance fact, not four per-box reads), so the Mac's label is a RECORD, not a
  measurement. → `C5` (#2709).
- **`❌` on cell-4, `❌*` on the other three**: the fleet view — the transport is per work-repo, so no box
  can see another (`❌*`: a fact about the channel, not a read of each peer). → `C3` (#2707).
- **`C6`** (#2710) is not one of these rows: it is the *shape* of the answer for all of them — a
  refusal must carry a name, a reason and a next action, and `UNKNOWN` must never be a pass.

---

## 5. What has an effect-based self-test in CI, and what does not

CI means `scripts/run-bash-shards.sh` — **the one list both lanes call**
(`.github/workflows/ci.yml` job `bash-suites`; `.github/workflows/ci-main.yml` job `script-validate`),
plus the pytest list in `ci.yml`'s single `python3.12 -m pytest …` step. ⛔ **No shard count is
written down here on purpose**: an earlier draft froze a number, which was stale the moment this PR added
a shard, and a live count rots on every subsequent PR exactly as a line number does (§2). Ask the file:
`bash scripts/run-bash-shards.sh --list | wc -l`.

### 5.1 Already proven by an effect test (name the shard, not the file)

| capability | suite (a shard in BOTH lanes) | the EFFECT it asserts |
|---|---|---|
| merge rail + evidence contract | `tests/admin-merge/run.sh`, `tests/admin-merge-evidence-contract/run.sh`, `tests/gh-shim/run.sh` | a merge is REFUSED without head-bound evidence; the certificate contract is pinned against a **real captured** evidence comment |
| review recorded | `tests/record-review/run.sh`, `tests/review-pr/run.sh`, `scripts/record-review.test.sh` | a clean verdict is recorded **bound to the reviewed head**; findings are not recorded (exit 7); a base-only move CARRYs and lane work REFUSES |
| placement decision | `scripts/orchestrator-harness/capacity-placement.test.sh` §8 | two boxes publish as **real pushes** to a **real local bare origin** and the idle one is CHOSEN |
| controller cycling | same suite §6/§7 | a two-cycle-stale record is `DEGRADED`, an absent one `ABSENT`, **never HEALTHY** |
| precedence rule | `scripts/orchestrator-harness/test-gates.sh` | `mp_reason` extracted from the LIVE script: 1 un-owned PR closes the gate, an unreadable count drains |
| spawn gate | `scripts/orchestrator-harness/spawn-gate.test.sh` | the gate refuses and ledgers |
| repair actuator | `scripts/test_pr_doctor.py` §10 | `rc=2` has exactly one meaning and **the record always agrees with launchd**; and (#2710) a pass whose only outcome was a durable worktree refusal exits `3`, not `0`, with the row and its repair named once it has refused `REFUSAL_ESCALATE_AT` times in a row |
| classifier | `scripts/test_objective.py` (the #2710 block) | the exit code agrees with the line by ALLOW-LIST (every refusing verdict, and a word nobody has taught it, exit `2`; the four readable ones exit `0`), a repo/checkout mismatch refuses **before any read**, and every line names `repo=`/`repo_src=` so the silent default cannot come back |
| inert-capability class itself — repo binding, fail-closed required set, reaper live-cwd | `tests/inert-capability-effects/run.sh` (§1–§3, landed in #2757) | the SHIPPED `_objective()` returns the CHECKOUT's repo (and a named REFUSAL when the origin is unreadable, never the `tortoise` default); an unreadable branch protection is **not** an empty required set (the same function, one byte of `gh` behaviour apart, yields OPPOSITE merge authorities); a live holder whose cwd is a SUBDIRECTORY keeps its tree **and its identical twin is removed in the same pass**. ⛔ **Fixed here (#2708): §3 could never pass** — the fixture creates its trees seconds before the pass and did not override `REAP_WT_MIN_AGE_MINUTES`, so rule 7's 45-min floor preserved **everything** (`reasons=too-young:2`) and both removal arms were red on every box, i.e. the live-cwd gate it exists to pin had no working test at all while the suite reported covering it. Verified by removing the one-line override again: `…the holder-free twin was not removed either, so the preserve arm proves nothing`, `2 of 16 assertion(s) failed` |
| repair actuator — **which copy judged the brief** **(#2708)** | `scripts/test_pr_doctor.py` — `test_a_refused_brief_NAMES_the_copy_of_the_gate_that_judged_it` | the brief the doctor **COMPOSES** is accepted by the gate the dispatcher **RESOLVES** (agreement, not construction); and when it is refused, the refusal **NAMES the `brief-gate.sh` path that judged it** (`nonblocking-dispatch.sh` prints `$bg_lib`), so an operator is sent to the copy that refused rather than the copy they just fixed — ⛔ and the naming line is emitted BEFORE the gate's ~3.3 KB teaching block, because `pr-doctor` logs only `detail[:160]` on its not-dispatched line (`scripts/pr-doctor.py:5093`): appended after it, the path sat at byte ~3290 of ~3655 and both slices cut it off (measured; that was this change's own review finding). ⚠️ **The bound is the ORDERING plus the path LENGTH** (#2986 review, P1 — the first form of this arm was RED on macOS): the path starts at char 53, so the whole path fits the 160-char slice whenever the resolved path is ≤ 107 chars — true of every production `$O` (the path a real box RESOLVES is `$O/brief-gate.sh`, `$O` defaulting to `$HOME/orchestrator` — 27 + `len($HOME)` chars, 41 in this fleet; the `$HOME/.pi/agent/scripts` candidate is only the fourth fallback, at 32 + `len($HOME)`) — 44-52 in practice) — while a longer resolved path shows a truncated tail. The arm therefore grades the offset (box-independent) and asserts the full path inside `detail[:160]` against a **production-length `$O`** (`/tmp/oXXXXXX`), not against a pytest temp root, whose length is a property of the box's `$TMPDIR` |
| deployment provenance | `scripts/orchestrator-harness/selftest.sh` — its deployed-drift block: 24 assertions, 15 of them carrying the `check-deployed-drift:` prefix (the other 9 grade `install.sh`'s stamp writer, its provenance fields, and a git-absent fallback) | through the SHIPPED script: match→0, a dirty source→1, a post-install edit→1, a missing record→2, `commit: UNKNOWN`→2, an unresolvable ref→2, an unknown commit object→2, BEHIND→1, a missing shipped file→1, an extra hand-placed script→1, a failed `mktemp`→2, an unreadable deployed `*.sh`→2 |
| deployment provenance — **which file** | `scripts/orchestrator-harness/check-deployed-drift.test.sh` **(new here, #2700)** | a **one-byte** difference is `DRIFT` (1) and the report **NAMES that file** (and not the unchanged one); restoring the byte is `OK` (0) again; and the suite asserts its own presence in the shard list |
| supervisor / reaper / cell surface | `scripts/harness-cohesion.test.sh`, `scripts/orchestrator-harness/install-launchd-durability.test.sh`, `scripts/cloud-cell-supervisor.test.sh` | a drifted copy is NAMED and an unreadable one is BROKEN (2, never OK); a redeploy cannot persistently disable the entrypoint; and a `keys.env` top-level exit cannot turn a failed cell start into a silent success |

⛔ **The new suite is a DELTA, not a second implementation — and a mutant proves it.** `selftest.sh`
asserts exit CODES; it cannot see a report that stops naming the file. Measured: replacing the
file-level `drift` call so the report keeps the path but loses the `the deployed copy DIFFERS` verdict
reds **exactly one** arm of the new suite — the one asserting that verdict — while every `selftest.sh`
arm stays green. That is the arm's reason to exist: `selftest.sh` grades EXIT CODES, and this mutant
changes no exit code, so its 15 arms cannot see the loss. (The arm greps a FIXED string that
contains the filename, so a report printing no filename cannot satisfy it; the real residual is the mirror
image — a report that names the file in a DIFFERENT format reds this arm too, i.e. the arm pins the wording,
not merely the presence of the name.)

Its non-vacuity is also **structural**: §1/§2/§3 are one fixture, **one byte apart**, with opposite
verdicts — a check that cannot see a one-byte change fails §2, and a check that is permanently red fails
§1.

**The retained arm's non-vacuity is TWO mutations that were RUN** (#2708, re-run after the rebase onto
#2978). M3 and M4 below are the only mutations this change's remaining diff can be graded by; M1, M2,
M5 and M6 graded the pass-verdict cut that #2978 landed independently, and they are recorded here as
⛔ **DO NOT APPLY** — the arms they reddened (`§14.1–14.4`) were removed with that cut, so re-applying
them to this diff grades a mechanism the file no longer has.

| mutation (the shape each capability actually went inert in) | reds | ⛔ status |
|---|---|---|
| **M3** `research_section()` returns `""` — the pre-#2258 stale copy that shipped section-less briefs (measured case 2: 9 h of `rc=80`) | `test_a_refused_brief_NAMES_the_copy_of_the_gate_that_judged_it` (the composed brief stops passing the gate) | live — RUN |
| **M4** drop `$bg_lib` from the dispatcher's refusal text — a refusal that does not name the copy that judged it (measured case 3: the fix landed on a copy that does not run) | the same test (the refusal stops naming which copy judged it) | live — RUN |
| **M1** verdict back on `undeliverable` alone (the pre-#2708 line) | `§14.1–14.3` + a retargeted arm | ⛔ DO NOT APPLY — superseded by #2978, its tests live in `test_pr_doctor.py`'s #2710 block |
| **M2** drop the queue-derived refusal axis | `§14.3` | ⛔ DO NOT APPLY — #2978 fixed the gate-order dependence by VOIDING a refused row's budget slot, not by charging it |
| **M5** stop naming a refusal on a pass that DID dispatch | `§14.4`'s second arm | ⛔ DO NOT APPLY — that sentence is #2978's `parts` block |
| **M6** append the refusal sentence after the stall counters | `§14.1–14.3` on the 110-char slice | ⛔ **WRONG AS ORIGINALLY RECORDED, AND DO NOT APPLY TWICE OVER** — (a) the placement moved with the superseded cut; (b) review cycle 2 falsified the CLAIM itself. The counters this code emitted were short (`refused-recorded=3; `, `budget=4; `), so `REFUSED` landed at char ~21-31 under EITHER order and every `reason[:110]` assertion still passed: a reorder would have gone green everywhere. The run that "confirmed" it used a malformed mutant (the `stalls` loop was moved too), so those reds came from a mangled parts assembly and not from the ordering. The finding that survives is the reviewer's arithmetic, and the property actually worth pinning is the **word** surviving the cut — which #2978's `parts` block owns now |

**Re-running M3/M4 is two small edits.** Each is a single edit applied to a **copy** of the tree (so the
box's own checkout is never mutated mid-run) and graded with
`python3 -m pytest scripts/test_pr_doctor.py -q -k NAMES_the_copy_of_the_gate`

M4 is the one that matters most for the *class*: it changes **no exit code and adds or removes no log line** anywhere
— the refusal still exits 80 with the same teaching message — so every exit-code assertion in the tree
stays green while the operator is once again sent to the copy they already fixed. That is why the arm
asserts the PATH, not the verdict. ⚠️ The text of ONE line does move, and it is the one this change is
about: `detail` loses `brief-gate=<path>` (`pr-doctor.py:3766-3767` builds it; `:3768` is the FAIL
line that logs `detail[:200]`, `:5093` renders `detail[:160]`), which is exactly the field the arm reads.

⛔ **A correction, recorded rather than rewritten:** an earlier draft of this section explained
`§14.3` with the sentence "a refusal row charges its capacity class, so at the shipped `MAX_FIX`=3 three
refused rows zero the class budget". That was true of #2708's own cut and is **false of the shipped
file**: #2978 landed the opposite resolution — *a refusal consumed nothing, so it must not hold a
budget slot* — and a reader who applied the deleted sentence would reintroduce the defect. The
mechanism is `pass_budgets()`'s `kind == "refused"` skip, and the contract above states it.

### 5.2 Capabilities with NO suite of their own (the honest gap list)

**The standard, applied once:** "exercised end-to-end from a shard that drives the shipped file" counts
as coverage (that is what `selftest.sh` does for `check-deployed-drift.sh` and `install.sh`, and what
`test_pr_doctor.py` does for `nonblocking-dispatch.sh`). "No suite AND not driven end-to-end anywhere"
is the gap list.

- `merge-one.sh`, `dispatch-merge.sh`, `chain-merge.sh`, `fix-one.sh`, `adopt-fix.sh`
- `repo-authority.sh` (copied by `landing-read.test.sh`, not graded), `repo-slug.sh`
- `rail-refusal.sh` (asserted from inside `red-fixer.test.sh`)
- `report.sh` and `box-status.sh` — driven, but neither has a suite of its own: `report.sh` from `test-gates.sh`, `box-status.sh` from `merge-reminder.test.sh` §16
- `launchd-controller.sh`, `launchd-cycle.sh` (their durability arm is `install-launchd-durability.test.sh`)

None of these is a *new* finding (they are named here so the gap is a list, not a surprise); `C2` (#2708)
owns the decision about which of them earns a test — starting from the ones whose inertness would be
invisible, i.e. `merge-one.sh` and `dispatch-merge.sh`.

⛔ **#2708's first cuts went at the capability where inertness is MOST invisible, not at the list above**
— `pr-doctor`'s own pass verdict, which is the one whose "I am running" and "I am refusing" states were
measured indistinguishable three times in one day (2026-10-28). Those rows are now in §5.1. The list in
this section is unchanged by that work: it is still the gap, and `merge-one.sh` / `dispatch-merge.sh` are
still where the next cut should start.

---

## 6. Decisions this file obeys, and the one it must not re-open

- **`MERGE_PRIORITY_AT` is NOT a threshold, and re-introducing one is a reopen.** Owner ruling
  2026-10-18 (#2099): *"for as long as ANY workable un-owned PR remains, issues are not opened — no
  threshold, no age, no evidence arm, no exception for a stalled drain"*. The number 25 survives
  **only** as the fail-closed fallback when the un-owned count is unreadable, and as the reviewer/
  fixer budget scaling.
  **OVERRIDES:** the "WIP limit / stop-starting threshold N" pattern common to Kanban and every
  merge-queue scheduler — the fleet decided against a number here, because a gate whose opening
  condition the automation cannot meet is a **drain defect, not a licence to open the gate**
  (measured 2026-10-18: three cells at `52 unowned of 54 open PRs`, `lanes=0`, for HOURS).
- **Dispatch is gated on capacity, not on a lane count.** Owner ruling 2026-10-17: *"dispatch should be
  gated on capacity, not on number of lanes"* (`MAX_LANES` is 2.5×cores as a derived *ceiling*, and
  `capacity.sh` explicitly refuses to be a lane cap).
- **An unreadable instrument is not a refusal, in a live dispatch path.** `spawn-gate.sh`'s disk gate
  fails **open** on an unreadable `df` and says why; pre-flight checks fail closed. Do not "unify" the
  polarity.
- **No capability may be turned off by making its test unable to fail.** A test that supplies the thing
  production lacks (a unique `CAP_HOST`, a pre-made record) is the pattern this epic exists to end — so
  a test's fixture seam must be named in its comment as a seam, and the production path named in the
  contract (§3.10).
- **Two verdicts are deliberately NOT three-valued, and that is a decision, not a gap (#2710, its scope
  item 5).** `cycle_verdict`'s `HEALTHY` grades *cycling*, not *effect*: a draining box with
  `dispatched=0` and a named gate is healthy, and §3.1 says so. `admin-merge.sh` has no rc table at all
  because it acts on ONE PR when asked and has no IDLE state; its refuse/wait split lives in its caller
  (`lander.sh`, §3.4). ⛔ **Do not "fix" either into a three-valued verdict**: the effect the reader
  wants is on the FIELDS (`dispatched=`/`nothing=`/`gate:`; the rail's `BLOCK — <reason>`), and a verdict
  that absorbed a refusal would be the exact defect this contract exists to remove. A capability that
  does grade effect three-valuedly (`objective.py`, `pr-doctor.py`, `capacity.sh`, `check-deployed-drift.sh`)
  must do it in BOTH its line and its exit code, per §2's polarity rule.

---

## 7. The children (what is still missing, and what each one depends on)

| id | child | depends on | why it is not in this file |
|---|---|---|---|
| **C1** | this contract | — | *(this document)* |
| **C2** | **#2708** — effect-based self-tests for the capabilities in §5.2 that earn one | C1 | the pattern is proven (§5.1); applying it 8× is its own work |
| **C3** | **#2707** — the fleet view: a per-box identity + a transport that is not partitioned by work repo (and a `cap_place` that refuses to decide on a fleet of one) | C1 | needs a design decision with a measured basis; §3.10 carries the evidence |
| **C4** | merge precedence — **already shipped** (#2099 / #2126 / #2203), observable, and pinned by `test-gates.sh` | — | **no child filed**: it exists. The epic's "threshold" phrasing is superseded by the #2099 ruling (§6) |
| **C5** | **#2709** — per-machine parity + activation: `pr-doctor` and a land actuator on every cell, an `auto-rail` that has a source, and one parity surface | C1, C2, #2135, #2345, #1761 | blocked on a read channel (§1.1) and on the cell doctor's own inert role pass |
| **C6** | **#2710** — "refusal is a verdict": a refusal carries a NAME, a REASON and a NEXT ACTION on every capability, and `UNKNOWN` is never a pass | C1, #2291 | **Landed:** `objective.py` (§3.7) and the repair actuator (§3.6) both refuse in the line AND the code, and §3.14 records who owns running-vs-pin. **Still open on this child:** the remaining capabilities' exit codes have not been graded against the §2 polarity rule (each needs its own measurement before it is changed), and `#2291` still owns separating "the box has no room" from "the transport refused" |

Every child carries the same research mandate as the epic: **read
`~/.pi/agent/state/TORTOISE-GRAPH-BRIEF.md` → run the contradiction test → read the artifacts named
here → `research` skill for SOTA → only then design.** ⛔ The Tortoise graph was **unreachable from
this box** (`docker://:@localhost:16379` is a Mac-local address; port closed here), so the
contradiction test in this lane was run against the **in-repo** decision record (§6) — a child that
can reach the graph must re-run it there before adopting anything.
