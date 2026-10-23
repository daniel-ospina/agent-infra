---
title: "Plan — #2481: the FIRST-CHECKS wait becomes progress-aware (SLOW vs STUCK)"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-10-23
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-2481, admin-merge, first-checks-wait
---

# Plan — #2481: the FIRST-CHECKS wait becomes progress-aware

**Issue:** agent-infra#2481 — *bug(rail): the FIRST-CHECKS wait is a fixed 3900s window
SHORTER than one green step of the lane it waits for*
**Lane:** `fix/2481-first-checks-progress`
**Components:** `scripts/admin-merge.sh`, `tests/admin-merge/run.sh`
**Complexity:** standard

---

## 1. The measured problem

`wait_for_first_checks()` (`scripts/admin-merge.sh`) held ONE fixed window
(`ADMIN_MERGE_FIRST_CHECKS_WAIT`, default = `FAILSAFE_RERUN_TIMEOUT` = **3900s**) and, on
expiry, `block_on_first_checks()` + §1b refused with
`precondition unmet: run still in_progress — no classification attempted` — i.e. **no
classification at all**, on a lane that was merely slow.

Measured on this repo's own green `ci.yml` PR runs (8 consecutive successes, 2026-10-22/23):

| quantity | measured |
|---|---|
| full green run | 6586s … **9032s** (median ≈ 8075s) |
| longest `bash-suites` JOB | 5490s … **6660s** |
| longest single **STEP** (`Bash shards — the ONE list both lanes run`) | 3960 / 4020 / 4368 / **4380s (73.0 min)** |

⇒ 3900s is **shorter than one green step** of the lane it waits for, and less than half its
median run. `bash-suites` was red on 48 of 83 open PRs: the common path.
`#2412` refused with that message and **merged 4 minutes later**.

## 2. Why a bigger number is not the fix

Raising 3900 would move the timeout later and keep failing on the same PRs. The wait was also
**blind**: its only clock was `waited` and it never compared one poll's observation with the
last, so an advancing run and a wedged one were indistinguishable *by construction*. It had to
pick a number, and 3900 was simply where it landed.

## 3. Decision — progress-aware wait

**Progress signal.** Every poll reads the pending runs' job listings
(`GET /repos/{o}/{r}/actions/runs/{id}/jobs`, ONE call per pending run) and fingerprints, per
run: `run:<id>:<status>` plus, per job, `<name>:<status>:<conclusion>:<steps-done>/<n>:<current-step#>`.
A CHANGED fingerprint is progress. Verified live 2026-10-23 on run `39959046444`: `bash-suites`
`in_progress` at step 5/8, `admin-merge` at 3/8, with per-step `number`/`status` and timestamps.

⛔ **Not `updatedAt`.** A run's `updatedAt` freezes for the whole of one long step; a bound built
on it produced the false `STALLED` verdict this rail already retracted (#1167 follow-on; §39
pins it out). A **step boundary** is evidence; the silence between two of them is not.

The fingerprint is **sorted by job name**, because the Jobs API's job order is not a contract and
a positional fingerprint would report a spurious "change" on every poll — resetting the stall clock
forever and hiding a real stall behind the ceiling.

**Three bounds, each derived from a measured quantity:**

