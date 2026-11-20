# agent-infra#2159 — a disk term in the drainer's capacity target

Status: PLAN (pre-build). Worktree `fix/2159-disk-term`, base `b237f14b6`.

## Problem (measured, not inferred)

`ai-drainer.sh`'s capacity formula is

    target = min( cpu_ceiling , mem_ceiling )

with `cpu_ceiling = floor(ncpu × 5/2)` and `mem_ceiling = (MemAvailable − MIN_MEM_FREE_MB) × 75% ÷ 512`.
**There is no disk term**, so the tick plans a lane count from memory and cores alone and
only discovers the disk when a lane dies.

Measured on pi-cell-4, 2026-11-19, from the drainer's own log (`~/.pi/../orchestrator-ai/logs/ai-drainer.log`):

    23:28:03Z  START: target=22 (cpu=40 mem=22 from mem_avail=16188MB …) alive=15 … dispatching 7
    FAILED EARLY: ai-drain-232803-…-1 started and exited rc=77 — NO LANE IS RUNNING.
      last log line: [disk-gate] REFUSED … DISK-NOHEADROOM REFUSED-DISK(free=1.7GB, need=2.0GB …)
                     only 1721MB is available … This is NOT a load refusal: waiting does not clear it
    23:28:05Z  FAIL: dispatcher refused (…) on ai-drain-…-1 — dispatched 0 of 7
    systemd:   eldato-ai-drainer.service: Failed with result 'exit-code'   → unit RED

Three separate costs in one tick:

1. **The target is a fiction.** `target=22` was computed on a box with 1.7 GB free whose per-lane
   requirement is 2,064 MB. The number cannot be reached and nothing in the line says so.
2. **A box fact is reported as a tick failure.** A full volume is not a defect in the drainer; it is
   the box refusing work. The unit goes red, and `systemctl --failed` then hides real failures behind
   a known-benign one.
3. **The tick stops at the first refusal with exit 1** (0 of 7), so the lanes that *could* have run
   later in the tick never start.

`dispatch-merge.sh` already takes the right disposition for the same refusal — "releases the claims
of the unspawned remainder … and **stops the batch**, because a full volume is a fact about the box
rather than about one issue". The drainer has no equivalent.

## Research

### INTERNAL (checked artifact)

* `scripts/orchestrator-harness/ai-drainer.sh:41-56` — the formula and its constants. Memory and CPU
  are each documented with a measurement; `grep -n 'df \|DISK\|statvfs' ai-drainer.sh` before this
  change returned **comments only**, and the memory-pressure arm is Darwin-only.
* `scripts/orchestrator-harness/spawn-gate.sh:243-267,585-620,730-815` — the ONE disk predicate
  (`disk_free_mb`, `disk_readable`, `disk_lane_costs`, `disk_lane_need`, `disk_worktree_need`,
  `disk_free_mb_target`). `disk_lane_need(t,s,r) = max(t,s) + r`. It is a **library**: the file's
  last block is `if [ "${BASH_SOURCE[0]:-}" = "$0" ]; then pi_shim_main "$@"; fi`, so sourcing it runs
  no main. Verified empirically in a subshell: `SRC_RC=0`, `disk_worktree_need` → `8144`,
  `disk_free_mb /` → `12409`.
