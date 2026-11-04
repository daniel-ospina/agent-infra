---
title: "Plan — #2890: one heartbeat per $STATE — a lock with an identity-bound stale takeover"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-10-27
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-2890, orchestrator-heartbeat, heartbeat-lock, pr-doctor
---
<!-- research-path: agent-infra#2890 scoping comment (double diamond) + PR #2898 body -->

# One heartbeat per `$STATE` — Implementation Plan

> **For Pi:** this plan is **already executed** — the code landed in PR #2898 before this doc was
> written. It is recorded here for two reasons: `check-pipeline-compliance.sh` check (d) requires a
> plan doc for a `complexity:standard` issue, and the design reasoning (which is durable) had been
> living only in a PR body, which is not a durable artifact. Where a step below describes work that
> is already in the diff, it is written in the future tense the plan format asks for; the
> `### Execution Record` section states what actually happened.

**Goal:** make one `orchestrator-heartbeat.sh` process the only process running a pass against one
`$STATE`, enforced inside the script so **every** entry point (launchd `StartInterval`, a manual
run, `launchctl kickstart -k`) gets the same guard.

**Team:** organisation-design-team
**Role:** — (lane execution; no role scope)

**Architecture:** a `mkdir`-and-stage lock directory at `$STATE/heartbeat.lock`, taken before the
first write of the pass and released on exit. Contention is resolved by probing the holder's
**identity** (`pid` + its own `ps -o lstart=` start time), not merely its liveness, because a
recycled pid reads as "alive" after a `SIGKILL` and would stop the box forever (#1985). A second,
independent bound — the lock's **age** — reclaims a holder that is genuinely live but wedged, so a
wedged pass costs one pass and never the box. No `flock`: see §3.

**Tech Stack:** bash, compatible with macOS `/bin/bash` 3.2 (no `declare -A`, no `mapfile`, no
`flock(1)`, no `/proc`), and with GNU userland on the Linux CI box (`find -mmin`, `ps -o lstart=`,
`sed`). Zero third-party dependencies.

---

## 1. The measured problem

`scripts/orchestrator-heartbeat.sh` had no single-instance guard. Instances accumulated on one
state dir and ran the same per-pass work at the same time.

Measured 2026-10-27 (agent-infra#2890, comment 1) and reproduced on a clean restart:

| observation | measurement |
|---|---|
| two live processes on one `$STATE` | `2283 etime 04:55` beside `8835 etime 01:23` (PR #2898) |
| after killing the older one + `launchctl kickstart` of the job | **two again within three minutes** — so it is not a leftover, it is every entry point |
| three coexisting | PIDs `56912`, `58371`, and a third arriving within minutes (issue #2890) |
| the harm, when a downstream guard was absent | same-second **duplicate `spawn` for one `prd-` id**: 13 + 24 + 40 + 29 = **106** over 2026-10-21..24 |
| the harm since 2026-10-25 | **zero** — because `pr-doctor` gained a "one worker per PR" guard, **not** because anything here changed |
| the remaining cost today | `pr-doctor` passes skipped: `04:53 → 05:04 → 05:22 → 05:53 → 06:23 → 06:26` (gaps 11/18/31/30 min against a 5-min cadence) |

**Stated precisely, because it changes the priority:** the dangerous consequence is currently
blocked by a guard in a *different* component that nobody is obliged to keep. The root cause — no
single-instance guard — is open. This is defence in depth, not an active incident.

## 2. Which problem framing to solve (problem diamond)

| # | Framing | Verdict |
|---|---|---|
| P1 | "two processes exist, make there be one" (the issue's literal wording) | **Rejected as the definition.** Process count is a symptom. The harm is that two passes mutate one `$STATE` concurrently; a lock that merely reduces the count, but lets two passes run, fixes nothing. |
| P2 | **"the pass is not serialized against a shared `$STATE`"** — one critical section, whoever the entry point | **Chosen.** It is the invariant the harm violates, and it is entry-point-independent by construction. |
| P3 | "the job is over-scheduled — the pass takes 6–9 min against a 5-min interval, so lengthen `StartInterval`" | **Rejected.** It cannot cover a manual run or `kickstart -k` (the measured reproduction path), and it would still permit overlap. Cadence is an operator setting, not a correctness property. |
| P4 | "the real defect is that the running box executes a *drifted* copy, so no upstream fix lands" | **Real, but separate scope.** 1209 vs 1199 lines across 6 hunks (78 lines). Already filed as #1552, #1738, #1694; changing the live box is explicitly **out of scope** for this change and stated as such in the PR body. |

### Targets, and what happens to each

The issue names three targets. Stating their disposition here, because a plan that claims to cover a
spec must say which parts it cannot:

| target (from #2890) | disposition |
|---|---|
| **0 concurrent instances over a 24 h observation window** | ⛔ **NOT reachable by this PR.** The live box runs a drifted copy (1209 vs 1199 lines), so nothing here executes there until #1552/#1738/#1694 close — and `fleet-inventory.sh` has **no row for the heartbeat tick job**, so the window could not be observed even after that. Filed as its own issue (the observability gap), not silently dropped. |
| **a second start refuses, with a named reason** | ✅ `SKIP — another instance is live (pid N …)`, exit 0 (§3.1), asserted by cases 1, 2, 15. |
| **the sibling case is tested** | ✅ 52 assertions over 17 cases; every rule mutation-checked (§7). |

P4 is the honest limit of this plan: **it fixes the versioned script only.**

## 3. Which mechanism (solution diamond)

| # | Approach | Verdict |
|---|---|---|
| S1 | **`flock(1)`** on `$STATE/heartbeat.lock` — the canonical shell-script mutex, and the SOTA answer on Linux: the kernel releases the lock when the holder dies, so the stale-lock problem does not exist at all | **Rejected — a recorded decision forbids it.** `flock(1)` is util-linux; **macOS does not ship it**, and this box is macOS. The decision is recorded at `docs/scoping/2026-09-05-issue-469-pi-session-hygiene.md:45` — *"`flock` does NOT exist on macOS (util-linux; CI ubuntu HAS it — a platform-divergence trap; the lock MUST NOT depend on it)"* — reached after a P1 review finding on that issue, and re-stated in-tree at `scripts/lane-reap.sh:1359` (*"Bash 3.2 has no flock(1); `mkdir` is the atomic primitive"*) and by four sibling reapers (`pi-cache-reap.sh:1031`, `pi-reap-idle.sh:1170`, `pi-reap-orphans.sh:427`, `pi-reap-worktrees.sh:561`). Adopting it here would silently reverse that decision and re-introduce the CI-green / box-broken divergence. |
| S2 | **`mkdir` claim + a `pid` file** — the bare `$STATE/pr-doctor.lock` pattern (`heartbeat-loop.sh:768-793`) | **Rejected as insufficient.** Liveness read from a bare pid is exactly the **#1985** defect: a pid the OS recycled after a `SIGKILL` reads as "the holder is alive", which stops the box silently *and* blocks its own recovery, because a start that defers to a wrong pid can never repair the lock it defers to. |
| S3 | **`mkdir` claim + `pid` AND `ps -o lstart=` identity + an age bound + a bounded settle**, assembled from patterns already in the tree | **Chosen.** Correctness comes from three independent arms: identity reclaims a recycled pid, the age bound reclaims a wedged-but-live holder, and the exit trap makes "the lock is gone" and "the process is gone" the same event. Every part is a pattern this repo already uses, so a reader can check it against a sibling (`ai-drainer.sh` GUARD 1 for the staged claim / atomic reclaim / ownership-checked release; `pr-doctor.lock` for the `-mmin +30` age rule; `watchdog-loop.sh` for the unwritable-`$STATE` rule). |

**The composition, and where each rule comes from:**

| rule | source | why it is here |
|---|---|---|
| stage the lock **already labelled**, then `mv` into place | `ai-drainer.sh` GUARD 1 | a bare `mkdir` then write leaves a pid-less lock that the next contender calls stale → two ticks |
| reclaim with an atomic `mv` aside, never `rm -rf` + `mkdir` | `ai-drainer.sh` GUARD 1 | two contenders both delete, both claim |
| release only a lock whose `pid` file names **us** | `ai-drainer.sh` GUARD 1 / #1761 | an exiting tick must not delete its successor's lock |
| `find -mmin +30` age bound | `$STATE/pr-doctor.lock` | reclaims a wedged-but-live holder; 30 min because a pass cannot legitimately run that long (target cadence 540 s, own `STALL … exceeded 390s` killer) |
| `pid` + `ps -o lstart=` identity, `LC_ALL=C` on both reads | #1985 | liveness is not identity; a locale-dependent mismatch would read as `recycled` and let two passes run |
| unwritable `$STATE` → **permit**, loudly | `watchdog-loop.sh`, inverted on purpose | refusing would take the box's only alarm offline at the moment the box is broken, and could not even log why (the log lives in that dir) |
| debris sweep for `.heartbeat.lock.*` older than the age bound | new — *no existing reader reaps that name* (grepped) | a claim `SIGKILL`ed between `mkdir` and `mv`/cleanup would otherwise leak a dir forever |

### 3.1 Decisions the issue left to this change

| decision | choice | reason |
|---|---|---|
| refusal exit code | **0**, not the issue's suggested non-zero | `scripts/lib/fleet-inventory.sh:68` renders a job's **non-zero last exit** as `FAILING`. At a 5-min interval against a 6–9 min pass, "a second start while one is live" is the expected, frequent, healthy case; a non-zero exit would paint the heartbeat `FAILING` on most ticks — a false red on the one component whose job is to report the box's state. The file's own header contract is "EXIT: always 0". |
| what a refusal may write | **nothing** under `$STATE`; the reason goes to **stdout** | so a contended tick provably mutates no byte of the state dir. Trade, stated not hidden: a refused tick leaves no line in `orchestrator-heartbeat.log` (that log lives in `$STATE`). |
| `--dry-run` under a live pass | claims if free, **never reclaims, never refuses** | a diagnostic must answer on a running box — the rule `origination-funnel.test.sh` already pins for `--check-refresh` |
| `HB_LOCK_STALE_MIN=0` | **not a setting** — below 1 falls back to 30 | the bound is `find -mmin +N`: `N=0` means "older than a minute", so a live pass holding 60 s would be joined by a second — the #2890 defect re-created by misconfiguration (`watchdog-loop.sh`'s `MAX_CONSEC` lesson, same shape) |
| `HB_LOCK_WAIT_S` | default 10 s, bounded **above** at 30 s, **not** for cadence | `kickstart -k` SIGTERMs the holder and starts the replacement immediately, and a trapped TERM only exits after the command in flight; a scheduled tick pays the same seconds and then refuses. The upper bound exists because the settle is spent by a tick that could otherwise sleep *through* its own interval (`HB_LOCK_WAIT_S=600` against a 300 s cadence = two silent lost beats). |
| an unreadable `ps` | **defer** (`unverifiable`), never `dead` | `ps -p PID` exits 1 both for "no such process" and for "could not see it", and those two answers mean opposite things here. Emptiness of the output is not a witness; the exit code is — `scripts/lib/pid-identity.sh:24-31`: *"the ONLY thing that may witness 'dead' is exit 1"*, and a read failure is `unverifiable`, which takes the `live` arm (defer, bounded by the age arm). The first version of this guard read an empty result as death, so a `ps` that failed to run — the fork-exhaustion state a loaded box reaches — reclaimed a **live** holder's lock and produced the very concurrent pass it exists to prevent. |
| `--dry-run` and the debris sweep | the sweep is **skipped** under `--dry-run` | the sweep is the guard's only destructive operation, and a diagnostic exists to answer without changing the box. It used to run inside `hb_claim`, which a dry run reaches. A dry run still *claims and releases* when the lock is free (so it cannot observe a half-state) and never reclaims. |

## 4. Wiring Check

Touch points enumerated from the change's actual seams:

| Touch Point | Type | Covered By | Status |
|---|---|---|---|
| `$STATE/heartbeat.lock` (new: `pid`, `start`, staging dirs) | State / Concurrent | `hb_claim` / `hb_probe` / `hb_release` | ✅ cases 1–5, 8, 13 |
| `$STATE/.heartbeat.lock.*` (**debris sweep**, `find … -exec rm -rf`) | State / Concurrent → **Out, destructive** | `hb_claim`, skipped under `--dry-run` | ✅ cases 14, 16 |
| `$STATE/orchestrator-heartbeat.log` | State / Out | untouched by a refusal (the guard sits above the truncation; the exists-check precedes the staging `mkdir`). It is also `fleet_row_heartbeat_loop`'s **freshness** input (`fleet-inventory.sh:702-705`), so a tick that refused in silence would eventually read LATE | ✅ asserted by the before/after file+dir set and a source-order pin |
| `$STATE/pr-doctor.lock` (sibling; detached `pr-doctor` children) | Concurrent | **deliberately NOT covered** — this lock serializes the *pass*; a detached child outlives it and is serialized by its own lock — which is itself **age-only, no identity** (`heartbeat-loop.sh:768-774`) | ✅ stated in the header; the sibling defect is cited and filed |
| `scripts/lib/fleet-inventory.sh` (the box's liveness read) | Consumer / In | refusal exits **0**. ⛔ The tick has **no registered row** in that file, so the inventory is *not* where a refusal shows up | ✅ rationale corrected to the two grounds that actually exist. ⚠️ that absence makes the issue's "0 concurrent over 24 h" target unobservable → filed |
| `heartbeat-loop.sh` (the entry point that bounds the tick — `run_bounded`, :534) | External / In | — | ⚠️ named because the **direct launchd entry point has no such bound**; see the age-arm residual |
| launchd entry point (`StartInterval`, `kickstart -k`) | External / Event | the guard is in-process above every write → no plist change needed; the refusal message goes to stdout (`StandardOutPath`) | ⚠️ the **live** plist is not version-controlled — #1694 |
| `ps` (process start time) | External / In | `hb_ident` = `LC_ALL=C ps -p <pid> -o lstart=` (not `/proc`: macOS has none), **exit code forwarded** | ✅ case 15 (a broken `ps` must defer) |
| signals `TERM` / `INT` | Event | traps installed **before** the claim; `trap 'exit 143' TERM`, `trap 'exit 130' INT` → the single `EXIT` release point (`orch-loop.sh`'s #1715 lesson: they must *exit*, not merely return) | ✅ case 12 |
| the `.heartbeat.lock.*` naming family (staging, stash, sweep share one prefix) | State / Concurrent | so a `SIGKILL` between the reclaim `mv` and its cleanup leaves something the next claim reaps | ✅ case 14 |
| the **live drifted copy** `/Users/home/orchestrator/orchestrator-heartbeat.sh` | Out of scope | 1209 vs 1199 lines / 6 hunks | ⚠️ explicitly out of scope — #1552, #1738, #1694 |
| macOS `/bin/bash` 3.2 + BSD `ps -o lstart=` / `find -mmin` / `sed` | Platform | no bash-4 construct in the guard; reads checked **statically** (the suite ran on Linux) | ⚠️ **a residual of THIS change**, not a pre-existing defect — the identity and age arms are only *executed* on the Linux box |

**No wiring gap blocks this change.** Four ⚠️ rows: three are pre-existing and already filed (#1694; #1552/#1738/#1694; the sibling-lock defects). The fourth — the macOS platform arm — is a residual this change creates, and it is stated rather than hidden.

## 5. Integration Surface Map

(test-design output, derived at plan time from the change's seams)

| # | Surface | Type | Data Flow | Test Layer | Contract | Key Failure Modes |
|---|---|---|---|---|---|---|
| 1 | `$STATE/heartbeat.lock` | Concurrent / State | Both | Integration (shell suite, real script, per-case `$HOME`) | dir contains `pid` (numeric) + `start` (trimmed `lstart`) | two claimers both win; a pid-less lock read as stale; a reclaim that loses a race and deletes the winner |
| 2 | process table (`ps -o lstart=`) | External | In | Integration | **exit code decides**: rc 0 ⇒ running, rc 1 + empty ⇒ absent, anything else ⇒ UNANSWERABLE (defer); formatted `LC_ALL=C` on both reads | recycled pid read as live; locale mismatch read as recycled (⇒ two passes); **a `ps` that could not run read as a death witness** (⇒ a live lock reclaimed) ✅ case 15 |
| 3 | `$STATE` writability | State / In | Out | Integration | unwritable ⇒ **permit**, warn on stdout | silent self-disable (a *no-op gate*) — the warn is load-bearing; a *half*-writable dir (the staging `mkdir` fails but the log opens) taking the wrong arm |
| 4 | clock / mtime (`find -mmin`) | External | In | Integration | age > `HB_LOCK_STALE_MIN` ⇒ reclaimable even if live | a live holder wedges the box forever (#1985); `N=0` re-creating the defect |
| 5 | signals (`TERM`/`INT`) | Event | In | Integration | exit 143/130 → `EXIT` trap releases | lock leaked after `kickstart -k` ✅ case 12; a successor's lock deleted ✅ case 8 |
| 7 | `$STATE/.heartbeat.lock.*` (debris) | Concurrent → Out (**destructive**) | Both | Integration | an orphan older than the age bound is reaped; a young one is never a candidate; **never under `--dry-run`** | an unaged live staging dir deleted (⇒ two passes); an aged orphan never reaped (⇒ permanent debris); a diagnostic deleting debris ✅ cases 14, 16 |
| 6 | exit status → `heartbeat-loop.sh`'s `TICK FAILED` line | Consumer | Out | Integration | refusal ⇒ **0** | a false `TICK FAILED` on most contended passes; and a refusal that exits non-zero on the launchd path being mistaken for a real tick failure |

**Bug Pattern Flags** — #1985 (*liveness is not identity*), #2557 (*the same work ran concurrently on one
resource*), #1761 (*an exit deleted a successor's lock*), and the repo-wide *no-op gate* class (a guard
that silently disables itself and still reports protection).

**Not applicable / skipped:** no DB, no auth boundary, no network, no UI, no third-party dependency —
so no pgTAP, no E2E, no PBT (the surfaces are process/filesystem, exercised by the integration suite).

## 6. Tasks

### Task 1: the guard, above the first write

**Intent:** make a second pass impossible against one `$STATE` from any entry point.
**Acceptance:** a second start while a first holds the lock runs no pass, creates no file/dir under
`$STATE`, bumps no mtime, names the holder on stdout, and exits 0.
**Files:** Modify `scripts/orchestrator-heartbeat.sh` (SINGLE-INSTANCE GUARD block + `hb_claim` /
`hb_probe` / `hb_release` / the claim loop + traps).

### Task 2: the reclaim arms

**Intent:** never let the guard become the wedge it removes.
**Acceptance:** a dead holder, a **recycled** pid, a pid-less lock, and a lock older than
`HB_LOCK_STALE_MIN` are each reclaimed; a young live holder is deferred to.
**Files:** as Task 1 (`hb_probe`, the `case` in the claim loop, the atomic `mv` reclaim).

### Task 3: the suite

**Intent:** make each rule fail-red-able on its own.
**Acceptance:** `bash scripts/orchestrator-harness/heartbeat-lock.test.sh` → 37 assertions, offline,
driving the **real** script through its real entry point against per-case `$HOME` fixtures; and
defusing any single rule turns its own case red.
**Files:** Create `scripts/orchestrator-harness/heartbeat-lock.test.sh`.

### Task 4: the documented limit

**Intent:** so the next reader does not mistake this for closing the live-box gap.
**Acceptance:** the header and PR body both state: versioned file only; live copy drifted
(#1552/#1738/#1694); defence in depth, not an active incident; this lock does not cover detached children.
**Files:** as Task 1 (header block) + PR body.

## 7. Verification

- `bash scripts/orchestrator-harness/heartbeat-lock.test.sh` → **`heartbeat-lock: 52 passed, 0 failed, 0 skipped`** (exit 0), 17 cases, offline, driving the **real** script through its real entry point against per-case `$HOME` fixtures.

### Non-vacuity — measured, and reproducible

Each rule was defused in a **copy** of the subject and its own case(es) went red. Reproduce any row by
editing that one construct in a copy of `scripts/orchestrator-heartbeat.sh`, placing the copy at
`<dir>/orchestrator-heartbeat.sh` with the suite at `<dir>/harness/heartbeat-lock.test.sh`, and running it:

| rule defused | reds |
|---|---|
| identity check (pid-only liveness) | 2 |
| age arm (`-mmin` bound never fires) | 2 |
| an unreadable `ps` read as death (pre-fix `hb_probe`) | 4 |
| claim is not atomic (`rm -rf` then `mv`) | 1 |
| no ownership check after the move | 1 |
| release is not ownership-checked (#1761) | 8 |
| traps installed only **after** the claim | 16 |
| debris sweep removed | 1 |
| sweep also runs under `--dry-run` | 1 |
| the settle has no upper bound | 1 |
| the refusal path stages before the held-lock check | 4 |

⛔ **Honest note on one row:** an `rm -rf`+`mkdir` rewrite of the **reclaim** alone still measures
**0 reds**, because the staged `mv` in `hb_claim` is the actual serializer and it alone keeps case 13
green. That is a statement about which arm is load-bearing, not a gap: the reclaim's atomic `mv` is
defence in depth behind the claim's.

### Other suites

- `tests/heartbeat-fleet-advance/run.sh` — **197/197 pass**. It pins this script's *shape* (executable-line
  count + a block-keyword cksum) and the guard moved both: re-cut in §0 of that suite from `506 →
  602` lines and `32193281534949 → 11455093485862`, with the reason in the suite and the commit message.
  Discovered by review — the first draft of this plan claimed this suite passed untouched, which was false.
- `scripts/heartbeat-loop.test.sh` — 36 assertions, passes. `tests/beat-pair/run.sh` — 17, passes.
- **Pre-existing failures, measured on `main` `0d443381`** and byte-identical on this branch:
  `mac-pin-parity.test.sh` (38 passed / 65 failed / 1 skipped), `orchestrator-bringup.test.sh` (131/9),
  `check-false-pass-shapes.test.sh` (2), `harness-surface.test.sh` (2), `fleet-inventory.test.sh` (138/6).
- Platform note: executed on Linux (bash 5.2, GNU findutils). macOS `/bin/bash` 3.2 and BSD
  `ps -o lstart=` / `find -mmin` / `sed` were checked **statically** (no bash-4 construct in the guard),
  not executed on a Mac — see the ⚠️ row in §4.

## 8. Execution Record

- Implemented in PR #2898 on `fix/2890-heartbeat-single-instance`.
- Three `[VGATE]` verification passes on the changed files found **two real defects, both fixed**:
  (a) the refusal path still wrote under `$STATE` (the staging `mkdir` ran before the held-lock check —
  11 writes per refused tick at the default settle, measured with `strace`); (b) the suite could not be
  executed by an agent at all (the checkout guard refused `bash -n "$SUBJECT"` as script-indirection).
  A later pass found case 9 **inert** (it fed a leading-zero value to a knob that never reaches
  `$(( ))`), now covering `HB_LOCK_WAIT_S`, with case 11 added for `HB_LOCK_STALE_MIN`.
- Recorded defect fixed alongside: a `SIGKILL` between the reclaim `mv` and its cleanup left a dir
  nothing reaped → the debris sweep.

### Review cycle 1 (fresh context, post-hoc) — 7 findings applied, 4 cited and filed

A fresh-context plan review found defects that the VGATE passes had not, and **every one was verified
against its primary source before being applied** (§ finding-verification rule):

| finding | verified against | disposition |
|---|---|---|
| an unreadable `ps` was read as a **death witness**, so a fork-exhausted box reclaimed a live lock — the exact defect this change removes | `scripts/lib/pid-identity.sh:24-31`; `scripts/disk-reaper.sh:813-826` (the same datum settled the other way); `ps -p <absent>` → rc 1 | **fixed** — `hb_ident` now forwards `ps`'s exit code and only `rc=1` + empty output witnesses death; case 15 added |
| `tests/heartbeat-fleet-advance/run.sh` was **RED** (2/197), pinning this script's shape — and this plan's first draft claimed it passed untouched | ran it | **fixed** — §0 re-cut (506→602, cksum→11455093485862); 197/197 |
| the debris sweep (`find … -exec rm -rf`) ran under `--dry-run`, i.e. the only destructive step executed by a diagnostic | read `hb_claim`; `--dry-run` reaches it | **fixed** — sweep skipped under `--dry-run`; case 16 added; §3.1 states the free-lock behaviour |
| traps were installed **after** the claim, so a `SIGTERM` in that window leaked the lock naming a dead pid | read lines 229→294 | **fixed** — traps installed before the loop; case 12 added |
| `HB_LOCK_WAIT_S` was bounded below but not **above**: `600` against a 300 s cadence = two lost beats | read the validation block | **fixed** — `HB_LOCK_WAIT_MAX_S=30`; case 17 added |
| the exit-0 rationale cited `fleet-inventory.sh:68` — a **legend comment**, and no row is registered for the tick job at all | `sed -n '60,80p'`; `grep _fleet_row_launchd_job` | **fixed** — rationale re-grounded on the file's own `EXIT: always 0` contract and `heartbeat-loop.sh:536-539`; the inventory gap filed |
| the header claimed the tick "carries its own stall killer (`STALL … exceeded 390s`)" | `grep -n STALL` — it is `run_bounded`'s message in `heartbeat-loop.sh:534`, absent on the direct launchd path | **fixed** — claim retracted; the >30-minute-preemption residual stated in the header and filed |
| `scripts/lane-reap.sh:1359` in the `flock` chain is the wrong path | it is `scripts/orchestrator-harness/lane-reap.sh:1359` | **fixed** here and in the issue comment |
| surfaces 5 (signals) and 1 (claim/reclaim race) had **no test** | grepped the suite: no signal is ever sent to the subject | **fixed** — cases 12 and 13; case 13 goes red under a non-atomic claim (measured) |
| the sweep is destructive and was on no surface and in no test | read the code path | **fixed** — §5 row 7 + cases 14, 16 |
| two §4 ⚠️ rows were described as "two" when the table had three, and the platform row is a residual of *this change*, not pre-existing | read the table | **fixed** |
| §5 rows 3 and 6 carried one failure mode each, against the map's own ≥2 standard | read the map | **fixed** |
| a legitimate pass over 30 minutes on the launchd path is preempted (no owner refresh) | `disk-reaper.sh:867` is the precedent (`touch "$LOCK_DIR"` every 25 iterations) | **cited, not invented here** — an owner refresh that outlives its owner is a worse wedge; filed as its own issue |
| two sibling singletons carry the same class of defect: `$STATE/pr-doctor.lock` is age-only (no identity) and `heartbeat-loop.pid` is a bare `kill -0` (#1985 shape) | `heartbeat-loop.sh:768-774`, `:293-296` | **cited, not fixed here** — one `$STATE` now holds three definitions of "stale"; filed |
| lock on-disk format differs from the family's `token`/`own` line (advisory, reviewer #5) | three sibling files | **not changed** — the staged `mv` makes the two files atomic together; noted so the next reader is not surprised |
| `hb_max_attempt = WAIT_S + 8` was the only uncommented constant | read the block | **fixed** — derived and explained |

The remaining review findings were advisory (P2, duplication/architecture, no in-scope bypass) and are
recorded above rather than applied, per the skill's disposition rule.

- **This plan doc was written after the code**, to satisfy `check-pipeline-compliance.sh` check (d) and
  to move the design reasoning out of a PR body. It is **not** evidence that a plan gate ran before
  implementation, and it claims no such thing.

## 9. Rejected alternatives, restated for the reader who arrives with a vendor page

`flock(1)` is the right answer **on Linux** and it is **not available on macOS**, where this script
runs (§3, S1). The recorded decision that puts it out of scope was reached after a P1 review finding
on that issue, and reversing it is a **reopen** — argued in that decision's own home
(`docs/scoping/2026-09-05-issue-469-pi-session-hygiene.md`) with the evidence in front of the owner —
never a quiet swap in one of the sibling locks. Note the decision's **scope is platform, not
universal**: `scripts/pr-repair-loop.sh:258-269` legitimately requires `flock` for a cell-side tool.

⛔ **A supporting argument that was wrong, kept here so it is not re-invented.** An earlier draft of
this section said `flock` "does not answer which process holds this, which is the datum this guard has
to report". That is false: a `flock`-wrapped claim can write `pid` + `lstart` into the locked file
exactly as this guard does — the holder's identity comes from what you write into the file, not from
the lock primitive. `flock` was rejected on **platform availability**, and on nothing else. (The
external facts that do bear on it: `flock(2)` is an *advisory* lock attached to an open file
description, released when all descriptors on it are closed; and it is not propagated over SMB/CIFS
before Linux 5.4 — neither is a reason to reject it where it exists.)