| knob | default | derivation |
|---|---|---|
| `ADMIN_MERGE_FIRST_CHECKS_STALL` | **8760s** | 2 × the longest MEASURED single step (4380s). The finest granularity GitHub exposes is a step boundary, so **any** bound below one legitimate step is a guaranteed false stall. Promoted at runtime to `max(STALL, 2 × longest COMPLETED step on the runs being waited on)`. |
| `ADMIN_MERGE_FIRST_CHECKS_CEILING` | **18064s** | 2 × the slowest MEASURED green run (9032s). A lane-occupancy cap, **not** a stall detector — its verdict never claims to be one. |
| `ADMIN_MERGE_FIRST_CHECKS_WAIT` | **3900s** (unchanged) | the LEGACY window, kept only for the states with **no object whose progress can be observed**: `never-started` (no run attached yet — the fresh-PR race, and #2465's inapplicable-lane case) and `unreadable` (the run list itself cannot be read). `0` still disables the wait when neither progress bound is set. |
| `ADMIN_MERGE_FIRST_CHECKS_POLL` | **60s** | the CALL budget, not comfort: a poll is 1 `run list` + 1 Jobs read per pending run. Worst case to the ceiling = 301 polls ≈ 600-900 REST calls over five hours (**≈120-180/h**) — less per hour than the fixed 10s window it replaces managed (390 calls in 65 min ≈ **360/h**) against the fleet's ONE shared 5000/h bucket. |

**Verdicts are distinguishable** (they recommend opposite remedies):

* `stalled` — `STALLED: NO observable change for <quiet>s (stall <bound>s …)` — names the last
  observed transition + the elapsed stall.
* `ceiling` — `expired after <waited>s (ceiling <bound>s) — a TIMEOUT, not a stall` — and when the
  run was moving, it says `it WAS PROGRESSING (N observable change(s))`.
* `never-started` / `unreadable` / `unobservable` — the legacy window's own wording.

**The failure mode of progress-aware waiting is a MISSING SIGNAL** — the one that turns "slow" into
"everything is stuck". A failed Jobs read (or more pending runs than the wait will fingerprint,
`FIRST_CHECKS_JOBS_MAX=8`) does **not** advance the stall clock; the wait reports the signal as
unavailable and refuses on the legacy window with `unobservable`, so a broken instrument can
neither manufacture a stall nor extend a wait.

## 4. What does NOT change

* the same checks, the same classification (§1b), the same refusal for a genuinely red check;
* every non-terminal exit still BLOCKS with no evidence posted and nothing merged;
* elapsed time can never turn a red into a green — pinned by §78(d) and by the pre-existing §76(d).

## 5. Scope boundaries (explicit, to avoid collisions)

* **`shardspeed`** owns making `bash-suites` fast. This change is correct **regardless** of how
  slow a check is; the two cannot collide (different files, different mechanism).
* **#2363** owns `atomic-land.sh`'s `--wait-timeout` default vs the harness silence bound. Untouched.
* **#2465** owns the FIRST-CHECKS lane FILTER (`python-ci.yml` has no PR trigger → `never-started`
  burns the whole window) and `--no-wait` propagation. Untouched: `never-started` keeps the legacy
  window byte-for-byte.

## 6. Verification

| Surface | Layer | Expected |
|---|---|---|
| slow but progressing past the old window | integration §78(a) | keeps waiting, quotes the transitions, then **lands** on the real classification (evidence + merge) |
| wedged run (frozen steps) | integration §78(b) | `STALL` verdict, naming the last transition + elapsed stall; no ceiling wording |
| progressing but out of ceiling | integration §78(c) | `TIMEOUT, not a stall`, `it WAS PROGRESSING`; no `STALLED` |
| gate not weakened | integration §78(d) | wait clears, classification runs, a genuine red still refuses, no merge/evidence |
| missing signal | integration §78(e) | names the unavailable signal, no stall claim |
| bounds derived / promoted / seamed | unit §78(f), §43 | 8760 / 18064 / 3900 / 60 printed with their derivation; a 5000s step promotes to 10000s; leading zeros refused |

## 7. Research

**Internal** (rung 1 of this task): `scripts/admin-merge.sh` (the wait, every refusal string,
`--print-bounds`), `scripts/atomic-land.sh` (`--wait-timeout`, `POLL`, the `ATOMIC_LAND_*` seams),
`scripts/ci-failure-set.sh` (the parser whose listing the wait shares), issue **#2299**
(`bash-suites` in-flight behaviour), #1167 / #1164 / #2090 / #2465, and §39/§76 of the rail suite
(the retracted false-STALL and the three-waits separation).