* `scripts/orchestrator-harness/README.md` §7.2i — "the disk gate existed and ran one step too late"
  (#3395): the gate lived inside `run_agent`, i.e. AFTER `wt_provision`, so on a full volume it was
  never reached. The fix introduced the PRE-START seam asked *before* `git worktree add`.
* `docs/ops/disk-reaper.md:1868-2012` — the refusal shape, and the recorded rule that a box whose
  lanes are measured cheaper lowers `DISK_LANE_SELF_MB`/`DISK_LANE_RESERVE_MB` **deliberately**.
* agent-infra#2159 (OPEN) — "disk caps lanes regardless of reaping". Its subject is exactly this
  formula; the turn-8 measurement of it is comment 7025828992.
* The test suite's own neutralisation idiom (`ai-drainer.test.sh:25-31`): the `DISK_*` terms are
  exported at the top so the suite's verdict is never decided by the host's free space. An explicit
  `0` is honoured by `disk_lane_costs`/`disk_worktree_terms` as a STATED choice.

### EXTERNAL (rung 3 — primary source)

`statvfs(3)`, man-pages 5.07 (`man7.org/linux/man-pages/man2/statvfs.2.html`), verbatim field comments:

    fsblkcnt_t f_bfree;  /* Number of free blocks */
    fsblkcnt_t f_bavail; /* Number of free blocks for unprivileged users */

⇒ the number a lane may use is **`f_bavail`**, which is what `df -Pk` column 4 ("Available")
reports — not `f_bfree` and not `f_blocks − f_bused`. Confirmed on this box, where the two differ by
the filesystem's root reserve:

    $ df -h /
    /dev/root  252G  230G  12G  96% /        →  Size − Used = 22G "computed", Avail = 12G

A `total − used` derivation would over-report by ~10 GB here — i.e. by ~5 lanes at 2,064 MB — which is
precisely the false-PASS direction. `spawn-gate.sh`'s `disk_free_mb` already reads column 4, so the
fix routes through it rather than re-deriving.

### CONTRADICTION TEST

* **#2159 (open) asks for this.** No recorded decision states that the drainer's target must remain
  cpu+mem only; the header's own `OVERRIDES:` blocks are about *which* swap/memory signal to read, not
  about excluding disk.
* **#1678 (owner, 2026-10-11) — "arming a DELETION tool is an owner-level consequence decision"** — is
  **not** touched: this change deletes nothing, arms nothing, and widens no reaper's census.
* **tortoise#9878 / #5215 / agent-infra#2344** (label routing to the self-hosted pool) — untouched:
  no `runs-on` label changes.
* **`MEM_PER_RUNNER_MB` / `LANE_MEM_MB` calibrations** — untouched; this adds a term, it does not
  re-derive an existing one.

## Design

### D1 — the term

    disk_ceiling = floor( (free_mb − DISK_MIN_FREE_MB) ÷ need_mb )       (0 when free is below the floor)
    target       = min( cpu_ceiling , mem_ceiling , disk_ceiling )

### D2 — no new literal for the per-lane need

`need_mb` comes from `disk_lane_costs` + `disk_lane_need` in `spawn-gate.sh`, applied to `$SEED_REPO`
(the checkout the lanes actually work). This is the "one predicate" rule the tree already enforces
(#3395's two-seams-one-number defect): the drainer must not charge a number the gate that refuses the
lane would disagree with. On this box that predicate yields **2,064 MB** for the harness target —
byte-identical to the `need=2.0GB` in the measured refusal above.

`spawn-gate.sh` is sourced in a **subshell**, which is this repo's own documented way to use a module
without letting it poison the caller ("A subshell cannot poison this shell, so the winner is the only
file ever sourced"). The module is resolved by a `SPAWN_GATE_MOD` seam, then `$O/` and `SELF_DIR`,
with the same three-part miss reason `capacity.sh`'s `fleet_line` already uses.

### D3 — free space on the volume the worktrees land on

`disk_free_mb "$AI"` — the tick creates `$AI/wt-drainer-<name>`, so `$AI` is the volume whose headroom
decides the target. `disk_free_mb_target` is not needed here (the drainer has already `mkdir -p`'d
`$AI/state`), but is used as the resolver if `$AI` is unreadable.

### D4 — the floor is the existing one

`DISK_MIN_FREE_MB`, taken from the SAME declaration `spawn-gate.sh` uses (`${DISK_MIN_FREE_MB:-${MIN_FREE_MB:-500}}`,
clamped to `[1, 249999999]`). A second floor would be a second answer to "is this volume full".

### D5 — polarity

* **readable reading** → compare. `free < floor` ⇒ `disk_ceiling = 0`.
* **unreadable reading** ⇒ **FAIL the tick, naming the probe** — the file's own posture for memory
  (`FAIL: available memory could not be read … the memory ceiling cannot be evaluated`, exit 1) and
  for swap. A guard that could not be evaluated must not look like an idle box, and a drainer that
  planned lanes blind would be the fail-OPEN the live arm is allowed to take *because* it costs one
  lane, not a whole tick's plan.
* **`need_mb = 0`** (the documented neutralisation idiom, and `spawn-gate`'s own "an explicit 0 is
  honoured") ⇒ **no disk term**, and a `NOTE:` line says the term is disabled. An exclusion a reader
  cannot see is the same defect one layer down.

### D6 — the term is re-asked INSIDE the loop, before each worktree

The target is computed once at tick start; free space then *shrinks as the tick creates its own
worktrees*, so by lane 2 the number is stale in exactly the direction that fails. The pre-start
seam's own doctrine is to ask **before** `git worktree add`, so the loop asks again:

    STOP: disk floor reached after N of M lane(s) — free=<mb> need=<mb> floor=<mb> …

and `finish 0`, because a full volume is a fact about the box, not a failure of the tick (the
disposition `dispatch-merge.sh` already takes). The lanes already dispatched keep their records:
their `DISPATCHED:` lines stand and are counted by the next tick.

### D7 — the reading is auditable

`START:`/`SKIP:` carry `disk=<ceiling> free=<mb> need=<mb>`, so the binding term is visible without
arithmetic. The existing parenthetical prefix (`target=2 (cpu=20 mem=2`) is preserved so current
assertions keep their meaning.

## Review Scope Contract

| # | In scope |
|---|---|
| R1 | `_capacity_target` returns the disk ceiling and free/need, and `target` is the min of THREE terms |
| R2 | the per-lane need is the existing predicate (no second literal); the module-miss is NAMED |
| R3 | free space is column 4 (`f_bavail`) on the volume the worktrees land on |
| R4 | floor is the existing `DISK_MIN_FREE_MB` declaration |
| R5 | unreadable probe FAILS the tick naming the probe (not 0 lanes, not silence) |
| R6 | `need = 0` disables the term AND says so |
| R7 | in-loop re-check before each `git worktree add`, stopping cleanly with a named line |
| R8 | `DISK_FREE_MB` / `DISK_LANE_NEED_MB` / `SPAWN_GATE_MOD` injected seams for hermetic arms |
| R9 | no deletion, no reaper arming, no census widening (#1678) |
| R10 | existing arms (`e4`/`e5`/`e6`) keep their meaning — the new term must not decide them |
| R11 | every new line names its numbers; a refusal without numbers is indistinguishable from a bug |

**Out of scope (stated):** the race where free space drops between the in-loop check and the
dispatcher's own gate still reports `FAIL`/exit 1 — filed as a residual, not fixed here; and the
`run_agent` live arm's fail-open, which is that arm's documented posture.

## Test arms planned

| arm | shape |
|---|---|
| (k1) | disk ceiling BINDS below cpu and mem, `target` = disk, and the line names all three |
| (k2) | free between floor and floor+need → `disk=0`, nothing dispatched, **exit 0** |
| (k3) | the floor is subtracted (free == floor+need admits exactly 1) |
| (k4) | unreadable reading → FAIL naming the probe, nothing dispatched |
| (k5) | `DISK_LANE_NEED_MB=0` → term disabled, NOTE emitted, cpu/mem decide |
| (k6) | in-loop: the disk falls after the target is computed → `STOP: disk …` after the lanes that fit, exit 0 |
| (k7) | the existing (e4)/(e5)/(e6) assertions unchanged (regression) |

## Mutation proof planned

M1 drop the disk term from the `min` · M2 drop the floor subtraction · M3 remove the in-loop check ·
M4 fold `unreadable` into 0 without the FAIL · M5 disable the term at `need=0` silently (no NOTE).

---

## PLAN-VERIFY round 1 — 11 findings, all verified against source, all applied

Fresh-context verifier, adversarially briefed. Every finding below was re-checked against the cited
line before being accepted; all 11 were real. The two that would have shipped a defect:

* **the 4-field `read`.** `read -r target cpu_ceil mem_ceil mem_pool <<<"$(_capacity_target)"` folds
  every trailing field into the LAST variable. Appending `disk/free/need` makes
  `mem_pool="1488 5 12285 2064"` and prints `pool=1488 5 12285 2064MB@75%/512MB`. Nothing greps
  `pool=`, so it would have shipped silently. → **D8**.
* **`TARGET_LANES` bypasses the whole term**, and the pin is the *default state* of most test arms
  (`RUN_TARGET=3`). A disk term inside `_capacity_target` is discarded on a pinned box, i.e. #2159
  would be unfixed on exactly the boxes that pin. → **D9**, with an explicit decision.

### D8 — the contract change is named, and the field ORDER is asserted

`_capacity_target` prints SEVEN fields and the call site reads SEVEN:

    read -r target cpu_ceil mem_ceil mem_pool disk_ceil disk_free disk_need <<<"$(_capacity_target)"

New arm (k0) asserts the line's field count and order, not a substring — so a later eighth field
cannot repeat this defect. `docs/ops/ai-drainer.md`'s `target=…` examples are updated.

### D9 — a pin overrides the DERIVED ceilings, not a HARD GUARD (decision, stated)

Recorded structure of this file: the swap floor and the load arm are checked **before**
`_capacity_target` and are **not** subject to `TARGET_LANES`; cpu/mem are *derived ceilings* and
**are**. The disk term is a derived ceiling of the same kind, so **the pin overrides it** — a pin is
"The operator's explicit call" and `TARGET_LANES` is already the documented way to stop dispatch.

But the in-loop pre-check (D6) is a **hard guard**: it is asked immediately before `git worktree add`,
it is not bypassable, and a pinned box therefore still cannot create worktrees past the disk floor.
That keeps #2159's real cost (dying at `git worktree add`, or being refused by the spawn gate one
step later) closed on pinned boxes too, while the pin keeps meaning what it means.

New arm (k8) proves BOTH halves: a pin above the disk ceiling still plans the pin, and the loop still
stops at the floor.

### D10 — the module-miss polarity (a case D5 did not cover)

`need_mb` is UNKNOWN when `spawn-gate.sh` is absent, stale, or dies at source time. **An EMPTY
subshell output is the miss, never `need = 0`** — the two are distinguishable because the probe prints
a number or nothing, and the `need=0` branch is reached only by a *parsed* `0`.

Polarity: **FAIL the tick, naming the module and both candidate paths** — the disk term *is* the plan,
so an unknown need cannot produce a plan (D5's own argument). This is deliberately NOT the `_num`
"warn and default" shape, and NOT `fleet_line`'s continue-with-a-reason shape (that is a REPORTING
instrument; this is a gate). The operator escape hatch is a stated `DISK_LANE_NEED_MB`.

### D11 — `need = 0` is a BRANCH BEFORE THE DIVISION

`$(( x / 0 ))` does not return 0, it **kills the shell** (`division by 0`), so under `set -u` the tick
would abort mid-lock with no `FAIL:` and no `STOP:` line — the worst possible shape. The disabled
state is therefore tested before any arithmetic, the in-loop check is skipped in that state, and arm
(k5) asserts the tick SURVIVES `DISK_LANE_NEED_MB=0` (a crash there is the most likely implementation
defect, not a hypothetical).

### D12 — `DISK_FREE_MB` is validated by the PROBE shape, never by `_num`

`_num` folds garbage into a default and continues (`ai-drainer.sh:297-307`); the probes deliberately do
not use it (`:566-568`, `:571-573`, `:594-596`, with the reasoning at `:583-587`: "`_num` would fold
`unreadable` into 0 … The seam must drive the same fail-closed path"). `DISK_FREE_MB` follows the
probe shape: `case "$v" in ''|*[!0-9]*) … FAIL … exit 1 ;; esac`.

### D13 — the disk fields go at the END of the parenthetical

Existing assertions are contiguous-substring greps (`:484` `mem=0 from mem_avail=600MB`; `:494`
`target=10 (cpu=10 mem=`; `:505` `target=2 (cpu=20 mem=2`; `:255` `START: target=3 (PINNED by
TARGET_LANES) alive=0 .* dispatching 3 `). The literal shape, therefore:

    target=<t> (cpu=<c> mem=<m> from mem_avail=<a>MB pool=<p>MB@<pct>%/<lane>MB disk=<d> free=<f> need=<n>)

and the PINNED line gains `; disk=<d> free=<f> need=<n>` after its own text. (e4) at `:484` is the arm
that catches a mid-string insertion, and k7 keeps it.

### D14 — fail-closed is argued on its own grounds, not inherited

The predicate being borrowed **fails open** on its live arm (`spawn-gate.sh:271-276` `disk_ok` returns
ALLOWED on an unreadable reading; `README.md:5775` records `run_agent` as "fail-**OPEN** on an
unreadable probe"). The drainer does NOT inherit that, and says why: that fail-open protects a *running
fleet* from a bad probe in exchange for one lane; here the probe decides **how many lanes to create**,
so the same trade would produce a whole tick's plan from nothing. `README.md:5788`'s "two postures,
one predicate" is the recorded precedent for exactly this split.

### D15 — which predicate, named (an implementer could land a 4× over-block)

The term uses **`disk_lane_costs <seed-repo>` + `disk_lane_need`** — the LIVE arm's pair, classified
against the checkout the lanes work — and deliberately **NOT `disk_worktree_need`**, which is the
repo-blind PRE-START worst case (8,144 MB) and would plan **1** lane where ~5 fit (12,285 MB free).
Measured in this worktree: `disk_lane_costs .` → `64 64 2000`, `disk_lane_need` → **2064**;
`disk_worktree_need` → **8144**.

⚠️ **The number is repo-class dependent, and that is stated rather than smoothed:** on a
`python_target` seed the same pair returns **8144**, so "2,064 MB" is a statement about an
*agent-infra* seed, not a constant. The START line prints `need=`, so the binding number is always
visible.

### D16 — the residual keeps its line numbers, and the fix is not overstated

`ai-drainer.sh:1908-1910` (`FAIL: cannot create a worktree … exit 1`) and `:1912-1914`
(`FAIL: dispatcher refused … exit 1`) both still exit 1. The measured incident took the SECOND path.
After D1+D6 the tick stops before either on a full volume, but if free space falls between the in-loop
check and the spawn gate the unit can still go red on a full volume. **That is by design and it is
named**, not filed as fixed.

### D17 — file inventory (four artifacts would otherwise go stale)

| file | what changes |
|---|---|
| `scripts/orchestrator-harness/ai-drainer.sh` | header formula `:45`; "NO RUN-AWAY" `:155-160`; `_capacity_target` `:1614-1624`; call site `:1814-1819`; probe block; dispatch loop `:1905-1915` |
| `scripts/orchestrator-harness/ai-drainer.test.sh` | `RUN_DISK_FREE_MB`/`RUN_DISK_LANE_NEED_MB`/`RUN_SPAWN_GATE_MOD` in `_drainer_env`; arms k0-k8 |
| `docs/ops/ai-drainer.md:78-84` | the fail-closed probe list gains **disk** |
| `scripts/orchestrator-harness/spawn-gate.sh:634-637` | its census says `ai-drainer.sh` creates `wt-drainer-<name>` "with a bare `git worktree add` and **no admission at all**" — false after D6, so the sentence is corrected in this change |

### Test-arm plumbing (D18)

`ai-drainer.test.sh:31` exports `DISK_LANE_TREE_MB=0 DISK_LANE_SELF_MB=0 DISK_LANE_RESERVE_MB=0`, so
`disk_lane_need` returns **0** and the term is DISABLED in every existing arm — which is exactly what
R10 needs (the new term must not decide e4/e5/e6). The k-arms therefore state their own numbers
through new `_drainer_env` seams (`RUN_DISK_FREE_MB`, `RUN_DISK_LANE_NEED_MB`, `RUN_SPAWN_GATE_MOD`),
and an arm that forgets one would be VACUOUS — so k1 asserts the disk ceiling actually bound (target
equals `disk=`, not merely "a number was printed").

### Updated in-scope table

R12 the `_capacity_target` contract change is applied at the call site and the field ORDER is asserted
R13 a pin overrides the derived disk ceiling but never the in-loop hard guard (both halves asserted)
R14 module miss / empty output FAILS the tick by name; `need=0` is a branch before the division and is
    distinguishable in the log from a miss
R15 the four stale artifacts of D17 are updated in this change

---

## BUILD–PROVE round: THE SUITE FALSIFIED D5/D10, AND IT WAS RIGHT

`ai-drainer.test.sh` → **239 passed, 5 failed** on the first build. One failure was my arm's
assertion (below); the other FOUR were the design, and they were the most valuable output of the
turn.

### What failed, and why it was not a test artifact

Four **non-vacuity** arms (holder-gate ×2, held-windows, lock) went red with
`dispatched=0`, `tree survived`, `rc=1`. They run a MUTANT COPY of the drainer out of `$ROOT`.
`SELF_DIR` for that copy is `$ROOT`, so the module lookup (`$O/spawn-gate.sh`, then
`<script dir>/spawn-gate.sh`) finds nothing — and D10's fail-closed probe then ended the tick with
exit 1 BEFORE settle and before any dispatch. Those arms were proving nothing because they never
reached the code they test.

⛔ **THE FIELD SHAPE IS THE SAME.** Any box whose runtime dir was seeded without `spawn-gate.sh` — or
any copy run from elsewhere — would have become a drainer that dispatches **nothing**, for ever,
quietly but for a log line. That is the **inert-unit class (#3194)**, and it is a WORSE outcome than
the disk term being absent: the whole cell loses its capacity instead of one bound degrading.

### D19 — the polarity is SPLIT, and this supersedes D10/R14 (as written, not as intended)

| shape | answer | why |
|---|---|---|
| the predicate is **unavailable** (module absent / stale / died while sourced) | **DEGRADE**: a named `NOTE:`, `disk=off (...)` on the line, and the tick plans from cores+memory — the pre-#2159 behaviour | a NEW bound must not be able to take a box to **zero** because a file is missing. The improvement is absent, not contradicted; the NOTE names the remedy (`SPAWN_GATE_MOD`). Same precedent as `fleet_line`'s `why=capacity.sh-unreachable` |
| the predicate **answered with a non-number** (a `df`/seam value that is not whole MB) | **FAIL closed, by name** | that is a FAULT in a resource this tick is about to spend, not an absent improvement — the same posture as the memory and swap probes (D5's original argument, now correctly scoped) |

Both are asserted, in opposite directions: (k4) `DISK_FREE_MB=unreadable` **must** end the tick;
(k4b) an unavailable module **must not** (it must still dispatch, and say why).

### The other failure, and it was MY arm

(k0) asserted `pool=<n>MB@75%/512MB disk=` — contiguous. It is not: the disk fields go at the END of
the line, so on a NON-pinned tick there is `) alive=0 … dispatcher=… ` in between. The arm's real
intent (a folded `mem_pool`) is asserted precisely by requiring the closing paren right after the
pool figures: `pool=[0-9]+MB@75%/512MB[)]`. Corrected.

### Also corrected: a message that named the wrong cause

(k4) showed `_disk_why` blaming a STALE `spawn-gate.sh` when the module had never been consulted at
all (both values were seams). The reason is now derived: `and both values were stated as seams, so
the probe was not consulted`. A diagnosis that sends an operator to re-farm a healthy file is the
same defect as a gate that refuses without stating what it measured.

---

## CODE-REVIEW round 1 — ISSUES: 5, all verified by execution, all applied (5c1e8989e → this commit)

| # | finding | disposition |
|---|---|---|
| P1 | the shipped ops doc states the **opposite polarity** of the module-miss case (`docs/ops/ai-drainer.md` said "fails closed by name" and added `disk` to the fail-closed probe list) — the code DEGRADES, and an arm pins that | **applied** — §1 now states the split; `disk` is removed from the fail-closed list and named as the second exception with its reason |
| P2 | an invalid `DISK_FREE_MB` did **not** fail closed when the module also could not answer: the degrade branch ran first and silently DISCARDED the garbage seam | **applied** — a stated seam is validated **before** the degrade decision; arm **(k4c)** |
| P2 | no integer-**range** guard: `DISK_FREE_MB=9223372036854775808` converts negative, the floor subtraction wraps back to a large positive, `[ -ge 0 ]` cannot catch it, and the term silently never binds (the line printed a negative `free=`) | **applied** — the module's own `is_limit` rule (≤9 digits) for both seams, with the probe exempt because `df` column 4 divided by 1024 cannot reach bash's wrap; arm **(k4d)** |
| P2 | a stated `DISK_FREE_MB` **freezes** the in-loop guard at a constant, while both docs said the disk is re-asked before *each* worktree | **applied as a stated qualification**, not a code change: the seam is what keeps the suite hermetic (the alternative makes every injected arm depend on the host's free space — the hazard this suite's own header forbids), so the header, the ENV block and the ops doc now say the guard is frozen when the seam is stated |
| P2 | two new diagnostics named something that did not happen (`_disk_why` claiming "looked at two paths" when `SPAWN_GATE_MOD` was stated; `need=0` blaming `DISK_LANE_NEED_MB` when the module derived it) | **applied** — `_disk_why` distinguishes stated-but-not-a-file from nowhere-to-look; `need=0` distinguishes a stated seam from a derived zero; arms **(k4e)** and **(k5b)** |

Two of the five (the validation ORDER and the RANGE guard) were defects the reviewer reproduced by
EXECUTION, not by reading — the wrap in particular is invisible in review and produces exactly the
false-PASS the term exists to prevent.

**PROOF after round 1**: `ai-drainer.test.sh` → **249 passed / 0 failed**, exit 0, sha256 identical
before and after the run.


---

## CODE-REVIEW round 2 — ISSUES: 5, all verified by execution, all applied

Round 2 was told to attack the round-1 fixes themselves, and **two of its five findings were defects
round 1 introduced**. Both are recorded here because they are the class this plan keeps meeting: a
statement that reads like a guard while nothing behind it can fire.

| # | finding | disposition |
|---|---|---|
| P2 | **`DISK_MIN_FREE_MB` was left out of the range guard round 1 added** — and the guard it *did* get is applied AFTER `10#`, so a value that WRAPS lands back **in band**. MEASURED: `DISK_MIN_FREE_MB=18446744073909551616` → `10#` yields `200000000`, which passes both the `>=1` and `<=249999999` bounds → floor 200,000,000 MB → `disk=0` → the tier goes inert and prints a SKIP that reads like a full volume, at rc 0 with **no WARN**. The comment claiming parity with `spawn-gate.sh` was false: `spawn-gate.sh:203` tests the raw STRING (`is_limit`) | **applied** — the width rule runs on the RAW value, before the conversion; the comment now states the bound AND the order; arm **(k4f)** reproduces the wrap and asserts `disk_floor=500MB` and that the term still BINDS |
| P2 | **round 1 made half of its own documented split unreachable.** The two non-digit FAIL arms, `_disk_asked` and `_disk_src`, could never fire: a stated non-digit exits at `_disk_seam_check` first (that is round 1's own fix), and `_disk_probe` digit-validates its own reading, so the `else` branch can only ever hold digits-or-empty. A module that answers `abc` therefore DEGRADES (rc 0) while the comment asserted it "FAILS CLOSED by name". Three dead constructs plus a false comment | **applied** — `_disk_asked`, `_disk_src` and both unreachable arms deleted; the comment now states the split the code implements (a **stated** seam fails closed, a **module** answering a non-number is indistinguishable from UNKNOWN and degrades); arm **(k4g)** pins the module case so the two shapes cannot silently swap back |
| P2 | the 9-digit cap's **stated reason was false** for 10–18 digits, in both the FAIL message and the ops doc: `$((1000000000))` does not wrap; only 19+ digits wrap 2^63 | **applied** — both texts now give the true reason (parity with `is_limit`, ≤999,999,999 MB ≈ 976 TB) and say plainly that the cap is not a wrap detector |
| P2 | the ops doc round 1 edited became **self-contradictory**: disk was "the second exception" at one line and cores "the one exception" six lines later | **applied** — cores is now "the other exception" |
| P2 | arm **(k4e)** did not prove its own title: it pinned only the `(looked at` prefix, so an implementation printing **one** path would stay green while the claim "names BOTH searched paths" became false | **applied** — the arm pins both full paths (`$ROOT/o-k4e/spawn-gate.sh and $ROOT/spawn-gate.sh`), which also proves `$SELF_DIR` resolved to the copy's directory — the property the four mutant-copy arms depend on |

### The build error this cycle surfaced, and why it matters

Both rounds' fixes were applied with a single multi-hunk edit whose **third hunk failed to match**.
The editor applies a call atomically, so hunks 1, 2 and 4 did not land either — but a *second* call
then removed `_disk_asked`'s assignment while leaving its read site. The result was `set -u` killing
every tick at `ai-drainer.sh:800`:

```
ai-drainer.sh: line 800: _disk_asked: unbound variable
```

**146 arms failed and 107 still "passed"** — many of them vacuously, because the arms that assert *"the
tick refuses"* were satisfied by the crash rather than by the behaviour. That is the failure mode a
pass/fail tally hides: a suite can go red for the wrong reason and green for no reason. The fix
verification is therefore stated as **the specific arms**, not the count.

**PROOF after round 2**: `ai-drainer.test.sh` → **252 passed / 0 failed**, exit 0
(`(k4f)`, `(k4g)`, `(k4e)`, `(k-real)`, `(k2)`, `(k3)`, `(k6)` all green).
`spawn-gate.test.sh` → **516 passed / 0 failed** (unchanged file, re-run for the pair).