**External** — **partial run, stated rather than hidden.** Rung 1
(`mcp__seo-intelligence__perplexity_search`) **unavailable** (`seo-intelligence` is not in this
machine's MCP catalog). Rung 2 (`web_search`) **unavailable**
(`PERPLEXITY_API_KEY not set`). Rung 3's search half (`mcp_load exa`) loaded but its calls fail
(`401 … EXA_API_KEY`); rung 3's `web_fetch` half returned the pages' navigation chrome only (2
fetches: `kubernetes.io` Deployment reference, `pkg.go.dev k8s.io/api/apps/v1`) — **0 usable
excerpts**. Counts: **4 attempted / 0 returned**. So the pattern is named from the internal evidence
and **labelled unverified**, never cited as if read:

* **Pattern (unverified, prior knowledge):** *progress-aware deadline* — a
  liveness/watchdog bound that resets on an observed signal and is capped by a hard deadline. The
  canonical instances are claimed to be Kubernetes `progressDeadlineSeconds`, Buildkite's
  no-output/inactivity timeout, and Jenkins `timeout(activity: true)`. Each of those is
  **progress-dependent for the bound and absolute for the ceiling**, which is the same two-bound
  shape adopted here — the difference being that this rail derives both from **this lane's measured
  durations** rather than from a default.
* **Failure mode (unverified, prior knowledge):** a missing heartbeat/progress signal is read as an
  absence of progress, so a broken *instrument* reports a hung *workload*. This design refuses that
  inference structurally (§3, `unobservable`).

Closing the external leg is a one-line config fix (a usable Perplexity or Exa key) and is **not**
required for the bound chosen here: every number in §3 derives from measurements of this lane,
recorded above.

## 8. Review-gate finding — the stall clock absorbed time it could not observe

The verification gate reproduced a defect in the first cut of §3, and it is recorded here because
it is the exact failure mode this design exists to prevent, found inside the design itself.

**The defect.** `quiet` — the stall clock whose value is printed as `NO observable change for Ns` —
was advanced on polls where the progress instrument had **failed** (`unobservable`), where no run
existed yet (`never-started`), and where the run list was unreadable. The comments and this plan
asserted the opposite, so code and record disagreed, and the code was wrong: a Jobs surface that
fails for `FIRST_CHECKS_WAIT` (3900s, ~44% of the 8760s stall bound) and then recovers produces a
`STALLED` verdict naming a hung shard on seconds that were never observable.

**Measured, pre-fix** (fixture: 6 unreadable polls, then a recovered poll with an unchanged
1s-step fingerprint, `STALL=6`):

```
admin-merge: ✗ BLOCK — the FIRST-CHECKS wait STALLED: NO observable change for 6s
   (stall 6s, derived from the measured longest green step; waited 7s of the 120s ceiling)
   last observed TRANSITION (0 change(s) before it): run 9821: 1 job(s): 0 completed, 1 not —
   bash-suites in_progress step 5/8 …
```

Six of those six seconds were unreadable; one change had in fact been observed (the first read).

**The fix.** `quiet` advances **only** on a poll whose fingerprint was observed and did not change.
Unobservable intervals advance the `missing` budget instead — which is what bounds an instrument
that never recovers, and which is now reported honestly as *cumulative and consecutive* time
(`unreadable for 6s … in total, 6s consecutively`) rather than as one continuous silence.

**Proof both ways.** New case §78(g) drives interleaved failed and successful reads: with the fix,
the same healthy run is never called stalled and lands; with only the two `quiet` increments
restored, §78(g) fails 3 of its 5 assertions and the rail blocks with the message above. No fixture
change was made between the two runs — the only difference is the two lines.

**The tell that it was a real gap and not a taste question:** the suite was green at 1607
assertions both before and after, because §78(e) exits on the 1s legacy window before any
accumulation can occur. A green suite is not evidence about a clock it never let run.
